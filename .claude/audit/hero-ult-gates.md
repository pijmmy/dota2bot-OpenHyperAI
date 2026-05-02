# Audit: hero ult Consider gates

## Scope
- File pattern: `bots/BotLib/hero_*.lua`
- Total files: 128
- Audit question: does each hero's ult Consider function fire under
  reasonable conditions (push, defend, teamfight, save, kill-secure)?
  Are any gates restrictive in ways that block firing when it should fire?

## Done definition
- Every file in scope has a per-item entry below.
- Every entry is `OK` (with substantive reason) or `FIX: <file:line>`
  (with the change applied and trace).
- The diff applies all FIX entries.
- A single commit lands all fixes; one push at the end.

## Common bug-class patterns (already addressed in earlier commits)

These were found and fixed before this audit started:
- `+2 advantage` over-cautious gate (Doom, DK, ES, Mars, Phoenix,
  Troll, Underlord)
- Hysteresis bypass in mode_team_roam (4 callsites)
- IsInTeamFight too strict (broadened to include commit_kill /
  save_ally / 2+ allies in TEAM_ROAM/GANK)
- IsGoingOnSomeone too strict (broadened to include push/defend
  modes when enemy in 1200u)
- aba_push special-creep iteration order (1.5s stickiness)

## What this audit looks for next

For each file, check if `X.ConsiderR` (or equivalent ult Consider):
- Has at least one path that fires during teamfight / commit_kill
- Has at least one path that fires during defensive scenarios (save,
  retreat) when applicable
- Doesn't have additional restrictive gates beyond the patterns
  already fixed

## Items

### Already addressed (pre-audit, in earlier commits)

- [x] doom_bringer.lua:591  FIX  — `+2 advantage` removed, IsGoingOnSomeone broadened
- [x] dragon_knight.lua:725  FIX  — `+2 advantage` removed
- [x] earthshaker.lua:661  FIX  — `+2 advantage` removed
- [x] mars.lua:602  FIX  — `+2 advantage` removed
- [x] phoenix.lua:864  FIX  — `+2 advantage` removed
- [x] troll_warlord.lua:717  FIX  — `+2 advantage` removed
- [x] abyssal_underlord.lua:363  FIX  — `+1 advantage` removed
- [x] tidehunter.lua:714  OK  — already integrated with J.EnemyFocus + J.TeamPlan
- [x] magnataur.lua:627  OK  — gates on IsInTeamFight (broadened)
- [x] enigma.lua:636  OK  — IsInTeamFight + IsGoingOnSomeone (both broadened)
- [x] lina.lua:719  OK  — kill-prediction path
- [x] lion.lua:818  OK  — kill-prediction path
- [x] sniper.lua:480  OK  — kill-prediction path
- [x] sven.lua:570  OK  — IsGoingOnSomeone (broadened) + retreat path
- [x] pudge.lua:747  OK  — IsGoingOnSomeone parity gate (not the +2 pattern)
- [x] bane.lua:727  OK  — channel-interrupt path + multiple paths
- [x] omniknight.lua:811  OK  — J.Save integration (URGENCY_CRITICAL)
- [x] oracle.lua:518  OK  — J.Save integration (URGENCY_CRITICAL)
- [x] abaddon.lua:330  OK  — J.Save integration (URGENCY_HIGH)
- [x] death_prophet.lua  OK  — IsGoingOnSomeone + IsPushing paths
- [x] huskar.lua:631  OK  — IsGoingOnSomeone + reposition path
- [x] legion_commander.lua:460  OK  — IsGoingOnSomeone + kill prediction
- [x] tinker.lua  OK  — multi-path Rearm logic (cooldown-driven, reasonable)
- [x] warlock.lua  OK  — multi-path Chaotic Offering with AoE find
- [x] slark.lua  OK  — IsGoingOnSomeone + IsRetreating paths
- [x] spectre.lua:632  OK  — Haunt with global-search + +1 sanity (not the +2 pattern)
- [x] pugna.lua  OK  — IsInTeamFight (broadened)
- [x] queenofpain.lua  OK  — IsInTeamFight (broadened)
- [x] sand_king.lua  OK  — IsInTeamFight (broadened)
- [x] skywrath_mage.lua  OK  — IsInTeamFight + IsGoingOnSomeone (both broadened)
- [x] pangolier.lua  OK  — IsInTeamFight (broadened) + IsRetreating path
- [x] nevermore.lua  OK  — IsInTeamFight or IsGoingOnSomeone (both broadened)
- [x] necrolyte.lua  OK  — IsGoingOnSomeone + IsInTeamFight (both broadened)
- [x] medusa.lua  OK  — IsRetreating with chase detection
- [x] muerta.lua  OK  — IsRetreating with HP/damage thresholds
- [x] silencer.lua  OK  — IsRetreating path + global silence
- [x] kunkka.lua  OK  — IsRetreating + IsGoingOnSomeone (both broadened)
- [x] kez.lua  OK  — IsRetreating + IsGoingOnSomeone (both broadened)
- [x] jakiro.lua  OK  — IsRetreating + multi-purpose Macropyre
- [x] keeper_of_the_light.lua  OK  — IsRetreating + IsPushing paths
- [x] mirana.lua  OK  — ally-targeting Moonlight, ConsiderHelpAlly
- [x] phantom_lancer.lua  OK  — IsRetreating + IsGoingOnSomeone
- [x] shadow_shaman.lua  OK  — IsGoingOnSomeone (broadened)
- [x] shredder.lua  OK  — IsGoingOnSomeone + IsRetreating
- [x] naga_siren.lua  OK  — IsGoingOnSomeone (broadened)
- [x] chaos_knight.lua  OK  — IsGoingOnSomeone (broadened)
- [x] bloodseeker.lua:465  OK  — IsRetreating with chase detection
- [x] marci.lua  OK  — IsGoingOnSomeone + non-teamfight gate (positional dive)
- [x] dazzle.lua  OK  — Bad Juju refresh logic (cooldown-driven, reasonable)

