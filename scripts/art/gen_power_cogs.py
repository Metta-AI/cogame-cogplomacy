#!/usr/bin/env python3
"""Render the seven power portraits with nano-banana (gemini-2.5-flash-image).

Two sheets — four cogs then three, one per great power, each carrying a
different large prop so a spectator can tell them apart in a 28px scorebug
plate with the labels hidden.  Two sheets rather than one row of seven
because the model reliably miscounts a row of seven and merges two figures;
four and three it gets right, and the same reference image anchors the style
across both calls.  The sheets are committed under scripts/art/source/;
split_cog_sheet.py keys and splits them into data/cog_<power>.png.

    GEMINI_API_KEY=... python3 scripts/art/gen_power_cogs.py

The key is only ever the `x-goog-api-key` header — never a URL parameter,
never written to a file, never logged.  CI does not regenerate art; the PNGs
are committed.
"""

import base64
import json
import os
import sys
import urllib.request

REFERENCE = "data/soldier_red_front.png"
OUT_A = "scripts/art/source/power_cogs_sheet_a.png"
OUT_B = "scripts/art/source/power_cogs_sheet_b.png"

COMMON = """Using this wheeled robot character ("cog": boxy screen face with two
glowing eyes, riveted shoulders, two big wheels) as the EXACT character design
reference, draw {count} of these cogs side by side in ONE horizontal row,
{count_words}. Space them out with a WIDE empty gap between each pair so that no
wheel, arm, flag or prop of one robot touches or overlaps its neighbour. All
the same size, full body, front-facing, same clean flat cartoon rendering with
hard edges. Background: perfectly flat, solid, uniform pure bright green
(#00FF00), no shadows, no gradients, no floor, no ground line — it will be
chroma-keyed out.
{roster}
No text, no labels, no letters anywhere in the image."""

SHEETS = [
    (OUT_A, "FOUR", "exactly four robots: one, two, three, four", """\
1st from left — AUSTRIA: deep red (#e0523a) plating, a double-headed eagle
crest plate on the chest.
2nd — ENGLAND: navy blue (#3f7cc4) plating, a large naval anchor held in one
hand.
3rd — FRANCE: sea green (#45a85e) plating, a big rolled diplomatic scroll
with a red wax seal held in one hand, close to the body. No flags, no poles.
4th — GERMANY: mustard yellow (#ddc531) plating, a spiked pickelhaube helmet on
its head."""),
    (OUT_B, "THREE", "exactly three robots: one, two, three", """\
1st from left — ITALY: violet (#a86fd6) plating, a laurel wreath around the
screen face.
2nd — RUSSIA: warm orange (#e08a3a) plating, a thick fur shoulder mantle.
3rd — TURKEY: pale lilac (#c9a0f0) plating, a crescent-moon standard on a
pole."""),
]


def render(key, ref, prompt, out):
    body = {
        "contents": [{"parts": [
            {"inline_data": {"mime_type": "image/png", "data": ref}},
            {"text": prompt},
        ]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        "https://generativelanguage.googleapis.com/v1beta/models/"
        "gemini-2.5-flash-image:generateContent",
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": key, "content-type": "application/json"},
    )
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    part = next(p for p in payload["candidates"][0]["content"]["parts"]
                if "inlineData" in p)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print("wrote", out, os.path.getsize(out), "bytes")


def main():
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        sys.exit("GEMINI_API_KEY is not set")
    ref = base64.b64encode(open(REFERENCE, "rb").read()).decode()
    for out, count, count_words, roster in SHEETS:
        render(key, ref, COMMON.format(count=count, count_words=count_words,
                                       roster=roster), out)


if __name__ == "__main__":
    main()
