-- 面板（PBZTweaker.exe）的拉起与熔断。
--
-- 历史教训（全部有现场日志支撑）：
--   · 老版要求心跳在 30 秒内，面板进程活着但心跳线程停摆 → 判死
--   · 判死后每 12 秒 os.execute('start ...') 一次
--   · os.execute 在 Windows 上必然拉起 cmd.exe，是**同步**的 → 游戏线程被挂住
--     实测 2026-11-15 15:55:36 卡 5704ms、15:57:03 卡 5538ms，两次都卡在这
--   · 新进程被单实例 Mutex 立刻踢掉 → 心跳依然不写 → 12 秒后再拉，形成死循环
--
-- 现在的规则（把「阻塞」的总次数压到每局最多 1 次）：
--   1. 心跳 TTL 放宽到 120 秒（面板加载慢 / 系统卡顿时不再误判）
--   2. **每局最多拉起 1 次**。面板进程一旦被 Mutex 踢掉，再拉多少次都没用，
--      反复拉只会反复阻塞游戏线程 —— 这是纯亏，不如一次性放弃并提示用户手动开
--   3. 拉起只在「心跳文件根本不存在」或「心跳过期超过 TTL」时触发，
--      并且触发后立刻把 attempts 记满，本局内不再尝试
--   4. 换世界不重置 attempts（重启游戏才重置）—— 换图时卡 5 秒是最不可接受的时机

local log = require("core.log")
local env = require("core.env")

local panel = {}

local MAX_ATTEMPTS   = 1      -- 每局最多拉起几次（1 = 只试一次）
local HEARTBEAT_TTL  = 120    -- 心跳多久没更新算面板死了

local attempts = 0
local givenUp = false
local lastBeat = nil

local function readHeartbeat()
    local f = io.open(env.HEARTBEAT, "r")
    if not f then return nil end
    local txt = f:read("*a") or ""
    f:close()
    local t = tonumber(txt)
    if not t then return nil end
    return t
end

local function alive()
    local t = readHeartbeat()
    if not t then return false end
    lastBeat = t
    local dt = os.time() - t
    -- dt < -5 说明系统时间被改过，当成不可信、认为面板没活着
    return dt >= -5 and dt <= HEARTBEAT_TTL
end

-- 每 60 tick（约 12 秒）调一次。
function panel.ensure()
    if givenUp then return end
    if alive() then return end          -- 面板活着，什么都不做

    -- 面板没活着。只在还能尝试时才动手。
    if attempts >= MAX_ATTEMPTS then
        givenUp = true
        log.info("面板未运行，本局已尝试过自动拉起，不再重试。" ..
            "调参请按 F8 呼出面板；若 F8 无反应，看系统托盘里的圆形图标（右键有「显示/隐藏面板」）。")
        return
    end

    local f = io.open(env.TWEAKER, "r")
    if not f then
        givenUp = true
        log.info("面板 exe 不存在，已停止自动拉起: " .. env.TWEAKER)
        return
    end
    f:close()

    -- ★ 先把次数记满再调用：os.execute 是同步阻塞的，
    -- 万一它卡住或抛错，也不能让下一次检查再来一遍。
    attempts = attempts + 1

    local ok, err = pcall(function()
        os.execute('start "" "' .. env.TWEAKER .. '"')
    end)
    if not ok then
        log.info("面板拉起失败: " .. tostring(err))
        givenUp = true
    end
end

-- 换世界后**不**重置 attempts：换图时卡 5 秒是最不可接受的时机。
-- 只有重新加载 mod / 重启游戏才会走到这里之外的新进程。
function panel.reset()
    -- 故意留空：保留 attempts 与 givenUp 的会话内语义。
end

function panel.status()
    return {
        alive = alive(),
        attempts = attempts,
        givenUp = givenUp,
        lastBeat = lastBeat,
    }
end

return panel
