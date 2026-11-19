# -*- coding: utf-8 -*-
"""修两个问题：

1. objKey 改用 GetFullName。
   tostring 解析出的地址在包装对象重建后可能不一致，导致锁定失效、
   每 4 秒重新选一次主光。

2. 基准落盘（persist）。
   Lua 热重载会清空 Engine.base / Engine.written。重载后读到的当前值
   可能是我们自己写过的（例如 6.0），被当成"原始值"再乘一次，
   就变成 12.0 —— 累乘。实测已经发生过一次。
   带 persist 标记的参数把 base/written 落盘，重载后接着用。
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
    marks = []

    # ---- 1. objKey 改用 GetFullName（更稳的身份标识）----
    old = '''local function objKey(o)
    local ok, str = pcall(function() return tostring(o) end)
    if not ok or not str then return nil end
    return string.match(str, "(%x%x%x%x%x%x%x%x+)")
end'''
    new = '''local function objKey(o)
    -- 优先用 GetFullName：组件名唯一且稳定（...Ultra_Dynamic_Sky_C_1.DirectionalLightComponent_1）。
    -- tostring 里的地址在包装对象重建后不一定相同，用它做身份会导致锁定反复失效。
    local ok, str = pcall(function() return o:GetFullName() end)
    if ok and str then return str end
    local ok2, s2 = pcall(function() return tostring(o) end)
    if ok2 and s2 then return string.match(s2, "(%x%x%x%x%x%x%x%x+)") end
    return nil
end

-- 引擎参数的基准/上次写入值，落盘用。
-- 只给 ROUTES 里标了 persist 的参数用（目前只有 sun.intensity）。
-- 不做全局落盘的原因：雾那边「重启后由游戏给出干净值」更可靠，
-- 落盘反而可能把脏基准留下来。这里只解决「Lua 热重载丢内存」这一个具体问题。
local ENG_STATE = "E:/PBZ_engine_state.txt"

local function engLoad()
    local t = {}
    local f = io.open(ENG_STATE, "r")
    if not f then return t end
    local txt = f:read("*a") or ""
    f:close()
    for line in string.gmatch(txt, "[^\\r\\n]+") do
        local k, b, w = string.match(line, "^([^|]+)|([%-%d%.eE]+)|([%-%d%.eE]+)$")
        if k then t[k] = { base = tonumber(b), written = tonumber(w) } end
    end
    return t
end

local function engSave(t)
    local f = io.open(ENG_STATE, "w")
    if not f then return end
    for k, v in pairs(t) do
        if v and v.base then
            f:write(string.format("%s|%.6f|%.6f\\n", k, v.base, v.written or 0))
        end
    end
    f:close()
end'''
    if old in s:
        s = s.replace(old, new, 1)
        marks.append("objKey 用 GetFullName")
    else:
        print("✘ objKey 锚点未匹配")
        return 1

    # ---- 2. ratio 分支开头：persist 参数先从文件恢复基准 ----
    old = '''        local base = Engine.base[p.key]
        local lastW = Engine.written[p.key]'''
    new = '''        -- persist 参数：Lua 热重载会清空内存基准，重载后读到的当前值
        -- 可能正是我们之前写过的（如 6.0），被当原始值再乘一次就累乘成 12.0。
        -- 从文件恢复 base/written 就能接上，实测这个问题已经发生过一次。
        if d.persist and Engine.base[p.key] == nil then
            local st = engLoad()[p.key]
            if st and st.base and st.base > 1e-6 then
                Engine.base[p.key] = st.base
                Engine.written[p.key] = st.written
            end
        end

        local base = Engine.base[p.key]
        local lastW = Engine.written[p.key]'''
    if old in s:
        s = s.replace(old, new, 1)
        marks.append("ratio 基准落盘读取")
    else:
        print("✘ ratio 锚点未匹配")
        return 1

    # ---- 3. 写入后保存基准 ----
    old = '''        Engine.written[p.key] = target'''
    new = '''        Engine.written[p.key] = target
        if d.persist then
            local st = engLoad()
            st[p.key] = { base = Engine.base[p.key], written = target }
            engSave(st)
        end'''
    if old in s:
        s = s.replace(old, new, 1)
        marks.append("写入后保存基准")
    else:
        print("✘ written 锚点未匹配")
        return 1

    # ---- 4. ROUTES 加 persist ----
    old = '''    ["sun.intensity"]   = { cls = "DirectionalLightComponent", scope = "primary", ttl = 20,
                            prop = "Intensity", setter = "SetIntensity",
                            mode = "ratio", onDisable = "revert" },'''
    new = '''    ["sun.intensity"]   = { cls = "DirectionalLightComponent", scope = "primary", ttl = 20,
                            prop = "Intensity", setter = "SetIntensity",
                            mode = "ratio", onDisable = "revert", persist = true },'''
    if old in s:
        s = s.replace(old, new, 1)
        marks.append("ROUTES persist")
    else:
        print("✘ ROUTES 锚点未匹配")
        return 1

    write_atomic(SRC, s)
    print("✔ " + "、".join(marks))
    print("  共 %d 行" % len(s.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
