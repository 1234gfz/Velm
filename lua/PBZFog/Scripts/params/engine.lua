-- 统一参数引擎。
--
-- 参数只声明「目标 + 语义」（见 routes.lua），这里统一执行六步：
--   ① 开关关闭 -> 不干预（或按 onDisable 还原）
--   ② 解析目标对象（缓存 + 每次验活）
--   ③ 实时读当前值（永不读存档）
--   ④ 按 mode 计算目标值：abs / ratio / mirror
--   ⑤ 与上次写入值比较，一致就跳过（避免无谓写入，也避免和游戏对撞）
--   ⑥ 写后读回校验，失败记一次日志

local log     = require("core.log")
local ue      = require("core.ue")
local env     = require("core.env")
local world   = require("core.world")
local objects = require("core.objects")
local ROUTES  = require("params.routes")

local engine = {}

local cache    = {}   -- "cls|scope" -> { objs = {...}, at = tick }
local at       = {}   -- key -> 上次写入的 tick
local written  = {}   -- key -> 上次写入的值
local base     = {}   -- key -> 实时基准（ratio 模式）
local primary  = {}   -- cls -> { obj = ..., key = ... }
local logged   = {}   -- key -> true（首次写入日志）

local tick = 0
function engine.setTick(t) tick = t end

-- ---------------------------------------------------------------- 状态文件

-- 只给 ROUTES 里标了 persist 的参数用（目前只有 sun.intensity）。
-- 不做全局落盘的原因：雾那边「重启后由游戏给出干净值」更可靠，
-- 落盘反而可能把脏基准留下来。这里只解决「Lua 热重载丢内存」这一个具体问题。
local function stateLoad()
    local t = {}
    local f = io.open(env.ENG_STATE, "r")
    if not f then return t end
    local txt = f:read("*a") or ""
    f:close()
    for line in string.gmatch(txt, "[^\r\n]+") do
        local k, b, w = string.match(line, "^([^|]+)|([%-%d%.eE]+)|([%-%d%.eE]+)$")
        if k then t[k] = { base = tonumber(b), written = tonumber(w) } end
    end
    return t
end

local function stateSave(t)
    local f = io.open(env.ENG_STATE, "w")
    if not f then return end
    for k, v in pairs(t) do
        if v and v.base then
            f:write(string.format("%s|%.6f|%.6f\n", k, v.base, v.written or 0))
        end
    end
    f:close()
end

-- ---------------------------------------------------------------- 目标解析

-- 解析目标对象集合。
-- 缓存策略：同一个 cls|scope 在 ttl 个 tick 内复用，但要逐个验活 ——
-- 缓存里任何一个死了就整体重扫（场景切换后是常态）。
local function resolve(d)
    local key = d.cls .. "|" .. (d.scope or "all")
    local bucket = cache[key]
    if bucket and (tick - bucket.at) < (d.ttl or 40) then
        local alive = true
        for i = 1, #bucket.objs do
            if not ue.alive(bucket.objs[i]) then alive = false break end
        end
        if alive then return bucket.objs end
    end

    local arr
    if d.scope == "first" then
        local one = objects.first(d.cls)
        arr = one and { one } or nil
    else
        arr = objects.get(d.cls)
    end

    local objs = {}
    if arr then
        for i = 1, #arr do
            local o = arr[i]
            if o and ue.alive(o) then table.insert(objs, o) end
        end
    end

    -- primary：只作用于「主光」。
    -- 场景里常有多个方向光（UDS 一般是太阳 + 月亮 + 补光），强度为 0 的是没启用的那个。
    -- scope="first" 取到的往往正是它 —— 写进去毫无画面变化，排查成本极高。
    --
    -- 选定后锁定：只有组件失效（换关卡）才重新选，
    -- 否则用户把强度调低后「最大值」可能变成另一个组件，目标会来回跳。
    if d.scope == "primary" and #objs > 0 then
        local rec = primary[d.cls]

        -- 已锁定且对象还活着：确认它仍在候选列表里（用身份标识比，不能用 ==）
        if rec and rec.obj and ue.alive(rec.obj) then
            local lk = rec.key
            for i = 1, #objs do
                if lk and ue.key(objs[i]) == lk then
                    -- 自愈：锁定的对象当前强度是 0，但别的候选有值 → 当初锁错了。
                    -- 踩过：最早探测时把某个未启用的组件临时改成 8，它成了最大值被锁定，
                    -- 之后一直改那个「空」组件，怎么调都没画面反应。
                    local curLocked = ue.readNum(objs[i], d.prop)
                    if curLocked ~= nil and curLocked <= 1e-6 then
                        local otherMax = 0
                        for j = 1, #objs do
                            if j ~= i then
                                local vj = ue.readNum(objs[j], d.prop)
                                if vj ~= nil and vj > otherMax then otherMax = vj end
                            end
                        end
                        if otherMax > 1e-6 then
                            log.info(string.format("主光重选：锁定对象强度为 0，另一候选 %.4f，改用它", otherMax))
                            break     -- 跳出，走下面的重选分支
                        end
                    end
                    cache[key] = { objs = { objs[i] }, at = tick }
                    return { objs[i] }
                end
            end
            -- 锁定对象不在了（换关卡/重建），往下重选
        end

        -- 重选：取当前强度最大的
        local best, bestV = nil, nil
        for i = 1, #objs do
            local bv = ue.readNum(objs[i], d.prop)
            if bv ~= nil and (bestV == nil or bv > bestV) then best, bestV = objs[i], bv end
        end
        if best then
            local oldKey = rec and rec.key or nil
            primary[d.cls] = { obj = best, key = ue.key(best) }
            if oldKey ~= primary[d.cls].key then
                log.info(string.format("主光锁定：%s 强度 %.4f（候选中最大）", d.cls, bestV or 0))
            end
            cache[key] = { objs = { best }, at = tick }
            return { best }
        end
    end

    cache[key] = { objs = objs, at = tick }
    return objs
