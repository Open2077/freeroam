-- Client half of the Open77 PvP gamemode.
--
-- Two jobs: announce readiness so the server can place this player, and RUN
-- THE WALL.
--
-- The wall being here is not a design preference, it is a measurement. Phase 0
-- E2 asked whether a prop can be solid and invisible at the same time, because
-- an invisible wall built from props would have been per-instance, free and
-- entirely server-side. The answer was no: `visible = false` is accepted by the
-- API, reports `created=8 refused=0`, and renders the prop anyway. Props are
-- solid (E1, measured against a control) but they cannot be hidden, so they can
-- MARK a boundary and never BE one.
--
-- That leaves the standard shape for this problem, and the one the platform is
-- built for: the client clamps its own position, and the server keeps a
-- backstop for the case where the clamp is absent, disabled or lying. See
-- server/bounds.lua -- a clamp that can be switched off is not authority.
--
-- Why a transform write is legitimate here, when every other move in this
-- resource is a kill -> respawn: the respawn transaction exists to carry the
-- fade, the streaming preload and the grace window across a real distance. A
-- correction of a few centimetres needs none of those, and using a respawn for
-- it would be a black screen every time somebody leaned on the boundary. This
-- is the one place in the mode where `Open77.travel.teleport` is the right
-- primitive, and it is bounded below so it can never become a teleport.

local announced = false

local bounds = nil        -- payload from server/bounds.lua `Bounds.payload`
local clampEnabled = false
local lastCorrectionAt = 0

local CLAMP_INTERVAL_MS = 16     -- ~60 Hz; the wall has to feel like geometry
local MAX_CORRECTION_M = 12.0    -- above this we are not clamping, see below
local MIN_CORRECTION_M = 0.001   -- below this, do not write a transform at all

-- ------------------------------------------------------------- readiness ---

local function announce()
    if announced then return end
    announced = true
    local sent, reason = TriggerServerEvent("deathmatch:ready")
    if not sent then
        announced = false
        Open77.log.error("deathmatch:ready not sent: " .. tostring(reason))
    end
end

AddEventHandler("open77:worldReady", announce)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    CreateThread(function()
        -- A server resource publication restarts every client resource while
        -- appearance and world restoration may still be running. A one-shot
        -- probe can miss the attached state and leave the server unaware of
        -- this player forever, so keep announcing until attachment; the server
        -- readiness gate makes both early and repeated attempts safe.
        while not announced do
            local state = Open77.character.state()
            if state and state.attached then announce() end
            if not announced then Wait(500) end
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        announced = false
        clampEnabled = false
        bounds = nil
    end
end)

-- ----------------------------------------------------------------- geometry ---

local function insideBox(box, x, y, z, inset)
    return x >= box.min.x + inset and x <= box.max.x - inset
       and y >= box.min.y + inset and y <= box.max.y - inset
       and z >= box.min.z and z <= box.max.z
end

-- Nearest point on (or just inside) a box. Z is clamped to the box but NOT
-- inset: the inset exists to keep a player off the vertical faces, and applying
-- it to Z would push somebody standing on the floor down through it.
local function projectInto(box, x, y, z, inset)
    local lo, hi
    local px, py, pz = x, y, z

    lo, hi = box.min.x + inset, box.max.x - inset
    if lo > hi then lo, hi = (box.min.x + box.max.x) * 0.5, (box.min.x + box.max.x) * 0.5 end
    if px < lo then px = lo elseif px > hi then px = hi end

    lo, hi = box.min.y + inset, box.max.y - inset
    if lo > hi then lo, hi = (box.min.y + box.max.y) * 0.5, (box.min.y + box.max.y) * 0.5 end
    if py < lo then py = lo elseif py > hi then py = hi end

    if pz < box.min.z then pz = box.min.z elseif pz > box.max.z then pz = box.max.z end
    return px, py, pz
end

