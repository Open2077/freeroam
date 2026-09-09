-- Open77 deathmatch -- bots.
--
-- THE BOTS FIGHT WITH CYBERPUNK'S OWN COMBAT AI. This file no longer picks
-- their targets, walks them, or subtracts anybody's health on a timer.
--
-- ===========================================================================
-- WHY THE SCRIPTED COMBAT LAYER IS GONE
-- ===========================================================================
--
-- It was never fighting FOR the engine; it was fighting AGAINST it. Three
-- findings, in the order they landed:
--
--   F10  `aiMode` reaches no engine call at all. It rides the replica and is
--        exposed to Lua, and `NpcReplication.cpp`, `NpcTasks.cpp` and
--        `Puppets.cpp` branch on it NOWHERE. Server-side it gates task
--        scheduling and the authority lease and nothing else. So `tasks` and
--        `native` are the same thing on a client, and every Maelstrom bot this
--        mode has ever spawned has had full vanilla combat AI running.
--
--        SUPERSEDED IN PART, 2026-09-01. `aiMode` now reaches exactly one
--        engine call and it is the one this mode needs: `NpcReplication`'s
--        hostility sweep treats `native` as "this body is meant to fight the
--        other `native` bodies of its bucket", and makes that true explicitly
--        (`client/src/api/Hostility.hpp`). The rest of F10 stands -- nothing
--        switches vanilla combat AI on or off, and nothing can.
--
--   Observed in game, 2026-09-01, and it is the whole indictment: some bots hit
--        the player through walls while others "look normal". That is TWO
--        combat systems on ONE body -- the scripted timer, which has no
--        occlusion, no aim and no animation, and the engine's, which has all
--        three. The minimap read COMBAT, a vanilla enemy health bar was drawn
--        over a bot, and a bot closed to melee. None of that is ours.
--
--   And the scripted layer was actively sabotaging the engine's. `moveTo` was
--        re-issued every 500 ms with the movement channel CLEARED first, which
--        cancels whatever command the behaviour tree had running. A body told
--        twice a second to walk somewhere cannot take cover, cannot strafe, and
--        cannot hold a firing line.
--
-- So the fake is deleted. What replaces each piece:
--
--   TARGETING          the engine's. Attitude, senses, the target tracker.
--   LINE OF SIGHT      the engine's raycast. The old `hasLineOfSight` tested
--                      whether both endpoints sat inside the arena volume --
--                      and the market is ONE box, so every point was "visible"
--                      from every other. It has been DELETED, not fixed: a
--                      predicate that returns true everywhere is worse than no
--                      predicate, because it reads like a check.
--   MOVEMENT           the engine's. No task stream. See HANDS OFF below.
--   THE BOT'S GUN      the engine's. The bot draws, aims and fires a real
--                      weapon; the VICTIM's client observes the resulting
--                      `gameHitEvent` and reports it.
--   BOT VS BOT         the engine's, through faction rivalry -- which is why
--                      the template list is now three MUTUALLY HOSTILE gangs
--                      rather than one. Maelstrom against Maelstrom is one
--                      side, and one side does not fight.
--
-- ===========================================================================
-- HANDS OFF: WHAT THIS FILE MUST NOT DO TO A COMBAT BOT
-- ===========================================================================
--
-- There is no "release control" call and none is needed -- the client's
-- authority tick issues a native command only while a movement task exists
-- (`NpcReplication.cpp`, `ActiveTask(... Movement)`), and cancels whatever was
-- running the moment there is none. So an EMPTY TASK QUEUE IS the hands-off
-- mode. The rule is therefore a rule about restraint:
--
--   * never enqueue a movement task on a combat bot;
--   * never enqueue a look task on a combat bot -- a forced `lookAt` fights the
--     aim controller for the same bone chain;
--   * never `setTransform` except as the leash of last resort, because a
--     teleport revokes the simulation lease and bumps the epoch.
--
-- `damagePolicy` is the one thing Open77 itself would impose: every policy
-- other than `mortal` installs a `gameGodModeSystem` Immortal source on the
-- projected body, which floors the vanilla damage pipeline. Bots are `mortal`
-- and must stay `mortal`.
--
-- ===========================================================================
-- THE MULTIPLAYER PROBLEM, AND THE ONE RULE THAT SOLVES IT
-- ===========================================================================
--
-- Every client that streams a bot in spawns the same full `NPCPuppet` from the
-- same record and runs its own copy of the behaviour tree. Nothing suppresses
-- it: `Toggle(AIHumanComponent)`, disabling `Senses`, a queued
-- `AIHoldPositionCommand` and a friendly attitude group have all been measured
-- and all failed. There is one authority client per NPC and it owns TASKS, not
-- the AI.
--
-- So on my screen the bot is shooting me, and on yours it is shooting you. If
-- witnesses were allowed to report, one burst would be credited N times.
--
--   OWNER REPORTS. The client that owns the body reports the hit.
--
--     player -> bot   the SHOOTER's client. Exactly one client's player pulled
--                     that trigger, so there is no duplicate to suppress.
--     bot -> player   the VICTIM's client. Exactly one client owns that player,
--                     so there is no duplicate to suppress.
--
-- This is duplicate-free for any number of clients without suppressing
-- anything, and it needs no cross-client agreement about who is fighting whom.
-- What it does NOT buy is a single consistent fight: two clients may see the
-- same bot standing in different places. Health does not diverge, because the
-- server ledger is the only thing that writes a health number.
--
-- ===========================================================================
-- TWO HEALTH LEDGERS, AND WHICH ONE WINS
-- ===========================================================================
--
-- The engine body carries the record's own priced pool -- 206 points for the
-- Maelstrom grunt, read off the vanilla health bar in game. This file says 100.
-- They are not in conflict, because `NpcReplication::ApplyState` projects the
-- server value as a FRACTION (`Api::Life::SetHealth(entity, health/maxHealth)`)
-- rather than as points.
--
--   THE SERVER LEDGER WINS, AND ITS 100 IS A PERCENTAGE SCALE.
--
-- A 26-point hit is 26% of whatever the record's pool happens to be, so four
-- hits kill a bot regardless of which gang it belongs to. That is why the three
-- templates need no rebalancing against each other, and why nothing here reads
-- the engine's number.
--
-- It also explains the "bots are unkillable" report exactly. Vanilla damage
-- lands on the engine pool, the server never hears about it, and the next
-- revision bump re-projects the canonical fraction -- so the bar drops and
-- snaps back. Reporting the hit is what closes that loop: the report decrements
-- the server ledger, and the fraction that comes back is the lower one.
--
-- ===========================================================================
-- THE TWO REPORT PATHS
-- ===========================================================================
--
-- `CombatReplication` mirrors NpcReplication into `s_npcBodies` and emits two
-- client Lua events off the wrapped `ScriptedPuppet.OnHit`. The client half of
-- this resource forwards them; this file admits them:
--
--   deathmatch:npcHit     I shot bot <npcId>. Carries the engine's damage, the
--                         absolute world Z of the intercept, the weapon and the
--                         attack kind.
--   deathmatch:npcHurtMe  bot <npcId> hit me, for <amount>.
--
-- Neither is trusted for the number it carries. The player -> bot amount comes
-- from this file's round-weapon table so that a bot takes the same number of
-- shots as a player does; the bot -> player amount is the engine's, CLAMPED,
-- because that direction is what "the engine's combat, faithfully" means and an
-- unclamped gang record can two-shot somebody.
--
-- The body part is derived from `hitZ - canonicalBotZ`, never reported. There
-- is no "I hit the head" field, because a body part the client chooses is a
-- damage multiplier the client chooses.
--
-- Both paths reuse the gate battery built for the old ray report: identity,
-- verified weapon, cadence, duplicate `seq`, per-second token bucket and a
-- per-player damage-per-second ceiling.
--
-- WHAT IS DELIBERATELY NOT VALIDATED, and it is a real change of posture: this
-- file no longer runs its own hit test. It cannot -- the server has volumes,
-- not geometry, and the whole point of the engine path is that the SHOOTER's
-- machine has the bones and the walls. Range and bucket are still checked, but
-- the wallhack-shaped hole the old ray report had is now closed by the engine
-- raycast rather than left open, and the client's say shrinks from "here is a
-- ray, pick somebody" to "the engine says I hit this specific body".
--
-- R5, DOUBLE COUNTING, is handled by construction rather than by discipline:
-- `combat.mode` selects exactly one path, and `admitReport`'s GATE 0 refuses
-- the other's by name before any other check runs. Every observation path goes
-- through that one door, so flipping the mode cannot leave both live -- and a
-- handler added later inherits the interlock instead of having to remember it.
-- Each handler repeats the check as well, only so the refusal is logged with
-- the reason that names the path.
--
-- ===========================================================================
-- BOUNDING THE AI (R6)
-- ===========================================================================
--
-- Native combat is not opt-in, so a bot inherits behaviour nobody chose: it may
-- chase a player out of the arena, or pick a fight with a vanilla NPC. Players
-- are already clamped by `client/main.lua` with `server/bounds.lua` as the
-- backstop; bots get the equivalent, in two escalating steps -- a soft `moveTo`
-- back inside, then a `setTransform` if that does not take. The soft step is
-- expected to fail in combat (`AIMoveToCommand.ignoreInCombat` is true, so the
-- behaviour tree may drop it), which is precisely why there is a hard step.
--
-- ===========================================================================
-- IDENTIFIERS
-- ===========================================================================
--
--   * PLAYER IDS ARRIVE AS STRINGS. `tonumber` at every entry point.
--   * NPC IDS ARE 64-BIT AND CROSS AS DECIMAL STRINGS. A uint64 does not
--     survive a Lua double past 2^53, so an npc id is NEVER passed through
--     `tonumber`. It is kept in the exact form the API returned it, and it is
--     looked up by its decimal-string key (`idKey`).
--   * A hot reload empties this VM's tables while the NPCs live on. Ownership
--     is always re-derived from `Open77.npcs.all()`, never from a table this VM
--     happens to hold, and orphans from a previous generation are reaped at
--     load.
--
local Config = DeathmatchConfig

-- ---------------------------------------------------------------------------
-- Defaults. Every one of these is overridden by DeathmatchConfig.bots.<key>
-- when the shared config grows the tree documented above.
-- ---------------------------------------------------------------------------
local Defaults = {
    enabled = true,
    fillWithBots = false,
    fillTarget = 6,
    maxPerInstance = nil,          -- nil = instance capacity minus one human
    difficulty = "standard",
    tickMs = 100,
    movementTickMs = 500,
    respawnDelayMs = 3000,
    health = 100.0,
    maxHealth = 100.0,
    streamingRadius = 200.0,
    streamingHysteresis = 40.0,
    despawnWhenUnobserved = false,
    spawnLiftMetres = 0.35,
    -- Under native combat this is not a switch this file owns: whether two bots
    -- fight is decided on the client, by the `aiMode = native` hostility sweep
    -- in `NpcReplication` (see `client/src/api/Hostility.hpp`). It survives only
    -- to gate the SCRIPTED path. The kill switch for the native one is
    -- `combat.mode = "scripted"`, which creates bots with `ai.tasks` and so
    -- takes them out of the sweep by construction.
    fightEachOther = true,
    labelled = true,
    excludeRoundsFromLadder = true,
    -- COSMETIC, and under native combat possibly harmful. A hostile gang record
    -- arrives with its own `primaryEquipment`, and forcing a weapon on it runs
    -- the player-proxy equip path against a native graph -- the same path whose
    -- comment in `NpcReplication.cpp` records a component-vtable corruption.
    -- `combat.forceWeapon` below decides whether it is applied; the default
    -- keeps today's behaviour because removing it is the unmeasured change.
    weaponRecord = "Items.Preset_Lexington_Default",
    namePrefix = "BOT ",
    tag = "BOT",

    -- -----------------------------------------------------------------------
    -- Which combat runs. THE MODE IS THE R5 INTERLOCK: exactly one report path
    -- is admitted. `admitReport`'s GATE 0 refuses the other's by name before
    -- any other check runs, so the interlock is a property of the one door
    -- every path goes through rather than a convention each handler is trusted
    -- to remember.
    -- -----------------------------------------------------------------------
    combat = {
        -- "native"   -- the engine fights. No tasks, no scripted gun, no
        --               scripted hit test. Damage in both directions arrives as
        --               an observed `gameHitEvent`.
        -- "scripted" -- the pre-2026-09-01 behaviour, kept only as a fallback
        --               for the case where the engine path cannot be made to
        --               report. It is not a supported gameplay mode: its "line
        --               of sight" is gone and it fires through walls.
        mode = "native",

        -- Apply `weaponRecord` to a native-combat bot at spawn and respawn.
        -- Set false to let the record's own equipment arm it, which is the more
        -- faithful configuration and the safer one for the vtable warning
        -- above. A/B this in game before changing the default: a bot that
        -- closes to MELEE is a bot with no gun drawn.
        forceWeapon = true,

        -- Bot -> player, the engine's own number.
        incoming = {
            -- Use the engine's computed damage. False takes `fallbackDamage`
            -- instead, which is the way back to a flat, predictable number.
            useEngineAmount = true,
            -- Multiplier applied before the clamp, so a whole roster can be
            -- softened without touching any record.
            scale = 1.0,
            -- The clamp, and it is not optional. A gang record's rifle is
            -- priced for a levelled solo player, not for a 100-point deathmatch
            -- scale; unclamped, a single burst is a kill.
            maxPerHit = 34.0,
            fallbackDamage = 18.0,
            -- Per player, per second, the same class of bound the outgoing path
            -- has. This one exists because the number is the ENGINE's and no
            -- gate upstream of it knows what a gang record will charge.
            maxDamagePerSecond = 90.0,
            -- Cadence floor per (bot, victim) pair. A shotgun's pellets already
            -- coalesce in the client drain; this catches the rest.
            minIntervalMs = 90,
        },

        -- -------------------------------------------------------------------
        -- The leash (R6). Native combat can walk a bot out of the arena chasing
        -- somebody, and no task stream is holding it any more.
        -- -------------------------------------------------------------------
        leash = {
            enabled = true,
            -- How often a bot's containment is judged. 2 Hz: a leash is not a
            -- wall, and the client-side player clamp already runs at 60 Hz for
            -- the case that has to feel like geometry.
            intervalMs = 500,
            -- Consecutive readable samples outside the zone before the SOFT
            -- step: a `moveTo` back to the nearest legal point. Expected to be
            -- ignored while the bot is in combat, which is why it is not the
            -- only step.
            softSamples = 4,
            -- Further consecutive samples outside before the HARD step: a
            -- `setTransform`. This revokes the simulation lease and bumps the
            -- authority epoch, so it is deliberately slow to arrive.
            hardSamples = 12,
            -- How far inside the boundary a corrected bot is placed.
            insetMetres = 1.5,
            -- Beyond this the bot is not leashed but DESTROYED and respawned on
            -- a surveyed mark. A bot ninety metres away did not lean on the
            -- wall; it fell, or it followed somebody into another district, and
            -- dragging it back would land it inside geometry.
            teleportLimitM = 60.0,
        },

        -- -------------------------------------------------------------------
        -- SEEK. Why it exists and why it is safe is in `tickSeek`; these are
        -- the fallbacks for a `shared/config.lua` that predates it.
        --
        -- THEY ARE NOT OPTIONAL. `combatSetting(name, group)` falls back to
        -- `Defaults.combat[group][name]`, so a key present in the code and
        -- absent from BOTH tables raises on an index of nil inside the tick.
        -- Every key `tickSeek` reads has an entry here.
        -- -------------------------------------------------------------------
        -- -------------------------------------------------------------------
        -- RESPAWN PACING. The crash fix; `respawnBot` and `createBot` carry the
        -- argument. Same rule as the seek block: every key read has an entry
        -- here, because `combatSetting` falls back to `Defaults.combat[group]`.
        -- -------------------------------------------------------------------
        respawn = {
            mode = "rebuild",
            corpseLingerMs = 1200,
            spawnSettleMs = 5000,
            spawnSpacingMs = 400,
        },

        seek = {
            enabled = true,
            intervalMs = 6000,
            preferBots = true,
            maxSuitors = 2,
            combatQuietMs = 5000,
            arriveM = 14.0,
            -- 130, matching shared/config.lua: the arena team clusters sit
            -- 98-117 m apart, so 90 refused every arena opponent. See the
            -- comment on the shipped value for the measurement.
            maxSeekM = 130.0,
            speed = "run",
            acceptanceRadiusM = 4.0,
            timeoutMs = 20000,
            priority = 20,
            seekPlayers = true,
            patrol = true,
        },
    },

    -- Knobs the shipped profile shape does not carry.
    shotIntervalMs = 180,
    moveRetickMs = 1000,
    moveRepathDistanceM = 3.0,
    patrolArrivalM = 3.0,
    maxVerticalM = 10.0,
    headshotChance = 0.10,
    headshotMultiplier = 2.0,

    -- THREE GANGS -- and, as of 2026-09-01, three gangs for VARIETY rather than
    -- for hostility.
    --
    -- The original comment here said the engine's attitude matrix would answer
    -- "does Maelstrom shoot Valentinos" for us. It was never measured. It has
    -- been now, and the answer is worse than "no": all 14 cross-gang pairs read
    -- `before=friendly` in the client log. The matrix made the three gangs
    -- ALLIES, and a friendly attitude is exactly the state measured on
    -- 2026-08-03 as friendly-fire immunity. So this roster was not failing to
    -- make bots fight -- it was the thing PREVENTING it, and adding more gang
    -- records would have made it worse.
    --
    -- Hostility is now stated rather than hoped for. Every `aiMode = native`
    -- NPC of a routing bucket is made explicitly hostile to every other one on
    -- every client, by `Api::Hostility` from `NpcReplication`'s sweep -- a
    -- per-agent `SetAttitudeTowards` override that does not consult the group
    -- matrix at all. The roster may therefore be one template or ten without
    -- changing whether bots fight; it changes only what they look like.
    --
    -- `civilian_female_relaxed_01` is NOT here and must never be: it resolves to
    -- `Character.Panam`, tagged `Invulnerable`, measured unshootable, and known
    -- to corrupt a component vtable when the weapon path runs against her
    -- native graph.
    templates = {
        "hostile_female_ranged_lab",   -- Maelstrom
        "gang_valentinos_ranged_01",   -- Valentinos
        "gang_tygerclaws_ranged_01",   -- Tyger Claws
    },

    callsigns = {
        "Ash", "Bolt", "Cinder", "Dagger", "Ember", "Flint", "Grit", "Husk",
        "Iron", "Jolt", "Kite", "Lash", "Mote", "Nail", "Onyx", "Pike",
        "Quill", "Rust", "Slag", "Tack", "Umber", "Vex", "Wire", "Xenon",
    },

    damage = {
        -- Engine hit reports: the `deathmatch:npcHit` path. ON under
        -- `combat.mode = "native"`, and `admitReport` refuses it outright under
        -- `"scripted"` regardless of this flag.
        acceptEngineHitReports = true,
        -- The old client-inferred aim ray. OFF, and the reason is R5: the day a
        -- second observation path lands, a mode still running the first credits
        -- every shot twice. `admitReport` also refuses it under `"native"`, so
        -- the two can never be live together even if both flags say true.
        acceptAimRayReports = false,
        acceptTargetedReports = false,
        requireVerifiedWeapon = true,
        -- SCRIPTED MODE ONLY: how far a scripted bot may shoot. 120 m spanned
        -- the whole surveyed arena, so range excluded nothing and a bot could
        -- kill from anywhere in Kabuki. A covered market fights at stall
        -- distance; this and the facing cone are what make a scripted bot
        -- something a player can see coming.
        maxRangeM = 38.0,
        -- THE REPORT GATE, and it must not be the same number. `maxRangeM`
        -- bounds what a scripted bot is ALLOWED to do; this bounds what a
        -- report is allowed to CLAIM, and the two are different questions. A
        -- player who lands a genuine engine hit on a bot across the whole arena
        -- has done nothing wrong, and refusing it because a scripted bot would
        -- not have been permitted that shot is a rule from the wrong system.
        -- Generous on purpose: this is a sanity bound against a report naming a
        -- body on the other side of the district, not a balance lever.
        reportMaxRangeM = 120.0,
        -- Half-angle the bot must have turned into before it may fire. Wide
        -- enough that it still shoots while strafing.
        fireConeDegrees = 40.0,
        -- DEAD, and kept only so an old `shared/config.lua` that still sets
        -- them does not read as a config error. They described the server's own
        -- ray/capsule hit test, which no longer exists: the engine performs the
        -- hit on the shooter's machine, with the real skeleton and the real
        -- cover, and reports the result. Nothing reads these four.
        hitRadiusM = 0.45,
        bodyLowM = 0.10,
        bodyHighM = 1.80,
        originToleranceM = 8.0,
        -- LIVE. `applyBotHit` still derives head-versus-torso from
        -- `hitZ - canonicalBotZ`, because a body part the client reports is a
        -- damage multiplier the client chooses.
        headMinM = 1.55,
        minReportIntervalMs = 45,
        maxReportsPerSecond = 16,
        maxDamagePerSecond = 220.0,
        defaultDamage = 26.0,
        headshotMultiplier = 2.0,
        weaponDamage = {
            lexington = 26.0, saratoga = 18.0, ajax = 22.0, copperhead = 20.0,
            masamune = 24.0, carnage = 58.0, satara = 62.0, grad = 90.0,
            nekomata = 95.0, defender = 16.0,
        },
    },

    -- Mirrors `DeathmatchConfig.bots.profiles` exactly, so the fallback and the
    -- shipped config are the same three personalities under the same three
    -- keys. `normalizeProfile` below expands either this shape or the richer
    -- explicit one into what the tick consumes.
    rangeBands = { close = 12.0, mid = 30.0, far = 70.0 },
    damagePerHit = 15.0,
    profiles = {
        relaxed = { reactionMs = 900, hitChance = { close = 0.55, mid = 0.30, far = 0.10 },
            burst = 3, reacquireMs = 1800, aggression = 0.4, fireIntervalMs = 900 },
        standard = { reactionMs = 550, hitChance = { close = 0.75, mid = 0.45, far = 0.18 },
            burst = 4, reacquireMs = 1200, aggression = 0.7, fireIntervalMs = 700 },
        veteran = { reactionMs = 300, hitChance = { close = 0.90, mid = 0.62, far = 0.30 },
            burst = 5, reacquireMs = 800, aggression = 0.9, fireIntervalMs = 500 },
    },
}

-- ---------------------------------------------------------------------------
-- Player-facing strings. ENGLISH, ONE TABLE (decision 16). Overridable from
-- `DeathmatchConfig.bots.strings` so the shared config can own them later
-- without touching this file.
-- ---------------------------------------------------------------------------
local Strings = {
    tag = "BOT",
    disabled = "Bots are disabled on this server.",
    noHost = "The instance kernel has not registered with the bot system yet.",
    noInstance = "You are not in an instance. Use: dm.bot <add|fill|clear|list> [n] [profile]",
    unknownInstance = "No such instance: %s",
    unknownProfile = "No such difficulty profile: %s",
    noSpawns = "Instance %s has no surveyed spawn marks; survey it before adding bots.",
    addFailed = "No bot could be created: %s",
    added = "Added %d bot(s) to instance %s on profile %s (%d bot(s) now).",
    filled = "Filled instance %s to capacity with %d bot(s) (%d bot(s) now).",
    alreadyFull = "Instance %s is already at capacity; no bot added.",
    cleared = "Removed %d bot(s) from %s.",
    listEmpty = "No bots.",
    usage = "usage: dm.bot <add [n] [profile] | fill | clear [all] | list | status> [instance=<id>]",
    ladderBlocked = "This round contains bots and will not be written to the ladder.",
}

-- ---------------------------------------------------------------------------
-- Config access. Read lazily so a hot reload of shared/config.lua is picked up
-- without restarting anything, and so this file works before the key exists.
-- ---------------------------------------------------------------------------
local function root()
    local configured = Config ~= nil and Config.bots or nil
    if type(configured) == "table" then return configured end
    return Defaults
end

local function setting(name)
    local value = root()[name]
    if value == nil then return Defaults[name] end
    return value
end

local function damageSetting(name)
    local configured = root().damage
    if type(configured) == "table" and configured[name] ~= nil then
        return configured[name]
    end
    return Defaults.damage[name]
end

local function profiles()
    local configured = root().profiles
    if type(configured) == "table" and next(configured) ~= nil then return configured end
    return Defaults.profiles
end

