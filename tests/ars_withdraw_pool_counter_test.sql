-- TSP-WITHDRAW-POOLCOUNTER-01 — контракт: снятие партии возвращает место в заявке
-- и одинаково отвечает за отказ от сделки на обоих маршрутах матча.
--
-- ЗАПУСК: python3 scripts/run_sql_rollback.py tests/ars_withdraw_pool_counter_test.sql
-- Раннер по умолчанию откатывает — прод не меняется.
--
-- Предмет: `rpc_self_withdraw_batch` (правящее определение —
-- supabase/migrations/20260702190000_tsp_chunk_dispatch.sql:395).
-- Спек (G2 2026-09-17): Docs/AGOS-TSP-WithdrawBatch-PoolCounter-FIX.md.
--
-- Покрытие матрицы (сверка ПО ID): M-001 M-002 M-003 M-004 M-005 M-006,
-- плюс FR-001/002 (счётчики), FR-004 (штраф), FR-006 (терминальная заявка).

do $$
declare
    v_region  uuid := gen_random_uuid();
    v_org_mpk uuid := gen_random_uuid();
    v_org_f   uuid := gen_random_uuid();
    v_auth    uuid := gen_random_uuid();
    v_user    uuid;
    v_sku     uuid;

    -- M-001/M-002: партия целиком, заявка набирает
    v_pr1 uuid := gen_random_uuid(); v_pool1 uuid := gen_random_uuid(); v_pl1 uuid := gen_random_uuid();
    v_b1  uuid := gen_random_uuid();
    -- M-003: партия с куском (регресс)
    v_pr2 uuid := gen_random_uuid(); v_pool2 uuid := gen_random_uuid(); v_pl2 uuid := gen_random_uuid();
    v_b2  uuid := gen_random_uuid();
    -- M-004: кусок И привязка к той же заявке — вычесть один раз
    v_pr3 uuid := gen_random_uuid(); v_pool3 uuid := gen_random_uuid(); v_pl3 uuid := gen_random_uuid();
    v_b3  uuid := gen_random_uuid();
    -- M-005: заявка уже закрыта
    v_pr4 uuid := gen_random_uuid(); v_pool4 uuid := gen_random_uuid(); v_pl4 uuid := gen_random_uuid();
    v_b4  uuid := gen_random_uuid();
    -- M-006: непроданная партия
    v_pr5 uuid := gen_random_uuid(); v_pool5 uuid := gen_random_uuid(); v_pl5 uuid := gen_random_uuid();
    v_b5  uuid := gen_random_uuid();

    v_int int; v_st text; v_res jsonb;
