local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local Utils = require( GetScriptDirectory()..'/FunLib/utils' )
local BotBuild = dofile(GetScriptDirectory() .. "/BotLib/" .. string.gsub(botName, "npc_dota_", ""));

-- Telemetry logger: throttled snapshots + kill-stream polling. Disabled
-- unless Customize.Logger.Enabled. Writes NDJSON to bots/logs/match_*.ndjson;
-- flushed per event so mid-match `tail -f` works.
local _ok_logger, _Logger = pcall(require, GetScriptDirectory()..'/FunLib/aba_logger')
if _ok_logger and _Logger and _Logger.IsEnabled and _Logger.IsEnabled() then
    _Logger.MaybeTick(bot)
    _Logger.PollKillStream(bot)
end

if BotBuild == nil
then
	print('[ERROR] No build config file found for bot: '..botName)
	return
end

function MinionThink(hMinionUnit)
	if not Utils.IsValidUnit(hMinionUnit) then return end
	if hMinionUnit.lastMinionFrameProcessTime == nil then hMinionUnit.lastMinionFrameProcessTime = DotaTime() end
	if DotaTime() - hMinionUnit.lastMinionFrameProcessTime < 0.3 then return end
	hMinionUnit.lastMinionFrameProcessTime = DotaTime()

	BotBuild.MinionThink(hMinionUnit)
end
