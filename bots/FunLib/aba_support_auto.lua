--[[ Support autopilot — stacking + pulling timings.

     Real Dota: pos 4/5 supports stack neutral camps at :53-:55 of each
     minute (creeps spawn at :00, you pull them out of spawn box right
     before, they regen + a new spawn appears = 2 stacks). And pos 5
     pulls at :15/:45/:53 to reset lane creep equilibrium.

     This module exposes timing helpers + nearest-camp lookup. mode_farm
     consults them to bias pos 4/5 toward camps during stacking windows. ]]
local ____exports = {}

local _jmz = nil
local function jmz()
    if _jmz == nil then
        _jmz = require(GetScriptDirectory().."/FunLib/jmz_func")
    end
    return _jmz
end

-- ============================================================
-- Timing windows
-- ============================================================

-- Stacking window per camp type (seconds-into-minute when bot should be
-- attacking the camp). Ancient camp needs ~5s lead, large needs ~7s.
local STACK_WINDOW_START = 50
local STACK_WINDOW_END = 56

-- Pulling: at :15 (small first wave) and :45 (third wave) of each
-- minute. Pos 5 pulls camps to disrupt lane creep equilibrium.
local PULL_WINDOWS = {
    { start = 12, ['end'] = 18 },
    { start = 42, ['end'] = 48 },
}

local function secondsIntoMinute(now)
    local n = math.floor(now)
    return n - math.floor(n / 60) * 60
end

function ____exports.IsStackingWindow(now)
    if now == nil then now = DotaTime() end
    if now < 60 then return false end
    local s = secondsIntoMinute(now)
    return s >= STACK_WINDOW_START and s <= STACK_WINDOW_END
end

function ____exports.IsPullingWindow(now)
    if now == nil then now = DotaTime() end
    if now < 30 then return false end
    local s = secondsIntoMinute(now)
    for i = 1, #PULL_WINDOWS do
        local w = PULL_WINDOWS[i]
        if s >= w.start and s <= w['end'] then return true end
    end
    return false
end

-- ============================================================
-- Camp locations (hardcoded; standard Dota 2 map)
-- These are approximate centers for the major neutral camps per side.
-- Stacking targets: ancient (largest) + large camps closest to safelane.
-- ============================================================

local RADIANT_STACK_CAMPS = {
    Vector(-3680,  1980, 256),  -- Radiant ancient camp
    Vector(-1632,  -200, 256),  -- Radiant large camp (mid jungle)
    Vector(-2048,  1568, 256),  -- Radiant medium offlane jungle
    Vector(-4288,  -416, 256),  -- Radiant safelane large
}

local DIRE_STACK_CAMPS = {
    Vector( 3712, -2016, 256),  -- Dire ancient camp
    Vector( 1568,   192, 256),  -- Dire large camp (mid jungle)
    Vector( 2240, -1440, 256),  -- Dire medium offlane jungle
    Vector( 4256,   544, 256),  -- Dire safelane large
}

-- Pulling camps: small/medium camps near each lane.
local RADIANT_PULL_CAMPS = {
    Vector(-4096, -416,  256),  -- Safelane small pull
    Vector(-1632,  -200, 256),  -- Mid jungle (deep pull from safelane)
}
local DIRE_PULL_CAMPS = {
    Vector( 4288,   544, 256),  -- Safelane small pull
    Vector( 1568,   192, 256),  -- Mid jungle
}

