--[[ Shared team belief / blackboard.

     Centralizes "should ONE bot do X, or should the WHOLE team do X" decisions.
     Currently scoped to scout-delegate-then-team-commit for Roshan; extensible
     to other objectives (deep wards, tormentor scouts, rune control) later.

     Pattern (from OpenAI Five Appendix E + canonical FuriousPuppy team_status.lua):
       1. Leader (lowest playerID alive) updates blackboard at most every 0.5s.
       2. Every other bot READS from blackboard, never re-queries world directly.
       3. Scout delegation: ONE bot is assigned per task; rest stand down on
          that task and wait for the scout's result to promote to team commit.

     Rationale: previously every bot independently called IsRoshanAlive() and
     evaluated rosh-mode desire each tick. That produced 5 bots converging on
     the same rosh pit redundantly + per-bot worldstate queries that bloat the
     bot VM. With a delegate pattern, exactly one bot scouts; team commits via
     team-plan only after the scout's result lands.

     Exposed as J.TeamState.* via jmz_func.lua.
     ]]
local ____exports = {}

-- Rate-limit blackboard updates. Leader runs at most every 0.5s of game time.
local UPDATE_INTERVAL = 0.5
local SCOUT_RESULT_TTL = 12.0   -- after this, scout must re-check
local SCOUT_TIMEOUT = 25.0      -- if scout hasn't reported in this long, re-delegate

-- Module-scope shared state. Visible to all bots via the J.TeamState namespace.
local _state = {
    leader_id = nil,
    last_update_t = -999,
    scout_delegate = {
        rosh = {
            owner_pid = -1,
            issued_at = -999,
            target_loc = nil,
            status = "unknown",   -- unknown | clear | alive | contested
            confidence = 0.0,
            valid_until = -999,
        },
    },
    -- Optional: track last-seen rosh body location for the scout to walk to.
    rosh_pit_loc = nil,

    -- Item 2: perceived enemy state. Leader-only writes. Other modules read
    -- via GetPerceivedEnemy(pid). Encodes "what we last saw vs ground truth"
    -- with confidence decay so engagement decisions don't act on ghost data.
    -- Schema: perceived_enemy[pid] = {
    --   last_seen_pos, last_seen_t, time_since_seen, confidence,
    --   predicted_pos, last_hp_pct, has_buyback, last_known_visible
    -- }
    perceived_enemy = {},

    -- Item 3: macro alert level + plan scorecard. Aggregates indirect signals
    -- (wave drift, tower chip, missing enemies, ward death, opposite-T fall)
    -- into a single team-wide threat indicator for desire modulation.
    macro_alert = "GREEN",   -- GREEN | YELLOW | ORANGE | RED
    plan_score = {
        smoke = 0.0, rosh = 0.0,
        push_top = 0.0, push_mid = 0.0, push_bot = 0.0,
        split = 0.0, invade_jungle = 0.0,
    },
    gank_alert = { severity = 0, target_zone = "none", expires_at = 0 },

    -- Item 8: wave equilibrium signal. lane_pressure[lane] is signed:
    -- positive = waves pushed toward enemy (we have map control there),
    -- negative = waves pushed toward us (defensive pressure).
    lane_pressure = { [1] = 0, [2] = 0, [3] = 0 },  -- LANE_TOP/MID/BOT
}

-- ============================================================
-- Helpers
-- ============================================================

local function aliveTeamPids()
    local team = GetTeam()
    local players = GetTeamPlayers(team)
    local out = {}
    for i = 1, #players do
        local pid = players[i]
        if IsHeroAlive(pid) then
            table.insert(out, pid)
        end
    end
    return out
end

local function getMember(pid)
    local team = GetTeam()
    local players = GetTeamPlayers(team)
    for i = 1, #players do
        if players[i] == pid then
            local m = GetTeamMember(i)
            if m ~= nil and not m:IsNull() then return m end
        end
    end
    return nil
end

local function selectLeader()
    -- Lowest playerID among alive bots; humans excluded so leader is always a
    -- bot (their decision-loop runs deterministically each tick).
    local best = nil
    for _, pid in ipairs(aliveTeamPids()) do
        local m = getMember(pid)
        if m ~= nil and m:IsBot() then
            if best == nil or pid < best then best = pid end
        end
    end
    return best
end

