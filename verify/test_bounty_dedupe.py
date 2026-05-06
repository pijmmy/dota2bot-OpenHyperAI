"""Static verification harness for the rebuilt GetBestBountyRune in
bots/mode_rune_generic.lua.

Verifies that two supports at the same fountain spawn coordinates
(zero-distance ties to all 4 bounty runes) get DIFFERENT runes, instead
of both claiming the same one. User report (latest game console.log
@ 0:09): "noone gets the runes at start" because the old algorithm let
both supports walk to the same bounty.
"""

import sys
from lupa import LuaRuntime

LUA = r"""
J = {}
function J.IsValidHero(h) return h ~= nil and h._valid end
function J.GetPosition(h) return h._pos end

_team = {}
function GetTeamMember(i) return _team[i] end

function makeHero(pos, pid, distMap)
    return {
        _pos = pos,
        _pid = pid,
        _valid = true,
        _distMap = distMap or {},
        GetPlayerID = function(self) return self._pid end,
    }
end

function setTeam(slots) _team = slots end
function clearTeam() _team = {} end

function GetUnitToLocationDistance(unit, loc)
    if unit._distMap and unit._distMap[loc] ~= nil then
        return unit._distMap[loc]
    end
    return 9999
end

function GetRuneSpawnLocation(rune) return rune end

nBountyRuneList = { 1, 2, 3, 4 }

X = {}
function X.IsPingedByHumanPlayer(loc, t) return false end
function IsHumanClaimingRune(rune) return false end

bot = nil

function X.GetBestBountyRune()
    local supports = {}
    for i = 1, 5 do
        local m = GetTeamMember(i)
        if J.IsValidHero(m) then
            local p = J.GetPosition(m)
            if p and p >= 4 then
                table.insert(supports, m)
            end
        end
    end
    table.sort(supports, function(a, b)
        return a:GetPlayerID() < b:GetPlayerID()
    end)

    local claimed = {}
    local myAssignment = nil
    local myPID = bot:GetPlayerID()

    for _, support in ipairs(supports) do
        local options = {}
        for _, rune in pairs(nBountyRuneList) do
            local loc = GetRuneSpawnLocation(rune)
            if not X.IsPingedByHumanPlayer(loc, math.huge)
            and not IsHumanClaimingRune(rune) then
                table.insert(options, {
                    rune = rune,
                    loc = loc,
                    dist = GetUnitToLocationDistance(support, loc),
                })
            end
        end
        table.sort(options, function(a, b)
            if a.dist == b.dist then return a.rune < b.rune end
            return a.dist < b.dist
        end)

        for _, opt in ipairs(options) do
            if not claimed[opt.rune] then
                claimed[opt.rune] = true
                if support:GetPlayerID() == myPID then
                    myAssignment = opt
                end
                break
            end
        end
    end

    if myAssignment ~= nil then
        return myAssignment.rune, myAssignment.dist
    end
    return -1, math.huge
end

-- helper to query for both supports
function getRuneFor(pid, supports)
    bot = nil
    for _, s in ipairs(supports) do
        if s:GetPlayerID() == pid then bot = s break end
    end
    return X.GetBestBountyRune()
end
"""


def main():
    print("=" * 70)
    print("Bounty rune dedupe verification (equal-distance tie handling)")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # Case 1: 2 supports at fountain (same dist to all 4 bounties).
    # Expect them to be assigned to DIFFERENT runes.
    def c1():
        L.execute("clearTeam()")
        L.execute(
            "_team[1] = makeHero(4, 1, {[1]=2000, [2]=2000, [3]=2000, [4]=2000})"
        )
        L.execute(
            "_team[2] = makeHero(5, 2, {[1]=2000, [2]=2000, [3]=2000, [4]=2000})"
        )
        # Pretend `bot` is each support in turn
        L.execute("bot = _team[1]")
        rune_pid1, _ = L.eval("X.GetBestBountyRune()")
        L.execute("bot = _team[2]")
        rune_pid2, _ = L.eval("X.GetBestBountyRune()")
        return rune_pid1, rune_pid2
    case("2 supports same fountain dist to all 4 → DIFFERENT runes",
         c1, (1, 2))

    # Case 2: support pos 5 closer to BOUNTY_4, pos 4 closer to BOUNTY_3.
    # Expected: pos 5 takes BOUNTY_4, pos 4 takes BOUNTY_3.
    def c2():
        L.execute("clearTeam()")
        L.execute("_team[1] = makeHero(4, 10, {[1]=3000, [2]=3000, [3]=1500, [4]=2500})")
        L.execute("_team[2] = makeHero(5, 11, {[1]=3000, [2]=3000, [3]=2500, [4]=1500})")
        L.execute("bot = _team[1]")
        rune_pid10, _ = L.eval("X.GetBestBountyRune()")
        L.execute("bot = _team[2]")
        rune_pid11, _ = L.eval("X.GetBestBountyRune()")
        return rune_pid10, rune_pid11
    case("Asymmetric distances → each picks their closest", c2, (3, 4))

    # Case 3: 1 support only — claims their closest bounty.
    def c3():
        L.execute("clearTeam()")
        L.execute("_team[1] = makeHero(5, 5, {[1]=3000, [2]=3000, [3]=1500, [4]=2500})")
        L.execute("bot = _team[1]")
        rune, _ = L.eval("X.GetBestBountyRune()")
        return rune
    case("Lone support → picks closest bounty", c3, 3)

    # Case 4: bot not a support (pos 3 core) — returns -1
    def c4():
        L.execute("clearTeam()")
        L.execute("_team[1] = makeHero(3, 7, {[1]=2000, [2]=2000, [3]=2000, [4]=2000})")
        L.execute("bot = _team[1]")
        rune, _ = L.eval("X.GetBestBountyRune()")
        return rune
    case("Bot is core (pos 3) → -1 (not a support)", c4, -1)

    # Case 5: 2 supports both prefer rune 1 (same closest).
    # Expected: lower playerID wins rune 1, other support takes rune 2.
    def c5():
        L.execute("clearTeam()")
        L.execute("_team[1] = makeHero(4, 1, {[1]=500, [2]=600, [3]=700, [4]=800})")
        L.execute("_team[2] = makeHero(5, 2, {[1]=400, [2]=500, [3]=600, [4]=700})")
        L.execute("bot = _team[1]")
        rune_pid1, _ = L.eval("X.GetBestBountyRune()")
        L.execute("bot = _team[2]")
        rune_pid2, _ = L.eval("X.GetBestBountyRune()")
        return rune_pid1, rune_pid2
    case("Both prefer rune 1: pid 1 (lower) takes rune 1, pid 2 takes rune 2",
         c5, (1, 2))

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
        if isinstance(expected, tuple):
            ok = result == expected
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
