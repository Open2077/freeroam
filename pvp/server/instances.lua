-- Kabuki Arena -- the instance kernel.
--
-- The central refactor of the plan (section 6): one global `match` becomes a
-- REGISTRY of independent instances, each owning a routing bucket, a zone, a
-- roster and a round.
--
-- This file is FIRST in the manifest, before every other server script, and
-- that is load-bearing. Load order is manifest order; this file builds the
-- `Deathmatch` global that bounds.lua, round.lua, arena.lua, loadout.lua,
-- scoring.lua, bots.lua, survey.lua and main.lua all hang themselves off, and
-- it makes the ONE `Open77.tunables.declare` call the resource is allowed.
-- Reordering these lines breaks the resource at load, not at runtime.
--
-- Server resources cannot link to each other -- the server runtime installs no
-- `exports` and no cross-resource event bus -- so one resource with many server
-- scripts sharing one Lua state is the only packaging that works. `pursuit`
-- ships nine of them for the same reason.
--
--
-- ===========================================================================
-- ===  CHANGES server/main.lua NEEDS.  APPLY THESE BY HAND.               ===
-- ===========================================================================
--
-- This file and server/bounds.lua are written against a main.lua that does not
-- exist yet. Everything below is the exact set of edits main.lua needs for the
-- two of them to work. They are written as anchored search/replace rather than
-- line numbers because other agents are rewriting main.lua in parallel and line
-- numbers will have moved; the anchors are quoted from main.lua as it stands at
-- 1070 lines.
--
-- --- M1. The tunable proxy moves here. ------------------------------------
--
-- `Open77.tunables.declare` is called ONCE per resource, in the first server
-- script. main.lua must stop declaring and start reading the published proxy.
--
--   -    local Tune = Open77.tunables.declare(Config.tunables)
--   +    local Tune = Deathmatch.tune
--
-- AND -- this is the sharp edge -- FOUR TUNABLE KEYS NO LONGER EXIST:
-- `minimumPlayers`, `countdownSeconds`, `lobbyRadius` and the old `durationSeconds`
-- spelling are gone from shared/config.lua. A misspelled or removed key RAISES
-- rather than returning nil, so every one of these is a hard error at the first
-- read, not a silent nil:
--
--   `Tune.minimumPlayers`  -> gone. Decision 2: FFA never queues and has no
--                             minimum. Delete `minimumPlayers()` (main.lua
--                             ~line 370) and every call to it.
--   `Tune.countdownSeconds`-> gone. There is no join countdown; you are placed
--                             alive and armed, mid-round, immediately.
--   `Tune.lobbyRadius`     -> gone with the cylinder. The lobby leash is a
--                             volume: `Deathmatch.bounds`.
--   `Tune.durationSeconds` -> renamed `roundSeconds`.
--   `Tune.respawnDelayMs`, `Tune.killLimit` -> unchanged, still there.
--
-- --- M2. Config keys that moved. ------------------------------------------
--
-- Straight renames, all mechanical:
--
--   Config.lobby.bucket            -> Config.buckets.lobby
--   Config.arena.bucket            -> instance.bucket        (per instance now)
--   Config.arena.spawns            -> DeathmatchKabuki.spawns.ffa   (shared/kabuki.lua)
--   Config.arena.spawnLiftMetres   -> Config.placement.spawnLiftMetres
--   Config.match.*                 -> Config.round.*
--   Config.weapons                 -> Config.equalizer.rotation
--   Config.lobby.radius            -> gone (volume)
--   Config.lobby.verticalTolerance -> gone (volume)
--   Config.lobby.warnAfterMs       -> Config.bounds.lobby.warnAfterMs
--   Config.lobby.returnAfterMs     -> Config.bounds.lobby.backstopMs
--   Config.arena.center/radius/verticalTolerance/warnAfterMs/returnAfterMs
--                                  -> gone (volumes; `Config.arena` is now the
--                                     ELIMINATION-format block, not the map)
--
-- --- M3. Bucket preparation leaves maybeFormMatch. ------------------------
--
-- main.lua ~line 549:
--
--   -    SetRoutingBucketPopulationEnabled(Config.arena.bucket, false)
--   -    SetRoutingBucketEntityLockdownMode(Config.arena.bucket, "relaxed")
--
-- Delete both. `Deathmatch.instances.open` does this per bucket, at allocation,
-- and re-does it on adoption after a hot reload.
--
-- --- M4. ensurePlayer adopts. ---------------------------------------------
--
-- main.lua ~line 52, inside `ensurePlayer`, the record-creation branch:
--
--        players[playerId] = record
--   -    SetPlayerRoutingBucket(playerId, Config.lobby.bucket)
--   +    -- Lazy roster (constraints ledger): there is still no way to list
--   +    -- players, so the registry is repopulated from the next event each
--   +    -- player produces. A player already standing in an instance bucket --
--   +    -- after a hot reload, say -- is re-adopted rather than dragged to the
--   +    -- lobby, which would place (and therefore kill) a live fighter.
--   +    if Deathmatch.instances.adopt(playerId) == nil then
--   +        SetPlayerRoutingBucket(playerId, Config.buckets.lobby)
--   +    end
--
-- --- M5. The damage arbiter dispatches by instance. -----------------------
--
-- main.lua ~line 790. THIS IS THE ONE THAT MATTERS. `Open77.combat.onDamage` is
-- host-global and fires for every candidate on the server; a shot damaging a
-- stranger in another instance is the worst bug this design can produce. The
-- instance gate goes FIRST, before the weapon check, before anything:
--
--    Open77.combat.onDamage(function(event)
--   -    if match == nil or match.state ~= "active" then return false end
--   -    local victimId = tonumber(event.victim) or 0
--   -    local attackerId = tonumber(event.attacker) or 0
--   -    if not isParticipant(victimId) then return false end
--   -    if attackerId == 0 then return true end
--   -    if not isParticipant(attackerId) then return false end
--   -    local expectedWeapon = match.weaponIds[attackerId]
--   +    local allowed, reason, instance = Deathmatch.instances.damageGate(event)
--   +    if not allowed then return false end
--   +    local attackerId = tonumber(event.attacker) or 0
--   +    if attackerId == 0 then return true end          -- environment
--   +    if instance.round == nil or instance.round.state ~= "active" then return false end
--   +    local expectedWeapon = instance.weaponIds[attackerId]
--        ...unchanged from here: the TweakDBID verification stays exactly as it is.
--
-- --- M6. The tick calls the kernel. ---------------------------------------
--
-- main.lua ~line 984, inside `CreateThread`, at the top of the loop body:
--
--        local at = nowMs()
--   +    Deathmatch.instances.reap(at)
--   +    Deathmatch.bounds.tick(at)
--
-- and DELETE the whole per-player boundary block (main.lua lines ~999-1013,
-- both `checkBoundary` calls) together with the `checkBoundary` function
-- (~951-982), `containsPlayer` (~110-123) and `resetBoundary` (~85-88).
-- bounds.lua owns all three now, on boxes instead of a cylinder, and it
-- self-throttles to ~5 Hz regardless of how often the tick calls it.
--
-- --- M7. Register the placer with bounds. ---------------------------------
--
-- bounds.lua DECIDES; it never places, because kill -> respawn belongs to the
-- one placement primitive main.lua owns. Near the bottom of main.lua, after
-- `placeInArena` and `sendToLobby` are defined:
--
--   + Deathmatch.bounds.setPlacer(function(playerId, instance, zoneName)
--   +     if instance ~= nil then
--   +         return placeInArena(playerId, instance, "bounds_backstop")
--   +     end
--   +     return sendToLobby(playerId, "lobby_boundary")
--   + end)
--
-- And two more hooks, both one line:
--
--   * inside `placeAt`, where it already writes `record.graceUntilMs`, add
--
--       + Deathmatch.bounds.hold(playerId, graceMs or Config.round.placementGraceMs)
--
--     so no rule judges a player while a placement is in flight. `setGraceReader`
--     is the alternative if main.lua would rather publish `record.graceUntilMs`
--     than call `hold` at each placement -- one or the other, not both.
--
--   * once, near the placer registration, hand bounds the lobby roster. It
--     samples instance members on its own; only main.lua knows who is standing
--     in the lobby, because there is still no way to list players:
--
--       + Deathmatch.bounds.setRoster(function()
--       +     local list = {}
--       +     for playerId in pairs(players) do list[#list + 1] = playerId end
--       +     return list
--       + end)
--
-- --- M8. Disconnect detaches. ---------------------------------------------
--
-- main.lua ~line 940, inside `onPlayerDisconnected`:
--
--   +    Deathmatch.instances.detach(playerId, "disconnected")
--   +    Deathmatch.bounds.forget(playerId)
--        players[playerId] = nil
--
-- --- M9. Strings. ---------------------------------------------------------
--
-- Every `notice(...)` call in main.lua carries hardcoded unaccented French
-- ("PATIENTEZ", "L'arme de la manche n'a pas pu etre equipee", "EGALITE", ...).
-- Decision 16: all of it is English and all of it lives in
-- `Config.strings.notice`. `Deathmatch.notice(playerId, kind, key, ...)` is
-- published below and formats from that table, so the replacement is
-- mechanical:
--
--   -    notice(playerId, "warning", "PATIENTEZ", "Votre personnage n'est pas encore pret.")
--   +    Deathmatch.notice(playerId, "warning", "notReady")
--
-- --- M10. What main.lua stops owning entirely. ----------------------------
--
--   the global `match` upvalue, `maybeFormMatch`, `queue`, `addToQueue`,
--   `removeFromQueue`, `queuePosition`, `queueContains`, `cancelCountdown`,
--   `prepareMatchStart`, `activateMatch`
--       -> round.lua (FFA) and arena.lua (queued formats). Instances replace
--          the global; the FFA queue does not exist at all.
--
--   `equipWeapon`, `stripWeapons`, `normalizeWeaponId`, `weaponRequests`,
--   the `open77:weapons:completed` handler
--       -> loadout.lua.
--
--   `countDeath`, `sortedRows`, the killfeed payload
--       -> scoring.lua.
--
-- main.lua keeps: lifecycle, the lazy roster, `placeAt`/`placeInArena`/
-- `sendToLobby`, commands, the tick and the state push. That is section 6's
-- table and it is the smallest main.lua the mode can have.
-- ===========================================================================


-- The one namespace. Global rather than local on purpose: the server runtime
-- installs no exports, so a shared global table in one Lua state is how nine
-- server scripts talk to each other. Guarded with `or` so the file is
-- re-entrant if it is ever loaded twice.
Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig

DM.config = Config

-- ---------------------------------------------------------------- helpers --

function DM.nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

function DM.log(text)
    print("[deathmatch] " .. tostring(text))
end

-- A BOT IS A PARTICIPANT, so a participant id reaches here -- from a kill feed,
-- a death card, a round winner. `Open77.players.name` RAISES on a non-positive
-- id, and it raises from inside the C function: the CLR exception unwinds past
-- every `pcall`, out of the Lua host, and is caught by ServerResourceHost.Tick,
-- which logs the message bare and STOPS the resource. That is why the crash had
-- no Lua frame and no stack, and why wrapping the call site achieved nothing.
--
-- Only five player bindings behave this way -- `players.name`, `.position`,
-- `.identifier`, `ready.isReady` and the routing-bucket pair. Every other one
-- (`damage`, `kill`, `respawn`, `combat.setTeam`, all of `weapons.*`) goes
-- through TryLuaPositiveId and returns `false, "invalid_player_id"`. So the
-- guard belongs at each door onto those five, exactly like `DM.notice` below,
-- and nowhere else.
function DM.playerName(playerId)
    local id = tonumber(playerId)
    if id == nil then return "?" end
    id = math.floor(id)
    if id <= 0 then
        local scoring = DM.scoring
        if type(scoring) == "table" and type(scoring.displayName) == "function" then
            local ok, name = pcall(scoring.displayName, id)
            if ok and name ~= nil then return tostring(name) end
        end
        if id == 0 then return "" end
        -- Literal fallback so the guard holds even if scoring.lua is absent.
        return "BOT " .. tostring(-id)
    end
    return Open77.players.name(id) or ("Player " .. tostring(id))
end

-- Command arguments and event payloads arrive as strings and may be anything at
-- all; NaN and the infinities pass `tonumber` and poison every comparison
-- downstream.
function DM.finite(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed
        or parsed == math.huge or parsed == -math.huge then
        return nil
    end
    return parsed
end

-- Player IDs arrive as STRINGS at every lifecycle handler. `tonumber` here, at
-- every entry point, or the table keys silently diverge and a player has two
-- records that never meet.
function DM.playerId(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed <= 0 then return nil end
    return math.floor(parsed)
end

-- Decision 16: every player-facing string is English and lives in one table.
-- `key` indexes `Config.strings.notice`; the varargs are `string.format`
-- arguments for the body.
-- A BOT IS NOT A PLAYER, and every engine binding that takes a player id says
-- so by refusing a negative one: `id must be positive (Parameter 'value')`,
-- which stops the whole resource with `runtime_error`. That is exactly what
-- happened on the first round ever started -- four bots joined, the round began,
-- and the mode died before anybody moved.
--
-- The guard lives HERE, at the entry point, rather than only in the loop that
-- happened to trip it. `DM.instances.members()` returns participants, and a bot
-- IS a participant -- it holds a slot, it scores, it appears in the standings --
-- so every present and future caller iterating members will hand this a bot.
-- Filtering at each call site fixes one loop and leaves the trap armed.
--
-- A bot has no client, so there is nobody to notify. Silently.
function DM.notice(playerId, kind, key, ...)
    if type(playerId) == "number" and playerId <= 0 then return end
    local entry = Config.strings.notice[key]
    if entry == nil then
        DM.log(("notice: no string for key '%s'"):format(tostring(key)))
        return
    end
    local body = entry.body
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, body, ...)
        body = ok and formatted or entry.body
    end
    TriggerClientEvent("deathmatch:notice", playerId, {
        kind = tostring(kind or "info"),
        title = tostring(entry.title or Config.strings.title),
        message = tostring(body or ""),
    })
end

-- THE ONE `declare` CALL IN THE RESOURCE, and it is here because this file is
-- first in the manifest. The declaration TABLE lives in shared/config.lua
-- beside everything else this mode tunes; the CALL is server-only, because
-- `Open77.tunables` does not exist on the client and a `shared_script` that
-- calls it fails on every connecting player and refuses the whole resource set.
--
-- `DM.tune.key` IS A CALL BEHIND A METATABLE, NOT A FIELD. Read it at the point
-- of use. A local taken at file scope freezes the value at load and every later
-- change from the panel does nothing while the panel goes on reporting the new
-- number.
DM.tune = Open77.tunables.declare(Config.tunables)


-- ================================================================ registry --

DM.instances = DM.instances or {}
local Instances = DM.instances

-- instanceId -> instance
local registry = {}
-- bucket -> instanceId. The owner table is what makes "first-free" honest: an
-- instance is not allowed to exist without its bucket being claimed here, and
-- the bucket is released only in `close`.
local bucketOwner = {}
-- playerId -> instance, and actorId (bots) -> instance. Two tables rather than
-- one because a bot id and a player id come from different spaces and confusing
-- them would be a silent cross-instance leak, which is exactly the bug this
-- file exists to prevent.
local playerIndex = {}
local actorIndex = {}

local nextInstanceId = 1
local openCount = { ffa = 0, arena = 0 }

-- Diagnostics are buffered and counted, then logged once. An unbuffered probe
-- once reported 291 ms where the truth was 14 ms.
local rejections = { cross_instance = 0, victim_not_in_instance = 0,
    attacker_not_in_instance = 0, instances_full = 0 }
local lastRejectionLogMs = {}

Instances.registry = registry
Instances.rejections = rejections


-- ------------------------------------------------------------ tuned reads --
--
-- Every one of these is read at the point of use, never cached at file scope.

local function ffaCapacity()
    return math.max(1, math.floor(DM.finite(DM.tune.ffaCapacity)
        or Config.instances.ffaCapacity))
end

local function ceilingFor(kind)
    if kind == "arena" then
        return math.max(1, math.floor(DM.finite(DM.tune.arenaCeiling)
            or Config.instances.arenaCeiling))
    end
    -- Also enforce the policy at allocation time, independent of carried or
    -- persisted tunables from the old multi-instance Freeroam configuration.
    if Config.freeroam then return 1 end
    return math.max(1, math.floor(DM.finite(DM.tune.ffaCeiling)
        or Config.instances.ffaCeiling))
end

local function lingerMs()
    local seconds = DM.finite(DM.tune.emptyLingerSeconds)
    if seconds == nil then return Config.instances.emptyLingerMs end
    return math.max(0, math.floor(seconds * 1000))
end

local function keepOneWarm()
    local value = DM.tune.keepOneWarm
    if value == nil then return Config.instances.keepOneWarm == true end
    return value == true
end


-- --------------------------------------------------------- bucket ranges --

local function rangeFor(kind)
    if kind == "arena" then
        return Config.buckets.arenaFirst, Config.buckets.arenaLast
    end
    return Config.buckets.ffaFirst, Config.buckets.ffaLast
end

-- Population disabled and entity lockdown relaxed, per bucket, exactly as the
-- shipped mode did for its single arena bucket. Applied at allocation and again
-- on adoption, because a hot reload empties this VM's registry while the buckets
-- and the players inside them live on -- the same lazy-repopulation rule the
-- gamemode doc gives for players, applied to bucket state.
local function prepareBucket(bucket)
    SetRoutingBucketPopulationEnabled(bucket, false)
    SetRoutingBucketEntityLockdownMode(bucket, "relaxed")
end

-- The lobby is the one place with no combat, but it still wants the vanilla
-- crowd out of the way: a station prompt competing with pedestrian traffic is
-- the difference between "an invitation" and "scenery".
function Instances.prepareLobby()
    -- The shared Freeroam world retains its population and lockdown policy.
end

-- First-free from the range, with the owner tracked, so two instances can never
-- share one bucket. Linear over at most 48 entries and called once per instance
-- open; there is nothing to optimise here and a sparse scan is auditable.
local function allocateBucket(kind)
    local first, last = rangeFor(kind)
    for bucket = first, last do
        if bucketOwner[bucket] == nil then return bucket end
    end
    return nil
end

-- Which kind of instance, if any, owns this bucket number. Used by `adopt` to
-- tell an arena bucket from an FFA one without consulting the registry, which
-- after a hot reload is empty.
function Instances.kindOfBucket(bucket)
    bucket = tonumber(bucket)
    if bucket == nil then return nil end
    if bucket >= Config.buckets.ffaFirst and bucket <= Config.buckets.ffaLast then
        return "ffa"
    end
    if bucket >= Config.buckets.arenaFirst and bucket <= Config.buckets.arenaLast then
        return "arena"
    end
    if bucket == Config.buckets.lobby then return "lobby" end
    return nil
end


-- ------------------------------------------------------------- open/close --

-- Opens an instance and claims its bucket. Returns `instance` or `nil, reason`.
--
-- `format` is a key of `Config.formats`; `kind` is which bucket range it draws
-- from. FFA formats draw from the FFA range, everything queued from the arena
-- range, so a full arena ladder can never starve the drop-in mode of buckets.
function Instances.open(format)
    local spec = Config.formats[format]
    if spec == nil then return nil, "unknown_format" end
    local kind = (format == "ffa") and "ffa" or "arena"

    if openCount[kind] >= ceilingFor(kind) then
        return nil, "instances_full"
    end

    local bucket = allocateBucket(kind)
    if bucket == nil then return nil, "instances_full" end

    local id = nextInstanceId
    nextInstanceId = nextInstanceId + 1

    local instance = {
        id = id,
        kind = kind,
        format = format,
        label = spec.label,
        -- The zone key IS the format key: `Config.zones` is keyed by format
        -- and holds volume NAMES only. The boxes those names refer to live in
        -- shared/kabuki.lua, which is generated by `/dm.survey dump`; nothing
        -- in the kernel holds a coordinate.
        zone = format,
        bucket = bucket,
        capacity = (format == "ffa") and ffaCapacity() or (spec.capacity or 2),
        openedAtMs = DM.nowMs(),
        emptySinceMs = DM.nowMs(),
        members = {},        -- playerId -> true
        order = {},          -- arrival order; there is no way to list players
        memberCount = 0,
        -- THE PARTICIPANT SPACE, AND NOTHING ELSE. A bot's participant id is
        -- always NEGATIVE (`bots.lua` allocates from -1 downwards), so
        -- `#actors` is the number of bots this instance holds and every reader
        -- may count it as one. The body alias -- the same bot under its uint64
        -- npc id -- lives in `actorAliases` below precisely so that stays true.
        actors = {},         -- bot participantId (negative) -> true
        -- THE BODY SPACE. One entry per LIVING body, added by `bindActor` when
        -- it is handed a positive id and moved by `rebindNpc` on every respawn
        -- that builds a new body. It exists so the damage gate can resolve a
        -- shot that arrives under the npc id rather than the participant id --
        -- see `Instances.resolve` -- and it is a SEPARATE table because it used
        -- to share `actors` and made every count of that table twice the truth.
        actorAliases = {},   -- npc id (positive) -> true
        weaponIds = {},      -- attacker verification, per player, per round
        round = nil,         -- round.lua / arena.lua own this
        closed = false,

        -- Several rounds run at once now, which is precisely the case where
        -- `promote()` is wrong: it is per-RESOURCE, so promoting at instance
        -- B's creation would move instance A's finish line too. Capture the
        -- whole set here and let every rule inside this instance read the
        -- capture for its whole life.
        tune = Open77.tunables.capture(),
    }

    registry[id] = instance
    bucketOwner[bucket] = id
    openCount[kind] = openCount[kind] + 1
    prepareBucket(bucket)

    DM.log(("instance %d opened format=%s bucket=%d zone=%s capacity=%d (%s open: %d)"):format(
        id, format, bucket, tostring(instance.zone), instance.capacity,
        kind, openCount[kind]))
    return instance
end

-- Releases the bucket and forgets the instance. Members must already be gone;
-- any that are not are detached first and LOGGED, because closing an instance
-- with somebody still inside it means a caller skipped `detach` and that is a
-- bug worth seeing rather than papering over.
function Instances.close(instance, reason)
    if instance == nil or instance.closed then return false end
    if instance.memberCount > 0 then
        DM.log(("instance %d closed with %d member(s) still attached (%s) -- detaching"):format(
            instance.id, instance.memberCount, tostring(reason)))
        for _, playerId in ipairs(Instances.members(instance)) do
            Instances.detach(playerId, "instance_closed")
        end
    end
    for actorId in pairs(instance.actors) do actorIndex[actorId] = nil end
    for actorId in pairs(instance.actorAliases or {}) do actorIndex[actorId] = nil end

    instance.closed = true
    bucketOwner[instance.bucket] = nil
    registry[instance.id] = nil
    openCount[instance.kind] = math.max(0, openCount[instance.kind] - 1)

    DM.log(("instance %d closed bucket=%d released reason=%s (%s open: %d)"):format(
        instance.id, instance.bucket, tostring(reason),
        instance.kind, openCount[instance.kind]))
    if DM.onInstanceClosed ~= nil then DM.onInstanceClosed(instance, reason) end
    return true
end


-- --------------------------------------------------------------- roster --

function Instances.members(instance)
    local list = {}
    if instance == nil then return list end
    for _, playerId in ipairs(instance.order) do
        if instance.members[playerId] then list[#list + 1] = playerId end
    end
    return list
end


--- The members of an instance that are actual PLAYERS.
---
--- `members` returns participants, and a bot IS a participant: it holds a slot,
--- it scores, it appears in the standings. But every engine binding that takes a
--- player id rejects a bot's synthetic negative one -- and the rejection is not a
--- returned error, it RAISES, and the resource stops with `runtime_error`. The
--- first round this mode ever ran died that way, twice, five seconds in.
---
--- So a loop about to touch the ENGINE iterates this, and a loop about to touch
--- the SCOREBOARD iterates `members`. That distinction is the whole point, and
--- picking the wrong one is the bug.
function Instances.humans(instance)
    local out = {}
    for _, id in ipairs(Instances.members(instance)) do
        if type(id) == "number" and id > 0 then out[#out + 1] = id end
    end
    return out
end

function Instances.of(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end
    return playerIndex[playerId]
end

function Instances.ofActor(actorId)
    actorId = tonumber(actorId)
    if actorId == nil then return nil end
    return actorIndex[actorId]
end

-- Player first, then bot. An NPC id from `open77:playerDamaged` is a large
-- 64-bit value (12884901889 was measured on 2026-08-31) and a player id is a
-- small ordinal, so a collision is not expected -- but the order is explicit
-- rather than relying on that, because "not expected" is not "impossible" and
-- the failure mode is a cross-instance damage leak.
function Instances.resolve(actorId)
    return Instances.of(actorId) or Instances.ofActor(actorId)
end

function Instances.attach(instance, playerId)
    playerId = DM.playerId(playerId)
    if instance == nil or instance.closed or playerId == nil then return false end

    local current = playerIndex[playerId]
    if current == instance then return true end
    if current ~= nil then Instances.detach(playerId, "moved") end

    instance.members[playerId] = true
    instance.order[#instance.order + 1] = playerId
    instance.memberCount = instance.memberCount + 1
    instance.emptySinceMs = nil
    playerIndex[playerId] = instance

    if Config.debug.verboseInstances then
        DM.log(("instance %d attach player=%d (%d/%d)"):format(
            instance.id, playerId, instance.memberCount, instance.capacity))
    end
    return true
end

function Instances.detach(playerId, reason)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end
    local instance = playerIndex[playerId]
    if instance == nil then return nil end

    playerIndex[playerId] = nil
    if instance.members[playerId] then
        instance.members[playerId] = nil
        instance.memberCount = math.max(0, instance.memberCount - 1)
    end
    for index = #instance.order, 1, -1 do
        if instance.order[index] == playerId then table.remove(instance.order, index) end
    end
    instance.weaponIds[playerId] = nil

    if instance.memberCount == 0 and instance.emptySinceMs == nil then
        instance.emptySinceMs = DM.nowMs()
    end
    if Config.debug.verboseInstances then
        DM.log(("instance %d detach player=%d reason=%s (%d/%d)"):format(
            instance.id, playerId, tostring(reason),
            instance.memberCount, instance.capacity))
    end
    return instance
end

-- Bots. A bot is a participant with its own id, and binding it here is what
-- lets the damage gate treat bot fire exactly like player fire -- no special
-- case in the arbiter, which is where a special case would be most dangerous.
--- Which of an instance's two actor tables an id belongs in.
---
--- THE SIGN IS THE DISCRIMINATOR AND IT IS AN INVARIANT, not a guess:
--- `bots.lua` allocates participant ids from -1 downwards, and an npc id is a
--- positive uint64. Splitting on it here -- once, in the kernel -- is what lets
--- every reader of `instance.actors` count bots without knowing that a bot is
--- bound twice.
local function actorTable(instance, actorId)
    if actorId < 0 then return instance.actors end
    if instance.actorAliases == nil then instance.actorAliases = {} end
    return instance.actorAliases
end

function Instances.bindActor(actorId, instance)
    actorId = tonumber(actorId)
    if actorId == nil or instance == nil or instance.closed then return false end
    local current = actorIndex[actorId]
    if current ~= nil and current ~= instance then
        actorTable(current, actorId)[actorId] = nil
    end
    actorTable(instance, actorId)[actorId] = true
    actorIndex[actorId] = instance
    return true
end

function Instances.unbindActor(actorId)
    actorId = tonumber(actorId)
    if actorId == nil then return false end
    local instance = actorIndex[actorId]
    if instance ~= nil then actorTable(instance, actorId)[actorId] = nil end
    actorIndex[actorId] = nil
    return instance ~= nil
end

--- How many BOTS this instance holds. One number, one definition.
---
--- MEASURED IN GAME on 2026-09-01, in a 3v3 filled with exactly five bots:
--- `/dm.instances` printed `#1 3v3 b=4240 1/6+10bot`. Ten, in a format whose
--- capacity is six. Nothing had accumulated -- the NPC registry held five
--- bodies throughout, round 1 and round 2 alike -- the counter was simply
--- adding up a table that carries a participant AND a body alias per bot, so
--- every bot was worth two. `main.lua` had already been bitten by the same
--- table and worked around it locally; the kernel's own two readouts had not,
--- and a workaround in one file is how the next reader is misled.
---
--- The table now holds the participant space alone, so this is a straight
--- count -- but it stays a named function rather than an inline `pairs` walk,
--- because the last time this was inline it was wrong in two places at once.
function Instances.botCount(instance)
    if instance == nil or type(instance.actors) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(instance.actors) do count = count + 1 end
    return count
end


-- ------------------------------------------------------------ join policy --

-- The fullest instance that still has room. Decision 3, and the comment is the
-- justification: fill up, do not spread out. A dead lobby is worse than a busy
-- one, and a 2/12 instance IS a dead lobby -- two of them are worse than one
-- 4/12. Ties break on the lowest id so the choice is deterministic and a test
-- can assert it.
function Instances.fullestWithRoom(format)
    local capacity = (format == "ffa") and ffaCapacity()
        or ((Config.formats[format] or {}).capacity or 2)
    local best, bestCount = nil, -1
    for _, instance in pairs(registry) do
        if not instance.closed and instance.format == format
            and instance.memberCount < capacity then
            if instance.memberCount > bestCount
                or (instance.memberCount == bestCount and best ~= nil and instance.id < best.id) then
                best, bestCount = instance, instance.memberCount
            end
        end
    end
    return best
end

-- The answer to "no waiting".
--
-- Returns `instance` or `nil, "instances_full"`. The refusal is a SERVER
-- CAPACITY condition, not a matchmaking one -- decision 2 says free-for-all
-- never queues, and the only refusal it ever produces is "every instance is
-- full". Tell the player exactly that; do not invent a queue to soften it.
function Instances.assignFFA(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil, "bad_player_id" end

    -- Already inside one? Then this is a re-entry (a hot reload, a rejoin, a
    -- second station press) and the answer is the instance they are in.
    local existing = playerIndex[playerId]
    if existing ~= nil and not existing.closed and existing.format == "ffa" then
        return existing, "already_assigned"
    end

    -- 1. Fullest instance that still has room.
    local target = Instances.fullestWithRoom("ffa")

    -- 2. Nothing with room -> open a new instance, if the ceiling allows.
    if target == nil then
        local opened, reason = Instances.open("ffa")
        if opened == nil then
            rejections.instances_full = rejections.instances_full + 1
            return nil, reason or "instances_full"
        end
        target = opened
    end

    -- 3. Capacity is re-checked here and not only in step 1, because the
    --    tunable can have moved between the two and a capacity that shrank
    --    under a live instance must refuse rather than overfill.
    if target.memberCount >= target.capacity then
        rejections.instances_full = rejections.instances_full + 1
        return nil, "instances_full"
    end

    Instances.attach(target, playerId)
    return target
end

-- Allocates a whole arena match at once. Arena is a MATCH, not a place: the
-- roster is known before the instance exists, so there is no fill policy and no
-- partial state to reason about.
function Instances.openArena(format, roster)
    local spec = Config.formats[format]
    if spec == nil or not spec.queued then return nil, "unknown_format" end
    if #roster > (spec.capacity or 2) then return nil, "roster_too_large" end

    local instance, reason = Instances.open(format)
    if instance == nil then return nil, reason end
    for _, playerId in ipairs(roster) do Instances.attach(instance, playerId) end
    return instance
end


-- ------------------------------------------------ adoption after a reload --

-- A hot reload empties this VM's registries while the players, the buckets and
-- any bots live on. The lab paid for this lesson on 2026-08-31: it lost track of
-- its own NPCs after an edit and reported "no npcs" with two standing in front
-- of the player.
--
-- There is no way to list players, so re-adoption is LAZY: the next event any
-- player produces reaches `ensurePlayer`, which calls this, which reads the
-- player's authoritative bucket and puts them back in an instance for it.
--
-- Returns the instance, or nil when the player is not in an instance bucket --
-- which the caller should read as "put them in the lobby", not as an error.
function Instances.adopt(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end
    if not Config.instances.adoptOnReload then return playerIndex[playerId] end

    local existing = playerIndex[playerId]
    if existing ~= nil and not existing.closed then return existing end

    local position = Open77.players.position(playerId)
    if position == nil then return nil end
    local bucket = tonumber(position.bucket)
    if bucket == nil then return nil end

    local kind = Instances.kindOfBucket(bucket)
    if kind ~= "ffa" and kind ~= "arena" then return nil end

    local ownerId = bucketOwner[bucket]
    local instance = ownerId and registry[ownerId] or nil
    if instance == nil then
        -- The bucket is occupied by a player but owned by nobody: this VM is
        -- younger than the fight. Rebuild an instance around the bucket rather
        -- than allocating a fresh one, so the players standing in it stay
        -- together and the bucket is not handed out twice.
        instance = Instances.adoptBucket(bucket, kind)
        if instance == nil then return nil end
    end

    Instances.attach(instance, playerId)
    DM.log(("instance %d adopted player=%d from bucket=%d after reload"):format(
        instance.id, playerId, bucket))
    return instance
end

-- Rebuilds an instance record around a bucket that is already in use. The
-- format cannot be recovered from a bucket number alone -- only the kind can --
-- so an adopted arena bucket comes back as an arena instance with no format and
-- arena.lua resolves it or closes it. FFA has one format, so it is recovered
-- exactly.
function Instances.adoptBucket(bucket, kind)
    bucket = tonumber(bucket)
    if bucket == nil or bucketOwner[bucket] ~= nil then return nil end

    local format = (kind == "ffa") and "ffa" or nil
    local spec = format and Config.formats[format] or nil
    local id = nextInstanceId
    nextInstanceId = nextInstanceId + 1

    local instance = {
        id = id,
        kind = kind,
        format = format,
        label = spec and spec.label or "Arena",
        zone = format or "ffa",
        bucket = bucket,
        capacity = (format == "ffa") and ffaCapacity() or 6,
        openedAtMs = DM.nowMs(),
        emptySinceMs = DM.nowMs(),
        members = {}, order = {}, memberCount = 0,
        actors = {}, actorAliases = {}, weaponIds = {},
        round = nil,
        closed = false,
        adopted = true,
        tune = Open77.tunables.capture(),
    }

    registry[id] = instance
    bucketOwner[bucket] = id
    openCount[kind] = openCount[kind] + 1
    prepareBucket(bucket)

    DM.log(("instance %d ADOPTED bucket=%d kind=%s -- rebuilt after a reload, round state is lost"):format(
        id, bucket, kind))
    return instance
end


-- ------------------------------------------------------------------ reap --

-- An instance that reaches zero players is NOT torn down immediately. A player
-- crossing between rounds, or a single reconnect, would otherwise churn the
-- bucket. It lingers for `emptyLingerMs` (default 60 s), then releases.
--
-- Called from the mode tick; it does its own arithmetic and is cheap enough to
-- call at any rate.
function Instances.reap(now)
    now = now or DM.nowMs()
    local linger = lingerMs()
    local warm = keepOneWarm()

    local doomed = nil
    for _, instance in pairs(registry) do
        if not instance.closed then
            if instance.memberCount > 0 then
                instance.emptySinceMs = nil
            else
                instance.emptySinceMs = instance.emptySinceMs or now
                if now - instance.emptySinceMs >= linger then
                    -- Keep the last FFA instance warm, if asked. Note the plan's
                    -- original reason for this ("so the first joiner never waits
                    -- on a wall build") died with E2: there is no wall to build,
                    -- so the default is off and this is now only about leaving a
                    -- bucket's population and lockdown state settled.
                    local last = warm and instance.format == "ffa"
                        and openCount.ffa <= 1
                    if not last then
                        doomed = doomed or {}
                        doomed[#doomed + 1] = instance
                    end
                end
            end
        end
    end

    -- Closing mutates `registry`, so it happens outside the iteration.
    if doomed ~= nil then
        for _, instance in ipairs(doomed) do
            Instances.close(instance, "reaped_after_linger")
        end
    end
end


-- ==================================================== the damage arbiter ---
--
-- THE ONE THAT MATTERS.
--
-- `Open77.combat.onDamage` is HOST-GLOBAL and fires for every damage candidate
-- on the server, not for one instance. The plan calls a cross-instance damage
-- leak the worst bug this design can produce, and it is a NEW failure mode:
-- with a single global `match` it could not exist, so nothing in the shipped
-- code guards against it.
--
-- The rule is one line long and admits no exception: resolve BOTH parties'
-- instances and reject any pair that does not share one.
--
-- Returns `allowed, reason, instance`. `instance` is the shared instance when
-- the pair is legitimate, so the caller can go straight on to the weapon
-- verification without resolving it a second time.
local function noteRejection(reason, attackerId, victimId)
    rejections[reason] = (rejections[reason] or 0) + 1
    local key = reason .. ":" .. tostring(attackerId) .. ":" .. tostring(victimId)
    local at = DM.nowMs()
    local last = lastRejectionLogMs[key]
    if last ~= nil and at - last < (Config.debug.logEveryMs or 5000) then return end
    lastRejectionLogMs[key] = at
    -- Cross-instance is logged at every rate-limited opportunity even when
    -- verbose damage logging is off: it is the failure this file exists to
    -- prevent and a silent one would be indistinguishable from correctness.
    if reason == "cross_instance" or Config.debug.verboseDamage then
        DM.log(("damage refused reason=%s attacker=%s victim=%s (total %d)"):format(
            reason, tostring(attackerId), tostring(victimId), rejections[reason]))
    end
end

function Instances.damageGate(event)
    local victimId = DM.playerId(event and event.victim)
    local attackerId = tonumber(event and event.attacker) or 0

    if victimId == nil then return false, "bad_victim" end

    local victimInstance = playerIndex[victimId]
    if victimInstance == nil or victimInstance.closed then
        noteRejection("victim_not_in_instance", attackerId, victimId)
        return false, "victim_not_in_instance"
    end

    -- Environment, fall damage, scripted placement damage: no attacker to
    -- resolve, and the victim's own instance decides what to do with it.
    if attackerId == 0 then
        return true, "environment", victimInstance
    end

    -- Self-damage is not a cross-instance question.
    if attackerId == victimId then
        return true, "self", victimInstance
    end

    local attackerInstance = Instances.resolve(attackerId)
    if attackerInstance == nil or attackerInstance.closed then
        noteRejection("attacker_not_in_instance", attackerId, victimId)
        return false, "attacker_not_in_instance"
    end

    if attackerInstance ~= victimInstance then
        noteRejection("cross_instance", attackerId, victimId)
        return false, "cross_instance"
    end

    return true, "same_instance", victimInstance
end

-- Publishes the same verdict without an event, for tests, for `/dm.where` and
-- for anything that wants to ask "could A shoot B?" without waiting for a shot.
function Instances.sharesInstance(a, b)
    local left = Instances.resolve(a)
    if left == nil then return false end
    return left == Instances.resolve(b)
end


-- ------------------------------------------------------------- readouts --

-- Live numbers for the entry station card. A station that cannot tell you
-- whether anyone is playing is a sign, not an invitation.
function Instances.summary()
    local out = {
        ffaInstances = 0, ffaPlayers = 0, ffaBots = 0,
        arenaInstances = 0, arenaPlayers = 0,
        capacity = ffaCapacity(),
        ceiling = ceilingFor("ffa"),
        target = nil, targetCount = nil,
    }
    for _, instance in pairs(registry) do
        if not instance.closed then
            if instance.format == "ffa" then
                out.ffaInstances = out.ffaInstances + 1
                out.ffaPlayers = out.ffaPlayers + instance.memberCount
                out.ffaBots = out.ffaBots + Instances.botCount(instance)
            else
                out.arenaInstances = out.arenaInstances + 1
                out.arenaPlayers = out.arenaPlayers + instance.memberCount
            end
        end
    end
    local target = Instances.fullestWithRoom("ffa")
    if target ~= nil then
        out.target = target.id
        out.targetCount = target.memberCount
    end
    return out
end

function Instances.describe()
    local parts = {}
    local ids = {}
    for id in pairs(registry) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local instance = registry[id]
        local bots = Instances.botCount(instance)
        parts[#parts + 1] = ("#%d %s b=%d %d/%d%s%s"):format(
            instance.id, tostring(instance.format), instance.bucket,
            instance.memberCount, instance.capacity,
            bots > 0 and ("+%dbot"):format(bots) or "",
            instance.emptySinceMs and (" empty %.0fs"):format(
                (DM.nowMs() - instance.emptySinceMs) / 1000) or "")
    end
    if #parts == 0 then return "no instances open" end
    return table.concat(parts, "  ")
end


-- ------------------------------------------------------------- commands --

local function output(source, raw, ok, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

-- The `<mode>.where` habit from writing-a-gamemode.md section 6, applied to the
-- instance registry: print what the server believes, so an instancing surprise
-- can be read rather than guessed at. `/dm.where` itself belongs to survey.lua
-- and answers the geometry question; this one answers the routing question.
RegisterCommand("dm.instances", function(source, args, raw)
    output(source, raw, true, ("instances -- ffa %d/%d open, arena %d/%d open, capacity %d"):format(
        openCount.ffa, ceilingFor("ffa"), openCount.arena, ceilingFor("arena"),
        ffaCapacity()))
    output(source, raw, true, "  " .. Instances.describe())
    output(source, raw, true, ("  refusals: cross_instance=%d victim_not_in_instance=%d attacker_not_in_instance=%d instances_full=%d"):format(
        rejections.cross_instance, rejections.victim_not_in_instance,
        rejections.attacker_not_in_instance, rejections.instances_full))

    local playerId = DM.playerId(args and args[1]) or DM.playerId(source)
    if playerId ~= nil then
        local instance = playerIndex[playerId]
        local position = Open77.players.position(playerId)
        output(source, raw, true, ("  player %d instance=%s bucket(server)=%s bucket(live)=%s"):format(
            playerId,
            instance and tostring(instance.id) or "none",
            instance and tostring(instance.bucket) or "-",
            position and tostring(position.bucket) or "unreadable"))
    end
end, false)


-- --------------------------------------------------------------- startup --

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    Instances.prepareLobby()
    DM.log(("instance kernel ready -- lobby=%d, ffa %d-%d (ceiling %d, capacity %d), arena %d-%d (ceiling %d), linger %.0fs"):format(
        Config.buckets.lobby,
        Config.buckets.ffaFirst, Config.buckets.ffaLast,
        ceilingFor("ffa"), ffaCapacity(),
        Config.buckets.arenaFirst, Config.buckets.arenaLast,
        ceilingFor("arena"), lingerMs() / 1000))

    -- The bucket ranges must not overlap each other or the lobby. Getting this
    -- wrong puts two instances in one world with no symptom until somebody
    -- shoots across a boundary that does not exist -- exactly the failure the
    -- damage gate above exists to catch, arriving through the front door.
    local lobby = Config.buckets.lobby
    if Config.buckets.ffaFirst <= Config.buckets.arenaLast
        and Config.buckets.arenaFirst <= Config.buckets.ffaLast then
        DM.log("BUCKETS WARNING -- the ffa and arena ranges OVERLAP; two instances can share a world")
    end
    if (lobby >= Config.buckets.ffaFirst and lobby <= Config.buckets.ffaLast)
        or (lobby >= Config.buckets.arenaFirst and lobby <= Config.buckets.arenaLast) then
        DM.log("BUCKETS WARNING -- the lobby bucket falls inside an instance range")
    end
end)
