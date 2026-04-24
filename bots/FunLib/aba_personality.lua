--[[ Hand-written to match typescript/bots/FunLib/aba_personality.ts.
     TSTL will regenerate this file when `npm run build` runs against the TS source.
     Keep both in sync. See ARCHITECTURE.md section 13 for the TS/Lua split. ]]
local ____exports = {}
local ____archetypes = require(GetScriptDirectory().."/FunLib/aba_hero_archetypes")
local GetArchetype = ____archetypes.GetArchetype

-- Module-scope state
local fretBotsActive = false

-- Lazy-loaded team plan module (avoids require cycle: jmz -> personality -> teamplan -> jmz).
-- Resolved on first ModulateDesire call.
local _teamPlanModule = nil
local _teamPlanTried = false
local function getTeamPlan()
    if _teamPlanTried then return _teamPlanModule end
    _teamPlanTried = true
    local ok, tp = pcall(require, GetScriptDirectory().."/FunLib/aba_teamplan")
    if ok and tp ~= nil then _teamPlanModule = tp end
    return _teamPlanModule
end

-- Lazy-loaded jmz_func (needed for J.GetPosition in role-aware scaling).
local _jmz = nil
local function getJmz()
    if _jmz == nil then
        local ok, j = pcall(require, GetScriptDirectory().."/FunLib/jmz_func")
        if ok then _jmz = j end
    end
    return _jmz
end

-- Lazy-loaded game theory module.
local _gt = nil
local function getGameTheory()
    if _gt == nil then
        local ok, g = pcall(require, GetScriptDirectory().."/FunLib/aba_gametheory")
        if ok then _gt = g end
    end
    return _gt
end

-- Constants
local NOISE_STDDEV = 0.12
local TILT_UPDATE_INTERVAL = 3.0
local TILT_DECAY_PER_SEC = 0.005
local TILT_PER_DEATH = 0.12
local TILT_PER_KILL_REDUCTION = 0.08

-- Mode modifiers: for each mode, how traits scale desire.
-- Each entry: {trait, atZero, atOne} — linear interp [0..1] -> [atZero..atOne].
local MODE_MODIFIERS = {
    farm = {
        { trait = "greed", atZero = 0.75, atOne = 1.3 },
        { trait = "teamSpirit", atZero = 1.1, atOne = 0.85 },
    },
    roam = {
        { trait = "aggression", atZero = 0.6, atOne = 1.35 },
        { trait = "greed", atZero = 1.1, atOne = 0.8 },
        { trait = "independence", atZero = 0.85, atOne = 1.15 },
    },
    team_roam = {
        { trait = "aggression", atZero = 0.7, atOne = 1.25 },
        { trait = "teamSpirit", atZero = 0.55, atOne = 1.3 },
        { trait = "independence", atZero = 1.2, atOne = 0.7 },
    },
    push = {
        { trait = "aggression", atZero = 0.8, atOne = 1.2 },
        { trait = "independence", atZero = 0.85, atOne = 1.25 },
    },
    defend = {
        { trait = "teamSpirit", atZero = 0.7, atOne = 1.3 },
        { trait = "risk", atZero = 1.15, atOne = 0.9 },
    },
    retreat = {
        { trait = "risk", atZero = 1.3, atOne = 0.7 },
    },
    rune = {
        { trait = "greed", atZero = 0.9, atOne = 1.15 },
        { trait = "independence", atZero = 0.9, atOne = 1.1 },
    },
    roshan = {
        { trait = "aggression", atZero = 0.85, atOne = 1.2 },
        { trait = "risk", atZero = 0.9, atOne = 1.15 },
        { trait = "teamSpirit", atZero = 0.9, atOne = 1.1 },
    },
    ward = {
        { trait = "teamSpirit", atZero = 0.8, atOne = 1.2 },
    },
    laning = {
        { trait = "greed", atZero = 0.95, atOne = 1.1 },
        { trait = "aggression", atZero = 0.95, atOne = 1.1 },
    },
    assemble = {
        { trait = "teamSpirit", atZero = 0.65, atOne = 1.25 },
        { trait = "independence", atZero = 1.25, atOne = 0.8 },
    },
}

-- Helpers
local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Irwin-Hall sum-of-uniforms approximation; ~N(0, ~stddev)
local function noise(stddev)
    local u = RandomFloat(0, 1) + RandomFloat(0, 1) - 1
    return u * stddev * 1.73
end

local function applyNoiseTo(value, stddev)
    return clamp01(value + noise(stddev))
end

