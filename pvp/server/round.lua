-- Kabuki Arena -- the free-for-all round loop, one per instance.
--
-- FREE-FOR-ALL IS A PLACE, NOT A MATCH. Everything in this file follows from
-- that one sentence and nothing in it should be read as a smaller version of
-- the old `match` state machine:
--
--   * it never queues and it has no countdown gate. A joiner is placed into a
--     LIVE round, mid-fight, alive and armed;
--   * a round ends on a timer or a kill limit, shows standings for a few
--     seconds, and then the NEXT round starts with the same players still
--     standing in the same instance, with the equalizer weapon rotated;
--   * nobody is ever ejected to the lobby between rounds. The instance
--     outlives every round it runs. `instance.round` is replaced; the instance
--     is not.
--
-- The old `match` upvalue is exactly the bug this file removes: several
-- instances run at once, so every deadline and every timer lives ON THE
-- INSTANCE (`instance.round`), never at module scope. The two module-scope
-- tables left are per-PLAYER facts that no instance can own -- the refusal card
-- a joiner was last shown, and the spawn-protection deadline, which has to
-- survive the placement that crosses the lobby/instance boundary. Both are
-- keyed by player id, repopulated lazily, and cleared by `Deathmatch.forget`.
--
--
-- WHAT THIS FILE DOES NOT OWN, AND THE LINE IS SHARP
--
--   * THE SCORE IS scoring.lua's. Every kill, death, assist, bonus, streak and
--     standings row lives on `instance.scoreboard` and nothing here keeps a
--     second copy. Two counters that can disagree is the same defect as two
--     containment tests: it surfaces as a scoreboard that does not match the
--     round that just ended. Of the score, this file reads exactly one number
--     -- the killer's kill count, because the KILL LIMIT is a round rule --
--     and it reads it back from scoring rather than tallying it.
--
--     The wiring follows from that: scoring.lua registers `open77:playerKilled`
--     and `open77:playerDied` ITSELF, scores the death, and then hands it to
--     the handler registered at the bottom of this file. So a counted death
--     arrives here already suppressed (placements), already debounced (one
--     death, two events) and already credited. Nothing here re-guards it, and
--     nothing here calls `Scoring.credit` -- that would be this file scoring
--     the death scoring.lua just handed it.
--
--   * THE LOADOUT IS loadout.lua's. Which slots, which records, which reserve,
--     the assign handshake and the TweakDBID verification. What this file owns
--     is WHEN: the rotation is advanced once per round, here, because "one
--     weapon per round for everyone" is a round rule.
--
--   * PLACEMENT IS main.lua's. Every move in the mode is one
--     `kill -> respawn` primitive, and there is exactly one of them.
--
-- This file publishes the small set of seams both round loops need
-- (`Deathmatch.place`, `Deathmatch.equip`, `Deathmatch.fragmentFor`,
-- `Deathmatch.leave`). They live here rather than in arena.lua because
-- round.lua loads first; arena.lua reads them at call time, so load order is
-- the only ordering constraint between the two.
--
--
-- ===========================================================================
-- ===  CHANGES server/main.lua AND open77.lua NEED.  APPLY THESE BY HAND. ===
-- ===========================================================================
--
-- Anchored search/replace rather than line numbers, in the same style as
-- instances.lua's M1-M10 and for the same reason: main.lua is being rewritten
-- in parallel and line numbers will have moved. Numbered R1-R12 so they can be
-- applied alongside M1-M10 (instances.lua) and L1-L3 / S1-S6 (loadout.lua,
-- scoring.lua) without any list renumbering another. THEY ASSUME M1-M10, L1-L3
-- AND S1-S6 ARE ALSO APPLIED.
--
-- --- R1. The manifest. ALREADY DONE -- do not reorder it. ----------------
--
-- `resources/gamemodes/open77_deathmatch/open77.lua` now lists all nine server scripts,
-- and LOAD ORDER IS MANIFEST ORDER. The shipped order is:
--
--     instances, bounds, loadout, scoring, bots, round, arena, survey, main
--
-- which satisfies everything these two files need and is not the order this
-- entry originally asked for. It is the better one, so it stays: round.lua
-- registers its death handler with `Deathmatch.scoring` AT LOAD, so scoring.lua
-- has to come first, and only the `onResourceStart` re-registration would have
-- rescued the other order. arena.lua after round.lua is the one constraint that
-- is genuinely required, because arena.lua reads the seams this file publishes.
-- Everything else between them resolves at call time.
--
-- --- R2. main.lua registers its placement primitives, once. ---------------
--
-- bounds.lua decides and main.lua places (M7); the same division holds here.
-- Nothing in round.lua or arena.lua ever calls `Open77.players.kill` or
-- `respawn`. Near the bottom of main.lua, beside the M7 block:
--
--   + Deathmatch.setPlacement(placeInArena, sendToLobby)
--
-- `placeInArena` GAINS A FIFTH PARAMETER, and it is not optional for the arena:
--
--   -  local function placeInArena(playerId, activeMatch, reason, graceMs)
--   -      local spawn, minimumSeparation = spawnFor(activeMatch, playerId)
--   +  local function placeInArena(playerId, instance, reason, graceMs, mark)
--   +      -- An explicit mark is used VERBATIM. arena.lua passes the surveyed
--   +      -- team mark for the player's side, and a maximin choice over the
--   +      -- free-for-all marks would put a duellist outside the carved 1v1
--   +      -- zone -- where the bounds backstop would then "correct" them by
--   +      -- killing them. Free-for-all passes nothing and keeps maximin.
--   +      local spawn, minimumSeparation = mark, nil
--   +      if spawn == nil then spawn, minimumSeparation = spawnFor(instance, playerId) end
--   +      if spawn == nil or DeathmatchKabuki.point(spawn.position) == nil then
--   +          return false, "not_surveyed"
--   +      end
--
-- and its body reads `instance.bucket` rather than `Config.arena.bucket` (M2)
-- and `Config.placement.spawnLiftMetres` rather than
-- `Config.arena.spawnLiftMetres`. `spawnFor` reads `DeathmatchKabuki.spawns.ffa`
-- instead of `Config.arena.spawns` and SKIPS entries whose `position` is still
-- nil: an unsurveyed mark is not a coordinate and must never be placed onto.
--
-- Both primitives return `ok` and may return a second `detail` string.
--
-- --- R3. main.lua registers NOTHING for the loadout. ----------------------
--
-- This entry used to hand main.lua's `equipWeapon` and `stripWeapons` to
-- `Deathmatch.setLoadout`. loadout.lua has landed and publishes
-- `Deathmatch.loadout.equip/strip/resupply`; the seam below prefers it, at call
-- time, over anything main.lua registers, and L1 deletes the two functions
-- outright. So `setLoadout` survives only as a fallback for a resource set
-- built without loadout.lua. DO NOT WIRE IT.
--
-- --- R4. Every placement tells the ledger not to count its death. ---------
--
-- `placeAt` moves a player with `kill -> respawn`, so without a suppression
-- window every arena entry, every respawn and every bounds backstop scores as a
-- death:
--
--   -    suppressDeathUntil[playerId] = nowMs() + 2500
--   +    Deathmatch.scoring.suppressDeath(playerId, 2500)
--
-- ONE call, not two. This entry originally asked for a second window belonging
-- to round.lua; the ruling that scoring.lua owns the score settled that -- there
-- is one suppression window and one death ledger in this mode.
-- `Deathmatch.suppressDeath` still exists and still works, but it now FORWARDS
-- into `Deathmatch.scoring.suppressDeath`, so a main.lua calling both simply
-- writes the same deadline twice. Drop the `Deathmatch.suppressDeath` line when
-- main.lua is next touched.
--
-- --- R5. Free-for-all entry calls the round, not a queue. -----------------
--
-- `joinRequest` loses the whole queue path. Decision 2: there is nothing to
-- wait for, so there is nothing to enrol in.
--
--   local function joinRequest(playerId)
--       local record = ensurePlayer(playerId)
--       if record == nil then return end
--   -    if not Open77.ready.isReady(playerId) then ... end
--   -    if queueContains(playerId) then ... end
--   -    addToQueue(playerId)
--   -    ...
--   +    Deathmatch.round.join(playerId)     -- readiness, capacity and the
--   +                                        -- refusal card are all its job
--       broadcastState()
--   end
--
-- `deathmatch:stationEnter` routes here too. The arena station is a different
-- event and a different entry point -- see R6.
--
-- --- R6. The arena queue and the buy window get their net events. ---------
--
--   + RegisterNetEvent("deathmatch:queue", function(size)
--   +     Deathmatch.arena.enqueue(source, size)
--   +     broadcastState()
--   + end)
--   + RegisterNetEvent("deathmatch:kit", function(key)
--   +     Deathmatch.arena.pickKit(source, key)
--   + end)
--
-- `deathmatch:stationQueue` opens the panel; the panel sends `deathmatch:queue`.
-- `pickKit` is a GATE, not a writer: the buy window is a round phase and only
-- the round knows whether it is open, so arena.lua checks the phase and then
-- hands the choice to `Deathmatch.loadout.chooseKit`, which validates the key
-- against the shipped list. loadout.lua also registers `deathmatch:pickKit` for
-- the same act, so this handler is optional -- keep whichever event the HUD
-- actually sends and delete the other.
--
-- --- R7. Leaving dispatches. ----------------------------------------------
--
-- `deathmatch:leave` and the `deathmatch.leave` command lose `removeParticipant`,
-- `removeFromQueue` and the whole `scope` dance:
--
--   -    removeFromQueue(playerId)
--   -    removeParticipant(playerId, "player_left", true)
--   -    notice(playerId, "warning", "MATCH QUITTE", ...)
--   +    Deathmatch.leave(playerId, scope)
--
-- It handles all three cases -- an arena queue entry, a free-for-all instance,
-- an arena match -- and answers "the player is in none of them" by doing
-- nothing. `removeParticipant`, `queuePosition`, `queueContains`, `addToQueue`,
-- `removeFromQueue` and the `queue` table all go with M10.
--
-- --- R8. Death, and disconnect. -------------------------------------------
--
-- THIS ENTRY SHRANK WHEN scoring.lua LANDED, and the shrinking is the point.
-- scoring.lua registers `open77:playerKilled` and `open77:playerDied` ITSELF,
-- scores the death, and then hands it to the handler round.lua registers at
-- load. So the round rule -- the respawn timer, the kill limit, the arena
-- elimination -- arrives by the same path that scored it, once, and there is
-- nothing in main.lua to wire.
--
-- S1 therefore DELETES both handlers from main.lua. If they are kept anyway,
-- keep them in exactly this shape:
--
--    AddEventHandler("open77:playerKilled", function(victimId, killerId)
--   -    countDeath(tonumber(victimId) or 0, tonumber(killerId) or 0, "player")
--   +    Deathmatch.onDeath(victimId, killerId, "player")
--    end)
--
-- `Deathmatch.onDeath` does NOT run the round rule directly: it forwards into
-- `Scoring.credit`, the same door bots.lua uses, so whichever of the two
-- describers arrives first counts and the second is dropped inside the
-- `countDeath` debounce. Ids are handed over RAW -- it normalises them itself,
-- because they arrive as strings and a `tonumber` at only one of two call sites
-- is how two tables silently diverge.
--
-- And in `onPlayerDisconnected`, beside the M8 lines and BEFORE
-- `Deathmatch.instances.detach`:
--
--   +    Deathmatch.forget(playerId)
--
-- The ordering is load-bearing: after a detach there is no way to tell which
-- arena side just lost a body, and the forfeit rule needs to know.
--
-- --- R9. The tick calls both loops. ---------------------------------------
--
-- Beside the M6 and L3 lines, in this order -- the kernel reaps first so a
-- round never steps an instance that is about to be closed:
--
--        local at = nowMs()
--        Deathmatch.instances.reap(at)
--        Deathmatch.bounds.tick(at)
--        Deathmatch.loadout.sweep(at)
--   +    Deathmatch.round.tick(at)
--   +    Deathmatch.arena.tick(at)
--
-- and DELETE the whole `if match ~= nil then ... else maybeFormMatch() end`
-- block above it.
--
-- --- R10. The state push merges a fragment. -------------------------------
--
-- `stateFor` keeps the record-shaped part it owns and takes everything about
-- the fight from one call. `Deathmatch.fragmentFor` dispatches on the player's
-- instance -- free-for-all, arena, or lobby -- so main.lua never learns which
-- mode a player is in:
--
--    local function stateFor(playerId)
--        local record = players[playerId]
--        local payload = {
--            playerId = playerId,
--   -        phase = match and match.state or "waiting",
--   -        playerState = record and record.state or "lobby",
--   -        queuePosition = ..., queueCount = ..., minimumPlayers = ...,
--   -        lobbyRadius = ..., participantCount = ..., participant = ...,
--   -        queuedNext = ..., canJoin = ..., canLeaveMatch = ...,
--        }
--   +    for key, value in pairs(Deathmatch.fragmentFor(playerId)) do
--   +        payload[key] = value
--   +    end
--        ...
--    end
--
-- THE FRAGMENT IS AUTHORITATIVE FOR `phase` AND `playerState`. Do not fall back
-- to `record.state` behind it: a player eliminated in an arena round and a
-- player waiting out a free-for-all respawn are different states main.lua has
-- no way to tell apart, and `record.state` is the stale copy. `phase` for a
-- player in no instance is `"lobby"` -- never `"waiting"`, which is the word a
-- client reads as "draw a waiting room".
--
-- The `match.state == "countdown"` / `"active"` / `"resolved"` branch below it
-- goes with the fragment, and so does `Config.match.statePushMs` ->
-- `Config.round.statePushMs`.
--
-- --- R11. Standings come from the one scoreboard. -------------------------
--
-- Nothing to do beyond S1, which already replaces `sortedRows`:
--
--   -    rows = sortedRows(match),
--   +    rows = Deathmatch.scoring.rows(Deathmatch.instances.of(playerId))
--
-- This entry originally asked for `sortedRows(instance)` reading an
-- `instance.stats` table these two files maintained. That table is gone: there
-- is ONE scoreboard, on `instance.scoreboard`, and scoring.lua owns it. What
-- the round keeps of the score is the kill count the kill LIMIT is measured on,
-- and it reads that back from scoring rather than tallying it in parallel.
--
-- --- R12. Ready and re-ready adopt rather than evict. ---------------------
--
-- `deathmatch:ready` re-primes a participant by pushing them into
-- `Config.arena.bucket`. With M4 in place `ensurePlayer` has already adopted
-- them, so the branch collapses:
--
--   -    if isParticipant(playerId) then
--   -        local position = Open77.players.position(playerId)
--   -        if position ~= nil and position.bucket ~= Config.arena.bucket then
--   -            SetPlayerRoutingBucket(playerId, Config.arena.bucket)
--   -        end
--   -        pushState(playerId)
--   -        return
--   -    end
--   +    if Deathmatch.instances.of(playerId) ~= nil then
--   +        pushState(playerId)
--   +        return
--   +    end
--
-- --- R13. Spawn protection breaks on aggression. --------------------------
--
-- Nothing to wire, and that is the better answer. S6 offers
-- `Deathmatch.scoring.setAggressionHandler`, and this file registers
-- `Deathmatch.breakProtection` with it at load, so a player's own CREDITED
-- outgoing damage drops their shield. Credited is the honest moment: an
-- unverified or cross-instance report is noise, not aggression, and dropping a
-- shield on it would make the shield unreliable in exactly the situation it
-- exists for.
--
-- A main.lua that registers the same handler itself is harmless --
-- `breakProtection` is idempotent and both registrations call it -- but it is
-- one more place to keep in step, so prefer letting this file own it.
--
-- --- R14. What main.lua may now delete. -----------------------------------
--
-- Beyond M10's, L1's and S1's lists, and all of it because this file or
-- arena.lua owns it:
--
--   `nextMatchId`, `allocateMatchId`, `capturedRules`, `chooseWinner`,
--   `resolveMatch`, `finishResolution`, `removeParticipant`, `scheduleRespawn`,
--   `participantCount`, `isParticipant`, the `Config.match.resultSeconds`
--   reads, and the `deathmatch.status` command's `minimumPlayers()` / `#queue`
--   / `match.weapon` readout -- `Deathmatch.instances.describe()`,
--   `/dm.rounds` and `/dm.arena` say the same thing about every instance
--   instead of about the one global there used to be.
--
-- `Open77.tunables.promote()` goes too, and this is the subtle one: it is
-- per-RESOURCE, so promoting when instance B starts a round would move
-- instance A's finish line. The kernel captures the whole set onto each
-- instance at open and every rule here reads `instance.tune`.
-- ===========================================================================


Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig

