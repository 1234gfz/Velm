-- 离线行为测试：用模拟的 UE 环境把整套模块真跑起来。
--
-- 为什么值得做：语法检查只能发现拼写错误。这次重构动了写入路径、持久化时机、
-- 换世界重置这些最容易出「静默失效」的地方 —— 那些错误语法完全正确，
-- 只有在游戏里跑起来才会暴露，而每次验证都要启动一次游戏（几分钟）。
-- 这个脚本用 fengari（Lua 5.3 的 JS 实现）在毫秒级把同样的逻辑跑一遍。
--
-- 由 tools/test_sim.js 提供两个全局：
--   MODULES  表：{"core.log" = 源码字符串, ...}
--   CFG_TEXT 参数表原始 JSON 字符串
--
-- 断言失败不抛异常，全部收集到 SUMMARY 里返回给 node 打印。

-- 离线测试里没有真实脚本路径可推导，显式给 env 一个模组目录（与下面 FILES 的 key 对齐）
_G.PBZFOG_MODDIR = "E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/Velm/"

-- ============================================================ 模拟文件系统

local FILES = {}
FILES["E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/Velm/pbz_tweaker.json"] = CFG_TEXT

local io_mock = {}
function io_mock.open(path, mode)
    if mode == nil or mode:sub(1, 1) == "r" then
        local content = FILES[path]
        if content == nil then return nil end
        local done = false
        return {
            read = function(_, fmt)
                if done then return nil end
                done = true
                if fmt == "*a" or fmt == "a" then return content end
                return content
            end,
            close = function() end,
        }
    end
    -- 写模式
    FILES[path] = ""
    return {
        write = function(_, ...)
            local parts = { ... }
            local s = ""
            for i = 1, select("#", ...) do
                s = s .. tostring(parts[i])
            end
            FILES[path] = FILES[path] .. s
        end,
        close = function() end,
        read = function() return nil end,
    }
end

local WRITE_COUNT = {}   -- path -> 写次数

-- 包一层统计写盘次数
local raw_open = io_mock.open
io_mock.open = function(path, mode)
    if mode == "w" then WRITE_COUNT[path] = (WRITE_COUNT[path] or 0) + 1 end
    return raw_open(path, mode)
end

_G.io = io_mock

local TIME = 1000
_G.os = {
    time = function() return TIME end,
    remove = function(p) FILES[p] = nil end,
    execute = function() EXEC_COUNT = (EXEC_COUNT or 0) + 1 end,
    date = function() return "sim" end,
}

-- ============================================================ 模拟 UE 对象

local OBJ_SEQ = 0

local METHODS = {}
local SETTERS = {
    SetFogDensity = "FogDensity",
    SetVolumetricFogExtinctionScale = "VolumetricFogExtinctionScale",
    SetFogMaxOpacity = "FogMaxOpacity",
    SetStartDistance = "StartDistance",
    SetFogHeightFalloff = "FogHeightFalloff",
    SetVolumetricFogScatteringDistribution = "VolumetricFogScatteringDistribution",
    SetVolumetricFogDistance = "VolumetricFogDistance",
    SetIntensity = "Intensity",
    SetFieldOfView = "FieldOfView",
    SetIndirectLightingIntensity = "IndirectLightingIntensity",
}

function METHODS.IsValid(self) return not self.__dead end
function METHODS.GetFullName(self) return self.__name end
function METHODS.GetAddress(self) return self.__id end
function METHODS.IsPendingKillPending(self) return self.__dead end
function METHODS.GetOwner(self) return self.__owner end
function METHODS.GetPropertyValue(self, k) return self.__props[k] end
function METHODS.SetPropertyValue(self, k, v) self.__props[k] = v; return true end
function METHODS.GetComponents(self) return self.__components or {} end
function METHODS.SetActorTickEnabled(self, v) self.__actorTick = v end
function METHODS.SetComponentTickEnabled(self, v) self.__compTick = v end
function METHODS.SetVisibility(self, v) self.__props.bVisible = v end
function METHODS.SetHiddenInGame(self, v) self.__props.bHiddenInGame = v end

