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
local _benchmarksMod  = tryLoad(GetScriptDirectory().."/FunLib/data/hero_benchmarks")
local _proMacroMod    = tryLoad(GetScriptDirectory().."/FunLib/data/pro_macro")

local ARCHETYPES = (_archetypesMod and _archetypesMod.HeroArchetypes) or {}
local SPIKES     = (_spikesMod and _spikesMod.HeroSpikes) or {}
local STATS      = (_statsMod and _statsMod.HeroStats) or {}
local MATCHUPS   = (_matchupsMod and _matchupsMod.HeroMatchups) or {}
local BENCHMARKS = (_benchmarksMod and _benchmarksMod.HeroBenchmarks) or {}
local PRO_MACRO  = (_proMacroMod and _proMacroMod.ProMacro) or {}

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
    -- Find the dominant archetype.
    -- If ALL totals are 0 (e.g., every hero on the board is unknown to our
    -- scraped data — new patch hero, scraper stale), don't pick a random one
    -- from pairs()-order. Fall through to the default strategy.
    local top = nil
    local topScore = 0   -- require > 0 to actually select; avoids non-deterministic pairs() winner on all-zero data
    for k, v in pairs(archetypeTotals) do
        if v > topScore then
            topScore = v
            top = k
        end
    end
    if top == nil then
        return "teamfight_mid"  -- safe default
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
-- Live game state adjustments (Phase 6)
--
-- Draft analysis runs once. But mid-game state shifts: falling behind
-- on networth, losing towers, comebacks. Strategy should adapt.
-- This re-runs every N seconds and may override the draft baseline.
-- ============================================================

local RECOMPUTE_INTERVAL = 90   -- every 90s (not so often that bots flip)
local _lastLiveEval = -999
local _liveStrategyOverride = nil   -- nil = use draft baseline

local function computeLiveOverride()
    local J = jmz()
    if J == nil then return nil end

    local okNW, myNW, enemyNW = pcall(function() return J.GetInventoryNetworth() end)
    if not okNW or myNW == nil or enemyNW == nil then return nil end
    local nwDelta = myNW - enemyNW

    local now = DotaTime()

    -- Massive gold lead mid-late game: switch to siege
    if nwDelta >= 20000 and now > 15 * 60 then
        return "fast_siege", "NW lead " .. tostring(math.floor(nwDelta / 1000)) .. "k"
    end

    -- Falling behind badly: turtle and scale
    if nwDelta <= -15000 and now > 15 * 60 then
        return "turtle_defensive", "NW behind " .. tostring(math.floor(-nwDelta / 1000)) .. "k"
    end

    -- Way behind early: play defensive
    if nwDelta <= -8000 and now < 20 * 60 then
        return "turtle_defensive", "early NW behind"
    end

    -- Tower-state-driven escalation. Wrapped in pcall because GetTower/GetBarracks
    -- can throw if invoked at unusual game states (early init, lobby load).
    local towerOverride, towerReason = nil, nil
    pcall(function()
        local team = GetTeam()
        local enemyTeam = GetOpposingTeam()
        local function towersDown(t)
            local n = 0
            for _, tid in pairs({TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1,
                                 TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2}) do
                local tw = GetTower(t, tid)
                if tw == nil or tw:IsNull() or not tw:IsAlive() then n = n + 1 end
            end
            return n
        end
        local enemyT12Down = towersDown(enemyTeam)
        local ourT12Down = towersDown(team)
        if nwDelta >= 6000 and enemyT12Down >= 3 and now > 18 * 60 then
            towerOverride, towerReason = "fast_siege", "lead+enemy 3 T1/T2 down"
        elseif nwDelta <= -6000 and ourT12Down >= 3 then
            towerOverride, towerReason = "turtle_defensive", "behind+3 own towers down"
        end
    end)
    if towerOverride then return towerOverride, towerReason end

    -- Late game and ~even: switched from late_scale (which dampened pushes)
    -- to teamfight_mid (rosh + commit_kill tempo).
    if now > 30 * 60 and math.abs(nwDelta) < 10000 then
        return "teamfight_mid", "late-game even, teamfight tempo"
    end

    -- Very late game (45min+) with stalled NW: late_scale for buyback war.
    if now > 45 * 60 and math.abs(nwDelta) < 5000 then
        return "late_scale", "ultra-late stalled"
    end

    return nil
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
--
-- Now includes Phase-6 live override: if game state strongly signals
-- a shift (20k NW lead -> siege, 15k behind -> turtle), use the override.
function ____exports.GetStrategyValues()
    local a = analyzeDraft()
    local base = (a and a.strategy_values) or STRATEGIES.teamfight_mid

    -- Refresh live override on interval
    local now = DotaTime()
    if now - _lastLiveEval >= RECOMPUTE_INTERVAL then
        _lastLiveEval = now
        local override, reason = computeLiveOverride()
        if override ~= nil and STRATEGIES[override] ~= nil then
            _liveStrategyOverride = { key = override, values = STRATEGIES[override], reason = reason }
        else
            _liveStrategyOverride = nil
        end
    end

    if _liveStrategyOverride ~= nil then
        return _liveStrategyOverride.values
    end
    return base
end

