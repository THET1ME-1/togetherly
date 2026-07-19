#!/usr/bin/env python3
"""Добавляет индексы под инкрементальную синхронизацию offline-first клиента.

Дельта-запросы клиента (PbRealtimeService.syncOnce) фильтруют по
`<scope> && updated > <водяной_знак>` с сортировкой по `updated`, но индексы
коллекций были только по created_at/ts → на больших таблицах (memories 273k+)
каждый инкремент частично сканировал таблицу, грузя единственный SQLite-writer.

Скрипт ИДЕМПОТЕНТЕН и БЕРЕЖЕН: читает ЖИВЫЕ индексы коллекции через API и лишь
ДОБАВЛЯЕТ недостающие (ничего не заменяет и не удаляет) — расхождение репо-схемы
с живой БД не приводит к потере индексов. Рестарт PB не нужен: PATCH коллекции
синхронизирует индексы на лету (writer притормозит на ~1-2с на memories).

Креды берутся из окружения (НЕ хардкодить в репо):
    PB_URL=https://togetherly.duckdns.org   (по умолчанию)
    PB_EMAIL=...  PB_PASSWORD=...            (суперюзер)

Запуск:
    PB_EMAIL=... PB_PASSWORD=... python3 pocketbase/apply_sync_indexes.py
"""
import json
import os
import urllib.request
import urllib.error

PB_URL = os.environ.get("PB_URL", "https://togetherly.duckdns.org").rstrip("/")
PB_EMAIL = os.environ["PB_EMAIL"]
PB_PASSWORD = os.environ["PB_PASSWORD"]

# Коллекция → добавляемый индекс. Состав повторяет фильтры syncOnce:
#   memories/chat/mascots/widget_data/chat_reads/miss_you → group_id && updated
#   memory_comments → memory_id && updated (фильтр там по memory_id)
#   mood_entries    → group_id && user_uid && updated
#   groups          → members ~ uid && updated (LIKE не индексируется, но после
#                     первого синка условие updated>wm высокоселективно → индекс
#                     по updated убирает полный скан таблицы групп)
INDEXES = {
    "memories": "CREATE INDEX `idx_memories_group_id_updated` ON `memories` (`group_id`, `updated`)",
    "memory_comments": "CREATE INDEX `idx_memory_comments_memory_id_updated` ON `memory_comments` (`memory_id`, `updated`)",
    "mood_entries": "CREATE INDEX `idx_mood_entries_group_id_user_uid_updated` ON `mood_entries` (`group_id`, `user_uid`, `updated`)",
    "chat_messages": "CREATE INDEX `idx_chat_messages_group_id_updated` ON `chat_messages` (`group_id`, `updated`)",
    "mascots": "CREATE INDEX `idx_mascots_group_id_updated` ON `mascots` (`group_id`, `updated`)",
    "widget_data": "CREATE INDEX `idx_widget_data_group_id_updated` ON `widget_data` (`group_id`, `updated`)",
    "chat_reads": "CREATE INDEX `idx_chat_reads_group_id_updated` ON `chat_reads` (`group_id`, `updated`)",
    "miss_you": "CREATE INDEX `idx_miss_you_group_id_updated` ON `miss_you` (`group_id`, `updated`)",
    "groups": "CREATE INDEX `idx_groups_updated` ON `groups` (`updated`)",
}


def api(method, path, token=None, body=None):
    url = PB_URL + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
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


def index_name(sql):
    """Имя индекса из SQL (для идемпотентности сравниваем по имени, не по тексту)."""
    return sql.split("`")[1] if "`" in sql else sql


def main():
    token = auth()
    for col, sql in INDEXES.items():
        st, cur = api("GET", f"/api/collections/{col}", token=token)
        if st != 200:
            print(f"[SKIP] {col}: GET {st} {cur}")
            continue
        live = list(cur.get("indexes") or [])
        names = {index_name(s) for s in live}
        if index_name(sql) in names:
            print(f"[OK]   {col}: индекс уже есть")
            continue
        st, res = api("PATCH", f"/api/collections/{col}", token=token,
                      body={"indexes": live + [sql]})
        if st == 200:
            print(f"[ADD]  {col}: {index_name(sql)}")
        else:
            print(f"[FAIL] {col}: PATCH {st} {res}")


if __name__ == "__main__":
    main()
