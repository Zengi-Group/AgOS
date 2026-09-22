-- ARS-755 / «Цену назначает фермер, и записывается ровно она».
-- SQL-прибор на матрицу слайса: что наблюдаемо в БД — проверяется здесь, остальное
-- честно названо чужим прибором (см. «Покрытие матрицы» ниже).
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01): миграция слайса и
-- этот файл идут ОДНОЙ откатываемой транзакцией. Порядок обязателен: тест обязан лечь
-- ПОСЛЕ миграции, иначе он меряет прод-тела, а не предмет слайса.
--   cat supabase/migrations/20260922140000_ars_755_farmer_owns_price.sql \
--       tests/ars_755_farmer_owns_price_test.sql > /tmp/ars755_run.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars755_run.sql
-- Прогон заканчивается ROLLBACK: ни одной строки не остаётся. Сторож ниже роняет
-- прогон ДО первой записи, если файл исполняется автокоммитом.
--
-- Предмет: supabase/migrations/20260922140000_ars_755_farmer_owns_price.sql
--          (три тела: rpc_lower_price, rpc_lower_batch_price, fn_tsp_batch_json)
-- Спек (G2 2026-09-22, подписан): Docs/AGOS-TSP-FarmerOwnsPrice-ARS-755.md
--
-- ПОКРЫТИЕ МАТРИЦЫ (id назван в КАЖДОМ утверждении — Matrix Test Audit сверяет ПО ID,
-- совпадение «по смыслу» считается непокрытым):
--   полностью — M-001 · M-002 · M-003 · M-006 · M-007 · M-009 · M-013 · M-016 · M-017 ·
--               M-018 · плюс инвариант FR-001 на нуле и null (явный INVALID_INPUT)
--   ЧАСТИЧНО  — M-008: в БД наблюдаема только половина («партия снова на рынке новым
--               кругом»: status = published и published_at = now()). Вторая половина —
--               «комбинат с бидом >= 1600 получает НОВОЕ предложение по 1600» — делает
--               ОТДЕЛЬНАЯ RPC rpc_self_auto_match_batch, которую кабинет зовёт сразу
--               после смены цены (useBatches.ts). Слайс её не трогает (FR-007), и звать
--               её здесь ради галочки значило бы проверять чужой код под чужим id.
--               Дом второй половины — прибор UI/фронта: preview фермерского кабинета и
--               qa/scenarios/05-tsp-farmer.md (ре-броадкаст после смены цены).
--   НЕ ЗДЕСЬ  — M-004 (предупреждение показано, кнопка активна) · M-005 (кнопка
--               неактивна, RPC не зовётся) · M-010 (подсказка «текущая − шаг» на экране)
--               · M-011 (текст «покупателей не нашлось») · M-012 (шторка BatchPriceSheet)
--               · M-014 (откат оптимистичного значения при обрыве) · M-015 (текст правила
--               до нажатия). Все семь — состояние ЭКРАНА, а не базы: дом — прибор
--               UI/preview фермерского кабинета (qa-agent) и qa/scenarios/05-tsp-farmer.md.
--               Серверная половина M-010 (ключ priceStepDown в JSON партии) — прибор
--               cross_check.sh CHECK 11 (контракт-снапшот contracts/rpc_return_keys.txt),
--               тестом на данных форма ответа не проверяется.
--
-- ФАЛЬСИФИЦИРУЕМОСТЬ — что именно падает БЕЗ миграции слайса (тело 20260702200000,
-- `v_new := least(v_new, v_current − v_step); v_new := greatest(v_new, 1)`):
--   M-001 — ввод 1600 при текущей 1500 схлопывается в 1400 (ровно прод-дефект 21.09);
--   M-003 — ввод 1500 при текущей 1500 схлопывается в 1400;
--   M-006 — цена меняется, и в журнал уходит price_lowered, а не returned_to_published;
--   M-007 — старое тело офферов не трогает вовсе, обе строки остаются pending;
--   M-009 — строка предложения остаётся pending, то есть принимаемой (это и есть дыра);
--   M-017 — «оставить цену» роняет цену на 1400, то есть меняет её;
--   M-016 — 1200 клэмпается ВВЕРХ к полу 1500, was_clamped = true;
--   M-018 — execute у anon (ACL до FR-017);
--   FR-001 на нуле — `greatest(v_new, 1)` молча подменяет 0 на 1 вместо отказа.
-- НЕ падают без миграции (и это сказано честно): M-002 — снижение 1500 → 1400 старое
-- тело тоже пишет как 1400; это регрессионный сторож, а не прибор на правку. M-013 —
-- статусный гейт слайс не менял, утверждение сторожит, что он НЕ сузился.
--
-- ФИКСТУРЫ СВОИ ЦЕЛИКОМ: свой регион, свои организации (КХ + два МПК), свои пользователи,
-- свои batches/offers, своя категория скота, своя строка tsp_sku_category_map и своя
-- строка minimum_prices. Ни одной существующей строки как фикстуру тест не правит.
-- Из общих справочников читается ровно один tsp_sku — и ТОЛЬКО такой, у которого ещё
-- нет активной строки в tsp_sku_category_map (иначе фикстура M-016 упёрлась бы в
-- ux_skumap_active_sku и подменила бы чужой мост). Общая конфигурация (tsp_config) не
-- правится: ценой шаг больше не распоряжается (FR-001).
--
-- ГЕЙТЫ. Тела RPC пускают по fn_my_org_ids(); под ролью postgres этот путь пуст, поэтому
-- вызовы идут тем же приёмом, что в tests/ars_760_price_decision_after_market_refusal_test.sql:
-- set_config('request.jwt.claims', …) + `set local role authenticated`, затем `reset role`.

