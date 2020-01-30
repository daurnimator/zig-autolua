const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const autolua = @import("./autolua.zig");
const lua = autolua.lua;

test "returning an array" {
    const L = lua.luaL_newstate();
    lua.luaL_openlibs(L);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.luaL_loadstring(L,
        \\return {1,2,3}
    ));
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, 1, 0, 0, null));
    testing.expectEqual([_]u32{ 1, 2, 3 }, autolua.check(L, 1, [3]u32));
}

test "returning a string" {
    const L = lua.luaL_newstate();
    lua.luaL_openlibs(L);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.luaL_loadstring(L,
        \\return "hello world"
    ));
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, 1, 0, 0, null));
    testing.expectEqualSlices(u8, "hello world"[0..], autolua.check(L, 1, []const u8));
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

fn func_error() !void {
    return error.SomeError;
}

fn func_unreachable() void {
    unreachable;
}

fn bar(L: ?*lua.lua_State) callconv(.C) c_int {
    return 0;
}

const lib = [_]lua.luaL_Reg{
    lua.luaL_Reg{ .name = "func_void", .func = autolua.wrap(func_void) },
    lua.luaL_Reg{ .name = "func_bool", .func = autolua.wrap(func_bool) },
    lua.luaL_Reg{ .name = "func_i8", .func = autolua.wrap(func_i8) },
    lua.luaL_Reg{ .name = "func_i64", .func = autolua.wrap(func_i64) },
    // lua.luaL_Reg{ .name = "func_u64", .func = autolua.wrap(func_u64) },
    lua.luaL_Reg{ .name = "func_f16", .func = autolua.wrap(func_f16) },
    lua.luaL_Reg{ .name = "func_f64", .func = autolua.wrap(func_f64) },
    // lua.luaL_Reg{ .name = "func_f128", .func = autolua.wrap(func_f128) },
    lua.luaL_Reg{ .name = "func_addu32", .func = autolua.wrap(func_addu32) },
    // lua.luaL_Reg{ .name = "func_error", .func = autolua.wrap(func_error) },
    lua.luaL_Reg{ .name = "bar", .func = bar },
    lua.luaL_Reg{ .name = 0, .func = null },
};

export fn luaopen_mylib(L: ?*lua.lua_State) c_int {
    lua.lua_createtable(L, 0, lib.len - 1);
    lua.luaL_setfuncs(L, &lib[0], 0);
    return 1;
}

test "wrapping void returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, autolua.wrap(func_void), 0);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(@as(c_int, 0), lua.lua_gettop(L));
}

test "wrapping boolean returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, autolua.wrap(func_bool), 0);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(false, autolua.check(L, 1, bool));
}

test "wrapping integer returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, autolua.wrap(func_i8), 0);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(@as(i8, 42), autolua.check(L, 1, i8));
}

test "wrapping float returning function works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, autolua.wrap(func_f16), 0);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(@as(f16, 1 << 10), autolua.check(L, 1, f16));
}

test "wrapping function that takes arguments works" {
    const L = lua.luaL_newstate();
    lua.lua_pushcclosure(L, autolua.wrap(func_addu32), 0);
    lua.lua_pushinteger(L, 5);
    lua.lua_pushinteger(L, 1000);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 2, lua.LUA_MULTRET, 0, 0, null));
    testing.expectEqual(@as(u32, 5 + 1000), autolua.check(L, 1, u32));
}

// test "wrapping function that throws error" {
//     const L = lua.luaL_newstate();
//     lua.lua_pushcclosure(L, autolua.wrap(func_error), 0);
//     testing.expectEqual(@as(c_int, lua.LUA_ERRRUN), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
//     testing.expect(error.SomeError == autolua.check(L, 1, anyerror));
// }

// test "wrapping unreachable function" {
//     const L = lua.luaL_newstate();
//     lua.lua_pushcclosure(L, autolua.wrap(func_unreachable), 0);
//     testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, lua.LUA_MULTRET, 0, 0, null));
// }

test "library works" {
    const L = lua.luaL_newstate();
    lua.luaL_openlibs(L);
    lua.luaL_requiref(L, "mylib", luaopen_mylib, 0);
    lua.lua_settop(L, 0);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.luaL_loadstring(L,
        \\local mylib = require "mylib"
        \\assert(mylib.func_void() == nil)
        \\assert(mylib.func_bool() == false)
        \\assert(mylib.func_i8() == 42)
        \\assert(mylib.func_f16() == 1<<10)
        \\assert(mylib.func_addu32(5432, 1234) == 6666)
    ));
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 0, 0, 0, 0, null));
}

test "wrap struct works" {
    const L = lua.luaL_newstate();
    lua.luaL_openlibs(L);
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.luaL_loadstring(L,
        \\local lib = ...
        \\assert(lib.get_void() == nil)
        \\assert(lib.get_bool() == false)
        \\assert(lib.get_i8() == 42)
        \\assert(lib.get_f16() == 1<<10)
        \\assert(lib.add_u32(5432, 1234) == 6666)
    ));
    autolua.pushlib(L, struct {
        pub fn get_void() void {
            return func_void();
        }

        pub fn get_bool() bool {
            return func_bool();
        }

        pub fn get_i8() i8 {
            return func_i8();
        }

        pub fn get_i64() i64 {
            return func_i64();
        }

        pub fn get_f16() f16 {
            return func_f16();
        }

        pub fn get_f64() f64 {
            return func_f64();
        }

        pub fn add_u32(x: u32, y: u32) u32 {
            return func_addu32(x, y);
        }
    });
    testing.expectEqual(@as(c_int, lua.LUA_OK), lua.lua_pcallk(L, 1, 0, 0, 0, null));
}
