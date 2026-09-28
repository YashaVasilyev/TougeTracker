#!/bin/bash
# Replays roads as drives and prints the co-driver's calls.
# Usage: ./scripts/simulate-drive.sh [speedKph] [text|audio] [outDir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/simdrive"
swiftc -O \
  TougeTracker/Core/Geo/GeoMath.swift \
  TougeTracker/Core/Pacenotes/PacenoteGenerator.swift \
  TougeTracker/Core/Pacenotes/PacenoteNavigator.swift \
  TougeTracker/Core/Pacenotes/CoDriverPhrases.swift \
  TougeTracker/Core/Pacenotes/DriveSimulator.swift \
  scripts/simulatedrive/main.swift -o "$OUT"
exec "$OUT" TougeTrackerTests/Fixtures/pacenote_fixtures.json "${1:-80}" "${2:-text}" "${3:-/tmp/simdrive-audio}"
