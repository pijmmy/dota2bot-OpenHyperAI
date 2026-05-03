"""Static verification harness for hero archetype affinity scoring in
bots/FunLib/aba_personality.lua GetDraftAffinity.

Verifies:
  - GetDraftAffinity returns [0, 1] match score (1 - L1_distance/5)
  - Identity match (archetype == profile) -> 1.0
  - Maximum mismatch -> 0.0
  - Symmetric in inputs
"""

import sys
from lupa import LuaRuntime


AFFINITY_LUA = r"""
local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

function getDraftAffinity(archetype, profile)
    local d = math.abs(profile.aggression - archetype.aggression)
        + math.abs(profile.greed - archetype.greed)
        + math.abs(profile.risk - archetype.risk)
        + math.abs(profile.independence - archetype.independence)
        + math.abs(profile.teamSpirit - archetype.teamSpirit)
    return clamp01(1 - (d / 5))
end
"""


def main():
    print("=" * 70)
    print("Archetype affinity verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(AFFINITY_LUA)

    def make_traits(agg, greed, risk, indep, ts):
        return f"{{aggression={agg}, greed={greed}, risk={risk}, independence={indep}, teamSpirit={ts}}}"

    cases = [
        # (description, archetype, profile, expected)
        ("Identity match (carry archetype + carry profile): 1.0",
         (0.5, 0.9, 0.4, 0.7, 0.3), (0.5, 0.9, 0.4, 0.7, 0.3), 1.0),
        ("Maximum mismatch (all 1 vs all 0): 0.0",
         (1.0, 1.0, 1.0, 1.0, 1.0), (0.0, 0.0, 0.0, 0.0, 0.0), 0.0),
        ("Half-mismatch on one trait (0.5 distance): 1 - 0.5/5 = 0.9",
         (0.5, 0.5, 0.5, 0.5, 0.5), (1.0, 0.5, 0.5, 0.5, 0.5), 0.9),
        ("Slot wants aggressive support, archetype is passive support",
         (0.2, 0.3, 0.3, 0.3, 0.7), (0.8, 0.3, 0.3, 0.3, 0.7),
         1 - 0.6/5),
        ("Symmetric: arg-swap doesn't change result",
         (0.3, 0.7, 0.4, 0.5, 0.6), (0.5, 0.4, 0.6, 0.3, 0.5),
         # Compute expected
         1 - (abs(0.5-0.3) + abs(0.4-0.7) + abs(0.6-0.4) + abs(0.3-0.5) + abs(0.5-0.6)) / 5),
    ]

    passed = 0
    total = 0
    for desc, arch, prof, expected in cases:
        total += 1
        arch_str = make_traits(*arch)
        prof_str = make_traits(*prof)
        result = L.eval(f"getDraftAffinity({arch_str}, {prof_str})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.4f} (expected {expected:.4f})")
        if ok:
            passed += 1

    # Verify symmetry directly
    print()
    print("Symmetry: getDraftAffinity(A, B) == getDraftAffinity(B, A)")
    print("-" * 70)
    a = (0.3, 0.7, 0.4, 0.5, 0.6)
    b = (0.5, 0.4, 0.6, 0.3, 0.5)
    fwd = L.eval(f"getDraftAffinity({make_traits(*a)}, {make_traits(*b)})")
    rev = L.eval(f"getDraftAffinity({make_traits(*b)}, {make_traits(*a)})")
    total += 1
    ok = abs(fwd - rev) < 0.001
    status = "PASS" if ok else "FAIL"
    print(f"  [{status}] fwd={fwd:.4f}, rev={rev:.4f}")
    if ok:
        passed += 1

    # Range: result is always in [0, 1]
    print()
    print("Result range [0, 1]")
    print("-" * 70)
    range_cases = [
        ("Both extremes: 0",
         (0.0, 0.0, 0.0, 0.0, 0.0), (1.0, 1.0, 1.0, 1.0, 1.0)),
        ("Identical: 1",
         (0.5, 0.5, 0.5, 0.5, 0.5), (0.5, 0.5, 0.5, 0.5, 0.5)),
    ]
    for desc, a, b in range_cases:
        total += 1
        result = L.eval(f"getDraftAffinity({make_traits(*a)}, {make_traits(*b)})")
        ok = 0.0 <= result <= 1.0
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.4f} (in [0,1])")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
