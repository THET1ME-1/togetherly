# -*- coding: utf-8 -*-
"""Convert raw mascot art (flat solid-colour background, e.g. 2560x2560) into
lightweight TRANSPARENT WebP assets bundled in assets/images/mascots/.

For each source image:
  1. Flood-fill the background to transparent starting from the 4 corners with a
     colour tolerance. Only the connected OUTER region is removed, so internal
     pixels of a similar colour (and enclosed areas) are kept intact.
  2. Trim to the opaque bounding box.
  3. Centre on a transparent square canvas with a small margin.
  4. Resize to SIZE (LANCZOS — this also anti-aliases the cut-out edge nicely,
     since the source is much larger than the target).
  5. Save as alpha WebP (quality 90, method 6) — same settings as the mood packs.

Usage:
  1. Drop the 4 source images into tools/mascot_src/ named exactly (any ext):
        spiky.png  lulu.png  iskrik.png  zhuzha.png
  2. Run from the repo root:
        python tools/convert_mascots.py
  3. Output -> assets/images/mascots/<name>.webp  (already covered by pubspec).

Knobs: if a faint grey halo/shadow remains, raise TOLERANCE; if clean edges get
eaten, lower it. Run again and eyeball the result over a dark background.
"""
import os
from collections import deque
from PIL import Image

SRC = os.path.join("tools", "mascot_src")
DST = os.path.join("assets", "images", "mascots")
SIZE = 512
MARGIN = 0.06          # transparent breathing room around the sticker
TOLERANCE = 55         # 0..441 (per-channel ~32). Raise to kill shadow halo.

# Source filename stem -> output asset name (also the mascot id slug).
NAMES = ["spiky", "lulu", "iskrik", "zhuzha"]


def _dist2(a, b):
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def remove_background(im, tol):
    """Clear the connected background reachable from the four corners."""
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    tol2 = tol * tol
    seen = bytearray(w * h)
    corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    # Reference background = average of the four corners (robust to JPEG noise).
    bg = tuple(sum(px[c][i] for c in corners) // 4 for i in range(3))

    q = deque()
    for x, y in corners:
        if not seen[y * w + x]:
            seen[y * w + x] = 1
            q.append((x, y))

    while q:
        x, y = q.popleft()
        r, g, b, _ = px[x, y]
        if _dist2((r, g, b), bg) > tol2:
            continue  # reached the mascot — stop, keep this pixel opaque
        px[x, y] = (r, g, b, 0)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                seen[ny * w + nx] = 1
                q.append((nx, ny))
    return im


def find_source(stem):
    if not os.path.isdir(SRC):
        return None
    for f in os.listdir(SRC):
        name, ext = os.path.splitext(f)
        if name.lower() == stem and ext.lower() in (
            ".png", ".jpg", ".jpeg", ".webp", ".bmp"
        ):
            return os.path.join(SRC, f)
    return None


def main():
    os.makedirs(DST, exist_ok=True)
    done = 0
    for stem in NAMES:
        src = find_source(stem)
        if src is None:
            print("MISSING  %-10s -> put %s.<png|jpg> into %s/" % (stem, stem, SRC))
            continue

        im = remove_background(Image.open(src), TOLERANCE)

        bbox = im.getchannel("A").getbbox()
        if bbox:
            im = im.crop(bbox)

        side = int(round(max(im.width, im.height) * (1 + MARGIN)))
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2), im)
        canvas = canvas.resize((SIZE, SIZE), Image.LANCZOS)

        out = os.path.join(DST, stem + ".webp")
        canvas.save(out, "WEBP", quality=90, method=6)
        kb = os.path.getsize(out) / 1024
        print("OK       %-10s -> %-12s %6.1f KB" % (stem, stem + ".webp", kb))
        done += 1

    print("\nConverted %d/%d" % (done, len(NAMES)))


if __name__ == "__main__":
    main()
