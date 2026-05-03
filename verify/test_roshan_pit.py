"""Static verification harness for the Roshan-pit cache invalidation fix
in jmz_func.lua J.GetCurrentRoshanLocation.

Verifies:
  - Cache invalidation triggers when ANY ally is at the cached pit
    without seeing Roshan (not just the FIRST alive ally)
  - The bug scenario the user reported: pos 1 alive in lane (far) + pos
    4/5 at wrong rosh pit (close) → cache should invalidate
"""

import sys
import lupa
from lupa import LuaRuntime


# Inline the cache invalidation logic exactly as in the fix.
ROSH_INVALIDATION_LUA = r"""
local _lastSeenRoshanLoc = nil
local _lastSeenRoshanTime = 0
local _ROSHAN_SEEN_TTL = 60
local _roshanPitAttempt = 0

function SetCacheState(loc, time, attempt)
    _lastSeenRoshanLoc = loc
    _lastSeenRoshanTime = time
    _roshanPitAttempt = attempt
end

function GetState()
    return {
        loc = _lastSeenRoshanLoc,
        time = _lastSeenRoshanTime,
        attempt = _roshanPitAttempt,
    }
end

-- This is the FIXED logic (closest-ally check, not first-alive).
function CheckCacheInvalidation()
    if _lastSeenRoshanLoc == nil then return "no cache" end
    if (DotaTime() - _lastSeenRoshanTime) >= _ROSHAN_SEEN_TTL then
        return "ttl expired"
    end
    -- The fix: iterate ALL allies, find closest distance to cached pit.
    local closestDist = math.huge
    for i = 1, 5 do
        local m = GetTeamMember(i)
        if m ~= nil and m:IsAlive() then
            local d = GetUnitToLocationDistance(m, _lastSeenRoshanLoc)
            if d < closestDist then closestDist = d end
        end
    end
    if closestDist < 800 then
        _lastSeenRoshanLoc = nil
        _lastSeenRoshanTime = -999
        _roshanPitAttempt = _roshanPitAttempt + 1
        return "invalidated"
    end
    return "kept"
end

-- Old (BUGGY) logic for comparison: first-alive ally only.
function CheckCacheInvalidation_OLD()
    if _lastSeenRoshanLoc == nil then return "no cache" end
    if (DotaTime() - _lastSeenRoshanTime) >= _ROSHAN_SEEN_TTL then
        return "ttl expired"
    end
    local ally = nil
    for i = 1, 5 do
        local m = GetTeamMember(i)
        if m ~= nil and m:IsAlive() then ally = m; break end
    end
    if ally ~= nil then
        local distToCache = GetUnitToLocationDistance(ally, _lastSeenRoshanLoc)
        if distToCache < 800 then
            return "invalidated_old"
        else
            return "kept_old"
        end
    end
    return "no allies"
end
"""


def setup_lua(scenario):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(ROSH_INVALIDATION_LUA)

    # Mock DotaTime
    L.execute(f"function DotaTime() return {scenario.get('now', 100)} end")

    bots = scenario["bots"]  # ordered: index 1..5

    def get_team_member(i):
        bot = bots.get(i)
        if bot is None:
            return None
        if not bot.get("alive", True):
            # Return a dead bot
            class Dead:
                def IsAlive(s): return False
            return Dead()
        return bot

    # Wrap to expose IsAlive properly
    class Bot:
        def __init__(self, data):
            self.data = data
        def IsAlive(self):
            return self.data.get("alive", True)

    def get_team_member_wrap(i):
        d = bots.get(i)
        if d is None: return None
        return Bot(d)

    L.globals().GetTeamMember = get_team_member_wrap

    def get_unit_to_loc_distance(unit, loc):
        ux, uy = unit.data["loc"]
        if isinstance(loc, dict) or hasattr(loc, "x"):
            try:
                lx, ly = loc["x"], loc["y"]
            except Exception:
                lx, ly = loc.x, loc.y
        else:
            lx, ly = loc[0], loc[1]
        return ((ux - lx) ** 2 + (uy - ly) ** 2) ** 0.5

    L.globals().GetUnitToLocationDistance = get_unit_to_loc_distance

    # Set the cached rosh location with a recent timestamp (within TTL).
    if "cached_pit" in scenario:
        cached_x, cached_y = scenario["cached_pit"]
        cache_time = scenario.get("now", 100) - 5  # 5s ago, within 60s TTL
        L.execute(f"SetCacheState({{x={cached_x}, y={cached_y}}}, {cache_time}, 0)")

    return L


