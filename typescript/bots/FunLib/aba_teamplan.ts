/**
 * Team-plan layer.
 *
 * One canonical "team intent" per team per tick. Any bot can trigger a recompute
 * (rate-limited to every TEAMPLAN_RECOMPUTE_INTERVAL seconds). The plan is stored
 * at module scope and queried by mode desire hooks to bias behavior toward team
 * strategy, weighted by each bot's personality teamSpirit trait.
 *
 * Intents (priority order):
 *   DEFEND_BASE   — enemies near Ancient, everyone drops farm
 *   DEFEND_LANE   — specific lane under pressure
 *   CONTEST_ROSH  — push for Roshan
 *   PUSH_LANE     — siege a specific lane
 *   SMOKE_GANK    — roam for picks
 *   REGROUP       — low HP/resources, reset
 *   FARM          — default
 *
 * Exposed to Lua as J.TeamPlan.*. Integrated into J.Personality.ModulateDesire
 * so existing mode hooks automatically pick up plan bias — no per-mode edits needed.
 */

import * as jmz from "bots/FunLib/jmz_func";
import { BotMode, Lane, Team, Tower, Barracks, Unit, UnitType, Vector } from "bots/ts_libs/dota";

declare function DotaTime(): number;
declare function GetTeam(): Team;
declare function GetOpposingTeam(): Team;
declare function GetBot(): Unit;
declare function GetTeamMember(n: number): Unit | null;
declare function GetTeamPlayers(team: Team): number[];
declare function GetTower(team: Team, tower: Tower): Unit | null;
declare function GetBarracks(team: Team, rax: Barracks): Unit | null;
declare function GetAncient(team: Team): Unit | null;
declare function IsHeroAlive(playerID: number): boolean;
declare function GetUnitToLocationDistance(unit: Unit, loc: Vector): number;
declare function GetUnitToUnitDistance(u1: Unit, u2: Unit): number;
declare function IsRoshanAlive(): boolean;

export type Intent =
    | "defend_base"
    | "defend_lane"
    | "commit_kill"
    | "lane_gank"
    | "contest_rosh"
    | "contest_tormentor"
    | "contest_lotus"
    | "push_lane"
    | "smoke_gank"
    | "regroup"
    | "farm";

export interface TeamPlan {
    intent: Intent;
    lane?: Lane;
    location?: Vector;
    validUntil: number;
    lastComputeTime: number;
    authorID: number;
    reason: string;  // for debug
}

// ============================================================
// State
// ============================================================

const TEAMPLAN_RECOMPUTE_INTERVAL = 2.0;
const PLAN_TTL = 12.0;

let currentPlan: TeamPlan = {
    intent: "farm",
    validUntil: 0,
    lastComputeTime: -999,
    authorID: -1,
    reason: "initial",
};

// Phase 8: smoke_gank cadence. Pro matches average one smoke every ~3 min
// (pro_macro.smoke_gank_cadence_min). Rate-limit plan issuance to match.
let _lastSmokeGankTime = -999;

// Phase 4: push_lane min-time gate. Exposed for potential debug inspection.
let _lastPushLaneTime = -999;

// ============================================================
// Public API
// ============================================================

export function GetCurrentPlan(): TeamPlan {
    return currentPlan;
}

/**
 * Trigger a recompute if the rate-limiter allows. Safe to call from any hook.
 * Returns the current plan (fresh or cached).
 */
export function MaybeRecompute(bot: Unit): TeamPlan {
    const now = DotaTime();
    if (now - currentPlan.lastComputeTime < TEAMPLAN_RECOMPUTE_INTERVAL) {
        return currentPlan;
    }
    const plan = computePlan(bot);
    plan.lastComputeTime = now;
    plan.validUntil = now + PLAN_TTL;
    plan.authorID = bot.GetPlayerID();
    currentPlan = plan;
    return plan;
}

// ============================================================
// Intent computation (priority order; first match wins)
// ============================================================

