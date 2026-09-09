-- Kabuki Arena -- the queued formats: 1v1, 2v2 and 3v3.
--
-- ARENA IS A MATCH, AND THIS IS THE ONLY PLACE IN THE MODE WHERE ANYONE WAITS.
-- Teams must be balanced and rounds must be symmetric, so unlike free-for-all
-- these genuinely queue; the queue exists because the format demands it, not
-- because the server wants a moment to think.
--
-- The shape, and every line below is one of these five sentences:
--
--   1. A queue per size. When a roster fills, an instance is allocated for the
--      whole roster at once -- `Instances.openArena`, not `assignFFA` -- so
--      there is never a half-formed match to reason about.
--   2. Sides are assigned by alternating the arrival order and pushed to the
--      platform with `Open77.combat.setTeam`. Friendly fire is cancelled BY THE
--      PLATFORM from that call; nothing here re-implements it, and nothing here
--      could, because combat policy is host-global.
--   3. Rounds are ELIMINATION. A death inside a round is final for that round:
--      no respawn, no placement, no countdown. The body stays dead in the
--      match's bucket, which is what "spectate your team" means -- there is no
--      spectator camera to hand out and no need for one.
--   4. A wiped team loses the round; the round point goes to the survivors.
--      Sides swap at the halfway point so the end of the map a team drew is not
--      the reason it won. First to N round wins takes the match.
--   5. Then everybody goes back to the lobby and the instance closes. A match
--      instance is allocated per match and released on the result, which is the
--      exact opposite of the free-for-all instance that outlives every round.
--
--
-- BOTS HOLD A SIDE. Added 2026-09-01, and it changes sentence 1 rather than
-- adding a sixth: a roster is completed with bots when the queue cannot fill
-- it, so a format with one player in the queue still becomes a match. Four
-- clients exhaust this workstation's 12 GiB card, so 3v3 has no other way of
-- being tested at all -- bot filling is not a convenience here, it is the only
-- path to the plan's own DONE criterion.
--
-- Five consequences run through this file, and each is commented where it
-- lands rather than only here:
--
--   * A ROSTER ENTRY IS A PARTICIPANT ID, not a player id, and a bot's is
--     NEGATIVE. `Open77.players.name`, `.position` and `.identifier` RAISE on a
--     non-positive id, the exception unwinds through `pcall`, and the resource
--     stops. `isBotId` is the guard in front of every one of them here.
--   * `instance.members` IS A PLAYER TABLE -- `Instances.attach` refuses a
--     negative id -- so a bot is bound as an ACTOR instead and membership is
--     asked through `present`. Judging a bot on `members` reads as "left the
--     server", which would wipe a side of bots on its first millisecond.
--   * A BOT IS NOT PLACED BY `DM.place`. That primitive is `kill -> respawn` on
--     a player proxy. bots.lua owns bot bodies, including the pacing that keeps
--     the entity service out of the churn that crashed the client, so round
--     starts hand it the two clusters and let it move them.
--   * FRIENDLY FIRE HAS TO BE STATED. Sentence 2 above is still true for
--     players and is NOT true for bots: the engine's hostility sweep makes
--     every native body in a bucket hostile to every other one and to the
--     player, all pairs, with no team to consult -- it has none, because the
--     NPC replica carries no side. `Arena.sideOf` is the one answer bots.lua
--     gates its three damage paths on, at the server ledger, which is the only
--     place a team-mate's bullet can be refused without a client change.
--   * THE LADDER IS UNAFFECTED, and deliberately needed no work: `createBot`
--     already taints the round and already reports `bot = true` to the
--     scoreboard, and `Scoring.ladderEligible` reads both AT THE WRITE. A match
--     with a bot on it is excluded by exactly the mechanisms a free-for-all
--     round is, with no arena-specific case to keep in step (decision 12).
--
-- WHAT THIS FILE DOES NOT OWN. The same line round.lua draws, for the same
-- reason: the SCORE is scoring.lua's -- kills, deaths, assists, bonuses,
-- streaks, the feed and the standings rows all live on `instance.scoreboard`,
-- and this file keeps no second copy of any of it. What the arena owns of the
-- result is the ROUND-WIN TALLY, which is a different number from the score and
-- is the only one a best-of is measured on. The LOADOUT is loadout.lua's,
-- including the kit a player picks in the buy window: this file owns the window,
-- not the choice made inside it. PLACEMENT is main.lua's.
--
-- A counted death reaches `Arena.onDeath` from scoring.lua, through the handler
-- round.lua registers -- already suppressed for placements, already debounced,
-- already credited.
--
--
-- Two things this file is deliberately careful about.
--
-- `setTeam` IS RE-APPLIED AT EVERY ROUND START, not once at match formation.
-- E5 -- "does `setTeam` survive a `kill -> respawn` placement?" -- is the one
-- Phase 0 experiment still unmeasured, and every round start places every
-- player. Re-applying is correct under both outcomes and costs one call per
-- player per round; assuming it survives is correct under only one of them, and
-- the failure mode is silent friendly fire between team-mates.
--
-- SIDE IS NOT SPAWN CLUSTER. A player's side is their half of the roster and is
-- stable for the whole match -- it is what the scoreboard, the team colours and
-- `setTeam` key on. What swaps at the halfway point is which END OF THE MAP that
-- half starts each round on, and that is `spawnCluster`. Conflating the two
-- would make a swap look like a player changing teams mid-match.
--
-- main.lua's wiring for this file is in the R-block at the top of round.lua.
-- Only R6 (the `deathmatch:queue` and `deathmatch:kit` net events) and R7
-- (leaving) are exclusively about the arena; everything else it needs it shares
-- with the free-for-all loop.


Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig
local Kabuki = DeathmatchKabuki

DM.arena = DM.arena or {}
local Arena = DM.arena


-- ================================================================= queues --
--
-- One queue per queued format, built from `Config.formats` rather than
-- hardcoded, so adding a 5v5 is a config edit.
--
-- This IS module-scope state, and it is the one thing in the two round files
-- that legitimately is: a queue is a property of the host, not of an instance,
-- and there is no instance to hang it off until the roster fills. A hot reload
-- empties it while the queued players live on in the lobby -- which is honest
-- rather than lossy: they are standing where they were, nothing was taken from
-- them, and the next thing they do re-queues them. It is announced at start, so
-- the emptiness is never mistaken for a queue that will not fill.

local queues = {}
local formatOrder = {}

