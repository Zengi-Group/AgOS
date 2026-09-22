-- ARS-694 / Планировщик закупочного флоу: судьба сделки перестаёт зависеть от вкладки.
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01): миграция общего
-- тела и этот тест идут ОДНОЙ откатываемой транзакцией:
--   cat supabase/migrations/20260922120000_ars_694_tsp_flow_shared_sweep.sql \
--       tests/ars_694_tsp_flow_scheduler_test.sql > /tmp/ars694_run.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars694_run.sql
-- Прогон заканчивается ROLLBACK: ни одной строки не остаётся. Сторож ниже роняет
-- прогон ДО первой записи, если файл исполняется автокоммитом.
--
-- Предмет: supabase/migrations/20260922120000_ars_694_tsp_flow_shared_sweep.sql
--          supabase/migrations/20260922130000_ars_694_tsp_flow_pg_cron.sql
-- Спек (G2 2026-09-22): Docs/AGOS-TSP-Scheduler-ARS-694.md
--
-- ПОКРЫТИЕ МАТРИЦЫ (id назван в КАЖДОМ утверждении — Matrix Test Audit сверяет ПО ID,
-- совпадение «по смыслу» считается непокрытым):
--   этим файлом — M-001 · M-002 · M-003 · M-004 · M-005 · M-006 · M-008 · M-009 ·
--                 M-010 · M-012 · M-013
--   НЕ покрыто и помечено честно:
--     M-007 (гонка джоб↔кабинет) — требует ДВУХ соединений; однопоточно не
--           воспроизводится. Механизм (`for update skip locked` + перечтение статуса
--           под блокировкой) читается в теле, но это не прогон, и засчитывать его
--           за прогон нельзя (прецедент ARS-695 M-011, ARS-760 M-014).
--     M-011 (отказ ветки партий) — покрыт СТРУКТУРНО: утверждение ниже проверяет, что
--           у ветки партий нет и не появилось счётчика `failed`. Вторая половина —
--           инъекция отказа в set-based оператор — потребовала бы временного триггера
--           на public.batches, то есть ACCESS EXCLUSIVE на живой таблице единственной
--           боевой базы; цена выше доказательства, поэтому НЕ проведена.
--     M-014 / M-015 (деградация: джоба нет / джоб падает) — свойства инфраструктуры,
--           а не данных. Прибор — `select ... from cron.job` / `cron.job_run_details`
--           после выкладки (приёмка в 20260922130000_ars_694_tsp_flow_pg_cron.sql §3)
--           плюс то, что этот файл прогоняет ТЕ ЖЕ тела через кабинетные RPC (M-013):
--           снятый джоб возвращает продукт ровно к ним.
--
-- ФАЛЬСИФИЦИРУЕМОСТЬ. Без миграции слайса падают M-001..M-005 и M-009: функций
-- rpc_process_tsp_* не существует вовсе, а сегодняшние правила исполняются только
-- из-под вошедшего пользователя по ЕГО организациям. Прибор на охват — M-001/M-004:
-- прогон идёт БЕЗ jwt-claims (fn_current_user_id() = null, fn_my_org_ids() пуст), и
-- под старым телом ни одна фикстура не сдвинулась бы.
--
-- ФИКСТУРЫ СВОИ ЦЕЛИКОМ: свой регион, свои организации, свои заявки/партии/офферы.
-- Существующие строки прода как фикстуру не читает. Счётчики прогона по всей базе
-- проверяются ТОЛЬКО там, где множество заведомо пусто (M-006 — второй прогон).

