-- ARS-754 / Партия продаётся только целиком: ручная привязка не режет.
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01): миграция и тест
-- идут ОДНОЙ откатываемой транзакцией, как у ARS-695/ARS-731:
--   cat supabase/migrations/20260924120000_ars_754_whole_batch_only.sql \
--       tests/ars_754_whole_batch_only_test.sql > /tmp/ars754_run.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars754_run.sql
-- Файл открывает свою транзакцию и заканчивается ROLLBACK: ни одной строки не остаётся.
-- Сторож ниже роняет прогон ДО первой записи, если файл исполняется автокоммитом.
--
-- Предмет: supabase/migrations/20260924120000_ars_754_whole_batch_only.sql.
-- Спек (G2 2026-09-24): Docs/AGOS-TSP-WholeBatchOnly-ARS-754.md.
--
-- Покрытие матрицы (id названы в КАЖДОМ утверждении и в строке NOTICE «… ok» —
-- Matrix Test Audit сверяет ПО ID): M-001 · M-002 · M-003 · M-004 · M-005 · M-006 ·
-- M-007 · M-008 · M-018 · M-019. Плюс FR-002 (вес: свободно меньше одной головы),
-- FR-003 (0 и ≥ голов), FR-004 (продано 0 < N < голов; продано всё), FR-006 (аллокатор
-- напрямую: 0 и ни одной записи), FR-021 (порядок ③ до ④, ⑤ до ⑥).
--
-- M-008 одной транзакцией не воспроизводится (две сессии): проверяется ① чтением тела —
-- первый оператор RPC берёт `for update` строку pools, это выстраивает привязки в одну
-- заявку в очередь; ② последовательной имитацией очереди: вторая привязка видит уже
-- набранное первой.
--
-- «Ничего не записано» на отказе: отказ RPC откатывает её запись целиком (так же, как
-- на API), поэтому содержательная проверка FR-002 «аллокатор отвечает 0 ДО первой записи» —
-- в M-007 и FR-006: строка, которая не вместила партию, не получила новой версии кортежа
-- (ctid не сдвинулся), хотя транзакция продолжилась и записала другое.
--
-- Фикстуры СВОИ ЦЕЛИКОМ: свой регион, свои организации, свои pool_requests/pools/
-- pool_lines/batches/offers. Потолки строк (max_heads / max_volume_kg) ставятся руками:
-- у самосборных заявок их нет. Общая конфигурация (tsp_config) не правится.

\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-754_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

-- Вызов ручной привязки так, как её зовёт фронт: роль authenticated, JWT оператора МПК.
-- Возвращает 'OK' или код отказа (текст до первого двоеточия — так же его режет
-- словарь зоны МПК, ARS-691 FR-002).
create function pg_temp.ars754_match(p_auth uuid, p_pool uuid, p_batch uuid,
                                     p_heads int, p_price int default null)
returns text
language plpgsql
as $f$
declare
    v_pl uuid;
begin
    perform set_config('request.jwt.claims',
        json_build_object('sub', p_auth::text, 'role', 'authenticated')::text, true);
    begin
        execute 'set local role authenticated';
        v_pl := public.rpc_self_match_batch_to_pool(p_pool, p_batch, p_heads, p_price);
        execute 'reset role';
        return 'OK';
    exception when others then
        execute 'reset role';
        return split_part(sqlerrm, ':', 1);
    end;
end;
$f$;

do $$
declare
    v_region    uuid := gen_random_uuid();
    v_org_mpk   uuid := gen_random_uuid();
    v_org_farm  uuid := gen_random_uuid();
    v_auth_mpk  uuid := gen_random_uuid();
    v_auth_farm uuid := gen_random_uuid();
    v_user_mpk  uuid;
    v_user_farm uuid;

    v_sku_id    uuid;
    v_grade     text;
    v_cat       text;
    v_ask       int  := 1200;        -- ask фермера, ₸/кг
    v_bid       int  := 1300;        -- бид МПК, ₸/кг (>= ask)
    v_month     date := date_trunc('month', now())::date;

    v_pool      uuid;
    v_pl        uuid;
    v_pl2       uuid;
    v_b         uuid;
    v_b2        uuid;
    v_offer     uuid;
    v_res       text;
    v_int       int;
    v_int2      int;
    v_status    text;
    v_tid       tid;
    v_tid2      tid;
    v_tid3      tid;
    v_def       text;
    v_p_pools   int;
    v_p_first   int;
