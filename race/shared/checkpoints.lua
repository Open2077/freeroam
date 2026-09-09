RaceCheckpointGeometry = {}

-- Intersection of the travelled segment with the actual checkpoint cylinder.
-- Testing the endpoint's altitude against the segment's horizontal closest point
-- accepts roads on another level and can miss legitimate fast downhill passes.
function RaceCheckpointGeometry.crossed(previous, current, target, radius, height, maxSegment)
    local dx, dy, dz = current.x - target.x, current.y - target.y, current.z - target.z
    if dx * dx + dy * dy <= radius * radius and math.abs(dz) <= height then return true end
    if previous == nil or previous.bucket ~= current.bucket then return false end
    local vx, vy, vz = current.x - previous.x, current.y - previous.y, current.z - previous.z
    if vx * vx + vy * vy + vz * vz > maxSegment * maxSegment then return false end
    local px, py, pz = previous.x - target.x, previous.y - target.y, previous.z - target.z
    local enter, leave = 0.0, 1.0
    local a = vx * vx + vy * vy
    local c = px * px + py * py - radius * radius
    if a < 0.000001 then
        if c > 0 then return false end
    else
        local b = 2 * (px * vx + py * vy)
        local discriminant = b * b - 4 * a * c
        if discriminant < 0 then return false end
        local root = math.sqrt(discriminant)
        enter = math.max(enter, (-b - root) / (2 * a))
        leave = math.min(leave, (-b + root) / (2 * a))
    end
    if math.abs(vz) < 0.000001 then
        if math.abs(pz) > height then return false end
    else
        local low, high = (-height - pz) / vz, (height - pz) / vz
        enter = math.max(enter, math.min(low, high))
        leave = math.min(leave, math.max(low, high))
    end
    return enter <= leave
end
