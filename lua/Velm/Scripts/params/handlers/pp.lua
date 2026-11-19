-- 后处理体积（handler = "pp"）。
--
-- 背景：这版游戏写不了 cvar，但 PostProcessVolume.Settings 的属性可以直接写，
-- 而且渲染器每帧都会读它，改完下一帧就生效（不用 MarkRenderStateDirty）。
--
-- 关键设计：
--   · 原值必须落盘（热重载会清内存），否则关掉开关就还原不回去
--   · 原值按「体积全名」记，换场景后旧记录自然失效 → 必须能被清掉（见 world 注册）
--   · 写盘走 core.store 的延迟持久化，绝不在游戏线程同步写大文件
--
-- ★ 2026-11-14 第二批优化：写入改成「队列 + 分帧摊平 + 按体积增量」。
--   问题：过场/流式加载时后处理体积反复增删，旧实现每检测到一次集合变化就把
--   「22 个字段 × 30~40 个体积」一次性全部重写，单帧峰值 25~67ms，密集时代入
--   4 倍帧生成就是"卡成 PPT / 偶尔卡几下"。
--   现在：
--     ① 每个 (字段, 体积) 的已写值记在 writeState 里，只有「这个体积还没被写过
--        这个字段」才进队列 —— 新生成一个体积只补写它的 22 个字段，不再重写全场。
--     ② 队列由 pump(WRITE_BUDGET_MS) 按时间预算消费，把原本一帧的几百次属性写
--        摊到多帧，单帧开销有上限。
--     ③ 体积集合变化仍然会触发出队（generation++），但只补缺的、不推倒重来。

local log     = require("core.log")
local ue      = require("core.ue")
local env     = require("core.env")
local json    = require("core.json")
local store   = require("core.store")
local world   = require("core.world")
local objects = require("core.objects")

local pp = {}

-- field -> { [体积全名] = { v = 原值 | {r,g,b}, b = 原 bOverride, c = 分量名 } }
local orig    = {}
local applied = {}     -- field -> true 表示我们确实动过它

-- field -> { [体积全名] = 已写入的值 }（number，或颜色 {r,g,b}）。
-- 用来判断「这个体积的这个字段现在是不是已经是我们要的值」，只有不是才重写。
local writeState = {}

local vols       = nil
local scannedAt  = 0
local restoreDone = false
local bad        = {}   -- 日志去重
local generation = 0    -- 体积集合代号
local volsSig    = nil  -- 体积集合签名（数量 + 全部全名）

-- 队列
local queue   = {}      -- 任务 { p=参数, v=体积对象, nm=全名 }
local qi      = 1
local queued  = {}      -- "field|nm" 去重
local reconcileNeeded = true
local reconcileDueAt = 0 -- 换代后推迟到这里才开始出队（见 RECONCILE_DELAY）

-- 每 tick 写属性的「时间预算」（毫秒），不是条数预算。
--
-- ★ 2026-11-15 从「固定条数」改成「时间上限」，原因是两次实测都很糟：
--   · 条数=32：一个 tick 塞 32 次跨 C++ 写，实测单 tick 200~450ms → 换图后卡死好几秒
--   · 条数=6 ：单 tick 轻了，但 26 字段 × 36 体积 = 936 次要 156 个 tick（31 秒）才写完
--              → 现场实测「换图后 34 秒画面才慢慢恢复」，正是用户抱怨的那句
--   问题在于「条数」和「耗时」不是线性关系（写不同属性、不同体积的代价差很多）。
--   改成「每 tick 最多花 6ms」，两种坏情况同时消失：
--   队列长时自动多写（每 tick 稳定 6ms 开销，感知不到），队列短时立刻停手。
local WRITE_BUDGET_MS = 6

-- 兜底上限：极端情况下（写入极快）也不能一个 tick 写完 936 条把渲染线程堵住。
local WRITE_BUDGET_MAX = 48

-- 换代后先等这么久（秒）再开始下发。
-- 为什么：LoadMap 之后游戏自己还在做流式加载（贴图/网格/PSO 编译），
-- 那几秒本来就是它最吃 CPU 的时候。我们如果同时往里灌 936 次属性写，
-- 两边的峰值叠在一起 → 卡死好几秒。错开 3 秒，各卡各的，用户只感知到游戏自己的加载。
local RECONCILE_DELAY = 3

