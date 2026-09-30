#!/bin/bash
# Checks whether the server can read Safari history, and prints the exact steps
# to enable it if not. Run this any time autocomplete history seems empty.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# macOS matches the FDA grant against the real binary, so resolve symlinks
# (e.g. /opt/homebrew/bin/node -> Cellar/...).
NODE_BIN="$(command -v node)"
NODE_REAL="$(node -e "console.log(require('fs').realpathSync(process.argv[1]))" "$NODE_BIN")"
DB="$HOME/Library/Safari/History.db"

if node -e "require('fs').accessSync(process.argv[1], require('fs').constants.R_OK)" "$DB" 2>/dev/null; then
  echo "OK — Safari history is readable. Restart the server:"
  echo "  launchctl kickstart -k gui/\$(id -u)/com.yasha.safari-startpage"
  exit 0
fi

cat <<EOF
Safari history is blocked by macOS, so autocomplete is using Google
suggestions only until you grant Full Disk Access.

Opening the settings pane for you now. Then:

  1. Unlock with your password
  2. Click "+" and add:   $NODE_REAL
  3. Toggle it ON
  4. Run this script again to confirm

If the "+" button is greyed out, quit System Settings (Cmd+Q) and reopen it.
EOF

# Take you straight to the Full Disk Access list.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
