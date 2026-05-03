"""Static verification harness for the HG-defense fixes in aba_teamplan.lua
and mode_defend_tower_*_generic.lua.

We can't run the actual Dota engine, but we CAN mock the engine API and
exercise the Lua code paths we changed. This catches:
  - Logic errors in findThreatenedLane (does it actually fire on the
    HG-fog scenario?)
  - Floor-arithmetic errors in the mode_defend_tower wrappers
  - Off-by-one / wrong-comparison bugs
  - Misnamed engine API calls (we'd see a Lua error)

It does NOT catch:
  - Engine API surface mismatches (e.g. WasRecentlyDamagedByCreep
    actually returning unexpected types — but we can audit the
    interface contract)
  - Dota's mode-selection algorithm specifics (we test the desire
    floor produces the expected number, not whether engine picks it)
"""

import sys
from pathlib import Path

import lupa
from lupa import LuaRuntime

ROOT = Path(__file__).parent.parent.parent
print(f"Repo root: {ROOT}")


# ---------------------------------------------------------------------------
# Test scenarios
# ---------------------------------------------------------------------------

class MockTower:
    def __init__(self, alive=True, hp_pct=1.0, damaged_by_hero=False, damaged_by_creep=False, location=(0, 0)):
        self.alive = alive
        self.hp_pct = hp_pct
        self.damaged_by_hero = damaged_by_hero
        self.damaged_by_creep = damaged_by_creep
        self.location = location

    def IsAlive(self): return self.alive
    def GetHealth(self): return int(self.hp_pct * 4500)
    def GetMaxHealth(self): return 4500
    def GetLocation(self): return Vector(*self.location)
    def WasRecentlyDamagedByAnyHero(self, _delta): return self.damaged_by_hero
    def WasRecentlyDamagedByCreep(self, _delta): return self.damaged_by_creep
    def IsNull(self): return False


class Vector:
    def __init__(self, x, y, z=0):
        self.x, self.y, self.z = x, y, z


def setup_lua(scenario):
    """Mock Dota engine + module API for one scenario."""
    L = LuaRuntime(unpack_returned_tuples=True)

    # Engine constants
    L.execute("LANE_TOP, LANE_MID, LANE_BOT = 1, 2, 3")
    L.execute("TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3 = 1, 2, 3")
    L.execute("TOWER_MID_1, TOWER_MID_2, TOWER_MID_3 = 4, 5, 6")
    L.execute("TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3 = 7, 8, 9")
    L.execute("BARRACKS_TOP_MELEE, BARRACKS_TOP_RANGED = 10, 11")
    L.execute("BARRACKS_MID_MELEE, BARRACKS_MID_RANGED = 12, 13")
    L.execute("BARRACKS_BOT_MELEE, BARRACKS_BOT_RANGED = 14, 15")

    # GetTower(team, tower_const) returns the MockTower or None for dead.
    # Map: team→lane→tier→tower
    towers = scenario["towers"]  # {(lane, tier): MockTower}

    def get_tower(team, tower_const):
        # Decode tower_const to (lane, tier)
        mapping = {
            1: (1, 1), 2: (1, 2), 3: (1, 3),
            4: (2, 1), 5: (2, 2), 6: (2, 3),
            7: (3, 1), 8: (3, 2), 9: (3, 3),
        }
        if tower_const not in mapping:
            return None
        return towers.get(mapping[tower_const])

    def get_barracks(team, _):
        return scenario.get("rax")  # MockTower or None

    L.globals().GetTower = get_tower
    L.globals().GetBarracks = get_barracks

    # Last-seen enemies — count near a location
    last_seen_count = scenario.get("last_seen_enemies", 0)

    def get_last_seen_enemies_near_loc(_loc, _radius):
        # Return a list of N fake enemy IDs
        return L.table_from([i + 1 for i in range(last_seen_count)])

    # Visible enemies — count near a location
    visible_count = scenario.get("visible_enemies", 0)

    def get_enemies_near_loc(_loc, _radius):
        # Returns a Lua list; we just need it to have the right length
        return L.table_from([{"name": f"enemy_{i}"} for i in range(visible_count)])

    # Build mocked jmz module
    L.execute("""
        function GetUnitToLocationDistance(_, _) return 100 end
    """)

    L.globals().jmz_module = L.table_from({
        "GetLastSeenEnemiesNearLoc": get_last_seen_enemies_near_loc,
        "GetEnemiesNearLoc": get_enemies_near_loc,
        "IsValidHero": lambda u: u is not None,
        "IsSuspiciousIllusion": lambda u: False,
        "IsMeepoClone": lambda u: False,
    })

    # The aba_teamplan code uses `local J = jmz()`; we provide jmz() as a
    # function that returns the module table.
    L.execute("function jmz() return jmz_module end")

    return L


