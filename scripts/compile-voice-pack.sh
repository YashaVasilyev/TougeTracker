#!/bin/bash
# Compiles the recorded co-driver clips down to AAC for the app bundle.
#
# The masters are 44.1kHz stereo WAV — 28MB for a few seconds of speech. As
# mono AAC at 80kbit/s the same recordings are a fraction of that, and the
# difference is inaudible on a phone speaker, which is where this is heard.
#
#   ./scripts/compile-voice-pack.sh [packDir] [outDir]
#
# The masters stay in voice-packs/ and are never bundled; only the output goes
# into the app. Re-run this after changing the masters.
set -euo pipefail
cd "$(dirname "$0")/.."
PACK="${1:-voice-packs/PhillMills}"
OUT="${2:-TougeTracker/Resources/codriver-voices}"
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }

[ -d "$PACK" ] || { echo "no pack at $PACK" >&2; exit 1; }
mkdir -p "$OUT"

count=0
for wav in "$PACK"/*.wav; do
  [ -e "$wav" ] || continue
  name="$(basename "$wav" .wav)"
  # Speech is mono. Keep the sample rate, drop the stereo channel, and use a
  # bitrate with headroom over what intelligible speech needs.
  ffmpeg -v error -y -i "$wav" -c:a aac -b:a 80k -ac 1 -movflags +faststart \
    "$OUT/$name.m4a"
  count=$(( count + 1 ))
done

echo "compiled $count clips into $OUT"
du -sh "$PACK" "$OUT"
