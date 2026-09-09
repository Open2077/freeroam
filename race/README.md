# Freeroam / Race

Server-authoritative N-player street racing with vehicle grids, personal checkpoint zones, live ranking,
GPS/HUD guidance, finish windows, and an ACL-gated in-game course creator.

Race is a submode of `freeroam` (0.6.0+), not a second gamemode. Start `freeroam`;
its manifest loads the Race engine in the same Lua VM, and its menu owns the shared
WebUI surface. The legacy `race` resource is only a dependency alias for old profiles.

## Entering a race

Use `/race`, the **RACE** tab in `/freeroam`, or the world terminal. Menu browsing and
queueing keep the player in Freeroam. Only a starting heat takes its drivers into the
isolated race bucket. Finishing or forfeiting restores the position and bucket captured
when the player left Freeroam. Sandbox teleports and respawns cannot override a driver
or an editor session.

Configure the terminal in `race/shared/config.lua`, under `RaceConfig.lobby`:
`center` plus `start.offset` define its world position; `start.radius`, `label`,
`holdSeconds` and `maxDistance` tune its interaction. Set `start.enabled = false`
to use commands and the menu only. `/race` remains available everywhere.

## Checkpoint guidance

Drive into the cyan zone around the GPS point. The circle uses the server's exact
checkpoint radius; it advances only when the server accepts the passage, together
with the GPS point and HUD counter. There are no shared solo quest portals or
look-ahead gates competing with the active target. The last target on the last lap
is white and labelled **FINISH LINE**. Ordinary checkpoint, lap and finish cues are
distinct; a lap cue is no longer immediately overwritten by a checkpoint pulse.

The native ring follows terrain and respects world occlusion. At long range or
behind a building, use the minimap GPS and the top-centre direction arrow. Tune
`visuals.checkpointViewDistance` for its visible range; `visuals.enabled = false`
disables the world ring without disabling guidance or checkpoint authority.
Acceptance checks a bounded swept cylinder between server position samples, so
fast/sloped passages are detected. The default altitude tolerance is 4 m to avoid
accepting another road level; server owners can tune `engine.checkpointZTolerance`.

## Creating a course

Grant the operator `command.race.editor` (or `command.race.*`) in `acl.jsonc`, then run:

```text
/race.editor
/race.editor <existing-course-id>
```

The command opens drive mode from Freeroam, keeps the administrator at their current Night City
position, spawns a disposable editor car, and enables a compact non-interactive drive HUD. The
normal game controls remain active. Enter the car, drive the route, and use the mapped actions:

| Default | Editor action |
|---|---|
| `F4` | Respawn the selected editor car in front of the administrator. |
| `F5` | Open the focused metadata/catalogue panel and choose the race vehicle. `Escape` closes only that panel. |
| `F6` | Capture or replace the start/finish reference. |
| `F7` | Add the current pose as an exact vehicle grid slot. |
| `F8` | Add the current pose as the next checkpoint. |
| `F9` / `F10` | Undo the last checkpoint / grid slot. |
| `F11` | Save the current course atomically. |
| `End` | Leave drive mode, remove its car, and return to the captured Freeroam position. |

All actions are registered through `RegisterKeyMapping`. Their effective bindings are shown in the
HUD and can be changed under **Pause → Settings → KEY BINDINGS**. The focused panel is only needed
to edit the course name, description, format, laps, radius and race vehicle, or to load/select/delete catalogue
entries. For each capture, orient the car—or the camera while on foot—in the intended driving
direction:

1. Capture the start/finish reference.
2. Add one exact vehicle grid slot per supported racer. The server rejects slots closer than
   `editor.minimumGridSpacing`, so authored vehicles cannot spawn on top of each other.
3. Drive or move along the route and add checkpoints in crossing order.
4. Open options, choose circuit/sprint, laps, gate radius, name, description and the allow-listed
   race vehicle. `F4` replaces the disposable editor car so the selection can be previewed.
5. Close the panel, then save from drive mode.

Positions always come from server authority: from the canonical editor-car transform while its
driver seat is occupied, otherwise from `Open77.players.position`. The WebUI supplies no position;
the client bridge supplies only vehicle/body heading, so a browser payload cannot forge coordinates.
Every editor network action is ignored
unless `/race.editor` previously created a live ACL-authorized session for that player.

Courses are stored atomically as one JSON document each:

```text
resources/gamemodes/freeroam/data/race/courses/<course-id>.json
resources/gamemodes/freeroam/data/race/race-settings.json
```

