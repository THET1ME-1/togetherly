/// <reference path="../pb_data/types.d.ts" />
// birthdays.pb.js — зеркалит users.birth_date в groups.member_birthdays.
//
// ЗАЧЕМ: экран важных дат ЧИТАЕТ ДР партнёра только из groups.member_birthdays
// (pb_data_service.groupRecordToPairMap), а «Мой день рождения» ПИШЕТСЯ только в
// users.birth_date (user_data.updateBirthDate). Писателя в member_birthdays в
// клиенте нет вовсе — звено потерялось при переезде с Firebase (в Supabase-эпоху
// его закрывал RPC group_set_member_birthday, в PB аналог не портировали).
// Итог: у ВСЕХ немигрированных пар ДР партнёра — вечное «Не установлен»
// (проверено на проде 2026-07-17: 0 групп с ISO-датами против 4639 мигрированных).
// Правило users (`id = @request.auth.id`) читать чужой профиль не даёт, поэтому
// чинить надо зеркалированием в группу — как уже сделано для имён/аватаров.
//
// ПОЧЕМУ НА СЕРВЕРЕ, А НЕ В КЛИЕНТЕ: серверный синк чинит всех разом и без
// релиза — выпущенный клиент member_birthdays уже читает и ISO-строку понимает,
// ему просто нечего было там найти. Клиентская правка требовала бы обновления
// ОБОИХ партнёров и повторного ввода даты руками.
//
// MERGE-ONLY: ключ пишется только тому, у кого birth_date непустой. Отсутствие
// даты НЕ удаляет ключ — иначе у мигрированных пар (member_birthdays в формате
// Firestore {_seconds}, users.birth_date пуст) мы бы стёрли единственную копию.
// Легитимной «очистки» даты в UI нет: пикеры всегда ставят непустое значение.
//
// ФОРМАТ — ISO с 'T' (PB хранит datetime как "2010-08-31 05:32:00.000Z"):
// клиентский _date() принимает String через DateTime.tryParse, а также
// Firestore-формат {_seconds,_nanoseconds} и epoch — оба вида в поле уживаются.
//
// ЗАПИСЬ ЧЕРЕЗ ORM ($app.save), а не raw SQL: save шлёт realtime-событие, и
// партнёр видит дату сразу. Рекурсии нет — guard на смену состава/даты гасит
// повторный заход. (Разовый бэкфилл 9.8k групп — наоборот, raw SQL мимо ORM:
// массовый realtime-шторм там не нужен, см. scratchpad/backfill_birthdays.sh.)
//
// JSVM-грабли (см. groups_membership.pb.js): модульный уровень хендлерам не
// виден — логика дублируется ВНУТРИ каждого. Весь хендлер в try/catch: сбой
// зеркалирования не должен ронять сохранение профиля/группы. e.next() — всегда.

onRecordAfterUpdateSuccess((e) => {
  try {
    // users пишется постоянно (коины, presence, токены), а ДР меняется раз в
    // жизнь — работаем только при реальной смене birth_date.
    const cur = e.record.getString("birth_date") || "";
    let old = "";
    try {
      old = e.record.original().getString("birth_date") || "";
    } catch (err) { /* original недоступен — лишний проход идемпотентен */ }
    if (cur && cur !== old) {
      const uid = e.record.id;
      const iso = cur.replace(" ", "T");
      const groups = $app.findRecordsByFilter(
        "groups", "members ~ {:u} && disbanded = false", "", 0, 0, { u: uid });
      for (const g of groups) {
        let map = {};
        try { map = JSON.parse(g.getString("member_birthdays") || "{}") || {}; }
        catch (err) { map = {}; }
        if (map[uid] === iso) continue; // уже актуально — не будим realtime зря
        map[uid] = iso;
        g.set("member_birthdays", map);
        $app.save(g);
      }
    }
  } catch (err) {
    console.log("birthdays: users→groups sync failed", err);
  }
  e.next();
}, "users");

onRecordAfterCreateSuccess((e) => {
  try {
    // Новая пара: member_birthdays пуст, а ДР у обоих могли быть заданы задолго
    // до знакомства — собираем карту из профилей участников.
    const members = e.record.getStringSlice("members") || [];
    let map = {};
    try { map = JSON.parse(e.record.getString("member_birthdays") || "{}") || {}; }
    catch (err) { map = {}; }
    let dirty = false;
    for (const uid of members) {
      if (!uid) continue;
      let bd = "";
      try { bd = $app.findRecordById("users", uid).getString("birth_date") || ""; }
      catch (err) { continue; } // профиля нет — пропускаем, не роняя создание пары
      if (!bd) continue;
      const iso = bd.replace(" ", "T");
      if (map[uid] === iso) continue;
      map[uid] = iso;
      dirty = true;
    }
    if (dirty) {
      e.record.set("member_birthdays", map);
      $app.save(e.record);
    }
  } catch (err) {
    console.log("birthdays: group create sync failed", err);
  }
  e.next();
}, "groups");

onRecordAfterUpdateSuccess((e) => {
  try {
    // Партнёр принял инвайт и вошёл в существующую группу — подтянуть его ДР.
    // groups-док пишется постоянно (счётчики/статусы), поэтому реагируем только
    // на реальную смену состава. Этот же guard гасит рекурсию от нашего save.
    const cur = e.record.getStringSlice("members") || [];
    let old = [];
    try {
      old = e.record.original().getStringSlice("members") || [];
    } catch (err) { /* original недоступен — пересинк текущих не повредит */ }
    if (cur.slice().sort().join(",") !== old.slice().sort().join(",")) {
      let map = {};
      try { map = JSON.parse(e.record.getString("member_birthdays") || "{}") || {}; }
      catch (err) { map = {}; }
      let dirty = false;
      for (const uid of cur) {
        if (!uid) continue;
        let bd = "";
        try { bd = $app.findRecordById("users", uid).getString("birth_date") || ""; }
        catch (err) { continue; }
        if (!bd) continue;
        const iso = bd.replace(" ", "T");
        if (map[uid] === iso) continue;
        map[uid] = iso;
        dirty = true;
      }
      if (dirty) {
        e.record.set("member_birthdays", map);
        $app.save(e.record);
      }
    }
  } catch (err) {
    console.log("birthdays: group members sync failed", err);
  }
  e.next();
}, "groups");
