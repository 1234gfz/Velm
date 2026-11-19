const fs = require('fs');
const raw = fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log','utf8').split(/\r?\n/);
console.log('=== 所有面板相关日志 ===');
for (const l of raw) {
  if (l.includes('面板') || l.includes('拉起')) console.log('  ' + l.slice(0,140));
}
console.log('\n=== 所有 换世界 事件 ===');
for (const l of raw) if (l.includes('换世界: LoadMap')) console.log('  ' + l.slice(0,60));