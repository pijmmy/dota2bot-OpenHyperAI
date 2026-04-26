--[[ Hand-written to match typescript/bots/FunLib/aba_focus.ts.
     Focus target system — one priority enemy per team.
     Scored by isolation, HP, reachability, core/support value.
     Used by team-plan to trigger commit_kill when enough allies are near. ]]
local ____exports = {}

-- Lazy-load jmz to avoid require cycles.
local _jmz = nil
local function jmz()
    if _jmz == nil then
        _jmz = require(GetScriptDirectory().."/FunLib/jmz_func")
    end
    return _jmz
end

-- ============================================================
-- State
-- ============================================================

local FOCUS_RECOMPUTE_INTERVAL = 1.5
local FOCUS_TTL = 5.0
local ISOLATION_RADIUS = 1500
local REACHABLE_RADIUS = 2200
local LAST_SEEN_WINDOW = 4.0

local currentFocus = {
    unit = nil,
    playerID = -1,
    score = 0,
    reason = "none",
    validUntil = 0,
    lastComputeTime = -999,
}

-- ============================================================
-- Helpers
-- ============================================================

local function distanceLocLoc(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function countEnemyAlliesNearLoc(enemyTeam, excludePID, loc, radius)
    local players = GetTeamPlayers(enemyTeam)
    local n = 0
    for i = 1, #players do
        local pid = players[i]
        if pid ~= excludePID and IsHeroAlive(pid) then
            local info = GetHeroLastSeenInfo(pid)
            if info ~= nil and info[1] ~= nil
               and info[1].location ~= nil
               and info[1].time_since_seen ~= nil
               and info[1].time_since_seen <= LAST_SEEN_WINDOW then
                local d = distanceLocLoc(info[1].location, loc)
                if d <= radius then n = n + 1 end
            end
        end
    end
    return n
end

local function findVisibleEnemyHero(pid)
    local J = jmz()
    local ok, enemies = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if not ok or enemies == nil then return nil end
    for i = 1, #enemies do
        local u = enemies[i]
        if J.IsValidHero(u) and not J.IsSuspiciousIllusion(u) then
            local okPid, uPid = pcall(function() return u:GetPlayerID() end)
            if okPid and uPid == pid then return u end
        end
    end
    return nil
end

local function describeReason(isolated, hp, reach, isCore)
    local parts = {}
    if isolated >= 1 then table.insert(parts, "isolated")
    elseif isolated > 0 then table.insert(parts, "semi-isolated") end
    if hp < 0.5 then table.insert(parts, "low-hp") end
    if isCore > 0.5 then table.insert(parts, "core") end
    if reach >= 3 then table.insert(parts, "we-have-3+-near") end
    if #parts == 0 then return "default" end
    return table.concat(parts, ",")
end

-- ============================================================
-- Core compute
-- ============================================================

local function computeFocus()
    local J = jmz()
    local enemyTeam = GetOpposingTeam()
    local enemyPlayers = GetTeamPlayers(enemyTeam)

    local bestScore = -1
    local bestResult = nil

    -- Phase 3: spike awareness factor. Pull once.
    local now = DotaTime()

    for i = 1, #enemyPlayers do
        local pid = enemyPlayers[i]
        if IsHeroAlive(pid) then
            local info = GetHeroLastSeenInfo(pid)
            if info ~= nil and info[1] ~= nil
               and info[1].location ~= nil
               and info[1].time_since_seen ~= nil
               and info[1].time_since_seen <= LAST_SEEN_WINDOW then
                local loc = info[1].location

                -- Reachability: someone on our team within REACHABLE_RADIUS
                local ourNear = J.GetAlliesNearLoc(loc, REACHABLE_RADIUS)
                if ourNear ~= nil and #ourNear > 0 then
                    -- Isolation
                    local enemiesAroundThem = countEnemyAlliesNearLoc(enemyTeam, pid, loc, ISOLATION_RADIUS)
                    local isolated = 0
                    if enemiesAroundThem == 0 then isolated = 1
                    elseif enemiesAroundThem == 1 then isolated = 0.3 end

                    local heroUnit = findVisibleEnemyHero(pid)
                    local hp = 1.0
                    local isCore = 0.5
                    local heroName = nil
                    if heroUnit ~= nil then
                        hp = J.GetHP(heroUnit)
                        isCore = J.IsCore(heroUnit) and 1 or 0
                        local okN, n = pcall(function() return heroUnit:GetUnitName() end)
                        if okN then heroName = n end
                    end
                    local lowHP = 1.0 - hp
                    local reach = math.min(#ourNear, 3) / 3

                    -- Phase 3: spike bonus. Killing a pre-spike enemy is valuable
                    -- (prevent their power spike); killing an in-spike enemy
                    -- interrupts their window. Post-spike enemy = lower priority,
                    -- they've already done their damage.
                    local spikeBonus = 0
                    if heroName ~= nil and J.DraftStrategy and J.DraftStrategy.GetSpikeState then
                        local state = J.DraftStrategy.GetSpikeState(heroName, now)
                        if state == "pre" then spikeBonus = 0.4    -- kill before they spike
                        elseif state == "in" then spikeBonus = 0.3 -- interrupt their window
                        elseif state == "post" then spikeBonus = -0.1 end
                    end

                    local score = 2.0 * isolated + 1.6 * lowHP + 0.6 * reach + 0.4 * isCore + spikeBonus

                    if score > bestScore then
                        bestScore = score
                        local reasonStr = describeReason(isolated, hp, #ourNear, isCore)
                        if spikeBonus ~= 0 then
                            reasonStr = reasonStr .. ",spike=" .. tostring(spikeBonus > 0 and "+" .. string.format("%.1f", spikeBonus) or string.format("%.1f", spikeBonus))
                        end
                        bestResult = {
                            unit = heroUnit,
                            playerID = pid,
                            score = score,
                            reason = reasonStr,
                            validUntil = 0,
                            lastComputeTime = 0,
                        }
                    end
                end
            end
        end
    end

    -- Reverted to 0.8 — user is crushing the enemy bots (3 vs 30). Making
    -- focus stricter would weaken enemy commits further. We WANT the enemy
    -- bots to commit aggressively on the human; that's what makes the game
    -- competitive.
    if bestResult ~= nil and bestResult.score >= 0.8 then
        return bestResult
    end
    return {
        unit = nil,
        playerID = -1,
        score = 0,
        reason = "no viable target",
        validUntil = 0,
        lastComputeTime = 0,
    }
end

-- ============================================================
-- Public API
-- ============================================================

function ____exports.GetFocus()
    return currentFocus
end

function ____exports.MaybeRecompute(bot)
    local now = DotaTime()
    if now - currentFocus.lastComputeTime < FOCUS_RECOMPUTE_INTERVAL then
        return currentFocus
    end
    local ok, result = pcall(computeFocus)
    if ok and result ~= nil then
        result.lastComputeTime = now
        result.validUntil = now + FOCUS_TTL
        currentFocus = result
    else
        currentFocus.lastComputeTime = now
    end
    return currentFocus
end

function ____exports.IsFocusTargetable(bot, maxRange)
    if bot == nil then return false end
    local f = currentFocus
    if f.unit == nil or DotaTime() > f.validUntil then return false end
    local J = jmz()
    if not J.IsValidHero(f.unit) then return false end
    local ok, dist = pcall(function() return GetUnitToUnitDistance(bot, f.unit) end)
    if not ok or dist == nil then return false end
    return dist <= maxRange
end

function ____exports.GetFocusIfInRange(bot, maxRange)
    if bot == nil then return nil end
    if not ____exports.IsFocusTargetable(bot, maxRange) then return nil end
    return currentFocus.unit
end

function ____exports.Describe()
    local f = currentFocus
    if f.unit == nil or DotaTime() > f.validUntil then return "none" end
    local ok, name = pcall(function() return f.unit:GetUnitName() end)
    if not ok then name = "unknown" end
    return name .. " [" .. f.reason .. " score=" .. string.format("%.2f", f.score) .. "]"
end

-- ============================================================
-- Phase 11 Item 10: objective-aware smoke target scoring.
--
-- Smoke target ≠ teamfight focus. Pre-fight smoke target should maximize
-- MAP SWING after kill, not just damage potential during fight. A kill
-- on a slightly lower-value hero is the right smoke pick if it removes
-- the only safe-lane defender or unlocks Roshan.
-- ============================================================

local SUPPORT_HEROES = {
    npc_dota_hero_dazzle = true,
    npc_dota_hero_oracle = true,
    npc_dota_hero_disruptor = true,
    npc_dota_hero_warlock = true,
    npc_dota_hero_witch_doctor = true,
    npc_dota_hero_lich = true,
    npc_dota_hero_keeper_of_the_light = true,
    npc_dota_hero_chen = true,
    npc_dota_hero_io = true,
    npc_dota_hero_treant = true,
    npc_dota_hero_omniknight = true,
}

local CARRY_HEROES = {
    npc_dota_hero_antimage = true,
    npc_dota_hero_spectre = true,
    npc_dota_hero_medusa = true,
    npc_dota_hero_terrorblade = true,
    npc_dota_hero_phantom_lancer = true,
    npc_dota_hero_naga_siren = true,
}

local function scoreSmokeTarget(enemyUnit)
    if enemyUnit == nil or not enemyUnit:IsAlive() then return -1 end
    local okN, name = pcall(function() return enemyUnit:GetUnitName() end)
    if not okN then return -1 end

    -- Isolation: distance from enemy team's nearest ally hero
    local nearAllies = enemyUnit:GetNearbyHeroes(1500, false, BOT_MODE_NONE) or {}
    local isolation = math.min(3, #nearAllies == 0 and 3 or (1500 / math.max(400, GetUnitToUnitDistance(enemyUnit, nearAllies[1]))))

    -- HP factor: low HP = easier kill
    local hp = enemyUnit:GetHealth() / math.max(1, enemyUnit:GetMaxHealth())
    local hp_factor = (1 - hp) * 1.5

    -- Buyback unavailability (late game): big swing if dead enemy can't bb
    local no_bb = 0
    if DotaTime() > 25 * 60 then
        local okBB, bb = pcall(function() return enemyUnit:GetBuybackCost() end)
        if okBB and type(bb) == "number" then
            local okG, g = pcall(function() return enemyUnit:GetGold() end)
            if okG and g ~= nil and g < bb then no_bb = 2 end
        end
    end

    -- Utility / support kill = bigger map swing (removes saves, vision)
    local utility = SUPPORT_HEROES[name] and 1.5 or 0

    -- Carry kill late = high value
    local nw = enemyUnit:GetNetWorth() or 0
    local nw_value = nw / 5000  -- normalize ~ [0, 4]

    -- Carry-specific: late-game carry kills enable rosh + push
    if CARRY_HEROES[name] and DotaTime() > 25 * 60 then
        nw_value = nw_value * 1.3
    end

    return 1.5 * isolation + hp_factor + no_bb + utility + 0.5 * nw_value
end

-- Returns the best smoke target (the enemy whose death gives biggest
-- map swing). Different from GetFocus — smoke targets can be lower-HP
-- supports while focus targets are typically high-value cores.
function ____exports.GetSmokeTarget()
    local enemyTeam = GetOpposingTeam()
    local enemies = GetUnitList(UNIT_LIST_ENEMY_HEROES) or {}
    local best = nil
    local best_score = -1
    for _, e in pairs(enemies) do
        if e ~= nil and not e:IsNull() and e:IsAlive() and not e:IsIllusion() then
            local s = scoreSmokeTarget(e)
            if s > best_score then
                best_score = s
                best = e
            end
        end
    end
    return best, best_score
end

return ____exports
