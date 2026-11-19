-- 每帧钩子：只给雾密度用。
--
-- 为什么必须有它：某些区域游戏每帧改写 FogDensity（UDS 天气系统驱动），
-- 200ms 一次的轮询永远抢不过 —— 表现就是「调了没反应」或「忽明忽暗」。
-- 唯一可靠的办法是在游戏自己的帧里动手。
--
-- ★ 单一写入者：装了这个钩子之后，雾密度**只有本模块一个写入者**，
-- params/engine 里的 fog.density 会让位（见 routes 的 hookManaged）。
-- 老版本同时保留了三条写入路径（engine 轮询 + SetFogDensity 钩子 + 副本镜像），
-- 互相打架，还踩过「延迟写入导致累乘、雾越乘越淡最后消失」的坑。
--
-- 两路钩子（都是从老版本原样移植、实机验证过的做法，不能省）：
--   1. SetFogDensity 钩子：游戏调 setter 时立刻按比例回写。这是主路径。
--      它同时记录「游戏写进来的原始值」。
--   2. Engine:Tick 钩子：某些路径游戏直接改字段、不走 setter，拦不到；
--      每帧强制按「原始值 × 比例」写一次兜底。
-- 两者都属于本模块 —— 写入者仍然只有一个。
--
-- 写入方式：直接写字段，不走 setter。
-- 走 setter 会 MarkRenderStateDirty，反复调用会打断体积雾的时域累积 —— 就是闪烁的根因。
--
-- ★ 防累乘（血泪教训）：
-- 曾经试过「等游戏值稳定后再写」，结果形成衰减链：
--   我们写 0.00128 → 游戏读到这个值再写 → 我们又乘 0.4 → 0.0005 → …
--   雾被越乘越淡，最后完全消失。
-- 判据：游戏写进来的值如果接近我们上次写出去的值（3% 内），说明它是从我们这里
-- 读走的，就不要再乘一次，直接跳过。

local log = require("core.log")
local ue  = require("core.ue")

local hooks = {}

local installed = false
local comp = nil          -- 当前要操作的雾组件（主循环定期同步进来）
local lastWritten = nil   -- 我们上次写出去的值
local lastRaw = nil       -- 游戏上一次写进来的原始密度
local selfWrite = false   -- 防重入（hook 内写字段会再触发 setter，必须挡住）
local setterHits = 0
local tickHits = 0

function hooks.active()
    return installed
end

-- 主循环每轮调用，把「当前游戏那盏雾」同步进来。
-- ★ 换了组件（传送 / 同地图内流式加载把旧的雾组件销毁重建）时必须清掉
--   lastRaw / lastWritten，否则会拿旧地图的原始密度当基准，把新地图的雾写歪
--   —— 表现就是「传送后雾的浓度不对，动一下参数才恢复」。
--   用 ue.same 判身份（包装对象每次取值都是新的，不能用 ==）。
function hooks.bind(component)
    if component == nil then
        comp = nil
        return
    end
    if comp ~= nil and not ue.same(comp, component) then
        lastRaw = nil
        lastWritten = nil
    end
    comp = component
end

-- 钩子还没装上时的「交接」：engine 的 ratio 模式已经在写雾密度，
-- 它算出的 base（游戏原始值）交给钩子当 lastRaw。
-- 不交接的话，钩子装上的那一刻会拿「已经乘过比例的值」当基准再乘一次 —— 累乘成双重缩放。
-- 模拟测试抓到过：0.024 × 0.8（engine）→ 再 × 0.8（钩子）= 0.01536，画面会突然变淡。
function hooks.seedBase(v)
    if v and v > 1e-9 then
        lastRaw = v
        lastWritten = nil
    end
end

function hooks.install(fogModule)
    if installed then return true end

    local function curComp()
        local c = comp
        if c == nil then return nil end
        if not ue.alive(c) then
            comp = nil
            return nil
        end
        return c
    end

    -- ---- 1. SetFogDensity 钩子（主路径：游戏走 setter 时立刻回写）----
    local ok1, err1 = pcall(function()
        RegisterHook("/Script/Engine.ExponentialHeightFogComponent:SetFogDensity",
            function(Context, NewValue)
                if selfWrite then return end
                local r = fogModule.getRatio() or 1
                if r == 1 then return end

                local nv = NewValue
                if type(nv) ~= "number" then
                    local okn, x = pcall(function() return nv:get() end)
                    if okn then nv = x end
                end
                nv = tonumber(nv)
                if not nv then return end

                -- 目标组件：钩子里能拿到触发者用触发者，否则用主循环绑定那个
                local c
                local okc, ctx = pcall(function() return Context:get() end)
                if okc and ctx and ue.alive(ctx) then c = ctx else c = curComp() end
                if not c then return end

                setterHits = setterHits + 1

                local target = nv * r
                -- 防累乘：游戏写进来的值接近我们上次写的 → 是回读，跳过
                if lastWritten and math.abs(nv - lastWritten) <= math.abs(lastWritten) * 0.03 then
                    if setterHits % 500 == 0 then
                        log.info(string.format("雾钩子: 第 %d 次，检测到回读自身值 %.6f，跳过", setterHits, nv))
                    end
                    return
                end

                lastRaw = nv
                fogModule.setRawDensity(nv)
                selfWrite = true
                pcall(function() c.FogDensity = target end)
                selfWrite = false
                lastWritten = target

                if setterHits == 1 or setterHits % 500 == 0 then
                    log.info(string.format("雾钩子: 第 %d 次，写入 %.6f（游戏 %.6f × %.2f）", setterHits, target, nv, r))
                end
            end)
    end)

    -- ---- 2. Engine:Tick 钩子（兜底：游戏绕过 setter 直接改字段时）----
    -- 必须极度轻量：每帧都跑，不能写日志（会拖慢帧）。
    local ok2, err2 = pcall(function()
        RegisterHook("/Script/Engine.Engine:Tick",
            function()
                if selfWrite then return end
                local r = fogModule.getRatio() or 1
                if r == 1 then return end
                local c = curComp()
                if not c then return end
                local base = lastRaw
                -- 首次：如果游戏从没走过 setter（某些路径直接改字段），
                -- 我们还没拿到原始值。此时读当前值当基准 —— 但只在还没写过的时候，
                -- 否则读到的是我们自己写的值，会被再乘一次（累乘）。
                if not base and lastWritten == nil then
                    base = ue.readNum(c, "FogDensity")
                    if base then
                        lastRaw = base
                        fogModule.setRawDensity(base)
                    end
                end
                if not base then return end
                selfWrite = true
                pcall(function() c.FogDensity = base * r end)
                selfWrite = false
                tickHits = tickHits + 1
            end)
    end)

    if ok1 or ok2 then
        installed = true
        log.info("雾钩子已安装（SetFogDensity=" .. tostring(ok1) .. " Tick=" .. tostring(ok2) .. "）")
    else
        log.info("雾钩子安装失败: setter=" .. tostring(err1) .. " tick=" .. tostring(err2) .. " —— 回退 200ms 轮询")
    end
    return installed
end

function hooks.forget()
    comp = nil
    lastWritten = nil
    lastRaw = nil
end

return hooks