def run_test(name, scenario, expect_new, expect_old=None):
    """
    expect_new: what the FIXED logic returns ('invalidated' or 'kept')
    expect_old: what the OLD (buggy) logic returns — used to demonstrate
        the bug fix (some scenarios should differ between old and new)
    """
    # Run OLD first in a fresh state, then NEW in another fresh state, so
    # one's mutation doesn't affect the other's read.
    L_old = setup_lua(scenario)
    old_result = L_old.eval("CheckCacheInvalidation_OLD()")
    L = setup_lua(scenario)
    new_result = L.eval("CheckCacheInvalidation()")
    passed = new_result == expect_new
    status = "PASS" if passed else "FAIL"
    detail = f"new={new_result}"
    if expect_old is not None:
        detail += f", old={old_result}"
        if old_result != expect_old:
            detail += f" (expected old={expect_old})"
    print(f"  [{status}] {name}: {detail} (expected new={expect_new})")
    return passed


def main():
    print("=" * 70)
    print("Roshan pit cache invalidation verification")
    print("=" * 70)

    # Roshan pit at (-3000, 3000) (Dire-side pit; arbitrary).
    rosh_pit = (-3000, 3000)

    cases = [
        # The user's exact bug: pos 1 carry alive in lane (far from pit),
        # pos 4 + 5 supports AT the pit. Old code checks pos 1's distance
        # (huge) and fails to invalidate. New code checks closest-ally
        # (pos 5 at pit) and invalidates.
        ("BUG: pos 1 in lane, supports at wrong pit (old keeps cache)",
         {
             "now": 100,
             "cached_pit": rosh_pit,
             "bots": {
                 1: {"loc": (-4000, -4500), "alive": True},  # Pos 1 in lane, far from pit
                 2: {"loc": (1000, -1000), "alive": True},
                 3: {"loc": (3000, 4500), "alive": True},
                 4: {"loc": (-2700, 3200), "alive": True},  # Pos 4 at pit (~360u away)
                 5: {"loc": (-3000, 3000), "alive": True},  # Pos 5 AT pit (0u)
             },
         },
         "invalidated", "kept_old"),

        # Single ally at pit alive: invalidate (both old and new)
        ("Single ally at pit (both invalidate)",
         {
             "now": 100,
             "cached_pit": rosh_pit,
             "bots": {
                 1: {"loc": (-3000, 3000), "alive": True},  # Pos 1 AT pit
             },
         },
         "invalidated", "invalidated_old"),

        # No allies near pit: keep cache (both)
        ("No allies near pit (both keep)",
         {
             "now": 100,
             "cached_pit": rosh_pit,
             "bots": {
                 1: {"loc": (-4000, -4500), "alive": True},
                 2: {"loc": (1000, -1000), "alive": True},
                 3: {"loc": (3000, 4500), "alive": True},
             },
         },
         "kept", "kept_old"),

        # Pos 1 dead, pos 4 at pit. Old code: ally = pos 4 (first alive)
        # → invalidates. New code: closest = pos 4 (only alive, at pit)
        # → invalidates. Both work.
        ("Pos 1 dead, pos 4 alive at pit (both invalidate)",
         {
             "now": 100,
             "cached_pit": rosh_pit,
             "bots": {
                 1: {"loc": (-4000, -4500), "alive": False},
                 4: {"loc": (-3000, 3000), "alive": True},
             },
         },
         "invalidated", "invalidated_old"),

        # All allies dead: cache stays
        ("All allies dead (no allies; both keep)",
         {
             "now": 100,
             "cached_pit": rosh_pit,
             "bots": {
                 1: {"loc": (-4000, -4500), "alive": False},
                 2: {"loc": (1000, -1000), "alive": False},
             },
         },
         "kept", "no allies"),
    ]

    passed_count = 0
    bug_demonstrated = False
    for case in cases:
        if run_test(*case):
            passed_count += 1
        # The first case explicitly demonstrates the bug — old kept, new invalidated
        if case[0].startswith("BUG"):
            L = setup_lua(case[1])
            old = L.eval("CheckCacheInvalidation_OLD()")
            new = L.eval("CheckCacheInvalidation()")
            if old == "kept_old" and new == "invalidated":
                bug_demonstrated = True

    print()
    print(f"Result: {passed_count}/{len(cases)} passed")
    if bug_demonstrated:
        print("Bug demonstrated: old logic KEPT stale cache; new logic INVALIDATES it.")
    return 0 if passed_count == len(cases) else 1


if __name__ == "__main__":
    sys.exit(main())
