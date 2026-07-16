-- ============================================================
-- d14_governance.sql — Feature Governance (Microstep 3)
-- ============================================================
-- Canon: Docs/AGOS-TSP-Flow-Microsteps/AGOS-Microstep3-FeatureGovernance-v1_0.md
-- Feature: ARS-204 (Foundation B). Implements the DESIGNED-but-UNBUILT M3
-- (was tracked in IMPL_DEBT). Framework now, content later — the seed only
-- demonstrates every pattern; real feature rows are added via INSERT (P8).
--
-- Depends on: d01_kernel.sql (users, organizations, organization_type_assignments,
--             user_organization_roles, fn_current_user_id, fn_my_org_ids,
--             fn_is_admin, fn_set_updated_at),
--             d13_billing.sql (membership_subscription, membership_plan) — the
--             org-membership axis reads live subscription state + granted tier.
-- Apply order: d01 → … → d11 → d12 → d13.
--
-- Two access axes joined by OR (D-FG-3):
--   1) personal PlatformSubscription (user_tier)  — NOT yet deployed → 'free'
--      placeholder via fn_user_platform_tier(); pro-gated features fail-closed.
--   2) organization AssociationMembership (org_membership_tier) — from d12.
-- Fail-closed (D-FG-2): unknown feature / missing row / error → DENY.
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 feature_gate (binary access)  — M3 §3.1
-- ------------------------------------------------------------
create table if not exists public.feature_gate (
    feature_code    text    primary key,
    category        text    not null
                        check (category in
                            ('tsp','ai','herd','vet','feed','analytics','lms','erp','identity')),
    -- Axis 1: personal subscription. NULL = this axis does not open the feature.
    user_tier_required          text
                        check (user_tier_required is null or user_tier_required in ('free','pro')),
    -- Axis 2: org membership. NULL = this axis does not open the feature.
    org_membership_tier_required text
                        check (org_membership_tier_required is null
                            or org_membership_tier_required in ('any','standard','premium')),
    -- Extra filter: org must have at least one of these types (active assignment).
    org_type_required           text[],
    upgrade_hint    text,               -- UI copy; NULL = UI hides feature entirely
    is_teaser       boolean not null default false,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    updated_by      uuid,               -- last TURAN admin editor
    -- M3 §4: org_type_required only makes sense on the membership axis.
    constraint feature_gate_type_needs_membership_axis
        check (org_type_required is null or org_membership_tier_required is not null)
);
comment on table public.feature_gate is
    'M3 §3.1. Binary feature access. Both required NULL ⇒ public feature. Otherwise
     access via OR of the two axes (see rpc_check_feature_access). Standards-as-data:
     new features added via INSERT, no deploy (D-FG-6).';

-- ------------------------------------------------------------
-- 3.2 feature_limit (quotas per period) — M3 §3.2
-- ------------------------------------------------------------
create table if not exists public.feature_limit (
    id              uuid    primary key default gen_random_uuid(),
    feature_code    text    not null references public.feature_gate(feature_code) on delete cascade,
    applies_to      text    not null check (applies_to in ('user_tier','org_membership_tier')),
    applies_value   text    not null,          -- e.g. 'free','pro','standard'
    limit_value     integer not null check (limit_value >= 0),
    limit_unit      text    not null,          -- 'messages' | 'batches' | 'export_jobs' | ...
    limit_period    text    not null check (limit_period in ('day','week','month','billing_cycle')),
    created_at      timestamptz not null default now(),
    unique (feature_code, applies_to, applies_value, limit_period)
);
comment on table public.feature_limit is
    'M3 §3.2. Quantitative quota for a gated feature. Meaningless without a
     feature_gate for the same feature_code (no access ⇒ no quota).';

-- ------------------------------------------------------------
-- 3.3 feature_usage (append-only usage log) — M3 §3.3
-- NOTE: M3 canon specifies BIGSERIAL PK; project convention (CLAUDE.md) is
-- uuid PK. We follow the uuid convention here — behaviour is identical.
-- Flagged to Architect for M3 doc reconciliation.
-- ------------------------------------------------------------
create table if not exists public.feature_usage (
    id              uuid    primary key default gen_random_uuid(),
    user_id         uuid    not null references public.users(id),
    org_id          uuid    references public.organizations(id),
    feature_code    text    not null references public.feature_gate(feature_code),
    used_at         timestamptz not null default now(),
    count           integer not null default 1 check (count > 0),
    metadata        jsonb
);
comment on table public.feature_usage is
    'M3 §3.3. Append-only (no UPDATE/DELETE except TTL cleanup). Quota check =
     SUM(count) over the period window. Written in the same transaction as the
     consuming RPC (rollback ⇒ no usage recorded).';

