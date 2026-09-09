-- UI adapter only. The platform owns validation, replication, cancellation and
-- native presentation. Use the public Promise API in the downloaded host.
local page, ready, running = nil, false, true
local catalog, byId, current = {}, {}, nil
local busy, serial, loading, loaded, revision = false, 0, false, false, 0
local statusText, lastCue = '', -1
local errors = {
    player_not_ready = 'Wait until your character has finished loading.',
    player_not_alive = 'You must be alive to play an animation.',
    player_in_vehicle = 'Exit your vehicle first.',
    animation_owned = 'Stop your current action before choosing another animation.',
    interrupted = 'Animation interrupted. Stand still and put your weapon away.',
    timeout = 'The animation could not start in time. Please try again.',
    unknown_profile = 'This animation is not available on this server.',
    invalid_clip = 'This variant is not available.',
    resource_stopped = 'The animation service is unavailable.',
}
local function localPlayer()
    local state = Open77.network.status()
    return state and tonumber(state.playerId)
end
local function send()
    if page and ready then
        page:send('animations:state', { catalog = catalog, current = current or false,
            busy = busy, loaded = loaded, message = statusText })
    end
end
local function cue()
    local now = Open77.time.monotonic()
    if now - lastCue < 0.15 then return end
    lastCue = now
    if Open77.sfx then pcall(Open77.sfx.play, 'ui_menu_onpress',
        { tag = 'freeroam.animations.select', unique = true, duration = 0.3 }) end
end
local function report(reason)
    statusText = errors[reason] or ('Animation unavailable: ' .. tostring(reason or 'unknown_error'))
    send()
    TriggerEvent('chat:addMessage', { type = 'system', author = 'ANIMATIONS',
        text = statusText, color = { 245, 201, 92 } })
end
local function await(pending, err)
    if not pending then return nil, err or 'resource_stopped' end
    return pending:await()
end
local function refresh()
    if loading then return end
    loading = true
    CreateThread(function()
        local values, err = await(Open77.animations.list())
        if not running then return end
        loading = false
        if not values then report(err); return end
        catalog, byId, loaded = values, {}, true
        for _, profile in ipairs(values) do byId[profile.id] = profile end
        local observed = revision
        local state = await(Open77.animations.state())
        if observed == revision then current = state end
        if running then send() end
    end)
end
local function open()
    if not page or not FreeroamMenu then return end
    FreeroamMenu.open()
    page:send('animations:open', {})
    cue()
    refresh()
end
local function stop()
    -- Abandon pending starts too. Late server acceptances are cancelled by the
    -- controller, not revived by a stale UI callback.
    serial = serial + 1
    revision = revision + 1
    busy, current, statusText = false, nil, ''
    send()
    cue()
    CreateThread(function()
        local ok, err = await(Open77.animations.cancel())
        if running and not ok then report(err) end
    end)
end
local function play(payload)
    if busy then return end
    local profile = type(payload.profile) == 'string' and byId[payload.profile]
    if not profile then report('unknown_profile'); return end
    local valid = false
    for _, clip in ipairs(profile.clips or {}) do if clip == payload.clip then valid = true; break end end
    if not valid then report('invalid_clip'); return end
    if type(payload.loop) ~= 'boolean' then return end
    local duration = tonumber(payload.durationMs)
    if not payload.loop and duration ~= 5000 and duration ~= 10000 and duration ~= 30000 then return end
    local options = { clip = payload.clip, loop = payload.loop }
    if not payload.loop then options.durationMs = duration end
    busy, statusText = true, ''
    serial = serial + 1
    local request = serial
    send()
    cue()
    FreeroamMenu.close() -- release the mouse before the temporary F7 view starts
    CreateThread(function()
        if not running or request ~= serial then return end
        local value, err = await(Open77.animations.request(profile.id, options))
        if not running or request ~= serial then return end
        busy = false
        if not value then report(err); return end
        -- Query canonical state: a native failure/stop may beat the Promise.
        local observed = revision
        local state = await(Open77.animations.state())
        if running and request == serial then
            if observed == revision then current = state end
            send()
        end
    end)
end
-- Client handlers do not expose the server-side `source` global. This ordinary
-- UI event never carries animation authority or a target player ID.
RegisterNetEvent('open77_animations:menu', open)
AddEventHandler('onPlayerAnimationChanged', function(player, state)
    if tonumber(player) ~= localPlayer() or type(state) ~= 'table' then return end
    revision = revision + 1
    current = state.active and state or nil
    send()
end)
AddEventHandler('onAnimationPlaybackFailed', function(player, _, reason)
    if tonumber(player) ~= localPlayer() then return end
    revision = revision + 1
    current = nil
    report(reason)
end)
AddEventHandler('onClientResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    page = FreeroamMenu.surface()
    if not page then return end
    page:on('animations:ready', function() ready = true; refresh() end)
    page:on('animations:open', open)
    page:on('animations:action', function(payload)
        if type(payload) ~= 'table' then return end
        if payload.action == 'stop' then stop()
        elseif payload.action == 'play' then play(payload)
        elseif payload.action == 'refresh' then refresh() end
    end)
end)
AddEventHandler('onClientResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    running, ready, page = false, false, nil
    serial = serial + 1
    -- The platform watches invoking-resource generations and retires its actions.
end)
