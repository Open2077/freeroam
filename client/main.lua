-- Freeroam client: presence announce, map blips and the /freeroam menu page.
-- No authority logic lives here — spawns, respawns, vehicles and teleports are
-- decided by server/main.lua; the menu only forwards button presses to it.

local Config = FreeroamConfig

local blipsCreated = false
local menu
local menuOpen = false
local hud
local hudReady = false
local hudClaimsActive = false
local lastHudClaimAttemptAt = -1000

-- The freeroam HUD replaces every supported vanilla gameplay readout except
-- the map cluster.  The minimap, compass and clock deliberately remain native:
-- unlike the other widgets they own the GPS route and in-world mappin bridge.
local hiddenHudComponents = { "health", "stamina", "weapon", "speedometer" }
local hiddenHudClaims = {}

local hudView = {
    ready = false,
    armor = 0,
    health = { value = 0, maximum = 100 },
    stamina = { value = 0, maximum = 100 },
    weapon = { equipped = false },
    vehicle = { active = false },
}

local weaponRequests = {}
local lastWeaponRequestAt = 0

local weaponCatalog = {}
for _, item in ipairs((Config.weapons and Config.weapons.catalog) or {}) do
    if item.record then weaponCatalog[tostring(item.record)] = item end
end

local vehicleCatalog = {}
for _, item in ipairs((Config.vehicles and Config.vehicles.catalog) or {}) do
    if item.record then vehicleCatalog[tostring(item.record)] = item end
end

local function number(value, fallback)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then return fallback or 0 end
    return parsed
end

local function truthy(value)
    return value == true or tostring(value) == "true" or tostring(value) == "1"
end

local function nowMs()
    if Open77.time and Open77.time.monotonic then
        return number(Open77.time.monotonic(), 0) * 1000
    end
    return 0
end

local function recordLabel(record, fallback)
    local text = tostring(record or "")
    if text == "" then return fallback end
    text = text:gsub("^[^.]+%.", ""):gsub("^Preset_", ""):gsub("_player$", "")
        :gsub("_", " ")
    return text
end

local function pushHud()
    hudView.hintsVisible = not menuOpen
        and not (FreeroamRaceClient and FreeroamRaceClient.ownsHud())
        and not (FreeroamPvpClient and FreeroamPvpClient.hasActivity())
    if hud and hudReady then hud:send("freeroam:hud", hudView) end
end

local function setVanillaHudHidden(hidden)
    if type(Open77.hud) ~= "table" or type(Open77.hud.setVisible) ~= "function" then
        print("[freeroam] vanilla HUD API unavailable; stock readouts left visible")
        return false
    end

    local allAccepted = true
    for _, component in ipairs(hiddenHudComponents) do
        if hidden or hiddenHudClaims[component] then
            local ok, accepted, result = pcall(Open77.hud.setVisible, component, not hidden)
            if ok and accepted then
                hiddenHudClaims[component] = hidden or nil
            else
                allAccepted = false
                print(string.format("[freeroam] HUD %s %s failed: %s", component,
                    hidden and "hide" or "restore", tostring(ok and result or accepted)))
            end
        end
    end
    hudClaimsActive = hidden and allAccepted or false
    return allAccepted
end

local function activateCustomHudIfReady()
    if not hudReady or not hudView.ready or hudClaimsActive then return end
    local at = nowMs()
    if at - lastHudClaimAttemptAt < 1000 then return end
    lastHudClaimAttemptAt = at
    if setVanillaHudHidden(true) then
        print("[freeroam] design-system HUD active; vanilla combat readouts hidden")
    end
end

local function sampleStats()
    if type(Open77.stats) ~= "table" or type(Open77.stats.get) ~= "function" then return end
    local ok, state = pcall(Open77.stats.get)
    if not ok or type(state) ~= "table" then return end
    local health = type(state.health) == "table" and state.health or {}
    local stamina = type(state.stamina) == "table" and state.stamina or {}
    local maxHealth = math.max(1, number(health.maximum or health.max, 100))
    local maxStamina = math.max(1, number(stamina.maximum or stamina.max, 100))
    hudView.health = {
        value = math.max(0, number(health.value or health.current, 0)),
        maximum = maxHealth,
    }
    hudView.stamina = {
        value = math.max(0, number(stamina.value or stamina.current, 0)),
        maximum = maxStamina,
    }
    hudView.armor = math.max(0, number(state.armor, 0))
    hudView.ready = true
