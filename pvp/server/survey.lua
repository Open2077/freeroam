-- Kabuki survey tooling -- Phase 1 of docs/gamemode-pvp-arena-plan.md.
--
-- The map has no coordinates. This file is how they get captured, and the rule
-- it exists to enforce is the one race/server/courses.lua states in its own
-- header: COORDINATES ARE NEVER ACCEPTED FROM A CLIENT PAYLOAD. Every position
-- in a dump comes from `Open77.players.position(caller)` -- the authoritative
-- server-side read -- and nothing else. A survey command carries a set name, a
-- volume id and at most a heading; never a place.
--
-- Everything here is a development instrument, ACL-gated, and it writes no
-- world state: it moves nobody, spawns nothing, and touches no match. The whole
-- output is text the surveyor pastes into shared/kabuki.lua.
--
-- ---------------------------------------------------------------------------
-- WIRING THIS FILE NEEDS (owned by another agent; not edited here)
--
--   open77.lua, in this order and BEFORE server/main.lua:
--       shared_script "shared/config.lua"
--       shared_script "shared/kabuki.lua"     -- new
--       server_script "server/main.lua"
--       server_script "server/survey.lua"     -- new
--
--   No new `permissions` entry: this file reads `players.life.read` and speaks
--   over `network.events`, both already declared.
--
--   shared/config.lua, optional -- every key below has a local default here and
--   is only read if present, so the file works unwired:
--       DeathmatchConfig.survey = {
--           sessionMinutes      = 30,    -- a survey session is a long walk
--           minimumSeparation   = 3.0,   -- metres between two marks in one set
--           minimumFootprint    = 1.5,   -- metres, smallest sane box edge
--           floorPadMetres      = 0.5,   -- box floor below the ground sample
--           defaultHeightMetres = 5.0,   -- box ceiling above the ground sample
--       }
--   The strings below belong under `DeathmatchConfig.strings.survey` the day
--   that table is the single home for player-facing copy; they are held here
--   for now so this file works against a config that does not know about it.
--
--   Read from shared/config.lua, all optional and all guarded: `map.volumes`,
--   `map.provisionalVolumes`, `map.surveyed`, `zones`, `formats[*].zone`. Those
--   are the SECOND copy of the map -- see the note in shared/kabuki.lua --
--   and `/dm.where` reports them beside this resource's own schema until the
--   duplication is resolved.
--
--   Nothing else. `/dm.where` reports the caller's instance through
--   `Deathmatch.instances.of` when server/instances.lua is loaded, and stays
--   silent about it when it is not -- Phase 1 must not wait on Phase 2.
--
--   NOT wired, and deliberately: there is no `/dm.survey goto <n>` to stand on
--   a captured mark, because placement is `kill -> respawn` (decision 9) and
--   that primitive lives in main.lua as a local. Reimplementing it here would
--   put a second placement path in the mode, which is exactly what the single
--   primitive exists to prevent. Export `Deathmatch.placeAt` and the verb is
--   ten lines; until then Phase 1's "grounded and alive on every mark" gate is
--   proven with the existing `deathmatch` placement or the debug bridge.
-- ---------------------------------------------------------------------------
--
-- ONE THING THE SURVEYOR MUST KNOW: a session lives in this VM and nowhere
-- else. A hot reload of the resource empties it while the surveyor is still
-- standing in the market -- the same way the Phase 0 laboratory lost track of
-- its own NPCs on 2026-08-31. There is no registry to re-read for a draft, so
-- the discipline is the dump: `/dm.survey dump` after every few marks, and
-- always before touching a Lua file. Marks are paid for by walking.

local Config = DeathmatchConfig
local Kabuki = DeathmatchKabuki

