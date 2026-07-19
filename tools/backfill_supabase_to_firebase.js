// Бэкфилл Supabase → Firebase для пар, у которых под Stage 4 запись в Firebase
// была отключена (данные ушли только в Supabase). АДДИТИВНЫЙ и БЕЗОПАСНЫЙ:
//   • create-only типы пишут в Firebase ТОЛЬКО записи, которых там НЕТ
//     (precondition exists:false на каждом write → затереть существующий свежий
//     Firebase невозможно);
//   • групповые поля (тип `group`) — merge ТОЛЬКО отсутствующих полей верхнего
//     уровня (updateMask + currentDocument.exists=true): существующее поле в
//     Firebase НИКОГДА не перезаписывается;
//   • удалённые в Supabase (deleted=true) НЕ воскрешает (где есть колонка deleted);
//   • DRY-RUN по умолчанию — без --commit ничего не пишет, только считает.
//
// Чат (chat_messages/chat_reads) НЕ бэкфиллится: история чата живёт в RTDB, не в
// Firestore (Firestore-док чата был лишь триггером пуша и сразу удаляется).
//
// Доступ:
//   • Firebase — owner refresh_token из firebase CLI configstore (как admin_groups.js).
//   • Supabase — service-role ключ из переменной окружения SBKEY (в файлы НЕ писать).
//
// Использование (TYPE = memories|comments|moods|strokes|canvasMeta|canvasCatalogue|widget|group|all):
//   SBKEY=... node tools/backfill_supabase_to_firebase.js all              # dry-run, все типы, все stage4-группы
//   SBKEY=... node tools/backfill_supabase_to_firebase.js memories         # dry-run, один тип
//   SBKEY=... node tools/backfill_supabase_to_firebase.js all --group GID  # одна группа
//   SBKEY=... node tools/backfill_supabase_to_firebase.js all --limit 20   # первые 20 групп
//   SBKEY=... node tools/backfill_supabase_to_firebase.js all --commit     # БОЕВОЙ прогон (пишет)

const fs = require("fs");
const os = require("os");
const https = require("https");

const PROJECT = "togetherly-d4856";
const FS_HOST = "firestore.googleapis.com";
const FS_BASE = `/v1/projects/${PROJECT}/databases/(default)/documents`;
const CID =
  "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com";
const CSEC = "j9iVZfS8kkCEFUPaAeJV0sAi";
const FRESH_DAYS = 21;

const SB_HOST = "xxjlzzkhrvyiqaexvymx.supabase.co";
const SBKEY = process.env.SBKEY || process.env.SUPABASE_SERVICE_ROLE_KEY || "";

const args = process.argv.slice(2);
const TYPE = args[0];
const COMMIT = args.includes("--commit");
const onlyGroup = (() => {
  const i = args.indexOf("--group");
  return i >= 0 ? args[i + 1] : null;
})();
const limitGroups = (() => {
  const i = args.indexOf("--limit");
  return i >= 0 ? parseInt(args[i + 1], 10) : null;
})();

function req(method, host, path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const data =
      body == null ? null : typeof body === "string" ? body : JSON.stringify(body);
    const h = Object.assign({}, headers);
    if (data != null) h["Content-Length"] = Buffer.byteLength(data);
    const r = https.request({ host, path, method, headers: h }, (resp) => {
      let d = "";
      resp.on("data", (c) => (d += c));
      resp.on("end", () => resolve({ status: resp.statusCode, body: d }));
    });
    r.on("error", reject);
    if (data != null) r.write(data);
    r.end();
  });
}

async function getToken() {
  const f = os.homedir() + "/.config/configstore/firebase-tools.json";
  const j = JSON.parse(fs.readFileSync(f, "utf8"));
  if (!j.tokens || !j.tokens.refresh_token) throw new Error("Нет refresh_token — `firebase login`.");
  const form =
    "client_id=" + encodeURIComponent(CID) +
    "&client_secret=" + encodeURIComponent(CSEC) +
    "&refresh_token=" + encodeURIComponent(j.tokens.refresh_token) +
    "&grant_type=refresh_token";
  const tk = await req("POST", "oauth2.googleapis.com", "/token", form, {
    "Content-Type": "application/x-www-form-urlencoded",
  });
  if (tk.status !== 200) throw new Error("refresh_token обмен не удался: " + tk.body.slice(0, 200));
  return { token: JSON.parse(tk.body).access_token, email: (j.user && j.user.email) || "?" };
}

