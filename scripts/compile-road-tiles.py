#!/usr/bin/env python3
"""Compiles the bundled road tiles for shipping.

The tiles are the app's bulk: about 179MB of JSON across ten thousand files,
which is most of the bundle and the reason a wireless install takes a while.
Two changes cut that by roughly three quarters without changing what the app
draws:

  * Coordinates are rounded to 5 decimal places, about 1m. They arrive at 6,
    roughly 0.1m, which is far finer than anything downstream can use — the
    generator resamples the line to 5m segments before it measures a corner.
  * Each tile is zlib-compressed, which JSON takes well. zlib rather than gzip
    because that is what Apple\'s decompression API reads.

Usage:
    scripts/compile-road-tiles.py [sourceDir] [outDir]

Defaults to TougeTracker/Resources/tiles -> TougeTracker/Resources/road-tiles.
The source tiles are left alone; they are the full-precision originals.
"""

import glob
import zlib
import json
import os
import sys

PRECISION = 5


def compile_tile(path, out_dir):
    with open(path) as handle:
        roads = json.load(handle)
    for road in roads:
        road["coordinates"] = [[round(lon, PRECISION), round(lat, PRECISION)]
                               for lon, lat in road["coordinates"]]
    # No pretty printing: every byte here is shipped.
    payload = json.dumps(roads, separators=(",", ":")).encode()
    name = os.path.basename(path).replace(".json", "")
    # Raw deflate, not a zlib or gzip container. Apple's
    # `decompressed(using: .zlib)` is COMPRESSION_ZLIB, which is bare deflate
    # with no header: feed it either container and every tile fails to decode,
    # leaving the map empty with nothing to explain why.
    compressor = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    with open(os.path.join(out_dir, name + ".json.z"), "wb") as out:
        out.write(compressor.compress(payload) + compressor.flush())

if __name__ == "__main__":
    source = sys.argv[1] if len(sys.argv) > 1 else "TougeTracker/Resources/tiles"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "TougeTracker/Resources/road-tiles"
    files = sorted(glob.glob(os.path.join(source, "t_*.json")))
    if not files:
        sys.exit(f"no tiles in {source} — run scripts/fetch-curvature-tiles.mjs first")
    os.makedirs(out_dir, exist_ok=True)
    for stale in glob.glob(os.path.join(out_dir, "*.json.z")):
        os.remove(stale)
    for path in files:
        compile_tile(path, out_dir)

    before = sum(os.path.getsize(f) for f in files)
    after = sum(os.path.getsize(f) for f in glob.glob(os.path.join(out_dir, "*.json.z")))
    print(f"compiled {len(files)} tiles: {before/1e6:.0f}MB -> {after/1e6:.0f}MB "
          f"({100 * (1 - after / before):.0f}% smaller)")
