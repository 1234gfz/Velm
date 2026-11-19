const fs = require('fs');
const files = [process.argv[2], process.argv[3]];

function run(file) {
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  let modeAdded = false, skyleakTouched = false;

  for (const g of d.groups || []) {
    const ps = g.parameters || [];
    const i = ps.findIndex(x => x && x.key === 'gi.skyleak');
    if (i >= 0) {
      const x = ps[i];
      x.min = 0; x.max = 3; x.step = 0.001; x.decimals = 4;
      x.modeKey = 'gi.skyleakmode';
      x.hint = '漏光强度。下面「漏光模式」选绝对时，这里是绝对值（0~1，游戏默认 0）；选比例时，这里是「原值 × 本值」，0.5 = 压到一半，1 = 不变。比例模式下原值为 0 的场景（游戏没开漏光）不会被点亮，也不会被强行打开。';
      skyleakTouched = true;
      if (!ps.some(y => y && y.key === 'gi.skyleakmode')) {
        ps.splice(i, 0, {
          key: 'gi.skyleakmode',
          label: '漏光模式',
          type: 'choice',
          default: 'abs',
          value: 'abs',
          options: [
            { label: '绝对（写死一个值）', value: 'abs' },
            { label: '比例（原值 × 百分比）', value: 'ratio' }
          ],
          hint: '决定「天光漏光」按绝对值还是按比例写。比例模式下每个体积各用自己的原值乘百分比，所以游戏没开漏光的场景仍然不亮；切换模式时会先还原再重新采基准，不会累乘。',
          sub: 'Lumen'
        });
        modeAdded = true;
      }
    }
  }

  const text = JSON.stringify(d, null, 2) + "\n";
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, text, 'utf8');
  fs.renameSync(tmp, file);
  return { modeAdded, skyleakTouched };
}

for (const f of files) {
  const r = run(f);
  console.log(f.split('\\').pop() + ' -> modeAdded=' + r.modeAdded + ' skyleak=' + r.skyleakTouched);
}
