/**
 * Bot personality system.
 *
 * Adds per-bot personality traits that modulate mode desires, retreat aggression,
 * and draft picks. Each bot rolls traits at first access (once per match) from
 * its hero archetype plus random noise, so:
 *   - Same hero plays differently across games.
 *   - Different heroes lean into natural playstyles (rats rat, fighters fight).
 *   - Tilt rises with deaths/losing, shifting behavior mid-game.
 *
 * Exposed to Lua as J.Personality.* via jmz_func.lua.
 */

import { Unit } from "bots/ts_libs/dota";
import { GetArchetype, HeroArchetype } from "./aba_hero_archetypes";

declare function DotaTime(): number;
declare function GameTime(): number;
declare function RandomFloat(a: number, b: number): number;
declare function RandomInt(a: number, b: number): number;

// ============================================================
// Types
// ============================================================

export interface BotPersonality {
    aggression: number;       // 0..1 — fight vs. avoid
    greed: number;            // 0..1 — farm vs. fight
    risk: number;             // 0..1 — dive vs. play safe
    independence: number;     // 0..1 — rat vs. group
    teamSpirit: number;       // 0..1 — respond to pings / help allies
    tilt: number;             // 0..1 — dynamic; rises on deaths
    tiltSensitivity: number;  // 0..1 — how much tilt distorts this hero
    archetypeName: string;
    seed: number;
    _initialized: boolean;
    _lastTiltUpdate: number;
    _lastDeaths: number;
    _lastKills: number;
}

/**
 * A slot's target personality profile — generated once per draft slot per match,
 * used to bias hero scoring toward archetypes that "match" this slot.
 */
export interface SlotProfile {
    aggression: number;
    greed: number;
    risk: number;
    independence: number;
    teamSpirit: number;
}

export type ModeTag =
    | "farm"
    | "roam"
    | "team_roam"
    | "push"
    | "defend"
    | "retreat"
    | "rune"
    | "roshan"
    | "ward"
    | "laning"
    | "assemble";

type TraitName = "aggression" | "greed" | "risk" | "independence" | "teamSpirit";

interface TraitMultiplier {
    trait: TraitName;
    atZero: number;
    atOne: number;
}

// Module-scope state. Declared early so all functions can reference it regardless
// of Lua hoisting behavior in the TSTL output.
let fretBotsActive = false;

// ============================================================
// Mode-to-trait modulation table
//
// For each mode, how traits scale the desire multiplier.
// atZero = multiplier when trait is 0, atOne = when trait is 1.
// Linear interpolation between.
//
// Combined effect of multiple traits on a mode is multiplicative.
// Keep per-trait deltas modest (±0.35) so combined extremes stay
// reasonable (~0.4..2.0x) and don't completely override game-state
// driven desires.
// ============================================================

const MODE_MODIFIERS: Partial<Record<ModeTag, TraitMultiplier[]>> = {
    farm: [
        { trait: "greed", atZero: 0.75, atOne: 1.3 },
        { trait: "teamSpirit", atZero: 1.1, atOne: 0.85 },
    ],
    roam: [
        { trait: "aggression", atZero: 0.6, atOne: 1.35 },
        { trait: "greed", atZero: 1.1, atOne: 0.8 },
        { trait: "independence", atZero: 0.85, atOne: 1.15 },
    ],
    team_roam: [
        { trait: "aggression", atZero: 0.7, atOne: 1.25 },
        { trait: "teamSpirit", atZero: 0.55, atOne: 1.3 },
        { trait: "independence", atZero: 1.2, atOne: 0.7 },
    ],
    push: [
        { trait: "aggression", atZero: 0.8, atOne: 1.2 },
        { trait: "independence", atZero: 0.85, atOne: 1.25 },
    ],
    defend: [
        { trait: "teamSpirit", atZero: 0.7, atOne: 1.3 },
        { trait: "risk", atZero: 1.15, atOne: 0.9 },
    ],
    retreat: [
        { trait: "risk", atZero: 1.3, atOne: 0.7 },
    ],
    rune: [
        { trait: "greed", atZero: 0.9, atOne: 1.15 },
        { trait: "independence", atZero: 0.9, atOne: 1.1 },
    ],
    roshan: [
        { trait: "aggression", atZero: 0.85, atOne: 1.2 },
        { trait: "risk", atZero: 0.9, atOne: 1.15 },
        { trait: "teamSpirit", atZero: 0.9, atOne: 1.1 },
    ],
    ward: [
        { trait: "teamSpirit", atZero: 0.8, atOne: 1.2 },
    ],
    laning: [
        { trait: "greed", atZero: 0.95, atOne: 1.1 },
        { trait: "aggression", atZero: 0.95, atOne: 1.1 },
    ],
    assemble: [
        { trait: "teamSpirit", atZero: 0.65, atOne: 1.25 },
        { trait: "independence", atZero: 1.25, atOne: 0.8 },
    ],
};

