#!/bin/bash
# Replays the fixture roads as drives and writes one WAV per road in which the
# co-driver is heard saying each call at the moment it would happen.
#
#   ./scripts/simulate-drive-audio.sh [speedKph] [outDir]
#
# Then:  afplay <outDir>/timelines/13-syn_zigzag_sharp.wav
set -euo pipefail
cd "$(dirname "$0")/.."
SPEED="${1:-80}"
OUT="${2:-/tmp/simdrive-audio}"
PACK="TougeTracker/Resources/codriver-voices/PhillMills"

[ -d "$PACK" ] || { echo "voice pack not found at $PACK" >&2; exit 1; }

rm -rf "$OUT" "$OUT/timelines"
# "manifest" mode records the transcript, the timing of every call and the words
# of each call, without speaking them; codriver-voice.py then turns the words
# into recorded pack clips.
./scripts/simulate-drive.sh "$SPEED" manifest "$OUT" > /dev/null
python3 scripts/codriver-voice.py "$OUT" "$PACK"
./scripts/stitch-drive-audio.sh "$OUT" "$OUT/timelines"
echo
echo "listen: afplay $OUT/timelines/<road>.wav"
