"""Static verification harness for the universal attack-mode hold
hysteresis added to bots/mode_attack_generic.lua.

Verifies:
  - Hold floor (0.7) fires when bot was attacking and target is alive
  - Hold floor releases after ATTACK_HOLD_SEC
  - Dive cap verdict (0.1) takes precedence over hold floor
  - No floor when no target, target dead, target invulnerable, or far away
  - Returns nil when neither rule fires (engine default)
"""

import sys
from lupa import LuaRuntime

GUARD_LUA = r"""
local ATTACK_HOLD_SEC = 1.5
BOT_MODE_ATTACK = 6  -- arbitrary engine constant for tests

-- Mocked bot state set by tests via globals.
function makeBot(activeMode, targetAlive, targetIsBot, targetTeam, targetInv, distToTarget, ownTeam, hp, hpMax)
    return {
        _mode = activeMode,
        _target = (targetAlive ~= nil) and {
            _alive = targetAlive,
            _isNull = targetIsBot == 'null',
            _team = targetTeam,
            _inv = targetInv,
            IsAlive = function(self) return self._alive end,
            IsNull = function(self) return self._isNull end,
            GetTeam = function(self) return self._team end,
            IsInvulnerable = function(self) return self._inv end,
        } or nil,
        _team = ownTeam,
        _dist = distToTarget,
        _hp = hp,
        _hpMax = hpMax,
        GetActiveMode = function(self) return self._mode end,
        GetTarget = function(self) return self._target end,
        GetTeam = function(self) return self._team end,
        GetHealth = function(self) return self._hp end,
        GetMaxHealth = function(self) return self._hpMax end,
    }
end

-- Mock GetUnitToUnitDistance using stamped distance
function GetUnitToUnitDistance(b, t) return b._dist end

local _lastInAttackTime = -100
local _now = 0
function setNow(t) _now = t end
function DotaTime() return _now end

function resetState() _lastInAttackTime = -100 end

-- Mirror of _attackHoldHysteresis in mode_attack_generic.lua
function attackHold(bot, desireFromCap)
    if desireFromCap ~= nil and desireFromCap <= 0.15 then
        return desireFromCap
    end

    local mode = bot:GetActiveMode()
    if mode == BOT_MODE_ATTACK then
        _lastInAttackTime = DotaTime()
    end

    if DotaTime() - _lastInAttackTime < ATTACK_HOLD_SEC then
        local tgt = bot:GetTarget()
        if tgt ~= nil and not tgt:IsNull() and tgt:IsAlive()
            and tgt:GetTeam() ~= bot:GetTeam()
            and not tgt:IsInvulnerable()
            and GetUnitToUnitDistance(bot, tgt) < 1200
        then
            return 0.7
        end
    end

    return desireFromCap
end
"""


def run_eval(L, expr):
    return L.eval(expr)


def main():
    print("=" * 70)
    print("Universal attack-mode hold hysteresis verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(GUARD_LUA)

    cases = []

    def case(desc, fn, expected):
        cases.append((desc, fn, expected))

    # --- Case 1: bot in ATTACK mode, alive enemy 800u away → floor at 0.7 ---
    def c1():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, false, 800, 2, 600, 1000), nil)"
        )
        # Now stamp is set; same tick should return floor
        return L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, false, 800, 2, 600, 1000), nil)"
        )
    case("ATTACK mode + alive enemy 800u → 0.7", c1, 0.7)

    # --- Case 2: stamp expires after 1.5s → return nil ---
    def c2():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, false, 800, 2, 600, 1000), nil)"
        )
        L.execute("setNow(11.6)")  # 1.6s elapsed > 1.5s window
        # No new ATTACK stamp here
        return L.eval(
            "attackHold(makeBot(0, true, false, 3, false, 800, 2, 600, 1000), nil)"
        )
    case("ATTACK 1.6s ago, no longer in ATTACK → nil (use engine default)", c2, None)

    # --- Case 3: dive cap returned 0.1 → preserved (hold doesn't override) ---
    def c3():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, false, 800, 2, 600, 1000), 0.1)"
        )
    case("Dive cap 0.1 + ATTACK + target → 0.1 preserved (no override)", c3, 0.1)

    # --- Case 4: was in ATTACK, but target is dead → no floor ---
    def c4():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, false, false, 3, false, 800, 2, 600, 1000), nil)"
        )
    case("ATTACK + dead target → nil", c4, None)

    # --- Case 5: target same team (e.g. ally somehow targeted) → no floor ---
    def c5():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 2, false, 800, 2, 600, 1000), nil)"
        )
    case("ATTACK + ally team target → nil", c5, None)

    # --- Case 6: target invulnerable → no floor ---
    def c6():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, true, 800, 2, 600, 1000), nil)"
        )
    case("ATTACK + invulnerable target → nil", c6, None)

    # --- Case 7: target far away (1500u > 1200) → no floor ---
    def c7():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, false, 1500, 2, 600, 1000), nil)"
        )
    case("ATTACK + target 1500u away → nil (out of 1200 range)", c7, None)

    # --- Case 8: just within hold window (1.49s) → floor still applies ---
    def c8():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, false, 800, 2, 600, 1000), nil)"
        )
        L.execute("setNow(11.49)")  # 1.49s elapsed, within window
        return L.eval(
            "attackHold(makeBot(0, true, false, 3, false, 800, 2, 600, 1000), nil)"
        )
    case("ATTACK 1.49s ago, target still close → 0.7 (hold active)", c8, 0.7)

    # --- Case 9: not in ATTACK and never was → no floor ---
    def c9():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval(
            "attackHold(makeBot(0, true, false, 3, false, 800, 2, 600, 1000), nil)"
        )
    case("Never in ATTACK + alive target → nil (no hysteresis trigger)", c9, None)

    # --- Case 10: dive cap 0.05 (any value <= 0.15) → preserved ---
    def c10():
        L.execute("resetState()")
        L.execute("setNow(10.0)")
        return L.eval(
            "attackHold(makeBot(BOT_MODE_ATTACK, true, false, 3, false, 800, 2, 600, 1000), 0.05)"
        )
    case("Dive cap 0.05 (suppression range) → 0.05 preserved", c10, 0.05)

    passed = 0
    total = 0
    for desc, fn, expected in cases:
        total += 1
        result = fn()
        # Lua nil maps to Python None
        ok = (result == expected) or (
            isinstance(result, float)
            and isinstance(expected, float)
            and abs(result - expected) < 0.001
        )
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result} (expected {expected})")
        if ok:
            passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
