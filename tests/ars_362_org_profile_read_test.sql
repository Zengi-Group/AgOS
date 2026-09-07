-- ARS-362 / MP-2.1 — регрессионный контракт читателя профиля организации.
-- Спека: Docs/AGOS-MPK-Profile-ReadRPC-ARS-362.md · контракт ответа: Dok3 RPC-63.
-- Перевыведено с нуля 2026-09-07 (сборка 56631d8 снята ревертом a4dec07).
--
-- ЗАПУСК (изолированной среды нет — IMPL_DEBT QA-ENV-ISOLATION-01):
--   psql "$DATABASE_URL" -f tests/ars_362_org_profile_read_test.sql
-- Файл открывает свою транзакцию и заканчивается ROLLBACK: ни одной строки в базе не
-- остаётся. Сторож ниже роняет прогон ДО первой записи, если файл всё же исполняется
-- автокоммитом. Проверка `transaction_timestamp() = statement_timestamp()` выбрана
-- потому, что `xact_start is not null` вакуумна — при автокоммите statement тоже идёт
-- в неявной транзакции (триаж №13a итерации 1).
--
-- Фикстуры СВОИ ЦЕЛИКОМ: тест создаёт своих auth.users (public.users делает триггер
-- trg_on_auth_user_created), свои организации, свой регион и ВЫДАЁТ права себе. Ни одной
-- существующей строки users / admin_roles / user_organization_roles / organizations он не
-- читает и не меняет — версия из сборки 56631d8 гасила is_active ЖИВОМУ админу TURAN
-- (триаж №13), и это недопустимо на единственной боевой базе.
--
-- Покрытие матрицы (id названы в каждом утверждении — Matrix Test Audit сверяет по id):
--   поведенчески: M-001 M-002 M-003 M-004 M-005 M-006 M-007 M-008 M-009 M-010 M-012 M-013 M-014
--   структурно  : M-011 (инсценировать сбой чтения нечем — IMPL_DEBT
--                 ARS-362-M011-NO-FAULT-INJECTION-01; в пакете G3 строка идёт как
--                 структурная, а не как закрытая поведением)

-- Без этой строки сторож ниже БЕСПОЛЕЗЕН: по умолчанию psql печатает ошибку и идёт к
-- следующему statement'у, то есть исполняет блок фикстур, который сторож и должен был
-- остановить — а под автокоммитом каждый insert сразу коммитится в единственную живую
-- базу. Строка живёт в файле, а не только в команде запуска, потому что защита не может
-- зависеть от того, вспомнил ли человек флаг.
\set ON_ERROR_STOP on

begin;

-- --------------------------------------------------------------------------------------
-- Сторож транзакции. Отдельным блоком и ПЕРВЫМ: до любой записи.
-- --------------------------------------------------------------------------------------
do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-362_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback). Автокоммитом он оставит фикстуры в '
                        'единственной боевой базе — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

do $$
declare
    -- фикстурные организации
    v_org_a        uuid := gen_random_uuid();   -- активная МПК, заполнена, тяжёлая
    v_org_b        uuid := gen_random_uuid();   -- активная МПК, чужая (для M-004)
    v_org_c        uuid := gen_random_uuid();   -- активная, НЕ МПК (M-009)
    v_org_d        uuid := gen_random_uuid();   -- активная МПК, пустая (M-002)
    v_org_e        uuid := gen_random_uuid();   -- МПК, is_active = false (гейт permissions)
    v_org_ghost    uuid := gen_random_uuid();   -- не создаётся вовсе (FR-003)
    -- фикстурные пользователи
    v_auth_admin   uuid := gen_random_uuid();   -- mpk_admin в org_a, org_c, org_e
    v_auth_acct    uuid := gen_random_uuid();   -- accountant в org_a (банк без profile.edit)
    v_auth_empl    uuid := gen_random_uuid();   -- employee в org_a (ни банка, ни правки)
    v_auth_turan   uuid := gen_random_uuid();   -- админ TURAN, ни в одной организации
    v_auth_out     uuid := gen_random_uuid();   -- участник только org_b
    v_user_admin   uuid;
    v_user_acct    uuid;
    v_user_empl    uuid;
    v_user_turan   uuid;
    v_user_out     uuid;
    -- фикстурные справочники и данные
    v_region       uuid := gen_random_uuid();
    v_region_name  text := 'QA ARS-362 область';
    v_site_region  uuid := gen_random_uuid();
    v_site_rname   text := 'QA ARS-362 район площадки';
    v_logical_1    uuid := gen_random_uuid();   -- лестница с историей + живой primary
    v_logical_2    uuid := gen_random_uuid();   -- ВТОРАЯ живая лестница (M-013)
    v_bin_prod     text := '900000000362';
    v_bin_proposed text := '900000000999';
    v_live2_id     uuid;
    v_closed2_id   uuid;
    v_pending_id   uuid;
    -- результаты
    v_res          jsonb;
    v_res_acct     jsonb;
    v_res_empl     jsonb;
    v_res_turan    jsonb;
    v_res_empty    jsonb;
    v_res_nonmpk   jsonb;
    v_res_inactive jsonb;
    v_res_fast     jsonb;
    v_err          text;
    v_state        text;
    v_err_outsider text;
    v_err_admin    text;
    v_leak         text;
    v_body         text;
    v_hist         jsonb;
    v_durations    double precision[] := array[]::double precision[];
    v_p95          double precision;
    v_t0           timestamptz;
    i              int;
