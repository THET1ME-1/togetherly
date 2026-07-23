/// Комнаты совместного просмотра (сайт togetherly.day/watch).
///
/// Сервер не хранит ничего: ни комнат, ни ссылок на видео, ни переписки.
/// Комната — это канал `watch:<id>` в Centrifugo, который живёт, пока в нём
/// есть хоть одно соединение. История канала выключена, на диск не пишется.
///
/// Вход анонимный: на сайте у людей нет аккаунтов. Пропуск выдаётся на шесть
/// часов и привязан к конкретной комнате — по нему нельзя подключиться ни к
/// каналу пары, ни к чужой комнате.
///
/// !!! ГРАБЛИ PB JSVM (см. coins.pb.js:5-19): обработчик исполняется в
/// ИЗОЛИРОВАННОМ пуле и НЕ видит функции уровня файла — всё инлайнится.

/// Код комнаты пары. Приложению не нужно ничего вводить: оба устройства
/// спрашивают код у сервера и молча оказываются в одной комнате. Тот же код
/// показывается в интерфейсе, чтобы позвать партнёра в браузер.
///
/// Код выводится из group_id через HMAC с серверным секретом: одинаковый для
/// пары, неугадываемый снаружи и не раскрывающий сам идентификатор группы.
routerAdd("POST", "/api/watch/room", (e) => {
  const auth = e.auth;
  if (!auth) return e.json(401, { ok: false, error: "unauthorized" });

  const body = e.requestInfo().body || {};
  const groupId = String(body.groupId || "");
  if (!groupId) return e.json(400, { ok: false, error: "no_group" });

  // Участие проверяем по users.group_ids — так же, как в правилах коллекций.
  const mine = auth.get("group_ids") || [];
  let member = false;
  for (let i = 0; i < mine.length; i++) {
    if (String(mine[i]) === groupId) { member = true; break; }
  }
  if (!member) return e.json(403, { ok: false, error: "not_member" });

  const secret = $os.getenv("CENTRIFUGO_TOKEN_HMAC");
  if (!secret) return e.json(500, { ok: false, error: "not_configured" });

  // Без похожих на глаз символов: код диктуют голосом и переписывают руками.
  const abc = "abcdefghjkmnpqrstuvwxyz23456789";
  const digest = $security.hs256(groupId, secret);
  let room = "";
  for (let i = 0; i < 8; i++) {
    room += abc[digest.charCodeAt(i) % abc.length];
  }

  return e.json(200, { ok: true, room: room });
});

routerAdd("POST", "/api/watch/token", (e) => {
  const TTL = 6 * 60 * 60; // пропуск на вечер, дольше комнате не нужно

  const body = e.requestInfo().body || {};
  const room = String(body.room || "").toLowerCase().replace(/[^a-z0-9]/g, "");

  // Имя комнаты придумывает клиент, поэтому проверяем форму: короткое
  // и только буквы с цифрами. Иначе через имя канала можно было бы уехать
  // в чужое пространство имён.
  if (room.length < 4 || room.length > 12) {
    return e.json(400, { ok: false, error: "bad_room" });
  }

  const secret = $os.getenv("CENTRIFUGO_TOKEN_HMAC");
  if (!secret) return e.json(500, { ok: false, error: "not_configured" });

  // Гостю выдаём случайное имя: постоянного идентификатора у него нет и не
  // должно быть — сайт анонимный. Своё прежнее имя браузер присылает обратно,
  // иначе перезагрузка вкладки выглядела бы приходом второго зрителя.
  const asked = String(body.guest || "");
  const guest = /^g[a-z0-9]{14}$/.test(asked) ? asked : "g" + $security.randomString(14);
  const channel = "watch:" + room;

  return e.json(200, {
    ok: true,
    userId: guest,
    channel: channel,
    // Пропуск на соединение и отдельный — на конкретный канал.
    connectionToken: $security.createJWT({ sub: guest }, secret, TTL),
    subscriptionToken: $security.createJWT(
      { sub: guest, channel: channel }, secret, TTL),
  });
});
