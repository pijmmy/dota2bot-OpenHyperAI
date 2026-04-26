--[[ Convex commitment + abort triggers (Phase 11 Item 4).

     Replaces the binary TACTIC_TIMEOUT model in aba_teamplan.lua. Real pros
     don't commit fully on tick 0 and disengage on tick 30 — they SHOW FACE,
     ramp commitment as positive signals accumulate (target isolated, ult up,
     vision gained), and abort hard on negative signals (TPs incoming, our
     initiator dead, mass HP drop).

     Two parts:
       1. Progress scalar in [0,1] per active task; updated each leader tick.
       2. Abort triggers that override desire entirely (zero out commitment).

     Commitment bonus to desire is convex (0.12 * prog^2), so it stays well
     inside the [0.85, 1.15] clamp even at full commitment.

     Exposed as J.Commitment.*
     ]]
local ____exports = {}

-- Per-task progress in [0, 1]. Resets to 0 when intent changes.
local _progress = {
    push_lane = 0, smoke_gank = 0, contest_rosh = 0, commit_kill = 0,
}
local _last_intent = nil
local _last_update_t = -999

-- ============================================================
-- Signal collectors. Each returns a count 0..5.
-- ============================================================

local function safeCall(fn, ...)
    local ok, ret = pcall(fn, ...)
    if ok then return ret end
    return nil
end

local function _jmz()
    local ok, J = pcall(require, GetScriptDirectory().."/FunLib/jmz_func")
    if ok then return J end
    return nil
end

local function countPositiveSignals(intent)
    local J = _jmz()
    if J == nil then return 0 end
    local n = 0
    local team = GetTeam()
    local enemyTeam = GetOpposingTeam()

    if intent == "push_lane" then
        -- Networth lead, tower being damaged, enemy buyback down (>25min)
        local okNW, myNW, enemyNW = pcall(function() return J.GetInventoryNetworth() end)
        if okNW and type(myNW) == "number" and (myNW - enemyNW) > 5000 then n = n + 1 end
        if J.TeamState then
            local conf = J.TeamState.MeanPerceivedConfidence()
            if conf > 0.6 then n = n + 1 end
            if J.TeamState.GetMacroAlert() == "GREEN" then n = n + 1 end
        end
        if DotaTime() > 25 * 60 then n = n + 1 end
    elseif intent == "smoke_gank" then
        if J.TeamState then
            local missing = J.TeamState.CountMissingEnemies(8)
            -- Smoke is GOOD when WE haven't been spotted (low enemy missing
            -- means enemies all visible elsewhere = clean rotation window).
            if missing == 0 then n = n + 2 end
            if J.TeamState.MeanPerceivedConfidence() > 0.5 then n = n + 1 end
        end
    elseif intent == "contest_rosh" then
        local aliveAllies = 0
        local players = GetTeamPlayers(team)
        for i = 1, #players do
            if IsHeroAlive(players[i]) then aliveAllies = aliveAllies + 1 end
        end
        if aliveAllies >= 5 then n = n + 2 end
        if aliveAllies >= 4 then n = n + 1 end
        if J.TeamState and J.TeamState.IsTeamCommitted("rosh") then n = n + 1 end
    elseif intent == "commit_kill" then
        if J.TeamState and J.TeamState.MeanPerceivedConfidence() > 0.6 then n = n + 1 end
    end
    return n
end

