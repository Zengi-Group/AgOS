-- ARS-359 regression contract.
-- Run after supabase/migrations/20260730134113_ars_359_mpk_profile_data_model.sql.

begin;

do $$
declare
    v_admin_user_id      uuid;
    v_admin_auth_id      uuid;
    v_org_id             uuid := gen_random_uuid();
    v_other_org_id       uuid := gen_random_uuid();
    v_review_id          uuid;
    v_address_review_id  uuid;
    v_site_id            uuid;
    v_second_site_id     uuid;
    v_bank_v1_id         uuid;
    v_bank_v2_id         uuid;
    v_other_bank_id      uuid;
    v_snapshot_before    jsonb;
    v_snapshot_after     jsonb;
    v_result             jsonb;
    v_error              text;
    v_fk                  record;
begin
    select u.id, u.auth_id
      into v_admin_user_id, v_admin_auth_id
    from public.users u
    join public.admin_roles ar on ar.user_id = u.id and ar.is_active
    where u.auth_id is not null and u.is_active
    order by u.created_at
    limit 1;

    if v_admin_user_id is null then
        raise exception 'ARS-359_TEST_SETUP: requires one active auth-backed admin';
    end if;

    -- Canonical shape and legacy-wide profile columns cannot coexist.
    if not exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'organizations'
          and column_name = 'head_full_name'
    ) or not exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'organizations'
          and column_name = 'head_title'
    ) then
        raise exception 'ARS-359: organization head columns missing';
    end if;

    if exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'mpk_profiles'
          and column_name = any(array[
              'annual_demand_heads', 'processing_capacity_per_day',
              'preferred_categories', 'preferred_regions', 'notes'
          ])
    ) then
        raise exception 'ARS-359: legacy wide mpk_profiles column survived';
    end if;

    insert into public.organizations (
        id, legal_name, bin_iin, address_text, phone, email
    ) values
        (v_org_id, 'QA ARS-359 MPK', '990000000001', 'Old legal address', '+77010000001', 'old@example.test'),
        (v_other_org_id, 'QA ARS-359 OTHER', '990000000002', 'Other address', '+77010000002', 'other@example.test');
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_id, 'mpk'), (v_other_org_id, 'mpk');
    insert into public.user_organization_roles (
        user_id, organization_id, role, is_primary
    ) values (v_admin_user_id, v_org_id, 'mpk_admin', false);

    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_admin_auth_id::text, 'role', 'authenticated')::text,
        true
    );

    -- Sparse profile: only the edited MPK gets an extension row.
    perform public.rpc_upsert_mpk_profile(
        v_org_id, '  Public MPK description  ', 'mpk/' || v_org_id || '/logo.png'
    );
    if not exists (
        select 1 from public.mpk_profiles
        where organization_id = v_org_id
          and public_description = 'Public MPK description'
    ) or exists (
        select 1 from public.mpk_profiles where organization_id = v_other_org_id
    ) then
        raise exception 'ARS-359: sparse/narrow profile upsert failed';
    end if;

    perform public.rpc_update_mpk_org_details(
        v_org_id, null, '  QA Director  ', '  General Director  ',
        ' +77010000009 ', ' MPK@EXAMPLE.TEST ', ' https://example.test '
    );
    if not exists (
        select 1 from public.organizations
        where id = v_org_id
          and head_full_name = 'QA Director'
          and head_title = 'General Director'
          and phone = '+77010000009'
          and email = 'mpk@example.test'
          and website = 'https://example.test'
    ) then
        raise exception 'ARS-359: organization head/contact update failed';
    end if;

    -- Primary-site UI path is idempotent and preserves one active primary.
    v_site_id := public.rpc_save_mpk_primary_site(
        v_org_id, '  Main intake  ', '  Site address  ', 120,
        null, '+77010000009', 'SITE@EXAMPLE.TEST', null
    );
    if public.rpc_save_mpk_primary_site(
        v_org_id, 'Main intake updated', 'Site address updated', 150,
        null, null, null, null
    ) <> v_site_id then
        raise exception 'ARS-359: primary-site upsert created an unnecessary row';
    end if;

    insert into public.mpk_sites (
        organization_id, site_name, address_text,
        processing_capacity_heads_per_day, is_primary, is_active
    ) values (
        v_org_id, 'Secondary site', 'Secondary address', 75, false, true
    ) returning id into v_second_site_id;

    perform public.rpc_save_mpk_primary_site(
        v_org_id, 'Secondary promoted', 'Secondary address', 80,
        null, null, null, v_second_site_id
    );
    if (
        select count(*) from public.mpk_sites
        where organization_id = v_org_id and is_primary and is_active
    ) <> 1 or not exists (
        select 1 from public.mpk_sites
        where id = v_second_site_id and is_primary and is_active
    ) then
        raise exception 'ARS-359: active primary-site invariant failed';
    end if;

    begin
        perform public.rpc_save_mpk_primary_site(
            v_org_id, 'Invalid', 'Invalid', 0, null, null, null, null
        );
        raise exception 'ARS-359: zero capacity unexpectedly accepted';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'CAPACITY_MUST_BE_POSITIVE' then raise; end if;
    end;

    -- Bank changes append a version, retain the prior row, and keep snapshots stable.
    v_bank_v1_id := public.rpc_append_org_bank_account(
        v_org_id, 'QA Bank', 'TESTKZKX', 'KZ123456789012345678',
        'QA ARS-359 MPK', 'KZT', null, null
    );
    select public.fn_org_bank_account_snapshot(v_bank_v1_id)
      into v_snapshot_before;

    v_bank_v2_id := public.rpc_append_org_bank_account(
        v_org_id, 'QA Bank v2', 'TESTKZKX', 'KZ223456789012345678',
        'QA ARS-359 MPK', 'KZT', null, v_bank_v1_id
    );
    select public.fn_org_bank_account_snapshot(v_bank_v1_id)
      into v_snapshot_after;

    if v_snapshot_after is distinct from v_snapshot_before
       or not exists (
            select 1 from public.org_bank_accounts
            where id = v_bank_v1_id and valid_to is not null and not is_primary
       )
       or not exists (
            select 1 from public.org_bank_accounts
            where id = v_bank_v2_id and version_no = 2
              and supersedes_id = v_bank_v1_id and valid_to is null and is_primary
       ) then
        raise exception 'ARS-359: append-new bank version/snapshot invariant failed';
    end if;

    v_other_bank_id := public.rpc_append_org_bank_account(
        v_org_id, 'Other QA Bank', 'OTHRKZKX', 'KZ323456789012345678',
        'QA ARS-359 MPK', 'KZT', true, null
    );
    if (
        select count(*) from public.org_bank_accounts
        where organization_id = v_org_id and valid_to is null and is_primary
    ) <> 1 or not exists (
        select 1 from public.org_bank_accounts
        where id = v_other_bank_id and is_primary and valid_to is null
    ) then
        raise exception 'ARS-359: current primary-bank invariant failed';
    end if;

    begin
        update public.org_bank_accounts
           set bank_name = 'Illegal overwrite'
         where id = v_bank_v2_id;
        raise exception 'ARS-359: bank business fields were updated in place';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'BANK_ACCOUNT_APPEND_NEW_REQUIRED' then raise; end if;
    end;

    -- Name/address apply immediately; BIN remains untouched until TURAN approves.
    v_review_id := public.rpc_propose_org_field_change(
        v_org_id, 'legal_name', 'QA ARS-359 MPK renamed'
    );
    if not exists (
        select 1 from public.organizations
        where id = v_org_id and legal_name = 'QA ARS-359 MPK renamed'
    ) or not exists (
        select 1 from public.org_field_reviews
        where id = v_review_id and status = 'pending'
          and production_value_applied_at is not null
    ) then
        raise exception 'ARS-359: immediate legal-name apply/review failed';
    end if;

    v_review_id := public.rpc_propose_org_field_change(
        v_org_id, 'bin_iin', '990000000009'
    );
    if not exists (
        select 1 from public.organizations
        where id = v_org_id and bin_iin = '990000000001'
    ) or not exists (
        select 1 from public.org_field_reviews
        where id = v_review_id and status = 'pending'
          and production_value_applied_at is null
    ) then
        raise exception 'ARS-359: pending BIN proposal changed production value';
    end if;

    -- Existing organizations RLS used to allow own-row direct updates. The guard (or
    -- a stricter deployment grant) must make that path incapable of bypassing review.
    v_error := null;
    begin
        execute 'set local role authenticated';
        begin
            update public.organizations
               set bin_iin = '990000000007'
             where id = v_org_id;
        exception
            when insufficient_privilege then
                get stacked diagnostics v_error = message_text;
        end;
        execute 'reset role';
    exception
        when others then
            execute 'reset role';
            raise;
    end;
    if v_error is null or not exists (
        select 1 from public.organizations
        where id = v_org_id and bin_iin = '990000000001'
    ) then
        raise exception 'ARS-359: direct authenticated BIN update bypassed review';
    end if;

    begin
        perform public.rpc_propose_org_field_change(
            v_org_id, 'bin_iin', '990000000008'
        );
        raise exception 'ARS-359: second pending BIN proposal unexpectedly accepted';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'FIELD_REVIEW_ALREADY_PENDING' then raise; end if;
    end;

    v_result := public.rpc_review_org_field_change(v_review_id, 'approved', 'Verified');
    if v_result->>'status' <> 'approved'
       or not exists (
            select 1 from public.organizations
            where id = v_org_id and bin_iin = '990000000009'
       ) then
        raise exception 'ARS-359: approved BIN was not applied atomically';
    end if;
    v_result := public.rpc_review_org_field_change(v_review_id, 'approved', 'Verified');
    if not (v_result->>'idempotent')::boolean then
        raise exception 'ARS-359: same-decision field review retry is not idempotent';
    end if;

    v_address_review_id := public.rpc_propose_org_field_change(
        v_org_id, 'address_text', 'New legal address'
    );
    perform public.rpc_review_org_field_change(
        v_address_review_id, 'rejected', 'Please correct the address'
    );
    if not exists (
        select 1 from public.organizations
        where id = v_org_id and address_text = 'New legal address'
    ) or not exists (
        select 1 from public.org_field_reviews
        where id = v_address_review_id and status = 'rejected'
          and production_value_applied_at is not null
    ) then
        raise exception 'ARS-359: rejected address silently reverted production';
    end if;

    -- Caller organization/permission is authoritative, not the supplied org id.
    begin
        perform public.rpc_propose_org_field_change(
            v_other_org_id, 'legal_name', 'Cross tenant overwrite'
        );
        raise exception 'ARS-359: cross-tenant field proposal unexpectedly succeeded';
    exception
        when insufficient_privilege then null;
    end;

    update public.user_organization_roles
       set role = 'accountant'
     where user_id = v_admin_user_id and organization_id = v_org_id;
    begin
        perform public.rpc_upsert_mpk_profile(v_org_id, 'Denied', null);
        raise exception 'ARS-359: accountant unexpectedly edited MPK profile';
    exception
        when insufficient_privilege then null;
    end;

    -- All target FKs and RLS predicates have supporting indexes.
    for v_fk in
        select c.conrelid, c.conname, a.attname, a.attnum
        from pg_constraint c
        cross join lateral unnest(c.conkey) as k(attnum)
        join pg_attribute a
          on a.attrelid = c.conrelid and a.attnum = k.attnum
        where c.contype = 'f'
          and c.conrelid = any(array[
              'public.mpk_profiles'::regclass,
              'public.mpk_sites'::regclass,
              'public.org_bank_accounts'::regclass,
              'public.org_field_reviews'::regclass
          ])
    loop
        if not exists (
            select 1 from pg_index i
            where i.indrelid = v_fk.conrelid
              and i.indisvalid
              and v_fk.attnum = any(i.indkey::smallint[])
        ) then
            raise exception 'ARS-359: FK %.% lacks an index', v_fk.conname, v_fk.attname;
        end if;
    end loop;

    if not exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_field_reviews'
          and indexname = 'uq_org_field_reviews_pending'
          and indexdef ilike '%where (status = ''pending''%'
    ) then
        raise exception 'ARS-359: partial pending-field-review index missing';
    end if;

    if exists (
        select 1
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = any(array[
              'mpk_profiles', 'mpk_sites', 'org_bank_accounts', 'org_field_reviews'
          ])
          and not c.relrowsecurity
    ) then
        raise exception 'ARS-359: target table exists with RLS disabled';
    end if;

    -- Explicit opt-in Data API behavior: tables remain RPC-only.
    if has_table_privilege('anon', 'public.mpk_profiles', 'select')
       or has_table_privilege('authenticated', 'public.mpk_profiles', 'select')
       or has_table_privilege('authenticated', 'public.mpk_sites', 'insert')
       or has_table_privilege('authenticated', 'public.org_bank_accounts', 'select')
       or has_table_privilege('authenticated', 'public.org_field_reviews', 'update') then
        raise exception 'ARS-359: direct Data API table privilege bypass exists';
    end if;

    if has_function_privilege(
        'anon', 'public.rpc_propose_org_field_change(uuid,text,text)', 'execute'
    ) or has_function_privilege(
        'anon',
        'public.rpc_append_org_bank_account(uuid,text,text,text,text,text,boolean,uuid)',
        'execute'
    ) or has_function_privilege(
        'authenticated', 'public.fn_org_bank_account_snapshot(uuid)', 'execute'
    ) then
        raise exception 'ARS-359: sensitive function ACL is too broad';
    end if;
end;
$$;

rollback;
