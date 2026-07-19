-- ============================================================
-- Togetherly — коины / покупки / награды как Postgres RPC
-- Запускать в: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================
-- Назначение: перенести server-авторитетную логику коинов из Firebase
-- Cloud Functions (functions/index.js) в Supabase, чтобы отказаться от
-- Cloud Functions. Каждая функция = аналог соответствующего onCall:
--   purchaseTheme / purchaseIcon / purchaseFeature / spendCoins /
--   grantDailyBonus / grantCoinsPurchase / grantDevCoins /
--   grantMemoryReward / grantAdReward / grantPartnerInviteReward /
--   grantMoodStreakReward.
--
-- БЕЗОПАСНОСТЬ: все функции SECURITY DEFINER + атомарны (SELECT … FOR UPDATE
-- внутри неявной транзакции функции) → нет гонок, двойных списаний, обхода
-- цены клиентом. Цены зашиты в функции (клиент их не передаёт).
--
-- ВАЖНО про переход (см. этап 1b в коде клиента):
--   После перевода клиента на эти RPC, mirrorUser() в SupabaseService БОЛЬШЕ
--   НЕ ДОЛЖЕН зеркалить coins/owned_*/reward-поля из Firebase — иначе он
--   затрёт результат RPC старым значением из Firestore. Источник правды по
--   коинам становится таблица public.users в Supabase.
--
-- Скрипт идемпотентный: CREATE OR REPLACE + ADD COLUMN IF NOT EXISTS.
-- ============================================================

-- ──────────────────────────────────────────────
-- 0. Колонки кулдаунов/идемпотентности на users
-- ──────────────────────────────────────────────
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS last_daily_bonus_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_memory_reward_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ad_rewards_date              TEXT,
  ADD COLUMN IF NOT EXISTS ad_rewards_today             INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS dev_coins_granted            BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS partner_invite_reward_granted BOOLEAN NOT NULL DEFAULT FALSE,
  -- [ "<email|uid партнёра>", … ] — стабильные ключи партнёров, за которых уже
  -- выдана награда за подключение. Награда «по 50 на уникальную пару людей».
  ADD COLUMN IF NOT EXISTS partner_invite_rewarded_keys JSONB NOT NULL DEFAULT '[]'::JSONB,
  -- { "<groupId>": "<iso8601>" } — кулдаун mood-streak на каждую группу.
  ADD COLUMN IF NOT EXISTS mood_streak_rewards          JSONB NOT NULL DEFAULT '{}'::JSONB;

