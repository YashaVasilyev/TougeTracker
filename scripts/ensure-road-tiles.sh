#!/bin/bash
# Makes sure the bundled road tiles exist before the app is built.
#
# The app reads its road data from Resources/road-tiles, which is produced by
# scripts/compile-road-tiles.py. That used to be a manual step that happened to
# be documented, so a build made without it produced an app with no road data at
# all: the map simply came up empty, with nothing in the log to say why, and
# check.sh passed. That is the worst shape of failure — silent, and the tests
# do not exercise the map.
#
# Three cases, cheapest first:
#   1. Already compiled — do nothing. This is the common case, and the check
#      is a single directory test so the build stays fast.
#   2. Source tiles present but not compiled — compile them here rather than
#      failing. Same output, just produced automatically.
#   3. Neither present — fail the build loudly, because there is no road data
#      to ship and no honest way to make an app out of it.
#
# Note when editing: XcodeGen embeds this file's text into the project at
# generate time, so a change here needs `xcodegen generate` before it takes
# effect. Editing it and rebuilding without regenerating silently runs the old
# version.
set -euo pipefail

# An Xcode build phase does not run this file: XcodeGen embeds the script text
# and executes it with SRCROOT set and $0 pointing at the shell. So the script's
# own location is only reliable when this is run directly. Getting this wrong
# made the phase look for tiles under the build directory and fail the build.
if [ -n "${SRCROOT:-}" ] && [ -d "${SRCROOT}/scripts" ]; then
  cd "${SRCROOT}"
elif [ -f "$(dirname "$0")/ensure-road-tiles.sh" ]; then
  cd "$(dirname "$0")/.."
fi

SRC="TougeTracker/Resources/tiles"
OUT="TougeTracker/Resources/road-tiles"

if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  exit 0
fi

if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
  echo "error: no road tiles."
  echo
  echo "  Neither $OUT nor $SRC has anything in it, so the app would build"
  echo "  with an empty map and no indication why."
  echo
  echo "  Fetch the curvature tiles first, then build:"
  echo "      node scripts/fetch-curvature-tiles.mjs"
  echo "      ./scripts/compile-road-tiles.py"
  exit 1
fi

echo "note: road tiles not compiled yet — compiling now (this takes a minute)."
./scripts/compile-road-tiles.py
echo "note: road tiles compiled."
