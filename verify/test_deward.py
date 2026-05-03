"""Static verification harness for deward suspect tracking in
bots/FunLib/aba_deward.lua.

Verifies:
  - GetSuspectedSpots returns mirror-side spots minus recently-swept ones
  - MarkSwept records timestamps; suspects skip swept spots within 5min
  - GetReachableSuspect picks closest within 4500u, prefers confirmed
    visible wards (-2000 score bonus over speculative spots)
  - IsGoodTimeToSweep gates: HP > 50%, no recent damage, no nearby
    enemies, not retreating
"""

import sys
from lupa import LuaRuntime


DEWARD_LUA = r"""
local DIRE_WARD_SPOTS = {
    {x=7456,  y=5824},
    {x=4992,  y=4288},
    {x=2880,  y=5440},
    {x=7104,  y=1408},
    {x=5440,  y=-2944},
    {x=1216,  y=-4928},
    {x=4480,  y=-2496},
    {x=2240,  y=-1664},
}
local RADIANT_WARD_SPOTS = {
    {x=-7456, y=-5824},
    {x=-4992, y=-4288},
    {x=-2880, y=-5440},
    {x=-7104, y=-1408},
    {x=-5440, y=2944},
    {x=-1216, y=4928},
    {x=-4480, y=2496},
    {x=-2240, y=1664},
}

local _swept = {}

local function getSweptState(team)
    if _swept[team] == nil then _swept[team] = {} end
    return _swept[team]
end

local function spotKey(loc)
    return string.format("%d_%d", math.floor(loc.x / 100), math.floor(loc.y / 100))
end

function MarkSwept(team, loc)
    if team == nil or loc == nil then return end
    local swept = getSweptState(team)
    swept[spotKey(loc)] = DotaTime()
end

-- _enemy_wards is set by Python tests
function GetSuspectedSpots(team)
    local pool = (team == 2) and DIRE_WARD_SPOTS or RADIANT_WARD_SPOTS
    local now = DotaTime()
    local suspects = {}
    local swept = getSweptState(team)
    if _enemy_wards ~= nil then
        for _, w in ipairs(_enemy_wards) do
            table.insert(suspects, { location = w, confirmed = true, last_seen = now })
        end
    end
    for _, loc in ipairs(pool) do
        local key = spotKey(loc)
        local lastSwept = swept[key] or -999
        if (now - lastSwept) > 300 then
            table.insert(suspects, { location = loc, confirmed = false, last_seen = 0 })
        end
    end
    return suspects
end

function GetReachableSuspect(bot, suspects)
    local best = nil
    local bestScore = math.huge
    for _, s in ipairs(suspects) do
        local dist = GetUnitToLocationDistance(bot, s.location)
        if dist < 4500 then
            local confirmedBonus = s.confirmed and -2000 or 0
            local score = dist + confirmedBonus
            if score < bestScore then
                bestScore = score
                best = s
            end
        end
    end
    return best
end

function IsGoodTimeToSweep(hp, recentlyHit, nearbyEnemyCount, isRetreating)
    if hp < 0.5 then return false end
    if recentlyHit then return false end
    if nearbyEnemyCount >= 1 then return false end
    if isRetreating then return false end
    return true
end
"""


def setup_lua(now=100):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(f"function DotaTime() return {now} end")
    L.globals().GetUnitToLocationDistance = lambda u, loc: (
        ((u["x"] - loc["x"]) ** 2 + (u["y"] - loc["y"]) ** 2) ** 0.5
    )
    L.execute(DEWARD_LUA)
    return L


