const fs = require('fs');
const raw = fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log', 'utf8').split(/\r?\n/);
// 取一个 38 行的爆发窗口，看内容
const want = '2026-11-15 15:42:0';
console.log('=== 15:42:0x 窗口的 Lua 行（前 42 条）===');
let n = 0;
for (const l of raw) {
  if (l.includes('[Lua]') && l.startsWith('[2026-11-15 15:42:0')) {
    const s = l.replace(/^\[[^\]]+\]\s*\[Lua\]\s*/, '');
    console.log('  ' + s.slice(0, 110));
    if (++n >= 42) break;
  }
}