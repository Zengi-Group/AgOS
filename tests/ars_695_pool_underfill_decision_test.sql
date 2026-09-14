-- ARS-695 / Выход из недобравшейся заявки — контракт точки выбора комбината.
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/ars_695_pool_underfill_decision_test.sql
-- Файл открывает свою транзакцию и заканчивается ROLLBACK: ни одной строки в базе не
-- остаётся. Сторож ниже роняет прогон ДО первой записи, если файл всё же исполняется
-- автокоммитом.
--
-- ⚠️ ЭТОТ ФАЙЛ НИ РАЗУ НЕ ПРОГОНЯЛСЯ. Он написан в сессии сборки, у которой не было
-- доступа к базе (ни staging, ни прод). Его ПЕРВЫЙ прогон и есть верификация слайса —
-- пока он не отработал зелёным, серверная половина матрицы ARS-695 считается НЕ
-- проверенной, а сам файл может содержать ошибки фикстур. Не выдавать его наличие за
-- пройденную проверку.
--
-- Предмет теста: supabase/migrations/20260914120000_ars_695_pool_underfill_decision.sql
-- (три self-serve RPC + шесть хелперов) и переписанный rpc_self_close_due_pools
-- (20260622120000_tsp_canonical_rebind.sql). Спек (G2 2026-09-14):
-- Docs/AGOS-TSP-PoolDecision-Underfill-ARS-695.md.
--
-- Фикстуры СВОИ ЦЕЛИКОМ: свой auth.users (public.users создаёт триггер
-- trg_on_auth_user_created), свои организации, регион, pool_requests/pools/pool_lines/
-- batches/batch_allocations/offers. Ни одной существующей строки как фикстуру не читает.
-- tsp_config НЕ правится: порог берётся из живой строки и фикстуры строятся ОТ него —
-- правка общей конфигурации даже под rollback влияла бы на параллельные сессии.
--
-- Покрытие матрицы (id названы в каждом утверждении — Matrix Test Audit сверяет ПО ID,
-- совпадение «по смыслу» считается непокрытым):
--   M-001 M-002 M-003 M-004 M-006 M-007 M-009 M-010 M-014
--   плюс FR-013 (revoke канонических RPC) и регресс-кейс ревью якоря 7:
--   партия, проданная кусками в ДВЕ заявки, не должна ронять accept_partial.
--   НЕ покрыты здесь: M-005 (путь полного набора — заморожен FR-001), M-008 (остаток на
--   рынке — проверяется вместе с UI), M-011 (гонка двух операторов — нужны два
--   соединения, а файл однопоточный), M-012 (смена строки tsp_config — см. выше, общая
--   конфигурация), M-013 (обрыв сети — фронтовой, закрыт
--   src/tests/mpk-pool-underfill-decision.browser.test.tsx).

