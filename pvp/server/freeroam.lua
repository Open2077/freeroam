-- Integration boundary: admission and returns wrap the existing FFA/arena
-- engine, so commands and UI go through exactly the same authoritative gate.
local DM = Deathmatch
local returns, throttles = {}, {}
local stopped = false
FreeroamPvp = {}

local function persist()
    if not Open77.state then return end
    local bag = Open77.state.load() or {}
    bag.freeroamPvpReturns = returns
    Open77.state.save(bag)
end

function FreeroamPvp.ownsPlayer(id)
    id = tonumber(id)
    return id ~= nil and (returns[id] ~= nil or DM.instances.of(id) ~= nil)
end

function FreeroamPvp.isReserved(id)
    if FreeroamPvp.ownsPlayer(id) then return true end
    local _, format = DM.arena.queuePosition(tonumber(id))
    return format ~= nil
end

local function notice(id, text)
    TriggerClientEvent("deathmatch:notice", id, { kind = "warning", title = "PVP", message = text })
end

local function entryFailure(id)
    if FreeroamRace and FreeroamRace.isReserved(id) then return "Leave Race or its queue first." end
    if returns[id] then return "Return to Freeroam first. Use /pvp.leave to retry if needed." end
    if DM.instances.of(id) then return "Leave your current match first." end
    local life = Open77.players.getLifeState(id)
    if not Open77.ready.isReady(id) or not life or life.phase ~= "alive" then
        return "Wait until your character is ready."
    end
    local position = Open77.players.position(id)
    if not position or tonumber(position.bucket) ~= 0 then return "Return to Freeroam first." end
    local seat = Open77.vehicles.getPlayerSeat(id)
    if type(seat) == "table" and seat.vehicleId ~= nil then return "Exit your vehicle before entering PvP." end
    return nil
end
FreeroamPvp.entryFailure = entryFailure

local function admit(id)
    id = DM.playerId(id)
    if not id then return nil, "invalid_player" end
    local now = DM.nowMs()
    if throttles[id] and now - throttles[id] < 700 then return nil, "rate_limited" end
    throttles[id] = now
    local failure = entryFailure(id)
    if failure then notice(id, failure); return nil, failure end
    return id
end

local joinFFA, enqueue = DM.round.join, DM.arena.enqueue
DM.round.join = function(id)
    local accepted, reason = admit(id)
    if not accepted then return nil, reason end
    local _, queued = DM.arena.queuePosition(accepted)
    if queued then notice(accepted, "Leave the arena queue before joining free-for-all."); return nil, "already_queued" end
    return joinFFA(accepted)
end
DM.arena.enqueue = function(id, format, bots)
    local accepted, reason = admit(id)
    if not accepted then return nil, reason end
    return enqueue(accepted, format, bots == true)
end

local place = DM.place
DM.place = function(id, instance, reason, graceMs, mark)
    id = DM.playerId(id)
    if not id then return false, "invalid_player" end
    if not returns[id] then
        -- The roster already contains us here. Capture at match start, NOT
        -- queue entry: queued players can explore the city in the meantime.
        if FreeroamRace and FreeroamRace.isReserved(id) then return false, "race_in_progress" end
        local position, life = Open77.players.position(id), Open77.players.getLifeState(id)
        if not Open77.ready.isReady(id) or not position or not life or life.phase ~= "alive" then
            return false, "not_ready"
        end
        if tonumber(position.bucket) ~= 0 then return false, "not_in_freeroam" end
        local seat = Open77.vehicles.getPlayerSeat(id)
        if type(seat) == "table" and seat.vehicleId ~= nil then return false, "in_vehicle" end
        local health = Open77.players.getHealth(id) or {}
        returns[id] = {
            x = position.x, y = position.y, z = position.z,
            bucket = position.bucket or 0, heading = position.heading or life.heading or 0,
            armor = health.armor or 0, godMode = health.godMode == true,
        }
        persist()
        Open77.players.setGodMode(id, false)
        TriggerClientEvent("freeroam:pvp:entered", id)
    end
    local ok, detail = place(id, instance, reason, graceMs, mark)
    if not ok then
        -- Defer teardown until the round's roster loop has finished. The
        -- capture remains owned until recovery completes, even on failure.
        SetTimeout(1, function()
            if not stopped then DM.leave(id, "auto") end
        end)
    end
    return ok, detail
