-- 用真 Lua 5.4 跑离线行为测试（不需要 node / fengari）。
-- 用法: lua.exe run_sim.lua
-- 它会自己在磁盘上收集 PBZFog 的所有模块源码塞进 MODULES，再加载 sim_test.lua。
local SCRIPTS = "E:/MSHY_Workbench/其他/影之刃零插件/lua/PBZFog/Scripts"
local CFG     = "E:/MSHY_Workbench/其他/影之刃零插件/lua/PBZFog/pbz_tweaker.json"

-- 收集模块：文件名相对于 SCRIPTS，用 . 代替 /
MODULES = {}
local function addfile(dir, base)
    local p = io.popen('dir /b /s "' .. dir .. '" 2>nul')
    for line in p:lines() do
        line = line:gsub("\r$", "")
        if line:sub(-4) == ".lua" then
            local rel = line:sub(#SCRIPTS + 2):gsub("\\", "/")
            local modname = rel:sub(1, -5):gsub("/", ".")
            local f = io.open(line, "rb")
            MODULES[modname] = f:read("a")
            f:close()
        end
    end
    p:close()
end
addfile(SCRIPTS)

do
    local f = io.open(CFG, "rb")
    CFG_TEXT = f:read("a")
    f:close()
end

dofile("E:/MSHY_Workbench/其他/影之刃零插件/tools/sim_test.lua")
