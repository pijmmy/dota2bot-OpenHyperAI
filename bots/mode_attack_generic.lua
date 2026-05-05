local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local Utils = require( GetScriptDirectory()..'/FunLib/utils')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')

local local_mode_attack_generic
if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then
	return
end

if Utils.BuggyHeroesDueToValveTooLazy[botName] then
	local_mode_attack_generic = dofile( GetScriptDirectory().."/FunLib/override_generic/mode_attack_generic" )
end

-- ============================================================
-- Universal tower-dive guard (applies to ALL 127 heroes)
--
-- The override at FunLib/override_generic/mode_attack_generic.lua is
-- only loaded for 9 specific "buggy" heroes (Muerta/Marci/LD bear/
-- Primal Beast/Dark Willow/Elder Titan/Hoodwink/IO/Kez). For every
-- OTHER hero, Dota's built-in default attack mode runs. Without this
-- universal guard, those 118 heroes happily walk into enemy tower
-- range and die.
--
-- This wrapper hooks GetDesire (which Dota always queries before
-- entering ATTACK mode) and clamps the desire to VERYLOW when the
-- bot would dive without an immortal frame. Works regardless of
-- whether the override loaded.
--
-- Uses J.Safezone.WouldDiveIfMovedTo from the safezone utility.
-- ============================================================

local _universalDiveSeen = false
local function _universalDiveCap(desireFromInner)
	-- Don't gate when an immortal frame is active.
	if bot:HasModifier('modifier_abaddon_borrowed_time')
	   or bot:HasModifier('modifier_item_satanic_unholy')
	   or bot:HasModifier('modifier_skeleton_king_reincarnation_scepter_active')
	   or bot:HasModifier('modifier_dazzle_shallow_grave')
	   or bot:HasModifier('modifier_oracle_false_promise')
	   or bot:HasModifier('modifier_omniknight_guardian_angel')
	   or bot:IsAttackImmune()
	then
		return desireFromInner
	end

	-- Use the safezone predicate. Fall through cleanly if module missing.
	local diving = false
	if J and J.Safezone and J.Safezone.WouldDiveIfMovedTo then
		local ok, dive = pcall(function()
			return J.Safezone.WouldDiveIfMovedTo(bot, bot:GetLocation(), 0)
		end)
		if ok and dive then diving = true end
	else
		-- Fallback: basic tower-proximity check.
		local towers = bot:GetNearbyTowers(750, true)
		if towers and towers[1] and not towers[1]:IsNull() and towers[1]:IsAlive() then
			-- In tower range. Suppress unless HP buffer >= 700.
			local hp = bot:GetHealth() + (bot:GetHealthRegen() * 3.0)
			if hp < 700 then diving = true end
		end
	end

	if diving then
		if not _universalDiveSeen then
			_universalDiveSeen = true
			pcall(function()
				bot:ActionImmediate_Chat("[OHA-DIVE-GUARD] " .. botName .. " suppressed attack desire (tower-range, no immortal)", false)
			end)
		end
		-- Drop to VERYLOW so retreat / defend modes win.
		return 0.1
	end

	return desireFromInner
end

if local_mode_attack_generic ~= nil then
	-- Override path: 9 specific heroes have their own override file.
	-- Wrap its GetDesire with the universal cap so even those heroes
	-- get the additional safety net.
	function GetDesire()
		return _universalDiveCap(local_mode_attack_generic.GetDesire())
	end
	function Think() return local_mode_attack_generic.Think() end
	function OnStart() return local_mode_attack_generic.OnStart() end
	function OnEnd() return local_mode_attack_generic.OnEnd() end
else
	-- All 118 other heroes: Dota's default attack mode runs. We can't
	-- override its behavior, but we CAN override the desire it sees by
	-- defining GetDesire here. When this returns VERYLOW, Dota picks a
	-- different mode (retreat/defend/etc.) instead of attack.
	--
	-- Returning a high desire would force-enable attack — we don't want
	-- that. Returning nil/non-number would cause assertion crashes. So
	-- we ONLY return when actually suppressing. The default-attack-mode
	-- behavior comes from Dota when GetDesire is absent or returns nil.
	function GetDesire()
		local capped = _universalDiveCap(nil)
		if capped == 0.1 then return capped end
		-- Otherwise let Dota's default-attack-mode internal logic decide.
		return nil
	end
end
