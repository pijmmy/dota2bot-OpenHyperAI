"""Static verification harness for the anti-dive safezone utility in
bots/FunLib/aba_safezone.lua.

Verifies:
  IsLocSafeFromEnemyTowers — boolean predicate on (loc, margin)
  WouldDiveIfMovedTo       — bot-state-aware predicate
  EstimateTowerDPS         — damage estimate
"""

import sys
from lupa import LuaRuntime


SAFEZONE_LUA = r"""
local TOWER_ATTACK_RANGE = 700
local DEFAULT_DANGER_RADIUS = 750

-- Test fixtures: an array of "towers" with .loc + .alive + .damage
_towers = {}

local function getTowers()
    local out = {}
    for _, t in ipairs(_towers) do
        if t.alive then table.insert(out, t) end
    end
    return out
end

function setTowers(towers)
    _towers = towers
end

function IsLocSafeFromEnemyTowers(loc, margin)
    margin = margin or 0
    local danger = DEFAULT_DANGER_RADIUS + margin
    for _, t in ipairs(getTowers()) do
        local dx = t.loc.x - loc.x
        local dy = t.loc.y - loc.y
        if dx * dx + dy * dy < danger * danger then
            return false
        end
    end
    return true
end

function WouldDiveIfMovedTo(bot, loc, margin)
    margin = margin or 0
    local danger = DEFAULT_DANGER_RADIUS + margin
    local nearestSq = math.huge
    for _, t in ipairs(getTowers()) do
        local dx = t.loc.x - loc.x
        local dy = t.loc.y - loc.y
        local distSq = dx * dx + dy * dy
        if distSq < nearestSq then nearestSq = distSq end
    end
    if nearestSq >= danger * danger then return false end
    if bot.immortal then return false end
    if bot.hp_buffer >= 700 then return false end
    return true
end

function EstimateTowerDPS(bot, loc, withinSec)
    local danger = DEFAULT_DANGER_RADIUS
    local total = 0
    for _, t in ipairs(getTowers()) do
        local dx = t.loc.x - loc.x
        local dy = t.loc.y - loc.y
        if dx * dx + dy * dy < danger * danger then
            total = total + t.damage * withinSec
        end
    end
    return total
end

function makeTower(x, y, alive, damage)
    return { loc = { x = x, y = y }, alive = alive, damage = damage or 100 }
end

function makeBot(immortal, hp_buffer)
    return { immortal = immortal, hp_buffer = hp_buffer }
end
"""


def main():
    print("=" * 70)
    print("Safezone utility verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(SAFEZONE_LUA)

    passed = 0
    total = 0

    # --- IsLocSafeFromEnemyTowers ---
    print()
    print("IsLocSafeFromEnemyTowers")
    print("-" * 70)

    cases = [
        # (description, towers, loc, margin, expected)
        ("No towers: safe everywhere",
         [], (1000, 1000), 0, True),
        ("Tower 800u away (>750): safe",
         [(1500, 0, True)], (700, 0), 0, True),
        ("Tower 700u away (<750 danger): NOT safe",
         [(1400, 0, True)], (700, 0), 0, False),
        ("Tower 749u away: NOT safe (boundary, < not <=)",
         [(1449, 0, True)], (700, 0), 0, False),
        ("Tower 750u away: safe (boundary)",
         [(1450, 0, True)], (700, 0), 0, True),
        ("Tower dead: safe regardless of distance",
         [(710, 0, False)], (700, 0), 0, True),
        ("Multiple towers, one in range: NOT safe",
         [(2000, 0, True), (1100, 0, True)], (700, 0), 0, False),
        ("Margin 200u widens danger zone",
         [(1500, 0, True)], (700, 0), 200, False),
    ]
    for desc, towers, loc, margin, expected in cases:
        total += 1
        towers_lua = "{" + ", ".join(
            f"makeTower({x}, {y}, {'true' if a else 'false'}, 100)"
            for x, y, a in towers) + "}"
        L.execute(f"setTowers({towers_lua})")
        result = L.eval(f"IsLocSafeFromEnemyTowers({{x={loc[0]}, y={loc[1]}}}, {margin})")
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    # --- WouldDiveIfMovedTo ---
    print()
    print("WouldDiveIfMovedTo (state-aware)")
    print("-" * 70)

    dive_cases = [
        # (description, towers, bot_immortal, bot_hp_buffer, loc, expected)
        ("No towers near loc: not diving",
         [(2500, 0, True)], False, 1000, (700, 0), False),
        ("In tower range, no immortal frame, low HP buffer 200: DIVE",
         [(1100, 0, True)], False, 200, (700, 0), True),
        ("In tower range, immortal frame: NOT diving (frame absorbs)",
         [(1100, 0, True)], True, 200, (700, 0), False),
        ("In tower range, no immortal frame, HP buffer 700: NOT diving (tanky enough)",
         [(1100, 0, True)], False, 700, (700, 0), False),
        ("In tower range, no immortal frame, HP buffer 699: DIVE (boundary)",
         [(1100, 0, True)], False, 699, (700, 0), True),
        ("In tower range, immortal AND HP 0: NOT diving (immortal wins)",
         [(1100, 0, True)], True, 0, (700, 0), False),
    ]
    for desc, towers, immortal, hp, loc, expected in dive_cases:
        total += 1
        towers_lua = "{" + ", ".join(
            f"makeTower({x}, {y}, {'true' if a else 'false'}, 100)"
            for x, y, a in towers) + "}"
        L.execute(f"setTowers({towers_lua})")
        L.execute(f"_bot = makeBot({'true' if immortal else 'false'}, {hp})")
        result = L.eval(f"WouldDiveIfMovedTo(_bot, {{x={loc[0]}, y={loc[1]}}}, 0)")
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    # --- EstimateTowerDPS ---
    print()
    print("EstimateTowerDPS")
    print("-" * 70)

    dps_cases = [
        # (description, towers, loc, sec, expected)
        ("No towers: 0",
         [], (0, 0), 3.0, 0),
        ("One tower in range, dmg 100, 3s: 300",
         [(700, 0, True, 100)], (0, 0), 3.0, 300),
        ("One tower out of range: 0",
         [(2000, 0, True, 100)], (0, 0), 3.0, 0),
        ("Two towers in range, dmg 100 each, 3s: 600",
         [(700, 0, True, 100), (-700, 0, True, 100)], (0, 0), 3.0, 600),
        ("Tower in range, 1s: 100",
         [(700, 0, True, 100)], (0, 0), 1.0, 100),
    ]
    for desc, towers, loc, sec, expected in dps_cases:
        total += 1
        if towers and len(towers[0]) == 4:
            towers_lua = "{" + ", ".join(
                f"makeTower({x}, {y}, {'true' if a else 'false'}, {d})"
                for x, y, a, d in towers) + "}"
        else:
            towers_lua = "{" + ", ".join(
                f"makeTower({x}, {y}, {'true' if a else 'false'}, 100)"
                for x, y, a in towers) + "}"
        L.execute(f"setTowers({towers_lua})")
        L.execute("_bot = makeBot(false, 1000)")
        result = L.eval(f"EstimateTowerDPS(_bot, {{x={loc[0]}, y={loc[1]}}}, {sec})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
