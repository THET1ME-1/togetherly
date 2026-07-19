/// <reference path="../pb_data/types.d.ts" />
// counters.pb.js — СЕРВЕРНОЕ ведение счётчиков ПАРЫ для достижений.
// AchievementService (клиент) читает их прямо из group-дока:
//   messages_count  → «Первое сообщение / 100 / 1000 сообщений»
//   drawings_count  → «Первый рисунок»
//
// ЗАЧЕМ НА СЕРВЕРЕ (а не в клиенте):
//  • messages_count — колонки не существовало, клиент её НИКОГДА не инкрементил →
//    достижения чата стояли на 0 у ВСЕХ пар (на проде у пары с 266 сообщениями —
//    0/1). Считаем по факту создания записи в chat_messages.
//  • drawings_count — клиент инкрементил лишь при создании холста ЧЕРЕЗ галерею;
//    массовый залив локальных холстов при паринге (canvas_storage_service
//    .pushAllToFirebase) и дефолтный «Canvas 1» шли МИМО счётчика → у пары с 43
//    холстами счётчик 0 («Первый рисунок 0/1»). Считаем по факту записи в
//    canvas_catalogue (единый источник — обе стороны видят один каталог).
//
// Серверный счёт чинит ВСЕХ разом и БЕЗ релиза: выпущенный клиент эти поля уже
// читает. Клиентский инкремент drawings_count обесврежен в groups.pb.js (роут
// /api/group/increment для drawings_count → no-op ok), иначе старые версии,
// всё ещё дёргающие increment, задвоили бы счётчик с этим хуком.
//
// АТОМАРНО: read-modify-write в $app.runInTransaction — PB держит единственный
// write-коннект, поэтому параллельные создания сообщений с двух устройств
// сериализуются (без транзакции lost-update занижал бы счётчик к порогам
// 100/1000). Хук onRecordAfter*Success срабатывает ПОСЛЕ коммита создания →
// собственная транзакция безопасна (ср. birthdays.pb.js: $app.save в afterSuccess).
//
// JSVM-грабли (см. groups.pb.js): хендлер сериализуется и файловых функций НЕ
// видит → вся логика инлайн; сбой счётчика не должен ронять создание записи
// (весь хендлер в try/catch); e.next() — всегда.

// ── Сообщение создано → messages_count += 1 ─────────────────────────────────
onRecordAfterCreateSuccess((e) => {
  try {
    const groupId = e.record.getString("group_id");
    if (groupId) {
      $app.runInTransaction((txApp) => {
        const g = txApp.findRecordById("groups", groupId);
        g.set("messages_count", (g.getInt("messages_count") || 0) + 1);
        txApp.save(g);
      });
    }
  } catch (err) {
    console.log("counters: chat_messages inc failed", err);
  }
  e.next();
}, "chat_messages");

// ── Холст добавлен в каталог → drawings_count += 1 ──────────────────────────
onRecordAfterCreateSuccess((e) => {
  try {
    const groupId = e.record.getString("group_id");
    if (groupId) {
      $app.runInTransaction((txApp) => {
        const g = txApp.findRecordById("groups", groupId);
        g.set("drawings_count", (g.getInt("drawings_count") || 0) + 1);
        txApp.save(g);
      });
    }
  } catch (err) {
    console.log("counters: canvas_catalogue inc failed", err);
  }
  e.next();
}, "canvas_catalogue");

// ── Холст удалён из каталога → drawings_count -= 1 (не ниже 0) ───────────────
onRecordAfterDeleteSuccess((e) => {
  try {
    const groupId = e.record.getString("group_id");
    if (groupId) {
      $app.runInTransaction((txApp) => {
        const g = txApp.findRecordById("groups", groupId);
        const next = (g.getInt("drawings_count") || 0) - 1;
        g.set("drawings_count", next < 0 ? 0 : next);
        txApp.save(g);
      });
    }
  } catch (err) {
    console.log("counters: canvas_catalogue dec failed", err);
  }
  e.next();
}, "canvas_catalogue");