--- `bots.combat.<name>`, and `bots.combat.<group>.<name>` for the two nested
--- tables. Read lazily like everything else here, so a hot reload of
--- shared/config.lua takes effect without restarting the resource.
local function combatSetting(name, group)
    local configured = root().combat
    if type(configured) == "table" then
        if group == nil then
            if configured[name] ~= nil then return configured[name] end
        else
            local nested = configured[group]
            if type(nested) == "table" and nested[name] ~= nil then return nested[name] end
        end
    end
    if group == nil then return Defaults.combat[name] end
    return Defaults.combat[group][name]
end

--- Is the engine driving this mode's combat?
---
--- Everything that must not touch a combat bot asks this, and it is a string
--- comparison rather than a boolean so a third mode can exist later without
--- every call site becoming a negation.
local function nativeCombat()
    return tostring(combatSetting("mode") or "native") ~= "scripted"
end

-- ---------------------------------------------------------------------------
-- Profile normalisation.
--
-- The shipped config describes a personality compactly -- reaction, three hit
-- chances against three named range bands, a burst length, a reacquire time, an
-- aggression scalar and an inter-burst interval. The tick needs that expanded
-- into explicit numbers. This is the ONE place the two shapes meet, and it also
-- accepts an already-explicit profile, so a future config can be more precise
-- without a code change.
--
-- `aggression` is the interesting one: it is a single 0..1 dial for how a bot
-- carries itself, and it drives BOTH the movement speed and the distance the
-- bot tries to hold. A timid bot walks and stays at 16 m; a relentless one
-- sprints and closes to 7 m. That is the whole "movement aggression" knob the
-- plan asks for, and it stays one number in the config.
-- ---------------------------------------------------------------------------
local normalizedCache = {}

local function expandBands(raw)
    if type(raw.bands) == "table" and #raw.bands > 0 then return raw.bands end
    local chance = raw.hitChance
    if type(chance) ~= "table" then return nil end
    local bands = setting("rangeBands")
    if type(bands) ~= "table" then bands = Defaults.rangeBands end
    -- Ordered by ascending maxM; the first band covering the distance wins and
    -- anything past the last band is out of range.
    return {
        { maxM = tonumber(bands.close) or 12.0, chance = tonumber(chance.close) or 0.0 },
        { maxM = tonumber(bands.mid) or 30.0, chance = tonumber(chance.mid) or 0.0 },
        { maxM = tonumber(bands.far) or 70.0, chance = tonumber(chance.far) or 0.0 },
    }
end

local function normalizeProfile(key, raw)
    local aggression = tonumber(raw.aggression) or 0.6
    if aggression < 0.0 then aggression = 0.0 elseif aggression > 1.0 then aggression = 1.0 end

    local bands = expandBands(raw)
    if bands == nil then bands = expandBands(Defaults.profiles.standard) end
    local far = 70.0
    if bands ~= nil and #bands > 0 then far = tonumber(bands[#bands].maxM) or 70.0 end

    local burst = math.max(1, math.floor(tonumber(raw.burst) or 4))
    local reacquireMs = math.floor(tonumber(raw.reacquireMs) or 1200)

    local movement = type(raw.movement) == "table" and raw.movement or {}
    local speed = movement.speed
    if speed == nil then
        if aggression >= 0.8 then speed = "sprint"
        elseif aggression >= 0.5 then speed = "run"
        else speed = "walk" end
    end

    return {
        key = key,
        label = tostring(raw.label or string.upper(tostring(key))),
        reactionMs = math.floor(tonumber(raw.reactionMs) or 550),
        reacquireMs = reacquireMs,
        loseTargetMs = math.floor(tonumber(raw.loseTargetMs) or (reacquireMs * 2)),
        shotIntervalMs = math.floor(tonumber(raw.shotIntervalMs)
            or tonumber(setting("shotIntervalMs")) or Defaults.shotIntervalMs),
        burstCooldownMs = math.floor(tonumber(raw.burstCooldownMs)
            or tonumber(raw.fireIntervalMs) or 700),
        burstMin = math.floor(tonumber(raw.burstMin) or burst),
        burstMax = math.floor(tonumber(raw.burstMax) or burst),
        damage = tonumber(raw.damage) or tonumber(setting("damagePerHit"))
            or Defaults.damagePerHit,
        headshotChance = tonumber(raw.headshotChance)
            or tonumber(setting("headshotChance")) or Defaults.headshotChance,
        headshotMultiplier = tonumber(raw.headshotMultiplier)
            or tonumber(setting("headshotMultiplier")) or Defaults.headshotMultiplier,
        maxRangeM = tonumber(raw.maxRangeM) or far,
        acquireRangeM = tonumber(raw.acquireRangeM) or (far * 1.1),
        -- SCRIPTED MODE ONLY, and it was a dead knob until now: `facingTarget`
        -- reads `profile.fireConeDegrees`, this function never emitted the key,
        -- so the configured value was unreachable and the hardcoded 40 degrees
        -- always won. A setting that silently does nothing is worse than an
        -- absent one, because it gets tuned and believed.
        fireConeDegrees = tonumber(raw.fireConeDegrees)
            or tonumber(damageSetting("fireConeDegrees")) or 40.0,
        maxVerticalM = tonumber(raw.maxVerticalM) or tonumber(setting("maxVerticalM"))
            or Defaults.maxVerticalM,
        bands = bands,
        movement = {
            speed = speed,
            aggression = aggression,
            -- 16 m at aggression 0, 7 m at aggression 1.
            preferredRangeM = tonumber(movement.preferredRangeM) or (16.0 - 9.0 * aggression),
            repathIntervalMs = math.floor(tonumber(movement.repathIntervalMs)
                or tonumber(setting("moveRetickMs")) or Defaults.moveRetickMs),
            repathDistanceM = tonumber(movement.repathDistanceM)
                or tonumber(setting("moveRepathDistanceM")) or Defaults.moveRepathDistanceM,
            patrolArrivalM = tonumber(movement.patrolArrivalM)
                or tonumber(setting("patrolArrivalM")) or Defaults.patrolArrivalM,
        },
    }
end

--- Resolve a profile key to an expanded profile. Returns profile, resolvedKey.
--- The cache is invalidated whenever the raw table identity changes, so editing
--- shared/config.lua and hot-reloading picks the new numbers up.
local function profileFor(key)
    local table_ = profiles()
    local resolved = key
    local raw = resolved ~= nil and table_[resolved] or nil
    if raw == nil then
        resolved = setting("difficulty") or Defaults.difficulty
        raw = table_[resolved]
    end
    if raw == nil then
        resolved = "standard"
        raw = table_[resolved] or Defaults.profiles.standard
    end

    local cached = normalizedCache[resolved]
    if cached ~= nil and cached.raw == raw then return cached.profile, resolved end
    local profile = normalizeProfile(resolved, raw)
    normalizedCache[resolved] = { raw = raw, profile = profile }
    return profile, resolved
end

--- Player-facing text. `DeathmatchConfig.strings.bots.<key>` wins if it exists,
--- then `DeathmatchConfig.bots.strings.<key>`, then the local table. All three
--- are English; there is exactly one place per string.
local function text(key)
    local shared = Config ~= nil and Config.strings or nil
    if type(shared) == "table" and type(shared.bots) == "table"
        and type(shared.bots[key]) == "string" then
        return shared.bots[key]
    end
    local configured = root().strings
    if type(configured) == "table" and type(configured[key]) == "string" then
        return configured[key]
    end
    return Strings[key] or key
end

--- The visible bot label. `strings.hud.botTag` is already the HUD's word for it,
--- so the scoreboard, the kill feed and this file cannot disagree.
local function botTag()
    local shared = Config ~= nil and Config.strings or nil
    if type(shared) == "table" and type(shared.hud) == "table"
        and type(shared.hud.botTag) == "string" then
        return shared.hud.botTag
    end
    return tostring(setting("tag") or Strings.tag)
end

--- Timings the bot shares with the players' round, so a bot is not on a
--- different clock from the humans it fights.
--- What the config ASKED for, for diagnostics only. `/dm.bot list` prints both
--- this and the effective mode, so a refused "move" is visible in the readout
--- and not only in the log line `startOnce` emits.
local function configuredRespawnMode()
    return tostring(combatSetting("mode", "respawn") or "rebuild") == "move"
        and "move" or "rebuild"
end

--- Always `"rebuild"`. `"move"` is READ, NAMED and REFUSED.
---
--- WHY A REFUSAL AND NOT A DEFAULT. `"move"` is not a slower or uglier respawn,
--- it is a two-step placement racing a one-shot grant, and the losing case is
--- the exact bug this mode was written to escape -- a corpse on the ground with
--- a full health bar, re-killable, credited every time. `shared/config.lua`
--- carries the measured sequence; the short version is that the server's
--- `setTransform` arms ONE projection-adoption grant, the client's teleport is
--- asynchronous, and the 100 ms motion sample that fires in between spends the
--- grant on the corpse's position. Every subsequent report of the actual mark
--- is then a `motion_jump`: 195 of them in 30 minutes on the production PvP
--- server, 2026-09-01.
---
--- A gamemode cannot check which client binary it is talking to, and this knob
--- is client-coupled, so "wrong value in a config" has to be survivable rather
--- than merely discouraged. It is therefore refused HERE, once, loudly, instead
--- of being honoured into a broken state that only a packet log explains.
---
--- WHAT LIFTS THE REFUSAL. `NpcReplication` must withhold `NpcMotion` for a
--- replica whose `placementArmed` is still true, so a server-authored placement
--- is answered by the body that arrived rather than by the body that has not
--- moved yet. `respawnBot`'s PATH A is left standing and correct for that day;
--- it is simply unreachable until then.
local function respawnMode()
    return "rebuild"
end

local function respawnDelayMs()
    local configured = tonumber(root().respawnDelayMs)
    if configured ~= nil then return math.floor(configured) end
    local round = Config ~= nil and Config.round or nil
    configured = type(round) == "table" and tonumber(round.respawnDelayMs) or nil
    if configured ~= nil then return math.floor(configured) end
    return Defaults.respawnDelayMs
end

local function spawnLiftMetres()
    local configured = tonumber(root().spawnLiftMetres)
    if configured ~= nil then return configured end
    local map = Config ~= nil and Config.map or nil
    configured = type(map) == "table" and tonumber(map.spawnLiftMetres) or nil
    if configured ~= nil then return configured end
    return Defaults.spawnLiftMetres
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function log(message)
    print("[deathmatch/bots] " .. tostring(message))
end

