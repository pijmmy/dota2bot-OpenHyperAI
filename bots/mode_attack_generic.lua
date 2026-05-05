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

-- ============================================================
-- Universal attack-mode hysteresis (applies to ALL 127 heroes)
--
-- The "Earthshaker toggling back and forth at 3:53min" bug class:
-- ATTACK mode desire is recomputed every tick from current enemy
-- proximity. When an enemy hero hovers around the engagement
-- threshold, the bot enters ATTACK -> walks toward target -> target
-- backs away -> bot drops out of ATTACK -> walks back to wave -> target
-- returns -> bot enters ATTACK again. Pure positional dither.
--
-- Cure: once we've been in ATTACK mode this tick, hold the desire
-- elevated for ATTACK_HOLD_SEC even if the inner calculation drops.
-- This gives the engagement at least one full attack swing's worth
-- of commitment before we can back out.
--
-- Same caveats as the dive cap: returning a number forces a desire
-- floor; returning nil falls through to Dota's default. We only
-- ELEVATE here when (a) ATTACK was active in the last hold window,
-- (b) we have a live target nearby, and (c) we're not already being
-- suppressed by the dive cap. That last point matters: the dive cap
-- runs first and returns 0.1; the hysteresis runs after and would
-- otherwise overwrite that with 0.7. So hysteresis takes the dive
-- cap's verdict as authoritative.
-- ============================================================

local ATTACK_HOLD_SEC = 1.5
local RETREAT_COOLDOWN_SEC = 2.5
local _lastInAttackTime = -100
local _lastInRetreatTime = -100
local function _attackHoldHysteresis(desireFromCap)
	-- Honor the dive cap's verdict — don't elevate desire when it
	-- already dropped us to suppress a tower-dive.
	if desireFromCap ~= nil and desireFromCap <= 0.15 then
		return desireFromCap
	end

	-- Stamp last-active mode tick. GetActiveMode reflects the previous
	-- tick's chosen mode.
	local mode = bot:GetActiveMode()
	if mode == BOT_MODE_ATTACK then
		_lastInAttackTime = DotaTime()
	elseif mode == BOT_MODE_RETREAT then
		_lastInRetreatTime = DotaTime()
	end

	-- Retreat-then-reengage suppression. User report: "I dove phoenix
	-- who came back at me after retreating. poor logic." Cause: bot
	-- exits RETREAT mode (HP regenerated, distance grew briefly), engine
	-- recomputes ATTACK desire on the still-nearby same enemy. Bot
	-- pivots, walks BACK at the threat that just chased it. Toggle.
	--
	-- Cure: for RETREAT_COOLDOWN_SEC after we were last in retreat,
	-- suppress ATTACK desire to LOW. Forces the bot to actually clear
	-- the retreat (move further away, regen, ally arrival, target
	-- leaves) before considering re-engagement. RETREAT mode's own
	-- desire stays intact — this only depresses the ATTACK desire that
	-- would otherwise win after retreat exits.
	if DotaTime() - _lastInRetreatTime < RETREAT_COOLDOWN_SEC then
		return 0.1
	end

	-- Within attack-hold window AND have a viable target nearby => hold floor.
	if DotaTime() - _lastInAttackTime < ATTACK_HOLD_SEC then
		local tgt = bot:GetTarget()
		if tgt ~= nil and not tgt:IsNull() and tgt:IsAlive()
			and tgt:GetTeam() ~= bot:GetTeam()
			and not tgt:IsInvulnerable()
			and GetUnitToUnitDistance(bot, tgt) < 1200
		then
			-- Floor at HIGH (0.7). This loses to retreat (which can hit
			-- 0.85+ at low HP) but wins against laning/farm/roam, so a
			-- target-locked engagement stays committed.
			return 0.7
		end
	end

	return desireFromCap
end

-- ============================================================
-- Human-ally kill yield (applies to ALL 127 heroes)
--
-- User report: "winning 8-0 same issue discussed about my team always
-- getting ahead early game. I didnt get the kills so clearly there is
-- a problem with the bots." The user wants the human carry to land
-- the kill blow when they're already engaged on a low-HP enemy.
--
-- Cure: suppress ATTACK desire when (a) a low-HP enemy hero is nearby,
-- (b) a human ally is closer to that enemy than the bot, (c) the human
-- ally is moving toward the enemy or attacking them. This makes the bot
-- pause attacks for ~1 second so the human's auto-attack lands the
-- killing blow. Bot resumes normal logic on next tick.
--
-- Limited to LATE-laning HP threshold (HP < 0.35) so this doesn't
-- prevent bots from helping in real fights — only nicks the kill
-- credit when the human is already winning the duel.
-- ============================================================

local KILL_YIELD_HP_THRESHOLD = 0.35
local KILL_YIELD_RADIUS = 800
local function _humanKillYield(desireFromHold)
	-- Only operate when desire is being elevated (we'd otherwise attack).
	-- Don't override dive cap (0.1) — that's already suppressing.
	if desireFromHold == nil or desireFromHold <= 0.15 then
		return desireFromHold
	end

	local enemies = bot:GetNearbyHeroes(KILL_YIELD_RADIUS, true, BOT_MODE_NONE)
	if enemies == nil then return desireFromHold end

	for i = 1, #enemies do
		local e = enemies[i]
		if e ~= nil and not e:IsNull() and e:IsAlive()
			and not e:IsIllusion()
			and e:GetMaxHealth() > 0
			and (e:GetHealth() / e:GetMaxHealth()) < KILL_YIELD_HP_THRESHOLD
		then
			local enemyLoc = e:GetLocation()
			local botDist = GetUnitToUnitDistance(bot, e)

			-- Find a human ally closer to this enemy than `bot`.
			for ai = 1, 5 do
				local ally = GetTeamMember(ai)
				if ally ~= nil and ally ~= bot
					and not ally:IsNull() and ally:IsAlive()
					and not ally:IsIllusion() and not ally:IsBot()
				then
					local allyDist = GetUnitToLocationDistance(ally, enemyLoc)
					if allyDist < botDist and allyDist < 800 then
						-- Human is closer + in range. Yield: drop ATTACK
						-- to LOW so the bot doesn't compete for the kill.
						-- Returns 0.1 — same level as dive-cap suppression.
						return 0.1
					end
				end
			end
		end
	end

	return desireFromHold
end

local function _applyUniversalGuards(innerDesire)
	local capped = _universalDiveCap(innerDesire)
	local held = _attackHoldHysteresis(capped)
	return _humanKillYield(held)
end

if local_mode_attack_generic ~= nil then
	-- Override path: 9 specific heroes have their own override file.
	-- Wrap its GetDesire with the universal cap + hold so even those
	-- heroes get the additional safety net.
	function GetDesire()
		return _applyUniversalGuards(local_mode_attack_generic.GetDesire())
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
	-- Two-stage logic:
	--   1) Dive cap may drop desire to 0.1 to suppress tower dives.
	--   2) Attack-hold may raise desire to 0.7 to prevent dither
	--      (only when dive cap didn't already suppress).
	-- If neither fires, return nil so Dota's default logic decides.
	function GetDesire()
		local result = _applyUniversalGuards(nil)
		-- Only return a number when we are actively overriding the engine.
		-- nil means "use the default attack desire calc" — engine handles.
		if result == 0.1 or result == 0.7 then return result end
		return nil
	end
end
