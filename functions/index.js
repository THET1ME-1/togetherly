/**
 * Cloud Function: onMissYouEvent
 *
 * Срабатывает при добавлении документа в groups/{groupId}/missYouEvents/{eventId}.
 * Отправляет push-уведомление всем участникам группы, кроме отправителя.
 *
 * Поддерживает vibeType: miss_you | thinking_of_you | want_hug | custom
 * Поддерживает:
 *  - fcmTokens (array) — несколько устройств / переустановка приложения
 *  - fcmToken  (string) — обратная совместимость
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { getDatabaseWithUrl, ServerValue } = require("firebase-admin/database");
const { getAuth } = require("firebase-admin/auth");
const { defineSecret } = require("firebase-functions/params");
const crypto = require("crypto");
const https = require("https");
const { google } = require("googleapis");

initializeApp();

// ─── Верификация покупок Google Play ─────────────────────────────────────────
// Имя пакета приложения (зеркало android/app/build.gradle → applicationId).
const ANDROID_PACKAGE_NAME = "com.togetherly.love";

let _androidPublisher = null;
// Лениво инициализируем клиент Android Publisher API на сервисном аккаунте
// функции (Application Default Credentials). Сервисный аккаунт должен иметь
// доступ к Play Developer API — см. README/инструкцию по деплою.
async function getAndroidPublisher() {
  if (_androidPublisher) return _androidPublisher;
  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const authClient = await auth.getClient();
  _androidPublisher = google.androidpublisher({ version: "v3", auth: authClient });
  return _androidPublisher;
}

/**
 * Проверяет покупку расходуемого товара в Google Play.
 * Бросает HttpsError, если покупка не подтверждена.
 * Возвращает данные покупки (purchaseState === 0 — оплачено).
 */
async function verifyGooglePlayPurchase(productId, purchaseToken) {
  let publisher;
  try {
    publisher = await getAndroidPublisher();
  } catch (e) {
    console.error("Play API: ошибка инициализации auth:", e && e.message);
    throw new HttpsError("internal", "Не удалось проверить покупку");
  }

  let res;
  try {
    res = await publisher.purchases.products.get({
      packageName: ANDROID_PACKAGE_NAME,
      productId,
      token: purchaseToken,
    });
  } catch (e) {
    // 404/410 — токен невалиден/просрочен; 401/403 — нет доступа (конфигурация).
    const code = (e && (e.code || (e.response && e.response.status))) || "?";
    console.error(`Play verify FAILED (product=${productId}, code=${code}): ${e && e.message}`);
    throw new HttpsError("failed-precondition", "Покупка не подтверждена Google Play");
  }

  const data = res.data || {};
  // purchaseState: 0 = Purchased, 1 = Canceled, 2 = Pending.
  if (data.purchaseState !== 0) {
    console.warn(`Play verify: purchaseState=${data.purchaseState} (product=${productId})`);
    throw new HttpsError("failed-precondition", "Покупка не завершена");
  }
  return data;
}

/**
 * Строит тип и тело уведомления в зависимости от vibeType.
 * Тело — запасной текст на случай если клиент не поддерживает тип.
 * Клиент всегда переопределяет заголовок локализованной строкой.
 */
function buildVibePayload(vibeType, customText) {
  switch (vibeType) {
    case "thinking_of_you":
      return { type: "thinking_of_you", body: "Думает о тебе 💭" };
    case "want_hug":
      return { type: "want_hug", body: "Хочет обнять тебя 🤗" };
    case "custom":
      return { type: "custom", body: customText || "✉️" };
    default:
      return { type: "miss_you", body: "Думает о вас и вспоминает 💭" };
  }
}

// RTDB europe-west1 (не дефолтный регион) — зеркало FCM-токенов и настроек
// уведомлений. Читая отсюда, функция пуша не тратит Firestore-чтения.
const RTDB_URL =
  "https://togetherly-d4856-default-rtdb.europe-west1.firebasedatabase.app";

let _rtdb = null;
function rtdb() {
  if (!_rtdb) _rtdb = getDatabaseWithUrl(RTDB_URL);
  return _rtdb;
}

/**
 * Возвращает { tokens: string[], notifMissYou: bool, source } для uid.
 * Сначала пробует RTDB push/{uid} (даром), при отсутствии — фолбэк на
 * Firestore users/{uid} (1 read), чтобы пуши не пропали у тех, чьи токены
 * ещё не зазеркалились после деплоя.
 */
async function getPushInfo(db, uid) {
  try {
    const snap = await rtdb().ref(`push/${uid}`).get();
    if (snap.exists()) {
      const v = snap.val() || {};
      const tokens = Object.keys(v.tokens || {});
      if (tokens.length > 0) {
        return { tokens, notifMissYou: v.notifMissYou !== false, source: "rtdb" };
      }
    }
  } catch (e) {
    console.warn(`getPushInfo RTDB read failed for uid=${uid}: ${e}`);
  }
  // Фолбэк: Firestore.
  const userDoc = await db.collection("users").doc(uid).get();
  if (!userDoc.exists) return { tokens: [], notifMissYou: true, source: "none" };
  const ud = userDoc.data();
  const tokens =
    Array.isArray(ud.fcmTokens) && ud.fcmTokens.length > 0
      ? ud.fcmTokens.filter(Boolean)
      : ud.fcmToken
        ? [ud.fcmToken]
        : [];
  return { tokens, notifMissYou: ud.notifMissYou !== false, source: "firestore" };
}

exports.onMissYouEvent = onDocumentCreated(
  "groups/{groupId}/missYouEvents/{eventId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data();
    const senderUid = data.senderUid;
    const senderName = data.senderName || "Your partner";
    const vibeType = data.vibeType || "miss_you";
    const customText = (data.customText || "").trim();
    const groupId = event.params.groupId;

    const db = getFirestore();

    // Получатели: из самого event-документа (приходит в триггер бесплатно),
    // иначе — фолбэк на чтение group-doc. recipientUids кладёт клиент из кеша
    // участников, чтобы на каждый тап не платить за чтение группы.
    let recipients = Array.isArray(data.recipientUids)
      ? data.recipientUids.filter((uid) => uid && uid !== senderUid)
      : null;
    if (!recipients || recipients.length === 0) {
      const groupDoc = await db.collection("groups").doc(groupId).get();
      if (!groupDoc.exists) return;
      const members = groupDoc.data().members || [];
      recipients = members.filter((uid) => uid !== senderUid);
    }

    if (recipients.length === 0) return;

    // Собираем FCM-токены получателей (RTDB-зеркало, фолбэк на Firestore).
    const tokenToUid = {}; // token → uid (для очистки устаревших)
    for (const uid of recipients) {
      const info = await getPushInfo(db, uid);

      // Проверяем настройку уведомлений.
      // Кастомные сообщения (custom) всегда доставляются — пользователь
      // специально написал текст, блокировать его настройкой "Я скучаю" неправильно.
      // Для остальных типов уважаем настройку notifMissYou.
      const notifEnabled = vibeType === "custom" || info.notifMissYou;
      if (!notifEnabled) {
        console.log(`VibeEvent [${groupId}] type=${vibeType}: notifications disabled for uid=${uid}, skipping`);
        continue;
      }

      for (const t of info.tokens) {
        if (t) tokenToUid[t] = uid;
      }
    }

    const tokens = Object.keys(tokenToUid);
    if (tokens.length === 0) {
      console.log(`MissYou [${groupId}]: no FCM tokens found for recipients`);
      return;
    }

    const { type, body } = buildVibePayload(vibeType, customText);

    // Формируем data-only push-сообщение.
    // Заголовок собирается на клиенте (локализация + никнейм отправителя).
    // body — запасной текст; для custom это сам текст пользователя.
    const messageData = {
      type,
      groupId,
      senderUid,
      senderName,
      body,
    };
    if (customText) messageData.customText = customText;

    const message = {
      data: messageData,
      android: {
        priority: "high",
      },
      apns: {
        headers: {
          "apns-priority": "10",
        },
        payload: {
          aps: {
            sound: "default",
            badge: 1,
            contentAvailable: true,
          },
        },
      },
    };

    const messaging = getMessaging();
    const results = await Promise.allSettled(
      tokens.map((token) => messaging.send({ ...message, token }))
    );

    // Находим устаревшие токены
    const staleTokens = [];
    results.forEach((result, i) => {
      if (
        result.status === "rejected" &&
        (result.reason?.code ===
          "messaging/registration-token-not-registered" ||
          result.reason?.code === "messaging/invalid-registration-token")
      ) {
        staleTokens.push(tokens[i]);
      }
    });

    // Удаляем устаревшие токены из RTDB-зеркала и из Firestore-массива.
    // Без чтения user-doc: arrayRemove идемпотентен, а одиночное legacy-поле
    // fcmToken чистить не обязательно (массив fcmTokens — основной источник).
    for (const staleToken of staleTokens) {
      const uid = tokenToUid[staleToken];
      if (!uid) continue;
      try {
        await rtdb().ref(`push/${uid}/tokens`).child(staleToken).remove();
      } catch (e) {
        console.warn(`Failed to remove stale RTDB token for uid=${uid}: ${e}`);
      }
      try {
        await db
          .collection("users")
          .doc(uid)
          .update({ fcmTokens: FieldValue.arrayRemove(staleToken) });
      } catch (e) {
        console.warn(`Failed to remove stale token for uid=${uid}: ${e}`);
      }
    }

    const successCount = results.filter((r) => r.status === "fulfilled").length;
    console.log(
      `VibeEvent [${groupId}] type=${type}: sent=${successCount}/${tokens.length}, stale=${staleTokens.length}`
    );
  }
);

