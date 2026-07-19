# -*- coding: utf-8 -*-
"""Изоляция данных по членству в паре — выставляет API-правила всех коллекций
PocketBase (миграция, закрытие блокера безопасности «любой залогиненный читает
всю базу»). Делает ДВЕ вещи:
  1) обновляет правила в pocketbase/collections_schema.json (источник для apply);
  2) если заданы креды суперюзера — хирургически PATCH-ит правила на живой сервер
     (только rule-поля, схему/данные/индексы НЕ трогает).

Паттерн (проверен вживую): дочерние коллекции гейтятся join'ом к groups —
  @request.auth.id != "" && @collection.groups.id ?= <key> && @collection.groups.members ?~ @request.auth.id
(нужен именно ?~ для json-массива members и ?= для мульти-join; обычный ~ НЕ
матчится). groups — по своему members; live_location — по подстроке channel.

Креды (НЕ хардкодить):
    PB_URL (по умолч. https://togetherly.duckdns.org), PB_EMAIL, PB_PW (суперюзер)
Запуск (только файл, без сервера):   python pocketbase/apply_acl.py
Запуск с раскаткой на сервер:        PB_EMAIL=.. PB_PW=.. python pocketbase/apply_acl.py
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

RW = ("listRule", "viewRule", "createRule", "updateRule", "deleteRule")


def member(field):
    """Дочерняя коллекция: доступ только членам группы field (join к groups)."""
    e = (f'@request.auth.id != "" && @collection.groups.id ?= {field} '
         f'&& @collection.groups.members ?~ @request.auth.id')
    return {k: e for k in RW}


def member_authored(author_field, group_field="group_id"):
    """Как member(), но createRule дополнительно требует, чтобы поле-автор
    записи совпадало с создателем — анти-спуфинг ВНУТРИ пары (член не может
    создать запись от имени партнёра). ТОЛЬКО create: update оставляем по
    членству (иначе сломаются легитимные кросс-правки — напр. реакция на
    сообщение партнёра пишет в его chat_messages.reactions)."""
    r = member(group_field)
    r["createRule"] = f'{r["createRule"]} && {author_field} = @request.auth.id'
    return r


def same(expr):
    return {k: expr for k in RW}


def same_authored(expr, author_field):
    """same(), но create дополнительно привязывает поле-автор к создателю."""
    r = same(expr)
    r["createRule"] = f'{expr} && {author_field} = @request.auth.id'
    return r


GROUPS = '@request.auth.id != "" && members ?~ @request.auth.id'
CHANNEL = '@request.auth.id != "" && channel ~ @request.auth.id'
IAP = '@request.auth.id != "" && user_uid = @request.auth.id'
# Медиа. ЧТЕНИЕ (list/view): владелец своих (uid), член пары (group_id), а также
# ЛЮБЫЕ аватары (kind=avatars/avatar) — они не приватны и их ОБЯЗАН видеть
# партнёр. Аватар грузится с group_id = uid (а не реальный pairId), поэтому join
# к groups его НЕ пускал → партнёр получал 403 на файл и видел заглушку-букву.
# ЗАПИСЬ (create/update/delete) остаётся строгой: только владелец/член группы —
# чтобы по «аватарному» послаблению нельзя было перезаписать/удалить чужой файл.
MEDIA_READ = ('@request.auth.id != "" && (uid = @request.auth.id '
              '|| kind = "avatars" || kind = "avatar" '
              '|| (@collection.groups.id ?= group_id && @collection.groups.members ?~ @request.auth.id))')
MEDIA_WRITE = ('@request.auth.id != "" && (uid = @request.auth.id '
               '|| (@collection.groups.id ?= group_id && @collection.groups.members ?~ @request.auth.id))')
PUBLIC_READ_ADMIN_WRITE = {
    "listRule": "", "viewRule": "",
    "createRule": None, "updateRule": None, "deleteRule": None,
}

RULES = {
    "groups": same(GROUPS),
    # дочерние по group_id; *_authored — create привязан к автору (анти-спуфинг)
    "memories": member_authored("author_uid"),
    "mood_entries": member_authored("user_uid"),
    "chat_messages": member_authored("user_uid"),
    "canvas_strokes": member("group_id"),  # нет поля-автора на записи
    "memory_comments": member_authored("author_uid"),
    "widget_data": member_authored("user_uid"),
    "miss_you": member_authored("user_uid"),
    "canvas_meta": member("group_id"),
    "canvas_catalogue": member("group_id"),
    "mascots": member("group_id"),
    "chat_reads": member_authored("user_uid"),
    "canvas_live": member("group_id"),
    "chat_typing": member_authored("user_uid"),
    # ключ — собственный id записи (= id группы/пары)
    "live_sessions": member("id"),
    "migration_flags": member("id"),
    # ключ — pair_id (= id группы)
    "live_session_presence": member_authored("user_uid", "pair_id"),
    "live_session_chat": member_authored("uid", "pair_id"),
    # presence «онлайн»: пишешь только свой (user_uid), читают все залогиненные
    # (онлайн-статус низкочувствителен, у записи нет привязки к группе).
    "user_presence": {
        "listRule": '@request.auth.id != ""',
        "viewRule": '@request.auth.id != ""',
        "createRule": '@request.auth.id != "" && user_uid = @request.auth.id',
        "updateRule": '@request.auth.id != "" && user_uid = @request.auth.id',
        "deleteRule": '@request.auth.id != "" && user_uid = @request.auth.id',
    },
    # live-локация: канал pair_<uidA>_<uidB>; create — точку пишешь только за себя
    "live_location": same_authored(CHANNEL, "user_uid"),
    # покупки — только свои
    "iap_purchases": same(IAP),
    # медиа — чтение: владелец/член/любые аватары; запись: строго владелец/член
    "media": {
        "listRule": MEDIA_READ,
        "viewRule": MEDIA_READ,
        "createRule": MEDIA_WRITE,
        "updateRule": MEDIA_WRITE,
        "deleteRule": MEDIA_WRITE,
    },
    # публичный контент: чтение всем, запись только суперюзер
    "app_config": dict(PUBLIC_READ_ADMIN_WRITE),
    "catalog_items": dict(PUBLIC_READ_ADMIN_WRITE),
    # invite_codes: owner-only (закрыт enumeration кодов). Приём идёт серверным
    # хуком /api/invite/accept (pb_hooks/invite.pb.js) под $app — он же удаляет
    # чужой код (правила не применяются к $app). Клиент создаёт/удаляет ТОЛЬКО
    # свои коды; create привязан к owner_uid (нельзя завести код за другого).
    "invite_codes": {
        "listRule": '@request.auth.id != "" && owner_uid = @request.auth.id',
        "viewRule": '@request.auth.id != "" && owner_uid = @request.auth.id',
        "createRule": '@request.auth.id != "" && owner_uid = @request.auth.id',
        "updateRule": '@request.auth.id != "" && owner_uid = @request.auth.id',
        "deleteRule": '@request.auth.id != "" && owner_uid = @request.auth.id',
    },
}


def update_file():
    with open(SCHEMA, encoding="utf-8") as f:
        doc = json.load(f)
    cols = doc["collections"] if isinstance(doc, dict) else doc
    by = {c["name"]: c for c in cols}
    touched, missing = [], []
    for name, rules in RULES.items():
        c = by.get(name)
        if not c:
            missing.append(name)
            continue
        for k, v in rules.items():
            c[k] = v
        touched.append(name)
    with open(SCHEMA, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    print(f"[file] обновлено правил в collections_schema.json: {len(touched)} коллекций")
    if missing:
        print(f"[file] ВНИМАНИЕ: нет в схеме (пропущены): {missing}")
    # коллекции в схеме без явного правила (кроме invite_codes) — подсветить
    no_rule = [c["name"] for c in cols if c["name"] not in RULES and c["name"] != "invite_codes"]
    if no_rule:
        print(f"[file] без правил в RULES (оставлены как есть): {no_rule}")
    return [c["name"] for c in cols]


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
    ok = fail = 0
    for name, rules in RULES.items():
        st, d = api("PATCH", f"/api/collections/{name}", token, rules)
        if st == 200:
            ok += 1
        else:
            fail += 1
            print(f"  ! {name}: HTTP {st} {json.dumps(d, ensure_ascii=False)[:200]}")
    print(f"[server] правила применены: ok={ok} fail={fail}")


def main():
    update_file()
    if PB_EMAIL and PB_PW:
        apply_server()
    else:
        print("[server] PB_EMAIL/PB_PW не заданы — только файл обновлён.")


if __name__ == "__main__":
    main()