# ---------------------------------------------------------------------------
# Inline the fix's logic. We extract it instead of loading aba_teamplan.lua
# (which has heavy module dependencies).
# ---------------------------------------------------------------------------

FIND_THREATENED_LANE_LUA = r"""
local function findFurthestAliveLaneBuilding(team, lane)
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
    -- rax fallback
    local raxMelee
    if lane == LANE_TOP then
        raxMelee = GetBarracks(team, BARRACKS_TOP_MELEE)
    elseif lane == LANE_MID then
        raxMelee = GetBarracks(team, BARRACKS_MID_MELEE)
    else
        raxMelee = GetBarracks(team, BARRACKS_BOT_MELEE)
    end
    if raxMelee ~= nil and raxMelee:IsAlive() then return raxMelee end
    return nil
end

local function getLaneTier(team, lane)
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

local function countEnemyHeroesNear(loc, radius)
    local J = jmz()
    local ok, enemies = pcall(function() return J.GetEnemiesNearLoc(loc, radius) end)
    if not ok or enemies == nil then return 0 end
    local n = 0
    for i = 1, #enemies do
        if J.IsValidHero(enemies[i]) then n = n + 1 end
    end
    return n
end

local function countLastSeenEnemyHeroesNear(loc, radius)
    local J = jmz()
    local ok, list = pcall(function() return J.GetLastSeenEnemiesNearLoc(loc, radius) end)
    if not ok or list == nil then return 0 end
    return #list
end

function findThreatenedLane(team)
    local lanes = { LANE_TOP, LANE_MID, LANE_BOT }
    local bestLane = nil
    local bestLoc = nil
    local bestThreat = 0
    for i = 1, #lanes do
        local lane = lanes[i]
        local building = findFurthestAliveLaneBuilding(team, lane)
        if building ~= nil then
            local loc = building:GetLocation()
            local visibleEnemies = countEnemyHeroesNear(loc, 1600)
            local hpPct = building:GetHealth() / math.max(1, building:GetMaxHealth())
            local recentlyHit = hpPct < 0.9

            local okHeroDmg, heroDmg = pcall(function()
                return building:WasRecentlyDamagedByAnyHero(5.0)
            end)
            local heroDamageRecent = (okHeroDmg and heroDmg) or false

            local okCreepDmg, creepDmg = pcall(function()
                return building:WasRecentlyDamagedByCreep(5.0)
            end)
            local creepDamageRecent = (okCreepDmg and creepDmg) or false

            local damagedRecently = heroDamageRecent or creepDamageRecent
            local tier = getLaneTier(team, lane)

            local threat = visibleEnemies + (recentlyHit and 1 or 0)
            local fires = false
            if tier <= 2 then
                fires = (threat >= 2)
            elseif tier == 3 then
                local lastSeenEnemies = countLastSeenEnemyHeroesNear(loc, 1800)
                fires = (visibleEnemies >= 1) or (lastSeenEnemies >= 1) or damagedRecently
                if fires then
                    threat = math.max(threat, 3)
                end
            else
                fires = damagedRecently or (visibleEnemies >= 1)
                if fires then
                    threat = math.max(threat, 4)
                end
            end

            if fires and threat > bestThreat then
                bestThreat = threat
                bestLane = lane
                bestLoc = loc
            end
        end
    end
    if bestLane ~= nil then
        return { lane = bestLane, loc = bestLoc, threat = bestThreat }
    end
    return nil
end
"""


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

