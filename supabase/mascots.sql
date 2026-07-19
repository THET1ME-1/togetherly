-- ============================================================
-- Togetherly — Этап 5 миграции (срез 1): маскоты + streak.
-- Run in: Supabase Dashboard → SQL Editor → New query → Run
-- Идемпотентный (IF NOT EXISTS / CREATE OR REPLACE) — можно запускать повторно.
-- ============================================================
-- Зеркало Firestore:
--   groups/{g}/mascots/{mascotId}  → public.mascots (галерея маскотов пары)
--   group-doc floating/streak-поля → колонки public.groups:
--     activeMascotId            → active_mascot_id
--     mascotPositionX/Y, scale  → mascot_position_x / _y / mascot_scale
--     streakDays                → streak_days
--     streakLastOpenedDate      → streak_last_opened_date ('YYYY-MM-DD')
-- Колонка groups.mascots (JSONB) — рудимент старого подхода, НЕ используется
-- (реальные маскоты всегда жили в subcollection). Оставлена как есть.
-- realtime .stream() допускает один .eq(): маскоты фильтруются по group_id
-- напрямую (он уникален между группами), составной ключ не нужен.
-- RLS off (Фаза 1), keys = TEXT.
-- ============================================================

-- ── Галерея маскотов группы ───────────────────────────────────
CREATE TABLE IF NOT EXISTS public.mascots (
  group_id      TEXT        NOT NULL,
  id            TEXT        NOT NULL,
  name          TEXT,
  image_url     TEXT,        -- URL рисованного маскота (Firebase/sb://); NULL у дефолтных
  default_asset TEXT,        -- asset-путь дефолтного маскота; NULL у рисованных
  created_by    TEXT,
  created_at    TIMESTAMPTZ,
  is_default    BOOLEAN     NOT NULL DEFAULT FALSE,
  record_streak INTEGER     NOT NULL DEFAULT 0,
  PRIMARY KEY (group_id, id)
);
-- RLS on public.mascots is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).
CREATE INDEX IF NOT EXISTS idx_mascots_group ON public.mascots(group_id);

-- ── Floating-маскот и streak в group-doc → колонки groups ─────
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS active_mascot_id        TEXT;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS mascot_position_x       DOUBLE PRECISION;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS mascot_position_y       DOUBLE PRECISION;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS mascot_scale            DOUBLE PRECISION;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS streak_days             INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS streak_last_opened_date TEXT;
-- Огонёк растёт ТОЛЬКО когда за день отметились ОБА партнёра. Первый зашедший за
-- день фиксируется тут (дата + его uid); второй ОТЛИЧНЫЙ участник «закрывает» день.
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS streak_pending_date     TEXT;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS streak_pending_uid      TEXT;

-- ── Атомарный учёт ежедневной активности (streak) ────────────
-- Аналог FirebaseService.recordGroupActivity. Огонёк растёт только если за день
-- зашли ОБА участника пары (а не один): первый ставит «ожидание»
-- (streak_pending_*), второй РАЗНЫЙ участник — поднимает streak_days. FOR UPDATE
-- сериализует одновременные вызовы. Возвращает текущий streak (вырастет на
-- вызове второго партнёра). p_today = 'YYYY-MM-DD' (локальная дата клиента).
-- uid вызывающего берётся из токена (auth.jwt()->>'sub'), клиент его не передаёт.
CREATE OR REPLACE FUNCTION public.group_record_activity(
  p_group_id TEXT,
  p_today    TEXT
) RETURNS INTEGER AS $$
DECLARE
  v_uid    TEXT := auth.jwt() ->> 'sub';
  v_last   TEXT;
  v_cur    INTEGER;
  v_active TEXT;
  v_pdate  TEXT;
  v_puid   TEXT;
  v_new    INTEGER;
BEGIN
  IF NOT public.is_group_member(p_group_id) THEN
    RAISE EXCEPTION 'forbidden: not a group member' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT streak_last_opened_date, COALESCE(streak_days, 0), active_mascot_id,
         streak_pending_date, streak_pending_uid
    INTO v_last, v_cur, v_active, v_pdate, v_puid
    FROM public.groups
   WHERE id = p_group_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- Огонёк за сегодня уже засчитан (оба отметились ранее).
  IF v_last = p_today THEN
    RETURN v_cur;
  END IF;

  -- Второй РАЗНЫЙ участник отметился сегодня → пара «оба зашли» → растим огонёк.
  IF v_pdate = p_today AND v_puid IS NOT NULL AND v_puid <> v_uid THEN
    IF v_last IS NOT NULL AND (p_today::date - v_last::date) = 1 THEN
      v_new := v_cur + 1;               -- следующий подряд день (где оба заходили)
    ELSE
      v_new := 1;                       -- первый общий день или разрыв
    END IF;
    UPDATE public.groups
       SET streak_days = v_new, streak_last_opened_date = p_today
     WHERE id = p_group_id;
    IF v_active IS NOT NULL THEN
      UPDATE public.mascots
         SET record_streak = v_new
       WHERE group_id = p_group_id AND id = v_active AND record_streak < v_new;
    END IF;
    RETURN v_new;
  END IF;

  -- Первый участник за сегодня (или повторный заход того же) — ставим ожидание
  -- партнёра. Огонёк пока НЕ растёт.
  IF v_pdate IS DISTINCT FROM p_today OR v_puid IS NULL THEN
    UPDATE public.groups
       SET streak_pending_date = p_today, streak_pending_uid = v_uid
     WHERE id = p_group_id;
  END IF;
  RETURN v_cur;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.group_record_activity(TEXT, TEXT)
  TO anon, authenticated;

-- ── Realtime ──────────────────────────────────────────────────
DO $$
BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.mascots; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;
