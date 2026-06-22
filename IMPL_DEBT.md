# IMPLEMENTATION DEBT — AgOS (code ≠ canon)

> Source: DOC_DRIFT_AUDIT-2026-06-22.md (adversarially verified). Generated as part of Doc-Reconciliation Phase 1.
> These are CODE gaps. Phase 1 (docs) does not fix them. Each is a Phase-2 work item; keep the audit id when actioned.
> Authority model: microsteps = canon (Identity/Membership/Governance/TSP); Doks = canon elsewhere; code = reality.
> Article-171 / data-isolation leak VET-02 is being fixed out-of-band (spawned task task_bf722ce0) — see note below.

## 🔴 Breaking (12)

| id | domain | conflict | what | evidence | action |
|----|--------|----------|------|----------|--------|
| AI-GATEWAY-01 | AI Gateway | code↔canon | nodes.py calls rpc_update_confirmation_payload — exists in no SQL; two-run amend raises at runtime | ai_gateway/nodes.py:262 | Add rpc_update_confirmation_payload(p_organization_id,p_conversation_id,p_payload jsonb) to d07 + registry, OR repoint nodes.py amend |
| TSP-SCHEMA-01 | TSP-schema | code lags | rpc_create_batch / rpc_publish_batch missing from code though Dok3 marks them Implemented | d02_tsp.sql (no defs); Dok3:71-72 | Implement per M4 §2.2 (auto-match→broadcast→published, BT-01/02/03); Dok3 status corrected in Task 7 regardless |
| TSP-SCHEMA-02 | TSP-schema | code↔canon | BT-05 broadcast leaves batch 'published' but rpc_accept_offer requires 'offering' — Offers un-acceptable | d02_tsp.sql:2491-2493,2706-2709,3035 | Set offering on retry-match Offer upsert, OR implement BT-05 as direct published→matched per M4 §3.3 |
| TSP-FLOW-01 | TSP-flow | code↔canon | Published batch can never reach 'offering' → FCFS accept unreachable on happy path | d02_tsp.sql:2491-2493,2706-2709,3035 | rpc_retry_match_pool/rpc_publish_pool set published→offering (offering_at + market.batch.offering + offering_started) on Offer create |
| TSP-FLOW-02 | TSP-flow | code lags | rpc_publish_batch is pre-M6: single 'published' path, no soft-warn/classifier-lock/scheduled_publish_at/branch | d07_ai_gateway.sql:1272-1300 | Rewrite to M6 contract (soft-warn vs minimum_price, lock classifier_version, scheduled_publish_at, branch scheduled/matched/offering/published) |
| VET-02 | Veterinary | code↔canon | rpc_get_vet_case_detail trusts client p_organization_id, no fn_my_org_ids() guard — cross-org leak (Art.171) | d04_vet.sql:1815-1845 | **✅ FIXED** on branch `fix/vet-f11-isolation` (commit `4a961c9`), guard added, cross_check 0/0/0. **PENDING DEPLOY** to Supabase. |
| FEED-05 | feed | code↔canon | feed_consumption_norms seed INSERT precedes its CREATE TABLE — fresh apply of d03 fails | d03_feed.sql:839 seed, 1579 CREATE | Move CREATE TABLE (+fcn_unique_norm) above the seed, or relocate seed after 1620 |
| IDENTITY-07 | identity | code↔canon | RoleSelect emits org-type 'services'/'feed_producer' → SQL CHECK + INVALID_ORG_TYPE; registration broken for those roles | constants.ts:125; d01_kernel.sql:238,3320 | Map services→supplier, feed_producer→supplier (or extend OrganizationType set per IDENTITY-06), verify vs deployed CHECK |
| MARKET-UI-04 | market-ui | code↔canon | Admin pool via rpc_activate_pool_request leaves pools.organization_id NULL → M4 ownership invariant break | d02_tsp.sql:1995-1999; PoolQueue.tsx | Migrate PoolQueue to rpc_create_pool, OR backfill organization_id in rpc_activate_pool_request |
| MEMBERSHIP-01 | membership | code↔canon | Deployed memberships uses deleted 4-level stack, not canon 6-state FSM; no state/grace/tier columns | d01_kernel.sql:289-296 | Additively add state + grace_reason/grace_until/paid_until/tier/revoke_reason/state_changed_at per Microstep2 §4 (A1) |
| MEMBERSHIP-02 | membership | code↔canon | Code requires pre-existing membership row at submit + FK membership_id NOT NULL; canon: row created at T2 approve | d01_kernel.sql:3480-3483,339 | Make membership_applications org-anchored (drop NOT NULL FK); approve(T2) creates row in grace_period |
| MEMBERSHIP-03 | membership | code lags | grace_period/expired/revoked + transitions T4-T10 + MembershipStateTransition log unimplemented | canon Microstep2 §3,§7 | Backlog billing-driven (T4/T7/T9) + cron-driven (T5/T6/T8) + admin revoke (T10) + audit table |

