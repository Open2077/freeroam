resource "freeroam"
version "0.7.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

dependency "open77_weapons >=0.1.0"
dependencies {
    "open77_props >=0.1.0",
    "open77_worldui >=0.1.0",
    "open77_zones >=0.1.0",
    "open77_notifications >=1.0.0",
    "open77_animations >=1.0.0",
}

shared_script "shared/config.lua"
shared_script "race/shared/config.lua"
shared_script "race/shared/checkpoints.lua"
shared_script "pvp/shared/config.lua"
shared_script "pvp/shared/kabuki.lua"
shared_script "pvp/shared/freeroam.lua"
server_script "server/activities.lua"
server_script "pvp/server/instances.lua"
server_script "pvp/server/mapstore.lua"
server_script "pvp/server/bounds.lua"
server_script "pvp/server/loadout.lua"
server_script "pvp/server/scoring.lua"
server_script "pvp/server/bots.lua"
server_script "pvp/server/round.lua"
server_script "pvp/server/arena.lua"
server_script "pvp/server/rating.lua"
server_script "pvp/server/ranked.lua"
server_script "pvp/server/survey.lua"
server_script "pvp/server/main.lua"
server_script "pvp/server/freeroam.lua"
server_script "race/server/courses.lua"
server_script "race/server/main.lua"
server_script "server/main.lua"
server_script "server/combat.lua"
client_script "client/main.lua"
client_script "client/animations.lua"
client_script "client/killfeed.lua"
client_script "race/client/checkpoints.lua"
client_script "race/client/main.lua"
client_script "pvp/client/bounds.lua"
client_script "pvp/client/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
    "local.events",
    "network.events",
    "world.vehicles",
    "world.props",
    "world.effects",
    "world.npcs",
    "world.safeareas",
    "player.weapons.edit",
    "database.access",
    "vehicles.performance",
    "input.actions",
    "filesystem.read",
    "filesystem.write",
    "players.life.read",
    "players.life.kill",
    "players.life.revive",
    "players.life.respawn",
    "players.damage.read",
    "players.damage.apply",
    "players.stats.read",
    "players.stats.apply",
    "combat.config",
    "player.travel",
    "player.equipment.edit",
    "player.weapons.read",
    "vehicles.read",
    "ui.vanilla.map",
    "ui.vanilla.hud",
    "ui.nameplates"
}