-- Идемпотентность IAP: один purchaseToken — одно начисление.
CREATE TABLE IF NOT EXISTS public.iap_purchases (
  purchase_token TEXT        PRIMARY KEY,
  user_uid       TEXT        NOT NULL,
  product_id     TEXT        NOT NULL,
  amount         INTEGER     NOT NULL,
  at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- RLS on public.iap_purchases is managed by supabase/security.sql (Stage 1); do NOT disable here
-- (re-running this file must NOT strip RLS — was the cause of mascots/iap_purchases UNRESTRICTED).

-- ──────────────────────────────────────────────
-- Вспомогательные функции цен (зеркало констант в functions/index.js)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._theme_price(p_theme_id INT) RETURNS INT AS $$
  -- Премиум-темы: индексы 5+ (0-4 бесплатные). По умолчанию 30 коинов; особая
  -- цена 16 (Aurora/«Северное сияние») = 40. Верхняя граница 50 — защита от
  -- мусорных id. Совпадает с themePrice() в functions/index.js — добавление
  -- новых тем (13..19 и далее) больше не ломает покупку.
  SELECT CASE
    WHEN p_theme_id < 5 OR p_theme_id > 50 THEN NULL
    WHEN p_theme_id = 16 THEN 40
    ELSE 30
  END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public._icon_price(p_icon_id TEXT) RETURNS INT AS $$
  SELECT CASE p_icon_id
    WHEN 'Paw' THEN 20 WHEN 'Sun' THEN 20 WHEN 'Moon' THEN 20
    WHEN 'Rainbow' THEN 20 WHEN 'Bunny' THEN 20 WHEN 'Frog' THEN 20
    WHEN 'Lucky' THEN 35 WHEN 'UFO' THEN 35 WHEN 'Together' THEN 35
    WHEN 'Soulmate' THEN 50 WHEN 'Perfect Match' THEN 50 WHEN 'Inseparable' THEN 50
    ELSE NULL END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public._feature_price(p_feature_id TEXT) RETURNS INT AS $$
  SELECT CASE p_feature_id WHEN 'days_widget_photos' THEN 20 ELSE NULL END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public._consumable_price(p_action_id TEXT) RETURNS INT AS $$
  SELECT CASE p_action_id WHEN 'chat_background' THEN 20 ELSE NULL END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public._coin_pack(p_product_id TEXT) RETURNS INT AS $$
  SELECT CASE p_product_id
    WHEN 'coins_10' THEN 10 WHEN 'coins_50' THEN 50
    WHEN 'coins_120' THEN 120 WHEN 'coins_300' THEN 300
    ELSE NULL END;
$$ LANGUAGE sql IMMUTABLE;

-- ──────────────────────────────────────────────
-- 1. Покупка премиум-темы (ownedThemes — массив INT)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_theme(p_uid TEXT, p_theme_id INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_price INT := public._theme_price(p_theme_id);
  v_coins INT;
  v_owned JSONB;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Тема не продаётся или не существует' USING ERRCODE = 'check_violation';
  END IF;
  SELECT coins, owned_themes INTO v_coins, v_owned FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; v_owned := '[]'::JSONB;
    INSERT INTO public.users (uid, coins, owned_themes) VALUES (p_uid, 0, '[]'::JSONB);
  END IF;
  IF v_owned @> to_jsonb(p_theme_id) THEN
    RETURN jsonb_build_object('ok', true, 'alreadyOwned', true, 'coins', v_coins, 'ownedThemes', v_owned);
  END IF;
  IF v_coins < v_price THEN
    RAISE EXCEPTION 'Недостаточно монет' USING ERRCODE = 'check_violation';
  END IF;
  v_coins := v_coins - v_price;
  v_owned := v_owned || jsonb_build_array(p_theme_id);
  UPDATE public.users SET coins = v_coins, owned_themes = v_owned, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'alreadyOwned', false, 'coins', v_coins, 'ownedThemes', v_owned);
END;
$$;

-- ──────────────────────────────────────────────
-- 2. Покупка профильной иконки (ownedIcons — массив TEXT)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_icon(p_uid TEXT, p_icon_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_price INT := public._icon_price(p_icon_id);
  v_coins INT;
  v_owned JSONB;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Иконка не продаётся или не существует' USING ERRCODE = 'check_violation';
  END IF;
  SELECT coins, owned_icons INTO v_coins, v_owned FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; v_owned := '[]'::JSONB;
    INSERT INTO public.users (uid, coins, owned_icons) VALUES (p_uid, 0, '[]'::JSONB);
  END IF;
  IF v_owned @> to_jsonb(p_icon_id) THEN
    RETURN jsonb_build_object('ok', true, 'alreadyOwned', true, 'coins', v_coins, 'ownedIcons', v_owned);
  END IF;
  IF v_coins < v_price THEN
    RAISE EXCEPTION 'Недостаточно монет' USING ERRCODE = 'check_violation';
  END IF;
  v_coins := v_coins - v_price;
  v_owned := v_owned || jsonb_build_array(p_icon_id);
  UPDATE public.users SET coins = v_coins, owned_icons = v_owned, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'alreadyOwned', false, 'coins', v_coins, 'ownedIcons', v_owned);
END;
$$;

-- ──────────────────────────────────────────────
-- 3. Покупка фичи навсегда (ownedFeatures — массив TEXT)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_feature(p_uid TEXT, p_feature_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_price INT := public._feature_price(p_feature_id);
  v_coins INT;
  v_owned JSONB;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Фича не продаётся или не существует' USING ERRCODE = 'check_violation';
  END IF;
  SELECT coins, owned_features INTO v_coins, v_owned FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; v_owned := '[]'::JSONB;
    INSERT INTO public.users (uid, coins, owned_features) VALUES (p_uid, 0, '[]'::JSONB);
  END IF;
  IF v_owned @> to_jsonb(p_feature_id) THEN
    RETURN jsonb_build_object('ok', true, 'alreadyOwned', true, 'coins', v_coins, 'ownedFeatures', v_owned);
  END IF;
  IF v_coins < v_price THEN
    RAISE EXCEPTION 'Недостаточно монет' USING ERRCODE = 'check_violation';
  END IF;
  v_coins := v_coins - v_price;
  v_owned := v_owned || jsonb_build_array(p_feature_id);
  UPDATE public.users SET coins = v_coins, owned_features = v_owned, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'alreadyOwned', false, 'coins', v_coins, 'ownedFeatures', v_owned);
END;
$$;

-- ──────────────────────────────────────────────
-- 4. Расходуемое действие (списать price, ничего не «куплено навсегда»)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.spend_coins(p_uid TEXT, p_action_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_price INT := public._consumable_price(p_action_id);
  v_coins INT;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Действие не существует' USING ERRCODE = 'check_violation';
  END IF;
  SELECT coins INTO v_coins FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; INSERT INTO public.users (uid, coins) VALUES (p_uid, 0); END IF;
  IF v_coins < v_price THEN
    RAISE EXCEPTION 'Недостаточно монет' USING ERRCODE = 'check_violation';
  END IF;
  v_coins := v_coins - v_price;
  UPDATE public.users SET coins = v_coins, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'coins', v_coins, 'spent', v_price);
END;
$$;

-- ──────────────────────────────────────────────
-- 5. Ежедневный бонус (1 коин раз в 20ч)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.grant_daily_bonus(p_uid TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_coins INT;
  v_last  TIMESTAMPTZ;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  SELECT coins, last_daily_bonus_at INTO v_coins, v_last FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; INSERT INTO public.users (uid, coins) VALUES (p_uid, 0); END IF;
  IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '20 hours' THEN
    RETURN jsonb_build_object('ok', false, 'tooEarly', true, 'coins', v_coins,
      'waitMinutes', CEIL(EXTRACT(EPOCH FROM (v_last + INTERVAL '20 hours' - NOW())) / 60));
  END IF;
  v_coins := v_coins + 1;
  UPDATE public.users SET coins = v_coins, last_daily_bonus_at = NOW(), updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'coins', v_coins, 'awarded', 1);
END;
$$;

-- ──────────────────────────────────────────────
-- 6. Начисление коинов за IAP-покупку (идемпотентно по purchaseToken)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.grant_coins_purchase(
  p_uid TEXT, p_product_id TEXT, p_purchase_token TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_amount INT := public._coin_pack(p_product_id);
  v_coins  INT;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  IF v_amount IS NULL THEN
    RAISE EXCEPTION 'Неизвестный productId: %', p_product_id USING ERRCODE = 'check_violation';
  END IF;
  SELECT coins INTO v_coins FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; INSERT INTO public.users (uid, coins) VALUES (p_uid, 0); END IF;
  -- Idempotency: один токен — одно начисление.
  IF EXISTS (SELECT 1 FROM public.iap_purchases WHERE purchase_token = p_purchase_token) THEN
    RETURN jsonb_build_object('ok', true, 'alreadyGranted', true, 'coins', v_coins);
  END IF;
  v_coins := v_coins + v_amount;
  INSERT INTO public.iap_purchases (purchase_token, user_uid, product_id, amount)
    VALUES (p_purchase_token, p_uid, p_product_id, v_amount);
  UPDATE public.users SET coins = v_coins, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'alreadyGranted', false, 'coins', v_coins, 'awarded', v_amount);
END;
$$;

-- ──────────────────────────────────────────────
-- 7. Dev-грант 1000 коинов (один раз, только для DEV_EMAIL)
--    Email берётся из строки users (не из параметра) — клиент не подделает.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.grant_dev_coins(p_uid TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_coins   INT;
  v_email   TEXT;
  v_granted BOOLEAN;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  SELECT coins, email, dev_coins_granted INTO v_coins, v_email, v_granted
    FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Пользователь не найден' USING ERRCODE = 'no_data_found';
  END IF;
  IF LOWER(COALESCE(v_email, '')) <> 'badzoff@gmail.com' THEN
    RAISE EXCEPTION 'Только для разработчика' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_granted THEN
    RETURN jsonb_build_object('ok', true, 'alreadyGranted', true, 'coins', v_coins);
  END IF;
  v_coins := v_coins + 1000;
  UPDATE public.users SET coins = v_coins, dev_coins_granted = TRUE, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'alreadyGranted', false, 'coins', v_coins, 'awarded', 1000);
END;
$$;

-- ──────────────────────────────────────────────
-- 8. Награда за добавление воспоминания (1 коин раз в 20ч)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.grant_memory_reward(p_uid TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_coins INT;
  v_last  TIMESTAMPTZ;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  SELECT coins, last_memory_reward_at INTO v_coins, v_last FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; INSERT INTO public.users (uid, coins) VALUES (p_uid, 0); END IF;
  IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '20 hours' THEN
    RETURN jsonb_build_object('ok', false, 'cooldown', true, 'coins', v_coins);
  END IF;
  v_coins := v_coins + 1;
  UPDATE public.users SET coins = v_coins, last_memory_reward_at = NOW(), updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'coins', v_coins, 'awarded', 1);
END;
$$;

-- ──────────────────────────────────────────────
-- 9. Награда за rewarded-видео (3 коина, лимит 3/сутки UTC)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.grant_ad_reward(p_uid TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_coins INT;
  v_date  TEXT;
  v_today INT;
  v_now   TEXT := to_char((NOW() AT TIME ZONE 'utc'), 'YYYY-MM-DD');
BEGIN
  PERFORM public.app_require_uid(p_uid);
  SELECT coins, ad_rewards_date, ad_rewards_today INTO v_coins, v_date, v_today
    FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; v_today := 0; INSERT INTO public.users (uid, coins) VALUES (p_uid, 0); END IF;
  IF v_date IS DISTINCT FROM v_now THEN v_today := 0; END IF;
  IF v_today >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'rateLimited', true, 'coins', v_coins);
  END IF;
  v_coins := v_coins + 3;
  UPDATE public.users SET coins = v_coins, ad_rewards_date = v_now,
    ad_rewards_today = v_today + 1, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'coins', v_coins, 'awarded', 3);