DM.round = DM.round or {}
local Round = DM.round


-- ================================================================== seams --
--
-- Placement is main.lua's and the loadout is loadout.lua's. Both are resolved
-- AT CALL TIME rather than captured at load, for the reason bots.lua gives for
-- the same pattern: a hot reload rebuilds `Deathmatch`, and a reference
-- captured at load points at the dead generation.

local placement = { into = nil, lobby = nil }
local fallbackLoadout = { equip = nil, strip = nil, resupply = nil }
local missing = {}

-- Says a missing seam once. A seam that is never registered is a wiring
-- mistake, and a wiring mistake that logs every tick is indistinguishable from
-- noise.
local function needs(name)
    if missing[name] then return end
    missing[name] = true
    DM.log(("seam '%s' is not registered -- see the R-block at the top of round.lua"):format(name))
end

--- `into(playerId, instance, reason, graceMs, mark) -> ok[, detail]`
--- `lobby(playerId, reason) -> ok[, detail]`
function DM.setPlacement(into, lobby)
    placement.into = type(into) == "function" and into or nil
    placement.lobby = type(lobby) == "function" and lobby or nil
end

--- Places a player inside an instance. `mark` is a surveyed
--- `{ position = , heading = }`; nil asks the placer for its own choice, which
--- for free-for-all is the maximin pick over the fourteen surveyed marks.
function DM.place(playerId, instance, reason, graceMs, mark)
    if placement.into == nil then
        needs("placement.into")
        return false, "no_placer"
    end
    return placement.into(playerId, instance, reason, graceMs, mark)