function computePlan(bot: Unit): TeamPlan {
    const team = GetTeam();
    const enemyTeam = GetOpposingTeam();
    const now = DotaTime();

    // Pull adaptive thresholds from game theory if available.
    let thresholds: any = {
        commitAllyThreshold: 2,
        pushAllyThreshold: 4,
        roshAllyThreshold: 3,
        tormentorLevelThreshold: 10,
    };
    const [okGT, gtMod] = pcall(require, GetScriptDirectory() + "/FunLib/aba_gametheory");
    if (okGT && gtMod !== null) {
        const [okT, t] = pcall(function () { return gtMod.GetThresholds(); });
        if (okT && t !== null) thresholds = t;
    }

    // 1. DEFEND_BASE: enemies near our Ancient
    const ourAncient = GetAncient(team);
    if (ourAncient) {
        const enemiesAtAncient = countEnemyHeroesNear(ourAncient.GetLocation(), 2500);
        if (enemiesAtAncient >= 1) {
            return freshPlan("defend_base", undefined, ourAncient.GetLocation(), "enemies near ancient");
        }
    }

    // 2. DEFEND_LANE: our T1/T2 under active attack (recently damaged + enemies in range)
    const threatenedLane = findThreatenedLane(team);
    if (threatenedLane !== null) {
        return freshPlan("defend_lane", threatenedLane.lane, threatenedLane.loc, "lane under attack");
    }

    // 2.5 COMMIT_KILL: focus target exists + ≥2 allies near the focus.
    // Fires between defend and contest_rosh so a juicy pick takes priority over
    // farming/pushing but not over base defense.
    const [okFocus, focusMod] = pcall(require, GetScriptDirectory() + "/FunLib/aba_focus");
    if (okFocus && focusMod !== null) {
        let pickSelf: Unit | null = null;
        for (let i = 1; i <= 5; i++) {
            const m = GetTeamMember(i);
            if (m !== null && m.IsAlive()) { pickSelf = m; break; }
        }
        if (pickSelf !== null) {
            focusMod.MaybeRecompute(pickSelf);
            const target = focusMod.GetFocus();
            if (target !== null && target.unit !== null && now < target.validUntil) {
                const focusLoc = target.unit.GetLocation();
                const nearAllies = jmz.GetAlliesNearLoc(focusLoc, 2000);
                if (nearAllies !== null && nearAllies.length >= 2) {
                    return freshPlan("commit_kill", undefined, focusLoc,
                        "focus=" + (target.reason || "?") + " allies=" + tostring(nearAllies.length));
                }
            }
        }
    }

    // 3. CONTEST_ROSH: rosh alive, past laning, we have numbers advantage or nothing else pressing
    if (IsRoshanAlive() && now > 15 * 60) {
        const aliveAllies = countAliveTeamHeroes(team);
        const aliveEnemies = countAliveTeamHeroes(enemyTeam);
        if (aliveAllies >= 4 && aliveAllies >= aliveEnemies) {
            return freshPlan("contest_rosh", undefined, undefined, "rosh up, we have numbers");
        }
    }

    // 3.8 SMOKE_GANK (overdue bypass): fire smoke even in late-game window when
    // cadence is due. Pros smoke FROM the high-ground clump — the two aren't
    // mutually exclusive. Without this block, late_game_group starves smoke
    // of all post-25min windows (sim showed ~8 events vs pro 13.3).
    let smokeCadenceSecA = 180;
    const pmSA = (jmz as any).DraftStrategy?.GetProMacro?.();
    if (pmSA && pmSA.smoke_gank_cadence_min && pmSA.smoke_gank_cadence_min > 0) {
        smokeCadenceSecA = pmSA.smoke_gank_cadence_min * 60;
    }
    if (now > 10 * 60 && (now - _lastSmokeGankTime) >= smokeCadenceSecA
        && !isInCooldown("smoke_gank")) {
        const groupedCountA = countGroupedAllies(team);
        if (groupedCountA >= 3) {
            _lastSmokeGankTime = now;
            return freshPlan("smoke_gank", undefined, undefined, "grouped, cadence overdue");
        }
    }

    // 3.9 LATE_GAME_GROUP (elevated priority): past p25 match duration, grouping
    // defensively wins over split-map pushing. Moved above push_lane because
    // without this sim harness showed 0 late_game_group fires in 40-min games —
    // push_lane was firing every recompute in the 25min+ window. Real pro macro:
    // once past p25 duration, teams converge at high ground to secure the core.
    let lateGameGateSec = 25 * 60;
    const pmL = (jmz as any).DraftStrategy?.GetProMacro?.();
    if (pmL && pmL.match_duration_p25 && pmL.match_duration_p25 > 0) {
        lateGameGateSec = pmL.match_duration_p25;
    }
    if (now > lateGameGateSec) {
        return freshPlan("late_game_group", undefined, undefined, "late game: group at high ground");
    }

    // 4. PUSH_LANE: weakest enemy lane + we have 4+ allies grouped somewhere.
    // Phase 4: gate by min game time derived from pro macro first_t1_fall_typical_sec.
    // Bots shouldn't siege during laning stage; allow from ~60% of pro first-T1 timing
    // (~7 min) or earlier if we have a >4k NW lead.
    let pushMinSec = 7 * 60;
    const pm4 = (jmz as any).DraftStrategy?.GetProMacro?.();
    if (pm4 && pm4.first_t1_fall_typical_sec && pm4.first_t1_fall_typical_sec > 0) {
        pushMinSec = pm4.first_t1_fall_typical_sec * 0.6;
    }
    let nwLead = 0;
    try {
        const nw = (jmz as any).GetInventoryNetworth?.();
        if (nw && typeof nw[0] === "number" && typeof nw[1] === "number") {
            nwLead = nw[0] - nw[1];
        }
    } catch (_e) { /* ignore */ }
    // Skip push_lane if on cooldown so we fall through to smoke_gank below
    // rather than hijacking the plan with freshPlan's cooldown-regroup behavior.
    if ((now >= pushMinSec || nwLead >= 4000) && !isInCooldown("push_lane")) {
        const pushTarget = findPushTarget(enemyTeam, team);
        if (pushTarget !== null) {
            _lastPushLaneTime = now;
            return freshPlan("push_lane", pushTarget.lane, pushTarget.loc, "push weakest lane");
        }
    }

    // 5. SMOKE_GANK: mid/late game + 3+ allies grouped + no lane under siege.
    // Phase 8: enforce pro-average cadence between smoke ganks (default 3 min).
    // Without a gate the plan re-issues every recompute while allies stand together;
    // this rate-limits issuance so the team disperses between ganks.
    let smokeCadenceSec = 180;
    const pm8 = (jmz as any).DraftStrategy?.GetProMacro?.();
    if (pm8 && pm8.smoke_gank_cadence_min && pm8.smoke_gank_cadence_min > 0) {
        smokeCadenceSec = pm8.smoke_gank_cadence_min * 60;
    }
    if (now > 10 * 60 && (now - _lastSmokeGankTime) >= smokeCadenceSec
        && !isInCooldown("smoke_gank")) {
        const groupedCount = countGroupedAllies(team);
        if (groupedCount >= 3) {
            _lastSmokeGankTime = now;
            return freshPlan("smoke_gank", undefined, undefined, "grouped, look for picks");
        }
    }

    // 6. REGROUP: team HP/mana low
    if (teamIsWeak(team)) {
        return freshPlan("regroup", undefined, undefined, "team needs to reset");
    }

    // 7. FARM: default
    return freshPlan("farm", undefined, undefined, "nothing pressing");
}

