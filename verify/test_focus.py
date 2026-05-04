"""Static verification harness for focus picking in
bots/FunLib/aba_focus.lua.

Verifies:
  - computeFocus scoring formula
    score = 2.0*isolated + 1.6*lowHP + 0.6*reach + 0.4*isCore + spikeBonus
  - 0.8 threshold (below = "no viable target")
  - scoreSmokeTarget formula for smoke gank targeting
"""

import sys
from lupa import LuaRuntime


SCORE_LUA = r"""
function focusScore(isolated, lowHP, reach, isCore, spikeBonus)
    return 2.0 * isolated + 1.6 * lowHP + 0.6 * reach + 0.4 * isCore + (spikeBonus or 0)
end

-- Buyback gate (esports.net HG-siege rule, see docs/SOURCES.md).
-- After 25min, kills on targets that can buy back are 0.75x value
-- because the target respawns at full HP and walks back into the fight.
function focusScoreWithBB(isolated, lowHP, reach, isCore, spikeBonus,
                         now, hasBuybackGold)
    local raw = focusScore(isolated, lowHP, reach, isCore, spikeBonus)
    local bbPenalty = 1.0
    if now > 25 * 60 and hasBuybackGold then
        bbPenalty = 0.75
    end
    return raw * bbPenalty
end

function passesThreshold(score)
    return score >= 0.8
end

function smokeScore(isolation, hp_factor, no_bb, utility, nw_value)
    return 1.5 * isolation + hp_factor + no_bb + utility + 0.5 * nw_value
end
"""


def main():
    print("=" * 70)
    print("Focus picking verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(SCORE_LUA)

    cases = [
        # (description, isolated, lowHP, reach, isCore, spike, expected_score)
        # isolated values: 1.0 (alone), 0.3 (1 ally), 0 (>=2 allies)
        # reach: clamp(allies_near, 3) / 3 → [0, 1]
        ("Isolated low-HP core, full reach, no spike",
         1.0, 0.7, 1.0, 1.0, 0.0,
         2.0*1.0 + 1.6*0.7 + 0.6*1.0 + 0.4*1.0 + 0),
        ("Semi-isolated full-HP support, 1 ally near",
         0.3, 0.0, 1/3, 0.0, 0.0,
         2.0*0.3 + 1.6*0.0 + 0.6*(1/3) + 0.4*0.0 + 0),
        ("Pre-spike kill bonus +0.4",
         1.0, 0.5, 1.0, 1.0, 0.4,
         2.0*1.0 + 1.6*0.5 + 0.6*1.0 + 0.4*1.0 + 0.4),
        ("Post-spike penalty -0.1",
         1.0, 0.5, 1.0, 1.0, -0.1,
         2.0*1.0 + 1.6*0.5 + 0.6*1.0 + 0.4*1.0 - 0.1),
    ]

    passed = 0
    total = 0
    print()
    print("Score formula")
    print("-" * 70)
    for desc, iso, lowhp, reach, core, spike, expected in cases:
        total += 1
        result = L.eval(f"focusScore({iso}, {lowhp}, {reach}, {core}, {spike})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    print()
    print("0.8 threshold")
    print("-" * 70)

    threshold_cases = [
        # (description, score, expected_passes)
        ("Healthy isolated core: 0.79 (just below) -> reject",
         0.79, False),
        ("Healthy isolated core: 0.80 (boundary) -> accept",
         0.80, True),
        ("Healthy isolated core: 0.81 -> accept",
         0.81, True),
        ("Default no-target: 0.0 -> reject",
         0.0, False),
        # Realistic: full-HP, 2-ally, support, no spike
        # iso=0 (2+ enemies near), lowHP=0, reach=2/3, isCore=0
        # = 0 + 0 + 0.4 + 0 = 0.4 → reject
        ("Full-HP support with 2 enemies near (score 0.4) -> reject",
         0.4, False),
        # Solo support sighted: iso=1.0, lowHP=0, reach=1/3, isCore=0
        # = 2.0 + 0 + 0.2 + 0 = 2.2 → accept
        ("Solo support sighted (score 2.2) -> accept",
         2.2, True),
    ]

    for desc, score, expected in threshold_cases:
        total += 1
        result = L.eval(f"passesThreshold({score})")
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    # --- Buyback penalty (esports.net HG-siege rule) ---
    print()
    print("Buyback gate (post-25min, target with bb gold = 0.75x score)")
    print("-" * 70)

    bb_cases = [
        # (description, raw inputs, now, hasBuybackGold, expected_total)
        # Pre-25min, has bb -> no penalty
        ("Pre-25min target with bb gold: full score (penalty doesn't apply)",
         (1.0, 0.5, 1.0, 1.0, 0.0),  # iso=1, lowhp=0.5, reach=1, core=1, spike=0
         20 * 60, True,
         (2.0*1.0 + 1.6*0.5 + 0.6*1.0 + 0.4*1.0 + 0)),
        # Post-25min, has bb -> 0.75x
        ("Post-25min target with bb gold: 0.75x score",
         (1.0, 0.5, 1.0, 1.0, 0.0),
         30 * 60, True,
         (2.0*1.0 + 1.6*0.5 + 0.6*1.0 + 0.4*1.0 + 0) * 0.75),
        # Post-25min, no bb -> full
        ("Post-25min target without bb gold: full score",
         (1.0, 0.5, 1.0, 1.0, 0.0),
         30 * 60, False,
         (2.0*1.0 + 1.6*0.5 + 0.6*1.0 + 0.4*1.0 + 0)),
        # 25-min boundary (now > 25*60, not >=). At exactly 1500s, NOT triggered.
        ("Exactly 25min (1500s): bb penalty NOT applied (> not >=)",
         (1.0, 0.5, 1.0, 1.0, 0.0),
         25 * 60, True,
         (2.0*1.0 + 1.6*0.5 + 0.6*1.0 + 0.4*1.0 + 0)),
        ("25min + 1s: bb penalty applies",
         (1.0, 0.5, 1.0, 1.0, 0.0),
         25 * 60 + 1, True,
         (2.0*1.0 + 1.6*0.5 + 0.6*1.0 + 0.4*1.0 + 0) * 0.75),
    ]
    for desc, args, now, has_bb, expected in bb_cases:
        total += 1
        iso, lhp, reach, core, spike = args
        bb_lua = "true" if has_bb else "false"
        result = L.eval(f"focusScoreWithBB({iso}, {lhp}, {reach}, {core}, {spike}, {now}, {bb_lua})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    print()
    print("Smoke target scoring (scoreSmokeTarget)")
    print("-" * 70)

    smoke_cases = [
        # (description, isolation, hp_factor, no_bb, utility, nw_value, expected)
        ("Solo support, low HP, no buyback, late",
         3.0, (1 - 0.3) * 1.5, 2.0, 1.5, 1.0,
         1.5*3.0 + (1-0.3)*1.5 + 2.0 + 1.5 + 0.5*1.0),
        ("Carry, full HP, has bb, mid game",
         1.5, 0.0, 0.0, 0.0, 4.0,
         1.5*1.5 + 0 + 0 + 0 + 0.5*4.0),
        ("Isolated full-HP support",
         3.0, 0.0, 0.0, 1.5, 0.5,
         1.5*3.0 + 0 + 0 + 1.5 + 0.5*0.5),
    ]

    for desc, iso, hpf, bb, util, nw, expected in smoke_cases:
        total += 1
        result = L.eval(f"smokeScore({iso}, {hpf}, {bb}, {util}, {nw})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
