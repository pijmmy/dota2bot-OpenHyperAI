"""Static verification harness for team-plan core logic in
bots/FunLib/aba_teamplan.lua.

Covers:
  - computeCommitment: convex commitment growth on sticky intents
  - findPushTarget: picks the lane with the lowest enemy-tier (furthest
    pushed in) when team has enough alive allies
  - getLaneTier: reports correct tier for each lane state

These functions drive the team-coordination layer. If commitment
arithmetic is wrong, plans flip too eagerly. If findPushTarget picks
the wrong lane, the team commits to the wrong objective.
"""

import sys
import lupa
from lupa import LuaRuntime


# ---------------------------------------------------------------------------
# Inline the logic exactly as in aba_teamplan.lua
# ---------------------------------------------------------------------------

LOGIC_LUA = r"""
local INTENT_BASE_COMMITMENT = {
    defend_base       = 1.00,
    save_ally         = 0.95,
    commit_kill       = 0.85,
    contest_rosh      = 0.85,
    contest_tormentor = 0.80,
    smoke_gank        = 0.65,
    push_lane         = 0.50,
    defend_lane       = 0.75,
    lane_gank         = 0.65,
    contest_lotus     = 0.40,
    late_game_group   = 0.55,
    regroup           = 0.45,
    farm              = 0.30,
}

local STICKY_INTENTS = {
    push_lane = true, contest_rosh = true, smoke_gank = true,
    late_game_group = true, commit_kill = true, defend_lane = true,
}

function computeCommitment(intent, planAgeSec)
    local base = INTENT_BASE_COMMITMENT[intent] or 0.50
    if STICKY_INTENTS[intent] then
        local age = planAgeSec or 0
        if age < 0 then age = 0 end
        if age > 30 then age = 30 end
        base = base + (age / 30) * 0.25
    end
    if base < 0 then return 0 end
    if base > 1 then return 1 end
    return base
end

-- findFurthestAliveLaneBuilding + getLaneTier + findPushTarget mirrors

function findFurthestAliveLaneBuilding(team, lane)
    local towers
    if lane == LANE_TOP then
        towers = { TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3 }
    elseif lane == LANE_MID then
        towers = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3 }
    else
        towers = { TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3 }
    end
    for i = 1, #towers do
        local t = GetTower(team, towers[i])
        if t ~= nil and t:IsAlive() then return t end
    end
    return nil
end

function getLaneTier(team, lane)
    local towers
    if lane == LANE_TOP then
        towers = { TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3 }
    elseif lane == LANE_MID then
        towers = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3 }
    else
        towers = { TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3 }
    end
    for i = 1, #towers do
        local t = GetTower(team, towers[i])
        if t ~= nil and t:IsAlive() then return i end
    end
    return 4
end

function countAliveTeamHeroes(team)
    return _aliveCount or 0
end

function findPushTarget(enemyTeam, team, threshold)
    local aliveAllies = countAliveTeamHeroes(team)
    local req = threshold or 4
    if aliveAllies < req then return nil end
    local lanes = { LANE_TOP, LANE_MID, LANE_BOT }
    local bestLane = nil
    local bestLoc = nil
    local bestTier = 99
    for i = 1, #lanes do
        local lane = lanes[i]
        local tier = getLaneTier(enemyTeam, lane)
        if tier < bestTier then
            local building = findFurthestAliveLaneBuilding(enemyTeam, lane)
            if building ~= nil then
                bestTier = tier
                bestLane = lane
                bestLoc = building:GetLocation()
            end
        end
    end
    if bestLane ~= nil and bestTier <= 3 then
        return { lane = bestLane, loc = bestLoc, tier = bestTier }
    end
    return nil
end
"""


def setup_lua():
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("LANE_TOP, LANE_MID, LANE_BOT = 1, 2, 3")
    L.execute("TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3 = 1, 2, 3")
    L.execute("TOWER_MID_1, TOWER_MID_2, TOWER_MID_3 = 4, 5, 6")
    L.execute("TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3 = 7, 8, 9")
    L.execute(LOGIC_LUA)
    return L


