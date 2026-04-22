--[[ Enemy-focus detection (defensive mirror of aba_focus).

     While aba_focus picks a priority ENEMY for OUR team to commit on,
     this module detects when the enemy team is committing on ONE of OUR
     allies — so we can trigger a defensive collapse (save spells, focus
     fire the attacker, TP response).

     Publishes a current "threatened ally" signal consumed by:
       - aba_save.lua (urgency boost when ally is enemy-focus)
       - aba_teamplan.lua (new save_ally intent — bots collapse to defend)

     Exposed as J.EnemyFocus.*
     ]]
local ____exports = {}

local _jmz = nil
local function jmz()
    if _jmz == nil then
        _jmz = require(GetScriptDirectory().."/FunLib/jmz_func")
    end
    return _jmz
end

-- ============================================================
-- State
-- ============================================================

local RECOMPUTE_INTERVAL = 1.0
local TTL = 4.0
local THREAT_RADIUS = 900   -- how close an enemy has to be to be "attacking"
local MIN_ENEMIES = 2        -- ≥2 enemies within radius = commit
local MIN_URGENCY = 0.9      -- threshold for publishing

local currentEnemyFocus = {
    unit = nil,           -- our ally that's being committed on
    playerID = -1,
    enemyCount = 0,
    urgency = 0,
    reason = "none",
    validUntil = 0,
    lastComputeTime = -999,
}

-- ============================================================
-- Big-ult modifiers — if ally has any of these, save_ally fires
-- regardless of nearby enemy count (single-enemy big-ult commits
-- like Chrono / Duel / Doom need the same response).
-- ============================================================

local BIG_ULT_MODIFIERS = {
    'modifier_faceless_void_chronosphere_freeze',
    'modifier_enigma_black_hole_pull',
    'modifier_enigma_black_hole_thinker',
    'modifier_magnataur_reverse_polarity',
    'modifier_legion_commander_duel',
    'modifier_tidehunter_ravage_slow',
    'modifier_doom_bringer_doom',
    'modifier_shadow_demon_disruption',
    'modifier_bane_fiends_grip',
    'modifier_bane_nightmare',
    'modifier_shadow_shaman_shackles',
    'modifier_beastmaster_primal_roar',
    'modifier_lion_impale',
    'modifier_necrolyte_reapers_scythe',
    'modifier_pudge_dismember',
    'modifier_sandking_burrowstrike',
    'modifier_kunkka_ghostship_damage_delay',
    'modifier_disruptor_static_storm',
    'modifier_outworld_destroyer_astral_imprisonment_prison',
    'modifier_ember_spirit_searing_chains',
    'modifier_item_aeon_disk_buff',  -- ally used aeon — they're in serious trouble
}

local function hasBigUltModifier(unit)
    for i = 1, #BIG_ULT_MODIFIERS do
        local ok, has = pcall(function() return unit:HasModifier(BIG_ULT_MODIFIERS[i]) end)
        if ok and has then return true, BIG_ULT_MODIFIERS[i] end
    end
    return false, nil
end

-- ============================================================
-- Scoring
-- ============================================================

local function clamp01(v) if v < 0 then return 0 end; if v > 1 then return 1 end; return v end

