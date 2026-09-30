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
# With --only-used, ships just the clips the app can actually ask for. The rest
# is 1.2MB of terrain and warning vocabulary that no code path reaches — worth
# dropping from an install, but the defaults keep it so that wiring up 3DEP later
# does not first mean hunting for recordings that were thrown away.
ONLY_USED=0
for arg in "$@"; do [ "$arg" = "--only-used" ] && ONLY_USED=1; done
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }

[ -d "$PACK" ] || { echo "no pack at $PACK" >&2; exit 1; }
mkdir -p "$OUT"

# The clips VoicePack can name, spelled out rather than guessed from its source.
USED="Left1 Left2 Left3 Left4 Left5 Left6 LeftHP LeftSquare LeftFlat
Right1 Right2 Right3 Right4 Right5 Right6 RightHP RightSquare RightFlat
Into-Left1 Into-Left2 Into-Left3 Into-Left4 Into-Left5
Into-Right1 Into-Right2 Into-Right3 Into-Right4 Into-Right5
And-Left2 And-Left3 And-Left4 And-Left5 And-Left6
And-Right2 And-Right3 And-Right4 And-Right5 And-Right6
Long VeryLong Tightens Opens
Dist40 Dist50 Dist60 Dist70 Dist80 Dist90 Dist100 Dist130 Dist150 Dist170
Dist200 Dist250 Dist300 Dist350 Dist400"

count=0
for wav in "$PACK"/*.wav; do
  [ -e "$wav" ] || continue
  name="$(basename "$wav" .wav)"
  # Speech is mono. Keep the sample rate, drop the stereo channel, and use a
  # bitrate with headroom over what intelligible speech needs.
  if [ "$ONLY_USED" = 1 ]; then
    case " $USED " in
      *" $name "*) ;;
      *) continue ;;
    esac
  fi
  ffmpeg -v error -y -i "$wav" -c:a aac -b:a 80k -ac 1 -movflags +faststart \
    "$OUT/$name.m4a"
  count=$(( count + 1 ))
done

echo "compiled $count clips into $OUT"
du -sh "$PACK" "$OUT"
