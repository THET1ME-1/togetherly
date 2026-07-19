-- ============================================================
-- Togetherly — удобный просмотр групп с ИМЕНАМИ участников.
-- Run in: Supabase Dashboard → SQL Editor. Идемпотентно.
-- ============================================================
-- В таблице groups рядом с участниками видно только id (members — массив uid).
-- Имена уже хранятся в member_names (карта uid → имя). Это VIEW показывает их
-- списком, НЕ меняя саму таблицу groups (нулевой риск для приложения).
--
-- Где смотреть: Table Editor → раздел Views → groups_readable
--   (или: select * from public.groups_readable;)
-- ============================================================

-- Гард: xp добавляется в level.sql. Дублируем idempotent-ALTER, чтобы VIEW не
-- упал, если level.sql ещё не прогоняли.
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS xp INTEGER NOT NULL DEFAULT 0;

-- DROP + CREATE (а не CREATE OR REPLACE): REPLACE не умеет менять состав/порядок
-- столбцов вида — падает при добавлении колонок в середину. DROP делает скрипт
-- безопасно повторяемым при правках набора столбцов.
DROP VIEW IF EXISTS public.groups_readable;

-- security_invoker = true → вид исполняется с правами вызывающего и УВАЖАЕТ
-- RLS таблицы groups. Без этого вид обходит RLS (Supabase: «UNRESTRICTED») и
-- через API мог бы отдать данные всех пар. Дашборд (service_role) всё равно
-- видит всё. Требует Postgres 15+ (в Supabase есть).
CREATE VIEW public.groups_readable
WITH (security_invoker = true) AS
SELECT
  g.id,
  -- Отдельные столбцы под каждого участника (пара = до 2 человек) — по ним
  -- удобно искать в Table Editor: фильтр по member_1_name ИЛИ member_2_name.
  g.member_names ->> (g.members ->> 0)  AS member_1_name,
  g.member_names ->> (g.members ->> 1)  AS member_2_name,
  -- Имена списком в порядке members, напр. «Аня, Боря» (для общего обзора).
  -- Если у uid нет имени в member_names — показываем сам uid в скобках.
  (
    SELECT string_agg(
             COALESCE(g.member_names ->> m.uid, '(' || m.uid || ')'),
             ', '
             ORDER BY m.ord
           )
    FROM jsonb_array_elements_text(g.members)
         WITH ORDINALITY AS m(uid, ord)
  )                                AS members_named,
  jsonb_array_length(g.members)    AS members_count,
  g.members,                       -- сырые uid (как было)
  g.member_names,                  -- карта uid → имя
  g.xp,
  g.memories_count,
  g.drawings_count,
  g.disbanded,
  g.created_at
FROM public.groups g;

-- Вид — ТОЛЬКО для дашборда (приложение его не читает). Полностью убираем доступ
-- через публичный API: дашборд (service_role) видит всё, anon/authenticated — нет.
REVOKE ALL ON public.groups_readable FROM anon, authenticated;
