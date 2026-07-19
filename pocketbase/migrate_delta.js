/**
 * ДЕЛЬТА-перенос Firebase → PocketBase (для cutover-окна). ОТДЕЛЬНЫЙ от
 * migrate_from_firebase.js (тот = первичный полный засев, не трогаем).
 *
 * Запуск:
 *   PB_PW=<su> node pocketbase/migrate_delta.js --since "2026-06-26T20:00:00Z"
 *   PB_PW=<su> node pocketbase/migrate_delta.js --since 1782000000000   (epoch ms)
 *   + --group <gid>   только одна группа (для теста)
 *   + --no-backfill   не доливать пропущенные штрихи (только дельта по времени)
 *
 * Что делает:
 *  1. ДЕЛЬТА: по ВСЕМ группам (флаги НЕ смотрим — ловим новое и у СТАРЫХ пар)
 *     переносит записи, созданные ПОСЛЕ --since: воспоминания (+комменты), штрихи,
 *     настроения, чат. Плюс re-sync изменяемого состояния (group-док, widget,
 *     miss_you, mascot-галерея). Плюс НОВЫЕ юзеры (Auth creationTime > since).
 *  2. БЭКФИЛЛ ШТРИХОВ (фикс бага полного засева): для холстов, которых НЕТ в
 *     {'main'}∪canvasCatalogue, переносит ВСЕ их штрихи (полный засев их пропускал).
 *
 * Идемпотентно (id сохраняются). Со старого Firebase только читает.
 * Типы дат (проверено на проде): memory/comment.createdAt и mood.timestamp =
 * Timestamp (фильтр Date); stroke.createdAt и chat.ts = number ms (фильтр числом).
 * Ограничения (крайние случаи): правки старых воспоминаний без editedAt и новые
 * комменты к СТАРЫМ воспоминаниям дельта не ловит (редко; на cutover Firebase
 * заморожен — новое не появляется, ловим всё до момента заморозки).
 */
const admin = require(__dirname + '/../functions/node_modules/firebase-admin');
const sa = require(__dirname + '/../scripts/serviceAccountKey.json');
admin.initializeApp({
  credential: admin.credential.cert(sa),
  databaseURL: 'https://togetherly-d4856-default-rtdb.europe-west1.firebasedatabase.app',
});
const db = admin.firestore();
const rtdb = admin.database();

const PB = 'https://togetherly.duckdns.org';
const PB_PW = process.env.PB_PW;
let TOKEN = null;

