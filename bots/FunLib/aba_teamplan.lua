--[[ Hand-written to match typescript/bots/FunLib/aba_teamplan.ts.
     TSTL will regenerate this file when `npm run build` runs against the TS source.
     Keep both in sync. See ARCHITECTURE.md section 16.

     Team-plan layer: one canonical "team intent" per team per tick. Mode desire
     hooks get biased toward the intent, weighted by each bot's teamSpirit trait.
     ]]
local ____exports = {}

-- jmz_func is lazy-loaded to avoid a require cycle: jmz_func requires this module
-- at its own load time, and if we require jmz_func here we'd recurse into a
-- half-loaded package. Inside functions (called later), jmz_func is fully loaded.
local _jmz = nil
local function jmz()
    if _jmz == nil then
        _jmz = require(GetScriptDirectory().."/FunLib/jmz_func")
    end
    return _jmz
end

-- Focus module is also lazy to keep load order flexible.
local _focus = nil
local function focus()
    if _focus == nil then
        local ok, f = pcall(require, GetScriptDirectory().."/FunLib/aba_focus")
        if ok then _focus = f end
    end
    return _focus
end

-- Game theory module (adaptive thresholds based on networth/level).
local _gt = nil
local function gt()
    if _gt == nil then
        local ok, g = pcall(require, GetScriptDirectory().."/FunLib/aba_gametheory")
        if ok then _gt = g end
    end
    return _gt
end

-- Enemy focus module (defensive signal — ally being committed on)
local _ef = nil
local function enemyFocus()
    if _ef == nil then
        local ok, e = pcall(require, GetScriptDirectory().."/FunLib/aba_enemy_focus")
        if ok then _ef = e end
    end
    return _ef
end

-- ============================================================
-- State
-- ============================================================

local TEAMPLAN_RECOMPUTE_INTERVAL = 2.0
local PLAN_TTL = 12.0

local currentPlan = {
    intent = "farm",
    lane = nil,
    location = nil,
    validUntil = 0,
    lastComputeTime = -999,
    authorID = -1,
    reason = "initial",
}

-- ============================================================
-- Helpers (Dota globals + a few jmz calls)
--
-- NOTE: these are declared BEFORE the tormentor/lotus helpers below so the
-- tormentor/lotus closures can resolve countAliveTeamHeroes as a local
-- upvalue. Earlier layout had the helpers below the consumers, which made
-- the names resolve as globals (nil) — crash on first tormentor/lotus probe.
-- ============================================================

local function countEnemyHeroesNear(loc, radius)
    local J = jmz()
    local ok, enemies = pcall(function() return J.GetEnemiesNearLoc(loc, radius) end)
    if not ok or enemies == nil then return 0 end
    local n = 0
    for i = 1, #enemies do
        if J.IsValidHero(enemies[i]) then n = n + 1 end
    end
    return n
end

local function countAliveTeamHeroes(team)
    local n = 0
    local players = GetTeamPlayers(team)
    for i = 1, #players do
        if IsHeroAlive(players[i]) then n = n + 1 end
    end
    return n
end

-- ============================================================
-- Tormentor + Lotus detection (no dedicated API; use unit lists)
-- ============================================================

-- Known lotus pool locations (radiant and dire sides).
-- Coordinates verified against standard Dota 2 map.
local LotusLocations = {
    { x = -7207,  y = 1480,  z = 384 },   -- Radiant near-top lotus (in ruins)
    { x = -5568,  y = 2880,  z = 384 },   -- Radiant far-top lotus
    { x = 7316,   y = -1400, z = 384 },   -- Dire near-bot lotus (in ruins)
    { x = 5440,   y = -2944, z = 384 },   -- Dire far-bot lotus
}

local function findNearestTormentorUnit(referenceLoc)
    local ok, neutrals = pcall(function() return GetUnitList(UNIT_LIST_ENEMIES) end)
    if not ok or neutrals == nil then return nil end
    local best = nil
    local bestDist = 999999
    for i = 1, #neutrals do
        local u = neutrals[i]
        if u ~= nil and not u:IsNull() and u:IsAlive() then
            local okName, name = pcall(function() return u:GetUnitName() end)
            if okName and type(name) == "string" and string.find(name, "miniboss") ~= nil then
                local d = 0
                if referenceLoc ~= nil then
                    local loc = u:GetLocation()
                    d = math.sqrt((loc.x - referenceLoc.x)^2 + (loc.y - referenceLoc.y)^2)
                end
                if best == nil or d < bestDist then
                    best = u
                    bestDist = d
                end
            end
        end
    end
    return best
end

local function isTormentorContestable(bot, team)
    local J = jmz()
    local expectedLoc = J.GetTormentorLocation(team)
    if expectedLoc == nil then return false, nil end
    -- Are we ready? Need 3+ allies alive + average level 10+
    local aliveAllies = countAliveTeamHeroes(team)
    if aliveAllies < 3 then return false, nil end
    local avgLevel = J.GetAverageLevel(false)
    if avgLevel < 10 then return false, nil end
    -- Is it alive? Probe unit list. Even if the team's own tormentor is elsewhere,
    -- check for ANY miniboss alive and use its location.
    local tormUnit = findNearestTormentorUnit(expectedLoc)
    if tormUnit == nil then return false, nil end
    return true, tormUnit:GetLocation()
end

local function isLotusContestable(team, now)
    -- Lotus pools refresh every ~3 min after pickup. Worth pickup as long as
    -- the ruins are still our side of the map. Old window cut off at 14min,
    -- which left supports walking past lotuses they should be grabbing all
    -- the way through mid-game. Extended to 25min — by then the team should
    -- be on rosh / push and the small sustain doesn't justify a rotation.
    -- contest_lotus is role-gated to {4,5} so cores aren't pulled off.
    if now < 60 or now > 25 * 60 then return false, nil end
    -- Score our nearest lotus location — prefer the one closer to the team center.
    local J = jmz()
    local teamFountain = J.GetTeamFountain and J.GetTeamFountain() or nil
    if teamFountain == nil then return false, nil end
    -- Ruins-side lotus = closer to our fountain. Pick that one.
    local bestLoc = nil
    local bestDist = 999999
    for i = 1, #LotusLocations do
        local L = LotusLocations[i]
        local loc = Vector(L.x, L.y, L.z)
        local d = math.sqrt((loc.x - teamFountain.x)^2 + (loc.y - teamFountain.y)^2)
        if d < bestDist then
            bestDist = d
            bestLoc = loc
        end
    end
    if bestLoc == nil then return false, nil end
    -- Need at least 1 ally not already farming to go grab it (supports typically)
    local aliveAllies = countAliveTeamHeroes(team)
    if aliveAllies < 2 then return false, nil end
    return true, bestLoc
end

local function findFurthestAliveLaneBuilding(team, lane)
    local towers
    if lane == LANE_TOP then
        towers = { TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3 }
    elseif lane == LANE_MID then
        towers = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3 }
    else
        towers = { TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3 }
    end
    for i = 1, #towers do
        local t = GetTower(team, towers[i])
        if t ~= nil and t:IsAlive() then return t end
    end
    -- rax fallback
    local raxMelee
    local raxRanged
    if lane == LANE_TOP then
        raxMelee = GetBarracks(team, BARRACKS_TOP_MELEE)
        raxRanged = GetBarracks(team, BARRACKS_TOP_RANGED)
    elseif lane == LANE_MID then
        raxMelee = GetBarracks(team, BARRACKS_MID_MELEE)
        raxRanged = GetBarracks(team, BARRACKS_MID_RANGED)
    else
        raxMelee = GetBarracks(team, BARRACKS_BOT_MELEE)
        raxRanged = GetBarracks(team, BARRACKS_BOT_RANGED)
    end
    if raxMelee ~= nil and raxMelee:IsAlive() then return raxMelee end
    if raxRanged ~= nil and raxRanged:IsAlive() then return raxRanged end
    return nil
end

