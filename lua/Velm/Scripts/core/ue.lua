-- 引擎胶水：所有「和 UE 对象打交道」的底层动作都收在这里。
--
-- 这一层不包含任何业务语义（不知道什么是雾、什么是后处理），只回答四件事：
--   1. 怎么拿到控制器 / GameInstance / KismetSystemLibrary
--   2. 怎么判断一个对象还能不能碰
--   3. 怎么读一个数值属性
--   4. 怎么把一个数值写进去（并且真的推给渲染器）
--
-- 为什么必须集中：这些动作每一个都踩过坑（IsValid 对已标记销毁的对象仍返回 true、
-- 包装对象不能用 == 比较、直接写属性不触发渲染状态重建），散落各处必然重复踩。

local log = require("core.log")

local ue = {}

-- ---------------------------------------------------------------- 常用单例

local pcRef = nil
local giRef = nil
local kslRef = nil

function ue.pc()
    if not pcRef then pcRef = FindFirstOf("PlayerController") end
    return pcRef
end

-- 世界上下文用 GameInstance 而不是 PlayerController：
-- 已验证 ExecuteConsoleCommand 在 GameInstance 上可用（参考 puerts 版本）。
function ue.gi()
    if not giRef then giRef = FindFirstOf("GameInstance") end
    return giRef
end

function ue.ksl()
    if kslRef then return kslRef end
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if ok and obj and ue.alive(obj) then
        kslRef = obj
        return kslRef
    end
    return nil
end

-- 场景切换后这些引用全失效，必须能主动清空。
function ue.invalidate()
    pcRef, giRef, kslRef = nil, nil, nil
end

-- ---------------------------------------------------------------- 对象验活

-- 最宽松的验活：只问 IsValid。
-- 注意它不够安全 —— 对象被标记「待销毁」时 IsValid 仍可能返回 true，
-- 这时读属性就是访问已释放内存（pcall 拦不住原生 AV）。
function ue.alive(v)
    if v == nil then return false end
    local ok, x = pcall(function() return v:IsValid() end)
    return ok and x == true
end

-- 严格验活：给「会被关卡流式加载批量重建」的对象用（后处理体积、雾组件）。
-- 在 IsValid 之外还要求：能取到非空全名、且没有待销毁标记。
function ue.usable(v)
    if not ue.alive(v) then return false end
    local okn, nm = pcall(function() return v:GetFullName() end)
    if not okn or type(nm) ~= "string" or #nm == 0 then return false end
    local okp, pk = pcall(function() return v:IsPendingKillPending() end)
    if okp and pk == true then return false end
    return true
end

-- 判断是不是同一个 UObject。
-- 绝对不能用 Lua 的 == / ~=：UE4SS 每次取值都返回新的包装对象，
-- 即使指向同一个原生对象，Lua 层的表也不相等。
-- 这个坑导致过「隐藏雾组件时把自己的副本一起隐藏了」。
function ue.same(a, b)
    if a == nil or b == nil then return false end
    local oka, aa = pcall(function() return a:GetAddress() end)
    local okb, bb = pcall(function() return b:GetAddress() end)
    if oka and okb and aa and bb then return aa == bb end
    -- 退化路径：比全名（地址取不到时用）
    local ok1, n1 = pcall(function() return a:GetFullName() end)
    local ok2, n2 = pcall(function() return b:GetFullName() end)
    return ok1 and ok2 and n1 == n2
end

-- 对象身份标识：优先用全名（组件名唯一且稳定），地址取不到才退化到 tostring。
-- 为什么需要：锁定主光时要比「是不是同一个组件」，而包装对象每次都是新的。
function ue.key(o)
    local ok, str = pcall(function() return o:GetFullName() end)
    if ok and str then return str end
    local ok2, s2 = pcall(function() return tostring(o) end)
    if ok2 and s2 then return string.match(s2, "(%x%x%x%x%x%x%x%x+)") end
    return nil
end

-- ---------------------------------------------------------------- 属性读写

-- 读一个数值属性。三条路径依次尝试：
--   1. GetPropertyValue 返回包装对象 → :get()
--   2. GetPropertyValue 直接返回数字
--   3. 直接索引 obj[name]
function ue.readNum(obj, name)
    local ok, v = pcall(function() return obj:GetPropertyValue(name) end)
    if ok and v ~= nil then
        local ok2, n = pcall(function() return v:get() end)
        if ok2 and type(n) == "number" then return n end
        if type(v) == "number" then return v end
    end
    local ok3, direct = pcall(function() return obj[name] end)
    if ok3 and type(direct) == "number" then return direct end
    return nil
end

-- 写一个数值属性。
-- 必须先走 setter：setter 内部会 MarkRenderStateDirty，把新值推给渲染器。
-- 直接写属性只改内存 —— 读回来是对的，但画面不变。
-- 这就是「值确实写进去了却一点效果都没有」的根因。
local setterLogged = {}

function ue.writeNum(comp, setter, prop, value)
    if setter then
        local ok = pcall(function() comp[setter](comp, value) end)
        if ok then
            if not setterLogged[prop] then
                setterLogged[prop] = true
                log.once("setter:" .. prop, "set " .. prop .. " -> " .. setter)
            end
            return true
        end
    end
    local ok2 = pcall(function() comp:SetPropertyValue(prop, value) end)
    if ok2 then
        if not setterLogged[prop] then
            setterLogged[prop] = true
            log.once("setter:" .. prop, "set " .. prop .. " -> SetPropertyValue（setter 不可用，画面可能不刷新）")
        end
        return true
    end
    return false
end

-- 写一个布尔属性（bVisible / bHiddenInGame 这类）。
-- SetVisibility 在这个 build 里是 TrivialObject，调了也没反应，所以优先写字段。
function ue.writeBool(obj, prop, value)
    local ok = pcall(function() obj[prop] = value end)
    return ok
end

-- 直接写任意字段（表、结构体等）。
function ue.write(obj, prop, value)
    return pcall(function() obj[prop] = value end)
end

function ue.read(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if ok then return v end
    return nil
end

-- 调用一个无返回值的方法，失败返回 false + 错误。
function ue.call(obj, method, ...)
    local args = table.pack(...)
    local ok, err = pcall(function()
        obj[method](obj, table.unpack(args, 1, args.n))
    end)
    return ok, err
end

-- 全名（只取末段，日志里更好看）
function ue.shortName(obj)
    local ok, nm = pcall(function() return obj:GetFullName() end)
    if not ok or not nm then return "?" end
    return string.match(nm, "([%w_]+)$") or nm
end

return ue
