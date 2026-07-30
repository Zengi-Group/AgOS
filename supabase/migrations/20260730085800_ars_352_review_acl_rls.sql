-- AgOS · ARS-352 · Close review/messaging Data API drift found by live audit.
--
-- Findings on mwtbozflyldcadypherr (2026-07-30):
--   * deal_review_dimension_scores was exposed with RLS disabled;
--   * rpc_submit_deal_review was anon-executable and trusted client org_id;
--   * d12 SECURITY DEFINER messaging functions inherited EXECUTE from PUBLIC.
--
-- Idempotent, additive security migration. No data rewrite.

-- -----------------------------------------------------------------------------
-- 1. Review tables: explicit Data API surface + inherited double-blind RLS.
-- -----------------------------------------------------------------------------

alter table public.deal_reviews enable row level security;
alter table public.deal_review_dimension_scores enable row level security;

drop policy if exists deal_reviews_read on public.deal_reviews;
create policy deal_reviews_read
    on public.deal_reviews for select
    to authenticated
    using (
        reviewer_org_id = any(
            coalesce((select public.fn_my_org_ids()), array[]::uuid[])
        )
        or (visible_at is not null and visible_at <= now())
    );

drop policy if exists deal_review_dimension_scores_read
    on public.deal_review_dimension_scores;
create policy deal_review_dimension_scores_read
    on public.deal_review_dimension_scores for select
    to authenticated
    using (
        exists (
            select 1
            from public.deal_reviews dr
            where dr.id = deal_review_id
              and (
                  dr.reviewer_org_id = any(
                      coalesce((select public.fn_my_org_ids()), array[]::uuid[])
                  )
                  or (dr.visible_at is not null and dr.visible_at <= now())
              )
        )
    );

revoke all on table public.deal_reviews
    from public, anon, authenticated, service_role;
revoke all on table public.deal_review_dimension_scores
    from public, anon, authenticated, service_role;
grant select on table public.deal_reviews
    to authenticated;
grant select on table public.deal_review_dimension_scores
    to authenticated;
grant select, insert, update, delete on table public.deal_reviews
    to service_role;
grant select, insert, update, delete on table public.deal_review_dimension_scores
    to service_role;

-- -----------------------------------------------------------------------------
-- 2. Canonical review write: authenticate and bind p_organization_id to caller.
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
    v_batch         record;
    v_mpk_org_id    uuid;
    v_reviewer_role text;
    v_review_id     uuid;
    v_other_exists  boolean;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not coalesce(p_organization_id = any(public.fn_my_org_ids()), false) then
        raise exception 'FORBIDDEN: caller is not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    if not (p_overall_score between 1 and 5) then
        raise exception 'INVALID_SCORE: overall_score must be between 1 and 5'
            using errcode = 'P0001';
    end if;
    if not (p_dimension_score between 1 and 5) then
        raise exception 'INVALID_SCORE: dimension_score must be between 1 and 5'
            using errcode = 'P0001';
    end if;
    if p_dimension_id is null then
        raise exception 'INVALID_INPUT: p_dimension_id required' using errcode = 'P0001';
    end if;
    if not exists (
        select 1 from public.review_dimensions
        where id = p_dimension_id and is_active = true
    ) then
        raise exception 'UNKNOWN_DIMENSION: %', p_dimension_id using errcode = 'P0001';
    end if;

    select b.*, p.organization_id as mpk_org_id
      into v_batch
    from public.batches b
    left join public.pool_lines pl on pl.id = b.pool_line_id
    left join public.pools p       on p.id = pl.pool_id
    where b.id = p_batch_id;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_batch.status != 'delivered' then
        raise exception 'INVALID_STATUS: reviews only from delivered (current %)',
            v_batch.status using errcode = 'P0001';
    end if;

    v_mpk_org_id := v_batch.mpk_org_id;

    if v_batch.organization_id = p_organization_id then
        v_reviewer_role := 'farmer';
    elsif v_mpk_org_id is not null and v_mpk_org_id = p_organization_id then
        v_reviewer_role := 'mpk';
    else
        raise exception 'FORBIDDEN: organization is not a party to this batch'
            using errcode = 'P0001';
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

    select exists (
        select 1 from public.deal_reviews
        where batch_id = p_batch_id
          and reviewer_org_id != p_organization_id
    ) into v_other_exists;

    if v_other_exists then
        update public.deal_reviews
        set visible_at = now()
        where batch_id = p_batch_id and visible_at is null;
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
            'mutual_revealed', v_other_exists
        ),
        true
    );

    return v_review_id;
end;
$$;

comment on function public.rpc_submit_deal_review(uuid, uuid, int, uuid, int, text) is
    'ARS-352 / D-M6-11 / D-M6-12. Authenticated mutual deal review; caller must
     belong to p_organization_id, which must be a batch party. Double-blind reveal.';

revoke execute on function public.rpc_submit_deal_review(uuid, uuid, int, uuid, int, text)
    from public, anon;
grant execute on function public.rpc_submit_deal_review(uuid, uuid, int, uuid, int, text)
    to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. Messaging: remove inherited PUBLIC/anon EXECUTE from all d12 entry points.
-- -----------------------------------------------------------------------------

revoke execute on function public.rpc_get_or_create_support_channel(uuid)
    from public, anon;
revoke execute on function public.rpc_send_message(uuid, text, jsonb)
    from public, anon;
revoke execute on function public.rpc_list_channels()
    from public, anon;
revoke execute on function public.rpc_list_messages(uuid, timestamptz, int)
    from public, anon;
revoke execute on function public.rpc_mark_channel_read(uuid)
    from public, anon;
revoke execute on function public.rpc_archive_channel(uuid)
    from public, anon;

grant execute on function public.rpc_get_or_create_support_channel(uuid)
    to authenticated, service_role;
grant execute on function public.rpc_send_message(uuid, text, jsonb)
    to authenticated, service_role;
grant execute on function public.rpc_list_channels()
    to authenticated, service_role;
grant execute on function public.rpc_list_messages(uuid, timestamptz, int)
    to authenticated, service_role;
grant execute on function public.rpc_mark_channel_read(uuid)
    to authenticated, service_role;
grant execute on function public.rpc_archive_channel(uuid)
    to authenticated, service_role;

revoke execute on function public.fn_fanout_comm_notifications(uuid)
    from public, anon, authenticated;
grant execute on function public.fn_fanout_comm_notifications(uuid)
    to service_role;