end

local function sampleVehicle()
    if type(Open77.vehicles) ~= "table"
        or type(Open77.vehicles.getPlayerSeat) ~= "function"
        or type(Open77.vehicles.get) ~= "function" then
        hudView.vehicle = { active = false }
        return
    end

    local seatOk, seat = pcall(Open77.vehicles.getPlayerSeat)
    if not seatOk or type(seat) ~= "table" or seat.vehicleId == nil then
        hudView.vehicle = { active = false }
        return
    end
    local vehicleOk, vehicle = pcall(Open77.vehicles.get, seat.vehicleId)
    if not vehicleOk or type(vehicle) ~= "table" then
        hudView.vehicle = { active = false }
        return
    end

    local record = tostring(vehicle.record or "")
    local configured = vehicleCatalog[record]
    local gear = math.floor(number(vehicle.gear, 0))
    local reversing = vehicle.reversing == true or gear < 0
    hudView.vehicle = {
        active = true,
        id = seat.vehicleId,
        record = record,
        label = configured and configured.label or recordLabel(record, "VEHICLE"),
        speedKph = math.abs(number(vehicle.speed, 0)) * 3.6,
        rpm = math.max(0, number(vehicle.rpm, 0)),
        rpmMax = math.max(1, number(vehicle.rpmMax, 1)),
        gearLabel = reversing and "R" or (gear == 0 and "N" or tostring(gear)),
        health = math.max(0, math.min(1, number(vehicle.health, 1))),
        onGround = vehicle.onGround ~= false,
    }
end

local function requestWeaponSnapshot()
    if type(Open77.weapons) ~= "table" or type(Open77.weapons.snapshot) ~= "function" then return end
    local at = nowMs()
    if at - lastWeaponRequestAt < 180 then return end
    -- Do not fill the shared script bridge with HUD reads while streaming
    -- stalls the previous read. Equipment mutations use that same queue.
    for id, pending in pairs(weaponRequests) do
        if at - pending.at <= 5000 then return end
        weaponRequests[id] = nil
    end
    lastWeaponRequestAt = at
    local ok, requestId = pcall(Open77.weapons.snapshot)
    if ok and requestId ~= nil then
        weaponRequests[tostring(requestId)] = { at = at, sawActive = false }
    end
    for id, pending in pairs(weaponRequests) do
        if at - pending.at > 5000 then weaponRequests[id] = nil end
    end
end

AddEventHandler("open77:weapons:state", function(requestId, slot, record, tweakDbId,
        active, drawn, _locked, _ammoRecord, _ammoTweakDbId, _ammoTotal, ammoReserve,
        magazine, capacity)
    local pending = weaponRequests[tostring(requestId)]
    if pending == nil or not truthy(active) then return end
    pending.sawActive = true
    local recordName = tostring(record or "")
    local configured = weaponCatalog[recordName]
    local mag = math.floor(number(magazine, -1))
    local cap = math.floor(number(capacity, -1))
    local reserve = math.floor(number(ammoReserve, -1))
    hudView.weapon = {
        equipped = recordName ~= "" or tostring(tweakDbId or "") ~= "",
        drawn = truthy(drawn),
        slot = math.max(1, math.floor(number(slot, 1))),
        record = recordName,
        label = configured and configured.label or recordLabel(recordName, "WEAPON"),
        category = configured and configured.category or "WEAPON",
        ammoKnown = mag >= 0 and cap >= 0,
        magazine = math.max(0, mag),
        capacity = math.max(0, cap),
        reserve = math.max(0, reserve),
    }
end)

AddEventHandler("open77:weapons:completed", function(requestId, operation, accepted)
    local id = tostring(requestId)
    local pending = weaponRequests[id]
    if pending == nil then return end
    if tostring(operation) == "snapshot" and truthy(accepted) and not pending.sawActive then
        hudView.weapon = { equipped = false }
    end
    weaponRequests[id] = nil
end)

AddEventHandler("open77:playerStatsChanged", function()
    sampleStats()
    activateCustomHudIfReady()
    pushHud()
end)

