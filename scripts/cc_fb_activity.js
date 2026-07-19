// READ-ONLY: объём дельты для миграции. Делит активность на:
//   • НОВЫЕ      = createTime в окне (новые пары/люди → перенести целиком)
//   • СТАРЫЕ+нов = createTime ДО окна, но updateTime в окне (старая пара,
//                  появились новые данные → до-синхронизировать)
// updateTime/createTime — серверные метаданные документа (не поля приложения).
// Ничего не пишет.
const admin = require("firebase-admin");
const sa = require("./serviceAccountKey.json");
admin.initializeApp({ credential: admin.credential.cert(sa) });
const db = admin.firestore();

const DAY = 24 * 3600 * 1000;
const now = Date.now();
const buckets = [1, 3, 7, 14, 30];

async function scan(coll) {
  const created = Object.fromEntries(buckets.map((b) => [b, 0]));
  const updatedOld = Object.fromEntries(buckets.map((b) => [b, 0]));
  let total = 0;
  let q = db.collection(coll).select("__name__").limit(3000);
  let last = null;
  while (true) {
    let qq = last
      ? db.collection(coll).select("__name__").startAfter(last).limit(3000)
      : q;
    const snap = await qq.get();
    if (snap.empty) break;
    for (const doc of snap.docs) {
      total++;
      const ct = doc.createTime ? doc.createTime.toDate().getTime() : 0;
      const ut = doc.updateTime ? doc.updateTime.toDate().getTime() : 0;
      for (const b of buckets) {
        const edge = now - b * DAY;
        if (ct >= edge) created[b]++;
        else if (ut >= edge) updatedOld[b]++; // создан раньше окна, но обновлён в окне
      }
    }
    last = snap.docs[snap.docs.length - 1];
    if (snap.size < 3000) break;
  }
  return { coll, total, created, updatedOld };
}

(async () => {
  for (const coll of ["users", "groups"]) {
    try {
      const r = await scan(coll);
      console.log(`\n=== ${r.coll}: всего ${r.total} ===`);
      console.log("окно | НОВЫХ (создано) | СТАРЫХ с новыми данными (обновлено)");
      for (const b of buckets) {
        console.log(`  ${b}д | ${r.created[b]} | ${r.updatedOld[b]}`);
      }
    } catch (e) {
      console.log(`scan ${coll} err:`, e.message);
    }
  }
  process.exit(0);
})();
