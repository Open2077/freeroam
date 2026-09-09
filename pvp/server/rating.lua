-- Kabuki Arena -- per-format rating (Elo). Plan section 10, Phase 8.
--
-- THIS FILE IS PURE ARITHMETIC. It reads `DeathmatchConfig` and `Deathmatch.tune`
-- for its tunables and nothing else: no engine binding, no database, no player
-- id, no state that outlives a call. Everything durable -- the stored rating,
-- the write, the hot-reload carry, and above all the DECISION 12 GATE -- lives
-- in `server/ranked.lua`, which owns the ladder and calls in here for the one
-- question this file answers: given what everybody was rated and how the round
-- finished, who moves and by how much.
--
-- The separation is not tidiness. `ranked.lua` refuses a round containing a bot
-- BEFORE it reads a single standings row, and that refusal must remain the only
-- one in the mode. A rating module that could be reached by any other path
-- would be a second door onto the ladder and therefore a second gate to keep in
-- step; there is no such path, because this file cannot find a round on its own.
--
-- ===========================================================================
-- WHY THIS WAS DEFERRED, AND WHAT CHANGED
-- ===========================================================================
--
-- Phase 8 shipped the career and explicitly did NOT ship a rating, for two
-- reasons written down at the time: an N-player free-for-all needs a rating
-- model that pursuit's two-sided exchange does not supply, and the arena
-- formats could not run at all until the twelve team marks were surveyed.
--
-- Both have since gone. The marks landed on 2026-09-01 (`shared/kabuki.lua`
-- `Kabuki.teams`) and a 1v1 has resolved end to end. So the only thing left was
-- the model, and there are two of them below because the two shapes of round
-- this mode runs are genuinely different contests.
--
-- ===========================================================================
-- MODEL 1 -- ARENA (1v1 / 2v2 / 3v3): A TWO-SIDED EXCHANGE
-- ===========================================================================
--
-- An arena round has two sides, one winner and one loser. That is the contest
-- Elo was invented for, so it is used unmodified:
--
--     E_a = 1 / (1 + 10^((R_b - R_a) / spread))
--     delta_a = K_a * (S_a - E_a)
--
-- Two decisions had to be made explicitly, because a team format does not
-- follow from the formula:
--
-- 1. A SIDE'S RATING IS THE MEAN OF ITS RATEABLE MEMBERS. The alternatives are
--    the sum (which makes a side's strength depend on how many people are on
--    it, so 3v3 and 1v1 would not share a scale) and a "strongest member"
--    reading (which lets one veteran carry two beginners at no cost to himself
--    and no benefit to them). The mean is the usual choice and it is the one
--    that keeps a 2v2 rating and a 3v3 rating comparable numbers on the same
--    axis, which is exactly what per-format rows are for.
--
--    "Rateable" is load-bearing: a participant with no master-backed identifier
--    has no rating to average in and receives none, so the mean is taken over
--    the members the ladder can actually key. A side with nobody rateable
--    cannot form a comparison and the round moves nothing.
--
-- 2. EVERY MEMBER OF A SIDE TAKES THE WHOLE SIDE DELTA. It is NOT divided
--    between them. Dividing would make a 3v3 win worth a third of a 1v1 win,
--    and since the formats rate separately that would not even show up as an
--    imbalance -- it would show up as 3v3 ratings that never leave the start
--    value, and as an incentive to duel. A win is a win in every format.
--
--    With equal sides -- which arena formats guarantee -- this is still exactly
--    zero-sum: n players gain d each and n lose d each. The only thing that
--    breaks the balance is two players carrying different K (see `kFor`), and
--    that is deliberate and is what FIDE does.
--
-- THE EXCHANGE IS PER ROUND, NOT PER MATCH, and that follows the ladder rather
-- than being chosen: `Scoring.beginRound` clears the board at the start of
-- every arena round, so `arena.lua` already writes the career once per round
-- and a match-level write would record one fifth of a best-of-five. Rating on
-- the same edge means a 3-0 sweep moves a rating further than a 3-2 win, which
-- is a feature and not an accident -- but it also means a best-of-five can
-- exchange five times, which is why `arenaK` is per-ROUND and set well below a
-- conventional per-match K.
--
-- ===========================================================================
-- MODEL 2 -- FREE-FOR-ALL: PAIRWISE PLACEMENT
-- ===========================================================================
--
-- Twelve players, 300 s, kill limit 25, respawns, and no sides at all. There is
-- no S_a and no E_a because there is no opponent. The two standard treatments
-- are a placement model (read the final standings as N(N-1)/2 pairwise results)
-- and a performance-against-the-field model (one expectation from the mean
-- rating of everybody else). This mode uses the FIRST:
--
--     delta_i = K_ffa / (N - 1) * SUM over j /= i of ( S_ij - E_ij )
--
-- Five reasons, and they are about THIS mode rather than about the literature:
--
-- 1. THE FIELD IS FLUID, so a single mean rating describes nobody. Decision 2
--    is that a round in progress is one you can join: `round.lua` places
--    arrivals into a live round and `instances.lua` fills before it spreads. A
--    player who was in the instance for forty seconds is in the standings, and
--    folding him into one field mean would move that mean for everybody who
--    played the whole round. A pairwise comparison against him is just one
--    comparison of eleven, weighted like any other.
--
-- 2. IT IS SCALE-FREE IN KILLS. The kill counts a field produces depend on the
--    weapon in rotation, on the kill limit, and on how long each player was
--    actually in the round -- none of which are properties of the player. An
--    ORDER survives all three.
--
-- 3. N = 2 DEGENERATES TO TEXTBOOK ELO. The same routine therefore rates a
--    twelve-player free-for-all and, if it were ever pointed at one, a duel,
--    and the two cannot drift apart in a way nobody notices.
--
-- 4. IT IS ZERO-SUM BEFORE ROUNDING. S_ij + S_ji = 1 and E_ij + E_ji = 1 for
--    every pair, and every player divides by the same N-1, so the deltas sum to
--    zero and the ladder cannot inflate. (Rounding to whole points costs at
--    most half a point per player; see `roundHalfAway`.)
--
-- 5. DIVIDING BY N-1 MAKES A ROUND WORTH A ROUND. Without it a twelve-player
--    round would move a rating eleven times as far as a duel does, purely
--    because there were more people in the room.
--
-- THE PAIRWISE OUTCOME IS THE SCOREBOARD'S OWN COMPARATOR, minus its last
-- tiebreak. `Scoring.rows` sorts on kills, then fewer deaths, then score, then
-- NAME -- and rating anybody on alphabetical order would be indefensible, so
-- `outcomeBetween` below stops after `score` and calls the rest a draw. What
-- that buys is a guarantee worth more than the third tiebreak: the rating can
-- never disagree with the standings the players just read.
--
-- WHAT THIS MODEL REWARDS: finishing above people it expected you to finish
-- below. Beating a 1400 is worth more than beating a 900, and losing to a 900
-- costs more than losing to a 1400.
--
-- WHAT IT DOES NOT REWARD, stated plainly because a rating whose blind spots
-- are undocumented gets trusted for things it cannot measure:
--
--   * MARGIN. 25-0 and 25-24 are the same first place. A dominant round is
--     worth exactly what a narrow one is worth.
--   * WHO YOU KILLED. The comparison is on final standings, not on the kill
--     graph. Farming the weakest player all round and duelling the leader all
--     round score identically.
--   * SURVIVAL, mostly. Deaths are only the SECOND tiebreak, because that is
--     what the scoreboard does: 11-20 finishes above 10-0.
--   * TIME PLAYED. A latecomer with three kills places last and pays for it.
--     This is the sharpest edge on the model and it is a deliberate trade
--     against reason 1 -- there is no join timestamp in the standings row, and
--     inventing one here would put the rating and the scoreboard on different
--     data.
--   * ASSISTS, damage and everything else in the career row. They are recorded
--     and they do not rate.
--
-- A margin-aware variant is a small change (make S_ij fractional in the kill
-- difference) and is deliberately NOT taken now: it needs a scale nobody has
-- measured, and an unmeasured scale in a rating is worse than a known blind
-- spot.

