# External reference sources for bot decision logic

When making non-trivial behavioral changes (target picking, retreat
gates, push/defend triggers, dive avoidance), check at least one
authoritative external source before relying on judgment. Don't reinvent
patterns the lineage already solved.

---

## Lineage of this project

This fork descends from forest0xia/dota2bot-OpenHyperAI, which itself
combines several earlier community scripts (per its README credits):

- **New Beginner AI** by `dota2jmz@163.com` — origin of `FunLib/jmz_func.lua`
- **Ranked Matchmaking AI** by `adamqqq` — origin of the `aba_*` modules
- **Tinkering ABout** by `ryndrb`
- **fretbots** by `fretmute` (difficulty scaler, in `FretBots/`)
- **BOT Experiment** by `Furiospuppy`
- **ExtremePush** by `insraq`

When something looks legacy or confusing, check the original first. It
often has reasoning that doesn't survive in the fork.

---

## Tier 1 — must read

### ModDota Lua (Bots) API documentation
<https://docs.moddota.com/lua_bots/>
Canonical reference for `CDOTA_Bot_Script` methods. Has the exact
signatures + argument units for every primitive used in mode files:
`WasRecentlyDamagedByTower`, `GetNearbyTowers`, `WasRecentlyDamagedByCreep`,
`GetActualIncomingDamage`, `GetIncomingTrackingProjectiles`, etc.

### Valve Developer Community — Dota Bot Scripting wiki
<https://developer.valvesoftware.com/wiki/Dota_Bot_Scripting>
Documents the **3-tier decision-making model** the project inherits:
team_desires → mode_X → Action_X. Confirms `Think()` is per-frame and
fog-of-war is enforced.

### forest0xia/dota2bot-OpenHyperAI (direct upstream)
<https://github.com/forest0xia/dota2bot-OpenHyperAI>
Check upstream's recent commits before fixing. They may have already
solved the same bug, or you may want to pull a regression-fix back.

### adamqqqplay/dota2ai — "Ranked Matchmaking AI"
<https://github.com/adamqqqplay/dota2ai>
Origin of every `aba_*.lua` pattern in this fork. Frozen at v1.7.16
(Dec 2023), so a stable reference. When confused by an `aba_*`
function, compare its body to the original.

---

## Tier 2 — useful for cross-reference

### ryndrb/dota2bot — "Tinkering ABout"
<https://github.com/ryndrb/dota2bot>
Independent fork from a parallel lineage. Sanity check for "is this
mode-desire pattern broken or just unfamiliar?"

### Yewchi/vulft — VUL-FT
<https://github.com/Yewchi/vulft>
Independent full-takeover bot. Has patterns NOT in our lineage worth
porting — notably:
- "Enemy fight intent is tracked and **loses magnitude based on
  facing direction**" → directly applicable to anti-dive (target
  facing away = lower threat = OK to attack; facing me = high threat
  = pull back).
- "Dynamic retreat — to friendly towers OR to friendly allies in the
  direction of the allied fountain" → cleaner retreat pattern than
  always-fountain.

### insraq/dota2bots — "ExtremePush"
<https://github.com/insraq/dota2bots>
Origin of TP-scroll-based push logic. Old (2017) but small enough to
read end-to-end if tracing push behavior.

### fretmute/fretbots
<https://github.com/fretmute/fretbots>
Already integrated as `FretBots/`. This is a **difficulty layer**,
not a decision layer — modifies gold/XP/items, not behavior. When
bots feel weak/strong, look here first.

---

## Tier 3 — pro decision rules to encode

### esports.net — How To Siege High Ground
<https://www.esports.net/wiki/guides/dota-2-high-ground/>
Encodable HG-siege rules:
- ~5+ levels lead vs counterpart before committing
- All T1/T2 must be down before T3 attempts
- Aegis significantly increases siege success
- BKB / damage / survivability item gates before commit
- Disengage after forcing cooldowns; reset
- If dead enemy has buyback gold, don't overextend
- Only the tower hitter sieges; counter-initiators stay hidden
- Anti-stack: spread out (avoid Echo Slam / Black Hole)

### Hotspawn — How To Defend High Ground
<https://www.hotspawn.com/dota2/guide/how-to-defend-high-ground-in-dota-2>
Encodable HG-defense rules:
- Tanky frontline at ramp/chokepoint (Centaur, Tide)
- Ranged carries behind frontliners
- Supports stay further back, ideally out of vision
- Mobile hero (NP, Storm) push-out farms map during siege
- Counter-init triggers (Wyvern, Phoenix) on enemy overextend
- Buyback advantage: defenders re-enter immediately
- Smoke wraparound as alternative to frontal-only

### Boosteria — Team Fight Positioning Fundamentals
<https://boosteria.org/guides/team-fight-positioning-fundamentals-dota-2>
Peel-vs-chase rules, hidden second-wave pattern, kite-and-reset.
Useful for encoding commit-vs-disengage gates.

### Dotabuff — What is High Ground Advantage?
<https://www.dotabuff.com/blog/2020-07-03-what-is-high-ground-advantage>
Mechanical fact: uphill 25% miss chance. The bot's threat calculation
during HG siege should account for this — attacking uphill at 75%
effective DPS changes the dive threshold math.

### Liquipedia Dota 2 Glossary
<https://liquipedia.net/dota2/Glossary>
Authoritative shared vocabulary (rotate / split-push / smoke gank
etc.). Use this when naming new functions / intents.

---

## Tier 4 — research / background

### OpenAI Five paper
<https://arxiv.org/abs/1912.06680>
~16k inputs per timestep, observation tree split global / per-hero /
per-unit. Useful for inspiring what to **observe**, not what to
**decide** — RL features don't translate to rule-based Lua directly.

### Wikipedia: OpenAI Five
<https://en.wikipedia.org/wiki/OpenAI_Five>
Project background; ended April 2019 with no continuation.

---

## Sources flagged as outdated / low quality

- developer.valvesoftware.com/wiki/Dota_2_Workshop_Tools/Scripting/API
  redirects to moddota — do not trust the URL.
- dota2.fandom.com community wiki — not authoritative.
- Ruoyu Sun 2017 quickstart — setup-only, 9 years old.
- shikyo13/Dota2AI — appears to be a mirror, no novel content.

---

## Notable absences

- No public OpenAI Five replication has shipped a working Lua-bot
  equivalent.
- The original jmz / "New Beginner AI" author has no discoverable
  standalone GitHub repo — the code only exists embedded in downstream
  forks.

---

## How to use these for a bug fix

1. **Identify which subsystem** (target picker, mode desire, push gate,
   defend gate).
2. **Check moddota first** for the right primitive + units (range in
   pixels? seconds? ticks?).
3. **Check the upstream lineage** (forest0xia → adamqqq → original
   author) to see how the pattern was meant to work.
4. **Cross-check VUL-FT** for an alternative implementation of the
   same problem.
5. **Encode Tier-3 pro rules** as desire multipliers / threshold gates,
   not as if-then narratives.
6. **Verify** via the `verify/` Python harness before shipping.
