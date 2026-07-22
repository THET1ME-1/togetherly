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
  // должно быть — сайт анонимный.
  const guest = "g" + $security.randomString(14);
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
