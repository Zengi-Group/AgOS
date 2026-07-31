-- AgOS · ARS-360 · Canonical deal-review convergence.
--
-- The legacy TSP clients retain their RPC signatures and JSON response shapes, but
-- every new review write lands in deal_reviews + deal_review_dimension_scores.
-- batches.notes.review and batches.notes.mpk_review are read-only migration inputs
-- and temporary fallback sources only; this migration deliberately never dual-writes
-- them.
--
-- Preconditions:
--   * ARS-352 review ACL/RLS hardening is present (this migration reasserts the
--     minimum grants below so it remains safe on drifted environments).
--   * The migration runner executes this file transactionally. The backfill helper
--     holds a write lock on batches while it snapshots legacy note values and the
--     adapters are rebound.
--
-- Split-batch safety:
--   deal_reviews is batch-scoped, not allocation-scoped. Therefore an MPK review is
--   only safe while a batch has exactly one distinct delivered MPK counterparty.
--   Ambiguous legacy notes are quarantined for reconciliation instead of guessed.

-- -----------------------------------------------------------------------------
-- 0. Keep canonical review tables on an explicit least-privilege Data API surface.
-- -----------------------------------------------------------------------------

alter table public.deal_reviews enable row level security;
alter table public.deal_review_dimension_scores enable row level security;