-- Every player-facing string in one table, in English (decision 16). Format
-- specifiers included: a translated line and a translated format string are the
-- same problem, and splitting them is how half a UI ends up untranslated.
local TEXT = {
    playerOnly        = "This command must be used in-game.",
    usage             = "usage: dm.survey <start|mark|box|list|dump|commit|clear> -- or use /dm.map, the live editor, which needs no paste and no reload",
    usageStart        = "usage: dm.survey start <%s>",
    usageBox          = "usage: dm.survey box <%s> [height]",
    usageClear        = "usage: dm.survey clear [all|marks|boxes|<set>|<volume>]",
    usageWherePlayer  = "usage: dm.where [ffa|3v3|2v2|1v1]",
    usageWhereConsole = "usage: dm.where <playerId> [ffa|3v3|2v2|1v1]",

    noSession         = "No survey session. Run: dm.survey start <set>",
    sessionExpired    = "Survey session expired after %d minutes of silence. Nothing was lost -- run dm.survey start <set> again.",
    sessionOpened     = "Survey session open. Capturing into '%s' (%s), %d of %d marks so far. Marks already captured are kept.",
    sessionSwitched   = "Now capturing into '%s' (%s), %d of %d. Nothing was discarded -- only 'clear' discards.",
    unknownSet        = "Unknown capture set '%s'. Known sets: %s",
    unknownVolume     = "Unknown volume '%s'. This map declares: %s. A new volume must be declared before it can be captured -- 'dm.map box <id>' declares one as it walks it, where this file's dump can only match the schema that already exists.",

    commitNoStore     = "The live map store is not loaded (server/mapstore.lua is not in the manifest), so there is nothing to commit into. Use 'dm.survey dump' and paste.",
    commitBuiltin     = "The active map is the BUILT-IN '%s' and is never written to. Copy it first: dm.map copy %s myarena",
    commitDone        = "Committed into the live map '%s': %d mark(s) across %d set(s) and %d volume(s). It is LIVE -- the next spawn uses it. The draft is kept, so 'dm.survey dump' still works.",
    commitZoned       = "This map had no zone, so every format now plays %s. Carve them apart with 'dm.map zone <format> <ids>'.",

    noPosition        = "The server cannot read your position right now (%s). Do not capture through a transition -- wait until you are standing still and alive.",
    setFull           = "Set '%s' already holds its %d marks. Use 'dm.survey clear %s' to start it over.",
    tooClose          = "Refused: %.2f m from mark %d of '%s', and the minimum separation is %.2f m. Two marks that close are a spawn blender, not two spawns.",
    markCaptured      = "Mark %d/%d captured for '%s' at %.3f %.3f %.3f (bucket %d), heading %s.",
    headingMissing    = "No heading given and your client has not reported one yet, so 0.0 was recorded. Re-run 'dm.survey start <set>' to switch the reporter on, or pass it: 'dm.survey mark <yaw>'.",

    boxFirst          = "Corner 1 of '%s' captured at %.3f %.3f %.3f. Walk to the OPPOSITE corner and run the same command again.",
    boxClosed         = "Volume '%s' closed: %.1f x %.1f m footprint, z %.2f to %.2f (%.1f m of headroom). %d of %d volumes surveyed.",
    boxReopened       = "Volume '%s' was already closed; starting it over from this corner.",
    boxTooSmall       = "Refused: the two corners of '%s' are only %.2f x %.2f m apart, under the %.2f m minimum. Did you capture twice in the same place?",
    boxInvalid        = "Could not close '%s': %s",
    boxHeightBad      = "Ignoring the height '%s'; it must be a positive number of metres.",

    cleared           = "Cleared %s. %d mark(s) and %d volume(s) remain in this session.",
    clearNothing      = "Nothing to clear for '%s'.",

    dumpEmpty         = "Nothing captured yet -- nothing to dump.",
    dumped            = "Dumped %d line(s) to the server console: %d/%d volumes, %d/%d marks. Copy it over the matching blocks in resources/gamemodes/open77_deathmatch/shared/kabuki.lua.",

    listHeader        = "survey set=%s expires_in=%dm | volumes %d/%d | marks %d/%d",
    listNone          = "survey: nothing captured yet; set=%s",

    -- `dead` is printed raw rather than inverted into `alive`: a life read that
    -- comes back nil is not the same answer as "alive", and flattening the two
    -- is how a mid-transition player gets acted on -- which crashes the client.
    whereLine         = "where player=%d pos=%.3f %.3f %.3f bucket=%d ready=%s dead=%s",
    whereVerdict      = "verdict format=%s zone=[%s] volume=%s inside=%s reason=%s",
    whereNearest      = "nearest=%s distance=%.2fm overshoot=%.2f,%.2f,%.2f",
    whereNoNearest    = "nearest=none -- no volume of this zone is surveyed yet, so no boundary can be judged.",
    whereConfig       = "config map (shared/config.lua) zone=[%s] volume=%s inside=%s reason=%s",
    whereDisagree     = "DISAGREEMENT: shared/kabuki.lua and shared/config.lua return different verdicts for this point. They hold two copies of the same map; one of them has to go before Phase 2 builds on either.",
    whereSession      = "survey session set=%s marks=%d openBox=%s",
    whereNoSession    = "survey session: none",
    whereInstance     = "instance=%s format=%s zone=%s bucket=%s player_bucket_matches=%s",
    whereNoInstance   = "instance=none -- this player is in no instance, so no arena zone is being enforced on them.",
}

-- Defaults, overridden by DeathmatchConfig.survey when that key exists.
local SURVEY = {
    sessionMinutes      = 30,
    minimumSeparation   = 3.0,
    minimumFootprint    = 1.5,
    floorPadMetres      = 0.5,
    defaultHeightMetres = 5.0,
}
for key, value in pairs(type(Config) == "table" and Config.survey or {}) do
    if SURVEY[key] ~= nil and tonumber(value) ~= nil then SURVEY[key] = tonumber(value) end
end

-- Per-volume ceilings, because Kabuki stacks. The market floor is at +-0 and
-- the gallery ring at +6: give the market an eight-metre ceiling and a player
-- standing on the bridge reads as being on the market floor, which breaks both
-- the level-aware reporting and anything later built on it. Keep each ceiling
-- under the floor above it, and pass an explicit height when the ground argues.
local HEIGHT = {
    market   = 5.0,
    lower    = 4.0,
    gallery  = 5.0,
    stair_nw = 7.0,  -- a stair spans two levels by definition; it needs the span
    stair_ne = 7.0,
    stair_sw = 7.0,
    stair_se = 7.0,
}

