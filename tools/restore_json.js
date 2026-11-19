const fs = require('fs');
const backup = process.argv[2];
const out = process.argv[3];
const data = JSON.parse(fs.readFileSync(backup, 'utf8'));

// 1) 把用户当前已知的雾参数值补回（来自截断前 20:25 的快照）
const patches = {
  'fog.density':    { value: 1,    enabled: false },
  'fog.maxopacity': { value: 1,    enabled: false },
  'fog.start':      { value: 5000, enabled: false },
  'fog.extinction': { value: 0.2,  enabled: true  },
  'fog.heightfall': { value: 0.13, enabled: true  },
  'fog.scatter':    { value: 0.3,  enabled: true  },
  'fog.voldist':    { value: 10000,enabled: false },
  'lfog.visible':   { value: false,enabled: false }
};
for (const g of data.groups) for (const p of (g.parameters || [])) {
  const pt = patches[p.key];
  if (pt) { if ('value' in pt) p.value = pt.value; if ('enabled' in pt) p.enabled = pt.enabled; }
}

// 2) 追加 7 个色调映射参数（若还没有）
const news = [
 {key:"img.filmblackclip",label:"胶片曲线·黑点裁切",type:"float",min:0,max:0.2,step:0.005,default:0,value:0,handler:"pp",target:"FilmBlackClip",hint:"黑场裁切：调大→更黑的暗部被压成纯黑（暗部更硬）。UE/ACES 默认 0。",enabled:false,sub:"色调"},
 {key:"img.filmwhiteclip",label:"胶片曲线·白点裁切",type:"float",min:0,max:0.5,step:0.01,default:0,value:0,handler:"pp",target:"FilmWhiteClip",hint:"白场裁切：调大→最亮处更早被压成纯白（高光更硬）。UE/ACES 默认 0。",enabled:false,sub:"色调"},
 {key:"img.expandgamut",label:"色域扩展（ACES 感）",type:"float",min:0,max:1,step:0.05,default:1.0,value:1.0,handler:"pp",target:"ExpandGamut",hint:"向 ACES 宽色域方向扩展，越大越有电影/ACES 味。UE 默认 1。",enabled:false,sub:"色调"},
 {key:"img.whitetint",label:"白平衡·色调（绿-品红）",type:"float",min:-1,max:1,step:0.05,default:0,value:0,handler:"pp",target:"WhiteTint",hint:"绿-品红轴偏色，负=偏绿，正=偏品红。配合白平衡色温用。",enabled:false,sub:"色调"},
 {key:"img.bluecorrection",label:"蓝光校正",type:"float",min:0,max:1,step:0.05,default:0.6,value:0.6,handler:"pp",target:"BlueCorrection",hint:"UE 默认 0.6。校正蓝色通道高亮表现，一般不用动。",enabled:false,sub:"色调"},
 {key:"img.gradingintensity",label:"调色总强度",type:"float",min:0,max:1,step:0.05,default:1.0,value:1.0,handler:"pp",target:"ColorGradingIntensity",hint:"整体色彩分级作用强度。1=全量，0=不改色。想一键减弱所有调色用它。",enabled:false,sub:"色调"},
 {key:"img.scenecolortint",label:"画面整体染色",type:"color",default:[1.0,1.0,1.0],value:[1.0,1.0,1.0],handler:"pp",target:"SceneColorTint",min:0,max:2,step:0.01,hint:"给整个画面乘一个颜色，1,1,1=不染色。轻调可定整体氛围（暖/冷）。",enabled:false,sub:"色调"}
];
const has = data.groups.some(g => (g.parameters || []).some(p => p.key === 'img.filmblackclip'));
if (!has) {
  for (const g of data.groups) {
    const ps = g.parameters || [];
    const i = ps.findIndex(x => x && x.key === 'img.filmtoe');
    if (i >= 0) { ps.splice(i + 1, 0, ...news); break; }
  }
}

const text = JSON.stringify(data, null, 2) + "\n";
const tmp = out + '.restore-tmp';
fs.writeFileSync(tmp, text, 'utf8');
fs.renameSync(tmp, out);
let n = 0; for (const g of data.groups) n += (g.parameters || []).length;
console.log('restored total params=' + n + ' -> ' + out);
