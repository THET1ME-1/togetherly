# -*- coding: utf-8 -*-
"""Опубликовать пак настроений ИЛИ маскота в удалённый каталог (Supabase) —
картинки → WebP → bucket `catalog`, строка → таблица `catalog_items`. БЕЗ SQL и
без релиза приложения.

Окружение (Supabase → Project Settings → API):
  SUPABASE_URL          (по умолчанию проектный)
  SUPABASE_SERVICE_KEY  СЕКРЕТНЫЙ service_role ключ (минует RLS). НЕ коммитить!

Описание контента — JSON-файл (картинки лежат рядом с ним). Примеры:
  tools/catalog/autumn.json   (пак), tools/catalog/halloween.json (маскот) — см. README.
Запуск:  SUPABASE_SERVICE_KEY=... python tools/catalog_publish.py tools/catalog/autumn.json
"""
import io
import json
import os
import sys
from collections import deque

import requests
from PIL import Image

URL = os.environ.get("SUPABASE_URL", "https://xxjlzzkhrvyiqaexvymx.supabase.co").rstrip("/")
KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
BUCKET = "catalog"
SIZE = 512
MARGIN = 0.06
TOLERANCE = 55


# ── обработка картинки ───────────────────────────────────────────────────────
def _remove_bg(im, tol):
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    tol2 = tol * tol
    seen = bytearray(w * h)
    corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    bg = tuple(sum(px[c][i] for c in corners) // 4 for i in range(3))
    q = deque()
    for x, y in corners:
        if not seen[y * w + x]:
            seen[y * w + x] = 1
            q.append((x, y))
    while q:
        x, y = q.popleft()
        r, g, b, _ = px[x, y]
        if (r - bg[0]) ** 2 + (g - bg[1]) ** 2 + (b - bg[2]) ** 2 > tol2:
            continue
        px[x, y] = (r, g, b, 0)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                seen[ny * w + nx] = 1
                q.append((nx, ny))
    return im


def to_webp(path, remove_bg):
    im = Image.open(path).convert("RGBA")
    if remove_bg:
        im = _remove_bg(im, TOLERANCE)
    bbox = im.getchannel("A").getbbox()
    if bbox:
        im = im.crop(bbox)
    side = int(round(max(im.width, im.height) * (1 + MARGIN)))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2), im)
    canvas = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    buf = io.BytesIO()
    canvas.save(buf, "WEBP", quality=90, method=6)
    return buf.getvalue()


# ── Supabase REST ────────────────────────────────────────────────────────────
def upload(path_in_bucket, data):
    r = requests.post(
        f"{URL}/storage/v1/object/{BUCKET}/{path_in_bucket}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "image/webp", "x-upsert": "true"},
        data=data,
    )
    r.raise_for_status()
    return f"{URL}/storage/v1/object/public/{BUCKET}/{path_in_bucket}"


def upsert_row(row):
    r = requests.post(
        f"{URL}/rest/v1/catalog_items",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json",
                 "Prefer": "resolution=merge-duplicates"},
        data=json.dumps(row),
    )
    r.raise_for_status()


# ── основной поток ───────────────────────────────────────────────────────────
def main(desc_path):
    if not KEY:
        sys.exit("ERROR: задай SUPABASE_SERVICE_KEY (service_role ключ из Supabase).")
    with open(desc_path, encoding="utf-8") as f:
        d = json.load(f)
    base = os.path.dirname(desc_path)
    kind = d["kind"]
    cid = d["id"]
    remove_bg = bool(d.get("removeBg", False))

    if kind == "mascot":
        url = upload(f"mascots/{cid}.webp", to_webp(os.path.join(base, d["image"]), remove_bg))
        data = {"url": url}
        # Требование разблокировки («задание»): {"type":"level","level":N} | {"type":"premium"}.
        if "unlock" in d:
            data["unlock"] = d["unlock"]
    elif kind == "mood_pack":
        moods = []
        for m in d["moods"]:
            url = upload(
                f"mood_packs/{cid}/{m['id']}.webp",
                to_webp(os.path.join(base, m["image"]), remove_bg),
            )
            entry = {"id": m["id"], "url": url}
            for k in ("labelRu", "labelEn", "color", "score"):
                if k in m:
                    entry[k] = m[k]
            moods.append(entry)
            print("  +", m["id"])
        data = {"moods": moods}
        if "tileGradient" in d:
            data["tileGradient"] = d["tileGradient"]
        if "unlock" in d:
            data["unlock"] = d["unlock"]
    else:
        sys.exit(f"ERROR: неизвестный kind '{kind}'")

    upsert_row({
        "id": cid, "kind": kind,
        "name_ru": d["nameRu"], "name_en": d["nameEn"],
        "is_free": d.get("isFree", True),
        "min_app": d.get("minApp"),
        "sort": d.get("sort", 0),
        "data": data, "enabled": True,
    })
    print(f"OK: {kind} '{cid}' опубликован.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python tools/catalog_publish.py <descriptor.json>")
    main(sys.argv[1])
