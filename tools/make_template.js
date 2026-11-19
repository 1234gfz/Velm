// 把 pbz_tweaker.json 归一成「干净模板」：所有参数默认关闭、数值取默认、模式绝对、
// 分辨率回到「不修改」。发布包/Pack 都应以这种干净态出厂，避免带上开发者的调参痕迹。
// 用法: node make_template.js <pbz_tweaker.json>
const fs = require('fs');
const p = process.argv[2];
if (!p) { console.error('用法: node make_template.js <pbz_tweaker.json>'); process.exit(1); }
const o = JSON.parse(fs.readFileSync(p, 'utf8'));
let n = 0;
for (const g of (o.groups || [])) {
  for (const pr of (g.parameters || [])) {
    pr.enabled = false;
    if (Object.prototype.hasOwnProperty.call(pr, 'default')) pr.value = pr.default;
    if (Object.prototype.hasOwnProperty.call(pr, 'mode')) pr.mode = 'abs';
    if (Object.prototype.hasOwnProperty.call(pr, 'ratio')) pr.ratio = 100;
    if (Object.prototype.hasOwnProperty.call(pr, 'offset')) pr.offset = 0;
    n++;
  }
}
if (o.master === undefined) o.master = true;
fs.writeFileSync(p, JSON.stringify(o, null, 2), 'utf8');
console.log('已归一为干净模板:', n, '个参数');
