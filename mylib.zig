// test with:
// zig test --library c --library lua -isystem /usr/include/ -L/usr/lib mylib.zig
//
// build with:
// zig build-lib -dynamic --library c -isystem /usr/include/ mylib.zig
// mv libmylib.so.0.0.0 mylib.so
//
// run example:
// lua -e 'mylib=require"mylib"; mylib.foo()'

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const lua_int_type = @typeInfo(lua.lua_Integer).Int;
const lua_float_type = @typeInfo(lua.lua_Number).Float;
fn push(L: ?*lua.lua_State, value: var) void {
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
        else => @compileError("unable to coerce from type: " ++ @typeName(@typeOf(value))),
    }
}

fn check(L: ?*lua.lua_State, idx: c_int, comptime T: type) T {
    switch (@typeId(T)) {
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
        else => @compileError("unable to coerce to type: " ++ @typeName(T)),
    }
}

fn wrap(comptime func: var) switch (@typeId(@typeOf(func))) {
    .Fn => lua.lua_CFunction,
    else => @compileError("unable to wrap type: " ++ @typeName(@typeOf(func))),
} {
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
            @panic("NYI: >9 argument functions");
        }

        extern fn wrapped_func(L: ?*lua.lua_State) c_int {
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
    }.wrapped_func;
}

fn func_void() void {}

fn func_bool() bool {
    return false;
}

fn func_i8() i8 {
    return 42;
}

fn func_i64() i64 {
    return 1 << 62;
}

fn func_u64() u64 {
    return 1 << 63;
}

fn func_f16() f16 {
    return 1 << 10;
}

fn func_f64() f64 {
    return 1 << 64;
}

fn func_f128() f128 {
    return 1 << 63;
}

fn func_addu32(x: u32, y: u32) u32 {
    return x + y;
}

extern fn bar(L: ?*lua.lua_State) c_int {
    return 0;
}

const lib = [_]lua.luaL_Reg{
    lua.luaL_Reg{ .name = c"func_void", .func = wrap(func_void) },
    lua.luaL_Reg{ .name = c"func_bool", .func = wrap(func_bool) },
    lua.luaL_Reg{ .name = c"func_i8", .func = wrap(func_i8) },
    lua.luaL_Reg{ .name = c"func_i64", .func = wrap(func_i64) },
    // lua.luaL_Reg{ .name = c"func_u64", .func = wrap(func_u64) },
    lua.luaL_Reg{ .name = c"func_f16", .func = wrap(func_f16) },
    lua.luaL_Reg{ .name = c"func_f64", .func = wrap(func_f64) },
    // lua.luaL_Reg{ .name = c"func_f128", .func = wrap(func_f128) },
    lua.luaL_Reg{ .name = c"func_addu32", .func = wrap(func_addu32) },
    lua.luaL_Reg{ .name = c"bar", .func = bar },
    lua.luaL_Reg{ .name = 0, .func = null },
};

export fn luaopen_mylib(L: ?*lua.lua_State) c_int {
    lua.lua_createtable(L, 0, lib.len - 1);
    lua.luaL_setfuncs(L, &lib[0], 0);
    return 1;
}

test "wrapping void returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, wrap(func_void), 0);
    testing.expectEqual(c_int(lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(c_int(0), lua.lua_gettop(L));
}

test "wrapping boolean returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, wrap(func_bool), 0);
    testing.expectEqual(c_int(lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(false, check(L, 1, bool));
}

test "wrapping integer returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, wrap(func_i8), 0);
    testing.expectEqual(c_int(lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(i8(42), check(L, 1, i8));
}

test "wrapping float returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, wrap(func_f16), 0);
    testing.expectEqual(c_int(lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(f16(1 << 10), check(L, 1, f16));
}

test "wrapping function that takes arguments works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, wrap(func_addu32), 0);
    lua.lua_pushinteger(L, 5);
    lua.lua_pushinteger(L, 1000);
    testing.expectEqual(c_int(lua.LUA_OK), lua.lua_pcallk(L, 2, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(u32(5 + 1000), check(L, 1, u32));
}

test "library works" {
    const L = lua.luaL_newstate();
    lua.luaL_openlibs(L);
    lua.luaL_requiref(L, c"mylib", luaopen_mylib, 0);
    lua.lua_settop(L, 0);
    testing.expectEqual(c_int(lua.LUA_OK), lua.luaL_loadstring(L,
        c\\local mylib = require "mylib"
        c\\assert(mylib.func_void() == nil)
        c\\assert(mylib.func_bool() == false)
        c\\assert(mylib.func_i8() == 42)
        c\\assert(mylib.func_f16() == 1<<10)
        c\\assert(mylib.func_addu32(5432, 1234) == 6666)
    ));
    testing.expectEqual(c_int(lua.LUA_OK), lua.lua_pcallk(L, 0, 0, 0, 0, null));
}
