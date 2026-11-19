#!/usr/bin/env node
// 用本机真 Lua 5.4 对整棵模块树做语法检查（loadfile，只编译不执行）。
// 用法: node syntaxtest.js [目录，默认 ../lua/PBZFog/Scripts]
// 可用环境变量 LUA_EXE 指定解释器路径。
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..', 'lua', 'PBZFog', 'Scripts'));
const lua = process.env.LUA_EXE || 'C:\\Users\\MSHY03\\AppData\\Local\\Programs\\Lua\\bin\\lua.exe';

if (!fs.existsSync(lua)) {
    console.error('找不到 Lua 解释器: ' + lua + '\n可设环境变量 LUA_EXE 指定。');
    process.exit(2);
}

function walk(d, out) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p, out);
        else if (e.name.endsWith('.lua')) out.push(p);
    }
    return out;
}

const files = walk(root, []);
let bad = 0;
for (const f of files) {
    // -e "assert(loadfile([[path]]))" —— 只加载编译，不执行
    try {
        execFileSync(lua, ['-e', 'assert(loadfile([[' + f + ']]))'], { stdio: ['ignore', 'ignore', 'pipe'], encoding: 'utf8' });
    } catch (e) {
        bad++;
        console.log('FAIL ' + f);
        if (e.stderr) console.log('     ' + String(e.stderr).trim().split('\n')[0]);
    }
}
console.log('语法检查: ' + files.length + ' 个文件, 失败 ' + bad);
process.exit(bad ? 1 : 0);
