const std = @import("std");
const assert = std.debug.assert;

pub const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    const c_alignment = 16;
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ud));
    const aligned_ptr: ?[*]align(c_alignment) u8 = @ptrCast(@alignCast(ptr));
    if (aligned_ptr) |previous_pointer| {
        const previous_slice = previous_pointer[0..osize];
        if (allocator.realloc(previous_slice, nsize)) |new_slice| {
            return new_slice.ptr;
        } else |_| {
            if (osize >= nsize) {
                // Lua assumes that the allocator never fails when osize >= nsize.
                // We could lie and say that `previous_slice.ptr` is still correct
                // However then osize will be incorrect, which means the next shrink/grow would lie to the allocator implementation
                @panic("unable to shrink");
            }
            return null;
        }
    } else {
        // osize is any of LUA_TSTRING, LUA_TTABLE, LUA_TFUNCTION, LUA_TUSERDATA, or LUA_TTHREAD
        // when (and only when) Lua is creating a new object of that type.
        // When osize is some other value, Lua is allocating memory for something else.
        return (allocator.alignedAlloc(u8, c_alignment, nsize) catch return null).ptr;
    }
}

pub const State = struct {
    L: *lua.lua_State,

    pub fn new(allocator: *const std.mem.Allocator) !State {
        return .{
            .L = lua.lua_newstate(alloc, @constCast(allocator)) orelse return error.OutOfMemory,
        };
    }

    pub fn close(self: State) void {
        lua.lua_close(self.L);
    }

    pub fn loadstring(self: State, s: [*:0]const u8) !void {
        switch (lua.luaL_loadstring(self.L, s)) {
            lua.LUA_OK => return,
            lua.LUA_ERRSYNTAX => return error.LuaSyntax,
            lua.LUA_ERRMEM => return error.OutOfMemory,
            else => |_| return error.Unexpected,
        }
    }

    fn pcallk(self: State) !void {
        switch (lua.lua_pcallk(self.L, 0, 0, 0, 0, null)) {
            lua.LUA_OK => return,
            lua.LUA_ERRRUN => return error.LuaRuntime,
            lua.LUA_ERRMEM => return error.OutOfMemory,
            lua.LUA_ERRERR => return error.LuaErrorInErrorHandling,
            lua.LUA_YIELD => @panic("NYI"),
            else => unreachable,
        }
    }

    pub fn dostring(self: State, s: [*:0]const u8) !void {
        try self.loadstring(s);
        return self.pcallk();
    }

    const LuaIntTypeInfo = @typeInfo(lua.lua_Integer).Int;
    const LuaFloatTypeInfo = @typeInfo(lua.lua_Number).Float;
    pub fn push(self: State, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(@TypeOf(value))) {
            .Void => lua.lua_pushnil(self.L),
            .Bool => lua.lua_pushboolean(self.L, @intFromBool(value)),
            .Int => |IntInfo| {
                assert(LuaIntTypeInfo.signedness == .signed);
                if (IntInfo.bits > LuaIntTypeInfo.bits or (IntInfo.signedness == .unsigned and IntInfo.bits >= LuaIntTypeInfo.bits)) {
                    @compileError("unable to coerce from type '" ++ @typeName(T) ++ "' (int too large)");
                }
                lua.lua_pushinteger(self.L, value);
            },
            .ComptimeInt => {
                // Will error at comptime if out of range
                lua.lua_pushinteger(self.L, value);
            },
            .Float => |FloatInfo| {
                if (FloatInfo.bits > LuaFloatTypeInfo.bits) {
                    @compileError("unable to coerce from type '" ++ @typeName(T) ++ "' (float too large)");
                }
                lua.lua_pushnumber(self.L, value);
            },
            .ComptimeFloat => {
                // Will error at comptime if out of range
                lua.lua_pushnumber(self.L, value);
            },
            .Fn => {
                // TODO: check if already the correct signature?
                lua.lua_pushcclosure(self.L, wrap(value), 0);
            },
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8) {
                        _ = lua.lua_pushlstring(self.L, value.ptr, value.len);
                    } else {
                        @compileError("unable to coerce from type '" ++ @typeName(T) ++ "'");
                    }
                },
                else => @compileError("unable to coerce from type '" ++ @typeName(T) ++ "'"),
            },
            .Type => {
                if (lua.luaL_newmetatable(self.L, @typeName(T)) == 1) {
                    // TODO: fill in the metatable with info about the type?
                }
            },
            else => @compileError("unable to coerce from type '" ++ @typeName(@TypeOf(value)) ++ "'"),
        }
    }

    pub fn pushlib(self: State, comptime value: type) void {
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
            lua.lua_createtable(self.L, 0, nrec);
        }

        inline for (Composite.decls) |d| {
            if (d.is_pub) {
                _ = lua.lua_pushlstring(self.L, d.name.ptr, d.name.len);
                // workaround for "unable to evaluate constant expression" error when calling `push` with a function
                switch (d.data) {
                    .Var, .Type => push(self.L, @field(value, d.name)),
                    .Fn => lua.lua_pushcclosure(self.L, wrap(@field(value, d.name)), 0),
                }
                lua.lua_rawset(self.L, -3);
            }
        }
    }

    pub fn check(self: State, idx: c_int, comptime T: type) T {
        switch (@typeInfo(T)) {
            .Void => {
                lua.luaL_checktype(self.L, idx, lua.LUA_TNIL);
                return {};
            },
            .Bool => {
                lua.luaL_checktype(self.L, idx, lua.LUA_TBOOLEAN);
                return lua.lua_toboolean(self.L, idx) != 0;
            },
            .Int => return @intCast(lua.luaL_checkinteger(self.L, idx)),
            .Float => return @floatCast(lua.luaL_checknumber(self.L, idx)),
            .Array => |AT| {
                switch (lua.lua_type(self.L, idx)) {
                    lua.LUA_TTABLE => {
                        var A: T = undefined;
                        for (&A, 0..) |*p, i| {
                            _ = lua.lua_geti(self.L, idx, @intCast(i + 1));
                            p.* = self.L.check(-1, AT.child);
                            lua.lua_pop(self.L, 1);
                        }
                        return A;
                    },
                    // TODO: lua.LUA_TUSERDATA
                    else => {
                        _ = lua.luaL_argerror(self.L, idx, "expected table");
                        unreachable;
                    },
                }
            },
            .Pointer => {
                if (T == *anyopaque) {
                    return lua.lua_topointer(self.L, idx);
                }

                const t = lua.lua_type(self.L, idx);
                if (T == []const u8) {
                    if (t == lua.LUA_TSTRING) {
                        var len: usize = undefined;
                        const ptr = lua.lua_tolstring(self.L, idx, &len);
                        return ptr[0..len];
                    } else if (t != lua.LUA_TUSERDATA) {
                        _ = lua.luaL_argerror(self.L, idx, "expected string or userdata");
                        unreachable;
                    }
                } else {
                    if (t != lua.LUA_TUSERDATA) {
                        _ = lua.luaL_argerror(self.L, idx, "expected userdata");
                        unreachable;
                    }
                }
                if (lua.lua_getmetatable(self.L, idx) == 0) {
                    _ = lua.luaL_argerror(self.L, idx, "unexpected userdata metatable");
                    unreachable;
                }
                // TODO: check if metatable is valid for Pointer type
                @panic("unable to coerce to type: " ++ @typeName(T));
                // lua.lua_pop(L, 1);
                // const ptr = lua.lua_touserdata(self.L, idx);
            },
            .Optional => |N| {
                if (lua.lua_isnoneornil(self.L, idx)) {
                    return null;
                }
                return self.L.check(idx, N.child);
            },
            else => @compileError("unable to coerce to type: " ++ @typeName(T)),
        }
    }
};

/// Wraps an arbitrary function in a Lua C-API using version
pub fn wrap(comptime func: anytype) lua.lua_CFunction {
    const Args = std.meta.ArgsTuple(@TypeOf(func));
    // See https://github.com/ziglang/zig/issues/229
    return struct {
        fn thunk(L: ?*lua.lua_State) callconv(.C) c_int {
            const state = State{ .L = L.? };
            var args: Args = undefined;
            comptime var i = 0;
            inline while (i < args.len) : (i += 1) {
                args[i] = state.check(i + 1, @TypeOf(args[i]));
            }
            const result = @call(.auto, func, args);
            if (@TypeOf(result) == void) {
                return 0;
            } else {
                state.push(result);
                return 1;
            }
        }
    }.thunk;
}

test "autolua" {
    _ = @import("./autolua_test.zig");
}