\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-695_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    v_region        uuid := gen_random_uuid();
    v_org_mpk       uuid := gen_random_uuid();   -- оператор
    v_org_mpk_other uuid := gen_random_uuid();   -- чужая МПК (M-009)
    v_org_farm_a    uuid := gen_random_uuid();   -- поставщик, маршрут «партия»
    v_org_farm_b    uuid := gen_random_uuid();   -- поставщик, маршрут «кусок»

    v_auth_op       uuid := gen_random_uuid();
    v_user_op       uuid;
    v_sku_id        uuid;

    -- Порог берём из живого конфига и строим фикстуры ОТ него (P8: значение — данные).
    v_min           int;
    v_above         int;    -- голов «выше порога, ниже цели»
    v_below         int;    -- голов «ниже порога»
    v_target        int;    -- цель заявки — заведомо больше v_above

    v_window        int;    -- окно решения, часов

    -- по одной заявке на сценарий: pools.pool_request_id уникален (d02_tsp.sql:398)
    v_pr_m1   uuid := gen_random_uuid();  v_pool_m1   uuid := gen_random_uuid();
    v_pr_m2   uuid := gen_random_uuid();  v_pool_m2   uuid := gen_random_uuid();
    v_pr_m3   uuid := gen_random_uuid();  v_pool_m3   uuid := gen_random_uuid();
    v_pr_m4   uuid := gen_random_uuid();  v_pool_m4   uuid := gen_random_uuid();
    v_pr_m6   uuid := gen_random_uuid();  v_pool_m6   uuid := gen_random_uuid();
    v_pr_m7   uuid := gen_random_uuid();  v_pool_m7   uuid := gen_random_uuid();
    v_pr_m9   uuid := gen_random_uuid();  v_pool_m9   uuid := gen_random_uuid();
    v_pr_m10  uuid := gen_random_uuid();  v_pool_m10  uuid := gen_random_uuid();
    v_pr_m14  uuid := gen_random_uuid();  v_pool_m14  uuid := gen_random_uuid();
    v_pr_two  uuid := gen_random_uuid();  v_pool_two  uuid := gen_random_uuid();  -- регресс-кейс
    v_pr_two2 uuid := gen_random_uuid();  v_pool_two2 uuid := gen_random_uuid();  -- вторая заявка той же партии

    v_pl_m1   uuid := gen_random_uuid();
    v_pl_m2   uuid := gen_random_uuid();
    v_pl_m3   uuid := gen_random_uuid();
    v_pl_m6   uuid := gen_random_uuid();
    v_pl_m7   uuid := gen_random_uuid();
    v_pl_m9   uuid := gen_random_uuid();
    v_pl_m10  uuid := gen_random_uuid();
    v_pl_m14  uuid := gen_random_uuid();
    v_pl_two  uuid := gen_random_uuid();
    v_pl_two2 uuid := gen_random_uuid();

    v_b_m1    uuid := gen_random_uuid();   -- M-001: маршрут «кусок»
    v_b_m1b   uuid := gen_random_uuid();   -- M-001: маршрут «партия» — оба разом (FR-005)
    v_b_m2    uuid := gen_random_uuid();   -- M-002: маршрут «кусок»
    v_b_m2b   uuid := gen_random_uuid();   -- M-002: маршрут «партия»
    v_b_m3    uuid := gen_random_uuid();
    v_b_m6    uuid := gen_random_uuid();
    v_b_m7    uuid := gen_random_uuid();
    v_b_m7b   uuid := gen_random_uuid();
    v_b_m9    uuid := gen_random_uuid();
    v_b_m10   uuid := gen_random_uuid();
    v_b_m14   uuid := gen_random_uuid();
    v_b_two   uuid := gen_random_uuid();   -- партия, проданная кусками в ДВЕ заявки

    v_offer_same  uuid := gen_random_uuid();  -- оффер этой же МПК по возвращаемой партии
    v_offer_other uuid := gen_random_uuid();  -- оффер ДРУГОЙ МПК по той же партии

    v_res    jsonb;
    v_err    text;
    v_status text;
    v_int    int;
    v_ts     timestamptz;