// ============================================================
// Initialization
// ============================================================

const NOISE_STDDEV = 0.12;

function clamp01(v: number): number {
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

// Gaussian-ish noise via sum-of-two-uniforms (Irwin-Hall approximation).
// Cheap and stable enough for this use. Output approximately N(0, ~0.29).
function noise(stddev: number): number {
    const u = (RandomFloat(0, 1) + RandomFloat(0, 1) - 1);
    return u * stddev * 1.73;
}

function applyNoiseTo(value: number, stddev: number): number {
    return clamp01(value + noise(stddev));
}

function rollPersonalityFromArchetype(archetype: HeroArchetype, seed: number): BotPersonality {
    return {
        aggression: applyNoiseTo(archetype.aggression, NOISE_STDDEV),
        greed: applyNoiseTo(archetype.greed, NOISE_STDDEV),
        risk: applyNoiseTo(archetype.risk, NOISE_STDDEV),
        independence: applyNoiseTo(archetype.independence, NOISE_STDDEV),
        teamSpirit: applyNoiseTo(archetype.teamSpirit, NOISE_STDDEV),
        tilt: 0,
        tiltSensitivity: archetype.tiltSensitivity,
        archetypeName: archetype.name,
        seed,
        _initialized: true,
        _lastTiltUpdate: 0,
        _lastDeaths: 0,
        _lastKills: 0,
    };
}

function makeEmpty(): BotPersonality {
    return {
        aggression: 0.5,
        greed: 0.5,
        risk: 0.5,
        independence: 0.5,
        teamSpirit: 0.5,
        tilt: 0,
        tiltSensitivity: 0.5,
        archetypeName: "default",
        seed: 0,
        _initialized: false,
        _lastTiltUpdate: 0,
        _lastDeaths: 0,
        _lastKills: 0,
    };
}

// ============================================================
// Accessors
// ============================================================

/**
 * Get (or lazily create) the personality for a bot.
 * Stored on the bot object to avoid cross-bot leaks.
 */
export function Get(bot: Unit): BotPersonality {
    if (!bot) return makeEmpty();
    const anyBot = bot as any;
    if (anyBot._personality && anyBot._personality._initialized) {
        return anyBot._personality;
    }

    const heroName = bot.GetUnitName();
    const archetype = GetArchetype(heroName);
    const seed = bot.GetPlayerID() * 31 + RandomInt(1, 1000000);
    const p = rollPersonalityFromArchetype(archetype, seed);
    anyBot._personality = p;
    return p;
}

/**
 * Get effective trait value — base trait adjusted by current tilt.
 * Tilt shifts: aggression + risk up, teamSpirit down. Scaled by hero sensitivity.
 * FretBots mode amplifies tilt effects (bots are emotional when they're cheating).
 */
export function GetEffective(bot: Unit): BotPersonality {
    const p = Get(bot);
    const fretMul = fretBotsActive ? 1.4 : 1.0;
    const shift = p.tilt * p.tiltSensitivity * 0.35 * fretMul;
    // Return a view — shallow copy is fine for read-only consumers
    return {
        aggression: clamp01(p.aggression + shift),
        greed: clamp01(p.greed - shift * 0.4),
        risk: clamp01(p.risk + shift),
        independence: clamp01(p.independence + shift * 0.3),
        teamSpirit: clamp01(p.teamSpirit - shift * 0.7),
        tilt: p.tilt,
        tiltSensitivity: p.tiltSensitivity,
        archetypeName: p.archetypeName,
        seed: p.seed,
        _initialized: true,
        _lastTiltUpdate: p._lastTiltUpdate,
        _lastDeaths: p._lastDeaths,
        _lastKills: p._lastKills,
    };
}

// ============================================================
// Modulation
// ============================================================

function lerp(a: number, b: number, t: number): number {
    return a + (b - a) * t;
}

function computeMultiplier(mode: ModeTag, p: BotPersonality): number {
    const mods = MODE_MODIFIERS[mode];
    if (!mods) return 1.0;
    let mult = 1.0;
    for (let i = 0; i < mods.length; i++) {
        const m = mods[i];
        const traitValue = (p as any)[m.trait];
        if (typeof traitValue === "number") {
            mult = mult * lerp(m.atZero, m.atOne, traitValue);
        }
    }
    return mult;
}

/**
 * Multiply a mode desire by the bot's personality factor for that mode.
 * Returns the adjusted desire. Caller handles any final capping.
 *
 * Also self-updates tilt as a side effect (cheap — has internal 3s rate limiter).
 * This way tilt stays fresh without needing a dedicated Think hook.
 */
export function ModulateDesire(bot: Unit, desire: number, mode: ModeTag): number {
    if (!bot || desire === null || desire === undefined) return desire;
    // Don't touch zero/negative desires — no point amplifying nothing
    if (desire <= 0) return desire;
    UpdateTilt(bot);
    const p = GetEffective(bot);
    const mult = computeMultiplier(mode, p);
    return desire * mult;
}

/**
 * Raw multiplier for a mode — use when caller wants to compose with other factors.
 */
export function GetMultiplier(bot: Unit, mode: ModeTag): number {
    if (!bot) return 1.0;
    const p = GetEffective(bot);
    return computeMultiplier(mode, p);
}

// ============================================================
// Tilt dynamics
// ============================================================

const TILT_UPDATE_INTERVAL = 3.0;       // seconds between recalcs
const TILT_DECAY_PER_SEC = 0.005;       // natural cooldown
const TILT_PER_DEATH = 0.12;
const TILT_PER_KILL_REDUCTION = 0.08;
const TILT_PER_TOWER_DEATH = 0.06;
const TILT_MAX = 1.0;

/**
 * Refresh tilt based on bot stats. Call periodically (every ~3s per bot).
 * Kept cheap: just reads death/kill counts and adjusts.
 */
export function UpdateTilt(bot: Unit): void {
    if (!bot) return;
    const p = Get(bot);
    const now = DotaTime();
    const dt = now - p._lastTiltUpdate;
    if (dt < TILT_UPDATE_INTERVAL) return;

    const deaths = bot.GetDeaths();
    const kills = bot.GetKills();

    const newDeaths = deaths - p._lastDeaths;
    const newKills = kills - p._lastKills;

    if (newDeaths > 0) {
        p.tilt = clamp01(p.tilt + TILT_PER_DEATH * newDeaths);
    }
    if (newKills > 0) {
        p.tilt = clamp01(p.tilt - TILT_PER_KILL_REDUCTION * newKills);
    }
    // Natural decay so tilt doesn't stick forever after one bad stretch
    p.tilt = clamp01(p.tilt - TILT_DECAY_PER_SEC * dt);

    p._lastDeaths = deaths;
    p._lastKills = kills;
    p._lastTiltUpdate = now;
}

/**
 * Explicit hook callable from outside (e.g. when a tower the bot cared about dies).
 */
export function BumpTilt(bot: Unit, amount: number): void {
    if (!bot) return;
    const p = Get(bot);
    p.tilt = clamp01(p.tilt + amount);
}

// ============================================================
// FretBots amplification
// ============================================================

/**
 * Called from FretBots init once it's enabled.
 * Amplifies tilt sensitivity across all bots (the bots *are* cheating, so their
 * emotional state matters more — swingy games feel more alive).
 */
export function SetFretBotsMode(active: boolean): void {
    fretBotsActive = active;
}

export function IsFretBotsMode(): boolean {
    return fretBotsActive;
}

// ============================================================
// Draft affinity
// ============================================================

/**
 * Roll a fresh slot profile — a random target personality for a draft slot.
 * Call once per slot per match; pass the result to GetDraftAffinity for
 * every candidate hero to score them.
 *
 * Range is [0.2..0.8] to keep slots from being extreme outliers.
 */
export function RollSlotProfile(): SlotProfile {
    return {
        aggression: RandomFloat(0.2, 0.8),
        greed: RandomFloat(0.2, 0.8),
        risk: RandomFloat(0.2, 0.8),
        independence: RandomFloat(0.2, 0.8),
        teamSpirit: RandomFloat(0.2, 0.8),
    };
}

/**
 * How well a hero's archetype matches a slot profile. [0..1], 1 = perfect match.
 */
export function GetDraftAffinity(heroName: string, profile: SlotProfile): number {
    const archetype = GetArchetype(heroName);
    const d =
        math.abs(profile.aggression - archetype.aggression) +
        math.abs(profile.greed - archetype.greed) +
        math.abs(profile.risk - archetype.risk) +
        math.abs(profile.independence - archetype.independence) +
        math.abs(profile.teamSpirit - archetype.teamSpirit);
    return clamp01(1 - (d / 5));
}

// ============================================================
// Debug helpers
// ============================================================

/**
 * One-line summary of a bot's current personality. Useful for chat/print debugging.
 */
export function Describe(bot: Unit): string {
    const p = GetEffective(bot);
    return (
        p.archetypeName +
        " | agg=" + string.format("%.2f", p.aggression) +
        " grd=" + string.format("%.2f", p.greed) +
        " rsk=" + string.format("%.2f", p.risk) +
        " ind=" + string.format("%.2f", p.independence) +
        " tms=" + string.format("%.2f", p.teamSpirit) +
        " tilt=" + string.format("%.2f", p.tilt)
    );
}
