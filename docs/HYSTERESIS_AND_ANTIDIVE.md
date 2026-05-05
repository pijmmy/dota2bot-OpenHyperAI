# Hysteresis + anti-dive architecture

Two unified utility modules that solve recurring bug classes in this
codebase. When making behavioral changes, USE these utilities instead
of writing inline copies of the same patterns. Audit (May 2026) found
8 oscillation sources and 10 tower-dive sources scattered across the
codebase — the patterns were copy-pasted with subtle variations,
which made fixes incomplete.

---

## Bug class 1: oscillation

### Why it happens

Per-tick decision functions (GetDesire / Think / Consider*) recompute
their output every frame from the current game state. If the input has
noise (ally count near edge of detection radius, enemy HP wobbling on
regen ticks, last-seen timestamp crossing the 5s window, two
similar-scoring targets), the OUTPUT alternates each frame. The bot
oscillates: action toggles, attack target flickers, retreat then
attack then retreat each tick.

User-visible symptom: "they toggle or get stuck sometimes going
backwards and forwards."

### The utility: `bots/FunLib/aba_hysteresis.lua` (J.Hysteresis)

Three primitives:

#### `J.Hysteresis.StickyTarget(pid, fresh, freshScore, lockSec, upgradeMul, domain)`

Caches the last-picked target per bot for `lockSec` seconds (default
1.5s). Re-picks only when:
- lock window expired, OR
- cached target invalid (dead/illusion/can't be seen), OR
- new pick scores >= cached.score * upgradeMul (default 1.5x — clear upgrade)

**Use for:** target-picking inner loops where the engine returns
arrays sorted by distance/HP that flicker between similarly-ranked
units.

**Application sites:**
- `bots/FunLib/aba_defend.lua` DefendThink hero target picker
  (domains "defend_hub" + "defend_nby")
- `bots/mode_farm_generic.lua` Think neutral creep picker (4 callsites
  via `pickStickyFarmNeutral` helper, domain "farm_neutral")
- *(legacy inline copies that should migrate to this utility:
  `bots/FunLib/override_generic/mode_attack_generic.lua`
  `_lastAttackTarget`, `bots/FunLib/aba_push.lua` `_lastSpecialTarget`,
  `bots/FunLib/aba_defend.lua` `_lastDefendCreep`,
  `bots/mode_team_roam_generic.lua` `SetStickyTarget`. They work; just
  not unified.)*

#### `J.Hysteresis.StickyGate(pid, gateName, fresh, holdSec)`

Boolean gate that holds for `holdSec` seconds (default 1.5s) before a
flip is allowed.

**Use for:** binary gates that flicker around a threshold ("am I
outnumbered?", "is the team grouped?", "should I engage?").

**Application sites:**
- `bots/mode_team_roam_generic.lua:165` ally>=enemy "engage" gate
  (gateName `"team_roam_engage"`, hold 1.5s)

#### `J.Hysteresis.StickyDesire(pid, modeTag, fresh, alpha)`

EMA-smoothed desire. Lower alpha = more smoothing.
`new = old * (1 - alpha) + fresh * alpha`. Default alpha = 0.30.

**Use for:** mode-level desires that swing high<->low between ticks.

**Application sites:**
- `bots/mode_retreat_generic.lua:124` retreat desire (modeTag
  `"retreat"`, alpha 0.30) — pairs with mode_attack's existing inline
  EMA so attack<->retreat oscillation damps.

---

## Bug class 2: tower diving

### Why it happens

`mode_attack_generic.lua` has anti-dive guards in GetDesire and Think,
but **the bot has many other paths to a tower-range location**:

- Items: `item_blink` combat path (every blink-init hero), Force
  Staff "push enemy toward self" path
- Modes: focus override in `mode_team_roam` / `mode_roam` (commit_kill
  intent walks bot toward focused target wherever that is)
- Hero abilities: Storm Spirit Ball Lightning destination, Spirit
  Breaker Charge of Darkness target, Earthshaker Blink Slam, Magnus
  Blink RP, Tiny Blink Toss, Centaur Hoof Stomp (forces melee
  proximity), Axe Berserker's Call

Each used to have its OWN (often missing) tower-proximity check.

User-visible symptom: "the bots just dive the towers."

### The utility: `bots/FunLib/aba_safezone.lua` (J.Safezone)

#### `J.Safezone.IsLocSafeFromEnemyTowers(loc, marginUnits)`

Cheap predicate. Returns true if `loc` is outside every alive enemy
tower's attack range + margin (default safe radius = 750u =
TOWER_ATTACK_RANGE 700 + buffer 50).

#### `J.Safezone.WouldDiveIfMovedTo(bot, loc, marginUnits)`

State-aware predicate. Returns true if moving `bot` to `loc` would
expose it to tower fire AND bot lacks an immortal frame
(BT/Satanic/WK/Dazzle grave/Oracle promise/Omni ult/IsAttackImmune)
AND bot's effective HP buffer is below 700 (~2 tower hits).

**Use for:** Consider* / item-usage paths that compute a destination
location BEFORE committing the action.

**Application sites:**
- `bots/ability_item_usage_generic.lua` item_blink combat path
  (line ~1619 — destination shifted to safe-distance fallback if
  primary location dives)
- `bots/mode_team_roam_generic.lua` focus attack-target override
  (line ~351 — skips the override if focus location is dive)
- `bots/mode_roam_generic.lua` focus attack-target override
  (line ~172 — same pattern as team_roam)
- `bots/BotLib/hero_storm_spirit.lua` ConsiderBallLightning combat
  zip (line ~454 — BL destination skipped if it dives)
- `bots/BotLib/hero_spirit_breaker.lua` ConsiderChargeOfDarkness
  IsGoingOnSomeone branch (line ~226 — charge target skipped if
  landing zone dives)

#### `J.Safezone.EstimateTowerDPS(bot, loc, withinSec)`

Damage estimate. Returns expected tower damage at `loc` over
`withinSec` seconds, applying armor/magic-resist via
`GetActualIncomingDamage`. Use when a Consider* function wants a
dose-response gate (e.g. "abandon dive if estimated DPS > X").

---

## Adding a new application site

When implementing a new behavioral change that picks a target / sets
a destination / gates engagement:

1. **Identify the noise source.** What tick-to-tick state change can
   flip the output?
2. **If it's a target / destination / boolean / desire:** use the
   matching primitive above. Don't write a new sticky cache inline.
3. **If it's a movement to a destination:** add
   `J.Safezone.WouldDiveIfMovedTo` before issuing the move. Suppress
   or reroute on dive.
4. **Add a verify-harness test.** See `verify/test_hysteresis.py` and
   `verify/test_safezone.py` for the patterns.

## Engine API reference

The primitives use these engine APIs (documented at
<https://docs.moddota.com/lua_bots/>):

- `GetTeamMember(i)` — i in [1, 5], returns the bot at slot i or nil
- `bot:GetPlayerID()` — used as cache key in StickyTarget/StickyGate
- `bot:GetNearbyTowers(radius, bEnemies)` — used in safezone
- `bot:HasModifier(name)` — used for immortal-frame detection
- `bot:GetActualIncomingDamage(dmg, type)` — used in DPS estimate
- `bot:WasRecentlyDamagedByTower(sec)` — orthogonal signal; safezone
  uses position-based checks instead of "have I been hit yet"

## Audit reference

Initial audit + lineage in `docs/SOURCES.md`. Subsequent application
work is tracked in commit history; search for "audit:" comments in
the Lua to find the file:line citation each gate references.
