// READ-ONLY скоуп бэкфилла Supabase→Firebase.
//
// Находит группы, у которых Firebase-запись МОГЛА быть отключена под Stage 4 —
// т.е. у ВСЕХ участников есть свежий (≤ _FRESH_DAYS) маркер `sbRead` (он пишется
// только когда участник реально читает из Supabase). Только у таких групп могут
// быть данные, существующие ТОЛЬКО в Supabase. Группы с частичным sbRead (не все
// участники) не в счёт — там мост держал дуал-запись в Firebase.
//
// Только ЧТЕНИЕ Firestore. Ничего не пишет. Доступ — как в admin_groups.js
// (refresh_token владельца из firebase CLI configstore).
//
//   node tools/backfill_scope.js

const fs = require("fs");
const os = require("os");
const https = require("https");

const PROJECT = "togetherly-d4856";
const FS_BASE = `/v1/projects/${PROJECT}/databases/(default)/documents`;
const CID =
  "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com";
const CSEC = "j9iVZfS8kkCEFUPaAeJV0sAi";
const FRESH_DAYS = 21; // = _kMarkerFreshDays

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
  if (tk.status !== 200) throw new Error("refresh_token обмен не удался: " + tk.body.slice(0, 200));
  return { token: JSON.parse(tk.body).access_token, email: (j.user && j.user.email) || "?" };
}

function authHeaders(token, json = true) {
  const h = { Authorization: "Bearer " + token, "x-goog-user-project": PROJECT };
  if (json) h["Content-Type"] = "application/json";
  return h;
}

function fv(field) {
  if (!field) return undefined;
  if ("stringValue" in field) return field.stringValue;
  if ("booleanValue" in field) return field.booleanValue;
  if ("integerValue" in field) return Number(field.integerValue);
  if ("timestampValue" in field) return field.timestampValue;
  if ("arrayValue" in field) return (field.arrayValue.values || []).map(fv);
  if ("mapValue" in field) {
    const out = {};
    const fields = field.mapValue.fields || {};
    for (const k of Object.keys(fields)) out[k] = fv(fields[k]);
    return out;
  }
  return field;
}

// Скан всех групп c проекцией нужных полей, постранично (startAfter по __name__).
async function scanGroups(token) {
  const docs = [];
  let cursorName = null;
  for (;;) {
    const sq = {
      structuredQuery: {
        from: [{ collectionId: "groups" }],
        select: {
          fields: [
            { fieldPath: "members" },
            { fieldPath: "sbRead" },
            { fieldPath: "disbanded" },
          ],
        },
        orderBy: [{ field: { fieldPath: "__name__" }, direction: "ASCENDING" }],
        limit: 1000,
      },
    };
    if (cursorName) {
      sq.structuredQuery.startAt = {
        before: false,
        values: [{ referenceValue: cursorName }],
      };
    }
    const r = await req("POST", "firestore.googleapis.com", `${FS_BASE}:runQuery`, sq, authHeaders(token));
    if (r.status !== 200) throw new Error(`runQuery ${r.status}: ${r.body.slice(0, 200)}`);
    const rows = JSON.parse(r.body).filter((x) => x.document);
    if (!rows.length) break;
    for (const x of rows) docs.push(x.document);
    cursorName = rows[rows.length - 1].document.name;
    if (rows.length < 1000) break;
  }
  return docs;
}

async function uidsToEmails(token, uids) {
  const out = {};
  if (!uids.length) return out;
  // accounts:lookup принимает до 100 localId за раз.
  for (let i = 0; i < uids.length; i += 100) {
    const batch = uids.slice(i, i + 100);
    const r = await req(
      "POST",
      "identitytoolkit.googleapis.com",
      `/v1/projects/${PROJECT}/accounts:lookup`,
      { localId: batch },
      authHeaders(token)
    );
    if (r.status !== 200) continue;
    for (const u of JSON.parse(r.body).users || []) {
      out[u.localId] = u.email || u.providerUserInfo?.[0]?.email || "(нет email)";
    }
  }
  return out;
}

function freshFor(sbRead, members, nowMs) {
  // true если у КАЖДОГО участника есть sbRead-ts не старше FRESH_DAYS.
  if (!sbRead || !members.length) return false;
  for (const m of members) {
    const ts = sbRead[m];
    if (!ts) return false;
    const dt = Date.parse(ts);
    if (isNaN(dt)) return false;
    if ((nowMs - dt) / 86400000 > FRESH_DAYS) return false;
  }
  return true;
}

async function main() {
  const { token, email } = await getToken();
  console.log(`Авторизован как: ${email}\n`);
  console.log("Сканирую коллекцию groups…");
  const docs = await scanGroups(token);
  console.log(`Всего групп: ${docs.length}`);

  const nowMs = Date.now();
  let withAnySbRead = 0;
  let partial = 0;
  const stage4 = []; // {gid, members}
  for (const doc of docs) {
    const f = doc.fields || {};
    if (fv(f.disbanded) === true) continue;
    const members = (fv(f.members) || []).filter((s) => s);
    const sbRead = fv(f.sbRead) || {};
    const sbKeys = Object.keys(sbRead);
    if (sbKeys.length) withAnySbRead++;
    if (!members.length) continue;
    if (freshFor(sbRead, members, nowMs)) {
      stage4.push({ gid: doc.name.split("/").pop(), members });
    } else if (sbKeys.length) {
      partial++;
    }
  }

  console.log(`Групп хоть с одним маркером sbRead: ${withAnySbRead}`);
  console.log(`  из них частичных (не все участники / устаревшие) — НЕ затронуты: ${partial}`);
  console.log(`\n=== STAGE4-группы (все участники свежо читали Supabase) — потенциально есть Supabase-only данные: ${stage4.length} ===`);

  if (!stage4.length) {
    console.log("Бэкфилл НЕ нужен: ни одной полностью-stage4 группы.");
    return;
  }

  // Резолвим email участников для отчёта.
  const allUids = [...new Set(stage4.flatMap((g) => g.members))];
  const emails = await uidsToEmails(token, allUids);
  for (const g of stage4) {
    console.log(`\n• ${g.gid}`);
    for (const m of g.members) console.log(`    ${m} → ${emails[m] || "?"}`);
  }
  console.log(`\nИтого затронутых групп: ${stage4.length}. Для них нужен бэкфилл Supabase→Firebase (нужен Supabase service-role ключ).`);
}

main().catch((e) => {
  console.error("Сбой:", e.message);
  process.exit(1);
});
