-- Kabuki Arena -- the RUNTIME MAP STORE and the live in-world map editor.
--
-- The bottleneck this file exists to remove: until now the only way to get a
-- coordinate into the mode was `/dm.survey` -> a printed dump -> a human paste
-- into `shared/kabuki.lua` -> a resource reload. Twenty-eight marks and seven
-- volumes went through that loop, and it blocked three arena formats and the
-- entry station for the whole life of the mode.
--
-- `/dm.map` closes the loop: walk somewhere, capture, and the very next spawn
-- uses it. No file is written, no resource is reloaded, nothing despawns.
--
-- ===========================================================================
-- WHERE THE STORE LIVES, AND WHY THERE
-- ===========================================================================
--
-- THE CONSTRAINT THAT DECIDES EVERYTHING: the dev server watches `resources/`
-- at 1 Hz and ANY write there hot-swaps the whole resource set -- which
-- despawns every bot, drops every player out of their instance, and has
-- crashed the client. So the store MUST NOT be a file under `resources/`.
-- Three candidates were weighed:
--
--   1. `Open77.tunables` -- REJECTED for the geometry. It does persist, to
--      `server/tunables.json`, which is outside `resources/` and survives a
--      reload, a stop and a server restart with no database at all. But
--      `ResourceTunables.MaximumTextLength` is 256 CHARACTERS per string value
--      and keys must be DECLARED at load: a map is roughly 4 KB of JSON and
--      its shape is authored at runtime, so it cannot be expressed as declared
--      scalars. Sharding a map across 128 declared keys would be a filesystem
--      built out of a settings form.
--
--      It IS used, for exactly the one thing that fits: `activeMap`, the NAME
--      of the map this server plays. That is a <=32-character string, it is a
--      per-server SETTING rather than runtime state, and putting it here means
--      the selection survives a restart even on a server with no database --
--      which is the shape the dev server actually runs in. One durable fact,
--      one source of truth, no second copy in a table to drift from it.
--
--   2. `Open77.state` -- USED, but only as the hot-reload bridge, and
--      COOPERATIVELY. It is host-owned and survives a Lua reload, which is
--      precisely the failure that matters while a map is being authored: the
--      other half of this branch is editing `server/arena.lua` and
--      `server/bots.lua` in this same resource, and every one of those writes
--      reloads this VM. Without this bridge an afternoon of walking would
--      evaporate on somebody else's save.
--
--      The catch, and it is the reason for `mergeIntoBag` below: the bag is
--      ONE 64 KiB JSON string PER RESOURCE, and `server/ranked.lua` already
--      writes it -- its own header calls itself "its only user". A second
--      writer that built its payload from scratch would silently drop the
--      career rounds recorded but not yet committed. So both sides now
--      read-modify-write and preserve each other's top-level keys. Neither
--      owns the bag any more; that is recorded in ranked.lua too.
--
--      It is NOT durable: a stop or a server restart drops it, by design.
--
--   3. `Open77.database` -- CHOSEN for durability, because it is the only
--      durable store server Lua has. `LuaResourceRuntime.Sandbox` nils `io`,
--      `os`, `package`, `require`, `load`, `dofile` and `loadfile`: a resource
--      cannot open a file at all. `server/ranked.lua` proved this exact path
--      in Phase 8 and this follows it -- same permission (`database.access`,
--      already declared), same serialised single-coroutine worker, same
--      tri-state probe, same rule that a missing bridge is a SUPPORTED state
--      rather than a failure.
--
-- So: `activeMap` in tunables.json (WHICH map), the geometry in MySQL (across
-- a restart) and in the carried-state bag (across a reload), and never a byte
-- inside `resources/`.
--
-- WHEN THE BRIDGE IS OFF -- which is how `server.deathmatch-local.jsonc` ships,
-- deliberately -- the store degrades to memory plus the reload bridge, every
-- readout SAYS SO in capitals, and `/dm.map export` is the escape hatch: it
-- prints the active map as pasteable Lua so a finished map can be promoted
-- into `shared/kabuki.lua` and become a built-in under source control. A
-- volatile store that looked durable would be worse than no store.
--
-- ===========================================================================
-- HOW "IMMEDIATELY" IS ACHIEVED, AND WHY IT INHERITS THE HONESTY RULES
-- ===========================================================================
--
-- `apply` writes the active map's geometry straight into the tables the whole
-- resource already reads -- `DeathmatchKabuki.volumes`, `.spawns`, `.teams`,
-- `.stations`, `.formats[*].volumes` and `DeathmatchConfig.zones[*].volumes` --
-- then rebuilds `Deathmatch.bounds` and re-pushes the boundary to every client.
-- Nothing downstream is changed, and nothing downstream had to be:
--
--   * `spawnFor` in server/main.lua re-reads `DeathmatchKabuki.spawns.ffa` on
--     every placement, so a mark captured now is a candidate for the next
--     spawn;
--   * `server/arena.lua` reads `Kabuki.teams[format]` when a match forms;
--   * `server/bounds.lua` judges with `Kabuki.locateIn` over `Bounds.volumes()`.
--
-- That is also what makes the honesty guarantees free rather than
-- re-implemented. There is still exactly ONE containment test in the resource,
-- so a runtime map is judged by the same six comparisons as a shipped one:
--
--   * a zone naming a volume with no box still returns `not_surveyed` /
--     `outside_partial`, which `Bounds.evaluate` treats as CANNOT TELL, so
--     containment is SUSPENDED rather than silently empty -- an empty zone
--     contains nothing, and a bounds check that contains nothing places every
--     player on every tick;
--   * a format whose team cluster is nil still refuses to start, because
--     arena.lua tests `Kabuki.point(mark.position)` on every mark;
--   * `Kabuki.surveyed` is RECOMPUTED on every apply from the volumes actually
--     named by the map's zones, so it is a measured claim rather than a flag
--     somebody remembered to set.
--
-- `/dm.map check` reports all of it in one screen, including the spawn sweep
-- `server/bounds.lua` runs at startup -- a mark outside its own zone starts a
-- fight that warns the player at two seconds and places them at five.
--
-- ===========================================================================
-- WHAT HAPPENS TO shared/kabuki.lua
-- ===========================================================================
--
-- It is untouched as data and becomes the BUILT-IN DEFAULT. This file
-- snapshots it at load, before anything can mutate it, under the name
-- `kabuki`; that snapshot is never written to, never deleted, and
-- `/dm.map select kabuki` restores the shipped map at any time. An empty
-- store therefore plays exactly what the resource has always played.
--
-- ===========================================================================
-- PLAN SECTION 12, DECISION 5 -- RE-DECIDED, NOT DRIFTED
-- ===========================================================================
--
-- Decision 5 reads "One map, four zones. Kabuki serves every format; a second
-- map is out of scope." The owner asked for several named maps manageable at
-- runtime, which touches it, so it is re-decided explicitly rather than
-- quietly widened -- see decision 21 in docs/gamemode-pvp-arena-plan.md.
--
-- The intent of decision 5 is preserved exactly: THE MODE STILL RUNS ONE MAP
-- AT A TIME, selected per server by the `activeMap` tunable, and the four
-- zones are still carved out of that one map. What changed is only that the
-- one map is now DATA the editor can swap rather than a file the surveyor
-- rewrites. Nothing in the mode ever sees two maps at once.

Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig
local Kabuki = DeathmatchKabuki

DM.maps = DM.maps or {}
local Maps = DM.maps


-- ------------------------------------------------------------------ config --

local DEFAULTS = {
    tablePrefix         = "open77_dm_",
    minimumSeparation   = 3.0,   -- metres between two marks in one set
    minimumFootprint    = 1.5,   -- metres, smallest sane box edge
    floorPadMetres      = 0.5,   -- box floor below the ground sample
    defaultHeightMetres = 5.0,   -- box ceiling above the ground sample
    maxMaps             = 32,
    maxFfaMarks         = 64,
    carryBudgetBytes    = 20 * 1024,
}

local function setting(key)
    local block = type(Config) == "table" and Config.mapstore or nil
    if type(block) == "table" and block[key] ~= nil then return block[key] end
    return DEFAULTS[key]
end

local function number(key)
    return tonumber(setting(key)) or DEFAULTS[key]
end

local function log(text)
    DM.log("mapstore: " .. tostring(text))
end


-- ----------------------------------------------------------------- strings --
--
-- Decision 16: every player-facing string is English and lives in the shared
-- table, not inline here. A missing key is reported as a missing key rather
-- than papered over with a second copy of the copy -- a local fallback table
-- would be exactly the duplication the decision forbids, and it would go stale.

local function T(key, ...)
    local block = type(Config) == "table" and type(Config.strings) == "table"
        and Config.strings.mapedit or nil
    local template = type(block) == "table" and block[key] or nil
    if type(template) ~= "string" then
        return ("[missing string: strings.mapedit.%s]"):format(tostring(key))
    end
    if select("#", ...) == 0 then return template end
    local ok, text = pcall(string.format, template, ...)
    return ok and text or template
end


-- ----------------------------------------------------------------- helpers --

