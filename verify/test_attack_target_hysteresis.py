"""Static verification harness for the sticky-attack-target hysteresis in
bots/FunLib/override_generic/mode_attack_generic.lua.

Verifies:
  - Within lock window (1.2s): keep cached target unless new pick is
    >= 1.5x cached score
  - Lock window expired: free re-pick
  - Cached target invalid (dead/illusion/can't see): switch immediately
  - 1.5x upgrade rule: borderline pick stays sticky, big upgrade switches
"""

import sys
from lupa import LuaRuntime


HYSTERESIS_LUA = r"""
local _lastAttackTarget = {}
local LOCK_SEC = 1.2

-- Mock unit container. valid: bool. canBeAttacked: bool.
local function mockUnit(id, valid, canBeAttacked)
    return {
        id = id,
        IsNull = function(self) return false end,
        IsAlive = function(self) return valid end,
        CanBeSeen = function(self) return valid end,
        IsIllusion = function(self) return false end,
    }
end

-- The sticky-target logic, extracted from production. `pid` is the
-- bot's player ID; `now` is mocked DotaTime.
function pickWithHysteresis(pid, freshPick, freshScore, now, freshPickCanBeAttacked)
    local cached = _lastAttackTarget[pid]
    local cachedValid = cached ~= nil
        and cached.unit ~= nil
        and not cached.unit:IsNull()
        and cached.unit:IsAlive()
        and cached.unit:CanBeSeen()
        and not cached.unit:IsIllusion()
        and cached.canBeAttacked  -- sim: J.CanBeAttacked(cached.unit)

    local picked = freshPick
    local pickedScore = freshScore
    if cachedValid and (now - cached.lockedAt) < LOCK_SEC then
        if freshPick == nil or freshScore < cached.score * 1.5 then
            picked = cached.unit
            pickedScore = cached.score
        end
    end
    if picked ~= nil then
        _lastAttackTarget[pid] = {
            unit = picked,
            score = pickedScore,
            lockedAt = (cachedValid and cached.unit == picked) and cached.lockedAt or now,
            canBeAttacked = (cachedValid and cached.unit == picked) and cached.canBeAttacked or freshPickCanBeAttacked,
        }
    end
    if picked == nil then return nil, 0 end
    return picked.id, pickedScore
end

function reset() _lastAttackTarget = {} end

function setUnitCanBeAttacked(pid, canAtk)
    if _lastAttackTarget[pid] then
        _lastAttackTarget[pid].canBeAttacked = canAtk
    end
end

-- Units track liveness in a shared table so tests can "kill" a cached unit
-- between picks (simulates target dying mid-fight).
_unitState = {}

function makeUnit(id)
    _unitState[id] = _unitState[id] or { alive = true }
    return {
        id = id,
        IsNull = function(self) return false end,
        IsAlive = function(self) return _unitState[id].alive end,
        CanBeSeen = function(self) return _unitState[id].alive end,
        IsIllusion = function(self) return false end,
    }
end

function killUnit(id)
    if _unitState[id] then _unitState[id].alive = false end
end

function reviveUnit(id)
    if _unitState[id] then _unitState[id].alive = true end
end
"""