-- Menu state pushed to the page. Built once from the shared config: the page
-- renders whatever it receives, so config edits reach the UI on reload.
local function menuState()
    return {
        locations = Config.teleport.locations,
        spawns = Config.spawn.points,
        vehicles = {
            catalog = Config.vehicles.catalog,
            allowCustomModels = Config.vehicles.allowCustomModels == true,
            maxPerPlayer = Config.vehicles.maxPerPlayer,
            defaultModel = Config.vehicles.defaultModel,
        },
        weapons = {
            enabled = Config.weapons.enabled == true,
            catalog = Config.weapons.catalog,
            defaultReserve = Config.weapons.defaultReserve,
            maximumReserve = Config.weapons.maximumReserve,
        },
        player = {
            allowRestore = Config.player.allowRestore == true,
            allowGodMode = Config.player.allowGodMode == true,
        },
    }
end

-- The surface itself stays permanently visible: the page body is fully
-- transparent until the JS applies its "open" class, so DOM state is the only
-- visibility authority. This deliberately avoids the surface hide->show path,
-- which stopped painting on the current client build (surfaces created hidden
-- never upload a frame once shown; always-visible surfaces are unaffected).
local function setMenuOpen(value)
    if value and FreeroamRaceClient then FreeroamRaceClient.close() end
    if not menu then
        print("[freeroam] menu page unavailable; /freeroam cannot open")
        return
    end
    if menuOpen == value then return end
    menuOpen = value
    pushHud()
    if value then
        menu:send("freeroam:state", menuState())
        local focused, focusReason = menu:setFocus(true, true)
        menu:send("freeroam:open", {})
        print(string.format("[freeroam] menu open focus=%s(%s)",
            tostring(focused), tostring(focusReason)))
    else
        menu:send("freeroam:closed", {})
        menu:setFocus(false, false)
        print("[freeroam] menu closed")
    end
end

-- The activity and sandbox views share one WebUI surface and one focus owner.
FreeroamMenu = {
    surface = function() return menu end,
    close = function() setMenuOpen(false) end,
    open = function() setMenuOpen(true) end,
}

local function createBlips()
    if blipsCreated or not Config.blips.enabled then return end

    local created = 0
    for _, location in ipairs(Config.teleport.locations) do
        local id = Open77.blips.create({
            position = location.position,
            sprite = Config.blips.locationSprite,
            title = location.label,
            description = ("Freeroam destination. /goto %s"):format(location.name),
        })
        if id ~= nil then created = created + 1 end
    end

    if Config.blips.showSpawns then
        for _, point in ipairs(Config.spawn.points) do
            local id = Open77.blips.create({
                position = point.position,
                sprite = Config.blips.spawnSprite,
                title = point.label or point.name,
                description = ("Freeroam spawn point. /spawn %s"):format(point.name),
            })
            if id ~= nil then created = created + 1 end
        end
    end

    -- A global failure (world not attached yet) is retried on the next signal.
    if created > 0 then
        blipsCreated = true
        print(string.format("[freeroam] %d blip(s) created", created))
    end
end

AddEventHandler("open77:worldReady", function()
    createBlips()
    activateCustomHudIfReady()
end)

-- The server answers /freeroam with this event.
RegisterNetEvent("freeroam:menu:open", function()
    print("[freeroam] freeroam:menu:open received")
    setMenuOpen(true)
end)

-- Local diagnostic hook: `resource emit freeroam:menu:toggle` in the developer
-- console toggles the menu without any server round-trip, which separates a
-- network-delivery failure from a surface/page failure.
AddEventHandler("freeroam:menu:toggle", function()
    print("[freeroam] local menu toggle")
    setMenuOpen(not menuOpen)
end)

-- Escape is owned by the plugin while the pause menu is armed: the key is
-- swallowed in the window procedure and never reaches the focused page, so
-- the page-side Escape handler cannot fire in a session. The plugin raises
-- open77:pauseKey instead; closing here keeps this menu from being left open
-- and unfocused (cursor gone) underneath the pause panel.
AddEventHandler("open77:pauseKey", function()
    if menuOpen then setMenuOpen(false) end
end)

-- Server-side outcome of a menu action, surfaced as a toast in the page.
RegisterNetEvent("freeroam:menu:result", function(ok, text)
    if menu then
        menu:send("freeroam:result", { ok = ok == true, text = tostring(text or "") })
    end
end)

