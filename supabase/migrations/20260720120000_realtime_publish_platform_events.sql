-- AgOS · Governance-wiring · ARS-269 (slice B) · REALTIME-АРМИРОВАНИЕ platform_events.
-- =============================================================================
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  ✅ PROD-SAFE. Можно применять на прод сразу (в отличие от ARS-264 pg_cron).│
-- │                                                                           │
-- │  platform_events: RLS ВКЛЮЧЕНА (d01_kernel.sql) + политика               │
-- │  platform_events_read_own (organization_id = any(fn_my_org_ids())).       │
-- │  Supabase Realtime применяет RLS к postgres_changes → клиент получает     │
-- │  ТОЛЬКО события своей организации. Межтенантной утечки нет.               │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- НАХОДКА VERIFY (ARS-269, прод mwtbozflyldcadypherr, 2026-07-20):
-- публикация `supabase_realtime` существует, но puballtables=false и содержит
-- 0 таблиц → postgres_changes на проде инертен для ВСЕХ таблиц. Значит и новый
-- слушатель кабинета (useEntitlementsRealtimeSync), и уже задеплоенный
-- useTaxonomyRealtimeSync НЕ получают событий, пока их таблицы не добавлены в
-- публикацию. Realtime на этом проекте не был армирован ни разу.
--
-- ФИЧА (ARS-269 slice B): кабинет фермера слушает событие
-- `entitlements.invalidated` (эмитится d13_billing на subscribe/cancel/renewals/
-- admin manual-pay/extend/revoke ARS-267) в platform_events и тихо пере-грузит
-- профиль/подписку → deriveMembership пересчитывает статус за секунды вместо
-- «до полного reload». Soft-invalidation (M3 §5, D-FG-4): сервер и так enforce'ит
-- TSP-гейты через fn_org_membership_active — это свежесть UI, не гейт.
--
-- ПОЧЕМУ ОТДЕЛЬНАЯ МИГРАЦИЯ (не канонический d-файл): членство таблицы в
-- публикации supabase_realtime — это инфра-конфиг окружения, а не доменная схема
-- (нет таблицы/колонки/RPC). Прецедент — ARS-264 (арм-DDL вне d13). Realtime у
-- Supabase обычно включается тумблером в дашборде, который под капотом делает
-- ровно этот ALTER PUBLICATION.
--
-- ИДЕМПОТЕНТНО: добавляем таблицу только если её ещё нет в публикации
-- (ALTER PUBLICATION ... ADD TABLE падает, если таблица уже участник).
-- =============================================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'platform_events'
  ) then
    alter publication supabase_realtime add table public.platform_events;
  end if;
end
$$;
