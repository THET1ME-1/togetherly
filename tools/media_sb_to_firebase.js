// Реверс медиа Supabase Storage (sb://) → Firebase Storage (gs://).
// Цель: полностью отключить Supabase. Переписывает ВСЕ ссылки sb:// в Firestore
// на gs://togetherly-d4856.firebasestorage.app/<path> (резолвер приложения уже
// умеет gs:// через Cloud Function getSignedUrl — обновление приложения НЕ нужно).
//
// Два класса sb://-файлов:
//   (a) Мигрированные: оригинал НИКОГДА не удалялся из Firebase Storage, а путь
//       в Supabase зеркалит путь Firebase → достаточно переписать URL.
//   (b) Рождённые в Supabase (новые загрузки под Stage 4): Firebase-оригинала нет
//       → файл СКАЧИВАЕТСЯ из Supabase Storage и ЗАЛИВАЕТСЯ в Firebase, затем URL.
//   Если файла нет ни там, ни там (gone) — ссылка остаётся как есть, считается gone.
//
// Перепись — generic-рекурсия по всем строковым полям документа (ловит imageUrl,
// imageUrls[], videoUrl, musicCoverUrl, authorAvatar, memberAvatars{}, mascots[],
// canvas strokes imageUrl, widgetData *Url — без перечисления каждого поля).
// PATCH только изменённых полей верхнего уровня (updateMask) — остальное не трогаем.
//
// Доступ: Firebase — owner refresh_token (firebase CLI configstore); Supabase —
// service-role в SBKEY (нужен для list/download приватного бакета). DRY-RUN по
// умолчанию (только считает + проверяет наличие; НЕ пишет, НЕ заливает).
//
// Использование:
//   SBKEY=... node tools/media_sb_to_firebase.js                 # dry-run, stage4-группы
//   SBKEY=... node tools/media_sb_to_firebase.js --all           # dry-run, ВСЕ группы
//   SBKEY=... node tools/media_sb_to_firebase.js --group GID      # одна группа
//   SBKEY=... node tools/media_sb_to_firebase.js --limit 20       # первые N групп
//   SBKEY=... node tools/media_sb_to_firebase.js --commit         # БОЕВОЙ (пишет+заливает)

const fs = require("fs");
const os = require("os");
const https = require("https");

const PROJECT = "togetherly-d4856";
const FB_HOST = "firestore.googleapis.com";
const ST_HOST = "firebasestorage.googleapis.com";
const FB_BASE = `/v1/projects/${PROJECT}/databases/(default)/documents`;
const FB_BUCKET = "togetherly-d4856.firebasestorage.app";
const CID = "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com";
const CSEC = "j9iVZfS8kkCEFUPaAeJV0sAi";
const FRESH_DAYS = 21;

const SB_HOST = "xxjlzzkhrvyiqaexvymx.supabase.co";
const SBKEY = process.env.SBKEY || process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const SB_SCHEME = "sb://";

const args = process.argv.slice(2);
const COMMIT = args.includes("--commit");
const SCAN_ALL = args.includes("--all");
const onlyGroup = (() => { const i = args.indexOf("--group"); return i >= 0 ? args[i + 1] : null; })();
const limitGroups = (() => { const i = args.indexOf("--limit"); return i >= 0 ? parseInt(args[i + 1], 10) : null; })();

// ── HTTP (текст и бинарь) ──
function req(method, host, path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const data = body == null ? null : Buffer.isBuffer(body) ? body : typeof body === "string" ? body : JSON.stringify(body);
    const h = Object.assign({}, headers);
    if (data != null) h["Content-Length"] = Buffer.byteLength(data);
    const r = https.request({ host, path, method, headers: h }, (resp) => {
      const chunks = [];
      resp.on("data", (c) => chunks.push(c));
      resp.on("end", () => resolve({ status: resp.statusCode, buf: Buffer.concat(chunks), headers: resp.headers }));
    });
    r.on("error", reject);
    if (data != null) r.write(data);
    r.end();
  });
}
async function reqText(method, host, path, body, headers) {
  const r = await req(method, host, path, body, headers);
  return { status: r.status, body: r.buf.toString(), headers: r.headers };
}

