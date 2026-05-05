#!/usr/bin/env bash
# Stop hook — detect sandbag/exit-ramp phrases in the assistant's most recent
# reply and block the stop with a discipline reminder if found.
#
# Reads JSON from stdin: { "session_id", "transcript_path", "stop_hook_active", ... }
# Exits 2 + message-to-stderr to block the stop and force the model to revise.

set -euo pipefail

# Read the JSON payload
PAYLOAD=$(cat)
TRANSCRIPT=$(echo "$PAYLOAD" | python -c "import sys, json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || echo "")
STOP_ACTIVE=$(echo "$PAYLOAD" | python -c "import sys, json; d=json.load(sys.stdin); print(d.get('stop_hook_active', False))" 2>/dev/null || echo "False")

# Don't loop: if the stop hook is already active (we're in a forced re-think),
# let it through. Prevents infinite block.
if [ "$STOP_ACTIVE" = "True" ]; then
    exit 0
fi

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    exit 0
fi

# Extract just the most recent assistant message text from the transcript.
# Transcript is JSONL; the last assistant message has role="assistant".
LAST_ASSISTANT=$(python <<PYEOF 2>/dev/null || echo ""
import json, sys
text = []
try:
    with open(r"""$TRANSCRIPT""", "r", encoding="utf-8") as f:
        lines = f.readlines()
    # Walk backwards; collect text from the most recent assistant message.
    last = None
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except Exception:
            continue
        msg = entry.get("message") or entry
        if isinstance(msg, dict) and msg.get("role") == "assistant":
            last = msg
            break
    if last:
        content = last.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    text.append(c.get("text", ""))
        elif isinstance(content, str):
            text.append(content)
    print("\n".join(text))
except Exception:
    pass
PYEOF
)

if [ -z "$LAST_ASSISTANT" ]; then
    exit 0
fi

# Banned phrases — sandbag / exit-ramp vocabulary the user explicitly rejected.
# Each match gets reported.
HITS=""

check() {
    local pattern="$1"
    if echo "$LAST_ASSISTANT" | grep -qiE "$pattern"; then
        HITS="${HITS}  - matched: ${pattern}"$'\n'
    fi
}

# Status-report sandbag phrases
check "still not done"
check "haven'?t (audited|verified|done|finished|fixed|tested|checked)"
check "needs lobby (test|verification|observation|playtest)"
check "want me to keep going"
check "should i (continue|proceed|keep going)"
check "let me know if"
check "tell me if"
check "what.{0,15}still not done"
check "what.{0,15}(haven'?t|hasn'?t) been"

# Premature-success vocabulary
check "sim.{0,8}(64|all).{0,3}green"
check "(all|sim).{0,3}(checks|tests).{0,8}pass"
check "ready to (test|play|push|merge)"
check "boot a (lobby|game)"
check "test (in (a |the )?lobby|it now|and tell me)"

# Teenager filler
check "^fair[\\.\\!]"
check "^right[\\.\\!]"
check "^got it[\\.\\!]"
check "^alright[\\.\\!]"
check "^ok[\\.\\!]"
check "^gotcha[\\.\\!]"

# Mid-task commit narration (chat-loop pattern)
check "let me commit"
check "committing (this|now|first)"
check "pushed.{0,30}(state of|status|summary)"

# Status-report scaffolding — reply structures that read as status reports
# even when the user just wanted the result. These patterns leaked through
# the original ban list; documented in item 5 of the trust audit.
check "^(state|final state|cumulative|cumulative coverage|coverage so far)"
check "(state of|status of|summary of) (the|this) (pr|branch|audit|batch|fix|change|repo)"
check "what (this commit )?(does|doesn'?t|did|did not)"
check "what (this )?(commit|batch|change|fix) does"
check "what (was|gets) (verified|covered|done|fixed)"
check "^cumulative (coverage|state|status|fixes|audit)"
check "^heroes (deliberately|specifically) (not|skipped|excluded)"
check "^heroes (with|without) (the helper|coverage|the modifier)"
check "^conclusion[\\.\\:]"
check "^summary[\\.\\:]"
check "^findings[\\.\\:]"
check "^method[\\.\\:]"
check "^per-hero (decisions|coverage|audit|breakdown)"

# "What I've done" lists — narrating the past instead of stating the result
check "what i'?ve (done|fixed|patched|added|covered)"
check "what i (did|fixed|patched|added|covered)"
check "(this|each) (commit|batch|fix) (does|covers|includes)"
check "^the (changes|fixes|edits|patches) (in|to|for) this"

# Self-flagellation / process-narration in replies (still chat-loop)
check "^now (let me|i'?ll|i'?m going to)"
check "^next (i'?ll|step|up|i need)"
check "^(going|grinding) (to|through)"
check "(i need to|i'?ll need to) keep (going|working)"

if [ -n "$HITS" ]; then
    cat >&2 <<MSG
[stop-blocker] Your reply contains banned sandbag/exit-ramp phrases:
$HITS
These are the chat-loop pattern the user explicitly forbade. Rewrite the
reply so it does NOT include them. Specifically:
  - Do not list "what's still not done" — either DO it, or stay silent.
  - Do not say "ready to test" / "boot a lobby" — that's an exit ramp.
  - Do not lead with "sim 64/64 green" — sim doesn't test behavior.
  - Do not open with "fair", "right", "got it", "alright", "ok".
  - Do not narrate mid-task commits.

If the work is genuinely complete, reply with the diff/result only —
no status reports, no caveats, no "want me to keep going."

If the work isn't complete, KEEP DOING IT. Do not stop.
MSG
    exit 2
fi

exit 0