end

function DM.sendToLobby(playerId, reason)
    if placement.lobby == nil then
        needs("placement.lobby")
        return false, "no_placer"
    end
    return placement.lobby(playerId, reason)
end

--- Fallback only, for a resource set built without loadout.lua. With L1 applied
--- there is nothing in main.lua left to register here (R3).
function DM.setLoadout(equip, strip, resupply)
    fallbackLoadout.equip = type(equip) == "function" and equip or nil
    fallbackLoadout.strip = type(strip) == "function" and strip or nil
    fallbackLoadout.resupply = type(resupply) == "function" and resupply or nil
end

local function loadoutCall(name, ...)
    local published = DM.loadout
    if type(published) == "table" and type(published[name]) == "function" then
        return published[name](...)
    end
    if fallbackLoadout[name] ~= nil then return fallbackLoadout[name](...) end
    needs("loadout." .. name)
    return nil
end

--- WHAT to issue is loadout.lua's -- it resolves the plan from the instance's
--- format, so the equalizer and the kit are one code path and neither this file
--- nor arena.lua carries a second copy of the slot list. WHEN to issue it is
--- the round's, which is why the call is here at all.
function DM.equip(playerId, instance) return loadoutCall("equip", playerId, instance) end
function DM.strip(playerId, instance) return loadoutCall("strip", playerId, instance) end
function DM.resupply(playerId, instance) return loadoutCall("resupply", playerId, instance) end

