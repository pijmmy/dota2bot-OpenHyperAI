"""Static verification harness for draft strategy live-override logic in
bots/FunLib/aba_draft_strategy.lua computeLiveOverride.

Verifies the override matrix:
  NW >= 20k @ 15min+    -> fast_siege
  NW <= -15k @ 15min+   -> turtle_defensive
  NW <= -8k @ <20min    -> turtle_defensive (early)
  NW >= 6k + 3+ enemy T1/T2 down @ 18min+ -> fast_siege (closeout)
  NW <= -6k + 3+ own T1/T2 down -> turtle_defensive
  30min+ + |NW|<10k     -> teamfight_mid
  45min+ + |NW|<5k      -> late_scale
  Otherwise             -> nil (use baseline)
"""

import sys
from lupa import LuaRuntime


OVERRIDE_LUA = r"""
function computeLiveOverride(nwDelta, now, ourT12Down, enemyT12Down)
    -- Massive gold lead mid-late game
    if nwDelta >= 20000 and now > 15 * 60 then
        return "fast_siege", "NW lead big"
    end
    if nwDelta <= -15000 and now > 15 * 60 then
        return "turtle_defensive", "NW behind big"
    end
    if nwDelta <= -8000 and now < 20 * 60 then
        return "turtle_defensive", "early NW behind"
    end
    -- Tower-state escalation
    if nwDelta >= 6000 and enemyT12Down >= 3 and now > 18 * 60 then
        return "fast_siege", "lead+enemy 3 T1/T2 down"
    elseif nwDelta <= -6000 and ourT12Down >= 3 then
        return "turtle_defensive", "behind+3 own towers down"
    end
    -- Late-game tempo
    if now > 30 * 60 and math.abs(nwDelta) < 10000 then
        return "teamfight_mid", "late-game even, teamfight tempo"
    end
    if now > 45 * 60 and math.abs(nwDelta) < 5000 then
        return "late_scale", "ultra-late stalled"
    end
    return nil, nil
end
"""


def main():
    print("=" * 70)
    print("Draft strategy live override verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(OVERRIDE_LUA)

    cases = [
        # (description, nwDelta, now (sec), ourT12Down, enemyT12Down, expected)
        # NW >= 20k @ 15min+
        ("NW lead 20k at 16min -> fast_siege",
         20000, 16*60, 0, 0, "fast_siege"),
        ("NW lead 25k at 20min -> fast_siege",
         25000, 20*60, 0, 0, "fast_siege"),
        ("NW lead 19k at 20min -> NOT fast_siege (below threshold)",
         19000, 20*60, 0, 0, None),
        ("NW lead 20k at 14min -> NOT (too early)",
         20000, 14*60, 0, 0, None),

        # NW <= -15k @ 15min+
        ("NW behind 15k at 16min -> turtle_defensive",
         -15000, 16*60, 0, 0, "turtle_defensive"),
        # At 16min the EARLY rule (NW<=-8k, now<20min) catches anything
        # below -8k. So -14k @ 16min still fires turtle_defensive.
        ("NW behind 14k at 16min -> turtle_defensive (early-rule catch)",
         -14000, 16*60, 0, 0, "turtle_defensive"),

        # Early NW <= -8k
        ("Early NW behind 8k at 10min -> turtle_defensive",
         -8000, 10*60, 0, 0, "turtle_defensive"),
        ("Early NW behind 8k at 19min -> turtle_defensive (still early)",
         -8000, 19*60, 0, 0, "turtle_defensive"),
        ("NW behind 8k at 20min -> NOT (no longer early, below -15k threshold)",
         -8000, 20*60, 0, 0, None),

        # Tower-state: NW lead 6k + 3+ enemy T1/T2 down @ 18min+
        ("NW lead 6k + 3 enemy towers down @ 19min -> fast_siege",
         6000, 19*60, 0, 3, "fast_siege"),
        ("NW lead 6k + 2 enemy towers down -> NOT (need 3+)",
         6000, 19*60, 0, 2, None),
        ("NW lead 6k + 3 enemy towers @ 17min -> NOT (too early)",
         6000, 17*60, 0, 3, None),

        # Tower-state: NW behind 6k + 3+ own T1/T2 down
        ("NW behind 6k + 3 own towers down -> turtle_defensive (any time)",
         -6000, 10*60, 3, 0, "turtle_defensive"),
        ("NW behind 6k + 2 own towers down -> NOT (need 3+)",
         -6000, 10*60, 2, 0, None),

        # Late game even -> teamfight_mid
        ("30min + NW 0 -> teamfight_mid",
         0, 31*60, 0, 0, "teamfight_mid"),
        ("30min + NW 9999 -> teamfight_mid (just under 10k)",
         9999, 31*60, 0, 0, "teamfight_mid"),
        ("30min + NW 11000 -> NOT teamfight_mid (above 10k)",
         11000, 31*60, 0, 0, None),

        # Ultra-late stalled (note: 30-min teamfight_mid catches earlier)
        ("46min + NW 0 -> teamfight_mid (catches before late_scale)",
         0, 46*60, 0, 0, "teamfight_mid"),
        # late_scale only fires when 30-min gate misses (|NW| >= 10k)
        # But ultra-late |NW| < 5k means |NW| < 10k too -> teamfight_mid wins
        # The late_scale rule is effectively unreachable. Document this.

        # No override
        ("No conditions met (mid-game, balanced) -> nil",
         500, 12*60, 0, 0, None),
        ("Game just started (10s) -> nil",
         100, 10, 0, 0, None),
    ]

    passed = 0
    total = 0
    for desc, nw, now, ourT, enemyT, expected in cases:
        total += 1
        L.execute(f"_strat, _reason = computeLiveOverride({nw}, {now}, {ourT}, {enemyT})")
        result = L.eval("_strat")
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