async function getToken() {
  const f = os.homedir() + "/.config/configstore/firebase-tools.json";
  const j = JSON.parse(fs.readFileSync(f, "utf8"));
  if (!j.tokens || !j.tokens.refresh_token) throw new Error("Нет refresh_token — `firebase login`.");
  const form = "client_id=" + encodeURIComponent(CID) + "&client_secret=" + encodeURIComponent(CSEC) +
    "&refresh_token=" + encodeURIComponent(j.tokens.refresh_token) + "&grant_type=refresh_token";
  const tk = await reqText("POST", "oauth2.googleapis.com", "/token", form, { "Content-Type": "application/x-www-form-urlencoded" });
  if (tk.status !== 200) throw new Error("refresh_token обмен не удался: " + tk.body.slice(0, 200));
  return { token: JSON.parse(tk.body).access_token, email: (j.user && j.user.email) || "?" };
}

function fbHeaders(token, json = true) {
  const h = { Authorization: "Bearer " + token, "x-goog-user-project": PROJECT };
  if (json) h["Content-Type"] = "application/json";
  return h;
}
function sbHeaders() { return { apikey: SBKEY, Authorization: "Bearer " + SBKEY }; }

const MIME = { webp: "image/webp", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif",
  mp4: "video/mp4", mov: "video/quicktime", mp3: "audio/mpeg", m4a: "audio/mp4", aac: "audio/aac", wav: "audio/wav" };
function mimeOf(path) { const e = (path.split(".").pop() || "").toLowerCase(); return MIME[e] || "application/octet-stream"; }

// ── sb:// → {bucket, path} ──
function parseSb(url) {
  const rest = url.slice(SB_SCHEME.length);
  const i = rest.indexOf("/");
  if (i < 0) return null;
  return { bucket: rest.slice(0, i), path: rest.slice(i + 1) };
}

// Кэш статуса файла в Firebase Storage по storage-path: 'ok' | 'gone'.
const fileStatus = new Map();
const stats = { refs: 0, rewritten: 0, copied: 0, gone: 0, copyFail: 0 };

// Firebase Storage: существует ли объект.
async function fbObjectExists(token, path) {
  const r = await req("GET", ST_HOST, `/v0/b/${FB_BUCKET}/o/${encodeURIComponent(path)}`, null, { Authorization: "Bearer " + token });
  return r.status === 200;
}
// Supabase Storage: скачать байты приватного объекта (service-role минует RLS).
async function sbDownload(bucket, path) {
  const r = await req("GET", SB_HOST, `/storage/v1/object/${bucket}/${encodeURI(path)}`, null, sbHeaders());
  if (r.status === 200) return { buf: r.buf, ct: r.headers["content-type"] };
  return null;
}
// Firebase Storage: залить байты.
async function fbUpload(token, path, buf, ct) {
  const r = await req("POST", ST_HOST, `/v0/b/${FB_BUCKET}/o?uploadType=media&name=${encodeURIComponent(path)}`,
    buf, { Authorization: "Bearer " + token, "Content-Type": ct || mimeOf(path) });
  return r.status === 200;
}

// Гарантировать, что файл sb-пути есть в Firebase Storage (скопировать при нужде).
// Статусы: 'ok' (уже в Firebase), 'copied' (скопирован), 'copy' (dry-run: нужно
// копировать), 'gone' (нет в Supabase), 'copyfail' (сбой заливки). Без счётчиков —
// учёт ведёт transformValue.
async function ensureInFirebase(token, bucket, path) {
  if (fileStatus.has(path)) return fileStatus.get(path);
  let st;
  if (await fbObjectExists(token, path)) {
    st = "ok"; // класс (a): оригинал на месте
  } else if (!COMMIT) {
    st = "copy"; // dry-run: считаем, что в Supabase есть (URL оттуда и взялся); gone проверим на --commit
  } else {
    const dl = await sbDownload(bucket, path); // класс (b): тащим из Supabase
    if (!dl) st = "gone";
    else if (await fbUpload(token, path, dl.buf, dl.ct)) st = "copied";
    else st = "copyfail";
  }
  fileStatus.set(path, st);
  return st;
}

