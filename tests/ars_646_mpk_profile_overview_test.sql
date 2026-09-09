-- ARS-646 / MP-2.2 — регрессионный контракт агрегата «Обзора» профиля МПК.
-- Спека: Docs/AGOS-MPK-Profile-OverviewRPC-ARS-646.md · контракт ответа: Dok3 RPC-64.
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01):
--   psql "$DATABASE_URL" -f tests/ars_646_mpk_profile_overview_test.sql
-- Файл открывает свою транзакцию и заканчивается ROLLBACK: ни одной строки в базе не
-- остаётся. Сторож ниже роняет прогон ДО первой записи, если файл всё же исполняется
-- автокоммитом.
--
-- Фикстуры СВОИ ЦЕЛИКОМ: тест создаёт своих auth.users (public.users делает триггер
-- trg_on_auth_user_created), свои организации, свой регион, свою заявку/пул/партию и
-- ВЫДАЁТ права себе. Ни одной существующей строки он не читает как фикстуру и не меняет.
--
-- Покрытие матрицы (id названы в каждом утверждении — Matrix Test Audit сверяет ПО ID,
-- совпадение «по смыслу» считается непокрытым):
--   поведенчески: M-001 M-002 M-003 M-004 M-005 M-006 M-007 M-008 M-009 M-010 M-011
--                 M-012 M-014 M-020
--   плюс требования, наблюдаемые отдельно от матрицы: FR-002 (ОБА пути доступа, включая
--                 админа TURAN), FR-018 (staff_active), FR-023 (три ключа признаком),
--                 FR-024 (владение через pools.organization_id — сторож: пул с
--                 pool_request_id = null), admission=restricted при истёкшем членстве
--   структурно  : M-013 — инсценировать внутренний сбой чтения нечем (тот же класс, что
--                 ARS-362 M-011: statement_timeout не ловится `when others`, а DDL по живой
--                 таблице берёт ACCESS EXCLUSIVE на боевой базе). В пакете G3 строка идёт
--                 как СТРУКТУРНАЯ, а не как закрытая поведением.
--   в отставке (проверок нет и не должно быть): M-015 M-016 M-017 M-018 M-019 — сняты
--                 вместе со счётом сделок 2026-09-09.

-- Без этой строки сторож ниже БЕСПОЛЕЗЕН: по умолчанию psql печатает ошибку и идёт к
-- следующему statement'у, то есть исполняет блок фикстур, который сторож и должен был
-- остановить.
\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-646_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    v_region       uuid := gen_random_uuid();
    -- организации
    v_org_a        uuid := gen_random_uuid();   -- МПК: допущена, членство истекает, правки, скрытый отзыв
    v_org_b        uuid := gen_random_uuid();   -- МПК чужая (M-002)
    v_org_c        uuid := gen_random_uuid();   -- НЕ МПК (M-011)
    v_org_d        uuid := gen_random_uuid();   -- МПК без данных верификации (M-005)
    v_org_e        uuid := gen_random_uuid();   -- МПК чистая: ничего не требует действий (M-009)
    v_org_farm     uuid := gen_random_uuid();   -- хозяйство-поставщик (автор скрытого отзыва)
    v_org_ghost    uuid := gen_random_uuid();   -- НЕ создаётся вовсе
    -- пользователи
    v_auth_admin   uuid := gen_random_uuid();   -- mpk_admin в org_a/c/d/e
    v_auth_view    uuid := gen_random_uuid();   -- viewer в org_a — БЕЗ mpk.review.submit
    v_auth_turan   uuid := gen_random_uuid();   -- админ TURAN, ни в одной организации
    v_auth_out     uuid := gen_random_uuid();   -- посторонний
    v_user_admin   uuid;
    v_user_view    uuid;
    v_user_turan   uuid;
    v_user_out     uuid;
    -- сделочная фикстура (легаси-маршрут: партия без кусков)
    v_request      uuid := gen_random_uuid();
    v_pool         uuid := gen_random_uuid();
    v_line         uuid := gen_random_uuid();
    v_batch        uuid := gen_random_uuid();   -- закрытая сделка, МЫ НЕ оценили → пункт
    v_batch2       uuid := gen_random_uuid();   -- закрытая сделка, МЫ оценили → пункта нет
    v_batch3       uuid := gen_random_uuid();   -- закрытая сделка МАРШРУТОМ ① (через куски)
    v_org_farm2    uuid := gen_random_uuid();   -- второе хозяйство (маршрут ①)
    v_org_f        uuid := gen_random_uuid();   -- МПК: верификация есть, членство ИСТЕКЛО → restricted
    v_memb_f       uuid;
    v_p95          numeric;
    v_memb_a       uuid;
    v_memb_e       uuid;
    -- результаты
    v_res          jsonb;
    v_err          text;
    v_state        text;
    v_att          jsonb;
    v_gate         jsonb;
    v_t0           timestamptz;
    v_ms           numeric;
    v_i            int;