local function scoreAllyInDanger(ally)
    local J = jmz()
    if not J.IsValidHero(ally) or ally:IsIllusion() then return 0, 0 end
    local hp = J.GetHP(ally)

    -- Count attacking enemies within threat radius
    local enemies = J.GetNearbyHeroes(ally, THREAT_RADIUS, true, BOT_MODE_NONE)
    if enemies == nil then enemies = {} end
    local attackingCount = 0
    for i = 1, #enemies do
        local e = enemies[i]
        if J.IsValidHero(e) and not J.IsSuspiciousIllusion(e) then
            local target = nil
            local okT, t = pcall(function() return e:GetAttackTarget() end)
            if okT then target = t end
            if target == ally then
                attackingCount = attackingCount + 1
            elseif ally:WasRecentlyDamagedByAnyHero(2.5) then
                attackingCount = attackingCount + 1
            end
        end
    end

    -- Big-ult shortcut: a single-target channel like Doom / Dismember / Duel
    -- is a commit even with 1 enemy. Force-trigger with high urgency.
    local caught, modName = hasBigUltModifier(ally)
    if caught then
        local urgency = 2.0 + (1 - hp) + 0.3 * attackingCount
        return urgency, math.max(attackingCount, 1)
    end

    if attackingCount < MIN_ENEMIES then return 0, attackingCount end

    -- Urgency: HP loss + enemy count + recently-damaged + disabled + is-core
    local recentlyHit = ally:WasRecentlyDamagedByAnyHero(2.0) and 1 or 0
    local disabled = 0
    local okD, isDis = pcall(function() return J.IsDisabled(ally) end)
    if okD and isDis then disabled = 1 end
    local isCore = 0
    local okC, core = pcall(function() return J.IsCore(ally) end)
    if okC and core then isCore = 1 end

    local urgency = (1 - hp)
                  + 0.35 * attackingCount
                  + 0.40 * recentlyHit
                  + 0.30 * disabled
                  + 0.40 * isCore

    return urgency, attackingCount
end

-- ============================================================
-- Public API
-- ============================================================

function ____exports.GetThreatenedAlly()
    return currentEnemyFocus
end

function ____exports.MaybeRecompute(bot)
    local now = DotaTime()
    if now - currentEnemyFocus.lastComputeTime < RECOMPUTE_INTERVAL then
        return currentEnemyFocus
    end
    local J = jmz()

    local bestAlly = nil
    local bestUrgency = 0
    local bestEnemyCount = 0
    local bestReason = "none"

    -- Iterate own team
    for i = 1, 5 do
        local okM, m = pcall(function() return GetTeamMember(i) end)
        if okM and m ~= nil and m:IsAlive() then
            local urgency, enemyCount = scoreAllyInDanger(m)
            if urgency > bestUrgency then
                bestAlly = m
                bestUrgency = urgency
                bestEnemyCount = enemyCount
                local parts = {}
                if J.GetHP(m) < 0.5 then table.insert(parts, "low-hp") end
                if enemyCount >= 3 then table.insert(parts, "3+enemies") end
                if m:WasRecentlyDamagedByAnyHero(2) then table.insert(parts, "under-attack") end
                bestReason = #parts > 0 and table.concat(parts, ",") or "pressured"
            end
        end
    end

    if bestAlly ~= nil and bestUrgency >= MIN_URGENCY then
        local okPid, pid = pcall(function() return bestAlly:GetPlayerID() end)
        currentEnemyFocus = {
            unit = bestAlly,
            playerID = okPid and pid or -1,
            enemyCount = bestEnemyCount,
            urgency = bestUrgency,
            reason = bestReason,
            validUntil = now + TTL,
            lastComputeTime = now,
        }
    else
        currentEnemyFocus = {
            unit = nil, playerID = -1, enemyCount = 0, urgency = 0,
            reason = "none", validUntil = 0, lastComputeTime = now,
        }
    end
    return currentEnemyFocus
end

function ____exports.IsActive()
    return currentEnemyFocus.unit ~= nil and DotaTime() < currentEnemyFocus.validUntil
end

-- Returns true if bot could feasibly help (close enough to the threatened ally)
function ____exports.CanHelp(bot, maxRange)
    if not ____exports.IsActive() then return false end
    local ally = currentEnemyFocus.unit
    if ally == nil then return false end
    if ally == bot then return false end
    local ok, dist = pcall(function() return GetUnitToUnitDistance(bot, ally) end)
    if not ok or dist == nil then return false end
    return dist <= (maxRange or 2500)
end

function ____exports.Describe()
    local f = currentEnemyFocus
    if f.unit == nil or DotaTime() > f.validUntil then return "no enemy commit" end
    local okN, name = pcall(function() return f.unit:GetUnitName() end)
    if not okN then name = "?" end
    return name .. " [" .. f.reason .. " urgency=" .. string.format("%.2f", f.urgency) .. " enemies=" .. tostring(f.enemyCount) .. "]"
end

return ____exports
