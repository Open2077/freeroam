# Open77 Freeroam

`freeroam` is the default example game mode shipped with the Open77 dedicated server. It provides
configurable player spawning, automatic respawn, curated weapon loadouts, server-owned vehicles,
named destinations, map blips, PvP with spawn protection and a kill feed, and player/admin tools.

> [!NOTE]
> This resource is a reference implementation for development servers. Review its commands,
> permissions, spawn points, and vehicle policy before using it on a public server.

## Install

This repository contains **only the `freeroam` gamemode**, version **0.7.0**:
the sandbox, integrated Race and PvP activities, animation menu, and their WebUI.
It is not a standalone dedicated server or an installation of the Open77 platform.

Use a compatible Open77 dedicated server and official resource set. The animation
menu requires the RP-enabled client **2.31.13+op77.45** or later, its matching
server runtime, and `open77_animations`.

From your server directory, clone into an unused resource directory:

```sh
git clone https://github.com/Open2077/freeroam.git resources/gamemodes/freeroam
```

If Freeroam is already installed there, back up that installation and its `data/`
before replacing it. Do not install a second resource named `freeroam` alongside it.
The declared direct dependencies are:

| Resource | Minimum version |
|---|---|
| `open77_weapons` | `0.1.0` |
| `open77_props` | `0.1.0` |
| `open77_worldui` | `0.1.0` |
| `open77_zones` | `0.1.0` |
| `open77_notifications` | `1.0.0` |
| `open77_animations` | `1.0.0` |

Install these and their transitive dependencies from the matching platform
distribution. Preserve the normal session shell, readiness, appearance and life
services of your server. Wardrobe, weather, voice, admin and other system resources
are configured separately; none is bundled into this repository.

Make the directory and dependencies discoverable under `resources.root` and
`resources.load`, then start the server. On a running development server, use
`refresh` followed by `ensure freeroam` in the **server console**; an existing
resource will restart. Do not additionally run the standalone Race or Deathmatch
gamemodes. Configure `shared/config.lua`, `race/shared/config.lua` and
`pvp/shared/config.lua` / `pvp/shared/freeroam.lua` for your server.

Runtime `data/`, recorded courses, credentials, server configuration and compiled
platform binaries are deliberately excluded. Race starts with no saved courses;
create them with `/race.editor`. Back up `data/` independently when updating.
Database persistence uses the server's configured bridge, never credentials in
this resource's shared scripts.

