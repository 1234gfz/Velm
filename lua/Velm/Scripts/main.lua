-- Velm 入口：装配 + 主循环。
--
-- 这是唯一允许创建循环的地方。所有具体逻辑都在模块里，这里只做装配和节拍。
--
-- 老实现 3,238 行，其中 359 行是这个循环加上一堆一次性诊断块
-- （tick==40 / 45 / 60 各跑一段 FindAllOf 全场景扫描）。那些诊断的结论
-- 已经写进 DESIGN.md，代码全部删除 —— 它们每轮都在白占 CPU。
--
-- ★ 循环里必须 return false，不能裸 return。
-- 裸 return 返回 nil，等于告诉 UE4SS「停掉这个循环」。曾经这样把主循环搞死，
-- 表现就是所有参数都不生效、日志里一片空白。

-- ---------------------------------------------------------------- 模块搜索路径

-- require("core.log") 要能解析到 Scripts/core/log.lua。
-- 不写死任何盘符/用户名：UE4SS 会为模组注入搜索路径，这里再基于「本文件所在目录」
-- 追加一次（下面的 debug.getinfo），保证换任何安装位置都能 require 到。
package.path = "./?.lua;./?/init.lua;" .. package.path

-- 再从 debug 信息里补一次（若 UE4SS 暴露了 debug 库），保证移动目录也不会坏。
pcall(function()
    if type(debug) == "table" and debug.getinfo then
        local src = debug.getinfo(1, "S").source
        local dir = src and src:match("^@(.*[/\\])")
        if dir then
            dir = dir:gsub("\\", "/")
            package.path = dir .. "?.lua;" .. dir .. "?/init.lua;" .. package.path
        end
    end
end)

local log   = require("core.log")
local ue    = require("core.ue")
local world = require("core.world")
local timing = require("core.timing")

local engine = require("params.engine")
local schema = require("params.schema")
local fogH   = require("params.handlers.fog")
local ppH    = require("params.handlers.pp")

local hooks  = require("features.hooks")
local panel  = require("features.panel")
local light  = require("features.light")
local probe  = require("features.probe")

-- 换世界时钩子的「上次写入值/原始值」必须清零：
-- 新场景的雾组件是新的，拿旧场景的原始密度当基准会把新场景写歪。
-- 清掉后每帧钩子会重新把「新组件的当前值」当基准读一次，比例自然对上。
world.onNewWorld("hooks", function()
    hooks.forget()
end)

-- 新 World 的时间轴可能从头算，不清会得到一个负的或巨大的间隔，
-- 进而被误判成「卡顿」，白白冻结下发好几轮。
world.onNewWorld("timing", function()
    timing.invalidate()
    probe.invalidate()
end)

local TICK_MS = 200

-- 后处理每轮最多下发几个字段。
-- 一帧写太多结构体会撞渲染线程，但给太少会让后面的参数饿死。
local PP_BUDGET = 3

local tick = 0

-- 计时来源：真机 Lua 有 os.clock（CPU 时间），模拟环境可能没有 → 退化到 os.time。
-- 只为「自证扫描开销」用，取不到精确值也无所谓，绝不能因为缺 os.clock 报错。
local clock = (type(os) == "table" and type(os.clock) == "function") and os.clock or nil
local function nowSec()
    if clock then return clock() end
    if type(os) == "table" and type(os.time) == "function" then return os.time() end
    return 0
end

-- ---------------------------------------------------------------- 性能自测
-- 只在 tick==40 跑一次，用来自证「全场景扫描到底多贵」。
-- 自适应迭代次数：先测一次估单次耗时，再按目标 ~100ms 总量取平均，
-- 避免在慢机器上一次跑几秒把游戏卡住。os.clock 取进程 CPU 时间。
local function bench(name, fn, targetMs)
    local ok, res = pcall(function()
        local t0 = nowSec(); fn(); local one = (nowSec() - t0) * 1000
        local n = math.floor((targetMs or 100) / math.max(one, 0.0001))
        if n < 3 then n = 3 end
        if n > 300 then n = 300 end
        local t1 = nowSec()
        for _ = 1, n do fn() end
        local avg = (nowSec() - t1) * 1000 / n
        return string.format("%s 单次≈%.3fms (重复%d次均值%.3fms)", name, one, n, avg)
    end)
    if ok then log.info("性能基准 " .. res) else log.info("性能基准 " .. name .. " 测得失败") end
end

