-- Stun-chain coordination.
--
-- Without coordination, every hero's CC ability fires on its own cooldown.
-- Two stuns landing at the same instant overlap and waste duration; two
-- stuns spaced apart give the enemy a window to escape between them.
--
-- This module gives hero CC Considers a "should I fire NOW?" check that
-- stops them from:
--   (a) wasting their stun on a target already locked down for >2s, and
--   (b) firing simultaneously when chaining at the END of an existing stun
--       would be strictly better.
--
-- Decision rule:
--   - target has fresh stun (remaining > 2.0s)        → DELAY (skip cast this tick)
--   - target has expiring stun (0.15s < r ≤ 0.5s)     → FIRE NOW (chain)
--   - target has mid stun (0.5s < r ≤ 2.0s)           → DELAY (wait for chain window)
--   - target unstunned                                → FIRE per normal logic
--
-- Detection uses J.GetRemainStunTime + a list of generic-stun modifiers
-- the engine doesn't always consolidate into modifier_stunned (chrono
-- freeze, black-hole pull, treant overgrowth, etc.).
--
-- Exposed as J.StunChain.

local ____exports = {}

local jmz = require(GetScriptDirectory() .. "/FunLib/jmz_func")

-- Hard-CC modifiers that should count toward "target is locked down."
-- modifier_stunned is the engine's consolidated stun; everything else
-- is a hero-specific CC that the engine doesn't always fold in.
local CC_MODIFIERS = {
    "modifier_stunned",
    "modifier_axe_berserkers_call",
    "modifier_legion_commander_duel",
    "modifier_faceless_void_chronosphere_freeze",
    "modifier_enigma_black_hole_pull",
    "modifier_naga_siren_song_of_the_siren_sleep",
    "modifier_treant_overgrowth",
    "modifier_lion_impale",
    "modifier_warlock_upheaval",   -- mass slow not stun, but lockdown for chains
    "modifier_invoker_cold_snap_freeze",
    "modifier_pudge_dismember",
    "modifier_bane_fiends_grip",
    "modifier_bane_nightmare",
    "modifier_shadow_shaman_shackles",
    "modifier_disruptor_static_storm",
    "modifier_winter_wyvern_winters_curse",
    "modifier_outworld_destroyer_astral_imprisonment_prison",
    "modifier_skywrath_mage_ancient_seal", -- silence is lockdown for casters
    "modifier_silencer_global_silence",
    "modifier_doom_bringer_doom",
    "modifier_terrorblade_sunder",
    "modifier_oracle_fortunes_end_purge",
    "modifier_mars_arena_of_blood_leash",
    "modifier_dark_seer_vacuum",
    "modifier_lich_chain_frost_slow",  -- bounce slow keeps target locked
}

-- Returns the longest active CC remaining on the target (in seconds).
-- 0 if no CC active.
local function getCCRemaining(target)
    if target == nil then return 0 end
    if target:IsNull() or not target:IsAlive() then return 0 end

    local longest = 0

    -- Generic engine-consolidated stun
    local okStun, stunR = pcall(function() return jmz.GetRemainStunTime(target) end)
    if okStun and type(stunR) == "number" and stunR > longest then
        longest = stunR
    end

    -- Hero-specific CC modifiers (not always in modifier_stunned)
    for _, mod in ipairs(CC_MODIFIERS) do
        if target:HasModifier(mod) then
            local okMod, r = pcall(function() return jmz.GetModifierTime(target, mod) end)
            if okMod and type(r) == "number" and r > longest then
                longest = r
            end
        end
    end

    return longest
end

-- Public: returns true if target is currently locked down for long enough
-- that adding another stun would overlap rather than chain. Called by
-- hero CC Considers to skip the cast.
function ____exports.ShouldDelay(target)
    if target == nil then return false end
    local remaining = getCCRemaining(target)
    -- 0.5 < r ≤ 2.5: skip (wait for end of CC to chain)
    -- > 2.5: skip (already locked long enough; chain unnecessary)
    return remaining > 0.5
end

-- Public: returns true if the target's current CC is about to expire and
-- a NEW stun would land at the perfect chain point. Use this when bot
-- has an instant-cast CC (no projectile/cast point worry) and wants to
-- prioritise chaining over other targets.
--
-- castDelay = bot's cast point + projectile travel time to target.
function ____exports.ShouldChainNow(target, castDelay)
    if target == nil then return false end
    castDelay = castDelay or 0.3
    local remaining = getCCRemaining(target)
    -- Window: enemy's CC ends in [castDelay, castDelay + 0.4]. Cast now,
    -- our CC lands as theirs ends.
    return remaining > castDelay and remaining <= (castDelay + 0.4)
end

-- Public: same shape as ShouldDelay but inverted for readability in
-- hero code.
function ____exports.IsTargetFreshlyLocked(target)
    if target == nil then return false end
    return getCCRemaining(target) > 2.0
end

function ____exports.GetCCRemaining(target)
    return getCCRemaining(target)
end

function ____exports.Describe(target)
    if target == nil then return "stun_chain: nil target" end
    return string.format("stun_chain: %s has %.2fs CC remaining",
        target:GetUnitName() or "?", getCCRemaining(target))
end

return ____exports
