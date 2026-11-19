// 静态自检：在不能真跑 Lua 的前提下，尽可能多地把低级错误挡在部署之前。
//
// 检查项：
//   1. 每个 .lua 都能被解析（语法）
//   2. 每个 require("a.b") 都指向存在的 a/b.lua
//   3. 每个 require 的结果被赋给变量后，调用到的成员确实在对方文件里定义
//   4. 调用了但从未定义的全局函数（排除 UE4SS / Lua 内置）
//   5. 同一模块里重复定义同名导出
//
// 用法: node tools/lint_modules.js [目录]
// 退出码非 0 表示有错误。

const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

// UE4SS 把「模块根」定为 mod 的 Scripts 目录（`;{}/?.lua` 里的 {} 就是它），
// 所以 require("core.log") → Scripts/core/log.lua。检查脚本必须用同一个根。
const ROOT = process.argv[2] || path.join(__dirname, '..', 'lua', 'Velm', 'Scripts');

const errors = [];
const warnings = [];

// ---------------------------------------------------------------- 工具

function rel(p) { return path.relative(ROOT, p).replace(/\\/g, '/'); }

// luaparse 的 StringLiteral 只填 raw，value 常为 null。统一从 raw 里剥引号。
function strVal(n) {
  if (!n) return null;
  if (typeof n.value === 'string') return n.value;
  if (typeof n.raw === 'string') {
    const r = n.raw;
    if (r.length >= 2) return r.slice(1, -1);
    return r;
  }
  return null;
}

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.lua')) out.push(p);
  }
  return out;
}

function walkNodes(node, fn) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (const n of node) walkNodes(n, fn); return; }
  if (node.type) fn(node);
  for (const k of Object.keys(node)) {
    if (k === 'type') continue;
    walkNodes(node[k], fn);
  }
}

// ---------------------------------------------------------------- 解析

const files = walk(ROOT, []).sort();
const parsed = {};

for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  try {
    parsed[rel(f)] = luaparse.parse(src, { luaVersion: '5.3', scope: false, comments: false });
  } catch (e) {
    errors.push(`[语法] ${rel(f)}: ${e.message}`);
  }
}

// ---------------------------------------------------------------- 导出成员表