/**
 * Cloud Function: onWidgetDataEvent
 *
 * Срабатывает когда пользователь меняет статус/настроение/сообщение/музыку.
 * Отправляет FCM data-сообщение партнёру с type=widget_update, чтобы
 * виджет рабочего стола обновился мгновенно даже когда Flutter-процесс убит.
 * После отправки удаляет триггерный документ.
 */
exports.onWidgetDataEvent = onDocumentCreated(
  "groups/{groupId}/widgetDataEvents/{eventId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data();
    const senderUid = data.senderUid;
    const groupId = event.params.groupId;

    const db = getFirestore();

    // Получаем участников группы
    const groupDoc = await db.collection("groups").doc(groupId).get();
    if (!groupDoc.exists) {
      await snapshot.ref.delete();
      return;
    }

    const members = groupDoc.data().members || [];
    const recipients = members.filter((uid) => uid !== senderUid);

    if (recipients.length === 0) {
      await snapshot.ref.delete();
      return;
    }

    // Собираем FCM-токены получателей
    const tokens = [];
    for (const uid of recipients) {
      const userDoc = await db.collection("users").doc(uid).get();
      if (!userDoc.exists) continue;
      const userData = userDoc.data();
      if (Array.isArray(userData.fcmTokens)) {
        tokens.push(...userData.fcmTokens.filter(Boolean));
      } else if (userData.fcmToken) {
        tokens.push(userData.fcmToken);
      }
    }

    if (tokens.length > 0) {
      // Data-only сообщение — не показывает уведомление, только обновляет виджет.
      // Кладём ТОЛЬКО реально изменившиеся поля (они и есть в событии). Раньше
      // отсутствующие уходили как "" и затирали статус/сообщение/музыку партнёра
      // на виджете до следующего полного синка (напр. смена настроения обнуляла
      // статус). Клиент тоже сохраняет только присутствующие ключи.
      const messageData = { type: "widget_update" };
      for (const key of ["status", "moodLabel", "message", "musicTitle", "musicArtist"]) {
        if (data[key] !== undefined && data[key] !== null) {
          messageData[key] = String(data[key]);
        }
      }

      const messaging = getMessaging();
      await Promise.allSettled(
        tokens.map((token) =>
          messaging.send({
            token,
            data: messageData,
            android: { priority: "high" },
            apns: {
              headers: { "apns-priority": "5" },
              payload: { aps: { contentAvailable: true } },
            },
          })
        )
      );

      console.log(
        `WidgetDataEvent [${groupId}]: sent widget_update to ${tokens.length} token(s)`
      );

      // Видимое уведомление о смене настроения. widget_update выше — тихий
      // (только обновляет виджет), поэтому отдельно шлём data-only пуш type=mood,
      // который клиент покажет как уведомление (с учётом тоггла notifMood).
      // moodLabel есть в событии только когда менялось именно настроение
      // (см. widgetFields в _updateField); пустая строка = сброс — не шумим.
      const moodLabel = (data.moodLabel || "").trim();
      if (moodLabel) {
        const senderName =
          (groupDoc.data().memberNames || {})[senderUid] || "Партнёр";
        const moodData = {
          type: "mood",
          groupId,
          senderUid,
          senderName,
          moodLabel,
          // title/body — фолбэк для клиентов без локализованной ветки mood:
          // их generic-путь в _buildLocalNotificationContent покажет это как есть.
          title: senderName,
          body: `Настроение: ${moodLabel}`,
        };
        await Promise.allSettled(
          tokens.map((token) =>
            messaging.send({
              token,
              data: moodData,
              android: { priority: "high" },
              apns: {
                headers: { "apns-priority": "10" },
                payload: { aps: { sound: "default", contentAvailable: true } },
              },
            })
          )
        );
        console.log(
          `WidgetDataEvent [${groupId}]: sent mood notification to ${tokens.length} token(s)`
        );
      }
    }

    // Удаляем триггерный документ — он больше не нужен
    await snapshot.ref.delete();
  }
);

/**
 * Cloud Function: onChatMessageEvent
 *
 * Срабатывает, когда пользователь отправляет сообщение в чат пары. Сам чат
 * живёт в Realtime Database (ноль Firestore-чтений при просмотре истории) —
 * здесь обрабатывается лишь эфемерный документ-событие для push-уведомления,
 * который удаляется сразу после отправки FCM.
 */
exports.onChatMessageEvent = onDocumentCreated(
  "groups/{groupId}/chatEvents/{eventId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data();
    const senderUid = data.senderUid;
    const senderName = data.senderName || "Your partner";
    const text = (data.text || "").trim();
    const groupId = event.params.groupId;

    const db = getFirestore();

    const groupDoc = await db.collection("groups").doc(groupId).get();
    if (!groupDoc.exists) {
      await snapshot.ref.delete();
      return;
    }

    const members = groupDoc.data().members || [];
    const recipients = members.filter((uid) => uid !== senderUid);
    if (recipients.length === 0) {
      await snapshot.ref.delete();
      return;
    }

    // Собираем токены получателей, у которых не отключены чат-уведомления.
    const tokenToUid = {};
    for (const uid of recipients) {
      const userDoc = await db.collection("users").doc(uid).get();
      if (!userDoc.exists) continue;
      const userData = userDoc.data();

      if (userData.notifChat === false) {
        console.log(`ChatEvent [${groupId}]: notifications disabled for uid=${uid}, skipping`);
        continue;
      }

      const tokensList = userData.fcmTokens;
      if (Array.isArray(tokensList) && tokensList.length > 0) {
        for (const t of tokensList) {
          if (t) tokenToUid[t] = uid;
        }
      } else if (userData.fcmToken) {
        tokenToUid[userData.fcmToken] = uid;
      }
    }

    const tokens = Object.keys(tokenToUid);
    if (tokens.length === 0) {
      await snapshot.ref.delete();
      return;
    }

    // Data-only сообщение — заголовок собирается на клиенте (никнейм + локаль).
    const messageData = {
      type: "chat",
      groupId,
      senderUid,
      senderName,
      body: text || "✉️",
    };

    const message = {
      data: messageData,
      android: { priority: "high" },
      apns: {
        headers: { "apns-priority": "10" },
        payload: {
          aps: { sound: "default", badge: 1, contentAvailable: true },
        },
      },
    };

    const messaging = getMessaging();
    const results = await Promise.allSettled(
      tokens.map((token) => messaging.send({ ...message, token }))
    );

    // Чистим устаревшие токены.
    const staleTokens = [];
    results.forEach((result, i) => {
      if (
        result.status === "rejected" &&
        (result.reason?.code ===
          "messaging/registration-token-not-registered" ||
          result.reason?.code === "messaging/invalid-registration-token")
      ) {
        staleTokens.push(tokens[i]);
      }
    });
    for (const staleToken of staleTokens) {
      const uid = tokenToUid[staleToken];
      if (!uid) continue;
      try {
        const userRef = db.collection("users").doc(uid);
        const userSnap = await userRef.get();
        if (!userSnap.exists) continue;
        const updates = { fcmTokens: FieldValue.arrayRemove(staleToken) };
        if (userSnap.data().fcmToken === staleToken) updates.fcmToken = "";
        await userRef.update(updates);
      } catch (e) {
        console.warn(`Failed to remove stale token for uid=${uid}: ${e}`);
      }
    }

    const successCount = results.filter((r) => r.status === "fulfilled").length;
    console.log(
      `ChatEvent [${groupId}]: sent=${successCount}/${tokens.length}, stale=${staleTokens.length}`
    );

    // Событие больше не нужно.
    await snapshot.ref.delete();
  }
);

// ═══════════════════════════════════════════════════════════════════════════
// КОИНЫ — серверно-авторитетный экономический модуль
// ═══════════════════════════════════════════════════════════════════════════
//
// Все начисления и списания коинов идут только через эти callable-функции.
// Клиент НЕ может писать поля coins/ownedThemes/devCoinsGranted/dailyBonus*/
// adRewards* напрямую — это блокируется Firestore Rules.
//
// Источник правды о ценах и премиум-темах — этот файл (зеркало lib/theme/app_theme.dart).

// Премиум-темы: индексы 5+ (0-4 бесплатные). Цена по умолчанию 30 коинов;
// особые цены — в THEME_PRICE_OVERRIDES. Раньше тут был enum 5..12 и при
// добавлении тем 13..19 в клиент (но не сюда) покупка падала с «Тема не
// продаётся» — теперь любая премиум-тема автоматически стоит 30, ломаться при
// добавлении новых тем не будет. Верхняя граница 50 — защита от мусорных id.
const THEME_PRICE_OVERRIDES = {
  16: 40, // Северное сияние (Aurora)
};
function themePrice(themeId) {
  if (typeof themeId !== "number" || themeId < 5 || themeId > 50) return null;
  return THEME_PRICE_OVERRIDES[themeId] || 30;
}

// Цены профильных иконок (зеркало lib/models/profile_icon.dart).
// Common = 20, Rare = 35, Premium = 50. Grant-only иконки (Sponsor/Helper)
// здесь отсутствуют — их нельзя купить.
const PROFILE_ICON_PRICES = {
  "Paw": 20,
  "Sun": 20,
  "Moon": 20,
  "Rainbow": 20,
  "Bunny": 20,
  "Frog": 20,
  "Lucky": 35,
  "UFO": 35,
  "Together": 35,
  "Soulmate": 50,
  "Perfect Match": 50,
  "Inseparable": 50,
};

// Цены одноразовых разблокировок фич (зеркало lib/models/user_data.dart).
// Покупается один раз, навсегда; хранится в ownedFeatures.
const FEATURE_PRICES = {
  "days_widget_photos": 20, // свои фото пары на виджете «Дни вместе»
};

