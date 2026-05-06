"""Static verification harness for the per-hero gap-closer anti-dive
guards added across hero_sand_king, hero_mirana, hero_slark,
hero_faceless_void, hero_phoenix, hero_tusk, hero_ember_spirit,
hero_pangolier.

All 8 heroes use the same logic shape:
  if J.Safezone.WouldDiveIfMovedTo(bot, gapCloserDestination, 0)
     and not <immortal-frame modifiers>
     and not bot:IsAttackImmune()
     and <cluster gate, eg #enemies < 3>
  then
     return BOT_ACTION_DESIRE_NONE  -- suppress
  end
  return BOT_ACTION_DESIRE_HIGH, ...

This suite verifies the canonical pattern itself: the gate fires on
dive risk, immortal frames bypass, cluster size 3+ bypasses, and
non-dive locations don't trigger suppression.
"""

import sys
from lupa import LuaRuntime

LUA = r"""
J = { Safezone = {} }
function J.Safezone.WouldDiveIfMovedTo(bot, loc, margin)
    return loc._wouldDive or false
end

function makeBot(borrowedTime, satanic, attackImmune)
    return {
        _hasBT = borrowedTime,
        _hasSatanic = satanic,
        _attackImmune = attackImmune,
        HasModifier = function(self, m)
            if m == 'modifier_abaddon_borrowed_time' then return self._hasBT end
            if m == 'modifier_item_satanic_unholy' then return self._hasSatanic end
            return false
        end,
        IsAttackImmune = function(self) return self._attackImmune end,
    }
end

function makeLoc(wouldDive)
    return { _wouldDive = wouldDive }
end

-- Canonical gap-closer guard pattern (no cluster carve-out)
function gapCloserGuard(bot, dest)
    if J.Safezone and J.Safezone.WouldDiveIfMovedTo
       and J.Safezone.WouldDiveIfMovedTo(bot, dest, 0)
       and not bot:HasModifier('modifier_abaddon_borrowed_time')
       and not bot:HasModifier('modifier_item_satanic_unholy')
       and not bot:IsAttackImmune()
    then
        return 'SUPPRESS'
    end
    return 'CAST'
end

-- Cluster-carve-out variant (Mirana / Phoenix / Tusk / Ember / FV / Pango)
function gapCloserGuardCluster(bot, dest, enemyCount)
    if J.Safezone and J.Safezone.WouldDiveIfMovedTo
       and J.Safezone.WouldDiveIfMovedTo(bot, dest, 0)
       and not bot:HasModifier('modifier_abaddon_borrowed_time')
       and not bot:HasModifier('modifier_item_satanic_unholy')
       and not bot:IsAttackImmune()
       and enemyCount < 3
    then
        return 'SUPPRESS'
    end
    return 'CAST'
end
"""


def main():
    print("=" * 70)
    print("Per-hero gap-closer anti-dive guard verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # Canonical guard (Sand King, Slark)
    def c1():
        return L.eval(
            "gapCloserGuard(makeBot(false, false, false), makeLoc(true))"
        )
    case("Dive location, no immortal → SUPPRESS", c1, "SUPPRESS")

    def c2():
        return L.eval(
            "gapCloserGuard(makeBot(false, false, false), makeLoc(false))"
        )
    case("Safe location → CAST", c2, "CAST")

    def c3():
        return L.eval(
            "gapCloserGuard(makeBot(true, false, false), makeLoc(true))"
        )
    case("Dive location + Borrowed Time → CAST (BT bypass)", c3, "CAST")

    def c4():
        return L.eval(
            "gapCloserGuard(makeBot(false, true, false), makeLoc(true))"
        )
    case("Dive location + Satanic → CAST (Satanic bypass)", c4, "CAST")

    def c5():
        return L.eval(
            "gapCloserGuard(makeBot(false, false, true), makeLoc(true))"
        )
    case("Dive location + AttackImmune → CAST (immunity bypass)", c5, "CAST")

    # Cluster-carve-out variant
    def c6():
        return L.eval(
            "gapCloserGuardCluster(makeBot(false, false, false), makeLoc(true), 2)"
        )
    case("Dive location, 2 enemies (< 3) → SUPPRESS", c6, "SUPPRESS")

    def c7():
        return L.eval(
            "gapCloserGuardCluster(makeBot(false, false, false), makeLoc(true), 3)"
        )
    case("Dive location, 3 enemies (cluster pays trade) → CAST", c7, "CAST")

    def c8():
        return L.eval(
            "gapCloserGuardCluster(makeBot(false, false, false), makeLoc(true), 5)"
        )
    case("Dive location, 5-man fight → CAST (big cluster)", c8, "CAST")

    def c9():
        return L.eval(
            "gapCloserGuardCluster(makeBot(false, false, false), makeLoc(false), 1)"
        )
    case("Safe location, 1 enemy → CAST (no dive risk)", c9, "CAST")

    # Combined
    def c10():
        return L.eval(
            "gapCloserGuardCluster(makeBot(true, false, false), makeLoc(true), 1)"
        )
    case("Dive + BT + 1 enemy → CAST (BT bypass overrides cluster)", c10, "CAST")

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
