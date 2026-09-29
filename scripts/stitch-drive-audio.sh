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

  # The calls have to be mixed, not concatenated: each segment is silence then
  # its call then silence out to the end of the drive, so overlaying them lines
  # every call up on the same timeline. Concatenating would play the segments
  # one after another and stretch a 6s drive to nearly 100s.
  #
  # The input list is read with a while loop rather than mapfile, which macOS's
  # bash 3.2 does not have.
  inputs=()
  while IFS= read -r line; do inputs+=("$line"); done < <(ls "$tmp"/*.wav)
  args=()
  for f in "${inputs[@]}"; do args+=(-i "$f"); done
  # The pack's own clips are already recorded at full scale, so the mix is left
  # at that level rather than normalised — normalising would quiet the roads
  # with one call to match the busy ones.
  ffmpeg -v error -y "${args[@]}" \
    -filter_complex "amix=inputs=${#inputs[@]}:duration=longest:normalize=0" \
    -t "$total" -ar 22050 -ac 1 -c:a pcm_s16le "$OUT_DIR/$road.wav"
  echo "stitched $road.wav — $i calls, ${total}s"
done
