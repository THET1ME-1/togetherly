/**
 * cleanup_duplicate_members.js
 *
 * Удаляет дублирующиеся UIDs из массива members в каждой группе Firestore.
 * Также удаляет «призрачные» UIDs: те, которые есть в members, но не
 * существуют в Firebase Auth (анонимные сессии от debug-тестирования).
 *
 * Запуск:
 *   1. npm install firebase-admin
 *   2. Скачай service account key:
 *      Firebase Console → Project Settings → Service accounts → Generate new private key
 *      Сохрани как scripts/serviceAccountKey.json
 *   3. node scripts/cleanup_duplicate_members.js
 *
 *   Флаги:
 *     --dry-run   Только показывает что будет изменено, ничего не пишет в Firestore
 *     --fix-ghosts Дополнительно удаляет UIDs которых нет в Firebase Auth
 */

const admin = require('firebase-admin');
const path = require('path');

const DRY_RUN = process.argv.includes('--dry-run');
const FIX_GHOSTS = process.argv.includes('--fix-ghosts');

const KEY_PATH = path.join(__dirname, 'togetherly-d4856-firebase-adminsdk-fbsvc-f1cdf08979.json');

try {
  const serviceAccount = require(KEY_PATH);
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
} catch (e) {
  console.error('❌  serviceAccountKey.json не найден.');
  console.error('   Скачай его: Firebase Console → Project Settings → Service accounts → Generate new private key');
  console.error('   Сохрани как: scripts/serviceAccountKey.json');
  process.exit(1);
}

const db = admin.firestore();
const auth = admin.auth();

async function uidExists(uid) {
  try {
    await auth.getUser(uid);
    return true;
  } catch {
    return false;
  }
}

async function run() {
  console.log(`🔍  Сканирую группы в проекте togetherly-d4856...`);
  if (DRY_RUN) console.log('⚠️   Режим --dry-run: изменения НЕ записываются\n');
  if (FIX_GHOSTS) console.log('👻  Режим --fix-ghosts: удаляю UIDs которых нет в Auth\n');

  const snapshot = await db.collection('groups').get();
  console.log(`   Найдено групп: ${snapshot.size}\n`);

  let fixed = 0;
  let skipped = 0;

  for (const doc of snapshot.docs) {
    const groupId = doc.id;
    const data = doc.data();
    const rawMembers = Array.isArray(data.members) ? data.members : [];

    // 1. Дедупликация одинаковых UIDs
    const unique = [...new Set(rawMembers)];
    const hadDuplicates = unique.length < rawMembers.length;

    if (hadDuplicates) {
      const dupes = rawMembers.filter((uid, i) => rawMembers.indexOf(uid) !== i);
      console.log(`🔴  Группа ${groupId}`);
      console.log(`    members было: [${rawMembers.join(', ')}]`);
      console.log(`    Дубли: [${[...new Set(dupes)].join(', ')}]`);
    }

    // 2. Удаление «призрачных» UIDs (нет в Firebase Auth)
    let validMembers = unique;
    if (FIX_GHOSTS) {
      const ghostUids = [];
      for (const uid of unique) {
        const exists = await uidExists(uid);
        if (!exists) ghostUids.push(uid);
      }
      if (ghostUids.length > 0) {
        console.log(`👻  Группа ${groupId} — призрачные UIDs: [${ghostUids.join(', ')}]`);
        validMembers = unique.filter(uid => !ghostUids.includes(uid));
      }
    }

    const needsUpdate = validMembers.length < rawMembers.length;

    if (!needsUpdate) {
      skipped++;
      continue;
    }

    // Чистим memberNames и memberAvatars от ключей которых нет в validMembers
    const memberNames = data.memberNames || {};
    const memberAvatars = data.memberAvatars || {};
    const cleanedNames = {};
    const cleanedAvatars = {};
    for (const uid of validMembers) {
      if (memberNames[uid] !== undefined) cleanedNames[uid] = memberNames[uid];
      if (memberAvatars[uid] !== undefined) cleanedAvatars[uid] = memberAvatars[uid];
    }

    console.log(`    ✅  members после: [${validMembers.join(', ')}]`);

    if (!DRY_RUN) {
      await doc.ref.update({
        members: validMembers,
        memberNames: cleanedNames,
        memberAvatars: cleanedAvatars,
      });
      console.log(`    💾  Сохранено в Firestore\n`);
    } else {
      console.log(`    📋  (dry-run, не сохраняю)\n`);
    }

    fixed++;
  }

  console.log('─'.repeat(50));
  console.log(`Итого:`);
  console.log(`  Исправлено групп: ${fixed}`);
  console.log(`  Без изменений:    ${skipped}`);
  if (DRY_RUN) console.log('\n  Запусти без --dry-run чтобы применить изменения.');

  process.exit(0);
}

run().catch(err => {
  console.error('❌  Ошибка:', err);
  process.exit(1);
});
