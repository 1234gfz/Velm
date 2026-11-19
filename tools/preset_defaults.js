// 从参数表生成一套「默认（游戏原版）」预设：所有参数取 default（回落到 value）。
// 用途：给用户一个「一键回到游戏原版」的基线。用法：node tools/preset_defaults.js [预设名]
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const CFG = path.join(ROOT, 'lua', 'PBZFog', 'pbz_tweaker.json');
const OUT = path.join(ROOT, 'lua', 'PBZFog', 'pbz_presets.json');
const NAME = process.argv[2] || '默认（游戏原版）';

const d = JSON.parse(fs.readFileSync(CFG, 'utf8'));
const obj = {};
for (const g of d.groups || [])
  for (const p of g.parameters || [])
    obj[p.key] = (p.default !== undefined ? p.default : p.value);

// 保留已有预设（如果 OUT 已存在且是对象），只更新这一套
let presets = {};
try { if (fs.existsSync(OUT)) presets = JSON.parse(fs.readFileSync(OUT, 'utf8')) || {}; } catch { presets = {}; }
presets[NAME] = obj;

fs.writeFileSync(OUT, JSON.stringify(presets, null, 2) + '\n', 'utf8');
console.log(`写出 ${OUT}：预设「${NAME}」${Object.keys(obj).length} 键（现有预设 ${Object.keys(presets).length} 套）`);
