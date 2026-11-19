-- 过场动画（cutscene）检测探针。
--
-- 目的：目前不知道这个游戏用什么信号才可靠地表示「正在放过场动画」。
-- 与其猜，不如先把候选信号全部采下来，等真的过场时看哪个变了。
--
-- 已知事实（来自 exe 字符串 + SDK dump）：
--   · 过场由 Flow 图节点 UPlayLevelSequence_C 驱动，字段有 SequencerActor /
--     SequencePlayer / DisableInput / HideUI
--   · 过场前有 UPreloadLevelSequence_C，带 BlackDuraingPreload / LoadVT / LoadVTComplete
--   · exe 里有枚举 EPBZCineVTState::{Preloading, Preloaded, Playing}
--     —— 说明游戏自己就有「过场状态机」，还专门为过场预加载虚拟纹理
--   · 但上面这些类都是蓝图类（_C 后缀），不在 exe 的反射表里，
--     FindFirstOf("LevelSequencePlayer") 之类大概率拿不到
--
-- 所以这里对每个候选信号都单独 pcall，采不到就记 "ERR"，绝不因为一个信号
-- 失败影响其它信号，也绝不影响主循环。
--
-- 采样策略（性能优先）：
--   · 每轮只读两个便宜的引擎函数（GetRealTimeSeconds / GetWorldDeltaSeconds）
--   · FindAllOf 这类全场景扫描只在「检测到卡顿」或「每 30 秒一次」时才做
--   · 只在状态可能变化时打日志，不刷屏

local log    = require("core.log")
local ue     = require("core.ue")
local timing = require("core.timing")

local probe = {}

-- ---------------------------------------------------------------- 候选类名

-- 全部用 pcall 试，谁拿得到就是谁。顺序按「最可能是过场标志」排。
local CANDIDATE_CLASSES = {
    "LevelSequenceActor",          -- 过场播放器本体（标准 UE 类）
    "LevelSequencePlayer",         -- 播放器（标准 UE 类）
    "MovieSceneSequencePlayer",    -- 上面那个的父类
    "MatineeActor",                -- 老式过场
    "WBP_FlowSequencer_C",         -- 本游戏的过场专用 UI（含跳过按钮）
    "WB_BlackScreen_C",            -- 过场/加载黑屏
    "PlayLevelSequence_C",         -- Flow 节点本体（如果是 UObject 可能拿不到）
}

local classOk = {}       -- 类名 -> true(能查到) / false(查不到) / nil(没试过)

-- ---------------------------------------------------------------- 状态

local lastSample   = nil
local lastExpensive = 0
local EXPENSIVE_INTERVAL = 30      -- 秒

local lastLoggedSig = nil          -- 上次打日志时的「信号指纹」，变了才打

-- ---------------------------------------------------------------- 便宜信号

local gsRef, gsTried = nil, false

local function gameplayStatics()
    if gsTried then return gsRef end
    gsTried = true
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok and obj and ue.alive(obj) then gsRef = obj end
    return gsRef
end