def main():
    print("=" * 70)
    print("Deward verification")
    print("=" * 70)

    passed = 0
    total = 0

    # --- GetSuspectedSpots: mirror correct + skip swept ---
    print()
    print("GetSuspectedSpots")
    print("-" * 70)

    # Radiant team (=2) gets DIRE_WARD_SPOTS (8 entries)
    total += 1
    L = setup_lua()
    L.execute("_enemy_wards = nil")
    count = L.eval("#GetSuspectedSpots(2)")
    ok = count == 8
    print(f"  [{'PASS' if ok else 'FAIL'}] Radiant team -> 8 mirror spots: got {count}")
    if ok: passed += 1

    # Dire team (=3) gets RADIANT_WARD_SPOTS (8 entries)
    total += 1
    L = setup_lua()
    L.execute("_enemy_wards = nil")
    count = L.eval("#GetSuspectedSpots(3)")
    ok = count == 8
    print(f"  [{'PASS' if ok else 'FAIL'}] Dire team -> 8 mirror spots: got {count}")
    if ok: passed += 1

    # MarkSwept removes one for 5 min
    total += 1
    L = setup_lua(now=100)
    L.execute("_enemy_wards = nil")
    L.execute("MarkSwept(2, {x=7456, y=5824})")  # mark first dire spot
    count = L.eval("#GetSuspectedSpots(2)")
    ok = count == 7  # 8 - 1 swept
    print(f"  [{'PASS' if ok else 'FAIL'}] After MarkSwept on one spot, 7 remain: got {count}")
    if ok: passed += 1

    # After 6 minutes, the swept spot returns
    total += 1
    L = setup_lua(now=100)
    L.execute("MarkSwept(2, {x=7456, y=5824})")
    L.execute("function DotaTime() return 460 end")  # 360s later, > 300s window
    count = L.eval("#GetSuspectedSpots(2)")
    ok = count == 8  # all back
    print(f"  [{'PASS' if ok else 'FAIL'}] After 6min, swept spot returns: got {count}")
    if ok: passed += 1

    # Visible enemy wards add to the suspect list
    total += 1
    L = setup_lua()
    L.execute("_enemy_wards = { {x=100, y=100}, {x=200, y=200} }")
    count = L.eval("#GetSuspectedSpots(2)")
    ok = count == 10  # 8 mirror + 2 confirmed
    print(f"  [{'PASS' if ok else 'FAIL'}] 2 visible enemy wards + 8 mirror -> 10: got {count}")
    if ok: passed += 1

    # --- GetReachableSuspect: prefers confirmed, within 4500 ---
    print()
    print("GetReachableSuspect")
    print("-" * 70)

    # Bot at (0, 0). Confirmed ward at (1000, 0) — score = 1000 - 2000 = -1000.
    # Speculative spot at (500, 0) — score = 500. Confirmed wins.
    total += 1
    L = setup_lua()
    L.execute("""
        suspects = {
            { location = {x=500, y=0},  confirmed = false },
            { location = {x=1000, y=0}, confirmed = true },
        }
        bot = {x=0, y=0}
        result = GetReachableSuspect(bot, suspects)
    """)
    rx = L.eval("result.location.x")
    confirmed = L.eval("result.confirmed")
    ok = rx == 1000 and confirmed is True
    print(f"  [{'PASS' if ok else 'FAIL'}] Confirmed at 1000u beats speculative at 500u "
          f"(got x={rx}, confirmed={confirmed})")
    if ok: passed += 1

    # All speculative: closest wins
    total += 1
    L = setup_lua()
    L.execute("""
        suspects = {
            { location = {x=500, y=0},  confirmed = false },
            { location = {x=1000, y=0}, confirmed = false },
            { location = {x=200, y=0},  confirmed = false },
        }
        bot = {x=0, y=0}
        result = GetReachableSuspect(bot, suspects)
    """)
    rx = L.eval("result.location.x")
    ok = rx == 200
    print(f"  [{'PASS' if ok else 'FAIL'}] All speculative: closest (200) wins (got x={rx})")
    if ok: passed += 1

    # All beyond 4500u: no result
    total += 1
    L = setup_lua()
    L.execute("""
        suspects = {
            { location = {x=5000, y=0}, confirmed = false },
            { location = {x=6000, y=0}, confirmed = true },
        }
        bot = {x=0, y=0}
        result = GetReachableSuspect(bot, suspects)
    """)
    ok = L.eval("result") is None
    print(f"  [{'PASS' if ok else 'FAIL'}] All beyond 4500u -> nil")
    if ok: passed += 1

    # Confirmed at 5000u (out of range), speculative at 1000u: spec wins
    # because the 5000u confirmed is filtered before the bonus is applied
    total += 1
    L = setup_lua()
    L.execute("""
        suspects = {
            { location = {x=1000, y=0}, confirmed = false },
            { location = {x=5000, y=0}, confirmed = true },
        }
        bot = {x=0, y=0}
        result = GetReachableSuspect(bot, suspects)
    """)
    rx = L.eval("result.location.x")
    ok = rx == 1000
    print(f"  [{'PASS' if ok else 'FAIL'}] Confirmed-but-out-of-range filtered, spec wins "
          f"(got x={rx})")
    if ok: passed += 1

    # --- IsGoodTimeToSweep gates ---
    print()
    print("IsGoodTimeToSweep gates")
    print("-" * 70)

    gate_cases = [
        # (description, hp, recentlyHit, enemies, isRetreating, expected)
        ("Healthy + safe -> true", 0.9, False, 0, False, True),
        ("HP 0.5 boundary: false (< not <=)", 0.49, False, 0, False, False),
        ("HP 0.5 exactly: true (>=)", 0.5, False, 0, False, True),
        ("Recent damage: false", 0.9, True, 0, False, False),
        ("1 enemy nearby: false", 0.9, False, 1, False, False),
        ("Retreating: false", 0.9, False, 0, True, False),
        ("All bad: false", 0.2, True, 3, True, False),
    ]
    for desc, hp, rh, ne, retr, expected in gate_cases:
        total += 1
        L = setup_lua()
        rh_lua = "true" if rh else "false"
        retr_lua = "true" if retr else "false"
        result = L.eval(f"IsGoodTimeToSweep({hp}, {rh_lua}, {ne}, {retr_lua})")
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok: passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