-- [playerId] = { setKey, expiresAtMs, marks = { [setKey] = { mark, ... } },
--                boxes = { [volumeId] = { first, second, height, min, max } } }
--
-- Nothing in this table is a world object, which is why it may be iterated at
-- all: the "never iterate your own registry" rule exists because props and NPCs
-- outlive the VM that spawned them. A draft does not outlive anything -- it
-- simply disappears, and the dump is the answer to that.
local sessions = {}

local function log(text)
    print("[deathmatch:survey] " .. tostring(text))
end

local function reply(source, raw, ok, text)
    log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function normalizeHeading(value)
    local heading = finite(value)
    if heading == nil then return nil end
    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    return heading
end

-- Player ids arrive as strings from every lifecycle event, and a string key and
-- a number key are two different rows in the same table. Convert at the door.
local function playerKey(value)
    local id = tonumber(value)
    if id == nil or id <= 0 then return nil end
    return id
end

-- The only source of coordinates in this file.
local function callerPosition(playerId)
    local position = Open77.players.position(playerId)
    if position == nil then return nil, "position_unknown" end
    local point = Kabuki.point(position)
    if point == nil then return nil, "position_unreadable" end
    point.bucket = tonumber(position.bucket) or 0
    return point
end

-- shared/config.lua's own copy of the map, for the second verdict `/dm.where`
-- prints. Resolved entirely defensively: that file belongs to the instance
-- kernel work and is moving, so this must degrade to silence rather than to an
-- error when its shape changes under us.
local function configGeometry(format)
    local map = type(Config) == "table" and DeathmatchKabuki or nil
    if type(map) ~= "table" or type(map.volumes) ~= "table" or #map.volumes == 0 then
        return nil
    end

    local ids
    local definition = type(Config.formats) == "table" and Config.formats[format] or nil
    local zone = definition ~= nil and type(Config.zones) == "table"
        and Config.zones[tostring(definition.zone or "")] or nil
    if zone ~= nil and type(zone.volumes) == "table" then
        ids = {}
        for index, id in ipairs(zone.volumes) do ids[index] = id end
        -- While its map is unsurveyed that file unions its provisional boxes
        -- into every arena zone, so the mode is playable on provisional ground
        -- rather than unbounded. The diagnostic has to union the same ones, or
        -- it will disagree with the enforcement for a reason that has nothing
        -- to do with where the player is standing.
        if map.surveyed ~= true and type(map.provisionalVolumes) == "table" then
            for _, id in ipairs(map.provisionalVolumes) do ids[#ids + 1] = id end
        end
    end
    return map.volumes, ids
end

-- The instance kernel's registry, if server/instances.lua has been loaded into
-- this state. Called through pcall and behind three type checks because this
-- file must remain loadable on its own: the survey is the tool that unblocks
-- Phase 1, and Phase 1 must not wait on Phase 2's registry to exist.
local function instanceOf(playerId)
    local namespace = type(Deathmatch) == "table" and Deathmatch or nil
    local registry = namespace and type(namespace.instances) == "table"
        and namespace.instances or nil
    if registry == nil or type(registry.of) ~= "function" then return nil end
    local ok, instance = pcall(registry.of, playerId)
    if not ok or type(instance) ~= "table" then return nil end
    return instance
end

local function volumeIdList()
    local ids = {}
    for index, volume in ipairs(Kabuki.volumes) do ids[index] = volume.id end
    return table.concat(ids, ", ")
end

local function setKeyList()
    return table.concat(Kabuki.setKeys(), ", ")
end

local function markCount(session)
    local total = 0
    for _, list in pairs(session.marks) do total = total + #list end
    return total
end

local function boxCount(session)
    local closed = 0
    for _, box in pairs(session.boxes) do
        if box.min ~= nil then closed = closed + 1 end
    end
    return closed
end

-- FORWARD-DECLARED, and this was a live bug rather than a style choice.
-- `sessionOf` below calls `tellClientToReport`, which was declared `local`
-- FORTY LINES FURTHER DOWN: inside `sessionOf` the name therefore resolved to
-- a global, which is nil, so the one path that reaches it -- a session
-- expiring after thirty minutes of silence -- raised "attempt to call a nil
-- value" instead of telling the client to stop reporting. It never fired in a
-- short test because a test never idles for half an hour.
local tellClientToReport

-- Lazily expired rather than swept by a tick. There is no way to list players,
-- so a sweep would be iterating this table to find rows whose owner may have
-- disconnected an hour ago -- and it would cost a thread for a tool used by one
-- person at a time. Checking on use answers the same question for free.
local function sessionOf(playerId)
    local session = sessions[playerId]
    if session == nil then return nil, TEXT.noSession end
    if nowMs() > session.expiresAtMs then
        sessions[playerId] = nil
        -- The exemption dies with the session it belonged to. A leash that
        -- stays off because somebody walked away is not a leash.
        local dm = rawget(_G, "Deathmatch")
        if dm ~= nil and dm.bounds ~= nil and dm.bounds.setExempt ~= nil then
            dm.bounds.setExempt(playerId, false, "survey")
        end
        tellClientToReport(playerId, false)
        return nil, TEXT.sessionExpired:format(math.floor(SURVEY.sessionMinutes))
    end
    session.expiresAtMs = nowMs() + SURVEY.sessionMinutes * 60000
    return session
end

-- ------------------------------------------------------------ subcommands --

-- Last heading each surveyor's client reported, so `mark` can default to the
-- direction they are actually facing instead of demanding a number.
local reportedHeading = {}

RegisterNetEvent("deathmatch:surveyHeading", function(yaw)
    local playerId = playerKey(source)
    local value = tonumber(yaw)
    if playerId == nil or value == nil or value ~= value then return end
    reportedHeading[playerId] = value % 360.0
end)

function tellClientToReport(playerId, enabled)
    TriggerClientEvent("deathmatch:surveyHeading", playerId, enabled == true)
    if not enabled then reportedHeading[playerId] = nil end
end

-- The heading channel, published so the LIVE MAP EDITOR can use it instead of
-- opening a second one.
--
-- There is exactly one 4 Hz reporter per client and this file owns it. Two
-- reporters on the same event would be two answers to one question -- and the
-- second one to switch it off would silence the first. `server/mapstore.lua`
-- resolves both of these at call time, so removing this file costs the editor
-- its headings and nothing else.
Deathmatch = Deathmatch or {}
Deathmatch.survey = Deathmatch.survey or {}
function Deathmatch.survey.heading(playerId)
    return reportedHeading[playerKey(playerId)]
end
function Deathmatch.survey.report(playerId, enabled)
    local id = playerKey(playerId)
    if id == nil then return end
    tellClientToReport(id, enabled == true)
end

local function cmdStart(source, raw, args)
    local key = tostring(args[1] or "")
    local set = Kabuki.set(key)
    if set == nil then
        if key == "" then
            return reply(source, raw, false, TEXT.usageStart:format(setKeyList()))
        end
        return reply(source, raw, false, TEXT.unknownSet:format(key, setKeyList()))
    end

    local session = sessions[source]
    local switched = session ~= nil
    if session == nil then
        session = { marks = {}, boxes = {} }
        sessions[source] = session
    end
    -- `start` is not a reset. Re-running it after switching sets, or after a
    -- typo, must never cost the marks already walked -- `clear` is the only
    -- verb in this file that destroys anything.
    session.setKey = key
    session.expiresAtMs = nowMs() + SURVEY.sessionMinutes * 60000
    session.marks[key] = session.marks[key] or {}

    -- A surveyor is exempt from the boundary leash for as long as the session
    -- is open. Measured 2026-08-31: without this, travelling to the map to
    -- survey it succeeds and the LOBBY leash then returns the surveyor a few
    -- seconds later. Both halves were correct in isolation -- the placement
    -- worked and the leash correctly judged a player standing 2500 m outside
    -- the lobby -- and they are simply incompatible. You cannot survey a map
    -- you are being ejected from.
    local dm = rawget(_G, "Deathmatch")
    if dm ~= nil and dm.bounds ~= nil and dm.bounds.setExempt ~= nil then
        dm.bounds.setExempt(source, true, "survey")
    end
    tellClientToReport(source, true)

    local template = switched and TEXT.sessionSwitched or TEXT.sessionOpened
    reply(source, raw, true, template:format(
        key, set.label, #session.marks[key], set.limit))
end

local function cmdMark(source, raw, args)
    local session, reason = sessionOf(source)
    if session == nil then return reply(source, raw, false, reason) end

    local set = Kabuki.set(session.setKey)
    local list = session.marks[session.setKey]
    if #list >= set.limit then
        return reply(source, raw, false,
            TEXT.setFull:format(session.setKey, set.limit, session.setKey))
    end

    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, TEXT.noPosition:format(failure)) end

    -- Two marks a metre apart are one mark and a spawn blender. This compares
    -- captured samples; it never derives one from another.
    for index, existing in ipairs(list) do
        local dx = point.x - existing.position.x
        local dy = point.y - existing.position.y
        local dz = point.z - existing.position.z
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if distance < SURVEY.minimumSeparation then
            return reply(source, raw, false, TEXT.tooClose:format(
                distance, index, session.setKey, SURVEY.minimumSeparation))
        end
    end

    -- Heading is the one value the caller supplies, because the server cannot
    -- see it: Open77.players.position returns { x, y, z, bucket } and no
    -- facing. Phase 0 measured how it is meant to be read back -- a yaw maps to
    -- a direction as (-sin yaw, cos yaw) on this build -- which is why a mark
    -- without one is recorded loudly rather than quietly zeroed.
    -- The argument still wins, but it is no longer required. While a survey
    -- session is open the surveyor's own client reports its facing at 4 Hz --
    -- which is the only place that number exists. The server cannot see it:
    -- the position record it receives is (x, y, z, bucket) with no rotation,
    -- and the life state's yaw is only written at a kill or respawn, so it is
    -- the direction you were placed facing rather than the one you are looking.
    -- Defaulting to that would have quietly recorded the wrong heading, which
    -- is worse than demanding the number.
    local heading = normalizeHeading(args[1]) or reportedHeading[playerKey(source)]
    list[#list + 1] = {
        position = { x = point.x, y = point.y, z = point.z },
        heading = heading or 0.0,
        headingKnown = heading ~= nil,
        bucket = point.bucket,
    }

    reply(source, raw, true, TEXT.markCaptured:format(
        #list, set.limit, session.setKey, point.x, point.y, point.z, point.bucket,
        heading and ("%.1f"):format(heading) or "0.0 (not supplied)"))
    if heading == nil then reply(source, raw, true, TEXT.headingMissing) end
end

local function cmdBox(source, raw, args)
    local session, reason = sessionOf(source)
    if session == nil then return reply(source, raw, false, reason) end

    local id = tostring(args[1] or "")
    if id == "" then return reply(source, raw, false, TEXT.usageBox:format(volumeIdList())) end
    if Kabuki.volume(id) == nil then
        return reply(source, raw, false, TEXT.unknownVolume:format(id, volumeIdList()))
    end

    local height
    if args[2] ~= nil then
        height = finite(args[2])
        if height == nil or height <= 0.0 then
            reply(source, raw, false, TEXT.boxHeightBad:format(tostring(args[2])))
            height = nil
        end
    end

    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, TEXT.noPosition:format(failure)) end

    local box = session.boxes[id]
    if box == nil or box.min ~= nil then
        -- No box, or a closed one: this corner starts it over. Redoing a badly
        -- walked volume must not need a clear.
        local reopened = box ~= nil
        box = { height = height or HEIGHT[id] or SURVEY.defaultHeightMetres }
        session.boxes[id] = box
        box.first = point
        if reopened then reply(source, raw, true, TEXT.boxReopened:format(id)) end
        return reply(source, raw, true, TEXT.boxFirst:format(id, point.x, point.y, point.z))
    end

    if height ~= nil then box.height = height end
    local footprintX = math.abs(point.x - box.first.x)
    local footprintY = math.abs(point.y - box.first.y)
    if footprintX < SURVEY.minimumFootprint or footprintY < SURVEY.minimumFootprint then
        return reply(source, raw, false, TEXT.boxTooSmall:format(
            id, footprintX, footprintY, SURVEY.minimumFootprint))
    end

    local closed, failureReason = Kabuki.boxFromCorners(box.first, point, {
        height = box.height,
        floorPad = SURVEY.floorPadMetres,
    })
    if closed == nil then
        return reply(source, raw, false, TEXT.boxInvalid:format(id, tostring(failureReason)))
    end
    box.second = point
    box.min, box.max = closed.min, closed.max

    reply(source, raw, true, TEXT.boxClosed:format(
        id, footprintX, footprintY, box.min.z, box.max.z, box.max.z - box.min.z,
        boxCount(session), #Kabuki.volumes))
end

local function cmdList(source, raw)
    local session, reason = sessionOf(source)
    if session == nil then return reply(source, raw, false, reason) end

    local marks, closed = markCount(session), boxCount(session)
    if marks == 0 and next(session.boxes) == nil then
        return reply(source, raw, true, TEXT.listNone:format(session.setKey))
    end

    local wanted = 0
    for _, entry in ipairs(Kabuki.sets) do wanted = wanted + entry.limit end
    reply(source, raw, true, TEXT.listHeader:format(
        session.setKey, math.max(0, math.floor((session.expiresAtMs - nowMs()) / 60000)),
        closed, #Kabuki.volumes, marks, wanted))

    for _, entry in ipairs(Kabuki.sets) do
        local list = session.marks[entry.key]
        if list ~= nil and #list > 0 then
            local missing = 0
            for _, mark in ipairs(list) do
                if not mark.headingKnown then missing = missing + 1 end
            end
            reply(source, raw, true, ("  %-8s %d/%d captured%s"):format(
                entry.key, #list, entry.limit,
                missing > 0 and (", %d without a heading"):format(missing) or ""))
        end
    end

    for _, volume in ipairs(Kabuki.volumes) do
        local box = session.boxes[volume.id]
        if box ~= nil then
            reply(source, raw, true, ("  %-8s %s"):format(volume.id, box.min ~= nil
                and ("closed %.1f x %.1f m, z %.2f..%.2f"):format(
                    box.max.x - box.min.x, box.max.y - box.min.y, box.min.z, box.max.z)
                or "one corner captured, waiting for the opposite one"))
        end
    end
end

-- ------------------------------------------------------------------ dump --

local function markLine(mark, suffix)
    if mark == nil or mark.position == nil then
        return ("    { position = nil, heading = 0.0 },%s"):format(suffix or "")
    end
    return ("    { position = { x = %.3f, y = %.3f, z = %.3f }, heading = %.1f },%s"):format(
        mark.position.x, mark.position.y, mark.position.z, mark.heading or 0.0,
        suffix or (mark.headingKnown and "" or "  -- heading not captured"))
end

local function cmdDump(source, raw)
    local session, reason = sessionOf(source)
    if session == nil then return reply(source, raw, false, reason) end
    if markCount(session) == 0 and boxCount(session) == 0 then
        return reply(source, raw, true, TEXT.dumpEmpty)
    end

    local lines = {}
    local function emit(text) lines[#lines + 1] = text or "" end

    emit("-- ==== /dm.survey dump ====================================")
    emit("-- Captured from Open77.players.position on the server. Paste each")
    emit("-- assignment over the matching block in shared/kabuki.lua, or keep the")
    emit("-- assignments as-is at the end of that file -- they are equivalent.")
    emit("")

    -- Volumes first: nothing else can be judged until the boxes exist.
    emit("DeathmatchKabuki.volumes = {")
    local volumesReady = 0
    for _, volume in ipairs(Kabuki.volumes) do
        local box = session.boxes[volume.id]
        if box ~= nil and box.min ~= nil then
            volumesReady = volumesReady + 1
            emit(("    { id = %q,"):format(volume.id))
            emit(("      min = { x = %.3f, y = %.3f, z = %.3f },"):format(
                box.min.x, box.min.y, box.min.z))
            emit(("      max = { x = %.3f, y = %.3f, z = %.3f } },"):format(
                box.max.x, box.max.y, box.max.z))
        else
            emit(("    { id = %q, min = nil, max = nil },  -- TODO not surveyed"):format(
                volume.id))
        end
    end
    emit("}")
    emit("")

    local marksReady, marksWanted = 0, 0
    for _, entry in ipairs(Kabuki.sets) do
        marksWanted = marksWanted + entry.limit
        local list = session.marks[entry.key] or {}
        marksReady = marksReady + #list
        if #list > 0 then
            emit(("%s = {"):format(entry.path))
            for index = 1, entry.limit do
                local mark = list[index]
                if entry.names ~= nil then
                    -- A named set: the entry carries its own id, and the order
                    -- of capture is the order declared in the schema.
                    local name = entry.names[index] or ("slot_" .. index)
                    if mark ~= nil then
                        emit(("    { id = %q, position = { x = %.3f, y = %.3f, z = %.3f }, heading = %.1f },%s"):format(
                            name, mark.position.x, mark.position.y, mark.position.z,
                            mark.heading or 0.0,
                            mark.headingKnown and "" or "  -- heading not captured"))
                    else
                        emit(("    { id = %q, position = nil, heading = 0.0 },  -- TODO"):format(name))
                    end
                elseif mark ~= nil then
                    emit(markLine(mark))
                else
                    emit(markLine(nil, ("  -- TODO %02d"):format(index)))
                end
            end
            emit("}")
            emit("")
        end
    end

    -- The flag is a claim about the whole map, so it is only ever emitted when
    -- the whole map is there. A half-surveyed map that announces itself as
    -- surveyed is worse than one that admits it is not.
    if volumesReady == #Kabuki.volumes and marksReady == marksWanted then
        emit("DeathmatchKabuki.surveyed = true")
    else
        emit(("-- DeathmatchKabuki.surveyed = true  -- withheld: %d/%d volumes, %d/%d marks"):format(
            volumesReady, #Kabuki.volumes, marksReady, marksWanted))
    end
    emit("-- ==== end of dump ========================================")

    -- One write, not one per line: section 6 of writing-a-gamemode.md was paid
    -- for by a probe that reported 291 ms where the truth was 14 ms. A dump is
    -- not a tick, but the habit is cheap and the console output is identical.
    print("\n" .. table.concat(lines, "\n"))
    reply(source, raw, true, TEXT.dumped:format(
        #lines, volumesReady, #Kabuki.volumes, marksReady, marksWanted))
end

-- ---------------------------------------------------------------- commit --
--
-- The bridge between this file's DRAFT and the live map store.
--
-- `dump` was always the wrong last mile: it printed text a person had to paste
-- into `shared/kabuki.lua`, and that write hot-swaps the resource set --
-- despawning every bot, dropping every player out of their instance. `commit`
-- pushes the same draft into `server/mapstore.lua`'s active map instead, where
-- it applies immediately and nothing reloads.
--
-- The draft is KEPT rather than consumed. Committing is not a decision to stop
-- surveying, `dump` still has to work afterwards for the promote-to-built-in
-- path, and destroying somebody's walked marks as a side effect of saving them
-- would be the worst possible reading of "commit".
local function cmdCommit(source, raw)
    local session, reason = sessionOf(source)
    if session == nil then return reply(source, raw, false, reason) end

    local store = rawget(_G, "Deathmatch")
    store = store ~= nil and store.maps or nil
    if type(store) ~= "table" or type(store.save) ~= "function" then
        return reply(source, raw, false, TEXT.commitNoStore)
    end

    local map = store.active()
    if map == nil then return reply(source, raw, false, TEXT.commitNoStore) end
    if map.builtin then
        return reply(source, raw, false, TEXT.commitBuiltin:format(map.name, map.name))
    end

    -- Marks. The destination list is resolved by the STORE, from the same set
    -- key this file already uses, so the two files cannot disagree about what
    -- `3v3_a` means.
    local marks, sets = 0, 0
    for _, entry in ipairs(Kabuki.sets) do
        local drafted = session.marks[entry.key]
        if drafted ~= nil and #drafted > 0 then
            local destination, definition = store.list(map, entry.key)
            if destination ~= nil then
                sets = sets + 1
                if definition.kind == "named" then
                    -- A named slot is replaced in place: the pair IS the
                    -- schema, and client/station.lua reads it positionally.
                    for index, mark in ipairs(drafted) do
                        local id = definition.names[index]
                        if id ~= nil and destination[index] ~= nil then
                            destination[index] = { id = id, position = mark.position,
                                                   heading = mark.heading or 0.0 }
                            marks = marks + 1
                        end
                    end
                else
                    for index = #destination, 1, -1 do destination[index] = nil end
                    for index, mark in ipairs(drafted) do
                        destination[index] = {
                            position = mark.position, heading = mark.heading or 0.0,
                            headingKnown = mark.headingKnown == true,
                        }
                        marks = marks + 1
                    end
                end
            end
        end
    end

    -- Volumes. Only CLOSED boxes travel: half a box is not a smaller box, and
    -- a volume with one corner would suspend containment for every zone that
    -- names it while looking like progress.
    local volumes = 0
    for id, box in pairs(session.boxes) do
        if box.min ~= nil and box.max ~= nil then
            local volume = store.volume(map, id)
            if volume ~= nil then
                volume.min = { x = box.min.x, y = box.min.y, z = box.min.z }
                volume.max = { x = box.max.x, y = box.max.y, z = box.max.z }
                volumes = volumes + 1
            end
        end
    end

    local zoned = store.autoZone(map)
    store.save(map)
    reply(source, raw, true, TEXT.commitDone:format(map.name, marks, sets, volumes))
    if zoned ~= nil then
        reply(source, raw, true, TEXT.commitZoned:format(table.concat(zoned, ",")))
    end
end


-- ----------------------------------------------------------------- clear --

local function cmdClear(source, raw, args)
    local session, reason = sessionOf(source)
    if session == nil then return reply(source, raw, false, reason) end

    local what = tostring(args[1] or "all"):lower()
    local cleared = nil
    if what == "all" then
        session.marks, session.boxes = {}, {}
        session.marks[session.setKey] = {}
        cleared = "everything"
    elseif what == "marks" then
        session.marks = {}
        session.marks[session.setKey] = {}
        cleared = "all marks"
    elseif what == "boxes" then
        session.boxes = {}
        cleared = "all volumes"
    elseif Kabuki.set(what) ~= nil then
        if session.marks[what] == nil or #session.marks[what] == 0 then
            return reply(source, raw, false, TEXT.clearNothing:format(what))
        end
        session.marks[what] = {}
        cleared = "set '" .. what .. "'"
    elseif Kabuki.volume(what) ~= nil then
        if session.boxes[what] == nil then
            return reply(source, raw, false, TEXT.clearNothing:format(what))
        end
        session.boxes[what] = nil
        cleared = "volume '" .. what .. "'"
    else
        return reply(source, raw, false, TEXT.usageClear)
    end

    reply(source, raw, true, TEXT.cleared:format(
        cleared, markCount(session), boxCount(session)))
end

-- -------------------------------------------------------------- commands --

local DISPATCH = {
    start = cmdStart,
    mark  = cmdMark,
    box   = cmdBox,
    list   = cmdList,
    dump   = cmdDump,
    commit = cmdCommit,
    clear  = cmdClear,
}

-- ACL-gated exactly as race/server/main.lua gates `/race.editor`: the third
-- argument of RegisterCommand is the restriction, and it is the whole gate.
-- Nothing inside re-checks it, so nothing inside can forget to.
RegisterCommand("dm.survey", function(source, args, raw)
    source = playerKey(source)
    if source == nil then return reply(0, raw, false, TEXT.playerOnly) end

    local verb = tostring(args[1] or ""):lower()
    local handler = DISPATCH[verb]
    if handler == nil then return reply(source, raw, false, TEXT.usage) end

    -- Hand the subcommand its own arguments, one-based, so each reads as if it
    -- were the whole command.
    local tail = {}
    for index = 2, (args.n or #args) do tail[index - 1] = args[index] end
    handler(source, raw, tail)
end, true)

-- --------------------------------------------------------------- dm.where --

-- The diagnostic section 6 of writing-a-gamemode.md insists on: print what the
-- SERVER sees. Position, bucket, readiness, life, the containing volume, the
-- verdict, and the reason -- because nearly every confusing failure this
-- project has hit was answered in one line by a command like this, after being
-- guessed at for far longer.
--
-- Unrestricted, and self-only for a player: an id argument would let anyone
-- read anyone's position. The console has no position of its own, so from the
-- console the id is required instead.
RegisterCommand("dm.where", function(source, args, raw)
    local caller = playerKey(source)
    local playerId, format

    if caller ~= nil then
        playerId = caller
        format = args[1]
    else
        playerId = playerKey(args[1])
        format = args[2]
        if playerId == nil then return reply(0, raw, false, TEXT.usageWhereConsole) end
    end

    -- The instance kernel's registry, when it has been loaded. Consulted first
    -- because it answers the question the format argument only guesses at: the
    -- zone actually being enforced on this player is the one their instance
    -- owns, not the one whoever typed the command had in mind.
    local instance = instanceOf(playerId)

    format = tostring(format or (instance and instance.format) or "ffa"):lower()
    if Kabuki.formats[format] == nil then
        return reply(source, raw, false, caller ~= nil
            and TEXT.usageWherePlayer or TEXT.usageWhereConsole)
    end

    local point, failure = callerPosition(playerId)
    if point == nil then return reply(source, raw, false, TEXT.noPosition:format(failure)) end

    reply(source, raw, true, TEXT.whereLine:format(
        playerId, point.x, point.y, point.z, point.bucket,
        tostring(Open77.ready.isReady(playerId)),
        tostring(Open77.players.isDead(playerId))))

    if instance == nil then
        reply(source, raw, true, TEXT.whereNoInstance)
    else
        -- A player whose bucket does not match their instance's is the failure
        -- this line exists to catch: they are registered in an arena they
        -- cannot see, and every bounds verdict about them is meaningless.
        reply(source, raw, true, TEXT.whereInstance:format(
            tostring(instance.id), tostring(instance.format), tostring(instance.zone),
            tostring(instance.bucket), tostring(point.bucket == instance.bucket)))
    end

    local zone = Kabuki.zone(format)
    local volumeId, reason = Kabuki.locate(point, zone)
    reply(source, raw, true, TEXT.whereVerdict:format(
        format, table.concat(zone, ","), volumeId or "none",
        tostring(volumeId ~= nil), reason or "contained"))

    if volumeId == nil then
        local nearestId, distance, dx, dy, dz = Kabuki.nearest(point, zone)
        if nearestId == nil then
            reply(source, raw, true, TEXT.whereNoNearest)
        else
            reply(source, raw, true, TEXT.whereNearest:format(nearestId, distance, dx, dy, dz))
        end
    end

    -- The SECOND map. shared/config.lua carries its own `map.volumes` and
    -- `zones` -- the same seven ids plus two provisional boxes -- and that is
    -- what bounds.lua will enforce. Until the duplication is settled, a
    -- diagnostic that reported only this file's schema would be answering a
    -- question nobody asked: it would say "outside" while the running mode said
    -- "inside", which is precisely the class of confusion /dm.where exists to
    -- end. So both are judged, by the same six comparisons, and labelled.
    local configVolumes, configZone = configGeometry(format)
    if configVolumes ~= nil then
        local configId, configReason = Kabuki.locateIn(configVolumes, point, configZone)
        reply(source, raw, true, TEXT.whereConfig:format(
            configZone and table.concat(configZone, ",") or "all",
            configId or "none", tostring(configId ~= nil), configReason or "contained"))
        if configId == nil then
            local nearId, distance, dx, dy, dz = Kabuki.nearestIn(configVolumes, point, configZone)
            if nearId ~= nil then
                reply(source, raw, true, TEXT.whereNearest:format(
                    "config:" .. nearId, distance, dx, dy, dz))
            end
        end
        -- Only a real disagreement is worth shouting about. Before Phase 1 is
        -- walked this file's schema cannot judge anything, and "the empty map
        -- disagrees with the provisional one" would fire on every single call
        -- until it meant nothing at all.
        local judged = volumeId ~= nil
            or (reason ~= "not_surveyed" and reason ~= "zone_empty")
        if judged and (configId ~= nil) ~= (volumeId ~= nil) then
            reply(source, raw, true, TEXT.whereDisagree)
        end
    end

    -- The caller's own draft, when they have one: during Phase 1 "what the
    -- server sees" includes how far the survey has got.
    local session = sessions[playerId]
    if session == nil then
        reply(source, raw, true, TEXT.whereNoSession)
    else
        local openBox = "none"
        for _, volume in ipairs(Kabuki.volumes) do
            local box = session.boxes[volume.id]
            if box ~= nil and box.min == nil then openBox = volume.id break end
        end
        reply(source, raw, true, TEXT.whereSession:format(
            session.setKey, markCount(session), openBox))
    end

end, false)

-- ---------------------------------------------------------------- events --

-- The id arrives as a string here, like every lifecycle event.
AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = playerKey(playerIdStr)
    if playerId == nil then return end
    sessions[playerId] = nil
    local dm = rawget(_G, "Deathmatch")
    if dm ~= nil and dm.bounds ~= nil and dm.bounds.setExempt ~= nil then
        dm.bounds.setExempt(playerId, false, "survey")
    end
    tellClientToReport(playerId, false)
end)

local progress = Kabuki.progress()
log(("ready -- dm.survey (ACL) / dm.where; Kabuki %d/%d volumes, %d/%d marks%s"):format(
    progress.volumesReady, progress.volumesWanted,
    progress.marksReady, progress.marksWanted,
    progress.complete and "" or " -- Phase 1 has not been walked yet"))
log("draft-and-paste is no longer the only path: /dm.map edits the live map in place, and 'dm.survey commit' pushes a walked draft straight into it.")
