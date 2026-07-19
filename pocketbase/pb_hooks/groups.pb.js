/// Серверные АТОМАРНЫЕ операции над группой (миграция §6, закрытие гонок
/// group-RMW DATA-5/6/7/8/9). Клиентский read-modify-write по json-полям группы
/// (member_*, счётчики, стрик, miss_you) терял обновления при одновременной
/// записи с двух устройств: конкурентная запись проходит успешно, ретрай ловит
/// только throw. Здесь RMW выполняется в $app.runInTransaction — PB исполняет
/// транзакции на единственном неконкурентном write-коннекте → параллельные
/// вызовы сериализуются, второй читает уже обновлённое значение. Lost-update
/// исключён.
///
/// ВАЖНО (PB JSVM грабли, см. coins.pb.js / CUTOVER.md):
///  1) обработчик сериализуется и НЕ видит функции уровня файла → все хелперы
///     ИНЛАЙН внутри обработчика;
///  2) json-поле читаем через getString()+JSON.parse (get() = байты); незаданное
///     json → getString даёт "null"/"" → коэрсим в fallback;
///  3) внутри tx — ТОЛЬКО txApp (txApp.findRecordById/save), иначе вне транзакции;
///  4) e.json вызываем ПОСЛЕ коммита (out перехватываем в замыкании).
///
/// Безопасность: $app/txApp обходят API-правила, поэтому КАЖДЫЙ роут сам
/// проверяет членство (e.auth.id ∈ group.members) перед мутацией.
/// Клиент (PbDataService) дёргает эти роуты, при их недоступности откатывается
/// на старый локальный RMW — так что версия-скью клиент/сервер безопасна.

// ── Точечная правка json-словаря группы (member_moods/names/avatars/ailments) ──
// body { groupId, field, uid, value }  value=null → удалить ключ
routerAdd("POST", "/api/group/patch-map", (e) => {
  const body = (e.requestInfo().body || {});
  const groupId = String(body.groupId || "").trim();
  const field = String(body.field || "").trim();
  const uid = String(body.uid || "").trim();
  const ALLOWED = ["member_moods", "member_names", "member_avatars", "member_ailments"];
  if (!groupId || !uid || ALLOWED.indexOf(field) === -1) {
    return e.json(400, { ok: false, error: "bad params" });
  }
  const hasValue = (body.value !== null && body.value !== undefined);
  const value = body.value;
  let out;
  try {
    $app.runInTransaction((txApp) => {
      const g = txApp.findRecordById("groups", groupId);
      const parse = (k, fb) => {
        try { const v = JSON.parse(g.getString(k) || JSON.stringify(fb)); return v == null ? fb : v; }
        catch (_) { return fb; }
      };
      const members = parse("members", []);
      if (members.indexOf(e.auth.id) === -1) { out = { s: 403, b: { ok: false, error: "not a member" } }; return; }
      const map = parse(field, {});
      if (hasValue) { map[uid] = value; } else { delete map[uid]; }
      g.set(field, map);
      txApp.save(g);
      out = { s: 200, b: { ok: true } };
    });
  } catch (err) { return e.json(500, { ok: false, error: "tx failed" }); }
  return e.json(out.s, out.b);
}, $apis.requireAuth());

// ── Атомарный инкремент счётчика группы ───────────────────────────────────────
// body { groupId, field, by }
routerAdd("POST", "/api/group/increment", (e) => {
  const body = (e.requestInfo().body || {});
  const groupId = String(body.groupId || "").trim();
  const field = String(body.field || "").trim();
  const by = Number(body.by);
  // drawings_count теперь ведёт серверный хук counters.pb.js (по canvas_catalogue
  // create/delete). Старые клиенты всё ещё дёргают increment(drawings_count) —
  // гасим в NO-OP с ok:true (клиент считает операцию выполненной и НЕ падает в
  // локальный RMW), иначе счётчик задвоился бы с хуком.
  if (field === "drawings_count") {
    return e.json(200, { ok: true, value: 0, noop: true });
  }
  const ALLOWED = ["memories_count", "xp"];
  if (!groupId || ALLOWED.indexOf(field) === -1 || !Number.isFinite(by)) {
    return e.json(400, { ok: false, error: "bad params" });
  }
  let out;
  try {
    $app.runInTransaction((txApp) => {
      const g = txApp.findRecordById("groups", groupId);
      let members = [];
      try { members = JSON.parse(g.getString("members") || "[]") || []; } catch (_) { members = []; }
      if (members.indexOf(e.auth.id) === -1) { out = { s: 403, b: { ok: false, error: "not a member" } }; return; }
      const next = (g.getInt(field) || 0) + by;
      g.set(field, next);
      txApp.save(g);
      out = { s: 200, b: { ok: true, value: next } };
    });
  } catch (err) { return e.json(500, { ok: false, error: "tx failed" }); }
  return e.json(out.s, out.b);
}, $apis.requireAuth());

