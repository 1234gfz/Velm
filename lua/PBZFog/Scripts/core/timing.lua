-- 墙钟时间 + 卡顿检测。
--
-- 为什么需要独立一层：主循环靠 LoopInGameThreadWithDelay(200, ...) 驱动。
-- 它保证「至少隔 200ms」，但**不保证「最多 200ms」** —— 游戏线程忙的时候
-- 回调会被推迟，可能好几秒才轮到一次。这时候如果还继续下发参数，就是在
-- 游戏已经卡住的伤口上再撒盐：每写一个属性都要 MarkRenderStateDirty，
-- 会让本来就喘不过气的渲染线程雪上加霜。
--
-- ★ 为什么不能用 os.clock()
--   实测（Lua 5.4，纯睡眠 3 秒不耗 CPU）：os.clock 只涨 0.339 秒。
--   它是**进程 CPU 时间**，不是墙钟。游戏卡住时多半在等 GPU / 等 IO，
--   CPU 时间是静止的，os.clock 完全看不出来 —— 曾经据此误判过一整轮。
--
-- 所以优先用引擎自己的墙钟：
--   GameplayStatics::GetRealTimeSeconds(WorldContextObject)   [BlueprintPure]
-- 拿不到才退回 os.time()（1 秒粒度，阈值相应放宽，见 stallThreshold）。

local log = require("core.log")
local ue  = require("core.ue")

local timing = {}

-- ---------------------------------------------------------------- 时间来源

local gsRef    = nil
local gsTried  = false
local source   = nil     -- "engine" / "ostime"

local function gameplayStatics()
    if gsTried then return gsRef end
    gsTried = true
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok and obj and ue.alive(obj) then
        gsRef = obj
    end
    return gsRef
end

-- 当前墙钟秒数（浮点，引擎路径有亚毫秒精度）。
function timing.now()
    local g = gameplayStatics()
    if g then
        local ctx = ue.gi() or ue.pc()
        if ctx then
            local ok, v = pcall(function() return g:GetRealTimeSeconds(ctx) end)
            if ok and type(v) == "number" and v > 0 then
                if source ~= "engine" then
                    source = "engine"
                    log.once("timing:engine",
                        "计时源: GameplayStatics::GetRealTimeSeconds（墙钟，可检测卡顿）")
                end
                return v
            end
        end
    end
    if source ~= "ostime" then
        source = "ostime"
        log.once("timing:ostime",
            "计时源: os.time（1 秒粒度，卡顿阈值放宽到 2 秒）")
    end
    return os.time()
end

function timing.source()
    return source or "?"
end

-- 卡顿判定阈值（秒）。
-- 引擎墙钟能测到亚秒，0.5 秒就是明显的卡顿（正常一轮 0.2 秒）。
-- os.time 只有整秒，设 0.5 会把「正常跨过一秒边界」误判成卡顿，所以放宽到 2 秒。
local BASE_THRESHOLD = 0.5

-- ★ 为什么还需要「相对基线」：
--   实机第一版用的是绝对阈值 0.5 秒，跑出来一个问题 —— 打 BOSS 时游戏本来就
--   持续掉帧，每轮都可能 >0.5 秒。那样每一轮都被判成「卡顿」，冻结 15 轮后
--   下一轮又立刻判卡顿，形成死循环：插件在整场战斗里一次都不跑。
--   结果就是「换图后参数永远不生效」，比卡顿更糟。
--
--   所以判据改成「这一轮明显比最近的常态更慢」，而不是「这一轮慢」：
--   维持最近若干轮 dt 的中位数作为基线，超过基线 3 倍才算异常卡顿。
--   持续慢的时候基线自己会升上去，插件就能恢复工作。
local HISTORY_N = 9
local history = {}       -- 最近 N 轮的 dt（环形，只用于求中位数）

local function medianOf(arr)
    local n = #arr
    if n == 0 then return nil end
    local t = {}
    for i = 1, n do t[i] = arr[i] end
    table.sort(t)
    if n % 2 == 1 then return t[(n + 1) // 2] end
    return (t[n // 2] + t[n // 2 + 1]) / 2
end

-- 记录一轮的间隔，并判断它是否算「异常卡顿」。
-- 返回 true 表示这一轮明显慢于常态，应当冻结。
function timing.isStall(dt)
    if not dt or dt <= 0 then return false end

    -- 基线只统计「正常轮」，避免把卡顿本身算进基线里（否则一次 3 秒卡顿
    -- 会把基线抬高，后面真的卡了反而判不出来）。
    local base = medianOf(history)
    local slow = false
    if base and base > 0 then
        slow = dt > math.max(BASE_THRESHOLD, base * 3)
    else
        slow = dt > BASE_THRESHOLD
    end

    if not slow then
        history[#history + 1] = dt
        if #history > HISTORY_N then table.remove(history, 1) end
    end

    return slow
end

function timing.stallThreshold()
    return (source == "engine") and BASE_THRESHOLD or 2.0
end

-- ---------------------------------------------------------------- 间隔测量

local lastAt = nil

-- 记录一次心跳，返回距上次的间隔（秒）。
-- 第一次调用（或刚 invalidate 过）返回 nil。
function timing.tick()
    local now = timing.now()
    local dt  = nil
    if lastAt then dt = now - lastAt end
    lastAt = now
    return dt
end

-- 换世界后重置：新的 World 时间轴可能从头算，不清会得到一个负的或巨大的间隔。
function timing.invalidate()
    lastAt = nil
    history = {}
end

return timing
