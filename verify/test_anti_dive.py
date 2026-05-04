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

-- Mocked bot/state inputs come from globals set by the test.
-- This mirrors the production guard chain in
-- bots/FunLib/override_generic/mode_attack_generic.lua.
function towerDiveGuard(b3, hasBT, hasSatanic, hasWKReinc, isAttackImmune,
                       wasHitByTower, towerExists, towerTargetingBot,
                       distToTower, botHP)
    -- Hard skip: low-HP suppression overrides immortal frames.
    -- Sourced from adamqqq's PushUtility AttackedByTowerRate gate
    -- (HP < 0.7 + 0.1*enemyCount means tower-tank is unsafe). We use
    -- a simpler 0.30 cutoff in attack mode because the focus is on
    -- "do not initiate a dive at low HP" not "calculate optimal tower
    -- DPS rate" — see docs/SOURCES.md.
    if botHP < 0.30 then
        local divingNow = false
        if wasHitByTower then divingNow = true end
        if towerExists then
            if towerTargetingBot then divingNow = true end
            if distToTower < 700 then divingNow = true end
        end
        if divingNow then return DESIRE_VERYLOW end
    end
    -- Soft skip: immortal frame OR teamfight commit (b3) overrides
    -- the dive guard, but only if HP is OK.
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

    HP_HEALTHY = 0.85
    HP_LOW = 0.20
    cases = [
        # (description, b3, BT, Satanic, WK, AttackImm, hitTower, towerExists, towerTargeting, distTower, hp, expected)
        ("Healthy bot taking tower hits, no immortal frame, no teamfight -> VERYLOW",
         False, False, False, False, False, True, True, False, 1500, HP_HEALTHY, DV_LOW),
        ("Tower targeting bot directly -> VERYLOW",
         False, False, False, False, False, False, True, True, 1500, HP_HEALTHY, DV_LOW),
        ("Bot inside tower range (500u) -> VERYLOW",
         False, False, False, False, False, False, True, False, 500, HP_HEALTHY, DV_LOW),
        ("Bot at exactly 700u from tower -> NOT diving (boundary, < not <=)",
         False, False, False, False, False, False, True, False, 700, HP_HEALTHY, DV_HIGH),
        ("Bot at 699u from tower -> VERYLOW",
         False, False, False, False, False, False, True, False, 699, HP_HEALTHY, DV_LOW),

        # Immortal-frame escapes (HEALTHY HP)
        ("Healthy BT active: dive freely -> NORMAL",
         False, True, False, False, False, True, True, True, 200, HP_HEALTHY, DV_HIGH),
        ("Healthy Satanic: dive freely",
         False, False, True, False, False, True, True, True, 200, HP_HEALTHY, DV_HIGH),
        ("Healthy WK reincarnation: dive freely",
         False, False, False, True, False, True, True, True, 200, HP_HEALTHY, DV_HIGH),
        ("Healthy Attack immune (BKB / WW Cold Embrace): dive freely",
         False, False, False, False, True, True, True, True, 200, HP_HEALTHY, DV_HIGH),

        # NEW: low-HP override of immortal frames (sourced from adamqqq)
        ("LOW HP + BT: still suppress (frame ends, dies anyway)",
         False, True, False, False, False, True, True, True, 200, HP_LOW, DV_LOW),
        ("LOW HP + Satanic: still suppress",
         False, False, True, False, False, True, True, True, 200, HP_LOW, DV_LOW),
        ("LOW HP + b3 teamfight: STILL SUPPRESS (low-HP block runs first)",
         True, False, False, False, False, True, True, True, 200, HP_LOW, DV_LOW),
        # Design choice: low-HP block fires BEFORE the b3 commit check.
        # Rationale: even in a 5-man teamfight, an individual at <30% HP
        # diving into tower range dies before contributing meaningful
        # damage. Bot peels back; team carries the fight. This is the
        # safer default. If lobby observation shows low-HP bots peeling
        # off necessary commits, swap the block order so b3 dominates.

        # HP exactly 0.30 boundary -> NOT low-HP (>= 0.30 passes)
        ("HP 0.30 exactly + BT: dive (boundary, not low-HP)",
         False, True, False, False, False, True, True, True, 200, 0.30, DV_HIGH),
        ("HP 0.299 + BT: low-HP suppress",
         False, True, False, False, False, True, True, True, 200, 0.299, DV_LOW),

        # No tower -> no danger
        ("No tower in 1600u: VERYHIGH",
         False, False, False, False, False, False, False, False, 9999, HP_HEALTHY, DV_HIGH),

        # Tower exists but bot far away
        ("Tower exists but bot 1500u away, no targeting, no hits",
         False, False, False, False, False, False, True, False, 1500, HP_HEALTHY, DV_HIGH),
    ]

    passed = 0
    total = 0
    for desc, b3, bt, sat, wk, ai, hit, te, tt, dist, hp, expected in cases:
        total += 1
        args = ", ".join(str(x).lower() if isinstance(x, bool) else str(x)
                         for x in [b3, bt, sat, wk, ai, hit, te, tt, dist, hp])
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