function fbHeaders(token, json = true) {
  const h = { Authorization: "Bearer " + token, "x-goog-user-project": PROJECT };
  if (json) h["Content-Type"] = "application/json";
  return h;
}
function sbHeaders() {
  return { apikey: SBKEY, Authorization: "Bearer " + SBKEY, "Content-Type": "application/json" };
}

// ── Firestore value helpers ──
function fv(field) {
  if (!field) return undefined;
  if ("stringValue" in field) return field.stringValue;
  if ("booleanValue" in field) return field.booleanValue;
  if ("integerValue" in field) return Number(field.integerValue);
  if ("doubleValue" in field) return field.doubleValue;
  if ("timestampValue" in field) return field.timestampValue;
  if ("nullValue" in field) return null;
  if ("arrayValue" in field) return (field.arrayValue.values || []).map(fv);
  if ("mapValue" in field) {
    const out = {};
    const fields = field.mapValue.fields || {};
    for (const k of Object.keys(fields)) out[k] = fv(fields[k]);
    return out;
  }
  return undefined;
}

// Ключи, которые в Firestore — Timestamp (в Supabase лежат ISO-строками).
const TS_KEYS = new Set(["createdAt", "editedAt", "timestamp", "updatedAt"]);
function toFs(v, key) {
  if (v === null || v === undefined) return { nullValue: null };
  if (TS_KEYS.has(key) && typeof v === "string") {
    const d = Date.parse(v);
    if (!isNaN(d)) return { timestampValue: new Date(d).toISOString() };
  }
  if (typeof v === "boolean") return { booleanValue: v };
  if (typeof v === "number")
    return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === "string") return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map((e) => toFs(e)) } };
  if (typeof v === "object") {
    const fields = {};
    for (const k of Object.keys(v)) fields[k] = toFs(v[k], k);
    return { mapValue: { fields } };
  }
  return { stringValue: String(v) };
}
function toFsFields(map) {
  const fields = {};
  for (const k of Object.keys(map)) fields[k] = toFs(map[k], k);
  return fields;
}

// Выкинуть null/undefined верхнего уровня (как делают mirror*-методы в приложении).
function clean(obj) {
  const o = {};
  for (const k of Object.keys(obj)) if (obj[k] !== null && obj[k] !== undefined) o[k] = obj[k];
  return o;
}

// ── stage4 group discovery (same logic as backfill_scope.js) ──
async function scanStage4Groups(token) {
  const docs = [];
  let cursorName = null;
  for (;;) {
    const sq = {
      structuredQuery: {
        from: [{ collectionId: "groups" }],
        select: { fields: [{ fieldPath: "members" }, { fieldPath: "sbRead" }, { fieldPath: "disbanded" }] },
        orderBy: [{ field: { fieldPath: "__name__" }, direction: "ASCENDING" }],
        limit: 1000,
      },
    };
    if (cursorName) sq.structuredQuery.startAt = { before: false, values: [{ referenceValue: cursorName }] };
    const r = await req("POST", FS_HOST, `${FS_BASE}:runQuery`, sq, fbHeaders(token));
    if (r.status !== 200) throw new Error(`scan runQuery ${r.status}: ${r.body.slice(0, 200)}`);
    const rows = JSON.parse(r.body).filter((x) => x.document);
    if (!rows.length) break;
    for (const x of rows) docs.push(x.document);
    cursorName = rows[rows.length - 1].document.name;
    if (rows.length < 1000) break;
  }
  const nowMs = Date.now();
  const out = [];
  for (const doc of docs) {
    const f = doc.fields || {};
    if (fv(f.disbanded) === true) continue;
    const members = (fv(f.members) || []).filter((s) => s);
    const sbRead = fv(f.sbRead) || {};
    if (!members.length) continue;
    let allFresh = true;
    for (const m of members) {
      const ts = sbRead[m];
      const dt = ts ? Date.parse(ts) : NaN;
      if (isNaN(dt) || (nowMs - dt) / 86400000 > FRESH_DAYS) { allFresh = false; break; }
    }
    if (allFresh) out.push(doc.name.split("/").pop());
  }
  return out;
}

