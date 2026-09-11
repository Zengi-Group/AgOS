-- ARS-684 / Pool Monitor — регрессионный контракт двухмаршрутной read-model
-- rpc_get_pool_matches(uuid).
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/ars_684_pool_monitor_dual_route_test.sql
-- Файл открывает свою транзакцию и заканчивается ROLLBACK: ни одной строки в базе не
-- остаётся. Сторож ниже роняет прогон ДО первой записи, если файл всё же исполняется
-- автокоммитом.
--
-- Предмет теста: supabase/migrations/20260910120000_ars_684_pool_matches_dual_route.sql
-- (действующее определение rpc_get_pool_matches, 203 строки). Спек (подписан G2
-- 2026-09-10): Docs/AGOS-TSP-PoolMonitor-ReadModel-ARS-684.md.
--
-- Фикстуры СВОИ ЦЕЛИКОМ: тест создаёт своего auth.users (public.users делает триггер
-- trg_on_auth_user_created), свои организации, свой регион, свои pool_requests/pools/
-- pool_lines/batches/batch_allocations/deal_reviews и ВЫДАЁТ права себе. Ни одной
-- существующей строки он не читает как фикстуру и не меняет.
--
-- Покрытие матрицы (id названы в каждом утверждении — Matrix Test Audit сверяет ПО ID,
-- совпадение «по смыслу» считается непокрытым):
--   M-001 M-002 M-003 M-004 M-005 M-009 M-014
--   плюс FR-008 (контракт формы ответа — 18 ключей строки, ровно, + сохранность
--   myRating на ОБОИХ маршрутах). Спек называет FR-008 «проверяется SQL-тестом, а не
--   CHECK 11»: снапшот contracts/rpc_return_keys.txt собирается только по SQL_FILES из
--   cross_check.sh, куда не входит эта миграция — то есть CHECK 11 форму этой функции
--   не проверяет. Этот файл — единственное место, что её фиксирует.
--   Остальные строки спековой матрицы (M-006..M-008, M-010..M-013, M-015..M-018)
--   принадлежат UI/приёмке/офлайн-поведению — вне периметра SQL-теста, закрываются
--   `npm run test:routers` и сценариями qa/scenarios/ TSPM (см. §Verification спека).

