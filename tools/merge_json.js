const fs = require('fs');
const projPath = process.argv[2], gamePath = process.argv[3];
const proj = JSON.parse(fs.readFileSync(projPath, 'utf8'));
const game = JSON.parse(fs.readFileSync(gamePath, 'utf8'));

// 收集游戏版已有 key
const gk = new Set();
for (const g of game.groups || []) for (const x of g.parameters || []) gk.add(x.key);

function findGroupBySub(sub) {
  for (const g of game.groups || []) {
    if ((g.parameters || []).some(x => x && x.sub === sub)) return g;
  }
  return null;
}

const added = [];
for (const pg of proj.groups || []) {
  for (const x of pg.parameters || []) {
    if (gk.has(x.key)) continue;
    let g = findGroupBySub(x.sub);
    if (!g) { g = { title: pg.title, parameters: [] }; (game.groups = game.groups || []).push(g); }
    g.parameters = g.parameters || [];
    // 插到同 sub 的最后一个参数后面
    let insertAt = g.parameters.length;
    for (let i = g.parameters.length - 1; i >= 0; i--) { if (g.parameters[i].sub === x.sub) { insertAt = i + 1; break; } }
    g.parameters.splice(insertAt, 0, x);
    gk.add(x.key);
    added.push(x.key);
  }
}
for (const k of ['version', 'title', 'hotkey']) if (proj[k] !== undefined) game[k] = proj[k];

const text = JSON.stringify(game, null, 2) + "\n";
const tmp = gamePath + '.merge-tmp';
fs.writeFileSync(tmp, text, 'utf8');
fs.renameSync(tmp, gamePath);
let n = 0; for (const g of game.groups) n += (g.parameters || []).length;
console.log('added=[' + added.join(',') + '] total=' + n);