RegisterNetEvent("freeroam:menu:weaponState", function(slots)
    if menu then
        menu:send("freeroam:weapons", { slots = type(slots) == "table" and slots or {} })
    end
end)

RegisterNetEvent("freeroam:menu:garageState", function(state)
    if menu then
        menu:send("freeroam:garage", type(state) == "table" and state or {})
    end
end)

RegisterNetEvent("freeroam:menu:playerState", function(state)
    if menu then
        menu:send("freeroam:player", type(state) == "table" and state or {})
    end
end)

-- ACL-authorised travel orders. The native lab commands (noclip, tp) are
-- refused while a session is active, so this server-driven path — backed by
-- the `player.travel` permission — is the only way to reach them in
-- multiplayer. The server never trusts the client: it only ever sends this
-- after the command dispatcher accepted the caller's ACL.
RegisterNetEvent("freeroam:travel", function(action, value)
    -- A client older than the travel binding has no Open77.travel table at
    -- all; a plain error here would kill the handler quota for nothing.
    if type(Open77.travel) ~= "table" then
        print("[freeroam] travel API unavailable on this client build")
        return
    end
    if action == "noclip" then
        local ok, reason = Open77.travel.setNoclip(value == true)
        if not ok then
            print("[freeroam] noclip request failed: " .. tostring(reason))
        end
    elseif action == "noclipSpeed" then
        local ok, reason = Open77.travel.setNoclipSpeed(tonumber(value) or 0)
        if not ok then
            print("[freeroam] noclip speed request failed: " .. tostring(reason))
        end
    end
end)

-- Tab scoreboard. The plugin forwards the Tab key as open77:scoreboardShow /
-- open77:scoreboardHide while a Open77 session is active (single-player Tab is
-- untouched). Rows come from the SERVER roster (freeroam:roster): every player
-- on the server is listed, whether or not the local client streams them. The
-- nameplate snapshot only contributes a live distance for the players that are
-- streamed nearby; the others show as far. The local player is listed too and
-- marked, so the count is the server's player count.
local scoreboard
local scoreboardOpen = false
local roster = {}
local rosterReceived = false

local function requestRoster()
    if type(TriggerServerEvent) == "function" then
        pcall(TriggerServerEvent, "freeroam:roster:request")
    end
end

local function localPlayerId()
    if type(Open77.network) ~= "table" or type(Open77.network.status) ~= "function" then return nil end
    local ok, status = pcall(Open77.network.status)
    if ok and type(status) == "table" then return tonumber(status.playerId) end
    return nil
end

local function streamedDistances()
    local distances = {}
    if type(Open77.nameplates) ~= "table" or type(Open77.nameplates.snapshot) ~= "function" then
        return distances
    end
    local ok, players = pcall(Open77.nameplates.snapshot)
    if not ok or type(players) ~= "table" then return distances end
    for _, player in ipairs(players) do
        local id = tonumber(player.id)
        if id ~= nil then distances[id] = tonumber(player.distance) end
    end
    return distances
end

local function scoreboardRows()
    local distances = streamedDistances()
    local selfId = localPlayerId()
    local rows = {}
    for _, player in ipairs(roster) do
        local id = tonumber(player.id)
        if id ~= nil then
            local isSelf = selfId ~= nil and id == selfId
            local distance = (not isSelf) and distances[id] or nil
            rows[#rows + 1] = {
                id = tostring(id),
                label = tostring(player.name or ("Player " .. tostring(id))),
                distance = distance,
                streamed = distance ~= nil,
                self = isSelf,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.self ~= b.self then return a.self end
        if a.streamed ~= b.streamed then return a.streamed end
        if a.streamed and a.distance ~= b.distance then return a.distance < b.distance end
        return string.lower(a.label) < string.lower(b.label)
    end)
    return rows
end

local function pushScoreboard()
    if scoreboard then
        scoreboard:send("scoreboard:data", { players = scoreboardRows(), rosterKnown = rosterReceived })
    end
end

local function setScoreboardOpen(value)
    if value and FreeroamPvpClient and FreeroamPvpClient.ownsHud() then return end
    if value and FreeroamRaceClient and FreeroamRaceClient.ownsHud() then return end
    if not scoreboard or scoreboardOpen == value then return end
    scoreboardOpen = value
    if value then
        if not rosterReceived then requestRoster() end
        pushScoreboard()
        scoreboard:send("scoreboard:open", {})
    else
        scoreboard:send("scoreboard:closed", {})
    end