const BATCH_CHUNK = 50;    // было 300: пачка = ОДНА SQLite-транзакция. 300 строк (особенно холст с тяжёлым JSON) держали единственный writer PocketBase до 169с и морозили ВСЕ записи приложения. 50 — короткая транзакция.
const MEDIA_CONC = 8;
const GROUP_CONC = 5;      // было 30: столько групп обходим параллельно. 30 параллельных пачек = до 30 одновременных транзакций в single-writer SQLite → захлёб. 5 — щадящий темп.
const CHUNK_PAUSE_MS = 40; // пауза между пачками — дать writer'у выдохнуть.
// Коллекции append-only: запись после миграции НЕ меняется. На повторном прогоне их
// id уже есть → пере-создавать бессмысленно (это и был шторм ~90k PK-коллизий + дорогой
// per-item фолбэк). Для них пропускаем уже существующие id (повторный прогон → почти 0
// записей, только дешёвые чтения). Изменяемое состояние (groups/widget/miss_you/mascots/
// mood/meta/reads) СЮДА НЕ входит — оно намеренно ре-синкается.
const SKIP_EXISTING = new Set(['memories', 'memory_comments', 'canvas_strokes', 'chat_messages']);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── аргументы ────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
function argVal(name) { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; }
const SINCE_RAW = argVal('--since');
const ONLY_GROUP = argVal('--group');
const NO_BACKFILL = argv.includes('--no-backfill');
if (!SINCE_RAW) throw new Error('нужен --since <ISO|epoch_ms>');
const SINCE_MS = /^\d+$/.test(SINCE_RAW) ? Number(SINCE_RAW) : Date.parse(SINCE_RAW);
if (!Number.isFinite(SINCE_MS)) throw new Error('--since не распарсился: ' + SINCE_RAW);
const SINCE_DATE = new Date(SINCE_MS);

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
async function pMap(items, fn, conc) {
  const out = new Array(items.length); let i = 0;
  const n = Math.min(conc, items.length) || 0;
  await Promise.all(Array.from({ length: n }, async () => {
    for (;;) { const idx = i++; if (idx >= items.length) break; out[idx] = await fn(items[idx], idx); }
  }));
  return out;
}
async function upsertById(col, id, body) {
  let r = await pb('POST', `/api/collections/${col}/records`, { id, ...body });
  if (r.status === 200) return r;
  if (r.status === 400) {
    const ex = await pb('GET', `/api/collections/${col}/records/${id}`);
    if (ex.status === 200) { r = await pb('PATCH', `/api/collections/${col}/records/${id}`, body); if (r.status === 200) return r; }
  }
  console.log(`  ! ${col}/${id}: ${r.status} ${JSON.stringify(r.data).slice(0, 160)}`); bump('failed'); return r;
}
async function upsertByFilter(col, filter, body) {
  const g = await pb('GET', `/api/collections/${col}/records?perPage=1&filter=${encodeURIComponent(filter)}`);
  if (g.data && g.data.items && g.data.items.length) {
    const r = await pb('PATCH', `/api/collections/${col}/records/${g.data.items[0].id}`, body);
    if (r.status !== 200) { console.log(`  ! ${col} PATCH: ${r.status}`); bump('failed'); } return r;
  }
  const r = await pb('POST', `/api/collections/${col}/records`, body);
  if (r.status !== 200) { console.log(`  ! ${col}: ${r.status} ${JSON.stringify(r.data).slice(0, 160)}`); bump('failed'); } return r;
}
// Возвращает Set уже существующих в PB id из переданного списка (дешёвые indexed-чтения).
async function existingIds(col, ids) {
  const found = new Set();
  for (let i = 0; i < ids.length; i += 50) {
    const slice = ids.slice(i, i + 50);
    const filter = slice.map((id) => `id="${id}"`).join(' || ');
    const r = await pb('GET', `/api/collections/${col}/records?perPage=${slice.length}&skipTotal=1&fields=id&filter=${encodeURIComponent(filter)}`);
    if (r.data && r.data.items) for (const it of r.data.items) found.add(it.id);
  }
  return found;
}
async function batchWrite(col, items, statKey) {
  const skipExisting = SKIP_EXISTING.has(col);
  for (let i = 0; i < items.length; i += BATCH_CHUNK) {
    let slice = items.slice(i, i + BATCH_CHUNK);
    // На повторном прогоне append-only коллекций: выкинуть уже существующие id, чтобы
    // НЕ пытаться их создавать (это и был шторм PK-коллизий + дорогой per-item фолбэк).
    if (skipExisting) {
      const ids = slice.filter((it) => it.id != null).map((it) => it.id);
      if (ids.length) {
        const have = await existingIds(col, ids);
        if (have.size) {
          const before = slice.length;
          slice = slice.filter((it) => it.id == null || !have.has(it.id));
          for (let k = 0; k < before - slice.length; k++) bump(statKey + '_skip');
        }
      }
      if (!slice.length) continue;
    }
    let ok = false;
    try {
      const requests = slice.map((it) => ({ method: 'POST', url: `/api/collections/${col}/records`, body: it.id != null ? { id: it.id, ...it.body } : it.body }));
      const r = await pb('POST', '/api/batch', { requests }); ok = r.status === 200;
    } catch (_) { ok = false; }
    if (ok) { for (let k = 0; k < slice.length; k++) bump(statKey); }
    else { for (const it of slice) { if (it.id != null) await upsertById(col, it.id, it.body); else await upsertByFilter(col, it.filter, it.body); bump(statKey); } }
    await sleep(CHUNK_PAUSE_MS);
  }
}

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
// эпоха-ms из Timestamp/number/string (для сравнения с SINCE_MS на клиенте)
function ms(v) {
  if (v == null) return 0;
  if (typeof v === 'object' && typeof v.toDate === 'function') return v.toDate().getTime();
  if (typeof v === 'object' && v._seconds != null) return v._seconds * 1000;
  if (typeof v === 'number') return v;
  if (typeof v === 'string') { const p = Date.parse(v); return Number.isFinite(p) ? p : 0; }
  return 0;
}
function randPw() { return 'Mig_' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2) + 'A1!'; }

