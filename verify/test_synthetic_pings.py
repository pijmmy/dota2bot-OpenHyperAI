"""Static verification harness for the synthetic team-ping system in
bots/FunLib/aba_synthetic_pings.lua.

Verifies pickObjective's strategy-driven branching:
  - early_aggro / fast_siege: enemy weakest tower (push)
  - split_push: tower mostly, occasional rosh after 12:00
  - teamfight_mid: alternates rosh / tower after 14:00
  - late_scale: own front tower until 28:00, then enemy
  - turtle_defensive: own front tower
  - fallback: enemy tower then own
And teamHasHuman gate (returns nil for mixed-team).
"""

import sys
from lupa import LuaRuntime


PINGS_LUA = r"""
function teamHasHuman(team)
    local players = GetTeamPlayers(team)
    if players == nil then return false end
    for i = 1, #players do
        if not IsPlayerBot(players[i]) then return true end
    end
    return false
end

local _state = {}
function getTeamState(team)
    if _state[team] == nil then
        _state[team] = { last_refresh = -999, current_ping = nil, cycle_index = 0 }
    end
    return _state[team]
end

function pickObjective(team, strategy, now, cycle_override)
    local enemyTeam = (team == 2) and 3 or 2
    local s = getTeamState(team)
    if cycle_override ~= nil then s.cycle_index = cycle_override - 1 end
    s.cycle_index = (s.cycle_index + 1) % 4

    local function getWeakestEnemyTower()
        return _enemy_tower_loc, "push"
    end
    local function getFrontmostOwnTower()
        return _own_tower_loc, "defend"
    end
    local function getRoshLoc()
        return _rosh_loc
    end

    if strategy == "early_aggro" or strategy == "fast_siege" then
        if _enemy_tower_loc ~= nil then return _enemy_tower_loc, "push" end
    elseif strategy == "split_push" then
        if s.cycle_index == 0 and now > 12 * 60 then
            local r = getRoshLoc()
            if r ~= nil then return r, "rosh" end
        end
        if _enemy_tower_loc ~= nil then return _enemy_tower_loc, "push" end
    elseif strategy == "teamfight_mid" then
        if (s.cycle_index == 0 or s.cycle_index == 2) and now > 14 * 60 then
            local r = getRoshLoc()
            if r ~= nil then return r, "rosh" end
        end
        if _enemy_tower_loc ~= nil then return _enemy_tower_loc, "push" end
    elseif strategy == "late_scale" then
        if now < 28 * 60 then
            if _own_tower_loc ~= nil then return _own_tower_loc, "defend" end
        else
            if _enemy_tower_loc ~= nil then return _enemy_tower_loc, "push" end
        end
    elseif strategy == "turtle_defensive" then
        if _own_tower_loc ~= nil then return _own_tower_loc, "defend" end
    end

    -- Fallback
    if _enemy_tower_loc ~= nil then return _enemy_tower_loc, "push" end
    if _own_tower_loc ~= nil then return _own_tower_loc, "defend" end
    return nil, nil
end
"""


def setup_lua(scenario):
    L = LuaRuntime(unpack_returned_tuples=True)

    # Mock team players — None = bot-only team
    has_human = bool(scenario.get("human_pids"))
    if has_human:
        L.execute("function GetTeamPlayers(team) return {1, 2} end")
        human_pids = scenario["human_pids"]
        L.execute(f"_human_pids = {{{','.join(str(p) for p in human_pids)}}}")
        L.execute("""
            function IsPlayerBot(pid)
                for i = 1, #_human_pids do
                    if _human_pids[i] == pid then return false end
                end
                return true
            end
        """)
    else:
        L.execute("function GetTeamPlayers(team) return {1, 2, 3, 4, 5} end")
        L.execute("function IsPlayerBot(pid) return true end")

    # Inject locations
    L.execute(f"_enemy_tower_loc = {scenario.get('enemy_tower') and 'true' or 'nil'}")
    if scenario.get("enemy_tower"):
        L.execute("_enemy_tower_loc = 'enemy_tower'")
    if scenario.get("own_tower"):
        L.execute("_own_tower_loc = 'own_tower'")
    if scenario.get("rosh"):
        L.execute("_rosh_loc = 'rosh'")
    L.execute(PINGS_LUA)
    return L


