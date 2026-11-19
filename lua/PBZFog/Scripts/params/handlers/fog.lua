-- 雾（handler = "fog"）与局部雾团（handler = "lfog"）。
--
-- ★ 单一写入者原则在这里最重要。
--
-- 历史包袱：雾曾经有三套写入路径同时存在 ——
--   · engineStep 定期写组件属性
--   · SetFogDensity 钩子在游戏每次调用时插一刀
--   · 副本接管（doMirror）每帧把原版镜像到副本
-- 三者互相打架，`engineStep` 里那句 `if cloneMode then return end` 就是伤疤。
--
-- 现在：雾只有一条写入路径 —— params/engine 的 ratio 模式。
-- 钩子（features/hooks）只做一件只读的事：记录「游戏当前写进来的原始值」，
-- 供 engine 当基准用。副本方案实测无效（spawn 出来的组件渲染器不认），已删除。
--
-- 雾还有一个特殊情况：某些区域游戏每帧改写 FogDensity，200ms 一次的轮询
-- 永远抢不过。这条由 features/hooks 的每帧钩子处理，但它写入的是
-- 「基准 × 比例」，比例值来自本模块暴露的 ratio()，语义仍是一致的。

local log     = require("core.log")
local ue      = require("core.ue")
local world   = require("core.world")
local objects = require("core.objects")
local env     = require("core.env")

local fog = {}

-- 用户设的密度比例。1.0 = 原样。
-- 钩子每帧要用，所以放在模块级变量里，由主循环在参数变化时更新。
local ratio = 1.0
local ratioDirty = false

-- 游戏自己写进来的原始密度（钩子维护）。engine 的 ratio 模式用它做基准。
local rawDensity = nil

-- ---------------------------------------------------------------- 参数处理

-- engine 的 ratio 模式已经能处理「定期重写」，这里只需要同步比例值。
-- 为什么不自己写：那会让雾有两个写入者（见文件头）。
function fog.setRatio(r)
    r = tonumber(r) or 1.0
    if math.abs(r - ratio) > 1e-9 then
        ratio = r
        ratioDirty = true
    end
end

function fog.getRatio()
    return ratio
end

-- 供每帧钩子使用：目标密度 = 游戏原始值 × 比例。
-- 返回 nil 表示「现在不需要干预」（比例为 1，或者还没拿到原始值）。
function fog.tickTarget()
    if ratio == 1.0 then return nil end
    if rawDensity == nil then return nil end
    return rawDensity * ratio
end

function fog.setRawDensity(v)
    rawDensity = v
end

function fog.getRawDensity()
    return rawDensity
end

-- 找「游戏自己那盏雾」。
-- 判据：owner 名含 Ultra_Dynamic（UDS 驱动的那盏）。
-- 不能按数组顺序取 —— 热重载留下的旧对象会被当成原版。
-- 对象列表由 core.objects 维护（事件驱动，不再每次 FindAllOf 全场景扫描）。
function fog.gameComponent()
    local arr = objects.get("ExponentialHeightFogComponent")
    if #arr == 0 then return nil end
    local best, bestD = nil, -1
    for i = 1, #arr do
        local c = arr[i]
        if ue.alive(c) then
            local oko, o = pcall(function() return c:GetOwner() end)
            if oko and o then
                local okn, nm = pcall(function() return o:GetFullName() end)
                if okn and nm and string.find(nm, "Ultra_Dynamic", 1, true) then
                    return c
                end
            end
            local d = tonumber(ue.readNum(c, "FogDensity")) or -1
            if d > bestD then best, bestD = c, d end
        end
    end
    return best
end

-- ---------------------------------------------------------------- 局部雾团

-- 场景里小范围飘动的雾是 Niagara 粒子（NS_Common_BossFog / NS_*_Fog）。
-- 只取前 600 个：全量扫场景在对象多的区域会明显卡顿。
-- 对象列表由 core.objects 事件维护；仅当 lfog 参数开启时才会走到这里。
local niaList = nil
local niaLast = nil

