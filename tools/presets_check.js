// 校验预设文件：每个键都在参数表里、类型对（bool / number）。
// 用法：node tools/presets_check.js [pbz_presets.json 路径]
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const CFG = path.join(ROOT, 'lua', 'PBZFog', 'pbz_tweaker.json');
const PRES = process.argv[2] || path.join(ROOT, 'lua', 'PBZFog', 'pbz_presets.json');

const d = JSON.parse(fs.readFileSync(CFG, 'utf8'));
const params = new Map();
for (const g of d.groups || []) for (const p of g.parameters || []) params.set(p.key, p);

let presets;
try { presets = JSON.parse(fs.readFileSync(PRES, 'utf8')); }
catch (e) { console.error('读取预设失败: ' + e.message); process.exit(2); }

let err = 0, warn = 0;
const numTypes = new Set(['float', 'int', 'double', 'number', 'slider']);
for (const [nm, obj] of Object.entries(presets)) {
  if (typeof obj !== 'object' || obj === null) { console.log(`  预设「${nm}」不是对象`); err++; continue; }
  for (const [k, v] of Object.entries(obj)) {
    const p = params.get(k);
    if (!p) { console.log(`  [${nm}] 未知参数: ${k}`); warn++; continue; }
    const t = String(p.type || '');
    if (t === 'bool') { if (typeof v !== 'boolean') { console.log(`  [${nm}] ${k} 应为 bool，得到 ${typeof v}`); err++; } }
    else if (numTypes.has(t)) { if (typeof v !== 'number') { console.log(`  [${nm}] ${k} 应为 number，得到 ${typeof v}`); err++; } }
    // color / select / enum / string 等：不强制类型（对象数组、字符串都允许）
  }
}
console.log(`预设检查: ${Object.keys(presets).length} 套, 错误 ${err}, 警告(未知键) ${warn}`);
process.exit(err ? 1 : 0);
