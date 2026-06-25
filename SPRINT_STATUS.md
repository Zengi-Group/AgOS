# SPRINT STATUS — AgOS

> ⚠️ **RETIRED 2026-06-24.** Текущий статус проекта теперь живёт в `apex-brain/projects/agos/_project.md` (раздел «Сейчас») — по закону мозга статус = компиляция из Linear+разговора в ОДНОМ доме (P4). Актуальная работа — в Linear (команда ARS). Этот файл сохранён для истории фаз и НЕ обновляется.

> Maintained by: Architect (planning/sign-off), DB Agent (after SQL), Backend Agent (after code), UI Agent (after UI)
> Last updated: 2026-06-23 (ADR-CABINET-SHELL-01 — новый мобильный кабинет интегрирован на ветке `feat/cabinet-shell-tsp`)

---

## Current Phase: 🟢 Cabinet Shell Integration (фермер+МПК) — INTEGRATED on `feat/cabinet-shell-tsp`, pending CEO review/merge (2026-06-23)

**ADR-CABINET-SHELL-01.** Новый мобильный кабинет из `feature/my-changes` интегрирован в `main` точечным cherry-pick'ом (ветки без общего предка → не `git merge`).

| Слой | Что сделано | Статус |
|------|-------------|--------|
| UI shell | `src/pages/cabinet/shell/**` (82 файла) + `src/lib/account.ts` + `scripts/test_rpc_create_batch.mjs` — `git checkout` | ✅ `tsc` 0 / `build` ✓ 5.18s |
| Routing | `App.tsx`: `/cabinet`→`CabinetApp`, `/mpk`→`MpkApp` (вне `AppLayout`); legacy→`/cabinet-legacy` (`Sidebar`/`Header`/22 стр. перепривязаны) | ✅ роуты wired (redirect→`/login`, 0 console errors) |
| SQL adapter | rebind #10 + self_join #5 как 2 миграции в `supabase/migrations/` (Option B); УЖЕ задеплоено на проде инженером | ✅ live; `cross_check.sh` 0/0/0 |
| Prod gate (Step 0) | канонический d02 цел: `batches`(tsp_sku_id/status) + `pools.organization_id` + 14 M4/M6 RPC + 11 A-CAT RPC; деструктив `DROP TABLE batches` не применялся | ✅ PASS (PostgREST read-only) |

**Отвергнуто (защита main):** auth-rewrite ветки (OTP/PIN main цел), 8 деструктивных миграций (`DROP TABLE batches CASCADE`), даунгрейд доков (Dok1/3, Microsteps, A-CAT-spec), `feeding_model.py`/`d11_norms.sql`. **Отложено (Phase 2):** expert-роль регистрации (IMPL_DEBT REG-EXPERT-01), MPK auto-routing (CABINET-SHELL-01).

**Pending:** (1) CEO ручная проверка аутентифицированного кабинета (OTP-логин → `/cabinet` фермер, `/mpk` МПК) — headless не проверить; (2) commit + PR (НЕ закоммичено, всё на ветке); (3) Phase-2 реконсиляция 2 слоёв TSP-RPC (IMPL_DEBT TSP-ADAPTER-01/02).

---

## Previous Phase: 🟡 M4 + M6 TSP — SQL CLOSED (incl. A-CAT bridge), DOCS SYNCED, UI/DATA PENDING (2026-06-15)

**Что закрыто (SQL layer):**

| Слой | Скоуп | Коммиты | Статус |
|------|-------|---------|--------|
| Schema (SECTION 7) | 12 новых таблиц, batches +8 cols / pools +6 cols (вкл. `organization_id` denormalisation), 14 индексов, RLS на 5 таблицах, seed `tsp_config` + 4 `review_dimensions`, deprecate `pool_requests` | `3415f64` + addendum `19dc1f1` | ✅ deployed на prod (`mwtbozflyldcadypherr`) |
| RPC (SECTION 8) | 14 функций M4/M6 канон: `rpc_create_pool, rpc_publish_pool, rpc_retry_match_pool, rpc_accept_offer, rpc_reject_offer, rpc_lower_batch_price, rpc_confirm_dispatch, rpc_confirm_delivery, rpc_submit_deal_review, rpc_pool_return_batches, rpc_pool_accept_partial, rpc_cancel_pool, rpc_get_reference_price, rpc_get_minimum_price` | `f7ec5d3` + `80ba7b2` + `19dc1f1` | ✅ deployed (14/14 в `information_schema.routines` + `rpc_name_registry`) |
| **A-CAT Schema (SECTION 7.16)** | `tsp_sku_category_map` (bridge) + partial unique index + 2 lookup indexes + RLS + 2 policies | `0450823` | ✅ deployed на prod |
| **A-CAT RPC patches (SECTION 8)** | `rpc_lower_batch_price` floor-clamp ✅ enabled (bridge JOIN, exact-rayon→national fallback) + `rpc_create_pool` floor-resolve via bridge (back-compat preserved) | `0450823` | ✅ deployed |
| **A-CAT Admin RPC (SECTION 8a)** | 11 functions: AC-1..7 write + AR-1..4 read; все `SECURITY DEFINER` + `fn_is_admin()` gate; whitelisted в `cross_check.sh` CHECK-5 (admin reference-data exception) | `0450823` | ✅ deployed (11/11 в `information_schema.routines` + `rpc_name_registry`) |
| Code review | 13 adversarial findings — 11 fixed, 2 rejected с обоснованием | `19dc1f1` | ✅ closed |
| Resolved defects | DEF-TSP-M4-OWNERSHIP, Q-TSP-RETRY-MATCH | — | ✅ closed |
| Resolved questions | **Q-TSP-CATEGORY-CLASSIFIER** (SQL layer ✅; UI+data pending — см. ниже) | — | ✅ architecture closed, ✅ SQL closed |
| Docs sync (DOC-SYNC-M4M6-01 + **DOC-SYNC-A-CAT-01**) | Dok 1 §8 v1.9 patch (12+1 entities, A-CAT statuses), Dok 3 §4a (14 RPC) + **§4b (11 A-CAT RPC)**, Dok 4 §3.3a (15 events) + **§3.3b (A-CAT events deferral decision)** | — | ✅ done 2026-06-15 |

