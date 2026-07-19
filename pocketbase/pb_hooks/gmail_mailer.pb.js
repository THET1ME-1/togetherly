/// Перехват ВСЕХ исходящих писем PocketBase → отправка через Gmail API (этап
/// cutover). Сброс пароля, верификация email и т.п. идут этим путём.
///
/// ЗАЧЕМ: провайдер VPS режет исходящий SMTP (все порты) → штатная отправка PB
/// невозможна. Шлём через Gmail HTTP-API (порт 443 работает). MIME/base64/OAuth
/// делает локальный python-релей (gmail_relay.py, 127.0.0.1:8099) — в JSVM это
/// неудобно/хрупко. Хук лишь POST'ит поля письма на релей.
///
/// onMailerSend срабатывает на КАЖДОЕ письмо. При успехе релея НЕ зовём e.next()
/// → дефолтный SMTP-путь (всё равно заблокирован) не запускается. При сбое —
/// логируем; e.next() тоже не зовём (SMTP мёртв, толку нет).
///
/// ВАЖНО (PB JSVM грабли): всё инлайн, доступны только $app/$http/e.*.

onMailerSend((e) => {
  try {
    const msg = e.message;
    const to = [];
    try {
      const list = msg.to || [];
      for (let i = 0; i < list.length; i++) {
        const a = list[i];
        if (a && a.address) to.push(String(a.address));
      }
    } catch (_) { /* ignore */ }

    if (to.length === 0) {
      try { $app.logger().error("gmail relay: письмо без получателей, пропуск"); } catch (_) {}
      return; // нечего слать
    }

    const payload = {
      to: to,
      subject: String(msg.subject || ""),
      html: String(msg.html || ""),
      text: String(msg.text || ""),
    };

    const resp = $http.send({
      method: "POST",
      url: "http://127.0.0.1:8099/send",
      body: JSON.stringify(payload),
      headers: { "Content-Type": "application/json" },
      timeout: 25,
    });

    if (resp.statusCode === 200) {
      return; // отправлено через Gmail API; дефолтный SMTP НЕ запускаем
    }
    try {
      $app.logger().error("gmail relay non-200: " + resp.statusCode + " " + String(resp.body));
    } catch (_) {}
  } catch (err) {
    try { $app.logger().error("gmail relay failed: " + String(err)); } catch (_) {}
  }
  // НЕ вызываем e.next(): штатный SMTP заблокирован провайдером, смысла нет.
});
