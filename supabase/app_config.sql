-- ============================================================
-- Togetherly — публичный конфиг приложения (force-update kill-switch).
-- Run in: Supabase Dashboard → SQL Editor → New query → Run (идемпотентно).
-- ============================================================
-- Клиент на старте читает app_config(id=1).min_build и, если установленная
-- сборка НИЖЕ — показывает блокирующий экран обновления (ForceUpdateScreen).
--
-- БЕЗОПАСНО ПО УМОЛЧАНИЮ: min_build = 0 ⇒ не блокирует НИКОГО. Чтобы потребовать
-- минимальную версию — поставь min_build = нужный versionCode (build number)
-- через Table Editor. Клиент fail-open: ошибка чтения = не блокируем.
--
-- Чтение нужно и роли `anon` (старт до авторизации), поэтому select открыт всем.
-- Запись закрыта (нет политик) — меняем только из Dashboard / service_role.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.app_config (
  id          INT PRIMARY KEY,
  min_build   INT NOT NULL DEFAULT 0,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Единственная строка конфига.
INSERT INTO public.app_config (id, min_build)
VALUES (1, 0)
ON CONFLICT (id) DO NOTHING;

-- Публичное чтение (anon + authenticated): конфиг не секретный.
GRANT SELECT ON public.app_config TO anon, authenticated;

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_config_public_read ON public.app_config;
CREATE POLICY app_config_public_read ON public.app_config
  FOR SELECT TO anon, authenticated
  USING (true);

-- INSERT/UPDATE/DELETE: политик НЕТ ⇒ запрещено для anon/authenticated.