**Verification:**
- `cross_check.sh` — 0/0/0 (после whitelist'а 11 A-CAT admin RPC в CHECK-5 — admin reference-data exception документирована inline)
- `information_schema.routines` — 14/14 M4/M6 + 11/11 A-CAT admin = **25 routines** SECURITY DEFINER + search_path
- `rpc_name_registry` — 14/14 M4/M6 + 11/11 A-CAT (всего 25 new entries from 2026-06-15)
- `pools.organization_id` — NOT NULL, backfilled
- `tsp_sku_category_map` — 7 cols, 4 indexes (pk + ux_active + idx_sku + idx_cat), RLS=true, 2 policies (read=auth / write=fn_is_admin)
- 3 RLS policies переписаны на column-check
- Smoke tests `rpc_get_minimum_price` / `rpc_get_reference_price` / `rpc_cancel_pool` — корректно
- Bridge integration verified: `rpc_lower_batch_price` + `rpc_create_pool` source содержит `tsp_sku_category_map` JOIN

**Что открыто (блокирует pilot):**

| Долг | Severity | Owner | Зависимость |
|------|----------|-------|-------------|
| **A-CAT UI** (A-CAT-01..04 экраны) | Significant | UI Agent | §3 спеки `Docs/AGOS-Dok6-A-CAT-AdminScreens-v1_0.md`. Подключение к 11 RPC уже deployed (см. Dok 3 §4b). ~2–3 дня. |
| **A-CAT data fill** (5–8 категорий + 30 SKU маппингов + N цен) | Critical (final pilot unblock) | CEO + зоолог | Зависит от A-CAT UI. После наполнения floor-enforcement автоматически активируется без redeploy (~1 час работы в админке). |
| **M6-C-ADMIN-FLOW** | Significant | Architect (дизайн-сессия) | UX-flow админа Турана (WIP в Microstep6, не закрыт). Параллельно с A-CAT — не блокирует. |
| **Dok 6 SCREEN contracts для M6-A/B/C** | Significant | Architect | Блокирует UI Agent для M6-A/B/C треков. После M6-C closure. |
| **AI Gateway tools для M4/M6 RPC** | Significant | Backend Agent | Текущие tools умеют только legacy `rpc_create_pool_request`/`rpc_match_batch_to_pool`. Не блокирует web-pilot; нужен для WhatsApp-канала. |
| **UI экраны для M6-A/B/C** | Significant | UI Agent | После Dok 6 contracts. |
| **Q-TSP-REVIEW-DIMENSIONS** | Minor | CEO post-pilot | Полный список dimensions после пилота. Пилотный seed (4 строки) уже в БД. |
| **LEGACY-RPC-CLEANUP** | Minor | Architect (ADR) | 7 legacy Slice 5b RPC дублируют функциональность. Deprecation ADR после миграции UI. |
| **M5-ONBOARDING** | Minor (deferred) | CEO + Architect | Microstep 5 не спроектирован. |
| **MIN-MEMBERSHIPS-CHECK-01** | Minor | DB Agent | `memberships_level_valid_for_type` CHECK без `IF NOT EXISTS`. |
| **DEF-TSP-M4-HEADER-STALE-01** | Minor | DB Agent | §8 header в d02_tsp.sql строки ~2120-2124 описывают уже-закрытый DEF-TSP-M4-OWNERSHIP «compromise». Косметика. |

**Recommended next step:** **UI Agent — §3 спеки** [`Docs/AGOS-Dok6-A-CAT-AdminScreens-v1_0.md`](Docs/AGOS-Dok6-A-CAT-AdminScreens-v1_0.md): 4 экрана `/admin/livestock-categories/*` (~2–3 дня). RPC уже live (commit `0450823`) — фронт делается «к готовому API». После UI sign-off CEO + зоолог наполняют данные в админке (~1 час) → Q-TSP-CATEGORY-CLASSIFIER полностью closed, TSP pilot разблокирован.

**Параллельные треки:** **M6-C-ADMIN-FLOW** (Architect дизайн-сессия) + **AI Gateway tools** (Backend Agent) — оба не блокируют A-CAT pilot.

---

## Previous Phase: ✅ ADR-AUTH-CONSOLIDATE-01 — CLOSED (2026-05-13)

**Decision:** `/register` (AGOS-native, 348 lines) declared canonical registration. Imported `/join` flow (1750 lines, from turan-industry-catalyst merge ADR-MIGRATION-01) and parallel admin queue removed from UI. Landing page and all marketing components preserved; CTAs rewired to `/register` directly.

**Removed:** 12 files (`public/Registration.tsx`, `admin/membership/Application{List,Detail}.tsx`, 6 hooks, 3 admin components). **Modified:** `App.tsx` (lazy imports + routes), `ApplicationsHub.tsx` (tab removed), 4 landing files (CTA hrefs).

**Verification:** `npx tsc --noEmit` 0 errors · `npm run build` success (4.7s) · Preview confirms `/` lендинг работает, все 4 CTA → `/register`, `/registration` и `/join` редиректят на `/register`, 0 console errors.

**Deferred to separate ADR:** schema cleanup of `registration_applications` table + trigger + counter function in `d10_public_site.sql` (requires prod-data audit). Orphaned `src/pages/landing/Index.tsx` — separate landing-canonicalization decision required.

**Architect sign-off:** APPROVED. P4 violation closed; AGOS-native flow now sole canonical path. Anonymous visitors from `/` route correctly into `organizations`+`memberships` (Slice 1/2 architecture).

---

## Previous Phase: ✅ ADR-PRICES-01/02 + DEF-WEANING-01-P3 — CLOSED (2026-04-18)

**Gate sign-off:** D-GATE-PRICES-01-FINAL. `cross_check.sh` 0/0/0. Tests: `test_price_resolver.py` 11/11 ✅, `test_molodnyak_nonzero_in_calving_months` 1/1 ✅. Prod Supabase verified: 7 seed rows (4 base + 3 age-specific), 3 RPCs deployed + registered. Railway/Vercel autodeploy from `main`.

### Gate invariants
| Check | Result |
|-------|--------|
| cross_check.sh 0/0/0 | ✅ |
| `rpc_list_livestock_prices` on prod | ✅ |
| `rpc_upsert_livestock_price` on prod | ✅ |
| `rpc_retire_livestock_price` on prod | ✅ |
| Seed: 4 base livestock_prices rows | ✅ |
| Seed: 3 age-specific steer_own rows (6/12/18mo) | ✅ |
| rpc_name_registry: 3/3 entries | ✅ |
| test_price_resolver.py 11/11 | ✅ |
| DEF-WEANING-01 P3 fix + test | ✅ |

### Commits
| ADR | Commit | Scope |
|-----|--------|-------|
| ADR-PRICES-01 | `e89f590` | livestock_prices category + 3 RPCs + 4 seed rows + Admin UI |
| ADR-PRICES-02 | `2ecc86a` | age_months dimension in price_resolver + 3 age seed rows + Wizard UX |
| ADR-PRICES-02 + DEF-WEANING-01 P3 | `3652bfc` | 11 test_price_resolver tests + molodnyak P3 test + P3 fix |
| live price preview UX | `b6a2452` | ProjectWizard live price preview |

### Architect sign-off
0 Critical findings. 0 Significant findings. ADR-PRICES-01 P8 migration complete (hardcoded → DB). ADR-PRICES-02 age-specific pricing working. DEF-WEANING-01 P3 path closed — molodnyak costs now non-zero in all 3 priority paths.

---

## Previous Phase: ✅ ADR-CAPEX-01 — CAPEX Module (Consulting) — CLOSED (2026-04-18)

**Gate sign-off:** D-GATE-CAPEX-01-FINAL. All 5 phases shipped. `cross_check.sh` 0/0/0. CAPEX test suite 14/14 (6 legacy + 8 new) green. Тест 7 prod verification confirmed Priority 2 math (drift 0.00057% from Excel 282,465,145.54). Known tech debt tracked for future ADR-CAPEX-02.

### Commits
| Phase | Commit | Scope |
|-------|--------|-------|
| Phase 1 (DB) | `cfce152` | schema + seed + 5 RPCs |
| Phase 2 (Backend) | `259fe49` | engine Priority chain + 14 tests |
| Phase 3 (UI + P8) | `92dfbb5` | editable CapexTab + wizard materials + price-params refactor |
| Phase 5 partial (Dok 1/3/4/7) | `eb88bea` | architecture docs |
| Phase 4 (Admin UI) | `560829c` | /admin/capex 3-tab page + Phase 3 docs followup |
| Phase 5 closeout (Dok 6) | `2d43c5a` | 5 screen contracts + D-GATE-CAPEX-01-FINAL |
| ADR-CAPEX-02 DB (tech debt fixes) | `174485f` | `rpc_save_project_infra_override` NULL-preserve + `rpc_list_capex_surcharges`. **Applied to prod via Supabase MCP `apply_migration` (2026-04-18).** Verified: registry entry present, new RPC returns `[{code:'default', contingency_rate:0.025}]`, `p_overrides` signature now `DEFAULT NULL::jsonb`. |

### Architect sign-off
0 unresolved Critical findings. Significant finding acknowledged (per-item depreciation delta +6% buildings / +2% equipment on recalc — intended per plan §2.3 step 5). Tech debt L-P3-WIZARD + L-P4-1 — **fixed via ADR-CAPEX-02 (2026-04-18)**. Remaining follow-up: UI Agent patches (ProjectWizard pass `p_overrides:null` + CapexSurchargesTab use new RPC) + Dok 3 §13c update (NULL-preserve semantic note).

---

## Previous Phase: 🕒 ADR-CAPEX-01 — CAPEX Module (historical detail)

Plan: [.claude/plans/q1-rosy-lollipop.md](.claude/plans/q1-rosy-lollipop.md)

| Phase | Owner | Status | Notes |
|-------|-------|--------|-------|
| Phase 1 — DB schema + seed | DB Agent | ✅ Done + Architect-signed (2026-04-17) | d09: CHECK extended (+2 cat), 3 new columns on consulting_projects, 5 RPCs, seed 4 materials + 1 surcharges + 53 infra_norms (incl. 10 bespoke overrides, deviation approved). **Applied to prod via psycopg2** during Architect audit (file changes were uncommitted, deploy step was missing). 22/22 QA invariants ✓. See DECISIONS_LOG `ADR-CAPEX-01 Phase 1 sign-off`. |
| Phase 2 — Engine rewrite | Backend Agent | ✅ Done + deployed + prod-verified (2026-04-17) | commit `259fe49` live on Railway. Тест 7 recalc confirmed Priority 2 active: CAPEX Итого = 273,774,324 ₸ ← matches Excel Летний-scenario expected (282,465,146 − 8,692,435) within 1,613 ₸ (0.00057% floating-point drift). Tools block = 4,240,000 ₸ exact. Calving multiplier, per-item depreciation, seed refs — all working. QA verdict PASS (0 Critical). |
| Phase 3 — UI: Wizard + CapexTab | UI Agent | ✅ Code done — pending commit + Vercel deploy (2026-04-17) | CapexTab: editable table per block, sticky save bar, legacy banner (Priority 3 fallback), materials_used display. ProjectWizard: material selectors в Step 3 (Edit mode) + separate Строительство row-card (View mode); handleCalculate saves materials via rpc_save_project_infra_override before /calculate (preserves last-version overrides to not clobber CapexTab edits). TSC clean, build succeeds (2m 5s). Known race: wizard/CapexTab cross-edit within same session can lose overrides (flagged, fix deferred to rpc_update_consulting_project materials-only extension). |
| Phase 4 — Admin /admin/capex | UI Agent | ✅ Code done — pending commit + Vercel deploy (2026-04-18) | New file `src/pages/admin/capex/CapexReferenceAdmin.tsx` (~780 lines): 3 tabs (Материалы / Нормативы / Надбавки) mirroring FeedReferenceAdmin pattern. Materials tab: CRUD 4 materials via `rpc_upsert_construction_material`. Norms tab: 53 items с block filter + search + Dialog с cost_model-specific form fields + bespoke price override + calving multiplier. Surcharges tab: single-row form, reads via `.from()` (tech debt flagged), saves via `rpc_upsert_consulting_reference`. Route `/admin/capex/*` in App.tsx. Sidebar link «Инфраструктура» (icon Building2). TSC clean, build 7.66s. |
| Phase 5 — Docs + verification | Architect + QA | 🟡 Partial done (2026-04-18) — Dok 1 §6 + Dok 3 §1.9/§13c + Dok 4 §3.10 + Dok 7 §11 updated. Pending: Dok 6 screen contracts (после Phase 4), final QA gate closure. |

### Phase 1 deviation — APPROVED (Architect, 2026-04-17)
Plan §1.3 listed `unit_cost_per_m2_override` on 4 items (FAC-009, INF-008, PAD-001, PAD-007). Excel actually has bespoke per-m² prices on 10 area items (additionally FAC-015=19500, FAC-019=40000, FAC-015b=9000, FAC-012=80000, FAC-001=12500, FAC-013=83333). Seed encodes all 10 to preserve plan §2.5 acceptance target 282,465,145.54 ₸. `material_target` retained on every area item → admin can delete override to activate catalog pricing (sandwich/light_frame/steel/brick). Reconciles internal plan inconsistency: §1.3 text was under-specified; §2.5 numeric target is the authoritative acceptance criterion.

### Process finding (Minor)
File-touched-but-not-deployed pattern re-occurred (third time in week: DEF-SCHEMA-DRIFT-01 for `needs_recalc`, -02 for `role_was_overridden`, now Phase 1). **Process fix:** DB Agent MUST apply SQL via `deploy_sql.py` or targeted psycopg2, then re-verify deployed state (`information_schema.columns` or `SELECT count(*) FROM ...`) before marking a phase ✅ Done. `cross_check.sh` alone does not verify prod — it only checks SQL files.

### Files touched (Phase 1)
- `d09_consulting.sql` — +391 lines (CHECK ALTER, 3 column ALTERs, 5 RPCs, 58 seed rows). Total now 1157 lines.
- `cross_check.sh` — +4 entries in CHECK-5 whitelist (`rpc_list_construction_materials`, `rpc_list_infrastructure_norms`, `rpc_upsert_construction_material`, `rpc_upsert_infrastructure_norm`).

### Files touched (Phase 2)
- `consulting_engine/app/engine/capex.py` — dispatcher + `_data_driven_calculate_capex` (new, ~220 lines) + 8 helpers + `_legacy_calculate_capex` (preserved verbatim). Priority chain: override → norm×material → legacy. Python 3.12 typing (`Optional[dict]` for 3.9 local compat).
- `consulting_engine/app/engine/orchestrator.py` — passes `herd=herd` to `calculate_capex` so norms with `applies_to=cows_eop/...` resolve (additive, default param).
- `consulting_engine/app/models/schemas.py` — `ProjectInput` +3 fields: `construction_material_enclosed` (default "sandwich"), `construction_material_support` (default "light_frame"), `infra_items_override: list[dict]` (default []).
- `consulting_engine/app/api/calculate.py` — reads `consulting_projects` row, overrides `input_params` material fields + `infra_items_override` before `run_calculation`. DB wins because CapexTab save path bypasses wizard payload.
- `consulting_engine/tests/fixtures/capex_seed.json` — NEW, mirrors the 58 d09 seed rows (4 materials + 1 surcharges + 53 norms).
- `consulting_engine/tests/test_capex_staff_wacc.py` — `TestCapexDataDriven` class: 8 tests (Excel parity, capacity scaling, calving multiplier, override exclude/material/bespoke, pasture area scaling, legacy fallback).

### Phase 2 test run (local Python 3.9 against isolated capex.py import)
- `TestCapex` (legacy, Priority 3): 6/6 ✅
- `TestCapexDataDriven` (new, Priority 2): 8/8 ✅
- Non-Staff full suite (feeding/herd/timeline/wacc/taxonomy): 40 passed, 3 skipped (taxonomy RPC), 3 xfailed (pre-existing). 0 new failures.
- `TestStaff` 6/6 failures — **pre-existing** (D-FEED-2: 7 staff positions vs test expectation 5 positions). Confirmed via `git stash` baseline. Out of Phase 2 scope.

### Phase 2 deployment (in progress — commit `259fe49` pushed 2026-04-17)
Railway `consulting-engine` service autodeploys from `main` push. Phase 2 changes are feature-flagged by seed presence — empty `refs['infrastructure_norms']` triggers Priority 3 legacy, giving zero-risk rollout even if seed is missing on prod.

**Prod verification check-list (CEO / Architect):**
1. Railway dashboard → Deployments → latest → Logs: confirm no import errors on startup.
2. Test recalc on project «Тест 7» (da3e54d6) → response `results.capex.priority_used == 2` (not 3), `grand_total` ≈ 282.4M ±1%.
3. Confirm no field in UI (P&L/Summary/CashFlow) moves >1% relative to pre-deploy values, EXCEPT depreciation line (see below).

### 🟡 Known behavioral change — depreciation delta (QA-identified, accepted)
Priority 2 uses **per-item** `depreciation_years` from seed (20y buildings, 5y tractor, 3y tools, 2y спецодежда, etc.). Priority 3 used a blanket 20y-buildings / 5y-equipment.

At capacity=300 defaults, delta on monthly depreciation:
- `depreciation_buildings_monthly`: 936.77 → 997.01 тыс.тг (**+6.4%**)
- `depreciation_equipment_monthly`: 960.67 → 981.94 тыс.тг (**+2.2%**)

Financial impact: depreciation line on P&L rises ≈ +80 тыс.тг/мес (~+1M тг/год); net income slightly lower; NPV/IRR drift ≤1%. **Intended by plan §2.3 step 5.** Any legacy project rerun after deploy will see this — this is an improvement in accuracy, not a defect.

Mitigation considered: UI badge «Обновлена методика амортизации» on first Priority-2 recalc. Deferred to Phase 3 UI scope if needed.

---

## Previous Phase: ✅ Feed Cost Engine Audit — CLOSED (2026-04-17). 9 defects fixed, deployed, QA+Architect signed off.

### Gate sign-off — D-GATE-FEED-AUDIT-2026-04-17

**QA verdict:** 22/22 functional checks passed, 0 Critical, 1 Significant (DEF-DOC-SYNC-01 — resolved same session).
**Architect sign-off:** APPROVED. All 9 defects closed, deployed, math verified end-to-end on project «Тест 7» (da3e54d6). See DECISIONS_LOG entries 2026-04-17.

| # | Defect | Severity | Domain | Status |
|---|--------|----------|--------|--------|
| 1 | DEF-RATION-SAVE-01 — PGRST203 overload ambiguity → 5 groups silently skipped on save | Critical | UI + SQL | ✅ Closed |
| 2 | DEF-FEED-NORMS-01 — Priority 2 summed all reproducer norms → 100M for cows_12m | Critical | Backend | ✅ Closed |
| 3 | DEF-CONSULTING-AUTH-01 — `fn_my_org_ids()/fn_is_admin()` blocked service_role → Priority 1 never fired | Critical | SQL | ✅ Closed |
| 4 | DEF-OPEX-FATTENING-01 — `total_fattening` dropped from COGS | Significant | Backend | ✅ Closed |
| 5 | DEF-SCHEMA-DRIFT-01 — `d09_consulting.sql` not in deploy_sql.py → `needs_recalc` column absent | Significant | DB/Deploy | ✅ Closed |
| 6 | DEF-OPEX-FEED-SPLIT-01 — P&L «Корма» indent under repro but included fatt | Significant | Backend + UI | ✅ Closed |
| 7 | DEF-RATION-COVERAGE-01 — UI counted animal_category codes, not feeding_group target_codes (5 of 8 vs 5 of 5) | Significant | UI | ✅ Closed |
| 8 | DEF-FEED-NORMS-02 — transition season ignored in Priority 2 | Minor | Backend | ✅ Closed |
| 9 | DEF-DOC-SYNC-01 — Dok 3 v1.4 stale after wrapper drop | Significant | Docs | ✅ Closed (commit 8a8e370) |

### Deploy summary

| Slice | Channel | Status |
|-------|---------|--------|
| SQL (d01 canonical `id` field, d03 wrapper drop, d09 `needs_recalc` + `rpc_save_consulting_ration` + `rpc_get_consulting_rations` auth removal) | Direct via psycopg2 to aws-1-ap-south-1.pooler | ✅ Applied |
| Python engine (`feeding_model.py` _calc_from_norms rewrite, `opex.py` feed split, `calculate.py` embed-join) | Railway `consulting-engine` service | ✅ Redeployed |
| UI (`Calculator.tsx`, `FeedReferenceAdmin.tsx`, `SimpleRationEditor.tsx`, `RationTab.tsx`, `PnlTab.tsx`) | Vercel autodeploy from `main` push | ✅ Live |

### Acceptance check — project Тест 7 (da3e54d6)

After redeploy, project shows end-to-end:
- `feeding._source = 'consulting_rations'` ✓ (Priority 1 active)
- `cows_12m year-1 = 11,326` тыс.тг (matches manual formula 318 тг/сут × 197 cows.eop × days → 11,326; was 100,906 before fixes — 8.9× reduction)
- `opex.feed_cost_repro == feeding.total_reproducer = 12,901` ✓
- `opex.feed_cost_fatt == feeding.total_fattening = 223` ✓
- `opex.total_cogs == cogs_reproducer + cogs_fattening = 47,429` ✓
- `pnl.gross_profit == revenue + total_cogs = 25,011` ✓
- P&L UI shows «Корма (репродуктор)» under reproducer, «Корма (откорм)» under fattening

### Side effect: deploy_sql.py host migration

`deploy_sql.py` DB_HOST updated from `aws-0-ap-south-1` to `aws-1-ap-south-1` (Supabase pooler migration — old host returned «Tenant or user not found»). Future SQL applies work off the new host.

### Tech debt payback (2026-04-17, same day)

| Debt | Resolution | Commit |
|------|-----------|--------|
| DEF-SQL-RESERVED-01 — `current_role` reserved-word blocked full `deploy_sql.py` re-apply | Quoted as `"current_role"` in d01 (4 places) + d07 (2 places). Column name unchanged → no data migration. `deploy_sql.py` now passes d01:900. | `3e26181` |
| DEF-WEANING-01 — `calves.avg = 0` → SUCKLING_CALF ration silently ignored, HEIFER/STEER ration overcharged for newborns (~4.9M тг/year overstated) | `_calc_from_consulting_rations` + `_calc_from_norms` split heifers/steers into suckling (first `weaning_months`=6) vs weaned. Suckling → molodnyak group with SUCKLING_CALF ration. New `ProjectInput.weaning_months`. Priority 3 untouched (CFC test parity). | `3e26181` |

Acceptance (project Тест 7): `molodnyak` year-1 = 427 тыс.тг (was 0), year-10 = 3,194. `total_reproducer` year-10 reduced from 57,517 → 50,973 (-11%). `total_fattening` year-10 reduced from 4,728 → 2,325 (-51%). All money previously overcharged on newborn animals now correctly attributed to SUCKLING_CALF line.

### Remaining tech debt (next session)

| Issue | Severity | Owner |
|-------|----------|-------|
| d01 `memberships_level_valid_for_type` CHECK constraint lacks IF NOT EXISTS → full `deploy_sql.py` re-apply blocked on 2nd-attempt | Minor | DB Agent |

---

## Previous Phase: TAXONOMY slice — FULLY CLOSED (2026-04-16). All post-tasks done. TAXONOMY_RPC_READ=true. Realtime wired. Next: Slice 4 proactive dispatch.

### TAXONOMY slice — Animal Ontology (ADR-ANIMAL-01)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| ADR | ADR-ANIMAL-01 in DECISIONS_LOG + Dok 1 | ✅ Approved (2026-04-15) | 4-layer architecture (L1 canonical / L2 projections / L3 operational / L4 external), 7 invariants I1–I7, 4 lifecycle types, propagation ≤60s |
| DB | M1: ALTER animal_categories + seed 6 axes (d01) | ✅ Done | purpose / physiological_state / age_band / status / deprecated_at / replaced_by_codes — 12 codes seeded |
| DB | M2: animal_category_mappings + L2 seeds (d01) | ✅ Done | feeding_group (10+2), cfc_group (11+1, valid_to=2026-12-31), turnover_key (12+2), market_sex (9), market_age_group (6). EXCLUDE gist on daterange. |
| QA | Gate audit post-M3a | ⚠️ FAIL → ✅ Fixed | 2 CRIT + 1 SIG found (non-deterministic resolve, RLS tautology, OX/MIXED unmapped). See M5 remediation. |
| DB | M5: QA remediation (is_primary, RLS fix, OX/MIXED seeds) | ✅ Done | Added `is_primary boolean` + unique partial index; backfilled primaries; fixed ecm_read; seeded 5 L2 rows for OX/MIXED. |
| DB | M3a: 6 RPCs + RLS + audit trigger (d01) | ✅ Done | rpc_list_animal_categories(date,bool), rpc_resolve_category, rpc_get_category_mappings, rpc_add/deprecate/migrate_animal_category |
| DB | M4: external_category_mappings (d01) | ✅ Done | L4 bridge: global + org-scoped mappings with 2 partial unique indexes |
| DB | DEF-TAXONOMY-01: duplicate rpc_list_animal_categories | ✅ Resolved (option D) | d01 canonical temporal overload + d03 legacy no-arg wrapper. @deprecated after M3c. Whitelist in cross_check.sh. |
| DB | cross_check.sh | ✅ 0 / 0 / 0 | 2 new whitelist entries documented |
| QA | Snapshot gate: rpc_get_category_mappings parity | ✅ PASSED (2026-04-16) | 3/3 tests: parity + I8 primary + cache invalidation. OX/MIXED gap found→fixed in CATEGORY_CODE_TO_HERD. |
| Backend | M3b: taxonomy_cache.py + test_taxonomy_snapshot.py | ✅ Done | consulting_engine: `taxonomy_rpc_read` flag + TaxonomyCache (read-through rpc_get_category_mappings/turnover_key). |
| Backend | M3b: ai_gateway/taxonomy.py wiring | ✅ Done | get_l1_codes() enum in vet tool schema; is_valid_l1_code() in extraction/rules.py; handle_platform_event() skeleton in notification_worker.py. |
| UI | M3c: SimpleRationEditor + herdCategoryMapping.ts → RPC | ✅ Done | `useAnimalCategoryMappings` hook (staleTime=60s). `useCategoryToHerd()` + `rationGroups` from feeding_group taxonomy. Static fallbacks preserved (HS-5). `useInvalidateTaxonomyCache()` ready for Realtime wiring (Slice 4). |
| Architect | Dok 3 update: add 6 RPCs to catalog | ✅ Done (2026-04-15) | RPC-T1..T6 in §1.8/§9b (lines 138-144, 569-592) |
| Architect | Dok 4 update: event `standards.animal_category.updated` | ✅ Done (2026-04-15) | Dok 4 §3.9 line 390 |
| Cleanup | TAXONOMY-CFC-DEPRECATE: remove Python CFC after valid_to (2026-12-31) | 🕒 Scheduled | 11 L2 rows auto-expire; Python code removal after |
| QA | Post-tasks audit (Realtime + flag flip) | ✅ PASSED (2026-04-16) | SIG-TAXONOMY-01 found+fixed (cd56ad8). MIN-TAXONOMY-01 accepted. cross_check 0/0/0. |

**DB Gate: ✅ PASSED** (2026-04-15) — cross_check 0/0/0 после M5 remediation.
**QA Gate: ✅ PASSED** (2026-04-15) — 2 CRIT + 1 SIG + 1 MINOR закрыты (commit `87db44b`).
**QA Post-tasks Gate: ✅ PASSED** (2026-04-16) — SIG-TAXONOMY-01 fixed. 0 critical / 0 significant. MIN-TAXONOMY-01 accepted.
**Architect sign-off: ✅** (2026-04-16) — TAXONOMY slice fully closed. No unresolved findings. Next: Backend Agent → proactive dispatch.

**TAXONOMY slice FULLY CLOSED (M1–M5 + M3b + M3c + all post-tasks).** Full propagation path: DB seeds → rpc_get_category_mappings → Python TaxonomyCache (consulting_engine) + ai_gateway L1 enum + React useAnimalCategoryMappings (UI). Feature flag `TAXONOMY_RPC_READ=true` (both services). Supabase Realtime wired in AppLayout.tsx.

**Remaining scheduled items:**
- TAXONOMY-CFC-DEPRECATE (2026-12-31): remove Python CFC path after cfc_group valid_to expires. Checklist in DECISIONS_LOG.md (2026-04-16 entry).

**Next sprint:** Slice 4 proactive dispatch — `handle_platform_event()` polling loop + embedding_worker.

---

## Previous Phase: Slice 9 post-gate — UI редизайн Consulting завершён. DEF-031 исправлен. QA: 0 critical.

### Slice 0 — Foundation

| Step | Action | Status | Gate |
|------|--------|--------|------|
| 1 | `git init`, initial commit | ✅ Done (688527a) | Repo exists |
| 2 | Create Supabase project (prod + staging) | ✅ Exists (`mwtbozflyldcadypherr`, Mumbai) | Project URL + anon key |
| 3 | Set env vars | ✅ `.env` created (Supabase keys set) | All vars in `.env` |
| 4 | Deploy SQL: d01→d02→d03→d04→d05→d07→d08 | ✅ Already deployed (94 tables, 22 rpc_* functions) | No FK errors |
| 5 | QA Agent: create `cross_check.sh` | ✅ Created | Script exists |
| 6 | Run `cross_check.sh` → 0 critical errors | ✅ **PASSED** (0 critical, 10 significant) | **DB GATE** |

**DB Gate: ✅ PASSED** (2026-03-18)

---

### Slice 1 — "У телёнка температура" (Sick Calf)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | F01, F02, F10, F11 | ✅ APPROVED | `Docs/AGOS-Dok6-Slice1-SickCalf.md` v2.0 — all 7 questions resolved. Dok 6 Gate PASSED. |
| DB | RPC-01 `rpc_register_organization` (d01) | ✅ Implemented | 4 org_types, p_role_data jsonb, atomic create. ⚠️ DEF-012 org_type CHECK |
| DB | RPC-02 `rpc_submit_membership_application` (d01) | ✅ Implemented | PENDING_EXISTS + ALREADY_ACTIVE checks |
| DB | RPC-04 `rpc_get_my_context` (d01) | ✅ Implemented | Stable read: orgs, farms, memberships, restrictions |
| DB | RPC-05/05b `rpc_upsert_farm` / `rpc_set_farm_activity_types` (d01) | ✅ Implemented | Upsert + delta activity types |
| DB | RPC-40 `rpc_start_ai_conversation` (d01) | ✅ Implemented | 24h session reuse (D64) |
| DB | RPC-26 `rpc_add_vet_diagnosis` (d04) | ✅ Implemented | Added to d04_vet.sql + rpc_name_registry |
| DB | RPC-27 `rpc_add_vet_recommendation` (d04) | ✅ Implemented | Added to d04_vet.sql + rpc_name_registry. D98 health_restriction via trigger. |
| DB | `rpc_get_vet_case_detail` (d04) | ✅ Implemented | D-F11-1: New RPC for F11 screen. Full case detail in one call. |
| Backend | FastAPI `/chat` webhook | ✅ Implemented | P-AI-8: save msg first → graph.invoke() → response |
| Backend | LangGraph graph | ✅ Implemented | D116 stateless, D117 one-run. 6 nodes: load_context→route→process→tools→compliance→save |
| Backend | Vet tools AI-07..10 | ✅ Implemented | `ai_gateway/tools/vet.py` — all 4 tools via supabase.rpc() |
| Backend | Compliance filter (P-AI-4) | ✅ Implemented | `ai_gateway/compliance.py` — dosage regex + antitrust + legal |
| Backend | ✅ DEF-013: 4x .table() calls replaced | ✅ Fixed (2026-04-16) | rpc_get_conversation_state, rpc_clear_confirmation, rpc_sync_conversation_role, rpc_get_user_phone |
| UI | F01 (Register), F02 (Farm Profile) | ✅ Implemented | 8-step conversational registration (4 roles), farm profile with herd groups |
| UI | F10 (Report Sick), F11 (Vet Case Detail) | ✅ Implemented | Vet case creation (severity=null, CEO decision), realtime detail view, P-AI-4 dosage compliance |
| QA | Slice 1 gate | ✅ **PASSED** (2026-03-19) | 0 critical, 0 significant in scope. DEF-013 accepted tech debt. cross_check.sh fixed (DEF-014/015). |

Already implemented: RPC-25 (`rpc_create_vet_case`), AI-01..AI-22.

### Slice 2 — Членство (Membership)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | A01, A02 | ✅ APPROVED | `Docs/AGOS-Dok6-Slice2-Membership.md` v1.0 — 3 CEO decisions resolved |
| DB | `rpc_get_membership_queue` (NEW, dual-mode) | ✅ Implemented | Admin read: list + detail. fn_is_admin() guard. Joins orgs+memberships+farms+herd_groups. |
| DB | RPC-03 `rpc_process_membership_application` (d01) | ✅ Implemented | FSM: submitted/under_review→approved/rejected. Notifications (WA+in_app). Events emitted. |
| Backend | WhatsApp notification sender (minimal worker) | ✅ Implemented | `ai_gateway/notification_worker.py` + `/notifications/process` endpoint. Claims via SKIP LOCKED, sends WA Cloud API, marks sent/failed via RPCs. |
| UI | A01 (Membership Queue), A02 (Decision) | ✅ Implemented | Admin palette, `fn_is_admin()` guard, RequireAdmin, confirmation dialog, WA notification mention. TypeScript clean. |
| QA | Slice 2 gate | ✅ **PASSED** (2026-03-19) | 0 critical, 0 significant in scope. fn_is_admin() verified SQL+UI. DEF-016 minor accepted. |

### Slice 3 — "Сколько корма нужно?" (Feed Planning)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | F03, F04, F15–F18 | ✅ APPROVED | `Docs/AGOS-Dok6-Slice3-Feed.md` v1.0 — 4 CEO decisions. F18 dual-view: per-head + total. |
| DB | RPC-07 `rpc_log_herd_event` (d01) | ✅ Done | Implemented in d01_kernel.sql (commit 0f6456f). Append-only herd event log. |
| DB | RPC-08 `rpc_get_farm_summary` (d01) | ✅ Done | Implemented in d01_kernel.sql (commit 0f6456f). Cross-domain jsonb summary. |
| DB | RPC-21..24 `rpc_upsert_feed_inventory`, `rpc_save_ration`, `rpc_archive_ration`, `rpc_get_current_ration` (d03) | ✅ Done | Implemented in d03_feed.sql (commit 0f6456f). Was incorrectly marked "Not started" — doc discrepancy. |
| Backend | AI-03 feed tool + calculate_ration + get_feed_budget Edge Functions | ✅ Done | Implemented (commit c8cbb7a) |
| UI | F03, F04, F15–F18 | ✅ Done | 6 screens implemented (commit f1f9631) |
| QA | Slice 3 gate | ✅ PASSED | D-GATE-S3 (commit e8eb953) |

Already implemented: RPC-06 (`rpc_upsert_herd_group`).

### Slice 4 — "Мой план на сезон" (Operations)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | F19–F23 | ✅ APPROVED | `Docs/AGOS-Dok6-Slice4-Operations.md` v1.0 |
| DB | RPC-37 `rpc_get_active_plan` (d05) | ✅ Done | d05_ops_edu.sql line 3535. Comprehensive jsonb: plan + phases[] + tasks_summary + kpis_summary. |
| DB | RPC-44 `rpc_add_knowledge_chunk` (d05) | ✅ Done | d05_ops_edu.sql line 3697. Deferred to Slice 7 UI. |
| DB | RPC-43 `rpc_create_proactive_alert` | ⚠️ Not as RPC | Backend writes directly to proactive_alerts via .table() — DEF-013 tech debt. Deferred. |
| DB | RPC-45 `rpc_restrict_organization` | ⬜ Deferred | Slice 6 (admin screens). |
| Backend | proactive dispatch + embedding + platform_events polling | ✅ Done (a06e0de) | /proactive/dispatch ✅ (main.py). embedding_worker.py ✅. poll_platform_events() ✅. |
| UI | F19 ProductionPlan | ✅ Done | 175 lines. rpc_get_active_plan, phases accordion, quick links. |
| UI | F20 TaskList | ✅ Done | 154 lines. Tabs: upcoming/overdue/completed. rpc_get_farm_tasks + rpc_complete_farm_task. |
| UI | F21 Timeline | ✅ Done | 143 lines. Gantt-style, CSS flexbox, today marker. |
| UI | F22 CascadePreview | ✅ Done | 153 lines. fn_preview_cascade + fn_shift_phase_cascade. |
| UI | F23 KpiDashboard | ✅ Done | 130 lines. Phase KPI groups, achieved/missed/pending. |
| QA | Slice 4 gate | ✅ PASSED (2026-04-16) — 0 Critical · 0 Significant after registry fix · 2 Minor accepted | fn_shift_phase_cascade + fn_preview_cascade added to rpc_name_registry. cross_check.sh → 0/0/0. |

Already implemented: RPC-33..36.

### Slice 5a — Market Farmer (F05–F09) — ✅ Gate PASSED (2026-04-01)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | F05–F09 | ✅ APPROVED | `Docs/AGOS-Dok6-Slice5a-Market-Farmer.md` |
| DB | RPC-11, RPC-17, RPC-18 (d02) | ✅ Implemented | rpc_cancel_batch, rpc_get_price_for_sku, rpc_get_market_summary |
| Backend | AI-16..21 market tools + disclaimer | ✅ Implemented | D-LEGAL-1: built without legal gate |
| UI | F05–F09 (farmer market: dashboard, batch, prices) | ✅ Implemented | Antitrust disclaimer in all price views |
| QA | Slice 5a gate | ✅ **PASSED** (2026-04-01) | D-GATE-S5a |

### Slice 5b — Market Admin (A11–A15) — 🔧 UI fixes applied, pending QA

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | A11–A15 | ✅ APPROVED | `Docs/AGOS-Dok6-Slice5b-Market-Admin.md` |
| DB | RPC-12..16, 19, 20 (d02) | ✅ Implemented | All 7 RPCs in d02_tsp.sql + registry. DEF-026 fixed (2026-04-01) |
| Backend | — | ✅ n/a | No new AI tools for admin screens |
| UI | A11 (PoolQueue), A12-A14 (PoolDetail), A15 (PriceGridManagement) | 🔧 Fixed | DEF-021..024 resolved by UI Agent (2026-04-01) |
| QA | Slice 5b gate | ⬜ Pending | Awaiting QA gate |

✅ DEF-026 (Fixed 2026-04-01): RPC-20 `rpc_publish_price_index_value` — corrected INSERT column names (`price_index_id` → `index_id`, `avg_price_per_kg` → `value_per_kg`), added required `data_source='expert_assessment'`, `published_by`, `published_at`.

Already implemented: RPC-09, RPC-10.

### Slice 6 — Эксперт-консоль (Expert)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | M01–M06, A03–A10 | ⬜ Not started | |
| DB | RPC-28..32 (d04) | ⬜ Not started | |
| Backend | Remaining vet/ops wiring | ⬜ Not started | |
| UI | M01–M06, A03–A10 | ⬜ Not started | 14 screens |
| QA | Slice 6 gate | ⬜ Not started | |

### Slice 7 — Образование (Education)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Dok 6 | F24–F28, A16–A19 | ⬜ Not started | |
| DB | RPC-38, 39, 42, 44 (d05) | ⬜ Not started | |
| Backend | Education tools, E2E smoke test | ⬜ Not started | |
| UI | F24–F28, A16–A19 | ⬜ Not started | 9 screens |
| QA | Slice 7 gate | ⬜ Not started | |

### Slice 8 — Унификация Рационов и Консалтинга

> **Решение:** D-S8-1 (2026-04-09) · **Архитектура:** Dok 7 v1.0

#### Часть A — Feed Справочник (самодостаточная)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| DB | `feed_consumption_norms` table in d03_feed.sql | ✅ Done | + RLS, index. DEF-027 fixed (rpc_list_feed_items + rpc_list_animal_categories created). |
| DB | `rpc_list_feed_items` (RPC-F01), `rpc_list_animal_categories` (RPC-F02) | ✅ Done | Created in d03_feed.sql. Fixes DEF-027. |
| DB | `rpc_upsert_feed_item` (RPC-F03), `rpc_upsert_feed_price` (RPC-F04), `rpc_upsert_feed_consumption_norm` (RPC-F05) | ✅ Done | Admin write RPCs in d03_feed.sql |
| DB | `rpc_list_feed_categories` (RPC-F06), `rpc_list_feed_consumption_norms` (RPC-F07) | ✅ Done | Read RPCs for FeedReferenceAdmin UI in d03_feed.sql |
| DB | d09_consulting.sql: убрать `feed_prices`/`feed_norms` из CHECK | ✅ Done | ADR-FEED-01. Аддитивное изменение. |
| UI | `/admin/feeds` — `FeedReferenceAdmin.tsx` | ✅ Done | 3 tabs: Каталог / Цены / Нормы. CRUD + dialogs. Sidebar entry added. |
| QA | Часть A gate | ⬜ Pending QA | |

#### Часть B — NASEM Calculator (самодостаточная)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Backend | `calculate-ration` Edge Function: `farm_id` optional, `consulting_project_id` support | ✅ Done | D-S8-3. Backward compatible. Dual-context save logic. |
| QA | Часть B gate | ⬜ Pending QA | |

#### Часть C — Ration Builder in Consulting (зависит от B)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| DB | `ration_versions`: ration_id → NULLABLE + consulting_project_id + context_animal_category_id + CHECK | ✅ Done | D-S8-4. Миграция в d03_feed.sql. RLS rv_read_own обновлён. |
| DB | `rpc_save_consulting_ration` (C-RPC-09), `rpc_get_consulting_rations` (C-RPC-10) | ✅ Done | В d09_consulting.sql. rpc_name_registry записи добавлены. |
| UI | `RationTab.tsx` в `/admin/consulting/:id/ration` | ✅ Done | Per-category NASEM calculator, CalcDialog, feed multi-select. |
| UI | `ProjectPage.tsx`: + 8-й таб "Рационы" | ✅ Done | Добавлен в TABS array. |
| UI | `App.tsx`: route `/admin/consulting/:id/ration` | ✅ Done | Import + Route добавлены. |
| QA | Часть C gate | ⬜ Pending QA | |

#### Часть D — Финансовая интеграция (зависит от A + C)

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Backend | `calculate.py`: `_load_feed_reference()` — feed_prices_d03, feed_consumption_norms, consulting_rations | ✅ Done | Supabase REST + rpc_get_consulting_rations. extra_refs kwarg added to run_calculation. |
| Backend | `feeding_model.py`: fallback chain Priority 1→2→3. `_calc_from_consulting_rations()`, `_calc_from_norms()` | ✅ Done | D-S8-2. Hardcoded defaults remain as Priority 3. `_source` key added to output. |
| QA | Часть D gate | ⬜ Pending QA | |

**Slice 8 Gate: ✅ PASSED (2026-04-09)** — D-GATE-S8

> **DEF-027** (Fixed 2026-04-09): `rpc_list_feed_items` and `rpc_list_animal_categories` called from `Calculator.tsx` and `RationTab.tsx` but did not exist in any SQL file. Created in d03_feed.sql as RPC-F01 and RPC-F02.

---

### Slice 9 — Expert Scenario Enhancement (Consulting Engine v2)

> **Reference:** Архитектурный анализ ZENGI_EXPERT_SCENARIO_v1.1 · **Plan:** swirling-waddling-catmull.md · **Completed:** 2026-04-09

Scope: стратегия реализации бычков (GAP-1 КРИТИЧНО), простой редактор рационов, физические объёмы кормов, годовая сводка кормовой потребности. Все изменения backward-compatible.

| Task | Layer | Component | Status | Notes |
|------|-------|-----------|--------|-------|
| A | UI | `ProjectWizard.tsx`: подсказки min/max для привесов | ✅ Done | hint prop в WizardField. Диапазоны: 0.70–1.10 кг/день бычки, 0.60–1.00 тёлки. |
| B | UI | `ProjectWizard.tsx`: клиентский калькулятор веса реализации | ✅ Done | `estimateSaleWeight()`. Live preview "~XXX кг" прямо в wizard step 3. |
| C | DB+BE | `d09_consulting.sql`: `'economic_parameters'` в CHECK + seed row | ✅ Done | Migration applied (2026-04-09). feed_inflation = 0.105. |
| C | BE | `feeding_model.py`: читать `FEED_INFLATION` из `refs["economic_parameters"]` | ✅ Done | `FEED_INFLATION_DEFAULT = 0.105`. Fallback на константу. |
| D | BE | `schemas.py`: `steer_sale_age_months: int` (0/7/12/18) | ✅ Done | `Field(default=0, ge=0, le=24)`. Backward-compatible default=0. |
| D | BE | `herd_turnover.py`: когортный трекинг бычков → продажа по возрасту | ✅ Done | `steer_cohorts: list[list]`. Legacy December sale при default=0. Mortaliy + bull transfer по когортам. |
| D | UI | `ProjectWizard.tsx`: select стратегии бычков (В декабре / 7 / 12 / 18 мес.) | ✅ Done | `STEER_SALE_OPTIONS`. Step 3 + Step 6 confirmation. |
| E | UI | `SimpleRationEditor.tsx`: табличный ввод рционов (5 групп × корма × сезон) | ✅ Done | Новый компонент. DEFAULT_RATIONS = CFC Excel defaults. Save → `rpc_save_consulting_ration`. |
| E | UI | `RationTab.tsx`: toggle "Простой" / "NASEM" | ✅ Done | `mode` state. SimpleRationEditor рендерится при mode='simple'. |
| F | BE | `feeding_model.py`: физические объёмы кормов (тонны) в output | ✅ Done | `_calc_group()` → `tuple[costs, quantities]`. `quantities.by_group`, `quantities.totals_by_feed`. |
| I | UI | `SummaryTab.tsx`: таблица "Кормовая потребность по годам, тн" | ✅ Done | Читает `results.feeding.annual_feed_summary`. Рендерит условно (прогрессивный). |

**Downstream impact (Task D):** `weight_model.py`, `revenue.py`, `feeding_model.py` адаптируются автоматически — читают обновлённые `steers_sold[]` / `steers_avg[]` массивы из herd_turnover.

**Slice 9 Gate: ✅ PASSED (2026-04-09)** — D-GATE-S9  
0 TS errors (`npx tsc --noEmit`). Dev server: 0 errors. Migration applied. Backward compat verified (steer_sale_age_months=0 → идентичный legacy output).

#### Post-gate fixes (2026-04-10)

| Commit | Fix | Notes |
|--------|-----|-------|
| `e534361` | `fattening_enabled/fattening_months` удалены из wizard — дериватируются из `steer_sale_age_months` | D-S9-5. tech_card.py консистентен с herd_turnover.py. |
| `d7bce9e` | `opex.feed_cost` отдельный массив; "Расходы на корма" строка в PnlTab; `annual_feed_cost_summary` во всех 3 путях движка | D-S9-6. |
| `81699aa` | SummaryTab: детальные таблицы кормов по группам (тыс. тг + тн) вместо одной строки итого | D-S9-7. |
| `e024ac4` | **DEF-028**: SimpleRationEditor передавал `p_animal_category_code` (строку) вместо `p_animal_category_id` (UUID) | Critical bug fix. Сохранение рационов теперь работает. |

#### Post-gate fixes (2026-04-11)

| Commit | Fix | Notes |
|--------|-----|-------|
| `5a3f6d9` | **UI**: Параметры page первый редизайн — двухколоночный layout (1fr + 260px), inline param inputs | Первый вариант отклонён пользователем |
| `0405cc0` | **UI**: Параметры page второй редизайн — карточные секции, hero IRR 28px, CoeffRow с растяжными барами, empty state правой панели | D-PARAMS-1. Принят. |
| `0d10389` | **QA infra**: cross_check.sh CHECK 1 — фикс BSD sed `\s+` → `[[:space:]]+`; whitelist fn_is_admin/fn_is_expert/fn_my_org_ids | DEF-029. Ранее cross-file дубли не детектировались на macOS |
| `e5a17c5` | **UX**: skeleton shimmer + tab fade animation (key={pathname}) + Loader2 на кнопке Рассчитать | D-UX-1. Вводит 3 бага — см. ниже. |
| `f46c425` | **fix**: blank header title (nameLoading бесконечный) + blank Тех.карта (tab-content height:100%) + skeleton shimmer контраст | DEF-032..034 |
| `04f2ab5` | **fix(ts)**: PromiseLike не имеет .catch() → обработка error через деструктуризацию в .then() | DEF-035. Build error на Vercel. |
| `eaa6b42` | **fix(ux)**: skeleton во всех 7 вкладках — h-48 w-full → table-like rows с .page padding; убран titleLoading из хедера | DEF-036 |
| `d05ae0b` | **fix(ts)**: удалён неиспользуемый nameLoading state — TS6133 build error | DEF-037. Последний build fix. |

**Build status: ✅ PASSING** (d05ae0b — все TS ошибки устранены)

#### Post-gate UI redesign (2026-04-12)

| Commit | Change | Notes |
|--------|--------|-------|
| — | **UI**: ConsultingDashboard → Attio-style grid table (3-level header, grid rows, footer) | D-UI-CONSULTING-01 |
| — | **UI**: ProjectPage → 3-row header (nav / title / tabs) via `headerContent` TopbarConfig extension | D-LAYOUT-01 |
| — | **Layout**: TopbarContext + Header.tsx + AppLayout.tsx — `headerContent?: ReactNode`, dynamic `gridTemplateRows` | D-LAYOUT-01 |
| — | **QA**: cross_check.sh → 0 critical. tsc --noEmit → 0 errors. All useSetTopbar callers regression-free | QA PASS |

#### ⚠️ Открытые дефекты

| DEF | Severity | Finding | File | Action needed |
|-----|----------|---------|------|---------------|
| DEF-031 | Significant | ~~`rpc_list_feed_prices` не зарегистрирована в `rpc_name_registry`~~ | `d03_feed.sql:2029` | ✅ **Fixed** (DB Agent 2026-04-12): INSERT добавлен в Slice 8 registry block d03_feed.sql |

---

## SQL Files — Implementation Inventory

### Already Implemented (confirmed in SQL)

**AI Gateway RPCs (d07_ai_gateway.sql) — 22 functions:**

| AI-ID | Function | Status |
|-------|----------|--------|
| AI-01 | `rpc_get_ai_farm_context` | ✅ (2 defs — DEF-001) |
| AI-02 | `rpc_upsert_herd_group` | ✅ (2 defs — DEF-002) |
| AI-03 | `rpc_get_feeding_plan` | ✅ |
| AI-04 | `rpc_get_farm_tasks` | ✅ |
| AI-05 | `rpc_complete_farm_task` | ✅ |
| AI-06 | `rpc_get_production_plan` | ✅ |
| AI-07 | `rpc_create_vet_case` | ✅ |
| AI-08 | `rpc_add_vet_symptoms` | ✅ |
| AI-09 | `rpc_get_vet_diagnosis` | ✅ |
| AI-10 | `rpc_get_treatment_protocols` | ✅ |
| AI-11 | `rpc_get_vaccination_schedule` | ✅ |
| AI-12 | `rpc_complete_vaccination_item` | ✅ |
| AI-13 | `rpc_create_consultation_request` | ✅ |
| AI-14 | `rpc_search_knowledge_chunks` | ✅ |
| AI-15 | `rpc_get_membership_status` | ✅ |
| AI-16 | `rpc_get_price_grid` | ✅ |
| AI-17 | `rpc_get_aggregated_supply` | ✅ |
| AI-18 | `rpc_get_aggregated_demand` | ✅ |
| AI-19 | `rpc_get_org_batches` | ✅ |
| AI-20 | `rpc_create_batch` | ✅ |
| AI-21 | `rpc_publish_batch` | ✅ |
| AI-22 | `rpc_update_conversation_language` | ✅ |

### Application Code

| Component | Status | Notes |
|-----------|--------|-------|
| `ai_gateway/main.py` | ✅ Slice 1 done | FastAPI `/chat` webhook, P-AI-8 save-first |
| `ai_gateway/graph.py` | ✅ Slice 1 done | LangGraph StateGraph, D116 stateless, D117 one-run |
| `ai_gateway/nodes.py` | ✅ Slice 1 done | 7 nodes: load_context→check_confirm→route→process→tools→compliance→save. ✅ DEF-013 fixed |
| `ai_gateway/tools/vet.py` | ✅ Slice 1 done | AI-07..10 via supabase.rpc(), P-AI-2 org_id injection |
| `ai_gateway/compliance.py` | ✅ Slice 1 done | P-AI-4 dosage regex (14 patterns), CF-01 antitrust, CF-05 legal |
| `ai_gateway/prompts.py` | ✅ Slice 1 done | System prompt builder from ai_prompts table (D133) |
| `ai_gateway/proactive.py` | ✅ Implemented in main.py | POST /proactive/dispatch (lines 220-241): INTERNAL_API_KEY guard + SKIP LOCKED via notification_worker.process_notification_batch(). No separate file needed. |
| `ai_gateway/embedding_worker.py` | ✅ Done (a06e0de) | Dok 5 §15: voyage-3 primary / OpenAI httpx fallback. WORKER_ID per hostname. SKIP LOCKED. FSM retry. lifespan asyncio.Task in main.py. |
| `src/` (React UI) | ✅ Slice 1 done | F01 (8-step reg), F02 (farm profile), F10 (report sick), F11 (vet case detail). AuthContext, useRpc hook, Supabase client. All data via supabase.rpc(). P-AI-4 dosage compliance verified. |

---

## Defects Found

| ID | Severity | File | Description | Status |
|----|----------|------|-------------|--------|
| DEF-001 | Significant | `d07_ai_gateway.sql` | `rpc_get_ai_farm_context` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-002 | Significant | `d07_ai_gateway.sql` | `rpc_upsert_herd_group` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-003 | Minor | `d01_kernel.sql` | `insert_user_message_dedup` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-004 | Minor | `d01_kernel.sql` | `claim_pending_notifications` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-005 | Minor | `d01_kernel.sql` | `mark_notification_failed` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-006 | Significant | `d05_ops_edu.sql` | `fn_preview_cascade` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-007 | Significant | `d05_ops_edu.sql` | `fn_generate_production_plan` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-008 | Significant | `d05_ops_edu.sql` | `rpc_start_production_plan` — 2 definitions | ✅ Fixed (2026-03-18) — V1 removed, V2 kept |
| DEF-009 | ~~Minor~~ | `d07_ai_gateway.sql` | `fn_my_org_ids`, `fn_is_admin`, `fn_is_expert` in d01+d07 | ⚪ Not a defect — intentional deploy-order dependency |
| DEF-012 | Significant | `d01_kernel.sql` | `rpc_register_organization` org_type CHECK constraint | 🟡 Known — verify against Dok 1 valid org_types |
| DEF-013 | Significant | `ai_gateway/nodes.py` + `notification_worker.py` | 3x `.table("ai_conversations")` + 1x `.table("users")` direct access — violates P-AI-1 | ✅ Fixed (2026-04-16) — 4 RPCs added: rpc_get_conversation_state, rpc_clear_confirmation, rpc_sync_conversation_role, rpc_get_user_phone. Instance 5 (platform_events) intentional (immutable log, documented) |
| DEF-014 | Minor | `cross_check.sh` | CHECK 3 window too narrow (10 lines) for multi-param functions | ✅ Fixed (2026-03-19) — expanded to 25 lines |
| DEF-015 | Minor | `cross_check.sh` | CHECK 4 matched advisory lock in SQL comments | ✅ Fixed (2026-03-19) — filter comment lines |
| DEF-016 | Minor | `ai_gateway/notification_worker.py` | `.table("users").select("phone")` direct read (line 179) — service_role, read-only | ✅ Fixed (2026-04-16) — resolved as Instance 4 in DEF-013 via rpc_get_user_phone |
| DEF-017 | **Critical** | `d01_kernel.sql` | `o.name` → `o.legal_name` in rpc_get_membership_queue + rpc_process_membership_application | ✅ Fixed (2026-03-19) — tested on Supabase |
| DEF-018 | **Critical** | `d01_kernel.sql` | `o.org_type` doesn't exist — need JOIN on `organization_type_assignments` | ✅ Fixed (2026-03-19) — tested on Supabase |
| DEF-019 | **Critical** | `d01_kernel.sql` | `hg.animal_category_code` → `hg.animal_category_id` (uuid), join on `ac.id` not `ac.code` | ✅ Fixed (2026-03-19) — tested on Supabase |
| DEF-020 | Significant | `d01_kernel.sql` | `activity_types` table doesn't exist — `fat.activity_type` is plain text | ✅ Fixed (2026-03-19) — tested on Supabase |
| DEF-021 | Significant | `PoolQueue.tsx` (A11) | Create button was stub — not wired to `rpc_create_pool_request` | ✅ Fixed (2026-04-01) — dialog + RPC-12 call |
| DEF-022 | Significant | `PoolQueue.tsx` (A11) | `rpc_activate_pool_request` (RPC-13) never called — draft requests couldn't start pipeline | ✅ Fixed (2026-04-01) — Activate button per draft request |
| DEF-023 | Significant | `PriceGridManagement.tsx` (A15) | `rpc_publish_price_index_value` (RPC-20) not implemented — price index section absent | ✅ Fixed (2026-04-01) — index form + history table added |
| DEF-024 | **Critical** | `PoolDetail.tsx`, `PriceGridManagement.tsx` | Antitrust disclaimer missing on price screens (Article 171) | ✅ Fixed (2026-04-01) — amber disclaimer card added |
| DEF-025 | Minor | `d02_tsp.sql` RPC-19 | ON CONFLICT `(tsp_sku_id, region_id, valid_from)` — NULL region_id won't trigger constraint | 🟡 Known — verify deployed constraint |
| DEF-026 | **Critical** | `d02_tsp.sql` RPC-20 | `rpc_publish_price_index_value` INSERT uses `price_index_id`/`avg_price_per_kg` but table has `index_id`/`value_per_kg`; missing required `data_source` | ✅ Fixed (2026-04-01) |
| DEF-027 | Significant | `Calculator.tsx`, `RationTab.tsx` | `rpc_list_feed_items` and `rpc_list_animal_categories` called from UI but did not exist in any SQL file | ✅ Fixed (2026-04-09) — created as RPC-F01 + RPC-F02 in d03_feed.sql |
| DEF-028 | **Critical** | `SimpleRationEditor.tsx` | `rpc_save_consulting_ration` called with `p_animal_category_code` (string) instead of `p_animal_category_id` (UUID) — RPC failed for every group | ✅ Fixed (2026-04-10) — load `rpc_list_animal_categories`, resolve code→UUID before call |

---

## Gates

| Gate | Status | Blocking |
|------|--------|----------|
| **DB Gate** | ✅ PASSED (0 critical, 7 significant) | All application code |
| **Dok 6 Gate (Slice 1)** | ✅ PASSED (2026-03-18) | F01, F02, F10, F11 contracts approved |
| **Legal Gate** | 🟡 D-LEGAL-1: review before public launch | Slice 5 public deploy |
| **Slice 1 Gate** | ✅ **PASSED** (2026-03-19) | QA pass + Architect sign-off. DEF-013 accepted. |
| **Slice 2 Gate** | ✅ **PASSED** (2026-03-19) | QA pass + Architect sign-off. |
| **Slice 3 Gate** | ✅ **PASSED** (2026-03-30) | D-GATE-S3 |
| **Slice 4 Gate** | ✅ **PASSED** (2026-03-30) | D-GATE-S4 |
| **Slice 5a Gate** | ✅ **PASSED** (2026-04-01) | D-GATE-S5a. 3 RPCs + 9 tools + 4 farmer screens. |
| **Slice 5b Gate** | ✅ **PASSED** (2026-04-01) | D-GATE-S5b. DEF-021..026 resolved. QA 0 critical. |
| **Slice 6a Gate** | ✅ **PASSED** (2026-03-31) | D-GATE-S6a |
| **Slice 6b Gate** | ⏸ Deferred | D-S6-3: after farmer feedback |
| **Slice 7 Gate** | ⬜ Not started | Merge Slice 7 to main |
| **Slice 8 Gate** | ✅ **PASSED** (2026-04-09) | D-GATE-S8. 9 RPCs, 4 parts, 0 TS errors. DEF-027..032 resolved. |

---

## Slice History

| Slice | Completed | Duration | Notes |
|-------|-----------|----------|-------|
| Slice 0 (Foundation) | 2026-03-18 | 1 day | DB Gate passed, cross_check.sh created |
| Slice 1 (Sick Calf) | 2026-03-19 | 2 days | 9 RPCs, AI Gateway, 4 screens, QA passed |
| Slice 2 (Membership) | 2026-03-19 | 1 day | 2 RPCs, WA notification worker, 2 admin screens, QA passed |
| Slice 3 (Feed) | 2026-03-30 | ~10 days | 6 RPCs, feed tools, 6 screens, QA passed |
| Slice 4 (Operations) | 2026-03-30 | 1 day | 4 RPCs, ops tools + proactive, 5 screens, QA passed |
| Slice 5a (Market Farmer) | 2026-04-01 | 2 days | 3 RPCs, 9 AI tools, 4 screens, QA passed. D-LEGAL-1 |
| Slice 5b (Market Admin) | 2026-04-01 | 1 day | 7 RPCs, 3 admin screens. DEF-021..026 found+fixed. |
| Slice 6a (Expert Console) | 2026-03-31 | 1 day | RPCs 28..32, M01–M06 + A03–A05, QA passed |
| Slice 8 (Ration+Consulting) | ✅ **Done** | 2026-04-09 | 4 части: Feed Справочник (A), NASEM Calculator (B), Ration Builder (C), Financial Integration (D). QA gate PASSED. |
| Ration v2 (ADR-RATION-01) | ✅ **Done** | 2026-04-16 | DEF-RATION-01..06 ✅, nutrient badges ✅, check_only Edge Fn ✅, ProjectWizard params ✅. QA: PASS 0/0/1 |
| Post-release bugs (2026-04-17) | ✅ **Done** | 2026-04-17 | DEF-ROLE-01 + 5 fixes (DB seed, pasture params P2+P3, steer mortality, milk mapping). QA: PASS 0/0/0 |

---

### Ration v2 (ADR-RATION-01) — Season-aware feeding cost split

> **ADR:** ADR-RATION-01 · **Dok 7 §9.2** · Started: 2026-04-16

| Task | Layer | Component | Status | Notes |
|------|-------|-----------|--------|-------|
| DEF-RATION-04 | DB | `consulting_projects`: `pasture_start_month` + `pasture_end_month` columns | ✅ Done (2ae1d4c) | `ADD COLUMN IF NOT EXISTS smallint NOT NULL DEFAULT 5/10 CHECK(BETWEEN 1 AND 12)`. cross_check 0/0/0. |
| DEF-RATION-01 | UI | `SimpleRationEditor.handleSave`: seasonal split — `p_results.pasture/stall` with separate item arrays | ✅ Done (0e2f656) | `p_items` keeps year-avg for RPC compat. `total_cost_per_day` = 6/6-month weighted avg. |
| DEF-RATION-05 | UI | `RationTab` NASEM: categories from `feeding_group` taxonomy via `useAnimalCategoryMappings` | ✅ Done (0e2f656) | Replaces static `CATEGORY_CODE_TO_HERD` filter. Fallback to old logic when taxonomy not loaded. |
| DEF-RATION-06 | UI | `RationTab` COGS summary card: show in both simple and NASEM modes | ✅ Done (0e2f656) | Removed `mode === 'nasem'` guard. |
| DEF-RATION-03 | Backend | `schemas.py` + `feeding_model._is_pasture_month`: pasture season from project params, not hardcoded | ✅ Done (5e0c01a) | `ProjectInput.pasture_start/end_month` (default 5/10). `_is_pasture_month` accepts optional params. Backward-compatible. |
| DEF-RATION-02 | Backend | `feeding_model._calc_from_consulting_rations`: dual-season cost split `results.pasture/stall` | ✅ Done (5e0c01a) | Legacy flat format supported as fallback. `_group_cost` now selects `pasture_cpd` vs `stall_cpd` per month. |
| — | UI | `ProjectWizard.tsx` Step 3: `pasture_start_month` + `pasture_end_month` inputs | ✅ Done (935ae56) | Regional hints: ЦКЗ 5–10, СКЗ 4–9, ЮКЗ 4–11. DEFAULT_PARAMS set. |
| — | UI | `SimpleRationEditor.tsx`: `NutritionBadge` 🟢/🟡 per group × season (pasture + stall) | ✅ Done (0ab9b67) | `check_only` Edge Fn call, debounced 300ms. Non-blocking. |
| — | Edge Fn | `calculate-ration` v6: `check_only` mode + `computeNutrients()` | ✅ Done (e905abe) | Deployed to Supabase, version 6 ACTIVE. No DB write on check_only. |

**QA Gate: ✅ PASSED (2026-04-16)** — 0 Critical · 0 Significant · 1 Minor
**Minor (MIN-RATION-01):** `rpc_save_consulting_ration` + `rpc_get_consulting_rations` in `d09_consulting.sql` use `set search_path = public` (missing `, pg_temp`). All other 8 functions correct. Fix: DB Agent in next SQL pass.
**→ MIN-RATION-01 ✅ Resolved** — all 10 d09 functions verified `set search_path = public, pg_temp` (2026-04-17).

**Architect sign-off: ✅ (2026-04-16)** — No unresolved Critical/Significant findings. ADR-RATION-01 fully closed.

---

### Post-release bug fixes (2026-04-17) — Ration/Engine/Herd Turnover

> **Context:** Комплексный аудит оставшихся дефектов в Рационах, Консалтинге и Обороте стада.  
> **QA verdict:** ✅ PASS · 0 Critical · 0 Significant · 0 Minor (cross_check.sh clean)  
> **Commits:** `601c4e6` (DEF-ROLE-01) + `cc65375` (5 fixes) + `746adb0` (DECISIONS_LOG)

| Fix | Severity | Component | Status |
|-----|----------|-----------|--------|
| DEF-ROLE-01 | Significant | `d01_kernel.sql` + `d07_ai_gateway.sql`: `role_was_overridden` column missing from `ai_conversations` — runtime error on every `load_context_node` call | ✅ Fixed (`601c4e6`) |
| Fix #1 | High | `SimpleRationEditor.tsx` + `RationTab.tsx`: редактор всегда стартовал с DEFAULT_RATIONS, игнорируя сохранённые рационы из БД | ✅ Fixed (`cc65375`) |
| Fix #2 | Medium | `feeding_model.py` Priority 2 (`_calc_from_norms`): `_is_pasture_month` вызывался с хардкод `0`, игнорировал `pasture_start_month` / `pasture_end_month` из проекта | ✅ Fixed (`cc65375`) |
| Fix #3 | Medium | `feeding_model.py` Priority 3 (`_calc_group` closure): то же — `_is_pasture_month(0, m)` без проектных параметров | ✅ Fixed (`cc65375`) |
| Fix #4 | Medium | `herd_turnover.py`: `STEER_MORTALITY_MONTHLY` читал `heifer_mortality_rate` вместо `steer_mortality_rate` | ✅ Fixed (`cc65375`) |
| Fix #5 | Medium | `SimpleRationEditor.tsx`: `milk → HAY_MIXED_GRASS` в simpleMap — сохранение с чужим FK; фильтры сохранения не проверяли наличие feedCodeToId | ✅ Fixed (`cc65375`) |

**QA Agent sign-off: ✅ (2026-04-17)** — cross_check.sh: 0/0/0. All 5 fixes verified against source. DEF-ROLE-01 confirmed in d01 + d07. MIN-RATION-01 resolved independently.

**Architect sign-off: ✅ (2026-04-17)** — No unresolved Critical/Significant findings. All 6 defects closed.

> **Архитектурное наблюдение (QA → Architect):** Функции `fn_is_admin`, `fn_is_expert`, `fn_my_org_ids` определены дважды: в d01 (базовая версия) и в d07 (JWT fast path, D-NEW-1). d07 wins по порядку применения — это намеренно и правильно. Рекомендация: добавить комментарий в d01 к этим трём функциям: `-- SUPERSEDED by d07_ai_gateway.sql (D-NEW-1 JWT fast path). Edit d07, not here.` Предотвратит будущие правки "не в то место". Исполнитель: DB Agent, следующий SQL pass.

---

### Post-release defect fix (2026-04-18) — DEF-REVENUE-PRICES-01 (Revenue module)

> **Context:** Арши заметил ощущение завышенной выручки от собственных бычков. Аудит revenue.py подтвердил три источника: плоская цена 2200 тг/кг на молодняк (рынок КЗ 1600-1800), тихий fallback `STEER_WEIGHT=331` кг маскировал баги weight_model, P8 нарушен (цены захардкожены).
> **QA verdict:** ✅ PASS · 0 Critical · 0 Significant · 0 Minor (cross_check.sh clean, 22 tests passed)
> **Commits:** pending (awaiting CEO approval for push)

| Fix | Severity | Component | Status |
|-----|----------|-----------|--------|
| DEF-REVENUE-PRICES-01 | Significant | `consulting_engine/app/engine/revenue.py` + `schemas.py` + `input_params.py` + `ProjectWizard.tsx`: цены реализации захардкожены (`BASE_PRICES`), fallback на `STEER_WEIGHT=331` маскировал баги weight_model, бычки 2200 тг/кг (рынок 1800) | ✅ Fixed (pending commit) |
| DOC-CONSULTING-SPEC-01 | Minor | `Docs/CONSULTING_MASTER_SPEC.md:613`: хардкод `base_prices = {2200, 1800, 2200, 2200}` противоречил обновлённому коду (P4 violation) | ✅ Fixed (spec now references ProjectInput.price_params) |

**QA Agent sign-off: ✅ (2026-04-18)** — cross_check.sh: 0/0/0. Нет dangling refs на `BASE_PRICES`/`STEER_WEIGHT`/`HEIFER_WEIGHT`. Контракт `price_params` консистентен: schema → input_params → revenue.py → UI. TypeScript clean. Vite HMR 0 errors. Pre-existing payroll test failure подтверждено ДО правок (git stash).

**Architect sign-off: ✅ (2026-04-18)** — QA verdict ok, cross-doc defect найден и починен (CONSULTING_MASTER_SPEC updated). Нет unresolved Critical/Significant. Additive-only (P7): только 4 новых поля в `ProjectInput`, убран hardcode, fallback заменён на loud-fail. Принципы: ✅ P4 (one source of truth восстановлен), ✅ P7 (additive), ✅ P8 (prices now parameters; full DB-reference в следующем ADR), ✅ HS-5.

**Экономический эффект на уже сохранённые проекты при пересчёте:**
- Собственные бычки: **−18%** выручки (2200→1800 тг/кг)
- Выбракованные быки: **−9%** выручки (2200→2000 тг/кг)
- Тёлки плем., коровы-культ: без изменений

**Known follow-up (не блокирует sign-off):**
- `price_reference` таблица в БД с годовым/региональным версионированием — отдельный ADR (полный P8).
- `CPI_ANNUAL = 0.105` всё ещё в коде ([revenue.py:24](consulting_engine/app/engine/revenue.py:24)) — вынести в параметры следующей правкой.
- Цена per-стратегия реализации бычков (6 мес. vs 12 vs 18 мес. — разная per-kg цена на рынке) — будущий ADR.

**Deploy-before-done rule (Phase 2 CAPEX lesson):** sign-off NOT = deployed. Railway autodeploys после `git push main`. Пересчёт существующих проектов через ProjectWizard → Рассчитать подхватит defaults через Pydantic. Изменения в `price_params` не требуют SQL-миграции — params живут в `input_params` JSONB.

---

### Post-release defect fix (2026-04-18) — DEF-CPI-PARAM-01 (CPI/inflation parametrization)

> **Context:** Follow-up #1 из DEF-REVENUE-PRICES-01 списка. `CPI_ANNUAL = 0.105` был захардкожен в двух модулях (revenue.py + opex.py).
> **QA verdict:** ✅ PASS · 0 Critical · 0 Significant · 0 Minor
> **Commits:** pending push

| Fix | Severity | Component | Status |
|-----|----------|-----------|--------|
| DEF-CPI-PARAM-01 | Significant | `revenue.py:24` + `opex.py:21` — module constant `CPI_ANNUAL = 0.105` заменён на `enriched_input["cpi_annual"]` через новое поле `ProjectInput.cpi_annual`. UI: WizardField в Step 4 Финансирование. | ✅ Fixed (pending commit) |

**Economic impact at default:** нулевой — default 10.5% идентичен прежнему hardcode; старые проекты дают те же числа. При изменении инвестором — меняется inflation factor для revenue и OPEX с года 2.

**QA sign-off: ✅ (2026-04-18)** — 22 tests pass, TSC clean, `CPI_ANNUAL` grep: 0 hits, no SQL touched.
**Architect sign-off: ✅ (2026-04-18)** — additive (P7), P8 на уровне project-params, feed_inflation остался независимым.

**Remaining tech debt queue:**
- `price_reference` таблица в БД (full P8, годовое/региональное версионирование) — следующий ADR.
- Цена per-стратегия реализации бычков — будущий ADR.

---

### ADR-PRICES-01 (2026-04-18) — Livestock Sale Prices DB catalog (tech-debt #2 closed)

> **Context:** Follow-up #2 из DEF-REVENUE-PRICES-01 списка. Полный P8 перенос цен КРС из Pydantic hardcoded в `consulting_reference_data` с temporal versioning.
> **QA verdict:** pending
> **Commits:** pending push

| Phase | Severity | Component | Status |
|-------|----------|-----------|--------|
| 1 | Significant | [d09_consulting.sql](d09_consulting.sql): `livestock_prices` category + 3 RPC + 4 seed rows + registry | ✅ Done |
| 2 | Significant | [price_resolver.py](consulting_engine/app/engine/price_resolver.py) NEW + [orchestrator.py](consulting_engine/app/engine/orchestrator.py) invokes + [schemas.py](consulting_engine/app/models/schemas.py) fields → Optional | ✅ Done |
| 3 | Significant | [ProjectWizard.tsx](src/pages/admin/consulting/ProjectWizard.tsx) nullable fields + catalog placeholder via `rpc_list_livestock_prices` | ✅ Done |
| 4 | Significant | [LivestockPricesAdmin.tsx](src/pages/admin/livestock-prices/LivestockPricesAdmin.tsx) NEW + [App.tsx](src/App.tsx) route + [Sidebar.tsx](src/components/layout/Sidebar.tsx) entry | ✅ Done |
| 5 | Minor | [cross_check.sh](cross_check.sh) whitelist + Dok 3 §«Consulting Livestock Prices RPCs» + Dok 7 §12 + DECISIONS_LOG + this entry | ✅ Done |

**Priority chain:** P1 project override → P2 DB catalog → P3 safety default (1800/2200/1800/2000). Backward-compatible: existing saved projects → P1 override → same numbers on recalc.

**Deploy order:** Apply SQL migration on prod Supabase → `git push main` (Railway + Vercel autodeploy).

**Verification:** cross_check.sh 0/0/0 · Python tests 22 passed · TypeScript `tsc --noEmit` clean.

**Remaining tech debt queue (after this):**
- **ADR-PRICES-02** — per-strategy steer pricing (6/12/18 мес). Схема уже поддерживает `age_months`, нужны только seed rows + UI tweak.
- Region dimension + per-org overrides — defer until need.
