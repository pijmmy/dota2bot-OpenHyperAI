"""Static verification harness for the unified hysteresis utility in
bots/FunLib/aba_hysteresis.lua.

Verifies the three primitives:
  StickyTarget — 1.5s lock + 1.5x upgrade override
  StickyGate   — boolean state with hold window
  StickyDesire — EMA smoothing
"""

import sys
from lupa import LuaRuntime


HYSTERESIS_LUA = r"""
local _now = 0
function DotaTime() return _now end
function setNow(t) _now = t end

-- Inlined production logic (mirrors bots/FunLib/aba_hysteresis.lua).
local _stickyTargets = {}
local _stickyGates = {}
local _stickyDesires = {}

function reset()
    _stickyTargets = {}
    _stickyGates = {}
    _stickyDesires = {}
end

local function isUnitValid(u)
    if u == nil then return false end
    if u.isNull then return false end
    if not u.alive then return false end
    return true
end

function StickyTarget(pid, freshTarget, freshScore, lockSec, upgradeMul, domain)
    lockSec = lockSec or 1.5
    upgradeMul = upgradeMul or 1.5
    domain = domain or "default"
    local key = tostring(pid) .. ":" .. domain
    local cached = _stickyTargets[key]
    local now = DotaTime()
    local cachedValid = cached ~= nil
        and cached.unit ~= nil
        and isUnitValid(cached.unit)
    local picked = freshTarget
    local pickedScore = freshScore or 0
    if cachedValid and (now - cached.lockedAt) < lockSec then
        if freshTarget == nil or (freshScore or 0) < cached.score * upgradeMul then
            picked = cached.unit
            pickedScore = cached.score
        end
    end
    if picked ~= nil then
        local sameAsCached = cachedValid and cached.unit == picked
        _stickyTargets[key] = {
            unit = picked,
            score = pickedScore,
            lockedAt = sameAsCached and cached.lockedAt or now,
        }
    end
    if picked == nil then return nil, 0 end
    return picked.id, pickedScore
end

function killUnit(unit)
    if unit then unit.alive = false end
end

function StickyGate(pid, gateName, fresh, holdSec)
    holdSec = holdSec or 1.5
    local key = tostring(pid) .. ":" .. gateName
    local cached = _stickyGates[key]
    local now = DotaTime()
    if cached == nil then
        _stickyGates[key] = { state = fresh, lastChange = now }
        return fresh
    end
    if cached.state ~= fresh then
        if (now - cached.lastChange) < holdSec then
            return cached.state
        end
        _stickyGates[key] = { state = fresh, lastChange = now }
        return fresh
    end
    return cached.state
end

function StickyDesire(pid, modeTag, fresh, alpha)
    alpha = alpha or 0.30
    local key = tostring(pid) .. ":" .. modeTag
    local cached = _stickyDesires[key]
    if cached == nil then
        _stickyDesires[key] = fresh
        return fresh
    end
    local smoothed = cached * (1 - alpha) + (fresh or 0) * alpha
    _stickyDesires[key] = smoothed
    return smoothed
end

function makeUnit(id)
    return { id = id, alive = true, isNull = false }
end
"""