# ---------------------------------------------------------------------------
# Tests for computeCommitment
# ---------------------------------------------------------------------------

def test_commitment():
    print("computeCommitment")
    print("-" * 70)
    L = setup_lua()
    cases = [
        # (intent, age, expected, description)
        ("defend_base", 0, 1.0, "defend_base always max (no sticky boost needed)"),
        ("defend_base", 30, 1.0, "defend_base clamped at 1.0 not >1.0"),
        ("save_ally", 0, 0.95, "save_ally not sticky, just base"),
        ("commit_kill", 0, 0.85, "commit_kill not sticky"),
        ("contest_rosh", 0, 0.85, "contest_rosh sticky base 0.85"),
        ("contest_rosh", 30, 1.0, "contest_rosh sticky max 0.85+0.25=1.10 clamped 1.0"),
        ("push_lane", 0, 0.50, "push_lane base 0.50 (advisory)"),
        ("push_lane", 12, 0.60, "push_lane after 12s age boost ~0.10"),
        ("push_lane", 25, 0.708333, "push_lane after 25s, ~0.708"),
        ("push_lane", 30, 0.75, "push_lane after 30s, max 0.50+0.25=0.75"),
        ("regroup", 0, 0.45, "regroup not sticky"),
        ("regroup", 100, 0.45, "regroup not sticky regardless of age"),
        ("smoke_gank", 0, 0.65, "smoke_gank sticky base 0.65"),
        ("smoke_gank", 30, 0.90, "smoke_gank +0.25 = 0.90"),
        ("unknown_intent", 0, 0.5, "unknown intents default to 0.50"),
        ("push_lane", -5, 0.50, "negative age clamped to 0"),
        ("push_lane", 60, 0.75, "age >30 clamped to 30"),
    ]
    passed = 0
    for intent, age, expected, desc in cases:
        L.globals().intent = intent
        L.globals().age = age
        result = L.eval("computeCommitment(intent, age)")
        ok = abs(result - expected) < 0.01
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.4f} (expected {expected})")
        if ok:
            passed += 1
    return passed, len(cases)


# ---------------------------------------------------------------------------
# Tests for findPushTarget + getLaneTier
# ---------------------------------------------------------------------------

class MockTower:
    def __init__(self, alive=True, location=(0, 0)):
        self.alive = alive
        self.location = location
    def IsAlive(self): return self.alive
    def GetLocation(self):
        # Return a simple table-like object
        class L:
            def __init__(s, loc): s.x, s.y = loc[0], loc[1]
        return L(self.location)


def setup_with_towers(towers, alive_count):
    """towers: dict of tower_const -> MockTower. alive_count: aliveAllies."""
    L = setup_lua()

    def get_tower(team, tower_const):
        return towers.get(tower_const)

    L.globals().GetTower = get_tower
    L.execute(f"_aliveCount = {alive_count}")
    return L


def test_lane_tier():
    print()
    print("getLaneTier")
    print("-" * 70)

    cases = [
        ("All TOP towers alive -> tier 1",
         {1: MockTower(), 2: MockTower(), 3: MockTower()}, 1, 1),
        ("TOP T1 dead -> tier 2",
         {1: MockTower(alive=False), 2: MockTower(), 3: MockTower()}, 1, 2),
        ("TOP T1+T2 dead -> tier 3",
         {1: MockTower(alive=False), 2: MockTower(alive=False), 3: MockTower()}, 1, 3),
        ("All TOP dead -> tier 4 (rax / base / ancient land)",
         {1: MockTower(alive=False), 2: MockTower(alive=False), 3: MockTower(alive=False)}, 1, 4),
        ("MID T1 dead, mid lane query",
         {4: MockTower(alive=False), 5: MockTower(), 6: MockTower()}, 2, 2),
        ("BOT all alive, BOT lane query",
         {7: MockTower(), 8: MockTower(), 9: MockTower()}, 3, 1),
    ]
    passed = 0
    for desc, towers, lane, expected in cases:
        L = setup_with_towers(towers, 5)
        L.globals().lane = lane
        result = L.eval("getLaneTier(2, lane)")
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got tier {result} (expected {expected})")
        if ok:
            passed += 1
    return passed, len(cases)


