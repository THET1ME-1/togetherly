/// Начисление монет за донат DonationAlerts. Вызывает воркер (donation_worker),
/// который опрашивает API донатов DA и шлёт сюда каждый донат. Экономика и
/// идемпотентность считаются ТОЛЬКО здесь (как в coins.pb.js).
///
/// POST /api/coins/donation-credit  body {secret, da_id, amount_rub, currency,
///   donor, message, email?, code?}
///   → 200 {ok:true, credited:N, uid}         начислено
///   → 200 {ok:true, already:true}            уже обработан (идемпотентность)
///   → 200 {ok:true, pending:true, reason}    не опознан → очередь ручной привязки
///   → 401 {ok:false}                         неверный секрет
///
/// Курс: 3 ₽ = 1 монета, мин. 50 ₽, бонус +15% от 300 ₽, +30% от 600 ₽.
/// Совпадение аккаунта: по code (users.donate_code) или email (users.email).
/// Не совпало / ниже минимума → pending_donations (тебе уведомление + привязка).
/// ВАЖНО (PB JSVM): хелперы инлайнятся внутрь обработчика.
routerAdd("POST", "/api/coins/donation-credit", (e) => {
  const body = e.requestInfo().body || {};
  const expect = $os.getenv("DONATION_SECRET");
  if (!expect || String(body.secret || "") !== expect) {
    return e.json(401, { ok: false, error: "unauthorized" });
  }

  const daId = String(body.da_id || "").trim();
  if (!daId) return e.json(400, { ok: false, error: "no da_id" });
  const amount = Math.floor(Number(body.amount_rub) || 0);
  const email = String(body.email || "").toLowerCase().trim();
  const code = String(body.code || "").trim();
  const donor = String(body.donor || "").slice(0, 120);
  const message = String(body.message || "").slice(0, 500);

  // ── идемпотентность: уже начислен или уже в очереди? ──────────────────────
  try {
    $app.findFirstRecordByFilter("donation_grants", "da_id = {:d}", { d: daId });
    return e.json(200, { ok: true, already: true });
  } catch (_) {}
  try {
    $app.findFirstRecordByFilter("pending_donations", "da_id = {:d}", { d: daId });
    return e.json(200, { ok: true, alreadyPending: true });
  } catch (_) {}

  // ── курс ──────────────────────────────────────────────────────────────────
  let coins = 0;
  if (amount >= 50) {
    coins = Math.floor(amount / 3);
    if (amount >= 600) coins = Math.floor(coins * 1.3);
    else if (amount >= 300) coins = Math.floor(coins * 1.15);
  }

  // ── найти аккаунт: сперва по коду, потом по email ─────────────────────────
  let user = null;
  if (code) {
    try { user = $app.findFirstRecordByFilter("users", "donate_code = {:c}", { c: code }); } catch (_) {}
  }
  if (!user && email) {
    try { user = $app.findFirstRecordByFilter("users", "email = {:e}", { e: email }); } catch (_) {}
  }

  // ── не опознан / ниже минимума → очередь ручной привязки ─────────────────
  const toPending = (reason) => {
    try {
      const col = $app.findCollectionByNameOrId("pending_donations");
      const r = new Record(col);
      r.set("da_id", daId);
      r.set("amount_rub", amount);
      r.set("coins", coins);
      r.set("donor", donor);
      r.set("message", message);
      r.set("email", email);
      r.set("code", code);
      r.set("status", "pending");
      $app.save(r);
    } catch (_) {}
    return e.json(200, { ok: true, pending: true, reason: reason });
  };
  if (coins <= 0) return toPending("below_min");
  if (!user) return toPending("no_user");

  // ── начислить (транзакция: баланс + запись-грант в одном коммите) ─────────
  try {
    $app.runInTransaction((tx) => {
      const u = tx.findRecordById("users", user.id);
      u.set("coins", (u.getInt("coins") || 0) + coins);
      tx.save(u);
      const gcol = tx.findCollectionByNameOrId("donation_grants");
      const g = new Record(gcol);
      g.set("da_id", daId);
      g.set("uid", user.id);
      g.set("coins", coins);
      g.set("amount_rub", amount);
      g.set("donor", donor);
      tx.save(g);
    });
  } catch (err) {
    return e.json(500, { ok: false, error: "save failed" });
  }
  return e.json(200, { ok: true, credited: coins, uid: user.id });
});
