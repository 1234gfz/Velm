const fs = require('fs');
const luaparse = require('luaparse');
const path = process.argv[2];
const src = fs.readFileSync(path, 'utf8');
try {
  luaparse.parse(src, { luaVersion: '5.3', scope: false, comments: false });
  console.log('OK ' + src.split('\n').length + ' lines  ' + path);
  process.exit(0);
} catch (e) {
  console.error('LUA SYNTAX ERROR: ' + e.message);
  process.exit(1);
}
