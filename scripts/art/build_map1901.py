#!/usr/bin/env python3
"""Build data/map1901.json — the vector map of 1901 Europe the viewer draws.

The authored data is the ANCHOR TABLE below: one hand-placed point per
province in a 1000x800 space, laid out to the geography of the standard
Diplomacy board (Atlantic on the left, Barents at the top right, North Africa
along the bottom).  The province outlines are derived from those anchors by
half-plane clipping (a Voronoi diagram over the anchors, clipped to the
frame) and then softened with a deterministic per-edge wobble so the coasts
read as drawn rather than as a lattice.  Every polygon comes out with 8-24
points, which is what the renderer wants.

Nothing here is random: run it twice and you get byte-identical output.  The
committed data/map1901.json is the artifact; this script is how it is
reproduced.

    python3 scripts/art/build_map1901.py

Adjacency is NOT taken from this file — it lives in src/cogplomacy/mapdata.nim,
which is the authority.  This file is only the picture.
"""

import json
import math
import os

WIDTH, HEIGHT = 1000, 800

# province code -> (x, y, kind, display name)
ANCHORS = [
    ("ADR", 530, 495, "sea", "Adriatic Sea"),
    ("AEG", 645, 615, "sea", "Aegean Sea"),
    ("ALB", 578, 538, "coast", "Albania"),
    ("ANK", 775, 528, "coast", "Ankara"),
    ("APU", 535, 552, "coast", "Apulia"),
    ("ARM", 855, 495, "coast", "Armenia"),
    ("BAL", 505, 262, "sea", "Baltic Sea"),
    ("BAR", 612, 35, "sea", "Barents Sea"),
    ("BEL", 355, 365, "coast", "Belgium"),
    ("BER", 505, 320, "coast", "Berlin"),
    ("BLA", 745, 428, "sea", "Black Sea"),
    ("BOH", 505, 400, "land", "Bohemia"),
    ("BOT", 537, 185, "sea", "Gulf of Bothnia"),
    ("BRE", 245, 420, "coast", "Brest"),
    ("BUD", 597, 435, "land", "Budapest"),
    ("BUL", 655, 520, "coast", "Bulgaria"),
    ("BUR", 370, 435, "land", "Burgundy"),
    ("CLY", 215, 175, "coast", "Clyde"),
    ("CON", 700, 557, "coast", "Constantinople"),
    ("DEN", 405, 265, "coast", "Denmark"),
    ("EAS", 745, 682, "sea", "Eastern Mediterranean"),
    ("EDI", 262, 187, "coast", "Edinburgh"),
    ("ENG", 240, 360, "sea", "English Channel"),
    ("FIN", 585, 95, "coast", "Finland"),
    ("GAL", 622, 385, "land", "Galicia"),
    ("GAS", 272, 480, "coast", "Gascony"),
    ("GOL", 332, 560, "sea", "Gulf of Lyon"),
    ("GRE", 602, 588, "coast", "Greece"),
    ("HEL", 388, 300, "sea", "Helgoland Bight"),
    ("HOL", 402, 330, "coast", "Holland"),
    ("ION", 520, 660, "sea", "Ionian Sea"),
    ("IRI", 150, 275, "sea", "Irish Sea"),
    ("KIE", 440, 305, "coast", "Kiel"),
    ("LON", 282, 305, "coast", "London"),
    ("LVN", 622, 235, "coast", "Livonia"),
    ("LVP", 215, 250, "coast", "Liverpool"),
    ("MAO", 92, 470, "sea", "Mid-Atlantic Ocean"),
    ("MAR", 345, 502, "coast", "Marseilles"),
    ("MOS", 790, 210, "land", "Moscow"),
    ("MUN", 455, 400, "land", "Munich"),
    ("NAF", 218, 692, "coast", "North Africa"),
    ("NAO", 110, 130, "sea", "North Atlantic Ocean"),
    ("NAP", 515, 588, "coast", "Naples"),
    ("NTH", 340, 220, "sea", "North Sea"),
    ("NWG", 300, 60, "sea", "Norwegian Sea"),
    ("NWY", 415, 105, "coast", "Norway"),
    ("PAR", 315, 430, "land", "Paris"),
    ("PIC", 320, 390, "coast", "Picardy"),
    ("PIE", 410, 470, "coast", "Piedmont"),
    ("POR", 140, 570, "coast", "Portugal"),
    ("PRU", 548, 315, "coast", "Prussia"),
    ("ROM", 480, 545, "coast", "Rome"),
    ("RUH", 430, 360, "land", "Ruhr"),
    ("RUM", 682, 450, "coast", "Rumania"),
    ("SER", 590, 490, "land", "Serbia"),
    ("SEV", 792, 330, "coast", "Sevastopol"),
    ("SIL", 542, 365, "land", "Silesia"),
    ("SKA", 415, 215, "sea", "Skagerrak"),
    ("SMY", 742, 610, "coast", "Smyrna"),
    ("SPA", 215, 560, "coast", "Spain"),
    ("STP", 665, 120, "coast", "St Petersburg"),
    ("SWE", 490, 132, "coast", "Sweden"),
    ("SYR", 845, 612, "coast", "Syria"),
    ("TRI", 515, 470, "coast", "Trieste"),
    ("TUN", 390, 692, "coast", "Tunis"),
    ("TUS", 450, 505, "coast", "Tuscany"),
    ("TYR", 475, 435, "land", "Tyrolia"),
    ("TYS", 450, 602, "sea", "Tyrrhenian Sea"),
    ("UKR", 722, 340, "land", "Ukraine"),
    ("VEN", 455, 455, "coast", "Venice"),
    ("VIE", 540, 425, "land", "Vienna"),
    ("WAL", 210, 310, "coast", "Wales"),
    ("WAR", 632, 330, "land", "Warsaw"),
    ("WES", 300, 622, "sea", "Western Mediterranean"),
    ("YOR", 275, 250, "coast", "Yorkshire"),
]

