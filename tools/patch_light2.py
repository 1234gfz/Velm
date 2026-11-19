# -*- coding: utf-8 -*-
"""把 lightProbe 换成「直接找组件类实例」的版本。

第一版失败原因：FindAllOf("DirectionalLight") 返回 0。
那个只匹配精确类名，游戏的太阳光很可能是蓝图子类（BP_XXX_Sun_C 之类），
或者根本不用 DirectionalLight 而是烘焙光 + SkyLight。
改成直接找 DirectionalLightComponent / SkyLightComponent 的实例，
组件类是引擎原生的，蓝图子类改不了它的名字。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "lua", "PBZFog", "Scripts", "main.lua")

NEW_FUNC = '''local function lightProbe()
    log("光照：开始探测")

    -- 1. 直接找组件类实例。
    --    不能用 FindAllOf("DirectionalLight") —— 那个只匹配精确类名，
    --    游戏的太阳光通常是蓝图子类，实测返回 0。组件类是引擎原生的，名字改不了。
    local compClasses = { "DirectionalLightComponent", "SkyLightComponent",
                          "SkyAtmosphereComponent", "PointLightComponent" }
    local found = {}
    for _, cn in ipairs(compClasses) do
        local ok, arr = pcall(function() return FindAllOf(cn) end)
        local n = (ok and arr and #arr) or 0
        log(string.format("光照：%s 实例数 = %d", cn, n))
        if n > 0 then found[cn] = arr end
    end

    -- 2. 兜底：列出所有 actor 类名里带 sun/sky/directional 的
    local ok2, all = pcall(function() return FindAllOf("Actor") end)
    if ok2 and all then
        local seen = {}
        for i = 1, #all do
            local o = all[i]
            if volLive(o) then
                local okc, cn = pcall(function() return o:GetClass():GetFName():ToString() end)
                if okc and cn then
                    local low = string.lower(cn)
                    if string.find(low, "sun") or string.find(low, "sky")
                       or string.find(low, "directional") or string.find(low, "day") then
                        seen[cn] = (seen[cn] or 0) + 1
                    end
                end
            end
        end
        if next(seen) then
            for cn, cnt in pairs(seen) do
                log(string.format("光照：  actor %s = %d 个", cn, cnt))
            end
        else
            log("光照：没有类名含 sun/sky/directional/day 的 actor")
        end
    end

    -- 3. 对方向光做读写测试（没有就退到天空光）
    local comp = nil
    local which = nil
    for _, cn in ipairs({ "DirectionalLightComponent", "SkyLightComponent" }) do
        if found[cn] and #found[cn] > 0 then
            for i = 1, #found[cn] do
                local c = found[cn][i]
                if volLive(c) then comp, which = c, cn; break end
            end
        end
        if comp then break end
    end

    if not comp then
        log("光照：既没有方向光也没有天空光组件，无法测强度")
        return
    end
    log("光照：测试对象 = " .. which .. "  " .. tostring(comp))

    for _, f in ipairs({ "Intensity", "IndirectLightingIntensity",
                         "VolumetricScatteringIntensity", "Temperature",
                         "bAffectsWorld", "Mobility", "CastShadows" }) do
        local ok, v = pcall(function() return comp[f] end)
        log(string.format("光照：%s = %s", f, tostring(ok and v or "读不到")))
    end
    local okcol, col = pcall(function() return comp.LightColor end)
    if okcol and col then
        local _, r = pcall(function() return col.R end)
        local _, g = pcall(function() return col.G end)
        local _, b = pcall(function() return col.B end)
        log(string.format("光照：LightColor = (%s, %s, %s)",
            tostring(r or "?"), tostring(g or "?"), tostring(b or "?")))
    end

    local oko, orig = pcall(function() return comp.Intensity end)
    if not (oko and type(orig) == "number") then
        log("光照：Intensity 读不到，无法测试写入")
        return
    end
    local tgt = orig * 2
    if tgt < 0.1 then tgt = 8 end

    -- 路线 A：官方 UFUNCTION（内部会标脏重建渲染状态）
    local okSet, errSet = pcall(function() comp:SetIntensity(tgt) end)
    local _, afterA = pcall(function() return comp.Intensity end)

    -- 路线 B：直接写字段（雾就是靠这条生效的）
    local okField = pcall(function() comp.Intensity = tgt end)
    local _, afterB = pcall(function() return comp.Intensity end)

    log(string.format("光照：原值 %.4f，目标 %.4f", orig, tgt))
    log(string.format("光照：SetIntensity  ok=%s 读回=%s %s",
        tostring(okSet), tostring(afterA or "?"),
        okSet and "" or ("err=" .. tostring(errSet))))
    log(string.format("光照：直接写字段   ok=%s 读回=%s",
        tostring(okField), tostring(afterB or "?")))

    lightState = { comp = comp, orig = orig, target = tgt, kind = which }
    log("光照：已改强度，主循环每 60 轮复查一次是否被游戏抢回")
end

'''


def read(path):
    with io.open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_atomic(path, text):
    tmp = path + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if len(read(tmp)) != len(text):
        raise RuntimeError("临时文件长度不符，放弃写入")
    os.replace(tmp, path)


def main():
    s = read(SRC)
    start = s.find("local function lightProbe()")
    if start < 0:
        print("✘ 找不到 lightProbe")
        return 1
    end = s.find("local function colorProbe()", start)
    if end < 0:
        print("✘ 找不到 lightProbe 结尾锚点")
        return 1
    s = s[:start] + NEW_FUNC + s[end:]
    write_atomic(SRC, s)
    print("✔ lightProbe 已替换，共 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