local function finite(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function normalizeHeading(value)
    local heading = finite(value)
    if heading == nil then return nil end
    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    return heading
end

-- Ids reach SQL, JSON and generated Lua source (the export). Whitelisted at
-- the door so none of the three has to defend itself.
local function cleanName(value, maximum)
    local name = tostring(value or ""):lower()
    if name == "" or #name > (maximum or 32) then return nil end
    if name:match("^[a-z0-9][a-z0-9_%-]*$") == nil then return nil end
    return name
end

local function cleanVolumeId(value)
    return cleanName(value, 24)
end

local function cleanLabel(value)
    local label = tostring(value or ""):gsub("%c", " "):gsub("%s+", " ")
    label = label:gsub("^%s+", ""):gsub("%s+$", "")
    if #label == 0 then return nil end
    if #label > 64 then label = label:sub(1, 64) end
    return label
end

local function copyPoint(value)
    local point = Kabuki.point(value)
    if point == nil then return nil end
    return { x = point.x, y = point.y, z = point.z }
end

local function copyMark(value)
    if type(value) ~= "table" then return nil end
    local position = copyPoint(value.position)
    if position == nil then return nil end
    return {
        position = position,
        heading = normalizeHeading(value.heading) or 0.0,
        headingKnown = value.headingKnown == true,
    }
end

local function distanceBetween(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end


-- --------------------------------------------------------------- the shape --

local TEAM_FORMATS = { "1v1", "2v2", "3v3" }
local ALL_FORMATS = { "ffa", "1v1", "2v2", "3v3" }
local SIDES = { "a", "b" }
local STATION_IDS = { "enter", "queue" }

-- The capture sets, and the ONE place their shape is declared. `resolve`
-- returns the live list inside a given map and creates nothing: a set that
-- does not exist on a map is an absence, and the caller decides what it means.
local SETS = {
    {
        key = "ffa", label = "FFA spawn marks", kind = "list",
        path = "DeathmatchKabuki.spawns.ffa",
        resolve = function(map) return map.spawns.ffa end,
    },
}
for _, format in ipairs(TEAM_FORMATS) do
    for _, side in ipairs(SIDES) do
        SETS[#SETS + 1] = {
            key = format .. "_" .. side,
            label = ("%s side %s"):format(format, side:upper()),
            kind = "list", format = format, side = side,
            path = ("DeathmatchKabuki.teams[%q].%s"):format(format, side),
            resolve = function(map)
                local teams = map.teams[format]
                return teams and teams[side] or nil
            end,
        }
    end
end
SETS[#SETS + 1] = {
    key = "station", label = "Lobby stations", kind = "named", names = STATION_IDS,
    path = "DeathmatchKabuki.stations",
    resolve = function(map) return map.stations end,
}

local function setKeyList()
    local keys = {}
    for index, entry in ipairs(SETS) do keys[index] = entry.key end
    return table.concat(keys, ", ")
end

-- `3v3.a` is what a person types; `3v3_a` is what the schema calls it. Both
-- work, and so do `stations` and `3v3a`: refusing a plausible spelling is a
-- worse outcome than accepting two.
local function findSet(key)
    local wanted = tostring(key or ""):lower():gsub("[%.%-%s]", "_")
    if wanted == "stations" then wanted = "station" end
    for _, entry in ipairs(SETS) do
        if entry.key == wanted or entry.key:gsub("_", "") == wanted then return entry end
    end
    return nil
end

-- How many marks a set is allowed to hold. A team side is EXACTLY `perSide`,
-- read from the format rules rather than hardcoded, so retuning a format in
-- config retunes the editor with it. Returns `required, ceiling`.
local function setCapacity(entry)
    if entry.kind == "named" then return #entry.names, #entry.names end
    if entry.format ~= nil then
        local definition = Kabuki.formats[entry.format]
        local perSide = definition and tonumber(definition.perSide) or nil
        if perSide == nil then perSide = tonumber(entry.format:match("^(%d+)v")) or 1 end
        return perSide, perSide
    end
    return nil, math.floor(number("maxFfaMarks"))
end


-- ------------------------------------------------------------- map records --

local function blankMap(name, label)
    return {
        name = name,
        label = label or name,
        builtin = false,
        volumes = {},
        spawns = { ffa = {} },
        teams = {
            ["1v1"] = { a = {}, b = {} },
            ["2v2"] = { a = {}, b = {} },
            ["3v3"] = { a = {}, b = {} },
        },
        stations = {
            { id = "enter", position = nil, heading = 0.0 },
            { id = "queue", position = nil, heading = 0.0 },
        },
        zones = { ffa = {}, ["1v1"] = {}, ["2v2"] = {}, ["3v3"] = {} },
        updatedMs = 0,
    }
end

-- Rebuild a map from anything -- a database row, the carried bag, the shipped
-- tables -- WITHOUT TRUSTING IT. Every coordinate goes through `Kabuki.point`,
-- every id through the name whitelist, every list through a length budget.
-- This is the only door into the store, so nothing downstream has to defend
-- itself: a half-written mark is dropped here, not judged at 60 Hz by the wall.
local function normalizeMap(raw, name, builtin)
    local map = blankMap(name, nil)
    map.builtin = builtin == true
    if type(raw) ~= "table" then return map end

    map.label = cleanLabel(raw.label) or name
    map.updatedMs = math.floor(tonumber(raw.updatedMs) or 0)

    local declared = {}
    for _, volume in ipairs(type(raw.volumes) == "table" and raw.volumes or {}) do
        local id = type(volume) == "table" and cleanVolumeId(volume.id) or nil
        if id ~= nil and not declared[id] and #map.volumes < 32 then
            declared[id] = true
            -- Half a box is not a smaller box: both corners, or neither.
            local min, max = copyPoint(volume.min), copyPoint(volume.max)
            if min == nil or max == nil then min, max = nil, nil end
            map.volumes[#map.volumes + 1] = { id = id, min = min, max = max }
        end
    end

    local rawSpawns = type(raw.spawns) == "table" and raw.spawns or {}
    local ceiling = math.floor(number("maxFfaMarks"))
    for _, mark in ipairs(type(rawSpawns.ffa) == "table" and rawSpawns.ffa or {}) do
        local copy = copyMark(mark)
        if copy ~= nil and #map.spawns.ffa < ceiling then
            map.spawns.ffa[#map.spawns.ffa + 1] = copy
        end
    end

    local rawTeams = type(raw.teams) == "table" and raw.teams or {}
    for _, format in ipairs(TEAM_FORMATS) do
        local source = type(rawTeams[format]) == "table" and rawTeams[format] or {}
        for _, side in ipairs(SIDES) do
            local into = map.teams[format][side]
            for _, mark in ipairs(type(source[side]) == "table" and source[side] or {}) do
                local copy = copyMark(mark)
                if copy ~= nil and #into < 8 then into[#into + 1] = copy end
            end
        end
    end

    -- Stations are NAMED and their order is the schema's, never the payload's:
    -- `enter` first, `queue` second, always, because client/station.lua and
    -- bounds.lua both index them positionally.
    local rawStations = type(raw.stations) == "table" and raw.stations or {}
    for index, id in ipairs(STATION_IDS) do
        for _, entry in ipairs(rawStations) do
            if type(entry) == "table" and tostring(entry.id) == id then
                local copy = copyMark(entry)
                if copy ~= nil then
                    map.stations[index] =
                        { id = id, position = copy.position, heading = copy.heading }
                end
                break
            end
        end
    end

    local rawZones = type(raw.zones) == "table" and raw.zones or {}
    for _, format in ipairs(ALL_FORMATS) do
        local list, taken = {}, {}
        for _, id in ipairs(type(rawZones[format]) == "table" and rawZones[format] or {}) do
            local clean = cleanVolumeId(id)
            -- A zone may only name a volume this map declares. A dangling name
            -- would suspend containment forever with no way to see why.
            if clean ~= nil and declared[clean] and not taken[clean] then
                taken[clean] = true
                list[#list + 1] = clean
            end
        end
        map.zones[format] = list
    end

    return map
end

-- A JSON-safe, self-contained copy. Used for the database payload, the carried
-- bag and `copy`, so all three are the same operation and cannot drift.
local function serialize(map)
    local out = {
        label = map.label, updatedMs = map.updatedMs,
        volumes = {}, spawns = { ffa = {} }, teams = {}, stations = {}, zones = {},
    }
    for index, volume in ipairs(map.volumes) do
        out.volumes[index] = { id = volume.id, min = copyPoint(volume.min),
                               max = copyPoint(volume.max) }
    end
    for index, mark in ipairs(map.spawns.ffa) do
        out.spawns.ffa[index] = { position = copyPoint(mark.position),
                                  heading = mark.heading,
                                  headingKnown = mark.headingKnown }
    end
    for _, format in ipairs(TEAM_FORMATS) do
        out.teams[format] = { a = {}, b = {} }
        for _, side in ipairs(SIDES) do
            for index, mark in ipairs(map.teams[format][side]) do
                out.teams[format][side][index] = {
                    position = copyPoint(mark.position), heading = mark.heading,
                    headingKnown = mark.headingKnown,
                }
            end
        end
    end
    for index, mark in ipairs(map.stations) do
        out.stations[index] = { id = mark.id, position = copyPoint(mark.position),
                                heading = mark.heading }
    end
    for _, format in ipairs(ALL_FORMATS) do
        local list = {}
        for index, id in ipairs(map.zones[format] or {}) do list[index] = id end
        out.zones[format] = list
    end
    return out
end

local function cloneMap(map, name, label)
    local copy = normalizeMap(serialize(map), name, false)
    copy.label = label or map.label
    return copy
end


-- ---------------------------------------------------------------- registry --

-- name -> map. The built-in is in here like any other map: that is what makes
-- "always restorable" true without a special case at every read.
local store = {}
local activeName = "kabuki"

local function mapNames()
    local names = {}
    for name in pairs(store) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function nameList()
    return table.concat(mapNames(), ", ")
end

local function active()
    return store[activeName or ""] or store.kabuki
end

Maps.active = active
Maps.names = mapNames
function Maps.get(name) return store[tostring(name or "")] end


-- ------------------------------------------------------------ the built-in --
--
-- Snapshotted from the LIVE tables, at load, before anything in this file can
-- write to them. `server/instances.lua` is the only server script that has run
-- at this point and it touches no geometry, so what is captured is literally
-- what `shared/kabuki.lua` and `DeathmatchConfig.zones` shipped.
--
-- Zones come from `Config.zones` rather than from `Kabuki.formats`, because
-- `server/bounds.lua` treats `Config.zones` as authoritative and warns on any
-- divergence. Snapshotting the ENFORCED list is what keeps the built-in map
-- identical to what the mode was playing a millisecond ago.
local function captureBuiltin()
    local raw = {
        label = (Config.zones and Config.zones.ffa and Config.zones.ffa.label)
            or (Config.strings and Config.strings.title) or "Kabuki",
        volumes = Kabuki.volumes,
        spawns = Kabuki.spawns,
        teams = Kabuki.teams,
        stations = Kabuki.stations,
        zones = {},
    }
    for _, format in ipairs(ALL_FORMATS) do
        local zone = Config.zones and Config.zones[format] or nil
        local list = zone and zone.volumes or Kabuki.zone(format)
        local copy = {}
        for index, id in ipairs(list or {}) do copy[index] = id end
        raw.zones[format] = copy
    end
    return normalizeMap(raw, "kabuki", true)
end

store.kabuki = captureBuiltin()


-- ------------------------------------------------------------------- apply --

-- Every volume named by any of this map's zones, and whether it has a box.
-- This is the readiness question the whole mode turns on: a zone naming a
-- boxless volume has containment SUSPENDED, which is honest but unplayable.
local function zoneReadiness(map)
    local named, ready, missing, total = {}, 0, {}, 0
    for _, format in ipairs(ALL_FORMATS) do
        for _, id in ipairs(map.zones[format] or {}) do
            if not named[id] then
                named[id] = true
                total = total + 1
                local volume
                for _, candidate in ipairs(map.volumes) do
                    if candidate.id == id then volume = candidate break end
                end
                if Kabuki.isSurveyed(volume) then
                    ready = ready + 1
                else
                    missing[#missing + 1] = id
                end
            end
        end
    end
    table.sort(missing)
    return ready, total, missing
end

Maps.zoneReadiness = zoneReadiness

-- Push the two lobby station marks to a client (or to everybody with -1).
--
-- The client holds its OWN copy of `shared/kabuki.lua`, so a station captured
-- on the server is invisible to `client/station.lua` until it is told. The
-- rings are the only way into the mode that is not a command, so a station the
-- editor moved and the client never heard about is the mode's front door
-- pointing at the wrong place.
local function pushStations(target)
    local map = active()
    if map == nil then return end
    local payload = {}
    for index, mark in ipairs(map.stations) do
        payload[index] = { id = mark.id, position = copyPoint(mark.position),
                           heading = mark.heading or 0.0 }
    end
    TriggerClientEvent("deathmatch:mapStations", target or -1, payload)
end

Maps.pushStations = pushStations

RegisterNetEvent("deathmatch:requestStations", function()
    local playerId = DM.playerId(source)
    if playerId == nil then return end
    pushStations(playerId)
end)

--- Make `map` the geometry the whole resource reads, RIGHT NOW.
---
--- This is the entire "no reload" claim, and it is deliberately a small
--- function: it writes the tables every consumer already reads, and changes no
--- consumer. `spawnFor` re-reads `spawns.ffa` on every placement, arena.lua
--- re-reads `teams[format]` when a match forms, bounds.lua judges over
--- `Bounds.volumes()` -- so the only remaining work is to rebuild that list
--- and re-push the client's copy of the boundary.
local function apply(map)
    if map == nil then return false, "no_map" end

    Kabuki.volumes = {}
    for index, volume in ipairs(map.volumes) do
        Kabuki.volumes[index] = { id = volume.id, min = copyPoint(volume.min),
                                  max = copyPoint(volume.max) }
    end

    Kabuki.spawns = { ffa = {} }
    for index, mark in ipairs(map.spawns.ffa) do
        Kabuki.spawns.ffa[index] =
            { position = copyPoint(mark.position), heading = mark.heading or 0.0 }
    end

    -- Every format key is present even when its clusters are empty.
    -- `Kabuki.sets` resolves `Kabuki.teams[<format>].a`, and a missing format
    -- key would raise inside `Kabuki.progress()` -- an editor that can crash
    -- the surveyor's own readout is worse than one that cannot store a map.
    Kabuki.teams = {}
    for _, format in ipairs(TEAM_FORMATS) do
        Kabuki.teams[format] = { a = {}, b = {} }
        for _, side in ipairs(SIDES) do
            for index, mark in ipairs(map.teams[format][side]) do
                Kabuki.teams[format][side][index] =
                    { position = copyPoint(mark.position), heading = mark.heading or 0.0 }
            end
        end
    end

    Kabuki.stations = {}
    for index, mark in ipairs(map.stations) do
        Kabuki.stations[index] = { id = mark.id, position = copyPoint(mark.position),
                                   heading = mark.heading or 0.0 }
    end

    -- The zone rule reaches TWO places and both must move together. bounds.lua
    -- resolves `Config.zones` and warns at startup when `Kabuki.formats`
    -- disagrees; writing only one of them would make the editor produce exactly
    -- the divergence that warning exists to catch.
    for _, format in ipairs(ALL_FORMATS) do
        local list = {}
        for index, id in ipairs(map.zones[format] or {}) do list[index] = id end
        if Kabuki.formats[format] ~= nil then Kabuki.formats[format].volumes = list end
        Config.zones[format] = Config.zones[format] or { label = format }
        Config.zones[format].volumes = list
        Config.zones[format].label = map.label
    end

    -- MEASURED, never asserted. `surveyed` is a claim about whether the map in
    -- use can be judged at all, so it is recomputed from the boxes that exist
    -- rather than carried in the payload where an author could set it by hand.
    local ready, total = zoneReadiness(map)
    Kabuki.surveyed = total > 0 and ready == total

    activeName = map.name

    if DM.bounds ~= nil and type(DM.bounds.rebuild) == "function" then
        DM.bounds.rebuild()
    end
    -- The client's wall is a COPY of the zone's boxes, sent on transition only.
    -- Without a forced re-push a player already inside an instance keeps
    -- clamping against the geometry the map had when they entered it.
    if type(DM.resyncBounds) == "function" then pcall(DM.resyncBounds) end
    -- Guarded because `apply` also runs at LOAD, to restore the selected map
    -- before bounds.lua reads the geometry, and a broadcast from a resource
    -- that is still coming up has no audience worth raising over. A station
    -- push that does not land is corrected by the client's own request at
    -- load; a raise here would take the resource down.
    pcall(pushStations, -1)
    return true
end

Maps.apply = apply

-- Re-apply the active map. Every mutating verb ends here, which is why "the
-- next spawn uses it" is a property of the design rather than of remembering.
local function touch(map)
    map.updatedMs = DM.nowMs()
    if map.name == activeName then apply(map) end
end


-- ======================================================== the active name --
--
-- Held in the ONE tunable this file uses, because "which map does this server
-- play" is a per-server SETTING, not runtime state: it must survive a reload,
-- a stop and a restart, and it must do so on a server with no database, which
-- is how the dev configuration ships. `tunables.json` sits beside
-- `server.jsonc`, outside the watched `resources/` tree, so writing it moves
-- nothing the 1 Hz resource watcher can see.
--
-- Read through `DM.tune`, which is a CALL behind a metatable -- never cached
-- at file scope, or every later change from Warden would do nothing while the
-- panel went on reporting the new value.

local function declaredActiveName()
    local ok, value = pcall(function() return DM.tune.activeMap end)
    if not ok then return nil end
    return cleanName(value, 32)
end

local function persistActiveName(name)
    if type(Open77.tunables) ~= "table"
        or type(Open77.tunables.set) ~= "function" then return false, "unavailable" end
    local ok, result, message = pcall(Open77.tunables.set, "activeMap", name)
    if not ok then return false, tostring(result) end
    if result == false then return false, tostring(message) end
    return true
end


-- ================================================ the hot-reload bridge --
--
-- `Open77.state` is host-owned and survives a Lua reload -- and this resource
-- reloads constantly, because it is edited while it runs. It is NOT durable: a
-- stop or a restart drops it, which is what the database below is for.
--
-- COOPERATIVE, and that is the whole subtlety. The bag is one JSON string per
-- resource and `server/ranked.lua` also writes it, so both sides read the
-- current bag and preserve the other's top-level keys before saving. A writer
-- that built its payload from scratch would silently drop the other's -- for
-- ranked that means career rounds recorded and not yet committed.

local CARRY_KEY = "maps"
local CARRY_PROTOCOL = 1

local function loadBag()
    if type(Open77.state) ~= "table" or type(Open77.state.load) ~= "function" then
        return nil
    end
    local ok, bag = pcall(Open77.state.load)
    if not ok or type(bag) ~= "table" then return nil end
    return bag
end

--- Read-modify-write the shared bag under our own key, leaving every other key
--- exactly as it was found.
local function mergeIntoBag(payload)
    if type(Open77.state) ~= "table" or type(Open77.state.save) ~= "function" then
        return false
    end
    local bag = loadBag() or {}
    bag[CARRY_KEY] = payload
    local ok, encoded = pcall(json.encode, bag)
    if not ok then return false end
    -- The host budget is 64 KiB for the WHOLE bag and we are not its only
    -- user, so this file keeps to its own share and trims itself rather than
    -- starving the other writer or raising from the C function.
    if #encoded > 60 * 1024 then return false end
    local saved = pcall(Open77.state.save, bag)
    return saved == true
end

local function carry()
    local budget = math.floor(number("carryBudgetBytes"))

    -- Everything, then the active map alone, then nothing. The active map is
    -- the one somebody is standing in the middle of authoring; the others are
    -- already in the database if there is one, and re-walkable if there is not.
    local attempts = { "all", "active" }
    for _, scope in ipairs(attempts) do
        local maps = {}
        for name, map in pairs(store) do
            if not map.builtin and (scope == "all" or name == activeName) then
                maps[name] = serialize(map)
            end
        end
        local payload = { protocol = CARRY_PROTOCOL, active = activeName, maps = maps }
        local ok, encoded = pcall(json.encode, payload)
        if ok and #encoded <= budget then
            if mergeIntoBag(payload) then return true end
        end
    end
    log("carried state would not fit its budget -- the map draft is NOT reload-safe right now")
    return false
end

local function adoptCarried()
    local bag = loadBag()
    local payload = bag ~= nil and bag[CARRY_KEY] or nil
    if type(payload) ~= "table" then return 0 end
    if payload.protocol ~= CARRY_PROTOCOL then
        log("carried map state from another protocol version discarded")
        return 0
    end

    local adopted = 0
    for name, raw in pairs(type(payload.maps) == "table" and payload.maps or {}) do
        local clean = cleanName(name, 32)
        -- REVALIDATED, NOT TRUSTED: this is JSON written by a previous
        -- generation of this file's own code, and `kabuki` is reserved.
        if clean ~= nil and clean ~= "kabuki" then
            store[clean] = normalizeMap(raw, clean, false)
            adopted = adopted + 1
        end
    end
    return adopted
end


-- ==================================================== the durable store --
--
-- Exactly `server/ranked.lua`'s pattern, for exactly its reasons: the sandbox
-- nils `io` and `os`, so the database bridge is the only durable store server
-- Lua has at all. A missing bridge is a SUPPORTED state, not a failure -- the
-- readouts just have to say so, in capitals, every time.

local function tableName()
    local prefix = tostring(setting("tablePrefix") or "open77_dm_")
    -- The prefix reaches SQL as an IDENTIFIER, and identifiers cannot be bound
    -- as parameters, so operator-supplied config is whitelisted rather than
    -- trusted.
    if prefix:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then prefix = "open77_dm_" end
    return prefix .. "maps"
end

--   nil   = not probed yet
--   true  = schema is up, maps persist
--   false = degraded to memory for this run
local dbReady = nil
local dbReason = "not probed"

local function storageLine()
    if dbReady == true then return T("storeDatabase", tableName()) end
    if dbReady == false then return T("storeVolatile", dbReason) end
    return T("storeUnprobed")
end

Maps.storageLine = storageLine

local function schema()
    return ([[
        CREATE TABLE IF NOT EXISTS %s (
            name        VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            label       VARCHAR(64) NOT NULL,
            payload     MEDIUMTEXT NOT NULL,
            updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (name)
        ) ENGINE=InnoDB
    ]]):format(tableName())
end

--- Probe the bridge by putting the schema up. Coroutine only -- `.await` yields.
local function ensureSchema()
    if dbReady ~= nil then return dbReady end
    local ok, reason = pcall(function() MySQL.update.await(schema()) end)
    if not ok then
        dbReady = false
        dbReason = tostring(reason)
        log("DATABASE UNAVAILABLE (" .. dbReason ..
            ") -- maps are VOLATILE this run; use /dm.map export before a restart")
        return false
    end
    dbReady = true
    dbReason = "ready"
    log("database ready -- maps persist in " .. tableName())
    return true
end

-- ONE coroutine owns every database call, for the reason ranked.lua spells
-- out: `.await` yields, so two independent threads can interleave mid-write
-- and a load can overwrite a save that has not landed. Serialised in one FIFO,
-- every order is correct.
local jobs = {}
local workerRunning = false
local drain

local function enqueue(job)
    jobs[#jobs + 1] = job
    if workerRunning then return end
    workerRunning = true
    CreateThread(function()
        local ok, err = pcall(drain)
        workerRunning = false
        if not ok then log("worker raised: " .. tostring(err)) end
    end)
end

local function writeMap(map)
    if not ensureSchema() then return end
    local ok, encoded = pcall(json.encode, serialize(map))
    if not ok then return log("could not encode map '" .. map.name .. "'") end
    local written, reason = pcall(function()
        MySQL.update.await(([[
            INSERT INTO %s (name, label, payload) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE label = VALUES(label), payload = VALUES(payload)
        ]]):format(tableName()), { map.name, map.label, encoded })
    end)
    if not written then log(("save of '%s' failed: %s"):format(map.name, tostring(reason))) end
end

local function deleteMap(name)
    if not ensureSchema() then return end
    pcall(function()
        MySQL.update.await(("DELETE FROM %s WHERE name = ?"):format(tableName()), { name })
    end)
end

local function readAll()
    if not ensureSchema() then return end
    local ok, rows = pcall(function()
        return MySQL.query.await(("SELECT name, label, payload FROM %s"):format(tableName()))
    end)
    if not ok then return log("map load failed: " .. tostring(rows)) end

    local loaded = 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local name = cleanName(row.name, 32)
        if name ~= nil and name ~= "kabuki" then
            local decoded, payload = pcall(json.decode, tostring(row.payload or ""))
            if decoded and type(payload) == "table" then
                payload.label = payload.label or row.label
                local incoming = normalizeMap(payload, name, false)
                -- The carried bag is the most RECENT memory (this VM's
                -- predecessor); the database is the most DURABLE. When both
                -- have a map, the newer edit wins, so a reload immediately
                -- followed by a database read cannot resurrect a mark that was
                -- just deleted.
                local existing = store[name]
                if existing == nil or incoming.updatedMs > existing.updatedMs then
                    store[name] = incoming
                end
                loaded = loaded + 1
            end
        end
    end
    if loaded > 0 then log(("loaded %d map(s) from %s"):format(loaded, tableName())) end

    -- The selection may name a map that only the database had.
    local wanted = declaredActiveName()
    if wanted ~= nil and store[wanted] ~= nil and wanted ~= activeName then
        apply(store[wanted])
        log("active map is now '" .. wanted .. "' (restored from the store)")
    end
end

drain = function()
    while #jobs > 0 do
        local job = table.remove(jobs, 1)
        local ok, err = pcall(job)
        if not ok then log("job raised: " .. tostring(err)) end
    end
end

--- Persist everything a change could have touched: the carried bag always
--- (cheap, synchronous, and the only thing that survives a reload), and the
--- database when there is one.
local function persist(map, removedName)
    carry()
    if removedName ~= nil then
        enqueue(function() deleteMap(removedName) end)
    end
    if map ~= nil and not map.builtin then
        enqueue(function() writeMap(map) end)
    end
end


--- Commit a mutation somebody else made to a map: re-apply it if it is the
--- active one, and write it to both stores.
---
--- Published for `server/survey.lua`'s `commit` verb, which pushes a walked
--- draft into the live map in one step. It is the ONLY door into persistence
--- from outside this file, so there is still exactly one place that decides
--- what "saved" means.
function Maps.save(map)
    if type(map) ~= "table" or map.builtin then return false end
    touch(map)
    persist(map)
    return true
end

--- Find or declare a volume on a map. Used by `Maps.save`'s callers, which
--- have boxes for ids the map may not carry yet.
function Maps.volume(map, id)
    local clean = cleanVolumeId(id)
    if clean == nil or type(map) ~= "table" then return nil end
    for _, volume in ipairs(map.volumes) do
        if volume.id == clean then return volume end
    end
    if #map.volumes >= 32 then return nil end
    local volume = { id = clean, min = nil, max = nil }
    map.volumes[#map.volumes + 1] = volume
    return volume
end

--- The list a capture-set key writes into, on a given map, or nil.
function Maps.list(map, key)
    local entry = findSet(key)
    if entry == nil or type(map) ~= "table" then return nil end
    return entry.resolve(map), entry
end

--- Give every format a zone if the map has none, so a map assembled entirely
--- through `Maps.save` is playable rather than silently suspended. Returns the
--- ids that were assigned, or nil when the map already had a zone.
function Maps.autoZone(map)
    local _, total = zoneReadiness(map)
    if total > 0 then return nil end
    local ids = {}
    for _, volume in ipairs(map.volumes) do
        if Kabuki.isSurveyed(volume) then ids[#ids + 1] = volume.id end
    end
    if #ids == 0 then return nil end
    for _, format in ipairs(ALL_FORMATS) do
        local copy = {}
        for index, id in ipairs(ids) do copy[index] = id end
        map.zones[format] = copy
    end
    return ids
end


-- ==================================================== the editing session --
--
-- Two things an author needs that a plain command cannot supply, and both are
-- exactly what `/dm.survey start` already turns on:
--
--   * A HEADING. The server cannot see which way anybody is facing --
--     `Open77.players.position` returns (x, y, z, bucket) and no rotation, and
--     the life state's yaw is only written at a kill or a respawn, so it is
--     the direction you were PLACED facing rather than the one you are looking.
--     While the session is open the author's own client reports its facing at
--     4 Hz, which is the only place that number exists.
--
--   * AN EXEMPTION FROM THE LEASH. Measured 2026-08-31: travelling to the map
--     to survey it succeeds, and the LOBBY leash then returns the surveyor a
--     few seconds later. Both halves were correct in isolation and they are
--     simply incompatible -- you cannot author a map you are being ejected
--     from.
--
-- Nothing in this table is a world object, so it may be iterated: a session
-- does not outlive anything, it simply disappears.

local sessions = {}

local function sessionMinutes()
    local block = type(Config) == "table" and Config.survey or nil
    return tonumber(block and block.sessionMinutes) or 30
end

local function surveyModule()
    local module = DM.survey
    return type(module) == "table" and module or nil
end

local function setReporting(playerId, enabled)
    local module = surveyModule()
    if module ~= nil and type(module.report) == "function" then
        pcall(module.report, playerId, enabled)
    end
end

local function setExempt(playerId, exempt)
    if DM.bounds ~= nil and type(DM.bounds.setExempt) == "function" then
        pcall(DM.bounds.setExempt, playerId, exempt, "mapedit")
    end
end

local function openSession(playerId)
    local session = sessions[playerId]
    if session == nil then
        session = { boxes = {} }
        sessions[playerId] = session
    end
    session.expiresAtMs = DM.nowMs() + sessionMinutes() * 60000
    setReporting(playerId, true)
    return session
end

local function closeSession(playerId)
    sessions[playerId] = nil
    setReporting(playerId, false)
    setExempt(playerId, false)
end

-- Lazily expired rather than swept by a tick: there is no way to list players,
-- so a sweep would cost a thread to find rows whose owner disconnected an hour
-- ago. Checking on use answers the same question for free.
local function sessionOf(playerId)
    local session = sessions[playerId]
    if session ~= nil and DM.nowMs() > session.expiresAtMs then
        closeSession(playerId)
        session = nil
    end
    return session
end

-- The last heading this author's client reported, if the reporter is on.
-- survey.lua owns the reporter -- one net event, one table -- because two
-- reporters on the same 4 Hz channel would be two answers to one question.
local function reportedHeading(playerId)
    local module = surveyModule()
    if module == nil or type(module.heading) ~= "function" then return nil end
    local ok, value = pcall(module.heading, playerId)
    if not ok then return nil end
    return normalizeHeading(value)
end

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = DM.playerId(playerIdStr)
    if playerId == nil then return end
    closeSession(playerId)
end)


-- ============================================================== commands --

local function reply(source, raw, ok, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

-- The ONE source of coordinates in this file, and it is the same rule
-- `server/survey.lua` and `race/server/courses.lua` state in their headers:
-- COORDINATES ARE NEVER ACCEPTED FROM A CLIENT PAYLOAD. A command carries a
-- set name, a volume id and at most a heading; never a place.
local function callerPosition(playerId)
    local position = Open77.players.position(playerId)
    if position == nil then return nil, "position_unknown" end
    local point = Kabuki.point(position)
    if point == nil then return nil, "position_unreadable" end
    return point
end

--- The active map, refusing the built-in.
---
--- The shipped map is the floor everything else stands on -- an empty store
--- plays it, `select kabuki` restores it, and `export` promotes a runtime map
--- into it. Letting the editor write to it would remove the one thing that is
--- always known-good.
local function editable(source, raw)
    local map = active()
    if map == nil then
        reply(source, raw, false, T("noActiveMap"))
        return nil
    end
    if map.builtin then
        reply(source, raw, false, T("builtinReadOnly", map.name, map.name))
        return nil
    end
    return map
end

local function volumeOf(map, id)
    for _, volume in ipairs(map.volumes) do
        if volume.id == id then return volume end
    end
    return nil
end

local function volumeIdList(map)
    local ids = {}
    for index, volume in ipairs(map.volumes) do ids[index] = volume.id end
    return #ids > 0 and table.concat(ids, ", ") or T("none")
end

local function markCount(map)
    local total = 0
    for _, entry in ipairs(SETS) do
        for _, mark in ipairs(entry.resolve(map) or {}) do
            if Kabuki.point(mark.position) ~= nil then total = total + 1 end
        end
    end
    return total
end

local function boxCount(map)
    local closed = 0
    for _, volume in ipairs(map.volumes) do
        if Kabuki.isSurveyed(volume) then closed = closed + 1 end
    end
    return closed
end


-- ------------------------------------------------------ map-level verbs --

local function cmdList(source, raw)
    reply(source, raw, true, T("listHeader", #mapNames(), storageLine()))
    for _, name in ipairs(mapNames()) do
        local map = store[name]
        reply(source, raw, true, T("listRow",
            name == activeName and ">" or " ", name,
            map.builtin and T("tagBuiltin") or "", map.label,
            boxCount(map), #map.volumes, markCount(map)))
    end
end

local function describe(source, raw, map)
    local ready, total, missing = zoneReadiness(map)
    reply(source, raw, true, T("showHeader", map.name, map.label,
        map.name == activeName and T("yes") or T("no"),
        map.builtin and T("yes") or T("no")))
    reply(source, raw, true, T("showVolumes", boxCount(map), #map.volumes,
        volumeIdList(map)))
    for _, format in ipairs(ALL_FORMATS) do
        local zone = map.zones[format] or {}
        reply(source, raw, true, T("showZone", format,
            #zone > 0 and table.concat(zone, ",") or T("none")))
    end
    for _, entry in ipairs(SETS) do
        local list = entry.resolve(map) or {}
        local captured = 0
        for _, mark in ipairs(list) do
            if Kabuki.point(mark.position) ~= nil then captured = captured + 1 end
        end
        local required, ceiling = setCapacity(entry)
        reply(source, raw, true, T("showSet", entry.key, entry.label, captured,
            required ~= nil and tostring(required) or ("<=" .. tostring(ceiling))))
    end
    reply(source, raw, true, T("showReadiness", ready, total,
        #missing > 0 and table.concat(missing, ",") or T("none")))
end

local function cmdShow(source, raw, args)
    local name = args[1] ~= nil and cleanName(args[1], 32) or activeName
    local map = name ~= nil and store[name] or nil
    if map == nil then return reply(source, raw, false, T("unknownMap",
        tostring(args[1] or ""), nameList())) end
    describe(source, raw, map)
end

local function selectMap(source, raw, map)
    apply(map)
    local ok, reason = persistActiveName(map.name)
    if not ok then
        -- Not fatal: the map IS applied and playable. It simply will not be
        -- re-selected after a restart, and saying so is the difference between
        -- a warning and a surprise next Monday.
        reply(source, raw, true, T("selectNotPersisted", tostring(reason)))
    end
    local ready, total, missing = zoneReadiness(map)
    reply(source, raw, true, T("selected", map.name, map.label,
        markCount(map), boxCount(map), #map.volumes))
    if total == 0 then
        reply(source, raw, true, T("selectedNoZones"))
    elseif ready < total then
        reply(source, raw, true, T("selectedSuspended", table.concat(missing, ",")))
    end
end

local function cmdSelect(source, raw, args)
    local name = cleanName(args[1], 32)
    local map = name ~= nil and store[name] or nil
    if map == nil then return reply(source, raw, false, T("unknownMap",
        tostring(args[1] or ""), nameList())) end
    selectMap(source, raw, map)
end

local function tail(args, from)
    local parts = {}
    for index = from, (args.n or #args) do
        if args[index] ~= nil then parts[#parts + 1] = tostring(args[index]) end
    end
    return table.concat(parts, " ")
end

local function cmdNew(source, raw, args)
    local name = cleanName(args[1], 32)
    if name == nil then return reply(source, raw, false, T("usageNew")) end
    if store[name] ~= nil then return reply(source, raw, false, T("mapExists", name, name)) end
    if #mapNames() >= math.floor(number("maxMaps")) then
        return reply(source, raw, false, T("tooManyMaps", math.floor(number("maxMaps"))))
    end

    local map = blankMap(name, cleanLabel(tail(args, 2)) or name)
    store[name] = map
    map.updatedMs = DM.nowMs()
    persist(map)
    reply(source, raw, true, T("created", name, map.label))
    selectMap(source, raw, map)
    reply(source, raw, true, T("createdNext"))
end

local function cmdCopy(source, raw, args)
    local sourceName = cleanName(args[1], 32)
    local newName = cleanName(args[2], 32)
    if sourceName == nil or newName == nil then
        return reply(source, raw, false, T("usageCopy", nameList()))
    end
    local origin = store[sourceName]
    if origin == nil then
        return reply(source, raw, false, T("unknownMap", tostring(args[1]), nameList()))
    end
    if store[newName] ~= nil then return reply(source, raw, false, T("mapExists", newName, newName)) end
    if #mapNames() >= math.floor(number("maxMaps")) then
        return reply(source, raw, false, T("tooManyMaps", math.floor(number("maxMaps"))))
    end

    local map = cloneMap(origin, newName, cleanLabel(tail(args, 3)))
    store[newName] = map
    map.updatedMs = DM.nowMs()
    persist(map)
    reply(source, raw, true, T("copied", sourceName, newName, markCount(map), boxCount(map)))
    selectMap(source, raw, map)
end

local function cmdRename(source, raw, args)
    local from = cleanName(args[1], 32)
    local to = cleanName(args[2], 32)
    if from == nil or to == nil then return reply(source, raw, false, T("usageRename")) end
    local map = store[from]
    if map == nil then
        return reply(source, raw, false, T("unknownMap", tostring(args[1]), nameList()))
    end
    if map.builtin then return reply(source, raw, false, T("builtinReadOnly", from, from)) end
    if store[to] ~= nil then return reply(source, raw, false, T("mapExists", to, to)) end

    store[from] = nil
    map.name = to
    store[to] = map
    if activeName == from then
        activeName = to
        persistActiveName(to)
    end
    map.updatedMs = DM.nowMs()
    persist(map, from)
    reply(source, raw, true, T("renamed", from, to))
end

local function cmdLabel(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local label = cleanLabel(tail(args, 1))
    if label == nil then return reply(source, raw, false, T("usageLabel")) end
    map.label = label
    touch(map)
    persist(map)
    reply(source, raw, true, T("labelled", map.name, label))
end

local function cmdDelete(source, raw, args)
    local name = cleanName(args[1], 32)
    local map = name ~= nil and store[name] or nil
    if map == nil then
        return reply(source, raw, false, T("unknownMap", tostring(args[1] or ""), nameList()))
    end
    if map.builtin then return reply(source, raw, false, T("builtinReadOnly", name, name)) end
    if name == activeName then return reply(source, raw, false, T("deleteActive", name)) end

    store[name] = nil
    persist(nil, name)
    carry()
    reply(source, raw, true, T("deleted", name))
end


-- --------------------------------------------------------- capture verbs --

--- Refuse a mark that would land on top of another in the same set.
---
--- Two marks a metre apart are one mark and a spawn blender. This compares
--- CAPTURED samples against each other; it never derives one from another,
--- which is the discipline Corpo Plaza paid for -- nearby XY does not imply
--- walkable ground.
local function tooClose(list, point, skipIndex)
    local minimum = number("minimumSeparation")
    for index, existing in ipairs(list) do
        local other = Kabuki.point(existing.position)
        if other ~= nil and index ~= skipIndex then
            local distance = distanceBetween(point, other)
            if distance < minimum then return index, distance, minimum end
        end
    end
    return nil
end

local function headingFor(source, argument)
    local given = normalizeHeading(argument)
    if given ~= nil then return given, true end
    local reported = reportedHeading(source)
    if reported ~= nil then return reported, true end
    return 0.0, false
end

local function cmdMark(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findSet(args[1])
    if entry == nil then
        return reply(source, raw, false, T("unknownSet", tostring(args[1] or ""), setKeyList()))
    end
    if entry.kind == "named" then return reply(source, raw, false, T("useStationVerb")) end

    local list = entry.resolve(map)
    local required, ceiling = setCapacity(entry)
    if #list >= ceiling then
        return reply(source, raw, false, T("setFull", entry.key, ceiling, entry.key))
    end

    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, T("noPosition", failure)) end

    local clashIndex, distance, minimum = tooClose(list, point)
    if clashIndex ~= nil then
        return reply(source, raw, false,
            T("tooClose", distance, clashIndex, entry.key, minimum))
    end

    openSession(source)
    local heading, known = headingFor(source, args[2])
    list[#list + 1] = { position = point, heading = heading, headingKnown = known }
    touch(map)
    persist(map)

    reply(source, raw, true, T("markCaptured", #list,
        required ~= nil and tostring(required) or ("<=" .. tostring(ceiling)),
        entry.key, point.x, point.y, point.z, heading))
    if not known then reply(source, raw, true, T("headingMissing")) end
    if required ~= nil and #list == required then
        reply(source, raw, true, T("setComplete", entry.key))
    end
end

local function cmdMarks(source, raw, args)
    local map = active()
    if map == nil then return reply(source, raw, false, T("noActiveMap")) end
    local only = args[1] ~= nil and findSet(args[1]) or nil
    if args[1] ~= nil and only == nil then
        return reply(source, raw, false, T("unknownSet", tostring(args[1]), setKeyList()))
    end

    for _, entry in ipairs(SETS) do
        if only == nil or only.key == entry.key then
            local list = entry.resolve(map) or {}
            local required, ceiling = setCapacity(entry)
            reply(source, raw, true, T("marksHeader", entry.key, entry.label, #list,
                required ~= nil and tostring(required) or ("<=" .. tostring(ceiling))))
            for index, mark in ipairs(list) do
                local point = Kabuki.point(mark.position)
                if point == nil then
                    reply(source, raw, true, T("markRowEmpty", index,
                        tostring(mark.id or index)))
                else
                    reply(source, raw, true, T("markRow", index,
                        entry.kind == "named" and tostring(mark.id or index) or tostring(index),
                        point.x, point.y, point.z, mark.heading or 0.0))
                end
            end
        end
    end
end

--- Resolve `<set> <index>` for `move` and `remove`. A named set is addressed
--- by its id (`station enter`) as well as by its number, because "enter" is
--- what the author calls it everywhere else.
local function resolveIndex(entry, list, token)
    local index = math.floor(tonumber(token) or 0)
    if index >= 1 and index <= #list then return index end
    if entry.kind == "named" then
        local wanted = tostring(token or ""):lower()
        for position, mark in ipairs(list) do
            if tostring(mark.id) == wanted then return position end
        end
    end
    return nil
end

local function cmdMove(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findSet(args[1])
    if entry == nil then
        return reply(source, raw, false, T("unknownSet", tostring(args[1] or ""), setKeyList()))
    end
    local list = entry.resolve(map)
    local index = resolveIndex(entry, list, args[2])
    if index == nil then
        return reply(source, raw, false, T("badIndex", tostring(args[2] or ""), entry.key, #list))
    end

    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, T("noPosition", failure)) end
    local clashIndex, distance, minimum = tooClose(list, point, index)
    if clashIndex ~= nil then
        return reply(source, raw, false, T("tooClose", distance, clashIndex, entry.key, minimum))
    end

    openSession(source)
    local heading, known = headingFor(source, args[3])
    local mark = list[index]
    mark.position = point
    mark.heading = heading
    mark.headingKnown = known
    touch(map)
    persist(map)
    reply(source, raw, true, T("markMoved", entry.key, index,
        point.x, point.y, point.z, heading))
    if not known then reply(source, raw, true, T("headingMissing")) end
end

local function cmdRemove(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findSet(args[1])
    if entry == nil then
        return reply(source, raw, false, T("unknownSet", tostring(args[1] or ""), setKeyList()))
    end
    local list = entry.resolve(map)
    local index = resolveIndex(entry, list, args[2])
    if index == nil then
        return reply(source, raw, false, T("badIndex", tostring(args[2] or ""), entry.key, #list))
    end

    if entry.kind == "named" then
        -- A named slot is never removed, only emptied: the pair IS the schema,
        -- and `client/station.lua` reads them positionally. An absent position
        -- means "not captured", which is the honest state the renderer already
        -- knows how to degrade to.
        list[index].position = nil
        list[index].heading = 0.0
    else
        table.remove(list, index)
    end
    touch(map)
    persist(map)
    reply(source, raw, true, T("markRemoved", entry.key, index, #list))
end

local function cmdStation(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local id = tostring(args[1] or ""):lower()
    if id ~= "enter" and id ~= "queue" then
        return reply(source, raw, false, T("usageStation"))
    end

    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, T("noPosition", failure)) end

    openSession(source)
    local heading = headingFor(source, args[2])
    for index, stationId in ipairs(STATION_IDS) do
        if stationId == id then
            map.stations[index] = { id = id, position = point, heading = heading }
        end
    end
    touch(map)
    persist(map)
    reply(source, raw, true, T("stationCaptured", id, point.x, point.y, point.z, heading))

    -- The dead band, checked the moment both marks exist and impossible to see
    -- by reading the numbers. `open77_worldui` activates at `radius + 0.5 m`,
    -- so two stations closer than the sum of their activations leave a gap
    -- where NEITHER prompt is live -- worse than an overlap, because an
    -- overlap is at least arbitrated.
    local first = Kabuki.point(map.stations[1] and map.stations[1].position)
    local second = Kabuki.point(map.stations[2] and map.stations[2].position)
    if first ~= nil and second ~= nil then
        local dx, dy = first.x - second.x, first.y - second.y
        local separation = math.sqrt(dx * dx + dy * dy)
        local required = tonumber(Config.stations and Config.stations.minSeparationMetres) or 6.0
        if separation < required then
            reply(source, raw, false, T("stationsTooClose", separation, required))
        else
            reply(source, raw, true, T("stationsSeparation", separation, required))
        end
    end
end


-- ---------------------------------------------------------------- volumes --

local function cmdVolume(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local verb = tostring(args[1] or ""):lower()
    local id = cleanVolumeId(args[2])
    if (verb ~= "add" and verb ~= "delete") or id == nil then
        return reply(source, raw, false, T("usageVolume", volumeIdList(map)))
    end

    if verb == "add" then
        if volumeOf(map, id) ~= nil then
            return reply(source, raw, false, T("volumeExists", id))
        end
        if #map.volumes >= 32 then return reply(source, raw, false, T("tooManyVolumes")) end
        map.volumes[#map.volumes + 1] = { id = id, min = nil, max = nil }
        touch(map)
        persist(map)
        return reply(source, raw, true, T("volumeAdded", id, id))
    end

    local removed = false
    for index, volume in ipairs(map.volumes) do
        if volume.id == id then table.remove(map.volumes, index) removed = true break end
    end
    if not removed then return reply(source, raw, false, T("unknownVolume", id, volumeIdList(map))) end
    -- A zone may never name a volume that does not exist: a dangling name
    -- suspends containment forever with nothing on screen to say why.
    for _, format in ipairs(ALL_FORMATS) do
        local kept = {}
        for _, name in ipairs(map.zones[format] or {}) do
            if name ~= id then kept[#kept + 1] = name end
        end
        map.zones[format] = kept
    end
    local session = sessionOf(source)
    if session ~= nil then session.boxes[id] = nil end
    touch(map)
    persist(map)
    reply(source, raw, true, T("volumeDeleted", id))
end

--- Two walked corners make a box. The GEOMETRY is `Kabuki.boxFromCorners` --
--- not reimplemented here, because two floor samples do not make a box on
--- their own and that file already carries the reason: both samples are taken
--- at the author's feet, so the span they describe is flat and contains
--- nobody. The vertical extent comes from the capture (`floorPad` below the
--- lower sample, `height` above the upper one), which is arithmetic on a
--- CEILING rather than on walkable ground -- the one place the survey
--- discipline permits it.
local function cmdBox(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local id = cleanVolumeId(args[1])
    if id == nil then return reply(source, raw, false, T("usageBox", volumeIdList(map))) end

    local height
    if args[2] ~= nil then
        height = finite(args[2])
        if height == nil or height <= 0.0 then
            reply(source, raw, false, T("badHeight", tostring(args[2])))
            height = nil
        end
    end

    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, T("noPosition", failure)) end

    local volume = volumeOf(map, id)
    if volume == nil then
        if #map.volumes >= 32 then return reply(source, raw, false, T("tooManyVolumes")) end
        volume = { id = id, min = nil, max = nil }
        map.volumes[#map.volumes + 1] = volume
        -- Persisted before the box exists, deliberately. The pending CORNER
        -- lives in the session and dies with the VM, but the declaration is
        -- part of the map: without this a reload between the two corners would
        -- lose the id as well as the corner, and `dm.map show` would disagree
        -- with the line just printed.
        touch(map)
        persist(map)
        reply(source, raw, true, T("volumeAdded", id, id))
    end

    local session = openSession(source)
    local pending = session.boxes[id]
    if pending == nil then
        session.boxes[id] = { first = point, height = height or number("defaultHeightMetres") }
        if Kabuki.isSurveyed(volume) then reply(source, raw, true, T("boxReopened", id)) end
        return reply(source, raw, true, T("boxFirst", id, point.x, point.y, point.z))
    end

    if height ~= nil then pending.height = height end
    local footprintX = math.abs(point.x - pending.first.x)
    local footprintY = math.abs(point.y - pending.first.y)
    local minimum = number("minimumFootprint")
    if footprintX < minimum or footprintY < minimum then
        return reply(source, raw, false,
            T("boxTooSmall", id, footprintX, footprintY, minimum))
    end

    local closed, reason = Kabuki.boxFromCorners(pending.first, point, {
        height = pending.height, floorPad = number("floorPadMetres"),
    })
    if closed == nil then
        return reply(source, raw, false, T("boxInvalid", id, tostring(reason)))
    end
    session.boxes[id] = nil
    volume.min, volume.max = closed.min, closed.max

    -- The first box on a map with no zones is assigned to every format, so a
    -- brand-new map is PLAYABLE the moment its first volume closes rather than
    -- silently suspended. This is a default, not a decision: `dm.map zone`
    -- carves the formats apart the moment somebody has an opinion, and the
    -- line below says out loud that it happened.
    local assigned = false
    local _, total = zoneReadiness(map)
    if total == 0 then
        for _, format in ipairs(ALL_FORMATS) do map.zones[format] = { id } end
        assigned = true
    end

    touch(map)
    persist(map)
    reply(source, raw, true, T("boxClosed", id, footprintX, footprintY,
        volume.min.z, volume.max.z, volume.max.z - volume.min.z,
        boxCount(map), #map.volumes))
    if assigned then reply(source, raw, true, T("boxZoned", id)) end
end

local function cmdUnbox(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local id = cleanVolumeId(args[1])
    local volume = id ~= nil and volumeOf(map, id) or nil
    if volume == nil then
        return reply(source, raw, false, T("unknownVolume", tostring(args[1] or ""),
            volumeIdList(map)))
    end
    local session = sessionOf(source)
    if session ~= nil then session.boxes[id] = nil end
    volume.min, volume.max = nil, nil
    touch(map)
    persist(map)
    reply(source, raw, true, T("boxCleared", id))
end

local function cmdZone(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local format = tostring(args[1] or ""):lower()
    if map.zones[format] == nil then
        return reply(source, raw, false, T("usageZone", table.concat(ALL_FORMATS, ", "),
            volumeIdList(map)))
    end
    if args[2] == nil then
        return reply(source, raw, false, T("usageZone", table.concat(ALL_FORMATS, ", "),
            volumeIdList(map)))
    end

    local list, taken = {}, {}
    local requested = tail(args, 2):gsub("%s+", ",")
    if requested:lower() ~= "none" then
        for token in requested:gmatch("[^,]+") do
            local id = cleanVolumeId(token)
            if id == nil or volumeOf(map, id) == nil then
                return reply(source, raw, false, T("unknownVolume", tostring(token),
                    volumeIdList(map)))
            end
            if not taken[id] then taken[id] = true list[#list + 1] = id end
        end
    end

    map.zones[format] = list
    touch(map)
    persist(map)
    reply(source, raw, true, T("zoneSet", format,
        #list > 0 and table.concat(list, ",") or T("none")))
    if #list == 0 then
        -- An empty zone contains nothing, and a bounds check that contains
        -- nothing places every player on every tick. `locateIn` answers
        -- `zone_empty`, which `Bounds.evaluate` treats as CANNOT TELL -- so
        -- the wall is suspended rather than inverted, and this line is why.
        reply(source, raw, true, T("zoneEmptyWarning", format))
    end
end


-- ------------------------------------------------------------- validation --
--
-- What this map still needs, in one screen, so the answer to "why will 1v1 not
-- start" is read rather than guessed. Everything here is judged by the SAME
-- predicates the running mode uses -- `Kabuki.isSurveyed`, `Kabuki.locateIn`,
-- `Kabuki.point` -- because a diagnostic that judges differently from the
-- enforcement is worse than no diagnostic at all.

--- Returns `problems, notes`.
---
--- The split is load-bearing, not cosmetic. A PROBLEM is something that stops
--- the format starting; a NOTE is something a designer should know and that
--- the mode will happily run anyway. Folding "only four spawn marks for a
--- twelve-player instance" in with "this zone has no box" would report a
--- perfectly playable map as blocked, and a validator that cries wolf gets
--- ignored on the day it is right.
local function formatVerdict(map, format)
    local zone = map.zones[format] or {}
    local problems, notes = {}, {}

    if #zone == 0 then
        problems[#problems + 1] = T("problemNoZone")
    else
        local missing = {}
        for _, id in ipairs(zone) do
            if not Kabuki.isSurveyed(volumeOf(map, id)) then missing[#missing + 1] = id end
        end
        if #missing > 0 then
            problems[#problems + 1] = T("problemNoBox", table.concat(missing, ","))
        end
    end

    if format == "ffa" then
        local count = #map.spawns.ffa
        if count == 0 then
            problems[#problems + 1] = T("problemNoMarks")
        else
            local capacity = tonumber(Kabuki.formats.ffa and Kabuki.formats.ffa.capacity) or 0
            if capacity > 0 and count < capacity then
                notes[#notes + 1] = T("problemThinMarks", count, capacity)
            end
        end
    else
        local required = select(1, setCapacity(findSet(format .. "_a")))
        for _, side in ipairs(SIDES) do
            local list = map.teams[format][side]
            local captured = 0
            for _, mark in ipairs(list) do
                if Kabuki.point(mark.position) ~= nil then captured = captured + 1 end
            end
            if captured < required then
                problems[#problems + 1] = T("problemTeam", side:upper(), captured, required)
            end
        end
    end

    return problems, notes
end

local function cmdCheck(source, raw, args)
    local map = active()
    if map == nil then return reply(source, raw, false, T("noActiveMap")) end
    local only = args[1] ~= nil and tostring(args[1]):lower() or nil
    if only ~= nil and map.zones[only] == nil then
        return reply(source, raw, false, T("usageCheck", table.concat(ALL_FORMATS, ", ")))
    end

    reply(source, raw, true, T("checkHeader", map.name, map.label, storageLine()))

    -- Volumes.
    local boxless = {}
    for _, volume in ipairs(map.volumes) do
        if not Kabuki.isSurveyed(volume) then boxless[#boxless + 1] = volume.id end
    end
    reply(source, raw, true, T("checkVolumes", boxCount(map), #map.volumes,
        #boxless > 0 and table.concat(boxless, ",") or T("none")))

    -- Per format: can it start, and if not, why.
    local playable, blocked = {}, {}
    for _, format in ipairs(ALL_FORMATS) do
        if only == nil or only == format then
            local problems, notes = formatVerdict(map, format)
            if #problems == 0 then
                playable[#playable + 1] = format
                reply(source, raw, true, T("checkFormatOk", format,
                    table.concat(map.zones[format] or {}, ",")))
            else
                blocked[#blocked + 1] = format
                reply(source, raw, true, T("checkFormatBlocked", format,
                    table.concat(problems, "; ")))
            end
            for _, note in ipairs(notes) do
                reply(source, raw, true, T("checkFormatNote", format, note))
            end
        end
    end

    -- The two lobby stations. The MINIMUM IS 6.0 m, from
    -- `Config.stations.minSeparationMetres`, and it is printed from the config
    -- rather than quoted from a comment on purpose: the comment in
    -- shared/kabuki.lua said 4.6 for weeks while the code enforced 6.0, and a
    -- round was lost to the difference. Never quote a number a rule owns.
    local first = Kabuki.point(map.stations[1] and map.stations[1].position)
    local second = Kabuki.point(map.stations[2] and map.stations[2].position)
    local required = tonumber(Config.stations and Config.stations.minSeparationMetres) or 6.0
    if first == nil or second == nil then
        reply(source, raw, true, T("checkStationsMissing",
            first == nil and (second == nil and T("stationsBoth") or "enter") or "queue"))
    else
        local dx, dy = first.x - second.x, first.y - second.y
        local separation = math.sqrt(dx * dx + dy * dy)
        if separation < required then
            reply(source, raw, true, T("checkStationsClose", separation, required))
        else
            reply(source, raw, true, T("checkStationsOk", separation, required))
        end
    end

    -- The spawn sweep server/bounds.lua runs at startup, run here on demand
    -- and against THIS map. A mark outside its own zone starts a fight that
    -- warns the player at two seconds and places them at five, and only a
    -- plain `outside` is the mark's fault: `not_surveyed` and
    -- `outside_partial` mean the box is not walked yet, which is expected
    -- while a map is being authored and is reported above instead.
    local swept, outside = 0, 0
    for _, entry in ipairs(SETS) do
        if entry.kind ~= "named" then
            local format = entry.format or "ffa"
            for index, mark in ipairs(entry.resolve(map) or {}) do
                local point = Kabuki.point(mark.position)
                if point ~= nil then
                    swept = swept + 1
                    local volumeId, reason =
                        Kabuki.locateIn(map.volumes, point, map.zones[format])
                    if volumeId == nil and reason == "outside" then
                        outside = outside + 1
                        local _, distance = Kabuki.nearestIn(map.volumes, point,
                            map.zones[format])
                        reply(source, raw, false, T("checkMarkOutside", entry.key, index,
                            point.x, point.y, point.z, format, distance or -1))
                    end
                end
            end
        end
    end
    reply(source, raw, true, T("checkSweep", swept, outside))

    reply(source, raw, true, T("checkVerdict",
        #playable > 0 and table.concat(playable, ",") or T("none"),
        #blocked > 0 and table.concat(blocked, ",") or T("none")))
end


-- ----------------------------------------------------------------- export --
--
-- The promotion path back into source control, and the only answer to a
-- volatile store: `export` prints the active map as the exact assignment
-- blocks `shared/kabuki.lua` holds, so a finished runtime map can be pasted in
-- and become a BUILT-IN that no database outage can lose.

local function markLiteral(mark, comment)
    local point = Kabuki.point(mark.position)
    if point == nil then
        return ("    { position = nil, heading = 0.0 },%s"):format(comment or "")
    end
    return ("    { position = { x = %.3f, y = %.3f, z = %.3f }, heading = %.1f },%s"):format(
        point.x, point.y, point.z, mark.heading or 0.0,
        comment or (mark.headingKnown and "" or "  -- heading not captured"))
end

local function cmdExport(source, raw, args)
    local name = args[1] ~= nil and cleanName(args[1], 32) or activeName
    local map = name ~= nil and store[name] or nil
    if map == nil then
        return reply(source, raw, false, T("unknownMap", tostring(args[1] or ""), nameList()))
    end

    local lines = {}
    local function emit(text) lines[#lines + 1] = text or "" end

    emit(("-- ==== /dm.map export %s ==============================="):format(map.name))
    emit(("-- label: %s"):format(map.label))
    emit("-- Captured from Open77.players.position on the server. Paste each")
    emit("-- assignment over the matching block in resources/gamemodes/open77_deathmatch/")
    emit("-- shared/kabuki.lua to promote this map to a BUILT-IN.")
    emit("")

    emit("DeathmatchKabuki.volumes = {")
    for _, volume in ipairs(map.volumes) do
        if Kabuki.isSurveyed(volume) then
            emit(("    { id = %q,"):format(volume.id))
            emit(("      min = { x = %.3f, y = %.3f, z = %.3f },"):format(
                volume.min.x, volume.min.y, volume.min.z))
            emit(("      max = { x = %.3f, y = %.3f, z = %.3f } },"):format(
                volume.max.x, volume.max.y, volume.max.z))
        else
            emit(("    { id = %q, min = nil, max = nil },  -- TODO no box"):format(volume.id))
        end
    end
    emit("}")
    emit("")

    emit("DeathmatchKabuki.spawns.ffa = {")
    for index, mark in ipairs(map.spawns.ffa) do
        emit(markLiteral(mark, mark.headingKnown and ("  -- %02d"):format(index)
            or ("  -- %02d, heading not captured"):format(index)))
    end
    emit("}")
    emit("")

    for _, format in ipairs(TEAM_FORMATS) do
        for _, side in ipairs(SIDES) do
            emit(("DeathmatchKabuki.teams[%q].%s = {"):format(format, side))
            for _, mark in ipairs(map.teams[format][side]) do emit(markLiteral(mark)) end
            emit("}")
        end
    end
    emit("")

    emit("DeathmatchKabuki.stations = {")
    for _, mark in ipairs(map.stations) do
        local point = Kabuki.point(mark.position)
        if point == nil then
            emit(("    { id = %q, position = nil, heading = 0.0 },  -- TODO"):format(mark.id))
        else
            emit(("    { id = %q, position = { x = %.3f, y = %.3f, z = %.3f }, heading = %.1f },"):format(
                mark.id, point.x, point.y, point.z, mark.heading or 0.0))
        end
    end
    emit("}")
    emit("")

    -- The zone rule lives in TWO tables and bounds.lua warns when they
    -- disagree, so the export emits both rather than leaving the second to be
    -- remembered.
    for _, format in ipairs(ALL_FORMATS) do
        local zone = map.zones[format] or {}
        local literal = {}
        for index, id in ipairs(zone) do literal[index] = ("%q"):format(id) end
        emit(("DeathmatchKabuki.formats[%q].volumes = { %s }"):format(
            format, table.concat(literal, ", ")))
        emit(("DeathmatchConfig.zones[%q].volumes = { %s }  -- authoritative for bounds.lua"):format(
            format, table.concat(literal, ", ")))
    end
    emit("")

    -- The flag is a claim about the whole map, so it is only emitted when the
    -- claim holds. A half-walked map that announces itself as surveyed is
    -- worse than one that admits it is not.
    local ready, total, missing = zoneReadiness(map)
    if total > 0 and ready == total then
        emit("DeathmatchKabuki.surveyed = true")
    else
        emit(("-- DeathmatchKabuki.surveyed = true  -- withheld: %d/%d zone volume(s) boxed%s"):format(
            ready, total, #missing > 0 and (", missing " .. table.concat(missing, ",")) or ""))
    end
    emit("-- ==== end of export ======================================")

    -- ONE write, not one per line: section 6 of writing-a-gamemode.md was paid
    -- for by a probe that reported 291 ms where the truth was 14 ms.
    print("\n" .. table.concat(lines, "\n"))
    reply(source, raw, true, T("exported", #lines, map.name, boxCount(map),
        #map.volumes, markCount(map)))
end


-- --------------------------------------------------------- store plumbing --

local function cmdStore(source, raw)
    reply(source, raw, true, T("storeLine", storageLine(), #mapNames(),
        tostring(activeName), tostring(declaredActiveName() or T("none"))))
    reply(source, raw, true, T("storeReload",
        type(Open77.state) == "table" and T("yes") or T("no")))
    if dbReady ~= true then reply(source, raw, true, T("storeAdvice")) end
end

local function cmdSave(source, raw)
    local map = active()
    persist(map)
    reply(source, raw, true, T("saveQueued", tostring(map and map.name or "?"), storageLine()))
end

local function cmdReload(source, raw)
    -- Re-probe deliberately: an operator who has just enabled the bridge and
    -- restarted MariaDB should not have to restart the server to find out.
    dbReady, dbReason = nil, "not probed"
    enqueue(readAll)
    reply(source, raw, true, T("reloadQueued", tableName()))
end

local function cmdEdit(source, raw, args)
    local token = tostring(args[1] or ""):lower()
    if token == "on" or token == "1" or token == "true" then
        openSession(source)
        setExempt(source, true)
        return reply(source, raw, true, T("editOn", math.floor(sessionMinutes())))
    end
    if token == "off" or token == "0" or token == "false" then
        closeSession(source)
        return reply(source, raw, true, T("editOff"))
    end
    reply(source, raw, false, T("usageEdit"))
end

local function cmdHelp(source, raw)
    for _, key in ipairs({
        "helpHeader", "helpList", "helpShow", "helpNew", "helpCopy", "helpSelect",
        "helpRename", "helpLabel", "helpDelete", "helpEdit", "helpMark", "helpMarks",
        "helpMove", "helpRemove", "helpStation", "helpBox", "helpUnbox", "helpVolume",
        "helpZone", "helpCheck", "helpExport", "helpStore", "helpSave", "helpReload",
        "helpFooter",
    }) do
        reply(source, raw, true, T(key))
    end
end


-- ---------------------------------------------------------------- dispatch --

-- The verbs that read the CALLER'S OWN POSITION. They are the only ones a
-- console cannot answer, because the console is not standing anywhere -- and
-- refusing them by name is better than letting `Open77.players.position(0)`
-- decide what that means.
local CAPTURES = {
    mark = true, move = true, station = true, box = true, edit = true,
}

local DISPATCH = {
    help = cmdHelp,
    list = cmdList,
    show = cmdShow,
    new = cmdNew,
    copy = cmdCopy,
    select = cmdSelect,
    rename = cmdRename,
    label = cmdLabel,
    delete = cmdDelete,
    edit = cmdEdit,
    mark = cmdMark,
    marks = cmdMarks,
    move = cmdMove,
    remove = cmdRemove,
    station = cmdStation,
    box = cmdBox,
    unbox = cmdUnbox,
    volume = cmdVolume,
    zone = cmdZone,
    check = cmdCheck,
    export = cmdExport,
    store = cmdStore,
    save = cmdSave,
    reload = cmdReload,
}

-- ACL-gated exactly as `/dm.survey` and `/race.editor` are: the third argument
-- of RegisterCommand IS the gate, and nothing inside re-checks it, so nothing
-- inside can forget to.
--
-- Every verb works from the debug bridge and from the console as well as from
-- a player, EXCEPT the ones that capture a coordinate -- those need feet on
-- the ground and say so.
RegisterCommand("dm.map", function(source, args, raw)
    local caller = DM.playerId(source)
    local verb = tostring(args[1] or ""):lower()
    if verb == "" then return cmdHelp(caller or 0, raw) end

    local handler = DISPATCH[verb]
    if handler == nil then
        return reply(caller or 0, raw, false, T("unknownVerb", verb))
    end

    -- Verbs that read the caller's position cannot answer for a console.
    if CAPTURES[verb] and caller == nil then
        return reply(0, raw, false, T("playerOnly"))
    end

    -- Hand the subcommand its own arguments, one-based, so each reads as if it
    -- were the whole command.
    local rest = { n = math.max(0, (args.n or #args) - 1) }
    for index = 2, (args.n or #args) do rest[index - 1] = args[index] end
    handler(caller or 0, raw, rest)
end, true)


-- ----------------------------------------------------------------- startup --

-- Order matters and it is the reverse of intuition. The carried bag is adopted
-- SYNCHRONOUSLY, before `server/bounds.lua` loads and runs its own
-- `Bounds.rebuild()`, so a hot reload comes back up on the authored map rather
-- than on the shipped one and then flipping. The database read is a coroutine
-- and necessarily lands later; it fills in maps the bag could not carry and
-- re-selects the active one if only the database had it.
local adopted = adoptCarried()
local wanted = declaredActiveName()
if wanted ~= nil and store[wanted] ~= nil then
    apply(store[wanted])
else
    apply(store.kabuki)
    if wanted ~= nil and wanted ~= "kabuki" then
        log(("the selected map '%s' is not in memory yet -- playing the built-in until the store answers")
            :format(wanted))
    end
end

CreateThread(function() enqueue(readAll) end)

AddEventHandler("onTunableChanged", function(key, value)
    if tostring(key) ~= "activeMap" then return end
    local name = cleanName(value, 32)
    if name == nil or store[name] == nil or name == activeName then return end
    apply(store[name])
    log(("active map changed to '%s' from the tunables panel"):format(name))
end)

local ready, total = zoneReadiness(active())
log(("ready -- /dm.map (ACL); %d map(s), active '%s', %d/%d zone volume(s) boxed, %s%s")
    :format(#mapNames(), tostring(activeName), ready, total, storageLine(),
        adopted > 0 and (", %d map(s) adopted across a reload"):format(adopted) or ""))
