-- ============================================================
-- TSP MATCHING HAPPY-PATH — runtime FSM test (TSP-FLOW-01/03, TSP-SCHEMA-02)
-- ============================================================
-- Proves the M4/M6 sell flow is reachable end-to-end after the fix:
--   create_batch(draft) -> set_batch_terms(price+window) -> publish_batch
--   -> create_pool + publish_pool (broadcast) -> batch becomes 'offering'
--   -> accept_offer -> batch 'matched' (-> pool auto-close -> 'confirmed')
--
-- HOW TO RUN (no schema mutation persists — wrapped in a rolled-back tx):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/tsp_happy_path_test.sql
--   or via psycopg2: execute the file inside one transaction, then ROLLBACK.
-- The DO block raises 'TSP_TEST_PASS' on success (forces rollback) or a
-- 'TSP_TEST_FAIL: ...' assertion on the first broken step.
--
-- PRE-FIX EXPECTATION: fails at the publish_pool step (batch stays 'published',
--   never 'offering') or at accept_offer ('INVALID_STATUS: batch is published').
-- POST-FIX EXPECTATION: raises 'TSP_TEST_PASS'.
--
-- NOTE: requires the fixed d02_tsp.sql applied to the target DB. To test
-- WITHOUT persisting the function change, apply the two CREATE OR REPLACE
-- (rpc_retry_match_pool, rpc_set_batch_terms) at the top of the same tx, then
-- this block, then ROLLBACK — the function defs roll back too.
-- ============================================================

begin;

do $$
declare
    v_farmer_org  uuid;
    v_mpk_org     uuid;
    v_farm        uuid;
    v_region      uuid;
    v_sku         uuid;
    v_batch       uuid;
    v_pool        uuid;
    v_offer       uuid;
    v_status      text;
    v_price       int := 1200;          -- farmer ask, KZT/kg
    r             jsonb;
begin
    -- ---- discover reference rows from the deployed DB ----
    select id into v_farmer_org from public.organizations order by created_at limit 1;
    select id into v_mpk_org   from public.organizations
        where id <> v_farmer_org order by created_at limit 1;
    select id into v_farm  from public.farms where organization_id = v_farmer_org limit 1;
    select id into v_region from public.regions where level = 'rayon' limit 1;
    select id into v_sku   from public.tsp_skus limit 1;

    if v_farmer_org is null or v_mpk_org is null or v_farm is null
       or v_region is null or v_sku is null then
        raise exception 'TSP_TEST_SETUP: need >=2 orgs, a farm, a rayon region, a tsp_sku in the DB (got farmer=%, mpk=%, farm=%, region=%, sku=%)',
            v_farmer_org, v_mpk_org, v_farm, v_region, v_sku;
    end if;

    -- ---- 1) farmer creates a draft batch ----
    r := public.rpc_create_batch(
            p_organization_id => v_farmer_org, p_farm_id => v_farm,
            p_tsp_sku_id => v_sku, p_heads => 10, p_avg_weight_kg => 400,
            p_region_id => v_region);
    v_batch := (r->>'batch_id')::uuid;

    -- ---- 2) set terms (price + ready window) — the TSP-FLOW-03 unblock ----
    perform public.rpc_set_batch_terms(
            p_organization_id => v_farmer_org, p_batch_id => v_batch,
            p_farmer_price_per_kg => v_price,
            p_ready_from => current_date + 30, p_ready_to => current_date + 60);

    -- ---- 3) publish the batch ----
    perform public.rpc_publish_batch(
            p_organization_id => v_farmer_org, p_batch_id => v_batch);
    select status into v_status from public.batches where id = v_batch;
    if v_status <> 'published' then
        raise exception 'TSP_TEST_FAIL: after publish_batch status=% (expected published)', v_status;
    end if;

    -- ---- 4) MPK creates a pool whose line accepts this batch, then publishes ----
    --        (rpc_create_pool handles pool_request/line/region wiring internally;
    --         line mpk_price >= farmer price, region covers batch region, window overlaps)
    r := public.rpc_create_pool(
            p_organization_id => v_mpk_org,
            p_total_target_volume_kg => 4000,
            p_delivery_from => current_date + 20, p_delivery_to => current_date + 70,
            p_pool_lines  => jsonb_build_array(jsonb_build_object(
                            'tsp_sku_id', v_sku, 'mpk_price_per_kg', v_price + 100,
                            'max_volume_kg', 8000)),
            p_pool_regions => jsonb_build_array(jsonb_build_object(
                            'region_type', 'rayon', 'region_id', v_region)));
    v_pool := (r->>'pool_id')::uuid;
    perform public.rpc_publish_pool(p_organization_id => v_mpk_org, p_pool_id => v_pool);

    -- ---- 5) ASSERT THE FIX: published batch transitioned to 'offering' ----
    select status into v_status from public.batches where id = v_batch;
    if v_status <> 'offering' then
        raise exception 'TSP_TEST_FAIL (TSP-FLOW-01): after publish_pool batch status=% (expected offering — broadcast did not transition FSM)', v_status;
    end if;

    -- ---- 6) MPK accepts the pending offer (previously unreachable) ----
    select id into v_offer from public.offers
        where batch_id = v_batch and mpk_org_id = v_mpk_org and status = 'pending' limit 1;
    if v_offer is null then
        raise exception 'TSP_TEST_FAIL: no pending offer for batch (broadcast did not create one)';
    end if;
    perform public.rpc_accept_offer(p_organization_id => v_mpk_org, p_offer_id => v_offer);

    -- ---- 7) ASSERT: batch matched (or confirmed if pool auto-closed) ----
    select status into v_status from public.batches where id = v_batch;
    if v_status not in ('matched', 'confirmed') then
        raise exception 'TSP_TEST_FAIL: after accept_offer batch status=% (expected matched|confirmed)', v_status;
    end if;

    raise exception 'TSP_TEST_PASS: happy path reachable (batch % final status=%)', v_batch, v_status;
end $$;

rollback;
-- ============================================================
-- Caveats: rpc_create_pool param names above follow the deployed M4 signature
-- (Dok 3 §4a). If they differ in your build, adjust the named args — the
-- assertions (steps 5 & 7) are the contract under test, not the seed calls.
-- ============================================================