--- Teams. Free-for-all is `setTeam(id, 0)` and the arena is `setTeam(id, side)`;
--- both go through here so a player who leaves a match can never carry a team
--- into a free-for-all and become quietly unshootable. The scoreboard is told
--- separately, so the HUD can colour a name without a second lookup.
function DM.setTeam(playerId, team, instance)
    team = math.floor(tonumber(team) or 0)
    local scoring = DM.scoring
    if type(scoring) == "table" and type(scoring.setTeam) == "function"
        and instance ~= nil then
        -- The SCOREBOARD still learns a bot's team: it is a participant and its
        -- row is drawn with everyone else's.
        scoring.setTeam(instance, playerId, team)
    end
    -- The COMBAT POLICY does not. Open77.combat.setTeam refuses a negative id
    -- and takes the resource down with it; a bot's friendly-fire relationships
    -- are bots.lua's business, through the npc id the engine actually knows.
    if type(playerId) == "number" and playerId <= 0 then return true end
    local combat = Open77.combat
    if combat == nil or type(combat.setTeam) ~= "function" then return false end
    return combat.setTeam(playerId, team) == true
end


-- ====================================================== per-player ledgers --
--
-- Two tables no instance can own, because both must survive a player crossing
-- the lobby/instance boundary and both answer questions asked before the
-- player is in an instance at all. Keyed by player id, repopulated lazily,
-- cleared by `DM.forget` on disconnect.
--
-- Note what is NOT here: death suppression and the double-report debounce.
-- scoring.lua owns both, in one table, because it is the file that decides
-- whether a death happened at all.

local refusals = {}            -- playerId -> the last refusal card shown to a joiner
local protectionUntilMs = {}   -- playerId -> spawn protection deadline

--- Spawn protection. The mechanism already exists and is invisible: `graceMs`
--- on the respawn holds the player in `Recovering`, which retains temporary
--- protection until the client acknowledges the end of its grace period.
--- Invulnerability the player cannot see is indistinguishable from a
--- hit-registration bug, so the deadline is remembered here and pushed to the
--- HUD.
function DM.holdProtection(playerId, durationMs)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    durationMs = math.max(0, math.floor(tonumber(durationMs) or 0))
    if durationMs == 0 then
        protectionUntilMs[playerId] = nil
        return
    end
    protectionUntilMs[playerId] = DM.nowMs() + durationMs
    if Config.spawnProtection.showOnHud then
        DM.notice(playerId, "info", "protectionOn", math.floor(durationMs / 1000 + 0.5))
    end
end

