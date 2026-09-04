-- ARS-362 / MP-2.1 regression contract for public.rpc_get_org_profile.
-- Run after supabase/migrations/20260904120000_ars_362_org_profile_read.sql.
-- Spec: Docs/AGOS-MPK-Profile-ReadRPC-ARS-362.md (frozen FR-001…FR-014 / M-001…M-012).
--
-- Every assertion below names the matrix id it covers, so the G3 Matrix Test Audit can be
-- matched by id and never by eye. Coverage of this file:
--   M-001 M-002 M-003 M-004 M-005 M-006 M-007 M-008 M-009 M-010 M-012  — behavioural
--   M-011                                                             — STRUCTURAL ONLY
-- M-011 (internal read failure) needs fault injection. The only injection available here is
-- DDL on a live table inside the transaction, which takes an ACCESS EXCLUSIVE lock on
-- production — there is no isolated environment (IMPL_DEBT QA-ENV-ISOLATION-01). The row is
-- therefore asserted structurally and reported as unmatched-behaviourally in the G3 packet;
-- it is NOT silently counted as covered.
--
-- The whole file runs inside one transaction and ends in ROLLBACK: read-path fixtures leave
-- no residue in the live database.
--
-- ПРАВА ЖИВЫХ ЛЮДЕЙ ТЕСТ НЕ ТРОГАЕТ. Фикстура создаёт СВОЕГО auth-пользователя (триггер
-- trg_on_auth_user_created делает под него public.users) и выдаёт права только ему. Ни одной
-- существующей строки users / admin_roles / user_organization_roles файл не читает и не меняет.
-- Так было не всегда: до 2026-09-04 тест брал первого действующего админа TURAN и гасил ему
-- admin_roles.is_active, чтобы отделить member-путь от admin-пути, — целость держалась только
-- на rollback'е, то есть обрыв сессии оставлял реального человека без прав. Решение владельца
-- (Dias, 2026-09-04): полагаться на rollback боевой базы для снятия прав у живого человека
-- недопустимо, даже когда он срабатывает. Admin-путь (M-008) теперь получается ВЫДАЧЕЙ права
-- своему пользователю, а не отбором чужого.

begin;

do $$
declare
    v_user_id           uuid;                        -- собственный пользователь фикстуры
    v_auth_id           uuid := gen_random_uuid();   -- собственный auth-пользователь
    v_org_id            uuid := gen_random_uuid();   -- full MPK org, caller is mpk_admin
    v_empty_org_id      uuid := gen_random_uuid();   -- M-002: nothing filled in
    v_nobank_org_id     uuid := gen_random_uuid();   -- M-003: caller is procurement
    v_nonmpk_org_id     uuid := gen_random_uuid();   -- M-009: no 'mpk' type assignment
    v_foreign_org_id    uuid := gen_random_uuid();   -- M-004: caller is not a member
    v_site_id           uuid;
    v_bank_v1_id        uuid := gen_random_uuid();
    v_bank_v2_id        uuid := gen_random_uuid();
    v_logical_id        uuid := gen_random_uuid();
    v_prod_bin          text := '990362000001';
    v_result            jsonb;
    v_result2           jsonb;
    v_denied_foreign    text;
    v_denied_null       text;
    v_err               text;
    v_blocked           boolean;
    v_def               text;
    v_started           timestamptz;
    v_elapsed_ms        numeric;
    i                   int;
