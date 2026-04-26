--[[ Match telemetry logger.

     Phase 12.1 — empirical probe + dispatch.

     Lua print() in Dota's bot script VM does NOT route to console.log.
     Verified empirically: a full match with -condebug enabled showed
     ZERO [ABA_LOG] lines, and OHA's own existing print()-based debug
     statements ([OHA draft], [OHA t=Xs] intent: ...) also never appeared.

     Source 2 server.dll exposes other vscript output primitives that
     MIGHT route to console.log:
       - SendToServerConsole(cmd)  -- runs a server console command
       - SendToConsole(cmd)        -- runs a console command
       - Msg(text)                 -- engine console message (often)
       - Warning(text)             -- engine warning channel

     This file's first job is to determine which one(s) work. On the
     first call to MaybeTick, we fire ONE probe line per candidate
     primitive, each tagged with a unique prefix. After the user plays
     a brief match (30s+), grepping console.log for the tags reveals
     which primitive(s) reach disk. Then we hard-wire the logger to use
     the winning one(s).

     Until the probe completes, real telemetry uses ALL primitives at
     once — wasteful but guarantees that whichever primitive works,
     records get captured.
     ]]
local ____exports = {}

local Customize = nil
do
    local ok, m = pcall(require, GetScriptDirectory().."/Customize/general")
    if ok then Customize = m end
end

local LOGGER_ENABLED = false
local TICK_INTERVAL = 5.0
if Customize and Customize.Logger then
    LOGGER_ENABLED = Customize.Logger.Enabled or false
    TICK_INTERVAL = Customize.Logger.TickInterval or TICK_INTERVAL
end

local LOG_PREFIX = "[ABA_LOG] "

local _last_tick_t = -999
local _initialized = false
local _probe_done = false

-- ============================================================
-- Inline JSON encoder (no third-party deps)
-- ============================================================

local function json_escape(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, '"', '\\"')
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "\r", "\\r")
    s = string.gsub(s, "\t", "\\t")
    return s
end

