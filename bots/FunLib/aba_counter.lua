--[[ Counter-strategy modifiers (Phase 11 Item 7).

     Reads the enemy draft (via aba_draft_strategy.GetEnemyStrategy + raw
     hero list) and emits per-archetype tactical adjustments:
       - intent multipliers (push more / less, smoke more / less, etc.)
       - desired formation spacing (spread vs clump)
       - "5-man gate" — minimum item coverage before grouping is allowed
       - per-item priority bumps (BKB / Lotus / Pipe vs initiator-heavy)

     Stays inside the [0.85, 1.15] desire envelope.

     Exposed as J.Counter.*
     ]]
local ____exports = {}

-- Heroes whose presence on the enemy team triggers each archetype flag.
-- Used to classify "is the enemy initiator-heavy?" without re-running
-- aba_draft_strategy from scratch.
local INITIATOR_HEROES = {
    npc_dota_hero_tidehunter = true,
    npc_dota_hero_magnataur = true,
    npc_dota_hero_enigma = true,
    npc_dota_hero_disruptor = true,
    npc_dota_hero_earthshaker = true,
    npc_dota_hero_axe = true,
    npc_dota_hero_dark_seer = true,
}

local PICKOFF_HEROES = {
    npc_dota_hero_pudge = true,
    npc_dota_hero_lina = true,
    npc_dota_hero_lion = true,
    npc_dota_hero_nevermore = true,
    npc_dota_hero_riki = true,
    npc_dota_hero_bounty_hunter = true,
    npc_dota_hero_nyx_assassin = true,
}

local SPLITPUSH_HEROES = {
    npc_dota_hero_furion = true,
    npc_dota_hero_lycan = true,
    npc_dota_hero_terrorblade = true,
    npc_dota_hero_arc_warden = true,
    npc_dota_hero_broodmother = true,
    npc_dota_hero_phantom_lancer = true,
}

local SIEGE_HEROES = {
    npc_dota_hero_tinker = true,
    npc_dota_hero_pugna = true,
    npc_dota_hero_dragon_knight = true,
    npc_dota_hero_leshrac = true,
    npc_dota_hero_death_prophet = true,
    npc_dota_hero_jakiro = true,
}

-- Cache: classified once at first call, never re-classified (drafts don't
-- change mid-match).
local _enemy_archetype = nil
local _enemy_initiator_threat = 0   -- in [0, 1]

local function classifyEnemy()
    if _enemy_archetype ~= nil then return _enemy_archetype, _enemy_initiator_threat end

    local enemyTeam = GetOpposingTeam()
    local players = GetTeamPlayers(enemyTeam)
    local counts = { initiator = 0, pickoff = 0, splitpush = 0, siege = 0 }
    local enemyHeroes = {}
    for i = 1, #players do
        local pid = players[i]
        local ok, name = pcall(function() return GetSelectedHeroName(pid) end)
        if ok and type(name) == "string" and name ~= "" then
            table.insert(enemyHeroes, name)
            if INITIATOR_HEROES[name] then counts.initiator = counts.initiator + 1 end
            if PICKOFF_HEROES[name] then counts.pickoff = counts.pickoff + 1 end
            if SPLITPUSH_HEROES[name] then counts.splitpush = counts.splitpush + 1 end
            if SIEGE_HEROES[name] then counts.siege = counts.siege + 1 end
        end
    end

    -- Pick the dominant archetype (count >= 2 wins; otherwise "balanced")
    local archetype = "balanced"
    if counts.initiator >= 2 then archetype = "initiator_heavy"
    elseif counts.pickoff >= 2 then archetype = "pickoff_heavy"
    elseif counts.splitpush >= 2 then archetype = "splitpush_heavy"
    elseif counts.siege >= 2 then archetype = "siege_heavy"
    end

    -- Initiator threat is granular — used for spacing calculation.
    _enemy_initiator_threat = math.min(1.0, counts.initiator / 3.0)

    _enemy_archetype = archetype
    return archetype, _enemy_initiator_threat
