# -*- coding: utf-8 -*-
"""给 main.lua 加平行光探测。

安全写入：先写同目录 .tmp，成功后再 os.replace 覆盖原文件。
踩过的坑：直接用 io.open(p, 'w') 会把原文件清空，万一写过程报错，
文件就变成 0 行（main.lua 曾经因此被截断，只能从游戏目录恢复）。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "lua", "PBZFog", "Scripts", "main.lua")

PROBE_MARK = "local function lightProbe()"

PROBE_CODE = '''-- ===== 平行光（DirectionalLight）探测 =====
--
-- 目的：确认场景里的平行光能否拿到、强度能否改。
-- 关键依据：LightComponent 的 SetIntensity / SetIndirectLightingIntensity
--   都是 UFUNCTION(BlueprintCallable)（SDK 的 LightComponent.h:262），
--   和 SetFogDensity 同一类，Lua 能直接调，不需要写内存、不需要绕反射表。
--
-- 触发方式：E:/PBZ_light_probe.txt 存在就跑一次，跑完自动删除。
--   故意不用 JSON 里的 testCube 开关 —— 那会改用户参数表。
local lightState = nil
local lightTick = 0

local function lightProbe()
    log("光照：开始探测平行光")

    local okf, arr = pcall(function() return FindAllOf("DirectionalLight") end)
    if not okf then log("光照：FindAllOf 失败 " .. tostring(arr)); return end
    local n = (arr and #arr) or 0
    log("光照：DirectionalLight 数量 = " .. tostring(n))

    if n == 0 then
        -- 兜底：列出场景里所有含 Light 的类，别直接下"没有"的结论
        local ok2, all = pcall(function() return FindAllOf("Actor") end)
        if ok2 and all then
            local seen = {}
            for i = 1, #all do
                local o = all[i]
                if volLive(o) then
                    local okc, cn = pcall(function() return o:GetClass():GetFName():ToString() end)
                    if okc and cn and string.find(string.lower(cn), "light") then
                        seen[cn] = (seen[cn] or 0) + 1
                    end
                end
            end
            for cn, cnt in pairs(seen) do
                log(string.format("光照：  场景里有 %s = %d 个", cn, cnt))
            end
            if next(seen) == nil then log("光照：场景里没有任何含 Light 的 actor") end
        end
        return
    end

    local target = nil
    for i = 1, math.min(n, 8) do
        local a = arr[i]
        if volLive(a) then
            local okn, nm = pcall(function() return a:GetFullName() end)
            log(string.format("光照：  [%d] %s", i, tostring(okn and nm or "?")))
            if not target then target = a end
        end
    end
    if not target then log("光照：所有 DirectionalLight 都已失效"); return end

    -- 组件：蓝图子类暴露的属性名可能不同，按顺序试
    local comp, srcName = nil, nil
    for _, f in ipairs({ "DirectionalLightComponent", "LightComponent" }) do
        local ok, c = pcall(function() return target[f] end)
        if ok and c and volLive(c) then comp, srcName = c, f; break end
    end
    if not comp then
        local ok, c = pcall(function() return target.RootComponent end)
        if ok and c and volLive(c) then comp, srcName = c, "RootComponent" end
    end
    if not comp then log("光照：拿不到灯光组件"); return end
    log("光照：组件来源 = " .. tostring(srcName) .. "  " .. tostring(comp))

    for _, f in ipairs({ "Intensity", "Brightness", "IndirectLightingIntensity",
                         "VolumetricScatteringIntensity", "Temperature",
                         "bAffectsWorld", "Mobility", "CastShadows",
                         "bCastVolumetricShadow" }) do
        local ok, v = pcall(function() return comp[f] end)
        log(string.format("光照：%s = %s", f, tostring(ok and v or "读不到")))
    end

    local okcol, col = pcall(function() return comp.LightColor end)
    if okcol and col then
        local okr, r = pcall(function() return col.R end)
        local okg, g = pcall(function() return col.G end)
        local okb, b = pcall(function() return col.B end)
        log(string.format("光照：LightColor = (%s, %s, %s)",
            tostring(okr and r or "?"), tostring(okg and g or "?"), tostring(okb and b or "?")))
    else
        log("光照：LightColor 读不到")
    end

    local oko, orig = pcall(function() return comp.Intensity end)
    if not (oko and type(orig) == "number") then
        log("光照：Intensity 读不到，无法测试写入"); return end
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
    log(string.format("光照：直接写字段   ok=%s 读回=%s", tostring(okField), tostring(afterB or "?")))

    lightState = { comp = comp, orig = orig, target = tgt }
    log("光照：已改强度，主循环每 60 轮复查一次是否被游戏改写")
end

'''

# 主循环里的锚点。**必须插在这里，不能插进 loadCfg** ——
# loadCfg 开头有 `if txt == cfgText then return end`，配置文件没变就直接返回，
# 插在那里的代码永远不会执行（这个坑刚踩过：探测代码放进去后完全没有输出）。
LOOP_ANCHOR = '''    local ppBudget = 3          -- 本轮后处理字段下发预算，见下面的 pp 分支
    pcall(loadCfg)'''

LOOP_INSERT = LOOP_ANCHOR + '''

    -- 平行光探测：标记文件触发，不碰参数表也不碰预设。
    -- 每 10 轮（约 2 秒）查一次文件，避免每轮做同步 IO。
    lightTick = lightTick + 1
    if lightTick % 10 == 0 then
        local mf = io.open("E:/PBZ_light_probe.txt", "r")
        if mf then
            mf:close()
            os.remove("E:/PBZ_light_probe.txt")
            local okl, errl = pcall(lightProbe)
            if not okl then log("光照出错: " .. tostring(errl)) end
        end
    end

    -- 复查：改完的强度是否被游戏抢回（判断有没有每帧写光强的逻辑）
    if lightState and lightTick % 60 == 0 then
        local okv, v = pcall(function() return lightState.comp.Intensity end)
        log(string.format("光照复查：Intensity = %s（我们写的 %.4f，原始 %.4f）",
            tostring(okv and v or "?"), lightState.target, lightState.orig))
    end'''


def read(path):
    with io.open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_atomic(path, text):
    tmp = path + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    # 校验临时文件写全了再替换
    if len(read(tmp)) != len(text):
        raise RuntimeError("临时文件长度不符，放弃写入")
    os.replace(tmp, path)


def main():
    s = read(SRC)

    # 1. 先清掉可能残留在 loadCfg 里的错误版本（永远执行不到）
    bad_start = s.find("    -- 平行光探测：标记文件触发，不碰参数表也不碰预设。")
    if bad_start >= 0:
        bad_end = s.find("    -- 调试开关：不隐藏原版", bad_start)
        if bad_end > bad_start:
            s = s[:bad_start] + s[bad_end:]
            print("已移除 loadCfg 里的错误插入")

    if PROBE_MARK in s:
        print("探测函数已存在，跳过函数插入")
    else:
        anchor = "local function colorProbe()"
        if anchor not in s:
            print("✘ 找不到锚点 local function colorProbe()")
            return 1
        s = s.replace(anchor, PROBE_CODE + anchor, 1)

    if "if lightTick % 10 == 0 then" not in s:
        if LOOP_ANCHOR not in s:
            print("✘ 找不到主循环锚点")
            return 1
        s = s.replace(LOOP_ANCHOR, LOOP_INSERT, 1)
        print("已把触发代码插入主循环")
    else:
        print("触发代码已存在，跳过")

    write_atomic(SRC, s)
    print("✔ 完成，共 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
