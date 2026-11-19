// 给所有 handler=="pp" 的参数补上「三模式」字段：
//   mode   当前模式：abs / ratio / offset（缺省 abs）
//   value  绝对模式的值（原有字段，不动）
//   ratio  比例模式的值，单位 %，0~300（缺省 100）
//   offset 偏移模式的值（缺省 0）
//   origin 比例模式的缩放原点；null 表示这个参数没有可靠原点、不开放比例
//   modes  支持哪些模式（面板据此决定图标菜单里有几项）
//
// 原点判定原则（宁缺勿滥 —— 拿不准就不给比例）：
//   0   = 该参数 0 就是「关闭 / 无效果」
//   1   = 该参数本身是倍率，1 是中性值
//   null= 没有可靠原点（曲线形状、枚举、颜色、哨兵值、区间边界）
const fs = require('fs');

const ORIGIN = {
  // —— 0 = 关闭 / 中性偏移 ——
  'img.bloom': 0,          // BloomIntensity，0 = 无泛光
  'img.ca': 0,             // SceneFringeIntensity，0 = 无
  'img.flare': 0,          // LensFlareIntensity
  'img.grain': 0,          // FilmGrainIntensity
  'img.vignette': 0,       // VignetteIntensity
  'img.mblur': 0,          // MotionBlurAmount
  'gi.skyleak': 0,         // LumenSkylightLeaking，0 = 不补
  'gi.ao': 0,              // AmbientOcclusionIntensity，0 = 无
  'gi.bias': 0,            // AutoExposureBias，0 = 不偏移（EV）
  'gi.locgray': 0,         // LocalExposureMiddleGreyBias，0 = 不偏移
  'gi.lehit': 0,           // LocalExposureHighlightThreshold
  'gi.lelot': 0,           // LocalExposureShadowThreshold
  'img.tonecurve': 0,      // ToneCurveAmount，0 = 不上曲线
  'img.bluecorrection': 0, // 0 = 不校正
  'img.whitetint': 0,      // -1~1，0 = 中性
  // —— 1 = 倍率中性 ——
  'gi.indirect': 1,        // IndirectLightingIntensity
  'gi.lumenboost': 1,      // LumenDiffuseColorBoost
  'gi.localexp': 1,        // LocalExposureContrastScale
  'gi.lehi': 1,            // LocalExposureHighlightContrastScale
  'gi.lelo': 1,            // LocalExposureShadowContrastScale
  'gi.ledetail': 1,        // LocalExposureDetailStrength
  'gi.lehits': 1,          // LocalExposureHighlightThresholdStrength
  'gi.lelos': 1,           // LocalExposureShadowThresholdStrength
  'img.sats': 1,           // ColorSaturationShadows
  'img.sath': 1,           // ColorSaturationHighlights
  'img.conts': 1,          // ColorContrastShadows
  'img.conth': 1,          // ColorContrastHighlights
  'img.filmslope': 1,      // FilmSlope，1 = 不偏
};

const COLOR = new Set(['img.scenecolortint', 'img.tintShadow', 'img.tintHigh']);

function patch(file) {
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  let ratioCnt = 0, noRatio = 0, dropped = 0;

  // 旧的独立 choice 参数（gi.skyleakmode）的值迁移到引用者身上，然后删掉它
  const oldMode = {};
  for (const g of d.groups || []) for (const p of g.parameters || [])
    if (p.key === 'gi.skyleakmode') oldMode['gi.skyleak'] = p.value || 'abs';

  for (const g of d.groups || []) {
    g.parameters = (g.parameters || []).filter(p => {
      if (p.key === 'gi.skyleakmode') { dropped++; return false; }
      return true;
    });
    for (const p of g.parameters) {
      if (p.handler !== 'pp') continue;
      if (p.modeKey) delete p.modeKey;

      const isEnum = /Method$/.test(p.target || '');
      const isColor = COLOR.has(p.key) || Array.isArray(p.value);
      const hasOrigin = Object.prototype.hasOwnProperty.call(ORIGIN, p.key);

      let modes;
      if (isEnum || isColor) modes = ['abs'];
      else if (hasOrigin) modes = ['abs', 'ratio', 'offset'];
      else modes = ['abs', 'offset'];

      p.mode = oldMode[p.key] || 'abs';
      if (p.mode === 'ratio' && !hasOrigin) p.mode = 'abs';
      if (p.ratio === undefined) p.ratio = 100;
      if (p.offset === undefined) p.offset = 0;
      p.origin = hasOrigin ? ORIGIN[p.key] : null;
      p.modes = modes;

      if (hasOrigin) ratioCnt++; else noRatio++;
    }
  }

  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(d, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, file);
  console.log(`${file.split('\\').pop()}  可比例=${ratioCnt}  无比例=${noRatio}  删旧choice=${dropped}`);
}

for (const f of process.argv.slice(2)) patch(f);
