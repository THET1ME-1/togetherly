// Матрица совместимости сборок партнёров для миграции FB→Supabase.
// Проверяет ЧТЕНИЕ/ЗАПИСЬ между двумя партнёрами в трёх топологиях:
//   • старый+старый  — оба пишут/читают ТОЛЬКО Firestore (legacy);
//   • новый+старый   — старый пишет Firestore; новый пишет Firestore + зеркало
//                       Supabase. Критично: пара ОБЯЗАНА видеть друг друга через
//                       Firestore (мост), иначе после апдейта партнёр «пропадает»;
//   • новый+новый    — оба пишут Firestore + Supabase (плоскость Supabase отдельно
//                       доказана cc_migrated_pair_test 36/36).
//
// Firestore читаем/пишем через REST с РЕАЛЬНЫМИ ID-токенами → ПРАВИЛА
// ПРИМЕНЯЮТСЯ (не admin-обход). Этим заодно бисектим риск только что
// передеплоенного firestore.rules: ломают ли новые правила co-member чтения.
// Supabase-зеркало — через REST. Создаёт 3 синтет-юзера (A,B новый/старый + C
// посторонний для negative-теста), всё за собой чистит.
//
// Запуск:
//   cp scripts/togetherly-d4856-firebase-adminsdk-*.json scripts/serviceAccountKey.json  (или уже лежит)
//   NODE_PATH=./functions/node_modules node scripts/cc_compat_matrix_test.js
//   rm scripts/serviceAccountKey.json

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

const svc = require('./serviceAccountKey.json');
admin.initializeApp({ credential: admin.credential.cert(svc) });

const PROJECT = svc.project_id;
const root = path.join(__dirname, '..');
const cfg = fs.readFileSync(path.join(root, 'lib/config/migration_config.dart'), 'utf8');
const SB_URL = cfg.match(/https:\/\/[a-z0-9]+\.supabase\.co/)[0];
const SB_KEY = cfg.match(/sb_publishable_[A-Za-z0-9_]+/)[0];
const gsvc = JSON.parse(fs.readFileSync(path.join(root, 'android/app/google-services.json'), 'utf8'));
const WEB_API_KEY = gsvc.client[0].api_key[0].current_key;
const FS = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;

const TAG = '__cccompat__' + Date.now();
const results = [];
function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
  console.log(`${pass ? '✅ PASS' : '❌ FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
}
const ok = (s) => s >= 200 && s < 300;

async function idTokenFor(uid) {
  const custom = await admin.auth().createCustomToken(uid);
  const r = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${WEB_API_KEY}`,
    { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: custom, returnSecureToken: true }) });
  const j = await r.json();
  if (!j.idToken) throw new Error('token exchange failed: ' + JSON.stringify(j));
  return j.idToken;
}

