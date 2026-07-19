-- ============================================================
-- Togetherly — ОФОРМЛЕНИЕ СООБЩЕНИЯ, выбранное отправителем:
--   • face   — выражение мордочки (_FaceExpr: happy/love/wink/playful/sad/calm)
--              или NULL — без лица.
--   • color  — цвет пузыря (ARGB int) или NULL — цвет темы.
--   • face_x/face_y — позиция мордочки на пузыре в долях 0..1.
-- Зеркалит RTDB chats/{groupId}/messages/{id}/{face,color,faceX,faceY}.
-- Run in: Supabase Dashboard → SQL Editor. Идемпотентно.
-- ============================================================

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS face   TEXT;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS color  BIGINT;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS face_x REAL;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS face_y REAL;
