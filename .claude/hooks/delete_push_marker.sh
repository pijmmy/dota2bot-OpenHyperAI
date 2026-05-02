#!/usr/bin/env bash
# PostToolUse hook for Bash matching `git push`.
# After a successful push, deletes the .claude/work-complete marker so the
# next batch must explicitly re-create it.
#
# Receives JSON: { tool_input: { command }, tool_response: { success, ... } }

set -euo pipefail

PAYLOAD=$(cat)
CMD=$(echo "$PAYLOAD" | python -c "import sys, json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('command', ''))" 2>/dev/null || echo "")

if ! echo "$CMD" | grep -qE "^[[:space:]]*git[[:space:]]+push"; then
    exit 0
fi

# Check if push succeeded. tool_response varies; we'll be permissive — if the
# marker exists and the command was a push, delete the marker. The PreToolUse
# hook already gated on the marker.
MARKER=".claude/work-complete"
if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
fi

exit 0
