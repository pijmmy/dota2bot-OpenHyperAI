"""Run all static verification tests for the recent gameplay fixes.

Each test mocks the Dota engine API + module dependencies and exercises
the production Lua logic to verify the fixes actually do what's claimed.

Use this when the user reports a bug to make sure the fix isn't just
"compiles cleanly" or "looks reasonable in code." Returns non-zero exit
on any failure.
"""

import subprocess
import sys
from pathlib import Path

TESTS = [
    "test_hg_defense.py",
    "test_bounty_rune.py",
    "test_roshan_pit.py",
    "test_stun_chain.py",
    "test_team_plan_logic.py",
    "test_ward_utility.py",
    "test_focus.py",
    "test_save.py",
    "test_enemy_focus.py",
    "test_synthetic_pings.py",
    "test_deward.py",
    "test_personality.py",
    "test_draft_strategy.py",
    "test_gametheory.py",
    "test_commitment.py",
    "test_archetype_affinity.py",
    "test_teamplan_helpers.py",
    "test_anti_dive.py",
    "test_attack_target_hysteresis.py",
    "test_hysteresis.py",
    "test_safezone.py",
    "test_attack_hold.py",
    "test_kunkka_ship.py",
    "test_skywrath_harass_gate.py",
    "test_support_farm_contention.py",
    "test_team_roam_engage_override.py",
    "test_bounty_core_coverage.py",
    "test_retreat_reengage_hold.py",
    "test_human_kill_yield.py",
]

def main():
    here = Path(__file__).parent
    results = []
    for test in TESTS:
        path = here / test
        if not path.exists():
            print(f"MISSING: {test}")
            results.append((test, False))
            continue
        proc = subprocess.run(
            [sys.executable, str(path)],
            capture_output=True,
            text=True,
        )
        ok = proc.returncode == 0
        results.append((test, ok))
        # Print the test's own output unfiltered
        print(proc.stdout, end="")
        if proc.stderr:
            print(proc.stderr, end="", file=sys.stderr)
        print()

    print("=" * 70)
    print("Suite summary")
    print("=" * 70)
    failed = [t for t, ok in results if not ok]
    for test, ok in results:
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {test}")
    print()
    if failed:
        print(f"{len(failed)} suite(s) failed: {', '.join(failed)}")
        return 1
    print("All suites passed.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
