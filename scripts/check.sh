#!/bin/bash
# Everything that can fail without a device, in one command.
#
# Intended for CI and for before pushing. The parity check in particular is not
# optional: it is what stops the simulator's audio drifting from what the app
# says, and that failure is silent in both directions.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== voice pack parity =="
./scripts/voicepack-parity.py

echo
echo "== tests =="
xcodegen generate > /dev/null
xcodebuild -project TougeTracker.xcodeproj -scheme TougeTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17e' test
