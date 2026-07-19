# -*- coding: utf-8 -*-
"""Convert the raw "pink emoji pack" PNGs (~700KB, transparent) into lightweight
square WebP assets (~60KB) used by the in-app mood picker (Pink mood pack).

Each source sticker is trimmed to its opaque bounds, centred on a transparent
square canvas with a small margin (so the 1:1 tile crops nothing), resized to
448px and saved as alpha WebP. Filenames become the mood ids.

Run from the repo root:  python tools/convert_pink_pack.py
"""
import os
from PIL import Image

SRC = os.path.join("assets", "images", "new emodji", "emoji pack", "pink emoji pack")
DST = os.path.join("assets", "images", "mood_packs", "pink")
SIZE = 448
MARGIN = 0.06  # transparent breathing room around the sticker

# Cyrillic source filename (without extension) -> mood id
MAPPING = {
    "радость кавай": "happy",
    "кавай влюблен": "love",
    "кавай целующая": "kiss",
    "кавай смифная": "laugh",
    "кавай насалаждение": "bliss",
    "кавай крутая": "cool",
    "кавай стыдливая": "embarrassed",
    "кавай спит": "sleepy",
    "кавай грусть": "sad",
    "кавай разачарованна": "disappointed",
    "кавай расстроенная": "upset",
    "кавай плачет": "very_sad",
    "кавай очень злой": "anger",
    # Доп. эмоции (вторая партия) — дополняем pink pack до уровня classic.
    "болен": "sick",
    "кавай наслаждение": "drooling",
    "кавай подмигивает": "winking",
    "кавай скучает": "missing",
    "кавай юбез эмоций": "no_emotion",
    "страх кавай": "fear",
    "треважная кавай": "anxiety",
    "удивление кавай": "surprise",
    "уставший": "tired",
}

os.makedirs(DST, exist_ok=True)

done = 0
for fname in os.listdir(SRC):
    if not fname.lower().endswith(".png"):
        continue
    stem = os.path.splitext(fname)[0]
    mood_id = MAPPING.get(stem)
    if mood_id is None:
        print("SKIP (no mapping):", stem)
        continue

    im = Image.open(os.path.join(SRC, fname)).convert("RGBA")

    # Trim to opaque bounding box so every sticker is centred consistently.
    bbox = im.getchannel("A").getbbox()
    if bbox:
        im = im.crop(bbox)

    # Fit into a square canvas with margin (keeps decorations from touching edges).
    side = int(round(max(im.width, im.height) * (1 + MARGIN)))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2), im)

    canvas = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    out = os.path.join(DST, mood_id + ".webp")
    canvas.save(out, "WEBP", quality=90, method=6)
    kb = os.path.getsize(out) / 1024
    print("OK  %-14s -> %-14s %6.1f KB" % (stem, mood_id + ".webp", kb))
    done += 1

print("\nConverted %d/%d" % (done, len(MAPPING)))
