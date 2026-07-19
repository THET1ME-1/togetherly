#!/usr/bin/env python3
"""Локальный релей PocketBase → Gmail API (этап cutover, отправка почты).

ЗАЧЕМ: провайдер VPS (hostkey) режет ВСЕ исходящие SMTP-порты (25/465/587/2525),
поэтому PocketBase не может слать письма по SMTP. Работает только HTTPS:443.
Gmail предоставляет HTTP-API (https://gmail.googleapis.com, порт 443) — через
него и шлём. Письма уходят с stgroup.dev@gmail.com, подписаны самим Google
(SPF/DKIM ок) → не попадают в спам.

КАК: PB-хук `gmail_mailer.pb.js` (onMailerSend) перехватывает каждое письмо и
POST'ит {to,subject,html,text} на этот релей (127.0.0.1, loopback — не блокируется).
Релей собирает MIME, добывает access-token из refresh-token (с кэшем ~1ч) и шлёт
в Gmail API. MIME/base64 в python тривиальны и корректны (в отличие от JSVM).

КРЕДЫ — из окружения (systemd EnvironmentFile=/etc/gmail-relay.env, режим 600,
НЕ в репозитории): GMAIL_CLIENT_ID/SECRET/REFRESH_TOKEN/SENDER_ADDR/SENDER_NAME.
Слушает только 127.0.0.1 → извне недоступен.
"""
import json
import os
import time
import threading
import base64
import urllib.request
import urllib.parse
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CID = os.environ["GMAIL_CLIENT_ID"]
CSEC = os.environ["GMAIL_CLIENT_SECRET"]
RT = os.environ["GMAIL_REFRESH_TOKEN"]
SENDER_ADDR = os.environ.get("GMAIL_SENDER_ADDR", "stgroup.dev@gmail.com")
SENDER_NAME = os.environ.get("GMAIL_SENDER_NAME", "Togetherly")
PORT = int(os.environ.get("GMAIL_RELAY_PORT", "8099"))

_tok = {"at": None, "exp": 0.0}
_lock = threading.Lock()


def _access_token():
    with _lock:
        if _tok["at"] and time.time() < _tok["exp"] - 60:
            return _tok["at"]
        data = urllib.parse.urlencode({
            "client_id": CID, "client_secret": CSEC,
            "refresh_token": RT, "grant_type": "refresh_token",
        }).encode()
        r = urllib.request.urlopen(
            "https://oauth2.googleapis.com/token", data=data, timeout=20)
        t = json.loads(r.read())
        _tok["at"] = t["access_token"]
        _tok["exp"] = time.time() + int(t.get("expires_in", 3600))
        return _tok["at"]


def _send(to, subject, html, text):
    m = EmailMessage()
    m["From"] = f"{SENDER_NAME} <{SENDER_ADDR}>"
    m["To"] = ", ".join(to)
    m["Subject"] = subject or ""
    m.set_content(text or " ")
    if html:
        m.add_alternative(html, subtype="html")
    raw = base64.urlsafe_b64encode(m.as_bytes()).decode()
    req = urllib.request.Request(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
        data=json.dumps({"raw": raw}).encode(),
        headers={"Authorization": "Bearer " + _access_token(),
                 "Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=20)
    return json.loads(r.read()).get("id")


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # healthcheck
        self._reply(200, {"ok": True, "service": "gmail-relay"})

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
            d = json.loads(self.rfile.read(n) or b"{}")
            to = d.get("to") or []
            if isinstance(to, str):
                to = [to]
            if not to:
                return self._reply(400, {"ok": False, "error": "no recipients"})
            mid = _send(to, d.get("subject", ""), d.get("html", ""), d.get("text", ""))
            print(f"gmail-relay: sent message id={mid}", flush=True)  # без PII (журнал)
            self._reply(200, {"ok": True, "id": mid})
        except Exception as e:  # noqa: BLE001
            print(f"gmail-relay ERROR: {e}", flush=True)
            self._reply(500, {"ok": False, "error": str(e)})

    def log_message(self, *a):  # тихо
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
