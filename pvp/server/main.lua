-- Kabuki Arena -- lifecycle, placement and the state push.
--
-- LAST in the manifest, and the smallest file the mode can have. Section 6's
-- table, applied: eight sibling modules landed around this one and took the
-- queue, the countdown, the weapons, the standings, the boundary rule and the
-- single global `match` with them. What is left here is what nothing else can
-- own:
--
--   * the LIFECYCLE -- connect, ready, the readiness gate, disconnect;
--   * the LAZY ROSTER -- there is still no way to list players, so `players`
--     is repopulated from the next event carrying an id, and a player already
--     standing in an instance bucket after a hot reload is ADOPTED rather than
--     dragged to the lobby (which would place, and therefore kill, a live
--     fighter);
--   * the ONE PLACEMENT PRIMITIVE -- `placeAt`, and the two shapes of it,
--     `placeInArena` and `sendToLobby`. Every placement in the mode is one
--     `kill -> respawn` and it happens exactly here. bounds.lua decides,
--     round.lua and arena.lua decide, this file places;
--   * the DAMAGE ARBITER -- `Open77.combat.onDamage` is host-global, so the
--     instance gate has to live where the callback does;
--   * the TICK, the STATE PUSH and the COMMANDS.
--
-- Everything else is a one-line call into `Deathmatch`. If a rule is being
-- decided in this file, it is in the wrong file.
--
-- Ids arrive as STRINGS at every lifecycle handler and every net event.
-- `Deathmatch.playerId` is applied at each entry point, once; a `tonumber` at
-- only some of them is how one player ends up with two records that never meet.
--
-- Every player-facing string comes from `Config.strings.notice` through
-- `Deathmatch.notice(playerId, kind, key, ...)`. No literals here.

local Config = DeathmatchConfig
local DM = Deathmatch

-- The lazy roster. `players[playerId] = record` and nothing more ambitious:
-- the record carries only what THIS file needs, because every question about
-- the fight is answered by `Deathmatch.fragmentFor`.
local players = {}
local nextStatePushMs = 0

local broadcastState

local function log(text) DM.log(text) end


-- =============================================================== the wall --
--
-- Decision 15: the wall is the CLIENT-SIDE CLAMP, and the client cannot clamp
-- against a zone it was never told about. `client/main.lua` listens for
-- `deathmatch:bounds` and `deathmatch:boundsClear`; `Deathmatch.bounds.payload`
-- builds the first. Without this push the boundary simply does not exist on
-- the client and only the five-second server backstop remains.
--
-- Sent on TRANSITION only -- the zone key is remembered on the record and the
-- payload goes out when it changes -- so the state push can call this at its
-- own rate without flooding a player with a box they already have.
local function syncBounds(playerId, force)
    local record = players[playerId]
    local instance = DM.instances.of(playerId)
    local zoneKey = instance ~= nil and DM.bounds.zoneOf(instance) or nil
    if record ~= nil and not force and record.boundsZone == zoneKey then return end
    if record ~= nil then record.boundsZone = zoneKey end
    if zoneKey == nil then
        TriggerClientEvent("deathmatch:boundsClear", playerId)
    else
        TriggerClientEvent("deathmatch:bounds", playerId, DM.bounds.payload(zoneKey))
    end
end


-- ============================================================ lazy roster --

