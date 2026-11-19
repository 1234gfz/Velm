const fs = require('fs');
const raw = fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log','utf8').split(/\r?\n/);
const ev = [];
for (const l of raw) {
  const m = l.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/);
  if (!m) continue;
  const t = new Date(m[1].replace(' ','T')+'+08:00').getTime();
  if (l.includes('[PBZ] 换世界')) ev.push({t, k:'换世界'});
  else if (l.includes('后处理体积换代')) ev.push({t, k:'换代'});
  else if (l.includes('[PBZ] 状态')) {
    const mm = l.match(/tick均=([\d.]+)ms 峰=([\d.]+)ms/);
    if (mm) ev.push({t, k:'状态', avg:+mm[1], max:+mm[2]});
  }
}
// 每次换代后 3 秒内写了多少个字段
const writes = [];
for (const l of raw) {
  const m = l.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/);
  if (m && l.includes('pp 写 ')) writes.push(new Date(m[1].replace(' ','T')+'+08:00').getTime());
}
const gen = ev.filter(e=>e.k==='换代').map(e=>e.t);
console.log('换代次数:', gen.length, ' 写入日志行数:', writes.length);
// 每个换代窗口内（到下一个换代为止）的写入条数
const per = [];
for (let i=0;i<gen.length;i++){
  const a=gen[i], b=gen[i+1]??Infinity;
  per.push(writes.filter(w=>w>=a&&w<b).length);
}
per.sort((x,y)=>x-y);
console.log(`每次换代触发的写入日志条数: 中位 ${per[Math.floor(per.length/2)]}  p90 ${per[Math.floor(per.length*0.9)]}  最大 ${per[per.length-1]}`);
console.log(`\n=== 峰值 tick 的分布（状态行）===`);
const st = ev.filter(e=>e.k==='状态');
const maxes = st.map(e=>e.max).sort((a,b)=>a-b);
console.log(`状态行 ${st.length} 条; 峰(ms): 中位 ${maxes[Math.floor(maxes.length/2)]}  p90 ${maxes[Math.floor(maxes.length*0.9)]}  p99 ${maxes[Math.floor(maxes.length*0.99)]}  最大 ${maxes[maxes.length-1]}`);
console.log('\n=== 峰 > 30ms 的状态行 ===');
for (const e of st) if (e.max > 30) {
  console.log(`  ${new Date(e.t+8*3600e3).toISOString().slice(11,19)}  均 ${e.avg}ms  峰 ${e.max}ms`);
}