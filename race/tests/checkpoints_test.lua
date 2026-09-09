local function point(x, y, z, bucket) return { x=x, y=y, z=z or 0, bucket=bucket or 1 } end
local target = point(0, 0)
local function crosses(a, b) return RaceCheckpointGeometry.crossed(a, b, target, 7, 4, 80) end
assert(crosses(nil, point(7, 0)), "inclusive acceptance edge")
assert(not crosses(nil, point(7.01, 0)), "outside radius")
assert(crosses(point(-20, 0), point(20, 0)), "fast crossing between samples")
assert(crosses(point(-20, 0, 10), point(20, 0, -10)), "sloped crossing with both endpoints outside altitude")
assert(not crosses(point(-20, 0, 14), point(20, 0, 0)), "altitude becomes valid only after leaving the zone")
assert(not crosses(point(-20, 0, 8), point(20, 0, 8)), "bridge above the checkpoint")
assert(not crosses(point(-20, 8), point(20, 8)), "miss beside zone")
assert(not crosses(point(-60, 0), point(60, 0)), "teleport cannot sweep a checkpoint")
assert(not crosses(point(-20, 0, 0, 2), point(20, 0)), "bucket changes cannot sweep")
assert(not crosses(point(8, 0), point(8, 0)), "stationary outside")
assert(crosses(point(0, 0, 8), point(0, 0, -8)), "vertical segment intersects cylinder")

local clock, creates, updates, removes, fail = 0, 0, 0, 0, false
local current, alive
Open77 = {
    time = { monotonic = function() return clock end },
    log = { info = function() end, warn = function() end },
    anchors = {
        create = function(options)
            creates = creates + 1
            current, alive = options, true
            return "9007199254740993"
        end,
        update = function(id, options)
            assert(id == "9007199254740993", "native IDs must stay lossless")
            updates = updates + 1
            if fail then return false, "not_found" end
            current = options
            return true
        end,
        remove = function() removes = removes + 1; alive = false end,
    },
}
local state = { phase="grid", participant=true, heatId=1, lap=1, laps=2, totalCheckpoints=2,
    nextCheckpoint={ id="cp1", index=1, position=point(12, 24, 8), radius=9 } }
RaceCheckpointVisual.sync(state)
assert(creates == 1 and current.presentation.radius == 9, "zone uses server radius")
assert(current.render == "ring" and current.presentation.accent == "#22D8E2")
state.phase = "active"
for i=1,30 do clock = i / 4; RaceCheckpointVisual.sync(state) end
assert(creates == 1 and updates == 0 and removes == 0 and alive,
    "same target never expires or respawns, even after local player passage")
state.nextCheckpoint = { id="cp2", index=2, position=point(34, 56, 8), radius=7 }
RaceCheckpointVisual.sync(state)
assert(updates == 1 and current.position.x == 34, "retarget only on server confirmation")
assert(current.presentation.accent == "#22D8E2", "lap line is not the final finish")
state.lap = 2
RaceCheckpointVisual.sync(state)
assert(current.presentation.accent == "#F0F3F6", "final finish gets a distinct visual")
fail = true
state.nextCheckpoint.position = point(35, 56, 8)
RaceCheckpointVisual.sync(state)
assert(not alive and removes == 1, "lost handle clears stale destination")
fail = false
RaceCheckpointVisual.sync(state)
assert(creates == 1, "retry throttled")
clock = clock + 1.1
RaceCheckpointVisual.sync(state)
assert(creates == 2 and alive, "lost handle recovers")
state.nextCheckpoint = nil
RaceCheckpointVisual.sync(state)
assert(not alive and removes == 2, "finish clears the zone")
state.participant = false
RaceCheckpointVisual.sync(state)
assert(removes == 2, "cleanup is idempotent")
