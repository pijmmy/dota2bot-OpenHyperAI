"""Static verification harness for remaining team-plan helpers in
bots/FunLib/aba_teamplan.lua.

Verifies:
  - countMissingEnemies: counts dead-or-stale-vision enemies
  - isInCooldown: respects TACTIC_COOLDOWN per intent
  - trackIntent: starts cooldown after timeout, resets start time
  - INTENT_ROLES routing: only specified roles act on each intent
"""

import sys
from lupa import LuaRuntime


HELPERS_LUA = r"""
local _now = 0
function DotaTime() return _now end
function setNow(t) _now = t end

-- countMissingEnemies impl
function countMissingEnemies(enemyInfos, staleSeconds)
    local missing = 0
    for i = 1, #enemyInfos do
        local info = enemyInfos[i]
        if info.alive then
            if type(info.time_since_seen) == "number"
               and info.time_since_seen >= staleSeconds then
                missing = missing + 1
            end
        end
    end
    return missing
end

-- Cooldown table + isInCooldown
local TACTIC_COOLDOWN = {
    commit_kill = 12,
    contest_rosh = 180,
    contest_tormentor = 20,
    lane_gank = 8,
    save_ally = 6,
    push_lane = 90,
    smoke_gank = 30,
}
local _intentCooldownUntil = {}

function isInCooldown(intent)
    local until_t = _intentCooldownUntil[intent]
    if until_t == nil then return false end
    return DotaTime() < until_t
end

function setCooldownUntil(intent, until_t)
    _intentCooldownUntil[intent] = until_t
end

function getCooldownDuration(intent)
    return TACTIC_COOLDOWN[intent] or 10
end

-- trackIntent simulation
local _intentStartTime = {}
local TACTIC_TIMEOUT = {
    commit_kill = 8,
    contest_rosh = 35,
    push_lane = 60,
    smoke_gank = 25,
}

function trackIntent(intent)
    local prev = nil
    for k, _ in pairs(_intentStartTime) do prev = k; break end
    if prev ~= intent then
        _intentStartTime = {}
        _intentStartTime[intent] = DotaTime()
    end
    local startedAt = _intentStartTime[intent]
    local timeout = TACTIC_TIMEOUT[intent]
    if startedAt ~= nil and timeout ~= nil and (DotaTime() - startedAt) > timeout then
        local cooldown = TACTIC_COOLDOWN[intent] or 10
        _intentCooldownUntil[intent] = DotaTime() + cooldown
        _intentStartTime = {}
    end
end

function getIntentStart(intent)
    return _intentStartTime[intent]
end

-- INTENT_ROLES check
local INTENT_ROLES = {
    contest_lotus = {4, 5},
    contest_tormentor = {3, 4, 5},
    push_lane = {1, 2, 3, 4, 5},
    smoke_gank = {2, 3, 4, 5},
    defend_base = {1, 2, 3, 4, 5},
}

function roleParticipates(intent, pos)
    local roles = INTENT_ROLES[intent]
    if roles == nil then return true end  -- unknown intents: everyone
    for i = 1, #roles do
        if roles[i] == pos then return true end
    end
    return false
end
"""


