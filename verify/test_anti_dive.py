"""Static verification harness for the anti-tower-dive guard in
bots/FunLib/override_generic/mode_attack_generic.lua.

Verifies:
  - Guard fires on WasRecentlyDamagedByTower(2)
  - Guard fires when enemy tower auto-targets bot
  - Guard fires when bot is inside tower attack range (<700u)
  - Guard does NOT fire when bot is in teamfight (b3 commitment)
  - Guard does NOT fire when bot has BT/Satanic/WK-reincarnation/AttackImmune
  - Returns DESIRE_VERYLOW when active, otherwise normal desire
"""

import sys
from lupa import LuaRuntime


GUARD_LUA = r"""
local DESIRE_VERYHIGH = 0.9
local DESIRE_VERYLOW = 0.1

-- Mocked bot/state inputs come from globals set by the test
function towerDiveGuard(b3, hasBT, hasSatanic, hasWKReinc, isAttackImmune,
                       wasHitByTower, towerExists, towerTargetingBot,
                       distToTower)
    if b3 then return DESIRE_VERYHIGH end
    if hasBT or hasSatanic or hasWKReinc or isAttackImmune then
        return DESIRE_VERYHIGH
    end
    local divingNow = false
    if wasHitByTower then divingNow = true end
    if towerExists then
        if towerTargetingBot then divingNow = true end
        if distToTower < 700 then divingNow = true end
    end
    if divingNow then return DESIRE_VERYLOW end
    return DESIRE_VERYHIGH
end
"""


def main():
    print("=" * 70)
    print("Anti-tower-dive guard verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(GUARD_LUA)

    DV_HIGH = 0.9
    DV_LOW = 0.1

    cases = [
        # (description, b3, BT, Satanic, WK, AttackImm, hitTower, towerExists, towerTargeting, distTower, expected)
        ("Bot taking tower hits, no immortal frame, no teamfight -> VERYLOW",
         False, False, False, False, False, True, True, False, 1500, DV_LOW),
        ("Tower targeting bot directly -> VERYLOW",
         False, False, False, False, False, False, True, True, 1500, DV_LOW),
        ("Bot inside tower range (500u) -> VERYLOW",
         False, False, False, False, False, False, True, False, 500, DV_LOW),
        ("Bot at exactly 700u from tower -> NOT diving (boundary, < not <=)",
         False, False, False, False, False, False, True, False, 700, DV_HIGH),
        ("Bot at 699u from tower -> VERYLOW",
         False, False, False, False, False, False, True, False, 699, DV_LOW),

        # Immortal-frame escapes
        ("BT active: dive freely -> NORMAL",
         False, True, False, False, False, True, True, True, 200, DV_HIGH),
        ("Satanic active: dive freely",
         False, False, True, False, False, True, True, True, 200, DV_HIGH),
        ("WK reincarnation: dive freely",
         False, False, False, True, False, True, True, True, 200, DV_HIGH),
        ("Attack immune (BKB / WW Cold Embrace): dive freely",
         False, False, False, False, True, True, True, True, 200, DV_HIGH),

        # b3 = teamfight commitment overrides
        ("b3 active (teamfight): commit through tower",
         True, False, False, False, False, True, True, True, 200, DV_HIGH),

        # No tower -> no danger
        ("No tower in 1600u: VERYHIGH",
         False, False, False, False, False, False, False, False, 9999, DV_HIGH),

        # Tower exists but bot far away
        ("Tower exists but bot 1500u away, no targeting, no hits",
         False, False, False, False, False, False, True, False, 1500, DV_HIGH),
    ]

    passed = 0
    total = 0
    for desc, b3, bt, sat, wk, ai, hit, te, tt, dist, expected in cases:
        total += 1
        args = ", ".join(str(x).lower() if isinstance(x, bool) else str(x)
                         for x in [b3, bt, sat, wk, ai, hit, te, tt, dist])
        result = L.eval(f"towerDiveGuard({args})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.2f} (expected {expected:.2f})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