local function countNegativeSignals(intent)
    local J = _jmz()
    if J == nil then return 0 end
    local n = 0
    local team = GetTeam()

    -- Universal: our team HP low
    local hpSum, hpCount = 0, 0
    local players = GetTeamPlayers(team)
    for i = 1, #players do
        local m = GetTeamMember(i)
        if m ~= nil and m:IsAlive() then
            hpSum = hpSum + (m:GetHealth() / math.max(1, m:GetMaxHealth()))
            hpCount = hpCount + 1
        end
    end
    if hpCount > 0 then
        local meanHP = hpSum / hpCount
        if meanHP < 0.5 then n = n + 2 end
        if meanHP < 0.7 then n = n + 1 end
    end

    if J.TeamState then
        local missing = J.TeamState.CountMissingEnemies(8)
        if missing >= 2 and intent ~= "smoke_gank" then n = n + 1 end
        if missing >= 3 then n = n + 1 end
        local alert = J.TeamState.GetMacroAlert()
        if alert == "RED" then n = n + 2 end
        if alert == "ORANGE" then n = n + 1 end
    end

    -- Ancient under threat
    local ancient = GetAncient(team)
    if ancient ~= nil then
        local hp = ancient:GetHealth() / math.max(1, ancient:GetMaxHealth())
        if hp < 0.5 and intent ~= "defend_base" then n = n + 2 end
    end

    return n
end

-- ============================================================
-- Update progress for the active intent
-- ============================================================

local UPDATE_INTERVAL = 1.0

local function updateProgress(intent, now)
    if intent ~= _last_intent then
        -- Intent changed: reset all progress (the previous task is over).
        for k in pairs(_progress) do _progress[k] = 0 end
        _last_intent = intent
    end
    if _progress[intent] == nil then return end

    local pos = countPositiveSignals(intent)
    local neg = countNegativeSignals(intent)
    -- Convex ramp: faster early, plateau toward 1
    local delta = 0.10 * pos - 0.20 * neg
    local p = _progress[intent] + delta
    if p < 0 then p = 0 end
    if p > 1 then p = 1 end
    _progress[intent] = p
end

-- ============================================================
-- Abort triggers: hard override regardless of progress
-- ============================================================

local function shouldAbortIntent(intent)
    local J = _jmz()
    if J == nil then return false end
    if intent == "commit_kill" or intent == "smoke_gank" then
        if J.TeamState and J.TeamState.CountMissingEnemies(8) >= 3 then return true end
        local team = GetTeam()
        local hpSum, hpCount = 0, 0
        local players = GetTeamPlayers(team)
        for i = 1, #players do
            local m = GetTeamMember(i)
            if m ~= nil and m:IsAlive() then
                hpSum = hpSum + (m:GetHealth() / math.max(1, m:GetMaxHealth()))
                hpCount = hpCount + 1
            end
        end
        if hpCount > 0 and (hpSum / hpCount) < 0.40 then return true end
    end
    if intent == "contest_rosh" then
        if J.TeamState and J.TeamState.GetMacroAlert() == "RED" then return true end
    end
    return false
end

-- ============================================================
-- Public API
-- ============================================================

-- Called by team-plan after intent is computed. Updates progress.
function ____exports.Tick(intent)
    local now = DotaTime()
    if now - _last_update_t < UPDATE_INTERVAL then return end
    _last_update_t = now
    updateProgress(intent, now)
end

-- Returns commitment progress for the active intent in [0, 1].
function ____exports.GetProgress(intent)
    return _progress[intent] or 0
end

-- Convex bonus to desire. Stays in [0, 0.12] so multiplier stays in
-- [1.0, 1.12] — well inside the existing 0.85-1.15 clamp envelope.
function ____exports.GetDesireBonus(intent)
    local p = _progress[intent] or 0
    return 0.12 * (p * p)
end

-- Returns true if commitment should be aborted (hard reset to regroup).
function ____exports.ShouldAbort(intent)
    return shouldAbortIntent(intent)
end

-- Force-reset progress. Called when an abort fires or the team picks a
-- different intent.
function ____exports.Reset(intent)
    if intent == nil then
        for k in pairs(_progress) do _progress[k] = 0 end
    else
        _progress[intent] = 0
    end
end

function ____exports.Describe()
    local parts = {}
    for k, v in pairs(_progress) do
        if v > 0.01 then
            table.insert(parts, string.format("%s=%.2f", k, v))
        end
    end
    if #parts == 0 then return "idle" end
    return table.concat(parts, " ")
end

return ____exports
