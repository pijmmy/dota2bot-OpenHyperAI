--[[ Safezone utility: predicate functions for "is this location/action
    safe from enemy tower fire."

The audit identified ~10 sites where bots commit to a position or
movement WITHOUT checking enemy tower proximity:

  - ability_item_usage_generic.lua item_blink combat path
  - mode_team_roam_generic.lua focus override
  - mode_roam_generic.lua focus override
  - hero_storm_spirit.lua ConsiderBallLightning
  - hero_spirit_breaker.lua ConsiderChargeOfDarkness
  - hero_earthshaker.lua ConsiderBlinkSlam
  - hero_magnataur.lua ConsiderBlinkRP
  - hero_tiny.lua ConsiderBlinkToss
  - hero_centaur.lua ConsiderHoofStomp
  - hero_axe.lua ConsiderQ Berserker's Call

Each currently has its own (or no) tower-proximity check. This module
is the single canonical predicate they should consult.

Tower attack range: 700u (all tier-1+ towers; ancient towers are 800u).
We use 750u as the default unsafe zone to give a small buffer for
projectile travel time during chase.

Tower attack damage: T1 ~110, T2 ~125, T3 ~150, ancient ~152. So a
bot with HP > 350 + immortal frame can typically tank 2-3 hits, but
the third one without escape lands.

Source rules informing the gate (see docs/SOURCES.md):
  - adamqqq's PushUtility.AttackedByTowerRate: HP gate at
    0.7 + 0.1 * enemyCount before tower-tank is considered safe.
  - esports.net HG-siege rules: BKB / damage / survivability item
    gates before commit; disengage on cooldowns wasted.
]]

local ____exports = {}

local TOWER_ATTACK_RANGE = 700      -- standard tower range
local TOWER_DANGER_BUFFER = 50      -- soft margin (so 750u total)
local DEFAULT_DANGER_RADIUS = TOWER_ATTACK_RANGE + TOWER_DANGER_BUFFER

-- ============================================================
-- IsLocSafeFromEnemyTowers
-- ============================================================
--
-- Returns true if `loc` is OUTSIDE every alive enemy tower's attack
-- range (with optional margin for projectile travel during chase).
-- This is the cheap predicate to call before:
--   - blinking to a location (item_blink)
--   - teleporting to a location (TP scroll, Furion ult)
--   - issuing Action_MoveToLocation as part of an offensive commit
--   - Storm Spirit Ball Lightning destination
--
-- Cheap: O(towers nearby), no per-bot state.

local function getNearbyEnemyTowers(forBot, radius)
    -- forBot may be nil for pure-location queries (use a sample bot).
    if forBot == nil then
        for i = 1, 5 do
            local m = GetTeamMember(i)
            if m ~= nil and m:IsAlive() then forBot = m; break end
        end
        if forBot == nil then return {} end
    end
    local ok, towers = pcall(function()
        return forBot:GetNearbyTowers(radius, true)
    end)
    if not ok or towers == nil then return {} end
    return towers
end

function ____exports.IsLocSafeFromEnemyTowers(loc, marginUnits)
    if loc == nil then return true end
    marginUnits = marginUnits or 0
    local danger = DEFAULT_DANGER_RADIUS + marginUnits

    -- Sample-bot probe radius: search wide enough to catch any tower
    -- that might have `loc` in its attack range.
    local probeRadius = 1600 + danger

    local towers = getNearbyEnemyTowers(nil, probeRadius)
    for _, t in pairs(towers) do
        if t ~= nil and not t:IsNull() and t:IsAlive() then
            local okLoc, tloc = pcall(function() return t:GetLocation() end)
            if okLoc and tloc ~= nil then
                local dx = tloc.x - loc.x
                local dy = tloc.y - loc.y
                local distSq = dx * dx + dy * dy
                if distSq < danger * danger then
                    return false
                end
            end
        end
    end
    return true
end

-- ============================================================
-- WouldDiveIfMovedTo
-- ============================================================
--
-- Stricter version that takes the BOT's state into account: returns
-- true if moving the bot to `loc` would put it in tower danger AND
-- the bot is not protected by an immortal-frame buff.
--
-- Use this in Consider* functions that issue movement (blink, charge,
-- toss, ball lightning destination). It's the gate that should be
-- checked BEFORE committing to the destination.

