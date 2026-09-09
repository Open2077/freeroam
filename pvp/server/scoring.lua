-- Kabuki Arena -- the damage ledger and the score.
--
-- M10 of server/instances.lua: `countDeath`, `sortedRows` and the kill-feed
-- payload leave main.lua and land here, and they arrive with the rest of plan
-- section 7's scoring table attached -- assists, first blood, revenge,
-- multi-kills, streaks and the out-of-bounds penalty.
--
-- ===========================================================================
-- ===  CHANGES server/main.lua NEEDS FOR loadout.lua AND scoring.lua.      ===
-- ===  APPLY THESE BY HAND. THEY ARE IN ADDITION TO M1-M10 IN              ===
-- ===  server/instances.lua, WHICH STILL APPLY UNCHANGED.                  ===
-- ===========================================================================
--
-- Anchored search/replace rather than line numbers, because main.lua is being
-- rewritten in parallel; the anchors are quoted from main.lua as it stands at
-- 1070 lines.
--
-- --- L1. The loadout upvalues and functions go. ---------------------------
--
-- main.lua ~lines 14-17, DELETE:
--
--   -    local lastWeaponIndex = 0
--   -    local suppressDeathUntil = {}
--   -    local loadoutVersion = {}
--   -    local weaponRequests = {}
--
-- and DELETE outright: `stripWeapons` (~164), `normalizeWeaponId` (~170),
-- `equipWeapon` (~179) and the whole `open77:weapons:completed` handler
-- (~208-253). loadout.lua owns all five, across three slots instead of one.
-- Every call site becomes one line:
--
--   -    equipWeapon(playerId, activeMatch)
--   +    Deathmatch.loadout.issue(playerId, instance, "round_start")
--
--   -    stripWeapons(playerId)
--   +    Deathmatch.loadout.strip(playerId)
--
-- The `SetTimeout(750, ...)` wrapper around the respawn `equipWeapon` (~666)
-- goes with it: `issue` already carries its own 250 ms settling gap, and the
-- respawn path wants `Deathmatch.loadout.onRespawn(playerId, instance)`, which
-- honours `Config.equalizer.resupplyOnRespawn` and refills the reserve instead
-- of re-issuing the whole loadout.
--
-- --- L2. The arbiter matches a SET, not one id. ---------------------------
--
-- This EXTENDS M5, which stops at the instance gate. Three slots are issued
-- now, so a katana kill would otherwise be refused as `wrong_weapon` while the
-- player holds a weapon the server itself handed them. main.lua ~797:
--
--   -    local expectedWeapon = instance.weaponIds[attackerId]
--   -    local reportedWeapon = normalizeWeaponId(event.weaponTdbId)
--   -    if expectedWeapon == nil or expectedWeapon == "" then ... return false end
--   -    if reportedWeapon ~= expectedWeapon then ... return false end
--   -    return true
--   +    local ok, why = Deathmatch.loadout.accepts(instance, attackerId, event.weaponTdbId)
--   +    if not ok then
--   +        logDamageDecision(attackerId, why,
--   +            instance.weaponIds[attackerId], event.weaponTdbId)
--   +        return false
--   +    end
--   +    return true
--
-- `accepts` FAILS CLOSED: an empty set accepts nothing, so a player whose
-- weapon never verified still cannot land damage. `instance.weaponIds` keeps
-- carrying the slot-1 id, unchanged, because bots.lua's `verifiedWeaponId` hook
-- reads that exact field.
--
-- --- L3. Two sweeps on the tick. ------------------------------------------
--
-- main.lua ~984, beside the `Deathmatch.instances.reap(at)` of M6:
--
--   +    Deathmatch.loadout.sweep(at)
--
-- --- S1. countDeath, sortedRows and the kill feed go. ---------------------
--
-- DELETE `countDeath` (~676-731), `sortedRows` (~343-368), and BOTH
-- `open77:playerKilled` (~732) and `open77:playerDied` (~736) handlers.
-- scoring.lua registers both events itself and owns the debounce, the
-- suppression window, the ledger and the feed.
--
--   -    rows = sortedRows(match),
--   +    rows = Deathmatch.scoring.rows(instance),
--
-- `chooseWinner` keeps working verbatim against `Deathmatch.scoring.rows`: the
-- comparator is the same one, kills first.
--
-- --- S2. EVERY PLACEMENT IS A DEATH THE DEATH RULE MUST NOT COUNT. --------
--
-- This is the one that bites. `placeAt` moves a player with `kill -> respawn`,
-- so without the suppression window every arena entry, every respawn and every
-- bounds backstop scores as a death. main.lua ~133, inside `placeAt`:
--
--   -    suppressDeathUntil[playerId] = nowMs() + 2500
--   +    Deathmatch.scoring.suppressDeath(playerId, 2500)
--
-- --- S3. Publish the state push. ------------------------------------------
--
-- Scoring changes the standings and the feed, and the HUD has to be told.
-- Near the bottom of main.lua, beside the M7 placer registration:
--
--   + Deathmatch.broadcastState = broadcastState
--
-- Guarded at every call site here, so a main.lua that forgets loses live
-- standings rather than raising.
--
-- --- S4. round.lua / arena.lua, two calls each. ---------------------------
--
--   * at round start:   `Deathmatch.scoring.beginRound(instance, roundId)`
--                       (it calls `DeathmatchBots.beginRound` for you)
--                       and `Deathmatch.loadout.onRoundStart(instance)` for the
--                       ammunition resupply, plus `Deathmatch.loadout.rotate`
--                       ONCE to advance the FFA equalizer.
--   * once, at load:    `Deathmatch.scoring.setDeathHandler(function(instance,
--                           victimId, killerId, info) ... end)`
--     A counted death is scored here and then handed to that function, which is
--     where the respawn timer, the kill limit and elimination live. Without a
--     handler a death still scores; nobody respawns.
--
-- --- S5. The ladder write (Phase 8, ranked.lua). --------------------------
--
--   + if Deathmatch.scoring.ladderEligible(instance) then ... write ... end
--
-- Decision 12: excluded AT THE WRITE, never filtered at the read.
--
-- --- S6. Optional, and cheap: break spawn protection on aggression. -------
--
-- Plan section 7 wants protection dropped the moment a player's own outgoing
-- damage credits. Publish a one-argument function and this file will call it:
--
--   + Deathmatch.scoring.setAggressionHandler(function(playerId) ... end)
-- ===========================================================================
--
--
-- ===========================================================================
-- WHAT THIS FILE HAD TO BE BUILT AROUND
-- ===========================================================================
--
-- 1. BOTS LIVE IN TWO ID SPACES AND ONLY ONE OF THEM IS A KEY.
--    A bot is a PARTICIPANT with a small negative id (-1, -2, ...) -- that is
--    what standings rows, the feed and every table here key on. It is also an
--    NPC with a uint64 id that crosses as a DECIMAL STRING (12884901889 was
--    measured in-game), and that is the form the engine attributes its shots
--    with: `open77:playerDamaged` and `open77:playerKilled` arrive carrying the
--    NPC id as the attacker.
--
--    `tonumber` on an npc id is not merely wrong, it is silently wrong past
--    2^53. So EVERY attacker and killer id this file receives goes through
--    `DeathmatchBots.attackerId(raw)` first. It is idempotent and passes a real
--    player id straight through, so it is applied unconditionally at the top of
--    each handler. Skip it and a bot's kills land under a key nothing else uses:
--    the bot appears to score nothing and no victim can ever take revenge on it.
--
-- 2. A BOT VICTIM PRODUCES NO ENGINE DEATH EVENT.
--    E6, measured 2026-08-31: a player's gunfire does not damage a server-owned
--    NPC and fires neither `onNpcDamaged` nor `onNpcDied`. bots.lua therefore
--    implements the hit itself and credits it, and death accounting for a bot
--    victim is driven from THAT path -- `Scoring.creditDamage` and
--    `Scoring.creditKill`, which bots.lua calls through the kernel's host hooks
--    -- never from an engine event that will never arrive.
--
--    The same path also owes the shooter a hitmarker, because
--    `open77:hitConfirmed` fires only for player victims (docs/combat.md,
--    "Client feedback events: the encoding, measured"). bots.lua already emits
--    `deathmatch:botHitConfirmed` at the point it credits the hit, so that debt
--    is paid where it is owed; this file must not emit a second one.
--
-- 3. THE FEED IS PER INSTANCE.
--    The shipped mode broadcast `deathmatch:killfeed` to -1, which was correct
--    when one global `match` existed. With several instances running it would
--    show every player every other instance's kills. Feed and callouts are sent
--    to the instance's members, one `TriggerClientEvent` each.
--
-- 4. NO DISPLAY LANGUAGE LEAVES THE SERVER.
--    A callout is `{ kind, count }` and nothing else; the wording lives in the
--    HUD's string table (`open77_deathmatch_hud/shared/strings.lua`). Every
--    server-side string this file emits comes from `Config.strings`.
--
-- 5. ALL STATE IS PER INSTANCE.
--    The scoreboard hangs off `instance.scoreboard`. The one module table is
--    `suppression[playerId]`, and it is deliberate: a placement suppresses a
--    death across the instance BOUNDARY -- entering the arena and being sent
--    back to the lobby are both placements -- so it cannot live on either side
--    of it.
-- ===========================================================================

Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig

DM.scoring = DM.scoring or {}
local Scoring = DM.scoring

-- See note 5. Per player, because a placement crosses instances.
local suppression = {}

-- Registered by round.lua / arena.lua; see S4 and S6.
local deathHandler = nil
local aggressionHandler = nil

local DEFAULT_SUPPRESS_MS = 2500
local DEATH_DEBOUNCE_MS = 1000


-- ------------------------------------------------------------------ helpers --

local function instances()
    local registry = DM.instances
    if type(registry) ~= "table" then return nil end
    return registry
end

-- The instance, from either a record or an id. bots.lua's host hooks pass the
-- RECORD to `addParticipant` and the ID to `removeParticipant` / `creditDamage`
-- / `creditKill`, so both spellings have to work or half the bot credits land
-- nowhere.
local function resolveInstance(value)
    if type(value) == "table" then
        if value.closed then return nil end
        return value
    end
    local registry = instances()
    if registry == nil then return nil end
    local id = tonumber(value)
    if id == nil then return nil end
    local record = registry.registry[id]
    if record == nil or record.closed then return nil end
    return record
end

-- A PARTICIPANT id: a positive player id or a negative bot id. Zero means "no
-- attacker" and is not a participant. Deliberately NOT `DM.playerId`, which
-- rejects everything below 1 and would drop every bot.
local function pid(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed
        or parsed == math.huge or parsed == -math.huge then return nil end
    parsed = math.floor(parsed)
    if parsed == 0 then return nil end
    return parsed
end

local function botsModule()
    local module = DeathmatchBots
    if type(module) ~= "table" then return nil end
    return module
end

-- THE TRANSLATION. See note 1. Applied to every attacker and killer id this
-- file receives, unconditionally, before it is used as a key.
local function translate(raw)
    if raw == nil then return 0 end
    local module = botsModule()
    if module ~= nil and type(module.attackerId) == "function" then
        local ok, translated = pcall(module.attackerId, raw)
        if ok then return math.floor(tonumber(translated) or 0) end
    end
    -- bots.lua absent (it loads AFTER this file, and a server may run without
    -- it) or it raised. An npc id is a uint64 that `tonumber` would corrupt, so
    -- anything too long to be a participant id is refused rather than converted:
    -- an uncredited kill is a cosmetic loss, a corrupted key is a wrong one.
    local digits = tostring(raw):match("^%-?%d+$")
    if digits == nil then return 0 end
    if #(digits:gsub("^%-", "")) > 9 then return 0 end
    return math.floor(tonumber(digits) or 0)
end

local function isBot(participantId)
    local module = botsModule()
    if module == nil or type(module.isBot) ~= "function" then return false end
    local ok, result = pcall(module.isBot, participantId)
    return ok and result == true
end

--- THE ONLY SAFE WAY TO NAME A PARTICIPANT, and it is published as
--- `Scoring.displayName` because every other file needs it too.
---
--- `DM.playerName` reaches `Open77.players.name`, which is one of the three
--- bindings that RAISE on a non-positive id -- and the raise is a CLR exception
--- thrown inside the C function, so it unwinds straight through `pcall` and
--- stops the whole resource with `runtime_error`. `pcall` IS NOT A GUARD
--- AGAINST THESE THREE; only not calling them is.
local function nameOf(participantId)
    local id = tonumber(participantId)
    if id == nil then return "?" end
    id = math.floor(id)
    if id <= 0 then
        local module = botsModule()
        if module ~= nil and type(module.name) == "function" then
            local ok, name = pcall(module.name, id)
            if ok and name ~= nil then return tostring(name) end
        end
        if id == 0 then return "" end
        return "BOT " .. tostring(-id)
    end
    return DM.playerName(id)
end

--- Published so no caller anywhere has to decide whether an id is safe to hand
--- to `Open77.players.name`. Answers for a player, a bot, and 0 ("no actor").
function Scoring.displayName(participantId)
    return nameOf(participantId)
end

-- Position for the kill-feed distance chip. Players answer through the
-- replicated snapshot; a bot answers through its npc id, which is passed back
-- to the API in its native form and NEVER through `tonumber`.
local function positionOf(participantId)
    if participantId > 0 then
        return Open77.players.position(participantId)
    end
    local module = botsModule()
    if module == nil or type(module.npcIdOf) ~= "function" then return nil end
    local ok, npcId = pcall(module.npcIdOf, participantId)
    if not ok or npcId == nil then return nil end
    local read, snapshot = pcall(Open77.npcs.get, npcId)
    if not read or type(snapshot) ~= "table" then return nil end
    return snapshot
end

local function distanceBetween(a, b)
    local left, right = positionOf(a), positionOf(b)
    if type(left) ~= "table" or type(right) ~= "table" then return nil end
    -- `DM.finite` on BOTH sides before subtracting: a position field may be a
    -- string, and an unreadable snapshot must produce no chip rather than a
    -- number derived from a coercion.
    local lx, ly, lz = DM.finite(left.x), DM.finite(left.y), DM.finite(left.z)
    local rx, ry, rz = DM.finite(right.x), DM.finite(right.y), DM.finite(right.z)
    if lx == nil or ly == nil or lz == nil then return nil end
    if rx == nil or ry == nil or rz == nil then return nil end
    local dx, dy, dz = lx - rx, ly - ry, lz - rz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function push()
    if type(DM.broadcastState) == "function" then pcall(DM.broadcastState) end
end


-- ------------------------------------------------------------- the board --

-- Per instance, created lazily. `stats` survives a round for the standings
-- screen; `beginRound` is what clears it.
local function board(instance)
    if instance == nil then return nil end
    local entry = instance.scoreboard
    if entry == nil then
        entry = {
            roundId = nil,
            stats = {},          -- participantId -> row state
            ledger = {},         -- victimId -> { total, maxHealth, by = { attackerId -> amount } }
            lastHit = {},        -- victimId -> the most recent credited hit
            lastKilledBy = {},   -- victimId -> who killed them last (revenge)
            lastDeathAtMs = {},  -- victimId -> debounce
            firstBloodTaken = false,
            hadBots = false,     -- own taint; see `ladderEligible`
        }
        instance.scoreboard = entry
    end
    return entry
end

local function statsFor(instance, participantId, info)
    local entry = board(instance)
    if entry == nil then return nil end
    local row = entry.stats[participantId]
    if row == nil then
        row = {
            id = participantId,
            name = nameOf(participantId),
            kills = 0, deaths = 0, assists = 0,
            score = 0,
            streak = 0, bestStreak = 0,
            -- CAREER COUNTERS (Phase 8). Both were already DERIVED here and
            -- immediately thrown away: `headshot` decided a bonus and lit a
            -- callout, `multiCount` was a rolling window that resets on the next
            -- death. Neither is recoverable after the fact, so a career that
            -- wanted "headshots" or "multi-kills" would have had to recompute
            -- them from a damage log this mode does not keep. They are counted
            -- HERE, where the decision is already being made, and ranked.lua
            -- persists what this file already knows rather than deriving a
            -- second answer that can disagree with the scoreboard.
            headshots = 0, multiKills = 0,
            damage = 0.0,
            team = 0,
            bot = participantId < 0,
            multiCount = 0,
            lastKillAtMs = nil,
            joinedAtMs = DM.nowMs(),
        }
        entry.stats[participantId] = row
    end
    if type(info) == "table" then
        if info.name ~= nil then row.name = tostring(info.name) end
        if info.bot ~= nil then row.bot = info.bot == true end
        if info.team ~= nil then row.team = math.floor(tonumber(info.team) or 0) end
    end
    if row.bot then entry.hadBots = true end
    return row
end

Scoring.board = board

--- Look a row up without creating one.
function Scoring.statsOf(instance, participantId)
    instance = resolveInstance(instance)
    participantId = pid(participantId)
    local entry = board(instance)
    if entry == nil or participantId == nil then return nil end
    return entry.stats[participantId]
end

function Scoring.killsOf(instance, participantId)
    local row = Scoring.statsOf(instance, participantId)
    return row ~= nil and row.kills or 0
end


-- --------------------------------------------------------------- roster --

-- Called by bots.lua's `addParticipant` host hook with the instance RECORD, and
-- by round.lua / arena.lua for players. Idempotent.
function Scoring.addParticipant(instance, participantId, info)
    instance = resolveInstance(instance)
    participantId = pid(participantId)
    if instance == nil or participantId == nil then return nil end
    return statsFor(instance, participantId, info)
end

-- A leaver keeps their row. Standings that erase somebody at the moment they
-- quit rewrite the round the survivors just played.
function Scoring.removeParticipant(instance, participantId, reason)
    instance = resolveInstance(instance)
    participantId = pid(participantId)
    local entry = board(instance)
    if entry == nil or participantId == nil then return false end
    local row = entry.stats[participantId]
    if row ~= nil then
        row.left = true
        row.leftReason = tostring(reason or "left")
    end
    entry.ledger[participantId] = nil
    entry.lastHit[participantId] = nil
    return true
end

-- Teams are arena.lua's; the row carries the integer so the HUD can colour a
-- name without a second lookup.
function Scoring.setTeam(instance, participantId, team)
    instance = resolveInstance(instance)
    participantId = pid(participantId)
    if instance == nil or participantId == nil then return false end
    statsFor(instance, participantId).team = math.floor(tonumber(team) or 0)
    return true
end


-- ---------------------------------------------------------------- rounds --

-- Clears the score, the ledger and first blood. It does NOT clear the roster:
-- the same players carry into the next round, which is the point of an instance
-- outliving its rounds.
function Scoring.beginRound(instance, roundId)
    instance = resolveInstance(instance)
    local entry = board(instance)
    if entry == nil then return false end

    entry.roundId = roundId
    entry.ledger = {}
    entry.lastHit = {}
    entry.lastKilledBy = {}
    entry.lastDeathAtMs = {}
    entry.firstBloodTaken = false
    entry.hadBots = false

    for participantId, row in pairs(entry.stats) do
        row.kills, row.deaths, row.assists = 0, 0, 0
        row.score = 0
        row.streak, row.bestStreak = 0, 0
        row.headshots, row.multiKills = 0, 0
        row.damage = 0.0
        row.multiCount = 0
        row.lastKillAtMs = nil
        if row.bot or participantId < 0 then entry.hadBots = true end
    end

    -- bots.lua keeps its own sticky taint, and it is the authority for "were
    -- there bots at the start". Announcing the round to it is what arms it.
    local module = botsModule()
    if module ~= nil and type(module.beginRound) == "function" then
        pcall(module.beginRound, instance.id, roundId)
    end
    return true
end

-- DECISION 12, AT THE WRITE. Two independent taints, AND-ed, and both fail
-- closed: this file's own (a bot ever appeared in the stats) and bots.lua's
-- sticky per-round one (clearing the bots mid-round cannot launder the result).
-- Either alone would be enough on a good day; together they survive one of the
-- two files being reloaded mid-round.
function Scoring.ladderEligible(instance)
    instance = resolveInstance(instance)
    if instance == nil then return false end
    local entry = board(instance)
    if entry == nil or entry.hadBots then return false end
    local module = botsModule()
    if module ~= nil and type(module.roundLadderEligible) == "function" then
        local ok, eligible = pcall(module.roundLadderEligible, instance.id)
        if not ok or eligible ~= true then return false end
    end
    return true
end


-- ---------------------------------------------------------------- output --

-- One `TriggerClientEvent` per member. See note 3: a broadcast to -1 would show
-- every player every other instance's kills.
--
-- HUMANS, NOT MEMBERS. This loop touches the ENGINE, so it takes the engine's
-- roster -- the rule written where `members` and `humans` are defined. A bot id
-- here is not a harmless no-op either way: `TriggerClientEvent` throws
-- `Invalid client event envelope` for any target below -1, and -1 itself is the
-- BROADCAST target, so a first bot would silently send this instance's kill feed
-- to every player on the server and the second would stop the resource.
local function toInstance(instance, event, payload)
    local registry = instances()
    if registry == nil or instance == nil then return end
    local roster = type(registry.humans) == "function"
        and registry.humans(instance) or registry.members(instance)
    for _, playerId in ipairs(roster) do
        if type(playerId) == "number" and playerId > 0 then
            TriggerClientEvent(event, playerId, payload)
        end
    end
end

-- THE CALLOUT. `{ kind, count }` and nothing else -- the wording lives in the
-- HUD's string table, so the server never carries display language.
-- `kind` is one of: multi | streak | firstBlood | revenge | headshot | assist |
-- streakEnded.
local function callout(participantId, kind, count)
    if participantId == nil or participantId <= 0 then return end   -- bots have no HUD
    TriggerClientEvent("deathmatch:callout", participantId, {
        kind = tostring(kind),
        count = math.floor(tonumber(count) or 0),
    })
end

Scoring.callout = callout


-- ---------------------------------------------------------------- ledger --

local function ledgerFor(entry, victimId)
    local record = entry.ledger[victimId]
    if record == nil then
        record = { total = 0.0, maxHealth = nil, by = {} }
        entry.ledger[victimId] = record
    end
    return record
end

--- Decay. The ledger is per LIFE, not per round: carrying damage across a death
--- would hand an assist for a wound the victim healed two lives ago.
function Scoring.decayLedger(instance, victimId)
    instance = resolveInstance(instance)
    victimId = pid(victimId)
    local entry = board(instance)
    if entry == nil or victimId == nil then return false end
    entry.ledger[victimId] = nil
    entry.lastHit[victimId] = nil
    return true
end

function Scoring.onRespawn(playerId, instance)
    if Config.scoring.ledgerDecayOnRespawn == false then return false end
    local participantId = translate(playerId)
    if instance == nil then
        local registry = instances()
        -- `resolve` and not `of`: a bot respawns too, and `of` rejects a
        -- negative participant id by design.
        instance = registry ~= nil and registry.resolve(participantId) or nil
    end
    return Scoring.decayLedger(instance, participantId)
end

-- THE LEDGER WRITE, and bots.lua's `creditDamage` host hook.
--
-- `instance` may be a record or an id; ids are translated; the amount is
-- validated. `info` carries `{ headshot, cause, weapon, lethal, maxHealth,
-- remainingHealth }`, all optional.
function Scoring.creditDamage(instance, attackerId, victimId, amount, info)
    instance = resolveInstance(instance)
    if instance == nil then return false end
    local entry = board(instance)

    local victim = pid(translate(victimId))
    local attacker = pid(translate(attackerId)) or 0
    if victim == nil then return false end

    amount = DM.finite(amount)
    if amount == nil or amount <= 0 then return false end
    info = type(info) == "table" and info or {}

    local record = ledgerFor(entry, victim)
    record.total = record.total + amount
    local reportedMax = DM.finite(info.maxHealth)
    if reportedMax ~= nil and reportedMax > 0 then record.maxHealth = reportedMax end

    -- Environment, fall damage and the bounds backstop have no attacker; they
    -- still move health, and they must never earn anybody an assist.
    if attacker ~= 0 and attacker ~= victim then
        record.by[attacker] = (record.by[attacker] or 0) + amount
        local row = statsFor(instance, attacker)
        row.damage = row.damage + amount
        entry.lastHit[victim] = {
            attackerId = attacker,
            headshot = info.headshot == true,
            weapon = info.weapon,
            cause = info.cause,
            atMs = DM.nowMs(),
        }
        -- Plan section 7: shooting from inside a spawn shield is the classic
        -- abuse, and the drop belongs at the moment outgoing damage CREDITS.
        if aggressionHandler ~= nil and attacker > 0 then
            pcall(aggressionHandler, attacker)
        end
    end
    if victim < 0 or attacker < 0 then entry.hadBots = true end
    return true
end

--- Everyone who put `assistThreshold` of the victim's health into them and is
--- not the killer. Percentages are of the victim's MAX health, which is the
--- only stable denominator: "30% of the victim's health" at the moment of a
--- lethal hit is 30% of nearly nothing.
local function assistsFor(entry, victimId, killerId)
    local record = entry.ledger[victimId]
    if record == nil then return {} end
    local maxHealth = record.maxHealth
    if maxHealth == nil or maxHealth <= 0 then maxHealth = 100.0 end
    local threshold = DM.finite(Config.scoring.assistThreshold) or 0.30
    local needed = maxHealth * threshold

    local out = {}
    for attackerId, dealt in pairs(record.by) do
        if attackerId ~= killerId and attackerId ~= victimId and dealt >= needed then
            out[#out + 1] = attackerId
        end
    end
    table.sort(out)
    return out
end


-- ============================================================ the scoring --
--
-- The ONE place a kill is scored. Two entry points reach it and they differ
-- only in what they have to defend against:
--
--   * `Scoring.creditKill`  -- bots.lua, for a BOT victim. There is no engine
--     death event for one (E6), and no placement either, so no suppression and
--     no debounce apply.
--   * `Scoring.countDeath`  -- a PLAYER victim, from `open77:playerKilled` /
--     `open77:playerDied`. Every placement in this mode is a `kill -> respawn`,
--     so it has to survive the suppression window and the double-report
--     debounce first.
local function award(instance, killerId, victimId, info)
    local entry = board(instance)
    local at = DM.nowMs()
    info = type(info) == "table" and info or {}

    local victimStats = statsFor(instance, victimId)
    victimStats.deaths = victimStats.deaths + 1

    -- A streak that ends is worth saying out loud; it is the other half of the
    -- streak callout and the HUD has a string for it.
    if victimStats.streak >= 3 then callout(victimId, "streakEnded", victimStats.streak) end
    victimStats.streak = 0
    victimStats.multiCount = 0

    local credited = killerId ~= 0 and killerId ~= victimId
    local killerStats = credited and statsFor(instance, killerId) or nil
    if killerStats == nil then credited = false end

    -- The lethal hit's body part is read from the ledger, never from the
    -- caller's optimism -- except for a bot victim, where bots.lua derived it
    -- from the intercept height itself and is the only source there is.
    local lastHit = entry.lastHit[victimId]
    local headshot = info.headshot == true
    if not headshot and lastHit ~= nil and lastHit.attackerId == killerId then
        headshot = lastHit.headshot == true
    end

    local weapon = info.weapon
    if weapon == nil and credited and type(DM.loadout) == "table" then
        weapon = DM.loadout.labelFor(instance, killerId,
            lastHit ~= nil and lastHit.weapon or nil)
    end

    local points = 0
    if credited then
        killerStats.kills = killerStats.kills + 1
        killerStats.streak = killerStats.streak + 1
        killerStats.bestStreak = math.max(killerStats.bestStreak, killerStats.streak)
        points = points + (DM.finite(Config.scoring.kill) or 100)

        if headshot then
            killerStats.headshots = (killerStats.headshots or 0) + 1
            points = points + (DM.finite(Config.scoring.headshotBonus) or 25)
            callout(killerId, "headshot", 1)
        end

        if not entry.firstBloodTaken then
            entry.firstBloodTaken = true
            points = points + (DM.finite(Config.scoring.firstBlood) or 50)
            callout(killerId, "firstBlood", 1)
        end

        -- Revenge: the killer is settling the score with whoever killed THEM
        -- last. Cleared once taken, so one death buys one revenge.
        if entry.lastKilledBy[killerId] == victimId then
            entry.lastKilledBy[killerId] = nil
            points = points + (DM.finite(Config.scoring.revenge) or 25)
            callout(killerId, "revenge", 1)
        end

        -- Multi-kill: the 2nd and every later kill inside the window.
        local window = DM.finite(Config.scoring.multiKillWindowMs) or 4000
        if killerStats.lastKillAtMs ~= nil and (at - killerStats.lastKillAtMs) <= window then
            killerStats.multiCount = killerStats.multiCount + 1
        else
            killerStats.multiCount = 1
        end
        killerStats.lastKillAtMs = at
        if killerStats.multiCount >= 2 then
            -- One MULTI-KILL EVENT, not one per kill in the burst: `multiCount`
            -- is already the burst length, and counting the 2nd, 3rd and 4th
            -- kill of one spree as three multi-kills would make the career
            -- number mean something different from the callout the player saw.
            killerStats.multiKills = (killerStats.multiKills or 0) + 1
            points = points + (DM.finite(Config.scoring.multiKill) or 25)
            callout(killerId, "multi", killerStats.multiCount)
        end

        -- Streak: +10 x n, where n is the streak this kill just reached. The
        -- shipped mode tracked the streak and only decorated the feed with it.
        points = points + (DM.finite(Config.scoring.streakStep) or 10) * killerStats.streak
        if killerStats.streak >= 3 then callout(killerId, "streak", killerStats.streak) end

        killerStats.score = killerStats.score + points
    end

    -- Revenge bookkeeping for the VICTIM's next kill.
    entry.lastKilledBy[victimId] = credited and killerId or nil

    -- Assists, before the ledger decays.
    local assisted = assistsFor(entry, victimId, credited and killerId or 0)
    for _, assistId in ipairs(assisted) do
        local row = statsFor(instance, assistId)
        row.assists = row.assists + 1
        row.score = row.score + (DM.finite(Config.scoring.assist) or 50)
        callout(assistId, "assist", row.assists)
    end

    -- The ledger is per life.
    entry.ledger[victimId] = nil
    entry.lastHit[victimId] = nil

    -- THE FEED. Every field the HUD reads, and only fields -- no display text.
    toInstance(instance, "deathmatch:killfeed", {
        killerId = credited and killerId or nil,
        killerName = credited and killerStats.name or nil,
        killerTeam = credited and killerStats.team or nil,
        killerBot = credited and (killerStats.bot == true) or nil,
        victimId = victimId,
        victimName = victimStats.name,
        victimTeam = victimStats.team,
        victimBot = victimStats.bot == true,
        weapon = weapon,
        headshot = headshot,
        distance = credited and distanceBetween(killerId, victimId) or nil,
        streak = credited and killerStats.streak or nil,
        cause = tostring(info.cause or (credited and "player" or "environment")),
    })

    if entry.hadBots == false and (victimId < 0 or killerId < 0) then
        entry.hadBots = true
    end

    push()

    -- THE HANDLER GETS THE NAMES, NOT JUST THE IDS, and that is not a
    -- convenience. `killerId` here is a PARTICIPANT id, so it is negative when a
    -- bot took the kill -- and the handler's natural next move is to render a
    -- death card, which used to mean `DM.playerName(killerId)` and therefore
    -- `Open77.players.name(-1)`. That binding RAISES, from inside the C
    -- function, so the exception unwinds past this very `pcall` and stops the
    -- resource: it is the crash that killed every bot round four seconds in.
    -- The name is already resolved here, safely, so the handler never has to
    -- ask the engine for it. See also `Scoring.displayName`.
    if deathHandler ~= nil then
        local ok, err = pcall(deathHandler, instance, victimId, credited and killerId or 0, {
            cause = tostring(info.cause or "player"),
            headshot = headshot,
            assists = assisted,
            points = points,
            killerKills = credited and killerStats.kills or 0,
            killerName = credited and killerStats.name or "",
            killerIsBot = credited and (killerStats.bot == true) or false,
            victimName = victimStats.name,
            victimIsBot = victimStats.bot == true,
        })
        if not ok then
            DM.log(("scoring death handler raised for victim %d: %s"):format(
                victimId, tostring(err)))
        end
    end
    return true
end


-- bots.lua's `creditKill` host hook. A BOT VICTIM ONLY takes this door: E6 means
-- no engine event will ever arrive for one, so the same code path that credited
-- the hit declares the death.
function Scoring.creditKill(instance, killerId, victimId, info)
    instance = resolveInstance(instance)
    if instance == nil then return false end
    local victim = pid(translate(victimId))
    if victim == nil then return false end
    local killer = pid(translate(killerId)) or 0
    return award(instance, killer, victim, info)
end


-- round.lua's scoring seam, and note THE ARGUMENT ORDER IS VICTIM FIRST:
-- `credit(instance, victimId, killerId, cause)`. It is a different spelling of
-- the same act, so it lands on the same code path rather than a parallel one.
--
-- It is also the reason `countDeath` keeps its debounce. Two entry points now
-- describe one player death -- this file's own `open77:playerKilled` handler
-- and round.lua's `onDeath` calling here -- so whichever arrives first counts
-- and the second is dropped inside the debounce window. Without that, wiring
-- both would score every kill twice.
function Scoring.credit(instance, victimId, killerId, cause)
    local victim = pid(translate(victimId))
    if victim == nil then return false end
    if victim > 0 then
        -- A player victim goes the full route: suppression window first, because
        -- every placement in this mode is a `kill -> respawn`.
        return Scoring.countDeath(victim, killerId, cause, { cause = cause })
    end
    return Scoring.creditKill(instance, killerId, victim, { cause = cause })
end


-- ------------------------------------------------------- a player's death --

--- Placement is a `kill -> respawn`, so main.lua calls this before every one.
function Scoring.suppressDeath(playerId, ms)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    suppression[playerId] = DM.nowMs() + math.max(0, math.floor(
        DM.finite(ms) or DEFAULT_SUPPRESS_MS))
    return true
end

function Scoring.isSuppressed(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    return (suppression[playerId] or 0) >= DM.nowMs()
end

--- A PLAYER victim. Returns false when the death is not counted, which is a
--- normal outcome: a placement, a double report, or a player who is not in an
--- instance at all.
function Scoring.countDeath(victimId, killerId, cause, info)
    local victim = DM.playerId(victimId)
    if victim == nil then return false end

    local registry = instances()
    if registry == nil then return false end
    local instance = registry.of(victim)
    if instance == nil or instance.closed then return false end

    local at = DM.nowMs()
    -- EVERY PLACEMENT IS A DEATH THE DEATH RULE MUST NOT COUNT.
    if (suppression[victim] or 0) >= at then return false end

    local entry = board(instance)
    local last = entry.lastDeathAtMs[victim]
    -- `playerKilled` and `playerDied` can both describe one death.
    if last ~= nil and at - last < DEATH_DEBOUNCE_MS then return false end
    entry.lastDeathAtMs[victim] = at

    info = type(info) == "table" and info or {}
    info.cause = info.cause or cause or "player"

    local killer = pid(translate(killerId)) or 0
    -- The killer has to share the instance, for the same reason the damage gate
    -- exists: a credit that crosses instances is the worst bug this design can
    -- produce, arriving through the scoreboard instead of through the arbiter.
    if killer ~= 0 and killer ~= victim then
        if not registry.sharesInstance(killer, victim) then
            DM.log(("scoring refused a cross-instance kill credit killer=%d victim=%d"):format(
                killer, victim))
            killer = 0
        end
    end

    return award(instance, killer, victim, info)
end


-- ---------------------------------------------------------------- penalty --

-- bounds.lua's hook, called at the backstop placement so the wall is never a
-- strategy. `points` is what the caller measured out (`Config.bounds.penaltyPoints`);
-- `Config.scoring.outOfBounds` is the fallback.
function Scoring.penalise(playerId, instance, reason, points)
    local participantId = pid(translate(playerId))
    instance = resolveInstance(instance)
    if participantId == nil then return false end
    if instance == nil then
        -- A lobby backstop. There is no round to score against and that is
        -- correct: the lobby has no combat, so it has no score either.
        return false
    end

    local delta = DM.finite(points)
    if delta == nil then delta = DM.finite(Config.scoring.outOfBounds) or -100 end
    local row = statsFor(instance, participantId)
    row.score = row.score + delta
    DM.log(("scoring penalty player=%d instance=%d reason=%s points=%d score=%d"):format(
        participantId, instance.id, tostring(reason or "penalty"), delta, row.score))
    push()
    return true
end


-- ---------------------------------------------------------------- rows --

-- Replaces `sortedRows`. The comparator is the shipped one, unchanged, and the
-- ordering is the decision: STANDINGS SORT ON KILLS FIRST. Score is a richer
-- number, not a replacement for the one players argue about.
function Scoring.rows(instance)
    instance = resolveInstance(instance)
    local rows = {}
    local entry = board(instance)
    if entry == nil then return rows end

    for participantId, stats in pairs(entry.stats) do
        -- `a and b or c` collapses a legitimate `false` into `c`, which would
        -- report a disconnected player as connected. Spelled out on purpose.
        local isPlayer = participantId > 0
        local connected, active
        if isPlayer then
            connected = Open77.players.name(participantId) ~= nil
            active = instance.members[participantId] == true
        else
            connected = true
            active = instance.actors[participantId] == true
        end
        local row = {
            id = participantId,
            name = stats.name,
            kills = stats.kills,
            deaths = stats.deaths,
            assists = stats.assists,
            damage = math.floor(stats.damage + 0.5),
            streak = stats.streak,
            bestStreak = stats.bestStreak,
            headshots = stats.headshots or 0,
            multiKills = stats.multiKills or 0,
            score = stats.score,
            team = math.floor(stats.team or 0),
            bot = stats.bot == true,
            connected = connected,
            active = active,
        }
        -- Rule 1 of plan section 8: bots are labelled, visibly, wherever they
        -- appear. bots.lua owns the tag so one file decides what a bot is called.
        local module = botsModule()
        if module ~= nil and type(module.decorateRow) == "function" then
            pcall(module.decorateRow, row)
        end
        rows[#rows + 1] = row
    end

    table.sort(rows, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        if a.deaths ~= b.deaths then return a.deaths < b.deaths end
        if a.score ~= b.score then return a.score > b.score end
        return tostring(a.name) < tostring(b.name)
    end)
    for index, row in ipairs(rows) do row.rank = index end
    return rows
end

--- The leader, or nil on a genuine tie. Kept beside `rows` because it must use
--- the same ordering; a winner chosen by a different comparator than the
--- scoreboard the players just read is how an argument starts.
function Scoring.leader(instance)
    local row = Scoring.leaderRow(instance)
    return row ~= nil and row.id or nil
end

--- The winner's whole ROW, and the one to prefer.
---
--- `leader` returns an id, and a winning BOT's id is negative -- which is safe
--- to store and to compare, and fatal to hand to `Open77.players.name`. Callers
--- that want to announce the winner want `row.name` and `row.bot`, both already
--- resolved here, rather than a second lookup that has to know what the id is.
function Scoring.leaderRow(instance)
    local rows = Scoring.rows(instance)
    if #rows == 0 then return nil end
    if #rows > 1 and rows[1].kills == rows[2].kills
        and rows[1].deaths == rows[2].deaths then return nil end
    return rows[1]
end


-- ---------------------------------------------------------------- events --

-- Every attacker id is TRANSLATED before it is used as a key. See note 1.
AddEventHandler("open77:playerDamaged", function(victimId, attackerId, amount,
        attackKind, weaponTdbId, bodyPart, remainingHealth, maxHealth, lethal)
    local victim = DM.playerId(victimId)
    if victim == nil then return end
    local registry = instances()
    if registry == nil then return end
    local instance = registry.of(victim)
    if instance == nil then return end

    Scoring.creditDamage(instance, attackerId, victim, amount, {
        headshot = tostring(bodyPart) == "head",
        cause = attackKind,
        weapon = weaponTdbId,
        maxHealth = maxHealth,
        remainingHealth = remainingHealth,
        -- `lethal` is "1"/"0" on this event, not "true"/"false"
        -- (docs/combat.md). Accept both spellings; a handler comparing against
        -- "true" silently never sees a lethal hit.
        lethal = lethal == true or lethal == 1 or lethal == "1" or lethal == "true",
    })
end)

AddEventHandler("open77:playerKilled", function(victimId, killerId, context)
    Scoring.countDeath(victimId, killerId, "player", { context = context })
end)

AddEventHandler("open77:playerDied", function(playerId, context)
    local killerId = 0
    if type(context) == "string" then
        killerId = context:match('"killer"%s*:%s*(%-?%d+)') or 0
    elseif type(context) == "table" then
        killerId = context.killer or 0
    end
    Scoring.countDeath(playerId, killerId, "environment", {})
end)

function Scoring.setDeathHandler(fn)
    deathHandler = (type(fn) == "function") and fn or nil
    return deathHandler ~= nil
end

function Scoring.setAggressionHandler(fn)
    aggressionHandler = (type(fn) == "function") and fn or nil
    return aggressionHandler ~= nil
end

function Scoring.forget(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    suppression[playerId] = nil
end

AddEventHandler("onPlayerDisconnected", function(playerId)
    Scoring.forget(playerId)
end)


-- ------------------------------------------------------------- diagnostics --

RegisterCommand("dm.score", function(source, args, raw)
    local function say(text)
        print(text)
        if source ~= nil and source > 0 then
            TriggerClientEvent("open77:command:result", source, raw or "", true, text)
        end
    end

    local registry = instances()
    if registry == nil then return say("scoring -- no instance kernel") end

    local instance = resolveInstance(DM.finite(args and args[1]))
        or registry.of(DM.playerId(source))
    if instance == nil then return say(Config.strings.error.notInInstance) end

    local entry = board(instance)
    say(("scoring instance=%d round=%s firstBlood=%s ladder=%s"):format(
        instance.id, tostring(entry.roundId), tostring(entry.firstBloodTaken),
        Scoring.ladderEligible(instance) and "eligible" or "EXCLUDED (bots)"))
    for _, row in ipairs(Scoring.rows(instance)) do
        say(("  %2d. %-20s k=%-3d d=%-3d a=%-3d score=%-5d streak=%d team=%d%s"):format(
            row.rank, tostring(row.name), row.kills, row.deaths, row.assists,
            row.score, row.streak, row.team, row.bot and "  [BOT]" or ""))
    end
    local pendingLedgers = 0
    for _ in pairs(entry.ledger) do pendingLedgers = pendingLedgers + 1 end
    say(("  open damage ledgers: %d"):format(pendingLedgers))
end, false)


AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    DM.log(("scoring ready -- kill %d, assist %d at %.0f%%, headshot +%d, first blood +%d,"
        .. " revenge +%d, multi +%d in %.0fs, streak +%d x n, out of bounds %d"):format(
        Config.scoring.kill, Config.scoring.assist,
        (Config.scoring.assistThreshold or 0.3) * 100,
        Config.scoring.headshotBonus, Config.scoring.firstBlood,
        Config.scoring.revenge, Config.scoring.multiKill,
        (Config.scoring.multiKillWindowMs or 4000) / 1000,
        Config.scoring.streakStep, Config.scoring.outOfBounds))
end)
