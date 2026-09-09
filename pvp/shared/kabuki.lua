-- Kabuki Arena map data -- the surveyed geometry of the one PvP map.
--
-- ---------------------------------------------------------------------------
-- THIS FILE IS NOW THE BUILT-IN DEFAULT OF A RUNTIME MAP STORE.
--
-- `server/mapstore.lua` snapshots the tables below at load, before anything
-- can write to them, and registers the snapshot as the map named `kabuki`.
-- From then on the geometry the mode reads is whichever map the `activeMap`
-- tunable selects, applied INTO these same tables -- which is why every
-- consumer in the resource is unchanged and why there is still exactly one
-- containment test.
--
-- Three consequences worth knowing before editing this file:
--
--   1. The built-in is never destroyed and never written to. An empty store
--      plays it, `/dm.map select kabuki` restores it, and `/dm.map export`
--      prints a runtime map in exactly the block shapes below so a finished
--      map can be PASTED HERE and become a built-in under source control.
--      That paste is the one remaining reason to edit this file by hand -- and
--      it hot-swaps the resource set, so it is done deliberately and never
--      mid-session.
--
--   2. `Kabuki.volumes`, `.spawns`, `.teams` and `.stations` are REPLACED
--      wholesale at runtime. Nothing may hold a reference to one of them
--      across a call; read through `DeathmatchKabuki` at the point of use, the
--      way `spawnFor`, `arena.lua` and `bounds.lua` already do.
--
--   3. `Kabuki.surveyed` is RECOMPUTED on every apply, from the volumes the
--      active map's zones actually name. The paragraph below still governs
--      what it means; it is simply measured now instead of asserted.
--
-- Plan §12 decision 5 ("one map, four zones") is intact and was re-decided
-- explicitly rather than drifted: the mode still plays ONE map at a time. See
-- decision 21 in docs/gamemode-pvp-arena-plan.md.
-- ---------------------------------------------------------------------------
--
-- THE COORDINATES IN THIS FILE DO NOT EXIST YET. Every position is an explicit
-- `nil` and every heading an explicit `0.0`: this file is the *shape* the data
-- takes, and Phase 1 fills it in-game with `/dm.survey` (server/survey.lua),
-- which dumps assignment statements that replace the placeholder blocks below.
-- See docs/gamemode-pvp-arena-plan.md section 3 and Phase 1.
--
-- Why placeholders rather than an empty table: the counts are decisions, not
-- accidents. Seven volumes, fourteen FFA marks, three marks a side for 3v3, two
-- lobby stations. A surveyor who sees fourteen empty slots knows the job is not
-- done at eight; an empty table tells them nothing.
--
-- Why boxes and not a cylinder or a polygon prism (decision 6): Kabuki is a
-- gallery six metres above a sunken floor, so a cylinder either clips the
-- bridge off or swallows the street outside. A box containment test is six
-- comparisons and is trivially correct; a polygon needs an ordered ring and a
-- winding test and buys nothing at this scale. A point is inside the arena if
-- it is inside ANY volume of the format's zone.
--
-- Shared rather than server-only on purpose: the wall is a client-side clamp
-- (decision 15, settled by E2) and the clamp needs exactly this geometry.
--
-- ---------------------------------------------------------------------------
-- UNRESOLVED: THERE ARE TWO MAPS IN THIS RESOURCE.
--
-- `shared/config.lua` grew a `DeathmatchConfig.map` block carrying the same
-- seven volume ids, the same zone lists and provisional North Watson spawn
-- marks, plus `DeathmatchConfig.zones`. That is the same geometry in a second
-- place, and two containment tests that can disagree are a bug waiting to
-- happen. One of the two must win before Phase 2 builds on either.
--
-- Nothing here reaches into that block: this file declares a shape and owns the
-- geometry FUNCTIONS, and every one of them takes its volume list as an
-- argument (`locateIn`, `nearestIn`, `contains`, `distanceTo`), so whichever
-- store wins, the test that judges it is this one. `/dm.where` currently
-- reports BOTH sources side by side, labelled, which is the honest state of
-- affairs until the duplication is settled.
-- ---------------------------------------------------------------------------

DeathmatchKabuki = {}
local Kabuki = DeathmatchKabuki

