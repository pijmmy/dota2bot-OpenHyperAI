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
    updateScoutAssignments(now)
    updateScoutResult(now)
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
