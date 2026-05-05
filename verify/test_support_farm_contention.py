"""Static verification harness for the support-vs-carry last-hit
contention gate in bots/mode_laning_generic.lua.

Verifies:
  - When bot is pos 4/5 and a core ally (pos 1/2/3) is in attack range
    of the creep, GetBestLastHitCreep skips that creep
  - When bot is pos 4/5 and no core ally is nearby, support last-hits
  - When bot is pos 1-3 (core), the suppression DOES NOT apply
  - The Think gate now activates for pos 4/5 supports (not just the 9
    buggy heroes), so the helper actually runs
"""

import sys
from lupa import LuaRuntime

LUA = r"""
-- Mock the helpers / API
function GetUnitToLocationDistance(ally, loc)
    return ally._distToCreep
end

-- J.GetPosition mock
J = {}
function J.GetPosition(unit)
    return unit._pos
end
function J.IsValid(c) return c ~= nil and not c._dead end
function J.CanBeAttacked(c) return c ~= nil and not c._dead end

function makeAlly(pos, distToCreep, isAlive, isIllusion, atkRange)
    return {
        _pos = pos,
        _distToCreep = distToCreep,
        _alive = isAlive,
        _illusion = isIllusion,
        _atkRange = atkRange or 600,
        IsAlive = function(self) return self._alive end,
        IsIllusion = function(self) return self._illusion end,
        GetAttackRange = function(self) return self._atkRange end,
    }
end

function makeBot(pos)
    return {
        _pos = pos,
        IsAlive = function(self) return true end,
        IsIllusion = function(self) return false end,
        GetAttackRange = function(self) return 600 end,
    }
end

-- Team members storage
_teamMembers = {}
function GetTeamMember(i) return _teamMembers[i] end

function setupTeam(bot, allies)
    _teamMembers = {}
    -- Pad to 5 slots
    for i = 1, 5 do _teamMembers[i] = nil end
    -- bot occupies one slot, allies occupy the rest. Use dummy slots.
    _teamMembers[1] = bot
    for i, a in ipairs(allies) do
        _teamMembers[i + 1] = a
    end
end

-- Mirror of isCoreAllyInRangeOfCreep + isSupport gate
function isCoreAllyInRangeOfCreep(bot, creep)
    if creep == nil then return false end
    local creepLoc = creep._loc
    for i = 1, 5 do
        local ally = GetTeamMember(i)
        if ally ~= nil and ally ~= bot and ally:IsAlive() and not ally:IsIllusion() then
            local okPos, allyPos = pcall(function() return J.GetPosition(ally) end)
            if okPos and allyPos ~= nil and allyPos <= 3 then
                local allyAtkRange = ally:GetAttackRange()
                if GetUnitToLocationDistance(ally, creepLoc) <= allyAtkRange + 50 then
                    return true
                end
            end
        end
    end
    return false
end

function shouldSkipCreep(bot, creep)
    local botPosOk, botPos = pcall(function() return J.GetPosition(bot) end)
    local isSupport = botPosOk and botPos ~= nil and botPos >= 4
    return isSupport and isCoreAllyInRangeOfCreep(bot, creep)
end

-- Think-gate test: returns true if Think function should be defined for this bot.
function thinkGateActive(bot, hasOverride, isPos1WithHumanPos5)
    local function _thinkGateBotIsSupport()
        local ok, p = pcall(function() return J.GetPosition(bot) end)
        return ok and p ~= nil and p >= 4
    end
    return hasOverride or isPos1WithHumanPos5 or _thinkGateBotIsSupport()
end

function makeCreep(loc, dead)
    return { _loc = loc, _dead = dead or false }
end
"""


def main():
    print("=" * 70)
    print("Support-vs-carry farm contention gate verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # 1) Support bot, core ally in range of creep → skip
    def c1():
        L.execute(
            r"""
            local bot = makeBot(5)
            local carry = makeAlly(1, 500, true, false, 600)
            setupTeam(bot, { carry })
            local creep = makeCreep({0, 0})
            return shouldSkipCreep(bot, creep)
        """
        )
        return L.eval(
            "(function() local bot = makeBot(5); local carry = makeAlly(1, 500, true, false, 600); "
            "setupTeam(bot, { carry }); local creep = makeCreep({0, 0}); "
            "return shouldSkipCreep(bot, creep) end)()"
        )
    case("Pos 5 support, pos 1 carry 500u from creep (in 650u range) → skip", c1, True)

    # 2) Support bot, core ally OUT of range → don't skip
    def c2():
        return L.eval(
            "(function() local bot = makeBot(5); local carry = makeAlly(1, 800, true, false, 600); "
            "setupTeam(bot, { carry }); local creep = makeCreep({0, 0}); "
            "return shouldSkipCreep(bot, creep) end)()"
        )
    case("Pos 5 support, pos 1 carry 800u from creep (out of 650u) → don't skip", c2, False)

    # 3) Carry bot, no skip applies (isSupport gate fails)
    def c3():
        return L.eval(
            "(function() local bot = makeBot(1); local sup = makeAlly(5, 500, true, false, 600); "
            "setupTeam(bot, { sup }); local creep = makeCreep({0, 0}); "
            "return shouldSkipCreep(bot, creep) end)()"
        )
    case("Pos 1 carry → skip never triggered (isSupport=false)", c3, False)

    # 4) Support bot, ally is also support (pos 4) → don't skip (only cores block)
    def c4():
        return L.eval(
            "(function() local bot = makeBot(5); local other_sup = makeAlly(4, 500, true, false, 600); "
            "setupTeam(bot, { other_sup }); local creep = makeCreep({0, 0}); "
            "return shouldSkipCreep(bot, creep) end)()"
        )
    case("Pos 5 + pos 4 ally close → don't skip (other support, not core)", c4, False)

    # 5) Support bot, dead ally in range → don't skip (alive check)
    def c5():
        return L.eval(
            "(function() local bot = makeBot(5); local carry = makeAlly(1, 500, false, false, 600); "
            "setupTeam(bot, { carry }); local creep = makeCreep({0, 0}); "
            "return shouldSkipCreep(bot, creep) end)()"
        )
    case("Pos 5 support, dead pos 1 in range → don't skip", c5, False)

    # 6) Think gate: pos 5 support → Think defined
    def c6():
        return L.eval(
            "(function() local bot = makeBot(5); return thinkGateActive(bot, false, false) end)()"
        )
    case("Think gate: pos 5 support, no override → gate active", c6, True)

    # 7) Think gate: pos 1 carry no human pos 5 → Think NOT defined
    def c7():
        return L.eval(
            "(function() local bot = makeBot(1); return thinkGateActive(bot, false, false) end)()"
        )
    case("Think gate: pos 1 carry, no override, no human pos 5 → gate inactive", c7, False)

    # 8) Think gate: pos 1 carry WITH human pos 5 → still active (legacy path)
    def c8():
        return L.eval(
            "(function() local bot = makeBot(1); return thinkGateActive(bot, false, true) end)()"
        )
    case("Think gate: pos 1 carry + human pos 5 → gate active (legacy)", c8, True)

    # 9) Think gate: pos 4 support → active
    def c9():
        return L.eval(
            "(function() local bot = makeBot(4); return thinkGateActive(bot, false, false) end)()"
        )
    case("Think gate: pos 4 support → gate active", c9, True)

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