function freshPlan(intent: Intent, lane: Lane | undefined, loc: Vector | undefined, reason: string): TeamPlan {
    return {
        intent,
        lane,
        location: loc,
        validUntil: 0,
        lastComputeTime: 0,
        authorID: -1,
        reason,
    };
}

// ============================================================
// State-reading helpers
// ============================================================

function countEnemyHeroesNear(loc: Vector, radius: number): number {
    const enemies = jmz.GetEnemiesNearLoc(loc, radius);
    let n = 0;
    for (let i = 0; i < enemies.length; i++) {
        if (jmz.IsValidHero(enemies[i])) n++;
    }
    return n;
}

function countAliveTeamHeroes(team: Team): number {
    let n = 0;
    const players = GetTeamPlayers(team);
    for (let i = 0; i < players.length; i++) {
        if (IsHeroAlive(players[i])) n++;
    }
    return n;
}

function findThreatenedLane(team: Team): { lane: Lane; loc: Vector } | null {
    const lanes: Lane[] = [Lane.Top, Lane.Mid, Lane.Bot];
    let bestLane: Lane | null = null;
    let bestLoc: Vector | null = null;
    let bestThreat = 0;

    for (let i = 0; i < lanes.length; i++) {
        const lane = lanes[i];
        const building = findFurthestAliveLaneBuilding(team, lane);
        if (!building) continue;
        const loc = building.GetLocation();
        const enemiesNear = countEnemyHeroesNear(loc, 1600);
        const recentlyHit = building.GetHealth() < building.GetMaxHealth() * 0.9;
        const threat = enemiesNear + (recentlyHit ? 1 : 0);
        if (threat >= 2 && threat > bestThreat) {
            bestThreat = threat;
            bestLane = lane;
            bestLoc = loc;
        }
    }
    if (bestLane !== null && bestLoc !== null) {
        return { lane: bestLane, loc: bestLoc };
    }
    return null;
}