## 🟠 Significant (subset — 30)

| id | domain | conflict | what | action |
|----|--------|----------|------|--------|
| AI-GATEWAY-02 | AI Gateway | code↔canon | Python tool names diverge from Dok5 names (market/expert) | Apply A3: keep SQL/RPC names, add map layer; Dok5 = LLM-tool-name canon (Task 9) |
| AI-GATEWAY-03 | AI Gateway | code lags | consultant role empty tool set; search_knowledge/escalate/get_membership_status/get_subsidy_programs missing | Implement consultant tools + search_knowledge for all roles, OR mark Planned in Dok5 |
| AI-GATEWAY-04 | AI Gateway | code↔canon | zootech tools differ from canon get_farm_context/update_herd_group/create_herd_group | Wire canon write tools into zootech set, OR ratify deployed set in Dok5 |
| AI-GATEWAY-05 | AI Gateway | code lags | compliance.py missing CF-04 (cross-org BLOCK) + CF-03 (epidemic alert) | Implement CF-04 (P-AI-2 last line) + CF-03, OR downgrade in Dok5 §8 with rationale |
| AI-GATEWAY-06 | AI Gateway | code↔canon | price disclaimer keys on canon names never emitted → fires only for get_price_grid | Add real emitted names to price_tools set (gated by A3 / AI-GATEWAY-02) |
| CONSULTING-03 | Consulting | code lags | inverted pasture-season interval validation not enforced | Add CHECK(pasture_start_month<=pasture_end_month) + Pydantic model_validator |
| TSP-SCHEMA-03 | TSP-schema | code lags | 5 legacy pre-M4 pool_request/match RPCs still active, no deprecation flag | Mark deprecated (registry+comment), stop callers, remove after data migration (A6) |
| TSP-SCHEMA-04 | TSP-schema | code↔canon | rpc_cancel_batch blocks offering/awaiting_price_decision/matched + checks deprecated pool_matches | Extend to BT-10/12/15, withdraw Offers, write cancelled_after_match |
| TSP-FLOW-03 | TSP-flow | code lags | rpc_create_batch writes target_month, omits ready_from/ready_to/farmer_price_per_kg | Add/persist ready_from/ready_to(+farmer_price) per D-M6-6 so §2.3 overlap match works |
| TSP-FLOW-04 | TSP-flow | code lags | farmer cancel BT-10/BT-15 unimplemented; rpc_cancel_batch pre-M6 | Implement M6 cancel modes w/ pool_line/offers + events |
| TSP-FLOW-05 | TSP-flow | code lags | market.batch.confirmed (identity reveal, D-M6-5/12) declared in Dok4 but never emitted | Emit in rpc_accept_offer + rpc_pool_accept_partial w/ identity payload (A7) |
| TSP-FLOW-06 | TSP-flow | code↔canon | offer.created/withdrawn (Dok4) not emitted; code emits offer.accepted/rejected (not in Dok4) | Emit offer.created/withdrawn; Dok4 rows added in Task 8 (A5) |
| VET-03 | Veterinary | code↔canon | code emits 'vet.signal.detected', canon 'vet.epidemic_signal.detected' | Rename emitted literals (d08:166,376; d04:2551) to canon |
| VET-04 | Veterinary | code↔canon | vet.vet_case.opened / vet.vaccination.plan_created / vet.vaccination.completed ≠ Dok4 canon | Rename to vet.case.opened / vet.vaccination_plan.created / vet.vaccination_record.created |
| VET-07 | Veterinary | code lags | health-restriction trigger emits no vet.health_restriction.created (Dok4 V-06 dead) | Add platform_events INSERT in fn_create_health_restriction_from_rec |
| EDUCATION-02 | education | code↔canon | code emits 'education.enrollment.completed'; Dok4 canon edu.* (A4) | Emit edu.course.completed + edu.certificate.issued (+enrolled/lesson) |
| EDUCATION-03 | education | code lags | certificate issuance emits no distinct edu.certificate.issued | Split emissions on cert INSERT when Slice 7 built |
| FEED-04 | feed | code↔canon | F17 is 4-tab RationPage; canon F17/F18 RationViewer.tsx/FeedBudget.tsx orphaned | Decide: doc the tabbed UI (FEED, Task 12) OR re-route; remove dead code |
| GOVERNANCE-01 | governance | code lags | entire Feature Governance layer (M3) zero implementation | CEO-gated: implement M3 tables+RPC fail-closed, OR confirm deferred (see open question) |
| GOVERNANCE-02 | governance | code lags | rpc_check_feature_access does not exist | Implement w/ M3, fail-closed (D-FG-2), register canonical name |
| IDENTITY-01 | identity | code lags | AssociationMembership not renamed; table still `memberships` | Rename intent recorded; gated on Microstep2 FSM finalization (A1) |
| IDENTITY-02 | identity | code lags | PlatformSubscription table absent (canon MVP) | Implement table + tier='free' auto-create hook |
| IDENTITY-03 | identity | code lags | SubscriptionEvent append-only log absent | Add subscription_events table |
| IDENTITY-04 | identity | code lags | FeatureGate registry absent | Implement feature_gates + effective_access() (antitrust-relevant) |
| IDENTITY-05 | identity | code↔canon | canon mandates 3 registration RPCs; code keeps atomic rpc_register_organization | Split per D-IDM-6 (additive migration); Dok3 RPC-01 noted in Task 7 |
| IDENTITY-06 | identity | code↔canon | OrganizationType seed diverges (no service/education/government; no requires_approval) | Create organization_types ref table w/ requires_approval; align codes |
| IDENTITY-09 | identity | code↔canon | expert = expert_profiles table vs canon D-IDM-8 (User.expertise_areas[]) | A8: keep expert_profiles (HS-2); add expertise_areas if needed; canon ratified to reality (Task 14) |
| IDENTITY-11 | identity | code↔canon | onboarding intent (D-IDM-5) no storage; users.preferences missing | Add users.preferences jsonb; move intent off blocking role_select |
| MARKET-UI-01 | market-ui | code lags | A-CAT screens A-CAT-01..04 never built | Build 4 screens+layout+sidebar+routes, OR mark UI-pending (doc note in Task 11) |
| MARKET-UI-02 | market-ui | code lags | farmer batch UI old 5-state FSM; deployed has 11 M4/M6 states | Extend UI (offering/awaiting_price_decision+lower_batch_price/confirmed/dispatched/delivered) |
| MEMBERSHIP-04 | membership | code↔canon | rpc_submit_membership_application signature diverges (membership_type/notes vs documents[]) | Gated on A1: additive replacement RPC accepting documents[] |
| MEMBERSHIP-06 | membership | code↔canon | frontend membership_status = 4th vocabulary | Consolidate to canon AssociationMembership state (A1) |

