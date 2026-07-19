/// invite_web.pb.js — веб-часть приглашений на PocketBase-VPS (замена Firebase
/// Hosting, который гасится вместе с проектом Firebase).
///
/// Отдаёт:
///   GET /invite/{code}               → HTML-лендинг: пробует открыть приложение
///                                      (loveapp://invite/CODE), иначе кнопка
///                                      «скачать». Ничего в БД не читает (нет
///                                      энумерации кодов, нулевая нагрузка).
///   GET /.well-known/assetlinks.json → верификация Android App Links для домена
///                                      togetherly.duckdns.org (те же отпечатки,
///                                      что были на Firebase Hosting).
///
/// Деплой: положить файл в /opt/pocketbase/pb_hooks/ на VPS и перезапустить
/// сервис (systemctl restart pocketbase). Только чтение/статика — БД не трогает.

routerAdd("GET", "/invite/{code}", (e) => {
  // JSVM-изоляция: константы объявляем ВНУТРИ хендлера — модульный уровень
  // хендлеру не виден (иначе ReferenceError). DOWNLOAD_URL — куда слать, если
  // приложение не установлено. TODO: заменить на реальную страницу загрузки.
  const DOWNLOAD_URL = "https://github.com/THET1ME-1/togetherly/releases/latest";
  // Санитизация: только буквы/цифры, максимум 12 символов — иначе это не наш
  // код (и защита от reflected-XSS при вставке в HTML/URL).
  // Path-параметр берём из url.path (pathValue роутером этой сборки PB не
  // наполняется): "/invite/CODE" → "CODE".
  const path = String((e.request && e.request.url && e.request.url.path) || "");
  const raw = path.split("/invite/")[1] || "";
  const code = raw.replace(/[^A-Za-z0-9]/g, "").slice(0, 12).toUpperCase();
  const HTML = "text/html; charset=utf-8";
  if (!code) return e.blob(400, HTML, "<h1>Неверная ссылка приглашения</h1>");

  const deep = "loveapp://invite/" + code;
  const html = [
    '<!doctype html><html lang="ru"><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width,initial-scale=1">',
    "<title>Приглашение в Togetherly</title>",
    "<style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#fff5f7;",
    "color:#33202a;display:flex;min-height:100vh;margin:0;align-items:center;justify-content:center;text-align:center}",
    ".card{max-width:340px;padding:28px}.code{font-size:34px;font-weight:800;letter-spacing:8px;color:#e5578a;margin:14px 0}",
    ".btn{display:inline-block;margin-top:18px;padding:14px 26px;border-radius:14px;background:#e5578a;color:#fff;",
    "text-decoration:none;font-weight:700}</style></head><body><div class=\"card\">",
    "<h2>💞 Тебя приглашают в Togetherly</h2>",
    '<p>Код приглашения:</p><div class="code">' + code + "</div>",
    "<p>Открываем приложение…</p>",
    '<a class="btn" href="' + deep + '">Открыть в приложении</a>',
    '<p style="margin-top:22px;font-size:14px">Нет приложения? ',
    '<a href="' + DOWNLOAD_URL + '">Скачать</a>, установить и ввести код выше.</p>',
    "</div><script>setTimeout(function(){location.href=" + JSON.stringify(deep) + "},400);</script>",
    "</body></html>",
  ].join("");
  return e.blob(200, HTML, html);
});

// iOS Universal Links: apple-app-site-association. appID = TeamID.BundleID
// (Y2Z9V86248.com.togetherly.love). Раздаётся как application/json (e.json),
// без extension-файла — content-type тут гарантирован. Работает после того,
// как выйдет iOS-сборка с applinks:togetherly.duckdns.org в entitlements.
routerAdd("GET", "/.well-known/apple-app-site-association", (e) => {
  return e.json(200, {
    applinks: {
      apps: [],
      details: [
        {
          appIDs: ["Y2Z9V86248.com.togetherly.love"],
          appID: "Y2Z9V86248.com.togetherly.love",
          components: [{ "/": "/invite/*", comment: "invite deep links" }],
          paths: ["/invite/*"],
        },
      ],
    },
  });
});

// Android App Links: подтверждение владения доменом. Те же SHA-256 отпечатки
// (upload+play), что раздавались с Firebase Hosting (hosting/.well-known/).
routerAdd("GET", "/.well-known/assetlinks.json", (e) => {
  return e.json(200, [
    {
      relation: [
        "delegate_permission/common.handle_all_urls",
        "delegate_permission/common.get_login_creds",
      ],
      target: {
        namespace: "android_app",
        package_name: "com.togetherly.love",
        sha256_cert_fingerprints: [
          "8F:DF:49:55:24:67:80:B8:AA:96:DF:FC:B8:65:2B:58:EB:E7:7B:E0:42:30:72:9A:72:20:1B:7C:23:B5:FC:C4",
          "1E:94:4F:00:FE:F1:17:D5:00:03:56:03:44:FC:BE:4F:9F:69:BF:FA:4C:F3:5B:A8:9F:26:D0:32:C3:3A:4E:13",
        ],
      },
    },
  ]);
});
