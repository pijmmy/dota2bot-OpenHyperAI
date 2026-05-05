#!/usr/bin/env python3
"""
For each Consider that gates on J.IsGoingOnSomeone(bot), check whether
the body inside the gate validates that the target is a hero before
casting.

Risk: my framework broadening (jmz_func.lua J.IsGoingOnSomeone now
returns true under PUSH_TOWER_* / DEFEND_TOWER_* when an enemy hero
is in 1200u) means the gate fires more often. Heroes that gate on
this AND use bot:GetTarget() / J.GetProperTarget(bot) without
validating it's a hero could now cast on creep targets.

Output: heroes whose IsGoingOnSomeone block has no hero-validation
call. Those are the genuine risk cases.
"""

import os
import re

REPO = r"C:\Users\User\Desktop\Dota 2 Open Hyper AI"
BOTLIB = os.path.join(REPO, "bots", "BotLib")

RE_FUNC_START = re.compile(r"^function X\.Consider", re.MULTILINE)
RE_END = re.compile(r"^end$", re.MULTILINE)
RE_ISO = re.compile(r"J\.IsGoingOnSomeone\(\s*bot\s*\)")
RE_VALID = re.compile(
    r"J\.IsValid(?:Hero|Target|Unit)\(|J\.CanCastOnTargetAdvanced\(|"
    r"J\.CanCastOnNonMagicImmune\(|J\.CanCastOnMagicImmune\(|"
    r"botTarget:IsHero\(\)|enemyHero:IsHero\(\)"
)


def split_into_functions(content):
    starts = [m.start() for m in RE_FUNC_START.finditer(content)]
    if not starts:
        return
    for i, start in enumerate(starts):
        next_start = starts[i + 1] if i + 1 < len(starts) else len(content)
        slc = content[start:next_start]
        ends = list(RE_END.finditer(slc))
        if not ends:
            continue
        first_end = ends[0]
        body_end = start + first_end.end()
        yield content[start:body_end]


def fn_name(body):
    m = re.match(r"function (X\.\w+)", body)
    return m.group(1) if m else "?"


def has_iso_without_validation(body):
    """Returns True if the function has a J.IsGoingOnSomeone gate but the
    block following it lacks any hero-validation call."""
    iso_match = RE_ISO.search(body)
    if not iso_match:
        return False
    # Take the body from the iso position to end-of-function
    sub = body[iso_match.start():]
    # Find the next 25 lines (heuristic: validation should be very nearby)
    lines = sub.split("\n")[:30]
    sub_text = "\n".join(lines)
    return not RE_VALID.search(sub_text)


def main():
    flagged = []
    for fname in sorted(os.listdir(BOTLIB)):
        if not fname.startswith("hero_") or not fname.endswith(".lua"):
            continue
        path = os.path.join(BOTLIB, fname)
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        for body in split_into_functions(content):
            if has_iso_without_validation(body):
                flagged.append((fname, fn_name(body)))

    print(f"{len(flagged)} Considers gate on IsGoingOnSomeone without validation:")
    for fname, fnnm in flagged:
        print(f"  {fname}: {fnnm}")


if __name__ == "__main__":
    main()
