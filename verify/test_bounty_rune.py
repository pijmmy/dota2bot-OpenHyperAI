"""Static verification harness for the bounty-rune pickup fix in
mode_rune_generic.lua.

Verifies:
  - GetBestBountyRune iterates ALL 4 bounty runes (not just 1+2)
  - Returns the closest unclaimed bounty
  - Distribution: pos 4 and pos 5 don't both pick the same bounty
"""

import sys
import lupa
from lupa import LuaRuntime


# ---------------------------------------------------------------------------
# Inline the GetBestBountyRune logic exactly as written in the fix.
# ---------------------------------------------------------------------------

GET_BEST_BOUNTY_LUA = r"""
local nBountyRuneList = {
    RUNE_BOUNTY_1,
    RUNE_BOUNTY_2,
    RUNE_BOUNTY_3,
    RUNE_BOUNTY_4,
}

-- Mock for J.IsValidHero + J.GetPosition
local J = {
    IsValidHero = function(u) return u ~= nil end,
    GetPosition = function(u) return u ~= nil and u.pos or 2 end,
}

-- This mirrors the production X.IsTheClosestSupport in
-- bots/mode_rune_generic.lua. Only pos 4/5 are competitors.
function IsTheClosestSupport(hUnit, vLocation)
    local targetAlly = hUnit
    local targetAllyDistance = GetUnitToLocationDistance(hUnit, vLocation)
    for i = 1, 5 do
        local member = GetTeamMember(i)
        if J.IsValidHero(member) and member ~= hUnit then
            local memberPos = J.GetPosition(member)
            if memberPos and memberPos >= 4 then
                local memberDistance = GetUnitToLocationDistance(member, vLocation)
                if memberDistance < targetAllyDistance then
                    targetAlly = member
                    targetAllyDistance = memberDistance
                end
            end
        end
    end
    return targetAlly == hUnit
end

function GetBestBountyRune(bot)
    local targetRune = -1
    local targetRuneDistance = math.huge
    for _, rune in pairs(nBountyRuneList) do
        local vRuneLocation = GetRuneSpawnLocation(rune)

        if IsTheClosestSupport(bot, vRuneLocation)
        and not IsHumanClaimingRune(rune)
        then
            local dist = GetUnitToLocationDistance(bot, vRuneLocation)
            if dist < targetRuneDistance then
                targetRune = rune
                targetRuneDistance = dist
            end
        end
    end
    return targetRune, targetRuneDistance
end
"""


def setup_lua(scenario):
    L = LuaRuntime(unpack_returned_tuples=True)

    # Engine constants for bounty runes
    L.execute("RUNE_BOUNTY_1, RUNE_BOUNTY_2, RUNE_BOUNTY_3, RUNE_BOUNTY_4 = 2, 3, 4, 5")

    # Build bot table (team members)
    bots = scenario["bots"]  # {pos: {"loc": (x,y)}}

    def get_team_member(i):
        if i in bots:
            return bots[i]
        return None

    L.globals().GetTeamMember = get_team_member

    # Rune spawn locations
    rune_locs = scenario["rune_locs"]  # {RUNE_BOUNTY_N: (x, y)}

    def get_rune_spawn_location(rune):
        loc = rune_locs.get(rune, (0, 0))
        return L.table_from({"x": loc[0], "y": loc[1]})

    L.globals().GetRuneSpawnLocation = get_rune_spawn_location

    # Distance computation
    def get_unit_to_location_distance(unit, loc):
        ux, uy = unit["loc"][0], unit["loc"][1]
        # loc is a Lua table with x, y
        try:
            lx, ly = loc["x"], loc["y"]
        except Exception:
            lx, ly = loc[0], loc[1]
        return ((ux - lx) ** 2 + (uy - ly) ** 2) ** 0.5

    L.globals().GetUnitToLocationDistance = get_unit_to_location_distance

    # No human ping
    L.globals().IsHumanClaimingRune = lambda _: False

    return L


def run_test(name, scenario, bot_pos, expect_rune):
    L = setup_lua(scenario)
    L.execute(GET_BEST_BOUNTY_LUA)
    bot = scenario["bots"][bot_pos]
    L.globals().mybot = bot
    rune, dist = L.eval("GetBestBountyRune(mybot)")
    passed = rune == expect_rune
    status = "PASS" if passed else "FAIL"
    print(f"  [{status}] {name}: pos {bot_pos} got rune {rune} dist {dist:.0f} (expected rune {expect_rune})")
    return passed