end

-- Counter-strategy table per archetype. Multipliers stay in [0.92, 1.10]
-- so they don't blow the [0.85, 1.15] envelope.
local COUNTERS = {
    initiator_heavy = {
        intent_mult = {
            push_lane = 0.95, smoke_gank = 1.05,
            commit_kill = 0.95, defend_base = 1.05,
        },
        spread_radius = 700,
        five_man_gate = "bkb",  -- block 5-man until BKB count >= 2
    },
    pickoff_heavy = {
        intent_mult = {
            push_lane = 0.97, smoke_gank = 0.95,
            commit_kill = 0.95,
        },
        spread_radius = 0,  -- DON'T spread vs pickoff — group up
        max_solo_distance = 2200,  -- never let a hero be >2200u from ally
    },
    splitpush_heavy = {
        intent_mult = {
            defend_base = 1.10, smoke_gank = 1.10,  -- gank the rat
            push_lane = 0.95,
        },
        spread_radius = 600,
    },
    siege_heavy = {
        intent_mult = {
            defend_base = 1.10, push_lane = 0.95,
            commit_kill = 1.00,
        },
        spread_radius = 500,
        item_priorities = { pipe = 1.4, crimson = 1.2, bkb = 1.2 },
    },
    balanced = {
        intent_mult = {},
        spread_radius = 400,
    },
}

-- ============================================================
-- Public API
-- ============================================================

-- Returns the classified enemy archetype as a string.
function ____exports.GetEnemyArchetype()
    local arch, _ = classifyEnemy()
    return arch
end

-- Per-intent multiplier for the current enemy archetype. Returns 1.0 if
-- no specific counter applies. Caller multiplies into existing desire.
function ____exports.GetIntentMultiplier(intent)
    local arch, _ = classifyEnemy()
    local entry = COUNTERS[arch]
    if entry == nil or entry.intent_mult == nil then return 1.0 end
    return entry.intent_mult[intent] or 1.0
end

-- Desired formation spacing (radius around team centroid, in units).
-- Higher = more spread (vs initiators); lower = clump (vs pickoff).
function ____exports.GetSpreadRadius()
    local arch, _ = classifyEnemy()
    local entry = COUNTERS[arch]
    if entry == nil then return 400 end
    return entry.spread_radius or 400
end

-- Returns true if our team has the items to commit to a 5-man fight.
-- Currently checks BKB count for initiator-heavy enemies.
function ____exports.CanFiveMan()
    local arch, _ = classifyEnemy()
    local entry = COUNTERS[arch]
    if entry == nil or entry.five_man_gate == nil then return true end
    if entry.five_man_gate == "bkb" then
        -- Count BKBs in our team. Need >= 2 against initiator-heavy.
        local team = GetTeam()
        local players = GetTeamPlayers(team)
        local bkbCount = 0
        for i = 1, #players do
            local m = GetTeamMember(i)
            if m ~= nil and m:IsAlive() then
                for slot = 0, 5 do
                    local item = m:GetItemInSlot(slot)
                    if item ~= nil and not item:IsNull() then
                        local okN, name = pcall(function() return item:GetName() end)
                        if okN and name == "item_black_king_bar" then
                            bkbCount = bkbCount + 1
                            break
                        end
                    end
                end
            end
        end
        return bkbCount >= 2
    end
    return true
end

-- Per-item priority bump for the current archetype. Returns 1.0 if no bump.
function ____exports.GetItemPriority(itemName)
    local arch, _ = classifyEnemy()
    local entry = COUNTERS[arch]
    if entry == nil or entry.item_priorities == nil then return 1.0 end
    return entry.item_priorities[itemName] or 1.0
end

function ____exports.Describe()
    local arch, threat = classifyEnemy()
    return string.format("vs %s (init_threat=%.2f, spread=%d, can_5man=%s)",
        arch, threat, ____exports.GetSpreadRadius(),
        tostring(____exports.CanFiveMan()))
end

return ____exports
