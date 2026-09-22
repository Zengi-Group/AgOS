-- AgOS · ARS-694 · РАСПИСАНИЕ ЗАКУПОЧНОГО ФЛОУ (pg_cron).
-- ============================================================================
-- Спек (G2 2026-09-22): Docs/AGOS-TSP-Scheduler-ARS-694.md
-- Закрывает: S-3 (FR-001..FR-005, FR-013, FR-015, FR-019, M-001..M-006, M-014, M-015).
-- Зависимость по порядку: 20260922120000_ars_694_tsp_flow_shared_sweep.sql должна
-- быть применена ДО этой миграции — джобы зовут rpc_process_tsp_*.
--
-- ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Расписание — инфраструктура, а не тело правила: его снимают
-- и ставят независимо от кода (FR-013 — джоба нет → продукт возвращается к
-- сегодняшнему, браузерному поведению, данные целы). Образец разделения —
-- 20260717120000_membership_renewals_pg_cron.sql.
--
-- ИНТЕРВАЛ — РАЗ В ЧАС, ОДИН НА ОБА ДЖОБА (FR-005, владелец 22.09). Правила связаны
-- (истечение оффера — предусловие точки решения по цене), и разные интервалы дали бы
-- разный срок половинам одного сценария. Час, а не сутки: окна правил измеряются в
-- часах (mpk_decision_window_hours = 24, offer_window_hours = 24), суточный прогон
-- удвоил бы 24-часовое окно. Отвергнуто: каждые 15 минут (минутной точности нет ни у
-- одного правила, журнал прогонов растёт вчетверо).
--
-- РАСПИСАНИЕ ЖИВЁТ В cron.job, А НЕ В tsp_config (FR-019): pg_cron читает его из
-- своей таблицы, и строка конфига стала бы вторым домом одного факта (P4).
-- Менять расписание — инженеру миграцией; экрана управления джобами слайс не заводит.
--
-- МОМЕНТ СРАБАТЫВАНИЯ В UTC. Предикат закрытия по дедлайну стоит на current_date,
-- джоб идёт по расписанию pg_cron в UTC — для Казахстана (UTC+5) граница суток
-- наступит в 05:00 по Алматы. Семантику правила это не меняет (сегодня момент вообще
-- не определён — он равен заходу в кабинет), но делает его детерминированным.
--
-- ДВИЖОК ПРОДЛЕНИЙ НЕ АРМИРУЕТСЯ (FR-015). Установка расширения ≠ запуск продлений:
-- create extension не создаёт ни одного джоба, а membership-renewals лежит в
-- отдельном денилистном файле (scripts/agos_db.py MIGRATION_DENYLIST), который эта
-- миграция не трогает и из денилиста не вынимает. Решение об арме — за ARS-264.
--
-- ДОСТУПНОСТЬ pg_cron ЗАМЕРЕНА НА ПРОДЕ 22.09 (run_sql_rollback.py, всё откатано):
-- версия 1.6.4 доступна, shared_preload_libraries её содержит, create extension
-- прошёл под той же ролью postgres, которой ходит deploy.py, через тот же пулер.
-- Остаточный риск — изменение доступности расширений на стороне Supabase между
-- замером и выкладкой; ловится самим create extension на деплое.
--
-- МОНИТОРИНГА НЕТ (FR-020, названо вслух): единственный след неуспешного прогона —
-- cron.job_run_details, и читает его человек, когда пришёл смотреть. Дома у
-- наблюдаемости фоновых работ в AgOS сегодня нет.
--
-- Выкладка: python3 scripts/deploy.py --files supabase/migrations/20260922130000_ars_694_tsp_flow_pg_cron.sql
-- ============================================================================


-- ── 1. Extension pg_cron (создаёт схему cron: cron.job, cron.schedule/unschedule) ──
create extension if not exists pg_cron;


-- ── 2. Джобы флоу (идемпотентно: снять старый → поставить заново) ──────────────
-- cron.unschedule бросает ошибку, если джоба нет → гейтим существованием.
do $$
begin
    if exists (select 1 from cron.job where jobname = 'tsp-pool-closures') then
        perform cron.unschedule('tsp-pool-closures');
    end if;
    if exists (select 1 from cron.job where jobname = 'tsp-batch-reviews') then
        perform cron.unschedule('tsp-batch-reviews');
    end if;
end
$$;

-- Закрытие заявок по дедлайну + возврат партий по молчанию комбината (FR-001, FR-004).
select cron.schedule(
    'tsp-pool-closures',
    '0 * * * *',                                            -- раз в час, UTC (FR-005)
    $$select public.rpc_process_tsp_pool_closures(500)$$     -- глобальный вход, service_role
);

-- Истечение офферов + вход партии в точку решения по цене (FR-002, FR-003).
select cron.schedule(
    'tsp-batch-reviews',
    '0 * * * *',                                            -- тот же интервал (FR-005)
    $$select public.rpc_process_tsp_batch_reviews(500)$$
);


-- ── 3. Приёмка (выполнять вручную после выкладки, не часть миграции) ───────────
-- Джобы в реестре (оба active, расписание '0 * * * *'):
--   select jobid, jobname, schedule, command, active from cron.job
--    where jobname in ('tsp-pool-closures','tsp-batch-reviews');
--
-- Тик без ожидания часа (M-006 — на пустом множестве все счётчики 0, исключения нет):
--   select public.rpc_process_tsp_pool_closures(500);
--   → { "filled":0, "closed":0, "awaitingDecision":0, "unfilled":0,
--       "expiredEmpty":0, "failed":0, "truncated":false }
--   select public.rpc_process_tsp_batch_reviews(500);
--   → { "moved":0, "afterMinutes":N, "offersExpired":0, "truncated":false }
--
-- След прогонов (FR-013/M-015 — неуспешный прогон не молчит):
--   select jobid, runid, status, return_message, start_time
--     from cron.job_run_details order by start_time desc limit 20;
--
-- M-009 (права): из-под authenticated глобальный вход недоступен —
--   set role authenticated; select public.rpc_process_tsp_pool_closures(1);
--   → ERROR: permission denied for function rpc_process_tsp_pool_closures
--
-- Снять джобы (откат, FR-013 — продукт возвращается к браузерному поведению):
--   select cron.unschedule('tsp-pool-closures');
--   select cron.unschedule('tsp-batch-reviews');
-- ============================================================================
