const fs = require('fs');
const raw = fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log', 'utf8').split(/\r?\n/);
const idx = raw.findIndex(l => l.startsWith('[2026-11-15 15:42:0'));
console.log('=== 原始行（含无时间戳的续行）===');
for (let i = idx; i < idx + 45 && i < raw.length; i++) {
  console.log(String(i).padStart(5) + ': ' + raw[i].slice(0, 130));
}