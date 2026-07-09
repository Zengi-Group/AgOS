-- ============================================================
-- TSP ADMIN write-RPC — runtime gate + FSM + reveal test (ARS-194 / ARS-195..199)
-- ============================================================
-- Proves the admin operator surface (SECTION 11 of d02_tsp.sql) behaves per canon:
--   1) admin gate: a NON-admin caller is rejected with FORBIDDEN (fn_is_admin)
--   2) rpc_admin_match_batch_to_pool: batch published|offering -> matched into the
--      best line (max mpk_price), deal_price = line MPK bid (D-M6-DEALPRICE),
--      capacity/window/region/sku predicate honored, matched_heads credited,
--      and contacts are NOT revealed yet (D-M6-5/12)
--   3) rpc_admin_unmatch: matched -> published, line volume + matched_heads rolled back
--   4) rpc_admin_advance_pool_status -> closed_filled: matched batch -> confirmed AND
--      pool.mpk_contact_revealed_at set (reveal happens ONLY here, not at match)
--   5) FSM guard: rpc_admin_cancel_batch on a confirmed batch -> INVALID_STATUS
--
-- HOW TO RUN (no schema/data mutation persists — wrapped in a rolled-back tx):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/tsp_admin_rpc_test.sql
--   or via psycopg2: execute the file in one transaction, then ROLLBACK.
-- The DO block raises 'TSP_ADMIN_TEST_PASS' on success (forces rollback) or a
-- 'TSP_ADMIN_TEST_FAIL: ...' assertion on the first broken step. Setup problems
-- raise 'TSP_ADMIN_TEST_SETUP: ...' (missing reference rows / no admin user).
--
-- REQUIRES: d02_tsp.sql SECTION 11 applied to the target DB, plus >=1 active
-- admin_roles row and >=1 non-admin user (for the gate assertions).
--
-- @case ADMIN-TSP-01 (gate) ADMIN-TSP-02 (match) ADMIN-TSP-03 (unmatch)
--       ADMIN-TSP-04 (reveal-on-confirmed) ADMIN-TSP-05 (fsm-guard)
-- ============================================================

begin;

do $$
declare
    v_farmer_org   uuid;
    v_mpk_org      uuid;
    v_mpk_auth_id  uuid;   -- MPK-org member auth_id (rpc_create_pool checks fn_my_org_ids)
    v_admin_auth   uuid;   -- active admin_roles user auth_id (fn_is_admin)
    v_nonadmin     uuid;   -- a user NOT in admin_roles (gate negative)
    v_farm         uuid;
    v_region       uuid;
    v_sku          uuid;
    v_batch        uuid;
    v_pool         uuid;
    v_line         uuid;
    v_status       text;
    v_deal         int;
    v_reveal       timestamptz;
    v_vol          int;
    v_matched0     int;   -- pool.matched_heads before match
    v_price        int := 1200;   -- farmer ask, KZT/kg
    v_bid          int := 1300;   -- MPK bid (>= ask) -> expected deal price
    v_ok           boolean;
    v_admin_claims text;
