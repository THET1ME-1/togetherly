/**
 * ТОЧЕЧНЫЙ безопасный бэкфилл ТОЛЬКО mood_entries + miss_you (Firebase → PB) для
 * конкретных пар/групп. В отличие от полного migrate_from_firebase.js НЕ трогает
 * group-док и прочие коллекции — чтобы не затереть живые PB-данные (member_moods/
 * xp/timers/current_status и т.п.), которые могли измениться уже на PB.
 *
 * Идемпотентно: mood_entries — upsertById по entryId; miss_you — max(текущий, исходный).
 *
 * Запуск (по email пары и/или явным group id):
 *   PB_EMAIL=<superuser> PB_PW=<pass> \
 *     node pocketbase/backfill_mood_missyou.js badzoff@gmail.com ashatilov2008@gmail.com
 *   PB_EMAIL=... PB_PW=... node pocketbase/backfill_mood_missyou.js 1TzAvReSf2lyxiFZHeeg
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
const PB_EMAIL = process.env.PB_EMAIL || 'badzoff@gmail.com';
let TOKEN = null;

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
    { identity: PB_EMAIL, password: PB_PW });
  if (r.status !== 200) throw new Error('PB auth failed: ' + JSON.stringify(r.data));
  TOKEN = r.data.token;
}
async function upsertById(col, id, body) {
  let r = await pb('POST', `/api/collections/${col}/records`, { id, ...body });
  if (r.status === 400) r = await pb('PATCH', `/api/collections/${col}/records/${id}`, body);
  if (r.status !== 200) console.log(`  ! ${col}/${id}: ${r.status} ${JSON.stringify(r.data).slice(0, 160)}`);
  return r;
}
async function upsertByFilter(col, filter, body) {
  const g = await pb('GET', `/api/collections/${col}/records?perPage=1&filter=${encodeURIComponent(filter)}`);
  if (g.data && g.data.items && g.data.items.length) {
    return pb('PATCH', `/api/collections/${col}/records/${g.data.items[0].id}`, body);
  }
  const r = await pb('POST', `/api/collections/${col}/records`, body);
  if (r.status !== 200) console.log(`  ! ${col}: ${r.status} ${JSON.stringify(r.data).slice(0, 160)}`);
  return r;
}
function iso(v) {
  if (v == null) return null;
  if (typeof v === 'object' && typeof v.toDate === 'function') return v.toDate().toISOString();
  if (typeof v === 'object' && v._seconds != null) return new Date(v._seconds * 1000).toISOString();
  if (typeof v === 'string') return v || null;
  if (typeof v === 'number') return new Date(v).toISOString();
  return null;
}
const stats = {};
const bump = (k) => stats[k] = (stats[k] || 0) + 1;

async function backfillGroup(gid) {
  const snap = await db.collection('groups').doc(gid).get();
  if (!snap.exists) { console.log('  group missing:', gid); return; }
  const d = snap.data();
  const members = Array.isArray(d.members) ? d.members : [];

  // mood_entries: v2 month-доки (.entries map) + v1 legacy подколлекция entries.
  for (const uid of members) {
    const calBase = db.collection('groups').doc(gid).collection('moodCalendar').doc(uid);
    const writeMood = async (entryId, e) => {
      if (!entryId || !e || typeof e !== 'object') return;
      await upsertById('mood_entries', entryId, {
        group_id: gid, user_uid: uid,
        mood_id: e.moodId || '', image_path: e.imagePath || '', label: e.label || '',
        timestamp: iso(e.timestamp) || new Date().toISOString(),
      });
      bump('mood_entries');
    };
    const months = await calBase.collection('months').get();
    for (const mdoc of months.docs) {
      const entries = (mdoc.data() || {}).entries || {};
      for (const eid of Object.keys(entries)) await writeMood(eid, entries[eid]);
    }
    const legacy = await calBase.collection('entries').get();
    for (const ldoc of legacy.docs) await writeMood(ldoc.id, ldoc.data());
  }

  // miss_you: RTDB missYou/{gid}/counts + legacy d.missYouCounts; max() при повторе.
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
      group_id: gid, user_uid: uid, count: Math.max(cur, c),
      updated_at: new Date().toISOString(),
    });
    bump('miss_you');
  }
  console.log(`  group ${gid}: ok`);
}

(async () => {
  if (!PB_PW) throw new Error('PB_PW env required');
  await authPb();
  const args = process.argv.slice(2);
  const gids = new Set();
  for (const a of args) {
    if (a.includes('@')) {
      let u = null;
      try { u = await admin.auth().getUserByEmail(a); } catch (_) { console.log('email не найден:', a); continue; }
      const gq = await db.collection('groups').where('members', 'array-contains', u.uid).get();
      gq.docs.forEach((g) => gids.add(g.id));
    } else {
      gids.add(a);
    }
  }
  console.log(`Групп к бэкфиллу: ${gids.size}`);
  for (const gid of gids) await backfillGroup(gid);
  console.log('\n=== ИТОГ БЭКФИЛЛА ===');
  console.log(JSON.stringify(stats, null, 2));
  process.exit(0);
})().catch((e) => { console.error('FATAL', e); process.exit(1); });
