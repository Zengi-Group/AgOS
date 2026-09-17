-- ARS-314 / TSP-CANCELPOOL-ALLOC-01 — контракт: отмена заявки освобождает ОБА маршрута.
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01):
--   python3 scripts/run_sql_rollback.py tests/ars_314_cancel_pool_chunks_test.sql
-- Раннер по умолчанию откатывает: ни одной строки в базе не остаётся.
--
-- Предмет: `fn_tsp_release_pool_allocations` + обе функции отмены заявки
-- (`rpc_cancel_pool`, `rpc_admin_cancel_pool`). Спек (G2 2026-09-14):
-- Docs/AGOS-TSP-CancelPool-Chunks-FIX.md.
--
-- Фикстуры СВОИ ЦЕЛИКОМ: свой auth.users (public.users создаёт триггер), свои организации,
-- регион, pool_requests/pools/pool_lines/batches/batch_allocations. Существующие строки
-- не читаются как фикстуры и не меняются.
--
-- Покрытие матрицы (id названы в каждом утверждении — сверка ПО ID, не «по смыслу»):
--   M-001 M-002 M-003 M-004 M-005 M-006 M-007, плюс FR-002 (счётчики строки и заявки)
--   и FR-005 (фермер не оштрафован).
--
-- Роль: RPC зовём под `authenticated`, но ЧИТАЕМ таблицы без роли — прямой select из
-- public.pools под этой ролью падает `infinite recursion detected in policy`
-- (преэкзистентная рекурсия RLS, IMPL_DEBT RLS-POOLS-RECURSION-01).

do $$
declare
    v_region     uuid := gen_random_uuid();
    v_org_mpk    uuid := gen_random_uuid();
    v_org_farm   uuid := gen_random_uuid();
    v_auth_op    uuid := gen_random_uuid();
    v_user_op    uuid;
    v_sku        uuid;

    -- M-001: заявка с одним куском
    v_pr1  uuid := gen_random_uuid();  v_pool1 uuid := gen_random_uuid();  v_pl1 uuid := gen_random_uuid();
    v_b1   uuid := gen_random_uuid();
    -- M-002: смешанные маршруты
    v_pr2  uuid := gen_random_uuid();  v_pool2 uuid := gen_random_uuid();  v_pl2 uuid := gen_random_uuid();
    v_b2a  uuid := gen_random_uuid();  -- кусок
    v_b2b  uuid := gen_random_uuid();  -- целиком
    -- M-003: партия в ДВУХ заявках (вторая остаётся живой)
    v_pr3  uuid := gen_random_uuid();  v_pool3 uuid := gen_random_uuid();  v_pl3 uuid := gen_random_uuid();
    v_pr3b uuid := gen_random_uuid();  v_pool3b uuid := gen_random_uuid(); v_pl3b uuid := gen_random_uuid();
    v_b3   uuid := gen_random_uuid();
    -- M-004: часть партии уже доставлена
    v_pr4  uuid := gen_random_uuid();  v_pool4 uuid := gen_random_uuid();  v_pl4 uuid := gen_random_uuid();
    v_pr4b uuid := gen_random_uuid();  v_pool4b uuid := gen_random_uuid(); v_pl4b uuid := gen_random_uuid();
    v_b4   uuid := gen_random_uuid();
    -- M-005: партия уже снята фермером
    v_pr5  uuid := gen_random_uuid();  v_pool5 uuid := gen_random_uuid();  v_pl5 uuid := gen_random_uuid();
    v_b5   uuid := gen_random_uuid();
    -- M-007: заявка вообще без кусков (админский путь)
    v_pr7  uuid := gen_random_uuid();  v_pool7 uuid := gen_random_uuid();  v_pl7 uuid := gen_random_uuid();
    v_b7   uuid := gen_random_uuid();

    v_status text;
    v_int    int;
    v_res    int;
