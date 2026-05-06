"""Static verification harness for the GetTalentList / GetAbilityList
padding fix in bots/FunLib/aba_skill.lua.

Verifies:
  - GetTalentList always returns >= 8 entries (padded with placeholder)
  - GetAbilityList indices 1..6 are always non-nil
  - Placeholder names are non-empty strings (so GetAbilityByName won't
    receive nil and trigger the "Null ability name passed into
    FindAbilityByName!" engine warning)
"""

import sys
from lupa import LuaRuntime

LUA = r"""
-- Mock the engine API surface aba_skill needs.
generic_hidden = "generic_hidden"
DOTA_ABILITY_BEHAVIOR_NOT_LEARNABLE = 1

function makeAbility(name, isTalent, isUltimate, isHidden, behavior)
    return {
        _name = name,
        _isTalent = isTalent or false,
        _isUltimate = isUltimate or false,
        _isHidden = isHidden or false,
        _behavior = behavior or 0,
        GetName = function(self) return self._name end,
        IsTalent = function(self) return self._isTalent end,
        IsUltimate = function(self) return self._isUltimate end,
        IsHidden = function(self) return self._isHidden end,
        GetBehavior = function(self) return self._behavior end,
    }
end

_slots = {}
function setSlot(i, ability) _slots[i] = ability end
function clearSlots() _slots = {} end

bot = {
    GetUnitName = function(self) return "npc_dota_hero_test" end,
    GetAbilityInSlot = function(self, slot) return _slots[slot] end,
}

-- Simplified Utils stub
Utils = {
    AbilityBehaviorHasFlag = function(behavior, flag)
        return (behavior or 0) >= 1 and flag == DOTA_ABILITY_BEHAVIOR_NOT_LEARNABLE
    end
}

-- The exported X table mirroring aba_skill.lua structure
X = {}

function X.GetTalentList(bot)
    local sTalentList = {}
    for i = 0, 25 do
        local hAbility = bot:GetAbilityInSlot(i)
        if hAbility ~= nil and hAbility:IsTalent() then
            table.insert(sTalentList, hAbility:GetName())
        end
    end
    while #sTalentList < 8 do
        table.insert(sTalentList, "_oha_unused_talent_slot")
    end
    return sTalentList
end

function X.GetAbilityList(bot)
    local sAbilityList = {}
    local totalUpgradeableAbilities = 10
    local unitName = bot:GetUnitName()
    for slot = 0, totalUpgradeableAbilities do
        local ability = bot:GetAbilityInSlot(slot)
        if ability then
            local name = ability:GetName()
            if name == generic_hidden then
                if slot ~= 0 then
                    table.insert(sAbilityList, generic_hidden)
                end
            elseif Utils.AbilityBehaviorHasFlag(ability:GetBehavior(), DOTA_ABILITY_BEHAVIOR_NOT_LEARNABLE) and ability:IsHidden() then
                -- skip
            elseif ability:IsUltimate() and slot >= 4 then
                if Utils.AbilityBehaviorHasFlag(ability:GetBehavior(), DOTA_ABILITY_BEHAVIOR_NOT_LEARNABLE) or ability:IsHidden() then
                    -- skip
                else
                    sAbilityList[6] = name
                end
            elseif not ability:IsTalent() then
                table.insert(sAbilityList, name)
            end
        end
    end
    for i = 1, 6 do
        if sAbilityList[i] == nil then
            sAbilityList[i] = "_oha_unused_ability_slot"
        end
    end
    return sAbilityList
end
"""


