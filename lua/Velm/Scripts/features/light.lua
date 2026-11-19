-- 平行光探测 / 还原通道。
--
-- 用途：调光的时候需要知道「场景里有几个方向光、哪个是主光、原始强度是多少」。
-- 触发方式是往 E:/PBZ_light_probe.txt 写命令，主循环发现文件就执行并删掉它。
-- 故意不用参数表里的开关 —— 那会改用户的参数文件。
--
-- 命令：
--   (空)      只列出当前状态，不修改
--   restore   全部还原到原始值，并清空引擎基准
--   1..n      把第 n 个方向光的强度翻倍（原始值为 0 的给 10.0，否则乘 2 看不出效果）
--
-- 原始值落盘而不是放内存：热重载会清空 Lua 状态，只放变量里的话重载后就找不回了。

local log     = require("core.log")
local ue      = require("core.ue")
local env     = require("core.env")
local objects = require("core.objects")
local engine  = require("params.engine")

local light = {}

local state = nil   -- { comp, orig, target } —— 主循环用它定期复查是否被游戏抢回
local tick = 0

function light.state()
    return state
end

function light.bumpTick()
    tick = tick + 1
    return tick
end

local function loadOrig()
    local f = io.open(env.LIGHT_ORIG, "r")
    if not f then return nil end
    local txt = f:read("*a") or ""
    f:close()
    local t = {}
    for line in string.gmatch(txt, "[^\r\n]+") do
        local idx, val = string.match(line, "^(%d+)=([%-%d%.eE]+)$")
        if idx and val then t[tonumber(idx)] = tonumber(val) end
    end
    if next(t) == nil then return nil end
    return t
end

local function saveOrig(t)
    local f = io.open(env.LIGHT_ORIG, "w")
    if not f then return end
    for i = 1, #t do
        if t[i] then f:write(string.format("%d=%.6f\n", i, t[i])) end
    end
    f:close()
end

-- 主循环调用：文件存在就执行，执行完删掉。
function light.poll()
    local mf = io.open(env.LIGHT_PROBE, "r")
    if not mf then return end
    local cmd = (mf:read("*a") or ""):gsub("%s", "")
    mf:close()
    os.remove(env.LIGHT_PROBE)
    local ok, err = pcall(light.probe, cmd)
    if not ok then log.info("光照出错: " .. tostring(err)) end
end

function light.probe(cmd)
    cmd = string.lower(string.gsub(tostring(cmd or ""), "%s", ""))
    log.info("光照：开始探测，命令=" .. (cmd == "" and "(空)" or cmd))

    local arr = objects.get("DirectionalLightComponent")
    local n = #arr
    log.info("光照：DirectionalLightComponent 实例数 = " .. tostring(n))
    if n == 0 then return end

    local comps = {}
    for i = 1, n do
        local c = arr[i]
        if ue.alive(c) then
            comps[#comps + 1] = { comp = c, now = tonumber(ue.readNum(c, "Intensity")) or 0 }
        end
    end
    if #comps == 0 then log.info("光照：全部失效"); return end

    -- 原始值：文件里没有就现在记（此时还没被我们改过，是干净的）
    local orig = loadOrig()
    if not orig then
        orig = {}
        for i = 1, #comps do orig[i] = comps[i].now end
        saveOrig(orig)
        log.info("光照：首次探测，已记录原始值")
    end

    for i = 1, #comps do
        local diff = ""
        if orig[i] and math.abs(comps[i].now - orig[i]) > 1e-4 then
            diff = string.format("  ← 被改过（原始 %.3f）", orig[i])
        end
        log.info(string.format("光照：  [%d] 当前=%.3f  原始=%s%s",
            i, comps[i].now, orig[i] and string.format("%.3f", orig[i]) or "?", diff))
    end

    if cmd == "" then
        log.info("光照：只查看，未修改")
        return
    end

    if cmd == "restore" then
        for i = 1, #comps do
            if orig[i] then
                pcall(function() comps[i].comp:SetIntensity(orig[i]) end)
                local back = ue.readNum(comps[i].comp, "Intensity")
                log.info(string.format("光照：还原 [%d] → %.3f（读回 %s）",
                    i, orig[i], tostring(back or "?")))
            end
        end
        -- 关键：把引擎参数的基准也清掉。
        -- 只还原数值、不清基准的话，engine 下一轮会按旧基准再写回去，等于白还原。
        engine.revert("sun.intensity")
        light.state = nil
        log.info("光照：全部还原完成，引擎基准已清空")
        return
    end

    local idx = tonumber(cmd)
    if not idx or idx < 1 or idx > #comps then
        log.info("光照：命令无法识别（可用：空 / restore / 1.." .. #comps .. "）")
        return
    end

    local base = orig[idx] or comps[idx].now
    -- 原始值是 0 的组件（未启用）给一个明显能看见的值，否则乘 2 还是 0
    local tgt
    if base < 0.01 then
        tgt = 10.0
    else
        tgt = base * 2
    end
    pcall(function() comps[idx].comp:SetIntensity(tgt) end)
    local after = ue.readNum(comps[idx].comp, "Intensity")
    log.info(string.format("光照：[%d] %.3f → %.3f（读回 %s）", idx, base, tgt, tostring(after or "?")))

    state = { comp = comps[idx].comp, orig = base, target = tgt }
end

-- 复查：改完的强度是否被游戏抢回
function light.recheck()
    if not state then return end
    local ok, v = pcall(function() return state.comp.Intensity end)
    log.info(string.format("光照复查：Intensity = %s（我们写的 %.4f，原始 %.4f）",
        tostring(ok and v or "?"), state.target, state.orig))
end

return light