Deathmatch = Deathmatch or {}

local DM = Deathmatch
local Config = DeathmatchConfig

DM.rating = DM.rating or {}
local Rating = DM.rating


-- --------------------------------------------------------------- tunables --
--
-- Read FRESH on every use and clamped HERE and nowhere else, exactly as
-- `pursuit/server/ranked.lua` does it: the Warden panel can move any of these
-- under a running server, and a number typed into a web form must not be able
-- to put the arithmetic into a state it does not survive.
--
-- The four an operator is most likely to want are declared as live tunables in
-- `Config.tunables` (`ratingEnabled`, `ratingStart`, `ratingArenaK`,
-- `ratingFfaK`); the rest are config, because changing a spread or a floor on a
-- live ladder is a decision to make between seasons rather than between rounds.

local DEFAULTS = {
    enabled = true,
    -- THE BASELINE. A rating means nothing without one, and it is a tunable
    -- rather than a constant for a reason that shows up on the first day: every
    -- unrated player is exactly here, so this number decides whether the ladder
    -- reads as "1000 and climbing" or "1500 and drifting". 1000 matches
    -- `pursuit/server/ranked.lua`, so a player who plays both modes sees one
    -- scale.
    start = 1000,
    -- The rating difference at which the favourite is expected to score 10/11.
    -- 400 is the Elo convention and there is no measurement on this ladder yet
    -- that would justify moving it.
    spread = 400.0,
    -- Nobody falls below this. A rating that can be driven arbitrarily low
    -- stops being a measurement and becomes a punishment.
    floor = 100,
    -- A decisive result that rounds to zero reads as a broken ladder, and it is
    -- a real loophole: at a large enough gap the favourite would win for free.
    minDelta = 1,
    -- PER ARENA ROUND, not per match -- a best-of-five can exchange five times.
    arenaK = 16.0,
    -- PER FREE-FOR-ALL ROUND, after the division by N-1. Higher than the arena
    -- K on purpose: one free-for-all round is 300 s and exchanges ONCE, while a
    -- best-of-five arena match is several exchanges over a comparable stretch
    -- of play. The two K values are what make a minute of arena and a minute of
    -- free-for-all move a rating by roughly the same amount.
    ffaK = 32.0,
    -- A new player's rating is a guess and should move a long way; a settled
    -- player's is evidence and should not.
    provisionalRounds = 10,
    provisionalScale = 2.0,
}
Rating.DEFAULTS = DEFAULTS