-- RLS policies cannot safely self-join deal_reviews without recursion. This narrow
-- SECURITY DEFINER predicate answers only whether the current caller owns a revealed
-- review in an exact, fully revealed farmer/MPK pair; it exposes no review data.
create or replace function public.fn_ars_360_can_read_revealed_deal_review(p_batch_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    return p_batch_id is not null
       and exists (
            select 1
            from public.deal_reviews dr
            where dr.batch_id = p_batch_id
              and dr.reviewer_org_id = any(
                  coalesce(public.fn_my_org_ids(), '{}'::uuid[])
              )
              and dr.visible_at is not null
              and dr.visible_at <= now()
       )
       and public.fn_ars_360_is_exact_current_deal_review_pair(p_batch_id, true);
end;
$$;

comment on function public.fn_ars_360_can_read_revealed_deal_review(uuid) is
    'ARS-360 RLS predicate: true only when the JWT caller owns a review in an exact,
     fully revealed farmer/MPK pair in the batch.';

revoke all on function public.fn_ars_360_can_read_revealed_deal_review(uuid)
    from public, anon, authenticated, service_role;
grant execute on function public.fn_ars_360_can_read_revealed_deal_review(uuid)
    to authenticated, service_role;

drop policy if exists deal_reviews_read on public.deal_reviews;
create policy deal_reviews_read
    on public.deal_reviews
    for select
    to authenticated
    using (
        reviewer_org_id = any(
            coalesce(public.fn_my_org_ids(), '{}'::uuid[])
        )
        or (
            visible_at is not null
            and visible_at <= now()
            and public.fn_ars_360_can_read_revealed_deal_review(batch_id)
        )
    );

drop policy if exists deal_review_dimension_scores_read
    on public.deal_review_dimension_scores;
create policy deal_review_dimension_scores_read
    on public.deal_review_dimension_scores
    for select
    to authenticated
    using (
        exists (
            select 1
            from public.deal_reviews dr
            where dr.id = deal_review_id
              and (
                    dr.reviewer_org_id = any(
                        coalesce(public.fn_my_org_ids(), '{}'::uuid[])
                    )
                    or (
                        dr.visible_at is not null
                        and dr.visible_at <= now()
                        and public.fn_ars_360_can_read_revealed_deal_review(dr.batch_id)
                    )
              )
        )
    );

revoke all on table public.deal_reviews
    from public, anon, authenticated, service_role;
revoke all on table public.deal_review_dimension_scores
    from public, anon, authenticated, service_role;
grant select on table public.deal_reviews to authenticated;
grant select on table public.deal_review_dimension_scores to authenticated;
grant select, insert, update, delete on table public.deal_reviews to service_role;
grant select, insert, update, delete on table public.deal_review_dimension_scores
    to service_role;

-- A review's score rows are part of the submitted canonical fact, not editable
-- metadata. Scores may be inserted only before their parent is revealed; all
-- updates/deletes are rejected so service-side maintenance cannot rewrite history.
create or replace function public.fn_ars_360_guard_deal_review_dimension_score_immutability()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if tg_op <> 'INSERT' then
        raise exception 'REVIEW_IMMUTABLE' using errcode = 'P0001';
    end if;

    if exists (
        select 1
        from public.deal_reviews dr
        where dr.id = new.deal_review_id
          and dr.visible_at is not null
    ) then
        raise exception 'REVIEW_IMMUTABLE_AFTER_REVEAL' using errcode = 'P0001';
    end if;

    return new;
end;
$$;

drop trigger if exists trg_ars_360_deal_review_dimension_score_immutability
    on public.deal_review_dimension_scores;
create trigger trg_ars_360_deal_review_dimension_score_immutability
    before insert or update or delete on public.deal_review_dimension_scores
    for each row execute function public.fn_ars_360_guard_deal_review_dimension_score_immutability();

revoke all on function public.fn_ars_360_guard_deal_review_dimension_score_immutability()
    from public, anon, authenticated, service_role;

-- Dimensions are reference data. Browser callers may use active definitions to
-- render review inputs, but must not be able to alter the canonical taxonomy.
alter table public.review_dimensions enable row level security;
drop policy if exists review_dimensions_read_active on public.review_dimensions;
create policy review_dimensions_read_active
    on public.review_dimensions
    for select
    to authenticated
    using (is_active);
revoke all on table public.review_dimensions
    from public, anon, authenticated, service_role;
grant select on table public.review_dimensions to authenticated;
grant select, insert, update, delete on table public.review_dimensions
    to service_role;

-- -----------------------------------------------------------------------------
-- 1. Durable, private reconciliation evidence for legacy values that cannot be
--    attributed safely. It is not a review read-model or a product-facing source.
-- -----------------------------------------------------------------------------

create table if not exists public.deal_review_legacy_reconciliation (
    id                              uuid primary key default gen_random_uuid(),
    batch_id                        uuid not null references public.batches(id)
                                    on delete restrict,
    legacy_key                      text not null
                                    check (legacy_key in ('review', 'mpk_review')),
    reason_code                     text not null
                                    check (reason_code in (
                                        'invalid_payload',
                                        'invalid_rating',
                                        'batch_not_delivered',
                                        'unknown_dimension',
                                        'no_delivered_mpk_counterparty',
                                        'ambiguous_mpk_counterparty',
                                        'review_already_revealed'
                                    )),
    raw_payload                     jsonb not null,
    candidate_counterparty_org_ids  uuid[] not null default '{}'::uuid[],
    status                          text not null default 'pending'
                                    check (status in ('pending', 'resolved')),
    resolution_code                 text,
    observed_at                     timestamptz not null default now(),
    last_observed_at                timestamptz not null default now(),
    resolved_at                     timestamptz,
    unique (batch_id, legacy_key),
    constraint deal_review_legacy_reconciliation_resolution_check check (
        (status = 'pending' and resolution_code is null and resolved_at is null)
        or
        (status = 'resolved' and resolution_code = 'canonical_present'
            and resolved_at is not null)
    )
);

comment on table public.deal_review_legacy_reconciliation is
    'ARS-360 private reconciliation/audit queue for legacy batches.notes review values
     that cannot be attributed to the canonical double-blind deal review model. It is
     not a product review source; no browser role can read or mutate it.';

create index if not exists idx_deal_review_legacy_reconciliation_pending
    on public.deal_review_legacy_reconciliation (observed_at, batch_id)
    where status = 'pending';

alter table public.deal_review_legacy_reconciliation enable row level security;
revoke all on table public.deal_review_legacy_reconciliation
    from public, anon, authenticated, service_role;
grant select on table public.deal_review_legacy_reconciliation to service_role;

-- -----------------------------------------------------------------------------
-- 2. Internal helpers. Both are intentionally non-client-executable.
-- -----------------------------------------------------------------------------

-- Prefer delivered chunk ownership whenever allocations exist. The pool-line route
-- is a deterministic compatibility fallback only for pre-Slice-9 batches that have
-- no allocations at all.
create or replace function public.fn_ars_360_mpk_counterparty_ids(p_batch_id uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    with allocation_state as (
        select
            count(*)::int as allocation_count,
            coalesce(
                array_agg(distinct p.organization_id order by p.organization_id)
                    filter (where a.status = 'delivered' and p.organization_id is not null),
                '{}'::uuid[]
            ) as delivered_org_ids
        from public.batch_allocations a
        join public.pools p on p.id = a.pool_id
        where a.batch_id = p_batch_id
    ), legacy_pool_line as (
        select p.organization_id
        from public.batches b
        left join public.pool_lines pl on pl.id = b.pool_line_id
        left join public.pools p on p.id = pl.pool_id
        where b.id = p_batch_id
    )
    select coalesce(
        (
            select case
                when s.allocation_count > 0 then s.delivered_org_ids
                when l.organization_id is not null then array[l.organization_id]::uuid[]
                else '{}'::uuid[]
            end
            from allocation_state s
            cross join legacy_pool_line l
        ),
        '{}'::uuid[]
    );
$$;

comment on function public.fn_ars_360_mpk_counterparty_ids(uuid) is
    'ARS-360 internal resolver. Returns distinct delivered MPK organization IDs for a
     batch; falls back to batch.pool_line only when no allocation rows exist.';

revoke all on function public.fn_ars_360_mpk_counterparty_ids(uuid)
    from public, anon, authenticated, service_role;

-- One shared attribution invariant for reveal, direct RLS and reputation. The
-- reviewer identities must still match the batch farmer and current singleton
-- delivered MPK; a historic pair is never trusted merely because its roles count 1+1.
create or replace function public.fn_ars_360_is_exact_current_deal_review_pair(
    p_batch_id uuid,
    p_require_visible boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select p_batch_id is not null
       and exists (
            select 1
            from public.deal_reviews dr
            join public.batches b on b.id = dr.batch_id
            cross join lateral (
                select public.fn_ars_360_mpk_counterparty_ids(dr.batch_id)
                    as counterparty_org_ids
            ) counterparty
            where dr.batch_id = p_batch_id
              and cardinality(counterparty.counterparty_org_ids) = 1
            group by dr.batch_id, b.organization_id, counterparty.counterparty_org_ids
            having count(*) = 2
               and count(*) filter (
                   where dr.reviewer_role = 'farmer'
                     and dr.reviewer_org_id = b.organization_id
               ) = 1
               and count(*) filter (
                   where dr.reviewer_role = 'mpk'
                     and dr.reviewer_org_id = counterparty.counterparty_org_ids[1]
               ) = 1
               and (
                   not p_require_visible
                   or count(*) filter (where dr.visible_at is not null) = 2
               )
       );
$$;

comment on function public.fn_ars_360_is_exact_current_deal_review_pair(uuid, boolean) is
    'ARS-360 internal attribution invariant: exact batch farmer/current singleton delivered
     MPK pair, optionally fully revealed. Used to fail closed on historic or split drift.';

revoke all on function public.fn_ars_360_is_exact_current_deal_review_pair(uuid, boolean)
    from public, anon, authenticated, service_role;

-- A submitted review is immutable. New rows must begin hidden, and no row may be
-- added after a batch has been revealed. The only permitted update is the one-time
-- double-blind transition visible_at: NULL -> timestamp, performed by the canonical
-- transaction after it has verified an exact farmer/MPK pair.
create or replace function public.fn_ars_360_guard_deal_review_immutability()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if tg_op = 'INSERT' then
        if new.visible_at is not null then
            raise exception 'REVIEW_REVEAL_REQUIRES_MUTUAL_PAIR' using errcode = 'P0001';
        end if;
        if exists (
            select 1
            from public.deal_reviews dr
            where dr.batch_id = new.batch_id
              and dr.visible_at is not null
        ) then
            raise exception 'REVIEW_IMMUTABLE_AFTER_REVEAL' using errcode = 'P0001';
        end if;
        return new;
    end if;

    if tg_op = 'DELETE' then
        raise exception 'REVIEW_IMMUTABLE' using errcode = 'P0001';
    end if;

    if old.visible_at is not null then
        raise exception 'REVIEW_IMMUTABLE_AFTER_REVEAL' using errcode = 'P0001';
    end if;

    if new.id is distinct from old.id
       or new.batch_id is distinct from old.batch_id
       or new.reviewer_org_id is distinct from old.reviewer_org_id
       or new.reviewer_role is distinct from old.reviewer_role
       or new.overall_score is distinct from old.overall_score
       or new.comment is distinct from old.comment
       or new.submitted_at is distinct from old.submitted_at
       or new.created_at is distinct from old.created_at
       or new.visible_at is null then
        raise exception 'REVIEW_IMMUTABLE' using errcode = 'P0001';
    end if;

    if not public.fn_ars_360_is_exact_current_deal_review_pair(new.batch_id, false) then
        raise exception 'REVIEW_REVEAL_REQUIRES_MUTUAL_PAIR' using errcode = 'P0001';
    end if;

    return new;
end;
$$;

drop trigger if exists trg_ars_360_deal_review_immutability on public.deal_reviews;
create trigger trg_ars_360_deal_review_immutability
    before insert or update or delete on public.deal_reviews
    for each row execute function public.fn_ars_360_guard_deal_review_immutability();

revoke all on function public.fn_ars_360_guard_deal_review_immutability()
    from public, anon, authenticated, service_role;

-- A row trigger alone cannot prove that a direct UPDATE revealed both rows. This
-- deferred pair invariant rejects any committed half-reveal while permitting the
-- canonical single-statement update that changes both exact-pair rows together.
create or replace function public.fn_ars_360_enforce_revealed_deal_review_pair()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch_id uuid;
begin
    if tg_op = 'DELETE' then
        v_batch_id := old.batch_id;
    else
        v_batch_id := new.batch_id;
    end if;

    if exists (
        select 1
        from public.deal_reviews dr
        where dr.batch_id = v_batch_id
          and dr.visible_at is not null
    ) and not public.fn_ars_360_is_exact_current_deal_review_pair(v_batch_id, true) then
        raise exception 'REVIEW_REVEAL_REQUIRES_MUTUAL_PAIR' using errcode = 'P0001';
    end if;

    return null;
end;
$$;

drop trigger if exists trg_ars_360_revealed_deal_review_pair on public.deal_reviews;
create constraint trigger trg_ars_360_revealed_deal_review_pair
    after insert or update or delete on public.deal_reviews
    deferrable initially deferred
    for each row execute function public.fn_ars_360_enforce_revealed_deal_review_pair();

revoke all on function public.fn_ars_360_enforce_revealed_deal_review_pair()
    from public, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. Canonical review transaction. Locking the batch row serializes two concurrent
--    submissions, so the second transaction performs the reveal atomically.
-- -----------------------------------------------------------------------------

create or replace function public.rpc_submit_deal_review(
    p_organization_id   uuid,
    p_batch_id          uuid,
    p_overall_score     int,
    p_dimension_id      uuid,
    p_dimension_score   int,
    p_comment           text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch                   public.batches%rowtype;
    v_mpk_counterparty_org_ids uuid[];
    v_reviewer_role           text;
    v_review_id               uuid;
    v_can_reveal              boolean := false;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not coalesce(p_organization_id = any(public.fn_my_org_ids()), false) then
        raise exception 'FORBIDDEN: caller is not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;
    if p_overall_score is null or p_overall_score not between 1 and 5 then
        raise exception 'INVALID_SCORE: overall_score must be between 1 and 5'
            using errcode = 'P0001';
    end if;
    if p_dimension_score is null or p_dimension_score not between 1 and 5 then
        raise exception 'INVALID_SCORE: dimension_score must be between 1 and 5'
            using errcode = 'P0001';
    end if;
    if p_dimension_id is null then
        raise exception 'INVALID_INPUT: p_dimension_id required' using errcode = 'P0001';
    end if;

    select b.*
      into v_batch
    from public.batches b
    where b.id = p_batch_id
    for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_batch.status <> 'delivered' then
        raise exception 'INVALID_STATUS: reviews only from delivered (current %)',
            v_batch.status using errcode = 'P0001';
    end if;

    v_mpk_counterparty_org_ids := public.fn_ars_360_mpk_counterparty_ids(p_batch_id);

    -- Reviews are batch-scoped rather than allocation-scoped, so neither role can
    -- safely submit until the batch resolves to exactly one delivered MPK.
    if cardinality(v_mpk_counterparty_org_ids) = 0 then
        raise exception 'NO_DELIVERED_MPK_COUNTERPARTY' using errcode = 'P0001';
    end if;
    if cardinality(v_mpk_counterparty_org_ids) <> 1 then
        raise exception
            'AMBIGUOUS_MPK_COUNTERPARTY: allocation-scoped review model required for batch %',
            p_batch_id using errcode = 'P0001';
    end if;

    if v_batch.organization_id = p_organization_id then
        v_reviewer_role := 'farmer';
    elsif p_organization_id = v_mpk_counterparty_org_ids[1] then
        v_reviewer_role := 'mpk';
    else
        raise exception 'FORBIDDEN: organization is not a party to this batch'
            using errcode = '42501';
    end if;

    if not exists (
        select 1
        from public.review_dimensions d
        where d.id = p_dimension_id
          and d.is_active
          and d.applicable_role in (v_reviewer_role, 'both')
    ) then
        raise exception 'UNKNOWN_OR_INAPPLICABLE_DIMENSION: %', p_dimension_id
            using errcode = 'P0001';
    end if;

    if exists (
        select 1
        from public.deal_reviews dr
        where dr.batch_id = p_batch_id
          and dr.reviewer_org_id = p_organization_id
    ) then
        raise exception 'REVIEW_ALREADY_SUBMITTED' using errcode = 'P0001';
    end if;

    if exists (
        select 1
        from public.deal_reviews dr
        where dr.batch_id = p_batch_id
          and dr.visible_at is not null
    ) then
        raise exception 'REVIEW_IMMUTABLE_AFTER_REVEAL' using errcode = 'P0001';
    end if;

    insert into public.deal_reviews (
        batch_id, reviewer_org_id, reviewer_role, overall_score, comment
    ) values (
        p_batch_id, p_organization_id, v_reviewer_role, p_overall_score, p_comment
    )
    returning id into v_review_id;

    insert into public.deal_review_dimension_scores (
        deal_review_id, dimension_id, score
    ) values (
        v_review_id, p_dimension_id, p_dimension_score
    );

    -- Exact pair only: a batch with several MPKs cannot safely use batch-wide
    -- visibility until a future allocation-scoped review model exists.
    select count(*) = 2
       and count(*) filter (where reviewer_role = 'farmer') = 1
       and count(*) filter (where reviewer_role = 'mpk') = 1
      into v_can_reveal
    from public.deal_reviews
    where batch_id = p_batch_id;

    if v_can_reveal then
        update public.deal_reviews
           set visible_at = now()
         where batch_id = p_batch_id
           and visible_at is null;
    end if;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.review.submitted', 'deal_reviews', v_review_id, p_organization_id,
        case v_reviewer_role when 'farmer' then 'farmer' else 'admin' end,
        public.fn_current_user_id(),
        jsonb_build_object(
            'batch_id', p_batch_id,
            'reviewer_role', v_reviewer_role,
            'overall_score', p_overall_score,
            'mutual_revealed', v_can_reveal
        ),
        true
    );

    return v_review_id;
end;
$$;

comment on function public.rpc_submit_deal_review(uuid, uuid, int, uuid, int, text) is
    'ARS-360 / D-M6-11 / D-M6-12: canonical immutable mutual review. Authenticated
     caller must belong to the supplied party organization. Batch-row locking makes
     the second eligible submission reveal the exact farmer/MPK pair atomically.';

revoke execute on function public.rpc_submit_deal_review(uuid, uuid, int, uuid, int, text)
    from public, anon;
grant execute on function public.rpc_submit_deal_review(uuid, uuid, int, uuid, int, text)
    to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Rerunnable, service-only legacy backfill. It is called once by this migration
--    and kept private so transaction-wrapped DB contract tests can prove its
--    idempotence on fresh fixtures.
-- -----------------------------------------------------------------------------

create or replace function public.fn_backfill_legacy_deal_reviews()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_weight_dimension_id    uuid;
    v_livestock_dimension_id uuid;
    v_farmer_backfilled      int := 0;
    v_mpk_backfilled         int := 0;
    v_revealed               int := 0;
    v_pending                int := 0;
begin
    -- Pause old notes writers for the bounded migration/backfill window. This lock
    -- is transaction-scoped and is held until the adapters below are rebound.
    lock table public.batches in share row exclusive mode;

    select id into v_weight_dimension_id
    from public.review_dimensions
    where code = 'weight_accuracy' and is_active and applicable_role = 'farmer'
    limit 1;

    select id into v_livestock_dimension_id
    from public.review_dimensions
    where code = 'livestock_condition' and is_active and applicable_role = 'mpk'
    limit 1;

    -- Farmer notes that cannot be safely copied are retained in a private queue.
    with source as (
        select
            b.id as batch_id,
            b.organization_id as reviewer_org_id,
            b.status,
            meta -> 'review' as raw_payload,
            public.fn_ars_360_mpk_counterparty_ids(b.id) as candidate_counterparty_org_ids,
            case when (meta -> 'review' ->> 'r1') ~ '^[1-5]$'
                 then (meta -> 'review' ->> 'r1')::int end as r1,
            case when (meta -> 'review' ->> 'r2') ~ '^[1-5]$'
                 then (meta -> 'review' ->> 'r2')::int end as r2
        from public.batches b
        cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
        where meta ? 'review'
    ), classified as (
        select s.*, case
            when jsonb_typeof(raw_payload) <> 'object' then 'invalid_payload'
            when r1 is null or r2 is null then 'invalid_rating'
            when status <> 'delivered' then 'batch_not_delivered'
            when v_weight_dimension_id is null then 'unknown_dimension'
            when cardinality(candidate_counterparty_org_ids) = 0
                then 'no_delivered_mpk_counterparty'
            when cardinality(candidate_counterparty_org_ids) <> 1
                then 'ambiguous_mpk_counterparty'
            when exists (
                select 1
                from public.deal_reviews dr
                where dr.batch_id = s.batch_id
                  and dr.visible_at is not null
            ) and not exists (
                select 1
                from public.deal_reviews dr
                where dr.batch_id = s.batch_id
                  and dr.reviewer_org_id = s.reviewer_org_id
                  and dr.reviewer_role = 'farmer'
            ) then 'review_already_revealed'
        end as reason_code
        from source s
        where not exists (
            select 1
            from public.deal_reviews dr
            where dr.batch_id = s.batch_id
              and dr.reviewer_org_id = s.reviewer_org_id
              and dr.reviewer_role = 'farmer'
        )
    )
    insert into public.deal_review_legacy_reconciliation (
        batch_id, legacy_key, reason_code, raw_payload, candidate_counterparty_org_ids
    )
    select batch_id, 'review', reason_code, raw_payload, candidate_counterparty_org_ids
    from classified
    where reason_code is not null
    on conflict (batch_id, legacy_key) do update
       set reason_code = excluded.reason_code,
           raw_payload = excluded.raw_payload,
           candidate_counterparty_org_ids = excluded.candidate_counterparty_org_ids,
           status = 'pending',
           resolution_code = null,
           resolved_at = null,
           last_observed_at = now();

    -- Valid farmer notes become one canonical review with the named pilot dimension.
    with source as (
        select
            b.id as batch_id,
            b.organization_id as reviewer_org_id,
            b.status,
            meta -> 'review' as raw_payload,
            public.fn_ars_360_mpk_counterparty_ids(b.id) as candidate_counterparty_org_ids,
            case when (meta -> 'review' ->> 'r1') ~ '^[1-5]$'
                 then (meta -> 'review' ->> 'r1')::int end as r1,
            case when (meta -> 'review' ->> 'r2') ~ '^[1-5]$'
                 then (meta -> 'review' ->> 'r2')::int end as r2
        from public.batches b
        cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
        where meta ? 'review'
    ), candidates as (
        select s.*
        from source s
        where s.status = 'delivered'
          and v_weight_dimension_id is not null
          and jsonb_typeof(s.raw_payload) = 'object'
          and s.r1 is not null and s.r2 is not null
          and cardinality(s.candidate_counterparty_org_ids) = 1
          and not exists (
              select 1
              from public.deal_reviews dr
              where dr.batch_id = s.batch_id
                and dr.visible_at is not null
          )
    ), inserted_reviews as (
        insert into public.deal_reviews (
            batch_id, reviewer_org_id, reviewer_role, overall_score, comment
        )
        select batch_id, reviewer_org_id, 'farmer', r1, coalesce(raw_payload ->> 'comment', '')
        from candidates
        on conflict (batch_id, reviewer_org_id) do nothing
        returning id, batch_id
    ), inserted_scores as (
        insert into public.deal_review_dimension_scores (deal_review_id, dimension_id, score)
        select ir.id, v_weight_dimension_id, c.r2
        from inserted_reviews ir
        join candidates c using (batch_id)
        on conflict (deal_review_id, dimension_id) do nothing
        returning id
    )
    select count(*)::int into v_farmer_backfilled from inserted_reviews;

    -- MPK notes are only attributable when there is exactly one delivered MPK.
    with source as (
        select
            b.id as batch_id,
            b.status,
            meta -> 'mpk_review' as raw_payload,
            public.fn_ars_360_mpk_counterparty_ids(b.id) as candidate_counterparty_org_ids,
            case when (meta -> 'mpk_review' ->> 'r1') ~ '^[1-5]$'
                 then (meta -> 'mpk_review' ->> 'r1')::int end as r1,
            case when (meta -> 'mpk_review' ->> 'r2') ~ '^[1-5]$'
                 then (meta -> 'mpk_review' ->> 'r2')::int end as r2
        from public.batches b
        cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
        where meta ? 'mpk_review'
    ), classified as (
        select s.*, case
            when jsonb_typeof(raw_payload) <> 'object' then 'invalid_payload'
            when r1 is null or r2 is null then 'invalid_rating'
            when status <> 'delivered' then 'batch_not_delivered'
            when v_livestock_dimension_id is null then 'unknown_dimension'
            when cardinality(candidate_counterparty_org_ids) = 0
                then 'no_delivered_mpk_counterparty'
            when cardinality(candidate_counterparty_org_ids) <> 1
                then 'ambiguous_mpk_counterparty'
            when exists (
                select 1
                from public.deal_reviews dr
                where dr.batch_id = s.batch_id
                  and dr.visible_at is not null
            ) and not exists (
                select 1
                from public.deal_reviews dr
                where dr.batch_id = s.batch_id
                  and dr.reviewer_org_id = s.candidate_counterparty_org_ids[1]
                  and dr.reviewer_role = 'mpk'
            ) then 'review_already_revealed'
        end as reason_code
        from source s
        where not (
            cardinality(s.candidate_counterparty_org_ids) = 1
            and exists (
                select 1
                from public.deal_reviews dr
                where dr.batch_id = s.batch_id
                  and dr.reviewer_org_id = s.candidate_counterparty_org_ids[1]
                  and dr.reviewer_role = 'mpk'
            )
        )
    )
    insert into public.deal_review_legacy_reconciliation (
        batch_id, legacy_key, reason_code, raw_payload, candidate_counterparty_org_ids
    )
    select batch_id, 'mpk_review', reason_code, raw_payload, candidate_counterparty_org_ids
    from classified
    where reason_code is not null
    on conflict (batch_id, legacy_key) do update
       set reason_code = excluded.reason_code,
           raw_payload = excluded.raw_payload,
           candidate_counterparty_org_ids = excluded.candidate_counterparty_org_ids,
           status = 'pending',
           resolution_code = null,
           resolved_at = null,
           last_observed_at = now();

    with source as (
        select
            b.id as batch_id,
            b.status,
            meta -> 'mpk_review' as raw_payload,
            public.fn_ars_360_mpk_counterparty_ids(b.id) as candidate_counterparty_org_ids,
            case when (meta -> 'mpk_review' ->> 'r1') ~ '^[1-5]$'
                 then (meta -> 'mpk_review' ->> 'r1')::int end as r1,
            case when (meta -> 'mpk_review' ->> 'r2') ~ '^[1-5]$'
                 then (meta -> 'mpk_review' ->> 'r2')::int end as r2
        from public.batches b
        cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
        where meta ? 'mpk_review'
    ), candidates as (
        select s.*
        from source s
        where s.status = 'delivered'
          and v_livestock_dimension_id is not null
          and jsonb_typeof(s.raw_payload) = 'object'
          and s.r1 is not null and s.r2 is not null
          and cardinality(s.candidate_counterparty_org_ids) = 1
          and not exists (
              select 1
              from public.deal_reviews dr
              where dr.batch_id = s.batch_id
                and dr.visible_at is not null
          )
    ), inserted_reviews as (
        insert into public.deal_reviews (
            batch_id, reviewer_org_id, reviewer_role, overall_score, comment
        )
        select batch_id, candidate_counterparty_org_ids[1], 'mpk', r1,
               coalesce(raw_payload ->> 'comment', '')
        from candidates
        on conflict (batch_id, reviewer_org_id) do nothing
        returning id, batch_id
    ), inserted_scores as (
        insert into public.deal_review_dimension_scores (deal_review_id, dimension_id, score)
        select ir.id, v_livestock_dimension_id, c.r2
        from inserted_reviews ir
        join candidates c using (batch_id)
        on conflict (deal_review_id, dimension_id) do nothing
        returning id
    )
    select count(*)::int into v_mpk_backfilled from inserted_reviews;

    -- A canonical row wins. If a previously queued legacy value is now superseded by
    -- a canonical row, retain its audit evidence but mark it resolved.
    update public.deal_review_legacy_reconciliation q
       set status = 'resolved',
           resolution_code = 'canonical_present',
           resolved_at = coalesce(q.resolved_at, now()),
           last_observed_at = now()
      from public.batches b
     where q.batch_id = b.id
       and q.status = 'pending'
       and (
            (q.legacy_key = 'review' and exists (
                select 1 from public.deal_reviews dr
                where dr.batch_id = q.batch_id
                  and dr.reviewer_org_id = b.organization_id
                  and dr.reviewer_role = 'farmer'
            ))
            or
            (q.legacy_key = 'mpk_review' and exists (
                select 1 from public.deal_reviews dr
                where dr.batch_id = q.batch_id
                  and dr.reviewer_role = 'mpk'
                  and dr.reviewer_org_id = any(q.candidate_counterparty_org_ids)
            ))
       );

    -- Backfill never widens visibility beyond an exact canonical farmer/MPK pair
    -- whose current delivered allocation resolver still identifies that same MPK.
    with scoped_reviews as (
        select dr.*, b.organization_id as farmer_org_id,
               counterparty.counterparty_org_ids
        from public.deal_reviews dr
        join public.batches b on b.id = dr.batch_id
        cross join lateral (
            select public.fn_ars_360_mpk_counterparty_ids(dr.batch_id)
                as counterparty_org_ids
        ) counterparty
        where cardinality(counterparty.counterparty_org_ids) = 1
    ), exact_pairs as (
        select batch_id
        from scoped_reviews
        group by batch_id, farmer_org_id, counterparty_org_ids
        having count(*) = 2
           and count(*) filter (
               where reviewer_role = 'farmer'
                 and reviewer_org_id = farmer_org_id
           ) = 1
           and count(*) filter (
               where reviewer_role = 'mpk'
                 and reviewer_org_id = counterparty_org_ids[1]
           ) = 1
    )
    update public.deal_reviews dr
       set visible_at = now()
      from exact_pairs p
     where dr.batch_id = p.batch_id
       and dr.visible_at is null;
    get diagnostics v_revealed = row_count;

    select count(*)::int into v_pending
    from public.deal_review_legacy_reconciliation
    where status = 'pending';

    return jsonb_build_object(
        'farmer_backfilled', v_farmer_backfilled,
        'mpk_backfilled', v_mpk_backfilled,
        'revealed', v_revealed,
        'pending_reconciliation', v_pending
    );
end;
$$;

comment on function public.fn_backfill_legacy_deal_reviews() is
    'ARS-360 private, rerunnable migration helper. Backfills valid legacy review
     notes into the canonical review tables and quarantines all unsafe values.';

revoke all on function public.fn_backfill_legacy_deal_reviews()
    from public, anon, authenticated, service_role;
grant execute on function public.fn_backfill_legacy_deal_reviews() to service_role;

-- The initial migration run is intentionally before adapter rebinding. With the
-- batches lock held by the surrounding migration transaction, no old notes writer
-- can race this snapshot.
select public.fn_backfill_legacy_deal_reviews();

-- -----------------------------------------------------------------------------
-- 5. Compatibility writers: preserve signatures/boolean responses; route only to
--    the canonical transaction. No batches.notes mutation remains here.
-- -----------------------------------------------------------------------------

create or replace function public.rpc_submit_review(
    p_batch_id uuid,
    p_r1 int,
    p_r2 int,
    p_comment text default ''
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_farmer_org_id uuid;
    v_dimension_id  uuid;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;

    select organization_id into v_farmer_org_id
    from public.batches
    where id = p_batch_id;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;

    select id into v_dimension_id
    from public.review_dimensions
    where code = 'weight_accuracy' and is_active and applicable_role = 'farmer'
    limit 1;
    if v_dimension_id is null then
        raise exception 'UNKNOWN_DIMENSION: weight_accuracy' using errcode = 'P0001';
    end if;

    perform public.rpc_submit_deal_review(
        v_farmer_org_id, p_batch_id, p_r1, v_dimension_id, p_r2, p_comment
    );
    return true;
end;
$$;

comment on function public.rpc_submit_review(uuid, int, int, text) is
    'ARS-360 legacy farmer adapter. Signature/boolean response preserved; r1 maps to
     overall_score and r2 to weight_accuracy in canonical deal review storage.';

revoke execute on function public.rpc_submit_review(uuid, int, int, text)
    from public, anon;
grant execute on function public.rpc_submit_review(uuid, int, int, text)
    to authenticated, service_role;

create or replace function public.rpc_self_submit_mpk_review(
    p_batch_id uuid,
    p_r1 int,
    p_r2 int,
    p_comment text default ''
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_mpk_counterparty_org_ids uuid[];
    v_dimension_id             uuid;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;

    v_mpk_counterparty_org_ids := public.fn_ars_360_mpk_counterparty_ids(p_batch_id);
    if cardinality(v_mpk_counterparty_org_ids) = 0 then
        raise exception 'NO_DELIVERED_MPK_COUNTERPARTY' using errcode = 'P0001';
    end if;
    if cardinality(v_mpk_counterparty_org_ids) <> 1 then
        raise exception
            'AMBIGUOUS_MPK_COUNTERPARTY: allocation-scoped review model required for batch %',
            p_batch_id using errcode = 'P0001';
    end if;
    if not coalesce(v_mpk_counterparty_org_ids[1] = any(public.fn_my_org_ids()), false) then
        raise exception 'FORBIDDEN: caller does not own delivered batch allocation'
            using errcode = '42501';
    end if;

    select id into v_dimension_id
    from public.review_dimensions
    where code = 'livestock_condition' and is_active and applicable_role = 'mpk'
    limit 1;
    if v_dimension_id is null then
        raise exception 'UNKNOWN_DIMENSION: livestock_condition' using errcode = 'P0001';
    end if;

    perform public.rpc_submit_deal_review(
        v_mpk_counterparty_org_ids[1], p_batch_id, p_r1, v_dimension_id, p_r2, p_comment
    );
    return true;
end;
$$;

comment on function public.rpc_self_submit_mpk_review(uuid, int, int, text) is
    'ARS-360 legacy MPK adapter. Signature/boolean response preserved; r1 maps to
     overall_score and r2 to livestock_condition in canonical storage. Split batches
     with several delivered MPKs are rejected until reviews become allocation-scoped.';

revoke execute on function public.rpc_self_submit_mpk_review(uuid, int, int, text)
    from public, anon;
grant execute on function public.rpc_self_submit_mpk_review(uuid, int, int, text)
    to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. Compatibility reads. They project canonical rows first, with a side-effect-free
--    notes fallback only when no canonical row exists and the legacy payload is valid.
-- -----------------------------------------------------------------------------

create or replace function public.fn_tsp_batch_json(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v jsonb;
begin
    select jsonb_build_object(
        'id',         b.id,
        'cat',        public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
        'grade',      public.fn_tsp_batch_grade(b.id),
        'breed',      coalesce(meta->>'breed', ''),
        'heads',      b.heads,
        'avgWeight',  b.avg_weight_kg,
        'age',        coalesce((meta->>'age')::int, 0),
        'fatness',    coalesce(meta->>'fatness', ''),
        'district',   coalesce(meta->>'district', coalesce(r.name_ru, '')),
        'price',      coalesce(b.farmer_price_per_kg, public.fn_tsp_ref_price(b.tsp_sku_id, b.region_id)),
        'dealPrice',  b.deal_price_per_kg,
        'matchedHeads',   coalesce(b.matched_heads, 0),
        'remainingHeads', greatest(b.heads - coalesce(b.matched_heads, 0), 0),
        'allocations', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'heads',        a.heads,
                       'price',        a.price_per_kg,
                       'status',       a.status,
                       'buyer',        case when pa.mpk_contact_revealed_at is not null then oa.legal_name else null end,
                       'buyerPhone',   case when pa.mpk_contact_revealed_at is not null then oa.phone     else null end,
                       'matchedAt',    a.matched_at,
                       'confirmedAt',  a.confirmed_at,
                       'dispatchedAt', a.dispatched_at,
                       'deliveredAt',  a.delivered_at
                   ) order by a.matched_at)
            from public.batch_allocations a
            join public.pools pa         on pa.id = a.pool_id
            join public.organizations oa on oa.id = pa.organization_id
            where a.batch_id = b.id and a.status <> 'cancelled'
        ), '[]'::jsonb),
        'buyer',      case when po.mpk_contact_revealed_at is not null then bo.legal_name else null end,
        'buyerPhone', case when po.mpk_contact_revealed_at is not null then bo.phone     else null end,
        'review',     case
            when coalesce(b.organization_id = any(public.fn_my_org_ids()), false) then
                coalesce(
                    canonical_review.review,
                    case
                        when jsonb_typeof(meta->'review') = 'object'
                         and (meta->'review'->>'r1') ~ '^[1-5]$'
                         and (meta->'review'->>'r2') ~ '^[1-5]$'
                            then meta->'review'
                    end
                )
        end,
        'state',      case
                          when b.status = 'draft' and coalesce(meta->>'scheduled','false') = 'true' then 'scheduled'
                          when b.status = 'draft'                   then 'draft'
                          when b.status = 'published'               then 'published'
                          when b.status = 'offering'                then 'offering'
                          when b.status = 'awaiting_price_decision' then 'decision'
                          when b.status = 'partially_matched'       then 'partial'
                          when b.status = 'matched'                 then 'matched'
                          when b.status = 'confirmed'               then 'confirmed'
                          when b.status = 'dispatched'              then 'dispatched'
                          when b.status = 'delivered'               then 'delivered'
                          when b.status in ('cancelled','failed','expired') then 'cancelled'
                          else b.status
                      end,
        'windowLabel',
            case when meta ? 'wf' and meta ? 'wt'
                 then to_char((meta->>'wf')::date, 'DD Mon') || ' — ' || to_char((meta->>'wt')::date, 'DD Mon')
                 else to_char(b.target_month, 'TMMonth YYYY') end,
        'publishAtLabel', null,
        'deadlineLabel', (
            select to_char(max(o.expires_at), 'DD Mon')
            from public.offers o
            where o.batch_id = b.id and o.status = 'pending'
        ),
        'createdAtIso',    b.created_at,
        'publishedAtIso',  b.published_at,
        'matchedAtIso',    b.matched_at,
        'confirmedAtIso',  b.confirmed_at,
        'dispatchedAtIso', b.dispatched_at,
        'deliveredAtIso',  b.delivered_at,
        'history',    jsonb_build_array(
            jsonb_build_object('t', 'Создана', 'd', to_char(b.created_at, 'DD Mon')),
            jsonb_build_object('t',
                case when b.status = 'draft' then 'Черновик'
                     when b.status in ('matched','partially_matched','confirmed','dispatched','delivered') then 'Подобран покупатель'
                     when b.status = 'cancelled' then 'Снята'
                     else 'Выставлена на продажу' end,
                'd', to_char(coalesce(b.published_at, b.created_at), 'DD Mon'))
        )
    )
    into v
    from public.batches b
    left join public.regions r        on r.id = b.region_id
    left join public.pool_lines pl    on pl.id = b.pool_line_id
    left join public.pools po         on po.id = pl.pool_id
    left join public.organizations bo on bo.id = po.organization_id
    cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
    left join lateral (
        select jsonb_build_object(
            'r1', dr.overall_score,
            'r2', score.score,
            'comment', coalesce(dr.comment, '')
        ) as review
        from public.deal_reviews dr
        left join lateral (
            select ds.score
            from public.deal_review_dimension_scores ds
            join public.review_dimensions d on d.id = ds.dimension_id
            where ds.deal_review_id = dr.id
              and d.code = 'weight_accuracy'
            limit 1
        ) score on true
        where dr.batch_id = b.id
          and dr.reviewer_org_id = b.organization_id
          and dr.reviewer_role = 'farmer'
        limit 1
    ) canonical_review on true
    where b.id = p_batch_id;

    return v;
end;
$$;

comment on function public.fn_tsp_batch_json(uuid) is
    'ARS-360 compatibility projection for the farmer Batch shape. review is canonical
     first (weight_accuracy), with a read-only valid-notes fallback only while legacy
     reconciliation remains. Direct client execution is intentionally forbidden.';

revoke execute on function public.fn_tsp_batch_json(uuid)
    from public, anon, authenticated, service_role;

create or replace function public.rpc_get_pool_matches(p_pool_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool     public.pools%rowtype;
    v_req      public.pool_requests%rowtype;
    v_revealed boolean;
begin
    select * into v_pool from public.pools where id = p_pool_id;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    if not coalesce(v_req.organization_id = any(public.fn_my_org_ids()), false) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = '42501';
    end if;

    v_revealed := v_pool.mpk_contact_revealed_at is not null;

    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'matchId',   a.id,
                'batchId',   b.id,
                'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'grade',     public.fn_tsp_batch_grade(b.id),
                'breed',     coalesce(meta->>'breed', ''),
                'heads',     a.heads,
                'avgWeight', b.avg_weight_kg,
                'price',     a.price_per_kg,
                'region',    coalesce(meta->>'district', coalesce(r.name_ru, '')),
                'status',    case when a.status = 'delivered'  then 'delivered'
                                  when a.status = 'dispatched' then 'dispatched'
                                  when a.status = 'confirmed'  then 'confirmed'
                                  else 'active' end,
                'matchedAt',    a.matched_at,
                'confirmedAt',  a.confirmed_at,
                'dispatchedAt', a.dispatched_at,
                'deliveredAt',  a.delivered_at,
                'farmName',  case when v_revealed then o.legal_name else null end,
                'farmPhone', case when v_revealed then o.phone     else null end,
                'myRating',  coalesce(
                    canonical_review.overall_score,
                    case
                        when jsonb_typeof(meta->'mpk_review') = 'object'
                         and (meta->'mpk_review'->>'r1') ~ '^[1-5]$'
                         and (meta->'mpk_review'->>'r2') ~ '^[1-5]$'
                            then (meta->'mpk_review'->>'r1')::int
                    end
                )
            )
            order by a.matched_at desc
        ), '[]'::jsonb)
        from public.batch_allocations a
        join public.batches b       on b.id = a.batch_id
        join public.organizations o on o.id = b.organization_id
        left join public.regions r  on r.id = b.region_id
        cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
        left join lateral (
            select dr.overall_score
            from public.deal_reviews dr
            where dr.batch_id = b.id
              and dr.reviewer_org_id = v_req.organization_id
              and dr.reviewer_role = 'mpk'
            limit 1
        ) canonical_review on true
        where a.pool_id = p_pool_id
          and a.status <> 'cancelled'
    );