end

function FreeroamPvp.returnPlayer(id)
    id = DM.playerId(id)
    local target = id and returns[id]
    if not target then return false, "no_return_position" end
    if target.returning then return true end
    target.returning = true
    persist()
    DM.loadout.strip(id)
    DM.setTeam(id, 0)
    TriggerClientEvent("deathmatch:boundsClear", id)
    local started, requested = DM.nowMs(), false
    local function step()
        if stopped or returns[id] ~= target then return end
        local life = Open77.players.getLifeState(id)
        if not life then returns[id] = nil; persist(); return end
        local phase = tostring(life.phase or ""):gsub("_", "")
        if requested and (phase == "alive" or phase == "recovering") then
            local position = Open77.players.position(id)
            if position and tonumber(position.bucket) == target.bucket then
                local dx, dy, dz = position.x-target.x, position.y-target.y, position.z-target.z
                if dx*dx+dy*dy+dz*dz < 225 then
                    Open77.players.setArmor(id, target.armor)
                    Open77.players.setGodMode(id, target.godMode)
                    Open77.players.setRegen(id, (FreeroamConfig.combat or {}).regenPerSecond or 0)
                    returns[id] = nil
                    persist()
                    TriggerClientEvent("freeroam:pvp:returned", id)
                    return
                end
            end
        end
        if not requested then
            DM.suppressDeath(id, 3000)
            DM.scoring.suppressDeath(id, 3000)
            if phase == "alive" or phase == "recovering" then
                local ok = Open77.players.kill(id, { cause = "script", weapon = "pvp:return" })
                if ok then phase = "dead" end
            end
            if phase == "dead" then
                requested = Open77.players.respawn(id, {
                    position = { x=target.x, y=target.y, z=target.z }, heading=target.heading,
                    bucket=target.bucket, health=1.0, graceMs=5000,
                }) == true
            end
        end
        if DM.nowMs() - started > 30000 then
            target.returning = false
            persist()
            notice(id, "Return is delayed. Use /pvp.leave to retry.")
            return
        end
        SetTimeout(250, step)
    end
    step()
    return true
end
DM.sendToLobby = function(id) return FreeroamPvp.returnPlayer(id) end

local leave = DM.leave
DM.leave = function(id, scope)
    local ok = leave(id, scope)
    id = tonumber(id)
    if returns[id] and not DM.instances.of(id) then FreeroamPvp.returnPlayer(id) end
    return ok
end

local function openPanel(id)
    if id <= 0 then return end
    TriggerClientEvent("deathmatch:panel", id, true)
end
RegisterCommand("pvp", function(id) openPanel(id) end, false)
RegisterCommand("pvp.join", function(id) if id > 0 then DM.round.join(id) end end, false)
RegisterCommand("pvp.leave", function(id) if id > 0 then DM.leave(id, "auto"); DM.broadcastState() end end, false)
RegisterNetEvent("freeroam:pvp:open", function() openPanel(source) end)
RegisterNetEvent("freeroam:pvp:queue", function(format, bots)
    DM.arena.enqueue(source, format, bots == true)
    DM.broadcastState()
end)
RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, {
        { command="/pvp", help="Open the Freeroam PvP activity." },
        { command="/pvp.join", help="Join a free-for-all fight." },
        { command="/pvp.leave", help="Leave PvP and return to your position." },
    })
end)
AddEventHandler("onPlayerDisconnected", function(id)
    id = tonumber(id); returns[id], throttles[id] = nil, nil; persist()
end)
AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then stopped = true end
end)
-- Match state is not carried on reload. Recover captured Freeroam positions;
-- map drafts and career keys in the same state bag are left untouched.
AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() or not Open77.state then return end
    local bag = Open77.state.load() or {}
    for key, value in pairs(bag.freeroamPvpReturns or {}) do
        local id = tonumber(key)
        if id and type(value) == "table" then
            value.returning = false; returns[id] = value
            SetTimeout(1000, function() FreeroamPvp.returnPlayer(id) end)
        end
    end
end)
