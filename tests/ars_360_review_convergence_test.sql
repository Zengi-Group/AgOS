-- ARS-360 transactional regression contract.
-- Run after supabase/migrations/20260731074557_ars_360_review_convergence.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/ars_360_review_convergence_test.sql
--
-- The test intentionally seeds only rollback-scoped fixtures.  It requires a
-- database-owner/migration-owner test connection (for fixture setup and the
-- non-client-executable backfill helper), four active non-admin auth-backed public.users, the
-- authenticated/anon database roles, one TSP SKU, and the three seeded review
-- dimensions used below.

begin;

do $$
declare
    v_user_ids                         uuid[];
    v_auth_ids                         uuid[];
    v_farmer_user_id                   uuid;
    v_farmer_auth_id                   uuid;
    v_mpk_a_user_id                    uuid;
    v_mpk_a_auth_id                    uuid;
    v_mpk_b_user_id                    uuid;
    v_mpk_b_auth_id                    uuid;
    v_outsider_user_id                 uuid;
    v_outsider_auth_id                 uuid;

    v_farmer_org_id                    uuid := gen_random_uuid();
    v_mpk_a_org_id                     uuid := gen_random_uuid();
    v_mpk_b_org_id                     uuid := gen_random_uuid();
    v_outsider_org_id                  uuid := gen_random_uuid();
    v_pool_request_a_id                uuid := gen_random_uuid();
    v_pool_request_b_id                uuid := gen_random_uuid();
    v_pool_a_id                        uuid := gen_random_uuid();
    v_pool_b_id                        uuid := gen_random_uuid();
    v_pool_line_a_id                   uuid := gen_random_uuid();
    v_pool_line_b_id                   uuid := gen_random_uuid();

    v_adapter_batch_id                 uuid := gen_random_uuid();
    v_invalid_write_batch_id           uuid := gen_random_uuid();
    v_projection_batch_id              uuid := gen_random_uuid();
    v_farmer_fallback_batch_id         uuid := gen_random_uuid();
    v_mpk_fallback_batch_id            uuid := gen_random_uuid();
    v_hidden_reputation_batch_id       uuid := gen_random_uuid();
    v_wrong_target_batch_id            uuid := gen_random_uuid();
    v_backfill_pair_batch_id           uuid := gen_random_uuid();
    v_backfill_farmer_batch_id         uuid := gen_random_uuid();
    v_backfill_mpk_duplicate_batch_id  uuid := gen_random_uuid();
    v_existing_canonical_batch_id      uuid := gen_random_uuid();
    v_invalid_backfill_batch_id        uuid := gen_random_uuid();
    v_not_delivered_batch_id           uuid := gen_random_uuid();
    v_ambiguous_batch_id               uuid := gen_random_uuid();
    v_unknown_dimension_batch_id       uuid := gen_random_uuid();

    v_sku_id                           uuid;
    v_weight_dimension_id              uuid;
    v_livestock_dimension_id           uuid;
    v_communication_dimension_id       uuid;
    v_weight_dimension_name            text;

    v_adapter_notes_before             text;
    v_invalid_write_notes_before       text;
    v_not_delivered_notes_before       text;
    v_fallback_notes_before            text;
    v_mpk_fallback_notes_before        text;
    v_ambiguous_notes_before           text;
    v_notes_snapshot_before_retry      jsonb;
    v_notes_snapshot_after_retry       jsonb;

    v_bool                             boolean;
    v_error                            text;
    v_result                           jsonb;
    v_projection                       jsonb;
    v_pool_match                       jsonb;
    v_reputation                       jsonb;
    v_reputation_anon                  jsonb;
    v_bad_payload                      jsonb := jsonb_build_object(
        'r1', 0, 'r2', 4, 'comment', 'ARS-360 invalid legacy payload'
    );
    v_ambiguous_payload                jsonb := jsonb_build_object(
        'r1', 4, 'r2', 5, 'comment', 'ARS-360 ambiguous MPK legacy payload'
    );
    v_ambiguous_farmer_payload         jsonb := jsonb_build_object(
        'r1', 5, 'r2', 4, 'comment', 'ARS-360 ambiguous farmer legacy payload'
    );
    v_report_payload                   jsonb;
    v_candidate_org_ids                uuid[];
    v_count                            integer;
    v_review_count_before_retry        integer;
    v_score_count_before_retry         integer;
    v_reconciliation_count_before_retry integer;
    v_fixture_batch_ids                uuid[];
