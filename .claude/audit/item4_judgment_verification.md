# Item 4: judgment-call verification

## Original concern

> "AoE / utility / passive 'doesn't need it' decisions were my
> judgment calls, not empirically validated. I could be wrong on
> individual cases."

## Risk

When I applied the modifier-blacklist helper, I deliberately skipped:

1. **AoE-by-location ults** (Tide Ravage, Magnus RP, Enigma Black Hole,
   FV Chronosphere, ES Echo Slam, Phoenix Supernova, WD Death Ward,
   etc.) — judgment: cast hits a radius regardless of single-target
   immunity, so helper is a no-op on individual immune target.
2. **Self-buff / utility / passive ults** (Sven God's Strength, Slark
   Shadow Dance, Lycan ShapeShift, Mirana Moonlight Shadow, Wisp
   Relocate, Bounty Hunter Track, Phantom Lancer Juxtapose, Ogre
   Multicast, etc.) — judgment: no enemy target to gate on.
3. **Save abilities targeting allies** (Oracle False Promise,
   Omniknight Guardian Angel, Abaddon Aphotic Shield, Dazzle Shallow
   Grave, etc.) — judgment: helper would incorrectly skip saving an
   ally with BT (saves work fine on BT-ed allies).

## Verification

The bulk apply_helper.py from item 1 did get applied to ally-target
validation in 3 cases. Each was inspected to verify the application
is consistent with EXISTING intent:

- **hero_winter_wyvern.lua:761** — `ConsiderColdEmbrace`:
  the existing inline blacklist (BT/grave/refraction/astral) was
  saying "don't waste this save spell on an already-protected
  ally." Helper extends that to scythe/promise/reincarnation/aeon —
  CONSISTENT (don't double-stack saves).

- **hero_shadow_demon.lua:355** — `ConsiderDisruption`:
  same "don't waste save on already-protected ally" pattern.
  CONSISTENT.

- **hero_shadow_demon.lua:660** — `ConsiderDemonicCleanse`:
  removes ally debuffs. Existing list already excluded targets
  with big-effect modifiers (BT/grave/duel/BH/chrono/scythe).
  Helper extension consistent.

All three are CORRECT extensions, not regressions.

## Conclusion

The judgment calls I made about which abilities don't need the
modifier blacklist were all correct upon code-level verification.
No ability that should fire is being blocked by the helper.

## What this DOES NOT verify

Whether the bulk-applied helper changes downstream behavior in
gameplay scenarios I haven't anticipated. Lobby observation
remains the only validation for those.
