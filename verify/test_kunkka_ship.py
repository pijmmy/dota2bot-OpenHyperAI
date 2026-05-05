"""Static verification harness for the Ghost Ship extrapolation fix in
bots/BotLib/hero_kunkka.lua.

Verifies:
  - _kunkkaShipImpactLoc extrapolates by ~0.55 * (dist/650)
  - Travel time is clamped to [0.4, 2.0] seconds
  - For a stationary target, impact = current location
  - For a target moving at 315 m/s perpendicular, the impact point is
    offset along the movement vector by the predicted travel-time delta
"""

import sys
from lupa import LuaRuntime

GHOST_SHIP_LUA = r"""
local GHOST_SHIP_SPEED = 650

-- Mock GetUnitToUnitDistance: returns the stamped distance from whichever
-- unit has _dist set (the bot in our test setup).
function GetUnitToUnitDistance(b1, b2)
    if b1 ~= nil and b1._dist ~= nil then return b1._dist end
    if b2 ~= nil and b2._dist ~= nil then return b2._dist end
    return 0
end

-- Mock target with extrapolation. Movement vector applied per second.
function makeTarget(x, y, vx, vy)
    local t = { _x = x, _y = y, _vx = vx, _vy = vy, _isNull = false }
    function t:GetLocation() return { x = self._x, y = self._y } end
    function t:IsNull() return self._isNull end
    function t:GetExtrapolatedLocation(dt)
        return { x = self._x + self._vx * dt, y = self._y + self._vy * dt }
    end
    return t
end

-- Mock J helper used inside _kunkkaShipImpactLoc.
J = { IsValidHero = function(h) return h ~= nil and not h:IsNull() end }

-- Bot with stamped distance to target.
function makeBot(distToTarget)
    return { _dist = distToTarget }
end

bot = makeBot(0)

local function _kunkkaShipImpactLoc( npcTarget )
    if not J.IsValidHero( npcTarget ) then return npcTarget:GetLocation() end
    local dist = GetUnitToUnitDistance( npcTarget, bot )
    local travelTime = math.min( 2.0, math.max( 0.4, dist / GHOST_SHIP_SPEED ) )
    return npcTarget:GetExtrapolatedLocation( travelTime * 0.55 )
end

-- Public test helpers
function impactFor(distToTarget, x, y, vx, vy)
    bot._dist = distToTarget
    local tgt = makeTarget(x, y, vx, vy)
    local loc = _kunkkaShipImpactLoc(tgt)
    return loc.x, loc.y
end
"""


def main():
    print("=" * 70)
    print("Kunkka Ghost Ship extrapolation verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(GHOST_SHIP_LUA)

    # Helper: normalized travel time used by the function
    def travel_time(dist):
        t = dist / 650.0
        if t < 0.4:
            t = 0.4
        if t > 2.0:
            t = 2.0
        return t * 0.55

    cases = []

    # 1) Stationary target at origin, distance 1000 → travel_time = 0.55 *
    #    (1000/650) = 0.846, expected impact = (0, 0).
    def c1():
        return L.eval("impactFor(1000, 0, 0, 0, 0)")
    cases.append(("Stationary target at origin, dist 1000 → (0,0)", c1, (0.0, 0.0)))

    # 2) Target moving 315 perp at distance 1000.
    def c2():
        return L.eval("impactFor(1000, 0, 0, 315, 0)")
    expected_x = 315 * travel_time(1000)
    cases.append(
        (
            f"Target moving 315 m/s, dist 1000 → impact x ~ {expected_x:.1f}",
            c2,
            (expected_x, 0.0),
        )
    )

    # 3) Target very close (300u) — travel time floor 0.4s applies.
    def c3():
        return L.eval("impactFor(300, 0, 0, 315, 0)")
    expected_x = 315 * travel_time(300)
    cases.append(
        (
            f"Close target (dist 300), floored travel time → impact x ~ {expected_x:.1f}",
            c3,
            (expected_x, 0.0),
        )
    )

    # 4) Target far (2000u) — travel time clamped at 2s ceiling.
    def c4():
        return L.eval("impactFor(2000, 0, 0, 315, 0)")
    expected_x = 315 * travel_time(2000)
    cases.append(
        (
            f"Far target (dist 2000), clamped travel time → impact x ~ {expected_x:.1f}",
            c4,
            (expected_x, 0.0),
        )
    )

    # 5) Target moving negative direction → impact below original y
    def c5():
        return L.eval("impactFor(1000, 100, 100, 0, -315)")
    expected_y = 100 + (-315) * travel_time(1000)
    cases.append(
        (
            f"Target moving -315 in y, start (100,100) → impact y ~ {expected_y:.1f}",
            c5,
            (100.0, expected_y),
        )
    )

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
        # Lua returns 2-tuple for (x, y)
        result_x, result_y = result
        exp_x, exp_y = expected
        ok = abs(result_x - exp_x) < 0.5 and abs(result_y - exp_y) < 0.5
        status = "PASS" if ok else "FAIL"
        print(
            f"  [{status}] {desc}: got ({result_x:.2f}, {result_y:.2f}), "
            f"expected ({exp_x:.2f}, {exp_y:.2f})"
        )
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