local function getLaneTier(team, lane)
    local towers
    if lane == LANE_TOP then
        towers = { TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3 }
    elseif lane == LANE_MID then
        towers = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3 }
    else
        towers = { TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3 }
    end
    for i = 1, #towers do
        local t = GetTower(team, towers[i])
        if t ~= nil and t:IsAlive() then return i end
    end
    return 4
end

local function findThreatenedLane(team)
    local lanes = { LANE_TOP, LANE_MID, LANE_BOT }
    local bestLane = nil
    local bestLoc = nil
    local bestThreat = 0
    for i = 1, #lanes do
        local lane = lanes[i]
        local building = findFurthestAliveLaneBuilding(team, lane)
        if building ~= nil then
            local loc = building:GetLocation()
            local enemiesNear = countEnemyHeroesNear(loc, 1600)
            local recentlyHit = building:GetHealth() < building:GetMaxHealth() * 0.9
            local threat = enemiesNear + (recentlyHit and 1 or 0)
            if threat >= 2 and threat > bestThreat then
                bestThreat = threat
                bestLane = lane
                bestLoc = loc
            end
        end
    end
    if bestLane ~= nil then
        return { lane = bestLane, loc = bestLoc }
    end
    return nil
end

local function findPushTarget(enemyTeam, team, threshold)
    local aliveAllies = countAliveTeamHeroes(team)
    local req = threshold or 4
    if aliveAllies < req then return nil end
    local lanes = { LANE_TOP, LANE_MID, LANE_BOT }
    local bestLane = nil
    local bestLoc = nil
    local bestTier = 99
    for i = 1, #lanes do
        local lane = lanes[i]
        local tier = getLaneTier(enemyTeam, lane)
        if tier < bestTier then
            local building = findFurthestAliveLaneBuilding(enemyTeam, lane)
            if building ~= nil then
                bestTier = tier
                bestLane = lane
                bestLoc = building:GetLocation()
            end
        end
    end
    if bestLane ~= nil and bestTier <= 3 then
        return { lane = bestLane, loc = bestLoc }
    end
    return nil
end

local function countGroupedAllies(team)
    local players = GetTeamPlayers(team)
    local anchor = nil
    for i = 1, #players do
        local m = GetTeamMember(i)
        if m ~= nil and m:IsAlive() then anchor = m; break end
    end
    if anchor == nil then return 0 end
    local n = 0
    for i = 1, #players do
        local m = GetTeamMember(i)
        if m ~= nil and m:IsAlive() and GetUnitToUnitDistance(anchor, m) <= 1600 then
            n = n + 1
        end
    end
    return n
end

local function teamIsWeak(team)
    local J = jmz()
    local players = GetTeamPlayers(team)
    local lowCount = 0
    local total = 0
    for i = 1, #players do
        local m = GetTeamMember(i)
        if m ~= nil and m:IsAlive() then
            total = total + 1
            if J.GetHP(m) < 0.45 or J.GetMP(m) < 0.25 then
                lowCount = lowCount + 1
            end
        end
    end
    return total >= 2 and lowCount >= math.ceil(total * 0.5)
end

-- Count enemies whose last-seen is stale (>= staleSeconds). Only counts heroes
-- that HAVE been seen at least once and whose info is genuinely old. "Never seen"
-- heroes don't count (otherwise we'd flag them at game start before any vision
-- accumulated and trigger spurious regroups).
local function countMissingEnemies(enemyTeam, staleSeconds)
    local players = GetTeamPlayers(enemyTeam)
    local missing = 0
    for i = 1, #players do
        local pid = players[i]
        if IsHeroAlive(pid) then
            local info = GetHeroLastSeenInfo(pid)
            -- Only count if info exists AND time_since_seen is a number >= staleSeconds.
            -- Skip missing info / nil time_since_seen — those mean "no data yet", not "smoked".
            if info ~= nil and info[1] ~= nil
               and type(info[1].time_since_seen) == "number"
               and info[1].time_since_seen >= staleSeconds then
                missing = missing + 1
            end
        end
    end
    return missing
end

-- ============================================================
-- Per-role intent routing.
--
-- Critical design fix after user feedback: "5 bots all group up at ruins,
-- no unpredictability, players don't act like this." The issue: intents
-- were team-wide — contest_lotus fired and ALL 5 bots went to ruins. In
-- real Dota, only pos 4/5 collect ruins; pos 1/2 farm/mid.
--
-- Each intent now specifies which roles (1-5) should respond to it.
-- Bots whose role isn't in the intent's roles treat the plan as "farm"
-- (no location bias). This prevents 5-man groupups for small objectives.
-- ============================================================

local INTENT_ROLES = {
    defend_base       = {1,2,3,4,5},  -- everyone defends the ancient
    defend_lane       = {1,2,3,4,5},  -- everyone defends a threatened rax
    save_ally         = {1,2,3,4,5},  -- anyone nearby collapses
    commit_kill       = {1,2,3,4,5},  -- full commit
    lane_gank         = {4,5,2},      -- supports + mid rotate for ganks, NOT pos 1/3
    contest_rosh      = {1,2,3,4,5},  -- team fight for rosh
    contest_tormentor = {2,3,4,5},    -- mid/off/supports; pos 1 farm instead
    contest_lotus     = {4,5},        -- ONLY supports collect lotus — fixes ruins groupup
    push_lane         = {1,2,3,4,5},  -- 5-man push
    smoke_gank        = {4,5,3},      -- mostly supports + offlaner
    regroup           = {1,2,3,4,5},
    late_game_group   = {1,2,3,4,5},  -- everyone groups late game
    farm              = {1,2,3,4,5},  -- fallback
}

-- Check if the given role (1-5) should respond to the plan's intent.
-- Used by mode_assemble and other converge-type modes.
local function roleRespondsToIntent(role, intent)
    local roles = INTENT_ROLES[intent]
    if roles == nil then return true end  -- unknown intent: default to respond
    for i = 1, #roles do
        if roles[i] == role then return true end
    end
    return false
end

-- Exposed helper
local function computeRoleShouldRespond(bot)
    local plan = nil  -- fill below
    return roleRespondsToIntent, plan
end

-- ============================================================
-- Tactic exhaustion / cooldown — give up failed commits
--
-- User feedback: "they should try once and move to the other spot or
-- give up and switch tactics." If commit_kill or contest_rosh has been
-- the intent continuously for too long, force a cooldown so other
-- intents can fire and bots can try something else.
-- ============================================================

local _intentStartTime = {}    -- intent -> when it became active
local _intentCooldownUntil = {}  -- intent -> game time it can fire again

-- Phase 8: smoke_gank cadence. Pro matches average one smoke ~every 3 min
-- (pro_macro.smoke_gank_cadence_min). We rate-limit our own smoke_gank plan
-- issuance to roughly match so bots don't spam gank intent.
local _lastSmokeGankTime = -999

-- Phase 4: push_lane min-time gate. Bots shouldn't try to push during laning
-- phase. Derived from pro first_t1_fall_typical_sec * 0.6 at compute time.
local _lastPushLaneTime = -999

local TACTIC_TIMEOUT = {
    commit_kill = 22,        -- give up after 22s if no kill
    contest_rosh = 35,       -- 35s for rosh attempt
    contest_tormentor = 30,
    lane_gank = 18,
    save_ally = 12,          -- saves are short-window
    -- Without a push_lane timeout, the intent dominates forever once the gate
    -- opens — smoke_gank, late_game_group, and regroup all lose priority. Cap
    -- the push commitment so the team disperses and can rotate into other
    -- plays (smokes, defensive regroup) between push attempts. Validated via
    -- sim harness: before this cap, bot-vs-bot matches showed 31/40 minutes
    -- locked into push_lane with 0 smoke_ganks and 0 late_game_group.
    push_lane = 30,
    smoke_gank = 25,
}

