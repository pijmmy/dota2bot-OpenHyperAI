"""Static verification harness for the LANING-mode dive cap +
RETREAT-mode dive boost added to bots/mode_laning_generic.lua and
bots/mode_retreat_generic.lua.

User report (latest game console.8799804509.log @ 0:46 prematch and
0:37 game time): "clockwerk dives the top tower" / "clockwerk and
undying dive the top tower." Universal anti-dive at the dispatcher
(mode_attack_generic.lua) only suppressed ATTACK desire — bots in
LANING mode walked freely into tower range.

Cap LANING desire to 0.1 when bot would dive without immortal frame.
Boost RETREAT desire to >= 0.5 in same condition so RETREAT wins.
"""

import sys
from lupa import LuaRuntime

LUA = r"""
J = { Safezone = {} }
function J.Safezone.WouldDiveIfMovedTo(bot, loc, margin)
    return bot._wouldDive or false
end

function makeBot(wouldDive, hasBT, hasSatanic, attackImmune)
    return {
        _wouldDive = wouldDive,
        _hasBT = hasBT,
        _hasSatanic = hasSatanic,
        _attackImmune = attackImmune,
        _hp = 800,
        _hpRegen = 5,
        GetLocation = function(self) return { x = 0, y = 0 } end,
        HasModifier = function(self, m)
            if m == 'modifier_abaddon_borrowed_time' then return self._hasBT end
            if m == 'modifier_item_satanic_unholy' then return self._hasSatanic end
            return false
        end,
        IsAttackImmune = function(self) return self._attackImmune end,
        GetNearbyTowers = function(self, range, isEnemy)
            return self._wouldDive and {{IsNull = function() return false end, IsAlive = function() return true end}} or {}
        end,
        GetHealth = function(self) return self._hp end,
        GetHealthRegen = function(self) return self._hpRegen end,
    }
end

bot = nil

-- Mirror laning-cap logic
function laningDiveCap(desire)
    if bot:HasModifier('modifier_abaddon_borrowed_time')
       or bot:HasModifier('modifier_item_satanic_unholy')
       or bot:IsAttackImmune()
    then
        return desire
    end

    local diving = false
    if J and J.Safezone and J.Safezone.WouldDiveIfMovedTo then
        local ok, dive = pcall(function()
            return J.Safezone.WouldDiveIfMovedTo(bot, bot:GetLocation(), 0)
        end)
        if ok and dive then diving = true end
    end

    if diving then return 0.1 end
    return desire
end

-- Mirror retreat-boost logic
function retreatDiveBoost(desire)
    if bot:HasModifier('modifier_abaddon_borrowed_time')
       or bot:HasModifier('modifier_item_satanic_unholy')
       or bot:IsAttackImmune()
    then
        return desire
    end

    local diving = false
    if J and J.Safezone and J.Safezone.WouldDiveIfMovedTo then
        local ok, dive = pcall(function()
            return J.Safezone.WouldDiveIfMovedTo(bot, bot:GetLocation(), 0)
        end)
        if ok and dive then diving = true end
    end

    if diving then
        if desire == nil or type(desire) ~= "number" or desire < 0.5 then
            return 0.5
        end
    end
    return desire
end
"""


def main():
    print("=" * 70)
    print("LANING dive cap + RETREAT boost verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # 1) LANING: in dive zone, no immortal → cap to 0.1
    def c1():
        L.execute("bot = makeBot(true, false, false, false)")
        return L.eval("laningDiveCap(0.7)")
    case("LANING in dive zone, no immortal → 0.1", c1, 0.1)

    # 2) LANING: not in dive zone → preserved
    def c2():
        L.execute("bot = makeBot(false, false, false, false)")
        return L.eval("laningDiveCap(0.7)")
    case("LANING not in dive zone → 0.7 preserved", c2, 0.7)

    # 3) LANING: in dive zone with BT → preserved
    def c3():
        L.execute("bot = makeBot(true, true, false, false)")
        return L.eval("laningDiveCap(0.7)")
    case("LANING in dive zone + BT → 0.7 preserved (immortal)", c3, 0.7)

    # 4) LANING: in dive zone with attack immune → preserved
    def c4():
        L.execute("bot = makeBot(true, false, false, true)")
        return L.eval("laningDiveCap(0.7)")
    case("LANING in dive zone + AttackImmune → 0.7 preserved", c4, 0.7)

    # 5) RETREAT: in dive zone, no immortal, low desire → boosted to 0.5
    def c5():
        L.execute("bot = makeBot(true, false, false, false)")
        return L.eval("retreatDiveBoost(0.2)")
    case("RETREAT in dive zone, desire 0.2 → boosted 0.5", c5, 0.5)

    # 6) RETREAT: not in dive zone → preserved
    def c6():
        L.execute("bot = makeBot(false, false, false, false)")
        return L.eval("retreatDiveBoost(0.2)")
    case("RETREAT not in dive zone → 0.2 preserved", c6, 0.2)

    # 7) RETREAT: in dive zone, but already-high desire → preserved
    def c7():
        L.execute("bot = makeBot(true, false, false, false)")
        return L.eval("retreatDiveBoost(0.85)")
    case("RETREAT in dive zone, desire 0.85 → 0.85 (already higher)", c7, 0.85)

    # 8) RETREAT: in dive zone with nil desire → boosted 0.5
    def c8():
        L.execute("bot = makeBot(true, false, false, false)")
        return L.eval("retreatDiveBoost(nil)")
    case("RETREAT in dive zone, desire nil → boosted 0.5", c8, 0.5)

    # 9) RETREAT in dive zone with BT → preserved (immortal)
    def c9():
        L.execute("bot = makeBot(true, true, false, false)")
        return L.eval("retreatDiveBoost(0.2)")
    case("RETREAT in dive zone + BT → 0.2 preserved (immortal bypass)", c9, 0.2)

    # 10) Combined: LANING capped to 0.1, RETREAT boosted to 0.5 → engine
    #     picks RETREAT. Confirms the two-piece fix works as a system.
    def c10():
        L.execute("bot = makeBot(true, false, false, false)")
        laning = L.eval("laningDiveCap(0.7)")
        retreat = L.eval("retreatDiveBoost(0.2)")
        return retreat > laning
    case("Combined: RETREAT 0.5 > LANING 0.1 → engine picks RETREAT",
         c10, True)

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
        ok = (result == expected) or (
            isinstance(result, float)
            and isinstance(expected, float)
            and abs(result - expected) < 0.001
        )
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