-- Flipped to true in the block the surveyor pastes. Everything that reads this
-- file must degrade honestly while it is false rather than silently treating an
-- unsurveyed map as an empty one: an empty zone contains nothing, and a bounds
-- check that contains nothing places every player on every tick.
-- TRUE as of 2026-09-01, and the honesty this flag demands is preserved by
-- narrowing the formats rather than by pretending the map is fully walked.
-- Every format now lists only `market`, which HAS a box, so no zone in use is
-- unsurveyed and containment is real everywhere it is claimed. The comment
-- above still governs: a nil volume must suspend containment, and none is in
-- use. `lower`, `gallery` and the four stairs remain uncaptured and unused.
Kabuki.surveyed = true

-- --------------------------------------------------------------- volumes --

-- Order is reporting priority, not geometry: a point inside an overlap is
-- reported as the FIRST match, so the two floors and the ring come before the
-- stairs that join them -- a stair necessarily overlaps the decks at its ends,
-- and "you are on the market floor" is the more useful of the two answers.
--
-- `min` / `max` are opposite corners of an axis-aligned box in world space,
-- componentwise. `/dm.survey box <id>` captures two ground samples and derives
-- the vertical extent from them; see `boxFromCorners` for why the two samples
-- on their own cannot produce a usable box.
Kabuki.volumes = {
    -- Phase 1 replaces this whole list with the `/dm.survey dump` output.
    -- PROVISIONAL, derived 2026-08-31 from the extent of the fourteen
    -- surveyed FFA marks plus a 10 m margin, NOT from a corner capture.
    -- It exists so the arena is playable before the boxes are walked: an
    -- unsurveyed zone suspends containment entirely, which means no wall,
    -- no rounds and no bots.
    --
    -- Deriving a VOLUME this way is sound where deriving a spawn mark is
    -- not. A mark asserts that its ground is walkable, and Corpo Plaza
    -- proved nearby XY does not imply that; a box asserts only "the arena
    -- is somewhere in here", and every point it was built from was stood
    -- on. Replace it with `/dm.survey box market` when the corners are
    -- walked -- this is a floor to build on, not an answer.
    { id = "market", min = { x = -1257.272, y = 1940.171, z = 4.763 },
                     max = { x = -1139.223, y = 2097.440, z = 23.941 } },
    -- WALKED 2026-09-01, both corners grounded. The comment estimated -3 m;
    -- the floor is actually at z 2.83, roughly FIVE metres below the market
    -- deck at 7.8. It is also a small room (12 x 11 m), not a wide sunken
    -- centre -- which is why 1v1 was given it: one room, no third angle.
    { id = "lower",    min = { x = -1207.146, y = 2030.000, z = 2.332 },
                       max = { x = -1195.000, y = 2041.200, z = 8.866 } },
    -- WALKED 2026-09-01, both corners from grounded samples via the in-game
    -- map editor. Not the full ring the comment above assumed: the deck runs
    -- along the NORTH edge only -- probing the south-west corner at
    -- (-1240, 1960) returned market floor at z 7.98, not gallery.
    { id = "gallery",  min = { x = -1215.000, y = 2078.000, z = 11.441 },
                       max = { x = -1173.115, y = 2087.440, z = 17.000 } },
    { id = "stair_nw", min = nil, max = nil },
    { id = "stair_ne", min = nil, max = nil },
    { id = "stair_sw", min = nil, max = nil },
    { id = "stair_se", min = nil, max = nil },
}

-- ---------------------------------------------------------------- spawns --

