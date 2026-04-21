/**
 * Focus target system.
 *
 * Per team, computes a single "priority focus enemy" based on isolation, HP,
 * core/support value, and reachability. Used by team-plan to trigger
 * commit_kill intent when enough allies are near the focus, and by bot logic
 * that wants to override attack targets toward the team priority.
 *
 * Exposed as J.Focus.*.
 */

import { Team, Unit } from "bots/ts_libs/dota";

declare function DotaTime(): number;
declare function GetTeam(): Team;
declare function GetOpposingTeam(): Team;
declare function GetTeamPlayers(team: Team): number[];
declare function GetTeamMember(n: number): Unit | null;
declare function IsHeroAlive(playerID: number): boolean;
declare function GetHeroLastSeenInfo(playerID: number): any;
declare function GetUnitToUnitDistance(a: Unit, b: Unit): number;
declare function GetUnitToLocationDistance(a: Unit, loc: any): number;

// Lazy-loaded jmz to avoid require cycles.
let _jmz: any = null;
function jmz(): any {
    if (_jmz === null) {
        _jmz = require(GetScriptDirectory() + "/FunLib/jmz_func");
    }
    return _jmz;
}

// ============================================================
// Types
// ============================================================

export interface FocusTarget {
    unit: Unit | null;
    playerID: number;
    score: number;
    reason: string;
    validUntil: number;
    lastComputeTime: number;
}

// ============================================================
// State
// ============================================================

const FOCUS_RECOMPUTE_INTERVAL = 1.5;
const FOCUS_TTL = 5.0;
const ISOLATION_RADIUS = 1500;         // enemy is "isolated" if no ally within this
const REACHABLE_RADIUS = 2200;         // our side must have someone this close
const LAST_SEEN_WINDOW = 4.0;          // seconds — consider recently-seen enemies

let currentFocus: FocusTarget = {
    unit: null,
    playerID: -1,
    score: 0,
    reason: "none",
    validUntil: 0,
    lastComputeTime: -999,
};

// ============================================================
// Public API
// ============================================================

/**
 * Get current focus target (or null). Caller should check validity.
 */
export function GetFocus(): FocusTarget {
    return currentFocus;
}

/**
 * Rate-limited recompute. Safe to call from hot paths.
 */
export function MaybeRecompute(bot: Unit): FocusTarget {
    const now = DotaTime();
    if (now - currentFocus.lastComputeTime < FOCUS_RECOMPUTE_INTERVAL) {
        return currentFocus;
    }
    const [ok, result] = pcall(computeFocus);
    if (ok && result !== null) {
        result.lastComputeTime = now;
        result.validUntil = now + FOCUS_TTL;
        currentFocus = result;
    } else {
        currentFocus.lastComputeTime = now;
    }
    return currentFocus;
}

/**
 * Is the focus target reasonably attackable by THIS bot right now?
 * Useful for hero-specific Consider functions that want to force-target the focus.
 */
export function IsFocusTargetable(bot: Unit, maxRange: number): boolean {
    const f = currentFocus;
    if (!f.unit || DotaTime() > f.validUntil) return false;
    const J = jmz();
    if (!J.IsValidHero(f.unit)) return false;
    return GetUnitToUnitDistance(bot, f.unit) <= maxRange;
}

/**
 * Return the focus unit if it's within maxRange and a valid hero, else null.
 * Hero logic that wants to bias target selection can call this before falling
 * back to their normal target-picking.
 */
export function GetFocusIfInRange(bot: Unit, maxRange: number): Unit | null {
    if (!IsFocusTargetable(bot, maxRange)) return null;
    return currentFocus.unit;
}

// ============================================================
// Computation
// ============================================================

