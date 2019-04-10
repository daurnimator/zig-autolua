// build with:
// zig build-lib -dynamic --library c -isystem /usr/include/ mylib.zig
// mv libmylib.so.0.0.0 mylib.so
//
// run with:
// lua -e 'mylib=require"mylib"; mylib.foo()'

const std = @import("std");

const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
});

extern fn foo(L: ?*lua.lua_State) c_int {
    return 0;
}

extern fn bar(L: ?*lua.lua_State) c_int {
    return 0;
}

const lib = []lua.luaL_Reg{
    lua.luaL_Reg{ .name = c"foo", .func = foo },
    lua.luaL_Reg{ .name = c"bar", .func = bar },
    lua.luaL_Reg{ .name = 0, .func = null },
};

export fn luaopen_mylib(L: *lua.lua_State) c_int {
    lua.lua_createtable(L, 0, lib.len - 1);
    lua.luaL_setfuncs(L, &lib[0], 0);
    return 1;
}
