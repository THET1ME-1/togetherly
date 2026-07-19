-- ============================================================
-- Togetherly — СИСТЕМА УРОВНЕЙ ПАРЫ: общий счётчик опыта groups.xp.
-- Уровень/ранг считаются на клиенте из xp (models/level.dart) — в БД только xp.
-- Растёт как memoriesCount: дуал-райт Firebase increment + этот RPC.
-- Run in: Supabase Dashboard → SQL Editor. Идемпотентно (можно повторно).
-- ============================================================

ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS xp INTEGER NOT NULL DEFAULT 0;

-- group_inc_counters расширен параметром p_xp (см. group_ops.sql — канон).
-- Дублируем здесь, чтобы файл был самодостаточным. Дроп старой 2-арг сигнатуры
-- убирает неоднозначность перегрузок.
DROP FUNCTION IF EXISTS public.group_inc_counters(TEXT, INT, INT);
CREATE OR REPLACE FUNCTION public.group_inc_counters(
  p_group_id TEXT,
  p_memories INT DEFAULT 0,
  p_drawings INT DEFAULT 0,
  p_xp       INT DEFAULT 0
) RETURNS VOID AS $$
  UPDATE public.groups
     SET memories_count = GREATEST(0, COALESCE(memories_count, 0) + p_memories),
         drawings_count = GREATEST(0, COALESCE(drawings_count, 0) + p_drawings),
         xp             = GREATEST(0, COALESCE(xp, 0) + p_xp)
   WHERE id = p_group_id;
$$ LANGUAGE sql;

GRANT EXECUTE ON FUNCTION public.group_inc_counters(TEXT, INT, INT, INT)
  TO anon, authenticated;
