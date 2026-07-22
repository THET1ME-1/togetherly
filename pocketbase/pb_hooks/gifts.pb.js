/// Подарки между партнёрами (фаза 1: движок «Отклик»).
///
/// Два роута:
///   POST /api/gifts/send   — списать монеты и создать запись подарка;
///   POST /api/gifts/react  — засчитать отклик и вернуть дарителю часть цены.
///
/// Деньги считает только сервер: клиентская цена — витрина. Запись в коллекцию
/// `gifts` закрыта правилами (createRule/updateRule = null), писать может лишь
/// эта пара роутов.
///
/// ИДЕМПОТЕНТНОСТЬ: `id` записи равен `giftId`, который генерит клиент. Повтор
/// после обрыва связи находит существующую запись и монеты не трогает — тот же
/// приём, что в `coins.pb.js` для `iap_purchases`.
///
/// !!! ГРАБЛИ PB JSVM (см. coins.pb.js:5-19): обработчик исполняется в
/// ИЗОЛИРОВАННОМ пуле и НЕ видит функции уровня файла. Поэтому прайс-таблица,
/// отправка ошибок в Bugsink и всё прочее инлайнится в каждый обработчик.

routerAdd("POST", "/api/gifts/send", (e) => {
  // Зеркало lib/models/gift.dart. Расхождение ловит test/logic/gift_catalog_test.dart.
  const PRICES = {
    heart: 10, star: 10, fire: 10, sun: 10,
    hug: 15, night: 15, cookie: 15, bunny: 15, paw: 15, spa: 15,
    coffee: 20, tea: 20, croissant: 20, pizza: 20, wine: 20,
    cocktail: 20, song: 20, photo: 20, piggy: 20,
    bouquet: 25, park: 25, ramen: 25, bed: 25, beach: 25,
    giftbox: 30, letter: 30, movie: 30, salute: 30,
    cake: 40, flight: 40, key: 40,
    medal: 50, rocket: 50, diamond: 60,
  };
  const LIFE_MS = 24 * 60 * 60 * 1000;

  const body = new DynamicModel({ giftId: "", groupId: "", giftKey: "" });
  e.bindBody(body);

  const giftId = (body.giftId || "").trim();
  const groupId = (body.groupId || "").trim();
  const giftKey = (body.giftKey || "").trim();
  const price = PRICES[giftKey];

  if (!giftId || !groupId || !price) {
    return e.json(400, { ok: false, error: "unknown_gift" });
  }

  let out = { s: 500, b: { ok: false, error: "internal" } };
  try {
    $app.runInTransaction((txApp) => {
      const me = e.auth.id;
      const user = txApp.findRecordById("users", me);

      // Повтор той же отправки: запись уже есть, монеты трогать нельзя.
      let existing = null;
      try {
        existing = txApp.findRecordById("gifts", giftId);
      } catch (_) {
        existing = null;
      }
      if (existing) {
        out = {
          s: 200,
          b: {
            ok: true,
            alreadySent: true,
            coins: user.getInt("coins") || 0,
            gift: {
              id: giftId,
              giftKey: existing.getString("gift_key"),
              price: existing.getInt("price"),
              state: existing.getString("state"),
              expiresAt: existing.getInt("expires_at"),
            },
          },
        };
        return;
      }

      const group = txApp.findRecordById("groups", groupId);
      // members хранится JSON-строкой: get() отдаёт не JS-массив, и перебор
      // молча даёт ноль участников. Так же читают groups.pb.js и coins.pb.js.
      let members = [];
      try {
        members = JSON.parse(group.getString("members") || "[]") || [];
      } catch (_) {
        members = [];
      }
      let isMember = false;
      let partner = "";
      for (let i = 0; i < members.length; i++) {
        const m = String(members[i]);
        if (m === me) isMember = true;
        else if (!partner) partner = m;
      }
      if (!isMember) {
        out = { s: 403, b: { ok: false, error: "not_member" } };
        return;
      }

      const coins = user.getInt("coins") || 0;
      if (coins < price) {
        out = { s: 402, b: { ok: false, error: "insufficient", coins: coins } };
        return;
      }

      const now = Date.now();
      const col = txApp.findCollectionByNameOrId("gifts");
      const rec = new Record(col);
      rec.set("id", giftId);
      rec.set("group_id", groupId);
      rec.set("sender_uid", me);
      rec.set("recipient_uid", partner);
      rec.set("gift_key", giftKey);
      rec.set("price", price);
      rec.set("state", "sent");
      rec.set("expires_at", now + LIFE_MS);
      txApp.save(rec);

      user.set("coins", coins - price);
      txApp.save(user);

      out = {
        s: 200,
        b: {
          ok: true,
          alreadySent: false,
          coins: coins - price,
          gift: {
            id: giftId,
            giftKey: giftKey,
            price: price,
            state: "sent",
            expiresAt: now + LIFE_MS,
          },
        },
      };
    });
  } catch (err) {
    // Телеметрия в Bugsink: без неё падение роута видит только пользователь.
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
          message: "gifts/send: " + String(err),
          level: "error",
          logger: "pb_hooks.gifts",
          tags: {
            feature: "gifts",
            route: "gifts_send",
            gift_key: giftKey,
            gift_id: giftId,
            error_code: "server",
          },
        }),
        timeout: 5,
      });
    } catch (_) {}
    try {
      $app.logger().error("gifts/send: " + String(err));
    } catch (_) {}
    out = { s: 500, b: { ok: false, error: "internal" } };
  }
  return e.json(out.s, out.b);
}, $apis.requireAuth());