def main():
    print("=" * 70)
    print("Attack target hysteresis verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(HYSTERESIS_LUA)

    passed = 0
    total = 0

    # First pick at t=0: target A score 100. Cache locks A.
    total += 1
    L.execute("reset()")
    L.execute("_unitState = {}; u_a = makeUnit('A'); u_b = makeUnit('B')")
    pid, score = L.eval("pickWithHysteresis(1, u_a, 100, 0, true)")
    ok = pid == "A" and score == 100
    print(f"  [{'PASS' if ok else 'FAIL'}] First pick locks A (got pid={pid}, score={score})")
    if ok: passed += 1

    # Within 0.5s: B scores 110 (slight upgrade) — keep A (sticky)
    total += 1
    pid, score = L.eval("pickWithHysteresis(1, u_b, 110, 0.5, true)")
    ok = pid == "A" and score == 100
    print(f"  [{'PASS' if ok else 'FAIL'}] At 0.5s B=110 (1.10x): stay sticky on A "
          f"(got pid={pid})")
    if ok: passed += 1

    # Within 1.0s: B scores 200 (2x A's 100) — switch to B (>=1.5x upgrade)
    total += 1
    pid, score = L.eval("pickWithHysteresis(1, u_b, 200, 1.0, true)")
    ok = pid == "B" and score == 200
    print(f"  [{'PASS' if ok else 'FAIL'}] At 1.0s B=200 (2x): switch to B "
          f"(got pid={pid})")
    if ok: passed += 1

    # Lock expired (>1.2s after switch): free re-pick. A scores 130, B 100. A wins.
    total += 1
    pid, score = L.eval("pickWithHysteresis(1, u_a, 130, 2.5, true)")
    ok = pid == "A" and score == 130
    print(f"  [{'PASS' if ok else 'FAIL'}] Lock expired, A=130 > B=100: switch back to A "
          f"(got pid={pid})")
    if ok: passed += 1

    # Cached target dies — invalid. New pick succeeds.
    total += 1
    L.execute("reset(); _unitState = {}")
    L.execute("u_a = makeUnit('A'); u_b = makeUnit('B')")
    L.eval("pickWithHysteresis(1, u_a, 100, 0, true)")
    L.execute("killUnit('A')")  # cached A dies mid-fight
    pid, score = L.eval("pickWithHysteresis(1, u_b, 50, 0.5, true)")
    ok = pid == "B" and score == 50
    print(f"  [{'PASS' if ok else 'FAIL'}] Cached A died: switch to B even at half score "
          f"(got pid={pid})")
    if ok: passed += 1

    # No fresh pick + cached invalid: nil
    total += 1
    L.execute("reset()")
    pid, score = L.eval("pickWithHysteresis(1, nil, 0, 0, true)")
    ok = pid is None
    print(f"  [{'PASS' if ok else 'FAIL'}] No fresh pick, no cache: nil "
          f"(got pid={pid})")
    if ok: passed += 1

    # Lock period boundary at 1.2s exactly: technically expired (< not <=)
    total += 1
    L.execute("reset()")
    L.execute("_unitState = {}; u_a = makeUnit('A'); u_b = makeUnit('B')")
    L.eval("pickWithHysteresis(1, u_a, 100, 0, true)")
    pid, score = L.eval("pickWithHysteresis(1, u_b, 50, 1.2, true)")
    # At exactly 1.2s, (now - lockedAt) is 1.2 which is NOT < 1.2.
    # So lock is expired and B wins (50 > nothing meaningful for sticky, free pick).
    ok = pid == "B"
    print(f"  [{'PASS' if ok else 'FAIL'}] At 1.2s exactly: lock expired, B=50 wins "
          f"(got pid={pid})")
    if ok: passed += 1

    # Multiple bots: per-pid cache doesn't bleed
    total += 1
    L.execute("reset()")
    L.execute("_unitState = {}; u_a = makeUnit('A'); u_b = makeUnit('B')")
    L.eval("pickWithHysteresis(1, u_a, 100, 0, true)")  # bot 1 -> A
    L.eval("pickWithHysteresis(2, u_b, 100, 0, true)")  # bot 2 -> B
    pid_1, _ = L.eval("pickWithHysteresis(1, u_b, 50, 0.5, true)")  # bot 1 should keep A
    pid_2, _ = L.eval("pickWithHysteresis(2, u_a, 50, 0.5, true)")  # bot 2 should keep B
    ok = pid_1 == "A" and pid_2 == "B"
    print(f"  [{'PASS' if ok else 'FAIL'}] Per-pid cache: bot 1 keeps A, bot 2 keeps B "
          f"(got 1={pid_1}, 2={pid_2})")
    if ok: passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
