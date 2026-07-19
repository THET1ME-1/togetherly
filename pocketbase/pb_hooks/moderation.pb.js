/// Админка модерации (PocketBase JSVM-хук) — замена сайту на Firebase+Supabase.
/// Раздаёт страницу `pb_public/mod-memories.html` + API под shared-secret. 0 Firebase.
///
///   GET /modapi/pb-media     — медиа из `media` (сырой SQL, rowid DESC), отдаёт id+file.
///   GET /modapi/pb-profiles  — профили из `widget_data`.
///   GET /modapi/stats        — активные юзеры + новые регистрации (замена GA).
///   GET /modapi/file         — ПРОКСИ файла: свежий superuser-токен на каждый запрос +
///                              302 на /api/files (фулл по клику не протухает). Гейт ?s=.
///
/// ВАЖНО (PB JSVM): хендлер ИЗОЛИРОВАН — функции уровня файла внутри НЕ видны,
/// поэтому гейт инлайнится в КАЖДЫЙ хендлер (нельзя выносить в общий хелпер!).
/// Чтение через e.requestInfo(). Секрет: env MOD_SECRET → фолбэк pb_data/.mod_secret.

// ── /modapi/file — прокси файла со свежим токеном ─────────────────────────────
routerAdd("GET", "/modapi/file", (e) => {
  const info = e.requestInfo(); const q = info.query || {}; const h = info.headers || {};
  const got = String(q["s"] || h["x_mod_secret"] || h["x-mod-secret"] || q["secret"] || "");
  let want = ""; try { want = $os.getenv("MOD_SECRET") || ""; } catch (_) {}
  if (!want) { try { const b = $os.readFile("/opt/pocketbase/pb_data/.mod_secret"); want = (typeof b === "string" ? b : String.fromCharCode.apply(null, b)).trim(); } catch (_) {} }
  if (!want || got !== want) return e.json(401, { error: "unauthorized" });

  const id = String(q["id"] || "").replace(/[^a-zA-Z0-9_]/g, "");
  const file = String(q["file"] || "");
  const thumb = String(q["thumb"] || "").replace(/[^0-9x]/g, "");
  if (!id || !file) return e.json(400, { error: "bad params" });

  let token = "";
  try { const sus = $app.findRecordsByFilter("_superusers", "id != ''", "", 1, 0); if (sus && sus.length) token = sus[0].newFileToken(); } catch (_) {}
  let target = "/api/files/media/" + id + "/" + encodeURIComponent(file) + "?token=" + token;
  if (thumb) target += "&thumb=" + thumb;
  return e.redirect(302, target);
});

// ── /modapi/pb-media ─────────────────────────────────────────────────────────
routerAdd("GET", "/modapi/pb-media", (e) => {
  const info = e.requestInfo(); const h = info.headers || {}, q = info.query || {};
  const got = String(h["x_mod_secret"] || h["x-mod-secret"] || q["secret"] || "");
  let want = ""; try { want = $os.getenv("MOD_SECRET") || ""; } catch (_) {}
  if (!want) { try { const b = $os.readFile("/opt/pocketbase/pb_data/.mod_secret"); want = (typeof b === "string" ? b : String.fromCharCode.apply(null, b)).trim(); } catch (_) {} }
  if (!want || got !== want) return e.json(401, { error: "unauthorized" });

  const area = String(q["area"] || "memories");
  const groupId = String(q["groupId"] || "").trim();
  let max = parseInt(q["max"] || "60", 10); if (!(max > 0) || max > 200) max = 60;
  let offset = parseInt(q["offset"] || "0", 10); if (!(offset >= 0)) offset = 0;

  const KINDS = {
    memories: ["memory", "memories"], widget: ["widget", "widgets", "canvas"],
    avatars: ["avatar", "avatars"], mascots: ["mascot", "mascots"],
    all: ["memory", "memories", "widget", "widgets", "canvas", "avatar", "avatars", "mascot", "mascots"],
  };
  const kinds = KINDS[area] || KINDS.memories;
  const kindList = kinds.map((k) => "'" + k + "'").join(",");
  let where = "kind IN (" + kindList + ")";
  const params = {};
  if (groupId) { where += " AND group_id = {:gid}"; params.gid = groupId; }
  const isVideo = (f) => /\.(mp4|mov|m4v|webm|avi|mkv|3gp)$/i.test(String(f || ""));

  try {
    const rows = arrayOf(new DynamicModel({ id: "", file: "", group_id: "", kind: "", uid: "" }));
    $app.db().newQuery("SELECT id, file, group_id, kind, uid FROM media WHERE " + where + " ORDER BY rowid DESC LIMIT {:lim} OFFSET {:off}")
      .bind(Object.assign({ lim: max, off: offset }, params)).all(rows);
    const cnt = new DynamicModel({ n: 0 });
    $app.db().newQuery("SELECT COUNT(*) AS n FROM media WHERE " + where).bind(params).one(cnt);
    const items = [];
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (!r.file) continue;
      items.push({ kind: isVideo(r.file) ? "video" : "image", id: r.id, file: r.file, groupId: r.group_id || "", uid: r.uid || "", cat: r.kind || "" });
    }
    const total = cnt.n || 0;
    const nextOffset = (offset + rows.length < total) ? (offset + rows.length) : null;
    return e.json(200, { items: items, total: total, nextOffset: nextOffset });
  } catch (err) { return e.json(500, { error: String(err) }); }
});

