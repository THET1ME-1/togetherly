# Публикация контента в каталог (без релиза приложения)

Картинки кладёшь рядом с JSON-описанием. Скрипт сам конвертит в WebP, заливает в
Supabase Storage (bucket `catalog`) и upsert'ит строку в таблицу `catalog_items`.

## Один раз
1. Выполни `supabase/catalog.sql` в Supabase (SQL Editor) — таблица + bucket.
2. Возьми **service_role** ключ: Supabase → Project Settings → API → service_role.
   Это СЕКРЕТ, не коммить.

## Публикация
```bash
export SUPABASE_SERVICE_KEY=<service_role-ключ>
python tools/catalog_publish.py tools/catalog/autumn.json      # пак
python tools/catalog_publish.py tools/catalog/halloween.json   # маскот
```
Готово — появится у всех в приложении (на сборке с min_app ≤ версии; `null` = у всех).

## Поля описания
- `kind`: `"mood_pack"` или `"mascot"`.
- `removeBg`: `true` — вырезать плоский фон у сырого арта; `false` — картинка уже
  прозрачная (готовые стикеры паков).
- `minApp`: `null` для теста (видно всем) / версия релиза для боевого раскатывания.
- Пак: `moods[]` с `id`+`image`. Известный id (happy/sad…) — просто новый стиль.
  НОВАЯ эмоция — добавь `labelRu`/`labelEn`/`color`/`score`.
- Маскот: одно поле `image`.
- `unlock` (необяз., маскот или пак) — «задание» для разблокировки:
  - `{ "type": "level", "level": N }` — откроется на уровне пары N (XP за активность);
  - `{ "type": "premium" }` — премиум-контент.
  Без поля — бесплатно. Уровни маскотов привязаны к рангам (см. `lib/models/level.dart`):
  Спайки ур.3, Лулу ур.6, Искрик ур.10, Жужа ур.15.