-- Fourteen marks for a twelve-player instance (decision 13): roughly one per
-- player, plus the headroom the maximin spawn choice needs to mean anything.
--
-- Every one of these must be an ACTUAL ground sample captured while walking the
-- deck continuously. The shipped North Watson marks carry the reason in
-- shared/config.lua and it is worth repeating here: do not derive offsets
-- around a mark, because Corpo Plaza proved that nearby XY does not imply
-- nearby walkable ground.
Kabuki.spawns = {
    ffa = {
        { position = { x = -1160.499, y = 2019.064, z = 7.763 }, heading = 104.0 },  -- 01
        { position = { x = -1149.223, y = 2054.840, z = 7.764 }, heading = 348.6 },  -- 02
        { position = { x = -1173.115, y = 2087.440, z = 11.941 }, heading = 237.3 },  -- 03
        { position = { x = -1191.302, y = 2006.883, z = 7.816 }, heading = 334.8 },  -- 04
        { position = { x = -1218.649, y = 2022.934, z = 7.816 }, heading = 257.5 },  -- 05
        { position = { x = -1220.135, y = 2048.270, z = 7.817 }, heading = 319.9 },  -- 06
        { position = { x = -1212.332, y = 2082.062, z = 7.847 }, heading = 204.5 },  -- 07
        { position = { x = -1192.751, y = 2072.839, z = 7.816 }, heading = 10.1 },  -- 08
        { position = { x = -1218.127, y = 1950.171, z = 7.984 }, heading = 38.1 },  -- 09
        { position = { x = -1247.272, y = 1973.837, z = 7.966 }, heading = 245.2 },  -- 10
        { position = { x = -1223.905, y = 1989.450, z = 7.984 }, heading = 344.7 },  -- 11
        { position = { x = -1212.264, y = 1978.527, z = 7.984 }, heading = 112.5 },  -- 12
        { position = { x = -1178.658, y = 2028.453, z = 7.954 }, heading = 114.6 },  -- 13
        { position = { x = -1204.229, y = 2068.211, z = 7.886 }, heading = 23.9 },  -- 14
    },
}

-- Two clusters, A and B on opposite approaches -- but one pair per format
-- rather than one pair overall. Section 3 gives each arena format a different
-- carved zone: 3v3 plays the whole footprint, 2v2 loses the gallery, and 1v1 is
-- the sunken room alone. A 1v1 taking the first mark of the 3v3 alley cluster
-- would spawn both duellists outside their own zone, and the bounds check would
-- then "correct" that by killing them. So each format captures its own pair of
-- clusters; the cost is six extra marks and it buys a rule with no exceptions.
-- Derived 2026-09-01 from the fourteen WALKED ffa marks rather than captured
-- separately, which is sound for the reason this file already gives: every
-- coordinate below is ground somebody stood on, so the Corpo Plaza failure
-- (nearby XY does not imply walkable) cannot apply. Sides are picked for
-- maximum separation -- 3v3 north vs south at 115 m, 2v2 at 117 m, 1v1 at
-- 98 m -- and each mark faces the OPPOSING cluster's centroid, so a round
-- opens looking at the fight instead of away from it.
--
-- These are honest and playable, not designed. Re-capture with
-- `/dm.survey start 3v3` once somebody has an opinion about arena geometry;
-- the point of landing them is that all three formats refuse to START while
-- a single mark is nil, so nothing about the arena could be tested at all.
Kabuki.teams = {
    ["3v3"] = {
        a = {
            { position = { x = -1173.115, y = 2087.440, z = 11.941 }, heading = 156.2 },  -- mark 03
            { position = { x = -1192.751, y = 2072.839, z = 7.816 }, heading = 162.5 },  -- mark 08
            { position = { x = -1204.229, y = 2068.211, z = 7.886 }, heading = 167.9 },  -- mark 14
        },
        b = {
            { position = { x = -1218.127, y = 1950.171, z = 7.984 }, heading = 347.4 },  -- mark 09
            { position = { x = -1247.272, y = 1973.837, z = 7.966 }, heading = 330.8 },  -- mark 10
            { position = { x = -1212.264, y = 1978.527, z = 7.984 }, heading = 347.2 },  -- mark 12
        },
    },
    ["2v2"] = {
        a = {
            { position = { x = -1149.223, y = 2054.840, z = 7.764 }, heading = 139.8 },  -- mark 02
            { position = { x = -1173.115, y = 2087.440, z = 11.941 }, heading = 157.8 },  -- mark 03
        },
        b = {
            { position = { x = -1218.127, y = 1950.171, z = 7.984 }, heading = 334.8 },  -- mark 09
            { position = { x = -1223.905, y = 1989.450, z = 7.984 }, heading = 322.5 },  -- mark 11
        },
    },
    ["1v1"] = {
        -- MOVED INTO `lower` 2026-09-01. The derived marks sat in the market,
        -- 36 m and 69 m OUTSIDE the 1v1 zone -- exactly the failure the header
        -- warns about: both duellists spawn outside their own zone and the
        -- bounds check then "corrects" them. `dm.map check` caught it the
        -- moment the carved zones became real, which is what that command is
        -- for. Both are grounded samples from walking the room.
        a = { { position = { x = -1207.146, y = 2041.200, z = 3.866 }, heading = 227.3 } },
        b = { { position = { x = -1195.000, y = 2030.000, z = 2.832 }, heading = 47.3 } },
    },
}

