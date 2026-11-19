const fs = require('fs');
const projPath = process.argv[2], gamePath = process.argv[3];

// key -> 要覆盖的字段
const patch = {
  'gi.skyleak':     { min: 0, max: 1, step: 0.001, decimals: 4 },
  'gi.skyleakdist': { min: 0, max: 10000, step: 50, decimals: 0 },
  'gi.lumenboost':  { decimals: 3 },
  'gi.lumengi':     { decimals: 3 },
  'gi.lumenscene':  { decimals: 3 }
};

function apply(file) {
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  const hit = [];
  for (const g of d.groups || []) for (const x of g.parameters || []) {
    const pt = patch[x.key];
    if (!pt) continue;
    for (const k in pt) x[k] = pt[k];
    hit.push(x.key);
  }
  const text = JSON.stringify(d, null, 2) + "\n";
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, text, 'utf8');
  fs.renameSync(tmp, file);
  return hit.join(',');
}

console.log('project:', apply(projPath));
console.log('game   :', apply(gamePath));