function computeFocus(): FocusTarget | null {
    const J = jmz();
    const enemyTeam = GetOpposingTeam();
    const myTeam = GetTeam();
    const now = DotaTime();

    // Collect candidate enemy heroes (alive and recently seen)
    const enemyPlayers = GetTeamPlayers(enemyTeam);
    let best: FocusTarget | null = null;

    for (let i = 0; i < enemyPlayers.length; i++) {
        const pid = enemyPlayers[i];
        if (!IsHeroAlive(pid)) continue;

        const info = GetHeroLastSeenInfo(pid);
        if (!info || !info[0]) continue;
        if (info[0].time_since_seen > LAST_SEEN_WINDOW) continue;

        // Find the live unit if possible. Last-seen location is a fallback.
        const loc = info[0].location;

        // Reachability: someone on our team must be within REACHABLE_RADIUS.
        const ourNear = J.GetAlliesNearLoc(loc, REACHABLE_RADIUS);
        if (ourNear === null || ourNear.length === 0) continue;

        // Isolation: no enemy ally within ISOLATION_RADIUS of this enemy.
        const enemiesAroundThem = countEnemyAlliesNearLoc(enemyTeam, pid, loc, ISOLATION_RADIUS);
        const isolated = enemiesAroundThem === 0 ? 1 : enemiesAroundThem === 1 ? 0.3 : 0;

        // Actual hero unit (if visible) for HP check; fall back to seen HP data
        const heroUnit = findVisibleEnemyHero(pid);
        const hp = heroUnit ? J.GetHP(heroUnit) : 1.0;
        const lowHP = 1.0 - hp;

        const isCore = heroUnit ? (J.IsCore(heroUnit) ? 1 : 0) : 0.5;

        // Score: isolation dominates, then HP, then reachability, small value bump.
        const reach = math.min(ourNear.length, 3) / 3;
        const score = 2.0 * isolated + 1.6 * lowHP + 0.6 * reach + 0.4 * isCore;

        if (best === null || score > best.score) {
            best = {
                unit: heroUnit,
                playerID: pid,
                score: score,
                reason: describeReason(isolated, hp, ourNear.length, isCore),
                validUntil: 0,
                lastComputeTime: 0,
            };
        }
    }

    // Threshold: don't lock a focus unless score is meaningful (avoids thrash on random sightings)
    if (best !== null && best.score >= 0.8) {
        return best;
    }
    return {
        unit: null,
        playerID: -1,
        score: 0,
        reason: "no viable target",
        validUntil: 0,
        lastComputeTime: 0,
    };
}

function describeReason(isolated: number, hp: number, reach: number, isCore: number): string {
    const parts: string[] = [];
    if (isolated >= 1) parts.push("isolated");
    else if (isolated > 0) parts.push("semi-isolated");
    if (hp < 0.5) parts.push("low-hp");
    if (isCore > 0.5) parts.push("core");
    if (reach >= 3) parts.push("we-have-3+-near");
    if (parts.length === 0) return "default";
    return table.concat(parts, ",");
}

// Count how many of an enemy player's teammates are near a location.
function countEnemyAlliesNearLoc(team: Team, excludePID: number, loc: any, radius: number): number {
    const players = GetTeamPlayers(team);
    let n = 0;
    for (let i = 0; i < players.length; i++) {
        const pid = players[i];
        if (pid === excludePID) continue;
        if (!IsHeroAlive(pid)) continue;
        const info = GetHeroLastSeenInfo(pid);
        if (!info || !info[0]) continue;
        if (info[0].time_since_seen > LAST_SEEN_WINDOW) continue;
        const d = jmz().Utils ? jmz().Utils.GetLocationToLocationDistance(info[0].location, loc) : 99999;
        if (d <= radius) n++;
    }
    return n;
}

// Search our unit lists for a visible enemy hero with this player ID.
function findVisibleEnemyHero(pid: number): Unit | null {
    const J = jmz();
    const enemies = GetUnitList(UnitType.Enemies);
    for (let i = 0; i < enemies.length; i++) {
        const u = enemies[i];
        if (J.IsValidHero(u) && !J.IsSuspiciousIllusion(u)) {
            if (u.GetPlayerID && u.GetPlayerID() === pid) return u;
        }
    }
    return null;
}

declare function GetUnitList(type: any): Unit[];
declare const UnitType: any;

// ============================================================
// Debug
// ============================================================

export function Describe(): string {
    const f = currentFocus;
    if (!f.unit || DotaTime() > f.validUntil) return "none";
    const name = f.unit.GetUnitName ? f.unit.GetUnitName() : "unknown";
    return name + " [" + f.reason + " score=" + string.format("%.2f", f.score) + "]";
}
