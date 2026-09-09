-- One owner for a player's life, travel and sandbox tools. Queueing alone does
-- not own gameplay: players remain free to explore while waiting for a match.
FreeroamActivities = {}
function FreeroamActivities.ownsPlayer(playerId)
    return (FreeroamRace and FreeroamRace.ownsPlayer(playerId))
        or (FreeroamPvp and FreeroamPvp.ownsPlayer(playerId)) or false
end
