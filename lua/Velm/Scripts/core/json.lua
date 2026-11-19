-- 极简 JSON 解析 / 序列化。
--
-- 为什么不直接用 UE4SS 自带的 json：它在这个 build 里暴露的接口不稳定
-- （早期版本没有 Json 库，后来的版本字段名变过）。自己带一份 90 行的解析器，
-- 跨版本不会坏。
--
-- 只支持标准 JSON 子集：对象、数组、字符串、数字、true/false/null。
-- 不支持：注释、单引号字符串、尾逗号、NaN/Infinity。参数表由面板（C#）生成，
-- 永远是标准 JSON。

local json = {}

local function skipws(s, i)
    while true do
        local c = s:sub(i, i)
        if c == " " or c == "\n" or c == "\r" or c == "\t" then i = i + 1 else return i end
    end
end

local parseValue

local function parseString(s, i)
    i = i + 1
    local out = {}
    while true do
        local c = s:sub(i, i)
        if c == "" then error("unterminated string at " .. i) end
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local n = s:sub(i + 1, i + 1)
            if n == "n" then table.insert(out, "\n")
            elseif n == "t" then table.insert(out, "\t")
            elseif n == "r" then table.insert(out, "\r")
            elseif n == "b" then table.insert(out, "\b")
            elseif n == "f" then table.insert(out, "\f")
            elseif n == "u" then
                local cp = tonumber(s:sub(i + 2, i + 5), 16) or 63
                if utf8 and utf8.char then table.insert(out, utf8.char(cp)) else table.insert(out, "?") end
                i = i + 4
            else table.insert(out, n) end
            i = i + 2
        else
            table.insert(out, c)
            i = i + 1
        end
    end
end

local function parseNumber(s, i)
    local j = i
    while true do
        local c = s:sub(j, j)
        if c:match("[%d%.%-eE%+]") then j = j + 1 else break end
    end
    return tonumber(s:sub(i, j - 1)) or 0, j
end

parseValue = function(s, i)
    i = skipws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local t = {}
        i = skipws(s, i + 1)
        if s:sub(i, i) == "}" then return t, i + 1 end
        while true do
            i = skipws(s, i)
            local k, ni = parseString(s, i)
            i = skipws(s, ni)
            i = i + 1                      -- 跳过冒号
            local v
            v, i = parseValue(s, i)
            t[k] = v
            i = skipws(s, i)
            local sep = s:sub(i, i)
            i = i + 1
            if sep == "}" then return t, i end
            if sep ~= "," then error("bad object at " .. i) end
        end
    elseif c == "[" then
        local t = {}
        i = skipws(s, i + 1)
        if s:sub(i, i) == "]" then return t, i + 1 end
        while true do
            local v
            v, i = parseValue(s, i)
            table.insert(t, v)
            i = skipws(s, i)
            local sep = s:sub(i, i)
            i = i + 1
            if sep == "]" then return t, i end
            if sep ~= "," then error("bad array at " .. i) end
        end
    elseif c == '"' then
        return parseString(s, i)
    elseif c == "t" then return true, i + 4
    elseif c == "f" then return false, i + 5
    elseif c == "n" then return nil, i + 4
    else
        return parseNumber(s, i)
    end
end

-- 解析。失败返回 nil + 错误信息，绝不抛异常 —— 参数表可能正被面板写到一半。
function json.decode(text)
    if type(text) ~= "string" or #text == 0 then return nil, "empty" end
    local ok, data = pcall(parseValue, text, 1)
    if not ok then return nil, tostring(data) end
    if type(data) ~= "table" then return nil, "not a table" end
    return data
end

-- 读文件并解析。文件不存在返回 nil，不报错。
function json.loadFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local txt = f:read("*a")
    f:close()
    return json.decode(txt)
end

local function esc(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
    return '"' .. s .. '"'
end
json.escape = esc

-- 序列化。只处理「字符串 key 的表 = 对象」和「纯数组 = 数组」两种情况。
-- 数字统一保留 6 位有效数字：后处理原值（0.000001 量级）和强度（100+）都能表示。
local function encodeValue(v, out)
    local tv = type(v)
    if tv == "nil" then
        table.insert(out, "null")
    elseif tv == "boolean" then
        table.insert(out, v and "true" or "false")
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            table.insert(out, "0")
        else
            table.insert(out, string.format("%.6g", v))
        end
    elseif tv == "string" then
        table.insert(out, esc(v))
    elseif tv == "table" then
        -- 判断是不是纯数组（1..n 连续整数键）
        local n = #v
        local isArray = true
        local count = 0
        for _ in pairs(v) do
            count = count + 1
            if count > n then isArray = false break end
        end
        if isArray and n > 0 then
            table.insert(out, "[")
            for i = 1, n do
                if i > 1 then table.insert(out, ",") end
                encodeValue(v[i], out)
            end
            table.insert(out, "]")
        elseif count == 0 then
            table.insert(out, "{}")
        else
            -- 对象：key 排序，保证同样的数据写出来字节一致（便于比对、便于 diff）
            local keys = {}
            for k in pairs(v) do table.insert(keys, tostring(k)) end
            table.sort(keys)
            table.insert(out, "{")
            for i, k in ipairs(keys) do
                if i > 1 then table.insert(out, ",") end
                table.insert(out, esc(k))
                table.insert(out, ":")
                encodeValue(v[k], out)
            end
            table.insert(out, "}")
        end
    else
        table.insert(out, "null")
    end
end

function json.encode(v)
    local out = {}
    encodeValue(v, out)
    return table.concat(out)
end

return json
