"""Static verification harness for the stun-chain module
(bots/FunLib/aba_stun_chain.lua).

Verifies the three public predicates produce the documented behavior:
  - ShouldDelay(target): true when target has > 0.5s CC remaining
  - ShouldChainNow(target, castDelay): true when remaining is in
    [castDelay, castDelay + 0.4] — the chain window
  - IsTargetFreshlyLocked(target): true when remaining > 2.0s

CC detection covers both the engine-consolidated stun
(jmz.GetRemainStunTime) AND a list of hero-specific modifiers via
target:HasModifier + jmz.GetModifierTime. Both paths need testing.
"""

import sys
import lupa
from lupa import LuaRuntime


# Inline the stun-chain module functions we want to exercise. We can't
# easily load the production file because it does
# `local jmz = require(...)` at top level which would try to load all
# of jmz_func.lua. So we copy the relevant logic verbatim.
STUN_CHAIN_LUA = r"""
local CC_MODIFIERS = {
    "modifier_stunned",
    "modifier_axe_berserkers_call",
    "modifier_legion_commander_duel",
    "modifier_faceless_void_chronosphere_freeze",
    "modifier_enigma_black_hole_pull",
    "modifier_naga_siren_song_of_the_siren_sleep",
    "modifier_treant_overgrowth",
    "modifier_lion_impale",
    "modifier_warlock_upheaval",
    "modifier_invoker_cold_snap_freeze",
    "modifier_pudge_dismember",
    "modifier_bane_fiends_grip",
    "modifier_bane_nightmare",
    "modifier_shadow_shaman_shackles",
    "modifier_disruptor_static_storm",
    "modifier_winter_wyvern_winters_curse",
    "modifier_outworld_destroyer_astral_imprisonment_prison",
    "modifier_skywrath_mage_ancient_seal",
    "modifier_silencer_global_silence",
    "modifier_doom_bringer_doom",
    "modifier_terrorblade_sunder",
    "modifier_oracle_fortunes_end_purge",
    "modifier_mars_arena_of_blood_leash",
    "modifier_dark_seer_vacuum",
    "modifier_lich_chain_frost_slow",
}

local jmz = jmz_module  -- injected from Python

local function getCCRemaining(target)
    if target == nil then return 0 end
    if target:IsNull() or not target:IsAlive() then return 0 end
    local longest = 0
    local okStun, stunR = pcall(function() return jmz.GetRemainStunTime(target) end)
    if okStun and type(stunR) == "number" and stunR > longest then
        longest = stunR
    end
    for _, mod in ipairs(CC_MODIFIERS) do
        if target:HasModifier(mod) then
            local okMod, r = pcall(function() return jmz.GetModifierTime(target, mod) end)
            if okMod and type(r) == "number" and r > longest then
                longest = r
            end
        end
    end
    return longest
end

function ShouldDelay(target)
    if target == nil then return false end
    local remaining = getCCRemaining(target)
    return remaining > 0.5
end

function ShouldChainNow(target, castDelay)
    if target == nil then return false end
    castDelay = castDelay or 0.3
    local remaining = getCCRemaining(target)
    return remaining > castDelay and remaining <= (castDelay + 0.4)
end

function IsTargetFreshlyLocked(target)
    if target == nil then return false end
    return getCCRemaining(target) > 2.0
end

function GetCCRemaining(target)
    return getCCRemaining(target)
end
"""


class MockTarget:
    """A mocked enemy hero with given stun + modifier state."""
    def __init__(self, alive=True, stun_time=0.0, modifiers=None, unit_name="enemy"):
        self.alive = alive
        self.stun_time = stun_time
        self.modifiers = modifiers or {}  # {mod_name: remaining_seconds}
        self.unit_name = unit_name

    def IsAlive(self): return self.alive
    def IsNull(self): return not self.alive
    def HasModifier(self, mod): return mod in self.modifiers
    def GetUnitName(self): return self.unit_name


def setup_lua(target):
    L = LuaRuntime(unpack_returned_tuples=True)

    # Build the jmz_module mock with GetRemainStunTime + GetModifierTime
    def get_remain_stun_time(t):
        return t.stun_time if t else 0.0

    def get_modifier_time(t, mod):
        return t.modifiers.get(mod, 0.0) if t else 0.0

    L.globals().jmz_module = L.table_from({
        "GetRemainStunTime": get_remain_stun_time,
        "GetModifierTime": get_modifier_time,
    })

    L.execute(STUN_CHAIN_LUA)
    L.globals().target = target
    return L