local perfDone = false
local function runBenchOnce()
    if perfDone then return end
    perfDone = true
    bench("FindAllOf(PostProcessVolume)", function() FindAllOf("PostProcessVolume") end, 60)
    bench("FindAllOf(ExponentialHeightFogComponent)", function() FindAllOf("ExponentialHeightFogComponent") end, 60)
    if ppH.benchRefresh then bench("pp 全量重扫(refresh)", ppH.benchRefresh, 80) end
end

-- 每 tick 的耗时统计。
--
-- ★ 必须说清楚：os.clock() 返回的是**整个进程**的 CPU 时间，不是墙钟。
--   游戏是多线程的，1 秒墙钟里进程可能烧掉 5~8 秒 CPU 时间。
--   所以这里算出来的「峰=5909ms」不代表游戏卡了 5.9 秒 ——
--   它只说明「在这个 10 秒窗口里，进程累计多烧了 5.9 秒 CPU」，
--   那段时间很可能是游戏自己在做流式加载/编译 PSO，Lua 根本没机会跑。
--   曾经据此误判成「插件卡了 6 秒」，白追了一整轮。
--
--   现在只报两个不含歧义的量：
--     cpu  每轮平均消耗的进程 CPU 时间（毫秒）—— 衡量 Lua 侧开销
--     n    这个窗口里主循环实际跑了多少轮 —— 该跑 50 轮（10 秒 / 200ms），
--          明显少于 50 就说明游戏线程被别的东西占住了，与本模块无关
local stepSumMs, stepN = 0, 0

-- 卡顿冻结的剩余轮数。
-- 一旦检测到「这一轮比预期晚了太多」，说明游戏线程正忙（流式加载/编译 PSO/过场），
-- 这时候继续下发参数只会让渲染线程更喘不过气 —— 冻结几轮，等它缓过来。
--
-- 为什么是「冻结轮数」而不是「等下一个 tick」：卡顿往往连续好几轮，
-- 只跳一轮等于没跳（下一轮立刻又写）。
local stallSkip = 0
local STALL_SKIP_TICKS = 15     -- 15 轮 × 200ms ≈ 3 秒

-- 卡顿统计（只用于状态行）
local stallCount, stallMax = 0, 0

-- 一次性诊断的待办标记。
-- ★ 不能再用 `if tick == 40` 这种「只认某一轮」的写法：帧率保底一旦在那一轮
--   触发冻结，这一轮就被跳过了，诊断永远不跑。改成「标记 + 到点就跑」。
local benchPending  = true
local diagPending   = true


