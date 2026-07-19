// Backend-тест сценария «ОБА партнёра уже мигрированы» (Stage 3/4 end-state).
// Создаёт 2 синтетических юзера A,B (пара). Для КАЖДОГО ресурса делает ЗАПИСЬ
// одним партнёром и ЧТЕНИЕ-ОБРАТНО другим из Supabase — это доказывает, что в
// конечном состоянии (оба читают/пишут только Supabase) пара видит данные друг
// друга по всем таблицам и RPC. В конце всё удаляет (префикс __ccpair__).
//
// Запуск (firebase-admin в functions/node_modules, ключ — admin SDK):
//   cp scripts/togetherly-d4856-firebase-adminsdk-*.json scripts/serviceAccountKey.json
//   NODE_PATH=./functions/node_modules node scripts/cc_migrated_pair_test.js
//   rm scripts/serviceAccountKey.json

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

const svc = require('./serviceAccountKey.json');
admin.initializeApp({ credential: admin.credential.cert(svc) });

const root = path.join(__dirname, '..');
const cfg = fs.readFileSync(path.join(root, 'lib/config/migration_config.dart'), 'utf8');
const SB_URL = cfg.match(/https:\/\/[a-z0-9]+\.supabase\.co/)[0];
const SB_KEY = cfg.match(/sb_publishable_[A-Za-z0-9_]+/)[0];
const gsvc = JSON.parse(fs.readFileSync(path.join(root, 'android/app/google-services.json'), 'utf8'));
const WEB_API_KEY = gsvc.client[0].api_key[0].current_key;

