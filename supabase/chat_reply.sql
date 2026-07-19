-- ============================================================
-- Togetherly — ОТВЕТЫ В ЧАТЕ (reply на конкретное сообщение).
-- Добавляет снимок цитаты к сообщению: id оригинала + имя/текст на момент
-- отправки (цитата остаётся читаемой, даже если оригинал правят/удаляют).
-- Run in: Supabase Dashboard → SQL Editor. Идемпотентно.
-- ============================================================

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS reply_to_id   TEXT;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS reply_to_name TEXT;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS reply_to_text TEXT;
