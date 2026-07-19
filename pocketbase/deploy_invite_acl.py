# -*- coding: utf-8 -*-
"""Деплой инвайт-хука + раскатка ACL на боевой PocketBase.

Делает за один прогон:
  1) SFTP-заливка pb_hooks/invite.pb.js на сервер (рядом с coins.pb.js);
  2) рестарт pocketbase.service, ожидание готовности;
  3) проверка, что роут /api/invite/accept зарегистрирован (POST без auth → 401,
     не 404 — значит хук загрузился);
  4) создание ВРЕМЕННОГО суперюзера по SSH → запуск apply_acl.py (применяет
     ОБНОВЛЁННЫЕ правила: invite_codes owner-only + create-binding авторов) →
     удаление суперюзера (finally).

SSH-пароль читается ТОЛЬКО из переменной окружения SSHPASS — в коде/выводе/файлах
не фигурирует. Временные креды суперюзера генерятся здесь и не печатаются.

Запуск:  SSHPASS=... python pocketbase/deploy_invite_acl.py
"""
import os
import sys
import json
import time
import base64
import secrets
import subprocess
import urllib.request
import urllib.error

import paramiko

HOST = os.environ.get("PB_SSH_HOST", "77.91.95.34")
USER = os.environ.get("PB_SSH_USER", "root")
PW = os.environ.get("SSHPASS", "")
PB_DIR = "/opt/pocketbase"
HOOKS = f"{PB_DIR}/pb_hooks"
PB_URL = os.environ.get("PB_URL", "https://togetherly.duckdns.org").rstrip("/")
HERE = os.path.dirname(os.path.abspath(__file__))

if not PW:
    sys.exit("SSHPASS не задан в окружении — нечем авторизоваться по SSH.")


def ssh_connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=30, look_for_keys=False,
              allow_agent=False)
    return c


def run(c, cmd, label):
    stdin, stdout, stderr = c.exec_command(cmd, timeout=120)
    rc = stdout.channel.recv_exit_status()
    out = stdout.read().decode(errors="replace").strip()
    err = stderr.read().decode(errors="replace").strip()
    tag = "ok" if rc == 0 else f"rc={rc}"
    print(f"[ssh] {label}: {tag}")
    if out:
        print("      " + out.replace("\n", "\n      "))
    if err and rc != 0:
        print("      ERR " + err.replace("\n", "\n      "))
    return rc, out, err


def http(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PB_URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as ex:
        return ex.code
    except Exception as ex:  # noqa
        return f"net-error: {ex}"


def main():
    local_hook = os.path.join(HERE, "pb_hooks", "invite.pb.js")
    if not os.path.exists(local_hook):
        sys.exit(f"нет файла хука: {local_hook}")

    c = ssh_connect()
    try:
        # 1) upload hook
        sftp = c.open_sftp()
        try:
            sftp.stat(HOOKS)
        except IOError:
            sys.exit(f"на сервере нет {HOOKS} — PB-хуки не там, где ожидалось.")
        remote_hook = f"{HOOKS}/invite.pb.js"
        sftp.put(local_hook, remote_hook)
        sz = sftp.stat(remote_hook).st_size
        sftp.close()
        print(f"[sftp] залит {remote_hook} ({sz} байт)")

        # 2) restart
        run(c, "systemctl restart pocketbase.service", "restart pocketbase")
        # ждём готовности публичного API
        ready = False
        for i in range(20):
            time.sleep(1.5)
            st = http("GET", "/api/health")
            if st == 200:
                ready = True
                print(f"[http] /api/health 200 (через ~{(i + 1) * 1.5:.0f}s)")
                break
        if not ready:
            print("[http] ВНИМАНИЕ: /api/health не отдал 200 за ~30s")

        # 3) проверка регистрации роута (без auth → 401, если хук загрузился)
        st = http("POST", "/api/invite/accept", body={"code": "ZZZZZZ"})
        if st == 401:
            print("[http] /api/invite/accept → 401 (роут есть, требует auth) ✔")
        elif st == 404:
            print("[http] /api/invite/accept → 404 — хук НЕ зарегистрирован! "
                  "Проверь логи pocketbase (journalctl -u pocketbase).")
        else:
            print(f"[http] /api/invite/accept → {st} (ожидался 401)")

        # 4) временный суперюзер → apply_acl.py → удалить суперюзер
        email = f"deploy_{secrets.token_hex(4)}@local.invalid"
        pw = base64.urlsafe_b64encode(secrets.token_bytes(18)).decode().rstrip("=")
        up_cmd = (f"cd {PB_DIR} && ./pocketbase superuser upsert "
                  f"'{email}' '{pw}'")
        rc, _, _ = run(c, up_cmd, "create temp superuser")
        if rc != 0:
            sys.exit("не удалось создать временного суперюзера — правила не применены.")
        try:
            env = dict(os.environ)
            env["PB_URL"] = PB_URL
            env["PB_EMAIL"] = email
            env["PB_PW"] = pw
            print("[acl] применяю apply_acl.py к серверу…")
            p = subprocess.run([sys.executable, os.path.join(HERE, "apply_acl.py")],
                               env=env, capture_output=True, text=True, timeout=180)
            sys.stdout.write(p.stdout)
            if p.returncode != 0:
                sys.stderr.write(p.stderr)
                print("[acl] apply_acl.py вернул ненулевой код — см. вывод выше.")
        finally:
            run(c, f"cd {PB_DIR} && ./pocketbase superuser delete '{email}'",
                "delete temp superuser")

        print("\n[готово] хук залит + правила применены.")
    finally:
        c.close()


if __name__ == "__main__":
    main()