// ── Выход участника из группы (members + member_* + disband если пусто) ────────
// body { groupId, uid }
routerAdd("POST", "/api/group/leave", (e) => {
  const body = (e.requestInfo().body || {});
  const groupId = String(body.groupId || "").trim();
  const uid = String(body.uid || "").trim();
  if (!groupId || !uid) return e.json(400, { ok: false, error: "bad params" });
  let out;
  try {
    $app.runInTransaction((txApp) => {
      const g = txApp.findRecordById("groups", groupId);
      const parse = (k, fb) => {
        try { const v = JSON.parse(g.getString(k) || JSON.stringify(fb)); return v == null ? fb : v; }
        catch (_) { return fb; }
      };
      let members = parse("members", []);
      if (members.indexOf(e.auth.id) === -1) { out = { s: 403, b: { ok: false, error: "not a member" } }; return; }
      members = members.filter((m) => m !== uid);
      const names = parse("member_names", {}); delete names[uid];
      const avatars = parse("member_avatars", {}); delete avatars[uid];
      const moods = parse("member_moods", {}); delete moods[uid];
      const ailments = parse("member_ailments", {}); delete ailments[uid];
      g.set("members", members);
      g.set("member_names", names);
      g.set("member_avatars", avatars);
      g.set("member_moods", moods);
      g.set("member_ailments", ailments);
      if (members.length === 0) {
        g.set("disbanded", true);
        g.set("disbanded_at", new Date().toISOString());
      }
      txApp.save(g);
      out = { s: 200, b: { ok: true } };
    });
  } catch (err) { return e.json(500, { ok: false, error: "tx failed" }); }
  return e.json(out.s, out.b);
}, $apis.requireAuth());

