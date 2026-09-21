-- ARS-760 / В точку решения по цене попадает только та партия, которой отказали.
-- ЧАСТЬ 1 из 2 — правило (M-001…M-006, M-011…M-013). Часть 2 — ремонт.
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01): миграция, обе
-- части теста и НАСТОЯЩИЙ скрипт ремонта идут ОДНОЙ откатываемой транзакцией. Порядок
-- обязателен: ремонт обязан лечь ПОСЛЕ фикстур части 1, иначе M-007/M-008 не проверены,
-- и ПОСЛЕ правила — этого требует FR-005.
-- Скрипт ремонта идёт ДВАЖДЫ: так M-009 (идемпотентность) проверяется на живом
-- артефакте, а не на пересказе его логики в тесте.
--   cat supabase/migrations/20260921120000_ars_760_price_decision_after_market_refusal.sql \
--       tests/ars_760_price_decision_after_market_refusal_test.sql \
--       scripts/deploy/repair_ars760_stuck_price_decision.sql \
--       scripts/deploy/repair_ars760_stuck_price_decision.sql \
--       tests/ars_760_price_decision_repair_test.sql > /tmp/ars760_run.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars760_run.sql
-- Прогон заканчивается ROLLBACK: ни одной строки не остаётся. Сторож ниже роняет
-- прогон ДО первой записи, если файл исполняется автокоммитом.
--
-- Предмет: supabase/migrations/20260921120000_ars_760_price_decision_after_market_refusal.sql
--          scripts/deploy/repair_ars760_stuck_price_decision.sql
-- Спек (G2 2026-09-21, переподписан после правки FR-001):
--          Docs/AGOS-TSP-PriceDecisionEntry-ARS-760.md
--
-- Покрытие матрицы (id назван в КАЖДОМ утверждении — Matrix Test Audit сверяет ПО ID,
-- совпадение «по смыслу» считается непокрытым):
--   часть 1 — M-001 · M-002 · M-003 · M-004 · M-005 · M-006 · M-011 · M-012 · M-013
--   часть 2 — M-007 · M-008 · M-009 · M-010
--   M-014 (снапшот контрактов) прибором имеет не этот файл, а cross_check.sh CHECK 11
--   после регистрации миграции в SQL_FILES — тестом на данных он непроверяем.
--
-- ФАЛЬСИФИЦИРУЕМОСТЬ. Без миграции слайса падает M-001 (сегодняшнее тело уводит в точку
-- решения партию без единого оффера) и M-004 (сегодня оффер не гаснет по своему сроку).
-- Отдельный прибор на ПЕТЛЮ — M-011. Отдельный прибор на выбор поля окна — M-012: его
-- оффер несёт created_at месячной давности и свежий expires_at, поэтому под окном по
-- created_at (текст FR-001 до правки 21.09) M-012 падает, под окном по expires_at проходит.
--
-- Фикстуры СВОИ ЦЕЛИКОМ: свой регион, свои организации, свои batches/offers. Ни одной
-- существующей строки как фикстуру не читает; общая конфигурация (tsp_config) не правится
-- — правило её значением больше не управляется, поэтому подкручивать порог незачем.

\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-760_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    v_region    uuid := gen_random_uuid();
    v_org_farm  uuid := gen_random_uuid();   -- владелец всех партий теста
    v_org_mpk   uuid := gen_random_uuid();   -- комбинат-автор офферов
    v_org_mpk2  uuid := gen_random_uuid();   -- второй комбинат (M-006: два статуса на одной партии)

    v_auth_farm uuid := gen_random_uuid();
    v_user_farm uuid;

    v_sku_id    uuid;
    v_h         int  := 25;
    v_ask       int  := 1400;
    v_month     date := date_trunc('month', now())::date;

    v_b1 uuid := gen_random_uuid();   -- M-001 · без интереса рынка
    v_b2 uuid := gen_random_uuid();   -- M-002 · рынок отказал
    v_b3 uuid := gen_random_uuid();   -- M-003 · оффер ещё жив
    v_b4 uuid := gen_random_uuid();   -- M-004 · частично проданная партия
    v_b5 uuid := gen_random_uuid();   -- M-005 · офферы сняты
    v_b6 uuid := gen_random_uuid();   -- M-006 · чужие статусы
    v_b7 uuid := gen_random_uuid();   -- M-007 · застряла без отказа рынка (чинит часть 2)
    v_b8 uuid := gen_random_uuid();   -- M-008 · застряла законно (часть 2 её не трогает)
    v_b9 uuid := gen_random_uuid();   -- M-011/M-012 · петля после снижения цены
    v_b10 uuid := gen_random_uuid();  -- FR-001 (окно) · оффер прошлого круга — прибор на сам член окна
    v_b11 uuid := gen_random_uuid();  -- FR-005 (зеркало) · застряла со СНЯТЫМИ офферами
    v_b12 uuid := gen_random_uuid();  -- FR-001 (второй путь) · снижение через rpc_lower_batch_price

    v_status   text;
    v_status2  text;
    v_price    int;
    v_at       timestamptz;
    v_res      jsonb;
    v_int      int;
    v_created  timestamptz;
