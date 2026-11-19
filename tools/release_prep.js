// 发布前参数表整理：删除废弃/有害参数、隐藏偏门参数、重排分组。
// 幂等：以「原始 pbz_tweaker.json」为输入，输出整理后的参数表。
// 用法：node tools/release_prep.js   （默认处理 ../lua/PBZFog/pbz_tweaker.json）
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const CFG = process.argv[2] || path.join(ROOT, 'lua', 'PBZFog', 'pbz_tweaker.json');

// —— 明确删除的参数（废弃/有害）——
const DROP_KEYS = new Set([
  'fog.clone',        // 接管雾（副本模式）—— 废弃且有害
  'fog.freezeuds',    // 冻结 UDS —— 副作用大
  'sky.intensity',    // 天光强度 —— 实测无效
  'gi.indirect',      // 间接光总倍率 —— Lumen 下无效
  'gi.lumengi',       // Lumen 最终聚集质量 —— 是降质量不是美化
  'gi.lumenscene',    // Lumen 场景光照质量 —— 同上
  'cam.fov',          // 相机 FOV —— 切镜头会被覆盖
]);

// —— 顶层调试字段（整段删除）——
const DROP_TOP = ['probe','testHideEasyFog','testMie','testFogRaw','testCloneRaw','testClonePos','testNoHide','testCube'];

// —— 保留但默认隐藏 / 标「进阶」——
const ADVANCED = new Set([
  'img.bloommethod','gi.localexpmode','gi.evmode',
  'gi.lekernel','gi.lehit','gi.lelot','gi.lehits','gi.lelos','gi.calconst','gi.histmax',
]);

// —— 目标分组与顺序（group -> subs -> keys）——
const LAYOUT = [
  { name:'雾效', desc:'按百分比缩放游戏原本的雾强度，100% = 游戏原版。', subs:[
    ['整体强度', ['fog.density','fog.maxopacity','fog.start']],
    ['体积雾',   ['fog.extinction','fog.heightfall','fog.scatter','fog.voldist','fog.vstart','fog.vnearfade']],
  ]},
  { name:'局部雾团', desc:'场景里小范围飘动的雾是 Niagara 粒子（雾门、BOSS 房那种），可以整组关掉', subs:[
    ['', ['lfog.visible']],
  ]},
  { name:'画面', desc:'直接写后处理体积的数值，绝对值不是倍率；改动要按右下角「应用」', subs:[
    ['泛光', ['img.bloom','img.bloomthr','img.bloomsize','img.bloommethod','img.bloompfmax']],
    ['其他', ['img.ca','img.flare','img.grain','img.vignette','img.mblur']],
  ]},
  { name:'光照与色调', desc:'曝光 / 局部曝光 / 色调映射 / 调色 / 环境光。这些参数依赖画质档位，档位低时可能不生效。', subs:[
    ['白平衡',        ['gi.temp']],
    ['阳光',          ['sun.intensity']],
    ['曝光与测光',    ['gi.bias','gi.evmin','gi.evmax','gi.evup','gi.evdown','gi.evmode','gi.lowpct','gi.highpct','gi.histmin','gi.histmax','gi.calconst']],
    ['局部曝光',      ['gi.localexp','gi.locgray','gi.lehi','gi.lelo','gi.ledetail','gi.leblend','gi.lekernel','gi.lehit','gi.lelot','gi.localexpmode','gi.lehits','gi.lelos']],
    ['色调映射 / 胶片',['img.tonecurve','img.filmslope','img.filmshoulder','img.filmtoe','img.filmblackclip','img.filmwhiteclip','img.expandgamut','img.gradingintensity']],
    ['色彩调色',      ['img.whitetint','img.bluecorrection','img.scenecolortint','img.tintShadow','img.tintHigh','img.sats','img.sath','img.conts','img.conth']],
    ['环境光 / 遮蔽', ['gi.skyleak','gi.skyleakdist','gi.lumenboost','gi.ao']],
  ]},
  { name:'分辨率（窗口）', desc:'引擎的分辨率接口被这游戏架空了，所以直接改窗口尺寸，UE 会自己重建画面。不受右上角总开关影响。', subs:[
    ['', ['res.mode']],
  ]},
];

function main() {
  const raw = fs.readFileSync(CFG, 'utf8');
  const data = JSON.parse(raw);

  // 建索引
  const byKey = new Map();
  for (const g of data.groups || [])
    for (const p of g.parameters || []) {
      if (byKey.has(p.key)) throw new Error('重复 key: ' + p.key);
      byKey.set(p.key, p);
    }
  const originalKeys = new Set(byKey.keys());

  const layoutKeys = new Set();
  const newGroups = [];
  const missing = [];
  for (const gdef of LAYOUT) {
    const params = [];
    for (const [sub, keys] of gdef.subs) {
      for (const k of keys) {
        if (layoutKeys.has(k)) throw new Error('layout 里重复 key: ' + k);
        layoutKeys.add(k);
        const src = byKey.get(k);
        if (!src) { missing.push(k); continue; }
        const p = Object.assign({}, src);   // 保留所有原字段
        p.sub = sub;
        if (ADVANCED.has(k)) p.advanced = true; else delete p.advanced;
        if (k === 'res.mode') p.ignoreMaster = true; else delete p.ignoreMaster;
        params.push(p);
      }
    }
    newGroups.push({ name: gdef.name, desc: gdef.desc, parameters: params });
  }

  // 校验：原始 key = 删除集 ∪ layout 集
  const dropped = [...originalKeys].filter(k => DROP_KEYS.has(k));
  const extra   = [...originalKeys].filter(k => !DROP_KEYS.has(k) && !layoutKeys.has(k));
  const notDroppedButMissing = [...DROP_KEYS].filter(k => originalKeys.has(k) === false);

  // 组装新顶层（保留其它字段，删调试字段）
  const out = {};
  for (const k of Object.keys(data)) {
    if (DROP_TOP.includes(k)) continue;
    if (k === 'groups') { out.groups = newGroups; continue; }
    out[k] = data[k];
  }

  // 备份 + 写回
  fs.writeFileSync(CFG + '.bak-prep', raw, 'utf8');
  fs.writeFileSync(CFG, JSON.stringify(out, null, 2) + '\n', 'utf8');

  console.log('=== release_prep 完成 ===');
  console.log('原始参数:', originalKeys.size, ' 删除:', dropped.length, ' 保留:', [...layoutKeys].length);
  console.log('删除的 key:', dropped.join(', '));
  console.log('布局里找不到的 key（缺失）:', missing.length ? missing.join(', ') : '无');
  console.log('原始里未被处理(既没删也没排进 layout)的 key:', extra.length ? extra.join(', ') : '无');
  console.log('要删但原始里本来就没有:', notDroppedButMissing.length ? notDroppedButMissing.join(', ') : '无');
  console.log('分组数:', newGroups.length);
  for (const g of newGroups) {
    console.log('  [' + g.name + '] ' + g.parameters.length + ' 项  (subs: ' +
      [...new Set(g.parameters.map(p => p.sub))].join(' / ') + ')');
  }
  const adv = [...layoutKeys].filter(k => byKey.get(k) && ADVANCED.has(k));
  console.log('标进阶(默认隐藏):', adv.join(', '));
}

main();
