-- Persistent Race course catalogue.
--
-- Coordinates are never accepted from a browser payload. The editor in
-- server/main.lua captures every start/checkpoint from Open77.players.position
-- and hands the resulting draft to this module for validation and persistence.

local Config = RaceConfig
local CourseConfig = Config.editor

local courses = {}
local selectedId = Config.selectedCourse
local nextOverrideId = nil
local storageReady = false
local storageError = nil
local customSequence = 0
local COURSES_DIRECTORY = "race/courses"
local SETTINGS_FILE = "race/race-settings.json"
local COURSE_SCHEMA_VERSION = 2

local function log(text)
    print("[race:courses] " .. tostring(text))
end

local function clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do copy[clone(key, seen)] = clone(child, seen) end
    return copy
end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function integer(value)
    local number = finite(value)
    if number == nil or number % 1 ~= 0 then return nil end
    return number
end

local function boundedText(value, maximum, fallback)
    if type(value) ~= "string" then value = fallback or "" end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if #value > maximum then value = value:sub(1, maximum) end
    return value
end

local function normalizeHeading(value)
    local heading = finite(value) or 0.0
    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    return heading
end

local function normalizePosition(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = finite(value.x), finite(value.y), finite(value.z)
    if x == nil or y == nil or z == nil then return nil end
    if math.abs(x) > 100000.0 or math.abs(y) > 100000.0 or math.abs(z) > 100000.0 then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function vehicleDefinition(id)
    id = tostring(id or "")
    for _, definition in ipairs(Config.engine.vehicles or {}) do
        if definition.id == id then return definition end
    end
    return nil
end

local function normalizeVehicle(value)
    if type(value) == "table" then value = value.id end
    if value == nil or value == "" then value = Config.engine.vehicle.id end
    local definition = vehicleDefinition(value)
    if definition == nil then return nil, "invalid_vehicle" end
    return definition.id
end

local function validId(value)
    return type(value) == "string" and #value >= 1 and #value <= 64 and
        value:match("^[a-z0-9][a-z0-9_-]*$") ~= nil
end

local function normalizeGrid(value, required)
    if value == nil then
        if required then return nil, "grid_missing" end
        return {}
    end
    if type(value) ~= "table" then return nil, "grid_expected" end
    if #value > CourseConfig.maximumGridSlots then return nil, "too_many_grid_slots" end
    if required and #value < CourseConfig.minimumGridSlots then return nil, "not_enough_grid_slots" end

    local grid = {}
    local spacing = CourseConfig.minimumGridSpacing or 2.5
    for index, slot in ipairs(value) do
        if type(slot) ~= "table" then return nil, "invalid_grid_slot" end
        local position = normalizePosition(slot.position)
        if position == nil then return nil, "invalid_grid_position" end
        for previous = 1, #grid do
            local other = grid[previous].position
            local dx, dy, dz = position.x - other.x, position.y - other.y, position.z - other.z
            if math.sqrt(dx * dx + dy * dy + dz * dz) < spacing then
                return nil, "grid_slots_overlap"
            end
        end
        grid[index] = { position = position, heading = normalizeHeading(slot.heading) }
    end
    return grid
end

local function normalizeCourse(input, metadata)
    if type(input) ~= "table" then return nil, "course_expected" end
    metadata = metadata or {}

    local name = boundedText(input.name, CourseConfig.maximumNameBytes, "")
    if #name < 3 then return nil, "name_too_short" end
    local description = boundedText(
        input.description, CourseConfig.maximumDescriptionBytes, "")
    local courseType = tostring(input.type or "circuit"):lower()
    if courseType ~= "circuit" and courseType ~= "sprint" then
        return nil, "invalid_type"
    end

    local laps = integer(input.laps) or 1
    if courseType == "sprint" then laps = 1 end
    if laps < CourseConfig.minimumLaps or laps > CourseConfig.maximumLaps then
        return nil, "invalid_laps"
    end

    local radius = finite(input.checkpointRadius) or Config.engine.checkpointRadius
    if radius < CourseConfig.minimumRadius or radius > CourseConfig.maximumRadius then
        return nil, "invalid_checkpoint_radius"
    end

    local vehicle, vehicleReason = normalizeVehicle(input.vehicle)
    if vehicle == nil then return nil, vehicleReason end

    local start = type(input.start) == "table" and input.start or nil
    local startPosition = start and normalizePosition(start.position) or nil
    if startPosition == nil then return nil, "start_missing" end

    local grid, gridReason = normalizeGrid(input.grid, metadata.requireGrid == true)
    if grid == nil then return nil, gridReason end

    if type(input.checkpoints) ~= "table" then return nil, "checkpoints_expected" end
    local checkpointCount = #input.checkpoints
    local minimumCheckpoints = courseType == "sprint"
        and CourseConfig.minimumCheckpoints
        or math.max(2, CourseConfig.minimumCheckpoints)
    if checkpointCount < minimumCheckpoints then
        return nil, "not_enough_checkpoints"
    end
    if checkpointCount > CourseConfig.maximumCheckpoints then
        return nil, "too_many_checkpoints"
    end

    local checkpoints = {}
    for index, checkpoint in ipairs(input.checkpoints) do
        if type(checkpoint) ~= "table" then return nil, "invalid_checkpoint" end
        local position = normalizePosition(checkpoint.position)
        if position == nil then return nil, "invalid_checkpoint_position" end
        local checkpointRadius = checkpoint.radius ~= nil and finite(checkpoint.radius) or nil
        if checkpointRadius ~= nil and
            (checkpointRadius < CourseConfig.minimumRadius or
             checkpointRadius > CourseConfig.maximumRadius) then
            return nil, "invalid_checkpoint_radius"
        end
        checkpoints[index] = {
            id = (index == checkpointCount and courseType == "sprint")
                and "finish" or ("cp_%03d"):format(index),
            position = position,
            heading = normalizeHeading(checkpoint.heading),
            radius = checkpointRadius,
        }
    end

    return {
        id = metadata.id or input.id,
        name = name,
        description = description,
        type = courseType,
        laps = laps,
        checkpointRadius = radius,
        vehicle = vehicle,
        start = { position = startPosition, heading = normalizeHeading(start.heading) },
        grid = grid,
        checkpoints = checkpoints,
        builtin = metadata.builtin == true or input.builtin == true,
        authorId = metadata.authorId or input.authorId,
        authorName = metadata.authorName or input.authorName,
        revision = integer(metadata.revision or input.revision) or 1,
    }
end

local function slug(value)
    local text = tostring(value or "course"):lower()
    text = text:gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
    if text == "" then text = "course" end
    return text:sub(1, 36)
end

local function newId(name, playerId)
    local stamp = math.floor(Open77.time.monotonic() * 1000)
    local id
    repeat
        customSequence = customSequence + 1
        local suffix = ("-%d-%d-%d"):format(playerId or 0, stamp, customSequence)
        id = slug(name):sub(1, 64 - #suffix) .. suffix
    until courses[id] == nil
    return id
end

local function summary(course)
    return {
        id = course.id,
        name = course.name,
        description = course.description,
        type = course.type,
        laps = course.laps,
        checkpointCount = #course.checkpoints,
        gridCount = #(course.grid or {}),
        gridCapacity = #(course.grid or {}) > 0 and #course.grid or Config.engine.maxRacers,
        checkpointRadius = course.checkpointRadius,
        vehicle = course.vehicle,
        vehicleLabel = (vehicleDefinition(course.vehicle) or {}).label,
        builtin = course.builtin == true,
        authorName = course.authorName,
        revision = course.revision,
        -- "selected" means an explicit one-heat admin override is pending;
        -- selectedId remains only the persistent idle/fallback preview.
        selected = course.id == nextOverrideId,
    }
end

local function emitChanged(reason)
    TriggerEvent("race:coursesChanged", reason or "changed")
end

local function persistCourse(course)
    local payload = clone(course)
    payload.schemaVersion = COURSE_SCHEMA_VERSION
    payload.builtin = nil
    local ok, reason = Open77.io.writeJson(
        ("%s/%s.json"):format(COURSES_DIRECTORY, course.id), payload)
    if not ok then
        storageReady = false
        storageError = tostring(reason or "write_failed")
        log("course file write failed: " .. storageError)
        return false, storageError
    end
    storageReady = true
    storageError = nil
    return true
end

local function persistSelection()
    local ok, reason = Open77.io.writeJson(SETTINGS_FILE, {
        schemaVersion = 1,
        selectedCourse = selectedId,
    })
    if not ok then
        storageReady = false
        storageError = tostring(reason or "write_failed")
        log("selection file write failed: " .. storageError)
        return false, storageError
    end
    storageReady = true
    storageError = nil
    return true
end

RaceCourses = {}

function RaceCourses.get(id)
    local course = courses[tostring(id or "")]
    return course and clone(course) or nil
end

function RaceCourses.vehicle(id)
    local definition = vehicleDefinition(id) or vehicleDefinition(Config.engine.vehicle.id)
    if definition == nil then return nil end
    local result = clone(definition)
    result.primaryColor = result.primaryColor or clone(Config.engine.vehicle.primaryColor)
    result.secondaryColor = result.secondaryColor or clone(Config.engine.vehicle.secondaryColor)
    return result
end

function RaceCourses.vehicles()
    local result = {}
    for _, definition in ipairs(Config.engine.vehicles or {}) do
        result[#result + 1] = { id = definition.id, label = definition.label }
    end
    return result
end

function RaceCourses.selected()
    local course = courses[selectedId]
    if course == nil then
        for id, candidate in pairs(courses) do
            selectedId, course = id, candidate
            break
        end
    end
    return course and clone(course) or nil
end

function RaceCourses.random(excludedId)
    excludedId = tostring(excludedId or "")
    local ids = {}
    for id in pairs(courses) do
        if id ~= excludedId then ids[#ids + 1] = id end
    end
    -- A single-course catalogue cannot avoid an immediate repeat.
    if #ids == 0 and excludedId ~= "" and courses[excludedId] ~= nil then
        ids[1] = excludedId
    end
    if #ids == 0 then return nil end
    table.sort(ids)
    return clone(courses[ids[math.random(#ids)]])
end

function RaceCourses.next(excludedId)
    if nextOverrideId ~= nil then
        local course = courses[nextOverrideId]
        nextOverrideId = nil
        if course ~= nil then return clone(course) end
    end
    return RaceCourses.random(excludedId)
end

function RaceCourses.list()
    local result = {}
    for _, course in pairs(courses) do result[#result + 1] = summary(course) end
    table.sort(result, function(left, right)
        if left.builtin ~= right.builtin then return left.builtin end
        return left.name:lower() < right.name:lower()
    end)
    return result
end

function RaceCourses.storageState()
    return {
        ready = storageReady,
        error = storageError,
        directory = "data/" .. COURSES_DIRECTORY,
        format = "json",
    }
end

function RaceCourses.validate(input)
    return normalizeCourse(input, { requireGrid = true })
end

function RaceCourses.save(playerId, input)
    local requestedId = type(input) == "table" and tostring(input.id or "") or ""
    local existing = requestedId ~= "" and courses[requestedId] or nil
    if existing ~= nil and existing.builtin then return nil, "builtin_readonly" end

    local identity = Open77.players.identifier(playerId)
    local displayName = Open77.players.name(playerId) or ("Player " .. tostring(playerId))
    local id = existing and existing.id or newId(input and input.name, playerId)
    local course, reason = normalizeCourse(input, {
        id = id,
        builtin = false,
        authorId = existing and existing.authorId or identity or ("player:" .. tostring(playerId)),
        authorName = existing and existing.authorName or displayName,
        revision = existing and (existing.revision + 1) or 1,
        requireGrid = true,
    })
    if course == nil then return nil, reason end

    local persisted, persistReason = persistCourse(course)
    if not persisted then return nil, "storage_write_failed:" .. tostring(persistReason) end
    courses[id] = course
    emitChanged(existing and "updated" or "created")
    return clone(course)
end

function RaceCourses.remove(id)
    id = tostring(id or "")
    local course = courses[id]
    if course == nil then return false, "course_not_found" end
    if course.builtin then return false, "builtin_readonly" end
    local removed, removeReason = Open77.io.remove(
        ("%s/%s.json"):format(COURSES_DIRECTORY, id))
    if not removed and removeReason ~= "not_found" then
        storageReady = false
        storageError = tostring(removeReason or "delete_failed")
        return false, "storage_delete_failed:" .. storageError
    end
    courses[id] = nil
    if nextOverrideId == id then nextOverrideId = nil end
    if selectedId == id then
        selectedId = Config.selectedCourse
        if courses[selectedId] == nil then selectedId = next(courses) end
        persistSelection()
    end
    emitChanged("deleted")
    return true
end

function RaceCourses.select(id)
    id = tostring(id or "")
    if courses[id] == nil then return false, "course_not_found" end
    local previous = selectedId
    selectedId = id
    local persisted, reason = persistSelection()
    if not persisted then
        selectedId = previous
        return false, "storage_write_failed:" .. tostring(reason)
    end
    -- An explicit admin/editor selection overrides the random draw once. The
    -- following heat returns to random rotation automatically.
    nextOverrideId = id
    emitChanged("selected")
    return true
end

function RaceCourses.initialize()
    local made, makeReason = Open77.io.makeDirectory(COURSES_DIRECTORY)
    if not made then
        storageReady = false
        storageError = tostring(makeReason or "mkdir_failed")
        log("JSON course storage unavailable: " .. storageError)
        emitChanged("storage_unavailable")
        return
    end

    local entries, listReason = Open77.io.list(COURSES_DIRECTORY)
    if entries == nil then
        storageReady = false
        storageError = tostring(listReason or "list_failed")
        log("JSON course storage unavailable: " .. storageError)
        emitChanged("storage_unavailable")
        return
    end

    local loaded, migrated = 0, 0
    for _, entry in ipairs(entries) do
        local fileId = entry.type == "file" and entry.name:match(
            "^([a-z0-9][a-z0-9_-]*)%.json$") or nil
        if validId(fileId) and courses[fileId] == nil then
            local input, readReason = Open77.io.readJson(
                ("%s/%s"):format(COURSES_DIRECTORY, entry.name))
            if input == nil then
                log(("course file '%s' unreadable: %s"):format(
                    tostring(entry.name), tostring(readReason)))
            elseif input.schemaVersion ~= 1 and input.schemaVersion ~= COURSE_SCHEMA_VERSION then
                log(("course file '%s' rejected: unsupported_schema"):format(entry.name))
            else
                local course, invalid = normalizeCourse(input, {
                    id = fileId,
                    builtin = false,
                    authorId = input.authorId,
                    authorName = input.authorName,
                    revision = input.revision,
                    requireGrid = true,
                })
                if course ~= nil then
                    courses[fileId] = course
                    loaded = loaded + 1
                    if input.schemaVersion < COURSE_SCHEMA_VERSION then
                        local upgraded, upgradeReason = persistCourse(course)
                        if upgraded then
                            migrated = migrated + 1
                        else
                            log(("course file '%s' migration failed: %s"):format(
                                tostring(entry.name), tostring(upgradeReason)))
                        end
                    end
                else
                    log(("course file '%s' rejected: %s"):format(
                        tostring(entry.name), tostring(invalid)))
                end
            end
        end
    end

    local settings, settingsReason = Open77.io.readJson(SETTINGS_FILE)
    if settings ~= nil and settings.schemaVersion == 1 and
        type(settings.selectedCourse) == "string" and courses[settings.selectedCourse] ~= nil then
        selectedId = settings.selectedCourse
    elseif settingsReason ~= nil and settingsReason ~= "not_found" then
        log("race settings file unreadable: " .. tostring(settingsReason))
    end
    if courses[selectedId] == nil then selectedId = next(courses) end
    storageReady = true
    storageError = nil
    log(("JSON storage ready; %d custom course(s), %d migrated to schema %d, selected=%s"):format(
        loaded, migrated, COURSE_SCHEMA_VERSION, tostring(selectedId)))
    emitChanged("loaded")
end

RaceCourses.initialize()