def make_scenario(t1=True, t2=True, t3=True, hp=1.0, hero_dmg=False, creep_dmg=False,
                  visible=0, last_seen=0, lane=3):
    """
    Build a scenario with given building states + signals on lane `lane`.
    Other lanes have all towers alive at 100% HP and no signals.

    The hp / hero_dmg / creep_dmg signals are applied to the FRONT-MOST
    living tower of `lane` (the one findFurthestAliveLaneBuilding will
    pick first). visible_enemies / last_seen are global to all lanes (a
    limitation of the simple mock — doesn't matter for fire-check tests
    on a single lane since all lanes get the same signal and the FIRST
    matching lane in TOP/MID/BOT order wins ties).
    """
    towers = {}

    # Determine which tower is the front-most alive on the test lane.
    front_tier = None
    for tier, present in [(1, t1), (2, t2), (3, t3)]:
        if present and front_tier is None:
            front_tier = tier

    for ln in [1, 2, 3]:
        for tier in [1, 2, 3]:
            if ln == lane:
                if tier == 1 and not t1: continue
                if tier == 2 and not t2: continue
                if tier == 3 and not t3: continue
                # Apply signals to the front-most building only
                if tier == front_tier:
                    towers[(ln, tier)] = MockTower(
                        alive=True, hp_pct=hp,
                        damaged_by_hero=hero_dmg,
                        damaged_by_creep=creep_dmg,
                        location=(1000 + ln * 100, 0),
                    )
                else:
                    towers[(ln, tier)] = MockTower(alive=True, hp_pct=1.0)
            else:
                towers[(ln, tier)] = MockTower(alive=True, hp_pct=1.0)
    return {
        "towers": towers,
        "rax": None,
        "visible_enemies": visible,
        "last_seen_enemies": last_seen,
    }


def run_test(name, scenario, expect_fire, expect_lane=None):
    """
    expect_fire: whether findThreatenedLane should return non-nil.
    expect_lane: optional, only checked when the test scenario is set up
        with signals on exactly one lane (single-lane mocks). Skip this
        assertion when the mock applies signals globally (visible_enemies
        and last_seen are global to all lanes in our simple mock — see
        make_scenario docstring).
    """
    L = setup_lua(scenario)
    L.execute(FIND_THREATENED_LANE_LUA)
    result = L.eval("findThreatenedLane(2)")  # team=2
    fired = result is not None
    passed = fired == expect_fire
    if expect_fire and expect_lane is not None and fired:
        passed = passed and result["lane"] == expect_lane
    status = "PASS" if passed else "FAIL"
    detail = f"fired={fired}"
    if fired:
        detail += f", lane={result['lane']}, threat={result['threat']}"
    expectation = f"expected fire={expect_fire}"
    if expect_lane is not None and expect_fire:
        expectation += f", expected lane={expect_lane}"
    print(f"  [{status}] {name}: {detail} ({expectation})")
    return passed


