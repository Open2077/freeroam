-- Race public configuration. This file is sent to clients: no secrets or ACL
-- decisions belong here.

RaceConfig = {
    schemaVersion = 2,

    lobby = {
        -- The menu and queue live in Freeroam; only heats are isolated.
        bucket = 0,
        center = { x = -1460.2, y = 99.9, z = 14.8 },
        heading = 175.0,
        placementGraceMs = 9000,
        start = {
            enabled = true,
            id = "race_lobby_terminal",
            offset = { x = 10.0, y = 0.0, z = 0.0 },
            radius = 3.0,
            style = "objective",
            label = "Open Race",
            description = "Join the next heat or choose a course.",
            key = "E",
            holdSeconds = 0.65,
            color = "#22D8E2",
            maxDistance = 100.0,
        },
    },

    engine = {
        minRacers = 1,
        maxRacers = 32,
        -- Once the minimum is reached, keep the lobby open for a fixed join
        -- window. New arrivals do not restart this countdown.
        queueGraceSeconds = 30.0,
        randomCourseEachHeat = true,
        -- Every driver receives this full loading window after the grid is
        -- created, even when all native seat confirmations arrive early.
        gridLoadSeconds = 20.0,
        -- Slow or failed clients may continue mounting after the loading
        -- window, but are classified DNF when this absolute grid timeout ends.
        gridReadySeconds = 60.0,
        -- The visible start sequence is exactly 3, 2, 1, GO. Vehicles remain
        -- input-locked through the whole sequence and release on the GO event.
        countdownSeconds = 3.0,
        durationSeconds = 1200.0,
        -- Once the winner finishes, remaining racers have this long to cross
        -- the line before the server classifies them DNF.
        finishGraceSeconds = 30.0,
        resultsSeconds = 12.0,
        heatBucket = 6500,
        checkpointRadius = 7.0,
        -- Do not accept a parallel street on the bridge above the course.
        checkpointZTolerance = 4.0,
        checkpointDebounceMs = 500,
        positionTickMs = 100,
        stateTickMs = 250,
        vehicleSeatPollMs = 500,
        maxSegmentMetres = 80.0,
        startGrid = {
            lanes = 2,
            laneSpacing = 3.25,
            rowSpacing = 5.5,
        },
        vehicle = {
            id = "archer_hella",
            record = "Vehicle.v_standard2_archer_hella_player",
            label = "Archer Hella EC-D i360",
            driverSeat = "seat_front_left",
            -- NCM creates slightly above the road, then places the materialized
            -- vehicle on the final slot while its durable automatic-seat order
            -- streams in. Once the native mount is confirmed, player authority
            -- wakes physics and the settle pass deliberately leaves it alone.
            spawnLiftMetres = 0.35,
            settleAfterMs = 1200,
            settledZOffsetMetres = 0.0,
            settleMaxDriftMetres = 3.0,
            -- ForcedExit needs a short native workspot window before the
            -- authoritative vehicle is removed and the player returns to lobby.
            exitSettleMs = 1500,
            primaryColor = { r = 24, g = 31, b = 38 },
            secondaryColor = { r = 0, g = 194, b = 209 },
        },
        -- Stable IDs are persisted in course JSON. Records never come from the
        -- browser or an unvalidated course payload: the server resolves the ID
        -- through this allow-list before spawning a grid vehicle.
        vehicles = {
            { id = "archer_hella", label = "Archer Hella EC-D i360",
                record = "Vehicle.v_standard2_archer_hella_player" },
            { id = "quadra_turbo_r", label = "Quadra Turbo-R V-Tech",
                record = "Vehicle.v_sport1_quadra_turbo_r_player" },
            { id = "quadra_type66_avenger", label = "Quadra Type-66 Avenger",
                record = "Vehicle.v_sport2_quadra_type66_avenger_player" },
            { id = "rayfield_caliburn", label = "Rayfield Caliburn",
                record = "Vehicle.v_sport1_rayfield_caliburn_player" },
            { id = "herrera_outlaw", label = "Herrera Outlaw GTS",
                record = "Vehicle.v_sport1_herrera_outlaw_player" },
            { id = "mizutani_shion", label = "Mizutani Shion MZ2",
                record = "Vehicle.v_sport2_mizutani_shion_player" },
            { id = "porsche_911", label = "Porsche 911 II Turbo",
                record = "Vehicle.v_sport2_porsche_911turbo_player" },
            { id = "archer_quartz_nomad", label = "Archer Quartz Sidewinder",
                record = "Vehicle.v_standard2_archer_quartz_nomad_player" },
        },
    },

    editor = {
        sessionMinutes = 30,
        -- Editing happens in the normal world rather than inside the isolated
        -- race lobby bucket. The editor car is disposable and session-scoped.
        worldBucket = 0,
        vehicleSpawnDistance = 4.5,
        vehicleSpawnLiftMetres = 0.35,
        vehicleSettleAfterMs = 1200,
        -- A point-to-point route only needs its finish. Circuits still require
        -- at least two checkpoints; server/courses.lua enforces that rule.
        minimumCheckpoints = 1,
        maximumCheckpoints = 96,
        minimumLaps = 1,
        maximumLaps = 99,
        minimumRadius = 2.0,
        maximumRadius = 30.0,
        maximumNameBytes = 64,
        maximumDescriptionBytes = 240,
        minimumGridSlots = 1,
        maximumGridSlots = 32,
        -- Slots closer than this are rejected both when captured and when a
        -- JSON course is loaded, so two authored vehicles cannot overlap.
        minimumGridSpacing = 2.75,
    },

    visuals = {
        enabled = true,
        -- Only the player's authoritative next checkpoint is drawn. Its native
        -- ground ring matches the acceptance radius and survives local entry
        -- until the server advances it, together with the GPS destination.
        checkpointViewDistance = 180.0,
        -- A calculated GPS route must use the same variant and trusted TweakDB
        -- definition as a right-click waypoint.
        nextBlipSprite = "CustomPositionVariant",
        nextBlipWalls = true,
    },

    presentation = {
        -- The sq024 layers are the exact vanilla race cues. Grid/tick/GO UI
        -- events mirror NCM 2.0's proven countdown sequence. Every play is
        -- best-effort: a missing audio bank or VFX can never stop race state.
        gridReadySfx = "ui_menu_onpress",
        countdownSfx = "sq024_race_countdown_start",
        countdownTickSfx = "ui_menu_onpress",
        countdownGoSfx = "ui_jingle_quest_new",
        goSfx = "sq024_race_start_fireworks",
        checkpointSfx = "ui_menu_onpress",
        lapSfx = "ui_jingle_quest_update",
        finishSfx = "ui_jingle_quest_success",
        startVfx = {
            { effect = "race.flare.smoke", lateral = -5.5, forward = 2.0, z = 0.20, duration = 8.0 },
            { effect = "race.flare.smoke", lateral = 5.5, forward = 2.0, z = 0.20, duration = 8.0 },
            -- The cooked effect is seven seconds long. Keep a small tail so
            -- Open77 does not kill its final particle burst on the boundary.
            { effect = "race.firework.burst", lateral = 0.0, forward = 5.0, z = 6.0, duration = 7.5 },
        },
    },

    -- The live catalogue is intentionally data-only: every selectable course
    -- must come from data/courses and therefore from the in-game editor (or an
    -- explicitly installed server JSON file). No sample/built-in track is
    -- silently mixed into a server owner's rotation.
    selectedCourse = nil,
    courses = {},

    debug = { verbose = true },
}
