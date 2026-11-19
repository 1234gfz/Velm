const fs = require('fs');
const p = process.argv[2];
const d = JSON.parse(fs.readFileSync(p, 'utf8'));
const news = [
  { key: "fog.vstart", label: "体积雾·起始距离", type: "float", min: 0, max: 20000, step: 500, default: 0, value: 0,
    handler: "fog", target: "volstart", uiScale: 0.01, suffix: "m",
    hint: "体积雾从多少米外才开始出现（游戏原值 0 = 贴脸就有）。调到 20~30 米，房间里近处的浓雾就退掉，远处照旧。这才是你想要的『起始距离』——经典雾的起始距离管不到体积雾。",
    enabled: false, sub: "体积雾" },
  { key: "fog.vnearfade", label: "体积雾·近场淡入", type: "float", min: 0, max: 5000, step: 100, default: 0, value: 0,
    handler: "fog", target: "volnearfade", uiScale: 0.01, suffix: "m",
    hint: "让体积雾在起始距离附近平滑淡入，避免出现硬边/突变。配合上面的『起始距离』一起用，建议 5~10 米。",
    enabled: false, sub: "体积雾" }
];
const has = d.groups.some(g => (g.parameters || []).some(x => x.key === 'fog.vstart'));
if (!has) {
  for (const g of d.groups) {
    const ps = g.parameters || [];
    const i = ps.findIndex(x => x && x.key === 'fog.voldist');
    if (i >= 0) { ps.splice(i + 1, 0, ...news); break; }
  }
}
const text = JSON.stringify(d, null, 2) + "\n";
const tmp = p + ".tmp"; fs.writeFileSync(tmp, text, "utf8"); fs.renameSync(tmp, p);
let n = 0; for (const g of d.groups) n += (g.parameters || []).length;
console.log("fog params added, total=" + n);