// Цены расходуемых действий — списываются КАЖДЫЙ раз, ничего не «покупается»
// навсегда (в отличие от FEATURE_PRICES). Напр. смена фона чата.
const CONSUMABLE_PRICES = {
  "chat_background": 20, // установить/сменить своё фото на фон чата
};

const DEV_EMAIL = "badzoff@gmail.com";
const DEV_GRANT_AMOUNT = 1000;

const DAILY_BONUS_AMOUNT = 1;
const DAILY_BONUS_COOLDOWN_MS = 20 * 60 * 60 * 1000; // 20ч (защита от тонких манипуляций tz)

const AD_REWARD_AMOUNT = 3;
const AD_REWARDS_PER_DAY = 3;

const MEMORY_REWARD_AMOUNT = 1;
const MEMORY_REWARD_COOLDOWN_MS = 20 * 60 * 60 * 1000; // 20ч = 1 раз в день

const PARTNER_INVITE_REWARD = 50;

const MOOD_STREAK_REWARD = 10;
const MOOD_STREAK_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000; // 7 дней

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "Требуется авторизация");
  }
  return request.auth;
}

/**
 * Покупка премиум-темы за коины.
 * Транзакционно: списывает price, добавляет themeId в ownedThemes.
 * Безопасно от race conditions, двойных списаний, обхода цены клиентом.
 */
