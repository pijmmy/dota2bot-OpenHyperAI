"""Static verification harness for the Skywrath Q/W harass time-gate
in bots/BotLib/hero_skywrath_mage.lua.

Verifies:
  - Q-harass fires at first opportunity (gate empty)
  - Q-harass blocked within HARASS_GAP_Q (5s) since last cast
  - Q-harass fires again after gap elapsed
  - W-harass uses HARASS_GAP_W (8s)
  - Gates are independent (Q stamp doesn't affect W and vice versa)
"""

import sys
from lupa import LuaRuntime

LUA = r"""
local HARASS_GAP_Q = 5.0
local HARASS_GAP_W = 8.0
local nLastQHarassTime = -100
local nLastWHarassTime = -100
local _now = 0

function setNow(t) _now = t end
function DotaTime() return _now end

function resetState()
    nLastQHarassTime = -100
    nLastWHarassTime = -100
end

-- Returns true if Q harass would fire (mirrors the gate at hero_skywrath ConsiderQ:319)
function qHarassWouldFire(haveEnemies, mp, skillLV)
    if haveEnemies and mp > 0.5 and skillLV >= 2
        and DotaTime() - nLastQHarassTime > HARASS_GAP_Q
    then
        return true
    end
    return false
end

function wHarassWouldFire(haveEnemies, mp, skillLV, lvl)
    if haveEnemies and mp > 0.5 and (skillLV >= 2 or lvl <= 2)
        and DotaTime() - nLastWHarassTime > HARASS_GAP_W
    then
        return true
    end
    return false
end

function stampQHarass() nLastQHarassTime = DotaTime() end
function stampWHarass() nLastWHarassTime = DotaTime() end
"""


def main():
    print("=" * 70)
    print("Skywrath Q/W harass time-gate verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # 1) First Q harass fires
    def c1():
        L.execute("resetState()")
        L.execute("setNow(60.0)")
        return L.eval("qHarassWouldFire(true, 0.7, 2)")
    case("First Q harass at t=60, MP 70%, skill 2 → fires", c1, True)

    # 2) Stamp at t=60, second call at t=63 (within 5s window) → blocked
    def c2():
        L.execute("resetState()")
        L.execute("setNow(60.0)")
        L.execute("stampQHarass()")
        L.execute("setNow(63.0)")
        return L.eval("qHarassWouldFire(true, 0.7, 2)")
    case("Q harass at t=60, retry at t=63 (3s) → blocked", c2, False)

    # 3) Stamp at t=60, retry at t=66 (6s elapsed) → fires
    def c3():
        L.execute("resetState()")
        L.execute("setNow(60.0)")
        L.execute("stampQHarass()")
        L.execute("setNow(66.0)")
        return L.eval("qHarassWouldFire(true, 0.7, 2)")
    case("Q harass at t=60, retry at t=66 (6s) → fires", c3, True)

    # 4) Q stamp doesn't gate W
    def c4():
        L.execute("resetState()")
        L.execute("setNow(60.0)")
        L.execute("stampQHarass()")
        return L.eval("wHarassWouldFire(true, 0.7, 2, 6)")
    case("Q harass at t=60 doesn't gate W harass at same tick", c4, True)

    # 5) W harass blocked at 7s, fires at 9s
    def c5():
        L.execute("resetState()")
        L.execute("setNow(60.0)")
        L.execute("stampWHarass()")
        L.execute("setNow(67.0)")
        a = L.eval("wHarassWouldFire(true, 0.7, 2, 6)")
        L.execute("setNow(69.0)")
        b = L.eval("wHarassWouldFire(true, 0.7, 2, 6)")
        return (a, b)
    case("W stamp at t=60: blocked at 67 (7s), fires at 69 (9s)", c5, (False, True))

    # 6) MP gate still respected (insufficient mana skips even with empty gate)
    def c6():
        L.execute("resetState()")
        L.execute("setNow(60.0)")
        return L.eval("qHarassWouldFire(true, 0.4, 2)")
    case("MP 40% < 0.5 cap: no harass even with empty gate", c6, False)

    # 7) No enemies in range: no harass even with full mana
    def c7():
        L.execute("resetState()")
        L.execute("setNow(60.0)")
        return L.eval("qHarassWouldFire(false, 0.9, 2)")
    case("No enemies in range: no harass", c7, False)

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
