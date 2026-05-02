#!/usr/bin/env python3
"""
v2: more aggressive helper application.

For each X.Consider* function in BotLib that has BOTH:
  - target validation (J.IsValidHero / J.IsValidTarget / J.CanCastOnTargetAdvanced)
  - damage prediction (CanKillTarget / WillKillTarget / WillMagicKillTarget /
    GetEstimatedDamageToTarget / nDamage / nKillDamage / etc.)

If J.HasDamageImmunityModifier is NOT already called, insert it after the
last `J.IsValidHero(<var>)` or `J.CanCastOnTargetAdvanced(<var>)` call as
an additional gate.

This is intentionally aggressive — it adds the helper to AoE-by-target,
buffs, debuffs, etc. The downside: some calls are "skip target" gating
that's now slightly stricter; the upside: no waste on damage-immune
targets.
"""

import os
import re

REPO = r"C:\Users\User\Desktop\Dota 2 Open Hyper AI"
BOTLIB = os.path.join(REPO, "bots", "BotLib")

RE_FUNC_START = re.compile(r"^function X\.Consider", re.MULTILINE)
RE_FUNC_END = re.compile(r"^end$", re.MULTILINE)

# A "target-gate" line: matches `<indent>and not <var>:IsHero()` or `J.IsValidHero(<var>)` etc.
RE_VALID = re.compile(
    r"^(\s+)(and\s+)?(?:J\.IsValid(?:Hero|Target|Unit)|J\.CanCastOnTargetAdvanced|J\.CanCastOnNonMagicImmune|J\.CanCastOnMagicImmune)\(\s*(\w+)\s*\)\s*$"
)


def split_into_functions(content):
    starts = [m.start() for m in RE_FUNC_START.finditer(content)]
    if not starts:
        return
    for i, start in enumerate(starts):
        next_start = starts[i + 1] if i + 1 < len(starts) else len(content)
        slc = content[start:next_start]
        ends = list(RE_FUNC_END.finditer(slc))
        if not ends:
            continue
        first_end = ends[0]
        body_end = start + first_end.end()
        yield start, body_end, content[start:body_end]


def patch_function(body):
    if "HasDamageImmunityModifier" in body:
        return None
    # Heuristic: must look like it does damage prediction
    if not re.search(
        r"WillKillTarget|WillMagicKillTarget|CanKillTarget|GetEstimatedDamageToTarget|"
        r"nDamage\b|nKillDamage|nDamageMagic|nDamagePure|nDamagePhysical",
        body,
    ):
        return None
    # Must have at least one target validation
    if not RE_VALID.search(body):
        return None

    lines = body.split("\n")
    last_idx = -1
    last_var = None
    last_indent = "\t"
    for i, line in enumerate(lines):
        m = RE_VALID.match(line)
        if m:
            last_idx = i
            last_indent = m.group(1)
            last_var = m.group(3)

    if last_idx < 0 or not last_var:
        return None

    # Insert AFTER last validation line, with same indent and `and not ...`
    new_line = f"{last_indent}and not J.HasDamageImmunityModifier({last_var})"
    lines.insert(last_idx + 1, new_line)
    return "\n".join(lines)


def patch_file(path):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    funcs = list(split_into_functions(content))
    funcs.reverse()
    new_content = content
    n = 0
    for start, end, body in funcs:
        patched = patch_function(body)
        if patched is None:
            continue
        new_content = new_content[:start] + patched + new_content[end:]
        n += 1
    if n > 0:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
    return n


def main():
    total = 0
    files_changed = []
    for fname in sorted(os.listdir(BOTLIB)):
        if not fname.startswith("hero_") or not fname.endswith(".lua"):
            continue
        path = os.path.join(BOTLIB, fname)
        n = patch_file(path)
        if n > 0:
            total += n
            files_changed.append((fname, n))
    print(f"Patched {total} Considers across {len(files_changed)} files")
    for fname, n in files_changed:
        print(f"  {fname}: +{n}")


if __name__ == "__main__":
    main()
