-- ============================================================
-- Togetherly — Supabase SECURITY (Фаза 3: подготовка к публичному релизу)
-- Run in: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================
-- ЧТО ДЕЛАЕТ:
--   • Включает Row Level Security (RLS) на ВСЕХ таблицах данных.
--   • Привязывает доступ к личности через Firebase-токен:
--     auth.jwt()->>'sub' == Firebase UID (ключи в таблицах = Firebase UID).
--   • Пользователь видит/меняет ТОЛЬКО свои данные и данные своей группы.
--
-- ПРЕДУСЛОВИЕ (иначе всё сломается — см. SECURITY_RUNBOOK.md):
--   1. В Supabase Dashboard включён Third-Party Auth → Firebase
--      (Authentication → Sign In / Providers → Firebase, project id).
--   2. Клиент шлёт Firebase ID-токен (Supabase.initialize(accessToken: …)
--      в lib/main.dart) — уже в сборке.
--   Без этого роль остаётся `anon`, и все запросы под RLS вернут пусто.
--
-- ПОРЯДОК ВЫКАТА: сначала (1)+(2) и проверка, что приложение РАБОТАЕТ при
--   ещё ВЫКЛЮЧЕННОМ RLS (токен принимается), и только ПОТОМ запускать этот
--   скрипт. Скрипт идемпотентный — можно гонять повторно.
--
-- ВНИМАНИЕ: этот скрипт НЕ закрывает SECURITY DEFINER функции (purchase_*,
--   grant_*, group_*). Они обходят RLS и закрываются отдельно —
--   см. security_rpc.sql (следующий шаг). До этого денежные функции уязвимы.
-- ============================================================

-- ──────────────────────────────────────────────
-- 0. ХЕЛПЕРЫ
-- ──────────────────────────────────────────────

-- Firebase UID текущего запроса (из проверенного JWT). NULL для anon.
CREATE OR REPLACE FUNCTION public.app_uid()
RETURNS TEXT
LANGUAGE sql STABLE
AS $$ SELECT auth.jwt() ->> 'sub' $$;

-- Состоит ли текущий пользователь в группе. SECURITY DEFINER, чтобы сама
-- проверка членства не блокировалась политикой RLS на groups (без рекурсии).
-- groups.members — JSONB-массив строк-UID, оператор `?` проверяет наличие.
CREATE OR REPLACE FUNCTION public.is_group_member(p_group_id TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.id = p_group_id
      AND g.members ? (auth.jwt() ->> 'sub')
  );
$$;

-- Защита для SECURITY DEFINER функций (используется в security_rpc.sql):
-- бросает, если переданный p_uid не совпадает с владельцем токена.
CREATE OR REPLACE FUNCTION public.app_require_uid(p_uid TEXT)
RETURNS VOID
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  IF p_uid IS NULL OR p_uid IS DISTINCT FROM (auth.jwt() ->> 'sub') THEN
    RAISE EXCEPTION 'forbidden: uid mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

-- ──────────────────────────────────────────────
-- 1. ГРАНТЫ роли authenticated (RLS всё равно фильтрует строки)
-- ──────────────────────────────────────────────
GRANT USAGE ON SCHEMA public TO authenticated, anon;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO authenticated;

-- ──────────────────────────────────────────────
-- 2. USERS — только своя строка (+ чтение co-member'а группы)
-- ──────────────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('public.users') IS NULL THEN
    RAISE NOTICE 'skip RLS: public.users not found'; RETURN;
  END IF;
  ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS users_self_rw       ON public.users;
  DROP POLICY IF EXISTS users_comember_read ON public.users;
  CREATE POLICY users_self_rw ON public.users
    FOR ALL TO authenticated
    USING (uid = public.app_uid())
    WITH CHECK (uid = public.app_uid());
  -- Партнёра по группе можно ТОЛЬКО читать (для флоу, где нужен его профиль).
  CREATE POLICY users_comember_read ON public.users
    FOR SELECT TO authenticated
    USING (EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.members ? public.app_uid()
        AND g.members ? public.users.uid
    ));
