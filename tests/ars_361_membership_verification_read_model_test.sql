-- ARS-361 regression contract.
-- Run after supabase/migrations/20260731074740_ars_361_membership_verification_read_model.sql.
--
-- Required read-model shape:
--   {version,organization_id,association_number,membership,verification}
--   membership.{is_active,source,state,trial_end,current_period_start,
--               current_period_end,next_billing_at,cancel_at_period_end,
--               subscription_id,plan_code,plan_title,renewal_mode,cta}
--   verification.{status,timeline,latest_by_type,type_assignment,membership_id}
--   verification.type_assignment.{assigned_at,assigned_by_user_id,is_self_assigned}
-- `association_number` is always JSON null: no canonical source exists.

begin;

do $$
declare
    v_admin_user_id       uuid;
    v_admin_auth_id       uuid;
    v_admin_role_id       uuid;
    v_active_org_id       uuid := gen_random_uuid();
    v_legacy_org_id       uuid := gen_random_uuid();
    v_terminal_org_id     uuid := gen_random_uuid();
    v_tenant_b_org_id     uuid := gen_random_uuid();
    v_unclassified_org_id uuid := gen_random_uuid();
    v_active_membership_id uuid;
    v_legacy_membership_id uuid;
    v_unclassified_membership_id uuid;
    v_subscription_id      uuid;
    v_plan_code           text := 'qa_ars361_' || replace(gen_random_uuid()::text, '-', '');
    v_period_start        timestamptz := date_trunc('second', clock_timestamp()) - interval '7 days';
    v_period_end          timestamptz;
    v_next_billing_at     timestamptz;
    v_evidence_anchor     timestamptz := date_trunc('second', clock_timestamp()) - interval '5 days';
    v_old_approved_id     uuid;
    v_rejected_id         uuid;
    v_expired_id          uuid;
    v_fresh_approved_id   uuid;
    v_result              jsonb;
    v_legacy_result       jsonb;
    v_terminal_result     jsonb;
    v_state_result        jsonb;
    v_unclassified_result jsonb;
    v_timeline            jsonb;
    v_latest              jsonb;
    v_blocked             boolean := false;
    v_state_org_id        uuid;
    v_state               text;
    v_expected_active     boolean;
    v_expected_cta        text;
