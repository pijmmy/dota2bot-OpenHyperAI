"""Static verification harness for the personality multiplier chain in
bots/FunLib/aba_personality.lua.

Verifies:
  - computeMultiplier: trait-driven mode-specific multipliers
    (lerp from atZero to atOne by trait value)
  - applyRoleScale: pos 1/2 carries farm more, pos 4/5 less; roam
    biased to supports
  - GetEffective tilt math: aggression+, greed-, risk+, indep+, teamSpirit-
"""

import sys
from lupa import LuaRuntime


PERS_LUA = r"""
local MODE_MODIFIERS = {
    farm = {
        { trait = "greed", atZero = 0.70, atOne = 1.35 },
        { trait = "teamSpirit", atZero = 1.1, atOne = 0.85 },
    },
    roam = {
        { trait = "aggression", atZero = 0.55, atOne = 1.40 },
        { trait = "greed", atZero = 1.1, atOne = 0.8 },
        { trait = "independence", atZero = 0.85, atOne = 1.15 },
    },
    team_roam = {
        { trait = "aggression", atZero = 0.65, atOne = 1.30 },
        { trait = "teamSpirit", atZero = 0.55, atOne = 1.3 },
        { trait = "independence", atZero = 1.2, atOne = 0.7 },
    },
    push = {
        { trait = "aggression", atZero = 0.8, atOne = 1.2 },
        { trait = "independence", atZero = 0.85, atOne = 1.25 },
    },
    defend = {
        { trait = "teamSpirit", atZero = 0.7, atOne = 1.3 },
        { trait = "risk", atZero = 1.15, atOne = 0.9 },
    },
    retreat = {
        { trait = "risk", atZero = 1.3, atOne = 0.7 },
    },
}

local FARM_ROLE_SCALE = {
    [1] = 1.35, [2] = 1.20, [3] = 0.90, [4] = 0.45, [5] = 0.40,
}
local ROAM_ROLE_SCALE = {
    [1] = 0.85, [2] = 1.15, [3] = 1.00, [4] = 1.30, [5] = 1.20,
}

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

function computeMultiplier(mode, p)
    local mods = MODE_MODIFIERS[mode]
    if mods == nil then return 1.0 end
    local mult = 1.0
    for i = 1, #mods do
        local m = mods[i]
        local traitValue = p[m.trait]
        if type(traitValue) == "number" then
            mult = mult * lerp(m.atZero, m.atOne, traitValue)
        end
    end
    return mult
end

function applyRoleScale(mode, pos, desire)
    if pos == nil then return desire end
    if mode == "farm" and FARM_ROLE_SCALE[pos] then
        return desire * FARM_ROLE_SCALE[pos]
    elseif (mode == "roam" or mode == "team_roam") and ROAM_ROLE_SCALE[pos] then
        return desire * ROAM_ROLE_SCALE[pos]
    end
    return desire
end

-- Tilt-driven trait shift used in GetEffective.
function applyTilt(p, fretBotsActive)
    local fretMul = fretBotsActive and 1.4 or 1.0
    local shift = p.tilt * p.tiltSensitivity * 0.35 * fretMul
    return {
        aggression = clamp01(p.aggression + shift),
        greed = clamp01(p.greed - shift * 0.4),
        risk = clamp01(p.risk + shift),
        independence = clamp01(p.independence + shift * 0.3),
        teamSpirit = clamp01(p.teamSpirit - shift * 0.7),
        tilt = p.tilt,
    }
end
"""