-- 标记「需要重新出队」，并把出队时间推到 delay 秒之后。
--
-- ★ delay > 0 时，已经处于待出队状态就不重复推迟：否则流式加载期间体积每秒都在变，
--   截止时间会被无限往后顶，参数永远下不去（表现为「新场景参数不生效」）。
--   语义是「这一轮 churn 开始后等 3 秒再动手」，不是「静止 3 秒才动手」。
-- ★ delay == 0 表示用户主动操作（改参数/切模式/重新采样），必须立刻覆盖待定状态。
local function markReconcile(delay)
    local d = delay or RECONCILE_DELAY
    if d > 0 and reconcileNeeded then return end
    reconcileNeeded = true
    reconcileDueAt = os.time() + d
end

-- 参数表里 handler=="pp" 的有效视图（由 schema.poll 在解析完参数表后灌进来）。
local paramList = {}

-- ★ 三模式（abs / ratio / offset）的写入状态。
--   writeInput[field][体积全名] = 上次写入时用的「输入值」。
--     绝对模式 = 绝对值本身；比例模式 = 百分比；偏移模式 = 偏移量。
--     判重必须比「输入值」而不是「算出来的结果值」：
--       比例模式下结果值 = origin + (原值-origin)*pct/100，跟 pct 永远不相等，
--       直接拿结果比会每轮都判定为「变了」→ 队列永远清不空。
--   lastMode[field] = 上次看到的模式。模式一变就把该字段整体还原成游戏原值，
--     再从真实游戏值重新采基准 —— 这是防累乘的唯一可靠办法。
--   比例/偏移的基准永远是 orig[field][nm].v（第一次覆盖前的真实游戏值），
--     绝不读「当前值」，因为当前值可能已经是我们自己写进去的。
local writeInput = {}
local lastMode   = {}

-- 原值存储：每 5 秒最多落盘一次。
local origStore = store.new({
    path = env.PPFILE,
    name = "pporig",
    interval = 5,
    encode = json.encode,
    decode = function(txt)
        local ok, data = pcall(json.decode, txt)
        if not ok or type(data) ~= "table" then return nil end
        return data
    end,
})

local function valEq(a, b)
    if type(a) == "table" and type(b) == "table" then
        return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
    end
    return a == b
end

local function nameOf(v)
    local ok, nm = pcall(function() return v:GetFullName() end)
    if ok and type(nm) == "string" and nm ~= "" then return nm end
    return nil
end

-- ---------------------------------------------------------------- 一次性迁移

-- 老版本（2026-11-01 那批）曾把第一个体积改成「全局 + Priority 10000」，
-- 会把它自己的整套设置强加到所有场景（进 BOSS 场时画面整体变味就是这么来的）。
-- 这里把它撤回原状。只跑一次。
local function restoreHijack()
    if restoreDone then return end
    restoreDone = true
    local arr = objects.get("PostProcessVolume")
    for i = 1, #arr do
        local v = arr[i]
        local okU, u = pcall(function() return v.bUnbound end)
        local okP, pr = pcall(function() return v.Priority end)
        if okU and u == true and okP and type(pr) == "number" and math.abs(pr - 10000.0) < 0.5 then
            pcall(function()
                v.bUnbound = false
                v.Priority = 0.0
            end)
            log.info("pp 已撤销之前对体积的全局接管")
        end
    end
end

-- ---------------------------------------------------------------- 体积扫描

-- 体积集合签名：数量 + 每个体积的全名（排序后拼接）。
-- 为什么不能只看数量：同地图内传送 / 流式加载常常是「旧的销毁、新的生成」，
-- 数量可能一模一样，但根本不是同一批体积。只看数量会漏判 → 新体积永远收不到值，
-- 表现就是「传送后某些后处理参数不生效，随便改一下参数才突然生效」。
local function sigOf(list)
    if not list or #list == 0 then return "0" end
    local parts = {}
    for i = 1, #list do
        parts[i] = nameOf(list[i]) or ("?" .. i)
    end
    table.sort(parts)
    return #list .. "|" .. table.concat(parts, "\n")
end