local function clampNumber(value, fallback, low, high)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback end
    if n < low then return low end
    if n > high then return high end
    return n
end

local function clampInteger(value, fallback, low, high)
    return math.floor(clampNumber(value, fallback, low, high) + 0.5)
end

-- `DM.tune.<key>` is A CALL BEHIND A METATABLE (see instances.lua), so it is
-- read at the point of use and never captured, and it is wrapped because a
-- server whose `instances.lua` is missing has no registry at all.
local function live(key)
    if key == nil then return nil end
    local tune = DM.tune
    if tune == nil then return nil end
    local ok, value = pcall(function() return tune[key] end)
    if not ok then return nil end
    return value
end

local function configured(key)
    local block = Config ~= nil and Config.rating or nil
    if type(block) == "table" and block[key] ~= nil then return block[key] end
    return nil
end

-- Live tunable, then config, then the default spelled out above -- so a server
-- whose config predates this file still rates.
local function pick(tuneKey, key)
    local value = live(tuneKey)
    if value ~= nil then return value end
    value = configured(key)
    if value ~= nil then return value end
    return DEFAULTS[key]
end

--- Every tunable this file has, clamped. One call per round; pass the result
--- around rather than re-reading, so one round is rated by one set of numbers
--- even if the panel moves them halfway through.
function Rating.settings()
    local s = {
        enabled           = pick("ratingEnabled", "enabled") ~= false,
        start             = clampInteger(pick("ratingStart", "start"), DEFAULTS.start, 100, 5000),
        spread            = clampNumber(pick(nil, "spread"), DEFAULTS.spread, 50.0, 2000.0),
        floor             = clampInteger(pick(nil, "floor"), DEFAULTS.floor, 0, 5000),
        minDelta          = clampInteger(pick(nil, "minDelta"), DEFAULTS.minDelta, 0, 50),
        arenaK            = clampNumber(pick("ratingArenaK", "arenaK"), DEFAULTS.arenaK, 1.0, 100.0),
        ffaK              = clampNumber(pick("ratingFfaK", "ffaK"), DEFAULTS.ffaK, 1.0, 200.0),
        provisionalRounds = clampInteger(pick(nil, "provisionalRounds"), DEFAULTS.provisionalRounds, 0, 100),
        provisionalScale  = clampNumber(pick(nil, "provisionalScale"), DEFAULTS.provisionalScale, 1.0, 5.0),
    }
    -- A floor above the baseline would put every new player instantly
    -- underwater, which is the one configuration the arithmetic cannot mean.
    if s.floor > s.start then s.floor = s.start end
    return s
end


-- ------------------------------------------------------------------- Elo --

--- What we expected of `a` against `b`, 0..1.
function Rating.expected(a, b, spread)
    return 1.0 / (1.0 + 10.0 ^ ((b - a) / (spread or DEFAULTS.spread)))
