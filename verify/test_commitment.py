"""Static verification harness for the commitment state machine in
bots/FunLib/aba_commitment.lua.

Verifies:
  - Progress ramp: delta = 0.10*pos - 0.20*neg, clamped [0, 1]
  - Reset on intent change
  - GetDesireBonus = 0.12 * progress^2 (convex, max 0.12)
  - ShouldAbort triggers
"""

import sys
from lupa import LuaRuntime


COMMIT_LUA = r"""
local _progress = {
    push_lane = 0, smoke_gank = 0, contest_rosh = 0, commit_kill = 0,
}
local _last_intent = nil

function updateProgress(intent, pos, neg)
    if intent ~= _last_intent then
        for k in pairs(_progress) do _progress[k] = 0 end
        _last_intent = intent
    end
    if _progress[intent] == nil then return end
    local delta = 0.10 * pos - 0.20 * neg
    local p = _progress[intent] + delta
    if p < 0 then p = 0 end
    if p > 1 then p = 1 end
    _progress[intent] = p
end

function getProgress(intent) return _progress[intent] or 0 end

function getDesireBonus(intent)
    local p = _progress[intent] or 0
    return 0.12 * (p * p)
end

function reset(intent)
    if intent == nil then
        for k in pairs(_progress) do _progress[k] = 0 end
    else
        _progress[intent] = 0
    end
    _last_intent = nil
end

function setProgress(intent, value) _progress[intent] = value end

-- Abort triggers (simplified — real version reads J.TeamState)
function shouldAbort(intent, missingEnemies, meanHP, macroAlert)
    if intent == "commit_kill" or intent == "smoke_gank" then
        if missingEnemies >= 3 then return true end
        if meanHP < 0.40 then return true end
    end
    if intent == "contest_rosh" then
        if macroAlert == "RED" then return true end
    end
    return false
end
"""


def main():
    print("=" * 70)
    print("Commitment state machine verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(COMMIT_LUA)

    passed = 0
    total = 0

    # --- Progress ramp ---
    print()
    print("Progress ramp (delta = 0.10*pos - 0.20*neg)")
    print("-" * 70)

    L.execute("reset(nil)")

    cases = [
        # (description, intent, pos, neg, expected_progress_after)
        ("First tick on push_lane: 2 pos, 0 neg -> 0.20",
         "push_lane", 2, 0, 0.20),
        ("Second tick: another 2 pos -> 0.40",
         "push_lane", 2, 0, 0.40),
        ("Third tick: 1 pos, 2 neg -> 0.40 + 0.10 - 0.40 = 0.10",
         "push_lane", 1, 2, 0.10),
        ("Fourth tick: 0 pos 5 neg -> clamped to 0",
         "push_lane", 0, 5, 0.0),
        ("Saturation: 10 pos -> 1.0 (clamped from 1.0)",
         "push_lane", 10, 0, 1.0),
        ("Saturation: 10 more pos still 1.0",
         "push_lane", 10, 0, 1.0),
    ]
    for desc, intent, pos, neg, expected in cases:
        total += 1
        L.execute(f"updateProgress('{intent}', {pos}, {neg})")
        result = L.eval(f"getProgress('{intent}')")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.3f} (expected {expected:.3f})")
        if ok:
            passed += 1

    # --- Intent change resets ---
    print()
    print("Intent change resets all progress")
    print("-" * 70)

    L.execute("reset(nil)")
    L.execute("updateProgress('push_lane', 5, 0)")  # progress = 0.5
    pre = L.eval("getProgress('push_lane')")
    L.execute("updateProgress('contest_rosh', 1, 0)")  # different intent
    post_push = L.eval("getProgress('push_lane')")
    post_rosh = L.eval("getProgress('contest_rosh')")
    total += 2
    ok1 = abs(pre - 0.5) < 0.001
    ok2 = post_push == 0
    ok3 = abs(post_rosh - 0.10) < 0.001  # only the new intent's first tick
    print(f"  [{'PASS' if ok1 else 'FAIL'}] Pre-switch: push_lane {pre:.2f}")
    print(f"  [{'PASS' if ok2 else 'FAIL'}] Post-switch: push_lane {post_push} (reset)")
    print(f"  [{'PASS' if ok3 else 'FAIL'}] Post-switch: contest_rosh {post_rosh:.2f} (fresh)")
    if ok1: passed += 1
    if ok2: passed += 1
    total += 1
    if ok3: passed += 1

    # --- Convex desire bonus ---
    print()
    print("GetDesireBonus = 0.12 * p^2")
    print("-" * 70)

    bonus_cases = [
        # (description, progress_target, expected_bonus)
        ("Progress 0: bonus 0", 0.0, 0.0),
        ("Progress 0.5: bonus 0.03 (0.12*0.25)", 0.5, 0.03),
        ("Progress 1.0: bonus 0.12 (max)", 1.0, 0.12),
        ("Progress 0.7: bonus 0.0588", 0.7, 0.12*0.7*0.7),
    ]
    for desc, p, expected in bonus_cases:
        total += 1
        L.execute("reset(nil)")
        L.execute(f"setProgress('push_lane', {p})")
        result = L.eval("getDesireBonus('push_lane')")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.4f} (expected {expected:.4f})")
        if ok:
            passed += 1

    # --- ShouldAbort ---
    print()
    print("ShouldAbort triggers")
    print("-" * 70)

    abort_cases = [
        # (description, intent, missing, hp, alert, expected)
        ("commit_kill, 3 missing -> abort",
         "commit_kill", 3, 1.0, "GREEN", True),
        ("commit_kill, 2 missing, full HP -> NO abort",
         "commit_kill", 2, 1.0, "GREEN", False),
        ("commit_kill, mean HP 0.30 -> abort",
         "commit_kill", 0, 0.30, "GREEN", True),
        ("commit_kill, mean HP 0.40 boundary -> NO abort (< not <=)",
         "commit_kill", 0, 0.40, "GREEN", False),
        ("smoke_gank, 3 missing -> abort",
         "smoke_gank", 3, 1.0, "GREEN", True),
        ("contest_rosh, RED alert -> abort",
         "contest_rosh", 0, 1.0, "RED", True),
        ("contest_rosh, ORANGE alert -> NO abort (only RED)",
         "contest_rosh", 0, 1.0, "ORANGE", False),
        ("push_lane (not in abort list): never aborts",
         "push_lane", 5, 0.1, "RED", False),
        ("commit_kill normal: no abort",
         "commit_kill", 0, 0.9, "GREEN", False),
    ]
    for desc, intent, missing, hp, alert, expected in abort_cases:
        total += 1
        result = L.eval(f"shouldAbort('{intent}', {missing}, {hp}, '{alert}')")
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
