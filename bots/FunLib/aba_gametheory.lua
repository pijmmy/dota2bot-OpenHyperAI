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

-- Find a hero's ultimate ability. Ult slot isn't universal (Invoker, Meepo,
-- Morphling etc. have non-standard layouts), so we use J.Skill.GetAbilityList
-- which already handles the "ult at logical index 6" convention (see
-- FunLib/aba_skill.lua). Falls back to slot scan if that isn't available.
local function getUltimate(bot)
    local J = jmz()
    if J and J.Skill and J.Skill.GetAbilityList then
        local ok, list = pcall(function() return J.Skill.GetAbilityList(bot) end)
        if ok and type(list) == "table" and list[6] ~= nil then
            local okA, ult = pcall(function() return bot:GetAbilityByName(list[6]) end)
            if okA and ult ~= nil and not ult:IsNull() then return ult end
        end
    end
    -- Fallback: scan slots and use ab:IsUltimate() which correctly identifies
    -- the ult regardless of its slot position. Previous heuristic
    -- (GetMaxLevel() <= 4) incorrectly matched normal abilities 1-4.
    for slot = 0, 24 do
        local okA, ab = pcall(function() return bot:GetAbilityInSlot(slot) end)
        if okA and ab ~= nil and not ab:IsNull() then
            local okU, isUlt = pcall(function() return ab:IsUltimate() end)
            if okU and isUlt and ab:IsTrained() then
                return ab
            end
        end
    end
    return nil
end

function ____exports.GetUltReadiness()
    local now = DotaTime()
    if now - ultCache.lastUpdate < RECOMPUTE_INTERVAL then
        return ultCache.value
    end
    local ready = 0
    for i = 1, 5 do
        local ok, m = pcall(function() return GetTeamMember(i) end)
        if ok and m ~= nil and m:IsAlive() then
            local ult = getUltimate(m)
            if ult ~= nil and ult:IsTrained()
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

    -- Ahead: press the advantage. 1-ally commit is intentional — winning team
    -- should be punishing mistakes aggressively, not playing safe.
    if pressure > 0.3 then
        t.commitAllyThreshold = 1
        t.pushAllyThreshold = 3
        t.roshAllyThreshold = 2
    elseif pressure < -0.3 then
        -- Behind: slightly conservative, but NOT turtle. Desperate teams
        -- need to force fights to get back, otherwise losing spirals.
        -- (Previous version's 3/5/4 thresholds locked losing bots into farm.)
        t.commitAllyThreshold = 2
        t.pushAllyThreshold = 4
        t.roshAllyThreshold = 3
    end

    -- Ult-heavy team: commits and pushes are cheaper (hard disables available).
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

-- Pressure bias magnitudes deliberately muted.
-- Previously stronger values (e.g., retreat 0.90 at +1, 1.10 at -1) caused
-- a losing-spiral: behind team retreated more + farmed more -> kept losing.
-- The formula mult = 1 + pressure * (target - 1) symmetric around 1 means
-- losing teams get the inverse of winning effects. Keep magnitudes small
-- so personality + team-plan stay the dominant signals; pressure is just
-- a gentle nudge, not a strait-jacket.
local PRESSURE_BIAS = {
    push      = 1.08,
    team_roam = 1.05,
    roam      = 1.05,
    roshan    = 1.08,
    retreat   = 0.95,
    farm      = 0.97,
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
