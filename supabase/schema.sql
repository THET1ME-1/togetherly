-- ============================================================
-- Togetherly — Supabase schema  (Phase 1 migration, dual-write)
-- Run in: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================
-- NOTES:
--  • Firebase UIDs/ids are NOT UUIDs → all keys are TEXT.
--  • NO foreign keys: dual-write зеркалит данные в произвольном
--    порядке, частичные данные не должны ломать вставку.
--  • RLS DISABLED for Phase 1 (2-аккаунтный тест на ветке).
--    Включить + политики — в Фазе 2 после миграции auth.
--  • Скрипт идемпотентный: можно запускать повторно.
-- ============================================================

-- ──────────────────────────────────────────────
-- 1. USERS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.users (
  uid                TEXT        PRIMARY KEY,
  display_name       TEXT,
  email              TEXT,
  avatar_url         TEXT,
  gender             TEXT,
  birth_date         TIMESTAMPTZ,
  coins              INTEGER     NOT NULL DEFAULT 0,
  owned_themes       JSONB       NOT NULL DEFAULT '[]'::JSONB,
  owned_icons        JSONB       NOT NULL DEFAULT '[]'::JSONB,
  owned_features     JSONB       NOT NULL DEFAULT '[]'::JSONB,
  granted_badges     JSONB       NOT NULL DEFAULT '[]'::JSONB,
  badge              TEXT,
  pair_id            TEXT,
  pair_ids           JSONB       NOT NULL DEFAULT '[]'::JSONB,
  invite_code        TEXT,
  fcm_token          TEXT,
  fcm_tokens         JSONB       NOT NULL DEFAULT '[]'::JSONB,
  notif_miss_you     BOOLEAN     NOT NULL DEFAULT TRUE,
  notif_new_memory   BOOLEAN     NOT NULL DEFAULT TRUE,
  notif_mood         BOOLEAN     NOT NULL DEFAULT TRUE,
  notif_chat         BOOLEAN     NOT NULL DEFAULT TRUE,
  solo_timers        JSONB       NOT NULL DEFAULT '[]'::JSONB,
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- RLS on public.users is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- 2. GROUPS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.groups (
  id                           TEXT        PRIMARY KEY,
  members                      JSONB       NOT NULL DEFAULT '[]'::JSONB,
  member_names                 JSONB       NOT NULL DEFAULT '{}'::JSONB,
  member_avatars               JSONB       NOT NULL DEFAULT '{}'::JSONB,
  max_members                  INTEGER     NOT NULL DEFAULT 2,
  relationship_type            TEXT                 DEFAULT 'couple',
  custom_relationship_label    TEXT,
  custom_relationship_emoji    TEXT,
  custom_relationship_types    JSONB       NOT NULL DEFAULT '[]'::JSONB,
  start_date                   TIMESTAMPTZ,
  anniversary_date             TIMESTAMPTZ,
  first_kiss_date              TIMESTAMPTZ,
  member_birthdays             JSONB       NOT NULL DEFAULT '{}'::JSONB,
  member_moods                 JSONB       NOT NULL DEFAULT '{}'::JSONB,
  current_status               JSONB,
  custom_statuses              JSONB       NOT NULL DEFAULT '[]'::JSONB,
  memories_count               INTEGER     NOT NULL DEFAULT 0,
  drawings_count               INTEGER     NOT NULL DEFAULT 0,
  active_session               JSONB,
  created_at                   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  disbanded                    BOOLEAN     NOT NULL DEFAULT FALSE,
  disbanded_at                 TIMESTAMPTZ,
  timers                       JSONB       NOT NULL DEFAULT '[]'::JSONB,
  mascots                      JSONB       NOT NULL DEFAULT '[]'::JSONB
);
-- RLS on public.groups is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- 3. WIDGET DATA  (per user per group)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.widget_data (
  group_id        TEXT        NOT NULL,
  user_uid        TEXT        NOT NULL,
  display_name    TEXT,
  avatar_url      TEXT,
  gender          TEXT,
  status          TEXT,
  mood_emoji      TEXT,
  mood_label      TEXT,
  message         TEXT,
  music_title     TEXT,
  music_artist    TEXT,
  music_url       TEXT,
  music_cover_url TEXT,
  photo_url       TEXT,
  data            JSONB       NOT NULL DEFAULT '{}'::JSONB,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_uid)
);
-- RLS on public.widget_data is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- 4. MEMORIES
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.memories (
  id                    TEXT             PRIMARY KEY,
  group_id              TEXT             NOT NULL,
  type                  TEXT,
  author_uid            TEXT,
  author_name           TEXT,
  author_avatar         TEXT,
  created_at            TIMESTAMPTZ,
  edited_at             TIMESTAMPTZ,
  data                  JSONB            NOT NULL DEFAULT '{}'::JSONB,
  is_pinned             BOOLEAN          NOT NULL DEFAULT FALSE,
  deleted               BOOLEAN          NOT NULL DEFAULT FALSE
);
-- RLS on public.memories is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- 5. MOOD ENTRIES
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.mood_entries (
  id          TEXT        PRIMARY KEY,
  group_id    TEXT        NOT NULL,
  user_uid    TEXT        NOT NULL,
  mood_id     TEXT,
  image_path  TEXT,
  label       TEXT,
  timestamp   TIMESTAMPTZ NOT NULL
);
-- RLS on public.mood_entries is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- 6. CHAT MESSAGES
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id          TEXT        PRIMARY KEY,
  group_id    TEXT        NOT NULL,
  user_uid    TEXT,
  user_name   TEXT,
  text        TEXT,
  ts          BIGINT      NOT NULL,
  edited_ts   BIGINT,
  reactions   JSONB       NOT NULL DEFAULT '{}'::JSONB,
  pin_id      TEXT,
  pin_title   TEXT,
  pin_thumb   TEXT,
  deleted     BOOLEAN     NOT NULL DEFAULT FALSE
);
-- RLS on public.chat_messages is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- 7. MISS YOU COUNTS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.miss_you (
  group_id    TEXT        NOT NULL,
  user_uid    TEXT        NOT NULL,
  count       INTEGER     NOT NULL DEFAULT 0,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_uid)
);
-- RLS on public.miss_you is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- INDEXES
-- ──────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_memories_group     ON public.memories(group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mood_group_user    ON public.mood_entries(group_id, user_uid, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_chat_group_ts       ON public.chat_messages(group_id, ts ASC);
CREATE INDEX IF NOT EXISTS idx_miss_you_group     ON public.miss_you(group_id);

-- ──────────────────────────────────────────────
-- RPC: атомарный инкремент счётчика «Я скучаю»
-- (upsert + increment одним вызовом)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.increment_miss_you(
  p_group_id TEXT,
  p_user_uid TEXT
) RETURNS VOID AS $$
  INSERT INTO public.miss_you (group_id, user_uid, count, updated_at)
  VALUES (p_group_id, p_user_uid, 1, NOW())
  ON CONFLICT (group_id, user_uid)
  DO UPDATE SET count = public.miss_you.count + 1, updated_at = NOW();
$$ LANGUAGE sql;

-- ──────────────────────────────────────────────
-- STORAGE — бакеты для медиафайлов (Фаза 1 миграции)
-- Run ONCE after enabling Storage in Supabase Dashboard.
-- ──────────────────────────────────────────────
-- Бакет «media» (приватный): memories/, music/, widget/, timer_backgrounds/
-- Бакет «avatars» (публичный): аватарки пользователей
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES
  ('media',   'media',   false, 104857600),  -- 100 MB, приватный
  ('avatars', 'avatars', true,  5242880)     -- 5 MB, публичный
ON CONFLICT (id) DO NOTHING;

-- Политики доступа (Фаза 1: полный доступ для anon-ключа).
-- В Фазе 2 заменить на политики с проверкой группы.
DO $$
BEGIN
  -- media: anon может читать и писать (доступ через Signed URL)
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='objects' AND policyname='phase1_media_all'
  ) THEN
    EXECUTE $pol$
      CREATE POLICY phase1_media_all ON storage.objects
        FOR ALL TO anon
        USING (bucket_id = 'media')
        WITH CHECK (bucket_id = 'media');
    $pol$;
  END IF;
  -- avatars: anon может читать и писать
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='objects' AND policyname='phase1_avatars_all'
  ) THEN
    EXECUTE $pol$
      CREATE POLICY phase1_avatars_all ON storage.objects
        FOR ALL TO anon
        USING (bucket_id = 'avatars')
        WITH CHECK (bucket_id = 'avatars');
    $pol$;
  END IF;
END $$;

-- ──────────────────────────────────────────────
-- REALTIME — включить, чтобы стримы (группа, настроения, чат, скучаю)
-- получали live-обновления. Идемпотентно через DO-блок.
-- ──────────────────────────────────────────────
DO $$
BEGIN
  PERFORM 1;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.groups;        EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.mood_entries;  EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.miss_you;      EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.widget_data;   EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.memories;      EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;
