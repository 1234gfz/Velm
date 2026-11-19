-- 延迟持久化。
--
-- 这是本次重构里收益最大的一块。
--
-- 老实现：applyPP 每成功写入一个字段就调 savePP()，把整个 ppOrig 表（446KB、
-- 2400+ 条记录）重新序列化并覆盖写盘。而 applyPP 跑在游戏线程上，每 200ms
-- 一轮、每轮最多 3 个字段 —— 也就是游戏线程会同步写 446KB 文件。
-- 表现就是「突然卡住好几秒」。
--
-- 新实现：set() 只把数据放内存 + 标脏；flush_if_due() 由主循环定期调用，
-- 且写盘有最小间隔（默认 5 秒）。写入内容仍是全量（原子性简单可靠），
-- 但频次从「每写一个字段一次」降到「最多 5 秒一次」。
--
-- 更进一步：flush 只在「确实有脏数据」时发生，且写完清脏标记。
-- 换场景时数据被清空（见 world.lua 的 onNewWorld 注册），文件不再只增不减。

local log = require("core.log")

local store = {}

-- 每个 store 实例管一个文件。
-- opts:
--   path      文件路径（必填）
--   encode    表 -> 字符串
--   decode    字符串 -> 表（失败返回 nil）
--   interval  最小写盘间隔（秒），默认 5
--   name      日志里显示的名字
function store.new(opts)
    local self = {
        path = opts.path,
        encode = opts.encode,
        decode = opts.decode,
        interval = opts.interval or 5,
        name = opts.name or "store",
        data = {},
        dirty = false,
        lastFlush = 0,
        loaded = false,
        writeCount = 0,
    }

    function self.load()
        if self.loaded then return self.data end
        self.loaded = true
        local f = io.open(self.path, "r")
        if not f then return self.data end
        local txt = f:read("*a")
        f:close()
        if not txt or #txt < 3 then return self.data end
        local ok, decoded = pcall(self.decode, txt)
        if ok and type(decoded) == "table" then
            self.data = decoded
        end
        return self.data
    end

    -- 只改内存 + 标脏。绝不在这里写盘。
    function self.set(key, value)
        self.data[key] = value
        self.dirty = true
    end

    function self.get(key)
        return self.data[key]
    end

    function self.clear(key)
        if key == nil then
            self.data = {}
        else
            self.data[key] = nil
        end
        self.dirty = true
    end

    function self.isEmpty()
        return next(self.data) == nil
    end

    function self.count()
        local n = 0
        for _ in pairs(self.data) do n = n + 1 end
        return n
    end

    -- 到点才真正落盘。返回 true 表示这次真的写了。
    -- 注意：写盘仍是同步 IO，但频次被压到每 interval 秒最多一次。
    function self.flushIfDue(now)
        if not self.dirty then return false end
        now = now or os.time()
        if (now - self.lastFlush) < self.interval then return false end
        return self.flushNow(now)
    end

    -- 强制立刻落盘（换场景 / 退出前 / 用户点「重新采样」时用）。
    function self.flushNow(now)
        if not self.dirty then return false end
        local ok, text = pcall(self.encode, self.data)
        if not ok then
            log.once("store:" .. self.name .. ":enc", self.name .. " 序列化失败: " .. tostring(text))
            return false
        end
        local f = io.open(self.path, "w")
        if not f then
            log.once("store:" .. self.name .. ":open", self.name .. " 无法写入: " .. self.path)
            return false
        end
        f:write(text)
        f:close()
        self.dirty = false
        self.lastFlush = now or os.time()
        self.writeCount = self.writeCount + 1
        return true
    end

    -- 让下一次 flushIfDue 立刻可执行（例如刚清空数据，想马上把空文件写下去）
    function self.markDue()
        self.lastFlush = 0
    end

    return self
end

return store
