-- ============================================================
-- Togetherly — комментарии к воспоминаниям (этап 3c миграции)
-- Запускать в: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================
-- Зеркало Firestore-сабколлекции groups/{g}/memories/{m}/comments/{id}.
-- RLS off (Phase 1), keys = TEXT (Firebase id). Идемпотентно.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.memory_comments (
  id            TEXT        PRIMARY KEY,
  group_id      TEXT        NOT NULL,
  memory_id     TEXT        NOT NULL,
  author_uid    TEXT,
  author_name   TEXT,
  author_avatar TEXT,
  text          TEXT,
  created_at    TIMESTAMPTZ,
  deleted       BOOLEAN     NOT NULL DEFAULT FALSE
);
-- RLS on public.memory_comments is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

CREATE INDEX IF NOT EXISTS idx_comments_mem
  ON public.memory_comments(group_id, memory_id, created_at ASC);

-- Realtime для живого потока комментариев.
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.memory_comments;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END $$;
