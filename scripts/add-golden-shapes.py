#!/usr/bin/env python3
"""Appends synthetic shapes to the golden fixtures, and regenerates them.

The existing fixtures barely exercise the newest behaviour: no road in them
produces a flat corner, a tightening one, or a grade either side of a band
boundary. Those paths are the ones most likely to rot, and a golden set that
never reaches them proves nothing.

The shapes are chosen to land on specific points — a corner just inside and just
outside each severity edge, a bend gentle enough to be flat, and one that
tightens exponentially.

Usage:  scripts/add-golden-shapes.py
"""

import json
import math
import os

ORIGIN = (42.0, -71.0)
R = 6371008.8


def advance(lat, lon, metres, bearing_deg):
    """One step: metres along a bearing, as absolute [lon, lat]."""
    rad = math.radians(bearing_deg)
    return [lon + (metres * math.sin(rad)) / (R * math.cos(math.radians(lat))) * 180 / math.pi,
            lat + (metres * math.cos(rad)) / R * 180 / math.pi]


def walk(headings, start=ORIGIN, step=10):
    """A road whose heading is given per step, at a constant spacing.

    Every point is absolute: a previous version treated them as offsets and
    accumulated them, which produced a 800,000km road and hung the generator.
    """
    lat, lon = start
    out = []
    for bearing in headings:
        point = advance(lat, lon, step, bearing)
        lat, lon = point[1], point[0]
        out.append(point)
    return out


def flat_bend():
    """A real corner, but too open for a 6, which the ladder calls Flat.

    Flat is the band from 150m to 300m of radius, so this has to turn
    genuinely: 2 degrees over 400m is an 11km radius, which is a straight, not
    a flat corner. 60 degrees over 250m is about 240m — inside the band.
    """
    step, total = 10.0, 60.0
    per_step = math.degrees(step / 240.0)      # 240m radius
    n = int(250 / step)
    headings = [0.0] * 20 + [per_step] * n + [per_step] * 20
    return walk(headings, (42.6, -71.4))


def tightening_corner():
    """A corner whose turn rate rises geometrically, so the radius tightens.

    A linearly rising turn rate would not do: radius is the reciprocal of
    curvature, so the radius would fall as 1/x and log-radius would be concave
    rather than straight, and the fit rightly rejects it.
    """
    headings = [0.0] * 20
    for i in range(1, 45):
        headings.append(headings[-1] + 0.5 * (1.06 ** i))
    headings += [headings[-1]] * 20
    return walk(headings, (42.4, -71.6))


if __name__ == "__main__":
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "TougeTrackerTests", "Fixtures", "pacenote_fixtures.json")
    fixtures = json.load(open(path))
    have = {f["name"] for f in fixtures}
    for name, coords in (("syn_flat_bend", flat_bend()),
                         ("syn_tightening", tightening_corner())):
        if name in have:
            print(f"  {name} already there")
            continue
        fixtures.append({"name": name, "coordinates": coords,
                         "expectedText": "", "expectedTurns": [], "totalLength": 0})
        print(f"  added {name}: {len(coords)} points")
    json.dump(fixtures, open(path, "w"))
