-- 世界生命周期。
--
-- 解决的问题：换场景 / 传送后，所有缓存的 UObject 引用全部失效。老实现是
-- resetForNewWorld() 里手工列一串变量逐个置 nil。手工列表必然漏 ——
-- 实际就漏了 ppOrig，导致那个文件只增不减，最后膨胀到 446KB、
-- 每写一个后处理字段都要全量重刷一次，游戏卡成 PPT。
--
-- 新做法：各模块自己在加载时注册「换世界要做什么」，world 只负责在检测到
-- 换世界时挨个调用。以后加模块不会再漏。
--
-- 检测方式（事件驱动）：RegisterLoadMapPostHook —— 引擎每次加载完地图通知一次，
-- 我们只置一个标记，真正处理放到主循环（不在引擎钩子里做重活）。
-- 仅当这个 UE4SS 版本没有地图钩子时，才退回旧的「每 2 秒扫第一个雾组件名」轮询。

local log     = require("core.log")
local ue      = require("core.ue")
local objects = require("core.objects")

local world = {}

local hooks = {}
local suspendUntil = 0
local pendingNewWorld = false

-- 注册换世界回调。fn 不带参数，自己清自己的缓存。
function world.onNewWorld(name, fn)
    hooks[#hooks + 1] = { name = name, fn = fn }
end

-- 换场景的静默期：世界正在批量销毁对象，这时候任何 FindAllOf / GetOwner /
-- 属性读写都可能拿到半死对象，IsValid 拦不住原生层越界 → 崩溃。
-- 静默期内主循环整轮跳过。
function world.suspend(seconds)
    suspendUntil = os.time() + (seconds or 5)
end

function world.suspended()
    return os.time() < suspendUntil
end

-- ---------------------------------------------------------------- 事件注册

local hasMapHook = (type(RegisterLoadMapPostHook) == "function")

if hasMapHook then
    local ok = pcall(function()
        RegisterLoadMapPostHook(function()
            -- 引擎钩子里只置标记，绝不在这里做扫描/读写（对象可能还没就绪）。
            pendingNewWorld = true
        end)
    end)
    if not ok then
        hasMapHook = false
        log.once("world:nohook", "RegisterLoadMapPostHook 注册失败，退回轮询检测换图")
    end
end

-- ---------------------------------------------------------------- 旧式轮询兜底

-- 仅在没有地图钩子时使用。
local lastMap = nil
local lastProbe = 0
local PROBE_INTERVAL = 2

local function currentMap()
    local arr = objects.get("ExponentialHeightFogComponent")
    if #arr == 0 then return nil end
    local c = arr[1]
    if not ue.alive(c) then return nil end
    local okn, nm = pcall(function() return c:GetFullName() end)
    if not okn or not nm then return nil end
    local path = string.match(nm, "^(.+)%.[^%.]+%.[^%.]+$") or nm
    return path
end

-- ---------------------------------------------------------------- 检测

local function fireNewWorld(reason)
    world.suspend(5)
    objects.invalidateAll()
    ue.invalidate()
    log.info("换世界: " .. (reason or ""))
    for _, h in ipairs(hooks) do
        local ok, err = pcall(h.fn)
        if not ok then
            log.once("world:" .. h.name, "换世界回调失败 [" .. h.name .. "]: " .. tostring(err))
        end
    end
end

-- 每轮主循环调用。检测到换世界就执行所有回调。
function world.check()
    if hasMapHook then
        if not pendingNewWorld then return false end
        pendingNewWorld = false
        fireNewWorld("LoadMap 事件")
        return true
    end

    -- 兜底轮询
    local now = os.time()
    if (now - lastProbe) < PROBE_INTERVAL then return false end
    lastProbe = now
    local map = currentMap()
    if not map then return false end
    if lastMap == nil then
        lastMap = map
        return false
    end
    if lastMap == map then return false end
    lastMap = map
    fireNewWorld((string.match(map, "([^/]+)$") or map))
    return true
end

-- 强制重建基线（兜底轮询模式下用；事件模式无副作用）。
function world.forget()
    lastMap = nil
    lastProbe = 0
end

return world
