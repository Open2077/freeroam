-- Public configuration for the freeroam gamemode.
--
-- This file is downloaded by clients, so never put secrets or ACL data here.
-- The shipped coordinates come from captures validated on build 2.31 (see
-- docs/research); operators are expected to replace them with their own spots.

FreeroamConfig = {
    -- Chat message sent when a player announces freeroam:ready.
    welcome = {
        enabled = true,
        text = "Welcome to freeroam — /freeroam.help lists the commands.",
        color = { 0, 229, 255 },
    },

    spawn = {
        -- random | nearest | first ("nearest" = closest point to the death).
        selection = "first",

        -- The pristine saves are only bootstrap worlds. Once the freeroam
        -- resource is ready, always replace their position with this
        -- gamemode-owned spawn (regardless of body family or save used).
        forceOnJoin = true,
        joinRetryMs = 250,
        joinTimeoutMs = 30000,

        -- Cooperating with a resource that restores a saved position
        -- (open77_playerstate). Freeroam owns spawn for a FIRST-TIME player and
        -- must not own it for a returning one: if both place the same player,
        -- the last one wins and the symptom is "placement appears to work and
        -- the player is somewhere else a second later".
        --
        -- Two knobs, and both fall back to the previous behaviour on their own.
        --
        -- deferToReadinessGate holds the join spawn back while the platform's
        -- join-time readiness gate still has this player. That is the
        -- documented platform rule -- do not teleport, spawn, kill or force a
        -- respawn on a player until their gate has opened -- which this
        -- resource predates and has been quietly violating. On a server whose
        -- binary has no gate at all, the check is skipped and this file behaves
        -- exactly as it did before.
        deferToReadinessGate = true,

        -- When the gate opens, its detail says WHY, and the host puts the
        -- releasing resource's own note there. That is the one place another
        -- resource's INTENT can reach this one, since server resources cannot
        -- call each other. A detail starting with any of these means somebody
        -- has already placed this player deliberately, and freeroam must leave
        -- them where they are. Empty this list to always spawn.
        placedByDetailPrefixes = { "playerstate:restored" },

        -- Automatic respawn after a death (gamemode teleports never enter this
        -- path).
        autoRespawn = true,
        respawnDelayMs = 4000,
        health = 1.0,
        graceMs = 5000,

        points = {
            {
                name = "freeroam_spawn",
                label = "Freeroam spawn",
                position = { x = 381.358826, y = -2401.794189, z = 181.988541 },
                heading = 0.0,
            },
        },
    },

    teleport = {
        enabled = true,
        health = 1.0,
        graceMs = 4000,

        -- /goto destinations. Coordinates come from repository captures
        -- (entity tests, markers/respawn/inspector docs) and are safe landing
        -- spots; adjust freely.
        locations = {
            { name = "arena",      label = "Freeroam arena",        district = "Badlands",    position = { x = 381.358826, y = -2401.794189, z = 181.988541 }, heading = 0.0 },
            { name = "lab",        label = "Open77 laboratory",     district = "East",        position = { x = 1669.75, y = -739.12, z = 49.86 },   heading = 0.0 },
            { name = "city",       label = "City west",             district = "City Center", position = { x = -667.14, y = -382.61, z = 9.16 },    heading = 0.0 },
            { name = "dealer",     label = "Vehicle dealership",    district = "Westbrook",   position = { x = -1442.2, y = 127.4, z = 18.0 },      heading = 0.0 },
            { name = "racegrid",   label = "Westbrook race grid",   district = "Westbrook",   position = { x = -1450.2, y = 119.9, z = 14.8 },      heading = 200.0 },
            { name = "heights",    label = "Northwest heights",     district = "North Oak",   position = { x = -1441.0, y = 1269.0, z = 123.0 },    heading = 180.0 },
            { name = "stoop",      label = "King Stoop forecourt",  district = "Watson",      position = { x = -410.22, y = 722.73, z = 115.0 },    heading = 147.0 },
            { name = "northside",  label = "North promenade",       district = "Watson",      position = { x = -469.47, y = 930.99, z = 56.45 },    heading = -68.0 },
            { name = "junction",   label = "Lower Watson junction", district = "Watson",      position = { x = -644.91, y = 1019.37, z = 36.56 },   heading = 75.5 },
            { name = "underpass",  label = "Lower Watson underpass",district = "Watson",      position = { x = -701.49, y = 1033.97, z = 35.71 },   heading = -104.5 },
            { name = "coast",      label = "Southwest coast",       district = "Badlands",    position = { x = -1716.38, y = -2421.28, z = 62.59 }, heading = 0.0 },
        },
    },

    vehicles = {
        defaultModel = "Vehicle.v_standard2_archer_hella_player",
        -- Keep public sessions tidy while still letting players compare a few
        -- cars. The oldest owned vehicle is recycled after a successful spawn.
        maxPerPlayer = 5,
        -- Spawn offset relative to the player (metres, world axes).
        spawnOffset = { x = 3.0, y = 0.0, z = 0.25 },
        -- Extra lift (metres) added on top of spawnOffset for AV records so
        -- they materialise clear of the ground instead of half-buried.
        avSpawnLift = 0.8,
        -- true: /car accepts any "Vehicle.*" record from the catalogue
        -- (see docs/vehicle-models.md). false: shortcuts only.
        allowCustomModels = true,

        -- Curated *_player records validated in docs/vehicle-models.md. The
        -- flat shortcut map used by /car is derived below from this catalog.
        catalog = {
            { key = "hella",       label = "Archer Hella",         category = "Street",  record = "Vehicle.v_standard2_archer_hella_player" },
            { key = "bandit",      label = "Archer Bandit",        category = "Street",  record = "Vehicle.v_standard2_archer_bandit_player" },
            { key = "quartz",      label = "Archer Quartz",        category = "Street",  record = "Vehicle.v_standard2_archer_quartz_player" },
            { key = "cortes",      label = "Villefort Cortes",     category = "Street",  record = "Vehicle.v_standard2_villefort_cortes_player" },
            { key = "delamain",    label = "Delamain Cortes",      category = "Street",  record = "Vehicle.v_standard2_villefort_cortes_delamain_player" },
            { key = "colby",       label = "Thorton Colby",        category = "Street",  record = "Vehicle.v_standard2_thorton_colby_player" },
            { key = "galena",      label = "Thorton Galena",       category = "Street",  record = "Vehicle.v_standard2_thorton_galena_player" },
            { key = "maimai",      label = "Makigai MaiMai",       category = "Street",  record = "Vehicle.v_standard2_makigai_maimai_player" },
            { key = "hozuki",      label = "Mizutani Hozuki",      category = "Street",  record = "Vehicle.v_standard2_mizutani_hozuki_player" },
            { key = "thrax",       label = "Chevalier Thrax",      category = "Street",  record = "Vehicle.v_standard2_chevalier_thrax_player" },
            { key = "supron",      label = "Mahir Supron",         category = "Utility", record = "Vehicle.v_standard25_mahir_supron_player" },
            { key = "columbus",    label = "Villefort Columbus",   category = "Utility", record = "Vehicle.v_standard25_villefort_columbus_player" },
            { key = "merrimac",    label = "Thorton Merrimac",     category = "Utility", record = "Vehicle.v_standard25_thorton_merrimac_player" },
            { key = "emperor",     label = "Chevalier Emperor",    category = "Utility", record = "Vehicle.v_standard3_chevalier_emperor_player" },
            { key = "mackinaw",    label = "Thorton Mackinaw",     category = "Utility", record = "Vehicle.v_standard3_thorton_mackinaw_player" },
            { key = "hellhound",   label = "Militech Hellhound",   category = "Utility", record = "Vehicle.v_standard3_militech_hellhound_player" },
            { key = "caliburn",    label = "Rayfield Caliburn",    category = "Sport",   record = "Vehicle.v_sport1_rayfield_caliburn_player" },
            { key = "mordred",     label = "Caliburn Mordred",     category = "Sport",   record = "Vehicle.v_sport1_rayfield_caliburn_mordred_player" },
            { key = "aerondight",  label = "Rayfield Aerondight",  category = "Sport",   record = "Vehicle.v_sport1_rayfield_aerondight_player" },
            { key = "outlaw",      label = "Herrera Outlaw",       category = "Sport",   record = "Vehicle.v_sport1_herrera_outlaw_player" },
            { key = "riptide",     label = "Herrera Riptide",      category = "Sport",   record = "Vehicle.v_sport1_herrera_riptide_player" },
            { key = "r7",          label = "Quadra Sport R-7",     category = "Sport",   record = "Vehicle.v_sport1_quadra_sport_r7_player" },
            { key = "turbo",       label = "Quadra Turbo-R",       category = "Sport",   record = "Vehicle.v_sport1_quadra_turbo_player" },
            { key = "type66",      label = "Quadra Type-66",       category = "Sport",   record = "Vehicle.v_sport2_quadra_type66_player" },
            { key = "avenger",     label = "Type-66 Avenger",      category = "Sport",   record = "Vehicle.v_sport2_quadra_type66_avenger_player" },
            { key = "shion",       label = "Mizutani Shion",       category = "Sport",   record = "Vehicle.v_sport2_mizutani_shion_player" },
            { key = "porsche",     label = "Porsche 911 Turbo",    category = "Sport",   record = "Vehicle.v_sport2_porsche_911turbo_player" },
            { key = "porschecab",  label = "Porsche 911 Cabrio",   category = "Sport",   record = "Vehicle.v_sport2_porsche_911turbo_cabrio_player" },
            { key = "alvarado",    label = "Villefort Alvarado",   category = "Sport",   record = "Vehicle.v_sport2_villefort_alvarado_player" },
            { key = "deleon",      label = "Villefort Deleon",     category = "Sport",   record = "Vehicle.v_sport2_villefort_deleon_player" },
            { key = "semimaru",    label = "Yaiba Semimaru",       category = "Bikes",   record = "Vehicle.v_sport1_yaiba_semimaru_player" },
            { key = "kusanagi",    label = "Yaiba Kusanagi",       category = "Bikes",   record = "Vehicle.v_sportbike1_yaiba_kusanagi_player" },
            { key = "muramasa",    label = "Yaiba Muramasa",       category = "Bikes",   record = "Vehicle.v_sportbike1_yaiba_muramasa_player" },
            { key = "arch",        label = "ARCH Nazaré",          category = "Bikes",   record = "Vehicle.v_sportbike2_arch_player" },
            { key = "jackie",      label = "Jackie's ARCH",        category = "Bikes",   record = "Vehicle.v_sportbike2_arch_jackie_player" },
            { key = "apollo",      label = "Brennan Apollo",       category = "Bikes",   record = "Vehicle.v_sportbike3_brennan_apollo_player" },
            { key = "manticore",   label = "Militech Manticore",   category = "AV",     record = "Vehicle.av_militech_manticore" },
            { key = "excalibur",   label = "Rayfield Excalibur",   category = "AV",     record = "Vehicle.av_rayfield_excalibur" },
            -- Third-party vehicles shipped as world packages (resources/assets/vehicles).
            -- The records only exist on a client that installed those packages, so
            -- list them only on worlds that require them (the freeroam servers do).
            { key = "aventador",   label = "Lamborghini Aventador SVJ", category = "Custom", record = "Vehicle.aventador_svj_01" },
            { key = "demon",       label = "Dodge Challenger SRT Demon", category = "Custom", record = "Vehicle.challenger_srt_demon_01" },
            { key = "m4csl",       label = "BMW M4 CSL",                 category = "Custom", record = "Vehicle.bmw_m4_csl" },
        },
        shortcuts = {},
    },

    weapons = {
        enabled = true,
        defaultReserve = 500,
        maximumReserve = 5000,
        catalog = {
            { key = "lexington", label = "M-10AF Lexington", category = "Handguns", record = "Items.Preset_Lexington_Default" },
            { key = "unity",     label = "Unity",            category = "Handguns", record = "Items.Preset_Unity_Default" },
            { key = "nue",       label = "Nue",              category = "Handguns", record = "Items.Preset_Nue_Default" },
            { key = "overture",  label = "Overture",         category = "Handguns", record = "Items.Preset_Overture_Default" },
            { key = "quasar",    label = "DR-12 Quasar",     category = "Handguns", record = "Items.Preset_Quasar_Default" },
            { key = "malorian",  label = "Malorian 3516",    category = "Handguns", record = "Items.Preset_Silverhand_3516" },
            { key = "saratoga",  label = "M221 Saratoga",    category = "SMG",      record = "Items.Preset_Saratoga_Default" },
            { key = "fenrir",    label = "Fenrir",           category = "SMG",      record = "Items.Preset_Saratoga_Maelstrom" },
            { key = "ajax",      label = "M251s Ajax",       category = "Rifles",   record = "Items.Preset_Ajax_Default" },
            { key = "copperhead",label = "D5 Copperhead",    category = "Rifles",   record = "Items.Preset_Copperhead_Default" },
            { key = "masamune",  label = "HJSH-18 Masamune", category = "Rifles",   record = "Items.Preset_Masamune_Default" },
            { key = "achilles",  label = "M-179e Achilles",  category = "Rifles",   record = "Items.Preset_Achilles_Default" },
            { key = "sor22",     label = "SOR-22",           category = "Rifles",   record = "Items.Preset_Sor22_Default" },
            { key = "grad",      label = "SPT32 Grad",       category = "Snipers",  record = "Items.Preset_Grad_Default" },
            { key = "nekomata",  label = "Nekomata",         category = "Snipers",  record = "Items.Preset_Nekomata_Default" },
            { key = "ashura",    label = "Ashura",           category = "Snipers",  record = "Items.Preset_Ashura_Default" },
            { key = "carnage",   label = "Carnage",          category = "Shotguns", record = "Items.Preset_Carnage_Default" },
            { key = "satara",    label = "DB-2 Satara",      category = "Shotguns", record = "Items.Preset_Satara_Default" },
            { key = "zhuo",      label = "L-69 Zhuo",        category = "Shotguns", record = "Items.Preset_Zhuo_Default" },
            { key = "defender",  label = "M2067 Defender",   category = "Heavy",   record = "Items.Preset_Defender_Default" },
            { key = "katana",    label = "Katana",           category = "Melee",   record = "Items.Preset_Katana_Default", melee = true },
            { key = "knife",     label = "Knife",            category = "Melee",   record = "Items.Preset_Knife_Default", melee = true },
            { key = "machete",   label = "Machete",          category = "Melee",   record = "Items.Preset_Machete_Default", melee = true },
            { key = "hammer",    label = "Hammer",           category = "Melee",   record = "Items.Preset_Hammer_Default", melee = true },
        },
    },

    player = {
        allowRestore = true,
        allowGodMode = true,
        armorOnRestore = 100,
    },

    -- Player-versus-player damage. The platform default is friendly fire OFF;
    -- freeroam opts in and shields the spawn areas.
    combat = {
        pvpEnabled = true,
        -- No damage inside this radius around any spawn point (metres).
        safeZoneRadius = 30.0,
        -- Multipliers applied by the server ledger on top of the vanilla
        -- damage computed on the attacker's game.
        damageMultiplier = 1.0,
        headshotMultiplier = 2.0,
        -- Per-attack-kind multipliers on top of the global one.
        rangedMultiplier = 1.0,
        meleeMultiplier = 1.0,
        explosionMultiplier = 1.0,
        -- Passive regeneration in health points per second (0 disables).
        regenPerSecond = 0.0,
        killfeed = {
            enabled = true,
            -- Entries visible at once and per-entry lifetime.
            maxEntries = 5,
            entryTtlMs = 6000,
        },
    },

    -- true: player commands (/car, /dv, /goto, /tpc, /spawn, /suicide,
    -- /revive) require the command.<name> ACL. The freeroam.* admin commands
    -- are always restricted.
    restrictPlayerCommands = false,

    blips = {
        enabled = true,
        locationSprite = "fast_travel",
        showSpawns = true,
        spawnSprite = "objective",
    },
}

for _, vehicle in ipairs(FreeroamConfig.vehicles.catalog) do
    FreeroamConfig.vehicles.shortcuts[vehicle.key] = vehicle.record
end