begin
    -- -------------------------------------------------------------------------
    -- Catalog, ACL, and schema contract.
    -- -------------------------------------------------------------------------
    if to_regclass('public.deal_review_legacy_reconciliation') is null then
        raise exception 'ARS-360: deal_review_legacy_reconciliation is missing';
    end if;
    if to_regprocedure('public.fn_backfill_legacy_deal_reviews()') is null then
        raise exception 'ARS-360: fn_backfill_legacy_deal_reviews() is missing';
    end if;
    if to_regprocedure('public.rpc_get_mpk_reputation(uuid)') is null then
        raise exception 'ARS-360: rpc_get_mpk_reputation(uuid) is missing';
    end if;
    if to_regprocedure('public.rpc_submit_review(uuid,integer,integer,text)') is null
       or to_regprocedure('public.rpc_self_submit_mpk_review(uuid,integer,integer,text)') is null then
        raise exception 'ARS-360: a legacy write adapter signature is missing';
    end if;

    if (
        select count(*)
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'deal_review_legacy_reconciliation'
          and column_name = any (array[
              'batch_id', 'legacy_key', 'reason_code', 'raw_payload',
              'candidate_counterparty_org_ids', 'status', 'resolution_code',
              'observed_at', 'last_observed_at', 'resolved_at'
          ])
    ) <> 10 then
        raise exception 'ARS-360: reconciliation report contract columns are incomplete';
    end if;

    if not coalesce((
        select c.relrowsecurity
        from pg_class c
        where c.oid = 'public.deal_review_legacy_reconciliation'::regclass
    ), false) then
        raise exception 'ARS-360: reconciliation report must have RLS enabled';
    end if;

    -- The dimension catalog is read-only to clients.  Canonical review facts are
    -- readable only through RLS and never writable through the Data API.
    if has_table_privilege('anon', 'public.review_dimensions', 'select')
       or not has_table_privilege('authenticated', 'public.review_dimensions', 'select')
       or has_table_privilege('authenticated', 'public.review_dimensions', 'insert')
       or has_table_privilege('authenticated', 'public.review_dimensions', 'update')
       or has_table_privilege('authenticated', 'public.review_dimensions', 'delete') then
        raise exception 'ARS-360: review dimension catalog ACL is not authenticated read-only';
    end if;

    if has_table_privilege('anon', 'public.deal_reviews', 'select')
       or has_table_privilege('anon', 'public.deal_review_dimension_scores', 'select')
       or not has_table_privilege('authenticated', 'public.deal_reviews', 'select')
       or not has_table_privilege('authenticated', 'public.deal_review_dimension_scores', 'select')
       or has_table_privilege('authenticated', 'public.deal_reviews', 'insert')
       or has_table_privilege('authenticated', 'public.deal_reviews', 'update')
       or has_table_privilege('authenticated', 'public.deal_reviews', 'delete')
       or has_table_privilege('authenticated', 'public.deal_review_dimension_scores', 'insert')
       or has_table_privilege('authenticated', 'public.deal_review_dimension_scores', 'update')
       or has_table_privilege('authenticated', 'public.deal_review_dimension_scores', 'delete') then
        raise exception 'ARS-360: canonical review table ACL permits a client-side write';
    end if;

    if has_table_privilege('anon', 'public.deal_review_legacy_reconciliation', 'select')
       or has_table_privilege('authenticated', 'public.deal_review_legacy_reconciliation', 'select')
       or has_table_privilege('authenticated', 'public.deal_review_legacy_reconciliation', 'insert')
       or has_table_privilege('authenticated', 'public.deal_review_legacy_reconciliation', 'update')
       or has_table_privilege('authenticated', 'public.deal_review_legacy_reconciliation', 'delete') then
        raise exception 'ARS-360: reconciliation report is exposed to a client role';
    end if;

    if has_function_privilege(
        'anon', 'public.rpc_submit_review(uuid,integer,integer,text)', 'execute'
    ) or has_function_privilege(
        'anon', 'public.rpc_self_submit_mpk_review(uuid,integer,integer,text)', 'execute'
    ) or has_function_privilege(
        'anon', 'public.rpc_submit_deal_review(uuid,uuid,integer,uuid,integer,text)', 'execute'
    ) then
        raise exception 'ARS-360: anon can execute a review write entry point';
    end if;

    if not has_function_privilege(
        'authenticated', 'public.rpc_submit_review(uuid,integer,integer,text)', 'execute'
    ) or not has_function_privilege(
        'authenticated', 'public.rpc_self_submit_mpk_review(uuid,integer,integer,text)', 'execute'
    ) or not has_function_privilege(
        'authenticated', 'public.rpc_submit_deal_review(uuid,uuid,integer,uuid,integer,text)', 'execute'
    ) then
        raise exception 'ARS-360: authenticated review write grant is missing';
    end if;

    if has_function_privilege(
        'anon', 'public.fn_backfill_legacy_deal_reviews()', 'execute'
    ) or has_function_privilege(
        'authenticated', 'public.fn_backfill_legacy_deal_reviews()', 'execute'
    ) then
        raise exception 'ARS-360: legacy backfill helper is client-executable';
    end if;

    -- Reputation is intentionally a public aggregate surface, but not a detail
    -- surface.  Its behavioural privacy checks are below.
    if not has_function_privilege(
        'anon', 'public.rpc_get_mpk_reputation(uuid)', 'execute'
    ) or not has_function_privilege(
        'authenticated', 'public.rpc_get_mpk_reputation(uuid)', 'execute'
    ) then
        raise exception 'ARS-360: public reputation aggregate execute grant is missing';
    end if;

    -- -------------------------------------------------------------------------
    -- Discover reusable test principals and catalog rows.
    -- -------------------------------------------------------------------------
    select array_agg(c.id order by c.created_at, c.id),
           array_agg(c.auth_id order by c.created_at, c.id)
      into v_user_ids, v_auth_ids
    from (
        select u.id, u.auth_id, u.created_at
        from public.users u
        where u.is_active
          and u.auth_id is not null
          and not exists (
              select 1
              from public.admin_roles ar
              where ar.user_id = u.id and ar.is_active
          )
        order by u.created_at, u.id
        limit 4
    ) c;

    if coalesce(cardinality(v_user_ids), 0) <> 4 then
        raise exception 'ARS-360_TEST_SETUP: requires four active non-admin auth-backed users';
    end if;

    v_farmer_user_id := v_user_ids[1];
    v_farmer_auth_id := v_auth_ids[1];
    v_mpk_a_user_id := v_user_ids[2];
    v_mpk_a_auth_id := v_auth_ids[2];
    v_mpk_b_user_id := v_user_ids[3];
    v_mpk_b_auth_id := v_auth_ids[3];
    v_outsider_user_id := v_user_ids[4];
    v_outsider_auth_id := v_auth_ids[4];

    select id, name_ru
      into v_weight_dimension_id, v_weight_dimension_name
    from public.review_dimensions
    where code = 'weight_accuracy' and applicable_role = 'farmer' and is_active
    limit 1;
    select id
      into v_livestock_dimension_id
    from public.review_dimensions
    where code = 'livestock_condition' and applicable_role = 'mpk' and is_active
    limit 1;
    select id
      into v_communication_dimension_id
    from public.review_dimensions
    where code = 'communication' and applicable_role = 'both' and is_active
    limit 1;
    select id into v_sku_id
    from public.tsp_skus
    order by sku_code
    limit 1;

    if v_weight_dimension_id is null
       or v_livestock_dimension_id is null
       or v_communication_dimension_id is null
       or v_sku_id is null then
        raise exception 'ARS-360_TEST_SETUP: needs active weight_accuracy, livestock_condition, communication dimensions and one TSP SKU';
    end if;

    -- Assert a real authenticated catalog mutation cannot bypass the catalog's
    -- read-only contract.  The original test role remains able to seed a later
    -- inactive-dimension reconciliation fixture.
    v_error := null;
    execute 'set local role authenticated';
    begin
        update public.review_dimensions
           set name_ru = 'ARS-360 forbidden catalog mutation'
         where id = v_weight_dimension_id;
    exception
        when insufficient_privilege then
            get stacked diagnostics v_error = message_text;
    end;
    execute 'reset role';
    if v_error is null
       or (select name_ru from public.review_dimensions where id = v_weight_dimension_id)
              is distinct from v_weight_dimension_name then
        raise exception 'ARS-360: authenticated catalog mutation was not rejected';
    end if;

    -- -------------------------------------------------------------------------
    -- Isolated farmer, two MPKs, and outsider.  Pools retain a legacy request so
    -- the existing rpc_get_pool_matches compatibility guard is exercised too.
    -- -------------------------------------------------------------------------
    insert into public.organizations (id, legal_name) values
        (v_farmer_org_id,   'ARS-360 QA Farmer ' || v_farmer_org_id),
        (v_mpk_a_org_id,    'ARS-360 QA MPK A ' || v_mpk_a_org_id),
        (v_mpk_b_org_id,    'ARS-360 QA MPK B ' || v_mpk_b_org_id),
        (v_outsider_org_id, 'ARS-360 QA Outsider ' || v_outsider_org_id);

    insert into public.organization_type_assignments (organization_id, org_type) values
        (v_farmer_org_id, 'farmer'),
        (v_mpk_a_org_id, 'mpk'),
        (v_mpk_b_org_id, 'mpk'),
        (v_outsider_org_id, 'farmer');

    insert into public.user_organization_roles (
        user_id, organization_id, role, is_primary
    ) values
        (v_farmer_user_id, v_farmer_org_id, 'owner', false),
        (v_mpk_a_user_id, v_mpk_a_org_id, 'owner', false),
        (v_mpk_b_user_id, v_mpk_b_org_id, 'owner', false),
        (v_outsider_user_id, v_outsider_org_id, 'owner', false);

    insert into public.pool_requests (
        id, organization_id, total_heads, target_month, status
    ) values
        (v_pool_request_a_id, v_mpk_a_org_id, 1000, date_trunc('month', current_date)::date, 'active'),
        (v_pool_request_b_id, v_mpk_b_org_id, 1000, date_trunc('month', current_date)::date, 'active');

    insert into public.pools (
        id, pool_request_id, organization_id, target_heads, matched_heads,
        total_target_volume_kg, status
    ) values
        (v_pool_a_id, v_pool_request_a_id, v_mpk_a_org_id, 1000, 0, 400000, 'filling'),
        (v_pool_b_id, v_pool_request_b_id, v_mpk_b_org_id, 1000, 0, 400000, 'filling');

    insert into public.pool_lines (
        id, pool_id, tsp_sku_id, mpk_price_per_kg, max_volume_kg
    ) values
        (v_pool_line_a_id, v_pool_a_id, v_sku_id, 1200, 400000),
        (v_pool_line_b_id, v_pool_b_id, v_sku_id, 1200, 400000);

    -- All delivered cases have allocation-level delivery.  The ambiguous fixture
    -- deliberately retains A as batches.pool_line_id while allocations identify A
    -- and B, proving that ARS-360 must not guess from the legacy column.
    insert into public.batches (
        id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
        status, pool_line_id, matched_heads, delivered_at, notes
    ) values
        (
            v_adapter_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object('fixture', 'adapter')::text
        ),
        (
            v_invalid_write_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object('fixture', 'invalid-write')::text
        ),
        (
            v_projection_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object(
                'review', jsonb_build_object('r1', 1, 'r2', 1, 'comment', 'legacy farmer loses'),
                'mpk_review', jsonb_build_object('r1', 1, 'r2', 1, 'comment', 'legacy MPK loses')
            )::text
        ),
        (
            v_farmer_fallback_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object(
                'review', jsonb_build_object('r1', 3, 'r2', 2, 'comment', 'farmer note fallback')
            )::text
        ),
        (
            v_mpk_fallback_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object(
                'mpk_review', jsonb_build_object('r1', 3, 'r2', 4, 'comment', 'MPK note fallback')
            )::text
        ),
        (
            v_hidden_reputation_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object('fixture', 'hidden-reputation')::text
        ),
        (
            v_wrong_target_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object('fixture', 'allocation-not-legacy-line')::text
        ),
        (
            v_backfill_pair_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object(
                'review', jsonb_build_object('r1', 5, 'r2', 4, 'comment', 'backfill farmer pair'),
                'mpk_review', jsonb_build_object('r1', 3, 'r2', 2, 'comment', 'backfill MPK pair')
            )::text
        ),
        (
            v_backfill_farmer_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object(
                'review', jsonb_build_object('r1', 4, 'r2', 3, 'comment', 'backfill farmer only')
            )::text
        ),
        (
            v_backfill_mpk_duplicate_batch_id, v_farmer_org_id, v_sku_id, 20, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            20, now(), jsonb_build_object(
                'mpk_review', jsonb_build_object('r1', 2, 'r2', 5, 'comment', 'backfill MPK duplicate allocation')
            )::text
        ),
        (
            v_existing_canonical_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object(
                'review', jsonb_build_object('r1', 1, 'r2', 1, 'comment', 'conflicting legacy loses')
            )::text
        ),
        (
            v_invalid_backfill_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            10, now(), jsonb_build_object('review', v_bad_payload)::text
        ),
        (
            v_not_delivered_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
            date_trunc('month', current_date)::date, 'confirmed', v_pool_line_a_id,
            10, null, jsonb_build_object(
                'review', jsonb_build_object('r1', 5, 'r2', 4, 'comment', 'not delivered')
            )::text
        ),
        (
            v_ambiguous_batch_id, v_farmer_org_id, v_sku_id, 20, 400,
            date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
            20, now(), jsonb_build_object(
                'review', v_ambiguous_farmer_payload,
                'mpk_review', v_ambiguous_payload
            )::text
        );

    insert into public.batch_allocations (
        batch_id, pool_line_id, pool_id, heads, price_per_kg, status, delivered_at
    ) values
        (v_adapter_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_invalid_write_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_projection_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_farmer_fallback_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_mpk_fallback_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_hidden_reputation_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_wrong_target_batch_id, v_pool_line_b_id, v_pool_b_id, 10, 1200, 'delivered', now()),
        (v_backfill_pair_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_backfill_farmer_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_backfill_mpk_duplicate_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_backfill_mpk_duplicate_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_existing_canonical_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_invalid_backfill_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_not_delivered_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'confirmed', null),
        (v_ambiguous_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()),
        (v_ambiguous_batch_id, v_pool_line_b_id, v_pool_b_id, 10, 1200, 'delivered', now());

    -- -------------------------------------------------------------------------
    -- Canonical legacy adapters: writes do not dual-write notes, use the named
    -- pilot dimensions, and preserve double-blind privacy before the reciprocal
    -- submission arrives.
    -- -------------------------------------------------------------------------
    select notes into v_adapter_notes_before
    from public.batches where id = v_adapter_batch_id;

    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_farmer_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    select public.rpc_submit_review(
        v_adapter_batch_id, 5, 4, 'ARS-360 farmer adapter'
    ) into v_bool;
    execute 'reset role';
    if v_bool is distinct from true then
        raise exception 'ARS-360: farmer legacy adapter did not return true';
    end if;

    if (select notes from public.batches where id = v_adapter_batch_id)
           is distinct from v_adapter_notes_before
       or not exists (
            select 1
            from public.deal_reviews dr
            join public.deal_review_dimension_scores ds on ds.deal_review_id = dr.id
            where dr.batch_id = v_adapter_batch_id
              and dr.reviewer_org_id = v_farmer_org_id
              and dr.reviewer_role = 'farmer'
              and dr.overall_score = 5
              and dr.comment = 'ARS-360 farmer adapter'
              and ds.dimension_id = v_weight_dimension_id
              and ds.score = 4
       ) then
        raise exception 'ARS-360: farmer adapter did not produce the canonical pilot review';
    end if;

    -- The counterparty has not submitted yet: no review or score can be read by
    -- the MPK through RLS.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_mpk_a_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    select count(*) into v_count
    from public.deal_reviews
    where batch_id = v_adapter_batch_id;
    if v_count <> 0 then
        execute 'reset role';
        raise exception 'ARS-360: MPK can read an unrevealed farmer review';
    end if;
    select count(*) into v_count
    from public.deal_review_dimension_scores ds
    join public.deal_reviews dr on dr.id = ds.deal_review_id
    where dr.batch_id = v_adapter_batch_id;
    if v_count <> 0 then
        execute 'reset role';
        raise exception 'ARS-360: MPK can read an unrevealed farmer dimension score';
    end if;
    execute 'reset role';

    execute 'set local role authenticated';
    select public.rpc_self_submit_mpk_review(
        v_adapter_batch_id, 3, 2, 'ARS-360 MPK adapter'
    ) into v_bool;
    execute 'reset role';
    if v_bool is distinct from true then
        raise exception 'ARS-360: MPK legacy adapter did not return true';
    end if;

    if (select notes from public.batches where id = v_adapter_batch_id)
           is distinct from v_adapter_notes_before
       or not exists (
            select 1
            from public.deal_reviews dr
            join public.deal_review_dimension_scores ds on ds.deal_review_id = dr.id
            where dr.batch_id = v_adapter_batch_id
              and dr.reviewer_org_id = v_mpk_a_org_id
              and dr.reviewer_role = 'mpk'
              and dr.overall_score = 3
              and dr.comment = 'ARS-360 MPK adapter'
              and ds.dimension_id = v_livestock_dimension_id
              and ds.score = 2
       )
       or (
            select count(*)
            from public.deal_reviews
            where batch_id = v_adapter_batch_id and visible_at is not null
       ) <> 2 then
        raise exception 'ARS-360: MPK adapter did not produce/reveal the canonical mutual pair';
    end if;

    -- Each party can now see both review rows and their inherited dimension rows.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_farmer_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    select count(*) into v_count from public.deal_reviews where batch_id = v_adapter_batch_id;
    if v_count <> 2 then
        execute 'reset role';
        raise exception 'ARS-360: farmer cannot read mutually revealed reviews';
    end if;
    select count(*) into v_count
    from public.deal_review_dimension_scores ds
    join public.deal_reviews dr on dr.id = ds.deal_review_id
    where dr.batch_id = v_adapter_batch_id;
    if v_count <> 2 then
        execute 'reset role';
        raise exception 'ARS-360: farmer cannot read mutually revealed scores';
    end if;
    execute 'reset role';

    -- Mutual reveal is bilateral. A third authenticated organization cannot use the
    -- direct RLS read surface as a public review feed.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_outsider_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    select count(*) into v_count from public.deal_reviews where batch_id = v_adapter_batch_id;
    if v_count <> 0 then
        execute 'reset role';
        raise exception 'ARS-360: unrelated authenticated user can read revealed reviews';
    end if;
    select count(*) into v_count
    from public.deal_review_dimension_scores ds
    join public.deal_reviews dr on dr.id = ds.deal_review_id
    where dr.batch_id = v_adapter_batch_id;
    if v_count <> 0 then
        execute 'reset role';
        raise exception 'ARS-360: unrelated authenticated user can read revealed scores';
    end if;
    execute 'reset role';

    -- Review content is append-only once submitted; the only system transition is
    -- the one-time NULL -> visible_at reveal.  Even the migration/test owner must
    -- not be able to rewrite an already revealed canonical review in place.
    v_error := null;
    begin
        update public.deal_reviews
           set comment = 'ARS-360 forbidden canonical rewrite'
         where batch_id = v_adapter_batch_id
           and reviewer_org_id = v_farmer_org_id;
        raise exception 'ARS-360: canonical review update unexpectedly succeeded';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
    end;
    if v_error not like 'REVIEW_IMMUTABLE_AFTER_REVEAL%'
       or not exists (
            select 1
            from public.deal_reviews
            where batch_id = v_adapter_batch_id
              and reviewer_org_id = v_farmer_org_id
              and comment = 'ARS-360 farmer adapter'
       ) then
        raise exception 'ARS-360: canonical review immutability guard is missing';
    end if;

    -- Dimension scores are part of the same submitted canonical fact: neither a
    -- service worker nor a direct table path may rewrite a revealed score.
    v_error := null;
    begin
        update public.deal_review_dimension_scores ds
           set score = 1
          from public.deal_reviews dr
         where ds.deal_review_id = dr.id
           and dr.batch_id = v_adapter_batch_id
           and dr.reviewer_org_id = v_farmer_org_id;
        raise exception 'ARS-360: canonical dimension score update unexpectedly succeeded';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
    end;
    if v_error not like 'REVIEW_IMMUTABLE%'
       or not exists (
            select 1
            from public.deal_review_dimension_scores ds
            join public.deal_reviews dr on dr.id = ds.deal_review_id
            where dr.batch_id = v_adapter_batch_id
              and dr.reviewer_org_id = v_farmer_org_id
              and ds.dimension_id = v_weight_dimension_id
              and ds.score = 4
       ) then
        raise exception 'ARS-360: canonical dimension-score immutability guard is missing';
    end if;

    -- A revealed pair is immutable as a batch too: no service-side direct insert
    -- may append a third party after double-blind reveal.
    v_error := null;
    begin
        insert into public.deal_reviews (
            batch_id, reviewer_org_id, reviewer_role, overall_score, comment
        ) values (
            v_adapter_batch_id, v_outsider_org_id, 'mpk', 3,
            'ARS-360 forbidden post-reveal insert'
        );
        raise exception 'ARS-360: post-reveal review insert unexpectedly succeeded';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
    end;
    if v_error not like 'REVIEW_IMMUTABLE_AFTER_REVEAL%'
       or (select count(*) from public.deal_reviews where batch_id = v_adapter_batch_id) <> 2 then
        raise exception 'ARS-360: revealed batch accepts a post-reveal review';
    end if;

    -- A retry may be an idempotent true or a stable explicit duplicate signal, but
    -- it may not make another review/score or overwrite the first one.
    select count(*) into v_review_count_before_retry
    from public.deal_reviews where batch_id = v_adapter_batch_id;
    select count(*) into v_score_count_before_retry
    from public.deal_review_dimension_scores ds
    join public.deal_reviews dr on dr.id = ds.deal_review_id
    where dr.batch_id = v_adapter_batch_id;

    v_error := null;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_farmer_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    begin
        select public.rpc_submit_review(
            v_adapter_batch_id, 5, 4, 'ARS-360 farmer adapter'
        ) into v_bool;
        if v_bool is distinct from true then
            raise exception 'ARS-360: adapter retry returned false';
        end if;
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error not like 'REVIEW_ALREADY_SUBMITTED%' then
                execute 'reset role';
                raise;
            end if;
    end;
    execute 'reset role';

    if (select count(*) from public.deal_reviews where batch_id = v_adapter_batch_id)
           <> v_review_count_before_retry
       or (
            select count(*)
            from public.deal_review_dimension_scores ds
            join public.deal_reviews dr on dr.id = ds.deal_review_id
            where dr.batch_id = v_adapter_batch_id
       ) <> v_score_count_before_retry
       or not exists (
            select 1 from public.deal_reviews
            where batch_id = v_adapter_batch_id
              and reviewer_org_id = v_farmer_org_id
              and overall_score = 5
              and comment = 'ARS-360 farmer adapter'
       ) then
        raise exception 'ARS-360: adapter retry duplicated or overwrote canonical facts';
    end if;

    -- Invalid, non-delivered, and non-party writes remain side-effect free.
    select notes into v_invalid_write_notes_before
    from public.batches where id = v_invalid_write_batch_id;
    v_error := null;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_farmer_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    begin
        perform public.rpc_submit_review(v_invalid_write_batch_id, 0, 4, 'invalid');
        raise exception 'ARS-360: invalid rating unexpectedly accepted';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
    end;
    execute 'reset role';
    if v_error not like 'INVALID_%'
       or exists (
            select 1 from public.deal_reviews
            where batch_id = v_invalid_write_batch_id
       )
       or (select notes from public.batches where id = v_invalid_write_batch_id)
              is distinct from v_invalid_write_notes_before then
        raise exception 'ARS-360: invalid adapter write was not rejected without side effects';
    end if;

    select notes into v_not_delivered_notes_before
    from public.batches where id = v_not_delivered_batch_id;
    v_error := null;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_farmer_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    begin
        perform public.rpc_submit_review(v_not_delivered_batch_id, 5, 4, 'too early');
        raise exception 'ARS-360: non-delivered review unexpectedly accepted';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
    end;
    execute 'reset role';
    if v_error not like 'INVALID_STATUS%'
       or exists (
            select 1 from public.deal_reviews
            where batch_id = v_not_delivered_batch_id
       )
       or (select notes from public.batches where id = v_not_delivered_batch_id)
              is distinct from v_not_delivered_notes_before then
        raise exception 'ARS-360: non-delivered adapter write was not rejected without side effects';
    end if;

    v_error := null;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_outsider_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    begin
        perform public.rpc_submit_review(v_adapter_batch_id, 4, 4, 'outsider');
        raise exception 'ARS-360: outsider review unexpectedly accepted';
    exception
        when raise_exception or insufficient_privilege then
            get stacked diagnostics v_error = message_text;
    end;
    execute 'reset role';
    if v_error not like 'FORBIDDEN%'
       or (select count(*) from public.deal_reviews where batch_id = v_adapter_batch_id)
              <> v_review_count_before_retry then
        raise exception 'ARS-360: outsider adapter write was not rejected without side effects';
    end if;

    -- -------------------------------------------------------------------------
    -- Canonical-first legacy reads and genuinely read-only note fallback.
    -- -------------------------------------------------------------------------
    insert into public.deal_reviews (
        batch_id, reviewer_org_id, reviewer_role, overall_score, comment
    ) values
        (
            v_projection_batch_id, v_farmer_org_id, 'farmer', 5,
            'canonical farmer projection'
        ),
        (
            v_projection_batch_id, v_mpk_a_org_id, 'mpk', 4,
            'canonical MPK projection'
        ),
        (
            v_hidden_reputation_batch_id, v_farmer_org_id, 'farmer', 1,
            'hidden farmer reputation input'
        ),
        (
            v_wrong_target_batch_id, v_farmer_org_id, 'farmer', 2,
            'wrong legacy-line target'
        ),
        (
            v_wrong_target_batch_id, v_mpk_b_org_id, 'mpk', 4,
            'wrong legacy-line counterparty'
        ),
        (
            v_existing_canonical_batch_id, v_farmer_org_id, 'farmer', 4,
            'existing canonical wins'
        );

    insert into public.deal_review_dimension_scores (deal_review_id, dimension_id, score)
    select dr.id, v_weight_dimension_id,
           case dr.batch_id
               when v_projection_batch_id then 4
               when v_hidden_reputation_batch_id then 1
               when v_wrong_target_batch_id then 1
               when v_existing_canonical_batch_id then 3
           end
    from public.deal_reviews dr
    where dr.batch_id in (
        v_projection_batch_id, v_hidden_reputation_batch_id,
        v_wrong_target_batch_id, v_existing_canonical_batch_id
    )
      and dr.reviewer_role = 'farmer';

    insert into public.deal_review_dimension_scores (deal_review_id, dimension_id, score)
    select id, v_livestock_dimension_id, 2
    from public.deal_reviews
    where batch_id = v_projection_batch_id and reviewer_org_id = v_mpk_a_org_id;
    insert into public.deal_review_dimension_scores (deal_review_id, dimension_id, score)
    select id, v_livestock_dimension_id, 4
    from public.deal_reviews
    where batch_id = v_wrong_target_batch_id and reviewer_org_id = v_mpk_b_org_id;

    -- An unrelated active score must never be used as legacy r2 in place of the
    -- named pilot dimension.
    insert into public.deal_review_dimension_scores (deal_review_id, dimension_id, score)
    select id, v_communication_dimension_id, 1
    from public.deal_reviews
    where batch_id = v_projection_batch_id and reviewer_org_id = v_farmer_org_id;
    insert into public.deal_review_dimension_scores (deal_review_id, dimension_id, score)
    select id, v_communication_dimension_id, 5
    from public.deal_reviews
    where batch_id = v_projection_batch_id and reviewer_org_id = v_mpk_a_org_id;

    -- The immutable guard permits this one system transition only after each batch
    -- has an exact farmer/MPK pair.  It also means the fixture cannot manufacture a
    -- visible one-sided review that production code could never reveal.
    update public.deal_reviews
       set visible_at = now()
     where batch_id in (v_projection_batch_id, v_wrong_target_batch_id);

    -- fn_tsp_batch_json is an internal/service entry point, but retains the
    -- farmer-owned response shape; keep the principal in its transaction-local
    -- JWT context while invoking it through the test runner.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_farmer_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    select public.fn_tsp_batch_json(v_projection_batch_id) into v_projection;
    if v_projection->'review' is distinct from jsonb_build_object(
        'r1', 5, 'r2', 4, 'comment', 'canonical farmer projection'
    ) then
        raise exception 'ARS-360: fn_tsp_batch_json did not prefer the canonical farmer review/pilot score';
    end if;

    select notes into v_fallback_notes_before
    from public.batches where id = v_farmer_fallback_batch_id;
    select public.fn_tsp_batch_json(v_farmer_fallback_batch_id) into v_projection;
    if v_projection->'review' is distinct from jsonb_build_object(
        'r1', 3, 'r2', 2, 'comment', 'farmer note fallback'
    )
       or exists (
            select 1 from public.deal_reviews
            where batch_id = v_farmer_fallback_batch_id
              and reviewer_org_id = v_farmer_org_id
       )
       or (select notes from public.batches where id = v_farmer_fallback_batch_id)
              is distinct from v_fallback_notes_before then
        raise exception 'ARS-360: farmer legacy fallback is not canonical-absent and side-effect free';
    end if;

    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_mpk_a_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    select e.value into v_pool_match
    from jsonb_array_elements(public.rpc_get_pool_matches(v_pool_a_id)) e
    where e.value->>'batchId' = v_projection_batch_id::text;
    execute 'reset role';
    if v_pool_match is null or (v_pool_match->>'myRating')::int <> 4 then
        raise exception 'ARS-360: rpc_get_pool_matches did not prefer canonical MPK overall score';
    end if;

    select notes into v_mpk_fallback_notes_before
    from public.batches where id = v_mpk_fallback_batch_id;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_mpk_a_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    select e.value into v_pool_match
    from jsonb_array_elements(public.rpc_get_pool_matches(v_pool_a_id)) e
    where e.value->>'batchId' = v_mpk_fallback_batch_id::text;
    execute 'reset role';
    if v_pool_match is null or (v_pool_match->>'myRating')::int <> 3
       or exists (
            select 1 from public.deal_reviews
            where batch_id = v_mpk_fallback_batch_id
              and reviewer_org_id = v_mpk_a_org_id
       )
       or (select notes from public.batches where id = v_mpk_fallback_batch_id)
              is distinct from v_mpk_fallback_notes_before then
        raise exception 'ARS-360: MPK legacy fallback is not canonical-absent and side-effect free';
    end if;

    -- A batch split between two distinct MPKs has no safe batch-wide canonical MPK
    -- identity.  The adapter must fail before it can alter the legacy payload.
    select notes into v_ambiguous_notes_before
    from public.batches where id = v_ambiguous_batch_id;
    v_error := null;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_mpk_a_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    begin
        perform public.rpc_self_submit_mpk_review(
            v_ambiguous_batch_id, 5, 5, 'ambiguous split must not write'
        );
        raise exception 'ARS-360: ambiguous MPK adapter write unexpectedly accepted';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
    end;
    execute 'reset role';
    if v_error not like 'AMBIGUOUS_MPK_COUNTERPARTY%'
       or exists (
            select 1 from public.deal_reviews
            where batch_id = v_ambiguous_batch_id
              and reviewer_role = 'mpk'
       )
       or (select notes from public.batches where id = v_ambiguous_batch_id)
              is distinct from v_ambiguous_notes_before then
        raise exception 'ARS-360: ambiguous MPK adapter write was not safely quarantined';
    end if;

    -- The farmer direction is fail-closed too: a batch-scoped farmer review cannot
    -- be safely attributed when delivered allocations name multiple MPKs.
    v_error := null;
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_farmer_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    begin
        perform public.rpc_submit_review(
            v_ambiguous_batch_id, 5, 4, 'ambiguous farmer split must not write'
        );
        raise exception 'ARS-360: ambiguous farmer adapter write unexpectedly accepted';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
    end;
    execute 'reset role';
    if v_error not like 'AMBIGUOUS_MPK_COUNTERPARTY%'
       or exists (
            select 1 from public.deal_reviews where batch_id = v_ambiguous_batch_id
       )
       or (select notes from public.batches where id = v_ambiguous_batch_id)
              is distinct from v_ambiguous_notes_before then
        raise exception 'ARS-360: ambiguous farmer adapter write was not safely quarantined';
    end if;

    -- -------------------------------------------------------------------------
    -- Public reputation is aggregate-only and must not disclose unrevealed facts
    -- or re-attribute a review via batches.pool_line_id when allocations disagree.
    -- At this point MPK A has exactly two revealed farmer reviews, both overall 5
    -- and weight_accuracy 4: the adapter pair and projection fixture.
    -- -------------------------------------------------------------------------
    select public.rpc_get_mpk_reputation(v_mpk_a_org_id) into v_reputation;
    if v_reputation is null
       or v_reputation->>'mpk_org_id' <> v_mpk_a_org_id::text
       or coalesce((v_reputation->>'review_count')::int, -1) <> 2
       or coalesce((v_reputation->>'average_score')::numeric, -1) <> 5
       or coalesce((v_reputation->>'weight_accuracy_average')::numeric, -1) <> 4
       or not (v_reputation ? 'distribution')
       or v_reputation ?| array[
            'batch_id', 'batch_ids', 'reviewer_org_id', 'reviewer_role',
            'comment', 'comments', 'raw_payload', 'reviews'
       ] then
        raise exception 'ARS-360: MPK reputation leaks detail or includes hidden/wrong-target reviews: %',
            v_reputation;
    end if;

    perform set_config('request.jwt.claims', jsonb_build_object('role', 'anon')::text, true);
    execute 'set local role anon';
    select public.rpc_get_mpk_reputation(v_mpk_a_org_id) into v_reputation_anon;
    execute 'reset role';
    if v_reputation_anon is distinct from v_reputation then
        raise exception 'ARS-360: anon reputation aggregate differs from the sanitized public result';
    end if;

    select public.rpc_get_mpk_reputation(v_mpk_b_org_id) into v_reputation;
    if v_reputation is null
       or v_reputation->>'mpk_org_id' <> v_mpk_b_org_id::text
       or coalesce((v_reputation->>'review_count')::int, -1) <> 1
       or coalesce((v_reputation->>'average_score')::numeric, -1) <> 2 then
        raise exception 'ARS-360: reputation did not use delivered allocations as the MPK attribution source';
    end if;

    -- -------------------------------------------------------------------------
    -- Rerunnable backfill.  Existing canonical facts win; malformed, premature,
    -- ambiguous, and missing-dimension facts reconcile rather than guess.
    -- -------------------------------------------------------------------------
    perform set_config(
        'request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true
    );
    select public.fn_backfill_legacy_deal_reviews() into v_result;
    if v_result is null or jsonb_typeof(v_result) <> 'object' then
        raise exception 'ARS-360: backfill helper must return a JSON object summary';
    end if;

    if not exists (
        select 1
        from public.deal_reviews dr
        join public.deal_review_dimension_scores ds on ds.deal_review_id = dr.id
        where dr.batch_id = v_backfill_pair_batch_id
          and dr.reviewer_org_id = v_farmer_org_id
          and dr.reviewer_role = 'farmer'
          and dr.overall_score = 5
          and dr.comment = 'backfill farmer pair'
          and ds.dimension_id = v_weight_dimension_id
          and ds.score = 4
    ) or not exists (
        select 1
        from public.deal_reviews dr
        join public.deal_review_dimension_scores ds on ds.deal_review_id = dr.id
        where dr.batch_id = v_backfill_pair_batch_id
          and dr.reviewer_org_id = v_mpk_a_org_id
          and dr.reviewer_role = 'mpk'
          and dr.overall_score = 3
          and dr.comment = 'backfill MPK pair'
          and ds.dimension_id = v_livestock_dimension_id
          and ds.score = 2
    ) or (
        select count(*)
        from public.deal_reviews
        where batch_id = v_backfill_pair_batch_id and visible_at is not null
    ) <> 2 then
        raise exception 'ARS-360: valid mutual legacy notes were not backfilled/revealed canonically';
    end if;

    if not exists (
        select 1
        from public.deal_reviews dr
        join public.deal_review_dimension_scores ds on ds.deal_review_id = dr.id
        where dr.batch_id = v_backfill_farmer_batch_id
          and dr.reviewer_org_id = v_farmer_org_id
          and dr.reviewer_role = 'farmer'
          and dr.overall_score = 4
          and dr.comment = 'backfill farmer only'
          and dr.visible_at is null
          and ds.dimension_id = v_weight_dimension_id
          and ds.score = 3
    ) then
        raise exception 'ARS-360: one-sided farmer legacy review was not backfilled privately';
    end if;

    if (
        select count(*)
        from public.deal_reviews dr
        join public.deal_review_dimension_scores ds on ds.deal_review_id = dr.id
        where dr.batch_id = v_backfill_mpk_duplicate_batch_id
          and dr.reviewer_org_id = v_mpk_a_org_id
          and dr.reviewer_role = 'mpk'
          and dr.overall_score = 2
          and dr.comment = 'backfill MPK duplicate allocation'
          and dr.visible_at is null
          and ds.dimension_id = v_livestock_dimension_id
          and ds.score = 5
    ) <> 1 then
        raise exception 'ARS-360: same-MPK duplicate allocations were not deduplicated to one canonical review';
    end if;

    if not exists (
        select 1
        from public.deal_reviews dr
        join public.deal_review_dimension_scores ds on ds.deal_review_id = dr.id
        where dr.batch_id = v_existing_canonical_batch_id
          and dr.reviewer_org_id = v_farmer_org_id
          and dr.overall_score = 4
          and dr.comment = 'existing canonical wins'
          and ds.dimension_id = v_weight_dimension_id
          and ds.score = 3
    ) or (
        select count(*)
        from public.deal_reviews
        where batch_id = v_existing_canonical_batch_id
          and reviewer_org_id = v_farmer_org_id
    ) <> 1 or exists (
        select 1
        from public.deal_review_legacy_reconciliation
        where batch_id = v_existing_canonical_batch_id and legacy_key = 'review'
    ) then
        raise exception 'ARS-360: existing canonical review did not win over the legacy payload';
    end if;

    select raw_payload
      into v_report_payload
    from public.deal_review_legacy_reconciliation
    where batch_id = v_invalid_backfill_batch_id
      and legacy_key = 'review'
      and reason_code = 'invalid_rating';
    if v_report_payload is distinct from v_bad_payload
       or exists (
            select 1 from public.deal_reviews
            where batch_id = v_invalid_backfill_batch_id
       ) then
        raise exception 'ARS-360: malformed legacy review was not reconciled without a canonical write';
    end if;

    select raw_payload
      into v_report_payload
    from public.deal_review_legacy_reconciliation
    where batch_id = v_not_delivered_batch_id
      and legacy_key = 'review'
      and reason_code = 'batch_not_delivered';
    if v_report_payload is distinct from jsonb_build_object(
        'r1', 5, 'r2', 4, 'comment', 'not delivered'
    )
       or exists (
            select 1 from public.deal_reviews
            where batch_id = v_not_delivered_batch_id
       ) then
        raise exception 'ARS-360: non-delivered legacy review was not reconciled without a canonical write';
    end if;

    select raw_payload, candidate_counterparty_org_ids
      into v_report_payload, v_candidate_org_ids
    from public.deal_review_legacy_reconciliation
    where batch_id = v_ambiguous_batch_id
      and legacy_key = 'mpk_review'
      and reason_code = 'ambiguous_mpk_counterparty';
    if v_report_payload is distinct from v_ambiguous_payload
       or coalesce(cardinality(v_candidate_org_ids), 0) <> 2
       or not (v_candidate_org_ids @> array[v_mpk_a_org_id, v_mpk_b_org_id])
       or exists (
            select 1
            from public.deal_reviews
            where batch_id = v_ambiguous_batch_id and reviewer_role = 'mpk'
       ) then
        raise exception 'ARS-360: split-batch MPK legacy review was guessed instead of reconciled';
    end if;

    select raw_payload, candidate_counterparty_org_ids
      into v_report_payload, v_candidate_org_ids
    from public.deal_review_legacy_reconciliation
    where batch_id = v_ambiguous_batch_id
      and legacy_key = 'review'
      and reason_code = 'ambiguous_mpk_counterparty';
    if v_report_payload is distinct from v_ambiguous_farmer_payload
       or coalesce(cardinality(v_candidate_org_ids), 0) <> 2
       or not (v_candidate_org_ids @> array[v_mpk_a_org_id, v_mpk_b_org_id])
       or exists (
            select 1
            from public.deal_reviews
            where batch_id = v_ambiguous_batch_id and reviewer_role = 'farmer'
       ) then
        raise exception 'ARS-360: split-batch farmer legacy review was guessed instead of reconciled';
    end if;

    -- The catalog remains mutable only to the service/admin authority.  Once the
    -- required pilot dimension is unavailable, valid-looking notes become a
    -- reconciliation item rather than an arbitrary dimension score.
    insert into public.batches (
        id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
        status, pool_line_id, matched_heads, delivered_at, notes
    ) values (
        v_unknown_dimension_batch_id, v_farmer_org_id, v_sku_id, 10, 400,
        date_trunc('month', current_date)::date, 'delivered', v_pool_line_a_id,
        10, now(), jsonb_build_object(
            'review', jsonb_build_object('r1', 4, 'r2', 4, 'comment', 'dimension disabled')
        )::text
    );
    insert into public.batch_allocations (
        batch_id, pool_line_id, pool_id, heads, price_per_kg, status, delivered_at
    ) values (
        v_unknown_dimension_batch_id, v_pool_line_a_id, v_pool_a_id, 10, 1200, 'delivered', now()
    );
    update public.review_dimensions
       set is_active = false
     where id = v_weight_dimension_id;

    perform public.fn_backfill_legacy_deal_reviews();
    if not exists (
        select 1
        from public.deal_review_legacy_reconciliation
        where batch_id = v_unknown_dimension_batch_id
          and legacy_key = 'review'
          and reason_code = 'unknown_dimension'
          and raw_payload = jsonb_build_object(
              'r1', 4, 'r2', 4, 'comment', 'dimension disabled'
          )
    ) or exists (
        select 1
        from public.deal_reviews
        where batch_id = v_unknown_dimension_batch_id
    ) then
        raise exception 'ARS-360: inactive pilot dimension did not reconcile legacy payload';
    end if;

    v_fixture_batch_ids := array[
        v_adapter_batch_id, v_invalid_write_batch_id, v_projection_batch_id,
        v_farmer_fallback_batch_id, v_mpk_fallback_batch_id,
        v_hidden_reputation_batch_id, v_wrong_target_batch_id,
        v_backfill_pair_batch_id, v_backfill_farmer_batch_id,
        v_backfill_mpk_duplicate_batch_id, v_existing_canonical_batch_id,
        v_invalid_backfill_batch_id, v_not_delivered_batch_id,
        v_ambiguous_batch_id, v_unknown_dimension_batch_id
    ];

    select count(*) into v_review_count_before_retry
    from public.deal_reviews where batch_id = any(v_fixture_batch_ids);
    select count(*) into v_score_count_before_retry
    from public.deal_review_dimension_scores ds
    join public.deal_reviews dr on dr.id = ds.deal_review_id
    where dr.batch_id = any(v_fixture_batch_ids);
    select count(*) into v_reconciliation_count_before_retry
    from public.deal_review_legacy_reconciliation
    where batch_id = any(v_fixture_batch_ids);
    select coalesce(jsonb_agg(
        jsonb_build_object('id', b.id, 'notes', b.notes) order by b.id
    ), '[]'::jsonb)
      into v_notes_snapshot_before_retry
    from public.batches b
    where b.id = any(v_fixture_batch_ids);

    -- A final retry must leave all canonical rows, scores, report row cardinality,
    -- and legacy raw notes unchanged.  The unique report key is exercised by
    -- repeat observation, not merely inspected from pg_catalog.
    perform public.fn_backfill_legacy_deal_reviews();

    select coalesce(jsonb_agg(
        jsonb_build_object('id', b.id, 'notes', b.notes) order by b.id
    ), '[]'::jsonb)
      into v_notes_snapshot_after_retry
    from public.batches b
    where b.id = any(v_fixture_batch_ids);

    if (
        select count(*) from public.deal_reviews
        where batch_id = any(v_fixture_batch_ids)
    ) <> v_review_count_before_retry
       or (
            select count(*)
            from public.deal_review_dimension_scores ds
            join public.deal_reviews dr on dr.id = ds.deal_review_id
            where dr.batch_id = any(v_fixture_batch_ids)
       ) <> v_score_count_before_retry
       or (
            select count(*)
            from public.deal_review_legacy_reconciliation
            where batch_id = any(v_fixture_batch_ids)
       ) <> v_reconciliation_count_before_retry
       or v_notes_snapshot_after_retry is distinct from v_notes_snapshot_before_retry
       or exists (
            select 1
            from public.deal_review_legacy_reconciliation
            where batch_id = any(v_fixture_batch_ids)
            group by batch_id, legacy_key
            having count(*) > 1
       ) then
        raise exception 'ARS-360: legacy backfill is not idempotent for fixture data';
    end if;
end;
$$;

rollback;
