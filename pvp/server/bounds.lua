-- Kabuki Arena -- containment authority and the server-side leash BACKSTOP.
--
-- Decision 6: bounds are AXIS-ALIGNED BOXES, and a point is inside if it is
-- inside ANY box of the format's zone. Not a cylinder, not a polygon prism.
--
-- The cylinder had to go because Kabuki is a gallery six metres above a sunken
-- floor: a cylinder either clips the bridge off or swallows the street outside.
-- A polygon prism was rejected for a different reason -- it needs an ordered
-- ring and a winding test and buys nothing at this scale, while a box test is
-- six comparisons and is what a surveyor can actually capture.
--
-- ---------------------------------------------------------------------------
-- WHERE THE GEOMETRY LIVES, AND WHY NOT HERE.
--
-- `shared/kabuki.lua` owns the map: the seven volume boxes, the marks, and
-- every geometric predicate. It is GENERATED -- `/dm.survey dump` rewrites it
-- wholesale from coordinates captured in-game -- so nothing in this file may
-- hold a coordinate that a surveyor's paste would have to keep in step.
--
-- This file owns the RULE and calls kabuki's predicates: `Kabuki.locateIn`,
-- `Kabuki.nearestIn`, `Kabuki.distanceTo`. It deliberately implements no
-- containment test of its own. Two containment tests that can disagree is a bug
-- waiting for a Friday, and it would present as "the diagnostic says I am
-- inside and the server keeps placing me".
--
-- The zone -- which volumes a format plays in -- is a RULE and comes from
-- `Config.zones[<format>]`, by name. The names are the seam between the two
-- files.
-- ---------------------------------------------------------------------------
--
-- THIS FILE IS NOT THE WALL.
--
-- Decision 15, settled by measurement on 2026-08-31: the wall is the CLIENT-SIDE
-- CLAMP. E1 proved props are solid, and then E2 proved `visible = false` does
-- not hide one -- the ring was accepted (`created=8 refused=0`) and rendered
-- anyway. The requirement is an invisible wall, so no arrangement of props can
-- meet it. The client polls its own position, projects back inside on the
-- nearest surface plus an inset, and writes a sub-metre transform; props
-- survive only as an optional visible marker.
--
-- What lives HERE is the authority behind that clamp: a player held outside for
-- N consecutive samples is PLACED, because a clamp that can be disabled is not
-- authority. It is a backstop, not a mechanism, and the difference shows in the
-- timings -- five seconds, not a quarter of one.
--
-- And this file DECIDES; it never PLACES. Every placement in the mode is one
-- `kill -> respawn` primitive owned by main.lua, carrying the fade, the
-- streaming preload and the grace window; bounds calls the placer main.lua
-- registers through `setPlacer`. That separation is why a backstop cannot
-- invent a second way to move a player.
--
-- ---------------------------------------------------------------------------
-- THE SAMPLING RULE, and it is the part most likely to be got wrong.
--
-- From the constraints ledger: never judge a player mid-transition; an
-- UNREADABLE position FREEZES accumulators rather than resetting them; and rules
-- are "held continuously for N seconds", sampled at ~5 Hz.
--
-- Two accumulators are kept, not one, and BOTH must be satisfied to act:
--
--   outsideSinceMs   wall-clock, when the player was first seen outside
--   outsideSamples   how many CONSECUTIVE readable samples said outside
--
-- An unreadable sample advances neither. That pairing is what makes the freeze
-- safe in both directions:
--
--   * time alone would convict a player across a replication gap -- the clock
--     keeps running while the server cannot see them;
--   * samples alone would let a player who lags into one sample per second sit
--     outside indefinitely;
--   * a RESET on unreadable would let anyone stay outside forever simply by
--     interrupting their own replication, which is precisely the exploit
--     pursuit's bounds file names in its own freeze comment.
--
-- Three answers, never two. `inside == nil` means the rule cannot tell and is
-- NOT a claim that the player is outside. Callers must not read it as one.
--
-- An UNSURVEYED or PARTLY surveyed zone is one of those cannot-tell answers,
-- and that is the single most important line in this file: an empty zone
-- contains nothing, so a naive read makes every player permanently outside and
-- the backstop places the entire instance every five seconds. `Kabuki.locateIn`
-- distinguishes `zone_empty`, `not_surveyed` and `outside_partial:n_of_m` from
-- a plain `outside` precisely so this file can freeze on the first three and
-- convict only on the last.