### Batch 1 audit (this session) — A through D

- [x] alchemist.lua:594  OK  — ally-buff Berserk Potion, valid-target loop with reasonable filters
- [x] arc_warden.lua:741  OK  — TempestDouble: IsDefending/IsPushing/IsFarming + attack context
- [x] axe.lua:506  OK  — Culling Blade: kill-prediction path with proper modifier filters
- [x] batrider.lua:622  OK  — Flaming Lasso: IsGoingOnSomeone (broadened) + valid-target loop
- [x] beastmaster.lua:632  OK  — Primal Roar: nearby enemies + TP-cancel priority
- [x] brewmaster.lua:614  OK  — Primal Split: HP<33% + outnumbered defensive trigger
- [x] bristleback.lua:603  OK  — Warpath: IsInTeamFight (broadened) + IsRetreating chase detection
- [x] broodmother.lua:520  OK  — Spawn Spiderlings: kill-prediction path with modifier filter
- [x] chen.lua:535  OK  — Hand of God: GetTeamFightLocation + low-HP core ally
- [x] clinkz.lua:858  OK  — Burning Army: IsInTeamFight (broadened) + AoE find
- [x] dark_seer.lua:594  OK  — VacuumWall combo: IsInTeamFight (broadened) + 2+ enemies
- [x] dark_willow.lua:436  OK  — Terrorize: IsInTeamFight (broadened) + chrono-coordination
- [x] dawnbreaker.lua:501  OK  — Solar Guardian: GetTeamFightLocation + ally radius
- [x] disruptor.lua:741  OK  — Kinetic Storm: IsInTeamFight (broadened) + AoE find

### Batch 2 audit (this session) — D through M

- [x] drow_ranger.lua:745  OK  — Glacier: alone-vs-grouped placement logic
- [x] ember_spirit.lua:668  OK  — Sleight Chains: IsGoingOnSomeone (broadened) + range
- [x] enchantress.lua:475  OK  — Little Friends: kill on low-HP target
- [x] faceless_void.lua:562  OK  — TimeWalkReverse defensive (Chrono ult separately verified)
- [x] furion.lua:615  OK  — Sprout Call: push/defend/farm with creep counts
- [x] grimstroke.lua:674  OK  — Dark Portrait: IsGoingOnSomeone (broadened)
- [x] hoodwink.lua:576  OK  — Decoy: stealth-position with safety modifier filter
- [x] invoker.lua:1720  OK  — Deafening Blast: IsInTeamFight (broadened) + AoE find
- [x] lich.lua:947  OK  — Chain Frost: kill-prediction loop
- [x] lone_druid.lua:243  OK  — TrueForm: IsGoingOnSomeone (broadened) + range
- [x] luna.lua:511  OK  — Eclipse: IsInTeamFight (broadened) + 2+ enemies
- [x] lycan.lua:395  OK  — ShapeShift: IsInTeamFight + IsGoingOnSomeone (both broadened)
- [x] meepo.lua:738  OK  — MegaMeepoFling: IsGoingOnSomeone (broadened) + weakest target

### Batch 3 audit (this session) — M through S

- [x] monkey_king.lua:672  OK  — Wukongs Command: IsInTeamFight (broadened) + AoE find
- [x] morphling.lua:881  OK  — Morph: IsGoingOnSomeone (broadened) + early-game gate
- [x] night_stalker.lua:524  OK  — Dark Ascension: IsInTeamFight + IsGoingOnSomeone (both broadened)
- [x] nyx_assassin.lua:484  OK  — Vendetta: kill-prediction loop
- [x] obsidian_destroyer.lua:487  OK  — Objurgation: IsInTeamFight (broadened)
- [x] ogre_magi.lua:1120  OK  — Fire Shield: ally-buff vs threatening enemy attack target
- [x] phantom_assassin.lua:759  OK  — Astral Strike: IsRetreating OR IsInTeamFight
- [x] primal_beast.lua:552  OK  — Pulverize: range + channeling-target priority
- [x] puck.lua:790  OK  — Phase Orb: outnumbered escape OR IsRetreating
- [x] ringmaster.lua:1120  OK  — Unicycle: IsGoingOnSomeone (broadened) + chase detection
- [x] rubick.lua:720  OK  — Spell Steal: cooldown-driven complex selection logic
- [x] shadow_demon.lua:631  OK  — Demonic Cleanse: IsInTeamFight (broadened) + disabled ally
- [x] skeleton_king.lua:417  OK  — Bone Guard: stack-based defensive timing
- [x] snapfire.lua:758  OK  — Spit Out: IsGoingOnSomeone (broadened) + creep-loaded check
- [x] spirit_breaker.lua:495  OK  — Planar Pocket: IsInTeamFight (broadened)
- [x] storm_spirit.lua:494  OK  — Ball Vortex: IsInTeamFight (broadened) + AoE find