local function step()
    local tStep = nowSec()
    tick = tick + 1
    engine.setTick(tick)

    -- ---------------------------------------------------------------- 帧率保底
    -- 必须放在最前面：一旦判定卡顿，这一轮什么都不做，尽早 return 才能尽快
    -- 把游戏线程让回去。
    --
    -- ★ 用墙钟间隔，不用 os.clock：实测 os.clock 是进程 CPU 时间，
    --   纯睡眠 3 秒只涨 0.34 秒，游戏卡在等 GPU 时它完全看不出来。
    --
    -- ★ 判据是「相对基线」不是绝对阈值：打 BOSS 时游戏本来就持续掉帧，
    --   用绝对 0.5 秒会把每一轮都判成卡顿 → 冻结完 15 轮又立刻判卡顿 →
    --   整场战斗插件一次都不跑，比卡顿更糟。详见 core/timing.lua 的注释。
    local dt = timing.tick()
    if timing.isStall(dt) then
        stallCount = stallCount + 1
        if dt > stallMax then stallMax = dt end
        stallSkip = STALL_SKIP_TICKS
        -- 卡顿时刻最有诊断价值：把过场探针的全部信号抓一次快照
        pcall(probe.onStall, dt)
        log.once("stall:first", "检测到卡顿，开始冻结下发（相对基线 3 倍或超过 " ..
            string.format("%.1fs", timing.stallThreshold()) .. "）")
        return false
    end

    if stallSkip > 0 then
        stallSkip = stallSkip - 1
        return false
    end

    -- 面板拉起放在冻结判定之后、其它早退之前。
    -- ★ 为什么在冻结之后：panel.ensure 里的 os.execute 会同步拉起 cmd.exe，
    --   实测能卡 5 秒 —— 在游戏已经卡住的时候干这个是最坏的选择。
    --   代价是「卡顿恰好撞上拉起轮次」时会推迟 12 秒再试，可以接受。
    -- ★ 为什么在其它早退之前：换场景静默期会连续跳轮，放后面会导致面板永远起不来。
    if tick % 60 == 0 then pcall(panel.ensure) end

    if benchPending and tick >= 40 then
        benchPending = false
        pcall(runBenchOnce)
    end
    -- 一次性雾诊断：把场景里所有会出雾的对象列进日志（判断是体积雾/局部雾体积/粒子）
    if diagPending and tick >= 60 then
        diagPending = false
        pcall(fogH.diag)
    end

    -- 换场景静默期：世界在批量销毁对象，这时候任何 FindAllOf / GetOwner /
    -- 属性读写都可能拿到半死对象，IsValid 拦不住原生层越界。整轮跳过。
    if world.suspended() then return false end

    -- 换世界检测（内部会在检测到时触发所有模块的重置回调 + 进入静默期）
    world.check()

    -- 后处理体积集合探测：独立于「有没有参数要写」定期扫描，
    -- 抓到传送/流式加载导致的体积换代就把 lastValue 作废，下一轮全量重下发。
    -- 必须放在 runAll 之前：先作废判重，runAll 才会重新写。
    pcall(ppH.poll)

    -- 参数表：最多每秒读一次文件
    pcall(schema.poll)

    -- 雾钩子：装一次，装不上就每 10 轮（约 2 秒）重试，直到成功。
    -- ★ 不能在固定的 tick==15 只试一次：游戏启动时雾组件可能还没生成
    -- （实测 tick 15 时 gameComponent() 返回 nil），一次性尝试会永远装不上，
    -- 结果就是「钩子=false」、需要每帧写雾的区域失效。
    if not hooks.active() then
        if tick % 10 == 0 then
            pcall(function()
                local comp = fogH.gameComponent()
                if comp then
                    hooks.bind(comp)
                    hooks.install(fogH)
                    -- 交接：装钩子之前是 engine 在按比例写雾密度，它已经把值乘过一次了。
                    -- 把 engine 记录的「原始基准」交给钩子，钩子才不会再乘第二次（否则画面骤暗）。
                    if hooks.active() then
                        hooks.seedBase(engine.baseOf("fog.density"))
                    end
                end
            end)
        end
    elseif tick % 25 == 0 then
        -- 换关卡/传送后旧雾组件会失效或换成新的（同地图内流式加载也会重建），
        -- 每 5 秒重新取一次并 bind（FindAllOf 全场景扫描，别太密）；
        -- hooks.bind 内部用 ue.same 判身份，换了组件就清掉 lastRaw/lastWritten，
        -- 避免拿旧地图的基准把新雾写歪。
        pcall(function()
            local comp = fogH.gameComponent()
            if comp then hooks.bind(comp) end
        end)
    end

    -- 平行光探测：每 10 轮（约 2 秒）查一次标记文件，避免每轮做同步 IO
    local lt = light.bumpTick()
    if lt % 10 == 0 then pcall(light.poll) end
    if light.state() and lt % 60 == 0 then pcall(light.recheck) end

    -- 后处理体积换代检查
    pcall(schema.checkPPGeneration)

    -- 全部参数分发
    pcall(schema.runAll, PP_BUDGET)

    -- 攒下的持久化改动，到点落盘（最多每 5 秒一次）
    pcall(ppH.flushIfDue)

    -- 过场探针：便宜信号每轮采，贵信号 30 秒一次。
    -- 目的是回答「这个游戏怎么判断正在放过场动画」—— 现在还不知道，
    -- 所以先把候选信号（相机 ViewTarget / LevelSequence 类计数 / 帧时间）采下来，
    -- 等你下次真的遇到过场时，日志里就有对照数据了。
    pcall(probe.tick, dt)

    -- 状态快照：每 50 轮（约 10 秒）打一次，便于对照现场
    if tick % 50 == 0 then
        pcall(function()
            local c = fogH.gameComponent()
            local avg = stepN > 0 and (stepSumMs / stepN) or 0
            log.info(string.format(
                "状态: 雾比例=%s 实际密度=%s | pp 字段=%d 体积=%d | 钩子=%s | cpu均=%.2fms 轮数=%d | 卡顿=%d次/最大%.1fs",
                tostring(fogH.getRatio()),
                tostring(c and ue.readNum(c, "FogDensity") or "?"),
                select(1, ppH.stats()),
                ppH.volCount(),
                tostring(hooks.active()),
                avg, stepN,
                stallCount, stallMax))
            stepSumMs, stepN = 0, 0
            stallCount, stallMax = 0, 0
        end)
    end

    local dtMs = (nowSec() - tStep) * 1000
    stepSumMs = stepSumMs + dtMs
    stepN = stepN + 1

    return false
end

log.info("Velm 已加载（模块化版本）")

LoopInGameThreadWithDelay(TICK_MS, step)
