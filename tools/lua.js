// 真 Lua 5.4 解释器（wasmoon = 官方 Lua 5.4 编译成 WASM，跑在 node 里，无需安装任何东西）
// 用法: node lua.js <script.lua> [args...]
// 说明: 工作目录会切到脚本所在目录，package.path 里加入脚本目录，行为尽量贴近 UE4SS 的 lua 环境。
const fs = require('fs');
const path = require('path');
const { LuaFactory } = require('wasmoon');

(async () => {
    const file = process.argv[2];
    if (!file) { console.error('用法: node lua.js <script.lua> [args...]'); process.exit(2); }
    const abs = path.resolve(file);
    if (!fs.existsSync(abs)) { console.error('找不到文件: ' + abs); process.exit(2); }
    const dir = path.dirname(abs);
    const factory = new LuaFactory();
    const lua = await factory.createEngine({ openStandardLibs: true });
    try {
        // 把脚本目录塞进 package.path，模拟 UE4SS 对每个 mod 的 Scripts 目录的处理
        await lua.doString(`package.path = ${JSON.stringify(dir + '/?.lua')} .. ";" .. ${JSON.stringify(dir + '/?/init.lua')} .. ";" .. package.path`);
        // 传参
        const args = process.argv.slice(3);
        lua.global.set('arg', lua.global.get('arg') || {});
        await lua.doString(`arg = { [0] = ${JSON.stringify(abs)} }`);
        for (let i = 0; i < args.length; i++) {
            await lua.doString(`arg[${i + 1}] = ${JSON.stringify(args[i])}`);
        }
        // 切工作目录
        const old = process.cwd();
        process.chdir(dir);
        const src = fs.readFileSync(abs, 'utf8');
        await lua.doString(src);
        process.chdir(old);
    } catch (e) {
        console.error('LUA ERROR: ' + (e && e.message ? e.message : e));
        process.exit(1);
    } finally {
        lua.global.close();
    }
})();