begin
    -- ==================================================================================
    -- 1. Фикстуры: конфиг-производные величины, регион, оператор, организации, SKU.
    -- ==================================================================================
    v_min := public.fn_tsp_pool_min_heads();
    if v_min is null or v_min < 1 then
        raise exception 'ARS-695_TEST_SETUP: fn_tsp_pool_min_heads вернул % — фикстура недостоверна', v_min;
    end if;
    v_above  := v_min + 2;          -- заведомо >= порога
    v_below  := greatest(v_min - 1, 1);
    if v_below >= v_min then
        raise exception 'ARS-695_TEST_SETUP: порог % не оставляет значения «ниже порога» '
                        '(нужен min_pool_heads >= 2)', v_min;
    end if;
    v_target := v_above * 10;       -- цель заведомо не достигается

    select mpk_decision_window_hours into v_window
    from public.tsp_config where is_active = true limit 1;
    v_window := coalesce(v_window, 24);

    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-695-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-695 область', 'oblast');

    insert into auth.users (id) values (v_auth_op);
    select id into v_user_op from public.users where auth_id = v_auth_op;
    if v_user_op is null then
        raise exception 'ARS-695_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations
        (id, legal_name, legal_form, region_id, address_text, phone)
    values
        (v_org_mpk,       'QA ARS-695 МПК-оператор', 'too', v_region, 'г. QA, ул. 1', null),
        (v_org_mpk_other, 'QA ARS-695 МПК чужая',    'too', v_region, 'г. QA, ул. 2', null),
        (v_org_farm_a,    'QA ARS-695 КХ партия',    'kh',  v_region, 'г. QA, ул. 3', '+7 700 000 06 95'),
        (v_org_farm_b,    'QA ARS-695 КХ кусок',     'kh',  v_region, 'г. QA, ул. 4', '+7 700 000 06 96');

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk, 'mpk'), (v_org_mpk_other, 'mpk'),
           (v_org_farm_a, 'farm'), (v_org_farm_b, 'farm');

    insert into public.organization_members (organization_id, user_id, role, is_active)
    values (v_org_mpk, v_user_op, 'owner', true);

    select id into v_sku_id from public.tsp_skus limit 1;
    if v_sku_id is null then
        raise exception 'ARS-695_TEST_SETUP: в tsp_skus нет ни одной строки — фикстура недостоверна';
    end if;

    -- ==================================================================================
    -- 2. Заявки. target_month в ПРОШЛОМ там, где сценарий про истёкшее окно (M-003/4/14).
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values
        (v_pr_m1,   v_org_mpk,       v_target, date_trunc('month', now())::date,                      v_region, 'active'),
        (v_pr_m2,   v_org_mpk,       v_target, date_trunc('month', now())::date,                      v_region, 'active'),
        (v_pr_m3,   v_org_mpk,       v_target, (date_trunc('month', now()) - interval '2 month')::date, v_region, 'active'),
        (v_pr_m4,   v_org_mpk,       v_target, (date_trunc('month', now()) - interval '2 month')::date, v_region, 'active'),
        (v_pr_m6,   v_org_mpk,       v_target, date_trunc('month', now())::date,                      v_region, 'active'),
        (v_pr_m7,   v_org_mpk,       v_target, date_trunc('month', now())::date,                      v_region, 'active'),
        (v_pr_m9,   v_org_mpk_other, v_target, date_trunc('month', now())::date,                      v_region, 'active'),
        (v_pr_m10,  v_org_mpk,       v_target, date_trunc('month', now())::date,                      v_region, 'active'),
        (v_pr_m14,  v_org_mpk,       v_target, (date_trunc('month', now()) - interval '2 month')::date, v_region, 'active'),
        (v_pr_two,  v_org_mpk,       v_target, date_trunc('month', now())::date,                      v_region, 'active'),
        (v_pr_two2, v_org_mpk,       v_target, date_trunc('month', now())::date,                      v_region, 'active');

    insert into public.pools
        (id, pool_request_id, organization_id, target_heads, matched_heads, status,
         awaiting_decision_at)
    values
        (v_pool_m1,   v_pr_m1,   v_org_mpk,       v_target, v_above * 2, 'awaiting_mpk_decision', now()),
        (v_pool_m2,   v_pr_m2,   v_org_mpk,       v_target, v_above * 2, 'awaiting_mpk_decision', now()),
        (v_pool_m3,   v_pr_m3,   v_org_mpk,       v_target, v_below,     'filling',               null),
        (v_pool_m4,   v_pr_m4,   v_org_mpk,       v_target, 0,           'filling',               null),
        -- M-006: окно решения истекло (вход в точку выбора был раньше окна)
        (v_pool_m6,   v_pr_m6,   v_org_mpk,       v_target, v_above,     'awaiting_mpk_decision',
         now() - make_interval(hours => v_window + 1)),
        (v_pool_m7,   v_pr_m7,   v_org_mpk,       v_target, v_above * 2, 'awaiting_mpk_decision', now()),
        (v_pool_m9,   v_pr_m9,   v_org_mpk_other, v_target, v_above,     'awaiting_mpk_decision', now()),
        (v_pool_m10,  v_pr_m10,  v_org_mpk,       v_target, v_above,     'filling',               null),
        (v_pool_m14,  v_pr_m14,  v_org_mpk,       v_target, v_above,     'filling',               null),
        (v_pool_two,  v_pr_two,  v_org_mpk,       v_target, v_above,     'awaiting_mpk_decision', now()),
        (v_pool_two2, v_pr_two2, v_org_mpk,       v_target, v_above,     'filling',               null);

    insert into public.pool_lines (id, pool_id, tsp_sku_id, mpk_price_per_kg, current_heads)
    values
        (v_pl_m1,   v_pool_m1,   v_sku_id, 1300, v_above * 2),
        (v_pl_m2,   v_pool_m2,   v_sku_id, 1300, v_above * 2),
        (v_pl_m3,   v_pool_m3,   v_sku_id, 1300, v_below),
        (v_pl_m6,   v_pool_m6,   v_sku_id, 1300, v_above),
        (v_pl_m7,   v_pool_m7,   v_sku_id, 1300, v_above * 2),
        (v_pl_m9,   v_pool_m9,   v_sku_id, 1300, v_above),
        (v_pl_m10,  v_pool_m10,  v_sku_id, 1300, v_above),
        (v_pl_m14,  v_pool_m14,  v_sku_id, 1300, v_above),
        (v_pl_two,  v_pool_two,  v_sku_id, 1300, v_above),
        (v_pl_two2, v_pool_two2, v_sku_id, 1300, v_above);

    -- ==================================================================================
    -- 3. Партии. Маршрут «кусок» держит pool_line_id как его пишет живой аллокатор
    --    (первый кусок проставляет batches.pool_line_id, 20260702160000:203) — именно
    --    поэтому предикат маршрута «целиком» обязан смотреть на ОТСУТСТВИЕ аллокаций.
    -- ==================================================================================
    insert into public.batches
        (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month, region_id,
         status, pool_line_id, matched_heads, deal_price_per_kg)
    values
        (v_b_m1,   v_org_farm_b, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m1,   v_above, 1300),
        (v_b_m1b,  v_org_farm_a, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m1,   v_above, 1300),
        (v_b_m2,   v_org_farm_b, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m2,   v_above, 1300),
        (v_b_m2b,  v_org_farm_a, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m2,   v_above, 1300),
        (v_b_m3,   v_org_farm_b, v_sku_id, v_below, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m3,   v_below, 1300),
        (v_b_m6,   v_org_farm_b, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m6,   v_above, 1300),
        (v_b_m7,   v_org_farm_b, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m7,   v_above, 1300),
        (v_b_m7b,  v_org_farm_a, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m7,   v_above, 1300),
        (v_b_m9,   v_org_farm_b, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m9,   v_above, 1300),
        (v_b_m10,  v_org_farm_b, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m10,  v_above, 1300),
        (v_b_m14,  v_org_farm_b, v_sku_id, v_above, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_m14,  v_above, 1300),
        -- регресс-кейс: одна партия, два куска в РАЗНЫЕ заявки (2*v_above голов всего)
        (v_b_two,  v_org_farm_b, v_sku_id, v_above * 2, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl_two, v_above * 2, 1300);

    -- Куски: маршрут «кусок» у M-001/M-002/M-006/M-007/M-009/M-010/M-014 и регресс-кейса.
    -- Партии *_m1b / *_m2b / *_m7b аллокаций НЕ имеют — это маршрут «целиком».
    insert into public.batch_allocations (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values
        (v_b_m1,  v_pl_m1,  v_pool_m1,  v_above, 1300, 'matched'),
        (v_b_m2,  v_pl_m2,  v_pool_m2,  v_above, 1300, 'matched'),
        (v_b_m3,  v_pl_m3,  v_pool_m3,  v_below, 1300, 'matched'),
        (v_b_m6,  v_pl_m6,  v_pool_m6,  v_above, 1300, 'matched'),
        (v_b_m7,  v_pl_m7,  v_pool_m7,  v_above, 1300, 'matched'),
        (v_b_m9,  v_pl_m9,  v_pool_m9,  v_above, 1300, 'matched'),
        (v_b_m10, v_pl_m10, v_pool_m10, v_above, 1300, 'matched'),
        (v_b_m14, v_pl_m14, v_pool_m14, v_above, 1300, 'matched'),
        -- регресс: кусок в закрываемую заявку И кусок в ДРУГУЮ, ещё открытую
        (v_b_two, v_pl_two,  v_pool_two,  v_above, 1300, 'matched'),
        (v_b_two, v_pl_two2, v_pool_two2, v_above, 1300, 'matched');

    -- Офферы по возвращаемой партии M-002: один этой МПК, другой — чужой (FR-004).
    insert into public.offers (id, batch_id, mpk_org_id, offered_price_per_kg, status, expires_at)
    values
        (v_offer_same,  v_b_m2, v_org_mpk,       1300, 'pending', now() + interval '1 day'),
        (v_offer_other, v_b_m2, v_org_mpk_other, 1310, 'pending', now() + interval '1 day');

    -- ==================================================================================
    -- Вызовы от лица оператора комбината (член v_org_mpk, НЕ член v_org_mpk_other).
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_op::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    -- ==================================================================================
    -- M-001 — «принять частично»: оба маршрута → confirmed, target = набранному, контакты.
    -- ==================================================================================
    v_res := public.rpc_self_pool_accept_partial(v_pool_m1);
    if (v_res ->> 'outcome') <> 'closed_partial' then
        raise exception 'ARS-695 M-001: outcome=%, ожидалось closed_partial', v_res ->> 'outcome';
    end if;

    select status, target_heads, mpk_contact_revealed_at
      into v_status, v_int, v_ts
    from public.pools where id = v_pool_m1;
    if v_status <> 'closed_partial' then
        raise exception 'ARS-695 M-001: статус заявки %, ожидался closed_partial', v_status;
    end if;
    if v_int <> v_above * 2 then
        raise exception 'ARS-695 M-001: target_heads=% не приведён к набранному (%)', v_int, v_above * 2;
    end if;
    if v_ts is null then
        raise exception 'ARS-695 M-001: контакты не раскрыты (mpk_contact_revealed_at пуст)';
    end if;

    -- FR-005: ОБА маршрута. Кусок → confirmed, партия целиком → confirmed.
    select status into v_status from public.batch_allocations
    where batch_id = v_b_m1 and pool_id = v_pool_m1;
    if v_status <> 'confirmed' then
        raise exception 'ARS-695 M-001/FR-005: кусок остался % (маршрут «кусок» не подтверждён)', v_status;
    end if;
    select status into v_status from public.batches where id = v_b_m1b;
    if v_status <> 'confirmed' then
        raise exception 'ARS-695 M-001/FR-005: партия целиком осталась % (маршрут «целиком» не подтверждён)', v_status;
    end if;
    -- FR-011: у фермера появляется ход — партия обязана быть confirmed и по маршруту «кусок».
    select status into v_status from public.batches where id = v_b_m1;
    if v_status <> 'confirmed' then
        raise exception 'ARS-695 M-001/FR-011: партия маршрута «кусок» осталась % — '
                        'rollup не довёл её до confirmed, кнопки отгрузки у фермера не будет', v_status;
    end if;
    -- FR-022: событие закрытия записано и уехало в аудит.
    if not exists (
        select 1 from public.platform_events
        where event_type = 'market.pool.closed_partial' and entity_id = v_pool_m1 and is_audit
    ) then
        raise exception 'ARS-695 M-001/FR-022: market.pool.closed_partial не записан (или is_audit=false)';
    end if;
    if not exists (
        select 1 from public.platform_events
        where event_type = 'market.batch.confirmed' and entity_id = v_b_m1b
    ) then
        raise exception 'ARS-695 M-001/FR-022: market.batch.confirmed не записан по маршруту «целиком»';
    end if;

    -- ==================================================================================
    -- M-002 — «вернуть партии»: оба маршрута на рынок, счётчики вниз, офферы избирательно.
    -- ==================================================================================
    v_res := public.rpc_self_pool_return_batches(v_pool_m2);
    if (v_res ->> 'outcome') <> 'closed_unfilled' then
        raise exception 'ARS-695 M-002: outcome=%, ожидалось closed_unfilled', v_res ->> 'outcome';
    end if;

    select status, matched_heads into v_status, v_int from public.pools where id = v_pool_m2;
    if v_status <> 'closed_unfilled' then
        raise exception 'ARS-695 M-002: статус заявки %, ожидался closed_unfilled', v_status;
    end if;
    if v_int <> 0 then
        raise exception 'ARS-695 M-002/FR-004: matched_heads=% — счётчик заявки не уменьшен на возвращённое', v_int;
    end if;
    select current_heads into v_int from public.pool_lines where id = v_pl_m2;
    if v_int <> 0 then
        raise exception 'ARS-695 M-002/FR-004: pool_lines.current_heads=% — счётчик строки не уменьшен', v_int;
    end if;

    select status, deal_price_per_kg into v_status, v_int from public.batches where id = v_b_m2;
    if v_status <> 'published' or v_int is not null then
        raise exception 'ARS-695 M-002/FR-005: партия маршрута «кусок» — статус %, deal % '
                        '(ожидалось published / NULL)', v_status, v_int;
    end if;
    select status, deal_price_per_kg into v_status, v_int from public.batches where id = v_b_m2b;
    if v_status <> 'published' or v_int is not null then
        raise exception 'ARS-695 M-002/FR-005: партия маршрута «целиком» — статус %, deal % '
                        '(ожидалось published / NULL)', v_status, v_int;
    end if;
    select status into v_status from public.batch_allocations
    where batch_id = v_b_m2 and pool_id = v_pool_m2;
    if v_status <> 'cancelled' then
        raise exception 'ARS-695 M-002: кусок остался % (ожидался cancelled)', v_status;
    end if;

    -- FR-004: гасится оффер ЭТОЙ МПК, оффер чужой — цел.
    select status into v_status from public.offers where id = v_offer_same;
    if v_status <> 'withdrawn' then
        raise exception 'ARS-695 M-002/FR-004: pending-оффер этой заявки остался % (ожидался withdrawn)', v_status;
    end if;
    select status into v_status from public.offers where id = v_offer_other;
    if v_status <> 'pending' then
        raise exception 'ARS-695 M-002/FR-004: оффер ДРУГОГО комбината стал % — чужая сделка не должна '
                        'закрываться вместе с этой заявкой', v_status;
    end if;
    if not exists (
        select 1 from public.platform_events
        where event_type = 'market.offer.withdrawn' and entity_id = v_offer_same
    ) then
        raise exception 'ARS-695 M-002: market.offer.withdrawn не эмитирован (Dok 4 §3.3a, reason=pool_returned)';
    end if;

    -- ==================================================================================
    -- M-003 — ниже порога: выбора нет, подметание возвращает партии автоматом.
    -- M-004 — пусто: expired_empty.
    -- M-014 — окно истекло, набрано >= порога: точка выбора + отметка времени.
    -- M-006 — молчание дольше окна решения: дефолт «вернуть».
    -- Все четыре исполняет ОДИН вызов подметания (FR-006/FR-007/M-014).
    -- ==================================================================================
    v_res := public.rpc_self_close_due_pools();

    select status, matched_heads into v_status, v_int from public.pools where id = v_pool_m3;
    if v_status <> 'closed_unfilled' then
        raise exception 'ARS-695 M-003: заявка ниже порога (% гол. при пороге %) получила статус %, '
                        'ожидался closed_unfilled без решения МПК', v_below, v_min, v_status;
    end if;
    select status into v_status from public.batches where id = v_b_m3;
    if v_status <> 'published' then
        raise exception 'ARS-695 M-003: партия ниже порога осталась % — не возвращена на рынок', v_status;
    end if;

    select status into v_status from public.pools where id = v_pool_m4;
    if v_status <> 'expired_empty' then
        raise exception 'ARS-695 M-004: пустая заявка получила %, ожидался expired_empty', v_status;
    end if;

    select status, awaiting_decision_at into v_status, v_ts from public.pools where id = v_pool_m14;
    if v_status <> 'awaiting_mpk_decision' then
        raise exception 'ARS-695 M-014: заявка % (>= порога, окно истекло) не ушла в точку выбора', v_status;
    end if;
    if v_ts is null then
        raise exception 'ARS-695 M-014/FR-012: awaiting_decision_at пуст — окно решения не с чего считать';
    end if;

    select status into v_status from public.pools where id = v_pool_m6;
    if v_status <> 'closed_unfilled' then
        raise exception 'ARS-695 M-006/FR-007: молчание дольше % ч дало статус %, ожидался '
                        'closed_unfilled (дефолт «вернуть»)', v_window, v_status;
    end if;
    select status into v_status from public.batches where id = v_b_m6;
    if v_status <> 'published' then
        raise exception 'ARS-695 M-006: партия после дефолтного возврата осталась %', v_status;
    end if;

    -- Возвращаемая форма расширена аддитивно (D-RPC-CONTRACT-SYNC-01).
    if not (v_res ? 'filled' and v_res ? 'closed' and v_res ? 'awaitingDecision'
            and v_res ? 'unfilled' and v_res ? 'expiredEmpty') then
        raise exception 'ARS-695: форма ответа rpc_self_close_due_pools сузилась: %', v_res;
    end if;

    -- ==================================================================================
    -- M-007 — смешанная заявка: оба маршрута подтверждены, ни одной партии в matched.
    -- ==================================================================================
    v_res := public.rpc_self_pool_accept_partial(v_pool_m7);
    select count(*) into v_int
    from public.batches b
    where b.status = 'matched'
      and (exists (select 1 from public.batch_allocations a
                    where a.batch_id = b.id and a.pool_id = v_pool_m7 and a.status = 'matched')
           or (b.pool_line_id = v_pl_m7
               and not exists (select 1 from public.batch_allocations a where a.batch_id = b.id)));
    if v_int <> 0 then
        raise exception 'ARS-695 M-007: % партий смешанной заявки остались matched', v_int;
    end if;

    -- ==================================================================================
    -- Регресс ревью якоря 7 — партия, проданная кусками в ДВЕ заявки. Страж M-007 не
    -- должен принимать законно-matched партию (её держит кусок другой открытой заявки)
    -- за нераспознанный маршрут, иначе accept_partial по такой заявке не пройдёт НИКОГДА.
    -- ==================================================================================
    begin
        v_res := public.rpc_self_pool_accept_partial(v_pool_two);
    exception when others then
        raise exception 'ARS-695 регресс (партия в двух заявках): accept_partial упал (%) — '
                        'страж принял законно-matched партию за нераспознанный маршрут', sqlerrm;
    end;
    if (v_res ->> 'outcome') <> 'closed_partial' then
        raise exception 'ARS-695 регресс: outcome=%, ожидалось closed_partial', v_res ->> 'outcome';
    end if;
    select status into v_status from public.batch_allocations
    where batch_id = v_b_two and pool_id = v_pool_two;
    if v_status <> 'confirmed' then
        raise exception 'ARS-695 регресс: кусок закрываемой заявки остался %', v_status;
    end if;
    select status into v_status from public.batch_allocations
    where batch_id = v_b_two and pool_id = v_pool_two2;
    if v_status <> 'matched' then
        raise exception 'ARS-695 регресс: кусок ДРУГОЙ, ещё открытой заявки стал % — '
                        'закрытие этой заявки не должно трогать чужую сделку', v_status;
    end if;

    -- ==================================================================================
    -- M-009 — чужая заявка: FORBIDDEN, ничего не изменено.
    -- ==================================================================================
    begin
        v_res := public.rpc_self_pool_accept_partial(v_pool_m9);
        v_err := null;
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err is null or v_err not like 'FORBIDDEN%' then
        raise exception 'ARS-695 M-009: чужая заявка не дала FORBIDDEN (sqlerrm=%)', v_err;
    end if;
    select status into v_status from public.pools where id = v_pool_m9;
    if v_status <> 'awaiting_mpk_decision' then
        raise exception 'ARS-695 M-009: статус чужой заявки изменён на %', v_status;
    end if;

    -- ==================================================================================
    -- M-010 — неверное состояние: решение по заявке в filling → INVALID_STATUS.
    -- ==================================================================================
    begin
        v_res := public.rpc_self_pool_accept_partial(v_pool_m10);
        v_err := null;
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err is null or v_err not like 'INVALID_STATUS%' then
        raise exception 'ARS-695 M-010: решение по filling-заявке не дало INVALID_STATUS (sqlerrm=%)', v_err;
    end if;
    select status into v_status from public.pools where id = v_pool_m10;
    if v_status <> 'filling' then
        raise exception 'ARS-695 M-010: статус заявки изменён на % при отказе', v_status;
    end if;

    -- ==================================================================================
    -- FR-013 — канонические RPC выведены из рабочего пути: execute отозван.
    -- ==================================================================================
    if has_function_privilege('authenticated', 'public.rpc_pool_accept_partial(uuid,uuid)', 'execute') then
        raise exception 'ARS-695 FR-013: rpc_pool_accept_partial всё ещё исполнима ролью authenticated';
    end if;
    if has_function_privilege('authenticated', 'public.rpc_pool_return_batches(uuid,uuid)', 'execute') then
        raise exception 'ARS-695 FR-013: rpc_pool_return_batches всё ещё исполнима ролью authenticated';
    end if;

    execute 'reset role';
    perform set_config('request.jwt.claims', '{}', true);

    raise notice 'ARS-695 / Underfill decision: контракт пройден. Закрыты M-001 M-002 M-003 '
                 'M-004 M-006 M-007 M-009 M-010 M-014, FR-004 FR-005 FR-011 FR-012 FR-013 FR-022 '
                 '+ регресс «партия в двух заявках».';
end;
$$;

rollback;