\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-694_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    v_region     uuid := gen_random_uuid();
    v_org_mpk    uuid := gen_random_uuid();   -- комбинат сценариев M-001..M-005, M-010
    v_org_mpk_v  uuid := gen_random_uuid();   -- комбинат M-012 (объём) — ЧУЖОЙ оператору
    v_org_farm   uuid := gen_random_uuid();   -- фермер: партии и офферы

    v_auth_op    uuid := gen_random_uuid();   -- оператор комбината (кабинет, M-013)
    v_user_op    uuid;
    v_auth_farm  uuid := gen_random_uuid();   -- фермер (кабинет, M-013)
    v_user_farm  uuid;

    v_sku_id     uuid;
    v_min        int;
    v_above      int;
    v_target     int;
    v_window     int;
    v_month_old  date := (date_trunc('month', now()) - interval '2 month')::date;
    v_month      date := date_trunc('month', now())::date;
    v_ask        int  := 1400;

    -- M-001 · дедлайн прошёл, набрано выше порога и ниже цели → точка выбора
    v_pr1   uuid := gen_random_uuid(); v_pool1 uuid := gen_random_uuid(); v_pl1 uuid := gen_random_uuid();
    v_b1    uuid := gen_random_uuid();
    -- M-004 · молчание комбината дольше окна → возврат партий
    v_pr4   uuid := gen_random_uuid(); v_pool4 uuid := gen_random_uuid(); v_pl4 uuid := gen_random_uuid();
    v_b4    uuid := gen_random_uuid();
    -- M-005 · заявка набралась и закрылась джобом → куски confirmed, контакты раскрыты
    v_pr5   uuid := gen_random_uuid(); v_pool5 uuid := gen_random_uuid(); v_pl5 uuid := gen_random_uuid();
    v_b5    uuid := gen_random_uuid();
    -- M-010 · отказ ОДНОЙ заявки внутри цикла (счётчик matched_heads разошёлся с реальностью)
    v_pr10  uuid := gen_random_uuid(); v_pool10 uuid := gen_random_uuid(); v_pl10 uuid := gen_random_uuid();
    v_b10   uuid := gen_random_uuid();
    -- M-012 · объём: три созревшие заявки чужого комбината, p_limit = 2
    v_pr12a uuid := gen_random_uuid(); v_pool12a uuid := gen_random_uuid();
    v_pr12b uuid := gen_random_uuid(); v_pool12b uuid := gen_random_uuid();
    v_pr12c uuid := gen_random_uuid(); v_pool12c uuid := gen_random_uuid();
    -- M-012 · бюджет прогона: по одной созревшей строке в КАЖДУЮ ветку заявок
    v_pr12d uuid := gen_random_uuid(); v_pool12d uuid := gen_random_uuid();
    v_pr12e uuid := gen_random_uuid(); v_pool12e uuid := gen_random_uuid();
    -- M-012 · объём у ветки партий: три партии, которым рынок отказал
    v_bat12a uuid := gen_random_uuid();
    v_bat12b uuid := gen_random_uuid();
    v_bat12c uuid := gen_random_uuid();

    -- M-002 · партия, которой рынок отказал (expired-оффер нынешнего круга, pending нет)
    v_bat2  uuid := gen_random_uuid();
    -- M-003 · оффер с истёкшим сроком на частично проданной партии
    v_bat3  uuid := gen_random_uuid();

    v_res    jsonb;
    v_res2   jsonb;
    v_status text;
    v_int    int;
    v_ts     timestamptz;
    v_uuid   uuid;
    v_err    text;