begin
    -- ==================================================================================
    -- 1. Фикстуры общего назначения
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-760-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-760 область', 'oblast');

    insert into auth.users (id) values (v_auth_farm);
    select id into v_user_farm from public.users where auth_id = v_auth_farm;
    if v_user_farm is null then
        raise exception 'ARS-760_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations (id, legal_name, legal_form, region_id, address_text, phone)
    values (v_org_farm, 'QA ARS-760 КХ',      'kh',  v_region, 'г. QA, ул. 1', '+7 700 000 07 60'),
           (v_org_mpk,  'QA ARS-760 МПК',     'too', v_region, 'г. QA, ул. 2', null),
           (v_org_mpk2, 'QA ARS-760 МПК два', 'too', v_region, 'г. QA, ул. 3', null);

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_farm, 'farmer'), (v_org_mpk, 'mpk'), (v_org_mpk2, 'mpk');

    insert into public.user_organization_roles (user_id, organization_id, role)
    values (v_user_farm, v_org_farm, 'owner');

    select s.id into v_sku_id
    from public.tsp_skus s
    where s.is_active = true
    limit 1;
    if v_sku_id is null then
        raise exception 'ARS-760_TEST_SETUP: не нашёл активный tsp_sku — фикстура недостоверна';
    end if;

    -- ==================================================================================
    -- 2. Партии и офферы
    -- ==================================================================================
    -- M-001 · партия без интереса рынка: на рынке втрое дольше порога, офферов НОЛЬ.
    -- Возраст берём заведомо больше любого разумного значения price_decision_after_minutes:
    -- правило его больше не читает, но именно возраст был топливом старого храповика.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg, published_at)
    values (v_b1, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'published', v_ask, now() - interval '30 days');

    -- M-002 · рынок отказал: партия в рассылке, оффер просрочен по СВОЕМУ сроку.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at)
    values (v_b2, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '3 days', now() - interval '3 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b2, v_org_mpk, v_ask, 'pending', now() - interval '2 days', now() - interval '3 days');

    -- M-003 · оффер ещё жив: срок не прошёл.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at)
    values (v_b3, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '3 days', now() - interval '3 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b3, v_org_mpk, v_ask, 'pending', now() + interval '6 hours', now() - interval '1 day');

    -- M-004 · частично проданная партия: сегодня её оффер не гаснет НИКОГДА, потому что
    -- старое правило смотрело только на партии с matched_heads = 0.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                matched_heads, published_at, offering_at)
    values (v_b4, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'partially_matched', v_ask, 10, now() - interval '5 days', now() - interval '5 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b4, v_org_mpk, v_ask, 'pending', now() - interval '1 day', now() - interval '5 days');

    -- M-005 · офферы СНЯТЫ, а не отвергнуты: отказа по цене не было.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at)
    values (v_b5, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'offering', v_ask, now() - interval '4 days', now() - interval '4 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b5, v_org_mpk,  v_ask, 'withdrawn', now() - interval '2 days', now() - interval '4 days'),
           (v_b5, v_org_mpk2, v_ask, 'withdrawn', now() - interval '2 days', now() - interval '4 days');

    -- M-006 · чужие статусы с прошедшим сроком: accepted и rejected неприкосновенны.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                matched_heads, published_at, offering_at)
    values (v_b6, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'matched', v_ask, v_h, now() - interval '6 days', now() - interval '6 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b6, v_org_mpk,  v_ask, 'accepted', now() - interval '3 days', now() - interval '6 days'),
           (v_b6, v_org_mpk2, v_ask, 'rejected', now() - interval '3 days', now() - interval '6 days');

    -- M-011/M-012 · петля. Партия стоит в точке решения с ПРОТУХШИМ оффером прошлого
    -- круга. Ниже фермер снизит цену — и прежний оффер не должен утащить её обратно.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, awaiting_price_decision_at)
    values (v_b9, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '30 days', now() - interval '20 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b9, v_org_mpk, v_ask, 'expired', now() - interval '29 days', now() - interval '30 days');

    -- ==================================================================================
    -- 3. Прогон правила
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_res := public.rpc_self_review_due_batches();
    execute 'reset role';

    -- ── M-001 · партия без интереса остаётся на рынке ────────────────────────────────
    select status, farmer_price_per_kg, awaiting_price_decision_at
      into v_status, v_price, v_at
    from public.batches where id = v_b1;
    if v_status <> 'published' then
        raise exception 'ARS-760 M-001 ПРОВАЛ: партия без единого оффера ушла в «%» — '
                        'система снова трактует возраст как отказ рынка', v_status;
    end if;
    if v_price <> v_ask then
        raise exception 'ARS-760 M-001 ПРОВАЛ: цена изменилась % → % без действия фермера '
                        '(нарушен FR-004)', v_ask, v_price;
    end if;
    if v_at is not null then
        raise exception 'ARS-760 M-001 ПРОВАЛ: проставлен awaiting_price_decision_at — '
                        '«Требует решения» появилось у партии, которую никто не смотрел';
    end if;
    raise notice 'ARS-760 M-001 OK: партия без интереса рынка осталась published по цене %', v_price;

    -- ── M-002 · рынок отказал — точка решения появляется ─────────────────────────────
    select status into v_status from public.batches where id = v_b2;
    select status into v_status2 from public.offers where batch_id = v_b2;
    if v_status2 <> 'expired' then
        raise exception 'ARS-760 M-002 ПРОВАЛ: оффер с прошедшим сроком остался «%»', v_status2;
    end if;
    if v_status <> 'awaiting_price_decision' then
        raise exception 'ARS-760 M-002 ПРОВАЛ: после отказа рынка партия осталась «%» — '
                        'канонический путь BT-09 не работает', v_status;
    end if;
    raise notice 'ARS-760 M-002 OK: оффер expired, партия в точке решения';

    -- ── M-003 · оффер ещё жив — партию не трогают ────────────────────────────────────
    select status into v_status from public.batches where id = v_b3;
    select status into v_status2 from public.offers where batch_id = v_b3;
    if v_status2 <> 'pending' then
        raise exception 'ARS-760 M-003 ПРОВАЛ: живой оффер погашен раньше своего срока («%»)', v_status2;
    end if;
    if v_status <> 'offering' then
        raise exception 'ARS-760 M-003 ПРОВАЛ: партия с живым предложением ушла в «%»', v_status;
    end if;
    raise notice 'ARS-760 M-003 OK: живой оффер и партия не тронуты';

    -- ── M-004 · оффер гаснет независимо от партии ────────────────────────────────────
    select status into v_status2 from public.offers where batch_id = v_b4;
    if v_status2 <> 'expired' then
        raise exception 'ARS-760 M-004 ПРОВАЛ: на частично проданной партии оффер с прошедшим '
                        'сроком остался «%» — срок предложения снова зависит от чужой партии', v_status2;
    end if;
    select status into v_status from public.batches where id = v_b4;
    if v_status <> 'partially_matched' then
        raise exception 'ARS-760 M-004 ПРОВАЛ: статус частично проданной партии изменился на «%»', v_status;
    end if;
    raise notice 'ARS-760 M-004 OK: оффер погас по своему сроку, статус партии не тронут';

    -- ── M-005 · офферы сняты, а не отвергнуты ────────────────────────────────────────
    select status into v_status from public.batches where id = v_b5;
    if v_status <> 'offering' then
        raise exception 'ARS-760 M-005 ПРОВАЛ: партия со снятыми (withdrawn) офферами ушла в «%» — '
                        'снятие принято за отказ по цене', v_status;
    end if;
    raise notice 'ARS-760 M-005 OK: снятые офферы отказом не считаются';

    -- ── M-006 · чужие статусы неприкосновенны ────────────────────────────────────────
    select count(*) into v_int
    from public.offers
    where batch_id = v_b6 and status in ('accepted', 'rejected');
    if v_int <> 2 then
        raise exception 'ARS-760 M-006 ПРОВАЛ: из двух офферов accepted/rejected с прошедшим '
                        'сроком уцелело % — свип переписал чужой ответ', v_int;
    end if;
    raise notice 'ARS-760 M-006 OK: accepted и rejected не тронуты';

    -- ── M-013 · повтор и параллельный прогон ─────────────────────────────────────────
    -- Свип зовётся из каждой открытой вкладки раз в 20 с. Второго события по той же
    -- партии быть не должно.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_self_review_due_batches();
    perform public.rpc_self_review_due_batches();
    execute 'reset role';

    select count(*) into v_int
    from public.batch_events
    where batch_id = v_b2 and event_type = 'price_decision_due';
    if v_int <> 1 then
        raise exception 'ARS-760 M-013 ПРОВАЛ: событий price_decision_due по одной партии = % '
                        '(ожидалось 1) — повторный прогон дублирует журнал', v_int;
    end if;
    raise notice 'ARS-760 M-013 OK: три прогона подряд дали ровно одно событие';

    -- ── M-011 · снижение цены не отправляет в точку решения сразу ────────────────────
    -- Это прибор на ПЕТЛЮ: без окна прежний expired-оффер утащил бы партию обратно
    -- на первом же прогоне свипа, и фермер не показал бы рынку новую цену ни секунды.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_price(v_b9, v_ask - 100);
    perform public.rpc_self_review_due_batches();
    execute 'reset role';

    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b9;
    if v_status <> 'published' then
        raise exception 'ARS-760 M-011 ПРОВАЛ: после снижения цены партия сразу ушла в «%» — '
                        'храповик сохранился, топливом стали протухшие офферы', v_status;
    end if;
    if v_price >= v_ask then
        raise exception 'ARS-760 M-011 ПРОВАЛ: цена не снизилась (% → %) — фикстура не проверяет '
                        'то, что заявлено', v_ask, v_price;
    end if;
    raise notice 'ARS-760 M-011 OK: партия осталась published с новой ценой %', v_price;

    -- ── M-012 · новый круг проходит канонически ──────────────────────────────────────
    -- Имитируем повторную рассылку ровно так, как её делает rpc_self_auto_match_batch:
    -- строка оффера ПЕРЕИСПОЛЬЗУЕТСЯ (unique (batch_id, mpk_org_id)), обновляются status
    -- и expires_at, а created_at НЕ трогается. Круг сдвигаем назад, чтобы срок нового
    -- предложения успел истечь.
    update public.batches
    set status = 'offering', offering_at = now(), published_at = now() - interval '10 minutes'
    where id = v_b9;
    update public.offers
    set status = 'pending', expires_at = now() - interval '1 minute', responded_at = null
    where batch_id = v_b9 and mpk_org_id = v_org_mpk;

    select created_at into v_created from public.offers where batch_id = v_b9;
    if v_created > now() - interval '20 days' then
        raise exception 'ARS-760 M-012 ПРОВАЛ ФИКСТУРЫ: created_at оффера = % — он обязан '
                        'остаться от ПРОШЛОГО круга, иначе тест не отличает окно по '
                        'created_at от окна по expires_at', v_created;
    end if;

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_self_review_due_batches();
    execute 'reset role';

    select status into v_status from public.batches where id = v_b9;
    if v_status <> 'awaiting_price_decision' then
        raise exception 'ARS-760 M-012 ПРОВАЛ: после отказа рынка в НОВОМ круге партия осталась '
                        '«%». Если окно мерить по created_at, переиспользованная строка оффера '
                        'остаётся «старше» нового published_at — и BT-09 умирает для всех '
                        'повторных кругов', v_status;
    end if;
    raise notice 'ARS-760 M-012 OK: новый круг довёл партию до точки решения';

    -- ── FR-001 (окно) · протухший оффер ПРОШЛОГО круга не считается отказом ──────────
    -- Прибор на САМ ЧЛЕН окна, а не на его безвредность. Найдено ревью якоря 7:
    -- M-011 проходит на гейте статуса (после rpc_lower_price партия `published`, а шаг
    -- (б) берёт только `offering`), а M-012 проверяет, что окно НЕ МЕШАЕТ. Убери член
    -- `o.expires_at >= b.published_at` целиком — и оба всё равно проходят. Проверено
    -- прогоном: без окна зелены все 13 сценариев. Эта фикстура — единственная, которую
    -- окно обязано ИСКЛЮЧИТЬ: партия снова в рассылке (новый круг начался), а из офферов
    -- только протухший от прошлого круга.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, offering_at)
    values (v_b10, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'offering', v_ask, now(), now());
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b10, v_org_mpk, v_ask, 'expired', now() - interval '1 day', now() - interval '2 days');

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_self_review_due_batches();
    execute 'reset role';

    select status into v_status from public.batches where id = v_b10;
    if v_status <> 'offering' then
        raise exception 'ARS-760 FR-001 (окно) ПРОВАЛ: оффер ПРОШЛОГО круга (expires_at раньше '
                        'published_at) засчитан за отказ — партия ушла в «%». Храповик вернулся: '
                        'партия уходит в точку решения, не показав рынку новую цену ни секунды', v_status;
    end if;
    raise notice 'ARS-760 FR-001 (окно) OK: протухший оффер прошлого круга отказом не считается';

    -- ── FR-001 (второй путь) · rpc_lower_batch_price тоже начинает новый круг ────────
    -- Найдено ревью якоря 7: канонический rpc_lower_batch_price ставит offering
    -- БЕЗУСЛОВНО и до ARS-760 не трогал published_at — то есть протухшие офферы
    -- прошлого круга оставались в окне, и партия без подходящего МПК уезжала обратно
    -- в точку решения на первом же прогоне свипа, не показав рынку новую цену.
    -- Фикстура: партия в точке решения, единственный оффер прошлого круга — expired;
    -- подходящих МПК нет, значит ре-броадкаст даст ноль строк и партия останется
    -- в offering без единого pending — самый опасный случай.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, awaiting_price_decision_at)
    values (v_b12, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '7 days', now() - interval '5 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b12, v_org_mpk, v_ask, 'expired', now() - interval '6 days', now() - interval '7 days');

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_lower_batch_price(v_org_farm, v_b12, v_ask - 100);
    perform public.rpc_self_review_due_batches();
    execute 'reset role';

    select status, farmer_price_per_kg into v_status, v_price from public.batches where id = v_b12;
    if v_status = 'awaiting_price_decision' then
        raise exception 'ARS-760 FR-001 (второй путь) ПРОВАЛ: после rpc_lower_batch_price партия '
                        'вернулась в точку решения на первом же прогоне свипа — храповик выжил '
                        'через канонический путь снижения цены (published_at не обновлён)';
    end if;
    if v_price >= v_ask then
        raise exception 'ARS-760 FR-001 (второй путь) ПРОВАЛ ФИКСТУРЫ: цена не снизилась (% → %) — '
                        'сценарий не проверяет то, что заявлено', v_ask, v_price;
    end if;
    raise notice 'ARS-760 FR-001 (второй путь) OK: канонический rpc_lower_batch_price начал новый круг, статус «%»', v_status;

    -- ── Фикстуры для части 2 (ремонт) ────────────────────────────────────────────────
    -- Часть 2 идёт отдельным блоком ПОСЛЕ настоящего скрипта ремонта, поэтому id
    -- передаются через временную таблицу: в одной транзакции она видна обоим.
    create temp table ars760_fixtures (name text primary key, id uuid) on commit drop;

    -- M-007 · застряла без отказа рынка: в точке решения, офферов ноль.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, awaiting_price_decision_at)
    values (v_b7, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '40 days', now() - interval '35 days');

    -- M-008 · застряла ЗАКОННО: в точке решения, есть expired-оффер нынешнего круга
    -- (expires_at позже published_at — то самое окно, которым мерит FR-001).
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, awaiting_price_decision_at)
    values (v_b8, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '10 days', now() - interval '8 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b8, v_org_mpk, v_ask, 'expired', now() - interval '9 days', now() - interval '10 days');

    -- FR-005 (зеркало) · застряла со СНЯТЫМИ офферами: expired нет ни одного, поэтому
    -- новое правило её туда больше не пустит, а ремонт обязан достать. Это ровно тот
    -- класс, ради которого предикат ремонта сознательно шире, чем «ноль офферов»
    -- (FR-005). Найдено ревью якоря 7: без этой фикстуры сужение предиката ремонта до
    -- «ноль офферов» не роняло ни одного утверждения.
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg,
                                target_month, region_id, status, farmer_price_per_kg,
                                published_at, awaiting_price_decision_at)
    values (v_b11, v_org_farm, v_sku_id, v_h, 420.00, v_month, v_region,
            'awaiting_price_decision', v_ask, now() - interval '15 days', now() - interval '12 days');
    insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
    values (v_b11, v_org_mpk,  v_ask, 'withdrawn', now() - interval '13 days', now() - interval '15 days'),
           (v_b11, v_org_mpk2, v_ask, 'rejected',  now() - interval '13 days', now() - interval '15 days');

    insert into ars760_fixtures (name, id)
    values ('m007', v_b7), ('m008', v_b8), ('b9', v_b9), ('m007b', v_b11),
           ('org_farm', v_org_farm), ('auth_farm', v_auth_farm);

    raise notice 'ARS-760 часть 1 пройдена: правило работает. Дальше — настоящий скрипт ремонта.';
end;
$$;