## 🟡 Minor (11)

| id | domain | what | action |
|----|--------|------|--------|
| CONSULTING-06 | Consulting | Dok7 Фаза4 `activated` + rpc_activate_consulting_project unimplemented | Mark NOT-YET (deferred) in Dok7 (Task 13) — no code action |
| CONSULTING-07 | Consulting | SimpleRationEditor omits nutrients_met/deficiencies/solver_status/calc_* (ADR-FEED-06) | Persist fields OR annotate Dok7 §9.3 (Task 13) |
| TSP-SCHEMA-07 | TSP-schema | pool_matches/pool_manifests lack DEPRECATED comments | Add deprecation comments; resolve Q-TSP-MANIFEST-FATE |
| TSP-FLOW-09 | TSP-flow | auto-close 400kg target_heads heuristic is lossy placeholder | Document placeholder OR make target_heads nullable |
| VET-10 | Veterinary | vet_cases.severity DB default 'moderate' vs D-F10-1 'nullable, AI determines' | Drop default, set rpc default null |
| IDENTITY-10 | identity | EconomicActivityType eligibility ref (D-IDM-1) not implemented | Add economic_activity_types ref + organizations.economic_activity_type_ids[] |
| MARKET-UI-07 | market-ui | CAPEX routes moved to /admin/directories/capex/*; Dok6-Slice-CAPEX stale | Doc fix in Task 11 |
| OPERATIONS-04 | operations | RPC-37 deployed but canon/Dok3 say NOT IMPLEMENTED | Doc status flip (Tasks 7 & 12) |
| OPERATIONS-05 | operations | RPC-44 rpc_add_knowledge_chunk deployed but marked DEFERRED | Doc status flip (Tasks 7 & 12) |
| IDENTITY-13 | identity | DEF-009 fn_* dual defs (d01 naive + d07 JWT); last-applied wins | Add comments at d01 defs noting d07 override (low risk) |
| TSP-SCHEMA-08-code | TSP-schema | (canon-internal, no code change) Batch links pool_line not Pool | Cross-ref note only — Task 14 |

> **Note on VET-02:** ✅ FIXED on branch `fix/vet-f11-isolation` (commit `4a961c9`) — ownership guard added, single definition confirmed, cross_check 0/0/0. **NOT YET DEPLOYED** — apply via `python3 deploy_sql.py <DB_PASSWORD>` to Supabase `mwtbozflyldcadypherr` before prod is safe.