See [resource setup](https://open2077.net/docs/resource-runtime) and
[RP animations](https://open2077.net/docs/rp-animations).

## Structure

| Path | Responsibility |
|---|---|
| `open77.lua` | Manifest, scripts, dependencies, and required permissions. |
| `shared/config.lua` | Spawn points, destinations, vehicle/weapon catalogs, quotas, player tools, and blips. |
| `server/main.lua` | Commands, validated menu actions, weapon requests, respawn policy, vehicle ownership, and teleport transactions. |
| `server/combat.lua` | PvP policy: friendly fire, spawn safe zones, multipliers, and the kill-feed broadcast. |
| `client/main.lua` | Client readiness, map blips, the `/freeroam` menu, the custom HUD, and scoreboard. |
| `client/animations.lua` | RP catalogue and playback controls through the public asynchronous animation API. |
| `client/killfeed.lua` | Combat feedback HUD: kill feed, authoritative hitmarker, damage flash. |
| `web/` | HTML/CSS/JS menu, custom gameplay HUD, scoreboard, and kill-feed surfaces rendered by the Open77 WebUI. |

`shared/config.lua` is downloaded by clients. Never place credentials or private server data in it.

## Menu

`/freeroam` opens a WebUI menu (`layer = "menu"`) with seven sections:

- **Vehicles** provides a searchable, category-filtered catalog, including pilotable AVs under
  the **AV** filter, optional custom `Vehicle.*` records, a live owned/maximum counter, and
  repair/engine/lock/light controls for the latest owned vehicle.
- **Weapons** assigns one of the configured templates to slots 1–3, displays the current loadout,
  changes reserve and magazine ammunition, activates or clears a slot, and holsters the weapon.
- **Travel** lists named destinations and spawn points and accepts explicit coordinates.
- **Player** returns to spawn, restores health and armor, revives, toggles god mode, or enters the
  normal death/respawn flow. Its status strip reflects authoritative health, armor, and god mode.
- **Race** opens the integrated race activity and course creator.
- **Animations**, also opened by `/anim`, provides 70 variants in 12 families:
  searchable categories, local favourites, looping/timed actions, **Play & Close**
  and **Stop**. Playback uses `open77_animations` and its server-validated public
  API; no raw clip execution or extra WebUI surface is introduced. The default
  smoke clip is locally checked on the male F7 proxy; other clips remain experimental.
- **PvP** offers free-for-all, 1v1, 2v2 and 3v3, a weapon/kit picker, optional training bots,
  queue status and a leave action. Sandbox mutations are blocked while an activity owns the player.

The page surface remains visible but fully transparent while closed, which avoids the CEF repaint
failure seen when a hidden surface is shown later. The server answers the command with
`freeroam:menu:open`; sandbox button presses return as the `freeroam:menu` net event, are throttled per
player, validated server-side, and executed by an authoritative API. `ESC` closes the menu;
teleport-style actions close it automatically.

## Race activity

Race is built into this gamemode. `/race`, the **RACE** menu tab and the configurable
world terminal all open the same activity drawer. Queueing leaves the player in the city;
a heat temporarily owns their vehicle, life and routing bucket, then returns them to their
captured Freeroam position. The complete ACL-gated course creator remains available via
`/race.editor` and the editor button. See [Race setup and editor controls](race/README.md).

## PvP activity

`/pvp` or the **PVP** tab opens the combat activity. `/pvp.join` enters free-for-all;
`/pvp.leave` cancels the queue or leaves the match. Arena queues leave players free to explore
the city until a match forms. Race and PvP reservations are mutually exclusive.

Combat rules run inside `freeroam`; do **not** additionally load `open77_deathmatch` or
`open77_deathmatch_hud` on this server. Those resources remain available for standalone PvP servers.
See [PvP configuration, lifecycle and limitations](pvp/README.md).

## Design-system HUD

Every freeroam-owned surface follows the Open77 Design System: the drawer menu, player/vehicle HUD,
scoreboard, killfeed, hitmarker, and damage vignette. [web/design-system.css](web/design-system.css) is the production,
offline-safe transcription of those tokens. The reference kit uses public font and icon CDNs;
the game resource deliberately does not. Its four typography roles resolve to installed Windows
fallbacks and the few HUD graphics are CSS geometry, so the UI never needs the network to paint.

A compact bottom-right chat-command hint lists `/freeroam`, `/race`, `/pvp` and `/anim`.
It is non-interactive and disappears while a Freeroam/PvP menu, Race panel/editor,
race, PvP match or PvP queue owns the view, and while dead or waiting for stats.
Hints and activity cards reserve the bottom 96 CSS pixels for the optional
`open-voice` indicator and its transient error; both align to its 32px right inset.
The hint uses the existing offline tokens and respects reduced-motion preferences.

The HUD replacement has a fail-open lifecycle:

1. `web/hud.html` loads and acknowledges `freeroam:hud:ready`.
2. The client obtains a real `Open77.stats` snapshot; page readiness alone is not enough.
3. Only then does the resource claim `health`, `stamina`, `weapon`, and `speedometer` through
   `Open77.hud.setVisible` and hide their vanilla widgets.
4. If either the page or the stats API is unavailable, the vanilla widgets stay visible instead of leaving the player
   without combat information.
5. Stopping or reloading the resource releases every claim.

Health, stamina, armor, active weapon/ammunition, vehicle speed, gear, RPM, and integrity are read
from the public `Open77.stats`, `Open77.weapons`, and `Open77.vehicles` APIs. No value is simulated
in JavaScript. Vitals and weapon/ammunition are anchored at the bottom-left; vehicle speed uses a
compact circular gauge at bottom-center whose 270-degree outline fills against the reported speed.
The multiplayer policy suppresses the vanilla quickslots that normally own the left region. The vanilla minimap,
compass, and clock are intentionally retained: they remain the owner of the native GPS route and
mappin projection and are outside the freeroam redesign.

The browser never supplies an arbitrary weapon template. It sends a short catalog key, and the
server resolves that key through `weapons.catalog` before calling `Open77.weapons`. Weapon
operations are asynchronous: the menu shows the queued result, then receives the authoritative
slot/ammunition snapshot after the client confirms the operation.

Menu mutations are refused when `restrictPlayerCommands = true`, because net events bypass the
ACL enforcement performed by the command dispatcher — players are told to use the ACL-checked
commands instead.

## Player commands

| Command | Description |
|---|---|
| `/freeroam` | Open the menu UI. |
| `/car [model]` | Spawn a server-owned vehicle near the player. |
| `/dv [all]` | Remove the latest owned vehicle, or every owned vehicle. |
| `/goto <location>` | Move to a configured destination. |
| `/tpc <x> <y> <z> [heading]` | Move to world coordinates. |
| `/locations` | List configured destinations. |
| `/spawn [name]` | Return to a configured spawn point. |
| `/suicide` | Enter the authoritative death flow. |
| `/revive` | Revive in place when dead. |
| `/players` | List known players and their life phase. |
| `/freeroam.status` | Show game-mode diagnostics. |
| `/freeroam.help` | Show available commands. |

Vehicle names can be configured keys such as `hella`, `caliburn`, and `kusanagi`, or full
`Vehicle.*` records when `allowCustomModels` is enabled. See the
[vehicle model catalog](https://github.com/Open2077/open77-base/blob/main/docs/vehicle-models.md).

The shipped `AV` category exposes the flight-capable records supported by the client. Select one
from `/freeroam` exactly like a ground vehicle; it is delivered with extra vertical clearance and
enters the replicated flight controller when the player takes the driver seat.

Weapon templates are player-accessible only through the menu allowlist. The separate ACL-gated
`/weapon.give`, `/weapon.ammo`, and `/weapon.remove` commands remain available to administrators;
see the [weapon API guide](https://github.com/Open2077/open77-base/blob/main/docs/weapon-api.md).

## Administrative commands

```text
/noclip [on|off]
/fly [on|off]
/freeroam.tp <playerId> <location>
/freeroam.respawn <playerId> [spawn]
/freeroam.revive <playerId>
/freeroam.cleanup
```

`/noclip` and `/fly` are ACL-delegated client capabilities: the dispatcher checks `command.noclip` /
`command.fly`, then the server sends `freeroam:travel` and the client resource flips the switch
through its `player.travel` permission. The native lab commands (`noclip`, `fly`, `tp`, `move.*`,
`godmode`, spawning, memory access, ...) are refused by the client while a multiplayer session is
active, so this ACL-checked path is the only way to reach them online.

Administrative commands require `command.freeroam.*`. Set `restrictPlayerCommands = true` to place
player commands behind their corresponding ACL permissions as well.

## PvP

PvP rides on the engine-level damage authority (see `docs/combat.md`): the attacker's game computes
hits through the vanilla pipeline, the server validates and owns every health point, and kills are
attributed through the life service. `server/combat.lua` only sets policy:

- `combat.pvpEnabled` turns friendly fire on (the platform default is off).
- `combat.safeZoneRadius` cancels all damage given or received near any configured spawn point,
  through a `Open77.combat.onDamage` arbiter.
- `combat.damageMultiplier` / `combat.headshotMultiplier` scale the server ledger.
- `combat.regenPerSecond` grants passive regeneration to every connecting player.
- `combat.killfeed` controls the broadcast rendered by `client/killfeed.lua`: attributed kills show
  `killer ELIM victim`, unattributed deaths show the victim only. The same surface renders the
  server-confirmed hitmarker (`open77:hitConfirmed`, amber on headshot, magenta on kill) and the
  incoming-damage vignette (`open77:localDamaged`).

## Configuration

All game-mode settings live in `shared/config.lua` under `FreeroamConfig`:

- `spawn.points` defines names, labels, positions, and headings.
- `spawn.selection` selects `random`, `nearest`, or `first`.
- `autoRespawn`, `respawnDelayMs`, `health`, and `graceMs` control recovery.
- `teleport.locations` defines `/goto` destinations.
- `vehicles.catalog` controls the searchable garage entries. Each entry has a unique `key`, a
  player-facing `label`, a `category`, and an exact `Vehicle.*` `record`.
- `vehicles.maxPerPlayer` limits server-owned vehicles per player. Once the limit is reached, a
  successful spawn recycles the oldest vehicle. Set it to `0` for no limit.
- `vehicles.allowCustomModels`, `defaultModel`, and `spawnOffset` control custom records and
  delivery. Vehicles otherwise remain until `/dv`, administrative cleanup, or resource removal.
- `weapons.catalog` is the player menu allowlist. Entries use `key`, `label`, `category`, an exact
  `Items.*` `record`, and optional `melee = true` to suppress automatic ammunition.
- `weapons.defaultReserve` is loaded after a firearm is assigned;
  `weapons.maximumReserve` bounds player-entered reserve values.
- `player.allowRestore`, `player.allowGodMode`, and `player.armorOnRestore` control the Player tab.
- `blips` controls destination and spawn markers.

Bundled coordinates are examples validated against Cyberpunk 2077 2.31. Server operators should
replace them with locations appropriate for their game mode.

## WebUI smoke test

In the full [platform repository](https://github.com/Open2077/open77-base),
`node scripts/freeroam-webui-smoke.mjs` loads the shipped pages in the
installed headless Edge, injects a recording Open77 bridge, renders all four menu tabs plus the
foot HUD, vehicle HUD, scoreboard, and killfeed at 1920×1080, rejects menu overflow, validates
their state/event contracts, and verifies the important action payloads. It writes screenshots to
`artifacts/freeroam-*.png`. This checks every browser surface without starting the game;
authoritative Lua behavior remains covered by `FreeroamIntegrationTests` in that
repository. These platform test tools are not bundled here. The local checkpoint
regression fixture is retained under `race/tests/`.

## Runtime behavior

### Teleportation

The current life API performs teleportation through an authoritative kill-and-respawn transaction.
The client applies the complete respawn sequence, including streaming preparation, fade behavior,
and the configured grace period.

### Automatic respawn

The server schedules respawn after a canonical dead-state event and revalidates the state when the
delay expires. Administrative recovery during the delay therefore cancels the pending respawn.

### Vehicle ownership

Vehicles are tracked per authenticated player. When `maxPerPlayer` is positive, successful spawns
recycle the oldest owned vehicle; removal events clean the ownership ledger regardless of which
system removed it.

### Presence

The protected session shell announces `open77:session:gameplayReady` only after the real Night City
world and player puppet are attached. Freeroam applies its forced join spawn from that event;
`freeroam:ready` remains only as compatibility for older clients. Player listings discard sessions
whose names can no longer be resolved by the authoritative server.

See the [ACL guide](https://open2077.net/docs/server-acl),
[life-system design](https://github.com/Open2077/open77-base/blob/main/docs/research/multiplayer-death-ragdoll-revive-and-respawn.md),
and repository [license](LICENSE), preserved from the Open77 platform.
