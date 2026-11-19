-- 参数表加载与分发。
--
-- 单一职责：把 pbz_tweaker.json 变成「一组带 handler 的参数」，并按 handler 分发。
-- 不在这里写任何业务逻辑 —— 每种 handler 都有自己的模块。
--
-- 性能要点（这是老实现最疼的地方）：
--   · 老 loadCfg 每 200ms 无条件 io.open + 读 48KB + 整串比较。
--   · 现在最多每秒读一次文件，并且**读到的原文和上次一样就直接返回，不重新解析**。
--     面板每次保存都会改文件内容，所以「改了立刻生效」的体验不变。
--   · 实测：解析这份 48KB 参数表要 ~8.7ms；每秒重解析一次就是每秒一次卡顿。
--     "读文件 + 整串比较"只要零点几毫秒，把每秒 8.7ms 的卡顿降到几乎为零。

local log   = require("core.log")
local env   = require("core.env")
local json  = require("core.json")
local ue    = require("core.ue")
local world = require("core.world")

local engine = require("params.engine")
local ppH    = require("params.handlers.pp")
local fogH   = require("params.handlers.fog")
local gusH   = require("params.handlers.gus")
local miscH  = require("params.handlers.misc")
local hooks  = require("features.hooks")

local schema = {}

local params    = {}     -- 全部参数（展平）
local fogParams = {}     -- handler=="fog" 的子集（钩子要用）
local master    = true
local prevMaster = nil   -- 上一轮的总开关状态（用于检测「开→关」并触发全量还原）
local lastMtime = nil
local lastResample = nil
local lastGeneration = nil   -- pp 体积代号，变了就把所有 pp 字段重写一遍
local loaded    = false

-- ---------------------------------------------------------------- 文件时间

-- 信号/数据分离：面板每次保存把 pbz_rev.txt 的版本号 +1（几字节）。
-- schema.poll 每秒只读这几字节版本号，没变就直接返回——不读 json、不解析。
-- 只有版本号变了才读一次整份 json 并解析；旧安装无 rev 文件时退回"读原文比对"。
-- 稳态开销≈每秒读几字节；改了最多 1 秒内生效。
local lastCheck = 0
local lastRev = nil   -- 上次读到的配置版本号（pbz_rev.txt，面板每次保存 +1）
local CHECK_INTERVAL = 1
local lastRaw = nil   -- 上次读到的原文，用来"内容没变就不解析"

-- ---------------------------------------------------------------- 分发

local function dispatch(p)
    local h = p.handler
    if h == nil then return end

    -- 覆盖开关关掉时一律按原版值处理：撤销已下发的覆盖，但界面里调好的数值不动。
    -- 这样关开关永远不会丢用户调过的东西。
    -- ignoreMaster=true 的参数（如分辨率/窗口类）不受总开关影响。
    local e = p
    if (not master and not p.ignoreMaster) or p.enabled == false then
        e = {}
        for k, v in pairs(p) do e[k] = v end
        e.enabled = false            -- 关键：总开关关 / 单项关，都按"撤销覆盖(还原原值)"处理
        if p["default"] ~= nil then e.value = p["default"] end
    end

    if h == "fog" then
        local d = engine.route(p.key)
        if not d then return end
        -- 雾密度由每帧钩子独占写入（如果钩子装上了）。
        -- 让位是为了保证「单一写入者」：两条路径同时写会互相打断时域累积。
        -- 钩子没装上时（安装失败）engine 兜底，功能不至于全丢。
        if d.hookManaged and hooks.active() then
            fogH.setRatio(tonumber(e.value) or 1.0)
            return
        end
        engine.step(e, d)
    elseif h == "pp" then
        if e.enabled == false then
            if ppH.hasOverride(p.target) then ppH.apply(e) end
        else
            ppH.apply(e)
        end
    elseif h == "gus" then
        if p.enabled == false then return end
        gusH.apply(e)
    elseif h == "cvar" then
        if p.enabled == false then return end
        miscH.applyCvar(e)
    elseif h == "exec" then
        if p.enabled == false then return end
        miscH.applyExec(e)
    elseif h == "light" then
        local d = engine.route(p.key)
        if d then engine.step(e, d) end
    elseif h == "app" then
        -- 窗口尺寸这类由面板进程直接改窗口，Lua 这边不用管
    end
end

-- ---------------------------------------------------------------- 对外

function schema.params()
    return params
end

function schema.fogParams()
    return fogParams
end

function schema.master()
    return master
end

function schema.loaded()
    return loaded
end

