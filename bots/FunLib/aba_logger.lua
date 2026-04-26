--[[ Match telemetry logger.

     Writes per-tick + per-event records to Dota's console output via
     `print()`. With Dota launched with `-condebug` in launch options,
     these lines are captured to:

         <Steam>/steamapps/common/dota 2 beta/game/dota/console.log

     The file is appended in real time so mid-match reads / kill-stream
     work. Each record is one line:

         [ABA_LOG] {"type":"tick","t":300,"pid":0,"hero":"...","intent":"farm",...}

     A Python-side tailer (sim.review) filters lines starting with the
     [ABA_LOG] prefix, strips it, parses the JSON.

     IMPORTANT: previous version used `io.open` for direct file writes.
     Dota's bot script VM sandboxes io.open — calling it crashed bot
     loading during hero selection. `print()` is the supported logging
     primitive. This rewrite uses ONLY print(), no file I/O.

     Disabled by default; opt-in via Customize.Logger.Enabled. Exposed
     as J.Logger.* via jmz_func.lua.
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

-- Prefix that the Python tailer (sim.review) greps for. Don't change without
-- updating sim/review.py LOG_PREFIX in lockstep.
local LOG_PREFIX = "[ABA_LOG] "

local _last_tick_t = -999
local _initialized = false

-- ============================================================
-- Inline JSON encoder (no third-party deps; Dota Lua doesn't ship one)
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
-- Public API
-- ============================================================

local function emit(rec)
    -- Single point of failure: print() can't crash but it can be no-op'd
    -- without -condebug. If the user has -condebug, lines append to
    -- console.log immediately. If not, lines still go to the in-game
    -- developer console (toggleable with backtick in-game).
    local ok, encoded = pcall(json_value, rec)
    if not ok then return end
    print(LOG_PREFIX .. encoded)
end

function ____exports.Event(kind, fields)
    if not LOGGER_ENABLED then return end
    if not _initialized then
        _initialized = true
        emit({
            type = "session_start",
            t = DotaTime(),
            gt = GameTime(),
            team = GetTeam(),
        })
    end
    local rec = { type = kind, t = DotaTime(), gt = GameTime() }
    if type(fields) == "table" then
        for k, v in pairs(fields) do rec[k] = v end
    end
    emit(rec)
end

function ____exports.MaybeTick(bot)
    if not LOGGER_ENABLED then return end
    if bot == nil then return end
    local now = DotaTime()
    if now - _last_tick_t < TICK_INTERVAL then return end
    -- Skip logging during the negative-time pre-game window AND the first
    -- 30s of game time. Dota's m_pActiveBotMode is null until the engine
    -- has picked a mode for each bot — and bot:GetActiveMode() ASSERTS at
    -- the C level if called when the pointer is null. pcall cannot catch a
    -- C-level access violation; it crashes the whole engine. Gating on
    -- DotaTime > 30 avoids the window where this is risky.
    if now < 30 then return end
    _last_tick_t = now

    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    local okName, name = pcall(function() return bot:GetUnitName() end)
    local okHp, hp = pcall(function() return bot:GetHealth() / math.max(1, bot:GetMaxHealth()) end)
    local okNW, nw = pcall(function() return bot:GetNetWorth() end)
    local okLvl, lvl = pcall(function() return bot:GetLevel() end)
    -- DELIBERATELY DO NOT CALL bot:GetActiveMode() — see comment above.
    -- bot:GetActiveModeDesire() goes through the same null-check path and
    -- is also unsafe at start-of-match. Both removed.
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
    ____exports.Event("intent_transition", {
        prev = prev_intent,
        next = new_intent,
        reason = reason,
    })
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

-- ============================================================
-- Kill-stream — polls every bot's GetKills/GetDeaths each tick.
-- Emits records the moment a counter increments so log shows kills live.
-- ============================================================

local _last_kills = {}
local _last_deaths = {}
local _last_alive = {}

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
function ____exports.Flush() end   -- no-op: print() already auto-flushes
function ____exports.Close() end   -- no-op: console.log is managed by Dota
function ____exports.GetPath() return "console.log (via -condebug)" end

return ____exports