-- 读一个 GameplayStatics 的纯函数（都是 BlueprintPure + WorldContext）。
local function gsCall(fnName)
    local g = gameplayStatics()
    if not g then return nil end
    local ctx = ue.gi() or ue.pc()
    if not ctx then return nil end
    local ok, v = pcall(function() return g[fnName](g, ctx) end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- ---------------------------------------------------------------- 相机信号

-- 过场时相机通常会被切到过场专用 actor 上。PlayerCameraManager 在反射表里，
-- 但 ViewTarget 是个结构体，能不能读到 Target 字段要看这个 build 的实现。
local function cameraTargetName()
    local pcm = FindFirstOf("PlayerCameraManager")
    if not pcm or not ue.alive(pcm) then return nil, "no-pcm" end

    -- 路径 1：ViewTarget 结构体的 Target 字段
    local ok1, vt = pcall(function() return pcm:GetPropertyValue("ViewTarget") end)
    if ok1 and vt then
        local ok2, tgt = pcall(function() return vt.Target end)
        if ok2 and tgt then
            local ok3, nm = pcall(function() return tgt:GetFullName() end)
            if ok3 and type(nm) == "string" and #nm > 0 then
                return nm, "ViewTarget.Target"
            end
        end
    end

    -- 路径 2：直接问相机「现在看的 actor」（部分版本有这个方法）
    local ok4, who = pcall(function() return pcm:GetViewTarget() end)
    if ok4 and who then
        local ok5, nm2 = pcall(function() return who:GetFullName() end)
        if ok5 and type(nm2) == "string" and #nm2 > 0 then
            return nm2, "GetViewTarget"
        end
    end

    return nil, "unreadable"
end

-- ---------------------------------------------------------------- 贵信号

local function countClass(cls)
    if classOk[cls] == false then return nil end
    local ok, arr = pcall(FindAllOf, cls)
    if not ok then
        if classOk[cls] == nil then
            classOk[cls] = false
            log.once("probe:cls:" .. cls, "探针: 类 " .. cls .. " 查不到（跳过）")
        end
        return nil
    end
    classOk[cls] = true
    if type(arr) ~= "table" then return 0 end
    local n = 0
    for i = 1, #arr do
        if ue.alive(arr[i]) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------- 采样

-- 每次卡顿时调用：把完整信号快照写进日志。
-- 这是最关键的采样点 —— 卡顿和过场高度相关，卡的那一刻最能说明问题。
function probe.onStall(dt)
    local parts = {}

    local rt  = timing.now()
    local gt  = gsCall("GetTimeSeconds")
    local wdt = gsCall("GetWorldDeltaSeconds")
    parts[#parts + 1] = string.format("卡顿 %.2fs", dt or -1)
    parts[#parts + 1] = "rt=" .. string.format("%.2f", rt)
    if gt  then parts[#parts + 1] = string.format("gt=%.2f", gt)  else parts[#parts + 1] = "gt=ERR" end
    if wdt then parts[#parts + 1] = string.format("帧时间=%.0fms", wdt * 1000) else parts[#parts + 1] = "帧时间=ERR" end

    local camNm, camSrc = cameraTargetName()
    if camNm then
        parts[#parts + 1] = "相机=" .. (string.match(camNm, "([%w_]+)$") or camNm)
    else
        parts[#parts + 1] = "相机=ERR/" .. tostring(camSrc)
    end

    local clsParts = {}
    for _, cls in ipairs(CANDIDATE_CLASSES) do
        local n = countClass(cls)
        if n ~= nil then
            clsParts[#clsParts + 1] = cls .. "=" .. n
        end
    end
    if #clsParts > 0 then
        parts[#parts + 1] = "类[" .. table.concat(clsParts, " ") .. "]"
    end

    log.info("探针(卡顿): " .. table.concat(parts, " | "))
    lastExpensive = rt
end

-- 每轮调用（便宜）。返回当前「疑似过场」的判定，供主循环参考。
function probe.tick(dt)
    local rt = timing.now()

    -- 便宜信号每轮都采
    local gt  = gsCall("GetTimeSeconds")
    local wdt = gsCall("GetWorldDeltaSeconds")

    -- 贵信号：距上次超过 30 秒才做一次，避免拖累帧率
    local counts = nil
    if (rt - lastExpensive) >= EXPENSIVE_INTERVAL then
        lastExpensive = rt
        counts = {}
        for _, cls in ipairs(CANDIDATE_CLASSES) do
            counts[cls] = countClass(cls)
        end
    end

    local camNm = cameraTargetName()

    -- 组装指纹：只在这些值「变化」时打日志
    local sig = table.concat({
        camNm or "-",
        counts and "C" or "-",
    }, "|")

    if counts and sig ~= lastLoggedSig then
        lastLoggedSig = sig
        local cp = {}
        for _, cls in ipairs(CANDIDATE_CLASSES) do
            if counts[cls] ~= nil then cp[#cp + 1] = cls .. "=" .. counts[cls] end
        end
        log.info(string.format("探针(周期): 相机=%s | 帧时间=%s | %s",
            camNm and (string.match(camNm, "([%w_]+)$") or camNm) or "ERR",
            wdt and string.format("%.0fms", wdt * 1000) or "ERR",
            #cp > 0 and table.concat(cp, " ") or "无可用类信号"))
    end

    lastSample = { rt = rt, gt = gt, wdt = wdt, cam = camNm }
    return lastSample
end

-- 换世界后清掉时间基准（新 World 的时间轴可能重算）。
function probe.invalidate()
    lastSample = nil
    lastExpensive = 0
    lastLoggedSig = nil
end

return probe