local function rollPersonalityFromArchetype(archetype, seed)
    return {
        aggression = applyNoiseTo(archetype.aggression, NOISE_STDDEV),
        greed = applyNoiseTo(archetype.greed, NOISE_STDDEV),
        risk = applyNoiseTo(archetype.risk, NOISE_STDDEV),
        independence = applyNoiseTo(archetype.independence, NOISE_STDDEV),
        teamSpirit = applyNoiseTo(archetype.teamSpirit, NOISE_STDDEV),
        tilt = 0,
        tiltSensitivity = archetype.tiltSensitivity,
        archetypeName = archetype.name,
        seed = seed,
        _initialized = true,
        _lastTiltUpdate = 0,
        _lastDeaths = 0,
        _lastKills = 0,
    }
end

local function makeEmpty()
    return {
        aggression = 0.5,
        greed = 0.5,
        risk = 0.5,
        independence = 0.5,
        teamSpirit = 0.5,
        tilt = 0,
        tiltSensitivity = 0.5,
        archetypeName = "default",
        seed = 0,
        _initialized = false,
        _lastTiltUpdate = 0,
        _lastDeaths = 0,
        _lastKills = 0,
    }
end

-- Get (or lazily init) the personality stored on the bot object.
function ____exports.Get(bot)
    if bot == nil then return makeEmpty() end
    if bot._personality ~= nil and bot._personality._initialized then
        return bot._personality
    end
    local ok, heroName = pcall(function() return bot:GetUnitName() end)
    if not ok or heroName == nil then heroName = "" end
    local archetype = GetArchetype(heroName)
    local seedPlayerID = 0
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    if okPid and pid ~= nil then seedPlayerID = pid end
    local seed = seedPlayerID * 31 + RandomInt(1, 1000000)
    local p = rollPersonalityFromArchetype(archetype, seed)
    bot._personality = p
    return p
end

-- Refresh tilt based on deaths/kills since last update. Has internal rate limiter
-- (every TILT_UPDATE_INTERVAL seconds) so can be called from hot paths safely.
function ____exports.UpdateTilt(bot)
    if bot == nil then return end
    local p = ____exports.Get(bot)
    local now = DotaTime()
    local dt = now - p._lastTiltUpdate
    if dt < TILT_UPDATE_INTERVAL then return end

    local okD, deaths = pcall(function() return bot:GetDeaths() end)
    local okK, kills  = pcall(function() return bot:GetKills() end)
    if not okD then deaths = p._lastDeaths end
    if not okK then kills = p._lastKills end

    local newDeaths = deaths - p._lastDeaths
    local newKills = kills - p._lastKills

    if newDeaths > 0 then
        p.tilt = clamp01(p.tilt + TILT_PER_DEATH * newDeaths)
    end
    if newKills > 0 then
        p.tilt = clamp01(p.tilt - TILT_PER_KILL_REDUCTION * newKills)
    end
    -- Natural decay so bad stretches don't stick forever
    p.tilt = clamp01(p.tilt - TILT_DECAY_PER_SEC * dt)

    p._lastDeaths = deaths
    p._lastKills = kills
    p._lastTiltUpdate = now
end

function ____exports.BumpTilt(bot, amount)
    if bot == nil then return end
    local p = ____exports.Get(bot)
    p.tilt = clamp01(p.tilt + amount)
end

-- Effective traits = base + tilt-driven shifts. FretBots mode amplifies tilt.
function ____exports.GetEffective(bot)
    local p = ____exports.Get(bot)
    local fretMul = fretBotsActive and 1.4 or 1.0
    local shift = p.tilt * p.tiltSensitivity * 0.35 * fretMul
    return {
        aggression = clamp01(p.aggression + shift),
        greed = clamp01(p.greed - shift * 0.4),
        risk = clamp01(p.risk + shift),
        independence = clamp01(p.independence + shift * 0.3),
        teamSpirit = clamp01(p.teamSpirit - shift * 0.7),
        tilt = p.tilt,
        tiltSensitivity = p.tiltSensitivity,
        archetypeName = p.archetypeName,
        seed = p.seed,
        _initialized = true,
        _lastTiltUpdate = p._lastTiltUpdate,
        _lastDeaths = p._lastDeaths,
        _lastKills = p._lastKills,
    }
end

local function computeMultiplier(mode, p)
    local mods = MODE_MODIFIERS[mode]
    if mods == nil then return 1.0 end
    local mult = 1.0
    for i = 1, #mods do
        local m = mods[i]
        local traitValue = p[m.trait]
        if type(traitValue) == "number" then
            mult = mult * lerp(m.atZero, m.atOne, traitValue)
        end
    end
    return mult
end

-- Per-role farm scaling (pro-match style: carry gets most farm, supports least).
-- Applied on top of personality greed to produce sensibly wide gaps.
-- Pos 1 and 2 cores farm harder; pos 4 and 5 supports farm much less
-- (frees them for roam / ward / stack).
local FARM_ROLE_SCALE = {
    [1] = 1.20,
    [2] = 1.10,
    [3] = 0.85,
    [4] = 0.50,
    [5] = 0.45,
}