begin
    -- ==================================================================================
    -- 0. Фикстуры общего назначения
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-754-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-754 область', 'oblast');

    insert into auth.users (id) values (v_auth_mpk), (v_auth_farm);
    select id into v_user_mpk  from public.users where auth_id = v_auth_mpk;
    select id into v_user_farm from public.users where auth_id = v_auth_farm;
    if v_user_mpk is null or v_user_farm is null then
        raise exception 'ARS-754_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_mpk,  'QA ARS-754 МПК', 'too', v_region, 'г. QA, ул. 1', null),
           (v_org_farm, 'QA ARS-754 КХ',  'kh',  v_region, 'г. QA, ул. 2', '+7 700 000 07 54');
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk, 'mpk'), (v_org_farm, 'farmer');
    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user_mpk, v_org_mpk, 'owner'), (v_user_farm, v_org_farm, 'owner');

    -- Сорт партии и строки заявки — из живых справочников (P8, L-7), как у ARS-731.
    select s.id, gs.code into v_sku_id, v_grade
    from public.tsp_skus s
    join public.grade_standards gs on gs.id = s.grade_id
    where s.is_active = true
    limit 1;
    if v_sku_id is null or v_grade is null then
        raise exception 'ARS-754_TEST_SETUP: не нашёл активный tsp_sku с сортом';
    end if;
    select l.category_label into v_cat
    from (select distinct category_label from public.pool_lines where category_label is not null) l
    where public.fn_tsp_grade_for_mpk_key(l.category_label) = v_grade
    limit 1;
    if v_cat is null then
        raise exception 'ARS-754_TEST_SETUP: нет category_label, дающего сорт %', v_grade;
    end if;

    -- ==================================================================================
    -- M-001 — партия влезает: цель 80, набрано 20, партия 23
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 20, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 20);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'OK' then
        raise exception 'ARS-754 M-001: привязка отказала (%), ожидалось OK', v_res;
    end if;
    select count(*), max(heads) into v_int, v_int2 from public.batch_allocations where batch_id = v_b;
    if v_int <> 1 or v_int2 <> 23 then
        raise exception 'ARS-754 M-001: строк сделки % (голов %), ожидалась одна на 23', v_int, v_int2;
    end if;
    select status, matched_heads into v_status, v_int from public.batches where id = v_b;
    if v_status <> 'matched' or v_int <> 23 then
        raise exception 'ARS-754 M-001: партия % / продано %, ожидалось matched / 23', v_status, v_int;
    end if;
    -- FR-009: поля партии, по которым BuyerCard показывает покупателя и цену.
    if not exists (select 1 from public.batches
                   where id = v_b and pool_line_id = v_pl and deal_price_per_kg = v_bid) then
        raise exception 'ARS-754 M-001 (FR-009): аллокатор не записал pool_line_id / deal_price_per_kg партии';
    end if;
    select matched_heads, status into v_int, v_status from public.pools where id = v_pool;
    if v_int <> 43 or v_status <> 'filling' then
        raise exception 'ARS-754 M-001: в заявке % (%), ожидалось 43 (filling)', v_int, v_status;
    end if;
    raise notice 'ARS-754 M-001 ok: партия целиком одной строкой сделки, в заявке 43';

    -- ==================================================================================
    -- M-002 — не влезает в заявку: цель 80, набрано 71, партия 23 (+ вторая в offering
    -- с живым оффером: FR-002 «офферы остаются как были»)
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid();
    v_b := gen_random_uuid(); v_b2 := gen_random_uuid(); v_offer := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 71, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 71);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b,  v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask),
           (v_b2, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'offering',  v_ask);
    insert into public.offers (id, batch_id, mpk_org_id, offered_price_per_kg, status, expires_at)
    values (v_offer, v_b2, v_org_mpk, v_ask, 'pending', now() + interval '1 day');

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BATCH_DOES_NOT_FIT' then
        raise exception 'ARS-754 M-002: ответ %, ожидался BATCH_DOES_NOT_FIT', v_res;
    end if;
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b2, null);
    if v_res <> 'BATCH_DOES_NOT_FIT' then
        raise exception 'ARS-754 M-002: ответ по партии в offering %, ожидался BATCH_DOES_NOT_FIT', v_res;
    end if;
    if exists (select 1 from public.batches where id = v_b  and (status <> 'published' or matched_heads <> 0))
       or exists (select 1 from public.batches where id = v_b2 and (status <> 'offering' or matched_heads <> 0))
       or exists (select 1 from public.batch_allocations where batch_id in (v_b, v_b2))
       or exists (select 1 from public.batch_events where batch_id in (v_b, v_b2))
       or not exists (select 1 from public.offers where id = v_offer and status = 'pending')
       or not exists (select 1 from public.pools where id = v_pool and matched_heads = 71 and status = 'filling')
       or not exists (select 1 from public.pool_lines where id = v_pl and current_heads = 71) then
        raise exception 'ARS-754 M-002: отказ что-то изменил (партия/строки/заявка/оффер/журнал)';
    end if;
    raise notice 'ARS-754 M-002 ok: BATCH_DOES_NOT_FIT, партии/заявка/оффер как были';

    -- ==================================================================================
    -- M-003 — не влезает в строку: потолок строки 15, занято 0, партия 23, заявка свободна
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
                                   current_heads, max_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 0, 15);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BATCH_DOES_NOT_FIT' then
        raise exception 'ARS-754 M-003: ответ %, ожидался BATCH_DOES_NOT_FIT', v_res;
    end if;
    if exists (select 1 from public.batch_allocations where batch_id = v_b)
       or not exists (select 1 from public.batches where id = v_b and status = 'published' and matched_heads = 0)
       or not exists (select 1 from public.pool_lines where id = v_pl and current_heads = 0) then
        raise exception 'ARS-754 M-003: отказ что-то записал';
    end if;
    raise notice 'ARS-754 M-003 ok: потолок строки 15 < 23 → BATCH_DOES_NOT_FIT, ничего не записано';

    -- ==================================================================================
    -- FR-002 — по весу свободно меньше одной головы: строка — кандидат (есть 200 кг),
    -- но в головах по весу 0 → BATCH_DOES_NOT_FIT, а не NO_MATCHING_LINE
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
                                   current_heads, max_volume_kg, current_volume_kg)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 0, 9000, 8800);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BATCH_DOES_NOT_FIT' then
        raise exception 'ARS-754 FR-002: вес < одной головы — ответ %, ожидался BATCH_DOES_NOT_FIT', v_res;
    end if;
    raise notice 'ARS-754 FR-002 ok: по весу свободно 200 кг < одной головы → BATCH_DOES_NOT_FIT';

    -- ==================================================================================
    -- M-004 — влезает ровно: свободно 23, партия 23 → заявка набрана и закрывается (ARS-731)
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 23, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 0);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'OK' then
        raise exception 'ARS-754 M-004: ответ %, ожидалось OK', v_res;
    end if;
    select status into v_status from public.pools where id = v_pool;
    if v_status <> 'closed_filled' then
        raise exception 'ARS-754 M-004: заявка %, ожидалось closed_filled', v_status;
    end if;
    select status into v_status from public.batch_allocations where batch_id = v_b;
    if v_status <> 'confirmed' then
        raise exception 'ARS-754 M-004: строка сделки %, ожидалось confirmed (ARS-731)', v_status;
    end if;
    raise notice 'ARS-754 M-004 ok: влезла ровно, заявка closed_filled, сделка confirmed';

    -- ==================================================================================
    -- M-005 — просьба разрезать через API: p_matched_heads = 10, партия 23.
    -- FR-003 — 0 → NO_REMAINING_HEADS; число ≥ голов = вся партия.
    -- FR-021 ③ до ④ — в заявке нет строки под сорт, а отказ всё равно BATCH_DOES_NOT_FIT.
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 0);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, 10);
    if v_res <> 'BATCH_DOES_NOT_FIT' then
        raise exception 'ARS-754 M-005: p_matched_heads=10 — ответ %, ожидался BATCH_DOES_NOT_FIT', v_res;
    end if;
    if exists (select 1 from public.batch_allocations where batch_id = v_b)
       or not exists (select 1 from public.batches where id = v_b and status = 'published' and matched_heads = 0) then
        raise exception 'ARS-754 M-005: отказ что-то записал';
    end if;
    raise notice 'ARS-754 M-005 ok: просьба разрезать (10 из 23) → BATCH_DOES_NOT_FIT';

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, 0);
    if v_res <> 'NO_REMAINING_HEADS' then
        raise exception 'ARS-754 FR-003: p_matched_heads=0 — ответ %, ожидался NO_REMAINING_HEADS', v_res;
    end if;
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, 50);
    if v_res <> 'OK'
       or not exists (select 1 from public.batch_allocations where batch_id = v_b and heads = 23) then
        raise exception 'ARS-754 FR-003: p_matched_heads=50 — ответ %, ожидалась вся партия (23)', v_res;
    end if;
    raise notice 'ARS-754 FR-003 ok: 0 → NO_REMAINING_HEADS, 50 ≥ 23 → вся партия';

    v_pool := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');                     -- строк нет вовсе
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, 10);
    if v_res <> 'BATCH_DOES_NOT_FIT' then
        raise exception 'ARS-754 FR-021: ③ должен сработать раньше ④ — ответ %', v_res;
    end if;
    raise notice 'ARS-754 FR-021 ok: ③ (разрезать) раньше ④ (нет строки)';

    -- ==================================================================================
    -- M-006 — партия уже «частями» (partially_matched) → BATCH_NOT_AVAILABLE.
    -- FR-004 — published, продано 5 из 20 → BATCH_NOT_AVAILABLE; продано 20 из 20 →
    -- BATCH_FULLY_MATCHED (случай ARS-689).
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 0);

    v_b := gen_random_uuid();
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg, matched_heads)
    values (v_b, v_org_farm, v_sku_id, 20, 400.00, v_month, v_region, 'partially_matched', v_ask, 10);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BATCH_NOT_AVAILABLE' then
        raise exception 'ARS-754 M-006: partially_matched — ответ %, ожидался BATCH_NOT_AVAILABLE', v_res;
    end if;
    if exists (select 1 from public.batch_allocations where batch_id = v_b)
       or not exists (select 1 from public.pool_lines where id = v_pl and current_heads = 0) then
        raise exception 'ARS-754 M-006: отказ что-то записал';
    end if;
    raise notice 'ARS-754 M-006 ok: partially_matched → BATCH_NOT_AVAILABLE, ничего не записано';

    v_b := gen_random_uuid();
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg, matched_heads)
    values (v_b, v_org_farm, v_sku_id, 20, 400.00, v_month, v_region, 'published', v_ask, 5);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BATCH_NOT_AVAILABLE' then
        raise exception 'ARS-754 FR-004: published, продано 5 из 20 — ответ %, ожидался BATCH_NOT_AVAILABLE', v_res;
    end if;
    v_b := gen_random_uuid();
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg, matched_heads)
    values (v_b, v_org_farm, v_sku_id, 20, 400.00, v_month, v_region, 'published', v_ask, 20);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BATCH_FULLY_MATCHED' then
        raise exception 'ARS-754 FR-004: published, продано 20 из 20 — ответ %, ожидался BATCH_FULLY_MATCHED', v_res;
    end if;
    raise notice 'ARS-754 FR-004 ok: продано 5/20 → BATCH_NOT_AVAILABLE, 20/20 → BATCH_FULLY_MATCHED';

    -- ==================================================================================
    -- M-007 — две строки под сорт: у строки с высшей ценой нет места под 23, во второй есть.
    -- Плюс FR-002: первая строка ответила 0 ДО первой записи — её кортеж не сдвинулся.
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_pl2 := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
                                   current_heads, max_heads)
    values (v_pl,  v_pool, v_sku_id, v_cat, v_bid + 100, 0, 15),     -- высшая цена, мало места
           (v_pl2, v_pool, v_sku_id, v_cat, v_bid,       0, null);   -- ниже цена, место есть
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);
    select ctid into v_tid from public.pool_lines where id = v_pl;

    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'OK' then
        raise exception 'ARS-754 M-007: ответ %, ожидалось OK (во второй строке есть место)', v_res;
    end if;
    if not exists (select 1 from public.batch_allocations
                   where batch_id = v_b and pool_line_id = v_pl2 and heads = 23)
       or (select count(*) from public.batch_allocations where batch_id = v_b) <> 1
       or not exists (select 1 from public.batches where id = v_b and pool_line_id = v_pl2
                                                     and deal_price_per_kg = v_bid) then
        raise exception 'ARS-754 M-007: партия записана не во вторую строку целиком';
    end if;
    select ctid into v_tid2 from public.pool_lines where id = v_pl;
    if v_tid2 <> v_tid
       or not exists (select 1 from public.pool_lines where id = v_pl and current_heads = 0) then
        raise exception 'ARS-754 M-007 (FR-002): строка с высшей ценой получила запись, хотя партию не вместила';
    end if;
    raise notice 'ARS-754 M-007 ok: первая строка (15 мест) пропущена без записи, партия во второй';

    -- FR-020 — порядок «от высшей цены»: ОБЕ строки вмещают партию. Дешёвая вставлена
    -- первой, чтобы перебор без `order by … desc` (или с `asc`) выбрал её (ревью якоря 7:
    -- M-007 такой регресс не ловит — в нём вмещает только одна строка).
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_pl2 := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl2, v_pool, v_sku_id, v_cat, v_bid,       0);         -- дешёвая, первой
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl,  v_pool, v_sku_id, v_cat, v_bid + 100, 0);         -- дорогая
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'OK'
       or not exists (select 1 from public.batches where id = v_b and pool_line_id = v_pl
                                                     and deal_price_per_kg = v_bid + 100)
       or not exists (select 1 from public.pool_lines where id = v_pl2 and current_heads = 0) then
        raise exception 'ARS-754 FR-020: обе строки вмещают — партия ушла не в строку с высшей ценой (%)', v_res;
    end if;
    raise notice 'ARS-754 FR-020 ok: обе строки вмещают — партия в строке с высшей ценой';

    -- ==================================================================================
    -- FR-006 — аллокатор напрямую: не вмещает → 0, и ни партия, ни строка, ни заявка не
    -- получили новой версии кортежа. partially_matched не пишется (FR-007).
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
                                   current_heads, max_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 0, 15);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);
    select ctid into v_tid  from public.batches    where id = v_b;
    select ctid into v_tid2 from public.pool_lines where id = v_pl;
    select ctid into v_tid3 from public.pools      where id = v_pool;

    v_int := public.fn_tsp_alloc_chunk(v_b, v_pl, 'manual_match', v_user_mpk, null, v_bid);
    if v_int <> 0 then
        raise exception 'ARS-754 FR-006: аллокатор взял % голов из 23 в строку на 15 — партия разрезана', v_int;
    end if;
    if (select ctid from public.batches    where id = v_b)    <> v_tid
       or (select ctid from public.pool_lines where id = v_pl)   <> v_tid2
       or (select ctid from public.pools      where id = v_pool) <> v_tid3
       or exists (select 1 from public.batch_allocations where batch_id = v_b)
       or exists (select 1 from public.batch_events where batch_id = v_b) then
        raise exception 'ARS-754 FR-006: аллокатор ответил 0, но что-то записал';
    end if;
    raise notice 'ARS-754 FR-006 ok: аллокатор 0 до первой записи, partially_matched не появился';

    -- ==================================================================================
    -- FR-021 ⑤ до ⑥ и ⑥ — цена: партия не влезает и бид ниже ask → BATCH_DOES_NOT_FIT;
    -- влезает и бид ниже ask → BID_BELOW_ASK
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
                                   current_heads, max_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_ask - 100, 0, 15);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BATCH_DOES_NOT_FIT' then
        raise exception 'ARS-754 FR-021: ⑤ должен сработать раньше ⑥ — ответ %', v_res;
    end if;
    update public.pool_lines set max_heads = null where id = v_pl;
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'BID_BELOW_ASK' then
        raise exception 'ARS-754 FR-021: партия влезает, бид ниже ask — ответ %, ожидался BID_BELOW_ASK', v_res;
    end if;
    raise notice 'ARS-754 FR-021 ok: ⑤ (не влезает) раньше ⑥ (цена); влезает с низкой ценой → BID_BELOW_ASK';

    -- ==================================================================================
    -- M-018 — строка полна: единственная строка под сорт, потолок 15, занято 15
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 15, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
                                   current_heads, max_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 15, 15);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'NO_MATCHING_LINE' then
        raise exception 'ARS-754 M-018: ответ %, ожидался NO_MATCHING_LINE', v_res;
    end if;
    raise notice 'ARS-754 M-018 ok: строка полна (15/15) → NO_MATCHING_LINE, как сегодня';

    -- ==================================================================================
    -- M-019 — строки под сорт и породу нет: единственная строка неактивна
    -- ==================================================================================
    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 80, 0, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
                                   current_heads, is_active)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 0, false);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b, v_org_farm, v_sku_id, 23, 400.00, v_month, v_region, 'published', v_ask);
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null);
    if v_res <> 'NO_MATCHING_LINE' then
        raise exception 'ARS-754 M-019: ответ %, ожидался NO_MATCHING_LINE', v_res;
    end if;
    raise notice 'ARS-754 M-019 ok: активной строки под сорт нет → NO_MATCHING_LINE';

    -- ==================================================================================
    -- M-008 — гонка двух операторов.
    -- ① Тело: первый оператор RPC — `for update` строки pools (сама заявка).
    -- ② Очередь: свободно 20, две партии по 12 → первая прошла (в заявке 8, набор идёт),
    --    вторая BATCH_DOES_NOT_FIT. Свободно 12 → первая набрала ровно до цели, вторая
    --    POOL_NOT_FILLING. Перелива нет.
    -- ==================================================================================
    v_def := lower(pg_get_functiondef('public.rpc_self_match_batch_to_pool(uuid, uuid, int, int)'::regprocedure));
    v_p_pools := position('from public.pools where id = p_pool_id for update' in v_def);
    v_p_first := least(
        nullif(position('from public.batches' in v_def), 0),
        nullif(position('from public.pool_lines' in v_def), 0),
        nullif(position('fn_tsp_alloc_chunk' in v_def), 0));
    if v_p_pools = 0 or v_p_pools > v_p_first then
        raise exception 'ARS-754 M-008: первый оператор RPC — не блокировка строки pools';
    end if;

    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid(); v_b2 := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 30, 10, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 10);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b,  v_org_farm, v_sku_id, 12, 400.00, v_month, v_region, 'published', v_ask),
           (v_b2, v_org_farm, v_sku_id, 12, 400.00, v_month, v_region, 'published', v_ask);
    if pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null) <> 'OK' then
        raise exception 'ARS-754 M-008: первая привязка не прошла';
    end if;
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b2, null);
    if v_res <> 'BATCH_DOES_NOT_FIT'
       or not exists (select 1 from public.pools where id = v_pool and matched_heads = 22 and status = 'filling') then
        raise exception 'ARS-754 M-008: вторая привязка — ответ %, ожидался BATCH_DOES_NOT_FIT без перелива', v_res;
    end if;

    v_pool := gen_random_uuid(); v_pl := gen_random_uuid(); v_b := gen_random_uuid(); v_b2 := gen_random_uuid();
    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 22, 10, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, v_cat, v_bid, 10);
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b,  v_org_farm, v_sku_id, 12, 400.00, v_month, v_region, 'published', v_ask),
           (v_b2, v_org_farm, v_sku_id, 12, 400.00, v_month, v_region, 'published', v_ask);
    if pg_temp.ars754_match(v_auth_mpk, v_pool, v_b, null) <> 'OK' then
        raise exception 'ARS-754 M-008: первая привязка (ровно до цели) не прошла';
    end if;
    v_res := pg_temp.ars754_match(v_auth_mpk, v_pool, v_b2, null);
    if v_res <> 'POOL_NOT_FILLING'
       or not exists (select 1 from public.pools where id = v_pool and matched_heads = 22) then
        raise exception 'ARS-754 M-008: вторая после точного набора — ответ %, ожидался POOL_NOT_FILLING', v_res;
    end if;
    raise notice 'ARS-754 M-008 ok: очередь по pools; вторая → BATCH_DOES_NOT_FIT / POOL_NOT_FILLING, перелива нет';

    raise notice 'ARS-754 TEST PASSED: M-001..M-008, M-018, M-019, FR-002/003/004/006/021';
end;
$$;

rollback;
