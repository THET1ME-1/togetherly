# -*- coding: utf-8 -*-
"""Опубликовать маскота ИЛИ пак настроений в каталог PocketBase — картинки →
WebP, строка → коллекция `catalog_items`. БЕЗ релиза приложения. PB-аналог
tools/catalog_publish.py (который лил в Supabase; миграция → PocketBase).

Картинка маскота хранится ПРЯМО на записи `catalog_items` (file-поле `image`) —
никакой примеси в коллекцию `media` (она для контента пар). URL вида
    https://togetherly.duckdns.org/api/files/catalog_items/<id>/<file>
кладётся в `catalog_items.data.url`. Поле `image` создаётся идемпотентно при
первом запуске. Файлы PB публичны (поле не protected), а у `catalog_items`
viewRule='' → клиент читает каталог без входа, CachedNetworkImage грузит по URL.

Паки настроений (kind=mood_pack) несут НЕСКОЛЬКО картинок (по одной на эмоцию),
которые на одну запись file-полем не ложатся → их блобы хранятся в `media`
с kind='catalog' (отдельно от пар-медиа по фильтру kind).

Креды суперюзера — из окружения (НЕ хардкодить):
    PB_URL=https://togetherly.duckdns.org   (по умолчанию)
    PB_EMAIL=...  PB_PASSWORD=...            (суперюзер PB)

Запуск (все 4 маскота-награды за уровень — один прогон):
    PB_EMAIL=badzoff@gmail.com PB_PASSWORD=*** \
      python tools/catalog_publish_pb.py \
      tools/catalog/spiky.json tools/catalog/lulu.json \
      tools/catalog/iskrik.json tools/catalog/zhuzha.json

Можно передать каталог — возьмёт все *.json внутри:
    PB_EMAIL=... PB_PASSWORD=... python tools/catalog_publish_pb.py tools/catalog
"""
import glob
import io
import json
import os
import sys
from collections import deque

import requests
from PIL import Image

PB_URL = os.environ.get("PB_URL", "https://togetherly.duckdns.org").rstrip("/")
PB_EMAIL = os.environ.get("PB_EMAIL", "")
PB_PASSWORD = os.environ.get("PB_PASSWORD", "")
SIZE = 512
MARGIN = 0.06
TOLERANCE = 55


# ── обработка картинки (идентична tools/catalog_publish.py) ────────────────────
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


# ── PocketBase REST ────────────────────────────────────────────────────────────
def auth():
    if not PB_EMAIL or not PB_PASSWORD:
        sys.exit("ERROR: задай PB_EMAIL и PB_PASSWORD (суперюзер PocketBase).")
    r = requests.post(
        f"{PB_URL}/api/collections/_superusers/auth-with-password",
        json={"identity": PB_EMAIL, "password": PB_PASSWORD}, timeout=60,
    )
    if r.status_code != 200:
        sys.exit(f"auth failed: HTTP {r.status_code} {r.text[:300]}")
    return r.json()["token"]


def ensure_image_field(token):
    """Идемпотентно добавляет file-поле `image` в коллекцию catalog_items."""
    h = {"Authorization": token}
    r = requests.get(f"{PB_URL}/api/collections/catalog_items", headers=h, timeout=60)
    r.raise_for_status()
    col = r.json()
    fields = col.get("fields", col.get("schema", []))
    if any(f.get("name") == "image" for f in fields):
        return
    fields.append({
        "name": "image", "type": "file", "required": False,
        "maxSelect": 1, "maxSize": 5 * 1024 * 1024, "mimeTypes": [],
    })
    col["fields"] = fields
    r2 = requests.patch(f"{PB_URL}/api/collections/{col['id']}", headers=h,
                        json=col, timeout=60)
    if r2.status_code != 200:
        raise RuntimeError(f"add image field: HTTP {r2.status_code} {r2.text[:300]}")
    print("  + поле image добавлено в catalog_items")


