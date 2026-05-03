local Defend = require( GetScriptDirectory()..'/FunLib/aba_defend')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')

local bot = GetBot()
local botName = bot:GetUnitName()

if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then
	return
end

function GetDesire()
	local raw = Defend.GetDefendDesire(bot, LANE_BOT)
	-- Team-plan floor: defend_lane on this lane → high floor.
	-- defend_base → high floor on any defend tower mode.
	-- See mode_defend_tower_top_generic.lua for full reasoning.
	pcall(function()
		if J.TeamPlan and J.TeamPlan.GetCurrentPlan then
			local plan = J.TeamPlan.GetCurrentPlan()
			if plan ~= nil then
				if plan.intent == "defend_lane" and plan.lane == LANE_BOT then
					raw = math.max(raw, 0.85)
				elseif plan.intent == "defend_base" then
					raw = math.max(raw, 0.80)
				end
			end
		end
	end)
	return J.Personality.ModulateDesire(bot, raw, 'defend')
end
function Think() Defend.DefendThink(bot, LANE_BOT) end
