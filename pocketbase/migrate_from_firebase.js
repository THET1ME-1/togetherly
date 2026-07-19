/**
 * Перенос данных Firebase → PocketBase (§8). Запуск:
 *   PB_PW=<superuser> node pocketbase/migrate_from_firebase.js email1 email2 ...
 *   PB_PW=<superuser> node pocketbase/migrate_from_firebase.js --all   (ВСЕ юзеры)
 *   + флаг --force — перенести заново, игнорируя migration_flags.
 *
 * Идемпотентно: id сохраняются → повтор обновляет/добавляет, не дублирует.
 * Со старого Firebase НИЧЕГО не удаляет (только читает).
 *
 * СКОРОСТЬ: записи пишутся ПАЧКАМИ через /api/batch (атомарно, чанки по
 * BATCH_CHUNK). При сбое чанка (коллизия/валидация) — откат всего чанка
 * сервером → падаем на пер-записный upsert (корректно обновляет/пропускает).
 * Медиа резолвится конкурентно (пул MEDIA_CONC) с дедупом in-flight по src.
 *
 * Auth: создаём users-запись с email + случайным паролем (вход — через Google/
 * Apple, PB линкует OAuth по email; либо мост паролей Firebase). scrypt НЕ переносится.
 */
const admin = require(__dirname + '/../functions/node_modules/firebase-admin');
const sa = require(__dirname + '/../scripts/serviceAccountKey.json');
admin.initializeApp({
  credential: admin.credential.cert(sa),
  databaseURL: 'https://togetherly-d4856-default-rtdb.europe-west1.firebasedatabase.app',
});
const db = admin.firestore();
const rtdb = admin.database();
const { AsyncLocalStorage } = require('async_hooks');
const groupFail = new AsyncLocalStorage(); // пер-групповой счётчик провалов (для флага)

const PB = 'https://togetherly.duckdns.org';
const PB_PW = process.env.PB_PW;
let TOKEN = null;

const BATCH_CHUNK = 300; // записей на один /api/batch (maxRequests=1000 на сервере)
const MEDIA_CONC = 8;    // параллельных резолвов медиа ВНУТРИ одной группы
const GROUP_CONC = 10;   // групп, обрабатываемых параллельно (сервер простаивает)
const USER_CONC = 48;    // параллельная сборка тел пользователей

