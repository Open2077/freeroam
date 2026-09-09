-- Kabuki Arena -- career stats. Plan section 10, Phase 8.
--
-- The S5 seam scoring.lua reserved:
--
--   + if Deathmatch.scoring.ladderEligible(instance) then ... write ... end
--
-- This file is the `... write ...`. It persists what scoring.lua ALREADY KNOWS
-- -- kills, deaths, assists, headshots, multi-kills, best streak, score, damage
-- -- rather than recomputing any of it from a damage log this mode does not
-- keep. A career that disagreed with the scoreboard the player just read would
-- be worse than no career at all.
--
-- ===========================================================================
-- WHERE THE STATS LIVE, AND WHY THERE
-- ===========================================================================
--
-- 1. A PER-SERVER LADDER OWNED BY THE GAMEMODE, not a platform-wide profile
--    owned by the master.
--
--    The master (`Open77.Master`) owns accounts, licensing and leases, and it
--    is not reachable from server Lua at all -- there is no binding for it, so
--    a global profile would mean a new C# surface, a new master schema, and a
--    production deployment, for numbers that are only meaningful relative to
--    ONE server's tuning. A kill/death ratio earned under `killLimit = 30`,
--    the 49-weapon arsenal and a 12-player instance is not the same
--    measurement as one earned under an operator's own settings, and averaging
--    them would produce a number that describes nothing.
--
--    Decision 8 makes this cheap to be wrong about in one direction only:
--    progression gates NOTHING, so no other system has to read these rows. And
--    the key below is the master-backed GUID, so promoting this to a global
--    profile later is a migration of rows that are already keyed correctly --
--    not a re-keying. Starting global and discovering the numbers are not
--    comparable is the expensive mistake; starting local is not.
--
-- 2. MySQL THROUGH `Open77.database`, BECAUSE IT IS THE ONLY DURABLE STORE
--    SERVER LUA HAS.
--
--    `LuaResourceRuntime.Sandbox` nils out `io`, `os`, `package`, `dofile`,
--    `loadfile`, `load` and `require`. A resource cannot open a file, cannot
--    write one, and cannot even load a chunk from a string. `server/.open77/`
--    is host-owned and written only by C# -- and two of the files in it
--    (`master-identity.json`, `resource-signing-key.json`) are registration
--    SECRETS rather than cache, so it is not somewhere a gamemode has any
--    business writing even if it could. `Open77.tunables.set` does reach disk,
--    but it is a form's worth of declared scalars, not a table.
--
--    So: the database bridge, exactly as `pursuit/server/ranked.lua`,
--    `open77_appearance` and `open77_playerstate` use it. The manifest already
--    declared `database.access` for this phase.
--
-- 3. NO DATABASE IS A SUPPORTED STATE, NOT A FAILURE.
--
--    `server.deathmatch-local.jsonc` ships with the bridge OFF on purpose, and
--    says why: turning it on makes the credential mandatory, and it also wakes
--    `open77_appearance`, which then demands character creation the autonomous
--    test loop cannot drive. So the career degrades to a LOUDLY LABELLED
--    in-memory table for the run, and every readout says which store answered.
--    A silent volatile ladder is indistinguishable from a broken one.
--
-- ===========================================================================
-- THE THREE THINGS THAT WOULD HAVE BROKEN THIS
-- ===========================================================================
--
-- 1. DECISION 12 IS ENFORCED AT THE WRITE, AND IT IS THE FIRST THING THIS FILE
--    DOES. `recordRound` consults `Deathmatch.scoring.ladderEligible` before it
--    reads a single row. A bot round produces no snapshot, no queue entry, no
--    announcement and no statement -- there is nothing for a later query,
--    export or migration to remember to filter out, because nothing was
--    written. `ladderEligible` is two independent sticky taints AND-ed
--    (scoring.lua's own, and bots.lua's per-round one), and both fail closed.
--
-- 2. PLAYER IDS ARE REISSUED; THE IDENTIFIER IS NOT. Every row is keyed on
--    `Open77.players.identifier` -- the 36-character master-backed GUID bound
--    to the client's identity certificate. Keying on a player id would arm the
--    next arrival on that id with the last occupant's career.
--
--    That binding is one of the FIVE that RAISE from inside the C function on a
--    non-positive id, and the CLR exception unwinds past every `pcall` and
--    stops the resource -- the crash that killed every bot round four seconds
--    in. A bot is a participant with a NEGATIVE id and bots are in the
--    standings rows this file iterates. So the id is gated by `DM.playerId`
--    (which returns nil for anything below 1) BEFORE the binding is touched,
--    and never after.
--
--    It also returns `nil` for a player who has already gone, which is exactly
--    when a round resolves. Identity is therefore captured EAGERLY, on connect
--    and at round start, and the snapshot is what the write uses.
--
-- 3. NOTHING ACCUMULATES ACROSS ROUNDS IN LUA. The unit of persistence is ONE
--    ROUND. A hot reload hands the successor VM a fresh everything, so a module
--    that banked a session total and flushed it "later" would lose whatever it
--    was holding on every Lua save -- and this mode is edited while it runs.
--    Recording at round end means a reload can cost at most the round that is
--    live, which is unavoidable and honest; and the pending queue itself rides
--    across the reload in `Open77.state`, which is host-owned and survives the
--    VM (though deliberately not a resource stop, and not a server restart --
--    that is what the database is for).
-- ===========================================================================

Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig

DM.ranked = DM.ranked or {}
local Ranked = DM.ranked


-- ------------------------------------------------------------------ config --

-- Defaults spelled out so a server whose config predates this file still runs.
local DEFAULTS = {
    enabled = true,
    recordRounds = true,
    tablePrefix = "open77_dm_",
    announceOnJoin = true,
    announceExclusion = true,
    maxCarriedIdentities = 48,
    maxCarriedRounds = 32,
    maxPendingRounds = 128,
    statementChunk = 48,        -- the bridge refuses more than 64 per transaction
}

local function setting(key)
    local block = Config ~= nil and Config.career or nil
    if type(block) == "table" and block[key] ~= nil then return block[key] end
    return DEFAULTS[key]
end

local function enabled()
    return setting("enabled") ~= false
end

local function tableName(suffix)
    local prefix = tostring(setting("tablePrefix") or "open77_dm_")
    -- The prefix reaches SQL as an IDENTIFIER, and identifiers cannot be bound
    -- as parameters. It is operator-supplied config, so it is whitelisted here
    -- rather than trusted: anything outside [A-Za-z0-9_] falls back to the
    -- default instead of being concatenated into a statement.
    if prefix:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then prefix = "open77_dm_" end
    return prefix .. suffix
end

local function log(text)
    DM.log("ranked: " .. tostring(text))
end


-- ----------------------------------------------------------------- helpers --

local function scoringModule()
    local module = DM.scoring
    if type(module) ~= "table" then return nil end
    return module
end

local function botsModule()
    local module = DeathmatchBots
    if type(module) ~= "table" then return nil end
    return module
end

-- The eight numbers a career is made of, plus the two that are maxima rather
-- than sums. One definition, used by the blank record, the round delta, the
-- database read and the readout, so the four cannot drift apart.
local SUM_FIELDS = {
    "kills", "deaths", "assists", "headshots", "multiKills",
    "score", "damage", "rounds", "wins",
}
local MAX_FIELDS = { "bestStreak" }

local function blankTotals()
    local totals = {}
    for _, field in ipairs(SUM_FIELDS) do totals[field] = 0 end
    for _, field in ipairs(MAX_FIELDS) do totals[field] = 0 end
    return totals
end

local function addTotals(into, delta)
    for _, field in ipairs(SUM_FIELDS) do
        into[field] = (into[field] or 0) + math.floor(tonumber(delta[field]) or 0)
    end
    for _, field in ipairs(MAX_FIELDS) do
        into[field] = math.max(into[field] or 0, math.floor(tonumber(delta[field]) or 0))
    end
    return into
end

-- `stored` is what the durable store last said; `session` is what has been
-- recorded since and is not yet reflected in it. The readout is the sum, so a
-- player who just finished a round sees it immediately whether or not the
-- transaction has landed.
local function combine(stored, session)
    local out = blankTotals()
    addTotals(out, stored)
    for _, field in ipairs(SUM_FIELDS) do
        out[field] = out[field] + math.floor(tonumber(session[field]) or 0)
    end
    for _, field in ipairs(MAX_FIELDS) do
        out[field] = math.max(out[field], math.floor(tonumber(session[field]) or 0))
    end
    return out
end


-- ------------------------------------------------------------------- state --

-- identifier -> { identifier, loaded, requested, modes = { <mode> = { stored, session } } }
--
-- The authoritative copy while the server runs. The database is where it goes
-- to survive a restart, not where it is read from during a round.
local careers = {}

-- Rounds recorded and not yet durably written. Carried across a hot reload in
-- `Open77.state`; see `carry` below.
local pending = {}

