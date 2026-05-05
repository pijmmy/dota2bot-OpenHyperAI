"""Static verification harness for game-theory pressure logic in
bots/FunLib/aba_gametheory.lua.

Verifies:
  - GetStrategicPressure: 0.7*nwPressure + 0.3*lvlPressure, clamped
  - GetThresholds: pressure-driven commit/push/rosh thresholds + ult bonus
  - GetPressureBias: mult = 1 + pressure * (target - 1) for each mode
"""

import sys
from lupa import LuaRuntime


GT_LUA = r"""
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function strategicPressure(myNW, enemyNW, myLvl, enemyLvl)
    local nwPressure = clamp((myNW - enemyNW) / 20000, -1, 1)
    local lvlPressure = clamp((myLvl - enemyLvl) / 5, -1, 1)
    return nwPressure * 0.7 + lvlPressure * 0.3
end

function getThresholds(pressure, ultReady)
    local t = {
        commitAllyThreshold = 2,
        pushAllyThreshold = 4,
        roshAllyThreshold = 3,
    }
    if pressure > 0.3 then
        t.commitAllyThreshold = 1
        t.pushAllyThreshold = 3
        t.roshAllyThreshold = 2
    elseif pressure < -0.3 then
        t.commitAllyThreshold = 2
        t.pushAllyThreshold = 4
        t.roshAllyThreshold = 3
    end
    if ultReady >= 3 then
        t.commitAllyThreshold = math.max(1, t.commitAllyThreshold - 1)
        t.pushAllyThreshold = math.max(3, t.pushAllyThreshold - 1)
    end
    if ultReady == 0 then
        t.commitAllyThreshold = t.commitAllyThreshold + 1
    end
    return t
end

local PRESSURE_BIAS = {
    push      = 1.08,
    team_roam = 1.05,
    roam      = 1.05,
    roshan    = 1.08,
    retreat   = 0.95,
    farm      = 0.97,
    defend    = 1.0,
}

function pressureBias(mode, pressure)
    local target = PRESSURE_BIAS[mode]
    if target == nil then return 1.0 end
    return 1 + pressure * (target - 1)
end
"""


def main():
    print("=" * 70)
    print("Game theory pressure verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(GT_LUA)

    passed = 0
    total = 0

    # --- strategicPressure ---
    print()
    print("strategicPressure (0.7*NW + 0.3*level)")
    print("-" * 70)

    cases = [
        # (description, myNW, enemyNW, myLvl, enemyLvl, expected)
        ("Equal: 0", 10000, 10000, 15, 15, 0),
        ("20k NW lead, equal levels: 0.7", 30000, 10000, 15, 15, 0.7),
        ("5-level lead, equal NW: 0.3", 10000, 10000, 20, 15, 0.3),
        ("Both maxed: 1.0", 30000, 10000, 20, 15, 1.0),
        ("20k NW behind: -0.7", 10000, 30000, 15, 15, -0.7),
        ("Way ahead clamped to 1.0", 60000, 10000, 30, 15, 1.0),
        ("Way behind clamped to -1.0", 10000, 60000, 15, 30, -1.0),
        ("10k NW lead = 0.5 NW pressure -> 0.35 contribution", 20000, 10000, 15, 15, 0.35),
    ]
    for desc, my, en, ml, el, expected in cases:
        total += 1
        result = L.eval(f"strategicPressure({my}, {en}, {ml}, {el})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    # --- getThresholds ---
    print()
    print("getThresholds")
    print("-" * 70)

    threshold_cases = [
        # (description, pressure, ultReady, expected_commit, expected_push, expected_rosh)
        ("Even (0), 1 ult: defaults",
         0.0, 1, 2, 4, 3),
        ("Even (0), 0 ults: commit +1",
         0.0, 0, 3, 4, 3),
        ("Ahead (0.5), 1 ult: aggressive thresholds",
         0.5, 1, 1, 3, 2),
        ("Ahead (0.5), 3 ults: most aggressive",
         0.5, 3, 1, 3, 2),  # 1->1 (max(1,0)) ; 3->3 (max(3,2))
        ("Ahead (0.5), 0 ults: commit++ even when ahead",
         0.5, 0, 2, 3, 2),
        ("Behind (-0.5), 1 ult: defaults",
         -0.5, 1, 2, 4, 3),
        ("Behind (-0.5), 3 ults: ult bonus",
         -0.5, 3, 1, 3, 3),
        ("Boundary 0.3 (NOT >0.3): defaults",
         0.3, 1, 2, 4, 3),
        ("Boundary 0.31: aggressive",
         0.31, 1, 1, 3, 2),
    ]
    for desc, p, ult, ec, ep, er in threshold_cases:
        total += 1
        L.execute(f"_t = getThresholds({p}, {ult})")
        c = L.eval("_t.commitAllyThreshold")
        ph = L.eval("_t.pushAllyThreshold")
        r = L.eval("_t.roshAllyThreshold")
        ok = c == ec and ph == ep and r == er
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got commit={c} push={ph} rosh={r} "
              f"(expected {ec}/{ep}/{er})")
        if ok:
            passed += 1

    # --- pressureBias ---
    print()
    print("pressureBias (mult = 1 + pressure * (target - 1))")
    print("-" * 70)

    bias_cases = [
        # (mode, pressure, expected)
        ("push at pressure=0: 1.0", "push", 0, 1.0),
        ("push at pressure=+1: 1.08", "push", 1, 1.08),
        ("push at pressure=-1: 0.92", "push", -1, 0.92),
        ("push at pressure=0.5: 1.04", "push", 0.5, 1.04),
        ("retreat at pressure=+1: 0.95 (retreat less when ahead)", "retreat", 1, 0.95),
        ("retreat at pressure=-1: 1.05 (retreat more when behind)", "retreat", -1, 1.05),
        ("farm at pressure=+1: 0.97", "farm", 1, 0.97),
        ("defend: always 1.0 (no bias)", "defend", 0.5, 1.0),
        ("Unknown mode: 1.0", "unknown", 0.5, 1.0),
    ]
    for desc, mode, p, expected in bias_cases:
        total += 1
        result = L.eval(f"pressureBias('{mode}', {p})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.4f} (expected {expected:.4f})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
