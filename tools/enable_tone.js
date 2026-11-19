const fs = require('fs');
const p = process.argv[2];
const d = JSON.parse(fs.readFileSync(p, 'utf8'));
const touch = ['img.tonecurve', 'img.filmslope', 'img.filmshoulder', 'img.filmtoe'];
const found = [];
for (const g of d.groups) for (const x of (g.parameters || [])) {
  if (touch.includes(x.key)) { x.enabled = true; found.push(x.key + '=' + x.value); }
}
const text = JSON.stringify(d, null, 2) + "\n";
const tmp = p + '.tmp';
fs.writeFileSync(tmp, text, 'utf8');
fs.renameSync(tmp, p);
console.log('enabled: ' + found.join(', '));
