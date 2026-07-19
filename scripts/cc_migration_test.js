// Backend end-to-end тест миграции Supabase (RLS + дуал-райт назначения).
// Создаёт 3 синтетических юзера (A,B — пара; C — чужой), обменивает на Firebase
// ID-токены и через PostgREST проверяет: связность, приём Firebase-токена
// (Third-Party Auth = Block 1), запись каждой функции-назначения, enforcement RLS.
// В конце всё удаляет. Тестовые данные помечены префиксом __cctest__.
//
// Запуск: node scripts/cc_migration_test.js

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

// ── Креды ────────────────────────────────────────────────────────────────
const svc = require('./serviceAccountKey.json');
admin.initializeApp({ credential: admin.credential.cert(svc) });

const root = path.join(__dirname, '..');
const cfg = fs.readFileSync(path.join(root, 'lib/config/migration_config.dart'), 'utf8');
const SB_URL = cfg.match(/https:\/\/[a-z0-9]+\.supabase\.co/)[0];
const SB_KEY = cfg.match(/sb_publishable_[A-Za-z0-9_]+/)[0];
const gsvc = JSON.parse(fs.readFileSync(path.join(root, 'android/app/google-services.json'), 'utf8'));
const WEB_API_KEY = gsvc.client[0].api_key[0].current_key;

