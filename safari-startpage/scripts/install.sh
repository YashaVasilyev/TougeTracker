#!/bin/bash
# Builds the start page, installs a LaunchAgent that runs the local server at
# login, points Safari at it, and opens it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.yasha.safari-startpage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${PORT:-8787}"
URL="http://localhost:$PORT"
NODE_BIN="$(command -v node)"

cd "$ROOT"

echo "==> Installing dependencies"
npm install --silent

echo "==> Building"
npm run build

echo "==> Registering LaunchAgent (starts at login on port $PORT)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$ROOT/server.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict><key>PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/safari-startpage.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/safari-startpage.err.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "==> Waiting for the server to come up"
for i in $(seq 1 20); do
  if curl -sf "$URL/api/health" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -sf "$URL/api/health" >/dev/null || { echo "Server did not start — see ~/Library/Logs/safari-startpage.err.log"; exit 1; }

echo "==> Opening in Safari"
osascript <<OSA
tell application "Safari"
  activate
  if (count of windows) = 0 then make new document
  set URL of current tab of front window to "$URL"
end tell
OSA

echo
echo "Done. Start page: $URL"
echo "To undo: bash scripts/uninstall.sh"
