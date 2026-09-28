#!/bin/bash
# Build TougeTracker, install it on the booted simulator, and launch it.
# Usage: ./scripts/deploy.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
BUNDLE_ID="com.tougetracker.app"
DERIVED="build/Deploy"

booted_udid() {
  xcrun simctl list devices booted -j \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
u=[x["udid"] for v in d.values() for x in v if x["state"]=="Booted"]
print(u[0] if u else "")'
}

DEVICE="${SIM_DEVICE:-$(booted_udid)}"

# Fall back to booting the first available iPhone so this is one command.
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available -j \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
c=[x["udid"] for v in d.values() for x in v if x["isAvailable"] and "iPhone" in x["name"]]
print(c[0] if c else "")')"
  if [ -n "$DEVICE" ]; then
    echo "==> Booting simulator $DEVICE"
    xcrun simctl boot "$DEVICE" || true
    xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
  fi
fi

if [ -z "$DEVICE" ]; then
  echo "!! No simulator available. Start one in Xcode, or set SIM_DEVICE=<udid>." >&2
  exit 1
fi
echo "==> Target simulator: $DEVICE"

echo "==> Generating project"
xcodegen generate >/dev/null

echo "==> Building ($CONFIG)"
if ! xcodebuild -project TougeTracker.xcodeproj -scheme TougeTracker \
  -configuration "$CONFIG" \
  -destination "platform=iOS Simulator,id=${DEVICE}" \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tee /tmp/touge-build.log | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"; then
  echo "!! Build failed — see /tmp/touge-build.log" >&2
  exit 1
fi

if ! grep -q "BUILD SUCCEEDED" /tmp/touge-build.log; then
  echo "!! Build failed — see /tmp/touge-build.log" >&2
  exit 1
fi

APP="${DERIVED}/Build/Products/${CONFIG}-iphonesimulator/TougeTracker.app"
if [ ! -d "$APP" ]; then
  echo "!! Build failed — $APP not found" >&2
  exit 1
fi

echo "==> Installing on simulator"
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP"

echo "==> Launching"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

echo "==> Done"