/// Приём оплат lava.top напрямую в PocketBase.
///
/// Главный путь — без кода и без бота: если почта покупки совпала с почтой
/// аккаунта, монеты падают на баланс сами, человек просто открывает приложение.
///
/// Запасной путь — код: платили с другой почты (рабочая, семейная, вход через
/// Google с иным адресом) или аккаунта ещё нет. Тогда создаётся запись в
/// `redeem_codes`, и код выдаёт бот @SnTAppsBot.
///
/// Защита: секрет в заголовке `X-Api-Key` (или `?key=`), он же вписан в
/// lava.top. Без него роут молчит — иначе монеты мог бы начислить кто угодно.
/// Секрет живёт в переменной окружения LAVA_WEBHOOK_KEY процесса PocketBase.
///
/// !!! ГРАБЛИ PB JSVM (см. coins.pb.js:5-19): обработчик исполняется в
/// ИЗОЛИРОВАННОМ пуле и НЕ видит функции уровня файла — всё инлайнится.

routerAdd("POST", "/api/lava/webhook", (e) => {
  // Товары lava.top → монеты. Зеркало bot/coins.py (PRODUCTS).
  const PRODUCTS = {
    "4d8ff539-fd74-47ab-85e4-35906be3a5b4": 600,
    "64e68f3f-7281-4593-aa00-0b438522750b": 1400,
    "cd2e08ec-e826-495d-bb55-842a3e3742dc": 4000,
  };
  const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

  const secret = $os.getenv("LAVA_WEBHOOK_KEY") || "";
  const given = e.request.header.get("X-Api-Key") ||
    e.request.url.query().get("key") || "";
  if (!secret || given !== secret) {
    return e.json(401, { ok: false, error: "bad_key" });
  }

  let payload = {};
  try {
    payload = e.requestInfo().body || {};
  } catch (_) {
    payload = {};
  }

  // lava.top присылает разные обёртки в зависимости от типа события, поэтому
  // ищем поля по всему дереву, а не по фиксированному пути (так же в bot/lava.py).
  const flat = {};
  const walk = (node, path) => {
    if (node === null || node === undefined) return;
    if (typeof node !== "object") {
      flat[path.toLowerCase()] = String(node);
      return;
    }
    for (const key in node) {
      walk(node[key], path ? path + "." + key : key);
    }
  };
  walk(payload, "");

  const pick = (names) => {
    for (const key in flat) {
      const tail = key.split(".").pop();
      for (let i = 0; i < names.length; i++) {
        if (tail === names[i] || key === names[i]) return flat[key];
      }
    }
    return "";
  };

  const status = (pick(["status", "eventtype", "event", "state", "type"]) || "")
    .toLowerCase();
  const paid = status.indexOf("success") !== -1 ||
    status.indexOf("paid") !== -1 ||
    status.indexOf("completed") !== -1 ||
    status.indexOf("subscription.recurring.payment.success") !== -1;
  if (!paid) {
    // Не оплата (отказ, тестовый пинг, возврат) — повторы делу не помогут.
    return e.json(200, { ok: true, skipped: status || "no_status" });
  }

  const email = (pick(["email", "buyeremail", "clientemail", "contactemail"]) || "")
    .trim().toLowerCase();
  const productId = (pick(["productid", "offerid", "parentid", "uuid", "id"]) || "")
    .trim().toLowerCase();
  const orderId = (pick(["contractid", "orderid", "invoiceid", "paymentid"]) || "").trim();
  const amount = PRODUCTS[productId];

  if (!amount) {
    // Товар другого приложения — этим занимается бот, не мы.
    return e.json(200, { ok: true, skipped: "not_ours", product: productId });
  }
  if (!email) {
    return e.json(400, { ok: false, error: "no_email" });
  }

  let out = { s: 500, b: { ok: false, error: "internal" } };
  try {
    $app.runInTransaction((txApp) => {
      // Идемпотентность: один заказ — одно начисление. Ключом служит номер
      // заказа, а при его отсутствии — почта с товаром (lava.top иногда шлёт
      // событие дважды).
      const key = ("LAVA" + (orderId || email + productId))
        .toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 30);

      // Ключ заказа живёт в отдельном поле: код у записи свой, и раньше
      // повторный вебхук по покупке без аккаунта заводил вторую запись.
      let existing = null;
      try {
        existing = txApp.findFirstRecordByFilter(
          "redeem_codes", "order_key = {:k}", { k: key });
      } catch (_) {
        existing = null;
      }
      if (existing) {
        out = { s: 200, b: { ok: true, repeated: true } };
        return;
      }

      // Ищем аккаунт с той же почтой: нашёлся — начисляем сразу.
      let user = null;
      try {
        user = txApp.findFirstRecordByFilter(
          "users", "email = {:e}", { e: email });
      } catch (_) {
        user = null;
      }

      const col = txApp.findCollectionByNameOrId("redeem_codes");
      const rec = new Record(col);
      rec.set("coins", amount);
      rec.set("sku", productId);
      rec.set("buyer_email", email);
      rec.set("order_key", key);

      if (user) {
        rec.set("code", key);
        rec.set("used_by", user.id);
        rec.set("used_at", Date.now());
        txApp.save(rec);

        user.set("coins", (user.getInt("coins") || 0) + amount);
        txApp.save(user);
        out = { s: 200, b: { ok: true, credited: amount, direct: true } };
        return;
      }

      // Аккаунта с такой почтой нет — заводим код для бота.
      let code = "";
      for (let i = 0; i < 8; i++) {
        code += ALPHABET.charAt(Math.floor(Math.random() * ALPHABET.length));
      }
      rec.set("code", "TG" + code);
      txApp.save(rec);
      out = { s: 200, b: { ok: true, credited: 0, direct: false } };
    });
  } catch (err) {
    try {
      $http.send({
        url: "http://127.0.0.1:8000/api/1/store/",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Sentry-Auth":
            "Sentry sentry_version=7, sentry_key=05953bce75c54cdb9fe149861d159da5",
        },
        body: JSON.stringify({
          message: "lava/webhook: " + String(err),
          level: "error",
          logger: "pb_hooks.lava",
          tags: { feature: "redeem", route: "lava_webhook", error_code: "server" },
        }),
        timeout: 5,
      });
    } catch (_) {}
    try {
      $app.logger().error("lava/webhook: " + String(err));
    } catch (_) {}
    out = { s: 500, b: { ok: false, error: "internal" } };
  }
  return e.json(out.s, out.b);
});
