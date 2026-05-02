# Dota 2 Bot Scripts - Claude Code Guide

## Project Overview

This is the **dota2bot-OpenHyperAI** project -- Lua bot scripts for Dota 2 that run in custom lobbies. Currently supports Patch 7.41/7.41a with 127 heroes.

## Key Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** -- Complete codebase architecture, file map, naming conventions, all systems explained
- **[docs/PATCH_UPDATE_GUIDE.md](docs/PATCH_UPDATE_GUIDE.md)** -- Step-by-step runbook for updating when a new Dota 2 patch drops

**Read these docs FIRST before making any changes.** They contain everything needed to make targeted updates without scanning the entire repo.

## Engineering discipline (read every session — non-negotiable)

Bot bugs in this codebase are almost never "syntax wrong." They are
"the desire / intent / target / threat-count calculation flips between
ticks because two inputs disagree, or one gate is too strict, or one
counter includes things it shouldn't." That means **shipping a code
change is not a fix**. A fix is when you have traced the specific
scenario through the actual code path and confirmed which gate now
fires (or doesn't) that didn't before.

### Hard rules

1. **Do not lead with "Sim 64/64 green" when the user reported a
   behavior bug.** The sim suite (`python -m sim.run_sim` in the
   guineapig repo) tests structural properties — function existence,
   intent priorities, multiplier-envelope clamps. It does **not** test
   whether Doom ults, whether bots respond to pings, whether bots
   dither at brood spiders, or whether Tide ravages. Sim green +
   behavior bug present = sim is silent on the bug. Saying "sim green,
   ready to test" misleads the user into thinking the problem is solved.

2. **Trace before shipping.** Before every fix to a hero / mode /
   teamplan file, mentally run a concrete scenario through the code:
   *"Bot X is in mode Y at minute Z, sees enemy A at distance D with
   HP H — walk through each gate."* Identify the specific line that
   fired/failed and put the trace in the commit message. If you can't
   trace it, you don't yet understand the bug — keep reading.

3. **Audit the bug class, not just the named instance.** When fixing
   pattern X in file Y (e.g. the `+2 advantage` gate in Doom's
   `ConsiderDoom`), grep the rest of `bots/BotLib/` for the same
   pattern and report findings in the same session. The user is
   almost always reporting one instance of a recurring pattern.

4. **No "go" loops.** Don't ship a small change, claim it works, ask
   the user to test, repeat. The user is paying for engineering, not
   chat. If the work is days, say "days" upfront and structure as
   audit → trace → verified-fix-batch → ship — not patch → patch →
   patch with "going" between each.

5. **Verify or admit.** For each shipped fix, in the commit message,
   declare: (a) what code path was traced, (b) under what scenario,
   (c) what specific change in behavior is now expected. If you didn't
   verify by tracing, say so explicitly: *"shipped on framework
   reasoning only, not traced through a concrete scenario."* Don't
   pretend.

6. **Dithering is always a bug.** Any time bots toggle behavior between
   ticks (target flip, attack-then-retreat-then-attack, two-anchor
   oscillation), the root cause is per-tick decision recomputation
   without hysteresis, OR a counter/threshold that includes things it
   shouldn't (summons treated as enemies, illusions counted as heroes,
   stale visibility data). Don't tune around it; find the input that
   keeps changing.

### Anti-patterns that have caused regressions in this project

- **"Framework fix should help X downstream callers."** Every
  downstream caller has its own gates. Broadening `IsGoingOnSomeone`
  doesn't make Tide ravage if Tide's `ConsiderRavage` has its own
  bugs. If you didn't read the downstream callers, the fix is unverified.
- **Multipliers stacked into ModulateDesire without tracing the chain.**
  Phase 11 shipped 9 modules into `J.Personality.ModulateDesire` this
  way; several actively hurt gameplay because no one walked through the
  ~8 stacking factors per call to see how they interacted.
- **"Sim 64/64 green"** quoted as evidence the user's bug is fixed.
  See rule 1.
- **Pattern-matching** (*"this looks like it might be the issue"*)
  without tracing the gate-by-gate flow. Almost always produces
  half-fixes that the user discovers in lobby and reports back.

### Vocabulary

- **Drop "fair", "right", "good question", "got it", "alright" and
  other agreeable-teenager openers.** Open with the substance.
- Don't say *"going, this is hours"* and then ship incremental patches
  across multiple sessions. That math doesn't add up to fixed.