// ── Supabase: все строки таблицы по группе (постранично) ──
// hasDeleted=false для таблиц без колонки deleted (canvas_meta/catalogue/widget_data).
async function sbRows(table, gid, select, hasDeleted = true) {
  const out = [];
  const PAGE = 1000;
  for (let from = 0; ; from += PAGE) {
    const path =
      `/rest/v1/${table}?group_id=eq.${encodeURIComponent(gid)}` +
      (hasDeleted ? `&deleted=eq.false` : ``) +
      `&select=${encodeURIComponent(select)}`;
    const r = await req("GET", SB_HOST, path, null, {
      ...sbHeaders(),
      Range: `${from}-${from + PAGE - 1}`,
      "Range-Unit": "items",
    });
    if (r.status !== 200 && r.status !== 206) throw new Error(`SB ${table} ${r.status}: ${r.body.slice(0, 200)}`);
    const rows = JSON.parse(r.body);
    out.push(...rows);
    if (rows.length < PAGE) break;
  }
  return out;
}

// ── Supabase: одна строка таблицы groups ──
async function sbGroupRow(gid, select) {
  const path = `/rest/v1/groups?id=eq.${encodeURIComponent(gid)}&select=${encodeURIComponent(select)}`;
  const r = await req("GET", SB_HOST, path, null, sbHeaders());
  if (r.status !== 200) throw new Error(`SB groups ${r.status}: ${r.body.slice(0, 200)}`);
  const rows = JSON.parse(r.body);
  return rows[0] || null;
}

// ── Firebase: id существующих доков (sub под parentRel; deep=true → collection-group) ──
async function fbExistingIds(token, parentRel, sub, deep = false) {
  const ids = new Set();
  const sq = {
    structuredQuery: {
      from: [{ collectionId: sub, ...(deep ? { allDescendants: true } : {}) }],
      select: { fields: [{ fieldPath: "__name__" }] },
      limit: 20000,
    },
  };
  const r = await req("POST", FS_HOST, `${FS_BASE}/${parentRel}:runQuery`, sq, fbHeaders(token));
  if (r.status !== 200) throw new Error(`FB existing ${sub} ${r.status}: ${r.body.slice(0, 200)}`);
  for (const x of JSON.parse(r.body)) {
    if (x.document) ids.add(x.document.name.split("/").pop());
  }
  return ids;
}

// ── Firebase: получить один документ (или null если 404) ──
async function fbGetDoc(token, rel) {
  const r = await req("GET", FS_HOST, `${FS_BASE}/${rel}`, null, fbHeaders(token, false));
  if (r.status === 404) return null;
  if (r.status !== 200) throw new Error(`FB get ${rel} ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

// ── Firebase: commit пачки create-only writes (exists:false) ──
async function fbCommitCreate(token, writes) {
  for (let i = 0; i < writes.length; i += 400) {
    const batch = writes.slice(i, i + 400);
    const r = await req("POST", FS_HOST, `${FS_BASE}:commit`, { writes: batch }, fbHeaders(token));
    if (r.status !== 200) throw new Error(`commit ${r.status}: ${r.body.slice(0, 300)}`);
  }
}

// ── Firebase: PATCH только указанных полей существующего дока (merge без перезаписи) ──
async function fbPatchFields(token, rel, fieldsMap) {
  const mask = Object.keys(fieldsMap)
    .map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`)
    .join("&");
  const path = `${FS_BASE}/${rel}?${mask}&currentDocument.exists=true`;
  const r = await req("PATCH", FS_HOST, path, { fields: toFsFields(fieldsMap) }, fbHeaders(token));
  if (r.status !== 200) throw new Error(`patch ${rel} ${r.status}: ${r.body.slice(0, 300)}`);
}

// ── Firebase: дописать ключи в map-поле `entries` month-дока (merge без перезаписи) ──
// maskPaths — список вида entries.`<id>`; создаёт док если его нет, иначе мержит
// только перечисленные ключи (остальные записи месяца не трогает).
async function fbPatchMonthEntries(token, rel, entFields, maskPaths) {
  const mask = maskPaths.map((p) => `updateMask.fieldPaths=${encodeURIComponent(p)}`).join("&");
  const path = `${FS_BASE}/${rel}?${mask}`;
  const body = { fields: { entries: { mapValue: { fields: entFields } } } };
  const r = await req("PATCH", FS_HOST, path, body, fbHeaders(token));
  if (r.status !== 200) throw new Error(`patch month ${rel} ${r.status}: ${r.body.slice(0, 300)}`);
}

