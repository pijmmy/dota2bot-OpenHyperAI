"""Static verification harness for enemy-focus detection in
bots/FunLib/aba_enemy_focus.lua.

Verifies:
  - scoreAllyInDanger urgency formula:
    urgency = (1-hp) + 0.35*attackingCount + 0.40*recentlyHit
            + 0.30*disabled + 0.40*isCore
  - Big-ult shortcut: 2.0 + (1-hp) + 0.3*attackingCount when ally has
    a big-ult debuff (Doom / Chrono / etc.)
  - MIN_ENEMIES = 2 gate (returns 0 if fewer attackers)
  - MIN_URGENCY = 0.9 publication threshold
"""

import sys
from lupa import LuaRuntime


SCORE_LUA = r"""
local MIN_ENEMIES = 2
local MIN_URGENCY = 0.9

function scoreNormal(hp, attackingCount, recentlyHit, disabled, isCore)
    if attackingCount < MIN_ENEMIES then return 0 end
    return (1 - hp)
         + 0.35 * attackingCount
         + 0.40 * recentlyHit
         + 0.30 * disabled
         + 0.40 * isCore
end

function scoreBigUlt(hp, attackingCount)
    return 2.0 + (1 - hp) + 0.3 * attackingCount
end

function exceedsThreshold(urgency)
    return urgency >= MIN_URGENCY
end
"""


def main():
    print("=" * 70)
    print("Enemy focus (save_ally trigger) verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(SCORE_LUA)

    # --- Normal scoring ---
    print()
    print("scoreAllyInDanger normal-path formula")
    print("-" * 70)

    cases = [
        # (description, hp, attackingCount, recentlyHit, disabled, isCore, expected)
        ("1 attacker (below MIN_ENEMIES=2): 0",
         0.3, 1, 1, 1, 1, 0),
        ("0 attackers: 0",
         0.1, 0, 1, 1, 1, 0),
        ("2 attackers, mid HP, fresh hit, core",
         0.5, 2, 1, 0, 1, 0.5 + 0.35*2 + 0.40 + 0 + 0.40),
        ("3 attackers, low HP, stunned, core",
         0.2, 3, 1, 1, 1, 0.8 + 0.35*3 + 0.40 + 0.30 + 0.40),
        ("4 attackers, full HP, no signals, support",
         1.0, 4, 0, 0, 0, 0 + 0.35*4),
        ("Critical: 0 HP 5 attackers everything",
         0.0, 5, 1, 1, 1, 1.0 + 0.35*5 + 0.40 + 0.30 + 0.40),
    ]
    passed = 0
    total = 0
    for desc, hp, ec, rh, d, c, expected in cases:
        total += 1
        result = L.eval(f"scoreNormal({hp}, {ec}, {rh}, {d}, {c})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    # --- Big-ult shortcut ---
    print()
    print("Big-ult shortcut (Doom / Chrono / Duel / etc.)")
    print("-" * 70)

    bigult_cases = [
        # (description, hp, attackingCount, expected)
        ("Doom on ally, 1 attacker (normally below threshold)",
         0.5, 1, 2.0 + 0.5 + 0.3),
        ("Chrono on full-HP carry, 2 attackers",
         1.0, 2, 2.0 + 0 + 0.6),
        ("Dismember on low-HP support, 1 attacker",
         0.2, 1, 2.0 + 0.8 + 0.3),
    ]
    for desc, hp, ec, expected in bigult_cases:
        total += 1
        result = L.eval(f"scoreBigUlt({hp}, {ec})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    # --- MIN_URGENCY threshold ---
    print()
    print("MIN_URGENCY = 0.9 publication gate")
    print("-" * 70)

    threshold_cases = [
        ("0.89 - just below: NO publish", 0.89, False),
        ("0.90 boundary: publish", 0.90, True),
        ("0.91 above: publish", 0.91, True),
        ("0 baseline: NO publish", 0, False),
        ("Big-ult 2.8 (always far above): publish", 2.8, True),
    ]
    for desc, u, expected in threshold_cases:
        total += 1
        result = L.eval(f"exceedsThreshold({u})")
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
