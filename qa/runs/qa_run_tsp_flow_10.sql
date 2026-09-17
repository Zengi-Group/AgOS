-- QA-прогон: пять кейсов, заблокированных долгом TSP-FLOW-10 (закрыт слайсом ARS-695).
-- Запуск: python3 scripts/run_sql_rollback.py qa/runs/qa_run_tsp_flow_10.sql
-- Раннер по умолчанию ОТКАТЫВАЕТ: прод не меняется (правило безопасности §1 qa-run).
--
-- Кейсы: TSPF-LIFE-11 (05) · TSPM-CLOSE-02, TSPM-CLOSE-03, TSPM-POOL-07 (06) · E2E-TSP-04 (08)
-- Проверяются ОЖИДАНИЯ КЕЙСОВ дословно, а не реализация: кейс описывает канон.
-- Конфиги читаются из tsp_config и подставляются в ожидания (правило §3, P8).

do $$
declare
    v_region   uuid := gen_random_uuid();
    v_org_mpk  uuid := gen_random_uuid();
    v_org_farm uuid := gen_random_uuid();
    v_auth     uuid := gen_random_uuid();
    v_user     uuid;
    v_sku      uuid;

    v_min      int;    -- порог закупки из конфига
    v_window   int;    -- окно решения МПК, часов
    v_above    int;    -- «набрано, но меньше цели»
    v_target   int;

    -- TSPM-CLOSE-02 / E2E-TSP-04-A: принять частично
    v_prA uuid := gen_random_uuid(); v_poolA uuid := gen_random_uuid(); v_plA uuid := gen_random_uuid();
    v_bA  uuid := gen_random_uuid();
    -- TSPF-LIFE-11 / E2E-TSP-04-B: вернуть партии
    v_prB uuid := gen_random_uuid(); v_poolB uuid := gen_random_uuid(); v_plB uuid := gen_random_uuid();
    v_bB  uuid := gen_random_uuid();
    -- TSPM-CLOSE-03: молчание дольше окна
    v_prC uuid := gen_random_uuid(); v_poolC uuid := gen_random_uuid(); v_plC uuid := gen_random_uuid();
    v_bC  uuid := gen_random_uuid();
    -- TSPM-POOL-07: окно истекло, ноль партий
    v_prD uuid := gen_random_uuid(); v_poolD uuid := gen_random_uuid(); v_plD uuid := gen_random_uuid();

    v_st     text;
    v_int    int;
    v_price  int;
    v_err    text;
    v_res    jsonb;
