-- One durable, personal checkpoint. Never predict acceptance from local distance:
-- the server's nextCheckpoint is the sole source for this zone and the GPS blip.
-- Native ground rings are projected every frame and occluded by world geometry;
-- the solo quest's StreetSignWidget is not a reliable multiplayer checkpoint.
RaceCheckpointVisual = {}
local handle, signature
local retryAt = 0

function RaceCheckpointVisual.clear()
    if handle ~= nil then Open77.anchors.remove(handle) end
    handle, signature = nil, nil
    retryAt = 0
end

function RaceCheckpointVisual.sync(state)
    local point = state and state.nextCheckpoint
    local phase = state and state.phase
    if RaceConfig.visuals.enabled == false or not state or state.participant ~= true or
        (phase ~= "grid" and phase ~= "countdown" and phase ~= "active") or
        type(point) ~= "table" or type(point.position) ~= "table" then
        RaceCheckpointVisual.clear()
        return
    end
    local radius = tonumber(point.radius) or RaceConfig.engine.checkpointRadius
    local finish = tonumber(point.index) == tonumber(state.totalCheckpoints) and
        tonumber(state.lap) == tonumber(state.laps)
    local position = point.position
    local key = table.concat({ tostring(state.heatId), tostring(state.lap), tostring(point.id),
        tostring(point.index), tostring(finish), tostring(radius),
        tostring(position.x), tostring(position.y), tostring(position.z) }, ":")
    if signature == key then return end
    if Open77.time.monotonic() < retryAt then return end
    local options = {
        position = position,
        maxDistance = RaceConfig.visuals.checkpointViewDistance or 180.0,
        presentation = {
            accent = finish and "#F0F3F6" or "#22D8E2",
            radius = radius,
            thickness = 5.0,
            groundOffset = 0.15,
        },
    }
    local ok, reason
    if handle ~= nil then
        ok, reason = Open77.anchors.update(handle, options)
        if not ok then
            -- A lost native handle must not retain an obsolete destination.
            Open77.anchors.remove(handle)
            handle, signature = nil, nil
        end
    else
        options.render = "ring"
        options.tag = "race.checkpoint"
        handle, reason = Open77.anchors.create(options)
        ok = handle ~= nil
    end
    if ok then
        signature = key
        Open77.log.info(("Race checkpoint zone target=%s lap=%s radius=%.1f finish=%s"):format(
            tostring(point.index), tostring(state.lap), radius, tostring(finish)))
    else
        retryAt = Open77.time.monotonic() + 1.0
        Open77.log.warn("Race checkpoint zone unavailable: " .. tostring(reason))
    end
end