begin
    -- ---- discover reference rows from the deployed DB ----
    select id into v_farmer_org from public.organizations order by created_at limit 1;
    select id into v_mpk_org from public.organizations
        where id <> v_farmer_org order by created_at limit 1;
    select id into v_farm   from public.farms where organization_id = v_farmer_org limit 1;
    select id into v_region from public.regions where level in ('rayon','oblast') order by level limit 1;
    select id into v_sku    from public.tsp_skus limit 1;
    select u.auth_id into v_mpk_auth_id
        from public.users u
        join public.user_organization_roles uor on u.id = uor.user_id
        where uor.organization_id = v_mpk_org limit 1;
    select u.auth_id into v_admin_auth
        from public.admin_roles ar
        join public.users u on u.id = ar.user_id
        where ar.is_active = true limit 1;
    select u.auth_id into v_nonadmin
        from public.users u
        where u.auth_id is not null
          and u.id not in (select user_id from public.admin_roles where is_active = true)
        limit 1;

    if v_farmer_org is null or v_mpk_org is null or v_farm is null
       or v_region is null or v_sku is null then
        raise exception 'TSP_ADMIN_TEST_SETUP: need >=2 orgs, a farm, a rayon/oblast region, a tsp_sku (got farmer=%, mpk=%, farm=%, region=%, sku=%)',
            v_farmer_org, v_mpk_org, v_farm, v_region, v_sku;
    end if;
    if v_mpk_auth_id is null then
        raise exception 'TSP_ADMIN_TEST_SETUP: no user in MPK org % (needed for pool JWT)', v_mpk_org;
    end if;
    if v_admin_auth is null then
        raise exception 'TSP_ADMIN_TEST_SETUP: no active admin_roles user (needed for fn_is_admin gate)';
    end if;
    if v_nonadmin is null then
        raise exception 'TSP_ADMIN_TEST_SETUP: no non-admin user found (needed for gate negative)';
    end if;

    v_admin_claims := json_build_object('sub', v_admin_auth::text, 'role', 'authenticated')::text;

    -- ---- seed: farmer published batch (mirrors happy-path steps 1-3) ----
    v_batch := (public.rpc_create_batch(
        p_organization_id => v_farmer_org, p_farm_id => v_farm,
        p_tsp_sku_id => v_sku, p_heads => 10, p_avg_weight_kg => 400,
        p_region_id => v_region)->>'batch_id')::uuid;
    perform public.rpc_set_batch_terms(
        p_organization_id => v_farmer_org, p_batch_id => v_batch,
        p_farmer_price_per_kg => v_price,
        p_ready_from => current_date + 30, p_ready_to => current_date + 60);
    perform public.rpc_publish_batch(
        p_organization_id => v_farmer_org, p_batch_id => v_batch);

    -- ---- seed: MPK pool (filling) whose line accepts this batch ----
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_mpk_auth_id::text, 'role', 'authenticated')::text, true);
    v_pool := (public.rpc_create_pool(
        p_organization_id => v_mpk_org,
        p_total_target_volume_kg => 4000,
        p_delivery_from => current_date + 20, p_delivery_to => current_date + 70,
        p_pool_lines  => jsonb_build_array(jsonb_build_object(
            'tsp_sku_id', v_sku, 'mpk_price_per_kg', v_bid, 'max_volume_kg', 8000)),
        p_pool_regions => jsonb_build_array(jsonb_build_object(
            'region_type', 'oblast', 'region_id', v_region)))->>'pool_id')::uuid;
    perform public.rpc_publish_pool(p_organization_id => v_mpk_org, p_pool_id => v_pool);
    select matched_heads into v_matched0 from public.pools where id = v_pool;

    -- ========================================================
    -- CASE ADMIN-TSP-01: gate — non-admin is rejected (FORBIDDEN)
    -- ========================================================
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_nonadmin::text, 'role', 'authenticated')::text, true);
    v_ok := false;
    begin
        perform public.rpc_admin_match_batch_to_pool(p_pool_id => v_pool, p_batch_id => v_batch);
    exception when others then
        if sqlerrm like 'FORBIDDEN%' then v_ok := true; else raise; end if;
    end;
    if not v_ok then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-01): non-admin was NOT blocked by fn_is_admin gate';
    end if;

    -- switch to admin context for the remaining cases
    perform set_config('request.jwt.claims', v_admin_claims, true);

    -- ========================================================
    -- CASE ADMIN-TSP-02: match — batch -> matched, deal = bid, NO reveal
    -- ========================================================
    perform public.rpc_admin_match_batch_to_pool(p_pool_id => v_pool, p_batch_id => v_batch);
    select status, deal_price_per_kg, pool_line_id into v_status, v_deal, v_line
        from public.batches where id = v_batch;
    if v_status <> 'matched' then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-02): batch status=% (expected matched)', v_status;
    end if;
    if v_deal <> v_bid then
        raise exception 'TSP_ADMIN_TEST_FAIL (D-M6-DEALPRICE): deal_price=% (expected % = MPK bid, not % ask)',
            v_deal, v_bid, v_price;
    end if;
    select current_volume_kg into v_vol from public.pool_lines where id = v_line;
    if v_vol <> 10 * 400 then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-02): line volume=% (expected 4000)', v_vol;
    end if;
    select matched_heads into v_status from public.pools where id = v_pool;
    if v_status::int <> v_matched0 + 10 then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-02): matched_heads=% (expected %)',
            v_status, v_matched0 + 10;
    end if;
    select mpk_contact_revealed_at into v_reveal from public.pools where id = v_pool;
    if v_reveal is not null then
        raise exception 'TSP_ADMIN_TEST_FAIL (D-M6-5/12): contacts revealed at MATCH (mpk_contact_revealed_at=%) — must reveal only at confirmed', v_reveal;
    end if;

    -- ========================================================
    -- CASE ADMIN-TSP-03: unmatch — rollback to published, volumes released
    -- ========================================================
    perform public.rpc_admin_unmatch(p_pool_id => v_pool, p_batch_id => v_batch);
    select status into v_status from public.batches where id = v_batch;
    if v_status <> 'published' then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-03): after unmatch batch status=% (expected published)', v_status;
    end if;
    select current_volume_kg into v_vol from public.pool_lines where id = v_line;
    if v_vol <> 0 then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-03): line volume=% after unmatch (expected 0)', v_vol;
    end if;
    select matched_heads into v_status from public.pools where id = v_pool;
    if v_status::int <> v_matched0 then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-03): matched_heads=% after unmatch (expected %)',
            v_status, v_matched0;
    end if;

    -- ========================================================
    -- CASE ADMIN-TSP-04: re-match then advance -> closed_filled reveals contacts
    -- ========================================================
    perform public.rpc_admin_match_batch_to_pool(p_pool_id => v_pool, p_batch_id => v_batch);
    perform public.rpc_admin_advance_pool_status(p_pool_id => v_pool, p_new_status => 'closed_filled');
    select status into v_status from public.batches where id = v_batch;
    if v_status <> 'confirmed' then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-04): batch status=% after closed_filled (expected confirmed)', v_status;
    end if;
    select mpk_contact_revealed_at into v_reveal from public.pools where id = v_pool;
    if v_reveal is null then
        raise exception 'TSP_ADMIN_TEST_FAIL (D-M6-5/12): contacts NOT revealed after closed_filled (mpk_contact_revealed_at is null)';
    end if;

    -- ========================================================
    -- CASE ADMIN-TSP-05: FSM guard — cannot admin-cancel a confirmed batch
    -- ========================================================
    v_ok := false;
    begin
        perform public.rpc_admin_cancel_batch(p_batch_id => v_batch);
    exception when others then
        if sqlerrm like 'INVALID_STATUS%' then v_ok := true; else raise; end if;
    end;
    if not v_ok then
        raise exception 'TSP_ADMIN_TEST_FAIL (ADMIN-TSP-05): admin-cancel of confirmed batch was NOT blocked by FSM guard';
    end if;

    raise exception 'TSP_ADMIN_TEST_PASS: gate + match/unmatch + reveal-on-confirmed + FSM guard all hold (batch %, pool %)', v_batch, v_pool;
end $$;

rollback;
-- ============================================================
-- Caveats: seed RPC param names follow the deployed M4/M6 signatures
-- (Dok 3 §4a) — mirror tests/tsp_happy_path_test.sql. The assertions
-- (CASE blocks), not the seed calls, are the contract under test.
-- ============================================================