async function pb(method, path, body) {
  const r = await fetch(PB + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(TOKEN ? { Authorization: TOKEN } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const t = await r.text();
  return { status: r.status, data: t ? JSON.parse(t) : null };
}
async function authPb() {
  const r = await pb('POST', '/api/collections/_superusers/auth-with-password',
    { identity: 'badzoff@gmail.com', password: PB_PW });
  if (r.status !== 200) throw new Error('PB auth failed: ' + JSON.stringify(r.data));
  TOKEN = r.data.token;
}

// Простой пул конкурентности.
async function pMap(items, fn, conc) {
  const out = new Array(items.length);
  let i = 0;
  const n = Math.min(conc, items.length) || 0;
  await Promise.all(Array.from({ length: n }, async () => {
    for (;;) {
      const idx = i++;
      if (idx >= items.length) break;
      out[idx] = await fn(items[idx], idx);
    }
  }));
  return out;
}

async function upsertById(col, id, body) {
  let r = await pb('POST', `/api/collections/${col}/records`, { id, ...body });
  if (r.status === 200) return r;
  // POST 400 = либо id уже занят (повтор → PATCH), либо РЕАЛЬНЫЙ validation-провал.
  // Проверяем существование: PATCH только если запись реально есть.
  if (r.status === 400) {
    const ex = await pb('GET', `/api/collections/${col}/records/${id}`);
    if (ex.status === 200) {
      r = await pb('PATCH', `/api/collections/${col}/records/${id}`, body);
      if (r.status === 200) return r;
    }
  }
  console.log(`  ! ${col}/${id}: ${r.status} ${JSON.stringify(r.data).slice(0, 200)}`);
  bump('failed');
  return r;
}
async function upsertByFilter(col, filter, body) {
  const g = await pb('GET', `/api/collections/${col}/records?perPage=1&filter=${encodeURIComponent(filter)}`);
  if (g.data && g.data.items && g.data.items.length) {
    const r = await pb('PATCH', `/api/collections/${col}/records/${g.data.items[0].id}`, body);
    if (r.status !== 200) { console.log(`  ! ${col} PATCH: ${r.status} ${JSON.stringify(r.data).slice(0, 200)}`); bump('failed'); }
    return r;
  }
  const r = await pb('POST', `/api/collections/${col}/records`, body);
  if (r.status !== 200) { console.log(`  ! ${col}: ${r.status} ${JSON.stringify(r.data).slice(0, 200)}`); bump('failed'); }
  return r;
}

// ── Пакетная запись через /api/batch ─────────────────────────────────────────
// items: [{id?, filter?, body}]. id → create-с-id (фолбэк upsertById);
// без id → create-авто-id (фолбэк upsertByFilter по filter). Батч АТОМАРЕН:
// status 200 = весь чанк закоммичен; иначе сервер откатил всё → пер-записный
// фолбэк (обновит существующие/поймает реальные ошибки).
async function batchWrite(col, items, statKey) {
  for (let i = 0; i < items.length; i += BATCH_CHUNK) {
    const slice = items.slice(i, i + BATCH_CHUNK);
    let ok = false;
    try {
      const requests = slice.map((it) => ({
        method: 'POST',
        url: `/api/collections/${col}/records`,
        body: it.id != null ? { id: it.id, ...it.body } : it.body,
      }));
      const r = await pb('POST', '/api/batch', { requests });
      ok = r.status === 200;
    } catch (_) { ok = false; }
    if (ok) { for (let k = 0; k < slice.length; k++) bump(statKey); continue; }
    for (const it of slice) {
      if (it.id != null) await upsertById(col, it.id, it.body);
      else await upsertByFilter(col, it.filter, it.body);
      bump(statKey);
    }
  }
}

// ── Защита от затирания (cutover) ────────────────────────────────────────────
// Флаг migration_flags/{prefix+id}.data_version. Первый прогон: флага нет →
// переносим → ставим флаг. Повтор (в т.ч. поздний --all ПОСЛЕ cutover) пропускает
// помеченные, чтобы НЕ откатить живые коины/данные снимком из Firebase. --force —
// перенести заново. Помечаем лишь при прогоне БЕЗ новых провалов.
// Существующие флаги грузим ОДНИМ проходом в Set (а не GET на каждую сущность),
// а новые пишем буфером пачками.
const DATA_VERSION = 1;
const FORCE = process.argv.includes('--force');
let migratedSet = new Set();
async function loadMigratedSet() {
  if (FORCE) return;
  let page = 1;
  for (;;) {
    const r = await pb('GET', `/api/collections/migration_flags/records?perPage=500&page=${page}&fields=id,data_version`);
    const items = (r.data && r.data.items) || [];
    for (const it of items) if (Number(it.data_version || 0) >= DATA_VERSION) migratedSet.add(it.id);
    if (items.length < 500) break;
    page++;
  }
}
function isMigrated(flagId) { return !FORCE && migratedSet.has(flagId); }
const flagBuffer = [];
function markMigrated(flagId) {
  flagBuffer.push({ id: flagId, body: { data_version: DATA_VERSION, updated_at: new Date().toISOString() } });
}
async function flushFlags() {
  if (!flagBuffer.length) return;
  const items = flagBuffer.splice(0, flagBuffer.length);
  await batchWrite('migration_flags', items, 'flags');
}

// Timestamp/Date/number/string → ISO-строка или null
function iso(v) {
  if (v == null) return null;
  if (typeof v === 'object' && typeof v.toDate === 'function') return v.toDate().toISOString();
  if (typeof v === 'object' && v._seconds != null) return new Date(v._seconds * 1000).toISOString();
  if (typeof v === 'string') return v || null;
  if (typeof v === 'number') return new Date(v).toISOString();
  return null;
}
function deepIso(o) {
  if (o == null) return o;
  if (typeof o === 'object' && typeof o.toDate === 'function') return o.toDate().toISOString();
  if (typeof o === 'object' && o._seconds != null && o._nanoseconds != null) return new Date(o._seconds * 1000).toISOString();
  if (Array.isArray(o)) return o.map(deepIso);
  if (typeof o === 'object') { const r = {}; for (const k of Object.keys(o)) r[k] = deepIso(o[k]); return r; }
  return o;
}
function randPw() { return 'Mig_' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2) + 'A1!'; }

// ── Перенос медиа: Firebase Storage → PB media (pb://), дедуп по src ──────────
const mediaCache = new Map();    // src → pb://-ссылка (готовая)
const mediaInflight = new Map(); // src → Promise<ref> (дедуп параллельных)
function parseFbStorage(url) {
  if (typeof url !== 'string' || !url) return null;
  if (url.startsWith('gs://')) {
    const m = url.match(/^gs:\/\/([^/]+)\/(.+)$/);
    return m ? { bucket: m[1], path: m[2] } : null;
  }
  let m = url.match(/firebasestorage\.googleapis\.com\/v0\/b\/([^/]+)\/o\/([^?]+)/);
  if (m) return { bucket: m[1], path: decodeURIComponent(m[2]) };
  m = url.match(/storage\.googleapis\.com\/([^/]+)\/(.+?)(\?|$)/);
  if (m) return { bucket: m[1], path: m[2] };
  return null; // внешний http (постеры/обложки из API) — не трогаем
}
async function migUrl(url, kind, groupId) {
  const fb = parseFbStorage(url);
  if (!fb) return url || '';
  if (mediaCache.has(url)) return mediaCache.get(url);
  if (mediaInflight.has(url)) return mediaInflight.get(url);
  const task = (async () => {
    // дедуп между прогонами: уже залитый блоб по src?
    const ex = await pb('GET', `/api/collections/media/records?perPage=1&filter=${encodeURIComponent(`src="${url}"`)}`);
    if (ex.data && ex.data.items && ex.data.items.length) {
      const r = ex.data.items[0];
      return `pb://media/${r.id}/${r.file}`;
    }
    const [buf] = await admin.storage().bucket(fb.bucket).file(fb.path).download();
    const filename = fb.path.split('/').pop() || 'file';
    const fd = new FormData();
    fd.append('file', new Blob([buf]), filename);
    fd.append('kind', kind || '');
    if (groupId) fd.append('group_id', groupId);
    fd.append('src', url);
    const r = await fetch(PB + '/api/collections/media/records',
      { method: 'POST', headers: { Authorization: TOKEN }, body: fd });
    if (r.status !== 200) { console.log(`  ! media upload (${fb.path}): ${r.status}`); return url; }
    const rec = await r.json();
    bump('media');
    return `pb://media/${rec.id}/${rec.file}`;
  })();
  mediaInflight.set(url, task);
  let ref;
  try { ref = await task; }
  catch (e) { console.log(`  ! media ${fb.path}: ${(e.message || e).toString().slice(0, 80)}`); ref = url; }
  mediaInflight.delete(url);
  if (ref && ref.startsWith('pb://')) mediaCache.set(url, ref);
  return ref;
}
async function migArr(arr, kind, groupId) {
  if (!Array.isArray(arr)) return arr;
  const out = [];
  for (const u of arr) out.push(await migUrl(u, kind, groupId));
  return out;
}

const stats = {};
const bump = (k) => {
  stats[k] = (stats[k] || 0) + 1;
  if (k === 'failed') { const s = groupFail.getStore(); if (s) s.n++; }
};

// ── Пользователи ─────────────────────────────────────────────────────────────
async function buildUserBody(uid) {
  const snap = await db.collection('users').doc(uid).get();
  const d = snap.exists ? snap.data() : {};
  let email = d.email || '';
  try { const au = await admin.auth().getUser(uid); email = au.email || email; } catch (_) {}
  const body = {
    email: email || `${uid}@migrated.local`,
    emailVisibility: false,
    verified: true,
    display_name: d.displayName || '',
    avatar_url: await migUrl(d.avatarUrl, 'avatar'),
    gender: d.gender || '',
    coins: Number(d.coins || 0),
    owned_themes: Array.isArray(d.ownedThemes) ? d.ownedThemes : [],
    owned_icons: Array.isArray(d.ownedIcons) ? d.ownedIcons : [],
    owned_features: Array.isArray(d.ownedFeatures) ? d.ownedFeatures : [],
    granted_badges: Array.isArray(d.grantedBadges) ? d.grantedBadges : [],
    badge: d.badge || '',
    pair_id: d.pairId || '',
    pair_ids: Array.isArray(d.pairIds) ? d.pairIds : [],
    invite_code: d.inviteCode || '',
    birth_date: iso(d.birthDate),
    dev_coins_granted: d.devCoinsGranted === true,
    ad_rewards_date: d.adRewardsDate || '',
    ad_rewards_today: Number(d.adRewardsToday || 0),
    solo_timers: Array.isArray(d.soloTimers) ? deepIso(d.soloTimers) : [],
    // Настройки уведомлений (в старом users-доке camelCase). Отсутствует = вкл.
    notif_miss_you: d.notifMissYou !== false,
    notif_new_memory: d.notifNewMemory !== false,
    notif_mood: d.notifMood !== false,
    notif_chat: d.notifChat !== false,
    updated_at: new Date().toISOString(),
  };
  return { uid, body, pw: randPw() };
}
// Фолбэк-запись одного юзера: create → (если есть) PATCH → (email занят другим
// uid) пропуск дубля. Возвращает 'created'|'updated'|'dup'|'fail'.
async function writeUser(p) {
  const { uid, body, pw } = p;
  const r = await pb('POST', '/api/collections/users/records', { id: uid, ...body, password: pw, passwordConfirm: pw });
  if (r.status === 200) { bump('users'); return 'created'; }
  const exists = await pb('GET', `/api/collections/users/records/${uid}`);
  if (exists.status === 200) {
    const pe = { ...body }; delete pe.email; // email существующего не трогаем
    const u = await pb('PATCH', `/api/collections/users/records/${uid}`, pe);
    if (u.status === 200) { bump('users'); return 'updated'; }
    console.log(`  ! user PATCH/${uid}: ${u.status}`); bump('failed'); return 'fail';
  }
  bump('users_skipped_dup'); // дубликат-аккаунт (email занят) — не создаём
  return 'dup';
}
async function batchUsers(preps) {
  for (let i = 0; i < preps.length; i += BATCH_CHUNK) {
    const slice = preps.slice(i, i + BATCH_CHUNK);
    let ok = false;
    try {
      const requests = slice.map((p) => ({
        method: 'POST', url: '/api/collections/users/records',
        body: { id: p.uid, ...p.body, password: p.pw, passwordConfirm: p.pw },
      }));
      const r = await pb('POST', '/api/batch', { requests });
      ok = r.status === 200;
    } catch (_) { ok = false; }
    if (ok) { for (const p of slice) { bump('users'); markMigrated('u_' + p.uid); } continue; }
    for (const p of slice) {
      const res = await writeUser(p);
      if (res !== 'fail') markMigrated('u_' + p.uid);
    }
  }
}

// ── Группа и её данные ───────────────────────────────────────────────────────
async function migrateGroup(gid) {
  const flagId = 'g_' + gid;
  if (isMigrated(flagId)) { bump('groups_skipped'); return; }
  await groupFail.run({ n: 0 }, async () => {
  const snap = await db.collection('groups').doc(gid).get();
  if (!snap.exists) return;
  const d = snap.data();
  await upsertById('groups', gid, {
    members: Array.isArray(d.members) ? d.members : [],
    member_names: d.memberNames || {},
    member_avatars: d.memberAvatars || {},
    member_moods: d.memberMoods || {},
    member_birthdays: d.memberBirthdays || {},
    max_members: Number(d.maxMembers || 2),
    relationship_type: d.relationshipType || 'couple',
    custom_relationship_label: d.customRelationshipLabel || '',
    custom_relationship_emoji: d.customRelationshipEmoji || '',
    custom_relationship_types: d.customRelationshipTypes || [],
    current_status: d.currentStatus || null,
    custom_statuses: d.customStatuses || [],
    start_date: iso(d.startDate),
    anniversary_date: iso(d.anniversaryDate),
    first_kiss_date: iso(d.firstKissDate),
    created_at: iso(d.createdAt),
    disbanded: d.disbanded === true,
    disbanded_at: iso(d.disbandedAt),
    memories_count: Number(d.memoriesCount || 0),
    drawings_count: Number(d.drawingsCount || 0),
    timers: Array.isArray(d.timers) ? deepIso(d.timers) : [],
    xp: Number(d.xp || 0),
    active_mascot_id: d.activeMascotId || '',
    mascot_position_x: Number(d.mascotPositionX || 0),
    mascot_position_y: Number(d.mascotPositionY || 0),
    mascot_scale: Number(d.mascotScale || 0),
    streak_days: Number(d.streakDays || 0),
    streak_last_opened_date: d.streakLastOpenedDate || '',
    streak_pending_date: d.streakPendingDate || '',
    streak_pending_uid: d.streakPendingUid || '',
  });
  bump('groups');

  // Читаем независимые подколлекции группы ПАРАЛЛЕЛЬНО (латентность вместо суммы).
  const grp = db.collection('groups').doc(gid);
  const [memSnap, wdSnap, msSnap, ccSnap] = await Promise.all([
    grp.collection('memories').get(),
    grp.collection('widgetData').get(),
    grp.collection('mascots').get(),
    grp.collection('canvasCatalogue').get(),
  ]);

  // memories (+ комментарии) — медиа резолвится конкурентно
  const memDocs = memSnap.docs;
  const memResults = await pMap(memDocs, async (m) => {
    const x = m.data();
    const data = deepIso(x);
    for (const k of ['imageUrl', 'videoUrl', 'musicUrl', 'musicCoverUrl', 'thumbnailUrl']) {
      if (data[k]) data[k] = await migUrl(data[k], 'memory', gid);
    }
    if (Array.isArray(data.imageUrls)) data.imageUrls = await migArr(data.imageUrls, 'memory', gid);
    const memItem = {
      id: m.id,
      body: {
        group_id: gid, type: x.type || 'note',
        author_uid: x.authorUid || '', author_name: x.authorName || '', author_avatar: x.authorAvatar || '',
        created_at: iso(x.createdAt), edited_at: iso(x.editedAt),
        is_pinned: x.isPinned === true, deleted: x.deleted === true, data,
      },
    };
    const cms = await m.ref.collection('comments').get();
    const comts = cms.docs.map((c) => {
      const cx = c.data();
      return {
        id: c.id,
        body: {
          group_id: gid, memory_id: m.id,
          author_uid: cx.authorUid || '', author_name: cx.authorName || '', author_avatar: cx.authorAvatar || '',
          text: cx.text || '', created_at: iso(cx.createdAt), deleted: cx.deleted === true,
        },
      };
    });
    return { memItem, comts };
  }, MEDIA_CONC);
  await batchWrite('memories', memResults.map((r) => r.memItem), 'memories');
  await batchWrite('memory_comments', memResults.flatMap((r) => r.comts), 'memory_comments');

  // widget_data — медиа конкурентно
  const wdDocs = wdSnap.docs;
  const wdItems = await pMap(wdDocs, async (w) => {
    const x = w.data();
    return {
      filter: `group_id="${gid}" && user_uid="${w.id}"`,
      body: {
        group_id: gid, user_uid: w.id,
        display_name: x.displayName || '', avatar_url: await migUrl(x.avatarUrl, 'avatar'), gender: x.gender || '',
        status: x.status || '', mood_emoji: x.moodEmoji || '', mood_label: x.moodLabel || '',
        message: x.message || '', music_title: x.musicTitle || '', music_artist: x.musicArtist || '',
        music_url: await migUrl(x.musicUrl, 'widget', gid), music_cover_url: await migUrl(x.musicCoverUrl, 'widget', gid),
        photo_url: await migUrl(x.photoUrl, 'widget', gid), photo_for_partner_url: await migUrl(x.photoForPartnerUrl, 'widget', gid),
        photo_for_partner_urls: await migArr(x.photoForPartnerUrls, 'widget', gid),
        photo_grid_count: Number(x.photoGridCount || 1), photo_grid_urls: await migArr(x.photoGridUrls, 'widget', gid),
        updated_at: iso(x.updatedAt) || new Date().toISOString(),
      },
    };
  }, MEDIA_CONC);
  await batchWrite('widget_data', wdItems, 'widget_data');

  // mascots — медиа конкурентно
  const msDocs = msSnap.docs;
  const msItems = await pMap(msDocs, async (m) => {
    const x = m.data();
    const mid = x.id || m.id;
    return {
      filter: `group_id="${gid}" && mascot_id="${mid}"`,
      body: {
        group_id: gid, mascot_id: mid, name: x.name || '', image_url: await migUrl(x.imageUrl, 'mascot', gid),
        default_asset: x.defaultAsset || '', created_by: x.createdBy || '',
        created_at: iso(x.createdAt), is_default: x.isDefault === true, record_streak: Number(x.recordStreak || 0),
      },
    };
  }, MEDIA_CONC);
  await batchWrite('mascots', msItems, 'mascots');

  // canvas_catalogue
  const ccDocs = ccSnap.docs;
  const ccItems = ccDocs.map((c) => {
    const x = c.data();
    const cid = x.id || c.id;
    return {
      filter: `group_id="${gid}" && canvas_id="${cid}"`,
      body: {
        group_id: gid, canvas_id: cid, name: x.name || '',
        created_at: Number(x.createdAt || 0), updated_at: Number(x.updatedAt || 0), created_by: x.createdBy || '',
      },
    };
  });
  await batchWrite('canvas_catalogue', ccItems, 'canvas_catalogue');

  // canvas: штрихи (canvas_strokes) + мета (canvas_meta) для 'main' и каталога
  const canvasIds = new Set(['main']);
  for (const c of ccDocs) canvasIds.add(c.id);
  const strokeItems = [];
  const metaItems = [];
  for (const canvasId of canvasIds) {
    const cref = db.collection('groups').doc(gid).collection('canvas').doc(canvasId);
    const strokes = await cref.collection('strokes').get();
    for (const s of strokes.docs) {
      const sd = s.data() || {};
      strokeItems.push({
        id: s.id,
        body: { group_id: gid, canvas_id: canvasId, order_index: Number(sd.orderIndex || 0), data: deepIso(sd), deleted: sd.deleted === true },
      });
    }
    const metaSnap = await cref.get();
    const md = metaSnap.exists ? metaSnap.data() : null;
    if (md) {
      metaItems.push({
        filter: `group_id="${gid}" && canvas_id="${canvasId}"`,
        body: {
          group_id: gid, canvas_id: canvasId,
          bg_color: Number(md.bgColor || 0), clear_version: Number(md.clearVersion || 0),
          canvas_rotation: Number(md.canvasRotation || 0), updated_at: iso(md.updatedAt) || new Date().toISOString(),
        },
      });
    }
  }
  await batchWrite('canvas_strokes', strokeItems, 'canvas_strokes');
  await batchWrite('canvas_meta', metaItems, 'canvas_meta');

  // RTDB chat messages
  const ch = await rtdb.ref('chats/' + gid + '/messages').get();
  const chatItems = [];
  if (ch.exists()) {
    const msgs = ch.val() || {};
    for (const key of Object.keys(msgs)) {
      const x = msgs[key];
      chatItems.push({
        id: key,
        body: {
          group_id: gid, user_uid: x.uid || '', user_name: x.name || '', text: x.text || '',
          ts: Number(x.ts || 0), edited_ts: Number(x.editedTs || 0), deleted: x.deleted === true,
          reactions: x.reactions || {}, pin_id: x.pinId || '', pin_title: x.pinTitle || '', pin_thumb: x.pinThumb || '',
          face: x.face || '', color: Number(x.color || 0), face_x: Number(x.faceX || 0), face_y: Number(x.faceY || 0),
          reply_to_id: x.replyToId || '', reply_to_name: x.replyToName || '', reply_to_text: x.replyToText || '',
        },
      });
    }
  }
  await batchWrite('chat_messages', chatItems, 'chat_messages');

  // RTDB chat reads
  const rd = await rtdb.ref('chats/' + gid + '/reads').get();
  const readItems = [];
  if (rd.exists()) {
    const reads = rd.val() || {};
    for (const uid of Object.keys(reads)) {
      readItems.push({
        filter: `group_id="${gid}" && user_uid="${uid}"`,
        body: { group_id: gid, user_uid: uid, last_read_ts: Number(reads[uid] || 0), updated_at: new Date().toISOString() },
      });
    }
  }
  await batchWrite('chat_reads', readItems, 'chat_reads');

  // mood_entries (Firestore moodCalendar → плоская коллекция):
  //   v2: moodCalendar/{uid}/months/{YYYY-MM}.entries{entryId:{...}}
  //   v1 legacy: moodCalendar/{uid}/entries/{entryId} (1 док = 1 запись)
  const moodMembers = Array.isArray(d.members) ? d.members : [];
  const moodItems = [];
  for (const uid of moodMembers) {
    const calBase = db.collection('groups').doc(gid).collection('moodCalendar').doc(uid);
    const push = (entryId, e) => {
      if (!entryId || !e || typeof e !== 'object') return;
      moodItems.push({
        id: entryId,
        body: {
          group_id: gid, user_uid: uid,
          mood_id: e.moodId || '', image_path: e.imagePath || '', label: e.label || '',
          timestamp: iso(e.timestamp) || new Date().toISOString(),
        },
      });
    };
    const months = await calBase.collection('months').get();
    for (const mdoc of months.docs) {
      const entries = (mdoc.data() || {}).entries || {};
      for (const eid of Object.keys(entries)) push(eid, entries[eid]);
    }
    const legacy = await calBase.collection('entries').get();
    for (const ldoc of legacy.docs) push(ldoc.id, ldoc.data());
  }
  await batchWrite('mood_entries', moodItems, 'mood_entries');

  // miss_you (RTDB missYou/{gid}/counts/{uid} + legacy d.missYouCounts).
  // max(существующий в PB, исходный) — повтор не откатывает live-счётчик.
  // Малый объём (≤ members) — оставлено пер-записно с GET-max.
  const missCounts = {};
  const myRt = await rtdb.ref('missYou/' + gid + '/counts').get();
  if (myRt.exists()) {
    const v = myRt.val() || {};
    for (const u of Object.keys(v)) missCounts[u] = Number(v[u] || 0);
  }
  if (d.missYouCounts && typeof d.missYouCounts === 'object') {
    for (const u of Object.keys(d.missYouCounts)) {
      missCounts[u] = Math.max(missCounts[u] || 0, Number(d.missYouCounts[u] || 0));
    }
  }
  for (const uid of Object.keys(missCounts)) {
    const c = missCounts[uid];
    if (!c || c <= 0) continue;
    const ex = await pb('GET', `/api/collections/miss_you/records?perPage=1&filter=${encodeURIComponent(`group_id="${gid}" && user_uid="${uid}"`)}`);
    const cur = (ex.data && ex.data.items && ex.data.items[0]) ? Number(ex.data.items[0].count || 0) : 0;
    await upsertByFilter('miss_you', `group_id="${gid}" && user_uid="${uid}"`, {
      group_id: gid, user_uid: uid, count: Math.max(cur, c), updated_at: new Date().toISOString(),
    });
    bump('miss_you');
  }

  // Группа перенесена без новых провалов → метим (буфер, флашится пачкой).
  if (groupFail.getStore().n === 0) markMigrated(flagId);
  else bump('groups_incomplete');
  }); // groupFail.run
}

(async () => {
  // ⛔ CUTOVER ЗАВЕРШЁН (2026-06-27) — миграция РЕТАЙРНУТА. Повторный полный засев
  // по живой базе клал PocketBase: PK-коллизии (id уже есть) + batch-транзакции до
  // 169с, держащие единственный SQLite-writer → заморозка всех записей приложения.
  // Запуск намеренно заблокирован. Если ДЕЙСТВИТЕЛЬНО нужно (новый чистый стенд):
  //   MIGRATION_ALLOW=cutover-done-i-am-sure node pocketbase/migrate_from_firebase.js ...
  if (process.env.MIGRATION_ALLOW !== 'cutover-done-i-am-sure') {
    console.error('⛔ migrate_from_firebase РЕТАЙРНУТ (cutover завершён, см. комментарий). Обход: MIGRATION_ALLOW=cutover-done-i-am-sure');
    process.exit(1);
  }
  if (!PB_PW) throw new Error('PB_PW env required');
  await authPb();
  await loadMigratedSet();
  console.log(`migrate v${DATA_VERSION}${FORCE ? ' [--force]' : ''} | флагов уже: ${migratedSet.size}`);
  const args = process.argv.slice(2);
  const seedUids = [];
  if (args.includes('--all')) {
    let pageToken;
    do {
      const res = await admin.auth().listUsers(1000, pageToken);
      res.users.forEach((u) => seedUids.push(u.uid));
      pageToken = res.pageToken;
    } while (pageToken);
    console.log(`--all: ${seedUids.length} пользователей из Firebase Auth`);
  } else {
    for (const email of args.filter((a) => !a.startsWith('--'))) {
      try { const u = await admin.auth().getUserByEmail(email); seedUids.push(u.uid); }
      catch (e) { console.log('email не найден:', email); }
    }
  }
  // Все группы сидов + все их участники (чтобы пары были целыми).
  const groupIds = new Set();
  const allUids = new Set(seedUids);
  if (args.includes('--all')) {
    // --all: все группы одним проходом (а не 20k array-contains-запросов); все
    // юзеры уже в seedUids (вся auth-база) → партнёров добирать не нужно.
    const gsnap = await db.collection('groups').select().get();
    gsnap.docs.forEach((g) => groupIds.add(g.id));
  } else {
    for (const uid of seedUids) {
      const gq = await db.collection('groups').where('members', 'array-contains', uid).get();
      gq.docs.forEach((g) => groupIds.add(g.id));
    }
    for (const gid of groupIds) {
      const g = (await db.collection('groups').doc(gid).get()).data() || {};
      (g.members || []).forEach((u) => allUids.add(u));
    }
  }
  console.log(`Сидов: ${seedUids.length} | групп: ${groupIds.size} | всего юзеров (с партнёрами): ${allUids.size}`);

  // Пользователи — конкурентная сборка тел + батч-вставка.
  const toMig = [...allUids].filter((uid) => !isMigrated('u_' + uid));
  console.log(`Переношу пользователей: ${toMig.length} (пропущено по флагам: ${allUids.size - toMig.length})...`);
  const t0 = Date.now();
  const preps = await pMap(toMig, (uid) => buildUserBody(uid), USER_CONC);
  await batchUsers(preps);
  await flushFlags();
  console.log(`  юзеры готовы за ${((Date.now() - t0) / 1000).toFixed(0)}с (media=${stats.media || 0})`);

  // Группы — последовательно (изоляция учёта провалов на группу), внутри — батчи.
  console.log(`Переношу группы параллельно (групп=${GROUP_CONC}, медиа/группа=${MEDIA_CONC})...`);
  const gidArr = [...groupIds];
  const tg = Date.now();
  let done = 0;
  await pMap(gidArr, async (gid) => {
    await migrateGroup(gid);
    done++;
    if (done % 50 === 0) {
      await flushFlags();
      const el = ((Date.now() - tg) / 1000).toFixed(0);
      console.log(`  ...${done}/${gidArr.length} групп · ${el}с · strokes=${stats.canvas_strokes || 0} media=${stats.media || 0} failed=${stats.failed || 0}`);
    }
  }, GROUP_CONC);
  await flushFlags();

  console.log('\n=== ИТОГ ПЕРЕНОСА ===');
  console.log(JSON.stringify(stats, null, 2));
  console.log(`Время групп: ${((Date.now() - tg) / 1000).toFixed(0)}с`);
  if (stats.failed) console.log(`\n⚠️  ПРОВАЛОВ: ${stats.failed} — записи НЕ перенесены (см. строки "!" выше)`);
  process.exit(stats.failed ? 1 : 0);
})().catch((e) => { console.error('FATAL', e); process.exit(1); });
