const std = @import("std");
const assert = std.debug.assert;

pub const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

// TODO: https://github.com/ziglang/zig/issues/4328
inline fn lua_pop(L: anytype, n: anytype) void {
    return lua.lua_settop(L, -n - 1);
}

pub fn alloc(ud: ?*c_void, ptr: ?*c_void, osize: usize, nsize: usize) callconv(.C) ?*c_void {
    const c_alignment = 16;
    const allocator = @ptrCast(*std.mem.Allocator, @alignCast(@alignOf(std.mem.Allocator), ud));
    if (@ptrCast(?[*]align(c_alignment) u8, @alignCast(c_alignment, ptr))) |previous_pointer| {
        const previous_slice = previous_pointer[0..osize];
        if (osize >= nsize) {
            // Lua assumes that the allocator never fails when osize >= nsize.
            return allocator.alignedShrink(previous_slice, c_alignment, nsize).ptr;
        } else {
            return (allocator.reallocAdvanced(previous_slice, c_alignment, nsize, .exact) catch return null).ptr;
        }
    } else {
        // osize is any of LUA_TSTRING, LUA_TTABLE, LUA_TFUNCTION, LUA_TUSERDATA, or LUA_TTHREAD
        // when (and only when) Lua is creating a new object of that type.
        // When osize is some other value, Lua is allocating memory for something else.
        return (allocator.alignedAlloc(u8, c_alignment, nsize) catch return null).ptr;
    }
}

pub fn newState(allocator: *std.mem.Allocator) !*lua.lua_State {
    return lua.lua_newstate(alloc, allocator) orelse return error.OutOfMemory;
}

const LuaIntTypeInfo = @typeInfo(lua.lua_Integer).Int;
const LuaFloatTypeInfo = @typeInfo(lua.lua_Number).Float;
pub fn push(L: ?*lua.lua_State, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(@TypeOf(value))) {
        .Void => lua.lua_pushnil(L),
        .Bool => lua.lua_pushboolean(L, @boolToInt(value)),
        .Int => |IntInfo| {
            assert(LuaIntTypeInfo.is_signed);
            if (IntInfo.bits > LuaIntTypeInfo.bits or (!IntInfo.is_signed and IntInfo.bits >= LuaIntTypeInfo.bits)) {
                @compileError("unable to coerce from type '" ++ @typeName(T) ++ "' (int too large)");
            }
            lua.lua_pushinteger(L, value);
        },
        .ComptimeInt => {
            // Will error at comptime if out of range
            lua.lua_pushinteger(L, value);
        },
        .Float => |FloatInfo| {
            if (FloatInfo.bits > LuaFloatTypeInfo.bits) {
                @compileError("unable to coerce from type '" ++ @typeName(T) ++ "' (float too large)");
            }
            lua.lua_pushnumber(L, value);
        },
        .ComptimeFloat => {
            // Will error at comptime if out of range
            lua.lua_pushnumber(L, value);
        },
        .Fn => {
            // TODO: check if already the correct signature?
            lua.lua_pushcclosure(L, wrap(value), 0);
        },
        .Pointer => |PointerInfo| switch (PointerInfo.size) {
            .Slice => {
                if (PointerInfo.child == u8) {
                    _ = lua.lua_pushlstring(L, value.ptr, value.len);
                } else {
                    @compileError("unable to coerce from type '" ++ @typeName(T) ++ "'");
                }
            },
            else => @compileError("unable to coerce from type '" ++ @typeName(T) ++ "'"),
        },
        .Type => {
            if (lua.luaL_newmetatable(L, @typeName(T)) == 1) {
                // TODO: fill in the metatable with info about the type?
            }
        },
        else => @compileError("unable to coerce from type '" ++ @typeName(@TypeOf(value)) ++ "'"),
    }
}