-- The two lobby stations of section 5. They are marks like any other -- a
-- position and a facing -- and they are surveyed in the same pass, because the
-- surveyor is already standing in the lobby when the session opens.
--
-- One survey constraint belongs with the numbers rather than with the renderer:
-- open77_worldui activates at `radius + 0.5 m`, and two stations placed closer
-- than the sum of their activations leave a dead band in which NEITHER prompt
-- is live.
--
-- THE MINIMUM IS 6.0 m, NOT 4.6 m. This comment said 4.6 -- the sum of the two
-- ring radii plus their activation pads -- while `Config.stations.minSeparationMetres`
-- has enforced 6.0 all along, and both `server/bounds.lua` and
-- `client/station.lua` read the config value. A pair captured at 5.98 m
-- therefore looked correct against this comment and was rejected by the code,
-- and the round it cost is the reason the number is no longer written twice:
-- `/dm.map check` and `/dm.map station` both PRINT the enforced value rather
-- than quoting one. Never restate a number a rule owns.
-- Surveyed 2026-09-01 in the lobby, both from grounded server samples:
-- `enter` via `/dm.survey mark`, `queue` from a `dm.goto` that reported
-- `grounded=yes` at rest. Separation 5.98 m, clear of the 4.6 m dead band the
-- comment above forbids.
--
-- These are HONEST but not considered: they sit where the lobby spawn happens
-- to put you, not where a designer would place a pair of rings. Re-capture them
-- with `/dm.survey start station` once someone has an opinion about the lobby
-- layout -- the point of landing them now is that the station cannot be drawn,
-- and therefore cannot be tested at all, while they are nil.
Kabuki.stations = {
    { id = "enter", position = { x = 1669.754, y = -739.133, z = 49.845 },
      heading = 0.0 },    -- ENTER THE ARENA, 2.0 m ring
    -- Re-captured 2026-09-01 after the owner reported the ring looked wrong:
    -- the previous point was EXTRAPOLATED 1.5 m past a grounded sample rather
    -- than stood on, and it landed on a slope 0.9 m above the enter ring. A
    -- ground circle is drawn as a flat ring at a single z, so on sloping ground
    -- it floats at one edge and sinks at the other -- which is exactly what
    -- "not on a flat floor" looks like. Height agreement between the two marks
    -- is therefore a real requirement, not tidiness.
    --
    -- This point is a grounded sample: 7.05 m from the enter ring (clear of the
    -- 6.0 m minimum the CODE enforces -- the 4.6 m in the comment above is
    -- wrong) and 0.10 m of rise across that span, about a 0.8 degree slope.
    { id = "queue", position = { x = 1676.800, y = -739.132, z = 49.947 },
      heading = 270.0 },  -- ARENA QUEUE, 1.6 m ring
}

-- --------------------------------------------------------------- formats --

-- Which volumes each format plays in, and how many spawn marks a side takes.
-- `capacity` is the roster ceiling, not the mark count.
Kabuki.formats = {
    -- Every format plays `market` alone for now, for the reason spelled out
    -- below: it is the only volume with a box, and a format that lists a nil
    -- volume has its containment SUSPENDED -- which is why the wall did not
    -- exist. One surveyed box that is enforced beats seven declared boxes that
    -- are not. The full list is kept here so restoring it is a paste:
    --
    --   volumes = { "market", "lower", "gallery",
    --               "stair_nw", "stair_ne", "stair_sw", "stair_se" },
    --
    -- The market box spans z 4.763 to 23.941, so it already contains BOTH decks
    -- -- the market floor near z 7.8 and the upper bridge near z 12 to 24. The
    -- boundary it enforces is therefore a real wall on both levels, not a floor
    -- plan; what the other six volumes would add is a tighter fit around the
    -- stairs and the sunken room, not a second storey.
    ffa = {
        volumes = { "market", "lower", "gallery" },
        capacity = 12,
        marks = "ffa",
    },
    ["3v3"] = {
        volumes = { "market", "lower", "gallery" },
        capacity = 6, perSide = 3, teams = "3v3",
    },
    -- PROVISIONAL ZONES, and this is a §12 re-decision recorded rather than
    -- slipped in. The plan carves a different zone per format -- 2v2 loses the
    -- gallery, 1v1 is the sunken room alone -- and that intent stands. But
    -- `lower` and `gallery` have NO BOX: only `market` has been surveyed, and a
    -- format whose zone does not exist cannot start, so 1v1 and 2v2 were
    -- unplayable rather than differently-shaped.
    --
    -- Pointing both at `market` for now makes all three formats run against the
    -- one real volume. It costs exactly what the plan says it costs: 1v1 gets a
    -- third angle it should not have, and 2v2 keeps overwatch it should lose.
    -- Restore the lines below the moment `/dm.survey box lower` and
    -- `box gallery` are walked -- the team marks do not have to move, only the
    -- zone list.
    --
    --   ["2v2"] = { volumes = { "market", "lower" }, ... }
    --   ["1v1"] = { volumes = { "lower" }, ... }
    ["2v2"] = { volumes = { "market", "lower" }, capacity = 4, perSide = 2, teams = "2v2" },
    ["1v1"] = { volumes = { "lower" }, capacity = 2, perSide = 1, teams = "1v1" },
}

