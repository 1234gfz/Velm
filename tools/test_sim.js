#!/usr/bin/env node
// 用 fengari（Lua 5.3 的 JS 实现）把 PBZFog 的模块在「模拟 UE 环境」里真跑一遍。
//
// 为什么：语法检查只能抓拼写。这次重构动的是写入路径、落盘时机、换世界重置 ——
// 这些出问题时语法完全正确，只有在游戏里跑才会暴露。启动游戏验证要几分钟一次，
// 这个脚本毫秒级跑同样的逻辑，改一行跑一次。
//
// 用法: node tools/test_sim.js
// 退出码 0 = 全部通过。

const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const TOOLS = __dirname;
const SCRIPTS = path.join(TOOLS, '..', 'lua', 'PBZFog', 'Scripts');
const CFG = path.join(TOOLS, '..', 'lua', 'PBZFog', 'pbz_tweaker.json');

// ---------------------------------------------------------------- 收集模块源码

function walk(dir, out, base) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out, base);
    else if (e.name.endsWith('.lua')) {
      let rel = path.relative(base, p).replace(/\\/g, '/');
      const modName = rel.replace(/\.lua$/, '').replace(/\//g, '.');
      out[modName] = fs.readFileSync(p, 'utf8');
    }
  }
  return out;
}

const modules = walk(SCRIPTS, {}, SCRIPTS);
const cfgText = fs.readFileSync(CFG, 'utf8');

// ---------------------------------------------------------------- 建 Lua 状态

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

// MODULES 表
lua.lua_createtable(L, 0, Object.keys(modules).length);
for (const [name, src] of Object.entries(modules)) {
  lua.lua_pushstring(L, to_luastring(src));
  lua.lua_setfield(L, -2, to_luastring(name));
}
lua.lua_setglobal(L, to_luastring('MODULES'));

// CFG_TEXT
lua.lua_pushstring(L, to_luastring(cfgText));
lua.lua_setglobal(L, to_luastring('CFG_TEXT'));

// ---------------------------------------------------------------- 运行测试

const testSrc = fs.readFileSync(path.join(TOOLS, 'sim_test.lua'), 'utf8');
const status = lauxlib.luaL_loadbuffer(L, to_luastring(testSrc), null, to_luastring('@sim_test.lua'));
if (status !== lua.LUA_OK) {
  console.error('测试脚本编译失败:', to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}
const callStatus = lua.lua_pcall(L, 0, 0, 0);
if (callStatus !== lua.LUA_OK) {
  console.error('测试脚本运行出错:', to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}

lua.lua_getglobal(L, to_luastring('SUMMARY'));
const summary = to_jsstring(lua.lua_tostring(L, -1));
lua.lua_getglobal(L, to_luastring('FAILED'));
const failed = lua.lua_tointeger(L, -1);

console.log('PBZFog 行为模拟测试');
console.log(summary);
process.exit(failed > 0 ? 1 : 0);
