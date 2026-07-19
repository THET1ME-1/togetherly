/// Страж денежных/наградных полей коллекции `users` (миграция §6, закрытие
/// блокера «экономика обходится прямым PATCH»). Поля coins/owned_*/кулдауны/
/// флаги наград ведут ТОЛЬКО серверные коин-роуты (coins.pb.js через $app.save —
/// программный save НЕ проходит через этот request-хук). Любой клиентский
/// PATCH /api/collections/users/records/:id, меняющий защищённое поле, отвергаем.
/// Суперюзер (админка) — пропускается.
///
/// Сравниваем входящее значение с сохранённым в БД: поле, которое клиент НЕ
/// присылает в PATCH, остаётся прежним (== orig) → проходит. Меняется только
/// то, что клиент реально пытается перезаписать.
///
/// ВАЖНО (PB JSVM): обработчик хука сериализуется и исполняется в изолированном
/// пуле — он НЕ видит функции/переменные уровня файла. Поэтому хелпер _deepEqual
/// объявлен ВНУТРИ обработчика (иначе ReferenceError на каждом update → весь
/// PATCH users падает 500). См. coins.pb.js и CUTOVER.md «грабли PB JSVM».

onRecordUpdateRequest((e) => {
  let isSuper = false;
  try {
    isSuper = !!(e.auth && e.auth.collection() && e.auth.collection().name === "_superusers");
  } catch (_) {
    isSuper = false;
  }
  if (!isSuper) {
    // Ownership check: non-superuser can only update their own record.
    if (e.record.id !== e.auth.id) {
      throw new ForbiddenError("cannot update other user's record");
    }
    const PROTECTED = [
      "coins", "owned_themes", "owned_icons", "owned_features", "granted_badges",
      "dev_coins_granted", "ad_rewards_date", "ad_rewards_today",
      "last_daily_bonus_ms", "last_memory_reward_ms",
      "last_daily_bonus_at", "last_memory_reward_at",
      "partner_invite_reward_granted", "partner_invite_rewarded_keys",
      "mood_streak_rewards",
    ];
    // Источник истины — ТЕЛО запроса (как в create-guard ниже). Прежнее
    // сравнение orig.get(f) vs e.record.get(f) давало ЛОЖНЫЙ 403: в PB JSVM
    // .get() на json-полях экономики (owned_*/granted_badges/
    // partner_invite_rewarded_keys/mood_streak_rewards) возвращает БАЙТЫ, не
    // равные сами себе → блокировало даже чистые правки профиля (имя/аватар/
    // пол/настройки/fcm) и роняло денормализацию аватара в группы. Клиент НЕ
    // присылает экономику легально (её ведут серверные коин-роуты через
    // $app.save, мимо этого request-хука), поэтому блокируем лишь реальную
    // попытку клиента записать НЕПУСТОЕ защищённое поле.
    const body = (e.requestInfo().body || {});
    for (let i = 0; i < PROTECTED.length; i++) {
      const f = PROTECTED[i];
      if (!(f in body)) continue; // поле не прислано клиентом — ок
      const v = body[f];
      const empty = (v == null || v === '' || v === 0 || v === false ||
        (Array.isArray(v) && v.length === 0) ||
        (typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === 0));
      if (!empty) {
        throw new ForbiddenError("read-only economy field");
      }
    }
  }

  // ── Денормализация профиля в группы ──────────────────────────────────────
  // При смене аватара/имени синхронизируем member_avatars[uid]/member_names[uid]
  // во ВСЕХ группах юзера. Партнёр читает аватар/имя из group-дока; клиентская
  // правка member_avatars иногда теряется (гонка/проглоченная ошибка), из-за
  // чего партнёр видел СТАРУЮ аватарку. Это серверная гарантия консистентности.
  let prevAvatar = null, prevName = null;
  try {
    const o = $app.findRecordById("users", e.record.id);
    prevAvatar = o.getString("avatar_url");
    prevName = o.getString("display_name");
  } catch (_) { prevAvatar = null; prevName = null; }
  const newAvatar = e.record.getString("avatar_url");
  const newName = e.record.getString("display_name");

  e.next(); // сохраняем users

  if (newAvatar !== prevAvatar || newName !== prevName) {
    try {
      const uid = e.record.id;
      const groups = $app.findRecordsByFilter(
        "groups", "members ~ {:u} && disbanded = false", "", 0, 0, { u: uid });
      for (let i = 0; i < groups.length; i++) {
        const g = groups[i];
        let changed = false;
        let avMap = {};
        try { const v = JSON.parse(g.getString("member_avatars") || "{}"); if (v && typeof v === "object") avMap = v; } catch (_) { avMap = {}; }
        if (newAvatar && avMap[uid] !== newAvatar) { avMap[uid] = newAvatar; g.set("member_avatars", avMap); changed = true; }
        let nmMap = {};
        try { const v = JSON.parse(g.getString("member_names") || "{}"); if (v && typeof v === "object") nmMap = v; } catch (_) { nmMap = {}; }
        if (newName && nmMap[uid] !== newName) { nmMap[uid] = newName; g.set("member_names", nmMap); changed = true; }
        if (changed) $app.save(g);
      }
    } catch (err) {
      try { $app.logger().error("member profile sync failed: " + String(err)); } catch (_) {}
    }
  }
}, "users");

