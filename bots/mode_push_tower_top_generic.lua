local Push = require( GetScriptDirectory()..'/FunLib/aba_push')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')
local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end
if bot.PushLaneDesire == nil then bot.PushLaneDesire = {0, 0, 0} end

function GetDesire()
    local raw = Push.GetPushDesire(bot, LANE_TOP)
    local res = J.Personality.ModulateDesire(bot, raw, 'push')
    bot.PushLaneDesire[LANE_TOP] = res
    return res
end
function Think() Push.PushThink(bot, LANE_TOP) end
