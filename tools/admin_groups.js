// Admin-инструмент поддержки: поиск и восстановление групп пары по email.
//
// Доступ берётся из локальной сессии firebase CLI (аккаунт-владелец
// stgroup.dev@gmail.com): refresh_token из ~/.config/configstore/firebase-tools.json
// обменивается на короткоживущий access_token. Сервис-аккаунт ключ не нужен.
// Токен в консоль НЕ печатается.
//
// Использование:
//   node tools/admin_groups.js lookup  <email> [email2 ...]   # только чтение
//   node tools/admin_groups.js restore <email> [email2 ...]   # снять disbanded
//
// «restore» делает: groups/{id}.disbanded = false и возвращает id группы
// в users/{member}.pairIds (arrayUnion) для обоих участников.

const fs = require("fs");
const os = require("os");
const https = require("https");

const PROJECT = "togetherly-d4856";
const FS_BASE = `/v1/projects/${PROJECT}/databases/(default)/documents`;
// Публичные OAuth-креды firebase-tools (как в исходниках firebase CLI).
const CID =
  "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com";
const CSEC = "j9iVZfS8kkCEFUPaAeJV0sAi";

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
    throw new Error("Нет refresh_token в firebase-tools.json — выполни `firebase login`.");
  }
  const form =
    "client_id=" + encodeURIComponent(CID) +
    "&client_secret=" + encodeURIComponent(CSEC) +
    "&refresh_token=" + encodeURIComponent(j.tokens.refresh_token) +
    "&grant_type=refresh_token";
  const tk = await req("POST", "oauth2.googleapis.com", "/token", form, {
    "Content-Type": "application/x-www-form-urlencoded",
  });
  if (tk.status !== 200) throw new Error("Обмен refresh_token не удался: " + tk.body.slice(0, 200));
  return { token: JSON.parse(tk.body).access_token, email: (j.user && j.user.email) || "?" };
}

function authHeaders(token, json = true) {
  const h = {
    Authorization: "Bearer " + token,
    "x-goog-user-project": PROJECT,
  };
  if (json) h["Content-Type"] = "application/json";
  return h;
}

// email -> uid через Identity Toolkit accounts:lookup
async function emailToUid(token, email) {
  const r = await req(
    "POST",
    "identitytoolkit.googleapis.com",
    `/v1/projects/${PROJECT}/accounts:lookup`,
    { email: [email] },
    authHeaders(token)
  );
  if (r.status !== 200) throw new Error(`accounts:lookup ${r.status}: ${r.body.slice(0, 200)}`);
  const u = JSON.parse(r.body).users;
  return u && u.length ? u[0].localId : null;
}

// uid[] -> {uid: email} обратный резолв
async function uidsToEmails(token, uids) {
  const out = {};
  if (!uids.length) return out;
  const r = await req(
    "POST",
    "identitytoolkit.googleapis.com",
    `/v1/projects/${PROJECT}/accounts:lookup`,
    { localId: uids },
    authHeaders(token)
  );
  if (r.status !== 200) return out;
  for (const u of JSON.parse(r.body).users || []) {
    out[u.localId] = u.email || u.providerUserInfo?.[0]?.email || "(нет email)";
  }
  return out;
}

// GET одного документа группы
async function fetchGroup(token, gid) {
  const r = await req(
    "GET",
    "firestore.googleapis.com",
    `${FS_BASE}/groups/${gid}`,
    null,
    authHeaders(token, false)
  );
  if (r.status !== 200) return null;
  return JSON.parse(r.body);
}

// GET users/{uid}
async function fetchUser(token, uid) {
  const r = await req(
    "GET",
    "firestore.googleapis.com",
    `${FS_BASE}/users/${uid}`,
    null,
    authHeaders(token, false)
  );
  return { status: r.status, doc: r.status === 200 ? JSON.parse(r.body) : null };
}

// Поиск групп по имени маскота (collection-group).
async function searchMascot(token, queryName) {
  const variants = [
    queryName,
    queryName.toLowerCase(),
    queryName.toUpperCase(),
    queryName.charAt(0).toUpperCase() + queryName.slice(1).toLowerCase(),
  ].filter((v, i, a) => a.indexOf(v) === i);
  const inQ = {
    structuredQuery: {
      from: [{ collectionId: "mascots", allDescendants: true }],
      where: {
        fieldFilter: {
          field: { fieldPath: "name" },
          op: "IN",
          value: { arrayValue: { values: variants.map((v) => ({ stringValue: v })) } },
        },
      },
    },
  };
  let r = await req("POST", "firestore.googleapis.com", `${FS_BASE}:runQuery`, inQ, authHeaders(token));
  let rows = (r.status === 200 ? JSON.parse(r.body) : []).filter((x) => x.document);
  if (!rows.length) {
    // полный скан с фильтром на вхождение (для опечаток/эмодзи/регистра)
    const needle = queryName.toLowerCase().slice(0, 6);
    const scan = {
      structuredQuery: {
        from: [{ collectionId: "mascots", allDescendants: true }],
        select: { fields: [{ fieldPath: "name" }] },
        limit: 30000,
      },
    };
    r = await req("POST", "firestore.googleapis.com", `${FS_BASE}:runQuery`, scan, authHeaders(token));
    const all = (r.status === 200 ? JSON.parse(r.body) : []).filter((x) => x.document);
    console.log(`  (точных нет; просканировано mascot-доков: ${all.length}, ищу вхождение "${needle}")`);
    rows = all.filter((x) =>
      (fv(x.document.fields.name) || "").toLowerCase().includes(needle)
    );
  }
  const groups = new Map(); // gid -> mascotName
  for (const x of rows) {
    const m = x.document.name.match(/groups\/([^/]+)\/mascots\/([^/]+)/);
    if (m) groups.set(m[1], fv(x.document.fields.name));
  }
  return groups;
}

