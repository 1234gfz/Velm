# -*- coding: utf-8 -*-
"""接入平行光强度到面板（复用现有 ROUTES/engineStep 机制）。

设计要点：
1. mode="ratio"（和雾一致，1.0=100%），不是绝对值。
2. 新增 scope="primary"：只作用于「主太阳」。
   原因：场景里有 3 个 DirectionalLightComponent（Ultra Dynamic Sky 的太阳+月亮+补光），
   scope="first" 拿到的是强度 0 的那个，改它画面毫无变化（实测踩过）。
3. primary 带「锁定」：一旦选定了主光组件就一直用它，不因为强度变化来回切换。
   只有组件失效（换关卡）才重新选。
4. onDisable="revert"：关掉开关时回到 1.0（= 原始值），而不是保持最后一次的值。
   engineStep 原来在关闭时直接用 p.value，会把用户设的值继续应用，这里补上。
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


def patch(s):
    changed = []

    # ---- 1. Engine 表加 primary 字段（锁定的主光对象） ----
    old = "local Engine = { cache = {}, last = {}, at = {}, throttle = {}, loggedOnce = {}, base = {}, written = {} }"
    new = ("local Engine = { cache = {}, last = {}, at = {}, throttle = {}, loggedOnce = {},\n"
           "                 base = {}, written = {}, primary = {} }")
    if old in s and "primary = {} }" not in s.split("\n")[0]:
        s = s.replace(old, new, 1)
        changed.append("Engine.primary 字段")

    # ---- 2. engineResolve 支持 scope="primary" ----
    old = """    Engine.cache[key] = { objs = objs, at = tick }
    return objs
end"""
    new = """    -- primary：只作用于「主光」。
    -- 场景里常有多个方向光（Ultra Dynamic Sky 一般是太阳 + 月亮 + 补光），
    -- 强度为 0 的是没启用的那个。scope="first" 取到的往往正是它 ——
    -- 写进去毫无画面变化，排查成本极高（实测踩过这个坑）。
    --
    -- 选定后**锁定**：只有组件失效（换关卡）才重新选，
    -- 否则用户把强度调低后「最大值」可能变成另一个组件，目标会来回跳。
    if d.scope == "primary" and #objs > 0 then
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
    end

    Engine.cache[key] = { objs = objs, at = tick }
    return objs
end"""
    if old in s:
        s = s.replace(old, new, 1)
        changed.append("engineResolve primary")
    else:
        print("✘ engineResolve 锚点未匹配")

    # ---- 3. engineStep：关闭且 onDisable="revert" 时回到原始值 ----
    old = """    -- ④ 计算目标值
    local v = tonumber(p.value)
    if v == nil and type(p.value) == "boolean" then v = p.value and 1 or 0 end
    local target"""
    new = """    -- ④ 计算目标值
    local v = tonumber(p.value)
    if v == nil and type(p.value) == "boolean" then v = p.value and 1 or 0 end

    -- 关闭且要求还原时：ratio 模式回到 1.0（= 原始值），abs 模式回到 default。
    -- 不加这段的话，关闭开关仍会用用户最后设的 value 继续覆盖，开关等于没用。
    if p.enabled == false and d.onDisable == "revert" then
        if d.mode == "ratio" then
            v = 1.0
        else
            local dv = tonumber(p["default"])
            if dv ~= nil then v = dv end
        end
    end

    local target"""
    if old in s:
        s = s.replace(old, new, 1)
        changed.append("engineStep revert")
    else:
        print("✘ engineStep 锚点未匹配")

    # ---- 4. ROUTES 加平行光路由 ----
    old = '''    ["gi.dirlight"]     = { cls = "DirectionalLightComponent", scope = "first", prop = "IndirectLightingIntensity", setter = "SetIndirectLightingIntensity", mode = "abs" },'''
    new = old + '''
    -- 平行光强度：比例模式（1.0 = 100%，和雾的浓度比例同一套语义）。
    -- scope="primary" 只动主太阳，不会把月亮/补光一起改成同一个值。
    -- onDisable="revert"：关掉开关回到 100%。ttl 给 20（4 秒）而不是默认 40，
    -- 换关卡后能更快重新锁定主光。
    ["sun.intensity"]   = { cls = "DirectionalLightComponent", scope = "primary", ttl = 20,
                            prop = "Intensity", setter = "SetIntensity",
                            mode = "ratio", onDisable = "revert" },'''
    if old in s and "sun.intensity" not in s:
        s = s.replace(old, new, 1)
        changed.append("ROUTES sun.intensity")
    else:
        print("✘ ROUTES 锚点未匹配（或已存在）")

    return s, changed


def main():
    s = read(SRC)
    s2, changed = patch(s)
    if not changed:
        print("没有任何改动")
        return 1
    write_atomic(SRC, s2)
    print("✔ 已改动：" + "、".join(changed))
    print("  共 %d 行" % len(s2.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
