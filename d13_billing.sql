-- ============================================================
-- d13_billing.sql — Membership Billing (recurrent org subscription)
-- ============================================================
-- Domain: AssociationMembership made recurrent/paid.
-- Canon: Feature ARS-202 (G2 closed 2026-07-10), Microstep 2 (Membership FSM).
-- Depends on: d01_kernel.sql (organizations, memberships, users, helpers,
--             fn_my_org_ids, fn_is_admin, fn_set_updated_at).
-- Apply order: d01 → … → d12 → d13. (ARS-268: was mislabeled d12 pre-renumber —
--   d12 is d12_messaging.sql; this file was renumbered d12→d13.)
--
-- Slice ARS-203 (Foundation A): membership_plan + membership_subscription.
-- Additive only (P7) — existing memberships table is NOT modified.
-- The subscription.state column supplies the `state` that the Feature
-- Governance formula (Microstep 3 / d13) expects — closing the M2↔M3 drift.
-- ============================================================

-- ------------------------------------------------------------
-- membership_plan (reference / config catalog — P8: standards as data)
-- Admin-managed plan constructor. Durations simplified to 1/3/12 months
-- per CEO decision (ARS-202). New plans are added via INSERT, no deploy.
-- ------------------------------------------------------------
create table if not exists public.membership_plan (
    id              uuid    primary key default gen_random_uuid(),
    plan_code       text    not null unique,          -- stable machine id, e.g. 'org_monthly'
    title           text    not null,                 -- human label, e.g. 'Месяц'
    billing_period  text    not null
                        check (billing_period in ('1 month', '3 months', '12 months')),
    price_amount    numeric(12,2) not null check (price_amount >= 0),
    currency        text    not null default 'KZT',
    trial_days      integer not null default 30 check (trial_days >= 0),  -- 30 = 1 месяц (CEO)
    applies_org_type text   check (applies_org_type is null
                        or applies_org_type in ('farmer', 'mpk', 'supplier', 'consultant', 'other')),
    grants_tier     text    not null default 'standard'
                        check (grants_tier in ('standard', 'premium')),  -- org_membership tier for d13
    grace_days      integer not null default 3 check (grace_days >= 0),  -- ARS-264: grace window per plan (P8)
    version         integer not null default 1,
    is_active       boolean not null default true,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.membership_plan is
    'ARS-203. P8 reference catalog of org membership plans. billing_period fixed to
     1/3/12 months (CEO, ARS-202). Admin fills price + trial + grants_tier via constructor,
     no deploy. grants_tier feeds the org-membership axis of Feature Governance (d13).';

-- ARS-264: grace_days added post-deploy → additive ALTER for existing installs (P8).
-- `create table if not exists` above won't add a column to a table that already
-- exists on prod, so an explicit idempotent ALTER is required.
alter table public.membership_plan
    add column if not exists grace_days integer not null default 3;
alter table public.membership_plan drop constraint if exists chk_membership_plan_grace_days;
alter table public.membership_plan add  constraint chk_membership_plan_grace_days
    check (grace_days >= 0);
comment on column public.membership_plan.grace_days is
    'ARS-264. Days the subscription stays in grace/past_due before the renewal engine
     walks it one step down the ladder. Read per-plan by rpc_process_membership_renewals
     (was hardcoded 3 in ARS-206). P8: config as data.';

-- ------------------------------------------------------------
-- membership_subscription (org-scoped, one live row per org)
-- FSM: trialing → active → grace → (past_due) → expired | canceled
-- capabilities ON while state in (trialing, active, grace) — see d13.
-- ------------------------------------------------------------
create table if not exists public.membership_subscription (
    id              uuid    primary key default gen_random_uuid(),
    organization_id uuid    not null references public.organizations(id) on delete cascade,
    membership_id   uuid    references public.memberships(id) on delete set null,  -- additive link
    plan_code       text    not null references public.membership_plan(plan_code),
    state           text    not null default 'trialing'
                        check (state in ('trialing', 'active', 'grace', 'past_due', 'expired', 'canceled', 'revoked')),
    trial_end               timestamptz,
    current_period_start    timestamptz,
    current_period_end      timestamptz,
    next_billing_at         timestamptz,
    cancel_at_period_end    boolean not null default false,
    price_snapshot          numeric(12,2),   -- price locked at subscription/renewal time
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.membership_subscription is
    'ARS-203. Recurrent subscription for an organization''s association membership.
     One LIVE subscription per org (partial unique index below). Terminal rows
     (expired/canceled) may accumulate as history. state supplies the value the
     Feature Governance formula (d13, Microstep 3 §4) reads for the org axis.';

-- ARS-267: disciplinary revoke (MS2 D-MEM-5, CEO D-BILL-REVOKE-01) adds a terminal
-- `revoked` state (≠ voluntary cancel; non-recurrent — a new subscription/application
-- is needed to return). text+CHECK evolves in place; `create table if not exists` is a
-- no-op on prod, so an explicit idempotent drop+add is required for existing installs.
alter table public.membership_subscription drop constraint if exists membership_subscription_state_check;
alter table public.membership_subscription add  constraint membership_subscription_state_check
    check (state in ('trialing', 'active', 'grace', 'past_due', 'expired', 'canceled', 'revoked'));
-- ARS-267: reason captured when an admin disciplinarily revokes membership.
alter table public.membership_subscription
    add column if not exists revoke_reason text;
comment on column public.membership_subscription.revoke_reason is
    'ARS-267. Admin-supplied reason for a disciplinary revoke (state=''revoked''). null otherwise.';

-- One live subscription per organization; terminal states may repeat.
create unique index if not exists uq_membership_subscription_live
    on public.membership_subscription (organization_id)
    where state in ('trialing', 'active', 'grace', 'past_due');

create index if not exists idx_membership_subscription_org
    on public.membership_subscription (organization_id);
create index if not exists idx_membership_subscription_state
    on public.membership_subscription (state);
-- Renewal engine (ARS-206) scans due subscriptions via this partial index.
create index if not exists idx_membership_subscription_due
    on public.membership_subscription (next_billing_at)
    where state in ('active', 'grace', 'past_due');

-- ------------------------------------------------------------
-- Row Level Security
-- ------------------------------------------------------------
alter table public.membership_plan          enable row level security;
alter table public.membership_subscription  enable row level security;

-- Plans are a public catalog: any authenticated user may read; admin writes.
drop policy if exists "membership_plan_read_authenticated" on public.membership_plan;
create policy "membership_plan_read_authenticated"
    on public.membership_plan for select
    using (auth.uid() is not null);

drop policy if exists "membership_plan_admin_write" on public.membership_plan;
create policy "membership_plan_admin_write"
    on public.membership_plan for all
    using (public.fn_is_admin());

-- Subscription is org-scoped: members of the org (or admin) read; admin writes.
-- (Lifecycle RPCs are SECURITY DEFINER and bypass RLS — slice ARS-205.)
drop policy if exists "membership_subscription_read_own" on public.membership_subscription;
create policy "membership_subscription_read_own"
    on public.membership_subscription for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

drop policy if exists "membership_subscription_admin_write" on public.membership_subscription;
create policy "membership_subscription_admin_write"
    on public.membership_subscription for all
    using (public.fn_is_admin());

-- ------------------------------------------------------------
-- updated_at triggers (reuse d01 fn_set_updated_at)
-- ------------------------------------------------------------
drop trigger if exists trg_membership_plan_updated_at on public.membership_plan;
create trigger trg_membership_plan_updated_at
    before update on public.membership_plan
    for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_membership_subscription_updated_at on public.membership_subscription;
create trigger trg_membership_subscription_updated_at
    before update on public.membership_subscription
    for each row execute function public.fn_set_updated_at();

-- ------------------------------------------------------------
-- Seed: starter plan catalog (CEO prices, ARS-202)
--   Месяц    1 month   4 850 ₸
--   3 месяца 3 months  13 095 ₸ (4850×3 − 10%)
--   Год      12 months 52 380 ₸ (4850×12 − 10%)
-- ------------------------------------------------------------
insert into public.membership_plan
    (plan_code, title, billing_period, price_amount, currency, trial_days, grants_tier)
values
    ('org_monthly',   'Месяц',    '1 month',   4850.00,  'KZT', 30, 'standard'),
    ('org_quarterly', '3 месяца', '3 months',  13095.00, 'KZT', 30, 'standard'),
    ('org_annual',    'Год',      '12 months', 52380.00, 'KZT', 30, 'standard')
on conflict (plan_code) do nothing;

-- ============================================================
-- Slice ARS-205 (subscription lifecycle RPCs)
-- All SECURITY DEFINER; caller must belong to the org (fn_my_org_ids) or be admin.
-- organization_id in every mutating RPC (P-AI-2). Additive (P7): no signature of
-- an existing RPC is touched. Web and AI Gateway call the SAME functions.
--
-- Events emitted (Dok 4 D66 'domain.entity.action'):
--   membership.subscription.started
--   membership.subscription.canceled
--   entitlements.invalidated   ← tells clients to re-fetch rpc_check_feature_access
-- FLAG (Architect): these 3 events are not yet registered in Dok 4 — needs the
-- EventBus doc updated + notification templates decided. Renewal event
-- (membership.subscription.renewed) belongs to the renewal engine (ARS-206).
-- ============================================================

-- ------------------------------------------------------------
-- rpc_list_membership_plans — public catalog for the pricing screen.
-- Read-only. Returns active plans ordered by price.
-- ------------------------------------------------------------
create or replace function public.rpc_list_membership_plans()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select coalesce(jsonb_agg(p order by p.price_amount), '[]'::jsonb)
    from (
        select plan_code, title, billing_period, price_amount, currency,
               trial_days, grants_tier, applies_org_type
        from public.membership_plan
        where is_active = true
    ) p;
$$;
comment on function public.rpc_list_membership_plans() is
    'ARS-205. Active membership plans for the pricing screen. Read-only.';

-- ------------------------------------------------------------
-- rpc_get_org_subscription — the org''s single LIVE subscription (or null),
-- enriched with plan title/price. Terminal history rows are ignored.
-- ------------------------------------------------------------
create or replace function public.rpc_get_org_subscription(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_row jsonb;
begin
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    select to_jsonb(s) || jsonb_build_object(
               'plan_title', mp.title,
               'plan_price', mp.price_amount,
               'plan_currency', mp.currency,
               'grants_tier', mp.grants_tier)
      into v_row
      from public.membership_subscription s
      join public.membership_plan mp on mp.plan_code = s.plan_code
     where s.organization_id = p_organization_id
       and s.state in ('trialing','active','grace','past_due')
     limit 1;

    return coalesce(v_row, 'null'::jsonb);
end;
$$;
comment on function public.rpc_get_org_subscription(uuid) is
    'ARS-205. The org''s live subscription (trialing/active/grace/past_due) + plan
     info, or JSON null. Member-or-admin only.';

-- ------------------------------------------------------------
-- fn_org_membership_active — canonical "is this org an active member?" predicate.
-- Source of truth for membership (ARS-263, D-BILL-TRUTH-01): a live PAID
-- subscription (trialing|active|grace — the access-ON window, past_due excluded
-- per d13 access rule) OR a legacy level-stack membership (old flow, NOT removed —
-- HS-2). One point of truth: every consumer that used to read `memberships.level`
-- directly (TSP gates SEC-GATE-MEMBERSHIP-01, admin membership_paid) calls this.
-- Pure org-scoped predicate — does NOT authenticate the caller; callers keep their
-- own ownership guard. Internal helper: revoke from public/anon/authenticated,
-- invoked by SECURITY DEFINER gate functions (owner executes) + service_role.
-- ------------------------------------------------------------
create or replace function public.fn_org_membership_active(p_organization_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select exists (
        -- canonical: live paid subscription (D-BILL-TRUTH-01)
        select 1 from public.membership_subscription
        where organization_id = p_organization_id
          and state in ('trialing', 'active', 'grace')
    ) or exists (
        -- legacy level-stack member (old flow, frozen not removed — HS-2)
        select 1 from public.memberships
        where organization_id = p_organization_id
          and level <> 'registered'
    );
$$;
comment on function public.fn_org_membership_active(uuid) is
    'ARS-263 / D-BILL-TRUTH-01. Canonical membership-active predicate: live paid
     subscription (trialing|active|grace) OR legacy level<>registered. Single point
     of truth for TSP gates + admin membership_paid. Pure predicate, no caller auth.';

-- Internal predicate: no ownership guard (org_id is an argument), so it must NOT be
-- callable directly by clients — revoke from PUBLIC (default grant), not just anon.
revoke execute on function public.fn_org_membership_active(uuid) from public;
revoke execute on function public.fn_org_membership_active(uuid) from anon;
revoke execute on function public.fn_org_membership_active(uuid) from authenticated;
grant  execute on function public.fn_org_membership_active(uuid) to service_role;

-- ------------------------------------------------------------
-- rpc_subscribe_org_membership — enroll an org into a plan, starting the trial.
-- Guards: authz (member/admin), plan active, no existing live subscription.
-- trial_days > 0 → state 'trialing' (period = trial window; billing after trial);
-- trial_days = 0 → state 'active' (first paid period starts now).
-- ------------------------------------------------------------
create or replace function public.rpc_subscribe_org_membership(
    p_organization_id uuid,
    p_plan_code       text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_plan          public.membership_plan%rowtype;
    v_membership_id uuid;
    v_state         text;
    v_now           timestamptz := now();
    v_trial_end     timestamptz;
    v_period_end    timestamptz;
    v_sub_id        uuid;
    v_row           jsonb;
begin
    -- authz
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    -- plan must exist and be active
    select * into v_plan
      from public.membership_plan
     where plan_code = p_plan_code and is_active = true;
    if not found then
        raise exception 'PLAN_NOT_FOUND: % (or inactive)', p_plan_code
            using errcode = 'P0002';
    end if;

    -- one live subscription per org (also enforced by uq_membership_subscription_live)
    if exists (
        select 1 from public.membership_subscription
         where organization_id = p_organization_id
           and state in ('trialing','active','grace','past_due')
    ) then
        raise exception 'ALREADY_SUBSCRIBED: organization % has a live subscription',
            p_organization_id using errcode = '23505';
    end if;

    -- additive link to the org''s existing membership row, if any
    select id into v_membership_id
      from public.memberships
     where organization_id = p_organization_id
     limit 1;

    if v_plan.trial_days > 0 then
        v_state      := 'trialing';
        v_trial_end  := v_now + make_interval(days => v_plan.trial_days);
        v_period_end := v_trial_end;   -- billing starts when the trial ends
    else
        v_state      := 'active';
        v_trial_end  := null;
        v_period_end := v_now + v_plan.billing_period::interval;
    end if;

    insert into public.membership_subscription
        (organization_id, membership_id, plan_code, state,
         trial_end, current_period_start, current_period_end,
         next_billing_at, price_snapshot)
    values
        (p_organization_id, v_membership_id, p_plan_code, v_state,
         v_trial_end, v_now, v_period_end,
         v_period_end, v_plan.price_amount)
    returning id into v_sub_id;

    perform public.publish_platform_event(
        'membership.subscription.started',
        p_organization_id,
        v_sub_id,
        jsonb_build_object('plan_code', p_plan_code, 'state', v_state,
                           'trial_end', v_trial_end, 'period_end', v_period_end));
    -- capabilities changed → clients must re-check feature access
    perform public.publish_platform_event(
        'entitlements.invalidated', p_organization_id, v_sub_id,
        jsonb_build_object('reason', 'subscription_started'));

    select to_jsonb(s) into v_row
      from public.membership_subscription s where s.id = v_sub_id;
    return v_row;
end;
$$;
comment on function public.rpc_subscribe_org_membership(uuid, text) is
    'ARS-205. Enroll an org into a plan and start the trial (or first paid period).
     One live subscription per org. Emits subscription.started + entitlements.invalidated.';

-- ------------------------------------------------------------
-- rpc_cancel_org_membership — cancel the org''s live subscription.
-- p_immediate = false (default): cancel at period end (keeps access until then).
-- p_immediate = true: terminate now (state 'canceled', access lost).
-- ------------------------------------------------------------
create or replace function public.rpc_cancel_org_membership(
    p_organization_id uuid,
    p_immediate       boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_sub_id uuid;
    v_row    jsonb;
begin
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    select id into v_sub_id
      from public.membership_subscription
     where organization_id = p_organization_id
       and state in ('trialing','active','grace','past_due')
     limit 1;
    if not found then
        raise exception 'NO_LIVE_SUBSCRIPTION: organization %', p_organization_id
            using errcode = 'P0002';
    end if;

    if p_immediate then
        update public.membership_subscription
           set state = 'canceled', cancel_at_period_end = false, next_billing_at = null
         where id = v_sub_id;
    else
        update public.membership_subscription
           set cancel_at_period_end = true
         where id = v_sub_id;
    end if;

    perform public.publish_platform_event(
        'membership.subscription.canceled', p_organization_id, v_sub_id,
        jsonb_build_object('immediate', p_immediate));
    if p_immediate then
        perform public.publish_platform_event(
            'entitlements.invalidated', p_organization_id, v_sub_id,
            jsonb_build_object('reason', 'subscription_canceled'));
    end if;

    select to_jsonb(s) into v_row
      from public.membership_subscription s where s.id = v_sub_id;
    return v_row;
end;
$$;
comment on function public.rpc_cancel_org_membership(uuid, boolean) is
    'ARS-205. Cancel the org''s live subscription — at period end (default) or
     immediately. Emits subscription.canceled (+entitlements.invalidated if immediate).';

-- ------------------------------------------------------------
-- Grants: web + AI Gateway (authenticated) may call; anon may not.
-- ------------------------------------------------------------
grant execute on function public.rpc_list_membership_plans()                to authenticated;
grant execute on function public.rpc_get_org_subscription(uuid)             to authenticated;
grant execute on function public.rpc_subscribe_org_membership(uuid, text)   to authenticated;
grant execute on function public.rpc_cancel_org_membership(uuid, boolean)   to authenticated;
revoke execute on function public.rpc_list_membership_plans()              from anon;
revoke execute on function public.rpc_get_org_subscription(uuid)           from anon;
revoke execute on function public.rpc_subscribe_org_membership(uuid, text) from anon;
revoke execute on function public.rpc_cancel_org_membership(uuid, boolean) from anon;

-- ------------------------------------------------------------
-- RPC name registry (D-NEW-A)
-- ------------------------------------------------------------
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('rpc_list_membership_plans',   null, 'list_membership_plans',   'd13_billing.sql', 'ARS-205 pricing catalog'),
    ('rpc_get_org_subscription',    null, 'get_org_subscription',    'd13_billing.sql', 'ARS-205 org live subscription'),
    ('rpc_subscribe_org_membership',null, 'subscribe_org_membership','d13_billing.sql', 'ARS-205 enroll + start trial'),
    ('rpc_cancel_org_membership',   null, 'cancel_org_membership',   'd13_billing.sql', 'ARS-205 cancel at period end / immediate'),
    ('fn_org_membership_active',    null, null,                      'd13_billing.sql', 'ARS-263 canonical membership-active predicate (subscription OR legacy level) — TSP gates + admin membership_paid')
on conflict (sql_name) do nothing;

-- ============================================================
-- Slice ARS-206 (renewal engine + payment abstraction)
-- A cron/service job rolls due subscriptions forward, charges via a payment
-- abstraction, and walks the failure ladder. Uses SKIP LOCKED (never advisory
-- locks — CLAUDE.md L-NEW-2) so parallel cron ticks don't double-charge.
--
-- Renewal FSM (state at period end, next_billing_at <= now):
--   cancel_at_period_end → expired            (no charge)
--   charge OK             → active, period rolled forward   [access ON]
--   charge FAIL:
--     trialing/active → grace     (retry in GRACE window)   [access ON]
--     grace           → past_due  (retry)                   [access OFF — d13]
--     past_due        → expired   (terminal)                [access OFF]
--
-- Events (Dok 4 D66) — FLAG (Architect): none registered in Dok 4 yet:
--   membership.subscription.renewed / .expired
--   membership.payment.succeeded / .failed
--   entitlements.invalidated  (on access loss/restore)
--
-- FLAG (ARS-206b, deferred per HS-4 — no speculative code): the real payment
-- provider + async webhook handler (rpc_membership_payment_webhook) are NOT
-- written here. fn_charge_membership is a synchronous stub that always succeeds
-- until a provider is chosen. When it lands, replace the stub body only (P7).
-- ============================================================

-- ------------------------------------------------------------
-- membership_payment — append-only audit of charge attempts (P12 temporal).
-- ------------------------------------------------------------
create table if not exists public.membership_payment (
    id              uuid    primary key default gen_random_uuid(),
    subscription_id uuid    not null references public.membership_subscription(id) on delete cascade,
    organization_id uuid    not null references public.organizations(id) on delete cascade,
    amount          numeric(12,2) not null check (amount >= 0),
    currency        text    not null default 'KZT',
    status          text    not null check (status in ('pending','succeeded','failed')),
    provider        text    not null default 'stub',
    provider_ref    text,
    created_at      timestamptz not null default now()
);
comment on table public.membership_payment is
    'ARS-206. Append-only log of membership charge attempts. provider=''stub''
     until a real provider lands (ARS-206b). One row per charge attempt.';

-- ARS-267: audit columns for admin-recorded manual payments (provider='manual').
-- `create table if not exists` is a no-op on prod → explicit idempotent ALTER (P7).
alter table public.membership_payment
    add column if not exists created_by uuid references public.users(id);
alter table public.membership_payment
    add column if not exists note text;
comment on column public.membership_payment.created_by is
    'ARS-267. User who recorded a manual payment (rpc_admin_record_manual_payment).
     null for engine/stub charges.';
comment on column public.membership_payment.note is
    'ARS-267. Mandatory justification for a manual payment (Kaspi transfer note etc.);
     null for engine charges.';

create index if not exists idx_membership_payment_sub
    on public.membership_payment (subscription_id, created_at desc);

alter table public.membership_payment enable row level security;
drop policy if exists "membership_payment_read_own" on public.membership_payment;
create policy "membership_payment_read_own"
    on public.membership_payment for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());
-- Writes only via SECURITY DEFINER engine (bypasses RLS) — no client insert policy.

-- ------------------------------------------------------------
-- fn_charge_membership — payment provider abstraction (STUB).
-- Logs a payment row and returns success. Replace body only when a real
-- provider is integrated (ARS-206b); signature stays (P7).
-- ------------------------------------------------------------
create or replace function public.fn_charge_membership(
    p_subscription_id uuid,
    p_organization_id uuid,
    p_amount          numeric,
    p_currency        text default 'KZT'
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ok boolean := true;   -- STUB: real provider decides this
begin
    insert into public.membership_payment
        (subscription_id, organization_id, amount, currency, status, provider)
    values
        (p_subscription_id, p_organization_id, p_amount, p_currency,
         case when v_ok then 'succeeded' else 'failed' end, 'stub');
    return v_ok;
end;
$$;
comment on function public.fn_charge_membership(uuid, uuid, numeric, text) is
    'ARS-206 STUB payment abstraction. Logs membership_payment + returns success.
     Replace body only when a real provider is integrated (ARS-206b). P7.';

-- Internal engine helper only: writes the membership_payment ledger with no ownership
-- guard, so it MUST be service_role-only. Revoke from PUBLIC (default grant) — not just anon.
revoke execute on function public.fn_charge_membership(uuid, uuid, numeric, text) from public;
revoke execute on function public.fn_charge_membership(uuid, uuid, numeric, text) from anon;
revoke execute on function public.fn_charge_membership(uuid, uuid, numeric, text) from authenticated;
grant  execute on function public.fn_charge_membership(uuid, uuid, numeric, text) to service_role;

-- ------------------------------------------------------------
-- rpc_process_membership_renewals — the cron/service engine.
-- Global job (no organization_id — whitelisted in cross_check CHECK 5).
-- Grant to service_role only; anon/authenticated revoked.
-- Returns a run summary: { processed, renewed, deferred, expired }.
-- ------------------------------------------------------------
create or replace function public.rpc_process_membership_renewals(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_grace_days integer;        -- ARS-264: read per-plan from membership_plan.grace_days (P8)
    rec          record;
    v_amount     numeric;
    v_paid       boolean;
    v_next_state text;
    v_new_end    timestamptz;
    v_processed  integer := 0;
    v_renewed    integer := 0;
    v_deferred   integer := 0;
    v_expired    integer := 0;
begin
    for rec in
        select s.id, s.organization_id, s.state, s.price_snapshot,
               s.current_period_end, s.cancel_at_period_end,
               mp.billing_period, mp.price_amount as plan_price, mp.currency,
               mp.grace_days
          from public.membership_subscription s
          join public.membership_plan mp on mp.plan_code = s.plan_code
         where s.next_billing_at is not null
           and s.next_billing_at <= now()
           and s.state in ('trialing','active','grace','past_due')
         order by s.next_billing_at
         limit p_limit
         for update of s skip locked
    loop
        v_processed := v_processed + 1;
        v_grace_days := coalesce(rec.grace_days, 3);   -- ARS-264: per-plan grace window (P8)

        -- Scheduled cancellation: terminate at period end, no charge.
        if rec.cancel_at_period_end then
            update public.membership_subscription
               set state = 'expired', next_billing_at = null
             where id = rec.id;
            perform public.publish_platform_event(
                'membership.subscription.expired', rec.organization_id, rec.id,
                jsonb_build_object('reason', 'canceled_at_period_end'));
            perform public.publish_platform_event(
                'entitlements.invalidated', rec.organization_id, rec.id,
                jsonb_build_object('reason', 'subscription_expired'));
            v_expired := v_expired + 1;
            continue;
        end if;

        v_amount := coalesce(rec.price_snapshot, rec.plan_price);
        v_paid   := public.fn_charge_membership(rec.id, rec.organization_id, v_amount, rec.currency);

        if v_paid then
            v_new_end := rec.current_period_end + rec.billing_period::interval;
            update public.membership_subscription
               set state = 'active',
                   current_period_start = rec.current_period_end,
                   current_period_end   = v_new_end,
                   next_billing_at      = v_new_end,
                   price_snapshot       = v_amount,
                   trial_end            = null
             where id = rec.id;
            perform public.publish_platform_event(
                'membership.payment.succeeded', rec.organization_id, rec.id,
                jsonb_build_object('amount', v_amount, 'currency', rec.currency));
            perform public.publish_platform_event(
                'membership.subscription.renewed', rec.organization_id, rec.id,
                jsonb_build_object('period_end', v_new_end));
            -- access was OFF in grace-fail states → restore
            if rec.state in ('past_due') then
                perform public.publish_platform_event(
                    'entitlements.invalidated', rec.organization_id, rec.id,
                    jsonb_build_object('reason', 'access_restored'));
            end if;
            v_renewed := v_renewed + 1;
        else
            v_next_state := case rec.state
                when 'grace'    then 'past_due'
                when 'past_due' then 'expired'
                else 'grace'    -- trialing / active
            end;
            perform public.publish_platform_event(
                'membership.payment.failed', rec.organization_id, rec.id,
                jsonb_build_object('amount', v_amount, 'from_state', rec.state));

            if v_next_state = 'expired' then
                update public.membership_subscription
                   set state = 'expired', next_billing_at = null
                 where id = rec.id;
                perform public.publish_platform_event(
                    'membership.subscription.expired', rec.organization_id, rec.id,
                    jsonb_build_object('reason', 'payment_failed'));
                perform public.publish_platform_event(
                    'entitlements.invalidated', rec.organization_id, rec.id,
                    jsonb_build_object('reason', 'subscription_expired'));
                v_expired := v_expired + 1;
            else
                update public.membership_subscription
                   set state = v_next_state,
                       next_billing_at = now() + make_interval(days => v_grace_days)
                 where id = rec.id;
                -- entering past_due loses access (d13 excludes it)
                if v_next_state = 'past_due' then
                    perform public.publish_platform_event(
                        'entitlements.invalidated', rec.organization_id, rec.id,
                        jsonb_build_object('reason', 'entered_past_due'));
                end if;
                v_deferred := v_deferred + 1;
            end if;
        end if;
    end loop;

    return jsonb_build_object(
        'processed', v_processed, 'renewed', v_renewed,
        'deferred', v_deferred, 'expired', v_expired);
end;
$$;
comment on function public.rpc_process_membership_renewals(integer) is
    'ARS-206/264. Cron/service renewal engine. SKIP LOCKED batch; charges via
     fn_charge_membership; rolls period on success, walks grace→past_due→expired
     ladder on failure (grace window = membership_plan.grace_days, per-plan, P8).
     Global job (no org param). service_role only. Armed by pg_cron job
     ''membership-renewals'' (staging-only migration; prod-enable = separate G3).';

-- Grants: engine is service-only; catalog for admins via dashboard (postgres).
-- Revoke from PUBLIC (default grant) — `from anon, authenticated` alone leaves PUBLIC execute.
revoke execute on function public.rpc_process_membership_renewals(integer) from public;
revoke execute on function public.rpc_process_membership_renewals(integer) from anon, authenticated;
grant execute on function public.rpc_process_membership_renewals(integer) to service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_process_membership_renewals', null, null, 'd13_billing.sql',
        'ARS-206 cron renewal engine (SKIP LOCKED); service_role only; global job')
on conflict (sql_name) do nothing;

-- ============================================================
-- Slice ARS-207 (admin plan constructor — write side of the P8 catalog)
-- TURAN admins fill the membership_plan catalog from the console without a
-- deploy (P8: standards as data). billing_period stays fixed to {1,3,12} months
-- (CEO, ARS-202) — enforced by the table CHECK; the RPC surfaces a clean error.
-- All admin-gated via fn_is_admin(); no org scope (global catalog).
-- ============================================================

-- ------------------------------------------------------------
-- rpc_admin_list_membership_plans — full catalog incl. inactive rows, all
-- fields, for the admin constructor table. Admin-only.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_list_membership_plans()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_rows jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;

    select coalesce(jsonb_agg(p order by p.is_active desc, p.price_amount), '[]'::jsonb)
      into v_rows
      from (
        select id, plan_code, title, billing_period, price_amount, currency,
               trial_days, applies_org_type, grants_tier, version, is_active,
               created_at, updated_at
        from public.membership_plan
      ) p;
    return v_rows;
end;
$$;
comment on function public.rpc_admin_list_membership_plans() is
    'ARS-207. Full membership_plan catalog (incl. inactive) for the admin
     constructor. Admin only.';

-- ------------------------------------------------------------
-- rpc_admin_upsert_membership_plan — create or update a plan by plan_code.
-- On update: bumps version + updated_at (existing subscriptions keep their
-- price_snapshot, so live subs are unaffected — P7 additive). Admin-only.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_upsert_membership_plan(
    p_plan_code        text,
    p_title            text,
    p_billing_period   text,
    p_price_amount     numeric,
    p_trial_days       integer default 30,
    p_grants_tier      text    default 'standard',
    p_applies_org_type text    default null,
    p_currency         text    default 'KZT'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_row jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;

    if coalesce(trim(p_plan_code), '') = '' then
        raise exception 'PLAN_CODE_REQUIRED' using errcode = '22023';
    end if;
    if coalesce(trim(p_title), '') = '' then
        raise exception 'TITLE_REQUIRED' using errcode = '22023';
    end if;
    -- CEO constraint (ARS-202): only 1/3/12-month periods. Clean error before
    -- the table CHECK fires with a cryptic message.
    if p_billing_period not in ('1 month', '3 months', '12 months') then
        raise exception 'BAD_BILLING_PERIOD: % (allowed: 1 month, 3 months, 12 months)',
            p_billing_period using errcode = '22023';
    end if;

    insert into public.membership_plan
        (plan_code, title, billing_period, price_amount, currency,
         trial_days, applies_org_type, grants_tier)
    values
        (p_plan_code, p_title, p_billing_period, p_price_amount, coalesce(p_currency, 'KZT'),
         coalesce(p_trial_days, 30), p_applies_org_type, coalesce(p_grants_tier, 'standard'))
    on conflict (plan_code) do update
        set title            = excluded.title,
            billing_period   = excluded.billing_period,
            price_amount     = excluded.price_amount,
            currency         = excluded.currency,
            trial_days       = excluded.trial_days,
            applies_org_type = excluded.applies_org_type,
            grants_tier      = excluded.grants_tier,
            version          = public.membership_plan.version + 1,
            updated_at       = now();

    select to_jsonb(mp) into v_row
      from public.membership_plan mp where mp.plan_code = p_plan_code;
    return v_row;
end;
$$;
comment on function public.rpc_admin_upsert_membership_plan(text, text, text, numeric, integer, text, text, text) is
    'ARS-207. Create/update a membership plan (by plan_code) from the admin
     constructor. Bumps version on update. Admin only. Live subs keep their
     price_snapshot (P7 additive).';

-- ------------------------------------------------------------
-- rpc_admin_set_membership_plan_active — retire/restore a plan (soft, P7).
-- Inactive plans drop out of the public catalog but keep serving live subs.
-- Admin-only.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_set_membership_plan_active(
    p_plan_code text,
    p_is_active  boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_row jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;

    update public.membership_plan
       set is_active  = p_is_active,
           updated_at = now()
     where plan_code = p_plan_code;
    if not found then
        raise exception 'PLAN_NOT_FOUND: %', p_plan_code using errcode = 'P0002';
    end if;

    select to_jsonb(mp) into v_row
      from public.membership_plan mp where mp.plan_code = p_plan_code;
    return v_row;
end;
$$;
comment on function public.rpc_admin_set_membership_plan_active(text, boolean) is
    'ARS-207. Soft retire/restore a membership plan. Inactive plans leave the
     public catalog but keep serving live subs (P7). Admin only.';

-- Grants: admin funcs — authenticated may call, fn_is_admin() gate inside; anon may not.
grant execute on function public.rpc_admin_list_membership_plans()                                       to authenticated;
grant execute on function public.rpc_admin_upsert_membership_plan(text, text, text, numeric, integer, text, text, text) to authenticated;
grant execute on function public.rpc_admin_set_membership_plan_active(text, boolean)                     to authenticated;
revoke execute on function public.rpc_admin_list_membership_plans()                                      from anon;
revoke execute on function public.rpc_admin_upsert_membership_plan(text, text, text, numeric, integer, text, text, text) from anon;
revoke execute on function public.rpc_admin_set_membership_plan_active(text, boolean)                    from anon;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('rpc_admin_list_membership_plans',    null, null, 'd13_billing.sql', 'ARS-207 admin plan constructor — full catalog'),
    ('rpc_admin_upsert_membership_plan',   null, null, 'd13_billing.sql', 'ARS-207 admin plan constructor — create/update'),
    ('rpc_admin_set_membership_plan_active',null, null, 'd13_billing.sql', 'ARS-207 admin plan constructor — retire/restore')
on conflict (sql_name) do nothing;

-- ============================================================
-- Slice ARS-266 / BILL-A1 (admin read-RPCs — subscriptions ops foundation)
-- Read-only backbone of the admin «управление подписками» screen (eng-spec §2.1).
-- Before this, the admin had NO way to see subscriptions or payments — only the
-- plan catalog. All three: SECURITY DEFINER, fn_is_admin() guard inside, global
-- admin scope (no per-caller org filter — admin sees all orgs by design).
-- ACL (eng-spec §2, SEC-GRANT-PUBLIC-01): revoke from public AND anon, then grant
-- authenticated (guard inside) + service_role. `revoke from anon` alone leaves
-- PUBLIC execute — both revokes are required.
-- Global admin scope → whitelisted in cross_check CHECK 5 (organization_id) — the
-- two org-less RPCs added there consciously (eng-spec §7).
-- ============================================================

-- ------------------------------------------------------------
-- rpc_admin_list_subscriptions — paginated, filterable subscription list with
-- per-state counters. Filters: state / plan_code / free-text search over org
-- legal_name + БИН. Sort next_billing_at asc nulls last (soonest-to-bill first),
-- then created_at desc as a stable tiebreak. counts_by_state ignores p_state (so
-- the state chips stay meaningful while one state is selected); total reflects the
-- full filter (state+plan+search) for pagination.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_list_subscriptions(
    p_state     text default null,
    p_plan_code text default null,
    p_search    text default null,
    p_limit     integer default 50,
    p_offset    integer default 0
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_search text    := nullif(btrim(coalesce(p_search, '')), '');
    v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 200);
    v_offset integer := greatest(coalesce(p_offset, 0), 0);
    v_counts jsonb;
    v_total  integer;
    v_rows   jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;

    with base as (
        select s.*,
               o.legal_name as org_name,
               o.bin_iin    as org_bin,
               mp.title     as plan_title
          from public.membership_subscription s
          join public.organizations o  on o.id = s.organization_id
          join public.membership_plan mp on mp.plan_code = s.plan_code
         where (p_plan_code is null or s.plan_code = p_plan_code)
           and (v_search is null
                or o.legal_name ilike '%' || v_search || '%'
                or o.bin_iin    ilike '%' || v_search || '%')
    )
    select
        (select jsonb_build_object(
                    'trialing', count(*) filter (where state = 'trialing'),
                    'active',   count(*) filter (where state = 'active'),
                    'grace',    count(*) filter (where state = 'grace'),
                    'past_due', count(*) filter (where state = 'past_due'),
                    'expired',  count(*) filter (where state = 'expired'),
                    'canceled', count(*) filter (where state = 'canceled'))
           from base),
        (select count(*) from base where (p_state is null or state = p_state)),
        (select coalesce(jsonb_agg(row_json order by ord_nbf asc nulls last, ord_created desc), '[]'::jsonb)
           from (
                select to_jsonb(b) || jsonb_build_object(
                           'last_payment_at',
                           (select max(pay.created_at)
                              from public.membership_payment pay
                             where pay.subscription_id = b.id)) as row_json,
                       b.next_billing_at as ord_nbf,
                       b.created_at      as ord_created
                  from base b
                 where (p_state is null or b.state = p_state)
                 order by b.next_billing_at asc nulls last, b.created_at desc
                 limit v_limit offset v_offset
           ) page)
      into v_counts, v_total, v_rows;

    return jsonb_build_object('total', v_total, 'counts_by_state', v_counts, 'rows', v_rows);
end;
$$;
comment on function public.rpc_admin_list_subscriptions(text, text, text, integer, integer) is
    'ARS-266. Admin subscription list: filters (state/plan/search over org name+БИН),
     counts_by_state (ignores state filter), total (full filter), rows enriched with
     org_name/org_bin/plan_title/last_payment_at. Sort next_billing_at asc nulls last.
     Global admin scope; fn_is_admin() guard.';

-- ------------------------------------------------------------
-- rpc_admin_get_subscription — one subscription card: the sub row, its plan, the
-- org identity, the legacy membership level, last 20 payment attempts and last 20
-- platform_events for this subscription (entity_id = subscription id).
-- membership_level resolves to the linked memberships row (subscription.membership_id);
-- if unlinked, falls back to the org's most-significant membership (non-registered
-- preferred, then most recently changed) — mirrors the bridge-predicate intent.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_get_subscription(p_subscription_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_sub   public.membership_subscription%rowtype;
    v_plan  jsonb;
    v_org   jsonb;
    v_level text;
    v_pay   jsonb;
    v_ev    jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;

    select * into v_sub
      from public.membership_subscription
     where id = p_subscription_id;
    if not found then
        raise exception 'SUBSCRIPTION_NOT_FOUND: %', p_subscription_id using errcode = 'P0002';
    end if;

    select to_jsonb(mp) into v_plan
      from public.membership_plan mp where mp.plan_code = v_sub.plan_code;

    select jsonb_build_object('id', o.id, 'name', o.legal_name, 'bin', o.bin_iin)
      into v_org
      from public.organizations o where o.id = v_sub.organization_id;

    -- linked membership row first; else org's most-significant membership
    select level into v_level
      from public.memberships where id = v_sub.membership_id;
    if v_level is null then
        select level into v_level
          from public.memberships
         where organization_id = v_sub.organization_id
         order by (level <> 'registered') desc, level_changed_at desc
         limit 1;
    end if;

    select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb)
      into v_pay
      from (
        select * from public.membership_payment
         where subscription_id = p_subscription_id
         order by created_at desc
         limit 20
      ) p;

    select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc), '[]'::jsonb)
      into v_ev
      from (
        select * from public.platform_events
         where entity_id = p_subscription_id
         order by created_at desc
         limit 20
      ) e;

    return jsonb_build_object(
        'subscription',     to_jsonb(v_sub),
        'plan',             coalesce(v_plan, 'null'::jsonb),
        'organization',     coalesce(v_org, 'null'::jsonb),
        'membership_level', to_jsonb(v_level),
        'payments',         v_pay,
        'events',           v_ev);
end;
$$;
comment on function public.rpc_admin_get_subscription(uuid) is
    'ARS-266. Admin subscription card: subscription + plan + organization{id,name,bin}
     + membership_level (legacy) + last 20 payments + last 20 platform_events
     (entity_id = subscription). Global admin scope; fn_is_admin() guard.';

-- ------------------------------------------------------------
-- rpc_admin_list_membership_payments — the payments ledger with a succeeded-sum
-- footer. Filters: org / status / date range [from,to]. sum_succeeded sums
-- status='succeeded' over the org+date filter, IGNORING the status filter (stable
-- "money in" footer regardless of the status chip). total reflects the full filter
-- (incl. status) for pagination. Rows enriched with org_name + plan_code.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_list_membership_payments(
    p_organization_id uuid        default null,
    p_status          text        default null,
    p_from            timestamptz default null,
    p_to              timestamptz default null,
    p_limit           integer     default 50,
    p_offset          integer     default 0
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 200);
    v_offset integer := greatest(coalesce(p_offset, 0), 0);
    v_total  integer;
    v_sum    numeric;
    v_rows   jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;

    with base as (
        select pay.*,
               o.legal_name as org_name,
               s.plan_code  as plan_code
          from public.membership_payment pay
          join public.organizations o on o.id = pay.organization_id
          left join public.membership_subscription s on s.id = pay.subscription_id
         where (p_organization_id is null or pay.organization_id = p_organization_id)
           and (p_from is null or pay.created_at >= p_from)
           and (p_to   is null or pay.created_at <= p_to)
    )
    select
        (select count(*) from base where (p_status is null or status = p_status)),
        (select coalesce(sum(amount), 0) from base where status = 'succeeded'),
        (select coalesce(jsonb_agg(row_json order by ord_created desc), '[]'::jsonb)
           from (
                select to_jsonb(b) as row_json, b.created_at as ord_created
                  from base b
                 where (p_status is null or b.status = p_status)
                 order by b.created_at desc
                 limit v_limit offset v_offset
           ) page)
      into v_total, v_sum, v_rows;

    return jsonb_build_object('total', v_total, 'sum_succeeded', v_sum, 'rows', v_rows);
end;
$$;
comment on function public.rpc_admin_list_membership_payments(uuid, text, timestamptz, timestamptz, integer, integer) is
    'ARS-266. Admin payments ledger: filters (org/status/date range), sum_succeeded
     (succeeded over org+date filter, ignores status chip), total (full filter),
     rows enriched with org_name + plan_code. Global admin scope; fn_is_admin() guard.';

-- ------------------------------------------------------------
-- Grants (eng-spec §2): revoke from public AND anon (SEC-GRANT-PUBLIC-01 —
-- `revoke from anon` alone leaves PUBLIC execute); grant authenticated (guard
-- inside) + service_role.
-- ------------------------------------------------------------
revoke execute on function public.rpc_admin_list_subscriptions(text, text, text, integer, integer)                       from public, anon;
revoke execute on function public.rpc_admin_get_subscription(uuid)                                                       from public, anon;
revoke execute on function public.rpc_admin_list_membership_payments(uuid, text, timestamptz, timestamptz, integer, integer) from public, anon;
grant  execute on function public.rpc_admin_list_subscriptions(text, text, text, integer, integer)                       to authenticated, service_role;
grant  execute on function public.rpc_admin_get_subscription(uuid)                                                       to authenticated, service_role;
grant  execute on function public.rpc_admin_list_membership_payments(uuid, text, timestamptz, timestamptz, integer, integer) to authenticated, service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('rpc_admin_list_subscriptions',        null, null, 'd13_billing.sql', 'ARS-266 admin subscriptions list + filters + counts_by_state'),
    ('rpc_admin_get_subscription',          null, null, 'd13_billing.sql', 'ARS-266 admin subscription card + payments + events'),
    ('rpc_admin_list_membership_payments',  null, null, 'd13_billing.sql', 'ARS-266 admin membership payments ledger + sum_succeeded')
on conflict (sql_name) do nothing;

-- ============================================================
-- Slice ARS-267 (admin subscription write-ops + cabinet resume)
-- Management operations for the TURAN admin (eng-spec §2.2) + cabinet resume.
-- Every op leaves a trail (ledger row and/or platform_event). All SECURITY
-- DEFINER, guard inside, ACL `revoke from public, anon` + grant authenticated
-- (guard inside) + service_role (SEC-GRANT-PUBLIC-01). Existing signatures
-- untouched (P7); additive columns only (created_by/note/revoke_reason above).
--
-- CEO decisions (2026-07-16): D-BILL-MANUAL-01 (manual payment in pilot),
-- D-BILL-REVOKE-01 (disciplinary `revoked` state in pilot).
--
-- Events (Dok 4): membership.subscription.{extended,plan_changed,resumed,revoked}
-- + reuse membership.payment.succeeded / .renewed / entitlements.invalidated.
-- ============================================================

-- ------------------------------------------------------------
-- rpc_admin_record_manual_payment — MS2 authority "Billing / manual admin
-- confirm", NOT a silent admin-override: p_reference + p_note are mandatory and
-- land in the append-only ledger. Mirrors the renewal-engine success branch —
-- rolls the period forward (base = max(current_period_end, now)) and sets state
-- 'active'. price_snapshot is NOT overwritten with the manual amount (future
-- auto-renewals stay on the plan-locked price). Terminal subs (canceled/revoked)
-- are rejected — resubscribe instead.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_record_manual_payment(
    p_subscription_id uuid,
    p_amount          numeric,
    p_reference       text,
    p_note            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_sub        public.membership_subscription%rowtype;
    v_plan       public.membership_plan%rowtype;
    v_prev_state text;
    v_base       timestamptz;
    v_new_end    timestamptz;
    v_currency   text;
    v_row        jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;
    if nullif(btrim(coalesce(p_reference, '')), '') is null then
        raise exception 'REFERENCE_REQUIRED: manual payment needs a receipt/reference'
            using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_note, '')), '') is null then
        raise exception 'NOTE_REQUIRED: manual payment needs a justification note'
            using errcode = '22023';
    end if;
    if p_amount is null or p_amount < 0 then
        raise exception 'INVALID_AMOUNT: %', p_amount using errcode = '22023';
    end if;

    select * into v_sub
      from public.membership_subscription
     where id = p_subscription_id
     for update;
    if not found then
        raise exception 'SUBSCRIPTION_NOT_FOUND: %', p_subscription_id using errcode = 'P0002';
    end if;
    if v_sub.state in ('canceled', 'revoked') then
        raise exception 'SUBSCRIPTION_TERMINAL: cannot record payment on % subscription (resubscribe instead)',
            v_sub.state using errcode = '22023';
    end if;

    select * into v_plan from public.membership_plan where plan_code = v_sub.plan_code;
    v_currency   := coalesce(v_plan.currency, 'KZT');
    v_prev_state := v_sub.state;

    -- roll the period forward (mirror renewal success branch)
    v_base    := greatest(coalesce(v_sub.current_period_end, now()), now());
    v_new_end := v_base + v_plan.billing_period::interval;

    -- ledger row FIRST — append-only audit with mandatory reference + note (P8-audit)
    insert into public.membership_payment
        (subscription_id, organization_id, amount, currency, status,
         provider, provider_ref, created_by, note)
    values
        (v_sub.id, v_sub.organization_id, p_amount, v_currency,
         'succeeded', 'manual', p_reference, public.fn_current_user_id(), p_note);

    update public.membership_subscription
       set state                = 'active',
           current_period_start = v_base,
           current_period_end   = v_new_end,
           next_billing_at      = v_new_end,
           trial_end            = null
     where id = v_sub.id;

    perform public.publish_platform_event(
        'membership.payment.succeeded', v_sub.organization_id, v_sub.id,
        jsonb_build_object('amount', p_amount, 'currency', v_currency,
                           'provider', 'manual', 'reference', p_reference));
    perform public.publish_platform_event(
        'membership.subscription.renewed', v_sub.organization_id, v_sub.id,
        jsonb_build_object('period_end', v_new_end, 'source', 'manual_admin'));
    -- access was OFF in past_due/expired → restored
    if v_prev_state in ('past_due', 'expired') then
        perform public.publish_platform_event(
            'entitlements.invalidated', v_sub.organization_id, v_sub.id,
            jsonb_build_object('reason', 'access_restored'));
    end if;

    select to_jsonb(s) into v_row from public.membership_subscription s where s.id = v_sub.id;
    return v_row;
end;
$$;
comment on function public.rpc_admin_record_manual_payment(uuid, numeric, text, text) is
    'ARS-267. Admin records a manual (e.g. Kaspi transfer) membership payment.
     Mandatory reference+note; writes membership_payment(provider=''manual'',succeeded,
     created_by,note); rolls the period forward (state→active). Restores access from
     past_due/expired. Emits payment.succeeded(manual)+renewed(+entitlements.invalidated).
     Rejects canceled/revoked subs. fn_is_admin() guard.';

-- ------------------------------------------------------------
-- rpc_admin_extend_subscription — comp/goodwill gesture: add p_days (1..90) to the
-- period. Reactivates from grace/past_due/expired (deliberate admin power — no
-- charge). Mandatory note. Rejects canceled/revoked.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_extend_subscription(
    p_subscription_id uuid,
    p_days            integer,
    p_note            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_sub        public.membership_subscription%rowtype;
    v_prev_state text;
    v_new_end    timestamptz;
    v_new_next   timestamptz;
    v_new_state  text;
    v_row        jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;
    if p_days is null or p_days < 1 or p_days > 90 then
        raise exception 'INVALID_DAYS: must be 1..90, got %', p_days using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_note, '')), '') is null then
        raise exception 'NOTE_REQUIRED: extension needs a justification note'
            using errcode = '22023';
    end if;

    select * into v_sub
      from public.membership_subscription
     where id = p_subscription_id
     for update;
    if not found then
        raise exception 'SUBSCRIPTION_NOT_FOUND: %', p_subscription_id using errcode = 'P0002';
    end if;
    if v_sub.state in ('canceled', 'revoked') then
        raise exception 'SUBSCRIPTION_TERMINAL: cannot extend % subscription', v_sub.state
            using errcode = '22023';
    end if;

    v_prev_state := v_sub.state;
    v_new_end    := coalesce(v_sub.current_period_end, now()) + make_interval(days => p_days);
    -- keep the billing cadence shifted; for reactivated (expired) subs next_billing was
    -- null → arm it to the new period end so the engine picks it up again.
    v_new_next   := coalesce(v_sub.next_billing_at + make_interval(days => p_days), v_new_end);
    v_new_state  := case when v_sub.state in ('grace', 'past_due', 'expired')
                         then 'active' else v_sub.state end;

    update public.membership_subscription
       set state              = v_new_state,
           current_period_end = v_new_end,
           next_billing_at    = v_new_next
     where id = v_sub.id;

    perform public.publish_platform_event(
        'membership.subscription.extended', v_sub.organization_id, v_sub.id,
        jsonb_build_object('days', p_days, 'note', p_note, 'period_end', v_new_end));
    if v_prev_state in ('past_due', 'expired') then
        perform public.publish_platform_event(
            'entitlements.invalidated', v_sub.organization_id, v_sub.id,
            jsonb_build_object('reason', 'access_restored'));
    end if;

    select to_jsonb(s) into v_row from public.membership_subscription s where s.id = v_sub.id;
    return v_row;
end;
$$;
comment on function public.rpc_admin_extend_subscription(uuid, integer, text) is
    'ARS-267. Admin comp/goodwill: extend the period by 1..90 days (mandatory note).
     Reactivates grace/past_due/expired → active without charge. Emits
     subscription.extended (+entitlements.invalidated if access restored).';

-- ------------------------------------------------------------
-- rpc_admin_change_subscription_plan — switch the plan effective NEXT period.
-- price_snapshot is NOT touched now: re-tariffing happens in the renewal engine
-- at the next roll (snapshot := new plan price). No immediate charge/refund —
-- simple and legally clean. Live subs only.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_change_subscription_plan(
    p_subscription_id uuid,
    p_new_plan_code   text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_sub  public.membership_subscription%rowtype;
    v_plan public.membership_plan%rowtype;
    v_old  text;
    v_row  jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;

    select * into v_plan
      from public.membership_plan
     where plan_code = p_new_plan_code and is_active = true;
    if not found then
        raise exception 'PLAN_NOT_FOUND: % (or inactive)', p_new_plan_code using errcode = 'P0002';
    end if;

    select * into v_sub
      from public.membership_subscription
     where id = p_subscription_id
     for update;
    if not found then
        raise exception 'SUBSCRIPTION_NOT_FOUND: %', p_subscription_id using errcode = 'P0002';
    end if;
    if v_sub.state not in ('trialing', 'active', 'grace', 'past_due') then
        raise exception 'SUBSCRIPTION_NOT_LIVE: cannot change plan on % subscription', v_sub.state
            using errcode = '22023';
    end if;
    if v_sub.plan_code = p_new_plan_code then
        raise exception 'PLAN_UNCHANGED: already on plan %', p_new_plan_code using errcode = '22023';
    end if;

    v_old := v_sub.plan_code;
    update public.membership_subscription
       set plan_code = p_new_plan_code
     where id = v_sub.id;

    perform public.publish_platform_event(
        'membership.subscription.plan_changed', v_sub.organization_id, v_sub.id,
        jsonb_build_object('from_plan', v_old, 'to_plan', p_new_plan_code,
                           'effective', 'next_period'));

    select to_jsonb(s) into v_row from public.membership_subscription s where s.id = v_sub.id;
    return v_row;
end;
$$;
comment on function public.rpc_admin_change_subscription_plan(uuid, text) is
    'ARS-267. Change the subscription plan effective next period (price_snapshot
     untouched — re-tariffed by the renewal engine at next roll; no immediate
     charge/refund). Live subs only. Emits subscription.plan_changed.';

-- ------------------------------------------------------------
-- rpc_resume_org_membership — undo a scheduled cancellation (cancel_at_period_end
-- → false) on the org's live subscription. Guard: member-or-admin (symmetric to
-- rpc_cancel_org_membership, S3). Called from both admin and the cabinet (ARS-261).
-- Idempotent: no error if the flag is already false.
-- ------------------------------------------------------------
create or replace function public.rpc_resume_org_membership(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_sub_id uuid;
    v_was    boolean;
    v_row    jsonb;
begin
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    select id, cancel_at_period_end into v_sub_id, v_was
      from public.membership_subscription
     where organization_id = p_organization_id
       and state in ('trialing', 'active', 'grace', 'past_due')
     limit 1;
    if v_sub_id is null then
        raise exception 'NO_LIVE_SUBSCRIPTION: organization %', p_organization_id
            using errcode = 'P0002';
    end if;

    update public.membership_subscription
       set cancel_at_period_end = false
     where id = v_sub_id;

    perform public.publish_platform_event(
        'membership.subscription.resumed', p_organization_id, v_sub_id,
        jsonb_build_object('was_scheduled_for_cancellation', v_was));

    select to_jsonb(s) into v_row from public.membership_subscription s where s.id = v_sub_id;
    return v_row;
end;
$$;
comment on function public.rpc_resume_org_membership(uuid) is
    'ARS-267. Undo a scheduled cancellation (cancel_at_period_end→false) on the org''s
     live subscription. Member-or-admin (symmetric to cancel). Idempotent. Called from
     admin + cabinet (ARS-261). Emits subscription.resumed.';

-- ------------------------------------------------------------
-- rpc_admin_revoke_membership — disciplinary terminal revoke (MS2 D-MEM-5,
-- CEO D-BILL-REVOKE-01). Distinct from voluntary cancel: state→'revoked' (terminal),
-- non-recurrent — the org needs a new subscription/application to return (revoked is
-- outside uq_membership_subscription_live, so re-subscribe is allowed). Mandatory
-- reason. Admin-only. Access is lost immediately.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_revoke_membership(
    p_organization_id uuid,
    p_reason          text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_sub_id uuid;
    v_row    jsonb;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = '42501';
    end if;
    if nullif(btrim(coalesce(p_reason, '')), '') is null then
        raise exception 'REASON_REQUIRED: disciplinary revoke needs a reason'
            using errcode = '22023';
    end if;

    select id into v_sub_id
      from public.membership_subscription
     where organization_id = p_organization_id
       and state in ('trialing', 'active', 'grace', 'past_due')
     limit 1;
    if v_sub_id is null then
        raise exception 'NO_LIVE_SUBSCRIPTION: organization %', p_organization_id
            using errcode = 'P0002';
    end if;

    update public.membership_subscription
       set state                = 'revoked',
           cancel_at_period_end = false,
           next_billing_at      = null,
           revoke_reason        = p_reason
     where id = v_sub_id;

    perform public.publish_platform_event(
        'membership.subscription.revoked', p_organization_id, v_sub_id,
        jsonb_build_object('reason', p_reason));
    perform public.publish_platform_event(
        'entitlements.invalidated', p_organization_id, v_sub_id,
        jsonb_build_object('reason', 'membership_revoked'));

    select to_jsonb(s) into v_row from public.membership_subscription s where s.id = v_sub_id;
    return v_row;
end;
$$;
comment on function public.rpc_admin_revoke_membership(uuid, text) is
    'ARS-267. Disciplinary terminal revoke (MS2 D-MEM-5): state→''revoked'', clears
     next_billing, records revoke_reason. Non-recurrent (re-subscribe allowed since
     revoked is outside the live-unique index). Mandatory reason. Admin-only.
     Emits subscription.revoked + entitlements.invalidated.';

-- ------------------------------------------------------------
-- Grants (eng-spec §2): revoke from public AND anon (SEC-GRANT-PUBLIC-01);
-- grant authenticated (guard inside) + service_role.
-- ------------------------------------------------------------
revoke execute on function public.rpc_admin_record_manual_payment(uuid, numeric, text, text) from public, anon;
revoke execute on function public.rpc_admin_extend_subscription(uuid, integer, text)          from public, anon;
revoke execute on function public.rpc_admin_change_subscription_plan(uuid, text)              from public, anon;
revoke execute on function public.rpc_resume_org_membership(uuid)                             from public, anon;
revoke execute on function public.rpc_admin_revoke_membership(uuid, text)                     from public, anon;
grant  execute on function public.rpc_admin_record_manual_payment(uuid, numeric, text, text) to authenticated, service_role;
grant  execute on function public.rpc_admin_extend_subscription(uuid, integer, text)          to authenticated, service_role;
grant  execute on function public.rpc_admin_change_subscription_plan(uuid, text)              to authenticated, service_role;
grant  execute on function public.rpc_resume_org_membership(uuid)                             to authenticated, service_role;
grant  execute on function public.rpc_admin_revoke_membership(uuid, text)                     to authenticated, service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('rpc_admin_record_manual_payment',    null, null, 'd13_billing.sql', 'ARS-267 admin manual payment (provider=manual) + roll period'),
    ('rpc_admin_extend_subscription',      null, null, 'd13_billing.sql', 'ARS-267 admin comp extend 1..90 days + reactivate'),
    ('rpc_admin_change_subscription_plan', null, null, 'd13_billing.sql', 'ARS-267 admin change plan effective next period'),
    ('rpc_resume_org_membership',          null, null, 'd13_billing.sql', 'ARS-267 undo scheduled cancellation (member-or-admin; cabinet ARS-261)'),
    ('rpc_admin_revoke_membership',        null, null, 'd13_billing.sql', 'ARS-267 disciplinary terminal revoke (MS2 D-MEM-5)')
on conflict (sql_name) do nothing;