def main():
    print("=" * 70)
    print("Personality multiplier chain verification")
    print("=" * 70)

    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(PERS_LUA)

    passed = 0
    total = 0

    # --- computeMultiplier ---
    print()
    print("computeMultiplier")
    print("-" * 70)

    # Greedy hero (greed=1, teamSpirit=0): farm boosted
    # mult = lerp(0.70, 1.35, 1.0) * lerp(1.1, 0.85, 0)
    #      = 1.35 * 1.1 = 1.485
    cases = [
        # (description, mode, traits, expected)
        ("Greedy hero, farm: 1.35 * 1.1 = 1.485",
         "farm", {"greed": 1.0, "teamSpirit": 0.0}, 1.35 * 1.1),
        ("Selfless hero, farm: 0.70 * 0.85 = 0.595",
         "farm", {"greed": 0.0, "teamSpirit": 1.0}, 0.70 * 0.85),
        ("Neutral hero, farm: 1.025 * 0.975 = 0.99...",
         "farm", {"greed": 0.5, "teamSpirit": 0.5}, 1.025 * 0.975),
        ("Aggressive solo roamer, roam: 1.40 * 0.8 * 1.15 = 1.288",
         "roam",
         {"aggression": 1.0, "greed": 1.0, "independence": 1.0},
         1.40 * 0.8 * 1.15),
        ("Brave defender, defend: teamSpirit 1.0 risk 0.0 = 1.3 * 1.15 = 1.495",
         "defend",
         {"teamSpirit": 1.0, "risk": 0.0},
         1.3 * 1.15),
        ("Bold retreat (low risk): 0.7",
         "retreat", {"risk": 1.0}, 0.7),
        ("Cautious retreat (high risk -> low atOne): wait, low risk = atZero=1.3",
         "retreat", {"risk": 0.0}, 1.3),
        ("Unknown mode: 1.0 (no-op)",
         "unknown_mode", {"aggression": 0.5}, 1.0),
    ]
    for desc, mode, traits, expected in cases:
        total += 1
        # Build Lua trait table
        trait_lua = "{" + ", ".join(f"{k}={v}" for k, v in traits.items()) + "}"
        L.execute(f"_p = {trait_lua}")
        result = L.eval(f"computeMultiplier('{mode}', _p)")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.4f} (expected {expected:.4f})")
        if ok:
            passed += 1

    # --- applyRoleScale ---
    print()
    print("applyRoleScale")
    print("-" * 70)

    role_cases = [
        ("Pos 1 farm: 1.0 * 1.35", "farm", 1, 1.0, 1.35),
        ("Pos 5 farm: 1.0 * 0.40", "farm", 5, 1.0, 0.40),
        ("Pos 4 roam: 1.0 * 1.30", "roam", 4, 1.0, 1.30),
        ("Pos 4 team_roam: 1.0 * 1.30", "team_roam", 4, 1.0, 1.30),
        ("Pos 1 push (no role scale): 1.0 unchanged", "push", 1, 1.0, 1.0),
        ("Unknown pos: no scale", "farm", 99, 1.0, 1.0),
    ]
    for desc, mode, pos, desire, expected in role_cases:
        total += 1
        result = L.eval(f"applyRoleScale('{mode}', {pos}, {desire})")
        ok = abs(result - expected) < 0.001
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {desc}: got {result:.4f} (expected {expected:.4f})")
        if ok:
            passed += 1

    # --- GetEffective tilt application ---
    print()
    print("Tilt-driven trait shift")
    print("-" * 70)

    # baseline traits, no tilt: identity
    total += 1
    L.execute("""
        _p = { aggression=0.5, greed=0.5, risk=0.5, independence=0.5,
               teamSpirit=0.5, tilt=0, tiltSensitivity=0.5 }
        _r = applyTilt(_p, false)
    """)
    agg = L.eval("_r.aggression")
    ok = abs(agg - 0.5) < 0.001
    print(f"  [{'PASS' if ok else 'FAIL'}] tilt=0 -> identity: aggression {agg:.3f}")
    if ok: passed += 1

    # Tilted hero: aggression+, teamSpirit-
    # tilt=0.5, tiltSens=0.5, fretMul=1.0
    # shift = 0.5 * 0.5 * 0.35 * 1.0 = 0.0875
    # aggression = 0.5 + 0.0875 = 0.5875
    # teamSpirit = 0.5 - 0.0875*0.7 = 0.5 - 0.06125 = 0.43875
    total += 1
    L.execute("""
        _p = { aggression=0.5, greed=0.5, risk=0.5, independence=0.5,
               teamSpirit=0.5, tilt=0.5, tiltSensitivity=0.5 }
        _r = applyTilt(_p, false)
    """)
    agg = L.eval("_r.aggression")
    ts = L.eval("_r.teamSpirit")
    ok = abs(agg - 0.5875) < 0.001 and abs(ts - 0.43875) < 0.001
    print(f"  [{'PASS' if ok else 'FAIL'}] tilt=0.5: agg {agg:.4f} (~0.5875), "
          f"teamSpirit {ts:.4f} (~0.43875)")
    if ok: passed += 1

    # FretBots mode amplifies tilt by 1.4x
    # shift = 0.5 * 0.5 * 0.35 * 1.4 = 0.1225
    # aggression = 0.5 + 0.1225 = 0.6225
    total += 1
    L.execute("""
        _r = applyTilt(_p, true)
    """)
    agg_fret = L.eval("_r.aggression")
    ok = abs(agg_fret - 0.6225) < 0.001
    print(f"  [{'PASS' if ok else 'FAIL'}] FretBots mode: agg {agg_fret:.4f} (~0.6225)")
    if ok: passed += 1

    # Clamp at 1.0
    total += 1
    L.execute("""
        _p = { aggression=0.95, greed=0.5, risk=0.95, independence=0.5,
               teamSpirit=0.5, tilt=1.0, tiltSensitivity=1.0 }
        _r = applyTilt(_p, false)
    """)
    risk = L.eval("_r.risk")
    ok = risk == 1.0  # should be clamped from 0.95+0.35=1.30
    print(f"  [{'PASS' if ok else 'FAIL'}] Tilt-shift clamps to 1.0: risk {risk}")
    if ok: passed += 1

    print()
    print(f"Result: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
