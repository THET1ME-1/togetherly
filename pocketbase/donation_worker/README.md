# Donation → coins (DonationAlerts)

Авто-начисление монет за донаты на DonationAlerts. Для sideload/веб-версий
(GitHub-Android, RuStore, iOS-IPA), где нет магазинного биллинга.

## Как работает

1. `worker.py` (systemd `togetherly-donations` на VPS) раз в ~20 с опрашивает
   `GET https://www.donationalerts.com/api/v1/alerts/donations` по OAuth-токену.
2. На каждый донат шлёт `POST /api/coins/donation-credit` в PocketBase.
3. Хук `pb_hooks/donations.pb.js` считает монеты и начисляет.

## Экономика

- **3 ₽ = 1 монета**, минимум **50 ₽**.
- Бонус: **+15 %** от 300 ₽, **+30 %** от 600 ₽.
- Совпадение аккаунта: `users.donate_code` (если задан) или `users.email`,
  вытащенные из **сообщения к донату**. Донатер обязан указать свой email/код.
- Не опознан / ниже минимума → `pending_donations` (ручная привязка).
- Идемпотентность по `da_id` (`donation_grants`).

## Секреты (НЕ в репозитории)

- `/etc/togetherly-donations.env`: `DA_TOKEN`, `DONATION_SECRET`, `PB_URL`,
  `POLL_INTERVAL`.
- PocketBase: drop-in `pocketbase.service.d/donation.conf` с `DONATION_SECRET`.
- DA OAuth-приложение id `20107`, аккаунт `thet1me` (user_id 15716741). Токен
  живёт ~год; при истечении обновить через refresh-token (`da_token.json`).

## Деплой

```
scp pb_hooks/donations.pb.js  root@VPS:/opt/pocketbase/pb_hooks/
scp donation_worker/worker.py root@VPS:/opt/donation_worker/
scp donation_worker/togetherly-donations.service root@VPS:/etc/systemd/system/
# env-файлы завести вручную; затем:
systemctl daemon-reload && systemctl restart pocketbase
systemctl enable --now togetherly-donations
```

Коллекции `donation_grants` / `pending_donations` создаются один раз через
API суперюзером (см. историю; поля text/number + autodate created/updated,
уникальный индекс на `da_id`).
