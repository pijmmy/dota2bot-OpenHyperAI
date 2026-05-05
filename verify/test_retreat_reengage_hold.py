"""Static verification harness for the retreat-then-reengage cooldown
in bots/mode_attack_generic.lua.

Verifies:
  - When bot was in RETREAT mode within RETREAT_COOLDOWN_SEC, ATTACK
    desire is suppressed to 0.1
  - After cooldown elapses, ATTACK desire follows normal logic
  - Dive-cap suppression remains authoritative (preserves 0.1)
  - Attack-hold floor (0.7) does NOT fire while retreat cooldown active
"""

import sys
from lupa import LuaRuntime

LUA = r"""
local ATTACK_HOLD_SEC = 1.5
local RETREAT_COOLDOWN_SEC = 2.5
BOT_MODE_ATTACK = 6
BOT_MODE_RETREAT = 11

local _lastInAttackTime = -100
local _lastInRetreatTime = -100
local _now = 0

function setNow(t) _now = t end
function DotaTime() return _now end

function resetState()
    _lastInAttackTime = -100
    _lastInRetreatTime = -100
end

-- Mirror the dispatcher hysteresis logic
function attackHold(activeMode, hasTarget, dist, desireFromCap)
    if desireFromCap ~= nil and desireFromCap <= 0.15 then
        return desireFromCap
    end

    if activeMode == BOT_MODE_ATTACK then
        _lastInAttackTime = DotaTime()
    elseif activeMode == BOT_MODE_RETREAT then
        _lastInRetreatTime = DotaTime()
    end

    if DotaTime() - _lastInRetreatTime < RETREAT_COOLDOWN_SEC then
        return 0.1
    end

    if DotaTime() - _lastInAttackTime < ATTACK_HOLD_SEC then
        if hasTarget and dist < 1200 then
            return 0.7
        end
    end

    return desireFromCap
end
"""


def main():
    print("=" * 70)
    print("Retreat-then-reengage cooldown verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # 1) Bot in RETREAT at t=10, then at t=11 (1s elapsed) → 0.1 suppress
    def c1():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval("attackHold(BOT_MODE_RETREAT, true, 800, nil)")
        L.execute("setNow(11.0)")
        return L.eval("attackHold(0, true, 800, nil)")
    case("Retreated 1s ago → 0.1 suppress", c1, 0.1)

    # 2) Bot in RETREAT at t=10, then at t=12.6 (2.6s elapsed > 2.5s window) → fall through
    def c2():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval("attackHold(BOT_MODE_RETREAT, true, 800, nil)")
        L.execute("setNow(12.6)")
        return L.eval("attackHold(0, true, 800, nil)")
    case("Retreated 2.6s ago → cooldown expired, return nil (no override)", c2, None)

    # 3) Bot just in ATTACK at t=10, retreat-cooldown not active → hold floor 0.7
    def c3():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval("attackHold(BOT_MODE_ATTACK, true, 800, nil)")
    case("Just attacking, no recent retreat, target near → 0.7 hold", c3, 0.7)

    # 4) Was in ATTACK at t=10, then RETREAT at t=10.5, then check at t=11
    #    → retreat cooldown active → 0.1 (overrides hold floor)
    def c4():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval("attackHold(BOT_MODE_ATTACK, true, 800, nil)")
        L.execute("setNow(10.5)")
        L.eval("attackHold(BOT_MODE_RETREAT, true, 800, nil)")
        L.execute("setNow(11.0)")
        return L.eval("attackHold(0, true, 800, nil)")
    case("ATTACK at 10, RETREAT at 10.5, check at 11 → retreat cooldown wins", c4, 0.1)

    # 5) Dive cap 0.1 + retreating → preserved 0.1 (early return; doesn't restamp retreat)
    def c5():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval("attackHold(BOT_MODE_RETREAT, true, 800, 0.1)")
    case("Dive cap 0.1 + RETREAT mode → 0.1 preserved (dive cap auth)", c5, 0.1)

    # 6) No retreat ever, no attack → return nil (engine default)
    def c6():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval("attackHold(0, true, 800, nil)")
    case("No retreat, no attack → nil", c6, None)

    # 7) Retreat at exact RETREAT_COOLDOWN_SEC boundary (2.5s) → cooldown elapsed
    def c7():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval("attackHold(BOT_MODE_RETREAT, true, 800, nil)")
        L.execute("setNow(12.5)")  # 2.5s exactly, < not <=
        return L.eval("attackHold(0, true, 800, nil)")
    case("Retreat 2.5s ago exactly → cooldown elapsed (< not <=)", c7, None)

    # 8) Retreat just barely within (2.49s) → still suppressed
    def c8():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval("attackHold(BOT_MODE_RETREAT, true, 800, nil)")
        L.execute("setNow(12.49)")
        return L.eval("attackHold(0, true, 800, nil)")
    case("Retreat 2.49s ago → still suppressed", c8, 0.1)

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
        ok = (result == expected) or (
            isinstance(result, float)
            and isinstance(expected, float)
            and abs(result - expected) < 0.001
        )
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
