// Backfill: выдать всем существующим Firebase-юзерам custom claim
// `role: authenticated`. Без него Supabase (Third-Party Auth) даёт запросу роль
// anon и все dual-write под RLS отклоняются. Новые юзеры получают claim через
// слушатель authStateChanges (FirebaseService.ensureSupabaseRole) при первом
// входе/старте; этот скрипт закрывает уже существующих проактивно (важно для
// Stage 3: партнёр должен иметь claim, чтобы его данные читались из Supabase).
//
// Идемпотентно: у кого claim уже стоит — пропускаются. Существующие claims
// сохраняются (merge). Запуск: node scripts/backfill_role_claims.js

const admin = require('firebase-admin');
const svc = require('./serviceAccountKey.json');
admin.initializeApp({ credential: admin.credential.cert(svc) });

(async () => {
  let pageToken;
  let total = 0, already = 0, set = 0, failed = 0;
  do {
    const res = await admin.auth().listUsers(1000, pageToken);
    for (const u of res.users) {
      total++;
      const claims = u.customClaims || {};
      if (claims.role === 'authenticated') { already++; continue; }
      try {
        await admin.auth().setCustomUserClaims(u.uid, { ...claims, role: 'authenticated' });
        set++;
      } catch (e) {
        failed++;
        console.log(`  ! ${u.uid}: ${e.message}`);
      }
    }
    pageToken = res.pageToken;
    process.stdout.write(`\rобработано: ${total}`);
  } while (pageToken);

  console.log(`\n\nВсего юзеров : ${total}`);
  console.log(`Уже было    : ${already}`);
  console.log(`Выдан claim : ${set}`);
  console.log(`Ошибок      : ${failed}`);
  console.log('\nГотово. Юзеры подхватят claim в токене при следующем входе/рефреше.');
  process.exit(failed ? 1 : 0);
})();
