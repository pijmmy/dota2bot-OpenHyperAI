"""Static verification harness for the human-ally kill yield in
bots/mode_attack_generic.lua.

Verifies:
  - When low-HP enemy is nearby AND human ally is closer + in 800u,
    bot's ATTACK desire drops to 0.1 (yields kill credit)
  - When all allies are bots, no yield
  - When enemy is at >= 35% HP, no yield (only nicks finishers)
  - When human ally is farther than bot, no yield (bot in better position)
  - Dive cap (0.1) preserved (no double-suppression issue)
  - When desire is nil (engine default), no yield (only suppress when
    the bot was actively going to attack)
"""

import sys
from lupa import LuaRuntime

LUA = r"""
local KILL_YIELD_HP_THRESHOLD = 0.35
local KILL_YIELD_RADIUS = 800

bot = nil
function setBot(distToEnemy, hp, hpMax)
    bot = {
        _distToEnemy = distToEnemy,
        _hp = hp,
        _hpMax = hpMax,
        IsBot = function(self) return true end,
        GetNearbyHeroes = function(self, r, isEnemy, mode)
            return _enemiesNearby
        end,
    }
end

_enemiesNearby = {}
_team = {}

function makeEnemy(x, y, hp, hpMax, isBot)
    return {
        _x = x, _y = y, _hp = hp, _hpMax = hpMax, _isBot = isBot,
        _isNull = false, _alive = true, _illusion = false,
        IsNull = function(self) return self._isNull end,
        IsAlive = function(self) return self._alive end,
        IsIllusion = function(self) return self._illusion end,
        IsBot = function(self) return self._isBot end,
        GetHealth = function(self) return self._hp end,
        GetMaxHealth = function(self) return self._hpMax end,
        GetLocation = function(self) return { x = self._x, y = self._y } end,
    }
end

function makeAlly(distToEnemy, isHuman)
    return {
        _distToEnemy = distToEnemy,
        _isBot = not isHuman,
        IsNull = function(self) return false end,
        IsAlive = function(self) return true end,
        IsIllusion = function(self) return false end,
        IsBot = function(self) return self._isBot end,
    }
end

function setEnemies(list) _enemiesNearby = list end
function setTeam(slots) _team = slots end
function GetTeamMember(i) return _team[i] end

function GetUnitToUnitDistance(b, e) return b._distToEnemy or 0 end
function GetUnitToLocationDistance(unit, loc) return unit._distToEnemy or 0 end

function humanKillYield(desireFromHold)
    if desireFromHold == nil or desireFromHold <= 0.15 then
        return desireFromHold
    end

    local enemies = bot:GetNearbyHeroes(KILL_YIELD_RADIUS, true, 0)
    if enemies == nil then return desireFromHold end

    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and not e:IsNull() and e:IsAlive()
            and not e:IsIllusion()
            and e:GetMaxHealth() > 0
            and (e:GetHealth() / e:GetMaxHealth()) < KILL_YIELD_HP_THRESHOLD
        then
            local enemyLoc = e:GetLocation()
            local botDist = GetUnitToUnitDistance(bot, e)

            for ai = 1, 5 do
                local ally = GetTeamMember(ai)
                if ally ~= nil and ally ~= bot
                    and not ally:IsNull() and ally:IsAlive()
                    and not ally:IsIllusion() and not ally:IsBot()
                then
                    local allyDist = GetUnitToLocationDistance(ally, enemyLoc)
                    if allyDist < botDist and allyDist < 800 then
                        return 0.1
                    end
                end
            end
        end
    end

    return desireFromHold
end
"""


def main():
    print("=" * 70)
    print("Human kill yield verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # 1) Low-HP enemy + human ally closer → yield (0.1)
    def c1():
        L.execute(
            "setBot(600, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 200, 1000, false)}); "
            "setTeam({makeAlly(400, true)})"
        )
        return L.eval("humanKillYield(0.7)")
    case("Low-HP enemy 600u + human ally 400u → yield 0.1", c1, 0.1)

    # 2) Low-HP enemy + only bot allies → no yield
    def c2():
        L.execute(
            "setBot(600, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 200, 1000, false)}); "
            "setTeam({makeAlly(400, false)})"
        )
        return L.eval("humanKillYield(0.7)")
    case("Low-HP enemy + only bot ally → no yield (0.7 preserved)", c2, 0.7)

    # 3) Mid-HP enemy (50%) + human ally close → no yield (HP gate)
    def c3():
        L.execute(
            "setBot(600, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 500, 1000, false)}); "
            "setTeam({makeAlly(400, true)})"
        )
        return L.eval("humanKillYield(0.7)")
    case("Mid-HP enemy 50% + human ally close → no yield (HP > 0.35)", c3, 0.7)

    # 4) Low-HP enemy + human ally FARTHER than bot → no yield (bot in pos)
    def c4():
        L.execute(
            "setBot(400, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 200, 1000, false)}); "
            "setTeam({makeAlly(600, true)})"
        )
        return L.eval("humanKillYield(0.7)")
    case("Low-HP enemy + human ally farther than bot → no yield", c4, 0.7)

    # 5) Low-HP enemy + human ally beyond 800u radius → no yield
    def c5():
        L.execute(
            "setBot(700, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 200, 1000, false)}); "
            "setTeam({makeAlly(900, true)})"
        )
        return L.eval("humanKillYield(0.7)")
    case("Low-HP enemy + human ally 900u from enemy → no yield", c5, 0.7)

    # 6) Dive cap 0.1 → preserved (early return, no override)
    def c6():
        L.execute(
            "setBot(600, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 200, 1000, false)}); "
            "setTeam({makeAlly(400, true)})"
        )
        return L.eval("humanKillYield(0.1)")
    case("Dive cap 0.1 → preserved (no override regardless of yield)", c6, 0.1)

    # 7) Desire nil → preserved (no override on engine-default cases)
    def c7():
        L.execute(
            "setBot(600, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 200, 1000, false)}); "
            "setTeam({makeAlly(400, true)})"
        )
        return L.eval("humanKillYield(nil)")
    case("Desire nil → preserved (no override on engine default)", c7, None)

    # 8) HP exactly at boundary (35%) → not yielded (< not <=)
    def c8():
        L.execute(
            "setBot(600, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 350, 1000, false)}); "
            "setTeam({makeAlly(400, true)})"
        )
        return L.eval("humanKillYield(0.7)")
    case("Enemy HP exactly 35% (boundary) → no yield", c8, 0.7)

    # 9) HP just under threshold (34.9%) → yielded
    def c9():
        L.execute(
            "setBot(600, 800, 1000); "
            "setEnemies({makeEnemy(0, 0, 349, 1000, false)}); "
            "setTeam({makeAlly(400, true)})"
        )
        return L.eval("humanKillYield(0.7)")
    case("Enemy HP 34.9% → yielded 0.1", c9, 0.1)

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