END $$;

-- ──────────────────────────────────────────────
-- 3. GROUPS — только свои группы.
-- INSERT: новый участник должен быть в members нового документа.
-- ──────────────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('public.groups') IS NULL THEN
    RAISE NOTICE 'skip RLS: public.groups not found'; RETURN;
  END IF;
  ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS groups_member_all ON public.groups;
  CREATE POLICY groups_member_all ON public.groups
    FOR ALL TO authenticated
    -- USING обязан содержать `members ? app_uid()`, а НЕ только табличный
    -- is_group_member(id): при upsert (INSERT ... ON CONFLICT DO UPDATE, как в
    -- mirrorGroupRaw) Postgres проверяет USING UPDATE-политики, а строки группы
    -- ещё нет в таблице → is_group_member(id) вернёт false и ПЕРВОЕ создание
    -- группы упадёт с 42501. `members ? app_uid()` читает members новой строки.
    USING (public.is_group_member(id) OR (members ? public.app_uid()))
    WITH CHECK (public.is_group_member(id) OR (members ? public.app_uid()));
END $$;

-- ──────────────────────────────────────────────
-- 4. Таблицы, привязанные к группе через колонку group_id — членство группы.
-- ──────────────────────────────────────────────
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'widget_data','memories','mood_entries','chat_messages','miss_you',
    'chat_reads','canvas_strokes','canvas_meta','canvas_catalogue',
    'memory_comments','mascots','migration_flags'
  ]
  LOOP
    -- Пропускаем таблицы, которых ещё нет (не все *.sql могли быть выполнены).
    IF to_regclass(format('public.%I', t)) IS NULL THEN
      RAISE NOTICE 'skip RLS: table public.% not found', t;
      CONTINUE;
    END IF;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS app_group_rw ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY app_group_rw ON public.%I FOR ALL TO authenticated '
      'USING (public.is_group_member(group_id)) '
      'WITH CHECK (public.is_group_member(group_id))', t);
  END LOOP;
END $$;

-- ──────────────────────────────────────────────
-- 5. IAP_PURCHASES — только свои покупки.
-- ──────────────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('public.iap_purchases') IS NULL THEN
    RAISE NOTICE 'skip RLS: public.iap_purchases not found'; RETURN;
  END IF;
  ALTER TABLE public.iap_purchases ENABLE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS iap_self ON public.iap_purchases;
  CREATE POLICY iap_self ON public.iap_purchases
    FOR ALL TO authenticated
    USING (user_uid = public.app_uid())
    WITH CHECK (user_uid = public.app_uid());
END $$;

-- ──────────────────────────────────────────────
-- 6. STORAGE — закрыть anon, требовать аутентификацию.
-- (media — приватный, доступ через Signed URL; avatars — публичное чтение.)
-- Уточнение «членство группы по пути файла» — отдельная доработка.
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS phase1_media_all   ON storage.objects;
DROP POLICY IF EXISTS phase1_avatars_all ON storage.objects;
DROP POLICY IF EXISTS media_authenticated_all   ON storage.objects;
DROP POLICY IF EXISTS avatars_authenticated_all ON storage.objects;
CREATE POLICY media_authenticated_all ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'media')
  WITH CHECK (bucket_id = 'media');
CREATE POLICY avatars_authenticated_all ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'avatars')
  WITH CHECK (bucket_id = 'avatars');

-- ============================================================
-- ПРОВЕРКА (после выката, в SQL Editor выполнять не нужно — это для глаз):
--   • Залогиненный тест-аккаунт видит свои группы/чаты/память.
--   • НЕ видит чужие (SELECT по чужому group_id вернёт 0 строк).
--   • Аноним (без токена) не видит ничего.
-- ============================================================
