-- Dewarding: track and remove enemy wards.
--
-- Without this, bots place wards but never seek out and remove enemy wards,
-- and the enemy team's vision over our jungle / safelane is uncontested.
-- User feedback: "bots dont de-ward."
--
-- Strategy:
--   1. Maintain a list of SUSPECTED enemy ward locations. Sources:
--      a. Symmetric-mirror common spots (every map side has known typical
--         wards — e.g. radiant near top runes, dire equivalent).
--      b. Spots where one of our heroes has been recently seen by enemies
--         (vision came from somewhere — likely a ward in the area).
--      c. Spots that our seen-list confirms an enemy ward is at (the
--         engine surfaces visible enemy wards via UNIT_LIST_ENEMY_WARDS).
--   2. When a support has a sentry available AND has time AND a suspect is
--      reachable, walk there and place a sentry. The sentry's truesight
--      reveals the enemy obs (if present), then bots' Valve-native attack
--      target picker handles the actual destroy (wards count as units).
--
-- Exposed as J.Deward.

local ____exports = {}

local jmz = require(GetScriptDirectory() .. "/FunLib/jmz_func")

-- Common enemy ward spots (mirrored from the team's perspective). These
-- are the spots an OPPONENT typically places observer wards against us.
-- For Radiant, the targets are Dire's typical ward locations; for Dire,
-- it's the reverse.

local DIRE_WARD_SPOTS = {
    Vector(7456, 5824, 384),    -- top-runes-side cliff
    Vector(4992, 4288, 384),    -- ancients camp side
    Vector(2880, 5440, 384),    -- top jungle entrance
    Vector(7104, 1408, 384),    -- bottom-rune jungle
    Vector(5440, -2944, 384),   -- bottom safelane jungle
    Vector(1216, -4928, 384),   -- bot rune cliff
    Vector(4480, -2496, 384),   -- mid bot side hill
    Vector(2240, -1664, 384),   -- mid hill
}

local RADIANT_WARD_SPOTS = {
    Vector(-7456, -5824, 384),
    Vector(-4992, -4288, 384),
    Vector(-2880, -5440, 384),
    Vector(-7104, -1408, 384),
    Vector(-5440, 2944, 384),
    Vector(-1216, 4928, 384),
    Vector(-4480, 2496, 384),
    Vector(-2240, 1664, 384),
}

-- State per-team (per-bot's-team). Tracks which suspected spots we've
-- recently swept, so we don't keep walking back.
local _swept = {}

local function getSweptState(team)
    if _swept[team] == nil then _swept[team] = {} end
    return _swept[team]
end

local function spotKey(loc)
    return string.format("%d_%d", math.floor(loc.x / 100), math.floor(loc.y / 100))
end

-- Returns the list of suspected enemy ward locations for our team.
-- These are spots OUR team should consider sweeping with sentries.
function ____exports.GetSuspectedSpots(team)
    if team == nil then team = GetTeam() end
    -- We sweep ENEMY ward spots (which sit on enemy side or in their jungle).
    -- For Radiant team, the ENEMY spots are typically Dire-side coords;
    -- for Dire team, the reverse.
    local pool
    if team == TEAM_RADIANT then
        pool = DIRE_WARD_SPOTS
    else
        pool = RADIANT_WARD_SPOTS
    end

    local now = DotaTime()
    local suspects = {}
    local swept = getSweptState(team)

    -- Add visible enemy wards (engine-surfaced)
    local enemyWards = GetUnitList(UNIT_LIST_ENEMY_WARDS)
    if enemyWards ~= nil then
        for _, w in pairs(enemyWards) do
            if w ~= nil and not w:IsNull() and w:IsAlive()
               and w:GetUnitName() == "npc_dota_observer_wards" then
                table.insert(suspects, {
                    location = w:GetLocation(),
                    confirmed = true,
                    last_seen = now,
                })
            end
        end
    end

    -- Add common-spot suspects (skip those swept in the last 5 minutes).
    for _, loc in ipairs(pool) do
        local key = spotKey(loc)
        local lastSwept = swept[key] or -999
        if (now - lastSwept) > 300 then
            table.insert(suspects, {
                location = loc,
                confirmed = false,
                last_seen = 0,
            })
        end
    end

    return suspects
end

-- Mark a spot as "swept" — call when bot plants a sentry near it.
function ____exports.MarkSwept(team, loc)
    if team == nil or loc == nil then return end
    local swept = getSweptState(team)
    swept[spotKey(loc)] = DotaTime()
end

-- Pick the highest-priority suspect within reach of the bot.
-- "Within reach" = within 4500u walking distance, not currently in danger.
function ____exports.GetReachableSuspect(bot)
    if bot == nil or not bot:IsAlive() then return nil end
    if bot:DistanceFromFountain() < 200 then return nil end

    local team = bot:GetTeam()
    local suspects = ____exports.GetSuspectedSpots(team)

    local best = nil
    local bestScore = math.huge
    for _, s in ipairs(suspects) do
        local dist = GetUnitToLocationDistance(bot, s.location)
        if dist < 4500 then
            -- Prefer confirmed wards (saw them) and closer suspects.
            local confirmedBonus = s.confirmed and -2000 or 0
            local score = dist + confirmedBonus
            if score < bestScore then
                bestScore = score
                best = s
            end
        end
    end
    return best
end

-- Check if a sweep is worth attempting now.
-- Don't sweep if: enemies near, low HP, has higher-priority work.
function ____exports.IsGoodTimeToSweep(bot)
    if bot == nil or not bot:IsAlive() then return false end
    if jmz.GetHP(bot) < 0.5 then return false end
    if bot:WasRecentlyDamagedByAnyHero(4.0) then return false end

    local nEnemies = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE)
    if nEnemies and #nEnemies >= 1 then return false end

    -- Don't sweep during base defense or ally-save situations
    local mode = bot:GetActiveMode()
    if mode == BOT_MODE_RETREAT or mode == BOT_MODE_DEFEND_ALLY then return false end
    if jmz.IsRetreating(bot) then return false end

    return true
end

function ____exports.Describe(bot)
    if bot == nil then return "deward: no bot" end
    local s = ____exports.GetReachableSuspect(bot)
    if s == nil then return "deward: no reachable suspect" end
    return string.format("deward: target=(%d,%d) confirmed=%s",
        s.location.x, s.location.y, tostring(s.confirmed))
end

return ____exports
