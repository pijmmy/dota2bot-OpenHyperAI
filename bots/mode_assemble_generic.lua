local bot = GetBot()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not string.find(bot:GetUnitName(), "hero") or bot:IsIllusion() then return end

local J = require( GetScriptDirectory()..'/FunLib/jmz_func' )

local PING_RECENCY = 8        -- respond to pings within this many seconds
local ASSEMBLE_DURATION = 5    -- stay in assemble mode for this long after ping
local ASSEMBLE_DESIRE = 0.85   -- desire value when assembling
local ARRIVE_RADIUS = 500      -- close enough to ping location
local MAX_RESPOND_DIST = 3200  -- only respond if within this distance
local TEAMPLAN_MAX_RESPOND_DIST = 5500  -- bots respond to team-plan from further

-- Intents that should drive assemble behavior — these set plan.location to
-- a group-up point. User complaint: "late game they are not defending higher
-- ground, they should be grouping up" — previously ignored because assemble
-- only responded to human pings.
local ASSEMBLE_INTENTS = {
	late_game_group = true,
	save_ally = true,
	contest_rosh = true,
	contest_tormentor = true,
	defend_base = true,
	defend_lane = true,
}

local assembleLoc = nil
local assembleExpireTime = 0
local lastTeamPlanIntent = nil

function GetDesire()
	if not bot:IsAlive() then return BOT_MODE_DESIRE_NONE end

	-- Check for recent human normal pings (not danger pings)
	local human, ping = J.GetHumanPing()
	if human ~= nil and ping ~= nil
	and ping.normal_ping
	and ping.time ~= 0
	and GameTime() - ping.time < PING_RECENCY
	then
		local dist = GetUnitToLocationDistance(bot, ping.location)
		if dist > ARRIVE_RADIUS and dist < MAX_RESPOND_DIST then
			assembleLoc = ping.location
			assembleExpireTime = GameTime() + ASSEMBLE_DURATION
			lastTeamPlanIntent = nil
			J.ModeAnnounce(bot, 'say_assemble', ASSEMBLE_DURATION)
			return J.Personality.ModulateDesire(bot, ASSEMBLE_DESIRE, 'assemble')
		end
	end

	-- Team-plan driven assemble: when the plan has a location and intent is
	-- one of the "converge" types, head there. This is what finally makes
	-- late_game_group, save_ally, and contest_rosh/tormentor physically pull
	-- bots to the action instead of just biasing desires.
	--
	-- Per-role gate: only roles listed in INTENT_ROLES for this intent respond.
	-- Prevents 5-man groupups for small objectives like lotus.
	if J.TeamPlan ~= nil and J.TeamPlan.GetCurrentPlan ~= nil then
		local plan = J.TeamPlan.GetCurrentPlan()
		if plan ~= nil and plan.location ~= nil
		   and plan.validUntil ~= nil and DotaTime() < plan.validUntil
		   and ASSEMBLE_INTENTS[plan.intent]
		   and (J.TeamPlan.RoleRespondsToIntent == nil or J.TeamPlan.RoleRespondsToIntent(bot)) then
			local dist = GetUnitToLocationDistance(bot, plan.location)
			if dist > ARRIVE_RADIUS and dist < TEAMPLAN_MAX_RESPOND_DIST then
				-- New intent = reset the assembly target
				if plan.intent ~= lastTeamPlanIntent then
					lastTeamPlanIntent = plan.intent
					assembleLoc = plan.location
					assembleExpireTime = GameTime() + ASSEMBLE_DURATION * 2
				else
					-- Same intent ongoing: refresh target + expire
					assembleLoc = plan.location
					assembleExpireTime = math.max(assembleExpireTime, GameTime() + ASSEMBLE_DURATION)
				end
				return J.Personality.ModulateDesire(bot, ASSEMBLE_DESIRE, 'assemble')
			end
		end
	end

	-- Continue moving to assembly point if still active
	if assembleLoc ~= nil and GameTime() < assembleExpireTime then
		local dist = GetUnitToLocationDistance(bot, assembleLoc)
		if dist <= ARRIVE_RADIUS then
			assembleLoc = nil
			return BOT_MODE_DESIRE_NONE
		end
		return J.Personality.ModulateDesire(bot, ASSEMBLE_DESIRE, 'assemble')
	end

	assembleLoc = nil
	lastTeamPlanIntent = nil
	return BOT_MODE_DESIRE_NONE
end

function OnEnd()
	assembleLoc = nil
	assembleExpireTime = 0
end

-- TP-to-save: when bot is far from assembly point and has a TP scroll
-- ready, TP to the nearest friendly tower close to the assembly point
-- instead of walking. Especially impactful for save_ally / late_game_group
-- where speed matters most.
local TP_DISTANCE_THRESHOLD = 4500
local TP_NEAR_TOWER_RADIUS = 2200
local lastTPAttempt = -999
local TP_COOLDOWN_BETWEEN_ATTEMPTS = 8  -- avoid spamming

local function findFriendlyTowerNearLoc(loc, radius)
	local team = GetTeam()
	local towers = {
		TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3,
		TOWER_MID_1, TOWER_MID_2, TOWER_MID_3,
		TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3,
		TOWER_BASE_1, TOWER_BASE_2,
	}
	for _, t in ipairs(towers) do
		local tower = GetTower(team, t)
		if tower ~= nil and tower:IsAlive() then
			local d = GetUnitToLocationDistance(tower, loc)
			if d <= radius then return tower end
		end
	end
	return nil
end

local function tryTPToAssembly(bot, assembleLoc)
	if DotaTime() - lastTPAttempt < TP_COOLDOWN_BETWEEN_ATTEMPTS then return false end
	if J.CanNotUseAbility(bot) then return false end
	-- Don't TP if enemies near (gets cancelled / interrupted)
	local nearbyEnemies = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if nearbyEnemies ~= nil and #nearbyEnemies > 0 then return false end
	-- Don't TP if recently damaged
	if bot:WasRecentlyDamagedByAnyHero(2.5) then return false end

	local tpScroll = nil
	for slot = 0, 16 do
		local item = bot:GetItemInSlot(slot)
		if item ~= nil and not item:IsNull() and item:GetName() == 'item_tpscroll'
		   and item:IsFullyCastable() then
			tpScroll = item
			break
		end
	end
	if tpScroll == nil then return false end

	local destTower = findFriendlyTowerNearLoc(assembleLoc, TP_NEAR_TOWER_RADIUS)
	if destTower == nil then return false end

	local dest = destTower:GetLocation()
	bot:Action_UseAbilityOnLocation(tpScroll, dest)
	lastTPAttempt = DotaTime()
	return true
end

function Think()
	if J.CanNotUseAction(bot) then return end
	if assembleLoc == nil then return end

	local dist = GetUnitToLocationDistance(bot, assembleLoc)
	if dist <= ARRIVE_RADIUS then
		assembleLoc = nil
		return
	end

	-- TP if far enough that walking would take too long
	if dist > TP_DISTANCE_THRESHOLD then
		if tryTPToAssembly(bot, assembleLoc) then return end
	end

	bot:Action_MoveToLocation(assembleLoc)
end
