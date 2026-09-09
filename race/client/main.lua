-- Race client presentation. The server owns course selection, checkpoint
-- acceptance, laps, time and ranking; this file only renders and sends intent.

local Config = RaceConfig

local page
local pageReady = false
local lastPushError = nil
local panelOpen = false
local boardHeld = false
local chatOpen = false
local noticeUntil = 0.0
local announced = false
local lobbyPoi = nil
local lobbyPoiCreating = false
local lobbyPoiEpoch = 0
local courseState = nil
local checkpointZones = {}
local nextBlip = nil
local nextBlipKey = nil
local nextBlipTrackCheckAt = 0.0
local state = nil
local editorState = nil
local editorPreviewSignature = nil
local editorPreviewHandles = {}
local editorPreviewDesired = {}
local editorPreviewRevision = 0
local editorPreviewAppliedRevision = 0
local editorPreviewSyncing = false
local editorPreviewOmitted = nil
local editorKeys = {}
local anchorAt = 0.0
local anchorRemainingMs = 0
local anchorElapsedMs = 0
local lastStateDigest = nil
local lastPhase = nil
local lastCountdownSecond = nil
local presentationHandles = {}
local countdownHandle = nil
local controlledVehicleId = nil
local controlsLocked = false
local physicsFrozen = false
local nextControlLockAttemptAt = 0.0
local lastControlLockError = nil
local lastPhysicsFreezeError = nil

local function nowSeconds()
    return Open77.time.monotonic()
end