-- -------------------------------------------------------- capture targets --

-- The sets `/dm.survey` can append to, in dump order. Each carries the Lua path
-- the dump emits, so survey.lua never has to know this schema's layout: the
-- file owns its own shape, and declaring a set here is the only edit a new
-- capture target needs.
--
-- `names` marks a set whose entries are identified rather than numbered; the
-- surveyor captures them in this order.
Kabuki.sets = {
    { key = "ffa", limit = 14, label = "FFA spawn marks",
      path = "DeathmatchKabuki.spawns.ffa",
      resolve = function() return Kabuki.spawns.ffa end },

    -- `resolve` reads through `Kabuki.teams` at CALL time and tolerates a
    -- missing format key, which matters now that the tables below are replaced
    -- wholesale by the live map editor (`server/mapstore.lua`). The editor
    -- guarantees every format key exists, but a nil-safe read costs nothing and
    -- a raise inside `Kabuki.progress()` would take down the surveyor's own
    -- readout -- the one thing that must keep working while a map is half
    -- authored.
    { key = "3v3_a", limit = 3, label = "3v3 team A",
      path = "DeathmatchKabuki.teams[\"3v3\"].a",
      resolve = function() return (Kabuki.teams["3v3"] or {}).a end },
    { key = "3v3_b", limit = 3, label = "3v3 team B",
      path = "DeathmatchKabuki.teams[\"3v3\"].b",
      resolve = function() return (Kabuki.teams["3v3"] or {}).b end },
    { key = "2v2_a", limit = 2, label = "2v2 team A",
      path = "DeathmatchKabuki.teams[\"2v2\"].a",
      resolve = function() return (Kabuki.teams["2v2"] or {}).a end },
    { key = "2v2_b", limit = 2, label = "2v2 team B",
      path = "DeathmatchKabuki.teams[\"2v2\"].b",
      resolve = function() return (Kabuki.teams["2v2"] or {}).b end },
    { key = "1v1_a", limit = 1, label = "1v1 side A",
      path = "DeathmatchKabuki.teams[\"1v1\"].a",
      resolve = function() return (Kabuki.teams["1v1"] or {}).a end },
    { key = "1v1_b", limit = 1, label = "1v1 side B",
      path = "DeathmatchKabuki.teams[\"1v1\"].b",
      resolve = function() return (Kabuki.teams["1v1"] or {}).b end },

    { key = "station", limit = 2, label = "Lobby stations",
      path = "DeathmatchKabuki.stations", names = { "enter", "queue" },
      resolve = function() return Kabuki.stations end },
}

function Kabuki.set(key)
    for _, entry in ipairs(Kabuki.sets) do
        if entry.key == key then return entry end
    end
    return nil
end

function Kabuki.setKeys()
    local keys = {}
    for index, entry in ipairs(Kabuki.sets) do keys[index] = entry.key end
    return keys
end

-- -------------------------------------------------------------- geometry --

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

