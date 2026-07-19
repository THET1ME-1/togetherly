/// <reference path="../pb_data/types.d.ts" />
// Счётчик сообщений пары для достижений чата (messages_1 / messages_100 /
// messages_1000). Колонки messages_count в groups НЕ БЫЛО вовсе: AchievementService
// читает group.messages_count, всегда получал 0, и «Первое сообщение / 100 / 1000
// сообщений» НИКОГДА не двигались (на проде у пары с 266 сообщениями — 0/1).
// Зеркалит определение drawings_count / memories_count (number, необязательное).
// Наполнение: серверный хук counters.pb.js (create chat_messages) + разовый
// бэкфилл существующих пар.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("groups")
  collection.fields.add(new Field({
    "hidden": false,
    "id": "number_messagescount",
    "max": null,
    "min": null,
    "name": "messages_count",
    "onlyInt": false,
    "presentable": false,
    "required": false,
    "system": false,
    "type": "number"
  }))
  return app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("groups")
  collection.fields.removeByName("messages_count")
  return app.save(collection)
})
