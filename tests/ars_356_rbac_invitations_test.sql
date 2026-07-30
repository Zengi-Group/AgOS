-- ARS-356 regression contract.
-- Run after the ARS-356 section of d01_kernel.sql is deployed.

begin;

do $$
declare
    v_inviter_id       uuid;
    v_inviter_auth     uuid;
    v_invitee_id       uuid;
    v_invitee_auth     uuid;
    v_org_id           uuid := gen_random_uuid();
    v_other_org_id     uuid := gen_random_uuid();
    v_suffix           text := replace(gen_random_uuid()::text, '-', '');
    v_inviter_email    text;
    v_invitee_email    text;
    v_created          jsonb;
    v_resent           jsonb;
    v_accepted         jsonb;
    v_invitation_id    uuid;
    v_token            text;
    v_old_token        text;
    v_error            text;
    v_actual           boolean;
    v_expected         boolean;
    v_case             record;
    v_permission       record;
begin
    select u.id, u.auth_id
      into v_inviter_id, v_inviter_auth
    from public.users u
    where u.auth_id is not null
    order by u.created_at
    limit 1;

    select u.id, u.auth_id
      into v_invitee_id, v_invitee_auth
    from public.users u
    where u.auth_id is not null
      and u.id <> v_inviter_id
    order by u.created_at
    limit 1;

    if v_inviter_id is null or v_invitee_id is null then
        raise exception 'ARS-356_TEST_SETUP: requires two auth-backed public users';
    end if;

    v_inviter_email := 'qa-ars356-admin-' || v_suffix || '@example.test';
    v_invitee_email := 'qa-ars356-user-' || v_suffix || '@example.test';

    update public.users
       set email = v_inviter_email, is_active = true
     where id = v_inviter_id;
    update public.users
       set email = v_invitee_email, is_active = true
     where id = v_invitee_id;
    update auth.users
       set email = v_inviter_email, email_confirmed_at = coalesce(email_confirmed_at, now())
     where id = v_inviter_auth;
    update auth.users
       set email = v_invitee_email, email_confirmed_at = coalesce(email_confirmed_at, now())
     where id = v_invitee_auth;

    insert into public.organizations (id, legal_name)
    values
        (v_org_id, 'QA ARS-356 MPK'),
        (v_other_org_id, 'QA ARS-356 OTHER MPK');
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_id, 'mpk'), (v_other_org_id, 'mpk');
    insert into public.user_organization_roles (
        user_id, organization_id, role, is_primary
    ) values (v_inviter_id, v_org_id, 'mpk_admin', false);

    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_inviter_auth::text, 'role', 'authenticated')::text,
        true
    );

    -- Exact role×permission matrix, including the four legacy compatibility roles.
    for v_case in
        select * from (values
            ('owner',       array['mpk.profile.edit','mpk.documents.manage','mpk.team.manage','mpk.purchase','mpk.receive','mpk.review.submit','mpk.deal_documents.read','mpk.deal_documents.manage','mpk.bank.manage']::text[]),
            ('manager',     array['mpk.profile.edit','mpk.documents.manage','mpk.team.manage','mpk.purchase','mpk.receive','mpk.review.submit','mpk.deal_documents.read','mpk.deal_documents.manage','mpk.bank.manage']::text[]),
            ('employee',    array['mpk.purchase','mpk.receive','mpk.review.submit','mpk.deal_documents.read']::text[]),
            ('viewer',      array['mpk.deal_documents.read']::text[]),
            ('mpk_admin',   array['mpk.profile.edit','mpk.documents.manage','mpk.team.manage','mpk.purchase','mpk.receive','mpk.review.submit','mpk.deal_documents.read','mpk.deal_documents.manage','mpk.bank.manage']::text[]),
            ('procurement', array['mpk.purchase','mpk.review.submit','mpk.deal_documents.read','mpk.deal_documents.manage']::text[]),
            ('receiver',    array['mpk.receive','mpk.deal_documents.read','mpk.deal_documents.manage']::text[]),
            ('accountant',  array['mpk.bank.manage','mpk.deal_documents.read','mpk.deal_documents.manage']::text[])
        ) as matrix(role, allowed)
    loop
        update public.user_organization_roles
           set role = v_case.role
         where user_id = v_inviter_id and organization_id = v_org_id;

        for v_permission in
            select code from public.organization_permissions order by code
        loop
            v_expected := v_permission.code = any(v_case.allowed);
            v_actual := public.fn_org_has_permission(v_org_id, v_permission.code);
            if v_actual is distinct from v_expected then
                raise exception 'ARS-356: role % permission % expected %, got %',
                    v_case.role, v_permission.code, v_expected, v_actual;
            end if;
        end loop;
    end loop;

    -- Accountant/procurement cannot perform team-admin operations.
    foreach v_error in array array['procurement', 'accountant'] loop
        update public.user_organization_roles
           set role = v_error
         where user_id = v_inviter_id and organization_id = v_org_id;
        begin
            perform public.rpc_create_org_invitation(
                v_org_id, 'qa-denied-' || v_error || '-' || v_suffix || '@example.test', 'viewer'
            );
            raise exception 'ARS-356: % unexpectedly created an invitation', v_error;
        exception
            when insufficient_privilege then null;
        end;
    end loop;

    update public.user_organization_roles
       set role = 'mpk_admin'
     where user_id = v_inviter_id and organization_id = v_org_id;

    -- Cross-tenant helper and invitation writes both fail.
    if public.fn_org_has_permission(v_other_org_id, 'mpk.team.manage') then
        raise exception 'ARS-356: cross-tenant permission leaked';
    end if;
    begin
        perform public.rpc_create_org_invitation(
            v_other_org_id, 'qa-cross-' || v_suffix || '@example.test', 'viewer'
        );
        raise exception 'ARS-356: cross-tenant invitation unexpectedly succeeded';
    exception
        when insufficient_privilege then null;
    end;

    -- Create, one-open uniqueness, hash secrecy, and immediate resend rate limit.
    v_created := public.rpc_create_org_invitation(
        v_org_id, upper(v_invitee_email), 'procurement'
    );
    v_invitation_id := (v_created->>'id')::uuid;
    v_token := v_created->>'token';
    if v_created ? 'token_hash' or length(v_token) <> 64 then
        raise exception 'ARS-356: invitation response leaked hash or omitted raw token';
    end if;
    if not exists (
        select 1 from public.org_invitations
        where id = v_invitation_id
          and token_hash = extensions.digest(v_token, 'sha256')
    ) then
        raise exception 'ARS-356: stored token digest mismatch';
    end if;

    begin
        perform public.rpc_create_org_invitation(v_org_id, v_invitee_email, 'viewer');
        raise exception 'ARS-356: duplicate open invite unexpectedly succeeded';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'INVITATION_ALREADY_OPEN' then raise; end if;
    end;

    begin
        perform public.rpc_resend_org_invitation(v_org_id, v_invitation_id);
        raise exception 'ARS-356: immediate resend unexpectedly succeeded';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if position('INVITATION_RESEND_RATE_LIMIT' in v_error) <> 1 then raise; end if;
    end;

    update public.org_invitations
       set last_sent_at = now() - interval '61 seconds'
     where id = v_invitation_id;
    v_old_token := v_token;
    v_resent := public.rpc_resend_org_invitation(v_org_id, v_invitation_id);
    v_token := v_resent->>'token';
    if v_token = v_old_token or (v_resent->>'resend_count')::int <> 1 then
        raise exception 'ARS-356: resend did not rotate token/count';
    end if;

    -- Acceptance binds verified auth email and materializes one UOR row atomically.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_invitee_auth::text, 'role', 'authenticated')::text,
        true
    );
    v_accepted := public.rpc_accept_org_invitation(v_token);
    if v_accepted->>'status' <> 'accepted'
       or (v_accepted->>'idempotent')::boolean then
        raise exception 'ARS-356: first acceptance result invalid: %', v_accepted;
    end if;
    v_accepted := public.rpc_accept_org_invitation(v_token);
    if not (v_accepted->>'idempotent')::boolean then
        raise exception 'ARS-356: same-user double accept was not idempotent';
    end if;
    if (
        select count(*) from public.user_organization_roles
        where user_id = v_invitee_id
          and organization_id = v_org_id
          and role = 'procurement'
    ) <> 1 then
        raise exception 'ARS-356: acceptance did not create exactly one canonical UOR row';
    end if;

    -- A different user cannot consume an already accepted token.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_inviter_auth::text, 'role', 'authenticated')::text,
        true
    );
    begin
        perform public.rpc_accept_org_invitation(v_token);
        raise exception 'ARS-356: second user consumed accepted token';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'INVITATION_ALREADY_ACCEPTED' then raise; end if;
    end;

    -- Revocation is terminal/idempotent; expiry is persisted lazily.
    v_created := public.rpc_create_org_invitation(
        v_org_id, 'qa-revoke-' || v_suffix || '@example.test', 'receiver'
    );
    v_invitation_id := (v_created->>'id')::uuid;
    if public.rpc_revoke_org_invitation(v_org_id, v_invitation_id)->>'status' <> 'revoked'
       or not (public.rpc_revoke_org_invitation(v_org_id, v_invitation_id)->>'idempotent')::boolean then
        raise exception 'ARS-356: revoke FSM/idempotency failed';
    end if;

    v_created := public.rpc_create_org_invitation(
        v_org_id, 'qa-expire-' || v_suffix || '@example.test', 'viewer'
    );
    v_invitation_id := (v_created->>'id')::uuid;
    update public.org_invitations
       set last_sent_at = now() - interval '2 hours',
           expires_at = now() - interval '1 hour'
     where id = v_invitation_id;
    perform count(*) from public.rpc_list_org_invitations(v_org_id);
    if not exists (
        select 1 from public.org_invitations
        where id = v_invitation_id and status = 'expired' and expired_at is not null
    ) then
        raise exception 'ARS-356: lazy expiry did not persist FSM transition';
    end if;

    -- Structural concurrency/ACL contract: row lock + partial unique key + no table bypass.
    if not exists (
        select 1
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = 'rpc_accept_org_invitation'
          and position('for update' in lower(pg_get_functiondef(p.oid))) > 0
    ) then
        raise exception 'ARS-356: acceptance row lock missing';
    end if;
    if not exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_invitations'
          and indexname = 'uq_org_invitations_open_email'
          and position('status = ''sent''' in indexdef) > 0
    ) then
        raise exception 'ARS-356: partial unique open-invite index missing';
    end if;
    if has_table_privilege('authenticated', 'public.org_invitations', 'select')
       or has_table_privilege('authenticated', 'public.org_invitations', 'insert')
       or has_table_privilege('anon', 'public.org_invitations', 'select') then
        raise exception 'ARS-356: invitation table bypass privilege exists';
    end if;
    if has_function_privilege(
        'anon', 'public.rpc_accept_org_invitation(text)', 'execute'
    ) then
        raise exception 'ARS-356: anon can accept invitations';
    end if;
end;
$$;

rollback;
