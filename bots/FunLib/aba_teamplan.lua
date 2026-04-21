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
    -- Lotus pools refresh every ~3 min after pickup. Without a direct API,
    -- we bias toward contesting during laning + early mid-game when lotuses
    -- matter most (sustain for the safelane / offlane).
    if now < 60 or now > 14 * 60 then return false, nil end
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

-- Count enemies whose last-seen is stale (>= staleSeconds). High stale count
-- often means they're smoked up or rotating — likely gank incoming.
local function countMissingEnemies(enemyTeam, staleSeconds)
    local players = GetTeamPlayers(enemyTeam)
    local missing = 0
    for i = 1, #players do
        local pid = players[i]
        if IsHeroAlive(pid) then
            local info = GetHeroLastSeenInfo(pid)
            if info == nil or info[1] == nil then
                missing = missing + 1
            elseif info[1].time_since_seen == nil or info[1].time_since_seen >= staleSeconds then
                missing = missing + 1
            end
        end
    end
    return missing
end

-- ============================================================
-- Intent computation
-- ============================================================

local function freshPlan(intent, lane, loc, reason)
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

local function computePlan(bot)
    local team = GetTeam()
    local enemyTeam = GetOpposingTeam()
    local now = DotaTime()

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

    -- 1. DEFEND_BASE: enemies near our Ancient
    local ourAncient = GetAncient(team)
    if ourAncient ~= nil then
        local enemiesAtAncient = countEnemyHeroesNear(ourAncient:GetLocation(), 2500)
        if enemiesAtAncient >= 1 then
            return freshPlan("defend_base", nil, ourAncient:GetLocation(), "enemies near ancient")
        end
    end

    -- 2. DEFEND_LANE: T1/T2 under active attack
    local threat = findThreatenedLane(team)
    if threat ~= nil then
        return freshPlan("defend_lane", threat.lane, threat.loc, "lane under attack")
    end

    -- 2.5 COMMIT_KILL: focus target exists + ≥2 allies near focus
    -- This fires between defend and contest_rosh so a juicy pick takes priority
    -- over farming/pushing but not over base defense.
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
                if nearAllies ~= nil and #nearAllies >= thresholds.commitAllyThreshold then
                    return freshPlan("commit_kill", nil, focusLoc,
                        "focus=" .. (target.reason or "?") .. " allies=" .. tostring(#nearAllies) .. "/" .. tostring(thresholds.commitAllyThreshold))
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

    -- 3. CONTEST_ROSH: rosh alive, past early game, numbers favorable.
    -- Loosened from 15min/4-allies to 12min/3-allies; also fires when enemies
    -- are mostly dead (post-teamfight push for rosh).
    local okRosh, roshAlive = pcall(function() return jmz().IsRoshanAlive() end)
    if okRosh and roshAlive and now > 12 * 60 then
        local aliveAllies = countAliveTeamHeroes(team)
        local aliveEnemies = countAliveTeamHeroes(enemyTeam)
        if aliveAllies >= thresholds.roshAllyThreshold and aliveAllies >= aliveEnemies then
            local roshLoc = jmz().GetCurrentRoshanLocation and jmz().GetCurrentRoshanLocation() or nil
            local reason = "rosh up, allies=" .. tostring(aliveAllies) .. "/" .. tostring(thresholds.roshAllyThreshold)
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

    -- 4. PUSH_LANE: weakest enemy lane + we have people (threshold adapts to pressure)
    local pushTarget = findPushTarget(enemyTeam, team, thresholds.pushAllyThreshold)
    if pushTarget ~= nil then
        return freshPlan("push_lane", pushTarget.lane, pushTarget.loc, "push weakest lane")
    end

    -- 5. SMOKE_GANK: mid/late game + grouped
    if now > 10 * 60 then
        local grouped = countGroupedAllies(team)
        if grouped >= 3 then
            return freshPlan("smoke_gank", nil, nil, "grouped, look for picks")
        end
    end

    -- 5.5 MISSING ENEMIES: 3+ enemies haven't been seen in >8s after minute 5
    -- usually means a smoke/rotation incoming. Bias to regroup defensively.
    if now > 5 * 60 then
        local missing = countMissingEnemies(enemyTeam, 8)
        if missing >= 3 then
            return freshPlan("regroup", nil, nil, "enemies missing=" .. tostring(missing) .. " (likely smoke/rotation)")
        end
    end

    -- 6. REGROUP
    if teamIsWeak(team) then
        return freshPlan("regroup", nil, nil, "team needs to reset")
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

function ____exports.MaybeRecompute(bot)
    if bot == nil then return currentPlan end
    local now = DotaTime()
    if now - currentPlan.lastComputeTime < TEAMPLAN_RECOMPUTE_INTERVAL then
        return currentPlan
    end
    local ok, plan = pcall(computePlan, bot)
    if not ok or plan == nil then return currentPlan end
    plan.lastComputeTime = now
    plan.validUntil = now + PLAN_TTL
    local okPid, pid = pcall(function() return bot:GetPlayerID() end)
    if okPid then plan.authorID = pid end
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
    commit_kill = {
        -- Everything converges on the target: team_roam and roam go high,
        -- farm/retreat/defend drop hard. Defending is still allowed if needed.
        -- laning: 0.25 - strong push to abandon lane for a gank opportunity.
        team_roam = 1.0, roam = 1.0, assemble = 0.9,
        farm = 0.15, push = 0.3, defend = 0.5, retreat = 0.3, rune = 0.2, roshan = 0.2, ward = 0.3,
        laning = 0.25,
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