begin
    -- ==================================================================================
    -- 0. Гранты и маркеры объявления.
    -- ==================================================================================
    if has_function_privilege('anon', 'public.rpc_get_mpk_profile_overview(uuid)', 'execute') then
        raise exception 'ARS-646: anon может исполнять агрегат «Обзора»';
    end if;
    if not has_function_privilege('authenticated', 'public.rpc_get_mpk_profile_overview(uuid)', 'execute') then
        raise exception 'ARS-646: authenticated не может исполнять агрегат «Обзора»';
    end if;
    if not has_function_privilege('service_role', 'public.rpc_get_mpk_profile_overview(uuid)', 'execute') then
        raise exception 'ARS-646 / M-004: грант service_role снят — служебный вызов будет '
                        'падать сырой ошибкой прав Postgres мимо обработчика';
    end if;

    -- FR-015: читатель ничего не мутирует. Держится на объявлении STABLE.
    if not exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'rpc_get_mpk_profile_overview'
           and p.provolatile = 's' and p.prosecdef
    ) then
        raise exception 'ARS-646 / FR-015: rpc_get_mpk_profile_overview не stable security definer';
    end if;

    -- M-013 (СТРУКТУРНО, не поведенчески): обработчик внутреннего сбоя обязан отдавать
    -- КОД и писать текст исключения только в лог. Инсценировать сбой нечем, поэтому
    -- проверяется тело функции. В пакете G3 строка идёт как структурная.
    if position('OVERVIEW_READ_FAILED' in pg_get_functiondef(
            'public.rpc_get_mpk_profile_overview(uuid)'::regprocedure)) = 0 then
        raise exception 'ARS-646 / M-013: в теле нет кода OVERVIEW_READ_FAILED';
    end if;
    if position('raise log' in pg_get_functiondef(
            'public.rpc_get_mpk_profile_overview(uuid)'::regprocedure)) = 0 then
        raise exception 'ARS-646 / M-013: sqlerrm не уходит в серверный лог — текст '
                        'SQL-исключения рискует уйти наружу';
    end if;
    -- Сужение по находке ревью якоря 7: две прежние проверки прошли бы и с
    -- `raise exception 'OVERVIEW_READ_FAILED: %', sqlerrm` — то есть с утёкшим наружу
    -- текстом исключения, ровно тем, что M-013 запрещает. Требуем голый код без формата.
    if pg_get_functiondef('public.rpc_get_mpk_profile_overview(uuid)'::regprocedure)
       ~ 'OVERVIEW_READ_FAILED[^'']*%' then
        raise exception 'ARS-646 / M-013: raise exception OVERVIEW_READ_FAILED несёт аргумент '
                        'формата — наружу может уйти текст SQL-исключения';
    end if;
    -- FR-023 / M-020 (структурная половина): в теле НЕ должно быть агрегатов по сделкам.
    -- Поведенческая половина — ниже, по ответу.
    if pg_get_functiondef('public.rpc_get_mpk_profile_overview(uuid)'::regprocedure)
       ~* 'count\(distinct[^)]*batch_id[^)]*\)[[:space:]]*(as)?[[:space:]]*deals' then
        raise exception 'ARS-646 / FR-023: в теле появился счёт сделок';
    end if;

    -- ==================================================================================
    -- 1. Фикстуры.
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-646-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-646 область', 'oblast');

    insert into auth.users (id) values
        (v_auth_admin), (v_auth_view), (v_auth_turan), (v_auth_out);

    select id into v_user_admin from public.users where auth_id = v_auth_admin;
    select id into v_user_view  from public.users where auth_id = v_auth_view;
    select id into v_user_turan from public.users where auth_id = v_auth_turan;
    select id into v_user_out   from public.users where auth_id = v_auth_out;

    if v_user_admin is null or v_user_view is null
       or v_user_turan is null or v_user_out is null then
        raise exception 'ARS-646_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations
        (id, legal_name, bin_iin, legal_form, region_id, address_text, is_active)
    values
        (v_org_a,    'QA ARS-646 МПК допущена',   null, 'too', v_region, 'г. QA, ул. 1', true),
        (v_org_b,    'QA ARS-646 МПК чужая',      null, 'too', v_region, 'г. QA, ул. 2', true),
        (v_org_c,    'QA ARS-646 не МПК',         null, 'kh',  v_region, 'г. QA, ул. 3', true),
        (v_org_d,    'QA ARS-646 МПК без данных', null, 'too', v_region, 'г. QA, ул. 4', true),
        (v_org_e,    'QA ARS-646 МПК чистая',     null, 'too', v_region, 'г. QA, ул. 5', true),
        (v_org_farm, 'QA ARS-646 КХ поставщик',   null, 'kh',  v_region, 'г. QA, ул. 6', true),
        (v_org_farm2,'QA ARS-646 КХ второй',      null, 'kh',  v_region, 'г. QA, ул. 7', true),
        (v_org_f,    'QA ARS-646 МПК истекла',    null, 'too', v_region, 'г. QA, ул. 8', true);

    -- org_c намеренно БЕЗ mpk-типа (M-011).
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_a, 'mpk'), (v_org_b, 'mpk'), (v_org_d, 'mpk'), (v_org_e, 'mpk'),
           (v_org_c, 'farmer'), (v_org_farm, 'farmer'), (v_org_farm2, 'farmer'),
           (v_org_f, 'mpk');

    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values
        (v_user_admin, v_org_a, 'mpk_admin', true),
        (v_user_admin, v_org_c, 'mpk_admin', false),
        (v_user_admin, v_org_d, 'mpk_admin', false),
        (v_user_admin, v_org_e, 'mpk_admin', false),
        (v_user_admin, v_org_f, 'mpk_admin', false),
        -- viewer в org_a: каталог не даёт ему mpk.review.submit — сторож permissions
        (v_user_view,  v_org_a, 'viewer',    true);

    insert into public.admin_roles (user_id, role) values (v_user_turan, 'super_admin');

    -- Верификация: org_a и org_e — approved; org_d НЕ получает ни memberships, ни
    -- verification_records (M-005: «нет данных» → unknown, НЕ «отказано»).
    insert into public.memberships (organization_id, org_type, level)
    values (v_org_a, 'mpk', 'active_buyer') returning id into v_memb_a;
    insert into public.memberships (organization_id, org_type, level)
    values (v_org_e, 'mpk', 'active_buyer') returning id into v_memb_e;
    -- level = 'registered' НАМЕРЕННО. fn_org_membership_active (канон D-BILL-TRUTH-01)
    -- считает членство активным ЛИБО по живой подписке, ЛИБО по легаси-уровню
    -- memberships.level <> 'registered'. Первая редакция фикстуры дала здесь
    -- 'active_buyer' — и организация с ИСТЁКШЕЙ подпиской оказалась допущена по легаси-
    -- пути, то есть тест падал, а код был прав. Строка запоминает этот факт: чтобы
    -- проверить «нельзя закупать», надо погасить ОБА пути, а не только подписку.
    -- Запись memberships всё равно нужна: verification_records.membership_id — NOT NULL.
    insert into public.memberships (organization_id, org_type, level)
    values (v_org_f, 'mpk', 'registered') returning id into v_memb_f;

    insert into public.verification_records
        (membership_id, organization_id, verification_type, result, verified_by, verified_at)
    values
        (v_memb_a, v_org_a, 'bin_iin_check',   'approved', v_user_turan, now() - interval '40 days'),
        (v_memb_a, v_org_a, 'document_review', 'approved', v_user_turan, now() - interval '30 days'),
        (v_memb_e, v_org_e, 'bin_iin_check',   'approved', v_user_turan, now() - interval '20 days'),
        (v_memb_e, v_org_e, 'document_review', 'approved', v_user_turan, now() - interval '20 days'),
        (v_memb_f, v_org_f, 'bin_iin_check',   'approved', v_user_turan, now() - interval '90 days'),
        (v_memb_f, v_org_f, 'document_review', 'approved', v_user_turan, now() - interval '90 days');

    -- Членство: org_a истекает через 12 дней (M-006 сработает), org_e — через 300 (не сработает).
    insert into public.membership_subscription
        (organization_id, membership_id, plan_code, state,
         current_period_start, current_period_end, next_billing_at)
    values
        (v_org_a, v_memb_a, 'org_annual', 'active',
         now() - interval '353 days', now() + interval '12 days', now() + interval '12 days'),
        (v_org_e, v_memb_e, 'org_annual', 'active',
         now() - interval '65 days',  now() + interval '300 days', now() + interval '300 days'),
        -- M-005 проверяет «нет данных → unknown». ЭТА организация закрывает противоположный
        -- и самый дорогой случай: данные верификации ЕСТЬ и одобрены, а членство ИСТЕКЛО —
        -- закупать нельзя. Не покрывалось ничем: converge/ревью показали, что подмена
        -- `restricted` на `allowed` прошла бы зелёной, то есть вкладка сказала бы «допущена»
        -- комбинату с истёкшим членством.
        (v_org_f, v_memb_f, 'org_annual', 'expired',
         now() - interval '400 days', now() - interval '35 days', null);

    -- M-007: две правки критических полей на проверке у org_a. legal_name/address_text
    -- применяются сразу, поэтому production_value_applied_at обязан быть непустым
    -- (org_field_reviews_apply_timing_check) даже пока правка висит.
    insert into public.org_field_reviews
        (organization_id, field_name, previous_value, proposed_value, status,
         requested_by_user_id, requested_at, production_value_applied_at)
    values
        (v_org_a, 'legal_name',   'QA ARS-646 МПК допущена', 'QA ARS-646 МПК новая',
         'pending', v_user_admin, now() - interval '5 hours', now() - interval '5 hours'),
        (v_org_a, 'address_text', 'г. QA, ул. 1', 'г. QA, ул. 1а',
         'pending', v_user_admin, now() - interval '6 hours', now() - interval '6 hours');

    -- M-008: скрытый отзыв о НАШЕЙ сделке по ЛЕГАСИ-маршруту — партия в состоянии
    -- delivered, привязанная к пулу org_a через pool_line, и БЕЗ единой строки
    -- batch_allocations. Маршрут выбран намеренно: в проде 4 из 5 закрытых партий именно
    -- такие, и если атрибуция потеряет легаси-путь, этот тест покраснеет.
    insert into public.pool_requests (id, organization_id, total_heads, target_month, status)
    values (v_request, v_org_a, 50, date_trunc('month', now())::date, 'active');
    -- pools.organization_id: колонки НЕТ в d02_tsp.sql, но в задеплоенной БД она NOT NULL
    -- («прод-сверено 2026-06-23», 20260622120000_tsp_canonical_rebind.sql). Классический
    -- L-6, и фикстура упёрлась в него на первом же прогоне. Заполняем деплоенную реальность
    -- И проверяем ниже, что читатель ходит НЕ через неё, а через pool_requests (FR-016):
    -- значение здесь намеренно совпадает с org заявки, поэтому расхождение путей тест не
    -- поймал бы — сторож пути живёт в самом теле функции и в комментарии блока ARS-646.
    -- Дом расхождения — ARS-668.
    -- pool_request_id НАМЕРЕННО NULL — это каноническая форма: rpc_create_pool пишет
    -- именно так, а pool_requests помечена DEPRECATED. Сторож против возврата к join'у
    -- через неё (FR-024): при прежней редакции кода все ассерты M-008 покраснели бы.
    insert into public.pools (id, pool_request_id, organization_id, target_heads, status)
    values (v_pool, null, v_org_a, 50, 'completed');
    insert into public.pool_lines (id, pool_id, category_label, mpk_price_per_kg)
    values (v_line, v_pool, 'QA ARS-646 категория', 1500);
    insert into public.batches
        (id, organization_id, heads, target_month, status, pool_line_id, region_id)
    values (v_batch, v_org_farm, 20, date_trunc('month', now())::date, 'delivered',
            v_line, v_region);
    -- Вторая закрытая сделка — контроль фильтра по роли: скрыт только НАШ отзыв, отзыва
    -- фермера нет. Пункт по ней возникать не должен (M-008 говорит про отзыв фермера).
    -- Состояние ДОСТИЖИМО: МПК оценил первым, фермер ещё нет. Прежняя редакция ставила
    -- сюда «отзыв фермера скрыт И наш есть» — состояние, недостижимое через канонического
    -- писателя (rpc_submit_deal_review раскрывает пару атомарно), то есть тест утверждал
    -- поведение на невозможных данных. Нашёл converge якоря 7.
    insert into public.batches
        (id, organization_id, heads, target_month, status, pool_line_id, region_id)
    values (v_batch2, v_org_farm, 15, date_trunc('month', now())::date, 'delivered',
            v_line, v_region);
    -- Третья закрытая сделка — МАРШРУТ ① атрибуции (через batch_allocations). Он не
    -- покрывался ничем, хотя комментарий в теле функции объявлял тест своим сторожем:
    -- обе прежние партии шли легаси-маршрутом, и подмена `a.status` или join'а прошла бы
    -- зелёной. Дробление сегодня выключено решением CEO (TSP-SLICE9-ROLLBACK-01), поэтому
    -- живых данных по этому маршруту нет — тем важнее фикстура: при реактивации Слайса 9
    -- маршрут включится молча.
    insert into public.batches
        (id, organization_id, heads, target_month, status, pool_line_id, region_id)
    values (v_batch3, v_org_farm2, 25, date_trunc('month', now())::date, 'delivered',
            null, v_region);
    insert into public.batch_allocations
        (batch_id, pool_line_id, pool_id, heads, price_per_kg, status, via, matched_at)
    values
        (v_batch3, v_line, v_pool, 25, 1500, 'delivered',  'manual_match', now() - interval '9 days'),
        (v_batch3, v_line, v_pool,  5, 1500, 'cancelled',  'manual_match', now() - interval '9 days');
    insert into public.deal_reviews
        (batch_id, reviewer_org_id, reviewer_role, overall_score, submitted_at, visible_at)
    values
        (v_batch,  v_org_farm,  'farmer', 5, now() - interval '2 days', null),
        (v_batch2, v_org_a,     'mpk',    5, now() - interval '3 days', null),
        (v_batch3, v_org_farm2, 'farmer', 4, now() - interval '1 day',  null);

    -- ==================================================================================
    -- 2. M-003 — нет сессии: типизированный отказ «требуется вход».
    -- ==================================================================================
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims', '{}', true);
        v_res := public.rpc_get_mpk_profile_overview(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'ARS-646 / M-003: вызов без сессии ВЕРНУЛ payload';
    end if;
    if v_err <> 'AUTH_REQUIRED' or v_state <> '42501' then
        raise exception 'ARS-646 / M-003: ожидался AUTH_REQUIRED/42501, получено %/%',
            v_err, v_state;
    end if;

    -- ==================================================================================
    -- 3. M-004 — служебный вызов: отказ в ОБОИХ состояниях, оба типизированы.
    --    Сторож против возврата ветки service_role копипастой из ARS-361.
    -- ==================================================================================
    begin
        perform set_config('role', 'service_role', true);
        perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
        v_res := public.rpc_get_mpk_profile_overview(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'ARS-646 / M-004: служебный вызов БЕЗ сессии вернул payload — '
                        'служебный путь просочился в предикат';
    end if;
    if v_err <> 'AUTH_REQUIRED' then
        raise exception 'ARS-646 / M-004: без сессии ожидался AUTH_REQUIRED, получено %', v_err;
    end if;

    begin
        perform set_config('role', 'service_role', true);
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_out, 'role', 'service_role')::text, true);
        v_res := public.rpc_get_mpk_profile_overview(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'ARS-646 / M-004: служебный вызов С сессией не-участника вернул payload';
    end if;
    if v_err not like 'FORBIDDEN%' or v_state <> '42501' then
        raise exception 'ARS-646 / M-004: ожидался FORBIDDEN/42501, получено %/%', v_err, v_state;
    end if;
    if v_err like '%permission denied%' then
        raise exception 'ARS-646 / M-004: наружу ушла сырая ошибка прав Postgres';
    end if;

    -- ==================================================================================
    -- 4. M-002 / M-012 — чужая, несуществующая и не названная организация: ОДИН отказ.
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);

    begin
        v_res := public.rpc_get_mpk_profile_overview(v_org_b);
        v_err := null;
    exception when others then v_err := sqlerrm; end;
    if v_err is null or v_err not like 'FORBIDDEN%' then
        raise exception 'ARS-646 / M-002: чужая организация не дала FORBIDDEN (получено %)', v_err;
    end if;

    begin
        v_res := public.rpc_get_mpk_profile_overview(null);
        v_state := null; v_err := null;
    exception when others then v_err := sqlerrm; end;
    if v_err is null or v_err not like 'FORBIDDEN%' then
        raise exception 'ARS-646 / M-012: null-организация не дала тот же FORBIDDEN (получено %)',
            v_err;
    end if;

    begin
        v_res := public.rpc_get_mpk_profile_overview(v_org_ghost);
        v_err := null;
    exception when others then v_err := sqlerrm; end;
    if v_err is null or v_err not like 'FORBIDDEN%' then
        raise exception 'ARS-646 / M-002: несуществующая организация не дала тот же отказ '
                        '(получено %) — ответ подтверждает её отсутствие', v_err;
    end if;

    -- ==================================================================================
    -- 5. M-001 — happy path: полный payload участника.
    -- ==================================================================================
    v_res := public.rpc_get_mpk_profile_overview(v_org_a);
    if v_res is null then
        raise exception 'ARS-646 / M-001: участник получил null';
    end if;
    if (v_res ->> 'contract_version') is null then
        raise exception 'ARS-646 / M-001 / FR-004: в ответе нет contract_version';
    end if;
    if (v_res ->> 'organization_id') <> v_org_a::text then
        raise exception 'ARS-646 / M-001: organization_id не совпадает с запрошенной';
    end if;
    if v_res -> 'admission' is null or v_res -> 'gates' is null
       or v_res -> 'attention' is null or v_res -> 'reputation' is null
       or v_res -> 'facts' is null or v_res -> 'permissions' is null then
        raise exception 'ARS-646 / M-001: в payload нет одного из шести обязательных блоков';
    end if;
    if jsonb_typeof(v_res -> 'gates') <> 'array'
       or jsonb_array_length(v_res -> 'gates') <> 3 then
        raise exception 'ARS-646 / M-001: gates не массив из трёх гейтов';
    end if;
    if (v_res -> 'admission' ->> 'status') <> 'allowed' then
        raise exception 'ARS-646 / M-001: approved + активное членство дали admission=%, '
                        'ожидалось allowed', v_res -> 'admission' ->> 'status';
    end if;
    if (v_res -> 'admission' ->> 'has_pending_reviews')::boolean is not true then
        raise exception 'ARS-646 / M-001: has_pending_reviews=false при двух правках на проверке';
    end if;
    if (v_res -> 'admission' ->> 'checked_at') is null then
        raise exception 'ARS-646 / M-001: нет checked_at';
    end if;

    -- Сторож дефекта, найденного ревью якоря 7: первая редакция читала у timeline ARS-361
    -- ключи occurred_at/status, которых там НЕТ (есть verified_at/result/effective_status),
    -- поэтому approved_at был null при любых данных, а тест на поле не смотрел вовсе.
    select g into v_gate
    from jsonb_array_elements(v_res -> 'gates') g
    where g ->> 'kind' = 'verification';
    if (v_gate ->> 'approved_at') is null then
        raise exception 'ARS-646 / M-001: approved_at пуст у организации с двумя одобренными '
                        'записями верификации — читаются не те ключи timeline';
    end if;
    if ((v_gate ->> 'approved_at')::timestamptz) < now() - interval '31 days' then
        raise exception 'ARS-646 / M-001: approved_at=% — взята не самая свежая из двух '
                        'записей (ожидалась −30 дней)', v_gate ->> 'approved_at';
    end if;
    if (v_gate ->> 'tone') <> 'warning' then
        raise exception 'ARS-646 / M-001: тон верификации при двух правках на проверке = %, '
                        'ожидался warning', v_gate ->> 'tone';
    end if;

    -- Репутация обязана быть про ЗАПРОШЕННУЮ организацию: подстановка чужого id оставила бы
    -- блок непустым, и проверка «не null» этого не заметила бы.
    if (v_res -> 'reputation' ->> 'mpk_org_id') <> v_org_a::text then
        raise exception 'ARS-646 / M-001: reputation.mpk_org_id=% вместо запрошенной организации',
            v_res -> 'reputation' ->> 'mpk_org_id';
    end if;

    -- ==================================================================================
    -- 6. M-010 — гейт документов: только признак, без счётчика «N из M».
    -- ==================================================================================
    select g into v_gate
    from jsonb_array_elements(v_res -> 'gates') g
    where g ->> 'kind' = 'documents';
    if v_gate is null then
        raise exception 'ARS-646 / M-010: гейта documents нет в ответе';
    end if;
    if (v_gate ->> 'available')::boolean is not false then
        raise exception 'ARS-646 / M-010: гейт documents отдал available<>false — '
                        'читателя документов не существует (дом ARS-363)';
    end if;
    if (v_gate ->> 'blocked_by') <> 'ARS-363' then
        raise exception 'ARS-646 / M-010: гейт documents без указателя на ARS-363';
    end if;
    if v_gate ? 'accepted_count' or v_gate ? 'total_count' then
        raise exception 'ARS-646 / M-010: у гейта documents появился счётчик — данных для '
                        'него не существует';
    end if;

    -- ==================================================================================
    -- 7. M-006 — членство истекает: число в гейте и в пункте внимания одно и то же.
    -- ==================================================================================
    select g into v_gate
    from jsonb_array_elements(v_res -> 'gates') g
    where g ->> 'kind' = 'membership';
    if (v_gate ->> 'is_active')::boolean is not true then
        raise exception 'ARS-646 / M-006: активная подписка прочитана как неактивная';
    end if;
    if (v_gate ->> 'days_left')::int not between 11 and 13 then
        raise exception 'ARS-646 / M-006: days_left=% при сроке 12 дней', v_gate ->> 'days_left';
    end if;
    if (v_gate ->> 'tone') <> 'warning' then
        raise exception 'ARS-646 / M-006: тон гейта членства при 12 днях = %, ожидался warning',
            v_gate ->> 'tone';
    end if;

    select a into v_att
    from jsonb_array_elements(v_res -> 'attention') a
    where a ->> 'kind' = 'membership_expiring';
    if v_att is null then
        raise exception 'ARS-646 / M-006: пункта membership_expiring нет при 12 днях до конца';
    end if;
    if (v_att ->> 'days_left') <> (v_gate ->> 'days_left') then
        raise exception 'ARS-646 / M-006: гейт и пункт внимания расходятся в days_left (% vs %)',
            v_gate ->> 'days_left', v_att ->> 'days_left';
    end if;
    if (v_att -> 'action' ->> 'type') <> 'open_admission' then
        raise exception 'ARS-646 / M-006 / FR-007: action.type=% вне закрытого перечня',
            v_att -> 'action' ->> 'type';
    end if;
    -- FR-006: наружу идут КОДЫ, не тексты. Русской формулировки в пункте быть не должно.
    if v_att::text ~ '[А-Яа-я]{4,}' then
        raise exception 'ARS-646 / M-006 / FR-006: в пункте внимания появился русский текст — '
                        'дом формулировок клиент, а не БД';
    end if;

    -- ==================================================================================
    -- 8. M-007 — правки на проверке: счётчик и имена полей, без текстов.
    -- ==================================================================================
    select a into v_att
    from jsonb_array_elements(v_res -> 'attention') a
    where a ->> 'kind' = 'pending_field_review';
    if v_att is null then
        raise exception 'ARS-646 / M-007: пункта pending_field_review нет при двух правках';
    end if;
    if (v_att ->> 'field_count')::int <> 2 then
        raise exception 'ARS-646 / M-007: field_count=%, ожидалось 2', v_att ->> 'field_count';
    end if;
    if not (v_att -> 'fields' @> '["legal_name"]'::jsonb
            and v_att -> 'fields' @> '["address_text"]'::jsonb) then
        raise exception 'ARS-646 / M-007: в fields нет имён правленых полей';
    end if;
    if (v_att -> 'action' ->> 'type') <> 'open_org' then
        raise exception 'ARS-646 / M-007 / FR-007: action.type=% вне закрытого перечня',
            v_att -> 'action' ->> 'type';
    end if;

    -- ==================================================================================
    -- 9. M-008 — скрытый отзыв по ЛЕГАСИ-маршруту атрибуции.
    -- ==================================================================================
    select a into v_att
    from jsonb_array_elements(v_res -> 'attention') a
    where a ->> 'kind' = 'hidden_review';
    if v_att is null then
        raise exception 'ARS-646 / M-008: пункта hidden_review нет — атрибуция потеряла '
                        'легаси-маршрут (партия delivered без кусков), а в проде это 4 из 5 '
                        'закрытых партий';
    end if;
    if (v_att ->> 'counterparty_name') <> 'QA ARS-646 КХ поставщик' then
        raise exception 'ARS-646 / M-008: counterparty_name=%, ожидалось имя хозяйства-автора',
            v_att ->> 'counterparty_name';
    end if;
    if (v_att -> 'action' ->> 'type') <> 'open_reputation' then
        raise exception 'ARS-646 / M-008 / FR-007: action.type=% вне закрытого перечня',
            v_att -> 'action' ->> 'type';
    end if;

    -- ОБРАТНАЯ ПОДМЕНА, без мутации по ходу теста. В фикстуре ДВЕ закрытые сделки с
    -- отзывом фермера: по первой мы не оценили, по второй — оценили. Пункт обязан
    -- посчитать ТОЛЬКО первую. Подмена сделана составом фикстуры, а не insert/delete
    -- посреди прогона: удалить отзыв нельзя (триггер immutability), а `disable trigger`
    -- взял бы ACCESS EXCLUSIVE на ЖИВОЙ deal_reviews — то самое, чего запрещает
    -- QA-ENV-ISOLATION-01. Ассерт при этом строже: он ловит и «условие не проверяется»
    -- (было бы 2), и «атрибуция потеряла легаси» (было бы 0).
    -- Фикстура держит ТРИ закрытые сделки: ① легаси (отзыв фермера скрыт) → считается;
    -- ② только наш отзыв, отзыва фермера нет → НЕ считается (фильтр по роли);
    -- ③ через batch_allocations, отзыв фермера скрыт → считается (маршрут ①).
    -- Ожидание 2 ловит три независимых регресса: потерю легаси-маршрута (стало бы 1),
    -- потерю маршрута кусков (стало бы 1) и потерю фильтра по роли (стало бы 3).
    if (v_att ->> 'count')::int <> 2 then
        raise exception 'ARS-646 / M-008: count=%, ожидалось 2 (легаси + маршрут кусков, '
                        'сделка только с нашим отзывом не считается)', v_att ->> 'count';
    end if;

    -- ==================================================================================
    -- 10. M-020 / FR-023 — три сделочных числа приходят ПРИЗНАКОМ, а не нулём.
    -- ==================================================================================
    v_res := public.rpc_get_mpk_profile_overview(v_org_a);
    for v_i in 1..3 loop
        v_gate := case v_i
            when 1 then v_res -> 'facts' -> 'deals_closed'
            when 2 then v_res -> 'facts' -> 'heads_accepted'
            else        v_res -> 'facts' -> 'supplier_orgs'
        end;
        if v_gate is null then
            raise exception 'ARS-646 / M-020: сделочный ключ #% исчез из контракта — возврат '
                            'счётчика должен ЗАПОЛНИТЬ форму, а не сменить её', v_i;
        end if;
        if jsonb_typeof(v_gate) = 'number' then
            raise exception 'ARS-646 / M-020 / FR-023: сделочный ключ #% отдал ЧИСЛО. Ноль '
                            'означал бы «сделок нет» — утверждение, которого система сделать '
                            'не может (смысл не определён, дом ARS-668)', v_i;
        end if;
        if (v_gate ->> 'available')::boolean is not false
           or (v_gate ->> 'blocked_by') <> 'ARS-668' then
            raise exception 'ARS-646 / M-020: сделочный ключ #% без признака '
                            '{available:false, blocked_by:ARS-668}', v_i;
        end if;
    end loop;
    -- Единственный считаемый факт — сотрудники: у org_a их двое (admin + viewer).
    if (v_res -> 'facts' ->> 'staff_active')::int <> 2 then
        raise exception 'ARS-646 / FR-018: staff_active=%, ожидалось 2',
            v_res -> 'facts' ->> 'staff_active';
    end if;

    -- ==================================================================================
    -- 11. permissions — единственное право, гейтящее действие на этом экране.
    -- ==================================================================================
    if (v_res -> 'permissions' ->> 'mpk.review.submit')::boolean is not true then
        raise exception 'ARS-646: mpk_admin не получил mpk.review.submit';
    end if;
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_view, 'role', 'authenticated')::text, true);
    v_res := public.rpc_get_mpk_profile_overview(v_org_a);
    if (v_res -> 'permissions' ->> 'mpk.review.submit')::boolean is not false then
        raise exception 'ARS-646: viewer получил mpk.review.submit — право не проверяется';
    end if;
    -- Читаемость раздела правом НЕ гейтится (Slice10 FR-016): viewer видит те же блоки.
    if jsonb_array_length(v_res -> 'gates') <> 3 then
        raise exception 'ARS-646 / Slice10 FR-016: viewer получил урезанный ответ — раздел '
                        'обязан быть read-only, а не скрытым';
    end if;

    -- ==================================================================================
    -- 12. M-005 — нет данных верификации: unknown, НЕ «отказано».
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);
    v_res := public.rpc_get_mpk_profile_overview(v_org_d);
    if (v_res -> 'admission' ->> 'status') = 'restricted' then
        raise exception 'ARS-646 / M-005: организация без данных верификации получила '
                        'restricted — «нет данных» не равно «отказано»';
    end if;
    if (v_res -> 'admission' ->> 'status') <> 'unknown' then
        raise exception 'ARS-646 / M-005: ожидался unknown, получено %',
            v_res -> 'admission' ->> 'status';
    end if;
    select g into v_gate
    from jsonb_array_elements(v_res -> 'gates') g
    where g ->> 'kind' = 'verification';
    if (v_gate ->> 'tone') <> 'unknown' then
        raise exception 'ARS-646 / M-005: тон гейта верификации без данных = %, ожидался unknown',
            v_gate ->> 'tone';
    end if;

    -- ==================================================================================
    -- 12b. FR-002 / M-002 — ВТОРОЙ путь доступа: админ TURAN.
    --      Не исполнялся ни разу: ghost-организацию спрашивал участник, и его отсекал
    --      предикат членства ВЫШЕ, поэтому ветка v_org_found была недостижима. Значит
    --      удаление `or v_is_admin` и удаление проверки «не найдено» прошли бы зелёными.
    --      Нашло ревью якоря 7.
    -- ==================================================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_turan, 'role', 'authenticated')::text, true);

    begin
        v_res := public.rpc_get_mpk_profile_overview(v_org_a);
        v_err := null;
    exception when others then v_err := sqlerrm; end;
    if v_err is not null then
        raise exception 'ARS-646 / FR-002: админ TURAN получил отказ (%) — второй путь '
                        'доступа не работает', v_err;
    end if;
    if (v_res ->> 'organization_id') <> v_org_a::text then
        raise exception 'ARS-646 / FR-002: админ TURAN получил чужой payload';
    end if;
    -- Право на мутацию админство НЕ даёт: писатель отзывов требует членства, поэтому
    -- обещать кнопку «Оценить» здесь значило бы соврать (находка converge, unrequested).
    if (v_res -> 'permissions' ->> 'mpk.review.submit')::boolean is not false then
        raise exception 'ARS-646: админ TURAN получил mpk.review.submit — обещание ложное, '
                        'rpc_submit_deal_review потребует членства и откажет';
    end if;

    begin
        v_res := public.rpc_get_mpk_profile_overview(v_org_ghost);
        v_err := null;
    exception when others then v_err := sqlerrm; end;
    if v_err is null or v_err not like 'FORBIDDEN%' then
        raise exception 'ARS-646 / M-002: несуществующая организация ОТ АДМИНА не дала '
                        'FORBIDDEN (получено %) — ветка «не найдено» недостижима или снята',
            v_err;
    end if;

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);

    -- ==================================================================================
    -- 12c. admission = restricted: данные верификации ЕСТЬ и одобрены, членство ИСТЕКЛО.
    --      Самая дорогая ошибка этого RPC — сказать «можно закупать», когда нельзя, — не
    --      наблюдалась ничем: подмена ветки на 'allowed' проходила зелёной.
    -- ==================================================================================
    v_res := public.rpc_get_mpk_profile_overview(v_org_f);
    if (v_res -> 'admission' ->> 'status') <> 'restricted' then
        raise exception 'ARS-646: организация с одобренной верификацией и ИСТЁКШИМ членством '
                        'получила admission=%, ожидалось restricted', 
            v_res -> 'admission' ->> 'status';
    end if;
    select g into v_gate
    from jsonb_array_elements(v_res -> 'gates') g
    where g ->> 'kind' = 'membership';
    if (v_gate ->> 'is_active')::boolean is not false then
        raise exception 'ARS-646: истёкшая подписка прочитана как активная';
    end if;
    -- Пункта «истекает» быть не должно: членство уже истекло, а не истекает.
    if exists (
        select 1 from jsonb_array_elements(v_res -> 'attention') a
        where a ->> 'kind' = 'membership_expiring'
    ) then
        raise exception 'ARS-646 / M-006: пункт membership_expiring выдан при УЖЕ истёкшем '
                        'членстве — состояние несёт гейт, а не пункт';
    end if;

    -- ==================================================================================
    -- 13. M-011 — организация НЕ МПК: тот же payload, НЕ отказ.
    -- ==================================================================================
    begin
        v_res := public.rpc_get_mpk_profile_overview(v_org_c);
        v_err := null;
    exception when others then v_err := sqlerrm; end;
    if v_err is not null then
        raise exception 'ARS-646 / M-011: не-МПК получила отказ (%) — 403 по типу обещал бы '
                        'проверку, которой нет', v_err;
    end if;
    if v_res -> 'gates' is null or jsonb_array_length(v_res -> 'gates') <> 3 then
        raise exception 'ARS-646 / M-011: не-МПК получила урезанный payload вместо пустых секций';
    end if;

    -- ==================================================================================
    -- 14. M-009 — ничего не требует действий: ПОСЧИТАННОЕ «чисто».
    -- ==================================================================================
    v_res := public.rpc_get_mpk_profile_overview(v_org_e);
    if jsonb_typeof(v_res -> 'attention') <> 'array' then
        raise exception 'ARS-646 / M-009: attention не массив — «чисто» неотличимо от '
                        '«не считалось»';
    end if;
    if jsonb_array_length(v_res -> 'attention') <> 0 then
        raise exception 'ARS-646 / M-009: у чистой организации % пунктов внимания',
            jsonb_array_length(v_res -> 'attention');
    end if;
    if (v_res -> 'admission' ->> 'status') <> 'allowed' then
        raise exception 'ARS-646 / M-009: чистая организация получила admission=%',
            v_res -> 'admission' ->> 'status';
    end if;
    if (v_res -> 'admission' ->> 'has_pending_reviews')::boolean is not false then
        raise exception 'ARS-646 / M-009: has_pending_reviews=true без правок на проверке';
    end if;

    -- ==================================================================================
    -- 15. M-014 — порог p95 < 200 мс. Условия замера идут в пакет G3, не в комментарий.
    -- ==================================================================================
    -- Считаем ИМЕННО p95, а не среднее: строка M-014 называет перцентиль, а среднее
    -- проходит на выбросах, на которых p95 не проходит (девять по 20 мс и один по 1500
    -- дают среднее 168). Нашло ревью якоря 7 и converge независимо.
    create temporary table if not exists ars646_timings (ms numeric) on commit drop;
    delete from ars646_timings;
    for v_i in 1..20 loop
        v_t0 := clock_timestamp();
        perform public.rpc_get_mpk_profile_overview(v_org_a);
        insert into ars646_timings (ms)
        values (extract(epoch from (clock_timestamp() - v_t0)) * 1000);
    end loop;
    select percentile_disc(0.95) within group (order by ms), avg(ms)
      into v_p95, v_ms from ars646_timings;
    raise notice 'ARS-646 / M-014: p95 = % мс (среднее % мс, 20 вызовов, порог 200)',
        round(v_p95, 2), round(v_ms, 2);
    if v_p95 >= 200 then
        raise exception 'ARS-646 / M-014: p95 % мс >= порога 200', round(v_p95, 2);
    end if;

    perform set_config('role', 'none', true);
    perform set_config('request.jwt.claims', '{}', true);

    raise notice 'ARS-646 / MP-2.2: контракт агрегата «Обзора» пройден. Поведенчески закрыты '
                 'M-001 M-002 M-003 M-004 M-005 M-006 M-007 M-008 M-009 M-010 M-011 M-012 '
                 'M-014 M-020; M-013 — СТРУКТУРНО.';
end;
$$;

rollback;
