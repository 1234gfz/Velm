// 发布前参数表整理：删除废弃/有害参数、隐藏偏门参数、重排分组。
// 幂等：以「原始 pbz_tweaker.json」为输入，输出整理后的参数表。
// 用法：node tools/release_prep.js   （默认处理 ../lua/Velm/pbz_tweaker.json）
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const CFG = process.argv[2] || path.join(ROOT, 'lua', 'Velm', 'pbz_tweaker.json');

// —— 明确删除的参数（废弃/有害）——
const DROP_KEYS = new Set([
  'fog.clone',        // 接管雾（副本模式）—— 废弃且有害
  'fog.freezeuds',    // 冻结 UDS —— 副作用大
  'sky.intensity',    // 天光强度 —— 实测无效
  'gi.indirect',      // 间接光总倍率 —— Lumen 下无效
  'gi.lumengi',       // Lumen 最终聚集质量 —— 是降质量不是美化
  'gi.lumenscene',    // Lumen 场景光照质量 —— 同上
  'cam.fov',          // 相机 FOV —— 切镜头会被覆盖
  'lfog.visible',     // 局部雾团 —— 实测无效果，删除
]);

// —— 顶层调试字段（整段删除）——
const DROP_TOP = ['probe','testHideEasyFog','testMie','testFogRaw','testCloneRaw','testClonePos','testNoHide','testCube'];

// —— 保留但默认隐藏 / 标「进阶」——
const ADVANCED = new Set([
  'img.bloommethod','gi.localexpmode','gi.evmode',
  'gi.lekernel','gi.lehit','gi.lelot','gi.lehits','gi.lelos','gi.calconst','gi.histmax',
]);

// —— tooltip 措辞改中性公开版（去掉第一人称、个人调试记录、★/「你」等主观表述）——
// 只覆盖需要改的项；没列出的保持原 hint。
const HINT_PATCH = {
  'fog.density': '控制整体雾浓度的主控项；100% = 游戏原版。',
  'fog.extinction': '控制体积雾的「厚度 / 吸收」，与雾浓度是两个不同维度，可叠加使用；100% = 原版。',
  'fog.vstart': '体积雾从多少米外才开始出现（原值 0 = 贴脸就有）。调到 20~30 米可退掉房间近处的浓雾、远处照旧。经典雾的「起始距离」管不到体积雾。',
  'gi.lowpct': '调暗画面的主要杠杆。测光时排除最暗的 N% 像素：调大 → 排除更多暗部 → 测光值变亮 → 画面变暗。窗口（highpct − lowpct）别小于 15，否则曝光会抖。',
  'gi.highpct': '测光时排除最亮的 (100−N)% 像素：调大 → 砍掉更多高光尾部 → 画面变亮；调小 → 让高光参与测光 → 画面变暗（高光被压住）。',
  'gi.histmin': '直方图亮度统计的下边界，默认 −8（即 1/256）；低于该值的像素不进直方图。若 MinBrightness 压得很低仍无变化，把这个也往下调（−10、−12）。',
  'gi.locgray': '中间灰的对数偏移：0 = 不变，1 = 2 倍亮，2 = 4 倍亮，−1 = 2 倍暗。官方 UI 范围 ±15；负值影响较小、正值更明显。',
  'gi.ledetail': '1 之外的值才启用局部曝光，一般应保持 1；过大的值容易让画面过曝发白。',
  'gi.lekernel': '用于模糊画面亮度的屏幕百分比。本版引擎该项未生效。',
  'gi.lehit': '局部曝光的高光阈值；数值越低画面越亮、对比越低。官方 UI 下限为 0，实际可负。',
  'gi.lelot': '局部曝光的阴影阈值；效果比高光阈值更明显，数值越低画面越亮，过低会发白。',
  'gi.localexpmode': '局部曝光的算法：0 = 关闭，1 = Bilateral（双边），2 = Gaussian（高斯）。开着局部曝光时，全局曝光的上下限会被局部算法部分抵消。',
  'gi.localexp': '⚠ 已废弃字段（引擎里名字带 _DEPRECATED）。UE5 已把它拆成「高光对比」和「阴影对比」两项，本项调整无反应，仅为兼容保留。',
  'gi.evmode': '原值 0（直方图）。2 = 手动，曝光完全固定、不再忽明忽暗，代价是进暗处就是暗的、不再自动提亮。可设 0 / 1 / 2，2 最激进。',
  'gi.skyleak': '漏光强度。绝对模式 = 直接给值（0~1）；比例模式 = 原值 × 百分比（100 = 不变）。比例模式下原值为 0 的场景不会被点亮，也不会被强行打开。',
};


// —— 目标分组与顺序（group -> subs -> keys）——
const LAYOUT = [
  { name:'雾效', desc:'按百分比缩放游戏原本的雾强度，100% = 游戏原版。', subs:[
    ['整体强度', ['fog.density','fog.maxopacity','fog.start']],
    ['体积雾',   ['fog.extinction','fog.heightfall','fog.scatter','fog.voldist','fog.vstart','fog.vnearfade']],
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
        if (HINT_PATCH[k]) p.hint = HINT_PATCH[k];
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