// ── медиа (как в полном скрипте, с дедупом in-flight) ────────────────────────
const mediaCache = new Map();
const mediaInflight = new Map();
function parseFbStorage(url) {
  if (typeof url !== 'string' || !url) return null;
  if (url.startsWith('gs://')) { const m = url.match(/^gs:\/\/([^/]+)\/(.+)$/); return m ? { bucket: m[1], path: m[2] } : null; }
  let m = url.match(/firebasestorage\.googleapis\.com\/v0\/b\/([^/]+)\/o\/([^?]+)/); if (m) return { bucket: m[1], path: decodeURIComponent(m[2]) };
  m = url.match(/storage\.googleapis\.com\/([^/]+)\/(.+?)(\?|$)/); if (m) return { bucket: m[1], path: m[2] };
  return null;
}
async function migUrl(url, kind, groupId) {
  const fb = parseFbStorage(url);
  if (!fb) return url || '';
  if (mediaCache.has(url)) return mediaCache.get(url);
  if (mediaInflight.has(url)) return mediaInflight.get(url);
  const task = (async () => {
    const ex = await pb('GET', `/api/collections/media/records?perPage=1&filter=${encodeURIComponent(`src="${url}"`)}`);
    if (ex.data && ex.data.items && ex.data.items.length) { const r = ex.data.items[0]; return `pb://media/${r.id}/${r.file}`; }
    const [buf] = await admin.storage().bucket(fb.bucket).file(fb.path).download();
    const filename = fb.path.split('/').pop() || 'file';
    const fd = new FormData();
    fd.append('file', new Blob([buf]), filename); fd.append('kind', kind || ''); if (groupId) fd.append('group_id', groupId); fd.append('src', url);
    const r = await fetch(PB + '/api/collections/media/records', { method: 'POST', headers: { Authorization: TOKEN }, body: fd });
    if (r.status !== 200) { console.log(`  ! media upload (${fb.path}): ${r.status}`); return url; }
    const rec = await r.json(); bump('media'); return `pb://media/${rec.id}/${rec.file}`;
  })();
  mediaInflight.set(url, task);
  let ref; try { ref = await task; } catch (e) { console.log(`  ! media ${fb.path}: ${(e.message || e).toString().slice(0, 80)}`); ref = url; }
  mediaInflight.delete(url);
  if (ref && ref.startsWith('pb://')) mediaCache.set(url, ref);
  return ref;
}
async function migArr(arr, kind, groupId) { if (!Array.isArray(arr)) return arr; const out = []; for (const u of arr) out.push(await migUrl(u, kind, groupId)); return out; }

const stats = {};
const bump = (k) => stats[k] = (stats[k] || 0) + 1;