def main():
    print("=" * 70)
    print("Hysteresis utility verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(HYSTERESIS_LUA)

    passed = 0
    total = 0

    # --- StickyTarget ---
    print()
    print("StickyTarget")
    print("-" * 70)

    cases = [
        ("First pick locks", lambda: (
            L.execute("reset(); setNow(0); u_a = makeUnit('A')"),
            L.eval("StickyTarget(1, u_a, 100, 1.5, 1.5, 'attack')"),
        )[1] == ("A", 100)),
        ("Within window, B=110 (1.10x): keep A", lambda: (
            L.execute("reset(); setNow(0); u_a = makeUnit('A'); u_b = makeUnit('B')"),
            L.eval("StickyTarget(1, u_a, 100, 1.5, 1.5, 'attack')"),
            L.execute("setNow(0.5)"),
            L.eval("StickyTarget(1, u_b, 110, 1.5, 1.5, 'attack')"),
        )[3] == ("A", 100)),
        ("Within window, B=151 (1.51x > 1.5x): switch to B", lambda: (
            L.execute("reset(); setNow(0); u_a = makeUnit('A'); u_b = makeUnit('B')"),
            L.eval("StickyTarget(1, u_a, 100, 1.5, 1.5, 'attack')"),
            L.execute("setNow(0.5)"),
            L.eval("StickyTarget(1, u_b, 151, 1.5, 1.5, 'attack')"),
        )[3] == ("B", 151)),
        ("Lock expired: free re-pick", lambda: (
            L.execute("reset(); setNow(0); u_a = makeUnit('A'); u_b = makeUnit('B')"),
            L.eval("StickyTarget(1, u_a, 100, 1.5, 1.5, 'attack')"),
            L.execute("setNow(2.0)"),
            L.eval("StickyTarget(1, u_b, 50, 1.5, 1.5, 'attack')"),
        )[3] == ("B", 50)),
        ("Cached unit died: switch", lambda: (
            L.execute("reset(); setNow(0); u_a = makeUnit('A'); u_b = makeUnit('B')"),
            L.eval("StickyTarget(1, u_a, 100, 1.5, 1.5, 'attack')"),
            L.execute("killUnit(u_a)"),
            L.execute("setNow(0.5)"),
            L.eval("StickyTarget(1, u_b, 50, 1.5, 1.5, 'attack')"),
        )[4] == ("B", 50)),
        ("Domain isolation: attack=A, defend=B don't bleed", lambda: (
            L.execute("reset(); setNow(0); u_a = makeUnit('A'); u_b = makeUnit('B')"),
            L.eval("StickyTarget(1, u_a, 100, 1.5, 1.5, 'attack')"),
            L.eval("StickyTarget(1, u_b, 100, 1.5, 1.5, 'defend')"),
            L.execute("setNow(0.5)"),
            # Within both windows, fresh=B (low score) into attack -> A still wins.
            # Within both windows, fresh=A (low score) into defend -> B still wins.
            L.eval("StickyTarget(1, u_b, 50, 1.5, 1.5, 'attack')"),
            L.eval("StickyTarget(1, u_a, 50, 1.5, 1.5, 'defend')"),
        )[4] == ("A", 100)
            and L.eval("StickyTarget(1, u_a, 50, 1.5, 1.5, 'defend')") == ("B", 100)),
    ]
    for desc, fn in cases:
        total += 1
        ok = fn()
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}")
        if ok:
            passed += 1

    # --- StickyGate ---
    print()
    print("StickyGate")
    print("-" * 70)

    L.execute("reset(); setNow(0)")
    total += 1
    ok = L.eval("StickyGate(1, 'engage', true, 1.5)") is True
    print(f"  [{'PASS' if ok else 'FAIL'}] First call: returns fresh value (true)")
    if ok: passed += 1

    L.execute("setNow(0.5)")
    total += 1
    ok = L.eval("StickyGate(1, 'engage', false, 1.5)") is True
    print(f"  [{'PASS' if ok else 'FAIL'}] Within hold window, fresh=false: hold true")
    if ok: passed += 1

    L.execute("setNow(2.0)")
    total += 1
    ok = L.eval("StickyGate(1, 'engage', false, 1.5)") is False
    print(f"  [{'PASS' if ok else 'FAIL'}] Hold window expired, fresh=false: flip to false")
    if ok: passed += 1

    # Same gate, fresh stays the same: just returns it
    L.execute("setNow(2.5)")
    total += 1
    ok = L.eval("StickyGate(1, 'engage', false, 1.5)") is False
    print(f"  [{'PASS' if ok else 'FAIL'}] Stable state passes through (no change to track)")
    if ok: passed += 1

    # Per-bot isolation
    L.execute("reset(); setNow(0)")
    L.eval("StickyGate(1, 'engage', true, 1.5)")
    L.eval("StickyGate(2, 'engage', false, 1.5)")
    total += 1
    a = L.eval("StickyGate(1, 'engage', false, 0.5)")
    L.execute("setNow(0.1)")  # under both windows
    b = L.eval("StickyGate(2, 'engage', true, 0.5)")
    ok = a is True and b is False
    print(f"  [{'PASS' if ok else 'FAIL'}] Per-bot isolation: bot 1 = true, bot 2 = false (both holding)")
    if ok: passed += 1

    # --- StickyDesire ---
    print()
    print("StickyDesire (EMA smoothing)")
    print("-" * 70)

    L.execute("reset()")
    total += 1
    ok = abs(L.eval("StickyDesire(1, 'retreat', 1.0, 0.30)") - 1.0) < 0.001
    print(f"  [{'PASS' if ok else 'FAIL'}] First call: returns fresh (1.0)")
    if ok: passed += 1

    # Spike to 0: smoothed = 1.0 * 0.7 + 0 * 0.3 = 0.7
    total += 1
    smoothed = L.eval("StickyDesire(1, 'retreat', 0.0, 0.30)")
    ok = abs(smoothed - 0.7) < 0.001
    print(f"  [{'PASS' if ok else 'FAIL'}] After spike to 0 (alpha=0.30): smoothed = 0.7 (got {smoothed:.3f})")
    if ok: passed += 1

    # Spike back to 1: smoothed = 0.7 * 0.7 + 1.0 * 0.3 = 0.49 + 0.30 = 0.79
    total += 1
    smoothed = L.eval("StickyDesire(1, 'retreat', 1.0, 0.30)")
    ok = abs(smoothed - 0.79) < 0.001
    print(f"  [{'PASS' if ok else 'FAIL'}] Spike back to 1.0: smoothed = 0.79 (got {smoothed:.3f})")
    if ok: passed += 1

    # Stable: convergence
    L.execute("reset()")
    L.eval("StickyDesire(1, 'retreat', 0.5, 0.30)")
    for _ in range(20):
        L.eval("StickyDesire(1, 'retreat', 0.5, 0.30)")
    total += 1
    ok = abs(L.eval("StickyDesire(1, 'retreat', 0.5, 0.30)") - 0.5) < 0.001
    print(f"  [{'PASS' if ok else 'FAIL'}] Convergence: stable input -> stable output")
    if ok: passed += 1

    # Different alpha = different smoothing
    L.execute("reset()")
    L.eval("StickyDesire(1, 'retreat', 1.0, 0.10)")  # heavier smoothing
    total += 1
    smoothed = L.eval("StickyDesire(1, 'retreat', 0.0, 0.10)")
    ok = abs(smoothed - 0.9) < 0.001  # 1.0 * 0.9 + 0 * 0.1 = 0.9
    print(f"  [{'PASS' if ok else 'FAIL'}] alpha=0.10: 1->0 smooths to 0.9 (got {smoothed:.3f})")
    if ok: passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