-- M4. A record is created on the first event that carries the id, and the
-- ADOPTION comes before the lobby bucket: after a hot reload the registry is
-- empty while the players are still standing in their instance buckets, and
-- pushing one of them to the lobby would be a placement -- a kill -- on a
-- fighter who never left.
local function ensurePlayer(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end
    local record = players[playerId]
    if record == nil then
        record = {
            sinceMs = DM.nowMs(),
            announced = false,
            awaitingReady = false,
            boundsZone = nil,
        }
        players[playerId] = record
        -- Browsing or connecting never changes the Freeroam routing bucket.
        syncBounds(playerId, true)
    end
    return record
end


-- ====================================================== the ONE primitive --

local function phaseOf(life)
    return life and tostring(life.phase or ""):gsub("_", "") or ""
end

-- ------------------------------------------------ did the placement TAKE? --
--
-- `placeAt` returns true when the RESPAWN REQUEST was accepted, and that is a
-- different fact from the body having arrived. The chain under it is
-- fire-and-forget on both sides. `PlayerLifeService.Respawn` only records the
-- request and broadcasts it; the client's `LifeReplication::ApplyLocal` queues
-- a `ResurrectEvent` (asynchronous -- the engine processes it later), calls the
-- teleport native ONCE with no navmesh readback, and then acknowledges with a
-- position it samples IN THE SAME FRAME, before either operation can have
-- settled. Neither side ever re-reads the settled transform, and the client's
-- `transitionAckRevision == state.revision` guard makes every server
-- retransmission of that revision a no-op -- so a placement that did not take
-- is never retried.
--
-- That is the mechanism behind the owner's report of players who "spawn on the
-- floor" and have to disconnect and reconnect: reconnecting is the only thing
-- that produces a fresh revision to apply. It is the PLAYER-side twin of the
-- bot failure fixed 2026-09-01 in NpcAuthorityService -- one requested spawn
-- point, one engine placement somewhere else, and nothing that reconciles the
-- two -- but it is a different subsystem and this fix does not reach it.
--
-- THIS DOES NOT CORRECT IT, and that restraint is the decision. A re-place is
-- a kill (see the note below), so a correction rule that fired wrongly would
-- kill live players on a production server; and the only way to know a body is
-- inert rather than merely elsewhere is to read the settled transform, which
-- only the client can do. What this does is make the failure VISIBLE and name
-- the mark, so a spawn mark the engine will not honour can be found in a log
-- instead of in a player's complaint. The bot side of the same question is now
-- answered by the server's `NPC spawn projection adopted` line.
--
-- 1200 ms is chosen so a legitimate player cannot have covered the threshold:
-- a sprint is roughly 8 m/s, so under 10 m, comfortably inside the 20 m this
-- calls anomalous.
local kPlacementCheckMs = 1200
local kPlacementDriftMetres = 20.0

local function verifyPlacement(playerId, requested, reason, token)
    local record = players[playerId]
    if record == nil or record.placementToken ~= token then return end

    local life = Open77.players.getLifeState(playerId)
    if life == nil then return end
    local phase = phaseOf(life)
    if phase ~= "alive" and phase ~= "recovering" then
        log(("placement did not settle player=%d reason=%s phase=%s -- the body is still"
            .. " in the transition a second after the request was accepted"):format(
            playerId, tostring(reason), phase))
        return
    end

    -- `players.position` raises on a non-positive id rather than returning an
    -- error, and a raise inside a SetTimeout callback stops the resource. The
    -- id was normalised by the caller, but this runs a second later and on a
    -- player who may have left, so it is guarded rather than trusted.
    local ok, position = pcall(Open77.players.position, playerId)
    if not ok or type(position) ~= "table" then return end
    local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
    if x == nil or y == nil or z == nil then return end

    local dx, dy, dz = x - requested.x, y - requested.y, z - requested.z
    local drift = math.sqrt(dx * dx + dy * dy + dz * dz)
    if drift < kPlacementDriftMetres then return end
    log(("placement drift player=%d reason=%s requested=%.3f,%.3f,%.3f actual=%.3f,%.3f,%.3f"
        .. " drift=%.1fm -- the engine did not honour the mark"):format(
        playerId, tostring(reason), requested.x, requested.y, requested.z, x, y, z, drift))
end

-- Every placement in the mode is a `kill -> respawn`, which means EVERY
-- PLACEMENT IS A DEATH, and there are two ledgers that must both be told not
-- to count it: round.lua's (`Deathmatch.deathGate`, R4) and scoring.lua's
-- (`Deathmatch.scoring.suppressDeath`, S2). They are separate on purpose --
-- one gates the round rule, the other gates the standings -- so both are
-- suppressed here, before the kill, at the one place that can know.
local function placeAt(playerId, position, heading, bucket, reason, graceMs)
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end

    graceMs = graceMs or Config.round.placementGraceMs

    DM.suppressDeath(playerId, 2500)
    DM.scoring.suppressDeath(playerId, 2500)

    local phase = phaseOf(life)
    if phase == "alive" or phase == "recovering" then
        local killed, killReason = Open77.players.kill(playerId, {
            cause = "script",
            weapon = "deathmatch:" .. tostring(reason or "place"),
        })
        if not killed then return false, "kill:" .. tostring(killReason) end
    elseif phase ~= "dead" then
        -- Never judge a player mid-transition. A placement onto a body that is
        -- still resolving is how a spawn becomes a fall.
        return false, "transition_in_progress:" .. phase
    end

    local respawned, respawnReason = Open77.players.respawn(playerId, {
        position = { x = position.x, y = position.y, z = position.z },
        heading = heading or 0.0,
        bucket = bucket,
        health = 1.0,
        graceMs = graceMs,
    })
    if not respawned then return false, "respawn:" .. tostring(respawnReason) end

    -- M7. No rule may judge a player while a placement is in flight. This is
    -- the `hold` half of the contract; `setGraceReader` is the alternative and
    -- registering both would be two answers to one question.
    DM.bounds.hold(playerId, graceMs)

    Open77.players.setArmor(playerId, 0)
    Open77.players.setRegen(playerId, 0)

    -- The token makes the check belong to THIS placement: a player re-placed
    -- inside the window -- a round start landing on a join, say -- must not be
    -- judged by the mark they have already left.
    local record = players[playerId]
    if record ~= nil then
        record.placementToken = (record.placementToken or 0) + 1
        local token = record.placementToken
        local requested = { x = position.x, y = position.y, z = position.z }
        SetTimeout(kPlacementCheckMs, function()
            verifyPlacement(playerId, requested, reason, token)
        end)
    end
    return true
end


-- ------------------------------------------------------------ spawn marks --

-- R2/M2. The marks live in `DeathmatchKabuki.spawns.ffa` and kabuki ships
-- UNSURVEYED: an entry whose `position` is still nil is not a coordinate and
-- must never be placed onto. Skipped here rather than defended against
-- downstream, so an empty list is an honest "no mark" instead of a placement
-- at (0,0,0) -- which is a real place in Night City.
local function surveyedMarks()
    local list = {}
    for _, mark in ipairs(DeathmatchKabuki.spawns.ffa or {}) do
        if DeathmatchKabuki.point(mark.position) ~= nil then
            list[#list + 1] = mark
        end
    end
    return list
end

-- Maximise the distance to the closest opponent. A simple round-robin made
-- adjacent four-metre marks follow each other, allowing a victim to reappear in
-- the killer's sights. This maximin choice uses the SURVEYED marks only; it
-- never invents a coordinate outside known walkable ground.
local function spawnFor(instance, playerId)
    local marks = surveyedMarks()
    local count = #marks
    if count == 0 then return nil, nil end

    instance.spawnCursor = (instance.spawnCursor or 0) + 1
    local startIndex = ((instance.spawnCursor - 1) % count) + 1

    -- Prefer recent authoritative placement targets while a simultaneous batch
    -- is still settling; afterwards use the opponents' live snapshots. This
    -- lets the second placement react to the first even before that client's
    -- next position packet reaches the server.
    local now = DM.nowMs()
    local opponents = {}
    -- Open77.players.position raises on a bot id. Bot bodies still occupy
    -- the arena, but their position belongs to the npc registry, so the
    -- maximin choice reads players here and bots are spaced by bots.lua.
    for _, opponentId in ipairs(DM.instances.humans and DM.instances.humans(instance)
            or DM.instances.members(instance)) do
        if opponentId ~= playerId then
            local assigned = instance.spawnPositions
                and instance.spawnPositions[opponentId] or nil
            local recent = assigned ~= nil and now - assigned.atMs <= 2000
            local position = recent and assigned.position
                or Open77.players.position(opponentId)
            if position == nil or (position.bucket ~= nil
                and tonumber(position.bucket) ~= instance.bucket) then
                position = assigned and assigned.position or nil
            end
            if position ~= nil then opponents[#opponents + 1] = position end
        end
    end

    if #opponents == 0 then return marks[startIndex], nil end

    local bestSpawn
    local bestMinimumSq = -1
    for offset = 0, count - 1 do
        local index = ((startIndex + offset - 2) % count) + 1
        local candidate = marks[index]
        local minimumSq = math.huge
        for _, opponent in ipairs(opponents) do
            local dx = candidate.position.x - opponent.x
            local dy = candidate.position.y - opponent.y
            local distanceSq = dx * dx + dy * dy
            if distanceSq < minimumSq then minimumSq = distanceSq end
        end
        if minimumSq > bestMinimumSq then
            bestSpawn = candidate
            bestMinimumSq = minimumSq
        end
    end
    return bestSpawn, math.sqrt(bestMinimumSq)
end


-- ------------------------------------------------------- the two shapes --

-- R2. `mark` is used VERBATIM when given: arena.lua passes the surveyed team
-- mark for the player's side, and a maximin choice over the free-for-all marks
-- would put a duellist outside the carved 1v1 zone, where the bounds backstop
-- would then "correct" them by killing them. Free-for-all passes nothing and
-- keeps maximin.
local function placeInArena(playerId, instance, reason, graceMs, mark)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false, "bad_player_id" end
    if instance == nil or instance.closed then return false, "no_instance" end

    local spawn, minimumSeparation = mark, nil
    if spawn == nil then spawn, minimumSeparation = spawnFor(instance, playerId) end
    if spawn == nil or DeathmatchKabuki.point(spawn.position) == nil then
        log(("arena placement refused player=%d instance=%d -- no surveyed mark"):format(
            playerId, instance.id))
        return false, "not_surveyed"
    end

    local position = {
        x = spawn.position.x,
        y = spawn.position.y,
        z = spawn.position.z + Config.placement.spawnLiftMetres,
    }
    SetPlayerRoutingBucket(playerId, instance.bucket)
    local ok, detail = placeAt(playerId, position, spawn.heading,
        instance.bucket, reason, graceMs)
    if not ok then
        log(("arena placement failed player=%d instance=%d reason=%s"):format(
            playerId, instance.id, tostring(detail)))
        return false, detail
    end

    instance.spawnPositions = instance.spawnPositions or {}
    instance.spawnPositions[playerId] = { position = position, atMs = DM.nowMs() }
    log(("arena placement player=%d instance=%d at %.3f %.3f %.3f bucket=%d reason=%s minOpponentDistance=%s"):format(
        playerId, instance.id, position.x, position.y, position.z,
        instance.bucket, tostring(reason), minimumSeparation ~= nil
            and ("%.1fm"):format(minimumSeparation) or "n/a"))
    syncBounds(playerId)
    return true
end

local function sendToLobby(playerId, reason)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false, "bad_player_id" end

    SetPlayerRoutingBucket(playerId, Config.buckets.lobby)
    local ok, detail = placeAt(playerId, Config.lobby.center, Config.lobby.heading,
        Config.buckets.lobby, reason or "lobby", Config.lobby.placementGraceMs)
    if not ok then
        log(("lobby placement failed player=%d reason=%s"):format(playerId, tostring(detail)))
    end
    DM.loadout.strip(playerId)
    syncBounds(playerId)
    return ok, detail
end


-- ============================================================ state push --

-- R10. The record-shaped part is all this file owns; everything about the
-- fight comes from one call. THE FRAGMENT IS AUTHORITATIVE for `phase` and
-- `playerState` -- a player eliminated in an arena round and a player waiting
-- out a free-for-all respawn are different states main.lua has no way to tell
-- apart, and there is no stale copy here to fall back to.
--
-- --------------------------------------------------------- the HUD contract --
--
-- Measured 2026-08-31, in game: a player standing in a live Kabuki round --
-- armed, with ammo, inside the market -- was shown the LOBBY DOCK. Nothing was
-- broken in the round and nothing was broken in the HUD; the two spoke
-- different shapes. The fragment is FLAT (`instanceId`, `instancePlayers`,
-- `protectionMs`) and says nothing at all about whether the player is IN a
-- fight, while open77_deathmatch_hud gates its entire in-round layout -- the
-- band, the weapon card, the K/D block, and the HIDING of the lobby dock -- on
-- one boolean, `participant`, that nothing had ever sent. Absent, it reads as
-- false, and a HUD told it is not in a match draws a lobby forever.
--
-- The shaping therefore happens HERE and not in the HUD. The fragment stays the
-- server's own vocabulary and every module goes on writing it unchanged; this
-- block is the single place that translates it, and it only ever ADDS keys:
--
--   participant       in an instance at all -- the master gate
--   instance{}        id, label, format, players, bots, capacity
--   self{}            the local player's own standings row + the shield window
--   participantCount  combatants in the round, bots included
--   maxPlayers        the instance capacity, for the occupancy readout
--   matchId           instance-round, for the match eyebrow
--   queuedNext        arena queue only; free-for-all never queues (decision 2)
--   crosshair         the gamemode's say over the reticle
--   phase             normalised to the HUD vocabulary; `roundState` keeps the raw
--
-- `phase` is the one key rewritten rather than added, and only for the
-- free-for-all standings interval. round.lua calls that state `standings`; the
-- HUD -- and its CSS, in four selectors -- calls the end-of-round screen
-- `resolved`. Same moment, other name. The raw value survives as `roundState`,
-- so nothing is lost, and arena's `buy` / `between` pass straight through:
-- those are genuinely different states, and inventing an equivalence for them
-- would be a lie rather than a translation.
local HUD_PHASE = {
    standings = "resolved",
}

-- HOW MANY BOTS THIS INSTANCE HOLDS, and the history is worth keeping because
-- the same trap caught two files a fortnight apart. `defaultHost.addParticipant`
-- binds a bot TWICE -- under its negative participant id, and again under its
-- uint64 npc id as an alias, so the damage gate can resolve a shot arriving
-- under either -- and both bindings used to land in `instance.actors`. Anything
-- that counted that table read 2 for one bot and 12 for six: the HUD did, and
-- was fixed here; `/dm.instances` did, and was not, which is how a 3v3 filled
-- with five bots printed `1/6+10bot` on 2026-09-01 and cost an hour to a
-- hypothesis about bots accumulating across rounds that was never true.
--
-- The kernel now keeps the two spaces in two tables (`Instances.bindActor`), so
-- `actors` is the participant space and counting it is honest. Three sources are
-- tried in the order of their authority: bots.lua owns bot lifecycle and counts
-- its own; the kernel's `botCount` is the one definition of the table walk; and
-- a plain count of `actors` is the last resort for a host that has neither.
local function botCount(instance)
    if instance == nil then return 0 end
    local module = DeathmatchBots
    if type(module) == "table" and type(module.count) == "function" then
        local ok, count = pcall(module.count, instance.id)
        if ok then return math.floor(tonumber(count) or 0) end
    end
    local instances = DM.instances
    if type(instances) == "table" and type(instances.botCount) == "function" then
        return instances.botCount(instance)
    end
    if type(instance.actors) ~= "table" then return 0 end
    local count = 0
    for actorId in pairs(instance.actors) do
        local id = tonumber(actorId)
        if id ~= nil and id < 0 then count = count + 1 end
    end
    return count
end

-- The protection ring needs a denominator and the server remembers only a
-- deadline. The PEAK remaining seen inside the current window is that
-- denominator: the sweep then reaches zero exactly when the shield does, which
-- is the only property a sweep has to have. A fresh grant is recognised by the
-- remaining time going UP, and the peak is dropped the moment the shield
-- expires, so the next window measures itself rather than the last one.
local function protectionWindow(record, remainingMs)
    if remainingMs <= 0 then
        if record ~= nil then record.protectionPeakMs = nil end
        return 0, 0
    end
    if record == nil then return remainingMs, remainingMs end
    local peak = record.protectionPeakMs
    if peak == nil or remainingMs > peak then
        peak = remainingMs
        record.protectionPeakMs = peak
    end
    return remainingMs, peak
end

-- The local player's own line, taken from the ONE scoreboard rather than
-- counted a second time here. A player who has not scored yet has no row, and
-- the zeroes below are the honest answer to that -- not a placeholder standing
-- in for a number that exists somewhere else.
local function selfRow(rows, playerId)
    for _, row in ipairs(rows) do
        if row.id == playerId then return row end
    end
    return nil
end

local function stateFor(playerId)
    local record = players[playerId]
    local payload = { playerId = playerId }
    for key, value in pairs(DM.fragmentFor(playerId)) do
        payload[key] = value
    end

    local instance = DM.instances.of(playerId)
    payload.rows = DM.scoring.rows(instance)
    if record ~= nil and record.awaitingReady then payload.awaitingReady = true end

    -- ------------------------------------------------------ the HUD shape --

    payload.roundState = payload.phase
    payload.phase = HUD_PHASE[payload.phase] or payload.phase

    -- THE ONE THAT WAS MISSING. Membership of an instance is the whole of it: a
    -- player eliminated in an arena round and a player counting down a
    -- free-for-all respawn are both still IN the fight, and `playerState`
    -- already carries the difference between them.
    payload.participant = instance ~= nil and instance.closed ~= true

    -- Free-for-all never queues (decision 2), so this is true only for a player
    -- sitting in an arena queue -- which is exactly when arena.lua sets
    -- `playerState` to "queued".
    payload.queuedNext = payload.playerState == "queued"

    -- The gamemode's say over the reticle. Always true today; sent explicitly
    -- so a future rule -- a scoped weapon, a cutscene -- has a key to write.
    payload.crosshair = true

    if instance ~= nil then
        payload.instance = {
            id = instance.id,
            label = instance.label,
            format = instance.format,
            players = instance.memberCount,
            bots = botCount(instance),
            capacity = instance.capacity,
        }
        payload.maxPlayers = instance.capacity
    end

    -- Flat, beside `instance.bots`, because the number answers a question the
    -- nested block does not: "does the round I am in count?". The ladder
    -- exclusion is a property of the ROUND, and a client -- or a test -- that
    -- wants to correlate `result.ranked` with the reason for it should not have
    -- to reach into a sub-table that only exists while the player is in an
    -- instance.
    payload.botCount = instance ~= nil and botCount(instance) or 0

    -- Combatants, bots included: the standings are the only place that knows
    -- how many bodies are actually in the round. A row belonging to a player
    -- who has left keeps its score and stops being counted, which is the whole
    -- meaning of `active`.
    local combatants = 0
    for _, row in ipairs(payload.rows) do
        if row.active ~= false then combatants = combatants + 1 end
    end
    payload.participantCount = combatants

    local remainingMs, totalMs = protectionWindow(
        record, math.max(0, math.floor(tonumber(payload.protectionMs) or 0)))
    local mine = selfRow(payload.rows, playerId)
    payload.self = {
        id = playerId,
        name = (mine ~= nil and mine.name) or Open77.players.name(playerId) or "",
        team = mine ~= nil and mine.team or 0,
        rank = mine ~= nil and mine.rank or 0,
        kills = mine ~= nil and mine.kills or 0,
        deaths = mine ~= nil and mine.deaths or 0,
        assists = mine ~= nil and mine.assists or 0,
        damage = mine ~= nil and mine.damage or 0,
        score = mine ~= nil and mine.score or 0,
        streak = mine ~= nil and mine.streak or 0,
        bestStreak = mine ~= nil and mine.bestStreak or 0,
        bot = false,
        protection = { remainingMs = remainingMs, totalMs = totalMs },
    }

    if payload.round ~= nil then
        payload.matchId = ("%s-%s"):format(
            tostring(payload.instanceId or 0), tostring(payload.round))
    end

    return payload
end

local function pushState(playerId)
    if players[playerId] == nil then return end
    syncBounds(playerId)

    -- `/dm.arena.mock` owns ONE caller's surface while it is running, and this
    -- is the whole of that mechanism.
    --
    -- It is here rather than inside `DM.fragmentFor` for a reason that is not
    -- obvious: this function overlays `participant`, `rows`, `self` and
    -- `instance` onto the fragment from the INSTANCE REGISTRY, and a player
    -- looking at a mock is in no instance -- so a fragment-level override would
    -- reach the page with `participant = false` and draw nothing at all. The
    -- mock therefore supplies the finished payload, and `stateFor` is skipped.
    --
    -- No arena format can start until the twelve team marks in
    -- `shared/kabuki.lua` are surveyed (`Arena.cluster` refuses a cluster with
    -- an unset mark), so without this the arena HUD is unreachable on this
    -- build. `Arena.mockStateFor` answers nil for everybody else and on every
    -- server where the command has never been run, which is every server.
    local arena = DM.arena
    local mock = type(arena) == "table" and type(arena.mockStateFor) == "function"
        and arena.mockStateFor(playerId) or nil

    TriggerClientEvent("deathmatch:state", playerId, mock or stateFor(playerId))
end

broadcastState = function()
    for playerId in pairs(players) do pushState(playerId) end
end


-- ========================================================= combat policy --
--
-- Combat policy is host-global. During a hot reload the incoming VM is prepared
-- before the outgoing VM receives onResourceStop. The old cleanup used to set
-- friendly fire false *after* this generation enabled it, silently cancelling
-- every PvP report after any edit. Apply once immediately and once on the first
-- scheduler tick, when the outgoing generation is guaranteed to be gone. There
-- is deliberately no stop-time reset: shutting the server needs none, and a
-- reload must leave its successor's policy intact.
local function applyCombatPolicy()
    local operations = {
        { "friendly_fire", Open77.combat.setFriendlyFire, Config.combat.friendlyFire },
        { "damage_multiplier", Open77.combat.setDamageMultiplier,
            Config.combat.damageMultiplier },
        { "headshot_multiplier", Open77.combat.setHeadshotMultiplier,
            Config.combat.headshotMultiplier },
        { "ranged_multiplier", function(value)
            return Open77.combat.setKindDamageMultiplier("ranged", value)
        end, Config.combat.rangedMultiplier },
    }
    for _, operation in ipairs(operations) do
        local ok, reason = operation[2](operation[3])
        if ok ~= true then
            log(("combat policy %s failed: %s"):format(
                operation[1], tostring(reason)))
        end
    end
end

-- Host-global multipliers and friendly fire belong to Freeroam's combat.lua.


-- ========================================================= damage arbiter --

local damageDecisionLog = {}
local function logDamageDecision(attackerId, reason, expected, reported)
    local key = table.concat({ tostring(attackerId), tostring(reason),
        tostring(expected), tostring(reported) }, ":")
    local at = DM.nowMs()
    if damageDecisionLog[key] ~= nil and at - damageDecisionLog[key] < 2000 then return end
    damageDecisionLog[key] = at
    log(("damage rejected attacker=%s reason=%s expected=%s reported=%s"):format(
        tostring(attackerId), tostring(reason), tostring(expected), tostring(reported)))
end

-- M5 + L2 + R13. `Open77.combat.onDamage` is HOST-GLOBAL and fires for every
-- candidate on the server, so the INSTANCE GATE GOES FIRST -- before the round
-- check, before the weapon check, before anything. A shot damaging a stranger
-- in another instance is the worst bug this design can produce, and it is a
-- failure mode that could not exist while there was one global `match`.
Open77.combat.onDamage(function(event)
    local victim = DM.instances.resolve(event.victim)
    local attacker = DM.instances.resolve(event.attacker)
    if victim == nil and attacker == nil then return true end
    local allowed, _, instance = DM.instances.damageGate(event)
    if not allowed then return false end

    -- EVERY attacker id goes through the translation first. A bot exists as a
    -- synthetic negative participant id AND as a uint64 NPC id, and its shots
    -- arrive under the latter -- which `tonumber` corrupts past 2^53.
    local attackerId = DeathmatchBots.attackerId(event.attacker)
    if attackerId == 0 then return true end          -- environment

    if instance and instance.format ~= "ffa" then
        local victimSide = DM.arena.sideOf(tonumber(event.victim))
        local attackerSide = DM.arena.sideOf(attackerId)
        if victimSide and attackerSide == victimSide and tonumber(event.victim) ~= attackerId then
            return false
        end
    end

    if instance == nil or instance.round == nil
        or instance.round.state ~= "active" then return false end

    -- A BOT's weapon was never issued through the loadout book, so there is
    -- nothing for `accepts` to match and it would fail closed on every bot
    -- shot. bots.lua owns bot fire end to end; the instance gate above is what
    -- keeps it honest. This is a special case at the WEAPON check only, never
    -- at the instance one.
    if attackerId < 0 then return true end

    -- L2. THE SET, not one id: three slots are issued, so a sidearm or katana
    -- kill would otherwise be refused as `wrong_weapon` while the player holds
    -- a weapon the server itself handed them. `accepts` fails closed.
    local ok, why = DM.loadout.accepts(instance, attackerId, event.weaponTdbId)
    if not ok then
        logDamageDecision(attackerId, why,
            instance.weaponIds[attackerId], event.weaponTdbId)
        return false
    end

    -- THE VICTIM'S SHIELD, and it has to be enforced HERE because nothing else
    -- enforces it.
    --
    -- The plan asserted -- and this file believed -- that `graceMs` on the
    -- respawn holds the player in `Recovering`, which "retains the temporary
    -- spawn protection". That is false in this codebase, and the audit that
    -- found it is worth restating so nobody re-derives the same comfort:
    -- `DamageAuthorityService.IsCombatCapable` treats `Recovering` exactly like
    -- `Alive`, and `PlayerLifeService.Kill` explicitly permits killing a player
    -- in `Recovering`. The only real invulnerability the platform has is
    -- `players.setGodMode`, which this mode never calls.
    --
    -- So the countdown ring was real, the deadline was real, `bots.lua` honoured
    -- it -- and every PLAYER shot straight through it. The shield existed
    -- against the half of the game that was scripted and not against the half
    -- that was not, which is the worst of both: visible, believed, and absent.
    --
    -- Checked after the weapon verification for the same reason `breakProtection`
    -- is: an unverified or cross-instance report is noise, and neither dropping a
    -- shield nor reporting a refusal should answer to it.
    local victimId = DM.playerId(event.victim)
    if victimId ~= nil and victimId ~= attackerId
        and DM.protectionRemaining(victimId) > 0 then
        return false
    end

    -- R13, and deliberately AFTER the verification: an unverified or
    -- cross-instance report is not aggression, it is noise, and dropping a
    -- player's shield on it would make the shield unreliable in exactly the
    -- situation it exists for.
    DM.breakProtection(attackerId)
    return true
end)

AddEventHandler("open77:combatAnomaly", function(playerId, kind, detail)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    local instance = DM.instances.of(playerId)
    if instance ~= nil and instance.round ~= nil and instance.round.state == "active" then
        log(("combat anomaly player=%d instance=%d kind=%s detail=%s"):format(
            playerId, instance.id, tostring(kind), tostring(detail)))
    end
end)


-- ================================================================ deaths --
--
-- R8. Both handlers are one line and hand the ids over RAW: `Deathmatch.onDeath`
-- runs them through `Deathmatch.playerId` itself, because they arrive as
-- strings and a `tonumber` at only one of the two call sites is how the two
-- tables diverge.
--
-- scoring.lua registers these same two events for the STANDINGS; this pair
-- drives the ROUND -- the respawn timer and the kill limit -- and the two paths
-- converge on `Scoring.countDeath`, whose debounce drops whichever arrives
-- second. That convergence is designed for: see scoring.lua's own note on
-- `Scoring.credit`, "two entry points now describe one player death".
AddEventHandler("open77:playerKilled", function(victimId, killerId)
    DM.onDeath(victimId, killerId, "player")
end)

AddEventHandler("open77:playerDied", function(playerId, context)
    local killerId = 0
    if type(context) == "string" then
        killerId = tonumber(context:match('"killer"%s*:%s*(%-?%d+)')) or 0
    elseif type(context) == "table" then
        killerId = tonumber(context.killer) or 0
    end
    DM.onDeath(playerId, killerId, "environment")
end)


-- ================================================================= entry --

-- R5. Free-for-all never queues: there is nothing to wait for, so there is
-- nothing to enrol in. Readiness, capacity and the refusal card are all
-- `Deathmatch.round.join`'s job.
local function joinRequest(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil or ensurePlayer(playerId) == nil then return end
    DM.round.join(playerId)
    broadcastState()
end

RegisterNetEvent("deathmatch:join", function()
    joinRequest(source)
end)

-- The entry station. Same act, different way in -- decision 10 makes the
-- station the way in and leaves `/dm` as the power-user fallback.
RegisterNetEvent("deathmatch:stationEnter", function()
    joinRequest(source)
end)

-- R6. The queue station opens the panel; the panel sends `deathmatch:queue`.
RegisterNetEvent("deathmatch:stationQueue", function()
    local playerId = DM.playerId(source)
    if playerId == nil or ensurePlayer(playerId) == nil then return end
    pushState(playerId)
    TriggerClientEvent("deathmatch:panel", playerId, true)
end)

RegisterNetEvent("deathmatch:queue", function(size)
    local playerId = DM.playerId(source)
    if playerId == nil or ensurePlayer(playerId) == nil then return end
    DM.arena.enqueue(playerId, size)
    broadcastState()
end)

RegisterNetEvent("deathmatch:kit", function(key)
    local playerId = DM.playerId(source)
    if playerId == nil or ensurePlayer(playerId) == nil then return end
    DM.arena.pickKit(playerId, key)
end)

-- R7. One call answers all three cases -- an arena queue entry, a free-for-all
-- instance, an arena match -- and answers "the player is in none of them" by
-- doing nothing.
RegisterNetEvent("deathmatch:leave", function(scope)
    local playerId = DM.playerId(source)
    if playerId == nil or ensurePlayer(playerId) == nil then return end
    DM.leave(playerId, scope)
    broadcastState()
end)

RegisterNetEvent("deathmatch:requestState", function()
    local playerId = DM.playerId(source)
    if playerId == nil or ensurePlayer(playerId) == nil then return end
    pushState(playerId)
end)


-- ============================================================= readiness --

local function joinPlacement(playerId, record)
    record.sinceMs = DM.nowMs()
    if not sendToLobby(playerId, "join") then
        record.awaitingReady = true
        return false
    end
    record.awaitingReady = false
    record.placed = true
    log(("player %d placed in lobby at %.2f %.2f %.2f bucket=%d"):format(
        playerId, Config.lobby.center.x, Config.lobby.center.y,
        Config.lobby.center.z, Config.buckets.lobby))
    pushState(playerId)
    return true
end

-- The readiness gate, and it is the reason placement is deferred at all: a
-- player who has announced but not incarnated has no body to place.
local function placeWhenPlaceable(playerId, record, startedMs)
    if players[playerId] ~= record or not record.awaitingReady then return end
    if not Open77.ready.isReady(playerId) then return end
    if Open77.players.getLifeState(playerId) ~= nil then
        if joinPlacement(playerId, record) then return end
    end
    if DM.nowMs() - startedMs >= Config.lobby.placementRetryTimeoutMs then
        record.awaitingReady = false
        log(("join placement timed out player=%d"):format(playerId))
        return
    end
    SetTimeout(Config.lobby.placementRetryMs, function()
        placeWhenPlaceable(playerId, record, startedMs)
    end)
end

RegisterNetEvent("deathmatch:ready", function()
    local playerId = DM.playerId(source)
    if playerId == nil then return end
    local record = ensurePlayer(playerId)
    if record == nil then return end
    record.announced = true
    record.placed = true

    -- R12. `ensurePlayer` has already adopted a hot-reloaded client back into
    -- the instance it never left, so there is nothing to re-prime and nothing
    -- to evict: a player in an instance is a player in a fight.
    if DM.instances.of(playerId) ~= nil then
        pushState(playerId)
        return
    end

    -- ...and neither is a player who is simply STANDING SOMEWHERE. R12 only
    -- covered players in an instance, which left everyone else -- an operator
    -- surveying a map, anyone in the lobby -- being re-placed on every resource
    -- publication. A Lua edit anywhere in this resource republishes the set,
    -- the client re-announces ready, and this handler read that as a fresh
    -- join. Measured on the owner: every save I made teleported them out of
    -- Kabuki and back to the lobby, which looked from their side like the
    -- boundary rules coming back.
    --
    -- A player is placed ONCE per connection. A republication is not a join.
    --
    -- `record.placed` alone could not carry this: a reload hands the resource a
    -- FRESH `players` table, so the flag it lives in disappears along with
    -- everything else, and the next `ready` looked like a first join all over
    -- again. The durable signal is the absence of `onPlayerConnected`, which
    -- does not re-fire for an already-connected client. No connect in this
    -- generation means this player was already in the world before the reload.
    if record.placed or not record.joined then
        record.placed = true
        pushState(playerId)
        return
    end

    if not Open77.ready.isReady(playerId) then
        record.awaitingReady = true
        log(("player %d announced before readiness gate; placement deferred"):format(playerId))
        return
    end
    record.awaitingReady = true
    placeWhenPlaceable(playerId, record, DM.nowMs())
end)

AddEventHandler("onPlayerReady", function(playerIdStr)
    local playerId = DM.playerId(playerIdStr)
    local record = playerId and players[playerId] or nil
    if record == nil or not record.announced or not record.awaitingReady then return end
    placeWhenPlaceable(playerId, record, DM.nowMs())
end)

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = DM.playerId(playerIdStr)
    if playerId == nil then return end
    local record = ensurePlayer(playerId)
    -- The ONLY reliable signal that this is a real join rather than a resource
    -- republication. `onPlayerConnected` does not re-fire for a player who is
    -- already connected, so a `deathmatch:ready` that arrives without it came
    -- from a client reloading its scripts -- and that player is already
    -- standing somewhere and must not be moved.
    if record ~= nil then record.joined = true end
    log(("player %d connected"):format(playerId))
end)

-- M8 + R8. `Deathmatch.forget` runs BEFORE the kernel detaches, because the
-- arena's forfeit rule needs to know which side just lost a body.
AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = DM.playerId(playerIdStr)
    if playerId == nil then return end
    DM.forget(playerId)
    DM.instances.detach(playerId, "disconnected")
    DM.bounds.forget(playerId)
    players[playerId] = nil
    broadcastState()
end)


-- ================================================================= tick --
--
-- M6 + L3 + R9, in this order: the kernel reaps first so a round never steps
-- an instance that is about to be closed. Every one of these self-throttles or
-- is cheap enough to call at any rate; the cadence of a rule is a property of
-- the rule, not of this loop.
CreateThread(function()
    while true do
        local at = DM.nowMs()
        DM.instances.reap(at)
        DM.bounds.tick(at)
        DM.loadout.sweep(at)
        DM.round.tick(at)
        DM.arena.tick(at)

        if at >= nextStatePushMs then
            nextStatePushMs = at + Config.round.statePushMs
            broadcastState()
        end
        Wait(250)
    end
end)


-- ============================================================ the seams --
--
-- Registered once, at the bottom, after every primitive above exists.

-- R2. Both round loops place through this and neither ever calls
-- `Open77.players.kill` or `respawn` itself.
DM.setPlacement(placeInArena, sendToLobby)

-- M7. bounds DECIDES; main.lua PLACES. A backstop that invented a second way
-- to move a player would be a second placement path, and there is exactly one.
DM.bounds.setPlacer(function(playerId, instance, zoneName)
    if instance ~= nil then
        return placeInArena(playerId, instance, "bounds_backstop")
    end
    return sendToLobby(playerId, "lobby_boundary")
end)

-- M7. bounds samples instance members on its own; only this file knows who is
-- standing in the lobby, because there is still no way to list players.
DM.bounds.setRoster(function()
    -- No lobby leash on people exploring Night City, including queued players.
    return {}
end)

-- S3. Scoring changes the standings and the feed, and the HUD has to be told.
-- Guarded at every call site there, so forgetting this loses live standings
-- rather than raising.
DM.broadcastState = broadcastState

--- Re-push every roster member's boundary payload, ignoring the transition
--- cache.
---
--- `syncBounds` sends ON TRANSITION ONLY -- the zone key is remembered on the
--- record and the payload goes out when it changes -- which is right for the
--- steady state and wrong for exactly one caller: the live map editor
--- (`server/mapstore.lua`), which changes the GEOMETRY of a zone whose key
--- never moves. Without this door the client's wall stays the copy it was sent
--- when the player entered the zone, so an author would walk through a
--- boundary they had just captured and conclude the capture had not worked.
---
--- It is a roster walk, not a player enumeration: `players` is this file's own
--- record table, and a record only exists for somebody an event has already
--- named.
function DM.resyncBounds()
    for playerId in pairs(players) do syncBounds(playerId, true) end
end

-- S6. Protection drops the moment a player's own outgoing damage CREDITS,
-- which covers the paths the arbiter never sees. R13 covers verified player
-- fire in the arbiter; `breakProtection` is idempotent, so the overlap is free.
DM.scoring.setAggressionHandler(function(playerId)
    DM.breakProtection(playerId)
end)


-- ============================================================= commands --

local function output(source, raw, ok, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

-- /dm.leash <on|off> -- exempt yourself from the boundary rules.
--
-- The exemption already existed, but only as a side effect of opening a survey
-- session, and that is a trap: an operator who switches on noclip to go and
-- LOOK at something has no reason to guess that a map-editor verb is what keeps
-- the lobby from dragging them back. It caught the owner within a minute of
-- being handed noclip -- "bounds BACKSTOP player=1 zone=lobby held outside
-- 8.6s / 31 samples -> placed" -- and it would have caught the next person too.
--
-- So the capability gets its own name. The leash is still on by default and
-- still authoritative for players; this only says who it does not apply to, and
-- it is restricted, so saying it requires the ACL.
RegisterCommand("dm.leash", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, Config.strings.error.playerOnly)
    end
    local token = string.lower(tostring(args[1] or ""))
    local enabled
    if token == "off" or token == "0" or token == "false" then
        enabled = false
    elseif token == "on" or token == "1" or token == "true" then
        enabled = true
    else
        return output(source, raw, false, "usage: dm.leash <on|off>")
    end

    if Deathmatch.bounds == nil or Deathmatch.bounds.setExempt == nil then
        return output(source, raw, false, "bounds unavailable")
    end
    -- `leash off` means exempt; the command is named for the thing the operator
    -- is switching, not for the flag the code happens to store.
    Deathmatch.bounds.setExempt(source, not enabled, "manual")
    output(source, raw, true, enabled
        and "boundary rules ON for you -- you will be returned if you leave your zone"
        or "boundary rules OFF for you -- go anywhere; run 'dm.leash on' to restore")
end, true)

-- /dm.goto <x> <y> <z> [heading] -- move the caller, for SURVEYING.
--
-- Phase 1 has to walk Kabuki, and this resource set deliberately excludes
-- freeroam (its autoRespawn answers every placement this mode issues), so
-- without this there is no way to reach the map you are here to capture.
--
-- It lives in main.lua rather than in survey.lua on purpose. survey.lua has no
-- placement verb of its own, and that is the right call: `placeAt` is the ONE
-- kill -> respawn primitive, and a second path around it is exactly what a
-- single primitive exists to prevent. So the surveyor's travel goes through the
-- same transaction as every spawn, respawn and backstop placement -- which also
-- means every trip across the city exercises the code the mode depends on.
--
-- Restricted: it moves a player, and it is a development verb.
RegisterCommand("dm.goto", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, Config.strings.error.playerOnly)
    end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if x == nil or y == nil or z == nil then
        return output(source, raw, false, "usage: dm.goto <x> <y> <z> [heading]")
    end

    local record = ensurePlayer(source)
    if record == nil then return output(source, raw, false, "no record") end

    -- Keep the caller in whatever bucket they are already in. A surveyor is
    -- normally in the lobby bucket, and silently moving them into an arena
    -- dimension would make every mark they capture belong to a world nobody
    -- else can see.
    local position = Open77.players.position(source)
    local bucket = position ~= nil and tonumber(position.bucket) or Config.buckets.lobby

    local ok, detail = placeAt(source, { x = x, y = y, z = z },
        tonumber(args[4]) or 0.0, bucket, "survey_travel", Config.lobby.placementGraceMs)
    output(source, raw, ok == true, ("goto %.3f %.3f %.3f bucket=%d ok=%s reason=%s"):format(
        x, y, z, bucket, tostring(ok), tostring(detail)))
end, true)

RegisterCommand("dm", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, Config.strings.error.playerOnly)
    end
    if args.n ~= 0 then return output(source, raw, false, "usage: dm") end
    ensurePlayer(source)
    pushState(source)
    TriggerClientEvent("deathmatch:panel", source, true)
    output(source, raw, true, "opening deathmatch panel")
end, false)