begin
    -- ==================================================================================
    -- Фикстуры
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-314-' || substr(replace(v_region::text,'-',''),1,8), 'QA ARS-314 область', 'oblast');

    insert into auth.users (id) values (v_auth_op);
    select id into v_user_op from public.users where auth_id = v_auth_op;
    if v_user_op is null then
        raise exception 'ARS-314_TEST_SETUP: триггер не создал public.users';
    end if;

    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_mpk,  'QA ARS-314 МПК', 'too', v_region, 'г. QA, 1', null),
           (v_org_farm, 'QA ARS-314 КХ',  'kh',  v_region, 'г. QA, 2', '+7 700 000 03 14');
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk, 'mpk'), (v_org_farm, 'farmer');
    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user_op, v_org_mpk, 'owner');

    select id into v_sku from public.tsp_skus limit 1;
    if v_sku is null then raise exception 'ARS-314_TEST_SETUP: пустой tsp_skus'; end if;

    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr1, v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active'),
           (v_pr2, v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active'),
           (v_pr3, v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active'),
           (v_pr3b,v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active'),
           (v_pr4, v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active'),
           (v_pr4b,v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active'),
           (v_pr5, v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active'),
           (v_pr7, v_org_mpk, 100, date_trunc('month', now())::date, v_region, 'active');

    insert into public.pools (id, pool_request_id, organization_id, target_heads, matched_heads, status)
    values (v_pool1, v_pr1, v_org_mpk, 100, 20, 'filling'),
           (v_pool2, v_pr2, v_org_mpk, 100, 40, 'filling'),
           (v_pool3, v_pr3, v_org_mpk, 100, 10, 'filling'),
           (v_pool3b,v_pr3b,v_org_mpk, 100, 10, 'filling'),
           (v_pool4, v_pr4, v_org_mpk, 100, 10, 'filling'),
           (v_pool4b,v_pr4b,v_org_mpk, 100, 10, 'executing'),
           (v_pool5, v_pr5, v_org_mpk, 100, 20, 'filling'),
           (v_pool7, v_pr7, v_org_mpk, 100, 20, 'filling');

    insert into public.pool_lines (id, pool_id, tsp_sku_id, mpk_price_per_kg, current_heads, current_volume_kg)
    values (v_pl1, v_pool1, v_sku, 1300, 20, 8000),
           (v_pl2, v_pool2, v_sku, 1300, 40, 16000),
           (v_pl3, v_pool3, v_sku, 1300, 10, 4000),
           (v_pl3b,v_pool3b,v_sku, 1300, 10, 4000),
           (v_pl4, v_pool4, v_sku, 1300, 10, 4000),
           (v_pl4b,v_pool4b,v_sku, 1300, 10, 4000),
           (v_pl5, v_pool5, v_sku, 1300, 20, 8000),
           (v_pl7, v_pool7, v_sku, 1300, 20, 8000);

    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, pool_line_id, matched_heads, deal_price_per_kg)
    values
        (v_b1,  v_org_farm, v_sku, 20, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl1, 20, 1300),
        (v_b2a, v_org_farm, v_sku, 20, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl2, 20, 1300),
        (v_b2b, v_org_farm, v_sku, 20, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl2, 20, 1300),
        -- M-003: 20 голов, по 10 в две заявки
        (v_b3,  v_org_farm, v_sku, 20, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl3, 20, 1300),
        -- M-004: 20 голов, 10 доставлено в другую заявку, 10 в отменяемой
        (v_b4,  v_org_farm, v_sku, 20, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl4, 20, 1300),
        -- M-005: партия снята фермером, кусок висит
        (v_b5,  v_org_farm, v_sku, 20, 400.00, date_trunc('month', now())::date, v_region, 'cancelled', v_pl5, 20, 1300),
        -- M-007: маршрут «целиком», кусков нет
        (v_b7,  v_org_farm, v_sku, 20, 400.00, date_trunc('month', now())::date, v_region, 'matched', v_pl7, 20, 1300);

    insert into public.batch_allocations (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values (v_b1,  v_pl1,  v_pool1,  20, 1300, 'matched'),
           (v_b2a, v_pl2,  v_pool2,  20, 1300, 'matched'),
           (v_b3,  v_pl3,  v_pool3,  10, 1300, 'matched'),
           (v_b3,  v_pl3b, v_pool3b, 10, 1300, 'matched'),     -- живая вторая заявка
           (v_b4,  v_pl4,  v_pool4,  10, 1300, 'matched'),
           (v_b4,  v_pl4b, v_pool4b, 10, 1300, 'delivered'),   -- уже доставлено
           (v_b5,  v_pl5,  v_pool5,  20, 1300, 'matched');
    -- v_b2b и v_b7 аллокаций НЕ имеют — маршрут «целиком».

    -- ==================================================================================
    -- M-001 — заявка с одним куском: кусок отменён, партия на рынке, счётчики обнулены
    -- ==================================================================================
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_op::text, 'role', 'authenticated')::text, true);
    v_res := public.rpc_cancel_pool(v_org_mpk, v_pool1, 'QA ARS-314');
    execute 'reset role';

    select status into v_status from public.batch_allocations where batch_id = v_b1 and pool_id = v_pool1;
    if v_status <> 'cancelled' then
        raise exception 'ARS-314 M-001: кусок остался % (ожидался cancelled)', v_status;
    end if;
    select status, matched_heads into v_status, v_int from public.batches where id = v_b1;
    if v_status <> 'published' or v_int <> 0 then
        raise exception 'ARS-314 M-001: партия %, matched_heads=% (ожидалось published / 0)', v_status, v_int;
    end if;
    select current_heads into v_int from public.pool_lines where id = v_pl1;
    if v_int <> 0 then
        raise exception 'ARS-314 M-001/FR-002: pool_lines.current_heads=% — счётчик голов строки не обнулён', v_int;
    end if;
    -- FR-005: фермер не оштрафован — событие нейтральное, без cancelled_after_match.
    if exists (select 1 from public.batch_events
                where batch_id = v_b1 and event_type = 'cancelled_after_match') then
        raise exception 'ARS-314 M-001/FR-005: на фермера повешен штраф за отмену комбината';
    end if;
    if not exists (select 1 from public.batch_events
                    where batch_id = v_b1 and event_type = 'returned_to_pool_cancelled'
                      and metadata->>'route' = 'allocation') then
        raise exception 'ARS-314 M-001: нет события returned_to_pool_cancelled по маршруту кусок';
    end if;

    -- ==================================================================================
    -- M-002 — смешанная заявка: освобождены ОБА маршрута
    -- ==================================================================================
    execute 'set local role authenticated';
    perform public.rpc_cancel_pool(v_org_mpk, v_pool2, 'QA ARS-314');
    execute 'reset role';

    select status into v_status from public.batches where id = v_b2a;
    if v_status <> 'published' then
        raise exception 'ARS-314 M-002: партия маршрута «кусок» осталась %', v_status;
    end if;
    select status into v_status from public.batches where id = v_b2b;
    if v_status <> 'published' then
        raise exception 'ARS-314 M-002: партия маршрута «целиком» осталась %', v_status;
    end if;

    -- ==================================================================================
    -- M-003 — партия в ДВУХ заявках: чужая сделка не тронута
    -- ==================================================================================
    execute 'set local role authenticated';
    perform public.rpc_cancel_pool(v_org_mpk, v_pool3, 'QA ARS-314');
    execute 'reset role';

    select status into v_status from public.batch_allocations where batch_id = v_b3 and pool_id = v_pool3;
    if v_status <> 'cancelled' then
        raise exception 'ARS-314 M-003: кусок отменяемой заявки остался %', v_status;
    end if;
    select status into v_status from public.batch_allocations where batch_id = v_b3 and pool_id = v_pool3b;
    if v_status <> 'matched' then
        raise exception 'ARS-314 M-003: кусок ЖИВОЙ заявки стал % — чужая сделка не должна страдать', v_status;
    end if;
    select status, matched_heads into v_status, v_int from public.batches where id = v_b3;
    if v_status <> 'partially_matched' or v_int <> 10 then
        raise exception 'ARS-314 M-003: партия %, matched_heads=% (ожидалось partially_matched / 10)', v_status, v_int;
    end if;

    -- ==================================================================================
    -- M-004 — часть партии доставлена: доставленное остаётся занятым
    -- ==================================================================================
    execute 'set local role authenticated';
    perform public.rpc_cancel_pool(v_org_mpk, v_pool4, 'QA ARS-314');
    execute 'reset role';

    select status into v_status from public.batch_allocations where batch_id = v_b4 and pool_id = v_pool4b;
    if v_status <> 'delivered' then
        raise exception 'ARS-314 M-004: доставленный кусок стал %', v_status;
    end if;
    select matched_heads into v_int from public.batches where id = v_b4;
    if v_int <> 10 then
        raise exception 'ARS-314 M-004/FR-002: matched_heads=% — доставленные головы обязаны считаться занятыми', v_int;
    end if;

    -- ==================================================================================
    -- M-005 — партия снята фермером: НЕ воскресает
    -- ==================================================================================
    execute 'set local role authenticated';
    perform public.rpc_cancel_pool(v_org_mpk, v_pool5, 'QA ARS-314');
    execute 'reset role';

    select status, matched_heads into v_status, v_int from public.batches where id = v_b5;
    if v_status <> 'cancelled' then
        raise exception 'ARS-314 M-005/FR-004: снятая фермером партия воскресла как % — ремонт не имеет права возвращать её на рынок', v_status;
    end if;
    if v_int <> 0 then
        raise exception 'ARS-314 M-005: matched_heads=% у снятой партии — счётчик не поправлен', v_int;
    end if;

    -- ==================================================================================
    -- M-006 — повторная отмена идемпотентна
    -- ==================================================================================
    execute 'set local role authenticated';
    v_res := public.rpc_cancel_pool(v_org_mpk, v_pool5, 'QA ARS-314 повтор');
    execute 'reset role';
    if v_res <> 0 then
        raise exception 'ARS-314 M-006: повторная отмена вернула % (ожидался 0)', v_res;
    end if;

    -- ==================================================================================
    -- M-007 — заявка без кусков: поведение как раньше. Через АДМИНСКУЮ отмену —
    -- дефект был идентичен в обеих функциях (урок L-2), значит проверяем обе.
    -- ==================================================================================
    -- fn_is_admin() читает app_metadata.is_admin из JWT (fast path, d07_ai_gateway.sql:2312),
    -- поэтому админский путь проверяется подстановкой claim — без записи в admin_roles,
    -- то есть без касания боевой таблицы прав даже под откатом.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_op::text, 'role', 'authenticated',
                          'app_metadata', json_build_object('is_admin', true))::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_admin_cancel_pool(v_pool7, 'QA ARS-314 admin');
    execute 'reset role';
    select status into v_status from public.batches where id = v_b7;
    if v_status <> 'published' then
        raise exception 'ARS-314 M-007: партия маршрута «целиком» при админской отмене осталась %', v_status;
    end if;
    select current_heads into v_int from public.pool_lines where id = v_pl7;
    if v_int <> 0 then
        raise exception 'ARS-314 M-007/FR-002: админская отмена не обнулила current_heads (=%)', v_int;
    end if;

    -- ==================================================================================
    -- Контроль: после всех отмен ни одного куска в статусе matched у отменённых заявок
    -- ==================================================================================
    select count(*) into v_int
    from public.batch_allocations a join public.pools p on p.id = a.pool_id
    where a.status = 'matched' and p.status = 'cancelled'
      and p.id in (v_pool1, v_pool2, v_pool3, v_pool4, v_pool5, v_pool7);
    if v_int > 0 then
        raise exception 'ARS-314: осталось % кусков matched в отменённых заявках', v_int;
    end if;

    raise notice 'ARS-314 / cancel_pool releases chunks: контракт пройден. Закрыты '
                 'M-001 M-002 M-003 M-004 M-005 M-006 M-007, FR-002 FR-004 FR-005.';
end;
$$;