begin
    -- ==================================================================================
    -- 1. Фикстуры общего назначения
    -- ==================================================================================
    v_min := public.fn_tsp_pool_min_heads();
    if v_min is null or v_min < 1 then
        raise exception 'ARS-694_TEST_SETUP: fn_tsp_pool_min_heads вернул % — фикстура недостоверна', v_min;
    end if;
    v_above  := v_min + 2;
    v_target := v_above * 10;

    select mpk_decision_window_hours into v_window
    from public.tsp_config where is_active = true limit 1;
    v_window := coalesce(v_window, 24);

    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-694-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-694 область', 'oblast');

    insert into auth.users (id) values (v_auth_op), (v_auth_farm);
    select id into v_user_op   from public.users where auth_id = v_auth_op;
    select id into v_user_farm from public.users where auth_id = v_auth_farm;
    if v_user_op is null or v_user_farm is null then
        raise exception 'ARS-694_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_mpk,   'QA ARS-694 МПК',        'too', v_region, 'г. QA, ул. 1', null),
           (v_org_mpk_v, 'QA ARS-694 МПК объём',  'too', v_region, 'г. QA, ул. 2', null),
           (v_org_farm,  'QA ARS-694 КХ',         'kh',  v_region, 'г. QA, ул. 3', '+7 700 000 06 94');

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk, 'mpk'), (v_org_mpk_v, 'mpk'), (v_org_farm, 'farmer');

    -- Оператор состоит ТОЛЬКО в v_org_mpk: заявки v_org_mpk_v для его кабинета чужие.
    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user_op, v_org_mpk, 'owner'), (v_user_farm, v_org_farm, 'owner');

    select id into v_sku_id from public.tsp_skus where is_active = true limit 1;
    if v_sku_id is null then
        raise exception 'ARS-694_TEST_SETUP: не нашёл активный tsp_sku — фикстура недостоверна';
    end if;

    -- ==================================================================================
    -- 2. Заявки комбината. target_month в ПРОШЛОМ везде, где сценарий про дедлайн.
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    -- Заявки сценария M-012 здесь НЕ заводятся: они созревшие, и полный прогон ниже
    -- (p_limit=500) съел бы их раньше, чем начнётся замер предела. Их дом — раздел 7.
    values (v_pr1,   v_org_mpk,   v_target, v_month_old, v_region, 'active'),
           (v_pr4,   v_org_mpk,   v_target, v_month,     v_region, 'active'),
           (v_pr5,   v_org_mpk,   v_target, v_month_old, v_region, 'active'),
           (v_pr10,  v_org_mpk,   v_target, v_month_old, v_region, 'active');

    insert into public.pools (id, pool_request_id, organization_id, target_heads,
                              matched_heads, status, awaiting_decision_at)
    values
        -- M-001: дедлайн прошёл, набрано выше порога и ниже цели
        (v_pool1, v_pr1, v_org_mpk, v_target, v_above, 'filling', null),
        -- M-004: уже в точке выбора, молчание ДЛИННЕЕ окна решения
        (v_pool4, v_pr4, v_org_mpk, v_target, v_above, 'awaiting_mpk_decision',
         now() - make_interval(hours => v_window + 1)),
        -- M-005: набрано ЦЕЛИКОМ, закрыть некому — заявка ждёт джоба
        (v_pool5, v_pr5, v_org_mpk, v_above, v_above, 'filling', null),
        -- M-010: счётчик matched_heads лжёт (0), партия привязана по-настоящему
        (v_pool10, v_pr10, v_org_mpk, v_target, 0, 'filling', null);

    insert into public.pool_lines (id, pool_id, tsp_sku_id, mpk_price_per_kg, current_heads)
    values (v_pl1,  v_pool1,  v_sku_id, 1300, v_above),
           (v_pl4,  v_pool4,  v_sku_id, 1300, v_above),
           (v_pl5,  v_pool5,  v_sku_id, 1300, v_above),
           (v_pl10, v_pool10, v_sku_id, 1300, v_above);

    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, pool_line_id,
                                matched_heads, deal_price_per_kg)
    values (v_b1,  v_org_farm, v_sku_id, v_above, 400.00, v_month, v_region, 'matched', v_pl1,  v_above, 1300),
           (v_b4,  v_org_farm, v_sku_id, v_above, 400.00, v_month, v_region, 'matched', v_pl4,  v_above, 1300),
           (v_b5,  v_org_farm, v_sku_id, v_above, 400.00, v_month, v_region, 'matched', v_pl5,  v_above, 1300),
           (v_b10, v_org_farm, v_sku_id, v_above, 400.00, v_month, v_region, 'matched', v_pl10, v_above, 1300);

    insert into public.batch_allocations (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values (v_b1,  v_pl1,  v_pool1,  v_above, 1300, 'matched'),
           (v_b4,  v_pl4,  v_pool4,  v_above, 1300, 'matched'),
           (v_b5,  v_pl5,  v_pool5,  v_above, 1300, 'matched'),
           (v_b10, v_pl10, v_pool10, v_above, 1300, 'matched');

    -- ==================================================================================
    -- 3. Партии фермера для ветки партий
    -- ==================================================================================
    -- M-002 · рынок отказал: оффер нынешнего круга уже expired, живых pending нет.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at)
    values (v_bat2, v_org_farm, v_sku_id, 25, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '3 days', now() - interval '3 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_bat2, v_org_mpk, v_ask, 'expired', now() - interval '1 day', now() - interval '3 days');

    -- M-003 · оффер с прошедшим сроком на частично проданной партии: гаснет по СВОЕМУ
    -- сроку, статус партии при этом не трогается (правило ARS-760 FR-002).
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                matched_heads, published_at, offering_at)
    values (v_bat3, v_org_farm, v_sku_id, 25, 420.00, v_month, v_region,
            'partially_matched', v_ask, 10, now() - interval '5 days', now() - interval '5 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_bat3, v_org_mpk, v_ask, 'pending', now() - interval '2 hours', now() - interval '5 days');

    -- ==================================================================================
    -- 4. ПРОГОН ДЖОБА. Ни jwt-claims, ни роли: у джоба нет пользователя —
    --    fn_current_user_id() = null, fn_my_org_ids() пуст. Именно это и проверяется:
    --    под старым, кабинетным телом не сдвинулась бы ни одна строка.
    -- ==================================================================================
    if public.fn_current_user_id() is not null then
        raise exception 'ARS-694_TEST_SETUP: fn_current_user_id() не пуст — прогон идёт '
                        'не в условиях джоба, доказательство недействительно';
    end if;

    v_res  := public.rpc_process_tsp_pool_closures(500);
    v_res2 := public.rpc_process_tsp_batch_reviews(500);
    raise notice 'ARS-694 прогон джоба · заявки: % · партии: %', v_res, v_res2;

    -- ── M-001 · заявка с прошедшим дедлайном закрыта без входа в кабинет ─────────────
    select status into v_status from public.pools where id = v_pool1;
    if v_status <> 'awaiting_mpk_decision' then
        raise exception 'ARS-694 M-001 ПРОВАЛ: заявка с истёкшим месяцем поставки осталась «%» '
                        '— судьба сделки по-прежнему ждёт открытой вкладки', v_status;
    end if;
    if (v_res ->> 'awaitingDecision')::int < 1 then
        raise exception 'ARS-694 M-001 ПРОВАЛ: заявка перешла, но прогон отдал awaitingDecision=% '
                        '— ответ не описывает сделанного', v_res ->> 'awaitingDecision';
    end if;
    raise notice 'ARS-694 M-001 OK: filling → awaiting_mpk_decision без единого захода в кабинет';

    -- ── M-004 · молчание комбината вернуло партии, и это сделал НЕ человек ───────────
    select status into v_status from public.pools where id = v_pool4;
    if v_status <> 'closed_unfilled' then
        raise exception 'ARS-694 M-004 ПРОВАЛ: заявка, простоявшая в точке выбора дольше '
                        'окна (% ч), осталась «%» — «через 24 ч» так и не получило '
                        'буквального смысла', v_window, v_status;
    end if;
    select status into v_status from public.batches where id = v_b4;
    if v_status <> 'published' then
        raise exception 'ARS-694 M-004 ПРОВАЛ: партия после возврата в статусе «%» '
                        '(ожидалось published) — фермер не получил её обратно', v_status;
    end if;
    select count(*) into v_int
    from public.platform_events
    where entity_id = v_pool4 and event_type = 'market.pool.closed_unfilled'
      and actor_type = 'system' and actor_id is null;
    if v_int <> 1 then
        raise exception 'ARS-694 M-004 ПРОВАЛ: событий market.pool.closed_unfilled с '
                        'actor_id is null = % (ожидалось 1) — под джобом у события '
                        'появился человек-автор', v_int;
    end if;
    -- Содержимое payload закрепляется ЗДЕСЬ: после выноса тела в fn_-хелпер ключи
    -- payload больше не попадают в снапшот CHECK 11 (он снимает только rpc_*), и без
    -- этого утверждения они не закреплены нигде (FR-016 — событие пишется как сегодня).
    select count(*) into v_int
    from public.platform_events
    where entity_id = v_pool4 and event_type = 'market.pool.closed_unfilled'
      and payload ->> 'pool_id' = v_pool4::text
      and payload ->> 'reason'  = 'decision_window_elapsed'
      and (payload ->> 'window_hours')::int = v_window;
    if v_int <> 1 then
        raise exception 'ARS-694 M-004 ПРОВАЛ: payload события изменился — ожидались '
                        'pool_id/reason=decision_window_elapsed/window_hours=%', v_window;
    end if;
    raise notice 'ARS-694 M-004 OK: возврат по молчанию исполнен джобом, actor_id = null';

    -- ── M-005 · выигрыш флоу целиком: заявка закрыта, куски подтверждены, контакты ───
    select status, mpk_contact_revealed_at into v_status, v_ts
    from public.pools where id = v_pool5;
    if v_status <> 'closed_filled' then
        raise exception 'ARS-694 M-005 ПРОВАЛ: набравшаяся заявка осталась «%» — приёмка, '
                        'отгрузка и отзывы недостижимы, ради чего слайс и делается', v_status;
    end if;
    if v_ts is null then
        raise exception 'ARS-694 M-005 ПРОВАЛ: заявка закрыта, а контакты не раскрыты — '
                        'стороны не могут договориться об отгрузке';
    end if;
    select status into v_status from public.batch_allocations
    where batch_id = v_b5 and pool_id = v_pool5;
    if v_status <> 'confirmed' then
        raise exception 'ARS-694 M-005 ПРОВАЛ: кусок партии остался «%» вместо confirmed', v_status;
    end if;
    raise notice 'ARS-694 M-005 OK: заявка закрыта джобом, куски confirmed, контакты раскрыты';

    -- ── M-010 · отказ ОДНОЙ заявки не роняет прогон ─────────────────────────────────
    -- Заявка с лживым matched_heads=0 идёт в ветку expired_empty, где страж
    -- fn_tsp_pool_assert_settled находит реально привязанную партию и кидает.
    if (v_res ->> 'failed')::int < 1 then
        raise exception 'ARS-694 M-010 ПРОВАЛ: заявка со сломанным счётчиком не дала '
                        'failed>0 (failed=%) — отказ проглочен молча', v_res ->> 'failed';
    end if;
    select status into v_status from public.pools where id = v_pool10;
    if v_status <> 'filling' then
        raise exception 'ARS-694 M-010 ПРОВАЛ: у упавшей заявки статус «%» — подтранзакция '
                        'не откатила полу-применённое решение', v_status;
    end if;
    raise notice 'ARS-694 M-010 OK: одна заявка упала (failed=%), остальные обработаны, '
                 'полу-записи нет', v_res ->> 'failed';

    -- ── M-002 · партия ушла в точку решения по цене без открытой вкладки ────────────
    select status into v_status from public.batches where id = v_bat2;
    if v_status <> 'awaiting_price_decision' then
        raise exception 'ARS-694 M-002 ПРОВАЛ: партия, которой рынок отказал, осталась «%» '
                        '— вход в точку решения по-прежнему требует вкладки фермера', v_status;
    end if;
    select count(*) into v_int
    from public.batch_events
    where batch_id = v_bat2 and event_type = 'price_decision_due' and created_by is null;
    if v_int <> 1 then
        raise exception 'ARS-694 M-002 ПРОВАЛ: событий price_decision_due с created_by is null '
                        '= % (ожидалось 1)', v_int;
    end if;
    -- metadata закрепляется здесь по той же причине, что payload у M-004: снапшот
    -- CHECK 11 её ключи больше не видит. Значения оставлены КАК БЫЛИ (ARS-760).
    select count(*) into v_int
    from public.batch_events
    where batch_id = v_bat2 and event_type = 'price_decision_due'
      and metadata ->> 'trigger' = 'review_due'
      and (metadata ->> 'after_minutes')::int = (v_res2 ->> 'afterMinutes')::int;
    if v_int <> 1 then
        raise exception 'ARS-694 M-002 ПРОВАЛ: metadata события изменилась — ожидались '
                        'trigger=review_due и after_minutes=%', v_res2 ->> 'afterMinutes';
    end if;
    raise notice 'ARS-694 M-002 OK: offering → awaiting_price_decision, событие без автора-человека';

    -- ── M-003 · оффер погас по своему сроку, партия не тронута ──────────────────────
    select status, responded_at into v_status, v_ts from public.offers where batch_id = v_bat3;
    if v_status <> 'expired' then
        raise exception 'ARS-694 M-003 ПРОВАЛ: оффер с истёкшим expires_at остался «%» — '
                        'срок предложения снова зависит от чьей-то открытой вкладки', v_status;
    end if;
    if v_ts is null then
        raise exception 'ARS-694 M-003 ПРОВАЛ: у погашенного оффера не проставлен responded_at';
    end if;
    select status into v_status from public.batches where id = v_bat3;
    if v_status <> 'partially_matched' then
        raise exception 'ARS-694 M-003 ПРОВАЛ: статус частично проданной партии изменился на «%» '
                        '— правило ARS-760 переписано, а слайс не вправе (FR-014)', v_status;
    end if;
    if (v_res2 ->> 'offersExpired')::int < 1 then
        raise exception 'ARS-694 M-003 ПРОВАЛ: оффер погашен, но прогон отдал offersExpired=%',
                        v_res2 ->> 'offersExpired';
    end if;
    raise notice 'ARS-694 M-003 OK: оффер expired + responded_at, партия не тронута';

    -- ── M-011 (структурно) · у ветки партий нет счётчика failed ─────────────────────
    -- Тело set-based: отказ роняет оператор целиком, полу-записи не бывает, и вводить
    -- failed значило бы переписать правило (FR-014). Проверяем форму ответа, а не
    -- инъекцию отказа — почему именно так, сказано в шапке файла.
    if v_res2 ? 'failed' then
        raise exception 'ARS-694 M-011 ПРОВАЛ: у ветки партий появился ключ failed — '
                        'правило переписано под счётчик, которого у set-based тела быть не может';
    end if;
    raise notice 'ARS-694 M-011 OK (структурно): ключа failed у ветки партий нет';

    -- ==================================================================================
    -- 5. M-006 (пусто) и M-008 (повтор). Рукотворную аварию M-010 сначала выводим из
    --    множества созревших — иначе «пусто» мерило бы её, а не пустоту.
    -- ==================================================================================
    update public.pools set status = 'cancelled' where id = v_pool10;

    v_res  := public.rpc_process_tsp_pool_closures(500);
    v_res2 := public.rpc_process_tsp_batch_reviews(500);

    -- ── M-006 · ни одной созревшей строки: все счётчики 0, исключения нет ───────────
    -- ЧЕСТНАЯ ОГОВОРКА (прибор меряет ВСЮ базу, изолированной среды нет —
    -- QA-ENV-ISOLATION-01): утверждение верно, только если первый прогон выгреб всё.
    -- Оно даст ЛОЖНОЕ падение, если во время прогона другой писатель создал созревшую
    -- строку, если первый прогон упёрся в p_limit=500 на реальных данных, или если
    -- живая вкладка кабинета держала строку под блокировкой и её пропустил `skip locked`.
    -- Замер 22.09 на проде: созревших заявок 0, партий 1, второй прогон 0 — поэтому
    -- утверждение сегодня измеряет пустоту, а не соседей. Падение здесь читать сначала
    -- как «на базе появилась работа», и только потом как регресс.
    if (v_res ->> 'filled')::int <> 0 or (v_res ->> 'closed')::int <> 0
       or (v_res ->> 'awaitingDecision')::int <> 0 or (v_res ->> 'unfilled')::int <> 0
       or (v_res ->> 'expiredEmpty')::int <> 0 or (v_res ->> 'failed')::int <> 0 then
        raise exception 'ARS-694 M-006 ПРОВАЛ: на пустом множестве прогон заявок отдал % '
                        '— он делает работу там, где работы нет', v_res;
    end if;
    if (v_res2 ->> 'moved')::int <> 0 or (v_res2 ->> 'offersExpired')::int <> 0 then
        raise exception 'ARS-694 M-006 ПРОВАЛ: на пустом множестве прогон партий отдал %', v_res2;
    end if;
    if (v_res ->> 'truncated')::boolean or (v_res2 ->> 'truncated')::boolean then
        raise exception 'ARS-694 M-006 ПРОВАЛ: пустой прогон помечен незавершённым';
    end if;
    raise notice 'ARS-694 M-006 OK: пустой прогон — все счётчики 0, исключения нет';

    -- ── M-008 · повтор: ни второго перехода, ни второго события ─────────────────────
    select count(*) into v_int
    from public.batch_events
    where batch_id = v_bat2 and event_type = 'price_decision_due';
    if v_int <> 1 then
        raise exception 'ARS-694 M-008 ПРОВАЛ: после двух прогонов подряд событий '
                        'price_decision_due по одной партии = % (ожидалось 1)', v_int;
    end if;
    select count(*) into v_int
    from public.platform_events
    where entity_id = v_pool4 and event_type = 'market.pool.closed_unfilled';
    if v_int <> 1 then
        raise exception 'ARS-694 M-008 ПРОВАЛ: после двух прогонов подряд событий '
                        'market.pool.closed_unfilled по одной заявке = % (ожидалось 1)', v_int;
    end if;
    raise notice 'ARS-694 M-008 OK: второй прогон — 0 переходов, второго события нет';

    -- ==================================================================================
    -- 6. M-013 · кабинет ПОСЛЕ джоба находит 0 работы (и это ровно тот же ответ,
    --    что был у кабинета всегда — форма не изменилась, FR-011).
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_op::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_self_close_due_pools();
    execute 'reset role';

    if (v_res ->> 'filled')::int <> 0 or (v_res ->> 'closed')::int <> 0
       or (v_res ->> 'awaitingDecision')::int <> 0 or (v_res ->> 'unfilled')::int <> 0
       or (v_res ->> 'expiredEmpty')::int <> 0 or (v_res ->> 'failed')::int <> 0 then
        raise exception 'ARS-694 M-013 ПРОВАЛ: кабинет комбината после прогона джоба нашёл '
                        'работу % — состояние при входе оказалось НЕ правильным', v_res;
    end if;
    if v_res ? 'truncated' then
        raise exception 'ARS-694 M-013 ПРОВАЛ: в ответе кабинетной RPC появился ключ truncated '
                        '— форма ответа изменилась, у фронта сломан контракт (FR-011)';
    end if;

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res2 := public.rpc_self_review_due_batches();
    execute 'reset role';

    if (v_res2 ->> 'moved')::int <> 0 or (v_res2 ->> 'offersExpired')::int <> 0 then
        raise exception 'ARS-694 M-013 ПРОВАЛ: кабинет фермера после прогона джоба нашёл '
                        'работу %', v_res2;
    end if;
    if v_res2 ? 'truncated' then
        raise exception 'ARS-694 M-013 ПРОВАЛ: в ответе кабинетной RPC партий появился ключ '
                        'truncated — форма ответа изменилась (FR-011)';
    end if;
    if (v_res2 ->> 'afterMinutes') is null then
        raise exception 'ARS-694 M-013 ПРОВАЛ: из ответа кабинета исчез afterMinutes (FR-011)';
    end if;
    raise notice 'ARS-694 M-013 OK: оба кабинета находят 0 работы, форма ответа прежняя';

    -- ==================================================================================
    -- 7. M-012 · объём: созревших заявок больше p_limit
    -- Заявки заводятся ЗДЕСЬ, после всех полных прогонов: заведённые в разделе 2 они
    -- были бы обработаны прогоном с p_limit=500 и мерить предел стало бы не на чем.
    -- Комбинат чужой оператору (v_org_mpk_v) — кабинетная проверка M-013 выше их не
    -- видела и не могла подмести.
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr12a, v_org_mpk_v, v_target, v_month_old, v_region, 'active'),
           (v_pr12b, v_org_mpk_v, v_target, v_month_old, v_region, 'active'),
           (v_pr12c, v_org_mpk_v, v_target, v_month_old, v_region, 'active');
    insert into public.pools (id, pool_request_id, organization_id, target_heads,
                              matched_heads, status, awaiting_decision_at)
    values (v_pool12a, v_pr12a, v_org_mpk_v, v_target, 0, 'filling', null),
           (v_pool12b, v_pr12b, v_org_mpk_v, v_target, 0, 'filling', null),
           (v_pool12c, v_pr12c, v_org_mpk_v, v_target, 0, 'filling', null);

    v_res := public.rpc_process_tsp_pool_closures(2);

    select count(*) into v_int
    from public.pools
    where id in (v_pool12a, v_pool12b, v_pool12c) and status = 'filling';
    if v_int <> 1 then
        raise exception 'ARS-694 M-012 ПРОВАЛ: из трёх созревших заявок при p_limit=2 осталось '
                        'необработанными % (ожидалась ровно 1) — предел объёма не соблюдён', v_int;
    end if;
    if (v_res ->> 'expiredEmpty')::int <> 2 then
        raise exception 'ARS-694 M-012 ПРОВАЛ: при p_limit=2 обработано % заявок',
                        v_res ->> 'expiredEmpty';
    end if;
    if not (v_res ->> 'truncated')::boolean then
        raise exception 'ARS-694 M-012 ПРОВАЛ: прогон взял полный предел и не отдал признак '
                        'незавершённости — затор молчит вместо того, чтобы быть видным';
    end if;
    -- Остаток уходит в следующий прогон, а не теряется.
    v_res := public.rpc_process_tsp_pool_closures(2);
    select count(*) into v_int
    from public.pools
    where id in (v_pool12a, v_pool12b, v_pool12c) and status = 'filling';
    if v_int <> 0 then
        raise exception 'ARS-694 M-012 ПРОВАЛ: остаток не обработан следующим прогоном '
                        '(осталось %)', v_int;
    end if;
    if (v_res ->> 'truncated')::boolean then
        raise exception 'ARS-694 M-012 ПРОВАЛ: прогон, взявший меньше предела, помечен '
                        'незавершённым — признак затора кричит впустую';
    end if;

    -- M-012 · ВЕТКА ПАРТИЙ. Отдельный прибор: без него предел объёма был бы доказан
    -- только для половины джоба (находка ревью якоря 7 — «у ветки партий p_limit и
    -- truncated не прогоняются ни разу»).
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at)
    values (v_bat12a, v_org_farm, v_sku_id, 25, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '3 days', now() - interval '3 days'),
           (v_bat12b, v_org_farm, v_sku_id, 25, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '3 days', now() - interval '3 days'),
           (v_bat12c, v_org_farm, v_sku_id, 25, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '3 days', now() - interval '3 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_bat12a, v_org_mpk, v_ask, 'expired', now() - interval '1 day', now() - interval '3 days'),
           (v_bat12b, v_org_mpk, v_ask, 'expired', now() - interval '1 day', now() - interval '3 days'),
           (v_bat12c, v_org_mpk, v_ask, 'expired', now() - interval '1 day', now() - interval '3 days');

    v_res2 := public.rpc_process_tsp_batch_reviews(2);
    select count(*) into v_int
    from public.batches
    where id in (v_bat12a, v_bat12b, v_bat12c) and status = 'offering';
    if v_int <> 1 then
        raise exception 'ARS-694 M-012 ПРОВАЛ (партии): из трёх созревших партий при '
                        'p_limit=2 осталось необработанными % (ожидалась ровно 1)', v_int;
    end if;
    if (v_res2 ->> 'moved')::int <> 2 or not (v_res2 ->> 'truncated')::boolean then
        raise exception 'ARS-694 M-012 ПРОВАЛ (партии): прогон отдал % — ожидались '
                        'moved=2 и truncated=true', v_res2;
    end if;
    v_res2 := public.rpc_process_tsp_batch_reviews(2);
    select count(*) into v_int
    from public.batches
    where id in (v_bat12a, v_bat12b, v_bat12c) and status = 'offering';
    if v_int <> 0 or (v_res2 ->> 'truncated')::boolean then
        raise exception 'ARS-694 M-012 ПРОВАЛ (партии): остаток не дочищен или прогон '
                        'ниже предела помечен незавершённым (осталось %, ответ %)', v_int, v_res2;
    end if;

    -- M-012 · предел принадлежит ПРОГОНУ, а не запросу. Прибор на бюджет: p_limit=1 при
    -- двух созревших ветках заявок (дедлайн + молчание) обязан тронуть ОДНУ строку
    -- суммарно, а не по одной на каждый цикл (находка ревью якоря 7: два `limit p_limit`
    -- давали до 2 × p_limit строк за прогон).
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr12d, v_org_mpk_v, v_target, v_month_old, v_region, 'active'),
           (v_pr12e, v_org_mpk_v, v_target, v_month,     v_region, 'active');
    insert into public.pools (id, pool_request_id, organization_id, target_heads,
                              matched_heads, status, awaiting_decision_at)
    values (v_pool12d, v_pr12d, v_org_mpk_v, v_target, 0, 'filling', null),
           (v_pool12e, v_pr12e, v_org_mpk_v, v_target, 0, 'awaiting_mpk_decision',
            now() - make_interval(hours => v_window + 1));

    v_res := public.rpc_process_tsp_pool_closures(1);
    select count(*) into v_int
    from public.pools
    where id in (v_pool12d, v_pool12e) and status in ('filling', 'awaiting_mpk_decision');
    if v_int <> 1 then
        raise exception 'ARS-694 M-012 ПРОВАЛ (бюджет): при p_limit=1 прогон тронул обе '
                        'ветки — предел стоит на запросе, а не на прогоне (осталось %)', v_int;
    end if;
    if not (v_res ->> 'truncated')::boolean then
        raise exception 'ARS-694 M-012 ПРОВАЛ (бюджет): предел выбран целиком, а прогон '
                        'не помечен незавершённым';
    end if;

    -- Нулевой и отрицательный предел — ошибка вызывающего, а не тихое «ничего не делать».
    begin
        perform public.rpc_process_tsp_pool_closures(0);
        raise exception 'ARS-694 M-012 ПРОВАЛ: p_limit=0 принят молча — прогон отдал бы '
                        'признак затора, не тронув ни строки';
    exception
        when sqlstate 'P0001' then
            if position('INVALID_LIMIT' in sqlerrm) = 0 then
                raise exception 'ARS-694 M-012 ПРОВАЛ: при p_limit=0 ожидался INVALID_LIMIT, '
                                'получено «%»', sqlerrm;
            end if;
    end;

    raise notice 'ARS-694 M-012 OK: p_limit соблюдён обеими ветками и прогоном в целом, '
                 'truncated честен, остаток дочищен следующим прогоном, 0 отвергнут';

    -- ==================================================================================
    -- 8. M-009 · права: вошедший пользователь не достаёт до глобального входа
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_op::text, 'role', 'authenticated')::text, true);
    begin
        execute 'set local role authenticated';
        perform public.rpc_process_tsp_pool_closures(1);
        execute 'reset role';
        raise exception 'ARS-694 M-009 ПРОВАЛ: authenticated исполнил глобальный вход — '
                        'любой вошедший получил запись в чужие сделки (ст. 171)';
    exception
        when insufficient_privilege then
            execute 'reset role';
            raise notice 'ARS-694 M-009 OK (заявки): authenticated отказано на уровне грантов СУБД';
        when others then
            v_err := sqlerrm;
            execute 'reset role';
            raise exception 'ARS-694 M-009 ПРОВАЛ: ожидался отказ прав, получено «%»', v_err;
    end;

    begin
        execute 'set local role authenticated';
        perform public.rpc_process_tsp_batch_reviews(1);
        execute 'reset role';
        raise exception 'ARS-694 M-009 ПРОВАЛ: authenticated исполнил глобальный вход партий';
    exception
        when insufficient_privilege then
            execute 'reset role';
            raise notice 'ARS-694 M-009 OK (партии): authenticated отказано на уровне грантов СУБД';
        when others then
            v_err := sqlerrm;
            execute 'reset role';
            raise exception 'ARS-694 M-009 ПРОВАЛ: ожидался отказ прав, получено «%»', v_err;
    end;

    -- M-009 · та же дверь с другой стороны: сами ХЕЛПЕРЫ. Именно они принимают
    -- p_org_ids => null («все организации»), и закрыты они только грантами. Прецедент
    -- ровно этого класса — 20260726120000_sec_revoke_leaked_helpers.sql: пять внутренних
    -- хелперов вызывались любым authenticated в обход guarded rpc_self_*. Без этих двух
    -- утверждений потеря revoke-строк не уронила бы ни одного прибора.
    begin
        execute 'set local role authenticated';
        perform public.fn_tsp_sweep_due_pools(null, 1);
        execute 'reset role';
        raise exception 'ARS-694 M-009 ПРОВАЛ: authenticated исполнил ХЕЛПЕР заявок с '
                        'охватом «все организации» — глобальный охват утёк мимо входа';
    exception
        when insufficient_privilege then
            execute 'reset role';
            raise notice 'ARS-694 M-009 OK (хелпер заявок): authenticated отказано';
        when others then
            v_err := sqlerrm;
            execute 'reset role';
            raise exception 'ARS-694 M-009 ПРОВАЛ: ожидался отказ прав на хелпере заявок, '
                            'получено «%»', v_err;
    end;

    begin
        execute 'set local role authenticated';
        perform public.fn_tsp_sweep_due_batches(null, 1);
        execute 'reset role';
        raise exception 'ARS-694 M-009 ПРОВАЛ: authenticated исполнил ХЕЛПЕР партий с '
                        'охватом «все организации»';
    exception
        when insufficient_privilege then
            execute 'reset role';
            raise notice 'ARS-694 M-009 OK (хелпер партий): authenticated отказано';
        when others then
            v_err := sqlerrm;
            execute 'reset role';
            raise exception 'ARS-694 M-009 ПРОВАЛ: ожидался отказ прав на хелпере партий, '
                            'получено «%»', v_err;
    end;

    raise notice 'ARS-694 ИТОГ: покрыты M-001 M-002 M-003 M-004 M-005 M-006 M-008 M-009 '
                 'M-010 M-011(структурно) M-012 M-013. НЕ покрыты и названы честно: '
                 'M-007 (нужны два соединения), M-011 (инъекция отказа), M-014/M-015 '
                 '(свойства инфраструктуры — прибор в миграции расписания).';
end;
$$;

rollback;