// Рекурсивная перепись sb:// в Firestore-Value. Возвращает {value, changed}.
async function transformValue(token, value) {
  if (!value || typeof value !== "object") return { value, changed: false };
  if ("stringValue" in value && typeof value.stringValue === "string" && value.stringValue.startsWith(SB_SCHEME)) {
    stats.refs++;
    const p = parseSb(value.stringValue);
    if (!p) return { value, changed: false };
    const st = await ensureInFirebase(token, p.bucket, p.path);
    const gs = { stringValue: `gs://${FB_BUCKET}/${p.path}` };
    if (st === "ok") { stats.rewritten++; return { value: gs, changed: true }; }
    if (st === "copied" || st === "copy") { stats.copied++; return { value: gs, changed: true }; }
    if (st === "copyfail") { stats.copyFail++; return { value, changed: false }; }
    stats.gone++;
    return { value, changed: false }; // gone — оставляем как есть
  }
  if ("arrayValue" in value) {
    const vals = value.arrayValue.values || [];
    let changed = false;
    const out = [];
    for (const v of vals) { const r = await transformValue(token, v); out.push(r.value); if (r.changed) changed = true; }
    return { value: { arrayValue: { values: out } }, changed };
  }
  if ("mapValue" in value) {
    const fields = value.mapValue.fields || {};
    let changed = false;
    const out = {};
    for (const k of Object.keys(fields)) { const r = await transformValue(token, fields[k]); out[k] = r.value; if (r.changed) changed = true; }
    return { value: { mapValue: { fields: out } }, changed };
  }
  return { value, changed: false };
}

// Перебрать поля документа; вернуть { changedFields, mask }.
async function transformDoc(token, fields) {
  const changedFields = {};
  const mask = [];
  for (const k of Object.keys(fields || {})) {
    const r = await transformValue(token, fields[k]);
    if (r.changed) { changedFields[k] = r.value; mask.push(k); }
  }
  return { changedFields, mask };
}

// PATCH только изменённых полей верхнего уровня существующего дока.
async function fbPatch(token, rel, changedFields, mask) {
  const q = mask.map((k) => `updateMask.fieldPaths=${encodeURIComponent("`" + k + "`")}`).join("&");
  const r = await reqText("PATCH", FB_HOST, `${FB_BASE}/${rel}?${q}&currentDocument.exists=true`,
    { fields: changedFields }, fbHeaders(token));
  if (r.status !== 200) throw new Error(`patch ${rel} ${r.status}: ${r.body.slice(0, 200)}`);
}

// Обработать один документ (name — полный resource name или rel-путь под /documents/).
async function processDoc(token, fullName, fields) {
  const { changedFields, mask } = await transformDoc(token, fields);
  if (!mask.length) return 0;
  const rel = fullName.includes("/documents/") ? fullName.split("/documents/")[1] : fullName;
  if (COMMIT) await fbPatch(token, rel, changedFields, mask);
  return mask.length;
}

// ── Firestore listing ──
async function fbGetDoc(token, rel) {
  const r = await reqText("GET", FB_HOST, `${FB_BASE}/${rel}`, null, fbHeaders(token, false));
  if (r.status === 404) return null;
  if (r.status !== 200) throw new Error(`get ${rel} ${r.status}: ${r.body.slice(0, 150)}`);
  return JSON.parse(r.body);
}
async function* fbList(token, parentRel, sub) {
  let pageToken = "";
  for (;;) {
    const qs = `pageSize=300${pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : ""}`;
    const r = await reqText("GET", FB_HOST, `${FB_BASE}/${parentRel}/${sub}?${qs}`, null, fbHeaders(token, false));
    if (r.status !== 200) throw new Error(`list ${parentRel}/${sub} ${r.status}: ${r.body.slice(0, 150)}`);
    const j = JSON.parse(r.body);
    for (const d of j.documents || []) yield d;
    if (!j.nextPageToken) break;
    pageToken = j.nextPageToken;
  }
}

async function scanGroups(token, allGroups) {
  const docs = [];
  let cursor = null;
  for (;;) {
    const sq = {
      structuredQuery: {
        from: [{ collectionId: "groups" }],
        select: { fields: [{ fieldPath: "members" }, { fieldPath: "sbRead" }, { fieldPath: "disbanded" }] },
        orderBy: [{ field: { fieldPath: "__name__" }, direction: "ASCENDING" }],
        limit: 1000,
      },
    };
    if (cursor) sq.structuredQuery.startAt = { before: false, values: [{ referenceValue: cursor }] };
    const r = await reqText("POST", FB_HOST, `${FB_BASE}:runQuery`, sq, fbHeaders(token));
    if (r.status !== 200) throw new Error(`scan ${r.status}: ${r.body.slice(0, 150)}`);
    const rows = JSON.parse(r.body).filter((x) => x.document);
    if (!rows.length) break;
    for (const x of rows) docs.push(x.document);
    cursor = rows[rows.length - 1].document.name;
    if (rows.length < 1000) break;
  }
  if (allGroups) return docs.map((d) => d.name.split("/").pop());
  const nowMs = Date.now();
  const out = [];
  for (const doc of docs) {
    const f = doc.fields || {};
    if (f.disbanded && f.disbanded.booleanValue === true) continue;
    const members = ((f.members && f.members.arrayValue.values) || []).map((v) => v.stringValue).filter(Boolean);
    const sbRead = (f.sbRead && f.sbRead.mapValue.fields) || {};
    if (!members.length) continue;
    let allFresh = true;
    for (const m of members) {
      const ts = sbRead[m] && sbRead[m].timestampValue;
      const dt = ts ? Date.parse(ts) : NaN;
      if (isNaN(dt) || (nowMs - dt) / 86400000 > FRESH_DAYS) { allFresh = false; break; }
    }
    if (allFresh) out.push(doc.name.split("/").pop());
  }
  return out;
}

