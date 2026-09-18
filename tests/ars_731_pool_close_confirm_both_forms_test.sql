-- ARS-731 / Закрытие заявки подтверждает сделку в ОБЕИХ формах записи.
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01): миграция и тест
-- идут ОДНОЙ откатываемой транзакцией, как это делал ARS-695:
--   cat supabase/migrations/20260918120000_ars_731_pool_close_confirm_both_forms.sql \
--       tests/ars_731_pool_close_confirm_both_forms_test.sql > /tmp/ars731_run.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars731_run.sql
-- Файл открывает свою транзакцию и заканчивается ROLLBACK: ни одной строки не остаётся.
-- Сторож ниже роняет прогон ДО первой записи, если файл исполняется автокоммитом.
--
-- Предмет: supabase/migrations/20260918120000_ars_731_pool_close_confirm_both_forms.sql.
-- Спек (G2 2026-09-18): Docs/AGOS-TSP-PoolClose-ConfirmBothForms-ARS-731.md.
--
-- Покрытие матрицы (id названы в КАЖДОМ утверждении — Matrix Test Audit сверяет ПО ID,
-- совпадение «по смыслу» считается непокрытым):
--   M-001 (закрывает авто-матч) · M-002 (закрывает аллокатор) · M-003 (закрывает
--   принятие оффера) · M-004 (закрывает активация заявки) · M-005 (партия с остатком).
--   Плюс FR-002 (повторный вызов ничего не меняет) и FR-016 (partial_accept=false при
--   полном наборе).
--
-- ⚠️ ОТКЛОНЕНИЕ ОТ ТЕКСТА M-004, названное вслух. Строка матрицы описывает заявку
-- «смешанную» (обе формы записи) и закрываемую свипом активации. Такое состояние
-- НЕДОСТИЖИМО: rpc_self_activate_pool_request СОЗДАЁТ заявку (insert into pools,
-- 20260726140000:48) — к моменту свипа у неё не может быть ни одной строки
-- batch_allocations. Поэтому M-004 проверяется в достижимой форме: свип закрывает
-- заявку и подтверждение идёт ЧЕРЕЗ общий вызов (а не односторонним update), что и
-- требует FR-001. Требование закрыто полностью; неточен текст сценария, а не код —
-- вынесено в Review Triage Log слайса, решение владельца не подменяется тестом.
--
-- Фикстуры СВОИ ЦЕЛИКОМ: свой регион, свои организации, свои pool_requests/pools/
-- pool_lines/batches/batch_allocations/offers. Ни одной существующей строки как фикстуру
-- не читает; общая конфигурация (tsp_config) не правится.

\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-731_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    v_region     uuid := gen_random_uuid();
    v_org_mpk    uuid := gen_random_uuid();
    v_org_farm   uuid := gen_random_uuid();   -- владелец партий, которые матчатся
    v_org_farm2  uuid := gen_random_uuid();   -- владелец «чужой» формы записи

    v_auth_mpk   uuid := gen_random_uuid();
    v_auth_farm  uuid := gen_random_uuid();
    v_user_mpk   uuid;
    v_user_farm  uuid;

    v_sku_id     uuid;
    v_grade      text;
    v_cat        text;
    v_h          int := 20;          -- голов в партии
    v_ask        int := 1200;        -- ask фермера, ₸/кг
    v_bid        int := 1300;        -- бид МПК, ₸/кг (>= ask)
    v_month      date := date_trunc('month', now())::date;

    -- M-001 · закрывает авто-матч
    v_pr1 uuid := gen_random_uuid(); v_pool1 uuid := gen_random_uuid(); v_pl1 uuid := gen_random_uuid();
    v_b1_alloc uuid := gen_random_uuid();   -- чужая форма: строка batch_allocations
    v_b1_auto  uuid := gen_random_uuid();   -- своя форма: ссылка в партии

    -- M-002 · закрывает аллокатор
    v_pr2 uuid := gen_random_uuid(); v_pool2 uuid := gen_random_uuid(); v_pl2 uuid := gen_random_uuid();
    v_b2_link  uuid := gen_random_uuid();   -- чужая форма: ссылка в партии
    v_b2_chunk uuid := gen_random_uuid();   -- своя форма: кусок

    -- M-003 · закрывает принятие оффера
    v_pr3 uuid := gen_random_uuid(); v_pool3 uuid := gen_random_uuid(); v_pl3 uuid := gen_random_uuid();
    v_b3_alloc uuid := gen_random_uuid();
    v_b3_offer uuid := gen_random_uuid();
    v_offer3   uuid := gen_random_uuid();

    -- M-004 · закрывает активация заявки
    v_pr4 uuid := gen_random_uuid();
    v_b4  uuid := gen_random_uuid();
    v_pool4 uuid;

    -- M-005 · партия с историческим остатком
    v_pr5 uuid := gen_random_uuid(); v_pool5 uuid := gen_random_uuid(); v_pl5 uuid := gen_random_uuid();
    v_b5_rest uuid := gen_random_uuid();     -- продана кусками частично, остаток на рынке
    v_b5_fill uuid := gen_random_uuid();     -- добивает цель куском

    v_alloc_b2 uuid;    -- id куска закрывающей партии M-002 (нужен приёмке в M-011)
    v_status  text;
    v_status2 text;
    v_took    int;
    v_res     jsonb;
    v_int     int;
    v_meta    jsonb;
