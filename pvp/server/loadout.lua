-- Kabuki Arena -- loadouts: issue, VERIFY, resupply.
--
-- M10 of server/instances.lua: `equipWeapon`, `stripWeapons`,
-- `normalizeWeaponId`, `weaponRequests` and the `open77:weapons:completed`
-- handler leave main.lua and land here. The main.lua edits that go with this
-- file are listed in the anchored block at the top of server/scoring.lua, with
-- everything else main.lua has to change; there is one list, not two.
--
-- Three slots now, where the shipped mode issued one and left the other two
-- empty (plan section 7):
--
--   FFA    slot 1 the rotating equalizer, slot 2 the fixed sidearm, slot 3 the
--          melee. All three from `Config.equalizer`. `Config.weapons` no longer
--          exists; the rotation is `Config.equalizer.rotation`.
--   Arena  the kit picked in the buy window, from `Config.kits`. Identical list
--          for both teams -- the choice is the player's, the catalogue is not.
--
-- ===========================================================================
-- THE HANDSHAKE IS ASYNCHRONOUS AND THAT IS THE WHOLE POINT
-- ===========================================================================
-- `Open77.weapons.assign` does not equip a weapon. It returns a REQUEST ID and
-- the verdict arrives later, on `open77:weapons:completed`, carrying the
-- `tweakDbId` the client actually ended up holding. That verified id -- not the
-- record we asked for -- is what the damage arbiter matches a reported shot
-- against.
--
-- The consequence is the security property of the whole mode and it is worth
-- stating plainly: A PLAYER WHOSE WEAPON NEVER VERIFIED CANNOT LAND DAMAGE.
-- `instance.weaponIds[playerId]` stays nil, the arbiter's
-- `weapon_not_verified` branch refuses every shot, and bots.lua's
-- `verifiedWeaponId` hook -- which reads the same table -- refuses the
-- player -> bot path for the same reason. Failing to write that table is
-- therefore FAIL CLOSED, which is why nothing here ever guesses an id from the
-- record it requested.
--
-- Four things the shipped handshake got right and that are preserved verbatim:
--
--   1. THE 250 ms GAP between removing the old weapons and assigning the new
--      ones. The removals are themselves asynchronous; assigning into a slot
--      still being torn down loses the assignment silently.
--   2. THE VERSION PER PLAYER. Every issue and every strip bumps it, and a
--      completion whose version no longer matches is DROPPED. Without it a
--      verdict from the previous round -- an assign that took a second while
--      the round rolled over -- writes a stale TweakDBID into the current
--      round's arbiter table, and the player's real weapon stops registering.
--   3. THE NORMALISED "0x..." FORM. TweakDB ids are 64-bit hashes and a Lua
--      number holds 53 integer bits, so the canonical form is a lowercase hex
--      string with leading zeroes stripped. Comparing an unnormalised id
--      against a normalised one never matches, and the failure looks exactly
--      like a cheater.
--   4. THE REQUEST IS KEYED BY `tostring(requestId)`. Request ids cross as
--      strings; a numeric key and a string key are different table entries.
--
-- ===========================================================================
-- MEASURED, AND LOAD-BEARING: RESERVE ONLY. NEVER A MAGAZINE.
-- ===========================================================================
-- `Open77.weapons.setAmmo` fails AS A WHOLE when `magazine` exceeds the
-- weapon's capacity. Measured 2026-08-31 and recorded in
-- docs/research/pvp-arena-and-bots.md: a Lexington given
-- `{ reserve = 300, magazine = 60 }` left the counter at `000 0000` -- not a
-- clamped magazine with a good reserve, NOTHING -- while the same call as
-- `{ reserve = 300 }` produced `000 0300` immediately.
--
-- The failure is silent and it looks like a weapon bug rather than an ammo
-- bug, so `ammoOptions` below is the ONE place ammunition options are built and
-- it drops a `magazine` key with a loud log rather than passing it through. Do
-- not add one back "just for the pistol"; capacity is per weapon and this file
-- does not know it.
--
-- Ammunition is also RESUPPLIED at round rollover and on respawn
-- (`Config.equalizer.resupplyOnRoundStart` / `resupplyOnRespawn`). The shipped
-- mode issued the reserve once, so a player who survived a long round simply
-- ran dry -- with no message, which reads as a broken gun.
--
-- ===========================================================================
-- STATE
-- ===========================================================================
-- Several instances run at once, so the loadout book lives ON THE INSTANCE
-- (`instance.loadout`) and never in a module table. Two exceptions, both
-- deliberate:
--
--   * `versions[playerId]` -- a monotonic per-player counter. It has to outlive
--     instance membership, because the stale completion it exists to reject is
--     exactly the one that arrives after the player left the instance that
--     issued it. A player is in one instance at a time, so it cannot leak
--     across instances.
--   * `pending[requestId]` -- the in-flight request registry. A request id is
--     server-wide, and the completion handler is handed nothing but that id, so
--     the lookup cannot be per instance. Every entry CARRIES its instance id
--     and is checked against the player's current instance before it applies.
-- ===========================================================================

Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig

DM.loadout = DM.loadout or {}
local Loadout = DM.loadout

-- See the header: monotonic per player, and pending keyed by request id.
local versions = {}
local pending = {}

-- A completion that never arrives would leak its pending entry. The platform
-- times a request out at ten seconds; this is the backstop for the case where
-- even the timeout is lost.
local PENDING_TTL_MS = 15000

local function instances()
    local registry = DM.instances
    if type(registry) ~= "table" then return nil end
    return registry
end

local function instanceOf(playerId)
    local registry = instances()
    if registry == nil then return nil end
    return registry.of(playerId)
end


-- ------------------------------------------------------------- identifiers --

-- TweakDB ids are 64-bit hashes and a Lua number holds 53 integer bits, so the
-- canonical form everywhere is a lowercase "0x..." string with leading zeroes
-- stripped. Carried over from main.lua UNCHANGED: the arbiter compares two
-- strings, and a difference in spelling is indistinguishable from a cheat.
function Loadout.normalizeWeaponId(value)
    if type(value) ~= "string" then return "" end
    local digits = string.lower(value):match("^0x([0-9a-f]+)$")
    if digits == nil then return "" end
    digits = digits:gsub("^0+", "")
    if digits == "" then return "" end
    return "0x" .. digits
end

local normalizeWeaponId = Loadout.normalizeWeaponId


-- ------------------------------------------------------------------- book --

-- Per instance, created lazily so an instance adopted after a hot reload grows
-- one on its first issue rather than needing the kernel to know about this file.
local function book(instance)
    if instance == nil then return nil end
    local entry = instance.loadout
    if entry == nil then
        entry = {
            plans = {},          -- playerId -> the slot plan last issued
            sets = {},           -- playerId -> slot -> verified "0x..." id
            kits = {},           -- playerId -> kit key chosen in the buy window
            rotationIndex = 0,   -- FFA equalizer cursor, PER INSTANCE
            weapon = nil,        -- the entry the current round is being played with
        }
        instance.loadout = entry
    end
    return entry
end

