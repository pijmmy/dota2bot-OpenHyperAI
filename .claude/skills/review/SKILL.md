---
name: review
description: Auto-diagnose the most recent Dota 2 bot custom-lobby match by running `python -m sim.review --json` against the latest NDJSON log under `<OHA>/bots/logs/`, parsing the structured anti-pattern report, and presenting findings sorted by severity. Use this skill IMMEDIATELY whenever the user says "review", "review the log", "review the match", "review latest", "diagnose latest", "what went wrong", "what broke", "find issues", "audit the game", or any short request to triage a recent bot match — even a one-word "review" without context, in this project, means run this skill. Also use whenever the user references a `.ndjson` log file, mentions checking `bots/logs/`, or asks for a triage report on bot behavior. Do NOT use for: simulator regression runs (use `python -m sim.run_sim` directly), inspecting source code (use Read/Grep), or general bot-script questions (consult CLAUDE.md and docs/).
---

# Review — diagnose the latest bot match log

The user runs custom-lobby Dota 2 matches with the bot scripts in this repo. When `Customize.Logger.Enabled = true`, every bot writes structured NDJSON telemetry to `<OHA>/bots/logs/match_<timestamp>.ndjson` — flushed per event so kill-stream, deaths, intent transitions, and minion-stuck reports land in the file the moment they happen.

This skill triages the latest log automatically and reports back specific bot anti-patterns with suspected causes + suggested fixes. The goal: the user shouldn't have to watch the game and tell Claude what's broken.

## Workflow

### 1. Run the review

Always invoke from the guineapig repo because that's where `sim.review` lives:

```bash
cd "C:\Users\User\Desktop\Dota2 Guineapig extreme" && python -m sim.review --json
```

`sim.review` auto-discovers the most recently modified `match_*.ndjson` in:
- `C:\Users\User\Desktop\Dota 2 Open Hyper AI\bots\logs\`
- (fallback) Steam install paths

It returns a JSON object with this shape:

```json
{
  "log_duration_sec": 2400,
  "total_ticks": 480,
  "kills_logged": 14,
  "deaths_logged": 12,
  "intent_transitions": 47,
  "findings": [
    {
      "id": "minion.idle.forged_spirit",
      "severity": "high",
      "score": 8,
      "when": 420,
      "who": "forged_spirit",
      "message": "...",
      "suspected_cause": "...",
      "suggested_fix": "..."
    }
  ]
}
```

### 2. Handle the no-log case

If `sim.review` fails with "No console.log found" or returns empty findings with a "no [ABA_LOG] records found" note, two things to check:

> **Logger not capturing.** For telemetry to land in `console.log`, two requirements:
>
> 1. Dota 2 launch options must include `-condebug`. In Steam: right-click Dota 2 → Properties → Launch Options → add `-condebug`.
> 2. `bots/Customize/general.lua` must have `Customize.Logger.Enabled = true` (default after Phase 12).
>
> Then play a match. Output goes to `<Steam>/steamapps/common/dota 2 beta/game/dota/console.log` and is appended live (mid-match `tail -f` works).

Don't try to read the in-game console manually — `sim.review` already extracts records via the `[ABA_LOG]` prefix.

### 3. Present findings

Sort findings by `score` descending, then by `when` ascending. Group by severity bracket:

- **CRITICAL / HIGH** (score ≥ 7) — these get rendered first and prominently
- **MEDIUM** (score 4-6) — second tier
- **LOW** (score 1-3) — only mention if there's nothing higher

For each finding render exactly:

```
[<SEVERITY>/<score>] m<MM>:<SS>  <who>: <message>
   cause:    <suspected_cause>
   fix:      <suggested_fix>
   touch:    <best-guess Lua file path based on suggested_fix text>
```

The `touch:` line is the value-add — extract a likely file path from the `suggested_fix` text. Common patterns:
- "MinionThink for forged_spirit" → `bots/BotLib/hero_invoker.lua`
- "computePlan / mode_*.lua GetDesire" → `bots/FunLib/aba_teamplan.lua` or `bots/mode_*.lua`
- "scout-delegation gate in mode_roshan_generic.lua" → `bots/mode_roshan_generic.lua`
- "SkillsComplement / ConsiderX hooks" → `bots/BotLib/hero_<name>.lua` (extract hero name from `who`)
- "TACTIC_COOLDOWN / aba_commitment" → `bots/FunLib/aba_commitment.lua`

If you can't confidently extract a file path, omit `touch:` rather than guess.

### 4. Summary header

Top of the report, give a one-line match summary:

```
Match: <duration>min, <kills> kills, <deaths> deaths, <intents> intent flips. <N> issues found.
```

Then the findings.

### 5. Offer the fix

After listing all findings, end with one offer — the highest-severity finding's suggested fix. Format:

> **Top priority fix:** `<touch path>` — `<short description>`. Want me to do it now?

If there are no findings:

> Nothing flagged. Bots playing within tolerances on this log.

If the user says yes, navigate to the `touch:` file, read the relevant function, apply the suggested fix, and run `python -m sim.run_sim` from the guineapig repo to confirm regressions hold.

## Why this matters

Without this skill the workflow is: user plays a match, watches a bot do something dumb, types out a description of the bug, asks Claude to fix it. That round-trip is slow and lossy — the user might miss subtle anti-patterns the diagnostic catches automatically (intent thrashing, kill droughts, scout-delegation leaks).

With this skill: user types `review`, Claude runs the diagnostic, presents prioritized issues with file pointers, and immediately offers to fix the worst one. The whole cycle is seconds.

## Anti-pattern catalog

The diagnostic in `sim/diagnose.py` currently checks for:

| ID prefix | What it detects |
|-----------|-----------------|
| `minion.idle` | Forged spirits / illusions standing still (multiple `minion_stuck` events) |
| `bot.paralyzed` | Bot has `mode_desire = 0` or `intent = null` for >20s post-laning |
| `rosh.redundant_scout` | Bots besides the delegated scout entered the rosh pit within 60s of delegation |
| `push.no_progress` | `push_lane` intent fired but no `tower_fall` event within 60s |
| `smoke.not_grouped` | `smoke_gank` intent fired with team spread >2500u |
| `kill.drought` | 8+ minute mid-game stretch with zero kills/deaths |
| `intent.thrashing` | Team intent flips faster than 4s avg |
| `death.serial` | Single hero died ≥8 times |
| `ability.no_cast` | Hero cast <5 abilities in 20+ min match |

If the user wants a NEW check added, edit `sim/diagnose.py` `ALL_CHECKS` list and add a function returning `list[Finding]`.

## Don't

- Don't run `sim.review` without the `--json` flag — text mode is for the user, not Claude.
- Don't try to interpret raw NDJSON yourself — that's what `sim.diagnose` is for.
- Don't fabricate findings if `sim.review` returns none. If the report is empty, say so.
- Don't run a full `sim.run_sim` regression sweep just to triage one match log — that's a separate workflow.
