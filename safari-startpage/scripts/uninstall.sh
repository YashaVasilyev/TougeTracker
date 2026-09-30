#!/bin/bash
# Removes the LaunchAgent and its plist.
set -euo pipefail

LABEL="com.yasha.safari-startpage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "Removed LaunchAgent ($LABEL) and its plist."
echo "To change what Safari opens at startup, edit Safari > Settings > General."
echo "To also drop the Full Disk Access grant: System Settings > Privacy & Security"
echo "> Full Disk Access, then remove the entry you added for Node."
