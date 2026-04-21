/**
 * Game-theoretic adjustments on top of the team-plan.
 *
 * Tracks:
 *   - Strategic pressure — networth + level delta, in [-1..+1]
 *   - Ult readiness — count of team members with their ult off cooldown + mana
 *
 * Exposes adaptive thresholds so team-plan fires commit_kill / push_lane /
 * contest_rosh with different ally counts depending on whether we're ahead
 * or behind.
 *
 * Also provides a per-mode pressure bias used as a final desire polish —
 * aggressive modes scale up when ahead, defensive modes when behind.
 */

import { Unit } from "bots/ts_libs/dota";

declare function DotaTime(): number;
declare function GetTeamMember(n: number): Unit | null;

let _jmz: any = null;
function jmz(): any {
    if (_jmz === null) {
        _jmz = require(GetScriptDirectory() + "/FunLib/jmz_func");
    }
    return _jmz;
}

const RECOMPUTE_INTERVAL = 2.0;

interface CachedVal {
    value: number;
    lastUpdate: number;
}

const pressureCache: CachedVal = { value: 0, lastUpdate: -999 };
const ultCache: CachedVal = { value: 0, lastUpdate: -999 };

function clamp(v: number, lo: number, hi: number): number {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

export function GetStrategicPressure(): number {
    const now = DotaTime();
    if (now - pressureCache.lastUpdate < RECOMPUTE_INTERVAL) {
        return pressureCache.value;
    }
    const J = jmz();
    let nwPressure = 0;
    // J.GetInventoryNetworth returns multi-return (myNW, enemyNW)
    const [okNW, myNW, enemyNW] = pcall(function (): LuaMultiReturn<[number, number]> {
        return J.GetInventoryNetworth();
    });
    if (okNW && myNW !== null && enemyNW !== null) {
        nwPressure = clamp((myNW - enemyNW) / 20000, -1, 1);
    }
    let lvlPressure = 0;
    const [okL, myLvl] = pcall(function () { return J.GetAverageLevel(false); });
    const [okE, enemyLvl] = pcall(function () { return J.GetAverageLevel(true); });
    if (okL && okE && myLvl !== null && enemyLvl !== null) {
        lvlPressure = clamp((myLvl - enemyLvl) / 5, -1, 1);
    }
    const value = nwPressure * 0.7 + lvlPressure * 0.3;
    pressureCache.value = value;
    pressureCache.lastUpdate = now;
    return value;
}

// Ult slot isn't universal (Invoker, Meepo, Morphling etc. have non-standard
// layouts). Use J.Skill.GetAbilityList which already handles "ult at logical
// index 6" per aba_skill.lua. Fallback: scan slots for a 4-level-max trained
// ability.
function getUltimate(bot: Unit): any {
    const J = jmz();
    if (J && J.Skill && J.Skill.GetAbilityList) {
        const [ok, list] = pcall(function () { return J.Skill.GetAbilityList(bot); });
        if (ok && type(list) === "table" && list[6] !== null) {
            const [okA, ult] = pcall(function () { return bot.GetAbilityByName(list[6]); });
            if (okA && ult !== null && !ult.IsNull()) return ult;
        }
    }
    for (let slot = 0; slot <= 5; slot++) {
        const [okA, ab] = pcall(function () { return bot.GetAbilityInSlot(slot); });
        if (okA && ab !== null && !ab.IsNull() && ab.IsTrained() && ab.GetMaxLevel() <= 4) {
            return ab;
        }
    }
    return null;
}

export function GetUltReadiness(): number {
    const now = DotaTime();
    if (now - ultCache.lastUpdate < RECOMPUTE_INTERVAL) {
        return ultCache.value;
    }
    let ready = 0;
    for (let i = 1; i <= 5; i++) {
        const [ok, m] = pcall(function () { return GetTeamMember(i); });
        if (ok && m !== null && m.IsAlive()) {
            const ult = getUltimate(m);
            if (ult !== null && ult.IsTrained()
                && ult.GetCooldownTimeRemaining() < 2
                && m.GetMana() >= ult.GetManaCost()) {
                ready++;
            }
        }
    }
    ultCache.value = ready;
    ultCache.lastUpdate = now;
    return ready;
}

export interface Thresholds {
    commitAllyThreshold: number;
    pushAllyThreshold: number;
    roshAllyThreshold: number;
    tormentorLevelThreshold: number;
    pressure: number;
    ultReady: number;
}

export function GetThresholds(): Thresholds {
    const pressure = GetStrategicPressure();
    const ultReady = GetUltReadiness();
    const t: Thresholds = {
        commitAllyThreshold: 2,
        pushAllyThreshold: 4,
        roshAllyThreshold: 3,
        tormentorLevelThreshold: 10,
        pressure: pressure,
        ultReady: ultReady,
    };

    if (pressure > 0.3) {
        t.commitAllyThreshold = 1;
        t.pushAllyThreshold = 3;
        t.roshAllyThreshold = 2;
    } else if (pressure < -0.3) {
        t.commitAllyThreshold = 3;
        t.pushAllyThreshold = 5;
        t.roshAllyThreshold = 4;
    }

    if (ultReady >= 3) {
        t.commitAllyThreshold = math.max(1, t.commitAllyThreshold - 1);
        t.pushAllyThreshold = math.max(3, t.pushAllyThreshold - 1);
    }
    if (ultReady === 0) {
        t.commitAllyThreshold = t.commitAllyThreshold + 1;
    }

    return t;
}

const PRESSURE_BIAS: Record<string, number> = {
    push: 1.15,
    team_roam: 1.10,
    roam: 1.10,
    roshan: 1.15,
    retreat: 0.90,
    farm: 0.95,
    defend: 1.0,
};

export function GetPressureBias(mode: string): number {
    const target = PRESSURE_BIAS[mode];
    if (target === undefined) return 1.0;
    const pressure = GetStrategicPressure();
    return 1 + pressure * (target - 1);
}

export function Describe(): string {
    const t = GetThresholds();
    return string.format("pressure=%.2f ultReady=%d commit>=%d push>=%d rosh>=%d",
        t.pressure, t.ultReady, t.commitAllyThreshold, t.pushAllyThreshold, t.roshAllyThreshold);
}