local function json_value(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v then return "null" end
        if v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    end
    if t == "string" then return '"' .. json_escape(v) .. '"' end
    if t == "table" then
        local n = 0
        local is_array = true
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                is_array = false
            end
        end
        if is_array and n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = json_value(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, vv in pairs(v) do
            table.insert(parts, '"' .. json_escape(tostring(k)) .. '":' .. json_value(vv))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return '"' .. tostring(v) .. '"'
end

-- ============================================================
-- Probe: write ONE line per candidate primitive at startup
--
-- Each line is tagged with a unique sentinel so I (Claude) can grep
-- the resulting console.log to see which primitive(s) actually wrote.
-- After the probe, I'll rewrite this module to use only the winner(s).
-- ============================================================

local function safe_call(fn, ...)
    if fn == nil then return false end
    local ok = pcall(fn, ...)
    return ok
end

local function run_probe()
    if _probe_done then return end
    _probe_done = true

    -- Tag schema: [ABA_PROBE/<primitive>] <payload>
    -- Grep `[ABA_PROBE/` in console.log to see which made it through.
    local payload = "hello-from-bot-script-t" .. tostring(math.floor(DotaTime()))

    -- 1. Plain Lua print
    safe_call(print, "[ABA_PROBE/print] " .. payload)

    -- 2. Source engine Msg (if exposed)
    if _G.Msg ~= nil then
        safe_call(_G.Msg, "[ABA_PROBE/Msg] " .. payload .. "\n")
    else
        safe_call(print, "[ABA_PROBE/Msg-MISSING] (Msg not in _G)")
    end

    -- 3. Source engine Warning
    if _G.Warning ~= nil then
        safe_call(_G.Warning, "[ABA_PROBE/Warning] " .. payload .. "\n")
    else
        safe_call(print, "[ABA_PROBE/Warning-MISSING] (Warning not in _G)")
    end

    -- 4. SendToServerConsole — most likely candidate per server.dll symbols
    if _G.SendToServerConsole ~= nil then
        safe_call(_G.SendToServerConsole, "echo [ABA_PROBE/SendToServerConsole] " .. payload)
    else
        safe_call(print, "[ABA_PROBE/SendToServerConsole-MISSING]")
    end

    -- 5. SendToConsole
    if _G.SendToConsole ~= nil then
        safe_call(_G.SendToConsole, "echo [ABA_PROBE/SendToConsole] " .. payload)
    else
        safe_call(print, "[ABA_PROBE/SendToConsole-MISSING]")
    end

    -- 6. printl (Source 2 specific helper, sometimes bound)
    if _G.printl ~= nil then
        safe_call(_G.printl, "[ABA_PROBE/printl] " .. payload)
    else
        safe_call(print, "[ABA_PROBE/printl-MISSING]")
    end

    -- 7. MsgN (Msg with newline, Source convention)
    if _G.MsgN ~= nil then
        safe_call(_G.MsgN, "[ABA_PROBE/MsgN] " .. payload)
    else
        safe_call(print, "[ABA_PROBE/MsgN-MISSING]")
    end
end

-- ============================================================
-- Multi-sink emit: until probe is verified, fire on every working
-- primitive in parallel so SOMETHING reaches the log.
-- ============================================================

local function emit_multi(line)
    -- Lua print
    pcall(print, line)
    -- echo to server console (works if SendToServerConsole is bound)
    if _G.SendToServerConsole ~= nil then
        pcall(_G.SendToServerConsole, "echo " .. line)
    end
    if _G.SendToConsole ~= nil then
        pcall(_G.SendToConsole, "echo " .. line)
    end
    if _G.Msg ~= nil then
        pcall(_G.Msg, line .. "\n")
    end
end

-- ============================================================
-- Public API
-- ============================================================

function ____exports.Event(kind, fields)
    if not LOGGER_ENABLED then return end
    if not _initialized then
        _initialized = true
        run_probe()
        local rec = {
            type = "session_start",
            t = DotaTime(),
            gt = GameTime(),
            team = GetTeam(),
        }
        emit_multi(LOG_PREFIX .. json_value(rec))
    end
    local rec = { type = kind, t = DotaTime(), gt = GameTime() }
    if type(fields) == "table" then
        for k, v in pairs(fields) do rec[k] = v end
    end
    emit_multi(LOG_PREFIX .. json_value(rec))
end

function ____exports.MaybeTick(bot)
    if not LOGGER_ENABLED then return end
    if bot == nil then return end
    local now = DotaTime()
    if now - _last_tick_t < TICK_INTERVAL then return end
    -- Wait until engine is fully set up before snapshotting (avoids the
    -- m_pActiveBotMode null assertion crash).
    if now < 30 then return end
    _last_tick_t = now

    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    local okName, name = pcall(function() return bot:GetUnitName() end)
    local okHp, hp = pcall(function() return bot:GetHealth() / math.max(1, bot:GetMaxHealth()) end)
    local okNW, nw = pcall(function() return bot:GetNetWorth() end)
    local okLvl, lvl = pcall(function() return bot:GetLevel() end)
    local okLoc, loc = pcall(function() return bot:GetLocation() end)

    local intent = nil
    local tp_ok, jmz = pcall(require, GetScriptDirectory().."/FunLib/jmz_func")
    if tp_ok and jmz and jmz.TeamPlan and jmz.TeamPlan.GetCurrentPlan then
        local okPlan, plan = pcall(function() return jmz.TeamPlan.GetCurrentPlan() end)
        if okPlan and plan then intent = plan.intent end
    end

    ____exports.Event("tick", {
        pid = okPid and pid or -1,
        hero = okName and name or "?",
        hp_pct = okHp and hp or -1,
        networth = okNW and nw or 0,
        level = okLvl and lvl or 0,
        x = (okLoc and loc) and loc.x or 0,
        y = (okLoc and loc) and loc.y or 0,
        intent = intent,
    })
end

function ____exports.AbilityCast(bot, abilityName, targetName)
    if not LOGGER_ENABLED then return end
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    local okN, name = pcall(function() return bot:GetUnitName() end)
    ____exports.Event("ability_cast", {
        pid = okPid and pid or -1,
        hero = okN and name or "?",
        ability = abilityName,
        target = targetName,
    })
end

function ____exports.IntentTransition(prev_intent, new_intent, reason)
    if not LOGGER_ENABLED then return end
    ____exports.Event("intent_transition", { prev = prev_intent, next = new_intent, reason = reason })
end

function ____exports.ScoutDelegated(task, owner_pid)
    if not LOGGER_ENABLED then return end
    ____exports.Event("scout_delegated", { task = task, owner_pid = owner_pid })
end

function ____exports.MinionStuck(bot, minionName, ticks)
    if not LOGGER_ENABLED then return end
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    ____exports.Event("minion_stuck", {
        pid = okPid and pid or -1,
        minion = minionName,
        ticks = ticks,
    })
end

local _last_kills = {}
local _last_deaths = {}
local _last_alive = {}

function ____exports.PollKillStream(bot)
    if not LOGGER_ENABLED then return end
    if bot == nil then return end
    if DotaTime() < 30 then return end
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    if not okPid then return end
    local okN, hero = pcall(function() return bot:GetUnitName() end)
    local okK, kills = pcall(function() return bot:GetKills() end)
    local okD, deaths = pcall(function() return bot:GetDeaths() end)
    local okA, alive = pcall(function() return bot:IsAlive() end)
    local okL, loc = pcall(function() return bot:GetLocation() end)

    if okK and kills ~= nil then
        local prev = _last_kills[pid] or kills
        if kills > prev then
            ____exports.Event("kill", {
                pid = pid, hero = okN and hero or "?",
                kills_total = kills,
                x = (okL and loc) and loc.x or 0,
                y = (okL and loc) and loc.y or 0,
            })
        end
        _last_kills[pid] = kills
    end

    if okD and deaths ~= nil then
        local prev = _last_deaths[pid] or deaths
        if deaths > prev then
            ____exports.Event("death", {
                pid = pid, hero = okN and hero or "?",
                deaths_total = deaths,
                x = (okL and loc) and loc.x or 0,
                y = (okL and loc) and loc.y or 0,
            })
        end
        _last_deaths[pid] = deaths
    end

    if okA then
        if _last_alive[pid] == false and alive == true then
            ____exports.Event("respawn", { pid = pid, hero = okN and hero or "?" })
        end
        _last_alive[pid] = alive
    end
end

function ____exports.IsEnabled() return LOGGER_ENABLED end
function ____exports.Flush() end
function ____exports.Close() end
function ____exports.GetPath() return "console.log (via -condebug + working primitive TBD)" end

return ____exports
