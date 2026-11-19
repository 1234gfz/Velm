const fs = require('fs');
const raw = fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log','utf8').split(/\r?\n/);
for (const t of ['15:16:24','15:55:36','15:57:03']) {
  const i = raw.findIndex(l => l.startsWith('[2026-11-15 ' + t.slice(0,5)) && l.includes('峰=' + (t==='15:16:24'?'5968':t==='15:55:36'?'5704':'5538')));
  console.log(`\n===== ${t} 卡了 ${t==='15:16:24'?'5968':t==='15:55:36'?'5704':'5538'}ms，前后各 12 行 =====`);
  if (i < 0) { console.log('  未定位'); continue; }
  for (let k = Math.max(0,i-12); k <= Math.min(raw.length-1, i+3); k++) {
    const mark = k === i ? '>>>' : '   ';
    console.log(mark + ' ' + raw[k].slice(0,125));
  }
}