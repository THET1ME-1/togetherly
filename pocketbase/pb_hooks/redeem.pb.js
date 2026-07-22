/// Погашение кодов пополнения (покупка монет мимо магазинов).
///
/// Деньги принимает lava.top, бот выдаёт покупателю код и кладёт его в
/// коллекцию `redeem_codes`. Здесь код гасится: один код — одно погашение,
/// монеты уходят на аккаунт того, кто его ввёл.
///
/// Почему гасит сервер, а не приложение: подписанный офлайн-ключ (как в Fern)
/// можно предъявить с двух аккаунтов, а баланс монет живёт на сервере. Здесь
/// же запись помечается внутри транзакции, и повтор ничего не даёт.
///
/// !!! ГРАБЛИ PB JSVM (см. coins.pb.js:5-19): обработчик исполняется в
/// ИЗОЛИРОВАННОМ пуле и НЕ видит функции уровня файла — всё инлайнится.

routerAdd("POST", "/api/coins/redeem", (e) => {
  const body = new DynamicModel({ code: "" });
  e.bindBody(body);

  // Человек вводит код руками: чистим пробелы, дефисы и регистр, чтобы
  // «tg-4f2a b19c» и «TG4F2AB19C» считались одним кодом.
  const code = String(body.code || "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
  if (code.length < 6) {
    return e.json(400, { ok: false, error: "invalid_code" });
  }

  let out = { s: 500, b: { ok: false, error: "internal" } };
  try {
    $app.runInTransaction((txApp) => {
      const me = e.auth.id;
      const user = txApp.findRecordById("users", me);

      let rec = null;
      try {
        rec = txApp.findFirstRecordByFilter(
          "redeem_codes", "code = {:c}", { c: code });
      } catch (_) {
        rec = null;
      }
      if (!rec) {
        out = { s: 404, b: { ok: false, error: "invalid_code" } };
        return;
      }

      const usedBy = rec.getString("used_by") || "";
      if (usedBy) {
        // Свой же код, введённый повторно (обрыв связи после начисления) —
        // не ошибка: отвечаем спокойно и показываем текущий баланс.
        if (usedBy === me) {
          out = {
            s: 200,
            b: {
              ok: true,
              alreadyRedeemed: true,
              coins: user.getInt("coins") || 0,
              awarded: 0,
            },
          };
        } else {
          out = { s: 409, b: { ok: false, error: "code_used" } };
        }
        return;
      }

      const amount = rec.getInt("coins") || 0;
      if (amount <= 0) {
        out = { s: 400, b: { ok: false, error: "invalid_code" } };
        return;
      }

      rec.set("used_by", me);
      rec.set("used_at", Date.now());
      txApp.save(rec);

      const newBalance = (user.getInt("coins") || 0) + amount;
      user.set("coins", newBalance);
      txApp.save(user);

      out = {
        s: 200,
        b: {
          ok: true,
          alreadyRedeemed: false,
          coins: newBalance,
          awarded: amount,
        },
      };
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
          message: "coins/redeem: " + String(err),
          level: "error",
          logger: "pb_hooks.redeem",
          tags: { feature: "redeem", route: "coins_redeem", error_code: "server" },
        }),
        timeout: 5,
      });
    } catch (_) {}
    try {
      $app.logger().error("coins/redeem: " + String(err));
    } catch (_) {}
    out = { s: 500, b: { ok: false, error: "internal" } };
  }
  return e.json(out.s, out.b);
}, $apis.requireAuth());