// Собрать create-only writes из (id → fields-map) и опционально закоммитить.
async function commitCreateOnly(token, items) {
  // Дедуп по пути: в Supabase бывают дубликаты id → один и тот же док дважды в
  // commit-батче = 400 "Cannot insert then insert an entity in the same request".
  const seen = new Set();
  items = items.filter((it) => (seen.has(it.path) ? false : (seen.add(it.path), true)));
  const writes = items.map((it) => ({
    update: {
      name: `projects/${PROJECT}/databases/(default)/documents/${it.path}`,
      fields: toFsFields(it.fields),
    },
    currentDocument: { exists: false },
  }));
  if (COMMIT && writes.length) await fbCommitCreate(token, writes);
  return writes.length;
}

// ── MEMORIES ── groups/{gid}/memories/{id} (data jsonb)
async function backfillMemories(token, gid) {
  const rows = await sbRows("memories", gid, "id,data");
  const existing = await fbExistingIds(token, `groups/${gid}`, "memories");
  const missing = rows.filter((r) => r.id && !existing.has(r.id) && r.data);
  const add = await commitCreateOnly(
    token,
    missing.map((r) => ({ path: `groups/${gid}/memories/${r.id}`, fields: r.data }))
  );
  return { sb: rows.length, fb: existing.size, add };
}

// ── COMMENTS ── groups/{gid}/memories/{memoryId}/comments/{id}
async function backfillComments(token, gid) {
  const rows = await sbRows(
    "memory_comments",
    gid,
    "id,memory_id,author_uid,author_name,author_avatar,text,created_at"
  );
  const existing = await fbExistingIds(token, `groups/${gid}`, "comments", true);
  const missing = rows.filter((r) => r.id && r.memory_id && !existing.has(r.id));
  const add = await commitCreateOnly(
    token,
    missing.map((r) => ({
      path: `groups/${gid}/memories/${r.memory_id}/comments/${r.id}`,
      fields: clean({
        authorUid: r.author_uid,
        authorName: r.author_name,
        authorAvatar: r.author_avatar,
        text: r.text,
        createdAt: r.created_at,
      }),
    }))
  );
  return { sb: rows.length, fb: existing.size, add };
}

// ── MOODS ── v2 month-документы: groups/{gid}/moodCalendar/{uid}/months/{YYYY-MM}
// с map-полем entries.{id}. Это КАНОН чтения приложения (loadMoodMonths); legacy
// entries/{id} читают только старые версии — туда долив бессмыслен. Дописываем
// только отсутствующие id в map, существующие записи месяца не трогаем.
async function backfillMoods(token, gid) {
  const rows = await sbRows("mood_entries", gid, "id,user_uid,mood_id,image_path,label,timestamp", false);
  // uid → monthKey(YYYY-MM) → [rows]
  const byUidMonth = {};
  for (const r of rows) {
    if (!r.id || !r.user_uid || !r.timestamp) continue;
    const mk = String(r.timestamp).slice(0, 7);
    ((byUidMonth[r.user_uid] ??= {})[mk] ??= []).push(r);
  }
  let add = 0;
  for (const uid of Object.keys(byUidMonth)) {
    for (const mk of Object.keys(byUidMonth[uid])) {
      const monthRows = byUidMonth[uid][mk];
      const rel = `groups/${gid}/moodCalendar/${uid}/months/${mk}`;
      const doc = await fbGetDoc(token, rel);
      const existing =
        (doc && doc.fields && doc.fields.entries && doc.fields.entries.mapValue &&
          doc.fields.entries.mapValue.fields) || {};
      const missing = monthRows.filter((r) => !(r.id in existing));
      if (!missing.length) continue;
      add += missing.length;
      if (COMMIT) {
        const entFields = {};
        const maskPaths = [];
        for (const r of missing) {
          entFields[r.id] = toFs(
            clean({ id: r.id, moodId: r.mood_id, imagePath: r.image_path, label: r.label, timestamp: r.timestamp })
          );
          maskPaths.push("entries.`" + r.id + "`");
        }
        await fbPatchMonthEntries(token, rel, entFields, maskPaths);
      }
    }
  }
  return { sb: rows.length, fb: 0, add };
}

