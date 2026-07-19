/// <reference path="../pb_data/types.d.ts" />
// Per-mascot серия (умирающий маскот): хранит {mascot_id: {s:серия, d:"YYYY-MM-DD"}}
// в group-доке. Серия растёт когда оба партнёра зашли за день, привязана к
// активному маскоту; пропуск дня → маскот «умирает» (серия со следующего общего
// дня стартует с 1). Заменяет единую парную streak_days в отображении.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("groups")
  collection.fields.add(new Field({
    "hidden": false,
    "id": "json_mascotstreaks",
    "maxSize": 2000000,
    "name": "mascot_streaks",
    "presentable": false,
    "required": false,
    "system": false,
    "type": "json"
  }))
  return app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("groups")
  collection.fields.removeByName("mascot_streaks")
  return app.save(collection)
})