local function distanceSq(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

-- The nearest legal point across every volume of the zone. Volumes overlap by
-- design -- a stair belongs to both the deck it leaves and the one it reaches --
-- so "outside" means outside ALL of them, and the correction is the closest
-- point of whichever volume is nearest.
local function nearestLegalPoint(x, y, z)
    local bestX, bestY, bestZ, bestSq
    for _, box in ipairs(bounds.volumes) do
        local px, py, pz = projectInto(box, x, y, z, bounds.inset or 0.0)
        local d = distanceSq(x, y, z, px, py, pz)
        if bestSq == nil or d < bestSq then
            bestSq, bestX, bestY, bestZ = d, px, py, pz
        end
    end
    return bestX, bestY, bestZ, bestSq
end

-- ---------------------------------------------------------------- the clamp ---

RegisterNetEvent("deathmatch:bounds", function(payload)
    if type(payload) ~= "table" or type(payload.volumes) ~= "table" then
        bounds, clampEnabled = nil, false
        return
    end

    -- An INCOMPLETE zone is not clamped. Kabuki ships unsurveyed, and a bounds
    -- test over a subset of its volumes is not a smaller arena -- it is an
    -- arena with holes, and every hole is a player being shoved by a wall that
    -- should not be there. server/bounds.lua omits unsurveyed volumes rather
    -- than sending half a box, and reports `complete` so this side can tell the
    -- difference between "outside the arena" and "we do not know yet".
    if payload.complete ~= true or #payload.volumes == 0 then
        bounds, clampEnabled = payload, false
        Open77.log.info(("deathmatch: bounds received for zone %s but not clamping (%d volume(s), complete=%s)")
            :format(tostring(payload.zone), #payload.volumes, tostring(payload.complete)))
        return
    end

    bounds = payload
    clampEnabled = true
end)

RegisterNetEvent("deathmatch:boundsClear", function()
    bounds, clampEnabled = nil, false
end)

CreateThread(function()
    while true do
        if clampEnabled and bounds ~= nil then
            local state = Open77.character.state()

            -- Never correct a player who is not standing in the world under
            -- their own control. During a placement the position is stale or
            -- absent entirely, and clamping a mid-respawn snapshot is how a
            -- spawn becomes a shove. `alive` is the cheap proxy the server uses
            -- for the same reason.
            if state and state.attached and state.alive and state.position then
                local x, y, z = state.position.x, state.position.y, state.position.z
                local outside = true
                for _, box in ipairs(bounds.volumes) do
                    if insideBox(box, x, y, z, 0.0) then outside = false break end
                end

                if outside then
                    local px, py, pz, dSq = nearestLegalPoint(x, y, z)
                    if px ~= nil then
                        local distance = math.sqrt(dSq)

                        -- Two bounds, and both matter.
                        --
                        -- Below MIN we do not write at all: floating point puts
                        -- a player a millimetre outside a face constantly, and
                        -- a transform write every frame for that would fight
                        -- the locomotion system for no visible gain.
                        --
                        -- Above MAX we do NOT clamp, deliberately. A player
                        -- twelve metres out is not leaning on the wall -- they
                        -- fell, they were launched, they were placed, or the
                        -- zone changed under them. Dragging them back across
                        -- that distance IS the teleport this mechanism exists
                        -- to avoid, and it would land them at an arbitrary box
                        -- face rather than on walkable ground. That case
                        -- belongs to the server backstop, which owns a proper
                        -- kill -> respawn onto a surveyed mark.
                        if distance > MIN_CORRECTION_M and distance <= MAX_CORRECTION_M then
                            local heading = state.heading or (state.rotation and state.rotation.yaw) or 0.0
                            local ok, reason = Open77.travel.teleport(px, py, pz, heading)
                            if not ok then
                                local now = Open77.time.monotonic()
                                if now - lastCorrectionAt > 5.0 then
                                    lastCorrectionAt = now
                                    Open77.log.warn("deathmatch: clamp refused: " .. tostring(reason))
                                end
                            end
                        end
                    end
                end
            end
        end
        Wait(CLAMP_INTERVAL_MS)
    end
end)

-- ------------------------------------------------------- survey heading ---
--
-- The server cannot see which way a player is facing: `Open77.players.position`
-- returns x, y, z and a bucket, and nothing else. That is why `/dm.survey mark`
-- had to be given a heading by hand -- it was asking the surveyor for the one
-- number only their own client knows, twenty-eight times.
--
-- So the client reports it, but ONLY while a survey session is open. The server
-- switches this on at `start` and off at `clear`, expiry and disconnect, which
-- keeps an ordinary player's session completely free of it: no timer, no
-- traffic, nothing running for a feature they will never use.

local headingReporter = false

RegisterNetEvent("deathmatch:surveyHeading", function(enabled)
    enabled = enabled == true
    if headingReporter == enabled then return end
    headingReporter = enabled
    if not enabled then return end

    CreateThread(function()
        while headingReporter do
            local state = Open77.character.state()
            local yaw = state and (state.yaw or (state.rotation and state.rotation.yaw))
            if yaw ~= nil then
                TriggerServerEvent("deathmatch:surveyHeading", yaw)
            end
            -- 4 Hz. A surveyor stands still, aims, and types; this only has to
            -- be fresher than the gap between facing a direction and pressing
            -- enter, and every extra sample is traffic nobody reads.
            Wait(250)
        end
    end)
end)

-- --------------------------------------------- forwarding an ENGINE hit ---
--
-- WHAT WAS HERE BEFORE, and why it is gone. This used to poll
-- `Open77.weapons.snapshot()` at 10 Hz, notice the magazine counter fall, and
-- send the camera ray as a guess at where the bullet went. Every part of that
-- was a workaround for not being able to see the shot: the ray was sampled when
-- the DROP was noticed rather than when the trigger was pulled, so a fast turn
-- while firing skewed it; a burst that emptied between two polls arrived as
-- several rays along one bearing; and the server then had to guess a victim by
-- casting that ray against capsules it invented, with no walls and no bones.
--
-- None of that is necessary. The engine already computes the hit -- properly,
-- with the real skeleton, the real cover and the real weapon stats -- and
-- `client/src/network/CombatReplication.cpp` now watches for it: the wrapped
-- `ScriptedPuppet.OnHit` reports through a bridge native and the drain emits
-- these two events. So this file no longer detects anything. It forwards.
--
-- THE TWO DIRECTIONS ARE REPORTED BY DIFFERENT CLIENTS, and that is the rule
-- that makes bots work in multiplayer at all. Every client that streams a bot
-- in runs its own copy of that bot's combat AI -- nothing in Open77 can
-- suppress it -- so on my screen it is shooting me and on yours it is shooting
-- you. If a witness were allowed to report, one burst would be credited once
-- per spectator.
--
--   open77:npcHit         I shot a bot. Only my client's player pulled that
--                         trigger, so I am the only possible reporter.
--   open77:npcAttackedMe  a bot shot me. Only my client owns my body, so again
--                         I am the only possible reporter.
--
-- Neither number is trusted. The server takes the player -> bot amount from its
-- own round-weapon table so a bot dies in the same number of shots a player
-- does; it takes the bot -> player amount from the engine but clamps it,
-- because a gang record's rifle is priced for a levelled solo player.
--
-- The intercept Z travels ABSOLUTE and unaltered. The server differences it
-- against the canonical bot transform to decide head or torso -- a body part
-- this side computed would be a damage multiplier this side chose.

local fireSequence = 0

-- Every argument of an engine-emitted client event arrives as a STRING. That is
-- documented and still easy to forget; `tonumber` is not optional here, and
-- `npcId` deliberately never sees it -- a 64-bit id does not survive a Lua
-- double past 2^53, so it is forwarded in exactly the form it arrived.
AddEventHandler("open77:npcHit", function(npcId, damage, hitZ, weapon, attackKind)
    if npcId == nil then return end
    fireSequence = fireSequence + 1
    TriggerServerEvent("deathmatch:npcHit", {
        npcId = npcId,
        damage = tonumber(damage),
        hitZ = tonumber(hitZ),
        -- The server checks this against the weapon it issued this player this
        -- round. It comes from the character state rather than from the event
        -- so it is the same string the verified-weapon gate compares against.
        weapon = Open77.character.state() and Open77.character.state().weaponId or weapon,
        attackKind = tonumber(attackKind),
        seq = fireSequence,
    })
end)

local hurtSequence = 0

AddEventHandler("open77:npcAttackedMe", function(npcId, damage, hitZ, weapon, attackKind)
    if npcId == nil then return end
    hurtSequence = hurtSequence + 1
    TriggerServerEvent("deathmatch:npcHurtMe", {
        npcId = npcId,
        amount = tonumber(damage),
        attackKind = tonumber(attackKind),
        weapon = weapon,
        seq = hurtSequence,
    })
end)

-- Bot versus bot, and this one is forwarded by exactly ONE client.
--
-- There is no player on either end of a crossfire, so neither owner rule above
-- applies and every client that streams both bodies sees the same exchange. The
-- native drops it unless this client holds the VICTIM's simulation lease -- the
-- platform's own single-client designation, elected by the server and
-- epoch-checked -- so by the time it reaches here it has already been made
-- unique. This side adds nothing to that; it forwards.
AddEventHandler("open77:npcCrossfire", function(victimNpcId, attackerNpcId, damage)
    if victimNpcId == nil or attackerNpcId == nil then return end
    TriggerServerEvent("deathmatch:npcCrossfire", {
        victim = victimNpcId,
        attacker = attackerNpcId,
        amount = tonumber(damage),
    })
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        fireSequence, hurtSequence = 0, 0
    end
end)