// ── CANVAS STROKES ── groups/{gid}/canvas/{canvasId}/strokes/{id} (data jsonb)
async function backfillStrokes(token, gid) {
  const rows = await sbRows("canvas_strokes", gid, "id,canvas_id,order_index,data");
  const existing = await fbExistingIds(token, `groups/${gid}`, "strokes", true);
  const missing = rows.filter((r) => r.id && r.canvas_id && !existing.has(r.id) && r.data);
  const add = await commitCreateOnly(
    token,
    missing.map((r) => {
      const data = { ...r.data };
      if (data.orderIndex == null && r.order_index != null) data.orderIndex = r.order_index;
      return { path: `groups/${gid}/canvas/${r.canvas_id}/strokes/${r.id}`, fields: data };
    })
  );
  return { sb: rows.length, fb: existing.size, add };
}

// ── CANVAS META ── groups/{gid}/canvas/{canvasId} (сам документ; create-only)
async function backfillCanvasMeta(token, gid) {
  const rows = await sbRows("canvas_meta", gid, "canvas_id,bg_color,canvas_rotation,clear_version", false);
  const existing = await fbExistingIds(token, `groups/${gid}`, "canvas");
  const missing = rows.filter((r) => r.canvas_id && !existing.has(r.canvas_id));
  const add = await commitCreateOnly(
    token,
    missing.map((r) => ({
      path: `groups/${gid}/canvas/${r.canvas_id}`,
      fields: clean({
        bgColor: r.bg_color,
        canvasRotation: r.canvas_rotation,
        clearVersion: r.clear_version,
      }),
    }))
  );
  return { sb: rows.length, fb: existing.size, add };
}

// ── CANVAS CATALOGUE ── groups/{gid}/canvasCatalogue/{canvasId}
async function backfillCanvasCatalogue(token, gid) {
  const rows = await sbRows("canvas_catalogue", gid, "canvas_id,name,created_at,updated_at,created_by", false);
  const existing = await fbExistingIds(token, `groups/${gid}`, "canvasCatalogue");
  const missing = rows.filter((r) => r.canvas_id && !existing.has(r.canvas_id));
  const add = await commitCreateOnly(
    token,
    missing.map((r) => ({
      path: `groups/${gid}/canvasCatalogue/${r.canvas_id}`,
      fields: clean({
        name: r.name,
        createdAt: r.created_at,
        updatedAt: r.updated_at,
        createdBy: r.created_by,
      }),
    }))
  );
  return { sb: rows.length, fb: existing.size, add };
}

// ── WIDGET DATA ── groups/{gid}/widgetData/{uid}
async function backfillWidget(token, gid) {
  const rows = await sbRows(
    "widget_data",
    gid,
    "user_uid,display_name,avatar_url,gender,status,mood_emoji,mood_label,message," +
      "music_title,music_artist,music_url,music_cover_url,photo_url,photo_for_partner_url," +
      "photo_for_partner_urls,photo_grid_count,photo_grid_urls,updated_at",
    false
  );
  const existing = await fbExistingIds(token, `groups/${gid}`, "widgetData");
  const missing = rows.filter((r) => r.user_uid && !existing.has(r.user_uid));
  const add = await commitCreateOnly(
    token,
    missing.map((r) => ({
      path: `groups/${gid}/widgetData/${r.user_uid}`,
      fields: clean({
        uid: r.user_uid,
        displayName: r.display_name,
        avatarUrl: r.avatar_url,
        gender: r.gender,
        status: r.status,
        moodEmoji: r.mood_emoji,
        moodLabel: r.mood_label,
        message: r.message,
        musicTitle: r.music_title,
        musicArtist: r.music_artist,
        musicUrl: r.music_url,
        musicCoverUrl: r.music_cover_url,
        photoUrl: r.photo_url,
        photoForPartnerUrl: r.photo_for_partner_url,
        photoForPartnerUrls: r.photo_for_partner_urls,
        photoGridCount: r.photo_grid_count,
        photoGridUrls: r.photo_grid_urls,
        updatedAt: r.updated_at,
      }),
    }))
  );
  return { sb: rows.length, fb: existing.size, add };
}

