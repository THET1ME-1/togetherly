#!/usr/bin/env python3
"""Включает OAuth2-провайдера в PocketBase (поле oauth2 коллекции users).

PB v0.23+: провайдеры живут в users.oauth2.providers = [{name, clientId,
clientSecret}, ...]. Скрипт логинится суперюзером, добавляет/заменяет одного
провайдера и проверяет результат. Не трогает остальных провайдеров.

Запуск (значения — из кабинета сервиса; redirect URI у всех:
https://togetherly.duckdns.org/api/oauth2-redirect):

    PB_EMAIL=badzoff@gmail.com PB_PASSWORD=*** \
    PROVIDER=yandex \
    CLIENT_ID=3e7623fec7814a91be64bbef3e987b26 \
    CLIENT_SECRET=bb85147b7fcc48e4ae8a9325fbe01ef9 \
    python3 pocketbase/enable_oauth_provider.py
"""
import json
import os
import urllib.error
import urllib.request

PB_URL = os.environ.get("PB_URL", "https://togetherly.duckdns.org").rstrip("/")
PB_EMAIL = os.environ["PB_EMAIL"]
PB_PASSWORD = os.environ["PB_PASSWORD"]
PROVIDER = os.environ["PROVIDER"]
CLIENT_ID = os.environ["CLIENT_ID"]
CLIENT_SECRET = os.environ["CLIENT_SECRET"]


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
    st, login = api(
        "POST", "/api/collections/_superusers/auth-with-password",
        body={"identity": PB_EMAIL, "password": PB_PASSWORD},
    )
    if st != 200:
        raise SystemExit(f"PB auth failed: {st} {login}")
    token = login["token"]

    st, users = api("GET", "/api/collections/users", token)
    if st != 200:
        raise SystemExit(f"get users failed: {st} {users}")

    o = users.get("oauth2", {}) or {}
    o["enabled"] = True
    provs = [p for p in o.get("providers", []) if p.get("name") != PROVIDER]
    provs.append({"name": PROVIDER, "clientId": CLIENT_ID,
                  "clientSecret": CLIENT_SECRET})
    o["providers"] = provs

    st, d = api("PATCH", f"/api/collections/{users['id']}", token,
                {"oauth2": o})
    print(f"PATCH users.oauth2 ({PROVIDER}): HTTP {st}")
    if st != 200:
        print("  ОШИБКА:", json.dumps(d, ensure_ascii=False)[:600])
        raise SystemExit(1)

    st, users2 = api("GET", "/api/collections/users", token)
    names = [p.get("name")
             for p in (users2.get("oauth2", {}) or {}).get("providers", [])]
    print("OK. Включённые провайдеры:", names)


if __name__ == "__main__":
    main()
