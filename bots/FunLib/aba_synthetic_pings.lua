-- Synthetic team objective pings for bot-only teams.
--
-- aba_teamplan.lua's user-ping → push_lane / defend_lane path only fires
-- when a human is on the bot's team (J.GetHumanPing iterates GetTeamPlayers
-- looking for a non-bot member). The enemy team in a custom lobby has no
-- humans, so the ping path silently fails for them. Result: enemy bots
-- never get the explicit "go push that tower" / "group up here" intent
-- driver, and play feels listless.
--
-- This module simulates a team-consensus ping for bot-only teams. It cycles
-- through objectives consistent with the team's drafted strategy and the
-- current game state. The ping's `location` and `time` fields are the same
-- shape `bot:GetMostRecentPing()` returns, so the existing aba_teamplan
-- ping consumer doesn't need to know it's synthetic.
--
-- Exposed as J.SyntheticPing.

local ____exports = {}

local jmz = require(GetScriptDirectory() .. "/FunLib/jmz_func")

-- Module state, per-team. Both Radiant and Dire teams might be all-bot
-- in mirror lobbies.
local _state = {}

local PING_REFRESH_SEC = 30
local DEFAULT_PING_RECENCY = 8   -- aba_teamplan considers a ping recent for 8s

local function getTeamState(team)
    if _state[team] == nil then
        _state[team] = {
            last_refresh = -999,
            current_ping = nil,
            cycle_index = 0,
        }
    end
    return _state[team]
end

local function teamHasHuman(team)
    local players = GetTeamPlayers(team)
    if players == nil then return false end
    for i = 1, #players do
        if not IsPlayerBot(players[i]) then
            return true
        end
    end
    return false
end

-- Pick a synthetic objective location consistent with the strategy.
-- Uses the team's current strategy + simple game-state heuristics.
local function pickObjective(team)
    local enemyTeam = (team == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
    local now = DotaTime()

    -- Strategy lookup. If aba_draft_strategy isn't loaded for some reason,
    -- fall through to teamfight_mid defaults.
    local strategy = "teamfight_mid"
    pcall(function()
        if jmz.DraftStrategy and jmz.DraftStrategy.GetEffectiveStrategyName then
            strategy = jmz.DraftStrategy.GetEffectiveStrategyName() or strategy
        end
    end)

    -- Find the weakest enemy tower (frontmost still-alive)
    local function getWeakestEnemyTower()
        local towerOrder = {
            { TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1 },
            { TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2 },
            { TOWER_TOP_3, TOWER_MID_3, TOWER_BOT_3 },
            { TOWER_BASE_1, TOWER_BASE_2 },
        }
        for _, tier in ipairs(towerOrder) do
            for _, tid in ipairs(tier) do
                local t = GetTower(enemyTeam, tid)
                if t ~= nil and not t:IsNull() and t:IsAlive() then
                    return t
                end
            end
        end
        return nil
    end

    -- Frontmost OWN tower (for defensive ping)
    local function getFrontmostOwnTower()
        local towerOrder = {
            { TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1 },
            { TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2 },
            { TOWER_TOP_3, TOWER_MID_3, TOWER_BOT_3 },
        }
        for _, tier in ipairs(towerOrder) do
            for _, tid in ipairs(tier) do
                local t = GetTower(team, tid)
                if t ~= nil and not t:IsNull() and t:IsAlive() then
                    return t
                end
            end
        end
        return nil
    end

    -- Cycle index increments per refresh so we vary the objective and
    -- don't ping the same spot every time.
    local s = getTeamState(team)
    s.cycle_index = (s.cycle_index + 1) % 4

    -- Strategy-driven objective selection.
    if strategy == "early_aggro" or strategy == "fast_siege" then
        -- Prefer aggressive: enemy weakest tower
        local t = getWeakestEnemyTower()
        if t ~= nil then
            return t:GetLocation(), "push"
        end
    elseif strategy == "split_push" then
        -- Cycle: enemy tower (mostly), occasionally rosh
        if s.cycle_index == 0 and now > 12 * 60 then
            local roshLoc = jmz.GetCurrentRoshanLocation and jmz.GetCurrentRoshanLocation() or nil
            if roshLoc ~= nil then return roshLoc, "rosh" end
        end
        local t = getWeakestEnemyTower()
        if t ~= nil then return t:GetLocation(), "push" end
    elseif strategy == "teamfight_mid" then
        -- Cycle between rosh (mid game) and tower
        if (s.cycle_index == 0 or s.cycle_index == 2) and now > 14 * 60 then
            local roshLoc = jmz.GetCurrentRoshanLocation and jmz.GetCurrentRoshanLocation() or nil
            if roshLoc ~= nil then return roshLoc, "rosh" end
        end
        local t = getWeakestEnemyTower()
        if t ~= nil then return t:GetLocation(), "push" end
    elseif strategy == "late_scale" then
        -- Defensive: ping our own front tower until late game
        if now < 28 * 60 then
            local t = getFrontmostOwnTower()
            if t ~= nil then return t:GetLocation(), "defend" end
        else
            local t = getWeakestEnemyTower()
            if t ~= nil then return t:GetLocation(), "push" end
        end
    elseif strategy == "turtle_defensive" then
        -- Stay on defense unless big NW lead
        local t = getFrontmostOwnTower()
        if t ~= nil then return t:GetLocation(), "defend" end
    end

    -- Fallback: enemy weakest tower if nothing else fired
    local t = getWeakestEnemyTower()
    if t ~= nil then return t:GetLocation(), "push" end

    -- Final fallback: own front tower (defend)
    local own = getFrontmostOwnTower()
    if own ~= nil then return own:GetLocation(), "defend" end

    return nil, nil
end

-- Public: get a synthetic ping for the team if no human is on it.
-- Returns nil if a human is present (the real ping path takes over).
-- Otherwise returns a ping in the same shape as bot:GetMostRecentPing():
--   { location = Vector(...), time = DotaTime(), normal_ping = true }
function ____exports.Get(team)
    if team == nil then team = GetTeam() end
    if teamHasHuman(team) then
        return nil   -- humans drive their own pings
    end

    local now = DotaTime()
    local s = getTeamState(team)
    -- Only refresh every PING_REFRESH_SEC; reuse the cached ping otherwise so
    -- the team plan's 8-second recency window stays satisfied.
    if s.current_ping == nil
       or (now - s.last_refresh) > PING_REFRESH_SEC then
        local loc, kind = pickObjective(team)
        if loc == nil then return nil end
        s.current_ping = {
            location = loc,
            time = now,
            normal_ping = true,
            synthetic = true,    -- so consumers can distinguish if they care
            kind = kind,
        }
        s.last_refresh = now
    end

    -- Re-stamp the time so consumers see it as "fresh" within the recency
    -- window. Without this, after PING_REFRESH_SEC the cached ping would
    -- be stale (DEFAULT_PING_RECENCY = 8s < PING_REFRESH_SEC = 30s).
    s.current_ping.time = now
    return s.current_ping
end

-- Debug
function ____exports.Describe(team)
    if team == nil then team = GetTeam() end
    local s = _state[team]
    if s == nil then return "synthetic_ping: not initialised" end
    if s.current_ping == nil then return "synthetic_ping: no ping cached" end
    local loc = s.current_ping.location
    return string.format("synthetic_ping(team=%d): kind=%s loc=(%.0f,%.0f) age=%.1fs",
        team, s.current_ping.kind or "?", loc.x, loc.y,
        DotaTime() - s.last_refresh)
end

return ____exports
