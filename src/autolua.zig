const std = @import("std");
const assert = std.debug.assert;

const lua_ABI = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const lua = struct {
    pub usingnamespace lua_ABI;

    // implement macros
    pub fn lua_pop(L: ?*lua.lua_State, n: c_int) void {
        lua_settop(L, -(n) - 1);
    }

    pub fn lua_replace(L: ?*lua.lua_State, idx: c_int) void {
        lua_copy(L, -1, idx);
        lua_pop(L, 1);
    }

    pub fn lua_call(L: ?*lua.lua_State, n: c_int, r: c_int) void {
        lua_callk(L, n, r, 0, null);
    }
};

const lua_int_type = @typeInfo(lua.lua_Integer).Int;
const lua_float_type = @typeInfo(lua.lua_Number).Float;
pub fn push(L: ?*lua.lua_State, value: var) void {
    switch (@typeId(@typeOf(value))) {
        .Void => lua.lua_pushnil(L),
        .Bool => lua.lua_pushboolean(L, if (value) u1(1) else u1(0)),
        .Int => {
            const int_type = @typeInfo(@typeOf(value)).Int;
            assert(lua_int_type.is_signed);
            if (int_type.bits > lua_int_type.bits or (!int_type.is_signed and int_type.bits >= lua_int_type.bits)) {
                @compileError("unable to coerce from type: " ++ @typeName(@typeOf(value)));
            }
            lua.lua_pushinteger(L, value);
        },
        .Float => {
            const float_type = @typeInfo(@typeOf(value)).Float;
            if (float_type.bits > lua_float_type.bits) {
                @compileError("unable to coerce from type: " ++ @typeName(@typeOf(value)));
            }
            lua.lua_pushnumber(L, value);
        },
        .Fn => {
            // TODO: check if already the correct signature?
            lua.lua_pushcclosure(L, wrap(value), 0);
        },
        .Pointer => |PT| {
            if (PT.size == .Slice and PT.child == u8) {
                _ = lua.lua_pushlstring(L, value.ptr, value.len);
            } else {
                @compileError("unable to coerce from type: " ++ @typeName(@typeOf(value)));
            }
        },
        else => @compileError("unable to coerce from type: " ++ @typeName(@typeOf(value))),
    }
}


pub fn pushlib(L: ?*lua.lua_State, comptime value: type) void {
    const Composite = switch(@typeInfo(value)) {
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
            switch (d.data) {
                .Var, .Fn => {
                    _ = lua.lua_pushlstring(L, d.name.ptr, d.name.len);
                    lua.lua_pushcclosure(L, wrap(@field(value, d.name)), 0);
                    lua.lua_rawset(L, -3);
                },
                else => @compileError("NYI: Type"),
            }
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
            switch(lua.lua_type(L, idx)) {
                lua.LUA_TTABLE => {
                    var A: T = undefined;
                    for (A) |*p, i| {
                        _ = lua.lua_geti(L, idx, @intCast(lua.lua_Integer, i + 1));
                        p.* = check(L, -1, AT.child);
                        lua.lua_pop(L, 1);
                    }
                    return A;
                },
                // TODO: lua.LUA_TUSERDATA
                else => {
                    _ = lua.luaL_argerror(L, idx, c"expected table");
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
                    _ = lua.luaL_argerror(L, idx, c"expected string or userdata");
                    unreachable;
                }
            } else {
                if (t != lua.LUA_TUSERDATA) {
                    _ = lua.luaL_argerror(L, idx, c"expected userdata");
                    unreachable;
                }
            }
            if (lua.lua_getmetatable(L, idx) == 0) {
                _ = lua.luaL_argerror(L, idx, c"unexpected userdata metatable");
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
pub fn wrap(comptime func: var) lua.lua_CFunction {
    const Fn = @typeInfo(@typeOf(func)).Fn;
    // See https://github.com/ziglang/zig/issues/229
    return struct {
        // See https://github.com/ziglang/zig/issues/2930
        fn call(L: ?*lua.lua_State) (if (Fn.return_type) |rt| rt else noreturn) {
            if (Fn.args.len == 0) return @inlineCall(func);
            const a1 = check(L, 1, Fn.args[0].arg_type.?);
            if (Fn.args.len == 1) return @inlineCall(func, a1);
            const a2 = check(L, 2, Fn.args[1].arg_type.?);
            if (Fn.args.len == 2) return @inlineCall(func, a1, a2);
            const a3 = check(L, 3, Fn.args[2].arg_type.?);
            if (Fn.args.len == 3) return @inlineCall(func, a1, a2, a3);
            const a4 = check(L, 4, Fn.args[3].arg_type.?);
            if (Fn.args.len == 4) return @inlineCall(func, a1, a2, a3, a4);
            const a5 = check(L, 5, Fn.args[4].arg_type.?);
            if (Fn.args.len == 5) return @inlineCall(func, a1, a2, a3, a4, a5);
            const a6 = check(L, 6, Fn.args[5].arg_type.?);
            if (Fn.args.len == 6) return @inlineCall(func, a1, a2, a3, a4, a5, a6);
            const a7 = check(L, 7, Fn.args[6].arg_type.?);
            if (Fn.args.len == 7) return @inlineCall(func, a1, a2, a3, a4, a5, a6, a7);
            const a8 = check(L, 8, Fn.args[7].arg_type.?);
            if (Fn.args.len == 8) return @inlineCall(func, a1, a2, a3, a4, a5, a6, a7, a8);
            const a9 = check(L, 9, Fn.args[8].arg_type.?);
            if (Fn.args.len == 9) return @inlineCall(func, a1, a2, a3, a4, a5, a6, a7, a8, a9);
            @compileError("NYI: >9 argument functions");
        }

        extern fn thunk(L: ?*lua.lua_State) c_int {
            if (Fn.return_type) |return_type| {
                const result: return_type = @inlineCall(call, L);
                if (return_type == void) {
                    return 0;
                } else {
                    push(L, result);
                    return 1;
                }
            } else {
                // is noreturn
                @inlineCall(call, L);
            }
        }
    }.thunk;
}

test "autolua" {
    _ = @import("./autolua_test.zig");
}
