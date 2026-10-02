#!/bin/bash
# Replays the fixture roads as *free* drives — no route, pacenotes built live
# from a rolling window of the road ahead — and prints the co-driver's calls.
#
#   ./scripts/simulate-live-drive.sh [speedKph] [text|audio] [outDir] [roadName]
#
# The companion to simulate-drive.sh, not a replacement: that one replays a
# planned route, and everything that only goes wrong when there is no route —
# a window rebuilt in the wrong place, a corner announced twice, a straight left
# without its corner — is invisible to it. Two of those were found this way.
#
# TRACE=1 prints every window and every call, for working out why a road was
# quiet.
set -euo pipefail
cd "$(dirname "$0")/.."

# Top-level code has to live in a file called main.swift, and the planned
# simulator already owns that name, so the live one is staged under /tmp.
STAGE="${TMPDIR:-/tmp}/simulatelive"
mkdir -p "$STAGE"
cp scripts/simulatedrive/live.swift "$STAGE/main.swift"

swiftc -O \
  TougeTracker/Core/Geo/GeoMath.swift \
  TougeTracker/Core/Geo/RoadSegmentBuilder.swift \
  TougeTracker/Core/Geo/RouteDirection.swift \
  TougeTracker/Core/Pacenotes/CornerTrend.swift \
  TougeTracker/Core/Pacenotes/PacenoteGenerator.swift \
  TougeTracker/Core/Pacenotes/PacenoteNavigator.swift \
  TougeTracker/Core/Pacenotes/CoDriverPhrases.swift \
  TougeTracker/Core/Pacenotes/LivePacenoteSource.swift \
  TougeTracker/Core/TougeRoad.swift \
  TougeTracker/Core/Recording/Types.swift \
  TougeTracker/Core/Network/LocalRoadSource.swift \
  TougeTracker/Core/Network/RoutePlanner.swift \
  "$STAGE/main.swift" -o "$STAGE/simulatelive"
exec "$STAGE/simulatelive" TougeTrackerTests/Fixtures/pacenote_fixtures.json \
  "${1:-80}" "${2:-text}" "${3:-/tmp/simdrive-audio}" "${4:-}"