Course files use schema version 2 and contain `vehicle`, `start`, ordered `grid`, ordered
`checkpoints`, author metadata, and revision. `vehicle` is a stable ID resolved exclusively through
`engine.vehicles`; a JSON or browser payload cannot inject an arbitrary TweakDB record. Existing
schema-1 courses are upgraded atomically on load and receive the configured default vehicle. Files
are loaded and validated when the resource starts or reloads. Invalid JSON, unsupported schemas,
overlapping grid slots, unsafe IDs, unknown vehicle IDs, or out-of-range coordinates are logged and
skipped rather than partially entering the live catalogue.

The gamemode ships no built-in or sample circuit. Only editor-created or deliberately installed JSON
files enter the live catalogue and random rotation. Every route requires an explicitly captured grid;
its number of saved grid slots is also that course's queue capacity, bounded by `engine.maxRacers`.

## Commands and ACL

| Command | ACL | Purpose |
|---|---|---|
| `/race` | public | Open Freeroam's Race activity menu. |
| `/race.join`, `/race.leave`, `/race.status` | public | Queue, leave, or inspect current state. |
| `/race.course.list` | public | List available courses and formats. |
| `/race.course.select <id>` | `command.race.course.select` | Select a one-heat override. |
| `/race.force` | `command.race.force` | Start with the current queue. |
| `/race.editor [id]` | `command.race.editor` | Open the course creator. |
| `/race.where [player]` | public diagnostic | Print server position/checkpoint state. |
| `/race.probe <x> <y> <z> [heading]` | `command.race.probe` | Validate a surveyed point in game. |

The recommended `operator` ACL role already grants `command.race.*`. The resource manifest grants
`filesystem.read` and `filesystem.write` only to its own `data/` directory through `Open77.io`;
that resource capability is separate from the player-facing command ACL.

## Layout

```text
freeroam/open77.lua               manifest, dependencies, server capabilities
freeroam/race/shared/config.lua   engine/editor/presentation limits and world terminal
freeroam/race/server/courses.lua  JSON catalogue, validation, selection, revisions
freeroam/race/server/main.lua     queue, grids, vehicles, checkpoints, ACL editor sessions
freeroam/race/client/main.lua     projection, control locks, mapped drive-editor actions
freeroam/web/index.html          shared Freeroam / Race page
freeroam/web/race/               activity presentation and design-system theme
freeroam/data/race/courses/      runtime-created custom JSON courses
```

## Authority rules

- Player and vehicle placement uses the server life/vehicle APIs; the WebUI never supplies a world
  position.
- Forming a grid reserves each authoritative driver seat with
  `Open77.vehicles.warpPlayerIntoVehicle(..., { moveBucket = true, exitLocked = true })`. The
  assignment itself keeps an arbitrarily distant vehicle in that player's interest set, so racers
  are streamed and mounted automatically instead of being placed beside a car and asked to press
  `F`. The countdown starts only after the client confirms the native workspot mount and clears the
  durable `ForcedEntry` flag.
- `engine.gridLoadSeconds` is a minimum loading window, set to 20 seconds locally. Early seat
  confirmations do not shorten it; after it expires, the `3, 2, 1, GO!` sequence begins as soon as
  every remaining driver is ready. `engine.gridReadySeconds` remains the longer failure timeout for
  a client that never completes its mount.
- During both the loading window and the `3, 2, 1` countdown, the client combines
  `Open77.vehicles.setControlLock` with `Open77.vehicles.setFrozen`. The first suppresses live
  throttle/brake/reverse input; the second disables the native chassis physics mask so inertia,
  gravity or another collision cannot move the car off its mark. GO wakes physics before restoring
  inputs in the same Lua tick.
- The exit lock stays authoritative through grid, countdown, active racing and results. Forfeit and
  heat cleanup use `forcePlayerOutOfVehicle`, keep the car alive for the native dismount window,
  then remove it and return the player to Freeroam. The editor car remains intentionally unlocked.
- Checkpoint zones are presentation hints. The server re-evaluates every crossing from the latest
  authenticated player position, bucket, vertical tolerance, radius, and bounded movement segment.
- A client cannot open an editor by emitting `race:editorAction`: only the restricted command can
  create the expiring server-side editor session.
- Drive mode runs in world bucket `0`, suppresses the lobby POI, and owns one disposable
  server-created car. Exiting or expiring the session removes it before returning the player to the
  captured Freeroam position and bucket.
- Vehicle controls remain natively locked through the `3, 2, 1` sequence and release on `GO!`.
- Course files never enter the downloaded client package and do not trigger a resource hot reload;
  the catalogue owns them as server data.

See [writing a gamemode](https://open2077.net/docs/writing-a-gamemode),
[server resource IO](https://open2077.net/docs/server-api#resource-local-file-io), and the
[Race runtime research](https://github.com/Open2077/open77-base/blob/main/docs/research/race-checkpoints-and-ui.md).