local DM = Deathmatch
local Config = DeathmatchConfig
local Kabuki = DeathmatchKabuki

DM.bounds = DM.bounds or {}
local Bounds = DM.bounds

-- playerId -> accumulator record
local state = {}
-- The combined volume list every lookup is judged against: kabuki's map plus
-- the lobby pad, which is not part of the Kabuki survey.
local volumes = {}
-- Said once each; a survey gap is a standing condition, not a per-tick event.
local said = {}

-- Players the leash must not judge at all. See `Bounds.setExempt`.
local exempt = {}

local placer = nil
local rosterReader = nil
local graceReader = nil

local lastSampleAtMs = 0

-- Verdicts that mean "the rule cannot tell". Every one of them is a transient
-- or a survey gap, and none of them is evidence that a player left the arena.
local CANNOT_TELL = {
    no_position = true,
    zone_empty = true,
    not_surveyed = true,
}


-- --------------------------------------------------------- volume sources --

-- The lobby pad. `kabuki.lua` has no survey target for the lobby -- it is not
-- part of the map -- so the box comes from `Config.lobby.volume`. If a
-- `lobby_pad` volume ever appears in kabuki, it WINS: the config value is a
-- fallback with an exit, not a competing store.
local function lobbyVolume()
    local surveyed = Kabuki.volume("lobby_pad")
    if surveyed ~= nil then return nil end   -- kabuki already carries it
    local volume = Config.lobby.volume
    if volume == nil then return nil end
    return { id = volume.id or "lobby_pad", min = volume.min, max = volume.max }
end

