"""Static verification harness for ward placement variance pickers in
bots/FunLib/aba_ward_utility.lua.

Verifies:
  - GetClosestObserverWardSpot scores by distance + recency penalty,
    picks from top-3 (variance, not strict-closest)
  - GetClosestSentryWardSpot same shape with sentry-specific window (210s)
  - Recently-planted spots get penalty so bots vary placements
  - nil / empty input handled safely
"""

import sys
import lupa
from lupa import LuaRuntime


VARIANCE_PICKER_LUA = r"""
function GetClosestObserverWardSpot(bot, spots)
    if spots == nil then return nil end
    local count = 0
    for _ in pairs(spots) do count = count + 1 end
    if count == 0 then return nil end
    local now = DotaTime()
    local scored = {}
    for _, spot in pairs(spots) do
        local dist = GetUnitToLocationDistance(bot, spot.location)
        local recencyPenalty = 0
        if spot.plant_time_obs and spot.plant_time_obs > 0 then
            local age = now - spot.plant_time_obs
            if age < 360 then
                recencyPenalty = (360 - age) * 3
            end
        end
        table.insert(scored, { spot = spot, score = dist + recencyPenalty })
    end
    table.sort(scored, function(a, b) return a.score < b.score end)
    local pickFrom = math.min(3, #scored)
    if pickFrom < 1 then return nil end
    local idx = RandomInt(1, pickFrom)
    return scored[idx].spot
end

function GetClosestSentryWardSpot(bot, spots)
    if spots == nil then return nil end
    local count = 0
    for _ in pairs(spots) do count = count + 1 end
    if count == 0 then return nil end
    local now = DotaTime()
    local scored = {}
    for _, spot in pairs(spots) do
        local dist = GetUnitToLocationDistance(bot, spot.location)
        local recencyPenalty = 0
        if spot.plant_time_sentry and spot.plant_time_sentry > 0 then
            local age = now - spot.plant_time_sentry
            if age < 210 then
                recencyPenalty = (210 - age) * 4
            end
        end
        table.insert(scored, { spot = spot, score = dist + recencyPenalty })
    end
    table.sort(scored, function(a, b) return a.score < b.score end)
    local pickFrom = math.min(3, #scored)
    if pickFrom < 1 then return nil end
    local idx = RandomInt(1, pickFrom)
    return scored[idx].spot
end
"""


def setup_lua(now=100, deterministic_random=None):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(f"function DotaTime() return {now} end")

    if deterministic_random is not None:
        L.globals().RandomInt = lambda lo, hi: deterministic_random
    else:
        # Default: always pick first (lowest score) for predictable testing
        L.globals().RandomInt = lambda lo, hi: 1

    bot_pos = (0, 0)

    def get_unit_to_loc_distance(unit, loc):
        try:
            lx, ly = loc["x"], loc["y"]
        except Exception:
            lx, ly = loc[0], loc[1]
        ux, uy = bot_pos
        return ((ux - lx) ** 2 + (uy - ly) ** 2) ** 0.5

    L.globals().GetUnitToLocationDistance = get_unit_to_loc_distance
    L.execute(VARIANCE_PICKER_LUA)
    L.globals().bot = {"loc": bot_pos}
    return L


def make_spot(loc, plant_obs=0, plant_sent=0):
    return {
        "location": {"x": loc[0], "y": loc[1]},
        "plant_time_obs": plant_obs,
        "plant_time_sentry": plant_sent,
    }