-- A point is `{ x, y, z }`; anything else -- a missing position, a read taken
-- mid-transition -- is not a point and must not be judged. Returning nil rather
-- than a zeroed vector is deliberate: (0,0,0) is a real place in Night City, so
-- a bounds check handed a silent zero would return a confident verdict about
-- somewhere the player has never stood.
function Kabuki.point(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = finite(value.x), finite(value.y), finite(value.z)
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

function Kabuki.volume(id)
    for _, volume in ipairs(Kabuki.volumes) do
        if volume.id == id then return volume end
    end
    return nil
end

-- A volume counts only once both corners exist. Half a box is not a smaller
-- box: `min` alone would be compared against an uninitialised `max`.
function Kabuki.isSurveyed(volume)
    return type(volume) == "table"
        and Kabuki.point(volume.min) ~= nil
        and Kabuki.point(volume.max) ~= nil
end

-- The volume ids a format plays in. Named rather than inlined because the
-- containment test and `/dm.where` must never disagree about which volumes
-- count -- a diagnostic that judges a different set from the enforcement is
-- worse than no diagnostic.
function Kabuki.zone(format)
    local definition = Kabuki.formats[format or "ffa"] or Kabuki.formats.ffa
    return definition and definition.volumes or {}
end

-- A lobby station mark by id, or nil.
--
-- `nil` here has ONE meaning and it is the useful one: the station has not been
-- surveyed yet. A mark with no position is not a station at the origin and not
-- a station at the lobby centre -- it is an absence, and the client draws
-- nothing rather than putting a ring somewhere nobody chose. `Kabuki.point`
-- does the rejecting, so a half-written mark (`{ x = 1 }`) is an absence too.
--
-- Capture both with:  /dm.survey start station  ->  mark  ->  mark  ->  dump
-- and paste the emitted `DeathmatchKabuki.stations` block over the one above.
-- The order is the one `Kabuki.sets` declares: `enter` first, then `queue`.
function Kabuki.station(id)
    for _, mark in ipairs(Kabuki.stations) do
        if mark.id == id then
            local position = Kabuki.point(mark.position)
            if position == nil then return nil end
            return { id = mark.id, position = position,
                     heading = tonumber(mark.heading) or 0.0 }
        end
    end
    return nil
end

-- How far apart the two stations actually are, on the ground plane, or nil when
-- either is unsurveyed. The renderer checks this against
-- `Config.stations.minSeparationMetres`: two prompts closer than the sum of
-- their activations leave a DEAD BAND where neither is live, which is worse
-- than an overlap because an overlap is at least arbitrated.
function Kabuki.stationSeparation()
    local enter, queue = Kabuki.station("enter"), Kabuki.station("queue")
    if enter == nil or queue == nil then return nil end
    local dx = queue.position.x - enter.position.x
    local dy = queue.position.y - enter.position.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Two ground samples do not make a box.
--
-- The plan's capture is "walk to a corner, capture, walk to the opposite
-- corner, capture" -- and both samples are taken at the surveyor's feet, so the
-- box they span is flat, or at best as tall as the deck's slope, and contains
-- nobody. The vertical extent therefore comes from the capture rather than from
-- the samples: `floorPad` below the lower sample, so a player standing exactly
-- on the ground is inside instead of on the boundary, and `height` above the
-- upper one.
--
-- This is arithmetic on captured coordinates, which the survey discipline
-- forbids for SPAWN marks -- and the distinction is the whole point. A derived
-- spawn mark asserts that a place is walkable, and Corpo Plaza proved that
-- assertion false. A box ceiling asserts nothing about the ground; it says only
-- how far up the room goes, which no amount of walking can measure anyway.
function Kabuki.boxFromCorners(first, second, options)
    local a, b = Kabuki.point(first), Kabuki.point(second)
    if a == nil or b == nil then return nil, "corner_missing" end
    options = options or {}
    local height = finite(options.height) or 8.0
    local floorPad = finite(options.floorPad) or 0.5
    if height <= 0.0 then return nil, "invalid_height" end

    return {
        min = {
            x = math.min(a.x, b.x),
            y = math.min(a.y, b.y),
            z = math.min(a.z, b.z) - floorPad,
        },
        max = {
            x = math.max(a.x, b.x),
            y = math.max(a.y, b.y),
            z = math.max(a.z, b.z) + height,
        },
    }
end

-- Six comparisons. This is the whole reason boxes were chosen.
function Kabuki.contains(volume, point)
    if not Kabuki.isSurveyed(volume) then return false end
    local min, max = volume.min, volume.max
    return point.x >= min.x and point.x <= max.x
       and point.y >= min.y and point.y <= max.y
       and point.z >= min.z and point.z <= max.z
end

local function wanted(volumeId, volumeIds)
    if volumeIds == nil then return true end
    for _, id in ipairs(volumeIds) do
        if id == volumeId then return true end
    end
    return false
end

-- Inside if inside ANY volume of the zone. Returns the volume id, or nil plus a
-- machine-readable reason -- `/dm.where` prints that reason verbatim, because a
-- verdict with no reason is exactly the failure this diagnostic exists to end.
--
-- `volumes` is any list of `{ id, min, max }`; `volumeIds` is a list of ids (a
-- format's zone), and nil means every volume in the list.
--
-- Taking the volume list as an argument rather than reading `Kabuki.volumes` is
-- what lets one implementation judge every source of geometry in the mode --
-- this schema, `DeathmatchConfig.map.volumes`, or a zone assembled at runtime.
-- Two containment tests that can disagree is a bug waiting for a Friday.
function Kabuki.locateIn(volumes, point, volumeIds)
    point = Kabuki.point(point)
    if point == nil then return nil, "no_position" end
    if type(volumes) ~= "table" then return nil, "no_volumes" end

    local considered, ready = 0, 0
    for _, volume in ipairs(volumes) do
        if wanted(volume.id, volumeIds) then
            considered = considered + 1
            if Kabuki.isSurveyed(volume) then
                ready = ready + 1
                if Kabuki.contains(volume, point) then return volume.id, nil end
            end
        end
    end

    -- Three different "not inside" answers, and conflating them is how an
    -- unsurveyed map reads as a player standing in the street.
    if considered == 0 then return nil, "zone_empty" end
    if ready == 0 then return nil, "not_surveyed" end
    if ready < considered then
        return nil, ("outside_partial:%d_of_%d_surveyed"):format(ready, considered)
    end
    return nil, "outside"
end

function Kabuki.locate(point, volumeIds)
    return Kabuki.locateIn(Kabuki.volumes, point, volumeIds)
end

-- Distance from a point to the surface of a box, zero on every axis the point
-- already straddles. This is what turns "outside" into something actionable:
-- 0.4 m over the lip of the gallery and 40 m out in the street are the same
-- verdict and completely different problems.
function Kabuki.distanceTo(volume, point)
    if not Kabuki.isSurveyed(volume) then return nil end
    local dx = math.max(volume.min.x - point.x, 0.0, point.x - volume.max.x)
    local dy = math.max(volume.min.y - point.y, 0.0, point.y - volume.max.y)
    local dz = math.max(volume.min.z - point.z, 0.0, point.z - volume.max.z)
    return math.sqrt(dx * dx + dy * dy + dz * dz), dx, dy, dz
end

-- The closest surveyed volume of the zone, with the per-axis overshoot.
function Kabuki.nearestIn(volumes, point, volumeIds)
    point = Kabuki.point(point)
    if point == nil or type(volumes) ~= "table" then return nil end
    local bestId, best, bestDx, bestDy, bestDz
    for _, volume in ipairs(volumes) do
        if wanted(volume.id, volumeIds) and Kabuki.isSurveyed(volume) then
            local distance, dx, dy, dz = Kabuki.distanceTo(volume, point)
            if distance ~= nil and (best == nil or distance < best) then
                bestId, best, bestDx, bestDy, bestDz = volume.id, distance, dx, dy, dz
            end
        end
    end
    return bestId, best, bestDx, bestDy, bestDz
end

function Kabuki.nearest(point, volumeIds)
    return Kabuki.nearestIn(Kabuki.volumes, point, volumeIds)
end

-- How much of the map is on the ground. Used by the survey readouts and by any
-- future consumer that has to decide whether Kabuki is usable at all yet.
function Kabuki.progress()
    local volumesReady = 0
    for _, volume in ipairs(Kabuki.volumes) do
        if Kabuki.isSurveyed(volume) then volumesReady = volumesReady + 1 end
    end

    local marksReady, marksWanted = 0, 0
    for _, entry in ipairs(Kabuki.sets) do
        marksWanted = marksWanted + entry.limit
        for _, mark in ipairs(entry.resolve() or {}) do
            if Kabuki.point(mark.position) ~= nil then marksReady = marksReady + 1 end
        end
    end

    return {
        volumesReady = volumesReady,
        volumesWanted = #Kabuki.volumes,
        marksReady = marksReady,
        marksWanted = marksWanted,
        complete = volumesReady == #Kabuki.volumes and marksReady == marksWanted,
    }
end
