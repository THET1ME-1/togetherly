#!/usr/bin/env python3
"""Идемпотентно применяет схему PocketBase (Этап 3 миграции Firebase→PocketBase).

Делает две вещи:
  1) импортирует базовые коллекции из collections_schema.json
     (PUT /api/collections/import, deleteMissing:false — только создаёт/мёрджит);
  2) дописывает в дефолтную auth-коллекцию `users` кастомные Firebase-поля
     (PATCH — пересоздавать auth-коллекцию нельзя) + уникальный индекс firebase_uid.

Креды берутся из окружения (НЕ хардкодить в репо):
    PB_URL=https://togetherly.duckdns.org   (по умолчанию)
    PB_EMAIL=...  PB_PASSWORD=...            (суперюзер)

Запуск:
    PB_EMAIL=badzoff@gmail.com PB_PASSWORD=*** python3 pocketbase/apply_schema.py
"""
import json
import os
import urllib.request
import urllib.error

PB_URL = os.environ.get("PB_URL", "https://togetherly.duckdns.org").rstrip("/")
PB_EMAIL = os.environ["PB_EMAIL"]
PB_PASSWORD = os.environ["PB_PASSWORD"]
HERE = os.path.dirname(__file__)


def api(method, path, token=None, body=None):
    url = PB_URL + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
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


def auth():
    st, d = api("POST", "/api/collections/_superusers/auth-with-password",
                body={"identity": PB_EMAIL, "password": PB_PASSWORD})
    if st != 200:
        raise SystemExit(f"auth failed: {st} {d}")
    return d["token"]


# ── кастомные поля users (Firebase-профиль). id остаётся авто-PB; Firebase UID
#    хранится в firebase_uid (uniq) — связи в данных ссылаются на него строкой. ──
def text(n):
    return {"name": n, "type": "text", "required": False}

def number(n):
    return {"name": n, "type": "number", "required": False}

def boolean(n):
    return {"name": n, "type": "bool", "required": False}

def date(n):
    return {"name": n, "type": "date", "required": False}

def jsonf(n):
    return {"name": n, "type": "json", "required": False, "maxSize": 5000000}

USERS_CUSTOM = [
    # сроки действия подарков-эффектов (epoch ms), см. lib/models/gift_effect.dart
    number("mute_until"), number("sunrise_until"),
    number("spa_until"), number("streak_shield_until"),
    text("display_name"), text("avatar_url"),
    text("gender"), date("birth_date"), number("coins"),
    jsonf("owned_themes"), jsonf("owned_icons"), jsonf("owned_features"),
    jsonf("granted_badges"), text("badge"), text("pair_id"), jsonf("pair_ids"),
    text("invite_code"), text("fcm_token"), jsonf("fcm_tokens"),
    boolean("notif_miss_you"), boolean("notif_new_memory"),
    boolean("notif_mood"), boolean("notif_chat"), jsonf("solo_timers"),
    date("updated_at"), date("last_daily_bonus_at"),
    date("last_memory_reward_at"), text("ad_rewards_date"),
    number("ad_rewards_today"), boolean("dev_coins_granted"),
    boolean("partner_invite_reward_granted"),
    jsonf("partner_invite_rewarded_keys"), jsonf("mood_streak_rewards"),
    # Кулдауны коин-наград — epoch-ms (number, а не date): надёжнее в pb_hooks
    # JSVM (тривиальное сравнение чисел вместо date-API). Заполняют коин-роуты.
    number("last_daily_bonus_ms"), number("last_memory_reward_ms"),
]
# Override поля id у users: принимать внешний id (= прежний uid мигрированного
# юзера, до 50 симв., смешанный регистр/'_'/'-'), но СОХРАНИТЬ автогенерацию
# для новых регистраций (autogeneratePattern не пустой).
USERS_ID_OVERRIDE = {
    "name": "id", "type": "text", "primaryKey": True, "required": True,
    "system": True, "pattern": "^[A-Za-z0-9_-]+$", "min": 1, "max": 50,
    "autogeneratePattern": "[a-z0-9]{15}",
}


def main():
    token = auth()

    # 1) импорт базовых коллекций
    with open(os.path.join(HERE, "collections_schema.json"), encoding="utf-8") as f:
        schema = json.load(f)
    st, d = api("PUT", "/api/collections/import", token, schema)
    print(f"[import] HTTP {st}" + ("" if st == 204 else f"  {json.dumps(d, ensure_ascii=False)[:400]}"))

    # 2) users: дописать кастомные поля (идемпотентно), УБРАТЬ устаревшее
    #    firebase_uid (поле+индекс) и переопределить id под внешние id.
    st, users = api("GET", "/api/collections/users", token)
    if st != 200:
        raise SystemExit(f"get users failed: {st} {users}")
    # выкинуть legacy-поле firebase_uid, если осталось с прошлых прогонов
    users["fields"] = [f for f in users["fields"] if f["name"] != "firebase_uid"]
    # override поля id
    users["fields"] = [USERS_ID_OVERRIDE if f["name"] == "id" else f
                       for f in users["fields"]]
    have = {f["name"] for f in users["fields"]}
    added = [f for f in USERS_CUSTOM if f["name"] not in have]
    if added:
        users["fields"] += added
    # индексы: убрать legacy firebase_uid
    users["indexes"] = [s for s in users.get("indexes", [])
                        if "idx_users_firebase_uid" not in s]
    st, d = api("PATCH", f"/api/collections/{users['id']}", token, users)
    print(f"[users] HTTP {st}  +полей={len(added)} (firebase_uid убран, id override)")
    if st != 200:
        print("  ОШИБКА:", json.dumps(d, ensure_ascii=False)[:500])


if __name__ == "__main__":
    main()