--- Registered with `Scoring.setAggressionHandler` (R13): shooting from inside a
--- shield is the classic abuse, so the shield drops the moment the player's own
--- outgoing damage credits. Driven from where damage credits rather than from
--- the arbiter, so an unverified or cross-instance report -- noise, not
--- aggression -- can never cost a player their shield.
function DM.breakProtection(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil or protectionUntilMs[playerId] == nil then return false end

    local instance = DM.instances.of(playerId)
    local breaks = Config.spawnProtection.breakOnAggression
    local tuned = instance ~= nil and instance.tune ~= nil
        and instance.tune.spawnProtectionBreaksOnFire or nil
    if tuned ~= nil then breaks = tuned == true end
    if not breaks then return false end

    if protectionUntilMs[playerId] <= DM.nowMs() then
        protectionUntilMs[playerId] = nil
        return false
    end
    protectionUntilMs[playerId] = nil
    DM.notice(playerId, "warning", "protectionBroken")
    return true
end

function DM.protectionRemaining(playerId, now)
    playerId = DM.playerId(playerId)
    local deadline = playerId and protectionUntilMs[playerId] or nil
    if deadline == nil then return 0 end
    return math.max(0, math.floor(deadline - (now or DM.nowMs())))
end

--- The refusal card. It is part of the AUTHORITATIVE state rather than only a
--- notice, because "every instance is full" is a server CAPACITY condition and
--- a player told to wait while the server matchmakes has been told something
--- else entirely. `queued` is always false: free-for-all never queues, and the
--- difference has to be machine-readable rather than a matter of wording.
local function refuse(playerId, code)
    refusals[playerId] = { code = tostring(code or "refused"), queued = false, atMs = DM.nowMs() }
end

local function admit(playerId)
    refusals[playerId] = nil
end

--- Called from `onPlayerDisconnected` (R8), BEFORE the kernel detaches, so the
--- arena still knows which side just lost a body. scoring.lua and loadout.lua
--- register their own disconnect handlers for their own tables; this one clears
--- only what this file and arena.lua hold.
function DM.forget(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    local arena = DM.arena
    if type(arena) == "table" and type(arena.forget) == "function" then
        arena.forget(playerId)
    end
    refusals[playerId] = nil
    protectionUntilMs[playerId] = nil
end


-- ============================================================ tuned reads --
--
-- Read from the INSTANCE'S CAPTURE, never from `DM.tune`. Several rounds run at
-- once, and a number that moved under a fight already in progress is exactly
-- what capturing exists to prevent; `Open77.tunables.promote()` is per-resource
-- and would move every instance's finish line at once.

local function tuned(instance, key)
    local capture = instance ~= nil and instance.tune or nil
    if type(capture) ~= "table" then return nil end
    return DM.finite(capture[key])
end

local function roundSeconds(instance)
    return math.max(10, math.floor(tuned(instance, "roundSeconds") or Config.round.durationSeconds))
end

local function killLimit(instance)
    return math.max(1, math.floor(tuned(instance, "killLimit") or Config.round.killLimit))
end

local function respawnDelayMs(instance)
    return math.max(250, math.floor(tuned(instance, "respawnDelayMs") or Config.round.respawnDelayMs))
end

local function standingsMs(instance)
    return math.max(1000, math.floor(
        (tuned(instance, "standingsSeconds") or Config.round.standingsSeconds) * 1000))
end

local function protectionMs(instance)
    local seconds = tuned(instance, "spawnProtectionSeconds")
    if seconds == nil then return Config.spawnProtection.respawnMs end
    return math.max(0, math.floor(seconds * 1000))
end

local function botsWanted(instance)
    local capture = instance ~= nil and instance.tune or nil
    local value = type(capture) == "table" and capture.fillWithBots or nil
    if value == nil then return Config.bots.fillWithBots == true end
    return value == true
end


-- =============================================== the score, read not kept --

local function scoring()
    local module = DM.scoring
    return type(module) == "table" and module or nil
end

-- Phase 8. Resolved at CALL time, never captured at load: ranked.lua loads
-- after this file and a server may run without it, in which case rounds are
-- played and simply not recorded.
local function ranking()
    local module = DM.ranked
    return type(module) == "table" and module or nil
end

--- The killer's kill count THIS ROUND, from the one scoreboard. This is the
--- only number this file reads out of the score, and it reads it rather than
--- keeping it because the kill limit and the standings must never be able to
--- disagree about who is on 25.
local function killsOf(instance, participantId)
    local module = scoring()
    if module == nil or type(module.killsOf) ~= "function" then return 0 end
    return module.killsOf(instance, participantId) or 0
end

local function enrol(instance, playerId)
    local module = scoring()
    if module == nil or type(module.addParticipant) ~= "function" then return end
    module.addParticipant(instance, playerId, { name = DM.playerName(playerId), bot = false })
end

--- A leaver keeps their row: standings that erase somebody at the moment they
--- quit rewrite the round the survivors just played.
local function unenrol(instance, playerId, reason)
    local module = scoring()
    if module == nil or type(module.removeParticipant) ~= "function" then return end
    module.removeParticipant(instance, playerId, reason)
end


-- ========================================================= the round loop --

--- Arms one player for the round in progress and gives them the protection
--- window that goes with the placement that just happened.
local function arm(instance, playerId, graceMs)
    DM.equip(playerId, instance)
    DM.holdProtection(playerId, graceMs)
end

--- Places one player into a live round. This is the whole of "free-for-all is a
--- place": there is no gate between the decision and the fight.
local function placeOne(instance, playerId, reason, graceMs, announce)
    local ok, detail = DM.place(playerId, instance, reason, graceMs)
    if not ok then
        DM.log(("round: placement failed instance=%d player=%d reason=%s detail=%s"):format(
            instance.id, playerId, tostring(reason), tostring(detail)))
        DM.notice(playerId, "error", "placementFailed")
        return false, detail
    end
    enrol(instance, playerId)
    arm(instance, playerId, graceMs)
    if announce and instance.round ~= nil and instance.round.weapon ~= nil then
        DM.notice(playerId, "info", "roundWeapon", instance.round.weapon.label)
    end
    return true
end

--- Advances the equalizer rotation, once, for the round about to start.
---
--- WHAT the rotation contains and how it is issued is loadout.lua's; that it
--- moves exactly once per round is a ROUND rule, and it is the reason this call
--- is here rather than inside `issue`. Every player in an instance must receive
--- the SAME weapon (decision 14), so a rotation advanced per player would break
--- the one idea the mode is built on.
local function rotate(instance)
    local module = DM.loadout
    if type(module) ~= "table" or type(module.rotate) ~= "function" then return nil end
    return module.rotate(instance)
end

--- Starts a round in an instance. The SAME PLAYERS stay where they are; only
--- the round record, the weapon and the placements are new.
function Round.begin(instance, reason)
    if instance == nil or instance.closed or instance.format ~= "ffa" then return nil end

    local previous = instance.round
    local number = (previous ~= nil and previous.number or 0) + 1
    local weapon = rotate(instance)
    local at = DM.nowMs()

    local round = {
        number = number,
        -- Never reused, which is what makes it safe to pin a deferred weapon
        -- assign or a queued respawn against: a recycled instance id looks
        -- identical after a reap, a recycled round id does not exist.
        id = ("%d:%d"):format(instance.id, number),
        state = "active",
        startedAtMs = at,
        endsAtMs = at + roundSeconds(instance) * 1000,
        killLimit = killLimit(instance),
        respawnDelayMs = respawnDelayMs(instance),
        weapon = weapon,
        pending = {},          -- playerId -> when their respawn is due
        death = {},            -- playerId -> the death card the HUD counts down
        result = nil,
    }
    instance.round = round

    -- Clears the score, the damage ledger and first blood, and arms bots.lua's
    -- per-round taint. It does NOT clear the roster: the same players carry into
    -- the next round, which is the point of an instance outliving them.
    local module = scoring()
    if module ~= nil and type(module.beginRound) == "function" then
        module.beginRound(instance, round.id)
    end

    -- Phase 8, and it has to be HERE rather than at the write: identity is
    -- captured while every player is certainly present, because
    -- `Open77.players.identifier` answers nil for somebody who has already
    -- gone -- and a forfeit is the result that most needs attributing. It also
    -- warms the career cache, so the round END is a computation rather than a
    -- database round trip.
    local ranked = ranking()
    if ranked ~= nil and type(ranked.onRoundStart) == "function" then
        pcall(ranked.onRoundStart, instance)
    end

    local graceMs = math.max(0, math.floor(Config.round.roundStartGraceMs or 1500))
    local placed = 0
    for _, playerId in ipairs(DM.instances.members(instance)) do
        DM.setTeam(playerId, 0, instance)
        -- Bots are placed by bots.lua, which owns their whole lifecycle and
        -- draws from the same surveyed marks. Routing one through placeOne
        -- would reach Open77.players.respawn with a negative id.
        if playerId > 0 and placeOne(instance, playerId, "round_start", graceMs, false) then
            placed = placed + 1
            DM.notice(playerId, "info", "roundWeapon", weapon and weapon.label or "")
            DM.notice(playerId, "success", "roundStart")
        end
    end

    -- Everyone still standing gets their reserve back. The shipped mode issued
    -- the reserve once, so a player who survived a long round simply ran dry.
    local kit = DM.loadout
    if type(kit) == "table" and type(kit.onRoundStart) == "function" then
        kit.onRoundStart(instance)
    end

    DM.log(("instance %d round %d ACTIVE weapon=%s limit=%d duration=%ds placed=%d reason=%s"):format(
        instance.id, number, weapon and weapon.key or "none",
        round.killLimit, roundSeconds(instance), placed, tostring(reason)))

    -- Backfill is deliberately AFTER the round is live, not before: a bot added
    -- to a round that has not started taints a round that may never run.
    if botsWanted(instance) and type(DeathmatchBots) == "table"
        and type(DeathmatchBots.backfill) == "function" then
        DeathmatchBots.backfill(instance.id)
    end

    return round
end

--- Ends a round. The instance is NOT touched: nobody moves, nobody is stripped,
--- nobody is sent anywhere. Standings run, then `Round.begin` starts the next
--- one around the same people.
function Round.finish(instance, reason, winnerId)
    local round = instance ~= nil and instance.round or nil
    if round == nil or round.state ~= "active" then return false end

    local at = DM.nowMs()
    round.state = "standings"
    round.endedAtMs = at
    round.standingsEndsAtMs = at + standingsMs(instance)
    round.pending = {}          -- nobody respawns into a round that is over

    -- The winner is chosen with the SAME comparator the scoreboard was sorted
    -- with. A winner picked by a different rule than the standings the players
    -- have just read is how an argument starts.
    if winnerId == nil then
        local module = scoring()
        if module ~= nil and type(module.leader) == "function" then
            winnerId = module.leader(instance)
        end
    end
    round.result = {
        reason = tostring(reason or "resolved"),
        winnerId = winnerId,
        winnerName = winnerId and DM.playerName(winnerId) or nil,
        -- Phase 8. Filled in below, before the state push that carries this
        -- table reaches anybody: the result card and the ladder write must
        -- agree about the same round, so one call decides both.
        ranked = false,
    }
    -- Kept on the INSTANCE, which outlives every round, so the answer to "did
    -- that count" survives the standings window. See `Round.stateFor`.
    instance.lastResult = round.result

    local seconds = math.floor(standingsMs(instance) / 1000 + 0.5)
    for _, playerId in ipairs(DM.instances.members(instance)) do
        if winnerId == playerId then
            DM.notice(playerId, "success", "roundWon")
        elseif winnerId ~= nil then
            DM.notice(playerId, "warning", "roundOver", DM.playerName(winnerId))
        else
            DM.notice(playerId, "info", "roundDraw")
        end
        DM.notice(playerId, "info", "nextRound", seconds)
    end

    -- S5, AND DECISION 12 AT THE WRITE. `ranked.lua` consults
    -- `scoring.ladderEligible` before it reads a single row, so a bot round
    -- produces no snapshot, no announcement and no statement -- there is no row
    -- for a later query to remember to filter. The call is synchronous and
    -- cheap: it walks the standings this round has already computed and hands
    -- them to a worker coroutine. Nothing here waits on a database.
    --
    -- Saying so out loud is part of the rule: a silent exclusion is
    -- indistinguishable from a broken ladder to a player who just went 20-3.
    local ranked = ranking()
    if ranked ~= nil and type(ranked.recordRound) == "function" then
        local ok, written, why = pcall(ranked.recordRound, instance, {
            roundId = round.number,
            reason = reason,
            winnerId = winnerId,
        })
        if ok then
            round.result.ranked = written == true
            if written ~= true and why == "bots" then
                pcall(ranked.announceExclusion, instance)
                DM.log(("instance %d round %d will not reach the ladder -- it contained bots"):format(
                    instance.id, round.number))
            elseif written ~= true then
                DM.log(("instance %d round %d not written to the ladder (%s)"):format(
                    instance.id, round.number, tostring(why)))
            end
        else
            DM.log(("instance %d round %d ladder write raised: %s"):format(
                instance.id, round.number, tostring(written)))
        end
    end

    DM.log(("instance %d round %d OVER reason=%s winner=%s"):format(
        instance.id, round.number, tostring(reason), tostring(winnerId or "draw")))
    return true
end


-- ------------------------------------------------------------- the entry --

--- Free-for-all entry. Returns `instance` or `nil, reason`.
---
--- There is no queue here and there is no countdown. The only refusal this can
--- ever produce is a capacity one.
function Round.join(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil, "bad_player_id" end

    -- Judging a player who is still incarnating is the mistake that produces a
    -- placement onto a body that does not exist yet.
    if not Open77.ready.isReady(playerId) then
        DM.notice(playerId, "warning", "notReady")
        return nil, "not_ready"
    end

    local instance, reason = DM.instances.assignFFA(playerId)
    if instance == nil then
        refuse(playerId, reason or "instances_full")
        DM.notice(playerId, "warning", "instancesFull")
        return nil, reason or "instances_full"
    end
    admit(playerId)
    DM.setTeam(playerId, 0, instance)

    -- An instance with no round is one nobody has fought in yet -- a fresh
    -- allocation, or one whose round was dropped when it emptied. Starting the
    -- round places everybody, this joiner included.
    if instance.round == nil then
        Round.begin(instance, "first_join")
    elseif reason ~= "already_assigned" then
        if not placeOne(instance, playerId, "join", protectionMs(instance), true) then
            DM.instances.detach(playerId, "placement_failed")
            refuse(playerId, "placement_failed")
            return nil, "placement_failed"
        end
    end

    DM.notice(playerId, "success", "joined", tostring(instance.id))
    return instance
end

--- Leaves a free-for-all instance. The instance does not care: it lingers, and
--- its round goes on for whoever is left. A lone player in an instance is
--- playing, not waiting.
function Round.leave(playerId, reason)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    local instance = DM.instances.of(playerId)
    if instance == nil or instance.format ~= "ffa" then return false end

    local round = instance.round
    if round ~= nil then
        round.pending[playerId] = nil
        round.death[playerId] = nil
    end

    unenrol(instance, playerId, reason or "left")
    DM.strip(playerId, instance)
    DM.instances.detach(playerId, reason or "left")
    DM.setTeam(playerId, 0)
    protectionUntilMs[playerId] = nil
    admit(playerId)
    DM.sendToLobby(playerId, reason or "left_match")
    DM.notice(playerId, "info", "leftMatch")
    return true
end


-- -------------------------------------------------------------- the death --

--- A counted death inside a free-for-all round.
---
--- CALLED BY scoring.lua, never by an engine event: by the time it arrives the
--- death has already passed the placement-suppression window and the
--- double-report debounce, and the kill, the streak and the bonuses are already
--- on the scoreboard. So there is deliberately no guard here that repeats any
--- of that -- a second guard would be a second answer, and the two would
--- eventually disagree.
---
--- `killerId` is 0 when nothing was credited. `info.killerKills` is the
--- killer's kill count AFTER the award, which is the number the kill limit is
--- measured on.
function Round.onDeath(instance, victimId, killerId, info)
    local round = instance ~= nil and instance.round or nil
    if round == nil or round.state ~= "active" then return false end

    info = type(info) == "table" and info or {}
    killerId = math.floor(tonumber(killerId) or 0)
    local at = DM.nowMs()

    -- A bot victim is bots.lua's to respawn, or not to; the round schedules
    -- nothing for a body it does not own. Bot participant ids are negative,
    -- which is exactly why they are.
    if victimId > 0 then
        if not instance.members[victimId] then return false end
        protectionUntilMs[victimId] = nil
        round.death[victimId] = {
            killerId = killerId,
            -- scoring.lua resolved this safely before calling us, and it knows
        -- whether the killer was a bot; asking again would re-enter the
        -- binding that used to stop the resource.
        killerName = info.killerName or "",
            cause = tostring(info.cause or "environment"),
            atMs = at,
            respawnAtMs = at + round.respawnDelayMs,
        }
        round.pending[victimId] = at + round.respawnDelayMs
    end

    -- The kill limit ends the ROUND, not the instance. Everybody stays exactly
    -- where they are and fights the next one.
    --
    -- A BOT MAY NOT END A ROUND. Bots are three mutually hostile gangs now and
    -- the engine's attitude matrix makes them fight each other in earnest, so a
    -- backfilled instance generates real kills with no player involved -- six
    -- bots crossfiring reach a limit of 25 on their own and the round resolves
    -- around players who were never in it. Bot kills still SCORE, still show in
    -- the feed, and still count towards the bot's own line; they just do not
    -- decide when the round is over. A negative id is a bot, by construction.
    if killerId > 0 then
        local kills = DM.finite(info.killerKills) or killsOf(instance, killerId)
        if kills >= round.killLimit then
            Round.finish(instance, "kill_limit", killerId)
        end
    end
    return true
end


-- ---------------------------------------------------------------- the tick --

--- Serves respawns that have come due. Collected first and acted on after,
--- because placing mutates the tables being walked.
local function serveRespawns(instance, round, now)
    local due = nil
    for playerId, at in pairs(round.pending) do
        if now >= at then
            due = due or {}
            due[#due + 1] = playerId
        end
    end
    if due == nil then return end

    for _, playerId in ipairs(due) do
        round.pending[playerId] = nil
        if instance.members[playerId] and round.state == "active" then
            local graceMs = protectionMs(instance)
            if DM.place(playerId, instance, "death_respawn", graceMs) then
                round.death[playerId] = nil
                DM.holdProtection(playerId, graceMs)
                -- Refill the reserve rather than re-issuing the whole loadout;
                -- loadout.lua honours `Config.equalizer.resupplyOnRespawn` and
                -- falls back to a full issue when nothing was ever issued.
                local kit = DM.loadout
                if type(kit) == "table" and type(kit.onRespawn) == "function" then
                    kit.onRespawn(playerId, instance)
                else
                    DM.equip(playerId, instance)
                end
                local module = scoring()
                if module ~= nil and type(module.onRespawn) == "function" then
                    module.onRespawn(playerId, instance)
                end
            else
                -- A placement that could not land is retried rather than
                -- dropped: a player left dead on the floor with no countdown has
                -- no way back into the fight at all.
                round.pending[playerId] = now + Config.lobby.placementRetryMs
            end
        end
    end
end

local function step(instance, now)
    local round = instance.round

    -- An emptied instance stops running rounds. It keeps its bucket for the
    -- linger -- the kernel's rule, not this one -- and the next joiner starts a
    -- fresh round rather than walking into the middle of one nobody played.
    if instance.memberCount == 0 then
        if round ~= nil then
            DM.log(("instance %d round %d dropped -- instance is empty"):format(
                instance.id, round.number))
            instance.round = nil
        end
        return
    end

    if round == nil then
        Round.begin(instance, "repopulated")
        return
    end

    if round.state == "active" then
        serveRespawns(instance, round, now)
        if now >= round.endsAtMs then Round.finish(instance, "time_limit") end
    elseif round.state == "standings" then
        if now >= round.standingsEndsAtMs then Round.begin(instance, "rollover") end
    end
end

--- Called from main.lua's tick (R9). Walks the KERNEL'S registry, never a table
--- this file holds: a hot reload empties whatever this VM was holding while the
--- instances, the buckets and the players inside them live on.
function Round.tick(now)
    now = now or DM.nowMs()
    local registry = DM.instances.registry
    if type(registry) ~= "table" then return end
    for _, instance in pairs(registry) do
        if not instance.closed and instance.format == "ffa" then
            step(instance, now)
        end
    end
end


-- ------------------------------------------------------------- the readout --

--- The free-for-all half of the state push. main.lua merges this over its own
--- payload (R10) and never learns which mode the player is in.
function Round.stateFor(instance, playerId)
    local round = instance.round
    local now = DM.nowMs()
    local summary = DM.instances.summary()

    local fragment = {
        mode = "ffa",
        phase = round and round.state or "active",
        playerState = "active",
        instanceId = instance.id,
        instanceBucket = instance.bucket,
        instanceCapacity = instance.capacity,
        instancePlayers = instance.memberCount,
        instanceCount = summary.ffaInstances,
        canJoin = false,
        canLeaveMatch = true,
        protectionMs = DM.protectionRemaining(playerId, now),
    }

    if round == nil then return fragment end

    fragment.round = round.number
    fragment.killLimit = round.killLimit
    if round.weapon ~= nil then
        fragment.weapon = {
            key = round.weapon.key,
            label = round.weapon.label,
            category = round.weapon.category,
        }
    end

    if round.state == "active" then
        fragment.remainingMs = math.max(0, math.floor(round.endsAtMs - now))
        local due = round.pending[playerId]
        if due ~= nil then
            fragment.playerState = "respawning"
            local card = round.death[playerId]
            fragment.death = {
                killerId = card and card.killerId or 0,
                killerName = card and card.killerName or "",
                cause = card and card.cause or "environment",
                remainingMs = math.max(0, math.floor(due - now)),
            }
        end
    else
        fragment.remainingMs = math.max(0, math.floor(round.standingsEndsAtMs - now))
    end

    -- THE LAST COMPLETED ROUND'S RESULT OUTLIVES THE STANDINGS WINDOW.
    --
    -- It used to be attached only while `round.state` was `standings`, so ten
    -- seconds after a round ended there was no longer any way to ask what it
    -- decided -- and Phase 8 gave that question a second answer worth keeping:
    -- `result.ranked`, whether the round the player just fought counted. The
    -- standings screen is a few seconds long and a player checking a career is
    -- not looking at it.
    --
    -- Harmless to the surface, because the HUD gates the banner on the PHASE and
    -- not on the presence of this field (`renderResult`: `phase === "resolved"`),
    -- so an active round draws no result card no matter what is attached here.
    -- `instance.lastResult` is written by `Round.finish`; an instance that has
    -- never finished a round simply has none.
    fragment.result = round.result or instance.lastResult

    return fragment
end

--- What a player who is in no instance at all is shown. `phase` is `"lobby"`
--- and never `"waiting"`: there is nothing to wait for, and a client handed
--- "waiting" will draw a waiting room.
local function lobbyFragment(playerId)
    local summary = DM.instances.summary()
    local fragment = {
        mode = "lobby",
        phase = "lobby",
        playerState = "lobby",
        instanceId = 0,
        instanceCount = summary.ffaInstances,
        instancePlayers = summary.ffaPlayers,
        instanceCapacity = summary.capacity,
        canJoin = true,
        canLeaveMatch = false,
        target = summary.target,
        targetCount = summary.targetCount,
    }

    local arena = DM.arena
    if type(arena) == "table" and type(arena.lobbyFragment) == "function" then
        for key, value in pairs(arena.lobbyFragment(playerId)) do fragment[key] = value end
    end
    return fragment
end


-- =============================================================== dispatch --
--
-- Two seams main.lua calls without knowing which mode the player is in. They
-- live in round.lua because it loads first; arena.lua is resolved at call time,
-- so a resource set without it degrades to free-for-all only rather than
-- failing to load.

local function arenaModule()
    local arena = DM.arena
    return type(arena) == "table" and arena or nil
end

--- The whole of R10. Returns a table main.lua merges over its state payload.
function DM.fragmentFor(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return {} end

    local instance = DM.instances.of(playerId)
    local arena = arenaModule()
    local fragment
    if instance == nil then
        fragment = lobbyFragment(playerId)
    elseif instance.format == "ffa" then
        fragment = Round.stateFor(instance, playerId)
    elseif arena ~= nil and type(arena.stateFor) == "function" then
        fragment = arena.stateFor(instance, playerId)
    else
        fragment = lobbyFragment(playerId)
    end

    -- The arena queue counts ride on EVERY push, including a free-for-all one.
    -- Section 15's mitigation for "arena queues never fill" is that the queue
    -- stays visible from inside a live free-for-all fight, and a number a
    -- player cannot see is a number they will not join.
    if arena ~= nil and type(arena.queueCounts) == "function" then
        fragment.arenaQueue = arena.queueCounts()
    end

    local refusal = refusals[playerId]
    if refusal ~= nil then fragment.refusal = refusal end
    return fragment
end

--- The whole of R7. `scope` is the client's hint and is honoured when it says
--- "queue"; otherwise the player's actual position decides, because a client
--- that believes it is queued while the server has it in a fight must not be
--- allowed to talk the server out of the fight.
function DM.leave(playerId, scope)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    scope = tostring(scope or "auto")
    local arena = arenaModule()

    local function dequeue()
        if arena ~= nil and type(arena.dequeue) == "function" then
            return arena.dequeue(playerId, "player_left") ~= false
        end
        return false
    end

    if scope == "queue" then return dequeue() end

    local instance = DM.instances.of(playerId)
    if instance == nil then return dequeue() end
    if instance.format == "ffa" then return Round.leave(playerId, "player_left") end
    if arena ~= nil and type(arena.leave) == "function" then
        return arena.leave(playerId, "player_left")
    end
    return false
end


-- ------------------------------------------------- entry points main.lua keeps --
--
-- Two calls main.lua makes that predate scoring.lua landing. Both are kept, and
-- both are now FORWARDERS into the one scoreboard rather than a second answer:
-- there is one suppression window and one death ledger in this mode, and these
-- reach them rather than shadowing them.
--
-- Both are safe to delete from main.lua when it is next touched. `suppressDeath`
-- is already paired there with the `Deathmatch.scoring.suppressDeath` of S2, so
-- it writes the same deadline twice; `onDeath` is paired with scoring.lua's own
-- registration of the same two engine events, and the debounce inside
-- `countDeath` is what makes the pair harmless rather than double-counted.

--- Every placement is a `kill -> respawn`, so main.lua calls this before every
--- one. scoring.lua owns the window; this is the older spelling of the same act.
function DM.suppressDeath(playerId, durationMs)
    local module = scoring()
    if module == nil or type(module.suppressDeath) ~= "function" then return false end
    return module.suppressDeath(playerId, durationMs) == true
end

--- A death observed by main.lua's own `open77:playerKilled` / `playerDied`
--- handlers. It does NOT run the round rule directly: it goes through
--- `Scoring.credit`, which is the same door bots.lua uses, so whichever of the
--- two describers arrives first counts and the second is dropped inside the
--- debounce. The round consequences then arrive back here through the death
--- handler registered below, once, by the only path that scores.
function DM.onDeath(victimId, killerId, cause)
    victimId = DM.playerId(victimId)
    if victimId == nil then return false end
    local instance = DM.instances.of(victimId)
    if instance == nil or instance.closed then return false end
    local module = scoring()
    if module == nil or type(module.credit) ~= "function" then return false end
    return module.credit(instance, victimId, killerId, cause) == true
end


-- ============================================================ registration --
--
-- scoring.lua owns the events and the score; this is the handshake that hands
-- the ROUND consequences of a counted death back to the round that owns them.
-- Registered here rather than wired from main.lua, so the two files agree
-- without a third one having to know they exist.

local function registerWithScoring()
    local module = scoring()
    if module == nil then
        DM.log("round.lua: scoring.lua is not loaded -- no respawns, no kill limit, no eliminations")
        return false
    end

    module.setDeathHandler(function(instance, victimId, killerId, info)
        if instance == nil or instance.closed then return end
        if instance.format == "ffa" then
            Round.onDeath(instance, victimId, killerId, info)
            return
        end
        local arena = arenaModule()
        if arena ~= nil and type(arena.onDeath) == "function" then
            arena.onDeath(instance, victimId, killerId, info)
        end
    end)

    -- R13. Nothing else in the mode can see a player's own outgoing damage
    -- credit, which is the only honest moment to drop their shield.
    if type(module.setAggressionHandler) == "function" then
        module.setAggressionHandler(DM.breakProtection)
    end
    return true
end

registerWithScoring()

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Re-registered at start as well as at load: a hot reload can bring the two
    -- files up in either order, and a death handler that was never registered
    -- is a mode where nobody ever respawns -- which reads as a placement bug,
    -- not as a wiring one.
    registerWithScoring()
    DM.log(("round loop ready -- %ds rounds, first to %d, %.1fs respawn, %ds standings"):format(
        Config.round.durationSeconds, Config.round.killLimit,
        Config.round.respawnDelayMs / 1000, Config.round.standingsSeconds))
end)


-- --------------------------------------------------------------- commands --

local function output(source, raw, ok, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

--- The `<mode>.where` habit applied to the round loop: print what the server
--- believes about every live free-for-all round, so a rollover surprise can be
--- read rather than guessed at.
RegisterCommand("dm.rounds", function(source, _, raw)
    local now = DM.nowMs()
    local ids = {}
    for id, instance in pairs(DM.instances.registry) do
        if not instance.closed and instance.format == "ffa" then ids[#ids + 1] = id end
    end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local instance = DM.instances.registry[id]
        local round = instance.round
        if round == nil then
            output(source, raw, true, ("  #%d %d/%d -- no round"):format(
                instance.id, instance.memberCount, instance.capacity))
        else
            local deadline = round.state == "active" and round.endsAtMs or round.standingsEndsAtMs
            local pending = 0
            for _ in pairs(round.pending) do pending = pending + 1 end
            output(source, raw, true, ("  #%d %d/%d round %d %s weapon=%s limit=%d in %.1fs respawning=%d"):format(
                instance.id, instance.memberCount, instance.capacity,
                round.number, round.state, round.weapon and round.weapon.key or "none",
                round.killLimit, math.max(0, deadline - now) / 1000, pending))
        end
    end
    if #ids == 0 then output(source, raw, true, "no free-for-all instance is running") end
end, false)
