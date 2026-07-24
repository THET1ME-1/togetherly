#!/usr/bin/env python3
"""Опрашивает API донатов DonationAlerts и шлёт каждый донат в PocketBase-хук
`/api/coins/donation-credit`, который начисляет монеты (идемпотентно по id
доната). Только стандартная библиотека — на сервере ничего ставить не нужно.

Конфиг из окружения (см. donation_worker.env, НЕ в репозитории):
  DA_TOKEN          — access-token DonationAlerts (scope donation-index)
  PB_URL            — базовый URL PocketBase (по умолчанию http://127.0.0.1:8090)
  DONATION_SECRET   — общий секрет с хуком
  POLL_INTERVAL     — период опроса, сек (по умолчанию 20)
"""
import json
import os
import re
import time
import urllib.error
import urllib.request

DA_TOKEN = os.environ["DA_TOKEN"]
PB_URL = os.environ.get("PB_URL", "http://127.0.0.1:8090").rstrip("/")
SECRET = os.environ["DONATION_SECRET"]
INTERVAL = int(os.environ.get("POLL_INTERVAL", "20"))

# Грубые курсы к рублю (донаты в основном в RUB; прочее — приблизительно).
RATES = {"RUB": 1.0, "USD": 95.0, "EUR": 105.0, "UAH": 2.5, "KZT": 0.2, "BYN": 30.0}
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
CODE_RE = re.compile(r"\b[A-HJ-NP-Z2-9]{6}\b")  # инвайт-подобный код аккаунта


def _get(url, headers):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.load(r)


def _post(url, data):
    body = json.dumps(data).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.load(r)


def to_rub(amount, currency):
    return int(round(amount * RATES.get((currency or "RUB").upper(), 1.0)))


def process():
    # Первая страница = свежие донаты; хук отсекает уже обработанные по da_id.
    data = _get(
        "https://www.donationalerts.com/api/v1/alerts/donations",
        {"Authorization": "Bearer " + DA_TOKEN},
    )
    for d in data.get("data", []):
        da_id = str(d.get("id"))
        msg = d.get("message") or ""
        amount = float(d.get("amount") or 0)
        currency = d.get("currency") or "RUB"
        donor = d.get("username") or d.get("name") or ""
        em = EMAIL_RE.search(msg)
        cm = CODE_RE.search(msg.upper())
        payload = {
            "secret": SECRET,
            "da_id": da_id,
            "amount_rub": to_rub(amount, currency),
            "currency": currency,
            "donor": donor,
            "message": msg,
            "email": em.group(0).lower() if em else "",
            "code": cm.group(0) if cm else "",
        }
        try:
            res = _post(PB_URL + "/api/coins/donation-credit", payload)
        except urllib.error.HTTPError as ex:
            print("[err] %s: HTTP %s %s" % (da_id, ex.code, ex.read()[:200]), flush=True)
            continue
        except Exception as ex:
            print("[err] %s: %s" % (da_id, ex), flush=True)
            continue
        if res.get("credited"):
            print("[credit] %s %s %s%s -> %s coins uid=%s"
                  % (da_id, donor, amount, currency, res["credited"], res.get("uid")), flush=True)
        elif res.get("pending"):
            print("[pending] %s %s %s%s reason=%s"
                  % (da_id, donor, amount, currency, res.get("reason")), flush=True)
        # already/alreadyPending — молча


def main():
    print("donation_worker start: poll %ss -> %s" % (INTERVAL, PB_URL), flush=True)
    while True:
        try:
            process()
        except Exception as ex:
            print("[loop-err] %s" % ex, flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
