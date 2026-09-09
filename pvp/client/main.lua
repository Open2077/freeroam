-- Shared Freeroam page, no duplicate health/ammo/crosshair surface.
local page, state
local ready, sound = false, true
local previousPhase, previousMatch, previousKills, countdown = nil, nil, 0, nil
local cueAt, handles = {}, {}
local safeAreaClaimed = false
local function combatSpace(enabled)
    if enabled == safeAreaClaimed then return end
    if not Open77.world or not Open77.world.setSafeAreas then return end
    local ok, accepted = pcall(Open77.world.setSafeAreas, not enabled)
    if ok and accepted then safeAreaClaimed = enabled end
end
local function send(event, payload) if page and ready then page:send(event, payload) end end
local function stopSounds()
    for _, handle in pairs(handles) do pcall(Open77.sfx.stop, handle) end
    handles = {}
end
local function cue(key)
    local event = DeathmatchConfig.sfx[key]
    if not sound or not DeathmatchConfig.sfx.enabled or not event or not Open77.sfx then return end
    local now = Open77.time.monotonic()
    if cueAt[key] and now-cueAt[key] < 0.12 then return end
    cueAt[key] = now
    if handles[key] then pcall(Open77.sfx.stop, handles[key]) end
    local ok, handle = pcall(Open77.sfx.play, event, { tag="freeroam.pvp."..key, unique=true, duration=2.0 })
    if ok then handles[key] = handle end
end
local function open()
    if not FreeroamMenu or not page then return end
    FreeroamMenu.open()
    send("pvp:open", {})
    TriggerServerEvent("deathmatch:requestState")
    TriggerServerEvent("deathmatch:requestGuns")
    cue("select")
end
FreeroamPvpClient = {
    ownsHud = function() return state and state.participant == true end,
    hasActivity = function() return state and (state.participant == true or state.playerState == "queued") end,
}
RegisterNetEvent("deathmatch:panel", function(value) if value ~= false then open() end end)
RegisterNetEvent("deathmatch:state", function(payload)
    if type(payload) ~= "table" then return end
    state = payload
    if state.participant then
        combatSpace(true)
        local phase = state.roundState or state.phase
        if previousMatch ~= state.matchId then previousKills = 0; countdown = nil end
        if phase ~= previousPhase then
            if phase == "active" then cue("start")
            elseif phase == "resolved" or phase == "standings" then cue("result") end
        end
        local kills = tonumber(state.self and state.self.kills) or 0
        if kills > previousKills then cue("select") end
        previousKills = kills
        if phase == "buy" or phase == "between" then
            local seconds = math.ceil((tonumber(state.remainingMs) or 0)/1000)
            if seconds > 0 and seconds <= 3 and countdown ~= seconds then cue("tick"); countdown = seconds end
        end
        previousPhase, previousMatch = phase, state.matchId
    else
        previousPhase, previousMatch, previousKills = nil, nil, 0
    end
    send("pvp:state", payload)
end)
RegisterNetEvent("freeroam:pvp:entered", function()
    combatSpace(true)
    FreeroamMenu.close(); FreeroamMenu.hideScoreboard()
    if FreeroamRaceClient then FreeroamRaceClient.close() end
    cue("join")
end)
RegisterNetEvent("freeroam:pvp:returned", function()
    combatSpace(false)
    stopSounds()
    send("pvp:notice", {title="FREEROAM",message="Back in the city. Your next activity is up to you."})
end)
RegisterNetEvent("deathmatch:guns", function(payload)
    if type(payload) ~= "table" then return end
    -- An arming callback must not steal the mouse during a live fight.
    send("pvp:weapons", payload)
end)
for _, name in ipairs({"notice", "killfeed"}) do
    RegisterNetEvent("deathmatch:"..name, function(payload) if type(payload)=="table" then send("pvp:"..name,payload) end end)
end
RegisterNetEvent("deathmatch:callout", function(payload)
    if not state or not state.participant or type(payload)~="table" then return end
    local labels = {double="DOUBLE ELIMINATION",triple="TRIPLE ELIMINATION",headshot="HEADSHOT",streak="ELIMINATION STREAK",lead="LEAD TAKEN"}
    local title = labels[payload.kind] or tostring(payload.kind or ""):gsub("_"," "):upper()
    send("pvp:notice",{title=title,message=(tonumber(payload.count) or 0)>1 and tostring(payload.count).." eliminations" or "Confirmed by the server."})
end)
AddEventHandler("open77:scoreboardShow",function() if FreeroamPvpClient.ownsHud() then send("pvp:board",{open=true}) end end)
AddEventHandler("open77:scoreboardHide",function() send("pvp:board",{open=false}) end)
AddEventHandler("onClientResourceStart",function(name)
    if name~=GetCurrentResourceName() then return end
    page=FreeroamMenu.surface()
    if not page then return end
    page:on("pvp:ready",function() ready=true; if state then send("pvp:state",state) end end)
    page:on("pvp:open",open)
    page:on("pvp:action",function(payload)
        if type(payload)~="table" then return end
        local action=payload.action
        if action=="sound" then sound=payload.enabled==true; if not sound then stopSounds() end; return end
        if action=="refresh" then TriggerServerEvent("deathmatch:requestState"); TriggerServerEvent("deathmatch:requestGuns"); return end
        cue("select")
        if action=="join" then TriggerServerEvent("deathmatch:join")
        elseif action=="queue" then TriggerServerEvent("freeroam:pvp:queue",payload.format,payload.bots==true)
        elseif action=="leave" then TriggerServerEvent("deathmatch:leave","auto")
        elseif action=="weapon" then TriggerServerEvent("deathmatch:chooseGuns",payload.key); TriggerServerEvent("deathmatch:requestGuns")
        elseif action=="kit" then TriggerServerEvent("deathmatch:kit",payload.key) end
    end)
    ready=true
    TriggerServerEvent("deathmatch:requestState")
end)
AddEventHandler("onClientResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    combatSpace(false)
    stopSounds(); page,state,ready=nil,nil,false
end)