// ── ДЕЛЬТА по одной группе ───────────────────────────────────────────────────
async function deltaGroup(gid) {
  const grp = db.collection('groups').doc(gid);
  const snap = await grp.get();
  if (!snap.exists) return;
  const d = snap.data();

  // 1. group-док — изменяемое состояние, всегда re-sync (счётчики/статус/маскот/стрик)
  await upsertById('groups', gid, {
    members: Array.isArray(d.members) ? d.members : [], member_names: d.memberNames || {}, member_avatars: d.memberAvatars || {},
    member_moods: d.memberMoods || {}, member_birthdays: d.memberBirthdays || {}, max_members: Number(d.maxMembers || 2),
    relationship_type: d.relationshipType || 'couple', custom_relationship_label: d.customRelationshipLabel || '',
    custom_relationship_emoji: d.customRelationshipEmoji || '', custom_relationship_types: d.customRelationshipTypes || [],
    current_status: d.currentStatus || null, custom_statuses: d.customStatuses || [], start_date: iso(d.startDate),
    anniversary_date: iso(d.anniversaryDate), first_kiss_date: iso(d.firstKissDate), created_at: iso(d.createdAt),
    disbanded: d.disbanded === true, disbanded_at: iso(d.disbandedAt), memories_count: Number(d.memoriesCount || 0),
    drawings_count: Number(d.drawingsCount || 0), timers: Array.isArray(d.timers) ? deepIso(d.timers) : [], xp: Number(d.xp || 0),
    active_mascot_id: d.activeMascotId || '', mascot_position_x: Number(d.mascotPositionX || 0), mascot_position_y: Number(d.mascotPositionY || 0),
    mascot_scale: Number(d.mascotScale || 0), streak_days: Number(d.streakDays || 0), streak_last_opened_date: d.streakLastOpenedDate || '',
    streak_pending_date: d.streakPendingDate || '', streak_pending_uid: d.streakPendingUid || '',
  });
  bump('groups_synced');

  // 2. НОВЫЕ воспоминания (createdAt > since) + их комменты
  const memSnap = await grp.collection('memories').where('createdAt', '>', SINCE_DATE).get();
  if (!memSnap.empty) {
    const res = await pMap(memSnap.docs, async (m) => {
      const x = m.data(); const data = deepIso(x);
      for (const k of ['imageUrl', 'videoUrl', 'musicUrl', 'musicCoverUrl', 'thumbnailUrl']) if (data[k]) data[k] = await migUrl(data[k], 'memory', gid);
      if (Array.isArray(data.imageUrls)) data.imageUrls = await migArr(data.imageUrls, 'memory', gid);
      const memItem = { id: m.id, body: { group_id: gid, type: x.type || 'note', author_uid: x.authorUid || '', author_name: x.authorName || '', author_avatar: x.authorAvatar || '', created_at: iso(x.createdAt), edited_at: iso(x.editedAt), is_pinned: x.isPinned === true, deleted: x.deleted === true, data } };
      const cms = await m.ref.collection('comments').get();
      const comts = cms.docs.map((c) => { const cx = c.data(); return { id: c.id, body: { group_id: gid, memory_id: m.id, author_uid: cx.authorUid || '', author_name: cx.authorName || '', author_avatar: cx.authorAvatar || '', text: cx.text || '', created_at: iso(cx.createdAt), deleted: cx.deleted === true } }; });
      return { memItem, comts };
    }, MEDIA_CONC);
    await batchWrite('memories', res.map((r) => r.memItem), 'memories');
    await batchWrite('memory_comments', res.flatMap((r) => r.comts), 'memory_comments');
  }

  // 3. НОВЫЕ штрихи (createdAt:number > since) по ВСЕМ холстам + БЭКФИЛЛ непереч.
  const allCanvas = await grp.collection('canvas').listDocuments();
  if (allCanvas.length) {
    const cc = await grp.collection('canvasCatalogue').get();
    const catalogued = new Set(['main']); cc.docs.forEach((c) => catalogued.add(c.id));
    const strokeItems = []; const metaItems = [];
    for (const cv of allCanvas) {
      const canvasId = cv.id;
      const inCatalog = catalogued.has(canvasId);
      // catalogued → только новое (createdAt>since); непереч. (баг) → ВСЕ (бэкфилл)
      let strokes;
      if (inCatalog) strokes = await cv.collection('strokes').where('createdAt', '>', SINCE_MS).get();
      else if (!NO_BACKFILL) { strokes = await cv.collection('strokes').get(); if (strokes.size) bump('canvas_backfilled'); }
      else strokes = { docs: [] };
      for (const s of strokes.docs) { const sd = s.data() || {}; strokeItems.push({ id: s.id, body: { group_id: gid, canvas_id: canvasId, order_index: Number(sd.orderIndex || 0), data: deepIso(sd), deleted: sd.deleted === true } }); }
      // мету непереч. холстов тоже доливаем (для них её не было)
      if (!inCatalog && !NO_BACKFILL) {
        const md = (await cv.get()).data();
        if (md) metaItems.push({ filter: `group_id="${gid}" && canvas_id="${canvasId}"`, body: { group_id: gid, canvas_id: canvasId, bg_color: Number(md.bgColor || 0), clear_version: Number(md.clearVersion || 0), canvas_rotation: Number(md.canvasRotation || 0), updated_at: iso(md.updatedAt) || new Date().toISOString() } });
      }
    }
    await batchWrite('canvas_strokes', strokeItems, 'canvas_strokes');
    await batchWrite('canvas_meta', metaItems, 'canvas_meta');
  }

  // 4. НОВЫЕ настроения (entry.timestamp > since) — читаем месяцы, фильтруем записи
  const moodMembers = Array.isArray(d.members) ? d.members : [];
  const moodItems = [];
  for (const uid of moodMembers) {
    const calBase = grp.collection('moodCalendar').doc(uid);
    const push = (entryId, e) => { if (!entryId || !e || typeof e !== 'object') return; if (ms(e.timestamp) <= SINCE_MS) return; moodItems.push({ id: entryId, body: { group_id: gid, user_uid: uid, mood_id: e.moodId || '', image_path: e.imagePath || '', label: e.label || '', timestamp: iso(e.timestamp) || new Date().toISOString() } }); };
    const months = await calBase.collection('months').get();
    for (const mdoc of months.docs) { const entries = (mdoc.data() || {}).entries || {}; for (const eid of Object.keys(entries)) push(eid, entries[eid]); }
    const legacy = await calBase.collection('entries').get();
    for (const ldoc of legacy.docs) push(ldoc.id, ldoc.data());
  }
  await batchWrite('mood_entries', moodItems, 'mood_entries');

  // 5. НОВЫЙ чат (ts:number > since) + reads (re-sync)
  const ch = await rtdb.ref('chats/' + gid + '/messages').orderByChild('ts').startAt(SINCE_MS + 1).get();
  const chatItems = [];
  if (ch.exists()) { const msgs = ch.val() || {}; for (const key of Object.keys(msgs)) { const x = msgs[key]; chatItems.push({ id: key, body: { group_id: gid, user_uid: x.uid || '', user_name: x.name || '', text: x.text || '', ts: Number(x.ts || 0), edited_ts: Number(x.editedTs || 0), deleted: x.deleted === true, reactions: x.reactions || {}, pin_id: x.pinId || '', pin_title: x.pinTitle || '', pin_thumb: x.pinThumb || '', face: x.face || '', color: Number(x.color || 0), face_x: Number(x.faceX || 0), face_y: Number(x.faceY || 0), reply_to_id: x.replyToId || '', reply_to_name: x.replyToName || '', reply_to_text: x.replyToText || '' } }); } }
  await batchWrite('chat_messages', chatItems, 'chat_messages');
  const rd = await rtdb.ref('chats/' + gid + '/reads').get();
  const readItems = [];
  if (rd.exists()) { const reads = rd.val() || {}; for (const uid of Object.keys(reads)) readItems.push({ filter: `group_id="${gid}" && user_uid="${uid}"`, body: { group_id: gid, user_uid: uid, last_read_ts: Number(reads[uid] || 0), updated_at: new Date().toISOString() } }); }
  await batchWrite('chat_reads', readItems, 'chat_reads');

  // 6. widget_data — текущее состояние, re-sync целиком (мало, по 1-2 на группу)
  const wdDocs = (await grp.collection('widgetData').get()).docs;
  const wdItems = await pMap(wdDocs, async (w) => { const x = w.data(); return { filter: `group_id="${gid}" && user_uid="${w.id}"`, body: { group_id: gid, user_uid: w.id, display_name: x.displayName || '', avatar_url: await migUrl(x.avatarUrl, 'avatar'), gender: x.gender || '', status: x.status || '', mood_emoji: x.moodEmoji || '', mood_label: x.moodLabel || '', message: x.message || '', music_title: x.musicTitle || '', music_artist: x.musicArtist || '', music_url: await migUrl(x.musicUrl, 'widget', gid), music_cover_url: await migUrl(x.musicCoverUrl, 'widget', gid), photo_url: await migUrl(x.photoUrl, 'widget', gid), photo_for_partner_url: await migUrl(x.photoForPartnerUrl, 'widget', gid), photo_for_partner_urls: await migArr(x.photoForPartnerUrls, 'widget', gid), photo_grid_count: Number(x.photoGridCount || 1), photo_grid_urls: await migArr(x.photoGridUrls, 'widget', gid), updated_at: iso(x.updatedAt) || new Date().toISOString() } }; }, MEDIA_CONC);
  await batchWrite('widget_data', wdItems, 'widget_data');

  // 7. НОВЫЕ маскоты галереи (createdAt > since)
  const msSnap = await grp.collection('mascots').where('createdAt', '>', SINCE_DATE).get();
  if (!msSnap.empty) {
    const msItems = await pMap(msSnap.docs, async (m) => { const x = m.data(); const mid = x.id || m.id; return { filter: `group_id="${gid}" && mascot_id="${mid}"`, body: { group_id: gid, mascot_id: mid, name: x.name || '', image_url: await migUrl(x.imageUrl, 'mascot', gid), default_asset: x.defaultAsset || '', created_by: x.createdBy || '', created_at: iso(x.createdAt), is_default: x.isDefault === true, record_streak: Number(x.recordStreak || 0) } }; }, MEDIA_CONC);
    await batchWrite('mascots', msItems, 'mascots');
  }

  // 8. miss_you — текущие счётчики, re-sync (max с тем, что в PB)
  const missCounts = {};
  const myRt = await rtdb.ref('missYou/' + gid + '/counts').get();
  if (myRt.exists()) { const v = myRt.val() || {}; for (const u of Object.keys(v)) missCounts[u] = Number(v[u] || 0); }
  if (d.missYouCounts && typeof d.missYouCounts === 'object') for (const u of Object.keys(d.missYouCounts)) missCounts[u] = Math.max(missCounts[u] || 0, Number(d.missYouCounts[u] || 0));
  for (const uid of Object.keys(missCounts)) {
    const c = missCounts[uid]; if (!c || c <= 0) continue;
    const ex = await pb('GET', `/api/collections/miss_you/records?perPage=1&filter=${encodeURIComponent(`group_id="${gid}" && user_uid="${uid}"`)}`);
    const cur = (ex.data && ex.data.items && ex.data.items[0]) ? Number(ex.data.items[0].count || 0) : 0;
    await upsertByFilter('miss_you', `group_id="${gid}" && user_uid="${uid}"`, { group_id: gid, user_uid: uid, count: Math.max(cur, c), updated_at: new Date().toISOString() }); bump('miss_you');
  }
}

