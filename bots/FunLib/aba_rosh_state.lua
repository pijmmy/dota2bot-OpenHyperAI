--[[ Rosh / Aegis / Buyback state machine (Phase 11 Item 9).

     Late-game (25-40 min) is where matches are decided in our sim window;
     pivotal Rosh / Aegis / buyback decisions can swap who wins. This module
     centralizes:

       - Rosh respawn phase: locked (<7min since kill) | scout (7-8) |
         open (8-11) | respawned (>11)
       - Aegis tracker: who picked it up, when, how long until expiry.
         Aegis-about-to-expire pressures the team to use it (i.e., commit
         to a push or fight to convert before it's wasted).
       - Buyback gate: should this bot buyback now? Requires gold AND
         a fight in progress AND ability to actually reach the fight.

     Exposed as J.RoshState.*
     ]]
local ____exports = {}

-- Rosh respawn timing: 8-11 min after death (uniform random in Dota).
-- Aegis lasts 5 min from pickup before expiring back into a free aegis
-- you can re-pickup if you have it dropped, or 5 min before the hero
-- with it loses the buff.
local ROSH_RESPAWN_MIN = 8 * 60
local ROSH_RESPAWN_MAX = 11 * 60
local AEGIS_DURATION = 5 * 60

local _state = {
    last_killed_at = -999,           -- DotaTime when rosh died (unknown initially)
    aegis_holder_pid = -1,           -- player id holding aegis
    aegis_picked_at = -999,
    last_phase = "respawned",
}

-- ============================================================
-- Internal helpers
-- ============================================================

local function _jmz()
    local ok, J = pcall(require, GetScriptDirectory().."/FunLib/jmz_func")
    if ok then return J end
    return nil
end

-- Detect rosh kill by polling IsRoshanAlive transitions. Cheap.
local _last_known_alive = true
local function pollKill()
    local ok, alive = pcall(function() return IsRoshanAlive() end)
    if not ok then return end
    if _last_known_alive and not alive then
        -- Just died
        _state.last_killed_at = DotaTime()
    end
    _last_known_alive = alive
end

-- Detect aegis pickup by checking for the modifier on each ally.
local function pollAegis()
    local team = GetTeam()
    local players = GetTeamPlayers(team)
    local now = DotaTime()
    local stillHeld = false
    for i = 1, #players do
        local m = GetTeamMember(i)
        if m ~= nil and m:IsAlive() then
            local ok, has = pcall(function() return m:HasModifier("modifier_aegis") end)
            if ok and has then
                if _state.aegis_holder_pid ~= players[i] then
                    _state.aegis_holder_pid = players[i]
                    _state.aegis_picked_at = now
                end
                stillHeld = true
            end
        end
    end
    if not stillHeld and _state.aegis_holder_pid >= 0 then
        -- Aegis expired or used
        _state.aegis_holder_pid = -1
    end
end

-- ============================================================
-- Public API
-- ============================================================

-- Tick from any bot. Cheap polls (no leader gating; this is per-bot but
-- the pcalls and modifier checks are fast).
function ____exports.Tick()
    pollKill()
    pollAegis()
end

-- Returns the current rosh phase as a string.
function ____exports.GetPhase()
    local since = DotaTime() - _state.last_killed_at
    if _state.last_killed_at < 0 then return "respawned" end
    if since < 7 * 60 then return "locked" end
    if since < ROSH_RESPAWN_MIN then return "scout" end
    if since < ROSH_RESPAWN_MAX then return "open" end
    return "respawned"
end

-- Returns true if the team should consider contesting rosh right now.
-- Combines phase, ally count, scout report.
function ____exports.ShouldContestRosh()
    local phase = ____exports.GetPhase()
    if phase == "locked" then return false end

    local team = GetTeam()
    local players = GetTeamPlayers(team)
    local alive = 0
    for i = 1, #players do
        if IsHeroAlive(players[i]) then alive = alive + 1 end
    end
    if alive < 4 then return false end

    -- Need scout confirmation (delegated check handled by aba_team_state).
    local J = _jmz()
    if J ~= nil and J.TeamState and J.TeamState.IsTeamCommitted("rosh") then
        return true
    end

    -- Otherwise allow contest_rosh in "open" phase if numbers favor us.
    if phase == "open" or phase == "respawned" then return true end
    return false
end

-- Returns aegis-expiry pressure multiplier for push_lane intent. When
-- aegis is on a teammate and approaching expiry, BIAS push_lane up to
-- "use it or lose it". Returns value in [1.0, 1.10].
function ____exports.AegisExpirePressure()
    if _state.aegis_holder_pid < 0 then return 1.0 end
    local age = DotaTime() - _state.aegis_picked_at
    if age < 3 * 60 then return 1.0 end
    if age < 4 * 60 then return 1.05 end
    return 1.10  -- last minute — push hard before it's wasted
end

-- Buyback gate. Returns true if THIS bot should buy back NOW.
function ____exports.ShouldBuyback(bot)
    if bot == nil or bot:IsAlive() then return false end
    -- Need the gold
    local okG, gold = pcall(function() return bot:GetGold() end)
    if not okG or gold == nil then return false end
    -- Buyback cost grows with level: roughly 100 + level*1.5 + gold/13
    -- We approximate: requires GetBuybackCost() if available, else min 1000.
    local okC, cost = pcall(function() return bot:GetBuybackCost() end)
    local need = (okC and type(cost) == "number") and cost or 1000
    if gold < need then return false end

    -- Need a reason: ancient under attack OR fight we can win
    local team = GetTeam()
    local ancient = GetAncient(team)
    if ancient ~= nil and (ancient:GetHealth() / math.max(1, ancient:GetMaxHealth())) < 0.5 then
        return true
    end

    -- Active commit_kill or contest_rosh by team
    local J = _jmz()
    if J ~= nil and J.TeamPlan and J.TeamPlan.GetIntent then
        local intent = J.TeamPlan.GetIntent(bot)
        if intent == "commit_kill" or intent == "contest_rosh" or intent == "defend_base" then
            return true
        end
    end
    return false
end

function ____exports.Describe()
    local phase = ____exports.GetPhase()
    local since = DotaTime() - _state.last_killed_at
    local aegis_str = "none"
    if _state.aegis_holder_pid >= 0 then
        local age = DotaTime() - _state.aegis_picked_at
        aegis_str = string.format("pid=%d age=%.0fs", _state.aegis_holder_pid, age)
    end
    return string.format("phase=%s since_kill=%.0fs aegis=%s",
        phase, since, aegis_str)
end

return ____exports