begin
    -- ==================================================================================
    -- 0. Гранты: читатель обязан быть закрыт от public/anon и открыт authenticated.
    --    Грант service_role умышлен и путём доступа НЕ является (FR-015) — его следствие
    --    проверяет M-014 ниже: не «permission denied for function», а наш код.
    -- ==================================================================================
    if has_function_privilege('anon', 'public.rpc_get_org_profile(uuid)', 'execute') then
        raise exception 'ARS-362: anon может исполнять читателя профиля';
    end if;
    if not has_function_privilege('authenticated', 'public.rpc_get_org_profile(uuid)', 'execute') then
        raise exception 'ARS-362: authenticated не может исполнять читателя профиля';
    end if;
    if not has_function_privilege('service_role', 'public.rpc_get_org_profile(uuid)', 'execute') then
        raise exception 'ARS-362 / M-014: грант service_role снят — служебный вызов будет '
                        'падать сырой ошибкой прав Postgres мимо обработчика';
    end if;

    -- FR-013: читатель ничего не мутирует. Держится на объявлении STABLE — проверяем,
    -- что маркер на месте: без него запись в теле стала бы возможной незаметно.
    if not exists (
        select 1
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'rpc_get_org_profile'
           and p.provolatile = 's'
           and p.prosecdef
    ) then
        raise exception 'ARS-362 / FR-013: rpc_get_org_profile не stable security definer';
    end if;

    -- ==================================================================================
    -- 1. Фикстуры.
    -- ==================================================================================
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-362-' || substr(replace(v_region::text, '-', ''), 1, 8),
            v_region_name, 'oblast'),
           (v_site_region, 'QA-362-' || substr(replace(v_site_region::text, '-', ''), 1, 8),
            v_site_rname, 'rayon');

    insert into auth.users (id) values
        (v_auth_admin), (v_auth_acct), (v_auth_empl), (v_auth_turan), (v_auth_out);

    select id into v_user_admin from public.users where auth_id = v_auth_admin;
    select id into v_user_acct  from public.users where auth_id = v_auth_acct;
    select id into v_user_empl  from public.users where auth_id = v_auth_empl;
    select id into v_user_turan from public.users where auth_id = v_auth_turan;
    select id into v_user_out   from public.users where auth_id = v_auth_out;

    if v_user_admin is null or v_user_acct is null or v_user_empl is null
       or v_user_turan is null or v_user_out is null then
        raise exception 'ARS-362_TEST_SETUP: триггер trg_on_auth_user_created не создал '
                        'public.users — фикстура недостоверна';
    end if;

    insert into public.organizations
        (id, legal_name, bin_iin, legal_form, region_id, address_text, phone, email,
         website, head_full_name, head_title, is_active)
    values
        (v_org_a, 'QA ARS-362 МПК полная', v_bin_prod, 'too', v_region,
         'г. QA, ул. Тестовая 1', '+77000000362', 'qa362a@example.kz',
         'https://qa362.example.kz', 'Тестов Тест Тестович', 'Директор', true),
        (v_org_b, 'QA ARS-362 МПК чужая', null, 'too', v_region, 'г. QA, ул. Чужая 2',
         null, null, null, null, null, true),
        (v_org_c, 'QA ARS-362 не МПК', null, 'kh', v_region, 'г. QA, ул. Ферма 3',
         null, null, null, null, null, true),
        (v_org_d, 'QA ARS-362 МПК пустая', null, 'too', null, 'г. QA, ул. Пустая 4',
         null, null, null, null, null, true),
        (v_org_e, 'QA ARS-362 МПК погашенная', null, 'too', v_region,
         'г. QA, ул. Погашенная 5', null, null, null, null, null, false);

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_a, 'mpk'), (v_org_b, 'mpk'), (v_org_d, 'mpk'), (v_org_e, 'mpk');

    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values
        (v_user_admin, v_org_a, 'mpk_admin',  true),
        (v_user_acct,  v_org_a, 'accountant', true),
        (v_user_empl,  v_org_a, 'employee',   true),
        (v_user_admin, v_org_c, 'mpk_admin',  false),
        (v_user_admin, v_org_d, 'mpk_admin',  false),
        (v_user_admin, v_org_e, 'mpk_admin',  false),
        (v_user_out,   v_org_b, 'mpk_admin',  true);

    -- Админ TURAN получает роль СЕБЕ; ни одна существующая admin_roles-строка не тронута.
    insert into public.admin_roles (user_id, role, is_active)
    values (v_user_turan, 'super_admin', true);

    insert into public.mpk_profiles (organization_id, public_description, logo_path)
    values (v_org_a, 'QA описание МПК для ARS-362', 'orgs/qa362/logo.png');

    -- Активная ПЕРВИЧНАЯ площадка + активная НЕ первичная: читатель обязан отдать первую
    -- и не отдавать вторую (скоуп v0.1, Slice10 §4.1 — не пропажа, а граница).
    insert into public.mpk_sites
        (organization_id, site_name, region_id, address_text,
         processing_capacity_heads_per_day, phone, email, is_primary, is_active,
         created_by_user_id)
    values
        (v_org_a, 'QA площадка первичная', v_site_region, 'г. QA, промзона 1',
         120, '+77000000001', 'site1@example.kz', true, true, v_user_admin),
        (v_org_a, 'QA площадка вторая', v_site_region, 'г. QA, промзона 2',
         40, null, null, false, true, v_user_admin);

    -- Банк: 25 ЗАКРЫТЫХ версий одной лестницы + её живой primary + ВТОРАЯ живая лестница.
    -- Второй живой счёт достижим задеплоенным писателем (IMPL_DEBT
    -- BANK-MULTI-LIVE-ACCOUNT-01) — именно на нём проверяется FR-019 / M-013.
    insert into public.org_bank_accounts
        (organization_id, logical_account_id, version_no, bank_name, bik, iban,
         account_holder_name, currency_code, is_primary, valid_from, valid_to,
         created_by_user_id)
    select v_org_a, v_logical_1, g,
           'QA Банк', 'QABIK001',
           'KZ' || lpad(g::text, 18, '0'),
           'QA ARS-362 держатель', 'KZT', false,
           now() - make_interval(days => 100 - g),
           now() - make_interval(days => 99 - g),
           v_user_admin
      from generate_series(1, 25) as g;

    insert into public.org_bank_accounts
        (organization_id, logical_account_id, version_no, bank_name, bik, iban,
         account_holder_name, currency_code, is_primary, valid_from, valid_to,
         created_by_user_id)
    values
        (v_org_a, v_logical_1, 26, 'QA Банк', 'QABIK001',
         'KZ' || lpad('26', 18, '0'), 'QA ARS-362 держатель', 'KZT', true,
         now() - interval '1 day', null, v_user_admin);

    -- Вторая лестница: ЗАКРЫТАЯ версия 1 и ЖИВАЯ версия 2. Закрыта она СВЕЖЕЕ всей
    -- истории первой лестницы (2 дня назад против 74), но её version_no = 1 — самый
    -- маленький в организации. Это и есть проверка на то, ЧЕМ режется граница: если
    -- резать по version_no, самая свежая закрытая запись во всей организации вылетает
    -- из ответа, проиграв версиям 7…25 первой лестницы, закрытым годы назад.
    insert into public.org_bank_accounts
        (organization_id, logical_account_id, version_no, bank_name, bik, iban,
         account_holder_name, currency_code, is_primary, valid_from, valid_to,
         created_by_user_id)
    values
        (v_org_a, v_logical_2, 1, 'QA Банк Второй', 'QABIK002',
         'KZ' || lpad('776', 18, '0'), 'QA ARS-362 второй держатель', 'KZT', false,
         now() - interval '3 days', now() - interval '2 days', v_user_admin)
    returning id into v_closed2_id;

    insert into public.org_bank_accounts
        (organization_id, logical_account_id, version_no, bank_name, bik, iban,
         account_holder_name, currency_code, is_primary, valid_from, valid_to,
         created_by_user_id)
    values
        (v_org_a, v_logical_2, 2, 'QA Банк Второй', 'QABIK002',
         'KZ' || lpad('777', 18, '0'), 'QA ARS-362 второй держатель', 'KZT', false,
         now() - interval '2 days', null, v_user_admin)
    returning id into v_live2_id;

    -- Правки критических полей: одна pending по bin_iin (M-006) + 25 закрытых (граница 20).
    insert into public.org_field_reviews
        (organization_id, field_name, previous_value, proposed_value, status,
         requested_by_user_id, requested_at)
    values (v_org_a, 'bin_iin', v_bin_prod, v_bin_proposed, 'pending',
            v_user_admin, now() - interval '3 hours')
    returning id into v_pending_id;

    -- Ещё две pending-правки, по одной на остальные критические поля: строка M-012
    -- называет тяжёлый случай как «20 версий банка + 3 правки на проверке», и три —
    -- это максимум, который допускает uq_org_field_reviews_pending (одна pending на
    -- поле, полей три). Обе старше правки БИН по requested_at, чтобы M-006 продолжал
    -- проверять именно её как первую. legal_name/address_text применяются сразу,
    -- поэтому production_value_applied_at у них обязан быть непустым
    -- (org_field_reviews_apply_timing_check), даже пока правка на проверке.
    insert into public.org_field_reviews
        (organization_id, field_name, previous_value, proposed_value, status,
         requested_by_user_id, requested_at, production_value_applied_at)
    values
        (v_org_a, 'legal_name', 'QA ARS-362 МПК полная', 'QA ARS-362 МПК переименованная',
         'pending', v_user_admin, now() - interval '5 hours', now() - interval '5 hours'),
        (v_org_a, 'address_text', 'г. QA, ул. Тестовая 1', 'г. QA, ул. Тестовая 2',
         'pending', v_user_admin, now() - interval '6 hours', now() - interval '6 hours');

    insert into public.org_field_reviews
        (organization_id, field_name, previous_value, proposed_value, status,
         requested_by_user_id, requested_at, reviewed_by_user_id, reviewed_at,
         review_note, production_value_applied_at)
    select v_org_a, 'legal_name', 'QA прежнее ' || g, 'QA предложенное ' || g,
           case when g % 2 = 0 then 'approved' else 'rejected' end,
           v_user_admin, now() - make_interval(days => 60 - g),
           v_user_turan, now() - make_interval(days => 59 - g),
           'QA заключение ' || g, now() - make_interval(days => 59 - g)
      from generate_series(1, 25) as g;

    -- ==================================================================================
    -- 2. M-005 — нет сессии: отказ «требуется вход», типизированный.
    --    Служебный путь отсутствует, поэтому сюда же приходит service_role (M-014 ниже).
    -- ==================================================================================
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims', '{}', true);
        v_res := public.rpc_get_org_profile(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'M-005: вызов без сессии вернул payload вместо отказа';
    end if;
    if v_err <> 'AUTH_REQUIRED' or v_state <> '42501' then
        raise exception 'M-005: ожидали AUTH_REQUIRED/42501, получили %/%', v_err, v_state;
    end if;

    -- ==================================================================================
    -- 3. M-014 — служебный вызов: СЛУЖЕБНОГО ПУТИ НЕТ. Отказ обязан быть НАШИМ кодом, а не
    --    «permission denied for function» — грант execute у роли есть, отсекает проверка.
    --    Строка нужна как СТОРОЖ: ветка coalesce(auth.role(),'')='service_role' была
    --    скопирована из ARS-361 машинально и вернётся тем же путём, если её не сторожить.
    -- ==================================================================================
    begin
        perform set_config('role', 'service_role', true);
        perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
        v_res := public.rpc_get_org_profile(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'M-014: служебный вызов ПРОШЁЛ — служебная дверь вернулась в предикат';
    end if;
    if v_err like 'permission denied%' then
        raise exception 'M-014: отказ пришёл сырой ошибкой прав Postgres (%) — грант '
                        'service_role снят, обработчик не сработал', v_err;
    end if;
    if v_state <> '42501' or v_err not in ('AUTH_REQUIRED') then
        raise exception 'M-014: ожидали типизированный AUTH_REQUIRED/42501 без сессии, '
                        'получили %/%', v_err, v_state;
    end if;

    -- M-014, вторая половина — ПОВЕДЕНЧЕСКИЙ сторож служебной двери, и именно он
    -- наблюдает «отсекает ПРЕДИКАТ», как требует строка матрицы. Утверждение выше
    -- слепо к двери: без клейма sub вызов падает на гейте сессии ещё ДО предиката,
    -- поэтому AUTH_REQUIRED приходит одинаково и с дверью, и без неё. Проверено
    -- мутацией: дверь, записанная не литералом auth.role(), а его разворотом
    -- current_setting('request.jwt.claims')->>'role', оставляла тест зелёным —
    -- служебный вызов читал бы банковские реквизиты ЛЮБОЙ организации.
    -- Здесь у актора роль service_role И валидный sub НЕ участника org_a: любая
    -- дверь, ключёванная по роли, каким бы способом она ни была написана, делает
    -- этот вызов успешным и роняет утверждение.
    begin
        perform set_config('role', 'service_role', true);
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_out, 'role', 'service_role')::text, true);
        v_res := public.rpc_get_org_profile(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'M-014 / FR-015: служебная роль с валидной сессией ПРОЧИТАЛА чужую '
                        'организацию — в предикате владения есть путь по роли';
    end if;
    if v_err is distinct from 'FORBIDDEN: not a member of organization ' || v_org_a::text
       or v_state <> '42501' then
        raise exception 'M-014 / FR-015: ожидали тот же FORBIDDEN, что на чужую организацию '
                        '(M-004), получили %/%', v_err, v_state;
    end if;

    -- Структурный сторож той же ветки: слагаемого auth.role() в теле быть не должно
    -- НИГДЕ — ни в гейте сессии, ни в предикате владения, ни в v_bank_read.
    v_body := pg_get_functiondef('public.rpc_get_org_profile(uuid)'::regprocedure);
    if v_body ~* 'auth\.role\s*\(' then
        raise exception 'M-014 / FR-015: в теле читателя снова появился auth.role() — '
                        'служебный путь вернулся копипастой из ARS-361';
    end if;

    -- ==================================================================================
    -- 4. M-004 / M-010 / FR-003 — чужая, несуществующая и не названная организация дают
    --    ОДИН И ТОТ ЖЕ отказ. Ключевое утверждение: при ОДНОМ И ТОМ ЖЕ входе не-участник
    --    и несуществующая организация неотличимы — иначе ответ подтверждает существование.
    -- ==================================================================================
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_out, 'role', 'authenticated')::text, true);
        v_res := public.rpc_get_org_profile(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'M-004: не-участник прочитал чужую организацию';
    end if;
    if v_err <> 'FORBIDDEN: not a member of organization ' || v_org_a::text
       or v_state <> '42501' then
        raise exception 'M-004: ожидали FORBIDDEN на % (42501), получили %/%',
            v_org_a, v_err, v_state;
    end if;

    -- не-участник спрашивает НЕСУЩЕСТВУЮЩУЮ организацию
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_out, 'role', 'authenticated')::text, true);
        v_res := public.rpc_get_org_profile(v_org_ghost);
        v_err_outsider := null;
    exception when others then
        v_err_outsider := sqlerrm;
    end;
    perform set_config('role', 'none', true);

    -- админ TURAN спрашивает ТУ ЖЕ несуществующую организацию: у него доступ есть,
    -- отсекает уже «не найдено» — за пределами блока чтения, через флаг v_org_found.
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_turan, 'role', 'authenticated')::text, true);
        v_res := public.rpc_get_org_profile(v_org_ghost);
        v_err_admin := null;
    exception when others then
        v_err_admin := sqlerrm;
    end;
    perform set_config('role', 'none', true);

    if v_err_outsider is null or v_err_admin is null then
        raise exception 'FR-003: несуществующая организация вернула payload (не-участник: %, '
                        'админ: %)', coalesce(v_err_outsider, 'PAYLOAD'),
                        coalesce(v_err_admin, 'PAYLOAD');
    end if;
    if v_err_outsider <> v_err_admin then
        raise exception 'FR-003: отказы РАЗЛИЧИМЫ — «не участник» = «%», «не существует» = '
                        '«%»: ответ подтверждает существование организации',
                        v_err_outsider, v_err_admin;
    end if;

    -- M-010: организация не названа — тот же отказ, а не веер «все мои организации».
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);
        v_res := public.rpc_get_org_profile(null);
        v_err := null;
    exception when others then
        v_err := sqlerrm; v_state := sqlstate;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'M-010: p_organization_id = null вернул payload';
    end if;
    if v_err <> 'FORBIDDEN: not a member of organization <NULL>' or v_state <> '42501' then
        raise exception 'M-010: ожидали FORBIDDEN … <NULL> (42501), получили %/%',
            v_err, v_state;
    end if;

    -- ==================================================================================
    -- 5. M-001 — happy path: участник с mpk.profile.edit И mpk.bank.manage (роль
    --    mpk_admin несёт оба права; user_organization_roles допускает одну роль на
    --    организацию, поэтому «оба права» = одна роль, а не две).
    --    SLOW PATH fn_my_org_ids: клейма app_metadata.org_ids нет, членство читается из БД.
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);
    v_res := public.rpc_get_org_profile(v_org_a);
    perform set_config('role', 'none', true);

    -- FR-005: не только присутствие, но и ЗНАЧЕНИЕ. Снапшот CHECK 11 фиксирует лишь
    -- имена ключей, а ветвиться потребитель будет по номеру редакции — незакреплённый
    -- номер можно сменить, не уронив ни одной проверки.
    if (v_res -> 'contract_version') is distinct from '1'::jsonb then
        raise exception 'FR-005 / M-001: contract_version = % (ожидали 1)',
            v_res -> 'contract_version';
    end if;
    if (v_res #>> '{organization,legal_name}') is distinct from 'QA ARS-362 МПК полная' then
        raise exception 'M-001: organization.legal_name = %', v_res #>> '{organization,legal_name}';
    end if;
    -- region_name: денормализация региона на чтении (Assumptions). Утверждается ИМЕНЕМ,
    -- иначе join региона можно перевести на любую другую колонку и тест не заметит.
    if (v_res #>> '{organization,region_name}') is distinct from v_region_name then
        raise exception 'M-001: organization.region_name = % (ожидали %)',
            v_res #>> '{organization,region_name}', v_region_name;
    end if;
    if (v_res #>> '{organization,head_full_name}') is distinct from 'Тестов Тест Тестович'
       or (v_res #>> '{organization,head_title}') is distinct from 'Директор' then
        raise exception 'M-001: руководитель в ответе не совпал';
    end if;
    -- org_types: положительное утверждение, а не только отрицательное (триаж №7).
    if not coalesce((v_res #> '{organization,org_types}') @> '["mpk"]'::jsonb, false) then
        raise exception 'M-001: organization.org_types = % (ожидали mpk)',
            v_res #>> '{organization,org_types}';
    end if;
    if (v_res #>> '{profile,public_description}') is distinct from 'QA описание МПК для ARS-362' then
        raise exception 'M-001: profile.public_description не совпал';
    end if;
    -- Активная ПЕРВИЧНАЯ площадка, и именно она: вторая активная не первичная не должна
    -- подменять её ни при какой сортировке.
    if (v_res #>> '{primary_site,site_name}') is distinct from 'QA площадка первичная' then
        raise exception 'M-001: primary_site.site_name = % (ожидали первичную)',
            v_res #>> '{primary_site,site_name}';
    end if;
    if (v_res #>> '{primary_site,region_name}') is distinct from v_site_rname then
        raise exception 'M-001: primary_site.region_name = % (ожидали %)',
            v_res #>> '{primary_site,region_name}', v_site_rname;
    end if;
    if (v_res #>> '{primary_site,processing_capacity_heads_per_day}') is distinct from '120' then
        raise exception 'M-001: мощность площадки = %',
            v_res #>> '{primary_site,processing_capacity_heads_per_day}';
    end if;
    if (v_res #>> '{bank,access}') is distinct from 'granted' then
        raise exception 'M-001: bank.access = % (ожидали granted)', v_res #>> '{bank,access}';
    end if;
    -- Денежные реквизиты названы ПОИМЁННО: снапшот CHECK 11 их видит только потому, что
    -- строки собраны явными jsonb_build_object, а не to_jsonb (CONTRACT-SNAPSHOT-TOJSONB-ROWS-01).
    if (v_res #>> '{bank,current,iban}') is distinct from 'KZ' || lpad('26', 18, '0')
       or (v_res #>> '{bank,current,bik}') is distinct from 'QABIK001'
       or (v_res #>> '{bank,current,bank_name}') is distinct from 'QA Банк'
       or (v_res #>> '{bank,current,account_holder_name}') is distinct from 'QA ARS-362 держатель'
       or (v_res #>> '{bank,current,currency_code}') is distinct from 'KZT' then
        raise exception 'M-001: реквизиты в bank.current не совпали: %', v_res #> '{bank,current}';
    end if;
    if (v_res #>> '{permissions,mpk.profile.edit}') is distinct from 'true'
       or (v_res #>> '{permissions,mpk.bank.manage}') is distinct from 'true' then
        raise exception 'M-001: permissions у mpk_admin = %', v_res -> 'permissions';
    end if;

    -- ==================================================================================
    -- 6. M-007 / M-013 / FR-019 — актуальная запись отдельно, история отдельно; граница
    --    режет ТОЛЬКО закрытые версии, живая запись не выпадает из ответа.
    -- ==================================================================================
    if (v_res #>> '{bank,current,version_no}') is distinct from '26'
       or (v_res #>> '{bank,current,is_primary}') is distinct from 'true'
       or (v_res #>> '{bank,current,valid_to}') is not null then
        raise exception 'M-007: bank.current не действующая primary-версия: %',
            v_res #> '{bank,current}';
    end if;

    v_hist := v_res #> '{bank,history}';
    -- 20 закрытых (граница) + 1 живая мимо границы = 21
    if coalesce(jsonb_array_length(v_hist), -1) <> 21 then
        raise exception 'M-013 / FR-019: в bank.history % записей, ожидали 21 '
                        '(20 закрытых + 1 живая мимо границы)', jsonb_array_length(v_hist);
    end if;
    -- ВТОРОЙ ЖИВОЙ счёт обязан быть в ответе: общий limit по version_no desc вытолкнул бы
    -- его целиком (version_no = 1 у второй лестницы), потеряв денежные реквизиты.
    if not exists (
        select 1
          from jsonb_array_elements(v_hist) as h
         where (h.value ->> 'account_id') = v_live2_id::text
           and (h.value ->> 'valid_to') is null
    ) then
        raise exception 'M-013 / FR-019: второй ЖИВОЙ счёт (%) выпал из ответа — граница '
                        'применена сквозь лестницы', v_live2_id;
    end if;
    -- Счётчик отражает ПОЛНЫЙ объём истории (25 закрытых + 1 живая не-current = 26),
    -- а не число отданных строк: иначе обрезка молчалива.
    -- 26 закрытых (25 первой лестницы + 1 второй) + 1 живая не-current = 27.
    if (v_res #>> '{bank,history_total}') is distinct from '27' then
        raise exception 'M-013 / FR-019: bank.history_total = % (ожидали 27)',
            v_res #>> '{bank,history_total}';
    end if;
    if (v_res #>> '{bank,history_total}')::int = jsonb_array_length(v_hist) then
        raise exception 'M-013: history_total совпал с длиной history — граница проверена '
                        'на данных, где она не срабатывает';
    end if;
    -- РЕЗ и ПОРЯДОК проверяются РАЗДЕЛЬНО: это два разных требования, и первая редакция
    -- этой сборки их слила, из-за чего порядок перестал быть «по убыванию версии».
    --
    -- (1) РЕЗ — 20 ПОСЛЕДНИХ закрытых версий (Dok3 RPC-63), то есть по времени закрытия.
    -- Самая свежая закрытая запись организации — версия 1 ВТОРОЙ лестницы (закрыта 2 дня
    -- назад); при резке по version_no она проиграла бы версиям 7…25 первой лестницы,
    -- закрытым 74–92 дня назад, и пропала бы из ответа совсем. Проверяется ПРИСУТСТВИЕ,
    -- а не позиция: позиция — дело порядка, и требовать её здесь значило бы снова
    -- смешать два требования.
    if not exists (
        select 1
          from jsonb_array_elements(v_hist) as h
         where (h.value ->> 'account_id') = v_closed2_id::text
    ) then
        raise exception 'M-007 / FR-019: самая свежая ЗАКРЫТАЯ версия (%) выпала из '
                        'истории — граница режет по номеру версии, а не по времени '
                        'закрытия', v_closed2_id;
    end if;

    -- (2) ПОРЯДОК — FR-006 дословно: закрытые версии идут по убыванию version_no.
    -- Проверяется монотонность всей закрытой подпоследовательности, а не одна позиция:
    -- утверждение на фиксированном индексе прошло бы и на порядке по времени закрытия.
    if exists (
        select 1
          from (
               select (h.value ->> 'version_no')::int as v,
                      lag((h.value ->> 'version_no')::int)
                          over (order by h.ordinality) as prev
                 from jsonb_array_elements(v_hist)
                          with ordinality as h(value, ordinality)
                where (h.value ->> 'valid_to') is not null
          ) s
         where s.prev is not null
           and s.v > s.prev
    ) then
        raise exception 'M-007 / FR-006: закрытые версии в bank.history идут НЕ по '
                        'убыванию version_no: %', v_hist;
    end if;

    -- (3) Живые записи, не попавшие в current, идут ПЕРВЫМИ: они действующие, и
    -- показывать их в хвосте по номеру версии значило бы выдать денежные реквизиты
    -- за историю (FR-019).
    if exists (
        select 1
          from jsonb_array_elements(v_hist) with ordinality as h(value, ordinality)
         where (h.value ->> 'valid_to') is null
           and h.ordinality > (
               select min(c.ordinality)
                 from jsonb_array_elements(v_hist) with ordinality as c(value, ordinality)
                where (c.value ->> 'valid_to') is not null
           )
    ) then
        raise exception 'M-007 / FR-019: живая запись стоит ПОСЛЕ закрытой — действующие '
                        'реквизиты показаны как история: %', v_hist;
    end if;
    -- Триаж №14: дублирующего ключа id в строках истории нет — только account_id.
    if (v_hist -> 0) ? 'id' then
        raise exception 'M-007: в строке bank.history снова появился дублирующий ключ id';
    end if;

    -- ==================================================================================
    -- 7. M-006 — БИН на проверке: organization.bin_iin остаётся ПРОД-значением, правка
    --    приходит отдельно, с прежним/предложенным значением, актором и временем.
    -- ==================================================================================
    if (v_res #>> '{organization,bin_iin}') is distinct from v_bin_prod then
        raise exception 'M-006: organization.bin_iin = % — в ответ утекло предложенное '
                        'значение вместо прод-значения', v_res #>> '{organization,bin_iin}';
    end if;
    -- Три pending-правки — тяжёлый случай строки M-012 в его названном виде.
    if coalesce(jsonb_array_length(v_res #> '{field_reviews,pending}'), -1) <> 3 then
        raise exception 'M-006 / M-012: pending-правок % вместо трёх',
            jsonb_array_length(v_res #> '{field_reviews,pending}');
    end if;
    if not coalesce(
           (select bool_and(f = any (array(
                        select jsonb_array_elements(v_res #> '{field_reviews,pending}')
                                   ->> 'field_name')))
              from unnest(array['bin_iin', 'legal_name', 'address_text']) as f),
           false) then
        raise exception 'M-006: в pending пришли не все три критических поля: %',
            v_res #> '{field_reviews,pending}';
    end if;
    if (v_res #>> '{field_reviews,pending,0,id}') is distinct from v_pending_id::text then
        raise exception 'M-006: в pending пришла не та правка (% вместо %)',
            v_res #>> '{field_reviews,pending,0,id}', v_pending_id;
    end if;
    if (v_res #>> '{field_reviews,pending,0,field_name}') is distinct from 'bin_iin'
       or (v_res #>> '{field_reviews,pending,0,previous_value}') is distinct from v_bin_prod
       or (v_res #>> '{field_reviews,pending,0,proposed_value}') is distinct from v_bin_proposed
       or (v_res #>> '{field_reviews,pending,0,requested_by_user_id}') is distinct from v_user_admin::text
       or (v_res #>> '{field_reviews,pending,0,requested_at}') is null then
        raise exception 'M-006: pending-правка неполна: %', v_res #> '{field_reviews,pending,0}';
    end if;
    -- Граница resolved_recent прожата: 25 закрытых, отдано 20, счётчик полный.
    if coalesce(jsonb_array_length(v_res #> '{field_reviews,resolved_recent}'), -1) <> 20 then
        raise exception 'FR-006: resolved_recent = % записей, ожидали 20',
            jsonb_array_length(v_res #> '{field_reviews,resolved_recent}');
    end if;
    if (v_res #>> '{field_reviews,resolved_total}') is distinct from '25' then
        raise exception 'FR-006: resolved_total = % (ожидали 25)',
            v_res #>> '{field_reviews,resolved_total}';
    end if;

    -- ==================================================================================
    -- 8. FR-015 / FR-016 — доказательством членства служит подписанный клейм
    --    app_metadata.org_ids (FAST PATH fn_my_org_ids), а не аргумент вызова.
    --    Прод-путь именно этот, и он обязан быть покрыт — в сборке 56631d8 тест
    --    проверял только slow path (триаж №21).
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated',
                          'app_metadata', json_build_object('org_ids',
                              json_build_array(v_org_a)))::text, true);
    v_res_fast := public.rpc_get_org_profile(v_org_a);
    perform set_config('role', 'none', true);
    if (v_res_fast #>> '{organization,id}') is distinct from v_org_a::text then
        raise exception 'FR-015: fast path (клейм app_metadata.org_ids) не дал доступа';
    end if;

    -- Обратная сторона того же факта — окно устаревания членства (FR-016, долг
    -- JWT-MEMBERSHIP-STALENESS-01): клейм ПЕРЕВЕШИВАЕТ запись в БД. Пользователь
    -- состоит в org_a по базе, но клейм называет только org_b — доступа к org_a нет.
    -- Утверждение стоит здесь, чтобы окно было видимым фактом, а не сноской.
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_auth_admin, 'role', 'authenticated',
                              'app_metadata', json_build_object('org_ids',
                                  json_build_array(v_org_b)))::text, true);
        v_res := public.rpc_get_org_profile(v_org_a);
        v_err := null;
    exception when others then
        v_err := sqlerrm;
    end;
    perform set_config('role', 'none', true);
    if v_err is null then
        raise exception 'FR-015: клейм назвал другую организацию, а доступ к org_a остался — '
                        'значит членство доказывается не клеймом и не базой';
    end if;

    -- ==================================================================================
    -- 9. M-003 — участник без mpk.bank.manage: признак «доступ закрыт», реквизитов НЕТ
    --    В СЕТЕВОМ ОТВЕТЕ. Роль accountant отделяет два флага прав друг от друга: если
    --    строки permissions поменять местами, этот блок и следующий разойдутся.
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_empl, 'role', 'authenticated')::text, true);
    v_res_empl := public.rpc_get_org_profile(v_org_a);
    perform set_config('role', 'none', true);

    if (v_res_empl #>> '{bank,access}') is distinct from 'denied' then
        raise exception 'M-003: bank.access = % у участника без права',
            v_res_empl #>> '{bank,access}';
    end if;
    if (v_res_empl #> '{bank,current}') is not null
       and (v_res_empl #> '{bank,current}') is distinct from 'null'::jsonb then
        raise exception 'M-003: реквизиты пришли БЕЗ права: %', v_res_empl #> '{bank,current}';
    end if;
    if coalesce(jsonb_array_length(v_res_empl #> '{bank,history}'), -1) <> 0
       or (v_res_empl #>> '{bank,history_total}') is distinct from '0' then
        raise exception 'M-003: история банка пришла без права: % / %',
            v_res_empl #> '{bank,history}', v_res_empl #>> '{bank,history_total}';
    end if;
    v_leak := v_res_empl::text;
    if v_leak like '%KZ' || lpad('26', 18, '0') || '%' or v_leak like '%QABIK00%' then
        raise exception 'M-003 / FR-004: IBAN или БИК присутствуют в сетевом ответе без права';
    end if;
    -- Раздел остаётся читаемым: под правом лежит только подблок банка (FR-004).
    if (v_res_empl #>> '{organization,legal_name}') is null
       or (v_res_empl #>> '{primary_site,site_name}') is null then
        raise exception 'M-003: без права на банк закрылся весь раздел, а не подблок';
    end if;
    if (v_res_empl #>> '{permissions,mpk.profile.edit}') is distinct from 'false'
       or (v_res_empl #>> '{permissions,mpk.bank.manage}') is distinct from 'false' then
        raise exception 'M-003: permissions у employee = %', v_res_empl -> 'permissions';
    end if;

    -- accountant: банк ЕСТЬ, правка профиля НЕТ — флаги разделены.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_acct, 'role', 'authenticated')::text, true);
    v_res_acct := public.rpc_get_org_profile(v_org_a);
    perform set_config('role', 'none', true);

    if (v_res_acct #>> '{bank,access}') is distinct from 'granted'
       or (v_res_acct #>> '{bank,current,iban}') is distinct from 'KZ' || lpad('26', 18, '0') then
        raise exception 'FR-004: accountant с mpk.bank.manage не получил реквизиты: %',
            v_res_acct #> '{bank}';
    end if;
    if (v_res_acct #>> '{permissions,mpk.bank.manage}') is distinct from 'true'
       or (v_res_acct #>> '{permissions,mpk.profile.edit}') is distinct from 'false' then
        raise exception 'FR-004: у accountant флаги прав не разделены: %',
            v_res_acct -> 'permissions';
    end if;

    -- ==================================================================================
    -- 10. M-008 — админ TURAN: доступ к запрошенной организации, включая банк. При этом
    --     permissions отражают права на ЗАПИСЬ, которых у него нет: обратное обещало бы
    --     экрану запись, которую писатели ARS-359 отклонят с 42501.
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_turan, 'role', 'authenticated')::text, true);
    v_res_turan := public.rpc_get_org_profile(v_org_a);
    perform set_config('role', 'none', true);

    if (v_res_turan #>> '{organization,id}') is distinct from v_org_a::text then
        raise exception 'M-008: админ TURAN не получил организацию';
    end if;
    if (v_res_turan #>> '{bank,access}') is distinct from 'granted'
       or (v_res_turan #>> '{bank,current,iban}') is distinct from 'KZ' || lpad('26', 18, '0') then
        raise exception 'M-008: админ TURAN не получил банк: %', v_res_turan #> '{bank}';
    end if;
    if (v_res_turan #>> '{permissions,mpk.bank.manage}') is distinct from 'false'
       or (v_res_turan #>> '{permissions,mpk.profile.edit}') is distinct from 'false' then
        raise exception 'M-008: админу обещаны права на запись, которых писатели не дадут: %',
            v_res_turan -> 'permissions';
    end if;

    -- ==================================================================================
    -- 11. M-002 — профиль ещё не заполнен: секции ПУСТЫЕ, но отличимые от «нет доступа».
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);
    v_res_empty := public.rpc_get_org_profile(v_org_d);
    perform set_config('role', 'none', true);

    if (v_res_empty #>> '{organization,legal_name}') is distinct from 'QA ARS-362 МПК пустая' then
        raise exception 'M-002: блок организации не заполнен';
    end if;
    if (v_res_empty -> 'profile') is not null
       and (v_res_empty -> 'profile') is distinct from 'null'::jsonb then
        raise exception 'M-002: profile не пуст: %', v_res_empty -> 'profile';
    end if;
    if (v_res_empty -> 'primary_site') is not null
       and (v_res_empty -> 'primary_site') is distinct from 'null'::jsonb then
        raise exception 'M-002: primary_site не пуст: %', v_res_empty -> 'primary_site';
    end if;
    -- Ключевое различие M-002 vs M-003: пусто, но ДОСТУП ЕСТЬ.
    if (v_res_empty #>> '{bank,access}') is distinct from 'granted' then
        raise exception 'M-002: пустой банк отдан как «нет доступа» (%) — состояния '
                        'неотличимы для экрана', v_res_empty #>> '{bank,access}';
    end if;
    if (v_res_empty #>> '{bank,history_total}') is distinct from '0'
       or coalesce(jsonb_array_length(v_res_empty #> '{bank,history}'), -1) <> 0 then
        raise exception 'M-002: пустая история банка непуста';
    end if;
    if coalesce(jsonb_array_length(v_res_empty #> '{field_reviews,pending}'), -1) <> 0
       or (v_res_empty #>> '{field_reviews,resolved_total}') is distinct from '0' then
        raise exception 'M-002: след правок непуст у пустой организации';
    end if;
    if (v_res_empty #>> '{organization,region_name}') is not null then
        raise exception 'M-002: region_name без региона = % (ожидали null)',
            v_res_empty #>> '{organization,region_name}';
    end if;

    -- ==================================================================================
    -- 12. M-009 — организация НЕ МПК: тот же payload с пустыми МПК-секциями, НЕ отказ.
    --     Плюс гейт permissions: писатели ARS-359 сверх права требуют is_active + mpk,
    --     поэтому флаги здесь false, хотя роль mpk_admin право несёт (триаж №4).
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);
    v_res_nonmpk := public.rpc_get_org_profile(v_org_c);
    perform set_config('role', 'none', true);

    if (v_res_nonmpk #>> '{organization,legal_name}') is distinct from 'QA ARS-362 не МПК' then
        raise exception 'M-009: не-МПК организация не отдана (403 по типу обещал бы '
                        'проверку, которой нет)';
    end if;
    if (v_res_nonmpk #> '{organization,org_types}') is distinct from '[]'::jsonb then
        raise exception 'M-009: org_types у не-МПК = %', v_res_nonmpk #> '{organization,org_types}';
    end if;
    if (v_res_nonmpk -> 'profile') is distinct from 'null'::jsonb
       or (v_res_nonmpk -> 'primary_site') is distinct from 'null'::jsonb then
        raise exception 'M-009: МПК-секции не пусты у не-МПК организации';
    end if;
    if (v_res_nonmpk #>> '{permissions,mpk.profile.edit}') is distinct from 'false' then
        raise exception 'M-009: читатель обещает mpk.profile.edit в не-МПК организации — '
                        'писатель отклонит её с ORG_NOT_ACTIVE_MPK';
    end if;

    -- Погашенная организация (is_active = false) — вторая половина того же гейта.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);
    v_res_inactive := public.rpc_get_org_profile(v_org_e);
    perform set_config('role', 'none', true);

    if (v_res_inactive #>> '{organization,is_active}') is distinct from 'false' then
        raise exception 'permissions-гейт: фикстура погашенной организации недостоверна';
    end if;
    if (v_res_inactive #>> '{permissions,mpk.profile.edit}') is distinct from 'false'
       or (v_res_inactive #>> '{permissions,mpk.bank.manage}') is distinct from 'false' then
        raise exception 'триаж №4: читатель обещает запись в ПОГАШЕННОЙ организации: %',
            v_res_inactive -> 'permissions';
    end if;

    -- ==================================================================================
    -- 13. M-011 — внутренний сбой чтения. ЗАКРЫТО СТРУКТУРНО, НЕ ПОВЕДЕНИЕМ: инсценировать
    --     сбой внутри обёрнутого блока нечем (statement_timeout даёт query_canceled,
    --     который when others по определению не ловит; DDL по живой таблице берёт ACCESS
    --     EXCLUSIVE на боевой базе — изолированной среды нет). Долг:
    --     IMPL_DEBT ARS-362-M011-NO-FAULT-INJECTION-01. В пакете G3 строка идёт как
    --     СТРУКТУРНАЯ — «passed» без этого слова означает невыполненный долг.
    -- ==================================================================================
    if v_body not like '%PROFILE_READ_FAILED%' then
        raise exception 'M-011 (структурно): в теле нет обработчика PROFILE_READ_FAILED';
    end if;
    if v_body ~* 'when\s+insufficient_privilege\s+then' then
        raise exception 'M-011 / FR-018 (структурно): вернулся passthrough '
                        '«when insufficient_privilege then raise» — он выпускает наружу '
                        'родной permission denied, то есть текст SQL-исключения (триаж №6)';
    end if;
    if v_body not like '%raise log%' then
        raise exception 'M-011 (структурно): sqlerrm/sqlstate не уходят в серверный лог';
    end if;
    -- FR-018: наружу идёт КОД. Готовой человекочитаемой формулировки в теле быть не должно.
    if v_body ~ 'using\s+message' then
        raise exception 'FR-018 (структурно): в теле появился using message — дом текста '
                        'ошибки клиент, а не БД';
    end if;

    -- ==================================================================================
    -- 14. M-012 / FR-014 — тяжёлая организация: p95 < 200 мс. Порог и p95 названы явно;
    --     замер идёт по org_a (26 версий банка, 26 правок, заполненная площадка) на
    --     сид-данных СРЕДЫ ПРИЁМКИ — изолированной среды нет (QA-ENV-ISOLATION-01),
    --     поэтому условия замера обязаны быть названы в пакете G3, иначе цифра
    --     несравнима между прогонами.
    -- ==================================================================================
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_admin, 'role', 'authenticated')::text, true);
    for i in 1..20 loop
        v_t0 := clock_timestamp();
        perform public.rpc_get_org_profile(v_org_a);
        v_durations := v_durations
            || (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::double precision;
    end loop;
    perform set_config('role', 'none', true);

    select percentile_disc(0.95) within group (order by d)
      into v_p95
      from unnest(v_durations) as d;

    raise notice 'M-012: p95 = % мс на 20 прогонах (порог 200 мс), условия замера — '
                 'среда приёмки, фикстуры этого файла', round(v_p95::numeric, 2);
    if v_p95 >= 200 then
        raise exception 'M-012 / FR-014: p95 = % мс >= 200 мс', round(v_p95::numeric, 2);
    end if;

    raise notice 'ARS-362: ЗЕЛЁНО. Поведенчески закрыты M-001…M-010, M-012…M-014; '
                 'M-011 — СТРУКТУРНО (ARS-362-M011-NO-FAULT-INJECTION-01).';
end;
$$;

rollback;
