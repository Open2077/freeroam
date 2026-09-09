-- Combat feedback HUD: kill feed, authoritative hitmarker, damage flash.
--
-- Self-contained on purpose: this file owns its own always-visible transparent
-- surface (web/killfeed.html) and never touches the menu or the scoreboard.
-- Every event it renders is server-authoritative:
--   freeroam:killfeed    broadcast by server/combat.lua on attributed kills
--   open77:hitConfirmed  emitted by the plugin when the server credited a hit
--                        by the local player (lethal flag included)
--   open77:localDamaged  emitted by the plugin when the local player lost
--                        health, with the world-space hit direction

local feed
local feedConfig = (FreeroamConfig and FreeroamConfig.combat and FreeroamConfig.combat.killfeed) or {}

local function push(event, payload)
    if feed then feed:send(event, payload or {}) end
end

RegisterNetEvent("freeroam:killfeed", function(killerName, victimName)
    push("killfeed:entry", {
        killer = tostring(killerName or ""),
        victim = tostring(victimName or ""),
    })
end)

AddEventHandler("open77:hitConfirmed", function(victimId, amount, bodyPart, lethal)
    push("killfeed:hit", {
        amount = tonumber(amount) or 0,
        bodyPart = tostring(bodyPart or "unknown"),
        lethal = tostring(lethal) == "1",
    })
end)

AddEventHandler("open77:localDamaged", function(attackerId, amount, dirX, dirY, dirZ)
    push("killfeed:damaged", {
        amount = tonumber(amount) or 0,
        direction = {
            x = tonumber(dirX) or 0,
            y = tonumber(dirY) or 0,
            z = tonumber(dirZ) or 0,
        },
    })
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local errorMessage
    feed, errorMessage = WebUI.create({
        entry = "web/killfeed.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 15,
        zIndex = 780,
        transparent = true,
        visible = true,
    })
    if feed == nil then
        print("[freeroam] killfeed WebUI failed: " .. tostring(errorMessage))
        return
    end
    feed:on("killfeed:ready", function()
        push("killfeed:config", {
            maxEntries = feedConfig.maxEntries or 5,
            entryTtlMs = feedConfig.entryTtlMs or 6000,
        })
    end)
end)
