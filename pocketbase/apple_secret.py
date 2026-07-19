#!/usr/bin/env python3
"""Генерация/обновление Apple client secret для Sign In with Apple в PocketBase.

Apple «client secret» — это JWT (ES256), подписанный приватным ключом .p8, со
сроком ЖИЗНИ максимум 6 месяцев. По истечении вход через Apple перестаёт
работать → этот скрипт перевыпускает секрет и патчит провайдера `apple` в PB.

Запускать раз в ~5 месяцев (или когда Apple-вход начал давать invalid_client).

Идентификаторы (НЕ секреты — есть в клиенте) можно переопределить через env:
    APPLE_TEAM_ID   (по умолчанию Y2Z9V86248)
    APPLE_KEY_ID    (по умолчанию UTU5Y8TRY9)
    APPLE_SERVICES_ID (clientId, по умолчанию com.togetherly.love.signin)
    APPLE_P8_PATH   (путь к .p8; по умолчанию ~/Загрузки/AuthKey_<KEY_ID>.p8)
PB-доступ:
    PB_URL (по умолчанию https://togetherly.duckdns.org), PB_EMAIL, PB_PASSWORD

Зависимости: PyJWT + cryptography.
Запуск:
    PB_EMAIL=badzoff@gmail.com PB_PASSWORD=*** \
    APPLE_P8_PATH=/home/alelx/Загрузки/AuthKey_UTU5Y8TRY9.p8 \
    python3 pocketbase/apple_secret.py
"""
import json
import os
import time
import urllib.request
import urllib.error

import jwt

PB_URL = os.environ.get("PB_URL", "https://togetherly.duckdns.org").rstrip("/")
PB_EMAIL = os.environ["PB_EMAIL"]
PB_PASSWORD = os.environ["PB_PASSWORD"]

TEAM = os.environ.get("APPLE_TEAM_ID", "Y2Z9V86248")
KEY_ID = os.environ.get("APPLE_KEY_ID", "UTU5Y8TRY9")
SERVICES_ID = os.environ.get("APPLE_SERVICES_ID", "com.togetherly.love.signin")
P8_PATH = os.environ.get(
    "APPLE_P8_PATH",
    os.path.expanduser(f"~/Загрузки/AuthKey_{KEY_ID}.p8"),
)
# Apple лимит — не более 6 мес (15777000 с); берём 180 дней с запасом.
TTL = 15552000


def api(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PB_URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        return e.code, (json.loads(raw) if raw else {})


def main():
    p8 = open(P8_PATH).read()
    now = int(time.time())
    secret = jwt.encode(
        {"iss": TEAM, "iat": now, "exp": now + TTL,
         "aud": "https://appleid.apple.com", "sub": SERVICES_ID},
        p8, algorithm="ES256", headers={"kid": KEY_ID, "alg": "ES256"},
    )
    exp_str = time.strftime("%Y-%m-%d", time.localtime(now + TTL))
    print(f"Apple client secret перевыпущен, действует до {exp_str}")

    st, login = api("POST", "/api/collections/_superusers/auth-with-password",
                    body={"identity": PB_EMAIL, "password": PB_PASSWORD})
    if st != 200:
        raise SystemExit(f"PB auth failed: {st} {login}")
    token = login["token"]

    st, users = api("GET", "/api/collections/users", token)
    if st != 200:
        raise SystemExit(f"get users failed: {st} {users}")
    o = users.get("oauth2", {}) or {}
    o["enabled"] = True
    provs = [p for p in o.get("providers", []) if p.get("name") != "apple"]
    provs.append({"name": "apple", "clientId": SERVICES_ID,
                  "clientSecret": secret})
    o["providers"] = provs
    st, d = api("PATCH", f"/api/collections/{users['id']}", token,
                {"oauth2": o})
    print(f"PATCH users.oauth2 (apple): HTTP {st}")
    if st != 200:
        print("  ОШИБКА:", json.dumps(d, ensure_ascii=False)[:500])


if __name__ == "__main__":
    main()