local function callExport(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    local result, callReason = promise:await()
    if not result or not result.ok then
        return nil, callReason or (result and result.error) or "export_failed"
    end
    return result
end

local function startLinePosition()
    local center, offset = Config.lobby.center, Config.lobby.start.offset
    return { x = center.x + offset.x, y = center.y + offset.y, z = center.z + offset.z }
end

local function headingFromCamera()
    local view = Open77.camera.view()
    if type(view) ~= "table" or type(view.forward) ~= "table" then return 0.0 end
    local x, y = tonumber(view.forward.x), tonumber(view.forward.y)
    if x == nil or y == nil or math.abs(x) + math.abs(y) < 0.0001 then return 0.0 end
    -- REDengine yaw 0 faces +Y: forward=(-sin(yaw), cos(yaw)).
    local heading = math.deg(math.atan(-x, y)) % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    return heading
end

local function headingForEditor()
    local character = Open77.character.state()
    local yaw = type(character) == "table" and tonumber(character.yaw) or nil
    if type(character) == "table" and character.inVehicle == true and yaw ~= nil then
        yaw = yaw % 360.0
        if yaw < 0.0 then yaw = yaw + 360.0 end
        return yaw
    end
    return headingFromCamera()
end

local function interpolatedTimes()
    if state == nil then return 0, 0 end
    local delta = math.max(0, (nowSeconds() - anchorAt) * 1000)
    local phase = tostring(state.phase or "waiting")
    local remaining = anchorRemainingMs
    local elapsed = anchorElapsedMs
    if phase == "forming" or phase == "grid" or phase == "countdown" or
        phase == "active" or phase == "results" then
        remaining = math.max(0, anchorRemainingMs - delta)
    end
    if phase == "active" then elapsed = anchorElapsedMs + delta end
    return remaining, elapsed
end

local function checkpointGuidance()
    local phase = state and tostring(state.phase or "waiting") or "waiting"
    local nextCheckpoint = state and state.nextCheckpoint
    if phase ~= "active" or state.participant ~= true or
        type(nextCheckpoint) ~= "table" or type(nextCheckpoint.position) ~= "table" then
        return { visible = false }
    end

    local view = Open77.camera.view()
    local character = Open77.character.state()
    if type(view) ~= "table" or type(view.forward) ~= "table" or
        type(character) ~= "table" or type(character.position) ~= "table" then
        return { visible = false }
    end

    local origin = character.position
    local target = nextCheckpoint.position
    local ox, oy, oz = tonumber(origin.x), tonumber(origin.y), tonumber(origin.z)
    local tx, ty, tz = tonumber(target.x), tonumber(target.y), tonumber(target.z)
    local fx, fy = tonumber(view.forward.x), tonumber(view.forward.y)
    if not ox or not oy or not oz or not tx or not ty or not tz or not fx or not fy then
        return { visible = false }
    end

    local forwardLength = math.sqrt(fx * fx + fy * fy)
    if forwardLength < 0.0001 then return { visible = false } end
    fx, fy = fx / forwardLength, fy / forwardLength

    local dx, dy, dz = tx - ox, ty - oy, tz - oz
    local horizontal = math.sqrt(dx * dx + dy * dy)
    local distance = math.sqrt(horizontal * horizontal + dz * dz)
    local forwardDot = dx * fx + dy * fy
    local rightDot = dx * fy - dy * fx
    local angle = horizontal > 0.01 and math.deg(math.atan(rightDot, forwardDot)) or 0.0
    local absoluteAngle = math.abs(angle)
    local direction = "AHEAD"
    if absoluteAngle >= 150.0 then
        direction = "BEHIND"
    elseif angle <= -30.0 then
        direction = "LEFT"
    elseif angle >= 30.0 then
        direction = "RIGHT"
    end

    return {
        visible = true,
        angle = angle,
        elevation = horizontal > 0.01 and math.deg(math.atan(dz, horizontal)) or 0.0,
        distance = distance,
        direction = direction,
        checkpoint = tonumber(nextCheckpoint.index) or tonumber(state.checkpointIndex) or 1,
        total = tonumber(state.totalCheckpoints) or 1,
        finish = tonumber(nextCheckpoint.index) == tonumber(state.totalCheckpoints) and
            tonumber(state.lap) == tonumber(state.laps),
        radius = tonumber(nextCheckpoint.radius) or Config.engine.checkpointRadius,
    }
end

local function push()
    if page == nil or not pageReady or state == nil then return end
    local remaining, elapsed = interpolatedTimes()
    state.remainingMs = remaining
    state.elapsedMs = elapsed
    state.panelOpen = panelOpen
    state.boardHeld = boardHeld
    state.chatOpen = chatOpen
    state.noticeOpen = nowSeconds() < noticeUntil
    if editorState ~= nil then editorState.keys = editorKeys end
    state.editor = editorState
    state.guidance = checkpointGuidance()
    local sent, reason = page:send("race:render", state)
    local failure = not sent and tostring(reason or "surface_unavailable") or nil
    if failure ~= lastPushError then
        lastPushError = failure
        if failure then Open77.log.error("Race UI state rejected: " .. failure) end
    end
end

local function setPanel(open)
    open = open == true
    if open then FreeroamMenu.close() end
    if panelOpen == open then return end
    panelOpen = open
    if page then
        page:setFocus(open, open)
        page:send("race:panel", { open = open })
    end
    push()
end

FreeroamRaceClient = {
    close = function() setPanel(false) end,
    ownsHud = function()
        return panelOpen or (state and state.participant == true) or editorState ~= nil
    end,
}

local function teardownLobby()
    lobbyPoiEpoch = lobbyPoiEpoch + 1
    lobbyPoiCreating = false
    if lobbyPoi ~= nil then
        callExport("open77_worldui", "remove", lobbyPoi)
        lobbyPoi = nil
    end
end

local function editorPointSignature(parts, kind, index, point)
    local position = type(point) == "table" and point.position or nil
    if type(position) ~= "table" then return end
    parts[#parts + 1] = ("%s:%d:%.3f:%.3f:%.3f:%.2f"):format(
        kind, index,
        tonumber(position.x) or 0.0,
        tonumber(position.y) or 0.0,
        tonumber(position.z) or 0.0,
        tonumber(point.heading) or 0.0)
end

local function editorPreviewDefinition(id, point, style, radius)
    local position = type(point) == "table" and point.position or nil
    if type(position) ~= "table" then return nil end
    return {
        id = id,
        position = {
            x = tonumber(position.x) or 0.0,
            y = tonumber(position.y) or 0.0,
            z = tonumber(position.z) or 0.0,
        },
        style = style,
        shape = "ring",
        radius = radius,
        maxDistance = 500.0,
        groundOffset = 0.08,
    }
end

local function editorPreviewDefinitionSignature(definition)
    local position = definition.position
    return ("%s:%.3f:%.3f:%.3f:%s:%s:%.2f:%.2f:%.2f"):format(
        tostring(definition.id),
        tonumber(position.x) or 0.0,
        tonumber(position.y) or 0.0,
        tonumber(position.z) or 0.0,
        tostring(definition.style),
        tostring(definition.shape),
        tonumber(definition.radius) or 0.0,
        tonumber(definition.maxDistance) or 0.0,
        tonumber(definition.groundOffset) or 0.0)
end

local function editorPreviewPlan(draft)
    if type(draft) ~= "table" then return nil, {} end
    local parts = {
        tostring(draft.type or "circuit"),
        ("%.2f"):format(tonumber(draft.checkpointRadius) or 0.0),
    }
    local fixedDefinitions = {}
    local checkpointDefinitions = {}

    editorPointSignature(parts, "start", 1, draft.start)
    local start = editorPreviewDefinition("editor_start", draft.start, "spawn", 2.0)
    if start ~= nil then fixedDefinitions[#fixedDefinitions + 1] = start end

    for index, point in ipairs(type(draft.grid) == "table" and draft.grid or {}) do
        editorPointSignature(parts, "grid", index, point)
        local definition = editorPreviewDefinition(
            ("editor_grid_%02d"):format(index), point, "interaction", 1.35)
        if definition ~= nil then fixedDefinitions[#fixedDefinitions + 1] = definition end
    end

    local checkpoints = type(draft.checkpoints) == "table" and draft.checkpoints or {}
    for index, point in ipairs(checkpoints) do
        editorPointSignature(parts, "checkpoint", index, point)
        local requestedRadius = tonumber(point.radius) or tonumber(draft.checkpointRadius) or 7.0
        local definition = editorPreviewDefinition(
            ("editor_checkpoint_%03d"):format(index), point,
            index == #checkpoints and "danger" or "objective",
            math.max(1.0, math.min(30.0, requestedRadius)))
        if definition ~= nil then checkpointDefinitions[#checkpointDefinitions + 1] = definition end
    end

    -- The native marker registry has a hard ceiling of 64 entries for the
    -- open77_worldui adapter. Keep deliberate headroom for other resources and
    -- show a rolling trail when a course contains more points than can be
    -- rendered at once. The complete draft remains server-side and in the HUD;
    -- only old preview rings behind the driver are hidden.
    local maximum = 48
    local definitions = {}
    for _, definition in ipairs(fixedDefinitions) do
        if #definitions >= maximum then break end
        definitions[#definitions + 1] = definition
    end
    local remaining = maximum - #definitions
    local firstCheckpoint = math.max(1, #checkpointDefinitions - remaining + 1)
    for index = firstCheckpoint, #checkpointDefinitions do
        if #definitions >= maximum then break end
        definitions[#definitions + 1] = checkpointDefinitions[index]
    end

    local omitted = #fixedDefinitions + #checkpointDefinitions - #definitions
    if omitted ~= editorPreviewOmitted then
        editorPreviewOmitted = omitted
        if omitted > 0 then
            Open77.log.info(("Race editor preview shows %d current markers; %d older marker(s) are hidden"):format(
                #definitions, omitted))
        end
    end
    return table.concat(parts, "|"), definitions
end

local function startEditorPreviewSync()
    if editorPreviewSyncing then return end
    editorPreviewSyncing = true
    CreateThread(function()
        while editorPreviewAppliedRevision ~= editorPreviewRevision do
            local revision = editorPreviewRevision
            local definitions = editorPreviewDesired
            local desired = {}
            for _, definition in ipairs(definitions) do
                desired[definition.id] = {
                    definition = definition,
                    signature = editorPreviewDefinitionSignature(definition),
                }
            end

            -- Remove only stale or genuinely changed points. Recreating the
            -- whole course after every F8 press could overlap export calls and
            -- exhaust the 64-marker native quota.
            for id, current in pairs(editorPreviewHandles) do
                local wanted = desired[id]
                if wanted == nil or wanted.signature ~= current.signature then
                    local _, reason = callExport("open77_worldui", "remove", current.handle)
                    if reason ~= nil and reason ~= "poi_not_found" then
                        Open77.log.warn(("Race editor marker %s removal failed: %s"):format(
                            tostring(id), tostring(reason)))
                    end
                    editorPreviewHandles[id] = nil
                end
            end

            for index, definition in ipairs(definitions) do
                local wanted = desired[definition.id]
                if editorPreviewHandles[definition.id] == nil then
                    local result, reason = callExport(
                        "open77_worldui", "create", definition)
                    if result and result.handle ~= nil then
                        editorPreviewHandles[definition.id] = {
                            handle = result.handle,
                            signature = wanted.signature,
                        }
                    else
                        Open77.log.warn(("Race editor marker %d (%s) failed: %s"):format(
                            index, tostring(definition.id), tostring(reason)))
                    end
                end
            end

            editorPreviewAppliedRevision = revision
        end

        editorPreviewSyncing = false
        -- An event can arrive after the loop condition but before the flag is
        -- cleared. Re-enter explicitly so that update cannot be lost.
        if editorPreviewAppliedRevision ~= editorPreviewRevision then
            startEditorPreviewSync()
        end
    end)
end

local function refreshEditorPreview(draft)
    local signature, definitions = editorPreviewPlan(draft)
    if signature == editorPreviewSignature then return end
    editorPreviewSignature = signature
    editorPreviewDesired = definitions
    editorPreviewRevision = editorPreviewRevision + 1
    startEditorPreviewSync()
end

local function teardownEditorPreview()
    refreshEditorPreview(nil)
end

local function clearBlip()
    RaceCheckpointVisual.clear()
    if nextBlip ~= nil then
        Open77.blips.remove(nextBlip)
        nextBlip = nil
    end
    nextBlipKey = nil
    nextBlipTrackCheckAt = 0.0
end

local function trackNextBlip(context)
    if nextBlip == nil then return false end
    local ok, changedOrReason = Open77.blips.track(nextBlip)
    nextBlipTrackCheckAt = nowSeconds() + (ok and 2.0 or 1.0)
    if not ok then
        Open77.log.warn(("Race checkpoint GPS track failed (%s): %s"):format(
            tostring(context), tostring(changedOrReason)))
        return false
    end
    if changedOrReason == true then
        Open77.log.info(("Race checkpoint GPS destination selected (%s): id=%s"):format(
            tostring(context), tostring(nextBlip)))
    end
    return true
end

local function gpsContextReady()
    local phase = state and tostring(state.phase or "waiting") or "waiting"
    -- Register the destination on the grid so its HUD point already exists,
    -- but select it only after the driver is seated. The vanilla GPS
    -- controller snapshots pedestrian/vehicle context when tracking starts;
    -- selecting the point before the car materializes can leave a valid
    -- manually-tracked id with no minimap road route for the whole heat.
    return phase == "countdown" or phase == "active"
end

local function setAssignedVehicleLock(vehicleId, locked, context)
    if type(Open77.vehicles) ~= "table" or
        type(Open77.vehicles.setControlLock) ~= "function" then
        if lastControlLockError ~= "api_unavailable" then
            Open77.log.error("Race grid lock unavailable: Open77.vehicles.setControlLock missing")
            lastControlLockError = "api_unavailable"
        end
        return false
    end
    local ok, reason = Open77.vehicles.setControlLock(vehicleId, locked == true)
    if not ok then
        local errorKey = tostring(vehicleId) .. ":" .. tostring(locked) .. ":" .. tostring(reason)
        if lastControlLockError ~= errorKey then
            Open77.log.warn(("Race grid lock failed (%s, vehicle=%s, locked=%s): %s"):format(
                tostring(context), tostring(vehicleId), tostring(locked), tostring(reason)))
            lastControlLockError = errorKey
        end
        return false
    end
    lastControlLockError = nil
    Open77.log.info(("Race vehicle controls %s (%s): id=%s"):format(
        locked and "locked" or "released", tostring(context), tostring(vehicleId)))
    return true
end

local function setAssignedVehicleFrozen(vehicleId, frozen, context)
    if type(Open77.vehicles) ~= "table" or
        type(Open77.vehicles.setFrozen) ~= "function" then
        if lastPhysicsFreezeError ~= "api_unavailable" then
            Open77.log.error("Race grid freeze unavailable: Open77.vehicles.setFrozen missing")
            lastPhysicsFreezeError = "api_unavailable"
        end
        return false
    end
    local ok, reason = Open77.vehicles.setFrozen(vehicleId, frozen == true)
    if not ok then
        local errorKey = tostring(vehicleId) .. ":" .. tostring(frozen) .. ":" .. tostring(reason)
        if lastPhysicsFreezeError ~= errorKey then
            Open77.log.warn(("Race grid freeze failed (%s, vehicle=%s, frozen=%s): %s"):format(
                tostring(context), tostring(vehicleId), tostring(frozen), tostring(reason)))
            lastPhysicsFreezeError = errorKey
        end
        return false
    end
    lastPhysicsFreezeError = nil
    Open77.log.info(("Race vehicle physics %s (%s): id=%s"):format(
        frozen and "frozen" or "released", tostring(context), tostring(vehicleId)))
    return true
end

local function releaseAssignedVehicle(context)
    local released = true
    if controlledVehicleId ~= nil and physicsFrozen then
        if setAssignedVehicleFrozen(controlledVehicleId, false, context) then
            physicsFrozen = false
        else
            released = false
        end
    end
    if controlledVehicleId ~= nil and controlsLocked then
        if setAssignedVehicleLock(controlledVehicleId, false, context) then
            controlsLocked = false
        else
            released = false
        end
    end
    if not released then
        nextControlLockAttemptAt = nowSeconds() + 0.10
        return false
    end
    controlledVehicleId = nil
    nextControlLockAttemptAt = 0.0
    return true
end

local function syncAssignedVehicleLock()
    local phase = state and tostring(state.phase or "waiting") or "waiting"
    local vehicle = state and state.vehicle
    local target = nil
    if state and state.participant == true and
        (phase == "grid" or phase == "countdown") and type(vehicle) == "table" and
        (type(vehicle.id) == "number" or type(vehicle.id) == "string") then
        -- Entity ids are opaque 64-bit values. Preserve the representation the
        -- server sent; tonumber() would lose precision above 2^53.
        target = vehicle.id
    end

    if target == nil then
        releaseAssignedVehicle("phase:" .. phase)
        return
    end
    if controlledVehicleId ~= nil and controlledVehicleId ~= target then
        if not releaseAssignedVehicle("vehicle_changed") then return end
    end
    controlledVehicleId = target
    if (controlsLocked and physicsFrozen) or nowSeconds() < nextControlLockAttemptAt then return end
    local complete = true
    if not controlsLocked then
        if setAssignedVehicleLock(target, true, "phase:" .. phase) then
            controlsLocked = true
        else
            complete = false
        end
    end
    if not physicsFrozen then
        if setAssignedVehicleFrozen(target, true, "phase:" .. phase) then
            physicsFrozen = true
        else
            complete = false
        end
    end
    if not complete then
        -- The authoritative state can arrive a few frames before the native
        -- vehicle projection. Retry without spamming logs or fighting physics.
        nextControlLockAttemptAt = nowSeconds() + 0.25
    end
end

local function rememberPresentation(kind, handle)
    if handle ~= nil then
        presentationHandles[#presentationHandles + 1] = { kind = kind, handle = handle }
    end
    return handle
end

local function stopPresentationHandle(kind, handle)
    if handle == nil then return end
    if kind == "sfx" and Open77.sfx and Open77.sfx.stop then
        Open77.sfx.stop(handle)
    elseif Open77.vfx and Open77.vfx.stop then
        Open77.vfx.stop(handle)
    end
end

local function stopPresentation()
    for _, entry in ipairs(presentationHandles) do
        stopPresentationHandle(entry.kind, entry.handle)
    end
    presentationHandles = {}
    countdownHandle = nil
end

local function playRaceSfx(event, tag, duration)
    if type(event) ~= "string" or event == "" or
        type(Open77.sfx) ~= "table" or type(Open77.sfx.play) ~= "function" then
        return nil
    end
    local handle, reason = Open77.sfx.play(event, {
        tag = tag,
        unique = true,
        duration = duration,
    })
    if handle == nil then
        Open77.log.debug(("Race SFX %s failed: %s"):format(event, tostring(reason)))
        return nil
    end
    return rememberPresentation("sfx", handle)
end

local function startTransform(offset)
    local start = courseState and courseState.course and courseState.course.start
    if type(start) ~= "table" or type(start.position) ~= "table" then return nil end
    local position = start.position
    local yaw = math.rad(tonumber(start.heading) or 0.0)
    local forwardX, forwardY = -math.sin(yaw), math.cos(yaw)
    local rightX, rightY = math.cos(yaw), math.sin(yaw)
    local forward = tonumber(offset.forward) or 0.0
    local lateral = tonumber(offset.lateral) or 0.0
    local halfYaw = yaw * 0.5
    return {
        position = {
            x = position.x + forwardX * forward + rightX * lateral,
            y = position.y + forwardY * forward + rightY * lateral,
            z = position.z + (tonumber(offset.z) or 0.0),
        },
        orientation = {
            x = 0.0, y = 0.0,
            z = math.sin(halfYaw), w = math.cos(halfYaw),
        },
        duration = tonumber(offset.duration) or 5.0,
        ignoreTimeDilation = true,
    }
end

local function playStartVfx()
    local presentation = Config.presentation or {}
    if type(Open77.vfx) ~= "table" or type(Open77.vfx.play) ~= "function" or
        type(presentation.startVfx) ~= "table" then return end
    for _, definition in ipairs(presentation.startVfx) do
        local transform = type(definition) == "table" and startTransform(definition) or nil
        if transform ~= nil and type(definition.effect) == "string" then
            local handle, reason = Open77.vfx.play(definition.effect, transform)
            if handle ~= nil then
                rememberPresentation("vfx", handle)
            else
                Open77.log.debug(("Race VFX %s failed: %s"):format(
                    definition.effect, tostring(reason)))
            end
        end
    end
end

local function teardownCourse()
    for _, handle in ipairs(checkpointZones) do
        callExport("open77_zones", "remove", handle)
    end
    checkpointZones = {}
    courseState = nil
    clearBlip()
    stopPresentation()
end

local function buildLobby()
    if Config.lobby.start.enabled == false then return end
    -- `race:state` is sent several times per second.  The lobby POI is durable;
    -- rebuilding it for every state packet makes its native marker and prompt
    -- despawn/respawn continuously (and retriggers the vanilla interaction HUD,
    -- including the stamina bar).  The epoch also prevents an in-flight export
    -- from resurrecting the lobby after the player has entered a heat.
    if lobbyPoi ~= nil or lobbyPoiCreating then return end
    lobbyPoiCreating = true
    local epoch = lobbyPoiEpoch
    local start = Config.lobby.start
    local result, reason = callExport("open77_worldui", "create", {
        id = start.id,
        position = startLinePosition(),
        radius = start.radius,
        style = start.style,
        maxDistance = start.maxDistance,
        label = start.label,
        description = start.description,
        key = start.key,
        holdSeconds = start.holdSeconds,
        color = start.color,
        icon = "DIALOG",
        event = "race:lobbySelected",
    })
    if epoch ~= lobbyPoiEpoch then
        if result and result.handle ~= nil then
            callExport("open77_worldui", "remove", result.handle)
        end
        return
    end
    lobbyPoiCreating = false
    if result and result.handle ~= nil then
        lobbyPoi = result.handle
    else
        Open77.log.error("Race lobby POI failed: " .. tostring(reason))
    end
end

local function buildCourse(payload)
    teardownCourse()
    if type(payload) ~= "table" or type(payload.course) ~= "table" or
        type(payload.course.checkpoints) ~= "table" then return end
    courseState = payload
    for index, checkpoint in ipairs(payload.course.checkpoints) do
        local eventName = ("race:checkpoint:%s:%d"):format(tostring(payload.heatId), index)
        local result, reason = callExport("open77_zones", "create", {
            id = ("race_%s_%d"):format(tostring(payload.heatId), index),
            position = checkpoint.position,
            radius = (checkpoint.radius or payload.course.checkpointRadius or
                Config.engine.checkpointRadius) + 1.5,
            enterEvent = eventName,
        })
        if result then
            checkpointZones[#checkpointZones + 1] = result.handle
            local checkpointId = checkpoint.id
            AddEventHandler(eventName, function()
                TriggerServerEvent("race:checkpointIntent", checkpointId)
            end)
        else
            Open77.log.error(("Race checkpoint zone %d failed: %s"):format(
                index, tostring(reason)))
        end
    end
    teardownLobby()
    Open77.log.info(("Race course %s loaded: %d checkpoint(s)"):format(
        tostring(payload.course.id), #payload.course.checkpoints))
end

local function updateBlip(nextCheckpoint)
    if type(nextCheckpoint) ~= "table" or type(nextCheckpoint.position) ~= "table" then
        clearBlip()
        return
    end
    local position = nextCheckpoint.position
    local finish = tonumber(nextCheckpoint.index) == tonumber(state.totalCheckpoints) and
        tonumber(state.lap) == tonumber(state.laps)
    local title = finish and "Finish" or ("Checkpoint %d/%d"):format(
        tonumber(nextCheckpoint.index) or 1,
        state and tonumber(state.totalCheckpoints) or 1)
    local description = state and ("Lap %d/%d · %s"):format(
        tonumber(state.lap) or 1, tonumber(state.laps) or 1,
        state.course and tostring(state.course.name) or "Race") or "Race checkpoint"
    local key = table.concat({
        tostring(state and state.heatId),
        tostring(nextCheckpoint.id),
        tostring(nextCheckpoint.index),
        tostring(state and state.totalCheckpoints),
        tostring(state and state.lap),
        tostring(state and state.laps),
        ("%.3f"):format(tonumber(position.x) or 0),
        ("%.3f"):format(tonumber(position.y) or 0),
        ("%.3f"):format(tonumber(position.z) or 0),
    }, ":")
    -- `race:state` arrives four times per second. Keep one stable custom
    -- waypoint for the whole checkpoint. `track` is still required to select
    -- it as the vanilla GPS destination; checking an already tracked id is
    -- read-only and lets the race reclaim guidance if another system replaced it.
    if nextBlip ~= nil and nextBlipKey == key then
        if gpsContextReady() and nowSeconds() >= nextBlipTrackCheckAt then
            trackNextBlip("verify")
        end
        return
    end
    local options = {
        position = position,
        sprite = Config.visuals.nextBlipSprite,
        title = title,
        description = description,
        active = true,
        visibleThroughWalls = Config.visuals.nextBlipWalls == true,
        -- A tracked static objective only changes MappinSystem's selected id.
        -- The routable form uses Cyberpunk's custom-waypoint definition, which
        -- is what wakes the native GPS pathfinder and its vehicle line effect.
        routable = true,
    }
    if nextBlip == nil then
        local id, reason = Open77.blips.create(options)
        if id == nil then
            Open77.log.error("Race checkpoint blip failed: " .. tostring(reason))
        else
            nextBlip = id
            nextBlipKey = key
            Open77.log.info(("Race checkpoint blip created: id=%s target=%s sprite=%s"):format(
                tostring(id), tostring(nextCheckpoint.index),
                tostring(Config.visuals.nextBlipSprite)))
            if gpsContextReady() then trackNextBlip("created") end
        end
    else
        local ok, reason = Open77.blips.update(nextBlip, options)
        if ok then
            nextBlipKey = key
            Open77.log.info(("Race checkpoint blip advanced: id=%s target=%s"):format(
                tostring(nextBlip), tostring(nextCheckpoint.index)))
            -- Updating title/description can replace the underlying native
            -- mappin while preserving the Open77 handle, so select it again.
            if gpsContextReady() then trackNextBlip("advanced") end
        else
            Open77.log.error("Race checkpoint blip update failed: " .. tostring(reason))
            clearBlip()
        end
    end
end

RegisterNetEvent("race:state", function(payload)
    if type(payload) ~= "table" then return end
    local previousPhase = lastPhase
    lastPhase = tostring(payload.phase or "waiting")
    state = payload
    anchorRemainingMs = math.max(0, tonumber(payload.remainingMs) or 0)
    anchorElapsedMs = math.max(0, tonumber(payload.elapsedMs) or 0)
    anchorAt = nowSeconds()
    syncAssignedVehicleLock()
    if payload.participant then
        -- Joining was initiated from a focused lobby page. Entering the grid is
        -- the hard boundary where gameplay must regain mouse/keyboard focus.
        if lastPhase == "grid" and previousPhase ~= "grid" then
            FreeroamMenu.close()
            if FreeroamMenu.hideScoreboard then FreeroamMenu.hideScoreboard() end
            setPanel(false)
        end
        teardownLobby()
    elseif editorState == nil and courseState == nil then
        buildLobby()
    end
    local nextCheckpoint = payload.nextCheckpoint
    local digest = table.concat({
        tostring(payload.phase),
        tostring(payload.playerState),
        tostring(payload.checkpointIndex),
        tostring(payload.totalCheckpoints),
        tostring(type(nextCheckpoint) == "table" and nextCheckpoint.index or "none"),
    }, ":")
    if digest ~= lastStateDigest then
        lastStateDigest = digest
        Open77.log.info(("Race state phase=%s player=%s checkpoint=%s/%s guidance=%s"):format(
            tostring(payload.phase), tostring(payload.playerState),
            tostring(payload.checkpointIndex), tostring(payload.totalCheckpoints),
            tostring(type(nextCheckpoint) == "table")))
    end
    updateBlip(payload.nextCheckpoint)
    RaceCheckpointVisual.sync(payload)
    local presentation = Config.presentation or {}
    if payload.participant and lastPhase == "grid" and previousPhase ~= "grid" then
        playRaceSfx(presentation.gridReadySfx, "race_grid_ready", 1.0)
    end
    if payload.participant and lastPhase == "countdown" and previousPhase ~= "countdown" then
        countdownHandle = playRaceSfx(
            presentation.countdownSfx, "race_countdown", 8.0)
    end
    if payload.participant and lastPhase == "countdown" then
        local second = math.max(0, math.ceil(anchorRemainingMs / 1000.0))
        if second > 0 and second ~= lastCountdownSecond then
            lastCountdownSecond = second
            playRaceSfx(presentation.countdownTickSfx,
                "race_countdown_tick", 0.75)
        end
    else
        lastCountdownSecond = nil
    end
    push()
end)

RegisterNetEvent("race:courseState", function(payload)
    buildCourse(payload)
    push()
end)

RegisterNetEvent("race:gateDebug", function(payload)
    if type(payload) ~= "table" then return end
    Open77.log.info(("Race gate debug: model=%s created=%s/%s entries=%s"):format(
        tostring(payload.model), tostring(payload.created), tostring(payload.expected),
        tostring(type(payload.entries) == "table" and #payload.entries or 0)))
    for _, entry in ipairs(type(payload.entries) == "table" and payload.entries or {}) do
        local snapshot = type(entry.snapshot) == "table" and entry.snapshot or {}
        local position = type(snapshot.position) == "table" and snapshot.position or {}
        Open77.log.info((
            "Race gate debug #%s: id=%s call=%s reason=%s snapshotModel=%s bucket=%s pos=%s,%s,%s"):format(
            tostring(entry.index), tostring(entry.id), tostring(entry.callOk),
            tostring(entry.reason), tostring(snapshot.model), tostring(snapshot.bucket),
            tostring(position.x), tostring(position.y), tostring(position.z)))
    end
end)

RegisterNetEvent("race:courseClear", function()
    teardownCourse()
    if editorState == nil then buildLobby() end
    push()
end)

RegisterNetEvent("race:lobbyState", function()
    if editorState == nil and (state == nil or not state.participant) then buildLobby() end
end)

RegisterNetEvent("race:panel", function(open)
    setPanel(open ~= false)
end)

RegisterNetEvent("race:editorState", function(payload)
    if type(payload) ~= "table" then return end
    if payload.open == false then
        editorState = nil
        teardownEditorPreview()
        setPanel(false)
    else
        local newSession = editorState == nil or
            tostring(editorState.sessionId) ~= tostring(payload.sessionId)
        editorState = payload
        FreeroamMenu.close()
        if FreeroamMenu.hideScoreboard then FreeroamMenu.hideScoreboard() end
        teardownLobby()
        refreshEditorPreview(payload.draft)
        if newSession then setPanel(false) end
    end
    push()
end)

RegisterNetEvent("race:editorRequestVehicle", function()
    if editorState == nil then return end
    TriggerServerEvent("race:editorAction", {
        action = "spawnVehicle",
        heading = headingForEditor(),
    })
end)

RegisterNetEvent("race:notice", function(payload)
    if type(payload) == "table" then
        -- Native Race notices use the same left-hand area as compact standings.
        -- Include the toast's exit transition, then restore standings automatically.
        noticeUntil = math.max(noticeUntil, nowSeconds() +
            math.max(0, tonumber(payload.durationMs) or 3500) / 1000.0 + 0.4)
        push()
    end
    if page and type(payload) == "table" then page:send("race:notice", payload) end
end)

RegisterNetEvent("race:go", function()
    -- Release before presentation work so the same client frame that receives
    -- the authoritative GO also restores native acceleration/reverse input.
    releaseAssignedVehicle("go")
    if countdownHandle ~= nil then
        stopPresentationHandle("sfx", countdownHandle)
        countdownHandle = nil
    end
    local presentation = Config.presentation or {}
    lastCountdownSecond = nil
    playRaceSfx(presentation.countdownGoSfx, "race_countdown_go", 2.0)
    playRaceSfx(presentation.goSfx, "race_go", 5.0)
    playStartVfx()
    if page then page:send("race:pulse", { kind = "go", text = "GO!" }) end
end)

RegisterNetEvent("race:checkpointAccepted", function(payload)
    local presentation = Config.presentation or {}
    playRaceSfx(presentation.checkpointSfx, "race_checkpoint", 1.5)
    if page then page:send("race:pulse", {
        kind = "checkpoint",
        text = ("CHECKPOINT %s / %s · CLEAR"):format(
            tostring(payload.completed or ""), tostring(payload.total or "")),
    }) end
end)

RegisterNetEvent("race:lap", function(payload)
    local presentation = Config.presentation or {}
    playRaceSfx(presentation.lapSfx, "race_lap", 3.0)
    if page then page:send("race:pulse", {
        kind = "lap",
        text = ("LAP %d/%d"):format(tonumber(payload.lap) or 1, tonumber(payload.laps) or 1),
    }) end
end)

RegisterNetEvent("race:finished", function(payload)
    clearBlip()
    local presentation = Config.presentation or {}
    playRaceSfx(presentation.finishSfx, "race_finish", 4.0)
    if page then page:send("race:pulse", {
        kind = "finish", text = ("FINISH · P%d"):format(tonumber(payload.place) or 1),
    }) end
end)

AddEventHandler("race:lobbySelected", function()
    TriggerServerEvent("race:openPanel")
end)

AddEventHandler("open77:scoreboardShow", function()
    if not FreeroamRaceClient.ownsHud() then return end
    boardHeld = true
    push()
end)

AddEventHandler("open77:scoreboardHide", function()
    boardHeld = false
    push()
end)

AddEventHandler("open77:chat:visibility", function(open)
    chatOpen = open == true
    push()
end)

AddEventHandler("open77:pauseKey", function()
    if panelOpen then setPanel(false) end
end)

AddEventHandler("open77:worldReady", function()
    if announced then return end
    announced = true
    CreateThread(function()
        Wait(1500)
        buildLobby()
        TriggerServerEvent("race:ready")
    end)
end)

local function handlePageAction(payload)
    if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
    if payload.action == "join" then
        TriggerServerEvent("race:join")
    elseif payload.action == "leaveQueue" then
        TriggerServerEvent("race:leave", "queue")
    elseif payload.action == "leaveRace" then
        TriggerServerEvent("race:leave", "forfeit")
    elseif payload.action == "close" then
        setPanel(false)
    elseif payload.action == "freeroam" then
        setPanel(false)
        FreeroamMenu.open()
    elseif payload.action == "editor" then
        -- Same authenticated, ACL-checked command path as /race.editor.
        TriggerServerEvent("open77:command:execute", "race.editor")
    end
end

local function handleEditorAction(payload)
    if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
    if payload.action == "captureStart" or payload.action == "captureGrid" or
        payload.action == "addCheckpoint" or payload.action == "spawnVehicle" then
        payload.heading = headingForEditor()
    end
    TriggerServerEvent("race:editorAction", payload)
end

local editorBindings = {
    { id = "race_editor_vehicle", name = "Race editor: respawn vehicle", key = "F4", action = "spawnVehicle" },
    { id = "race_editor_menu", name = "Race editor: open options", key = "F5", action = "menu" },
    { id = "race_editor_start", name = "Race editor: capture start", key = "F6", action = "captureStart" },
    { id = "race_editor_grid", name = "Race editor: add grid slot", key = "F7", action = "captureGrid" },
    { id = "race_editor_checkpoint", name = "Race editor: add checkpoint", key = "F8", action = "addCheckpoint" },
    { id = "race_editor_undo_checkpoint", name = "Race editor: undo checkpoint", key = "F9", action = "undo" },
    { id = "race_editor_undo_grid", name = "Race editor: undo grid slot", key = "F10", action = "undoGrid" },
    { id = "race_editor_save", name = "Race editor: save course", key = "F11", action = "save" },
    { id = "race_editor_exit", name = "Race editor: exit drive mode", key = "END", action = "close" },
}

local function refreshEditorKeys()
    local values = {}
    for _, binding in ipairs(editorBindings) do
        values[binding.action] = Open77.input.keyFor(binding.id) or binding.key
    end
    editorKeys = values
    push()
end

local function editorHotkey(action)
    if editorState == nil then return end
    if action == "menu" then
        setPanel(true)
        if page ~= nil then page:send("race:editorOpen", {}) end
        return
    end
    handleEditorAction({ action = action })
end

local function registerEditorBindings()
    for _, binding in ipairs(editorBindings) do
        local action = binding.action
        local ok, effectiveOrReason = RegisterKeyMapping(
            binding.id, binding.name, binding.key,
            function() editorHotkey(action) end)
        if ok then
            editorKeys[action] = effectiveOrReason
        else
            Open77.log.error(("Race editor key mapping '%s' failed: %s"):format(
                binding.id, tostring(effectiveOrReason)))
        end
    end
    refreshEditorKeys()
end

AddEventHandler("open77:keybinds:changed", refreshEditorKeys)

local function createPage()
    page = FreeroamMenu.surface()
    if page == nil then
        Open77.log.error("Freeroam's shared activity surface is unavailable")
        return
    end
    page:on("freeroam:race", function()
        setPanel(true)
        TriggerServerEvent("race:requestState")
    end)
    page:on("race:ready", function()
        pageReady = true
        Open77.log.info("Freeroam Race UI ready on the shared menu surface")
        TriggerServerEvent("race:requestState")
        push()
    end)
    page:on("race:action", handlePageAction)
    page:on("race:editor", handleEditorAction)
    page:on("race:close", function() setPanel(false) end)
    -- The surface is created by Freeroam before this submode starts. Its JS
    -- may already have emitted ready before our handlers were registered.
    -- Request an acknowledgement as well: either startup order converges.
    page:send("race:initialize", {})
    TriggerEvent("open77:chat:requestVisibility")
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    registerEditorBindings()
    createPage()
    CreateThread(function()
        while page ~= nil do
            if state ~= nil then push() end
            Wait(50)
        end
    end)
    CreateThread(function()
        Wait(500)
        if announced then return end
        local character = Open77.character.state()
        if not character or not character.attached then return end
        announced = true
        buildLobby()
        TriggerServerEvent("race:ready")
    end)
    Open77.log.info(("Race client 1.0 ready, generation %d"):format(
        Open77.resource.generation()))
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page and panelOpen then page:setFocus(false, false) end
    releaseAssignedVehicle("resource_stop")
    teardownLobby()
    teardownCourse()
    teardownEditorPreview()
    page = nil
    pageReady = false
    panelOpen = false
    boardHeld = false
    announced = false
    chatOpen = false
    noticeUntil = 0.0
    state = nil
    editorState = nil
    lastStateDigest = nil
    lastPhase = nil
    lastCountdownSecond = nil
end)