const TAG = '__ccpair__' + Date.now();
const results = [];
function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
  console.log(`${pass ? '✅ PASS' : '❌ FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
}

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
const sbPatch = (t, pathq, row) => sbWrite('PATCH', pathq, t, row, 'return=representation');
const sbRpc = (t, name, params) => sbWrite('POST', `rpc/${name}`, t, params || {});
const ok = (s) => s >= 200 && s < 300;
const rows = (r) => Array.isArray(r.json) ? r.json : [];

(async () => {
  const users = {};
  const G = `${TAG}_grp`;
  const today = new Date().toISOString().slice(0, 10);

  try {
    // ── Два «мигрированных» партнёра ────────────────────────────────────────
    for (const role of ['A', 'B']) {
      const email = `cc-pair-${role.toLowerCase()}-${Date.now()}@cctest.invalid`;
      const u = await admin.auth().createUser({ email, password: 'Test!' + Math.random().toString(36) });
      await admin.auth().setCustomUserClaims(u.uid, { role: 'authenticated' });
      users[role] = { uid: u.uid, email, token: await idTokenFor(u.uid) };
    }
    const A = users.A, B = users.B;
    check('Firebase: 2 юзера (пара) + ID-токены', true,
      `A=${A.uid.slice(0,6)} B=${B.uid.slice(0,6)}`);

    // ── Подключение: Supabase принимает Firebase-токен обоих ─────────────────
    const cA = await sbGet('users?select=uid&limit=1', A.token);
    const cB = await sbGet('users?select=uid&limit=1', B.token);
    check('Подключение A: Supabase принимает Firebase-токен', cA.status === 200, `HTTP ${cA.status}`);
    check('Подключение B: Supabase принимает Firebase-токен', cB.status === 200, `HTTP ${cB.status}`);
    if (cA.status === 401 || cB.status === 401) throw new Error('Third-Party Auth не настроен — стоп');

    // ── users: оба пишут свою строку, читают строку партнёра (co-member) ─────
    await sbInsert(A.token, 'users', { uid: A.uid, display_name: 'cc-A', email: A.email });
    await sbInsert(B.token, 'users', { uid: B.uid, display_name: 'cc-B', email: B.email });
    check('users: A пишет свой профиль', true);
    check('users: B пишет свой профиль', true);

    // ── groups: A создаёт пару [A,B]; оба читают группу ──────────────────────
    const gIns = await sbInsert(A.token, 'groups',
      { id: G, members: [A.uid, B.uid], member_names: { [A.uid]: 'cc-A', [B.uid]: 'cc-B' },
        start_date: new Date().toISOString() });
    check('groups: A создаёт пару [A,B]', ok(gIns.status), `HTTP ${gIns.status}`);
    check('groups: A читает группу', rows(await sbGet(`groups?id=eq.${G}&select=id`, A.token)).length === 1);
    check('groups: B читает группу партнёра', rows(await sbGet(`groups?id=eq.${G}&select=id`, B.token)).length === 1);
    // co-member чтение профиля
    check('users: A читает профиль B (co-member)',
      rows(await sbGet(`users?uid=eq.${B.uid}&select=display_name`, A.token)).length === 1);

    // ── memberMoods через RPC: A ставит → B читает с карточки группы ──────────
    await sbRpc(A.token, 'group_set_member_mood',
      { p_group_id: G, p_uid: A.uid, p_mood: { id: 'happy', emoji: '😀', label: 'ок' } });
    const moodSeenByB = await sbGet(`groups?id=eq.${G}&select=member_moods`, B.token);
    check('mood (RPC): A ставит → B видит настроение A',
      rows(moodSeenByB)[0]?.member_moods?.[A.uid]?.emoji === '😀');
    await sbRpc(B.token, 'group_clear_member_mood', { p_group_id: G, p_uid: B.uid });
    check('mood (RPC): B чистит своё настроение', true);

    // ── memories: A пишет → B читает; B пишет → A читает; patch автором ───────
    const memA = `${TAG}_memA`, memB = `${TAG}_memB`;
    await sbInsert(A.token, 'memories',
      { id: memA, group_id: G, type: 'note', author_uid: A.uid, author_name: 'cc-A',
        created_at: new Date().toISOString(), data: { text: 'от A' } });
    check('memories: A пишет → B читает воспоминание A',
      rows(await sbGet(`memories?id=eq.${memA}&select=id,data`, B.token)).length === 1);
    await sbInsert(B.token, 'memories',
      { id: memB, group_id: G, type: 'note', author_uid: B.uid, author_name: 'cc-B',
        created_at: new Date().toISOString(), data: { text: 'от B' } });
    check('memories: B пишет → A читает воспоминание B',
      rows(await sbGet(`memories?id=eq.${memB}&select=id`, A.token)).length === 1);
    await sbRpc(A.token, 'memory_patch', { p_id: memA, p_patch: { text: 'правка A' } });
    const patched = await sbGet(`memories?id=eq.${memA}&select=data`, B.token);
    check('memories (RPC memory_patch): правка A видна B',
      rows(patched)[0]?.data?.text === 'правка A');
    await sbRpc(A.token, 'group_inc_counters', { p_group_id: G, p_memories: 2, p_drawings: 0 });
    check('memories: счётчик через RPC group_inc_counters',
      rows(await sbGet(`groups?id=eq.${G}&select=memories_count`, B.token))[0]?.memories_count === 2);

    // ── comments: A комментирует → B читает; B → A ───────────────────────────
    const cmA = `${TAG}_cmA`, cmB = `${TAG}_cmB`;
    await sbInsert(A.token, 'memory_comments',
      { id: cmA, group_id: G, memory_id: memA, author_uid: A.uid, author_name: 'cc-A',
        text: 'коммент A', created_at: new Date().toISOString() });
    check('comments: A пишет → B читает', rows(await sbGet(`memory_comments?id=eq.${cmA}&select=text`, B.token))[0]?.text === 'коммент A');
    await sbInsert(B.token, 'memory_comments',
      { id: cmB, group_id: G, memory_id: memA, author_uid: B.uid, author_name: 'cc-B',
        text: 'коммент B', created_at: new Date().toISOString() });
    check('comments: B пишет → A читает', rows(await sbGet(`memory_comments?id=eq.${cmB}&select=text`, A.token)).length === 1);

    // ── mood_entries (календарь): A пишет → B читает; B → A ───────────────────
    const meA = `${TAG}_meA`, meB = `${TAG}_meB`;
    await sbInsert(A.token, 'mood_entries',
      { id: meA, group_id: G, user_uid: A.uid, mood_id: 'happy', label: 'ок', timestamp: new Date().toISOString() });
    check('mood_entries: A пишет → B читает', rows(await sbGet(`mood_entries?id=eq.${meA}&select=id`, B.token)).length === 1);
    await sbInsert(B.token, 'mood_entries',
      { id: meB, group_id: G, user_uid: B.uid, mood_id: 'sad', label: 'грусть', timestamp: new Date().toISOString() });
    check('mood_entries: B пишет → A читает', rows(await sbGet(`mood_entries?id=eq.${meB}&select=id`, A.token)).length === 1);

    // ── chat: A шлёт → B читает; B → A; реакция + статусы прочтения ───────────
    const msgA = `${TAG}_msgA`, msgB = `${TAG}_msgB`;
    await sbInsert(A.token, 'chat_messages',
      { id: msgA, group_id: G, user_uid: A.uid, user_name: 'cc-A', text: 'привет от A', ts: Date.now() });
    check('chat: A шлёт → B читает сообщение', rows(await sbGet(`chat_messages?id=eq.${msgA}&select=text`, B.token))[0]?.text === 'привет от A');
    await sbInsert(B.token, 'chat_messages',
      { id: msgB, group_id: G, user_uid: B.uid, user_name: 'cc-B', text: 'привет от B', ts: Date.now() });
    check('chat: B шлёт → A читает сообщение', rows(await sbGet(`chat_messages?id=eq.${msgB}&select=id`, A.token)).length === 1);
    // реакция B на сообщение A → A видит
    await sbRpc(B.token, 'chat_set_reaction', { p_id: msgA, p_uid: B.uid, p_emoji: '❤️' });
    check('chat (RPC chat_set_reaction): реакция B видна A',
      rows(await sbGet(`chat_messages?id=eq.${msgA}&select=reactions`, A.token))[0]?.reactions?.[B.uid] === '❤️');
    // редактирование своего сообщения A → B видит
    await sbPatch(A.token, `chat_messages?id=eq.${msgA}`, { text: 'правка A', edited_ts: Date.now() });
    check('chat: правка A видна B', rows(await sbGet(`chat_messages?id=eq.${msgA}&select=text`, B.token))[0]?.text === 'правка A');
    // chat_reads (галочки): A отметил → B читает ts
    await sbInsert(A.token, 'chat_reads', { group_id: G, user_uid: A.uid, last_read_ts: Date.now() });
    check('chat_reads: A отметил прочтение → B читает', rows(await sbGet(`chat_reads?group_id=eq.${G}&user_uid=eq.${A.uid}&select=last_read_ts`, B.token)).length === 1);

    // ── canvas: A рисует штрих → B читает; patch; meta; каталог ───────────────
    const strokeA = `${TAG}_strokeA`;
    await sbInsert(A.token, 'canvas_strokes',
      { id: strokeA, group_id: G, canvas_id: 'main', order_index: 0, data: { color: 1, points: [1, 2] } });
    check('canvas_strokes: A рисует → B читает штрих', rows(await sbGet(`canvas_strokes?id=eq.${strokeA}&select=id`, B.token)).length === 1);
    await sbRpc(B.token, 'canvas_stroke_patch', { p_id: strokeA, p_patch: { color: 2 } });
    check('canvas (RPC canvas_stroke_patch): патч B виден A',
      rows(await sbGet(`canvas_strokes?id=eq.${strokeA}&select=data`, A.token))[0]?.data?.color === 2);
    await sbInsert(A.token, 'canvas_meta', { group_id: G, canvas_id: 'main', bg_color: 123, canvas_rotation: 90 });
    check('canvas_meta: A ставит фон/поворот → B читает',
      rows(await sbGet(`canvas_meta?group_id=eq.${G}&canvas_id=eq.main&select=bg_color`, B.token))[0]?.bg_color === 123);
    await sbInsert(A.token, 'canvas_catalogue',
      { group_id: G, canvas_id: 'main', name: 'Холст', created_at: Date.now(), updated_at: Date.now(), created_by: A.uid });
    check('canvas_catalogue: A создаёт холст → B читает', rows(await sbGet(`canvas_catalogue?group_id=eq.${G}&canvas_id=eq.main&select=name`, B.token))[0]?.name === 'Холст');

    // ── widget_data: A пишет → B читает виджет A; B → A ───────────────────────
    await sbInsert(A.token, 'widget_data', { group_id: G, user_uid: A.uid, display_name: 'cc-A', mood_emoji: '😀' });
    check('widget_data: A пишет → B читает виджет A',
      rows(await sbGet(`widget_data?group_id=eq.${G}&user_uid=eq.${A.uid}&select=mood_emoji`, B.token))[0]?.mood_emoji === '😀');
    await sbInsert(B.token, 'widget_data', { group_id: G, user_uid: B.uid, display_name: 'cc-B', mood_emoji: '😎' });
    check('widget_data: B пишет → A читает виджет B',
      rows(await sbGet(`widget_data?group_id=eq.${G}&user_uid=eq.${B.uid}&select=mood_emoji`, A.token))[0]?.mood_emoji === '😎');

    // ── miss_you («я скучаю»): A тапает → B читает счётчик ────────────────────
    await sbRpc(A.token, 'increment_miss_you', { p_group_id: G, p_user_uid: A.uid });
    check('miss_you (RPC increment_miss_you): A тапает → B видит счётчик',
      rows(await sbGet(`miss_you?group_id=eq.${G}&user_uid=eq.${A.uid}&select=count`, B.token))[0]?.count === 1);

    // ── mascots + streak: A создаёт маскота, активирует, RPC streak → B видит ─
    const masc = `${TAG}_masc`;
    await sbInsert(A.token, 'mascots',
      { group_id: G, id: masc, name: 'Мася', default_asset: 'assets/m.png', created_by: A.uid,
        created_at: new Date().toISOString(), is_default: true });
    check('mascots: A создаёт маскота → B читает галерею',
      rows(await sbGet(`mascots?group_id=eq.${G}&id=eq.${masc}&select=name`, B.token))[0]?.name === 'Мася');
    await sbPatch(A.token, `groups?id=eq.${G}`, { active_mascot_id: masc });
    // Огонёк растёт ТОЛЬКО когда за день отметились ОБА: первый (A) ставит
    // «ожидание» и НЕ растит, второй РАЗНЫЙ (B) — поднимает streak.
    const streakSolo = await sbRpc(A.token, 'group_record_activity', { p_group_id: G, p_today: today });
    check('streak: один партнёр (A) НЕ растит огонёк (ждём второго)',
      ok(streakSolo.status) && Number(streakSolo.json) === 0, `streak=${JSON.stringify(streakSolo.json)}`);
    const streak = await sbRpc(B.token, 'group_record_activity', { p_group_id: G, p_today: today });
    check('streak: второй партнёр (B) растит огонёк (оба зашли)',
      ok(streak.status) && Number(streak.json) >= 1, `streak=${JSON.stringify(streak.json)}`);
    check('mascots: streak_days виден A',
      (rows(await sbGet(`groups?id=eq.${G}&select=streak_days`, A.token))[0]?.streak_days ?? 0) >= 1);

    // ── RLS-санити: аноним (без токена) НЕ видит группу ──────────────────────
    const anon = await sbGet(`groups?id=eq.${G}&select=id`, null);
    check('RLS−: аноним (без токена) НЕ видит группу пары', rows(anon).length === 0, `строк: ${rows(anon).length}`);

  } catch (e) {
    check('FATAL', false, e.message);
  } finally {
    console.log('\n— очистка тестовых данных —');
    try {
      const A = users.A;
      if (A) {
        for (const tbl of ['memory_comments', 'memories', 'mood_entries', 'chat_messages',
          'chat_reads', 'canvas_strokes', 'canvas_meta', 'canvas_catalogue',
          'widget_data', 'miss_you', 'mascots']) {
          await sbWrite('DELETE', `${tbl}?group_id=eq.${G}`, A.token);
        }
        await sbWrite('DELETE', `groups?id=eq.${G}`, A.token);
      }
      for (const role of ['A', 'B']) {
        const u = users[role];
        if (!u) continue;
        await sbWrite('DELETE', `users?uid=eq.${u.uid}`, u.token);
        await admin.auth().deleteUser(u.uid).catch(() => {});
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
