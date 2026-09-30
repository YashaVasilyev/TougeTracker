#!/usr/bin/env python3
"""Checks that the simulator and the app parse a pacenote the same way.

`codriver-voice.py` exists only to build the audio for a simulated drive. If it
disagrees with `VoicePack` in the app, a simulated drive does not sound like the
real one, and the difference is invisible until someone listens to both.

This runs the same phrases through both and compares, so the two cannot drift.

Usage:  scripts/voicepack-parity.py
"""

import importlib.util
import os
import subprocess
import sys

PHRASES = [
    "three left", "three left long", "three left long tightens",
    "three left very long opens", "two right opens", "into three right",
    "into three right tightens", "followed by one left tightens",
    "square right", "100", "220",
]


def python_clips():
    spec = importlib.util.spec_from_file_location(
        "cv", os.path.join(os.path.dirname(__file__), "codriver-voice.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pack = module.Pack("voice-packs/PhillMills")
    return {p: [os.path.basename(c)[:-4] for c in module.clips_for_phrase(pack, p)]
            for p in PHRASES}


def swift_clips():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    # Top-level code is only allowed in a file called main.swift.
    source_dir = os.path.join("/tmp", "voicepack-parity")
    os.makedirs(source_dir, exist_ok=True)
    source = os.path.join(source_dir, "main.swift")
    with open(source, "w") as f:
        f.write("""
import Foundation
let dir = "voice-packs/PhillMills"
let names = Set(try! FileManager.default.contentsOfDirectory(atPath: dir))
    .filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) }
let pack = VoicePack(available: Set(names))
for phrase in CommandLine.arguments.dropFirst() {
    print("\\(phrase)\\t\\(pack.clips(for: phrase).joined(separator: " + "))")
}
""")
    binary = "/tmp/voicepack-parity-bin"
    subprocess.run(["swiftc", "-O",
                    os.path.join(root, "TougeTracker/Core/Geo/GeoMath.swift"),
                    os.path.join(root, "TougeTracker/Core/Pacenotes/VoicePack.swift"),
                    source, "-o", binary], check=True, cwd=root)
    out = subprocess.run([binary] + PHRASES, capture_output=True, text=True,
                         check=True, cwd=root).stdout.splitlines()
    # The Swift side prints a joined string; compare like with like.
    return {phrase: joined.split(" + ") if joined else []
            for phrase, joined in (line.split("\t", 1) for line in out)}


if __name__ == "__main__":
    mine, theirs = python_clips(), swift_clips()
    bad = 0
    for phrase in PHRASES:
        if mine[phrase] != theirs[phrase]:
            bad += 1
            print(f"  MISMATCH {phrase!r}: python {mine[phrase]} vs swift {theirs[phrase]}")
    print(f"{len(PHRASES) - bad}/{len(PHRASES)} phrases agree")
    sys.exit(1 if bad else 0)
