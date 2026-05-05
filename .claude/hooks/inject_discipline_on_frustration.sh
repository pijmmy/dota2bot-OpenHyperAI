#!/usr/bin/env bash
# UserPromptSubmit hook.
# When the user's prompt contains frustration markers ("FINISH", "lazy",
# "do better", "shitty", "FFS", etc.), prepend a discipline reminder to
# the model's context.
#
# Reads JSON: { "session_id", "prompt", ... }
# Output to stdout is *prepended* to the user prompt the model receives.
# Exit 0 with output; non-zero blocks the prompt entirely.

set -euo pipefail

PAYLOAD=$(cat)
PROMPT=$(echo "$PAYLOAD" | python -c "import sys, json; d=json.load(sys.stdin); print(d.get('prompt', ''))" 2>/dev/null || echo "")

if [ -z "$PROMPT" ]; then
    exit 0
fi

# Frustration markers — case-insensitive.
TRIGGERED=0
if echo "$PROMPT" | grep -qiE "(FINISH|finish the (job|fucking))" ; then TRIGGERED=1; fi
if echo "$PROMPT" | grep -qiE "(lazy|laziness)" ; then TRIGGERED=1; fi
if echo "$PROMPT" | grep -qiE "(shitty|shit|sack of shit|asshole|FFS|fucking|cocked up|cock up)" ; then TRIGGERED=1; fi
if echo "$PROMPT" | grep -qiE "do better|stop pissing me off|why am i wasting" ; then TRIGGERED=1; fi
if echo "$PROMPT" | grep -qiE "you are (useless|dogshit|trash)" ; then TRIGGERED=1; fi
if echo "$PROMPT" | grep -qiE "i (cant|can'?t) stand" ; then TRIGGERED=1; fi
if echo "$PROMPT" | grep -qiE "have you done all the work\?" ; then TRIGGERED=1; fi
if echo "$PROMPT" | grep -qiE "you'?re (purposely|deliberately) " ; then TRIGGERED=1; fi

if [ "$TRIGGERED" -eq 0 ]; then
    exit 0
fi

# Inject context before the user prompt.
cat <<'REMINDER'
[discipline-reminder — auto-injected because user is frustrated]

The user has signalled the chat-loop pattern is happening again. You are
about to fail the same way as before unless you change behavior NOW:

NON-NEGOTIABLE for this reply:
1. Do NOT produce a status report. Do NOT list "what's still not done."
   Do NOT say "boot a lobby" / "test it" / "ready to play."
2. Do NOT lead with "fair", "right", "got it", "alright", "ok".
3. Do NOT lead with "Sim 64/64 green" — sim doesn't test what they care about.
4. Do NOT push partway through a batch. One push per finished batch.
5. Do NOT narrate intermediate commits ("let me commit and push") — work
   silently to a defined finish line, THEN ship.

What success looks like for this turn:
- If the user asked you to do work, the work is in the diff at the end.
- If the user asked a question, the answer is in the reply with NO padding.
- If you genuinely cannot finish in one turn, say so in ONE sentence and
  state the finish-line condition you're working toward, then keep working.

The mechanical defenses (Stop hook + commit-trace hook + push-gate hook)
are now installed. They will block sandbag phrases at stop time, block
commits without a Trace section, and block pushes without a work-complete
marker. Don't try to game them — actually do the work.

Now, the user's actual prompt follows.
---
REMINDER

# The model receives both this reminder + the original prompt. Hook stdout
# is prepended automatically by Claude Code.
exit 0
