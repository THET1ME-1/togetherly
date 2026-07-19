-- ============================================================
-- Togetherly — Этап 5 миграции (срез 2+3): статусы прочтения + реакции чата.
-- Run in: Supabase Dashboard → SQL Editor → New query → Run
-- Идемпотентный (IF NOT EXISTS / CREATE OR REPLACE) — можно запускать повторно.
-- (Если уже запускал версию со срезом 2 — просто запусти ещё раз, добавится RPC.)
-- ============================================================
-- Зеркало RTDB chats/{groupId}/reads/{uid} = lastReadTs (ms-epoch) →
-- public.chat_reads. Для галочек «прочитано». Сообщения чата уже читаются
-- из chat_messages; срез 3 снимает с RTDB и запись (send/edit/delete/реакции).
-- Низкочастотная запись (markRead троттлится по росту ts на клиенте).
-- RLS off (Фаза 1), keys = TEXT.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.chat_reads (
  group_id     TEXT        NOT NULL,
  user_uid     TEXT        NOT NULL,
  last_read_ts BIGINT      NOT NULL DEFAULT 0,  -- ms-since-epoch последнего прочитанного
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_uid)
);
-- RLS on public.chat_reads is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ── Реакция на сообщение (атомарно, без гонки партнёров) ──────
-- Один эмодзи на uid: NULL/'' убирает ключ, иначе ставит. jsonb_set/minus
-- атомарны в одном UPDATE — read-modify-write с клиента терял бы реакцию
-- партнёра, написанную параллельно.
CREATE OR REPLACE FUNCTION public.chat_set_reaction(
  p_id    TEXT,
  p_uid   TEXT,
  p_emoji TEXT
) RETURNS VOID AS $$
  UPDATE public.chat_messages
     SET reactions = CASE
           WHEN p_emoji IS NULL OR p_emoji = ''
             THEN COALESCE(reactions, '{}'::jsonb) - p_uid
           ELSE jsonb_set(
             COALESCE(reactions, '{}'::jsonb), ARRAY[p_uid], to_jsonb(p_emoji))
         END
   WHERE id = p_id;
$$ LANGUAGE sql;
GRANT EXECUTE ON FUNCTION public.chat_set_reaction(TEXT, TEXT, TEXT)
  TO anon, authenticated;

-- ── Realtime ──────────────────────────────────────────────────
DO $$
BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_reads; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;