// ── /modapi/pb-profiles ──────────────────────────────────────────────────────
routerAdd("GET", "/modapi/pb-profiles", (e) => {
  const info = e.requestInfo(); const h = info.headers || {}, q = info.query || {};
  const got = String(h["x_mod_secret"] || h["x-mod-secret"] || q["secret"] || "");
  let want = ""; try { want = $os.getenv("MOD_SECRET") || ""; } catch (_) {}
  if (!want) { try { const b = $os.readFile("/opt/pocketbase/pb_data/.mod_secret"); want = (typeof b === "string" ? b : String.fromCharCode.apply(null, b)).trim(); } catch (_) {} }
  if (!want || got !== want) return e.json(401, { error: "unauthorized" });

  const groupId = String(q["groupId"] || "").trim();
  let max = parseInt(q["max"] || "60", 10); if (!(max > 0) || max > 200) max = 60;
  let offset = parseInt(q["offset"] || "0", 10); if (!(offset >= 0)) offset = 0;

  const avatarOf = (v) => {
    const s = String(v || "");
    if (s.indexOf("pb://media/") === 0) {
      const rest = s.substring("pb://media/".length);
      const slash = rest.indexOf("/");
      if (slash > 0) return { avatarId: rest.substring(0, slash), avatarFile: rest.substring(slash + 1) };
    }
    if (s.indexOf("http") === 0) return { avatarHttp: s };
    return {};
  };

  let where = "1=1"; const params = {};
  if (groupId) { where = "group_id = {:gid}"; params.gid = groupId; }

  try {
    const rows = arrayOf(new DynamicModel({ group_id: "", user_uid: "", display_name: "", status: "", message: "", mood_label: "", music_title: "", music_artist: "", avatar_url: "", updated: "" }));
    $app.db().newQuery("SELECT group_id, user_uid, display_name, status, message, mood_label, music_title, music_artist, avatar_url, updated FROM widget_data WHERE " + where + " ORDER BY updated DESC LIMIT {:lim} OFFSET {:off}")
      .bind(Object.assign({ lim: max, off: offset }, params)).all(rows);
    const cnt = new DynamicModel({ n: 0 });
    $app.db().newQuery("SELECT COUNT(*) AS n FROM widget_data WHERE " + where).bind(params).one(cnt);
    const items = [];
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      const music = [r.music_title, r.music_artist].filter(Boolean).join(" — ");
      items.push(Object.assign({ kind: "profile", name: r.display_name || "", uid: r.user_uid || "", groupId: r.group_id || "", status: r.status || "", message: r.message || "", moodLabel: r.mood_label || "", music: music, updated: r.updated || "" }, avatarOf(r.avatar_url)));
    }
    const nextOffset = (offset + rows.length < (cnt.n || 0)) ? (offset + rows.length) : null;
    return e.json(200, { items: items, total: cnt.n || 0, nextOffset: nextOffset });
  } catch (err) { return e.json(500, { error: String(err) }); }
});