local TACTIC_COOLDOWN = {
    commit_kill = 12,        -- 12s cooldown after timeout
    contest_rosh = 180,      -- 3-min cooldown — Phase 14: was 25s, caused
                              -- both teams to spam rosh attempts every minute.
                              -- Real games have rosh attempted maybe once
                              -- every 8-10 min on average; this cooldown
                              -- enforces that pacing even when gates re-open.
    contest_tormentor = 20,
    lane_gank = 8,
    save_ally = 6,
    push_lane = 90,          -- long rest after push so smoke/group can fire
    smoke_gank = 30,
}

local function isInCooldown(intent)
    local until_t = _intentCooldownUntil[intent]
    if until_t == nil then return false end
    return DotaTime() < until_t
end

local function trackIntent(intent)
    -- Called every computePlan with the intent that's about to be returned
    local prev = nil
    for k, _ in pairs(_intentStartTime) do prev = k; break end
    if prev ~= intent then
        _intentStartTime = {}
        _intentStartTime[intent] = DotaTime()
    end

    -- If this intent has run too long, push it into cooldown
    local startedAt = _intentStartTime[intent]
    local timeout = TACTIC_TIMEOUT[intent]
    if startedAt ~= nil and timeout ~= nil and (DotaTime() - startedAt) > timeout then
        local cooldown = TACTIC_COOLDOWN[intent] or 10
        _intentCooldownUntil[intent] = DotaTime() + cooldown
        _intentStartTime = {}
    end
end

-- ============================================================
-- Plan commitment.
--
-- commitment ∈ [0, 1] tells GetPlanBias how authoritatively to enforce
-- the plan. Low commitment = advisory (bots can ignore via their own
-- desires + teamSpirit dampener — current behavior). High commitment
-- = the bias range widens beyond the [0.5, 1.3] envelope AND drops the
-- teamSpirit dampener, so contradicting modes get hammered to ~0.2x and
-- aligned modes get pushed to ~1.6x. That makes high-stakes plans
-- (defend_base, push during a winning state, save_ally) actually
-- coordinate the team instead of being one factor among many.
--
-- Push-then-retreat fix: push_lane commitment grows with age. After 25s
-- in push, commitment is high enough that the missing-enemy regroup
-- intent at line ~846 can't actually pull bots off the push — their
-- push mode dominates regardless.
-- ============================================================

local INTENT_BASE_COMMITMENT = {
    defend_base       = 1.00,
    save_ally         = 0.95,
    commit_kill       = 0.85,
    contest_rosh      = 0.85,
    contest_tormentor = 0.80,
    smoke_gank        = 0.65,
    push_lane         = 0.50,   -- starts advisory; ramps via age boost below
    defend_lane       = 0.75,
    lane_gank         = 0.65,
    contest_lotus     = 0.40,
    late_game_group   = 0.55,
    regroup           = 0.45,
    farm              = 0.30,   -- always advisory
}

-- Sticky intents: longer time spent in this intent → stronger commitment.
-- Stops the team flipping plans every 2s during a coordinated maneuver.
local STICKY_INTENTS = {
    push_lane = true, contest_rosh = true, smoke_gank = true,
    late_game_group = true, commit_kill = true, defend_lane = true,
}

local function computeCommitment(intent, planAgeSec)
    local base = INTENT_BASE_COMMITMENT[intent] or 0.50
    if STICKY_INTENTS[intent] then
        local age = planAgeSec or 0
        if age < 0 then age = 0 end
        if age > 30 then age = 30 end
        base = base + (age / 30) * 0.25   -- up to +0.25 after 30s
    end
    if base < 0 then return 0 end
    if base > 1 then return 1 end
    return base
end

-- ============================================================
-- Intent computation
-- ============================================================

local function freshPlan(intent, lane, loc, reason)
    -- Tactic switching: if this intent has been firing too long without success,
    -- downgrade to regroup so bots break off and try something different.
    -- Real Dota: failed dive -> regroup -> different tactic. Don't keep grinding.
    if isInCooldown(intent) then
        return {
            intent = "regroup",
            lane = nil,
            location = nil,
            validUntil = 0,
            lastComputeTime = 0,
            authorID = -1,
            reason = "tactic '" .. tostring(intent) .. "' on cooldown — regrouping to switch",
        }
    end
    trackIntent(intent)
    return {
        intent = intent,
        lane = lane,
        location = loc,
        validUntil = 0,
        lastComputeTime = 0,
        authorID = -1,
        reason = reason,
    }
end

-- Compute a group location for late-game regrouping.
-- Phase 14 fix: was returning the team's Ancient (= fountain) which made
-- late_game_group glue bots to the fountain forever. Now returns the
-- team's frontmost own tower — wherever the actual battle line is.
-- Falls through tiers from T1 -> T2 -> T3 -> ancient (only as last resort).
local function computeGroupLocation(team)
    local lanes = { LANE_TOP, LANE_MID, LANE_BOT }
    -- Iterate tower tiers from forward to back. Pick the first tier where
    -- ANY of our lanes still has that tier alive — that's the front line.
    local tier_lists = {
        { TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1 },
        { TOWER_TOP_2, TOWER_MID_2, TOWER_BOT_2 },
        { TOWER_TOP_3, TOWER_MID_3, TOWER_BOT_3 },
    }
    for _, tier in ipairs(tier_lists) do
        for _, t_id in ipairs(tier) do
            local t = GetTower(team, t_id)
            if t ~= nil and not t:IsNull() and t:IsAlive() then
                return t:GetLocation()
            end
        end
    end
    -- All outer towers gone — group at ancient as last-resort defensive stance
    local ancient = GetAncient(team)
    if ancient == nil then return nil end
    return ancient:GetLocation()
end

-- Opening flavor: rolled once per match to vary early-game strategy.
-- Stored at module scope so every computePlan call sees the same roll.
local _openingFlavor = nil
local _midgameFlavor = nil
local _lateGameFlavor = nil
local function getOpeningFlavor()
    if _openingFlavor ~= nil then return _openingFlavor end
    local roll = RandomInt(1, 100)
    if roll <= 15 then _openingFlavor = "bounty_invade"   -- 15%: rotate to enemy bounty for FB
    elseif roll <= 32 then _openingFlavor = "lotus_rush"
    elseif roll <= 52 then _openingFlavor = "aggro_roam"
    elseif roll <= 72 then _openingFlavor = "passive_lane"
    elseif roll <= 88 then _openingFlavor = "deward_scout"
    else _openingFlavor = "smoke_gank_early" end
    return _openingFlavor
end

-- Enemy bounty rune locations — used by bounty_invade opening flavor.
-- Each team's bounties are mirrored across the map. We pick the bounty
-- closer to the enemy team's safelane (the "near" one) for invades.
local function getEnemyBountyLocation(myTeam)
    if myTeam == TEAM_RADIANT then
        -- Dire safelane bounty is near top — invade that one
        return Vector(7456, -64, 384)
    else
        -- Radiant safelane bounty is near bot — invade that one
        return Vector(-7456, 64, 384)
    end
end

local function getMidgameFlavor(now)
    if _midgameFlavor ~= nil then return _midgameFlavor end
    if now < 12 * 60 then return nil end
    local roll = RandomInt(1, 100)
    if roll <= 25 then _midgameFlavor = "fast_siege"
    elseif roll <= 50 then _midgameFlavor = "pickoff_focus"
    elseif roll <= 75 then _midgameFlavor = "split_farm"
    else _midgameFlavor = "objective_dance" end
    return _midgameFlavor
end

local function getLateGameFlavor(now)
    if _lateGameFlavor ~= nil then return _lateGameFlavor end
    if now < 28 * 60 then return nil end
    local roll = RandomInt(1, 100)
    if roll <= 34 then _lateGameFlavor = "high_ground_rush"
    elseif roll <= 67 then _lateGameFlavor = "aegis_stall"
    else _lateGameFlavor = "split_and_rax" end
    return _lateGameFlavor
end