// ── Засчитать дневную активность (стрик растёт когда зашли ОБА) ────────────────
// body { groupId, uid, today }  today = "YYYY-MM-DD" (локальная дата клиента —
// сохраняем семантику старого клиента; атомарность добавляет транзакция).
routerAdd("POST", "/api/group/record-activity", (e) => {
  const body = (e.requestInfo().body || {});
  const groupId = String(body.groupId || "").trim();
  const uid = String(body.uid || "").trim();
  const today = String(body.today || "").trim();
  if (!groupId || !uid || !/^\d{4}-\d{2}-\d{2}$/.test(today)) {
    return e.json(400, { ok: false, error: "bad params" });
  }
  let out;
  try {
    $app.runInTransaction((txApp) => {
      const nz = (v) => { const s = v == null ? "" : String(v); return s.length ? s : null; };
      const g = txApp.findRecordById("groups", groupId);
      let members = [];
      try { members = JSON.parse(g.getString("members") || "[]") || []; } catch (_) { members = []; }
      if (members.indexOf(e.auth.id) === -1) { out = { s: 403, b: { ok: false, error: "not a member" } }; return; }
      const last = nz(g.getString("streak_last_opened_date"));
      if (last === today) { out = { s: 200, b: { ok: true, already: true } }; return; }
      const pendUid = nz(g.getString("streak_pending_uid"));
      const pendDate = nz(g.getString("streak_pending_date"));
      const bothPresent = pendDate === today && pendUid != null && pendUid !== uid;
      if (bothPresent) {
        const isConsecutive = (prevDay) => {
          if (!prevDay) return false;
          const a = Date.parse(today + "T00:00:00Z");
          const b = Date.parse(prevDay + "T00:00:00Z");
          return !isNaN(a) && !isNaN(b) && Math.round((a - b) / 86400000) === 1;
        };
        // Парная серия (back-compat): оставляем, но отображение теперь per-mascot.
        const pairStreak = isConsecutive(last) ? (g.getInt("streak_days") || 0) + 1 : 1;
        g.set("streak_days", pairStreak);
        g.set("streak_last_opened_date", today);

        // PER-MASCOT серия: привязана к активному маскоту, считается по ЕГО
        // собственной последней дате общего дня. Пропуск → старт с 1 («умер»).
        const activeMascotId = nz(g.getString("active_mascot_id"));
        let mStreak = 0;
        if (activeMascotId) {
          let map = {};
          try { const v = JSON.parse(g.getString("mascot_streaks") || "{}"); if (v && typeof v === "object") map = v; } catch (_) { map = {}; }
          const prev = (map[activeMascotId] && typeof map[activeMascotId] === "object") ? map[activeMascotId] : {};
          const prevS = Number(prev.s) || 0;
          mStreak = isConsecutive(nz(prev.d)) ? prevS + 1 : 1;
          map[activeMascotId] = { s: mStreak, d: today };
          g.set("mascot_streaks", map);
        }
        txApp.save(g);

        // record_streak (рекорд per-mascot) — только для персистентных маскотов.
        if (activeMascotId) {
          try {
            const mascot = txApp.findFirstRecordByFilter(
              "mascots", "group_id = {:g} && mascot_id = {:m}", { g: groupId, m: activeMascotId });
            if ((mascot.getInt("record_streak") || 0) < mStreak) {
              mascot.set("record_streak", mStreak);
              txApp.save(mascot);
            }
          } catch (_) { /* каталожный/нет записи — ок */ }
        }
        out = { s: 200, b: { ok: true, streak: pairStreak, mascotStreak: mStreak } };
        return;
      }
      if (pendDate !== today || pendUid == null) {
        g.set("streak_pending_date", today);
        g.set("streak_pending_uid", uid);
        txApp.save(g);
      }
      out = { s: 200, b: { ok: true, pending: true } };
    });
  } catch (err) { return e.json(500, { ok: false, error: "tx failed" }); }
  return e.json(out.s, out.b);
}, $apis.requireAuth());

// ── Атомарный инкремент «Я скучаю» (запись miss_you по group_id+user_uid) ──────
// body { groupId, uid, vibe, text }
routerAdd("POST", "/api/group/miss-you", (e) => {
  const body = (e.requestInfo().body || {});
  const groupId = String(body.groupId || "").trim();
  const uid = String(body.uid || "").trim();
  const vibe = String(body.vibe || "miss_you");
  const text = String(body.text || "");
  if (!groupId || !uid) return e.json(400, { ok: false, error: "bad params" });
  let out;
  try {
    $app.runInTransaction((txApp) => {
      // членство по группе
      let members = [];
      try {
        const g = txApp.findRecordById("groups", groupId);
        members = JSON.parse(g.getString("members") || "[]") || [];
      } catch (_) { members = []; }
      if (members.indexOf(e.auth.id) === -1) { out = { s: 403, b: { ok: false, error: "not a member" } }; return; }
      const nowIso = new Date().toISOString();
      let rec = null;
      try {
        rec = txApp.findFirstRecordByFilter(
          "miss_you", "group_id = {:g} && user_uid = {:u}", { g: groupId, u: uid });
      } catch (_) { rec = null; }
      if (rec) {
        const next = (rec.getInt("count") || 0) + 1;
        rec.set("count", next);
        rec.set("updated_at", nowIso);
        rec.set("last_vibe", vibe);
        rec.set("last_vibe_text", text);
        txApp.save(rec);
        out = { s: 200, b: { ok: true, count: next } };
      } else {
        const col = txApp.findCollectionByNameOrId("miss_you");
        const r = new Record(col);
        r.set("group_id", groupId);
        r.set("user_uid", uid);
        r.set("count", 1);
        r.set("updated_at", nowIso);
        r.set("last_vibe", vibe);
        r.set("last_vibe_text", text);
        txApp.save(r);
        out = { s: 200, b: { ok: true, count: 1 } };
      }
    });
  } catch (err) { return e.json(500, { ok: false, error: "tx failed" }); }
  return e.json(out.s, out.b);
}, $apis.requireAuth());
