-- ============================================================
-- Togetherly — УДАЛЁННЫЙ КАТАЛОГ КОНТЕНТА (паки настроений + маскоты).
-- Глобальный read-only контент: добавляем новые паки/эмоции/маскотов БЕЗ
-- релиза приложения. Это НЕ пар-данные — нет связи с миграцией групп.
-- Run in: Supabase Dashboard → SQL Editor → New query → Run. Идемпотентно.
-- ============================================================
-- Модель: одна строка = один элемент каталога (пак ИЛИ маскот).
--   kind='mood_pack' → data = { tileGradient?:[hex,hex],
--                               moods:[{id,url,labelRu?,labelEn?,color?,score?}] }
--   kind='mascot'    → data = { url }
-- Картинки → публичный Storage bucket 'catalog' (CDN, без signed-URL).
-- min_app — semver-гейт: старые сборки пропускают элементы, которые не умеют.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.catalog_items (
  id         TEXT PRIMARY KEY,            -- 'autumn', 'spiky' ... (id пака/маскота)
  kind       TEXT NOT NULL CHECK (kind IN ('mood_pack', 'mascot')),
  name_ru    TEXT NOT NULL,
  name_en    TEXT NOT NULL,
  is_free    BOOLEAN NOT NULL DEFAULT TRUE,
  min_app    TEXT,                        -- напр. '1.14.0'; NULL = без ограничения
  sort       INTEGER NOT NULL DEFAULT 0,  -- порядок в пикере/галерее
  data       JSONB NOT NULL DEFAULT '{}', -- см. формат выше
  enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_catalog_kind ON public.catalog_items(kind) WHERE enabled;

-- ── RLS: ПУБЛИЧНОЕ ЧТЕНИЕ, запись ТОЛЬКО админом (service_role обходит RLS) ──
ALTER TABLE public.catalog_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS catalog_public_read ON public.catalog_items;
CREATE POLICY catalog_public_read ON public.catalog_items
  FOR SELECT TO anon, authenticated
  USING (enabled);
-- НЕТ политик insert/update/delete → клиенты (anon/authenticated) не могут писать.
-- Контент добавляем из SQL Editor или админ-скриптом с SERVICE-ключом (минует RLS).

-- ── Публичный bucket для картинок каталога (CDN, без подписи URL) ──
INSERT INTO storage.buckets (id, name, public)
VALUES ('catalog', 'catalog', TRUE)
ON CONFLICT (id) DO UPDATE SET public = TRUE;

-- ── Realtime (необязательно: каталог и так фетчится при старте) ──
DO $$
BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.catalog_items; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;

-- ============================================================
-- ПРИМЕРЫ ВСТАВКИ (после загрузки картинок в bucket 'catalog')
-- Публичный URL: https://<project>.supabase.co/storage/v1/object/public/catalog/<path>
-- ============================================================

-- Пример пака с переиспользованием известных эмоций (новый стиль картинок):
-- min_app = NULL → виден на ЛЮБОЙ сборке (для теста). Для релиза ставь версию,
-- начиная с которой пак умеет рендериться (старые сборки его пропустят).
-- INSERT INTO public.catalog_items (id, kind, name_ru, name_en, is_free, min_app, sort, data)
-- VALUES ('autumn', 'mood_pack', 'Осень', 'Autumn', TRUE, NULL, 10, jsonb_build_object(
--   'tileGradient', jsonb_build_array('#FFF3E0', '#FFE0B2'),
--   'moods', jsonb_build_array(
--     jsonb_build_object('id','happy', 'url','https://<proj>.supabase.co/storage/v1/object/public/catalog/mood_packs/autumn/happy.webp'),
--     jsonb_build_object('id','sad',   'url','https://<proj>.supabase.co/storage/v1/object/public/catalog/mood_packs/autumn/sad.webp'),
--     -- НОВАЯ эмоция (своего id нет в сборке) → несём label/color/score:
--     jsonb_build_object('id','cozy',  'url','https://<proj>.supabase.co/storage/v1/object/public/catalog/mood_packs/autumn/cozy.webp',
--                        'labelRu','Уют', 'labelEn','Cozy', 'color','#E8A23D', 'score',4)
--   )))
-- ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, name_ru = EXCLUDED.name_ru,
--   name_en = EXCLUDED.name_en, is_free = EXCLUDED.is_free, min_app = EXCLUDED.min_app,
--   sort = EXCLUDED.sort, enabled = TRUE, updated_at = now();

-- Пример маскота (Фаза 2, когда подключим каталог маскотов):
-- INSERT INTO public.catalog_items (id, kind, name_ru, name_en, sort, data)
-- VALUES ('spiky', 'mascot', 'Спайки', 'Spiky', 10, jsonb_build_object(
--   'url','https://<proj>.supabase.co/storage/v1/object/public/catalog/mascots/spiky.webp'))
-- ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, updated_at = now();