\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-755_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    v_region    uuid := gen_random_uuid();
    v_org_farm  uuid := gen_random_uuid();   -- владелец всех партий теста
    v_org_mpk   uuid := gen_random_uuid();   -- комбинат №1 (его оффер принимает M-009)
    v_org_mpk2  uuid := gen_random_uuid();   -- комбинат №2 (вторая строка для M-007)

    v_auth_farm uuid := gen_random_uuid();
    v_auth_mpk  uuid := gen_random_uuid();
    v_user_farm uuid;
    v_user_mpk  uuid;

    v_sku_id    uuid;
    v_cat_id    uuid := gen_random_uuid();   -- своя категория скота (мост для M-016)
    v_h         int  := 25;
    v_ask       int  := 1500;                -- «текущая» цена во всех сценариях матрицы
    v_up        int  := 1600;                -- подъём (M-001, M-007, M-008, M-009)
    v_down      int  := 1400;                -- снижение (M-002)
    v_floor     int  := 1500;                -- пол для второй двери (M-016)
    v_below     int  := 1200;                -- ввод НИЖЕ пола (M-016)
    v_month     date := date_trunc('month', now())::date;

    v_b1   uuid := gen_random_uuid();   -- M-001 · подъём 1500 → 1600
    v_b2   uuid := gen_random_uuid();   -- M-002 · снижение 1500 → 1400
    v_b3   uuid := gen_random_uuid();   -- M-003 · та же цена вводом
    v_b6   uuid := gen_random_uuid();   -- M-006 · «оставить цену и ждать»
    v_b7   uuid := gen_random_uuid();   -- M-007 / M-008 / M-009 · подъём при двух pending
    v_b13a uuid := gen_random_uuid();   -- M-013 · партия published
    v_b13b uuid := gen_random_uuid();   -- M-013 · партия offering
    v_b16  uuid := gen_random_uuid();   -- M-016 · вторая дверь и пол
    v_b17  uuid := gen_random_uuid();   -- M-017 · цена не изменилась, оффер жив
    v_b0   uuid := gen_random_uuid();   -- FR-001 · ноль и null

    v_off_mpk1 uuid := gen_random_uuid();   -- оффер комбината №1 по партии v_b7
    v_off_mpk2 uuid := gen_random_uuid();   -- оффер комбината №2 по партии v_b7
    v_off_17   uuid := gen_random_uuid();   -- единственный живой оффер партии v_b17

    v_status   text;
    v_status2  text;
    v_price    int;
    v_deal     int;
    v_at       timestamptz;
    v_at2      timestamptz;
    v_pub      timestamptz;
    v_int      int;
    v_res      jsonb;
    v_meta     jsonb;
    v_check    int;
    v_oid      oid;
    v_caught   text;
    v_sqlstate text;
