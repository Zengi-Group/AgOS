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
    ('rpc_list_membership_plans',   null, 'list_membership_plans',   'd12_billing.sql', 'ARS-205 pricing catalog'),
    ('rpc_get_org_subscription',    null, 'get_org_subscription',    'd12_billing.sql', 'ARS-205 org live subscription'),
    ('rpc_subscribe_org_membership',null, 'subscribe_org_membership','d12_billing.sql', 'ARS-205 enroll + start trial'),
    ('rpc_cancel_org_membership',   null, 'cancel_org_membership',   'd12_billing.sql', 'ARS-205 cancel at period end / immediate')
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
    v_grace_days integer := 3;   -- FLAG (ARS-206): grace window; make configurable later
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
               mp.billing_period, mp.price_amount as plan_price, mp.currency
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
    'ARS-206. Cron/service renewal engine. SKIP LOCKED batch; charges via
     fn_charge_membership; rolls period on success, walks grace→past_due→expired
     ladder on failure. Global job (no org param). service_role only.';

-- Grants: engine is service-only; catalog for admins via dashboard (postgres).
revoke execute on function public.rpc_process_membership_renewals(integer) from anon, authenticated;
grant execute on function public.rpc_process_membership_renewals(integer) to service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_process_membership_renewals', null, null, 'd12_billing.sql',
        'ARS-206 cron renewal engine (SKIP LOCKED); service_role only; global job')
on conflict (sql_name) do nothing;