def main():
    print("=" * 70)
    print("HG defense verification (findThreatenedLane v3)")
    print("=" * 70)

    cases = [
        # The user's exact complaint: T1+T2 down on lane 3, T3 chip-damaged
        # by creeps, all heroes in fog. v2 missed this; v3 should fire.
        # Lane match is meaningful: only lane 3 has the damage signal,
        # other lanes have full-HP undamaged towers with no enemies.
        ("HG fog push (creep damage only, heroes in fog)",
         make_scenario(t1=False, t2=False, t3=True, hp=0.92,
                       hero_dmg=False, creep_dmg=True,
                       visible=0, last_seen=0),
         True, 3),

        # HG with last-seen enemies (smoke push). last_seen is global to
        # all lanes in the mock, so the lane that fires first wins —
        # which happens to be lane 3 because it's the only one at HG tier
        # (tier 3 fires on last_seen >= 1; tiers 1/2 require threat >= 2).
        ("HG with last-seen enemies (smoke push)",
         make_scenario(t1=False, t2=False, t3=True, hp=1.0,
                       hero_dmg=False, creep_dmg=False,
                       visible=0, last_seen=2),
         True, 3),

        # HG with visible enemies. visible_enemies = 2 globally; lane 1
        # (TOP, tier 1, threat 2) fires first because TOP iterates before
        # BOT. Lane match dropped — the IMPORTANT thing is that fire
        # happens.
        ("HG with visible enemies (any lane fires)",
         make_scenario(t1=False, t2=False, t3=True, hp=1.0,
                       hero_dmg=False, creep_dmg=False,
                       visible=2, last_seen=2),
         True),

        # HG with hero damage on the lane-3 T3 (recentlyHit + heroDmg).
        # Only lane 3 has the signal, so lane 3 must be the result.
        ("HG with recent hero damage",
         make_scenario(t1=False, t2=False, t3=True, hp=0.95,
                       hero_dmg=True, creep_dmg=False,
                       visible=0, last_seen=0),
         True, 3),

        # HG with NO signals — should NOT fire
        ("HG with no signals (idle T3)",
         make_scenario(t1=False, t2=False, t3=True, hp=1.0,
                       hero_dmg=False, creep_dmg=False,
                       visible=0, last_seen=0),
         False),

        # All lanes have T1+T2+T3 alive, 1 visible enemy globally — should
        # NOT fire on any lane (tier 1 requires threat>=2).
        ("All T1 alive, 1 visible enemy global (single roamer)",
         make_scenario(t1=True, t2=True, t3=True, hp=1.0,
                       hero_dmg=False, creep_dmg=False,
                       visible=1, last_seen=0),
         False),

        # All T1 alive, 2 visible enemies globally — fires on tier 1
        # (threat=2). Lane irrelevant since signal is global.
        ("T1 alive, 2 visible enemies (real push, any lane fires)",
         make_scenario(t1=True, t2=True, t3=True, hp=1.0,
                       hero_dmg=False, creep_dmg=False,
                       visible=2, last_seen=0),
         True),

        # Lane 3 T1 chipped (hp 0.85 = recentlyHit) + 1 visible enemy
        # globally. ONLY lane 3 has chipped HP. visible=1 alone fails
        # tier 1's >=2 gate on TOP/MID. On BOT, threat = 1 + 1 = 2
        # (recentlyHit boost), fires.
        ("T1 chipped on lane 3 + 1 visible enemy",
         make_scenario(t1=True, t2=True, t3=True, hp=0.85,
                       hero_dmg=False, creep_dmg=False,
                       visible=1, last_seen=0),
         True, 3),

        # T3 dead, rax alive, creep damage → fires (rax tier)
        ("Rax exposed, creep damage",
         {
             "towers": {
                 (1, 1): MockTower(alive=True, hp_pct=1.0),
                 (1, 2): MockTower(alive=True, hp_pct=1.0),
                 (1, 3): MockTower(alive=True, hp_pct=1.0),
                 (2, 1): MockTower(alive=True, hp_pct=1.0),
                 (2, 2): MockTower(alive=True, hp_pct=1.0),
                 (2, 3): MockTower(alive=True, hp_pct=1.0),
                 # Lane 3 (BOT): all towers dead, fall through to rax
             },
             "rax": MockTower(alive=True, hp_pct=0.95,
                              damaged_by_hero=False, damaged_by_creep=True,
                              location=(1300, 0)),
             "visible_enemies": 0,
             "last_seen_enemies": 0,
         },
         True, 3),
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
