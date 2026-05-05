local Defend = require( GetScriptDirectory()..'/FunLib/aba_defend')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')

local bot = GetBot()
local botName = bot:GetUnitName()

if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then
	return
end

function GetDesire()
	local raw = Defend.GetDefendDesire(bot, LANE_TOP)
	-- Team-plan floor: if computePlan returned defend_lane on THIS lane
	-- (e.g. T3/rax taking damage in fog — see findThreatenedLane tier-3+
	-- branch in aba_teamplan.lua), force a high floor on defend desire
	-- so bots actually commit. Without this, defend's own GetDefendDesire
	-- can return ~0.05 when no enemies are visible, and the team-plan
	-- multiplier (1.0 for defend_lane) doesn't add a floor — only scales.
	--
	-- 0.95 floor for matching defend_lane: high enough to dominate
	-- retreat under defend_lane (retreat mult 0.85, raw_critical 0.95 →
	-- final 0.81; mine final ≥ 0.95 * envelope ≈ 0.81-1.14). Defend
	-- wins over retreat, farm, push, team_roam — i.e. the bot actually
	-- goes to the threatened tower.
	-- 0.90 for defend_base: slightly lower so any lane defend can fire.
	pcall(function()
		if J.TeamPlan and J.TeamPlan.GetCurrentPlan then
			local plan = J.TeamPlan.GetCurrentPlan()
			if plan ~= nil then
				if plan.intent == "defend_lane" and plan.lane == LANE_TOP then
					raw = math.max(raw, 0.95)
				elseif plan.intent == "defend_base" then
					raw = math.max(raw, 0.90)
				end
			end
		end
	end)
	return J.Personality.ModulateDesire(bot, raw, 'defend')
end
function Think() Defend.DefendThink(bot, LANE_TOP) end
