-- AgOS · Биллинг · ARS-264 · АКТИВАЦИЯ ДВИЖКА ПРОДЛЕНИЙ (pg_cron).
-- =============================================================================
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  ⚠️  STAGING ONLY. НЕ ПРИМЕНЯТЬ НА ПРОД до платёжного провайдера (ARS-270).│
-- │                                                                           │
-- │  fn_charge_membership — STUB (v_ok := true): продлевает период БЕЗ        │
-- │  реальной оплаты. Армирование cron на живых организациях = бесплатные,    │
-- │  бесконечные продления. Прод-включение — ОТДЕЛЬНОЕ G3+CEO решение после    │
-- │  замены stub на реальный провайдер (ARS-270).                             │
-- │                                                                           │
-- │  Именно поэтому этот арм-DDL живёт в отдельной миграции, а НЕ в            │
-- │  каноническом d13_billing.sql: прод-деплой схемы d13 НЕ должен молча       │
-- │  запускать движок (G2-решение CEO, 2026-07-17).                           │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ФИЧА (ARS-264, умбрелла ARS-258 Q3=A): движок rpc_process_membership_renewals
-- (ARS-206, тело задеплоено, service_role-only) никем не вызывался — на проде нет
-- pg_cron. Прецедента установки extension нет: tsp_price_decision_timer осознанно
-- сделан self-serve «нет pg_cron», d03_feed — только комментарий. Это ПЕРВАЯ
-- установка pg_cron.
--
-- РЕШЕНИЯ (G2, CEO, 2026-07-17):
--   • Шедулер = pg_cron (вариант A), не edge function. Движок уже готов и
--     service_role-only; паттерн cron.schedule минимален.
--   • Расписание = ежедневно 03:00 UTC (низкий трафик). Батч p_limit=100.
--   • Идемпотентно: unschedule-if-exists → schedule. Повторное применение
--     безопасно.
--
-- ЗАВИСИМОСТЬ ПОРЯДКА: d13_billing.sql (с колонкой membership_plan.grace_days,
-- ARS-264) должен быть применён ДО этой миграции — движок читает mp.grace_days.
--
-- ПРИМЕНЯТЬ ЧЕРЕЗ SQL Editor на STAGING.
-- =============================================================================


-- ── 1. Extension pg_cron (создаёт схему cron: cron.job, cron.schedule/unschedule) ──
create extension if not exists pg_cron;


-- ── 2. Джоб продлений (идемпотентно: снять старый → поставить заново) ──────────
-- cron.unschedule бросает ошибку, если джоба нет → гейтим существованием.
do $$
begin
    if exists (select 1 from cron.job where jobname = 'membership-renewals') then
        perform cron.unschedule('membership-renewals');
    end if;
end
$$;

select cron.schedule(
    'membership-renewals',                                 -- имя джоба (стабильное)
    '0 3 * * *',                                           -- ежедневно в 03:00 UTC
    $$select public.rpc_process_membership_renewals(100)$$ -- глобальный движок, service_role
);


-- ── 3. Приёмка (STAGING, выполнять вручную, не часть миграции) ─────────────────
-- Джоб виден в реестре:
--   select jobid, jobname, schedule, command, active from cron.job
--    where jobname = 'membership-renewals';
--
-- Тик движка без ожидания 03:00 (подписка с next_billing_at <= now() в
-- trialing/active/grace/past_due катится по success-ветке stub → active + событие
-- membership.subscription.renewed; grace-лестница проходима):
--   select public.rpc_process_membership_renewals(100);
--   → { "processed": N, "renewed": ..., "deferred": ..., "expired": ... }
--
-- grace_days берётся из плана (P8):
--   update public.membership_plan set grace_days = 5 where plan_code = 'org_monthly';
--   -- следующая неуспешная оплата даст next_billing_at = now() + 5 дней.
--
-- Снять джоб (откат):
--   select cron.unschedule('membership-renewals');
-- =============================================================================