def test_find_push_target():
    print()
    print("findPushTarget")
    print("-" * 70)

    # Standard: all enemy T1 alive across all 3 lanes, 5 allies alive
    all_t1_alive = {
        1: MockTower(alive=True, location=(-3000, 0)),  # TOP T1
        2: MockTower(alive=True), 3: MockTower(alive=True),
        4: MockTower(alive=True, location=(0, 0)),       # MID T1
        5: MockTower(alive=True), 6: MockTower(alive=True),
        7: MockTower(alive=True, location=(3000, 0)),    # BOT T1
        8: MockTower(alive=True), 9: MockTower(alive=True),
    }

    # Mid pushed to T2 (T1 dead), TOP+BOT still T1
    mid_pushed = {
        1: MockTower(alive=True, location=(-3000, 0)),
        2: MockTower(alive=True), 3: MockTower(alive=True),
        4: MockTower(alive=False),
        5: MockTower(alive=True, location=(500, 500)),
        6: MockTower(alive=True),
        7: MockTower(alive=True, location=(3000, 0)),
        8: MockTower(alive=True), 9: MockTower(alive=True),
    }

    # All T1 dead, T2 alive
    all_t2 = {
        1: MockTower(alive=False), 2: MockTower(alive=True, location=(-3500, 0)), 3: MockTower(),
        4: MockTower(alive=False), 5: MockTower(alive=True, location=(0, -500)), 6: MockTower(),
        7: MockTower(alive=False), 8: MockTower(alive=True, location=(3500, 0)), 9: MockTower(),
    }

    cases = [
        # (description, towers, alive_count, threshold, expect_lane, expect_tier)
        ("All T1 alive, 5 allies -> fires on TOP (iteration order tie-break)",
         all_t1_alive, 5, 4, 1, 1),
        ("Mid pushed to T2, 5 allies -> fires on TOP (still tier 1, lower than mid's 2)",
         mid_pushed, 5, 4, 1, 1),
        ("All T2 alive, 5 allies -> tier 2 on TOP",
         all_t2, 5, 4, 1, 2),
        ("3 allies alive (below threshold 4) -> nil",
         all_t1_alive, 3, 4, None, None),
        ("threshold lowered to 3, 3 allies -> fires",
         all_t1_alive, 3, 3, 1, 1),
        ("Threshold met but no buildings (rax/ancient territory) -> nil",
         {1: MockTower(alive=False), 2: MockTower(alive=False), 3: MockTower(alive=False),
          4: MockTower(alive=False), 5: MockTower(alive=False), 6: MockTower(alive=False),
          7: MockTower(alive=False), 8: MockTower(alive=False), 9: MockTower(alive=False)},
         5, 4, None, None),
    ]
    passed = 0
    for desc, towers, alive_count, threshold, expect_lane, expect_tier in cases:
        L = setup_with_towers(towers, alive_count)
        L.globals().threshold = threshold
        result = L.eval("findPushTarget(2, 3, threshold)")
        if expect_lane is None:
            ok = result is None
            detail = "got nil" if result is None else f"got lane {result['lane']}"
        else:
            ok = result is not None and result["lane"] == expect_lane and result["tier"] == expect_tier
            detail = f"got lane {result['lane'] if result else 'nil'}, tier {result['tier'] if result else 'n/a'}"
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: {detail}")
        if ok:
            passed += 1
    return passed, len(cases)


def main():
    print("=" * 70)
    print("Team plan logic verification")
    print("=" * 70)

    p1, t1 = test_commitment()
    p2, t2 = test_lane_tier()
    p3, t3 = test_find_push_target()

    total_passed = p1 + p2 + p3
    total = t1 + t2 + t3

    print()
    print(f"Result: {total_passed}/{total} passed "
          f"(commitment {p1}/{t1}, lane_tier {p2}/{t2}, push_target {p3}/{t3})")
    return 0 if total_passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