routerAdd("POST", "/api/gifts/react", (e) => {
  const REFUND_SHARE = 0.3; // доля цены, возвращаемая дарителю за отклик

  const body = new DynamicModel({ giftId: "" });
  e.bindBody(body);
  const giftId = (body.giftId || "").trim();
  if (!giftId) return e.json(400, { ok: false, error: "gift_not_found" });

  let out = { s: 500, b: { ok: false, error: "internal" } };
  try {
    $app.runInTransaction((txApp) => {
      let gift = null;
      try {
        gift = txApp.findRecordById("gifts", giftId);
      } catch (_) {
        gift = null;
      }
      if (!gift) {
        out = { s: 404, b: { ok: false, error: "gift_not_found" } };
        return;
      }

      const me = e.auth.id;
      if (gift.getString("recipient_uid") !== me) {
        out = { s: 403, b: { ok: false, error: "not_recipient" } };
        return;
      }

      const user = txApp.findRecordById("users", me);
      if (gift.getString("state") === "reacted") {
        out = {
          s: 200,
          b: {
            ok: true,
            alreadyReacted: true,
            refund: gift.getInt("refund") || 0,
            coins: user.getInt("coins") || 0,
          },
        };
        return;
      }

      const refund = Math.floor((gift.getInt("price") || 0) * REFUND_SHARE);
      gift.set("state", "reacted");
      gift.set("reacted_at", Date.now());
      gift.set("refund", refund);
      txApp.save(gift);

      if (refund > 0) {
        const sender = txApp.findRecordById("users", gift.getString("sender_uid"));
        sender.set("coins", (sender.getInt("coins") || 0) + refund);
        txApp.save(sender);
      }

      out = {
        s: 200,
        b: {
          ok: true,
          alreadyReacted: false,
          refund: refund,
          coins: user.getInt("coins") || 0,
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
          message: "gifts/react: " + String(err),
          level: "error",
          logger: "pb_hooks.gifts",
          tags: {
            feature: "gifts",
            route: "gifts_react",
            gift_id: giftId,
            error_code: "server",
          },
        }),
        timeout: 5,
      });
    } catch (_) {}
    try {
      $app.logger().error("gifts/react: " + String(err));
    } catch (_) {}
    out = { s: 500, b: { ok: false, error: "internal" } };
  }
  return e.json(out.s, out.b);
}, $apis.requireAuth());
