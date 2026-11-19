#!/usr/bin/env node
// 把「模块源码 + 参数表 + 测试脚本」打包成一个自包含的 Lua 文件，再用本机真 Lua 5.4 跑。
// 为什么：node 负责读文件（UTF-8 路径没问题），Lua 只负责执行，避免中文路径/编码坑。
// 用法: node run_sim.js
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const TOOLS = __dirname;
const SCRIPTS = path.join(TOOLS, '..', 'lua', 'Velm', 'Scripts');
const CFG = path.join(TOOLS, '..', 'lua', 'Velm', 'pbz_tweaker.json');

function walk(dir, out, base) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, out, base);
        else if (e.name.endsWith('.lua')) {
            const rel = path.relative(base, p).replace(/\\/g, '/');
            const modName = rel.replace(/\.lua$/, '').replace(/\//g, '.');
            out[modName] = fs.readFileSync(p, 'utf8');
        }
    }
    return out;
}

function luaLong(s) {
    // 用长字符串 [==[ ]==] 包，选择不与内容冲突的等号级别
    let eq = '';
    while (s.includes(']' + eq + ']')) eq += '=';
    return '[' + eq + '[' + s + ']' + eq + ']';
}

const modules = walk(SCRIPTS, {}, SCRIPTS);
const cfgText = fs.readFileSync(CFG, 'utf8');
const testSrc = fs.readFileSync(path.join(TOOLS, 'sim_test.lua'), 'utf8');

let out = '';
out += 'MODULES = {}\n';
for (const [name, src] of Object.entries(modules)) {
    out += 'MODULES[' + JSON.stringify(name) + '] = ' + luaLong(src) + '\n';
}
out += 'CFG_TEXT = ' + luaLong(cfgText) + '\n';
out += 'local _RAWWRITE = io.write\n';
out += testSrc + '\n';
out += '\nif SUMMARY then _RAWWRITE("\\n" .. SUMMARY .. "\\n") end\n';

const bundle = path.join(TOOLS, '_sim_bundle.lua');
fs.writeFileSync(bundle, out, 'utf8');

const lua = process.env.LUA_EXE || 'C:\\Users\\MSHY03\\AppData\\Local\\Programs\\Lua\\bin\\lua.exe';
try {
    const stdout = execFileSync(lua, [bundle], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    process.stdout.write(stdout);
} catch (e) {
    if (e.stdout) process.stdout.write(e.stdout);
    if (e.stderr) process.stderr.write(e.stderr);
    process.exit(1);
}
