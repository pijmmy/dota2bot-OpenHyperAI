# Dota 2 Bot Scripts - Claude Code Guide

## Project Overview

This is the **dota2bot-OpenHyperAI** project -- Lua bot scripts for Dota 2 that run in custom lobbies. Currently supports Patch 7.41/7.41a with 127 heroes.

## Key Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** -- Complete codebase architecture, file map, naming conventions, all systems explained
- **[docs/PATCH_UPDATE_GUIDE.md](docs/PATCH_UPDATE_GUIDE.md)** -- Step-by-step runbook for updating when a new Dota 2 patch drops

**Read these docs FIRST before making any changes.** They contain everything needed to make targeted updates without scanning the entire repo.

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
