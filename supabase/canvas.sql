-- ============================================================
-- Togetherly — холсты / рисунки (этап 3c миграции)
-- Запускать в: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================
-- Зеркало Firestore:
--   groups/{g}/canvas/{canvasId}/strokes/{id}  → canvas_strokes (сам рисунок)
--   groups/{g}/canvas/{canvasId} (meta-док)    → canvas_meta (фон/clear/поворот)
--   groups/{g}/canvasCatalogue/{canvasId}      → canvas_catalogue (список холстов)
-- Эфемерные live-штрихи и presence НЕ мигрируются (как presence — остаются в FS).
-- gc = group_id||':'||canvas_id: realtime .stream() допускает один .eq(), а
-- canvas_id='main' не уникален между группами → фильтруем по составному gc.
-- RLS off (Phase 1), keys = TEXT. Идемпотентно.
-- ============================================================

-- ── Завершённые штрихи (сам рисунок) ──────────────────────────
CREATE TABLE IF NOT EXISTS public.canvas_strokes (
  id          TEXT        PRIMARY KEY,
  group_id    TEXT        NOT NULL,
  canvas_id   TEXT        NOT NULL DEFAULT 'main',
  gc          TEXT        GENERATED ALWAYS AS (group_id || ':' || canvas_id) STORED,
  order_index INTEGER     NOT NULL DEFAULT 0,
  data        JSONB       NOT NULL DEFAULT '{}'::JSONB,
  deleted     BOOLEAN     NOT NULL DEFAULT FALSE
);
-- RLS on public.canvas_strokes is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).
CREATE INDEX IF NOT EXISTS idx_canvas_strokes ON public.canvas_strokes(gc, order_index ASC);

-- ── Мета холста (фон / версия очистки / поворот) ──────────────
CREATE TABLE IF NOT EXISTS public.canvas_meta (
  group_id        TEXT        NOT NULL,
  canvas_id       TEXT        NOT NULL DEFAULT 'main',
  gc              TEXT        GENERATED ALWAYS AS (group_id || ':' || canvas_id) STORED,
  bg_color        BIGINT,
  clear_version   BIGINT,
  canvas_rotation INTEGER,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, canvas_id)
);
-- RLS on public.canvas_meta is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).
CREATE INDEX IF NOT EXISTS idx_canvas_meta_gc ON public.canvas_meta(gc);

-- ── Каталог холстов (мультиканвас) ────────────────────────────
CREATE TABLE IF NOT EXISTS public.canvas_catalogue (
  group_id   TEXT    NOT NULL,
  canvas_id  TEXT    NOT NULL,
  name       TEXT,
  created_at BIGINT,
  updated_at BIGINT,
  created_by TEXT,
  PRIMARY KEY (group_id, canvas_id)
);
-- RLS on public.canvas_catalogue is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).
CREATE INDEX IF NOT EXISTS idx_canvas_cat_group ON public.canvas_catalogue(group_id);

-- ── RPC: частичный патч штриха (перетаскивание картинки, sb://-URL) ──
-- data || p_patch + опционально order_index — атомарно, без read-modify-write.
CREATE OR REPLACE FUNCTION public.canvas_stroke_patch(p_id TEXT, p_patch JSONB)
RETURNS VOID LANGUAGE sql AS $$
  UPDATE public.canvas_strokes
    SET data = COALESCE(data, '{}'::JSONB) || p_patch,
        order_index = COALESCE((p_patch->>'orderIndex')::INT, order_index)
  WHERE id = p_id;
$$;
GRANT EXECUTE ON FUNCTION public.canvas_stroke_patch(TEXT, JSONB) TO anon, authenticated;

-- ── Realtime ──────────────────────────────────────────────────
DO $$
BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.canvas_strokes;   EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.canvas_meta;      EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.canvas_catalogue; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;