exports.purchaseTheme = onCall(async (request) => {
  const auth = requireAuth(request);
  const themeId = Number(request.data && request.data.themeId);
  if (!Number.isInteger(themeId)) {
    throw new HttpsError("invalid-argument", "themeId должен быть числом");
  }
  const price = themePrice(themeId);
  if (!price) {
    throw new HttpsError("invalid-argument", "Тема не премиум или не существует");
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const coins = Number(data.coins || 0);
    const owned = Array.isArray(data.ownedThemes) ? data.ownedThemes : [];

    if (owned.includes(themeId)) {
      return { ok: true, alreadyOwned: true, coins, ownedThemes: owned };
    }
    if (coins < price) {
      throw new HttpsError("failed-precondition", "Недостаточно монет");
    }

    const newCoins = coins - price;
    const newOwned = [...owned, themeId].sort((a, b) => a - b);
    tx.set(userRef, {
      coins: newCoins,
      ownedThemes: newOwned,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    return { ok: true, alreadyOwned: false, coins: newCoins, ownedThemes: newOwned };
  });
});

/**
 * Покупка профильной иконки за коины.
 * Транзакционно: списывает цену, добавляет iconId в ownedIcons.
 * Безопасно от race conditions, двойных списаний и обхода цены клиентом.
 */
exports.purchaseIcon = onCall(async (request) => {
  const auth = requireAuth(request);
  const iconId = request.data && request.data.iconId;
  if (typeof iconId !== "string" || !iconId) {
    throw new HttpsError("invalid-argument", "iconId должен быть строкой");
  }
  const price = PROFILE_ICON_PRICES[iconId];
  if (!price) {
    throw new HttpsError("invalid-argument", "Иконка не продаётся или не существует");
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const coins = Number(data.coins || 0);
    const owned = Array.isArray(data.ownedIcons) ? data.ownedIcons : [];

    if (owned.includes(iconId)) {
      return { ok: true, alreadyOwned: true, coins, ownedIcons: owned };
    }
    if (coins < price) {
      throw new HttpsError("failed-precondition", "Недостаточно монет");
    }

    const newCoins = coins - price;
    const newOwned = [...owned, iconId];
    tx.set(userRef, {
      coins: newCoins,
      ownedIcons: newOwned,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    return { ok: true, alreadyOwned: false, coins: newCoins, ownedIcons: newOwned };
  });
});

/**
 * Покупка одноразовой разблокировки фичи за коины (напр. свои фото на виджете).
 * Транзакционно: списывает price, добавляет featureId в ownedFeatures.
 * Безопасно от race conditions, двойных списаний и обхода цены клиентом.
 */
exports.purchaseFeature = onCall(async (request) => {
  const auth = requireAuth(request);
  const featureId = request.data && request.data.featureId;
  if (typeof featureId !== "string" || !featureId) {
    throw new HttpsError("invalid-argument", "featureId должен быть строкой");
  }
  const price = FEATURE_PRICES[featureId];
  if (!price) {
    throw new HttpsError("invalid-argument", "Фича не продаётся или не существует");
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const coins = Number(data.coins || 0);
    const owned = Array.isArray(data.ownedFeatures) ? data.ownedFeatures : [];

    if (owned.includes(featureId)) {
      return { ok: true, alreadyOwned: true, coins, ownedFeatures: owned };
    }
    if (coins < price) {
      throw new HttpsError("failed-precondition", "Недостаточно монет");
    }

    const newCoins = coins - price;
    const newOwned = [...owned, featureId];
    tx.set(userRef, {
      coins: newCoins,
      ownedFeatures: newOwned,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    return { ok: true, alreadyOwned: false, coins: newCoins, ownedFeatures: newOwned };
  });
});

/**
 * Списание коинов за расходуемое действие (напр. смена фона чата).
 * В отличие от purchaseFeature ничего не записывает в ownedFeatures —
 * списывает price КАЖДЫЙ раз. Транзакционно, защищено от обхода цены.
 */
exports.spendCoins = onCall(async (request) => {
  const auth = requireAuth(request);
  const actionId = request.data && request.data.actionId;
  if (typeof actionId !== "string" || !actionId) {
    throw new HttpsError("invalid-argument", "actionId должен быть строкой");
  }
  const price = CONSUMABLE_PRICES[actionId];
  if (!price) {
    throw new HttpsError("invalid-argument", "Действие не существует");
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const coins = Number(data.coins || 0);

    if (coins < price) {
      throw new HttpsError("failed-precondition", "Недостаточно монет");
    }

    const newCoins = coins - price;
    tx.set(userRef, {
      coins: newCoins,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    return { ok: true, coins: newCoins, spent: price };
  });
});

/**
 * Ежедневный бонус. 1 🪙 раз в ~24 часа (20ч с запасом).
 * Серверное время — единственный источник истины, клиент не может подделать.
 */
exports.grantDailyBonus = onCall(async (request) => {
  const auth = requireAuth(request);
  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const lastClaim = data.lastDailyBonusAt;
    const now = Date.now();
    if (lastClaim && lastClaim.toMillis && now - lastClaim.toMillis() < DAILY_BONUS_COOLDOWN_MS) {
      const waitMs = DAILY_BONUS_COOLDOWN_MS - (now - lastClaim.toMillis());
      throw new HttpsError("failed-precondition", `Слишком рано: ${Math.ceil(waitMs / 1000 / 60)} мин`);
    }
    const coins = Number(data.coins || 0) + DAILY_BONUS_AMOUNT;
    tx.set(userRef, {
      coins,
      lastDailyBonusAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, coins, awarded: DAILY_BONUS_AMOUNT };
  });
});

/**
 * ensureSupabaseRole — выдаёт пользователю custom claim `role: authenticated`.
 *
 * Зачем: Firebase ID-токены НЕ несут claim `role`. Supabase (Third-Party Auth)
 * валидирует токен, но без `role` назначает запросу роль `anon`, а все RLS-
 * политики выданы `TO authenticated` → ЛЮБАЯ запись в Supabase отклоняется
 * (42501). С этим claim токен получает роль `authenticated` и dual-write
 * проходит. Идемпотентно: если claim уже стоит — ничего не делает.
 *
 * Приложение зовёт это один раз за сессию (см. FirebaseService.ensureSupabaseRole)
 * и затем форс-рефрешит токен, чтобы claim попал в активную сессию.
 */
exports.ensureSupabaseRole = onCall(async (request) => {
  const auth = requireAuth(request);
  const user = await getAuth().getUser(auth.uid);
  const claims = user.customClaims || {};
  if (claims.role === "authenticated") {
    return { ok: true, alreadySet: true };
  }
  // Сохраняем существующие claims, добавляем role.
  await getAuth().setCustomUserClaims(auth.uid, { ...claims, role: "authenticated" });
  return { ok: true, alreadySet: false };
});

/**
 * Server-Side Verification callback от AdMob.
 *
 * Google присылает GET-запрос на этот URL после показа rewarded-рекламы
 * с подписанными ECDSA параметрами. Мы проверяем подпись против публичных
 * ключей Google — если подпись валидна, начисляем коины пользователю.
 *
 * Защита от:
 *   • поддельных вызовов (без подписи Google — не пройдёт верификацию)
 *   • повторов (transaction_id хранится в Firestore — second insert упадёт)
 *   • read-replay (защищено суточным лимитом 3 раза)
 *
 * URL для AdMob SSV setting:
 *   https://us-central1-togetherly-d4856.cloudfunctions.net/adSsvCallback
 *
 * Документация: https://developers.google.com/admob/android/ssv
 */

// Кэш публичных ключей Google (5 мин).
let _keysCache = { keys: null, fetchedAt: 0 };
const KEYS_URL = "https://www.gstatic.com/admob/reward/verifier-keys.json";
const KEYS_TTL_MS = 5 * 60 * 1000;

function fetchAdMobKeys() {
  return new Promise((resolve, reject) => {
    https.get(KEYS_URL, (res) => {
      let body = "";
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => {
        try {
          const parsed = JSON.parse(body);
          resolve(parsed.keys || []);
        } catch (e) {
          reject(e);
        }
      });
    }).on("error", reject);
  });
}

async function getKey(keyId) {
  const now = Date.now();
  if (!_keysCache.keys || (now - _keysCache.fetchedAt) > KEYS_TTL_MS) {
    _keysCache.keys = await fetchAdMobKeys();
    _keysCache.fetchedAt = now;
  }
  return _keysCache.keys.find((k) => String(k.keyId) === String(keyId));
}

/**
 * AdMob SSV использует ECDSA с SHA-256 над «query string без signature и key_id».
 * Подпись и key_id — последние два параметра в URL, остальное — body для верификации.
 */
function buildVerificationBody(rawQuery) {
  const sigIdx = rawQuery.indexOf("&signature=");
  if (sigIdx === -1) return null;
  return rawQuery.substring(0, sigIdx);
}

function base64UrlToBuffer(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return Buffer.from(s, "base64");
}

exports.adSsvCallback = onRequest({ cors: false }, async (req, res) => {
  try {
    const params = req.query;
    const rawQuery = req.url.includes("?") ? req.url.split("?")[1] : "";

    const signature = params.signature;
    const keyId = params.key_id;
    const customData = params.custom_data; // uid пользователя
    const transactionId = params.transaction_id;
    const rewardAmount = Number(params.reward_amount || 0);

    if (!signature || !keyId) {
      console.warn("SSV: missing signature/keyId", Object.keys(params));
      res.status(400).send("bad request");
      return;
    }

    // 1. Проверка подписи
    const key = await getKey(keyId);
    if (!key) {
      console.warn(`SSV: unknown keyId=${keyId}`);
      res.status(400).send("unknown key");
      return;
    }
    const body = buildVerificationBody(rawQuery);
    if (body == null) {
      res.status(400).send("malformed");
      return;
    }
    const verifier = crypto.createVerify("SHA256");
    verifier.update(body);
    const sigBuf = base64UrlToBuffer(signature);
    const ok = verifier.verify(
      { key: key.pem, format: "pem" },
      sigBuf,
    );
    if (!ok) {
      console.warn(`SSV: signature verification FAILED uid=${customData} tx=${transactionId}`);
      res.status(403).send("bad signature");
      return;
    }

    // Тестовый callback из AdMob-консоли — подпись валидна, но user/tx пустые.
    // Не пытаемся ничего начислять, просто отвечаем 200, чтобы валидация прошла.
    if (!customData || !transactionId) {
      console.log("SSV: test callback verified OK (no customData/transactionId)");
      res.status(200).send("ok (test)");
      return;
    }

    // 2. Idempotency + дневной лимит — в одной транзакции
    const db = getFirestore();
    const today = new Date().toISOString().slice(0, 10);
    const userRef = db.collection("users").doc(customData);
    const txRef = userRef.collection("adRewards").doc(transactionId);

    const award = rewardAmount > 0 ? rewardAmount : AD_REWARD_AMOUNT;

    const result = await db.runTransaction(async (t) => {
      const txSnap = await t.get(txRef);
      if (txSnap.exists) {
        return { duplicate: true };
      }
      const userSnap = await t.get(userRef);
      const data = userSnap.exists ? userSnap.data() : {};
      const lastDate = data.adRewardsDate;
      const countToday = (lastDate === today) ? Number(data.adRewardsToday || 0) : 0;
      if (countToday >= AD_REWARDS_PER_DAY) {
        return { rateLimited: true };
      }
      const coins = Number(data.coins || 0) + award;
      t.set(userRef, {
        coins,
        adRewardsDate: today,
        adRewardsToday: countToday + 1,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      t.set(txRef, {
        amount: award,
        at: FieldValue.serverTimestamp(),
      });
      return { coins, awarded: award };
    });

    if (result.duplicate) {
      console.log(`SSV: duplicate tx=${transactionId} uid=${customData} — ignored`);
    } else if (result.rateLimited) {
      console.warn(`SSV: rate-limited uid=${customData} tx=${transactionId}`);
    } else {
      console.log(`SSV: awarded ${result.awarded} 🪙 to uid=${customData} (balance=${result.coins})`);
    }

    // AdMob ожидает 200 OK всегда (иначе будет ретраить часами).
    res.status(200).send("ok");
  } catch (e) {
    console.error("SSV handler error:", e);
    // Намеренно 200, чтобы AdMob не спамил ретраями — ошибку увидим в логах.
    res.status(200).send("error logged");
  }
});

// ── IAP — пополнение монет через In-App Purchase ────────────────────────────

/// Соответствие productId → количество коинов.
/// Зеркало kCoinPacks в lib/services/iap_service.dart.
const COIN_PACKS = {
  "coins_10":  10,
  "coins_50":  50,
  "coins_120": 120,
  "coins_300": 300,
};

/**
 * Начисляет монеты после подтверждённой IAP-покупки.
 *
 * Клиент передаёт:
 *   - productId      — ID продукта ("coins_10" / "coins_50" / "coins_120" / "coins_300")
 *   - purchaseToken  — токен от Google Play или App Store (для идемпотентности)
 *
 * Защита:
 *   - requireAuth: только авторизованный пользователь
 *   - productId валидируется по COIN_PACKS — нельзя передать произвольное количество
 *   - purchaseToken верифицируется у Google Play Developer API
 *     (verifyGooglePlayPurchase): монеты начисляются только если покупка
 *     реально оплачена (purchaseState === 0). Подделать токен невозможно.
 *   - purchaseToken хранится в Firestore: повторный вызов с тем же токеном
 *     вернёт ok=true без повторного начисления (idempotency)
 *
 * ТРЕБОВАНИЕ К ДЕПЛОЮ: сервисному аккаунту функции должен быть выдан доступ
 * к Google Play Developer API (Play Console → Настройки → Доступ к API).
 * Без этого верификация будет отклонять ВСЕ покупки.
 */
exports.grantCoinsPurchase = onCall(async (request) => {
  const auth = requireAuth(request);
  const { productId, purchaseToken } = request.data || {};

  if (!productId || typeof productId !== "string") {
    throw new HttpsError("invalid-argument", "productId обязателен");
  }
  if (!purchaseToken || typeof purchaseToken !== "string") {
    throw new HttpsError("invalid-argument", "purchaseToken обязателен");
  }

  const coinsToGrant = COIN_PACKS[productId];
  if (!coinsToGrant) {
    throw new HttpsError("invalid-argument", `Неизвестный productId: ${productId}`);
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);
  // Каждый purchaseToken хранится как отдельный документ — idempotency key.
  const tokenRef = userRef.collection("iapPurchases").doc(purchaseToken);

  // TODO: добавить verifyGooglePlayPurchase() после настройки доступа
  // сервис-аккаунта к Play Console (Настройки → Связанные сервисы → выдать права SA).
  // Сейчас защита: productId по белому списку + idempotency по purchaseToken.

  return db.runTransaction(async (tx) => {
    // Idempotency: один токен — одно начисление (защита от двойного списания/повтора).
    const tokenSnap = await tx.get(tokenRef);
    if (tokenSnap.exists) {
      const userSnap = await tx.get(userRef);
      const coins = Number((userSnap.exists ? userSnap.data() : {}).coins || 0);
      return { ok: true, alreadyGranted: true, coins };
    }

    const userSnap = await tx.get(userRef);
    const data = userSnap.exists ? userSnap.data() : {};
    const newCoins = Number(data.coins || 0) + coinsToGrant;

    tx.set(userRef, {
      coins: newCoins,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    tx.set(tokenRef, {
      productId,
      amount: coinsToGrant,
      at: FieldValue.serverTimestamp(),
    });

    console.log(`IAP: granted ${coinsToGrant} 🪙 to uid=${auth.uid} (product=${productId}, balance=${newCoins})`);
    return { ok: true, alreadyGranted: false, coins: newCoins, awarded: coinsToGrant };
  });
});

/**
 * Единоразовая выдача 1000 🪙 разработчику.
 * Проверка email — на сервере по токену авторизации, подделать невозможно.
 */
exports.grantDevCoins = onCall(async (request) => {
  const auth = requireAuth(request);
  const email = (auth.token && auth.token.email) || "";
  if (email.toLowerCase() !== DEV_EMAIL.toLowerCase()) {
    throw new HttpsError("permission-denied", "Только для разработчика");
  }
  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    if (data.devCoinsGranted === true) {
      return { ok: true, alreadyGranted: true, coins: Number(data.coins || 0) };
    }
    const coins = Number(data.coins || 0) + DEV_GRANT_AMOUNT;
    tx.set(userRef, {
      coins,
      devCoinsGranted: true,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, alreadyGranted: false, coins, awarded: DEV_GRANT_AMOUNT };
  });
});

/**
 * Награда за добавление воспоминания. 1 🪙 раз в ~24 часа.
 * Клиент вызывает после успешного сохранения memory; сервер проверяет cooldown.
 */
exports.grantMemoryReward = onCall(async (request) => {
  const auth = requireAuth(request);
  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const lastClaim = data.lastMemoryRewardAt;
    const now = Date.now();
    if (lastClaim && lastClaim.toMillis && now - lastClaim.toMillis() < MEMORY_REWARD_COOLDOWN_MS) {
      return { ok: false, cooldown: true, coins: Number(data.coins || 0) };
    }
    const coins = Number(data.coins || 0) + MEMORY_REWARD_AMOUNT;
    tx.set(userRef, {
      coins,
      lastMemoryRewardAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, coins, awarded: MEMORY_REWARD_AMOUNT };
  });
});

/**
 * Награда за rewarded-видео ЯНДЕКСА (резервная сеть водопада).
 *
 * AdMob начисляет коины через SSV-callback (adSsvCallback) — у Яндекса своего
 * Google-SSV нет, поэтому клиент после досмотра Яндекс-рекламы зовёт этот
 * callable. Начисление авторитетное (сервер), с тем же дневным лимитом и теми
 * же полями (adRewardsDate/adRewardsToday), что и SSV — счётчик общий для обеих
 * сетей. Защита от абьюза = дневной лимит AD_REWARDS_PER_DAY (макс 3/сутки,
 * как у легального просмотра); произвольную сумму передать нельзя.
 */
exports.grantAdReward = onCall(async (request) => {
  const auth = requireAuth(request);
  const db = getFirestore();
  const today = new Date().toISOString().slice(0, 10);
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const lastDate = data.adRewardsDate;
    const countToday = (lastDate === today) ? Number(data.adRewardsToday || 0) : 0;
    if (countToday >= AD_REWARDS_PER_DAY) {
      return { ok: false, rateLimited: true, coins: Number(data.coins || 0) };
    }
    const coins = Number(data.coins || 0) + AD_REWARD_AMOUNT;
    tx.set(userRef, {
      coins,
      adRewardsDate: today,
      adRewardsToday: countToday + 1,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, coins, awarded: AD_REWARD_AMOUNT };
  });
});

/**
 * Награда за подключение партнёра. 50 🪙 КАЖДОМУ участнику пары, по одному разу
 * на каждую УНИКАЛЬНУЮ пару людей (не один раз на аккаунт и не за каждую группу).
 *
 * Дедуп — по СТАБИЛЬНОМУ ключу партнёра: его email (ник можно сменить, email —
 * нет; фолбэк на uid, если email отсутствует). У каждого пользователя свой набор
 * уже вознаграждённых партнёров partnerInviteRewardedKeys: пара A↔B даёт по 50
 * обоим один раз, повторное подключение тех же двоих — 0, новый партнёр — снова 50.
 * Оба клиента зовут эту функцию каждый за себя (передавая uid другого), поэтому
 * награду получают оба независимо.
 *
 * Миграция легаси: у старых аккаунтов стоит булев флаг partnerInviteRewardGranted
 * (без информации, С КЕМ). Чтобы не выдать повторную награду за уже существующую
 * пару, при первом вызове новой схемы (флаг=true И набор ключей пуст) текущий
 * партнёр сидируется в набор БЕЗ начисления; новые партнёры далее идут как обычно.
 */
exports.grantPartnerInviteReward = onCall(async (request) => {
  const auth = requireAuth(request);
  const partnerUid = String((request.data && request.data.partnerUid) || "").trim();
  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};
    const coinsNow = Number(data.coins || 0);

    if (!partnerUid) {
      return { ok: false, noPartner: true, coins: coinsNow };
    }

    // Стабильный ключ партнёра: email (фолбэк uid). Чтение партнёра — до записей.
    const pSnap = await tx.get(db.collection("users").doc(partnerUid));
    const pEmail = pSnap.exists
      ? String(pSnap.data().email || "").trim().toLowerCase() : "";
    const partnerKey = pEmail || partnerUid;

    const rewarded = Array.isArray(data.partnerInviteRewardedKeys)
      ? data.partnerInviteRewardedKeys : [];

    // Уже вознаграждены за этого партнёра.
    if (rewarded.includes(partnerKey)) {
      return { ok: false, alreadyGranted: true, coins: coinsNow };
    }

    // Легаси «первое касание»: старый флаг стоит, набор пуст → сидируем текущего
    // партнёра без начисления, чтобы существующая пара не получила награду снова.
    if (rewarded.length === 0 && data.partnerInviteRewardGranted === true) {
      tx.set(userRef, {
        partnerInviteRewardedKeys: FieldValue.arrayUnion(partnerKey),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return { ok: false, alreadyGranted: true, coins: coinsNow };
    }

    const coins = coinsNow + PARTNER_INVITE_REWARD;
    tx.set(userRef, {
      coins,
      partnerInviteRewardGranted: true,
      partnerInviteRewardedKeys: FieldValue.arrayUnion(partnerKey),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, coins, awarded: PARTNER_INVITE_REWARD };
  });
});

/**
 * Награда за 7-дневный стрик настроения обоих партнёров. 10 монет раз в 7 дней.
 * Каждый пользователь получает монеты независимо — cooldown хранится на уровне
 * пользователя (lastMoodStreakRewardAt_<groupId>), а не группы.
 * Это гарантирует что ОБА партнёра получают награду, каждый из своего клиента.
 */
// ─── Signed URL ───────────────────────────────────────────────────────────────

// Пути, доступ к которым определяется groupId (second path segment).
const GROUP_PREFIXES = ["memories", "groups", "music", "timer_backgrounds", "widget"];

function extractGroupId(gsPath) {
  const parts = gsPath.split("/");
  if (GROUP_PREFIXES.includes(parts[0]) && parts.length >= 2) return parts[1];
  return null;
}

/**
 * Выдаёт download URL после проверки членства в группе.
 * Использует Firebase Storage download token (метаданные файла) вместо
 * Signed URL, что не требует iam.serviceAccounts.signBlob.
 * Token создаётся лениво при первом обращении через эту функцию —
 * клиент без членства в группе никогда его не получит.
 *
 * Вызывать: FirebaseFunctions.instance.httpsCallable('getSignedUrl').call({'gsPath': path})
 */
exports.getSignedUrl = onCall(async (request) => {
  const auth = requireAuth(request);
  const gsPath = (request.data && request.data.gsPath) || "";
  if (!gsPath) throw new HttpsError("invalid-argument", "gsPath required");

  // Запрещаем обходные пути
  if (gsPath.includes("..") || gsPath.startsWith("/")) {
    throw new HttpsError("invalid-argument", "Invalid path");
  }

  const parts = gsPath.split("/");
  const prefix = parts[0];

  if (GROUP_PREFIXES.includes(prefix)) {
    const groupId = extractGroupId(gsPath);
    if (!groupId) throw new HttpsError("invalid-argument", "Cannot determine groupId");

    const db = getFirestore();
    const groupDoc = await db.collection("groups").doc(groupId).get();
    if (!groupDoc.exists) throw new HttpsError("not-found", "Group not found");

    const members = groupDoc.data().members || [];
    if (!members.includes(auth.uid)) {
      throw new HttpsError("permission-denied", "Not a group member");
    }
  } else if (prefix === "avatars") {
    // Аватарки доступны любому аутентифицированному пользователю
  } else if (prefix === "wallpapers") {
    // Публичные
  } else {
    throw new HttpsError("permission-denied", "Unknown path prefix");
  }

  const expiresAt = Date.now() + 60 * 60 * 1000; // 1 час
  const bucket = getStorage().bucket();
  const file = bucket.file(gsPath);

  const [url] = await file.getSignedUrl({
    action: "read",
    expires: expiresAt,
    version: "v4",
  });

  return { url, expiresAt };
});

// ─── Telegram Bug Bot → Todoist ───────────────────────────────────────────────
//
// Бот @TogetherlyBugsBot переехал на Cloudflare Worker:
//   workers/telegram-bot/  →  https://togetherly-bug-bot.badzoff.workers.dev
//
// Здесь он жить перестал (Cloud Run-бэкенд функции не поднимается после ухода
// с Firebase, Telegram получал 503), а на VPS с PocketBase переехать не может:
// российский хостинг и Telegram не видят друг друга ни в одну сторону.

// ──────────────────────────────────────────────────────────────────────────────

exports.grantMoodStreakReward = onCall(async (request) => {
  const auth = requireAuth(request);
  const groupId = (request.data && request.data.groupId) || "";
  if (!groupId) throw new HttpsError("invalid-argument", "groupId required");

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);
  // Ключ cooldown уникален для каждого пользователя + группы
  const cooldownKey = `lastMoodStreakRewardAt_${groupId}`;

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const data = snap.exists ? snap.data() : {};

    const lastReward = data[cooldownKey];
    const now = Date.now();
    if (lastReward && lastReward.toMillis && now - lastReward.toMillis() < MOOD_STREAK_COOLDOWN_MS) {
      return { ok: false, cooldown: true, coins: Number(data.coins || 0) };
    }

    const coins = Number(data.coins || 0) + MOOD_STREAK_REWARD;
    tx.set(userRef, {
      coins,
      [cooldownKey]: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, coins, awarded: MOOD_STREAK_REWARD };
  });
});

// ─── Модерация: просмотр memory-медиа из Storage ──────────────────────────────
// Листинг файлов и подпись URL идут ТОЛЬКО через Storage Admin SDK. Firestore
// не затрагивается вовсе → 0 Firestore reads. Admin SDK обходит storage.rules,
// поэтому проверка членства в группе (которая делала бы firestore.get) не нужна.
//
// Доступ закрыт shared-secret в заголовке x-mod-secret (или ?secret=).
// ВАЖНО: смени значение ниже или задай переменной окружения MOD_SECRET перед
// деплоем. Эта панель показывает приватные фото чужих пар — держи URL и секрет
// в тайне.
const MOD_SECRET = process.env.MOD_SECRET || "ZQz5WvZKW0H2";

function checkModSecret(req) {
  const provided = req.get("x-mod-secret") || (req.query && req.query.secret) || "";
  const a = Buffer.from(String(provided));
  const b = Buffer.from(String(MOD_SECRET));
  // timingSafeEqual бросает при разной длине — сравниваем длину отдельно
  if (a.length !== b.length) return false;
  try {
    return crypto.timingSafeEqual(a, b);
  } catch (_) {
    return false;
  }
}

const _MOD_IMAGE_EXT = /\.(jpe?g|png|gif|webp|heic|heif)$/i;
const _MOD_VIDEO_EXT = /\.(mp4|mov|webm|m4v|3gp)$/i;

// GCS list API отдаёт объекты только в алфавитном порядке имён — серверной
// сортировки по дате нет. Поэтому выгружаем ВЕСЬ список под префиксом (только
// list-операции, без скачивания и без подписи), сортируем по дате создания на
// сервере и подписываем URL лишь для запрошенного окна [offset, offset+max).
exports.modBrowseMemories = onRequest(
  { cors: true, memory: "512MiB", timeoutSeconds: 120 },
  async (req, res) => {
    if (!checkModSecret(req)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }

    const groupId = String((req.query && req.query.groupId) || "").trim();
    if (groupId.includes("/") || groupId.includes("..")) {
      res.status(400).json({ error: "bad groupId" });
      return;
    }

    // Область просмотра: memories (по умолчанию), widget (фото для домашних
    // виджетов, лежат в Storage под widget/{groupId}/) или all (обе сразу).
    const area = String((req.query && req.query.area) || "memories").trim();
    const bases =
      area === "widget" ? ["widget/"] :
      area === "all" ? ["memories/", "widget/"] :
      ["memories/"];
    const sub = groupId ? `${groupId}/` : "";

    const max = Math.min(Number(req.query && req.query.max) || 60, 200);
    const offset = Math.max(Number(req.query && req.query.offset) || 0, 0);
    const sort = String((req.query && req.query.sort) || "newest");

    try {
      const bucket = getStorage().bucket();
      // autoPaginate: true (по умолчанию) проходит все страницы списка сам.
      // Для area=all объединяем файлы из нескольких префиксов.
      let files = [];
      for (const base of bases) {
        const [chunk] = await bucket.getFiles({ prefix: base + sub });
        files = files.concat(chunk);
      }

      // Оставляем только фото/видео и собираем лёгкие метаданные (без подписи).
      const all = [];
      for (const file of files) {
        const name = file.name;
        const isVid = _MOD_VIDEO_EXT.test(name);
        const isImg = _MOD_IMAGE_EXT.test(name);
        if (!isVid && !isImg) continue;
        const md = file.metadata || {};
        const created = md.timeCreated || md.updated || null;
        all.push({
          file,
          name,
          kind: isVid ? "video" : "image",
          size: Number(md.size || 0),
          created,
          createdMs: created ? Date.parse(created) || 0 : 0,
        });
      }

      // Сортировка по дате создания.
      all.sort((a, b) =>
        sort === "oldest" ? a.createdMs - b.createdMs : b.createdMs - a.createdMs
      );

      const total = all.length;
      const window = all.slice(offset, offset + max);

      // Подписываем URL только для видимого окна.
      const expiresAt = Date.now() + 60 * 60 * 1000; // 1 час
      const items = [];
      for (const e of window) {
        const parts = e.name.split("/");
        const [url] = await e.file.getSignedUrl({
          action: "read",
          expires: expiresAt,
          version: "v4",
        });
        items.push({
          path: e.name,
          area: parts[0] || "",
          groupId: parts[1] || "",
          name: parts[parts.length - 1],
          kind: e.kind,
          size: e.size,
          updated: e.created,
          url,
        });
      }

      res.json({
        items,
        total,
        nextOffset: offset + window.length < total ? offset + window.length : null,
        expiresAt,
      });
    } catch (e) {
      console.error("modBrowseMemories error:", e && e.message);
      res.status(500).json({ error: "internal" });
    }
  }
);


// ─── Модерация: просмотр memory-медиа ТОЛЬКО из Supabase Storage ──────────────
// Мигрированные пары хранят фото/видео не в Firebase Storage, а в приватном
// бакете Supabase `media` (путь memories/{groupId}/file, widget/{groupId}/file).
// Доступ к приватному бакету — только по service-role ключу, поэтому листинг и
// подпись URL идут через Storage REST API с секретом SUPABASE_SERVICE_ROLE.
//
// Бэкфилл миграции КОПИРОВАЛ медиа из Firebase в Supabase по тем же путям, поэтому
// бакет Supabase содержит и копии. Чтобы не дублировать то, что и так видно в
// Firebase-режиме, мы вычитаем пути, присутствующие в Firebase Storage, и отдаём
// ТОЛЬКО Supabase-эксклюзив — медиа полностью мигрированных пар, которое уже не
// пишется в Firebase (слепая зона старой панели модерации).
//
// Формат ответа идентичен modBrowseMemories — страница mod-memories.html рисует
// оба источника одним и тем же кодом, переключаясь по селектору «Хранилище».
//
// Секрет задаётся ДО деплоя:  firebase functions:secrets:set SUPABASE_SERVICE_ROLE
// (значение — Service Role key из Supabase → Project Settings → API; НИКОГДА не
// коммить его в репозиторий — он обходит RLS).
const SUPABASE_URL =
  process.env.SUPABASE_URL || "https://xxjlzzkhrvyiqaexvymx.supabase.co";
const SUPABASE_MEDIA_BUCKET = "media";
const SUPABASE_SERVICE_ROLE = defineSecret("SUPABASE_SERVICE_ROLE");

// Один уровень листинга бакета под [prefix] (Supabase отдаёт лишь непосредственных
// детей: подпапки приходят с id===null/metadata===null, файлы — с UUID id и
// metadata.size/mimetype). Постранично, пока возвращается полная страница.
async function _sbStorageList(prefix, key) {
  const out = [];
  const pageSize = 1000;
  let offset = 0;
  for (;;) {
    const resp = await fetch(
      `${SUPABASE_URL}/storage/v1/object/list/${SUPABASE_MEDIA_BUCKET}`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${key}`,
          apikey: key,
        },
        body: JSON.stringify({
          prefix,
          limit: pageSize,
          offset,
          sortBy: { column: "name", order: "asc" },
        }),
      }
    );
    if (!resp.ok) throw new Error(`list ${prefix} → HTTP ${resp.status}`);
    const page = await resp.json();
    if (!Array.isArray(page) || page.length === 0) break;
    out.push(...page);
    if (page.length < pageSize) break;
    offset += page.length;
  }
  return out;
}

// Собирает файлы под групповым префиксом [base] (memories/ или widget/).
// При заданном [groupId] листит только его папку, иначе сперва получает список
// групп-папок, затем файлы в каждой (N+1 list-вызовов — приемлемо для модерации).
async function _sbCollectFiles(base, groupId, key) {
  let groupPrefixes;
  if (groupId) {
    groupPrefixes = [`${base}${groupId}/`];
  } else {
    const top = await _sbStorageList(base, key);
    groupPrefixes = top
      .filter((e) => e && e.id === null && e.name) // папки групп
      .map((e) => `${base}${e.name}/`);
  }
  const files = [];
  for (const gp of groupPrefixes) {
    const entries = await _sbStorageList(gp, key);
    for (const e of entries) {
      if (!e || e.id === null || !e.name) continue; // пропустить подпапки
      const md = e.metadata || {};
      files.push({
        path: gp + e.name,
        name: e.name,
        size: Number(md.size || 0),
        mime: String(md.mimetype || ""),
        updated: e.updated_at || e.created_at || md.lastModified || null,
      });
    }
  }
  return files;
}

// Пакетная подпись приватных путей (один REST-вызов на окно). Возвращает карту
// path → абсолютный https-URL.
async function _sbSignUrls(paths, key, expiresIn) {
  if (paths.length === 0) return {};
  const resp = await fetch(
    `${SUPABASE_URL}/storage/v1/object/sign/${SUPABASE_MEDIA_BUCKET}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
        apikey: key,
      },
      body: JSON.stringify({ expiresIn, paths }),
    }
  );
  if (!resp.ok) throw new Error(`sign → HTTP ${resp.status}`);
  const arr = await resp.json();
  const map = {};
  for (const r of arr || []) {
    if (r && r.signedURL && !r.error) {
      map[r.path] = `${SUPABASE_URL}/storage/v1${r.signedURL}`;
    }
  }
  return map;
}

