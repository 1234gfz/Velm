-- 统一日志。
--
-- 为什么单独一个模块：以前 log() 是 main.lua 里的一个局部函数，任何模块想打日志
-- 都得把它传进去，于是各处又开始自己 print。现在只有一个入口，格式也统一。

local log = {}

local seen = {}

local function emit(msg)
    print("[PBZ] " .. tostring(msg) .. "\n")
end

-- 普通日志，每次都打。
function log.info(msg)
    emit(msg)
end

-- 同 key 只打一次。用于「只想知道第一次发生了什么」的场景（探测结论、路径锁定、
-- 参数首次写入），避免每 200ms 刷一行把日志冲掉。
function log.once(key, msg)
    if seen[key] then return end
    seen[key] = true
    emit(msg)
end

-- 同一个 key 换了内容才打（用于「状态变化时才想看见」的日志）。
local lastSeen = {}
function log.changed(key, msg)
    if lastSeen[key] == msg then return end
    lastSeen[key] = msg
    emit(msg)
end

-- 热重载后想重新看见「只打一次」的日志时用。
function log.resetOnce()
    seen = {}
    lastSeen = {}
end

function log.fmt(v)
    v = tonumber(v) or 0
    if math.abs(v - math.floor(v)) < 1e-6 then
        return string.format("%d", math.floor(v))
    end
    return string.format("%.3f", v)
end

return log