def upload_media(token, filename, data):
    """Заливает байты как запись media (kind='catalog') → публичный file-URL.
    Только для мульти-картиночных паков настроений."""
    r = requests.post(
        f"{PB_URL}/api/collections/media/records",
        headers={"Authorization": token},
        data={"kind": "catalog"},
        files={"file": (filename, data, "image/webp")},
        timeout=120,
    )
    r.raise_for_status()
    rec = r.json()
    return f"{PB_URL}/api/files/media/{rec['id']}/{rec['file']}"


def upsert_catalog_item(token, row, image=None):
    """update по id → при 404 create с этим id (id = slug, напр. 'spiky').
    Если передан [image] (filename, bytes) — грузим его в file-поле `image`
    мультипартом и возвращаем сохранённое имя файла."""
    cid = row["id"]
    h = {"Authorization": token}
    if image is not None:
        # мультипарт: json-поле data сериализуем строкой, файл — в `image`
        form = {k: (json.dumps(v) if isinstance(v, (dict, list, bool)) else v)
                for k, v in row.items()}
        files = {"image": (image[0], image[1], "image/webp")}
        r = requests.patch(
            f"{PB_URL}/api/collections/catalog_items/records/{cid}",
            headers=h, data=form, files=files, timeout=120,
        )
        if r.status_code == 404:
            r = requests.post(
                f"{PB_URL}/api/collections/catalog_items/records",
                headers=h, data=form, files=files, timeout=120,
            )
    else:
        r = requests.patch(
            f"{PB_URL}/api/collections/catalog_items/records/{cid}",
            headers=h, json=row, timeout=60,
        )
        if r.status_code == 404:
            r = requests.post(
                f"{PB_URL}/api/collections/catalog_items/records",
                headers=h, json=row, timeout=60,
            )
    if r.status_code not in (200, 201):
        raise RuntimeError(f"catalog_items upsert {cid}: HTTP {r.status_code} {r.text[:300]}")
    return r.json().get("image")


# ── публикация одного описания ────────────────────────────────────────────────
def publish(token, desc_path):
    with open(desc_path, encoding="utf-8") as f:
        d = json.load(f)
    base = os.path.dirname(desc_path)
    kind = d["kind"]
    cid = d["id"]
    remove_bg = bool(d.get("removeBg", False))

    def base_row(data):
        return {
            "id": cid, "kind": kind,
            "name_ru": d["nameRu"], "name_en": d["nameEn"],
            "is_free": d.get("isFree", True),
            "min_app": d.get("minApp") or "",
            "sort": d.get("sort", 0),
            "data": data, "enabled": True,
        }

    if kind == "mascot":
        # Картинка — file-поле `image` на самой записи каталога (не в media).
        img = to_webp(os.path.join(base, d["image"]), remove_bg)
        data = {}
        if "unlock" in d:
            data["unlock"] = d["unlock"]
        stored = upsert_catalog_item(token, base_row(data),
                                     image=(f"{cid}.webp", img))
        url = f"{PB_URL}/api/files/catalog_items/{cid}/{stored}"
        data["url"] = url
        # дописать url в data (теперь известно сохранённое имя файла)
        r = requests.patch(
            f"{PB_URL}/api/collections/catalog_items/records/{cid}",
            headers={"Authorization": token}, json={"data": data}, timeout=60,
        )
        r.raise_for_status()
    elif kind == "mood_pack":
        moods = []
        for m in d["moods"]:
            url = upload_media(token, f"{cid}_{m['id']}.webp",
                               to_webp(os.path.join(base, m["image"]), remove_bg))
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
        upsert_catalog_item(token, base_row(data))
    else:
        sys.exit(f"ERROR: неизвестный kind '{kind}' в {desc_path}")

    print(f"OK: {kind} '{cid}' опубликован в PocketBase.")


def _expand(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(glob.glob(os.path.join(p, "*.json")))
        else:
            out.append(p)
    return out


def main(paths):
    descs = _expand(paths)
    if not descs:
        sys.exit("usage: python tools/catalog_publish_pb.py <descriptor.json> [...]")
    token = auth()
    ensure_image_field(token)
    for p in descs:
        publish(token, p)
    print(f"\nГотово: {len(descs)} элемент(ов) каталога в PocketBase.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python tools/catalog_publish_pb.py <descriptor.json> [...]")
    main(sys.argv[1:])
