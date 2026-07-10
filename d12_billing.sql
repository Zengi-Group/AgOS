-- ============================================================
-- d12_billing.sql — Membership Billing (recurrent org subscription)
-- ============================================================
-- Domain: AssociationMembership made recurrent/paid.
-- Canon: Feature ARS-202 (G2 closed 2026-07-10), Microstep 2 (Membership FSM).
-- Depends on: d01_kernel.sql (organizations, memberships, users, helpers,
--             fn_my_org_ids, fn_is_admin, fn_set_updated_at).
-- Apply order: d01 → … → d11 → d12.
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
    version         integer not null default 1,
    is_active       boolean not null default true,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.membership_plan is
    'ARS-203. P8 reference catalog of org membership plans. billing_period fixed to
     1/3/12 months (CEO, ARS-202). Admin fills price + trial + grants_tier via constructor,
     no deploy. grants_tier feeds the org-membership axis of Feature Governance (d13).';

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
                        check (state in ('trialing', 'active', 'grace', 'past_due', 'expired', 'canceled')),
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
