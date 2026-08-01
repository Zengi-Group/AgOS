-- ARS-361 — canonical membership + MPK verification read model.
-- Additive deployment counterpart of d13_billing.sql. This does not alter the
-- membership lifecycle engine or arm the staging-only renewal cron.
-- Requires the canonical d01/d13 schema (organizations, memberships,
-- verification_records, membership_subscription, helpers, and RPC registry).

create index if not exists idx_verification_records_mpk_projection
    on public.verification_records (
        organization_id, membership_id, verification_type, verified_at desc, id desc
    ) include (result, expires_at);
comment on index public.idx_verification_records_mpk_projection is
    'ARS-361. Supports canonical MPK verification latest-by-type and timeline reads.';

create or replace function public.rpc_get_org_membership_verification(
    p_organization_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_subscription          public.membership_subscription%rowtype;
    v_mpk_membership        public.memberships%rowtype;
    v_assignment            public.organization_type_assignments%rowtype;
    v_has_subscription      boolean := false;
    v_has_mpk_membership    boolean := false;
    v_has_assignment        boolean := false;
    v_is_active             boolean := false;
    v_is_self_assigned      boolean := false;
    v_membership_source     text := 'none';
    v_plan_title             text;
    v_cta                    text := 'subscribe';
    v_now                    timestamptz := now();
    v_latest_by_type         jsonb := '[]'::jsonb;
    v_timeline               jsonb := '[]'::jsonb;
    v_has_evidence           boolean := false;
    v_has_rejected           boolean := false;
    v_has_expired            boolean := false;
    v_has_conditional        boolean := false;
    v_all_latest_approved    boolean := false;
    v_verification_status    text := 'not_mpk';
begin
    if p_organization_id is null
       or not (
           p_organization_id = any(coalesce(public.fn_my_org_ids(), array[]::uuid[]))
           or public.fn_is_admin()
           -- auth.role() is NULL when request.jwt.claims has no role. Coalesce it
           -- so an unauthenticated request cannot turn the whole predicate NULL.
           or coalesce(auth.role(), '') = 'service_role'
       ) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    select s.* into v_subscription
      from public.membership_subscription s
     where s.organization_id = p_organization_id
     order by (s.state in ('trialing', 'active', 'grace', 'past_due')) desc,
              s.updated_at desc,
              s.created_at desc,
              s.id desc
     limit 1;
    v_has_subscription := found;

    if v_has_subscription then
        select mp.title into v_plan_title
          from public.membership_plan mp
         where mp.plan_code = v_subscription.plan_code;
    end if;

    v_is_active := public.fn_org_membership_active(p_organization_id);
    if v_is_active
       and v_has_subscription
       and v_subscription.state in ('trialing', 'active', 'grace') then
        v_membership_source := 'subscription';
    elsif v_is_active then
        v_membership_source := 'legacy_membership';
    elsif v_has_subscription then
        v_membership_source := 'subscription';
    end if;

    if v_membership_source = 'legacy_membership' then
        v_cta := 'contact_turan';
    elsif v_membership_source = 'subscription' then
        v_cta := case
            when v_subscription.state in ('grace', 'past_due') then 'contact_turan'
            when v_subscription.state in ('expired', 'canceled', 'revoked') then 'subscribe'
            else 'manage'
        end;
    end if;

    select m.* into v_mpk_membership
      from public.memberships m
     where m.organization_id = p_organization_id
       and m.org_type = 'mpk'
     limit 1;
    v_has_mpk_membership := found;

    select ota.* into v_assignment
      from public.organization_type_assignments ota
     where ota.organization_id = p_organization_id
       and ota.org_type = 'mpk'
     limit 1;
    v_has_assignment := found;

    v_is_self_assigned := v_has_assignment and (v_assignment.assigned_by is null);

    if v_has_assignment and v_has_mpk_membership then
        with ranked as (
            select vr.id,
                   vr.verification_type,
                   vr.result,
                   vr.verified_at,
                   vr.expires_at,
                   row_number() over (
                       partition by vr.verification_type
                       order by vr.verified_at desc, vr.id desc
                   ) as recency_rank
              from public.verification_records vr
             where vr.organization_id = p_organization_id
               and vr.membership_id = v_mpk_membership.id
        ), latest as (
            select id,
                   verification_type,
                   result,
                   verified_at,
                   expires_at,
                   case
                       when expires_at is not null and expires_at <= v_now then 'expired'
                       else result
                   end as status
              from ranked
             where recency_rank = 1
        )
        select coalesce(
                   jsonb_agg(
                       jsonb_build_object(
                           'id', id,
                           'verification_type', verification_type,
                           'result', result,
                           'effective_status', status,
                           'verified_at', verified_at,
                           'expires_at', expires_at
                       ) order by verification_type
                   ),
                   '[]'::jsonb
               ),
               count(*) > 0,
               coalesce(bool_or(status = 'rejected'), false),
               coalesce(bool_or(status = 'expired'), false),
               coalesce(bool_or(status = 'conditional'), false),
               coalesce(bool_and(status = 'approved'), false)
          into v_latest_by_type,
               v_has_evidence,
               v_has_rejected,
               v_has_expired,
               v_has_conditional,
               v_all_latest_approved
          from latest;

        select coalesce(
                   jsonb_agg(
                       jsonb_build_object(
                           'id', vr.id,
                           'verification_type', vr.verification_type,
                           'result', vr.result,
                           'effective_status', case
                               when vr.expires_at is not null and vr.expires_at <= v_now
                                   then 'expired'
                               else vr.result
                           end,
                           'verified_at', vr.verified_at,
                           'expires_at', vr.expires_at
                       ) order by vr.verified_at desc, vr.id desc
                   ),
                   '[]'::jsonb
               )
          into v_timeline
          from public.verification_records vr
         where vr.organization_id = p_organization_id
           and vr.membership_id = v_mpk_membership.id;
    end if;

    if not v_has_assignment then
        v_verification_status := 'not_mpk';
    elsif not v_has_evidence then
        v_verification_status := 'incomplete';
    elsif v_has_rejected then
        v_verification_status := 'rejected';
    elsif v_has_expired then
        v_verification_status := 'expired';
    elsif v_has_conditional then
        v_verification_status := 'conditional';
    elsif v_all_latest_approved then
        v_verification_status := 'approved';
    else
        v_verification_status := 'incomplete';
    end if;

    return jsonb_build_object(
        'version', 1,
        'organization_id', p_organization_id,
        'association_number', null::text,
        'membership', jsonb_build_object(
            'source', v_membership_source,
            'is_active', v_is_active,
            'subscription_id', case when v_membership_source = 'subscription' then v_subscription.id else null end,
            'state', case when v_membership_source = 'subscription' then v_subscription.state else null end,
            'plan_code', case when v_membership_source = 'subscription' then v_subscription.plan_code else null end,
            'plan_title', case when v_membership_source = 'subscription' then v_plan_title else null end,
            'trial_end', case when v_membership_source = 'subscription' then v_subscription.trial_end else null end,
            'current_period_start', case when v_membership_source = 'subscription' then v_subscription.current_period_start else null end,
            'current_period_end', case when v_membership_source = 'subscription' then v_subscription.current_period_end else null end,
            'next_billing_at', case when v_membership_source = 'subscription' then v_subscription.next_billing_at else null end,
            'cancel_at_period_end', case when v_membership_source = 'subscription' then v_subscription.cancel_at_period_end else null end,
            'renewal_mode', 'manual_assistance',
            'cta', v_cta
        ),
        'verification', jsonb_build_object(
            'membership_id', case when v_has_assignment and v_has_mpk_membership then v_mpk_membership.id else null end,
            'type_assignment', case
                when v_has_assignment then jsonb_build_object(
                    'assigned_at', v_assignment.assigned_at,
                    'assigned_by_user_id', v_assignment.assigned_by,
                    'is_self_assigned', v_is_self_assigned,
                    'classification_only', true
                )
                else 'null'::jsonb
            end,
            'status', v_verification_status,
            'latest_by_type', v_latest_by_type,
            'timeline', v_timeline
        )
    );
end;
$$;
comment on function public.rpc_get_org_membership_verification(uuid) is
    'ARS-361. Member/admin/trusted-service canonical read model for membership lifecycle and MPK
     verification evidence. fn_org_membership_active remains the access source; legacy
     access is explicit and has null subscription lifecycle fields. Assignment is
     classification-only; verification.status summarizes evidence, not a write gate.';

revoke execute on function public.rpc_get_org_membership_verification(uuid) from public, anon;
grant  execute on function public.rpc_get_org_membership_verification(uuid) to authenticated, service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values (
    'rpc_get_org_membership_verification',
    null,
    'get_org_membership_verification',
    'd13_billing.sql',
    'ARS-361 canonical membership lifecycle + MPK verification read model'
)
on conflict (sql_name) do nothing;
