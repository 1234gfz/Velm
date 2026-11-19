const fs=require('fs');
const raw=fs.readFileSync('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/UE4SS.log','utf8').split(/\r?\n/);
// 5 秒卡顿是否都紧跟在 LoadMap 之后？
const stall=['15:16:24','15:55:36','15:57:03','15:23:36','15:24:36','15:35:45','15:39:23','15:42:45','16:12:33','16:43:07','16:46:43'];
const loads=[];
for(const l of raw){const m=l.match(/^\[(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})/); if(m&&l.includes('换世界: LoadMap')) loads.push(m[2]);}
console.log('LoadMap 时刻:', loads.join(' '));
console.log('\n卡顿时刻 -> 最近一次 LoadMap 的间隔:');
for(const s of stall){
  const toSec=t=>{const[a,b,c]=t.split(':').map(Number);return a*3600+b*60+c;};
  const prev=loads.filter(x=>toSec(x)<=toSec(s)).pop();
  const gap=prev?(toSec(s)-toSec(prev)):'-';
  console.log(`  ${s}  <- ${prev||'无'}  +${gap}s`);
}