def main():
    print("=" * 70)
    print("Synthetic pings verification")
    print("=" * 70)

    passed = 0
    total = 0

    # --- teamHasHuman ---
    print()
    print("teamHasHuman gate")
    print("-" * 70)
    cases = [
        ("All-bot team -> false", {}, 2, False),
        ("Mixed team with human -> true", {"human_pids": [1]}, 2, True),
    ]
    for desc, scen, team, expected in cases:
        total += 1
        L = setup_lua(scen)
        result = L.eval(f"teamHasHuman({team})")
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    # --- Strategy-driven objective selection ---
    print()
    print("pickObjective strategy branching")
    print("-" * 70)

    full_scenario = {"enemy_tower": True, "own_tower": True, "rosh": True}

    obj_cases = [
        # (description, strategy, now, cycle_set, expected_tag)
        ("early_aggro -> push (weakest enemy tower)",
         "early_aggro", 60, None, "push"),
        ("fast_siege -> push",
         "fast_siege", 60, None, "push"),
        ("split_push at cycle 0 + 13min -> rosh",
         "split_push", 13*60, 4, "rosh"),  # cycle becomes 0 after +1 mod 4
        ("split_push at cycle 1 -> push",
         "split_push", 13*60, 1, "push"),
        ("split_push pre-12min -> push (rosh gate not open)",
         "split_push", 5*60, 4, "push"),
        ("teamfight_mid at cycle 0 + 15min -> rosh",
         "teamfight_mid", 15*60, 4, "rosh"),
        ("teamfight_mid at cycle 2 + 15min -> rosh",
         "teamfight_mid", 15*60, 2, "rosh"),  # cycle_override=X yields final cycle=X
        ("teamfight_mid at cycle 1 -> push",
         "teamfight_mid", 15*60, 1, "push"),  # cycle 1 not in {0,2} -> push
        ("teamfight_mid pre-14min -> push (rosh gate not open)",
         "teamfight_mid", 10*60, 4, "push"),
        ("late_scale before 28min -> defend (own tower)",
         "late_scale", 20*60, None, "defend"),
        ("late_scale after 28min -> push",
         "late_scale", 30*60, None, "push"),
        ("turtle_defensive -> defend",
         "turtle_defensive", 60, None, "defend"),
        ("turtle_defensive late game -> defend (still)",
         "turtle_defensive", 40*60, None, "defend"),
        ("Unknown strategy -> fallback push",
         "unknown_strat", 60, None, "push"),
    ]
    for desc, strat, now, cycle, expected in obj_cases:
        total += 1
        L = setup_lua(full_scenario)
        cycle_arg = "nil" if cycle is None else str(cycle)
        L.execute(f"_loc, _tag = pickObjective(2, '{strat}', {now}, {cycle_arg})")
        tag = L.eval("_tag")
        ok = tag == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: tag={tag} (expected {expected})")
        if ok:
            passed += 1

    # --- Fallback when no enemy towers ---
    print()
    print("Fallback handling")
    print("-" * 70)
    fb_cases = [
        ("No enemy tower, own tower exists -> defend (fallback)",
         {"own_tower": True}, "early_aggro", "defend"),
        ("No towers at all -> nil",
         {}, "early_aggro", None),
    ]
    for desc, scen, strat, expected in fb_cases:
        total += 1
        L = setup_lua(scen)
        L.execute(f"_loc, _tag = pickObjective(2, '{strat}', 60, nil)")
        tag = L.eval("_tag")
        ok = tag == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: tag={tag} (expected {expected})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
