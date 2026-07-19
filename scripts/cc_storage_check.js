// Фокус-тест Supabase STORAGE (сторона медиа-миграции).
// Проверяет, может ли authenticated-юзер (Firebase-токен) ЗАГРУЗИТЬ файл в
// бакеты media (приватный) и avatars, и что аноним заблокирован RLS. Этим
// бисектим причину застрявшей медиа-миграции: если загрузка в Supabase РАБОТАЕТ,
// значит миграция падает на СКАЧИВАНИИ из Firebase (мёртвый/недоступный файл), а
// не на стороне Supabase. Создаёт 1 синтетического юзера, всё за собой чистит.
//
// Запуск:
//   cp scripts/togetherly-d4856-firebase-adminsdk-*.json scripts/serviceAccountKey.json
//   NODE_PATH=./functions/node_modules node scripts/cc_storage_check.js
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

const TAG = '__ccstorage__' + Date.now();
function check(name, pass, detail = '') {
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

// Supabase Storage REST: upload/get/delete объекта.
async function sbUpload(bucket, objPath, token, bytes, contentType) {
  const r = await fetch(`${SB_URL}/storage/v1/object/${bucket}/${objPath}`, {
    method: 'POST',
    headers: {
      apikey: SB_KEY,
      Authorization: `Bearer ${token || SB_KEY}`,
      'Content-Type': contentType,
      'x-upsert': 'true',
    },
    body: bytes,
  });
  const txt = await r.text();
  return { status: r.status, body: txt };
}
async function sbDelete(bucket, objPath, token) {
  const r = await fetch(`${SB_URL}/storage/v1/object/${bucket}/${objPath}`, {
    method: 'DELETE',
    headers: { apikey: SB_KEY, Authorization: `Bearer ${token || SB_KEY}` },
  });
  return r.status;
}

(async () => {
  let uid = null;
  const mediaPath = `memories/${TAG}/probe.txt`;   // путь как у медиа-миграции
  const avatarPath = `${TAG}/probe.txt`;
  const bytes = Buffer.from('cc-storage-probe');
  try {
    const u = await admin.auth().createUser({
      email: `cc-storage-${Date.now()}@cctest.invalid`,
      password: 'Test!' + Math.random().toString(36),
    });
    uid = u.uid;
    await admin.auth().setCustomUserClaims(uid, { role: 'authenticated' });
    const token = await idTokenFor(uid);
    check('Firebase: synthetic authenticated user + token', true, uid.slice(0, 8));

    // 1. authenticated → media (приватный бакет, путь как memories/…)
    const up = await sbUpload('media', mediaPath, token, bytes, 'text/plain');
    check('media: authenticated MAY upload (Supabase-сторона медиа-миграции)',
      ok(up.status), `HTTP ${up.status} ${up.body.slice(0, 160)}`);

    // 2. authenticated → avatars
    const upA = await sbUpload('avatars', avatarPath, token, bytes, 'text/plain');
    check('avatars: authenticated MAY upload', ok(upA.status),
      `HTTP ${upA.status} ${upA.body.slice(0, 160)}`);

    // 3. anon (без user-токена, только publishable) → media должен быть ЗАПРЕЩЁН
    const anon = await sbUpload('media', `${TAG}/anon.txt`, null, bytes, 'text/plain');
    check('media: anon upload ЗАПРЕЩЁН (RLS)', !ok(anon.status),
      `HTTP ${anon.status}`);

    // Чистим загруженные объекты
    if (ok(up.status)) await sbDelete('media', mediaPath, token);
    if (ok(upA.status)) await sbDelete('avatars', avatarPath, token);
    if (ok(anon.status)) await sbDelete('media', `${TAG}/anon.txt`, token);
  } catch (e) {
    check('FATAL', false, e.message);
  } finally {
    if (uid) { try { await admin.auth().deleteUser(uid); } catch (_) {} }
    console.log('\n— очистка завершена —');
    process.exit(0);
  }
})();

function ok(s) { return s >= 200 && s < 300; }