const TAG = '__cctest__' + Date.now();
const results = [];
function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
  console.log(`${pass ? '✅ PASS' : '❌ FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
}

// ── Firebase ID-токен из uid (custom → exchange) ──────────────────────────
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

// ── PostgREST helpers ─────────────────────────────────────────────────────
function hdrs(token, extra = {}) {
  return { apikey: SB_KEY, Authorization: `Bearer ${token || SB_KEY}`,
    'Content-Type': 'application/json', ...extra };
}
async function sbGet(pathq, token) {
  const r = await fetch(`${SB_URL}/rest/v1/${pathq}`, { headers: hdrs(token) });
  const body = await r.text();
  let json; try { json = JSON.parse(body); } catch { json = body; }
  return { status: r.status, json };
}
async function sbWrite(method, pathq, token, body, prefer) {
  const extra = prefer ? { Prefer: prefer } : {};
  const r = await fetch(`${SB_URL}/rest/v1/${pathq}`,
    { method, headers: hdrs(token, extra), body: body ? JSON.stringify(body) : undefined });
  const txt = await r.text();
  let json; try { json = JSON.parse(txt); } catch { json = txt; }
  return { status: r.status, json };
}
const sbInsert = (t, tbl, row) => sbWrite('POST', tbl, t, row, 'return=representation,resolution=merge-duplicates');
const sbRpc = (t, name, params) => sbWrite('POST', `rpc/${name}`, t, params || {});
const ok = (s) => s >= 200 && s < 300;

// ── Тест ───────────────────────────────────────────────────────────────────
(async () => {
  const users = {};       // role → {uid, email, token}
  const G = `${TAG}_grp`;
  const today = new Date().toISOString().slice(0, 10);

  try {
    // Создаём 3 юзера в Firebase Auth
    for (const role of ['A', 'B', 'C']) {
      const email = `cc-mig-${role.toLowerCase()}-${Date.now()}@cctest.invalid`;
      const u = await admin.auth().createUser({ email, password: 'Test!' + Math.random().toString(36) });
      // ФИКС роли: Firebase-токен без claim role → Supabase даёт роль anon →
      // RLS (TO authenticated) не применяется. Выдаём role=authenticated.
      await admin.auth().setCustomUserClaims(u.uid, { role: 'authenticated' });
      users[role] = { uid: u.uid, email, token: await idTokenFor(u.uid) };
    }
    check('Firebase: создание 3 юзеров + ID-токены', true,
      `A=${users.A.uid.slice(0,6)} B=${users.B.uid.slice(0,6)} C=${users.C.uid.slice(0,6)}`);

    const A = users.A, B = users.B, C = users.C;

    // 0. Firebase connectivity (admin Firestore write/read/delete)
    try {
      const ref = admin.firestore().collection('__cctest').doc(TAG);
      await ref.set({ t: Date.now() });
      const snap = await ref.get();
      await ref.delete();
      check('Firebase: Firestore admin write/read/delete', snap.exists);
    } catch (e) { check('Firebase: Firestore admin write/read/delete', false, e.message); }

    // 1. Supabase принимает Firebase-токен (Third-Party Auth = Block 1)
    const auth = await sbGet('users?select=uid&limit=1', A.token);
    check('Supabase: принимает Firebase ID-токен (Block 1 / Third-Party Auth)',
      auth.status === 200, `HTTP ${auth.status}${auth.status===401?' → Third-Party Auth НЕ настроен':''}`);
    if (auth.status === 401) throw new Error('Third-Party Auth не настроен — дальше нет смысла');

    // 2. users: self-write
    for (const role of ['A', 'B', 'C']) {
      const u = users[role];
      const r = await sbInsert(u.token, 'users', { uid: u.uid, display_name: `cc-${role}`, email: u.email });
      check(`users: self-upsert (${role})`, ok(r.status), `HTTP ${r.status}`);
    }

    // 3. users RLS: A видит себя, C НЕ видит A (ещё не co-member)
    const aSelf = await sbGet(`users?uid=eq.${A.uid}&select=uid`, A.token);
    check('users RLS: A читает свою строку', aSelf.status===200 && aSelf.json.length===1);
    const cReadsA = await sbGet(`users?uid=eq.${A.uid}&select=uid`, C.token);
    check('users RLS: C НЕ видит чужую строку A', cReadsA.status===200 && cReadsA.json.length===0,
      `вернулось строк: ${Array.isArray(cReadsA.json)?cReadsA.json.length:'?'}`);

    // 4. groups: A создаёт группу [A,B]
    const gIns = await sbInsert(A.token, 'groups',
      { id: G, members: [A.uid, B.uid], member_names: { [A.uid]: 'cc-A', [B.uid]: 'cc-B' }, start_date: new Date().toISOString() });
    check('groups: A создаёт группу [A,B]', ok(gIns.status), `HTTP ${gIns.status}`);

    // 5. groups RLS: A и B видят; C — нет
    const aSeesG = await sbGet(`groups?id=eq.${G}&select=id`, A.token);
    const bSeesG = await sbGet(`groups?id=eq.${G}&select=id`, B.token);
    const cSeesG = await sbGet(`groups?id=eq.${G}&select=id`, C.token);
    check('groups RLS: A (член) видит группу', aSeesG.json.length===1);
    check('groups RLS: B (член) видит группу', bSeesG.json.length===1);
    check('groups RLS: C (чужой) НЕ видит группу', cSeesG.json.length===0,
      `вернулось строк: ${Array.isArray(cSeesG.json)?cSeesG.json.length:'?'}`);

    // 6. Member-поля через RPC (mood/name/avatar/birthday)
    const moodR = await sbRpc(A.token, 'group_set_member_mood',
      { p_group_id: G, p_uid: A.uid, p_mood: { id: 'happy', emoji: '😀', label: 'Счастлив', updatedAt: new Date().toISOString() } });
    const moodBack = await sbGet(`groups?id=eq.${G}&select=member_moods`, A.token);
    check('RPC group_set_member_mood', ok(moodR.status) && moodBack.json[0]?.member_moods?.[A.uid]?.emoji==='😀', `HTTP ${moodR.status}`);
    check('RPC group_set_member_name', ok((await sbRpc(A.token,'group_set_member_name',{p_group_id:G,p_uid:A.uid,p_name:'cc-A-new'})).status));
    check('RPC group_set_member_avatar', ok((await sbRpc(A.token,'group_set_member_avatar',{p_group_id:G,p_uid:A.uid,p_url:'https://x/a.png'})).status));
    check('RPC group_set_member_birthday', ok((await sbRpc(A.token,'group_set_member_birthday',{p_group_id:G,p_uid:A.uid,p_date:'1995-05-05T00:00:00Z'})).status));
    check('RPC group_clear_member_mood', ok((await sbRpc(A.token,'group_clear_member_mood',{p_group_id:G,p_uid:A.uid})).status));

    // 7. Счётчики + активность
    const incR = await sbRpc(A.token, 'group_inc_counters', { p_group_id: G, p_memories: 1, p_drawings: 0 });
    const incBack = await sbGet(`groups?id=eq.${G}&select=memories_count`, A.token);
    check('RPC group_inc_counters', ok(incR.status) && incBack.json[0]?.memories_count===1, `count=${incBack.json[0]?.memories_count}`);
    check('RPC group_record_activity', ok((await sbRpc(A.token,'group_record_activity',{p_group_id:G,p_today:today})).status));

    // 8. Память + patch
    const memId = `${TAG}_mem`;
    const memIns = await sbInsert(A.token, 'memories',
      { id: memId, group_id: G, type: 'note', author_uid: A.uid, author_name: 'cc-A', created_at: new Date().toISOString(), data: { text: 'привет' } });
    check('memories: insert (A)', ok(memIns.status), `HTTP ${memIns.status}`);
    check('RPC memory_patch', ok((await sbRpc(A.token,'memory_patch',{p_id:memId,p_patch:{text:'правка'}})).status));
    const cReadsMem = await sbGet(`memories?id=eq.${memId}&select=id`, C.token);
    check('memories RLS: C НЕ видит память чужой группы', cReadsMem.json.length===0,
      `строк: ${Array.isArray(cReadsMem.json)?cReadsMem.json.length:'?'}`);

    // 9. Настроения (mood_entries)
    const meId = `${TAG}_mood`;
    check('mood_entries: insert (A)', ok((await sbInsert(A.token,'mood_entries',
      { id: meId, group_id: G, user_uid: A.uid, mood_id: 'happy', label: 'ок', timestamp: new Date().toISOString() })).status));

    // 10. Чат + реакция
    const msgId = `${TAG}_msg`;
    check('chat_messages: insert (A)', ok((await sbInsert(A.token,'chat_messages',
      { id: msgId, group_id: G, user_uid: A.uid, user_name: 'cc-A', text: 'йо', ts: Date.now() })).status));
    check('RPC chat_set_reaction', ok((await sbRpc(A.token,'chat_set_reaction',{p_id:msgId,p_uid:A.uid,p_emoji:'❤️'})).status));

    // 11. Miss-you
    const myR = await sbRpc(A.token, 'increment_miss_you', { p_group_id: G, p_user_uid: A.uid });
    const myBack = await sbGet(`miss_you?group_id=eq.${G}&user_uid=eq.${A.uid}&select=count`, A.token);
    check('RPC increment_miss_you', ok(myR.status) && myBack.json[0]?.count===1, `count=${myBack.json[0]?.count}`);

    // 12. Widget data
    check('widget_data: upsert (A)', ok((await sbInsert(A.token,'widget_data',
      { group_id: G, user_uid: A.uid, display_name: 'cc-A', mood_emoji: '😀' })).status));

    // 13. Коины (SECURITY DEFINER + app_require_uid). grant_dev_coins — dev-only,
    // поэтому проверяем grant_daily_bonus (доступен любому).
    const bonus = await sbRpc(A.token, 'grant_daily_bonus', { p_uid: A.uid });
    const coinsBack = await sbGet(`users?uid=eq.${A.uid}&select=coins`, A.token);
    check('RPC grant_daily_bonus (A себе)', ok(bonus.status), `HTTP ${bonus.status}, coins=${coinsBack.json[0]?.coins}`);

    // ── RLS NEGATIVE (главное: чужой НЕ может) ──────────────────────────────
    const cMood = await sbRpc(C.token, 'group_set_member_mood',
      { p_group_id: G, p_uid: C.uid, p_mood: { emoji: '😈' } });
    const moodAfterC = await sbGet(`groups?id=eq.${G}&select=member_moods`, A.token);
    const cInjected = !!moodAfterC.json[0]?.member_moods?.[C.uid];
    check('RLS−: C НЕ может писать mood в чужую группу', !cInjected, `инъекция произошла: ${cInjected}`);

    const cMemIns = await sbInsert(C.token, 'memories',
      { id: `${TAG}_hack`, group_id: G, author_uid: C.uid, data: {} });
    const hackRow = await sbGet(`memories?id=eq.${TAG}_hack&select=id`, A.token);
    check('RLS−: C НЕ может вставить память в чужую группу', hackRow.json.length===0, `HTTP ${cMemIns.status}`);

    const cCoins = await sbRpc(C.token, 'grant_dev_coins', { p_uid: A.uid });
    check('RLS−: C НЕ может начислить коины от имени A', !ok(cCoins.status),
      `HTTP ${cCoins.status} (ожидаем ошибку app_require_uid)`);

    const anon = await sbGet(`groups?id=eq.${G}&select=id`, null);
    check('RLS−: anon (без токена) НЕ видит группу', Array.isArray(anon.json) && anon.json.length===0,
      `HTTP ${anon.status}, строк: ${Array.isArray(anon.json)?anon.json.length:'?'}`);

  } catch (e) {
    check('FATAL', false, e.message);
  } finally {
    // ── Очистка ──────────────────────────────────────────────────────────
    console.log('\n— очистка тестовых данных —');
    try {
      const A = users.A, B = users.B, C = users.C;
      if (A) {
        for (const tbl of ['memories', 'mood_entries', 'chat_messages', 'miss_you', 'widget_data']) {
          await sbWrite('DELETE', `${tbl}?group_id=eq.${G}`, A.token);
        }
        await sbWrite('DELETE', `groups?id=eq.${G}`, A.token);
      }
      for (const role of ['A','B','C']) {
        const u = users[role];
        if (!u) continue;
        await sbWrite('DELETE', `users?uid=eq.${u.uid}`, u.token);
        await admin.auth().deleteUser(u.uid).catch(()=>{});
      }
      console.log('очистка завершена');
    } catch (e) { console.log('очистка частична:', e.message); }

    const passed = results.filter(r => r.pass).length;
    const failed = results.filter(r => !r.pass);
    console.log(`\n══ ИТОГ: ${passed}/${results.length} PASS ══`);
    if (failed.length) {
      console.log('Провалено:');
      failed.forEach(f => console.log(`  ❌ ${f.name}${f.detail?' — '+f.detail:''}`));
    }
    process.exit(failed.length ? 1 : 0);
  }
})();
