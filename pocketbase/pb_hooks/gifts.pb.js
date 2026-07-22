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
  // Подарки, которые доходят не сразу. Зеркало deliverAfter/deliversAtMorning.
  const DELAY_H = { letter: 24 };
  const MORNING = { croissant: true };

  const body = new DynamicModel({
    giftId: "", groupId: "", giftKey: "", note: "", date: "", place: "",
  });
  e.bindBody(body);

  const giftId = (body.giftId || "").trim();
  const groupId = (body.groupId || "").trim();
  const giftKey = (body.giftKey || "").trim();
  // Записка внутри коробки, предсказание в печенье, текст письма.
  const note = String(body.note || "").slice(0, 500);
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
      rec.set("note", note);
      rec.set("price", price);
      rec.set("state", "sent");
      // Дата для обратного отсчёта (отпуск, билет, ужин) и место (лапка).
      if (body.date) rec.set("date", String(body.date).slice(0, 40));
      if (body.place) rec.set("place", String(body.place).slice(0, 80));
      // Отложенная доставка: письмо ждёт сутки, завтрак — ближайшее утро.
      let deliverAt = now;
      if (DELAY_H[giftKey]) {
        deliverAt = now + DELAY_H[giftKey] * 60 * 60 * 1000;
      } else if (MORNING[giftKey]) {
        const d = new Date(now);
        const m = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 8, 0, 0, 0);
        deliverAt = d.getTime() < m.getTime()
          ? m.getTime()
          : m.getTime() + 24 * 60 * 60 * 1000;
      }
      rec.set("deliver_at", deliverAt);
      rec.set("expires_at", deliverAt + LIFE_MS);
      txApp.save(rec);

      user.set("coins", coins - price);
      txApp.save(user);

      // Копилка не тратит монеты, а передаёт их партнёру: единственный способ
      // поделиться балансом внутри пары.
      if (giftKey === "piggy" && partner) {
        try {
          const p = txApp.findRecordById("users", partner);
          p.set("coins", (p.getInt("coins") || 0) + price);
          txApp.save(p);
        } catch (_) {}
      }

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

  const MUTUAL_WINDOW_MS = 60 * 1000; // окно «обнял в ответ»
  const MUTUAL_BONUS = { hug: 5 };    // зеркало mutualBonus в lib/models/gift.dart
  // Подарки, меняющие приложение получателя. Зеркало lib/models/gift_effect.dart.
  //   morning — до ближайших восьми утра; иначе срок в часах.
  const EFFECTS = {
    night: { field: "mute_until", morning: true },
    sun: { field: "sunrise_until", morning: true },
    spa: { field: "spa_until", hours: 24 },
    fire: { field: "streak_shield_until", hours: 24 },
  };

  const body = new DynamicModel({ giftId: "", reply: "" });
  e.bindBody(body);
  const giftId = (body.giftId || "").trim();
  // Желание на звезду: текст получателя, который вернётся дарителю.
  const reply = String(body.reply || "").slice(0, 500);
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

      const now = Date.now();
      const price = gift.getInt("price") || 0;
      let refund = Math.floor(price * REFUND_SHARE);

      // Успел ответить в первую минуту — обоим по бонусу сверх возврата.
      // Отсчёт от expires_at, потому что момент отправки известен через него.
      const bonus = MUTUAL_BONUS[gift.getString("gift_key")] || 0;
      const sentAt = (gift.getInt("expires_at") || 0) - 24 * 60 * 60 * 1000;
      const quick = bonus > 0 && sentAt > 0 && now - sentAt <= MUTUAL_WINDOW_MS;

      gift.set("state", "reacted");
      gift.set("reacted_at", now);
      gift.set("refund", refund + (quick ? bonus : 0));
      if (reply) gift.set("reply", reply);
      txApp.save(gift);

      if (refund > 0 || quick) {
        const sender = txApp.findRecordById("users", gift.getString("sender_uid"));
        sender.set("coins", (sender.getInt("coins") || 0) + refund + (quick ? bonus : 0));
        txApp.save(sender);
      }
      if (quick) {
        user.set("coins", (user.getInt("coins") || 0) + bonus);
        txApp.save(user);
      }

      // Ключик открывает партнёру секретные записи на сутки.
      if (gift.getString("gift_key") === "key") {
        const prevUnlock = user.getInt("secrets_until") || 0;
        user.set("secrets_until", Math.max(prevUnlock, now + 24 * 60 * 60 * 1000));
        txApp.save(user);
      }

      // Салют остаётся записью в общей ленте — событие, а не вспышка.
      if (gift.getString("gift_key") === "salute") {
        try {
          const memCol = txApp.findCollectionByNameOrId("memories");
          const mem = new Record(memCol);
          mem.set("group_id", gift.getString("group_id"));
          mem.set("author_uid", gift.getString("sender_uid"));
          mem.set("data", JSON.stringify({
            type: "gift",
            giftKey: "salute",
            title: "Салют",
            createdAt: now,
          }));
          txApp.save(mem);
        } catch (_) {}
      }

      // Эффект подарка на приложение получателя: тихая ночь, рассвет, отдых,
      // щит серии. Срок кладём в профиль — экраны про подарки не знают.
      const eff = EFFECTS[gift.getString("gift_key")];
      if (eff) {
        let until;
        if (eff.morning) {
          const d = new Date(now);
          const morning = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 8, 0, 0, 0);
          until = d.getTime() < morning.getTime()
            ? morning.getTime()
            : morning.getTime() + 24 * 60 * 60 * 1000;
        } else {
          until = now + eff.hours * 60 * 60 * 1000;
        }
        // Продлеваем, а не затираем: два подарка подряд дают больше тишины.
        const prev = user.getInt(eff.field) || 0;
        user.set(eff.field, Math.max(prev, until));
        txApp.save(user);
      }

      out = {
        s: 200,
        b: {
          ok: true,
          alreadyReacted: false,
          refund: refund + (quick ? bonus : 0),
          mutual: quick ? bonus : 0,
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

/// Отказ от приглашения: подарок гаснет, дарителю возвращается ВСЯ цена.
/// Штраф за «не сейчас» убил бы желание звать вообще.
routerAdd("POST", "/api/gifts/decline", (e) => {
  const body = new DynamicModel({ giftId: "" });
  e.bindBody(body);
  const giftId = (body.giftId || "").trim();
  if (!giftId) return e.json(400, { ok: false, error: "gift_not_found" });

  let out = { s: 500, b: { ok: false, error: "internal" } };
  try {
    $app.runInTransaction((txApp) => {
      let gift = null;
      try { gift = txApp.findRecordById("gifts", giftId); } catch (_) { gift = null; }
      if (!gift) {
        out = { s: 404, b: { ok: false, error: "gift_not_found" } };
        return;
      }
      if (gift.getString("recipient_uid") !== e.auth.id) {
        out = { s: 403, b: { ok: false, error: "not_recipient" } };
        return;
      }
      if (gift.getString("state") !== "sent") {
        out = { s: 200, b: { ok: true, alreadyReacted: true, refund: 0 } };
        return;
      }
      const price = gift.getInt("price") || 0;
      gift.set("state", "declined");
      gift.set("reacted_at", Date.now());
      gift.set("refund", price);
      txApp.save(gift);
      try {
        const sender = txApp.findRecordById("users", gift.getString("sender_uid"));
        sender.set("coins", (sender.getInt("coins") || 0) + price);
        txApp.save(sender);
      } catch (_) {}
      out = { s: 200, b: { ok: true, alreadyReacted: false, refund: price } };
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
          message: "gifts/decline: " + String(err),
          level: "error",
          logger: "pb_hooks.gifts",
          tags: { feature: "gifts", route: "gifts_decline", gift_id: giftId,
                  error_code: "server" },
        }),
        timeout: 5,
      });
    } catch (_) {}
    try { $app.logger().error("gifts/decline: " + String(err)); } catch (_) {}
    out = { s: 500, b: { ok: false, error: "internal" } };
  }
  return e.json(out.s, out.b);
}, $apis.requireAuth());