END;
$$;

-- ──────────────────────────────────────────────
-- 10. Награда за подключение партнёра (50 коинов КАЖДОМУ, один раз на пару людей)
--     Дедуп по стабильному ключу партнёра: email (фолбэк uid) — ник можно сменить.
--     Каждый пользователь хранит свой набор partner_invite_rewarded_keys.
--     Сигнатура изменилась на (TEXT, TEXT) → дропаем старую 1-арг версию.
-- ──────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.grant_partner_invite_reward(TEXT);
CREATE OR REPLACE FUNCTION public.grant_partner_invite_reward(p_uid TEXT, p_partner_uid TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_coins   INT;
  v_keys    JSONB;
  v_granted BOOLEAN;
  v_pemail  TEXT;
  v_key     TEXT;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  IF p_partner_uid IS NULL OR p_partner_uid = '' THEN
    SELECT coins INTO v_coins FROM public.users WHERE uid = p_uid;
    RETURN jsonb_build_object('ok', false, 'noPartner', true, 'coins', COALESCE(v_coins, 0));
  END IF;

  -- Стабильный ключ партнёра: email (фолбэк uid, напр. если партнёр ещё не в Supabase).
  SELECT LOWER(NULLIF(TRIM(email), '')) INTO v_pemail FROM public.users WHERE uid = p_partner_uid;
  v_key := COALESCE(v_pemail, p_partner_uid);

  SELECT coins, COALESCE(partner_invite_rewarded_keys, '[]'::JSONB), partner_invite_reward_granted
    INTO v_coins, v_keys, v_granted FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN
    v_coins := 0; v_keys := '[]'::JSONB; v_granted := FALSE;
    INSERT INTO public.users (uid, coins) VALUES (p_uid, 0);
  END IF;

  -- Уже вознаграждены за этого партнёра.
  IF v_keys @> to_jsonb(v_key) THEN
    RETURN jsonb_build_object('ok', false, 'alreadyGranted', true, 'coins', v_coins);
  END IF;

  -- Легаси «первое касание»: старый флаг стоит, набор пуст → сидируем текущего
  -- партнёра без начисления (существующая пара не должна получить награду снова).
  IF jsonb_array_length(v_keys) = 0 AND v_granted IS TRUE THEN
    UPDATE public.users SET
      partner_invite_rewarded_keys = v_keys || jsonb_build_array(v_key), updated_at = NOW()
      WHERE uid = p_uid;
    RETURN jsonb_build_object('ok', false, 'alreadyGranted', true, 'coins', v_coins);
  END IF;

  v_coins := v_coins + 50;
  UPDATE public.users SET
    coins = v_coins,
    partner_invite_rewarded_keys = v_keys || jsonb_build_array(v_key),
    partner_invite_reward_granted = TRUE,
    updated_at = NOW()
  WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'coins', v_coins, 'awarded', 50);
