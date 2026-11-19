# -*- coding: utf-8 -*-
"""lightProbe 第三版：列出全部方向光组件，找出主太阳，并对全部做强度测试。

第二版结论：场景里有 3 个 DirectionalLightComponent，actor 是
Ultra_Dynamic_Sky_Child_C（Ultra Dynamic Sky 插件）。
但只测了第一个（Intensity=0），不是主太阳。这版把 3 个都列出来。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "lua", "PBZFog", "Scripts", "main.lua")

NEW_FUNC = '''local function lightProbe()
    log("光照：开始探测")

    local ok, arr = pcall(function() return FindAllOf("DirectionalLightComponent") end)
    local n = (ok and arr and #arr) or 0
    log("光照：DirectionalLightComponent 实例数 = " .. tostring(n))
    if n == 0 then
        log("光照：没有方向光组件")
        return
    end

    -- 逐个列出来：归属哪个 actor、当前强度、Mobility。
    -- 目的：分清「主太阳」和「月亮/补光」。Ultra Dynamic Sky 通常有两个
    -- 方向光，一个太阳一个月亮，按时间切换，强度为 0 的那个就是没在用的。
    local list = {}
    for i = 1, n do
        local c = arr[i]
        if volLive(c) then
            local _, inten = pcall(function() return c.Intensity end)
            local _, owner = pcall(function() return c.OwnerPrivate end)
            local ownerName = "?"
            if owner and volLive(owner) then
                local _, nm = pcall(function() return owner:GetFullName() end)
                ownerName = tostring(nm)
            end
            local _, mob = pcall(function() return c.Mobility end)
            log(string.format("光照：  [%d] Intensity=%-10s Mobility=%-4s owner=%s",
                i, tostring(inten or "?"), tostring(mob or "?"), ownerName))
            list[#list + 1] = { comp = c, inten = tonumber(inten) or 0 }
        end
    end

    if #list == 0 then
        log("光照：方向光组件全部失效"); return
    end

    -- 主太阳 = 强度最大的那个
    local main = list[1]
    for i = 2, #list do
        if list[i].inten > main.inten then main = list[i] end
    end
    log(string.format("光照：主太阳判定 → 强度 %.4f（共 %d 个方向光）", main.inten, #list))

    local orig = main.inten
    local tgt = orig * 2
    if tgt < 0.5 then tgt = 8 end

    -- 路线 A：官方 UFUNCTION
    local okSet, errSet = pcall(function() main.comp:SetIntensity(tgt) end)
    local _, afterA = pcall(function() return main.comp.Intensity end)
    log(string.format("光照：SetIntensity ok=%s 读回=%s %s",
        tostring(okSet), tostring(afterA or "?"),
        okSet and "" or ("err=" .. tostring(errSet))))

    -- 路线 B：直接写字段
    local okField = pcall(function() main.comp.Intensity = tgt end)
    local _, afterB = pcall(function() return main.comp.Intensity end)
    log(string.format("光照：直接写字段  ok=%s 读回=%s", tostring(okField), tostring(afterB or "?")))

    log(string.format("光照：主太阳 %.4f → %.4f，请看画面明暗是否变化", orig, tgt))

    lightState = { comp = main.comp, orig = orig, target = tgt, kind = "DirectionalLight" }
    log("光照：主循环每 60 轮复查一次，判断是否被游戏抢回")
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
        print("✘ 找不到结尾锚点")
        return 1
    s = s[:start] + NEW_FUNC + s[end:]
    write_atomic(SRC, s)
    print("✔ 已替换，共 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