// ── GROUP FIELDS ── поля в самом groups/{gid} (merge ТОЛЬКО отсутствующих полей)
const GROUP_COL = {
  member_moods: "memberMoods",
  member_names: "memberNames",
  member_avatars: "memberAvatars",
  member_birthdays: "memberBirthdays",
  current_status: "currentStatus",
  custom_statuses: "customStatuses",
  custom_relationship_types: "customRelationshipTypes",
};
function isEmptyVal(v) {
  if (v === null || v === undefined) return true;
  if (Array.isArray(v)) return v.length === 0;
  if (typeof v === "object") return Object.keys(v).length === 0;
  return false;
}
async function backfillGroupFields(token, gid) {
  const sb = await sbGroupRow(gid, Object.keys(GROUP_COL).join(","));
  if (!sb) return { sb: 0, fb: 0, add: 0 };
  const fbDoc = await fbGetDoc(token, `groups/${gid}`);
  const fbFields = (fbDoc && fbDoc.fields) || {};
  const toAdd = {};
  let sbCount = 0;
  for (const [sc, cc] of Object.entries(GROUP_COL)) {
    const val = sb[sc];
    if (!isEmptyVal(val)) sbCount++;
    const fbHas = fbFields[cc] !== undefined && !("nullValue" in fbFields[cc]);
    // Дописываем поле, только если оно непустое в Supabase и ОТСУТСТВУЕТ в Firebase.
    if (!isEmptyVal(val) && !fbHas) toAdd[cc] = val;
  }
  const add = Object.keys(toAdd).length;
  if (COMMIT && add) await fbPatchFields(token, `groups/${gid}`, toAdd);
  return { sb: sbCount, fb: Object.keys(fbFields).length, add };
}

const HANDLERS = {
  memories: backfillMemories,
  comments: backfillComments,
  moods: backfillMoods,
  strokes: backfillStrokes,
  canvasMeta: backfillCanvasMeta,
  canvasCatalogue: backfillCanvasCatalogue,
  widget: backfillWidget,
  group: backfillGroupFields,
};
const ALL_TYPES = Object.keys(HANDLERS);

async function main() {
  if (!SBKEY) throw new Error("SBKEY не задан. Запусти: SBKEY=<service-role> node tools/backfill_supabase_to_firebase.js ...");
  const isAll = TYPE === "all";
  if (!isAll && !HANDLERS[TYPE]) {
    console.log("Типы:", ALL_TYPES.join(", "), "| all");
    console.log("Пример: SBKEY=... node tools/backfill_supabase_to_firebase.js all --group <GID>");
    process.exit(1);
  }
  const types = isAll ? ALL_TYPES : [TYPE];
  const { token, email } = await getToken();
  console.log(`Firebase: ${email} | Supabase: ${SB_HOST}`);
  console.log(`Типы: ${types.join(", ")} | режим: ${COMMIT ? "🔴 БОЕВОЙ (пишет)" : "🟢 DRY-RUN (только чтение)"}\n`);

  let groups;
  if (onlyGroup) {
    groups = [onlyGroup];
  } else {
    console.log("Ищу stage4-группы…");
    groups = await scanStage4Groups(token);
    console.log(`Найдено stage4-групп: ${groups.length}`);
    if (limitGroups) groups = groups.slice(0, limitGroups);
  }

  const perType = Object.fromEntries(types.map((t) => [t, { add: 0, sb: 0 }]));
  let touched = 0, errs = 0;
  for (let i = 0; i < groups.length; i++) {
    const gid = groups[i];
    let groupAdded = 0;
    const parts = [];
    for (const t of types) {
      try {
        const res = await HANDLERS[t](token, gid);
        perType[t].add += res.add;
        perType[t].sb += res.sb;
        if (res.add > 0) {
          groupAdded += res.add;
          parts.push(`${t}=${res.add}`);
        }
      } catch (e) {
        errs++;
        console.log(`  ${gid} [${t}]: ОШИБКА ${e.message}`);
      }
    }
    if (groupAdded > 0) {
      touched++;
      console.log(`  ${gid}: ${COMMIT ? "долито" : "долить"} ${groupAdded} (${parts.join(", ")})`);
    }
    if ((i + 1) % 50 === 0) console.log(`  … ${i + 1}/${groups.length}`);
  }

  console.log(`\n=== ИТОГ (${COMMIT ? "БОЕВОЙ" : "DRY-RUN"}) ===`);
  console.log(`Групп обработано: ${groups.length}, с отсутствующими записями: ${touched}, ошибок: ${errs}`);
  for (const t of types) {
    console.log(`  ${t}: в Supabase=${perType[t].sb}, ${COMMIT ? "долито" : "к доливке"}=${perType[t].add}`);
  }
  const totAdd = types.reduce((s, t) => s + perType[t].add, 0);
  if (!COMMIT && totAdd > 0) console.log(`\nЭто DRY-RUN. Для боевого прогона добавь --commit.`);
}

main().catch((e) => {
  console.error("Сбой:", e.message);
  process.exit(1);
});
