// 生成 tooltip（hint）「旧 → 新」对照表，供评审。
// 用法：node tools/hints_review.js [oldGitRef] [outFile]
//   oldGitRef 默认取最早含 67 项参数表的提交；outFile 默认 docs/HINTS_REVIEW.md
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const CUR = path.join(ROOT, 'lua', 'PBZFog', 'pbz_tweaker.json');
const OLD_REF = process.argv[2] || 'ccd755a';
const OUT = process.argv[3] || path.join(ROOT, 'docs', 'HINTS_REVIEW.md');

function flatten(data) {
  const m = new Map();
  for (const g of data.groups || [])
    for (const p of g.parameters || []) m.set(p.key, p);
  return m;
}

const cur = flatten(JSON.parse(fs.readFileSync(CUR, 'utf8')));
let old;
try {
  const raw = execFileSync('git', ['-C', ROOT, 'show', `${OLD_REF}:lua/PBZFog/pbz_tweaker.json`], { encoding: 'utf8' });
  old = flatten(JSON.parse(raw));
} catch (e) {
  console.error('读取旧版本失败（git show ' + OLD_REF + '）: ' + e.message);
  process.exit(1);
}

const changed = [];
const removed = [];
const added = [];
for (const [k, p] of old) {
  if (!cur.has(k)) { removed.push(k); continue; }
  const a = p.hint || '', b = cur.get(k).hint || '';
  if (a !== b) changed.push([k, a, b]);
}
for (const k of cur.keys()) if (!old.has(k)) added.push(k);

let md = '# Tooltip 措辞评审（旧 → 新）\n\n';
md += `> 对比 ${OLD_REF} 与当前。共修改 ${changed.length} 条、删除参数 ${removed.length} 个、新增 ${added.length} 个。\n`;
md += '> 评审通过后再定稿；如需英文另附。\n\n';
md += '## 已改写\n\n| 参数 | 旧 | 新 |\n|---|---|---|\n';
for (const [k, a, b] of changed) {
  const esc = s => String(s).replace(/\|/g, '\\|').replace(/\n/g, ' ');
  md += `| \`${k}\` | ${esc(a)} | ${esc(b)} |\n`;
}
md += '\n## 已删除的参数\n\n' + (removed.length ? removed.map(k => `- \`${k}\``).join('\n') : '（无）') + '\n';
if (added.length) md += '\n## 新增的参数\n\n' + added.map(k => `- \`${k}\``).join('\n') + '\n';

fs.writeFileSync(OUT, md, 'utf8');
console.log('写出 ' + OUT + '：改写 ' + changed.length + '，删除 ' + removed.length + '，新增 ' + added.length);