// ── НОВЫЕ пользователи (Auth creationTime > since) ───────────────────────────
async function migrateNewUsers() {
  const fresh = [];
  let pageToken;
  do {
    const res = await admin.auth().listUsers(1000, pageToken);
    for (const u of res.users) { const ct = Date.parse(u.metadata.creationTime || ''); if (Number.isFinite(ct) && ct > SINCE_MS) fresh.push(u.uid); }
    pageToken = res.pageToken;
  } while (pageToken);
  console.log(`Новых пользователей с момента since: ${fresh.length}`);
  for (const uid of fresh) {
    const snap = await db.collection('users').doc(uid).get();
    const d = snap.exists ? snap.data() : {};
    let email = d.email || '';
    try { const au = await admin.auth().getUser(uid); email = au.email || email; } catch (_) {}
    const pw = randPw();
    const body = { email: email || `${uid}@migrated.local`, emailVisibility: false, verified: true, display_name: d.displayName || '', avatar_url: await migUrl(d.avatarUrl, 'avatar'), gender: d.gender || '', coins: Number(d.coins || 0), owned_themes: Array.isArray(d.ownedThemes) ? d.ownedThemes : [], owned_icons: Array.isArray(d.ownedIcons) ? d.ownedIcons : [], owned_features: Array.isArray(d.ownedFeatures) ? d.ownedFeatures : [], granted_badges: Array.isArray(d.grantedBadges) ? d.grantedBadges : [], badge: d.badge || '', pair_id: d.pairId || '', pair_ids: Array.isArray(d.pairIds) ? d.pairIds : [], invite_code: d.inviteCode || '', birth_date: iso(d.birthDate), dev_coins_granted: d.devCoinsGranted === true, ad_rewards_date: d.adRewardsDate || '', ad_rewards_today: Number(d.adRewardsToday || 0), solo_timers: Array.isArray(d.soloTimers) ? deepIso(d.soloTimers) : [], notif_miss_you: d.notifMissYou !== false, notif_new_memory: d.notifNewMemory !== false, notif_mood: d.notifMood !== false, notif_chat: d.notifChat !== false, updated_at: new Date().toISOString() };
    const r = await pb('POST', '/api/collections/users/records', { id: uid, ...body, password: pw, passwordConfirm: pw });
    if (r.status === 200) { bump('users_new'); continue; }
    const ex = await pb('GET', `/api/collections/users/records/${uid}`);
    if (ex.status === 200) { const pe = { ...body }; delete pe.email; await pb('PATCH', `/api/collections/users/records/${uid}`, pe); bump('users_new'); }
    else bump('users_skipped_dup');
  }
}