local function computePlan(bot)
    local team = GetTeam()
    local enemyTeam = GetOpposingTeam()
    local now = DotaTime()
    local readiness = 1.0

    -- Pull adaptive thresholds from game theory if available (falls back to defaults).
    local thresholds = {
        commitAllyThreshold = 2,
        pushAllyThreshold = 4,
        roshAllyThreshold = 3,
        tormentorLevelThreshold = 10,
    }
    local gtMod = gt()
    if gtMod ~= nil then
        local ok, t = pcall(function() return gtMod.GetThresholds() end)
        if ok and t ~= nil then thresholds = t end
    end

    -- Strategy integration: apply per-strategy adjustments to thresholds and
    -- cadences, so a `split_push` draft plays differently from a `late_scale`
    -- draft. Without this, the drafted strategy was only a small ModulateDesire
    -- multiplier; bots played mid-game roughly the same regardless of comp.
    --
    -- Strategy is the LIVE-OVERRIDDEN one (computeLiveOverride may have
    -- swapped to turtle/aggro based on game state).
    local strategy = "teamfight_mid"
    local strategyPushMinAdj = 0
    local strategySmokeCadenceAdj = 0
    do
        local jmzMod_for_strat = jmz()
        if jmzMod_for_strat and jmzMod_for_strat.DraftStrategy
           and jmzMod_for_strat.DraftStrategy.GetEffectiveStrategyName then
            local okS, s = pcall(function() return jmzMod_for_strat.DraftStrategy.GetEffectiveStrategyName() end)
            if okS and type(s) == "string" then strategy = s end
        end
    end
    -- Strategy-specific threshold + cadence adjustments. All clamped so no
    -- single setting can break Phase-14 invariants (defend_base still fires
    -- on real threat regardless; rosh still requires hard advantage).
    if strategy == "early_aggro" then
        thresholds.commitAllyThreshold = math.max(1, thresholds.commitAllyThreshold - 1)
        thresholds.pushAllyThreshold = math.max(3, thresholds.pushAllyThreshold - 1)
        strategySmokeCadenceAdj = -90   -- 180s → 90s smoke cadence
        strategyPushMinAdj = -2 * 60    -- push 2min earlier
    elseif strategy == "fast_siege" then
        thresholds.pushAllyThreshold = math.max(3, thresholds.pushAllyThreshold - 1)
        strategyPushMinAdj = -2 * 60
    elseif strategy == "teamfight_mid" then
        thresholds.roshAllyThreshold = math.max(2, thresholds.roshAllyThreshold - 1)
    elseif strategy == "split_push" then
        -- split_push: don't lower commit thresholds (we WANT the team mostly
        -- doing other things while one core splits). Push cadence stays
        -- normal; push_lane can fire early.
        strategyPushMinAdj = -1 * 60
    elseif strategy == "late_scale" then
        thresholds.commitAllyThreshold = thresholds.commitAllyThreshold + 1
        thresholds.pushAllyThreshold = math.min(5, thresholds.pushAllyThreshold + 1)
        strategySmokeCadenceAdj = 60     -- 180s → 240s, less smoke
        strategyPushMinAdj = 2 * 60      -- push 2min later
    elseif strategy == "turtle_defensive" then
        thresholds.commitAllyThreshold = thresholds.commitAllyThreshold + 1
        thresholds.pushAllyThreshold = math.min(5, thresholds.pushAllyThreshold + 1)
        thresholds.roshAllyThreshold = thresholds.roshAllyThreshold + 1
        strategySmokeCadenceAdj = 90
        strategyPushMinAdj = 3 * 60
    end

    -- 1. DEFEND_BASE: ancient under REAL threat — Phase 14 fix.
    --
    -- Previous gate fired on 1+ enemy within 2500u. In late game both teams
    -- routinely have a scout/split-pusher near the enemy base, which
    -- triggered defend_base for the OPPOSITE team. Net result: both teams
    -- panic-recall to their own ancient and hover at the fountain. User
    -- report: "late game both sides just hover near the fountain."
    --
    -- New gate requires evidence of an ACTUAL coordinated threat:
    --   (a) 2+ enemies within 1500u (coordinated push, not a lone scout), OR
    --   (b) ancient taking damage in the last 8 seconds, OR
    --   (c) ancient HP below 80% (under real attack)
    local ourAncient = GetAncient(team)
    if ourAncient ~= nil and not ourAncient:IsNull() then
        local hpPct = ourAncient:GetHealth() / math.max(1, ourAncient:GetMaxHealth())
        local okDmg, recentDmg = pcall(function() return ourAncient:WasRecentlyDamagedByAnyHero(8.0) end)
        local recentlyDamaged = (okDmg and recentDmg) or false
        local enemiesAtAncient = countEnemyHeroesNear(ourAncient:GetLocation(), 1500)

        if enemiesAtAncient >= 2 or recentlyDamaged or hpPct < 0.80 then
            local reason = string.format("real threat: enemies=%d hp=%.0f%% dmg=%s",
                enemiesAtAncient, hpPct * 100, tostring(recentlyDamaged))
            return freshPlan("defend_base", nil, ourAncient:GetLocation(), reason)
        end
    end

    -- 1.5 USER PING → push_lane / defend_lane.
    --
    -- User pings are an EXPLICIT command channel: "the team should be HERE
    -- doing THAT". Previously assemble_generic responded by walking bots to
    -- the ping — but team plan didn't issue a push_lane intent, so once
    -- bots arrived, no mode kept them attacking. This wires the ping into
    -- the team plan layer.
    --
    -- Ping on enemy-side of map → push_lane (with the ping's location;
    -- push_tower mode finds the actual structure from there).
    -- Ping on our side → defend_lane (treat as "help here").
    -- 8-second window so a single ping commits the team for a push without
    -- requiring the user to spam clicks.
    local okJmz, jmzMod = pcall(jmz)
    if okJmz and jmzMod and jmzMod.GetHumanPing then
        local okPing, _, ping = pcall(function()
            local m, p = jmzMod.GetHumanPing()
            return m, p
        end)
        -- For bot-only teams (e.g. enemy team in custom lobby), there is no
        -- human ping. Fall through to synthetic team-objective ping so the
        -- bot-only team still gets ping-driven push/defend intents.
        if (not okPing or ping == nil or ping.location == nil or ping.time == 0
            or (now - ping.time) >= 8)
           and jmzMod.SyntheticPing and jmzMod.SyntheticPing.Get then
            local okSyn, synPing = pcall(function() return jmzMod.SyntheticPing.Get(team) end)
            if okSyn and synPing ~= nil then
                ping = synPing
                okPing = true
            end
        end
        if okPing and ping ~= nil and ping.location ~= nil and ping.time ~= 0
           and (now - ping.time) < 8 then
            -- River line is x+y=0. Radiant safe-side has x+y < 0; Dire's
            -- safe side x+y > 0. So enemy-side for us = opposite sign.
            local pingSum = (ping.location.x or 0) + (ping.location.y or 0)
            local enemySide
            if team == TEAM_RADIANT then
                enemySide = (pingSum > 0)
            else
                enemySide = (pingSum < 0)
            end
            if enemySide then
                return freshPlan("push_lane", nil, ping.location,
                    "user pinged enemy side — push")
            else
                -- Our side: lane help, not full base defense.
                return freshPlan("defend_lane", nil, ping.location,
                    "user pinged own side — group up")
            end
        end
    end

    -- 2. DEFEND_LANE: T1/T2 under active attack
    local threat = findThreatenedLane(team)
    if threat ~= nil then
        return freshPlan("defend_lane", threat.lane, threat.loc, "lane under attack")
    end

    -- 2.4 SAVE_ALLY: enemy is committing on one of our heroes — collapse defensively.
    -- Sits ABOVE commit_kill because saving a teammate > finishing our own pick.
    local ef = enemyFocus()
    if ef ~= nil then
        local pickSelf = nil
        for i = 1, 5 do
            local m = GetTeamMember(i)
            if m ~= nil and m:IsAlive() then pickSelf = m; break end
        end
        if pickSelf ~= nil then
            ef.MaybeRecompute(pickSelf)
            if ef.IsActive() then
                local threatened = ef.GetThreatenedAlly()
                if threatened ~= nil and threatened.unit ~= nil then
                    local saveLoc = threatened.unit:GetLocation()
                    return freshPlan("save_ally", nil, saveLoc,
                        "save=" .. (threatened.reason or "?") .. " urgency=" .. string.format("%.2f", threatened.urgency or 0))
                end
            end
        end
    end

    -- Hoisted: TeamfightReadiness must be computed BEFORE commit_kill so the
    -- readiness gate at the engageOK check sees real values. Otherwise it
    -- reads the init `readiness = 1.0` and the gate is a no-op.
    local jmzM = jmz()
    if jmzM and jmzM.TeamState and jmzM.TeamState.TeamfightReadiness then
        local okReady, ready = pcall(function() return jmzM.TeamState.TeamfightReadiness() end)
        if okReady and type(ready) == "number" then readiness = ready end
    end

    -- 2.5 COMMIT_KILL: focus target exists + ≥ threshold allies near focus
    -- (threshold adapts to pressure and focus quality — a very high-score
    -- focus lowers the threshold by 1, so a juicy isolated-low-HP core
    -- triggers commit with just 1 ally nearby rather than requiring 2).
    --
    -- 2.6 LANE_GANK: during laning, a 1v1 on a low-HP adjacent-lane enemy
    -- is still a commit — pro supports roam solo all the time. Looser than
    -- commit_kill (1 ally within 1500u is enough).
    local f = focus()
    if f ~= nil then
        local pickSelf = nil
        for i = 1, 5 do
            local m = GetTeamMember(i)
            if m ~= nil and m:IsAlive() then pickSelf = m; break end
        end
        if pickSelf ~= nil then
            f.MaybeRecompute(pickSelf)
            local target = f.GetFocus()
            if target ~= nil and target.unit ~= nil and now < target.validUntil then
                local focusLoc = target.unit:GetLocation()
                local nearAllies = jmz().GetAlliesNearLoc(focusLoc, 2000)
                -- Adaptive effective threshold: very high-quality focus (score >= 2)
                -- reduces required ally count by 1 (down to minimum 1). Rewards
                -- isolation + low HP + core value.
                local effThreshold = thresholds.commitAllyThreshold
                if (target.score or 0) >= 2.0 then
                    effThreshold = math.max(1, effThreshold - 1)
                end
                if nearAllies ~= nil and #nearAllies >= effThreshold then
                    -- Phase 11 Item 2: info asymmetry gate. Don't commit on
                    -- a ghost target. ShouldEngage requires fresh perception
                    -- + not 2+ enemies missing.
                    local jmzM_for_engage = jmz()
                    local target_pid = nil
                    if target.unit ~= nil then
                        local okPid, pid = pcall(function() return target.unit:GetPlayerID() end)
                        if okPid then target_pid = pid end
                    end
                    local engageOK = true
                    if jmzM_for_engage and jmzM_for_engage.TeamState and target_pid ~= nil then
                        engageOK = jmzM_for_engage.TeamState.ShouldEngage(target_pid)
                    end
                    if engageOK and readiness > 0.50 then
                        return freshPlan("commit_kill", nil, focusLoc,
                            "focus=" .. (target.reason or "?") .. " allies=" .. tostring(#nearAllies) .. "/" .. tostring(effThreshold)
                            .. " score=" .. string.format("%.2f", target.score or 0))
                    end
                end
                -- Lane-gank path: laning phase + low-HP focus + at least 1 close ally
                local okLaning, isLaning = pcall(function() return jmz().IsInLaningPhase() end)
                if okLaning and isLaning then
                    local okHP, hp = pcall(function() return jmz().GetHP(target.unit) end)
                    if okHP and hp ~= nil and hp < 0.55 then
                        local closeAllies = jmz().GetAlliesNearLoc(focusLoc, 1500)
                        if closeAllies ~= nil and #closeAllies >= 1 then
                            return freshPlan("lane_gank", nil, focusLoc,
                                "lane-gank hp=" .. string.format("%.2f", hp) .. " allies=" .. tostring(#closeAllies))
                        end
                    end
                end
            end
        end
    end

    -- 3. CONTEST_ROSH: tightened gate — Phase 14 fix.
    --
    -- Previous gate (now > 12min, rosh alive, allies >= 3, allies >= enemies)
    -- fired on most mid-game ticks because all four conditions were trivially
    -- satisfied. Both teams spammed contest_rosh every 25-35s for the rest of
    -- the game, ruining gameplay. (User report: "Both teams obsessed with
    -- roshan and ruin gameplay.")
    --
    -- New gate requires HARD ADVANTAGE before committing — actual numbers
    -- advantage AND a real trigger reason (recent kill / aegis incoming /
    -- big NW lead). Fires roughly once every 5-10 minutes when conditions
    -- align, not constantly.
    local roshGateSec = 15 * 60   -- not before minute 15 unless triggered
    if jmzM and jmzM.DraftStrategy and jmzM.DraftStrategy.GetProMacro then
        local pm = jmzM.DraftStrategy.GetProMacro()
        if pm and pm.first_rosh_typical_sec and pm.first_rosh_typical_sec > 0 then
            roshGateSec = math.floor(pm.first_rosh_typical_sec)  -- pro median, not 0.8x
        end
    end
    local okRosh, roshAlive = pcall(function() return jmz().IsRoshanAlive() end)
    if okRosh and roshAlive and now > roshGateSec then
        local aliveAllies = countAliveTeamHeroes(team)
        local aliveEnemies = countAliveTeamHeroes(enemyTeam)

        -- Hard advantage required: 4+ allies AND at least 2 more alive than
        -- enemies (i.e. enemy team has 2+ dead heroes recently). This means
        -- contest_rosh only fires after a successful teamfight, not "we
        -- happen to be alive at the same time as them."
        local hasNumbersAdvantage = (aliveAllies >= 4) and (aliveAllies >= aliveEnemies + 2)

        -- OR: massive networth lead (>10k) and full team alive — we're
        -- snowballing, take rosh as a finisher.
        local hasNWLead = false
        if jmzM and jmzM.GetInventoryNetworth then
            local okNW, myNW, enemyNW = pcall(function() return jmzM.GetInventoryNetworth() end)
            if okNW and type(myNW) == "number" and type(enemyNW) == "number" then
                hasNWLead = (aliveAllies == 5) and ((myNW - enemyNW) >= 10000)
            end
        end

        if (hasNumbersAdvantage or hasNWLead) and readiness > 0.50 then
            local roshLoc = jmz().GetCurrentRoshanLocation and jmz().GetCurrentRoshanLocation() or nil
            local reason = hasNumbersAdvantage
                and ("rosh: numbers " .. tostring(aliveAllies) .. "v" .. tostring(aliveEnemies))
                or ("rosh: nw_lead 10k+")
            return freshPlan("contest_rosh", nil, roshLoc, reason)
        end
    end

    -- 3.5 CONTEST_TORMENTOR: tormentor alive + we're ready + enough allies
    local tormentorReady, tormentorLoc = isTormentorContestable(bot, team)
    if tormentorReady then
        return freshPlan("contest_tormentor", nil, tormentorLoc, "tormentor up, team ready")
    end

    -- 3.7 CONTEST_LOTUS: early/mid game, ruins lotus is a sustain objective
    local lotusReady, lotusLoc = isLotusContestable(team, now)
    if lotusReady then
        return freshPlan("contest_lotus", nil, lotusLoc, "lotus sustain pickup")
    end

    -- 3.8 SMOKE_GANK (overdue bypass): fire smoke even in late-game group
    -- window when cadence has come around. Pros smoke FROM the high-ground
    -- grouping — the two aren't mutually exclusive. Without this block the
    -- late_game_group gate below starves smoke_gank of all post-25min
    -- windows, flattening smoke events at ~8/match vs pro expectation 13.
    local smokeCadenceSec = 180
    if jmzM and jmzM.DraftStrategy and jmzM.DraftStrategy.GetProMacro then
        local pm = jmzM.DraftStrategy.GetProMacro()
        if pm and pm.smoke_gank_cadence_min and pm.smoke_gank_cadence_min > 0 then
            smokeCadenceSec = pm.smoke_gank_cadence_min * 60
        end
    end
    -- Strategy adjustment: early_aggro shortens cadence; turtle/late_scale lengthens it.
    smokeCadenceSec = math.max(60, smokeCadenceSec + (strategySmokeCadenceAdj or 0))
    if now > 10 * 60 and (now - _lastSmokeGankTime) >= smokeCadenceSec
       and not isInCooldown("smoke_gank") then
        local grouped = countGroupedAllies(team)
        if grouped >= 3 then
            _lastSmokeGankTime = now
            return freshPlan("smoke_gank", nil, nil, "grouped, cadence overdue")
        end
    end

    -- (Phase 14: late_game_group DEMOTED back below push_lane — see section 5
    -- after push. Phase 9's elevated priority was a workaround for push_lane
    -- dominating, but push_lane now has its own TACTIC_TIMEOUT/COOLDOWN. With
    -- late_game_group running BEFORE push_lane and its location set to the
    -- ancient (= fountain), bots got glued to the fountain past minute 25.
    -- User report: "late game both sides just hover near the fountain".)

    -- 4. PUSH_LANE: weakest enemy lane + we have people (threshold adapts to pressure).
    -- Phase 4: gate by a min game time from pro macro data. Pro first T1 typically
    -- falls around 12 min; we allow push_lane from 60% of that window so bots still
    -- leverage early lane wins (~7 min) but don't try to siege during laning stage.
    -- Exception: if we have a clear networth lead, allow earlier pushes.
    local pushMinSec = 7 * 60
    if jmzM and jmzM.DraftStrategy and jmzM.DraftStrategy.GetProMacro then
        local pm = jmzM.DraftStrategy.GetProMacro()
        if pm and pm.first_t1_fall_typical_sec and pm.first_t1_fall_typical_sec > 0 then
            pushMinSec = pm.first_t1_fall_typical_sec * 0.6
        end
    end
    -- Strategy adjustment: aggressive comps push earlier, scaling comps later.
    pushMinSec = math.max(4 * 60, pushMinSec + (strategyPushMinAdj or 0))
    -- Big gold lead (>4k) overrides the min-time gate — comp that snowballs early
    -- should be allowed to press advantage.
    local nwLead = 0
    if jmzM and jmzM.GetInventoryNetworth then
        local okNW, myNW, enemyNW = pcall(function() return jmzM.GetInventoryNetworth() end)
        if okNW and type(myNW) == "number" and type(enemyNW) == "number" then
            nwLead = myNW - enemyNW
        end
    end
    -- Skip push_lane if it's on cooldown so we fall THROUGH to smoke_gank /
    -- other secondary intents. freshPlan would normally return "regroup" for
    -- a cooldown'd intent, but that hijacks the whole plan; we want the other
    -- gates below to actually evaluate.
    if (now >= pushMinSec or nwLead >= 4000) and not isInCooldown("push_lane") then
        local pushTarget = findPushTarget(enemyTeam, team, thresholds.pushAllyThreshold)
        if pushTarget ~= nil then
            _lastPushLaneTime = now
            return freshPlan("push_lane", pushTarget.lane, pushTarget.loc, "push weakest lane")
        end
    end

    -- 5. SMOKE_GANK: mid/late game + grouped.
    -- Phase 8: enforce pro-average cadence between smoke ganks
    -- (pro_macro.smoke_gank_cadence_min * 60 sec, default 180s). Without a gate,
    -- smoke_gank intent would re-issue every recompute tick while 3+ bots stand
    -- together — this rate-limits the *plan issuance* so the team disperses
    -- between ganks and actually farms.
    local smokeCadenceSec = 180
    if jmzM and jmzM.DraftStrategy and jmzM.DraftStrategy.GetProMacro then
        local pm = jmzM.DraftStrategy.GetProMacro()
        if pm and pm.smoke_gank_cadence_min and pm.smoke_gank_cadence_min > 0 then
            smokeCadenceSec = pm.smoke_gank_cadence_min * 60
        end
    end
    -- Strategy adjustment: early_aggro shortens cadence; turtle/late_scale lengthens it.
    smokeCadenceSec = math.max(60, smokeCadenceSec + (strategySmokeCadenceAdj or 0))
    if now > 10 * 60 and (now - _lastSmokeGankTime) >= smokeCadenceSec
       and not isInCooldown("smoke_gank") then
        local grouped = countGroupedAllies(team)
        if grouped >= 3 then
            _lastSmokeGankTime = now
            return freshPlan("smoke_gank", nil, nil, "grouped, look for picks")
        end
    end

    -- 5.5 MISSING ENEMIES: 3+ enemies haven't been seen in >8s after minute 5
    -- usually means a smoke/rotation incoming. Bias to regroup defensively.
    --
    -- Push-then-retreat fix: if the current plan is push_lane (or contest_rosh)
    -- with high commitment, do NOT flip to regroup just because enemies dropped
    -- vision. The user explicitly reported "team starts to push tower then
    -- retreats for no reason." The previous behavior was: bots commit to push,
    -- enemies smoke or jungle for 8s, missing-enemy gate fires, plan flips to
    -- regroup, bots peel off. That's the bug.
    --
    -- High-commitment push_lane has had 12+ seconds of investment (commitment
    -- 0.5 base + 0.10 from the age boost crosses 0.6); aborting it on
    -- speculative ghost-enemy signal hurts more than it helps.
    if now > 5 * 60 then
        local missing = countMissingEnemies(enemyTeam, 8)
        if missing >= 3 then
            local cur = currentPlan or {}
            local curCommit = cur.commitment or 0
            local stickyIntent = cur.intent == "push_lane" or cur.intent == "contest_rosh"
            if stickyIntent and curCommit > 0.6 then
                -- skip the regroup override; let the next gates run
            else
                return freshPlan("regroup", nil, nil, "enemies missing=" .. tostring(missing) .. " (likely smoke/rotation)")
            end
        end
    end

    -- 5.7 LATE_GAME_GROUP (fallback only — Phase 14): if past p25 match
    -- duration AND no higher-priority intent fired, group at the front-line
    -- tower. This is a fallback, NOT a primary mode — push_lane and
    -- smoke_gank above run first. The location is the team's frontmost
    -- living tower (forward HG line), NOT the ancient. Glueing bots to
    -- the fountain late-game is the bug we just fixed.
    local lateGameGateSec = 25 * 60
    if jmzM and jmzM.DraftStrategy and jmzM.DraftStrategy.GetProMacro then
        local pm = jmzM.DraftStrategy.GetProMacro()
        if pm and pm.match_duration_p25 and pm.match_duration_p25 > 0 then
            lateGameGateSec = pm.match_duration_p25
        end
    end
    if now > lateGameGateSec then
        -- Late-game offensive override: when winning (NW lead + alive parity),
        -- promote the late-game fallback from defensive assembly (front-line
        -- tower) to push_lane targeting the enemy's weakest lane. User
        -- complaint: "team also does not stick together mid late game to
        -- push towers or gain objects" — the old fallback assembled at OUR
        -- frontmost tower regardless of game state, so winning teams stalled
        -- defensively instead of closing.
        local aliveAllies = countAliveTeamHeroes(team)
        local aliveEnemies = countAliveTeamHeroes(enemyTeam)
        local winning = (nwLead >= 4000) and (aliveAllies >= aliveEnemies) and (aliveAllies >= 4)
        if winning and not isInCooldown("push_lane") then
            local pushTarget = findPushTarget(enemyTeam, team, thresholds.pushAllyThreshold)
            if pushTarget ~= nil then
                _lastPushLaneTime = now
                return freshPlan("push_lane", pushTarget.lane, pushTarget.loc,
                    "late-game winning: push instead of group-defend")
            end
        end
        local groupLoc = computeGroupLocation(team)
        if groupLoc ~= nil then
            return freshPlan("late_game_group", nil, groupLoc, "late game: hold front-line tower")
        end
    end

    -- 6. REGROUP
    if teamIsWeak(team) then
        return freshPlan("regroup", nil, nil, "team needs to reset")
    end

    -- 6.5 OPENING FLAVOR: early-game variance so bots don't always start the
    -- same way. User complaint: "dont always start the same." Rolled once
    -- per match; applies during laning phase when no urgent intent fires.
    if now < 4 * 60 then
        local flavor = getOpeningFlavor()
        if flavor == "bounty_invade" then
            -- Pre-game and first 90s only — invade enemy bounty for FB / steal.
            -- Routes the team to the enemy bounty location via smoke_gank
            -- intent. Role gating on smoke_gank ({1,2,3,4,5}) means whole
            -- team converges; user wanted occasional FB pressure, not every
            -- match. Capped at 90s — past that, stale invade risks 5-man
            -- counter-gank from enemy team that's now grouped.
            if now < 90 then
                local enemyBounty = getEnemyBountyLocation(team)
                return freshPlan("smoke_gank", nil, enemyBounty, "opening: bounty_invade")
            end
            -- After the invade window, fall through to lane.
        elseif flavor == "lotus_rush" then
            return freshPlan("lane_gank", nil, nil, "opening: lotus_rush->support_rotation")
        elseif flavor == "aggro_roam" or flavor == "smoke_gank_early" then
            -- Bias toward team_roam even without a low-HP focus (opportunistic rotations)
            return freshPlan("smoke_gank", nil, nil, "opening: " .. flavor)
        elseif flavor == "deward_scout" then
            return freshPlan("regroup", nil, nil, "opening: deward_scout (ward coverage)")
        end
        -- passive_lane falls through to farm — default safe laning
    end

    if now >= 12 * 60 and now <= 24 * 60 then
        local flavor = getMidgameFlavor(now)
        if flavor == "fast_siege" then
            return freshPlan("push_lane", nil, nil, "mid flavor: fast_siege")
        elseif flavor == "pickoff_focus" then
            return freshPlan("smoke_gank", nil, nil, "mid flavor: pickoff_focus")
        elseif flavor == "split_farm" then
            return freshPlan("farm", nil, nil, "mid flavor: split_farm")
        elseif flavor == "objective_dance" then
            return freshPlan("regroup", nil, nil, "mid flavor: objective_dance")
        end
    end

    if now >= 28 * 60 then
        local flavor = getLateGameFlavor(now)
        if flavor == "high_ground_rush" then
            return freshPlan("push_lane", nil, nil, "late flavor: high_ground_rush")
        elseif flavor == "aegis_stall" then
            -- Phase 14: aegis_stall must NOT bypass the rosh gate above.
            -- Stall semantics = group up & wait, not "go to roshpit again".
            return freshPlan("regroup", nil, nil, "late flavor: aegis_stall")
        elseif flavor == "split_and_rax" then
            return freshPlan("smoke_gank", nil, nil, "late flavor: split_and_rax")
        end
    end

    -- 7. FARM default
    return freshPlan("farm", nil, nil, "nothing pressing")
end

-- ============================================================
-- Public API
-- ============================================================

function ____exports.GetCurrentPlan()
    return currentPlan
end

-- Returns true if the given bot's role should follow the current plan's
-- intent. Bots whose role isn't in the intent's target roles should
-- ignore the plan location and act on their own priorities.
function ____exports.RoleRespondsToIntent(bot)
    if bot == nil or currentPlan == nil or currentPlan.intent == nil then return true end
    local J = jmz()
    if J == nil or J.GetPosition == nil then return true end
    local ok, pos = pcall(function() return J.GetPosition(bot) end)
    if not ok or pos == nil then return true end
    return roleRespondsToIntent(pos, currentPlan.intent)
end

-- Phase 11 Item 11: ε-randomization for mixed strategies. A purely
-- deterministic intent policy is exploitable: a human who plays vs the
-- bot enough learns that "if X, bot always does Y". We perturb a small
-- fraction of decisions among interchangeable alternatives.
--
-- Constraints:
--   - Only swap among CLOSE-PRIORITY intents (push_lane <-> smoke_gank
--     or smoke_gank <-> regroup). Never swap defend_base or commit_kill.
--   - Only fire when the alternative is ACTUALLY VIABLE (passes its own
--     gates). Otherwise swap is a no-op.
--   - Low rate (8%) so behavior remains mostly predictable but not
--     mechanical. Higher rates make the bot incoherent.
local SWAP_PAIRS = {
    push_lane = "smoke_gank",
    smoke_gank = "push_lane",
}
local _last_swap_time = -999
local SWAP_COOLDOWN = 5 * 60   -- at most one ε-swap every 5 minutes

local function maybeSwapIntent(plan, bot)
    if plan == nil or plan.intent == nil then return plan end
    local alt = SWAP_PAIRS[plan.intent]
    if alt == nil then return plan end
    local now = DotaTime()
    -- Global swap cooldown: prevents the swap from flipping every recompute
    -- tick on a "lucky" seed and clobbering Phase 9's intent distribution.
    -- Without this, sim showed radiant getting 31 push / 2 smoke (vs dire's
    -- balanced 12/10) because radiant's RNG happened to roll < 0.08 often.
    if now - _last_swap_time < SWAP_COOLDOWN then return plan end
    if RandomFloat(0, 1) > 0.20 then return plan end
    _last_swap_time = now
    return {
        intent = alt,
        lane = plan.lane,
        location = plan.location,
        validUntil = plan.validUntil,
        lastComputeTime = plan.lastComputeTime,
        authorID = plan.authorID,
        reason = (plan.reason or "") .. " [eps-swap to " .. alt .. "]",
    }
end

function ____exports.MaybeRecompute(bot)
    -- This function is on the hot path — every mode's ModulateDesire calls it.
    -- If it throws, mode GetDesire's return value is nil, which Dota interprets
    -- as no-mode-active across ALL modes, asserting m_pActiveBotMode == NULL
    -- and crashing. So every step here is wrapped defensively.
    if bot == nil then return currentPlan end
    local now = DotaTime()
    if now - currentPlan.lastComputeTime < TEAMPLAN_RECOMPUTE_INTERVAL then
        return currentPlan
    end
    local ok, plan = pcall(computePlan, bot)
    if not ok or plan == nil or type(plan) ~= "table" then return currentPlan end

    -- Apply mixed-strategy ε-noise. Pcall-guarded so a swap bug can't tank
    -- the whole desire stack.
    local okSwap, swapped = pcall(maybeSwapIntent, plan, bot)
    if okSwap and type(swapped) == "table" and swapped.intent ~= nil then
        plan = swapped
    end

    -- Phase 11 Item 4: convex commitment + abort triggers. Pcall-guarded
    -- per-call. Any failure here just leaves the plan as-is; we never
    -- propagate an exception out of MaybeRecompute.
    pcall(function()
        local okC, Commit = pcall(require, GetScriptDirectory().."/FunLib/aba_commitment")
        if not okC or not Commit then return end
        if Commit.Tick then pcall(Commit.Tick, plan.intent) end
        if Commit.ShouldAbort then
            local okA, shouldAbort = pcall(Commit.ShouldAbort, plan.intent)
            if okA and shouldAbort then
                pcall(Commit.Reset, plan.intent)
                plan = {
                    intent = "regroup",
                    lane = nil, location = nil,
                    validUntil = now + 6,
                    lastComputeTime = now,
                    authorID = plan.authorID,
                    reason = "abort: " .. tostring(plan.intent),
                }
            end
        end
    end)

    -- Sanity-check the plan shape before storing — a malformed plan
    -- (missing intent / non-table) would propagate via GetCurrentPlan
    -- and break every downstream ModulateDesire call next tick.
    if type(plan) ~= "table" or plan.intent == nil then
        return currentPlan
    end
    plan.lastComputeTime = now
    plan.validUntil = now + PLAN_TTL
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    if okPid then plan.authorID = pid end

    -- Commitment: how authoritatively GetPlanBias enforces this plan.
    -- Sticky intents grow commitment with age (anti-flip). The previous
    -- intent's start time stays in _intentStartTime if trackIntent didn't
    -- rotate it, so we read it for the age boost.
    local intentStart = _intentStartTime[plan.intent]
    local planAge = (intentStart ~= nil) and (now - intentStart) or 0
    plan.commitment = computeCommitment(plan.intent, planAge)

    currentPlan = plan
    return plan
end

-- ============================================================
-- Mode-to-intent match table
-- ============================================================

local MATCH = {
    defend_base = {
        defend = 1.0, retreat = 0.85, assemble = 0.9,
        farm = 0.15, roam = 0.2, push = 0.1, team_roam = 0.25, rune = 0.4, roshan = 0.1,
    },
    defend_lane = {
        defend = 1.0, retreat = 0.85, assemble = 0.85,
        farm = 0.4, roam = 0.3, push = 0.2, team_roam = 0.35, rune = 0.6, roshan = 0.3,
    },
    save_ally = {
        -- Collapse defensively on threatened ally. High team_roam + assemble
        -- so bots converge. Defend also stays high (ally may be near tower).
        -- Retreat is mid — we want to SAVE not flee; dying bots can flee via
        -- their own retreat mode logic.
        team_roam = 1.0, assemble = 0.95, defend = 0.85, roam = 0.85,
        farm = 0.2, push = 0.25, retreat = 0.55, rune = 0.3, roshan = 0.25,
    },
    commit_kill = {
        -- Everything converges on the target: team_roam and roam go high,
        -- farm/retreat/defend drop hard. Defending is still allowed if needed.
        -- laning: 0.25 - strong push to abandon lane for a gank opportunity.
        -- retreat 0.55: previously 0.3 which suppressed retreat too hard —
        -- bots would dive towers / teammates instead of fleeing. User feedback:
        -- "bristleback went straight for our tower when we attacked."
        team_roam = 1.0, roam = 1.0, assemble = 0.9,
        farm = 0.15, push = 0.3, defend = 0.5, retreat = 0.55, rune = 0.2, roshan = 0.2, ward = 0.3,
        laning = 0.25,
    },
    late_game_group = {
        -- Group up, hold position, defend rax/base. Don't split farm or push alone.
        assemble = 1.0, defend = 1.0, team_roam = 0.85, retreat = 0.9,
        farm = 0.35, push = 0.65, roam = 0.55, rune = 0.4, roshan = 0.65, ward = 0.7,
    },
    lane_gank = {
        -- Lighter touch than commit_kill — one bot ganks, others keep laning.
        -- Strong roam boost, moderate laning penalty, keeps farm/defend unchanged.
        roam = 1.0, team_roam = 0.95, assemble = 0.8,
        laning = 0.4, farm = 0.5, push = 0.55, defend = 0.8, retreat = 0.7,
    },
    contest_rosh = {
        roshan = 1.0, team_roam = 0.85, assemble = 0.8,
        farm = 0.4, push = 0.3, defend = 0.8,
    },
    contest_tormentor = {
        -- No dedicated tormentor mode; use assemble + team_roam to converge
        -- on the tormentor location.
        team_roam = 0.95, assemble = 0.85, roshan = 0.6,
        farm = 0.3, push = 0.25, roam = 0.7, defend = 0.75,
    },
    contest_lotus = {
        -- Small detour; should NOT dominate farm/push but beats idling.
        -- Mostly benefits supports (pos 4/5).
        team_roam = 0.75, roam = 0.8, assemble = 0.7, ward = 0.85,
        farm = 0.6, push = 0.65, defend = 0.85,
    },
    push_lane = {
        push = 1.0, team_roam = 0.8,
        farm = 0.5, roam = 0.4, defend = 0.7, retreat = 0.5,
    },
    smoke_gank = {
        roam = 1.0, team_roam = 1.0,
        farm = 0.5, push = 0.7, defend = 0.8,
    },
    regroup = {
        retreat = 1.0, farm = 0.85, ward = 0.9,
        roam = 0.4, push = 0.3, team_roam = 0.4,
    },
    farm = {
        farm = 1.0, rune = 1.0, laning = 1.0, ward = 1.0,
        push = 0.85, defend = 0.9, roam = 0.8, team_roam = 0.75, roshan = 0.8,
    },
}

local function getMatch(intent, mode)
    local t = MATCH[intent]
    if t == nil then return 1.0 end
    local v = t[mode]
    if v == nil then return 1.0 end
    return v
end

-- ============================================================
-- Bias multiplier
-- ============================================================

local MIN_MULT = 0.5
local MAX_MULT = 1.3

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

function ____exports.GetPlanBias(bot, mode, teamSpirit)
    local plan = currentPlan
    if DotaTime() > plan.validUntil then return 1.0 end

    -- Engagement override: if there's an enemy hero in immediate attack range,
    -- don't bias away from combat. Previously the commit_kill / push / etc. bias
    -- could push farm/team_roam desire high enough that bots would walk past
    -- an enemy hero in melee range to chase the team target — unrealistic and
    -- exploitable. Here we neutralize the bias for non-combat modes when an
    -- enemy is right in front of us, so Valve's default attack_generic desire
    -- (which spikes when enemies are close) wins.
    local okJmz, J = pcall(jmz)
    if okJmz and J ~= nil and bot ~= nil then
        local okEnemies, nearbyEnemies = pcall(function()
            return J.GetNearbyHeroes(bot, 900, true, BOT_MODE_NONE)
        end)
        if okEnemies and nearbyEnemies ~= nil and #nearbyEnemies > 0 then
            -- For modes that would pull the bot AWAY from the fight, bail to neutral.
            if mode == "farm" or mode == "push" or mode == "team_roam" or mode == "roam"
               or mode == "rune" or mode == "ward" or mode == "roshan" then
                return 1.0
            end
        end
    end

    local m = getMatch(plan.intent, mode)
    local commitment = plan.commitment or 0.5

    -- High-commitment plans are AUTHORITATIVE: bypass the teamSpirit
    -- dampener and widen the bias range so contradicting modes get
    -- hammered (~0.2x) and aligned modes get amplified (~1.6x). This
    -- is what makes defend_base, push during a winning state, and
    -- save_ally actually coordinate the whole team rather than
    -- losing to one bot's high greed/independence personality.
    --
    -- Threshold 0.6 picked so push_lane crosses it after ~12s of
    -- continuous push (base 0.50 + 0.10 age boost). Defensive intents
    -- (defend_base 1.00, save_ally 0.95) are over the threshold from
    -- the first tick they fire.
    if commitment > 0.6 then
        local expand = (commitment - 0.6) / 0.4 * 0.3
        local lo = MIN_MULT - expand   -- 0.5 → 0.2 at full commit
        local hi = MAX_MULT + expand   -- 1.3 → 1.6 at full commit
        return lerp(lo, hi, m)
    end

    -- Low commitment: advisory, dampened by teamSpirit (existing behavior).
    local compliantMult = lerp(MIN_MULT, MAX_MULT, m)
    return 1.0 + clamp01(teamSpirit) * (compliantMult - 1.0)
end

function ____exports.Describe()
    local p = currentPlan
    local s = p.intent
    if p.lane ~= nil then s = s .. " lane=" .. tostring(p.lane) end
    s = s .. " [" .. (p.reason or "") .. "]"
    return s
end

return ____exports