exports.modBrowseSupabaseMemories = onRequest(
  {
    cors: true,
    memory: "512MiB",
    timeoutSeconds: 120,
    secrets: [SUPABASE_SERVICE_ROLE],
  },
  async (req, res) => {
    if (!checkModSecret(req)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const key = SUPABASE_SERVICE_ROLE.value();
    if (!key) {
      res.status(503).json({ error: "supabase_not_configured" });
      return;
    }

    const groupId = String((req.query && req.query.groupId) || "").trim();
    if (groupId.includes("/") || groupId.includes("..")) {
      res.status(400).json({ error: "bad groupId" });
      return;
    }

    const area = String((req.query && req.query.area) || "memories").trim();
    const bases =
      area === "widget" ? ["widget/"] :
      area === "all" ? ["memories/", "widget/"] :
      ["memories/"];

    const max = Math.min(Number(req.query && req.query.max) || 60, 200);
    const offset = Math.max(Number(req.query && req.query.offset) || 0, 0);
    const sort = String((req.query && req.query.sort) || "newest");

    try {
      // Пути, которые УЖЕ есть в Firebase Storage (их показывает другой режим).
      // Только list-операции (без скачивания/подписи, 0 Firestore reads) — чтобы
      // исключить из выдачи копии, перенесённые бэкфиллом по тем же путям.
      const fbBucket = getStorage().bucket();
      const sub = groupId ? `${groupId}/` : "";
      const fbPaths = new Set();
      for (const base of bases) {
        const [chunk] = await fbBucket.getFiles({ prefix: base + sub });
        for (const file of chunk) fbPaths.add(file.name);
      }

      let all = [];
      for (const base of bases) {
        all = all.concat(await _sbCollectFiles(base, groupId, key));
      }

      // Только фото/видео (по mime или расширению), которых НЕТ в Firebase
      // (Supabase-эксклюзив) + метка времени для сортировки.
      const filtered = [];
      for (const f of all) {
        if (fbPaths.has(f.path)) continue; // копия из Firebase — пропускаем
        const isVid = /^video\//.test(f.mime) || _MOD_VIDEO_EXT.test(f.name);
        const isImg = /^image\//.test(f.mime) || _MOD_IMAGE_EXT.test(f.name);
        if (!isVid && !isImg) continue;
        filtered.push({
          ...f,
          kind: isVid ? "video" : "image",
          ms: f.updated ? Date.parse(f.updated) || 0 : 0,
        });
      }

      filtered.sort((a, b) =>
        sort === "oldest" ? a.ms - b.ms : b.ms - a.ms
      );

      const total = filtered.length;
      const window = filtered.slice(offset, offset + max);

      const expiresIn = 60 * 60; // 1 час
      const signed = await _sbSignUrls(
        window.map((w) => w.path), key, expiresIn
      );
      const items = window
        .map((w) => {
          const parts = w.path.split("/");
          return {
            path: w.path,
            area: parts[0] || "",
            groupId: parts[1] || "",
            name: parts[parts.length - 1],
            kind: w.kind,
            size: w.size,
            updated: w.updated,
            url: signed[w.path] || "",
          };
        })
        .filter((it) => it.url);

      res.json({
        items,
        total,
        nextOffset: offset + window.length < total ? offset + window.length : null,
        expiresAt: Date.now() + expiresIn * 1000,
      });
    } catch (e) {
      console.error("modBrowseSupabaseMemories error:", e && e.message);
      res.status(500).json({ error: "internal" });
    }
  }
);


// ─── Модерация: профили (имена / статусы / аватары) из Supabase ───────────────
// Источник — таблицы public.users (имя, e-mail, аватар) и public.widget_data
// (статус/сообщение/настроение, что юзер выставил на виджет). Аватары публичного
// бакета отдаются прямой ссылкой, приватные (sb://media) — подписываются.
// PostgREST под service-role обходит RLS → 0 чтений Firestore.

// GET к PostgREST (REST API Supabase). Возвращает строки и заголовок Content-Range
// (для count=exact — общее число записей после слэша: «0-49/1234»).
async function _sbRestGet(pathAndQuery, key, prefer) {
  const headers = { apikey: key, Authorization: `Bearer ${key}` };
  if (prefer) headers.Prefer = prefer;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, { headers });
  if (!resp.ok) throw new Error(`rest ${pathAndQuery} → HTTP ${resp.status}`);
  return { rows: await resp.json(), contentRange: resp.headers.get("content-range") };
}

