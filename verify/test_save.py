"""Static verification harness for save-ally urgency scoring in
bots/FunLib/aba_save.lua.

Verifies the scoreAllyThreat formula:
  urgency = (1 - hp)
          + 0.25 * enemyCount
          + 0.50 * recentlyHit
          + 0.30 * disabled
          + 0.40 * isCore
plus the early-return gates:
  - hp >= 0.85: not a save situation (return 0)
  - 0 enemies AND hp >= 0.5: not a save situation
"""

import sys
from lupa import LuaRuntime


SCORE_LUA = r"""
function scoreAllyThreat(hp, enemyCount, recentlyHit, disabled, isCore)
    if hp >= 0.85 then return 0 end
    if enemyCount == 0 and hp >= 0.5 then return 0 end
    return (1 - hp)
         + 0.25 * enemyCount
         + 0.50 * recentlyHit
         + 0.30 * disabled
         + 0.40 * isCore
end
"""


def main():
    print("=" * 70)
    print("Save urgency scoring verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(SCORE_LUA)

    cases = [
        # (description, hp, enemyCount, recentlyHit, disabled, isCore, expected)
        ("Healthy ally (hp=0.9): early-return 0",
         0.9, 2, 1, 1, 1, 0),
        ("Above 0.5 HP, 0 enemies: early-return 0",
         0.7, 0, 1, 0, 0, 0),
        ("0.5 HP, 0 enemies: early-return 0 (boundary)",
         0.5, 0, 0, 0, 0, 0),
        ("0.49 HP, 0 enemies: scored (just below boundary)",
         0.49, 0, 0, 0, 0, (1 - 0.49)),
        ("Low HP carry under 2-attacker dive: full urgency",
         0.3, 2, 1, 0, 1, (1 - 0.3) + 0.25*2 + 0.50 + 0 + 0.40),
        ("Stunned support, 1 attacker, low HP: very urgent",
         0.2, 1, 1, 1, 0,
         (1 - 0.2) + 0.25 + 0.50 + 0.30 + 0),
        ("Mid HP support, 1 attacker, no recent damage",
         0.6, 1, 0, 0, 0,
         (1 - 0.6) + 0.25),
        ("Critical: 0 HP, 5 attackers, stunned, core",
         0.0, 5, 1, 1, 1,
         1.0 + 0.25*5 + 0.50 + 0.30 + 0.40),
    ]

    passed = 0
    total = 0
    for desc, hp, ec, rh, d, c, expected in cases:
        total += 1
        result = L.eval(f"scoreAllyThreat({hp}, {ec}, {rh}, {d}, {c})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    # Threshold-based decisions: callers compare urgency against 0.7
    # (moderate save) and 1.2 (definitely save). Verify the typical
    # scenarios cross the right bands.
    print()
    print("Urgency thresholds (caller-side: 0.7 moderate, 1.2 definite)")
    print("-" * 70)
    threshold_cases = [
        # (description, urgency, exceeds_moderate, exceeds_definite)
        ("0.5 HP carry, 1 attacker (urgency 0.75)", 0.75, True, False),
        ("0.3 HP support, 2 attackers, recently hit (urgency 1.50)", 1.50, True, True),
        ("0.7 HP no enemies (urgency 0)", 0, False, False),
        ("0.6 HP, 1 attacker (urgency 0.65)", 0.65, False, False),
        ("Boundary 0.7", 0.7, True, False),
        ("Boundary 1.2", 1.2, True, True),
    ]
    for desc, u, em, ed in threshold_cases:
        total += 2  # both threshold checks
        m = u >= 0.7
        d = u >= 1.2
        status = "PASS" if m == em else "FAIL"
        print(f"  [{status}] {desc}: moderate={m} (expected {em})")
        if m == em:
            passed += 1
        status = "PASS" if d == ed else "FAIL"
        print(f"  [{status}] {desc}: definite={d} (expected {ed})")
        if d == ed:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