RegisterCommand("deathmatch.join", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, Config.strings.error.playerOnly)
    end
    if args.n ~= 0 then return output(source, raw, false, "usage: deathmatch.join") end
    joinRequest(source)
    output(source, raw, true, "deathmatch enrollment requested")
end, false)

RegisterCommand("deathmatch.leave", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, Config.strings.error.playerOnly)
    end
    if args.n ~= 0 then return output(source, raw, false, "usage: deathmatch.leave") end
    ensurePlayer(source)
    DM.leave(source, "auto")
    broadcastState()
    output(source, raw, true, "left the arena or the queue")
end, false)

-- R14. There is no single `match` to describe any more, so the readout is the
-- registry's own: every instance, and every arena queue.
RegisterCommand("deathmatch.status", function(source, _, raw)
    output(source, raw, true, "instances -- " .. DM.instances.describe())
    output(source, raw, true, "arena queues -- " .. DM.arena.describe())
    -- Phase 8. Resolved at call time and guarded: a server running without
    -- ranked.lua plays exactly the same rounds and simply records none of them,
    -- and the status readout should say which of the two this is rather than
    -- leaving an operator to infer it from an empty ladder.
    local ranked = DM.ranked
    if type(ranked) == "table" and type(ranked.describe) == "function" then
        local ok, line = pcall(ranked.describe)
        output(source, raw, true, "career -- " .. (ok and tostring(line) or "unavailable"))
    else
        output(source, raw, true, "career -- not loaded (server/ranked.lua is not in the manifest)")
    end
end, false)


log(("ready -- lobby bucket=%d, ffa buckets %d-%d, equalizer rotation=%d, capacity=%d"):format(
    Config.buckets.lobby, Config.buckets.ffaFirst, Config.buckets.ffaLast,
    #Config.equalizer.rotation, Config.instances.ffaCapacity))