function findPushTarget(enemyTeam: Team, team: Team): { lane: Lane; loc: Vector } | null {
    // Find weakest enemy lane (lowest-tier alive building); only commit if we have people.
    const aliveAllies = countAliveTeamHeroes(team);
    if (aliveAllies < 4) return null;

    const lanes: Lane[] = [Lane.Top, Lane.Mid, Lane.Bot];
    let bestLane: Lane | null = null;
    let bestLoc: Vector | null = null;
    let bestTier = 99;

    for (let i = 0; i < lanes.length; i++) {
        const lane = lanes[i];
        const tier = getLaneTier(enemyTeam, lane);
        if (tier < bestTier) {
            const building = findFurthestAliveLaneBuilding(enemyTeam, lane);
            if (building) {
                bestTier = tier;
                bestLane = lane;
                bestLoc = building.GetLocation();
            }
        }
    }
    if (bestLane !== null && bestLoc !== null && bestTier <= 3) {
        return { lane: bestLane, loc: bestLoc };
    }
    return null;
}

function findFurthestAliveLaneBuilding(team: Team, lane: Lane): Unit | null {
    const towers: Tower[] =
        lane === Lane.Top ? [Tower.Top1, Tower.Top2, Tower.Top3] :
        lane === Lane.Mid ? [Tower.Mid1, Tower.Mid2, Tower.Mid3] :
                            [Tower.Bot1, Tower.Bot2, Tower.Bot3];
    for (let i = 0; i < towers.length; i++) {
        const t = GetTower(team, towers[i]);
        if (t && t.IsAlive()) return t;
    }
    // Check rax
    const raxMelee = lane === Lane.Top ? GetBarracks(team, Barracks.TopMelee) : lane === Lane.Mid ? GetBarracks(team, Barracks.MidMelee) : GetBarracks(team, Barracks.BotMelee);
    if (raxMelee && raxMelee.IsAlive()) return raxMelee;
    const raxRanged = lane === Lane.Top ? GetBarracks(team, Barracks.TopRanged) : lane === Lane.Mid ? GetBarracks(team, Barracks.MidRanged) : GetBarracks(team, Barracks.BotRanged);
    if (raxRanged && raxRanged.IsAlive()) return raxRanged;
    return null;
}

function getLaneTier(team: Team, lane: Lane): number {
    const towers: Tower[] =
        lane === Lane.Top ? [Tower.Top1, Tower.Top2, Tower.Top3] :
        lane === Lane.Mid ? [Tower.Mid1, Tower.Mid2, Tower.Mid3] :
                            [Tower.Bot1, Tower.Bot2, Tower.Bot3];
    for (let i = 0; i < towers.length; i++) {
        const t = GetTower(team, towers[i]);
        if (t && t.IsAlive()) return i + 1;
    }
    return 4;
}

function countGroupedAllies(team: Team): number {
    // Count allies within 1600 of the first alive bot we find
    const players = GetTeamPlayers(team);
    let anchor: Unit | null = null;
    for (let i = 1; i <= players.length; i++) {
        const m = GetTeamMember(i);
        if (m && m.IsAlive()) { anchor = m; break; }
    }
    if (!anchor) return 0;
    let n = 0;
    for (let i = 1; i <= players.length; i++) {
        const m = GetTeamMember(i);
        if (m && m.IsAlive() && GetUnitToUnitDistance(anchor, m) <= 1600) n++;
    }
    return n;
}

function teamIsWeak(team: Team): boolean {
    const players = GetTeamPlayers(team);
    let lowCount = 0;
    let total = 0;
    for (let i = 1; i <= players.length; i++) {
        const m = GetTeamMember(i);
        if (m && m.IsAlive()) {
            total++;
            if (jmz.GetHP(m) < 0.45 || jmz.GetMP(m) < 0.25) lowCount++;
        }
    }
    return total >= 2 && lowCount >= math.ceil(total * 0.5);
}

// ============================================================
// Mode-to-intent match table
// ============================================================

type ModeKey = "farm" | "roam" | "team_roam" | "push" | "defend" | "retreat" | "rune" | "roshan" | "ward" | "laning" | "assemble";