local function newObj(class, name, props)
    OBJ_SEQ = OBJ_SEQ + 1
    local o = { __class = class, __name = name, __id = OBJ_SEQ, __dead = false, __props = props or {} }
    return setmetatable(o, {
        __index = function(t, k)
            if METHODS[k] then return METHODS[k] end
            local setterProp = SETTERS[k]
            if setterProp then
                return function(self, v)
                    self.__props[setterProp] = v
                    self.__setterCount = (self.__setterCount or 0) + 1
                    return true
                end
            end
            return t.__props[k]
        end,
        __newindex = function(t, k, v) t.__props[k] = v end,
    })
end

local function newSettings()
    local store = {
        ColorGainShadows = { X = 1, Y = 1, Z = 1 },
        ColorGainHighlights = { X = 1, Y = 1, Z = 1 },
    }
    return setmetatable({ __store = store }, {
        __index = function(t, k)
            local v = t.__store[k]
            if v == nil then return 0 end
            return v
        end,
        __newindex = function(t, k, v) t.__store[k] = v end,
    })
end

-- ============================================================ 世界

local WORLD = {}

local function clearWorld() WORLD = {} end

local function addObj(class, name, props)
    local o = newObj(class, name, props)
    WORLD[class] = WORLD[class] or {}
    table.insert(WORLD[class], o)
    return o
end

local function aliveList(class)
    local out = {}
    for _, o in ipairs(WORLD[class] or {}) do
        if not o.__dead then table.insert(out, o) end
    end
    return out
end

_G.FindAllOf = function(class) return aliveList(class) end
_G.FindFirstOf = function(class)
    local l = aliveList(class)
    return l[1]
end

local KSL = newObj("KismetSystemLibrary", "/Script/Engine.Default__KismetSystemLibrary")
KSL.ExecuteConsoleCommand = function() return true end
KSL.GetConsoleVariableFloatValue = function() return 1.0 end

-- GameplayStatics 的 mock。
-- 为什么必须有：core/timing.lua 靠 GetRealTimeSeconds 取墙钟，
-- 没有它就会退化成 os.time()（固定值），dt 永远为 0，
-- 「卡顿冻结」这条分支在测试里根本走不到 —— 等于没测。
--
-- 用一个可手动推进的虚拟时钟：advanceClock(秒) 推一下，
-- 主循环下一轮就会看到「这一轮晚了 N 秒」。
local VCLOCK = 100.0
_G.__advanceClock = function(s) VCLOCK = VCLOCK + s end
_G.__resetClock = function(v) VCLOCK = v or 100.0 end

local GS = newObj("GameplayStatics", "/Script/Engine.Default__GameplayStatics")
GS.GetRealTimeSeconds = function(self, ctx) return VCLOCK end
GS.GetTimeSeconds = function(self, ctx) return VCLOCK end
GS.GetWorldDeltaSeconds = function(self, ctx) return 0.016 end

-- GameplayStatics 的时间函数都要传 WorldContextObject。
-- 没有 GameInstance / PlayerController 的话，core/timing 拿不到 context，
-- 会静默退化成 os.time() —— 那样卡顿检测就完全失效了。
-- 所以这里必须提供，让测试跑在「和真机一样」的路径上。
local GI = newObj("GameInstance", "/Game/Test/GI_Sim.GI_Sim")
-- 加进 WORLD，这样 FindFirstOf("GameInstance") 能拿到（core/ue.lua 就是那么取的）。
-- 没有它，core/timing 拿不到 WorldContext，会静默退化成 os.time()。
WORLD["GameInstance"] = { GI }