END;
$$;

-- ──────────────────────────────────────────────
-- 11. Награда за 7-дневный mood-стрик (10 коинов раз в 7 дней на группу)
--     Кулдаун на каждую группу: mood_streak_rewards->>groupId.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.grant_mood_streak_reward(p_uid TEXT, p_group_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_coins INT;
  v_map   JSONB;
  v_last  TIMESTAMPTZ;
BEGIN
  PERFORM public.app_require_uid(p_uid);
  IF p_group_id IS NULL OR p_group_id = '' THEN
    RAISE EXCEPTION 'groupId обязателен' USING ERRCODE = 'check_violation';
  END IF;
  SELECT coins, mood_streak_rewards INTO v_coins, v_map FROM public.users WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND THEN v_coins := 0; v_map := '{}'::JSONB; INSERT INTO public.users (uid, coins) VALUES (p_uid, 0); END IF;
  v_last := (v_map->>p_group_id)::TIMESTAMPTZ;
  IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '7 days' THEN
    RETURN jsonb_build_object('ok', false, 'cooldown', true, 'coins', v_coins);
  END IF;
  v_coins := v_coins + 10;
  v_map := jsonb_set(COALESCE(v_map, '{}'::JSONB), ARRAY[p_group_id], to_jsonb(NOW()), true);
  UPDATE public.users SET coins = v_coins, mood_streak_rewards = v_map, updated_at = NOW() WHERE uid = p_uid;
  RETURN jsonb_build_object('ok', true, 'coins', v_coins, 'awarded', 10);
END;
$$;

-- ──────────────────────────────────────────────
-- Права: клиент (anon/authenticated ключ) должен мочь вызывать RPC.
-- SECURITY DEFINER гарантирует, что внутри функции права владельца.
-- ──────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION
  public.purchase_theme(TEXT, INT),
  public.purchase_icon(TEXT, TEXT),
  public.purchase_feature(TEXT, TEXT),
  public.spend_coins(TEXT, TEXT),
  public.grant_daily_bonus(TEXT),
  public.grant_coins_purchase(TEXT, TEXT, TEXT),
  public.grant_dev_coins(TEXT),
  public.grant_memory_reward(TEXT),
  public.grant_ad_reward(TEXT),
  public.grant_partner_invite_reward(TEXT, TEXT),
  public.grant_mood_streak_reward(TEXT, TEXT)
TO anon, authenticated;