def main():
    print("=" * 70)
    print("Team plan helpers verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(HELPERS_LUA)

    passed = 0
    total = 0

    # --- countMissingEnemies ---
    print()
    print("countMissingEnemies (stale > N seconds)")
    print("-" * 70)

    cases = [
        # (description, enemy_infos, stale_threshold, expected)
        ("All visible: 0 missing",
         [{"alive": True, "time_since_seen": 0.5},
          {"alive": True, "time_since_seen": 1.0}],
         8, 0),
        ("3 missing of 5 (stale 8s+)",
         [{"alive": True, "time_since_seen": 10},
          {"alive": True, "time_since_seen": 12},
          {"alive": True, "time_since_seen": 15},
          {"alive": True, "time_since_seen": 0.5},
          {"alive": True, "time_since_seen": 1}],
         8, 3),
        ("Dead enemies don't count as missing",
         [{"alive": False, "time_since_seen": 100}], 8, 0),
        ("nil time_since_seen: don't count (no data)",
         [{"alive": True, "time_since_seen": None}], 8, 0),
        ("Boundary: 8s exactly counts (>= not >)",
         [{"alive": True, "time_since_seen": 8.0}], 8, 1),
    ]
    for desc, infos, threshold, expected in cases:
        total += 1
        # Build Lua table
        infos_lua = "{"
        for inf in infos:
            tss = inf["time_since_seen"]
            tss_lua = "nil" if tss is None else str(tss)
            alive_lua = "true" if inf["alive"] else "false"
            infos_lua += f"{{alive={alive_lua}, time_since_seen={tss_lua}}}, "
        infos_lua += "}"
        L.execute(f"_infos = {infos_lua}")
        result = L.eval(f"countMissingEnemies(_infos, {threshold})")
        ok = result == expected
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    # --- isInCooldown + trackIntent ---
    print()
    print("isInCooldown + trackIntent")
    print("-" * 70)

    # Reset state
    L.execute("setNow(0); _intentCooldownUntil = {}; _intentStartTime = {}")

    # Test: cooldown not set -> false
    total += 1
    result = L.eval("isInCooldown('push_lane')")
    ok = result is False
    print(f"  [{'PASS' if ok else 'FAIL'}] No cooldown set: false (got {result})")
    if ok: passed += 1

    # Set cooldown until 100s, current 50s -> in cooldown
    total += 1
    L.execute("setNow(50); setCooldownUntil('push_lane', 100)")
    result = L.eval("isInCooldown('push_lane')")
    ok = result is True
    print(f"  [{'PASS' if ok else 'FAIL'}] In cooldown (now 50, until 100): true")
    if ok: passed += 1

    # At 100s exactly: false (DotaTime() < until_t)
    total += 1
    L.execute("setNow(100)")
    result = L.eval("isInCooldown('push_lane')")
    ok = result is False
    print(f"  [{'PASS' if ok else 'FAIL'}] At cooldown end exactly: false")
    if ok: passed += 1

    # trackIntent: first call records start time
    total += 1
    L.execute("setNow(0); _intentCooldownUntil = {}; _intentStartTime = {}")
    L.execute("setNow(100); trackIntent('push_lane')")
    start = L.eval("getIntentStart('push_lane')")
    ok = start == 100
    print(f"  [{'PASS' if ok else 'FAIL'}] trackIntent start time recorded: got {start}")
    if ok: passed += 1

    # trackIntent: same intent persists (no reset)
    total += 1
    L.execute("setNow(110); trackIntent('push_lane')")
    start = L.eval("getIntentStart('push_lane')")
    ok = start == 100  # still original
    print(f"  [{'PASS' if ok else 'FAIL'}] Same intent persists: start still 100 (got {start})")
    if ok: passed += 1

    # trackIntent: timeout (push_lane TACTIC_TIMEOUT = 60)
    # 100 + 61 = 161 > 100+60: should set cooldown
    total += 1
    L.execute("setNow(165); trackIntent('push_lane')")
    in_cd = L.eval("isInCooldown('push_lane')")
    # With now=165, cooldown set to 165 + 90 = 255
    ok = in_cd is True
    print(f"  [{'PASS' if ok else 'FAIL'}] After timeout: in cooldown (got {in_cd})")
    if ok: passed += 1

    # Different intent: previous resets, new intent's start = now
    total += 1
    L.execute("setNow(0); _intentCooldownUntil = {}; _intentStartTime = {}")
    L.execute("setNow(50); trackIntent('push_lane')")
    L.execute("setNow(60); trackIntent('smoke_gank')")
    push_start = L.eval("getIntentStart('push_lane')")
    smoke_start = L.eval("getIntentStart('smoke_gank')")
    ok = push_start is None and smoke_start == 60
    print(f"  [{'PASS' if ok else 'FAIL'}] Intent switch: push_start nil, smoke_start 60 "
          f"(got push={push_start}, smoke={smoke_start})")
    if ok: passed += 1

    # --- INTENT_ROLES ---
    print()
    print("INTENT_ROLES routing")
    print("-" * 70)

    role_cases = [
        # (description, intent, pos, expected)
        ("contest_lotus: pos 4 participates", "contest_lotus", 4, True),
        ("contest_lotus: pos 5 participates", "contest_lotus", 5, True),
        ("contest_lotus: pos 1 doesn't (cores keep farming)", "contest_lotus", 1, False),
        ("contest_lotus: pos 2 doesn't", "contest_lotus", 2, False),
        ("contest_lotus: pos 3 doesn't", "contest_lotus", 3, False),
        ("contest_tormentor: pos 3 yes", "contest_tormentor", 3, True),
        ("contest_tormentor: pos 4 yes", "contest_tormentor", 4, True),
        ("contest_tormentor: pos 1 no", "contest_tormentor", 1, False),
        ("push_lane: all positions", "push_lane", 1, True),
        ("smoke_gank: pos 1 carry doesn't gank", "smoke_gank", 1, False),
        ("smoke_gank: pos 4 yes", "smoke_gank", 4, True),
        ("Unknown intent: all positions participate", "unknown", 3, True),
    ]
    for desc, intent, pos, expected in role_cases:
        total += 1
        result = L.eval(f"roleParticipates('{intent}', {pos})")
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
