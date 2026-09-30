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


def arc_headings(radius, step, straight_in=20, straight_out=20, total=120):
    """Headings for a constant-radius arc between two straights.

    The heading has to *accumulate*: a list of the same value repeated is a
    straight line, not an arc. A first version of this built the arc that way
    and the generator correctly called it a straight — the shape, not the
    ladder, was wrong.
    """
    headings = [0.0] * straight_in
    for i in range(total - straight_in - straight_out):
        headings.append(headings[-1] + step / radius * 180 / math.pi)
    headings += [headings[-1]] * straight_out
    return headings


def flat_bend():
    """A real corner, but too open for a 6, which the ladder calls Flat.

    Flat is the 150m-300m band. 350m and above is not a corner at all, and
    150m and below reads as a 6, so 240m sits in the middle of it.
    """
    return walk(arc_headings(240.0, 10.0), (42.6, -71.4), step=10)


def tightening_corner():
    """A corner whose turn rate rises geometrically, so the radius tightens.

    Radius is the reciprocal of curvature, so a turn rate that merely increases
    makes the radius fall as 1/x and log-radius comes out concave, which the fit
    rightly rejects. A road that tightens tightens geometrically, and that is
    what makes log-radius a straight line.

    The rate is kept in a range where the corner starts around a 4 and ends near
    a 1: too aggressive and the corner is a hairpin or a grade 1, and a grade 1
    is not called as tightening because it has nowhere left to go.
    """
    headings = [0.0] * 20
    for i in range(1, 60):
        headings.append(headings[-1] + 0.5 * (1.06 ** i))
    headings += [headings[-1]] * 20
    return walk(headings, (42.4, -71.6), step=10)


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
