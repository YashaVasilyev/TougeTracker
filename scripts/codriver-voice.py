#!/usr/bin/env python3
"""Turns the co-driver phrases written by the drive simulator into speech.

The simulator writes what the co-driver would *say* ("into three right, 100").
This resolves each of those words to a recorded clip from the Assetto Corsa
voice pack and joins the clips into one file per call, so a drive can be
listened to rather than read.

Usage:
    codriver-voice.py <audioDir> [packDir]

< audioDir > holds one directory per road, each with the clips and the
manifest.tsv written by "./scripts/simulate-drive.sh <speed> audio".
Each manifest line is replaced with the built speech for that call.
"""

import os
import re
import subprocess
import sys

GRADES = {
    "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
    "hairpin": "HP", "square": "Square", "flat": "Flat",
}
DIRECTIONS = {"left": "Left", "right": "Right"}


class Pack:
    """The recorded clips, looked up by name and tolerant of what is missing.

    The pack is a rally voice pack, so its vocabulary is wider than ours but not
    identical: it has no "into six" and no "followed by one". Rather than fail,
    fall back to the nearest thing that exists — a two-clip "into five, and
    left six" still says something a driver can act on, silence does not.
    """

    def __init__(self, directory):
        # Absolute, because the list file ffmpeg reads is resolved relative to
        # its own location — the call being built — not to this pack.
        self.dir = os.path.abspath(directory)
        # The masters are WAV; the app bundles the compiled AAC. Accept either so
        # this runs against whichever copy is to hand.
        self.have = {n.rsplit(".", 1)[0] for n in os.listdir(self.dir)
                     if n.endswith((".wav", ".m4a"))}
        self.distances = sorted(int(n[4:]) for n in self.have
                                if n.startswith("Dist") and n[4:].isdigit())
        # Distances we had to round to a recorded clip, so the substitution is
        # visible in the build log rather than only audible as a wrong number.
        self.rounded = []

    def get(self, *names):
        for name in names:
            if name in self.have:
                return os.path.join(self.dir, name + ".wav")
        return None

    def distance(self, metres):
        """The clip for a straight of `metres`.

        The pack only records fifteen distances — 40 to 90 in tens, then 100,
        130, 150, 170 and 200 upwards in fifties — but we call a distance every
        ten metres. Without this, three distances in five found no clip and were
        dropped silently, so "square right, 220" came out as just "square
        right": the co-driver gave the corner and never said how far.

        The nearest recorded distance is within 20m of any we call, which is
        inside the rounding a co-driver already does.
        """
        if f"Dist{metres}" in self.have:
            return os.path.join(self.dir, f"Dist{metres}.wav")
        nearest = min(self.distances, key=lambda d: (abs(d - metres), -d))
        self.rounded.append((metres, nearest))
        return os.path.join(self.dir, f"Dist{nearest}.wav")


    def clips_for(self, connector, grade, direction, modifier):
        """The clips for one pacenote, in the order they are spoken.

        Takes the same arguments, in the same order, that `parse_item` returns.
        """
        tail = self.modifier_clips(modifier)
        if connector == "into":
            clip = self.get(f"Into-{direction}{grade}", f"And-{direction}{grade}")
            if clip:
                return [clip] + tail
            # No single "into" clip for this severity: say it as one.
            return [self.get(f"Into-{direction}1"), self.get(f"{direction}{grade}")]
        if connector == "and":
            clip = self.get(f"And-{direction}{grade}")
            if clip:
                return [clip] + tail
            # No "followed by one" in the pack. Say the link with an "into one"
            # clip and the severity plainly: dropping the link would call two
            # corners that sound unrelated. Must stay in step with VoicePack
            # in the app, or a simulated drive does not sound like the real one.
            return [self.get(f"Into-{direction}1"), self.get(f"{direction}{grade}")]
        clip = self.get(f"{direction}{grade}")
        if clip:
            return [clip] + tail
        return [c for c in [self.get(f"{direction}1")] if c]

    def modifier_clips(self, modifier):
        return [self.get(modifier)] if modifier else []


def parse_item(item):
    """Splits one phrase item into (connector, grade, direction, modifier)."""
    connector = None
    for prefix, name in (("into ", "into"), ("followed by ", "and")):
        if item.startswith(prefix):
            connector, item = name, item[len(prefix):]
            break
    modifier = None
    for suffix, name in ((" very long", "VeryLong"), (" long", "Long")):
        if item.endswith(suffix):
            modifier, item = name, item[:-len(suffix)]
            break
    parts = item.split()
    if len(parts) < 2:
        return None
    direction = DIRECTIONS.get(parts[-1])
    grade = GRADES.get(parts[0])
    if not direction or not grade:
        return None
    return connector, grade, direction, modifier


def clips_for_phrase(pack, phrase):
    """Every clip for a whole call, which may chain several notes."""
    out = []
    for item in phrase.split(", "):
        item = item.strip()
        if not item:
            continue
        if item.isdigit():
            # A straight is called as a distance alone.
            out.append(pack.distance(int(item)))
            continue
        parsed = parse_item(item)
        if parsed:
            out.extend(pack.clips_for(*parsed))
    return [c for c in out if c]


def build(pack, phrase, out_path):
    clips = clips_for_phrase(pack, phrase)
    if not clips:
        return None
    listfile = out_path + ".txt"
    with open(listfile, "w") as f:
        for clip in clips:
            f.write(f"file '{clip}'\n")
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0",
         "-i", listfile, "-ar", "44100", "-ac", "2", out_path],
        check=True)
    os.remove(listfile)
    return out_path


if __name__ == "__main__":
    audio_dir = sys.argv[1]
    pack = Pack(sys.argv[2] if len(sys.argv) > 2
                else "voice-packs/PhillMills")
    built = missing = 0
    for road in sorted(os.listdir(audio_dir)):
        manifest = os.path.join(audio_dir, road, "manifest.tsv")
        if not os.path.isfile(manifest):
            continue
        lines = [l for l in open(manifest).read().splitlines() if l.strip()]
        out = ["clip\tseconds\tphrase"]
        for line in lines[1:]:
            clip, seconds, phrase = line.split("\t")
            built_path = build(pack, phrase, os.path.join(audio_dir, road, clip + ".wav"))
            if built_path:
                built += 1
                out.append(f"{clip}.wav\t{seconds}\t{phrase}")
                # The synthesised clip, if there was one, is now redundant.
                stale = os.path.join(audio_dir, road, clip)
                if os.path.exists(stale):
                    os.remove(stale)
            else:
                missing += 1
        open(manifest, "w").write("\n".join(out) + "\n")
    print(f"built {built} calls, {missing} with no matching clips")
    if pack.rounded:
        shown = ", ".join(f"{a}->{b}" for a, b in sorted(set(pack.rounded)))
        print(f"rounded {len(set(pack.rounded))} distances to a recorded clip: {shown}")
