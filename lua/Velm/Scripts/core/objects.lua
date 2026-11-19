-- 对象登记中心。
--
-- 解决的问题：旧实现靠「每 2 秒 / 每 8 秒 FindAllOf 全场景扫描」来发现新对象。
-- FindAllOf 会把游戏里所有 UObject 遍历一遍，就算几十毫秒，在 4 倍帧生成下
-- 也会被放大成肉眼可见的卡顿。所以战斗里不能有任何周期性全量扫描。
--
-- 新做法：事件驱动。
--   · NotifyOnNewObject(类名, 回调) —— 引擎每次新建这个类的对象就通知我们一次。
--     回调里只把对象引用塞进列表，绝不读属性（对象这时可能还没构造完，读就踩雷）。
--   · RegisterLoadMapPostHook —— 换图时通知一次（由 core.world 统一处理），
--     我们清空登记表、下次访问时重新播种（只发生在加载界面，不在战斗中）。
--   · 每次取用时做一次惰性验活（IsValid），死对象顺手剔除 —— 只有几十个对象，
--     微秒级，可以放心每次都做。
--
-- 兼容：如果这个 UE4SS 版本没有 NotifyOnNewObject（或某类注册抛错），该类退回
-- 「按需 FindAllOf + 8 秒节流」。功能不丢，只是该类回到低频扫描，绝不会退化成
-- 每帧全扫。

local log = require("core.log")
local ue  = require("core.ue")

local objects = {}

local lists    = {}    -- class -> { obj, ... }（登记顺序，可能含死对象，取用时清理）
local seeded   = {}    -- class -> true：已做过一次 FindAllOf 播种
local dirty    = {}    -- class -> true：换图后需要重新播种
local watching = {}    -- class -> true：已注册过 NotifyOnNewObject
local subOk    = {}    -- class -> true：该类事件订阅成功（可增量）；false → 需按需扫描
local lastScan = {}    -- class -> 上次兜底扫描的 os.time()

local hasNotify = (type(NotifyOnNewObject) == "function")

local FALLBACK_TTL = 8   -- 秒：无事件时的兜底扫描节流

function objects.available()
    return hasNotify
end

-- 用 FindAllOf 填一个类的登记表（只存引用，不改属性）。
local function seedFrom(class)
    lists[class] = {}
    local ok, arr = pcall(function() return FindAllOf(class) end)
    if ok and arr then
        local l = lists[class]
        for i = 1, #arr do
            if arr[i] ~= nil then l[#l + 1] = arr[i] end
        end
    end
    seeded[class] = true
    dirty[class] = false
    lastScan[class] = os.time()
end

-- 监听某一类的新对象。只登记引用，不碰对象属性。
function objects.watch(class)
    if watching[class] then return end
    watching[class] = true
    lists[class] = lists[class] or {}
    if not hasNotify then
        subOk[class] = false
        return
    end
    local function try(name)
        return pcall(function()
            NotifyOnNewObject(name, function(obj)
                if obj == nil then return end
                local l = lists[class]
                if l then l[#l + 1] = obj end
            end)
        end)
    end
    -- 先试短名，失败再试全名（不同 UE4SS 版本/引擎对类名格式要求不同）。
    local ok, err = try(class)
    if not ok then
        local ok2 = try("/Script/Engine." .. class)
        if ok2 then
            ok = true
        else
            subOk[class] = false
            log.once("objects:nofail:" .. class,
                "NotifyOnNewObject 订阅失败（" .. class .. "/全名均失败: " ..
                tostring(err) .. "），该类退回按需扫描")
            return
        end
    end
    subOk[class] = true
end

-- 换图：标记所有已登记的类需要重新播种。真正扫描延迟到下次 objects.get。
function objects.invalidateAll()
    for class in pairs(lists) do dirty[class] = true end
end

-- 取某类的存活对象列表（去重 + 验活）。这是调用方唯一应该用的入口。
function objects.get(class)
    objects.watch(class)

    if subOk[class] then
        -- 事件模式：只在首次 / 换图后播种一次，平时靠事件增量，不做全扫。
        if not seeded[class] or dirty[class] then seedFrom(class) end
    else
        -- 兜底模式：不能靠事件发现新对象，只能按需扫描 + 节流。
        if not seeded[class] or dirty[class] then
            seedFrom(class)
        elseif (os.time() - (lastScan[class] or 0)) >= FALLBACK_TTL then
            seedFrom(class)
        end
    end

    -- 惰性滤波：去死对象 + 去重（按地址）。
    local src = lists[class]
    local out = {}
    local seen = {}
    for i = 1, #src do
        local o = src[i]
        if ue.alive(o) then
            local addr = nil
            local oka, a = pcall(function() return o:GetAddress() end)
            if oka and a ~= nil then addr = tostring(a) end
            if addr == nil then addr = ue.key(o) or ("idx" .. i) end
            if not seen[addr] then
                seen[addr] = true
                out[#out + 1] = o
            end
        end
    end
    lists[class] = out
    return out
end

-- 取第一个存活对象（等价于旧 FindFirstOf）。
function objects.first(class)
    local l = objects.get(class)
    return l[1]
end

return objects