end

--- Round half AWAY from zero. `math.floor(x + 0.5)` is wrong for negatives --
--- it turns -0.5 into 0 and biases every loss upward by half a point, which
--- over a season is a free ride for whoever loses most.
function Rating.roundHalfAway(value)
    if value >= 0 then return math.floor(value + 0.5) end
    return -math.floor(-value + 0.5)
end

--- The K a player carries into THIS round, from the rated rounds he had BEFORE
--- it. Both players use their OWN K, so a provisional player facing a settled
--- one moves further than his opponent and the exchange is not zero-sum. That
--- is deliberate and is what FIDE does: a ladder is a measurement, not a
--- currency, and refusing to let a beginner converge in order to keep the books
--- balanced would be optimising the wrong thing.
function Rating.kFor(baseK, ratedRounds, s)
    local rounds = math.max(0, math.floor(tonumber(ratedRounds) or 0))
    if rounds < (s.provisionalRounds or 0) then return baseK * (s.provisionalScale or 1.0) end
    return baseK
end

-- A decisive result must move something. Applied only where "decisive" is
-- unambiguous: a side that won or lost an arena round, and a free-for-all
-- finish that beat EVERYBODY or lost to everybody. A mid-table free-for-all
-- finish is genuinely allowed to be worth nothing.
local function enforceMinDelta(delta, actual, maximum, s)
    if s.minDelta <= 0 then return delta end
    if actual >= maximum and delta < s.minDelta then return s.minDelta end
    if actual <= 0.0 and delta > -s.minDelta then return -s.minDelta end
    return delta
end


-- ---------------------------------------------------------- the two models --

--- One participant's result against another, from the SCOREBOARD's comparator
--- with its arbitrary name tiebreak removed. 1 / 0.5 / 0.
local function outcomeBetween(a, b)
    if a.kills ~= b.kills then return a.kills > b.kills and 1.0 or 0.0 end
    if a.deaths ~= b.deaths then return a.deaths < b.deaths and 1.0 or 0.0 end
    if a.score ~= b.score then return a.score > b.score and 1.0 or 0.0 end
    return 0.5
end
Rating.outcomeBetween = outcomeBetween

local function meanRating(side)
    local total = 0.0
    for _, participant in ipairs(side) do total = total + participant.rating end
    return total / #side
end