-- Push/team_roam can also be slightly role-weighted: supports lead initiations,
-- cores follow up. But we keep it mild.
local ROAM_ROLE_SCALE = {
    [1] = 0.90,
    [2] = 1.00,
    [3] = 1.00,
    [4] = 1.15,
    [5] = 1.10,
}

local function applyRoleScale(mode, bot, desire)
    -- Protected access because J.Role may not be fully loaded during very early ticks.
    local J = getJmz()
    if J == nil or J.GetPosition == nil then return desire end
    local ok, pos = pcall(function() return J.GetPosition(bot) end)
    if not ok or pos == nil then return desire end
    if mode == "farm" and FARM_ROLE_SCALE[pos] then
        return desire * FARM_ROLE_SCALE[pos]
    elseif (mode == "roam" or mode == "team_roam") and ROAM_ROLE_SCALE[pos] then
        return desire * ROAM_ROLE_SCALE[pos]
    end
    return desire
end

-- Multiply a mode desire by the bot's personality factor. Self-updates tilt.
-- Also applies team-plan bias if the team plan module is available.
-- Zero/negative desires pass through unchanged (gates stay as gates).
function ____exports.ModulateDesire(bot, desire, mode)
    if bot == nil or desire == nil then return desire end
    if type(desire) ~= "number" then return desire end
    if desire <= 0 then return desire end
    ____exports.UpdateTilt(bot)

    -- Periodic debug hook (gated by Customize.Debug; 30s rate-limit inside)
    local J = getJmz()
    if J ~= nil and J.DebugPeriodic ~= nil then
        pcall(function() J.DebugPeriodic() end)
    end

    local p = ____exports.GetEffective(bot)

    -- Apply team-plan bias first (team strategy layer)
    local tp = getTeamPlan()
    if tp ~= nil then
        tp.MaybeRecompute(bot)
        local planMult = tp.GetPlanBias(bot, mode, p.teamSpirit)
        desire = desire * planMult
    end

    -- Then personality multiplier (individual variance on top of team strategy)
    local mult = computeMultiplier(mode, p)
    desire = desire * mult

    -- Role-based scaling (pro-match farm priority)
    desire = applyRoleScale(mode, bot, desire)

    -- Game-theory pressure bias (aggressive when ahead, safer when behind)
    local gt = getGameTheory()
    if gt ~= nil then
        local okBias, bias = pcall(function() return gt.GetPressureBias(mode) end)
        if okBias and type(bias) == "number" then
            desire = desire * bias
        end
    end

    -- Per-match team mood — adds chaos so each game feels different.
    -- Multiplies on top of everything else so the game-state-aware signals
    -- still dominate, but the match flavor leaves a fingerprint.
    local J = getJmz()
    if J ~= nil and J.TeamMood ~= nil then
        local okMM, moodMult = pcall(function() return J.TeamMood.GetMoodMultiplier(mode) end)
        if okMM and type(moodMult) == "number" then
            desire = desire * moodMult
        end
    end

    return desire
end

function ____exports.GetMultiplier(bot, mode)
    if bot == nil then return 1.0 end
    local p = ____exports.GetEffective(bot)
    return computeMultiplier(mode, p)
end

function ____exports.SetFretBotsMode(active)
    fretBotsActive = active
end

function ____exports.IsFretBotsMode()
    return fretBotsActive
end

-- Draft: roll a target profile for a slot, used as the affinity target for hero scoring
function ____exports.RollSlotProfile()
    return {
        aggression = RandomFloat(0.2, 0.8),
        greed = RandomFloat(0.2, 0.8),
        risk = RandomFloat(0.2, 0.8),
        independence = RandomFloat(0.2, 0.8),
        teamSpirit = RandomFloat(0.2, 0.8),
    }
end

-- [0..1] match between a hero's archetype and a slot profile
function ____exports.GetDraftAffinity(heroName, profile)
    if profile == nil then return 0.5 end
    local archetype = GetArchetype(heroName)
    local d = math.abs(profile.aggression - archetype.aggression)
        + math.abs(profile.greed - archetype.greed)
        + math.abs(profile.risk - archetype.risk)
        + math.abs(profile.independence - archetype.independence)
        + math.abs(profile.teamSpirit - archetype.teamSpirit)
    return clamp01(1 - (d / 5))
end

-- Debug string
function ____exports.Describe(bot)
    local p = ____exports.GetEffective(bot)
    return p.archetypeName
        .. " | agg=" .. string.format("%.2f", p.aggression)
        .. " grd=" .. string.format("%.2f", p.greed)
        .. " rsk=" .. string.format("%.2f", p.risk)
        .. " ind=" .. string.format("%.2f", p.independence)
        .. " tms=" .. string.format("%.2f", p.teamSpirit)
        .. " tilt=" .. string.format("%.2f", p.tilt)
end

return ____exports
