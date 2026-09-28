# TougeTracker

An iOS app for exploring and driving touge (mountain pass) roads. Browse
scored road segments on a map, generate rally-style pacenotes for a route, then
record the drive with live motion telemetry and spoken turn calls.

## Features

- **Plan** — Map view of roads coloured by score, with a bottom preview card
  showing length, curvature, flow, and the first four pacenotes. Save routes,
  jump to full details, or start a drive straight from the map.
- **Drive** — Live HUD with a G-meter, speed/distance readout, and a co-driver
  that calls pacenotes ahead of each turn. Records GPS and motion data.
- **History** — Previously recorded drives with their telemetry.
- **Settings** — Units and pacenote format (rally or descriptive).

## Requirements

- Xcode 16+ (built against the iOS 26.5 simulator SDK)
- iOS 17.0+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the Xcode project is
  generated from `project.yml` and is **not** committed

```sh
brew install xcodegen
```

## Getting started

The `.xcodeproj` is not in the repository, so generate it first:

```sh
xcodegen generate
```

The road data tiles are also not committed (see *Data provenance*). They require
a sibling `../Tougefinder` checkout with its dependencies installed:

```sh
node scripts/split-db-into-tiles.mjs
```

Without the tiles the app builds but shows no roads on the map, and
`LocalRoadSourceTests` fails.

Then build, test, or run on a simulator:

```sh
./scripts/deploy.sh            # build, install, and launch on a simulator
./scripts/deploy.sh release
```

To run the test suite:

```sh
xcodebuild -project TougeTracker.xcodeproj -scheme TougeTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17e' test
```

`deploy.sh` picks the first booted simulator, and falls back to booting an
available iPhone if none is running. Override it with `SIM_DEVICE=<udid>`.

## Project layout

```
TougeTracker/
  App/         App entry point, root tab view, settings
  Core/
    Geo/       Haversine, bearing, interpolation, smoothing
    Network/   Bundled road tile loading
    Pacenotes/ Pacenote generation and turn navigation
    Recording/ Drive engine, co-driver speech, record types
    Sensors/   Location and motion services
    Storage/   SwiftData models and route store
  Features/    Plan, Drive, History, and Settings views
  Resources/   Road data tiles
  UI/          Shared UI helpers
TougeTrackerTests/
  Fixtures/    Golden pacenote fixtures shared with the JS reference
scripts/
  deploy.sh                Build + install + launch
  split-db-into-tiles.mjs  Generate bundled road tiles
  dump-pacenotes.mjs       Reference JS pacenote implementation
  goldencheck/             Cross-check Swift output against the JS
```

## Architecture notes

- **Pacenote generation is shared with a JS reference implementation.** The
  Swift generator is expected to match the output of `scripts/dump-pacenotes.mjs`
  byte for byte, and `PacenoteGoldenTests` enforces this against
  `TougeTrackerTests/Fixtures/pacenote_fixtures.json`. Run
  `scripts/dump-pacenotes.mjs` to regenerate the fixtures after changing the
  algorithm.
- **Road data is not committed.** The 0.25°-grid tiles under `Resources/tiles`
  are generated locally by `scripts/split-db-into-tiles.mjs` from a sibling
  `../Tougefinder` checkout. Regenerate them before building or running tests:

  ```sh
  node scripts/split-db-into-tiles.mjs
  ```
- **String road IDs.** The source database uses Overpass `way` IDs, which are
  usually numeric but occasionally strings like `way-nh-16-pinkham-north`.
  Decoding those as `Int64` aborts an entire tile, so `TougeRoad` folds strings
  into a stable FNV-1a `Int64` that survives across launches.
- **Touge files are read-only.** The app reads the bundled tiles directly rather
  than copying them into a writable location, so app updates replace them
  atomically.

## Data provenance

The road tiles under `TougeTracker/Resources/tiles` are **not** committed to
this repository. They are generated locally from `touges_db.json` in the
sibling Tougefinder project, which derives road geometry from OpenStreetMap
(© OpenStreetMap contributors, ODbL).

## License

No license has been assigned to this project yet.