const exportsOf = {};
for (const [file, ast] of Object.entries(parsed)) {
  const mod = file.replace(/\.lua$/, '').replace(/\//g, '.');
  const set = new Set();
  walkNodes(ast.body, (n) => {
    if (n.type === 'FunctionDeclaration' && n.identifier && n.identifier.type === 'MemberExpression') {
      const id = n.identifier;
      if (id.index) {
        const m = id.index.name || strVal(id.index);
        if (m) set.add(m);
      }
    }
    if (n.type === 'AssignmentStatement') {
      for (const v of n.variables) {
        if (v.type === 'MemberExpression' && v.index) {
          const m = v.index.name || strVal(v.index);
          if (m) set.add(m);
        }
      }
    }
  });
  exportsOf[mod] = set;
}

// ---------------------------------------------------------------- require

const REQUIRES = new Map();

for (const [file, ast] of Object.entries(parsed)) {
  walkNodes(ast.body, (n) => {
    if (n.type !== 'LocalStatement') return;
    if (!n.init || n.init.length !== 1) return;
    const init = n.init[0];
    if (init.type !== 'CallExpression') return;
    if (!init.base || init.base.type !== 'Identifier' || init.base.name !== 'require') return;
    const arg = init.arguments && init.arguments[0];
    if (!arg) return;
    const mod = strVal(arg);
    if (!mod) return;
    const localName = n.variables && n.variables[0] && n.variables[0].name;
    const target = path.join(ROOT, mod.replace(/\./g, path.sep) + '.lua');
    if (!fs.existsSync(target)) {
      errors.push(`[require] ${file}: require("${mod}") 找不到 ${rel(target)}`);
      return;
    }
    if (!REQUIRES.has(file)) REQUIRES.set(file, []);
    REQUIRES.get(file).push({ localName, mod });
  });
}

// ---------------------------------------------------------------- 成员调用

for (const [file, list] of REQUIRES.entries()) {
  const ast = parsed[file];
  if (!ast) continue;
  const byLocal = {};
  for (const r of list) if (r.localName) byLocal[r.localName] = r.mod;

  walkNodes(ast.body, (n) => {
    if (n.type !== 'MemberExpression') return;
    if (!n.base || n.base.type !== 'Identifier') return;
    const mod = byLocal[n.base.name];
    if (!mod) return;
    const member = n.index && (n.index.name || strVal(n.index));
    if (!member) return;
    const known = exportsOf[mod];
    if (!known) return;
    if (!known.has(member)) {
      warnings.push(`[成员] ${file}: ${n.base.name}.${member} 未在 ${mod} 中定义`);
    }
  });
}

// ---------------------------------------------------------------- 全局函数

const LUA_BUILTINS = new Set([
  'print', 'pairs', 'ipairs', 'next', 'type', 'tostring', 'tonumber', 'pcall', 'xpcall',
  'error', 'assert', 'select', 'unpack', 'rawget', 'rawset', 'rawequal', 'rawlen',
  'setmetatable', 'getmetatable', 'require', 'load', 'loadstring',
  'collectgarbage', 'dofile', 'loadfile',
]);

const UE4SS_GLOBALS = new Set([
  'RegisterHook', 'RegisterKeyBind', 'RegisterConsoleCommand', 'RegisterConsoleCommandHandler',
  'RegisterConsoleCommandGlobalHandler', 'RegisterCustomEvent',
  'NotifyOnNewObject', 'NotifyOnNewClass', 'NotifyOnNewLiveViewObject',
  'ExecuteWithDelay', 'ExecuteInGameThread', 'ExecuteAsync',
  'ExecuteInGameThreadWithDelay', 'LoopInGameThreadWithDelay', 'LoopAsync',
  'FindAllOf', 'FindFirstOf', 'FindObject', 'StaticFindObject', 'StaticConstructObject',
  'LoadAsset', 'CreateInvalidObject', 'DumpAllObjects', 'DumpObject',
  'RegisterLoadMapPreHook', 'RegisterLoadMapPostHook',
  'RegisterBeginPlayPreHook', 'RegisterBeginPlayPostHook',
  'RegisterULocalPlayerExecPreHook', 'RegisterULocalPlayerExecPostHook',
  'RegisterProcessConsoleExecPreHook', 'RegisterProcessConsoleExecPostHook',
  'RegisterProcessEventPreHook', 'RegisterProcessEventPostHook',
  'RegisterInitGameStatePreHook', 'RegisterInitGameStatePostHook',
  'RegisterAActorTickPreHook', 'RegisterAActorTickPostHook',
  'RegisterUStructLinkPreHook', 'RegisterUStructLinkPostHook',
  'RegisterUObjectProcessEventPreHook', 'RegisterUObjectProcessEventPostHook',
  'RegisterEngineTickPreHook', 'RegisterEngineTickPostHook',
  'RegisterCallFunctionByNameWithArgumentsPreHook',
  'RegisterCallFunctionByNameWithArgumentsHook',
  'ModRef', 'UEHelpers', 'IsValid', 'GetWorld', 'GetPlayerController',
]);

const definedGlobals = new Set();
for (const ast of Object.values(parsed)) {
  walkNodes(ast.body, (n) => {
    if (n.type === 'FunctionDeclaration' && n.identifier && n.identifier.type === 'Identifier') {
      definedGlobals.add(n.identifier.name);
    }
    // 前向声明：local parseValue; parseValue = function(...) end
    if (n.type === 'LocalStatement' && n.variables) {
      for (const v of n.variables) if (v.type === 'Identifier') definedGlobals.add(v.name);
    }
    // 直接赋值也视为定义（globals 的常见写法）
    if (n.type === 'AssignmentStatement' && n.variables) {
      for (const v of n.variables) if (v.type === 'Identifier') definedGlobals.add(v.name);
    }
    // function foo() 形式
    if (n.type === 'FunctionDeclaration' && n.identifier && n.identifier.type === 'Identifier') {
      definedGlobals.add(n.identifier.name);
    }
    // 函数参数是局部名，调用它们不算「未定义全局函数」（消除 fn()/cb() 之类的误报）
    if ((n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression') && Array.isArray(n.parameters)) {
      for (const prm of n.parameters) if (prm && prm.type === 'Identifier') definedGlobals.add(prm.name);
    }
  });
}

const usedGlobals = new Map();
for (const [file, ast] of Object.entries(parsed)) {
  walkNodes(ast.body, (n) => {
    if (n.type !== 'CallExpression') return;
    if (!n.base || n.base.type !== 'Identifier') return;
    const nm = n.base.name;
    if (LUA_BUILTINS.has(nm) || UE4SS_GLOBALS.has(nm) || definedGlobals.has(nm)) return;
    if (!usedGlobals.has(nm)) usedGlobals.set(nm, new Set());
    usedGlobals.get(nm).add(file);
  });
}
for (const [nm, where] of usedGlobals.entries()) {
  warnings.push(`[全局] 调用了未定义的全局函数 ${nm}()，出现在: ${[...where].join(', ')}`);
}

// ---------------------------------------------------------------- 重复定义

const defCount = {};
for (const [file, ast] of Object.entries(parsed)) {
  const mod = file.replace(/\.lua$/, '').replace(/\//g, '.');
  walkNodes(ast.body, (n) => {
    if (n.type !== 'FunctionDeclaration') return;
    if (!n.identifier || n.identifier.type !== 'MemberExpression') return;
    const m = n.identifier.index && (n.identifier.index.name || strVal(n.identifier.index));
    if (!m) return;
    const k = mod + '.' + m;
    defCount[k] = (defCount[k] || 0) + 1;
  });
}
for (const [k, c] of Object.entries(defCount)) {
  if (c > 1) warnings.push(`[重复] ${k} 定义了 ${c} 次`);
}

// ---------------------------------------------------------------- 输出

const totalLines = files.reduce((s, f) => s + fs.readFileSync(f, 'utf8').split('\n').length, 0);

console.log(`检查 ${files.length} 个文件，共 ${totalLines} 行`);

if (warnings.length) {
  console.log('');
  console.log(`警告 ${warnings.length} 条:`);
  for (const w of warnings) console.log('  ' + w);
}

if (errors.length) {
  console.log('');
  console.log(`错误 ${errors.length} 条:`);
  for (const e of errors) console.log('  ' + e);
  process.exit(1);
}
console.log('没有错误。');