async function processGroup(token, gid) {
  let changed = 0;
  // 1. group doc (memberAvatars, mascots, …)
  const g = await fbGetDoc(token, `groups/${gid}`);
  if (g) changed += await processDoc(token, `groups/${gid}`, g.fields);
  // 2. memories
  for await (const d of fbList(token, `groups/${gid}`, "memories")) {
    changed += await processDoc(token, d.name, d.fields);
    // 2b. комментарии содержат authorAvatar — на случай sb://
    const mid = d.name.split("/").pop();
    for await (const c of fbList(token, `groups/${gid}/memories/${mid}`, "comments")) {
      changed += await processDoc(token, c.name, c.fields);
    }
  }
  // 3. widgetData
  for await (const d of fbList(token, `groups/${gid}`, "widgetData")) {
    changed += await processDoc(token, d.name, d.fields);
  }
  // 4. canvas/*/strokes (+ сам canvas-док)
  for await (const cv of fbList(token, `groups/${gid}`, "canvas")) {
    changed += await processDoc(token, cv.name, cv.fields);
    const cid = cv.name.split("/").pop();
    for await (const s of fbList(token, `groups/${gid}/canvas/${cid}`, "strokes")) {
      changed += await processDoc(token, s.name, s.fields);
    }
  }
  return changed;
}

async function main() {
  if (!SBKEY) throw new Error("SBKEY не задан. SBKEY=<service-role> node tools/media_sb_to_firebase.js ...");
  const { token, email } = await getToken();
  console.log(`Firebase: ${email} | bucket: ${FB_BUCKET} | Supabase: ${SB_HOST}`);
  console.log(`Режим: ${COMMIT ? "🔴 БОЕВОЙ (пишет+заливает)" : "🟢 DRY-RUN (только проверка)"}\n`);

  let groups;
  if (onlyGroup) groups = [onlyGroup];
  else {
    console.log(SCAN_ALL ? "Сканирую ВСЕ группы…" : "Ищу stage4-группы…");
    groups = await scanGroups(token, SCAN_ALL);
    console.log(`Групп: ${groups.length}`);
    if (limitGroups) groups = groups.slice(0, limitGroups);
  }

  let touched = 0, errs = 0;
  for (let i = 0; i < groups.length; i++) {
    try {
      const c = await processGroup(token, groups[i]);
      if (c > 0) { touched++; console.log(`  ${groups[i]}: ${COMMIT ? "переписано полей" : "к переписи полей"} ${c}`); }
    } catch (e) { errs++; console.log(`  ${groups[i]}: ОШИБКА ${e.message}`); }
    if ((i + 1) % 50 === 0) console.log(`  … ${i + 1}/${groups.length}`);
  }

  console.log(`\n=== ИТОГ (${COMMIT ? "БОЕВОЙ" : "DRY-RUN"}) ===`);
  console.log(`Групп: ${groups.length}, с правками: ${touched}, ошибок: ${errs}`);
  console.log(`sb://-ссылок найдено: ${stats.refs}`);
  console.log(`  переписано (файл уже в Firebase): ${stats.rewritten}`);
  console.log(`  ${COMMIT ? "скопировано из Supabase + переписано" : "требуют копирования из Supabase"}: ${stats.copied}`);
  console.log(`  gone (нет ни в Firebase, ни в Supabase): ${stats.gone}`);
  if (stats.copyFail) console.log(`  СБОЙ копирования: ${stats.copyFail}`);
  if (!COMMIT && (stats.rewritten + stats.copied) > 0) console.log(`\nЭто DRY-RUN. Боевой прогон: --commit`);
}

main().catch((e) => { console.error("Сбой:", e.message); process.exit(1); });
