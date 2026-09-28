# TougeTracker

An iOS app for exploring and driving touge (mountain pass) roads. Browse
scored road segments on a map, generate rally-style pacenotes for a route, then
record the drive with live motion telemetry and spoken turn calls.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Features

- **Plan** — Map view of roads coloured by score, with a bottom preview card
  showing length, curvature, flow, and the first four pacenotes. Save routes,
  jump to full details, or start a drive straight from the map. Tap the segment
  button and mark a start and an end to route *any* drivable road — including
  ones with no score in the bundled data — via OpenStreetMap.
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

The road data tiles are also not committed (see *Data provenance*). They are
downloaded from roadcurvature.com and converted locally:

```sh
node scripts/fetch-curvature-tiles.mjs           # all US states, both bands
node scripts/fetch-curvature-tiles.mjs vermont  # one state, for iteration
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
  fetch-curvature-tiles.mjs  Download roadcurvature.com KML and generate bundled road tiles
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
  are generated locally by `scripts/fetch-curvature-tiles.mjs`, which downloads
  the roadcurvature.com KMZ files and converts them. Regenerate them before
  building or running tests:

  ```sh
  node scripts/fetch-curvature-tiles.mjs
  ```

  Downloads are cached in `.curvature-cache/` at the repo root. Pass one or
  more state slugs to build a small subset while iterating.
- **Scores are curvature-only.** roadcurvature publishes no traffic/flow data,
  so `flowScore` is always null and `totalScore` is derived logarithmically
  from the raw curvature value (degrees per mile). The conversion is in
  `scoreFor` in the fetch script.
- **Road IDs are hashed.** roadcurvature exposes no stable numeric ID, so
  `TougeRoad.id` is an FNV-1a hash of the road's name and start coordinate.
  `TougeRoad` still folds string IDs into a hash on decode, since the bundled
  tiles carry the value as a plain integer.
- **Touge files are read-only.** The app reads the bundled tiles directly rather
  than copying them into a writable location, so app updates replace them
  atomically.

## Data provenance

The road tiles under `TougeTracker/Resources/tiles` are **not** committed to
this repository. They are generated locally by `scripts/fetch-curvature-tiles.mjs`
from the color-coded KML/KMZ files published by
[roadcurvature.com](https://kml.roadcurvature.com/), which analyses OpenStreetMap
highway geometry to detect curves and rank each segment. The underlying geometry
is © OpenStreetMap contributors and licensed ODbL.

## License

MIT — see [LICENSE](LICENSE).

The pacenote algorithm in `Core/Pacenotes/` is a port of the JS implementation
in the Tougefinder project, and is kept byte-for-byte compatible with it via the
golden fixtures. Attribution is required when redistributing.

The road data tiles are **not** covered by this license. They are generated
locally by this repository's own script from roadcurvature.com's KML/KMZ output,
where the underlying geometry is © OpenStreetMap contributors and licensed ODbL.

## Development notes

Local setup on this machine:

- Simulators available: **iPhone 17e** and **iPhone Air** (iOS 26.5). There is
  no iPhone 16 Pro — targeting it fails with "Unable to find a device matching
  the provided destination specifier".
- The GitHub remote uses SSH over **port 443** (`git@github-touge`), because
  outbound port 22 to github.com times out on this network. The alias lives in
  `~/.ssh/config`.
- `xcodegen generate` must be rerun after adding or removing source files, since
  the project file is generated and untracked.
