-- PvP is an opt-in activity. The city never becomes a fenced Deathmatch lobby.
DeathmatchConfig.buckets.lobby = 0
-- Freeroam has one public FFA, not a pool of twelve-player shards. Private
-- queued arena matches retain their separate routing range and capacity.
DeathmatchConfig.buckets.ffaLast = DeathmatchConfig.buckets.ffaFirst
DeathmatchConfig.instances.ffaCeiling = 1
DeathmatchConfig.instances.ffaCapacity = 32
DeathmatchConfig.tunables.ffaCeiling.value = 1
DeathmatchConfig.tunables.ffaCeiling.max = 1
DeathmatchConfig.tunables.ffaCeiling.description = "Freeroam always uses one shared free-for-all."
DeathmatchConfig.tunables.ffaCapacity.value = 32
DeathmatchConfig.tunables.ffaCapacity.max = 128
DeathmatchConfig.tunables.ffaCapacity.description = "Player limit for the shared FFA. A full FFA never opens another instance."
DeathmatchConfig.instances.adoptOnReload = false
DeathmatchConfig.freeroam = true
DeathmatchConfig.sfx = {
    enabled = true,
    select = "ui_menu_onpress",
    join = "ui_menu_onpress",
    tick = "sq024_race_countdown",
    start = "sq024_race_start",
    result = "sq024_race_finish",
}
DeathmatchConfig.strings.notice.leftMatch = {
    title = "FREEROAM", body = "Returning to your position in the city.",
}