end

-- ---------------------------------------------------------------- 单参数处理

-- p: 参数表条目（含 key / value / enabled / default）
-- d: routes 里对应的描述
function engine.step(p, d)
    -- ① 开关
    if p.enabled == false and d.onDisable ~= "revert" then return end

    -- ② 目标
    local objs = resolve(d)
    if #objs == 0 then return end

    -- ③ 读当前值（取第一个作为基准；写入时全部同步，保证多组件一致）
    local cur = ue.readNum(objs[1], d.prop)
    if cur == nil then return end

    -- ④ 计算目标值
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

    local target
    if d.mode == "abs" then
        target = v
    elseif d.mode == "ratio" then
        -- 相对原值的比例模式（供「倍数类」效果使用，雾不走这条）。
        -- 基准只存在内存里，不落盘：
        --   · 落盘会留下脏数据 —— 曾经基准被存成 0，又叠加「基准为 0 不写」的保护，
        --     结果那一项永久失效，表现为「调什么都没反应」；
        --   · 重启后游戏会给出干净的初始值，内存基准自然重建。
        -- 检测到外部改动（换区/天气）时重新取基准，避免用过期基准把画面写歪。
        -- persist 参数：Lua 热重载会清空内存基准，重载后读到的当前值
        -- 可能正是我们之前写过的（如 6.0），被当原始值再乘一次就累乘成 12.0。
        -- 从文件恢复 base/written 就能接上。
        if d.persist and base[p.key] == nil then
            local st = stateLoad()[p.key]
            if st and st.base and st.base > 1e-6 then
                base[p.key] = st.base
                written[p.key] = st.written
            end
        end

        local b = base[p.key]
        local lastW = written[p.key]
        if b == nil or b <= 1e-6 then
            if cur > 1e-6 then
                b = cur
                base[p.key] = b
            end
        elseif lastW ~= nil and math.abs(cur - lastW) > 1e-4 then
            b = cur
            base[p.key] = b
        end
        if b == nil then
            if d.boot and cur <= 1e-6 then target = d.boot   -- 值被写成 0 时的自愈
            else return end
        else
            target = b * (v or 1)
        end
    elseif d.mode == "mirror" then
        local srcObjs = d.source and resolve(d.source)
        local src = srcObjs and srcObjs[1]
        if not src then return end
        local sv = ue.readNum(src, d.source.prop)
        if sv == nil then return end
        target = sv * (v or 1)
    end
    if target == nil then return end
    if d.clamp then target = math.min(d.clamp, target) end

    -- ⑤ 到了目标值就不写
    local tag = p.key
    local lastAt = at[tag]
    if lastAt == nil or math.abs(cur - target) > (d.eps or 1e-4) then
        if lastAt ~= nil and (tick - lastAt) < (d.throttle or 5) then return end
        at[tag] = tick

        -- ⑥ 写入 + 读回校验（逐个对象，写前再验一次活）
        local okN, failN = 0, 0
        for i = 1, #objs do
            local o = objs[i]
            if ue.alive(o) then
                if ue.writeNum(o, d.setter, d.prop, target) then okN = okN + 1 else failN = failN + 1 end
            else
                failN = failN + 1
            end
        end
        written[p.key] = target
        if d.persist then
            local st = stateLoad()
            st[p.key] = { base = base[p.key], written = target }
            stateSave(st)
        end
        local back = ue.readNum(objs[1], d.prop)
        if back ~= nil and math.abs(back - target) > (d.eps or 1e-4) then
            log.info(string.format("引擎 %s: 目标 %.4f 读回 %.4f（被覆盖）", p.key, target, back))
        elseif not logged[tag] then
            logged[tag] = true
            log.info(string.format("引擎 %s -> %.4f（%d 个对象）", p.key, target, okN))
        end
        if failN > 0 then cache[d.cls .. "|" .. (d.scope or "all")] = nil end
    end
end

-- ---------------------------------------------------------------- 对外查询

function engine.route(key)
    return ROUTES[key]
end

function engine.baseOf(key)
    return base[key]
end

-- 还原某个参数：清基准、清已写记录、清锁定。
-- 只还原数值不清基准的话，下一轮会按旧基准再写回去 —— 等于白还原。
function engine.revert(key)
    base[key] = nil
    written[key] = nil
    at[key] = nil
    logged[key] = nil
    local d = ROUTES[key]
    if d and d.scope == "primary" then primary[d.cls] = nil end
end

function engine.revertAll()
    base, written, at, logged, primary = {}, {}, {}, {}, {}
    os.remove(env.ENG_STATE)
end

function engine.forgetCache()
    cache = {}
    primary = {}
    at = {}
end

world.onNewWorld("engine", function()
    -- 只清缓存与节流记录。
    --
    -- ★ 不要清 base / written：
    -- base 是「游戏原始值」的参照。换世界后新组件回到原始值，而我们手里
    -- base = 原值、written = 上次写出去的值(原值×比例)，两者对不上 → 下一轮
    -- 会重新认定 cur 为新基准，正好恢复正确比例。
    -- 如果这里把 base 也清了，就会拿「已经被我们改过的当前值」当新基准，
    -- 再乘一次比例 —— 这正是「换场景后光/雾越调越暗」的累乘 bug。
    -- 老实现也没有在 resetForNewWorld 里清 Engine.base，这里保持一致。
    engine.forgetCache()
    at = {}
end)

return engine
