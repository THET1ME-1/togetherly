#!/bin/bash
# backfill_birthdays.sh — разовое зеркалирование users.birth_date → groups.member_birthdays.
#
# Чинит «День рождения партнёра: Не установлен» для уже существующих пар БЕЗ
# обновления приложения (выпущенный клиент это поле читает и ISO понимает —
# ему просто нечего было там найти).
#
# БЕЗОПАСНОСТЬ:
#   * merge-only (json_patch) — только добавляет/обновляет ключи тех, у кого есть
#     birth_date. Ничего не удаляет: у мигрированных пар Firestore-формат остаётся.
#   * тяжёлый скан (json_each по 9.8k групп, ~2 мин на 3.3G базе) делается ОДИН раз
#     на чтение; запись идёт батчами по PK — короткими транзакциями, чтобы не
#     держать SQLite-writer (инцидент 2026-06-27: длинный writer + retry-storm
#     положили PB).
#   * идемпотентно: повторный прогон не трогает уже синхронизированные группы.
#   * DRY=1 — только считает и показывает примеры, ничего не пишет.
#
# Запуск:  DRY=1 ./backfill_birthdays.sh   # посмотреть объём
#          ./backfill_birthdays.sh          # применить

set -euo pipefail

DB=${DB:-/opt/pocketbase/pb_data/data.db}
IDS=${IDS:-/tmp/bd_ids.txt}
BATCH=${BATCH:-200}
PAUSE=${PAUSE:-0.2}
DRY=${DRY:-0}

q() { sqlite3 -cmd ".timeout 10000" "$DB" "$@"; }

# --- Шаг 1: один тяжёлый скан — кому синк реально что-то даст -----------------
# (есть член с непустым birth_date, и карта ещё не содержит его актуальный ISO)
echo "Сканирую (это ~2 минуты, только чтение)..."
q "
SELECT g.id FROM groups g
WHERE g.disbanded = false
  AND EXISTS (
    SELECT 1 FROM users u
    WHERE u.birth_date IS NOT NULL AND u.birth_date != ''
      AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(g.members) THEN g.members ELSE '[]' END) je
                  WHERE je.value = u.id)
      AND (
        NOT json_valid(g.member_birthdays)
        OR json_type(g.member_birthdays) != 'object'
        OR json_extract(g.member_birthdays, '\$.' || u.id) IS NULL
        OR json_extract(g.member_birthdays, '\$.' || u.id) != replace(u.birth_date, ' ', 'T')
      )
  );
" > "$IDS"

TOTAL=$(wc -l < "$IDS")
echo "Групп требует синка: $TOTAL"
[ "$TOTAL" -eq 0 ] && { echo "Нечего делать."; exit 0; }

if [ "$DRY" = "1" ]; then
  echo "--- DRY RUN, ничего не записано ---"
  echo "Первые 5 групп и их текущее member_birthdays:"
  head -5 "$IDS" | while read -r gid; do
    q "SELECT '  ' || id || ' → ' || COALESCE(NULLIF(substr(member_birthdays,1,50),''),'(пусто)') FROM groups WHERE id='$gid';"
  done
  exit 0
fi

# --- Шаг 2: запись батчами по PK ---------------------------------------------
DONE=0
while IFS= read -r -d '' chunk; do
  # chunk — до $BATCH id, разделённых запятыми и закавыченных
  q "
  UPDATE groups SET member_birthdays = json_patch(
    CASE WHEN json_valid(member_birthdays) AND json_type(member_birthdays) = 'object'
         THEN member_birthdays ELSE '{}' END,
    COALESCE((
      SELECT json_group_object(u.id, replace(u.birth_date, ' ', 'T')) FROM users u
      WHERE u.birth_date IS NOT NULL AND u.birth_date != ''
        AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(groups.members) THEN groups.members ELSE '[]' END) je
                    WHERE je.value = u.id)
    ), '{}')
  ) WHERE id IN ($chunk);
  "
  n=$(printf '%s' "$chunk" | tr -cd ',' | wc -c)
  DONE=$(( DONE + n + 1 ))
  echo "  синхронизировано $DONE / $TOTAL"
  sleep "$PAUSE"
done < <(awk -v b="$BATCH" '
  { ids = (NR % b == 1 || b == 1) ? "\047" $0 "\047" : ids ",\047" $0 "\047" }
  NR % b == 0 { printf "%s%c", ids, 0; ids = "" }
  END { if (ids != "") printf "%s%c", ids, 0 }
' "$IDS")

echo "Готово. Синхронизировано групп: $DONE"
echo "--- Итог по базе ---"
q "SELECT CASE
     WHEN member_birthdays IS NULL OR member_birthdays='' OR member_birthdays='{}' THEN 'пусто'
     WHEN member_birthdays LIKE '%_seconds%' THEN 'остался firestore'
     ELSE 'iso (читается клиентом)' END AS формат, COUNT(*)
   FROM groups GROUP BY формат;"