def assert_eq(name, actual, expected):
    passed = actual == expected
    status = "PASS" if passed else "FAIL"
    print(f"  [{status}] {name}: got {actual}, expected {expected}")
    return passed


def run_case(name, target, should_delay, should_chain, fresh_lock, cc_remaining):
    """Run all four predicates against the target and verify expectations."""
    print(f"\nScenario: {name}")
    if target is None:
        L = LuaRuntime(unpack_returned_tuples=True)
        L.globals().jmz_module = L.table_from({
            "GetRemainStunTime": lambda t: 0.0,
            "GetModifierTime": lambda t, m: 0.0,
        })
        L.execute(STUN_CHAIN_LUA)
        L.globals().target = None
    else:
        L = setup_lua(target)

    cc = L.eval("GetCCRemaining(target)")
    sd = L.eval("ShouldDelay(target)")
    sc = L.eval("ShouldChainNow(target, 0.3)")
    fl = L.eval("IsTargetFreshlyLocked(target)")

    results = []
    results.append(assert_eq("GetCCRemaining", cc, cc_remaining))
    results.append(assert_eq("ShouldDelay", sd, should_delay))
    results.append(assert_eq("ShouldChainNow(0.3)", sc, should_chain))
    results.append(assert_eq("IsTargetFreshlyLocked", fl, fresh_lock))
    return all(results)


def main():
    print("=" * 70)
    print("Stun chain verification (aba_stun_chain.lua predicates)")
    print("=" * 70)

    cases = [
        # (name, target, should_delay, should_chain_now(0.3), fresh_locked, cc_remaining)
        ("nil target — all predicates safe-false",
         None, False, False, False, 0.0),

        ("dead target — all predicates safe-false",
         MockTarget(alive=False, stun_time=2.0),
         False, False, False, 0.0),

        ("unstunned target — fire normally (all false)",
         MockTarget(stun_time=0.0),
         False, False, False, 0.0),

        ("freshly stunned (3.0s) — DELAY + freshly locked",
         MockTarget(stun_time=3.0),
         True, False, True, 3.0),

        ("mid stun (1.5s) — DELAY (out of chain window)",
         MockTarget(stun_time=1.5),
         True, False, False, 1.5),

        ("end-of-stun chain window (0.4s, castDelay 0.3, in [0.3, 0.7])",
         MockTarget(stun_time=0.4),
         False, True, False, 0.4),

        ("just below chain window (0.25s, < castDelay 0.3) — neither delay nor chain",
         MockTarget(stun_time=0.25),
         False, False, False, 0.25),

        ("0.5s exactly — boundary: delay false, chain true (0.5 <= 0.7)",
         MockTarget(stun_time=0.5),
         False, True, False, 0.5),

        ("hero-specific CC: chrono freeze 4.0s",
         MockTarget(modifiers={"modifier_faceless_void_chronosphere_freeze": 4.0}),
         True, False, True, 4.0),

        ("hero-specific CC: dismember 1.8s",
         MockTarget(modifiers={"modifier_pudge_dismember": 1.8}),
         True, False, False, 1.8),

        ("hero-specific CC: doom 7.0s — locked indefinitely",
         MockTarget(modifiers={"modifier_doom_bringer_doom": 7.0}),
         True, False, True, 7.0),

        ("longest-wins: stun 0.4s + chrono 3.0s — chrono wins",
         MockTarget(stun_time=0.4, modifiers={"modifier_faceless_void_chronosphere_freeze": 3.0}),
         True, False, True, 3.0),

        ("longest-wins: stun 2.0s + dismember 0.4s — stun wins",
         MockTarget(stun_time=2.0, modifiers={"modifier_pudge_dismember": 0.4}),
         True, False, False, 2.0),

        ("modifier present but engine returned 0 (e.g. about to expire)",
         MockTarget(modifiers={"modifier_stunned": 0.0}),
         False, False, False, 0.0),
    ]

    passed = 0
    for case in cases:
        if run_case(*case):
            passed += 1

    total = len(cases)
    print()
    print(f"Result: {passed}/{total} scenarios fully passed (all 4 predicates each)")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
