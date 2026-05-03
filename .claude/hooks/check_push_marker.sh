#!/usr/bin/env bash
# PreToolUse hook for Bash matching `git push`.
# Blocks pushes unless `.claude/work-complete` exists.
#
# This stops the chat-loop pattern of fragmenting work into many small
# pushes that produce checkpoint dopamine without genuine completion.
#
# Workflow:
#   1. User defines a batch of work.
#   2. Claude does ALL of it.
#   3. When the batch is complete and verified, Claude creates
#      .claude/work-complete with a one-line summary.
#   4. Push succeeds; the hook deletes the marker on success.
#
# Override: set CLAUDE_SKIP_PUSH_GATE=1 to bypass (emergency only).

set -euo pipefail

PAYLOAD=$(cat)
CMD=$(echo "$PAYLOAD" | python -c "import sys, json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('command', ''))" 2>/dev/null || echo "")

# Only act on git push commands.
if ! echo "$CMD" | grep -qE "^[[:space:]]*git[[:space:]]+push"; then
    exit 0
fi

# Override hatch.
if [ "${CLAUDE_SKIP_PUSH_GATE:-0}" = "1" ]; then
    exit 0
fi

# Marker path was moved from .claude/work-complete to .work-complete because
# Claude Code treats .claude/ as a sensitive directory and prompts on every
# write even in bypass-permissions mode (the carve-out exists so an injection
# can't grant itself permissions). Moving the marker out fixes that prompt
# loop while keeping the gate functional. The old path is still accepted as
# a fallback for in-flight branches that wrote to the legacy location.
MARKER=".work-complete"
MARKER_LEGACY=".claude/work-complete"

if [ -f "$MARKER" ] || [ -f "$MARKER_LEGACY" ]; then
    # Marker exists; allow push. Deleted on success by the PostToolUse hook.
    exit 0
fi

# Block.
cat >&2 <<MSG
[push-blocker] git push blocked — .work-complete marker is missing.

This project enforces "one push per batch, not per commit" to prevent
the chat-loop pattern (small fix → push → claim → ask user to test → repeat).

Before pushing, you must:
  1. Confirm the entire batch of work the user asked for is genuinely done.
  2. Each item in the batch is verified — file:line trace, not pattern-match.
  3. Create the marker: 'echo "<one-line summary>" > .work-complete'

Then re-run the push. The marker will be auto-deleted on success.

If you're tempted to push partial work for a "checkpoint" or to "let the
user test" — DON'T. Keep doing the work until the batch is complete.

Override (emergency only): CLAUDE_SKIP_PUSH_GATE=1 git push ...
MSG
exit 2