begin
    -- Страховка до ПЕРВОЙ записи: файл обязан идти внутри ЯВНОЙ транзакции, которая
    -- кончается rollback'ом. При автокоммите фикстуры осели бы в боевой базе.
    -- Проверка именно такая, потому что `xact_start is not null` вакуумна: при автокоммите
    -- statement тоже идёт в неявной транзакции, и это условие истинно ВСЕГДА (проверено
    -- эмпирически). transaction_timestamp() фиксируется на begin и не двигается, а
    -- statement_timestamp() растёт с каждым statement — различие есть только в явной
    -- транзакции. Оговорка: если бы этот do-блок был самым первым statement'ом сразу за
    -- begin, при грубом разрешении часов метки теоретически могли совпасть.
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-362_TEST_SETUP: файл обязан идти в явной транзакции (begin … rollback)';
    end if;

    -- Фикстура работает от СОБСТВЕННОГО пользователя. Прав живых людей тест не касается:
    -- ни одной существующей строки users / admin_roles / user_organization_roles он не
    -- читает и не меняет. Раньше здесь брался первый действующий админ TURAN и ему
    -- гасился is_active, чтобы отделить member-путь от admin-пути — целость держалась
    -- только на rollback'е, то есть обрыв сессии оставлял реального человека без прав.
    -- Теперь admin-путь получается не гашением чужого права, а выдачей своего (M-008).
    insert into auth.users (id, email)
    values (v_auth_id, 'qa-ars362-' || replace(v_auth_id::text, '-', '') || '@example.test');
    -- trg_on_auth_user_created → fn_handle_new_auth_user() создаёт public.users сам.
    select u.id into v_user_id from public.users u where u.auth_id = v_auth_id;
    if v_user_id is null then
        raise exception 'ARS-362_TEST_SETUP: public.users не создан триггером auth.users';
    end if;

    -- -------------------------------------------------------------------------
    -- Grants (Design contract): anon must not reach the reader at all.
    -- -------------------------------------------------------------------------
    if has_function_privilege('anon', 'public.rpc_get_org_profile(uuid)', 'execute') then
        raise exception 'ARS-362: anon can execute rpc_get_org_profile';
    end if;
    if not has_function_privilege('authenticated', 'public.rpc_get_org_profile(uuid)', 'execute')
       or not has_function_privilege('service_role', 'public.rpc_get_org_profile(uuid)', 'execute') then
        raise exception 'ARS-362: authenticated/service_role cannot execute rpc_get_org_profile';
    end if;
    if not exists (
        select 1 from public.rpc_name_registry
        where sql_name = 'rpc_get_org_profile' and status = 'active'
    ) then
        raise exception 'ARS-362: rpc_get_org_profile is not registered in rpc_name_registry (D-NEW-A)';
    end if;

    -- -------------------------------------------------------------------------
    -- Fixture
    -- -------------------------------------------------------------------------
    insert into public.organizations (id, legal_name, bin_iin, legal_form, address_text, phone, email, website, head_full_name, head_title)
    values
        (v_org_id,         'QA ARS-362 MPK',        v_prod_bin,     'too', 'Production address', '+77010362001', 'mpk@example.test', 'https://example.test', 'QA Director', 'General Director'),
        (v_empty_org_id,   'QA ARS-362 EMPTY',      '990362000002', 'too', null, null, null, null, null, null),
        (v_nobank_org_id,  'QA ARS-362 NOBANK',     '990362000003', 'too', 'Nobank address', null, null, null, null, null),
        (v_nonmpk_org_id,  'QA ARS-362 NONMPK',     '990362000004', 'kh',  'Farm address', null, null, null, null, null),
        (v_foreign_org_id, 'QA ARS-362 FOREIGN',    '990362000005', 'too', 'Foreign address', null, null, null, null, null);

    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_id, 'mpk'), (v_empty_org_id, 'mpk'), (v_nobank_org_id, 'mpk'),
           (v_nonmpk_org_id, 'farmer'), (v_foreign_org_id, 'mpk');

    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values (v_user_id, v_org_id,        'mpk_admin',   false),
           (v_user_id, v_empty_org_id,  'mpk_admin',   false),
           (v_user_id, v_nobank_org_id, 'procurement', false),
           (v_user_id, v_nonmpk_org_id, 'mpk_admin',   false);

    insert into public.mpk_profiles (organization_id, public_description, logo_path)
    values (v_org_id, 'QA public description', 'mpk/' || v_org_id || '/logo.png');

    insert into public.mpk_sites (
        id, organization_id, site_name, address_text,
        processing_capacity_heads_per_day, phone, email, is_primary, is_active
    ) values (
        gen_random_uuid(), v_org_id, 'QA main intake', 'QA site address',
        150, '+77010362009', 'site@example.test', true, true
    ) returning id into v_site_id;

    -- M-007 fixture: two versions of one logical bank account, v1 superseded by v2.
    insert into public.org_bank_accounts (
        id, organization_id, logical_account_id, version_no, bank_name, bik, iban,
        account_holder_name, currency_code, is_primary, valid_from, valid_to
    ) values (
        v_bank_v1_id, v_org_id, v_logical_id, 1, 'QA Bank', 'QATEST01',
        'KZ' || lpad('1', 18, '0'), 'QA ARS-362 MPK', 'KZT', false,
        now() - interval '2 days', now() - interval '1 day'
    ), (
        v_bank_v2_id, v_org_id, v_logical_id, 2, 'QA Bank', 'QATEST01',
        'KZ' || lpad('2', 18, '0'), 'QA ARS-362 MPK', 'KZT', true,
        now() - interval '1 day', null
    );

    -- M-006 fixture: a pending bin_iin proposal plus one resolved legal_name proposal.
    insert into public.org_field_reviews (
        organization_id, field_name, previous_value, proposed_value, status,
        requested_by_user_id, requested_at
    ) values (
        v_org_id, 'bin_iin', v_prod_bin, '990362999999', 'pending',
        v_user_id, now() - interval '3 hours'
    );
    insert into public.org_field_reviews (
        organization_id, field_name, previous_value, proposed_value, status,
        requested_by_user_id, requested_at, reviewed_by_user_id, reviewed_at,
        production_value_applied_at
    ) values (
        v_org_id, 'legal_name', 'QA ARS-362 OLD', 'QA ARS-362 MPK', 'approved',
        v_user_id, now() - interval '2 days', v_user_id,
        now() - interval '2 days', now() - interval '2 days'
    );

    -- Bank details also exist for the no-permission org: M-003 must prove they are absent
    -- from the network payload, not merely hidden by the screen.
    insert into public.org_bank_accounts (
        organization_id, logical_account_id, version_no, bank_name, bik, iban,
        account_holder_name, currency_code, is_primary
    ) values (
        v_nobank_org_id, gen_random_uuid(), 1, 'QA Secret Bank', 'QASECRET',
        'KZ' || lpad('7', 18, '0'), 'QA ARS-362 NOBANK', 'KZT', true
    );

    -- =========================================================================
    -- M-001…M-007 и M-009…M-010 идут от обычного участника организации: своей строки в
    -- admin_roles у пользователя фикстуры ПОКА НЕТ, поэтому admin-байпас не может замаскировать
    -- ни одно member-утверждение ниже. Право админа выдаётся себе позже, ровно на M-008.
    -- =========================================================================
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_auth_id::text, 'role', 'authenticated')::text,
        true
    );

    -- ---------------------------------------------------------------- M-001 --
    -- Happy path: one call returns organization, profile, site, bank, reviews, permissions.
    v_result := public.rpc_get_org_profile(v_org_id);
    if v_result ->> 'contract_version' is distinct from '1' then
        raise exception 'M-001/FR-005: contract_version missing or not 1: %', v_result;
    end if;
    if v_result #>> '{organization,id}' is distinct from v_org_id::text
       or v_result #>> '{organization,legal_name}' is distinct from 'QA ARS-362 MPK'
       or v_result #>> '{organization,address_text}' is distinct from 'Production address'
       or v_result #>> '{organization,head_full_name}' is distinct from 'QA Director'
       or v_result #>> '{organization,phone}' is distinct from '+77010362001' then
        raise exception 'M-001: organization block incomplete: %', v_result -> 'organization';
    end if;
    if v_result #>> '{profile,public_description}' is distinct from 'QA public description' then
        raise exception 'M-001: profile block incomplete: %', v_result -> 'profile';
    end if;
    if v_result #>> '{primary_site,id}' is distinct from v_site_id::text
       or v_result #>> '{primary_site,processing_capacity_heads_per_day}' is distinct from '150' then
        raise exception 'M-001: primary_site block incomplete: %', v_result -> 'primary_site';
    end if;
    if v_result #>> '{bank,access}' is distinct from 'granted'
       or v_result #>> '{bank,current,account_id}' is distinct from v_bank_v2_id::text then
        raise exception 'M-001: bank block incomplete for a mpk.bank.manage holder: %', v_result -> 'bank';
    end if;
    if v_result #>> '{permissions,mpk.profile.edit}' is distinct from 'true'
       or v_result #>> '{permissions,mpk.bank.manage}' is distinct from 'true' then
        raise exception 'M-001: effective permissions not projected: %', v_result -> 'permissions';
    end if;
    if jsonb_array_length(v_result #> '{field_reviews,pending}') <> 1
       or v_result ->> 'field_reviews' is null then
        raise exception 'M-001: field_reviews block incomplete: %', v_result -> 'field_reviews';
    end if;

    -- ---------------------------------------------------------------- M-002 --
    -- Empty profile: sections are empty but distinguishable from «no access», and the
    -- organization block is still filled.
    v_result2 := public.rpc_get_org_profile(v_empty_org_id);
    if v_result2 #>> '{organization,legal_name}' is distinct from 'QA ARS-362 EMPTY' then
        raise exception 'M-002: organization block must stay filled on an empty profile: %', v_result2;
    end if;
    if jsonb_typeof(v_result2 -> 'profile') is distinct from 'null'
       or jsonb_typeof(v_result2 -> 'primary_site') is distinct from 'null' then
        raise exception 'M-002: empty profile/site must be JSON null: %', v_result2;
    end if;
    if v_result2 #>> '{bank,access}' is distinct from 'granted'
       or jsonb_typeof(v_result2 #> '{bank,current}') is distinct from 'null'
       or jsonb_array_length(v_result2 #> '{bank,history}') <> 0 then
        raise exception 'M-002: an empty bank must read as granted-but-empty, not as denied: %',
            v_result2 -> 'bank';
    end if;
    if jsonb_array_length(v_result2 #> '{field_reviews,pending}') <> 0
       or (v_result2 #>> '{field_reviews,resolved_total}')::int <> 0 then
        raise exception 'M-002: empty review trail not projected: %', v_result2 -> 'field_reviews';
    end if;

    -- ---------------------------------------------------------------- M-003 --
    -- No mpk.bank.manage: an explicit denial, and no bank data anywhere in the payload.
    v_result2 := public.rpc_get_org_profile(v_nobank_org_id);
    if v_result2 #>> '{bank,access}' is distinct from 'denied' then
        raise exception 'M-003/FR-004: bank access must be explicitly denied: %', v_result2 -> 'bank';
    end if;
    if jsonb_typeof(v_result2 #> '{bank,current}') is distinct from 'null'
       or jsonb_array_length(v_result2 #> '{bank,history}') <> 0 then
        raise exception 'M-003: denied bank block still carried data: %', v_result2 -> 'bank';
    end if;
    if v_result2::text ilike '%QA Secret Bank%'
       or v_result2::text like '%' || 'KZ' || lpad('7', 18, '0') || '%'
       or v_result2::text ilike '%QASECRET%' then
        raise exception 'M-003: bank details leaked into the network payload of a caller without the right';
    end if;
    if v_result2 #>> '{permissions,mpk.bank.manage}' is distinct from 'false'
       or v_result2 #>> '{permissions,mpk.profile.edit}' is distinct from 'false' then
        raise exception 'M-003: procurement must not be told it may edit: %', v_result2 -> 'permissions';
    end if;
    -- The section itself stays readable — the right guards only the bank sub-block.
    if v_result2 #>> '{organization,legal_name}' is distinct from 'QA ARS-362 NOBANK' then
        raise exception 'M-003: the section must stay readable without mpk.bank.manage: %', v_result2;
    end if;

    -- ---------------------------------------------------------------- M-006 --
    -- A pending bin_iin proposal never replaces the production value; it arrives separately
    -- with previous/proposed value, actor and time.
    if v_result #>> '{organization,bin_iin}' is distinct from v_prod_bin then
        raise exception 'M-006: bin_iin must stay the production value while a proposal is pending: %',
            v_result #>> '{organization,bin_iin}';
    end if;
    if v_result #>> '{field_reviews,pending,0,field_name}' is distinct from 'bin_iin'
       or v_result #>> '{field_reviews,pending,0,previous_value}' is distinct from v_prod_bin
       or v_result #>> '{field_reviews,pending,0,proposed_value}' is distinct from '990362999999'
       or v_result #>> '{field_reviews,pending,0,requested_by_user_id}' is distinct from v_user_id::text
       or v_result #>> '{field_reviews,pending,0,requested_at}' is null then
        raise exception 'M-006: the pending proposal did not carry value/actor/time: %',
            v_result #> '{field_reviews,pending}';
    end if;
    -- FR-006: resolved history arrives under its own key, never mixed into pending.
    if jsonb_array_length(v_result #> '{field_reviews,resolved_recent}') <> 1
       or (v_result #>> '{field_reviews,resolved_total}')::int <> 1
       or v_result #>> '{field_reviews,resolved_recent,0,field_name}' is distinct from 'legal_name' then
        raise exception 'M-006/FR-006: resolved trail not separated from pending: %',
            v_result -> 'field_reviews';
    end if;

    -- ---------------------------------------------------------------- M-007 --
    -- Several bank versions: the live one is marked under its own key, older ones arrive as
    -- history in descending version order (FR-006).
    if v_result #>> '{bank,current,version_no}' is distinct from '2'
       or v_result #>> '{bank,current,is_primary}' is distinct from 'true'
       or (v_result #>> '{bank,current,valid_to}') is not null then
        raise exception 'M-007: the current bank version was not resolved: %', v_result #> '{bank,current}';
    end if;
    if jsonb_array_length(v_result #> '{bank,history}') <> 1
       or v_result #>> '{bank,history,0,account_id}' is distinct from v_bank_v1_id::text
       or v_result #>> '{bank,history,0,version_no}' is distinct from '1'
       or (v_result #>> '{bank,history,0,valid_to}') is null then
        raise exception 'M-007: superseded versions did not arrive as history: %', v_result #> '{bank,history}';
    end if;

    -- ---------------------------------------------------------------- M-009 --
    -- A non-MPK organization gets the same payload with empty MPK sections, not a refusal.
    v_result2 := public.rpc_get_org_profile(v_nonmpk_org_id);
    if v_result2 #>> '{organization,legal_name}' is distinct from 'QA ARS-362 NONMPK' then
        raise exception 'M-009: a non-MPK organization must still be readable: %', v_result2;
    end if;
    if v_result2 #> '{organization,org_types}' @> '["mpk"]'::jsonb then
        raise exception 'M-009 fixture broken: the organization must not carry the mpk type';
    end if;
    if jsonb_typeof(v_result2 -> 'profile') is distinct from 'null'
       or jsonb_typeof(v_result2 -> 'primary_site') is distinct from 'null' then
        raise exception 'M-009: MPK sections must be empty, not refused: %', v_result2;
    end if;

    -- ------------------------------------------------------- M-004 / M-010 --
    -- A foreign organization and a null id give the SAME denial, so the answer never
    -- confirms that someone else's organization exists (FR-003).
    v_blocked := false;
    begin
        perform public.rpc_get_org_profile(v_foreign_org_id);
    exception
        when insufficient_privilege then
            v_blocked := true;
            v_denied_foreign := sqlerrm;
    end;
    if not v_blocked then
        raise exception 'M-004: a non-member read a foreign organization profile';
    end if;

    v_blocked := false;
    begin
        perform public.rpc_get_org_profile(null);
    exception
        when insufficient_privilege then
            v_blocked := true;
            v_denied_null := sqlerrm;
    end;
    if not v_blocked then
        raise exception 'M-010: a null organization id was not refused';
    end if;
    if v_denied_foreign not like 'FORBIDDEN%' then
        raise exception 'M-004: the denial is not the typed access error: %', v_denied_foreign;
    end if;
    if split_part(v_denied_foreign, ':', 1) is distinct from split_part(v_denied_null, ':', 1) then
        raise exception 'M-010/FR-003: null and foreign denials differ (% vs %)',
            v_denied_null, v_denied_foreign;
    end if;
    -- A non-existent organization must be indistinguishable from a foreign one.
    v_blocked := false;
    begin
        perform public.rpc_get_org_profile(gen_random_uuid());
    exception
        when insufficient_privilege then
            v_blocked := true;
            v_err := sqlerrm;
    end;
    if not v_blocked or split_part(v_err, ':', 1) is distinct from split_part(v_denied_foreign, ':', 1) then
        raise exception 'M-004/FR-003: a non-existent organization is distinguishable from a foreign one: %', v_err;
    end if;

    -- ---------------------------------------------------------------- M-005 --
    -- No session: a typed authentication error, distinct from the access denial above.
    v_blocked := false;
    perform set_config('request.jwt.claims', '{}'::text, true);
    begin
        perform public.rpc_get_org_profile(v_org_id);
    exception
        when insufficient_privilege then
            v_blocked := true;
            v_err := sqlerrm;
    end;
    if not v_blocked then
        raise exception 'M-005: an unauthenticated request was not refused';
    end if;
    if v_err not like 'AUTH_REQUIRED%' then
        raise exception 'M-005: the unauthenticated refusal is not AUTH_REQUIRED: %', v_err;
    end if;

    -- ---------------------------------------------------------------- M-008 --
    -- A TURAN admin reaches the requested organization, bank included, without membership.
    -- Право админа ВЫДАЁТСЯ СВОЕМУ пользователю (новая строка), а не отбирается у чужого.
    insert into public.admin_roles (user_id, role, is_active)
    values (v_user_id, 'super_admin', true);
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    v_result2 := public.rpc_get_org_profile(v_foreign_org_id);
    if v_result2 #>> '{organization,id}' is distinct from v_foreign_org_id::text then
        raise exception 'M-008: an admin could not read the requested organization';
    end if;
    if v_result2 #>> '{bank,access}' is distinct from 'granted' then
        raise exception 'M-008: an admin was denied the bank sub-block: %', v_result2 -> 'bank';
    end if;
    -- The admin holds no organization role here, so the write flags must stay false: the
    -- ARS-359 writers check the permission, not the admin flag.
    if v_result2 #>> '{permissions,mpk.bank.manage}' is distinct from 'false' then
        raise exception 'M-008: admin read access was mistaken for a write right: %',
            v_result2 -> 'permissions';
    end if;

    -- ---------------------------------------------------------------- M-011 --
    -- STRUCTURAL ONLY (see the file header): the internal-failure path is asserted by
    -- construction, not by behaviour. Behavioural coverage needs fault injection and an
    -- isolated environment (IMPL_DEBT QA-ENV-ISOLATION-01).
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'rpc_get_org_profile';
    if v_def not like '%PROFILE_READ_FAILED%' then
        raise exception 'M-011/FR-008: the reader has no typed internal-failure code';
    end if;
    if v_def !~* 'raise\s+exception[^;]*sqlerrm' is not true then
        -- Guard reads: sqlerrm must never appear inside a client-facing RAISE EXCEPTION.
        raise exception 'M-011/FR-008: sqlerrm is raised to the client instead of being logged';
    end if;

    -- ---------------------------------------------------------------- M-012 --
    -- Heavy organization: 20 bank versions + 3 pending proposals + a filled site.
    -- The number printed here is a single-session timing on the acceptance environment's
    -- seed data; the p95 claim and its measurement conditions belong to the G3 packet
    -- (FR-014), not to this assertion.
    update public.org_bank_accounts set valid_to = now(), is_primary = false
     where organization_id = v_org_id and valid_to is null;
    for i in 3..20 loop
        insert into public.org_bank_accounts (
            organization_id, logical_account_id, version_no, bank_name, bik, iban,
            account_holder_name, currency_code, is_primary, valid_from, valid_to
        ) values (
            v_org_id, v_logical_id, i, 'QA Bank', 'QATEST01',
            'KZ' || lpad(i::text, 18, '0'), 'QA ARS-362 MPK', 'KZT',
            i = 20, now() - make_interval(hours => 20 - i),
            case when i = 20 then null else now() end
        );
    end loop;
    insert into public.org_field_reviews (
        organization_id, field_name, previous_value, proposed_value, status,
        requested_by_user_id, requested_at, production_value_applied_at
    ) values
        (v_org_id, 'legal_name', 'QA ARS-362 MPK', 'QA ARS-362 MPK v2', 'pending', v_user_id, now(), now()),
        (v_org_id, 'address_text', 'Production address', 'Production address v2', 'pending', v_user_id, now(), now());

    v_started := clock_timestamp();
    for i in 1..5 loop
        perform public.rpc_get_org_profile(v_org_id);
    end loop;
    v_elapsed_ms := extract(epoch from (clock_timestamp() - v_started)) * 1000 / 5;

    v_result2 := public.rpc_get_org_profile(v_org_id);
    if jsonb_array_length(v_result2 #> '{bank,history}') <> 19
       or v_result2 #>> '{bank,current,version_no}' is distinct from '20' then
        raise exception 'M-012: the heavy bank ladder was not projected whole: current=%, history=%',
            v_result2 #> '{bank,current,version_no}',
            jsonb_array_length(v_result2 #> '{bank,history}');
    end if;
    if jsonb_array_length(v_result2 #> '{field_reviews,pending}') <> 3 then
        raise exception 'M-012: the three pending proposals were not projected: %',
            v_result2 #> '{field_reviews,pending}';
    end if;
    raise notice 'M-012 timing: mean % ms over 5 calls (single session, acceptance-environment seed; p95 conditions belong to the G3 packet)',
        round(v_elapsed_ms, 1);

    -- FR-013: the reader mutates nothing. Any write inside it would be visible as a changed
    -- updated_at on the rows it touched.
    if exists (
        select 1 from public.mpk_profiles
        where organization_id = v_org_id and updated_at <> created_at
    ) then
        raise exception 'FR-013: the reader mutated mpk_profiles';
    end if;

    raise notice 'ARS-362: M-001…M-010 and M-012 passed behaviourally; M-011 structurally only.';
end;
$$;

rollback;
