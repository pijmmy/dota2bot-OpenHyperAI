/**
 * Hero archetype data for the personality system.
 *
 * Each hero has five trait values in [0..1]:
 *   - aggression:   fight vs. avoid          (0 = passive, 1 = always looking for a fight)
 *   - greed:        farm vs. fight            (0 = always in fights, 1 = always farming)
 *   - risk:         dive vs. play safe        (0 = plays it safe, 1 = dives low HP, 1v3s)
 *   - independence: rat vs. group             (0 = always with team, 1 = split-pushes, solo)
 *   - teamSpirit:   respond to pings / help   (0 = lone wolf, 1 = selfless team player)
 *
 * Plus tiltSensitivity in [0..1]: how much tilt distorts this hero's behavior
 * (e.g. Pudge goes hard on tilt and chases hooks; Treant stays calm).
 *
 * Values are derived from the role map for most heroes, with explicit overrides
 * for heroes whose real-game playstyle isn't captured by role scores alone
 * (rats, yolo fighters, known tilters, etc.).
 */

import { HeroName } from "bots/ts_libs/dota/heroes";
import { HeroRolesMap } from "./aba_hero_roles_map";

declare function RandomFloat(a: number, b: number): number;

export interface HeroArchetype {
    name: string;
    aggression: number;
    greed: number;
    risk: number;
    independence: number;
    teamSpirit: number;
    tiltSensitivity: number;
}

// ============================================================
// Derivation from role scores
// ============================================================