-- Arena. Two sides, one mean rating each, one expectation, one delta per side,
-- and every member of a side takes the whole of it.
local function twoSided(list, winnerTeam, s)
    local sides = { {}, {} }
    for _, participant in ipairs(list) do
        local side = sides[participant.team]
        if side ~= nil then side[#side + 1] = participant end
    end
    if #sides[1] == 0 or #sides[2] == 0 then
        return nil, "team", "one side had nobody the ladder could key"
    end

    local mean = { meanRating(sides[1]), meanRating(sides[2]) }
    local expectation = { Rating.expected(mean[1], mean[2], s.spread) }
    expectation[2] = 1.0 - expectation[1]

    local actual = { 0.5, 0.5 }
    if winnerTeam == 1 then actual = { 1.0, 0.0 }
    elseif winnerTeam == 2 then actual = { 0.0, 1.0 } end

    local results = {}
    for team = 1, 2 do
        for _, participant in ipairs(sides[team]) do
            local k = Rating.kFor(s.arenaK, participant.rounds, s)
            local delta = Rating.roundHalfAway(k * (actual[team] - expectation[team]))
            results[#results + 1] = {
                key = participant.key,
                before = participant.rating,
                delta = enforceMinDelta(delta, actual[team], 1.0, s),
                k = k,
                expected = expectation[team],
                actual = actual[team],
                team = team,
                sideRating = mean[team],
                opponentRating = mean[3 - team],
                place = (winnerTeam == nil or winnerTeam == 0) and 1
                    or (team == winnerTeam and 1 or 2),
            }
        end
    end
    return results, "team", nil
end

-- Free-for-all. N(N-1)/2 pairwise results read off the final standings,
-- normalised by N-1 so one round is worth one round.
local function pairwise(list, s)
    local count = #list
    if count < 2 then return nil, "pairwise", "a field of one cannot be rated" end

    -- Placement is reported, never used in the arithmetic: the deltas below are
    -- order-independent by construction, and this exists only so a readout can
    -- say where somebody finished.
    local order = {}
    for index, participant in ipairs(list) do order[index] = participant end
    table.sort(order, function(a, b)
        local outcome = outcomeBetween(a, b)
        if outcome ~= 0.5 then return outcome > 0.5 end
        return a.key < b.key
    end)
    local place = {}
    for index, participant in ipairs(order) do place[participant.key] = index end

    local results = {}
    for _, participant in ipairs(list) do
        local scored, expectedScore = 0.0, 0.0
        for _, other in ipairs(list) do
            if other ~= participant then
                scored = scored + outcomeBetween(participant, other)
                expectedScore = expectedScore
                    + Rating.expected(participant.rating, other.rating, s.spread)
            end
        end
        local k = Rating.kFor(s.ffaK, participant.rounds, s)
        local delta = Rating.roundHalfAway(k * (scored - expectedScore) / (count - 1))
        results[#results + 1] = {
            key = participant.key,
            before = participant.rating,
            -- `count - 1` is the maximum attainable, so a sweep and a whitewash
            -- are the only two finishes the minimum applies to.
            delta = enforceMinDelta(delta, scored, count - 1, s),
            k = k,
            expected = expectedScore / (count - 1),
            actual = scored / (count - 1),
            team = 0,
            place = place[participant.key],
            field = count,
        }
    end
    return results, "pairwise", nil
end


-- ------------------------------------------------------------- the entry --

--- Is this format a two-sided contest? Asked of the DATA (`Config.formats`)
--- rather than of a hardcoded list of names, so a format added to the config
--- rates without an edit here.
function Rating.isTwoSided(mode)
    local formats = Config ~= nil and Config.formats or nil
    local spec = type(formats) == "table" and formats[tostring(mode)] or nil
    if type(spec) ~= "table" then return false end
    return (tonumber(spec.teams) or 0) >= 2
end

--- Rate one finished round.
---
--- `participants` is an array of
---   `{ key, rating, rounds, kills, deaths, score, team }`
--- where `key` is opaque -- this file never sees a player id, a name or an
--- identifier, only something to hang a result on. `opts.winnerTeam` is 1, 2 or
--- nil (a draw) and matters only to a two-sided format.
---
--- Returns `results, model, note`. `results` is nil when the round cannot be
--- rated at all, and `note` says why.
function Rating.round(mode, participants, opts)
    opts = type(opts) == "table" and opts or {}
    local s = opts.settings or Rating.settings()
    if not s.enabled then return nil, "disabled", "rating is disabled in this server's config" end

    local twoSidedFormat = Rating.isTwoSided(mode)

    local list = {}
    local seen = {}
    for _, participant in ipairs(participants or {}) do
        if type(participant) == "table" and type(participant.key) == "string"
            and not seen[participant.key] then
            seen[participant.key] = true
            list[#list + 1] = {
                key = participant.key,
                rating = clampInteger(participant.rating, s.start, 0, 100000),
                rounds = math.max(0, math.floor(tonumber(participant.rounds) or 0)),
                kills = math.floor(tonumber(participant.kills) or 0),
                deaths = math.floor(tonumber(participant.deaths) or 0),
                score = math.floor(tonumber(participant.score) or 0),
                team = math.floor(tonumber(participant.team) or 0),
            }
        end
    end
    if #list < 2 then
        return nil, twoSidedFormat and "team" or "pairwise",
            "fewer than two rateable participants"
    end

    local results, model, note
    if twoSidedFormat then
        results, model, note = twoSided(list, opts.winnerTeam, s)
    else
        results, model, note = pairwise(list, s)
    end
    if results == nil then return nil, model, note end

    -- THE FLOOR IS APPLIED HERE AND THE DELTA IS THEN CORRECTED TO MATCH, so
    -- the number written to the database as a delta and the number added to the
    -- in-memory rating can never disagree about where a player ended up.
    local baseK = twoSidedFormat and s.arenaK or s.ffaK
    for _, result in ipairs(results) do
        local after = result.before + result.delta
        if after < s.floor then after = s.floor end
        result.after = after
        result.delta = after - result.before
        result.provisional = result.k > baseK + 1e-9
    end
    return results, model, note
end

--- One line saying what the model currently is, for `/dm.stats` and for the
--- operator readout. A rating nobody can see the parameters of is a magic
--- number with a database behind it.
function Rating.describe(s)
    s = s or Rating.settings()
    if not s.enabled then return "rating DISABLED in config" end
    return ("start %d, spread %d, K arena %g/round FFA %g/round, floor %d, first %d round(s) at x%g")
        :format(s.start, s.spread, s.arenaK, s.ffaK, s.floor,
            s.provisionalRounds, s.provisionalScale)
end