\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-684_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    -- регион и организации
    v_region            uuid := gen_random_uuid();
    v_org_mpk           uuid := gen_random_uuid();   -- оператор: МПК, владелец пулов M-001..M-005,014
    v_org_mpk_other     uuid := gen_random_uuid();   -- чужая МПК — владелец пула M-009
    v_org_farm_a        uuid := gen_random_uuid();   -- поставщик, маршрут «партия» (pool_line_id)
    v_org_farm_b        uuid := gen_random_uuid();   -- поставщик, маршрут «кусок» (batch_allocations)

    -- пользователь-оператор комбината
    v_auth_op           uuid := gen_random_uuid();
    v_user_op           uuid;

    -- справочник (read-only, не наша фикстура — только SELECT)
    v_sku_id            uuid;

    -- пулы + их заявки + строки. По одному пулу на сценарий: pools.pool_request_id
    -- уникален (d02_tsp.sql:398) — одну pool_requests нельзя переиспользовать между пулами.
    v_pr_m1             uuid := gen_random_uuid();
    v_pr_m2             uuid := gen_random_uuid();
    v_pr_m3             uuid := gen_random_uuid();
    v_pr_m3b            uuid := gen_random_uuid();
    v_pr_m4             uuid := gen_random_uuid();
    v_pr_m5             uuid := gen_random_uuid();
    v_pr_m14            uuid := gen_random_uuid();
    v_pr_m9             uuid := gen_random_uuid();

    v_pool_m1           uuid := gen_random_uuid();   -- M-001: happy path, маршрут «партия»
    v_pool_m2           uuid := gen_random_uuid();   -- M-002: happy path, маршрут «кусок»
    v_pool_m3           uuid := gen_random_uuid();   -- M-003: смешанный, 2 партии, без дублей
    v_pool_m3b          uuid := gen_random_uuid();   -- M-003 (доп.): 1 партия — ОБА маршрута разом
    v_pool_m4           uuid := gen_random_uuid();   -- M-004: до раскрытия контактов
    v_pool_m5           uuid := gen_random_uuid();   -- M-005: пусто
    v_pool_m14          uuid := gen_random_uuid();   -- M-014: снятые партия и кусок
    v_pool_m9           uuid := gen_random_uuid();   -- M-009: чужой пул (FORBIDDEN)

    v_pl_m1             uuid := gen_random_uuid();
    v_pl_m2             uuid := gen_random_uuid();
    v_pl_m3             uuid := gen_random_uuid();
    v_pl_m3b            uuid := gen_random_uuid();
    v_pl_m4             uuid := gen_random_uuid();
    v_pl_m14            uuid := gen_random_uuid();

    -- батчи (партии)
    v_batch_m1          uuid := gen_random_uuid();   -- M-001: маршрут «партия» (pool_line_id)
    v_batch_m2          uuid := gen_random_uuid();   -- M-002: маршрут «кусок» (batch_allocations)
    v_batch_m3_e        uuid := gen_random_uuid();   -- M-003: маршрут «кусок»
    v_batch_m3_f        uuid := gen_random_uuid();   -- M-003: маршрут «партия»
    v_batch_m3b_g       uuid := gen_random_uuid();   -- M-003 (доп.): ОБА маршрута разом
    v_batch_m4_alloc    uuid := gen_random_uuid();   -- M-004: маршрут «кусок», до раскрытия
    v_batch_m4_batch    uuid := gen_random_uuid();   -- M-004: маршрут «партия», до раскрытия
    v_batch_m14_h       uuid := gen_random_uuid();   -- M-014: партия cancelled (маршрут «партия»)
    v_batch_m14_i       uuid := gen_random_uuid();   -- M-014: кусок cancelled (маршрут «кусок»)

    v_alloc_m2          uuid;   -- id строки batch_allocations M-002 — matchId ОБЯЗАН = ей

    -- рабочие переменные
    v_res               jsonb;
    v_row               jsonb;
    v_err               text;
    v_count             int;
    v_expected_keys     text[] := array[
        'matchId','batchId','source','cat','grade','breed','heads','avgWeight','price',
        'region','status','matchedAt','confirmedAt','dispatchedAt','deliveredAt',
        'farmName','farmPhone','myRating'
    ];
    v_extra             text[];
    v_missing           text[];
