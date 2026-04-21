--[[ Hand-written to match typescript/bots/FunLib/aba_hero_archetypes.ts.
     TSTL will regenerate this file when `npm run build` runs against the TS source.
     Keep both in sync. See ARCHITECTURE.md section 13.

     Each hero gets five traits in [0..1]:
       aggression:   fight vs. avoid
       greed:        farm vs. fight
       risk:         dive vs. play safe
       independence: rat vs. group
       teamSpirit:   respond to pings / help
     Plus tiltSensitivity [0..1]: how much tilt distorts this hero.

     Values derived from role map for most heroes; explicit OVERRIDES for heroes
     whose real playstyle isn't captured by role scores alone. ]]
local ____exports = {}
local ____rolesMap = require(GetScriptDirectory().."/FunLib/aba_hero_roles_map")
local HeroRolesMap = ____rolesMap.HeroRolesMap

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Normalize role score (0..3) to 0..1
local function n(score)
    if score == nil or score == 0 then return 0 end
    return math.min(1, score / 3)
end

local function deriveFromRoles(heroName)
    local roles = HeroRolesMap[heroName]
    if roles == nil then
        return {
            name = "unknown",
            aggression = 0.5,
            greed = 0.5,
            risk = 0.5,
            independence = 0.5,
            teamSpirit = 0.5,
            tiltSensitivity = 0.5,
        }
    end
    local carry      = n(roles.carry)
    local disabler   = n(roles.disabler)
    local durable    = n(roles.durable)
    local escape     = n(roles.escape)
    local initiator  = n(roles.initiator)
    local jungler    = n(roles.jungler)
    local nuker      = n(roles.nuker)
    local support    = n(roles.support)
    local pusher     = n(roles.pusher)
    local healer     = n(roles.healer)

    local aggression    = clamp(0.4  + 0.25*initiator + 0.12*nuker    + 0.08*carry    + 0.08*durable,   0.2, 0.85)
    local greed         = clamp(0.35 + 0.28*carry     + 0.10*jungler  - 0.20*support,                   0.15, 0.85)
    local risk          = clamp(0.4  + 0.20*durable   + 0.15*escape   - 0.10*support  + 0.10*initiator, 0.2, 0.85)
    local independence  = clamp(0.35 + 0.22*pusher    + 0.18*jungler  + 0.10*escape   - 0.15*support,   0.2, 0.85)
    local teamSpirit    = clamp(0.4  + 0.25*support   + 0.15*initiator+ 0.20*healer   + 0.12*disabler - 0.18*carry, 0.2, 0.9)

    return {
        name = "derived",
        aggression = aggression,
        greed = greed,
        risk = risk,
        independence = independence,
        teamSpirit = teamSpirit,
        tiltSensitivity = 0.5,
    }
end

-- Salient-hero overrides. Only fields present are overridden; rest come from derivation.
-- Keys are the internal hero unit names (what bot:GetUnitName() returns).
local OVERRIDES = {
    -- ==== Rat / split-push ====
    ['npc_dota_hero_furion']           = { name = "Rat King",         aggression = 0.55, greed = 0.6,  risk = 0.4,  independence = 0.9,  teamSpirit = 0.35 },
    ['npc_dota_hero_tinker']           = { name = "Ratter Mage",      aggression = 0.35, greed = 0.7,  risk = 0.25, independence = 0.85, teamSpirit = 0.3,  tiltSensitivity = 0.75 },
    ['npc_dota_hero_techies']          = { name = "Nuisance",         aggression = 0.4,  greed = 0.3,  risk = 0.3,  independence = 0.75, teamSpirit = 0.5,  tiltSensitivity = 0.9 },
    ['npc_dota_hero_lycan']            = { name = "Rat Wolf",         aggression = 0.65, greed = 0.55, risk = 0.55, independence = 0.85, teamSpirit = 0.4 },
    ['npc_dota_hero_broodmother']      = { name = "Spider Rat",       aggression = 0.55, greed = 0.5,  risk = 0.5,  independence = 0.85, teamSpirit = 0.35 },
    ['npc_dota_hero_lone_druid']       = { name = "Bear Split",       aggression = 0.55, greed = 0.55, risk = 0.45, independence = 0.8,  teamSpirit = 0.4 },
    ['npc_dota_hero_arc_warden']       = { name = "Ultra Rat",        aggression = 0.3,  greed = 0.9,  risk = 0.25, independence = 0.9,  teamSpirit = 0.25 },
    ['npc_dota_hero_meepo']            = { name = "Split King",       aggression = 0.7,  greed = 0.7,  risk = 0.55, independence = 0.75, teamSpirit = 0.35, tiltSensitivity = 0.85 },

    -- ==== Yolo / aggressive fighters ====
    ['npc_dota_hero_huskar']           = { name = "Yolo Berserker",   aggression = 0.9,  greed = 0.25, risk = 0.9,  independence = 0.4,  teamSpirit = 0.5,  tiltSensitivity = 0.85 },
    ['npc_dota_hero_bloodseeker']      = { name = "Blood Hunter",     aggression = 0.9,  greed = 0.3,  risk = 0.8,  independence = 0.5,  teamSpirit = 0.55 },
    ['npc_dota_hero_spirit_breaker']   = { name = "Cosmic Gank",      aggression = 0.85, greed = 0.25, risk = 0.8,  independence = 0.55, teamSpirit = 0.7 },
    ['npc_dota_hero_pudge']            = { name = "Hook Addict",      aggression = 0.8,  greed = 0.25, risk = 0.75, independence = 0.45, teamSpirit = 0.65, tiltSensitivity = 0.95 },
    ['npc_dota_hero_phantom_assassin'] = { name = "Crit Fisher",      aggression = 0.75, greed = 0.5,  risk = 0.7,  independence = 0.45, teamSpirit = 0.55 },
    ['npc_dota_hero_legion_commander'] = { name = "Duel Diva",        aggression = 0.9,  greed = 0.35, risk = 0.85, independence = 0.45, teamSpirit = 0.7,  tiltSensitivity = 0.7 },
    ['npc_dota_hero_axe']              = { name = "Call Fisher",      aggression = 0.85, greed = 0.35, risk = 0.8,  independence = 0.4,  teamSpirit = 0.75 },
    ['npc_dota_hero_night_stalker']    = { name = "Night Terror",     aggression = 0.8,  greed = 0.35, risk = 0.7,  independence = 0.55, teamSpirit = 0.6 },
    ['npc_dota_hero_ursa']             = { name = "Bear Rage",        aggression = 0.8,  greed = 0.4,  risk = 0.7,  independence = 0.45, teamSpirit = 0.6 },
    ['npc_dota_hero_rattletrap']       = { name = "Rocket Diva",      aggression = 0.8,  greed = 0.25, risk = 0.75, independence = 0.5,  teamSpirit = 0.8 },
    ['npc_dota_hero_slark']            = { name = "Swim King",        aggression = 0.7,  greed = 0.5,  risk = 0.8,  independence = 0.55, teamSpirit = 0.5 },
    ['npc_dota_hero_primal_beast']     = { name = "Rampage Prime",    aggression = 0.85, greed = 0.3,  risk = 0.85, independence = 0.35, teamSpirit = 0.75 },
    ['npc_dota_hero_monkey_king']      = { name = "Cloud Jumper",     aggression = 0.7,  greed = 0.5,  risk = 0.65, independence = 0.55, teamSpirit = 0.55 },
    ['npc_dota_hero_pangolier']        = { name = "Rolling Rogue",    aggression = 0.7,  greed = 0.45, risk = 0.7,  independence = 0.5,  teamSpirit = 0.65 },
    ['npc_dota_hero_riki']             = { name = "Shadow Stab",      aggression = 0.65, greed = 0.5,  risk = 0.55, independence = 0.6,  teamSpirit = 0.5 },
    ['npc_dota_hero_bounty_hunter']    = { name = "Shuriken Scout",   aggression = 0.65, greed = 0.45, risk = 0.5,  independence = 0.55, teamSpirit = 0.7 },
    ['npc_dota_hero_centaur']          = { name = "Stomp Tank",       aggression = 0.7,  greed = 0.35, risk = 0.7,  independence = 0.35, teamSpirit = 0.8 },
    ['npc_dota_hero_skeleton_king']    = { name = "Undead Carry",     aggression = 0.65, greed = 0.55, risk = 0.75, independence = 0.4,  teamSpirit = 0.55 },
    ['npc_dota_hero_troll_warlord']    = { name = "Troll Carry",      aggression = 0.7,  greed = 0.5,  risk = 0.6,  independence = 0.45, teamSpirit = 0.55 },
    ['npc_dota_hero_juggernaut']       = { name = "Omni Blade",       aggression = 0.65, greed = 0.55, risk = 0.65, independence = 0.45, teamSpirit = 0.6 },
    ['npc_dota_hero_mars']             = { name = "Arena Lord",       aggression = 0.75, greed = 0.4,  risk = 0.65, independence = 0.4,  teamSpirit = 0.75 },
    ['npc_dota_hero_magnataur']        = { name = "RP Gambler",       aggression = 0.7,  greed = 0.4,  risk = 0.6,  independence = 0.35, teamSpirit = 0.85, tiltSensitivity = 0.7 },
    ['npc_dota_hero_earthshaker']      = { name = "Echo Gambler",     aggression = 0.7,  greed = 0.35, risk = 0.65, independence = 0.4,  teamSpirit = 0.85 },
    ['npc_dota_hero_tidehunter']       = { name = "Ravage Prime",     aggression = 0.65, greed = 0.3,  risk = 0.55, independence = 0.35, teamSpirit = 0.85 },
    ['npc_dota_hero_enigma']           = { name = "Black Hole Fisher",aggression = 0.65, greed = 0.4,  risk = 0.6,  independence = 0.45, teamSpirit = 0.85 },
    ['npc_dota_hero_faceless_void']    = { name = "Chrono Sphere",    aggression = 0.7,  greed = 0.5,  risk = 0.6,  independence = 0.4,  teamSpirit = 0.8,  tiltSensitivity = 0.7 },
    ['npc_dota_hero_batrider']         = { name = "Lassoer",          aggression = 0.7,  greed = 0.35, risk = 0.65, independence = 0.45, teamSpirit = 0.75 },

    -- ==== Greedy farmers ====
    ['npc_dota_hero_antimage']         = { name = "Blink Farmer",     aggression = 0.4,  greed = 0.85, risk = 0.45, independence = 0.7,  teamSpirit = 0.3 },
    ['npc_dota_hero_spectre']          = { name = "Haunt Farmer",     aggression = 0.5,  greed = 0.8,  risk = 0.5,  independence = 0.55, teamSpirit = 0.6 },
    ['npc_dota_hero_medusa']           = { name = "Mana Shield",      aggression = 0.35, greed = 0.85, risk = 0.3,  independence = 0.4,  teamSpirit = 0.5 },
    ['npc_dota_hero_terrorblade']      = { name = "Metamorph",        aggression = 0.4,  greed = 0.8,  risk = 0.4,  independence = 0.65, teamSpirit = 0.4 },
    ['npc_dota_hero_naga_siren']       = { name = "Song Farmer",      aggression = 0.5,  greed = 0.75, risk = 0.4,  independence = 0.55, teamSpirit = 0.55 },
    ['npc_dota_hero_phantom_lancer']   = { name = "Illusion Farmer",  aggression = 0.5,  greed = 0.75, risk = 0.55, independence = 0.55, teamSpirit = 0.45 },
    ['npc_dota_hero_alchemist']        = { name = "Gold Hoarder",     aggression = 0.55, greed = 0.75, risk = 0.5,  independence = 0.4,  teamSpirit = 0.55 },

    -- ==== Safe-lane pos1 (team-dependent) ====
    ['npc_dota_hero_sniper']           = { name = "Safe Shooter",     aggression = 0.45, greed = 0.65, risk = 0.3,  independence = 0.4,  teamSpirit = 0.45 },
    ['npc_dota_hero_drow_ranger']      = { name = "Silver Aura",      aggression = 0.45, greed = 0.55, risk = 0.3,  independence = 0.35, teamSpirit = 0.55 },
    ['npc_dota_hero_luna']             = { name = "Moon Blade",       aggression = 0.6,  greed = 0.55, risk = 0.45, independence = 0.4,  teamSpirit = 0.55 },
    ['npc_dota_hero_gyrocopter']       = { name = "Call Down",        aggression = 0.6,  greed = 0.55, risk = 0.45, independence = 0.4,  teamSpirit = 0.7 },
    ['npc_dota_hero_morphling']        = { name = "Morph Out",        aggression = 0.65, greed = 0.55, risk = 0.75, independence = 0.5,  teamSpirit = 0.5 },
    ['npc_dota_hero_muerta']           = { name = "Pistol Cat",       aggression = 0.55, greed = 0.55, risk = 0.4,  independence = 0.4,  teamSpirit = 0.55 },
    ['npc_dota_hero_templar_assassin'] = { name = "Psi Fisher",       aggression = 0.6,  greed = 0.65, risk = 0.5,  independence = 0.55, teamSpirit = 0.4 },

    -- ==== Mid nukers / opportunists ====
    ['npc_dota_hero_invoker']          = { name = "Combo Chef",       aggression = 0.65, greed = 0.55, risk = 0.55, independence = 0.45, teamSpirit = 0.55, tiltSensitivity = 0.75 },
    ['npc_dota_hero_puck']             = { name = "Orb Dasher",       aggression = 0.65, greed = 0.5,  risk = 0.7,  independence = 0.5,  teamSpirit = 0.6 },
    ['npc_dota_hero_queenofpain']      = { name = "Pain Train",       aggression = 0.7,  greed = 0.5,  risk = 0.65, independence = 0.55, teamSpirit = 0.45 },
    ['npc_dota_hero_nevermore']        = { name = "Soul Stacker",     aggression = 0.65, greed = 0.6,  risk = 0.55, independence = 0.45, teamSpirit = 0.5 },
    ['npc_dota_hero_zuus']             = { name = "Global Spammer",   aggression = 0.5,  greed = 0.6,  risk = 0.3,  independence = 0.55, teamSpirit = 0.65 },
    ['npc_dota_hero_lina']             = { name = "Ult Picker",       aggression = 0.6,  greed = 0.55, risk = 0.45, independence = 0.45, teamSpirit = 0.6 },
    ['npc_dota_hero_storm_spirit']     = { name = "Ball Chaser",      aggression = 0.75, greed = 0.5,  risk = 0.8,  independence = 0.55, teamSpirit = 0.55 },
    ['npc_dota_hero_ember_spirit']     = { name = "Remnant Dancer",   aggression = 0.7,  greed = 0.55, risk = 0.7,  independence = 0.5,  teamSpirit = 0.5 },
    ['npc_dota_hero_void_spirit']      = { name = "Portal Jumper",    aggression = 0.65, greed = 0.55, risk = 0.7,  independence = 0.5,  teamSpirit = 0.5 },
    ['npc_dota_hero_obsidian_destroyer']={ name = "Astral Prison",    aggression = 0.5,  greed = 0.6,  risk = 0.35, independence = 0.4,  teamSpirit = 0.55 },
    ['npc_dota_hero_leshrac']          = { name = "Push Nuker",       aggression = 0.65, greed = 0.45, risk = 0.55, independence = 0.65, teamSpirit = 0.55 },
    ['npc_dota_hero_pugna']            = { name = "Ward Sniper",      aggression = 0.55, greed = 0.55, risk = 0.45, independence = 0.55, teamSpirit = 0.55 },
    ['npc_dota_hero_death_prophet']    = { name = "Exorcism Pusher",  aggression = 0.6,  greed = 0.45, risk = 0.5,  independence = 0.6,  teamSpirit = 0.6 },
    ['npc_dota_hero_dark_seer']        = { name = "Wall Diver",       aggression = 0.55, greed = 0.55, risk = 0.5,  independence = 0.4,  teamSpirit = 0.75 },
    ['npc_dota_hero_skywrath_mage']    = { name = "Silence Nuker",    aggression = 0.6,  greed = 0.35, risk = 0.35, independence = 0.35, teamSpirit = 0.75 },
    ['npc_dota_hero_ancient_apparition']={ name = "Ice Blast",        aggression = 0.45, greed = 0.3,  risk = 0.3,  independence = 0.4,  teamSpirit = 0.75 },
    ['npc_dota_hero_shredder']         = { name = "Chain Spammer",    aggression = 0.7,  greed = 0.5,  risk = 0.7,  independence = 0.5,  teamSpirit = 0.55 },
    ['npc_dota_hero_dragon_knight']    = { name = "Tank Pusher",      aggression = 0.55, greed = 0.5,  risk = 0.5,  independence = 0.5,  teamSpirit = 0.65 },
    ['npc_dota_hero_bristleback']      = { name = "Quill Tank",       aggression = 0.7,  greed = 0.45, risk = 0.75, independence = 0.4,  teamSpirit = 0.6 },
    ['npc_dota_hero_viper']            = { name = "Slow Picker",      aggression = 0.55, greed = 0.55, risk = 0.45, independence = 0.4,  teamSpirit = 0.5 },
    ['npc_dota_hero_razor']            = { name = "Static Link",      aggression = 0.55, greed = 0.55, risk = 0.5,  independence = 0.4,  teamSpirit = 0.55 },
    ['npc_dota_hero_necrolyte']        = { name = "Scythe Reaper",    aggression = 0.55, greed = 0.5,  risk = 0.6,  independence = 0.4,  teamSpirit = 0.65 },

    -- ==== Hard supports / team players ====
    ['npc_dota_hero_crystal_maiden']   = { name = "Freeze Maiden",    aggression = 0.35, greed = 0.2,  risk = 0.3,  independence = 0.25, teamSpirit = 0.9 },
    ['npc_dota_hero_lion']             = { name = "Finger Sup",       aggression = 0.7,  greed = 0.25, risk = 0.55, independence = 0.3,  teamSpirit = 0.9 },
    ['npc_dota_hero_shadow_shaman']    = { name = "Shack Pusher",     aggression = 0.6,  greed = 0.3,  risk = 0.45, independence = 0.45, teamSpirit = 0.85 },
    ['npc_dota_hero_warlock']          = { name = "Golem Summoner",   aggression = 0.5,  greed = 0.25, risk = 0.4,  independence = 0.3,  teamSpirit = 0.9 },
    ['npc_dota_hero_dazzle']           = { name = "Grave Priest",     aggression = 0.4,  greed = 0.25, risk = 0.35, independence = 0.3,  teamSpirit = 0.9 },
    ['npc_dota_hero_oracle']           = { name = "Promise Saver",    aggression = 0.5,  greed = 0.25, risk = 0.55, independence = 0.35, teamSpirit = 0.9 },
    ['npc_dota_hero_witch_doctor']     = { name = "Paralyze Doc",     aggression = 0.55, greed = 0.25, risk = 0.4,  independence = 0.3,  teamSpirit = 0.85 },
    ['npc_dota_hero_jakiro']           = { name = "Dual Breath",      aggression = 0.45, greed = 0.3,  risk = 0.35, independence = 0.4,  teamSpirit = 0.8 },
    ['npc_dota_hero_lich']             = { name = "Frost Shield",     aggression = 0.45, greed = 0.3,  risk = 0.3,  independence = 0.3,  teamSpirit = 0.9 },
    ['npc_dota_hero_omniknight']       = { name = "Purify Saint",     aggression = 0.45, greed = 0.3,  risk = 0.4,  independence = 0.25, teamSpirit = 0.9 },
    ['npc_dota_hero_dawnbreaker']      = { name = "Solar Guard",      aggression = 0.6,  greed = 0.3,  risk = 0.5,  independence = 0.3,  teamSpirit = 0.85 },
    ['npc_dota_hero_wisp']             = { name = "Relocate Wisp",    aggression = 0.4,  greed = 0.2,  risk = 0.5,  independence = 0.15, teamSpirit = 0.95 },
    ['npc_dota_hero_winter_wyvern']    = { name = "Curse Saver",      aggression = 0.45, greed = 0.25, risk = 0.4,  independence = 0.3,  teamSpirit = 0.9 },
    ['npc_dota_hero_treant']           = { name = "Tree Dad",         aggression = 0.4,  greed = 0.25, risk = 0.4,  independence = 0.3,  teamSpirit = 0.95 },
    ['npc_dota_hero_keeper_of_the_light']={ name = "Illuminate Sup",  aggression = 0.4,  greed = 0.35, risk = 0.3,  independence = 0.45, teamSpirit = 0.85 },
    ['npc_dota_hero_vengefulspirit']   = { name = "Swap Sup",         aggression = 0.6,  greed = 0.25, risk = 0.55, independence = 0.3,  teamSpirit = 0.9 },
    ['npc_dota_hero_rubick']           = { name = "Steal Artist",     aggression = 0.5,  greed = 0.35, risk = 0.4,  independence = 0.35, teamSpirit = 0.75 },
    ['npc_dota_hero_snapfire']         = { name = "Cookie Gran",      aggression = 0.5,  greed = 0.3,  risk = 0.4,  independence = 0.4,  teamSpirit = 0.8 },
    ['npc_dota_hero_hoodwink']         = { name = "Acorn Shot",       aggression = 0.5,  greed = 0.4,  risk = 0.45, independence = 0.45, teamSpirit = 0.75 },
    ['npc_dota_hero_grimstroke']       = { name = "Ink Binder",       aggression = 0.55, greed = 0.3,  risk = 0.4,  independence = 0.4,  teamSpirit = 0.8 },
    ['npc_dota_hero_ogre_magi']        = { name = "Multicaster",      aggression = 0.55, greed = 0.3,  risk = 0.45, independence = 0.3,  teamSpirit = 0.85 },
    ['npc_dota_hero_undying']          = { name = "Tomb Tanker",      aggression = 0.55, greed = 0.25, risk = 0.6,  independence = 0.3,  teamSpirit = 0.85 },
    ['npc_dota_hero_bane']             = { name = "Nightmare Sup",    aggression = 0.5,  greed = 0.3,  risk = 0.45, independence = 0.35, teamSpirit = 0.85 },
    ['npc_dota_hero_shadow_demon']     = { name = "Disruption Sup",   aggression = 0.5,  greed = 0.3,  risk = 0.45, independence = 0.35, teamSpirit = 0.85 },
    ['npc_dota_hero_disruptor']        = { name = "Static Storm",     aggression = 0.55, greed = 0.3,  risk = 0.4,  independence = 0.35, teamSpirit = 0.8 },
    ['npc_dota_hero_phoenix']          = { name = "Sun Egg",          aggression = 0.6,  greed = 0.35, risk = 0.65, independence = 0.3,  teamSpirit = 0.85 },
    ['npc_dota_hero_chen']             = { name = "Creep Herder",     aggression = 0.4,  greed = 0.4,  risk = 0.3,  independence = 0.55, teamSpirit = 0.8 },
    ['npc_dota_hero_enchantress']      = { name = "Enchant Jungler",  aggression = 0.45, greed = 0.45, risk = 0.35, independence = 0.55, teamSpirit = 0.7 },
    ['npc_dota_hero_venomancer']       = { name = "Ward Plague",      aggression = 0.55, greed = 0.4,  risk = 0.4,  independence = 0.4,  teamSpirit = 0.7 },

    -- ==== Other / flex ====
    ['npc_dota_hero_abaddon']          = { name = "Mist Guard",       aggression = 0.55, greed = 0.35, risk = 0.65, independence = 0.35, teamSpirit = 0.85 },
    ['npc_dota_hero_abyssal_underlord']= { name = "Pit Tank",         aggression = 0.6,  greed = 0.4,  risk = 0.55, independence = 0.35, teamSpirit = 0.75 },
    ['npc_dota_hero_beastmaster']      = { name = "Call Summoner",    aggression = 0.65, greed = 0.4,  risk = 0.55, independence = 0.55, teamSpirit = 0.7 },
    ['npc_dota_hero_brewmaster']       = { name = "Drunk Bruiser",    aggression = 0.75, greed = 0.45, risk = 0.8,  independence = 0.4,  teamSpirit = 0.75 },
    ['npc_dota_hero_chaos_knight']     = { name = "Phantasm Lord",    aggression = 0.7,  greed = 0.45, risk = 0.7,  independence = 0.4,  teamSpirit = 0.6 },
    ['npc_dota_hero_clinkz']           = { name = "Arrow Sniper",     aggression = 0.6,  greed = 0.55, risk = 0.55, independence = 0.65, teamSpirit = 0.4 },
    ['npc_dota_hero_kunkka']           = { name = "Sailor Captain",   aggression = 0.6,  greed = 0.45, risk = 0.55, independence = 0.35, teamSpirit = 0.75 },
    ['npc_dota_hero_life_stealer']     = { name = "Infest Dunk",      aggression = 0.7,  greed = 0.5,  risk = 0.65, independence = 0.35, teamSpirit = 0.7 },
    ['npc_dota_hero_mirana']           = { name = "Arrow Hunter",     aggression = 0.55, greed = 0.4,  risk = 0.55, independence = 0.55, teamSpirit = 0.6 },
    ['npc_dota_hero_nyx_assassin']     = { name = "Nyx Ganker",       aggression = 0.6,  greed = 0.4,  risk = 0.5,  independence = 0.5,  teamSpirit = 0.65 },
    ['npc_dota_hero_sand_king']        = { name = "Epicenter",        aggression = 0.65, greed = 0.4,  risk = 0.6,  independence = 0.45, teamSpirit = 0.75 },
    ['npc_dota_hero_silencer']         = { name = "Global Silence",   aggression = 0.5,  greed = 0.45, risk = 0.4,  independence = 0.45, teamSpirit = 0.7 },
    ['npc_dota_hero_slardar']          = { name = "Slithereen Gank",  aggression = 0.7,  greed = 0.45, risk = 0.6,  independence = 0.35, teamSpirit = 0.7 },
    ['npc_dota_hero_sven']             = { name = "Stormhammer Dad",  aggression = 0.65, greed = 0.55, risk = 0.6,  independence = 0.35, teamSpirit = 0.7 },
    ['npc_dota_hero_tiny']             = { name = "Toss Striker",     aggression = 0.7,  greed = 0.5,  risk = 0.6,  independence = 0.4,  teamSpirit = 0.7 },
    ['npc_dota_hero_tusk']             = { name = "Punch Ganker",     aggression = 0.7,  greed = 0.35, risk = 0.65, independence = 0.4,  teamSpirit = 0.75 },
    ['npc_dota_hero_weaver']           = { name = "Time Lapser",      aggression = 0.6,  greed = 0.55, risk = 0.7,  independence = 0.65, teamSpirit = 0.45 },
    ['npc_dota_hero_windrunner']       = { name = "Focus Fire",       aggression = 0.55, greed = 0.45, risk = 0.5,  independence = 0.45, teamSpirit = 0.65 },
    ['npc_dota_hero_elder_titan']      = { name = "Echo Init",        aggression = 0.55, greed = 0.35, risk = 0.55, independence = 0.4,  teamSpirit = 0.8 },
    ['npc_dota_hero_dark_willow']      = { name = "Cursed Crown",     aggression = 0.55, greed = 0.35, risk = 0.5,  independence = 0.45, teamSpirit = 0.75 },
    ['npc_dota_hero_earth_spirit']     = { name = "Rock Roller",      aggression = 0.65, greed = 0.4,  risk = 0.6,  independence = 0.5,  teamSpirit = 0.65 },
    ['npc_dota_hero_doom_bringer']     = { name = "Sadist Farmer",    aggression = 0.65, greed = 0.55, risk = 0.55, independence = 0.5,  teamSpirit = 0.6 },
    ['npc_dota_hero_marci']            = { name = "Dispose Punch",    aggression = 0.7,  greed = 0.4,  risk = 0.6,  independence = 0.45, teamSpirit = 0.75 },
    ['npc_dota_hero_ringmaster']       = { name = "Circus Master",    aggression = 0.55, greed = 0.35, risk = 0.5,  independence = 0.45, teamSpirit = 0.75 },
    ['npc_dota_hero_visage']           = { name = "Grave Keeper",     aggression = 0.55, greed = 0.4,  risk = 0.6,  independence = 0.5,  teamSpirit = 0.65 },
    ['npc_dota_hero_kez']              = { name = "Blade Dancer",     aggression = 0.7,  greed = 0.45, risk = 0.65, independence = 0.5,  teamSpirit = 0.55 },
    ['npc_dota_hero_largo']            = { name = "Largo",            aggression = 0.6,  greed = 0.45, risk = 0.55, independence = 0.45, teamSpirit = 0.6 },
    ['npc_dota_hero_lone_druid_bear']  = { name = "Spirit Bear",      aggression = 0.6,  greed = 0.55, risk = 0.55, independence = 0.85, teamSpirit = 0.4 },
}

function ____exports.GetArchetype(heroName)
    local base = deriveFromRoles(heroName)
    local override = OVERRIDES[heroName]
    if override == nil then return base end
    return {
        name            = override.name            or base.name,
        aggression      = override.aggression      or base.aggression,
        greed           = override.greed           or base.greed,
        risk            = override.risk            or base.risk,
        independence    = override.independence    or base.independence,
        teamSpirit      = override.teamSpirit      or base.teamSpirit,
        tiltSensitivity = override.tiltSensitivity or base.tiltSensitivity,
    }
end

function ____exports.GetOverrideCount()
    local c = 0
    for _ in pairs(OVERRIDES) do c = c + 1 end
    return c
end

return ____exports