-- Score a candidate bot for rosh-scouting. Lower score = better scout.
-- Factors: distance to rosh, support-ness (pos 4/5 prefer scouting), low HP
-- penalty (sending a 30%-HP support is worse than a healthy one), networth
-- penalty (don't send the carry off-farm).
local function scoreScoutCandidate(unit, rosh_loc)
    if unit == nil or not unit:IsAlive() or unit:IsIllusion() then return 1e9 end
    local dist = GetUnitToLocationDistance(unit, rosh_loc)
    local hp = unit:GetHealth() / math.max(1, unit:GetMaxHealth())
    local nw = unit:GetNetWorth()

    local score = dist * 0.5             -- raw distance
    score = score - 600                   -- baseline (no role bonus = 0)
    if hp < 0.6 then score = score + 1500 end  -- penalize sending injured
    score = score + (nw / 1000) * 100     -- penalize sending the carry

    return score
end

-- ============================================================
-- Leader update — only the leader writes to _state
-- ============================================================

local function getRoshLoc()
    -- Cache the rosh pit location on first lookup; alternates between two
    -- pits in 7.34+ but for delegation purposes either is fine — the scout
    -- just needs to walk into the right pit and see whether rosh is there.
    if _state.rosh_pit_loc ~= nil then return _state.rosh_pit_loc end
    -- Try jmz helper if available
    local ok, J = pcall(require, GetScriptDirectory().."/FunLib/jmz_func")
    if ok and J ~= nil and J.GetCurrentRoshanLocation then
        local okLoc, loc = pcall(function() return J.GetCurrentRoshanLocation() end)
        if okLoc and loc ~= nil then
            _state.rosh_pit_loc = loc
            return loc
        end
    end
    -- Fallback: hardcoded radiant-side pit (close enough for scouting decision)
    return Vector(-2400, 1900, 256)
end

local function updateScoutAssignments(now)
    local rosh_slot = _state.scout_delegate.rosh
    -- If scout result is fresh, keep it.
    if rosh_slot.valid_until > now then return end
    -- If a scout is already on task and not timed out, leave them.
    if rosh_slot.owner_pid >= 0
       and (now - rosh_slot.issued_at) < SCOUT_TIMEOUT
       and rosh_slot.status == "unknown" then
        return
    end

    -- Pick a fresh delegate. Score all alive teammates; lowest score wins.
    local rosh_loc = getRoshLoc()
    local best_pid = -1
    local best_score = 1e9
    for _, pid in ipairs(aliveTeamPids()) do
        local m = getMember(pid)
        if m ~= nil and m:IsBot() then
            local s = scoreScoutCandidate(m, rosh_loc)
            if s < best_score then
                best_score = s
                best_pid = pid
            end
        end
    end

    if best_pid >= 0 then
        rosh_slot.owner_pid = best_pid
        rosh_slot.target_loc = rosh_loc
        rosh_slot.issued_at = now
        rosh_slot.status = "unknown"
        rosh_slot.confidence = 0.0
        rosh_slot.valid_until = -999
    end
end

local function updateScoutResult(now)
    -- The scout reports its observation. We poll IsRoshanAlive() ONCE here
    -- (leader-only) and credit the result to the delegated scout if they're
    -- close to the pit, otherwise leave status as "unknown".
    local rosh_slot = _state.scout_delegate.rosh
    if rosh_slot.owner_pid < 0 then return end

    local scout = getMember(rosh_slot.owner_pid)
    if scout == nil or not scout:IsAlive() then
        -- Scout died mid-mission. Reset for re-delegation next tick.
        rosh_slot.owner_pid = -1
        rosh_slot.status = "unknown"
        return
    end

    local d = GetUnitToLocationDistance(scout, rosh_slot.target_loc or getRoshLoc())
    if d <= 1500 then
        -- Close enough to "see" the pit. Record the answer.
        local ok, alive = pcall(function() return IsRoshanAlive() end)
        if ok then
            rosh_slot.status = alive and "alive" or "clear"
            rosh_slot.confidence = 0.9
            rosh_slot.valid_until = now + SCOUT_RESULT_TTL
        end
    end
end

-- ============================================================
-- Item 2: Perceived enemy state with confidence decay
-- ============================================================

local function clamp01(x)
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

local function updatePerceivedEnemies(now)
    local enemyTeam = GetOpposingTeam()
    local players = GetTeamPlayers(enemyTeam)
    for i = 1, #players do
        local pid = players[i]
        local pe = _state.perceived_enemy[pid]
        if pe == nil then
            pe = { time_since_seen = 999, confidence = 0,
                   has_buyback = true, last_hp_pct = 1.0 }
            _state.perceived_enemy[pid] = pe
        end

        local ok, info = pcall(function() return GetHeroLastSeenInfo(pid) end)
        if ok and info ~= nil and info[1] ~= nil then
            local first = info[1]
            local tss = first.time_since_seen or 999
            pe.time_since_seen = tss
            pe.last_seen_pos = first.location
            pe.last_seen_t = now - tss
            -- Confidence decays linearly to 0 over 15 seconds since last
            -- visible. Beyond 15s the bot has no real info — should not
            -- engage on this enemy as if their position is known.
            pe.confidence = clamp01(1 - tss / 15.0)
            pe.last_known_visible = (tss < 0.5)
        else
            -- No info at all (very early game / dead bot): full uncertainty.
            pe.confidence = 0
            pe.time_since_seen = 999
        end
    end
end

-- Item 3: indirect-signal threat assessment
local function countMissingEnemies(staleSeconds)
    local n = 0
    for _, pe in pairs(_state.perceived_enemy) do
        if (pe.time_since_seen or 999) >= staleSeconds then
            n = n + 1
        end
    end
    return n
end

local function updateMacroAlert(now)
    local missing = countMissingEnemies(8)
    local mean_conf = 0
    local count = 0
    for _, pe in pairs(_state.perceived_enemy) do
        mean_conf = mean_conf + (pe.confidence or 0)
        count = count + 1
    end
    if count > 0 then mean_conf = mean_conf / count end

    -- Score signals
    local a = 0
    if missing >= 3 then a = a + 2 end
    if missing >= 2 and now > 5 * 60 then a = a + 1 end
    if mean_conf < 0.3 and now > 8 * 60 then a = a + 1 end
    -- Ancient threat
    local ourAncient = pcall(GetAncient, GetTeam()) and GetAncient(GetTeam()) or nil
    if ourAncient ~= nil then
        local hp = ourAncient:GetHealth() / math.max(1, ourAncient:GetMaxHealth())
        if hp < 0.6 then a = a + 2 end
        if hp < 0.4 then a = a + 1 end
    end

    local alert = "GREEN"
    if a >= 4 then alert = "RED"
    elseif a >= 2 then alert = "YELLOW"
    end
    _state.macro_alert = alert

    -- Update gank alert with target zone if many missing
    if missing >= 3 then
        -- Compute centroid of last-seen positions of missing enemies
        local cx, cy, cnt = 0, 0, 0
        for _, pe in pairs(_state.perceived_enemy) do
            if (pe.time_since_seen or 999) >= 8 and pe.last_seen_pos then
                cx = cx + pe.last_seen_pos.x
                cy = cy + pe.last_seen_pos.y
                cnt = cnt + 1
            end
        end
        if cnt > 0 then
            cx = cx / cnt; cy = cy / cnt
            -- Classify zone by hardcoded thresholds
            local zone = "neutral"
            if math.abs(cx) > 4000 then zone = (cx > 0) and "bot_side" or "top_side"
            elseif math.abs(cy) > 4000 then zone = (cy > 0) and "dire_side" or "radiant_side"
            else zone = "mid"
            end
            _state.gank_alert = {
                severity = math.min(1.0, missing / 5),
                target_zone = zone,
                expires_at = now + 15,
            }
        end
    end
end

-- Item 8: wave equilibrium update. We don't have direct lane-collision-point
-- API, so we approximate using GetLaneFrontAmount or fallback to creep
-- lookup near each lane. Positive = waves toward enemy, negative = toward us.
local function updateLanePressure()
    local team = GetTeam()
    for _, lane in ipairs({1, 2, 3}) do  -- LANE_TOP/MID/BOT
        local ok, amount = pcall(function() return GetLaneFrontAmount(team, lane, true) end)
        if ok and type(amount) == "number" then
            -- amount in [0,1]: 0 = enemy fountain, 1 = our fountain.
            -- Convert to signed pressure: 0.5 is neutral.
            -- Positive = enemy pushing toward us is BAD, so we report
            -- (0.5 - amount) so positive = we're winning the lane.
            _state.lane_pressure[lane] = (0.5 - amount) * 2  -- [-1, 1]
        end
    end
end

-- ============================================================
-- Public API
-- ============================================================

-- Called by any bot from its Think tick. Only the leader actually does work.
function ____exports.MaybeUpdate(bot)
    if bot == nil then return end
    local now = DotaTime()
    if now - _state.last_update_t < UPDATE_INTERVAL then return end

    -- Leader election: lowest-pid alive bot. Recomputed every update tick so
    -- death of the leader hands off cleanly.
    _state.leader_id = selectLeader()
    if _state.leader_id == nil or bot:GetPlayerID() ~= _state.leader_id then
        return
    end

    _state.last_update_t = now
    updatePerceivedEnemies(now)
    updateMacroAlert(now)
    updateLanePressure()
    updateScoutAssignments(now)
    updateScoutResult(now)
end

-- Item 2: read perceived state for an enemy.
function ____exports.GetPerceivedEnemy(pid)
    return _state.perceived_enemy[pid]
end

-- Item 2: count enemies whose last-seen-info exceeds the given staleness.
-- Used by team-plan defensive gates ("3+ missing for 8s = back off").
function ____exports.CountMissingEnemies(staleSeconds)
    return countMissingEnemies(staleSeconds or 8)
end

-- Item 2: mean perceived-confidence across visible enemies. Drives the
-- info_advantage multiplier on offensive intents.
function ____exports.MeanPerceivedConfidence()
    local total, n = 0, 0
    for _, pe in pairs(_state.perceived_enemy) do
        if (pe.time_since_seen or 999) < 30 then
            total = total + (pe.confidence or 0)
            n = n + 1
        end
    end
    if n == 0 then return 0 end
    return total / n
end

-- Item 2: engagement gate. Returns true only if we have enough information
-- to commit on the given enemy. Implements BSJ's "2+ missing for 8s = abort".
function ____exports.ShouldEngage(focus_pid)
    local pe = _state.perceived_enemy[focus_pid]
    if pe == nil then return false end
    if (pe.confidence or 0) < 0.4 then return false end
    if countMissingEnemies(8) >= 2 then return false end
    return true
end

-- Item 3: macro alert level. Drives intent multipliers (offensive intents
-- dampened in YELLOW/RED, defensive amplified).
function ____exports.GetMacroAlert()
    return _state.macro_alert
end

-- Item 3: alert-derived multiplier. Stays inside [0.85, 1.15] envelope.
-- For offensive intents, call ApplyMacroAlertMult(desire, "offensive").
-- For defensive, call with "defensive" — high alert AMPLIFIES defense.
function ____exports.ApplyMacroAlertMult(desire, side)
    local map_off = { GREEN = 1.00, YELLOW = 0.95, ORANGE = 0.90, RED = 0.85 }
    local map_def = { GREEN = 1.00, YELLOW = 1.05, ORANGE = 1.10, RED = 1.15 }
    local m = (side == "defensive") and (map_def[_state.macro_alert] or 1.0)
                                     or (map_off[_state.macro_alert] or 1.0)
    return desire * m
end

-- Item 3: gank alert info (expected ambush zone if 3+ enemies missing).
function ____exports.GetGankAlert()
    if DotaTime() > _state.gank_alert.expires_at then
        return { severity = 0, target_zone = "none", expires_at = 0 }
    end
    return _state.gank_alert
end

-- Item 8: wave equilibrium. lane in {1,2,3}; returns signed pressure
-- in [-1, 1] where positive = we're pushing.
function ____exports.GetLanePressure(lane)
    return _state.lane_pressure[lane] or 0
end

-- Returns true if THIS bot is the delegated scout for the given task. Mode
-- desire functions should gate on this so non-delegated bots don't compete
-- with the scout for the same objective.
function ____exports.IsScoutFor(bot, task)
    if bot == nil then return false end
    local slot = _state.scout_delegate[task]
    if slot == nil then return false end
    return slot.owner_pid == bot:GetPlayerID()
end

-- Returns the current scout result for the task. Used by team-plan to
-- promote suspicion -> commit only after the scout has reported.
function ____exports.GetScoutResult(task)
    local slot = _state.scout_delegate[task]
    if slot == nil then return "unknown", 0.0 end
    if DotaTime() > slot.valid_until then return "unknown", 0.0 end
    return slot.status, slot.confidence
end

-- Has a fresh "alive + safe to commit" scout result landed for this task?
-- Team-plan reads this to upgrade rosh-suspicion to team-wide contest_rosh.
function ____exports.IsTeamCommitted(task)
    local status, conf = ____exports.GetScoutResult(task)
    return (status == "alive") and conf >= 0.8
end

-- Debug snapshot
function ____exports.Describe()
    local slot = _state.scout_delegate.rosh
    return string.format("rosh: owner=%d status=%s conf=%.2f valid_for=%.1fs",
        slot.owner_pid, slot.status, slot.confidence,
        math.max(0, slot.valid_until - DotaTime()))
end

return ____exports