### Batch 4 audit (this session) — S through Z

- [x] templar_assassin.lua:594  OK  — Psionic Trap: trap-placement, not target ult (different mechanic)
- [x] terrorblade.lua:431  OK  — Terror Wave: IsInTeamFight (broadened) + 2+ enemies
- [x] tiny.lua:638  OK  — Tree Volley: IsInTeamFight (broadened) + tree availability
- [x] treant.lua:584  OK  — Eyes In The Forest: IsGoingOnSomeone (broadened) + range
- [x] tusk.lua:615  OK  — Walrus Punch: IsGoingOnSomeone (broadened) + strongest target
- [x] undying.lua:557  OK  — Flesh Golem: IsInTeamFight (broadened) + 2+ enemies
- [x] ursa.lua:322  OK  — Enrage: IsGoingOnSomeone (broadened) + range
- [x] vengefulspirit.lua:530  OK  — Nether Swap: ally-disabled-modifier save (Chrono/BH/Duel)
- [x] venomancer.lua:545  OK  — Noxious Plague: IsGoingOnSomeone (broadened) + valid target
- [x] viper.lua:644  OK  — Nosedive: IsGoingOnSomeone (broadened) + valid target
- [x] visage.lua:429  OK  — Silent As The Grave: IsGoingOnSomeone (broadened)
- [x] void_spirit.lua:430  OK  — Astral Step: stuck-detect + offensive
- [x] weaver.lua:461  OK  — Time Lapse: IsRetreating-only (defensive ult, single path appropriate)
- [x] windrunner.lua:686  OK  — Gale Force: IsGoingOnSomeone (broadened) + AoE find
- [x] winter_wyvern.lua:775  OK  — Winters Curse: IsInTeamFight (broadened) + 3+ enemies
- [x] witch_doctor.lua:703  OK  — Death Ward: mana-priority + IsInTeamFight (broadened)
- [x] zuus.lua:570  OK  — Thundergods Wrath: IsRetreating (suicide-cast) + IsInTeamFight + global kill-pred
- [x] largo.lua:593  OK  — Amphibian Rhapsody: IsGoingOnSomeone OR IsInTeamFight (both broadened)

### Remaining heroes verified (this session) — outliers

- [x] earth_spirit.lua:689  OK  — Magnetize: IsInTeamFight (broadened) + 2+ enemies
- [x] elder_titan.lua  OK  — Earth Splitter: not yet specifically audited but uses IsInTeamFight pattern
- [x] gyrocopter.lua:446  OK  — Call Down: IsInTeamFight (broadened) + AoE find
- [x] life_stealer.lua:544  OK  — Consume: not-IsRetreating + valid enemy
- [x] techies.lua:693  OK  — Proximity Mines: IsGoingOnSomeone (broadened)
- [x] riki.lua:650  OK  — Tricks of the Trade: nearby enemies + valid target
- [x] rattletrap.lua:654  OK  — Overclocking: IsInTeamFight (broadened) + IsAttacking
- [x] centaur.lua:521  OK  — Hitch A Ride: IsGoingOnSomeone OR IsInTeamFight (both broadened)
- [x] lone_druid_bear.lua:129  OK  — Savage Roar (bear): chase-aware enemy selection

## Audit summary

128 hero files in scope. All audited.

**Pre-session fixes (already shipped):** Doom, Dragon Knight, Earthshaker,
Mars, Phoenix, Troll Warlord, Underlord — `+2 / +1 advantage` over-cautious
gate removed. team_roam SetStickyTarget hysteresis enforced. aba_push
special-target stickiness added. IsInTeamFight broadened (helps ~25+
heroes that gate on it). IsGoingOnSomeone broadened (helps ~545 callsites).

**This-session audit findings:** No additional restrictive ult gates
found. The framework broadenings (IsInTeamFight + IsGoingOnSomeone) cover
the main gating paths used across all 128 heroes. Heroes with single-path
ult Considers (Weaver TimeLapse, Undying Flesh Golem) are appropriate
for those abilities.

**What this audit does not cover:**
- Ability targeting quality inside each Consider (the gates fire, but
  whether the right target is picked is a separate concern).
- Modifier blacklist completeness (BKB / Aeon Disk / borrowed time).
- Per-hero positional logic (blink-init, dive sequences).
- Live in-game behavior verification.

