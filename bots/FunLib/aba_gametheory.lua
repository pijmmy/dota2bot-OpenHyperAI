--[[ Game-theoretic adjustments on top of the team-plan.
     Tracks networth / level pressure and ult readiness, exposes them as
     signals that team-plan and mode hooks use to adapt strategy.

     Paired with TS source at typescript/bots/FunLib/aba_gametheory.ts.
     See ARCHITECTURE.md section 19. ]]
local ____exports = {}

local _jmz = nil
local function jmz()
    if _jmz == nil then
        _jmz = require(GetScriptDirectory().."/FunLib/jmz_func")
    end
    return _jmz
end

-- ============================================================
-- Strategic pressure: -1 (way behind) .. +1 (way ahead)
-- ============================================================

local RECOMPUTE_INTERVAL = 2.0
local pressureCache = { value = 0, lastUpdate = -999 }

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function ____exports.GetStrategicPressure()
    local now = DotaTime()
    if now - pressureCache.lastUpdate < RECOMPUTE_INTERVAL then
        return pressureCache.value
    end
    local J = jmz()
    -- Networth delta: 20k lead = +1.0, 20k behind = -1.0
    -- J.GetInventoryNetworth() returns (myNW, enemyNW) as multi-return; pcall captures all.
    local nwPressure = 0
    local okNW, myNW, enemyNW = pcall(function() return J.GetInventoryNetworth() end)
    if okNW and myNW ~= nil and enemyNW ~= nil then
        nwPressure = clamp((myNW - enemyNW) / 20000, -1, 1)
    end
    -- Level delta: 5-level lead = +1.0
    local lvlPressure = 0
    local okLvl, myLvl = pcall(function() return J.GetAverageLevel(false) end)
    local okELvl, enemyLvl = pcall(function() return J.GetAverageLevel(true) end)
    if okLvl and okELvl and myLvl ~= nil and enemyLvl ~= nil then
        lvlPressure = clamp((myLvl - enemyLvl) / 5, -1, 1)
    end
    local value = nwPressure * 0.7 + lvlPressure * 0.3
    pressureCache.value = value
    pressureCache.lastUpdate = now
    return value
end

-- ============================================================
-- Ult readiness: count team members with ult available
-- ============================================================

local ultCache = { value = 0, lastUpdate = -999 }

function ____exports.GetUltReadiness()
    local now = DotaTime()
    if now - ultCache.lastUpdate < RECOMPUTE_INTERVAL then
        return ultCache.value
    end
    local ready = 0
    for i = 1, 5 do
        local ok, m = pcall(function() return GetTeamMember(i) end)
        if ok and m ~= nil and m:IsAlive() then
            -- Ult is always at slot 5 (index 5 in Lua 1-based, or via ability list index 6 by convention)
            local okAbil, ult = pcall(function() return m:GetAbilityInSlot(5) end)
            if okAbil and ult ~= nil and not ult:IsNull() and ult:IsTrained()
               and ult:GetCooldownTimeRemaining() < 2
               and m:GetMana() >= ult:GetManaCost() then
                ready = ready + 1
            end
        end
    end
    ultCache.value = ready
    ultCache.lastUpdate = now
    return ready
end

-- ============================================================
-- Combined aggression multiplier: what to scale commit/push thresholds by.
-- ============================================================

--[[ Returns a table of threshold multipliers for team-plan conditions.
     `commitAllyThreshold` — how many allies near focus before commit fires
        (default 2; when ahead, 1; when behind, 3)
     `pushAllyThreshold`  — allies alive for push_lane (default 4)
     `roshAllyThreshold`  — allies alive for contest_rosh (default 3)
     `tormentorLevelThreshold` — avg level for contest_tormentor (default 10) ]]
function ____exports.GetThresholds()
    local pressure = ____exports.GetStrategicPressure()
    local ultReady = ____exports.GetUltReadiness()

    local t = {
        commitAllyThreshold = 2,
        pushAllyThreshold = 4,
        roshAllyThreshold = 3,
        tormentorLevelThreshold = 10,
        pressure = pressure,
        ultReady = ultReady,
    }

    -- Ahead: press the advantage
    if pressure > 0.3 then
        t.commitAllyThreshold = 1
        t.pushAllyThreshold = 3
        t.roshAllyThreshold = 2
    elseif pressure < -0.3 then
        -- Behind: be conservative
        t.commitAllyThreshold = 3
        t.pushAllyThreshold = 5
        t.roshAllyThreshold = 4
    end

    -- Ult-heavy team: commits and pushes are cheaper (hard disables available)
    if ultReady >= 3 then
        t.commitAllyThreshold = math.max(1, t.commitAllyThreshold - 1)
        t.pushAllyThreshold = math.max(3, t.pushAllyThreshold - 1)
    end
    -- Naked team (no big ults): play safer
    if ultReady == 0 then
        t.commitAllyThreshold = t.commitAllyThreshold + 1
    end

    return t
end

-- ============================================================
-- Desire bias by pressure — applied as a final polish in ModulateDesire
-- so aggressive modes scale up when ahead, defensive when behind.
-- ============================================================

local PRESSURE_BIAS = {
    -- When pressure is +1.0: these multipliers; at 0, they're 1.0; at -1.0, inverted.
    push      = 1.15,
    team_roam = 1.10,
    roam      = 1.10,
    roshan    = 1.15,
    retreat   = 0.90,
    farm      = 0.95,
    defend    = 1.0,
}

function ____exports.GetPressureBias(mode)
    local target = PRESSURE_BIAS[mode]
    if target == nil then return 1.0 end
    local pressure = ____exports.GetStrategicPressure()
    -- Linear interpolate: at pressure=0 return 1.0; at pressure=+1 return target; at pressure=-1 return inverse.
    -- inverse(target) = 1/target for multipliers > 1, target for < 1 (i.e., 2.0 * pressure * (target - 1) / ...)
    -- Simpler: mult = 1 + pressure * (target - 1)
    return 1 + pressure * (target - 1)
end

-- ============================================================
-- Debug
-- ============================================================

function ____exports.Describe()
    local t = ____exports.GetThresholds()
    return string.format("pressure=%.2f ultReady=%d commit>=%d push>=%d rosh>=%d",
        t.pressure, t.ultReady, t.commitAllyThreshold, t.pushAllyThreshold, t.roshAllyThreshold)
end

return ____exports
