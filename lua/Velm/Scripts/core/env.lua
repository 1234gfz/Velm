-- 全部路径的唯一定义处（唯一允许出现「绝对路径」的模块）。
-- 模组目录在运行时从「本文件自身路径」推导，绝不写死盘符/用户名 —— 别人装到任何盘都能用。

local env = {}

-- 从脚本自身路径推导：.../Velm/Scripts/core/env.lua  ->  .../Velm/
local function deriveModDir()
    local src
    pcall(function()
        if type(debug) == "table" and debug.getinfo then
            src = debug.getinfo(1, "S").source
        end
    end)
    local d
    if type(src) == "string" then
        d = src:match("^@(.*[/\\])")            -- .../Scripts/core/
    end
    if not d and package and package.searchpath then
        local p = package.searchpath("core.env", package.path)
        if type(p) == "string" then d = p:match("^(.*[/\\])") end
    end
    if not d then return nil end
    d = d:gsub("\\", "/")
    -- .../Scripts/core/ -> .../Scripts/ -> .../Velm/
    return (d:gsub("core/$", ""):gsub("Scripts/$", ""))
end

local function normalizeDir(d)
    if type(d) ~= "string" or d == "" then return nil end
    d = d:gsub("\\", "/")
    if d:sub(-1) ~= "/" then d = d .. "/" end
    return d
end

-- 允许外部（离线测试 / 特殊部署）通过全局覆盖模组目录；否则运行时从脚本路径推导。
local modDir = normalizeDir(rawget(_G, "PBZFOG_MODDIR")) or normalizeDir(deriveModDir())
if not modDir then
    error("Velm: 无法从脚本路径推导模组目录（需要 debug.getinfo 或 package.searchpath）")
end
env.MODDIR = modDir                         -- 以 / 结尾

env.CFG       = env.MODDIR .. "pbz_tweaker.json"
env.PPFILE    = env.MODDIR .. "pbz_pporig.json"
env.HEARTBEAT = env.MODDIR .. "panel_heartbeat.txt"
env.REV       = env.MODDIR .. "pbz_rev.txt"

-- 面板（WPF）随模组一起分发：Velm/PBZTweaker/PBZTweaker.exe
env.TWEAKER   = env.MODDIR .. "PBZTweaker/PBZTweaker.exe"

-- 运行时状态 / 高级调试通道（都放在模组目录内，不污染系统盘根目录）
env.ENG_STATE   = env.MODDIR .. "pbz_engine_state.txt"
env.LIGHT_ORIG  = env.MODDIR .. "pbz_light_orig.txt"
env.LIGHT_PROBE = env.MODDIR .. "pbz_light_probe.txt"
env.FOGDIAG     = env.MODDIR .. "pbz_fogdiag.txt"

return env