create index if not exists idx_feature_usage_lookup
    on public.feature_usage (user_id, feature_code, used_at);

-- ------------------------------------------------------------
-- Personal subscription tier resolver.
-- PlatformSubscription is NOT deployed yet → everyone is 'free' (fail-closed
-- for 'pro' features). When PlatformSubscription lands, replace the body only —
-- signature stays, so no caller breaks (P7).
-- ------------------------------------------------------------
create or replace function public.fn_user_platform_tier(p_user_id uuid)
returns text language sql security definer stable
set search_path = public, pg_temp as $$
    select 'free'::text where p_user_id is not null;
$$;
comment on function public.fn_user_platform_tier(uuid) is
    'M3 axis-1 placeholder. Returns personal PlatformSubscription tier; ''free''
     until PlatformSubscription is built. Replace body only, keep signature (P7).';

-- ------------------------------------------------------------
-- rpc_check_feature_access — the effective_access formula (M3 §4)
-- Returns jsonb: { allow, reason, upgrade_hint, is_teaser, limit }
--   limit (when access granted and a quota applies):
--     { value, unit, period, used, remaining }
-- Fail-closed: unknown feature ⇒ allow=false.
-- Read-only: emits NO events (invalidation is fired by mutation RPCs).
-- ------------------------------------------------------------
create or replace function public.rpc_check_feature_access(
    p_user_id       uuid,
    p_feature_code  text,
    p_organization_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_gate          public.feature_gate%rowtype;
    v_public        boolean := false;
    v_user_tier     text;
    v_user_grants   boolean := false;
    v_org_grants    boolean := false;
    v_sub_state     text;
    v_org_tier      text;
    v_tier_match    boolean;
    v_role_ok       boolean;
    v_type_ok       boolean;
    v_allow         boolean;
    v_axis          text;           -- axis used for quota: 'user_tier' | 'org_membership_tier'
    v_axis_value    text;
    v_lim           public.feature_limit%rowtype;
    v_window_start  timestamptz;
    v_used          integer;
    v_limit_json    jsonb := null;
begin
    -- SEC-RPC-ORGTRUST-01: SECURITY DEFINER bypasses RLS and p_user_id/p_organization_id are
    -- client-supplied. A normal authenticated caller may only query their OWN user + OWN orgs;
    -- service_role (AI gateway, P-AI-6) and admin may query on behalf of anyone.
    if not (auth.role() = 'service_role' or public.fn_is_admin()) then
        if p_user_id is distinct from public.fn_current_user_id() then
            raise exception 'FORBIDDEN: cannot query feature access for another user' using errcode = '42501';
        end if;
        if p_organization_id is not null
           and not (p_organization_id = any(public.fn_my_org_ids())) then
            raise exception 'FORBIDDEN: not a member of organization %', p_organization_id using errcode = '42501';
        end if;
    end if;

    -- Fail-closed on unknown feature (D-FG-2)
    select * into v_gate from public.feature_gate where feature_code = p_feature_code;
    if not found then
        return jsonb_build_object(
            'allow', false, 'reason', 'unknown_feature',
            'feature_code', p_feature_code, 'limit', null);
    end if;

    v_public := (v_gate.user_tier_required is null
                 and v_gate.org_membership_tier_required is null);

    -- Axis 1: personal subscription tier (rank: free=1, pro=2)
    v_user_tier := public.fn_user_platform_tier(p_user_id);
    if v_gate.user_tier_required is not null then
        if (case v_user_tier when 'pro' then 2 when 'free' then 1 else 0 end)
           >= (case v_gate.user_tier_required when 'pro' then 2 when 'free' then 1 else 0 end)
        then
            v_user_grants := true;
        end if;
    end if;

    -- Axis 2: org membership (live subscription state + granted tier from d12)
    if v_gate.org_membership_tier_required is not null and p_organization_id is not null then
        select ms.state, mp.grants_tier
          into v_sub_state, v_org_tier
          from public.membership_subscription ms
          join public.membership_plan mp on mp.plan_code = ms.plan_code
         where ms.organization_id = p_organization_id
           and ms.state in ('trialing','active','grace')   -- capabilities ON
         order by (case mp.grants_tier when 'premium' then 2 else 1 end) desc
         limit 1;

        if found then
            -- (b) tier match ('any' == 'standard' in MVP; premium ≥ standard)
            v_tier_match := (v_gate.org_membership_tier_required = 'any')
                or ((case v_org_tier when 'premium' then 2 else 1 end)
                    >= (case v_gate.org_membership_tier_required
                            when 'premium' then 2 else 1 end));

            -- (c) user must have a role in this org
            v_role_ok := exists (
                select 1 from public.user_organization_roles
                 where user_id = p_user_id and organization_id = p_organization_id);

            -- (d) org type filter — deployed organization_type_assignments has NO
            -- status column (M3 §4 referenced status='active'; drift flagged);
            -- assignment existence = active.
            v_type_ok := (v_gate.org_type_required is null)
                or exists (
                    select 1 from public.organization_type_assignments
                     where organization_id = p_organization_id
                       and org_type = any(v_gate.org_type_required));

            if v_tier_match and v_role_ok and v_type_ok then
                v_org_grants := true;
            end if;
        end if;
    end if;

    v_allow := v_public or v_user_grants or v_org_grants;

    -- Attach applicable quota (only when access granted)
    if v_allow then
        if v_org_grants then
            v_axis := 'org_membership_tier';
            v_axis_value := v_org_tier;
        else
            v_axis := 'user_tier';
            v_axis_value := v_user_tier;
        end if;

        select * into v_lim
          from public.feature_limit
         where feature_code = p_feature_code
           and applies_to = v_axis
           and applies_value = v_axis_value
         limit 1;

        if found then
            v_window_start := case v_lim.limit_period
                when 'day'   then now() - interval '1 day'
                when 'week'  then now() - interval '7 days'
                when 'month' then now() - interval '1 month'
                when 'billing_cycle' then coalesce(
                    (select current_period_start
                       from public.membership_subscription
                      where organization_id = p_organization_id
                        and state in ('trialing','active','grace')
                      order by current_period_start desc nulls last
                      limit 1),
                    now() - interval '1 month')
                else now() - interval '1 month'
            end;

            select coalesce(sum(count), 0) into v_used
              from public.feature_usage
             where user_id = p_user_id
               and feature_code = p_feature_code
               and used_at >= v_window_start;

            v_limit_json := jsonb_build_object(
                'value', v_lim.limit_value,
                'unit', v_lim.limit_unit,
                'period', v_lim.limit_period,
                'used', v_used,
                'remaining', greatest(v_lim.limit_value - v_used, 0));
        end if;
    end if;

    return jsonb_build_object(
        'allow', v_allow,
        'reason', case
            when v_public then 'public'
            when v_org_grants then 'org_membership'
            when v_user_grants then 'user_tier'
            else 'denied' end,
        'upgrade_hint', v_gate.upgrade_hint,
        'is_teaser', v_gate.is_teaser,
        'limit', v_limit_json);
exception when others then
    -- Fail-closed on any error (D-FG-2)
    return jsonb_build_object('allow', false, 'reason', 'error', 'limit', null);
end;
$$;

comment on function public.rpc_check_feature_access(uuid, text, uuid) is
    'M3 §4 effective_access. OR of user-tier and org-membership axes; NULL axis
     does not grant; both NULL ⇒ public. Fail-closed. Returns allow + applicable
     quota. Read-only (no events). Org axis reads d13 membership_subscription.';

-- Grants: lock down from PUBLIC/anon (SEC-RPC-ORGTRUST-01). authenticated = own data
-- (guarded above); service_role = AI gateway (P-AI-6). Note: `revoke from anon` alone does
-- NOT remove the default PUBLIC execute grant — must revoke from PUBLIC.
revoke execute on function public.rpc_check_feature_access(uuid, text, uuid) from public;
revoke execute on function public.rpc_check_feature_access(uuid, text, uuid) from anon;
grant  execute on function public.rpc_check_feature_access(uuid, text, uuid) to authenticated;
grant  execute on function public.rpc_check_feature_access(uuid, text, uuid) to service_role;
revoke execute on function public.fn_user_platform_tier(uuid) from public;
revoke execute on function public.fn_user_platform_tier(uuid) from anon;
grant  execute on function public.fn_user_platform_tier(uuid) to authenticated;
grant  execute on function public.fn_user_platform_tier(uuid) to service_role;

-- ------------------------------------------------------------
-- Row Level Security
-- ------------------------------------------------------------
alter table public.feature_gate   enable row level security;
alter table public.feature_limit  enable row level security;
alter table public.feature_usage  enable row level security;

-- Gate & limit are public config: any authenticated user reads; admin writes.
drop policy if exists "feature_gate_read_authenticated" on public.feature_gate;
create policy "feature_gate_read_authenticated"
    on public.feature_gate for select using (auth.uid() is not null);
drop policy if exists "feature_gate_admin_write" on public.feature_gate;
create policy "feature_gate_admin_write"
    on public.feature_gate for all using (public.fn_is_admin());

drop policy if exists "feature_limit_read_authenticated" on public.feature_limit;
create policy "feature_limit_read_authenticated"
    on public.feature_limit for select using (auth.uid() is not null);
drop policy if exists "feature_limit_admin_write" on public.feature_limit;
create policy "feature_limit_admin_write"
    on public.feature_limit for all using (public.fn_is_admin());

-- Usage: a user reads only their own rows (admin reads all). Writes go through
-- SECURITY DEFINER RPCs (which bypass RLS) — no client-side insert policy.
drop policy if exists "feature_usage_read_own" on public.feature_usage;
create policy "feature_usage_read_own"
    on public.feature_usage for select
    using (user_id = public.fn_current_user_id() or public.fn_is_admin());

-- ------------------------------------------------------------
-- updated_at trigger (feature_gate only; limit/usage have no updated_at)
-- ------------------------------------------------------------
drop trigger if exists trg_feature_gate_updated_at on public.feature_gate;
create trigger trg_feature_gate_updated_at
    before update on public.feature_gate
    for each row execute function public.fn_set_updated_at();

-- ------------------------------------------------------------
-- RPC name registry (D-NEW-A)
-- ------------------------------------------------------------
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_check_feature_access', null, 'check_feature_access', 'd14_governance.sql',
        'M3 §4 effective_access: gate decision + applicable quota, fail-closed')