function Loadout.version(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return 0 end
    return versions[playerId] or 0
end

local function bumpVersion(playerId)
    local value = (versions[playerId] or 0) + 1
    versions[playerId] = value
    return value
end


-- --------------------------------------------------------------- rotation --

-- Round-robin rather than random: with two or more entries this guarantees that
-- consecutive rounds never receive the same weapon, which random does not.
-- The cursor is on the INSTANCE, so two instances rotate independently -- the
-- shipped mode's `lastWeaponIndex` was a file-scope upvalue and would have made
-- every instance share one rotation.
function Loadout.rotate(instance)
    local rotation = Config.equalizer.rotation
    if type(rotation) ~= "table" or #rotation == 0 then return nil end
    local entry = book(instance)

    -- UNDER `mode = "choice"` THERE IS NO ROUND WEAPON, and saying so is the
    -- whole of it. round.lua stores this return as `round.weapon`, and that one
    -- field feeds two player-facing claims: the "%s -- same weapon for
    -- everyone" notice a joiner receives, and the SHARED WEAPON card on the
    -- match band. Both would name a rotation entry that nobody in the instance
    -- is carrying. A nil suppresses both at once, and the band is repainted
    -- from `deathmatch:loadout` below with what the player actually holds.
    --
    -- The CURSOR is left exactly where it was, deliberately: flipping the
    -- `loadoutMode` tunable back to "equalizer" mid-session resumes the
    -- rotation rather than restarting it. `Loadout.mode()` is called rather
    -- than the `choosable` local because that local is declared further down
    -- this file; the instance is always free-for-all here, since round.lua is
    -- the only caller and it runs on nothing else.
    if Loadout.mode() == "choice" and #Loadout.primaries() > 0 then
        if entry ~= nil then entry.weapon = nil end
        return nil
    end

    if entry == nil then return rotation[1] end
    entry.rotationIndex = (entry.rotationIndex % #rotation) + 1
    entry.weapon = rotation[entry.rotationIndex]
    return entry.weapon
end

-- The weapon THIS ROUND is being played with. round.lua owns the round and may
-- publish its choice as `instance.round.weapon`; that wins. Otherwise the
-- instance's own cursor answers, rotating once on the very first call so a
-- loadout issued before any round exists is still a real weapon rather than nil.
--
-- It never rotates on a normal read: every player in an instance must receive
-- the SAME equalizer, which is the entire idea (decision 14).
function Loadout.weapon(instance)
    local round = instance ~= nil and instance.round or nil
    if type(round) == "table" and type(round.weapon) == "table" then
        return round.weapon
    end
    local entry = book(instance)
    if entry == nil then return Config.equalizer.rotation[1] end
    if entry.weapon == nil then return Loadout.rotate(instance) end
    return entry.weapon
end


-- ------------------------------------------------------------------- kits --

-- The buy list, for the arena buy-window UI and for the `/guns` picker. Records
-- are NOT sent: a client has no use for a TweakDB record and publishing one
-- invites it to ask for another.
--
-- `weapons` is the one addition the picker needed, and it is labels rather than
-- records for exactly that reason. "Sniper" on its own is not a choice -- a
-- player picking a kit has to see what is in it -- and every label here already
-- appears in the kill feed, so nothing new is published. They resolve through
-- `labelForRecord`, which reads the same catalogue the feed does, so a kit and
-- its own kill lines can never name a weapon differently.
function Loadout.kitList()
    local out = {}
    for _, kit in ipairs(Config.kits.list) do
        local weapons = {}
        for _, line in ipairs(kit.slots or {}) do
            weapons[#weapons + 1] = Loadout.labelForRecord(line.record) or tostring(line.record)
        end
        out[#out + 1] = { key = kit.key, label = kit.label, weapons = weapons }
    end
    return out
end

local function kitByKey(key)
    for _, kit in ipairs(Config.kits.list) do
        if kit.key == key then return kit end
    end
    return nil
end

function Loadout.kitFor(instance, playerId)
    playerId = DM.playerId(playerId)
    local entry = book(instance)
    local chosen = (entry ~= nil and playerId ~= nil) and entry.kits[playerId] or nil
    return kitByKey(chosen) or kitByKey(Config.kits.default) or Config.kits.list[1]
end

-- The buy window's write. Returns ok, reason. It records the CHOICE only; the
-- weapons are issued when the round starts, by arena.lua calling `issue`.
function Loadout.chooseKit(playerId, kitKey)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false, "bad_player_id" end
    local instance = instanceOf(playerId)
    if instance == nil then return false, "not_in_instance" end
    if instance.kind ~= "arena" then return false, "not_an_arena_instance" end
    local kit = kitByKey(tostring(kitKey))
    if kit == nil then return false, "unknown_kit" end
    book(instance).kits[playerId] = kit.key
    return true, kit.key
end

-- The buy window is arena.lua's; the CHOICE is a loadout fact, so the write
-- lands here. Registered from this file rather than wired, so a kit pick works
-- the moment the HUD grows the panel.
RegisterNetEvent("deathmatch:pickKit", function(kitKey)
    local playerId = DM.playerId(source)
    if playerId == nil then return end
    local ok, reason = Loadout.chooseKit(playerId, kitKey)
    if not ok and Config.debug.verboseDamage then
        DM.log(("kit pick refused player=%d reason=%s"):format(playerId, tostring(reason)))
    end
end)


-- ---------------------------------------------------------------- arsenal --
--
-- THE CHOOSABLE PRIMARIES, and why they are not the kits above.
--
-- The `/guns` picker used to offer `Config.kits.list` -- four kits, which is
-- the ARENA buy list and was borrowed because it was the only weapon list in
-- this file. It now offers `Config.loadout.primaries`: every canonical firearm
-- of the 2.31 build, 49 of them, each one a row of
-- docs/generated/weapons-2.31.csv. The filter that selects them is written out
-- above the list in shared/config.lua so anyone can re-run it.
--
-- `kitList`, `kitByKey`, `kitFor` and `chooseKit` are UNTOUCHED. server/arena.lua
-- publishes `kitList()` into its buy-window fragment and reads `kitFor` for the
-- issued kit; the four kits are that window's catalogue and were never this
-- picker's problem. The only place the two lists still meet is `resolvePrimary`
-- below, which accepts a kit key as an alias so `/guns sniper` keeps working.

--- The arsenal, or the equalizer rotation if a server has no arsenal
--- configured. The fallback is not decoration: the rotation is the other list
--- of primaries in this mode, so an operator who empties `primaries` gets a
--- ten-weapon picker rather than a dead command.
---
--- A MODULE function rather than a file-local because `Loadout.rotate` -- which
--- is declared far above this line -- has to ask whether an arsenal exists.
--- That is the same reason `rotate` already calls `Loadout.mode()`.
function Loadout.primaries()
    local list = type(Config.loadout) == "table" and Config.loadout.primaries or nil
    if type(list) == "table" and #list > 0 then return list end
    return Config.equalizer.rotation
end

local function primaryByKey(key)
    if key == nil then return nil end
    key = tostring(key)
    for _, entry in ipairs(Loadout.primaries()) do
        if entry.key == key then return entry end
    end
    return nil
end

local function primaryByRecord(record)
    if record == nil then return nil end
    record = tostring(record)
    for _, entry in ipairs(Loadout.primaries()) do
        if entry.record == record then return entry end
    end
    return nil
end

--- The picker's payload: four fields a row, already in the order the panel
--- draws them.
---
--- RECORDS ARE NOT SENT -- the rule `kitList` already states: a client has no
--- use for a TweakDB record and publishing one invites it to ask for another.
--- `reserve` IS sent, and is the one field that had to be added: 60 rounds for
--- a Grad against 360 for a Defender is the difference between two picks, and a
--- player choosing on the name alone is choosing blind.
---
--- THE SORT HAPPENS HERE, not on the page, and the sort keys do not travel.
--- Category display order is a config fact (`Config.loadout.categories`); a
--- page that had to be told it would be a second place for it to be wrong, and
--- a page that had to be told it TWICE -- once as an order and once as a
--- per-row group index -- would be two. The panel starts a new heading whenever
--- `category` differs from the previous row, which needs nothing else.
--- A category the config forgot to list sorts last rather than vanishing.
function Loadout.primaryList()
    local order = {}
    local categories = type(Config.loadout) == "table" and Config.loadout.categories or nil
    if type(categories) == "table" then
        for index, name in ipairs(categories) do order[tostring(name)] = index end
    end

    local ranked = {}
    for index, entry in ipairs(Loadout.primaries()) do
        local category = tostring(entry.category or "")
        ranked[#ranked + 1] = {
            group = order[category] or math.huge,
            order = index,
            row = {
                key = entry.key,
                label = entry.label,
                category = category,
                reserve = DM.finite(entry.reserve),
            },
        }
    end
    table.sort(ranked, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.order < b.order
    end)

    local out = {}
    for _, item in ipairs(ranked) do out[#out + 1] = item.row end
    return out
end

--- The arena kit whose slot 1 is this weapon, or nil.
---
--- `/guns` has always meant one thing everywhere: a pick made while an arena
--- buy window is open is that window's pick too. With a 49-weapon arsenal and a
--- four-kit buy list that can only hold for the four weapons the arena actually
--- sells (Ajax, Saratoga, Carnage, Grad). For the other forty-five the arena
--- keeps its own default, which is the honest answer -- the buy list is the
--- arena's catalogue, not this picker's.
local function kitForPrimary(entry)
    if entry == nil or type(Config.kits) ~= "table" then return nil end
    for _, kit in ipairs(Config.kits.list or {}) do
        for _, line in ipairs(kit.slots or {}) do
            if math.floor(tonumber(line.slot) or 0) == 1 and line.record == entry.record then
                return kit.key
            end
        end
    end
    return nil
end

--- Lower-case, letters and digits only. "SPT32 Grad" -> "spt32grad", so a
--- player who types the name off the screen is understood.
local function slug(value)
    return (tostring(value or ""):lower():gsub("[^%w]", ""))
end

--- Resolve whatever a player typed or clicked to a primary. Three routes, in
--- order, and the last two are what keep the direct form usable at 49 entries:
---
---   1. the weapon key            /guns nekomata
---   2. an arena KIT key -- one of the four names /guns accepted before this
---      change. It resolves to that kit's own slot-1 weapon, so /guns sniper
---      still hands out a Grad and nobody's muscle memory broke.
---   3. the display label, slugged: /guns spt32grad, /guns sor22.
local function resolvePrimary(name)
    if name == nil then return nil end
    local wanted = tostring(name):lower()

    local entry = primaryByKey(wanted)
    if entry ~= nil then return entry end

    local kit = kitByKey(wanted)
    if kit ~= nil then
        for _, line in ipairs(kit.slots or {}) do
            if math.floor(tonumber(line.slot) or 0) == 1 then
                entry = primaryByRecord(line.record)
                if entry ~= nil then return entry end
            end
        end
    end

    local target = slug(wanted)
    if target ~= "" then
        for _, candidate in ipairs(Loadout.primaries()) do
            if slug(candidate.label) == target then return candidate end
        end
    end
    return nil
end


-- ============================================================ weapon choice --
--
-- `/guns` -- the free-for-all answer to "which gun do I get to play with".
--
-- ===========================================================================
-- THIS DOES NOT DELETE THE EQUALIZER, IT SWITCHES AGAINST IT
-- ===========================================================================
-- Decision 14 gives every player in a free-for-all instance the SAME weapon,
-- rotating each round, and it is the mode's clearest idea: fights stay readable
-- and nobody loses to a loadout. Per-player choice is in direct tension with
-- that, so the two are a SWITCH (`Config.loadout.mode`, with the `loadoutMode`
-- tunable in front of it) rather than a blend. Every line of the equalizer path
-- above and in round.lua is intact and is what `mode = "equalizer"` still runs,
-- rotation included. `choice` is the shipped default because it is what was
-- asked for; an operator flips it back live from the Warden panel.
--
-- The ARENA is not touched by this switch. Its formats declare
-- `loadout = "kit"` and it already has a buy window, so a mode flag that
-- silently rewrote them would be a second, invisible rule.
--
-- ===========================================================================
-- TWO STORES, AND THEY ARE DIFFERENT FACTS
-- ===========================================================================
--   `instance.loadout.kits[playerId]`  the ARENA buy-window pick. Per instance,
--                                      because a buy window belongs to a match.
--   `choices[playerId]`                the SESSION pick. Module scope, because
--                                      it has to outlive a respawn, a round
--                                      rollover AND the instance itself -- a
--                                      player who leaves a full instance and
--                                      lands in a fresh one is the same player
--                                      with the same preference.
--
-- `/guns` writes both: it means one thing everywhere, and `chooseKit` refuses
-- anywhere that is not an arena buy window, so the second write costs a
-- refusal and nothing else.
--
-- ===========================================================================
-- RECONNECT: DELIBERATELY NOT PERSISTED
-- ===========================================================================
-- `forget` drops the pick on disconnect, exactly as it drops `versions`. There
-- is no gamemode persistence layer yet (phase 8 is unstarted), so the
-- alternative is not "remember across sessions", it is "keep a table entry
-- keyed by a player id the platform is free to hand to somebody else". That is
-- not a missing feature, it is a bug that would silently arm a new arrival with
-- the last occupant's kit. The cost of the honest answer is one click: the
-- picker opens by itself on the reconnecting player's first round.
--
-- A HOT RELOAD loses the pick too, along with `versions`, the instance round
-- and everything else this VM holds. It does NOT re-prompt -- see
-- `maybePrompt` -- so a Lua save stays silent, which is the half that matters.

-- playerId -> kit key. See above: session scope, not instance scope.
local choices = {}

-- playerId -> true once the picker has been opened for them unasked. One
-- prompt per session, never a nag.
local prompted = {}

-- playerId -> true when THIS Lua generation saw them connect.
--
-- THE TRAP THIS EXISTS FOR, and it has already cost this mode a day elsewhere:
-- a hot reload hands the successor VM a FRESH `prompted` table, so a picker
-- keyed on "have I seen this player" reopens on every single Lua save. Nothing
-- stored in this VM can survive to say otherwise.
--
-- server/main.lua solves the identical problem for placement and this follows
-- its precedent exactly: the durable signal is the ABSENCE of
-- `onPlayerConnected`, which does not re-fire for a client that is already
-- connected. No connect in this generation means the player was in the world
-- before the reload -- adopt them, do not prompt them.
local connected = {}

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = DM.playerId(playerIdStr)
    if playerId ~= nil then connected[playerId] = true end
end)


-- `DM.tune.<key>` IS A CALL BEHIND A METATABLE, so it is read at the point of
-- use and never hoisted to a file-scope local -- a local would freeze the value
-- at load and every later flip from the Warden panel would do nothing while the
-- panel went on reporting the new one.
local function tunedMode()
    local tune = DM.tune
    if type(tune) ~= "table" then return nil end
    local ok, value = pcall(function() return tune.loadoutMode end)
    if not ok or type(value) ~= "string" then return nil end
    return value
end

--- "equalizer" or "choice". The tunable wins over the config default so an
--- operator can flip it on a running server; anything unrecognised reads as
--- "equalizer", because the equalizer is the behaviour that was already there.
function Loadout.mode()
    local configured = type(Config.loadout) == "table" and Config.loadout.mode or nil
    local value = tunedMode() or configured or "equalizer"
    return value == "choice" and "choice" or "equalizer"
end

--- Does this instance issue the player's OWN pick? Free-for-all only, and only
--- while the switch says so. A nil instance is the lobby, where the pick is
--- still worth recording for the round the player has not joined yet.
local function choosable(instance)
    if Loadout.mode() ~= "choice" then return false end
    if instance == nil then return true end
    if instance.kind == "arena" then return false end
    local spec = instance.format ~= nil and Config.formats[instance.format] or nil
    local style = spec ~= nil and spec.loadout or "equalizer"
    return style == "equalizer"
end

--- The primary this player picked for the session, defaulted. Never nil while
--- the arsenal has an entry -- and it always has one, because
--- `Loadout.primaries` falls back to the equalizer rotation.
function Loadout.chosenPrimary(playerId)
    playerId = DM.playerId(playerId)
    local key = playerId ~= nil and choices[playerId] or nil
    local fallback = type(Config.loadout) == "table" and Config.loadout.default or nil
    return primaryByKey(key) or primaryByKey(fallback) or Loadout.primaries()[1]
end

--- The slot-1 key the player is actually CARRYING, read off the plan that was
--- last issued rather than off the pick -- which is the whole point: the two
--- differ for exactly as long as a pick is waiting on a respawn.
---
--- Under an ARENA plan the slot-1 key is the KIT's, not a weapon's, because
--- `planFromKit` stamps the kit key on every line. That is deliberate and is
--- what lets one function answer for both paths; the arena never consults
--- `choicePending` anyway.
local function issuedPrimaryKey(instance, playerId)
    local entry = book(instance)
    local plan = (entry ~= nil and playerId ~= nil) and entry.plans[playerId] or nil
    if type(plan) ~= "table" then return nil end
    for _, spec in ipairs(plan) do
        if spec.slot == 1 then return spec.key end
    end
    return nil
end

--- True while a pick has been made but not yet handed over. An equalizer weapon
--- in slot 1 answers true as well, and correctly: the player is holding a
--- rotation entry and is owed a kit.
function Loadout.choicePending(instance, playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil or instance == nil or not choosable(instance) then return false end
    local wanted = Loadout.chosenPrimary(playerId)
    if wanted == nil then return false end
    return issuedPrimaryKey(instance, playerId) ~= wanted.key
end

--- CAN THE SWAP HAPPEN NOW, OR MUST IT WAIT FOR A RESPAWN?
---
--- A weapon must never change in a player's hands mid-firefight: `issue` strips
--- all three slots, waits 250 ms and re-assigns, so a player who picks while
--- being shot at spends a quarter of a second holding nothing. Waiting for the
--- respawn costs them nothing -- they are about to be re-armed anyway.
---
--- The exceptions are the cases where it is genuinely free, and they are worth
--- taking because they are the common ones: the picker opens by itself DURING
--- spawn protection, and a pick made there should land there.
local function swapIsFree(instance, playerId)
    if instance == nil then return true, "lobby" end
    local round = instance.round
    -- No round, or the standings interval between two: nobody can shoot.
    if type(round) ~= "table" or round.state ~= "active" then return true, "between" end
    -- Dead and counting down. The respawn re-issues, so let it.
    if type(round.pending) == "table" and round.pending[playerId] ~= nil then
        return false, "respawning"
    end
    -- Inside spawn protection: invulnerable, and firing would have dropped it.
    if type(DM.protectionRemaining) == "function"
        and (DM.protectionRemaining(playerId) or 0) > 0 then
        return true, "protected"
    end
    return false, "live"
end

--- Record a pick and put it where the player can feel it.
---
--- `name` is anything `resolvePrimary` understands: a weapon key, one of the
--- four arena kit keys, or the display label.
---
--- Returns ok, weaponKeyOrReason, outcome. `outcome` is one of "applied",
--- "queued", "ready", "arena", "arena_other", "equalizer" -- the command prints
--- it and the notice says the same thing in words.
function Loadout.chooseWeapons(playerId, name)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false, "bad_player_id" end
    local weapon = resolvePrimary(name)
    if weapon == nil then return false, "unknown_weapon" end

    choices[playerId] = weapon.key
    -- A player who has picked has been asked. Never prompt them again.
    prompted[playerId] = true

    -- One meaning everywhere: if they happen to be in an arena buy window, this
    -- is that window's pick too -- for the four weapons the buy list actually
    -- sells. `kitForPrimary` answers nil for the other forty-five and the arena
    -- keeps its own default; `chooseKit` refuses anywhere that is not a buy
    -- window regardless.
    local kitKey = kitForPrimary(weapon)
    if kitKey ~= nil then Loadout.chooseKit(playerId, kitKey) end

    local instance = instanceOf(playerId)
    if instance ~= nil and instance.kind == "arena" then
        -- TWO DIFFERENT TRUTHS, and the old single message could only tell one
        -- of them. The buy list sells four of the forty-nine; a pick the arena
        -- carries really does arm next round, and a pick it does not carry
        -- arms nothing here. Promising the second would be exactly the lie
        -- this feature exists to avoid.
        if kitKey ~= nil then
            DM.notice(playerId, "info", "gunsReady", weapon.label)
            return true, weapon.key, "arena"
        end
        DM.notice(playerId, "info", "gunsArenaOnly", weapon.label)
        return true, weapon.key, "arena_other"
    end

    if Loadout.mode() ~= "choice" then
        -- Recorded anyway rather than refused: flipping `loadoutMode` back to
        -- "choice" mid-session must honour a pick made while it was off.
        DM.notice(playerId, "info", "gunsEqualizer")
        return true, weapon.key, "equalizer"
    end

    if instance == nil then
        DM.notice(playerId, "info", "gunsReady", weapon.label)
        return true, weapon.key, "ready"
    end

    local free, why = swapIsFree(instance, playerId)
    -- The issue is checked, not assumed. It refuses a player who is in the
    -- registry but not a member of the instance -- a real window, between a
    -- detach and the next placement -- and telling them the weapon is in their
    -- hands when nothing was issued is the one lie this whole feature exists to
    -- avoid. The respawn will pick it up, so say that instead.
    if free and Loadout.issue(playerId, instance, "guns_" .. tostring(why)) then
        DM.notice(playerId, "info", "gunsApplied", weapon.label)
        return true, weapon.key, "applied"
    end
    DM.notice(playerId, "info", "gunsNextSpawn", weapon.label)
    return true, weapon.key, "queued"
end

--- Open the picker on the player's match surface.
---
--- The payload carries everything the surface needs, so the picker costs the
--- state push nothing: that push runs several times a second for every player,
--- and a catalogue which changes only when this file is edited has no business
--- riding on it.
function Loadout.openPicker(playerId, auto)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    if #Loadout.primaries() == 0 then return false end
    prompted[playerId] = true
    local instance = instanceOf(playerId)
    -- 49 rows of four scalars is ~250 value nodes against the host's
    -- 1024-node ceiling for one message, so the catalogue still travels whole
    -- and the page needs no paging -- which is why this panel can scroll and
    -- filter where the admin menu has to be sent a nine-row window. If the
    -- arsenal ever triples, this is the line that has to start windowing too.
    TriggerClientEvent("deathmatch:guns", playerId, {
        open = true,
        auto = auto == true,
        mode = Loadout.mode(),
        chosen = Loadout.chosenPrimary(playerId).key,
        carrying = issuedPrimaryKey(instance, playerId),
        pending = Loadout.choicePending(instance, playerId),
        weapons = Loadout.primaryList(),
    })
    return true
end

--- The first-time prompt: once, on a player's first arming of the session.
---
--- It fires from `issue`, which means it fires while the player is inside the
--- spawn protection that goes with the placement that just happened -- so the
--- one moment the picker holds them still is a moment they cannot be hurt. The
--- HUD closes it by itself when that protection ends, so it can never leave
--- somebody standing in a live round reading a menu.
function Loadout.maybePrompt(playerId, instance)
    if type(Config.loadout) == "table" and Config.loadout.promptOnFirstRound == false then
        return false
    end
    if not choosable(instance) then return false end
    playerId = DM.playerId(playerId)
    if playerId == nil or prompted[playerId] then return false end
    if not connected[playerId] then
        -- A reload survivor. `prompted` died with the outgoing VM and
        -- `connected` is empty for precisely the same reason; the two absences
        -- cancel. Mark them asked and stay quiet -- a Lua save must not reopen
        -- a menu in front of somebody who is playing.
        prompted[playerId] = true
        return false
    end
    return Loadout.openPicker(playerId, true)
end


RegisterNetEvent("deathmatch:chooseGuns", function(key)
    local playerId = DM.playerId(source)
    if playerId == nil then return end
    local ok, reason = Loadout.chooseWeapons(playerId, key)
    if not ok and Config.debug.verboseInstances then
        DM.log(("guns pick refused player=%d reason=%s"):format(playerId, tostring(reason)))
    end
end)

RegisterNetEvent("deathmatch:requestGuns", function()
    local playerId = DM.playerId(source)
    if playerId ~= nil then Loadout.openPicker(playerId, false) end
end)


-- ------------------------------------------------------------------ plans --

-- One kit -> a slot plan. Shared by the arena buy window and by the `/guns`
-- pick, because they draw from the same catalogue and a second copy of this
-- loop is a second place for the two to drift apart.
--
-- `key` is the KIT key on every slot, not the weapon's. That is what makes
-- `issuedPrimaryKey` able to say what a player is carrying by reading the plan
-- back.
local function planFromKit(kit)
    if kit == nil or type(kit.slots) ~= "table" then return nil end
    local plan = {}
    for _, line in ipairs(kit.slots) do
        plan[#plan + 1] = {
            slot = math.floor(tonumber(line.slot) or 1),
            record = tostring(line.record),
            reserve = DM.finite(line.reserve),
            key = kit.key,
            label = kit.label,
        }
    end
    if #plan == 0 then return nil end
    table.sort(plan, function(a, b) return a.slot < b.slot end)
    return plan, kit
end

--- One WEAPON -> a three-slot plan: the pick in slot 1, then the fixed sidearm
--- and melee from `Config.equalizer`.
---
--- SLOTS 2 AND 3 ARE NOT CHOOSABLE, and that is the existing rule rather than a
--- simplification: `Config.equalizer` states it -- a player who runs the primary
--- dry still has a fight left. The picker changes what goes in slot 1 and
--- nothing else.
---
--- The one special case is mechanical, not a rule. Unity is both a pickable
--- pistol and the fixed sidearm, so a player who picks it would ask the weapons
--- API to equip one record into two slots. The duplicate is dropped; they get
--- the Unity once, in slot 1, and keep the katana.
local function planFromPrimary(entry)
    if entry == nil or entry.record == nil then return nil end
    local equalizer = Config.equalizer
    local plan = {
        { slot = 1, record = tostring(entry.record), reserve = DM.finite(entry.reserve),
          key = entry.key, label = entry.label, category = entry.category },
    }
    local sidearm = equalizer.sidearm
    if type(sidearm) == "table" and sidearm.record ~= entry.record then
        plan[#plan + 1] = { slot = math.floor(tonumber(sidearm.slot) or 2),
            record = tostring(sidearm.record), reserve = DM.finite(sidearm.reserve),
            key = sidearm.key, label = sidearm.label, category = sidearm.category }
    end
    local melee = equalizer.melee
    if type(melee) == "table" then
        plan[#plan + 1] = { slot = math.floor(tonumber(melee.slot) or 3),
            record = tostring(melee.record), reserve = DM.finite(melee.reserve),
            key = melee.key, label = melee.label, category = melee.category }
    end
    table.sort(plan, function(a, b) return a.slot < b.slot end)
    return plan, entry
end


-- What a player is owed, as an array of slot specs, ordered slot 1 first.
--
-- The FFA plan is the equalizer's three lines and nothing else; the arena plan
-- is the chosen kit's. Neither invents a record: every `record` here came out
-- of shared/config.lua, which took it from the generated 2.31 catalogue.
function Loadout.planFor(instance, playerId)
    if instance == nil then return nil end
    playerId = DM.playerId(playerId)
    if playerId == nil then return nil end

    local format = instance.format
    local spec = format ~= nil and Config.formats[format] or nil
    local style = spec ~= nil and spec.loadout or ((instance.kind == "arena") and "kit" or "equalizer")

    if style == "kit" then
        return planFromKit(Loadout.kitFor(instance, playerId))
    end

    -- `loadout.mode = "choice"`: the free-for-all issues the player's OWN pick,
    -- out of `Config.loadout.primaries` -- every canonical firearm of the build,
    -- not the arena's four-kit buy list. Slots 2 and 3 stay the equalizer's
    -- fixed sidearm and melee, so the choice is the primary and nothing else.
    -- Everything below this branch is the equalizer, unchanged, and is what
    -- `mode = "equalizer"` still runs.
    if choosable(instance) then
        local plan, weapon = planFromPrimary(Loadout.chosenPrimary(playerId))
        if plan ~= nil then return plan, weapon end
    end

    local weapon = Loadout.weapon(instance)
    if weapon == nil then return nil end
    local equalizer = Config.equalizer
    local plan = {
        { slot = 1, record = tostring(weapon.record), reserve = DM.finite(weapon.reserve),
          key = weapon.key, label = weapon.label, category = weapon.category, rotating = true },
    }
    local sidearm = equalizer.sidearm
    if type(sidearm) == "table" then
        plan[#plan + 1] = { slot = math.floor(tonumber(sidearm.slot) or 2),
            record = tostring(sidearm.record), reserve = DM.finite(sidearm.reserve),
            key = sidearm.key, label = sidearm.label, category = sidearm.category }
    end
    local melee = equalizer.melee
    if type(melee) == "table" then
        plan[#plan + 1] = { slot = math.floor(tonumber(melee.slot) or 3),
            record = tostring(melee.record), reserve = DM.finite(melee.reserve),
            key = melee.key, label = melee.label, category = melee.category }
    end
    table.sort(plan, function(a, b) return a.slot < b.slot end)
    return plan, weapon
end


-- An externally supplied slot list -- `{ { slot, record, reserve }, ... }` --
-- brought up to the shape the rest of this file uses. Labels are recovered from
-- the config by record so the kill feed still has a weapon name; no record, no
-- slot: an entry missing either is dropped rather than issued blind.
function Loadout.normalizePlan(slots)
    if type(slots) ~= "table" or #slots == 0 then return nil end
    local plan = {}
    for _, line in ipairs(slots) do
        local slot = math.floor(tonumber(line.slot) or 0)
        local record = line.record ~= nil and tostring(line.record) or nil
        if slot >= 1 and slot <= 3 and record ~= nil then
            plan[#plan + 1] = {
                slot = slot,
                record = record,
                reserve = DM.finite(line.reserve),
                key = line.key or Loadout.keyForRecord(record),
                label = line.label or Loadout.labelForRecord(record),
                category = line.category,
            }
        end
    end
    if #plan == 0 then return nil end
    table.sort(plan, function(a, b) return a.slot < b.slot end)
    return plan, plan[1]
end

-- Record -> the config entry that names it. The catalogue is small and read
-- once per issue, so a linear scan is auditable and costs nothing.
local function catalogueEntry(record)
    record = tostring(record)
    for _, entry in ipairs(Config.equalizer.rotation) do
        if entry.record == record then return entry end
    end
    for _, key in ipairs({ "sidearm", "melee" }) do
        local entry = Config.equalizer[key]
        if type(entry) == "table" and entry.record == record then return entry end
    end
    -- The arsenal, which is where every `/guns` pick comes from. Scanned after
    -- the rotation so the ten records the two lists share keep answering with
    -- the rotation's own entry, and before the kits so a weapon is named by its
    -- own name rather than by the kit that happens to carry it.
    for _, entry in ipairs(Loadout.primaries()) do
        if entry.record == record then return entry end
    end
    for _, kit in ipairs(Config.kits.list) do
        for _, line in ipairs(kit.slots) do
            if line.record == record then return { key = kit.key, label = kit.label } end
        end
    end
    return nil
end

function Loadout.keyForRecord(record)
    local entry = catalogueEntry(record)
    return entry ~= nil and entry.key or nil
end

function Loadout.labelForRecord(record)
    local entry = catalogueEntry(record)
    return entry ~= nil and entry.label or nil
end


-- ------------------------------------------------------------------ ammo --

-- THE ONE PLACE AMMUNITION OPTIONS ARE BUILT. See the header: a `magazine` that
-- exceeds the weapon's capacity makes `setAmmo` fail as a whole and leaves the
-- counter at `000 0000`, and this file does not know any weapon's capacity. So
-- the key is dropped here, loudly, rather than trusted to a caller.
local function ammoOptions(spec, activate)
    if spec == nil then return nil end
    local reserve = DM.finite(spec.reserve)
    if reserve == nil or reserve <= 0 then return nil end
    if spec.magazine ~= nil then
        DM.log(("loadout: DROPPED a magazine value for slot %s -- setAmmo fails as a whole"
            .. " when magazine exceeds capacity (measured 2026-08-31); reserve only"):format(
            tostring(spec.slot)))
    end
    return { reserve = math.floor(reserve), activate = activate == true }
end


-- -------------------------------------------------------------- the issue --

local function track(requestId, info)
    if requestId == nil then return false end
    info.atMs = DM.nowMs()
    pending[tostring(requestId)] = info
    return true
end

local function requestAmmo(playerId, instance, version, spec, activate)
    local options = ammoOptions(spec, activate)
    if options == nil then return end
    local requestId, reason = Open77.weapons.setAmmo(playerId, spec.slot, options)
    if requestId == nil then
        DM.log(("loadout ammo refused player=%d slot=%d reason=%s"):format(
            playerId, spec.slot, tostring(reason)))
        return
    end
    track(requestId, {
        playerId = playerId, instanceId = instance.id, version = version,
        step = "setAmmo", slot = spec.slot, spec = spec, activate = activate == true,
    })
end

-- Removes everything in the three slots and bumps the version, so any verdict
-- still in flight for this player is dead on arrival.
--
-- `instance` is optional: `sendToLobby` strips a player who may already have
-- been detached, and the strip must still happen.
function Loadout.strip(playerId, instance)
    -- A bot never carries a server-issued loadout: bots.lua owns its
    -- weapon end to end, and Open77.weapons.* raises on a negative id
    -- rather than returning an error, taking the resource with it.
    if type(playerId) == "number" and playerId <= 0 then return false end
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    bumpVersion(playerId)

    instance = instance or instanceOf(playerId)
    local entry = book(instance)
    if entry ~= nil then
        entry.sets[playerId] = nil
        entry.plans[playerId] = nil
    end
    if instance ~= nil then instance.weaponIds[playerId] = nil end

    Open77.weapons.holster(playerId)
    for slot = 1, 3 do Open77.weapons.remove(playerId, slot) end
    return true
end

-- Issue the whole loadout. Returns true when the requests went out; the WEAPON
-- is not usable until each verdict lands, and the arbiter enforces that.
--
-- `reason` is for the log only.
function Loadout.issue(playerId, instance, reason, slots)
    -- A bot never carries a server-issued loadout: bots.lua owns its
    -- weapon end to end, and Open77.weapons.* raises on a negative id
    -- rather than returning an error, taking the resource with it.
    if type(playerId) == "number" and playerId <= 0 then return false end
    playerId = DM.playerId(playerId)
    if playerId == nil then return false, "bad_player_id" end
    instance = instance or instanceOf(playerId)
    if instance == nil or instance.closed then return false, "not_in_instance" end
    if not instance.members[playerId] then return false, "not_a_member" end

    -- `slots` lets the ROUND decide what to issue and leaves this file to issue
    -- it -- the seam round.lua declares (`DM.equip(playerId, instance, slots)`).
    -- Absent, the plan is resolved here from the format. Both spellings answer
    -- the same way; only one file may be the source of truth per call.
    local plan, source = Loadout.normalizePlan(slots)
    if plan == nil then plan, source = Loadout.planFor(instance, playerId) end
    if plan == nil or #plan == 0 then return false, "no_plan" end

    local version = bumpVersion(playerId)
    local entry = book(instance)
    entry.plans[playerId] = plan
    entry.sets[playerId] = {}
    -- Cleared IMMEDIATELY, not when the new verdict lands: between the strip and
    -- the verification the player is holding nothing the server issued, and the
    -- arbiter must say so.
    instance.weaponIds[playerId] = nil

    Open77.weapons.holster(playerId)
    for slot = 1, 3 do Open77.weapons.remove(playerId, slot) end

    -- The 250 ms gap. The removals above are asynchronous too; assigning into a
    -- slot still being torn down loses the assignment with no error anywhere.
    SetTimeout(250, function()
        local current = instanceOf(playerId)
        if current ~= instance or instance.closed
            or versions[playerId] ~= version
            or not instance.members[playerId] then return end

        -- Descending slot order so slot 1 -- the only one assigned `active` --
        -- is the LAST request issued and therefore the weapon in hand when the
        -- dust settles. Assigning it first and then filling slots 2 and 3 puts
        -- the katana in the player's hands at the start of a gunfight.
        for index = #plan, 1, -1 do
            local spec = plan[index]
            local requestId, refusal = Open77.weapons.assign(
                playerId, spec.record, spec.slot,
                { active = spec.slot == 1, addToInventory = true })
            if requestId == nil then
                DM.log(("loadout assign refused player=%d slot=%d weapon=%s reason=%s"):format(
                    playerId, spec.slot, tostring(spec.key), tostring(refusal)))
                if spec.slot == 1 then DM.notice(playerId, "error", "loadoutFailed") end
            else
                track(requestId, {
                    playerId = playerId, instanceId = instance.id, version = version,
                    step = "assign", slot = spec.slot, spec = spec,
                })
            end
        end
    end)

    if Config.debug.verboseInstances then
        DM.log(("loadout issued player=%d instance=%d slots=%d source=%s (%s)"):format(
            playerId, instance.id, #plan,
            tostring(source ~= nil and (source.key or source.label) or "?"),
            tostring(reason or "issue")))
    end

    -- WHAT THE BAND SHOWS. `Round.stateFor` publishes `round.weapon`, which is
    -- the equalizer's rotation entry and is correct only under
    -- `mode = "equalizer"` -- `rotate` returns nil in choice mode precisely so
    -- that it publishes nothing there. This is the replacement: the loadout
    -- says what it just handed this player, and the HUD prefers it over the
    -- round's weapon only while the mode is "choice".
    --
    -- It rides its own event rather than the state push because a push runs
    -- several times a second for every player and this changes a handful of
    -- times a round.
    local primary = nil
    for _, spec in ipairs(plan) do
        if spec.slot == 1 then primary = spec end
    end
    TriggerClientEvent("deathmatch:loadout", playerId, {
        mode = Loadout.mode(),
        kit = source ~= nil and source.key or nil,
        label = primary ~= nil
            and (Loadout.labelForRecord(primary.record) or primary.label) or nil,
        category = source ~= nil and source.label or nil,
    })

    -- The first-time weapon picker, at the ONE point in the mode that means
    -- "this player is now armed and in a round". It self-limits to once per
    -- session and stays silent for a hot-reload survivor; see `maybePrompt`.
    -- Last, so an issue that failed above never opens a menu.
    Loadout.maybePrompt(playerId, instance)
    return true
end


-- --------------------------------------------------------------- resupply --

-- Reserve only, and NO `activate`: a resupply happens mid-life, and activating
-- slot 1 would yank the weapon out of the hands of a player who had deliberately
-- switched to the sidearm.
function Loadout.resupply(playerId, instance, reason)
    -- A bot never carries a server-issued loadout: bots.lua owns its
    -- weapon end to end, and Open77.weapons.* raises on a negative id
    -- rather than returning an error, taking the resource with it.
    if type(playerId) == "number" and playerId <= 0 then return false end
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    instance = instance or instanceOf(playerId)
    if instance == nil or instance.closed then return false end

    -- round.lua's seam is `resupply(playerId, instance, slots)`; a table in the
    -- third position is a slot list, not a reason. Accepting both keeps one
    -- implementation rather than two that can drift.
    local supplied = nil
    if type(reason) == "table" then
        supplied = Loadout.normalizePlan(reason)
        reason = "round_start"
    end

    local entry = book(instance)
    local plan = supplied or (entry ~= nil and entry.plans[playerId] or nil)
    if plan == nil then
        -- Nothing was ever issued in this instance -- issuing is the resupply.
        return Loadout.issue(playerId, instance, reason or "resupply_without_plan")
    end

    local version = versions[playerId] or 0
    local sent = 0
    for _, spec in ipairs(plan) do
        if DM.finite(spec.reserve) ~= nil then
            requestAmmo(playerId, instance, version, spec, false)
            sent = sent + 1
        end
    end
    if sent > 0 then DM.notice(playerId, "info", "resupplied") end
    return sent > 0
end

-- Round rollover: everyone still standing gets their reserve back. Without this
-- a player who survives a long round runs dry and reads it as a broken gun.
function Loadout.resupplyInstance(instance, reason)
    local registry = instances()
    if registry == nil or instance == nil then return 0 end
    local count = 0
    -- humans, not members: a bot has no server-issued loadout to resupply.
    for _, playerId in ipairs(registry.humans and registry.humans(instance)
            or registry.members(instance)) do
        if Loadout.resupply(playerId, instance, reason or "round_start") then
            count = count + 1
        end
    end
    return count
end

-- The two switches shared/config.lua publishes, honoured here so a caller can
-- ask unconditionally and let the config decide.
function Loadout.onRespawn(playerId, instance)
    playerId = DM.playerId(playerId)
    if playerId == nil then return false end
    instance = instance or instanceOf(playerId)

    -- WHERE A `/guns` PICK MADE MID-ROUND ACTUALLY LANDS.
    --
    -- A respawn normally only refills the reserve: re-issuing three weapons on
    -- every death would be three assign handshakes for no change. But it is
    -- also the only point in a live round where swapping is free -- the player
    -- has just been placed and is holding nothing they were using a second ago
    -- -- so a pending pick is spent here, as a full issue, and the resupply is
    -- skipped because the issue carries its own ammunition.
    if Loadout.choicePending(instance, playerId) then
        return Loadout.issue(playerId, instance, "guns_respawn")
    end

    if Config.equalizer.resupplyOnRespawn == false then return false end
    return Loadout.resupply(playerId, instance, "respawn")
end

function Loadout.onRoundStart(instance)
    if Config.equalizer.resupplyOnRoundStart == false then return 0 end
    return Loadout.resupplyInstance(instance, "round_start")
end


-- round.lua's loadout seam is `equip` / `strip` / `resupply`, and it prefers a
-- published `Deathmatch.loadout` over the primitives main.lua registers. `equip`
-- is `issue` under the name that seam uses; `strip` and `resupply` already carry
-- it. One implementation, two spellings, so neither file has to be edited to
-- agree with the other.
function Loadout.equip(playerId, instance, slots)
    return Loadout.issue(playerId, instance, "equip", slots)
end


-- ----------------------------------------------------------- verification --

-- The slot-1 verified id -- the exact value main.lua's arbiter and bots.lua's
-- `verifiedWeaponId` hook both read out of `instance.weaponIds`.
function Loadout.verifiedWeaponId(instance, playerId)
    playerId = DM.playerId(playerId)
    if instance == nil or playerId == nil then return nil end
    local id = instance.weaponIds[playerId]
    if id == nil or id == "" then return nil end
    return id
end

-- THE SET. Three slots are issued, so a shot may legitimately come from any of
-- the three verified ids -- a katana kill is otherwise refused as
-- `wrong_weapon`, which is the single most confusing rejection this mode can
-- produce because the player is holding a weapon the server itself handed them.
--
-- Fail closed: an empty set accepts nothing.
function Loadout.accepts(instance, playerId, reportedWeaponId)
    playerId = DM.playerId(playerId)
    if instance == nil or playerId == nil then return false, "no_instance" end
    local reported = normalizeWeaponId(reportedWeaponId)
    if reported == "" then return false, "unreadable_weapon" end

    local entry = book(instance)
    local set = entry ~= nil and entry.sets[playerId] or nil
    if type(set) ~= "table" then return false, "weapon_not_verified" end

    local any = false
    for _, verified in pairs(set) do
        any = true
        if verified == reported then return true, "verified" end
    end
    if not any then return false, "weapon_not_verified" end
    return false, "wrong_weapon"
end

function Loadout.isVerified(instance, playerId)
    return Loadout.verifiedWeaponId(instance, playerId) ~= nil
end

-- The label the kill feed renders for a shot. Resolved from the plan that was
-- ISSUED, by verified id first and by slot second, so the feed never invents a
-- weapon name and never carries display language of its own -- every label here
-- came out of `Config.equalizer` or `Config.kits`.
--- The catalogue KEY of the weapon this player actually reported firing.
---
--- `weaponDamage` in bots.lua used to be keyed on the round's equalizer weapon,
--- which was fine while everyone carried the same gun. `/guns` ended that: under
--- `loadout.mode = "choice"` there is no round weapon, the lookup missed, and
--- every player-to-bot hit fell through to `defaultDamage` -- so a sniper, an
--- SMG and a shotgun all did 26 and every bot died in exactly four hits from
--- anything. Pricing the shot by what was fired restores the difference.
---
--- Resolved through the issued SET, like `labelFor` and `accepts`, so a weapon
--- the server never handed this player prices as nothing rather than as its
--- catalogue value.
function Loadout.keyFor(instance, playerId, weaponId)
    playerId = DM.playerId(playerId)
    if instance == nil or playerId == nil then return nil end
    local entry = book(instance)
    if entry == nil then return nil end
    local plan = entry.plans[playerId]
    if type(plan) ~= "table" then return nil end

    local reported = normalizeWeaponId(weaponId)
    local set = entry.sets[playerId]
    if reported == "" or type(set) ~= "table" then return nil end

    for slot, verified in pairs(set) do
        if verified == reported then
            for _, spec in ipairs(plan) do
                if spec.slot == slot then
                    return spec.key or Loadout.keyForRecord(spec.record)
                end
            end
        end
    end
    return nil
end

function Loadout.labelFor(instance, playerId, weaponId)
    playerId = DM.playerId(playerId)
    if instance == nil or playerId == nil then return nil end
    local entry = book(instance)
    if entry == nil then return nil end
    local plan = entry.plans[playerId]
    if type(plan) ~= "table" then return nil end

    local reported = normalizeWeaponId(weaponId)
    local set = entry.sets[playerId]
    if reported ~= "" and type(set) == "table" then
        for slot, verified in pairs(set) do
            if verified == reported then
                for _, spec in ipairs(plan) do
                    if spec.slot == slot then return spec.label end
                end
            end
        end
    end
    -- No match: name the primary rather than nothing. A feed line without a
    -- weapon is still a kill, and the HUD draws a glyph in its place.
    for _, spec in ipairs(plan) do
        if spec.slot == 1 then return spec.label end
    end
    return nil
end


-- ============================================================== completion --
--
-- The verdict. Everything above is a request; this is the only place a weapon
-- becomes real to the arbiter.
AddEventHandler("open77:weapons:completed", function(
    playerId, requestId, operation, accepted, reason, result)
    local key = tostring(requestId)
    local info = pending[key]
    -- Not ours: another resource's request, or a `setActive` we fired and do not
    -- track. Silence is correct.
    if info == nil then return end
    pending[key] = nil

    local numericId = DM.playerId(playerId)
    if numericId == nil or numericId ~= info.playerId then return end
    if info.step ~= operation then return end

    -- STALENESS, in the order the checks get cheaper. A verdict that survives
    -- all three belongs to the round that is being played right now.
    if versions[info.playerId] ~= info.version then return end
    local instance = instanceOf(info.playerId)
    if instance == nil or instance.closed or instance.id ~= info.instanceId then return end

    if accepted ~= true then
        local transient = reason == "queue_full" or reason == "player_unavailable"
            or (info.slot == 1 and (reason == "weapon_not_drawn"
                or reason == "weapon_slot_empty" or reason == "activation_rejected"))
        if transient and (info.retries or 0) < 3 then
            info.retries = (info.retries or 0) + 1
            SetTimeout(500 * info.retries, function()
                local current = instanceOf(info.playerId)
                if current ~= instance or instance.closed
                    or versions[info.playerId] ~= info.version then return end
                local requestId
                if operation == "assign" then
                    requestId = Open77.weapons.assign(info.playerId, info.spec.record, info.slot,
                        { active = info.slot == 1, addToInventory = true })
                elseif operation == "setAmmo" then
                    requestId = Open77.weapons.setAmmo(info.playerId, info.slot,
                        ammoOptions(info.spec, info.activate))
                end
                if requestId then track(requestId, info) end
            end)
            return
        end
        DM.log(("loadout %s failed player=%d slot=%s reason=%s"):format(
            tostring(operation), info.playerId, tostring(info.slot), tostring(reason)))
        if operation == "assign" and info.slot == 1 then
            DM.notice(info.playerId, "error", "loadoutFailed")
        end
        return
    end

    if operation ~= "assign" then return end

    result = type(result) == "table" and result or {}
    local verifiedId = normalizeWeaponId(result.tweakDbId)
    local entry = book(instance)
    if verifiedId == "" then
        -- The weapon IS equipped -- the platform accepted -- but without an id
        -- the arbiter has nothing to match a shot against, so the player's
        -- shots stay blocked. Say exactly that; a silent version of this is
        -- indistinguishable from a hit-registration bug.
        DM.log(("loadout assign returned no TweakDBID player=%d slot=%d"):format(
            info.playerId, info.slot))
        if info.slot == 1 then DM.notice(info.playerId, "warning", "loadoutUnverified") end
    else
        entry.sets[info.playerId] = entry.sets[info.playerId] or {}
        entry.sets[info.playerId][info.slot] = verifiedId
        -- Slot 1 is ALSO published on the instance, because that is the field
        -- main.lua's arbiter and bots.lua's `verifiedWeaponId` hook read. The
        -- full set lives in the book; see `Loadout.accepts`.
        if info.slot == 1 then
            instance.weaponIds[info.playerId] = verifiedId
            if Config.debug.verboseInstances then
                DM.log(("loadout verified player=%d instance=%d weapon=%s id=%s"):format(
                    info.playerId, instance.id, tostring(info.spec.key), verifiedId))
            end
        end
    end

    -- Ammunition follows the assign, always reserve-only, and activates only
    -- for slot 1 -- this is a fresh issue, so putting the primary in hand is
    -- what the player expects.
    requestAmmo(info.playerId, instance, info.version, info.spec, info.slot == 1)

    -- Slot 1 is the last assign issued (see the descending loop), so this is
    -- the point where the whole loadout has landed. Make the primary active
    -- explicitly rather than trusting assign ordering across three requests.
    if info.slot == 1 and Open77.weapons.setActive ~= nil then
        Open77.weapons.setActive(info.playerId, 1)
    end
end)


-- ------------------------------------------------------------ housekeeping --

-- A completion that never arrives would leak its entry forever. Cheap, and
-- called from the mode tick.
function Loadout.sweep(now)
    now = now or DM.nowMs()
    for key, info in pairs(pending) do
        if now - (info.atMs or now) > PENDING_TTL_MS then pending[key] = nil end
    end
end

function Loadout.forget(playerId)
    playerId = DM.playerId(playerId)
    if playerId == nil then return end
    versions[playerId] = nil
    -- The `/guns` pick goes with them, DELIBERATELY. See the weapon-choice
    -- header: with no persistence layer, keeping it would mean keeping a
    -- preference keyed by a player id the platform may hand to somebody else.
    choices[playerId] = nil
    prompted[playerId] = nil
    connected[playerId] = nil
    for key, info in pairs(pending) do
        if info.playerId == playerId then pending[key] = nil end
    end
end

-- Registered here rather than wired into main.lua's disconnect handler: several
-- handlers for one event are fine, and a file that allocates its own state
-- should release it without asking another file to remember.
AddEventHandler("onPlayerDisconnected", function(playerId)
    Loadout.forget(playerId)
end)


-- ------------------------------------------------------------- diagnostics --

-- The `<mode>.where` habit applied to loadouts: print what the server believes
-- a player is holding, so "my gun does not register" can be read rather than
-- guessed at. It is the fastest way to tell an unverified weapon -- which is a
-- loadout fault -- from a rejected shot, which is an arbiter one.
RegisterCommand("dm.loadout", function(source, args, raw)
    local function say(text)
        print(text)
        if source ~= nil and source > 0 then
            TriggerClientEvent("open77:command:result", source, raw or "", true, text)
        end
    end

    local playerId = DM.playerId(args and args[1]) or DM.playerId(source)
    if playerId == nil then return say("loadout -- give a player id") end
    local instance = instanceOf(playerId)
    if instance == nil then
        return say(("loadout player=%d -- not in an instance"):format(playerId))
    end

    local entry = book(instance)
    local plan = entry.plans[playerId]
    local set = entry.sets[playerId] or {}
    say(("loadout player=%d instance=%d format=%s version=%d"):format(
        playerId, instance.id, tostring(instance.format), versions[playerId] or 0))
    -- The `/guns` half of the readout. `chosen` is the pick, `carrying` is what
    -- was actually issued, and the two differing IS the answer whenever the
    -- complaint is "I picked the sniper and I am holding a rifle": the pick is
    -- waiting on a respawn, exactly as designed.
    local chosen = Loadout.chosenPrimary(playerId)
    say(("  mode=%s  chosen=%s  carrying=%s  pending=%s"):format(
        Loadout.mode(),
        tostring(chosen and chosen.key),
        tostring(issuedPrimaryKey(instance, playerId) or "nothing"),
        tostring(Loadout.choicePending(instance, playerId))))
    -- The pick spelled out, because a key is not a weapon: "grad" and "60
    -- rounds of sniper ammunition" are the same fact and only one of them can
    -- be checked against what the player is looking at.
    if chosen ~= nil then
        say(("  pick=%s  category=%s  reserve=%s  (arsenal holds %d)"):format(
            tostring(chosen.label), tostring(chosen.category or "-"),
            tostring(chosen.reserve or "-"), #Loadout.primaries()))
    end
    if plan == nil then return say("  nothing issued in this instance") end
    for _, spec in ipairs(plan) do
        say(("  slot %d  %-26s reserve=%s  verified=%s"):format(
            spec.slot, tostring(spec.label or spec.record),
            tostring(spec.reserve or "-"), tostring(set[spec.slot] or "NO")))
    end
    say(("  arbiter reads weaponIds[%d] = %s"):format(
        playerId, tostring(instance.weaponIds[playerId] or "nil -- shots blocked")))
end, false)


-- /guns [weapon|list] -- the weapon picker.
--
-- THREE FORMS, AND ONLY THE FIRST NEEDS THE UI. `/guns` opens the surface;
-- `/guns nekomata` makes the pick outright; `/guns list` prints the whole
-- arsenal, grouped exactly as the picker groups it. A feature reachable only
-- through a CEF page cannot be driven from the debug bridge or from a scenario
-- step, so the headless forms are what make this testable at all -- and they
-- print the same verdict the notice speaks, so the two can be compared.
--
-- `list` is new with the 49-weapon arsenal and is not a nicety. The old command
-- recited its four kit keys in every message; forty-nine of them do not fit in
-- a chat line and have no business in a notification toast, so the catalogue
-- moved to a form that can hold it and the other two messages just point at it.
--
-- The argument is forgiving on purpose -- see `resolvePrimary`: a weapon key, an
-- old kit key (`/guns sniper` still hands out a Grad), or the display label with
-- the punctuation taken out (`/guns spt32grad`).
--
-- Unrestricted: choosing your own gun is the feature, not an operator verb.
RegisterCommand("guns", function(source, args, raw)
    local function say(ok, text)
        print(text)
        if source ~= nil and source > 0 then
            TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
        end
    end

    if source == nil or source <= 0 then
        return say(false, Config.strings.error.playerOnly)
    end

    local catalogue = Loadout.primaryList()
    if #catalogue == 0 then
        -- No arsenal at all. Saying so beats opening an empty panel.
        return say(false, "guns -- this server has no weapons configured")
    end

    local wanted = args and args[1] ~= nil and string.lower(tostring(args[1])) or nil

    if wanted == "list" then
        say(true, ("guns -- %d weapons. /guns <key> picks one without the UI."):format(#catalogue))
        local group, keys = nil, {}
        local function flush()
            if group ~= nil and #keys > 0 then
                say(true, ("  %-16s %s"):format(group, table.concat(keys, "  ")))
            end
            keys = {}
        end
        for _, entry in ipairs(catalogue) do
            if entry.category ~= group then
                flush()
                group = entry.category
            end
            keys[#keys + 1] = entry.key
        end
        flush()
        local mine = Loadout.chosenPrimary(source)
        return say(true, ("  yours: %s"):format(tostring(mine ~= nil and mine.key or "none")))
    end

    if wanted == nil then
        Loadout.openPicker(source, false)
        local mine = Loadout.chosenPrimary(source)
        return say(true, ("guns -- picker open; you have '%s'. /guns <key> picks headless, /guns list prints all %d."):format(
            tostring(mine ~= nil and mine.key or "none"), #catalogue))
    end

    local ok, key, outcome = Loadout.chooseWeapons(source, wanted)
    if not ok then
        DM.notice(source, "warning", "gunsUnknown", wanted)
        return say(false, ("guns -- no weapon called '%s' (%s). /guns list prints all %d."):format(
            wanted, tostring(key), #catalogue))
    end

    -- The outcome is the whole point of the readout: WHEN a pick lands is the
    -- only thing about it a player can get wrong.
    local when = ({
        applied   = "in your hands now",
        queued    = "on your next respawn",
        ready     = "when you drop into a round",
        arena     = "when the next arena round arms",
        arena_other = "in the free-for-all -- this arena arms from its own four-kit buy list",
        equalizer = "never, while loadoutMode is 'equalizer' -- recorded for when it is not",
    })[tostring(outcome)] or tostring(outcome)
    local picked = Loadout.chosenPrimary(source)
    say(true, ("guns -- %s (%s), %s"):format(
        key, tostring(picked ~= nil and picked.label or key), when))
end, false)

-- Discoverability. `/guns` is worth nothing to a player who has to be told it
-- exists, and the chat resource publishes completions for exactly this. It is
-- fired by open77_chat on readiness, so a resource set without chat simply
-- never calls this -- there is nothing to guard.
RegisterNetEvent("chat:ready", function()
    local playerId = DM.playerId(source)
    if playerId == nil then return end
    TriggerClientEvent("chat:addSuggestions", playerId, { {
        command = "/guns",
        help = "Choose the weapons you play with.",
        parameters = { { name = "weapon", help = "a weapon key such as nekomata or carnage; 'list' prints every one. Omit to open the picker.", optional = true } },
    } })
end)


AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    DM.log(("loadout ready -- mode=%s, arsenal %d, equalizer rotation %d, sidearm=%s melee=%s, arena kits %d (default %s)"):format(
        Loadout.mode(),
        #Loadout.primaries(),
        #Config.equalizer.rotation,
        tostring(Config.equalizer.sidearm and Config.equalizer.sidearm.key or "none"),
        tostring(Config.equalizer.melee and Config.equalizer.melee.key or "none"),
        #Config.kits.list, tostring(Config.kits.default)))
end)
