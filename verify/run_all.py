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
