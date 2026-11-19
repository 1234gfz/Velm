# -*- coding: utf-8 -*-
"""修 primary 锁定：用对象地址比较，不能用 ==。

问题：UE4SS 的 FindAllOf 每次返回新的包装对象，即使指向同一个 UObject，
Lua 层 table 也不同，`objs[i] == locked` 永远 false。
后果：每 4 秒（ttl）就重新选一次主光，日志刷屏，且在多方向光场景可能导致目标跳变。

修法：把锁定的对象地址（tostring 里的十六进制）作为身份标识来比较。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "lua", "PBZFog", "Scripts", "main.lua")


def read(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return f.read()


def write_atomic(p, text):
    tmp = p + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if len(read(tmp)) != len(text):
        raise RuntimeError("临时文件长度不符，放弃写入")
    os.replace(tmp, p)


def main():
    s = read(SRC)

    # 1. 在 engineResolve 前加 objKey 辅助函数
    anchor = "-- 解析目标对象集合。how: class（按类全取）/ first（取第一个）"
    helper = '''-- 取对象的身份标识（UObject 原始地址的十六进制串）。
-- 为什么需要：UE4SS 的 FindAllOf 每次返回**新的包装对象**，
-- 即使指向同一个 UObject，Lua 层用 == 比较也永远不相等。
-- 之前直接比 == 的后果：每 4 秒就把主光"重新锁定"一次，多方向光场景下目标会跳变。
local function objKey(o)
    local ok, str = pcall(function() return tostring(o) end)
    if not ok or not str then return nil end
    return string.match(str, "(%x%x%x%x%x%x%x%x+)")
end

''' + anchor
    if "local function objKey(o)" not in s:
        if anchor not in s:
            print("✘ objKey 锚点未匹配")
            return 1
        s = s.replace(anchor, helper, 1)
        print("✔ 已加 objKey")
    else:
        print("objKey 已存在")

    # 2. 重写 primary 分支：用 objKey 比较 + 只在真正切换时打日志
    old = '''    if d.scope == "primary" and #objs > 0 then
        local locked = Engine.primary[d.cls]
        if locked and volLive(locked) then
            for i = 1, #objs do
                if objs[i] == locked then
                    Engine.cache[key] = { objs = { locked }, at = tick }
                    return { locked }
                end
            end
        end
        local best, bestV = nil, nil
        for i = 1, #objs do
            local bv = readNum(objs[i], d.prop)
            if bv ~= nil and (bestV == nil or bv > bestV) then best, bestV = objs[i], bv end
        end
        if best then
            Engine.primary[d.cls] = best
            log(string.format("主光锁定：%s（当前强度 %.4f，候选中取最大值）",
                d.cls, bestV or 0))
            Engine.cache[key] = { objs = { best }, at = tick }
            return { best }
        end
    end'''

    new = '''    if d.scope == "primary" and #objs > 0 then
        local rec = Engine.primary[d.cls]

        -- 已锁定且对象还活着：确认它仍在候选列表里（用地址比，不能用 ==）
        if rec and rec.obj and volLive(rec.obj) then
            local lk = rec.key
            for i = 1, #objs do
                if lk and objKey(objs[i]) == lk then
                    -- 用集合里的新包装，比缓存的旧包装更保险
                    Engine.cache[key] = { objs = { objs[i] }, at = tick }
                    return { objs[i] }
                end
            end
            -- 锁定对象不在了（换关卡/重建），往下重选
        end

        -- 重选：取当前强度最大的
        local best, bestV = nil, nil
        for i = 1, #objs do
            local bv = readNum(objs[i], d.prop)
            if bv ~= nil and (bestV == nil or bv > bestV) then best, bestV = objs[i], bv end
        end
        if best then
            local oldKey = rec and rec.key or nil
            Engine.primary[d.cls] = { obj = best, key = objKey(best) }
            if oldKey ~= Engine.primary[d.cls].key then
                log(string.format("主光锁定：%s 强度 %.4f（候选中最大）", d.cls, bestV or 0))
            end
            Engine.cache[key] = { objs = { best }, at = tick }
            return { best }
        end
    end'''

    if old in s:
        s = s.replace(old, new, 1)
        print("✔ 已修 primary 比较逻辑")
    else:
        print("✘ primary 锚点未匹配")
        return 1

    write_atomic(SRC, s)
    print("✔ 共 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
