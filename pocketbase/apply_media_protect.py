# -*- coding: utf-8 -*-
"""Делает file-поле коллекции `media` PROTECTED (закрытие блокера «приватные
фото/видео отдаются по публичному URL без токена»). После этого
`/api/files/media/<id>/<file>` возвращает 403 без `?token=<fileToken>`, а токен
PB выдаёт только по viewRule коллекции (мы уже закрыли её по владельцу/члену —
apply_acl.py). Клиент добавляет токен через PbMediaService.resolveUrlAuthed.

Обновляет collections_schema.json + (если есть креды) PATCH-ит сервер.
Креды: PB_URL (по умолч. https://togetherly.duckdns.org), PB_EMAIL, PB_PW.
Запуск: PB_EMAIL=.. PB_PW=.. python pocketbase/apply_media_protect.py
"""
import json
import os
import sys
import urllib.request
import urllib.error

HERE = os.path.dirname(__file__)
SCHEMA = os.path.join(HERE, "collections_schema.json")
PB_URL = os.environ.get("PB_URL", "https://togetherly.duckdns.org").rstrip("/")
PB_EMAIL = os.environ.get("PB_EMAIL", "")
PB_PW = os.environ.get("PB_PW", "")


def update_file():
    with open(SCHEMA, encoding="utf-8") as f:
        doc = json.load(f)
    cols = doc["collections"] if isinstance(doc, dict) else doc
    media = next((c for c in cols if c.get("name") == "media"), None)
    if not media:
        print("[file] media не найдена в схеме"); return
    fields = media.get("fields", media.get("schema", []))
    fld = next((x for x in fields if x.get("name") == "file"), None)
    if not fld:
        print("[file] поле file не найдено в media"); return
    fld["protected"] = True
    with open(SCHEMA, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    print("[file] media.file.protected=true записано в collections_schema.json")


def api(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PB_URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        return e.code, (json.loads(raw) if raw else {})


def apply_server():
    st, d = api("POST", "/api/collections/_superusers/auth-with-password",
                body={"identity": PB_EMAIL, "password": PB_PW})
    if st != 200:
        sys.exit(f"auth failed: {st} {d}")
    token = d["token"]
    st, media = api("GET", "/api/collections/media", token)
    if st != 200:
        sys.exit(f"get media failed: {st} {media}")
    fields = media.get("fields", [])
    for x in fields:
        if x.get("name") == "file":
            x["protected"] = True
    media["fields"] = fields
    st, d = api("PATCH", f"/api/collections/{media['id']}", token, media)
    print(f"[server] media.file protected → HTTP {st}"
          + ("" if st == 200 else f"  {json.dumps(d, ensure_ascii=False)[:300]}"))


def main():
    update_file()
    if PB_EMAIL and PB_PW:
        apply_server()
    else:
        print("[server] PB_EMAIL/PB_PW не заданы — только файл обновлён.")


if __name__ == "__main__":
    main()
