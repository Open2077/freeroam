-- Default Open77 freeroam gamemode.
--
-- All authority lives here: player spawn/respawn through the life primitives,
-- network vehicles through Open77.vehicles, commands through the authenticated
-- dispatcher. The client only announces itself and draws map blips.
--
-- Teleport note: the runtime does not expose a direct teleport for a living
-- player yet. /goto and /tpc use the documented transaction
-- kill(script) -> respawn(position), which goes through the full respawn
-- discipline (fade, streaming preload, grace). See
-- docs/research/multiplayer-death-ragdoll-revive-and-respawn.md.

local Config = FreeroamConfig

local known = {}          -- playerId -> { joinedAtMs }
local garages = {}        -- playerId -> { vehicleId... } in creation order
local vehicleOwners = {}  -- vehicleId -> playerId
local joinSpawns = {}      -- playerId -> pending | complete
local godModes = {}        -- playerId -> true while the freeroam toggle is on
local pendingWeaponMenus = {} -- requestId string -> asynchronous menu operation
local menuLastActionMs = {}   -- mutation throttle, playerId -> monotonic milliseconds
local menuLastSnapshotMs = {} -- read-only loadout refresh throttle

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function output(source, raw, success, text)
    print("[freeroam] " .. text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local function announce(target, text, color)
    TriggerClientEvent("chat:addMessage", target, {
        type = "system",
        author = "FREEROAM",
        text = text,
        color = color or { 0, 229, 255 },
    })
end

local function finiteNumber(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed or parsed == math.huge or parsed == -math.huge then
        return nil
    end
    return parsed
end

local function rememberPlayer(playerId)
    if playerId == nil or playerId <= 0 then return end
    if known[playerId] == nil then
        known[playerId] = { joinedAtMs = nowMs() }
    end
end

-- Destinations and spawn points indexed by name.
local locationsByName = {}
for _, location in ipairs(Config.teleport.locations) do
    locationsByName[string.lower(location.name)] = location
end

local spawnsByName = {}
for _, point in ipairs(Config.spawn.points) do
    spawnsByName[string.lower(point.name)] = point
end

-- The browser only sends these short keys. Exact records are resolved from the
-- shared server-owned catalog; arbitrary Items.* strings never cross into the
-- weapon API from an untrusted menu event.
local weaponsByKey = {}
for _, weapon in ipairs((Config.weapons and Config.weapons.catalog) or {}) do
    weaponsByKey[string.lower(weapon.key)] = weapon
end

local vehiclesByRecord = {}
for _, vehicle in ipairs((Config.vehicles and Config.vehicles.catalog) or {}) do
    vehiclesByRecord[vehicle.record] = vehicle
end

local function pickSpawn(reference)
    local points = Config.spawn.points
    if #points == 0 then return nil end
    if Config.spawn.selection == "first" then return points[1] end
    if Config.spawn.selection == "nearest" and reference ~= nil then
        local best, bestSquared
        for _, point in ipairs(points) do
            local dx = point.position.x - reference.x
            local dy = point.position.y - reference.y
            local dz = point.position.z - reference.z
            local squared = dx * dx + dy * dy + dz * dz
            if bestSquared == nil or squared < bestSquared then
                best, bestSquared = point, squared
            end
        end
        return best
    end
    return points[math.random(#points)]
end

-- Server teleport transaction: a living player is first killed with the marker
-- weapon "freeroam:teleport", then respawned immediately — both transitions
-- leave in the same tick, so the client only observes the fade.
local function teleportTo(playerId, position, heading)
    if not Config.teleport.enabled then return false, "teleport_disabled" end
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end
    if life.phase == "alive" or life.phase == "recovering" then
        local ok, reason = Open77.players.kill(playerId, {
            cause = "script",
            weapon = "freeroam:teleport",
        })
        if not ok then return false, reason end
    elseif life.phase ~= "dead" then
        return false, "transition_in_progress"
    end
    return Open77.players.respawn(playerId, {
        position = position,
        heading = heading or 0,
        bucket = life.bucket or 0,
        health = Config.teleport.health,
        graceMs = Config.teleport.graceMs,
    })
end

local function respawnAt(playerId, point)
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end
    if life.phase ~= "dead" then return false, "invalid_state" end
    return Open77.players.respawn(playerId, {
        position = point.position,
        heading = point.heading or 0,
        bucket = life.bucket or 0,
        health = Config.spawn.health,
        graceMs = Config.spawn.graceMs,
    })
end

-- Pristine saves are implementation details, not freeroam spawn data. Move a
-- newly attached player through the authoritative life pipeline so streaming,
-- buckets and replication all observe the same canonical position.
local function forceSpawnAt(playerId, point)
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end
    if life.phase == "alive" or life.phase == "recovering" then
        local ok, reason = Open77.players.kill(playerId, {
            cause = "script",
            weapon = "freeroam:join_spawn",
        })
        if not ok then return false, reason end
    elseif life.phase ~= "dead" then
        return false, "transition_in_progress"
    end
    return Open77.players.respawn(playerId, {
        position = point.position,
        heading = point.heading or 0,
        bucket = life.bucket or 0,
        health = Config.spawn.health,
        graceMs = Config.spawn.graceMs,
    })
end

-- ---------------------------------------------------------------------------
-- Cooperating with a resource that restores a saved position.
--
-- Freeroam is the right owner of spawn for a player arriving for the first
-- time -- that is what forceOnJoin is FOR, since the pristine saves are
-- bootstrap worlds rather than freeroam spawn data. It is the wrong owner for a
-- player who is coming back to a position somebody saved for them, and if both
-- systems place the same player the last one wins non-deterministically.
--
-- This resource cannot ask the other one, because server resources cannot call
-- each other: no exports, no cross-resource event bus, and a TriggerEvent that
-- walks only its own VM. Only the host sees both, so both facts below come from
-- the host and neither is a call into another resource.
--
--   Open77.ready.isReady(playerId)   is anybody still holding this player
--   onPlayerReady(playerId, detail)  the gate lifting, and WHY it lifted
--
-- The second is the interesting one. When the last hold is released the host
-- passes the releasing resource's own note through as `detail`, so a resource
-- that has just placed a player can say so, and this one can read it without
-- either knowing the other exists.
--
-- Both paths degrade to the previous behaviour by themselves: a server binary
-- with no readiness gate has no Open77.ready, nothing is ever deferred, and
-- every player is spawned exactly as before.
local readyDetail = {}     -- playerId -> the detail the gate opened with

local function readinessHeld(playerId)
    if Config.spawn.deferToReadinessGate == false then return false end
    if type(Open77.ready) ~= "table" or type(Open77.ready.isReady) ~= "function" then
        return false
    end
    return not Open77.ready.isReady(playerId)
end

local function placedByAnotherResource(playerId)
    local detail = readyDetail[playerId]
    if type(detail) ~= "string" then return false end
    for _, prefix in ipairs(Config.spawn.placedByDetailPrefixes or {}) do
        if #prefix > 0 and detail:sub(1, #prefix) == prefix then return true, detail end
    end
    return false
end

local function applyJoinSpawn(playerId)
    if FreeroamActivities and FreeroamActivities.ownsPlayer(playerId) then return end
    if not Config.spawn.forceOnJoin or joinSpawns[playerId] ~= nil then return end

    -- Somebody has already put this player where they belong. Checked here and
    -- not only in the onPlayerReady handler below, because the gate can open
    -- before the client announces gameplay readiness OR after it, and both
    -- orderings have to reach the same answer.
    local placed, detail = placedByAnotherResource(playerId)
    if placed then
        joinSpawns[playerId] = "deferred"
        print(string.format(
            "[freeroam] join spawn skipped for %d: already placed by another resource (%s)",
            playerId, tostring(detail)))
        return
    end

    -- Still held. Latch so a repeated gameplayReady cannot re-enter, and let
    -- the onPlayerReady handler below resume this.
    if readinessHeld(playerId) then
        joinSpawns[playerId] = "waiting"
        print(string.format("[freeroam] join spawn for %d deferred: readiness gate is closed", playerId))
        return
    end
    local point = Config.spawn.points[1]
    if point == nil then
        print(string.format("[freeroam] join spawn unavailable for %d: no spawn point", playerId))
        return
    end

    joinSpawns[playerId] = "pending"
    local startedAt = nowMs()
    local retryMs = math.max(50, tonumber(Config.spawn.joinRetryMs) or 250)
    local timeoutMs = math.max(retryMs, tonumber(Config.spawn.joinTimeoutMs) or 30000)

    local function attempt()
        if joinSpawns[playerId] ~= "pending" then return end
        if FreeroamActivities and FreeroamActivities.ownsPlayer(playerId) then
            joinSpawns[playerId] = "complete"
            return
        end
        local ok, reason = forceSpawnAt(playerId, point)
        if ok then
            joinSpawns[playerId] = "complete"
            print(string.format(
                "[freeroam] player %d spawned at %s (%.6f, %.6f, %.6f)",
                playerId, point.name, point.position.x, point.position.y, point.position.z))
            return
        end

        if (reason == "player_not_found" or reason == "transition_in_progress")
            and nowMs() - startedAt < timeoutMs then
            SetTimeout(retryMs, attempt)
            return
        end

        joinSpawns[playerId] = nil
        print(string.format("[freeroam] join spawn for %d rejected: %s", playerId, tostring(reason)))
    end

    attempt()
end

-- Garage: per-player tracking of created vehicles. Vehicles remain canonical
-- until an explicit /dv, administrative cleanup, or resource-owned removal.
local function resolveModel(value)
    if value == nil or value == "" then return Config.vehicles.defaultModel end
    local shortcut = Config.vehicles.shortcuts[string.lower(value)]
    if shortcut ~= nil then return shortcut end
    if Config.vehicles.allowCustomModels and string.match(value, "^Vehicle%.[%w_]+$") ~= nil then
        return value
    end
    return nil, "unknown_model"
end

local function isAvModel(model)
    return string.match(model, "^Vehicle%.av_") ~= nil or model == "Vehicle.max_tac_av"
end

local function spawnVehicle(playerId, modelArg)
    local model, reason = resolveModel(modelArg)
    if model == nil then return nil, reason end
    local position = Open77.players.position(playerId)
    if position == nil then return nil, "no_fresh_position" end

    local garage = garages[playerId] or {}
    garages[playerId] = garage

    local offset = Config.vehicles.spawnOffset
    -- AV records are tall aircraft whose pivot is the chassis centre, so the
    -- flat car offset (z = 0.25) buries half the hull underground. Spawn AVs
    -- with extra lift so they materialise clear of the ground and are
    -- immediately boardable.
    if isAvModel(model) then
        offset = {
            x = offset.x,
            y = offset.y,
            z = offset.z + Config.vehicles.avSpawnLift,
        }
    end
    local id, createReason = Open77.vehicles.create({
        record = model,
        position = {
            x = position.x + offset.x,
            y = position.y + offset.y,
            z = position.z + offset.z,
        },
        yaw = 0,
        bucket = position.bucket or 0,
    })
    if id == nil then return nil, createReason end
    garage[#garage + 1] = id
    vehicleOwners[id] = playerId

    local maximum = math.max(0, math.floor(tonumber(Config.vehicles.maxPerPlayer) or 0))
    while maximum > 0 and #garage > maximum do
        local oldest = table.remove(garage, 1)
        if oldest ~= nil then
            vehicleOwners[oldest] = nil
            Open77.vehicles.remove(oldest)
        end
    end
    return id, model
end

local function latestVehicle(playerId)
    local garage = garages[playerId]
    if garage == nil then return nil end
    while #garage > 0 do
        local id = garage[#garage]
        local vehicle = Open77.vehicles.get(id)
        if vehicle ~= nil then return id, vehicle end
        table.remove(garage)
        vehicleOwners[id] = nil
    end
    return nil
end

local function pushGarageState(playerId)
    local id, latest = latestVehicle(playerId)
    local garage = garages[playerId] or {}
    local state = {
        count = #garage,
        maximum = math.max(0, math.floor(tonumber(Config.vehicles.maxPerPlayer) or 0)),
    }
    if id ~= nil and latest ~= nil then
        local flags = math.floor(tonumber(latest.flags) or 0)
        local catalog = vehiclesByRecord[latest.record]
        state.latest = {
            id = id,
            record = latest.record,
            key = catalog and catalog.key or nil,
            label = catalog and catalog.label or latest.record,
            engineOn = (flags & Open77.vehicles.flags.engineOn) ~= 0,
            locked = (flags & Open77.vehicles.flags.locked) ~= 0,
            lightsOn = (flags & Open77.vehicles.flags.lightsOn) ~= 0,
        }
    end
    TriggerClientEvent("freeroam:menu:garageState", playerId, state)
end

local function pushPlayerState(playerId)
    local health = Open77.players.getHealth(playerId)
    if health == nil then
        return TriggerClientEvent("freeroam:menu:playerState", playerId, {
            available = false,
        })
    end
    TriggerClientEvent("freeroam:menu:playerState", playerId, {
        available = true,
        health = health.health,
        maximumHealth = health.maxHealth,
        armor = health.armor,
        godMode = health.godMode == true,
    })
end

local function removeVehicles(playerId, all)
    local garage = garages[playerId]
    if garage == nil or #garage == 0 then return 0 end
    local removed = 0
    repeat
        local id = table.remove(garage)
        if id ~= nil then
            vehicleOwners[id] = nil
            if Open77.vehicles.remove(id) then removed = removed + 1 end
        end
    until not all or #garage == 0
    return removed
end

AddEventHandler("onVehicleRemoved", function(id)
    id = tonumber(id)
    if id == nil then return end
    local owner = vehicleOwners[id]
    if owner == nil then return end
    vehicleOwners[id] = nil
    local garage = garages[owner]
    if garage == nil then return end
    for index = #garage, 1, -1 do
        if garage[index] == id then table.remove(garage, index) end
    end
    pushGarageState(owner)
end)

-- Automatic respawn after a real death. Gamemode teleports switch to
-- respawnpending in the same tick as their kill, so by the time this event is
-- dispatched the phase is no longer "dead" and nothing gets scheduled.
AddEventHandler("onPlayerLifeStateChanged", function(playerId, _, phase)
    if phase ~= "dead" or not Config.spawn.autoRespawn then return end
    playerId = tonumber(playerId)
    if playerId == nil or readinessHeld(playerId) then return end
    if FreeroamActivities and FreeroamActivities.ownsPlayer(playerId) then return end
    rememberPlayer(playerId)
    local life = Open77.players.getLifeState(playerId)
    if life == nil or life.phase ~= "dead" then return end
    SetTimeout(Config.spawn.respawnDelayMs, function()
        if FreeroamActivities and FreeroamActivities.ownsPlayer(playerId) then return end
        if readinessHeld(playerId) then return end
        local current = Open77.players.getLifeState(playerId)
        if current == nil or current.phase ~= "dead" then return end
        local point = pickSpawn(current.position)
        if point == nil then return end
        local ok, reason = respawnAt(playerId, point)
        if not ok then
            print(string.format("[freeroam] auto-respawn for %d rejected: %s", playerId, tostring(reason)))
        end
    end)
end)

local function gameplayReady()
    local playerId = tonumber(source)
    if playerId == nil or playerId <= 0 then return end
    if FreeroamActivities and FreeroamActivities.ownsPlayer(playerId) then return end
    print(string.format("[freeroam] gameplay ready received player=%d", playerId))
    rememberPlayer(playerId)
    applyJoinSpawn(playerId)
    if Config.welcome.enabled then
        announce(playerId, Config.welcome.text, Config.welcome.color)
    end
end

-- The protected shell emits this only after the pristine Night City world has
-- attached and its player puppet is available. A network event is intentional:
-- local Lua events are isolated per resource VM.
RegisterNetEvent("open77:session:gameplayReady", gameplayReady)

-- Compatibility for older clients which announced readiness from freeroam.
RegisterNetEvent("freeroam:ready", gameplayReady)

-- The readiness gate lifting. It is a barrier, not a trigger: it says only that
-- nobody is holding this player any more, and nothing about whether their world
-- is up -- which is why the join spawn still starts from gameplayReady and this
-- handler only ever RESUMES one that was deferred.
--
-- `detail` is recorded for every player, held or not, because applyJoinSpawn
-- may consult it either before or after this fires.
AddEventHandler("onPlayerReady", function(playerIdStr, detail)
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end
    readyDetail[playerId] = type(detail) == "string" and detail or ""
    if joinSpawns[playerId] ~= "waiting" then return end
    joinSpawns[playerId] = nil
    applyJoinSpawn(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if playerId == nil then return end
    joinSpawns[playerId] = nil
    readyDetail[playerId] = nil
    known[playerId] = nil
    godModes[playerId] = nil
    menuLastActionMs[playerId] = nil
    menuLastSnapshotMs[playerId] = nil
    for requestId, pending in pairs(pendingWeaponMenus) do
        if pending.playerId == playerId then pendingWeaponMenus[requestId] = nil end
    end
end)

-- Suggestions delivered to each player's chat when it opens.
local CHAT_SUGGESTIONS = {
    { command = "/freeroam", help = "Open the freeroam menu.", parameters = {} },
    { command = "/car", help = "Spawn a vehicle next to you.", parameters = {
        { name = "model", help = "Shortcut (hella, caliburn, kusanagi...) or a full Vehicle.* record", optional = true } } },
    { command = "/dv", help = "Delete your latest vehicle, or all of them with 'all'.", parameters = {
        { name = "all", optional = true } } },
    { command = "/goto", help = "Teleport to a named location.", parameters = {
        { name = "location", help = "See /locations." } } },
    { command = "/tpc", help = "Teleport to world coordinates.", parameters = {
        { name = "x" }, { name = "y" }, { name = "z" }, { name = "heading", optional = true } } },
    { command = "/locations", help = "List the /goto destinations.", parameters = {} },
    { command = "/spawn", help = "Return to a spawn point.", parameters = {
        { name = "name", help = "A specific point, otherwise the configured selection.", optional = true } } },
    { command = "/suicide", help = "Kill yourself (automatic respawn takes over).", parameters = {} },
    { command = "/revive", help = "Revive in place if you are dead.", parameters = {} },
    { command = "/players", help = "List the players known to the gamemode.", parameters = {} },
    { command = "/freeroam.status", help = "Gamemode status.", parameters = {} },
    { command = "/freeroam.help", help = "Freeroam gamemode help.", parameters = {} },
    { command = "/noclip", help = "[admin] Toggle noclip flight for yourself.", parameters = {
        { name = "on|off", optional = true } } },
    { command = "/fly", help = "[admin] Alias of /noclip.", parameters = {
        { name = "on|off", optional = true } } },
    { command = "/noclip.speed", help = "[admin] Set your noclip speed (Shift x4, Ctrl x0.25).", parameters = {
        { name = "m/s", help = "0.1 to 500 metres per second." } } },
    { command = "/freeroam.tp", help = "[admin] Teleport a player to a location.", parameters = {
        { name = "playerId" }, { name = "location" } } },
    { command = "/freeroam.respawn", help = "[admin] Respawn a dead player.", parameters = {
        { name = "playerId" }, { name = "point", optional = true } } },
    { command = "/freeroam.revive", help = "[admin] Revive a dead player in place.", parameters = {
        { name = "playerId" } } },
    { command = "/freeroam.cleanup", help = "[admin] Remove every gamemode vehicle.", parameters = {} },
}

RegisterNetEvent("chat:ready", function()
    rememberPlayer(source)
    TriggerClientEvent("chat:addSuggestions", source, CHAT_SUGGESTIONS)
end)

-- Menu ------------------------------------------------------------------------
--
-- /freeroam opens the WebUI menu client-side; every button press comes back as
-- the "freeroam:menu" net event and is executed by the same authority helpers
-- as the chat commands. Menu mutations are refused when the operator put the
-- player commands behind the ACL, because net events bypass the command
-- dispatcher that enforces it.

local function menuResult(playerId, ok, text)
    TriggerClientEvent("freeroam:menu:result", playerId, ok == true, text)
    -- The menu closes itself after teleport-style actions, so a failure would
    -- vanish with it; repeat failures in the chat where they stay visible.
    if not ok then
        announce(playerId, text, { 255, 76, 92 })
    end
    print(string.format("[freeroam] menu %s for %d: %s", ok and "ok" or "rejected", playerId, text))
end

local menuActions = {}

local function rememberWeaponMenu(requestId, playerId, kind, context)
    local key = tostring(requestId)
    pendingWeaponMenus[key] = {
        playerId = playerId,
        kind = kind,
        context = context or {},
    }
    SetTimeout(11500, function()
        local pending = pendingWeaponMenus[key]
        if pending == nil then return end
        pendingWeaponMenus[key] = nil
        menuResult(pending.playerId, false, "weapon request timed out")
    end)
end

local function requestWeaponSnapshot(playerId)
    if not Config.weapons.enabled or type(Open77.weapons) ~= "table" then
        return nil, "weapons_unavailable"
    end
    local requestId, reason = Open77.weapons.requestSnapshot(playerId)
    if requestId ~= nil then rememberWeaponMenu(requestId, playerId, "snapshot") end
    return requestId, reason
end

AddEventHandler("open77:weapons:completed", function(
    playerId, requestId, operation, accepted, reason, result)
    playerId = tonumber(playerId)
    local key = tostring(requestId)
    local pending = pendingWeaponMenus[key]
    if pending == nil or playerId == nil or pending.playerId ~= playerId then return end
    pendingWeaponMenus[key] = nil
    if accepted ~= true then
        return menuResult(playerId, false,
            "weapon " .. tostring(operation) .. " failed: " .. tostring(reason))
    end

    if pending.kind == "snapshot" then
        TriggerClientEvent("freeroam:menu:weaponState", playerId,
            type(result) == "table" and result or {})
        return
    end

    local context = pending.context
    if pending.kind == "equip" then
        local maximum = math.max(0,
            math.floor(tonumber(Config.weapons.maximumReserve) or 5000))
        local reserve = math.min(maximum,
            math.max(0, math.floor(tonumber(Config.weapons.defaultReserve) or 0)))
        if reserve > 0 and not context.melee then
            local ammoRequest, ammoReason = Open77.weapons.setAmmo(
                playerId, context.slot, { reserve = reserve, activate = true })
            if ammoRequest ~= nil then
                rememberWeaponMenu(ammoRequest, playerId, "equipAmmo", context)
                return menuResult(playerId, true,
                    context.label .. " equipped; loading " .. reserve .. " reserve rounds")
            end
            return menuResult(playerId, false,
                "automatic ammo refill failed: " .. tostring(ammoReason))
        end
        menuResult(playerId, true, context.label .. " equipped")
    elseif pending.kind == "equipAmmo" then
        menuResult(playerId, true, context.label .. " ready with reserve ammunition")
    elseif pending.kind == "ammo" then
        local ammo = type(result) == "table" and result.ammo or nil
        menuResult(playerId, true, string.format(
            "slot %d ammo: reserve %s, magazine %s/%s",
            context.slot, tostring(ammo and ammo.reserve or context.reserve),
            tostring(ammo and ammo.magazine or context.magazine or "kept"),
            tostring(ammo and ammo.capacity or "?")))
    elseif pending.kind == "activate" then
        menuResult(playerId, true, "slot " .. context.slot .. " activated")
    elseif pending.kind == "remove" then
        menuResult(playerId, true, "slot " .. context.slot .. " cleared")
    elseif pending.kind == "holster" then
        menuResult(playerId, true, "weapon holstered")
    end

    requestWeaponSnapshot(playerId)
end)

menuActions.car = function(playerId, payload)
    local id, detail = spawnVehicle(playerId, type(payload.model) == "string" and payload.model or nil)
    if id == nil then return false, "vehicle create rejected: " .. tostring(detail) end
    return true, string.format("vehicle %d (%s) delivered", id, detail)
end

menuActions.dv = function(playerId, payload)
    local removed = removeVehicles(playerId, payload.all == true)
    if removed == 0 then return false, "no vehicle to delete" end
    return true, string.format("%d vehicle(s) deleted", removed)
end

local function setLatestVehicleFlag(playerId, flag, enabled)
    local id, vehicle = latestVehicle(playerId)
    if id == nil then return false, "no owned vehicle" end
    local flags = tonumber(vehicle.flags) or 0
    if enabled then flags = flags | flag else flags = flags & (~flag) end
    local ok = Open77.vehicles.update(id, { flags = flags })
    if not ok then return false, "vehicle update rejected" end
    return true, string.format("vehicle %d updated", id)
end

menuActions.vehicleRepair = function(playerId)
    local id = latestVehicle(playerId)
    if id == nil then return false, "no owned vehicle" end
    if not Open77.vehicles.repair(id, "full") then return false, "vehicle repair rejected" end
    return true, string.format("vehicle %d fully repaired", id)
end

menuActions.vehicleEngine = function(playerId, payload)
    return setLatestVehicleFlag(
        playerId, Open77.vehicles.flags.engineOn, payload.enabled == true)
end

menuActions.vehicleLock = function(playerId, payload)
    return setLatestVehicleFlag(
        playerId, Open77.vehicles.flags.locked, payload.enabled == true)
end

menuActions.vehicleLights = function(playerId, payload)
    return setLatestVehicleFlag(
        playerId, Open77.vehicles.flags.lightsOn, payload.enabled == true)
end

menuActions.weaponEquip = function(playerId, payload)
    if not Config.weapons.enabled or type(Open77.weapons) ~= "table" then
        return false, "weapons unavailable"
    end
    local key = type(payload.key) == "string" and string.lower(payload.key) or ""
    local weapon = weaponsByKey[key]
    local slot = finiteNumber(payload.slot)
    if weapon == nil then return false, "unknown weapon" end
    if slot == nil or slot % 1 ~= 0 or slot < 1 or slot > 3 then return false, "invalid slot" end
    local requestId, reason = Open77.weapons.assign(
        playerId, weapon.record, slot, { active = true, addToInventory = true })
    if requestId == nil then return false, "weapon rejected: " .. tostring(reason) end
    rememberWeaponMenu(requestId, playerId, "equip", {
        slot = slot, key = weapon.key, label = weapon.label, melee = weapon.melee == true,
    })
    return true, weapon.label .. " queued for slot " .. slot
end

menuActions.weaponAmmo = function(playerId, payload)
    if not Config.weapons.enabled or type(Open77.weapons) ~= "table" then
        return false, "weapons unavailable"
    end
    local slot = finiteNumber(payload.slot)
    local reserve = finiteNumber(payload.reserve)
    local magazine = payload.magazine ~= nil and finiteNumber(payload.magazine) or nil
    local maximum = math.max(0, math.floor(tonumber(Config.weapons.maximumReserve) or 5000))
    if slot == nil or slot % 1 ~= 0 or slot < 1 or slot > 3 then return false, "invalid slot" end
    if reserve == nil or reserve % 1 ~= 0 or reserve < 0 or reserve > maximum then
        return false, "reserve must be an integer from 0 to " .. maximum
    end
    if payload.magazine ~= nil and
       (magazine == nil or magazine % 1 ~= 0 or magazine < 0 or magazine > 1000) then
        return false, "magazine must be an integer from 0 to 1000"
    end
    local amounts = { reserve = reserve, activate = true }
    if magazine ~= nil then amounts.magazine = magazine end
    local requestId, reason = Open77.weapons.setAmmo(playerId, slot, amounts)
    if requestId == nil then return false, "ammo rejected: " .. tostring(reason) end
    rememberWeaponMenu(requestId, playerId, "ammo", {
        slot = slot, reserve = reserve, magazine = magazine,
    })
    return true, "ammo update queued for slot " .. slot
end

menuActions.weaponActivate = function(playerId, payload)
    if not Config.weapons.enabled or type(Open77.weapons) ~= "table" then
        return false, "weapons unavailable"
    end
    local slot = finiteNumber(payload.slot)
    if slot == nil or slot % 1 ~= 0 or slot < 1 or slot > 3 then return false, "invalid slot" end
    local requestId, reason = Open77.weapons.setActive(playerId, slot)
    if requestId == nil then return false, "activation rejected: " .. tostring(reason) end
    rememberWeaponMenu(requestId, playerId, "activate", { slot = slot })
    return true, "activating slot " .. slot
end

menuActions.weaponRemove = function(playerId, payload)
    if not Config.weapons.enabled or type(Open77.weapons) ~= "table" then
        return false, "weapons unavailable"
    end
    local slot = finiteNumber(payload.slot)
    if slot == nil or slot % 1 ~= 0 or slot < 1 or slot > 3 then return false, "invalid slot" end
    local requestId, reason = Open77.weapons.remove(playerId, slot)
    if requestId == nil then return false, "remove rejected: " .. tostring(reason) end
    rememberWeaponMenu(requestId, playerId, "remove", { slot = slot })
    return true, "clearing slot " .. slot
end

menuActions.weaponHolster = function(playerId)
    if not Config.weapons.enabled or type(Open77.weapons) ~= "table" then
        return false, "weapons unavailable"
    end
    local requestId, reason = Open77.weapons.holster(playerId)
    if requestId == nil then return false, "holster rejected: " .. tostring(reason) end
    rememberWeaponMenu(requestId, playerId, "holster")
    return true, "holstering weapon"
end

menuActions.weaponSnapshot = function(playerId)
    local requestId, reason = requestWeaponSnapshot(playerId)
    if requestId == nil then return false, "snapshot rejected: " .. tostring(reason) end
    return true, "refreshing loadout"
end

menuActions["goto"] = function(playerId, payload)
    local location = locationsByName[string.lower(type(payload.name) == "string" and payload.name or "")]
    if location == nil then return false, "unknown location" end
    local ok, reason = teleportTo(playerId, location.position, location.heading)
    if not ok then return false, "teleport rejected: " .. tostring(reason) end
    return true, "teleporting to " .. location.label
end

menuActions.tpc = function(playerId, payload)
    local x, y, z = finiteNumber(payload.x), finiteNumber(payload.y), finiteNumber(payload.z)
    local heading = payload.heading ~= nil and finiteNumber(payload.heading) or 0
    if x == nil or y == nil or z == nil or heading == nil then return false, "invalid coordinates" end
    local ok, reason = teleportTo(playerId, { x = x, y = y, z = z }, heading)
    if not ok then return false, "teleport rejected: " .. tostring(reason) end
    return true, string.format("teleporting to %.1f, %.1f, %.1f", x, y, z)
end

menuActions.spawn = function(playerId, payload)
    local point
    if type(payload.name) == "string" and payload.name ~= "" then
        point = spawnsByName[string.lower(payload.name)]
        if point == nil then return false, "unknown spawn point" end
    else
        point = pickSpawn(Open77.players.position(playerId))
        if point == nil then return false, "no spawn point configured" end
    end
    local ok, reason = teleportTo(playerId, point.position, point.heading)
    if not ok then return false, "teleport rejected: " .. tostring(reason) end
    return true, "returning to spawn " .. (point.label or point.name)
end

menuActions.suicide = function(playerId)
    local ok, reason = Open77.players.kill(playerId, { cause = "script", weapon = "freeroam:suicide" })
    if not ok then return false, "rejected: " .. tostring(reason) end
    return true, "see you in a moment"
end

menuActions.revive = function(playerId)
    local ok, reason = Open77.players.revive(playerId, {
        health = Config.spawn.health,
        graceMs = Config.spawn.graceMs,
    })
    if not ok then return false, "rejected: " .. tostring(reason) end
    return true, "revive in progress"
end

menuActions.restore = function(playerId)
    if not Config.player.allowRestore then return false, "restore disabled" end
    local health = Open77.players.getHealth(playerId)
    if health == nil then return false, "health state unavailable" end
    local ok, reason = Open77.players.setHealth(playerId, health.maxHealth)
    if not ok then return false, "health restore rejected: " .. tostring(reason) end
    local armor = math.max(0, tonumber(Config.player.armorOnRestore) or 0)
    local armorOk, armorReason = Open77.players.setArmor(playerId, armor)
    if not armorOk then return false, "armor restore rejected: " .. tostring(armorReason) end
    return true, string.format("health restored and armor set to %.0f", armor)
end

menuActions.godMode = function(playerId, payload)
    if not Config.player.allowGodMode then return false, "god mode disabled" end
    local enabled = payload.enabled == true
    local ok, reason = Open77.players.setGodMode(playerId, enabled)
    if not ok then return false, "god mode rejected: " .. tostring(reason) end
    godModes[playerId] = enabled or nil
    return true, enabled and "god mode enabled" or "god mode disabled"
end

RegisterNetEvent("freeroam:menu", function(action, payload)
    rememberPlayer(source)
    if FreeroamActivities and FreeroamActivities.ownsPlayer(source) then
        return menuResult(source, false, "Leave your activity before using sandbox tools.")
    end
    if Config.restrictPlayerCommands then
        return menuResult(source, false, "menu actions are disabled; use the ACL-checked commands")
    end
    local handler = type(action) == "string" and menuActions[action] or nil
    if handler == nil then return menuResult(source, false, "unknown menu action") end
    local at = nowMs()
    -- Refreshing the loadout must not consume the mutation throttle: entering
    -- the Weapons tab requests a snapshot, and a fast click on a catalog card
    -- immediately afterwards should still equip it. Snapshot spam is bounded
    -- independently.
    local throttle = action == "weaponSnapshot" and menuLastSnapshotMs or menuLastActionMs
    if throttle[source] ~= nil and at - throttle[source] < 250 then
        return menuResult(source, false, "slow down")
    end
    throttle[source] = at
    local ok, text = handler(source, type(payload) == "table" and payload or {})
    menuResult(source, ok, text)
    if action == "car" or action == "dv" or string.match(action, "^vehicle") then
        pushGarageState(source)
    elseif action == "restore" or action == "godMode" or action == "revive" then
        pushPlayerState(source)
    end
end)

-- Player commands ------------------------------------------------------------

local restricted = Config.restrictPlayerCommands == true

local function requirePlayer(source, raw)
    if source == nil or source <= 0 then
        output(source, raw, false, "this command targets the sending player; unavailable from the console")
        return false
    end
    rememberPlayer(source)
    if raw ~= "freeroam" and FreeroamActivities and FreeroamActivities.ownsPlayer(source) then
        output(source, raw, false, "Leave your activity before using sandbox tools.")
        return false
    end
    return true
end

RegisterCommand("freeroam", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n ~= 0 then return output(source, raw, false, "usage: freeroam") end
    requestWeaponSnapshot(source)
    pushGarageState(source)
    pushPlayerState(source)
    TriggerClientEvent("freeroam:menu:open", source)
    output(source, raw, true, "opening the freeroam menu")
end, false)

RegisterCommand("car", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n > 1 then return output(source, raw, false, "usage: car [model]") end
    local id, detail = spawnVehicle(source, args[1])
    if id == nil then
        if detail == "unknown_model" then
            local names = {}
            for name in pairs(Config.vehicles.shortcuts) do names[#names + 1] = name end
            table.sort(names)
            return output(source, raw, false,
                "unknown model; shortcuts: " .. table.concat(names, ", "))
        end
        return output(source, raw, false, "vehicle create rejected: " .. tostring(detail))
    end
    output(source, raw, true, string.format("vehicle %d (%s) delivered", id, detail))
end, restricted)

RegisterCommand("dv", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n > 1 or (args[1] ~= nil and args[1] ~= "all") then
        return output(source, raw, false, "usage: dv [all]")
    end
    local removed = removeVehicles(source, args[1] == "all")
    if removed == 0 then return output(source, raw, false, "no vehicle to delete") end
    output(source, raw, true, string.format("%d vehicle(s) deleted", removed))
end, restricted)

RegisterCommand("goto", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n ~= 1 then return output(source, raw, false, "usage: goto <location> — see /locations") end
    local location = locationsByName[string.lower(args[1])]
    if location == nil then return output(source, raw, false, "unknown location — see /locations") end
    local ok, reason = teleportTo(source, location.position, location.heading)
    if not ok then return output(source, raw, false, "teleport rejected: " .. tostring(reason)) end
    output(source, raw, true, "teleporting to " .. location.label)
end, restricted)

RegisterCommand("tpc", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n < 3 or args.n > 4 then return output(source, raw, false, "usage: tpc <x> <y> <z> [heading]") end
    local x, y, z = finiteNumber(args[1]), finiteNumber(args[2]), finiteNumber(args[3])
    local heading = args[4] ~= nil and finiteNumber(args[4]) or 0
    if x == nil or y == nil or z == nil or heading == nil then
        return output(source, raw, false, "invalid coordinates")
    end
    local ok, reason = teleportTo(source, { x = x, y = y, z = z }, heading)
    if not ok then return output(source, raw, false, "teleport rejected: " .. tostring(reason)) end
    output(source, raw, true, string.format("teleporting to %.1f, %.1f, %.1f", x, y, z))
end, restricted)

RegisterCommand("locations", function(source, _, raw)
    rememberPlayer(source)
    output(source, raw, true, string.format("destinations (%d):", #Config.teleport.locations))
    for _, location in ipairs(Config.teleport.locations) do
        output(source, raw, true, string.format("  %s — %s (%.0f, %.0f, %.0f)",
            location.name, location.label,
            location.position.x, location.position.y, location.position.z))
    end
end, false)

RegisterCommand("spawn", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n > 1 then return output(source, raw, false, "usage: spawn [name]") end
    local point
    if args[1] ~= nil then
        point = spawnsByName[string.lower(args[1])]
        if point == nil then return output(source, raw, false, "unknown spawn point") end
    else
        local position = Open77.players.position(source)
        point = pickSpawn(position)
        if point == nil then return output(source, raw, false, "no spawn point configured") end
    end
    local ok, reason = teleportTo(source, point.position, point.heading)
    if not ok then return output(source, raw, false, "teleport rejected: " .. tostring(reason)) end
    output(source, raw, true, "returning to spawn " .. (point.label or point.name))
end, restricted)

RegisterCommand("suicide", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n ~= 0 then return output(source, raw, false, "usage: suicide") end
    local ok, reason = Open77.players.kill(source, { cause = "script", weapon = "freeroam:suicide" })
    if not ok then return output(source, raw, false, "rejected: " .. tostring(reason)) end
    output(source, raw, true, "see you in a moment")
end, restricted)

RegisterCommand("revive", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    if args.n ~= 0 then return output(source, raw, false, "usage: revive") end
    local ok, reason = Open77.players.revive(source, {
        health = Config.spawn.health,
        graceMs = Config.spawn.graceMs,
    })
    if not ok then return output(source, raw, false, "rejected: " .. tostring(reason)) end
    output(source, raw, true, "revive in progress")
end, restricted)

RegisterCommand("players", function(source, _, raw)
    rememberPlayer(source)
    local lines, count = {}, 0
    for playerId in pairs(known) do
        local name = Open77.players.name(playerId)
        if name == nil then
            known[playerId] = nil
        else
            count = count + 1
            local life = Open77.players.getLifeState(playerId)
            lines[#lines + 1] = string.format("  %d — %s (%s)",
                playerId, name, life ~= nil and life.phase or "?")
        end
    end
    output(source, raw, true, string.format("known players (%d):", count))
    for _, line in ipairs(lines) do output(source, raw, true, line) end
end, false)

RegisterCommand("freeroam.status", function(source, _, raw)
    rememberPlayer(source)
    local vehicles, players = 0, 0
    for _, garage in pairs(garages) do vehicles = vehicles + #garage end
    for _ in pairs(known) do players = players + 1 end
    output(source, raw, true, string.format(
        "freeroam: players=%d vehicles=%d spawns=%d destinations=%d autoRespawn=%s teleport=%s",
        players, vehicles, #Config.spawn.points, #Config.teleport.locations,
        tostring(Config.spawn.autoRespawn), tostring(Config.teleport.enabled)))
end, false)

RegisterCommand("freeroam.help", function(source, _, raw)
    rememberPlayer(source)
    output(source, raw, true, "freeroam — player commands:")
    output(source, raw, true, "  /car [model], /dv [all], /goto <location>, /tpc <x y z> [heading]")
    output(source, raw, true, "  /locations, /spawn [name], /suicide, /revive, /players")
    output(source, raw, true, "  admin: /freeroam.tp, /freeroam.respawn, /freeroam.revive, /freeroam.cleanup")
end, false)

-- Admin commands (command.freeroam.* ACL) ------------------------------------

-- Noclip is a client capability, so authority works by delegation: the ACL
-- decides here, then the trusted client resource is told to flip the switch
-- through its `player.travel` permission. The local lab commands (noclip,
-- fly, tp) are refused by the client while a session is active, so this is
-- the only multiplayer path.
local noclipEnabled = {}

local function setNoclip(source, args, raw, commandName)
    if not requirePlayer(source, raw) then return end
    if args.n > 1 or (args[1] ~= nil and args[1] ~= "on" and args[1] ~= "off") then
        return output(source, raw, false, "usage: " .. commandName .. " [on|off]")
    end
    local enable
    if args[1] == "on" then enable = true
    elseif args[1] == "off" then enable = false
    else enable = noclipEnabled[source] ~= true end
    noclipEnabled[source] = enable or nil
    TriggerClientEvent("freeroam:travel", source, "noclip", enable)
    output(source, raw, true, enable and "noclip enabled" or "noclip disabled")
end

RegisterCommand("noclip", function(source, args, raw)
    setNoclip(source, args, raw, "noclip")
end, true)

RegisterCommand("fly", function(source, args, raw)
    setNoclip(source, args, raw, "fly")
end, true)

RegisterCommand("noclip.speed", function(source, args, raw)
    if not requirePlayer(source, raw) then return end
    local speed = args.n == 1 and finiteNumber(args[1]) or nil
    if speed == nil or speed < 0.1 or speed > 500 then
        return output(source, raw, false, "usage: noclip.speed <0.1..500 m/s>")
    end
    TriggerClientEvent("freeroam:travel", source, "noclipSpeed", speed)
    output(source, raw, true, string.format("noclip speed set to %.1f m/s", speed))
end, true)

RegisterCommand("freeroam.tp", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: freeroam.tp <playerId> <location>") end
    local playerId = tonumber(args[1])
    local location = locationsByName[string.lower(args[2] or "")]
    if playerId == nil then return output(source, raw, false, "invalid playerId") end
    if location == nil then return output(source, raw, false, "unknown location — see /locations") end
    local ok, reason = teleportTo(playerId, location.position, location.heading)
    if not ok then return output(source, raw, false, "teleport rejected: " .. tostring(reason)) end
    announce(playerId, "An administrator teleported you to " .. location.label .. ".")
    output(source, raw, true, string.format("player %d teleported to %s", playerId, location.label))
end, true)

RegisterCommand("freeroam.respawn", function(source, args, raw)
    if args.n < 1 or args.n > 2 then return output(source, raw, false, "usage: freeroam.respawn <playerId> [point]") end
    local playerId = tonumber(args[1])
    if playerId == nil then return output(source, raw, false, "invalid playerId") end
    local point
    if args[2] ~= nil then
        point = spawnsByName[string.lower(args[2])]
        if point == nil then return output(source, raw, false, "unknown spawn point") end
    else
        local life = Open77.players.getLifeState(playerId)
        point = pickSpawn(life ~= nil and life.position or nil)
        if point == nil then return output(source, raw, false, "no spawn point configured") end
    end
    local ok, reason = respawnAt(playerId, point)
    if not ok then return output(source, raw, false, "respawn rejected: " .. tostring(reason)) end
    output(source, raw, true, string.format("player %d respawned at %s", playerId, point.name))
end, true)

RegisterCommand("freeroam.revive", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: freeroam.revive <playerId>") end
    local playerId = tonumber(args[1])
    if playerId == nil then return output(source, raw, false, "invalid playerId") end
    local ok, reason = Open77.players.revive(playerId, {
        health = Config.spawn.health,
        graceMs = Config.spawn.graceMs,
    })
    if not ok then return output(source, raw, false, "rejected: " .. tostring(reason)) end
    output(source, raw, true, string.format("player %d revived in place", playerId))
end, true)

RegisterCommand("freeroam.cleanup", function(source, args, raw)
    if args.n ~= 0 then return output(source, raw, false, "usage: freeroam.cleanup") end
    local removed = 0
    for playerId in pairs(garages) do
        removed = removed + removeVehicles(playerId, true)
    end
    output(source, raw, true, string.format("%d gamemode vehicle(s) removed", removed))
end, true)

CreateThread(function()
    -- Same lazy seed as open77_weather: the first scheduler resume supplies a
    -- process-specific monotonic clock.
    math.randomseed(math.floor(Open77.time.monotonic() * 1000000) % 2147483647)
end)

print(string.format(
    "[freeroam] gamemode ready — %d spawns, %d destinations, %d vehicles, %d weapons; /freeroam.help",
    #Config.spawn.points, #Config.teleport.locations,
    #Config.vehicles.catalog, #(Config.weapons.catalog or {})))

-- ---------------------------------------------------------------------------
-- Tab scoreboard roster. The client used to list only the players it had a
-- streamed proxy for (the nameplate snapshot: nearby players), so the board
-- looked empty on a busy server. The host knows everyone: its roster is pushed
-- to every client when a player is ready, when one leaves, on request from a
-- client that (re)started the resource, and on a slow tick so a display name
-- changed through the identity flow catches up. Rows carry only the id and
-- the name; the client adds a live distance for the players it can see.
-- ---------------------------------------------------------------------------
local function rosterPayload()
    local ids = {}
    if type(Open77.players) == "table" and type(Open77.players.all) == "function" then
        ids = Open77.players.all() or {}
    elseif type(GetPlayers) == "function" then
        ids = GetPlayers() or {}
    end
    local players = {}
    for _, raw in ipairs(ids) do
        local id = tonumber(raw)
        if id ~= nil and id > 0 then
            local name = nil
            if type(Open77.players) == "table" and type(Open77.players.name) == "function" then
                name = Open77.players.name(id)
            end
            players[#players + 1] = { id = id, name = tostring(name or ("Player " .. tostring(id))) }
        end
    end
    table.sort(players, function(a, b) return a.id < b.id end)
    return { players = players, count = #players }
end

local rosterSignature = ""
local function broadcastRoster(force)
    local payload = rosterPayload()
    local parts = {}
    for _, player in ipairs(payload.players) do
        parts[#parts + 1] = tostring(player.id) .. "=" .. player.name
    end
    local signature = table.concat(parts, "|")
    if not force and signature == rosterSignature then return end
    rosterSignature = signature
    TriggerClientEvent("freeroam:roster", -1, payload)
end

AddEventHandler("onPlayerReady", function()
    -- Names are final once the player is ready; a fresh join changes the roster.
    broadcastRoster(true)
end)

AddEventHandler("onPlayerDisconnected", function()
    -- The host drops the player from `all` before this fires, so the payload is
    -- already without them; force the push so late-stage name equality cannot
    -- suppress it.
    broadcastRoster(true)
end)

RegisterNetEvent("freeroam:roster:request", function()
    local playerId = tonumber(source)
    if playerId == nil or playerId <= 0 then return end
    TriggerClientEvent("freeroam:roster", playerId, rosterPayload())
end)

CreateThread(function()
    while true do
        Wait(5000)
        broadcastRoster(false)
    end
end)