on conflict (sql_name) do nothing;

-- ------------------------------------------------------------
-- Seed — 6 template examples (M3 §7). Framework demo, NOT MVP content.
-- ------------------------------------------------------------
-- 1. TSP create batch — members only, org type farmer
insert into public.feature_gate
    (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser)
values ('tsp_create_batch', 'tsp', null, 'any', array['farmer'],
        'Доступно для членов ассоциации с типом «фермер»', false)
on conflict (feature_code) do nothing;

-- 2. TSP market preview — public teaser
insert into public.feature_gate
    (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser)
values ('tsp_view_market_preview', 'tsp', null, null, null, null, true)
on conflict (feature_code) do nothing;

-- 3. AI basic chat — public with a free-tier daily quota
insert into public.feature_gate
    (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser)
values ('ai_chat_basic', 'ai', null, null, null, null, false)
on conflict (feature_code) do nothing;

insert into public.feature_limit
    (feature_code, applies_to, applies_value, limit_value, limit_unit, limit_period)
values ('ai_chat_basic', 'user_tier', 'free', 10, 'messages', 'day')
on conflict (feature_code, applies_to, applies_value, limit_period) do nothing;

-- 4. NASEM calculator — Pro (placeholder rule)
insert into public.feature_gate
    (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser)
values ('feed_ration_calculator_nasem', 'feed', 'pro', null, null,
        'Расчёт рационов NASEM — для Pro-подписчиков', false)
on conflict (feature_code) do nothing;

-- 5. ERP access — Pro (D-FG-7)
insert into public.feature_gate
    (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser)
values ('erp_access', 'erp', 'pro', null, null, 'ERP-модуль доступен в Pro-подписке', false)
on conflict (feature_code) do nothing;

-- 6. LMS free catalog — public
insert into public.feature_gate
    (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser)
values ('lms_free_courses', 'lms', null, null, null, null, false)
on conflict (feature_code) do nothing;
