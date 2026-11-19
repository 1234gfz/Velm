const fs = require('fs');
const log = fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log', 'utf8').split(/\r?\n/);
// 状态行形如: [2026-11-15 15:15:38.7903307] [Lua] [PBZ] 状态: ...
const ts = [];
for (const l of log) {
  if (l.includes('[PBZ] 状态')) {
    const m = l.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/);
    if (m) ts.push(new Date(m[1].replace(' ', 'T') + '+08:00').getTime());
  }
}
console.log('状态行数:', ts.length);
const gaps = [];
for (let i = 1; i < ts.length; i++) gaps.push((ts[i] - ts[i-1]) / 1000);
gaps.sort((a,b)=>a-b);
const q = p => gaps[Math.min(gaps.length-1, Math.floor(gaps.length*p))];
console.log(`间隔(秒): 最小 ${gaps[0]}  中位 ${q(0.5)}  p90 ${q(0.9)}  p99 ${q(0.99)}  最大 ${gaps[gaps.length-1]}`);
console.log('\n> 20 秒的间隔（主循环被卡住 / 游戏不在跑）:');
for (let i = 1; i < ts.length; i++) {
  const d = (ts[i] - ts[i-1]) / 1000;
  if (d > 20) {
    const a = new Date(ts[i-1]+8*3600e3).toISOString().slice(11,19);
    const b = new Date(ts[i]+8*3600e3).toISOString().slice(11,19);
    console.log(`  ${a} -> ${b}  ${d.toFixed(0)}s`);
  }
}