// Read-only диагностика состояния миграции Firebase→Supabase в ПРОДЕ.
//
// Отвечает на вопрос «мигрированы ли пары на самом деле / у всех ли ошибка»:
// сканирует коллекцию groups в Firestore и считает по маркерам, которые пишет
// клиент:
//   • sbMig[uid]  — «я на новой сборке» (пишется на каждый listenToPair);
//   • sbRead[uid] — «я РЕАЛЬНО читаю из Supabase» (пишется ТОЛЬКО когда пара
//                   уже флипнута, _resolveGroupCompat при _readSb==true).
// Если групп со свежим sbRead ≈ 0 при массе групп со свежим sbMig — значит
// «оба на новой сборке, но флип не происходит ни у кого» (систематически).
//
// Доступ — refresh_token владельца из firebase CLI configstore (как
// tools/admin_groups.js). НИЧЕГО не пишет. Запуск:
//   node scripts/check_migration_state.js

const fs = require("fs");
const os = require("os");
const https = require("https");

const PROJECT = "togetherly-d4856";
const FS_BASE = `/v1/projects/${PROJECT}/databases/(default)/documents`;
const CID =
  "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com";
const CSEC = "j9iVZfS8kkCEFUPaAeJV0sAi";
const FRESH_DAYS = 21; // == _kMarkerFreshDays в firebase_service.dart

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
  if (!j.tokens || !j.tokens.refresh_token) {
    throw new Error("Нет refresh_token — выполни `firebase login`.");
  }
  const form =
    "client_id=" + encodeURIComponent(CID) +
    "&client_secret=" + encodeURIComponent(CSEC) +
    "&refresh_token=" + encodeURIComponent(j.tokens.refresh_token) +
    "&grant_type=refresh_token";
  const tk = await req("POST", "oauth2.googleapis.com", "/token", form, {
    "Content-Type": "application/x-www-form-urlencoded",
  });
  if (tk.status !== 200) throw new Error("refresh обмен не удался: " + tk.body.slice(0, 200));
  return JSON.parse(tk.body).access_token;
}

// Свежий ли timestamp-маркер (мапа uid->{timestampValue}) для данного uid.
function freshFor(mapField, uid, now) {
  const fields = mapField && mapField.mapValue && mapField.mapValue.fields;
  if (!fields || !fields[uid]) return false;
  const ts = fields[uid].timestampValue;
  if (!ts) return false;
  const ageDays = (now - new Date(ts).getTime()) / 86400000;
  return ageDays <= FRESH_DAYS;
}

async function main() {
  const token = await getToken();
  const headers = { Authorization: "Bearer " + token, "x-goog-user-project": PROJECT };
  const now = Date.now();

  let pageToken = null;
  let total = 0, active = 0;
  let someMig = 0, allMig = 0;     // ≥1 / все участники на новой сборке
  let someRead = 0, allRead = 0;   // ≥1 / все участники реально читают Supabase
  let migratedFully = 0;           // active + allMig + allRead (полностью флипнуты)

  do {
    let path = `${FS_BASE}/groups?pageSize=300`;
    if (pageToken) path += `&pageToken=${encodeURIComponent(pageToken)}`;
    const res = await req("GET", "firestore.googleapis.com", path, null, headers);
    if (res.status !== 200) throw new Error("list groups: " + res.status + " " + res.body.slice(0, 300));
    const j = JSON.parse(res.body);
    const docs = j.documents || [];
    for (const doc of docs) {
      total++;
      const f = doc.fields || {};
      if (f.disbanded && f.disbanded.booleanValue === true) continue;
      const members = ((f.members && f.members.arrayValue && f.members.arrayValue.values) || [])
        .map((v) => v.stringValue).filter(Boolean);
      if (members.length === 0) continue;
      active++;

      const migFlags = members.map((u) => freshFor(f.sbMig, u, now));
      const readFlags = members.map((u) => freshFor(f.sbRead, u, now));
      const anyMig = migFlags.some(Boolean), everyMig = migFlags.every(Boolean);
      const anyRead = readFlags.some(Boolean), everyRead = readFlags.every(Boolean);

      if (anyMig) someMig++;
      if (everyMig) allMig++;
      if (anyRead) someRead++;
      if (everyRead) allRead++;
      if (everyMig && everyRead) migratedFully++;
    }
    pageToken = j.nextPageToken || null;
  } while (pageToken);

  // Сколько юзеров завершили data-бэкфилл (users.sbMigrated=true пишется в
  // _ensureSbMigratedFlag только когда dataDone). Это предпосылка флипа, которую
  // мой новый гейт ВСЁ ЕЩЁ требует — если она массово не выполнена, флип не
  // пойдёт даже без media-зависимости.
  async function countUsers(whereTrue) {
    const q = { structuredAggregationQuery: { structuredQuery: { from: [{ collectionId: "users" }] }, aggregations: [{ alias: "c", count: {} }] } };
    if (whereTrue) q.structuredAggregationQuery.structuredQuery.where = { fieldFilter: { field: { fieldPath: "sbMigrated" }, op: "EQUAL", value: { booleanValue: true } } };
    const res = await req("POST", "firestore.googleapis.com", `${FS_BASE}:runAggregationQuery`, q, Object.assign({ "Content-Type": "application/json" }, headers));
    if (res.status !== 200) return "?(" + res.status + ")";
    try { return JSON.parse(res.body)[0].result.aggregateFields.c.integerValue; } catch { return "?"; }
  }
  const usersTotal = await countUsers(false);
  const usersMigrated = await countUsers(true);

  const pct = (n) => active ? ((100 * n) / active).toFixed(1) + "%" : "—";
  console.log("══════════ СОСТОЯНИЕ МИГРАЦИИ (прод) ══════════");
  console.log(`Документов groups всего:            ${total}`);
  console.log(`Активных (есть members, не distb):  ${active}`);
  console.log(`─────────────────────────────────────────────`);
  console.log(`Свежий sbMig у ≥1 участника:        ${someMig}  (${pct(someMig)})`);
  console.log(`Свежий sbMig у ВСЕХ (оба на новой): ${allMig}  (${pct(allMig)})`);
  console.log(`─────────────────────────────────────────────`);
  console.log(`Свежий sbRead у ≥1 участника:       ${someRead}  (${pct(someRead)})`);
  console.log(`Свежий sbRead у ВСЕХ (реально чит): ${allRead}  (${pct(allRead)})`);
  console.log(`─────────────────────────────────────────────`);
  console.log(`ПОЛНОСТЬЮ ФЛИПНУТЫ (allMig+allRead): ${migratedFully}  (${pct(migratedFully)})`);
  console.log(`─────────────────────────────────────────────`);
  console.log(`users всего:                        ${usersTotal}`);
  console.log(`users с sbMigrated=true (data done):${usersMigrated}`);
  console.log(`порог свежести маркера: ${FRESH_DAYS} дн`);
}

main().catch((e) => { console.error("FAIL:", e.message); process.exit(1); });