pub fn pushlib(L: ?*lua.lua_State, comptime value: type) void {
    const Composite = switch (@typeInfo(value)) {
        .Struct => |t| t,
        .Union => |t| t,
        .Enum => |t| t,
        else => @compileError("unable to push type " ++ @typeName(value)),
    };

    {
        comptime var nrec = 0;
        inline for (Composite.decls) |d| {
            if (d.is_pub) {
                nrec += 1;
            }
        }
        lua.lua_createtable(L, 0, nrec);
    }

    inline for (Composite.decls) |d| {
        if (d.is_pub) {
            _ = lua.lua_pushlstring(L, d.name.ptr, d.name.len);
            // workaround for "unable to evaluate constant expression" error when calling `push` with a function
            switch (d.data) {
                .Var, .Type => push(L, @field(value, d.name)),
                .Fn => lua.lua_pushcclosure(L, wrap(@field(value, d.name)), 0),
            }
            lua.lua_rawset(L, -3);
        }
    }
}

pub fn check(L: ?*lua.lua_State, idx: c_int, comptime T: type) T {
    switch (@typeInfo(T)) {
        .Void => {
            lua.luaL_checktype(L, idx, lua.LUA_TNIL);
            return void;
        },
        .Bool => {
            lua.luaL_checktype(L, idx, lua.LUA_TBOOLEAN);
            return lua.lua_toboolean(L, idx) != 0;
        },
        .Int => return @intCast(T, lua.luaL_checkinteger(L, idx)),
        .Float => return @floatCast(T, lua.luaL_checknumber(L, idx)),
        .Array => |AT| {
            switch (lua.lua_type(L, idx)) {
                lua.LUA_TTABLE => {
                    var A: T = undefined;
                    for (A) |*p, i| {
                        _ = lua.lua_geti(L, idx, @intCast(lua.lua_Integer, i + 1));
                        p.* = check(L, -1, AT.child);
                        lua_pop(L, 1);
                    }
                    return A;
                },
                // TODO: lua.LUA_TUSERDATA
                else => {
                    _ = lua.luaL_argerror(L, idx, "expected table");
                    unreachable;
                },
            }
        },
        .Pointer => |PT| {
            if (T == *c_void) {
                return lua.lua_topointer(L, idx);
            }

            const t = lua.lua_type(L, idx);
            if (T == []const u8) {
                if (t == lua.LUA_TSTRING) {
                    var len: usize = undefined;
                    const ptr = lua.lua_tolstring(L, idx, &len);
                    return ptr[0..len];
                } else if (t != lua.LUA_TUSERDATA) {
                    _ = lua.luaL_argerror(L, idx, "expected string or userdata");
                    unreachable;
                }
            } else {
                if (t != lua.LUA_TUSERDATA) {
                    _ = lua.luaL_argerror(L, idx, "expected userdata");
                    unreachable;
                }
            }
            if (lua.lua_getmetatable(L, idx) == 0) {
                _ = lua.luaL_argerror(L, idx, "unexpected userdata metatable");
                unreachable;
            }
            // TODO: check if metatable is valid for Pointer type
            @panic("unable to coerce to type: " ++ @typeName(T));
            // lua.lua_pop(L, 1);
            // const ptr = lua.lua_touserdata(L, idx);
        },
        else => @compileError("unable to coerce to type: " ++ @typeName(T)),
    }
}

/// Wraps an arbitrary function in a Lua C-API using version
pub fn wrap(comptime func: anytype) lua.lua_CFunction {
    const Fn = @typeInfo(@TypeOf(func)).Fn;
    // See https://github.com/ziglang/zig/issues/229
    return struct {
        // See https://github.com/ziglang/zig/issues/2930
        fn call(L: ?*lua.lua_State, args: anytype) (if (Fn.return_type) |rt| rt else void) {
            if (Fn.args.len == args.len) {
                return @call(.{}, func, args);
            } else {
                const i = args.len;
                const a = check(L, i + 1, Fn.args[i].arg_type.?);
                return @call(.{ .modifier = .always_inline }, call, .{ L, args ++ .{a} });
            }
        }

        fn thunk(L: ?*lua.lua_State) callconv(.C) c_int {
            const result = @call(.{ .modifier = .always_inline }, call, .{ L, .{} });
            if (@TypeOf(result) == void) {
                return 0;
            } else {
                push(L, result);
                return 1;
            }
        }
    }.thunk;
}

test "autolua" {
    _ = @import("./autolua_test.zig");
}