-- 每轮主循环调用。只有「距上次检查够久」才真正读文件。
-- 关键：读到的原文和上次一样就直接返回，绝不重新 json.decode。
-- 实测解析这份 48KB 参数表要 ~8.7ms，每秒一次就是每秒一次卡顿；
-- 而"读 48KB + 整串比较"只要零点几毫秒，摊下来无感。
function schema.poll(force)
    local now = os.time()
    if not force and (now - lastCheck) < CHECK_INTERVAL then return false end
    lastCheck = now

    -- 快速路径：先读几字节的版本号(pbz_rev.txt)，没变就直接返回——不读 json、不解析。
    -- 面板每次真正保存参数时会把版本号 +1；没变就说明配置没动。
    local rev = nil
    do
        local rf = io.open(env.REV, "rb")
        if rf then
            local s = rf:read("*l") or rf:read("*a")
            rf:close()
            if s then rev = tonumber(s:match("%d+")) end
        end
    end
    if (not force) and loaded and rev ~= nil and rev == lastRev then
        return false          -- 版本号没变：常态路径，几乎零开销
    end

    local fh = io.open(env.CFG, "rb")
    if not fh then
        log.once("cfg:missing", "参数表读取失败: " .. env.CFG)
        return false
    end
    local raw = fh:read("*a")
    fh:close()
    if raw == nil or raw == "" then return false end

    -- 兼容没有 pbz_rev.txt 的旧安装：退回"读原文比对"，避免漏更新。
    if rev == nil and (not force) and raw == lastRaw then
        return false
    end
    lastRaw = raw
    lastRev = rev

    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then
        log.once("cfg:badjson", "参数表解析失败: " .. tostring(data))
        return false
    end

    params = {}
    fogParams = {}
    master = (data.master ~= false)

    -- 「重新采样」：把后处理原值记录全清掉，下一轮从游戏里重新读。
    local rs = tonumber(data.resample) or 0
    if lastResample ~= nil and rs ~= lastResample then
        ppH.resample()
    end
    lastResample = rs

    for _, g in ipairs(data.groups or {}) do
        for _, p in ipairs(g.parameters or {}) do
            table.insert(params, p)
            if p.handler == "fog" then table.insert(fogParams, p) end
        end
    end

    -- 把 pp 参数的有效视图灌给 pp 模块（自己排队、分帧写入）。
    -- master 关掉时按 default 下发；enabled=false 让 pp 还原该字段的原值。
    --
    -- 三模式（参数自带字段，不再需要额外的 choice 参数行）：
    --   mode   "abs" | "ratio" | "offset" —— 当前用哪种
    --   value  绝对模式的值
    --   ratio  比例模式的百分比（0~300，100 = 不变）
    --   offset 偏移模式的值（原值 + offset）
    --   origin 比例的缩放原点（0 = 关闭语义，1 = 倍率中性；null 表示不开放比例）
    --   modes  支持哪几种（面板用；Lua 侧只做兜底校验）
    local VALID_MODE = { abs = true, ratio = true, offset = true }

    local ppParams = {}
    for _, p in ipairs(params) do
        if p.handler == "pp" then
            local val = p.value
            -- 总开关关掉（且不是 ignoreMaster 项）等价于该项 enabled=false → pp 会还原原值。
            local effEnabled = (p.enabled ~= false) and (master or p.ignoreMaster)
            if (not master and not p.ignoreMaster) and p["default"] ~= nil then val = p["default"] end

            -- 模式兜底：不认识的、或该参数没开放这种模式的，一律退回绝对。
            local m = p.mode
            if not VALID_MODE[m] then m = "abs" end
            local allowed = p.modes
            if type(allowed) == "table" then
                local ok = false
                for _, x in ipairs(allowed) do if x == m then ok = true; break end end
                if not ok then m = "abs" end
            end
            -- 比例模式必须有可靠原点，没有就退回绝对（参数表标错也不会算错值）。
            if m == "ratio" and type(p.origin) ~= "number" then m = "abs" end

            ppParams[#ppParams + 1] = {
                target = p.target,
                value = val,
                component = p.component,
                enabled = effEnabled,
                mode = m,
                ratio = tonumber(p.ratio) or 100,
                offset = tonumber(p.offset) or 0,
                origin = tonumber(p.origin),
            }
        end
    end
    ppH.setParams(ppParams)
    -- 总开关「由开变关」：显式请求一次全量还原（不等 reconcile，避免刚进场景漏掉）。
    if (not master) and (prevMaster ~= false) then
        if ppH.requestRevertAll then pcall(ppH.requestRevertAll) end
    end
    prevMaster = master

    loaded = true
    log.changed("cfg:count", string.format("参数表: %d 项（雾 %d）master=%s",
        #params, #fogParams, tostring(master)))
    return true
end

-- 逐参数分发。主循环每轮调用一次。
-- 后处理字段有预算限制（一帧写太多结构体会撞渲染线程），其余没有。
function schema.runAll(ppBudget)
    local used = 0
    for _, p in ipairs(params) do
        local h = p.handler
        if h == "pp" then
            -- pp 由 params.handlers.pp 自己排队、分帧写入（见 pp.poll）。
            -- 这里不再逐帧直写 —— 曾经每 tick 写 3 个字段 × 全部体积，
            -- 单帧几十毫秒，过场/流式加载密集换代时就是"卡成 PPT"。
        elseif h == "app" then
            -- 不做任何事
        else
            local ok, err = pcall(dispatch, p)
            if not ok then
                log.once("err:" .. tostring(p.key), "参数出错 " .. tostring(p.key) .. ": " .. tostring(err))
            end
        end
    end
end

-- 后处理体积换代：pp 自己在 pp.poll 里检测并出队，这里只同步一下代号，
-- 不再打日志（避免和 pp 的「后处理体积换代」重复打印）。
function schema.checkPPGeneration()
    lastGeneration = ppH.generation()
end

world.onNewWorld("schema", function()
    lastCheck = 0
    -- 参数表内容没变，不需要重新读；只是让下一轮强制检查一次
end)

return schema