for key, spec in pairs(Config.formats) do
    if spec.queued then
        queues[key] = {}
        formatOrder[#formatOrder + 1] = key
    end
end
table.sort(formatOrder, function(a, b)
    return (Config.formats[a].order or 0) < (Config.formats[b].order or 0)
end)

-- Said once each: an unsurveyed team cluster is a standing condition, not a
-- per-tick event.
local said = {}
local function sayOnce(key, text)
    if said[key] then return end
    said[key] = true
    DM.log(text)
end


-- ============================================================ tuned reads --
--
-- Match-level numbers come from the INSTANCE'S CAPTURE, exactly like every
-- other rule in the mode: several matches run at once, and a "best of" that
-- moved under a match already in progress would move a finish line somebody was
-- two rounds from crossing.

local function tuned(instance, key)
    local capture = instance ~= nil and instance.tune or nil
    if type(capture) ~= "table" then return nil end
    return DM.finite(capture[key])
end

local function bestOf(instance)
    -- Odd, so there is no draw to explain. An even value is rounded up rather
    -- than refused: a panel that can produce one should not be able to produce a
    -- match that cannot be won.
    local value = math.max(1, math.floor(tuned(instance, "arenaBestOf") or Config.arena.bestOf))
    if value % 2 == 0 then value = value + 1 end
    return value
end

local function roundSeconds(instance)
    return math.max(10, math.floor(tuned(instance, "arenaRoundSeconds") or Config.arena.roundSeconds))
end

local function buyMs(instance)
    return math.max(0, math.floor(
        (tuned(instance, "arenaBuySeconds") or Config.arena.buySeconds) * 1000))
end

local function betweenMs()
    return math.max(0, math.floor((Config.arena.betweenRoundsSeconds or 8) * 1000))
end

local function resultMs()
    return math.max(0, math.floor((Config.arena.resultSeconds or 12) * 1000))
end


-- ================================================================== marks --
--
-- Team spawn clusters are PER FORMAT. Each format carves a different zone, so a
-- 1v1 taking the 3v3 alley cluster would spawn both duellists outside `lower` --
-- and the bounds backstop would then "correct" that by killing them. Six extra
-- marks buy a rule with no exceptions.

--- The surveyed marks of one cluster, or nil when the survey has not reached
--- them. Nil REFUSES TO FORM THE MATCH; it never falls back onto the
--- free-for-all marks. An unsurveyed mark is not a coordinate, and a derived one
--- asserts walkable ground that Corpo Plaza proved is not implied by nearby XY.
function Arena.cluster(format, side)
    local teams = Kabuki.teams[format]
    local marks = teams and teams[side] or nil
    if type(marks) ~= "table" or #marks == 0 then return nil end
    for _, mark in ipairs(marks) do
        if Kabuki.point(mark.position) == nil then return nil end
    end
    return marks
end

--- Both clusters, or nil plus the id of the one that is missing.
local function clustersFor(format)
    local a = Arena.cluster(format, "a")
    if a == nil then return nil, "a" end
    local b = Arena.cluster(format, "b")
    if b == nil then return nil, "b" end
    return { a = a, b = b }
end


-- ================================================================== queue --

local function queueFor(format)
    return queues[tostring(format or "")]
end

--- Where a player stands, across every queue. There is no way to list players
--- and no reverse index worth maintaining for three short arrays.
function Arena.queuePosition(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end
    for _, format in ipairs(formatOrder) do
        for index, entry in ipairs(queues[format]) do
            if entry.playerId == playerId then return index, format end
        end
    end
    return nil
end

function Arena.queueCounts()
    local counts = {}
    for _, format in ipairs(formatOrder) do counts[format] = #queues[format] end
    return counts
end

local function removeFrom(format, playerId)
    local queue = queues[format]
    if queue == nil then return false end
    for index = #queue, 1, -1 do
        if queue[index].playerId == playerId then
            table.remove(queue, index)
            return true
        end
    end
    return false
end

--- Enters a queue. Returns `position, format`, or `nil, reason`.
---
--- A player already in a fight is refused rather than silently pulled out of it:
--- leaving is an explicit act, and a station press that yanked somebody out of a
--- live round would be indistinguishable from a bug.
--- `wantsBots` is the caller's EXPLICIT consent to be matched against bots,
--- and it is a property of the queue ENTRY rather than of the queue: two people
--- can stand in the same 2v2 queue and only one of them be willing to have it
--- completed. One willing entry is enough to fill the roster -- the alternative,
--- requiring unanimity, means the format never starts on a server where one
--- player has not found the option, which is the state this whole change
--- exists to leave.
function Arena.enqueue(playerId, format, wantsBots)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil, "bad_player_id" end
    format = tostring(format or "")
    if queueFor(format) == nil then return nil, "unknown_format" end

    if not Open77.ready.isReady(playerId) then
        DM.notice(playerId, "warning", "notReady")
        return nil, "not_ready"
    end
    if DM.instances.of(playerId) ~= nil then
        return nil, "already_in_instance"
    end

    -- One queue at a time. Standing in all three would let one player fill three
    -- rosters and be pulled into whichever filled first -- a reasonable feature,
    -- and a different decision from this one.
    local existing, current = Arena.queuePosition(playerId)
    if current == format then
        -- Already here. Re-queueing with `bots` is how a player who queued and
        -- then got tired of waiting says so, so the flag is UPGRADED rather
        -- than ignored -- and then the formation is retried, because that
        -- upgrade may be exactly what lets the roster close.
        if wantsBots == true then
            local entry = queues[format][existing]
            if entry ~= nil and entry.bots ~= true then
                entry.bots = true
                DM.log(("arena queue %s: player %d will accept bots"):format(format, playerId))
                Arena.tryForm(format)
            end
        end
        DM.notice(playerId, "info", "queued", existing, Config.formats[format].label)
        return existing, format
    end
    if current ~= nil then removeFrom(current, playerId) end

    local at = DM.nowMs()
    local queue = queues[format]
    queue[#queue + 1] = { playerId = playerId, atMs = at, seenMs = at, bots = wantsBots == true }
    local position = #queue
    DM.notice(playerId, "success", "queued", position, Config.formats[format].label)
    DM.log(("arena queue %s: player %d joined at position %d"):format(format, playerId, position))

    Arena.tryForm(format)
    return position, format
end

--- Leaves a queue. Silent when the player was not in one.
function Arena.dequeue(playerId, reason)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    local _, format = Arena.queuePosition(playerId)
    if format == nil then return false end
    removeFrom(format, playerId)
    DM.log(("arena queue %s: player %d left (%s)"):format(format, playerId, tostring(reason)))
    DM.notice(playerId, "info", "queueLeft")
    return true
end

--- A queued player who stops answering is dropped rather than holding a slot
--- five other people are waiting behind. "Stops answering" is measured on the
--- server's own view -- a name that no longer resolves, or a readiness gate the
--- player has fallen back through -- never on a client report.
local function prune(now)
    local staleMs = math.max(1000, math.floor(Config.arena.queue.staleAfterMs or 180000))
    for _, format in ipairs(formatOrder) do
        local queue = queues[format]
        for index = #queue, 1, -1 do
            local entry = queue[index]
            local playerId = entry.playerId
            local gone = Open77.players.name(playerId) == nil
            local inFight = DM.instances.of(playerId) ~= nil
            if Open77.ready.isReady(playerId) then entry.seenMs = now end
            if gone or inFight or (now - entry.seenMs) >= staleMs then
                table.remove(queue, index)
                DM.log(("arena queue %s: player %s dropped (%s)"):format(
                    format, tostring(playerId),
                    gone and "disconnected" or (inFight and "already in a fight" or "stale")))
                if not gone and not inFight then
                    DM.notice(playerId, "info", "queueLeft")
                end
            end
        end
    end
end


-- =========================================================== match record --

local function scoring()
    local module = DM.scoring
    return type(module) == "table" and module or nil
end

-- Phase 8, resolved at call time. See the same helper in round.lua.
local function ranking()
    local module = DM.ranked
    return type(module) == "table" and module or nil
end

local function sideOf(instance, playerId)
    local match = instance ~= nil and instance.match or nil
    return match ~= nil and match.sides[playerId] or nil
end

local function other(side)
    return side == 1 and 2 or 1
end


-- ==================================================================== bots --
--
-- A ROSTER SLOT IS A PARTICIPANT, AND A BOT IS A PARTICIPANT. Everything below
-- that says "player" in a variable name now means participant, and the three
-- helpers here are the whole of the difference between the two kinds.
--
-- bots.lua owns the lifecycle -- creation, pacing, the native combat path, the
-- leash, respawn. This file owns only the two things a MATCH knows and a bot
-- cannot: which side it holds, and when a round starts. It reaches bots.lua
-- through its published functions and never touches a bot record.
--
-- Resolved at call time, exactly like `scoring()` and `ranking()` above: a
-- server whose manifest omits `server/bots.lua` runs the same arena and simply
-- never fills one.

local function botsModule()
    local module = DeathmatchBots
    return type(module) == "table" and module or nil
end

--- Is this participant id a bot? Cheap, total, and safe on any input -- it is
--- the guard in front of every `Open77.players.*` call in this file.
---
--- A bot's participant id is NEGATIVE by construction, so the sign alone
--- answers it. `DeathmatchBots.isBot` is consulted as well because a negative
--- id belonging to no live bot is a roster row for a body that has gone, and
--- those two cases want different treatment in `rosterFor`.
local function isBotId(participantId)
    local id = tonumber(participantId)
    return id ~= nil and id < 0
end

--- Is this roster member still IN the match?
---
--- `instance.members` is a PLAYER table -- `Instances.attach` refuses a
--- non-positive id -- so it answers nil for every bot, and a bot roster judged
--- on it is a roster of six players who all left. That is not a hypothetical:
--- `aliveOn` reads this, `aliveOn` decides when a team is wiped, and a team
--- that is wiped on its first millisecond ends the round instantly.
local function present(instance, participantId)
    if not isBotId(participantId) then
        return instance ~= nil and instance.members[participantId] == true
    end
    local module = botsModule()
    if module == nil or type(module.get) ~= "function" then return false end
    local bot = module.get(participantId)
    return bot ~= nil and instance ~= nil
        and tostring(bot.instanceId) == tostring(instance.id)
end

--- Which end of the map a side starts a round on. The swap is on ROUNDS PLAYED,
--- not on round wins: a swap that depends on the score can be dodged by winning,
--- and the point of swapping is that neither team keeps the better half for the
--- whole match.
local function clusterKey(match, side, roundNumber)
    local swapped = roundNumber > match.swapAfterRounds
    if side == 1 then return swapped and "b" or "a" end
    return swapped and "a" or "b"
end

--- Is this roster member a body that is UP, right now?
---
--- THREE TESTS, AND A BOT NEEDS ALL THREE. `eliminated` is the arena's own
--- ledger, written by `Arena.onDeath` for players and bots alike; `present` says
--- the body still exists at all; and for a bot the LIVE STATE is asked of
--- bots.lua directly.
---
--- The third one is not redundant, and it is the difference between a count
--- that is derived and a count that is merely remembered. `eliminated` is only
--- ever set by an event chain -- `declareDeath` -> `creditKill` -> the death
--- handler -> `Arena.onDeath` -- and any link of that chain declining leaves a
--- bot that is dead in bots.lua and alive on this roster. Asking the body is one
--- table read and it cannot be out of date.
local function standing(instance, match, participantId)
    if not present(instance, participantId) then return false end
    if match.eliminated[participantId] then return false end
    if isBotId(participantId) then
        local module = botsModule()
        if module ~= nil and type(module.isAlive) == "function" then
            return module.isAlive(participantId) == true
        end
    end
    return true
end

--- How many of one side are still standing THIS round.
local function aliveOn(instance, side)
    local match = instance.match
    local count = 0
    for _, participantId in ipairs(match.roster[side]) do
        if standing(instance, match, participantId) then count = count + 1 end
    end
    return count
end

local function refreshAlive(instance)
    local match = instance.match
    match.aliveByTeam = { aliveOn(instance, 1), aliveOn(instance, 2) }
    return match.aliveByTeam
end

--- Sides go to the platform AND to the scoreboard: the platform is what cancels
--- friendly fire, the row is what lets the HUD colour a name without a second
--- lookup. `Deathmatch.setTeam` does both.
local function assignTeam(instance, playerId, side)
    DM.setTeam(playerId, side, instance)
end


-- ============================================================= the rounds --

--- Starts a round. Places EVERY roster member -- including the players
--- eliminated in the last one, because elimination is scoped to ONE round -- at
--- their side's cluster mark, re-applies the team, and opens the buy window. The
--- round goes live when the buy window closes.
local function startRound(instance, reason)
    local match = instance.match
    local number = match.roundNumber + 1
    match.roundNumber = number
    match.eliminated = {}

    local at = DM.nowMs()
    local buy = buyMs(instance)
    local round = {
        number = number,
        -- Never reused, so a deferred assign or a queued callback can be pinned
        -- against it safely.
        id = ("%d:%d"):format(instance.id, number),
        state = "buy",
        startedAtMs = at,
        buyEndsAtMs = at + buy,
        -- The hard end of the wait for a roster that is still arriving. See
        -- `step`: the buy window doubles as the bots' grace period, and this is
        -- the bound that stops a body which is never coming from stalling the
        -- match. Only ever consulted while `match.pendingBots > 0`.
        rosterDeadlineMs = at + buy
            + math.max(0, math.floor(Config.arena.botFillGraceMs or 15000)),
        endsAtMs = nil,
        -- M5's damage gate reads `instance.round.state`; it must exist and it
        -- must not say "active" during the buy window. There is deliberately no
        -- `weapon`: an arena round issues kits rather than one shared weapon, and
        -- loadout.lua resolves the plan from the format.
        weapon = nil,
    }
    instance.round = round

    -- Clears the score and the damage ledger for the new round, and arms
    -- bots.lua's per-round taint.
    local module = scoring()
    if module ~= nil and type(module.beginRound) == "function" then
        module.beginRound(instance, round.id)
    end

    -- Phase 8: capture identity while everybody is certainly present, and warm
    -- the career cache. See the same call in round.lua.
    local ranked = ranking()
    if ranked ~= nil and type(ranked.onRoundStart) == "function" then
        pcall(ranked.onRoundStart, instance)
    end

    -- The grace covers the whole buy window plus the round-start window, so
    -- nothing can judge or shoot a player who is standing still by the rules.
    local graceMs = buy + math.max(0, math.floor(Config.arena.roundStartGraceMs or 1500))
    local placed, bots = 0, 0
    -- THIS round's clusters, per side, kept so bots.lua can be handed both in
    -- one call. It is a per-round table and not a per-match one precisely
    -- because `clusterKey` swaps them at the halfway point.
    local marksBySide = {}
    for side = 1, 2 do
        local marks = match.clusters[clusterKey(match, side, number)]
        marksBySide[side] = marks
        local index = 0
        for _, participantId in ipairs(match.roster[side]) do
            index = index + 1
            local mark = marks[((index - 1) % #marks) + 1]
            -- Re-applied every round: E5 is unmeasured, and this is correct
            -- whether or not a team survives a placement. It is called for a
            -- BOT too -- `DM.setTeam` tells the scoreboard and then returns
            -- before touching `Open77.combat.setTeam`, which refuses a negative
            -- id and would stop the resource.
            assignTeam(instance, participantId, side)
            if isBotId(participantId) then
                -- A BOT IS NOT PLACED BY `DM.place`. That primitive is
                -- `kill -> respawn` on a player proxy and refuses a negative id
                -- outright; a bot's body is bots.lua's, and it is moved below,
                -- in one call for the whole instance, so the pacing gates and
                -- the respawn transaction stay where they are owned. The
                -- scoreboard row already exists -- `createBot` registered it --
                -- and `assignTeam` above has just refreshed its side.
                bots = bots + 1
            else
                local ok, detail = DM.place(participantId, instance, "arena_round", graceMs, mark)
                if ok then
                    if module ~= nil and type(module.addParticipant) == "function" then
                        module.addParticipant(instance, participantId,
                            { name = DM.playerName(participantId), team = side, bot = false })
                    end
                    DM.holdProtection(participantId, graceMs)
                    placed = placed + 1
                else
                    DM.log(("arena %d: placement failed player=%d detail=%s"):format(
                        instance.id, participantId, tostring(detail)))
                    DM.notice(participantId, "error", "placementFailed")
                end
            end
        end
    end

    -- The bot half of the placement, and it is deliberately ONE call rather
    -- than one per bot: bots.lua paces body creation across the whole resource
    -- and a per-bot round-start loop here would be a second scheduler racing
    -- the first. It relocates the living and revives the dead onto their side's
    -- cluster for this round; `goLive` re-arms elimination once it has run.
    if bots > 0 then
        local module_ = botsModule()
        if module_ ~= nil and type(module_.arenaRoundStart) == "function" then
            local ok, touched, moved, revived, bodies =
                pcall(module_.arenaRoundStart, instance.id, marksBySide)
            if not ok then
                DM.log(("arena %d: bot round start raised: %s"):format(
                    instance.id, tostring(touched)))
            else
                -- SAID OUT LOUD, every round, because the alternative is what
                -- happened on 2026-09-01: an operator reading `1/6+10bot` had
                -- no line anywhere that could tell them whether the match had
                -- acquired five extra bodies or one counter was doubling. It
                -- had not -- but proving that took an hour it should have taken
                -- a log line. `touched` is the roster this call reset, `moved`
                -- and `revived` are the two ways a body comes back, and `bodies`
                -- is what the instance really holds afterwards: it must equal
                -- the bot half of the format, every round, for the whole match.
                -- `touched` short of `bots` is a bot that lost its side, which
                -- is a formation bug and is now visible too.
                DM.log(("arena %d round %d: %d/%d bot(s) reset -- %d moved, %d revived, %d bodies held"):format(
                    instance.id, number, tonumber(touched) or 0, bots,
                    tonumber(moved) or 0, tonumber(revived) or 0,
                    tonumber(bodies) or 0))
            end
        end
    end

    refreshAlive(instance)
    local seconds = math.floor(buy / 1000 + 0.5)
    for _, playerId in ipairs(DM.instances.members(instance)) do
        if number == match.swapAfterRounds + 1 then
            DM.notice(playerId, "info", "sidesSwapped")
        end
        if buy > 0 then DM.notice(playerId, "info", "buyWindow", seconds) end
    end

    DM.log(("arena %d (%s) round %d BUY placed=%d/%d bots=%d swapped=%s reason=%s"):format(
        instance.id, match.format, number, placed,
        #match.roster[1] + #match.roster[2], bots,
        tostring(number > match.swapAfterRounds), tostring(reason)))
    return round
end

--- The buy window closes: kits are issued and the round goes live.
local function goLive(instance, now)
    local round = instance.round
    local match = instance.match
    round.state = "active"
    round.startedAtMs = now
    round.endsAtMs = now + roundSeconds(instance) * 1000
    refreshAlive(instance)

    -- HUMANS, not members. This loop touches the ENGINE -- `DM.equip` runs the
    -- loadout path -- and `members` is the participant roster, which now
    -- genuinely contains bots. A bot needs no kit: the gang record arrives
    -- armed and `bots.combat.forceWeapon` is the only thing that touches it.
    for _, playerId in ipairs(DM.instances.humans(instance)) do
        -- loadout.lua resolves the kit the player chose during the window; this
        -- file owns the window, not the choice made inside it.
        DM.equip(playerId, instance)
        DM.notice(playerId, "success", "roundStart")
    end

    -- ELIMINATION IS ARMED HERE, not at round start. The buy window is exactly
    -- when a bot killed last round is allowed to come back, and this is the
    -- edge that closes it again -- so a bot that dies inside the live round
    -- stays down for the rest of it, which is decision 4 applied to a body
    -- instead of a player.
    local module = botsModule()
    if module ~= nil and type(module.arenaRoundLive) == "function" then
        local ok, alive, total = pcall(module.arenaRoundLive, instance.id)
        if ok and (tonumber(total) or 0) > 0 then
            -- Said out loud when a bot did NOT make it back: a side that starts
            -- a body down is a real handicap, and reading it off the scoreboard
            -- later is how it gets mistaken for a bot that was shot early.
            if alive ~= total then
                DM.log(("arena %d round %d: %d of %d bot(s) stood up in time"):format(
                    instance.id, round.number, alive, total))
            end
            refreshAlive(instance)
        end
    end

    DM.log(("arena %d round %d ACTIVE alive=%d-%d duration=%ds"):format(
        instance.id, round.number, match.aliveByTeam[1], match.aliveByTeam[2],
        roundSeconds(instance)))
end

local resolveMatch   -- forward: a departure can end a match

--- Scores a round. `winnerSide` of nil is a draw and awards nothing -- which can
--- only happen on the timer with both sides equally alive, and is reported as a
--- draw rather than broken on a hidden tiebreak.
local function finishRound(instance, winnerSide, reason)
    local round = instance.round
    local match = instance.match
    if round == nil or round.state ~= "active" then return false end

    round.state = "between"
    round.endedAtMs = DM.nowMs()
    round.betweenEndsAtMs = round.endedAtMs + betweenMs()
    round.winnerSide = winnerSide

    if winnerSide ~= nil then
        match.wins[winnerSide] = match.wins[winnerSide] + 1
    end

    for _, playerId in ipairs(DM.instances.members(instance)) do
        local side = sideOf(instance, playerId)
        if side ~= nil and winnerSide ~= nil then
            local mine, theirs = match.wins[side], match.wins[other(side)]
            if side == winnerSide then
                DM.notice(playerId, "success", "teamWon", mine, theirs)
            else
                DM.notice(playerId, "warning", "teamLost", mine, theirs)
            end
        end
    end

    -- S5 AND DECISION 12, AT THE WRITE -- and it is HERE rather than at the
    -- match result because `Scoring.beginRound` clears the board at the start of
    -- every arena round. By the time the match resolves, the standings hold the
    -- LAST round only, so a single match-level write would silently record one
    -- fifth of a best-of-five. One write per round, exactly as a free-for-all
    -- does it, and the career sums them.
    --
    -- `winners` names a whole SIDE rather than one leader, because an arena
    -- round is won by a team.
    local ranked = ranking()
    if ranked ~= nil and type(ranked.recordRound) == "function" then
        local winners = nil
        if winnerSide ~= nil and winnerSide ~= 0 then
            winners = {}
            for _, playerId in ipairs(DM.instances.members(instance)) do
                if playerId > 0 and sideOf(instance, playerId) == winnerSide then
                    winners[playerId] = true
                end
            end
        end
        local ok, written, why = pcall(ranked.recordRound, instance, {
            roundId = round.number,
            reason = reason,
            winners = winners,
            -- The SIDE, named rather than inferred. `winners` is a set of player
            -- ids and answers "did this player win"; the rating's two-sided model
            -- needs "which of the two sides won", and those stop being the same
            -- question the moment a side is all bots, all unkeyable, or empty --
            -- at which point an inference from `winners` reads as a draw and
            -- quietly rates a decisive round as one. `nil` here IS the draw.
            winnerSide = winnerSide,
        })
        if ok then
            if written == true then match.ranked = true end
            if written ~= true and why ~= "bots" then
                DM.log(("arena %d round %d not written to the ladder (%s)"):format(
                    instance.id, round.number, tostring(why)))
            end
        else
            DM.log(("arena %d round %d ladder write raised: %s"):format(
                instance.id, round.number, tostring(written)))
        end
    end

    DM.log(("arena %d round %d OVER winner=%s reason=%s score=%d-%d"):format(
        instance.id, round.number, tostring(winnerSide or "draw"), tostring(reason),
        match.wins[1], match.wins[2]))

    -- The match is DECIDED the moment a side has the round wins, but the result
    -- card still waits out the between-rounds window: the last round ends the way
    -- every other round ended rather than cutting away mid-kill.
    if winnerSide ~= nil and match.wins[winnerSide] >= match.target then
        match.decided = winnerSide
    elseif match.roundNumber >= match.roundCeiling then
        -- Draws cannot deadlock a match. Nothing in the rules produces an endless
        -- run of them, but "nothing in the rules" is not a bound, and an arena
        -- instance that never releases its bucket is a leak.
        if match.wins[1] == match.wins[2] then
            match.decided = 0
        else
            match.decided = match.wins[1] > match.wins[2] and 1 or 2
        end
        DM.log(("arena %d hit the round ceiling (%d) -- resolving on wins"):format(
            instance.id, match.roundCeiling))
    end
    return true
end

--- Ends the match. Everybody keeps standing where they are for the result card;
--- the lobby comes afterwards, in `dissolve`.
resolveMatch = function(instance, winnerSide, reason)
    local match = instance.match
    if match == nil or match.state == "resolved" then return false end

    local at = DM.nowMs()
    match.state = "resolved"
    match.resultEndsAtMs = at + resultMs()
    match.result = {
        reason = tostring(reason or "best_of"),
        winnerSide = winnerSide or 0,
        wins = { match.wins[1], match.wins[2] },
        rounds = match.roundNumber,
        -- Phase 8. Set by `finishRound`, which is where the writes actually
        -- happen -- one per ROUND, exactly as in a free-for-all, because
        -- `Scoring.beginRound` clears the board at the start of every arena
        -- round and there is therefore no match-level total to write. The taint
        -- is per instance and sticky, so every round of one match answers the
        -- same way and this flag is the whole match's honest answer.
        ranked = match.ranked == true,
    }
    if instance.round ~= nil then instance.round.state = "resolved" end

    -- THE RESULT CARD IS NOT PART OF THE FIGHT, and with bots on the roster it
    -- has to be said rather than assumed. A player stops shooting when the
    -- match ends; a bot does not -- nothing in the engine knows the match has a
    -- result, and this file must not reach into a native-combat body to stop it
    -- (the hands-off rule in bots.lua: no movement task, no look task, no
    -- transform). The lever that does work is the LEDGER, and the mode already
    -- has one that bots respect: `victimShootable` reads
    -- `protectionRemaining`, so a spawn shield covering the card makes every
    -- incoming bot report refuse itself. It is also visible -- the HUD draws
    -- the ring -- so nobody has to guess why they stopped taking damage.
    for _, playerId in ipairs(DM.instances.humans(instance)) do
        DM.holdProtection(playerId, resultMs())
    end

    for _, playerId in ipairs(DM.instances.members(instance)) do
        local side = sideOf(instance, playerId)
        if winnerSide == nil or winnerSide == 0 then
            DM.notice(playerId, "info", "roundDraw")
        elseif side == winnerSide then
            DM.notice(playerId, "success", "matchWon")
        else
            DM.notice(playerId, "warning", "matchLost")
        end
    end

    -- Decision 12, said out loud once per match. The WRITES are per round, in
    -- `finishRound`; this is the sentence the players get, and it is here rather
    -- than there so a best-of-five does not repeat it five times.
    if match.ranked ~= true then
        local module = scoring()
        if module ~= nil and type(module.ladderEligible) == "function"
            and not module.ladderEligible(instance) then
            local ranked = ranking()
            if ranked ~= nil then pcall(ranked.announceExclusion, instance) end
            DM.log(("arena %d will not reach the ladder -- it contained bots"):format(instance.id))
        end
    end

    DM.log(("arena %d (%s) RESOLVED winner=side %s score=%d-%d rounds=%d reason=%s"):format(
        instance.id, match.format, tostring(winnerSide or "draw"),
        match.wins[1], match.wins[2], match.roundNumber, tostring(reason)))
    return true
end

--- The result card is over. Everybody goes home and the bucket is released -- an
--- arena instance is allocated per match and released on the result, which is the
--- whole difference from a free-for-all instance.
local function dissolve(instance, reason)
    local module = scoring()
    -- CLOSING, said before anything is taken apart. Reaping the bots below
    -- re-enters this file through `Arena.participantGone` -- once per body --
    -- and without this flag each of those would run the forfeit rules against a
    -- roster that is being emptied on purpose, resolving a match that has
    -- already resolved. `participantGone` refuses any state but `playing`.
    if instance.match ~= nil then instance.match.state = "closing" end
    -- The bots go first, and explicitly. `tickBot` would reap them within
    -- `tickMs` once the bucket closed -- it destroys any bot whose instance no
    -- longer resolves -- but that leaves a window in which six bodies stand in
    -- a released bucket, and a released bucket is one the kernel may hand to
    -- the next match. Reaping here makes the release the last thing that
    -- happens rather than a race with a tick.
    local module_ = botsModule()
    if module_ ~= nil and type(module_.reap) == "function" then
        pcall(module_.reap, instance.id, reason or "match_over")
    end
    for _, playerId in ipairs(DM.instances.members(instance)) do
        DM.setTeam(playerId, 0)
        DM.strip(playerId, instance)
        if module ~= nil and type(module.removeParticipant) == "function" then
            module.removeParticipant(instance, playerId, reason or "match_over")
        end
        DM.instances.detach(playerId, reason or "match_over")
        DM.sendToLobby(playerId, reason or "match_over")
    end
    DM.instances.close(instance, reason or "match_over")
end


-- =============================================================== formation --

--- Tries to form a match for one size. Returns the instance, or nil.
---
--- Everything that can refuse does so BEFORE anybody is taken out of the queue,
--- so a refusal costs a queued player nothing and the next attempt starts from
--- exactly the same place.
--- May this queue be completed with bots, and why?
---
--- Returns `true, "requested"` for an explicit `/dm.queue <format> bots`;
--- `true, "auto"` when the operator has switched the automatic fill on AND the
--- queue has waited it out; false otherwise.
---
--- SAME SHAPE AS Q5, AND THE SAME ANSWER. The tunable wins over the config
--- value where a tunable host exists, exactly as `DeathmatchBots.backfill`
--- reads it -- and an EXPLICIT request is always honoured regardless, exactly
--- as `/dm.bot fill` is. That asymmetry is the whole design: a production
--- server does not quietly sell a bot as an opponent, and a developer with one
--- machine and a 12 GiB card is not thereby prevented from testing a 3v3 that
--- needs six bodies.
local function botFillAllowed(format, queue, now)
    -- In Freeroam the checkbox is individual consent, not a vote. Do not
    -- silently match a human-only entry against bots requested by a stranger.
    if Config.freeroam then
        for _, entry in ipairs(queue) do
            if entry.bots ~= true then return false, "human_only" end
        end
        return #queue > 0, "requested"
    end
    for _, entry in ipairs(queue) do
        if entry.bots == true then return true, "requested" end
    end

    local live = DM.tune ~= nil and DM.tune.arenaFillWithBots or nil
    local enabled = live
    if enabled == nil then enabled = Config.arena.queue.fillWithBots end
    if enabled ~= true then return false, "disabled" end

    -- The oldest entry is the one whose patience is being measured: it is the
    -- player who has waited longest for a human opponent that has not come.
    local waited = math.max(0, math.floor(Config.arena.queue.botFillAfterMs or 30000))
    local oldest = queue[1]
    if oldest == nil or (now - (oldest.atMs or now)) < waited then
        return false, "waiting"
    end
    return true, "auto"
end

function Arena.tryForm(format)
    local spec = Config.formats[format]
    local queue = queueFor(format)
    if spec == nil or queue == nil then return nil end

    -- Queueing does not own the player's life or vehicle. Revalidate right
    -- before allocating a match, including formations triggered by another
    -- player's enqueue rather than the periodic prune.
    if FreeroamPvp and FreeroamPvp.entryFailure then
        for index = #queue, 1, -1 do
            local id = queue[index].playerId
            local failure = FreeroamPvp.entryFailure(id)
            if failure then
                table.remove(queue, index)
                TriggerClientEvent("deathmatch:notice", id, {
                    kind = "warning", title = "QUEUE CANCELLED", message = failure,
                })
            end
        end
    end

    local capacity = spec.capacity or (spec.teams * spec.teamSize)
    if #queue == 0 then return nil end

    -- ---------------------------------------------------------------- bots --
    --
    -- HOW MANY HUMANS, AND HOW MANY BODIES THE ROSTER IS STILL SHORT. A full
    -- queue forms exactly as it always did -- `botsWanted` is zero and every
    -- line below reduces to the original. A short one forms only when the fill
    -- is allowed, and NEVER with zero humans: an arena of six bots playing
    -- itself in an empty bucket is a VRAM bill, not a match.
    local humansWanted = math.min(#queue, capacity)
    local botsWanted = capacity - humansWanted
    local fillWhy = nil
    if botsWanted > 0 then
        local allowed
        allowed, fillWhy = botFillAllowed(format, queue, DM.nowMs())
        if not allowed then return nil end
        local module = botsModule()
        if module == nil or type(module.addToArena) ~= "function" then
            sayOnce("nobots:" .. format,
                ("arena %s cannot be filled with bots -- server/bots.lua is not loaded"):format(
                    format))
            return nil
        end
    end

    local clusters, missing = clustersFor(format)
    if clusters == nil then
        sayOnce("cluster:" .. format,
            ("arena %s cannot form -- team cluster '%s' is not surveyed yet; run /dm.survey"):format(
                format, tostring(missing)))
        return nil
    end

    local roster = {}
    for index = 1, humansWanted do roster[index] = queue[index].playerId end

    local instance, reason = DM.instances.openArena(format, roster)
    if instance == nil then
        sayOnce("full:" .. format, ("arena %s cannot form -- %s"):format(format, tostring(reason)))
        return nil
    end
    said["full:" .. format] = nil

    -- Committed: only now does anybody leave the queue.
    for _, playerId in ipairs(roster) do removeFrom(format, playerId) end

    -- Alternating the arrival order is the balance rule, and with no rating to
    -- balance on it is the honest one: it splits the queue rather than
    -- pretending to seed it. `Config.arena.queue.rated` is false and the panel
    -- says so rather than implying a skill match that does not exist.
    --
    -- BOTS TAKE THE SLOTS THE HUMANS DID NOT, and the alternation is unchanged:
    -- slot 1 is side 1, slot 2 is side 2, and so on across the WHOLE capacity.
    -- Humans occupy the low slots because they are the ones the queue ordered,
    -- so a 3v3 with one human gives side 1 that human plus two bots and side 2
    -- three bots -- balanced without a second balancing rule to keep in step
    -- with this one.
    local sides = {}
    local rosterBySide = { {}, {} }
    local botSlots = { 0, 0 }
    for index = 1, capacity do
        local side = ((index - 1) % 2) + 1
        local playerId = roster[index]
        if playerId ~= nil then
            sides[playerId] = side
            rosterBySide[side][#rosterBySide[side] + 1] = playerId
        else
            botSlots[side] = botSlots[side] + 1
        end
    end

    local rounds = bestOf(instance)
    local target = math.floor(rounds / 2) + 1
    instance.match = {
        format = format,
        state = "playing",
        bestOf = rounds,
        target = target,
        -- The halfway point, and never past what the match can reach: a swap
        -- scheduled after the last possible round is a swap that never happens.
        swapAfterRounds = math.max(1, math.min(
            math.floor(Config.arena.swapSidesAfterRounds or target), target)),
        roundCeiling = target * 2 + 2,
        sides = sides,
        roster = rosterBySide,
        wins = { 0, 0 },
        aliveByTeam = { 0, 0 },
        eliminated = {},
        clusters = clusters,
        roundNumber = 0,
        decided = nil,
        result = nil,
        -- Bodies asked for and not yet standing. `startRound` holds the buy
        -- window open while this is above zero -- see `step` -- because bots.lua
        -- paces body creation and a 3v3 filled with bots does not become six
        -- bodies on one frame. Decremented as each arrives, never below zero.
        pendingBots = 0,
        -- How many bots this match was formed with, and why. Read only by the
        -- log and by `/dm.arena`; the ladder exclusion does NOT read it -- that
        -- is `Scoring.ladderEligible`, which asks the scoreboard and bots.lua
        -- rather than trusting a number this file keeps.
        bots = 0,
        botFill = fillWhy,
    }

    for _, playerId in ipairs(roster) do
        DM.notice(playerId, "success", "queueMatched", spec.label)
    end
    DM.log(("arena %d formed %s: %d player(s) + %d bot(s) requested (%s), best of %d (first to %d), swap after %d"):format(
        instance.id, format, #roster, botsWanted, tostring(fillWhy or "none"),
        rounds, target, instance.match.swapAfterRounds))

    -- ---------------------------------------------------------------- bots --
    --
    -- REQUESTED AFTER THE MATCH RECORD EXISTS AND BEFORE THE FIRST ROUND, and
    -- both halves of that matter. `onCreated` writes into `match.roster` and
    -- `match.sides`, so the record has to be there; and a bot that arrives
    -- before `startRound` is placed by it like everybody else, which is one
    -- fewer path than placing it here would be.
    --
    -- The cluster handed over is ROUND ONE's, from the same `clusterKey` the
    -- placement uses, so a bot that arrives late still spawns on the end of the
    -- map its side is playing from. `arenaRoundStart` rewrites it every round
    -- after that, which is what makes the halfway swap apply to bots too.
    if botsWanted > 0 then
        local module = botsModule()
        local profile = Config.arena.botProfile
        for side = 1, 2 do
            if botSlots[side] > 0 then
                local cluster = clusters[clusterKey(instance.match, side, 1)]
                instance.match.pendingBots = instance.match.pendingBots + botSlots[side]
                local created, why, queued = module.addToArena(
                    instance.id, side, botSlots[side], cluster, profile,
                    function(participantId, forSide)
                        Arena.adoptBot(instance, participantId, forSide)
                    end)
                if (tonumber(created) or 0) + (tonumber(queued) or 0) < botSlots[side] then
                    -- Short, and said plainly. The match still runs: a side one
                    -- body down is a handicap, and a handicap is a better
                    -- outcome than a format that refuses to start at all.
                    local short = botSlots[side] - (tonumber(created) or 0) - (tonumber(queued) or 0)
                    instance.match.pendingBots = instance.match.pendingBots - short
                    DM.log(("arena %d: side %d is %d bot(s) short (%s)"):format(
                        instance.id, side, short, tostring(why)))
                end
            end
        end
    end

    startRound(instance, "match_start")
    return instance
end

--- A bot body has appeared for a match: put it on the roster.
---
--- Called BY bots.lua, once per body, and possibly after `tryForm` has already
--- returned -- body creation is paced across the whole resource, so a 3v3
--- asking for six bodies gets the tail of them over the following seconds. This
--- is why the roster is written here rather than assumed complete at formation.
---
--- Idempotent on the side tables, so a duplicate callback cannot put one bot on
--- a roster twice.
function Arena.adoptBot(instance, participantId, side)
    local match = instance ~= nil and instance.match or nil
    local id = tonumber(participantId)
    side = math.floor(tonumber(side) or 0)
    if match == nil or id == nil or (side ~= 1 and side ~= 2) then return false end
    id = math.floor(id)
    if match.sides[id] ~= nil then return false end

    match.sides[id] = side
    match.roster[side][#match.roster[side] + 1] = id
    match.bots = (match.bots or 0) + 1
    match.pendingBots = math.max(0, (match.pendingBots or 0) - 1)

    -- The scoreboard already has a row -- `createBot` registered it with the
    -- side -- so this is the team being RE-stated for the same reason it is
    -- re-stated at every round start, and it costs one table write for a bot.
    assignTeam(instance, id, side)
    refreshAlive(instance)
    DM.log(("arena %d: bot %d joined side %d (%d/%d bodies, %d still coming)"):format(
        instance.id, id, side,
        #match.roster[1] + #match.roster[2],
        (Config.formats[match.format] or {}).capacity or 0,
        match.pendingBots))
    return true
end


-- ============================================================== departures --

--- One player leaves an arena match, by any route. `returnToLobby` is false for
--- a disconnect, where there is nobody left to place.
---
--- A side that loses its last body loses the MATCH. That is a forfeit, not a
--- round win: continuing a 2v2 as a 2v0 is not a shorter match, it is a
--- different game.
--- Takes one participant off the roster. PLAYER OR BOT, and the roster surgery
--- is all it does -- no engine call, no scoreboard write, no placement -- so it
--- is safe to run for a body that no longer exists.
---
--- Returns the side they held, or nil when the match never had them.
local function unroster(match, participantId)
    local side = match.sides[participantId]
    if side == nil then return nil end
    match.sides[participantId] = nil
    match.eliminated[participantId] = nil
    local list = match.roster[side]
    for index = #list, 1, -1 do
        if list[index] == participantId then table.remove(list, index) end
    end
    return side
end

--- What follows a participant leaving the roster, whoever they were.
---
--- FACTORED OUT RATHER THAN COPIED, because there are now two ways off a roster
--- -- a player leaving and a bot's body ceasing to exist -- and they must answer
--- the same four questions in the same order. A second copy would be a second
--- set of forfeit rules, and the day they disagreed the match would either
--- resolve twice or not at all.
---
--- `side` is the side the departing participant held, or nil.
local function afterWithdrawal(instance, match, side)
    refreshAlive(instance)
    if match.state ~= "playing" then return true end

    -- NO PEOPLE LEFT, WHATEVER THE ROSTER SAYS. With bots on it, a roster stays
    -- non-empty long after the last person has gone -- a 3v3 whose only human
    -- quits leaves five bots fighting in a bucket nobody can see, holding an
    -- arena slot and about two and a half gigabytes of VRAM per body's worth of
    -- client streaming for as long as the best-of runs. The bots exist to fill
    -- a match a player is in; with no player there is no match.
    if #DM.instances.humans(instance) == 0 then
        DM.log(("arena %d: no players left; closing a match of %d bot(s)"):format(
            instance.id, #match.roster[1] + #match.roster[2]))
        dissolve(instance, "no_players_left")
        return true
    end

    local left, right = #match.roster[1], #match.roster[2]
    if left == 0 and right == 0 then
        DM.instances.close(instance, "everyone_left")
        return true
    end
    if left == 0 or right == 0 then
        resolveMatch(instance, left == 0 and 2 or 1, "opponents_left")
        return true
    end

    -- A side emptied of LIVING bodies mid-round still loses the round the normal
    -- way, so a disconnect at the wrong moment is not a different rule from a
    -- death at the wrong moment.
    local round = instance.round
    if round ~= nil and round.state == "active" and side ~= nil
        and match.aliveByTeam[side] == 0 then
        finishRound(instance, other(side), "team_wiped")
    end
    return true
end

local function departed(instance, playerId, reason, returnToLobby)
    local match = instance.match
    if match == nil then return false end
    local side = unroster(match, playerId)

    -- The row survives: standings that erase somebody at the moment they quit
    -- rewrite the round the survivors just played.
    local module = scoring()
    if module ~= nil and type(module.removeParticipant) == "function" then
        module.removeParticipant(instance, playerId, reason or "left")
    end

    DM.setTeam(playerId, 0)
    if returnToLobby then DM.strip(playerId, instance) end
    DM.instances.detach(playerId, reason or "left")
    if returnToLobby then
        DM.sendToLobby(playerId, reason or "left_match")
        DM.notice(playerId, "info", "leftMatch")
    end

    return afterWithdrawal(instance, match, side)
end

--- A BOT'S BODY HAS CEASED TO EXIST. Called by bots.lua's `removeParticipant`
--- host hook, which is the one funnel every disappearance goes through:
--- `/dm.bot clear`, the instance closing, a body the client reaped
--- (`npc_vanished`), and the platform's own `onNpcRemoved`.
---
--- WHY IT IS NOT ENOUGH TO LET THE BODY SIMPLY BE ABSENT. Measured in game on
--- 2026-09-01: `dm.bot clear all` during a live 1v1 left `alive 1-1`, `bots=1`
--- and `side 2: BOT 1 [BOT]` on the roster with nothing standing in the world.
--- `present` was already answering correctly -- it asks bots.lua whether the bot
--- exists -- but `aliveByTeam` is a CACHE that only `refreshAlive` moves, and
--- nothing was moving it: a destroyed bot raises no death, so `Arena.onDeath`
--- never ran. Side 2 could not be wiped, every round went the full 120 s to a
--- `time_limit` draw, and the best-of never resolved.
---
--- The treatment is the one a player already gets for leaving, and for the same
--- reason: a body that is gone is gone for good -- `destroyBot` never recreates
--- a participant, and the transient case (a body reaped underneath us) goes
--- through `releaseBody`, which KEEPS the participant. So this drops the roster
--- entry outright rather than merely marking it eliminated, which also stops the
--- ghost reappearing in the next round's placement.
---
--- `step`'s per-tick check is the backstop behind this, and it is deliberately
--- kept: an event can be missed, and the invariant -- a side is never reported
--- alive while it holds no bodies -- must not depend on one.
function Arena.participantGone(instanceId, participantId, reason)
    local id = tonumber(participantId)
    if id == nil then return false end
    id = math.floor(id)

    local registry = DM.instances.registry
    local instance = type(registry) == "table" and registry[tonumber(instanceId) or -1] or nil
    if instance == nil or instance.closed then return false end
    local match = instance.match
    -- Only a match in progress cares. `dissolve` marks the match `closing`
    -- BEFORE it reaps the bots, so the reap cannot re-enter the forfeit rules of
    -- a match that is already being taken apart.
    if match == nil or match.state ~= "playing" then return false end

    local side = unroster(match, id)
    if side == nil then return false end
    if id < 0 then match.bots = math.max(0, (match.bots or 1) - 1) end

    DM.log(("arena %d: participant %d left side %d without dying (%s); side sizes now %d-%d"):format(
        instance.id, id, side, tostring(reason),
        #match.roster[1], #match.roster[2]))
    return afterWithdrawal(instance, match, side)
end

--- Which side of a live arena match a participant holds -- PLAYER OR BOT -- or
--- nil when they are in no match.
---
--- THE ONE ANSWER TO "ARE THESE TWO TEAM-MATES", and it has to be, because
--- three different damage paths ask it and they must not be able to disagree.
--- `Open77.combat.setTeam` cancels friendly fire between PLAYERS inside the
--- platform's arbiter; the two paths a bot is on -- `Open77.players.damage` for
--- bot -> player and `Open77.npcs.applyDamage` for player -> bot and bot -> bot
--- -- do not travel it, so bots.lua gates them on this instead (see
--- `sameArenaSide` there).
---
--- Not a lookup table: `match.sides` is already the index, and the only work
--- here is finding the match. A player is found through the kernel's player
--- index; a bot through the instance id on its own record, because a bot is
--- bound to an instance as an ACTOR and `Instances.of` answers only for
--- players.
function Arena.sideOf(participantId)
    local id = tonumber(participantId)
    if id == nil then return nil end
    id = math.floor(id)

    local instance
    if id > 0 then
        instance = DM.instances.of(id)
    else
        local module = botsModule()
        local bot = module ~= nil and type(module.get) == "function"
            and module.get(id) or nil
        local instanceId = bot ~= nil and tonumber(bot.instanceId) or nil
        local registry = DM.instances.registry
        instance = instanceId ~= nil and type(registry) == "table"
            and registry[instanceId] or nil
    end
    if instance == nil or instance.closed then return nil end
    local match = instance.match
    return match ~= nil and match.sides[id] or nil
end

--- Explicit departure: the player asked to leave (R7).
function Arena.leave(playerId, reason)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    local instance = DM.instances.of(playerId)
    if instance == nil or instance.format == "ffa" then return false end
    return departed(instance, playerId, reason or "player_left", true)
end

--- Disconnect (R8). Called BEFORE the kernel detaches, which is why the ordering
--- in R8 matters: after a detach there is no way to tell which side lost a body.
function Arena.forget(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    local _, format = Arena.queuePosition(playerId)
    if format ~= nil then removeFrom(format, playerId) end
    local instance = DM.instances.of(playerId)
    if instance ~= nil and instance.format ~= "ffa" then
        departed(instance, playerId, "disconnected", false)
    end
end


-- =================================================================== death --

--- A death inside an arena round is an ELIMINATION. Nothing is placed, nothing
--- is scheduled, and the body stays dead in the match's bucket for the rest of
--- the round -- which is what spectating your team is, mechanically. The life
--- ledger is the authority on that and it is deliberately not overruled.
---
--- A 1v1 with respawns is a race to a number where whoever is ahead can trade
--- down to the win; this is the rule that makes the small formats a duel, a
--- trade-and-clutch and a site fight instead of three shorter free-for-alls.
---
--- Called BY scoring.lua through the handler round.lua registers, so the death
--- has already cleared the placement-suppression window -- which matters more
--- here than anywhere else in the mode, because a round start places every
--- player at once and counting one of those would wipe a team on its first
--- millisecond.
function Arena.onDeath(instance, victimId, killerId, info)
    local match = instance ~= nil and instance.match or nil
    local round = instance ~= nil and instance.round or nil
    if match == nil or round == nil or round.state ~= "active" then return false end
    -- `present`, not `instance.members`. A BOT reaches this handler too --
    -- scoring.lua routes `creditKill` through the same death handler for a bot
    -- victim -- and a bot is bound to the instance as an ACTOR, never as a
    -- member, so the old test refused every bot elimination and a side of bots
    -- could never be wiped.
    if not present(instance, victimId) then return false end
    if match.eliminated[victimId] then return false end

    match.eliminated[victimId] = true
    DM.holdProtection(victimId, 0)
    if victimId > 0 then DM.notice(victimId, "warning", "eliminated") end

    local side = sideOf(instance, victimId)
    refreshAlive(instance)
    if side ~= nil and match.aliveByTeam[side] == 0 then
        finishRound(instance, other(side), "team_wiped")
    end
    return true
end


-- ------------------------------------------------------------ the buy window --

--- The kit pick main.lua routes `deathmatch:kit` to.
---
--- The WINDOW is this file's -- it is a round phase, and only the round knows
--- whether it is open. The CHOICE is loadout.lua's, which also registers
--- `deathmatch:pickKit` for the same act, validates the key against the shipped
--- list and never trusts a record a client names. So this is a gate in front of
--- one writer, not a second writer.
function Arena.pickKit(playerId, kitKey)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end

    local instance = DM.instances.of(playerId)
    if instance == nil or instance.match == nil then return false end
    local round = instance.round
    if round == nil or round.state ~= "buy" then return false end

    local kit = DM.loadout
    if type(kit) ~= "table" or type(kit.chooseKit) ~= "function" then return false end
    return kit.chooseKit(playerId, kitKey) == true
end


-- ==================================================================== tick --

local function step(instance, now)
    local match = instance.match
    local round = instance.round

    -- An adopted arena bucket comes back from a hot reload with no format and no
    -- match: the KIND is recoverable from the bucket number, the round is not.
    -- There is nothing to resume, so the honest answer is to send the players
    -- home rather than to invent a score.
    if match == nil then
        if instance.memberCount > 0 then
            sayOnce("orphan:" .. instance.id,
                ("arena %d has no match record (adopted after a reload) -- returning %d player(s) to the lobby"):format(
                    instance.id, instance.memberCount))
            dissolve(instance, "match_state_lost")
        else
            DM.instances.close(instance, "match_state_lost")
        end
        return
    end

    if match.state == "resolved" then
        if now >= match.resultEndsAtMs then dissolve(instance, "match_over") end
        return
    end

    if round == nil then
        startRound(instance, "recovered")
        return
    end

    if round.state == "buy" then
        if now >= round.buyEndsAtMs then
            -- THE BUY WINDOW DOUBLES AS THE ROSTER'S GRACE PERIOD, and only
            -- while a body is still on its way. bots.lua paces creation across
            -- the whole resource -- 400 ms apart, and five seconds of settling
            -- after a reload -- so a 3v3 filled with bots does not become six
            -- bodies on one frame. Going live with a side that has nobody
            -- standing on it hands the other side the round on the timer and
            -- reads exactly like a broken format.
            --
            -- `rosterDeadlineMs` is what stops that being unbounded: a body
            -- that is never coming costs the match `botFillGraceMs` and then
            -- the round starts a body down, which is honest and is logged.
            local waiting = (match.pendingBots or 0) > 0
                and now < (round.rosterDeadlineMs or 0)
            if waiting then
                -- Said once per round, and the flag lives on the ROUND rather
                -- than in `said`: that table is never cleared, and a key per
                -- instance per round would grow for as long as the server runs.
                if not round.rosterHoldLogged then
                    round.rosterHoldLogged = true
                    DM.log(("arena %d round %d: holding the buy window for %d bot(s) still spawning"):format(
                        instance.id, round.number, match.pendingBots))
                end
            else
                if (match.pendingBots or 0) > 0 then
                    DM.log(("arena %d round %d: starting %d body(ies) short -- the roster did not complete in %d ms"):format(
                        instance.id, round.number, match.pendingBots,
                        math.max(0, math.floor(Config.arena.botFillGraceMs or 15000))))
                    match.pendingBots = 0
                end
                goLive(instance, now)
            end
        end
    elseif round.state == "active" then
        -- ================================================================
        -- THE INVARIANT: a side is never reported alive while it holds no
        -- bodies. Checked here, every tick, and NOT only where a body is
        -- known to have gone.
        -- ================================================================
        --
        -- `Arena.participantGone` is the event that should always fire first,
        -- and this is the backstop behind it. Both exist on purpose. Measured in
        -- game on 2026-09-01: `dm.bot clear all` mid-round left the roster
        -- claiming `alive 1-1` with one of those two bodies removed from the
        -- world, so the round could not end by elimination and ran its full
        -- 120 s to a draw -- a best-of-five in that state never resolves.
        --
        -- The event fixes the case we know about; this fixes the shape. Every
        -- other route to a vanished body -- an instance closing underneath a
        -- bot, the client reaping one (`npc_vanished`), a platform removal, or
        -- a roster that never completed because a spawn was refused -- has the
        -- same failure mode, and a rule that has to be re-derived at each new
        -- call site is a rule that will eventually be missed at one.
        --
        -- IT IS CHEAP AND IT IS A NO-OP FOR PLAYERS. `refreshAlive` walks at
        -- most six roster entries, and for a human side it reads the same two
        -- tables (`instance.members`, `match.eliminated`) that `Arena.onDeath`
        -- and `departed` have already refreshed -- so nothing here can fire that
        -- those two did not already handle. `present` is what makes it work for
        -- bots: it asks bots.lua whether the body exists rather than trusting
        -- the roster.
        local alive = refreshAlive(instance)
        if alive[1] == 0 or alive[2] == 0 then
            -- Both at zero is a real outcome, not an impossible one: two bodies
            -- can go down inside the same tick. It is scored as a DRAW rather
            -- than awarded to whichever side the loop happened to test first,
            -- which is the same answer the time limit gives when the counts are
            -- equal.
            local winner = nil
            if alive[1] > 0 then winner = 1 elseif alive[2] > 0 then winner = 2 end
            local empty = winner == nil and 0 or other(winner)
            local why = "team_wiped"
            if winner == nil then why = "mutual_wipe"
            elseif #match.roster[empty] == 0 then why = "side_empty" end
            DM.log(("arena %d round %d: alive %d-%d with the round live (%s) -- scoring it now"):format(
                instance.id, round.number, alive[1], alive[2], why))
            finishRound(instance, winner, why)
            return
        end

        if now >= round.endsAtMs then
            -- On the timer, the side with more bodies still standing takes the
            -- round. Equal is a draw: there is no health total to break it on
            -- that both teams could have seen.
            local alive = match.aliveByTeam
            local winner = nil
            if alive[1] > alive[2] then winner = 1
            elseif alive[2] > alive[1] then winner = 2 end
            finishRound(instance, winner, "time_limit")
        end
    elseif round.state == "between" then
        if now >= round.betweenEndsAtMs then
            if match.decided ~= nil then
                resolveMatch(instance, match.decided, "best_of")
            else
                startRound(instance, "next_round")
            end
        end
    end
end

--- Called from main.lua's tick (R9). Walks the KERNEL'S registry rather than a
--- table this file holds: a hot reload empties whatever this VM was holding
--- while the instances, the buckets and the players inside them live on.
function Arena.tick(now)
    now = now or DM.nowMs()

    prune(now)
    for _, format in ipairs(formatOrder) do Arena.tryForm(format) end

    local registry = DM.instances.registry
    if type(registry) ~= "table" then return end
    -- Collected first: `dissolve` closes instances, which mutates the registry.
    local live = {}
    for _, instance in pairs(registry) do
        if not instance.closed and instance.kind == "arena" then
            live[#live + 1] = instance
        end
    end
    for _, instance in ipairs(live) do
        if not instance.closed then step(instance, now) end
    end
end


-- ================================================================= readout --

--- One side's roster, as the HUD needs to read it: who is on it, and which of
--- them are still in the round.
---
--- THE HUD CANNOT DERIVE THIS FROM THE STANDINGS and that is why it is here.
--- `Deathmatch.scoring.rows` carries a `team` and an `active`, but `active`
--- means "still a member of the instance" -- it is false for someone who
--- disconnected and TRUE for someone who was shot thirty seconds ago. In an
--- elimination round the question a player asks the screen is "how many of us
--- are left", and only `match.eliminated` answers it.
---
--- `eliminated` and `alive` are BOTH sent and they are not each other's
--- negation: a player who left the server is neither eliminated nor alive, and
--- collapsing the two would make a disconnect look like a kill.
local function rosterFor(instance, match, side)
    local rows = {}
    for _, participantId in ipairs(match.roster[side]) do
        local bot = isBotId(participantId)
        local connected = present(instance, participantId)
        local eliminated = match.eliminated[participantId] == true
        rows[#rows + 1] = {
            id = participantId,
            -- `Open77.players.name` RAISES on a non-positive id and the
            -- exception unwinds through `pcall` and stops the resource, so a
            -- bot must never reach it. `DM.playerName` is the guarded door and
            -- resolves a bot's callsign through scoring.lua on the way.
            name = bot and DM.playerName(participantId)
                or (Open77.players.name(participantId) or ""),
            connected = connected,
            eliminated = eliminated,
            -- `standing`, not `connected and not eliminated`. They agree for a
            -- player and they can disagree for a bot: a body that is dead in
            -- bots.lua but whose elimination event has not landed would read as
            -- alive here, and the HUD would show a survivor who is on the floor.
            -- The count the round is decided on and the count the page draws
            -- must come from the same predicate or one of them is a lie.
            alive = standing(instance, match, participantId),
            -- Decision 12, rule 1 of section 8: bots are LABELLED, visibly,
            -- everywhere they appear. This field was shipped as a constant
            -- `false` against exactly this day, so that the HUD would need no
            -- change when bots started holding a side. It needed none.
            bot = bot,
        }
    end
    return rows
end

--- The arena half of the state push, merged over main.lua's payload by
--- `Deathmatch.fragmentFor` (R10).
function Arena.stateFor(instance, playerId)
    local match = instance.match
    local round = instance.round
    local now = DM.nowMs()
    local summary = DM.instances.summary()

    local fragment = {
        mode = instance.format or "arena",
        phase = round and round.state or "resolved",
        playerState = "active",
        instanceId = instance.id,
        instanceBucket = instance.bucket,
        instanceCapacity = instance.capacity,
        instancePlayers = instance.memberCount,
        instanceCount = summary.arenaInstances,
        canJoin = false,
        canLeaveMatch = true,
        protectionMs = DM.protectionRemaining(playerId, now),
    }
    if match == nil then return fragment end

    local side = match.sides[playerId] or 1
    local eliminated = match.eliminated[playerId] == true
    if eliminated then fragment.playerState = "eliminated" end
    if match.state == "resolved" then
        fragment.phase = "resolved"
        fragment.result = match.result
        fragment.remainingMs = math.max(0, math.floor(match.resultEndsAtMs - now))
    end

    local kit = DM.loadout
    local roundNumber = math.max(1, match.roundNumber)
    local spec = Config.formats[match.format]
    fragment.arena = {
        side = side,
        eliminated = eliminated,
        round = match.roundNumber,
        wins = { match.wins[1], match.wins[2] },
        aliveByTeam = { match.aliveByTeam[1], match.aliveByTeam[2] },
        bestOf = match.bestOf,
        target = match.target,
        swapAfterRounds = match.swapAfterRounds,
        spawnCluster = clusterKey(match, side, roundNumber),

        -- ------------------------------------------------------- the HUD --
        --
        -- Everything below exists because `resources/gamemodes/open77_deathmatch_hud/
        -- web/match.js` had no arena surface at all: it rendered the
        -- free-for-all scoreboard over an elimination match, and its footer
        -- read "FIRST TO 25 ELIMINATIONS" because the fragment carried no
        -- `killLimit` and the page fell back to its own literal default. An
        -- elimination format has no kill limit and never will; what it has is
        -- a round tally, and `bestOf` / `target` above are that number.
        --
        -- `format` is the KEY ("1v1"), which is what the page keys its layout
        -- on; `label` is the word ("Duel"), which is what it prints. Sending
        -- both keeps display language out of the page's logic and match logic
        -- out of its copy.
        format = match.format,
        label = spec ~= nil and spec.label or match.format,
        perSide = spec ~= nil and spec.teamSize or nil,

        -- SIDE IS NOT SPAWN CLUSTER (see the header). `swapped` says which end
        -- of the map the sides are playing from THIS round -- it is the same
        -- predicate `clusterKey` uses, published rather than recomputed on the
        -- page, so the indicator and the spawns can never disagree.
        swapped = roundNumber > match.swapAfterRounds,

        -- Two rosters, indexed by side, in roster order. This is the whole of
        -- "who is left", and in an elimination format it is the primary read.
        roster = { rosterFor(instance, match, 1), rosterFor(instance, match, 2) },
    }
    if type(kit) == "table" then
        if type(kit.kitFor) == "function" then
            local chosen = kit.kitFor(instance, playerId)
            fragment.arena.kit = chosen and chosen.key or Config.kits.default
        end
        -- The buy list carries keys and labels only; records stay on the server,
        -- because a client has no use for a TweakDB record and publishing one
        -- invites it to ask for another.
        if round ~= nil and round.state == "buy" and type(kit.kitList) == "function" then
            fragment.arena.kits = kit.kitList()
        end
    end

    if round ~= nil and match.state ~= "resolved" then
        local deadline = nil
        if round.state == "buy" then deadline = round.buyEndsAtMs
        elseif round.state == "active" then deadline = round.endsAtMs
        elseif round.state == "between" then deadline = round.betweenEndsAtMs end
        if deadline ~= nil then
            fragment.remainingMs = math.max(0, math.floor(deadline - now))
        end
    end

    -- Deliberately NO `death` card. There is no respawn to count down to inside
    -- an elimination round, and a countdown that never fires is worse than no
    -- countdown at all.
    return fragment
end

--- What a player standing in the lobby is told about the queues. Merged into the
--- lobby fragment by round.lua.
function Arena.lobbyFragment(playerId)
    local fragment = { arenaQueue = Arena.queueCounts() }
    local position, format = Arena.queuePosition(playerId)
    if format ~= nil then
        fragment.playerState = "queued"
        fragment.queueFormat = format
        fragment.queuePosition = position
        fragment.queueRated = Config.arena.queue.rated == true
    end
    return fragment
end

function Arena.describe()
    local parts = {}
    for _, format in ipairs(formatOrder) do
        local queue = queues[format]
        local wanted = false
        for _, entry in ipairs(queue) do
            if entry.bots == true then wanted = true break end
        end
        parts[#parts + 1] = ("%s %d queued%s"):format(
            format, #queue, wanted and " (bots)" or "")
    end
    local live = DM.tune ~= nil and DM.tune.arenaFillWithBots or nil
    if live == nil then live = Config.arena.queue.fillWithBots end
    parts[#parts + 1] = ("autofill=%s"):format(tostring(live == true))
    return table.concat(parts, "  ")
end


-- ============================================================ the HUD mock --
--
-- WHY THIS EXISTS, and it is not a convenience.
--
-- No arena format can start on this build. `Arena.cluster` returns nil the
-- moment any mark in a cluster has no position, and all twelve team marks in
-- `shared/kabuki.lua` are `position = nil` -- so `clustersFor` answers nil for
-- 1v1, 2v2 and 3v3 alike and `tryForm` never forms anything. That is a SURVEY
-- gap, not a code gap: twelve coordinates fix it and nothing else will.
--
-- Which leaves the arena HUD surface in an impossible position. It cannot be
-- seen, so it cannot be checked, so it would ship on the strength of somebody
-- having read the JavaScript. This command closes that: it pushes a fragment
-- shaped EXACTLY like the one `Arena.stateFor` builds, so the page renders from
-- the same data it will receive on the day the marks exist.
--
-- WHAT IT DOES NOT PROVE, said plainly rather than left to be discovered:
-- nothing about matchmaking, placement, elimination, the side swap actually
-- moving anybody, or the buy window actually issuing a kit. It proves the
-- SURFACE -- that every field is read, that the layout holds at one, two and
-- three per side, and that an elimination format never again prints a kill
-- limit. Everything behind the fragment stays unverified until the survey.
--
-- It is restricted, it changes no world state, it moves nobody, and it expires.

local MOCK_LIFETIME_MS = 300000     -- five minutes; an operator forgets

-- Enough names to fill a 3v3 twice over, and deliberately not player-like:
-- somebody reading a screenshot has to be able to tell a mock from a match.
local MOCK_NAMES = {
    { "MOCK_ALFA", "MOCK_BRAVO", "MOCK_CHARLIE" },
    { "MOCK_DELTA", "MOCK_ECHO", "MOCK_FOXTROT" },
}

local mocks = {}   -- playerId -> { format, phase, round, startedMs, endsAtMs }

local function mockRoster(spec, mock, side, playerId)
    local rows = {}
    for index = 1, (spec.teamSize or 1) do
        -- Slot 1 of side 1 is the caller, so `isSelf` resolves on the page and
        -- the self-highlight, the team colour and the eliminated treatment are
        -- all exercised against a real id rather than an invented one.
        local mine = side == 1 and index == 1
        local eliminated = false
        if mock.phase == "active" or mock.phase == "between" or mock.phase == "resolved" then
            -- One down on each side from the second slot on, so the roster shows
            -- both states at every size that has room for both. A 1v1 keeps
            -- everybody alive, because a 1v1 with one player eliminated is a
            -- round that has already ended.
            eliminated = index > 1 and (index + side) % 2 == 0
        end
        rows[#rows + 1] = {
            id = mine and playerId or (90000 + side * 10 + index),
            name = mine and (Open77.players.name(playerId) or "YOU")
                or MOCK_NAMES[side][index],
            connected = true,
            eliminated = eliminated,
            alive = not eliminated,
            bot = false,
        }
    end
    return rows
end

local function aliveIn(rows)
    local count = 0
    for _, row in ipairs(rows) do if row.alive then count = count + 1 end end
    return count
end

--- The whole synthetic push, rebuilt on every call so the clock runs.
---
--- This is `stateFor`'s output, not `Arena.stateFor`'s: main.lua overlays
--- `participant`, `rows`, `self` and `instance` onto the fragment from the
--- registry, and a mock player is in no instance, so a fragment-level mock
--- would arrive at the page with `participant = false` and draw nothing. The
--- hook is therefore in `pushState`, and this returns the finished payload.
function Arena.mockStateFor(playerId)
    playerId = DM.playerId(playerId)
    local mock = playerId ~= nil and mocks[playerId] or nil
    if mock == nil then return nil end

    local now = DM.nowMs()
    if now >= mock.endsAtMs then
        mocks[playerId] = nil
        DM.log(("arena mock expired for player %d"):format(playerId))
        return nil
    end

    local spec = Config.formats[mock.format]
    local roster = { mockRoster(spec, mock, 1, playerId), mockRoster(spec, mock, 2, playerId) }
    local target = math.floor(mock.bestOf / 2) + 1

    -- The phase clock, counted down from the phase's own configured length so
    -- the number on screen is the number the real round would show.
    local windowMs = 1000 * (
        mock.phase == "buy" and Config.arena.buySeconds
        or mock.phase == "between" and Config.arena.betweenRoundsSeconds
        or mock.phase == "resolved" and Config.arena.resultSeconds
        or Config.arena.roundSeconds)
    local elapsed = (now - mock.startedMs) % windowMs

    -- Standings rows, so TAB over a mock shows the same scoreboard an arena
    -- match will. Kills are derived from the roster rather than invented per
    -- push: a number that changes every 500 ms reads as a bug.
    local rows, rank = {}, 0
    for side = 1, 2 do
        for index, member in ipairs(roster[side]) do
            rank = rank + 1
            rows[#rows + 1] = {
                id = member.id, name = member.name, rank = rank,
                kills = (4 - index) + side, deaths = index, assists = 0,
                damage = 100 * ((4 - index) + side), score = 100 * ((4 - index) + side),
                streak = 0, bestStreak = 1, team = side, bot = false,
                connected = true, active = member.alive,
            }
        end
    end

    local mine = rows[1]
    return {
        playerId = playerId,
        mode = mock.format,
        phase = mock.phase,
        playerState = "active",
        remainingMs = math.max(0, windowMs - elapsed),
        participant = true,
        participantCount = #rows,
        maxPlayers = spec.capacity,
        canJoin = false,
        canLeaveMatch = true,
        protectionMs = 0,
        crosshair = true,
        queuedNext = false,
        instanceId = 0,
        instance = {
            id = 0, label = "MOCK", format = mock.format,
            players = #rows, bots = 0, capacity = spec.capacity,
        },
        matchId = ("mock-%s-%d"):format(mock.format, mock.round),
        rows = rows,
        self = {
            id = playerId, name = mine.name, team = 1, rank = 1,
            kills = mine.kills, deaths = mine.deaths, assists = 0,
            damage = mine.damage, score = mine.score, streak = 0, bestStreak = 1,
            bot = false, protection = { remainingMs = 0, totalMs = 0 },
        },
        arenaQueue = Arena.queueCounts(),
        arena = {
            side = 1,
            eliminated = false,
            round = mock.round,
            wins = { mock.wins[1], mock.wins[2] },
            aliveByTeam = { aliveIn(roster[1]), aliveIn(roster[2]) },
            bestOf = mock.bestOf,
            target = target,
            swapAfterRounds = Config.arena.swapSidesAfterRounds,
            spawnCluster = mock.round > Config.arena.swapSidesAfterRounds and "b" or "a",
            format = mock.format,
            label = spec.label,
            perSide = spec.teamSize,
            swapped = mock.round > Config.arena.swapSidesAfterRounds,
            roster = roster,
            kit = Config.kits ~= nil and Config.kits.default or nil,
            kits = mock.phase == "buy" and type(DM.loadout) == "table"
                and type(DM.loadout.kitList) == "function" and DM.loadout.kitList() or nil,
        },
    }
end


-- --------------------------------------------------------------- commands --

local function output(source, raw, ok, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

-- /dm.arena.mock <1v1|2v2|3v3> [buy|active|between|resolved] [round] -- paint
-- the arena HUD from a synthetic fragment, for as long as it takes to look at
-- it. `/dm.arena.mock off` stops; it also stops by itself after five minutes.
--
-- Restricted, like every other development verb in this resource. It writes no
-- world state at all: no placement, no bucket change, no team, no damage. The
-- ONLY thing it touches is what this one caller's own HUD is told, and it stops
-- touching that the moment it is switched off.
--
-- `round` is the argument worth knowing about: pass a number greater than
-- `Config.arena.swapSidesAfterRounds` (3 by default) and the surface renders in
-- its swapped state, which is otherwise unreachable without a live match.
local MOCK_PHASES = { buy = true, active = true, between = true, resolved = true }

RegisterCommand("dm.arena.mock", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, Config.strings.error.playerOnly)
    end

    local format = string.lower(tostring(args[1] or ""))
    if format == "off" or format == "stop" or format == "clear" then
        mocks[source] = nil
        return output(source, raw, true,
            "arena HUD mock off -- your surface is back on the real state push")
    end

    local spec = Config.formats[format]
    if spec == nil or spec.queued ~= true then
        return output(source, raw, false,
            "usage: dm.arena.mock <1v1|2v2|3v3> [buy|active|between|resolved] [round] | off")
    end

    local phase = string.lower(tostring(args[2] or "active"))
    if not MOCK_PHASES[phase] then
        return output(source, raw, false,
            ("unknown phase '%s' -- one of buy, active, between, resolved"):format(phase))
    end

    local bestOf = math.max(1, math.floor(tonumber(Config.arena.bestOf) or 5))
    local round = math.max(1, math.floor(tonumber(args[3]) or 1))

    -- The tally is derived from the round number rather than taken as a fourth
    -- argument, so it can never describe a match that could not have happened:
    -- round 4 of a best of 5 has had three results, and three results is
    -- exactly what these two numbers add up to.
    local played = round - 1
    local winsA = math.min(math.ceil(played / 2), math.floor(bestOf / 2) + 1)
    local wins = { winsA, played - winsA }

    local now = DM.nowMs()
    mocks[source] = {
        format = format, phase = phase, round = round, bestOf = bestOf,
        wins = wins, startedMs = now, endsAtMs = now + MOCK_LIFETIME_MS,
    }

    output(source, raw, true, ("arena HUD mock ON -- %s, %s, round %d of best of %d, %d-%d%s. " ..
        "Expires in %d s; 'dm.arena.mock off' to stop."):format(
        format, phase, round, bestOf, wins[1], wins[2],
        round > (Config.arena.swapSidesAfterRounds or 3) and ", sides swapped" or "",
        MOCK_LIFETIME_MS / 1000))
end, true)

-- /dm.queue <1v1|2v2|3v3> [bots|nobots] [player=<id>]
-- /dm.queue leave [player=<id>]
-- /dm.queue status
--
-- THE ARENA'S ENTRY POINT THAT IS NOT A SURFACE, and it is the reason this
-- command exists at all. Queueing had exactly two doors -- the `/dm` panel and
-- the world station -- and both of them are the HUD. `RegisterCommand("dm.arena")`
-- looked like a third and is not: it takes no verb and only prints. So an
-- agent, a test harness or an operator on the console could read the queues and
-- could not enter one, which meant the whole of Phase 6 could only ever be
-- exercised by a human holding a controller. With `bots`, this one command
-- takes a format from an empty queue to a finished match on its own.
--
-- UNRESTRICTED, and self-only for a player -- the same shape as `/dm.where` and
-- `/dm.stats`, and for the same reason. Queueing yourself is the feature, not an
-- operator verb. `player=<id>` is accepted ONLY from the server console, which
-- is privileged by definition and has no position of its own to queue; a player
-- who passes it is told to use the panel rather than silently queueing somebody
-- else. `RegisterCommand`'s third argument is per COMMAND and not per
-- invocation, so this is the only way to have both without either exposing the
-- id form to everybody or hiding the plain form from its owner.
--
-- `bots` is EXPLICIT CONSENT, and it is honoured whatever the server's
-- `arenaFillWithBots` says -- exactly as `/dm.bot fill` is honoured whatever
-- `fillWithBots` says. A round containing a bot never reaches the ladder
-- (decision 12), so nothing can be farmed with it.
local function parseQueueArgs(args)
    local parsed = { format = nil, bots = nil, player = nil }
    for index = 1, (args.n or #args) do
        local token = tostring(args[index] or ""):lower()
        local named = token:match("^player=(.+)$")
        if named ~= nil then
            parsed.player = DM.finite(named)
        elseif token == "bots" or token == "fill" then
            parsed.bots = true
        elseif token == "nobots" or token == "wait" then
            parsed.bots = false
        elseif token ~= "" and parsed.format == nil then
            parsed.format = token
        elseif tonumber(token) ~= nil and parsed.player == nil then
            -- A bare trailing number, for a console that finds `player=1`
            -- fussy. Only ever read as an id because `format` is already taken
            -- by then and no format is a number.
            parsed.player = DM.finite(token)
        end
    end
    return parsed
end

RegisterCommand("dm.queue", function(source, args, raw)
    local caller = DM.playerId(source)
    local parsed = parseQueueArgs(args)
    local verb = parsed.format or "status"

    local function usage(ok)
        output(source, raw, ok == true,
            "usage: dm.queue <1v1|2v2|3v3> [bots|nobots]   -- enter a queue; 'bots' completes the roster")
        output(source, raw, ok == true,
            "       dm.queue leave                          -- leave the queue, or forfeit the match")
        output(source, raw, ok == true,
            "       dm.queue status                         -- queue depths and running matches")
        if caller == nil then
            output(source, raw, ok == true,
                "       from the console, add player=<id> -- the console has nobody to queue")
        end
        return false
    end

    if verb == "status" or verb == "" then
        output(source, raw, true, "arena queues -- " .. Arena.describe())
        return true
    end

    -- Whose queue entry this is about. A player is always themselves; the
    -- console must say.
    local subject = caller
    if parsed.player ~= nil then
        if caller ~= nil then
            return output(source, raw, false,
                "dm.queue queues YOU. Ask the other player to run it, or use the console.")
        end
        subject = DM.playerId(parsed.player)
        if subject == nil then
            return output(source, raw, false, "dm.queue -- give a positive player id")
        end
    end
    if subject == nil then return usage(false) end

    if verb == "leave" or verb == "off" or verb == "stop" then
        -- One call answers all three cases -- a queue entry, a free-for-all
        -- instance, a live arena match -- and answers "none of them" by doing
        -- nothing. Deliberately NOT `Arena.dequeue`: a player who typed
        -- `dm.queue leave` mid-match means the match.
        local left = DM.leave(subject, "auto")
        return output(source, raw, true, left
            and ("player %d left the queue or the match"):format(subject)
            or ("player %d was in no queue and no match"):format(subject))
    end

    local spec = Config.formats[verb]
    if spec == nil or spec.queued ~= true then return usage(false) end

    local position, reason = Arena.enqueue(subject, verb, parsed.bots == true)
    if position == nil then
        return output(source, raw, false,
            ("dm.queue %s refused for player %d: %s"):format(verb, subject, tostring(reason)))
    end

    -- The formation already ran inside `enqueue`, so by the time this line is
    -- printed the match may exist. Say which of the two happened rather than
    -- always reporting a queue position the player is no longer standing in.
    local instance = DM.instances.of(subject)
    if instance ~= nil and instance.match ~= nil then
        local match = instance.match
        return output(source, raw, true,
            ("arena %d formed: %s, side %d, %d bot(s) on the roster, best of %d. Watch it with dm.arena."):format(
                instance.id, spec.label, match.sides[subject] or 0,
                match.bots or 0, match.bestOf))
    end

    local counts = Arena.queueCounts()
    return output(source, raw, true,
        ("player %d queued for %s at position %d (%d waiting)%s"):format(
            subject, spec.label, position, counts[verb] or 0,
            parsed.bots == true and " -- bots will complete the roster"
                or " -- add 'bots' to complete the roster now"))
end, false)

RegisterCommand("dm.arena", function(source, _, raw)
    output(source, raw, true, "arena queues -- " .. Arena.describe())

    local ids = {}
    for id, instance in pairs(DM.instances.registry) do
        if not instance.closed and instance.kind == "arena" then ids[#ids + 1] = id end
    end
    table.sort(ids)

    local now = DM.nowMs()
    for _, id in ipairs(ids) do
        local instance = DM.instances.registry[id]
        local match = instance.match
        if match == nil then
            output(source, raw, true, ("  #%d %s -- no match record (adopted)"):format(
                instance.id, tostring(instance.format)))
        else
            local round = instance.round
            local deadline = now
            if round ~= nil then
                if round.state == "buy" then deadline = round.buyEndsAtMs
                elseif round.state == "active" then deadline = round.endsAtMs
                elseif round.state == "between" then deadline = round.betweenEndsAtMs
                else deadline = match.resultEndsAtMs or now end
            end
            -- `bots` and `ladder` are the decision-12 readout, and they belong
            -- together: a match with a bot on it is one that will not be
            -- persisted, and an operator should be able to see both facts
            -- without reading a log. The eligibility is asked of the SCOREBOARD
            -- rather than derived from the bot count, because the scoreboard is
            -- what the write consults.
            local module = scoring()
            local eligible = module ~= nil and type(module.ladderEligible) == "function"
                and module.ladderEligible(instance) or false
            output(source, raw, true,
                ("  #%d %s round %d %s %d-%d (first to %d) alive %d-%d in %.1fs bots=%d%s ladder=%s"):format(
                    instance.id, match.format, match.roundNumber,
                    round and round.state or "?", match.wins[1], match.wins[2], match.target,
                    match.aliveByTeam[1], match.aliveByTeam[2],
                    math.max(0, deadline - now) / 1000, match.bots or 0,
                    (match.pendingBots or 0) > 0
                        and ("+%d coming"):format(match.pendingBots) or "",
                    eligible and "eligible" or "EXCLUDED"))
            -- Both rosters, by side, with the bot label on. This is the line the
            -- acceptance test reads: it says who is on which half and which of
            -- them are still standing, which no other readout answers.
            for side = 1, 2 do
                local names = {}
                for _, participantId in ipairs(match.roster[side]) do
                    names[#names + 1] = ("%s%s%s"):format(
                        DM.playerName(participantId),
                        isBotId(participantId) and " [BOT]" or "",
                        match.eliminated[participantId] and " (out)" or "")
                end
                output(source, raw, true, ("     side %d: %s"):format(
                    side, #names > 0 and table.concat(names, ", ") or "(empty)"))
            end
        end
    end
    if #ids == 0 then output(source, raw, true, "  no arena match is running") end
end, false)


AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- The queue is in-memory and a reload empties it while the queued players go
    -- on standing in the lobby. Saying so here is what stops that emptiness
    -- being read as "the queue never fills".
    DM.log(("arena ready -- %d queued format(s): %s; queues start empty after every reload"):format(
        #formatOrder, table.concat(formatOrder, ", ")))
    for _, format in ipairs(formatOrder) do
        if clustersFor(format) == nil then
            DM.log(("arena %s cannot run yet -- its team clusters are not surveyed"):format(format))
        end
    end
end)