-- Current effective strategy key (draft OR live override)
function ____exports.GetEffectiveStrategyName()
    local _ = ____exports.GetStrategyValues()  -- refresh live override
    if _liveStrategyOverride ~= nil then
        return _liveStrategyOverride.key
    end
    local a = analyzeDraft()
    return a and a.strategy or "teamfight_mid"
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

-- Per-hero percentile benchmarks — { gpm_p50, gpm_p75, gpm_p95, xpm_p50, ... }
function ____exports.GetBenchmark(heroName)
    return BENCHMARKS[heroName]
end

-- Pro-match macro timings (first rosh time, first T1 fall, etc.)
function ____exports.GetProMacro()
    return PRO_MACRO
end

-- Phase 5: compare bot's current gold/min to its hero's percentile benchmarks.
-- Returns a farm-pace multiplier:
--   >1.0 = below p50 (farm harder)
--   =1.0 = around p50
--   <1.0 = at or above p75 (on track, don't over-farm)
function ____exports.GetFarmPaceMultiplier(bot)
    if bot == nil then return 1.0 end
    local J = jmz()
    if J == nil then return 1.0 end
    local okN, heroName = pcall(function() return bot:GetUnitName() end)
    if not okN or type(heroName) ~= "string" then return 1.0 end
    local bm = BENCHMARKS[heroName]
    if bm == nil or bm.gpm_p50 == nil then return 1.0 end

    -- Bot's current GPM estimate. Dota API: bot:GetNetWorth() / GameTime_in_min
    local okNW, nw = pcall(function() return bot:GetNetWorth() end)
    if not okNW or nw == nil then return 1.0 end
    local t = DotaTime()
    if t < 60 then return 1.0 end  -- too early to compare
    local currentGPM = nw * 60 / t

    local p50 = bm.gpm_p50 or 400
    local p75 = bm.gpm_p75 or (p50 * 1.15)

    if currentGPM < p50 * 0.85 then
        return 1.12   -- way below — farm harder
    elseif currentGPM < p50 then
        return 1.06   -- slightly below
    elseif currentGPM > p75 then
        return 0.94   -- ahead of pace — can commit more
    end
    return 1.0
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

-- Phase 11 Item 6: dynamic NW-relative spike windows. Replaces static
-- per-hero spike windows with a NW-pace-shifted version. A fed Anti-Mage
-- (1.5x p50 GPM) spikes ~33% earlier than the static window says; a
-- starved one spikes ~67% later. Clamped to [0.5x, 1.6x] so wild swings
-- can't push the spike to minute-5 or to never.
function ____exports.GetDynamicSpikeState(bot, dotaTimeSeconds)
    if bot == nil then return "mid", 0 end
    local okN, heroName = pcall(function() return bot:GetUnitName() end)
    if not okN or type(heroName) ~= "string" then return "mid", 0 end
    local s = SPIKES[heroName]
    local bm = BENCHMARKS[heroName]
    if s == nil then return "mid", 0 end

    local startMin = s.spike_window_start_min or 0
    local endMin = s.spike_window_end_min or 0
    local centerMin = (startMin + endMin) / 2

    local nw_ratio = 1.0
    if bm and bm.gpm_p50 and dotaTimeSeconds > 60 then
        local okNW, nw = pcall(function() return bot:GetNetWorth() end)
        if okNW and nw then
            local currentGPM = nw * 60 / dotaTimeSeconds
            nw_ratio = currentGPM / math.max(1, bm.gpm_p50)
        end
    end
    if nw_ratio < 0.5 then nw_ratio = 0.5 end
    if nw_ratio > 1.6 then nw_ratio = 1.6 end

    local effective_center_min = centerMin / nw_ratio
    local effective_start = effective_center_min - (centerMin - startMin)
    local effective_end = effective_center_min + (endMin - centerMin)

    local nowMin = dotaTimeSeconds / 60
    if nowMin < effective_start then
        return "pre", math.max(0, 1 - (effective_start - nowMin) / 5)
    elseif nowMin > effective_end then
        return "post", math.max(0, 1 - (nowMin - effective_end) / 10)
    else
        return "in", 1.0
    end
end

-- ============================================================
-- Debug
-- ============================================================

function ____exports.Describe()
    local a = analyzeDraft()
    if a == nil then return "not analyzed yet" end
    if not a.data_loaded then return "no data loaded — using fallback " .. a.strategy end
    local parts = {}
    -- Indicate live override if active
    if _liveStrategyOverride ~= nil then
        table.insert(parts, _liveStrategyOverride.key .. " [live:" .. (_liveStrategyOverride.reason or "?") .. "]")
    else
        table.insert(parts, a.strategy)
    end
    if a.enemy_strategy then table.insert(parts, "vs " .. a.enemy_strategy) end
    if a.reason and _liveStrategyOverride == nil then
        table.insert(parts, "(" .. a.reason .. ")")
    end
    local tempo = a.my_tempo or {}
    local et = a.enemy_tempo or {}
    local tempoStr = string.format("my=%dE/%dM/%dL enemy=%dE/%dM/%dL",
        tempo.early or 0, tempo.mid or 0, tempo.late or 0,
        et.early or 0, et.mid or 0, et.late or 0)
    table.insert(parts, tempoStr)
    return table.concat(parts, " | ")
end

return ____exports