begin
    -- ==================================================================================
    -- 1. Фикстуры: регион, оператор, организации, справочник SKU.
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-684-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-684 область', 'oblast');

    insert into auth.users (id) values (v_auth_op);
    select id into v_user_op from public.users where auth_id = v_auth_op;
    if v_user_op is null then
        raise exception 'ARS-684_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations
        (id, legal_name, legal_form, region_id, address_text, phone)
    values
        (v_org_mpk,       'QA ARS-684 МПК-оператор',      'too', v_region, 'г. QA, ул. 1', null),
        (v_org_mpk_other, 'QA ARS-684 МПК чужая',         'too', v_region, 'г. QA, ул. 2', null),
        (v_org_farm_a,    'QA ARS-684 КХ маршрут-партия', 'kh',  v_region, 'г. QA, ул. 3', '+7 700 000 00 03'),
        (v_org_farm_b,    'QA ARS-684 КХ маршрут-кусок',  'kh',  v_region, 'г. QA, ул. 4', '+7 700 000 00 04');

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk, 'mpk'), (v_org_mpk_other, 'mpk'),
           (v_org_farm_a, 'farmer'), (v_org_farm_b, 'farmer');

    -- fn_my_org_ids() (d07_ai_gateway.sql:2257, действующее переопределение — L-1)
    -- медленным путём читает ИМЕННО user_organization_roles.
    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values (v_user_op, v_org_mpk, 'procurement', true);

    select id into v_sku_id from public.tsp_skus order by sku_code limit 1;
    if v_sku_id is null then
        raise exception 'ARS-684_TEST_SETUP: в tsp_skus нет ни одной строки — фикстура недостоверна';
    end if;

    -- ==================================================================================
    -- 2. Пулы. Владение rpc_get_pool_matches проверяет ЧЕРЕЗ pool_requests.organization_id
    --    (не через pools.organization_id — см. миграцию :63-66), поэтому КАЖДЫЙ пул
    --    обязан висеть на pool_requests нужной организации.
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values
        (v_pr_m1,  v_org_mpk,       50, date_trunc('month', now())::date, v_region, 'active'),
        (v_pr_m2,  v_org_mpk,       50, date_trunc('month', now())::date, v_region, 'active'),
        (v_pr_m3,  v_org_mpk,       50, date_trunc('month', now())::date, v_region, 'active'),
        (v_pr_m3b, v_org_mpk,       50, date_trunc('month', now())::date, v_region, 'active'),
        (v_pr_m4,  v_org_mpk,       50, date_trunc('month', now())::date, v_region, 'active'),
        (v_pr_m5,  v_org_mpk,       50, date_trunc('month', now())::date, v_region, 'active'),
        (v_pr_m14, v_org_mpk,       50, date_trunc('month', now())::date, v_region, 'active'),
        (v_pr_m9,  v_org_mpk_other, 50, date_trunc('month', now())::date, v_region, 'active');

    insert into public.pools
        (id, pool_request_id, organization_id, target_heads, status, mpk_contact_revealed_at)
    values
        (v_pool_m1,  v_pr_m1,  v_org_mpk,       50, 'closed_filled', now() - interval '1 day'),
        (v_pool_m2,  v_pr_m2,  v_org_mpk,       50, 'closed_filled', now() - interval '1 day'),
        (v_pool_m3,  v_pr_m3,  v_org_mpk,       50, 'closed_filled', now() - interval '1 day'),
        (v_pool_m3b, v_pr_m3b, v_org_mpk,       50, 'closed_filled', now() - interval '1 day'),
        (v_pool_m4,  v_pr_m4,  v_org_mpk,       50, 'filling',       null),
        (v_pool_m5,  v_pr_m5,  v_org_mpk,       50, 'filling',       null),
        (v_pool_m14, v_pr_m14, v_org_mpk,       50, 'closed_filled', now() - interval '1 day'),
        (v_pool_m9,  v_pr_m9,  v_org_mpk_other, 50, 'closed_filled', now() - interval '1 day');

    -- pool_lines: одна строка на пул. Обслуживает и маршрут «партия» (batches.pool_line_id
    -- целится сюда) и маршрут «кусок» (batch_allocations.pool_line_id — NOT NULL FK, целится
    -- сюда же; сама read-model это поле в ответе не использует, см. миграцию :74-119).
    insert into public.pool_lines (id, pool_id, tsp_sku_id, mpk_price_per_kg)
    values
        (v_pl_m1,  v_pool_m1,  v_sku_id, 1300),
        (v_pl_m2,  v_pool_m2,  v_sku_id, 1300),
        (v_pl_m3,  v_pool_m3,  v_sku_id, 1300),
        (v_pl_m3b, v_pool_m3b, v_sku_id, 1300),
        (v_pl_m4,  v_pool_m4,  v_sku_id, 1300),
        (v_pl_m14, v_pool_m14, v_sku_id, 1300);

    -- ==================================================================================
    -- 3. Батчи. pool_line_id проставлен ТОЛЬКО у маршрута «партия» (Route 2 требует
    --    b.pool_line_id -> pool_lines.pool_id = p_pool_id); маршрут «кусок» держит его
    --    null — правду о принадлежности несёт исключительно batch_allocations.
    -- ==================================================================================
    insert into public.batches
        (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month, region_id,
         status, pool_line_id)
    values
        (v_batch_m1,       v_org_farm_a, v_sku_id, 20, 380.00,
         date_trunc('month', now())::date, v_region, 'confirmed', v_pl_m1),
        (v_batch_m2,       v_org_farm_b, v_sku_id, 15, 390.00,
         date_trunc('month', now())::date, v_region, 'matched',   null),
        (v_batch_m3_e,     v_org_farm_b, v_sku_id, 12, 400.00,
         date_trunc('month', now())::date, v_region, 'matched',   null),
        (v_batch_m3_f,     v_org_farm_a, v_sku_id, 18, 410.00,
         date_trunc('month', now())::date, v_region, 'confirmed', v_pl_m3),
        (v_batch_m3b_g,    v_org_farm_b, v_sku_id, 22, 405.00,
         date_trunc('month', now())::date, v_region, 'confirmed', v_pl_m3b),
        (v_batch_m4_alloc, v_org_farm_b, v_sku_id, 14, 395.00,
         date_trunc('month', now())::date, v_region, 'matched',   null),
        (v_batch_m4_batch, v_org_farm_a, v_sku_id, 16, 385.00,
         date_trunc('month', now())::date, v_region, 'matched',   v_pl_m4),
        (v_batch_m14_h,    v_org_farm_a, v_sku_id, 10, 370.00,
         date_trunc('month', now())::date, v_region, 'cancelled', v_pl_m14),
        -- M-014, маршрут «кусок»: pool_line_id указывает В ЭТОТ пул — это РЕАЛЬНАЯ форма
        -- записи, а не удобная. fn_tsp_alloc_chunk пишет batches.pool_line_id по ПЕРВОМУ
        -- куску (20260702160000:203), а rollup при отмене всех кусков выходит раньше
        -- («нет активных кусков — оставляем как есть», 20260702190000:78) и НЕ очищает его.
        -- С pool_line_id = null строка отсеивалась бы внутренним join'ом ещё до guard'а,
        -- и защита от снятого куска на маршруте «партия» не проверялась бы вовсе.
        (v_batch_m14_i,    v_org_farm_b, v_sku_id, 11, 375.00,
         date_trunc('month', now())::date, v_region, 'matched',   v_pl_m14);

    -- batch_allocations: маршрут «кусок». M-002 — отдельным INSERT ... RETURNING, чтобы
    -- захватить id распределения и сверить его с matchId (не должен совпасть с batchId).
    insert into public.batch_allocations
        (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values
        (v_batch_m2, v_pl_m2, v_pool_m2, 15, 1370, 'confirmed')
    returning id into v_alloc_m2;

    insert into public.batch_allocations
        (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values
        (v_batch_m3_e,     v_pl_m3,  v_pool_m3,  12, 1350, 'confirmed'),
        (v_batch_m3b_g,    v_pl_m3b, v_pool_m3b, 22, 1360, 'confirmed'),
        (v_batch_m4_alloc, v_pl_m4,  v_pool_m4,  14, 1340, 'matched'),
        (v_batch_m14_i,    v_pl_m14, v_pool_m14, 11, 1300, 'cancelled');

    -- deal_reviews: канонический отзыв МПК-вызывателя (reviewer_org_id = pool_requests
    -- .organization_id) по каждому из двух happy-path батчей — FR-008 / myRating,
    -- на обоих маршрутах, с РАЗНЫМИ оценками, чтобы нельзя было пройти совпадением.
    insert into public.deal_reviews (batch_id, reviewer_org_id, reviewer_role, overall_score, comment)
    values
        (v_batch_m1, v_org_mpk, 'mpk', 4, 'ARS-684 QA canonical score, route=batch'),
        (v_batch_m2, v_org_mpk, 'mpk', 5, 'ARS-684 QA canonical score, route=allocation');

    -- ==================================================================================
    -- Вызовы от лица оператора комбината (член v_org_mpk, НЕ член v_org_mpk_other).
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_op::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    -- ==================================================================================
    -- M-001 — happy path · автоматч: пул closed_filled, раскрыт, партия только через
    -- pool_line_id, распределений нет.
    -- ==================================================================================
    v_res := public.rpc_get_pool_matches(v_pool_m1);
    if jsonb_array_length(v_res) <> 1 then
        raise exception 'ARS-684 M-001: ожидалась ровно 1 строка (маршрут «партия», '
                        'распределений нет), получено %', jsonb_array_length(v_res);
    end if;
    select e.value into v_row
    from jsonb_array_elements(v_res) e
    where e.value ->> 'batchId' = v_batch_m1::text;
    if v_row is null then
        raise exception 'ARS-684 M-001: строки по batchId=% нет в ответе', v_batch_m1;
    end if;
    if (v_row ->> 'source') <> 'batch' then
        raise exception 'ARS-684 M-001: source=%, ожидалось batch', v_row ->> 'source';
    end if;
    if (v_row ->> 'farmName') <> 'QA ARS-684 КХ маршрут-партия' then
        raise exception 'ARS-684 M-001: farmName=%, ожидалось имя хозяйства-поставщика',
            v_row ->> 'farmName';
    end if;
    if (v_row ->> 'farmPhone') is null then
        raise exception 'ARS-684 M-001: farmPhone пуст при раскрытых контактах пула';
    end if;

    -- FR-008: набор ключей строки — РОВНО ожидаемый (18), без лишних и без пропавших.
    -- Сравнение через EXCEPT — независимо от коллации/порядка (никакой сортировки).
    select array(select jsonb_object_keys(v_row) except select unnest(v_expected_keys))
      into v_extra;
    select array(select unnest(v_expected_keys) except select jsonb_object_keys(v_row))
      into v_missing;
    if array_length(v_extra, 1) is not null or array_length(v_missing, 1) is not null then
        raise exception 'ARS-684 FR-008: набор ключей строки (маршрут batch) разошёлся — '
                        'лишние=%, отсутствующие=%', v_extra, v_missing;
    end if;
    -- FR-008 / myRating: канонический отзыв МПК-вызывателя обязан прийти в myRating —
    -- работает как раньше (ARS-360 / ADR-353), теперь и на маршруте «партия».
    if (v_row ->> 'myRating')::int <> 4 then
        raise exception 'ARS-684 FR-008: myRating (маршрут batch) = %, ожидалось 4 '
                        '(канонический deal_reviews)', v_row ->> 'myRating';
    end if;

    -- ==================================================================================
    -- M-002 — happy path · ручной матч: партия продана куском (batch_allocations).
    -- ==================================================================================
    v_res := public.rpc_get_pool_matches(v_pool_m2);
    if jsonb_array_length(v_res) <> 1 then
        raise exception 'ARS-684 M-002: ожидалась ровно 1 строка, получено %',
            jsonb_array_length(v_res);
    end if;
    select e.value into v_row
    from jsonb_array_elements(v_res) e
    where e.value ->> 'batchId' = v_batch_m2::text;
    if v_row is null then
        raise exception 'ARS-684 M-002: строки по batchId=% нет в ответе', v_batch_m2;
    end if;
    if (v_row ->> 'source') <> 'allocation' then
        raise exception 'ARS-684 M-002: source=%, ожидалось allocation', v_row ->> 'source';
    end if;
    if (v_row ->> 'matchId') <> v_alloc_m2::text then
        raise exception 'ARS-684 M-002: matchId=% — ожидался id распределения (%), НЕ id партии '
                        '(приёмка по кускам не должна сломаться)', v_row ->> 'matchId', v_alloc_m2;
    end if;

    -- FR-008 на втором маршруте — тот же контракт формы и myRating.
    select array(select jsonb_object_keys(v_row) except select unnest(v_expected_keys))
      into v_extra;
    select array(select unnest(v_expected_keys) except select jsonb_object_keys(v_row))
      into v_missing;
    if array_length(v_extra, 1) is not null or array_length(v_missing, 1) is not null then
        raise exception 'ARS-684 FR-008: набор ключей строки (маршрут allocation) разошёлся — '
                        'лишние=%, отсутствующие=%', v_extra, v_missing;
    end if;
    if (v_row ->> 'myRating')::int <> 5 then
        raise exception 'ARS-684 FR-008: myRating (маршрут allocation) = %, ожидалось 5 '
                        '(канонический deal_reviews)', v_row ->> 'myRating';
    end if;

    -- ==================================================================================
    -- M-003 — смешанный пул: партия E через распределение, партия F через pool_line_id.
    -- Ровно 2 строки, у каждой свой маршрут, дублей нет (каждая партия ровно один раз).
    -- ==================================================================================
    v_res := public.rpc_get_pool_matches(v_pool_m3);
    if jsonb_array_length(v_res) <> 2 then
        raise exception 'ARS-684 M-003: смешанный пул дал % строк(и), ожидалось 2',
            jsonb_array_length(v_res);
    end if;

    select count(*) into v_count
    from jsonb_array_elements(v_res) e
    where e.value ->> 'batchId' = v_batch_m3_e::text and e.value ->> 'source' = 'allocation';
    if v_count <> 1 then
        raise exception 'ARS-684 M-003: партия маршрута allocation (%) встречена % раз(а) '
                        'с верным source, ожидался ровно 1', v_batch_m3_e, v_count;
    end if;

    select count(*) into v_count
    from jsonb_array_elements(v_res) e
    where e.value ->> 'batchId' = v_batch_m3_f::text and e.value ->> 'source' = 'batch';
    if v_count <> 1 then
        raise exception 'ARS-684 M-003: партия маршрута batch (%) встречена % раз(а) '
                        'с верным source, ожидался ровно 1', v_batch_m3_f, v_count;
    end if;

    -- Отдельно: партия, у которой ЕСТЬ распределение в этом пуле И pool_line_id в этот же
    -- пул, обязана дать РОВНО одну строку — авторитет распределений (P2), без дублей.
    v_res := public.rpc_get_pool_matches(v_pool_m3b);
    if jsonb_array_length(v_res) <> 1 then
        raise exception 'ARS-684 M-003: партия с обоими признаками маршрута дала % строк(и), '
                        'ожидалась ровно 1 (без дублей)', jsonb_array_length(v_res);
    end if;
    select e.value into v_row
    from jsonb_array_elements(v_res) e
    where e.value ->> 'batchId' = v_batch_m3b_g::text;
    if v_row is null or (v_row ->> 'source') <> 'allocation' then
        raise exception 'ARS-684 M-003: партия с обоими признаками маршрута дала source=%, '
                        'ожидался allocation (авторитет распределений, P2)', v_row ->> 'source';
    end if;

    -- ==================================================================================
    -- M-004 — до раскрытия контактов: строки видны на ОБОИХ маршрутах, хозяйство анонимно.
    -- ==================================================================================
    v_res := public.rpc_get_pool_matches(v_pool_m4);
    if jsonb_array_length(v_res) <> 2 then
        raise exception 'ARS-684 M-004: до раскрытия ожидались обе строки (2), получено %',
            jsonb_array_length(v_res);
    end if;

    select e.value into v_row
    from jsonb_array_elements(v_res) e
    where e.value ->> 'batchId' = v_batch_m4_alloc::text;
    if v_row is null then
        raise exception 'ARS-684 M-004: маршрут allocation не виден до раскрытия — строки нет';
    end if;
    if (v_row ->> 'farmName') is not null or (v_row ->> 'farmPhone') is not null then
        raise exception 'ARS-684 M-004: маршрут allocation до раскрытия отдал имя/телефон '
                        '(farmName=%, farmPhone=%) — гейт ст.171 ЗК РК пробит',
            v_row ->> 'farmName', v_row ->> 'farmPhone';
    end if;

    select e.value into v_row
    from jsonb_array_elements(v_res) e
    where e.value ->> 'batchId' = v_batch_m4_batch::text;
    if v_row is null then
        raise exception 'ARS-684 M-004: маршрут batch не виден до раскрытия — строки нет';
    end if;
    if (v_row ->> 'farmName') is not null or (v_row ->> 'farmPhone') is not null then
        raise exception 'ARS-684 M-004: маршрут batch до раскрытия отдал имя/телефон '
                        '(farmName=%, farmPhone=%) — гейт ст.171 ЗК РК пробит',
            v_row ->> 'farmName', v_row ->> 'farmPhone';
    end if;

    -- ==================================================================================
    -- M-005 — пул без единой набранной партии: пустой массив, НЕ null.
    -- ==================================================================================
    v_res := public.rpc_get_pool_matches(v_pool_m5);
    if v_res is distinct from '[]'::jsonb then
        raise exception 'ARS-684 M-005: пул без единой партии отдал %, ожидался []::jsonb', v_res;
    end if;

    -- ==================================================================================
    -- M-009 — чужой пул: FORBIDDEN, не пустой список.
    -- ==================================================================================
    begin
        v_res := public.rpc_get_pool_matches(v_pool_m9);
        v_err := null;
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err is null or v_err not like 'FORBIDDEN%' then
        raise exception 'ARS-684 M-009: чужой пул не дал FORBIDDEN (sqlerrm=%, ответ=%)',
            v_err, v_res;
    end if;

    -- ==================================================================================
    -- M-014 — снятая партия/кусок: ни та, ни другая строка не должны попасть в ответ.
    -- ==================================================================================
    v_res := public.rpc_get_pool_matches(v_pool_m14);
    if v_res is distinct from '[]'::jsonb then
        raise exception 'ARS-684 M-014: снятые партия (cancelled) и кусок (cancelled) '
                        'остались в ответе (%) — ожидался [] на ОБОИХ маршрутах', v_res;
    end if;

    execute 'reset role';
    perform set_config('request.jwt.claims', '{}', true);

    raise notice 'ARS-684 / Pool Monitor dual-route: контракт rpc_get_pool_matches пройден. '
                 'Закрыты M-001 M-002 M-003 M-004 M-005 M-009 M-014, FR-008.';
end;
$$;

rollback;
