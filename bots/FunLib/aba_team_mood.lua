--[[ Per-match team mood / strategic flavor.

     Rolled ONCE per match at first access. Exposes a set of mood-influenced
     multipliers that bias mode desires team-wide so:
       * Same draft plays differently across matches
       * Some games have aggressive early teams, others late-game scaling
       * Some teams obsess over rosh, others ignore it
       * Some teams smoke-gank constantly, others farm patiently

     Combined with per-bot personality (individual variance), opening flavor
     (early-game bias), and game theory pressure (state-driven), each match
     should feel meaningfully different.

     Exposed as J.TeamMood.*
     ]]
local ____exports = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- ============================================================
-- Roll once per match
-- ============================================================

local mood = nil

local function rollMood()
    -- Each axis is sampled independently; combinations create distinctive
    -- team flavors (e.g. high aggression + low patience + early tempo
    -- = "early-game gank squad"; low aggression + high patience + late tempo
    -- = "late-game scaling carry team").
    -- Magnitudes deliberately moderate — user feedback "patch is much worse"
    -- after I bumped them too high. Target: each axis swings ~15% above/below
    -- baseline. Combined stack stays well within the ModulateDesire envelope.
    local m = {
        aggression     = clamp(0.85 + RandomFloat(0, 0.30), 0.85, 1.15),
        patience       = clamp(0.85 + RandomFloat(0, 0.30), 0.85, 1.15),
        coordination   = clamp(0.90 + RandomFloat(0, 0.20), 0.90, 1.10),
        rosh_eagerness = clamp(0.80 + RandomFloat(0, 0.40), 0.80, 1.20),
        gank_eagerness = clamp(0.85 + RandomFloat(0, 0.30), 0.85, 1.15),
        push_eagerness = clamp(0.85 + RandomFloat(0, 0.30), 0.85, 1.15),
        defensive_lean = clamp(0.90 + RandomFloat(0, 0.20), 0.90, 1.10),
    }

    -- Tempo: weighted random
    local t = RandomInt(1, 100)
    if t <= 30 then m.tempo = "early"
    elseif t <= 65 then m.tempo = "mid"
    else m.tempo = "late" end

    -- Theme — derived from axes for debug readability
    local parts = {}
    if m.aggression >= 1.15 then table.insert(parts, "aggro")
    elseif m.aggression <= 0.85 then table.insert(parts, "passive") end
    if m.patience >= 1.15 then table.insert(parts, "farm-heavy")
    elseif m.patience <= 0.85 then table.insert(parts, "fighty") end
    if m.coordination >= 1.15 then table.insert(parts, "coordinated")
    elseif m.coordination <= 0.85 then table.insert(parts, "loose") end
    if m.rosh_eagerness >= 1.15 then table.insert(parts, "rosh-hungry") end
    if m.push_eagerness >= 1.15 then table.insert(parts, "siege") end
    table.insert(parts, m.tempo)
    m.theme = #parts > 0 and table.concat(parts, "+") or "balanced"
    return m
end

local function getMood()
    if mood == nil then mood = rollMood() end
    return mood
end

function ____exports.Get()
    return getMood()
end

-- ============================================================
-- Per-mode multiplier applied at the end of ModulateDesire
--
-- Returns a small mood-driven multiplier (typically 0.7-1.3x).
-- Compounds with personality + team-plan + pressure but stays modest.
-- ============================================================

function ____exports.GetMoodMultiplier(mode)
    local m = getMood()
    local result = 1.0
    if mode == "farm" then
        result = m.patience
    elseif mode == "roam" or mode == "team_roam" then
        -- Two-axis compound; clamp to documented envelope
        result = m.aggression * m.gank_eagerness
    elseif mode == "push" then
        result = m.push_eagerness
    elseif mode == "defend" then
        result = m.defensive_lean
    elseif mode == "retreat" then
        result = m.defensive_lean
    elseif mode == "roshan" then
        result = m.rosh_eagerness
    elseif mode == "assemble" then
        result = m.coordination
    elseif mode == "laning" then
        if m.tempo == "early" then result = 0.9
        elseif m.tempo == "late" then result = 1.1 end
    end
    -- Tightened envelope after user feedback. Mood is supposed to be a
    -- gentle nudge, not a strong signal — game state and personality
    -- should dominate.
    if result < 0.80 then result = 0.80 end
    if result > 1.20 then result = 1.20 end
    return result
end

-- ============================================================
-- Team-spirit multiplier — applied to per-bot teamSpirit so highly-
-- coordinated mood teams have stronger team-plan compliance.
-- ============================================================

function ____exports.GetCoordinationMultiplier()
    return getMood().coordination
end

-- ============================================================
-- Threshold modifier — let aggressive mood teams commit easier.
-- Returns adjustment to commit_kill ally threshold (negative = looser).
-- ============================================================

function ____exports.GetThresholdAdjust()
    local m = getMood()
    local commitAdj = 0
    if m.aggression >= 1.20 and m.gank_eagerness >= 1.20 then commitAdj = -1 end  -- 1 ally enough
    if m.aggression <= 0.85 then commitAdj = 1 end  -- need more confidence
    return {
        commit = commitAdj,
        push = (m.push_eagerness >= 1.20 and -1) or 0,
        rosh = (m.rosh_eagerness >= 1.20 and -1) or 0,
    }
end

-- ============================================================
-- Debug
-- ============================================================

function ____exports.Describe()
    local m = getMood()
    return string.format("%s [agg=%.2f pat=%.2f coord=%.2f rosh=%.2f gank=%.2f push=%.2f tempo=%s]",
        m.theme, m.aggression, m.patience, m.coordination,
        m.rosh_eagerness, m.gank_eagerness, m.push_eagerness, m.tempo)
end

return ____exports