begin
    insert into public.regions (id, code, name_ru, level)
    values (v_region,'QA-WD-'||substr(replace(v_region::text,'-',''),1,8),'QA withdraw','oblast');
    insert into auth.users (id) values (v_auth);
    select id into v_user from public.users where auth_id = v_auth;
    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_mpk,'QA-WD МПК','too',v_region,'QA 1',null),
           (v_org_f,'QA-WD КХ','kh',v_region,'QA 2','+7 700 000 20 20');
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk,'mpk'), (v_org_f,'farmer');
    -- Снимает ФЕРМЕР — членство в хозяйстве, не в комбинате.
    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user, v_org_f, 'owner');
    select id into v_sku from public.tsp_skus limit 1;

    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr1,v_org_mpk,100,date_trunc('month',now())::date,v_region,'active'),
           (v_pr2,v_org_mpk,100,date_trunc('month',now())::date,v_region,'active'),
           (v_pr3,v_org_mpk,100,date_trunc('month',now())::date,v_region,'active'),
           (v_pr4,v_org_mpk,100,date_trunc('month',now())::date,v_region,'active'),
           (v_pr5,v_org_mpk,100,date_trunc('month',now())::date,v_region,'active');

    insert into public.pools (id,pool_request_id,organization_id,target_heads,matched_heads,status)
    values (v_pool1,v_pr1,v_org_mpk,100,80,'filling'),
           (v_pool2,v_pr2,v_org_mpk,100,20,'filling'),
           -- M-004: счётчик заявки СПЕЦИАЛЬНО больше голов партии (50 против 20), иначе
           -- двойное вычитание неотличимо от одинарного: greatest(0-20,0) тоже даёт 0.
           (v_pool3,v_pr3,v_org_mpk,100,50,'filling'),
           (v_pool4,v_pr4,v_org_mpk,100,20,'closed_partial'),   -- M-005: терминальная
           (v_pool5,v_pr5,v_org_mpk,100,0,'filling');

    insert into public.pool_lines (id,pool_id,tsp_sku_id,mpk_price_per_kg,current_heads,current_volume_kg)
    values (v_pl1,v_pool1,v_sku,1300,80,32000),(v_pl2,v_pool2,v_sku,1300,20,8000),
           (v_pl3,v_pool3,v_sku,1300,50,20000),(v_pl4,v_pool4,v_sku,1300,20,8000),
           (v_pl5,v_pool5,v_sku,1300,0,0);

    insert into public.batches (id,organization_id,tsp_sku_id,heads,avg_weight_kg,target_month,region_id,
                                status,pool_line_id,matched_heads,deal_price_per_kg)
    values (v_b1,v_org_f,v_sku,30,400.00,date_trunc('month',now())::date,v_region,'matched',v_pl1,30,1300),
           (v_b2,v_org_f,v_sku,20,400.00,date_trunc('month',now())::date,v_region,'matched',v_pl2,20,1300),
           (v_b3,v_org_f,v_sku,20,400.00,date_trunc('month',now())::date,v_region,'matched',v_pl3,20,1300),
           (v_b4,v_org_f,v_sku,20,400.00,date_trunc('month',now())::date,v_region,'matched',v_pl4,20,1300),
           (v_b5,v_org_f,v_sku,25,400.00,date_trunc('month',now())::date,v_region,'published',null,0,null);

    -- M-003 и M-004 — партии С кусками. M-001/M-005 — без кусков (маршрут «целиком»).
    insert into public.batch_allocations (batch_id,pool_line_id,pool_id,heads,price_per_kg,status)
    values (v_b2,v_pl2,v_pool2,20,1300,'matched'),
           (v_b3,v_pl3,v_pool3,20,1300,'matched');

    perform set_config('request.jwt.claims',
        json_build_object('sub',v_auth::text,'role','authenticated')::text, true);

    -- ═══ M-001 · партия целиком: счётчики заявки и строки уменьшены, штраф записан ═══
    execute 'set local role authenticated';
    v_res := public.rpc_self_withdraw_batch(v_b1, true);
    execute 'reset role';

    select matched_heads into v_int from public.pools where id = v_pool1;
    raise notice 'M-001: заявка 80 - 30 = % (ожидание 50)', v_int;
    if v_int <> 50 then
        raise exception 'M-001/FR-001 FAIL: matched_heads=% (ожидалось 50) — место в заявке не освобождено', v_int;
    end if;
    select current_heads, current_volume_kg into v_int, v_st from public.pool_lines where id = v_pl1;
    if v_int <> 50 then
        raise exception 'M-001/FR-002 FAIL: current_heads строки=% (ожидалось 50)', v_int;
    end if;
    select current_volume_kg into v_int from public.pool_lines where id = v_pl1;
    if v_int <> 20000 then
        raise exception 'M-001/FR-002 FAIL: current_volume_kg=% (ожидалось 20000 = 32000-12000)', v_int;
    end if;
    -- FR-004: снятие ПРОДАННОЙ партии = отказ от сделки, событие штрафное.
    if not exists (select 1 from public.batch_events
                    where batch_id = v_b1 and event_type = 'cancelled_after_match') then
        raise exception 'M-001/FR-004 FAIL: снятие проданной партии не записано как cancelled_after_match';
    end if;
    if exists (select 1 from public.batch_events
                where batch_id = v_b1 and event_type = 'cancelled_before_match') then
        raise exception 'M-001/FR-004 FAIL: записано cancelled_before_match — «снята до матча» для проданной партии';
    end if;

    -- ═══ M-002 · заявка снова может добирать ═══
    select (matched_heads < target_heads) into v_st from public.pools where id = v_pool1;
    raise notice 'M-002: заявка может добирать: %', v_st;
    if v_st <> 'true' then
        raise exception 'M-002/FR-003 FAIL: matched_heads не меньше target_heads — матчер места не увидит';
    end if;

    -- ═══ M-003 · регресс маршрута «кусок» ═══
    execute 'set local role authenticated';
    v_res := public.rpc_self_withdraw_batch(v_b2, true);
    execute 'reset role';
    select matched_heads into v_int from public.pools where id = v_pool2;
    raise notice 'M-003: заявка с куском 20 - 20 = % (ожидание 0)', v_int;
    if v_int <> 0 then
        raise exception 'M-003/FR-005 FAIL: маршрут «кусок» сломан: matched_heads=%', v_int;
    end if;
    select status into v_st from public.batch_allocations where batch_id = v_b2;
    if v_st <> 'cancelled' then
        raise exception 'M-003 FAIL: кусок остался %', v_st;
    end if;

    -- ═══ M-004 · кусок И привязка к той же заявке: вычесть РОВНО один раз ═══
    execute 'set local role authenticated';
    v_res := public.rpc_self_withdraw_batch(v_b3, true);
    execute 'reset role';
    select matched_heads into v_int from public.pools where id = v_pool3;
    raise notice 'M-004: заявка 50 - 20 = % (ожидание 30; двойное вычитание дало бы 10)', v_int;
    if v_int <> 30 then
        raise exception 'M-004 FAIL: matched_heads=% (ожидалось 30) — маршруты сложились, вычли дважды', v_int;
    end if;
    select current_heads into v_int from public.pool_lines where id = v_pl3;
    raise notice 'M-004: строка 50 - 20 = % (ожидание 30)', v_int;
    if v_int <> 30 then
        raise exception 'M-004 FAIL: current_heads=% (ожидалось 30) — двойное вычитание по строке', v_int;
    end if;
    -- Штрафное событие есть (его пишет ветка кусков). Количество НЕ проверяем: функция
    -- дополнительно пишет итоговое событие в конце, поэтому «одно на партию» — неверное
    -- ожидание, а не признак дефекта. Двойное вычитание ловится счётчиками выше.
    if not exists (select 1 from public.batch_events
                    where batch_id = v_b3 and event_type = 'cancelled_after_match') then
        raise exception 'M-004 FAIL: штрафное событие не записано';
    end if;

    -- ═══ M-005 · заявка уже закрыта: счётчик не трогаем (FR-006) ═══
    execute 'set local role authenticated';
    v_res := public.rpc_self_withdraw_batch(v_b4, true);
    execute 'reset role';
    select matched_heads into v_int from public.pools where id = v_pool4;
    raise notice 'M-005: терминальная заявка (closed_partial) осталась с % (ожидание 20 — не тронуто)', v_int;
    if v_int <> 20 then
        raise exception 'M-005/FR-006 FAIL: счётчик закрытой заявки изменён на % — её числа это история сделки', v_int;
    end if;

    -- ═══ M-006 · непроданная партия: счётчики ни при чём, штрафа нет ═══
    execute 'set local role authenticated';
    v_res := public.rpc_self_withdraw_batch(v_b5, false);
    execute 'reset role';
    if exists (select 1 from public.batch_events
                where batch_id = v_b5 and event_type = 'cancelled_after_match') then
        raise exception 'M-006 FAIL: за снятие НЕпроданной партии выписан штраф';
    end if;
    select matched_heads into v_int from public.pools where id = v_pool5;
    if v_int <> 0 then
        raise exception 'M-006 FAIL: счётчик заявки без матчей изменился на %', v_int;
    end if;

    raise notice 'TSP-WITHDRAW-POOLCOUNTER-01: контракт пройден. Закрыты M-001..M-006, FR-001/002/003/004/005/006.';
end;
$$;