local function getNiagara()
    if niaList then return niaList end
    local arr = objects.get("NiagaraComponent")
    if #arr == 0 then return nil end
    local hits = {}
    for i = 1, math.min(#arr, 600) do
        local okn, nm = pcall(function() return arr[i]:GetFullName() end)
        if okn and nm and string.find(string.lower(nm), "fog") then
            table.insert(hits, arr[i])
        end
    end
    niaList = hits
    log.once("lfog:scan", "局部雾团: 找到 " .. #hits .. " 个 Niagara")
    return niaList
end

function fog.applyLocal(p)
    local list = getNiagara()
    if not list or #list == 0 then return end
    if niaLast == p.value then return end
    local want
    if type(p.value) == "boolean" then want = p.value
    else want = (tonumber(p.value) or 1) >= 0.5 end

    local okCount = 0
    for _, c in ipairs(list) do
        -- SetVisibility 有两个参数 (bNewVisibility, bPropagateToChildren)，少传会直接报参数个数不对
        local ok = pcall(function() c:SetVisibility(want, true) end)
        if not ok then ok = pcall(function() c:SetHiddenInGame(not want, true) end) end
        if not ok then ok = pcall(function() c.bHiddenInGame = not want end) end
        if ok then okCount = okCount + 1 end
    end
    if okCount > 0 then
        niaLast = p.value
        log.info(string.format("局部雾团: 显示=%s 命中 %d/%d", tostring(want), okCount, #list))
    else
        log.once("lfog:fail", "局部雾团: 所有写法都失败")
    end
end

-- ---------------------------------------------------------------- 一次性诊断

-- 诊断：把场景里所有「会出雾」的对象列进日志，用来判断房间里的浓雾到底是
-- 体积雾（ExponentialHeightFog）、局部雾体积（LocalFogVolume）还是粒子（Niagara）。
--
-- ★ 2026-11-15 改成「按需触发」，不再开机自动跑。
--   现场 A/B 实测：它开机自动跑时会让游戏主线程无响应 0.6 秒 ——
--   因为 objects.get("NiagaraComponent") 会订阅 NiagaraComponent 的创建事件，
--   而场景里有 545 个 NiagaraComponent，FindAllOf 播种 + 逐个登记就是那一卡。
--   这个诊断当初只是为了回答「房间浓雾是哪一种雾」，结论早已写进 DESIGN.md，
--   没有理由每次启动都付一次这个代价。
--   现在改成：只有 E:/PBZ_fogdiag.txt 存在时才跑一次（用完删掉标记即可）。
local diagDone = false
function fog.diag()
    if diagDone then return end
    local marker = env.FOGDIAG
    local mf = io.open(marker, "r")
    if not mf then return end
    mf:close()
    diagDone = true
    local function num(o, prop)
        local ok, v = pcall(function() return o[prop] end)
        if ok and type(v) == "number" then return string.format("%.3f", v) end
        return "?"
    end
    local function nm(o)
        local ok, s = pcall(function() return o:GetFullName() end)
        return ok and tostring(s) or "?"
    end
    local ef = objects.get("ExponentialHeightFogComponent")
    log.info(string.format("雾诊断: ExponentialHeightFogComponent 共 %d 个", #ef))
    for i = 1, #ef do
        local o = ef[i]
        local vol = "?"
        pcall(function() vol = tostring(o.bEnableVolumetricFog) end)
        log.info(string.format("   #%d %s | volumetric=%s FogDensity=%s StartDistance=%s VolStart=%s VolNearFade=%s VolDist=%s VolExtScale=%s",
            i, nm(o), vol,
            num(o, "FogDensity"), num(o, "StartDistance"),
            num(o, "VolumetricFogStartDistance"), num(o, "VolumetricFogNearFadeInDistance"),
            num(o, "VolumetricFogDistance"), num(o, "VolumetricFogExtinctionScale")))
    end
    local lv = objects.get("LocalFogVolumeComponent")
    log.info(string.format("雾诊断: LocalFogVolumeComponent 共 %d 个", #lv))
    for i = 1, math.min(#lv, 12) do
        local o = lv[i]
        log.info(string.format("   #%d %s | RadialExt=%s HeightExt=%s HeightFalloff=%s",
            i, nm(o), num(o, "RadialFogExtinction"), num(o, "HeightFogExtinction"), num(o, "HeightFogFalloff")))
    end
    local all = objects.get("NiagaraComponent")
    local cnt = 0
    for i = 1, #all do
        local s = nm(all[i])
        if s:lower():find("fog", 1, true) then cnt = cnt + 1 end
    end
    log.info(string.format("雾诊断: NiagaraComponent 共 %d 个，其中名字含 Fog 的 %d 个", #all, cnt))
end

-- ---------------------------------------------------------------- 生命周期

world.onNewWorld("fog", function()
    rawDensity = nil
    niaList = nil
    niaLast = nil
end)

return fog
