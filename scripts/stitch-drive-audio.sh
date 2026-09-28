#!/bin/bash
# Lays the clips written by "./scripts/simulate-drive.sh <speed> audio" back on
# the timeline they came from, producing one WAV per road in which every call is
# heard at the second it would have been spoken on the drive.
#
# Usage: ./scripts/stitch-drive-audio.sh <audioDir> [outDir]
set -euo pipefail
AUDIO_DIR="${1:?usage: stitch-drive-audio.sh <audioDir> [outDir]}"
OUT_DIR="${2:-$AUDIO_DIR/timelines}"
mkdir -p "$OUT_DIR"

for dir in "$AUDIO_DIR"/*/; do
  manifest="$dir/manifest.tsv"
  [ -f "$manifest" ] || continue
  road="$(basename "$dir")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # Pass one: where each call falls, and how long the drive runs. The length has
  # to be known before any audio is built — padding without a length produces an
  # endless file.
  total=0
  i=0
  while IFS=$'\t' read -r clip seconds phrase; do
    [ "$clip" = "clip" ] && continue
    [ -f "$dir/$clip" ] || continue
    ms=$(python3 -c "print(int(float('$seconds')*1000))")
    len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$dir/$clip")
    end=$(python3 -c "print($ms/1000 + $len)")
    total=$(python3 -c "print(max($total, $end))")
    i=$(( i + 1 ))
  done < "$manifest"
  [ $i -eq 0 ] && continue

  # Pass two: each call becomes silence, then the call, then silence out to the
  # full length of the drive. Lining every segment up to the same length is what
  # makes the concatenation overlay the calls instead of playing them end to end.
  i=0
  while IFS=$'\t' read -r clip seconds phrase; do
    [ "$clip" = "clip" ] && continue
    [ -f "$dir/$clip" ] || continue
    ms=$(python3 -c "print(int(float('$seconds')*1000))")
    ffmpeg -v error -y -i "$dir/$clip" -af "adelay=$ms|$ms,apad" -t "$total" \
      -ar 22050 -ac 1 -c:a pcm_s16le "$tmp/$(printf '%03d' $i).wav"
    i=$(( i + 1 ))
  done < "$manifest"

  ls "$tmp"/*.wav | sed "s|^|file '|; s|$|'|" > "$tmp/list.txt"
  ffmpeg -v error -y -f concat -safe 0 -i "$tmp/list.txt" -c copy "$OUT_DIR/$road.wav"
  echo "stitched $road.wav — $i calls, ${total}s"
done