local function hasImmortalFrame(bot)
    if bot == nil then return false end
    local mods = {
        'modifier_abaddon_borrowed_time',
        'modifier_item_satanic_unholy',
        'modifier_skeleton_king_reincarnation_scepter_active',
        'modifier_dazzle_shallow_grave',
        'modifier_oracle_false_promise',
        'modifier_omniknight_guardian_angel',
    }
    for i = 1, #mods do
        local ok, has = pcall(function() return bot:HasModifier(mods[i]) end)
        if ok and has then return true end
    end
    local okAI, ai = pcall(function() return bot:IsAttackImmune() end)
    if okAI and ai then return true end
    return false
end

local function botEffectiveHpBuffer(bot)
    if bot == nil then return 0 end
    local okH, hp = pcall(function() return bot:GetHealth() end)
    local okR, regen = pcall(function() return bot:GetHealthRegen() end)
    if not okH or hp == nil then return 0 end
    -- HP minus 3s of expected tower damage (~3 hits at ~150 = ~450).
    local effective = hp + (okR and regen or 0) * 3.0
    return effective
end

--[[ bot: the bot considering the move.
     loc: the destination it's about to move to.
     marginUnits: optional extra safe margin.
     Returns true if moving to loc would expose bot to tower fire AND
     bot lacks immortal frame AND HP can't safely tank.
]]
function ____exports.WouldDiveIfMovedTo(bot, loc, marginUnits)
    if bot == nil or loc == nil then return false end
    marginUnits = marginUnits or 0
    local danger = DEFAULT_DANGER_RADIUS + marginUnits

    local towers = getNearbyEnemyTowers(bot, 1600 + danger)
    local nearestTowerDist = math.huge
    local nearestTower = nil
    for _, t in pairs(towers) do
        if t ~= nil and not t:IsNull() and t:IsAlive() then
            local okLoc, tloc = pcall(function() return t:GetLocation() end)
            if okLoc and tloc ~= nil then
                local dx = tloc.x - loc.x
                local dy = tloc.y - loc.y
                local distSq = dx * dx + dy * dy
                if distSq < nearestTowerDist then
                    nearestTowerDist = distSq
                    nearestTower = t
                end
            end
        end
    end

    if nearestTower == nil then return false end
    if nearestTowerDist >= danger * danger then return false end

    -- In tower range. Allow if bot has an immortal frame.
    if hasImmortalFrame(bot) then return false end

    -- Allow if bot has enough effective HP to absorb expected damage
    -- (350 minimum buffer — enough for 2 tower hits at ~150 each + buffer).
    local hpBuffer = botEffectiveHpBuffer(bot)
    if hpBuffer >= 700 then return false end

    -- Diving with low HP and no immortal frame.
    return true
end

-- ============================================================
-- Damage estimation (for Consider* gates that want a more
-- conservative threshold)
-- ============================================================

function ____exports.EstimateTowerDPS(bot, loc, withinSec)
    -- Returns expected damage from all enemy towers that could attack
    -- the bot at `loc` over `withinSec` seconds.
    if bot == nil or loc == nil then return 0 end
    withinSec = withinSec or 3.0
    local danger = DEFAULT_DANGER_RADIUS

    local towers = getNearbyEnemyTowers(bot, 1600 + danger)
    local total = 0
    for _, t in pairs(towers) do
        if t ~= nil and not t:IsNull() and t:IsAlive() then
            local okLoc, tloc = pcall(function() return t:GetLocation() end)
            if okLoc and tloc ~= nil then
                local dx = tloc.x - loc.x
                local dy = tloc.y - loc.y
                if dx * dx + dy * dy < danger * danger then
                    local okD, dmg = pcall(function() return t:GetAttackDamage() end)
                    -- Tower swing rate ~1.0/s. Apply armor/magic resist
                    -- via GetActualIncomingDamage if available.
                    if okD and dmg ~= nil then
                        local raw = dmg * withinSec
                        local okA, actual = pcall(function()
                            return bot:GetActualIncomingDamage(raw, 0) -- DAMAGE_TYPE_PHYSICAL = 1, but 0 lets engine pick
                        end)
                        total = total + (okA and actual or raw)
                    end
                end
            end
        end
    end
    return total
end

-- ============================================================
-- Constants exposed for tests
-- ============================================================

____exports.TOWER_ATTACK_RANGE = TOWER_ATTACK_RANGE
____exports.DEFAULT_DANGER_RADIUS = DEFAULT_DANGER_RADIUS

return ____exports
