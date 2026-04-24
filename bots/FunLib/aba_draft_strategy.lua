--[[ Draft-analyzed match strategy.

     At game start, analyzes both teams' heroes against scraped pro-match data
     (bots/FunLib/data/*.lua) and computes the optimal team strategy for OUR
     side, plus a read on the ENEMY's likely strategy.

     This REPLACES the random team_mood — instead of rolling dice each match,
     the strategy is grounded in what heroes are on the board.

     Exposed as J.DraftStrategy.*
     ]]
local ____exports = {}

-- Lazy-load jmz to avoid cycles.
local _jmz = nil
local function jmz()
    if _jmz == nil then
        _jmz = require(GetScriptDirectory().."/FunLib/jmz_func")
    end
    return _jmz
end

-- ============================================================
-- Data loading — pcall so missing data files don't break bots
-- ============================================================

local function tryLoad(path)
    local ok, m = pcall(require, path)
    if ok and m ~= nil then return m end
    return nil
end

local _archetypesMod  = tryLoad(GetScriptDirectory().."/FunLib/data/draft_archetypes")
local _spikesMod      = tryLoad(GetScriptDirectory().."/FunLib/data/hero_spikes")
local _statsMod       = tryLoad(GetScriptDirectory().."/FunLib/data/hero_stats")
local _matchupsMod    = tryLoad(GetScriptDirectory().."/FunLib/data/hero_matchups")

local ARCHETYPES = (_archetypesMod and _archetypesMod.HeroArchetypes) or {}
local SPIKES     = (_spikesMod and _spikesMod.HeroSpikes) or {}
local STATS      = (_statsMod and _statsMod.HeroStats) or {}
local MATCHUPS   = (_matchupsMod and _matchupsMod.HeroMatchups) or {}

local function dataAvailable()
    local n = 0
    for _ in pairs(ARCHETYPES) do n = n + 1; if n >= 10 then return true end end
    return false
end

-- ============================================================
-- Per-team archetype scoring
-- ============================================================

local function collectTeamHeroes(team)
    local names = {}
    local players = GetTeamPlayers(team)
    for i = 1, #players do
        local pid = players[i]
        local h = GetSelectedHeroName(pid)
        if h ~= nil and h ~= "" then
            table.insert(names, h)
        end
    end
    return names
end

-- Sum archetype scores across a team's heroes -> one total score per archetype.
local function scoreTeamArchetypes(heroNames)
    local totals = {
        pickoff = 0.0,
        teamfight = 0.0,
        split_push = 0.0,
        turtle_scale = 0.0,
        siege = 0.0,
        utility = 0.0,
    }
    for i = 1, #heroNames do
        local name = heroNames[i]
        local a = ARCHETYPES[name]
        if a ~= nil then
            for k, v in pairs(a) do
                totals[k] = (totals[k] or 0) + v
            end
        end
    end
    return totals
end

-- Count heroes by tempo (early / mid / late) for a team.
local function countTempoDistribution(heroNames)
    local dist = { early = 0, mid = 0, late = 0 }
    local coreCount = 0   -- carries/mids (whose tempo matters most for timing)
    local coreScaling = 0
    for i = 1, #heroNames do
        local name = heroNames[i]
        local s = SPIKES[name]
        if s ~= nil and s.tempo ~= nil then
            dist[s.tempo] = (dist[s.tempo] or 0) + 1
        end
        local st = STATS[name]
        if st ~= nil and st.roles ~= nil then
            for _, role in pairs(st.roles) do
                if role == "Carry" then
                    coreCount = coreCount + 1
                    if s and s.scaling_factor then
                        coreScaling = coreScaling + s.scaling_factor
                    end
                    break
                end
            end
        end
    end
    local avgCoreScaling = coreCount > 0 and (coreScaling / coreCount) or 1.0
    return dist, avgCoreScaling
end

-- ============================================================
-- Strategy classification
-- ============================================================

local STRATEGIES = {
    -- Each strategy has mood-style trait values (replaces aba_team_mood's random roll).
    -- Values are interpreted the same way as team_mood multipliers.
    early_aggro = {
        aggression     = 1.15,
        patience       = 0.85,
        coordination   = 1.05,
        rosh_eagerness = 1.05,
        gank_eagerness = 1.20,
        push_eagerness = 1.00,
        defensive_lean = 0.90,
        tempo          = "early",
    },
    teamfight_mid = {
        aggression     = 1.10,
        patience       = 0.95,
        coordination   = 1.15,
        rosh_eagerness = 1.15,
        gank_eagerness = 1.05,
        push_eagerness = 1.05,
        defensive_lean = 1.00,
        tempo          = "mid",
    },
    late_scale = {
        aggression     = 0.90,
        patience       = 1.15,
        coordination   = 1.05,
        rosh_eagerness = 0.90,
        gank_eagerness = 0.85,
        push_eagerness = 0.85,
        defensive_lean = 1.15,
        tempo          = "late",
    },
    split_push = {
        aggression     = 0.95,
        patience       = 1.00,
        coordination   = 0.85,  -- bots go off on their own
        rosh_eagerness = 0.95,
        gank_eagerness = 0.95,
        push_eagerness = 1.15,
        defensive_lean = 0.95,
        tempo          = "mid",
    },
    fast_siege = {
        aggression     = 1.05,
        patience       = 0.90,
        coordination   = 1.15,
        rosh_eagerness = 0.95,
        gank_eagerness = 0.95,
        push_eagerness = 1.20,
        defensive_lean = 0.95,
        tempo          = "early",
    },
    turtle_defensive = {
        aggression     = 0.85,
        patience       = 1.15,
        coordination   = 1.10,
        rosh_eagerness = 0.85,
        gank_eagerness = 0.85,
        push_eagerness = 0.85,
        defensive_lean = 1.20,
        tempo          = "late",
    },
}

-- ============================================================
-- Pick strategy from archetype + tempo profile
-- ============================================================

local function pickStrategy(archetypeTotals, tempoDist, avgCoreScaling)
    -- Find the dominant archetype
    local top = nil
    local topScore = -1
    for k, v in pairs(archetypeTotals) do
        if v > topScore then
            topScore = v
            top = k
        end
    end

    local earlyHeroes = tempoDist.early or 0
    local lateHeroes = tempoDist.late or 0

    -- Mapping dominant archetype + tempo -> strategy key
    -- Priority: very-late-scaling carry team trumps other signals
    if avgCoreScaling >= 1.25 and lateHeroes >= earlyHeroes then
        return "late_scale"
    end
    if avgCoreScaling <= 0.90 and earlyHeroes >= lateHeroes then
        return "early_aggro"
    end

    if top == "pickoff" then
        -- Pickoff + early tempo = early aggro; otherwise mid ganks
        if earlyHeroes >= 2 then return "early_aggro" end
        return "teamfight_mid"  -- pickoff + mid tempo is roam+fight
    end
    if top == "teamfight" then
        return "teamfight_mid"
    end
    if top == "split_push" then
        return "split_push"
    end
    if top == "siege" then
        return "fast_siege"
    end
    if top == "turtle_scale" then
        -- Turtle-leaning draft + late carries -> late_scale
        if lateHeroes >= 2 then return "late_scale" end
        return "turtle_defensive"
    end
    if top == "utility" then
        -- Heavy utility draft usually supports a scaling carry
        if lateHeroes >= earlyHeroes then return "late_scale" end
        return "teamfight_mid"
    end

    -- Default fallback
    return "teamfight_mid"
end

-- ============================================================
-- Lazy one-shot analysis (per match)
-- ============================================================

local _analyzed = nil

local function analyzeDraft()
    if _analyzed ~= nil then return _analyzed end
    -- Don't analyze until heroes are picked
    local myTeam = GetTeam()
    local enemyTeam = GetOpposingTeam()
    local myHeroes = collectTeamHeroes(myTeam)
    local enemyHeroes = collectTeamHeroes(enemyTeam)
    -- Need at least 3 heroes picked on each side before we draw conclusions
    if #myHeroes < 3 or #enemyHeroes < 3 then return nil end

    -- If data didn't load, return a neutral analysis so we don't break things
    if not dataAvailable() then
        _analyzed = {
            strategy = "teamfight_mid",
            strategy_values = STRATEGIES.teamfight_mid,
            my_archetypes = {},
            enemy_archetypes = {},
            my_tempo = {},
            enemy_tempo = {},
            data_loaded = false,
            reason = "no data files — falling back to teamfight_mid",
        }
        return _analyzed
    end

    local myArch = scoreTeamArchetypes(myHeroes)
    local enemyArch = scoreTeamArchetypes(enemyHeroes)
    local myTempo, myAvgScaling = countTempoDistribution(myHeroes)
    local enemyTempo, _ = countTempoDistribution(enemyHeroes)

    -- Pick our strategy based on our draft + tempo
    local strategyKey = pickStrategy(myArch, myTempo, myAvgScaling)

    -- Adjust if enemy has a SPECIFIC threat — e.g., enemy is late_scale
    -- = we should push before their carry online.
    local enemyStrategyKey = pickStrategy(enemyArch, enemyTempo, myAvgScaling)  -- rough read
    if enemyStrategyKey == "late_scale" and strategyKey ~= "late_scale" then
        -- Bias our play earlier to punish before enemy carry comes online
        -- (keep our strategy but boost push/gank eagerness)
        local s = {}
        for k, v in pairs(STRATEGIES[strategyKey]) do s[k] = v end
        if type(s.push_eagerness) == "number" then s.push_eagerness = s.push_eagerness * 1.05 end
        if type(s.gank_eagerness) == "number" then s.gank_eagerness = s.gank_eagerness * 1.05 end
        _analyzed = {
            strategy = strategyKey,
            strategy_values = s,
            my_archetypes = myArch,
            enemy_archetypes = enemyArch,
            my_tempo = myTempo,
            enemy_tempo = enemyTempo,
            enemy_strategy = enemyStrategyKey,
            data_loaded = true,
            reason = "punish before enemy " .. enemyStrategyKey,
        }
        return _analyzed
    end

    _analyzed = {
        strategy = strategyKey,
        strategy_values = STRATEGIES[strategyKey],
        my_archetypes = myArch,
        enemy_archetypes = enemyArch,
        my_tempo = myTempo,
        enemy_tempo = enemyTempo,
        enemy_strategy = enemyStrategyKey,
        data_loaded = true,
    }
    return _analyzed
end

-- ============================================================
-- Public API
-- ============================================================

function ____exports.GetStrategy()
    return analyzeDraft()
end

function ____exports.GetStrategyName()
    local a = analyzeDraft()
    return a and a.strategy or "teamfight_mid"
end

-- Returns the mood-style multipliers for the current strategy.
-- Used by aba_personality ModulateDesire as a drop-in replacement for
-- J.TeamMood.GetMoodMultiplier.
function ____exports.GetStrategyValues()
    local a = analyzeDraft()
    return (a and a.strategy_values) or STRATEGIES.teamfight_mid
end

-- Read the enemy's strategy — lets team-plan anticipate enemy plays.
function ____exports.GetEnemyStrategy()
    local a = analyzeDraft()
    return a and a.enemy_strategy or "teamfight_mid"
end

-- ============================================================
-- Matchup lookup — who beats who. Used by focus scoring later.
-- ============================================================

function ____exports.GetMatchupWinrate(myHeroName, enemyHeroName)
    local row = MATCHUPS[myHeroName]
    if row == nil then return nil end
    return row[enemyHeroName]
end

-- ============================================================
-- Hero spike introspection
-- ============================================================

function ____exports.GetSpike(heroName)
    return SPIKES[heroName]
end

-- Returns true if the given game time is within this hero's spike window.
function ____exports.IsInSpikeWindow(heroName, dotaTimeSeconds)
    local s = SPIKES[heroName]
    if s == nil then return false end
    local startS = (s.spike_window_start_min or 0) * 60
    local endS = (s.spike_window_end_min or 0) * 60
    return dotaTimeSeconds >= startS and dotaTimeSeconds <= endS
end

-- Returns "pre", "in", "post" for where this hero is relative to their spike.
function ____exports.GetSpikeState(heroName, dotaTimeSeconds)
    local s = SPIKES[heroName]
    if s == nil then return "mid" end
    local startS = (s.spike_window_start_min or 0) * 60
    local endS = (s.spike_window_end_min or 0) * 60
    if dotaTimeSeconds < startS then return "pre" end
    if dotaTimeSeconds > endS then return "post" end
    return "in"
end

-- ============================================================
-- Debug
-- ============================================================

function ____exports.Describe()
    local a = analyzeDraft()
    if a == nil then return "not analyzed yet" end
    if not a.data_loaded then return "no data loaded — using fallback " .. a.strategy end
    local parts = { a.strategy }
    if a.enemy_strategy then table.insert(parts, "vs " .. a.enemy_strategy) end
    if a.reason then table.insert(parts, "(" .. a.reason .. ")") end
    local tempo = a.my_tempo or {}
    local et = a.enemy_tempo or {}
    local tempoStr = string.format("my=%dE/%dM/%dL enemy=%dE/%dM/%dL",
        tempo.early or 0, tempo.mid or 0, tempo.late or 0,
        et.early or 0, et.mid or 0, et.late or 0)
    table.insert(parts, tempoStr)
    return table.concat(parts, " | ")
end

return ____exports