-- 更新体积列表并算签名。不在这里出队 —— 出队由调用方决定（避免重入）。
local function updateVols()
    local arr = objects.get("PostProcessVolume")
    local list = {}
    for i = 1, #arr do
        local v = arr[i]
        local okE, en = pcall(function() return v.bEnabled end)
        if not okE or en ~= false then list[#list + 1] = v end
    end
    vols = list
    return sigOf(list)
end

-- 供主循环「换代检查」使用：算一次签名，变了就 generation+1 并标记需要出队。
local function refresh()
    local sig = updateVols()
    if sig ~= volsSig then
        volsSig = sig
        generation = generation + 1
        markReconcile()
        log.info("后处理体积换代，全部字段重新下发")
    end
end

function pp.generation()
    return generation
end

-- 仅供性能自测用：跑一次全量重扫（FindAllOf 播种 + 验活 + 签名）。
function pp.benchRefresh()
    updateVols()
end

-- schema 解析完参数表后把 pp 参数的有效视图灌进来。
function pp.setParams(list)
    paramList = list or {}
    markReconcile(0)   -- 参数表刚变，用户正等着看效果，立刻出队
end

-- 总开关关闭时调用：把「我们改过的所有字段」无条件还原成原值，
-- 直到 orig 记录清空为止（pp.poll 每轮重试，避免刚进场景 volumes 还没扫到时漏掉）。
local revertAllPending = false
function pp.requestRevertAll()
    revertAllPending = true
end

-- ---------------------------------------------------------------- 出队

-- 把「还没写到位的 (字段, 体积)」装进队列。已写过的、值已对的都不装。
-- 换图/新体积时只会装增量，不会推倒重写整场。
local function buildQueue()
    queue = {}
    qi = 1
    queued = {}
    if not vols or #vols == 0 then return end

    -- 先把全名算一遍（每轮几十次 pcall，微秒级）
    local names = {}
    for i = 1, #vols do names[i] = nameOf(vols[i]) end

    for _, p in ipairs(paramList) do
        local field = p.target
        if field then
            -- ★ 用户切换了模式（绝对 / 比例 / 偏移）：先把这个字段整体还原成游戏原值，
            -- 再清掉已写记录，让下一轮从真实游戏值重新采基准。
            -- 不做这一步的话，比例/偏移会把「上次写进去的值」当成原值再算一次 = 累乘。
            -- 这也保证基准永远是游戏真实值，与操作顺序无关。
            local m = p.mode or "abs"
            if lastMode[field] ~= nil and lastMode[field] ~= m then
                pp.revertField(field, true)
                markReconcile(0)   -- 用户刚切模式，下一轮立刻重排队
            end
            lastMode[field] = m

            if p.enabled == false then
                -- 关掉的项（含总开关关闭时全部按 false 下发）：无条件还原到原值，
                -- 不再依赖 applied 标记——否则换图/重载后 applied 丢了就永远还原不回去。
                pp.revertField(field, true)
            else
                local ws = writeState[field]
                if not ws then ws = {}; writeState[field] = ws end
                local wi = writeInput[field]
                -- 本模式下「用户当前想写的输入值」
                local want = p.value
                if m == "ratio" then want = p.ratio
                elseif m == "offset" then want = p.offset end
                for i = 1, #vols do
                    local nm = names[i]
                    if nm then
                        if not valEq(wi and wi[nm], want) then
                            local key = field .. "\1" .. nm
                            if not queued[key] then
                                queued[key] = true
                                queue[#queue + 1] = { p = p, v = vols[i], nm = nm }
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- 单体积单字段写

local function writeOne(p, v, nm)
    local field = p.target
    if not field then return false end
    local okS, s = pcall(function() return v.Settings end)
    if not (okS and s) then return false end

    local saved = orig[field]
    if not saved then saved = {}; orig[field] = saved end

    local comp = p.component
    local isColor = (type(p.value) == "table")
    local mode = p.mode or "abs"
    local isRatio = (mode == "ratio")
    local isOffset = (mode == "offset")

    -- 第一次碰这个体积的这个字段：先把它原有的值和 bOverride 记下来，供还原用。
    -- ★ 比例/偏移模式的基准就是这里记下的原值（第一次覆盖前的真实游戏值）。
    if saved[nm] == nil then
        local _, ov = pcall(function() return s["bOverride_" .. field] end)
        if isColor then
            local okc, cv = pcall(function()
                local v4 = s[field]
                return { v4.X, v4.Y, v4.Z }
            end)
            saved[nm] = { c = "RGB", v = (okc and cv) or { 1, 1, 1 }, b = (ov == true) }
        elseif comp then
            local okc, cv = pcall(function() return s[field][comp] end)
            saved[nm] = { c = comp, v = (type(cv) == "number" and cv) or 0, b = (ov == true) }
        else
            local _, cv = pcall(function() return s[field] end)
            saved[nm] = { v = (type(cv) == "number" and cv) or 0, b = (ov == true) }
        end
    end

    -- 算出实际要写入的值。三种模式都从「原值」出发，绝不读当前值（防累乘）：
    --   绝对：val = value
    --   比例：val = origin + (原值 - origin) × ratio/100    ← origin 是该参数的自然零点
    --   偏移：val = 原值 + offset
    -- 比例模式下 origin=0 时退化成「原值 × ratio/100」，正是最直观的缩放语义。
    local val = p.value
    local input = p.value      -- 判重用的输入值（绝对模式就是 value 本身）
    if isRatio then
        input = tonumber(p.ratio) or 100
        local rec = saved[nm]
        local base = rec and rec.v
        if type(base) ~= "number" then return false end
        local origin = tonumber(p.origin) or 0
        val = origin + (base - origin) * input / 100
    elseif isOffset then
        input = tonumber(p.offset) or 0
        local rec = saved[nm]
        local base = rec and rec.v
        if type(base) ~= "number" then return false end
        val = base + input
    end

    -- ★ 比例/偏移模式绝不强行打开 bOverride：只调「游戏本来就开了这项」的体积。
    -- 否则会把没开漏光/没开某项的场景强行点亮，等于替游戏做决定。
    -- 只记账、不写盘，避免每轮重复入队。
    if isRatio or isOffset then
        local _, ov = pcall(function() return s["bOverride_" .. field] end)
        if ov ~= true then
            local ws0 = writeState[field]
            if not ws0 then ws0 = {}; writeState[field] = ws0 end
            ws0[nm] = val
            local wi0 = writeInput[field]
            if not wi0 then wi0 = {}; writeInput[field] = wi0 end
            wi0[nm] = input
            return true
        end
    end

    if field == "LumenSkylightLeaking" and saved[nm] then
        local rec = saved[nm]
        local cur0
        pcall(function() cur0 = s[field] end)
        log.once("diag:w:" .. tostring(nm), string.format("写诊断 skyleak 原值=%s 写入=%s 当前=%s ov原=%s",
            tostring(type(rec.v)=="number" and rec.v or rec.v), tostring(val), tostring(cur0), tostring(rec.b)))
    end

    local ok
    if isColor then
        ok = pcall(function()
            s["bOverride_" .. field] = true
            local v4 = s[field]
            v4.X = val[1]; v4.Y = val[2]; v4.Z = val[3]
        end)
    elseif comp then
        ok = pcall(function()
            s["bOverride_" .. field] = true
            s[field][comp] = val
        end)
    else
        ok = pcall(function()
            s["bOverride_" .. field] = true
            s[field] = val
        end)
    end
    if not ok then return false end

    local ws = writeState[field]
    if not ws then ws = {}; writeState[field] = ws end
    if isColor then ws[nm] = { val[1], val[2], val[3] } else ws[nm] = val end
    local wi = writeInput[field]
    if not wi then wi = {}; writeInput[field] = wi end
    wi[nm] = input
    applied[field] = true
    if not bad[field] then
        bad[field] = true
        local n = 0
        for _ in pairs(ws) do n = n + 1 end
        local tag = ""
        if isRatio then tag = string.format("（原值×%s%%，原点 %s）", tostring(input), tostring(p.origin))
        elseif isOffset then tag = string.format("（原值%+.3f）", input) end
        log.info(string.format("pp 写 %s = %s%s（已覆盖 %d 个体积）", field, tostring(val), tag, n))
    end
    return true
end

-- 把内存里的 orig 同步进 store 并标脏；真正落盘由 flushIfDue 决定。
--
-- ★ 落盘前剔除已销毁体积的记录：换图/流式加载会在体积全名里留下
--   `TrashedPackage_NNNNN` 这类墓碑对象（现场实测 75 条记录里 36 条是它，
--   占 105KB / 约 40% 的文件体积），它们永远不会再被访问，留着只会让
--   每 5 秒一次的序列化白白多做 40% 的工作。
--   判据用「全名里含 TrashedPackage」而不是「验活」：落盘是低频路径，
--   没必要为它逐个 pcall 跨 C++ 边界。
local function isDeadName(nm)
    return type(nm) == "string" and nm:find("TrashedPackage", 1, true) ~= nil
end

local function markDirty()
    for field, recs in pairs(orig) do
        local clean, n = nil, 0
        for nm, rec in pairs(recs) do
            if not isDeadName(nm) then
                if not clean then clean = {} end
                clean[nm] = rec
                n = n + 1
            end
        end
        if n == 0 then
            origStore.clear(field)
        else
            origStore.set(field, clean)
        end
    end
    local keep = {}
    for field in pairs(orig) do keep[field] = true end
    for field in pairs(origStore.data) do
        if not keep[field] then origStore.clear(field) end
    end
end

-- 分帧消费队列。按「时间预算」消费：每 tick 最多花 budgetMs 毫秒，
-- 同时受条数上限兜底（写入极快时不至于一口气把 936 条全灌进去堵住渲染线程）。
--
-- 为什么用时间而不是条数：写不同属性/不同体积的代价差很多（结构体大小、
-- 是否触发 MarkRenderStateDirty），条数完全反映不了真实开销。
local pumpWrote = false
local function pump(budgetMs)
    if not vols or #vols == 0 then return end
    local clock = (type(os) == "table" and type(os.clock) == "function") and os.clock or nil
    local t0 = clock and clock() or 0
    local done = 0
    while qi <= #queue and done < WRITE_BUDGET_MAX do
        -- 时间到就收手：剩下的留到下一个 tick（200ms 后），不会累积成卡顿。
        if clock and done > 0 and ((clock() - t0) * 1000) >= budgetMs then break end
        local t = queue[qi]
        qi = qi + 1
        if t and ue.usable(t.v) then
            if writeOne(t.p, t.v, t.nm) then pumpWrote = true end
            done = done + 1
        end
        -- 死对象直接跳过、不占预算（后面的继续写）
    end
    if pumpWrote then
        markDirty()
        pumpWrote = false
    end
    if qi > #queue then
        queue = {}; qi = 1; queued = {}
    end
end

-- ---------------------------------------------------------------- 定期探测（关键修复）
--
-- 主循环每 tick 调用：
--   · 每秒重算一次体积签名，集合变了就 generation++ 并标记出队；
--   · 参数表变了（schema 灌了新 paramList）也会标记出队；
--   · 剩下的时间都在 pump：把队列里的写入按预算摊到多帧。
--
-- 体积增删由 core.objects 的事件登记自动跟上（新体积一生成就进列表、死体积取用时
-- 自动剔除），这里只算签名，不涉及任何全场景扫描。
local POLL_INTERVAL = 1   -- 秒：签名重算的节流
local lastPoll = 0

function pp.poll()
    local now = os.time()
    if (now - lastPoll) >= POLL_INTERVAL then
        lastPoll = now
        refresh()
    end
    -- ★ 总开关关闭：无条件全量还原（不依赖 reconcile / 队列 / applied 标记）。
    if revertAllPending then
        if vols and #vols > 0 then
            local keys = {}
            for f in pairs(orig) do keys[#keys + 1] = f end
            for _, f in ipairs(keys) do pp.revertField(f, true) end
            if next(orig) == nil then revertAllPending = false end
        end
    end
    -- ★ 换代后延迟出队：LoadMap 刚结束时游戏自己还在流式加载、编译 PSO，
    -- 这时候再灌几百次属性写就是雪上加霜。等它喘口气（RECONCILE_DELAY 秒）再开始。
    if reconcileNeeded and now >= reconcileDueAt then
        reconcileNeeded = false
        buildQueue()
    end
    pump(WRITE_BUDGET_MS)
end

-- 供 main 的换代检查调用（generation 变化只会打日志，真正出队在上面 poll 里）
function pp.checkGeneration()
    -- 签名/poll 已经处理；这里保留一个空钩子方便以后挂日志。
end

-- ---------------------------------------------------------------- 载入 / 保存

local function loadOrig()
    local data = origStore.load()
    for field, recs in pairs(data) do
        if type(recs) == "table" and next(recs) ~= nil then
            orig[field] = recs
            applied[field] = true     -- 有原值就说明我们动过，允许还原
        end
    end
    local n = 0
    for _ in pairs(applied) do n = n + 1 end
    if n > 0 then log.info("pp 原值已载入: " .. n .. " 项（延迟落盘，不阻塞游戏线程）") end
end
loadOrig()

-- ---------------------------------------------------------------- 还原（单字段）

-- 开关关掉 = 撤销覆盖，把每个体积的这个字段写回「第一次覆盖前」的原值。
-- 同步执行（用户主动关开关才触发，罕见）。
function pp.revertField(field, force)
    if (not force) and not applied[field] then return end
    local saved = orig[field]
    if not saved then return end
    local restored = 0
    local dead = false
    local diagSk = false
    for _, v in ipairs(vols or {}) do
        if not ue.usable(v) then dead = true; break end
        local nm = nameOf(v)
        local rec = nm and saved[nm]
        if rec then
            local okS, s = pcall(function() return v.Settings end)
            if okS and s then
                if field == "LumenSkylightLeaking" and not diagSk then
                    diagSk = true
                    local curB
                    pcall(function() curB = s[field] end)
                    log.info(string.format("还原诊断 skyleak 还原前=%s 将写原值=%s ov原=%s",
                        tostring(curB), tostring(rec.v), tostring(rec.b)))
                end
                local okR
                if rec.c == "RGB" then
                    okR = pcall(function()
                        local v4 = s[field]
                        v4.X = rec.v[1]; v4.Y = rec.v[2]; v4.Z = rec.v[3]
                        s["bOverride_" .. field] = rec.b
                    end)
                elseif rec.c then
                    okR = pcall(function()
                        s[field][rec.c] = rec.v
                        s["bOverride_" .. field] = rec.b
                    end)
                else
                    okR = pcall(function()
                        s[field] = rec.v
                        s["bOverride_" .. field] = rec.b
                    end)
                end
                if okR then restored = restored + 1 end
            end
        end
    end
    orig[field] = nil
    applied[field] = nil
    writeState[field] = nil
    writeInput[field] = nil
    -- 去掉队列里这个字段的残留任务
    local nq = {}
    for i = 1, #queue do
        local t = queue[i]
        if not (t and t.p and t.p.target == field) then nq[#nq + 1] = t end
    end
    queue = nq
    if qi > #queue then qi = 1; queued = {} end
    markDirty()
    if dead then refresh() end
    if restored > 0 then
        log.info(string.format("pp 还原 %s（%d 个体积）", field, restored))
    else
        log.info("pp 还原 " .. field .. " 找不到对应体积的原值，跳过")
    end
end

-- 兼容旧接口：某字段有没有被我们覆盖过（主循环判断"关掉的项还有没有覆盖没撤"用）。
function pp.hasOverride(field)
    return applied[field] == true
end

-- 兼容旧接口：这一项现在需不需要动手（现在是队列驱动，保留给外部判断用）。
function pp.needsWork(p)
    if p.enabled == false then return applied[p.target] == true end
    local ws = writeState[p.target]
    if not ws then return true end
    return true
end

-- ---------------------------------------------------------------- 对外接口

function pp.flushIfDue()
    return origStore.flushIfDue()
end

-- 用户点「重新采样」：清空原值，下一轮从游戏里重新读。
function pp.resample()
    orig = {}
    applied = {}
    writeState = {}
    writeInput = {}
    bad = {}
    queue = {}; qi = 1; queued = {}
    markReconcile(0)   -- 用户点「重新采样」，立刻
    origStore.clear()
    origStore.markDue()
    origStore.flushNow()
    generation = generation + 1
    log.info("后处理原值记录已清空，下一轮重新从游戏里采样")
end

function pp.volCount()
    return vols and #vols or 0
end

-- 统计信息，给日志用
function pp.stats()
    local fields, recs = 0, 0
    for _ in pairs(orig) do fields = fields + 1 end
    for _, r in pairs(orig) do
        for _ in pairs(r) do recs = recs + 1 end
    end
    return fields, recs
end

-- ★ 换世界：丢掉所有体积原值与写入状态。
-- 老实现漏了清 ppOrig，导致换场景后记录只增不减、膨胀到 446KB / 2400+ 条，
-- 每次写字段都要全量重刷文件 —— 这就是「玩久了突然卡成 PPT」的老根因。
world.onNewWorld("pp", function()
    vols = nil
    scannedAt = 0
    volsSig = nil
    lastPoll = 0
    orig = {}
    applied = {}
    writeState = {}
    writeInput = {}
    bad = {}
    queue = {}; qi = 1; queued = {}
    markReconcile()   -- 换图：错开游戏自己的流式加载/PSO 编译峰值
    origStore.clear()
    origStore.markDue()
    origStore.flushNow()
    log.info("pp 换世界：体积缓存与全部原值已清空")
end)

return pp