begin
    -- ==================================================================================
    -- 1. Фикстуры общего назначения
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-755-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-755 область', 'oblast');

    insert into auth.users (id) values (v_auth_farm), (v_auth_mpk);
    select id into v_user_farm from public.users where auth_id = v_auth_farm;
    select id into v_user_mpk  from public.users where auth_id = v_auth_mpk;
    if v_user_farm is null or v_user_mpk is null then
        raise exception 'ARS-755_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_farm, 'QA ARS-755 КХ',      'kh',  v_region, 'г. QA, ул. 1', '+7 700 000 07 55'),
           (v_org_mpk,  'QA ARS-755 МПК',     'too', v_region, 'г. QA, ул. 2', null),
           (v_org_mpk2, 'QA ARS-755 МПК два', 'too', v_region, 'г. QA, ул. 3', null);

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_farm, 'farmer'), (v_org_mpk, 'mpk'), (v_org_mpk2, 'mpk');

    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user_farm, v_org_farm, 'owner'),
           (v_user_mpk,  v_org_mpk,  'owner');

    -- SKU берём ТОЛЬКО без активного моста: свою строку tsp_sku_category_map (M-016)
    -- иначе не завести — ux_skumap_active_sku держит один активный мост на SKU, и тест
    -- начал бы править чужую справочную строку.
    select s.id into v_sku_id
    from public.tsp_skus s
    where s.is_active = true
      and not exists (
          select 1 from public.tsp_sku_category_map m
          where m.tsp_sku_id = s.id and m.is_active = true
      )
    limit 1;
    if v_sku_id is null then
        raise exception 'ARS-755_TEST_SETUP: не нашёл активный tsp_sku БЕЗ активного моста '
                        'в tsp_sku_category_map — фикстура M-016 недостоверна';
    end if;

    -- ==================================================================================
    -- 2. Партии и предложения
    -- ==================================================================================
    -- Все партии — в точке решения по цене (кроме M-013), цена 1500, круг открыт давно:
    -- так видно, что published_at обновляется вызовом, а не остаётся прежним.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, awaiting_price_decision_at)
    values (v_b1,  v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '2 days'),
           (v_b2,  v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '2 days'),
           (v_b3,  v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '2 days'),
           (v_b7,  v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '2 days'),
           (v_b16, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '2 days'),
           (v_b17, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '2 days'),
           (v_b0,  v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '2 days');

    -- M-006 · «Оставить цену и ждать»: партия пришла в точку решения ИЗ рассылки,
    -- поэтому у неё проставлены оба штампа — прибор увидит, что гаснут оба.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at, awaiting_price_decision_at)
    values (v_b6, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask,
            now() - interval '10 days', now() - interval '9 days', now() - interval '2 days');

    -- M-013 · смена цены ВНЕ точки решения: партия на рынке и партия в рассылке.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at)
    values (v_b13a, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'published', v_ask, now() - interval '1 day');
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at)
    values (v_b13b, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '1 day', now() - interval '1 day');

    -- M-007 / M-009 · два ЖИВЫХ предложения по старой цене 1500.
    insert into public.offers (id, batch_id, mpk_org_id, offered_price_per_kg, status,
                               expires_at, created_at)
    values (v_off_mpk1, v_b7, v_org_mpk,  v_ask, 'pending',
            now() + interval '12 hours', now() - interval '1 day'),
           (v_off_mpk2, v_b7, v_org_mpk2, v_ask, 'pending',
            now() + interval '12 hours', now() - interval '1 day');

    -- M-017 · один живой оффер у партии, где цена НЕ изменится.
    insert into public.offers (id, batch_id, mpk_org_id, offered_price_per_kg, status,
                               expires_at, created_at)
    values (v_off_17, v_b17, v_org_mpk, v_ask, 'pending',
            now() + interval '12 hours', now() - interval '1 day');

    -- ==================================================================================
    -- 3. M-001 · подъём цены: 1500 → 1600 записывается как 1600, НЕ как 1400
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b1, v_up);
    execute 'reset role';

    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b1;
    if v_price <> v_up then
        raise exception 'ARS-755 M-001 ПРОВАЛ: фермер назвал % — в базе %. Названная цена '
                        'подменена (при старом теле здесь ровно % = current − step, '
                        'прод-дефект 21.09)', v_up, v_price, v_ask - 100;
    end if;
    if v_status <> 'published' then
        raise exception 'ARS-755 M-001 ПРОВАЛ: после подъёма цены партия в «%», а не published '
                        '— на рынок она не вернулась', v_status;
    end if;
    raise notice 'ARS-755 M-001 OK: подъём 1500 → % записан ровно, партия published', v_price;

    -- ==================================================================================
    -- 4. M-002 · снижение: 1500 → 1400 записывается как 1400
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b2, v_down);
    execute 'reset role';

    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b2;
    if v_price <> v_down then
        raise exception 'ARS-755 M-002 ПРОВАЛ: снижение до % записано как % — снятие зажима '
                        'сломало обычное понижение', v_down, v_price;
    end if;
    if v_status <> 'published' then
        raise exception 'ARS-755 M-002 ПРОВАЛ: после снижения цены партия в «%», а не published', v_status;
    end if;
    raise notice 'ARS-755 M-002 OK: снижение 1500 → % записано ровно', v_price;

    -- ==================================================================================
    -- 5. M-003 · та же цена вводом: 1500 → 1500, партия снова на рынке
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b3, v_ask);
    execute 'reset role';

    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b3;
    if v_price <> v_ask then
        raise exception 'ARS-755 M-003 ПРОВАЛ: фермер ввёл ту же цену % — в базе %. Сохранение '
                        'цены механически невозможно (старое тело роняло её на current − step)',
                        v_ask, v_price;
    end if;
    if v_status <> 'published' then
        raise exception 'ARS-755 M-003 ПРОВАЛ: после ввода той же цены партия в «%» — на рынок '
                        'она не вернулась', v_status;
    end if;
    raise notice 'ARS-755 M-003 OK: та же цена % записана как есть, партия published', v_price;

    -- ==================================================================================
    -- 6. M-006 · «Оставить цену и ждать»: возврат на рынок без смены цены
    -- ==================================================================================
    select published_at into v_pub from public.batches where id = v_b6;

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b6, v_ask);
    execute 'reset role';

    select status, farmer_price_per_kg, awaiting_price_decision_at, offering_at, published_at
      into v_status, v_price, v_at, v_at2, v_pub
    from public.batches where id = v_b6;
    if v_status <> 'published' then
        raise exception 'ARS-755 M-006 ПРОВАЛ: «оставить цену и ждать» оставило партию в «%» — '
                        'обещание «партия остаётся в продаже» снова неправда', v_status;
    end if;
    if v_price <> v_ask then
        raise exception 'ARS-755 M-006 ПРОВАЛ: цена изменилась % → % действием, которое обещает '
                        'её НЕ менять', v_ask, v_price;
    end if;
    if v_at is not null then
        raise exception 'ARS-755 M-006 ПРОВАЛ: awaiting_price_decision_at не снят (%) — партия '
                        'осталась помеченной как «требует решения»', v_at;
    end if;
    if v_at2 is not null then
        raise exception 'ARS-755 M-006 ПРОВАЛ: offering_at не снят (%) — штамп прошлого круга '
                        'рассылки пережил возврат на рынок', v_at2;
    end if;
    if v_pub < now() - interval '1 second' then
        raise exception 'ARS-755 M-006 ПРОВАЛ: published_at = % не обновлён — новый круг торга '
                        'не начался, и партия уедет обратно в точку решения на первом свипе', v_pub;
    end if;

    select count(*) into v_int
    from public.batch_events
    where batch_id = v_b6 and event_type = 'returned_to_published';
    if v_int <> 1 then
        raise exception 'ARS-755 M-006 ПРОВАЛ: событий returned_to_published = % (ожидалась ровно '
                        'одна) — журнал не отличает возврат на рынок от смены цены', v_int;
    end if;
    select count(*) into v_int
    from public.batch_events
    where batch_id = v_b6 and event_type = 'price_lowered';
    if v_int <> 0 then
        raise exception 'ARS-755 M-006 ПРОВАЛ: в журнал ушло price_lowered (% шт.) при неизменной '
                        'цене — событие лжёт о том, чего не было', v_int;
    end if;
    raise notice 'ARS-755 M-006 OK: партия published по цене %, оба штампа сняты, ровно одно '
                 'событие returned_to_published', v_price;

    -- ==================================================================================
    -- 7. M-007 · фактическая смена цены гасит старые предложения
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b7, v_up);
    execute 'reset role';

    select count(*) into v_int
    from public.offers
    where batch_id = v_b7 and status = 'withdrawn';
    if v_int <> 2 then
        raise exception 'ARS-755 M-007 ПРОВАЛ: после подъёма 1500 → % погашено % предложений из 2 '
                        '— строки со старой ценой остались живыми, и сделка может уйти по цене, '
                        'которую фермер уже отменил', v_up, v_int;
    end if;
    select count(*) into v_int
    from public.offers
    where batch_id = v_b7 and status = 'pending';
    if v_int <> 0 then
        raise exception 'ARS-755 M-007 ПРОВАЛ: живых (pending) предложений по старой цене осталось %', v_int;
    end if;
    raise notice 'ARS-755 M-007 OK: обе строки предложений погашены в withdrawn';

    -- ==================================================================================
    -- 8. M-008 · новый круг по новой цене — ЧАСТИЧНО (см. шапку)
    -- ==================================================================================
    -- В БД наблюдаемо ровно это: партия вернулась на рынок и круг торга начат заново
    -- (published_at = now()). Рассылку по новой цене делает ОТДЕЛЬНАЯ RPC
    -- rpc_self_auto_match_batch, которую зовёт кабинет сразу после смены цены; слайс её
    -- не трогает (FR-007), поэтому здесь она НЕ зовётся — иначе тест мерил бы чужой код
    -- под id M-008. Вторая половина («у комбината с бидом >= 1600 появляется новое
    -- предложение по 1600») — прибор UI/фронта: preview кабинета и qa/scenarios/05-tsp-farmer.md.
    select status, farmer_price_per_kg, published_at into v_status, v_price, v_pub
    from public.batches where id = v_b7;
    if v_status <> 'published' then
        raise exception 'ARS-755 M-008 (частично) ПРОВАЛ: после смены цены партия в «%» — новый '
                        'круг по новой цене начаться не может', v_status;
    end if;
    if v_price <> v_up then
        raise exception 'ARS-755 M-008 (частично) ПРОВАЛ: в новый круг партия уходит по цене %, '
                        'а фермер назвал %', v_price, v_up;
    end if;
    if v_pub < now() - interval '1 second' then
        raise exception 'ARS-755 M-008 (частично) ПРОВАЛ: published_at = % не обновлён — круг '
                        'торга не перезапущен, новая цена не получит своего времени на рынке', v_pub;
    end if;
    raise notice 'ARS-755 M-008 OK ЧАСТИЧНО: партия published по % с новым published_at. '
                 'Ре-броадкаст (rpc_self_auto_match_batch) — прибор UI/фронта, здесь не проверяется', v_price;

    -- ==================================================================================
    -- 9. M-009 · сделка по отменённой цене невозможна
    -- ==================================================================================
    -- Живая функция принятия — rpc_self_accept_offer(p_offer_id uuid) returns jsonb
    -- (последнее тело: 20260918120000_ars_731_pool_close_confirm_both_forms.sql:495).
    -- Гейт статуса строки стоит ДО гейта статуса партии, поэтому погашенная строка
    -- отбивается своим INVALID_STATUS (errcode P0003).
    select status into v_status2 from public.offers where id = v_off_mpk1;
    if v_status2 <> 'withdrawn' then
        raise exception 'ARS-755 M-009 ПРОВАЛ ФИКСТУРЫ: строка предложения по старой цене в «%», '
                        'а не withdrawn — проверять нечего, дыра ещё открыта', v_status2;
    end if;

    v_caught := null;
    begin
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_mpk::text, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        perform public.rpc_self_accept_offer(v_off_mpk1);
        execute 'reset role';
        raise exception 'ARS-755 M-009 ПРОВАЛ: комбинат ПРИНЯЛ погашенную строку предложения — '
                        'сделка ушла по цене %, которую фермер уже отменил', v_ask;
    exception
        when others then
            if sqlerrm like 'ARS-755 M-009 ПРОВАЛ%' then
                raise;
            end if;
            v_caught   := sqlerrm;
            v_sqlstate := sqlstate;
    end;
    execute 'reset role';

    if v_caught not like 'INVALID_STATUS%' then
        raise exception 'ARS-755 M-009 ПРОВАЛ: принятие отбито НЕ тем отказом: «%» (sqlstate %). '
                        'Ожидался INVALID_STATUS по статусу строки предложения',
                        v_caught, v_sqlstate;
    end if;

    select status, deal_price_per_kg into v_status, v_deal from public.batches where id = v_b7;
    if v_status = 'matched' or v_deal is not null then
        raise exception 'ARS-755 M-009 ПРОВАЛ: сделка всё же состоялась — статус «%», цена сделки % '
                        '(ожидалось: сделки нет)', v_status, v_deal;
    end if;
    select status into v_status2 from public.offers where id = v_off_mpk1;
    if v_status2 <> 'withdrawn' then
        raise exception 'ARS-755 M-009 ПРОВАЛ: после отказа строка предложения стала «%» — '
                        'состояние изменилось отклонённой попыткой', v_status2;
    end if;
    raise notice 'ARS-755 M-009 OK: принятие погашенной строки отбито («%»), сделки нет', v_caught;

    -- ==================================================================================
    -- 10. M-013 · смена цены вне точки решения по-прежнему разрешена
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b13a, v_up);   -- партия на рынке
    perform public.rpc_lower_price(v_b13b, v_up);   -- партия в рассылке
    execute 'reset role';

    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b13a;
    if v_status <> 'published' or v_price <> v_up then
        raise exception 'ARS-755 M-013 ПРОВАЛ: у партии published смена цены дала «%» / % — '
                        'статусный гейт сузился или цена подменена', v_status, v_price;
    end if;
    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b13b;
    if v_status <> 'published' or v_price <> v_up then
        raise exception 'ARS-755 M-013 ПРОВАЛ: у партии offering смена цены дала «%» / % — '
                        'статусный гейт сузился или цена подменена', v_status, v_price;
    end if;
    raise notice 'ARS-755 M-013 OK: смена цены прошла и из published, и из offering — гейт не сузился';

    -- ==================================================================================
    -- 11. M-016 · вторая дверь (rpc_lower_batch_price) не подменяет цену полом
    -- ==================================================================================
    -- Таблица minimum_prices на проде пуста (аудит TSP-PRICEFLOOR-01), поэтому СВОЯ строка
    -- обязательна: без неё «не сработало» и «нечему было срабатывать» неразличимы.
    -- Заводим свою категорию, свой мост SKU → категория и свой пол 1500 по СВОЕМУ региону.
    insert into public.livestock_categories (id, code, name_ru)
    values (v_cat_id, 'QA-755-' || substr(replace(v_cat_id::text, '-', ''), 1, 8),
            'QA ARS-755 категория');

    insert into public.tsp_sku_category_map (tsp_sku_id, category_id, is_active)
    values (v_sku_id, v_cat_id, true);

    insert into public.minimum_prices (category_id, region_id, price_per_kg, valid_from, is_active)
    values (v_cat_id, v_region, v_floor, current_date - 1, true);

    -- Потенция фикстуры: повторяем РАЗРЕШЕНИЕ пола ровно так, как его делает тело RPC.
    -- Если здесь null — строка теста ничего не доказывает, и это провал фикстуры, а не кода.
    select mp.price_per_kg into v_check
    from public.tsp_sku_category_map m
    join public.minimum_prices mp on mp.category_id = m.category_id
    join public.batches b on b.id = v_b16
    where m.tsp_sku_id = b.tsp_sku_id
      and m.is_active  = true
      and mp.is_active = true
      and (mp.region_id = b.region_id or mp.region_id is null)
      and (mp.valid_to is null or mp.valid_to >= current_date)
    order by (mp.region_id = b.region_id) desc nulls last, mp.valid_from desc
    limit 1;
    if v_check is distinct from v_floor then
        raise exception 'ARS-755 M-016 ПРОВАЛ ФИКСТУРЫ: пол для партии разрешился в % (ожидалось %) '
                        '— «пол не сработал» было бы неотличимо от «пола не было»', v_check, v_floor;
    end if;

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_lower_batch_price(v_org_farm, v_b16, v_below);
    execute 'reset role';

    select farmer_price_per_kg into v_price from public.batches where id = v_b16;
    if v_price <> v_below then
        raise exception 'ARS-755 M-016 ПРОВАЛ: на второй двери названа цена %, записана % (пол %) '
                        '— инвариант FR-001 верен на одной двери из двух, то есть не инвариант',
                        v_below, v_price, v_floor;
    end if;
    if (v_res->>'new_price')::int <> v_below then
        raise exception 'ARS-755 M-016 ПРОВАЛ: в ответе new_price = %, а фермер назвал %',
                        v_res->>'new_price', v_below;
    end if;
    if (v_res->>'was_clamped')::boolean is distinct from false then
        raise exception 'ARS-755 M-016 ПРОВАЛ: was_clamped = % — функция сообщает о подмене цены, '
                        'которой после FR-016 быть не может', v_res->>'was_clamped';
    end if;

    -- Пол остался ОРИЕНТИРОМ в журнале (FR-016): это второй прибор на потенцию фикстуры —
    -- тело действительно видело пол и всё равно записало названную цену.
    select metadata into v_meta
    from public.batch_events
    where batch_id = v_b16 and event_type = 'price_lowered'
    order by created_at desc limit 1;
    if (v_meta->>'floor_price_per_kg')::int is distinct from v_floor then
        raise exception 'ARS-755 M-016 ПРОВАЛ ФИКСТУРЫ: в журнале floor_price_per_kg = % '
                        '(ожидалось %) — тело RPC пола не увидело, значит и клэмпать было нечего',
                        v_meta->>'floor_price_per_kg', v_floor;
    end if;
    raise notice 'ARS-755 M-016 OK: при поле % записана названная цена %, was_clamped = false',
                 v_floor, v_price;

    -- ==================================================================================
    -- 12. M-017 · цена не изменилась — живое предложение не гасится
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b17, v_ask);
    execute 'reset role';

    select status into v_status2 from public.offers where id = v_off_17;
    if v_status2 <> 'pending' then
        raise exception 'ARS-755 M-017 ПРОВАЛ: при НЕизменной цене живое предложение стало «%» — '
                        'действие, обещающее «партия остаётся в продаже», убило живой интерес рынка',
                        v_status2;
    end if;
    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b17;
    if v_status <> 'published' or v_price <> v_ask then
        raise exception 'ARS-755 M-017 ПРОВАЛ: партия «%» по цене % (ожидалось published по %)',
                        v_status, v_price, v_ask;
    end if;
    raise notice 'ARS-755 M-017 OK: предложение осталось pending, партия published по %', v_price;

    -- ==================================================================================
    -- 13. M-018 · права второй двери после применения миграции
    -- ==================================================================================
    -- Проверяем МЕХАНИЗМ, а не пересказ: pg_proc.proacl + has_function_privilege.
    if not exists (select 1 from pg_roles where rolname = 'anon')
       or not exists (select 1 from pg_roles where rolname = 'service_role')
       or not exists (select 1 from pg_roles where rolname = 'authenticated') then
        raise exception 'ARS-755 M-018 ПРОВАЛ ФИКСТУРЫ: в базе нет одной из ролей '
                        'anon/authenticated/service_role — ACL сверять не с чем';
    end if;

    -- Адресуем функцию по СИГНАТУРЕ типов (regprocedure), а не по тексту
    -- pg_get_function_identity_arguments: тот отдаёт список ВМЕСТЕ с именами параметров
    -- ('p_organization_id uuid, …'), и сверка с 'uuid, uuid, integer' молча не находит
    -- ничего — прибор превращается в проверку собственной строки.
    begin
        v_oid := 'public.rpc_lower_batch_price(uuid,uuid,integer)'::regprocedure::oid;
    exception
        when others then
            raise exception 'ARS-755 M-018 ПРОВАЛ: функции public.rpc_lower_batch_price(uuid, uuid, integer) '
                            'в базе нет — сверять ACL не с чем («%»)', sqlerrm;
    end;

    if not has_function_privilege('authenticated', v_oid, 'execute') then
        raise exception 'ARS-755 M-018 ПРОВАЛ: у authenticated НЕТ execute на rpc_lower_batch_price '
                        '— revoke снёс доступ вебу';
    end if;
    if not has_function_privilege('service_role', v_oid, 'execute') then
        raise exception 'ARS-755 M-018 ПРОВАЛ: у service_role НЕТ execute на rpc_lower_batch_price '
                        '— AI-шлюз ходит сервисным аккаунтом (P-AI-6) и остался без второй двери';
    end if;
    if has_function_privilege('anon', v_oid, 'execute') then
        raise exception 'ARS-755 M-018 ПРОВАЛ: у anon ЕСТЬ execute на rpc_lower_batch_price — '
                        'revoke FR-017 не лёг, защита снова в один слой';
    end if;
    select count(*) into v_int
    from pg_proc p, aclexplode(p.proacl) a
    where p.oid = v_oid and a.grantee = 0 and a.privilege_type = 'EXECUTE';
    if v_int <> 0 then
        raise exception 'ARS-755 M-018 ПРОВАЛ: в proacl осталась запись EXECUTE для PUBLIC '
                        '(% шт.) — право у всех ролей разом', v_int;
    end if;
    raise notice 'ARS-755 M-018 OK: execute есть у authenticated и service_role, нет у anon и PUBLIC';

    -- ==================================================================================
    -- 14. FR-001 на нуле · ноль и null отбиваются явным INVALID_INPUT
    -- ==================================================================================
    -- Прежний `greatest(v_new, 1)` молча превращал 0 в 1 — подмена названной цены, ровно
    -- то, что слайс лечит. Теперь стоит явный raise (фронт до этого не доводит, M-005).
    v_caught := null;
    begin
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        perform public.rpc_lower_price(v_b0, 0);
        execute 'reset role';
        raise exception 'ARS-755 FR-001 (ноль) ПРОВАЛ: цена 0 принята без отказа — названная цена '
                        'снова подменяется молча';
    exception
        when others then
            if sqlerrm like 'ARS-755 FR-001%' then
                raise;
            end if;
            v_caught := sqlerrm;
    end;
    execute 'reset role';
    if v_caught not like 'INVALID_INPUT%' then
        raise exception 'ARS-755 FR-001 (ноль) ПРОВАЛ: отказ пришёл не тот: «%» (ожидался INVALID_INPUT)',
                        v_caught;
    end if;

    v_caught := null;
    begin
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        perform public.rpc_lower_price(v_b0, null);
        execute 'reset role';
        raise exception 'ARS-755 FR-001 (null) ПРОВАЛ: цена null принята без отказа';
    exception
        when others then
            if sqlerrm like 'ARS-755 FR-001%' then
                raise;
            end if;
            v_caught := sqlerrm;
    end;
    execute 'reset role';
    if v_caught not like 'INVALID_INPUT%' then
        raise exception 'ARS-755 FR-001 (null) ПРОВАЛ: отказ пришёл не тот: «%» (ожидался INVALID_INPUT)',
                        v_caught;
    end if;

    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b0;
    if v_status <> 'awaiting_price_decision' or v_price <> v_ask then
        raise exception 'ARS-755 FR-001 (ноль/null) ПРОВАЛ: отклонённый вызов всё же изменил партию: '
                        '«%» / % (ожидалось awaiting_price_decision / %)', v_status, v_price, v_ask;
    end if;
    raise notice 'ARS-755 FR-001 (ноль и null) OK: оба вызова отбиты INVALID_INPUT, партия не тронута';

    -- ── M-010 (серверная половина) · ключ шага доезжает до экрана ───────────────
    -- Прибор добавлен по находке ревью якоря 7. Изначально эта половина была приписана
    -- CHECK 11, но снапшот контрактов пропускает всё, что не начинается с `rpc_`
    -- (scripts/contract_snapshot.py:83), а тут `fn_`. То есть пропажа ключа не падала
    -- НИГДЕ: снапшот её не видит, экранный тест берёт priceStepDown из своей фикстуры,
    -- а на живом экране у фермера молча исчезает кнопка «Снизить и предложить снова»
    -- (нет ключа → фронт подсказку не рисует, BatchScreen.tsx).
    if not (public.fn_tsp_batch_json(v_b1) ? 'priceStepDown') then
        raise exception 'ARS-755 M-010 ПРОВАЛ: в JSON партии нет ключа priceStepDown — '
                        'подсказка шага до экрана не доедет, и фермер останется без кнопки снижения';
    end if;
    if (public.fn_tsp_batch_json(v_b1) ->> 'priceStepDown') is null then
        raise exception 'ARS-755 M-010 ПРОВАЛ: ключ priceStepDown пуст — фолбэк FR-005 '
                        '(coalesce …, 100) не сработал';
    end if;
    raise notice 'ARS-755 M-010 (серверная половина) OK: ключ priceStepDown есть и непуст (%)',
                 (public.fn_tsp_batch_json(v_b1) ->> 'priceStepDown');

    raise notice 'ARS-755: матрица пройдена — M-001 · M-002 · M-003 · M-006 · M-007 · '
                 'M-008 (частично) · M-009 · M-010 (серверная половина) · M-013 · M-016 · '
                 'M-017 · M-018 · FR-001 (ноль/null)';
end;
$$;

rollback;