(async () => {
  // ⛔ CUTOVER ЗАВЕРШЁН (2026-06-27) — миграция РЕТАЙРНУТА. Повторный прогон по
  // живой базе клал PocketBase (PK-коллизии «id уже есть» + batch-локи до 169с,
  // держащие единственный SQLite-writer → заморозка всех записей приложения).
  // Запуск намеренно заблокирован. Если ДЕЙСТВИТЕЛЬНО нужно (новый чистый стенд):
  //   MIGRATION_ALLOW=cutover-done-i-am-sure node pocketbase/migrate_delta.js ...
  if (process.env.MIGRATION_ALLOW !== 'cutover-done-i-am-sure') {
    console.error('⛔ migrate_delta РЕТАЙРНУТ (cutover завершён, см. комментарий). Обход: MIGRATION_ALLOW=cutover-done-i-am-sure');
    process.exit(1);
  }
  if (!PB_PW) throw new Error('PB_PW env required');
  await authPb();
  console.log(`ДЕЛЬТА с ${SINCE_DATE.toISOString()} (ms=${SINCE_MS})${NO_BACKFILL ? ' [без бэкфилла штрихов]' : ' [+ бэкфилл штрихов]'}${ONLY_GROUP ? ' [группа ' + ONLY_GROUP + ']' : ''}`);

  if (ONLY_GROUP) {
    await deltaGroup(ONLY_GROUP);
  } else {
    await migrateNewUsers();
    const gsnap = await db.collection('groups').select().get();
    const gidArr = gsnap.docs.map((g) => g.id);
    console.log(`Групп к обходу: ${gidArr.length}`);
    let done = 0; const t0 = Date.now();
    await pMap(gidArr, async (gid) => {
      await deltaGroup(gid); done++;
      if (done % 200 === 0) { const el = ((Date.now() - t0) / 1000).toFixed(0); console.log(`  ...${done}/${gidArr.length} групп · ${el}с · strokes=${stats.canvas_strokes || 0} backfilled-canvas=${stats.canvas_backfilled || 0} failed=${stats.failed || 0}`); }
    }, GROUP_CONC);
  }

  console.log('\n=== ИТОГ ДЕЛЬТЫ ===');
  console.log(JSON.stringify(stats, null, 2));
  if (stats.failed) console.log(`\n⚠️  ПРОВАЛОВ: ${stats.failed}`);
  process.exit(stats.failed ? 1 : 0);
})().catch((e) => { console.error('FATAL', e); process.exit(1); });
