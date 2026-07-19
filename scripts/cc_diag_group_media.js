// Диагностика застрявшей медиа-миграции группы (Firebase-сторона).
// Через Admin SDK: читает memories группы из Firestore, собирает медиа-URL и
// проверяет, СУЩЕСТВУЕТ ли каждый файл в Firebase Storage. Если файл отсутствует
// → это он навечно блокирует медиа-миграцию (флаг ставится только при 0 неудач).
// Только чтение, ничего не меняет.
//
//   cp scripts/togetherly-d4856-firebase-adminsdk-*.json scripts/serviceAccountKey.json
//   NODE_PATH=./functions/node_modules node scripts/cc_diag_group_media.js <groupId>
//   rm scripts/serviceAccountKey.json

const admin = require('firebase-admin');
const svc = require('./serviceAccountKey.json');
admin.initializeApp({ credential: admin.credential.cert(svc), storageBucket: `${svc.project_id}.appspot.com` });

const GID = process.argv[2] || 'ADuqhCOwcZg89UyNzZ9D';
const db = admin.firestore();
const bucket = admin.storage().bucket();

const FB_PREFIXES = ['memories/', 'music/', 'timer_backgrounds/', 'widget/', 'groups/', 'avatars/', 'wallpapers/'];
function isFbMedia(u) {
  if (!u || typeof u !== 'string' || u.startsWith('sb://')) return false;
  return u.startsWith('gs://') || u.includes('firebasestorage.googleapis.com')
    || FB_PREFIXES.some((p) => u.startsWith(p));
}
function toPath(u) {
  if (u.startsWith('gs://')) { const p = u.split('/'); return p.length >= 4 ? p.slice(3).join('/') : null; }
  if (FB_PREFIXES.some((p) => u.startsWith(p))) return u.split('?')[0];
  try { const o = new URL(u).searchParams.get('o'); return o ? decodeURIComponent(o) : null; } catch { return null; }
}

(async () => {
  console.log(`\n=== Диагностика медиа группы ${GID} ===\n`);
  const gdoc = await db.collection('groups').doc(GID).get();
  if (!gdoc.exists) { console.log('Группа в Firestore НЕ найдена. Проверь groupId.'); process.exit(0); }
  console.log('members:', JSON.stringify(gdoc.data().members));

  const mems = await db.collection('groups').doc(GID).collection('memories').get();
  console.log(`memories в Firestore: ${mems.size}\n`);

  const urls = [];
  for (const d of mems.docs) {
    const m = d.data();
    for (const f of ['imageUrl', 'videoUrl', 'musicUrl', 'musicCoverUrl']) {
      if (isFbMedia(m[f])) urls.push({ id: d.id, field: f, url: m[f] });
    }
    if (Array.isArray(m.imageUrls)) {
      m.imageUrls.forEach((u, i) => { if (isFbMedia(u)) urls.push({ id: d.id, field: `imageUrls[${i}]`, url: u }); });
    }
  }
  console.log(`Firebase-медиа URL для миграции: ${urls.length}\n`);

  let missing = 0, exists = 0, badpath = 0;
  for (const u of urls) {
    const p = toPath(u.url);
    if (!p) { badpath++; console.log(`⚠️  ${u.id}/${u.field}: путь не распознан — ${u.url.slice(0, 80)}`); continue; }
    try {
      const [ex] = await bucket.file(p).exists();
      if (ex) { exists++; }
      else { missing++; console.log(`❌  ОТСУТСТВУЕТ в Storage: ${p}   (mem ${u.id}/${u.field})`); }
    } catch (e) {
      console.log(`⚠️  ошибка проверки ${p}: ${e.message}`);
    }
  }
  console.log(`\n=== ИТОГ: существуют ${exists}, ОТСУТСТВУЮТ ${missing}, нераспознанный путь ${badpath} ===`);
  console.log(missing > 0
    ? '\n➡️  Подтверждено: мёртвые файлы блокируют флип группы (failures != 0 навсегда).'
    : '\n➡️  Все файлы на месте — блокировка НЕ из-за мёртвых файлов (смотреть compat/_groupMixed или dataDone).');
  process.exit(0);
})().catch((e) => { console.error('FATAL', e); process.exit(1); });
