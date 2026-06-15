# AGOS Sprint Status

> Last updated: 2026-04-09 by Architect (WeightCalc module D-WEIGHT-1/2)

---

## Completed Slices

| Slice | Gate | Date |
|-------|------|------|
| Slice 0 — Foundation | DB Gate | 2026-03-17 |
| Slice 1 — Sick Calf | D-GATE-S1 | 2026-03-19 |
| Slice 2 — Membership | D-GATE-S2 | 2026-03-19 |
| Slice 3 — Feed Planning | D-GATE-S3 | 2026-03-30 |
| Slice 4 — Operations | D-GATE-S4 | 2026-03-30 |
| Slice 6a — Expert Console | D-GATE-S6a | 2026-03-31 |
| Slice 5a — Market Farmer | D-GATE-S5a | 2026-04-01 |
| Slice 5b — Market Admin | D-GATE-S5b | 2026-04-01 |

## Deployed Infrastructure

| Component | URL/Status |
|-----------|------------|
| Frontend (Vercel) | https://ag-os.vercel.app |
| AI Gateway (Railway) | https://agos-production.up.railway.app |
| Supabase | mwtbozflyldcadypherr (ap-south-1) |
| Edge Functions | calculate-ration, get-feed-budget (ACTIVE) |

## Screens (40 total)

| Series | Count | Screens |
|--------|-------|---------|
| Farmer (F) | 20 | F01-F04, F05-F08, F10-F12, F15-F23 |
| Admin (A) | 14 | A01-A05, AdminDashboard + PoolQueue, PoolDetail, PriceGridManagement, UserManagement, RoleAssignment, OrgManagement, RegionDirectory, SystemSettings |
| Expert (M) | 6 | M01-M06 |

## RPCs Deployed (26+)

Slice 1: RPC-01,02,04,05/05b,25,26,27,40 + AI-01..23
Slice 2: RPC-03, rpc_get_membership_queue
Slice 3: RPC-07,08,21-24
Slice 4: RPC-37
Slice 5a: RPC-11..13 + 3 price/sku RPCs + AI-16..21 market tools (3 RPCs, 9 AI tools, 4 screens)
Slice 5b: RPC-14..20 + pool/pricing management (7 RPCs, DEF-021..026 resolved)
Slice 6a: RPC-28,29,31,32,44,45 + rpc_activate_vaccination_plan
In progress: rpc_list_vaccination_plans, rpc_list_vaccination_plan_items, rpc_list_vaccines (READ-RPCs, d04)

## M4+M6 RPCs — DEPLOYED ✅ (Section 8, d02_tsp.sql, 14 functions)

Migrations applied 2026-06-15:
- `d02_tsp_section7_m4_m6_extension` (schema)
- `d02_tsp_section8_m4_m6_rpcs` (initial 12 RPCs)
- `d02_tsp_addendum_a_pools_org_id_column` (DEF-TSP-M4-OWNERSHIP resolution)
- `d02_tsp_addendum_b_rpc_refactor_and_new` (refactor 8 RPCs + `rpc_retry_match_pool` + `rpc_cancel_pool`)

| Function | Caller | FSM |
|----------|--------|-----|
| rpc_create_pool | MPK | Pool draft + N lines + M regions (atomic) — uses `pools.organization_id` directly |
| rpc_publish_pool | MPK | pools: draft → filling, inline call to rpc_retry_match_pool |
| rpc_retry_match_pool | system | Q-TSP-RETRY-MATCH/BT-05: scan published batches, broadcast Offers; idempotent |
| rpc_accept_offer | MPK | FCFS accept, withdraw siblings, batch → matched, auto-close |
| rpc_reject_offer | MPK | offer → rejected |
| rpc_lower_batch_price | Farmer | awaiting_price_decision → offering, re-broadcast |
| rpc_confirm_dispatch | Farmer | batch: confirmed → dispatched (D-M6-10) |
| rpc_confirm_delivery | MPK | batch: dispatched → delivered (D-M6-10) |
| rpc_submit_deal_review | Farmer ∨ MPK | deal_reviews + dimension; double-blind reveal |
| rpc_pool_return_batches | MPK | awaiting_mpk_decision → closed_unfilled; matched → published |
| rpc_cancel_pool | MPK | filling → cancelled; withdraw offers, return matched batches |
| rpc_pool_accept_partial | MPK | awaiting_mpk_decision → closed_partial; matched → confirmed |
| rpc_get_reference_price | any | STABLE read + mandatory disclaimer (Art.171) |
| rpc_get_minimum_price | any | STABLE read + mandatory disclaimer (Art.171) |

Status: ✅ **deployed 2026-06-15** (migration `d02_tsp_section8_m4_m6_rpcs`). Prod-verify: 12/12 functions in information_schema, 12/12 in rpc_name_registry, 12/12 SECURITY DEFINER + search_path. Smoke-test on rpc_get_minimum_price / rpc_get_reference_price ✓ (disclaimers returned).

## Blocked / Deferred

| Slice | Status | Note |
|-------|--------|------|
| Slice 6b (Admin A06-A10) | DEFERRED | Low priority; after farmer feedback (D-S6-3) |
| Slice 7 (Education) | READY | Next slice to implement |

## In Progress (unstaged changes)

| What | Files | Status |
|------|-------|--------|
| READ-RPCs для expert screens (замена прямых .from() запросов) | `d04_vet.sql` (+178 строк), `EpidemicSignals.tsx`, `ExpertKpi.tsx`, `RecordVaccination.tsx`, `VaccinationPlans.tsx`, `Sidebar.tsx`, `AdminDashboard.tsx` | Не закоммичены |
| WeightCalc модуль — динамический расчёт веса реализации (D-WEIGHT-1) | `weight_model.py` (NEW), `schemas.py`, `input_params.py`, `orchestrator.py`, `revenue.py` | Не закоммичен |

## Open Tech Debt

| ID | Severity | Description |
|----|----------|-------------|
| DEF-009 | Known | fn_my_org_ids/fn_is_admin/fn_is_expert dual defs (d01 naive + d07 JWT) |
| DEF-023 | Low | Farmer pages .from() on reference tables |
| S-1 | Significant | rpc_start_production_plan missing p_organization_id |
| S-2/S-3 | Significant | Seed ON CONFLICT without UNIQUE (nutrient_requirements, epidemic_thresholds) |
