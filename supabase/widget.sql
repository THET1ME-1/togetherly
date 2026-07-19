-- ════════════════════════════════════════════════════════════════════════
--  ЭТАП 3c-widget: чтение widget_data из Supabase
-- ════════════════════════════════════════════════════════════════════════
--
-- Проблема: типизированные колонки widget_data (schema.sql) НЕ покрывали
-- фото-поля парного виджета (photoForPartnerUrl/Urls, photoGrid*), а `data`
-- JSONB перезаписывается на КАЖДЫЙ частичный апдейт (mirrorWidgetData кладёт
-- туда только текущий патч) — поэтому читать widget_data из `data` нельзя.
--
-- Решение: добавляем недостающие фото-поля как ОТДЕЛЬНЫЕ колонки. Upsert с
-- onConflict обновляет только переданные колонки, а непереданные оставляет
-- нетронутыми → типизированные колонки накапливают полное состояние виджета
-- между частичными апдейтами. Чтение идёт ТОЛЬКО из колонок.
--
-- Идемпотентно, безопасно запускать повторно в SQL Editor.

ALTER TABLE public.widget_data
  ADD COLUMN IF NOT EXISTS photo_for_partner_url  TEXT,
  ADD COLUMN IF NOT EXISTS photo_for_partner_urls JSONB NOT NULL DEFAULT '[]'::JSONB,
  ADD COLUMN IF NOT EXISTS photo_grid_count       INT   NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS photo_grid_urls        JSONB NOT NULL DEFAULT '[]'::JSONB;
