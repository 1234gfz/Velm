const fs = require('fs');
const raw = fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log', 'utf8').split(/\r?\n/);
// 统计每 10 秒窗口内的 Lua 日志行数，看写入爆发
const buckets = new Map();
let total = 0;
for (const l of raw) {
  if (!l.includes('[Lua]')) continue;
  const m = l.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/);
  if (!m) continue;
  const k = m[1].slice(0, 17) + '0';  // 10 秒窗口
  buckets.set(k, (buckets.get(k) || 0) + 1);
  total++;
}
console.log('Lua 日志总行数:', total);
const arr = [...buckets.entries()].sort((a,b) => b[1]-a[1]);
console.log('\n=== Lua 行数最多的 10 个窗口（每 10 秒）===');
for (const [k, v] of arr.slice(0, 10)) console.log(`  ${k}  ${v} 行`);
const counts = arr.map(x=>x[1]).sort((a,b)=>a-b);
console.log(`\n窗口数 ${counts.length}  中位 ${counts[Math.floor(counts.length/2)]}  p95 ${counts[Math.floor(counts.length*0.95)]}  最大 ${counts[counts.length-1]}`);
// 换代事件间隔
const gen = [];
for (const l of raw) {
  if (l.includes('后处理体积换代')) {
    const m = l.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/);
    if (m) gen.push(new Date(m[1].replace(' ','T')+'+08:00').getTime());
  }
}
console.log(`\n换代次数: ${gen.length}`);
const g2 = [];
for (let i=1;i<gen.length;i++) g2.push((gen[i]-gen[i-1])/1000);
g2.sort((a,b)=>a-b);
if (g2.length) console.log(`换代间隔(秒): 最小 ${g2[0]}  中位 ${g2[Math.floor(g2.length/2)]}  最大 ${g2[g2.length-1]}`);
console.log(`密集换代(<3秒内连续): ${g2.filter(x=>x<3).length} 次`);