function clamp(v: number, lo: number, hi: number): number {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// Role scores are 0..3 in the map; normalize to 0..1.
function n(score: number | undefined): number {
    if (!score) return 0;
    return math.min(1, score / 3);
}

function deriveFromRoles(heroName: string): HeroArchetype {
    const roles = HeroRolesMap[heroName];
    if (!roles) {
        // Fallback: unknown hero gets neutral defaults
        return {
            name: "unknown",
            aggression: 0.5,
            greed: 0.5,
            risk: 0.5,
            independence: 0.5,
            teamSpirit: 0.5,
            tiltSensitivity: 0.5,
        };
    }

    const carry = n(roles.carry);
    const disabler = n(roles.disabler);
    const durable = n(roles.durable);
    const escape = n(roles.escape);
    const initiator = n(roles.initiator);
    const jungler = n(roles.jungler);
    const nuker = n(roles.nuker);
    const support = n(roles.support);
    const pusher = n(roles.pusher);
    const healer = n(roles.healer);

    const aggression = clamp(0.4 + 0.25 * initiator + 0.12 * nuker + 0.08 * carry + 0.08 * durable, 0.2, 0.85);
    const greed = clamp(0.35 + 0.28 * carry + 0.1 * jungler - 0.2 * support, 0.15, 0.85);
    const risk = clamp(0.4 + 0.2 * durable + 0.15 * escape - 0.1 * support + 0.1 * initiator, 0.2, 0.85);
    const independence = clamp(0.35 + 0.22 * pusher + 0.18 * jungler + 0.1 * escape - 0.15 * support, 0.2, 0.85);
    const teamSpirit = clamp(0.4 + 0.25 * support + 0.15 * initiator + 0.2 * healer + 0.12 * disabler - 0.18 * carry, 0.2, 0.9);

    return {
        name: "derived",
        aggression,
        greed,
        risk,
        independence,
        teamSpirit,
        tiltSensitivity: 0.5,
    };
}

// ============================================================
// Manual overrides
//
// Only heroes whose real playstyle diverges meaningfully from role derivation
// get explicit entries. Partial — unspecified fields fall back to derivation.
// Names are free-form for debug readability.
// ============================================================

interface PartialArchetype {
    name?: string;
    aggression?: number;
    greed?: number;
    risk?: number;
    independence?: number;
    teamSpirit?: number;
    tiltSensitivity?: number;
}

const OVERRIDES: Record<string, PartialArchetype> = {
    // ---- Rat / split-push archetypes ----
    [HeroName.NaturesProphet]: { name: "Rat King", aggression: 0.55, greed: 0.6, risk: 0.4, independence: 0.9, teamSpirit: 0.35 },
    [HeroName.Tinker]: { name: "Ratter Mage", aggression: 0.35, greed: 0.7, risk: 0.25, independence: 0.85, teamSpirit: 0.3, tiltSensitivity: 0.75 },
    [HeroName.Techies]: { name: "Nuisance", aggression: 0.4, greed: 0.3, risk: 0.3, independence: 0.75, teamSpirit: 0.5, tiltSensitivity: 0.9 },
    [HeroName.Lycan]: { name: "Rat Wolf", aggression: 0.65, greed: 0.55, risk: 0.55, independence: 0.85, teamSpirit: 0.4 },
    [HeroName.Broodmother]: { name: "Spider Rat", aggression: 0.55, greed: 0.5, risk: 0.5, independence: 0.85, teamSpirit: 0.35 },
    [HeroName.LoneDruid]: { name: "Bear Split", aggression: 0.55, greed: 0.55, risk: 0.45, independence: 0.8, teamSpirit: 0.4 },
    [HeroName.ArcWarden]: { name: "Ultra Rat", aggression: 0.3, greed: 0.9, risk: 0.25, independence: 0.9, teamSpirit: 0.25 },
    [HeroName.Meepo]: { name: "Split King", aggression: 0.7, greed: 0.7, risk: 0.55, independence: 0.75, teamSpirit: 0.35, tiltSensitivity: 0.85 },

    // ---- Yolo / aggressive fighters ----
    [HeroName.Huskar]: { name: "Yolo Berserker", aggression: 0.9, greed: 0.25, risk: 0.9, independence: 0.4, teamSpirit: 0.5, tiltSensitivity: 0.85 },
    [HeroName.Bloodseeker]: { name: "Blood Hunter", aggression: 0.9, greed: 0.3, risk: 0.8, independence: 0.5, teamSpirit: 0.55 },
    [HeroName.SpiritBreaker]: { name: "Cosmic Gank", aggression: 0.85, greed: 0.25, risk: 0.8, independence: 0.55, teamSpirit: 0.7 },
    [HeroName.Pudge]: { name: "Hook Addict", aggression: 0.8, greed: 0.25, risk: 0.75, independence: 0.45, teamSpirit: 0.65, tiltSensitivity: 0.95 },
    [HeroName.PhantomAssassin]: { name: "Crit Fisher", aggression: 0.75, greed: 0.5, risk: 0.7, independence: 0.45, teamSpirit: 0.55 },
    [HeroName.LegionCommander]: { name: "Duel Diva", aggression: 0.9, greed: 0.35, risk: 0.85, independence: 0.45, teamSpirit: 0.7, tiltSensitivity: 0.7 },
    [HeroName.Axe]: { name: "Call Fisher", aggression: 0.85, greed: 0.35, risk: 0.8, independence: 0.4, teamSpirit: 0.75 },
    [HeroName.NightStalker]: { name: "Night Terror", aggression: 0.8, greed: 0.35, risk: 0.7, independence: 0.55, teamSpirit: 0.6 },
    [HeroName.Ursa]: { name: "Bear Rage", aggression: 0.8, greed: 0.4, risk: 0.7, independence: 0.45, teamSpirit: 0.6 },
    [HeroName.Clockwerk]: { name: "Rocket Diva", aggression: 0.8, greed: 0.25, risk: 0.75, independence: 0.5, teamSpirit: 0.8 },
    [HeroName.Slark]: { name: "Swim King", aggression: 0.7, greed: 0.5, risk: 0.8, independence: 0.55, teamSpirit: 0.5 },
    [HeroName.PrimalBeast]: { name: "Rampage Prime", aggression: 0.85, greed: 0.3, risk: 0.85, independence: 0.35, teamSpirit: 0.75 },
    [HeroName.MonkeyKing]: { name: "Cloud Jumper", aggression: 0.7, greed: 0.5, risk: 0.65, independence: 0.55, teamSpirit: 0.55 },
    [HeroName.Pangolier]: { name: "Rolling Rogue", aggression: 0.7, greed: 0.45, risk: 0.7, independence: 0.5, teamSpirit: 0.65 },
    [HeroName.Riki]: { name: "Shadow Stab", aggression: 0.65, greed: 0.5, risk: 0.55, independence: 0.6, teamSpirit: 0.5 },
    [HeroName.BountyHunter]: { name: "Shuriken Scout", aggression: 0.65, greed: 0.45, risk: 0.5, independence: 0.55, teamSpirit: 0.7 },
    [HeroName.Centaur]: { name: "Stomp Tank", aggression: 0.7, greed: 0.35, risk: 0.7, independence: 0.35, teamSpirit: 0.8 },
    [HeroName.WraithKing]: { name: "Undead Carry", aggression: 0.65, greed: 0.55, risk: 0.75, independence: 0.4, teamSpirit: 0.55 },
    [HeroName.TrollWarlord]: { name: "Troll Carry", aggression: 0.7, greed: 0.5, risk: 0.6, independence: 0.45, teamSpirit: 0.55 },
    [HeroName.Juggernaut]: { name: "Omni Blade", aggression: 0.65, greed: 0.55, risk: 0.65, independence: 0.45, teamSpirit: 0.6 },
    [HeroName.Mars]: { name: "Arena Lord", aggression: 0.75, greed: 0.4, risk: 0.65, independence: 0.4, teamSpirit: 0.75 },
    [HeroName.Magnus]: { name: "RP Gambler", aggression: 0.7, greed: 0.4, risk: 0.6, independence: 0.35, teamSpirit: 0.85, tiltSensitivity: 0.7 },
    [HeroName.Earthshaker]: { name: "Echo Gambler", aggression: 0.7, greed: 0.35, risk: 0.65, independence: 0.4, teamSpirit: 0.85 },
    [HeroName.Tidehunter]: { name: "Ravage Prime", aggression: 0.65, greed: 0.3, risk: 0.55, independence: 0.35, teamSpirit: 0.85 },
    [HeroName.Enigma]: { name: "Black Hole Fisher", aggression: 0.65, greed: 0.4, risk: 0.6, independence: 0.45, teamSpirit: 0.85 },
    [HeroName.FacelessVoid]: { name: "Chrono Sphere", aggression: 0.7, greed: 0.5, risk: 0.6, independence: 0.4, teamSpirit: 0.8, tiltSensitivity: 0.7 },
    [HeroName.Batrider]: { name: "Lassoer", aggression: 0.7, greed: 0.35, risk: 0.65, independence: 0.45, teamSpirit: 0.75 },

    // ---- Greedy farmers ----
    [HeroName.Antimage]: { name: "Blink Farmer", aggression: 0.4, greed: 0.85, risk: 0.45, independence: 0.7, teamSpirit: 0.3 },
    [HeroName.Spectre]: { name: "Haunt Farmer", aggression: 0.5, greed: 0.8, risk: 0.5, independence: 0.55, teamSpirit: 0.6 },
    [HeroName.Medusa]: { name: "Mana Shield", aggression: 0.35, greed: 0.85, risk: 0.3, independence: 0.4, teamSpirit: 0.5 },
    [HeroName.Terrorblade]: { name: "Metamorph", aggression: 0.4, greed: 0.8, risk: 0.4, independence: 0.65, teamSpirit: 0.4 },
    [HeroName.NagaSiren]: { name: "Song Farmer", aggression: 0.5, greed: 0.75, risk: 0.4, independence: 0.55, teamSpirit: 0.55 },
    [HeroName.PhantomLancer]: { name: "Illusion Farmer", aggression: 0.5, greed: 0.75, risk: 0.55, independence: 0.55, teamSpirit: 0.45 },
    [HeroName.Alchemist]: { name: "Gold Hoarder", aggression: 0.55, greed: 0.75, risk: 0.5, independence: 0.4, teamSpirit: 0.55 },

    // ---- Position-1 safe-lane carries (careful, team-dependent) ----
    [HeroName.Sniper]: { name: "Safe Shooter", aggression: 0.45, greed: 0.65, risk: 0.3, independence: 0.4, teamSpirit: 0.45 },
    [HeroName.DrowRanger]: { name: "Silver Aura", aggression: 0.45, greed: 0.55, risk: 0.3, independence: 0.35, teamSpirit: 0.55 },
    [HeroName.Luna]: { name: "Moon Blade", aggression: 0.6, greed: 0.55, risk: 0.45, independence: 0.4, teamSpirit: 0.55 },
    [HeroName.Gyrocopter]: { name: "Call Down", aggression: 0.6, greed: 0.55, risk: 0.45, independence: 0.4, teamSpirit: 0.7 },
    [HeroName.Morphling]: { name: "Morph Out", aggression: 0.65, greed: 0.55, risk: 0.75, independence: 0.5, teamSpirit: 0.5 },
    [HeroName.Muerta]: { name: "Pistol Cat", aggression: 0.55, greed: 0.55, risk: 0.4, independence: 0.4, teamSpirit: 0.55 },
    [HeroName.TemplarAssassin]: { name: "Psi Fisher", aggression: 0.6, greed: 0.65, risk: 0.5, independence: 0.55, teamSpirit: 0.4 },

    // ---- Mid nukers / opportunists ----
    [HeroName.Invoker]: { name: "Combo Chef", aggression: 0.65, greed: 0.55, risk: 0.55, independence: 0.45, teamSpirit: 0.55, tiltSensitivity: 0.75 },
    [HeroName.Puck]: { name: "Orb Dasher", aggression: 0.65, greed: 0.5, risk: 0.7, independence: 0.5, teamSpirit: 0.6 },
    [HeroName.QueenOfPain]: { name: "Pain Train", aggression: 0.7, greed: 0.5, risk: 0.65, independence: 0.55, teamSpirit: 0.45 },
    [HeroName.ShadowFiend]: { name: "Soul Stacker", aggression: 0.65, greed: 0.6, risk: 0.55, independence: 0.45, teamSpirit: 0.5 },
    [HeroName.Zeus]: { name: "Global Spammer", aggression: 0.5, greed: 0.6, risk: 0.3, independence: 0.55, teamSpirit: 0.65 },
    [HeroName.Lina]: { name: "Ult Picker", aggression: 0.6, greed: 0.55, risk: 0.45, independence: 0.45, teamSpirit: 0.6 },
    [HeroName.StormSpirit]: { name: "Ball Chaser", aggression: 0.75, greed: 0.5, risk: 0.8, independence: 0.55, teamSpirit: 0.55 },
    [HeroName.EmberSpirit]: { name: "Remnant Dancer", aggression: 0.7, greed: 0.55, risk: 0.7, independence: 0.5, teamSpirit: 0.5 },
    [HeroName.VoidSpirit]: { name: "Portal Jumper", aggression: 0.65, greed: 0.55, risk: 0.7, independence: 0.5, teamSpirit: 0.5 },
    [HeroName.OutworldDestroyer]: { name: "Astral Prison", aggression: 0.5, greed: 0.6, risk: 0.35, independence: 0.4, teamSpirit: 0.55 },
    [HeroName.Leshrac]: { name: "Push Nuker", aggression: 0.65, greed: 0.45, risk: 0.55, independence: 0.65, teamSpirit: 0.55 },
    [HeroName.Pugna]: { name: "Ward Sniper", aggression: 0.55, greed: 0.55, risk: 0.45, independence: 0.55, teamSpirit: 0.55 },
    [HeroName.DeathProphet]: { name: "Exorcism Pusher", aggression: 0.6, greed: 0.45, risk: 0.5, independence: 0.6, teamSpirit: 0.6 },
    [HeroName.DarkSeer]: { name: "Wall Diver", aggression: 0.55, greed: 0.55, risk: 0.5, independence: 0.4, teamSpirit: 0.75 },
    [HeroName.SkywrathMage]: { name: "Silence Nuker", aggression: 0.6, greed: 0.35, risk: 0.35, independence: 0.35, teamSpirit: 0.75 },
    [HeroName.AncientApparition]: { name: "Ice Blast", aggression: 0.45, greed: 0.3, risk: 0.3, independence: 0.4, teamSpirit: 0.75 },
    [HeroName.Timbersaw]: { name: "Chain Spammer", aggression: 0.7, greed: 0.5, risk: 0.7, independence: 0.5, teamSpirit: 0.55 },
    [HeroName.DragonKnight]: { name: "Tank Pusher", aggression: 0.55, greed: 0.5, risk: 0.5, independence: 0.5, teamSpirit: 0.65 },
    [HeroName.Bristleback]: { name: "Quill Tank", aggression: 0.7, greed: 0.45, risk: 0.75, independence: 0.4, teamSpirit: 0.6 },
    [HeroName.Viper]: { name: "Slow Picker", aggression: 0.55, greed: 0.55, risk: 0.45, independence: 0.4, teamSpirit: 0.5 },
    [HeroName.Razor]: { name: "Static Link", aggression: 0.55, greed: 0.55, risk: 0.5, independence: 0.4, teamSpirit: 0.55 },
    [HeroName.Necrophos]: { name: "Scythe Reaper", aggression: 0.55, greed: 0.5, risk: 0.6, independence: 0.4, teamSpirit: 0.65 },

    // ---- Hard supports / team players ----
    [HeroName.CrystalMaiden]: { name: "Freeze Maiden", aggression: 0.35, greed: 0.2, risk: 0.3, independence: 0.25, teamSpirit: 0.9 },
    [HeroName.Lion]: { name: "Finger Sup", aggression: 0.7, greed: 0.25, risk: 0.55, independence: 0.3, teamSpirit: 0.9 },
    [HeroName.ShadowShaman]: { name: "Shack Pusher", aggression: 0.6, greed: 0.3, risk: 0.45, independence: 0.45, teamSpirit: 0.85 },
    [HeroName.Warlock]: { name: "Golem Summoner", aggression: 0.5, greed: 0.25, risk: 0.4, independence: 0.3, teamSpirit: 0.9 },
    [HeroName.Dazzle]: { name: "Grave Priest", aggression: 0.4, greed: 0.25, risk: 0.35, independence: 0.3, teamSpirit: 0.9 },
    [HeroName.Oracle]: { name: "Promise Saver", aggression: 0.5, greed: 0.25, risk: 0.55, independence: 0.35, teamSpirit: 0.9 },
    [HeroName.WitchDoctor]: { name: "Paralyze Doc", aggression: 0.55, greed: 0.25, risk: 0.4, independence: 0.3, teamSpirit: 0.85 },
    [HeroName.Jakiro]: { name: "Dual Breath", aggression: 0.45, greed: 0.3, risk: 0.35, independence: 0.4, teamSpirit: 0.8 },
    [HeroName.Lich]: { name: "Frost Shield", aggression: 0.45, greed: 0.3, risk: 0.3, independence: 0.3, teamSpirit: 0.9 },
    [HeroName.Omniknight]: { name: "Purify Saint", aggression: 0.45, greed: 0.3, risk: 0.4, independence: 0.25, teamSpirit: 0.9 },
    [HeroName.Dawnbreaker]: { name: "Solar Guard", aggression: 0.6, greed: 0.3, risk: 0.5, independence: 0.3, teamSpirit: 0.85 },
    [HeroName.IO]: { name: "Relocate Wisp", aggression: 0.4, greed: 0.2, risk: 0.5, independence: 0.15, teamSpirit: 0.95 },
    [HeroName.WinterWyvern]: { name: "Curse Saver", aggression: 0.45, greed: 0.25, risk: 0.4, independence: 0.3, teamSpirit: 0.9 },
    [HeroName.TreantProtector]: { name: "Tree Dad", aggression: 0.4, greed: 0.25, risk: 0.4, independence: 0.3, teamSpirit: 0.95 },
    [HeroName.KeeperOfTheLight]: { name: "Illuminate Sup", aggression: 0.4, greed: 0.35, risk: 0.3, independence: 0.45, teamSpirit: 0.85 },
    [HeroName.VengefulSpirit]: { name: "Swap Sup", aggression: 0.6, greed: 0.25, risk: 0.55, independence: 0.3, teamSpirit: 0.9 },
    [HeroName.Rubick]: { name: "Steal Artist", aggression: 0.5, greed: 0.35, risk: 0.4, independence: 0.35, teamSpirit: 0.75 },
    [HeroName.Snapfire]: { name: "Cookie Gran", aggression: 0.5, greed: 0.3, risk: 0.4, independence: 0.4, teamSpirit: 0.8 },
    [HeroName.Hoodwink]: { name: "Acorn Shot", aggression: 0.5, greed: 0.4, risk: 0.45, independence: 0.45, teamSpirit: 0.75 },
    [HeroName.Grimstroke]: { name: "Ink Binder", aggression: 0.55, greed: 0.3, risk: 0.4, independence: 0.4, teamSpirit: 0.8 },
    [HeroName.OgreMagi]: { name: "Multicaster", aggression: 0.55, greed: 0.3, risk: 0.45, independence: 0.3, teamSpirit: 0.85 },
    [HeroName.Undying]: { name: "Tomb Tanker", aggression: 0.55, greed: 0.25, risk: 0.6, independence: 0.3, teamSpirit: 0.85 },
    [HeroName.Bane]: { name: "Nightmare Sup", aggression: 0.5, greed: 0.3, risk: 0.45, independence: 0.35, teamSpirit: 0.85 },
    [HeroName.ShadowDeamon]: { name: "Disruption Sup", aggression: 0.5, greed: 0.3, risk: 0.45, independence: 0.35, teamSpirit: 0.85 },
    [HeroName.Disruptor]: { name: "Static Storm", aggression: 0.55, greed: 0.3, risk: 0.4, independence: 0.35, teamSpirit: 0.8 },
    [HeroName.Phoenix]: { name: "Sun Egg", aggression: 0.6, greed: 0.35, risk: 0.65, independence: 0.3, teamSpirit: 0.85 },
    [HeroName.Chen]: { name: "Creep Herder", aggression: 0.4, greed: 0.4, risk: 0.3, independence: 0.55, teamSpirit: 0.8 },
    [HeroName.Enchantress]: { name: "Enchant Jungler", aggression: 0.45, greed: 0.45, risk: 0.35, independence: 0.55, teamSpirit: 0.7 },
    [HeroName.Venomancer]: { name: "Ward Plague", aggression: 0.55, greed: 0.4, risk: 0.4, independence: 0.4, teamSpirit: 0.7 },

    // ---- Other / flex ----
    [HeroName.Abaddon]: { name: "Mist Guard", aggression: 0.55, greed: 0.35, risk: 0.65, independence: 0.35, teamSpirit: 0.85 },
    [HeroName.Underlord]: { name: "Pit Tank", aggression: 0.6, greed: 0.4, risk: 0.55, independence: 0.35, teamSpirit: 0.75 },
    [HeroName.Beastmaster]: { name: "Call Summoner", aggression: 0.65, greed: 0.4, risk: 0.55, independence: 0.55, teamSpirit: 0.7 },
    [HeroName.Brewmaster]: { name: "Drunk Bruiser", aggression: 0.75, greed: 0.45, risk: 0.8, independence: 0.4, teamSpirit: 0.75 },
    [HeroName.ChaosKnight]: { name: "Phantasm Lord", aggression: 0.7, greed: 0.45, risk: 0.7, independence: 0.4, teamSpirit: 0.6 },
    [HeroName.Clinkz]: { name: "Arrow Sniper", aggression: 0.6, greed: 0.55, risk: 0.55, independence: 0.65, teamSpirit: 0.4 },
    [HeroName.Kunkka]: { name: "Sailor Captain", aggression: 0.6, greed: 0.45, risk: 0.55, independence: 0.35, teamSpirit: 0.75 },
    [HeroName.Lifestealer]: { name: "Infest Dunk", aggression: 0.7, greed: 0.5, risk: 0.65, independence: 0.35, teamSpirit: 0.7 },
    [HeroName.Mirana]: { name: "Arrow Hunter", aggression: 0.55, greed: 0.4, risk: 0.55, independence: 0.55, teamSpirit: 0.6 },
    [HeroName.NyxAssassin]: { name: "Nyx Ganker", aggression: 0.6, greed: 0.4, risk: 0.5, independence: 0.5, teamSpirit: 0.65 },
    [HeroName.SandKing]: { name: "Epicenter", aggression: 0.65, greed: 0.4, risk: 0.6, independence: 0.45, teamSpirit: 0.75 },
    [HeroName.Silencer]: { name: "Global Silence", aggression: 0.5, greed: 0.45, risk: 0.4, independence: 0.45, teamSpirit: 0.7 },
    [HeroName.Slardar]: { name: "Slithereen Gank", aggression: 0.7, greed: 0.45, risk: 0.6, independence: 0.35, teamSpirit: 0.7 },
    [HeroName.Sven]: { name: "Stormhammer Dad", aggression: 0.65, greed: 0.55, risk: 0.6, independence: 0.35, teamSpirit: 0.7 },
    [HeroName.Tiny]: { name: "Toss Striker", aggression: 0.7, greed: 0.5, risk: 0.6, independence: 0.4, teamSpirit: 0.7 },
    [HeroName.Tusk]: { name: "Punch Ganker", aggression: 0.7, greed: 0.35, risk: 0.65, independence: 0.4, teamSpirit: 0.75 },
    [HeroName.Weaver]: { name: "Time Lapser", aggression: 0.6, greed: 0.55, risk: 0.7, independence: 0.65, teamSpirit: 0.45 },
    [HeroName.Windrunner]: { name: "Focus Fire", aggression: 0.55, greed: 0.45, risk: 0.5, independence: 0.45, teamSpirit: 0.65 },
    [HeroName.ElderTitan]: { name: "Echo Init", aggression: 0.55, greed: 0.35, risk: 0.55, independence: 0.4, teamSpirit: 0.8 },
    [HeroName.DarkWillow]: { name: "Cursed Crown", aggression: 0.55, greed: 0.35, risk: 0.5, independence: 0.45, teamSpirit: 0.75 },
    [HeroName.EarthSpirit]: { name: "Rock Roller", aggression: 0.65, greed: 0.4, risk: 0.6, independence: 0.5, teamSpirit: 0.65 },
    [HeroName.Doom]: { name: "Sadist Farmer", aggression: 0.65, greed: 0.55, risk: 0.55, independence: 0.5, teamSpirit: 0.6 },
    [HeroName.Marci]: { name: "Dispose Punch", aggression: 0.7, greed: 0.4, risk: 0.6, independence: 0.45, teamSpirit: 0.75 },
    [HeroName.Ringmaster]: { name: "Circus Master", aggression: 0.55, greed: 0.35, risk: 0.5, independence: 0.45, teamSpirit: 0.75 },
    [HeroName.Visage]: { name: "Grave Keeper", aggression: 0.55, greed: 0.4, risk: 0.6, independence: 0.5, teamSpirit: 0.65 },
    [HeroName.Kez]: { name: "Blade Dancer", aggression: 0.7, greed: 0.45, risk: 0.65, independence: 0.5, teamSpirit: 0.55 },
    // Largo — no role data yet; moderate fighter default
    [HeroName.Largo]: { name: "Largo", aggression: 0.6, greed: 0.45, risk: 0.55, independence: 0.45, teamSpirit: 0.6 },
    // Lone Druid Bear (minion) — shouldn't normally be queried but safe default
    [HeroName.LoneDruidBear]: { name: "Spirit Bear", aggression: 0.6, greed: 0.55, risk: 0.55, independence: 0.85, teamSpirit: 0.4 },
};

// ============================================================
// Public API
// ============================================================

/**
 * Look up a hero's archetype — override if present, else derived from role data.
 * Safe to call with an unknown hero name (returns neutral defaults).
 */
export function GetArchetype(heroName: string): HeroArchetype {
    const base = deriveFromRoles(heroName);
    const override = OVERRIDES[heroName];
    if (!override) return base;
    return {
        name: override.name ?? base.name,
        aggression: override.aggression ?? base.aggression,
        greed: override.greed ?? base.greed,
        risk: override.risk ?? base.risk,
        independence: override.independence ?? base.independence,
        teamSpirit: override.teamSpirit ?? base.teamSpirit,
        tiltSensitivity: override.tiltSensitivity ?? base.tiltSensitivity,
    };
}

/**
 * For tests/debug: how many heroes have explicit overrides?
 */
export function GetOverrideCount(): number {
    let n = 0;
    for (const _ in OVERRIDES) n++;
    return n;
}
