-- Freeroam PvP policy and kill feed.
--
-- The engine-level damage authority (DamageAuthorityService) validates every
-- attacker report before this file sees anything. Freeroam only decides
-- gameplay policy: enable friendly fire, shield the spawn areas, and turn the
-- attributed kill events into a feed every client renders.

local combatConfig = (FreeroamConfig and FreeroamConfig.combat) or {}

local function combatAnnounce(target, text, color)
    TriggerClientEvent("chat:addMessage", target, {
        author = "Freeroam",
        text = text,
        color = color or { 255, 90, 90 },
    })
end

local function distance(a, b)
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function insideSafeZone(position)
    local radius = combatConfig.safeZoneRadius or 0
    if radius <= 0 or position == nil then return false end
    local points = (FreeroamConfig.spawn and FreeroamConfig.spawn.points) or {}
    for index = 1, #points do
        local point = points[index].position
        if point ~= nil and distance(position, point) <= radius then
            return true
        end
    end
    return false
end

-- Policy, applied once at resource start.
if combatConfig.pvpEnabled ~= false then
    Open77.combat.setFriendlyFire(true)
    print("freeroam: PvP enabled (friendly fire on).")
else
    -- PvP FFA needs host damage enabled. The Freeroam and arena arbiters
    -- separately reject city damage and same-side arena damage.
    Open77.combat.setFriendlyFire(Deathmatch ~= nil)
    print("freeroam: PvP disabled.")
end
if combatConfig.damageMultiplier ~= nil then
    Open77.combat.setDamageMultiplier(combatConfig.damageMultiplier)
end
if combatConfig.headshotMultiplier ~= nil then
    Open77.combat.setHeadshotMultiplier(combatConfig.headshotMultiplier)
end
if combatConfig.rangedMultiplier ~= nil then
    Open77.combat.setKindDamageMultiplier("ranged", combatConfig.rangedMultiplier)
end
if combatConfig.meleeMultiplier ~= nil then
    Open77.combat.setKindDamageMultiplier("melee", combatConfig.meleeMultiplier)
end
if combatConfig.explosionMultiplier ~= nil then
    Open77.combat.setKindDamageMultiplier("explosion", combatConfig.explosionMultiplier)
end

-- Spawn protection: cancel any damage given or received inside a safe zone.
Open77.combat.onDamage(function(event)
    -- The activity's own instance/weapon/team arbiter handles arena damage.
    -- NPC ids are not player ids and must never reach players.position.
    if Deathmatch and (Deathmatch.instances.resolve(event.victim)
        or Deathmatch.instances.resolve(event.attacker)) then return true end
    if combatConfig.pvpEnabled == false then return false end
    if (tonumber(event.victim) or 0) <= 0 then return true end
    local victimPosition = Open77.players.position(event.victim)
    if victimPosition ~= nil and insideSafeZone(victimPosition) then
        return false
    end
    local attackerId = tonumber(event.attacker) or 0
    local attackerPosition = attackerId > 0 and attackerId < 1000000000
        and Open77.players.position(attackerId) or nil
    if attackerPosition ~= nil and insideSafeZone(attackerPosition) then
        return false
    end
    return true
end)

-- Optional passive regeneration for every connected player.
local regen = combatConfig.regenPerSecond or 0
if regen > 0 then
    AddEventHandler("onPlayerConnected", function(playerId)
        Open77.players.setRegen(tonumber(playerId) or 0, regen)
    end)
end

-- Kill feed: the life pipeline emits open77:playerKilled with the attributed
-- killer once the damage ledger reaches zero.
local killfeed = combatConfig.killfeed or {}
AddEventHandler("open77:playerKilled", function(victimId, killerId)
    if FreeroamPvp and FreeroamPvp.ownsPlayer(victimId) then return end
    if killfeed.enabled == false then return end
    local victim = tonumber(victimId) or 0
    local killer = tonumber(killerId) or 0
    if victim == 0 or killer == 0 or killer == victim then return end
    local victimName = GetPlayerName(victim) or ("Player " .. victim)
    local killerName = GetPlayerName(killer) or ("Player " .. killer)
    TriggerClientEvent("freeroam:killfeed", -1, killerName, victimName)
    combatAnnounce(-1, killerName .. " eliminated " .. victimName .. ".")
end)

-- Temporary PvP diagnostics for runtime acceptance (remove afterwards).
AddEventHandler("open77:combatAnomaly", function(playerId, kind, detail)
    print("[pvp-diag] anomaly player=" .. tostring(playerId) .. " kind=" .. tostring(kind) ..
        " detail=" .. tostring(detail))
end)
AddEventHandler("open77:playerDamaged", function(victimId, attackerId, amount, attackKind, weapon, bodyPart, remaining)
    print("[pvp-diag] damaged victim=" .. tostring(victimId) .. " attacker=" .. tostring(attackerId) ..
        " amount=" .. tostring(amount) .. " kind=" .. tostring(attackKind) .. " part=" .. tostring(bodyPart) ..
        " remaining=" .. tostring(remaining))
end)

-- Suicide and environment deaths still show up in the feed, unattributed.
AddEventHandler("open77:playerDied", function(playerId, context)
    if FreeroamActivities and FreeroamActivities.ownsPlayer(playerId) then return end
    if killfeed.enabled == false then return end
    local victim = tonumber(playerId) or 0
    if victim == 0 then return end
    local killer = 0
    if type(context) == "string" then
        local killerText = context:match('"killer"%s*:%s*(%d+)')
        killer = tonumber(killerText) or 0
    end
    if killer ~= 0 then return end -- the attributed handler above covers it
    local victimName = GetPlayerName(victim) or ("Player " .. victim)
    TriggerClientEvent("freeroam:killfeed", -1, "", victimName)
end)