// Группы, где members содержит uid.
async function groupsForUid(token, uid) {
  const q = {
    structuredQuery: {
      from: [{ collectionId: "groups" }],
      where: {
        fieldFilter: {
          field: { fieldPath: "members" },
          op: "ARRAY_CONTAINS",
          value: { stringValue: uid },
        },
      },
    },
  };
  const r = await req(
    "POST",
    "firestore.googleapis.com",
    `${FS_BASE}:runQuery`,
    q,
    authHeaders(token)
  );
  if (r.status !== 200) throw new Error(`runQuery ${r.status}: ${r.body.slice(0, 200)}`);
  const rows = JSON.parse(r.body).filter((x) => x.document);
  return rows.map((x) => x.document);
}

function fv(field) {
  if (!field) return undefined;
  if ("stringValue" in field) return field.stringValue;
  if ("booleanValue" in field) return field.booleanValue;
  if ("integerValue" in field) return Number(field.integerValue);
  if ("timestampValue" in field) return field.timestampValue;
  if ("arrayValue" in field) return (field.arrayValue.values || []).map(fv);
  return field;
}

function docId(doc) {
  return doc.name.split("/").pop();
}

// Восстановить распущенные группы для набора (gid -> members).
async function restoreGroups(token, groups) {
  const writes = [];
  for (const [gid, members] of groups) {
    writes.push({
      update: {
        name: `projects/${PROJECT}/databases/(default)/documents/groups/${gid}`,
        fields: { disbanded: { booleanValue: false } },
      },
      updateMask: { fieldPaths: ["disbanded"] },
    });
    for (const m of members) {
      writes.push({
        transform: {
          document: `projects/${PROJECT}/databases/(default)/documents/users/${m}`,
          fieldTransforms: [
            {
              fieldPath: "pairIds",
              appendMissingElements: { values: [{ stringValue: gid }] },
            },
          ],
        },
      });
    }
  }
  if (!writes.length) return;
  const r = await req(
    "POST",
    "firestore.googleapis.com",
    `${FS_BASE}:commit`,
    { writes },
    authHeaders(token)
  );
  if (r.status !== 200) throw new Error(`commit ${r.status}: ${r.body.slice(0, 300)}`);
}

// Печать ключевых полей группы (дата/счётчики/название).
function printGroupFields(doc) {
  const f = doc.fields || {};
  const interesting = [
    "startDate", "anniversary", "anniversaryDate", "sinceDate", "togetherSince",
    "relationshipStart", "createdAt", "customRelationshipLabel", "name",
    "missYou", "missYouCount", "disbanded", "disbandedAt",
  ];
  for (const k of interesting) {
    if (f[k] !== undefined) console.log(`    ${k} = ${JSON.stringify(fv(f[k]))}`);
  }
}

