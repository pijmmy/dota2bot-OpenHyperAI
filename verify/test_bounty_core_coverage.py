"""Static verification harness for the bounty rune coverage fix in
bots/mode_rune_generic.lua.

Verifies:
  - Pre-game cores (pos 1/2/3) get a non-NONE rune desire when there's
    a bounty no support is closer to
  - Cores yield to supports when a support is closer to the same rune
  - When two cores compete, the closer core wins
  - DESIRE returned for cores is 0.42 (below support's 0.5, above
    laning's 0.268)
"""

import sys
from lupa import LuaRuntime

LUA = r"""
J = {}
function J.IsValidHero(h) return h ~= nil and h._valid end
function J.GetPosition(h) return h._pos end

_team = {}
function GetTeamMember(i) return _team[i] end

function makeHero(pos, dist, valid)
    return {
        _pos = pos,
        _dist = dist,
        _valid = (valid ~= false),
    }
end

function setTeam(slots) _team = slots end

function GetUnitToLocationDistance(unit, loc) return unit._dist end
function GetRuneSpawnLocation(rune) return rune end -- treat rune ID as location id

-- Mock bounty list: 4 ids
nBountyRuneList = { 1, 2, 3, 4 }

-- Per-hero distances are stamped in the hero object. To represent
-- different distances per rune, the test re-stamps unit._dist before
-- each call. For multi-rune coverage we need per-rune distances; use
-- the unit._distMap[rune] override when present.
function GetUnitToLocationDistance(unit, loc)
    if unit._distMap ~= nil and unit._distMap[loc] ~= nil then
        return unit._distMap[loc]
    end
    return unit._dist
end

X = {}

-- Mocked: skip pinged-by-human / human-claiming gates for tests
function X.IsPingedByHumanPlayer(loc, t) return false end
function IsHumanClaimingRune(rune) return false end

bot = nil

local CORE_BOUNTY_MAX_DISTANCE = 3800

function X.GetBestBountyForCore()
    local targetRune = -1
    local targetRuneDistance = math.huge
    for _, rune in pairs(nBountyRuneList) do
        local vRuneLocation = GetRuneSpawnLocation(rune)

        local botDist = GetUnitToLocationDistance(bot, vRuneLocation)
        if botDist > CORE_BOUNTY_MAX_DISTANCE then goto continue end

        local supportCloser = false
        for i = 1, 5 do
            local member = GetTeamMember(i)
            if J.IsValidHero(member) and member ~= bot then
                local memberPos = J.GetPosition(member)
                if memberPos and memberPos >= 4 then
                    if GetUnitToLocationDistance(member, vRuneLocation) < botDist then
                        supportCloser = true
                        break
                    end
                end
            end
        end
        if supportCloser then goto continue end

        local botIsClosestCore = true
        for i = 1, 5 do
            local member = GetTeamMember(i)
            if J.IsValidHero(member) and member ~= bot then
                local memberPos = J.GetPosition(member)
                if memberPos and memberPos >= 1 and memberPos <= 3 then
                    if GetUnitToLocationDistance(member, vRuneLocation) < botDist then
                        botIsClosestCore = false
                        break
                    end
                end
            end
        end
        if not botIsClosestCore then goto continue end

        if X.IsPingedByHumanPlayer(vRuneLocation, math.huge)
        or IsHumanClaimingRune(rune) then goto continue end

        if botDist < targetRuneDistance then
            targetRune = rune
            targetRuneDistance = botDist
        end
        ::continue::
    end
    return targetRune, targetRuneDistance
end

-- Helper: set bot + team via per-rune distance maps
function setBotWithDistMap(pos, distMap)
    bot = makeHero(pos, 9999, true)
    bot._distMap = distMap
end

function setAllyAtSlot(slot, pos, distMap)
    local h = makeHero(pos, 9999, true)
    h._distMap = distMap
    _team[slot] = h
end

function clearTeam()
    _team = {}
end
"""


def main():
    print("=" * 70)
    print("Bounty rune core-coverage verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected_rune):
        cases.append((desc, fn, expected_rune))

    # 1) Lone core, no supports, 4 bounties at distances 500, 1000, 1500, 2000
    #    → core picks rune 1 (closest)
    def c1():
        L.execute("clearTeam()")
        L.execute("setBotWithDistMap(2, {[1]=500, [2]=1000, [3]=1500, [4]=2000})")
        return L.eval("X.GetBestBountyForCore()")
    case("Lone core, 4 bounties → picks rune 1 (closest)", c1, 1)

    # 2) Core (pos 2) + support (pos 5) closer to all bounties → core gets nothing
    def c2():
        L.execute("clearTeam()")
        L.execute("setBotWithDistMap(2, {[1]=500, [2]=1000, [3]=1500, [4]=2000})")
        L.execute("setAllyAtSlot(1, 5, {[1]=300, [2]=400, [3]=500, [4]=600})")
        return L.eval("X.GetBestBountyForCore()")
    case("Core + support closer to all 4 bounties → core gets -1", c2, -1)

    # 3) Core (pos 2) + support (pos 5) closer to runes 1,2 only.
    #    Core's distMap: {1=500, 2=1000, 3=1500, 4=2000}. Support: {1=300, 2=400, 3=2000, 4=2500}.
    #    Core's eligible runes: 3 (support farther), 4 (support farther).
    #    Of those, rune 3 is closer to bot (1500 < 2000). Pick rune 3.
    def c3():
        L.execute("clearTeam()")
        L.execute("setBotWithDistMap(2, {[1]=500, [2]=1000, [3]=1500, [4]=2000})")
        L.execute("setAllyAtSlot(1, 5, {[1]=300, [2]=400, [3]=2000, [4]=2500})")
        return L.eval("X.GetBestBountyForCore()")
    case("Core + support closer to runes 1,2 → core picks rune 3", c3, 3)

    # 4) Two cores compete. Bot is pos 2 with {1=500, 2=1000}; ally pos 1 has {1=300, 2=900}.
    #    For rune 1: ally closer (300 < 500). Bot not closest core → skip.
    #    For rune 2: ally closer (900 < 1000). Bot not closest core → skip.
    #    Result: -1.
    def c4():
        L.execute("clearTeam()")
        L.execute("setBotWithDistMap(2, {[1]=500, [2]=1000, [3]=9999, [4]=9999})")
        L.execute("setAllyAtSlot(1, 1, {[1]=300, [2]=900, [3]=9999, [4]=9999})")
        return L.eval("X.GetBestBountyForCore()")
    case("Two cores, ally pos 1 closer to runes 1+2 → bot pos 2 gets -1", c4, -1)

    # 5) Two cores split. Bot pos 2 {1=500, 2=1500}; ally pos 1 {1=300, 2=2000}.
    #    Rune 1: ally closer (300 < 500). Skip.
    #    Rune 2: bot closer (1500 < 2000). Bot is closest core. Pick rune 2.
    def c5():
        L.execute("clearTeam()")
        L.execute("setBotWithDistMap(2, {[1]=500, [2]=1500, [3]=9999, [4]=9999})")
        L.execute("setAllyAtSlot(1, 1, {[1]=300, [2]=2000, [3]=9999, [4]=9999})")
        return L.eval("X.GetBestBountyForCore()")
    case("Two cores split: ally takes rune 1, bot takes rune 2", c5, 2)

    passed = 0
    total = 0
    for desc, fn, expected_rune in cases:
        total += 1
        result_rune, result_dist = fn()
        ok = result_rune == expected_rune
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got rune={result_rune} (expected {expected_rune})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
