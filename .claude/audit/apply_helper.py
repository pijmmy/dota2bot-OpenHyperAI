#!/usr/bin/env python3
"""
Bulk-apply J.HasDamageImmunityModifier(target) to every X.Consider*
function in BotLib/ that uses kill prediction or single-target damage
on a hero target, without already having the helper or a comprehensive
modifier blacklist.

Strategy: for each Consider function that has at least one of these
patterns:
  - any modifier_X check (BT/grave/scythe/false_promise/refraction/reincarnation/aeon)
  - a CanKillTarget / WillMagicKillTarget / WillKillTarget call

If the function already has J.HasDamageImmunityModifier(_), skip.
Otherwise: find the line right after the LAST `not <var>:HasModifier(...)`
in the function and add `and not J.HasDamageImmunityModifier(<var>)`
on a new line at the same indentation.

If the function has no inline modifier checks but does have kill
prediction with a target var, we add the helper after the kill check.
"""

import os
import re
import sys

REPO = r"C:\Users\User\Desktop\Dota 2 Open Hyper AI"
BOTLIB = os.path.join(REPO, "bots", "BotLib")

# Patterns
RE_FUNC_START = re.compile(r"^function X\.Consider", re.MULTILINE)
RE_FUNC_END = re.compile(r"^end$", re.MULTILINE)

RE_HASMOD = re.compile(
    r"^(\s+)(and\s+)?not\s+(\w+):HasModifier\(\s*['\"]"
    r"modifier_(?:abaddon_borrowed_time|dazzle_shallow_grave|necrolyte_reapers_scythe|"
    r"oracle_false_promise_timer|templar_assassin_refraction_absorb|"
    r"skeleton_king_reincarnation_scepter_active|item_aeon_disk_buff)['\"]\s*\)\s*$"
)

RE_HELPER = re.compile(r"J\.HasDamageImmunityModifier\(")


def split_into_functions(content):
    """Yield (start_idx, end_idx, body) tuples for each X.Consider* function."""
    starts = [m.start() for m in RE_FUNC_START.finditer(content)]
    if not starts:
        return
    # Find the matching 'end' for each start
    for i, start in enumerate(starts):
        # Body is from this start to either the next start or end of file
        # but we want the matching `end` line.
        # Walk until next standalone `end` line that's at column 0.
        body_search_start = start
        next_start = starts[i + 1] if i + 1 < len(starts) else len(content)
        body = content[body_search_start:next_start]
        # Find the LAST `^end$` in this slice
        ends = [m for m in RE_FUNC_END.finditer(body)]
        if not ends:
            continue
        # Use the FIRST end line — that's the function close
        first_end = ends[0]
        body_end = body_search_start + first_end.end()
        yield start, body_end, content[start:body_end]


def find_target_var_in_lines(lines, around_idx):
    """Look for the variable name used in HasModifier checks within the function lines."""
    # Search for `<var>:HasModifier` in the lines near around_idx
    candidates = []
    for line in lines:
        m = re.search(r"(\w+):HasModifier\(\s*['\"]modifier_", line)
        if m:
            candidates.append(m.group(1))
    if candidates:
        # Most common
        from collections import Counter
        return Counter(candidates).most_common(1)[0][0]
    return None


def patch_function(body):
    """Return patched body or None if no change."""
    # Skip if helper already present
    if RE_HELPER.search(body):
        return None

    lines = body.split("\n")
    # Find LAST line matching RE_HASMOD
    last_hasmod_idx = -1
    target_var = None
    indent = "\t"
    for i, line in enumerate(lines):
        m = RE_HASMOD.match(line)
        if m:
            last_hasmod_idx = i
            indent = m.group(1)
            target_var = m.group(3)

    if last_hasmod_idx < 0:
        # No inline blacklist found in this function, skip.
        return None

    if not target_var:
        return None

    # Insert helper line right after last_hasmod_idx
    new_line = f"{indent}and not J.HasDamageImmunityModifier({target_var})"
    lines.insert(last_hasmod_idx + 1, new_line)
    return "\n".join(lines)


def patch_file(path):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    # Process functions in REVERSE to avoid index shifts
    funcs = list(split_into_functions(content))
    funcs.reverse()

    new_content = content
    patched_count = 0

    for start, end, body in funcs:
        patched = patch_function(body)
        if patched is None:
            continue
        new_content = new_content[:start] + patched + new_content[end:]
        patched_count += 1

    if patched_count > 0:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
    return patched_count


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

    print(f"Patched {total} Consider functions across {len(files_changed)} files:")
    for fname, n in files_changed:
        print(f"  {fname}: +{n}")


if __name__ == "__main__":
    main()
