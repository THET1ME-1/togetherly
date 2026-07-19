/**
 * backfill_group_counts.js
 *
 * Проставляет memoriesCount и drawingsCount на все группы Firestore,
 * у которых эти поля отсутствуют. После запуска count() fallback в
 * getGroupMemoriesCount/getGroupDrawingsCount больше не будет срабатывать,
 * что устранит ~317K лишних Firestore reads в день.
 *
 * Запуск:
 *   1. npm install firebase-admin  (в папке scripts)
 *   2. Скачай service account key:
 *      Firebase Console → Project Settings → Service accounts → Generate new private key
 *      Сохрани как scripts/serviceAccountKey.json
 *   3. node scripts/backfill_group_counts.js
 *
 * Флаги:
 *   --dry-run   Только показывает что нужно обновить, ничего не пишет
 */

const admin = require('firebase-admin');
const path = require('path');

const DRY_RUN = process.argv.includes('--dry-run');

const serviceAccount = require(path.resolve(__dirname, 'serviceAccountKey.json'));
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

const db = admin.firestore();

async function main() {
  console.log(DRY_RUN ? '[DRY RUN] Не пишем в Firestore' : 'Запуск бэкфилла...');

  const groupsSnap = await db.collection('groups').get();
  console.log(`Всего групп: ${groupsSnap.size}`);

  let updated = 0;
  let skipped = 0;

  const BATCH_SIZE = 400;
  let batch = db.batch();
  let batchCount = 0;

  for (const groupDoc of groupsSnap.docs) {
    const data = groupDoc.data();
    const needsMemories = data.memoriesCount == null;
    const needsDrawings = data.drawingsCount == null;

    if (!needsMemories && !needsDrawings) {
      skipped++;
      continue;
    }

    const update = {};

    if (needsMemories) {
      const snap = await groupDoc.ref.collection('memories').count().get();
      update.memoriesCount = snap.data().count;
    }
    if (needsDrawings) {
      const snap = await groupDoc.ref.collection('canvases').count().get();
      update.drawingsCount = snap.data().count;
    }

    console.log(`  ${groupDoc.id}: memoriesCount=${update.memoriesCount ?? '(уже есть)'}, drawingsCount=${update.drawingsCount ?? '(уже есть)'}`);

    if (!DRY_RUN) {
      batch.update(groupDoc.ref, update);
      batchCount++;

      if (batchCount >= BATCH_SIZE) {
        await batch.commit();
        batch = db.batch();
        batchCount = 0;
      }
    }

    updated++;
  }

  if (!DRY_RUN && batchCount > 0) {
    await batch.commit();
  }

  console.log(`\nГотово: обновлено ${updated}, пропущено ${skipped} (поля уже были)`);
}

main().catch(console.error).finally(() => process.exit());
