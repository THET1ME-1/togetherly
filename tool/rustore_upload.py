#!/usr/bin/env python3
"""Загрузка AAB/APK в RuStore через Open API.

Поток (RuStore Open API):
  1. POST /public/auth          — получить токен (подпись приватным ключом).
  2. POST .../version           — создать черновик версии → versionId.
  3. POST .../version/{id}/aab   — залить файл сборки.
  4. POST .../version/{id}/commit — отправить версию на модерацию/публикацию.

⚠️ ПЕРВУЮ версию RuStore требует залить вручную через консоль
   (кнопка «Загрузить версию»). Этот скрипт — для последующих обновлений.

Зависимости:  pip install requests cryptography

Использование:
  export RUSTORE_KEY_ID="<Key ID из раздела «API RuStore»>"
  export RUSTORE_PRIVATE_KEY_PEM="$(cat private_key.pem)"   # приватный ключ
  python3 tool/rustore_upload.py \
      --package com.togetherly.love \
      --aab build/app/outputs/bundle/release/app-release.aab \
      --whatsnew "Релиз для RuStore"

Секреты НЕ хранить в репозитории — передавать через env / CI-secrets.
"""
import argparse
import base64
import os
import sys
from datetime import datetime, timezone

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

API = "https://public-api.rustore.ru"


def _load_private_key(pem: str):
    # Поддержка как «голого» base64 (PKCS#8 без заголовков), так и полного PEM.
    pem = pem.strip()
    if "BEGIN" not in pem:
        pem = (
            "-----BEGIN PRIVATE KEY-----\n"
            + "\n".join(pem[i : i + 64] for i in range(0, len(pem), 64))
            + "\n-----END PRIVATE KEY-----\n"
        )
    return serialization.load_pem_private_key(pem.encode(), password=None)


def get_token(key_id: str, private_key_pem: str) -> str:
    """Авторизация: подпись (keyId + timestamp) ключом по SHA512withRSA."""
    key = _load_private_key(private_key_pem)
    # RuStore парсит timestamp как ISO-8601 OffsetDateTime: миллисекунды и
    # смещение ЧЕРЕЗ ДВОЕТОЧИЕ (напр. 2024-01-01T00:00:00.123+00:00). Прежний
    # формат «+0000» (без двоеточия) сервер не парсил → 400 Bad Request на
    # /public/auth, и публикация падала на самом первом шаге.
    ts = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    message = (key_id + ts).encode()
    signature = base64.b64encode(
        key.sign(message, padding.PKCS1v15(), hashes.SHA512())
    ).decode()

    resp = requests.post(
        f"{API}/public/auth",
        json={"keyId": key_id, "timestamp": ts, "signature": signature},
        timeout=30,
    )
    if not resp.ok:
        # Тело ответа RuStore содержит причину (формат timestamp, подпись,
        # ключ). raise_for_status его прятал — падение выглядело «немым».
        sys.exit(
            f"RuStore auth {resp.status_code} на /public/auth: {resp.text}\n"
            f"(отправленный timestamp={ts})"
        )
    data = resp.json()
    token = (data.get("body") or {}).get("jwe")
    if not token:
        sys.exit(f"Не удалось получить токен: {data}")
    return token


def _headers(token: str) -> dict:
    return {"Public-Token": token}


def create_version(token: str, package: str, whatsnew: str) -> int:
    # publishType=INSTANTLY → версия публикуется АВТОМАТИЧЕСКИ сразу после
    # прохождения модерации. С MANUAL версия проходила модерацию, но зависала
    # в «готова к публикации» и требовала ручного нажатия «Опубликовать» в
    # консоли — снаружи выглядело как «сборка по тегу не доходит до публикации».
    resp = requests.post(
        f"{API}/public/v1/application/{package}/version",
        headers={**_headers(token), "Content-Type": "application/json"},
        json={"whatsNew": whatsnew, "publishType": "INSTANTLY"},
        timeout=30,
    )
    resp.raise_for_status()
    version_id = resp.json().get("body")
    print(f"Создан черновик версии: {version_id}")
    return version_id


def upload_build(token: str, package: str, version_id: int, path: str):
    ext = "aab" if path.endswith(".aab") else "apk"
    with open(path, "rb") as f:
        resp = requests.post(
            f"{API}/public/v1/application/{package}/version/{version_id}/{ext}",
            headers=_headers(token),
            files={"file": (os.path.basename(path), f, "application/octet-stream")},
            timeout=600,
        )
    resp.raise_for_status()
    print(f"Сборка загружена ({ext}).")


def commit_version(token: str, package: str, version_id: int):
    resp = requests.post(
        f"{API}/public/v1/application/{package}/version/{version_id}/commit",
        headers=_headers(token),
        timeout=60,
    )
    resp.raise_for_status()
    print("Версия отправлена на публикацию.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True)
    ap.add_argument("--aab", required=True)
    ap.add_argument("--whatsnew", default="Обновление")
    args = ap.parse_args()

    key_id = os.environ.get("RUSTORE_KEY_ID")
    private_key = os.environ.get("RUSTORE_PRIVATE_KEY_PEM")
    if not key_id or not private_key:
        sys.exit("Заданы не все переменные: RUSTORE_KEY_ID, RUSTORE_PRIVATE_KEY_PEM")
    if not os.path.exists(args.aab):
        sys.exit(f"Файл не найден: {args.aab}")

    token = get_token(key_id, private_key)
    version_id = create_version(token, args.package, args.whatsnew)
    upload_build(token, args.package, version_id, args.aab)
    commit_version(token, args.package, version_id)
    print("Готово.")


if __name__ == "__main__":
    main()