def main():
    print("=" * 70)
    print("Bounty rune verification (GetBestBountyRune)")
    print("=" * 70)

    # Standard 7.41 bounty rune layout (approximate locations from Dota wiki).
    # RUNE_BOUNTY constants: 1=2, 2=3, 3=4, 4=5 (per Lua).
    rune_locs_standard = {
        2: (-3000, -1500),  # BOUNTY_1: Radiant safe-side jungle
        3: (3000, 1500),    # BOUNTY_2: Dire safe-side jungle
        4: (-2000, 2500),   # BOUNTY_3: Dire offlane jungle (wraps)
        5: (2000, -2500),   # BOUNTY_4: Radiant offlane jungle
    }

    cases = [
        # Pos 5 Radiant safelane support spawned near (-5000, -5000) — closest
        # bounty is BOUNTY_1 (Radiant safe). With my fix this is NOT a sticky
        # mapping; it picks the closest. v2 (only had BOUNTY_1, _2) would have
        # picked _1 in this case too — both correct. The improvement is for
        # bots near _3 / _4.
        ("Pos 5 Radiant safelane near BOUNTY_1",
         {
             "bots": {
                 1: {"loc": (-4000, -4500), "pos": 1},
                 2: {"loc": (-100, -100), "pos": 2},
                 3: {"loc": (3000, 4500), "pos": 3},
                 4: {"loc": (4500, -3000), "pos": 4},
                 5: {"loc": (-5000, -5000), "pos": 5},
             },
             "rune_locs": rune_locs_standard,
         },
         5, 2),

        # Pos 4 Radiant offlane near BOUNTY_4. v2 would have routed pos 4
        # to RUNE_POWERUP_1 (river top) — empty at 0:00. v3 picks _4.
        # This is the user's "pos 4 not picking up bounty" scenario.
        ("Pos 4 Radiant offlane near BOUNTY_4 (v2 would have missed)",
         {
             "bots": {
                 1: {"loc": (-4000, -4500), "pos": 1},
                 2: {"loc": (-100, -100), "pos": 2},
                 3: {"loc": (3000, 4500), "pos": 3},
                 4: {"loc": (1500, -3000), "pos": 4},   # closest to _4
                 5: {"loc": (-5000, -5000), "pos": 5},  # closest to _1
             },
             "rune_locs": rune_locs_standard,
         },
         4, 5),

        # Distribution: pos 4 and pos 5 both Radiant. _1 and _4 are Radiant-side.
        # IsTheClosestAlly should distribute: pos 5 gets the one they're closer
        # to, pos 4 gets the other.
        ("Distribution: pos 5 picks _1, pos 4 picks _4 (no overlap)",
         {
             "bots": {
                 1: {"loc": (-3500, -4500), "pos": 1},
                 2: {"loc": (-100, -100), "pos": 2},
                 3: {"loc": (3000, 4500), "pos": 3},
                 4: {"loc": (1500, -3000), "pos": 4},   # closest to _4
                 5: {"loc": (-5000, -5000), "pos": 5},  # closest to _1
             },
             "rune_locs": rune_locs_standard,
         },
         5, 2),  # Pos 5 picks _1 (=2)

        # Same scenario, query pos 4
        ("Distribution check: pos 4 query",
         {
             "bots": {
                 1: {"loc": (-3500, -4500), "pos": 1},
                 2: {"loc": (-100, -100), "pos": 2},
                 3: {"loc": (3000, 4500), "pos": 3},
                 4: {"loc": (1500, -3000), "pos": 4},
                 5: {"loc": (-5000, -5000), "pos": 5},
             },
             "rune_locs": rune_locs_standard,
         },
         4, 5),  # Pos 4 picks _4 (=5)
    ]

    passed_count = 0
    for case in cases:
        if run_test(*case):
            passed_count += 1

    print()
    print(f"Result: {passed_count}/{len(cases)} passed")
    return 0 if passed_count == len(cases) else 1


if __name__ == "__main__":
    sys.exit(main())
