/// Мост миграции паролей Firebase → PocketBase (этап cutover, §8/auth).
///
/// ПРОБЛЕМА: пароли в Firebase = scrypt, в PocketBase = bcrypt. Хеши НЕ
/// переносятся, поэтому у мигрированных юзеров в PB пароля нет → первый вход
/// после обнови падает. Массовый «сброс пароля письмом» при 20k юзеров и
/// заблокированном на VPS SMTP — нежизнеспособен (см. CUTOVER / память).
///
/// РЕШЕНИЕ (ноль писем для основной массы): при первом входе клиент сначала
/// пробует обычный PB-логин; если он падает (пароля в PB ещё нет) — зовёт этот
/// роут. Сервер проверяет email+пароль в Firebase Auth REST (по HTTPS:443 —
/// исходящий SMTP провайдер режет, а 443 работает), и при успехе ЗАПИСЫВАЕТ
/// этот пароль в PB-запись юзера. Клиент повторяет PB-логин — проходит. Дальше
/// юзер целиком на PocketBase, в Firebase больше не ходит.
///
/// БЕЗОПАСНОСТЬ: роут публичный (до-логинный), но пароль ставится ТОЛЬКО если
/// Firebase подтвердил тот же пароль → вызывающий уже знает реальный пароль
/// (т.е. это владелец). Подмена чужого аккаунта невозможна. Перебор гасит сам
/// Firebase (TOO_MANY_ATTEMPTS). Новых аккаунтов в Firebase НЕ создаёт — только
/// читает. Когда Firebase выведут из эксплуатации, роут штатно деградирует в
/// ok:false (клиент покажет обычную ошибку входа), к тому моменту активные уже
/// с PB-паролем, а новые регистрируются прямо в PB.
///
/// ВАЖНО (PB JSVM грабли, см. coins.pb.js): обработчик сериализуется → всё
/// инлайн, доступны только $app/$apis/$http/e.*; тело — e.requestInfo().body.

routerAdd("POST", "/api/migrate/verify-password", (e) => {
  // Firebase Web API key берётся из окружения PocketBase (НЕ хардкодим в
  // публичном репо). Задать: FB_WEB_API_KEY в env процесса pocketbase.
  // Клиентский ключ Firebase формально не секрет, но это ключ проекта — держим
  // его вне кода. Пусто → мост входа через старый Firebase-пароль отключён.
  let FB_KEY = ""; try { FB_KEY = $os.getenv("FB_WEB_API_KEY") || ""; } catch (_) {}
  if (!FB_KEY) {
    return e.json(200, { ok: false, reason: "bridge_disabled" });
  }

  const body = (e.requestInfo().body || {});
  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");
  if (!email || !password) {
    return e.json(400, { ok: false, error: "bad params" });
  }

  // Юзер должен УЖЕ существовать в PB (создан bulk-импортом §8). Нет записи —
  // мост не применим (не мигрированный / опечатка в почте).
  let user;
  try {
    user = $app.findAuthRecordByEmail("users", email);
  } catch (_) {
    return e.json(200, { ok: false, reason: "no_pb_user" });
  }

  // Проверяем пароль в Firebase Auth REST.
  let fbOk = false;
  try {
    const resp = $http.send({
      method: "POST",
      url: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=" + FB_KEY,
      body: JSON.stringify({ email: email, password: password, returnSecureToken: false }),
      headers: { "Content-Type": "application/json" },
      timeout: 20,
    });
    fbOk = (resp.statusCode === 200);
  } catch (err) {
    try { $app.logger().error("migrate bridge: firebase http failed: " + String(err)); } catch (_) {}
    return e.json(200, { ok: false, reason: "fb_unreachable" });
  }

  if (!fbOk) {
    // Неверный пароль ЛИБО Firebase throttling — в обоих случаях не пускаем.
    return e.json(200, { ok: false, reason: "bad_credentials" });
  }

  // Firebase подтвердил пароль → переносим его в PB-запись.
  try {
    user.setPassword(password);
    $app.save(user);
  } catch (err) {
    try { $app.logger().error("migrate bridge: set password failed: " + String(err)); } catch (_) {}
    return e.json(500, { ok: false, error: "set_password_failed" });
  }

  return e.json(200, { ok: true });
});