-- Tri-state, exactly as pursuit and open77_appearance do it. There is no "is
-- the database on?" question to ask -- `MySQL` is installed by the bootstrap
-- whether or not the bridge is enabled and whether or not this resource holds
-- `database.access`, so testing the global proves nothing. The first real
-- statement is the probe.
--   nil   = not probed yet
--   true  = schema is up, rows persist
--   false = degraded to memory for this run
local dbReady = nil
local dbReason = "not probed"

-- playerId -> true when THIS Lua generation saw them connect.
--
-- server/main.lua and server/loadout.lua both solve the same problem with the
-- same signal and this follows their precedent exactly: the durable marker is
-- the ABSENCE of `onPlayerConnected`, which does not re-fire for a client that
-- is already connected. No connect in this generation means the player was in
-- the world before the reload -- so `announced` is empty for exactly the same
-- reason `connected` is, the two absences cancel, and a reload survivor is
-- marked announced and left alone. A Lua save must not print a career card in
-- front of somebody who is mid-fight.
local connected = {}
local announced = {}

local function storageLine()
    if not enabled() then return "career DISABLED in config" end
    if dbReady == true then return "database (" .. tableName("career") .. ")" end
    if dbReady == false then return "MEMORY ONLY -- volatile (" .. dbReason .. ")" end
    return "not probed yet"
end
Ranked.storageLine = storageLine


-- --------------------------------------------------------------- identity --