local function distLocLoc(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function getCampList(team, kind)
    if team == TEAM_RADIANT then
        if kind == "stack" then return RADIANT_STACK_CAMPS
        else return RADIANT_PULL_CAMPS end
    else
        if kind == "stack" then return DIRE_STACK_CAMPS
        else return DIRE_PULL_CAMPS end
    end
end

function ____exports.GetNearestStackCamp(bot)
    if bot == nil then return nil end
    local botLoc = bot:GetLocation()
    local team = GetTeam()
    local camps = getCampList(team, "stack")
    local best = nil
    local bestD = 99999
    for i = 1, #camps do
        local d = distLocLoc(botLoc, camps[i])
        if d < bestD then bestD = d; best = camps[i] end
    end
    return best, bestD
end

function ____exports.GetNearestPullCamp(bot)
    if bot == nil then return nil end
    local botLoc = bot:GetLocation()
    local team = GetTeam()
    local camps = getCampList(team, "pull")
    local best = nil
    local bestD = 99999
    for i = 1, #camps do
        local d = distLocLoc(botLoc, camps[i])
        if d < bestD then bestD = d; best = camps[i] end
    end
    return best, bestD
end

-- ============================================================
-- Eligibility
-- ============================================================

-- Pos 4 and 5 should stack. Pos 1-3 should be farming hard.
function ____exports.IsStackerRole(bot)
    local J = jmz()
    if J == nil or J.GetPosition == nil then return false end
    local ok, pos = pcall(function() return J.GetPosition(bot) end)
    if not ok or pos == nil then return false end
    return pos == 4 or pos == 5
end

-- Pos 5 typically pulls in safelane. Pos 4 sometimes pulls offlane.
function ____exports.IsPullerRole(bot)
    local J = jmz()
    if J == nil or J.GetPosition == nil then return false end
    local ok, pos = pcall(function() return J.GetPosition(bot) end)
    if not ok or pos == nil then return false end
    return pos == 5 or pos == 4
end

-- Don't stack/pull if engaged in a fight or running for life.
function ____exports.IsBusy(bot)
    if bot == nil then return true end
    if not bot:IsAlive() then return true end
    local J = jmz()
    if J == nil then return false end
    local hp = J.GetHP(bot)
    if hp ~= nil and hp < 0.5 then return true end
    if bot:WasRecentlyDamagedByAnyHero(3) then return true end
    local enemies = J.GetNearbyHeroes(bot, 1100, true, BOT_MODE_NONE)
    if enemies ~= nil and #enemies > 0 then return true end
    -- Also bail if team plan is anything urgent
    if J.TeamPlan ~= nil and J.TeamPlan.GetCurrentPlan ~= nil then
        local plan = J.TeamPlan.GetCurrentPlan()
        if plan ~= nil then
            local urgent = {
                defend_base=true, defend_lane=true, save_ally=true,
                commit_kill=true, lane_gank=true,
            }
            if urgent[plan.intent] then return true end
        end
    end
    return false
end

-- ============================================================
-- One-shot recommendation
--
-- Returns (mode, location, motive) where mode is "stack" / "pull" / nil.
-- Hook this from mode_farm Think to detour pos 4/5 to a camp at the right time.
-- ============================================================

function ____exports.GetSupportTask(bot)
    if not ____exports.IsStackerRole(bot) and not ____exports.IsPullerRole(bot) then
        return nil
    end
    if ____exports.IsBusy(bot) then return nil end

    local now = DotaTime()
    if ____exports.IsStackingWindow(now) and ____exports.IsStackerRole(bot) then
        local loc, dist = ____exports.GetNearestStackCamp(bot)
        if loc ~= nil and dist <= 4500 then
            return "stack", loc, string.format("stacking @ :%02d", math.floor(secondsIntoMinute(now)))
        end
    end

    if ____exports.IsPullingWindow(now) and ____exports.IsPullerRole(bot) then
        local loc, dist = ____exports.GetNearestPullCamp(bot)
        if loc ~= nil and dist <= 3500 then
            return "pull", loc, string.format("pulling @ :%02d", math.floor(secondsIntoMinute(now)))
        end
    end

    return nil
end

function ____exports.Describe(bot)
    if bot == nil then return "no-bot" end
    local task, loc, motive = ____exports.GetSupportTask(bot)
    if task == nil then return "no task" end
    return motive or task
end

return ____exports
