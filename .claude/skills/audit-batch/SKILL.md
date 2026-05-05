---
name: audit-batch
description: Run a structured per-item audit across many files (e.g. all 127 hero files) without partial-shipping. Use this when the user asks for an audit, sweep, or "go through every X" workflow. Forces a checklist file, per-item proof entries, and rejects mid-batch commits/pushes. Trigger on "audit X", "go through every X", "sweep X", "fix all X", or when scope is >10 files.
---

# audit-batch — structured multi-file audit workflow

This skill forces the chat-loop pattern to break on bulk audits. The
default behavior is: read 5 files, claim "fix shipped", ask user to
test, repeat. This skill makes that impossible.

## Workflow (mandatory; cannot be skipped)

### Step 1 — Define scope, in writing

Create `.claude/audit/<topic>.md` with:

```
# Audit: <topic>

## Scope
- File pattern: <e.g. bots/BotLib/hero_*.lua>
- Total files: <N>
- Audit question: <e.g. "does ConsiderR fire during pushes?">

## Done definition
- Every file in scope has a per-item entry below.
- Every entry says `OK` (no fix needed, with reason) or
  `FIX: <file:line>` with the change applied and file:line trace.
- The diff applies all `FIX` entries.

## Items
[empty — populated as you audit]
```

If you can't write this header, you don't have a clear-enough audit
target. Stop and ask the user to clarify.

### Step 2 — Enumerate every file in scope

Use `Glob` or `find` to list every file. Append to the `## Items`
section as `- [ ] <file>` checkbox lines. Do not skip any.

### Step 3 — Per-item read + decision

For EACH file, read the relevant section, then append a one-line
entry of the form:

```
- [x] hero_huskar.lua:719  OK  — IsGoingOnSomeone gate, broadened by framework fix; no internal blocker.
- [x] hero_dragon_knight.lua:727  FIX  — `+2 advantage` gate prevents ult during winning fights; removed.
```

`OK` reasons must be substantive. "Looks fine" is not a reason. State
what was checked and why it doesn't need a fix.

### Step 4 — Apply all fixes in batch

Once every item has an entry, apply the FIX edits. ONE commit per
batch (per CLAUDE.md / commit-trace hook), with the trace section
referencing the audit file.

### Step 5 — Push only after the marker is created

The push-gate hook requires `.claude/work-complete` to exist. Create
it ONLY when:
- Every item in scope has a checked entry.
- The diff applies all FIX entries.
- The commit lands cleanly.

The marker is auto-deleted on push. Each subsequent batch must
explicitly re-create it.

## Anti-patterns this skill blocks

- "I read 5 files and found bugs in 3" — you must read every file.
  Sample audits report counts based on samples, not facts.
- "I'll fix the obvious cases first and come back for the rest" —
  there is no "come back." Either it's audited or it isn't.
- "Sim 64/64 green, audit batch landed" — the sim doesn't test what
  the user cares about. Lead with the audit completeness, not the
  sim status.
- "Need lobby verification" — the audit is about CODE-level
  consistency. Lobby verification is a separate concern. Don't use
  it as an exit ramp.

## Reference

The CLAUDE.md "Engineering discipline" section and the hooks in
`.claude/hooks/` enforce these rules mechanically. Don't try to
bypass them — actually do the audit.