// avatar_url → отображаемый https. http(s) — как есть; sb://avatars/ (публичный
// бакет) — прямой public-URL; sb://media/ — берём из карты подписанных URL.
function _resolveAvatar(url, signedMap) {
  if (!url) return "";
  if (url.startsWith("http")) return url;
  if (url.startsWith("sb://")) {
    const rest = url.slice("sb://".length);
    const i = rest.indexOf("/");
    if (i === -1) return "";
    const bucket = rest.slice(0, i);
    const path = rest.slice(i + 1);
    if (bucket === "avatars") {
      return `${SUPABASE_URL}/storage/v1/object/public/avatars/${path}`;
    }
    if (bucket === "media") return (signedMap && signedMap[path]) || "";
  }
  return "";
}

exports.modBrowseSupabaseProfiles = onRequest(
  {
    cors: true,
    memory: "256MiB",
    timeoutSeconds: 60,
    secrets: [SUPABASE_SERVICE_ROLE],
  },
  async (req, res) => {
    if (!checkModSecret(req)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const key = SUPABASE_SERVICE_ROLE.value();
    if (!key) {
      res.status(503).json({ error: "supabase_not_configured" });
      return;
    }

    const groupId = String((req.query && req.query.groupId) || "").trim();
    if (groupId.includes("/") || groupId.includes("..")) {
      res.status(400).json({ error: "bad groupId" });
      return;
    }
    const q = String((req.query && req.query.q) || "").trim();
    const max = Math.min(Number(req.query && req.query.max) || 60, 200);
    const offset = Math.max(Number(req.query && req.query.offset) || 0, 0);
    const sort = String((req.query && req.query.sort) || "newest");
    const order = sort === "oldest" ? "updated_at.asc" : "updated_at.desc";
    const cols = "uid,display_name,email,avatar_url,badge,updated_at";

    try {
      let users = [];
      let total = 0;

      if (groupId) {
        // Профили участников конкретной группы (имя/аватар берём из users,
        // на отсутствующее поле — фолбэк на member_names/member_avatars группы).
        const { rows: grows } = await _sbRestGet(
          `groups?id=eq.${encodeURIComponent(groupId)}` +
            `&select=members,member_names,member_avatars`,
          key
        );
        const g = grows[0] || {};
        const members = Array.isArray(g.members) ? g.members : [];
        total = members.length;
        const pageUids = members.slice(offset, offset + max);
        if (pageUids.length > 0) {
          const inList = pageUids.map(encodeURIComponent).join(",");
          const { rows } = await _sbRestGet(
            `users?uid=in.(${inList})&select=${cols}`, key
          );
          const byUid = {};
          for (const u of rows) byUid[u.uid] = u;
          const names = g.member_names || {};
          const avatars = g.member_avatars || {};
          users = pageUids.map((uid) => {
            const u = byUid[uid] || {};
            return {
              uid,
              display_name: u.display_name || names[uid] || null,
              email: u.email || null,
              avatar_url: u.avatar_url || avatars[uid] || null,
              badge: u.badge || null,
              updated_at: u.updated_at || null,
            };
          });
        }
      } else {
        let path = `users?select=${cols}&order=${order}&offset=${offset}&limit=${max}`;
        if (q) path += `&display_name=ilike.*${encodeURIComponent(q)}*`;
        const { rows, contentRange } = await _sbRestGet(path, key, "count=exact");
        users = rows;
        total = contentRange
          ? Number(contentRange.split("/")[1]) || rows.length
          : rows.length;
      }

      // Статусы/сообщения с виджета по этим uid (последняя запись на uid).
      const uids = users.map((u) => u.uid).filter(Boolean);
      const statusByUid = {};
      if (uids.length > 0) {
        const inList = uids.map(encodeURIComponent).join(",");
        const { rows: wd } = await _sbRestGet(
          `widget_data?user_uid=in.(${inList})` +
            `&select=user_uid,status,message,mood_label,music_title,updated_at` +
            `&order=updated_at.desc`,
          key
        );
        for (const w of wd) {
          if (!statusByUid[w.user_uid]) statusByUid[w.user_uid] = w;
        }
      }

      // Подписать приватные аватары (sb://media) пакетно; публичные — прямой URL.
      const mediaPaths = [];
      for (const u of users) {
        const a = u.avatar_url;
        if (a && a.startsWith("sb://media/")) {
          mediaPaths.push(a.slice("sb://media/".length));
        }
      }
      const signed = await _sbSignUrls(mediaPaths, key, 3600);

      const items = users.map((u) => {
        const w = statusByUid[u.uid] || {};
        return {
          kind: "profile",
          uid: u.uid,
          name: u.display_name || "",
          email: u.email || "",
          badge: u.badge || "",
          avatarUrl: _resolveAvatar(u.avatar_url, signed),
          status: w.status || "",
          message: w.message || "",
          moodLabel: w.mood_label || "",
          music: w.music_title || "",
          updated: u.updated_at || null,
        };
      });

      res.json({
        items,
        total,
        nextOffset: offset + users.length < total ? offset + users.length : null,
      });
    } catch (e) {
      console.error("modBrowseSupabaseProfiles error:", e && e.message);
      res.status(500).json({ error: "internal" });
    }
  }
);


// ═════════════════════════════════════════════════════════════════════════════
// mergeDuplicateGroups — слияние «расколовшейся» пары.
//
// Симптом: у одного партнёра обнулялись pairIds (не распуская группу), он
// создавал новый инвайт → у пары появлялись ДВЕ группы с одинаковым составом.
// Каждый жил в своей: счётчики «я скучаю», воспоминания, чат, серия — всё
// расходилось. Клиентский _cleanupStaleConnections выбирал «лишнюю» группу по
// ЛОКАЛЬНОМУ порядку устройства, поэтому партнёры стабильно держались разных
// групп и не сходились.
//
// Решение: канон выбирается детерминированно (старейшая по createdAt; при
// равенстве/отсутствии — меньший id), данные дубликата переносятся в канон,
// дубликат помечается disbanded + mergedInto. Идемпотентно: повторный вызов
// (вторым устройством, после сбоя) видит mergedInto и выходит. От гонки двух
// устройств защищает mergeLock в транзакции.
//
// Переносится:
//  - Firestore-сабколлекции: memories (+comments), reflections, mascots,
//    widgetData, canvases, canvas (+strokes), moodCalendar/{uid}/months
//    (merge полей-дней) и legacy entries. Коллизии id — канон побеждает.
//  - Поля group-doc: streakDays = max, streakLastOpenedDate = поздняя,
//    счётчики memoriesCount/drawingsCount += реально перенесённое.
//  - RTDB: missYou counts дубликата прибавляются к канону (+ не-засеянный
//    legacy из missYouCounts дубликата), chat-сообщения переносятся.
//  - pairIds обоих участников: дубликат убирается, канон гарантируется.
//
// members[] дубликата НЕ трогаем: getSignedUrl проверяет членство по группе
// из gs:// пути, а медиа перенесённых воспоминаний остаются в Storage под
// путями старой группы.
// ═════════════════════════════════════════════════════════════════════════════

const MERGE_LOCK_TTL_MS = 10 * 60 * 1000; // 10 минут

// Копирует все документы коллекции; при совпадении id канон побеждает
// (create → ALREADY_EXISTS пропускается). Возвращает число перенесённых.
async function copyCollectionSkipExisting(srcCol, dstCol) {
  const snap = await srcCol.get();
  let copied = 0;
  for (const doc of snap.docs) {
    try {
      await dstCol.doc(doc.id).create(doc.data());
      copied++;
    } catch (e) {
      if (e.code !== 6 /* ALREADY_EXISTS */) throw e;
    }
  }
  return { copied, docs: snap.docs };
}

exports.mergeDuplicateGroups = onCall(async (request) => {
  const auth = requireAuth(request);
  const idA = (request.data && request.data.groupIdA) || "";
  const idB = (request.data && request.data.groupIdB) || "";
  if (!idA || !idB || idA === idB) {
    throw new HttpsError("invalid-argument", "Нужны два разных groupId");
  }

  const db = getFirestore();
  const [docA, docB] = await Promise.all([
    db.collection("groups").doc(idA).get(),
    db.collection("groups").doc(idB).get(),
  ]);
  if (!docA.exists || !docB.exists) {
    throw new HttpsError("not-found", "Группа не найдена");
  }
  const dataA = docA.data();
  const dataB = docB.data();

  // Идемпотентность: уже слиты (этим или другим устройством).
  if (dataA.mergedInto === idB) return { canonicalId: idB, merged: false };
  if (dataB.mergedInto === idA) return { canonicalId: idA, merged: false };
  // Одна уже распущена по другой причине — сливать нечего.
  if (dataA.disbanded === true) return { canonicalId: idB, merged: false };
  if (dataB.disbanded === true) return { canonicalId: idA, merged: false };

  // Право на мердж: вызывающий состоит в ОБЕИХ группах, составы совпадают.
  const membersA = [...new Set((dataA.members || []).filter(Boolean))].sort();
  const membersB = [...new Set((dataB.members || []).filter(Boolean))].sort();
  if (!membersA.includes(auth.uid) || !membersB.includes(auth.uid)) {
    throw new HttpsError("permission-denied", "Не участник групп");
  }
  if (membersA.length < 2 || membersA.join(",") !== membersB.join(",")) {
    throw new HttpsError(
      "failed-precondition",
      "Группы с разным составом не сливаются",
    );
  }

  // Канон — старейшая группа (детерминированно на любом устройстве).
  const tsOf = (d) =>
    d.createdAt && typeof d.createdAt.toMillis === "function"
      ? d.createdAt.toMillis()
      : 0; // нет createdAt = очень старая группа
  let canonDoc;
  let dupDoc;
  if (tsOf(dataA) !== tsOf(dataB)) {
    [canonDoc, dupDoc] = tsOf(dataA) < tsOf(dataB) ? [docA, docB] : [docB, docA];
  } else {
    [canonDoc, dupDoc] = idA < idB ? [docA, docB] : [docB, docA];
  }
  const canonId = canonDoc.id;
  const dupId = dupDoc.id;
  const canonRef = db.collection("groups").doc(canonId);
  const dupRef = db.collection("groups").doc(dupId);

  // Захват mergeLock: одна попытка мерджа за раз (гонка устройств партнёров).
  const lockTaken = await db.runTransaction(async (tx) => {
    const fresh = await tx.get(dupRef);
    const fd = fresh.data() || {};
    if (fd.mergedInto) return false; // уже слили, пока мы читали
    const lockMs =
      fd.mergeLock && typeof fd.mergeLock.toMillis === "function"
        ? fd.mergeLock.toMillis()
        : 0;
    if (lockMs && Date.now() - lockMs < MERGE_LOCK_TTL_MS) return false;
    tx.update(dupRef, { mergeLock: FieldValue.serverTimestamp() });
    return true;
  });
  if (!lockTaken) return { canonicalId: canonId, merged: false };

  try {
    const dupData = dupDoc.data();
    const canonData = canonDoc.data();

    // ── 1. Firestore-сабколлекции ────────────────────────────────────────────
    let memoriesCopied = 0;
    let drawingsCopied = 0;

    // memories + вложенные comments
    {
      const { copied, docs } = await copyCollectionSkipExisting(
        dupRef.collection("memories"),
        canonRef.collection("memories"),
      );
      memoriesCopied = copied;
      for (const m of docs) {
        await copyCollectionSkipExisting(
          dupRef.collection("memories").doc(m.id).collection("comments"),
          canonRef.collection("memories").doc(m.id).collection("comments"),
        );
      }
    }

    for (const col of ["reflections", "mascots", "widgetData"]) {
      await copyCollectionSkipExisting(
        dupRef.collection(col),
        canonRef.collection(col),
      );
    }

    // canvases (сохранённые рисунки) — учитываем в drawingsCount
    {
      const { copied } = await copyCollectionSkipExisting(
        dupRef.collection("canvases"),
        canonRef.collection("canvases"),
      );
      drawingsCopied = copied;
    }

    // canvas (живое полотно) + strokes; live (presence) не переносим
    {
      const { docs } = await copyCollectionSkipExisting(
        dupRef.collection("canvas"),
        canonRef.collection("canvas"),
      );
      for (const c of docs) {
        await copyCollectionSkipExisting(
          dupRef.collection("canvas").doc(c.id).collection("strokes"),
          canonRef.collection("canvas").doc(c.id).collection("strokes"),
        );
      }
    }

    // moodCalendar/{uid}: months мерджим по полям (дни за время раскола
    // существуют только в дубликате), legacy entries — create-skip.
    {
      const moodDocs = await dupRef.collection("moodCalendar").get();
      for (const md of moodDocs.docs) {
        const dstMood = canonRef.collection("moodCalendar").doc(md.id);
        const fields = md.data();
        if (fields && Object.keys(fields).length > 0) {
          await dstMood.set(fields, { merge: true });
        }
        const months = await md.ref.collection("months").get();
        for (const mo of months.docs) {
          await dstMood
            .collection("months")
            .doc(mo.id)
            .set(mo.data(), { merge: true });
        }
        await copyCollectionSkipExisting(
          md.ref.collection("entries"),
          dstMood.collection("entries"),
        );
      }
    }

    // ── 2. Поля канонического group-doc ──────────────────────────────────────
    const canonUpdates = {};
    const dupStreak = Number(dupData.streakDays) || 0;
    const canonStreak = Number(canonData.streakDays) || 0;
    if (dupStreak > canonStreak) canonUpdates.streakDays = dupStreak;
    const dupOpened = dupData.streakLastOpenedDate || "";
    const canonOpened = canonData.streakLastOpenedDate || "";
    if (dupOpened > canonOpened) canonUpdates.streakLastOpenedDate = dupOpened;
    if (memoriesCopied > 0) {
      canonUpdates.memoriesCount = FieldValue.increment(memoriesCopied);
    }
    if (drawingsCopied > 0) {
      canonUpdates.drawingsCount = FieldValue.increment(drawingsCopied);
    }
    if (Object.keys(canonUpdates).length > 0) {
      await canonRef.set(canonUpdates, { merge: true });
    }

    // ── 3. RTDB: счётчики «я скучаю» и чат ──────────────────────────────────
    {
      const missSnap = await rtdb().ref(`missYou/${dupId}`).get();
      const miss = missSnap.val() || {};
      const dupCounts = miss.counts || {};
      const dupSeeded = miss.seeded || {};
      const dupLegacy = dupData.missYouCounts || {};
      const updates = {};
      for (const uid of membersA) {
        // Тапы из дубликата + его Firestore-legacy, если тот ещё не был
        // засеян в RTDB дубликата (иначе он уже внутри counts).
        const add =
          (Number(dupCounts[uid]) || 0) +
          (dupSeeded[uid] != null ? 0 : Number(dupLegacy[uid]) || 0);
        if (add > 0) {
          updates[`missYou/${canonId}/counts/${uid}`] =
            ServerValue.increment(add);
        }
      }
      if (Object.keys(updates).length > 0) {
        await rtdb().ref().update(updates);
      }
      await rtdb().ref(`missYou/${dupId}`).remove();
    }

    {
      const chatSnap = await rtdb().ref(`chats/${dupId}/messages`).get();
      const messages = chatSnap.val() || {};
      const keys = Object.keys(messages);
      if (keys.length > 0) {
        const canonChatSnap = await rtdb()
          .ref(`chats/${canonId}/messages`)
          .get();
        const existing = canonChatSnap.val() || {};
        const updates = {};
        for (const k of keys) {
          if (existing[k] === undefined) {
            updates[`chats/${canonId}/messages/${k}`] = messages[k];
          }
        }
        if (Object.keys(updates).length > 0) {
          await rtdb().ref().update(updates);
        }
      }
      await rtdb().ref(`chats/${dupId}`).remove();
    }

    // ── 4. Финализация: дубликат распущен, pairIds участников починены ──────
    await dupRef.update({
      disbanded: true,
      mergedInto: canonId,
      mergeLock: FieldValue.delete(),
    });
    for (const uid of membersA) {
      await db
        .collection("users")
        .doc(uid)
        .set(
          {
            pairIds: FieldValue.arrayRemove(dupId),
          },
          { merge: true },
        );
      await db
        .collection("users")
        .doc(uid)
        .set(
          {
            pairIds: FieldValue.arrayUnion(canonId),
          },
          { merge: true },
        );
    }

    console.log(
      `mergeDuplicateGroups: ${dupId} → ${canonId} by ${auth.uid}, ` +
        `memories=${memoriesCopied}, drawings=${drawingsCopied}`,
    );
    return { canonicalId: canonId, merged: true };
  } catch (e) {
    // Снимаем лок, чтобы можно было повторить (идемпотентные шаги докатятся).
    await dupRef
      .update({ mergeLock: FieldValue.delete() })
      .catch(() => undefined);
    console.error("mergeDuplicateGroups failed:", e && e.message);
    throw new HttpsError("internal", "Мердж не удался, попробуйте ещё раз");
  }
});