--- Canonical decimal-string key for a 64-bit id.
---
--- NPC ids cross event boundaries as strings and come back from the API as Lua
--- integers. `tonumber` is forbidden on them -- past 2^53 a double silently
--- loses the low bits and two different bots collapse into one. This produces a
--- lossless key from either form and is the ONLY way an npc id is compared.
local function idKey(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind == "string" then
        local trimmed = value:match("^%s*(.-)%s*$")
        if trimmed == "" then return nil end
        return trimmed
    end
    if kind == "number" then
        if math.type ~= nil and math.type(value) == "integer" then
            return string.format("%d", value)
        end
        return string.format("%.0f", value)
    end
    return tostring(value)
end

--- Player ids arrive as strings from every engine entry point.
local function playerNumber(value)
    local id = tonumber(value)
    if id == nil or id <= 0 then return nil end
    return math.floor(id)
end

--- The platform raises a Lua error on an invalid npc id, an invalid enum or a
--- malformed task parameter -- and a bot id can go stale between the tick that
--- read it and the call that uses it. Every NPC API call therefore goes through
--- here, so one dead bot never takes down the tick.
local function safe(fn, ...)
    if type(fn) ~= "function" then return false, "no_function" end
    local ok, result, reason = pcall(fn, ...)
    if not ok then return false, tostring(result) end
    return result, reason
end

local function isFinite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function distance2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function distance3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Same normalisation the existing damage arbiter applies, so a weapon id
--- compares equal across the two paths.
local function normalizeWeaponId(value)
    if type(value) ~= "string" then return "" end
    local digits = string.lower(value):match("^0x([0-9a-f]+)$")
    if digits == nil then return "" end
    digits = digits:gsub("^0+", "")
    if digits == "" then return "" end
    return "0x" .. digits
end

-- ---------------------------------------------------------------------------
-- THE HOST CONTRACT
--
-- bots.lua owns bots and nothing else. Everything it needs to know about
-- instances, rounds, rosters and scoring comes through one indirection, so this
-- file has no opinion about how the kernel is organised.
--
-- THERE IS NOTHING TO WIRE. `defaultHost` below binds straight to
-- `Deathmatch.instances`, which already carries every concept this file needs
-- and calls a bot an `actor`. `DeathmatchBots.setHost{...}` overrides it, for a
-- test double or a different kernel; every hook is optional and a missing one
-- degrades to "no bots" rather than to a crash.
--
--   instance(instanceId)            -> instance view or nil
--   instanceOfPlayer(playerId)      -> instanceId or nil
--   playersIn(instanceId)           -> array of numeric human player ids
--   isPlayerAlive(playerId)         -> boolean
--   capacity(instanceId)            -> integer (defaults to 12, decision 13)
--   addParticipant(instanceId, participantId, info)
--   removeParticipant(instanceId, participantId, reason)
--   creditDamage(instanceId, attackerId, victimId, amount, info)
--   creditKill(instanceId, killerId, victimId, info)
--   verifiedWeaponId(playerId)      -> "0x..." the server issued, or nil
--   roundWeaponKey(instanceId)      -> the round weapon's config key
--   containsPoint(instanceId, point)  -> boolean, or nil when unknown
--   projectInside(instanceId, point, inset) -> { x, y, z, distance } or nil
--   notice(playerId, kind, key, ...)
--   tunable(name)                   -> live tunable value or nil
--
-- An instance view is a plain read-only table:
--
--   { id, bucket, zone, format, state, capacity,
--     spawns = { { position = {x,y,z}, heading = n }, ... },
--     marks = <optional patrol marks; defaults to spawns> }
--
-- WHAT THE KERNEL AND THE SCORING LAYER MUST DO IN RETURN -- two calls, and
-- both are easy to miss:
--
--   1. `DeathmatchBots.attackerId(raw)` ON EVERY ATTACKER AND KILLER ID.
--      bots.lua credits ONLY bot victims. When a bot damages or kills a PLAYER,
--      the platform's own `open77:playerDamaged` / `open77:playerKilled` fire
--      with `attacker = <npcId>` -- a 64-bit number that is not a participant
--      id and that `tonumber` would corrupt. This call maps it to the bot's
--      negative participant id and passes a real player id through unchanged.
--      Without it every bot kill lands uncredited. That one call is the whole
--      "no special case" promise of the synthetic negative id.
--
--   2. `DeathmatchBots.roundLadderEligible(instanceId)` IMMEDIATELY BEFORE THE
--      LADDER WRITE. Decision 12: excluded at the write, not filtered at the
--      read.
--
-- Optional, and free where they are used:
--
--   `DeathmatchBots.beginRound(instanceId, roundId)`  round.lua, at round start
--   `DeathmatchBots.reap(instanceId, reason)`         on instance close
--   `DeathmatchBots.decorateRow(row)`                 standings rows
--   `DeathmatchBots.tag(participantId)`               kill feed labels
--   `DeathmatchBots.backfill(instanceId)`             the Q5 automatic fill
-- ---------------------------------------------------------------------------
local host = nil

-- ---------------------------------------------------------------------------
-- THE DEFAULT HOST -- bound straight to the kernel `instances.lua` publishes.
--
-- `Deathmatch.instances` already carries the concept this file needs and calls
-- it by the right name: an instance owns `actors`, and `bindActor` /
-- `unbindActor` / `ofActor` / `resolve` exist precisely so the damage gate can
-- treat bot fire like player fire with no special case in the arbiter. So the
-- default host is not an abstraction over the kernel, it is a thin translation
-- into it, and `setHost` remains for a test double or a future kernel.
--
-- Everything here is resolved AT CALL TIME. Nothing is captured at load: a hot
-- reload rebuilds `Deathmatch` and a cached reference would point at the dead
-- generation's registry.
-- ---------------------------------------------------------------------------
local function kernel()
    -- Read at call time, never captured: a hot reload rebuilds `Deathmatch` and
    -- a cached reference would point at the dead generation's registry.
    local dm = Deathmatch
    if type(dm) ~= "table" then return nil end
    local instances = dm.instances
    if type(instances) ~= "table" then return nil end
    return dm, instances
end

--- The spawn marks a format draws from, flattened. `clusters` is two arrays --
--- one per team -- and a free-for-all bot may use either end, so both are
--- offered. No mark is invented, moved or interpolated on the way through.
--- INTEGRATION FIX 2026-08-31. This read `Config.map.spawns[spec.spawns]`,
--- which was true when it was written and is not any more: the ruling that
--- settled the two-maps collision moved ALL geometry into shared/kabuki.lua,
--- and `DeathmatchConfig.map` no longer exists. The old read did not error --
--- it returned nil, so every bot silently had no spawn marks at all and the
--- failure would have looked like a bot AI problem rather than a moved key.
--- Geometry now comes from DeathmatchKabuki, which is the single owner.
--- FIX 2026-08-31. An UNSURVEYED mark is not a coordinate, and this function used
--- to hand them out anyway. `kabuki.lua` ships every mark as an explicit
--- `{ position = nil, heading = 0.0 }` and a survey fills them in one at a time, so
--- a half-surveyed set is not an exotic state -- it is the normal one for the whole
--- of Phase 1, and the dump withholds `surveyed = true` precisely to say so.
--- `chooseSpawn` then read `candidate.position or candidate` on such a mark, fell
--- through to the mark table itself and raised
--- `attempt to perform arithmetic on a nil value (field 'x')` on every bot tick.
--- Every other consumer of the same geometry already filters -- main.lua's
--- `surveyedMarks`, `Arena.cluster` -- so the fix belongs here, at this file's one
--- geometry read, rather than as a guard at each use.
local function surveyedOnly(marks)
    local out = {}
    for _, mark in ipairs(marks) do
        if type(mark) == "table" and DeathmatchKabuki.point(mark.position) ~= nil then
            out[#out + 1] = mark
        end
    end
    return out
end

local function marksForFormat(format)
    local kabuki = DeathmatchKabuki
    local spec = Config ~= nil and Config.formats or nil
    spec = type(spec) == "table" and spec[format] or nil
    if type(kabuki) ~= "table" or type(kabuki.spawns) ~= "table" or spec == nil then
        return nil
    end
    -- `spec.spawns` names a set in kabuki.spawns ("ffa", or a per-format team
    -- entry). Fall back to the format key itself, then to the FFA marks, which
    -- are the only ones guaranteed to exist for a free-for-all bot.
    local set = kabuki.spawns[spec.spawns or format]
        or kabuki.spawns[format]
        or kabuki.spawns.ffa
    if type(set) ~= "table" then return nil end
    if #set > 0 then
        local marks = surveyedOnly(set)
        return #marks > 0 and marks or nil
    end
    -- A table of named clusters rather than an array of marks.
    local flat = {}
    for _, cluster in pairs(set) do
        if type(cluster) == "table" then
            for _, mark in ipairs(surveyedOnly(cluster)) do flat[#flat + 1] = mark end
        end
    end
    if #flat == 0 then return nil end
    return flat
end

local defaultHost = {}

function defaultHost.instance(instanceId)
    local _, instances = kernel()
    if instances == nil then return nil end
    local id = tonumber(instanceId)
    local record = id ~= nil and instances.registry[id] or nil
    if record == nil or record.closed then return nil end
    return {
        id = record.id,
        bucket = record.bucket,
        zone = record.zone,
        format = record.format,
        state = record.round ~= nil and record.round.state or "open",
        capacity = record.capacity,
        spawns = marksForFormat(record.format),
    }
end

function defaultHost.instances()
    local _, instances = kernel()
    if instances == nil then return {} end
    local ids = {}
    for id, record in pairs(instances.registry) do
        if not record.closed then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

function defaultHost.instanceOfPlayer(playerId)
    local _, instances = kernel()
    if instances == nil then return nil end
    local record = instances.of(playerId)
    if record == nil or record.closed then return nil end
    return record.id
end

function defaultHost.playersIn(instanceId)
    local _, instances = kernel()
    if instances == nil then return {} end
    local id = tonumber(instanceId)
    local record = id ~= nil and instances.registry[id] or nil
    if record == nil then return {} end
    return instances.members(record)
end

function defaultHost.capacity(instanceId)
    local _, instances = kernel()
    if instances == nil then return nil end
    local id = tonumber(instanceId)
    local record = id ~= nil and instances.registry[id] or nil
    return record ~= nil and record.capacity or nil
end

--- Binding the bot into `instance.actors` is what makes the damage gate accept
--- its fire without a special case, so it is not optional bookkeeping.
---
--- TWO keys are bound, and the second one is the whole reason bot fire lands.
--- `Instances.damageGate` resolves `event.attacker` through `resolve` ->
--- `ofActor`, which keys on a NUMBER -- and a bot's shot arrives attributed to
--- its NPC id (12884901889 was measured), not to its participant id. So the npc
--- id is bound as a SECONDARY actor key for the same instance, and the gate
--- then sees the shot as coming from inside the victim's instance with no
--- change anywhere else.
---
--- That alias is only bound when the id survives the number round trip, which
--- is checked at creation, not assumed: a 64-bit id past 2^53 does not survive
--- a Lua double, and binding a truncated key would silently let one bot answer
--- for another. When it does not survive, the alias is skipped and the kernel
--- must call `DeathmatchBots.attackerId` -- which it should be doing anyway.
function defaultHost.addParticipant(instanceId, participantId, info)
    local dm, instances = kernel()
    if instances == nil then return end
    local id = tonumber(instanceId)
    local record = id ~= nil and instances.registry[id] or nil
    if record == nil then return end
    instances.bindActor(participantId, record)
    local alias = type(info) == "table" and info.npcAlias or nil
    if alias ~= nil then instances.bindActor(alias, record) end
    local scoring = dm.scoring
    if type(scoring) == "table" and type(scoring.addParticipant) == "function" then
        scoring.addParticipant(record, participantId, info)
    end
end

--- A bot has ceased to exist. Unbind it, mark its row, and TELL THE MATCH.
---
--- THE ARENA CALL IS NOT BOOKKEEPING, and it is here rather than in `destroyBot`
--- because this is the one funnel every disappearance already goes through --
--- `/dm.bot clear`, an instance closing, a body the client reaped
--- (`npc_vanished`), and the platform's own `onNpcRemoved`. A seam per caller is
--- a seam the next caller forgets.
---
--- MEASURED 2026-09-01, in game. `dm.bot clear all` during a live 1v1 removed
--- the body and left the participant on the arena roster: `alive 1-1`, `bots=1`,
--- `side 2: BOT 1 [BOT]`, with nothing standing in the world. Side 2 could
--- therefore never be wiped, every round ran its full 120 s to a `time_limit`
--- draw, and a best-of-five in that state never resolves at all. The arena had
--- no way to hear about it: a destroyed bot raises no death, and `aliveByTeam`
--- is a cached number that only `refreshAlive` moves.
---
--- Scoring is told FIRST and the arena second, deliberately. The standings row
--- survives a departure -- it carries the kills the bot took and erasing it
--- would rewrite the round the survivors just played -- while the arena drops
--- the ROSTER entry, which is a different table answering a different question:
--- "who is still in this round". Reversing the order would have the arena
--- resolve a match against a scoreboard that had not yet recorded the leaver.
function defaultHost.removeParticipant(instanceId, participantId, reason, npcAlias)
    local dm, instances = kernel()
    if instances == nil then return end
    instances.unbindActor(participantId)
    if npcAlias ~= nil then instances.unbindActor(npcAlias) end
    local scoring = dm.scoring
    if type(scoring) == "table" and type(scoring.removeParticipant) == "function" then
        scoring.removeParticipant(instanceId, participantId, reason)
    end
    local arena = dm.arena
    if type(arena) == "table" and type(arena.participantGone) == "function" then
        -- `pcall` because this runs inside `destroyBot`, which runs inside a
        -- `pairs` walk of the bot table in `DeathmatchBots.clear`: a raise here
        -- would abandon that walk half way and leak every bot after it.
        local ok, err = pcall(arena.participantGone, instanceId, participantId, reason)
        if not ok then
            log(("arena notification raised for bot %s: %s"):format(
                tostring(participantId), tostring(err)))
        end
    end
end

--- Move the NPC ACTOR ALIAS from one body to another without disturbing the
--- scoreboard row.
---
--- Respawn now rebuilds the engine body (see `respawnBot`), so a bot's npc id
--- changes across a death while its participant id does not. The alias is what
--- `Instances.damageGate` resolves an attacker through, so it must follow the
--- live body -- but `removeParticipant` would mark the scoring row `left` and
--- `addParticipant` would re-add it, which is a scoreboard flicker on every
--- respawn. This is the narrow operation neither of those is.
--- Nothing needs to be told about the new npc id itself: the scoring row does
--- not store one, it asks `DeathmatchBots.npcIdOf(participantId)` when it wants
--- a position (`scoring.lua:313`), and that reads the live record.
function defaultHost.rebindNpc(instanceId, participantId, oldAlias, newAlias)
    local _, instances = kernel()
    if instances == nil then return end
    if oldAlias ~= nil then instances.unbindActor(oldAlias) end
    if newAlias == nil then return end
    local id = tonumber(instanceId)
    local record = id ~= nil and instances.registry[id] or nil
    if record ~= nil then instances.bindActor(newAlias, record) end
end

function defaultHost.creditDamage(instanceId, attackerId, victimId, amount, info)
    local dm = kernel()
    local scoring = dm ~= nil and dm.scoring or nil
    if type(scoring) == "table" and type(scoring.creditDamage) == "function" then
        scoring.creditDamage(instanceId, attackerId, victimId, amount, info)
    end
end

function defaultHost.creditKill(instanceId, killerId, victimId, info)
    local dm = kernel()
    local scoring = dm ~= nil and dm.scoring or nil
    if type(scoring) == "table" and type(scoring.creditKill) == "function" then
        scoring.creditKill(instanceId, killerId, victimId, info)
    end
end

--- The verified TweakDBID the server itself issued this player this round. The
--- kernel keeps it per instance, which is exactly the scope the check needs.
function defaultHost.verifiedWeaponId(playerId)
    local _, instances = kernel()
    if instances == nil then return nil end
    local record = instances.of(playerId)
    if record == nil then return nil end
    local id = tonumber(playerId)
    return id ~= nil and record.weaponIds[id] or nil
end

--- Does the loadout book accept this weapon from this player -- ANY of the
--- three issued slots, not just the primary?
---
--- `verifiedWeaponId` above answers a narrower question: it returns slot 1 only,
--- because `loadout.lua` records the verified id per slot but the instance
--- kernel keeps just the primary. Gate 2 used it while claiming to enforce "the
--- same weapon rule the PvP arbiter enforces" -- and the arbiter has used the
--- whole set since L2. The gap was silent and one-sided: a Unity round or a
--- katana swing landed on a PLAYER and was refused `wrong_weapon` against a BOT.
function defaultHost.weaponAccepted(playerId, weaponId)
    local dm, instances = kernel()
    if dm == nil or instances == nil then return nil end
    local book = dm.loadout
    if type(book) ~= "table" or type(book.accepts) ~= "function" then return nil end
    local record = instances.of(playerId)
    if record == nil then return nil end
    local ok = book.accepts(record, playerId, weaponId)
    return ok == true
end

--- The catalogue key of the weapon this player actually fired, for pricing.
function defaultHost.weaponKey(playerId, weaponId)
    local dm, instances = kernel()
    if dm == nil or instances == nil then return nil end
    local book = dm.loadout
    if type(book) ~= "table" or type(book.keyFor) ~= "function" then return nil end
    local record = instances.of(playerId)
    if record == nil then return nil end
    return book.keyFor(record, playerId, weaponId)
end

--- Is this point inside the instance's arena zone? `nil` means CANNOT TELL.
---
--- Three answers, never two, and the leash depends on the distinction: an
--- unsurveyed zone, a missing bounds module or an unreadable position must not
--- read as "the bot is outside", or every bot in an unsurveyed arena gets
--- dragged to a boundary that was never measured.
---
--- This is the same `Bounds.contains` the player clamp and the player backstop
--- use. One containment predicate for the whole mode: two that can disagree is
--- a bug waiting for a Friday.
--- NOT `Bounds.contains`, and the difference is the whole reason this is three
--- answers rather than two. `contains` collapses to `volumeId ~= nil`, so an
--- UNSURVEYED zone -- where no volume can answer at all -- comes back `false`,
--- indistinguishable from a bot standing in the street. Every bot in an
--- unsurveyed arena would then be leashed, and then respawned, forever.
---
--- `Bounds.locate` keeps the distinction in its second return, and the three
--- reasons that mean "cannot tell" are `no_position`, `zone_empty` and
--- `not_surveyed`, plus the `outside_partial:` family for a half-surveyed zone.
--- That classification is bounds.lua's, and it is repeated here rather than
--- imported because bounds.lua keeps it in a file-local table -- if a fourth
--- reason is ever added there, it has to be added here too.
local CANNOT_TELL = {
    no_position = true,
    no_volumes = true,
    zone_empty = true,
    not_surveyed = true,
}

function defaultHost.containsPoint(instanceId, point)
    local dm = kernel()
    local bounds = dm ~= nil and dm.bounds or nil
    if type(bounds) ~= "table" or type(bounds.locate) ~= "function" then return nil end
    local view = defaultHost.instance(instanceId)
    local zone = view ~= nil and view.zone or nil
    if zone == nil then return nil end

    local volumeId, reason = bounds.locate(point, zone)
    if volumeId ~= nil then return true end
    reason = tostring(reason or "")
    if reason == "" or CANNOT_TELL[reason] or reason:find("^outside_partial") then
        return nil
    end
    return false
end

--- The nearest legal point inside the zone, plus how far outside the input was.
---
--- Returns ONE table, `{ x, y, z, distance }`, or nil -- deliberately not two
--- values. `hostCall` funnels every host call through `pcall` and returns a
--- single result, so a two-value contract here would silently deliver a nil
--- distance to every caller, and a distance that is always nil reads as zero:
--- the "too far to drag, respawn instead" branch of the leash would never fire
--- and its log line would report every bot as 0.0 m outside.
function defaultHost.projectInside(instanceId, point, inset)
    local dm = kernel()
    local bounds = dm ~= nil and dm.bounds or nil
    if type(bounds) ~= "table" or type(bounds.project) ~= "function" then return nil end
    local view = defaultHost.instance(instanceId)
    local zone = view ~= nil and view.zone or nil
    if zone == nil then return nil end
    local target, _, distance = bounds.project(point, zone, inset)
    if target == nil then return nil end
    return {
        x = target.x, y = target.y, z = target.z,
        distance = tonumber(distance) or 0.0,
    }
end

--- Which side of an arena match a PARTICIPANT holds -- player or bot -- or nil
--- outside a match.
---
--- THE ARENA IS ASKED, not this file's own `bot.side`, and that is the point.
--- `Open77.combat.setTeam` cancels friendly fire between PLAYERS, and the two
--- damage paths a bot is on -- `Open77.players.damage` and
--- `Open77.npcs.applyDamage` -- do not travel it. So the mode has to answer
--- "are these two on the same side" itself, and it must get the same answer for
--- every pair: player/bot, bot/bot, and the player/player case the platform
--- already handles. `arena.match.sides` is the one table that knows all three.
function defaultHost.arenaSide(participantId)
    local dm = kernel()
    local arena = dm ~= nil and dm.arena or nil
    if type(arena) ~= "table" or type(arena.sideOf) ~= "function" then return nil end
    return arena.sideOf(participantId)
end

function defaultHost.roundWeaponKey(instanceId)
    local _, instances = kernel()
    if instances == nil then return nil end
    local id = tonumber(instanceId)
    local record = id ~= nil and instances.registry[id] or nil
    local round = record ~= nil and record.round or nil
    local weapon = type(round) == "table" and round.weapon or nil
    return type(weapon) == "table" and weapon.key or nil
end

function defaultHost.isPlayerAlive(playerId)
    if Open77.players.isDead == nil then return nil end
    local dead = Open77.players.isDead(playerId)
    if dead == nil then return nil end
    return dead ~= true
end

--- How long this player's spawn shield still has to run, in milliseconds.
---
--- THE SHIELD ALREADY EXISTED and the bots simply never asked. `round.lua`
--- calls `DM.holdProtection` on every join and every respawn, and the HUD
--- already draws the countdown -- but the shield is enforced by the damage
--- ARBITER, and a bot's gun is `Open77.players.damage` called directly, which
--- does not pass through it. So the owner spawned under a visible shield and
--- was killed through it, repeatedly.
---
--- Note what this is NOT: the life-state phase. There is no `protected` phase --
--- the phases are alive / dead / revivepending / respawnpending / recovering --
--- so a freshly respawned player reads `alive` while still shielded, and a gate
--- built on the phase alone (as the first attempt was) refuses nothing.
function defaultHost.protectionRemaining(playerId)
    local dm = kernel()
    if dm == nil or type(dm.protectionRemaining) ~= "function" then return nil end
    return dm.protectionRemaining(playerId)
end

function defaultHost.notice(playerId, kind, key, ...)
    local dm = kernel()
    if dm ~= nil and type(dm.notice) == "function" then
        dm.notice(playerId, kind, key, ...)
    end
end

function defaultHost.tunable(name)
    local dm = kernel()
    local tune = dm ~= nil and dm.tune or nil
    if type(tune) ~= "table" then return nil end
    -- `tune.<key>` is a call behind a metatable, not a field: read it here, at
    -- the point of use, never into a file-scope local.
    return tune[name]
end

local function activeHost()
    if host ~= nil then return host end
    if kernel() ~= nil then return defaultHost end
    return nil
end

local function hostCall(name, ...)
    local target = activeHost()
    if target == nil then return nil end
    local fn = target[name]
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if not ok then
        log(("host.%s raised: %s"):format(name, tostring(result)))
        return nil
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Registry.
--
-- `bots` is BEHAVIOUR state, never authority. Ownership of a projected NPC is
-- always re-derived from `Open77.npcs.all()`, which the platform already
-- filters to this resource: a hot reload hands the successor generation an
-- empty table while the NPCs are still standing in the world, and any loop that
-- iterated this table instead would silently leak every bot it owned.
-- ---------------------------------------------------------------------------
local bots = {}          -- [participantId] = bot record
local botByNpc = {}      -- [npcKey decimal string] = bot record
local nextParticipant = -1
local nextCallsign = 0
local roundTaint = {}    -- [instanceId] = { roundId = ..., tainted = true }
local reports = {}       -- [playerId] = rate/duplicate/dps state
-- Cadence and damage-per-second state for damage a body RECEIVES from bots.
-- Keyed by player id for a human victim and by the string `"bot:<id>"` for a
-- bot victim: negating a bot's participant id would land it on a real player's
-- key, and the two would eat each other's budget.
local incoming = {}      -- [victimKey] = { startedAtMs, amount, pairs = {...} }
local decisionLog = {}
local started = false

-- ---------------------------------------------------------------------------
-- THE THREE GATES ON CREATING AN ENGINE BODY (the 2026-09-01 crash)
--
-- A body is a `DynamicEntityService` entry on the client, and that service has
-- exactly one way to destroy one: `Despawn(cyberId)`. It has NO cancel by
-- request id. So a spawn that is still in flight -- submitted, no cyber id yet
-- -- cannot be called off, and `NpcReplication::Despawn` does the only thing it
-- can when a removal arrives in that window: it drops `replica.spawnRequest`
-- and returns. The engine then finishes the spawn, registers the entity, and
-- NOTHING EVER DESPAWNS IT. The body stands in the world running native AI with
-- no replica, no lease and no owner.
--
-- The 2026-09-01 session ended with 46 spawn submissions against 20 despawn
-- submissions and a crash reading a freed pointer, two seconds after a resource
-- hot swap. The swap is the worst case and the log shows why: the host prepares
-- the INCOMING VM before the outgoing one receives `onResourceStop`
-- (`server/main.lua` says so in as many words), so the new generation filled its
-- instance 1.1 s after the old generation's eleven despawns were submitted and
-- while five of them were still unconfirmed -- with a world transition running
-- underneath (`world epoch 2` in the same second).
--
-- These three gates make that sequence impossible from this side. They do not
-- repair the client-side gap, which is C++ and wants its own change; they
-- remove the paths that reach it.
--
--   stopping        this VM has had `onResourceStop`. It gets one more tick
--                   (`LuaResourceRuntime.Stop` calls `Tick` after emitting), and
--                   a body created in that tick is one the host is about to tear
--                   down -- the exact race.
--   settle window   after this VM starts, wait before creating anything, so the
--                   incoming generation is not spawning while the outgoing one's
--                   despawns are still in flight.
--   spacing         at most one body creation per `spawnSpacingMs` across the
--                   whole resource, so eleven simultaneous respawns become a
--                   paced stream rather than eleven concurrent spawn requests.
-- ---------------------------------------------------------------------------
local stopping = false
local vmStartedAtMs = nowMs()
local lastBodySpawnAtMs = 0

-- Arrival counters for the three engine report paths, tallied BEFORE any gate
-- and surfaced by `/dm.bot list`.
--
-- They exist because the diagnosis of "bots do not fight" was blocked on a
-- distinction the tree could not make: an empty server log is produced both by
-- an engine that never fired a shot and by a handler that refused every report
-- it got. `seen` counts what arrived; `applied` counts what survived. Equal and
-- zero blames the ENGINE (attitude, acquisition); `seen > 0` with
-- `applied == 0` blames THIS FILE, and the refusal reason is then in the log
-- beside it.
local engineHitsSeen = 0
local engineHitsApplied = 0
local incomingSeen = 0
local crossfireSeen = 0
local crossfireApplied = 0

-- The same reading, for the seek half of the mode. `issued` is a destination
-- the platform accepted; `refused` is one it did not, which is the only way to
-- tell "the bots are not being sent anywhere" apart from "the bots are being
-- sent somewhere and not going". `respawns` and `rebuilds` are the bug-2
-- readout: a respawn that never rebuilds a body is a corpse left standing in
-- the participant table.
local seekIssued = 0
local seekRefused = 0
local respawnsRun = 0
local respawnsFailed = 0
-- BODIES, AS OPPOSED TO RESPAWNS. `respawnsRun` says how often the death
-- transaction ran; it says nothing about whether a body was CREATED or an
-- existing one was RE-PLACED, and under `respawn.mode = "move"` those are the
-- two entirely different things it can mean.
--
-- The distinction had no readout at all until 2026-09-01, when a 3v3 filled
-- with five bots printed `1/6+10bot` and there was no counter anywhere that
-- could say whether ten bodies existed or one number was counting five twice.
-- (It was the number: see `Instances.botCount`.) Guessing cost an hour, so the
-- guess is now a measurement -- `bodies[created=N released=N live=N]` in
-- `/dm.bot`. `created` is every call to `Open77.npcs.create` this VM has made,
-- `released` every `npcs.remove`, and `live` is counted from the records at the
-- moment of the read. A match that holds its format is `created == live` once
-- it has filled; a match that is accumulating has `created` climbing per round
-- with `released` flat.
local bodiesCreated = 0
local bodiesReleased = 0

--- Bot records that currently hold an engine body. Counted at the read rather
--- than tracked, so it cannot drift away from the records the way a running
--- total can. A bot between `releaseBody` and its rebuild is deliberately NOT
--- counted: it has no body, which is the whole invariant the rebuild rests on.
local function liveBodies(instanceId)
    local key = instanceId ~= nil and tostring(instanceId) or nil
    local count = 0
    for _, bot in pairs(bots) do
        if bot.npcId ~= nil and (key == nil or tostring(bot.instanceId) == key) then
            count = count + 1
        end
    end
    return count
end
-- Body creations refused by the three gates above, by gate. A roster that never
-- fills reads as `spawnGate[stopping=0 settling=12 spacing=3]` and names its own
-- reason instead of looking like a broken spawn mark.
-- Spawns the pacing gate DEFERRED rather than refused.
--
-- The gates exist to stop the spawn/despawn churn that produced the
-- `puppet-install` crash, and they must stay. But `DeathmatchBots.add` looped
-- and BROKE on the first refusal, so with one body creation allowed per
-- `spawnSpacingMs`, `/dm.bot add 6` created exactly one bot and silently dropped
-- five -- which is what the owner saw as "there is only one bot in my game".
--
-- Pacing is a statement about RATE, not about total. So a refusal for spacing or
-- settling now parks the remainder here and the tick drains it at the permitted
-- rate; only a real refusal (no room, no marks, unknown instance) still ends the
-- request. `stopping` is deliberately NOT queued: a VM being torn down must not
-- leave work for a successor that will not own it.
-- ARENA. A parked entry carries the SIDE and the spawn CLUSTER it was asked
-- for, because a bot that arrives two seconds late still has to arrive on the
-- right half of the map holding the right half of the roster. Dropping them
-- would give a 3v3 a bot with no side, which the arena roster has no row for.
local pendingSpawns = {}   -- [n] = { instanceId, profileKey, side, marks, onCreated }

local spawnGateStopping = 0
local spawnGateSettling = 0
local spawnGateSpacing = 0

-- The one namespace, and global for the same reason `Deathmatch` is: the server
-- runtime installs no exports, so a shared global table in one Lua state is how
-- this resource's server scripts talk to each other. Guarded with `or` so the
-- file is re-entrant if it is ever loaded twice.
DeathmatchBots = DeathmatchBots or {}

local function allocateParticipantId()
    local id = nextParticipant
    nextParticipant = nextParticipant - 1
    return id
end

local function allocateName()
    local pool = setting("callsigns")
    if type(pool) ~= "table" or #pool == 0 then pool = Defaults.callsigns end
    nextCallsign = nextCallsign + 1
    local callsign = pool[((nextCallsign - 1) % #pool) + 1]
    local wrap = math.floor((nextCallsign - 1) / #pool)
    if wrap > 0 then callsign = callsign .. "-" .. tostring(wrap + 1) end
    return tostring(setting("namePrefix")) .. callsign
end

--- Deduplicated logging. A bot fires several times a second and a refusal that
--- logs every shot -- a victim inside their spawn-protection grace, say -- turns
--- a normal condition into a flooded log.
local function logThrottled(key, message)
    local at = nowMs()
    if decisionLog[key] ~= nil and at - decisionLog[key] < 2000 then return end
    decisionLog[key] = at
    log(message)
end

local function logDecision(playerId, reason, detail)
    local key = tostring(playerId) .. ":" .. tostring(reason)
    local at = nowMs()
    if decisionLog[key] ~= nil and at - decisionLog[key] < 2000 then return end
    decisionLog[key] = at
    log(("bot damage report rejected player=%s reason=%s detail=%s"):format(
        tostring(playerId), tostring(reason), tostring(detail)))
end

-- ---------------------------------------------------------------------------
-- Ladder exclusion (decision 12).
--
-- The predicate is consulted AT THE WRITE, not filtered at the read, and it is
-- STICKY for the round: clearing the bots halfway through does not launder the
-- result. It is also FAIL CLOSED -- an instance whose round the kernel never
-- announced keeps whatever taint it has, so a persistence layer that forgets to
-- call `beginRound` writes nothing rather than writing a bot round.
-- ---------------------------------------------------------------------------
local function taint(instanceId)
    if instanceId == nil then return end
    local key = tostring(instanceId)
    local entry = roundTaint[key]
    if entry == nil then
        entry = { roundId = nil, tainted = true }
        roundTaint[key] = entry
    else
        entry.tainted = true
    end
end

--- Called by the round layer when a new round starts in an instance.
function DeathmatchBots.beginRound(instanceId, roundId)
    if instanceId == nil then return end
    local key = tostring(instanceId)
    roundTaint[key] = { roundId = roundId, tainted = false }
    -- A round that starts with bots already standing in the arena is tainted
    -- from its first millisecond.
    for _, bot in pairs(bots) do
        if tostring(bot.instanceId) == key then
            roundTaint[key].tainted = true
            break
        end
    end
end

--- THE PREDICATE THE PERSISTENCE LAYER CALLS, immediately before the insert.
--- Returns false when the round must not reach the ladder.
function DeathmatchBots.roundLadderEligible(instanceId)
    -- An operator may turn the exclusion off; nothing else may.
    if setting("excludeRoundsFromLadder") == false then return true end
    if instanceId == nil then return false end
    local entry = roundTaint[tostring(instanceId)]
    if entry == nil then return true end
    return entry.tainted ~= true
end

--- Convenience inverse, for a call site that reads better as a question.
function DeathmatchBots.roundHadBots(instanceId)
    return not DeathmatchBots.roundLadderEligible(instanceId)
end

--- The line the standings screen shows when a round will not be persisted.
--- Silent exclusion is indistinguishable from a broken ladder, and a player who
--- just went 20-3 deserves to be told why it did not count.
function DeathmatchBots.ladderNotice(instanceId)
    if DeathmatchBots.roundLadderEligible(instanceId) then return nil end
    return text("ladderBlocked")
end

-- ---------------------------------------------------------------------------
-- Identity. A bot is a participant with a synthetic NEGATIVE id, so standings,
-- scoring and the kill feed key on it exactly like a player id and need no
-- special case. Player ids are always positive, so the two spaces cannot
-- collide, and `tonumber` on a negative id is lossless.
-- ---------------------------------------------------------------------------
function DeathmatchBots.isBot(participantId)
    local id = tonumber(participantId)
    if id == nil or id >= 0 then return false end
    return bots[math.floor(id)] ~= nil
end

function DeathmatchBots.get(participantId)
    local id = tonumber(participantId)
    if id == nil then return nil end
    return bots[math.floor(id)]
end

function DeathmatchBots.name(participantId)
    local bot = DeathmatchBots.get(participantId)
    return bot ~= nil and bot.name or nil
end

--- The label the scoreboard and the kill feed render. Non-nil ONLY for a bot,
--- so a UI can do `row.tag = DeathmatchBots.tag(row.id)` unconditionally.
function DeathmatchBots.tag(participantId)
    if not DeathmatchBots.isBot(participantId) then return nil end
    if setting("labelled") == false then return nil end
    return botTag()
end

--- Stamp a standings row. Rule 1 of section 8: bots are labelled, visibly.
function DeathmatchBots.decorateRow(row)
    if type(row) ~= "table" then return row end
    local bot = DeathmatchBots.get(row.id)
    if bot == nil then
        -- FIX 2026-08-31. This used to clear `row.bot`, which UNLABELLED every row
        -- whose bot had since been removed -- `/dm.bot clear`, a despawn, the end of
        -- a backfill. The row itself survives to the end of the round carrying the
        -- kills the bot took, so what a player saw was a scoreboard on which "BOT
        -- Ash" was, as far as any machine-readable field went, a person. That is
        -- exactly rule 1 of the plan's section 8 being broken, and the name prefix is
        -- no defence: the prefix is presentation and will be translated, the flag is
        -- what the HUD, the feed and any future consumer read.
        --
        -- Being a bot is not a property of being currently spawned. scoring.lua
        -- already derives it permanently from the negative participant id, so the
        -- honest thing to do with no live record is to add nothing and take nothing
        -- away. Only the live decorations -- tag, profile, connectedness -- depend on
        -- the bot still existing, and they are the ones below.
        return row
    end
    row.bot = true
    row.botTag = DeathmatchBots.tag(row.id)
    row.botProfile = bot.profileKey
    row.connected = true
    return row
end

--- The npc id behind a bot participant, in its native form. Pass it straight
--- back to the API; never through `tonumber`.
function DeathmatchBots.npcIdOf(participantId)
    local bot = DeathmatchBots.get(participantId)
    return bot ~= nil and bot.npcId or nil
end

--- Translate a raw attacker/killer id from a platform event into a participant
--- id. THE KERNEL MUST CALL THIS on every attacker it receives -- a bot's shot
--- arrives attributed to its 64-bit npc id, which is not a participant id and
--- which `tonumber` would corrupt.
function DeathmatchBots.attackerId(raw)
    if raw == nil then return 0 end
    local key = idKey(raw)
    if key ~= nil then
        local bot = botByNpc[key]
        if bot ~= nil then return bot.participantId end
    end
    -- Idempotent: handed a participant id it already translated, it gives the
    -- same answer, so a call site may run every id through it without tracking
    -- which ones it has already converted.
    local numeric = tonumber(raw)
    if numeric ~= nil and numeric < 0 and bots[math.floor(numeric)] ~= nil then
        return math.floor(numeric)
    end
    -- Not one of ours: it is a player id, and player ids arrive as strings.
    return playerNumber(raw) or 0
end

-- ---------------------------------------------------------------------------
-- Instance helpers
-- ---------------------------------------------------------------------------
local function instanceView(instanceId)
    if instanceId == nil then return nil end
    return hostCall("instance", instanceId)
end

local function instanceCapacity(instanceId)
    local configured = hostCall("capacity", instanceId)
    local value = tonumber(configured)
    if value ~= nil and value > 0 then return math.floor(value) end
    local view = instanceView(instanceId)
    value = view ~= nil and tonumber(view.capacity) or nil
    if value ~= nil and value > 0 then return math.floor(value) end
    -- Decision 13: FFA instance capacity is 12.
    return 12
end

local function humansIn(instanceId)
    local list = hostCall("playersIn", instanceId)
    if type(list) ~= "table" then return {} end
    local out = {}
    for _, raw in ipairs(list) do
        local id = playerNumber(raw)
        if id ~= nil then out[#out + 1] = id end
    end
    return out
end

local function botsIn(instanceId)
    local key = tostring(instanceId)
    local out = {}
    for _, bot in pairs(bots) do
        if tostring(bot.instanceId) == key then out[#out + 1] = bot end
    end
    return out
end

function DeathmatchBots.count(instanceId)
    if instanceId == nil then
        local total = 0
        for _ in pairs(bots) do total = total + 1 end
        return total
    end
    return #botsIn(instanceId)
end

local function spawnMarks(view)
    if view == nil then return nil end
    local marks = view.spawns
    if type(marks) == "table" and #marks > 0 then return marks end
    return nil
end

local function patrolMarks(view)
    if view == nil then return nil end
    local marks = view.marks
    if type(marks) == "table" and #marks > 0 then return marks end
    return spawnMarks(view)
end

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------
local function botPosition(bot)
    local snapshot = safe(Open77.npcs.get, bot.npcId)
    if type(snapshot) ~= "table" then return nil end
    local x, y, z = tonumber(snapshot.x), tonumber(snapshot.y), tonumber(snapshot.z)
    if x == nil or y == nil or z == nil then return nil end
    bot.health = tonumber(snapshot.health) or bot.health
    bot.maxHealth = tonumber(snapshot.maxHealth) or bot.maxHealth
    return { x = x, y = y, z = z, bucket = tonumber(snapshot.bucket) }, snapshot
end

--- THE DOOR ONTO `Open77.players.position`, AND IT IS A DOOR ON PURPOSE.
---
--- `players.position`, `players.name` and `players.identifier` are the three
--- bindings that RAISE on a non-positive id instead of returning an error --
--- and the raise is a CLR `ArgumentOutOfRangeException` thrown inside the C
--- function, so it unwinds THROUGH `pcall`, through this file's `safe` and
--- `hostCall`, out of the scheduler, and stops the resource with
--- `runtime_error`. The tick's `pcall(tickBot, ...)` is no defence against it.
--- Refusing here, at the one place this file reads a player position, is.
---
--- A bot's position is never here: it belongs to the npc registry and is read
--- by `botPosition`.
local function playerPosition(playerId)
    local id = playerNumber(playerId)
    if id == nil then return nil end
    local position = Open77.players.position(id)
    if type(position) ~= "table" then return nil end
    local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z, bucket = tonumber(position.bucket) }
end

--- Same door, for the same reason: the last fallback below is
--- `Open77.players.name`, which raises on a non-positive id. A bot's liveness
--- is `bot.state`, never this.
local function playerAlive(playerId)
    local id = playerNumber(playerId)
    if id == nil then return false end
    local answer = hostCall("isPlayerAlive", id)
    if answer ~= nil then return answer == true end
    if Open77.players.isDead ~= nil then
        local dead = Open77.players.isDead(id)
        if dead ~= nil then return dead ~= true end
    end
    return Open77.players.name(id) ~= nil
end

-- ---------------------------------------------------------------------------
-- The vertical band, which is ALL that is left of the scripted path's "line of
-- sight" and is now named for what it is.
--
-- What used to be here called itself line of sight and was not. It sampled the
-- segment against the arena volume and required every sample to be inside --
-- but Kabuki's market is ONE box, so every point in it is inside, and the test
-- returned true for every shot that stayed in the arena. That is a predicate
-- which never refuses, which is worse than no predicate at all, because it
-- reads like a check and gets counted as one. It has been deleted.
--
-- The band that survives is genuinely useful and genuinely small: it stops a
-- gallery bot firing through the deck into the sunken level. It is used only by
-- the scripted path; native combat has the engine's raycast and needs none of
-- it.
-- ---------------------------------------------------------------------------
local function withinVerticalBand(from, to, profile)
    return math.abs(to.z - from.z) <= (profile.maxVerticalM or 10.0)
end

-- ---------------------------------------------------------------------------
-- Spawn selection. The same maximin rule the players get: among the surveyed
-- marks, take the one whose nearest opponent is farthest away. Surveyed marks
-- only -- never a derived offset, for the reason the arena config spells out.
-- ---------------------------------------------------------------------------
local function opponentPositions(instanceId, exceptParticipantId)
    local out = {}
    for _, playerId in ipairs(humansIn(instanceId)) do
        local position = playerPosition(playerId)
        if position ~= nil then out[#out + 1] = position end
    end
    for _, bot in ipairs(botsIn(instanceId)) do
        if bot.participantId ~= exceptParticipantId and bot.state == "alive" then
            local position = botPosition(bot)
            if position ~= nil then out[#out + 1] = position end
        end
    end
    return out
end

--- `marksOverride` is the ARENA's spawn cluster: an arena bot holds a side, and
--- a side plays one end of the map, so it must not be offered the whole
--- free-for-all mark set. Absent (every free-for-all bot) the instance's own
--- marks are used exactly as before. The maximin choice below is unchanged and
--- still runs -- it simply runs over three marks instead of fourteen.
local function chooseSpawn(instanceId, view, exceptParticipantId, cursor, marksOverride)
    local marks = marksOverride
    if type(marks) ~= "table" or #marks == 0 then marks = spawnMarks(view) end
    if marks == nil then return nil end
    local opponents = opponentPositions(instanceId, exceptParticipantId)
    local start = ((cursor or 0) % #marks) + 1
    if #opponents == 0 then return marks[start] end

    local best, bestMinimumSq = marks[start], -1
    for offset = 0, #marks - 1 do
        local index = ((start + offset - 1) % #marks) + 1
        local candidate = marks[index]
        local position = candidate.position or candidate
        local minimumSq = math.huge
        for _, opponent in ipairs(opponents) do
            local dx = position.x - opponent.x
            local dy = position.y - opponent.y
            local squared = dx * dx + dy * dy
            if squared < minimumSq then minimumSq = squared end
        end
        if minimumSq > bestMinimumSq then
            best, bestMinimumSq = candidate, minimumSq
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Task issue. Everything goes through `moveTo` with an explicit position,
-- because E8 measured `follow` reporting `executing` while delivering
-- commandTarget = 0,0,0. The movement channel is CLEARED before each issue:
-- an NPC accepts 64 tasks and a 500 ms re-issue loop would hit that ceiling in
-- half a minute otherwise.
-- ---------------------------------------------------------------------------
--- `Open77.npcs.channels` is a constant table; indexing it directly would raise
--- outside `safe`, because the argument is evaluated before the pcall.
local function channel(name)
    local channels = Open77.npcs.channels
    return type(channels) == "table" and channels[name] or nil
end

local function issueMove(bot, position, speed, acceptanceRadius)
    safe(Open77.npcs.tasks.clear, bot.npcId, channel("movement"), "repath")
    local taskId = safe(Open77.npcs.tasks.moveTo, bot.npcId, {
        x = position.x, y = position.y, z = position.z,
    }, {
        speed = speed or "run",
        acceptanceRadius = acceptanceRadius or 1.5,
        timeoutMs = 30000,
        priority = 10,
    })
    bot.lastMoveAtMs = nowMs()
    bot.lastIssuedAtMs = bot.lastMoveAtMs
    bot.lastMoveTarget = { x = position.x, y = position.y, z = position.z }
    return taskId
end

local function issueLookAt(bot, target)
    safe(Open77.npcs.tasks.clear, bot.npcId, channel("look"), "retarget")
    if target == nil then return end
    if target.kind == "player" then
        safe(Open77.npcs.tasks.lookAt, bot.npcId, { type = "player", id = target.id })
    else
        local other = DeathmatchBots.get(target.id)
        if other ~= nil then
            safe(Open77.npcs.tasks.lookAt, bot.npcId, { type = "npc", id = other.npcId })
        end
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local function templateFor(index)
    local list = setting("templates")
    if type(list) ~= "table" or #list == 0 then list = Defaults.templates end
    return list[((index - 1) % #list) + 1]
end

--- Apply the configured cosmetic weapon, if this configuration wants one.
---
--- Under NATIVE combat this is not cosmetic and it is not obviously right. A
--- hostile gang record arrives with its own `primaryEquipment`, so the engine
--- can arm it without help -- and `setLoadout` drives
--- `Api::Puppets::ApplyWeapon`, the player-proxy equip path, whose own comment
--- in `NpcReplication.cpp` records a component-vtable corruption when it runs
--- against a native graph. Against that, a bot observed closing to MELEE is a
--- bot with nothing drawn, which is exactly the symptom an empty canonical
--- loadout produces.
---
--- Both cannot be settled by reading, so `combat.forceWeapon` is an A/B switch
--- and the default keeps today's behaviour: removing the call is the change
--- nobody has measured.
--- Takes an npc id, never a bot record: `createBot` calls it before the record
--- exists, and `bot.npcId` on a bare id would raise rather than return nil.
local function applyLoadout(npcId)
    if nativeCombat() and combatSetting("forceWeapon") ~= true then return false end
    local weaponRecord = setting("weaponRecord")
    if type(weaponRecord) ~= "string" or weaponRecord == "" then return false end
    return safe(Open77.npcs.setLoadout, npcId, { weapon = weaponRecord }) == true
end

--- Create the ENGINE BODY for a bot: one `Open77.npcs.create` and the loadout.
---
--- Extracted from `createBot` because respawn now needs exactly this and
--- nothing else. See `respawnBot` for why a corpse cannot be reused.
--- Returns `npcId` or `nil, reason`.
local function spawnBotBody(template, mark, bucket)
    local position = mark.position or mark
    local lift = spawnLiftMetres()
    -- `create` rejects an unknown template or an out-of-range field with
    -- `nil, reason` rather than raising, so both returns are checked -- but it
    -- goes through `safe` anyway, because a raise here would abort the add loop
    -- half way and leak the participant id.
    local npcId, reason = safe(Open77.npcs.create, {
        template = template,
        position = { x = position.x, y = position.y, z = position.z + lift },
        yaw = tonumber(mark.heading) or 0.0,
        bucket = bucket,
        -- `native` under native combat, and it is DECLARATIVE rather than
        -- functional: F10 established that no client code branches on `aiMode`,
        -- so this changes nothing about the engine. It is set anyway because
        -- `/dm.bot list`, `npc.diag` and anyone reading a snapshot must be able
        -- to see which combat this bot is under, and a field that says `tasks`
        -- on a bot that receives no tasks is a lie the next reader has to
        -- disprove. Server-side it also stops the task scheduler from ever
        -- treating this bot as `frozen`.
        aiMode = nativeCombat() and Open77.npcs.ai.native or Open77.npcs.ai.tasks,
        -- Mortal is the whole point: a bot that cannot die is a target dummy.
        damagePolicy = Open77.npcs.damage.mortal,
        health = tonumber(setting("health")) or Defaults.health,
        maxHealth = tonumber(setting("maxHealth")) or Defaults.maxHealth,
        streamingRadius = tonumber(setting("streamingRadius")) or Defaults.streamingRadius,
        streamingHysteresis = tonumber(setting("streamingHysteresis"))
            or Defaults.streamingHysteresis,
        -- A bot must never vanish on its own: a despawned bot is still a
        -- participant on the scoreboard, and that is a ghost.
        despawnWhenUnobserved = setting("despawnWhenUnobserved") == true,
        persistent = false,
    })
    if npcId == nil or npcId == false then return nil, tostring(reason) end
    -- THE ONE DOOR onto `npcs.create` in this file, so this is the one place a
    -- body can be born and the only counter that has to be kept honest.
    bodiesCreated = bodiesCreated + 1
    applyLoadout(npcId)
    return npcId
end

--- The alias test, done once here rather than assumed anywhere: `tonumber` on
--- the decimal key, then back to a key. Equal means the id fits a Lua double
--- exactly and may be used as a numeric actor alias; unequal means it does not,
--- and the alias is refused rather than silently truncated.
local function aliasFor(npcKey, participantId)
    local alias = tonumber(npcKey)
    if alias == nil or idKey(alias) ~= npcKey then
        if alias ~= nil then
            log(("npc id %s does not survive a Lua number; no actor alias bound"
                .. " for bot %s. The kernel MUST call DeathmatchBots.attackerId"
                .. " on every attacker id or this bot's fire will be gated out.")
                :format(npcKey, tostring(participantId)))
        end
        return nil
    end
    return alias
end

--- May a body be created right now? `nil` when yes, a refusal reason when no.
---
--- Every path that calls `Open77.npcs.create` goes through here. See the
--- module-state header for what each gate is and what it prevents.
local function bodySpawnRefusal()
    if stopping then
        spawnGateStopping = spawnGateStopping + 1
        return "stopping"
    end
    local at = nowMs()
    local settle = tonumber(combatSetting("spawnSettleMs", "respawn")) or 5000
    if at - vmStartedAtMs < settle then
        spawnGateSettling = spawnGateSettling + 1
        return "settling"
    end
    local spacing = tonumber(combatSetting("spawnSpacingMs", "respawn")) or 400
    if at - lastBodySpawnAtMs < spacing then
        spawnGateSpacing = spawnGateSpacing + 1
        return "spacing"
    end
    return nil
end

--- `options` is the ARENA's half of this call and is nil everywhere else:
--- `options.side` is the half of the roster the bot holds, `options.marks` is
--- the spawn cluster that side plays from. Both are stored on the record, and
--- `side ~= nil` is also what makes the bot ELIMINATION-scoped -- see
--- `respawnHeld` below.
local function createBot(instanceId, view, profileKey, options)
    options = type(options) == "table" and options or nil
    local side = options ~= nil and tonumber(options.side) or nil
    local marks = options ~= nil and options.marks or nil
    if type(marks) ~= "table" or #marks == 0 then marks = spawnMarks(view) end
    if marks == nil then return nil, "no_spawn_marks" end
    local refusal = bodySpawnRefusal()
    if refusal ~= nil then return nil, refusal end

    local _, resolvedKey = profileFor(profileKey)
    local participantId = allocateParticipantId()
    local mark = chooseSpawn(instanceId, view, participantId,
        DeathmatchBots.count(instanceId), marks)
    local position = mark.position or mark
    local lift = spawnLiftMetres()
    local bucket = tonumber(view.bucket) or 0

    local template = templateFor(math.abs(participantId))
    local npcId, reason = spawnBotBody(template, mark, bucket)
    if npcId == nil then
        nextParticipant = nextParticipant + 1  -- give the id back
        return nil, tostring(reason)
    end
    lastBodySpawnAtMs = nowMs()

    -- The CANONICAL instance id, taken from the view rather than from the
    -- caller: `/dm.bot add instance=3` passes the string "3" and a player
    -- resolves to the number 3, and two spellings of one instance is exactly
    -- the sort of divergence that leaves a bot orphaned in a closed bucket.
    local canonicalInstanceId = view.id ~= nil and view.id or instanceId

    local npcKey = idKey(npcId)
    local alias = aliasFor(npcKey, participantId)

    local bot = {
        participantId = participantId,
        npcId = npcId,
        npcKey = npcKey,
        npcAlias = alias,
        instanceId = canonicalInstanceId,
        bucket = bucket,
        name = allocateName(),
        profileKey = resolvedKey,
        template = template,
        state = "alive",
        health = tonumber(setting("health")) or Defaults.health,
        maxHealth = tonumber(setting("maxHealth")) or Defaults.maxHealth,
        target = nil,
        targetSeenAtMs = 0,
        acquiredAtMs = 0,
        readyToFireAtMs = 0,
        nextShotAtMs = 0,
        reacquireAtMs = 0,
        burstLeft = 0,
        lastMoveAtMs = 0,
        lastMoveTarget = nil,
        patrolIndex = 0,
        respawnAtMs = 0,
        spawnedAtMs = nowMs(),
        -- ONE KILL PER LIFE, structurally. `declareDeath` credits only when
        -- `creditedLifeId ~= lifeId`, and `respawnBot` is the only thing that
        -- advances `lifeId`. Two death paths racing on the same body -- the
        -- health backstop and `onNpcDied`, say -- therefore cannot produce two
        -- scoreboard kills even if the `state` guard were somehow bypassed.
        lifeId = 1,
        creditedLifeId = 0,
        -- ----------------------------------------------------------------
        -- ARENA. Nil on a free-for-all bot, and every arena behaviour below
        -- keys on `side ~= nil` rather than on the instance's format, so a
        -- bot cannot half-belong to a match.
        -- ----------------------------------------------------------------
        -- The half of the roster this bot holds. arena.lua owns the value; it
        -- is copied onto the scoreboard row through `addParticipant` so the
        -- HUD colours a bot's name exactly like a player's.
        side = side,
        -- The spawn CLUSTER that side plays from. arena.lua rewrites it at
        -- every round start, because the sides swap ends at the halfway point
        -- and a bot respawning on the mark it started the match on would walk
        -- out of the opposing team's spawn.
        marks = marks,
        -- ELIMINATION (decision 4). A death inside an arena round is final for
        -- that round, for a bot exactly as for a player: `tickBot` reads this
        -- instead of the respawn timer. `arenaRoundStart` is the ONLY thing
        -- that lifts it, and `arenaRoundLive` is the only thing that puts it
        -- back. A free-for-all bot never sets it and respawns as it always did.
        respawnHeld = side ~= nil,
        -- Stamped by every hit report naming this bot, in either direction.
        -- The seek guard reads it; nothing else may write it.
        lastCombatAtMs = 0,
        -- STAGGERED, not zero. Every bot of a roster is created in one loop, so
        -- a shared phase would have all twelve run `seekDestination` -- which is
        -- O(roster) `npcs.get` calls -- in the same tick, every interval,
        -- forever. A random offset inside the interval spreads them out and
        -- costs nothing.
        seekIssuedAtMs = nowMs() - math.random(0, 6000),
    }
    bots[participantId] = bot
    botByNpc[bot.npcKey] = bot

    taint(canonicalInstanceId)
    hostCall("addParticipant", canonicalInstanceId, participantId, {
        name = bot.name,
        bot = true,
        botTag = botTag(),
        profile = resolvedKey,
        npcId = npcId,
        npcAlias = alias,
        -- The SCOREBOARD learns the side here rather than waiting for
        -- `assignTeam`: a bot created mid-formation would otherwise show as
        -- team 0 -- the free-for-all value -- until the next round start.
        team = side,
    })

    log(("bot %d created npc=%s template=%s profile=%s instance=%s bucket=%d side=%s at %.2f,%.2f,%.2f"):format(
        participantId, bot.npcKey, template, resolvedKey, tostring(canonicalInstanceId),
        bucket, tostring(side or "-"), position.x, position.y, position.z + lift))
    return bot
end

local function destroyBot(bot, reason)
    if bot == nil then return false end
    -- Drop this body's crossfire window with the body. Bots are respawned by
    -- participant id and destroyed by the hundred over a long session, so a
    -- window per dead bot is a slow leak with no upper bound.
    incoming["bot:" .. tostring(bot.participantId)] = nil
    safe(Open77.npcs.tasks.clear, bot.npcId, nil, reason or "bot_removed")
    safe(Open77.npcs.remove, bot.npcId)
    if bot.npcId ~= nil then bodiesReleased = bodiesReleased + 1 end
    bots[bot.participantId] = nil
    if bot.npcKey ~= nil then botByNpc[bot.npcKey] = nil end
    hostCall("removeParticipant", bot.instanceId, bot.participantId,
        reason or "bot_removed", bot.npcAlias)
    return true
end

--- THE DEATH TRANSACTION'S OTHER HALF, AND IT REPLACES THE BODY.
---
--- BUG 2, owner 2026-09-01: *"i have a dead npc body in front of me, i'm not
--- sure if he is respawning; if i hit him over and over it says that i killed
--- him again and again."* Their scoreboard read `K 6` and some of those were
--- one corpse credited repeatedly. This is that bug, and the old code above is
--- the whole of it. Two facts, both read from the client tree:
---
--- 1. **`setTransform` cannot move an NPC body.** There is no teleport path for
---    an NPC replica anywhere in `NpcReplication.cpp`. A body is placed exactly
---    once, at `DynamicEntityService::Spawn`; after that it reaches a new
---    position only by WALKING there -- `ApplyObserverMotion` issues a native
---    `moveTo` towards the authority's reported pose, and the authority client
---    drives its own AI. `Open77.npcs.setTransform` moves the SERVER's record
---    and nothing else. A corpse walks nowhere, so the body stayed exactly
---    where it fell.
--- 2. **`revive` does not resurrect the puppet.** `ApplyState` projects the
---    server health as a stat-pool FRACTION (`NpcReplication.cpp:705-719`) and
---    never queues a `ResurrectEvent`. `Api::Life::Resurrect` exists and is
---    used for player proxies (`LifeReplication.cpp:516`) precisely because
---    `Life.hpp:105-110` records that refilling the pool alone "leaves the
---    puppet collapsed (its anim graph stays in the death/ragdoll state)".
---    It is called on no NPC anywhere.
---
--- So the old respawn produced a body that was a CORPSE on every client and
--- `alive` in this table. Every gate that protects a dead bot -- `state ~=
--- "alive"` in the hit, incoming and crossfire handlers -- passed, the player
--- shot the corpse four more times, and `declareDeath` credited another kill.
--- Every three seconds, for as long as they kept firing.
---
--- THE FIX IS TO REBUILD THE BODY. Destroy the corpse and create a fresh NPC on
--- the chosen mark. It costs one spawn per death, which is what the 3 s respawn
--- delay is for, and it is the only respawn that is true on the client as well
--- as in this table. It also unbinds the corpse's npc id, so a report still in
--- flight for the old body resolves to no bot and is refused by name
--- (`crossfire_unknown_bot` / `unknown_bot`) rather than landing on the new
--- life.
---
--- The participant id, the name, the profile and the scoreboard row all
--- survive: only the engine body and its numeric actor alias change, and the
--- alias is rebound through `rebindNpc` rather than through
--- `removeParticipant`, which would mark the row as having left.
--- Hand the ENGINE BODY back while keeping the participant.
---
--- Split out of the respawn transaction on 2026-09-01, and the split is the
--- crash fix rather than a tidy-up. The first version of the rebuild destroyed
--- the corpse and created its replacement in the SAME tick, which is a despawn
--- and a spawn issued on one frame -- precisely the concurrency the client
--- cannot cancel (see the module-state header). Releasing the body shortly after
--- death and creating the replacement at the respawn deadline puts seconds
--- between the two, and the invariant that makes it safe is simple: a dead bot
--- with `npcId == nil` has no body, and `respawnBot` refuses to run until it
--- reads that.
---
--- The corpse also stops being something the player can stand and shoot at,
--- which is the other half of what the owner reported. `corpseLingerMs` leaves
--- long enough for the death animation to play.
---
--- UNBIND BEFORE REMOVING. `Open77.npcs.remove` raises `onNpcRemoved`, whose
--- handler deletes the participant on a hit -- correct for a body the platform
--- reaped, catastrophic here.
local function releaseBody(bot, reason)
    local npcId = bot.npcId
    if npcId == nil then return false end
    local key, alias = bot.npcKey, bot.npcAlias
    if key ~= nil then botByNpc[key] = nil end
    -- Kept for the respawn's log line only, so `bot N respawned (was M)` names
    -- a real corpse instead of `nil`. Never read as state: the invariant that
    -- `respawnBot` PATH B tests is `npcId == nil`, and this is deliberately not
    -- that.
    bot.lastNpcKey = key
    bot.npcId, bot.npcKey, bot.npcAlias = nil, nil, nil
    -- The crossfire window is keyed on the participant and its pair cadences
    -- name the body that just went away.
    incoming["bot:" .. tostring(bot.participantId)] = nil
    safe(Open77.npcs.tasks.clear, npcId, nil, reason or "body_released")
    safe(Open77.npcs.remove, npcId)
    bodiesReleased = bodiesReleased + 1
    hostCall("rebindNpc", bot.instanceId, bot.participantId, alias, nil)
    return true
end

local function respawnBot(bot)
    local view = instanceView(bot.instanceId)
    if view == nil then return false end
    local mark = chooseSpawn(bot.instanceId, view, bot.participantId, bot.patrolIndex, bot.marks)
    if mark == nil then return false end
    local position = mark.position or mark
    local lift = spawnLiftMetres()
    local bucket = tonumber(view.bucket) or bot.bucket or 0

    -- ==================================================================
    -- PATH A -- MOVE. Keep the body; place it and stand it up.
    -- ==================================================================
    --
    -- UNREACHABLE, DELIBERATELY. `respawnMode()` returns "rebuild"
    -- unconditionally and names the reason; this block is kept whole because it
    -- is right in every respect but one, and that one is client-side.
    --
    -- WHAT IS MISSING. A server placement here is TWO steps -- `setTransform`
    -- writes the canonical mark and arms ONE projection-adoption grant, then the
    -- client's `DrivePlacement` teleports the body asynchronously and with
    -- retries. `NpcReplication` submits `NpcMotion` from the body's live
    -- position every 100 ms throughout, so the corpse's own position reaches the
    -- server FIRST, is out of budget, takes the grant, and is adopted as
    -- canonical. The real placement then lands and is rejected as a
    -- `motion_jump` against the corpse, forever: 195 of them in 30 minutes on
    -- the production PvP server, 2026-09-01, with bodies left lying on the
    -- pavement and re-killable because `revive` had already succeeded
    -- server-side. Two placements, one grant; the grant goes to the wrong one.
    --
    -- WHAT LIFTS IT. `NpcReplication` withholding `NpcMotion` while
    -- `placementArmed` is true, so the sample that answers a server placement is
    -- the body that arrived rather than the body that has not moved yet. Then
    -- delete the gate in `respawnMode` and this becomes the respawn again.
    --
    -- (The 333 rejections this comment used to hold against PATH B were the
    -- unadopted engine spawn projection, since fixed at the root in
    -- `NpcAuthorityService.Adoptable`. Npc ids also carry a generation, so an
    -- in-flight report for a destroyed body resolves to `not_found` and can
    -- never land on its replacement. Neither argument for MOVE survives.)
    --
    -- ORDER: transform first, then revive. Both bump the revision, so the client
    -- sees the placement already pointing at the mark when the dead -> alive edge
    -- arms its driver, and the driver then keeps asking until the body is
    -- actually there rather than assuming one command took.
    if respawnMode() == "move" and bot.npcId ~= nil then
        safe(Open77.npcs.tasks.clear, bot.npcId, nil, "bot_respawn")
        safe(Open77.npcs.setTransform, bot.npcId, {
            position = { x = position.x, y = position.y, z = position.z + lift },
            yaw = tonumber(mark.heading) or 0.0,
        })
        local revived = safe(Open77.npcs.revive, bot.npcId, bot.maxHealth)
        if revived ~= true then
            -- The body was reaped underneath us. Hand it back and let the next
            -- tick take the rebuild path rather than keeping a ghost.
            releaseBody(bot, "revive_failed")
            bot.respawnAtMs = nowMs() + 250
            logThrottled(("respawn:revive:%d"):format(bot.participantId),
                ("bot %d revive failed; rebuilding the body instead"):format(
                    bot.participantId))
            return false
        end
        safe(Open77.npcs.setHealth, bot.npcId, bot.maxHealth, bot.maxHealth)
        -- Re-applied rather than assumed to survive a revive.
        applyLoadout(bot.npcId)

        respawnsRun = respawnsRun + 1
        bot.lifeId = (bot.lifeId or 1) + 1
        bot.state = "alive"
        bot.health = bot.maxHealth
        bot.target = nil
        bot.lastAttacker = nil
        bot.burstLeft = 0
        bot.lastMoveTarget = nil
        bot.lastMoveAtMs = 0
        bot.lastIssuedAtMs = 0
        bot.readyToFireAtMs = 0
        bot.nextShotAtMs = 0
        bot.reacquireAtMs = 0
        bot.outsideSamples = 0
        bot.leashSoftAtMs = 0
        bot.leashCheckedAtMs = 0
        bot.spawnedAtMs = nowMs()
        bot.lastCombatAtMs = 0
        bot.seekIssuedAtMs = nowMs() - math.random(0, 6000)
        bot.seekReason = nil
        bot.seekTargetId = nil
        log(("bot %d respawned (moved) life=%d npc=%s at %.2f,%.2f,%.2f"):format(
            bot.participantId, bot.lifeId, bot.npcKey,
            position.x, position.y, position.z + lift))
        return true
    end

    -- ==================================================================
    -- PATH B -- REBUILD. Destroy the body and create a fresh one.
    -- ==================================================================
    --
    -- THE INVARIANT. The corpse must already be gone: `tickBot` releases it
    -- `corpseLingerMs` after death and only then lets this run. A respawn that
    -- destroyed and created on one frame is what the crash fix removed.
    if bot.npcId ~= nil then
        bot.respawnAtMs = nowMs() + 250
        return false
    end

    local refusal = bodySpawnRefusal()
    if refusal ~= nil then
        bot.respawnAtMs = nowMs() + 250
        logThrottled("respawn:gate:" .. refusal,
            ("bot respawn held back by the %s gate"):format(refusal))
        return false
    end

    respawnsRun = respawnsRun + 1

    local npcId, reason = spawnBotBody(bot.template, mark, bucket)
    if npcId == nil then
        -- Keep the record and try again shortly. Dropping it here would take a
        -- participant off the scoreboard for a transient spawn failure, and a
        -- vanished bot is the ghost `despawnWhenUnobserved = false` exists to
        -- prevent.
        respawnsFailed = respawnsFailed + 1
        bot.respawnAtMs = nowMs() + 1000
        logThrottled(("respawn:%d"):format(bot.participantId),
            ("bot %d respawn body failed (%s); retrying"):format(
                bot.participantId, tostring(reason)))
        return false
    end
    lastBodySpawnAtMs = nowMs()

    -- No destroy here. `releaseBody` already handed the old body back seconds
    -- ago, unbound its key and dropped its crossfire window; this transaction
    -- only creates.
    bot.npcId = npcId
    bot.npcKey = idKey(npcId)
    bot.npcAlias = aliasFor(bot.npcKey, bot.participantId)
    bot.bucket = bucket
    botByNpc[bot.npcKey] = bot
    -- `nil` for the old alias, and it is a LITERAL rather than a variable on
    -- purpose. This used to read `oldAlias`, which no scope in this file ever
    -- defined -- so it was a global read that always answered nil, and only
    -- happened to be correct. `releaseBody` unbound the corpse's alias seconds
    -- ago (`rebindNpc(..., alias, nil)`), so there is genuinely nothing left to
    -- unbind here and saying so beats a name that looks like state.
    hostCall("rebindNpc", bot.instanceId, bot.participantId, nil, bot.npcAlias)

    -- A NEW LIFE. `declareDeath` will credit exactly one kill against it.
    bot.lifeId = (bot.lifeId or 1) + 1
    bot.state = "alive"
    bot.health = bot.maxHealth
    bot.target = nil
    bot.lastAttacker = nil
    bot.burstLeft = 0
    bot.lastMoveTarget = nil
    bot.lastMoveAtMs = 0
    bot.lastIssuedAtMs = 0
    bot.readyToFireAtMs = 0
    bot.nextShotAtMs = 0
    bot.reacquireAtMs = 0
    bot.outsideSamples = 0
    bot.leashSoftAtMs = 0
    bot.leashCheckedAtMs = 0
    bot.spawnedAtMs = nowMs()
    bot.lastCombatAtMs = 0
    bot.seekIssuedAtMs = nowMs() - math.random(0, 6000)
    bot.seekReason = nil

    log(("bot %d respawned life=%d npc=%s (was %s) at %.2f,%.2f,%.2f"):format(
        bot.participantId, bot.lifeId, bot.npcKey, tostring(bot.lastNpcKey),
        position.x, position.y, position.z + lift))
    return true
end

--- Move a LIVING bot back onto a surveyed mark, keeping everything else.
---
--- Not `respawnBot`, and the difference is a bug the leash would otherwise have
--- shipped with. `respawnBot` is the DEATH transaction: it revives, refills to
--- `maxHealth` and clears the attacker. Calling it to reposition a bot that is
--- merely lost would hand a full health bar back to a body a player had worked
--- down to ten points, and silently delete the damage they had done.
---
--- A living body needs none of that. Clear the task channels so nothing queued
--- walks it straight back out, write the transform, and leave health, killer
--- attribution and the scoreboard exactly as they were.
local function relocateBot(bot, reason)
    local view = instanceView(bot.instanceId)
    if view == nil then return false end
    local mark = chooseSpawn(bot.instanceId, view, bot.participantId, bot.patrolIndex, bot.marks)
    if mark == nil then return false end
    local position = mark.position or mark
    local lift = spawnLiftMetres()

    safe(Open77.npcs.tasks.clear, bot.npcId, nil, reason or "bot_relocated")
    local moved = safe(Open77.npcs.setTransform, bot.npcId, {
        position = { x = position.x, y = position.y, z = position.z + lift },
        yaw = tonumber(mark.heading) or 0.0,
    })
    if moved ~= true then return false end

    -- The movement bookkeeping IS reset, because it describes where the bot was
    -- going and it is no longer going there. Health and `lastAttacker` are not.
    bot.lastMoveTarget = nil
    bot.lastMoveAtMs = 0
    bot.lastIssuedAtMs = 0
    bot.leashSoftAtMs = 0
    bot.outsideSamples = 0
    return true
end

--- ONE KILL PER LIFE, AND THE GUARD IS DOUBLE ON PURPOSE.
---
--- The `state` test alone was the whole protection, and it was sound as far as
--- it went -- but bug 2 walked straight past it, because `respawnBot` set the
--- state back to `alive` on a body that was still a corpse on every client. The
--- body rebuild is the real repair; this is the one that holds even if some
--- future path resurrects a record without rebuilding it, and it costs an
--- integer compare.
---
--- `lifeId` advances only in `respawnBot`. So a second death declared against a
--- life that has already been credited changes the state (harmless, it is
--- already dead) and credits nothing.
local function declareDeath(bot, killerParticipantId, cause, headshot)
    if bot.state == "dead" then return end
    bot.state = "dead"
    bot.target = nil
    bot.burstLeft = 0
    safe(Open77.npcs.tasks.clear, bot.npcId, nil, "bot_died")

    local at = nowMs()
    local delay = respawnDelayMs()
    -- The corpse is released first and the replacement created at the deadline,
    -- so a despawn and a spawn are never issued on one frame. Clamped so a
    -- configuration with a very short respawn delay cannot invert the two.
    local linger = math.max(0, tonumber(combatSetting("corpseLingerMs", "respawn")) or 1200)
    if linger > delay - 500 then linger = math.max(0, delay - 500) end
    bot.bodyReleaseAtMs = at + linger
    bot.respawnAtMs = at + delay
    bot.seekTargetId = nil

    local life = bot.lifeId or 1
    if bot.creditedLifeId == life then
        log(("bot %d death re-declared for life %d; kill NOT credited a second time")
            :format(bot.participantId, life))
        return
    end
    bot.creditedLifeId = life

    hostCall("creditKill", bot.instanceId, killerParticipantId or 0, bot.participantId, {
        cause = tostring(cause or "firearm"),
        headshot = headshot == true,
        victimIsBot = true,
        killerIsBot = killerParticipantId ~= nil and killerParticipantId < 0,
    })
    log(("bot %d died killer=%s cause=%s"):format(
        bot.participantId, tostring(killerParticipantId or "none"), tostring(cause)))
end

-- ---------------------------------------------------------------------------
-- Public lifecycle API
-- ---------------------------------------------------------------------------

--- Add `count` bots to an instance. Returns added, reason.
function DeathmatchBots.add(instanceId, count, profileKey)
    if setting("enabled") ~= true then return 0, "bots_disabled" end
    local view = instanceView(instanceId)
    if view == nil then return 0, "unknown_instance" end
    if spawnMarks(view) == nil then return 0, "no_spawn_marks" end

    local wanted = math.floor(tonumber(count) or 1)
    if wanted <= 0 then return 0, "count_zero" end

    local capacity = instanceCapacity(instanceId)
    -- Default ceiling: capacity minus one seat, so an instance can never be
    -- entirely bots and turn away the human it exists to entertain.
    local maxPerInstance = math.floor(tonumber(setting("maxPerInstance"))
        or math.max(0, capacity - 1))
    local humans = #humansIn(instanceId)
    local current = DeathmatchBots.count(instanceId)
    local room = math.min(maxPerInstance - current, capacity - humans - current)
    if room <= 0 then return 0, "instance_full" end
    if wanted > room then wanted = room end

    local added, firstReason, queued = 0, nil, 0
    for index = 1, wanted do
        local bot, reason = createBot(instanceId, view, profileKey)
        if bot == nil then
            firstReason = firstReason or reason
            -- A rate gate is not a refusal. Park the rest and let the tick
            -- spend them; anything else ends the request here.
            if reason == "spacing" or reason == "settling" then
                for _ = index, wanted do
                    pendingSpawns[#pendingSpawns + 1] =
                        { instanceId = instanceId, profileKey = profileKey }
                    queued = queued + 1
                end
            end
            break
        end
        added = added + 1
    end
    return added, firstReason, queued
end

--- Fill an instance up to `bots.fillTarget` BODIES -- players plus bots -- never
--- past its capacity.
---
--- The `fillWithBots` tunable (Q5) governs the AUTOMATIC path only; an explicit
--- admin `/dm.bot fill` is always allowed, because filling an instance by hand
--- is how the mode is tested at sizes this workstation's VRAM cannot host with
--- real clients.
function DeathmatchBots.fill(instanceId, profileKey)
    local capacity = instanceCapacity(instanceId)
    local target = math.floor(tonumber(setting("fillTarget")) or Defaults.fillTarget)
    if target > capacity then target = capacity end
    local humans = #humansIn(instanceId)
    local current = DeathmatchBots.count(instanceId)
    local room = target - humans - current
    if room <= 0 then return 0, "instance_full" end
    return DeathmatchBots.add(instanceId, room, profileKey)
end

-- ---------------------------------------------------------------------------
-- ARENA. Bots that hold a side.
--
-- WHY THIS IS A SEPARATE DOOR AND NOT A FLAG ON `add`. A free-for-all bot and
-- an arena bot differ in three ways at once, and every one of them has to be
-- true from the first millisecond of the body's life:
--
--   SIDE        it belongs to half a roster, and the scoreboard, the HUD roster
--               and the friendly-fire gates all key on that.
--   CLUSTER     it spawns on its side's end of the map, not on the fourteen
--               free-for-all marks -- which straddle both ends, so a bot given
--               them would open the round standing in the enemy spawn.
--   ELIMINATION it does not come back when it dies, until the round layer says
--               a new round has started.
--
-- `add` bounds the roster on `capacity - humans`, which is the free-for-all
-- rule and the wrong one here: an arena roster is EXACTLY `capacity`, the
-- humans are already counted in it by the caller, and "capacity minus one seat
-- for a human" would refuse the last bot of a 1v1. So this path does its own
-- arithmetic and calls `createBot` directly.
--
-- THE LADDER EXCLUSION NEEDS NOTHING HERE and that is deliberate: `createBot`
-- already calls `taint(instanceId)` and already reports `bot = true` to the
-- scoreboard, which sets `hadBots`. Both taints are read at the WRITE by
-- `Scoring.ladderEligible`, so an arena round with bots in it is excluded by
-- the same two mechanisms a free-for-all round is, with no arena-specific case
-- to keep in step.
-- ---------------------------------------------------------------------------

--- Create `count` bots on one side of an arena match.
---
--- `marks` is that side's spawn cluster (`Arena.cluster`), already filtered to
--- surveyed marks by the caller. `onCreated(participantId, side)` is called for
--- each body as it appears -- IMMEDIATELY for the ones the pacing gate lets
--- through, and LATER from the tick for the ones it parks. A 3v3 asks for up to
--- six bodies and `spawnSpacingMs` is 400 ms, so the tail genuinely does arrive
--- after this function has returned; a caller that read only the return value
--- would build a roster missing five of its six bots.
---
--- Returns `created, reason, queued`.
function DeathmatchBots.addToArena(instanceId, side, count, marks, profileKey, onCreated)
    if setting("enabled") ~= true then return 0, "bots_disabled" end
    side = math.floor(tonumber(side) or 0)
    if side ~= 1 and side ~= 2 then return 0, "bad_side" end
    if type(marks) ~= "table" or #marks == 0 then return 0, "no_spawn_marks" end

    local view = instanceView(instanceId)
    if view == nil then return 0, "unknown_instance" end

    local wanted = math.floor(tonumber(count) or 0)
    if wanted <= 0 then return 0, "count_zero" end

    local created, firstReason, queued = 0, nil, 0
    for index = 1, wanted do
        local bot, reason = createBot(instanceId, view, profileKey,
            { side = side, marks = marks })
        if bot == nil then
            firstReason = firstReason or reason
            -- A rate gate is not a refusal -- same rule as `add`. Park the
            -- remainder WITH their side and cluster so they arrive complete.
            if reason == "spacing" or reason == "settling" then
                for _ = index, wanted do
                    pendingSpawns[#pendingSpawns + 1] = {
                        instanceId = instanceId, profileKey = profileKey,
                        side = side, marks = marks, onCreated = onCreated,
                    }
                    queued = queued + 1
                end
            end
            break
        end
        created = created + 1
        if type(onCreated) == "function" then
            local ok, err = pcall(onCreated, bot.participantId, side)
            if not ok then
                log(("arena bot callback raised: %s"):format(tostring(err)))
            end
        end
    end
    return created, firstReason, queued
end

--- The side a bot holds, or nil for a free-for-all bot. Read by the
--- friendly-fire gates and by the arena's roster readout.
function DeathmatchBots.sideOf(participantId)
    local bot = DeathmatchBots.get(participantId)
    return bot ~= nil and bot.side or nil
end

--- Is this bot standing? The arena's `alive` count needs an answer that is not
--- `instance.members[id]`, which is a PLAYER table and answers nil for a bot.
function DeathmatchBots.isAlive(participantId)
    local bot = DeathmatchBots.get(participantId)
    return bot ~= nil and bot.state == "alive"
end

--- A new arena round begins: every arena bot of the instance goes back to its
--- side's cluster, alive and whole.
---
--- `marksBySide` is `{ [1] = <cluster>, [2] = <cluster> }` for THIS round --
--- not for the match, because the sides swap ends at the halfway point and a
--- bot that kept its opening cluster would respawn in the other team's spawn
--- for the whole second half.
---
--- Two paths, and the split is the same one `respawnBot` documents. A LIVING
--- bot is relocated and refilled: no despawn, no spawn, no epoch churn. A DEAD
--- one goes through the respawn transaction, which is the only code that knows
--- how to stand a body back up under either respawn mode -- so the hold is
--- lifted, the deadlines are brought forward, and the tick runs it within
--- `tickMs`. The buy window (20 s by default) is what makes that safe: it is
--- two orders of magnitude longer than the respawn needs.
---
--- Returns `touched, moved, revived, bodies`, and the split is the point rather
--- than a detail. `moved` is a body that already existed and was put back on its
--- mark; `revived` is one that was dead and is being stood up -- in place under
--- `respawn.mode = "move"`, rebuilt under `"rebuild"`. `bodies` is how many bot
--- bodies this instance actually holds at the end of the call, counted from the
--- records.
---
--- That last number is the one the arena prints, because on 2026-09-01 an
--- operator read `1/6+10bot` in a 3v3 filled with five and no line anywhere
--- could say whether the match had acquired five bodies or one counter was
--- doubling. It was the counter (`Instances.botCount`). Proving that took an
--- hour it should have taken a log line.
function DeathmatchBots.arenaRoundStart(instanceId, marksBySide)
    if type(marksBySide) ~= "table" then return 0, 0, 0, liveBodies(instanceId) end
    local touched, moved, revived = 0, 0, 0
    for _, bot in ipairs(botsIn(instanceId)) do
        local marks = bot.side ~= nil and marksBySide[bot.side] or nil
        if type(marks) == "table" and #marks > 0 then bot.marks = marks end
        if bot.side ~= nil then
            touched = touched + 1
            -- The hold is lifted for the buy window only. `arenaRoundLive` puts
            -- it back the moment the round goes live, so a bot killed during
            -- the round stays down for the rest of it.
            bot.respawnHeld = false
            if bot.state == "dead" then
                revived = revived + 1
                -- Only the DEADLINE is brought forward, never the corpse
                -- release. Under `rebuild` the tick handed this body back
                -- `corpseLingerMs` after it died -- long before the round
                -- ended -- so `respawnBot` finds `npcId == nil` and simply
                -- creates. Zeroing `bodyReleaseAtMs` here would instead release
                -- and create on ONE FRAME in the rare case where the corpse is
                -- still standing, which is exactly the despawn/spawn
                -- concurrency the crash fix was written to remove. The existing
                -- interlock is better than a special case: `respawnBot` refuses
                -- while a body is present and re-arms itself 250 ms later.
                bot.respawnAtMs = nowMs()
            else
                moved = moved + 1
                relocateBot(bot, "arena_round")
                bot.health = bot.maxHealth
                safe(Open77.npcs.setHealth, bot.npcId, bot.maxHealth, bot.maxHealth)
                bot.lastAttacker = nil
                bot.lastCombatAtMs = 0
                bot.target = nil
                bot.burstLeft = 0
            end
        end
    end
    return touched, moved, revived, liveBodies(instanceId)
end

--- The round goes live: elimination is armed again.
---
--- Returns `alive, total` so the round layer can say plainly that a side
--- started a body down, rather than leaving a silently short roster to be
--- discovered from the scoreboard.
function DeathmatchBots.arenaRoundLive(instanceId)
    local alive, total = 0, 0
    for _, bot in ipairs(botsIn(instanceId)) do
        if bot.side ~= nil then
            total = total + 1
            bot.respawnHeld = true
            if bot.state == "alive" then alive = alive + 1 end
        end
    end
    return alive, total
end

--- How many bot BODIES exist, for one instance or for the whole resource. Not
--- the same question as `DeathmatchBots.count`, which counts participants: a bot
--- between `releaseBody` and its rebuild is a participant with no body, and the
--- gap between the two numbers is where a leak would show.
function DeathmatchBots.bodyCount(instanceId)
    return liveBodies(instanceId)
end

--- The AUTOMATIC backfill, for the kernel's tick to call on a thin instance.
--- Refuses unless `fillWithBots` is on -- the tunable if the host exposes one,
--- otherwise the config value. Q5 defaults it OFF in production.
function DeathmatchBots.backfill(instanceId, profileKey)
    local live = hostCall("tunable", "fillWithBots")
    local enabled = live
    if enabled == nil then enabled = setting("fillWithBots") end
    if enabled ~= true then return 0, "fill_disabled" end
    return DeathmatchBots.fill(instanceId, profileKey)
end

--- Remove every bot of one instance, or of every instance when `instanceId` is
--- nil. This is also the instance-reap hook: the kernel calls it when it
--- releases a bucket.
function DeathmatchBots.clear(instanceId, reason)
    local removed = 0
    local key = instanceId ~= nil and tostring(instanceId) or nil
    for _, bot in pairs(bots) do
        if key == nil or tostring(bot.instanceId) == key then
            if destroyBot(bot, reason or "cleared") then removed = removed + 1 end
        end
    end
    return removed
end

--- Alias with the name the instance kernel will reach for.
function DeathmatchBots.reap(instanceId, reason)
    return DeathmatchBots.clear(instanceId, reason or "instance_reaped")
end

--- Register the instance kernel. See THE HOST CONTRACT above.
--- Override the default host. Pass nil to fall back to the kernel binding.
--- The default host already speaks to `Deathmatch.instances`, so nothing has to
--- call this for bots to work; it exists for a test double and for a kernel
--- that is not the one in instances.lua.
function DeathmatchBots.setHost(newHost)
    host = type(newHost) == "table" and newHost or nil
    log(host ~= nil and "explicit host registered"
        or "explicit host cleared; falling back to the Deathmatch kernel")
    return activeHost() ~= nil
end

--- Rows for the state push, so a scoreboard can render bots before the kernel
--- has folded them into its own roster.
function DeathmatchBots.snapshot(instanceId)
    local list
    if instanceId ~= nil then
        list = botsIn(instanceId)
    else
        list = {}
        for _, entry in pairs(bots) do list[#list + 1] = entry end
    end

    local rows = {}
    for _, bot in ipairs(list) do
        rows[#rows + 1] = {
            id = bot.participantId,
            name = bot.name,
            bot = true,
            botTag = botTag(),
            profile = bot.profileKey,
            instanceId = bot.instanceId,
            state = bot.state,
            health = bot.health,
            maxHealth = bot.maxHealth,
        }
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Reconciliation.
--
-- `Open77.npcs.all()` is already filtered to this resource, and it is the only
-- authority on what this resource owns. After a hot reload `bots` is empty
-- while the NPCs are still standing in the arena, so anything not in the
-- registry is an orphan from the previous generation and is reaped -- otherwise
-- every edit leaks a bot. Only NPCs whose template is one of the bot templates
-- are touched, so a future sibling script in this resource that owns its own
-- NPCs is not collateral damage.
-- ---------------------------------------------------------------------------
local function isBotTemplate(name)
    local list = setting("templates")
    if type(list) ~= "table" then list = Defaults.templates end
    for _, entry in ipairs(list) do
        if tostring(entry) == tostring(name) then return true end
    end
    return false
end

local function reconcile()
    local owned = safe(Open77.npcs.all)
    if type(owned) ~= "table" then return 0, 0 end
    local reaped, kept = 0, 0
    for _, snapshot in ipairs(owned) do
        local key = idKey(snapshot.id)
        if key ~= nil and botByNpc[key] ~= nil then
            kept = kept + 1
        elseif isBotTemplate(snapshot.template) then
            safe(Open77.npcs.remove, snapshot.id)
            reaped = reaped + 1
        end
    end
    if reaped > 0 or kept > 0 then
        log(("reconcile: kept=%d reaped=%d orphan bot(s) from a previous generation"):format(
            kept, reaped))
    end
    return kept, reaped
end

-- ---------------------------------------------------------------------------
-- Targeting
-- ---------------------------------------------------------------------------
local function targetPosition(target)
    if target == nil then return nil end
    if target.kind == "player" then return playerPosition(target.id) end
    local other = DeathmatchBots.get(target.id)
    if other == nil or other.state ~= "alive" then return nil end
    return (botPosition(other))
end

local function targetAlive(target)
    if target == nil then return false end
    if target.kind == "player" then return playerAlive(target.id) end
    local other = DeathmatchBots.get(target.id)
    return other ~= nil and other.state == "alive"
end

local function selectTarget(bot, origin, profile)
    local best, bestDistance = nil, math.huge
    local acquire = profile.acquireRangeM or 50.0

    for _, playerId in ipairs(humansIn(bot.instanceId)) do
        if playerAlive(playerId) then
            local position = playerPosition(playerId)
            if position ~= nil
                and (position.bucket == nil or position.bucket == bot.bucket) then
                local separation = distance3(origin, position)
                if separation <= acquire and separation < bestDistance
                    and withinVerticalBand(origin, position, profile) then
                    best = { kind = "player", id = playerId }
                    bestDistance = separation
                end
            end
        end
    end

    if setting("fightEachOther") == true then
        for _, other in ipairs(botsIn(bot.instanceId)) do
            if other.participantId ~= bot.participantId and other.state == "alive" then
                local position = botPosition(other)
                if position ~= nil and position.bucket == bot.bucket then
                    local separation = distance3(origin, position)
                    if separation <= acquire and separation < bestDistance
                        and withinVerticalBand(origin, position, profile) then
                        best = { kind = "bot", id = other.participantId }
                        bestDistance = separation
                    end
                end
            end
        end
    end

    return best, bestDistance
end

local function bandChance(profile, separation)
    local bands = profile.bands
    if type(bands) ~= "table" then return nil end
    for _, band in ipairs(bands) do
        if separation <= (tonumber(band.maxM) or 0.0) then
            return tonumber(band.chance) or 0.0
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The bot's gun. E7 GREEN: an npc id is a valid attacker on a player and it
-- survives into `open77:playerDamaged`, so the kill feed names the bot and the
-- directional damage indicator has a real source.
--
-- Bot -> player damage is NOT credited here: the platform emits
-- `open77:playerDamaged` / `open77:playerKilled` and the kernel's existing
-- ledger consumes them (after translating the attacker id -- see
-- `DeathmatchBots.attackerId`). Crediting here as well would double-count.
-- Bot -> bot damage HAS no platform event, so it is credited here.
-- ---------------------------------------------------------------------------

--- Is the bot actually POINTING at what it is shooting?
---
--- It was not. The fire gate tested range and a volume-containment "line of
--- sight", and nothing else -- so a bot fired at anything inside the arena box
--- regardless of which way it faced, and the owner was killed from behind by
--- bots that were looking elsewhere. Volume containment cannot see walls
--- either: with the market as one box, every point in it is "visible" from
--- every other, so that test only ever rejected shots leaving the arena.
---
--- A facing cone is not occlusion and does not pretend to be. What it buys is
--- that a bot must have turned towards you before it can hurt you, which is the
--- part a player can actually read and respond to. Heading maps to a direction
--- as (-sin, cos) on this build, measured by walking a known yaw.
local function facingTarget(bot, snapshot, origin, targetPos, profile)
    local yaw = snapshot ~= nil and tonumber(snapshot.yaw) or nil
    -- Unknown facing must not silently disarm every bot; a missing yaw is a
    -- streaming gap, not a refusal.
    if yaw == nil then return true end

    local dx, dy = targetPos.x - origin.x, targetPos.y - origin.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return true end

    local radians = math.rad(yaw)
    local forwardX, forwardY = -math.sin(radians), math.cos(radians)
    local dot = (dx / length) * forwardX + (dy / length) * forwardY
    local cone = math.cos(math.rad(tonumber(profile.fireConeDegrees) or 40.0))
    -- Kept for `dm.bot list`: a cone that never refuses, or refuses always, is
    -- a frozen yaw rather than a working gate, and only a reading tells them
    -- apart.
    bot.debugYaw, bot.debugDot = yaw, dot
    return dot >= cone
end


--- May this victim be shot at all?
---
--- Spawn protection did not work, and the reason is worth keeping: the grace on
--- a respawn protects the ENGINE damage path, and a bot's gun is scripted
--- damage through `Open77.players.damage`, which does not consult it. Zero shots
--- were ever refused -- the owner spawned and was hit immediately, by a bot they
--- could not even see.
---
--- So the gamemode enforces it, which is the only place that can: anything not
--- squarely `alive` is off limits. That covers the respawn grace, the moment of
--- death, and every mid-transition state where a body exists but the player does
--- not yet control it.
local function victimShootable(target)
    if target.kind ~= "player" then return true end

    local remaining = tonumber(hostCall("protectionRemaining", target.id) or 0) or 0
    if remaining > 0 then return false end

    local life = Open77.players.getLifeState(target.id)
    if life == nil then return false end
    -- Server phases carry no underscore; the client's do. Normalising both ways
    -- costs nothing and removes a class of silent mismatch.
    local phase = tostring(life.phase or ""):gsub("_", "")
    return phase == "alive"
end

--- Are these two participants team-mates in an arena match?
---
--- FALSE OUTSIDE A MATCH, always: a free-for-all has no sides, so every pair
--- there answers no and nothing changes for the mode this file was written for.
--- Both ends must resolve to a side and the sides must be equal -- one side
--- known and the other nil is a bot the match does not own, and refusing damage
--- on that would make a stray body invulnerable rather than friendly.
---
--- WHY IT IS NEEDED AT ALL. The engine's hostility sweep
--- (`client/src/api/Hostility.hpp`) makes every `aiMode = native` body of a
--- bucket hostile to every other one and to the local player, ALL PAIRS, with
--- no notion of a team -- it has none to read, because the NPC replica carries
--- no side. So in a 3v3 the engine will happily have two team-mates shoot each
--- other, and the only place that can be refused without a client change is
--- HERE, at the server ledger, which is the thing that actually subtracts
--- health (see "TWO HEALTH LEDGERS" at the top of this file). The engine still
--- draws the shot; it just never lands.
local function sameArenaSide(first, second)
    local a = hostCall("arenaSide", first)
    local b = hostCall("arenaSide", second)
    if a == nil or b == nil then return false end
    return a == b
end

local function fireOnce(bot, profile, target, separation)
    local chance = bandChance(profile, separation)
    if chance == nil then return false end
    if math.random() > chance then return false end

    local headshot = math.random() < (tonumber(profile.headshotChance) or 0.0)
    local amount = (tonumber(profile.damage) or 10.0)
        * (headshot and (tonumber(profile.headshotMultiplier) or 2.0) or 1.0)

    if target.kind == "player" then
        local ok, reason = Open77.players.damage(target.id, amount, {
            attacker = bot.npcId,   -- native form; never through tonumber
            cause = "firearm",
        })
        if ok ~= true then
            -- Normal, not exceptional: a victim inside their spawn-protection
            -- grace refuses every shot until it expires.
            logThrottled(("shot:%d:%s"):format(bot.participantId, tostring(reason)),
                ("bot %d shot refused victim=%d reason=%s"):format(
                    bot.participantId, target.id, tostring(reason)))
            return false
        end
        return true
    end

    local other = DeathmatchBots.get(target.id)
    if other == nil then return false end
    local applied = safe(Open77.npcs.applyDamage, other.npcId, amount,
        "bot:" .. tostring(bot.participantId), "firearm")
    if applied ~= true then return false end
    hostCall("creditDamage", bot.instanceId, bot.participantId, other.participantId,
        amount, { headshot = headshot, cause = "firearm", victimIsBot = true })
    -- The victim remembers who shot it, exactly as `applyBotHit` does for a
    -- player's shot. Without this, `fightEachOther` fire that finishes a bot
    -- through the TICK'S HEALTH BACKSTOP -- rather than through the branch
    -- below -- credits `nil`, and the kill lands as an environment death that
    -- nobody scored. `onNpcDied` reads the same field.
    other.lastAttacker = bot.participantId
    other.health = math.max(0.0, (other.health or other.maxHealth) - amount)
    if other.health <= 0.0 then
        declareDeath(other, bot.participantId, "firearm", headshot)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- THE LEASH (R6)
--
-- Native combat is not opt-in and cannot be switched off, so a bot inherits
-- behaviour nobody chose: chase a player out of the arena, wander after a
-- vanilla NPC it decided to fight, or be pushed somewhere by a grenade. The
-- player side of this problem is already solved -- `client/main.lua` clamps at
-- 60 Hz with `server/bounds.lua` as the backstop -- and this is the equivalent
-- for a body that has no client of its own to clamp it.
--
-- THREE ANSWERS, NEVER TWO, and it is the same rule bounds.lua states for
-- players: `containsPoint` returning nil means CANNOT TELL, not "outside". An
-- unsurveyed zone, an absent bounds module or an unreadable position must
-- freeze the accumulator rather than advance it, or every bot in an unsurveyed
-- arena is dragged to a boundary that was never measured.
--
-- TWO ESCALATING STEPS, because the soft one is expected to fail. A `moveTo` on
-- a bot in combat may simply be dropped -- `AIMoveToCommand.ignoreInCombat` is
-- set true where the client builds it -- and a bot chasing somebody out of the
-- arena is by definition in combat. So the soft step is the polite attempt and
-- the hard step is the one that always works:
--
--   soft   `moveTo` to the nearest legal point. Costs nothing if ignored.
--   hard   `setTransform`. Always works, and is deliberately slow to arrive
--          because it revokes the simulation lease and bumps the authority
--          epoch, which re-elects an owner and briefly stalls native tasks.
--
-- BEYOND `teleportLimitM` neither step is right. A bot sixty metres outside did
-- not lean on the wall; it fell through the world, or followed somebody into
-- the next district. Dragging it back across that distance lands it inside
-- geometry, so it is destroyed and respawned on a surveyed mark instead --
-- which is exactly the reasoning `client/main.lua` uses for `MAX_CORRECTION_M`.
-- ---------------------------------------------------------------------------
local function tickLeash(bot, origin, at)
    if combatSetting("enabled", "leash") ~= true then return false end
    if at - (bot.leashCheckedAtMs or 0) < (tonumber(combatSetting("intervalMs", "leash")) or 500) then
        return false
    end
    bot.leashCheckedAtMs = at

    local inside = hostCall("containsPoint", bot.instanceId, origin)
    if inside == nil then
        -- Cannot tell. FREEZE the accumulator rather than reset it: resetting
        -- would let a bot sit outside indefinitely simply by standing where the
        -- zone cannot answer, which is the exploit bounds.lua names in its own
        -- freeze comment.
        return false
    end
    if inside then
        bot.outsideSamples = 0
        return false
    end

    bot.outsideSamples = (bot.outsideSamples or 0) + 1
    local soft = math.floor(tonumber(combatSetting("softSamples", "leash")) or 4)
    if bot.outsideSamples < soft then return false end

    local inset = tonumber(combatSetting("insetMetres", "leash")) or 1.5
    local target = hostCall("projectInside", bot.instanceId, origin, inset)
    if type(target) ~= "table" then return false end
    local distance = tonumber(target.distance) or 0.0

    -- Too far to drag: this is a placement, not a correction.
    local limit = tonumber(combatSetting("teleportLimitM", "leash")) or 60.0
    if distance > limit then
        -- `relocateBot`, NOT `respawnBot`: this body is alive, and the death
        -- transaction would refill it to `maxHealth` and quietly erase whatever
        -- damage a player had already done to it.
        logThrottled(("leash:lost:%d"):format(bot.participantId),
            ("bot %d is %.1fm outside its zone -- placing on a mark rather than dragging"):format(
                bot.participantId, distance))
        bot.outsideSamples = 0
        relocateBot(bot, "leash_lost")
        return true
    end

    local hard = math.floor(tonumber(combatSetting("hardSamples", "leash")) or 12)
    if bot.outsideSamples >= hard then
        -- The hard step. Clear the movement channel first: a queued task
        -- surviving a teleport would immediately walk the bot back out.
        safe(Open77.npcs.tasks.clear, bot.npcId, channel("movement"), "leash")
        safe(Open77.npcs.setTransform, bot.npcId, {
            position = { x = target.x, y = target.y, z = target.z },
        })
        log(("bot %d leashed HARD from %.1fm outside after %d samples"):format(
            bot.participantId, distance, bot.outsideSamples))
        bot.outsideSamples = 0
        bot.leashSoftAtMs = 0
        return true
    end

    -- The soft step, re-issued no more than once per second so a bot the
    -- behaviour tree keeps ignoring does not accumulate movement tasks against
    -- the 64-per-NPC ceiling.
    if at - (bot.leashSoftAtMs or 0) >= 1000 then
        bot.leashSoftAtMs = at
        safe(Open77.npcs.tasks.clear, bot.npcId, channel("movement"), "leash")
        safe(Open77.npcs.tasks.moveTo, bot.npcId,
            { x = target.x, y = target.y, z = target.z },
            { speed = "run", acceptanceRadius = 2.0, timeoutMs = 8000, priority = 90 })
        logThrottled(("leash:soft:%d"):format(bot.participantId),
            ("bot %d nudged back inside from %.1fm out"):format(bot.participantId, distance))
    end
    return false
end

-- ---------------------------------------------------------------------------
-- SEEK (bug 1, owner 2026-09-01: "the bots aren't moving [...] so they stay on
-- spawn and we never see them")
--
-- THE DEFECT, and it is two rules that are each correct alone. Native combat
-- issues no movement at all -- "an empty task queue IS the hands-off mode" --
-- and `chooseSpawn` is a MAXIMIN rule that puts every new body on the surveyed
-- mark whose nearest opponent is FARTHEST away. Put together they guarantee the
-- one arrangement in which nothing can ever happen: eight bodies, 31.7 m apart
-- at the closest and 132 m at the widest, none of which moves, inside a covered
-- market no perception radius crosses. Only a player walking into a cone, or a
-- bullet, ever started a fight.
--
-- WHY A COARSE `moveTo` RATHER THAN THE OTHER TWO CANDIDATES.
--
--   * Suppressing or replacing an observer's AI is a CLOSED DOOR. It crashed
--     every observing client and `ApplyObserverMotion` says so in the source
--     (`NpcReplication.cpp:533-542`). Nothing here touches a locomotion
--     controller.
--   * Seeding threat further out is already done, by `Api::Hostility`'s 0.5 Hz
--     sweep, and it is what made bots fight AT ALL (F22). It is not sufficient
--     for meeting: a seeded threat gives the engine a target, and the engine
--     then decides whether closing on it is worth leaving cover for. It is also
--     capped by `SeedThreat`'s cooldown and deliberately never seeds a player.
--   * Spawning them closer throws away the one fairness property the spawn rule
--     has, and would have to be undone the moment real players outnumber bots.
--
-- WHY THIS IS NOT F13 REPEATING ITSELF. F13's scripted layer re-issued `moveTo`
-- at 2 Hz and CLEARED THE MOVEMENT CHANNEL before every issue, so it cancelled
-- whatever the behaviour tree had running and a bot could never take cover,
-- strafe or break contact. Three things differ here, and each is load-bearing:
--
--   1. CADENCE. One destination per `intervalMs` (6 s), not two per second.
--   2. THE QUIET WINDOW. A bot is only ever sent somewhere when the server has
--      seen no hit report naming it, in either direction, for `combatQuietMs`.
--      `bot.lastCombatAtMs` is stamped by every report path.
--   3. THE ENGINE'S OWN VETO. `AIMoveToCommand.ignoreInCombat` is set true
--      where the client builds the command (`api/NpcTasks.cpp:425`), so a
--      `moveTo` issued a moment before contact is dropped by the engine rather
--      than obeyed by the bot. A bot that IS fighting is never steered by us,
--      and that is enforced twice -- once by our clock and once by the engine's
--      combat state, which is the authority we do not have.
--
-- The channel clear stays, because 64 tasks is the per-NPC ceiling and a
-- superseded destination must not accumulate -- but it only ever cancels OUR
-- previous seek, and it only runs on a body the quiet window already called
-- idle.
-- ---------------------------------------------------------------------------
local function seekSetting(name)
    return combatSetting(name, "seek")
end

--- How many OTHER bots are already walking towards each participant.
---
--- The whole of the "conga line" fix. Without it every bot runs the same
--- nearest-opponent rule against the same map and reaches the same answer, so a
--- roster converges to one point -- which on 2026-09-01 was the player.
local function suitorCounts(instanceId, exceptParticipantId)
    local counts = {}
    for _, other in ipairs(botsIn(instanceId)) do
        if other.participantId ~= exceptParticipantId
            and other.state == "alive" and other.seekTargetId ~= nil then
            counts[other.seekTargetId] = (counts[other.seekTargetId] or 0) + 1
        end
    end
    return counts
end

--- Something worth walking towards, and `nil` when there is none.
---
--- THREE RULES, and the second and third are the 2026-09-01 correction.
---
--- 1. **Only bots, while any bot is available.** The owner ran the first seek
---    build and reported *"they are moving now -- but they go directly toward
---    me"*: every bot took the nearest opponent, the player was in the middle of
---    the market, and eleven bots walked eleven straight lines to one person and
---    never met each other. Bot-versus-bot was ALREADY working
---    (`crossfire=39/39`, four bots killed by other bots) -- the seek was simply
---    out-competing it. Under `preferBots` a player is considered only when the
---    instance has no living bot opponent in range at all, which in a filled
---    instance is never.
---
---    The player is not thereby ignored: the engine's own senses and the
---    hostility sweep make every bot hostile to them, exactly as before. What
---    changes is that the player WALKS INTO a firefight rather than being the
---    destination of eleven of them.
---
--- 2. **Nearest that is not already crowded.** Sorting by distance and taking
---    the first candidate with fewer than `maxSuitors` bots already heading for
---    it turns one scrum into several fights spread over the map. Nearest still
---    wins outright when everything is spoken for, so this can never refuse to
---    pick.
---
--- 3. **Patrol when nothing is in range**, so a lone bot is not a statue.
---
--- Walking is not a threat seed: `Api::Hostility` still never puts a player into
--- a tracker, so spawn protection is untouched either way.
local function seekDestination(bot, origin)
    local maximum = tonumber(seekSetting("maxSeekM")) or 90.0
    local maximumSq = maximum * maximum

    -- RULE 1. Bots first, and on their own if there are any.
    local candidates = {}
    for _, other in ipairs(botsIn(bot.instanceId)) do
        if other.participantId ~= bot.participantId and other.state == "alive" then
            local position = botPosition(other)
            if position ~= nil and position.bucket == origin.bucket then
                local separation = distance3(origin, position)
                if separation * separation <= maximumSq then
                    candidates[#candidates + 1] = {
                        id = other.participantId,
                        position = position,
                        separation = separation,
                    }
                end
            end
        end
    end

    local preferBots = seekSetting("preferBots") ~= false
    if seekSetting("seekPlayers") ~= false and (not preferBots or #candidates == 0) then
        for _, playerId in ipairs(humansIn(bot.instanceId)) do
            if playerAlive(playerId) then
                local position = playerPosition(playerId)
                if position ~= nil and position.bucket == origin.bucket then
                    local separation = distance3(origin, position)
                    if separation * separation <= maximumSq then
                        candidates[#candidates + 1] = {
                            id = playerId,
                            position = position,
                            separation = separation,
                        }
                    end
                end
            end
        end
    end

    if #candidates > 0 then
        -- RULE 2. Nearest first, then the first one that is not already crowded.
        table.sort(candidates, function(left, right)
            if left.separation == right.separation then return left.id < right.id end
            return left.separation < right.separation
        end)
        local counts = suitorCounts(bot.instanceId, bot.participantId)
        local ceiling = math.floor(tonumber(seekSetting("maxSuitors")) or 2)
        local chosen = candidates[1]
        if ceiling > 0 then
            for _, candidate in ipairs(candidates) do
                if (counts[candidate.id] or 0) < ceiling then
                    chosen = candidate
                    break
                end
            end
        end
        bot.seekTargetId = chosen.id
        return chosen.position, chosen.separation, "opponent"
    end

    bot.seekTargetId = nil
    if seekSetting("patrol") == false then return nil end

    -- Nobody in range. Walk the surveyed marks rather than stand still: a lone
    -- bot in a thin instance is exactly the body the owner never sees.
    local view = instanceView(bot.instanceId)
    local marks = patrolMarks(view)
    if marks == nil then return nil end
    bot.patrolIndex = (bot.patrolIndex or 0) + 1
    local mark = marks[(bot.patrolIndex % #marks) + 1]
    local position = mark ~= nil and (mark.position or mark) or nil
    if position == nil then return nil end
    return position, distance3(origin, position), "patrol"
end

local function tickSeek(bot, origin, at)
    if seekSetting("enabled") ~= true then return false end

    -- GUARD 1. Anything that reported a hit naming this bot, in either
    -- direction, counts as a fight in progress. The engine owns a fighting bot
    -- completely.
    local quiet = tonumber(seekSetting("combatQuietMs")) or 5000
    if at - (bot.lastCombatAtMs or 0) < quiet then
        bot.seekReason = "combat"
        return false
    end
    -- The leash is a stronger claim on the movement channel than seeking is:
    -- a bot outside its zone must come back before it goes looking.
    if (bot.outsideSamples or 0) > 0 then
        bot.seekReason = "leash"
        return false
    end
    if at - (bot.seekIssuedAtMs or 0) < (tonumber(seekSetting("intervalMs")) or 6000) then
        return false
    end

    local destination, separation, kind = seekDestination(bot, origin)
    if destination == nil then
        bot.seekReason = "nobody"
        bot.seekIssuedAtMs = at
        return false
    end

    -- Standing on it already -- a patrol mark the bot never left. Skip rather
    -- than issue a task that completes on arrival at zero metres;
    -- `seekDestination` has already stepped `patrolIndex`, so the next pass
    -- picks a different mark.
    if separation <= 2.0 then
        bot.seekReason = ("at:%s"):format(kind)
        bot.seekIssuedAtMs = at
        return false
    end

    -- Close enough already. Below this the engine's own senses do the
    -- introduction and a destination would only argue with them.
    local arrive = tonumber(seekSetting("arriveM")) or 14.0
    if kind == "opponent" and separation <= arrive then
        bot.seekReason = ("near:%.0fm"):format(separation)
        bot.seekIssuedAtMs = at
        return false
    end

    bot.seekIssuedAtMs = at
    -- Only ever cancels a previous SEEK. The behaviour tree's own combat
    -- movement does not live on this channel, and the quiet window means this
    -- body was not fighting anyway.
    safe(Open77.npcs.tasks.clear, bot.npcId, channel("movement"), "seek")
    local taskId = safe(Open77.npcs.tasks.moveTo, bot.npcId, {
        x = destination.x, y = destination.y, z = destination.z,
    }, {
        speed = tostring(seekSetting("speed") or "run"),
        acceptanceRadius = tonumber(seekSetting("acceptanceRadiusM")) or 4.0,
        timeoutMs = math.floor(tonumber(seekSetting("timeoutMs")) or 20000),
        priority = math.floor(tonumber(seekSetting("priority")) or 20),
    })
    if taskId == nil or taskId == false then
        seekRefused = seekRefused + 1
        bot.seekReason = "refused"
        logThrottled(("seek:refused:%d"):format(bot.participantId),
            ("bot %d seek task refused (%s at %.0fm)"):format(
                bot.participantId, kind, separation))
        return false
    end
    seekIssued = seekIssued + 1
    -- The target id is in the readout on purpose: `/dm.bot list` showing six
    -- rows with six different `->` values is the spread working, and six rows
    -- all naming the player is the 2026-09-01 conga line coming back.
    bot.seekReason = ("%s->%s:%.0fm"):format(
        kind, tostring(bot.seekTargetId or "-"), separation)
    bot.lastMoveTarget = { x = destination.x, y = destination.y, z = destination.z }
    bot.lastMoveAtMs = at
    logThrottled(("seek:%d"):format(bot.participantId),
        ("bot %d seeking %s at %.0fm"):format(bot.participantId, kind, separation))
    return true
end

-- ---------------------------------------------------------------------------
-- THE NATIVE TICK. Almost nothing, and that is the point.
--
-- Under native combat this file's only jobs are bookkeeping the engine cannot
-- do -- noticing a death, running the respawn timer, reaping an orphan -- the
-- leash, and ONE coarse destination for a body that has been idle long enough
-- to be certain it is not fighting. It issues no look task and no damage.
-- ---------------------------------------------------------------------------
local function tickNativeBot(bot, at, origin, snapshot)
    -- Health backstop. `onNpcDied` is the primary signal; this file does not
    -- assume an event fires because a document says so.
    if snapshot ~= nil and (tonumber(snapshot.health) or 1.0) <= 0.0 then
        declareDeath(bot, bot.lastAttacker, "firearm", false)
        return
    end
    -- The leash first, and it returns true when it acted: a bot being pulled
    -- back inside its zone must not have that correction overwritten by a seek
    -- destination in the same tick.
    if tickLeash(bot, origin, at) then return end
    tickSeek(bot, origin, at)
end

-- ---------------------------------------------------------------------------
-- The tick
-- ---------------------------------------------------------------------------
local function tickBot(bot, at, movementDue)
    -- Reap with the instance. `Instances.close` already unbinds the actor, so
    -- the only thing left to do is remove the projection -- and it is done from
    -- the tick rather than from a close hook, because chaining
    -- `DM.onInstanceClosed` behind whatever else registered on it is how one
    -- file silently cancels another's cleanup.
    local view = instanceView(bot.instanceId)
    if view == nil then
        destroyBot(bot, "instance_closed")
        return
    end

    if bot.state == "dead" then
        -- REBUILD keeps two deadlines, in this order and never on the same
        -- frame: hand the body back, then -- once it is actually gone -- create
        -- the next one. MOVE keeps the body and has only the second.
        if respawnMode() == "rebuild"
            and bot.npcId ~= nil and at >= (bot.bodyReleaseAtMs or 0) then
            releaseBody(bot, "bot_corpse_released")
        end
        -- ELIMINATION. An arena bot whose round is running does not come back:
        -- the body stays dead in the match's bucket, which is what "spectate
        -- your team" is for a player and is the same rule applied to a bot.
        -- `arenaRoundStart` is what lifts the hold, one round later.
        if not bot.respawnHeld and at >= bot.respawnAtMs then respawnBot(bot) end
        return
    end

    local origin, snapshot = botPosition(bot)
    if origin == nil then
        -- The NPC is gone underneath us -- reaped, or removed by the platform.
        destroyBot(bot, "npc_vanished")
        return
    end
    bot.bucket = origin.bucket or bot.bucket

    -- THE FORK. Under native combat everything below this line is a command
    -- that would cancel one the behaviour tree issued, so none of it runs.
    if nativeCombat() then
        return tickNativeBot(bot, at, origin, snapshot)
    end

    -- Health backstop. `onNpcDied` is the primary signal, but this file does
    -- not assume an event fires just because the documentation says so.
    if snapshot ~= nil and (tonumber(snapshot.health) or 1.0) <= 0.0 then
        declareDeath(bot, bot.lastAttacker, "firearm", false)
        return
    end

    local profile = profileFor(bot.profileKey)

    -- 1. Target.
    local retarget = bot.target == nil or at >= bot.reacquireAtMs
        or not targetAlive(bot.target)
    if not retarget then
        local currentPos = targetPosition(bot.target)
        if currentPos == nil then
            if at - bot.targetSeenAtMs > (profile.loseTargetMs or 3000) then
                retarget = true
            end
        else
            bot.targetSeenAtMs = at
        end
    end
    if retarget then
        local chosen = selectTarget(bot, origin, profile)
        local changed = (chosen == nil) ~= (bot.target == nil)
            or (chosen ~= nil and bot.target ~= nil
                and (chosen.kind ~= bot.target.kind or chosen.id ~= bot.target.id))
        if changed then
            bot.target = chosen
            bot.acquiredAtMs = at
            bot.targetSeenAtMs = at
            bot.readyToFireAtMs = at + (profile.reactionMs or 500)
            bot.burstLeft = 0
            bot.nextShotAtMs = at + (profile.reactionMs or 500)
            bot.lastMoveTarget = nil
            issueLookAt(bot, chosen)
        end
        bot.reacquireAtMs = at + (profile.reacquireMs or 2000)
    end

    -- 2. Movement. `moveTo` with an explicit position, re-issued on a tick --
    -- E8 measured `follow` reporting `executing` while going nowhere.
    local movement = profile.movement
    if movementDue and at - (bot.lastMoveAtMs or 0) >= (movement.repathIntervalMs or 1000) then
        local destination, acceptance = nil, 1.5
        local targetPos = bot.target ~= nil and targetPosition(bot.target) or nil
        if targetPos ~= nil then
            -- The destination is the TARGET'S OWN position: somebody is
            -- standing there, so it is walkable ground by construction. The
            -- acceptance radius is the engagement range, so the bot closes to
            -- its preferred distance and stops.
            destination = targetPos
            acceptance = movement.preferredRangeM or 12.0
        else
            local marks = patrolMarks(view)
            if marks ~= nil and #marks > 0 then
                local mark = marks[(bot.patrolIndex % #marks) + 1]
                local position = mark.position or mark
                if distance2(origin, position) <= (movement.patrolArrivalM or 3.0) then
                    bot.patrolIndex = bot.patrolIndex + 1
                    mark = marks[(bot.patrolIndex % #marks) + 1]
                    position = mark.position or mark
                end
                destination = position
                acceptance = movement.patrolArrivalM or 3.0
            end
        end

        if destination ~= nil then
            local moved = bot.lastMoveTarget == nil
                or distance2(bot.lastMoveTarget, destination)
                    > (movement.repathDistanceM or 3.0)
            -- A heartbeat re-issue even when the destination has not moved.
            -- E8 is the reason: a task reporting `executing` is not evidence
            -- that the NPC is going anywhere, and a bot standing still on a
            -- patrol leg for the rest of the round is the failure this guards.
            local stale = at - (bot.lastIssuedAtMs or 0)
                >= (movement.repathIntervalMs or 1000) * 3
            if moved or stale then
                issueMove(bot, destination, movement.speed, acceptance)
            else
                bot.lastMoveAtMs = at
            end
        end
    end

    -- 3. Fire.
    if bot.target == nil or at < bot.readyToFireAtMs or at < bot.nextShotAtMs then
        return
    end
    local targetPos = targetPosition(bot.target)
    if targetPos == nil or not targetAlive(bot.target) then
        bot.target = nil
        issueLookAt(bot, nil)
        return
    end
    local separation = distance3(origin, targetPos)
    if separation > (profile.maxRangeM or 45.0)
        or not withinVerticalBand(origin, targetPos, profile)
        -- Added after the first bot playtest: without these two a bot shot
        -- anything inside the arena box, facing anywhere, including a player
        -- still inside their spawn protection.
        or not facingTarget(bot, snapshot, origin, targetPos, profile)
        or not victimShootable(bot.target) then
        bot.nextShotAtMs = at + (profile.shotIntervalMs or 200)
        return
    end

    if bot.burstLeft <= 0 then
        local low = math.floor(tonumber(profile.burstMin) or 3)
        local high = math.floor(tonumber(profile.burstMax) or low)
        if high < low then high = low end
        bot.burstLeft = math.random(low, high)
    end

    fireOnce(bot, profile, bot.target, separation)
    bot.burstLeft = bot.burstLeft - 1
    if bot.burstLeft > 0 then
        bot.nextShotAtMs = at + (profile.shotIntervalMs or 200)
    else
        bot.nextShotAtMs = at + (profile.burstCooldownMs or 1200)
    end
end

-- ---------------------------------------------------------------------------
-- PLAYER -> BOT: the bounded report handler. Read the trust model at the top of
-- this file before changing anything here.
-- ---------------------------------------------------------------------------
local function reportState(playerId)
    local state = reports[playerId]
    if state == nil then
        state = {
            tokens = tonumber(damageSetting("maxReportsPerSecond")) or 16,
            refilledAtMs = nowMs(),
            lastReportAtMs = 0,
            lastSeq = -1,
            damageWindowStartMs = nowMs(),
            damageInWindow = 0.0,
        }
        reports[playerId] = state
    end
    return state
end

--- Cadence and damage-per-second state for the incoming (bot -> player) path.
---
--- Returns TWO tables, and the two scopes are the point:
---
---   pair    per (victim, bot). Bounds how fast ONE bot may land hits, which is
---           a weapon-cadence question and belongs to the pair.
---   window  per victim. Bounds how much damage a player may take per second
---           from ALL bots, which is a survivability question and belongs to
---           the player.
---
--- Sharing one window would let a single attacker exhaust everybody's budget;
--- sharing one cadence would let six attackers walk straight through it.
---
--- The pair is keyed by the bot's PARTICIPANT id, a small negative integer that
--- a Lua table indexes exactly -- never by the 64-bit npc id, which does not
--- survive a Lua double past 2^53.
local function incomingState(playerId, participantId)
    local window = incoming[playerId]
    if window == nil then
        window = { startedAtMs = nowMs(), amount = 0.0, pairs = {} }
        incoming[playerId] = window
    end
    local pair = window.pairs[participantId]
    if pair == nil then
        pair = { lastAtMs = 0 }
        window.pairs[participantId] = pair
    end
    return pair, window
end

local function consumeToken(state, at)
    local rate = tonumber(damageSetting("maxReportsPerSecond")) or 16
    local elapsed = at - state.refilledAtMs
    if elapsed > 0 then
        state.tokens = math.min(rate, state.tokens + (elapsed / 1000.0) * rate)
        state.refilledAtMs = at
    end
    if state.tokens < 1.0 then return false end
    state.tokens = state.tokens - 1.0
    return true
end

local function withinDpsCeiling(state, at, amount)
    local ceiling = tonumber(damageSetting("maxDamagePerSecond")) or 220.0
    if at - state.damageWindowStartMs >= 1000 then
        state.damageWindowStartMs = at
        state.damageInWindow = 0.0
    end
    if state.damageInWindow + amount > ceiling then return false end
    state.damageInWindow = state.damageInWindow + amount
    return true
end

--- What one hit from this player's weapon is worth against a bot.
---
--- Order matters. The weapon ACTUALLY FIRED comes first, resolved through the
--- issued set; the round's equalizer weapon is the fallback for when the mode is
--- running one gun for everyone; `defaultDamage` is the floor. Before this, only
--- the middle term existed, so under `/guns` -- where there IS no round weapon --
--- every weapon priced identically at 26 and each bot took exactly four hits
--- from a sniper, an SMG or a shotgun alike.
local function weaponDamageFor(instanceId, playerId, weapon)
    local table_ = damageSetting("weaponDamage")
    if type(table_) ~= "table" then
        return tonumber(damageSetting("defaultDamage")) or Defaults.damage.defaultDamage
    end

    local keys = {
        playerId ~= nil and hostCall("weaponKey", playerId, weapon) or nil,
        hostCall("roundWeaponKey", instanceId),
    }
    for _, key in ipairs(keys) do
        if key ~= nil then
            local value = tonumber(table_[tostring(key)])
            if value ~= nil then return value end
        end
    end
    return tonumber(damageSetting("defaultDamage")) or Defaults.damage.defaultDamage
end

--- Gates 1 to 6: everything that does not depend on the shape of the report.
---
--- Returns `instanceId, state, at` on success and `nil, reason` on refusal, so
--- a caller reads the SECOND return as the report state on success and as the
--- refusal reason on failure. Both call sites branch on the first return before
--- touching the second.
--- `path` is `"engine"` or `"ray"`, and GATE 0 is the R5 interlock.
---
--- It lives here rather than only in each handler on purpose. Every observation
--- path must pass through this function, so putting the mode check at the door
--- makes "exactly one path is admitted" a property of the code rather than a
--- convention a future handler is trusted to remember. The handlers keep their
--- own check as well, so a refusal is logged with the reason that names the
--- path; this one is the backstop that cannot be forgotten.
local function admitReport(playerId, weapon, seq, path)
    if setting("enabled") ~= true then return nil, "bots_disabled" end

    -- Gate 0: the mode owns which path is live. `nil` is treated as the engine
    -- path, so an un-migrated caller fails closed under scripted combat rather
    -- than slipping through unclassified.
    local native = nativeCombat()
    if path == "ray" then
        if native then return nil, "ray_path_wrong_mode" end
        if damageSetting("acceptAimRayReports") ~= true then
            return nil, "ray_reports_disabled"
        end
    else
        if not native then return nil, "engine_path_wrong_mode" end
        if damageSetting("acceptEngineHitReports") ~= true then
            return nil, "engine_reports_disabled"
        end
    end

    local instanceId = hostCall("instanceOfPlayer", playerId)
    if instanceId == nil then return nil, "no_instance" end
    if DeathmatchBots.count(instanceId) == 0 then return nil, "no_bots" end
    if not playerAlive(playerId) then return nil, "shooter_not_alive" end

    -- Gate 2: the same weapon rule the PvP arbiter enforces -- now actually the
    -- same one. `weaponAccepted` consults the whole issued set, so a sidearm or
    -- a katana counts against a bot exactly as it already counted against a
    -- player. `nil` means the book could not answer, which falls back to the
    -- primary-slot check rather than opening the gate.
    if damageSetting("requireVerifiedWeapon") ~= false then
        local accepted = hostCall("weaponAccepted", playerId, weapon)
        if accepted == false then return nil, "wrong_weapon" end
        if accepted == nil then
            local expected = normalizeWeaponId(hostCall("verifiedWeaponId", playerId))
            if expected == "" then return nil, "weapon_not_verified" end
            if normalizeWeaponId(weapon) ~= expected then return nil, "wrong_weapon" end
        end
    end

    local at = nowMs()
    local state = reportState(playerId)

    -- Gate 3: cadence.
    local minimum = tonumber(damageSetting("minReportIntervalMs")) or 45
    if at - state.lastReportAtMs < minimum then return nil, "cadence" end
    if not consumeToken(state, at) then return nil, "rate" end
    state.lastReportAtMs = at

    -- Gate 4: duplicate suppression. A replayed packet does not advance seq.
    --
    -- A client resource reload restarts the counter at zero, and a strict
    -- monotonic rule would then reject that player's every shot for the rest of
    -- the session -- a silent, permanent, one-player outage, which is a far
    -- worse failure than the replay it prevents. A large backwards jump is
    -- therefore read as a restart and resynchronised. That is safe because
    -- replay protection is not what bounds the damage: the cadence gate, the
    -- token bucket and the dps ceiling are, and they are untouched by it.
    local sequence = tonumber(seq)
    if sequence ~= nil then
        if sequence <= state.lastSeq then
            if sequence + 64 >= state.lastSeq then return nil, "duplicate_shot" end
            logDecision(playerId, "sequence_resync", state.lastSeq)
        end
        state.lastSeq = sequence
    end

    return instanceId, state, at
end

local function applyBotHit(playerId, instanceId, state, at, bot, hitZ, footZ, weapon)
    local headMin = tonumber(damageSetting("headMinM")) or 1.55
    -- Gate 8: the body part is derived from the intercept, never reported.
    local headshot = (hitZ - footZ) >= headMin

    -- Gate 9: the amount is the server's, priced from the weapon actually fired.
    local amount = weaponDamageFor(instanceId, playerId, weapon)
    if headshot then
        amount = amount * (tonumber(damageSetting("headshotMultiplier")) or 2.0)
    end

    -- Gate 10: the per-player, per-second damage ceiling.
    if not withinDpsCeiling(state, at, amount) then
        logDecision(playerId, "dps_cap", amount)
        return false
    end

    local applied = safe(Open77.npcs.applyDamage, bot.npcId, amount,
        "player:" .. tostring(playerId), "firearm")
    if applied ~= true then
        logDecision(playerId, "apply_refused", tostring(applied))
        return false
    end

    bot.lastAttacker = playerId
    bot.lastCombatAtMs = at          -- this body is fighting; seek stays away
    bot.health = math.max(0.0, (bot.health or bot.maxHealth) - amount)

    hostCall("creditDamage", instanceId, playerId, bot.participantId, amount, {
        headshot = headshot, cause = "firearm", victimIsBot = true,
    })

    local lethal = bot.health <= 0.0
    if lethal then declareDeath(bot, playerId, "firearm", headshot) end

    -- The platform's `open77:hitConfirmed` only fires for player victims, so
    -- the shooter's hitmarker for a bot has to come from here. It is emitted by
    -- the SERVER after the server decided the hit, so it is authoritative in
    -- exactly the same sense.
    TriggerClientEvent("deathmatch:botHitConfirmed", playerId, {
        botId = bot.participantId,
        name = bot.name,
        amount = amount,
        bodyPart = headshot and "head" or "torso",
        lethal = lethal,
        health = bot.health,
        maxHealth = bot.maxHealth,
    })
    return true
end

-- ---------------------------------------------------------------------------
-- THE ENGINE HIT REPORTS. Both directions, and each is reported by the client
-- that OWNS the body -- see the header for why that rule is what makes this
-- work at all.
-- ---------------------------------------------------------------------------

--- player -> bot. `Open77CombatReportNpcHit` fired on the shooter's machine off
--- a real `gameHitEvent`, so the engine already resolved the bones, the cover
--- and the weapon stats. Everything this file adds is the things the engine
--- does not know: which instance, which round weapon, and what a bot is worth.
---
--- WHAT IS TAKEN FROM THE CLIENT: the npc id, and the world Z of the intercept.
--- WHAT IS NOT: the amount (gate 9's table) and the body part (derived below
--- from the intercept against the CANONICAL bot transform, which the client
--- does not supply and cannot move).
RegisterNetEvent("deathmatch:npcHit", function(payload)
    local playerId = playerNumber(source)
    if playerId == nil then return end
    engineHitsSeen = engineHitsSeen + 1
    if not nativeCombat() then
        -- R5, enforced rather than trusted: under scripted combat this event is
        -- refused by name, so flipping the mode cannot leave both observation
        -- paths crediting the same shot.
        return logDecision(playerId, "engine_reports_wrong_mode", "")
    end
    if damageSetting("acceptEngineHitReports") ~= true then
        return logDecision(playerId, "engine_reports_disabled", "")
    end
    if type(payload) ~= "table" then
        return logDecision(playerId, "malformed", type(payload))
    end

    local instanceId, state, at = admitReport(playerId, payload.weapon, payload.seq, "engine")
    if instanceId == nil then return logDecision(playerId, state, payload.weapon) end

    -- The victim is named, not chosen -- and that is a smaller say than the old
    -- ray report gave, not a larger one. A ray let a client aim anywhere inside
    -- an eight-metre origin tolerance and have the server pick whatever it
    -- crossed; this requires the engine to have actually computed a hit on this
    -- specific body, and then still checks the body is a live bot of the
    -- shooter's own instance and bucket.
    local bot = botByNpc[idKey(payload.npcId) or ""]
    if bot == nil or bot.state ~= "alive" then
        return logDecision(playerId, "unknown_bot", tostring(payload.npcId))
    end
    if tostring(bot.instanceId) ~= tostring(instanceId) then
        return logDecision(playerId, "cross_instance", tostring(bot.instanceId))
    end
    -- Friendly fire, arena side. The platform cancels it between players; this
    -- is the same rule for the player -> bot direction, which never reaches the
    -- platform's arbiter.
    if sameArenaSide(playerId, bot.participantId) then
        return logDecision(playerId, "friendly_bot", tostring(bot.participantId))
    end

    local shooter = playerPosition(playerId)
    local position = botPosition(bot)
    if shooter == nil or position == nil then
        return logDecision(playerId, "position_unknown", "")
    end
    if position.bucket ~= shooter.bucket then
        return logDecision(playerId, "bucket_mismatch", tostring(position.bucket))
    end
    local separation = distance3(shooter, position)
    if separation > (tonumber(damageSetting("reportMaxRangeM")) or 120.0) then
        return logDecision(playerId, "range", ("%.1fm"):format(separation))
    end

    -- The intercept arrives as an ABSOLUTE world Z. Differencing it against the
    -- canonical foot sample here, rather than accepting a height from the
    -- client, is what keeps the headshot multiplier out of the client's hands.
    -- A missing or non-finite Z degrades to a torso hit rather than refusing
    -- the whole report: an unreadable body part is not an unreadable hit.
    local hitZ = tonumber(payload.hitZ)
    if not isFinite(hitZ) then hitZ = position.z end

    if applyBotHit(playerId, instanceId, state, at, bot, hitZ, position.z, payload.weapon) then
        engineHitsApplied = engineHitsApplied + 1
    end
end)

--- bot -> player, reported by the VICTIM.
---
--- This inverts the direction of trust the PvP arbiter uses, and the inversion
--- is forced rather than chosen: the attacker is an NPC and an NPC has no
--- client. The choice was between this and letting the NPC's authority client
--- report damage on other people's behalf -- which would mean bot damage only
--- ever reaches whoever happens to hold the lease, and would depend on a
--- hostile NPC acquiring a player PROXY, which nobody has measured.
---
--- The abuse direction is worth naming plainly, because it is the opposite of
--- the usual one. A victim cannot inflate their own damage -- the amount is
--- clamped and the dps ceiling is per player. A victim CAN under-report by
--- simply never sending, which is immunity to bots. That is accepted here: it
--- is a modified client harming only a bot fight, in a mode whose rounds are
--- already excluded from the ladder for containing bots at all.
RegisterNetEvent("deathmatch:npcHurtMe", function(payload)
    local playerId = playerNumber(source)
    if playerId == nil then return end
    incomingSeen = incomingSeen + 1
    if not nativeCombat() then
        return logDecision(playerId, "incoming_wrong_mode", "")
    end
    if type(payload) ~= "table" then
        return logDecision(playerId, "malformed", type(payload))
    end
    if setting("enabled") ~= true then return end

    local instanceId = hostCall("instanceOfPlayer", playerId)
    if instanceId == nil then return logDecision(playerId, "no_instance", "") end

    local bot = botByNpc[idKey(payload.npcId) or ""]
    if bot == nil or bot.state ~= "alive" then
        return logDecision(playerId, "incoming_unknown_bot", tostring(payload.npcId))
    end
    if tostring(bot.instanceId) ~= tostring(instanceId) then
        return logDecision(playerId, "incoming_cross_instance", tostring(bot.instanceId))
    end
    -- Friendly fire, the other direction: a bot on the victim's own arena side
    -- does not hurt them. The engine has no side to read and will fire anyway;
    -- the ledger is what decides whether it counts.
    if sameArenaSide(playerId, bot.participantId) then
        return logDecision(playerId, "incoming_friendly_bot", tostring(bot.participantId))
    end

    -- The spawn shield, and this is the ONE gate that was already known to be
    -- missing: the respawn grace protects the ENGINE damage path, and bot
    -- damage does not travel it. Without this the owner spawns under a visible
    -- shield and is killed through it -- which is exactly what happened.
    if not victimShootable({ kind = "player", id = playerId }) then
        return logDecision(playerId, "incoming_protected", "")
    end

    local victim = playerPosition(playerId)
    local position = botPosition(bot)
    if victim == nil or position == nil then
        return logDecision(playerId, "position_unknown", "")
    end
    if position.bucket ~= victim.bucket then
        return logDecision(playerId, "incoming_bucket_mismatch", tostring(position.bucket))
    end
    local separation = distance3(victim, position)
    if separation > (tonumber(damageSetting("reportMaxRangeM")) or 120.0) then
        return logDecision(playerId, "incoming_range", ("%.1fm"):format(separation))
    end

    local at = nowMs()
    local pair, window = incomingState(playerId, bot.participantId)
    local minimum = tonumber(combatSetting("minIntervalMs", "incoming")) or 90
    if at - (pair.lastAtMs or 0) < minimum then
        return logDecision(playerId, "incoming_cadence", tostring(bot.participantId))
    end
    pair.lastAtMs = at
    -- This bot is shooting somebody. The seek guard reads this and stays out.
    bot.lastCombatAtMs = at

    -- THE AMOUNT. The engine's, because "the engine's combat, faithfully" is the
    -- whole point of this path -- but scaled and CLAMPED, because a gang
    -- record's rifle is priced for a levelled solo player and this mode's health
    -- is a hundred-point scale. Unclamped, one burst is a kill and the round is
    -- unplayable.
    -- A ZERO IS NOT A REFUSAL. The engine declining to price a hit it plainly
    -- resolved is exactly the failure that deleted every bot report in the
    -- 2026-09-01 session: the client used to suppress the whole message, and
    -- the server never learned a shot had landed. `fallbackDamage` is the knob
    -- that exists for this, so an unusable engine number now selects it and the
    -- report survives. A NEGATIVE or non-finite number is still a refusal --
    -- that is malformed, not merely unpriced.
    local amount
    if combatSetting("useEngineAmount", "incoming") == true then
        amount = tonumber(payload.amount)
        if amount ~= nil and isFinite(amount) and amount <= 0.0 then
            logThrottled("incoming_unpriced:" .. tostring(playerId),
                ("bot %d hit player %d and the engine priced it at %s; using fallbackDamage")
                    :format(bot.participantId, playerId, tostring(amount)))
            amount = tonumber(combatSetting("fallbackDamage", "incoming")) or 18.0
        end
        if not isFinite(amount) or amount <= 0.0 then
            return logDecision(playerId, "incoming_malformed_amount", tostring(payload.amount))
        end
        amount = amount * (tonumber(combatSetting("scale", "incoming")) or 1.0)
    else
        amount = tonumber(combatSetting("fallbackDamage", "incoming")) or 18.0
    end
    amount = math.min(amount, tonumber(combatSetting("maxPerHit", "incoming")) or 34.0)
    if amount <= 0.0 then return end

    -- A per-player, per-second ceiling on top of the per-hit clamp. This one is
    -- not redundant: the per-hit clamp bounds ONE bullet, and six bots firing
    -- at one player is a rate nothing upstream of here bounds.
    local ceiling = tonumber(combatSetting("maxDamagePerSecond", "incoming")) or 90.0
    if at - (window.startedAtMs or 0) >= 1000 then
        window.startedAtMs = at
        window.amount = 0.0
    end
    if (window.amount or 0.0) + amount > ceiling then
        return logDecision(playerId, "incoming_dps_cap", ("%.1f"):format(amount))
    end
    window.amount = (window.amount or 0.0) + amount

    -- `attacker = bot.npcId` in its NATIVE form, never through `tonumber`: E7
    -- measured the npc id surviving all the way into `open77:playerDamaged`, so
    -- the kill feed names the bot and the directional damage indicator has a
    -- real source to point at. The kernel translates it to the bot's negative
    -- participant id through `DeathmatchBots.attackerId`.
    --
    -- Damage is NOT credited here. The platform emits `open77:playerDamaged` /
    -- `open77:playerKilled` and the kernel's ledger consumes them; crediting
    -- here as well would double-count.
    local ok, reason = Open77.players.damage(playerId, amount, {
        attacker = bot.npcId,
        cause = "firearm",
    })
    if ok ~= true then
        logThrottled(("incoming:%d:%s"):format(playerId, tostring(reason)),
            ("bot %d damage on player %d refused: %s"):format(
                bot.participantId, playerId, tostring(reason)))
    end
end)

--- bot -> bot, reported by the client holding the VICTIM's simulation lease.
---
--- The owner asked for this in as many words -- "les bots doivent se tuer entre
--- eux aussi" -- and under native combat it is not something this file scripts.
--- It is a question about two records that the engine's attitude matrix answers,
--- and it can only answer yes if the roster is more than one gang. That is why
--- `config.templates` names three.
---
--- WHO REPORTS. There is no player on either end, so neither owner rule covers
--- it: every client streaming both bodies watches the same exchange. The client
--- native already discarded it unless that client holds the victim's authority
--- lease -- exactly one client per NPC per epoch, elected by the server and
--- epoch-checked on every packet -- so by the time it arrives here it is
--- unique. This handler therefore does NOT try to deduplicate; it validates
--- that both bodies are bots of the same instance and applies.
---
--- WHY THE SENDER IS NOT CHECKED against the lease here: the server-side lease
--- holder is known (`authorityPlayerId` on the NPC snapshot) and comparing it
--- would be a stronger gate -- but a lease can hand over between the hit and
--- the packet, and rejecting on that race would silently drop real bot kills
--- during exactly the moments bots are moving fastest. The bound that matters
--- is instead a cap on how much crossfire damage one bot can take per second,
--- below, which holds whether the report is unique or not.
--- EVERY REFUSAL BELOW IS LOGGED, and that is a change made for a reason.
---
--- This handler shipped with eleven silent `return`s. A session that produced
--- no bot-versus-bot damage therefore looked EXACTLY like a session in which
--- the engine never fired a shot -- the server log was empty either way, and
--- the empty log was read as "no report ever arrived" when it could equally
--- have meant "eleven reports arrived and every one was dropped here". That is
--- the failure shape this project has paid for repeatedly: a path that fails
--- closed with no trace. `crossfireCount` also tallies arrivals unconditionally,
--- so `/dm.bot list` can distinguish the two without reading a log at all.
RegisterNetEvent("deathmatch:npcCrossfire", function(payload)
    local playerId = playerNumber(source)
    if playerId == nil then return end
    crossfireSeen = crossfireSeen + 1
    if not nativeCombat() then
        return logDecision(playerId, "crossfire_wrong_mode", "")
    end
    if setting("enabled") ~= true then
        return logDecision(playerId, "crossfire_bots_disabled", "")
    end
    if type(payload) ~= "table" then
        return logDecision(playerId, "crossfire_malformed", type(payload))
    end

    local victim = botByNpc[idKey(payload.victim) or ""]
    local attacker = botByNpc[idKey(payload.attacker) or ""]
    if victim == nil or attacker == nil then
        -- Almost always a body that has already been destroyed and whose report
        -- was in flight. Worth a line anyway: if it is CONSTANT, the client and
        -- the server disagree about npc ids, which no other readout would show.
        return logDecision(playerId, "crossfire_unknown_bot",
            ("victim=%s attacker=%s"):format(
                tostring(payload.victim), tostring(payload.attacker)))
    end
    if victim.state ~= "alive" or attacker.state ~= "alive" then
        return logDecision(playerId, "crossfire_not_alive",
            ("victim=%s attacker=%s"):format(victim.state, attacker.state))
    end
    if victim.participantId == attacker.participantId then
        return logDecision(playerId, "crossfire_self", tostring(victim.participantId))
    end
    if tostring(victim.instanceId) ~= tostring(attacker.instanceId) then
        return logDecision(playerId, "crossfire_instance_mismatch",
            ("%s vs %s"):format(tostring(victim.instanceId), tostring(attacker.instanceId)))
    end
    -- Two bots on the SAME arena side. The hostility sweep made them enemies
    -- because it made every body of the bucket an enemy of every other one, and
    -- it had no team to consult. Refusing at the ledger is the whole of the
    -- correction, and it is the only one available without a client change.
    if sameArenaSide(victim.participantId, attacker.participantId) then
        return logDecision(playerId, "crossfire_same_side",
            ("%d vs %d"):format(victim.participantId, attacker.participantId))
    end

    -- The reporter must at least be a participant of the instance it is
    -- describing. It is a weak check on purpose -- any of the instance's
    -- clients may legitimately hold the lease -- but it stops a player in
    -- another instance narrating a fight they cannot see.
    local reporterInstance = hostCall("instanceOfPlayer", playerId)
    if reporterInstance == nil
        or tostring(reporterInstance) ~= tostring(victim.instanceId) then
        return logDecision(playerId, "crossfire_foreign_instance", tostring(victim.instanceId))
    end

    local at = nowMs()
    -- A STRING key, and it must be. `incoming` is otherwise indexed by player
    -- id, and a bot's participant id negated is a small positive integer -- so
    -- bot -1 would land on player 1's damage window and the two would eat each
    -- other's budget. Namespacing it is the whole fix.
    local pair, window = incomingState("bot:" .. tostring(victim.participantId),
        attacker.participantId)
    local minimum = tonumber(combatSetting("minIntervalMs", "incoming")) or 90
    if at - (pair.lastAtMs or 0) < minimum then
        return logDecision(playerId, "crossfire_cadence", tostring(minimum))
    end
    pair.lastAtMs = at

    -- Same rule as the incoming path above, and for the same reason: the
    -- gamemode prices crossfire, so an engine zero selects `fallbackDamage`
    -- rather than deleting a bot-versus-bot exchange the engine resolved.
    local amount
    if combatSetting("useEngineAmount", "incoming") == true then
        amount = tonumber(payload.amount)
        if amount ~= nil and isFinite(amount) and amount <= 0.0 then
            logThrottled("crossfire_unpriced",
                ("crossfire arrived unpriced by the engine (%s); using fallbackDamage")
                    :format(tostring(amount)))
            amount = tonumber(combatSetting("fallbackDamage", "incoming")) or 18.0
        end
        if not isFinite(amount) or amount <= 0.0 then
            return logDecision(playerId, "crossfire_amount", tostring(payload.amount))
        end
        amount = amount * (tonumber(combatSetting("scale", "incoming")) or 1.0)
    else
        amount = tonumber(combatSetting("fallbackDamage", "incoming")) or 18.0
    end
    amount = math.min(amount, tonumber(combatSetting("maxPerHit", "incoming")) or 34.0)
    if amount <= 0.0 then
        return logDecision(playerId, "crossfire_amount_zero", tostring(amount))
    end

    -- Per-victim ceiling, and here it is doing real work rather than guarding an
    -- exploit: a bot caught in a three-way crossfire would otherwise evaporate
    -- in a tick, which reads as a bug even when it is arithmetic.
    local ceiling = tonumber(combatSetting("maxDamagePerSecond", "incoming")) or 90.0
    if at - (window.startedAtMs or 0) >= 1000 then
        window.startedAtMs = at
        window.amount = 0.0
    end
    if (window.amount or 0.0) + amount > ceiling then
        return logDecision(playerId, "crossfire_dps_cap", tostring(ceiling))
    end
    window.amount = (window.amount or 0.0) + amount

    local applied = safe(Open77.npcs.applyDamage, victim.npcId, amount,
        "bot:" .. tostring(attacker.participantId), "firearm")
    if applied ~= true then
        return logDecision(playerId, "crossfire_apply_refused", tostring(applied))
    end
    crossfireApplied = crossfireApplied + 1

    -- The victim remembers who shot it. Without this a bot finished through the
    -- tick's HEALTH BACKSTOP -- rather than through the branch below -- credits
    -- `nil`, and the kill lands as an environment death that nobody scored.
    -- `onNpcDied` reads the same field.
    victim.lastAttacker = attacker.participantId
    -- BOTH ends are fighting, and both must be left to the engine.
    victim.lastCombatAtMs = at
    attacker.lastCombatAtMs = at
    victim.health = math.max(0.0, (victim.health or victim.maxHealth) - amount)
    hostCall("creditDamage", victim.instanceId, attacker.participantId,
        victim.participantId, amount,
        { headshot = false, cause = "firearm", victimIsBot = true })
    if victim.health <= 0.0 then
        declareDeath(victim, attacker.participantId, "firearm", false)
    end
end)

-- ---------------------------------------------------------------------------
-- Platform events
-- ---------------------------------------------------------------------------
-- The outgoing VM still gets one scheduler tick after this fires
-- (`LuaResourceRuntime.Stop` emits, then calls `Tick`), and the host is at that
-- moment removing every NPC this resource owns. A body created in that window is
-- a spawn racing its own teardown, which is the one thing the client cannot
-- cancel. Refuse from here on; the host reaps what already exists.
AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopping = true
    log("resource stopping -- no further bot bodies will be created")
end)

AddEventHandler("onNpcDamaged", function(npcId, sourceTag, amount, health)
    local bot = botByNpc[idKey(npcId) or ""]
    if bot == nil then return end
    bot.health = tonumber(health) or bot.health
    bot.lastCombatAtMs = nowMs()
    local playerId = tostring(sourceTag or ""):match("^player:(%d+)$")
    if playerId ~= nil then bot.lastAttacker = playerNumber(playerId) end
end)

AddEventHandler("onNpcDied", function(npcId, sourceTag, cause)
    local bot = botByNpc[idKey(npcId) or ""]
    if bot == nil then return end
    local tag = tostring(sourceTag or "")
    local killer = nil
    local player = tag:match("^player:(%-?%d+)$")
    if player ~= nil then
        killer = playerNumber(player)
    else
        local other = tag:match("^bot:(%-%d+)$")
        if other ~= nil then killer = tonumber(other) end
    end
    declareDeath(bot, killer or bot.lastAttacker, cause or "firearm", false)
end)

AddEventHandler("onNpcRemoved", function(npcId, reason)
    local bot = botByNpc[idKey(npcId) or ""]
    if bot == nil then return end
    log(("bot %d npc removed by the platform (%s)"):format(
        bot.participantId, tostring(reason)))
    bots[bot.participantId] = nil
    botByNpc[bot.npcKey] = nil
    hostCall("removeParticipant", bot.instanceId, bot.participantId,
        "npc_removed", bot.npcAlias)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = playerNumber(playerIdStr)
    if playerId == nil then return end
    reports[playerId] = nil
    incoming[playerId] = nil
    for _, bot in pairs(bots) do
        if bot.target ~= nil and bot.target.kind == "player"
            and bot.target.id == playerId then
            bot.target = nil
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Commands. ACL-GATED: the third argument of RegisterCommand is `restricted`,
-- and the transport derives `command.dm.bot` from the command word and refuses
-- before this handler is ever scheduled. That gate is the ONLY authorisation on
-- this platform -- there is no Lua-callable permission check -- so bots are
-- never reachable from a net event.
-- ---------------------------------------------------------------------------
local function output(source_, raw, ok, message)
    log(message)
    if source_ ~= nil and source_ > 0 then
        TriggerClientEvent("open77:command:result", source_, raw or "",
            ok == true, tostring(message))
    end
    return ok == true
end

--- Arguments after the verb, in any order: a bare number is a count, an
--- `instance=<id>` token names an instance, anything else is a profile key.
--- Order-free because `dm.bot add 3 veteran` and `dm.bot add veteran 3` are the
--- same intent and refusing one of them is a papercut for no gain.
local function parseArguments(args)
    local parsed = { count = nil, profile = nil, instance = nil }
    for index = 2, (args.n or #args) do
        local token = tostring(args[index] or "")
        local named = token:match("^instance=(.+)$")
        if named ~= nil then
            parsed.instance = named
        elseif tonumber(token) ~= nil then
            parsed.count = math.floor(tonumber(token))
        elseif token ~= "" then
            parsed.profile = token
        end
    end
    return parsed
end

--- The explicit `instance=<id>`, else the caller's own instance, else -- for the
--- server console, which has no position -- the only instance open, if there is
--- exactly one. Guessing between two would be worse than refusing.
local function resolveInstance(source_, parsed)
    if parsed.instance ~= nil then return parsed.instance end
    local playerId = playerNumber(source_)
    if playerId ~= nil then
        local own = hostCall("instanceOfPlayer", playerId)
        if own ~= nil then return own end
    end
    local open = hostCall("instances")
    if type(open) == "table" and #open == 1 then return open[1] end
    return nil
end

RegisterCommand("dm.bot", function(source_, args, raw)
    local caller = tonumber(source_) or 0
    if setting("enabled") ~= true then
        return output(caller, raw, false, text("disabled"))
    end
    if activeHost() == nil then
        return output(caller, raw, false, text("noHost"))
    end

    local action = tostring(args[1] or ""):lower()
    if action == "" then action = "status" end

    if action == "list" or action == "status" then
        local rows = {}
        local native = nativeCombat()
        for _, bot in pairs(bots) do
            if native then
                -- Under native combat the yaw/dot pair is meaningless -- there
                -- is no facing cone because there is no scripted gun. What a
                -- reader needs instead is which GANG this body is (bot-versus-
                -- bot depends entirely on the roster not being one faction) and
                -- whether the leash is currently fighting it.
                -- `life` and `seek` are the two bug readouts. A `life` that
                -- never advances while kills are being credited is bug 2
                -- coming back; a `seek` stuck on `combat` while nothing is
                -- happening means `lastCombatAtMs` is being stamped by
                -- something that is not a fight.
                -- `side` and `held` are the ARENA readout. A 3v3 that ends with
                -- every bot on one side is a formation bug, and a bot stuck at
                -- `held=true` through a live round is elimination working --
                -- but stuck at `held=true` through a BUY window is
                -- `arenaRoundStart` not having run, which no other line shows.
                rows[#rows + 1] = ("%d %s [%s] i=%s hp=%.0f/%.0f %s tmpl=%s out=%d life=%d seek=%s side=%s held=%s"):format(
                    bot.participantId, bot.name, bot.profileKey, tostring(bot.instanceId),
                    bot.health or 0, bot.maxHealth or 0, bot.state,
                    tostring(bot.template), bot.outsideSamples or 0,
                    bot.lifeId or 1, tostring(bot.seekReason or "-"),
                    tostring(bot.side or "-"), tostring(bot.respawnHeld == true))
            else
                rows[#rows + 1] = ("%d %s [%s] i=%s hp=%.0f/%.0f %s yaw=%s dot=%s"):format(
                    bot.participantId, bot.name, bot.profileKey, tostring(bot.instanceId),
                    bot.health or 0, bot.maxHealth or 0, bot.state,
                    bot.debugYaw ~= nil and ("%.0f"):format(bot.debugYaw) or "-",
                    bot.debugDot ~= nil and ("%.2f"):format(bot.debugDot) or "-")
            end
        end
        if #rows == 0 then return output(caller, raw, true, text("listEmpty")) end
        -- The report tally comes FIRST, because it is the one reading that says
        -- whether the combat pipeline is alive at all. All zeros with bots on
        -- the ground means no client ever offered a hit, which is an engine
        -- problem (attitude or acquisition) and not a gamemode one; a non-zero
        -- `seen` beside a zero `ok` means this file refused them, and the
        -- reason is in the log next to it.
        return output(caller, raw, true,
            ("mode=%s/%s reports[playerHit=%d/%d botHurtMe=%d crossfire=%d/%d]"
                .. " seek[issued=%d refused=%d] respawn[run=%d failed=%d]"
                .. " bodies[created=%d released=%d live=%d]"
                .. " spawnGate[stopping=%d settling=%d spacing=%d] | %s"):format(
                native and "native" or "scripted",
                configuredRespawnMode() ~= respawnMode()
                    and (respawnMode() .. "(" .. configuredRespawnMode() .. " refused)")
                    or respawnMode(),
                engineHitsApplied, engineHitsSeen, incomingSeen,
                crossfireApplied, crossfireSeen,
                seekIssued, seekRefused, respawnsRun, respawnsFailed,
                bodiesCreated, bodiesReleased, liveBodies(),
                spawnGateStopping, spawnGateSettling, spawnGateSpacing,
                table.concat(rows, " | ")))
    end

    if action == "clear" and tostring(args[2] or ""):lower() == "all" then
        local removed = DeathmatchBots.clear(nil, "command_clear")
        return output(caller, raw, true, (text("cleared")):format(removed, "every instance"))
    end

    local parsed = parseArguments(args)
    if parsed.profile ~= nil and profiles()[parsed.profile] == nil then
        return output(caller, raw, false,
            (text("unknownProfile")):format(parsed.profile))
    end

    local instanceId = resolveInstance(source_, parsed)
    if instanceId == nil then
        return output(caller, raw, false, text("noInstance"))
    end
    if instanceView(instanceId) == nil then
        return output(caller, raw, false, (text("unknownInstance")):format(tostring(instanceId)))
    end

    if action == "clear" then
        local removed = DeathmatchBots.clear(instanceId, "command_clear")
        return output(caller, raw, true,
            (text("cleared")):format(removed, tostring(instanceId)))
    end

    if action == "add" or action == "fill" then
        local profileKey = parsed.profile

        local added, reason, queued
        if action == "fill" then
            added, reason, queued = DeathmatchBots.fill(instanceId, profileKey)
        else
            added, reason, queued = DeathmatchBots.add(
                instanceId, parsed.count or 1, profileKey)
        end

        -- Spawns are paced to keep the entity service out of the churn that
        -- crashed the client, so a large request lands over the next few
        -- seconds rather than at once. Say so: an operator who asked for six,
        -- saw one, and was told nothing reasonably concluded it was broken.
        queued = tonumber(queued) or 0
        if queued > 0 then
            return output(caller, raw, true,
                ("Added %d bot(s) to instance %s now; %d more queued and arriving over the next few seconds (spawns are paced)."):format(
                    added, tostring(instanceId), queued))
        end

        if added == 0 then
            if reason == "instance_full" then
                return output(caller, raw, false,
                    (text("alreadyFull")):format(tostring(instanceId)))
            end
            if reason == "no_spawn_marks" then
                return output(caller, raw, false,
                    (text("noSpawns")):format(tostring(instanceId)))
            end
            return output(caller, raw, false,
                (text("addFailed")):format(tostring(reason)))
        end

        local _, resolvedKey = profileFor(profileKey)
        local message = action == "fill"
            and (text("filled")):format(tostring(instanceId), added,
                DeathmatchBots.count(instanceId))
            or (text("added")):format(added, tostring(instanceId), resolvedKey,
                DeathmatchBots.count(instanceId))
        return output(caller, raw, true, message)
    end

    return output(caller, raw, false, text("usage"))
end, true)

-- ---------------------------------------------------------------------------
-- Start. One thread, wrapped in pcall so a host that throws never stalls the
-- bots, and never the rest of the resource.
-- ---------------------------------------------------------------------------
local function startOnce()
    if started then return end
    started = true

    -- Say the refusal out loud, once, at the only moment anybody is reading.
    -- A knob that is silently ignored is worse than one that is honoured
    -- badly: the next reader tunes the value and watches nothing change.
    if configuredRespawnMode() == "move" then
        log("bots.combat.respawn.mode = \"move\" is REFUSED; \"rebuild\" used"
            .. " instead. The client does not yet withhold NpcMotion while a"
            .. " placement is in flight, so a moved respawn spends the"
            .. " projection-adoption grant on the corpse's position and the"
            .. " body never lands on its mark (195 motion_jump in 30 min,"
            .. " production PvP 2026-09-01). See shared/config.lua.")
    end

    SetTimeout(250, function()
        reconcile()
    end)

    CreateThread(function()
        local lastMovementAtMs = 0
        while true do
            local interval = math.max(50, math.floor(tonumber(setting("tickMs"))
                or Defaults.tickMs))
            if activeHost() ~= nil and setting("enabled") == true then
                local at = nowMs()
                local movementDue = at - lastMovementAtMs
                    >= (tonumber(setting("movementTickMs")) or Defaults.movementTickMs)
                if movementDue then lastMovementAtMs = at end
                -- Drain at most ONE parked spawn per tick, before the bots
                -- run: `createBot` re-checks every gate itself, so a tick that
                -- is still inside the spacing window simply fails and the entry
                -- waits. An instance that closed underneath a parked entry
                -- drops it rather than resurrecting it.
                if #pendingSpawns > 0 then
                    local entry = table.remove(pendingSpawns, 1)
                    local view = instanceView(entry.instanceId)
                    if view ~= nil then
                        local bot, reason = createBot(
                            entry.instanceId, view, entry.profileKey,
                            { side = entry.side, marks = entry.marks })
                        if bot == nil and (reason == "spacing" or reason == "settling") then
                            table.insert(pendingSpawns, 1, entry)
                        elseif bot == nil then
                            log(("parked spawn dropped for instance %s: %s"):format(
                                tostring(entry.instanceId), tostring(reason)))
                        elseif type(entry.onCreated) == "function" then
                            -- The arena needs the participant id to put the bot
                            -- on a roster, and a paced spawn arrives after the
                            -- request returned. `pcall` because a raising
                            -- callback here would stall the whole bot tick.
                            local ok, err = pcall(entry.onCreated, bot.participantId, entry.side)
                            if not ok then
                                log(("parked spawn callback raised: %s"):format(tostring(err)))
                            end
                        end
                    end
                end

                for _, bot in pairs(bots) do
                    local ok, err = pcall(tickBot, bot, at, movementDue)
                    if not ok then
                        log(("bot %d tick raised: %s"):format(
                            bot.participantId, tostring(err)))
                    end
                end
            end
            Wait(interval)
        end
    end)
end

startOnce()

local function profileKeys()
    local keys = {}
    for key in pairs(profiles()) do keys[#keys + 1] = key end
    table.sort(keys)
    return table.concat(keys, ",")
end

log(("ready -- difficulty=%s profiles=%s templates=%s fillWithBots=%s fillTarget=%s ladderExclusion=%s"):format(
    tostring(setting("difficulty")), profileKeys(),
    table.concat(setting("templates"), ","),
    tostring(setting("fillWithBots")), tostring(setting("fillTarget")),
    tostring(setting("excludeRoundsFromLadder") ~= false)))
