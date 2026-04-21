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

local function findPushTarget(enemyTeam, team)
    local aliveAllies = countAliveTeamHeroes(team)
    if aliveAllies < 4 then return nil end
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
                if nearAllies ~= nil and #nearAllies >= 2 then
                    return freshPlan("commit_kill", nil, focusLoc,
                        "focus=" .. (target.reason or "?") .. " allies=" .. tostring(#nearAllies))
                end
            end
        end
    end

    -- 3. CONTEST_ROSH: rosh alive, past laning, numbers advantage
    local okRosh, roshAlive = pcall(function() return jmz().IsRoshanAlive() end)
    if okRosh and roshAlive and now > 15 * 60 then
        local aliveAllies = countAliveTeamHeroes(team)
        local aliveEnemies = countAliveTeamHeroes(enemyTeam)
        if aliveAllies >= 4 and aliveAllies >= aliveEnemies then
            return freshPlan("contest_rosh", nil, nil, "rosh up, we have numbers")
        end
    end

    -- 4. PUSH_LANE: weakest enemy lane + we have people
    local pushTarget = findPushTarget(enemyTeam, team)
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
        team_roam = 1.0, roam = 1.0, assemble = 0.9,
        farm = 0.15, push = 0.3, defend = 0.5, retreat = 0.3, rune = 0.2, roshan = 0.2, ward = 0.3,
    },
    contest_rosh = {
        roshan = 1.0, team_roam = 0.85, assemble = 0.8,
        farm = 0.4, push = 0.3, defend = 0.8,
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
