--[[ Match telemetry logger.

     Writes per-tick + per-event JSON records to a file during a Dota 2
     custom-lobby match. The output log is machine-readable and consumed
     by the guineapig sim's diagnostic module (sim.review / sim.diagnose)
     to automatically surface bad-behavior anti-patterns WITHOUT a human
     having to watch the game and report.

     Workflow:
       1. Match starts — logger opens a file at:
            <Dota>/game/dota/scripts/vscripts/bots/logs/match_<unix>.json
       2. During match — every TICK_INTERVAL seconds (default 5s) each bot
          posts a snapshot (intent, focus, mode, position, hp, networth).
          On key events (ability cast, death, item buy, scout delegation,
          team-plan transition) records are pushed immediately.
       3. Match ends — the log is finalized as a JSON array.

     The file format is INTENTIONALLY one JSON object per line (NDJSON)
     so partial logs (game crash, mid-match read) are still parseable.
     The diagnostic module reads NDJSON, sorts by time, and runs checks.

     Exposed as J.Logger.* via jmz_func.lua. Disabled by default; enable
     via Customize.Logger.Enabled.

     IMPORTANT: file I/O from Lua bot scripts is sandboxed by Dota. The
     `io.open` call may fail silently in some environments. Logger checks
     for this and degrades gracefully (no-op) if write isn't permitted.
     ]]
local ____exports = {}

local Customize = nil
do
    local ok, m = pcall(require, GetScriptDirectory().."/Customize/general")
    if ok then Customize = m end
end

-- Logger config. Disabled by default — opt-in by adding to Customize.
local LOGGER_ENABLED = false
local TICK_INTERVAL = 5.0   -- seconds between snapshots
if Customize and Customize.Logger then
    LOGGER_ENABLED = Customize.Logger.Enabled or false
    TICK_INTERVAL = Customize.Logger.TickInterval or TICK_INTERVAL
end

local _file = nil
local _file_path = nil
local _last_tick_t = -999
local _initialized = false
local _failed_to_open = false

-- ============================================================
-- JSON encoding (lua-native, single-line per record)
-- ============================================================

-- Lightweight JSON encoder. We don't need full schema — just numbers,
-- strings, bools, nil, and tables. Keys are always strings.
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
        if v ~= v then return "null" end       -- NaN
        if v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    end
    if t == "string" then return '"' .. json_escape(v) .. '"' end
    if t == "table" then
        -- Detect array vs object by checking for sequential int keys
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
-- File handling
-- ============================================================

local function tryOpen()
    if _failed_to_open then return false end
    if _file ~= nil then return true end
    if not LOGGER_ENABLED then return false end

    -- Build a unique path per-match. Dota's bot script sandbox usually
    -- allows writes to the bots/logs/ directory.
    local dir = GetScriptDirectory() .. "/logs"
    local timestamp = math.floor(GameTime() * 1000)
    _file_path = dir .. "/match_" .. tostring(timestamp) .. ".ndjson"
    local f, err = io.open(_file_path, "w")
    if f == nil then
        _failed_to_open = true
        print("[aba_logger] Could not open log file: " .. tostring(err))
        return false
    end
    _file = f
    _initialized = true
    -- Header record
    ____exports.Event("session_start", { dota_time = DotaTime(), team = GetTeam() })
    return true
end

-- ============================================================
-- Public API
-- ============================================================

-- Write one event record. Cheap; safe to call from any hook.
function ____exports.Event(kind, fields)
    if not LOGGER_ENABLED then return end
    if not tryOpen() then return end

    local rec = {
        type = kind,
        t = DotaTime(),
        gt = GameTime(),
    }
    if type(fields) == "table" then
        for k, v in pairs(fields) do rec[k] = v end
    end
    local line = json_value(rec) .. "\n"
    local ok, err = pcall(function() _file:write(line); _file:flush() end)
    if not ok then
        _failed_to_open = true
        print("[aba_logger] Write failed: " .. tostring(err))
    end
