-- 分辨率 / 渲染缩放（handler = "gus"）。
--
-- 走引擎官方 API：UGameUserSettings 内部自己去写 cvar（Scalability 那套没被
-- Shipping 编译掉），所以既不用控制台，也不依赖任何特征码，游戏更新不会坏。
--
-- 这里的历史坑：
--   · 同一个值每 200ms 重下一次会让 swapchain 反复重建 → 卡顿。所以「同值不重复下发」。
--   · 连续失败也要锁定，否则会每轮重试，同样在重建 swapchain。
--   · 面板上的分辨率下拉是「改游戏窗口」，和这个 handler 是两条不同的路：
--     面板那条（handler="app"）由 C# 直接 SetWindowPos，Lua 不参与。

local log = require("core.log")
local ue  = require("core.ue")

local gus = {}

local ref     = nil
local logged  = false
local missing = false
local last    = {}   -- target -> 上次下发的签名
local tries   = {}   -- target -> 连续失败次数

-- 0=独占全屏 1=无边框窗口(推荐) 2=普通窗口
local MODES = { f = 0, w = 1, x = 2 }

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return (ok and v) and true or false
end

local function get()
    if valid(ref) then return ref end
    ref = nil
    -- 首选：从引擎对象的 GameUserSettings 属性取，游戏自定义子类也能拿到
    local eng = nil
    local ok1, e1 = pcall(function() return FindFirstOf("GameEngine") end)
    if ok1 and e1 then eng = e1 end
    if not eng then
        local ok2, e2 = pcall(function() return FindFirstOf("Engine") end)
        if ok2 and e2 then eng = e2 end
    end
    if eng then
        local ok3, v = pcall(function() return eng.GameUserSettings end)
        if ok3 and valid(v) then ref = v end
    end
    if not ref then
        local ok4, v = pcall(function() return FindFirstOf("GameUserSettings") end)
        if ok4 and valid(v) then ref = v end
    end
    if not ref then
        local ok5, list = pcall(function() return FindAllOf("GameUserSettings") end)
        if ok5 and list and #list > 0 and valid(list[1]) then ref = list[1] end
    end
    if ref and not logged then
        logged = true
        log.info("GUS 就绪: " .. ue.shortName(ref))
    end
    return ref
end

-- 成功就锁定不再下发；连续失败 3 次也锁定，避免每 200ms 反复重设窗口。
local function done(target, sig, ok)
    local n = (tries[target] or 0) + 1
    tries[target] = n
    if ok or n >= 3 then last[target] = sig end
end

function gus.apply(p)
    local sig = tostring(p.target) .. "=" .. tostring(p.value)
    if last[p.target] == sig then return end
    local g = get()
    if not g then
        if not missing then
            missing = true
            log.info("找不到 GameUserSettings，分辨率/渲染缩放不可用")
        end
        return
    end

    if p.target == "scale" then
        local v = tonumber(p.value) or 100
        local okSet = pcall(function() g:SetResolutionScaleValueEx(v) end)
        if not okSet then
            pcall(function() g:SetResolutionScaleNormalized(v / 100) end)
        end
        local okApply = pcall(function() g:ApplyNonResolutionSettings() end)
        if not okApply then
            okApply = pcall(function() g:ApplySettings(false) end)
        end
        log.info(string.format("res.scale %.0f%% set=%s apply=%s", v, tostring(okSet), tostring(okApply)))
        if okSet or okApply then last[p.target] = sig else done(p.target, sig, false) end
        return
    end

    if p.target == "mode" then
        local s = tostring(p.value)
        if s == "none" then
            last[p.target] = sig
            return
        end
        local w, h, m = s:match("^(%d+)x(%d+)(%a)$")
        local nx, ny, mode = tonumber(w), tonumber(h), MODES[m]
        if not nx or not ny or not mode then
            log.info("res.mode 参数无法解析: " .. s)
            return
        end
        -- 方式一：官方接口。FIntPoint 用表传，失败再退方式二
        local okA = pcall(function() g:SetScreenResolution({ X = nx, Y = ny }) end)
        pcall(function() g:SetFullscreenMode(mode) end)
        local okC = false
        if okA then okC = pcall(function() g:ApplyResolutionSettings(false) end) end
        if not (okA and okC) then
            -- 方式二：直接写属性，再让引擎自己应用
            pcall(function() g:SetPropertyValue("ResolutionSizeX", nx) end)
            pcall(function() g:SetPropertyValue("ResolutionSizeY", ny) end)
            pcall(function() g:SetPropertyValue("FullscreenMode", mode) end)
            pcall(function() g:SetPropertyValue("LastConfirmedFullscreenMode", mode) end)
            okC = pcall(function() g:ApplyResolutionSettings(false) end)
        end
        log.info(string.format("res.mode %dx%d mode=%d api=%s apply=%s 读回=%sx%s/%s",
            nx, ny, mode, tostring(okA), tostring(okC),
            tostring(ue.readNum(g, "ResolutionSizeX")), tostring(ue.readNum(g, "ResolutionSizeY")),
            tostring(ue.readNum(g, "FullscreenMode"))))
        if okA and okC then last[p.target] = sig else done(p.target, sig, false) end
        return
    end
end

function gus.forget()
    ref = nil
    last = {}
    tries = {}
end

return gus