// ── Firestore REST: типизированные значения ──────────────────────────────────
function enc(v) {
  if (v === null) return { nullValue: null };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v)
    ? { integerValue: String(v) } : { doubleValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(enc) } };
  if (typeof v === 'object') return { mapValue: { fields: encFields(v) } };
  return { stringValue: String(v) };
}
function encFields(obj) {
  const f = {};
  for (const [k, val] of Object.entries(obj)) f[k] = enc(val);
  return f;
}
function decField(field) {
  if (!field) return undefined;
  const t = Object.keys(field)[0];
  const v = field[t];
  if (t === 'integerValue') return Number(v);
  if (t === 'arrayValue') return (v.values || []).map(decField);
  if (t === 'mapValue') return decDoc({ fields: v.fields });
  return v;
}
function decDoc(doc) {
  const out = {};
  for (const [k, val] of Object.entries(doc.fields || {})) out[k] = decField(val);
  return out;
}
// PATCH создаёт/обновляет документ по известному пути (id в пути).
async function fsWrite(docPath, token, obj) {
  const r = await fetch(`${FS}/${docPath}`, {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields: encFields(obj) }),
  });
  return { status: r.status, body: await r.text() };
}
async function fsRead(docPath, token) {
  const r = await fetch(`${FS}/${docPath}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const txt = await r.text();
  let json; try { json = JSON.parse(txt); } catch { json = {}; }
  return { status: r.status, data: json.fields ? decDoc(json) : null };
}
async function fsDelete(docPath, token) {
  await fetch(`${FS}/${docPath}`, { method: 'DELETE',
    headers: { Authorization: `Bearer ${token}` } }).catch(() => {});
}

// ── Supabase REST (зеркало нового клиента) ───────────────────────────────────
function sbHdrs(token, extra = {}) {
  return { apikey: SB_KEY, Authorization: `Bearer ${token || SB_KEY}`,
    'Content-Type': 'application/json', ...extra };
}
async function sbInsert(token, tbl, row) {
  const r = await fetch(`${SB_URL}/rest/v1/${tbl}`, { method: 'POST',
    headers: sbHdrs(token, { Prefer: 'return=representation,resolution=merge-duplicates' }),
    body: JSON.stringify(row) });
  return { status: r.status, body: await r.text() };
}
async function sbGet(pathq, token) {
  const r = await fetch(`${SB_URL}/rest/v1/${pathq}`, { headers: sbHdrs(token) });
  let json; try { json = JSON.parse(await r.text()); } catch { json = []; }
  return { status: r.status, rows: Array.isArray(json) ? json : [] };
}
async function sbDel(pathq, token) {
  await fetch(`${SB_URL}/rest/v1/${pathq}`, { method: 'DELETE', headers: sbHdrs(token) })
    .catch(() => {});
}

(async () => {
  const U = {};
  const G = `${TAG}_grp`;
  const nowIso = () => new Date().toISOString();
  try {
    // ── 3 юзера: A,B партнёры; C посторонний (negative) ──────────────────────
    for (const role of ['A', 'B', 'C']) {
      const email = `cc-compat-${role.toLowerCase()}-${Date.now()}@cctest.invalid`;
      const u = await admin.auth().createUser({ email, password: 'T!' + Math.random().toString(36) });
      await admin.auth().setCustomUserClaims(u.uid, { role: 'authenticated' });
      U[role] = { uid: u.uid, token: await idTokenFor(u.uid) };
    }
    const A = U.A, B = U.B, C = U.C;
    check('Firebase: 3 юзера + токены (A,B пара; C посторонний)', true,
      `A=${A.uid.slice(0,6)} B=${B.uid.slice(0,6)} C=${C.uid.slice(0,6)}`);

    // ── Группа [A,B] в Firestore ─────────────────────────────────────────────
    const gw = await fsWrite(`groups/${G}`, A.token,
      { members: [A.uid, B.uid], memberNames: { [A.uid]: 'cc-A', [B.uid]: 'cc-B' },
        createdAt: nowIso() });
    check('Firestore rules: A создаёт группу [A,B]', ok(gw.status), `HTTP ${gw.status}`);
    check('Firestore rules: B (участник) читает группу',
      ok((await fsRead(`groups/${G}`, B.token)).status));
    // negative: посторонний C НЕ читает группу (members не содержит C)
    check('Firestore rules −: посторонний C НЕ читает группу пары',
      (await fsRead(`groups/${G}`, C.token)).status === 403, 'ожидаем 403');

    // ═══ ТОПОЛОГИЯ 1: СТАРЫЙ + СТАРЫЙ (только Firestore) ═════════════════════
    // Старый билд: ни маркера sbMig, ни зеркала Supabase — всё в Firestore.
    const memOldA = `${TAG}_oldA`, memOldB = `${TAG}_oldB`;
    await fsWrite(`groups/${G}/memories/${memOldA}`, A.token,
      { type: 'note', authorUid: A.uid, text: 'старый A', createdAt: nowIso() });
    const rOldByB = await fsRead(`groups/${G}/memories/${memOldA}`, B.token);
    check('old+old: A пишет воспоминание (Firestore) → B читает',
      ok(rOldByB.status) && rOldByB.data?.text === 'старый A');
    await fsWrite(`groups/${G}/memories/${memOldB}`, B.token,
      { type: 'note', authorUid: B.uid, text: 'старый B', createdAt: nowIso() });
    const rOldByA = await fsRead(`groups/${G}/memories/${memOldB}`, A.token);
    check('old+old: B пишет воспоминание (Firestore) → A читает',
      ok(rOldByA.status) && rOldByA.data?.text === 'старый B');
    // mood-календарь: B пишет своё → A (участник) читает
    await fsWrite(`groups/${G}/moodCalendar/${B.uid}/entries/${TAG}_mB`, B.token,
      { moodId: 'happy', label: 'ок', ts: nowIso() });
    check('old+old: B пишет mood → A читает',
      ok((await fsRead(`groups/${G}/moodCalendar/${B.uid}/entries/${TAG}_mB`, A.token)).status));
    // widgetData: A пишет свой → B читает
    await fsWrite(`groups/${G}/widgetData/${A.uid}`, A.token,
      { displayName: 'cc-A', moodEmoji: '😀', updatedAt: nowIso() });
    check('old+old: A пишет widgetData → B читает',
      ok((await fsRead(`groups/${G}/widgetData/${A.uid}`, B.token)).status));
    // negative: C не может писать в memories пары
    const cWrite = await fsWrite(`groups/${G}/memories/${TAG}_cHack`, C.token,
      { text: 'hack', createdAt: nowIso() });
    check('old+old −: посторонний C НЕ пишет в memories пары',
      cWrite.status === 403, `ожидаем 403, HTTP ${cWrite.status}`);

    // ═══ ТОПОЛОГИЯ 2: НОВЫЙ + СТАРЫЙ (мост через Firestore) ══════════════════
    // Новый клиент (A): пишет Firestore + зеркалит Supabase + ставит маркер
    // sbMig[A]. Старый (B): только Firestore, без маркера → пара СМЕШАННАЯ
    // (allFresh=false) → источник остаётся Firestore у обоих.
    await fsWrite(`groups/${G}`, A.token,
      { members: [A.uid, B.uid], sbMig: { [A.uid]: nowIso() } }); // только A пометил себя
    const gDoc = await fsRead(`groups/${G}`, A.token);
    const sbMigKeys = Object.keys(gDoc.data?.sbMig || {});
    check('new+old: маркер sbMig стоит ТОЛЬКО у нового (A) → пара смешанная',
      sbMigKeys.length === 1 && sbMigKeys[0] === A.uid, `маркеры: ${sbMigKeys.length}`);
    // Новый A пишет воспоминание В FIRESTORE (мост) + зеркало Supabase
    const memNewA = `${TAG}_newA`;
    const wFs = await fsWrite(`groups/${G}/memories/${memNewA}`, A.token,
      { type: 'note', authorUid: A.uid, text: 'новый A мост', createdAt: nowIso() });
    check('new+old: новый A пишет воспоминание в Firestore (мост)', ok(wFs.status));
    // ── КРИТИЧНО: старый B видит запись нового A через Firestore ──
    const seenByOldB = await fsRead(`groups/${G}/memories/${memNewA}`, B.token);
    check('new+old ★ старый B ВИДИТ воспоминание нового A (через Firestore)',
      ok(seenByOldB.status) && seenByOldB.data?.text === 'новый A мост');
    // ── КРИТИЧНО: новый A видит запись старого B (читает Firestore, не Supabase) ──
    const seenByNewA = await fsRead(`groups/${G}/memories/${memOldB}`, A.token);
    check('new+old ★ новый A ВИДИТ воспоминание старого B (через Firestore)',
      ok(seenByNewA.status) && seenByNewA.data?.text === 'старый B');
    // Зеркало нового A засеяно в Supabase (для будущего флипа в new+new)
    await admin.firestore(); // no-op, ensure init
    await sbInsert(A.token, 'groups',
      { id: G, members: [A.uid, B.uid], start_date: nowIso() });
    const mir = await sbInsert(A.token, 'memories',
      { id: memNewA, group_id: G, type: 'note', author_uid: A.uid, author_name: 'cc-A',
        created_at: nowIso(), data: { text: 'новый A мост' } });
    check('new+old: зеркало нового A засеяно в Supabase (для будущего флипа)',
      ok(mir.status), `HTTP ${mir.status}`);
    // Старого B в Supabase ПОКА НЕТ (старый клиент не зеркалит) — это норма,
    // его докатит бэкфилл при флипе. Подтверждаем расхождение явно.
    const oldBInSb = await sbGet(`memories?id=eq.${memOldB}&select=id`, A.token);
    check('new+old: запись старого B ещё НЕ в Supabase (докатит бэкфилл) — ожидаемо',
      oldBInSb.rows.length === 0);

    // ═══ ТОПОЛОГИЯ 3: НОВЫЙ + НОВЫЙ (оба пометились, оба зеркалят) ═══════════
    // Оба ставят свежий маркер → allFresh=true → группа имеет право на Supabase
    // (флип на след. сессии). Бэкфилл копирует Firestore-данные в Supabase.
    await fsWrite(`groups/${G}`, A.token,
      { members: [A.uid, B.uid], sbMig: { [A.uid]: nowIso() } });
    await fsWrite(`groups/${G}`, B.token,
      { members: [A.uid, B.uid], sbMig: { [A.uid]: nowIso(), [B.uid]: nowIso() } });
    const gDoc2 = await fsRead(`groups/${G}`, A.token);
    const keys2 = Object.keys(gDoc2.data?.sbMig || {}).sort();
    check('new+new: оба партнёра пометились sbMig → allFresh (право на Supabase)',
      keys2.length === 2 && keys2.includes(A.uid) && keys2.includes(B.uid));
    // Эмуляция бэкфилла: запись старого B копируется в Supabase → теперь видна обоим
    const back = await sbInsert(A.token, 'memories',
      { id: memOldB, group_id: G, type: 'note', author_uid: B.uid, author_name: 'cc-B',
        created_at: nowIso(), data: { text: 'старый B' } });
    check('new+new: бэкфилл копирует прежнюю Firestore-запись B в Supabase', ok(back.status));
    const bothInSb = await sbGet(`memories?group_id=eq.${G}&select=id&order=id`, B.token);
    check('new+new ★ обе записи (A и B) видны в Supabase обоим партнёрам',
      bothInSb.rows.length >= 2, `строк в Supabase: ${bothInSb.rows.length}`);

  } catch (e) {
    check('FATAL', false, e.message);
  } finally {
    console.log('\n— очистка —');
    try {
      const A = U.A;
      // Firestore
      for (const p of [
        `groups/${G}/memories/${TAG}_oldA`, `groups/${G}/memories/${TAG}_oldB`,
        `groups/${G}/memories/${TAG}_newA`,
        `groups/${G}/moodCalendar/${U.B?.uid}/entries/${TAG}_mB`,
        `groups/${G}/widgetData/${U.A?.uid}`, `groups/${G}`]) {
        if (A) await fsDelete(p, A.token);
      }
      // Supabase
      if (A) { await sbDel(`memories?group_id=eq.${G}`, A.token); await sbDel(`groups?id=eq.${G}`, A.token); }
      for (const role of ['A', 'B', 'C']) {
        if (U[role]) await admin.auth().deleteUser(U[role].uid).catch(() => {});
      }
      console.log('очистка завершена');
    } catch (e) { console.log('очистка частична:', e.message); }

    const passed = results.filter(r => r.pass).length;
    const failed = results.filter(r => !r.pass);
    console.log(`\n══ ИТОГ: ${passed}/${results.length} PASS ══`);
    if (failed.length) {
      console.log('Провалено:');
      failed.forEach(f => console.log(`  ❌ ${f.name}${f.detail ? ' — ' + f.detail : ''}`));
    }
    process.exit(failed.length ? 1 : 0);
  }
})();