// Match = how well the given mode serves the given intent. [0..1].
// Fill only non-1 matches; anything missing defaults to 1 (no penalty, no boost).
const MATCH: Record<Intent, Partial<Record<ModeKey, number>>> = {
    defend_base: {
        defend: 1.0, retreat: 0.85, assemble: 0.9,
        farm: 0.15, roam: 0.2, push: 0.1, team_roam: 0.25, rune: 0.4, roshan: 0.1,
    },
    defend_lane: {
        defend: 1.0, retreat: 0.85, assemble: 0.85,
        farm: 0.4, roam: 0.3, push: 0.2, team_roam: 0.35, rune: 0.6, roshan: 0.3,
    },
    commit_kill: {
        team_roam: 1.0, roam: 1.0, assemble: 0.9,
        farm: 0.15, push: 0.3, defend: 0.5, retreat: 0.3, rune: 0.2, roshan: 0.2, ward: 0.3,
        laning: 0.25,
    } as Partial<Record<ModeKey, number>>,
    lane_gank: {
        roam: 1.0, team_roam: 0.95, assemble: 0.8,
        laning: 0.4, farm: 0.5, push: 0.55, defend: 0.8, retreat: 0.7,
    } as Partial<Record<ModeKey, number>>,
    contest_rosh: {
        roshan: 1.0, team_roam: 0.85, assemble: 0.8,
        farm: 0.4, push: 0.3, defend: 0.8,
    },
    contest_tormentor: {
        team_roam: 0.95, assemble: 0.85, roshan: 0.6,
        farm: 0.3, push: 0.25, roam: 0.7, defend: 0.75,
    },
    contest_lotus: {
        team_roam: 0.75, roam: 0.8, assemble: 0.7, ward: 0.85,
        farm: 0.6, push: 0.65, defend: 0.85,
    },
    push_lane: {
        push: 1.0, team_roam: 0.8,
        farm: 0.5, roam: 0.4, defend: 0.7, retreat: 0.5,
    },
    smoke_gank: {
        roam: 1.0, team_roam: 1.0,
        farm: 0.5, push: 0.7, defend: 0.8,
    },
    regroup: {
        retreat: 1.0, farm: 0.85, ward: 0.9,
        roam: 0.4, push: 0.3, team_roam: 0.4,
    },
    farm: {
        farm: 1.0, rune: 1.0, laning: 1.0, ward: 1.0,
        push: 0.85, defend: 0.9, roam: 0.8, team_roam: 0.75, roshan: 0.8,
    },
};

function getMatch(intent: Intent, mode: ModeKey): number {
    const intentTable = MATCH[intent];
    if (!intentTable) return 1.0;
    const v = intentTable[mode];
    if (v === undefined) return 1.0;
    return v;
}

// ============================================================
// Bias multiplier
// ============================================================

const MIN_MULT = 0.5;
const MAX_MULT = 1.3;

function lerp(a: number, b: number, t: number): number {
    return a + (b - a) * t;
}

function clamp01(v: number): number {
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

/**
 * Desire multiplier for a mode given current plan and bot teamSpirit.
 * teamSpirit = 0 → ignore plan completely (mult = 1.0).
 * teamSpirit = 1 → full compliance (mult scales 0.5..1.3 by match).
 */
export function GetPlanBias(bot: Unit, mode: string, teamSpirit: number): number {
    const plan = currentPlan;
    if (DotaTime() > plan.validUntil) return 1.0;

    // Engagement override: if an enemy hero is within immediate attack range,
    // don't bias away from combat. Otherwise commit_kill / push / etc. could
    // push farm / team_roam desires high enough that the bot walks past an
    // enemy right in front of it to chase the team target — unrealistic and
    // exploitable. Neutralizing the bias here lets Valve's default
    // attack_generic desire (which spikes on close enemies) win.
    const [okEnemies, nearbyEnemies] = pcall(function (): Unit[] {
        return jmz.GetNearbyHeroes(bot, 900, true, BotMode.None);
    });
    if (okEnemies && nearbyEnemies !== null && nearbyEnemies.length > 0) {
        if (mode === "farm" || mode === "push" || mode === "team_roam" || mode === "roam"
            || mode === "rune" || mode === "ward" || mode === "roshan") {
            return 1.0;
        }
    }

    const m = getMatch(plan.intent, mode as ModeKey);
    const compliantMult = lerp(MIN_MULT, MAX_MULT, m);
    return 1.0 + clamp01(teamSpirit) * (compliantMult - 1.0);
}

/**
 * Debug description of the current plan.
 */
export function Describe(): string {
    const p = currentPlan;
    return p.intent + (p.lane !== undefined ? " lane=" + tostring(p.lane) : "") + " [" + p.reason + "]";
}