end

RegisterNetEvent("freeroam:roster", function(payload)
    if type(payload) ~= "table" or type(payload.players) ~= "table" then return end
    roster = payload.players
    rosterReceived = true
    if scoreboardOpen then pushScoreboard() end
end)

FreeroamMenu.hideScoreboard = function() setScoreboardOpen(false) end

AddEventHandler("open77:scoreboardShow", function() setScoreboardOpen(true) end)
AddEventHandler("open77:scoreboardHide", function() setScoreboardOpen(false) end)

-- Keep distances live while the board is held open.
CreateThread(function()
    while true do
        if scoreboardOpen then pushScoreboard() end
        Wait(300)
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local errorMessage
    menu, errorMessage = WebUI.create({
        entry = "web/index.html",
        layer = "menu",
        width = 1920,
        height = 1080,
        fps = 60,
        transparent = true,
        -- Kept visible on purpose; the page is transparent while closed. See
        -- the note above setMenuOpen.
        visible = true,
    })
    if menu == nil then
        print("[freeroam] menu WebUI failed: " .. tostring(errorMessage))
    else
        print("[freeroam] menu surface created")
        menu:on("freeroam:ready", function()
            print("[freeroam] menu page loaded and ready")
            menu:send("freeroam:state", menuState())
        end)
        menu:on("freeroam:close", function()
            setMenuOpen(false)
        end)
        menu:on("freeroam:action", function(payload)
            if type(payload) ~= "table" or type(payload.type) ~= "string" then return end
            if payload.type == "wardrobe" then
                setMenuOpen(false)
                TriggerServerEvent("open77:command:execute", "wardrobe")
                return
            end
            local accepted2, reason2 = TriggerServerEvent("freeroam:menu", payload.type, payload)
            if not accepted2 then
                menu:send("freeroam:result", {
                    ok = false,
                    text = "network refused: " .. tostring(reason2),
                })
                return
            end
            -- Teleport-style actions fade the screen; keep the vehicle tabs
            -- open so several models can be tried in a row.
            if payload.type == "goto" or payload.type == "tpc" or payload.type == "spawn"
                or payload.type == "suicide" then
                setMenuOpen(false)
            end
        end)
    end

    local hudError
    hud, hudError = WebUI.create({
        entry = "web/hud.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 60,
        zIndex = 620,
        transparent = true,
        visible = true,
    })
    if hud == nil then
        -- The vanilla readouts stay visible if the replacement cannot paint.
        print("[freeroam] HUD WebUI failed; vanilla HUD retained: " .. tostring(hudError))
    else
        hud:on("freeroam:hud:ready", function()
            hudReady = true
            sampleStats()
            sampleVehicle()
            activateCustomHudIfReady()
            pushHud()
            if not hudView.ready then
                print("[freeroam] design-system HUD ready; waiting for stats before hiding stock readouts")
            end
        end)

        CreateThread(function()
            while hud ~= nil do
                sampleStats()
                sampleVehicle()
                activateCustomHudIfReady()
                requestWeaponSnapshot()
                pushHud()
                Wait(50)
            end
        end)
    end

    local scoreboardError
    scoreboard, scoreboardError = WebUI.create({
        entry = "web/scoreboard.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 10,
        zIndex = 800,
        transparent = true,
        visible = true,
    })
    if scoreboard == nil then
        print("[freeroam] scoreboard WebUI failed: " .. tostring(scoreboardError))
    else
        scoreboard:on("scoreboard:ready", function()
            requestRoster()
            pushScoreboard()
        end)
    end

    -- The world may already be attached when the server generation starts this
    -- resource; try right away, then once more in case the blip API was not
    -- available yet.
    CreateThread(function()
        Wait(1000)
        createBlips()
        if not blipsCreated then
            Wait(5000)
            createBlips()
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    setVanillaHudHidden(false)
    blipsCreated = false
    menu = nil
    menuOpen = false
    hud = nil
    hudReady = false
    hudClaimsActive = false
    lastHudClaimAttemptAt = -1000
    weaponRequests = {}
    scoreboard = nil
    scoreboardOpen = false
end)