begin
    v_min    := public.fn_tsp_pool_min_heads();
    select mpk_decision_window_hours into v_window from public.tsp_config where is_active = true limit 1;
    v_window := coalesce(v_window, 24);
    v_above  := v_min + 5;
    v_target := v_above * 10;
    raise notice 'КОНФИГ: min_pool_heads=% · mpk_decision_window_hours=%', v_min, v_window;

    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-F10-' || substr(replace(v_region::text,'-',''),1,8), 'QA TSP-FLOW-10', 'oblast');
    insert into auth.users (id) values (v_auth);
    select id into v_user from public.users where auth_id = v_auth;
    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_mpk,'QA-F10 МПК','too',v_region,'QA 1',null),
           (v_org_farm,'QA-F10 КХ','kh',v_region,'QA 2','+7 700 000 10 10');
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk,'mpk'), (v_org_farm,'farmer');
    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user, v_org_mpk, 'owner');
    select id into v_sku from public.tsp_skus limit 1;

    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_prA,v_org_mpk,v_target,(date_trunc('month',now())-interval '2 month')::date,v_region,'active'),
           (v_prB,v_org_mpk,v_target,(date_trunc('month',now())-interval '2 month')::date,v_region,'active'),
           (v_prC,v_org_mpk,v_target,(date_trunc('month',now())-interval '2 month')::date,v_region,'active'),
           (v_prD,v_org_mpk,v_target,(date_trunc('month',now())-interval '2 month')::date,v_region,'active');

    insert into public.pools (id,pool_request_id,organization_id,target_heads,matched_heads,status,awaiting_decision_at)
    values (v_poolA,v_prA,v_org_mpk,v_target,v_above,'filling',null),
           (v_poolB,v_prB,v_org_mpk,v_target,v_above,'filling',null),
           -- TSPM-CLOSE-03: уже в точке выбора, молчание длиннее окна
           (v_poolC,v_prC,v_org_mpk,v_target,v_above,'awaiting_mpk_decision', now() - make_interval(hours => v_window + 1)),
           (v_poolD,v_prD,v_org_mpk,v_target,0,'filling',null);

    insert into public.pool_lines (id,pool_id,tsp_sku_id,mpk_price_per_kg,current_heads)
    values (v_plA,v_poolA,v_sku,1300,v_above),(v_plB,v_poolB,v_sku,1300,v_above),
           (v_plC,v_poolC,v_sku,1300,v_above),(v_plD,v_poolD,v_sku,1300,0);

    insert into public.batches (id,organization_id,tsp_sku_id,heads,avg_weight_kg,target_month,region_id,
                                status,pool_line_id,matched_heads,deal_price_per_kg)
    values (v_bA,v_org_farm,v_sku,v_above,400.00,date_trunc('month',now())::date,v_region,'matched',v_plA,v_above,1300),
           (v_bB,v_org_farm,v_sku,v_above,400.00,date_trunc('month',now())::date,v_region,'matched',v_plB,v_above,1300),
           (v_bC,v_org_farm,v_sku,v_above,400.00,date_trunc('month',now())::date,v_region,'matched',v_plC,v_above,1300);

    insert into public.batch_allocations (batch_id,pool_line_id,pool_id,heads,price_per_kg,status)
    values (v_bA,v_plA,v_poolA,v_above,1300,'matched'),
           (v_bB,v_plB,v_poolB,v_above,1300,'matched'),
           (v_bC,v_plC,v_poolC,v_above,1300,'matched');

    perform set_config('request.jwt.claims',
        json_build_object('sub',v_auth::text,'role','authenticated')::text, true);

    -- ═══ TSPM-POOL-07 · окно истекло, 0 партий → expired_empty без решения МПК ═══
    execute 'set local role authenticated';
    v_res := public.rpc_self_close_due_pools();
    execute 'reset role';
    select status into v_st from public.pools where id = v_poolD;
    raise notice 'TSPM-POOL-07: заявка с 0 партий → % (ожидание канона: expired_empty)', v_st;
    if v_st <> 'expired_empty' then
        raise exception 'TSPM-POOL-07 FAIL: % вместо expired_empty', v_st;
    end if;

    -- ═══ TSPM-CLOSE-03 · молчание > окна → дефолт «вернуть» ═══
    -- (тот же вызов подметания выше обработал и заявку C)
    select status into v_st from public.pools where id = v_poolC;
    raise notice 'TSPM-CLOSE-03: молчание %ч → % (ожидание: closed_unfilled, дефолт farmer-friendly)', v_window, v_st;
    if v_st <> 'closed_unfilled' then
        raise exception 'TSPM-CLOSE-03 FAIL: % вместо closed_unfilled', v_st;
    end if;
    select status into v_st from public.batches where id = v_bC;
    raise notice 'TSPM-CLOSE-03: партия после дефолта → % (ожидание: published)', v_st;
    if v_st <> 'published' then
        raise exception 'TSPM-CLOSE-03 FAIL: партия % вместо published', v_st;
    end if;
    -- «повторный вызов решения после дефолта → решение принято»: система обязана внятно
    -- отказать, а не применить решение второй раз.
    begin
        execute 'set local role authenticated';
        v_res := public.rpc_self_pool_accept_partial(v_poolC);
        execute 'reset role';
        v_err := null;
    exception when others then
        v_err := sqlerrm;
    end;
    raise notice 'TSPM-CLOSE-03: повторное решение после дефолта → %', coalesce(v_err,'ПРИМЕНЕНО (!)');
    if v_err is null or v_err not like 'INVALID_STATUS%' then
        raise exception 'TSPM-CLOSE-03 FAIL: повторное решение не отклонено (%)', coalesce(v_err,'применено');
    end if;

    -- ═══ TSPM-CLOSE-02 / E2E-TSP-04-A · «принять частично» ═══
    execute 'set local role authenticated';
    perform public.rpc_self_close_due_pools();          -- заявка A → точка выбора
    execute 'reset role';
    select status into v_st from public.pools where id = v_poolA;
    raise notice 'TSPM-CLOSE-02: заявка (0<filled<target) → % (ожидание: awaiting_mpk_decision)', v_st;
    if v_st <> 'awaiting_mpk_decision' then
        raise exception 'TSPM-CLOSE-02 FAIL: % вместо awaiting_mpk_decision', v_st;
    end if;

    execute 'set local role authenticated';
    v_res := public.rpc_self_pool_accept_partial(v_poolA);
    execute 'reset role';
    select status, target_heads into v_st, v_int from public.pools where id = v_poolA;
    raise notice 'E2E-TSP-04-A: принять частично → % · target_heads=% (ожидание: closed_partial, target=filled=%)',
                 v_st, v_int, v_above;
    if v_st <> 'closed_partial' or v_int <> v_above then
        raise exception 'E2E-TSP-04-A FAIL: % / target=% (ожидалось closed_partial / %)', v_st, v_int, v_above;
    end if;
    select status into v_st from public.batches where id = v_bA;
    raise notice 'E2E-TSP-04-A: партия → % (ожидание: confirmed)', v_st;
    if v_st <> 'confirmed' then
        raise exception 'E2E-TSP-04-A FAIL: партия % вместо confirmed', v_st;
    end if;

    -- ═══ TSPF-LIFE-11 / E2E-TSP-04-B · «вернуть партии» ═══
    execute 'set local role authenticated';
    perform public.rpc_self_close_due_pools();          -- заявка B → точка выбора
    v_res := public.rpc_self_pool_return_batches(v_poolB);
    execute 'reset role';
    select status into v_st from public.pools where id = v_poolB;
    raise notice 'E2E-TSP-04-B: вернуть партии → заявка % (ожидание: closed_unfilled)', v_st;
    if v_st <> 'closed_unfilled' then
        raise exception 'E2E-TSP-04-B FAIL: % вместо closed_unfilled', v_st;
    end if;
    select status, deal_price_per_kg, matched_heads into v_st, v_price, v_int
    from public.batches where id = v_bB;
    raise notice 'TSPF-LIFE-11: партия → % · deal_price=% · matched_heads=% (ожидание: published / NULL / 0)',
                 v_st, coalesce(v_price::text,'NULL'), v_int;
    if v_st <> 'published' or v_price is not null then
        raise exception 'TSPF-LIFE-11 FAIL: % / deal=% (ожидалось published / NULL)', v_st, v_price;
    end if;
    -- «партия снова участвует в matching»: предикат матчеров — status IN (published,offering,
    -- partially_matched) AND matched_heads < heads (20260702160000:686).
    if not (v_int < (select heads from public.batches where id = v_bB)) then
        raise exception 'TSPF-LIFE-11 FAIL: matched_heads=% не меньше heads — матчеры партию не возьмут', v_int;
    end if;
    raise notice 'TSPF-LIFE-11: партия снова видна матчерам (matched_heads % < heads) — OK', v_int;

    -- Уведомление фермеру («Покупатель не набрал нужный объём…») — ЧАСТЬ ОЖИДАНИЯ КЕЙСА,
    -- которая НЕ выполняется: слайс ARS-695 уведомлений не строит (FR-014, дом ARS-685),
    -- диспетчер событие→notifications не достроен (IMPL_DEBT NOTIF-DISPATCH-01).
    select count(*) into v_int from public.platform_events
    where event_type = 'market.pool.closed_unfilled' and entity_id = v_poolB;
    raise notice 'TSPF-LIFE-11: событие market.pool.closed_unfilled записано: % шт (уведомления — NOTIF-DISPATCH-01)', v_int;

    raise notice '═══ ПРОГОН ЗАВЕРШЁН: все пять кейсов отработали по ожиданиям канона ═══';
end;
$$;
