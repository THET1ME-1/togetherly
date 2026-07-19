/// <reference path="../pb_data/types.d.ts" />
// groups_membership.pb.js — поддерживает скрытое поле users.group_ids
// (мульти-relation на groups) в актуальном состоянии при изменении членства.
//
// ЗАЧЕМ: старое правило доступа парных коллекций
//   @collection.groups.id ?= group_id && @collection.groups.members ?~ @request.auth.id
// компилируется PB в неиндексируемый COALESCE-JOIN groups + JSON_EXTRACT LIKE на
// КАЖДУЮ строку выдачи — на тяжёлых парах (чат 3k+ строк × 8200 групп) такой
// запрос в modernc-SQLite жуётся 30+ секунд и умирает по context deadline
// (инцидент 2026-07-02: «бесконечная синхронизация», мёртвые фоновые виджеты).
// Быстрое правило — `group_id ?= @request.auth.group_ids` — читает членство из
// САМОЙ auth-записи без джойна. Этот хук и держит его свежим.
//
// users.group_ids — HIDDEN-поле: клиент не может ни читать, ни писать его через
// API (иначе можно было бы приписать себе чужую группу), пишем только мы тут
// (raw SQL мимо валидации) и разовый бэкфилл.
//
// Семантика: ВСЕ группы, где uid в members, ВКЛЮЧАЯ disbanded (как в старом
// правиле — надгробия распада должны долетать читателям).
//
// JSVM-грабли (см. memory): вся логика ВНУТРИ хендлеров (модульный уровень им
// не виден), в конце каждого — e.next().

onRecordAfterCreateSuccess((e) => {
  // копия resync-логики в каждом хендлере — JSVM-изоляция
  const uids = e.record.getStringSlice("members") || [];
  for (const uid of uids) {
    if (!uid) continue;
    try {
      $app.db().newQuery(
        "UPDATE users SET group_ids = COALESCE((SELECT json_group_array(g.id) FROM groups g WHERE EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(g.members) THEN g.members ELSE '[]' END) je WHERE je.value = {:uid})), '[]') WHERE id = {:uid}"
      ).bind({ uid: uid }).execute();
    } catch (err) {
      console.log("groups_membership create resync failed", uid, err);
    }
  }
  e.next();
}, "groups");

onRecordAfterUpdateSuccess((e) => {
  // members меняется редко (join/leave), а groups-док пишется ПОСТОЯННО
  // (счётчики/статусы) — пересинк только при реальной смене состава.
  const cur = e.record.getStringSlice("members") || [];
  let old = [];
  try {
    old = e.record.original().getStringSlice("members") || [];
  } catch (err) { /* original недоступен — пересинк текущих не повредит */ }
  const curKey = cur.slice().sort().join(",");
  const oldKey = old.slice().sort().join(",");
  if (curKey === oldKey) { e.next(); return; }
  const seen = {};
  const uids = [];
  for (const u of cur.concat(old)) {
    if (u && !seen[u]) { seen[u] = true; uids.push(u); }
  }
  for (const uid of uids) {
    try {
      $app.db().newQuery(
        "UPDATE users SET group_ids = COALESCE((SELECT json_group_array(g.id) FROM groups g WHERE EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(g.members) THEN g.members ELSE '[]' END) je WHERE je.value = {:uid})), '[]') WHERE id = {:uid}"
      ).bind({ uid: uid }).execute();
    } catch (err) {
      console.log("groups_membership update resync failed", uid, err);
    }
  }
  e.next();
}, "groups");

onRecordAfterDeleteSuccess((e) => {
  const uids = e.record.getStringSlice("members") || [];
  for (const uid of uids) {
    if (!uid) continue;
    try {
      $app.db().newQuery(
        "UPDATE users SET group_ids = COALESCE((SELECT json_group_array(g.id) FROM groups g WHERE EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(g.members) THEN g.members ELSE '[]' END) je WHERE je.value = {:uid})), '[]') WHERE id = {:uid}"
      ).bind({ uid: uid }).execute();
    } catch (err) {
      console.log("groups_membership delete resync failed", uid, err);
    }
  }
  e.next();
}, "groups");
