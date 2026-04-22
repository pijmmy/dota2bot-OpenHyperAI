--[[ Save-ally detection.

     Detects when one of our heroes is under enemy commit/dive and returns
     the most-urgent save target. Hero files with save spells (Dazzle grave,
     Oracle promise, Omni ult, IO relocate, Abaddon shield, Treant armor,
     Winter Wyvern Cold Embrace, Dazzle Shadow Wave heal, etc.) query this
     at the top of their Consider functions to preempt deaths.

     Exposed as J.Save.*

     Paired with TS source at typescript/bots/FunLib/aba_save.ts. ]]
local ____exports = {}

local _jmz = nil
local function jmz()
    if _jmz == nil then
        _jmz = require(GetScriptDirectory().."/FunLib/jmz_func")
    end
    return _jmz
end

-- ============================================================
-- Urgency scoring
--
-- urgency = (1 - hp)               <- lower HP = more urgent
--         + 0.25 * enemyCount      <- more attackers = more urgent
--         + 0.5 * recentDamageFlag <- recently hit = immediate danger
--         + 0.3 * disabledFlag     <- stunned/silenced can't self-save
--         + 0.4 * isCoreFlag       <- losing a core is more painful
--
-- Output in [0..~3]; callers compare against a threshold like 0.7 for
-- moderate saves, 1.2 for definitely-save.
-- ============================================================

local function scoreAllyThreat(ally, bot)
    local J = jmz()
    if not J.IsValidHero(ally) then return 0, 0 end
    local hp = J.GetHP(ally)
    if hp >= 0.85 then return 0, 0 end  -- healthy, no save needed

    local enemiesNear = J.GetNearbyHeroes(ally, 900, true, BOT_MODE_NONE)
    local enemyCount = 0
    if enemiesNear ~= nil then
        for i = 1, #enemiesNear do
            if J.IsValidHero(enemiesNear[i]) and not J.IsSuspiciousIllusion(enemiesNear[i]) then
                enemyCount = enemyCount + 1
            end
        end
    end

    -- No attackers nearby AND full HP = not a save situation
    if enemyCount == 0 and hp >= 0.5 then return 0, enemyCount end

    local recentlyHit = 0
    local ok, wasHit = pcall(function() return ally:WasRecentlyDamagedByAnyHero(2.0) end)
    if ok and wasHit then recentlyHit = 1 end

    local disabled = 0
    local okD, isDis = pcall(function() return J.IsDisabled(ally) end)
    if okD and isDis then disabled = 1 end

    local isCore = 0
    local okC, core = pcall(function() return J.IsCore(ally) end)
    if okC and core then isCore = 1 end

    local urgency = (1 - hp)
                  + 0.25 * enemyCount
                  + 0.50 * recentlyHit
                  + 0.30 * disabled
                  + 0.40 * isCore

    return urgency, enemyCount
end

-- ============================================================
-- Public API
-- ============================================================

--[[ Returns (ally, urgency) for the most-threatened ally within saveRange
     of `bot`. Returns (nil, 0) if no ally needs saving.

     Excludes the caller (`bot`) — bots save teammates, not themselves.
     For self-save (BKB, Euls on self), use existing item/ability logic. ]]
function ____exports.GetAllyUnderThreat(bot, saveRange)
    if bot == nil then return nil, 0 end
    local J = jmz()
    local allies = J.GetNearbyHeroes(bot, saveRange, false, BOT_MODE_NONE)
    if allies == nil then return nil, 0 end

    local best = nil
    local bestUrgency = 0
    for i = 1, #allies do
        local ally = allies[i]
        if ally ~= nil and ally ~= bot and J.IsValidHero(ally) and not ally:IsIllusion() then
            local urgency, _ = scoreAllyThreat(ally, bot)
            if urgency > bestUrgency then
                best = ally
                bestUrgency = urgency
            end
        end
    end
    return best, bestUrgency
end

-- Urgency threshold suggestions for callers:
--   >= 0.7  : moderate, consider saving (basic abilities, tangos)
--   >= 1.2  : serious, high-priority save (shield, armor)
--   >= 1.8  : critical, use big save (grave, promise, guardian, relocate)
____exports.URGENCY_MODERATE = 0.7
____exports.URGENCY_HIGH     = 1.2
____exports.URGENCY_CRITICAL = 1.8

-- ============================================================
-- "Already protected" checks — avoid double-saving
--
-- Save spells that are idempotent (grave, promise) shouldn't be cast
-- again if the ally already has a save modifier. Callers use this to
-- filter out already-protected allies.
-- ============================================================

local SAVE_MODIFIERS = {
    'modifier_dazzle_shallow_grave',
    'modifier_oracle_false_promise',
    'modifier_oracle_false_promise_timer',
    'modifier_omniknight_guardian_angel',
    'modifier_abaddon_borrowed_time',
    'modifier_abaddon_aphotic_shield',
    'modifier_treant_living_armor',
    'modifier_winter_wyvern_cold_embrace',
    'modifier_item_aeon_disk_buff',
    'modifier_dazzle_shadow_wave',
    'modifier_wisp_relocate',
}

function ____exports.HasSaveModifier(unit)
    if unit == nil then return false end
    for i = 1, #SAVE_MODIFIERS do
        local ok, has = pcall(function() return unit:HasModifier(SAVE_MODIFIERS[i]) end)
        if ok and has then return true end
    end
    return false
end

-- Convenience: get a save target that isn't already protected.
function ____exports.GetAllyNeedingSave(bot, saveRange, minUrgency)
    local ally, urgency = ____exports.GetAllyUnderThreat(bot, saveRange)
    if ally == nil then return nil, 0 end
    if minUrgency ~= nil and urgency < minUrgency then return nil, urgency end
    if ____exports.HasSaveModifier(ally) then return nil, urgency end
    return ally, urgency
end

-- ============================================================
-- Debug
-- ============================================================

function ____exports.Describe(bot)
    local ally, urgency = ____exports.GetAllyUnderThreat(bot, 2000)
    if ally == nil then return "no ally under threat" end
    local ok, name = pcall(function() return ally:GetUnitName() end)
    if not ok then name = "?" end
    return name .. string.format(" urgency=%.2f", urgency)
end

return ____exports
