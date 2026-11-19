-- cvar / exec 这两类「动作型」参数。
--
-- 共同点：它们不是「往某个组件写一个值」，而是一次性动作。
-- 所以不能走 engine 的六步流程，必须各自实现，但语义仍然统一在这里。

local log = require("core.log")
local ue  = require("core.ue")

local misc = {}

-- ---------------------------------------------------------------- cvar

-- 直接写 cvar（UE5.3+ 才有 SetConsoleVariable*），比走控制台可靠。
local directPath = nil
local seenCvarErr = {}

local function ksl() return ue.ksl() end

function misc.cvarGetF(name)
    local k = ksl()
    if not k then return nil end
    local ok, v = pcall(function() return k:GetConsoleVariableFloatValue(name) end)
    if ok then return v end
    return nil
end

local function cvarDirect(name, value)
    local k = ksl()
    if not k then return false end
    local isInt = (math.abs(value - math.floor(value)) < 1e-6)
    local e1, e2
    if isInt and directPath ~= "float" then
        local ok = pcall(function() k:SetConsoleVariableIntValue(name, math.floor(value)) end)
        if ok then
            if directPath ~= "int" then directPath = "int"; log.info("cvar setter -> IntValue") end
            return true
        end
        e1 = "int failed"
    end
    if directPath ~= "int" then
        local ok2 = pcall(function() k:SetConsoleVariableFloatValue(name, value) end)
        if ok2 then
            if directPath ~= "float" then directPath = "float"; log.info("cvar setter -> FloatValue") end
            return true
        end
        e2 = "float failed"
    end
    if not seenCvarErr[name] then
        seenCvarErr[name] = true
        log.info("cvarDirect " .. name .. " failed: " .. tostring(e1) .. " " .. tostring(e2))
    end
    return false
end

-- ---------------------------------------------------------------- exec

local execPath = nil
local seenExecErr = {}

local function exec(cmd)
    local k = ksl()
    local gi = ue.gi()
    local pc = ue.pc()
    if not k then return false end
    local list = {
        { id = 1, name = "KSL_dot_gi",  fn = function() return k.ExecuteConsoleCommand(gi, cmd, nil) end },
        { id = 2, name = "KSL_dot_pc",  fn = function() return k.ExecuteConsoleCommand(pc, cmd, nil) end },
        { id = 3, name = "KSL_gi_null", fn = function() return k:ExecuteConsoleCommand(gi, cmd, nil) end },
        { id = 4, name = "KSL_gi_pc",   fn = function() return k:ExecuteConsoleCommand(gi, cmd, pc) end },
    }
    for _, a in ipairs(list) do
        if execPath == nil or execPath == a.id then
            local ok = pcall(a.fn)
            if ok then
                if execPath ~= a.id then
                    execPath = a.id
                    log.info("exec path -> #" .. a.id .. " " .. a.name)
                end
                return true
            end
            if execPath == nil and not seenExecErr[a.id] then
                seenExecErr[a.id] = true
                log.info("exec #" .. a.id .. " " .. a.name .. " failed")
            end
        end
    end
    if execPath == nil then
        log.once("exec:none", "console command path unavailable")
    end
    return false
end

function misc.canExec()
    return execPath ~= nil
end

-- ---------------------------------------------------------------- 参数应用

function misc.applyCvar(p)
    local v
    if p.type == "bool" then
        v = p.value and (p.on or 1) or (p.off or 0)
    else
        v = p.value
    end
    if not cvarDirect(p.target, v) then
        exec(p.target .. " " .. log.fmt(v))
    end
end

function misc.applyExec(p)
    if p.target == "r.SetRes" then
        exec("r.SetRes " .. tostring(p.value))
    elseif not cvarDirect(p.target, p.value or 0) then
        exec(p.target .. " " .. log.fmt(p.value or 0))
    end
end

function misc.forget()
    execPath = nil
    directPath = nil
end

return misc