end;
$$;

comment on function public.rpc_get_pool_matches(uuid) is
    'ARS-360 compatibility projection for MPK pool matches. myRating is the caller
     MPK''s canonical review first, with a read-only valid-notes fallback only while
     legacy reconciliation remains. No counterparty review content is exposed.';

revoke execute on function public.rpc_get_pool_matches(uuid) from public, anon;
grant execute on function public.rpc_get_pool_matches(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. Intentionally public, sanitized reputation aggregate. It uses canonical,
--    mutually revealed farmer reviews only and never returns counterparty identity,
--    batch identifiers, review comments, or individual review records.
-- -----------------------------------------------------------------------------

create or replace function public.rpc_get_mpk_reputation(p_mpk_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if p_mpk_org_id is null then
        raise exception 'MPK_ORGANIZATION_REQUIRED' using errcode = 'P0001';
    end if;

    return (
        with eligible_reviews as (
            select dr.overall_score, weight_score.score as weight_accuracy_score
            from public.deal_reviews dr
            join public.batches b on b.id = dr.batch_id
            cross join lateral (
                select public.fn_ars_360_mpk_counterparty_ids(dr.batch_id) as counterparty_org_ids
            ) counterparty
            left join lateral (
                select ds.score
                from public.deal_review_dimension_scores ds
                join public.review_dimensions d on d.id = ds.dimension_id
                where ds.deal_review_id = dr.id
                  and d.code = 'weight_accuracy'
                limit 1
            ) weight_score on true
            where dr.reviewer_role = 'farmer'
              and dr.reviewer_org_id = b.organization_id
              and dr.visible_at is not null
              and dr.visible_at <= now()
              and public.fn_ars_360_is_exact_current_deal_review_pair(dr.batch_id, true)
              and cardinality(counterparty.counterparty_org_ids) = 1
              and counterparty.counterparty_org_ids[1] = p_mpk_org_id
              and exists (
                  select 1
                  from public.deal_reviews mpk_review
                  where mpk_review.batch_id = dr.batch_id
                    and mpk_review.reviewer_org_id = p_mpk_org_id
                    and mpk_review.reviewer_role = 'mpk'
                    and mpk_review.visible_at is not null
                    and mpk_review.visible_at <= now()
              )
        )
        select jsonb_build_object(
            'mpk_org_id', p_mpk_org_id,
            'review_count', count(*),
            'average_score', round(avg(overall_score)::numeric, 2),
            'weight_accuracy_average', round(avg(weight_accuracy_score)::numeric, 2),
            'distribution', jsonb_build_object(
                '1', count(*) filter (where overall_score = 1),
                '2', count(*) filter (where overall_score = 2),
                '3', count(*) filter (where overall_score = 3),
                '4', count(*) filter (where overall_score = 4),
                '5', count(*) filter (where overall_score = 5)
            )
        )
        from eligible_reviews
    );
end;
$$;

comment on function public.rpc_get_mpk_reputation(uuid) is
    'ARS-360 intentional public aggregate endpoint. Counts only mutually revealed,
     unambiguously attributable farmer-to-MPK canonical reviews and returns no
     counterparty, batch, comment, or individual-review data.';

revoke execute on function public.rpc_get_mpk_reputation(uuid)
    from public, anon, authenticated, service_role;
grant execute on function public.rpc_get_mpk_reputation(uuid)
    to anon, authenticated, service_role;

-- Keep the runtime registry aligned with the canonical d02 declaration so the
-- API catalog checker can prove this public RPC is intentional.
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values (
    'rpc_get_mpk_reputation',
    'rpc_get_mpk_reputation',
    null,
    'supabase/migrations/20260731074557_ars_360_review_convergence.sql',
    'ARS-360: public aggregate-only farmer-to-MPK reputation; no counterparty or batch detail'
)
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name,
        notes = excluded.notes,
        created_in = excluded.created_in;