// Вернуть группу в pairIds всех её текущих members (idempotent, disbanded не трогает).
async function fixPairIds(token, gid, members) {
  const writes = members.map((m) => ({
    transform: {
      document: `projects/${PROJECT}/databases/(default)/documents/users/${m}`,
      fieldTransforms: [
        { fieldPath: "pairIds", appendMissingElements: { values: [{ stringValue: gid }] } },
      ],
    },
  }));
  const r = await req("POST", "firestore.googleapis.com", `${FS_BASE}:commit`, { writes }, authHeaders(token));
  if (r.status !== 200) throw new Error(`commit ${r.status}: ${r.body.slice(0, 300)}`);
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd || !["lookup", "restore", "mascot", "group", "fixpair"].includes(cmd) || rest.length === 0) {
    console.log("Использование:");
    console.log("  node tools/admin_groups.js lookup  <email> [email2 ...]");
    console.log("  node tools/admin_groups.js restore <email> [email2 ...]");
    console.log("  node tools/admin_groups.js mascot  <имя_маскота>");
    console.log("  node tools/admin_groups.js group   <groupId> [groupId2 ...]");
    console.log("  node tools/admin_groups.js fixpair <groupId>   # вернуть группу в pairIds участников");
    process.exit(1);
  }
  const { token, email } = await getToken();
  console.log(`Авторизован как владелец: ${email}\n`);

  if (cmd === "group") {
    for (const gid of rest) {
      console.log(`=== Группа ${gid} ===`);
      const doc = await fetchGroup(token, gid);
      if (!doc) { console.log("  (не найдена)"); continue; }
      const members = fv(doc.fields.members) || [];
      const emails = await uidsToEmails(token, members);
      console.log(`  disbanded = ${fv(doc.fields.disbanded) === true}`);
      printGroupFields(doc);
      console.log("  ── участники ──");
      for (const m of members) {
        console.log(`  • ${m}  →  ${emails[m] || "(email не найден)"}`);
        const { status, doc: ud } = await fetchUser(token, m);
        if (status !== 200 || !ud) { console.log(`      users/${m}: НЕТ документа (status ${status})`); continue; }
        const uf = ud.fields || {};
        const name = fv(uf.name) ?? fv(uf.displayName) ?? "(нет имени)";
        const pairIds = fv(uf.pairIds) || [];
        const coins = fv(uf.coins);
        console.log(`      имя=${JSON.stringify(name)}  coins=${coins ?? "-"}`);
        console.log(`      pairIds=[${pairIds.join(", ")}]  содержит эту группу: ${pairIds.includes(gid)}`);
        console.log(`      всего полей в профиле: ${Object.keys(uf).length}`);
      }
      console.log("");
    }
    return;
  }

  if (cmd === "fixpair") {
    for (const gid of rest) {
      console.log(`=== fixpair ${gid} ===`);
      const doc = await fetchGroup(token, gid);
      if (!doc) { console.log("  (группа не найдена)"); continue; }
      if (fv(doc.fields.disbanded) === true) {
        console.log("  ⚠ группа disbanded=true — используй команду restore, а не fixpair");
        continue;
      }
      const members = fv(doc.fields.members) || [];
      const emails = await uidsToEmails(token, members);
      await fixPairIds(token, gid, members);
      console.log("  Готово. Группа возвращена в pairIds участников:");
      for (const m of members) console.log(`    ${m} → ${emails[m] || "?"}`);
    }
    return;
  }

  if (cmd === "mascot") {
    const name = rest.join(" ");
    console.log(`=== поиск маскота "${name}" ===`);
    const groups = await searchMascot(token, name);
    if (!groups.size) {
      console.log("Ничего не найдено.");
      return;
    }
    for (const [gid, mname] of groups) {
      console.log(`\n• Группа ${gid}  (маскот: "${mname}")`);
      const doc = await fetchGroup(token, gid);
      if (!doc) {
        console.log("    (не удалось прочитать документ группы)");
        continue;
      }
      const members = fv(doc.fields.members) || [];
      const emails = await uidsToEmails(token, members);
      console.log(`    disbanded = ${fv(doc.fields.disbanded) === true}`);
      console.log("    участники:");
      for (const m of members) console.log(`      ${m}  →  ${emails[m] || "(email не найден)"}`);
      printGroupFields(doc);
    }
    return;
  }

  const emails = rest;

  const toRestore = new Map(); // gid -> members[]
  for (const em of emails) {
    console.log(`=== ${em} ===`);
    let uid;
    try {
      uid = await emailToUid(token, em);
    } catch (e) {
      console.log(`  ✗ ошибка поиска: ${e.message}`);
      continue;
    }
    if (!uid) {
      console.log("  ✗ пользователь с таким email не найден в Auth");
      continue;
    }
    console.log(`  uid: ${uid}`);
    let docs;
    try {
      docs = await groupsForUid(token, uid);
    } catch (e) {
      console.log(`  ✗ ошибка запроса групп: ${e.message}`);
      continue;
    }
    if (!docs.length) {
      console.log("  групп не найдено (members не содержит uid)");
      continue;
    }
    for (const doc of docs) {
      const gid = docId(doc);
      const members = fv(doc.fields.members) || [];
      const disbanded = fv(doc.fields.disbanded) === true;
      console.log(
        `  группа ${gid}: members=[${members.join(", ")}] disbanded=${disbanded}`
      );
      if (disbanded) toRestore.set(gid, members);
    }
  }

  if (cmd === "restore") {
    if (!toRestore.size) {
      console.log("\nНечего восстанавливать — распущенных групп не найдено.");
      return;
    }
    console.log(`\nВосстанавливаю ${toRestore.size} групп(ы)…`);
    await restoreGroups(token, [...toRestore.entries()]);
    for (const gid of toRestore.keys()) console.log(`  ↻ ${gid}: disbanded=false, возвращена в pairIds`);
    console.log("Готово.");
  } else if (toRestore.size) {
    console.log(
      `\nНайдено распущенных групп: ${toRestore.size}. Чтобы восстановить — повтори с командой restore.`
    );
  }
}

main().catch((e) => {
  console.error("Сбой:", e.message);
  process.exit(1);
});