onRecordCreateRequest((e) => {
  let isSuper = false;
  try {
    isSuper = !!(e.auth && e.auth.collection() && e.auth.collection().name === "_superusers");
  } catch (_) {
    isSuper = false;
  }
  if (!isSuper) {
    // ── Чёрный список email (модерация: бан-эвейдеры) ─────────────────────
    // Список — в файле pb_data/.banned_emails, по одному lowercase-email в
    // строке. Читаем на КАЖДУЮ регистрацию (createRequest редок) → новые баны
    // = просто дописать строку в файл, БЕЗ рестарта PB. $os.readFile отдаёт
    // БАЙТЫ → декодируем fromCharCode. Ошибка чтения/нет файла = fail-open
    // (не мешаем легитимной регистрации). Блокирует только повторный signup на
    // тот же email; смена email/oauth — потолок без device-атестации.
    try {
      const bodyEmail = String(((e.requestInfo().body || {}).email) || "").trim().toLowerCase();
      if (bodyEmail) {
        let raw = "";
        try {
          const bytes = $os.readFile("/opt/pocketbase/pb_data/.banned_emails");
          raw = String.fromCharCode.apply(null, bytes);
        } catch (_) { raw = ""; }
        const banned = raw.split("\n").map(function (s) { return s.trim().toLowerCase(); }).filter(Boolean);
        if (banned.indexOf(bodyEmail) !== -1) {
          throw new ForbiddenError("registration blocked");
        }
      }
    } catch (err) {
      if (err instanceof ForbiddenError) throw err; // реальный бан — пробрасываем
      // прочие ошибки (чтение файла и т.п.) — не блокируем регистрацию
    }

    const PROTECTED = [
      "coins", "owned_themes", "owned_icons", "owned_features", "granted_badges",
      "dev_coins_granted", "ad_rewards_date", "ad_rewards_today",
      "last_daily_bonus_ms", "last_memory_reward_ms",
      "last_daily_bonus_at", "last_memory_reward_at",
      "partner_invite_reward_granted", "partner_invite_rewarded_keys",
      "mood_streak_rewards",
    ];
    // Проверяем ТОЛЬКО реально присланные клиентом поля, а не дефолты записи:
    // e.record.get() для json-полей экономики (owned_*/granted_badges/
    // partner_invite_rewarded_keys/mood_streak_rewards) возвращает БАЙТЫ → ложно
    // «непусто» → рубило даже чистую регистрацию (email/пароль/имя). Источник
    // истины — тело запроса; пустые/дефолтные значения разрешаем, блокируем
    // только попытку клиента выставить РЕАЛЬНУЮ экономику.
    const body = (e.requestInfo().body || {});
    for (let i = 0; i < PROTECTED.length; i++) {
      const f = PROTECTED[i];
      if (!(f in body)) continue; // клиент не присылал поле — ок (дефолт схемы)
      const v = body[f];
      const empty = (v == null || v === '' || v === 0 || v === false ||
        (Array.isArray(v) && v.length === 0) ||
        (typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === 0));
      if (!empty) {
        throw new ForbiddenError("read-only economy field");
      }
    }
  }
  e.next();
}, "users");
