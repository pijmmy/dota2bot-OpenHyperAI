# Dota 2 Bot Architecture Guide

This document is the single source of truth for understanding, maintaining, and updating the dota2bot-OpenHyperAI codebase. It is designed so that a developer (or AI assistant) can quickly make targeted updates without re-scanning the entire repository.

Last verified against: **Patch 7.41a** (March 2026)

---

## Table of Contents

1. [Directory Structure](#1-directory-structure)
2. [Naming Conventions](#2-naming-conventions)
3. [Hero Bot Files](#3-hero-bot-files)
4. [Skill / Ability System](#4-skill--ability-system)
5. [Item System](#5-item-system)
6. [Neutral Item System](#6-neutral-item-system)
7. [Item Active-Use System](#7-item-active-use-system)
8. [Bot Behavior Modes](#8-bot-behavior-modes)
9. [FretBots (Enhanced Difficulty)](#9-fretbots-enhanced-difficulty)
10. [Customization System](#10-customization-system)
11. [Patch Update Checklist](#11-patch-update-checklist)
12. [External Data Sources](#12-external-data-sources)
13. [Common Pitfalls](#13-common-pitfalls)
14. [TypeScript to Lua (TSTL) Relationship](#13-typescript-to-lua-tstl-relationship)
15. [Personality System](#15-personality-system)
16. [Team Plan Layer](#16-team-plan-layer)
17. [Defend Tuning (PR 3)](#17-defend-tuning-pr-3)
18. [Focus Target + Kill Commit](#18-focus-target--kill-commit)
19. [Game Theory Layer](#19-game-theory-layer)
20. [Save-Ally + Enemy-Focus Defense](#20-save-ally--enemy-focus-defense)
21. [Channel Interrupt + Late-Game Grouping](#21-channel-interrupt--late-game-grouping)

---

## 1. Directory Structure

```
vscripts/
├── bots/                              # Main bot logic (Workshop folder 3246316298)
│   ├── bot_generic.lua                # Bot initialization entry point
│   ├── hero_selection.lua             # Hero picking/banning logic
│   ├── item_purchase_generic.lua      # Item purchasing state machine
│   ├── ability_item_usage_generic.lua # Ability casting + item active-use logic (~8000 lines)
│   ├── mode_*_generic.lua             # Behavior modes (laning, farm, push, retreat, etc.)
│   │
│   ├── BotLib/                        # all hero-specific files (one per hero)
│   │   ├── hero_abaddon.lua
│   │   ├── hero_axe.lua
│   │   └── ... (hero_[internal_name].lua)
│   │
│   ├── FunLib/                        # Core utility libraries
│   │   ├── jmz_func.lua              # Main aggregator (loads all sub-libraries as J.*)
│   │   ├── aba_item.lua              # Item lists, components, sell/buy logic
│   │   ├── aba_skill.lua             # Ability slot reading, skill build system
│   │   ├── aba_role.lua              # Role/position assignment (pos 1-5)
│   │   ├── aba_hero_roles_map.lua    # Hero role scores (carry/support/initiator/etc.)
│   │   ├── aba_site.lua              # Map positioning, farm timing, location logic
│   │   ├── spell_list.lua            # Ability weight database (all heroes)
│   │   ├── spell_prob_list.lua       # Ability probability weights
│   │   ├── advanced_item_strategy.lua # Fallback item builds by position
│   │   ├── aba_chat.lua              # Chatbot + item/hero name localization
│   │   ├── aba_minion.lua            # Minion/summon control
│   │   ├── aba_special_units.lua     # Special unit interactions
│   │   ├── morphling_utility.lua     # Morphling replicate helper
│   │   └── rubick_hero/              # Rubick spell-steal hero-specific logic
│   │       ├── beastmaster.lua
│   │       └── ...
│   │
│   ├── Buff/                          # Buff mode (enhanced neutral items)
│   │   └── NeutralItems.lua           # Neutral item tier lists + distribution logic
│   │
│   ├── FretBots/                      # Enhanced difficulty mode
│   │   ├── SettingsDefault.lua        # Default difficulty settings
│   │   ├── SettingsNeutralItemTable.lua # Neutral item configs with role weights
│   │   ├── HeroNames.lua             # Hero name localizations (en/zh/ru/ja)
│   │   ├── NeutralItems.lua          # Neutral item distribution timing/logic
│   │   └── matchups_data.lua         # Hero matchup database
│   │
│   ├── Customize/                     # User customization
│   │   ├── general.lua               # Global settings (bans, picks, difficulty)
│   │   └── hero/                     # Per-hero overrides
│   │       └── viper.lua             # Example
│   │
│   └── ts_libs/                       # TypeScript-generated constants
│       └── dota/heroes.lua           # HeroName enum
│
├── typescript/                        # TypeScript source (compiles to Lua)
├── game/                              # Valve default setup + permanent customization
└── docs/                              # Developer documentation (this file)
```

---

## 2. Naming Conventions

| Element          | Format                          | Example                              |
|------------------|---------------------------------|--------------------------------------|
| Hero internal    | `npc_dota_hero_[name]`          | `npc_dota_hero_crystal_maiden`       |
| Hero file        | `hero_[name].lua`               | `hero_crystal_maiden.lua`            |
| Ability          | `[hero]_[ability]`              | `crystal_maiden_crystal_nova`        |
| Item             | `item_[name]`                   | `item_black_king_bar`                |
| Modifier         | `modifier_[source]_[name]`      | `modifier_item_blink_dagger_cd`      |
| Talent           | `special_bonus_[type]_[value]`  | `special_bonus_hp_250`               |
| Position         | `pos_[1-5]`                     | `pos_1` (carry), `pos_5` (hard sup)  |

**Important:** These names are set by Valve and can change between patches. Always verify against [d2vpkr](https://github.com/dotabuff/d2vpkr) or in-game.

---

## 3. Hero Bot Files

Each file in `BotLib/hero_[name].lua` follows this exact structure:

```lua
-- 1. IMPORTS
local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local sAbilityList = J.Skill.GetAbilityList(bot)   -- Dynamic slot reading

-- 2. TALENT BUILD
local tTalentTreeList = {
    ['t25'] = {0, 10},   -- 0=left talent, 10=right talent
    ['t20'] = {10, 0},
    ['t15'] = {0, 10},
    ['t10'] = {10, 0},
}

-- 3. ABILITY BUILD ORDER
local tAllAbilityBuildList = {
    {1,2,1,2,1,6,1,2,2,2,6,3,3,3,6},  -- Indices into sAbilityList
}
-- 1-5 = regular abilities (filtered, no innates), 6 = ultimate (always)

-- 4. ITEM BUILDS BY POSITION
sRoleItemsBuyList['pos_1'] = { "item_tango", "item_phase_boots", ... }
sRoleItemsBuyList['pos_2'] = { ... }
-- ... pos_3 through pos_5

-- 5. SELL LIST
X['sSellList'] = { "item_quelling_blade", ... }

-- 6. ABILITY REFERENCES
local abilityQ = bot:GetAbilityByName('hero_ability_q')
-- or: local abilityQ = bot:GetAbilityByName(sAbilityList[1])

-- 7. SKILLS COMPLEMENT (ability casting logic)
function X.SkillsComplement()
    -- Priority-ordered ability usage
end

-- 8. CONSIDER FUNCTIONS (one per ability)
function X.ConsiderQ()
    return desire, target
end
```

### Key Rules

- **`tAllAbilityBuildList` indices are NOT slot numbers.** They index into the filtered `sAbilityList` built by `aba_skill.lua`. Index 1 = first non-innate ability, 6 = ultimate.
- **If an ability becomes innate** (non-learnable) in a patch, it is filtered out of `sAbilityList` and all higher indices shift down. The build order MUST be updated.
- **Use `sAbilityList[N]` for ability references** when possible (resilient to renames). Only use hardcoded `GetAbilityByName('hero_ability_name')` when you need to check specific modifiers or special logic.
- **When unsure about an ability name after a rename**, chain fallbacks:
  ```lua
  local ability = bot:GetAbilityByName('new_name')
                  or bot:GetAbilityByName('old_name')
                  or (sAbilityList[N] and bot:GetAbilityByName(sAbilityList[N]))
  ```

---

## 4. Skill / Ability System

**Core file:** `FunLib/aba_skill.lua`

### GetAbilityList(bot) -- Dynamic Slot Reader

1. Iterates slots 0-10 via `bot:GetAbilityInSlot(slot)`
2. Filters out:
   - `generic_hidden` (placeholder slots) -- except inserts as placeholder if not slot 0
   - Abilities with `DOTA_ABILITY_BEHAVIOR_NOT_LEARNABLE` AND `IsHidden()` (innates)
   - Talent abilities (slots 10+)
3. Places ultimate abilities at index **6** in the returned `sAbilityList`
4. Regular abilities get sequential indices 1, 2, 3, ...

### GetSkillList() -- Build Order Resolver

Takes `sAbilityList` + `nAbilityBuildList` (the `{1,2,1,...}` array) and produces the final skill-up sequence. References `sAbilityList[nAbilityBuildList[i]]` to get the actual ability name.

### Implications for Patch Updates

- If an ability **moves from learnable to innate**: the ability disappears from `sAbilityList`, indices shift, and the build order breaks. You must update `tAllAbilityBuildList` to only reference existing indices.
- If an ability is **renamed**: `GetAbilityByName('old_name')` returns nil. Update all references.
- If an ability's **targeting type changes** (e.g., unit-target to point-target): Update the `Action_UseAbilityOnEntity` / `Action_UseAbilityOnLocation` calls.

### Modifier files

- `FunLib/spell_list.lua` -- Ability weight database keyed by `npc_dota_hero_[name]`. Used for generic ability evaluation.
- `FunLib/spell_prob_list.lua` -- Probability weights for ability casting decisions.
- `FunLib/rubick_hero/[hero].lua` -- Rubick spell-steal logic per hero. Must be updated if ability names change.

---

## 5. Item System

**Core file:** `FunLib/aba_item.lua` (~830 lines)

### Item Lists (order of importance)

| List Name        | Purpose                                    | Line Range |
|------------------|--------------------------------------------|------------|
| `sBasicItems`    | Basic shop components (branches, boots...) | ~150-197   |
| `sSeniorItems`   | Mid-tier items (blink, arcane boots...)    | ~199-234   |
| `sTopItems`      | All finished items the bot can buy         | ~236-320   |
| `sSellList`      | Item pairs: "if you buy X, sell Y"         | ~391-450   |
| `sNeedDebugItemList` | Items that need special use-logic      | ~18-155    |
| `sNotSellItemList` | Items the bot should never sell           | ~486-530   |
| `tEarlyItem`     | Early-game consumables/stat items          | ~322-345   |

### Item Component System

Each item has a component definition:
```lua
Item['item_bfury'] = GetItemComponents('item_bfury')[1]
```

- `GetItemComponents()` is a **Valve API** that returns the current game's recipe.
- **Use this for all upgrade items.** It auto-updates when the game client patches.
- Only hardcode component arrays when the API returns wrong data (rare): `item_phase_boots`, `item_power_treads`, `item_ultimate_scepter`.
- **NEVER** hardcode component arrays for basic shop items (items with no sub-components like `item_splintmail`, `item_shawl`). They are leaf nodes.

### Item Purchase Flow

`item_purchase_generic.lua`:
1. Loads hero's `sBuyList` from the BotLib file
2. Processes in reverse order (highest priority first)
3. Checks if the bot already owns the item
4. Breaks items into components via the component definitions
5. Purchases components from the correct shop (main/secret/side)
6. Auto-sells items from `sSellList` when inventory is full

### Self-Defined Items ("Outfits")

Some heroes use virtual item names like `item_sven_outfit` that map to real items via `tDefineItemRealName` (~line 842+). These represent early-game item bundles.

---

## 6. Neutral Item System

Neutral items are handled by **two separate systems** depending on the game mode.

### Buff Mode (`Buff/NeutralItems.lua`)

- Defines `Tier1NeutralItems` through `Tier5NeutralItems` arrays
- Items are distributed to bots based on game time
- Simple random selection from the tier pool
- Includes enhancement items (enchantments) per tier

### FretBots Mode (`FretBots/SettingsNeutralItemTable.lua` + `FretBots/NeutralItems.lua`)

- More sophisticated role-aware item distribution
- Each item has: `name`, `tier`, `ranged` weight, `melee` weight, `roles` array `{pos1,pos2,pos3,pos4,pos5}`
- `GetBotDesireForItem()` scores items based on attack type + role + tier
- Timing system with difficulty scaling and variance

### Updating Neutral Items

When Valve rotates the neutral item pool:
1. Check `https://raw.githubusercontent.com/dotabuff/d2vpkr/master/dota/scripts/npc/neutral_items.txt` for the current tier lists
2. Update both `Buff/NeutralItems.lua` and `FretBots/SettingsNeutralItemTable.lua`
3. Comment out removed items (keep for reference), add new ones
4. Items that moved tiers: remove from old tier, add to new tier
5. For FretBots, assign sensible role weights based on item type:
   - Physical damage: `roles={3,3,1,0,0}` (carry/mid)
   - Magic/support: `roles={1,1,1,3,3}` (support)
   - Tank: `roles={1,1,3,1,1}` (offlane)
   - Universal: `roles={1,1,1,1,1}`

---

## 7. Item Active-Use System

**Core file:** `ability_item_usage_generic.lua` (~8000 lines)

Every item with an active ability has a `ConsiderItemDesire` function:

```lua
X.ConsiderItemDesire["item_name"] = function(hItem)
    -- Return: desire, target, castType, motive
    -- desire: BOT_ACTION_DESIRE_NONE / _MODERATE / _HIGH
    -- castType: 'unit' | 'ground' | 'none' (self-cast)
    return BOT_ACTION_DESIRE_NONE
end
```

### Adding a New Active Item

1. Find a similar existing item as a template
2. Add the function near similar items in the file
3. Common patterns:
   - **Self-cast buff** (BKB, Mask of Madness): `sCastType = 'none'`, check combat conditions
   - **Unit-target ally** (Glimmer Cape, Mekansm): iterate `hAllyList`, check HP/danger
   - **Unit-target enemy** (Orchid, Abyssal): check `botTarget` validity and range
   - **Ground-target AoE** (Pipe, Shiva's): check enemy count in range
   - **Urn-like** (heal or damage): check charges, target ally for heal / enemy for damage

### Helper Functions Used

- `J.GetNearbyHeroes(bot, range, isEnemy, mode)` -- Get heroes in range
- `J.IsValid(unit)` / `J.IsValidHero(unit)` -- Validity checks
- `J.IsInRange(unit1, unit2, range)` -- Distance check
- `J.CanCastOnNonMagicImmune(unit)` / `J.CanCastOnMagicImmune(unit)` -- Immunity checks
- `J.IsRetreating(bot)` / `J.IsGoingOnSomeone(bot)` -- Behavior checks
- `J.GetHP(unit)` / `J.GetMP(unit)` -- Health/mana percentage (0-1)
- `J.IsDisabled(unit)` -- Stun/root/silence check
- `bot:HasModifier('modifier_name')` -- Buff/debuff check

---

## 8. Bot Behavior Modes

Located in `mode_*_generic.lua` files:

| File                         | Purpose                        |
|------------------------------|--------------------------------|
| `mode_laning_generic.lua`    | Early laning, last-hitting     |
| `mode_farm_generic.lua`      | Jungle/creep farming           |
| `mode_roam_generic.lua`      | Solo ganking                   |
| `mode_team_roam_generic.lua` | Group ganking                  |
| `mode_attack_generic.lua`    | General attacking              |
| `mode_retreat_generic.lua`   | Defensive retreat              |
| `mode_defend_tower_*.lua`    | Tower defense (top/mid/bot)    |
| `mode_push_tower_*.lua`      | Tower pushing                  |
| `mode_roshan_generic.lua`    | Roshan hunt                    |
| `mode_rune_generic.lua`      | Rune pickup                    |
| `mode_ward_generic.lua`      | Ward placement                 |
| `mode_outpost_generic.lua`   | Outpost control                |

These files generally don't need updating for item/ability patches, only for game mechanic changes (e.g., timing changes, map changes).

---

## 9. FretBots (Enhanced Difficulty)

FretBots mode gives bots unfair advantages (extra gold, XP, stats) for challenging gameplay.

Key files:
- `FretBots/SettingsDefault.lua` -- Bonus values (gold, XP multipliers)
- `FretBots/HeroNames.lua` -- Hero name localizations for chat
- `FretBots/matchups_data.lua` -- Hero matchup database (14876 lines)
- `FretBots/NeutralItems.lua` -- Item distribution with timing/difficulty scaling

---

## 10. Customization System

### General Settings (`Customize/general.lua`)
```lua
Customize = {
    Enable = true,
    Localization = "en",
    Ban = {},
    Radiant_Heros = {'Random', 'Random', 'Random', 'Random', 'Random'},
    Dire_Heros = {'Random', 'Random', 'Random', 'Random', 'Random'},
    Allow_Repeated_Heroes = false,
}
```

### Per-Hero Overrides (`Customize/hero/[name].lua`)
```lua
return {
    Enable = true,
    AbilityUpgrade = {1,2,1,2,1,6,...},  -- Custom skill build
    Talent = {t10={0,10}, ...},           -- Custom talents
    PurchaseList = {"item_...", ...},      -- Custom item build
    SellList = {"item_...", ...},          -- Custom sell list
}
```

Loaded by `J.SetUserHeroInit()` in each hero file. Permanent customization goes in `game/Customize/` to survive workshop updates.

---

## 11. Patch Update Checklist

When a new Dota 2 patch drops, follow these steps in order:

### Step 1: Gather Data (parallel)

- [ ] Fetch patch notes from `https://www.dota2.com/patches/X.XX`
- [ ] Fetch current shop items from `https://raw.githubusercontent.com/dotabuff/d2vpkr/master/dota/scripts/shops.txt`
- [ ] Fetch current neutral items from `https://raw.githubusercontent.com/dotabuff/d2vpkr/master/dota/scripts/npc/neutral_items.txt`
- [ ] Cross-check ability/item names against **Liquipedia** (`https://liquipedia.net/dota2/HERO_NAME`) -- patch note summaries can be inaccurate about exact internal names

### Step 2: Update Shop Items (`FunLib/aba_item.lua`)

- [ ] `sBasicItems` list: Add new basic components
- [ ] `sSeniorItems` list: Add/remove mid-tier items
- [ ] `sTopItems` list: Add all new purchasable items
- [ ] Component definitions: Add `GetItemComponents('item_name')[1]` for new upgrade items
- [ ] `sSellList`: Add sell-pair entries for new components replacing old ones
- [ ] Comment out (don't delete) removed items with `-- removed from game` note

### Step 3: Update Hero Item Builds (`BotLib/hero_*.lua`)

- [ ] `grep` for removed item names across all BotLib files
- [ ] Replace with appropriate alternatives based on hero role
- [ ] Add new items to suitable hero builds

### Step 4: Handle Ability Changes

- [ ] **Renames**: `grep` for old `GetAbilityByName('old_name')` calls, update to new names
- [ ] **Replaced abilities**: Rewrite casting logic if targeting changed
- [ ] **Innate transitions**: If a previously-learnable ability became innate:
  - Update `tAllAbilityBuildList` (remove references to the now-missing index)
  - Add nil guards for the ability variable
  - Comment out the Consider function for that ability
- [ ] Update `spell_list.lua`, `spell_prob_list.lua`, `rubick_hero/*.lua`
- [ ] **Always verify against Liquipedia** -- patch note summaries can be wrong

### Step 5: Add Item Active-Use Logic (`ability_item_usage_generic.lua`)

- [ ] For each new item with an ACTIVE ability, add a `ConsiderItemDesire` function
- [ ] Check Liquipedia for targeting type (unit/ground/self-cast)
- [ ] Copy a similar existing item as a template
- [ ] Passive-only items don't need logic here

### Step 6: Update Neutral Items

- [ ] `Buff/NeutralItems.lua`: Update all 5 tier arrays
- [ ] `FretBots/SettingsNeutralItemTable.lua`: Update with role weights
- [ ] Add `ConsiderItemDesire` for new neutral items with active abilities
- [ ] Comment out removed neutrals, add new ones, move items between tiers

### Step 7: Update Support Files

- [ ] `FunLib/advanced_item_strategy.lua`: Replace removed items in fallback builds
- [ ] `FunLib/aba_site.lua`: Update `HasItem()` checks for removed items
- [ ] `FretBots/HeroNames.lua`: Add new heroes (if any)
- [ ] `FunLib/aba_hero_roles_map.lua`: Add role scores for new heroes

### Step 8: New Heroes (if any)

- [ ] Create `BotLib/hero_[name].lua` following existing hero file template
- [ ] Add to `FretBots/HeroNames.lua`
- [ ] Add to `FunLib/aba_hero_roles_map.lua`
- [ ] Add abilities to `spell_list.lua`

---

## 12. External Data Sources

| Source | URL | Purpose |
|--------|-----|---------|
| **d2vpkr shops.txt** | `https://raw.githubusercontent.com/dotabuff/d2vpkr/master/dota/scripts/shops.txt` | Authoritative item internal names |
| **d2vpkr neutral_items.txt** | `https://raw.githubusercontent.com/dotabuff/d2vpkr/master/dota/scripts/npc/neutral_items.txt` | Current neutral item pool by tier |
| **d2vpkr npc_heroes.txt** | `https://raw.githubusercontent.com/dotabuff/d2vpkr/master/dota/scripts/npc/npc_heroes.txt` | Hero ability slot definitions |
| **Liquipedia** | `https://liquipedia.net/dota2/HERO_NAME` | Ability details, targeting, descriptions |
| **Official patch notes** | `https://www.dota2.com/patches/X.XX` | Patch change summary |
| **Valve Bot API docs** | `https://docs.moddota.com/lua_bots/` | Bot scripting API reference |

### Trust Hierarchy

1. **d2vpkr** (extracted game data) > **Liquipedia** (community-maintained) > **patch notes** (summaries, can have errors)
2. **Always verify ability names** before editing code. Patch note summaries (even AI-generated ones) can be wrong about whether an ability is innate vs. learnable, or about exact internal names.
3. When in doubt, use **dynamic `sAbilityList[N]` references** instead of hardcoded ability names.

---

## 13. TypeScript to Lua (TSTL) Relationship

Some Lua files in `bots/FunLib/` are **generated from TypeScript** via TSTL. When editing these files, you **MUST also update the TypeScript source** or changes will be overwritten on next build.

### TS-Generated Files (edit the `.ts` source, not the `.lua` output)

| Generated Lua File | TypeScript Source |
|---------------------|-------------------|
| `FunLib/aba_site.lua` | `typescript/bots/FunLib/aba_site.ts` |
| `FunLib/utils.lua` | `typescript/bots/FunLib/utils.ts` |
| `FunLib/advanced_item_strategy.lua` | `typescript/bots/FunLib/advanced_item_strategy.ts` |
| `FunLib/aba_push.lua` | `typescript/bots/FunLib/aba_push.ts` |
| `FunLib/aba_defend.lua` | `typescript/bots/FunLib/aba_defend.ts` |
| `FunLib/global_cache.lua` | `typescript/bots/FunLib/global_cache.ts` |
| `FunLib/aba_role.lua` | `typescript/bots/FunLib/aba_role.ts` |
| `FunLib/aba_hero_roles_map.lua` | `typescript/bots/FunLib/aba_hero_roles_map.ts` |
| `FunLib/spell_prob_list.lua` | `typescript/bots/FunLib/spell_prob_list.ts` |
| `FunLib/aba_buff.lua` | `typescript/bots/FunLib/aba_buff.ts` |
| `Customize/general.lua` | `typescript/bots/Customize/general.ts` |
| `ts_libs/dota/heroes.lua` | `typescript/bots/ts_libs/dota/heroes.ts` |

### Pure Lua Files (edit directly)

These files have NO TypeScript source -- edit the Lua directly:
- `FunLib/jmz_func.lua` (core functions, hand-written Lua)
- `FunLib/aba_item.lua` (item definitions)
- `FunLib/aba_skill.lua` (skill system)
- `FunLib/spell_list.lua` (ability weights)
- `FunLib/aba_chat.lua` (chatbot)
- `ability_item_usage_generic.lua` (item active-use logic)
- `item_purchase_generic.lua` (purchase logic)
- All `BotLib/hero_*.lua` files
- All `Buff/*.lua` files
- All `FretBots/*.lua` files (except those with `.ts` counterparts)

### How to Check

If unsure whether a Lua file is TS-generated, look for the TSTL marker pattern at the top:
```lua
-- Generated by TSTL
```
Or check if a corresponding `.ts` file exists in `typescript/bots/` at the same relative path.

### jmz_func.d.ts

`typescript/bots/FunLib/jmz_func.d.ts` is a **type declaration file** for the hand-written `jmz_func.lua`. It provides TypeScript type information but does NOT generate any Lua. If you add new functions to `jmz_func.lua` that TS files need to call, add declarations here.

---

## 14. Common Pitfalls

### 1. Hardcoding component arrays for basic items
**Wrong:** `Item['item_splintmail'] = { 'item_chainmail', 'item_blades_of_attack' }`
**Right:** Just add `item_splintmail` to `sBasicItems`. It's a leaf item with no sub-components.

### 2. Overriding GetItemComponents with hardcoded arrays
`GetItemComponents()` is a game API that returns correct data once the client updates. Only hardcode when the API is known to return wrong data (very rare).

### 3. Trusting patch note summaries for ability names
Patch notes use display names ("Summon Razorback"), but the code needs internal names (`beastmaster_call_of_the_wild_razorback` or `beastmaster_summon_razorback`). These can differ. Always verify on Liquipedia or d2vpkr.

### 4. Forgetting to update multiple files for ability renames
An ability rename requires updates in:
- `BotLib/hero_[name].lua` (GetAbilityByName + Consider function)
- `FunLib/spell_list.lua` (ability weights)
- `FunLib/spell_prob_list.lua` (probability weights)
- `FunLib/rubick_hero/[name].lua` (Rubick spell-steal logic)

### 5. Assuming innate = removed
Innate abilities are NOT removed. They still exist in the game but are `NOT_LEARNABLE`. They are filtered out of `sAbilityList` by `aba_skill.lua`. The ability can still apply modifiers that other code checks for (`bot:HasModifier(...)`).

### 6. Not nil-guarding ability references
When referencing `sAbilityList[N]` where N might not exist (because an ability became innate), always guard:
```lua
local abilityE = sAbilityList[3] and bot:GetAbilityByName(sAbilityList[3]) or nil
if abilityE ~= nil then ... end
```

### 7. Editing FretBots but not Buff (or vice versa)
Neutral items exist in TWO files. Always update both `Buff/NeutralItems.lua` AND `FretBots/SettingsNeutralItemTable.lua`.

### 8. Adding items to sTopItems but not GetItemComponents
Every item in `sTopItems` that is an upgrade item needs a corresponding `GetItemComponents` entry, or the purchase system won't know how to buy it.

---

## 15. Personality System

Per-bot personality traits that modulate mode desires and draft picks, so bots of the same hero play differently across games and different heroes lean into natural playstyles (rats rat, fighters fight).

### Files

| File | Role |
|------|------|
| `typescript/bots/FunLib/aba_personality.ts` | TS source for the core system |
| `typescript/bots/FunLib/aba_hero_archetypes.ts` | TS source for 127-hero archetype table |
| `bots/FunLib/aba_personality.lua` | Hand-written Lua mirror (will be regenerated by TSTL on `npm run build`) |
| `bots/FunLib/aba_hero_archetypes.lua` | Hand-written Lua mirror of the archetype data |

**Why both TS and hand-written Lua?** The TS files are the long-term source of truth. The Lua mirrors exist so the system runs today without requiring a Node.js install. When Node.js is available, `npm run build` regenerates the Lua from TS — the structure matches so behavior stays identical.

### Traits

Each bot has five traits in `[0..1]` (0.5 = neutral):

- `aggression` — fight vs. avoid
- `greed` — farm vs. fight
- `risk` — dive vs. play safe
- `independence` — rat vs. group
- `teamSpirit` — respond to pings / help allies

Plus `tilt` (dynamic 0..1, rises on deaths, decays over time) and `tiltSensitivity` (how much tilt distorts this hero — Pudge is high, Treant is low).

### Archetype derivation

`aba_hero_archetypes.lua` derives baseline traits for each hero from `aba_hero_roles_map.lua` role scores, then applies manual overrides for ~100 salient heroes (NP = rat, Huskar = yolo, etc.). Heroes without overrides get reasonable defaults from their role profile.

### Hooks

Personality modulates mode desires via `J.Personality.ModulateDesire(bot, desire, tag)`:

| Mode file | Tag | Where hooked |
|-----------|-----|--------------|
| `mode_farm_generic.lua` | `farm` | Wraps `GetDesire()` |
| `mode_roam_generic.lua` | `roam` | Wraps `GetDesire()` |
| `mode_team_roam_generic.lua` | `team_roam` | Wraps `GetDesire()` |
| `mode_retreat_generic.lua` | `retreat` | Wraps `GetDesire()` |
| `mode_roshan_generic.lua` | `roshan` | Wraps `GetDesire()` |
| `mode_ward_generic.lua` | `ward` | Wraps `GetDesire()` |
| `mode_push_tower_*_generic.lua` | `push` | Wraps `Push.GetPushDesire()` |
| `mode_defend_tower_*_generic.lua` | `defend` | Wraps `Defend.GetDefendDesire()` |

`ModulateDesire` is a no-op for desire ≤ 0 (gates stay as gates). It also self-updates tilt (has an internal 3-second rate limiter).

### Draft bias

`hero_selection.lua` rolls one `SlotProfile` per draft slot at module load, then uses `J.Personality.GetDraftAffinity(cand, profile)` as a 5th scoring factor in `ScoreCandidatesForTeam`. This biases hero picks toward archetypes that match each slot's rolled flavor, giving each match a slightly different team composition feel.

### FretBots amplification

`FretBots.lua` calls `J.Personality.SetFretBotsMode(true)` during init. In that mode, tilt effects are amplified ×1.4 — the theory being that bots on steroids are emotionally charged and tilt swings should feel bigger.

### Failsafe

`jmz_func.lua` loads personality via pcall; if the module fails to load, `J.Personality` falls back to a no-op stub. Bots continue to work with vanilla (non-personality) behavior.

### Debugging

Call `J.Personality.Describe(bot)` from a `print()` to dump a bot's current personality state: archetype name + trait values + tilt.

---

## 16. Team Plan Layer

A single canonical "team intent" per team per tick, used to bias mode desires so the 5 bots act like a team rather than 5 independent agents. Integrated into `J.Personality.ModulateDesire`, so existing mode hooks pick up team-plan bias automatically.

### Files

| File | Role |
|------|------|
| `typescript/bots/FunLib/aba_teamplan.ts` | TS source |
| `bots/FunLib/aba_teamplan.lua` | Hand-written Lua mirror |

### Intents (priority order)

1. `defend_base` — enemies near our Ancient; everyone drops what they're doing
2. `defend_lane` — a specific T1/T2 is under active attack
3. `contest_rosh` — rosh alive, past 15min, numbers advantage
4. `push_lane` — 4+ allies alive, weakest enemy lane
5. `smoke_gank` — past 10min + 3+ allies grouped
6. `regroup` — team low HP/mana; reset
7. `farm` — default

### How it integrates

`J.TeamPlan.MaybeRecompute(bot)` is called from inside `J.Personality.ModulateDesire`. It has a 2-second rate limiter, so any bot calling desire-modulation keeps the plan fresh without per-bot coordination. The computed plan is stored at module scope and queried by `GetPlanBias(bot, mode, teamSpirit)` which returns a multiplier based on:

1. **Match score**: how well this mode serves this intent (lookup table, 0..1)
2. **teamSpirit weighting**: high teamSpirit → full compliance; low teamSpirit → ignore plan

So a `teamSpirit=0.9` support bot will strongly follow the team plan, while a `teamSpirit=0.25` rat hero mostly does their own thing. This preserves personality variance.

### Cycle avoidance

`aba_teamplan` needs `jmz_func` helpers (`GetEnemiesNearLoc`, `IsRoshanAlive`, etc.) but `jmz_func.lua` itself requires `aba_teamplan`. To avoid load-time infinite recursion, `aba_teamplan.lua` uses a lazy `jmz()` helper that requires jmz_func on first use inside functions — never at module load.

### Debugging

- `J.TeamPlan.Describe()` returns current intent + lane + reason (e.g., `"defend_lane lane=2 [lane under attack]"`).
- `J.TeamPlan.GetCurrentPlan()` returns the raw plan table for inspection.

---

## 17. Defend Tuning (PR 3)

Targeted fixes in `aba_defend.ts` / `aba_defend.lua` for three defend gates that previously caused "bots abandon towers" behavior:

1. **Any-enemy-in-range bailout** (`GetDefendDesireHelper` bail-out block) — was returning `VeryLow` if ANY enemy was near the bot, which broke defending since defending a tower means fighting enemies. Changed to bail only when locally outnumbered AND not stronger.

2. **Only-one-defender gate** (near `IsAnyAllyDefending` checks) — the original "1 enemy + 2+ defenders → all but one bail" caused isolated defenders to get run down. Now only **cores** bail when heavily overstaffed (3+ allies). Supports always help defend.

3. **Tower abandonment threshold** (near `buildingTier === 1 && hp <= 0.15`) — previously abandoned any T1 at 15% HP regardless of situation, which was a big cause of the "feed at towers" complaint. Now requires BOTH low HP AND being outnumbered (`lEnemies > nEffAllies + 1`). Thresholds tightened to 10% / 7%.

When regenerating from TSTL (`npm run build`), these changes come from `typescript/bots/FunLib/aba_defend.ts` — Lua was hand-synced to match.

---

## 18. Focus Target + Kill Commit

Addresses the biggest gap in OHA's challenge: bots don't coordinate kills. You could extend safely before because no one smokes, converges, or commits a full combo. This system fixes that.

### Files

| File | Role |
|------|------|
| `typescript/bots/FunLib/aba_focus.ts` | TS source — focus target computation |
| `bots/FunLib/aba_focus.lua` | Hand-written Lua mirror |

### What it does

1. **Focus target scoring**: Every 1.5s, score each enemy hero on:
   - **Isolation** (weight 2.0) — no allies within 1500u = prime pick
   - **Low HP** (weight 1.6) — vulnerable target
   - **Reachability** (weight 0.6) — at least one of our heroes within 2200u
   - **Core value** (weight 0.4) — cores > supports as kill priority
2. **Publish focus**: Store the top scorer in `J.Focus.GetFocus()` with TTL 5s.
3. **Team-plan trigger**: `aba_teamplan` checks focus during recompute. If focus exists AND ≥2 allies are within 2000u of the focus → intent flips to `commit_kill`.
4. **Massive desire swing**: `commit_kill` match table drives `team_roam` and `roam` desires to 1.0 and farm desires to 0.15. Bots converge on the focus's location.

### Priority

`commit_kill` sits at priority 2.5 in the intent chain — above contest_rosh/push/farm, below defend_base/defend_lane. So a pickable focus beats farming/pushing but base defense always wins.

### Personality interaction

Because this rides on top of the team-plan bias, each bot's `teamSpirit` still gates compliance:

- High-teamSpirit supports and initiators converge hard on the focus
- Low-teamSpirit rats (Tinker, NP, Arc Warden) partially ignore — consistent with their archetype

### Debugging

- `J.Focus.Describe()` → `"npc_dota_hero_lina [isolated,low-hp score=3.42]"` or `"none"`
- `J.TeamPlan.Describe()` → shows `commit_kill [focus=... allies=N]` when active

### Hook point for hero-specific use

Hero logic (Consider functions in `BotLib/hero_*.lua`) can call `J.Focus.GetFocusIfInRange(bot, maxRange)` to prefer the team's focus as an attack target, falling back to their normal target-picking if the focus isn't near. Not adopted everywhere yet — future work.

---

## 19. Game Theory Layer

Adaptive strategy — the team plan's intent thresholds and per-mode desire multipliers respond to networth, level, and ult availability. Bots press harder when winning, play safer when losing, commit more readily when they have ults up.

### Files

| File | Role |
|------|------|
| `typescript/bots/FunLib/aba_gametheory.ts` | TS source |
| `bots/FunLib/aba_gametheory.lua` | Hand-written Lua mirror |

### Signals

- **Strategic pressure** in [-1..+1] = 70% networth delta + 30% level delta. Recomputed every 2s.
- **Ult readiness** = count of team members with their ult (slot 5) off cooldown AND enough mana to cast.

### Adaptive thresholds (`GetThresholds`)

The team plan pulls these at compute time instead of hardcoding:

| Threshold | Pressure > +0.3 (ahead) | Even | Pressure < −0.3 (behind) |
|-----------|-------------------------|------|---------------------------|
| commit_kill allies needed | 1 | 2 | 3 |
| push_lane allies alive | 3 | 4 | 5 |
| contest_rosh allies alive | 2 | 3 | 4 |

Plus ult-heavy bonus: if `ultReady >= 3`, commit/push thresholds each drop by 1 (team with 3 big ults available can commit with fewer bodies). If `ultReady == 0`, commit threshold goes up by 1 (naked team plays safer).

### Pressure bias (`GetPressureBias`)

Applied as the final polish in `J.Personality.ModulateDesire` — multiplies mode desire by `1 + pressure * (target - 1)`:

| Mode | Target (at pressure = +1) | At pressure = 0 | At pressure = −1 |
|------|----------------------------|-----------------|-------------------|
| push | 1.15× | 1.0× | 0.85× |
| team_roam / roam | 1.10× | 1.0× | 0.90× |
| roshan | 1.15× | 1.0× | 0.85× |
| retreat | 0.90× | 1.0× | 1.10× |
| farm | 0.95× | 1.0× | 1.05× |

So a team 15k ahead pushes 15% harder and retreats 10% less. A team 15k behind farms 5% more and retreats 10% more — natural comeback pacing.

### Combined stack order

`J.Personality.ModulateDesire` now applies, in order:

1. **Team plan bias** (commit_kill, push_lane, etc., via GetPlanBias)
2. **Personality multiplier** (hero archetype + per-bot random noise)
3. **Role scaling** (pos 1 farms, pos 5 roams)
4. **Pressure bias** (ahead = aggro, behind = safe)

Extremes compound multiplicatively but each layer is moderate, so typical final multipliers stay in 0.3–2.0× range.

### Debug

- `J.GameTheory.Describe()` → `"pressure=+0.24 ultReady=2 commit>=2 push>=4 rosh>=3"`
- Call at any time to see how the game state is shaping decisions.

---

## 20. Save-Ally + Enemy-Focus Defense

Defensive mirror of the focus / commit_kill system. Where aba_focus picks a priority ENEMY for OUR team to kill, aba_enemy_focus detects when enemies are committing on ONE of OUR allies, so we can collapse defensively instead of letting them 5-man pick our carry.

### Files

| File | Role |
|------|------|
| `bots/FunLib/aba_enemy_focus.lua` | Detects threatened ally (urgency-scored) |
| `bots/FunLib/aba_save.lua` | Save-ally helper, urgency-boosted when enemy-focus is active |

### Trigger conditions

An ally is flagged as enemy-focus target when EITHER:

1. **Multi-attacker case**: ≥2 enemies within 900u of the ally AND attacking them / recently damaged them. Urgency = `(1-hp) + 0.35·enemies + 0.4·recentDamage + 0.3·disabled + 0.4·isCore`.
2. **Big-ult case**: ally has any of 24 known big-ult modifiers (Chrono, Ravage, RP, Duel, Doom, Fiend's Grip, Reaper's Scythe, Dismember, Ghost Ship, etc.). Single-enemy channels count as commits. Urgency forced to ≥ 2.0.

### Downstream effects

- **Team plan**: new `save_ally` intent at priority 2.4 (above commit_kill, below defend_lane). Match table: `team_roam 1.0, assemble 0.95, defend 0.85`. Bots converge.
- **Save spells**: `J.Save.GetAllyUnderThreat` gets a +0.8 urgency boost on the enemy-focus target, ensuring CRITICAL-tier urgency for the RIGHT ally (not some other mildly-hurt one).
- **Assemble mode**: `save_ally` is in `ASSEMBLE_INTENTS`, so the mode reads the plan's location and physically walks bots to the threatened ally.

### Heroes adopting the save system

Adopted in `Consider*` functions at HIGH or CRITICAL urgency thresholds:
- Dazzle (Shallow Grave), Oracle (False Promise), Omniknight (Guardian Angel), Abaddon (Aphotic Shield), Treant (Living Armor), Winter Wyvern (Cold Embrace), Snapfire (Firesnap Cookie)
- Item saves: Force Staff, Glimmer Cape, Lotus Orb (all in `ability_item_usage_generic.lua`)

### Debug

- `J.EnemyFocus.Describe()` → `"npc_dota_hero_morphling [under-attack,low-hp urgency=2.41 enemies=3]"` or `"no enemy commit"`

---

## 21. Channel Interrupt + Late-Game Grouping

Two smaller but high-impact additions:

### Channel interrupt (mode_roam, mode_team_roam)

At the top of both mode Think functions: iterate nearby enemies (within 1400u), check `IsChanneling()` — if true and not magic-immune / invulnerable, force-attack them. Interrupts Black Hole / Freezing Field / Shackles / Fiend's Grip / Macropyre / Ghost Ship / Dismember etc.

Priority: ABOVE commit_kill focus override. Interrupting a channel beats finishing a pick.

### Late-game grouping (team plan)

New intent `late_game_group` at priority 5.7 (after missing-enemy regroup, before team-HP regroup). Fires at `DotaTime() > 25 * 60`. Plan location = our Ancient. Match: `assemble 1.0, defend 1.0, retreat 0.9, team_roam 0.85, farm 0.35`.

Drives late-game "stop split-farming, group at high ground for defense." User feedback: "late game they are not defending higher ground, they should be grouping up."

### Opening flavor variance (team plan)

At game start (first 4 min when no urgent intent fires), one of five flavors is applied based on a seeded roll:
- `lotus_rush` (22%) — force contest_lotus earlier
- `aggro_roam` (23%) — bias smoke_gank
- `passive_lane` (25%) — default farm, nothing special
- `deward_scout` (18%) — regroup intent (ward coverage)
- `smoke_gank_early` (12%) — bias smoke_gank

Addresses "dont always start the same."

### Assemble mode integration (CRITICAL FIX)

`mode_assemble_generic.lua` was previously only responding to HUMAN pings. Team-plan location (set by late_game_group, save_ally, contest_rosh, contest_tormentor, defend_base, defend_lane) was ignored. Fixed: assemble now reads `J.TeamPlan.GetCurrentPlan().location` when intent is in `ASSEMBLE_INTENTS`. This is what finally makes bots physically walk to team-plan locations rather than just biasing desires.