begin
    -- ==================================================================================
    -- 1. Фикстуры общего назначения
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-731-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-731 область', 'oblast');

    insert into auth.users (id) values (v_auth_mpk), (v_auth_farm);
    select id into v_user_mpk  from public.users where auth_id = v_auth_mpk;
    select id into v_user_farm from public.users where auth_id = v_auth_farm;
    if v_user_mpk is null or v_user_farm is null then
        raise exception 'ARS-731_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_mpk,   'QA ARS-731 МПК',        'too', v_region, 'г. QA, ул. 1', null),
           (v_org_farm,  'QA ARS-731 КХ основное','kh',  v_region, 'г. QA, ул. 2', '+7 700 000 07 31'),
           (v_org_farm2, 'QA ARS-731 КХ второе',  'kh',  v_region, 'г. QA, ул. 3', '+7 700 000 07 32');

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_mpk, 'mpk'), (v_org_farm, 'farmer'), (v_org_farm2, 'farmer');

    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user_mpk, v_org_mpk, 'owner'), (v_user_farm, v_org_farm, 'owner');

    -- SKU и его сорт: авто-матч резолвит сорт партии через grade_standards
    -- (fn_tsp_batch_grade), а строку заявки — через fn_tsp_grade_for_mpk_key(category_label).
    -- Оба конца берём из живых справочников, а не из догадки (P8, L-7).
    select s.id, gs.code into v_sku_id, v_grade
    from public.tsp_skus s
    join public.grade_standards gs on gs.id = s.grade_id
    where s.is_active = true
    limit 1;
    if v_sku_id is null or v_grade is null then
        raise exception 'ARS-731_TEST_SETUP: не нашёл активный tsp_sku с сортом — фикстура недостоверна';
    end if;

    select l.category_label into v_cat
    from (select distinct category_label from public.pool_lines where category_label is not null) l
    where public.fn_tsp_grade_for_mpk_key(l.category_label) = v_grade
    limit 1;
    if v_cat is null then
        raise exception 'ARS-731_TEST_SETUP: нет category_label, дающего сорт % — фикстура недостоверна', v_grade;
    end if;

    -- ==================================================================================
    -- 2. M-001 — смешанная заявка, цель добирает rpc_self_auto_match_batch
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr1, v_org_mpk, v_h * 2, v_month, v_region, 'active');
    insert into public.pools (id, pool_request_id, organization_id, target_heads, matched_heads, status)
    values (v_pool1, v_pr1, v_org_mpk, v_h * 2, v_h, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl1, v_pool1, v_sku_id, v_cat, v_bid, v_h);

    -- чужая форма записи: партия, проданная СТРОКОЙ аллокации
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, pool_line_id, matched_heads, deal_price_per_kg)
    values (v_b1_alloc, v_org_farm2, v_sku_id, v_h, 400.00, v_month, v_region, 'matched', v_pl1, v_h, v_bid);
    insert into public.batch_allocations (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values (v_b1_alloc, v_pl1, v_pool1, v_h, v_bid, 'matched');

    -- партия, которая закроет заявку авто-матчем (пишет ссылку в самой партии)
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b1_auto, v_org_farm, v_sku_id, v_h, 400.00, v_month, v_region, 'published', v_ask);

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_self_auto_match_batch(v_b1_auto);
    execute 'reset role';

    if coalesce((v_res ->> 'matched')::boolean, false) is not true then
        raise exception 'ARS-731 M-001: авто-матч не сматчил (%). Фикстура не удовлетворяет '
                        'предикатам матча — сценарий не проверен', v_res;
    end if;

    select status into v_status from public.pools where id = v_pool1;
    if v_status <> 'closed_filled' then
        raise exception 'ARS-731 M-001: заявка %, ожидалось closed_filled', v_status;
    end if;

    select status into v_status  from public.batch_allocations where batch_id = v_b1_alloc;
    select status into v_status2 from public.batches           where id       = v_b1_auto;
    if v_status <> 'confirmed' then
        raise exception 'ARS-731 M-001: ЧУЖАЯ форма (строка аллокации) осталась в % — '
                        'ровно тот дефект, который чинит слайс', v_status;
    end if;
    if v_status2 <> 'confirmed' then
        raise exception 'ARS-731 M-001: своя форма (ссылка в партии) осталась в %', v_status2;
    end if;

    -- FR-016: при ПОЛНОМ наборе partial_accept обязан быть false, иначе слайс пишет
    -- в журнал ложь своими руками.
    select metadata into v_meta
    from public.batch_events
    where batch_id = v_b1_auto and event_type = 'confirmed'
    order by created_at desc limit 1;
    if v_meta is null then
        raise exception 'ARS-731 FR-016: события confirmed по партии нет — вызов не состоялся';
    end if;
    if coalesce((v_meta ->> 'partial_accept')::boolean, true) is not false then
        raise exception 'ARS-731 FR-016: partial_accept=% при полном наборе', v_meta ->> 'partial_accept';
    end if;

    -- FR-002: повторный вызов идемпотентен — подтверждать больше нечего.
    v_int := public.fn_tsp_pool_confirm_matches(v_pool1);
    if v_int <> 0 then
        raise exception 'ARS-731 FR-002: повторный вызов подтвердил % единиц, ожидалось 0', v_int;
    end if;

    -- ==================================================================================
    -- 3. M-002 — смешанная заявка, цель добирает fn_tsp_alloc_chunk
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr2, v_org_mpk, v_h * 2, v_month, v_region, 'active');
    insert into public.pools (id, pool_request_id, organization_id, target_heads, matched_heads, status)
    values (v_pool2, v_pr2, v_org_mpk, v_h * 2, v_h, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl2, v_pool2, v_sku_id, v_cat, v_bid, v_h);

    -- чужая форма: партия, привязанная ССЫЛКОЙ и без единой аллокации
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, pool_line_id, matched_heads, deal_price_per_kg)
    values (v_b2_link, v_org_farm2, v_sku_id, v_h, 400.00, v_month, v_region, 'matched', v_pl2, v_h, v_bid);

    -- партия, которая закроет заявку куском
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg, matched_heads)
    values (v_b2_chunk, v_org_farm, v_sku_id, v_h, 400.00, v_month, v_region, 'published', v_ask, 0);

    v_took := public.fn_tsp_alloc_chunk(v_b2_chunk, v_pl2, 'manual_match', v_user_mpk, null, v_bid);
    if v_took <> v_h then
        raise exception 'ARS-731 M-002: аллокатор взял % голов, ожидалось %', v_took, v_h;
    end if;

    select status into v_status from public.pools where id = v_pool2;
    if v_status <> 'closed_filled' then
        raise exception 'ARS-731 M-002: заявка %, ожидалось closed_filled', v_status;
    end if;

    select status into v_status from public.batches where id = v_b2_link;
    if v_status <> 'confirmed' then
        raise exception 'ARS-731 M-002: ЧУЖАЯ форма (ссылка в партии) осталась в % — '
                        'зеркальная половина того же дефекта', v_status;
    end if;
    select status into v_status from public.batch_allocations where batch_id = v_b2_chunk;
    if v_status <> 'confirmed' then
        raise exception 'ARS-731 M-002: своя форма (кусок) осталась в %', v_status;
    end if;

    -- ==================================================================================
    -- 4. M-003 — смешанная заявка, цель добирает rpc_self_accept_offer
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr3, v_org_mpk, v_h * 2, v_month, v_region, 'active');
    insert into public.pools (id, pool_request_id, organization_id, target_heads, matched_heads, status)
    values (v_pool3, v_pr3, v_org_mpk, v_h * 2, v_h, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl3, v_pool3, v_sku_id, v_cat, v_bid, v_h);

    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, pool_line_id, matched_heads, deal_price_per_kg)
    values (v_b3_alloc, v_org_farm2, v_sku_id, v_h, 400.00, v_month, v_region, 'matched', v_pl3, v_h, v_bid);
    insert into public.batch_allocations (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values (v_b3_alloc, v_pl3, v_pool3, v_h, v_bid, 'matched');

    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b3_offer, v_org_farm, v_sku_id, v_h, 400.00, v_month, v_region, 'offering', v_ask);
    insert into public.offers (id, batch_id, mpk_org_id, offered_price_per_kg, status, expires_at)
    values (v_offer3, v_b3_offer, v_org_mpk, v_ask, 'pending', now() + interval '1 day');

    -- Оффер принимает МПК, а не фермер: гейт функции проверяет offers.mpk_org_id против
    -- fn_my_org_ids (20260726140000:417). Прогон нашёл это фикстурой — claims меняем.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_mpk::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_self_accept_offer(v_offer3);
    execute 'reset role';
    if (v_res ->> 'poolId') is null then
        raise exception 'ARS-731 M-003: принятие оффера не вернуло заявку (%)', v_res;
    end if;

    select status into v_status from public.pools where id = v_pool3;
    if v_status <> 'closed_filled' then
        raise exception 'ARS-731 M-003: заявка %, ожидалось closed_filled', v_status;
    end if;
    select status into v_status from public.batch_allocations where batch_id = v_b3_alloc;
    if v_status <> 'confirmed' then
        raise exception 'ARS-731 M-003: ЧУЖАЯ форма осталась в % — путь принятия оффера '
                        'ровно тот, что при счёте «два тела» остался бы сломанным', v_status;
    end if;

    -- ==================================================================================
    -- 5. M-004 — цель добирается свипом при rpc_self_activate_pool_request
    --    (в достижимой форме — см. «ОТКЛОНЕНИЕ» в шапке файла)
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id,
                                      status, accepted_categories)
    values (v_pr4, v_org_mpk, v_h, v_month, v_region, 'draft',
            jsonb_build_array(jsonb_build_object('code', v_cat, 'price', v_bid)));

    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg)
    values (v_b4, v_org_farm, v_sku_id, v_h, 400.00, v_month, v_region, 'published', v_ask);

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_mpk::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_self_activate_pool_request(v_pr4);
    execute 'reset role';

    v_pool4 := (v_res ->> 'pool_id')::uuid;
    if v_pool4 is null then
        raise exception 'ARS-731 M-004: активация не вернула заявку (%)', v_res;
    end if;

    select status into v_status from public.pools where id = v_pool4;
    if v_status <> 'closed_filled' then
        raise exception 'ARS-731 M-004: заявка %, ожидалось closed_filled — свип не закрыл её '
                        'по набору цели, сценарий не проверен', v_status;
    end if;
    select status into v_status from public.batches where id = v_b4;
    if v_status <> 'confirmed' then
        raise exception 'ARS-731 M-004: сделка осталась в % — путь активации не подтвердил её', v_status;
    end if;
    -- Подтверждение обязано идти ЧЕРЕЗ общий вызов, а не односторонним update: событие
    -- confirmed пишет именно fn_tsp_pool_confirm_matches (FR-001/FR-016).
    if not exists (select 1 from public.batch_events
                   where batch_id = v_b4 and event_type = 'confirmed') then
        raise exception 'ARS-731 M-004: события confirmed нет — подтверждение сделано '
                        'односторонним update мимо общего вызова';
    end if;

    -- ==================================================================================
    -- 6. M-005 — партия с историческим остатком: сделка confirmed, партия остаётся
    --    partially_matched (её непроданная часть ещё продаётся)
    -- ==================================================================================
    insert into public.pool_requests (id, organization_id, total_heads, target_month, region_id, status)
    values (v_pr5, v_org_mpk, v_h * 2, v_month, v_region, 'active');
    insert into public.pools (id, pool_request_id, organization_id, target_heads, matched_heads, status)
    values (v_pool5, v_pr5, v_org_mpk, v_h * 2, v_h, 'filling');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl5, v_pool5, v_sku_id, v_cat, v_bid, v_h);

    -- партия на 2*v_h голов, продана кусками только наполовину → остаток на рынке
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, pool_line_id, matched_heads, deal_price_per_kg)
    values (v_b5_rest, v_org_farm2, v_sku_id, v_h * 2, 400.00, v_month, v_region,
            'partially_matched', v_pl5, v_h, v_bid);
    insert into public.batch_allocations (batch_id, pool_line_id, pool_id, heads, price_per_kg, status)
    values (v_b5_rest, v_pl5, v_pool5, v_h, v_bid, 'matched');

    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, farmer_price_per_kg, matched_heads)
    values (v_b5_fill, v_org_farm, v_sku_id, v_h, 400.00, v_month, v_region, 'published', v_ask, 0);

    v_took := public.fn_tsp_alloc_chunk(v_b5_fill, v_pl5, 'manual_match', v_user_mpk, null, v_bid);
    if v_took <> v_h then
        raise exception 'ARS-731 M-005: аллокатор взял % голов, ожидалось %', v_took, v_h;
    end if;

    select status into v_status from public.batch_allocations
    where batch_id = v_b5_rest and pool_id = v_pool5;
    if v_status <> 'confirmed' then
        raise exception 'ARS-731 M-005: сделка партии с остатком осталась в %', v_status;
    end if;
    select status into v_status from public.batches where id = v_b5_rest;
    if v_status <> 'partially_matched' then
        raise exception 'ARS-731 M-005: партия с непроданным остатком стала % — она снята '
                        'с рынка, хотя остаток ещё продаётся', v_status;
    end if;

    -- ==================================================================================
    -- 7. M-011 — сквозной путь: заявка закрылась набранной → фермер отгружает →
    --    комбинат подтверждает приёмку. Смысл слайса именно в этом: до него все три
    --    последних шага цепи были недостижимы, потому что сделка висела в `matched`.
    --    Берём заявку M-002 — в ней закрытие уже произошло, и обе формы подтверждены.
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_self_dispatch_ready(v_b2_chunk);
    execute 'reset role';

    select status into v_status from public.batch_allocations where batch_id = v_b2_chunk;
    if v_status <> 'dispatched' then
        raise exception 'ARS-731 M-011: после отгрузки сделка в % — фермер не смог отгрузить '
                        'то, что подтвердил слайс', v_status;
    end if;

    -- id куска читаем ДО включения роли: прямой select из связки pools под ролью
    -- authenticated падает `infinite recursion detected in policy` — рекурсия
    -- преэкзистентная, к слайсу отношения не имеет (IMPL_DEBT RLS-POOLS-RECURSION-01).
    select id into v_alloc_b2 from public.batch_allocations where batch_id = v_b2_chunk;

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_mpk::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_self_confirm_delivery_alloc(v_alloc_b2);
    execute 'reset role';

    select status into v_status from public.batch_allocations where batch_id = v_b2_chunk;
    if v_status <> 'delivered' then
        raise exception 'ARS-731 M-011: после приёмки сделка в %, ожидалось delivered', v_status;
    end if;

    perform set_config('request.jwt.claims', '{}', true);

    raise notice 'ARS-731 / Закрытие заявки в обеих формах: контракт пройден. '
                 'Закрыты M-001 M-002 M-003 M-004 M-005 M-011, FR-001 FR-002 FR-016.';
end;
$$;

rollback;