CENTRES = {
    "VIE": 0, "BUD": 0, "TRI": 0,
    "LON": 1, "EDI": 1, "LVP": 1,
    "PAR": 2, "MAR": 2, "BRE": 2,
    "BER": 3, "MUN": 3, "KIE": 3,
    "ROM": 4, "VEN": 4, "NAP": 4,
    "MOS": 5, "WAR": 5, "SEV": 5, "STP": 5,
    "CON": 6, "SMY": 6, "ANK": 6,
    "NWY": -1, "SWE": -1, "DEN": -1, "HOL": -1, "BEL": -1, "SPA": -1,
    "POR": -1, "TUN": -1, "SER": -1, "RUM": -1, "BUL": -1, "GRE": -1,
}

# Split coasts: the anchor for each named coast, as an offset from the
# province anchor toward the water that coast faces.
COASTS = {
    "SPA": {"NC": (-34, -30), "SC": (12, 40)},
    "STP": {"NC": (-18, -46), "SC": (-36, 34)},
    "BUL": {"EC": (34, -18), "SC": (-6, 40)},
}


def clip(poly, ax, ay, bx, by):
    """Sutherland-Hodgman clip of `poly` to the half-plane nearer to a."""
    mx, my = (ax + bx) / 2.0, (ay + by) / 2.0
    nx, ny = bx - ax, by - ay

    def inside(p):
        return (p[0] - mx) * nx + (p[1] - my) * ny <= 0

    out = []
    for i in range(len(poly)):
        cur, nxt = poly[i], poly[(i + 1) % len(poly)]
        ci, ni = inside(cur), inside(nxt)
        if ci:
            out.append(cur)
        if ci != ni:
            dx, dy = nxt[0] - cur[0], nxt[1] - cur[1]
            denom = dx * nx + dy * ny
            if abs(denom) > 1e-9:
                t = ((mx - cur[0]) * nx + (my - cur[1]) * ny) / denom
                out.append((cur[0] + t * dx, cur[1] + t * dy))
    return out


def wobble(poly, seed):
    """Subdivide every edge and nudge the new points off the straight line.

    The displacement is a function of the EDGE ALONE (its two endpoints,
    taken in a canonical order), never of which cell is being drawn, so the
    two cells that share an edge produce byte-identical points for it and
    the map never opens a seam.  Long edges get two extra points, short ones
    one, so a cell ends up with 8-24 points whatever its shape.
    """
    del seed
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        out.append(a)
        flipped = (round(b[0], 3), round(b[1], 3)) < (round(a[0], 3),
                                                      round(a[1], 3))
        ca, cb = (b, a) if flipped else (a, b)
        length = math.hypot(cb[0] - ca[0], cb[1] - ca[1])
        if length < 1e-6:
            continue
        steps = 2 if length > 90 else 1
        nx, ny = -(cb[1] - ca[1]) / length, (cb[0] - ca[0]) / length
        amp = min(7.0, length * 0.07)
        key = int(round(ca[0] * 3 + ca[1] * 7 + cb[0] * 11 + cb[1] * 13))
        points = []
        for s in range(1, steps + 1):
            t = s / (steps + 1.0)
            px, py = ca[0] + (cb[0] - ca[0]) * t, ca[1] + (cb[1] - ca[1]) * t
            offset = amp * math.sin(math.radians((key + s * 97) * 4.7))
            points.append((px + nx * offset, py + ny * offset))
        if flipped:
            points.reverse()
        out.extend(points)
    return out


def build():
    frame = [(0.0, 0.0), (float(WIDTH), 0.0),
             (float(WIDTH), float(HEIGHT)), (0.0, float(HEIGHT))]
    provinces = {}
    for index, (code, x, y, kind, name) in enumerate(ANCHORS):
        poly = list(frame)
        for other_index, (_, ox, oy, _, _) in enumerate(ANCHORS):
            if other_index == index:
                continue
            if math.hypot(ox - x, oy - y) > 320:
                continue          # far anchors can never cut this cell
            poly = clip(poly, x, y, ox, oy)
            if len(poly) < 3:
                break
        if len(poly) < 3:
            raise SystemExit("degenerate cell for " + code)
        poly = wobble(poly, index)
        if len(poly) > 24:
            step = len(poly) / 24.0
            poly = [poly[int(i * step)] for i in range(24)]
        entry = {
            # The province id the sim uses: events name provinces by id, so
            # the viewer needs the same numbering to print their names.
            "id": index,
            "name": name,
            "kind": kind,
            "centre": code in CENTRES,
            "home": CENTRES.get(code, -1),
            "poly": [[round(px, 1), round(py, 1)] for px, py in poly],
            "label": [x, y],
            "dot": [x, y - 16],
        }
        if code in COASTS:
            entry["coasts"] = {
                coast: [x + dx, y + dy]
                for coast, (dx, dy) in COASTS[code].items()
            }
        provinces[code] = entry
    return {
        "format": "cogplomacy.map1901.v1",
        "space": {"width": WIDTH, "height": HEIGHT},
        "provinces": provinces,
    }


def main():
    data = build()
    assert len(data["provinces"]) == 75, len(data["provinces"])
    assert sum(1 for p in data["provinces"].values() if p["centre"]) == 34
    for code, entry in data["provinces"].items():
        assert 8 <= len(entry["poly"]) <= 24, (code, len(entry["poly"]))
    root = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    out = os.path.join(root, "data", "map1901.json")
    with open(out, "w") as handle:
        json.dump(data, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
