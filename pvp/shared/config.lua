-- Kabuki Arena -- public rules for the Open77 PvP gamemode.
--
-- THIS FILE IS SENT TO EVERY CONNECTING CLIENT. Never place a secret, an ACL
-- entry, an identity or an address in it. Everything here is publishable.
--
-- It is also the single source of truth for player-facing TEXT (`Config.strings`,
-- decision 16). The mode used to carry hardcoded unaccented French in two Lua
-- files and one HTML page; all of it is English now and all of it is here, so
-- the next language is a table rather than a search across two markup
-- languages.
--
-- Layout, in the order a reader needs it:
--
--   buckets          routing-bucket ranges -- the instance kernel's address space
--   instances        capacity, linger, ceilings
--   lobby            the one place with no combat
--   zones            which volumes each format plays in, BY NAME
--   formats          ffa / 1v1 / 2v2 / 3v3
--   round            free-for-all round timings
--   arena            elimination-round timings, queue, buy window
--   spawnProtection  the grace that is currently invisible
--   equalizer        the FFA shared-weapon rotation (decision 14)
--   kits             the arena buy list
--   loadout          equalizer or per-player choice, and the /guns prompt
--   bounds           leash sampling and the server backstop
--   combat           host-global damage policy
--   bots             difficulty profile and backfill
--   scoring          the points table
--   stations         world-UI entry points
--   strings          every player-facing string, English
--   tunables         the Warden panel contract
--
-- ---------------------------------------------------------------------------
-- THIS FILE HOLDS NO MAP GEOMETRY. `shared/kabuki.lua` DOES.
--
-- The split is not a matter of taste; it follows from how the two files are
-- produced. `kabuki.lua` is GENERATED: `/dm.survey dump` regenerates it
-- wholesale from coordinates captured in-game, so everything a surveyor's paste
-- would overwrite lives there -- the seven volume boxes, the fourteen FFA
-- marks, the per-format team clusters, the lobby station marks, and every
-- geometric predicate. This file is HAND-AUTHORED and holds rules: buckets,
-- capacity, linger, round timings, kill limit, spawn protection, the weapon
-- rotation, the kits, the tunables and the strings.
--
-- The one thing that sits on the line is `zones` below, and it lands here on
-- purpose: WHICH volumes a format plays in is a rule -- cutting the gallery
-- from 2v2 is a design decision about overwatch -- while WHERE those volumes
-- are is geometry. The names are the seam, and `server/bounds.lua` resolves
-- them against `DeathmatchKabuki.volumes` and judges them with
-- `DeathmatchKabuki.locateIn`, so there is exactly ONE containment test in the
-- resource. Two tests that can disagree is a bug waiting for a Friday.
--
-- The single geometric value left in this file is `lobby.volume`, and it is
-- here because the lobby is not part of the surveyed Kabuki map and
-- `kabuki.lua` has no survey target for it. bounds.lua prefers a `lobby_pad`
-- volume from `kabuki.lua` the moment one exists, so this is a fallback with an
-- exit, not a second store.
-- ---------------------------------------------------------------------------
DeathmatchConfig = {
    -- ======================================================================
    -- BUCKETS -- the instance kernel's address space
    -- ======================================================================
    --
    -- One instance owns one bucket for its whole life. Allocation is first-free
    -- from the range with the owner tracked, and the bucket is RELEASED on reap
    -- so two instances can never share one. See server/instances.lua.
    --
    -- The ranges are sized generously on purpose: since the wall became a
    -- client-side clamp (decision 15) instances no longer need a prop
    -- perimeter, so the 256-props-per-resource quota stopped gating instance
    -- count and the ceiling became a pure bucket-range choice. It costs nothing
    -- to reserve the range; `instances.ffaCeiling` below is the number that
    -- actually limits how many open.
    buckets = {
        lobby      = 4100,                     -- the one place with no combat
        ffaFirst   = 4200, ffaLast   = 4231,   -- 32 free-for-all instances
        arenaFirst = 4240, arenaLast = 4287,   -- 48 arena matches
    },
    -- ======================================================================
    -- INSTANCES -- capacity, fill policy, reap
    -- ======================================================================
    instances = {
        -- Decision 13. Fourteen surveyed marks give roughly one per player plus
        -- the headroom the maximin spawn choice needs to mean anything.
        ffaCapacity = 12,
        -- How many may be OPEN at once, independently of how many buckets are
        -- reserved above. Lowering this below the number currently open never
        -- closes an instance; it only refuses the next one.
        ffaCeiling   = 32,
        arenaCeiling = 48,
        -- Decision 3: fill before spread. An instance is chosen by "fullest
        -- that still has room"; a new one opens only when none has room. A
        -- 2/12 instance is a dead lobby, and two of them are worse than one
        -- 4/12.
        fillBeforeSpread = true,
        -- An emptied instance is NOT torn down immediately. A player crossing
        -- between rounds, or a single reconnect, would otherwise churn the
        -- bucket. It lingers, then releases.
        emptyLingerMs = 60000,
        -- The plan offers keeping the last instance warm "so the first joiner
        -- of the evening never waits on a wall build". E2 removed the wall
        -- build: there are no props to raise, so opening an instance is a table
        -- insert and two bucket calls. Kept as a switch because it also keeps
        -- the bucket's population/lockdown state settled, but OFF by default --
        -- its original justification no longer exists.
        keepOneWarm = false,
        -- Re-adoption after a hot reload. The registry is in-memory and a
        -- reload empties it while the players stay in their buckets, so the
        -- kernel rebuilds lazily from the next event each player produces
        -- (there is still no way to list players). A player found in a bucket
        -- inside the FFA range is re-adopted into an instance for that bucket
        -- rather than dragged back to the lobby.
        adoptOnReload = true,
    },
    -- ======================================================================
    -- LOBBY
    -- ======================================================================
    lobby = {
        -- The bucket lives in `buckets.lobby`; repeating it here would be two
        -- truths about one number.
        heading = 0.0,
        -- The surveyed Open77 laboratory landing point. Do NOT reuse Freeroam's
        -- spawn at (381.358826, -2401.794189, 181.988541): doing so made a
        -- successful deathmatch placement indistinguishable from the old
        -- gamemode spawn.
        center = { x = 1669.75, y = -739.12, z = 49.86 },
        -- The lobby leash is a BOX now, like every other boundary in the mode
        -- (decision 6). The old radius/verticalTolerance cylinder is gone.
        --
        -- PROVISIONAL, and the derivation is deliberate and of a different kind
        -- from a spawn mark: this box circumscribes the 35 m / +-12 m cylinder
        -- the shipped mode already enforced around the landing point above. A
        -- box around a boundary players already lived inside is a superset of
        -- it; it asserts nothing about walkable ground, which is the property
        -- survey discipline protects. A derived SPAWN mark would assert exactly
        -- that, and Corpo Plaza proved the assertion false.
        --
        -- bounds.lua prefers `DeathmatchKabuki.volume("lobby_pad")` over this
        -- the moment the surveyor captures one, so the exit is already built.
        volume = {
            id = "lobby_pad",
            provisional = true,
            min = { x = 1634.75, y = -774.12, z = 37.86 },
            max = { x = 1704.75, y = -704.12, z = 61.86 },
        },
        placementGraceMs = 7000,
        placementRetryMs = 250,
        placementRetryTimeoutMs = 30000,
    },
    -- ======================================================================
    -- PLACEMENT
    -- ======================================================================
    placement = {
        -- Lifts a surveyed mark slightly so a player never spawns inside the
        -- ground plane. The ONE offset applied to a captured mark anywhere in
        -- the mode, and it is vertical only.
        spawnLiftMetres = 0.35,
    },
    -- ======================================================================
    -- ZONES -- which volumes each format plays in (plan section 3)
    -- ======================================================================
    --
    -- KEYED BY FORMAT, and holding NAMES ONLY. The boxes those names refer to
    -- live in `shared/kabuki.lua`; `server/bounds.lua` resolves a name against
    -- `DeathmatchKabuki.volumes` and judges containment with
    -- `DeathmatchKabuki.locateIn`, which is the resource's one and only
    -- containment test.
    --
    -- Cutting volumes is how one surveyed map serves four formats, and each cut
    -- is a design decision rather than a geometric one -- which is exactly why
    -- the list is here and the boxes are not.
    --
    -- NOTE, and it wants settling before Phase 2 builds on either:
    -- `DeathmatchKabuki.formats[<key>].volumes` carries the same four lists, and
    -- `Kabuki.zone(format)` reads them. bounds.lua treats THIS table as
    -- authoritative and compares the two at startup, logging a warning on any
    -- divergence -- so the duplication is loud rather than silent, but it is
    -- still a duplication. The clean end state is `kabuki.formats` keeping only
    -- what the surveyor needs (mark counts, capture sets) and this table keeping
    -- the zone rule.
    zones = {
        -- The lobby is not part of the Kabuki survey; `lobby_pad` resolves from
        -- `Config.lobby.volume` unless kabuki.lua grows one.
        lobby = { label = "Lobby", volumes = { "lobby_pad" }, combat = false },
        -- FFA and 3v3: the whole footprint. Vertical play and four stair chokes
        -- are what makes the space interesting at 8-12 players, and the full
        -- footprint gives 3v3 a real site fight with two approaches per team.
        -- FFA is deliberately NARROWED to the one volume that has actually been
        -- surveyed. A zone is judged only when every volume it names exists, so
        -- listing six unsurveyed ids alongside the captured one suspends
        -- containment for the whole arena -- no wall, no rounds, no bots -- and
        -- the mode reads as broken rather than as unfinished.
        --
        -- Restore the full list when `lower`, `gallery` and the stairs are
        -- walked. The bounds test takes a list, so widening the arena is
        -- literally re-adding names here.
        -- RESTORED 2026-09-01: `lower` and `gallery` now have walked boxes, so
        -- the carved zones of section 3 are real again. The four stairs stay
        -- OUT deliberately -- they have no box, and a zone naming a boxless
        -- volume has its containment SUSPENDED, which would silently turn the
        -- wall off for that format. A stair also overlaps the decks at both
        -- ends, so "you are on the market floor" is the more useful answer.
        ffa = {
            label = "Kabuki Market",
            volumes = { "market", "lower", "gallery" },
        },
        -- Narrowed for the same reason as FFA above: a zone naming a nil volume
        -- is not judged at all, so the six uncaptured ids were suspending the
        -- wall rather than widening it. Re-add them when the boxes are walked.
        ["3v3"] = {
            label = "Kabuki Market",
            volumes = { "market", "lower", "gallery" },
        },
        -- 2v2: no gallery. Removes overwatch and shortens the fight.
        -- Both narrowed to the surveyed volume, same reason as FFA and 3v3
        -- above: a zone naming a nil volume is not judged at all, so `lower`
        -- was suspending the wall for these two formats entirely rather than
        -- shaping them. Restore when `/dm.survey box lower` is walked:
        --   ["2v2"] volumes = { "market", "lower" }
        --   ["1v1"] volumes = { "lower" }
        ["2v2"] = { label = "Market and lower", volumes = { "market", "lower" } },
        -- 1v1: one room, no third angle -- provisionally the whole market.
        ["1v1"] = { label = "Lower level", volumes = { "lower" } },
    },
    -- ======================================================================
    -- FORMATS
    -- ======================================================================
    --
    -- Two fundamentally different match lifecycles, and conflating them is what
    -- made the old mode feel like neither (plan section 2).
    --
    --   Free-for-all is a PLACE. Always running, instant entry, never queues.
    --   Arena is a MATCH. Balanced teams, symmetric rounds, so it genuinely
    --   queues -- the only place in the whole mode where a player waits.
    --
    -- A format carries no geometry at all. Its zone is `Config.zones[<key>]`,
    -- by name; its spawn marks are `DeathmatchKabuki.spawns.ffa` for the
    -- free-for-all and `DeathmatchKabuki.teams[<key>]` for the queued formats.
    --
    -- The team clusters are PER FORMAT, not one shared pair, and that is not
    -- redundancy: each format carves a different zone, so a 1v1 taking the 3v3
    -- alley cluster would spawn both duellists outside `lower`, and the bounds
    -- backstop would then "correct" that by killing them. Six extra marks buy a
    -- rule with no exceptions.
    formats = {
        ffa = {
            key = "ffa", order = 1,
            label = "Free-for-all",
            queued = false,          -- decision 2: FFA never queues
            teams = 0, teamSize = 0,
            elimination = false,     -- respawn, same round
            capacity = 12,           -- decision 13; the tunable overrides
            loadout = "equalizer",   -- decision 14
        },
        ["1v1"] = {
            key = "1v1", order = 2,
            label = "Duel",
            queued = true,
            teams = 2, teamSize = 1,
            elimination = true,      -- decision 4
            capacity = 2,
            loadout = "kit",
        },
        ["2v2"] = {
            key = "2v2", order = 3,
            label = "Doubles",
            queued = true,
            teams = 2, teamSize = 2,
            elimination = true,
            capacity = 4,
            loadout = "kit",
        },
        ["3v3"] = {
            key = "3v3", order = 4,
            label = "Squads",
            queued = true,
            teams = 2, teamSize = 3,
            elimination = true,
            capacity = 6,
            loadout = "kit",
        },
    },
    -- ======================================================================
    -- ROUND -- free-for-all timings
    -- ======================================================================
    --
    -- There is no `minimumPlayers` and no join countdown any more, and that is
    -- the point of decision 2: a round in progress is one you can join. A lone
    -- player in a fresh instance is playing, not waiting.
    round = {
        durationSeconds = 300,
        killLimit = 25,
        respawnDelayMs = 3000,
        -- 10 s of standings, then the next round with the same players and the
        -- next weapon in the rotation. The instance outlives every round.
        standingsSeconds = 10,
        -- Grace applied by each placement primitive.
        placementGraceMs = 5000,
        roundStartGraceMs = 1500,
        statePushMs = 500,
    },
    -- ======================================================================
    -- ARENA -- elimination timings and the queue
    -- ======================================================================
    arena = {
        -- Round wins needed to take the match. Odd, so there is no draw to
        -- explain.
        bestOf = 5,
        roundSeconds = 120,
        buySeconds = 20,             -- kit pick; both teams get the same list
        betweenRoundsSeconds = 8,
        resultSeconds = 12,
        -- Sides swap when either team reaches this many round wins; with
        -- bestOf 5 that is the halfway point.
        swapSidesAfterRounds = 3,
        placementGraceMs = 5000,
        roundStartGraceMs = 1500,
        -- ------------------------------------------------------------------
        -- BOTS FILLING A ROSTER
        -- ------------------------------------------------------------------
        --
        -- The difficulty profile arena bots are created on. Nil takes
        -- `bots.difficulty`, which is what a free-for-all backfill uses; naming
        -- it separately exists because an elimination duel and a
        -- twelve-player free-for-all do not want the same opponent.
        botProfile = nil,
        -- How long a round start will wait past the end of the buy window for a
        -- bot that has been asked for and has not arrived.
        --
        -- WHY IT IS NEEDED. bots.lua paces body creation across the whole
        -- resource (`bots.combat.respawn.spawnSpacingMs`, 400 ms) because
        -- issuing six spawns on one frame is the concurrency behind the
        -- puppet-install crash. A 3v3 filled entirely with bots therefore takes
        -- about two seconds to become six bodies, and after a resource reload
        -- the five-second settle gate is in front of that as well. Going live
        -- with a side that has nobody standing on it hands the other side the
        -- round on the timer, so the window is held -- but only this long,
        -- because a body that is never coming must not stall the match.
        botFillGraceMs = 15000,
        queue = {
            -- Honest matchmaking: first-come until there is a population to
            -- rate-match, and the panel says so rather than pretending to rate
            -- four people.
            rated = false,
            -- A queued player who stops answering is dropped rather than
            -- holding a slot five other people are waiting behind.
            staleAfterMs = 180000,
            updateMs = 2000,
            -- Q5, for the ARENA rather than for the free-for-all, and the same
            -- answer: OFF here, on by an operator's decision. A production
            -- server that silently completes a 3v3 with four bots is selling a
            -- match it did not have, and the arena is the mode where that
            -- matters most -- it is the one with a ladder attached.
            --
            -- An EXPLICIT request (`/dm.queue 3v3 bots`) is always honoured
            -- regardless, exactly as `/dm.bot fill` is: filling a roster by
            -- hand is how the mode is tested at sizes this workstation's VRAM
            -- cannot host with real clients. Four clients exhaust a 12 GiB
            -- card, so 3v3 can ONLY be validated with bots.
            fillWithBots = false,
            -- How long a queue must have waited before the AUTOMATIC fill
            -- above completes it. Long enough that two people arriving twenty
            -- seconds apart still play each other rather than each playing a
            -- roster of bots.
            botFillAfterMs = 30000,
        },
    },
    -- ======================================================================
    -- SPAWN PROTECTION
    -- ======================================================================
    --
    -- It already exists and nobody can see it: `graceMs` on respawn holds the
    -- player in `Recovering`, which retains temporary spawn protection until
    -- the client acknowledges the end of its grace period. Invulnerability the
    -- player cannot see is indistinguishable from a hit-registration bug, so it
    -- is pushed to the HUD -- and it breaks on aggression, because shooting
    -- from inside a shield is the classic abuse.
    spawnProtection = {
        joinMs = 5000,
        respawnMs = 5000,
        roundStartMs = 1500,
        breakOnAggression = true,    -- dropped the moment outgoing damage credits
        showOnHud = true,
    },
    -- ======================================================================
    -- EQUALIZER -- the FFA shared weapon (decision 14)
    -- ======================================================================
    --
    -- One rotating weapon for everyone is the mode's clearest idea and keeps
    -- fights readable. Round-robin rather than random: with two or more entries
    -- this guarantees that consecutive rounds never receive the same weapon.
    --
    -- `reserve` only, and that is load-bearing rather than incidental.
    -- `Open77.weapons.setAmmo` fails AS A WHOLE if `magazine` exceeds the
    -- weapon's capacity -- measured 2026-08-31: a Lexington given
    -- `{ reserve = 300, magazine = 60 }` ended on `000 0000`, while
    -- `{ reserve = 300 }` produced `000 0300` immediately.
    equalizer = {
        -- Slot 1 rotates. Slots 2 and 3 are fixed, so a player who runs the
        -- primary dry still has a fight left -- the old mode issued one weapon
        -- in one slot and left the other two empty.
        rotation = {
            { key = "lexington",  label = "M-10AF Lexington", category = "Pistol",        record = "Items.Preset_Lexington_Default",  reserve = 180 },
            { key = "saratoga",   label = "M221 Saratoga",    category = "SMG",           record = "Items.Preset_Saratoga_Default",   reserve = 240 },
            { key = "ajax",       label = "M251s Ajax",       category = "Assault rifle", record = "Items.Preset_Ajax_Default",       reserve = 240 },
            { key = "copperhead", label = "D5 Copperhead",    category = "Assault rifle", record = "Items.Preset_Copperhead_Default", reserve = 240 },
            { key = "masamune",   label = "HJSH-18 Masamune", category = "Assault rifle", record = "Items.Preset_Masamune_Default",   reserve = 240 },
            { key = "carnage",    label = "Carnage",          category = "Shotgun",       record = "Items.Preset_Carnage_Default",    reserve = 80 },
            { key = "satara",     label = "DB-2 Satara",      category = "Shotgun",       record = "Items.Preset_Satara_Default",     reserve = 80 },
            { key = "grad",       label = "SPT32 Grad",       category = "Sniper rifle",  record = "Items.Preset_Grad_Default",       reserve = 60 },
            { key = "nekomata",   label = "Nekomata",         category = "Sniper rifle",  record = "Items.Preset_Nekomata_Default",   reserve = 60 },
            { key = "defender",   label = "M2067 Defender",   category = "LMG",           record = "Items.Preset_Defender_Default",   reserve = 360 },
        },
        -- Both records below are `canonical = True` in
        -- docs/generated/weapons-2.31.csv, which is the provenance rule this
        -- repo works to: a record reaches Lua from the generated catalogue,
        -- never from memory. The arbiter still verifies the TweakDBID that
        -- comes back from the assign handshake -- a record being canonical is
        -- not a promise that it equipped.
        sidearm = { key = "unity", label = "Unity", category = "Pistol",
            record = "Items.Preset_Unity_Default", reserve = 120, slot = 2 },
        melee = { key = "katana", label = "Katana", category = "Melee",
            record = "Items.Preset_Katana_Default", slot = 3 },
        -- Resupplied at round rollover and on respawn. The old mode issued the
        -- reserve once, so a player who survived a long round simply ran dry.
        resupplyOnRespawn = true,
        resupplyOnRoundStart = true,
    },
    -- ======================================================================
    -- KITS -- the arena buy list (identical for both teams)
    -- ======================================================================
    kits = {
        default = "rifle",
        list = {
            { key = "rifle", label = "Rifle",
                slots = {
                    { slot = 1, record = "Items.Preset_Ajax_Default", reserve = 240 },
                    { slot = 2, record = "Items.Preset_Unity_Default", reserve = 90 },
                    { slot = 3, record = "Items.Preset_Katana_Default" },
                } },
            { key = "smg", label = "SMG",
                slots = {
                    { slot = 1, record = "Items.Preset_Saratoga_Default", reserve = 240 },
                    { slot = 2, record = "Items.Preset_Unity_Default", reserve = 90 },
                    { slot = 3, record = "Items.Preset_Katana_Default" },
                } },
            { key = "shotgun", label = "Shotgun",
                slots = {
                    { slot = 1, record = "Items.Preset_Carnage_Default", reserve = 80 },
                    { slot = 2, record = "Items.Preset_Unity_Default", reserve = 90 },
                    { slot = 3, record = "Items.Preset_Katana_Default" },
                } },
            { key = "sniper", label = "Sniper",
                slots = {
                    { slot = 1, record = "Items.Preset_Grad_Default", reserve = 60 },
                    { slot = 2, record = "Items.Preset_Unity_Default", reserve = 90 },
                    { slot = 3, record = "Items.Preset_Katana_Default" },
                } },
        },
    },
    -- ======================================================================
    -- LOADOUT MODE -- the equalizer, or the player's own pick
    -- ======================================================================
    --
    -- BOTH PATHS EXIST ON PURPOSE AND NEITHER IS DEAD CODE.
    --
    --   "equalizer"  Decision 14, unchanged: one rotating weapon in slot 1,
    --                the same for everybody in the instance, a new one every
    --                round. It is the mode's clearest idea -- fights stay
    --                readable, nobody loses to a loadout -- and it is the only
    --                reason the free-for-all needs no economy.
    --   "choice"     Each player picks a kit from `kits.list` and keeps it.
    --                What the owner asked for, and what a deathmatch player
    --                expects: the weapon you are good with.
    --
    -- They are in genuine tension, which is why this is a switch and not a
    -- merge. `choice` is the default so the owner can play it; flipping the
    -- `loadoutMode` tunable restores the equalizer live, on a running server,
    -- with no edit here. NOTHING ABOUT THE EQUALIZER PATH WAS REMOVED to make
    -- room for the picker: `Config.equalizer` is still the whole of the FFA
    -- plan under `mode = "equalizer"`, the rotation still advances once per
    -- round in round.lua, and the HUD still carries its banner.
    --
    -- Only the FREE-FOR-ALL reads this. The arena formats declare
    -- `loadout = "kit"` in `formats` and have their own buy window; a switch
    -- that silently rewrote them would be a second, invisible rule.
    loadout = {
        mode = "choice",             -- "equalizer" | "choice"
        -- Open the picker once, unprompted, on a player's first round of the
        -- session. Off means `/guns` is the only way in -- discoverable only to
        -- someone who has read the chat suggestions.
        promptOnFirstRound = true,
        -- --------------------------------------------------------------
        -- THE ARSENAL -- every weapon a player may pick in slot 1
        -- --------------------------------------------------------------
        --
        -- The picker used to offer four KITS (rifle / smg / shotgun / sniper)
        -- out of `Config.kits.list`. It offers this instead: every canonical
        -- primary firearm the 2.31 build ships, so "which gun do I get to play
        -- with" has the answer a deathmatch player expects.
        --
        -- PROVENANCE, which is the rule this repo works to -- a record reaches
        -- Lua from the generated catalogue, never from memory. Every line below
        -- is one row of `docs/generated/weapons-2.31.csv` selected by a filter
        -- anybody can re-run:
        --
        --     canonical == True
        --     category == "arme_a_feu"          (firearms; no melee, no
        --                                        grenades, no arm cyberware)
        --     record ends "_Default"            (the stock preset of each
        --                                        family -- the iconics and the
        --                                        vendor skins are variants of
        --                                        these and add no new gun)
        --     deprecated != True
        --     equip_area == "EquipmentArea.Weapon"
        --
        -- That filter yields exactly these 49 records, and every one of them is
        -- also in `open77_admin/shared/weapons.lua` -- the 189-record allowlist
        -- the admin panel already hands out through the same
        -- `Open77.weapons.assign` handshake. `label` is that catalogue's own
        -- display name, so a weapon is named identically in the picker, in the
        -- kill feed and in the admin panel.
        --
        -- WHY THIS IS NOT `equalizer.rotation`, and why the ten rows they share
        -- are written twice. The rotation is the equalizer's round-robin: a
        -- deliberately small, readable cycle where consecutive rounds never
        -- repeat. Growing it to 49 would silently turn a ten-round cycle into a
        -- forty-nine-round one and change a mode this edit must leave alone.
        -- The two lists answer different questions, so they are two lists; the
        -- ten rows in common carry byte-identical key, label, category, record
        -- and reserve.
        --
        -- `reserve` is per CATEGORY, extending the rotation's own numbers
        -- rather than the CSV's: Pistol 180, SMG 240, Assault rifle 240,
        -- Shotgun 80, Sniper rifle 60, LMG 360 are exactly what the rotation
        -- already issues. Revolver (120) and Precision rifle (120) are the two
        -- categories the rotation never had; both sit where their rate of fire
        -- and damage put them, between a pistol and a sniper. As everywhere
        -- else in this file it is `reserve` ONLY -- a `magazine` that exceeds
        -- the weapon's capacity makes `setAmmo` fail as a whole.
        --
        -- Slots 2 and 3 are NOT picked. The Unity sidearm and the katana stay
        -- fixed, for the reason stated at `equalizer` above: a player who runs
        -- the primary dry still has a fight left. The one exception is
        -- mechanical -- picking Unity itself as the primary drops the duplicate
        -- sidearm rather than issuing the same record twice.
        default = "ajax",
        -- Display order of the groups in the picker. A key not named here
        -- still renders; it lands after the ones that are.
        categories = {
            "Pistol", "Revolver", "SMG", "Assault rifle",
            "Precision rifle", "Sniper rifle", "Shotgun", "LMG",
        },
        primaries = {
            -- Pistol
            { key = "chao",       label = "A-22B Chao",       category = "Pistol",          record = "Items.Preset_Chao_Default",              reserve = 180 },
            { key = "grit",       label = "HA-4 Grit",        category = "Pistol",          record = "Items.Preset_Grit_Default",              reserve = 180 },
            { key = "yukimura",   label = "HJKE-11 Yukimura", category = "Pistol",          record = "Items.Preset_Yukimura_Default",          reserve = 180 },
            { key = "kenshin",    label = "JKE-X2 Kenshin",   category = "Pistol",          record = "Items.Preset_Kenshin_Default",           reserve = 180 },
            { key = "kappa",      label = "Kappa",            category = "Pistol",          record = "Items.Preset_Kappa_Default",             reserve = 180 },
            { key = "liberty",    label = "Liberty",          category = "Pistol",          record = "Items.Preset_Liberty_Default",           reserve = 180 },
            { key = "lexington",  label = "M-10AF Lexington", category = "Pistol",          record = "Items.Preset_Lexington_Default",         reserve = 180 },
            { key = "omaha",      label = "M-76e Omaha",      category = "Pistol",          record = "Items.Preset_Omaha_Default",             reserve = 180 },
            { key = "ticon",      label = "Militech Ticon",   category = "Pistol",          record = "Items.Preset_Ticon_Default",             reserve = 180 },
            { key = "nue",        label = "Nue",              category = "Pistol",          record = "Items.Preset_Nue_Default",               reserve = 180 },
            { key = "unity",      label = "Unity",            category = "Pistol",          record = "Items.Preset_Unity_Default",             reserve = 180 },
            -- Revolver
            { key = "quasar",     label = "DR-12 Quasar",     category = "Revolver",        record = "Items.Preset_Quasar_Default",            reserve = 120 },
            { key = "nova",       label = "DR5 Nova",         category = "Revolver",        record = "Items.Preset_Nova_Default",              reserve = 120 },
            { key = "metel",      label = "Metel",            category = "Revolver",        record = "Items.Preset_Metel_Default",             reserve = 120 },
            { key = "overture",   label = "Overture",         category = "Revolver",        record = "Items.Preset_Overture_Default",          reserve = 120 },
            { key = "burya",      label = "RT-46 Burya",      category = "Revolver",        record = "Items.Preset_Burya_Default",             reserve = 120 },
            -- SMG
            { key = "pulsar",     label = "DS1 Pulsar",       category = "SMG",             record = "Items.Preset_Pulsar_Default",            reserve = 240 },
            { key = "dian",       label = "G-58 Dian",        category = "SMG",             record = "Items.Preset_Dian_Default",              reserve = 240 },
            { key = "guillotine", label = "Guillotine",       category = "SMG",             record = "Items.Preset_Guillotine_Default",        reserve = 240 },
            { key = "saratoga",   label = "M221 Saratoga",    category = "SMG",             record = "Items.Preset_Saratoga_Default",          reserve = 240 },
            { key = "senkoh",     label = "Senkoh LX",        category = "SMG",             record = "Items.Preset_Senkoh_Default",            reserve = 240 },
            { key = "shingen",    label = "TKI-20 Shingen",   category = "SMG",             record = "Items.Preset_Shingen_Default",           reserve = 240 },
            { key = "warden",     label = "Warden",           category = "SMG",             record = "Items.Preset_Warden_Default",            reserve = 240 },
            -- Assault rifle
            { key = "copperhead", label = "D5 Copperhead",    category = "Assault rifle",   record = "Items.Preset_Copperhead_Default",        reserve = 240 },
            { key = "sidewinder", label = "D5 Sidewinder",    category = "Assault rifle",   record = "Items.Preset_Sidewinder_Default",        reserve = 240 },
            { key = "umbra",      label = "DA8 Umbra",        category = "Assault rifle",   record = "Items.Preset_Umbra_Default",             reserve = 240 },
            { key = "hercules",   label = "Hercules 3AX",     category = "Assault rifle",   record = "Items.Preset_Hercules_Default",          reserve = 240 },
            { key = "masamune",   label = "HJSH-18 Masamune", category = "Assault rifle",   record = "Items.Preset_Masamune_Default",          reserve = 240 },
            { key = "kyubi",      label = "Kyubi",            category = "Assault rifle",   record = "Items.Preset_Kyubi_Default",             reserve = 240 },
            { key = "ajax",       label = "M251s Ajax",       category = "Assault rifle",   record = "Items.Preset_Ajax_Default",              reserve = 240 },
            -- Precision rifle
            { key = "kolac",      label = "Kolac",            category = "Precision rifle", record = "Items.Preset_Kolac_Default",             reserve = 120 },
            { key = "achilles",   label = "M-179e Achilles",  category = "Precision rifle", record = "Items.Preset_Achilles_Default",          reserve = 120 },
            { key = "sor22",      label = "SOR-22",           category = "Precision rifle", record = "Items.Preset_Sor22_Default",             reserve = 120 },
            -- Sniper rifle
            { key = "ashura",     label = "Ashura",           category = "Sniper rifle",    record = "Items.Preset_Ashura_Default",            reserve = 60 },
            { key = "osprey",     label = "NDI Osprey",       category = "Sniper rifle",    record = "Items.Preset_Osprey_Default",            reserve = 60 },
            { key = "nekomata",   label = "Nekomata",         category = "Sniper rifle",    record = "Items.Preset_Nekomata_Default",          reserve = 60 },
            { key = "rasetsu",    label = "Rasetsu",          category = "Sniper rifle",    record = "Items.Preset_Tech_Sniper_Rifle_Default", reserve = 60 },
            { key = "grad",       label = "SPT32 Grad",       category = "Sniper rifle",    record = "Items.Preset_Grad_Default",              reserve = 60 },
            -- Shotgun
            { key = "carnage",    label = "Carnage",          category = "Shotgun",         record = "Items.Preset_Carnage_Default",           reserve = 80 },
            { key = "crusher",    label = "Crusher",          category = "Shotgun",         record = "Items.Preset_Crusher_Default",           reserve = 80 },
            { key = "satara",     label = "DB-2 Satara",      category = "Shotgun",         record = "Items.Preset_Satara_Default",            reserve = 80 },
            { key = "testera",    label = "DB-2 Testera",     category = "Shotgun",         record = "Items.Preset_Testera_Default",           reserve = 80 },
            { key = "igla",       label = "DB-4 Igla",        category = "Shotgun",         record = "Items.Preset_Igla_Default",              reserve = 80 },
            { key = "palica",     label = "DB-4 Palica",      category = "Shotgun",         record = "Items.Preset_Palica_Default",            reserve = 80 },
            { key = "zhuo",       label = "L-69 Zhuo",        category = "Shotgun",         record = "Items.Preset_Zhuo_Default",              reserve = 80 },
            { key = "tactician",  label = "M2038 Tactician",  category = "Shotgun",         record = "Items.Preset_Tactician_Default",         reserve = 80 },
            { key = "pozhar",     label = "VST-37 Pozhar",    category = "Shotgun",         record = "Items.Preset_Pozhar_Default",            reserve = 80 },
            -- LMG
            { key = "defender",   label = "M2067 Defender",   category = "LMG",             record = "Items.Preset_Defender_Default",          reserve = 360 },
            { key = "ma70",       label = "MA70 HB",          category = "LMG",             record = "Items.Preset_MA70_Default",              reserve = 360 },
        },
    },
    -- ======================================================================
    -- BOUNDS -- the leash backstop (server side of decision 15)
    -- ======================================================================
    --
    -- The WALL is the client-side clamp: the client projects itself back inside
    -- and writes a sub-metre transform. This block configures the SERVER
    -- BACKSTOP that catches a player held outside anyway, because a clamp that
    -- can be disabled is not authority.
    --
    -- The rule is "held continuously for N seconds", sampled at ~5 Hz, and BOTH
    -- an elapsed time and a consecutive-sample count must be satisfied. That
    -- pairing is what makes an unreadable position safe: an unreadable sample
    -- FREEZES both accumulators rather than resetting either, so a player can
    -- neither be judged by the wall clock across a replication gap, nor clear
    -- the accumulator by causing one.
    bounds = {
        sampleMs = 200,              -- ~5 Hz
        arena = {
            warnAfterMs = 1500,  warnAfterSamples = 7,
            backstopMs  = 5000,  backstopSamples  = 24,
            warnRepeatMs = 3000,
        },
        lobby = {
            warnAfterMs = 2500,  warnAfterSamples = 12,
            backstopMs  = 6500,  backstopSamples  = 31,
            warnRepeatMs = 4000,
        },
        -- How far inside the surface the clamp target sits. The client uses it
        -- for its own projection and the server uses the same number, so both
        -- sides agree where "inside" starts.
        insetMetres = 0.75,
        -- Draw the boundary. An unmarked wall reads as a bug. Props may DRAW it
        -- -- E4 proved they stay in their own bucket -- but they never enforce
        -- it, because E2 proved they cannot be invisible.
        draw = { enabled = true, style = "ground_band", color = "#FF3355" },
        -- A backstop placement costs score, so the wall is never a strategy.
        penaltyPoints = -100,
    },
    -- ======================================================================
    -- COMBAT -- host-global policy
    -- ======================================================================
    --
    -- Combat policy is HOST-GLOBAL. `setDamageMultiplier` and friends apply to
    -- every instance at once, so per-instance damage tuning is NOT available.
    -- Accept it; do not fake it in the arbiter without measuring.
    --
    -- Applied once on load and once on the first scheduler tick: during a hot
    -- reload the incoming VM is prepared before the outgoing VM receives
    -- onResourceStop, and the old cleanup used to disable friendly fire AFTER
    -- the new generation enabled it, silently cancelling every PvP report.
    combat = {
        friendlyFire = true,         -- teams are what cancel it, per side
        -- TIME TO KILL. At 1.0 the Lexington took a player from full to dead in
        -- THREE rounds, which is the single loudest balance complaint: a duel
        -- resolves before either player has reacted, so position and aim never
        -- get to matter and whoever fired first wins. 0.55 puts it at five or
        -- six body shots, or three with a headshot -- long enough to turn,
        -- break line of sight, or lose a fight you started badly.
        --
        -- This is the host-global multiplier (`Open77.combat.setDamageMultiplier`),
        -- so it governs player-versus-player only. Neither direction of bot
        -- damage passes through it: player -> bot is priced from
        -- `bots.damage.weaponDamage`, and bot -> player arrives as the engine's
        -- own number under `bots.combat.incoming`, which carries its own scale
        -- and clamp. If a time-to-kill change here should apply to bots too,
        -- both of those have to move with it.
        damageMultiplier = 0.55,
        headshotMultiplier = 2.0,
        rangedMultiplier = 1.0,
    },
    -- ======================================================================
    -- COMBAT MUSIC
    -- ======================================================================
    --
    -- Read `client/music.lua` first: it carries the evidence for WHY a PvP
    -- fight is silent and HOW the engine drives its own music. This block is
    -- only the four event names and the two windows.
    --
    -- THE FAMILY NAME IS THE ONE THING HERE THAT WAS NOT READ OUT OF THE BUILD,
    -- and it is a config value for exactly that reason. A Wwise event is
    -- addressed by a CName -- a hash -- so an unknown name is not an error
    -- anywhere: `sfx.play` succeeds, the engine posts the hash, and Wwise
    -- ignores it. A wrong name here is INDISTINGUISHABLE FROM SILENCE, and no
    -- log line will say so.
    --
    -- What is certain: `mus_ow_police_START_silent`, `mus_ow_police_calm`,
    -- `mus_ow_police_tense` and `mus_ow_police_STOP_silent` are string literals
    -- in the 2.31 executable, posted by the prevention-heat handler at RVA
    -- 0x1337CF0. That is the family whose existence is proven on this build.
    --
    -- What is inferred: the `ow_generic` family below follows the same naming
    -- and carries a `combat` state, which the police family does not -- it has
    -- `calm` and `tense` instead. It comes from
    -- `docs/generated/sfx-events-wolvenkit-seed.csv`, whose rows are tagged
    -- `music_quests_events|STS|ow_generic` and which declares itself
    -- `gameVersion 1.6`, so its 2.31 presence is a seed and not a measurement.
    -- The generic family is the default because it is the one the open world
    -- uses for an ordinary firefight, which is the sound the owner asked for.
    --
    -- IF NOTHING PLAYS, THIS IS THE FIRST SUSPECT. Swap the three names for the
    -- police family -- start `mus_ow_police_START_silent`, combat
    -- `mus_ow_police_tense`, stop `mus_ow_police_calm` -- and reload the
    -- resource. That family is proven present on this build, so if it plays and
    -- the generic one does not, the generic names are wrong; if neither plays,
    -- the mechanism is.
    music = {
        enabled = true,
        -- Opens the container. Posted once, first, every time -- a state event
        -- aimed at a container that is not playing is silence, not an error.
        start = "mus_ow_generic_START_silent",
        -- Switches the open container to its combat segment.
        combat = "mus_ow_generic_combat",
        -- The family's QUIET STATE, not its `_STOP_` event. The container may be
        -- one the engine opened for the district rather than one of ours, and
        -- closing somebody else's takes the open-world music away with it.
        -- client/music.lua opens a container; it never closes one.
        stop = "mus_ow_generic_silent",
        -- How long one PvP hit keeps the music going, and how long a bot
        -- contact keeps us out of the engine's way. The second is the longer of
        -- the two deliberately: engine combat outlives the last shot, and
        -- coming back in under it is exactly the double track this avoids.
        holdMs = 12000,
        botQuietMs = 15000,
    },
    -- ======================================================================
    -- BOTS
    -- ======================================================================
    --
    -- Measured 2026-08-31: bot -> player damage works and CARRIES ATTRIBUTION
    -- (the NPC id survives into `open77:playerDamaged`), but player -> bot
    -- damage does NOT happen by itself -- the gamemode must detect the hit on
    -- the attacker's client and call `Open77.npcs.applyDamage`. And `follow`
    -- reports `executing` while delivering commandTarget 0,0,0: movement is
    -- `moveTo`, re-issued on a tick.
    bots = {
        -- Q5, deferred to whoever runs the server: off in production, on in the
        -- dev config. An empty server feels alive with bots and a busy one
        -- feels fake.
        fillWithBots = true,
        fillTarget = 6,              -- bodies (players + bots) an instance aims for
        -- THREE MUTUALLY HOSTILE GANGS, and the rivalry is the feature.
        --
        -- One faction is one side, and one side does not fight. Under native
        -- combat "les bots doivent se tuer entre eux aussi" is not something
        -- this mode scripts -- it is a question about two records that the
        -- engine's own attitude matrix answers, and it can only answer "yes" if
        -- the two records belong to different gangs. Bots are round-robined
        -- across this list, so a roster of six is two Maelstrom, two Valentinos
        -- and two Tyger Claws, and the player is hostile to all three.
        --
        -- `civilian_female_relaxed_01` is NOT here and must never be. It
        -- resolves to `Character.Panam`, which carries the TweakDB tag
        -- `Invulnerable` -- vanilla quest protection that no attitude change,
        -- damage policy or Lua call can lift. This list used to name it
        -- alongside the Maelstrom, so `bots.lua` round-robined them and HALF
        -- EVERY ROSTER WAS UNSHOOTABLE. That was the whole of "I cannot fire on
        -- the bot", and it also invalidated the Phase 0 experiment that
        -- concluded players cannot damage NPCs at all: the decisive shots were
        -- fired at a protected story character. Panam is independently unsafe
        -- here too -- driving the weapon path against her native graph corrupts
        -- a component vtable (Cyberpunk2077.exe+0x336376).
        --
        -- The two gang aliases were promoted into the server-owned registry
        -- (`NpcAuthorityService.cs`) against an explicit criterion: no
        -- Invulnerable/Immortal tag, `category = gang`, `risk = candidate`, an
        -- aggressive reaction preset, real ranged equipment and no quest
        -- affiliation. 462 catalogued records satisfy it.
        templates = {
            "hostile_female_ranged_lab",   -- Maelstrom
            "gang_valentinos_ranged_01",   -- Valentinos
            "gang_tygerclaws_ranged_01",   -- Tyger Claws
        },
        -- Two rules that are not negotiable: bots are LABELLED on the
        -- scoreboard and in the kill feed, and a round containing a bot is
        -- never written to the ladder -- excluded at the write, not filtered at
        -- the read.
        labelled = true,
        excludeRoundsFromLadder = true,
        difficulty = "standard",
        -- ==================================================================
        -- WHICH COMBAT RUNS
        -- ==================================================================
        --
        -- `native` means the engine fights and this mode replicates. No
        -- scripted targeting, no `moveTo` stream, no damage on a timer. Damage
        -- in both directions is an observed `gameHitEvent` reported by the
        -- client that owns the body -- the shooter for player -> bot, the
        -- victim for bot -> player -- which is what keeps one burst from being
        -- credited once per spectator.
        --
        -- `scripted` is the pre-2026-09-01 behaviour and is kept only as a
        -- fallback in case the engine path cannot be made to report. It is not
        -- a supported gameplay mode: it fires through walls.
        --
        -- The mode is also the double-count interlock, and it is enforced at
        -- one door rather than by convention: every observation path goes
        -- through `admitReport`, whose first gate refuses the path the mode did
        -- not select. Flipping this cannot leave both live, and the flags below
        -- cannot override it.
        combat = {
            mode = "native",
            -- Force `weaponRecord` onto a native-combat bot, or let the gang
            -- record's own `primaryEquipment` arm it.
            --
            -- Leaving this true is today's behaviour and therefore the known
            -- quantity, but it is not obviously right: `setLoadout` drives the
            -- player-proxy equip path, whose comment in `NpcReplication.cpp`
            -- records a component-vtable corruption when it runs against a
            -- native graph. Against that, a bot observed closing to MELEE is a
            -- bot with nothing drawn. A/B it in game before changing it.
            forceWeapon = true,
            -- Bot -> player damage, and bot -> bot: the engine's own number,
            -- bounded.
            --
            -- MEASURED 2026-09-01, AND IT CHANGES HOW TO READ THIS BLOCK:
            -- `useEngineAmount` is TRUE and is currently doing NOTHING, because
            -- the engine reports zero on 100% of these hits. The funnel line
            -- read `zeroDamage=52` out of `hits=52` -- a clean sweep, both
            -- directions, not an edge case. So `fallbackDamage` below is
            -- pricing the ENTIRE fight: every bot bullet, on every weapon, from
            -- every gang record, is worth exactly the same flat number.
            --
            -- Nothing is broken by this and the mode is playable -- bots kill
            -- each other and the player with correct attribution -- but two
            -- consequences must not be discovered later by surprise:
            --   * a gang record's real per-weapon damage reaches nothing, so a
            --     sniper and an SMG hit identically;
            --   * `scale` and `maxPerHit` still apply (they multiply and clamp
            --     the fallback), but they can only scale one constant.
            -- `docs/research/pvp-arena-and-bots.md` F24 records what it would
            -- take to recover the real numbers.
            incoming = {
                -- Kept TRUE deliberately even though it currently selects
                -- nothing: the day the real values are recovered, this is the
                -- switch that starts using them, and flipping it to false now
                -- would hide that they had arrived.
                useEngineAmount = true,
                scale = 1.0,
                -- The clamp is not optional. A gang record's rifle is priced
                -- for a levelled solo player; this mode's health is a
                -- hundred-point scale. Unclamped, one burst is a kill.
                maxPerHit = 34.0,
                fallbackDamage = 18.0,
                -- Per victim, across ALL bots. The per-hit clamp bounds one
                -- bullet; nothing upstream bounds six bots converging.
                maxDamagePerSecond = 90.0,
                -- Per (victim, bot) pair.
                minIntervalMs = 90,
            },
            -- The leash. Native combat can walk a bot out of the arena chasing
            -- somebody, and no task stream is holding it any more. Players are
            -- already clamped client-side at 60 Hz with a server backstop; this
            -- is the equivalent for a body with no client of its own.
            leash = {
                enabled = true,
                intervalMs = 500,
                -- Soft: a `moveTo` back inside, which the behaviour tree may
                -- ignore in combat. Hard: a `setTransform`, which always works
                -- but revokes the simulation lease, so it is slow to arrive.
                softSamples = 4,
                hardSamples = 12,
                insetMetres = 1.5,
                -- Beyond this it is a placement, not a correction: the bot is
                -- respawned on a surveyed mark rather than dragged through
                -- whatever is in between.
                teleportLimitM = 60.0,
            },
            -- ==============================================================
            -- SEEK -- the answer to "the bots stay on spawn and we never see
            -- them" (owner, 2026-09-01).
            -- ==============================================================
            --
            -- Native combat issues no movement, by design, and `chooseSpawn`
            -- is a MAXIMIN rule: every bot is placed on the surveyed mark
            -- whose nearest opponent is farthest away. The two together are a
            -- lobby of statues -- the measured spread was 31.7 m for the
            -- closest pair and 132 m for the widest, which no vanilla
            -- perception radius crosses, so nothing ever introduced them
            -- except a player walking into a cone.
            --
            -- WHAT THIS IS NOT. It is not the scripted `moveTo` stream that
            -- native mode replaced (F13): that re-issued at 2 Hz, cleared the
            -- movement channel first, and cancelled whatever the behaviour
            -- tree had running, so a bot could not take cover or break
            -- contact. This issues ONE coarse `moveTo` every `intervalMs`,
            -- and only while the server has seen no combat on that body for
            -- `combatQuietMs`.
            --
            -- TWO INDEPENDENT GUARDS keep us out of a live fight, and the
            -- second one is the engine's rather than ours:
            --   1. the quiet window below -- every hit report involving this
            --      bot, in either direction, stamps `lastCombatAtMs`;
            --   2. `AIMoveToCommand.ignoreInCombat` is set TRUE where the
            --      client builds the command (`api/NpcTasks.cpp:425`), so the
            --      engine itself drops a `moveTo` on a body that is in
            --      combat. A task issued a moment before contact cannot steer
            --      a bot that has since engaged.
            -- ==============================================================
            -- RESPAWN PACING -- the 2026-09-01 crash fix.
            -- ==============================================================
            --
            -- A respawn replaces the engine body, because reviving one does not
            -- work (`bots.lua` `respawnBot` has the two client-side reasons).
            -- The first version did the destroy and the create in ONE tick, and
            -- that is a despawn racing a spawn -- the one concurrency the client
            -- cannot cancel, because `DynamicEntityService` can only destroy a
            -- body by its cyber id and a spawn in flight does not have one yet.
            -- `NpcReplication::Despawn` drops the request and the engine
            -- finishes the spawn anyway: an untracked body nobody will ever
            -- remove.
            --
            -- These three numbers keep a destroy and a create apart.
            respawn = {
                -- ========================================================
                -- "rebuild" -- AND "move" IS REFUSED, NOT MERELY UNSELECTED.
                -- ========================================================
                --
                -- "rebuild" is the kill -> respawn primitive: hand the corpse
                -- back, then create a fresh body on the mark. ONE placement,
                -- and that is the whole property that makes it correct.
                --
                -- "move" -- keep the body, `setTransform` it onto the mark and
                -- `revive` it -- was flipped on here 2026-09-01 and REVERTED
                -- 2026-09-01 after the owner reported bots lying dead on the
                -- pavement, re-killable, never coming back. It is not a tuning
                -- problem, it is a two-step placement racing a one-shot grant:
                --
                --   1. server `SetTransform(mark)` -- canonical becomes the
                --      mark and `ProjectionPending` is armed. ONE grant.
                --   2. client `DrivePlacement` teleports the body -- but an
                --      `AI::TeleportCommand` is asynchronous and RETRIED, so
                --      the body is still lying where it died for a while yet.
                --   3. meanwhile `NpcReplication` submits `NpcMotion` every
                --      100 ms from the body's LIVE position, unconditionally.
                --      That stale sample is 25-75 m from the mark, so it is
                --      out of budget, so it takes the grant -- and the server
                --      ADOPTS THE CORPSE as canonical.
                --   4. the teleport finally lands, the body reports the mark,
                --      the grant is spent: `motion_jump`, revoke, re-elect,
                --      reject, forever. Measured: 195 `motion_jump` in 30 min.
                --
                -- So the corpse never moves, the leash reads a canonical that
                -- IS the corpse, and the record says `alive` with a full health
                -- bar because `revive` succeeded server-side regardless. That
                -- is exactly the corpse-with-a-health-bar `bots.lua` documents
                -- above `releaseBody`, arrived at from the other direction.
                --
                -- "rebuild" cannot reach that state: `Create` arms the grant on
                -- a body that has no in-flight reports (npc ids carry a
                -- generation, so the corpse's id is never reissued), the first
                -- sample the client sends IS the engine's spawn projection, the
                -- grant adopts it, and there is no second placement to race.
                -- The 333/552 rejections this comment used to blame on rebuild
                -- were that unadopted spawn projection -- fixed at the root in
                -- `NpcAuthorityService.Adoptable`, so the churn argument for
                -- "move" no longer holds.
                --
                -- DO NOT FLIP THIS BACK until `NpcReplication` withholds
                -- `NpcMotion` for a replica whose `placementArmed` is still
                -- true. That is the missing half, it is client-side, and until
                -- it ships `respawnMode()` in `bots.lua` refuses "move" outright
                -- rather than letting a config edit re-arm the bug.
                mode = "rebuild",
                -- How long the corpse stays after death, before the body is
                -- handed back. Long enough for the death animation; the
                -- replacement is not created until this has happened, so it is
                -- also the guarantee that the two never share a frame. Clamped
                -- in code to `respawnDelayMs - 500`.
                corpseLingerMs = 1200,
                -- After THIS VM starts, wait this long before creating any
                -- body. A hot reload prepares the incoming VM before the
                -- outgoing one is told to stop, so without this the new
                -- generation fills its instance while the old generation's
                -- despawns are still in flight -- which is exactly what the
                -- crash log shows, 1.1 s apart, with a world transition
                -- underneath.
                spawnSettleMs = 5000,
                -- Minimum gap between any two body creations, across the whole
                -- resource. Eleven bots dying together become a paced stream
                -- rather than eleven concurrent spawn requests.
                spawnSpacingMs = 400,
            },
            seek = {
                enabled = true,
                -- How often one bot may be given a destination. Deliberately
                -- slow: this is "walk over there and find someone", not
                -- steering.
                intervalMs = 6000,
                -- No combat report naming this bot for this long before it is
                -- considered idle enough to be sent somewhere.
                combatQuietMs = 5000,
                -- Close enough. Below this the engine's own senses will do the
                -- introduction and a destination would only fight them.
                arriveM = 14.0,
                -- Do not walk a bot across the whole map to a body it will
                -- never reach before the round ends; beyond this, patrol.
                --
                -- RAISED FROM 90 TO 130 ON 2026-09-01, and the old value was a
                -- free-for-all number applied to an arena it does not fit.
                -- `shared/kabuki.lua` places the arena team clusters for maximum
                -- separation and records the distances: 3v3 at 115 m, 2v2 at
                -- 117 m, 1v1 at 98 m. Every one of those is BEYOND 90, so
                -- `seekDestination` refused its only candidate at every arena
                -- round start and fell through to patrolling the fourteen
                -- free-for-all marks instead -- a bot wandering the market at
                -- random rather than walking at its opponent.
                --
                -- Observed: a 1v1 ran the full 120 s at 0-0 with the bot never
                -- reaching the player. That is arithmetic, not an AI problem.
                -- 130 covers the widest cluster pair with margin and sits beside
                -- `damage.reportMaxRangeM` (120), which was chosen to span the
                -- whole surveyed arena for the same reason.
                maxSeekM = 130.0,
                -- Walk, run, sprint. `run` reads as a deathmatch and still
                -- lets the engine blend into combat locomotion on contact.
                speed = "run",
                -- Stop within this of the destination. Wide, because the point
                -- is proximity, not a position.
                acceptanceRadiusM = 4.0,
                -- The task's own ceiling. A destination the navmesh cannot
                -- reach expires instead of pinning the movement channel.
                timeoutMs = 20000,
                -- Below every leash priority, so a bot being pulled back
                -- inside the arena is never fighting a seek task.
                priority = 20,
                -- May a bot walk towards a PLAYER at all? Walking is not a
                -- threat seed -- `Hostility.cpp` still never seeds a player into
                -- a tracker -- so spawn protection is untouched either way.
                seekPlayers = true,
                -- AND THE PLAYER IS THE LAST RESORT, not the nearest answer.
                --
                -- Measured 2026-09-01, first session with seeking: *"the bots
                -- aren't fighting each other apparently but they are moving now
                -- -- but they go directly toward me."* Every bot ran the same
                -- nearest-opponent rule, the player was in the middle of the
                -- market, so eleven bots drew eleven straight lines to one
                -- person and never met each other. Bot-versus-bot was already
                -- proven working (`crossfire=39/39`, four bots killed by other
                -- bots); the seek was simply out-competing it.
                --
                -- With this on, a bot considers the player only when there is no
                -- living bot opponent in range at all. The player still gets
                -- attacked -- the engine's own senses and the hostility sweep
                -- do that, and always did -- but they are walked into a
                -- firefight rather than being the destination of one.
                preferBots = true,
                -- How many bots may be walking towards the same opponent before
                -- the next one picks somebody else. This is what turns one
                -- scrum into several fights spread over the map; nearest still
                -- wins when every candidate is already spoken for.
                maxSuitors = 2,
                -- With no opponent in range, wander the surveyed marks instead
                -- of standing still. This is what stops a lone bot from being
                -- a statue.
                patrol = true,
            },
        },
        damage = {
            -- The engine hit path is on; the client-inferred aim ray is off.
            -- Both are also gated on `combat.mode` in code, so these two flags
            -- can never open a second path by accident.
            acceptEngineHitReports = true,
            acceptAimRayReports = false,
            acceptTargetedReports = false,
            -- How far away a REPORT may claim a hit. Deliberately not the same
            -- as `maxRangeM`, which is how far a scripted bot is allowed to
            -- shoot: a player who lands a genuine engine hit across the whole
            -- arena has done nothing wrong. This is a sanity bound against a
            -- report naming a body in another district, not a balance lever.
            reportMaxRangeM = 120.0,
        },
        -- SCRIPTED BOT DAMAGE, and it only applies under `combat.mode =
        -- "scripted"`. Under `native` nothing reads it: the bot's gun is a real
        -- weapon fired by the engine.
        --
        -- NOTE, because this table used to declare `damagePerHit` TWICE -- once
        -- as 0.0 with a comment explaining that zero silenced the scripted gun,
        -- and again as 15.0 eight lines later. Lua keeps the LAST assignment in
        -- a table constructor, so the mute switch never took effect and the
        -- scripted gun kept firing at 15. A duplicate key in a table literal is
        -- silent in every Lua implementation; there is now exactly one.
        damagePerHit = 15.0,
        -- DECORATIVE UNDER `combat.mode = "native"`, which is the default.
        --
        -- Every field below -- reaction time, hit chance, burst length,
        -- aggression, fire interval -- describes the SCRIPTED gun, and
        -- `tickNativeBot` reads none of them: it runs the death backstop and
        -- the leash and nothing else. Under native combat a profile sets the
        -- label on the scoreboard row and changes no behaviour whatsoever.
        -- Difficulty is the engine's, and it comes from the record.
        --
        -- Left in place because `mode = "scripted"` still consumes them, and
        -- because deleting the vocabulary would make `/dm.bot add 3 veteran`
        -- an error rather than a no-op. But do not tune them expecting an
        -- effect: on the shipped default there is none.
        profiles = {
            relaxed  = { reactionMs = 900, hitChance = { close = 0.55, mid = 0.30, far = 0.10 }, burst = 3, reacquireMs = 1800, aggression = 0.4, fireIntervalMs = 900 },
            standard = { reactionMs = 550, hitChance = { close = 0.75, mid = 0.45, far = 0.18 }, burst = 4, reacquireMs = 1200, aggression = 0.7, fireIntervalMs = 700 },
            veteran  = { reactionMs = 300, hitChance = { close = 0.90, mid = 0.62, far = 0.30 }, burst = 5, reacquireMs = 800,  aggression = 0.9, fireIntervalMs = 500 },
        },
        rangeBands = { close = 12.0, mid = 30.0, far = 70.0 },
        moveRetickMs = 1000,         -- scripted mode only; `follow` does not steer
    },
    -- ======================================================================
    -- SCORING
    -- ======================================================================
    --
    -- `open77:playerDamaged` carries victim, attacker, amount, kind, weapon,
    -- bodyPart, remainingHealth, maxHealth and lethal for every hit, which is
    -- everything a per-victim damage ledger needs.
    --
    -- Standings still sort on KILLS first. Score is a richer number, not a
    -- replacement for the one players argue about.
    scoring = {
        kill = 100,
        assist = 50,
        assistThreshold = 0.30,      -- >= 30% of the victim's health, not the killer
        headshotBonus = 25,
        firstBlood = 50,
        revenge = 25,
        multiKill = 25,              -- each, for the 2nd and later kill in the window
        multiKillWindowMs = 4000,
        streakStep = 10,             -- +10 x n
        outOfBounds = -100,
        ledgerDecayOnRespawn = true,
    },
    -- ======================================================================
    -- CAREER -- what survives the round (plan section 10, Phase 8)
    -- ======================================================================
    --
    -- Read by `server/ranked.lua`. Career stats only: decision 8 says
    -- progression gates NOTHING, so there are no unlocks here and no power
    -- curve, and there is nothing for another system to have to read.
    --
    -- WHERE: MySQL, through `Open77.database`, keyed by the master-backed
    -- identifier. It is the only durable store server Lua has -- the sandbox
    -- nils `io` and `os`, and `server/.open77/` is host-owned and holds
    -- registration secrets rather than resource state. The bridge is per
    -- SERVER, not per resource: enabling it here wakes every other resource
    -- that holds `database.access` at the same moment, which is what took the
    -- live Pursuit server down on 2026-08-27. `server.deathmatch-local.jsonc`
    -- therefore ships with it OFF and this degrades to a volatile table that
    -- says so in every readout.
    --
    -- NO NAME IS EVER STORED. The identifier is opaque and already
    -- master-backed; the display name is resolved live when somebody reads a
    -- card. A durable table of chosen handles buys nothing.
    career = {
        enabled = true,
        -- The per-round audit table. Aggregates alone cannot answer "did that
        -- bot round leave a row behind" -- the answer would be a number that
        -- did not move, which is what a ladder that is not writing at all also
        -- looks like. One row per player per persisted round makes it a query.
        recordRounds = true,
        -- Table names are `<prefix>career` and `<prefix>rounds`. A prefix reaches
        -- SQL as an identifier and cannot be bound as a parameter, so anything
        -- outside [A-Za-z0-9_] is refused and the default is used instead.
        tablePrefix = "open77_dm_",
        -- One career line per session when a player drops into their first
        -- round. Never re-shown after a Lua hot reload -- see `Ranked.greet`.
        announceOnJoin = true,
        -- Tell the players when a round will not count. bots.lua has carried
        -- the sentence since Phase 3 and nothing spoke it; a silent exclusion
        -- is indistinguishable from a broken ladder to somebody who just went
        -- 20-3.
        announceExclusion = true,
        -- The hot-reload bridge is `Open77.state`, which is 64 KiB and shared
        -- with nothing else in this resource. These are what gets trimmed
        -- first if a payload will not fit.
        maxCarriedIdentities = 48,
        maxCarriedRounds = 32,
        -- A write that keeps failing must not grow without bound.
        maxPendingRounds = 128,
        -- Statements per transaction. The bridge refuses more than 64.
        statementChunk = 48,
    },
    -- ======================================================================
    -- RATING -- the per-format ELO (plan section 10, Phase 8)
    -- ======================================================================
    --
    -- Read by `server/rating.lua`, which is pure arithmetic, and persisted by
    -- `server/ranked.lua` beside the career it rides with -- same table prefix,
    -- same identity key, same serialised worker, and above all the SAME
    -- decision-12 gate. A round containing a bot moves no rating because it
    -- never reaches the write at all.
    --
    -- The four numbers an operator is most likely to reach for are ALSO live
    -- tunables (`ratingEnabled`, `ratingStart`, `ratingArenaK`, `ratingFfaK`)
    -- and the tunable wins when it is set. The rest are here only: changing a
    -- spread or a floor under a live ladder is a between-seasons decision, not
    -- a between-rounds one.
    --
    -- WHY TWO K VALUES. The arena writes once per ROUND, because
    -- `Scoring.beginRound` clears the board at the start of each one and a
    -- match-level write would record a fifth of a best-of-five -- so a
    -- best-of-five arena match can exchange five times while a 300 s
    -- free-for-all round exchanges once. Equal K values would make an evening
    -- of arena worth five times an evening of free-for-all.
    rating = {
        enabled = true,
        -- THE BASELINE. Every unrated player is exactly here, so this decides
        -- whether the ladder reads as "1000 and climbing" or "1500 and
        -- drifting". Matches `pursuit/server/ranked.lua` so a player who plays
        -- both modes sees one scale.
        start = 1000,
        -- The gap at which the favourite is expected to score 10/11. The Elo
        -- convention, and there is no measurement on this ladder that would
        -- justify moving it yet.
        spread = 400.0,
        -- Nobody goes below this. A rating that can be driven arbitrarily low
        -- stops being a measurement and becomes a punishment.
        floor = 100,
        -- A decisive result that rounds to zero reads as a broken ladder, and
        -- at a large enough gap it is a real loophole: the favourite would win
        -- for free. Applied only where "decisive" is unambiguous -- an arena
        -- win or loss, and a free-for-all finish that beat everybody or lost to
        -- everybody.
        minDelta = 1,
        -- PER ARENA ROUND.
        arenaK = 16.0,
        -- PER FREE-FOR-ALL ROUND, after the model divides by N-1.
        ffaK = 32.0,
        -- A new player's rating is a guess and should move a long way; a
        -- settled player's is evidence and should not. Both K values are
        -- multiplied by `provisionalScale` for a player's first
        -- `provisionalRounds` rated rounds IN THAT FORMAT.
        provisionalRounds = 10,
        provisionalScale = 2.0,
    },
    -- ======================================================================
    -- STATIONS -- the way in (plan section 5)
    -- ======================================================================
    --
    -- Entry is a station in the world, not a command (decision 10). `/dm`
    -- survives as an admin and power-user fallback, never as the way in.
    --
    -- Five things pursuit already learned the hard way, all encoded here:
    --   * On 2.31 the native 3D ring does not draw at all. `open77_groundcircle`
    --     is what the player actually sees, following real ground per vertex;
    --     markers sit ~0.55 m below the ground sample.
    --   * `open77_worldui` gives radius + 0.5 m of activation. Two stations
    --     closer than the sum of their activations leave a DEAD BAND where
    --     neither prompt is live -- worse than an overlap, because an overlap is
    --     arbitrated and a dead band just looks broken.
    --   * The prompt colour defaults to #00E5FF regardless of style. Pass
    --     `color` explicitly or a green ring gets a cyan card.
    --   * Tear the station down when the player leaves the bucket. Ownership is
    --     the lever, not `maxDistance`.
    --   * The arbiter renders one card at a time, so both stations may share E.
    --     Separate them with the marker glyph and the card badge, not the key.
    stations = {
        maxDistance = 25.0,
        -- Minimum separation between the two station centres: the sum of their
        -- activations (radius + 0.5 each) plus a margin. Checked at startup.
        minSeparationMetres = 6.0,
        enter = {
            id = "dm_enter",
            radius = 2.0,
            style = "objective",
            color = "#00E5FF",
            marker = "chevron",
            icon = "DIALOG",
            key = "E",
            hold = true,             -- entering is a commitment
            holdSeconds = 0.9,       -- long enough that a stray tap cannot join
            event = "deathmatch:stationEnter",
            -- No position here. The mark is geometry and lives in
            -- `DeathmatchKabuki.stations`, captured in the same survey pass --
            -- the surveyor is already standing in the lobby when the session
            -- opens.
            --
            -- UNTIL IT IS CAPTURED THE STATION IS NOT DRAWN, and that is a
            -- correction of what this comment used to promise. Falling back to
            -- `Config.lobby.center` would put BOTH stations on one point, which
            -- is precisely the dead band `minSeparationMetres` above exists to
            -- forbid -- and it would put a ring on ground nobody chose while
            -- reading, to a player, exactly like a surveyed one. client/station.lua
            -- draws nothing and logs one line naming the survey command instead.
            -- `/dm` remains the way in until then.
        },
        queue = {
            id = "dm_queue",
            radius = 1.6,
            style = "spawn",
            color = "#3DDC84",
            marker = "chevron",
            icon = "DIALOG",
            key = "E",
            hold = false,            -- opening a panel is reversible
            event = "deathmatch:stationQueue",
            -- See above: the mark is `DeathmatchKabuki.stations`.
        },
    },
    -- ======================================================================
    -- DEBUG
    -- ======================================================================
    debug = {
        verboseInstances = false,
        verboseBounds = false,
        verboseDamage = false,
        -- Diagnostics are buffered and logged once. An unbuffered probe once
        -- reported 291 ms where the truth was 14 ms.
        logEveryMs = 5000,
    },
    -- ======================================================================
    -- STRINGS -- every player-facing string, English (decision 16)
    -- ======================================================================
    --
    -- Server notices and HUD copy both read from here. Nothing player-facing is
    -- written inline anywhere else in the resource.
    strings = {
        title = "KABUKI ARENA",
        notice = {
            -- Entry
            joined            = { title = "IN THE FIGHT",     body = "You are in instance %s. Good hunting." },
            notReady          = { title = "HOLD ON",          body = "Your character is not ready yet." },
            instancesFull     = { title = "SERVER FULL",      body = "Every arena instance is full. That is a server capacity limit, not a queue -- try again shortly." },
            leftMatch         = { title = "LEFT THE ARENA",   body = "You are back in the lobby." },
            placementFailed   = { title = "PLACEMENT FAILED", body = "The arena could not place you. Try again." },
            -- Free-for-all round
            roundStart        = { title = "FIGHT",            body = "GO!" },
            roundWeapon       = { title = "THIS ROUND",       body = "%s -- same weapon for everyone." },
            roundOver         = { title = "ROUND OVER",       body = "%s takes the round." },
            roundDraw         = { title = "DRAW",             body = "The round ends with no clear winner." },
            roundWon          = { title = "VICTORY",          body = "You finish top of the standings." },
            nextRound         = { title = "NEXT ROUND",       body = "Starting in %d s." },
            -- Arena
            queued            = { title = "QUEUED",           body = "Position %d in the %s queue." },
            queueLeft         = { title = "QUEUE",            body = "You left the queue." },
            queueMatched      = { title = "MATCH FOUND",      body = "%s -- placing you now." },
            buyWindow         = { title = "PICK YOUR KIT",    body = "%d s. Both teams get the same list." },
            eliminated        = { title = "ELIMINATED",       body = "Spectating your team until the round ends." },
            teamWon           = { title = "ROUND WON",        body = "%d - %d." },
            teamLost          = { title = "ROUND LOST",       body = "%d - %d." },
            sidesSwapped      = { title = "SIDES SWAPPED",    body = "You are now on the other side." },
            matchWon          = { title = "MATCH WON",        body = "Returning to the lobby." },
            matchLost         = { title = "MATCH LOST",       body = "Returning to the lobby." },
            -- Bounds
            boundsWarn        = { title = "OUT OF BOUNDS",    body = "Return to %s -- %d s." },
            boundsReturned    = { title = "OUT OF BOUNDS",    body = "You were held outside the arena and have been placed back inside." },
            lobbyReturned     = { title = "RESTRICTED AREA",  body = "You were returned to the lobby." },
            -- Loadout
            loadoutFailed     = { title = "LOADOUT",          body = "The round weapon could not be equipped." },
            loadoutUnverified = { title = "LOADOUT",          body = "Your weapon is equipped but could not be verified; your shots stay blocked." },
            resupplied        = { title = "RESUPPLIED",       body = "Ammunition restored." },
            -- Weapon choice (`/guns`). Three outcomes, because WHEN a pick
            -- lands is the only thing a player can get wrong about it: a
            -- weapon must never change in someone's hands mid-firefight, so a
            -- pick made while alive and unprotected waits for the respawn --
            -- and saying so is the difference between a rule and a bug.
            gunsApplied       = { title = "LOADOUT",          body = "%s. It is in your hands now." },
            gunsNextSpawn     = { title = "LOADOUT",          body = "%s. You pick it up on your next respawn -- weapons never change mid-fight." },
            gunsReady         = { title = "LOADOUT",          body = "%s. You will carry it when you drop into a round." },
            -- The arsenal is 49 weapons and the arena's buy list is 4, so a
            -- pick can be one the arena does not sell. Saying "you will carry
            -- it" there would be a lie: the arena arms from its own list.
            gunsArenaOnly     = { title = "LOADOUT",          body = "%s is your free-for-all weapon. This arena arms from its own buy list, so the round will not hand it to you." },
            -- The catalogue is 49 weapons now, so this no longer recites it:
            -- a notification toast is not a list, and `/guns list` is.
            gunsUnknown       = { title = "LOADOUT",          body = "No weapon called \"%s\". Type /guns list to see every one." },
            gunsEqualizer     = { title = "LOADOUT",          body = "This server plays the equalizer -- one weapon for everyone, rotating every round. There is nothing to choose." },
            -- Career (Phase 8). One line, once per session, when a returning
            -- player drops into their first round -- never after a Lua reload.
            careerWelcome     = { title = "CAREER",           body = "%d kills / %d deaths (%.2f K/D) over %d rounds. Type /dm.stats for the full card." },
            -- Spawn protection
            protectionOn      = { title = "SPAWN PROTECTION", body = "%d s of protection." },
            protectionBroken  = { title = "PROTECTION LOST",  body = "You fired -- protection dropped." },
        },
        station = {
            enterLabel   = "ENTER THE ARENA",
            enterIdle    = "No fight running. You will open a fresh instance.",
            enterSummary = "%d playing across %d instance(s). You land in a %d/%d fight.",
            queueLabel   = "ARENA QUEUE",
            queueSummary = "1v1 %d queued  -  2v2 %d queued  -  3v3 %d queued",
            -- Shown INSTEAD of the depth line once this player is in a queue.
            -- The depth is what you read while deciding; your own position is
            -- what you read once you have decided, and a card showing both is a
            -- card the player has to parse rather than glance at.
            queueQueued  = "You are %d in the %s queue. Open the panel to change or cancel.",
        },
        hud = {
            equalizerBanner = "SAME WEAPON FOR EVERYONE",
            spectating      = "SPECTATING",
            botTag          = "BOT",
            instanceTag     = "INSTANCE %s",
            firstBlood      = "FIRST BLOOD",
            revenge         = "REVENGE",
            headshot        = "HEADSHOT",
            multiKill       = "MULTI-KILL x%d",
            streak          = "%d KILL STREAK",
            killLimit       = "FIRST TO %d",
        },
        error = {
            playerOnly    = "player only",
            unknownFormat = "unknown format -- try ffa, 1v1, 2v2 or 3v3",
            notInInstance = "you are not in an arena instance",
        },
        -- ------------------------------------------------------------------
        -- THE LIVE MAP EDITOR (`/dm.map`, server/mapstore.lua)
        -- ------------------------------------------------------------------
        --
        -- Decision 16 covers operator-facing copy too: `server/mapstore.lua`
        -- holds no string of its own and reads every line from here, format
        -- specifiers included -- a translated line and a translated format
        -- string are the same problem, and splitting them is how half a tool
        -- ends up untranslated.
        --
        -- These are read back by `T()` in that file, which reports a MISSING
        -- key as a missing key rather than falling back to a local copy. A
        -- fallback table would be the duplication this decision forbids and it
        -- would go stale the first time a line was reworded here.
        mapedit = {
            -- Shared words, so a readout never assembles English from
            -- fragments the way a `tostring(bool)` would.
            yes                 = "yes",
            no                  = "no",
            none                = "none",
            tagBuiltin          = "[built-in]",
            stationsBoth        = "both stations are",
            playerOnly          = "This verb captures where you are standing, so it must be used in-game.",
            noActiveMap         = "There is no active map. Run: dm.map select kabuki",
            builtinReadOnly     = "'%s' is the BUILT-IN map and is never edited -- it is the shipped geometry and the floor everything else stands on. Copy it first: dm.map copy %s myarena",

            -- Where the data lives. Printed constantly and on purpose: a
            -- volatile store that looked durable would be worse than none.
            storeDatabase       = "database (%s)",
            storeVolatile       = "MEMORY ONLY -- NOT durable across a server restart (%s)",
            storeUnprobed       = "not probed yet",
            storeLine           = "map store -- %s | %d map(s) | active '%s' | tunables.activeMap='%s'",
            storeReload         = "survives a Lua hot reload: %s (carried in the host's state bag, shared with the career ledger)",
            storeAdvice         = "No database bridge, so these maps DIE on a server restart. Run 'dm.map export' and paste the block into resources/gamemodes/open77_deathmatch/shared/kabuki.lua to make the map a built-in.",
            saveQueued          = "Save of '%s' queued -- %s",
            reloadQueued        = "Re-reading the map store from %s. The active map is re-selected if only the store had it.",

            -- Map-level verbs.
            listHeader          = "maps: %d -- store: %s",
            listRow             = "%s %-14s %-11s %-24s volumes %d/%d  marks %d",
            showHeader          = "map '%s' label='%s' active=%s builtin=%s",
            showVolumes         = "  volumes %d/%d with a box: %s",
            showZone            = "  zone %-4s = %s",
            showSet             = "  set %-8s %-18s %d captured (wanted %s)",
            showReadiness       = "  zone volumes boxed %d/%d, missing: %s",
            unknownMap          = "No map called '%s'. Known maps: %s",
            usageNew            = "usage: dm.map new <name> [label...] -- name is lowercase letters, digits, '_' and '-'",
            mapExists           = "A map called '%s' already exists. Pick another name, or edit that one with: dm.map select %s",
            tooManyMaps         = "The store already holds its %d maps. Delete one first.",
            created             = "Created map '%s' (%s). It is EMPTY -- no volumes, no marks.",
            createdNext         = "Next: dm.map edit on -> walk two opposite corners with 'dm.map box arena' -> 'dm.map mark ffa' on every spawn you want.",
            usageCopy           = "usage: dm.map copy <source> <name> [label...] -- known maps: %s",
            copied              = "Copied '%s' to '%s': %d mark(s) and %d box(es) came with it.",
            usageRename         = "usage: dm.map rename <old> <new>",
            renamed             = "Renamed '%s' to '%s'.",
            usageLabel          = "usage: dm.map label <text...> -- the human-readable name shown on the boundary readouts",
            labelled            = "Map '%s' is now labelled '%s'.",
            deleteActive        = "'%s' is the ACTIVE map. Select another one first: dm.map select kabuki",
            deleted             = "Deleted map '%s'.",
            selected            = "Now playing '%s' (%s): %d mark(s), %d/%d volume(s) with a box. It is live -- the next spawn uses it.",
            selectNotPersisted  = "WARNING: the selection could not be persisted (%s), so a server restart will come back on the previous map. The geometry itself is unaffected.",
            selectedNoZones     = "This map names NO volumes for any format, so containment is SUSPENDED everywhere: there is no wall, no format can start, and with no spawn mark captured NO PLACEMENT CAN SUCCEED -- a round running right now will fail to respawn anybody. Author on a quiet server, or run 'dm.map select kabuki' to put the shipped map back. Start with: dm.map box arena (once at each opposite corner).",
            selectedSuspended   = "Containment is SUSPENDED for every zone naming %s -- those volumes have no box yet. An unsurveyed zone is never treated as an empty one, so the wall is off rather than inverted.",

            -- Editing session.
            usageEdit           = "usage: dm.map edit <on|off>",
            editOn              = "Map editing ON for %d minutes: your client now reports which way you are facing (so a captured mark keeps your heading), and the boundary leash no longer applies to you. Run 'dm.map edit off' when you are done.",
            editOff             = "Map editing OFF: heading reporting stopped and the boundary rules apply to you again.",

            -- Marks.
            unknownSet          = "Unknown capture set '%s'. Sets: %s -- '3v3.a' and '3v3_a' both work.",
            useStationVerb      = "The lobby stations are named, not numbered. Use: dm.map station <enter|queue> [heading]",
            setFull             = "Set '%s' already holds its %d mark(s). Move one with 'dm.map move %s <index>' or delete one first.",
            noPosition          = "The server cannot read your position right now (%s). Never capture through a transition -- stand still, alive, and try again.",
            tooClose            = "Refused: %.2f m from mark %d of '%s', and the minimum separation is %.2f m. Two marks that close are a spawn blender, not two spawns.",
            markCaptured        = "Mark %d (of %s) captured for '%s' at %.3f %.3f %.3f, heading %.1f. It is LIVE -- the next spawn can use it.",
            headingMissing      = "No heading was recorded (0.0). Run 'dm.map edit on' so your client reports its facing, or pass the yaw yourself.",
            setComplete         = "Set '%s' is now complete.",
            marksHeader         = "set %-8s %-18s %d captured (wanted %s)",
            markRow             = "  %2d %-8s %.3f %.3f %.3f heading %.1f",
            markRowEmpty        = "  %2d %-8s NOT CAPTURED",
            badIndex            = "No mark '%s' in set '%s' -- it holds %d.",
            markMoved           = "Mark %s[%d] moved to %.3f %.3f %.3f, heading %.1f. Live immediately.",
            markRemoved         = "Removed %s[%d]; %d mark(s) left in that set.",

            -- Stations.
            usageStation        = "usage: dm.map station <enter|queue> [heading] -- captured where you stand",
            stationCaptured     = "Station '%s' captured at %.3f %.3f %.3f, heading %.1f. Every client's ring has been redrawn.",
            stationsSeparation  = "The two stations are %.2f m apart (minimum %.2f m) -- clear of the dead band.",
            stationsTooClose    = "WARNING: the two stations are %.2f m apart and the enforced minimum is %.2f m. Closer than that leaves a band where NEITHER prompt is live, which looks like a broken station rather than a missing one. Walk further and capture again.",

            -- Volumes and zones.
            usageVolume         = "usage: dm.map volume <add|delete> <id> -- this map declares: %s",
            volumeExists        = "This map already declares a volume called '%s'.",
            volumeAdded         = "Volume '%s' declared. It has NO BOX yet, so every zone naming it has containment SUSPENDED until you walk it: dm.map box %s",
            volumeDeleted       = "Volume '%s' deleted, and removed from every zone that named it.",
            unknownVolume       = "No volume '%s' on this map. It declares: %s",
            tooManyVolumes      = "A map may declare at most 32 volumes.",
            usageBox            = "usage: dm.map box <id> [height] -- run it at one corner, then again at the OPPOSITE corner. This map declares: %s",
            badHeight           = "Ignoring the height '%s'; it must be a positive number of metres.",
            boxFirst            = "Corner 1 of '%s' captured at %.3f %.3f %.3f. Walk to the OPPOSITE corner and run the same command again.",
            boxReopened         = "Volume '%s' already had a box; this corner starts it over.",
            boxTooSmall         = "Refused: the two corners of '%s' are only %.2f x %.2f m apart, under the %.2f m minimum. Did you capture twice in the same place?",
            boxInvalid          = "Could not close '%s': %s",
            boxClosed           = "Volume '%s' closed: %.1f x %.1f m footprint, z %.2f to %.2f (%.1f m of headroom). %d of %d volume(s) on this map now have a box. The wall is live.",
            boxZoned            = "'%s' is this map's first box, so every format now plays it. Carve them apart when you have an opinion: dm.map zone 1v1 <ids>",
            boxCleared          = "The box of '%s' was cleared. Every zone naming it has containment SUSPENDED until it is walked again.",
            usageZone           = "usage: dm.map zone <format> <id[,id...]|none> -- formats: %s -- this map declares: %s",
            zoneSet             = "Format '%s' now plays: %s",
            zoneEmptyWarning    = "'%s' now names no volume at all, so its containment is SUSPENDED: the wall does not exist for it and the format will not judge anybody. That is the honest state, not an empty arena.",

            -- Validation.
            usageCheck          = "usage: dm.map check [format] -- formats: %s",
            checkHeader         = "check map '%s' (%s) -- store: %s",
            checkVolumes        = "  volumes: %d of %d have a box; without one: %s",
            checkFormatOk       = "  %-4s READY   zone [%s]",
            checkFormatBlocked  = "  %-4s BLOCKED %s",
            -- A NOTE never blocks. Kept apart from a problem on purpose: a
            -- validator that reports a playable map as broken gets ignored on
            -- the day it is right.
            checkFormatNote     = "  %-4s note    %s",
            problemNoZone       = "names no volume, so containment is suspended and it cannot start",
            problemNoBox        = "its zone names %s, which have no box -- containment is SUSPENDED",
            problemNoMarks      = "no FFA spawn mark has been captured",
            problemThinMarks    = "only %d FFA mark(s) for a capacity of %d -- playable, but the maximin spawn choice has little to choose from",
            problemTeam         = "side %s has %d of %d mark(s)",
            checkStationsMissing = "  stations: NOT CAPTURED (%s missing) -- the ground rings are the way IN to the mode, so nobody can enter without using /dm",
            checkStationsOk     = "  stations: %.2f m apart, minimum %.2f m -- OK",
            checkStationsClose  = "  stations: %.2f m apart and the enforced minimum is %.2f m -- expect a DEAD BAND where neither prompt is live",
            checkMarkOutside    = "  WARNING %s[%d] at %.1f %.1f %.1f is OUTSIDE the '%s' zone by %.1f m -- a fight started there warns the player at two seconds and places them at five",
            checkSweep          = "  spawn sweep: %d captured mark(s), %d outside their own zone",
            checkVerdict        = "  verdict -- playable: %s | blocked: %s",

            -- Export.
            exported            = "Printed %d line(s) to the server console for map '%s' (%d/%d volume(s) with a box, %d mark(s)). Paste it over the matching blocks in resources/gamemodes/open77_deathmatch/shared/kabuki.lua to promote this map to a BUILT-IN.",

            -- Help.
            unknownVerb         = "Unknown verb '%s'. Run 'dm.map help' for the list.",
            helpHeader          = "dm.map -- the live map editor. Everything below takes effect IMMEDIATELY; nothing writes a file under resources/, so nothing reloads.",
            helpList            = "  list                          every map in the store, with the active one marked",
            helpShow            = "  show [name]                   volumes, zones and mark counts of one map",
            helpNew             = "  new <name> [label...]         create an empty map and select it",
            helpCopy            = "  copy <source> <name> [label]  duplicate a map -- the usual way to start one",
            helpSelect          = "  select <name>                 play this map on this server, from the next spawn",
            helpRename          = "  rename <old> <new>            rename a map",
            helpLabel           = "  label <text...>               set the active map's human-readable name",
            helpDelete          = "  delete <name>                 delete a map (never the built-in, never the active one)",
            helpEdit            = "  edit <on|off>                 heading reporting + boundary exemption while you author",
            helpMark            = "  mark <set> [heading]          capture a spawn mark where you stand (ffa, 3v3.a, 1v1.b, ...)",
            helpMarks           = "  marks [set]                   list captured marks",
            helpMove            = "  move <set> <index> [heading]  re-capture that mark where you stand",
            helpRemove          = "  remove <set> <index>          delete that mark",
            helpStation         = "  station <enter|queue>         capture a lobby station where you stand",
            helpBox             = "  box <id> [height]             walk two opposite corners to capture a volume",
            helpUnbox           = "  unbox <id>                    clear a volume's box, keeping the id",
            helpVolume          = "  volume <add|delete> <id>      declare or drop a volume id",
            helpZone            = "  zone <format> <ids|none>      which volumes a format plays in",
            helpCheck           = "  check [format]                what this map still needs, and why a format cannot start",
            helpExport          = "  export [name]                 print the map as pasteable Lua for shared/kabuki.lua",
            helpStore           = "  store                         where the store lives and whether it is durable",
            helpSave            = "  save                          force a durable write now",
            helpReload          = "  reload                        re-read the store from the database",
            helpFooter          = "Travel with /dm.goto <x> <y> <z> [heading]. A map is only as honest as its boxes: a zone naming a volume with no box has containment SUSPENDED, and 'dm.map check' says which.",
        },
    },
    -- ======================================================================
    -- TUNABLES -- the Warden panel contract
    -- ======================================================================
    --
    -- EVERY key here is `apply = "live"`, and that is not laziness. `promote()`
    -- is per-RESOURCE, not per-match, so on a mode where several rounds run at
    -- once -- which is exactly what the instance kernel makes true -- promoting
    -- at instance B's creation would move instance A's finish line too. The
    -- kernel therefore CAPTURES the whole set onto each instance at open
    -- (`instance.tune = Open77.tunables.capture()`) and every rule inside that
    -- instance reads the capture for its whole life. A mode that captures does
    -- not need `promote()` at all; declaring these `live` and letting the
    -- capture do the holding is the documented answer for concurrent rounds.
    --
    -- Bounds are chosen so that anything inside them is still a game. Anything
    -- outside them is not a setting, it is a bug report.
    tunables = {
        -- WHICH MAP THIS SERVER PLAYS, and the one durable fact the map editor
        -- keeps outside the database.
        --
        -- It is a tunable rather than a row for a specific reason: a tunable is
        -- written to `server/tunables.json`, which sits beside `server.jsonc`
        -- and OUTSIDE the watched `resources/` tree, and it survives a reload,
        -- a stop and a server restart with no database at all -- which is
        -- exactly how the dev configuration ships. The map GEOMETRY cannot live
        -- here (a tunable string is capped at 256 characters and its keys must
        -- be declared at load), but the selection is a <=32-character name and
        -- a per-server setting, which is precisely what this surface is for.
        --
        -- Plan §12 decision 5 said "one map, four zones", and that intent is
        -- unchanged: this is a single value, so the mode still runs ONE map at
        -- a time. See decision 21 -- the editor manages many as data, the
        -- server plays one.
        --
        -- `kabuki` is the BUILT-IN: the geometry shipped in shared/kabuki.lua,
        -- snapshotted at load, never written to, always restorable.
        activeMap = {
            value = "kabuki", type = "string",
            apply = "live", label = "Active map", group = "Map", order = 1,
            description = "Which map from the runtime store this server plays. 'kabuki' is the shipped built-in and is always available. Author maps in-game with /dm.map.",
        },
        ffaCapacity = {
            value = 12, type = "integer", min = 2, max = 24, step = 1,
            apply = "live", label = "FFA capacity", group = "Instances", order = 1,
            description = "Players per free-for-all instance. A new instance opens only when none has room.",
        },
        ffaCeiling = {
            value = 32, type = "integer", min = 1, max = 32, step = 1,
            apply = "live", label = "FFA instance ceiling", group = "Instances", order = 2,
            description = "How many free-for-all instances may run at once. Lowering it never closes one; it refuses the next.",
        },
        arenaCeiling = {
            value = 48, type = "integer", min = 1, max = 48, step = 1,
            apply = "live", label = "Arena match ceiling", group = "Instances", order = 3,
            description = "How many queued arena matches may run at once.",
        },
        emptyLingerSeconds = {
            value = 60, type = "integer", min = 0, max = 600, step = 5,
            unit = "s", apply = "live", label = "Empty linger", group = "Instances", order = 4,
            description = "How long an emptied instance keeps its bucket before releasing it, so a reconnect does not churn it.",
        },
        keepOneWarm = {
            value = false, type = "boolean",
            apply = "live", label = "Keep one instance warm", group = "Instances", order = 5,
            description = "Never reap the last free-for-all instance, so its bucket state stays settled between sessions.",
        },
        roundSeconds = {
            value = 300, type = "integer", min = 60, max = 1800, step = 30,
            unit = "s", apply = "live", label = "Round length", group = "Free-for-all", order = 1,
            description = "Maximum length of a free-for-all round. Captured when the round starts.",
        },
        killLimit = {
            value = 25, type = "integer", min = 1, max = 250, step = 1,
            apply = "live", label = "Kill limit", group = "Free-for-all", order = 2,
            description = "The first player to reach this many kills ends the round.",
        },
        respawnDelayMs = {
            value = 3000, type = "integer", min = 500, max = 15000, step = 250,
            unit = "ms", apply = "live", label = "Respawn delay", group = "Free-for-all", order = 3,
            description = "Delay between a counted death and the arena respawn.",
        },
        standingsSeconds = {
            value = 10, type = "integer", min = 3, max = 60, step = 1,
            unit = "s", apply = "live", label = "Standings", group = "Free-for-all", order = 4,
            description = "How long the standings are shown between rounds.",
        },
        loadoutMode = {
            value = "choice", choices = { "equalizer", "choice" },
            apply = "live", label = "Weapons", group = "Free-for-all", order = 5,
            description = "equalizer: one rotating weapon, the same for everyone, a new one each round. choice: every player picks a kit with /guns and keeps it. A change reaches a player at their next respawn, never in their hands.",
        },
        arenaBestOf = {
            value = 5, type = "integer", min = 1, max = 9, step = 2,
            apply = "live", label = "Best of", group = "Arena", order = 1,
            description = "Round wins needed to take an arena match. Odd, so there is no draw to explain.",
        },
        arenaRoundSeconds = {
            value = 120, type = "integer", min = 30, max = 600, step = 10,
            unit = "s", apply = "live", label = "Arena round length", group = "Arena", order = 2,
            description = "Time limit on one elimination round before it is scored on survivors.",
        },
        arenaBuySeconds = {
            value = 20, type = "integer", min = 5, max = 90, step = 1,
            unit = "s", apply = "live", label = "Buy window", group = "Arena", order = 3,
            description = "Time to pick a kit before an arena round starts.",
        },
        spawnProtectionSeconds = {
            value = 5.0, min = 0.0, max = 15.0, step = 0.5,
            unit = "s", apply = "live", label = "Spawn protection", group = "Combat", order = 1,
            description = "Invulnerability after a respawn. Five seconds is long for a twelve-player free-for-all and short for a contested spawn.",
        },
        spawnProtectionBreaksOnFire = {
            value = true, type = "boolean",
            apply = "live", label = "Protection breaks on aggression", group = "Combat", order = 2,
            description = "Drop a player's spawn protection the moment their own outgoing damage is credited.",
        },
        boundsBackstopSeconds = {
            value = 5.0, min = 1.0, max = 30.0, step = 0.5,
            unit = "s", apply = "live", label = "Boundary backstop", group = "Combat", order = 3,
            description = "How long a player must be held continuously outside the zone before the server places them back inside. The wall itself is enforced on the client; this is the authority behind it.",
        },
        fillWithBots = {
            value = false, type = "boolean",
            apply = "live", label = "Backfill with bots", group = "Bots", order = 1,
            description = "Quietly add bots to a thin free-for-all instance. Off in production: an empty server feels alive with bots and a busy one feels fake.",
        },
        arenaFillWithBots = {
            value = false, type = "boolean",
            apply = "live", label = "Fill arena queues with bots", group = "Bots", order = 2,
            description = "Complete a waiting 1v1/2v2/3v3 roster with bots so the match can start. Off in production: a queued format is a promise of opponents. An explicit '/dm.queue <format> bots' is always allowed regardless, and is the only way 3v3 can be tested on one machine.",
        },
        botFillTarget = {
            value = 6, type = "integer", min = 0, max = 23, step = 1,
            apply = "live", label = "Bot fill target", group = "Bots", order = 3,
            description = "How many bodies -- players plus bots -- a backfilled instance aims for.",
        },
        botDifficulty = {
            value = "standard", choices = { "relaxed", "standard", "veteran" },
            apply = "live", label = "Bot difficulty", group = "Bots", order = 4,
            description = "Reaction delay, hit chance by range band, burst length and aggression.",
        },
        -- RATING. The four an operator actually reaches for; the spread, the
        -- floor, the minimum delta and the provisional window stay in
        -- `Config.rating` because moving them under a live ladder is a
        -- between-seasons decision. Every one of these is read FRESH at the
        -- moment a round is rated, so a change reaches the next round with no
        -- reload -- and none of them can reach a round that contained a bot,
        -- because that round never gets as far as the rating at all.
        ratingEnabled = {
            value = true, type = "boolean",
            apply = "live", label = "Rate rounds", group = "Rating", order = 1,
            description = "Compute and persist a per-format ELO alongside the career row. Off leaves the career untouched and simply stops rating; ratings already stored are not erased.",
        },
        ratingStart = {
            value = 1000, type = "integer", min = 100, max = 5000, step = 50,
            apply = "live", label = "Starting rating", group = "Rating", order = 2,
            description = "Where an unrated player begins, per format. A rating is meaningless without a baseline and this is it. Changing it moves nobody who has already been rated.",
        },
        ratingArenaK = {
            value = 16, type = "integer", min = 1, max = 100, step = 1,
            apply = "live", label = "Arena K (per round)", group = "Rating", order = 3,
            description = "How far one arena ROUND can move a rating. Per round, not per match: a best-of-five exchanges up to five times, which is why this is well below a conventional per-match K.",
        },
        ratingFfaK = {
            value = 32, type = "integer", min = 1, max = 200, step = 1,
            apply = "live", label = "Free-for-all K (per round)", group = "Rating", order = 4,
            description = "How far one free-for-all round can move a rating, after the pairwise model divides by the field size less one. Higher than the arena K because a 300 s free-for-all round exchanges once.",
        },
    },
}