// ── /modapi/stats — активные пользователи + новые регистрации (замена GA) ──────
routerAdd("GET", "/modapi/stats", (e) => {
  const info = e.requestInfo(); const h = info.headers || {}, q = info.query || {};
  const got = String(h["x_mod_secret"] || h["x-mod-secret"] || q["secret"] || "");
  let want = ""; try { want = $os.getenv("MOD_SECRET") || ""; } catch (_) {}
  if (!want) { try { const b = $os.readFile("/opt/pocketbase/pb_data/.mod_secret"); want = (typeof b === "string" ? b : String.fromCharCode.apply(null, b)).trim(); } catch (_) {} }
  if (!want || got !== want) return e.json(401, { error: "unauthorized" });

  const one = (sql) => { try { const m = new DynamicModel({ n: 0 }); $app.db().newQuery(sql).one(m); return m.n || 0; } catch (_) { return 0; } };
  // members может быть невалидным JSON у части групп → json_array_length бросит и
  // обнулит весь COUNT. Гейтим json_valid, иначе одна битая строка убивает KPI.
  const MEMBERS = "json_array_length(CASE WHEN json_valid(members) THEN members ELSE '[]' END)";
  const VIDEO = "(file LIKE '%.mp4' OR file LIKE '%.mov' OR file LIKE '%.webm' OR file LIKE '%.m4v' OR file LIKE '%.3gp' OR file LIKE '%.avi' OR file LIKE '%.mkv')";
  const out = {
    totalUsers: one("SELECT COUNT(*) AS n FROM users"),
    pairedGroups: one("SELECT COUNT(*) AS n FROM groups WHERE disbanded = false AND " + MEMBERS + " >= 2"),
    soloGroups: one("SELECT COUNT(*) AS n FROM groups WHERE disbanded = false AND " + MEMBERS + " = 1"),
    totalGroups: one("SELECT COUNT(*) AS n FROM groups WHERE disbanded = false"),
    disbanded: one("SELECT COUNT(*) AS n FROM groups WHERE disbanded = true"),
    activeHour: one("SELECT COUNT(*) AS n FROM users WHERE updated >= datetime('now','-1 hours')"),
    dau: one("SELECT COUNT(*) AS n FROM users WHERE updated >= datetime('now','-24 hours')"),
    wau: one("SELECT COUNT(*) AS n FROM users WHERE updated >= datetime('now','-7 days')"),
    mau: one("SELECT COUNT(*) AS n FROM users WHERE updated >= datetime('now','-30 days')"),
    newHour: one("SELECT COUNT(*) AS n FROM users WHERE created >= datetime('now','-1 hours')"),
    newDay: one("SELECT COUNT(*) AS n FROM users WHERE created >= datetime('now','-24 hours')"),
    newWeek: one("SELECT COUNT(*) AS n FROM users WHERE created >= datetime('now','-7 days')"),
    baselineUsers: one("SELECT COUNT(*) AS n FROM users WHERE created < datetime('now','-30 days')"),
    content: {
      memories: one("SELECT COUNT(*) AS n FROM memories"),
      messages: one("SELECT COUNT(*) AS n FROM chat_messages"),
      media: one("SELECT COUNT(*) AS n FROM media"),
      videos: one("SELECT COUNT(*) AS n FROM media WHERE " + VIDEO),
      moods: one("SELECT COUNT(*) AS n FROM mood_entries"),
      missYou: one("SELECT COALESCE(SUM(count),0) AS n FROM miss_you"),
      mascots: one("SELECT COUNT(*) AS n FROM mascots"),
      comments: one("SELECT COUNT(*) AS n FROM memory_comments"),
    },
    daily: [], mediaKinds: [], moods: [], online: null,
  };
  out.content.photos = (out.content.media || 0) - (out.content.videos || 0);
  // Регистрации по дням, 30 дней (для графика роста + накопительной кривой).
  try {
    const drows = arrayOf(new DynamicModel({ d: "", c: 0 }));
    $app.db().newQuery("SELECT substr(created,1,10) AS d, COUNT(*) AS c FROM users WHERE created >= datetime('now','-30 days') GROUP BY d ORDER BY d").all(drows);
    for (let i = 0; i < drows.length; i++) out.daily.push({ d: drows[i].d, c: drows[i].c });
  } catch (_) {}
  // Медиа по типам (Воспоминания/Виджеты/Аватары/Маскоты/Рисунки…).
  try {
    const mk = arrayOf(new DynamicModel({ k: "", c: 0 }));
    $app.db().newQuery("SELECT kind AS k, COUNT(*) AS c FROM media GROUP BY kind ORDER BY c DESC").all(mk);
    for (let i = 0; i < mk.length; i++) out.mediaKinds.push({ k: mk[i].k, c: mk[i].c });
  } catch (_) {}
  // Распределение настроений (top-10 по текущим профилям).
  try {
    const mo = arrayOf(new DynamicModel({ k: "", c: 0 }));
    $app.db().newQuery("SELECT mood_label AS k, COUNT(*) AS c FROM widget_data WHERE mood_label != '' GROUP BY mood_label ORDER BY c DESC LIMIT 10").all(mo);
    for (let i = 0; i < mo.length; i++) out.moods.push({ k: mo[i].k, c: mo[i].c });
  } catch (_) {}
  try {
    let key = "";
    try { const cfg = JSON.parse(String.fromCharCode.apply(null, $os.readFile("/opt/centrifugo/config.json"))); key = (cfg.http_api && cfg.http_api.key) || cfg.api_key || ""; } catch (_) {}
    if (key) {
      const res = $http.send({ url: "http://127.0.0.1:9000/api/info", method: "POST", headers: { "X-API-Key": key, "Content-Type": "application/json" }, body: "{}", timeout: 5 });
      const j = res.json;
      if (j && j.result && j.result.nodes) { let u = 0; for (let i = 0; i < j.result.nodes.length; i++) u += (j.result.nodes[i].num_users || 0); out.online = u; }
    }
  } catch (_) {}
  return e.json(200, out);
});