--- The one safe door onto `Open77.players.identifier`.
---
--- `DM.playerId` returns nil for anything below 1, so a bot's negative
--- participant id -- which IS in the standings rows this file walks -- never
--- reaches the binding that would stop the resource. A valid but departed
--- player answers `nil`, which is a refusal, not an error.
local function identifierOf(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end
    local ok, identifier = pcall(Open77.players.identifier, playerId)
    if not ok or type(identifier) ~= "string" then return nil end
    -- The master formats it "D", so it is exactly 36 characters. Anything else
    -- is refused outright rather than written as a career nobody can be matched
    -- back to. `open77_appearance` and `open77_playerstate` gate on the same
    -- length for the same reason.
    if #identifier ~= 36 then return nil end
    if identifier:find("[^0-9A-Fa-f%-]") ~= nil then return nil end
    return identifier
end

-- playerId -> identifier, captured while the player is certainly present.
-- `Open77.players.identifier` answers nil for somebody who has already gone,
-- and a round resolves at exactly the moment somebody may have.
local identities = {}

local function rememberIdentity(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end
    local identifier = identifierOf(playerId)
    -- Never overwrite a known identity with a miss.
    if identifier ~= nil then identities[playerId] = identifier end
    return identities[playerId]
end

local function careerFor(identifier)
    local record = careers[identifier]
    if record == nil then
        record = { identifier = identifier, loaded = false, requested = false, modes = {} }
        careers[identifier] = record
    end
    return record
end

-- THE RATING RIDES IN THE SAME SLOT AS THE CAREER, and it deliberately does NOT
-- ride in `stored` / `session`. Those are counters: every field in them is a sum
-- or a maximum, `addTotals` treats them as such, and the SQL upsert accumulates
-- them as deltas so two servers sharing one database cannot overwrite each
-- other. A rating is none of those things -- it is a GAUGE, it can go down, and
-- it is computed FROM its current value rather than added to it. Folding it into
-- `SUM_FIELDS` would have `combine` add a stored 1200 to a session 1200 and
-- report 2400.
--
--   rating        the last settled value; nil until the store has answered, at
--                 which point `settings.start` is what an absent row means
--   ratingRounds  rated rounds in THIS format, which is what picks the K
--   ratingPending deltas computed for rounds whose write has not landed yet
--   peak          the high-water mark, never lowered
local function modeSlot(record, mode)
    local slot = record.modes[mode]
    if slot == nil then
        slot = {
            stored = blankTotals(), session = blankTotals(),
            rating = nil, ratingRounds = 0, ratingPending = 0,
            peak = nil, lastDelta = 0,
        }
        record.modes[mode] = slot
    end
    -- A slot built by an older generation of this file and adopted across a hot
    -- reload has the career fields and not these; default them in place rather
    -- than anywhere the arithmetic would have to test for nil.
    if slot.ratingRounds == nil then slot.ratingRounds = 0 end
    if slot.ratingPending == nil then slot.ratingPending = 0 end
    if slot.lastDelta == nil then slot.lastDelta = 0 end
    return slot
end

-- Resolved at CALL time, never captured: `server/rating.lua` can be reloaded
-- under this one, and a server that drops it from the manifest keeps its career
-- and simply stops rating.
local function ratingModule()
    local module = DM.rating
    if type(module) ~= "table" or type(module.round) ~= "function" then return nil end
    return module
end

local function ratingSettings()
    local module = ratingModule()
    if module == nil then return nil end
    local ok, settings = pcall(module.settings)
    if not ok or type(settings) ~= "table" then return nil end
    return settings
end

--- What a player's rating READS as right now: the last settled value, plus any
--- delta that has been computed for a round whose write has not landed. Same
--- rule as the career numbers, which already include the unwritten rounds --
--- one readout cannot be honest about the kills and coy about the rating.
local function ratingValue(slot, settings)
    local base = slot.rating
    if base == nil then base = settings ~= nil and settings.start or 1000 end
    return base + (slot.ratingPending or 0)
end


-- ------------------------------------------------------- carried state --
--
-- `Open77.state` is host-owned and survives a hot reload; it is deliberately
-- dropped on stop/restart and it is not a database. What rides in it is exactly
-- the two things a fresh VM cannot rebuild and the database cannot yet answer:
-- rounds that were recorded but whose transaction has not landed, and -- when
-- the bridge is off -- the volatile career itself, which would otherwise be
-- wiped by every Lua save on precisely the servers where testing happens.
--
-- The bag is 64 KiB and it is SHARED. This file was its only user until the
-- live map editor landed; `server/mapstore.lua` now carries the map being
-- authored under its own top-level key, because a hot reload is exactly what
-- costs a surveyor an afternoon of walking. There is one bag per RESOURCE, so
-- both sides read-modify-write and preserve each other's keys -- see the merge
-- in `carry` below. A writer that built its payload from scratch would delete
-- the other's without any error at all.
--
-- It is trimmed rather than allowed to raise: an oversized save throws from the
-- C function, and losing a career readout is a far smaller failure than
-- stopping the resource.
local CARRY_PROTOCOL = 1
local CARRY_BUDGET_BYTES = 48 * 1024

local function carriedPayload(identityLimit, roundLimit)
    local rounds = {}
    for index = math.max(1, #pending - roundLimit + 1), #pending do
        rounds[#rounds + 1] = pending[index]
    end

    local volatileCareers = nil
    if dbReady == false then
        volatileCareers = {}
        local kept = 0
        for identifier, record in pairs(careers) do
            if kept >= identityLimit then break end
            local modes = {}
            local any = false
            for mode, slot in pairs(record.modes) do
                local totals = combine(slot.stored, slot.session)
                -- THE RATING RIDES TOO, and it needs its own reason to be
                -- carried: a player can hold a rating with no career rounds
                -- attached to it in this VM -- adopted across an earlier reload,
                -- or loaded from a store that has since gone away -- and losing
                -- it on the next Lua save is exactly the "volatile ladder that
                -- looks broken" this whole carry exists to prevent. These three
                -- keys are not in SUM_FIELDS or MAX_FIELDS, so `addTotals` on
                -- the other side steps straight over them and the career
                -- arithmetic cannot be corrupted by their presence.
                if slot.rating ~= nil then
                    totals.rating = slot.rating
                    totals.ratingRounds = slot.ratingRounds or 0
                    totals.peak = slot.peak or slot.rating
                end
                if totals.rounds > 0 or slot.rating ~= nil then
                    modes[mode] = totals
                    any = true
                end
            end
            if any then
                volatileCareers[identifier] = modes
                kept = kept + 1
            end
        end
    end

    return {
        protocol = CARRY_PROTOCOL,
        pending = rounds,
        volatile = volatileCareers,
    }
end

local function carry()
    if type(Open77.state) ~= "table" or type(Open77.state.save) ~= "function" then return end
    local identityLimit = math.floor(tonumber(setting("maxCarriedIdentities")) or 48)
    local roundLimit = math.floor(tonumber(setting("maxCarriedRounds")) or 32)
    for _ = 1, 4 do
        local payload = carriedPayload(identityLimit, roundLimit)
        local ok, encoded = pcall(json.encode, payload)
        if not ok then return end
        if #encoded <= CARRY_BUDGET_BYTES then
            -- THIS FILE IS NO LONGER THE BAG'S ONLY USER, and saving a payload
            -- built from scratch would silently delete the other one's.
            -- `server/mapstore.lua` carries the map a surveyor is in the middle
            -- of authoring under its own top-level key, and a round resolving
            -- mid-session would otherwise wipe it.
            --
            -- So: read the current bag, keep every key that is not ours, and
            -- write the merge. mapstore does the mirror image. Neither owns the
            -- bag; each owns its own keys. The `protocol` check in `adopt`
            -- below still only ever looks at this file's three.
            local bag = {}
            if type(Open77.state.load) == "function" then
                local read, existing = pcall(Open77.state.load)
                if read and type(existing) == "table" then
                    for key, value in pairs(existing) do
                        if key ~= "protocol" and key ~= "pending" and key ~= "volatile" then
                            bag[key] = value
                        end
                    end
                end
            end
            bag.protocol, bag.pending, bag.volatile =
                payload.protocol, payload.pending, payload.volatile

            -- Never inside `onResourceStop`: a reload prepares the successor
            -- BEFORE stopping this VM, so a write from a stopping resource is
            -- refused. Every call site here is a state change, which is what
            -- the contract asks for.
            pcall(Open77.state.save, bag)
            return
        end
        identityLimit = math.floor(identityLimit / 2)
        roundLimit = math.max(4, math.floor(roundLimit / 2))
        if identityLimit < 1 then identityLimit = 1 end
    end
    log("carried state would not fit in 48 KiB even trimmed -- not carried")
end

local function adopt()
    if type(Open77.state) ~= "table" or type(Open77.state.load) ~= "function" then return end
    local ok, carried = pcall(Open77.state.load)
    -- Untrusted input from a previous version of this file's own code.
    if not ok or type(carried) ~= "table" then return end
    if carried.protocol ~= CARRY_PROTOCOL then
        log("carried state from another protocol version discarded")
        return
    end

    -- REVALIDATED, NOT TRUSTED. This is JSON written by a previous generation of
    -- this file's own code, and the one field everything downstream indexes on
    -- is the identifier: `careers[nil]` raises, and a nil named parameter is an
    -- ABSENT key in a Lua values table, so it never reaches the binder and the
    -- driver rejects the whole statement for an undefined `@id`. An entry that
    -- cannot be keyed is dropped here rather than at either of those.
    local rounds = 0
    if type(carried.pending) == "table" then
        for _, record in ipairs(carried.pending) do
            if type(record) == "table" and type(record.entries) == "table" then
                local entries = {}
                for _, entry in ipairs(record.entries) do
                    if type(entry) == "table" and type(entry.identifier) == "string"
                        and #entry.identifier == 36 then
                        entries[#entries + 1] = entry
                    end
                end
                if #entries > 0 then
                    record.entries = entries
                    record.mode = tostring(record.mode or "ffa")
                    record.instanceId = math.floor(tonumber(record.instanceId) or 0)
                    record.roundId = math.floor(tonumber(record.roundId) or 0)
                    -- A round that was rated before its write failed keeps the
                    -- exchange it earned; recomputing it against a table that
                    -- has moved since would rate the same round twice from
                    -- different baselines. Revalidated to numbers, and dropped
                    -- entirely rather than half-trusted -- a missing block is a
                    -- round that simply gets rated on the retry.
                    local results = nil
                    if type(record.ratingResults) == "table" then
                        results = {}
                        for _, result in ipairs(record.ratingResults) do
                            local delta = type(result) == "table" and tonumber(result.delta) or nil
                            if delta == nil or delta ~= delta or type(result.key) ~= "string"
                                or #result.key ~= 36 then
                                results = nil
                                break
                            end
                            results[#results + 1] = {
                                key = result.key,
                                before = math.floor(tonumber(result.before) or 0),
                                delta = math.floor(delta),
                                after = math.floor(tonumber(result.after) or 0),
                            }
                        end
                        if results ~= nil and #results == 0 then results = nil end
                    end
                    record.ratingResults = results
                    record.ratingFloor = math.floor(tonumber(record.ratingFloor) or 0)
                    pending[#pending + 1] = record
                    rounds = rounds + 1
                end
            end
        end
    end

    local identityCount = 0
    if type(carried.volatile) == "table" then
        for identifier, modes in pairs(carried.volatile) do
            if type(identifier) == "string" and #identifier == 36 and type(modes) == "table" then
                local record = careerFor(identifier)
                for mode, totals in pairs(modes) do
                    if type(totals) == "table" then
                        local slot = modeSlot(record, tostring(mode))
                        addTotals(slot.stored, totals)
                        -- Revalidated like everything else here: this is JSON
                        -- written by a previous generation of this file's own
                        -- code, and a rating that arrives as a string or a table
                        -- would poison every later exchange rather than failing
                        -- anywhere visible.
                        local rating = tonumber(totals.rating)
                        if rating ~= nil and rating == rating then
                            slot.rating = math.floor(rating)
                            slot.ratingRounds =
                                math.max(0, math.floor(tonumber(totals.ratingRounds) or 0))
                            slot.peak =
                                math.floor(tonumber(totals.peak) or slot.rating)
                        end
                    end
                end
                identityCount = identityCount + 1
            end
        end
    end

    -- Re-arm the unsettled rating deltas, AFTER the volatile block above has put
    -- the settled ratings back. `ratingPending` is what makes a card honest
    -- between an exchange and the write that carries it; it died with the
    -- outgoing VM while the exchange itself rode across in `pending`, so without
    -- this the two would disagree until the retry landed.
    for _, record in ipairs(pending) do
        for _, result in ipairs(record.ratingResults or {}) do
            local slot = modeSlot(careerFor(result.key), record.mode)
            slot.ratingPending = (slot.ratingPending or 0) + result.delta
        end
    end

    if rounds > 0 or identityCount > 0 then
        log(("adopted %d unwritten round(s) and %d volatile career(s) across a reload")
            :format(rounds, identityCount))
    end
end


-- ------------------------------------------------------------------ schema --
--
-- Two tables, and the second is not bookkeeping either.
--
-- `<prefix>career` is the ladder: one row per identity PER MODE, because a
-- free-for-all K/D says nothing about a 1v1 (plan section 10) and folding them
-- together would produce a number that describes neither.
--
-- `<prefix>rounds` is one row per persisted round per player, and it exists so
-- that "a round containing a bot leaves no row behind" -- the Phase 8 gate,
-- verbatim -- is a question somebody can actually ASK:
--
--     SELECT COUNT(*) FROM open77_dm_rounds WHERE instance_id = ? AND round_id = ?;
--
-- An aggregate-only ladder can only ever be checked by not moving, which is
-- indistinguishable from a ladder that is not writing at all.
--
-- THERE IS NO NAME COLUMN, and that is deliberate rather than an omission --
-- `pursuit_ranked_ratings` carries one and this does not. A career row is
-- durable, exportable data on a real person; the identifier is opaque and
-- already master-backed, and the display name is answered live by
-- `Open77.players.name` at the moment somebody reads the card. Storing it would
-- put a chosen human-readable handle on disk for no capability at all.
local function schema()
    return {
        ([[
        CREATE TABLE IF NOT EXISTS %s (
            identifier   CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            mode         VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            kills        BIGINT UNSIGNED NOT NULL DEFAULT 0,
            deaths       BIGINT UNSIGNED NOT NULL DEFAULT 0,
            assists      BIGINT UNSIGNED NOT NULL DEFAULT 0,
            headshots    BIGINT UNSIGNED NOT NULL DEFAULT 0,
            multi_kills  BIGINT UNSIGNED NOT NULL DEFAULT 0,
            best_streak  INT UNSIGNED NOT NULL DEFAULT 0,
            score        BIGINT NOT NULL DEFAULT 0,
            damage       BIGINT UNSIGNED NOT NULL DEFAULT 0,
            rounds       BIGINT UNSIGNED NOT NULL DEFAULT 0,
            wins         BIGINT UNSIGNED NOT NULL DEFAULT 0,
            first_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_played  DATETIME NULL,
            PRIMARY KEY (identifier, mode),
            KEY idx_%s_ladder (mode, kills DESC)
        ) ENGINE=InnoDB
        ]]):format(tableName("career"), tableName("career")),
        ([[
        CREATE TABLE IF NOT EXISTS %s (
            id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            identifier   CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            mode         VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            instance_id  INT NOT NULL,
            round_id     INT NOT NULL,
            kills        INT NOT NULL DEFAULT 0,
            deaths       INT NOT NULL DEFAULT 0,
            assists      INT NOT NULL DEFAULT 0,
            headshots    INT NOT NULL DEFAULT 0,
            multi_kills  INT NOT NULL DEFAULT 0,
            best_streak  INT NOT NULL DEFAULT 0,
            score        INT NOT NULL DEFAULT 0,
            damage       INT NOT NULL DEFAULT 0,
            won          TINYINT(1) NOT NULL DEFAULT 0,
            played_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            KEY idx_%s_identity (identifier, mode),
            KEY idx_%s_round (instance_id, round_id)
        ) ENGINE=InnoDB
        ]]):format(tableName("rounds"), tableName("rounds"), tableName("rounds")),
        -- THE RATING IS ITS OWN TABLE, not three more columns on `career`.
        --
        -- Two reasons, and the second is the one that decided it. First, an
        -- existing deployment: `CREATE TABLE IF NOT EXISTS` cannot add a column,
        -- so folding the rating into `career` would need a migration -- and
        -- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` is MariaDB-only syntax that
        -- would quietly make this ladder refuse to start on MySQL.
        --
        -- Second and more importantly, the two have different WRITE semantics.
        -- Every career column is a counter and its upsert is a pure delta
        -- accumulation, which is what makes two servers sharing one database
        -- safe. A rating is a gauge computed from its own current value. Keeping
        -- them apart is what stops somebody adding `rating = VALUES(rating)` to
        -- a statement whose every other clause is `x = x + VALUES(x)`.
        --
        -- The key is the same (identifier, mode) as the career, so the two rows
        -- are one join apart, and a promotion to a master-owned global profile
        -- stays a migration of correctly-keyed rows rather than a re-keying.
        ([[
        CREATE TABLE IF NOT EXISTS %s (
            identifier   CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            mode         VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            rating       INT NOT NULL,
            peak         INT NOT NULL,
            rated_rounds BIGINT UNSIGNED NOT NULL DEFAULT 0,
            last_delta   INT NOT NULL DEFAULT 0,
            first_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at   DATETIME NULL,
            PRIMARY KEY (identifier, mode),
            KEY idx_%s_ladder (mode, rating DESC)
        ) ENGINE=InnoDB
        ]]):format(tableName("rating"), tableName("rating")),
    }
end

--- Probe the bridge by putting the schema up. Coroutine only -- `.await` yields.
local function ensureSchema()
    if dbReady ~= nil then return dbReady end
    local ok, reason = pcall(function()
        for _, statement in ipairs(schema()) do MySQL.update.await(statement) end
    end)
    if not ok then
        dbReady = false
        dbReason = tostring(reason)
        log("DATABASE UNAVAILABLE (" .. dbReason .. ") -- careers are VOLATILE this run")
        -- The volatile career now needs the reload bridge it did not need while
        -- the durable store was still a possibility.
        carry()
        return false
    end
    dbReady = true
    dbReason = "ready"
    log("database ready -- careers persist in " .. tableName("career"))
    return true
end


-- ------------------------------------------------------------ the worker --
--
-- ONE coroutine owns every database call this file makes, and that is not
-- tidiness. `.await` yields, so two independent `CreateThread`s can interleave
-- mid-transaction -- and the two operations here are a LOAD (replace `stored`
-- with what the table says) and a COMMIT (move a delta out of `session` and
-- into `stored`). Interleave them and a load can overwrite a commit's result
-- with a row read before it landed, or a commit can be double-counted by a load
-- that already includes it. Serialised in one FIFO, every order is correct:
-- a load enqueued first runs first, and a load enqueued after a commit reads a
-- table that already contains it while `session` no longer does.
--
-- Nothing here runs on the tick, and nothing here runs in a damage or kill
-- path: `recordRound` snapshots synchronously and returns, and this drains
-- afterwards.
local jobs = {}
local workerRunning = false
local drain

local function enqueue(job)
    jobs[#jobs + 1] = job
    if workerRunning then return end
    workerRunning = true
    CreateThread(function()
        local ok, err = pcall(drain)
        workerRunning = false
        if not ok then log("worker raised: " .. tostring(err)) end
        -- A raise leaves work behind. Restart once rather than stalling until
        -- the next round; a second failure will log again and stop.
        if not ok and #jobs > 0 then
            workerRunning = true
            CreateThread(function()
                local retried, why = pcall(drain)
                workerRunning = false
                if not retried then log("worker raised again, stalling: " .. tostring(why)) end
            end)
        end
    end)
end

local function loadCareer(identifier)
    local record = careerFor(identifier)
    if record.loaded then return end
    if not ensureSchema() then
        -- Degraded: the blank record IS the record. Marked loaded so the same
        -- failed query is not retried once per round for the rest of the run.
        record.loaded = true
        return
    end
    local ok, rows = pcall(function()
        return MySQL.query.await(([[
            SELECT mode, kills, deaths, assists, headshots, multi_kills,
                   best_streak, score, damage, rounds, wins
              FROM %s
             WHERE identifier = ?
        ]]):format(tableName("career")), { identifier })
    end)
    if not ok then
        log(("career load failed for %s: %s"):format(identifier, tostring(rows)))
        return
    end
    if type(rows) == "table" then
        for _, row in ipairs(rows) do
            local slot = modeSlot(record, tostring(row.mode or "ffa"))
            slot.stored = {
                kills = math.floor(tonumber(row.kills) or 0),
                deaths = math.floor(tonumber(row.deaths) or 0),
                assists = math.floor(tonumber(row.assists) or 0),
                headshots = math.floor(tonumber(row.headshots) or 0),
                multiKills = math.floor(tonumber(row.multi_kills) or 0),
                bestStreak = math.floor(tonumber(row.best_streak) or 0),
                score = math.floor(tonumber(row.score) or 0),
                damage = math.floor(tonumber(row.damage) or 0),
                rounds = math.floor(tonumber(row.rounds) or 0),
                wins = math.floor(tonumber(row.wins) or 0),
            }
        end
    end

    -- The rating rows, in the same coroutine turn and BEFORE `record.loaded` is
    -- set. That ordering is the whole point: the commit job below calls
    -- `loadCareer` for every participant and only then computes the exchange, so
    -- a rating is never calculated against a baseline the store had not yet
    -- answered for. A rating computed from a default 1000 when the table said
    -- 1400 is not a rounding error -- the delta is then written against the real
    -- value and the player's rating jumps to somewhere neither number implies.
    local rated, ratingRows = pcall(function()
        return MySQL.query.await(([[
            SELECT mode, rating, peak, rated_rounds
              FROM %s
             WHERE identifier = ?
        ]]):format(tableName("rating")), { identifier })
    end)
    if not rated then
        -- Deliberately NOT marked loaded: the career half landed and the rating
        -- half did not, and rating this player against a default while his real
        -- row exists is the one failure mode worth retrying for.
        log(("rating load failed for %s: %s"):format(identifier, tostring(ratingRows)))
        return
    end
    if type(ratingRows) == "table" then
        for _, row in ipairs(ratingRows) do
            local slot = modeSlot(record, tostring(row.mode or "ffa"))
            slot.rating = math.floor(tonumber(row.rating) or 0)
            slot.peak = math.floor(tonumber(row.peak) or slot.rating)
            slot.ratingRounds = math.floor(tonumber(row.rated_rounds) or 0)
        end
    end
    record.loaded = true
end

-- ------------------------------------------------------- the rating write --
--
-- ONE event per rated round, broadcast, carrying no name and no identifier --
-- the same contract as `deathmatch:ladderWrite` above and for the same reason.
-- It is separate from that one rather than folded into it because the two are
-- decided at different moments: the ladder write is the round's DECISION, taken
-- synchronously at round end, while the exchange below can only be computed
-- once the store has answered for everybody's baseline. A single event would
-- have had to wait for the database to say anything at all.
local function announceRating(record)
    local playerOf = {}
    for _, entry in ipairs(record.entries) do playerOf[entry.identifier] = entry.playerId end
    local rows = {}
    for _, result in ipairs(record.ratingResults) do
        rows[#rows + 1] = {
            id = playerOf[result.key],
            before = result.before, delta = result.delta, after = result.after,
            k = result.k, expected = result.expected, actual = result.actual,
            place = result.place, team = result.team,
            provisional = result.provisional == true,
        }
    end
    TriggerClientEvent("deathmatch:ratingWrite", -1, {
        instanceId = record.instanceId,
        roundId = record.roundId,
        mode = record.mode,
        model = record.ratingModel,
        storage = storageLine(),
        at = DM.nowMs(),
        rows = rows,
    })
end

--- Rate one recorded round. COMPUTED ON THE WORKER, deliberately, and that
--- placement is the whole reason the number can be trusted.
---
--- `recordRound` is synchronous and returns before any statement is issued, so
--- at that moment a participant's stored rating may not have been read yet --
--- `warm` queues the load at round start, and the load and this share one FIFO
--- but not one instant. A rating computed from the 1000 default when the table
--- says 1400 is not a rounding error: the DELTA is then applied to the real
--- 1400 and the player lands somewhere neither number implies. So the commit
--- job loads every participant first and calls this afterwards, on the same
--- coroutine, where "loaded" is a fact rather than a hope.
---
--- Computed ONCE per record, guarded by `record.ratingResults`. A transient
--- write failure leaves the round in `pending` and it is retried later; the
--- exchange it carries is what was earned at the time, not a recalculation
--- against a table that has moved since.
local function applyRating(record)
    if record.ratingResults ~= nil then return end
    local module = ratingModule()
    if module == nil then return end
    local settings = ratingSettings()
    if settings == nil or not settings.enabled then return end

    local participants = {}
    for _, entry in ipairs(record.entries) do
        local slot = modeSlot(careerFor(entry.identifier), record.mode)
        participants[#participants + 1] = {
            key = entry.identifier,
            rating = ratingValue(slot, settings),
            rounds = slot.ratingRounds or 0,
            kills = entry.kills,
            deaths = entry.deaths,
            score = entry.score,
            team = entry.team or 0,
        }
    end

    local ok, results, model, note = pcall(module.round, record.mode, participants, {
        winnerTeam = record.winnerTeam,
        settings = settings,
    })
    if not ok then
        log("rating model raised: " .. tostring(results))
        return
    end
    if results == nil then
        record.ratingNote = tostring(note or "not rated")
        return
    end

    record.ratingModel = tostring(model)
    record.ratingResults = results
    -- Carried on the record rather than re-read at write time: the panel can
    -- move the floor between the exchange and the statement, and the two must
    -- not then disagree about where a player landed.
    record.ratingFloor = settings.floor
    -- The card a player reads must be right NOW, from the same numbers, exactly
    -- as the career already is. `settle` moves this into `rating` once the
    -- statement has landed -- or once there turns out to be nowhere to land.
    for _, result in ipairs(results) do
        local slot = modeSlot(careerFor(result.key), record.mode)
        slot.ratingPending = (slot.ratingPending or 0) + result.delta
    end
    announceRating(record)
end

local function statementsFor(record)
    local statements = {}
    local careerTable = tableName("career")
    local roundsTable = tableName("rounds")
    local recordRounds = setting("recordRounds") ~= false

    for _, entry in ipairs(record.entries) do
        statements[#statements + 1] = {
            query = ([[
                INSERT INTO %s
                    (identifier, mode, kills, deaths, assists, headshots, multi_kills,
                     best_streak, score, damage, rounds, wins, last_played)
                VALUES (@id, @mode, @kills, @deaths, @assists, @headshots, @multi,
                        @streak, @score, @damage, 1, @won, CURRENT_TIMESTAMP)
                ON DUPLICATE KEY UPDATE
                    kills = kills + VALUES(kills),
                    deaths = deaths + VALUES(deaths),
                    assists = assists + VALUES(assists),
                    headshots = headshots + VALUES(headshots),
                    multi_kills = multi_kills + VALUES(multi_kills),
                    best_streak = GREATEST(best_streak, VALUES(best_streak)),
                    score = score + VALUES(score),
                    damage = damage + VALUES(damage),
                    rounds = rounds + 1,
                    wins = wins + VALUES(wins),
                    last_played = CURRENT_TIMESTAMP
            ]]):format(careerTable),
            -- The upsert is a DELTA, never a total. Two servers sharing one
            -- database, or a row edited by hand, must not be silently
            -- overwritten by whatever this VM happened to have cached.
            values = {
                id = entry.identifier, mode = record.mode,
                kills = entry.kills, deaths = entry.deaths, assists = entry.assists,
                headshots = entry.headshots, multi = entry.multiKills,
                streak = entry.bestStreak, score = entry.score, damage = entry.damage,
                won = entry.won and 1 or 0,
            },
        }
        if recordRounds then
            statements[#statements + 1] = {
                query = ([[
                    INSERT INTO %s
                        (identifier, mode, instance_id, round_id, kills, deaths, assists,
                         headshots, multi_kills, best_streak, score, damage, won)
                    VALUES (@id, @mode, @instance, @round, @kills, @deaths, @assists,
                            @headshots, @multi, @streak, @score, @damage, @won)
                ]]):format(roundsTable),
                values = {
                    id = entry.identifier, mode = record.mode,
                    instance = record.instanceId, round = record.roundId,
                    kills = entry.kills, deaths = entry.deaths, assists = entry.assists,
                    headshots = entry.headshots, multi = entry.multiKills,
                    streak = entry.bestStreak, score = entry.score, damage = entry.damage,
                    won = entry.won and 1 or 0,
                },
            }
        end
    end

    -- The rating, written as a DELTA for the same reason every career column is:
    -- two servers sharing one database, or a row corrected by hand, must not be
    -- silently overwritten by whatever this VM happened to have cached.
    -- `GREATEST(@floor, ...)` puts the floor in SQL as well as in the model, so
    -- the table cannot end up holding a value the model would never produce.
    --
    -- NOTE THE ORDER OF THE TWO ASSIGNMENTS. MySQL evaluates the assignments of
    -- ON DUPLICATE KEY UPDATE left to right and a later one sees the values the
    -- earlier ones wrote, so `peak` is assigned FIRST -- while `rating` on its
    -- right-hand side is still the row's OLD value -- and computes the same
    -- expression `rating` is about to be given. Swapping the two lines would
    -- silently double the delta into the peak.
    for _, result in ipairs(record.ratingResults or {}) do
        statements[#statements + 1] = {
            query = ([[
                INSERT INTO %s
                    (identifier, mode, rating, peak, rated_rounds, last_delta, updated_at)
                VALUES (@id, @mode, @after, @after, 1, @delta, CURRENT_TIMESTAMP)
                ON DUPLICATE KEY UPDATE
                    peak         = GREATEST(peak, GREATEST(@floor, rating + @delta)),
                    rating       = GREATEST(@floor, rating + @delta),
                    rated_rounds = rated_rounds + 1,
                    last_delta   = @delta,
                    updated_at   = CURRENT_TIMESTAMP
            ]]):format(tableName("rating")),
            values = {
                id = result.key, mode = record.mode,
                after = result.after, delta = result.delta,
                floor = record.ratingFloor or 0,
            },
        }
    end
    return statements
end

--- Move one round's delta out of `session` and into `stored`. Called once the
--- durable store has it, and once when there is no durable store to have it --
--- in the degraded case `stored` is simply where the volatile total lives.
local function settle(record)
    for _, entry in ipairs(record.entries) do
        local slot = modeSlot(careerFor(entry.identifier), record.mode)
        for _, field in ipairs(SUM_FIELDS) do
            slot.session[field] = math.max(0,
                (slot.session[field] or 0) - math.floor(tonumber(entry[field]) or 0))
        end
        addTotals(slot.stored, entry)
        -- `bestStreak` is a maximum, so the session copy cannot be decremented;
        -- it is simply dropped, because `stored` now holds it.
        slot.session.bestStreak = 0
    end

    -- The rating settles the same way and for the same reason, as a DELTA
    -- rather than an assignment. `result.after` was computed against the
    -- baseline plus whatever was already pending, and the worker's FIFO
    -- guarantees earlier rounds settle first -- so adding the delta and
    -- assigning `after` agree, and the delta form is the one that stays correct
    -- if they ever stop agreeing.
    for _, result in ipairs(record.ratingResults or {}) do
        local slot = modeSlot(careerFor(result.key), record.mode)
        local floor = record.ratingFloor or 0
        -- `slot.rating` is nil until something has settled into it, and when it is
        -- nil THIS is that something: the worker's FIFO settles rounds in the
        -- order they were recorded, so an earlier round for the same identity and
        -- format has already been through here and left a value behind. A nil
        -- therefore means no earlier round is outstanding, which makes
        -- `result.before` -- the baseline the exchange was computed against --
        -- exactly the right base.
        --
        -- The first version of this line subtracted `ratingPending` from
        -- `result.before` to "undo" the optimistic display, and that was wrong in
        -- the one case that always happens: `applyRating` has ALREADY added this
        -- round's own delta to `ratingPending`, so the subtraction removed the
        -- very delta about to be added and every first-ever rated round settled
        -- back to the baseline. The card said `last +32` over a rating of 1000.
        local before = slot.rating
        if before == nil then before = result.before end
        local after = before + result.delta
        if after < floor then after = floor end
        slot.rating = after
        slot.peak = math.max(slot.peak or after, after)
        slot.ratingRounds = (slot.ratingRounds or 0) + 1
        slot.lastDelta = result.delta
        slot.ratingPending = (slot.ratingPending or 0) - result.delta
    end
end

local function commit(record)
    if not ensureSchema() then return false, "degraded" end
    local statements = statementsFor(record)
    local chunk = math.max(1, math.min(64, math.floor(tonumber(setting("statementChunk")) or 48)))
    local index = 1
    while index <= #statements do
        local slice = {}
        for offset = index, math.min(index + chunk - 1, #statements) do
            slice[#slice + 1] = statements[offset]
        end
        -- `transaction.await` resolves a failure to `false, reason` instead of
        -- raising (oxmysql parity), so BOTH have to be tested: the pcall for a
        -- bridge-level refusal, and the return for a rollback.
        local ok, committed, reason = pcall(function()
            return MySQL.transaction.await(slice)
        end)
        if not ok then return false, tostring(committed) end
        if committed ~= true then return false, tostring(reason or "rolled_back") end
        index = index + chunk
    end
    return true
end

drain = function()
    while #jobs > 0 do
        local job = table.remove(jobs, 1)
        if job.kind == "load" then
            loadCareer(job.identifier)
        elseif job.kind == "commit" then
            local record = job.record
            -- LOAD, THEN RATE, THEN WRITE, in that order and on this one
            -- coroutine. `loadCareer` is idempotent and returns immediately for
            -- anybody already loaded, so this costs nothing in the ordinary case
            -- -- and in the case that matters (a player whose warm-up load has
            -- not come back yet) it is the difference between an exchange
            -- computed against the real baseline and one computed against 1000.
            for _, entry in ipairs(record.entries) do loadCareer(entry.identifier) end
            applyRating(record)
            local ok, reason = commit(record)
            if ok then
                settle(record)
                log(("wrote instance %s round %s (%s) -- %d player(s)"):format(
                    tostring(record.instanceId), tostring(record.roundId),
                    record.mode, #record.entries))
            elseif reason == "degraded" then
                -- No durable store this run. The write still HAPPENED, into the
                -- volatile table, and the readout says which store answered.
                settle(record)
            else
                -- A TRANSIENT FAILURE LEAVES THE ROUND IN `pending`, untouched
                -- and still first, and stops the drain. It is retried when the
                -- next round is recorded or when the resource next starts.
                -- Spinning here would hammer a database that is already
                -- unhappy, and dropping it would lose a round somebody played.
                log(("write failed for instance %s round %s (%s) -- kept, retried at the next round"):format(
                    tostring(record.instanceId), tostring(record.roundId), tostring(reason)))
                carry()
                return
            end
            for index = #pending, 1, -1 do
                if pending[index] == record then table.remove(pending, index) end
            end
            carry()
        end
    end
end


-- ------------------------------------------------------------ the write --

local function announceWrite(record, eligible)
    -- ONE event per round, broadcast, carrying no name and no identifier.
    --
    -- Decision 12 says the exclusion is at the WRITE and never at the read, and
    -- a rule that leaves no trace is a rule nobody can check. This is the
    -- trace: every ladder write this mode performs is announced, so "a bot
    -- round produced none" is an observation rather than an article of faith --
    -- and the all-human control round proves the announcement is not simply
    -- never wired.
    --
    -- The payload is the ROUND, not the career: participant ids and the numbers
    -- from the standings the players just read. The career KEY -- the
    -- master-backed identifier -- is deliberately not in it, because this
    -- crosses the wire to clients.
    local rows = {}
    for _, entry in ipairs(record.entries) do
        rows[#rows + 1] = {
            id = entry.playerId,
            kills = entry.kills, deaths = entry.deaths, assists = entry.assists,
            headshots = entry.headshots, multiKills = entry.multiKills,
            bestStreak = entry.bestStreak, score = entry.score, damage = entry.damage,
            won = entry.won == true,
            identified = entry.identifier ~= nil,
        }
    end
    TriggerClientEvent("deathmatch:ladderWrite", -1, {
        instanceId = record.instanceId,
        roundId = record.roundId,
        mode = record.mode,
        reason = record.reason,
        at = record.at,
        storage = storageLine(),
        ranked = eligible,
        rows = rows,
    })
end

--- Record one finished round. THE ONE ENTRY POINT, called by `round.lua` at the
--- end of a free-for-all round and by `arena.lua` when a match resolves.
---
--- Returns `ranked (boolean), reason`. `false, "bots"` is the decision-12 path
--- and is the reason the caller writes into `result.ranked`.
---
--- Everything here is SYNCHRONOUS and cheap: it walks the standings the round
--- has already computed and hands the result to the worker. No statement is
--- issued on this call stack, so nothing in a round-end path waits on a
--- database, and a database that is slow or down cannot hold up the next round.
function Ranked.recordRound(instance, opts)
    opts = type(opts) == "table" and opts or {}
    if instance == nil then return false, "no_instance" end
    if not enabled() then return false, "disabled" end

    -- ================================================================
    -- DECISION 12, AT THE WRITE. FIRST, BEFORE ANYTHING IS EVEN READ.
    -- ================================================================
    -- Not a flag on a row, not a column, not a filter for a later query to
    -- remember: a round containing a bot produces no snapshot, no queue entry,
    -- no announcement and no statement. There is nothing left behind to forget
    -- about. `ladderEligible` AND-s two independent sticky taints and both fail
    -- closed, so losing either file mid-round refuses the write rather than
    -- launders it.
    local scoring = scoringModule()
    if scoring == nil or type(scoring.ladderEligible) ~= "function" then
        return false, "no_scoring"
    end
    if scoring.ladderEligible(instance) ~= true then
        return false, "bots"
    end

    local mode = tostring(instance.format or "ffa")
    local rows = scoring.rows(instance)
    local winners = type(opts.winners) == "table" and opts.winners or nil
    local winnerId = DM.playerId(opts.winnerId)

    local record = {
        instanceId = math.floor(tonumber(instance.id) or 0),
        roundId = math.floor(tonumber(opts.roundId) or 0),
        mode = mode,
        reason = tostring(opts.reason or "resolved"),
        at = DM.nowMs(),
        entries = {},
        -- WHICH SIDE WON, for the rating's two-sided model. Taken from
        -- `opts.winnerSide` -- what `arena.lua` actually decided -- rather than
        -- inferred from the `won` flags below, because a side whose every member
        -- is a bot or is unkeyable produces no `won` entry at all and would then
        -- read as a draw. The inference is kept only as the fallback for a
        -- caller that does not name a side; a free-for-all names none and does
        -- not use this.
        winnerTeam = nil,
    }
    local declaredSide = math.floor(tonumber(opts.winnerSide) or 0)
    if declaredSide == 1 or declaredSide == 2 then record.winnerTeam = declaredSide end

    for _, row in ipairs(rows) do
        -- HUMANS ONLY, and the guard is `> 0` rather than `not row.bot`: a bot
        -- is a participant with a negative id, and the id is the thing that
        -- must never reach `Open77.players.identifier`.
        local playerId = DM.playerId(row.id)
        if playerId ~= nil then
            local won = false
            if winners ~= nil then won = winners[playerId] == true
            elseif winnerId ~= nil then won = (playerId == winnerId) end
            record.entries[#record.entries + 1] = {
                playerId = playerId,
                -- Captured at round start and on connect, because
                -- `Open77.players.identifier` answers nil for a player who has
                -- already gone -- and a forfeit is exactly the result that most
                -- needs recording.
                identifier = identities[playerId] or rememberIdentity(playerId),
                kills = math.floor(tonumber(row.kills) or 0),
                deaths = math.floor(tonumber(row.deaths) or 0),
                assists = math.floor(tonumber(row.assists) or 0),
                headshots = math.floor(tonumber(row.headshots) or 0),
                multiKills = math.floor(tonumber(row.multiKills) or 0),
                bestStreak = math.floor(tonumber(row.bestStreak) or 0),
                score = math.floor(tonumber(row.score) or 0),
                damage = math.floor(tonumber(row.damage) or 0),
                rounds = 1,
                wins = won and 1 or 0,
                won = won,
                -- The scoreboard's own team integer, set by `DM.setTeam` at
                -- every arena round start and 0 in a free-for-all. It is what
                -- the two-sided model splits on, so the rating and the coloured
                -- names on the HUD can never disagree about who was on whose
                -- side.
                team = math.floor(tonumber(row.team) or 0),
            }
            if won and record.winnerTeam == nil then
                local team = math.floor(tonumber(row.team) or 0)
                if team == 1 or team == 2 then record.winnerTeam = team end
            end
        end
    end

    if #record.entries == 0 then
        return false, "no_players"
    end

    -- The announcement is the round's, and it goes out whether or not any of
    -- those players could be keyed -- an eligible round that nothing could be
    -- attributed to is still a round the ladder saw, and saying so is what
    -- separates "no identity" from "not wired".
    announceWrite(record, true)

    -- The career the player can read updates NOW, from the same numbers. The
    -- durable copy follows on the worker.
    local keyed = {}
    for _, entry in ipairs(record.entries) do
        if entry.identifier ~= nil then
            local slot = modeSlot(careerFor(entry.identifier), mode)
            for _, field in ipairs(SUM_FIELDS) do
                slot.session[field] = (slot.session[field] or 0)
                    + math.floor(tonumber(entry[field]) or 0)
            end
            slot.session.bestStreak = math.max(slot.session.bestStreak or 0, entry.bestStreak)
            keyed[#keyed + 1] = entry
        end
    end

    if #keyed == 0 then
        log(("instance %d round %d (%s) eligible but no player could be identified -- nothing to key a career on")
            :format(record.instanceId, record.roundId, mode))
        return true, "unidentified"
    end

    record.entries = keyed
    pending[#pending + 1] = record
    local ceiling = math.floor(tonumber(setting("maxPendingRounds")) or 128)
    while #pending > ceiling do
        table.remove(pending, 1)
        log("pending write queue overflowed -- oldest round dropped")
    end
    carry()
    enqueue({ kind = "commit", record = record })
    return true, "queued"
end

--- Called by round.lua / arena.lua at round start. Two jobs: capture every
--- present player's identity while they are certainly present, and warm the
--- career cache so a round end is a computation rather than a round trip.
function Ranked.onRoundStart(instance)
    if instance == nil or not enabled() then return end
    local registry = DM.instances
    if type(registry) ~= "table" then return end
    local roster = type(registry.humans) == "function"
        and registry.humans(instance) or registry.members(instance)
    for _, playerId in ipairs(roster or {}) do
        Ranked.warm(playerId)
        Ranked.greet(playerId)
    end
end

--- Capture identity and queue a load. Idempotent and safe for a bot id.
function Ranked.warm(playerId)
    if not enabled() then return nil end
    local identifier = rememberIdentity(playerId)
    if identifier == nil then return nil end
    local record = careerFor(identifier)
    if record.loaded or record.requested then return identifier end
    record.requested = true
    enqueue({ kind = "load", identifier = identifier })
    return identifier
end


-- ------------------------------------------------------------- the readout --

local function totalsFor(identifier)
    local record = careers[identifier]
    local perMode, overall, ratings = {}, blankTotals(), {}
    if record == nil then return perMode, overall, false, ratings end
    local settings = ratingSettings()
    for mode, slot in pairs(record.modes) do
        local totals = combine(slot.stored, slot.session)
        -- A mode is shown when it has a career OR a rating. The two can come
        -- apart in both directions -- a rating adopted across a reload with no
        -- rounds behind it in this VM, and a round recorded on a server that has
        -- rating switched off -- and hiding either half would make the card
        -- disagree with the table.
        local rated = slot.rating ~= nil or (slot.ratingRounds or 0) > 0
            or (slot.ratingPending or 0) ~= 0
        if totals.rounds > 0 or totals.kills > 0 or totals.deaths > 0 or rated then
            perMode[mode] = totals
            ratings[mode] = {
                rating = settings ~= nil and ratingValue(slot, settings) or slot.rating,
                rounds = slot.ratingRounds or 0,
                peak = slot.peak,
                lastDelta = slot.lastDelta or 0,
                established = slot.rating ~= nil,
                provisional = settings ~= nil
                    and (slot.ratingRounds or 0) < (settings.provisionalRounds or 0),
            }
            for _, field in ipairs(SUM_FIELDS) do
                overall[field] = overall[field] + totals[field]
            end
            overall.bestStreak = math.max(overall.bestStreak, totals.bestStreak)
        end
    end
    return perMode, overall, record.loaded, ratings
end

--- The career of one player, or nil. Published so the HUD or another file can
--- read it without knowing the storage.
function Ranked.careerOf(playerId)
    local identifier = identities[DM.playerId(playerId) or -1] or identifierOf(playerId)
    if identifier == nil then return nil end
    local perMode, overall, loaded, ratings = totalsFor(identifier)
    return {
        modes = perMode, overall = overall, loaded = loaded,
        ratings = ratings, storage = storageLine(),
    }
end

-- K/D is the number players argue about, so the convention has to be stated:
-- zero deaths is NOT infinity, it is the kill count -- the same rule every
-- shooter uses -- and a career with no rounds at all reads 0.00 rather than
-- nan, which is what a bare division produces and what would then be printed.
local function ratio(kills, deaths)
    if deaths <= 0 then return kills * 1.0 end
    return kills / deaths
end
Ranked.ratio = ratio

local function report(say, playerId, identifier)
    local perMode, overall, loaded, ratings = totalsFor(identifier)
    local name = playerId ~= nil and DM.playerName(playerId) or "?"

    say(("career %s -- storage: %s%s"):format(
        name, storageLine(), loaded and "" or "  (not loaded yet)"))
    if overall.rounds == 0 and overall.kills == 0 and overall.deaths == 0 then
        -- The baseline is said even here -- ESPECIALLY here. This is the card a
        -- player reads before their first round, and "you start at 1000" is the
        -- one thing it can honestly tell them.
        local blankSettings = ratingSettings()
        local blankModule = ratingModule()
        if blankSettings ~= nil and blankModule ~= nil
            and type(blankModule.describe) == "function" then
            local ok, line = pcall(blankModule.describe, blankSettings)
            if ok and type(line) == "string" then say("  rating -- " .. line) end
        end
        return say("  no rounds recorded yet")
    end
    say(("  rounds %d  wins %d  kills %d  deaths %d  K/D %.2f  assists %d"):format(
        overall.rounds, overall.wins, overall.kills, overall.deaths,
        ratio(overall.kills, overall.deaths), overall.assists))
    say(("  headshots %d  multi-kills %d  best streak %d  score %d  damage %d"):format(
        overall.headshots, overall.multiKills, overall.bestStreak,
        overall.score, overall.damage))

    -- THE RATING IS PER FORMAT AND THERE IS NO OVERALL ONE, deliberately. Plan
    -- section 10: a 1v1 rating means nothing about a twelve-player free-for-all,
    -- and the two are not even measured by the same model -- an arena rating is
    -- a two-sided exchange, a free-for-all rating is a pairwise placement. An
    -- average of the two would be a number with no definition at all.
    --
    -- The parameters are printed rather than hidden, because a rating whose
    -- baseline and K nobody can see is a magic number with a database behind it,
    -- and the first question a player asks about a rating is what the numbers
    -- mean.
    local settings = ratingSettings()
    local module = ratingModule()
    if settings ~= nil and module ~= nil and type(module.describe) == "function" then
        local ok, line = pcall(module.describe, settings)
        if ok and type(line) == "string" then say("  rating -- " .. line) end
    end

    -- Per format, because a 1v1 rating means nothing about a 12-player
    -- free-for-all (plan section 10) and an aggregate that hides the split
    -- would be the number that means neither.
    local modes = {}
    for mode in pairs(perMode) do modes[#modes + 1] = mode end
    table.sort(modes)
    for _, mode in ipairs(modes) do
        local totals = perMode[mode]
        local rated = ratings[mode]
        -- `*` is "provisional" -- still inside the placement window, where K is
        -- scaled up and the number is a guess rather than evidence. `?` is a
        -- format with no rated round at all, so what is shown is the baseline
        -- and not a measurement. Saying so is cheap; a player reading 1000 and
        -- believing it was earned is not.
        local elo, mark = "     ", ""
        if rated ~= nil and rated.rating ~= nil then
            elo = ("%5d"):format(rated.rating)
            if rated.rounds <= 0 then mark = "?"
            elseif rated.provisional then mark = "*" end
        end
        say(("  %-4s elo %s%-1s rounds %-4d wins %-4d k=%-5d d=%-5d K/D %.2f  hs=%-4d multi=%-3d best=%d"):format(
            mode, elo, mark, totals.rounds, totals.wins, totals.kills, totals.deaths,
            ratio(totals.kills, totals.deaths), totals.headshots,
            totals.multiKills, totals.bestStreak))
        if rated ~= nil and rated.rounds > 0 then
            say(("        rated rounds %d  peak %d  last %+d%s"):format(
                rated.rounds, rated.peak or rated.rating, rated.lastDelta,
                rated.provisional and "  (provisional: K is scaled up until the placement window closes)" or ""))
        end
    end
    local queued = 0
    for _, record in ipairs(pending) do
        for _, entry in ipairs(record.entries) do
            if entry.identifier == identifier then queued = queued + 1 end
        end
    end
    if queued > 0 then
        say(("  %d round(s) recorded and not yet written -- the numbers above already include them"):format(queued))
    end
end

local function sayer(source, raw)
    return function(text)
        print(text)
        if source ~= nil and source > 0 then
            TriggerClientEvent("open77:command:result", source, raw or "", true, text)
        end
    end
end

--- `/dm.stats` -- your own career. UNRESTRICTED: reading your own record is the
--- feature, not an operator verb, exactly as `/guns` is.
---
--- The `<id>` form is deliberately NOT here. `RegisterCommand`'s third argument
--- is the whole ACL gate and it is per-COMMAND, not per-invocation -- there is
--- no binding that lets an unrestricted handler ask whether its caller is
--- privileged. Registering one command that takes an id would therefore either
--- expose everybody's card to everybody, or hide everybody's from themselves.
--- The mode already answers this with a PAIR (`dm.arena` / `dm.arena.mock`,
--- `dm.where` / `dm.survey`), so this follows: `/dm.stats.of <id>` below is the
--- restricted half. The server console is privileged by definition and gets the
--- id form here as well, so an operator at the console never needs the pair.
RegisterCommand("dm.stats", function(source, args, raw)
    local say = sayer(source, raw)
    if not enabled() then return say("career stats are disabled in this server's config") end

    local wanted = DM.finite(args and args[1])
    if wanted ~= nil and (source == nil or source <= 0) then
        local playerId = DM.playerId(wanted)
        if playerId == nil then return say("dm.stats -- give a positive player id") end
        local identifier = Ranked.warm(playerId)
        if identifier == nil then
            return say(("career player=%d -- no identity (not connected, or this server has no master-backed identity for them)")
                :format(playerId))
        end
        return report(say, playerId, identifier)
    end
    if wanted ~= nil then
        return say("dm.stats reads your own career. /dm.stats.of <id> reads somebody else's and is ACL-gated.")
    end

    local playerId = DM.playerId(source)
    if playerId == nil then
        say("usage: dm.stats                 -- your own career, in game")
        say("       dm.stats <playerId>      -- from the server console")
        return say("       dm.stats.of <playerId>   -- in game, ACL-gated")
    end
    local identifier = Ranked.warm(playerId)
    if identifier == nil then
        return say("career -- this server has no master-backed identity for you, so nothing is being recorded. "
            .. storageLine())
    end
    report(say, playerId, identifier)
end, false)

--- `/dm.rating.sim <mode> <rating> <rating> [...]` -- what the model would do to
--- a synthetic field, WITHOUT touching a single stored row.
---
--- It exists for the same reason `/dm.arena.mock` does: the arithmetic that
--- decides a rating is otherwise only observable by playing a round and then
--- reading a table, which is a slow way to answer "why did I lose 12 points" and
--- an impossible way to answer "what would a K of 24 do". Ratings are given best
--- first, so the field is assumed to have finished in the order typed; a
--- two-sided format splits the list down the middle and side 1 wins.
---
--- ACL-gated, not because it can do harm -- it cannot, it computes and prints --
--- but because the answer is a tuning question and the pair `/dm.stats` /
--- `/dm.stats.of` has already set the convention for which half of a readout is
--- an operator verb.
RegisterCommand("dm.rating.sim", function(source, args, raw)
    local say = sayer(source, raw)
    local module = ratingModule()
    if module == nil then return say("rating -- server/rating.lua is not loaded") end
    local settings = ratingSettings()
    if settings == nil then return say("rating -- settings unreadable") end

    local mode = tostring((args and args[1]) or "ffa")
    local values = {}
    for index = 2, #(args or {}) do
        local value = DM.finite(args[index])
        if value == nil then
            return say(("dm.rating.sim -- '%s' is not a number"):format(tostring(args[index])))
        end
        values[#values + 1] = math.floor(value)
    end
    if #values < 2 then
        say("usage: dm.rating.sim <mode> <rating> <rating> [...]   -- best finisher first")
        return say("       modes: ffa, 1v1, 2v2, 3v3.  A two-sided format splits the list in half; side 1 wins.")
    end

    local twoSided = module.isTwoSided(mode)
    local half = math.floor(#values / 2)
    local participants = {}
    for index, rating in ipairs(values) do
        participants[#participants + 1] = {
            key = ("sim-%02d"):format(index),
            rating = rating,
            rounds = settings.provisionalRounds,   -- settled, so the base K is what is shown
            -- The finishing order IS the order typed: a strictly descending kill
            -- count makes every pairwise outcome decisive and leaves nothing to
            -- the second and third tiebreaks.
            kills = #values - index,
            deaths = 0,
            score = 0,
            team = twoSided and (index <= half and 1 or 2) or 0,
        }
    end

    local results, model, note = module.round(mode, participants,
        { winnerTeam = twoSided and 1 or nil, settings = settings })
    if results == nil then
        return say(("rating sim %s -- NOT RATED (%s)"):format(mode, tostring(note or model)))
    end

    say(("rating sim %s model=%s field=%d %s"):format(
        mode, tostring(model), #values, module.describe(settings)))
    local total = 0
    for _, result in ipairs(results) do
        total = total + result.delta
        say(("  %s place=%d side=%d rating=%d k=%.1f expected=%.3f actual=%.3f delta=%+d after=%d"):format(
            result.key, result.place or 0, result.team or 0, result.before, result.k,
            result.expected, result.actual, result.delta, result.after))
    end
    -- The books, printed. Every model here is zero-sum before rounding, so a
    -- total that is not within half a point per player is a bug in the model
    -- rather than a rounding artefact.
    say(("  sum of deltas = %+d (zero-sum before rounding; the floor and the "
        .. "provisional K are the only two things allowed to move it)"):format(total))
end, true)

--- The restricted half of the pair. ACL-gated by `RegisterCommand`'s third
--- argument, which is the whole gate.
RegisterCommand("dm.stats.of", function(source, args, raw)
    local say = sayer(source, raw)
    if not enabled() then return say("career stats are disabled in this server's config") end
    local playerId = DM.playerId(DM.finite(args and args[1]))
    if playerId == nil then return say("usage: dm.stats.of <playerId>") end
    local identifier = Ranked.warm(playerId)
    if identifier == nil then
        return say(("career player=%d -- no identity for that id"):format(playerId))
    end
    report(say, playerId, identifier)
end, true)


-- ---------------------------------------------------------------- lifecycle --

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = DM.playerId(playerIdStr)
    if playerId == nil then return end
    connected[playerId] = true
    Ranked.warm(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = DM.playerId(playerIdStr)
    if playerId == nil then return end
    connected[playerId] = nil
    announced[playerId] = nil
    -- The identity snapshot is kept deliberately for one more moment: a round
    -- resolving on the forfeit this disconnect just caused still has to be able
    -- to attribute the leaver. It is dropped once the queue no longer needs it.
    SetTimeout(30000, function()
        local stillHere = false
        for _, record in ipairs(pending) do
            for _, entry in ipairs(record.entries) do
                if entry.playerId == playerId then stillHere = true end
            end
        end
        if not stillHere and connected[playerId] == nil then identities[playerId] = nil end
    end)
end)

--- One career line per session, never a nag, and never after a Lua save.
---
--- Called from the round layer once the player is actually in a fight, so the
--- card is not printed over a loading screen.
function Ranked.greet(playerId)
    if not enabled() or setting("announceOnJoin") == false then return false end
    playerId = DM.playerId(playerId)
    if playerId == nil or announced[playerId] then return false end
    if not connected[playerId] then
        -- A RELOAD SURVIVOR. `announced` died with the outgoing VM and
        -- `connected` is empty for exactly the same reason; the two absences
        -- cancel. Mark them greeted and stay silent -- a Lua save must not put
        -- a career card in front of somebody who is mid-fight.
        announced[playerId] = true
        return false
    end
    announced[playerId] = true
    local identifier = identities[playerId]
    if identifier == nil then return false end
    local _, overall = totalsFor(identifier)
    if overall.rounds <= 0 then return false end
    DM.notice(playerId, "info", "careerWelcome",
        overall.kills, overall.deaths, ratio(overall.kills, overall.deaths), overall.rounds)
    return true
end

--- Say out loud that a round did not count. A silent exclusion is
--- indistinguishable from a broken ladder to a player who just went 20-3 --
--- bots.lua has carried the sentence since Phase 3 and nothing spoke it.
function Ranked.announceExclusion(instance)
    if not enabled() or setting("announceExclusion") == false then return false end
    if instance == nil then return false end
    local module = botsModule()
    if module == nil or type(module.ladderNotice) ~= "function" then return false end
    local ok, message = pcall(module.ladderNotice, instance.id)
    if not ok or type(message) ~= "string" then return false end
    local registry = DM.instances
    if type(registry) ~= "table" then return false end
    local roster = type(registry.humans) == "function"
        and registry.humans(instance) or registry.members(instance)
    for _, playerId in ipairs(roster or {}) do
        -- `DM.notice` already refuses a non-positive id, but the roster is
        -- humans-first for the same reason `toInstance` is: a bot has no client.
        if DM.playerId(playerId) ~= nil then
            TriggerClientEvent("deathmatch:notice", playerId, {
                kind = "info",
                title = Config.strings.title,
                message = message,
            })
        end
    end
    return true
end

--- Operator readout, and the answer to "is anything being written at all".
function Ranked.describe()
    local identities_ = 0
    for _ in pairs(careers) do identities_ = identities_ + 1 end
    local queuedRounds = #pending
    local rating = "rating module ABSENT"
    local module = ratingModule()
    if module ~= nil and type(module.describe) == "function" then
        local ok, line = pcall(module.describe)
        if ok and type(line) == "string" then rating = line end
    end
    return ("%s -- %d identity(ies) cached, %d round(s) awaiting a write, %d job(s) queued; rating: %s")
        :format(storageLine(), identities_, queuedRounds, #jobs, rating)
end

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    if not enabled() then return log("DISABLED in config") end
    adopt()
    CreateThread(function()
        ensureSchema()
        log("ready -- career stats per identity per format; " .. storageLine())
        -- Anything adopted from the outgoing VM is written now rather than
        -- waiting for the next round to end.
        for _, record in ipairs(pending) do
            enqueue({ kind = "commit", record = record })
        end
    end)
end)
