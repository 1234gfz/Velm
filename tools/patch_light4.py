# -*- coding: utf-8 -*-
"""lightProbe 第四版：带原始值落盘 + 精确指定索引 + 还原。

为什么需要这个：
  第三版把「强度最大的」当成主太阳，结果它选中的是 [1] —— 而 [1] 原本是 0.0，
  是被我上一次探测改成 8.0 的。于是又把它改成 16.0，等于一直在改一个本来
  没启用的组件，越改越离谱。

  根子在「没有记录原始值」。这版把第一次读到的强度落盘（E:/PBZ_light_orig.txt），
  之后每次探测：
    - 文件不存在 → 记录当前值当原始值
    - 命令 "restore" → 全部还原成原始值
    - 命令 "0"/"1"/"2" → 改该索引为原始值的 2 倍
    - 其他/空     → 只打印状态，不动

触发文件 E:/PBZ_light_probe.txt 的内容就是命令。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "lua", "PBZFog", "Scripts", "main.lua")

NEW_FUNC = '''-- 方向光原始强度记录文件。落盘而不是放内存：
-- 热重载会清空 Lua 状态，只放变量里的话重载后就找不回原始值了。
local LIGHT_ORIG_FILE = "E:/PBZ_light_orig.txt"

local function loadLightOrig()
    local f = io.open(LIGHT_ORIG_FILE, "r")
    if not f then return nil end
    local txt = f:read("*a") or ""
    f:close()
    local t = {}
    for line in string.gmatch(txt, "[^\\r\\n]+") do
        local idx, val = string.match(line, "^(%d+)=([%-%d%.eE]+)$")
        if idx and val then t[tonumber(idx)] = tonumber(val) end
    end
    if next(t) == nil then return nil end
    return t
end

local function saveLightOrig(t)
    local f = io.open(LIGHT_ORIG_FILE, "w")
    if not f then return end
    for i = 1, #t do
        if t[i] then f:write(string.format("%d=%.6f\\n", i, t[i])) end
    end
    f:close()
end

local function lightProbe(cmd)
    cmd = string.lower(string.gsub(tostring(cmd or ""), "%s", ""))
    log("光照：开始探测，命令=" .. (cmd == "" and "(空)" or cmd))

    local ok, arr = pcall(function() return FindAllOf("DirectionalLightComponent") end)
    local n = (ok and arr and #arr) or 0
    log("光照：DirectionalLightComponent 实例数 = " .. tostring(n))
    if n == 0 then return end

    -- 收集有效组件
    local comps = {}
    for i = 1, n do
        local c = arr[i]
        if volLive(c) then
            local _, v = pcall(function() return c.Intensity end)
            comps[#comps + 1] = { comp = c, now = tonumber(v) or 0 }
        end
    end
    if #comps == 0 then log("光照：全部失效"); return end

    -- 原始值：文件里没有就现在记（此时还没被我们改过，是干净的）
    local orig = loadLightOrig()
    local recorded = orig ~= nil
    if not orig then
        orig = {}
        for i = 1, #comps do orig[i] = comps[i].now end
        saveLightOrig(orig)
        log("光照：首次探测，已记录原始值")
    end

    -- 打印当前状态（含原始值对照，一眼看出谁被改过）
    for i = 1, #comps do
        local diff = ""
        if orig[i] and math.abs(comps[i].now - orig[i]) > 1e-4 then
            diff = string.format("  ← 被改过（原始 %.3f）", orig[i])
        end
        log(string.format("光照：  [%d] 当前=%.3f  原始=%s%s",
            i, comps[i].now, orig[i] and string.format("%.3f", orig[i]) or "?", diff))
    end

    if cmd == "" then
        log("光照：只查看，未修改")
        return
    end

    if cmd == "restore" then
        for i = 1, #comps do
            if orig[i] then
                pcall(function() comps[i].comp:SetIntensity(orig[i]) end)
                local _, back = pcall(function() return comps[i].comp.Intensity end)
                log(string.format("光照：还原 [%d] → %.3f（读回 %s）",
                    i, orig[i], tostring(back or "?")))
            end
        end
        lightState = nil
        log("光照：全部还原完成")
        return
    end

    -- 数字：改该索引
    local idx = tonumber(cmd)
    if not idx or idx < 1 or idx > #comps then
        log("光照：命令无法识别（可用：空 / restore / 1.." .. #comps .. "）")
        return
    end

    local base = orig[idx] or comps[idx].now
    -- 原始值是 0 的组件（未启用）给一个明显能看见的值，否则乘 2 还是 0
    local tgt
    if base < 0.01 then
        tgt = 10.0
    else
        tgt = base * 2
    end
    pcall(function() comps[idx].comp:SetIntensity(tgt) end)
    local _, after = pcall(function() return comps[idx].comp.Intensity end)
    log(string.format("光照：[%d] %.3f → %.3f（读回 %s）",
        idx, base, tgt, tostring(after or "?")))

    lightState = { comp = comps[idx].comp, orig = base, target = tgt }
    log("光照：主循环每 60 轮复查是否被游戏抢回")
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

    # 主循环里的调用要传命令：把触发文件内容读出来传进去
    old = '''            os.remove("E:/PBZ_light_probe.txt")
            local okl, errl = pcall(lightProbe)'''
    new = '''            local cmd = ""
            do
                local cf = io.open("E:/PBZ_light_probe.txt", "r")
                if cf then cmd = (cf:read("*a") or ""):gsub("%s", ""); cf:close() end
            end
            os.remove("E:/PBZ_light_probe.txt")
            local okl, errl = pcall(lightProbe, cmd)'''
    if old in s:
        s = s.replace(old, new, 1)
        print("已更新主循环调用（传命令）")
    else:
        print("⚠ 主循环调用未匹配，需手工检查")

    write_atomic(SRC, s)
    print("✔ 完成，共 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
