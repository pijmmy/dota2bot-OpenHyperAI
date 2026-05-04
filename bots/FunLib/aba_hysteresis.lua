--[[ Hysteresis utilities for per-tick decision stability.

The bot script's decision functions (GetDesire / Think / Consider*) run
every frame. If a decision depends on a noisy signal (ally count near
edge of radius, enemy HP wobbling on regen ticks, last-seen timestamp
crossing the 5s window), the OUTPUT alternates frame-to-frame and the
bot oscillates: action toggles, attack target flickers between two
similarly-scoring enemies, retreat-then-attack-then-retreat each tick.

User feedback that drove this module:
  "they toggle or get stuck sometimes going backwards and forwards"
  "the bots just dive the towers"

Three primitives:

  H.StickyTarget(pid, fresh, freshScore, lockSec, upgradeMul)
    Generic sticky-target lock. Caches the last picked target per bot
    (PID-keyed) for `lockSec` seconds. Re-picks only when:
      - lock window expired, OR
      - cached target is invalid (dead/illusion/can't be seen), OR
      - new fresh pick scores >= cached.score * upgradeMul (default 1.5x)

  H.StickyGate(pid, gateName, fresh, holdSec)
    Boolean state that holds for `holdSec` seconds before flipping. Use
    for binary gates ("are we outnumbered?", "should we engage?") that
    flicker around the threshold each tick.

  H.StickyDesire(pid, modeTag, fresh, alpha)
    EMA-smoothed desire. Clamps frame-to-frame swings so a transient
    high-desire spike doesn't override a stable mid-desire mode. alpha
    of 0.30 means new value is 30% fresh + 70% history (one-frame
    swings are 30% of their amplitude).

All functions are safe to call without prior init — first call seeds
the cache with the fresh value.

Paired with TS source at typescript/bots/FunLib/aba_hysteresis.ts (TBD;
this module ships as Lua-first per the project's hand-written FunLib
convention — see ARCHITECTURE.md section 13).

See also docs/SOURCES.md for the audit that identified the application
sites and the lineage references that informed this design.
]]

local ____exports = {}

-- ============================================================
-- StickyTarget: 1.5s sticky lock with upgrade-multiplier override
-- ============================================================
--
-- Application sites identified by audit:
--   - aba_defend.lua DefendThink (hero target picker line ~1316/1361/1366)
--   - mode_farm_generic.lua Think (neutral creep target picker)
--   - mode_attack_generic.lua override (already has inline copy)
--   - aba_push.lua (already has inline copy as _lastSpecialTarget)
--   - team_roam SetStickyTarget (already has inline copy)
--
-- This module unifies the pattern so future application sites use
-- one canonical implementation instead of copy-pasting the lock logic.

local _stickyTargets = {}

local function isUnitValid(u)
    if u == nil then return false end
    local okNull, isNull = pcall(function() return u:IsNull() end)
    if okNull and isNull then return false end
    local okAlive, isAlive = pcall(function() return u:IsAlive() end)
    if okAlive and not isAlive then return false end
    local okSeen, canSee = pcall(function() return u:CanBeSeen() end)
    if okSeen and not canSee then return false end
    local okIll, isIll = pcall(function() return u:IsIllusion() end)
    if okIll and isIll then return false end
    return true
end

--[[ pid: per-bot key (use bot:GetPlayerID()).
     freshTarget: the unit just picked by the per-tick scorer (may be nil).
     freshScore: that pick's score.
     lockSec: seconds to keep the cached target before allowing free re-pick (default 1.5).
     upgradeMul: switch threshold; new pick must score >= cached.score * mul (default 1.5).
     domain: optional string namespace so one bot can have separate caches
             for different decision contexts (e.g. "attack" vs "defend").
     Returns: the unit to act on (cached or fresh), or nil if both are nil.
]]
function ____exports.StickyTarget(pid, freshTarget, freshScore, lockSec, upgradeMul, domain)
    lockSec = lockSec or 1.5
    upgradeMul = upgradeMul or 1.5
    domain = domain or "default"
    local key = tostring(pid) .. ":" .. domain

    local cached = _stickyTargets[key]
    local now = DotaTime()
    local cachedValid = cached ~= nil
        and cached.unit ~= nil
        and isUnitValid(cached.unit)

    local picked = freshTarget
    local pickedScore = freshScore or 0
    if cachedValid and (now - cached.lockedAt) < lockSec then
        if freshTarget == nil or (freshScore or 0) < cached.score * upgradeMul then
            picked = cached.unit
            pickedScore = cached.score
        end
    end

    if picked ~= nil then
        local sameAsCached = cachedValid and cached.unit == picked
        _stickyTargets[key] = {
            unit = picked,
            score = pickedScore,
            lockedAt = sameAsCached and cached.lockedAt or now,
        }
    end

    return picked, pickedScore
end

function ____exports.ClearStickyTarget(pid, domain)
    domain = domain or "default"
    local key = tostring(pid) .. ":" .. domain
    _stickyTargets[key] = nil
end

-- ============================================================
-- StickyGate: boolean state with hold window
-- ============================================================
--
-- For per-tick gates that flicker around a threshold ("am I outnumbered?",
-- "is the team grouped?", "should I retreat?"). Once the gate flips, it
-- stays in that state for `holdSec` seconds before another flip is allowed.
--
-- Application sites identified by audit:
--   - mode_team_roam_generic.lua:165 (ally-vs-enemy ratio gate)
--   - mode_retreat_generic.lua (#enemies-vs-#allies + bWeAreStronger gate)
--   - aba_defend.lua:1054 ds.nInRangeEnemy > ds.nInRangeAlly
--   - aba_support_auto.lua IsBusy

local _stickyGates = {}

--[[ pid: per-bot key.
     gateName: identifies the specific gate (e.g. "outnumbered", "team_grouped").
     fresh: the freshly computed boolean.
     holdSec: minimum seconds before a flip is allowed (default 1.5).
     Returns: the (held or fresh) boolean.
]]
function ____exports.StickyGate(pid, gateName, fresh, holdSec)
    holdSec = holdSec or 1.5
    local key = tostring(pid) .. ":" .. gateName
    local cached = _stickyGates[key]
    local now = DotaTime()

    if cached == nil then
        _stickyGates[key] = { state = fresh, lastChange = now }
        return fresh
    end

    if cached.state ~= fresh then
        if (now - cached.lastChange) < holdSec then
            return cached.state
        end
        _stickyGates[key] = { state = fresh, lastChange = now }
        return fresh
    end

    return cached.state
end

-- ============================================================
-- StickyDesire: EMA smoothing
-- ============================================================
--
-- For mode-level desires that swing high<->low between ticks. Returns
-- the EMA: new = old * (1 - alpha) + fresh * alpha. Lower alpha =
-- more smoothing.
--
-- Application sites identified by audit:
--   - mode_retreat_generic.lua (no smoothing today; mode_attack has alpha=0.30 inline)
--
-- Existing sites with their own EMA stay as-is — this utility is for
-- new applications. Deduplicate later if patterns overlap exactly.

local _stickyDesires = {}

function ____exports.StickyDesire(pid, modeTag, fresh, alpha)
    alpha = alpha or 0.30
    local key = tostring(pid) .. ":" .. modeTag
    local cached = _stickyDesires[key]
    if cached == nil then
        _stickyDesires[key] = fresh
        return fresh
    end
    local smoothed = cached * (1 - alpha) + (fresh or 0) * alpha
    _stickyDesires[key] = smoothed
    return smoothed
end

function ____exports.ResetStickyDesire(pid, modeTag)
    local key = tostring(pid) .. ":" .. modeTag
    _stickyDesires[key] = nil
end

-- ============================================================
-- Debug
-- ============================================================

function ____exports.Describe(pid, domain)
    domain = domain or "default"
    local key = tostring(pid) .. ":" .. domain
    local cached = _stickyTargets[key]
    if cached == nil then return "no sticky" end
    if not isUnitValid(cached.unit) then return "stale" end
    local okN, name = pcall(function() return cached.unit:GetUnitName() end)
    if not okN then name = "?" end
    return string.format("%s score=%.2f age=%.1fs",
        name, cached.score, DotaTime() - cached.lockedAt)
end

return ____exports
