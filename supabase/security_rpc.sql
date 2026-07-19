-- ============================================================
-- Togetherly — закрытие денежных SECURITY DEFINER функций.
-- Run in: Supabase Dashboard → SQL Editor. ЗАПУСКАТЬ ПОСЛЕ security.sql.
-- Идемпотентно.
-- ============================================================
-- КОНТЕКСТ:
--   Денежные функции в coins.sql — SECURITY DEFINER (обходят RLS). Внутри уже
--   стоит app_require_uid(p_uid) → вызвать для ЧУЖОГО uid нельзя. НО security.sql
--   раздаёт `GRANT EXECUTE ON ALL FUNCTIONS … TO authenticated`, поэтому любой
--   залогиненный клиент может вызвать их ДЛЯ СЕБЯ напрямую (grant_dev_coins,
--   grant_ad_reward и т.д.) — в обход реальной проверки (dev-права, AdMob SSV).
--
--   Приложение эти функции напрямую НЕ вызывает (экономика идёт через Firebase
--   callables; в будущем — Edge Functions). Поэтому отзыв прав у anon/authenticated
--   НИЧЕГО не ломает в клиенте и закрывает self-mint. service_role (Edge/серверная
--   сторона) под REVOKE не подпадает и продолжит звать их свободно.
--
-- ⚠️ ПОРЯДОК: этот файл — ПОСЛЕДНИЙ. security.sql содержит
--    `GRANT EXECUTE ON ALL FUNCTIONS … TO authenticated`, который при ПОВТОРНОМ
--    прогоне security.sql снова откроет эти функции. Если перезапускаешь
--    security.sql — прогони security_rpc.sql следом.
-- ============================================================

REVOKE EXECUTE ON FUNCTION
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
FROM PUBLIC, anon, authenticated;

-- Ценовые помощники — внутренние, клиенту не нужны.
REVOKE EXECUTE ON FUNCTION
  public._theme_price(INT),
  public._icon_price(TEXT),
  public._feature_price(TEXT),
  public._consumable_price(TEXT),
  public._coin_pack(TEXT)
FROM PUBLIC, anon, authenticated;