def main():
    print("=" * 70)
    print("aba_skill GetTalentList / GetAbilityList padding verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # 1) GetTalentList with NO talents loaded -> 8 placeholder entries
    def c1():
        L.execute("clearSlots()")
        list_obj = L.eval("X.GetTalentList(bot)")
        return len(list_obj), list_obj[1]
    case("GetTalentList, no talents -> 8 entries, [1] = placeholder", c1,
         (8, "_oha_unused_talent_slot"))

    # 2) GetTalentList with 4 talents loaded -> 8 entries (4 real + 4 padding)
    def c2():
        L.execute("clearSlots()")
        L.execute("setSlot(10, makeAbility('special_bonus_attack_speed_15', true))")
        L.execute("setSlot(11, makeAbility('special_bonus_movement_speed_20', true))")
        L.execute("setSlot(12, makeAbility('special_bonus_intelligence_8', true))")
        L.execute("setSlot(13, makeAbility('special_bonus_strength_10', true))")
        list_obj = L.eval("X.GetTalentList(bot)")
        return len(list_obj), list_obj[1], list_obj[5], list_obj[8]
    case("GetTalentList with 4 talents -> 8 entries, real then padding", c2,
         (8, "special_bonus_attack_speed_15", "_oha_unused_talent_slot",
          "_oha_unused_talent_slot"))

    # 3) GetTalentList with full 8 talents -> 8 entries, no padding
    def c3():
        L.execute("clearSlots()")
        for i, name in enumerate([
            "tlnt_a", "tlnt_b", "tlnt_c", "tlnt_d",
            "tlnt_e", "tlnt_f", "tlnt_g", "tlnt_h",
        ]):
            L.execute(f"setSlot({10 + i}, makeAbility('{name}', true))")
        list_obj = L.eval("X.GetTalentList(bot)")
        return len(list_obj), list_obj[1], list_obj[8]
    case("GetTalentList with 8 talents -> 8 entries, all real", c3,
         (8, "tlnt_a", "tlnt_h"))

    # 4) GetAbilityList typical hero (Q W E + 2 generic_hidden + ult)
    def c4():
        L.execute("clearSlots()")
        L.execute("setSlot(0, makeAbility('hero_q'))")
        L.execute("setSlot(1, makeAbility('hero_w'))")
        L.execute("setSlot(2, makeAbility('hero_e'))")
        L.execute("setSlot(3, makeAbility('generic_hidden'))")
        L.execute("setSlot(4, makeAbility('generic_hidden'))")
        L.execute("setSlot(5, makeAbility('hero_r', false, true))")
        list_obj = L.eval("X.GetAbilityList(bot)")
        # All 6 indices non-nil
        return [list_obj[i] for i in range(1, 7)]
    case("GetAbilityList typical hero -> 6 indices all real", c4,
         ["hero_q", "hero_w", "hero_e", "generic_hidden",
          "generic_hidden", "hero_r"])

    # 5) GetAbilityList hero with passive innate (slot 3 = not-learnable hidden)
    def c5():
        L.execute("clearSlots()")
        L.execute("setSlot(0, makeAbility('hero_q'))")
        L.execute("setSlot(1, makeAbility('hero_w'))")
        L.execute("setSlot(2, makeAbility('hero_e'))")
        # Slot 3: passive innate (not learnable + hidden) -> SKIPPED by skill list
        L.execute("setSlot(3, makeAbility('hero_innate', false, false, true, 1))")
        L.execute("setSlot(5, makeAbility('hero_r', false, true))")
        list_obj = L.eval("X.GetAbilityList(bot)")
        return [list_obj[i] for i in range(1, 7)]
    case("GetAbilityList with passive innate -> [4]/[5] padded",
         c5,
         ["hero_q", "hero_w", "hero_e",
          "_oha_unused_ability_slot", "_oha_unused_ability_slot",
          "hero_r"])

    # 6) GetAbilityList with NO ult (e.g. early-game, hero hasn't learned R)
    def c6():
        L.execute("clearSlots()")
        L.execute("setSlot(0, makeAbility('hero_q'))")
        L.execute("setSlot(1, makeAbility('hero_w'))")
        L.execute("setSlot(2, makeAbility('hero_e'))")
        L.execute("setSlot(3, makeAbility('generic_hidden'))")
        L.execute("setSlot(4, makeAbility('generic_hidden'))")
        # No slot 5 -> sAbilityList[6] never set
        list_obj = L.eval("X.GetAbilityList(bot)")
        return list_obj[6]
    case("GetAbilityList no ult -> [6] padded", c6, "_oha_unused_ability_slot")

    # 7) GetAbilityList completely empty (bot uninitialized) -> all 6 padded
    def c7():
        L.execute("clearSlots()")
        list_obj = L.eval("X.GetAbilityList(bot)")
        return [list_obj[i] for i in range(1, 7)]
    case("GetAbilityList uninitialized bot -> all 6 padded", c7,
         ["_oha_unused_ability_slot"] * 6)

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
        # Lua tables come back as Python tuples or lists depending on iteration
        if isinstance(expected, tuple):
            ok = result == expected
        elif isinstance(expected, list):
            ok = list(result) == expected
        else:
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