begin
    select u.id, u.auth_id, ar.id
      into v_admin_user_id, v_admin_auth_id, v_admin_role_id
      from public.users u
      join public.admin_roles ar on ar.user_id = u.id and ar.is_active
     where u.auth_id is not null and u.is_active
     order by u.created_at
     limit 1;

    if v_admin_user_id is null then
        raise exception 'ARS-361_TEST_SETUP: requires one active auth-backed admin';
    end if;

    -- The public reader is an authenticated, guarded RPC; direct/anon execution
    -- would disclose another organization's membership and verification evidence.
    if has_function_privilege(
        'anon', 'public.rpc_get_org_membership_verification(uuid)', 'execute'
    ) then
        raise exception 'ARS-361: anon can execute the membership/verification reader';
    end if;
    if not has_function_privilege(
        'authenticated', 'public.rpc_get_org_membership_verification(uuid)', 'execute'
    ) then
        raise exception 'ARS-361: authenticated callers cannot execute the reader';
    end if;

    insert into public.organizations (id, legal_name)
    values
        (v_active_org_id, 'QA ARS-361 active MPK'),
        (v_legacy_org_id, 'QA ARS-361 legacy MPK'),
        (v_terminal_org_id, 'QA ARS-361 terminal subscription'),
        (v_tenant_b_org_id, 'QA ARS-361 tenant B'),
        (v_unclassified_org_id, 'QA ARS-361 stale MPK membership');

    -- Re-use the active admin as a real tenant-B user while its admin role is
    -- temporarily disabled below. This avoids inventing auth.users fixtures.
    insert into public.user_organization_roles (
        user_id, organization_id, role, is_primary
    ) values (
        v_admin_user_id, v_tenant_b_org_id, 'owner', false
    );

    -- Both assignments are deliberately self-assigned. They classify the org but
    -- cannot, on their own, establish verification approval.
    insert into public.organization_type_assignments (organization_id, org_type, assigned_by)
    values
        (v_active_org_id, 'mpk', null),
        (v_legacy_org_id, 'mpk', null);

    insert into public.memberships (organization_id, org_type, level)
    values (v_active_org_id, 'mpk', 'registered')
    returning id into v_active_membership_id;

    insert into public.memberships (organization_id, org_type, level)
    values (v_legacy_org_id, 'mpk', 'observer')
    returning id into v_legacy_membership_id;

    insert into public.memberships (organization_id, org_type, level)
    values (v_unclassified_org_id, 'mpk', 'registered')
    returning id into v_unclassified_membership_id;

    insert into public.membership_plan (
        plan_code, title, billing_period, price_amount, currency, trial_days,
        grants_tier, is_active
    ) values (
        v_plan_code, 'QA ARS-361 plan', '1 month', 0, 'KZT', 0,
        'standard', true
    );

    v_period_end := v_period_start + interval '30 days';
    v_next_billing_at := v_period_end;
    insert into public.membership_subscription (
        organization_id, membership_id, plan_code, state, trial_end,
        current_period_start, current_period_end, next_billing_at,
        cancel_at_period_end
    ) values (
        v_active_org_id, v_active_membership_id, v_plan_code, 'active', null,
        v_period_start, v_period_end, v_next_billing_at, false
    ) returning id into v_subscription_id;

    -- An active legacy level overrides a past_due subscription exactly as
    -- fn_org_membership_active does; its subscription lifecycle must stay hidden.
    insert into public.membership_subscription (
        organization_id, membership_id, plan_code, state,
        current_period_start, current_period_end, next_billing_at,
        cancel_at_period_end
    ) values (
        v_legacy_org_id, v_legacy_membership_id, v_plan_code, 'past_due',
        v_period_start, v_period_end, v_next_billing_at, true
    );

    -- Tenant B must not read tenant A. Temporarily disable the selected admin role,
    -- leaving the caller with exactly its tenant-B organization membership.
    update public.admin_roles
       set is_active = false
     where id = v_admin_role_id;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_admin_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    begin
        perform public.rpc_get_org_membership_verification(v_active_org_id);
    exception
        when insufficient_privilege then
            v_blocked := true;
    end;
    if not v_blocked then
        raise exception 'ARS-361: tenant B was not blocked from tenant A read-model';
    end if;
    update public.admin_roles
       set is_active = true
     where id = v_admin_role_id;

    -- A request with no JWT role must fail closed too. auth.role() returns NULL
    -- for these claims, so this guards against SQL's three-valued boolean logic
    -- accidentally bypassing the authorization condition.
    v_blocked := false;
    perform set_config('request.jwt.claims', '{}'::text, true);
    begin
        perform public.rpc_get_org_membership_verification(v_active_org_id);
    exception
        when insufficient_privilege then
            v_blocked := true;
    end;
    if not v_blocked then
        raise exception 'ARS-361: request without JWT role was not blocked from reader';
    end if;

    if not has_function_privilege(
        'service_role', 'public.rpc_get_org_membership_verification(uuid)', 'execute'
    ) then
        raise exception 'ARS-361: service_role cannot execute the membership/verification reader';
    end if;
    perform set_config(
        'request.jwt.claims',
        json_build_object('role', 'service_role')::text,
        true
    );
    v_result := public.rpc_get_org_membership_verification(v_active_org_id);
    if v_result->>'organization_id' is distinct from v_active_org_id::text then
        raise exception 'ARS-361: trusted service role could not read the projection';
    end if;

    -- Use the real admin caller for the positive assertions and to demonstrate
    -- that security-definer reads do not lose the authorized tenant's evidence.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_admin_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    v_result := public.rpc_get_org_membership_verification(v_active_org_id);

    if v_result->>'version' is distinct from '1'
       or v_result->>'organization_id' is distinct from v_active_org_id::text
       or v_result #>> '{membership,is_active}' is distinct from 'true'
       or v_result #>> '{membership,source}' is distinct from 'subscription'
       or v_result #>> '{membership,state}' is distinct from 'active'
       or v_result #>> '{membership,subscription_id}' is distinct from v_subscription_id::text
       or v_result #>> '{membership,plan_code}' is distinct from v_plan_code
       or v_result #>> '{membership,plan_title}' is distinct from 'QA ARS-361 plan'
       or (v_result #>> '{membership,current_period_start}')::timestamptz is distinct from v_period_start
       or (v_result #>> '{membership,current_period_end}')::timestamptz is distinct from v_period_end
       or (v_result #>> '{membership,next_billing_at}')::timestamptz is distinct from v_next_billing_at
       or v_result #>> '{membership,cancel_at_period_end}' is distinct from 'false' then
        raise exception 'ARS-361: active subscription state or stored lifecycle dates were not projected faithfully: %',
            v_result;
    end if;

    if v_result #>> '{verification,membership_id}' is distinct from v_active_membership_id::text
       or v_result #>> '{verification,type_assignment,is_self_assigned}' is distinct from 'true'
       or v_result #> '{verification,type_assignment,assigned_by_user_id}' is distinct from 'null'::jsonb
       or v_result #>> '{verification,status}' is distinct from 'incomplete'
       or v_result #> '{verification,timeline}' is distinct from '[]'::jsonb
       or v_result #> '{verification,latest_by_type}' is distinct from '[]'::jsonb then
        raise exception 'ARS-361: self-assigned MPK without evidence was not kept incomplete/non-approved: %',
            v_result;
    end if;

    -- There is no canonical association-number source; never synthesize one from
    -- either the organization or membership UUID.
    if v_result->'association_number' is distinct from 'null'::jsonb then
        raise exception 'ARS-361: read model invented an association number: %', v_result;
    end if;

    -- Legacy level-stack access is still canonical for a legacy-only organization,
    -- but it must not fabricate subscription lifecycle values.
    v_legacy_result := public.rpc_get_org_membership_verification(v_legacy_org_id);
    if v_legacy_result #>> '{membership,is_active}' is distinct from 'true'
       or v_legacy_result #>> '{membership,source}' is distinct from 'legacy_membership'
       or v_legacy_result #> '{membership,state}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,trial_end}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,current_period_start}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,current_period_end}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,next_billing_at}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,cancel_at_period_end}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,subscription_id}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,plan_code}' is distinct from 'null'::jsonb
       or v_legacy_result #> '{membership,plan_title}' is distinct from 'null'::jsonb
       or v_legacy_result #>> '{membership,renewal_mode}' is distinct from 'manual_assistance'
       or v_legacy_result #>> '{membership,cta}' is distinct from 'contact_turan'
       or v_legacy_result #>> '{verification,membership_id}' is distinct from v_legacy_membership_id::text then
        raise exception 'ARS-361: legacy membership with past_due subscription projected fabricated lifecycle: %',
            v_legacy_result;
    end if;

    -- Every subscription state keeps its own stored dates after reload. Access is
    -- exactly the existing predicate: trialing/active/grace on; past_due/terminal off.
    for v_state, v_expected_active, v_expected_cta in
        select state, is_active, cta
          from (values
              ('trialing'::text, true,  'manage'::text),
              ('grace'::text,    true,  'contact_turan'::text),
              ('past_due'::text, false, 'contact_turan'::text),
              ('expired'::text,  false, 'subscribe'::text),
              ('canceled'::text, false, 'subscribe'::text)
          ) as cases(state, is_active, cta)
    loop
        v_state_org_id := gen_random_uuid();
        insert into public.organizations (id, legal_name)
        values (v_state_org_id, 'QA ARS-361 lifecycle ' || v_state);
        insert into public.membership_subscription (
            organization_id, plan_code, state, trial_end,
            current_period_start, current_period_end, next_billing_at,
            cancel_at_period_end
        ) values (
            v_state_org_id, v_plan_code, v_state, v_period_end,
            v_period_start, v_period_end, v_next_billing_at, false
        );

        v_state_result := public.rpc_get_org_membership_verification(v_state_org_id);
        if v_state_result #>> '{membership,source}' is distinct from 'subscription'
           or v_state_result #>> '{membership,is_active}' is distinct from v_expected_active::text
           or v_state_result #>> '{membership,state}' is distinct from v_state
           or v_state_result #>> '{membership,cta}' is distinct from v_expected_cta
           or (v_state_result #>> '{membership,trial_end}')::timestamptz is distinct from v_period_end
           or (v_state_result #>> '{membership,current_period_start}')::timestamptz is distinct from v_period_start
           or (v_state_result #>> '{membership,current_period_end}')::timestamptz is distinct from v_period_end
           or (v_state_result #>> '{membership,next_billing_at}')::timestamptz is distinct from v_next_billing_at
           or v_state_result #>> '{membership,cancel_at_period_end}' is distinct from 'false' then
            raise exception 'ARS-361: lifecycle state % did not preserve canonical access/dates/CTA: %',
                v_state, v_state_result;
        end if;
    end loop;

    -- Verification is append-only. A newer rejection must supersede an older
    -- approval for the same type; expiration changes effective status, never the
    -- underlying recorded result.
    insert into public.verification_records (
        membership_id, organization_id, verification_type, result, verified_by,
        verified_at, expires_at, notes
    ) values (
        v_active_membership_id, v_active_org_id, 'bin_iin_check', 'approved',
        v_admin_user_id, v_evidence_anchor, v_evidence_anchor + interval '365 days',
        'older approved record'
    ) returning id into v_old_approved_id;

    insert into public.verification_records (
        membership_id, organization_id, verification_type, result, verified_by,
        verified_at, expires_at, notes
    ) values (
        v_active_membership_id, v_active_org_id, 'bin_iin_check', 'rejected',
        v_admin_user_id, v_evidence_anchor + interval '1 day', null,
        'newer rejected record'
    ) returning id into v_rejected_id;

    insert into public.verification_records (
        membership_id, organization_id, verification_type, result, verified_by,
        verified_at, expires_at, notes
    ) values (
        v_active_membership_id, v_active_org_id, 'site_visit', 'approved',
        v_admin_user_id, v_evidence_anchor + interval '2 days',
        v_evidence_anchor + interval '3 days', 'expired approved record'
    ) returning id into v_expired_id;

    insert into public.verification_records (
        membership_id, organization_id, verification_type, result, verified_by,
        verified_at, expires_at, notes
    ) values (
        v_active_membership_id, v_active_org_id, 'document_review', 'approved',
        v_admin_user_id, v_evidence_anchor + interval '3 days',
        v_evidence_anchor + interval '365 days', 'current approved record'
    ) returning id into v_fresh_approved_id;

    v_result := public.rpc_get_org_membership_verification(v_active_org_id);
    v_timeline := v_result #> '{verification,timeline}';
    if jsonb_typeof(v_timeline) is distinct from 'array'
       or jsonb_array_length(v_timeline) <> 4
       or (v_timeline->0->>'id')::uuid is distinct from v_fresh_approved_id
       or (v_timeline->1->>'id')::uuid is distinct from v_expired_id
       or (v_timeline->2->>'id')::uuid is distinct from v_rejected_id
       or (v_timeline->3->>'id')::uuid is distinct from v_old_approved_id then
        raise exception 'ARS-361: verification timeline is not append-only/newest-first: %',
            v_timeline;
    end if;

    select e
      into v_latest
      from jsonb_array_elements(v_result #> '{verification,latest_by_type}') e
     where e->>'verification_type' = 'bin_iin_check';
    if v_latest is null
       or v_latest->>'id' is distinct from v_rejected_id::text
       or v_latest->>'result' is distinct from 'rejected'
       or v_latest->>'effective_status' is distinct from 'rejected' then
        raise exception 'ARS-361: latest rejected evidence did not supersede older approval: %',
            v_latest;
    end if;

    select e
      into v_latest
      from jsonb_array_elements(v_result #> '{verification,latest_by_type}') e
     where e->>'verification_type' = 'site_visit';
    if v_latest is null
       or v_latest->>'id' is distinct from v_expired_id::text
       or v_latest->>'result' is distinct from 'approved'
       or v_latest->>'effective_status' is distinct from 'expired' then
        raise exception 'ARS-361: expired approval did not retain raw evidence and map to expired: %',
            v_latest;
    end if;

    select e
      into v_latest
      from jsonb_array_elements(v_result #> '{verification,latest_by_type}') e
     where e->>'verification_type' = 'document_review';
    if v_latest is null
       or v_latest->>'id' is distinct from v_fresh_approved_id::text
       or v_latest->>'result' is distinct from 'approved'
       or v_latest->>'effective_status' is distinct from 'approved' then
        raise exception 'ARS-361: current approved evidence was not projected correctly: %',
            v_latest;
    end if;

    if v_result #>> '{verification,status}' is distinct from 'rejected' then
        raise exception 'ARS-361: latest rejected evidence did not dominate aggregate verification status: %',
            v_result;
    end if;

    -- Classification is the first gate for MPK evidence. A stale MPK membership row
    -- (and even an otherwise approved record) cannot expose a verification timeline.
    insert into public.verification_records (
        membership_id, organization_id, verification_type, result, verified_by,
        verified_at, expires_at
    ) values (
        v_unclassified_membership_id, v_unclassified_org_id, 'document_review',
        'approved', v_admin_user_id, v_evidence_anchor, v_evidence_anchor + interval '365 days'
    );
    v_unclassified_result := public.rpc_get_org_membership_verification(v_unclassified_org_id);
    if v_unclassified_result #>> '{verification,status}' is distinct from 'not_mpk'
       or v_unclassified_result #> '{verification,membership_id}' is distinct from 'null'::jsonb
       or v_unclassified_result #> '{verification,type_assignment}' is distinct from 'null'::jsonb
       or v_unclassified_result #> '{verification,timeline}' is distinct from '[]'::jsonb
       or v_unclassified_result #> '{verification,latest_by_type}' is distinct from '[]'::jsonb then
        raise exception 'ARS-361: stale unclassified MPK evidence leaked into the read model: %',
            v_unclassified_result;
    end if;

    -- Terminal lifecycle history is append-only too. If there is no live row, the
    -- newest terminal record (not a hard-coded state ordering) must survive reload.
    insert into public.membership_subscription (
        organization_id, plan_code, state, current_period_start,
        current_period_end, next_billing_at, created_at, updated_at
    ) values (
        v_terminal_org_id, v_plan_code, 'expired', v_period_start,
        v_period_end, null, v_evidence_anchor, v_evidence_anchor
    ), (
        v_terminal_org_id, v_plan_code, 'revoked', v_period_start + interval '1 day',
        v_period_end + interval '1 day', null,
        v_evidence_anchor + interval '1 day', v_evidence_anchor + interval '1 day'
    );
    v_terminal_result := public.rpc_get_org_membership_verification(v_terminal_org_id);
    if v_terminal_result #>> '{membership,source}' is distinct from 'subscription'
       or v_terminal_result #>> '{membership,is_active}' is distinct from 'false'
       or v_terminal_result #>> '{membership,state}' is distinct from 'revoked'
       or v_terminal_result #>> '{membership,cta}' is distinct from 'subscribe'
       or (v_terminal_result #>> '{membership,current_period_end}')::timestamptz
            is distinct from v_period_end + interval '1 day' then
        raise exception 'ARS-361: newest terminal subscription did not survive reload: %',
            v_terminal_result;
    end if;
end;
$$;

rollback;