- When the work is genuinely days, say *"this is days of work, here is
  what days one and two look like"* — not *"hours."*

### Banned phrases (mechanically enforced via Stop hook)

The following are blocked in stop-time replies. They look like honest
disclosure but they're sandbag phrases that signal chat-loop drift. The
Stop hook (`.claude/hooks/check_stop_sandbag.sh`) will reject the reply
and force a rewrite if any appear:

- "still not done" / "haven't audited" / "haven't verified" / "haven't fixed"
- "needs lobby test" / "needs lobby verification" / "needs lobby observation"
- "want me to keep going" / "should I continue/proceed/keep going"
- "ready to test" / "ready to play" / "ready to push" / "ready to merge"
- "boot a lobby" / "test in a lobby" / "test it now" / "test and tell me"
- "sim 64/64 green" / "all checks pass" / "all tests pass" (when leading
  with this on a behavior-bug report)
- Opening with "fair", "right", "got it", "alright", "ok", "gotcha"
- "let me commit" / "committing now" / "pushed [state of...]" mid-task

The override is to actually finish the work. The hook is not gameable.

### Finished-state contract (mechanically enforced via PreToolUse hooks)

**Every commit must include a `## Trace` or `Trace:` section** describing
the concrete scenario walked through the code, what gate fires/doesn't,
and what changes behaviorally. The commit-trace hook
(`.claude/hooks/check_commit_trace.sh`) blocks commits without it.
Exception: `chore:` / `docs:` / `trivial:` / `typo:` prefixes for
non-code changes.

**Every `git push` requires the `.claude/work-complete` marker file.** The
push-gate hook (`.claude/hooks/check_push_marker.sh`) blocks pushes when
the marker is absent. The marker is auto-deleted on successful push, so
each batch must explicitly re-create it.

The workflow is:
  1. User defines a batch of work.
  2. Do all of it. No mid-batch commits-and-pushes for "checkpoints."
  3. When done, write a one-line summary to `.claude/work-complete`.
  4. Push.

If you're tempted to push partial work — stop. Keep doing the work.

### Frustration response (mechanically enforced via UserPromptSubmit hook)

When the user uses frustration markers ("FINISH", "lazy", "do better",
"shitty", "FFS", etc.), the UserPromptSubmit hook
(`.claude/hooks/inject_discipline_on_frustration.sh`) injects this
discipline reminder into context before your prompt. You don't need
to remember it manually — it auto-injects. But knowing it auto-injects
means: when the user is angry, the discipline rules are already
re-loaded, so you have NO excuse to drift.

## Common Tasks

### Check for New Patches

To check if there are patches we haven't updated for:
1. Fetch `https://www.dota2.com/datafeed/patchnoteslist?language=english`
2. Compare latest version against "Last updated for" in `docs/PATCH_UPDATE_GUIDE.md`
3. If newer patch exists, follow the update process below

### Patch Update (most common)

When user says "update for patch X.XX" or provides patch notes:

1. Read `docs/PATCH_UPDATE_GUIDE.md` for the step-by-step process
2. Fetch patch data: `https://www.dota2.com/datafeed/patchnotes?version=X.XX&language=english`
3. Fetch d2vpkr data (shops.txt, neutral_items.txt) for authoritative item/ability names
4. **Categorize changes**: STRUCTURAL (need code) vs NUMBER-ONLY (game API handles) vs TALENT SWAPS
5. **Always verify ability names on Liquipedia** -- patch note summaries can be wrong
6. Follow the checklist in order: items -> hero builds -> abilities -> neutrals -> actives -> map changes
7. **Always update TS sources** for any TS-generated Lua files changed (see ARCHITECTURE.md Section 13)

### Add a New Hero

1. Copy a similar existing hero from `bots/BotLib/` as template
2. Add to `FretBots/HeroNames.lua`, `FunLib/aba_hero_roles_map.lua`, `FunLib/spell_list.lua`
3. See "New Heroes" section in `docs/PATCH_UPDATE_GUIDE.md`

### Fix a Hero's Item Build

1. Read `bots/BotLib/hero_[name].lua`
2. Edit the `sRoleItemsBuyList['pos_N']` arrays
3. Items use `item_[internal_name]` format -- check `FunLib/aba_item.lua` for valid names

### Fix a Hero's Ability Logic