end

-- Snapshot bot state. Throttled to TICK_INTERVAL — call once per tick from
-- bot_generic.lua / mode_*.lua and the throttle handles the rate.
function ____exports.MaybeTick(bot)
    if not LOGGER_ENABLED then return end
    if bot == nil then return end
    local now = DotaTime()
    if now - _last_tick_t < TICK_INTERVAL then return end
    _last_tick_t = now

    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    local okName, name = pcall(function() return bot:GetUnitName() end)
    local okHp, hp = pcall(function() return bot:GetHealth() / math.max(1, bot:GetMaxHealth()) end)
    local okNW, nw = pcall(function() return bot:GetNetWorth() end)
    local okLvl, lvl = pcall(function() return bot:GetLevel() end)
    local okMode, mode = pcall(function() return bot:GetActiveMode() end)
    local okMD, mdesire = pcall(function() return bot:GetActiveModeDesire() end)
    local okLoc, loc = pcall(function() return bot:GetLocation() end)

    -- Pull team-plan intent if loaded
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
        mode = okMode and mode or 0,
        mode_desire = okMD and mdesire or 0,
        x = (okLoc and loc) and loc.x or 0,
        y = (okLoc and loc) and loc.y or 0,
        intent = intent,
    })
end

-- Specific event helpers (cleaner call sites than passing strings around)
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
    ____exports.Event("intent_transition", {
        prev = prev_intent,
        next = new_intent,
        reason = reason,
    })
end

function ____exports.ScoutDelegated(task, owner_pid)
    ____exports.Event("scout_delegated", { task = task, owner_pid = owner_pid })
end

function ____exports.MinionStuck(bot, minionName, ticks)
    -- Logged when a minion has been idle (no attack target, near bot) for
    -- N consecutive ticks. Used for the "forged spirit standing still"
    -- diagnostic class.
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    ____exports.Event("minion_stuck", {
        pid = okPid and pid or -1,
        minion = minionName,
        ticks = ticks,
    })
end

-- ============================================================
-- Kill stream — polls every bot's GetKills/GetDeaths each tick and emits
-- a kill_event whenever the counter increments. Live; flushed immediately
-- so the log reflects kills the moment they happen (no end-of-match wait).
-- ============================================================

local _last_kills = {}    -- pid -> last seen kill count
local _last_deaths = {}   -- pid -> last seen death count
local _last_alive = {}    -- pid -> last alive bool

function ____exports.PollKillStream(bot)
    if not LOGGER_ENABLED then return end
    if bot == nil then return end
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    if not okPid then return end
    local okN, hero = pcall(function() return bot:GetUnitName() end)
    local okK, kills = pcall(function() return bot:GetKills() end)
    local okD, deaths = pcall(function() return bot:GetDeaths() end)
    local okA, alive = pcall(function() return bot:IsAlive() end)
    local okL, loc = pcall(function() return bot:GetLocation() end)

    -- Kill increment
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

    -- Death increment
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

    -- Alive transitions (catches respawns)
    if okA then
        if _last_alive[pid] == false and alive == true then
            ____exports.Event("respawn", { pid = pid, hero = okN and hero or "?" })
        end
        _last_alive[pid] = alive
    end
end

-- Flush hint: NDJSON is already flushed after every write, but we expose
-- this for explicit "save now" calls if the bot wants belt-and-suspenders.
function ____exports.Flush()
    if _file ~= nil then
        pcall(function() _file:flush() end)
    end
end

function ____exports.Close()
    if _file ~= nil then
        ____exports.Event("session_end", { dota_time = DotaTime() })
        local ok = pcall(function() _file:close() end)
        _file = nil
    end
end

function ____exports.IsEnabled()
    return LOGGER_ENABLED
end

function ____exports.GetPath()
    return _file_path
end

return ____exports