-- Rebuilds the combined list. Called at load, at resource start, and by
-- survey.lua after a capture, so a survey session sees its own work without a
-- resource restart.
function Bounds.rebuild()
    volumes = {}
    for _, volume in ipairs(Kabuki.volumes or {}) do
        volumes[#volumes + 1] = volume
    end
    local lobby = lobbyVolume()
    if lobby ~= nil then volumes[#volumes + 1] = lobby end
end

function Bounds.volumes()
    return volumes
end

-- The zone key IS the format key. `Config.zones` is keyed by format, plus a
-- `lobby` entry for players who are not in an instance at all.
--- INTEGRATION FIX 2026-08-31. An ADOPTED arena bucket (re-adopted after a hot
--- reload) carries `kind = "arena"` but no `format` yet, and the old fallback
--- answered "ffa" for it. That is not a harmless default: it would judge an
--- arena player against the FULL Kabuki footprint, so the duel zone's walls
--- would not exist for the window between adoption and the match being
--- rebuilt. An arena instance with no format now yields no zone at all, and a
--- caller with no zone does not clamp -- the same honest-degradation rule the
--- client wall already follows for an unsurveyed map.
function Bounds.zoneOf(instance)
    if instance == nil then return "lobby" end
    return instance.format or "ffa"
end

function Bounds.volumeIds(zoneKey)
    local zone = Config.zones[zoneKey or "lobby"]
    return zone and zone.volumes or {}
end

function Bounds.zoneLabel(zoneKey)
    local zone = Config.zones[zoneKey or "lobby"]
    return zone and zone.label or tostring(zoneKey)
end


-- ---------------------------------------------------------- the predicate --

-- One containment test in the whole resource, and it is kabuki's. Returns
-- `volumeId, reason` exactly as `Kabuki.locateIn` does: a volume id when the
-- point is inside, otherwise nil plus a machine-readable reason that `/dm.where`
-- prints verbatim.
function Bounds.locate(point, zoneKey)
    return Kabuki.locateIn(volumes, point, Bounds.volumeIds(zoneKey))
end

function Bounds.contains(point, zoneKey)
    local volumeId = Bounds.locate(point, zoneKey)
    return volumeId ~= nil, volumeId
end

-- The CLAMP TARGET: the nearest point inside the zone, pulled in by an inset.
--
-- The client computes the same projection locally and writes the transform; the
-- server computes it here so both sides agree where "inside" starts, so the
-- backstop places to the same spot the clamp would have reached, and so the
-- geometry can be asserted in a test without a client.
--
-- The volume is CHOSEN by `Kabuki.nearestIn` -- the predicate stays kabuki's --
-- and only the clamp arithmetic happens here, because a projection is not a
-- containment test and duplicating it duplicates nothing.
--
-- Returns `point, volumeId, distance`. `distance` is how far the input was from
-- that volume, so a caller can tell "a hair over the lip of the gallery" from
-- "forty metres out in the street".
function Bounds.project(point, zoneKey, inset)
    local origin = Kabuki.point(point)
    if origin == nil then return nil, nil, nil end
    local volumeId, distance = Kabuki.nearestIn(volumes, origin, Bounds.volumeIds(zoneKey))
    if volumeId == nil then return nil, nil, nil end

    local volume
    for _, candidate in ipairs(volumes) do
        if candidate.id == volumeId then volume = candidate break end
    end
    if volume == nil then return nil, nil, nil end

    inset = inset or Config.bounds.insetMetres or 0.0
    local target = {}
    for _, axis in ipairs({ "x", "y", "z" }) do
        local lo, hi = volume.min[axis], volume.max[axis]
        -- A box thinner than twice the inset cannot hold the inset on both
        -- sides; aim at its middle rather than producing lo > hi and a clamp
        -- that oscillates across the centre line.
        local room = (hi - lo) * 0.5
        local applied = math.min(inset, math.max(0.0, room - 0.01))
        lo, hi = lo + applied, hi - applied
        target[axis] = math.max(lo, math.min(hi, origin[axis]))
    end
    return target, volumeId, distance
end

-- What the client needs to run the clamp itself: the surveyed volumes of its
-- zone, and the inset both sides agree on. Serialisable and publishable -- the
-- geometry is already in shared/kabuki.lua, which every client downloads.
--
-- Unsurveyed volumes are omitted rather than sent as nulls: a client that
-- receives half a box would clamp against an uninitialised corner.
function Bounds.payload(zoneKey)
    local ids = Bounds.volumeIds(zoneKey)
    local wanted = {}
    for _, id in ipairs(ids) do wanted[id] = true end

    local list = {}
    for _, volume in ipairs(volumes) do
        if wanted[volume.id] and Kabuki.isSurveyed(volume) then
            list[#list + 1] = {
                id = volume.id,
                min = { x = volume.min.x, y = volume.min.y, z = volume.min.z },
                max = { x = volume.max.x, y = volume.max.y, z = volume.max.z },
            }
        end
    end
    return {
        zone = zoneKey,
        label = Bounds.zoneLabel(zoneKey),
        volumes = list,
        complete = #list == #ids,
        inset = Config.bounds.insetMetres,
        draw = Config.bounds.draw,
    }
end


-- --------------------------------------------------------- authoritative --

-- Returns `inside, detail`.
--
--   inside == true    the server saw the player inside a volume of the zone
--   inside == false   the server saw them, and they were outside all of them
--   inside == nil     the server CANNOT TELL -- and that is not "outside"
--
-- Cannot-tell covers five things, and all five are transients or survey gaps:
-- no replicated position; a position in a different bucket from the one being
-- judged (a placement in flight, or a player who has already left); a client
-- that has not passed the readiness gate; a zone with no volumes; and a zone
-- whose volumes are not all surveyed yet.
--
-- `outside_partial` is treated as cannot-tell on purpose. A half-surveyed
-- Kabuki has a market floor and no gallery: a player standing on the gallery is
-- genuinely outside every box that exists, and convicting them would be the
-- survey's fault, not theirs.
function Bounds.evaluate(playerId, zoneKey, bucket)
    local position = Open77.players.position(playerId)
    if position == nil then return nil, "unreadable" end
    if bucket ~= nil and tonumber(position.bucket) ~= bucket then
        return nil, "wrong_bucket"
    end
    if not Open77.ready.isReady(playerId) then return nil, "not_ready" end

    local volumeId, reason = Bounds.locate(position, zoneKey)
    if volumeId ~= nil then return true, volumeId end
    if reason == nil then return nil, "no_verdict" end
    if CANNOT_TELL[reason] or reason:find("^outside_partial") then
        return nil, reason
    end

    local _, distance = Kabuki.nearestIn(volumes, position, Bounds.volumeIds(zoneKey))
    return false, ("outside:%.1fm"):format(distance or -1)
end


-- ------------------------------------------------------- accumulators --

local function entryFor(playerId)
    local entry = state[playerId]
    if entry == nil then
        entry = {
            outsideSinceMs = nil,
            outsideSamples = 0,
            unreadableSamples = 0,
            warnedAtMs = nil,
            lastDetail = nil,
            lastVolume = nil,
            holdUntilMs = nil,
        }
        state[playerId] = entry
    end
    return entry
end

local function clearAccumulators(entry)
    entry.outsideSinceMs = nil
    entry.outsideSamples = 0
    entry.warnedAtMs = nil
end

-- Placement grace. Every placement is a `kill -> respawn`, and no rule may judge
-- a player while one is in flight. main.lua calls this from its placement
-- primitive; `setGraceReader` is the alternative for a main.lua that would
-- rather publish the `record.graceUntilMs` it already tracks. One or the other,
-- not both.
function Bounds.hold(playerId, durationMs)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    local entry = entryFor(playerId)
    entry.holdUntilMs = DM.nowMs() + math.max(0, tonumber(durationMs) or 0)
    clearAccumulators(entry)
end

--- EXEMPTION. A surveyor cannot survey a map they are being ejected from.
---
--- Found the hard way on 2026-08-31: `/dm.goto` moved the surveyor 2500 m to
--- Kabuki, the placement succeeded, and the lobby leash pulled them straight
--- back to the lobby a few seconds later. Both halves were behaving correctly
--- -- the travel worked, and the leash correctly judged a player standing
--- 2500 m outside the lobby volume. The two are simply incompatible, and the
--- resolution is not to weaken the leash but to say who it does not apply to.
---
--- This is deliberately NOT a duration. `hold` carries a placement grace and
--- expires because a placement ends; a survey session has no natural length,
--- and a grace long enough to walk a district is indistinguishable from having
--- no leash at all for everybody who forgot to clear it. An explicit set that
--- someone must switch off is the honest shape: `/dm.survey clear` and
--- disconnect both clear it, and it is ACL-gated at the command.
--- The exemption has more than one OWNER, and that is why it is a set rather
--- than a flag.
---
--- Two things switch it on independently: opening a survey session, and the
--- operator saying `dm.leash off`. With a single boolean, whichever switched
--- OFF last won -- so clearing a survey session silently revoked a leash the
--- operator had set by hand, and the next step they took teleported them back
--- to the lobby. Measured the hard way on 2026-08-31, on the owner, twice.
---
--- Each owner may only retract its own claim. A player is exempt while ANY
--- claim stands, which is the only rule that composes: neither owner has to
--- know the other exists.
function Bounds.setExempt(playerId, enabled, owner)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    owner = tostring(owner or "manual")

    local claims = exempt[playerId]
    if enabled == true then
        claims = claims or {}
        claims[owner] = true
        exempt[playerId] = claims
        clearAccumulators(entryFor(playerId))
        return
    end

    if claims == nil then return end
    claims[owner] = nil
    if next(claims) == nil then exempt[playerId] = nil end
end

function Bounds.isExempt(playerId)
    playerId = DM.playerId(playerId)
    return playerId ~= nil and exempt[playerId] ~= nil
end

function Bounds.setGraceReader(fn) graceReader = fn end

-- bounds DECIDES; main.lua PLACES. `fn(playerId, instance, zoneKey)`.
function Bounds.setPlacer(fn) placer = fn end

-- There is no way to list players, so the roster comes from whoever owns it:
-- the instance registry for anybody in a fight, plus whatever main.lua's lazy
-- roster knows about in the lobby. Without a reader, only instance members are
-- sampled -- which is correct, just narrower.
function Bounds.setRoster(fn) rosterReader = fn end

function Bounds.forget(playerId)
    playerId = DM.playerId(playerId)
    if playerId ~= nil then
        state[playerId] = nil
        exempt[playerId] = nil
    end
end


-- ------------------------------------------------------- the leash rule --

local function rulesFor(instance)
    if instance == nil then return Config.bounds.lobby end
    local rules = Config.bounds.arena
    -- The operator's backstop seconds override the configured default, and they
    -- are read from the INSTANCE'S CAPTURE rather than live: several rounds run
    -- at once, and a number that moved under a fight already in progress is
    -- exactly what capturing exists to prevent.
    local seconds = DM.finite(instance.tune and instance.tune.boundsBackstopSeconds)
    if seconds == nil then return rules end
    local backstopMs = math.max(1000, math.floor(seconds * 1000))
    return {
        warnAfterMs = math.min(rules.warnAfterMs, math.floor(backstopMs * 0.3)),
        warnAfterSamples = rules.warnAfterSamples,
        backstopMs = backstopMs,
        -- The sample floor scales with the window so the two accumulators stay
        -- proportionate: at 5 Hz a five-second hold is ~25 samples, and asking
        -- for 24 of them tolerates one dropped frame without tolerating a
        -- player who only replicates twice.
        backstopSamples = math.max(3,
            math.floor(backstopMs / (Config.bounds.sampleMs or 200) * 0.96)),
        warnRepeatMs = rules.warnRepeatMs,
    }
end

local function sampleOne(playerId, now)
    -- An exempt player is not judged AT ALL -- not warned, not accumulated
    -- against, not placed. This is checked before anything else so an exempt
    -- surveyor cannot even build up an out-of-bounds timer that would fire the
    -- instant the exemption is lifted.
    if exempt[playerId] then
        local entry = state[playerId]
        if entry ~= nil then clearAccumulators(entry) end
        return
    end

    local entry = entryFor(playerId)

    -- Placement grace, honoured here as everywhere else. No rule judges a
    -- player while a placement transaction is still in flight.
    local holdUntil = entry.holdUntilMs
    if graceReader ~= nil then
        local reported = graceReader(playerId)
        if reported ~= nil then holdUntil = math.max(holdUntil or 0, reported) end
    end
    if holdUntil ~= nil and now < holdUntil then
        entry.lastDetail = "grace"
        return
    end

    local instance = DM.instances.of(playerId)
    local zoneKey = Bounds.zoneOf(instance)
    local bucket = instance and instance.bucket or Config.buckets.lobby
    local rules = rulesFor(instance)

    local inside, detail = Bounds.evaluate(playerId, zoneKey, bucket)
    entry.lastDetail = detail
    entry.zone = zoneKey

    if inside == nil then
        -- FREEZE. Neither accumulator advances and neither is cleared. One
        -- missing snapshot is not evidence that a player came back, and it is
        -- not evidence that they left either.
        entry.unreadableSamples = entry.unreadableSamples + 1
        -- A survey gap is a standing condition, so it is said once per zone
        -- rather than five times a second per player.
        if detail == "zone_empty" or detail == "not_surveyed" then
            local key = "gap:" .. zoneKey
            if not said[key] then
                said[key] = true
                DM.log(("bounds -- zone '%s' is %s; containment is SUSPENDED there rather than convicting everyone in it"):format(
                    zoneKey, detail == "zone_empty" and "empty" or "not surveyed"))
            end
        end
        return
    end

    entry.unreadableSamples = 0

    if inside then
        if entry.outsideSinceMs ~= nil and Config.debug.verboseBounds then
            DM.log(("bounds: player %d back inside '%s' after %.1fs / %d samples"):format(
                playerId, zoneKey, (now - entry.outsideSinceMs) / 1000,
                entry.outsideSamples))
        end
        entry.lastVolume = detail
        clearAccumulators(entry)
        return
    end

    entry.outsideSinceMs = entry.outsideSinceMs or now
    entry.outsideSamples = entry.outsideSamples + 1
    local elapsed = now - entry.outsideSinceMs

    -- BOTH conditions, always. See the header.
    if elapsed >= rules.backstopMs and entry.outsideSamples >= rules.backstopSamples then
        clearAccumulators(entry)
        -- The position and verdict are logged because a backstop that fires on a
        -- player standing on the lobby mark is a stale or wrong-bucket sample,
        -- not an escape -- and without them the two are indistinguishable.
        local sample = Open77.players.position(playerId)
        DM.log(("bounds BACKSTOP player=%d zone=%s held outside %.1fs / %d samples (last=%s at %s bucket=%s) -> placed"):format(
            playerId, zoneKey, elapsed / 1000, rules.backstopSamples,
            tostring(detail),
            sample and ("%.2f,%.2f,%.2f"):format(sample.x or 0, sample.y or 0, sample.z or 0) or "nil",
            sample and tostring(sample.bucket) or "nil"))
        DM.notice(playerId, "warning",
            instance ~= nil and "boundsReturned" or "lobbyReturned")
        -- The score penalty, so the wall is never a strategy. scoring.lua
        -- publishes the hook; without it the placement still happens.
        if DM.scoring ~= nil and DM.scoring.penalise ~= nil then
            DM.scoring.penalise(playerId, instance, "out_of_bounds",
                Config.bounds.penaltyPoints)
        end
        if placer ~= nil then
            local ok, err = pcall(placer, playerId, instance, zoneKey)
            if not ok then
                DM.log(("bounds backstop placer raised for player %d: %s"):format(
                    playerId, tostring(err)))
            end
        else
            DM.log("bounds backstop has NO PLACER registered -- see Deathmatch.bounds.setPlacer")
        end
        return
    end

    if elapsed >= rules.warnAfterMs and entry.outsideSamples >= rules.warnAfterSamples then
        local due = entry.warnedAtMs == nil
            or (now - entry.warnedAtMs) >= rules.warnRepeatMs
        if due then
            entry.warnedAtMs = now
            local remaining = math.max(0, (rules.backstopMs - elapsed) / 1000)
            DM.notice(playerId, "warning", "boundsWarn",
                Bounds.zoneLabel(zoneKey), math.floor(remaining + 0.5))
            if Config.debug.verboseBounds then
                DM.log(("bounds: player %d outside '%s' %s, %.1fs left"):format(
                    playerId, zoneKey, tostring(detail), remaining))
            end
        end
    end
end

-- Called from the mode tick at whatever rate it runs; this self-throttles to
-- `Config.bounds.sampleMs` (~5 Hz), so the rule's cadence is a property of the
-- rule and not of whoever calls it. That matters: the sample COUNT is half the
-- decision, and a tick that changed rate would otherwise change the rule.
function Bounds.tick(now)
    now = now or DM.nowMs()
    if now - lastSampleAtMs < (Config.bounds.sampleMs or 200) then return end
    lastSampleAtMs = now

    local seen = {}

    for _, instance in pairs(DM.instances.registry) do
        if not instance.closed then
            for _, playerId in ipairs(DM.instances.members(instance)) do
                if not seen[playerId] then
                    seen[playerId] = true
                    sampleOne(playerId, now)
                end
            end
        end
    end

    if rosterReader ~= nil then
        local ok, roster = pcall(rosterReader)
        if ok and type(roster) == "table" then
            for _, value in ipairs(roster) do
                local playerId = DM.playerId(value)
                if playerId ~= nil and not seen[playerId] then
                    seen[playerId] = true
                    sampleOne(playerId, now)
                end
            end
        end
    end

    -- Accumulators for players nobody claims any more are dropped, so a
    -- disconnect that skipped `forget` cannot leak a record per session.
    --
    -- An ACTIVE HOLD survives the sweep. A player is held before the registry
    -- has them -- and, with no roster reader, a player in the lobby is never in
    -- `seen` at all -- so dropping the record here would silently discard the
    -- placement grace it exists to carry.
    for playerId, entry in pairs(state) do
        local held = entry.holdUntilMs ~= nil and now < entry.holdUntilMs
        if not seen[playerId] and not held and not exempt[playerId] then
            state[playerId] = nil
        end
    end
end


-- --------------------------------------------------------------- queries --

-- Is this player outside, as of the rule's own most recent look?
--
-- THREE answers, not two, exactly as pursuit's equivalent publishes: `nil`
-- means the rule has not judged this player at all -- placement grace, a
-- readiness gate, an unsurveyed zone -- and is NOT a claim that they are
-- inside. Callers must not read it as one.
function Bounds.outside(playerId)
    local entry = state[DM.playerId(playerId) or -1]
    if entry == nil or entry.lastDetail == nil then return nil end
    local detail = entry.lastDetail
    if detail == "grace" or detail == "unreadable" or detail == "wrong_bucket"
        or detail == "not_ready" or detail == "no_verdict"
        or CANNOT_TELL[detail] or detail:find("^outside_partial") then
        return nil
    end
    return entry.outsideSinceMs ~= nil
end

-- The readout `/dm.where` prints: position, bucket, which volume contains you,
-- the verdict, and why. Section 6 of writing-a-gamemode.md asks for exactly
-- this, and it is the difference between reading a bounds decision and guessing
-- at one.
function Bounds.describe(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return "bad player id" end
    local instance = DM.instances.of(playerId)
    local zoneKey = Bounds.zoneOf(instance)
    local bucket = instance and instance.bucket or Config.buckets.lobby
    local position = Open77.players.position(playerId)
    local inside, detail = Bounds.evaluate(playerId, zoneKey, bucket)
    local entry = state[playerId]
    return ("player %d instance=%s zone=%s bucket=%d pos=%s live-bucket=%s inside=%s detail=%s outsideFor=%s samples=%d frozen=%d"):format(
        playerId,
        instance and tostring(instance.id) or "none",
        zoneKey, bucket,
        position and ("%.2f,%.2f,%.2f"):format(position.x, position.y, position.z)
            or "unreadable",
        position and tostring(position.bucket) or "?",
        inside == nil and "cannot-tell" or tostring(inside),
        tostring(detail),
        (entry and entry.outsideSinceMs)
            and ("%.1fs"):format((DM.nowMs() - entry.outsideSinceMs) / 1000) or "-",
        entry and entry.outsideSamples or 0,
        entry and entry.unreadableSamples or 0)
end


-- -------------------------------------------------------------- commands --

local function output(source, raw, ok, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

RegisterCommand("dm.bounds", function(source, args, raw)
    local progress = Kabuki.progress()
    output(source, raw, true, ("bounds -- map %s, %d/%d volume(s) surveyed, %d/%d mark(s), inset %.2fm, sampled every %dms"):format(
        Kabuki.surveyed and "SURVEYED" or "NOT SURVEYED",
        progress.volumesReady, progress.volumesWanted,
        progress.marksReady, progress.marksWanted,
        Config.bounds.insetMetres or 0, Config.bounds.sampleMs or 200))

    for zoneKey, zone in pairs(Config.zones) do
        local ready, total = 0, 0
        local names = {}
        for _, id in ipairs(zone.volumes or {}) do
            total = total + 1
            local volume
            for _, candidate in ipairs(volumes) do
                if candidate.id == id then volume = candidate break end
            end
            local ok = volume ~= nil and Kabuki.isSurveyed(volume)
            if ok then ready = ready + 1 end
            names[#names + 1] = id .. (ok and "" or "?")
        end
        output(source, raw, true, ("  zone %-6s %-22s %d/%d ready: %s"):format(
            zoneKey, tostring(zone.label), ready, total,
            #names > 0 and table.concat(names, ", ") or "NONE"))
    end

    local playerId = DM.playerId(args and args[1]) or DM.playerId(source)
    if playerId ~= nil then
        output(source, raw, true, "  " .. Bounds.describe(playerId))
    end
end, false)


-- --------------------------------------------------------------- startup --

Bounds.rebuild()

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    Bounds.rebuild()

    local progress = Kabuki.progress()
    DM.log(("bounds ready -- %d/%d volume(s), %d/%d mark(s); the backstop is a BACKSTOP, the wall is the client clamp"):format(
        progress.volumesReady, progress.volumesWanted,
        progress.marksReady, progress.marksWanted))
    if not progress.complete then
        DM.log("bounds -- Kabuki is NOT fully surveyed. Containment is SUSPENDED for any zone whose volumes are missing; run /dm.survey before trusting a bounds verdict.")
    end

    -- The zone rule lives in Config.zones and the same four lists also exist in
    -- DeathmatchKabuki.formats. Until that duplication is removed, compare them
    -- here: a silent divergence would mean the containment test and the
    -- surveyor's own readout judge different volumes, and a diagnostic that
    -- disagrees with enforcement is worse than no diagnostic.
    for _, format in ipairs({ "ffa", "1v1", "2v2", "3v3" }) do
        local mine = Bounds.volumeIds(format)
        local theirs = Kabuki.zone(format)
        local same = #mine == #theirs
        if same then
            for index = 1, #mine do
                if mine[index] ~= theirs[index] then same = false break end
            end
        end
        if not same then
            DM.log(("bounds WARNING -- zone mismatch for '%s': Config.zones says [%s], DeathmatchKabuki.formats says [%s]. Config.zones is authoritative here."):format(
                format, table.concat(mine, ","), table.concat(theirs, ",")))
        end
    end

    -- Spawn marks inside their own zone is the one property that must hold
    -- before any of the tuning above matters: a mark outside the boundary
    -- starts a fight that warns the player two seconds in and places them at
    -- five.
    --
    -- EVERY mark table is swept, not just the FFA one, and the per-format team
    -- clusters are swept against THEIR OWN format's zone. That is the check
    -- that catches the mistake the cluster split exists to prevent -- a 1v1
    -- mark that is perfectly valid for 3v3 and outside `lower`. Pursuit shipped
    -- the opposite bug: it swept `match.spawns` and never `vehicles.spawns`, so
    -- a second, independent mark set was never validated and the gap was
    -- invisible only because that table was still nil. The table PATH is
    -- printed with each warning so a report names the position that must change.
    local sets = { { path = "spawns.ffa", marks = (Kabuki.spawns or {}).ffa, zone = "ffa" } }
    for _, format in ipairs({ "1v1", "2v2", "3v3" }) do
        local teams = (Kabuki.teams or {})[format] or {}
        for _, side in ipairs({ "a", "b" }) do
            sets[#sets + 1] = {
                path = ("teams[\"%s\"].%s"):format(format, side),
                marks = teams[side], zone = format,
            }
        end
    end

    local captured, outside = 0, 0
    for _, set in ipairs(sets) do
        for index, mark in ipairs(set.marks or {}) do
            local point = Kabuki.point(mark.position)
            if point ~= nil then
                captured = captured + 1
                local volumeId, reason = Bounds.locate(point, set.zone)
                -- Only a plain `outside` is a mark's fault. `not_surveyed` and
                -- `outside_partial` mean the sweep ran before the boxes landed,
                -- which is expected during Phase 1 and is not a warning.
                if volumeId == nil and reason == "outside" then
                    outside = outside + 1
                    DM.log(("bounds WARNING -- DeathmatchKabuki.%s[%d] (%.1f, %.1f, %.1f) is OUTSIDE the '%s' zone"):format(
                        set.path, index, point.x, point.y, point.z, set.zone))
                end
            end
        end
    end
    DM.log(("bounds spawn sweep -- %d captured mark(s) across %d table(s), %d outside their own zone"):format(
        captured, #sets, outside))

    -- The dead band. `open77_worldui` activates at `radius + 0.5 m`, and two
    -- stations closer than the sum of their activations leave a gap in which
    -- NEITHER prompt is live -- worse than an overlap, because an overlap is
    -- arbitrated and a dead band just looks broken. Cheap to check the moment
    -- both marks exist, and impossible to see by reading the numbers.
    local stations = Kabuki.stations or {}
    local first = Kabuki.point(stations[1] and stations[1].position)
    local second = Kabuki.point(stations[2] and stations[2].position)
    if first ~= nil and second ~= nil then
        local dx, dy = first.x - second.x, first.y - second.y
        local separation = math.sqrt(dx * dx + dy * dy)
        local required = Config.stations.minSeparationMetres or 6.0
        if separation < required then
            DM.log(("bounds WARNING -- the two lobby stations are %.1fm apart, under the %.1fm minimum: expect a DEAD BAND where neither prompt is live"):format(
                separation, required))
        end
    end
end)