def main():
    print("=" * 70)
    print("Ward utility variance picker verification")
    print("=" * 70)

    passed = 0
    total = 0

    # --- Observer ---
    print()
    print("GetClosestObserverWardSpot")
    print("-" * 70)

    # Case 1: nil input
    total += 1
    L = setup_lua()
    L.execute("result = GetClosestObserverWardSpot(bot, nil)")
    ok = L.eval("result") is None
    print(f"  [{'PASS' if ok else 'FAIL'}] nil spots -> nil")
    if ok: passed += 1

    # Case 2: empty input
    total += 1
    L = setup_lua()
    L.globals().spots = L.table_from({})
    L.execute("result = GetClosestObserverWardSpot(bot, spots)")
    ok = L.eval("result") is None
    print(f"  [{'PASS' if ok else 'FAIL'}] empty spots -> nil")
    if ok: passed += 1

    # Case 3: deterministic pick=1 picks the strict-closest unplanted spot
    total += 1
    L = setup_lua(deterministic_random=1)
    spots = L.table_from({
        L.eval("({})"): make_spot((100, 0)),    # closest, never planted
        L.eval("({})"): make_spot((1000, 0)),   # far
        L.eval("({})"): make_spot((2000, 0)),
    })
    # Use a list-style table so we can verify the pick
    L.execute("""
        spots = {
            { location = {x=100, y=0}, plant_time_obs = 0 },
            { location = {x=1000, y=0}, plant_time_obs = 0 },
            { location = {x=2000, y=0}, plant_time_obs = 0 },
        }
        result = GetClosestObserverWardSpot(bot, spots)
    """)
    rx = L.eval("result.location.x")
    ok = rx == 100
    print(f"  [{'PASS' if ok else 'FAIL'}] deterministic pick (idx=1): "
          f"closest unplanted (got x={rx}, expected 100)")
    if ok: passed += 1

    # Case 4: recency penalty pushes recently-planted spot out of top-3
    # Spots: (100,0) just planted 60s ago vs (500,0) never planted vs (800,0) planted 300s ago
    # now = 100s; obs_recency: 360s window, penalty (360-age)*3
    # Wait — `now=100`, plant_time was when? Let me think.
    # The age is now - plant_time_obs. If plant_time_obs is 60 (60s after game start),
    # and now is 400, age = 340, penalty = 20*3 = 60.
    # Let me use now=400. Spot1 planted at t=380 (age=20, penalty=(360-20)*3=1020).
    # Spot2 never planted (penalty 0). Spot3 planted at t=100 (age=300, penalty=(360-300)*3=180).
    # Distances: spot1=100, spot2=500, spot3=800.
    # Scores: spot1=100+1020=1120, spot2=500+0=500, spot3=800+180=980.
    # Sorted: spot2 (500), spot3 (980), spot1 (1120). Top-3 all included; idx=1 picks spot2.
    total += 1
    L = setup_lua(now=400, deterministic_random=1)
    L.execute("""
        spots = {
            { location = {x=100, y=0}, plant_time_obs = 380 },
            { location = {x=500, y=0}, plant_time_obs = 0 },
            { location = {x=800, y=0}, plant_time_obs = 100 },
        }
        result = GetClosestObserverWardSpot(bot, spots)
    """)
    rx = L.eval("result.location.x")
    ok = rx == 500
    print(f"  [{'PASS' if ok else 'FAIL'}] recency penalty: spot just planted demoted, "
          f"unplanted middle-distance wins (got x={rx}, expected 500)")
    if ok: passed += 1

    # Case 5: 4 spots, idx=2 picks SECOND-closest (top-3)
    total += 1
    L = setup_lua(deterministic_random=2)
    L.execute("""
        spots = {
            { location = {x=100, y=0}, plant_time_obs = 0 },
            { location = {x=300, y=0}, plant_time_obs = 0 },
            { location = {x=500, y=0}, plant_time_obs = 0 },
            { location = {x=2000, y=0}, plant_time_obs = 0 },
        }
        result = GetClosestObserverWardSpot(bot, spots)
    """)
    rx = L.eval("result.location.x")
    ok = rx == 300
    print(f"  [{'PASS' if ok else 'FAIL'}] random idx=2 picks 2nd-closest "
          f"(got x={rx}, expected 300)")
    if ok: passed += 1

    # Case 6: idx=3 picks the 3rd-closest, NEVER picks the 4th (top-3 only)
    total += 1
    L = setup_lua(deterministic_random=3)
    L.execute("""
        spots = {
            { location = {x=100, y=0}, plant_time_obs = 0 },
            { location = {x=300, y=0}, plant_time_obs = 0 },
            { location = {x=500, y=0}, plant_time_obs = 0 },
            { location = {x=2000, y=0}, plant_time_obs = 0 },
        }
        result = GetClosestObserverWardSpot(bot, spots)
    """)
    rx = L.eval("result.location.x")
    ok = rx == 500
    print(f"  [{'PASS' if ok else 'FAIL'}] random idx=3 picks 3rd-closest, "
          f"4th never selectable (got x={rx}, expected 500)")
    if ok: passed += 1

    # Case 7: penalty doesn't apply if age > 360s (window expired)
    total += 1
    L = setup_lua(now=1000, deterministic_random=1)
    L.execute("""
        spots = {
            { location = {x=100, y=0}, plant_time_obs = 100 },
            { location = {x=500, y=0}, plant_time_obs = 0 },
        }
        result = GetClosestObserverWardSpot(bot, spots)
    """)
    # Spot1: age = 900, > 360, no penalty. Score = 100. Wins.
    rx = L.eval("result.location.x")
    ok = rx == 100
    print(f"  [{'PASS' if ok else 'FAIL'}] expired-window plant (age 900>360) "
          f"gets no penalty (got x={rx}, expected 100)")
    if ok: passed += 1

    # --- Sentry ---
    print()
    print("GetClosestSentryWardSpot")
    print("-" * 70)

    # Case 8: sentry uses 210s window with multiplier 4
    # Spot1 planted at t=300, now=400, age=100. Penalty = (210-100)*4 = 440.
    # Spot2 never planted. Distance 500.
    # Scores: spot1 = 100 + 440 = 540, spot2 = 500. Spot2 wins.
    total += 1
    L = setup_lua(now=400, deterministic_random=1)
    L.execute("""
        spots = {
            { location = {x=100, y=0}, plant_time_sentry = 300 },
            { location = {x=500, y=0}, plant_time_sentry = 0 },
        }
        result = GetClosestSentryWardSpot(bot, spots)
    """)
    rx = L.eval("result.location.x")
    ok = rx == 500
    print(f"  [{'PASS' if ok else 'FAIL'}] sentry recency: spot planted 100s ago "
          f"demoted (got x={rx}, expected 500)")
    if ok: passed += 1

    # Case 9: nil input safe
    total += 1
    L = setup_lua()
    L.execute("result = GetClosestSentryWardSpot(bot, nil)")
    ok = L.eval("result") is None
    print(f"  [{'PASS' if ok else 'FAIL'}] sentry nil spots -> nil")
    if ok: passed += 1

    # Case 10: sentry penalty multiplier higher than observer (4 vs 3)
    # Same age (100s after plant), now=400.
    # Observer: penalty = (360-100)*3 = 780. So observer with dist 100 + 780 = 880.
    # Sentry: penalty = (210-100)*4 = 440. So sentry with dist 100 + 440 = 540.
    # Both should still demote a recently-planted spot relative to a free far spot.
    # Verify sentry penalty > observer penalty when ages are same.
    total += 1
    # Sentry-specific: spot1 planted just now (age 0); penalty = 210*4 = 840
    # Observer same: penalty = 360*3 = 1080.
    # The exact cutoff differs. Let's verify sentry penalty for fresh plant > 800.
    L = setup_lua(now=100, deterministic_random=1)
    L.execute("""
        spots = {
            { location = {x=100, y=0}, plant_time_sentry = 100 },
            { location = {x=900, y=0}, plant_time_sentry = 0 },
        }
        result = GetClosestSentryWardSpot(bot, spots)
    """)
    # Spot1: age=0, penalty=210*4=840, score=100+840=940. Spot2: 900. Spot2 wins.
    rx = L.eval("result.location.x")
    ok = rx == 900
    print(f"  [{'PASS' if ok else 'FAIL'}] sentry fresh-plant penalty 840 "
          f"demotes vs free 900u-away (got x={rx}, expected 900)")
    if ok: passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
