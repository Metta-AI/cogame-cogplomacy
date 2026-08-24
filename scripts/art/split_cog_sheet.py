#!/usr/bin/env python3
"""Key, split and pad the nano-banana power sheet into per-power sprites.

Reads the two nano-banana sheets under scripts/art/source/ (four cogs then
three, on a flat green backdrop), floods the backdrop away from the image
border so green accents inside a cog survive, splits each row on its empty
columns, pads every part to a square and writes data/cog_<power>.png at 128px.

    python3 scripts/art/split_cog_sheet.py

This script owns data/cog_*.png. The starter's data/soldier_*_front.png are
NOT owned by it: they stay as the inherited cogame-bullwhip sprites and are
still used as the fallback token art when a portrait fails to load.
"""

import os
import sys
from collections import deque

from PIL import Image

SHEETS = [
    ("scripts/art/source/power_cogs_sheet_a.png",
     ["austria", "england", "france", "germany"]),
    ("scripts/art/source/power_cogs_sheet_b.png",
     ["italy", "russia", "turkey"]),
]
SIZE = 128
TOLERANCE = 60


def median_border(image):
    width, height = image.size
    pixels = image.load()
    samples = []
    for x in range(0, width, 4):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(0, height, 4):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    samples.sort()
    return samples[len(samples) // 2]


def key_out(image):
    """Flood-fill the backdrop colour from the border into transparency."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    backdrop = median_border(image)

    def close(colour):
        return (abs(colour[0] - backdrop[0]) +
                abs(colour[1] - backdrop[1]) +
                abs(colour[2] - backdrop[2])) < TOLERANCE * 3

    seen = bytearray(width * height)
    queue = deque()
    for x in range(width):
        for y in (0, height - 1):
            queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        seen[index] = 1
        if not close(pixels[x, y][:3]):
            continue
        pixels[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return image


def columns_with_ink(image, threshold=3):
    """Ink per column, measured over the TOP of the figures only.

    The cogs stand on big wheels that habitually touch their neighbours', so
    a full-height projection sees one unbroken blob. Bodies and heads always
    have air between them, so the upper 55% of the inked band is where the
    gaps live.
    """
    box = image.getbbox()
    if not box:
        return []
    top, bottom = box[1], box[3]
    band = int(top + (bottom - top) * 0.55)
    width, _ = image.size
    pixels = image.load()
    used = []
    for x in range(width):
        count = 0
        for y in range(top, band):
            if pixels[x, y][3] > 40:
                count += 1
                if count >= threshold:
                    break
        used.append(count >= threshold)
    return used


def spans(used):
    out = []
    start = None
    for index, value in enumerate(used):
        if value and start is None:
            start = index
        elif not value and start is not None:
            out.append((start, index))
            start = None
    if start is not None:
        out.append((start, len(used)))
    return out


def pad_square(image):
    box = image.getbbox()
    if box:
        image = image.crop(box)
    width, height = image.size
    side = max(width, height)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - width) // 2, side - height))
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def ink_profile(image):
    """Ink count per column over the whole sheet."""
    width, height = image.size
    pixels = image.load()
    profile = []
    for x in range(width):
        count = 0
        for y in range(0, height, 2):
            if pixels[x, y][3] > 40:
                count += 1
        profile.append(count)
    return profile


def cut_columns(profile, low, high, parts):
    """Where to cut an inked range into `parts` figures.

    Equal slabs give the nominal boundaries; each one then slides to the
    emptiest column within 40% of a slab. That survives a flag on a pole
    reaching over the gap into the next cog — the pole is two or three thin
    columns, and the emptiest column near the boundary is still between the
    two figures.
    """
    slab = (high - low) / float(parts)
    cuts = []
    for index in range(1, parts):
        nominal = low + slab * index
        window = int(slab * 0.4)
        best = int(nominal)
        for x in range(max(low + 1, int(nominal) - window),
                       min(high - 1, int(nominal) + window) + 1):
            if profile[x] < profile[best]:
                best = x
        cuts.append(best)
    return [low] + cuts + [high]


def split_sheet(source, powers):
    if not os.path.exists(source):
        sys.exit("missing " + source + " — run gen_power_cogs.py first")
    sheet = key_out(Image.open(source))
    box = sheet.getbbox()
    if not box:
        sys.exit("nothing left after keying " + source)
    profile = ink_profile(sheet)
    edges = cut_columns(profile, box[0], box[2], len(powers))
    print(source, "->", len(powers), "figures at", edges)
    os.makedirs("data", exist_ok=True)
    for index, power in enumerate(powers):
        part = sheet.crop((edges[index], 0, edges[index + 1], sheet.size[1]))
        out = os.path.join("data", "cog_" + power + ".png")
        pad_square(part).save(out)
        print("wrote", out)


def main():
    for source, powers in SHEETS:
        split_sheet(source, powers)


if __name__ == "__main__":
    main()
