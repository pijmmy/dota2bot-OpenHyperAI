"""Static verification harness for the team_roam engage-gate override
on team-plan commit, in bots/mode_team_roam_generic.lua.

Verifies:
  - Engage gate respects original ally>=enemy parity by default
  - When team plan = commit_kill (within validUntil window), gate is forced true
  - When team plan = lane_gank, gate is forced true
  - When team plan = smoke_gank, gate is forced true
  - When validUntil is in the past, override does NOT apply
  - Other plan intents (defend_base, push_lane, farm) do NOT override
"""

import sys
from lupa import LuaRuntime

LUA = r"""
local _now = 0
function setNow(t) _now = t end
function DotaTime() return _now end

J = { TeamPlan = {} }
local _currentPlan = nil
function J.TeamPlan.GetCurrentPlan()
    return _currentPlan
end

function setPlan(intent, validUntil)
    _currentPlan = { intent = intent, validUntil = validUntil }
end
function clearPlan() _currentPlan = nil end

-- Mock StickyGate that just returns the fresh value.
J.Hysteresis = {
    StickyGate = function(_, _, fresh, _) return fresh end,
}

function computeEngageGate(allies, enemies)
    local _engageGateFresh = (allies >= enemies)
    local _engageGateHeld = _engageGateFresh
    if J.Hysteresis and J.Hysteresis.StickyGate then
        _engageGateHeld = J.Hysteresis.StickyGate(0, "team_roam_engage", _engageGateFresh, 1.5)
    end

    if J.TeamPlan and J.TeamPlan.GetCurrentPlan then
        local plan = J.TeamPlan.GetCurrentPlan()
        if plan ~= nil and plan.intent ~= nil
            and (plan.intent == 'commit_kill' or plan.intent == 'lane_gank' or plan.intent == 'smoke_gank')
            and plan.validUntil ~= nil and DotaTime() < plan.validUntil
        then
            _engageGateHeld = true
        end
    end

    return _engageGateHeld
end
"""


def main():
    print("=" * 70)
    print("team_roam engage-gate plan override verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # 1) No plan, allies >= enemies → engage true
    def c1():
        L.execute("clearPlan()")
        L.execute("setNow(60.0)")
        return L.eval("computeEngageGate(3, 2)")
    case("No plan, 3 allies vs 2 enemies → engage", c1, True)

    # 2) No plan, allies < enemies → engage false (passive)
    def c2():
        L.execute("clearPlan()")
        L.execute("setNow(60.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("No plan, 2 allies vs 3 enemies → don't engage (passive)", c2, False)

    # 3) commit_kill plan + parity disadvantage → engage anyway
    def c3():
        L.execute("setNow(60.0)")
        L.execute("setPlan('commit_kill', 75.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("commit_kill plan active + parity unfavorable → engage forced", c3, True)

    # 4) lane_gank plan + parity unfavorable → engage anyway
    def c4():
        L.execute("setNow(60.0)")
        L.execute("setPlan('lane_gank', 75.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("lane_gank plan active + parity unfavorable → engage forced", c4, True)

    # 5) smoke_gank plan + parity unfavorable → engage anyway
    def c5():
        L.execute("setNow(60.0)")
        L.execute("setPlan('smoke_gank', 75.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("smoke_gank plan active + parity unfavorable → engage forced", c5, True)

    # 6) commit_kill plan EXPIRED (validUntil < now) → no override
    def c6():
        L.execute("setNow(80.0)")
        L.execute("setPlan('commit_kill', 75.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("commit_kill plan expired (now=80, validUntil=75) → no override", c6, False)

    # 7) defend_base plan + parity unfavorable → no engage override
    def c7():
        L.execute("setNow(60.0)")
        L.execute("setPlan('defend_base', 75.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("defend_base plan + parity unfavorable → don't engage", c7, False)

    # 8) push_lane plan + parity unfavorable → no engage override
    def c8():
        L.execute("setNow(60.0)")
        L.execute("setPlan('push_lane', 75.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("push_lane plan + parity unfavorable → don't engage", c8, False)

    # 9) farm plan + parity unfavorable → no engage override
    def c9():
        L.execute("setNow(60.0)")
        L.execute("setPlan('farm', 75.0)")
        return L.eval("computeEngageGate(2, 3)")
    case("farm plan + parity unfavorable → don't engage", c9, False)

    # 10) commit_kill, parity favorable → engage (gate would have been true anyway)
    def c10():
        L.execute("setNow(60.0)")
        L.execute("setPlan('commit_kill', 75.0)")
        return L.eval("computeEngageGate(4, 2)")
    case("commit_kill plan + parity favorable → engage", c10, True)

    # 11) commit_kill plan with nil validUntil → no override (defensive)
    def c11():
        L.execute("setNow(60.0)")
        L.execute("setPlan('commit_kill', nil)")
        return L.eval("computeEngageGate(2, 3)")
    case("commit_kill plan with nil validUntil → no override", c11, False)

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
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
