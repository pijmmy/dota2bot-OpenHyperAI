#!/usr/bin/env bash
# PreToolUse hook for Bash matching `git commit`.
# Blocks commits whose message body lacks a structured trace section.
#
# Forces every code-changing commit to include either:
#   - a "## Trace" / "Trace:" / "scenario:" section, OR
#   - the explicit phrase "no-trace: <reason>" admitting the trace was skipped.
#
# This stops the "ship now, document later" pattern.

set -euo pipefail

PAYLOAD=$(cat)

# Extract the command using python (more reliable than jq on Windows).
CMD=$(python -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" <<<"$PAYLOAD")

# Quick gate: only act on git commit commands.
if ! echo "$CMD" | grep -qE "^[[:space:]]*git[[:space:]]+commit"; then
    exit 0
fi

# Skip merges, reverts, amends — those legitimately don't need a trace.
if echo "$CMD" | grep -qE "(--amend|--merge|--revert|--squash)"; then
    exit 0
fi

# Skip if user explicitly opted out via env var.
if [ "${CLAUDE_SKIP_TRACE_CHECK:-0}" = "1" ]; then
    exit 0
fi

# Extract the message body using python. Handles 3 cases:
#   1) inline -m "..."
#   2) heredoc:  -m "$(cat <<'EOF' ... EOF)"
#   3) -F file
MSG=$(python -c "
import re, sys, os
cmd = sys.stdin.read()
msg = ''

# Case: heredoc with EOF marker
m = re.search(r\"cat <<'EOF'\s*\n(.*?)\nEOF\", cmd, re.DOTALL)
if m:
    msg = m.group(1)
else:
    # Case: inline -m \"...\" or -m '...'
    m = re.search(r'-m\s+\"([^\"]*)\"', cmd, re.DOTALL)
    if m:
        msg = m.group(1)
    else:
        m = re.search(r\"-m\s+'([^']*)'\", cmd, re.DOTALL)
        if m:
            msg = m.group(1)
        else:
            # Case: -F file
            m = re.search(r'-F\s+(\S+)', cmd)
            if m and os.path.isfile(m.group(1)):
                with open(m.group(1), 'r', encoding='utf-8', errors='ignore') as f:
                    msg = f.read()

print(msg)
" <<<"$CMD")

# If we couldn't extract a message at all, allow (don't false-block).
if [ -z "$MSG" ]; then
    exit 0
fi

# Trace requirement: at least one of these must appear in the message.
if echo "$MSG" | grep -qiE "(^|[[:space:]])(##[[:space:]]*Trace|Trace:|scenario:|no-trace:)"; then
    exit 0
fi

# Trivial-maintenance prefixes are allowed without trace.
if echo "$MSG" | grep -qiE "^(chore|docs|trivial|typo|whitespace|formatting|style):"; then
    exit 0
fi

# Otherwise, block.
cat >&2 <<'BLOCKMSG'
[trace-required] git commit blocked — message body is missing the trace section.

Every code-changing commit in this project must include ONE of:
  1. "## Trace" or "Trace:" section explaining the concrete scenario
     traced through the code, what gate fires/doesn't, and what changes
     behaviorally.
  2. "no-trace: <reason>" if the change is genuinely untraceable
     (config files, comment-only, etc.).
  3. A "chore:" / "docs:" / "trivial:" / "typo:" prefix for trivial
     maintenance.

If you're committing real code changes without tracing, that's the
chat-loop pattern. Trace it through the code first, then commit. If
you genuinely can't trace it, write "no-trace: framework reasoning
only, not verified through a concrete scenario" in the body.

Override (emergency only): CLAUDE_SKIP_TRACE_CHECK=1 git commit ...
BLOCKMSG
exit 2