1. Read `bots/BotLib/hero_[name].lua`
2. The `SkillsComplement()` function controls ability casting priority
3. Each ability has a `ConsiderX()` function returning desire + target
4. See "Skill / Ability System" in `docs/ARCHITECTURE.md`

## Important Rules

- **Use `GetItemComponents()` for item recipes** -- don't hardcode component arrays
- **Use `sAbilityList[N]` references** when possible -- resilient to ability renames
- **Always update BOTH neutral item files** (Buff/ AND FretBots/)
- **Verify on Liquipedia** before trusting patch note summaries about ability names
- **Test in-game** after changes -- some things can only be verified at runtime

## Personality System

Per-bot personality traits that modulate mode desires + draft picks, so bots of the same hero feel different across games and different heroes lean into natural playstyles (rats rat, fighters fight).

- Core: `bots/FunLib/aba_personality.lua` (+ TS source). Exposed as `J.Personality.*`.
- Archetypes: `bots/FunLib/aba_hero_archetypes.lua` -- 127-hero data, derived from role map with ~100 manual overrides.
- Desire hooks: every pure-Lua mode file + `mode_push_tower_*` / `mode_defend_tower_*` wrappers modulate via `J.Personality.ModulateDesire(bot, desire, tag)`.
- Draft bias: `hero_selection.lua` uses `J.Personality.GetDraftAffinity` as a 5th scoring factor.
- FretBots: amplifies tilt effects x1.4 via `SetFretBotsMode(true)`.
- See `docs/ARCHITECTURE.md` section 15 for full details.

**When tweaking hero playstyle**: edit the archetype override in `bots/FunLib/aba_hero_archetypes.lua` AND the TS source `typescript/bots/FunLib/aba_hero_archetypes.ts`. Keep them in sync -- if Node is installed and `npm run build` runs later, TSTL regeneration will otherwise overwrite hand edits.

## Team Plan Layer

Single canonical team intent per tick (defend_base / defend_lane / **commit_kill** / contest_rosh / push_lane / smoke_gank / regroup / farm) — biases bot mode desires so the team acts coordinated rather than 5 independent agents. Integrated into `J.Personality.ModulateDesire`, so mode hooks get team-plan bias automatically.

- Core: `bots/FunLib/aba_teamplan.lua` (+ TS source). Exposed as `J.TeamPlan.*`.
- Bots with high `teamSpirit` follow the plan closely; low `teamSpirit` mostly ignore it (preserves individual variance).
- See `docs/ARCHITECTURE.md` section 16.

## Focus Target + Kill Commit

Per-team priority enemy target based on isolation/HP/value; when ≥2 allies are near the focus, team-plan flips to `commit_kill` intent which massively biases team_roam/roam desires (bots converge on the target, farm/retreat desires drop).

- Core: `bots/FunLib/aba_focus.lua` (+ TS source). Exposed as `J.Focus.*`.
- Hook point for hero files: `J.Focus.GetFocusIfInRange(bot, range)` returns the team's focus if in range (for overriding attack target selection). Not yet adopted in hero files.
- See `docs/ARCHITECTURE.md` section 18.

## Save-Ally + Enemy-Focus Defense

Defensive mirror of the focus system. Detects when enemies commit on one of our allies -> triggers `save_ally` team intent -> bots collapse defensively + save spells fire on the right ally.

- Core: `bots/FunLib/aba_enemy_focus.lua` (J.EnemyFocus.*) + `bots/FunLib/aba_save.lua` (J.Save.*).
- Triggers on EITHER 2+ attackers on ally OR big-ult modifier on ally (Chrono/Ravage/Doom/etc.).
- Adopted in save heroes (Dazzle/Oracle/Omni/Abaddon/Treant/Wyvern/Snapfire) and save items (Force/Glimmer/Lotus).
- See `docs/ARCHITECTURE.md` section 20.

## Channel Interrupt + Late-Game Grouping

Two important patches:
- Channel interrupt: at top of `mode_roam` / `mode_team_roam` Think, force-attack any enemy `IsChanneling()`. Cancels Black Hole / Freezing Field / Shackles / etc.
- Late-game group (intent): after 25min, team plan becomes `late_game_group` with location = Ancient. Bots assemble defensively instead of split farming.
- Opening flavor variance: rolled per-match, gives different early-game behaviors.
- Assemble mode fix: previously only responded to human pings; now reads team-plan location for `late_game_group / save_ally / contest_rosh / contest_tormentor / defend_base / defend_lane`.
- See `docs/ARCHITECTURE.md` section 21.
