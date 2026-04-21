local Defend = require( GetScriptDirectory()..'/FunLib/aba_defend')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')

local bot = GetBot()
local botName = bot:GetUnitName()

if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then
	return
end

function GetDesire()
	local raw = Defend.GetDefendDesire(bot, LANE_MID)
	return J.Personality.ModulateDesire(bot, raw, 'defend')
end
function Think() Defend.DefendThink(bot, LANE_MID) end