_G.StaticFindObject = function(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then return KSL end
    if path == "/Script/Engine.Default__GameplayStatics" then return GS end
    return nil
end

local HOOKS = {}
_G.RegisterHook = function(name, fn)
    HOOKS[name] = HOOKS[name] or {}
    table.insert(HOOKS[name], fn)
    return true
end
_G.IsInGameThread = function() return true end

-- 事件驱动 API 的 mock：
--   NotifyOnNewObject：登记回调，addObj 新建对象时触发（模拟引擎新建对象）。
--   RegisterLoadMapPostHook：登记换图回调，测试里手动调用 MAPHOOK() 触发。
local NOTIFY = {}
_G.NotifyOnNewObject = function(class, fn)
    NOTIFY[class] = NOTIFY[class] or {}
    table.insert(NOTIFY[class], fn)
    return true
end
local MAPHOOK = nil
_G.RegisterLoadMapPostHook = function(fn) MAPHOOK = fn; return true end
local function fireNewObject(class, obj)
    for _, fn in ipairs(NOTIFY[class] or {}) do pcall(fn, obj) end
end

local STEP = nil
_G.LoopInGameThreadWithDelay = function(ms, fn) STEP = fn end

-- ============================================================ require

local MODCACHE = {}
_G.require = function(name)
    if MODCACHE[name] then return MODCACHE[name] end
    local src = MODULES[name]
    assert(src, "找不到模块: " .. tostring(name))
    local chunk, err = load(src, "@" .. name)
    assert(chunk, "模块编译失败 " .. name .. ": " .. tostring(err))
    local r = chunk()
    MODCACHE[name] = r == nil and true or r
    return MODCACHE[name]
end

-- package 表可能被 main.lua 改，先给个真的
_G.package = _G.package or { path = "" }

-- ============================================================ 断言

local RESULTS = {}
local function check(name, cond, detail)
    table.insert(RESULTS, { name = name, ok = cond and true or false, detail = detail or "" })
end

local function approx(a, b, tol)
    if a == nil or b == nil then return false end
    return math.abs(a - b) <= (tol or 1e-4)
end

-- ============================================================ 场景搭建

-- 一盏游戏雾（UDS 驱动）
addObj("ExponentialHeightFogComponent", "/Game/Maps/LevelA.LevelA:PersistentLevel.Ultra_Dynamic_Sky_C_1.Fog",
    { FogDensity = 0.024, VolumetricFogExtinctionScale = 0.7, FogMaxOpacity = 1.0,
      StartDistance = 5000, FogHeightFalloff = 0.09, VolumetricFogScatteringDistribution = 0.2,
      VolumetricFogDistance = 10000 })

-- 两个后处理体积
local pp1 = addObj("PostProcessVolume", "/Game/Maps/LevelA.LevelA:PersistentLevel.PostProcessVolume_1")
pp1.Settings = newSettings()
pp1.bEnabled = true
pp1.bUnbound = false
pp1.Priority = 0
local pp2 = addObj("PostProcessVolume", "/Game/Maps/LevelA.LevelA:PersistentLevel.PostProcessVolume_2")
pp2.Settings = newSettings()
pp2.bEnabled = true

addObj("SkyLightComponent", "/Game/Maps/LevelA.LevelA:PersistentLevel.SkyLight_1", { Intensity = 6.0 })
addObj("CameraComponent", "/Game/Maps/LevelA.LevelA:PersistentLevel.Camera_1", { FieldOfView = 90 })
addObj("DirectionalLightComponent", "/Game/Maps/LevelA.LevelA:PersistentLevel.Sun_1", { Intensity = 8.0 })
addObj("DirectionalLightComponent", "/Game/Maps/LevelA.LevelA:PersistentLevel.Moon_1", { Intensity = 0.0 })

local gus = newObj("GameUserSettings", "/Script/ProjectPBZ.PBZGameUserSettings")
gus.ResolutionSizeX = 2560
gus.ResolutionSizeY = 1440
gus.FullscreenMode = 1
gus.SetResolutionScaleValueEx = function() return true end
gus.SetResolutionScaleNormalized = function() return true end
gus.ApplyNonResolutionSettings = function() return true end
gus.ApplySettings = function() return true end
gus.SetScreenResolution = function() return true end
gus.SetFullscreenMode = function() return true end
gus.ApplyResolutionSettings = function() return true end
addObj("GameUserSettings", "/Script/ProjectPBZ.PBZGameUserSettings", {})

local engine = newObj("GameEngine", "/Script/Engine.GameEngine")
engine.GameUserSettings = gus
addObj("GameEngine", "/Script/Engine.GameEngine", {})
WORLD["GameEngine"][1].GameUserSettings = gus

-- ============================================================ 载入被测代码

-- 载入期间保留输出（便于定位加载错误），之后静音，避免几千行日志拖慢模拟
local realPrint = print
local okLoad, loadErr = pcall(function()
    require("main")
end)
local BUF = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    BUF[#BUF + 1] = table.concat(parts)
    if #BUF > 4000 then table.remove(BUF, 1) end
end
_G.__LOGBUF = BUF
check("主入口可加载", okLoad, tostring(loadErr))
check("主循环已注册", STEP ~= nil, "LoopInGameThreadWithDelay 未被调用")

-- ============================================================ 步进

local function stepOnce()
    -- 虚拟墙钟按「正常一轮 0.2 秒」推进。
    -- 卡顿测试用 __advanceClock() 额外注入时间，模拟「这一轮晚了 N 秒」。
    _G.__advanceClock(0.2)
    if STEP then
        local ok, err = pcall(STEP)
        if not ok then error("主循环抛异常: " .. tostring(err)) end
    end
    -- 模拟引擎每帧钩子（我们只关心 Tick 那一路）
    for _, fn in ipairs(HOOKS["/Script/Engine.Engine:Tick"] or {}) do
        pcall(fn)
    end
end

if STEP then
    for i = 1, 40 do
        TIME = TIME + 1
        local ok, err = pcall(stepOnce)
        if not ok then
            check("主循环连续运行", false, tostring(err))
            break
        end
    end

    -- ---- 测试 1：雾密度比例生效 ----
    local fog = WORLD["ExponentialHeightFogComponent"][1]
    -- 参数表里 fog.density=0.8（相对原值 0.024 → 目标 0.0192）
    check("雾密度按比例写入", approx(fog.__props.FogDensity, 0.024 * 0.8, 1e-3),
        string.format("实际=%s 期望≈%s", tostring(fog.__props.FogDensity), tostring(0.024 * 0.8)))

    -- ---- 测试 2：后处理字段写到了体积 ----
    check("后处理 BloomIntensity 已下发", math.abs((pp1.Settings.__store.BloomIntensity or 0) - 2) < 1e-6,
        "值=" .. tostring(pp1.Settings.__store.BloomIntensity))
    check("后处理 VignetteIntensity 已下发", math.abs((pp1.Settings.__store.VignetteIntensity or 0) - 0.6) < 1e-6,
        "值=" .. tostring(pp1.Settings.__store.VignetteIntensity))

    -- ---- 测试 3：延迟持久化 —— 80 步（约 80 秒模拟）不应每次都写盘 ----
    local ppPath = "E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/Velm/pbz_pporig.json"
    local writes = WRITE_COUNT[ppPath] or 0
    check("后处理原值未每轮刷盘", writes <= 25,
        "80 步内写盘 " .. writes .. " 次（老实现每写一个字段就全量刷一次，会是几十上百次）")

    -- ---- 测试 4：原值落盘内容含体积名 ----
    local saved = FILES[ppPath] or ""
    check("原值文件已生成且非空", #saved > 10, "长度=" .. #saved)
    check("原值文件记录了体积全名", string.find(saved, "PostProcessVolume", 1, true) ~= nil, "")

    -- ---- 测试 5：换世界后不残留旧体积的原值（这是「越玩越卡」的根因）----
    -- 造一个「临时体积」：写完原值后把它标记为已销毁，再换世界。
    -- 正确行为：换世界清空 orig 后只记录当前存活体积，临时体积的全名不应再出现在文件里，
    -- 否则「玩久了 pporig 只增不减 → 每次写字段全量重刷 → 卡成 PPT」的老 bug 就回来了。
    local stale = addObj("PostProcessVolume", "/Game/Maps/LevelA.LevelA:PersistentLevel.PPV_Stale")
    stale.Settings = newSettings()
    fireNewObject("PostProcessVolume", stale)
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end
    local hadStale = ((FILES[ppPath] or ""):find("PPV_Stale", 1, true) ~= nil)
    check("换世界前临时体积的原值已被记录", hadStale, "未在 pporig 里找到 PPV_Stale")
    stale.__dead = true      -- 模拟这个体积在换图时被销毁
    local fog2 = WORLD["ExponentialHeightFogComponent"][1]
    fog2.__name = "/Game/Maps/LevelB.LevelB:PersistentLevel.Ultra_Dynamic_Sky_C_1.Fog"
    if MAPHOOK then pcall(MAPHOOK) end
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end
    local hasStaleAfter = ((FILES[ppPath] or ""):find("PPV_Stale", 1, true) ~= nil)
    check("换世界后旧体积原值已清空（不累积）", not hasStaleAfter, "换世界后 pporig 仍残留 PPV_Stale")

    -- ---- 测试 5b：同地图内新生成一个后处理体积（事件驱动，无全场景扫描）----
    -- 这是「传送后某些参数不生效」的等价场景：新体积一生成，事件通知 → 进列表 →
    -- 签名变化 → 全部字段重新下发。断言新体积也收到了 BloomIntensity。
    local pp3 = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PostProcessVolume_New")
    pp3.Settings = newSettings()
    pp3.bEnabled = true
    fireNewObject("PostProcessVolume", pp3)
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end
    check("新体积经事件登记后收到后处理", math.abs((pp3.Settings.__store.BloomIntensity or 0) - 2) < 1e-6,
        "值=" .. tostring(pp3.Settings.__store.BloomIntensity))

    -- ---- 测试 5d：换代后延迟出队（错开游戏自己的流式加载峰值）----
    -- 现场证据：11 次卡顿里 9 次落在 LoadMap 之后 6~16 秒，正是「换图后一口气重下发
    -- 936 次属性写」和游戏自己的贴图/PSO 加载撞在一起。所以换代后要等 RECONCILE_DELAY 秒。
    -- 断言两件事：①刚换代那 2 秒内一个新体积收不到值；②过了延迟就收到了。
    local pp4 = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PostProcessVolume_Delay")
    pp4.Settings = newSettings()
    pp4.bEnabled = true
    fireNewObject("PostProcessVolume", pp4)
    for i = 1, 2 do TIME = TIME + 1; pcall(stepOnce) end
    check("换代后延迟期内不下发（不跟游戏加载抢 CPU）",
        math.abs((pp4.Settings.__store.BloomIntensity or 0) - 2) > 1e-6,
        "值=" .. tostring(pp4.Settings.__store.BloomIntensity) .. "（延迟期内就被写了）")
    for i = 1, 6 do TIME = TIME + 1; pcall(stepOnce) end
    check("延迟结束后照常下发", math.abs((pp4.Settings.__store.BloomIntensity or 0) - 2) < 1e-6,
        "值=" .. tostring(pp4.Settings.__store.BloomIntensity))

    -- ---- 测试 5e：已销毁体积的墓碑记录不落盘 ----
    -- 现场实测 pporig 里 75 条记录有 36 条是 `TrashedPackage_NNNNN` 墓碑，
    -- 占 105KB / 约 40% 文件体积。它们永远不会再被访问，每 5 秒却要跟着全量序列化一次。
    -- 断言：写进这种体积的字段不出现在落盘内容里。
    local tomb = addObj("PostProcessVolume", "PostProcessVolume TrashedPackage_99999.PBZ_X:PersistentLevel.PPV_Dead")
    tomb.Settings = newSettings()
    tomb.bEnabled = true
    fireNewObject("PostProcessVolume", tomb)
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end
    local hasTomb = ((FILES[ppPath] or ""):find("TrashedPackage", 1, true) ~= nil)
    check("墓碑体积的记录不落盘（省 40% 序列化开销）", not hasTomb,
        "落盘内容里仍含 TrashedPackage")

    -- ---- 测试 5c：比例模式（原值 × 比例，且不点亮没开的体积）----
    -- 这是「天光漏光只想按比例压低、不想写死绝对值」的等价场景。
    -- 造两个体积：A 开了漏光（bOverride=true、原值 1.0），B 没开（原值 0）。
    -- 把 gi.skyleak 切到比例 0.5，正确行为是：A 被写成 0.5，B 保持 0 且不被强行打开。
    local ppA = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PPV_LeakA")
    ppA.Settings = newSettings()
    ppA.bEnabled = true
    ppA.Settings.__store.LumenSkylightLeaking = 1.0
    ppA.Settings.__store.bOverride_LumenSkylightLeaking = true
    local ppB = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PPV_LeakB")
    ppB.Settings = newSettings()
    ppB.bEnabled = true
    ppB.Settings.__store.LumenSkylightLeaking = 0.0
    ppB.Settings.__store.bOverride_LumenSkylightLeaking = false
    fireNewObject("PostProcessVolume", ppA)
    fireNewObject("PostProcessVolume", ppB)
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end

    -- 直接改参数表文件内容（模拟用户在面板上改），再让 schema 重新解析。
    -- 注意：不能直接改 schema.params() 里的表再 poll(true) —— poll 会从文件重建，改动会被丢掉。
    local schema = require("params.schema")
    local cfgJson = require("core.json")
    local cfgPath = "E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/Velm/pbz_tweaker.json"
    local function patchCfg(fn)
        local d = cfgJson.decode(FILES[cfgPath])
        for _, g in ipairs(d.groups or {}) do
            for _, p in ipairs(g.parameters or {}) do fn(p) end
        end
        FILES[cfgPath] = cfgJson.encode(d)
        return pcall(function() schema.poll(true) end)
    end
    local okReload = patchCfg(function(p)
        if p.key == "gi.skyleak" then p.mode = "ratio"; p.ratio = 50; p.enabled = true end
    end)
    for i = 1, 30 do TIME = TIME + 1; pcall(stepOnce) end
    local vA = ppA.Settings.__store.LumenSkylightLeaking
    local vB = ppB.Settings.__store.LumenSkylightLeaking
    local ovB = ppB.Settings.__store.bOverride_LumenSkylightLeaking
    check("比例模式：开了漏光的体积按比例压低", okReload and math.abs(vA - 0.5) < 1e-6, "A=" .. tostring(vA))
    check("比例模式：没开漏光的体积不被点亮", math.abs(vB) < 1e-9 and ovB ~= true,
        "B=" .. tostring(vB) .. " override=" .. tostring(ovB))

    -- ---- 测试 5d：切回绝对模式不会累乘 ----
    -- 期望：切模式时先还原（A 回到 1.0），再按绝对值写 0.25，结果是 0.25 而不是 0.5*0.5。
    patchCfg(function(p)
        if p.key == "gi.skyleak" then p.mode = "abs"; p.value = 0.25 end
    end)
    for i = 1, 30 do TIME = TIME + 1; pcall(stepOnce) end
    local vA2 = ppA.Settings.__store.LumenSkylightLeaking
    check("绝对模式切换后不累乘", math.abs(vA2 - 0.25) < 1e-6, "A=" .. tostring(vA2))

    -- ---- 测试 5e：偏移模式（原值 + Δ）----
    -- 用 gi.bias（AutoExposureBias，origin=0）验：造两个体积原值 -2 和 0，
    -- 偏移 +0.3 后应分别变成 -1.7 和 0.3 —— 这才满足用户"不同场景有正有负、统一调一档"。
    local ppC = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PPV_BiasC")
    ppC.Settings = newSettings()
    ppC.bEnabled = true
    ppC.Settings.__store.AutoExposureBias = -2.0
    ppC.Settings.__store.bOverride_AutoExposureBias = true
    local ppD = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PPV_BiasD")
    ppD.Settings = newSettings()
    ppD.bEnabled = true
    ppD.Settings.__store.AutoExposureBias = 0.0
    ppD.Settings.__store.bOverride_AutoExposureBias = true
    fireNewObject("PostProcessVolume", ppC)
    fireNewObject("PostProcessVolume", ppD)
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end

    patchCfg(function(p)
        if p.key == "gi.bias" then p.mode = "offset"; p.offset = 0.3; p.enabled = true end
    end)
    for i = 1, 30 do TIME = TIME + 1; pcall(stepOnce) end
    local vC = ppC.Settings.__store.AutoExposureBias
    local vD = ppD.Settings.__store.AutoExposureBias
    check("偏移模式：负原值加上偏移", math.abs(vC - (-1.7)) < 1e-6, "C=" .. tostring(vC))
    check("偏移模式：零原值也生效", math.abs(vD - 0.3) < 1e-6, "D=" .. tostring(vD))

    -- ---- 测试 5f：origin=1 的参数按倍率中性缩放 ----
    -- gi.lumenboost（LumenDiffuseColorBoost，origin=1）原值 1.7，比例 50%
    -- 期望 1 + (1.7-1)*0.5 = 1.35。若错误地用 origin=0 会得到 0.85（比中性还暗）。
    local ppE = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PPV_BoostE")
    ppE.Settings = newSettings()
    ppE.bEnabled = true
    ppE.Settings.__store.LumenDiffuseColorBoost = 1.7
    ppE.Settings.__store.bOverride_LumenDiffuseColorBoost = true
    fireNewObject("PostProcessVolume", ppE)
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end
    patchCfg(function(p)
        if p.key == "gi.lumenboost" then p.mode = "ratio"; p.ratio = 50; p.enabled = true end
    end)
    for i = 1, 30 do TIME = TIME + 1; pcall(stepOnce) end
    local vE = ppE.Settings.__store.LumenDiffuseColorBoost
    check("比例模式按 origin=1 缩放（不是当 0 用）", math.abs(vE - 1.35) < 1e-6, "E=" .. tostring(vE))

    -- ---- 测试 5g：没有可靠原点的参数不允许比例 ----
    -- gi.evmin（AutoExposureMinBrightness）origin=null，即使参数表写了 ratio 也必须退回绝对。
    local ppF = addObj("PostProcessVolume", "/Game/Maps/LevelB.LevelB:PersistentLevel.PPV_EvMinF")
    ppF.Settings = newSettings()
    ppF.bEnabled = true
    ppF.Settings.__store.AutoExposureMinBrightness = -17
    ppF.Settings.__store.bOverride_AutoExposureMinBrightness = true
    fireNewObject("PostProcessVolume", ppF)
    for i = 1, 20 do TIME = TIME + 1; pcall(stepOnce) end
    patchCfg(function(p)
        if p.key == "gi.evmin" then p.mode = "ratio"; p.ratio = 50; p.value = -8; p.enabled = true end
    end)
    for i = 1, 30 do TIME = TIME + 1; pcall(stepOnce) end
    local vF = ppF.Settings.__store.AutoExposureMinBrightness
    check("无原点参数强制退回绝对（不按比例算）", math.abs(vF - (-8)) < 1e-6, "F=" .. tostring(vF))

    -- ---- 测试 6：连续运行不出错（等价于「不静默失效」）----
    local okRun = pcall(function()
        for i = 1, 60 do TIME = TIME + 1; stepOnce() end
    end)
    check("长时间运行无异常", okRun, "")

    -- ---- 测试 7：面板拉起有熔断，不会无限 os.execute ----
    local execBefore = EXEC_COUNT or 0
    -- 心跳文件不存在 → 判死 → 拉起（但受冷却与熔断约束）
    for i = 1, 200 do TIME = TIME + 1; pcall(stepOnce) end
    local execTotal = EXEC_COUNT or 0
    check("面板拉起不无限重试", execTotal <= 6,
        "1200 步内拉起尝试 " .. execTotal .. " 次（老实现一天 89 次、形成死循环）")

    -- ---- 测试 8：json 往返 ----
    local json = require("core.json")
    local sample = { a = 1, b = "文本", c = true, d = { 1, 2, 3 }, e = { x = 0.5 } }
    local enc = json.encode(sample)
    local dec = json.decode(enc)
    check("json 往返一致", dec and dec.a == 1 and dec.b == "文本" and dec.c == true
        and dec.d[2] == 2 and math.abs(dec.e.x - 0.5) < 1e-9, enc)

    -- ---- 测试 9：store 延迟写盘 ----
    local store = require("core.store")
    local s = store.new({ path = "E:/sim_store.json", name = "sim", interval = 5, encode = json.encode,
        decode = function(t) return json.decode(t) end })
    s.load()
    s.set("k", 1)
    local w1 = s.flushIfDue(100)      -- 到点，写
    local w2 = s.flushIfDue(101)      -- 未到间隔，不写
    s.set("k", 2)                     -- 再来一次改动
    local w3 = s.flushIfDue(106)      -- 已过 5 秒间隔，写
    check("store 到点才落盘", w1 == true and w2 == false and w3 == true,
        string.format("100=%s 101=%s 106=%s", tostring(w1), tostring(w2), tostring(w3)))

    -- ---- 测试 10：计时源走引擎墙钟，不是 os.clock ----
    -- 这一条是本次改动的根基：如果 timing 退化成 os.time，
    -- 卡顿检测就完全失效了（os.time 只有整秒，且模拟环境里是固定值）。
    local timing = require("core.timing")
    check("计时源用引擎墙钟（能检测卡顿的前提）",
        timing.source() == "engine",
        "实际=" .. tostring(timing.source()))

    -- ---- 测试 11：卡顿会冻结下发 ----
    -- 注入 3 秒延迟（阈值 0.5 秒），下一轮应当什么都不写。
    -- 用一个还没下发过的字段来验证：冻结期内它不该被写。
    local ppFreeze = addObj("PostProcessVolume",
        "/Game/Maps/Test/PPV_Freeze.PPV_Freeze",
        { Settings = newSettings() })
    ppFreeze.Settings.__store.BloomIntensity = 0
    ppFreeze.bEnabled = true
    -- 必须走事件登记，否则 objects 列表里没有它（事件驱动模式下不做全场景扫描）
    fireNewObject("PostProcessVolume", ppFreeze)
    -- 让它进入待下发队列。
    -- ★ 必须同时推进 TIME：pp.poll 内部用 os.time() 做 1 秒节流，
    --   只推 VCLOCK 不动 TIME 的话，refresh() 永远不跑，新体积永远进不来。
    for i = 1, 30 do TIME = TIME + 1; stepOnce() end
    local beforeFreeze = ppFreeze.Settings.__store.BloomIntensity
    -- 先确认它确实被下发过（否则下面的「冻结」断言会假通过）
    check("冻结测试前置：新体积已收到下发",
        math.abs((beforeFreeze or 0) - 2) < 1e-6,
        "值=" .. tostring(beforeFreeze))

    -- 制造一次卡顿
    _G.__advanceClock(3.0)
    local okStall = pcall(stepOnce)
    check("卡顿当轮不抛异常", okStall, "")

    -- 冻结期内推 10 轮，字段不应变化
    local afterFreeze = ppFreeze.Settings.__store.BloomIntensity
    for i = 1, 10 do TIME = TIME + 1; stepOnce() end
    local afterSkip = ppFreeze.Settings.__store.BloomIntensity
    check("卡顿当轮冻结（不跟游戏抢 CPU）",
        afterFreeze == beforeFreeze,
        string.format("前=%s 卡顿轮后=%s", tostring(beforeFreeze), tostring(afterFreeze)))
    check("冻结期内持续不写", afterSkip == beforeFreeze,
        string.format("冻结后=%s 期望=%s", tostring(afterSkip), tostring(beforeFreeze)))

    -- ---- 测试 12：冻结结束后恢复下发 ----
    for i = 1, 25 do TIME = TIME + 1; stepOnce() end
    check("冻结结束后恢复下发",
        math.abs((ppFreeze.Settings.__store.BloomIntensity or 0) - 2) < 1e-6,
        "值=" .. tostring(ppFreeze.Settings.__store.BloomIntensity))

    -- ---- 测试 12b：持续慢时不冻结（BOSS 战掉帧场景）----
    -- 实机踩到的坑：第一版用绝对阈值 0.5 秒，打 BOSS 时游戏本来就持续掉帧，
    -- 每轮都 >0.5 秒 → 每轮都判卡顿 → 冻结 15 轮 → 下一轮又判 → 整场战斗
    -- 插件一次都不跑，参数永远不生效。这比卡顿更糟。
    -- 正确行为：持续慢的时候基线自己升上去，插件继续工作。
    local ppSlow = addObj("PostProcessVolume",
        "/Game/Maps/Test/PPV_Slow.PPV_Slow", { Settings = newSettings() })
    ppSlow.Settings.__store.BloomIntensity = 0
    ppSlow.bEnabled = true
    fireNewObject("PostProcessVolume", ppSlow)
    -- 用 0.45 秒/轮（慢，但稳定）跑 60 轮：不该被反复冻结
    for i = 1, 60 do
        TIME = TIME + 1
        _G.__advanceClock(0.25)      -- 在 stepOnce 自带的 0.2 基础上再加，总共 0.45
        stepOnce()
    end
    check("持续掉帧（BOSS 战）时不会一直冻结、参数照常下发",
        math.abs((ppSlow.Settings.__store.BloomIntensity or 0) - 2) < 1e-6,
        "值=" .. tostring(ppSlow.Settings.__store.BloomIntensity))

    -- ---- 测试 13：换世界会重置时间基准（否则新 World 会被误判成卡顿）----
    local okInv = pcall(function()
        timing.invalidate()
        stepOnce()
    end)
    check("换世界后重置时间基准不抛异常", okInv, "")
end

-- ============================================================ 输出

local pass, fail = 0, 0
local lines = {}
for _, r in ipairs(RESULTS) do
    if r.ok then pass = pass + 1; table.insert(lines, "  PASS  " .. r.name)
    else fail = fail + 1; table.insert(lines, "  FAIL  " .. r.name .. "   [" .. r.detail .. "]") end
end

SUMMARY = table.concat(lines, "\n") .. string.format("\n结果: %d 通过 / %d 失败", pass, fail)
FAILED = fail
