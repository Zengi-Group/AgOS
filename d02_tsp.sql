-- ============================================================
-- AGOS Schema: d02_tsp
-- Project: TURAN Agricultural Operating System
-- Consolidated: 2026-03-05 (pre-development baseline)
-- Extended:    2026-06-15 — M4 (Batch/Pool/Offer v1.0) + M6 (TSP Flow v1.0)
--              merged from d09_tsp_m4m6_patch.sql (see SECTION 7).
--
-- Market / TSP (Transparent Supply Pool) module.
Batches, Pools, Matches, Delivery, Prices.
--
-- Depends on: d01_kernel.sql
-- Consolidated from: 002_tsp__1_.sql
--
-- Convention: All statements are idempotent.
--   CREATE TABLE IF NOT EXISTS
--   CREATE OR REPLACE FUNCTION
--   ALTER TABLE ADD COLUMN IF NOT EXISTS
--   INSERT ... ON CONFLICT DO NOTHING
-- ============================================================
-- ============================================================
-- AGOS Migration 002: MARKET / TSP MODULE
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 4 March 2026
--
-- Entities (15 total):
--   Reference (5):  tsp_skus*, weight_categories*, grade_standards*,
--                   valid_combinations*, price_index_methodologies*
--   Operational (8): batches, pool_requests, pools, pool_matches,
--                    delivery_records, pool_manifests,
--                    price_grids, price_indices
--   Log/Append (2):  price_grid_log, price_index_values
--
-- * Reference tables seeded from TSP-Ассортимент-КРС-v2.xlsx
--
-- Cross-checked against:
--   ✅ Dok 1 Domain Model Specification v1.2 (Section 3.3, 4.3, 5.5, 5.7)
--   ✅ Decisions D28–D41, D84, D90
--   ✅ FSM Catalog 5.7 (Batch, PoolRequest, Pool, DeliveryRecord)
--   ✅ Legal Constraints 5.9 (antitrust, data isolation, three-tier)
--   ✅ TSP-Ассортимент-КРС-v2.xlsx (30 SKUs, 3 grades, weight ranges)
--   ✅ Ownership Matrix Section 4.3
--   ✅ Universal Principles P1–P12
--
-- Depends on: 001_kernel.sql
--   (organizations, farms, herd_groups, breeds, productivity_directions,
--    regions, users, platform_events)
--
-- Required by: 003_feed.sql (no hard dep), 004_platform_ai.sql,
--              005_vet.sql (no dep), 006_ops_edu.sql
--
-- LEGAL NOTE (Section 5.9, Article 171 PK RK):
--   TSP = coordination infrastructure, NOT a marketplace.
--   No payments processed. No binding prices. Participation voluntary.
--   Antitrust disclaimer text seeded in grade_standards.legal_disclaimer.
-- ============================================================

-- ============================================================
-- SECTION 1: REFERENCE TABLES (5 tables)
-- P8: Standards as Data, Not Code — all editable by admin
-- Seeded from TSP-Ассортимент-КРС-v2.xlsx
-- ============================================================

-- -------------------------------------------------------
-- grade_standards
-- D31: Grade (НС/С/ВС) in model from day 1; hidden in UI Phase 1
-- D90: All grade attributes in one table (not normalised)
-- Seed data: 3 rows from TSP-Ассортимент-КРС-v2.xlsx
-- -------------------------------------------------------
create table if not exists public.grade_standards (
    id                  uuid    primary key default gen_random_uuid(),
    code                text    not null unique,    -- NS | S | VS
    name_ru             text    not null,           -- НС | С | ВС
    sort_order          int     not null,           -- 1=NS, 2=S, 3=VS (lowest to highest)
    -- Quality criteria (from TSP-Ассортимент-КРС-v2.xlsx)
    bcs_min             numeric(3,1),               -- Body Condition Score minimum
    bcs_max             numeric(3,1),               -- Body Condition Score maximum
    muscle_score        text    not null,           -- М1 – Слабая | М2 – Средняя | М3 – Хорошая
    vet_requirements    text    not null,           -- vet documentation required
    homogeneity_pct_min int,                        -- batch uniformity % minimum
    id_requirement      text    not null,           -- СИРЭС / желательна / не требуется
    yield_pct_min       int     not null,           -- убойный выход % min
    yield_pct_max       int     not null,           -- убойный выход % max
    premium_type        text    not null,           -- none | base | base_reliability
    target_buyers       text,                       -- descriptive, informational only
    -- D28/Legal 5.9: antitrust disclaimer per grade
    is_active           boolean not null default true,
    created_at          timestamptz not null default now()
);
comment on table public.grade_standards is
    'D31: НС/С/ВС grade system. In data model from Phase 1; hidden in UI until market is ready.
     D90: All attributes in one table (not normalised) — grade changes as a whole unit.
     P8: admin-managed. Seed: 3 rows from TSP-Ассортимент-КРС-v2.xlsx.
     Legal 5.9: grade thresholds are association standards (Tier 3), NOT binding price mandates.';

-- -------------------------------------------------------
-- tsp_skus
-- D29: TspCategory ≠ AnimalCategory (different purposes: sales vs herd mgmt)
-- D90: One table, 30 rows = full SKU catalogue from TSP-Ассортимент-КРС-v2.xlsx
-- SKU = breed_group × sex × age_group × weight_category × grade
-- -------------------------------------------------------
create table if not exists public.tsp_skus (
    id              uuid    primary key default gen_random_uuid(),
    sku_code        text    not null unique,     -- TSP-0001 … TSP-0030
    grade_id        uuid    not null references public.grade_standards(id),
    -- Dimensions (denormalised per D90)
    breed_group     text    not null
                                check (breed_group in (
                                    'elite_meat',   -- Элитные мясные породы
                                    'local',        -- Локальные породы (казахская белоголовая etc)
                                    'crossbred'     -- Беспородные / помесные
                                )),
    sex             text    not null
                                check (sex in ('bull', 'heifer', 'cow')),
    age_group       text    not null
                                check (age_group in (
                                    'young_1',  -- Молодняк I:   6–12 мес
                                    'young_2',  -- Молодняк II: 12–24 мес
                                    'adult',    -- Взрослый:    24–48 мес
                                    'senior'    -- Старший:       48+ мес
                                )),
    age_min_months  int     not null,
    age_max_months  int,                -- null = no upper bound (senior)
    weight_category text    not null
                                check (weight_category in (
                                    'light',    -- Лёгкая
                                    'standard', -- Стандартная
                                    'heavy'     -- Тяжёлая
                                )),
    weight_min_kg   int     not null,
    weight_max_kg   int     not null,
    yield_pct_min   int     not null,   -- убойный выход % min (denorm for quick display)
    yield_pct_max   int     not null,
    is_active       boolean not null default true,
    sort_order      int     not null default 0,
    created_at      timestamptz not null default now()
);
comment on table public.tsp_skus is
    'D29: Sales taxonomy (≠ AnimalCategory which is herd management taxonomy).
     D90: 30 rows = full SKU catalogue. Breed group derived from breeds table at Batch creation,
     but stored here as denormalised text for catalogue display without joins.
     SKU = breed_group × sex × age_group × weight_category (grade adds quality dimension).
     Beспородные (crossbred) never get ВС grade — enforced by valid_sku_combinations.';

-- -------------------------------------------------------
-- valid_sku_combinations
-- D31: Enforces which breed_group × grade combos are legally valid
-- Prevents system from creating impossible batches (e.g. Беспородный ВС)
-- Cross-reference with TSP-Ассортимент-КРС-v2.xlsx: crossbred = NS only
-- -------------------------------------------------------
create table if not exists public.valid_sku_combinations (
    id              uuid    primary key default gen_random_uuid(),
    breed_group     text    not null,
    grade_code      text    not null,
    is_valid        boolean not null default true,
    reason          text,   -- explanation when is_valid=false
    created_at      timestamptz not null default now(),
    unique (breed_group, grade_code)
);
comment on table public.valid_sku_combinations is
    'D31: Antitrust-safe enforcement — prevents impossible grade assignments.
     From TSP-Ассортимент-КРС-v2.xlsx: crossbred animals only qualify for NS grade.
     RPC create_batch checks this before allowing grade assignment.
     P8: admin-managed. Changes here = data update, not code deployment.';

-- -------------------------------------------------------
-- weight_classes
-- Dok 1 Q18 RESOLVED: weight ranges extracted from TSP-Ассортимент-КРС-v2.xlsx
-- Weight ranges differ by animal type — stored as descriptive reference
-- Actual weight validation done at Batch level using tsp_skus.weight_min/max_kg
-- -------------------------------------------------------
create table if not exists public.weight_classes (
    id              uuid    primary key default gen_random_uuid(),
    code            text    not null unique,    -- LIGHT | STANDARD | HEAVY
    name_ru         text    not null,
    sort_order      int     not null,
    description_ru  text,   -- descriptive weight ranges (animal-type specific ranges in tsp_skus)
    created_at      timestamptz not null default now()
);
comment on table public.weight_classes is
    'Dok1 Q18 RESOLVED. Lightweight lookup for UI display only.
     Actual weight ranges per animal type live in tsp_skus.weight_min/max_kg.
     Rationale: weight ranges differ by animal type (bull 380-550kg heavy ≠ heifer 320-430kg heavy),
     so a single weight_class range would be misleading. tsp_skus is the authoritative source.';

-- -------------------------------------------------------
-- price_index_methodologies
-- D84: PriceIndex = expert product, not transaction aggregate (Phase 1)
-- Methodology describes HOW the index is calculated
-- -------------------------------------------------------
create table if not exists public.price_index_methodologies (
    id              uuid    primary key default gen_random_uuid(),
    code            text    not null unique,
    name_ru         text    not null,
    description_ru  text,
    data_sources    text[],     -- ['expert_assessment', 'regional_markets', 'transaction_data']
    review_frequency text   not null default 'monthly'
                                check (review_frequency in ('weekly','monthly','quarterly')),
    is_active       boolean not null default true,
    created_at      timestamptz not null default now()
);
comment on table public.price_index_methodologies is
    'D84: Phase 1 = expert assessment only. Phase 2+ = hybrid with real transaction data.
     Stored as reference so PriceIndex can reference specific methodology version.
     P8: admin-managed. methodology change = data update, not code change.';

-- ============================================================
-- SECTION 2: OPERATIONAL TABLES (8 tables)
-- ============================================================

-- -------------------------------------------------------
-- batches
-- FSM 5.7: draft → published → matched | cancelled | expired
--          matched → published (admin rollback)
-- D32: Batch ↔ HerdGroup SOFT link (don't block batch creation if group incomplete)
-- D35: Price snapshot captured at match time (in pool_matches, not here)
-- Ownership Matrix 4.3: Farmer C/U/A; Admin U (match/cancel); AI C (draft)
-- -------------------------------------------------------
create table if not exists public.batches (
    id                  uuid    primary key default gen_random_uuid(),
    organization_id     uuid    not null references public.organizations(id),
    farm_id             uuid    references public.farms(id),           -- D32: soft link
    herd_group_id       uuid    references public.herd_groups(id),    -- D32: soft link
    -- TSP product cell (locked on publish per FSM)
    tsp_sku_id          uuid    references public.tsp_skus(id),
    breed_id            uuid    references public.breeds(id),          -- actual breed (D30)
    -- Batch details
    heads               int     not null check (heads > 0),
    avg_weight_kg       numeric(6,2) check (avg_weight_kg > 0),
    target_month        date    not null,       -- YYYY-MM-01: month of intended delivery
    region_id           uuid    references public.regions(id),         -- dispatch region
    -- FSM status (5.7)
    status              text    not null default 'draft'
                                    check (status in (
                                        'draft',        -- editable, not visible to market
                                        'published',    -- visible, matchable
                                        'matched',      -- assigned to a pool
                                        'cancelled',    -- farmer/admin cancelled
                                        'expired'       -- target_month passed, auto-expired
                                    )),
    -- D31: Grade — nullable Phase 1 (hidden in UI), required Phase 2+
    grade_standard_id   uuid    references public.grade_standards(id),
    -- Notes (always editable regardless of status)
    notes               text,
    -- Rollback tracking (matched → published)
    rollback_reason     text,
    rollback_at         timestamptz,
    rollback_by         uuid    references public.users(id),
    -- Expiry
    expires_at          timestamptz,   -- set by system when published (target_month + buffer)
    -- FSM transition timestamps
    published_at        timestamptz,
    matched_at          timestamptz,
    cancelled_at        timestamptz,
    created_by          uuid    references public.users(id),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.batches is
    'FSM 5.7: draft→published→matched|cancelled|expired. matched→published (rollback).
     D32: farm_id and herd_group_id are SOFT links (nullable) — batch valid without farm profile.
     D31: grade_standard_id nullable Phase 1. tsp_sku_id locked on publish (product cell).
     Editability rule: draft=all fields; published=heads/notes/target_month only (tsp_sku locked);
     matched/cancelled/expired=all locked.
     Legal 5.9 Tier 1: published batch = intention to supply (not binding until pool match).';
comment on column public.batches.target_month is
    'Always stored as first day of month (YYYY-MM-01). UI shows as "Май 2026".
     expires_at set to last day of target_month + 7 days buffer by RPC publish_batch.';

-- -------------------------------------------------------
-- pool_requests
-- D33: PoolRequest 1:1 Pool (one request = one pool, auto-created on activation)
-- FSM 5.7: draft → active → closed | expired
-- D39: MPK demand profile in accepted_categories JSONB (don't over-engineer for 5 MPKs)
-- Ownership Matrix 4.3: MPK C/U/A; Admin U (close)
-- -------------------------------------------------------
create table if not exists public.pool_requests (
    id                  uuid    primary key default gen_random_uuid(),
    organization_id     uuid    not null references public.organizations(id), -- MPK org
    -- Demand profile
    total_heads         int     not null check (total_heads > 0),
    target_month        date    not null,   -- YYYY-MM-01
    region_id           uuid    references public.regions(id),
    -- D39: JSONB for accepted categories (flexible for 5 MPKs — no over-engineering)
    accepted_categories jsonb,  -- [{tsp_sku_id, min_heads, max_heads, priority}]
    -- Premium capacity (from Dok 1 ERD 3.3)
    premium_bulls       int     not null default 0 check (premium_bulls >= 0),
    premium_heifers     int     not null default 0 check (premium_heifers >= 0),
    premium_cows        int     not null default 0 check (premium_cows >= 0),
    -- FSM
    status              text    not null default 'draft'
                                    check (status in (
                                        'draft',    -- MPK configuring
                                        'active',   -- visible, accepting batches (auto-creates Pool)
                                        'closed',   -- filled or manually closed by MPK/admin
                                        'expired'   -- target_month passed
                                    )),
    notes               text,
    closed_at           timestamptz,
    closed_by           uuid    references public.users(id),
    close_reason        text,
    activated_at        timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.pool_requests is
    'FSM 5.7: draft→active→closed|expired.
     D33: activating a pool_request auto-creates one Pool (1:1 relationship).
     D39: accepted_categories JSONB — flexible enough for 5 MPKs without separate table.
     Legal 5.9: pool_request = expression of intent to consider (not binding commitment).
     D40: MPK identity NOT revealed to farmers until Pool transitions to executing.';

-- -------------------------------------------------------
-- pools
-- D33: Created automatically when PoolRequest → active
-- FSM 5.7: filling → filled → executing → dispatched → delivered → executed
--          filling → closed (underfilled, admin decision)
-- D40: Contacts (MPK identity) revealed ONLY at → executing transition
-- Ownership Matrix 4.3: System C; Admin U/A
-- -------------------------------------------------------
create table if not exists public.pools (
    id                  uuid    primary key default gen_random_uuid(),
    pool_request_id     uuid    not null unique references public.pool_requests(id),
    -- Aggregate counters (maintained by RPC on each match)
    matched_heads       int     not null default 0 check (matched_heads >= 0),
    target_heads        int     not null check (target_heads > 0), -- denorm from pool_request
    -- FSM 5.7
    status              text    not null default 'filling'
                                    check (status in (
                                        'filling',      -- accepting batch matches
                                        'filled',       -- matched_heads >= target_heads
                                        'executing',    -- contacts revealed, logistics started
                                        'dispatched',   -- D41: optional intermediate
                                        'delivered',    -- D41: optional intermediate
                                        'executed',     -- final state
                                        'closed'        -- admin: underfilled, no longer accepting
                                    )),
    execution_result    text    check (execution_result in ('full','partial','failed')),
    -- D40: Contact reveal — populated ONLY at → executing transition
    mpk_contact_revealed_at timestamptz,    -- when MPK identity was revealed to matched farmers
    -- Filling deadline (D34: systemic — not left to MPK discretion)
    filling_deadline    date,   -- last day to add batches (set at pool creation)
    -- FSM timestamps
    filled_at           timestamptz,
    executing_at        timestamptz,
    executed_at         timestamptz,
    closed_at           timestamptz,
    -- Admin actions
    confirmed_by        uuid    references public.users(id),  -- admin who confirmed filled→executing
    closed_by           uuid    references public.users(id),
    close_reason        text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.pools is
    'D33: Auto-created when PoolRequest activates. 1:1 with pool_requests.
     D40: CRITICAL — MPK identity (and farmer contacts) revealed ONLY at executing transition.
     Before that: both sides see only anonymous aggregates.
     D41: dispatched/delivered are optional intermediate states (skip to executed if simple).
     execution_result populated at executed state only.
     Legal 5.9: Pool is coordination structure, not transaction. No payment processed here.';
comment on column public.pools.mpk_contact_revealed_at is
    'D40: Legal isolation. Set by RPC transition_pool_to_executing.
     Before this timestamp: farmer sees "Покупатель подобран" but NOT who.
     After: PoolManifest accessible to matched farmers and MPK.';

-- -------------------------------------------------------
-- pool_matches
-- Junction: Pool ↔ Batch (many-to-many via pool)
-- D35: Price snapshot at match time — IMMUTABLE after creation
-- Ownership Matrix 4.3: Admin C/A
-- -------------------------------------------------------
create table if not exists public.pool_matches (
    id                          uuid    primary key default gen_random_uuid(),
    pool_id                     uuid    not null references public.pools(id),
    batch_id                    uuid    not null references public.batches(id),
    -- D35: IMMUTABLE price snapshot captured at match moment
    reference_price_at_match    int,    -- KZT per kg, from price_grid at time of match
    premium_at_match            int,    -- KZT per kg premium (0 if НС grade)
    grade_at_match              text,   -- grade code at time of match (NS/S/VS)
    tsp_sku_at_match            text,   -- sku_code at time of match (immutable record)
    -- Match details
    matched_heads               int     not null check (matched_heads > 0),
    matched_by                  uuid    references public.users(id),  -- admin
    matched_at                  timestamptz not null default now(),
    notes                       text,
    unique (pool_id, batch_id)  -- one batch can only be matched to one pool at a time
);
comment on table public.pool_matches is
    'D35: Price snapshot is IMMUTABLE — never UPDATE these fields after insert.
     Rationale: if price_grid changes after match, the original match price must be preserved
     for audit, dispute resolution, and data analytics integrity.
     grade_at_match / tsp_sku_at_match: snapshot of what was agreed (denorm intentional).
     unique(pool_id, batch_id): same batch cannot be matched to same pool twice.';

-- -------------------------------------------------------
-- delivery_records
-- D36: Actual delivery data for market analytics + reputation calculation
-- FSM 5.7: pending → delivered | rejected | partial
-- Ownership Matrix 4.3: MPK C/U (actuals); Admin U/A (confirm); System C (skeleton)
-- -------------------------------------------------------
create table if not exists public.delivery_records (
    id                  uuid    primary key default gen_random_uuid(),
    pool_match_id       uuid    not null unique references public.pool_matches(id),
    organization_id     uuid    not null references public.organizations(id), -- denorm for RLS
    -- Planned (from batch)
    planned_heads       int     not null,
    -- Actuals (filled by MPK after delivery)
    actual_heads        int,
    actual_avg_weight_kg    numeric(6,2),
    actual_price_per_kg     numeric(8,2),   -- KZT/kg actually paid
    total_amount            numeric(14,2),  -- total deal value (informational only, no payment here)
    currency                text    not null default 'KZT',
    -- Quality assessment at delivery (D36: actuals for analytics)
    actual_grade        text,           -- may differ from matched grade (real assessment)
    actual_yield_pct    numeric(5,2),
    quality_notes       text,
    -- FSM
    status              text    not null default 'pending'
                                    check (status in (
                                        'pending',      -- skeleton created at pool→executing
                                        'delivered',    -- MPK confirmed delivery
                                        'partial',      -- partial delivery accepted
                                        'rejected'      -- delivery rejected (quality/quantity)
                                    )),
    -- D38: Reputation input (D38: calculate_reputation is RPC, not entity)
    is_disputed         boolean not null default false,
    dispute_notes       text,
    -- Timestamps
    delivery_date       date,
    confirmed_by        uuid    references public.users(id),   -- admin
    confirmed_at        timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.delivery_records is
    'D36: Actual delivery data = foundation of reputation system + market analytics.
     Skeleton row created by system at Pool→executing transition (status=pending).
     MPK fills actuals. Admin confirms (D21 in ownership matrix).
     total_amount informational: TSP does NOT process payments (Legal 5.9).
     actual_grade may differ from grade_at_match — real quality assessment at delivery gate.
     D38: reputation = computed RPC over delivery_records, not stored entity.';

-- -------------------------------------------------------
-- pool_manifests
-- D37: Generated PDF document for MPK logistics
-- Accessible ONLY to matched MPK + admin (D40)
-- Ownership Matrix 4.3: System/Admin C; Admin generates
-- -------------------------------------------------------
create table if not exists public.pool_manifests (
    id              uuid    primary key default gen_random_uuid(),
    pool_id         uuid    not null references public.pools(id),
    document_url    text    not null,   -- Supabase Storage URL (signed, time-limited)
    version         int     not null default 1,  -- increments on regeneration
    generated_at    timestamptz not null default now(),
    generated_by    uuid    references public.users(id),
    is_current      boolean not null default true,  -- latest version flag
    created_at      timestamptz not null default now()
);
comment on table public.pool_manifests is
    'D37: PDF manifest for MPK logistics (list of matched batches, farms, volumes, grades).
     D40: RLS restricts access to matched MPK + admin ONLY (not farmers, not other MPKs).
     Multiple versions possible (pool can be updated before executing).
     is_current=true: latest version. Previous versions kept for audit.';

-- -------------------------------------------------------
-- price_grids
-- Reference prices from association (Tier 3 legal, Section 5.9)
-- D35: Price snapshot at match time copies from here
-- MANDATORY antitrust disclaimer (Section 5.9)
-- Ownership Matrix 4.3: Admin C/U/A
-- -------------------------------------------------------
create table if not exists public.price_grids (
    id                      uuid    primary key default gen_random_uuid(),
    tsp_sku_id              uuid    not null references public.tsp_skus(id),
    region_id               uuid    references public.regions(id),  -- null = national (all regions)
    -- Reference prices (KZT/kg)
    base_price_per_kg       int     not null check (base_price_per_kg > 0),
    premium_per_kg          int     not null default 0 check (premium_per_kg >= 0),
    -- Legal 5.9: MANDATORY antitrust disclaimer
    -- Text: «Справочные цены являются индикативными рыночными ориентирами...»
    legal_disclaimer_shown  boolean not null default true,  -- must be true to be published
    -- Validity
    valid_from              date    not null,
    valid_to                date,   -- null = currently active
    is_active               boolean not null default false,   -- admin explicitly activates
    -- Version tracking
    version                 int     not null default 1,
    approved_by             uuid    references public.users(id),
    approved_at             timestamptz,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    -- Only one active price per SKU per region at a time
    unique (tsp_sku_id, region_id, valid_from)
);
comment on table public.price_grids is
    'D35: Prices snapshotted into pool_matches at match time (immutable).
     Legal 5.9 MANDATORY: legal_disclaimer_shown=true required before any price display.
     Disclaimer text: «Справочные цены являются индикативными рыночными ориентирами.
     Итоговые расчётные цены определяются при поставке на основании рыночных условий.
     TURAN не устанавливает, не обеспечивает и не гарантирует цены сделок. Участие добровольное.»
     Tier 3 legal: prices are association benchmarks, NOT mandated rates.
     region_id=null = national price (applies when no region-specific price exists).';
comment on column public.price_grids.legal_disclaimer_shown is
    'MUST be true before price is visible in any UI (web or AI).
     RPC get_price_for_sku checks this before returning data.
     Setting to false = effectively pulling price from public view.';

-- -------------------------------------------------------
-- price_grid_log
-- Append-only audit trail of all price_grid changes
-- Auto-populated by trigger on price_grids updates
-- -------------------------------------------------------
create table if not exists public.price_grid_log (
    id                  uuid    primary key default gen_random_uuid(),
    price_grid_id       uuid    not null references public.price_grids(id),
    tsp_sku_id          uuid    not null references public.tsp_skus(id),  -- denorm
    old_base_price      int,
    new_base_price      int,
    old_premium         int,
    new_premium         int,
    changed_by          uuid    references public.users(id),
    change_reason       text,
    created_at          timestamptz not null default now()
    -- No updated_at: APPEND-ONLY
);
comment on table public.price_grid_log is
    'P12 (Temporal): append-only price history. Never UPDATE.
     Auto-populated by trigger fn_log_price_grid_change on price_grids UPDATE.
     Required for: market analytics, dispute resolution, Data Flywheel.';

-- -------------------------------------------------------
-- price_indices
-- D84: Expert-assessed market index (Phase 1); hybrid with transactions (Phase 2+)
-- Distinct from price_grids: index = market signal, grid = reference for TSP
-- -------------------------------------------------------
create table if not exists public.price_indices (
    id                  uuid    primary key default gen_random_uuid(),
    methodology_id      uuid    not null references public.price_index_methodologies(id),
    code                text    not null unique,    -- e.g. TURAN-BEEF-KZ-NATIONAL
    name_ru             text    not null,
    tsp_sku_id          uuid    references public.tsp_skus(id),  -- null = composite index
    region_id           uuid    references public.regions(id),   -- null = national
    frequency           text    not null default 'monthly'
                                    check (frequency in ('daily','weekly','monthly','quarterly')),
    description_ru      text,
    is_active           boolean not null default true,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.price_indices is
    'D84: Phase 1 = expert assessment only. phase 2+ = hybrid.
     Distinct from price_grids: index reflects MARKET reality; grid is ASSOCIATION benchmark.
     code format: TURAN-{commodity}-{region}-{scope} e.g. TURAN-BEEF-KZ-NATIONAL.
     tsp_sku_id null = composite/basket index (e.g. all beef categories average).';

-- -------------------------------------------------------
-- price_index_values
-- Append-only time series of index values
-- D84: Expert publishes periodically; Phase 2+ may auto-populate from transactions
-- -------------------------------------------------------
create table if not exists public.price_index_values (
    id              uuid    primary key default gen_random_uuid(),
    index_id        uuid    not null references public.price_indices(id),
    period_date     date    not null,       -- first day of period
    value_per_kg    numeric(8,2) not null check (value_per_kg > 0),
    currency        text    not null default 'KZT',
    data_source     text    not null
                                check (data_source in (
                                    'expert_assessment',    -- D84 Phase 1: expert judgment
                                    'transaction_data',     -- Phase 2+: real deal data
                                    'external_reference',   -- external market data
                                    'composite'             -- weighted average of multiple sources
                                )),
    sample_size     int,            -- number of transactions if data_source=transaction_data
    confidence_pct  int,            -- expert confidence 0-100
    published       boolean not null default false,
    published_by    uuid    references public.users(id),
    published_at    timestamptz,
    notes           text,
    created_at      timestamptz not null default now(),
    unique (index_id, period_date)  -- one value per index per period
    -- No updated_at: APPEND-ONLY time series
);
comment on table public.price_index_values is
    'D84: Append-only time series. published=false = draft (not visible to farmers/MPKs).
     Admin/expert publishes. Phase 2+: transaction_data source auto-populated from delivery_records.
     sample_size and confidence_pct = transparency metadata for index quality.
     Legal 5.9: index values are informational market signals, NOT price mandates.';

-- ============================================================
-- SECTION 3: INDEXES
-- ============================================================

-- grade_standards
create index idx_grade_code on public.grade_standards (code);

-- tsp_skus (heavily queried for batch creation and pool matching)
create index idx_tsp_skus_grade     on public.tsp_skus (grade_id);
create index idx_tsp_skus_breed_sex on public.tsp_skus (breed_group, sex, age_group);
create index idx_tsp_skus_active    on public.tsp_skus (is_active);

-- batches (critical — queried by status, org, target_month constantly)
create index idx_batches_org_status     on public.batches (organization_id, status);
create index idx_batches_status_month   on public.batches (status, target_month)
    where status in ('published', 'matched');
create index idx_batches_sku            on public.batches (tsp_sku_id)
    where tsp_sku_id is not null;
create index idx_batches_herd_group     on public.batches (herd_group_id)
    where herd_group_id is not null;
create index idx_batches_region_month   on public.batches (region_id, target_month)
    where status = 'published';
create index idx_batches_expires        on public.batches (expires_at)
    where status = 'published';  -- cron expiry job

-- pool_requests
create index idx_pool_req_org_status    on public.pool_requests (organization_id, status);
create index idx_pool_req_status_month  on public.pool_requests (status, target_month)
    where status = 'active';

-- pools
create index idx_pools_request          on public.pools (pool_request_id);
create index idx_pools_status           on public.pools (status);

-- pool_matches
create index idx_pm_pool    on public.pool_matches (pool_id);
create index idx_pm_batch   on public.pool_matches (batch_id);

-- delivery_records
create index idx_dr_match   on public.delivery_records (pool_match_id);
create index idx_dr_org     on public.delivery_records (organization_id);
create index idx_dr_status  on public.delivery_records (status);

-- pool_manifests
create index idx_manifests_pool_current on public.pool_manifests (pool_id, is_current)
    where is_current = true;

-- price_grids
create index idx_pg_sku_active  on public.price_grids (tsp_sku_id, is_active)
    where is_active = true;
create index idx_pg_region      on public.price_grids (region_id)
    where region_id is not null;

-- price_grid_log
create index idx_pgl_grid_time  on public.price_grid_log (price_grid_id, created_at desc);

-- price_indices
create index idx_pi_sku         on public.price_indices (tsp_sku_id)
    where tsp_sku_id is not null;

-- price_index_values
create index idx_piv_index_date on public.price_index_values (index_id, period_date desc);
create index idx_piv_published  on public.price_index_values (index_id, published)
    where published = true;

-- ============================================================
-- SECTION 4: ROW LEVEL SECURITY
-- Core rule: Farmer sees OWN batches only. Aggregated data = anonymous RPCs.
-- MPK sees OWN pool_requests/pools. Contacts revealed only at executing.
-- Legal 5.9: zero cross-farmer data visibility.
-- ============================================================

alter table public.grade_standards          enable row level security;
alter table public.tsp_skus                 enable row level security;
alter table public.valid_sku_combinations   enable row level security;
alter table public.weight_classes           enable row level security;
alter table public.price_index_methodologies enable row level security;
alter table public.batches                  enable row level security;
alter table public.pool_requests            enable row level security;
alter table public.pools                    enable row level security;
alter table public.pool_matches             enable row level security;
alter table public.delivery_records         enable row level security;
alter table public.pool_manifests           enable row level security;
alter table public.price_grids              enable row level security;
alter table public.price_grid_log           enable row level security;
alter table public.price_indices            enable row level security;
alter table public.price_index_values       enable row level security;

-- Reference tables: readable by all authenticated users
create policy "grade_standards_read_auth"       on public.grade_standards       for select using (auth.uid() is not null);
create policy "grade_standards_admin_write"     on public.grade_standards       for all    using (public.fn_is_admin());
create policy "tsp_skus_read_auth"              on public.tsp_skus              for select using (auth.uid() is not null);
create policy "tsp_skus_admin_write"            on public.tsp_skus              for all    using (public.fn_is_admin());
create policy "valid_combos_read_auth"          on public.valid_sku_combinations for select using (auth.uid() is not null);
create policy "valid_combos_admin_write"        on public.valid_sku_combinations for all    using (public.fn_is_admin());
create policy "weight_classes_read_auth"        on public.weight_classes        for select using (auth.uid() is not null);
create policy "weight_classes_admin_write"      on public.weight_classes        for all    using (public.fn_is_admin());
create policy "pim_read_auth"                   on public.price_index_methodologies for select using (auth.uid() is not null);
create policy "pim_admin_write"                 on public.price_index_methodologies for all    using (public.fn_is_admin());

-- Batches: farmer sees own; admin sees all
create policy "batches_read_own"    on public.batches for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());
create policy "batches_write_own"   on public.batches for all
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());

-- Pool requests: MPK sees own; admin sees all
create policy "pool_req_read_own"   on public.pool_requests for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());
create policy "pool_req_write_own"  on public.pool_requests for all
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());

-- Pools: MPK + matched farmers (only own); admin all
-- D40: farmer sees pool only AFTER their batch is matched
-- DEF-TSP-M4-OWNERSHIP (resolved): MPK ownership checked via pools.organization_id.
create policy "pools_read"          on public.pools for select
    using (
        public.fn_is_admin()
        or organization_id = any(public.fn_my_org_ids())
        or id in (
            select pm.pool_id from public.pool_matches pm
            join public.batches b on b.id = pm.batch_id
            where b.organization_id = any(public.fn_my_org_ids())
        )
    );
create policy "pools_admin_write"   on public.pools for all using (public.fn_is_admin());

-- Pool matches: farmer sees own batch matches; MPK sees own pool matches; admin all
create policy "pool_matches_read"   on public.pool_matches for select
    using (
        public.fn_is_admin()
        or batch_id in (
            select id from public.batches
            where organization_id = any(public.fn_my_org_ids())
        )
        or pool_id in (
            select id from public.pools
            where organization_id = any(public.fn_my_org_ids())
        )
    );
create policy "pool_matches_admin_write" on public.pool_matches for all using (public.fn_is_admin());

-- Delivery records: farmer sees own; MPK sees own; admin all
create policy "delivery_read_own"   on public.delivery_records for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());
create policy "delivery_mpk_write"  on public.delivery_records for update
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());

-- Pool manifests: D40 — only matched MPK + admin
-- DEF-TSP-M4-OWNERSHIP (resolved): MPK ownership checked via pools.organization_id.
create policy "manifests_read"      on public.pool_manifests for select
    using (
        public.fn_is_admin()
        or pool_id in (
            select id from public.pools
            where organization_id = any(public.fn_my_org_ids())
              and status in ('executing','dispatched','delivered','executed')
        )
    );
create policy "manifests_admin_write" on public.pool_manifests for all using (public.fn_is_admin());

-- Price grids: all authenticated read (with disclaimer); admin write
create policy "price_grids_read_auth"   on public.price_grids for select
    using (auth.uid() is not null and legal_disclaimer_shown = true);
create policy "price_grids_admin_write" on public.price_grids for all using (public.fn_is_admin());

-- Price grid log: admin only
create policy "pgl_admin_read"  on public.price_grid_log for select using (public.fn_is_admin());

-- Price indices and values: read authenticated; write admin
create policy "pi_read_auth"    on public.price_indices       for select using (auth.uid() is not null);
create policy "pi_admin_write"  on public.price_indices       for all    using (public.fn_is_admin());
create policy "piv_read_published" on public.price_index_values for select
    using (published = true or public.fn_is_admin());
create policy "piv_admin_write" on public.price_index_values  for all    using (public.fn_is_admin());

-- ============================================================
-- SECTION 5: TRIGGERS
-- ============================================================

-- updated_at triggers
create trigger trg_batches_updated_at
    before update on public.batches
    for each row execute function public.fn_set_updated_at();

create trigger trg_pool_requests_updated_at
    before update on public.pool_requests
    for each row execute function public.fn_set_updated_at();

create trigger trg_pools_updated_at
    before update on public.pools
    for each row execute function public.fn_set_updated_at();

create trigger trg_delivery_records_updated_at
    before update on public.delivery_records
    for each row execute function public.fn_set_updated_at();

create trigger trg_price_grids_updated_at
    before update on public.price_grids
    for each row execute function public.fn_set_updated_at();

create trigger trg_price_indices_updated_at
    before update on public.price_indices
    for each row execute function public.fn_set_updated_at();

-- Price grid change log trigger
create or replace function public.fn_log_price_grid_change()
returns trigger language plpgsql security definer as $$
begin
    if (old.base_price_per_kg <> new.base_price_per_kg
        or old.premium_per_kg <> new.premium_per_kg) then
        insert into public.price_grid_log (
            price_grid_id, tsp_sku_id,
            old_base_price, new_base_price,
            old_premium, new_premium,
            changed_by
        ) values (
            new.id, new.tsp_sku_id,
            old.base_price_per_kg, new.base_price_per_kg,
            old.premium_per_kg, new.premium_per_kg,
            public.fn_current_user_id()
        );
    end if;
    return new;
end;
$$;

create trigger trg_price_grid_log
    after update on public.price_grids
    for each row execute function public.fn_log_price_grid_change();

-- ============================================================
-- SECTION 6: SEED DATA
-- Source: TSP-Ассортимент-КРС-v2.xlsx (30 SKUs)
-- P8: Admin-editable after migration
-- ============================================================

-- Grade standards (3 rows)
insert into public.grade_standards (
    code, name_ru, sort_order,
    bcs_min, bcs_max, muscle_score,
    vet_requirements, homogeneity_pct_min,
    id_requirement, yield_pct_min, yield_pct_max,
    premium_type, target_buyers
) values
(
    'NS', 'Нестандарт', 1,
    null, 2.5, 'М1 – Слабая',
    'Минимальный / неполный', null,
    'Не требуется', 44, 48,
    'none', 'МПК с гибкими требованиями'
),
(
    'S', 'Стандарт', 2,
    2.5, 5.0, 'М2 – Средняя',
    'Ветпаспорт + здоров', 70,
    'Желательна', 48, 52,
    'base', 'Большинство МПК, откормочники'
),
(
    'VS', 'Высший стандарт', 3,
    3.5, 4.5, 'М3 – Хорошая',
    'Полный пакет (бруц/туб)', 80,
    'Обязательна (СИРЭС)', 52, 58,
    'base_reliability', 'Premium МПК, экспорт, Mitsui'
)
on conflict (code) do nothing;

-- Weight classes (3 rows)
insert into public.weight_classes (code, name_ru, sort_order, description_ru) values
    ('LIGHT',    'Лёгкая',       1, 'Молодняк I: 150–260 кг'),
    ('STANDARD', 'Стандартная',  2, 'Молодняк II–Взрослый: 220–480 кг (диапазон по типу)'),
    ('HEAVY',    'Тяжёлая',      3, 'Молодняк II–Взрослый: 320–650 кг (диапазон по типу)')
on conflict (code) do nothing;

-- Valid breed × grade combinations
-- Source: TSP-Ассортимент-КРС-v2.xlsx — crossbred = NS only
insert into public.valid_sku_combinations (breed_group, grade_code, is_valid, reason) values
    ('elite_meat', 'NS', true,  null),
    ('elite_meat', 'S',  true,  null),
    ('elite_meat', 'VS', true,  null),
    ('local',      'NS', true,  null),
    ('local',      'S',  true,  null),
    ('local',      'VS', true,  null),
    ('crossbred',  'NS', true,  null),
    ('crossbred',  'S',  false, 'Беспородные животные не соответствуют критериям Стандарт (BCS, мышечность, однородность)'),
    ('crossbred',  'VS', false, 'Беспородные животные не соответствуют критериям Высший стандарт')
on conflict (breed_group, grade_code) do nothing;

-- TSP SKUs (30 rows from TSP-Ассортимент-КРС-v2.xlsx)
-- Format: (sku_code, grade_code, breed_group, sex, age_group, age_min, age_max,
--          weight_category, weight_min, weight_max, yield_min, yield_max, sort_order)
insert into public.tsp_skus (
    sku_code, grade_id, breed_group, sex, age_group,
    age_min_months, age_max_months,
    weight_category, weight_min_kg, weight_max_kg,
    yield_pct_min, yield_pct_max, sort_order
)
select
    b.sku_code,
    g.id as grade_id,
    b.breed_group, b.sex, b.age_group,
    b.age_min_months, b.age_max_months,
    b.weight_category, b.weight_min_kg, b.weight_max_kg,
    b.yield_pct_min, b.yield_pct_max, b.sort_order
from (values
    -- === ЭЛИТНЫЕ МЯСНЫЕ (elite_meat) ===
    ('TSP-0001','NS','elite_meat','bull','young_1',  6,  12,'light',    150,260,44,48, 1),
    ('TSP-0002','S', 'elite_meat','bull','young_2', 12,  24,'standard', 260,380,48,52, 2),
    ('TSP-0003','VS','elite_meat','bull','young_2', 12,  24,'heavy',    380,550,52,58, 3),
    ('TSP-0004','S', 'elite_meat','bull','adult',   24,  48,'standard', 350,480,48,52, 4),
    ('TSP-0005','VS','elite_meat','bull','adult',   24,  48,'heavy',    480,650,52,58, 5),
    ('TSP-0006','S', 'elite_meat','heifer','young_2',12, 24,'standard', 220,320,48,52, 6),
    ('TSP-0007','VS','elite_meat','heifer','young_2',12, 24,'heavy',    320,430,52,58, 7),
    ('TSP-0008','S', 'elite_meat','cow','adult',    24,  48,'standard', 320,430,48,52, 8),
    ('TSP-0009','VS','elite_meat','cow','adult',    24,  48,'heavy',    430,580,52,58, 9),
    ('TSP-0010','S', 'elite_meat','cow','senior',   48,null,'standard', 280,400,48,52,10),
    -- === ЛОКАЛЬНЫЕ (local) ===
    ('TSP-0011','NS','local','bull','young_1',  6,  12,'light',    150,260,44,48,11),
    ('TSP-0012','S', 'local','bull','young_2', 12,  24,'standard', 260,380,48,52,12),
    ('TSP-0013','VS','local','bull','young_2', 12,  24,'heavy',    380,550,52,58,13),
    ('TSP-0014','S', 'local','bull','adult',   24,  48,'standard', 350,480,48,52,14),
    ('TSP-0015','VS','local','bull','adult',   24,  48,'heavy',    480,650,52,58,15),
    ('TSP-0016','S', 'local','heifer','young_2',12, 24,'standard', 220,320,48,52,16),
    ('TSP-0017','VS','local','heifer','young_2',12, 24,'heavy',    320,430,52,58,17),
    ('TSP-0018','S', 'local','cow','adult',    24,  48,'standard', 320,430,48,52,18),
    ('TSP-0019','VS','local','cow','adult',    24,  48,'heavy',    430,580,52,58,19),
    ('TSP-0020','S', 'local','cow','senior',   48,null,'standard', 280,400,48,52,20),
    -- === БЕСПОРОДНЫЕ (crossbred) — только NS ===
    ('TSP-0021','NS','crossbred','bull','young_1',  6,  12,'light',    150,260,44,48,21),
    ('TSP-0022','NS','crossbred','bull','young_2', 12,  24,'standard', 260,380,44,48,22),
    ('TSP-0023','NS','crossbred','bull','young_2', 12,  24,'heavy',    380,550,44,48,23),
    ('TSP-0024','NS','crossbred','bull','adult',   24,  48,'standard', 350,480,44,48,24),
    ('TSP-0025','NS','crossbred','bull','adult',   24,  48,'heavy',    480,650,44,48,25),
    ('TSP-0026','NS','crossbred','heifer','young_2',12, 24,'standard', 220,320,44,48,26),
    ('TSP-0027','NS','crossbred','heifer','young_2',12, 24,'heavy',    320,430,44,48,27),
    ('TSP-0028','NS','crossbred','cow','adult',    24,  48,'standard', 320,430,44,48,28),
    ('TSP-0029','NS','crossbred','cow','adult',    24,  48,'heavy',    430,580,44,48,29),
    ('TSP-0030','NS','crossbred','cow','senior',   48,null,'standard', 280,400,44,48,30)
) as b(sku_code, grade_code, breed_group, sex, age_group,
       age_min_months, age_max_months,
       weight_category, weight_min_kg, weight_max_kg,
       yield_pct_min, yield_pct_max, sort_order)
join public.grade_standards g on g.code = b.grade_code
on conflict (sku_code) do nothing;

-- Price index methodology (Phase 1: expert assessment)
insert into public.price_index_methodologies
    (code, name_ru, description_ru, data_sources, review_frequency)
values (
    'EXPERT_MONTHLY',
    'Экспертная оценка (ежемесячно)',
    'Ежемесячная оценка рыночных цен аналитиками ассоциации на основе региональных рынков и отраслевых данных.',
    array['expert_assessment','regional_markets'],
    'monthly'
) on conflict (code) do nothing;

-- ============================================================
-- SECTION 7: M4 + M6 EXTENSION (merged 2026-06-15)
-- ============================================================
-- Source: d09_tsp_m4m6_patch.sql v1.0 — consolidated into canonical file
-- per CLAUDE.md ("separate patch files are FORBIDDEN").
-- All statements idempotent: safe to re-run on existing DB.
--
-- Decisions implemented:
--   M4 §1.1:  livestock_categories, livestock_category_rules,
--             reference_prices, minimum_prices, batch_events;
--             Offer entity (broadcast-механика);
--             Pool = PoolRequest absorbed (pool_requests deprecated).
--   D-M6-1,3,9: tsp_config (offer_window=24h, mpk_window=24h,
--                publish_lead=7d, price_step_down=100₸/kg).
--   D-M6-4:   pool_regions (rayon-level matching).
--   D-M6-5/12: batches.status 'confirmed' (identity revealed at confirmed).
--   D-M6-6:   batches.ready_from / ready_to.
--   D-M6-7:   batches.scheduled_publish_at + 'scheduled' status.
--   D-M6-8:   pools.delivery_from / delivery_to (overlap predicate).
--   D-M6-10:  batches dispatched/delivered at batch level (two-sided handshake).
--   D-M6-11:  review_dimensions, deal_reviews, deal_review_dimension_scores.
--   D-M6-12:  visible_at double-blind reveal.
--   D-M6-13:  pool_lines (container model), batches.pool_line_id,
--             pools.total_target_volume_kg.
-- ============================================================

-- ------------------------------------------------------------
-- 7.1: EXTEND batches TABLE
-- ------------------------------------------------------------

-- 7.1.1 Temporal model: delivery window on Batch (D-M6-6)
alter table public.batches
    add column if not exists ready_from date,
    add column if not exists ready_to   date;

comment on column public.batches.ready_from is
    'D-M6-6: Earliest date farmer can dispatch this batch. Invariant: ready_to >= ready_from.
     Locked when batch reaches state=matched. Drives scheduled_publish_at.';
comment on column public.batches.ready_to is
    'D-M6-6: Latest date farmer can hold batch ready for dispatch.
     Matching predicate: batch.ready_window ∩ pool.delivery_window ≠ ∅ (D-M6-8).';

-- 7.1.2 Deferred publication (D-M6-7)
alter table public.batches
    add column if not exists scheduled_publish_at timestamptz;

comment on column public.batches.scheduled_publish_at is
    'D-M6-7: = ready_from − tsp_config.publish_lead_days.
     NULL or ≤ now → spot (immediate matching).
     > now → batch enters state=scheduled until system job fires at this timestamp.';

-- 7.1.3 Price fields (M4 §2)
alter table public.batches
    add column if not exists farmer_price_per_kg int check (farmer_price_per_kg > 0),
    add column if not exists deal_price_per_kg   int check (deal_price_per_kg > 0);

comment on column public.batches.farmer_price_per_kg is
    'M4 §2: ₸/kg set by farmer at publication. Soft-warned if < minimum_price (Art.171 PK RK).
     Can be lowered in awaiting_price_decision → triggers new broadcast (D-M6-3, fixed 100₸ step).';
comment on column public.batches.deal_price_per_kg is
    'M4 §2: Locked deal price. = winning pool.mpk_price (auto-match)
     or offer.offered_price (broadcast-match). Immutable after match. ₸/kg.';

-- 7.1.4 Pool line FK — column added here; FK constraint added after pool_lines created (7.4)
alter table public.batches
    add column if not exists pool_line_id uuid;

comment on column public.batches.pool_line_id is
    'D-M6-13: FK → pool_lines.id. Replaces conceptual batch.pool_id.
     NULL = unmatched (or returned after pool closure). Locked at state=matched.
     FK constraint added in 7.4 after pool_lines table creation.';

-- 7.1.5 FSM timestamps (M4 §3 + M6 §3)
alter table public.batches
    add column if not exists scheduled_at               timestamptz,
    add column if not exists offering_at                timestamptz,
    add column if not exists awaiting_price_decision_at timestamptz,
    add column if not exists confirmed_at               timestamptz,
    add column if not exists dispatched_at              timestamptz,
    add column if not exists delivered_at               timestamptz;

-- 7.1.6 Expand status CHECK to include all M4 + M6 states
-- M4 §3.1 states: draft, published, offering, awaiting_price_decision,
--                 matched, confirmed, dispatched, delivered, cancelled, failed
-- M6 §3 adds:     scheduled
-- Legacy kept:    expired (backward compat, deprecated going forward)
do $$
declare v_cname text;
begin
    select conname into v_cname
      from pg_constraint
     where conrelid = 'public.batches'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%status%'
     limit 1;
    if v_cname is not null then
        execute 'alter table public.batches drop constraint ' || quote_ident(v_cname);
    end if;
end $$;

alter table public.batches
    add constraint batches_status_check check (status in (
        -- M4 + M6 canonical states
        'draft',                    -- editable, not visible to market
        'scheduled',                -- D-M6-7: future publish; waiting for scheduled_publish_at
        'published',                -- visible, no match yet; retry-match on new Pool
        'offering',                 -- M4 §5: broadcast Offers sent to MPKs, FCFS 24h
        'awaiting_price_decision',  -- M4 §2.6: all Offers expired; farmer decides price
        'matched',                  -- in a Pool.pool_line, awaiting pool close
        'confirmed',                -- D-M6-5: pool closed, deal locked; identity revealed
        'dispatched',               -- D-M6-10: farmer confirmed dispatch (BT-16 amended)
        'delivered',                -- D-M6-10: MPK confirmed receipt at batch level
        'cancelled',                -- terminal negative (farmer or admin)
        'failed',                   -- M4: terminal error state
        -- Legacy (backward compat only — do not use in new code)
        'expired'                   -- DEPRECATED: use pool expiry logic
    ));

comment on column public.batches.status is
    'FSM (M4 §3 + M6 §3):
     draft → scheduled|published|offering|matched → confirmed → dispatched → delivered.
     Parallel unhappy: → awaiting_price_decision → offering (price lowered).
     Terminal: cancelled, failed. Legacy ''expired'' kept for compat.';

-- ------------------------------------------------------------
-- 7.2: EXTEND pools TABLE
-- ------------------------------------------------------------

-- 7.2.1 Pool is now self-contained (M4: PoolRequest absorbed → pool_request_id nullable)
alter table public.pools
    alter column pool_request_id drop not null;

comment on column public.pools.pool_request_id is
    'M4: PoolRequest absorbed into Pool. DEPRECATED FK.
     New Pool records: pool_request_id = NULL.
     Old records retain their value. pool_requests table is deprecated.';

-- 7.2.1.1 DEF-TSP-M4-OWNERSHIP — Pool owns its MPK organization_id directly.
-- Before this fix: ownership was derived via LEFT JOIN to pool_requests, which forced
-- rpc_create_pool to insert a "stub" pool_request row only to carry the MPK org id.
-- This fix denormalises organization_id onto pools, removes the stub workaround,
-- and lets all owner-checks use a single column comparison (faster, simpler, RLS-clean).
alter table public.pools
    add column if not exists organization_id uuid references public.organizations(id);

-- Backfill legacy rows from their pool_request stub (idempotent — only fills NULLs).
update public.pools p
   set organization_id = pr.organization_id
  from public.pool_requests pr
 where pr.id = p.pool_request_id
   and p.organization_id is null
   and pr.organization_id is not null;

-- After backfill, ownership is required for every pool (M4 invariant).
-- Idempotent: SET NOT NULL is a no-op if the column is already NOT NULL.
alter table public.pools
    alter column organization_id set not null;

create index if not exists idx_pools_org_status on public.pools (organization_id, status);

comment on column public.pools.organization_id is
    'D-M6-OWNERSHIP: MPK organization that owns this pool.
     Denormalised onto pools so owner-checks do not need a join through
     the deprecated pool_requests table. NOT NULL — every pool has exactly one MPK owner.';

-- 7.2.2 Aggregate volume target — container model (D-M6-13)
alter table public.pools
    add column if not exists total_target_volume_kg int check (total_target_volume_kg > 0);

comment on column public.pools.total_target_volume_kg is
    'D-M6-13: Aggregate target in kg across all pool_lines.
     Pool "filled" when Σ(matched batch volumes by line) reaches this.
     Complements target_heads (kept for backward compat).';

-- 7.2.3 Pool delivery window — overlap matching predicate (D-M6-8)
alter table public.pools
    add column if not exists delivery_from date,
    add column if not exists delivery_to   date;

comment on column public.pools.delivery_from is
    'D-M6-8: Pool delivery window start.
     Matching predicate: batch.[ready_from,ready_to] ∩ pool.[delivery_from,delivery_to] ≠ ∅.';
comment on column public.pools.delivery_to is
    'D-M6-8: Pool delivery window end.';

-- 7.2.4 Expand pools status CHECK (M4 §4.1)
-- M4 canonical: draft, filling, awaiting_mpk_decision, closed_filled,
--               closed_partial, closed_unfilled, executing, completed,
--               cancelled, expired_empty
-- Legacy kept:  filled, dispatched, delivered, executed, closed
do $$
declare v_cname text;
begin
    select conname into v_cname
      from pg_constraint
     where conrelid = 'public.pools'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%status%'
     limit 1;
    if v_cname is not null then
        execute 'alter table public.pools drop constraint ' || quote_ident(v_cname);
    end if;
end $$;

alter table public.pools
    add constraint pools_status_check check (status in (
        -- M4 §4.1 canonical states
        'draft',                -- MPK configuring, not yet published
        'filling',              -- published, accepting batch matches
        'awaiting_mpk_decision',-- window expired, partial fill; MPK must decide
        'closed_filled',        -- target reached (incl. overshoot); batches → confirmed
        'closed_partial',       -- MPK accepted partial fill
        'closed_unfilled',      -- MPK returned batches (or default after decision window)
        'executing',            -- dispatch started
        'completed',            -- all batches delivered
        'cancelled',            -- MPK cancelled before close
        'expired_empty',        -- window expired, zero batches matched
        -- Legacy (backward compat only — do not use in new code)
        'filled',       -- DEPRECATED → use closed_filled
        'dispatched',   -- DEPRECATED at pool level → use batch dispatched
        'delivered',    -- DEPRECATED at pool level → use batch delivered
        'executed',     -- DEPRECATED → use completed
        'closed'        -- DEPRECATED → use closed_filled/closed_partial/closed_unfilled
    ));

-- 7.2.5 Pool FSM timestamps
alter table public.pools
    add column if not exists published_at          timestamptz,
    add column if not exists awaiting_decision_at  timestamptz,
    add column if not exists cancelled_at          timestamptz,
    add column if not exists completed_at          timestamptz;

-- ------------------------------------------------------------
-- 7.3: DEPRECATE pool_requests TABLE
-- ------------------------------------------------------------

comment on table public.pool_requests is
    'DEPRECATED — M4 decision 2026-05-16: PoolRequest entity absorbed into Pool.
     Table and existing rows kept for backward compat. Do NOT create new pool_request records.
     New MPK pools are created via rpc_create_pool() with pool_lines array.
     pools.pool_request_id FK is now nullable.';

-- ------------------------------------------------------------
-- 7.4: NEW TABLE — pool_lines
-- Category-level rows within an MPK Pool container (D-M6-13)
-- ------------------------------------------------------------

create table if not exists public.pool_lines (
    id                  uuid    primary key default gen_random_uuid(),
    pool_id             uuid    not null references public.pools(id) on delete cascade,
    -- Category link (tsp_sku until livestock_categories is seeded — D-M6-13)
    tsp_sku_id          uuid    references public.tsp_skus(id),
    category_label      text,   -- human-readable label (used until classifier finalised)
    -- MPK pricing
    mpk_price_per_kg    int     not null check (mpk_price_per_kg > 0),
    -- Volume (D-M6-13: MAX allowed, MIN not — MIN creates unfillable states)
    max_volume_kg       int     check (max_volume_kg > 0),          -- optional cap per category
    current_volume_kg   int     not null default 0
                                    check (current_volume_kg >= 0), -- running total matched
    is_active           boolean not null default true,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);

comment on table public.pool_lines is
    'D-M6-13: One row = one category within an MPK Pool container.
     Pool carries total_target_volume_kg (aggregate) + N lines (per-category demand).
     Rule: MAX allowed (caps overfill), MIN not allowed (would create unfillable states).
     mpk_price_per_kg >= minimum_price enforced by rpc_create_pool RPC.
     batch.pool_line_id FK → this table (replaces batch.pool_id concept D-TSP-1/D-TSP-2).
     current_volume_kg updated atomically by matching RPC on each Batch add.';
comment on column public.pool_lines.max_volume_kg is
    'D-M6-13: Optional per-category volume cap (kg). NULL = no upper limit.
     System stops matching new batches to this line when current_volume_kg >= max_volume_kg.';

create index if not exists idx_pool_lines_pool_id    on public.pool_lines (pool_id);
create index if not exists idx_pool_lines_tsp_sku_id on public.pool_lines (tsp_sku_id);

alter table public.pool_lines enable row level security;

-- FK from batches.pool_line_id → pool_lines.id (column added in 7.1.4)
do $$
begin
    alter table public.batches
        add constraint batches_pool_line_id_fk
            foreign key (pool_line_id)
            references public.pool_lines (id)
            on delete set null;
exception when duplicate_object then null;
end $$;

create index if not exists idx_batches_pool_line_id
    on public.batches (pool_line_id)
    where pool_line_id is not null;

-- ------------------------------------------------------------
-- 7.5: NEW TABLE — pool_regions
-- Rayon-level region targeting for Pools (D-M6-4)
-- ------------------------------------------------------------

create table if not exists public.pool_regions (
    id              uuid    primary key default gen_random_uuid(),
    pool_id         uuid    not null references public.pools(id) on delete cascade,
    region_type     text    not null check (region_type in ('oblast', 'rayon')),
    region_id       uuid    not null references public.regions(id),
    created_at      timestamptz not null default now(),
    unique (pool_id, region_id)
);

comment on table public.pool_regions is
    'D-M6-4: Rayon-level region targeting. Pool specifies N region rows.
     region_type=rayon  → specific rayon; batch.region_id must match exactly.
     region_type=oblast → all rayons of that oblast match
                          (join via regions.parent_id in matching RPC).
     "Вся область" UI option = insert one oblast row (not all its rayons individually).
     Additive: add rows to expand, delete to restrict pool coverage.
     Consequence D-M6-4: stricter market → higher frequency of issuance C (published state).';

create index if not exists idx_pool_regions_pool_id   on public.pool_regions (pool_id);
create index if not exists idx_pool_regions_region_id on public.pool_regions (region_id);

alter table public.pool_regions enable row level security;

-- ------------------------------------------------------------
-- 7.6: NEW TABLE — offers
-- Broadcast offer entity; FCFS 24h (M4 §5)
-- ------------------------------------------------------------

create table if not exists public.offers (
    id                      uuid    primary key default gen_random_uuid(),
    batch_id                uuid    not null references public.batches(id),
    mpk_org_id              uuid    not null references public.organizations(id),
    offered_price_per_kg    int     not null check (offered_price_per_kg > 0),
    status                  text    not null default 'pending'
                                        check (status in (
                                            'pending',    -- awaiting MPK response
                                            'accepted',   -- MPK accepted → batch matched
                                            'rejected',   -- MPK explicitly rejected
                                            'expired',    -- offer_window elapsed, no response
                                            'withdrawn'   -- system closed (sibling accepted /
                                                          -- batch cancelled / pool filled)
                                        )),
    expires_at              timestamptz not null,  -- = created_at + offer_window_hours
    responded_at            timestamptz,
    responded_by            uuid    references public.users(id),
    created_at              timestamptz not null default now(),
    unique (batch_id, mpk_org_id)   -- one active Offer per batch per MPK
);

comment on table public.offers is
    'M4 §5: Broadcast offer — created when batch has no auto-match (step 3 of publish_batch).
     System sends one Offer per matching MPK organisation. FCFS: first MPK to accept wins.
     On accept: all other pending Offers for same batch → withdrawn (atomically).
     offer_window_hours from tsp_config (confirmed: 24h, D-M6-1).
     unique(batch_id, mpk_org_id): MPK cannot receive duplicate Offers for same batch.
     After all Offers expire → batch → awaiting_price_decision (M4 §2.6).';

create index if not exists idx_offers_batch_id     on public.offers (batch_id);
create index if not exists idx_offers_mpk_org_id   on public.offers (mpk_org_id);
create index if not exists idx_offers_pending       on public.offers (expires_at)
    where status = 'pending';  -- for scheduled-job sweep

alter table public.offers enable row level security;

-- ------------------------------------------------------------
-- 7.7: NEW TABLE — livestock_categories
-- TSP sales taxonomy — derived by classifier (M4 §1.1)
-- ------------------------------------------------------------

create table if not exists public.livestock_categories (
    id              uuid    primary key default gen_random_uuid(),
    code            text    not null unique,
    name_ru         text    not null,
    description_ru  text,
    is_active       boolean not null default true,
    sort_order      int     not null default 0,
    created_at      timestamptz not null default now()
);

comment on table public.livestock_categories is
    'M4 §1.1: TSP sales taxonomy. Distinct from HerdGroup animal classification (D29).
     Derived automatically via livestock_category_rules — farmer never selects manually.
     Seed data: pending Q-TSP-CATEGORY-CLASSIFIER (finalisation with zoologist, before pilot).
     reference_prices and minimum_prices reference this table.';

-- ------------------------------------------------------------
-- 7.8: NEW TABLE — livestock_category_rules
-- Rules for rpc_derive_category (M4 §1.1)
-- ------------------------------------------------------------

create table if not exists public.livestock_category_rules (
    id              uuid    primary key default gen_random_uuid(),
    category_id     uuid    not null references public.livestock_categories(id),
    version         int     not null default 1,
    -- Matching criteria (NULL = wildcard / any value accepted)
    breed_group     text    check (breed_group in ('elite_meat','local','crossbred')),
    sex             text    check (sex in ('bull','heifer','cow')),
    age_min_months  int,
    age_max_months  int,    -- null = no upper bound
    weight_min_kg   int,
    weight_max_kg   int,    -- null = no upper bound
    bcs_min         numeric(3,1),
    bcs_max         numeric(3,1),
    -- Tiebreak: highest priority wins when multiple rules match
    priority        int     not null default 0,
    is_active       boolean not null default true,
    created_at      timestamptz not null default now()
);

comment on table public.livestock_category_rules is
    'M4 §1.1: Rule set for rpc_derive_category(breed_group, sex, age_months, weight_kg, bcs).
     Versioned: admin prepares new ruleset (version N+1) without breaking active rules.
     Matching: all non-null criteria must match; highest priority rule wins on multi-match.
     P8: standards-as-data — classifier update = INSERT new rules, not code deploy.
     Q-TSP-CATEGORY-CLASSIFIER: pending finalisation with zoologist before pilot.';

create index if not exists idx_category_rules_category on public.livestock_category_rules (category_id);
create index if not exists idx_category_rules_active   on public.livestock_category_rules (is_active, priority desc);

-- ------------------------------------------------------------
-- 7.9: NEW TABLE — reference_prices
-- TURAN recommended prices per livestock category (M4 §1.1)
-- ------------------------------------------------------------

create table if not exists public.reference_prices (
    id                      uuid    primary key default gen_random_uuid(),
    category_id             uuid    not null references public.livestock_categories(id),
    region_id               uuid    references public.regions(id),  -- null = national
    price_per_kg            int     not null check (price_per_kg > 0),
    -- Mandatory antitrust disclaimer (Art. 171 PK RK / §5.9)
    legal_disclaimer_shown  boolean not null default true,
    valid_from              date    not null,
    valid_to                date,
    is_active               boolean not null default false,
    approved_by             uuid    references public.users(id),
    approved_at             timestamptz,
    created_at              timestamptz not null default now(),
    unique (category_id, region_id, valid_from)
);

comment on table public.reference_prices is
    'M4 §1.1: TURAN recommended (indicative) price per LivestockCategory.
     ANTITRUST (Art.171 PK RK, §5.9 Tier 3): indicative only, NOT binding.
     Disclaimer MANDATORY when displayed: «Справочные цены являются индикативными
     рыночными ориентирами. TURAN не устанавливает и не гарантирует цены сделок.»
     AI LAYER RESTRICTION: AI may ONLY reference this table for price hints
     (never aggregated transaction data — Dok5 §6 antitrust constraint).
     region_id=NULL = national fallback.';

-- ------------------------------------------------------------
-- 7.10: NEW TABLE — minimum_prices
-- Protective floor per livestock category (M4 §1.1)
-- ------------------------------------------------------------

create table if not exists public.minimum_prices (
    id              uuid    primary key default gen_random_uuid(),
    category_id     uuid    not null references public.livestock_categories(id),
    region_id       uuid    references public.regions(id),
    price_per_kg    int     not null check (price_per_kg > 0),
    valid_from      date    not null,
    valid_to        date,
    is_active       boolean not null default false,
    approved_by     uuid    references public.users(id),
    approved_at     timestamptz,
    created_at      timestamptz not null default now(),
    unique (category_id, region_id, valid_from)
);

comment on table public.minimum_prices is
    'M4 §1.1: Protective floor price per category.
     rpc_publish_batch: soft-warns farmer if farmer_price_per_kg < floor (not a hard block).
     rpc_create_pool: enforces mpk_price_per_kg >= floor for each pool_line (hard block).
     D-M6-3 stop-rule: rpc_lower_batch_price clamps suggested price to floor; system never
     auto-suggests below. Farmer can still set custom price below with explicit confirmation.
     Art. 171 PK RK: floor = TURAN association standard (farmer protection), not price fixing.';

-- ------------------------------------------------------------
-- 7.11: NEW TABLE — tsp_config
-- TSP operational parameters — standards-as-data (M6 §1)
-- ------------------------------------------------------------

create table if not exists public.tsp_config (
    id                          uuid    primary key default gen_random_uuid(),
    offer_window_hours          int     not null default 24 check (offer_window_hours > 0),
    mpk_decision_window_hours   int     not null default 24 check (mpk_decision_window_hours > 0),
    publish_lead_days           int     not null default 7  check (publish_lead_days >= 0),
    price_step_down_amount      int     not null default 100 check (price_step_down_amount > 0),
    is_active                   boolean not null default false,
    valid_from                  timestamptz not null default now(),
    created_by                  uuid    references public.users(id),
    created_at                  timestamptz not null default now(),
    -- Invariant: at most one active config at a time
    constraint tsp_config_one_active exclude using btree (is_active with =)
        where (is_active = true) deferrable initially deferred
);

comment on table public.tsp_config is
    'M6 §1: Association-level TSP parameters. P8: change = row update, not code deploy.
     offer_window_hours=24:        MPK has 24h to accept/reject a broadcast Offer.     [CEO confirmed D-M6-1]
     mpk_decision_window_hours=24: MPK has 24h to decide on underfilled pool.
                                   Default on silence = return batches (farmer-friendly). [CEO confirmed D-M6-1]
     publish_lead_days=7:          Batch published this many days before ready_from.    [CEO confirmed D-M6-9]
     price_step_down_amount=100:   Fixed ₸/kg step (replaces price_step_down_pct).
                                   Stop-rule: clamp to minimum_price.                   [CEO confirmed D-M6-3]';

-- Seed: active config with CEO-confirmed values
-- NOTE: cannot use ON CONFLICT — only constraint is deferrable EXCLUDE,
-- which PG forbids as ON CONFLICT arbiter. Use WHERE NOT EXISTS for idempotency.
insert into public.tsp_config (
    offer_window_hours, mpk_decision_window_hours,
    publish_lead_days, price_step_down_amount,
    is_active
)
select 24, 24, 7, 100, true
where not exists (select 1 from public.tsp_config where is_active = true);

-- ------------------------------------------------------------
-- 7.12: NEW TABLE — batch_events
-- Append-only FSM event log per Batch (M4 §1.1)
-- ------------------------------------------------------------

create table if not exists public.batch_events (
    id          uuid    primary key default gen_random_uuid(),
    batch_id    uuid    not null references public.batches(id),
    event_type  text    not null,
    -- Canonical event_type values (non-exhaustive):
    --   published, auto_matched, broadcast_sent, offer_accepted, offer_expired,
    --   matched, price_lowered, confirmed, dispatched, delivered,
    --   cancelled_after_match, cancelled_during_execution,
    --   scheduled, auto_published  (D-M6-7, M6 §3.3)
    metadata    jsonb,
    created_by  uuid    references public.users(id),
    created_at  timestamptz not null default now()
);

comment on table public.batch_events is
    'M4 §1.1: Append-only audit log. NEVER updated — INSERT only.
     Drives behavioural reputation scoring (D-TSP-14 preserved alongside D-M6-11 reviews).
     Key event: cancelled_after_match (BT-15) flagged for future rating penalty.
     M6 §3.3 adds: scheduled, auto_published.';

create index if not exists idx_batch_events_batch_id on public.batch_events (batch_id);
create index if not exists idx_batch_events_type     on public.batch_events (event_type);
create index if not exists idx_batch_events_created  on public.batch_events (created_at desc);

alter table public.batch_events enable row level security;

drop policy if exists batch_events_farmer_read on public.batch_events;
create policy batch_events_farmer_read
    on public.batch_events for select
    using (
        batch_id in (
            select id from public.batches
             where organization_id = any(fn_my_org_ids())
        )
    );

-- ------------------------------------------------------------
-- 7.13: NEW TABLE — review_dimensions
-- Lookup for review quality dimensions (D-M6-11)
-- ------------------------------------------------------------

create table if not exists public.review_dimensions (
    id              uuid    primary key default gen_random_uuid(),
    code            text    not null unique,
    name_ru         text    not null,
    applicable_role text    not null check (applicable_role in ('farmer', 'mpk', 'both')),
    is_pilot_primary boolean not null default false,
    description_ru  text,
    sort_order      int     not null default 0,
    is_active       boolean not null default true,
    created_at      timestamptz not null default now()
);

comment on table public.review_dimensions is
    'D-M6-11: Quality dimensions for mutual deal reviews. P8: admin-managed.
     Pilot flow: overall (1-5) + 1 role-specific dimension (is_pilot_primary=true).
     Farmer→MPK pilot dimension: weight_accuracy.
     MPK→Farmer pilot dimension: livestock_condition.
     Schema holds N dimensions — additive expansion post-pilot.
     Q-TSP-REVIEW-DIMENSIONS: full list to be finalised post-pilot.';

-- Seed pilot dimensions
insert into public.review_dimensions
    (code, name_ru, applicable_role, is_pilot_primary, description_ru, sort_order)
values
    ('weight_accuracy',
     'Соответствие заявленному весу',
     'farmer', true,
     'Насколько фактический вес партии совпал с заявленным фермером', 1),
    ('livestock_condition',
     'Соответствие кондиции описанию',
     'mpk', true,
     'Насколько состояние скота соответствовало описанию в карточке партии', 2),
    ('communication',
     'Коммуникация и оперативность',
     'both', false,
     'Качество общения, скорость ответа на вопросы и запросы', 3),
    ('delivery_punctuality',
     'Пунктуальность поставки',
     'both', false,
     'Соблюдение согласованного окна поставки', 4)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- 7.14: NEW TABLE — deal_reviews
-- Mutual batch reviews, double-blind reveal (D-M6-11, D-M6-12)
-- ------------------------------------------------------------

create table if not exists public.deal_reviews (
    id              uuid    primary key default gen_random_uuid(),
    batch_id        uuid    not null references public.batches(id),
    reviewer_org_id uuid    not null references public.organizations(id),
    reviewer_role   text    not null check (reviewer_role in ('farmer', 'mpk')),
    overall_score   int     not null check (overall_score between 1 and 5),
    comment         text,
    submitted_at    timestamptz not null default now(),
    -- Double-blind (D-M6-12): null until both sides submit, or window expires
    visible_at      timestamptz,
    created_at      timestamptz not null default now(),
    unique (batch_id, reviewer_org_id)
);

comment on table public.deal_reviews is
    'D-M6-11: Mutual review. One record per reviewer per batch (after delivered state).
     Double-blind (D-M6-12): visible_at set by system when BOTH parties submit,
     or when review_window expires (7-day default — pending UX validation).
     Before visible_at: reviewer sees own review only; other side sees nothing.
     After visible_at: both reviews become mutually visible.
     Pre-deal: org reputation (★ aggregate) shown anonymously — D-M6-12 anti-discrimination.
     Org reputation = derived view (P4), never stored as a field.';

create index if not exists idx_deal_reviews_batch_id     on public.deal_reviews (batch_id);
create index if not exists idx_deal_reviews_reviewer_org on public.deal_reviews (reviewer_org_id);
create index if not exists idx_deal_reviews_visible      on public.deal_reviews (visible_at)
    where visible_at is not null;

alter table public.deal_reviews enable row level security;

drop policy if exists deal_reviews_read on public.deal_reviews;
create policy deal_reviews_read
    on public.deal_reviews for select
    using (
        -- reviewer sees own review always
        reviewer_org_id = any(fn_my_org_ids())
        -- all see after double-blind reveal
        or (visible_at is not null and visible_at <= now())
    );

-- ------------------------------------------------------------
-- 7.15: NEW TABLE — deal_review_dimension_scores
-- Per-dimension scores within a deal_review (D-M6-11)
-- ------------------------------------------------------------

create table if not exists public.deal_review_dimension_scores (
    id              uuid    primary key default gen_random_uuid(),
    deal_review_id  uuid    not null references public.deal_reviews(id) on delete cascade,
    dimension_id    uuid    not null references public.review_dimensions(id),
    score           int     not null check (score between 1 and 5),
    created_at      timestamptz not null default now(),
    unique (deal_review_id, dimension_id)
);

comment on table public.deal_review_dimension_scores is
    'D-M6-11: One row per dimension score within a deal_review.
     Pilot: 1 row per review (is_pilot_primary dimension for the reviewer role).
     N rows per review post-pilot — additive expansion.
     Inherits visibility rules from parent deal_reviews via deal_review_id.
     Cascade delete: removing a review removes its dimension scores.';

create index if not exists idx_review_dim_scores_review    on public.deal_review_dimension_scores (deal_review_id);
create index if not exists idx_review_dim_scores_dimension on public.deal_review_dimension_scores (dimension_id);

-- ------------------------------------------------------------
-- 7.16: NEW TABLE — tsp_sku_category_map
-- Bridge: tsp_skus → livestock_categories  (D-TSP-CATEGORY-BRIDGE, 2026-06-15)
-- Architecture: Docs/AGOS-Dok6-A-CAT-AdminScreens-v1_0.md §2.1
-- ------------------------------------------------------------
-- Closes Q-TSP-CATEGORY-CLASSIFIER via admin self-service (no seed, no brief).
-- Many SKU → one Category. Versioned: admin can stage version=N+1 with
-- is_active=false, then atomically flip via rpc_admin_map_sku_to_category.
-- Floor-clamp lookups read ONLY is_active=true rows → empty map degrades
-- gracefully (v_floor=NULL, clamp is no-op). Schema can ship before zoologist
-- fills data; pilot unblocks the moment 30/30 SKU are mapped.

create table if not exists public.tsp_sku_category_map (
    id              uuid    primary key default gen_random_uuid(),
    tsp_sku_id      uuid    not null references public.tsp_skus(id),
    category_id     uuid    not null references public.livestock_categories(id),
    version         int     not null default 1,
    is_active       boolean not null default true,
    created_by      uuid    references public.users(id),
    created_at      timestamptz not null default now()
);

comment on table public.tsp_sku_category_map is
    'D-TSP-CATEGORY-BRIDGE (A2, 2026-06-15): bridge tsp_skus → livestock_categories
     (many SKU → one Category). Versioned: admin can stage version=N+1 with
     is_active=false, then atomically flip via rpc_admin_map_sku_to_category.
     Floor-check reads only is_active=true rows → empty map → no clamp
     (graceful degradation in rpc_lower_batch_price and rpc_create_pool).';

-- Enforce "one active mapping per SKU" via partial unique index (a UNIQUE
-- constraint cannot carry a WHERE clause; an index can).
create unique index if not exists ux_skumap_active_sku
    on public.tsp_sku_category_map (tsp_sku_id)
    where is_active = true;

create index if not exists idx_skumap_sku on public.tsp_sku_category_map (tsp_sku_id) where is_active = true;
create index if not exists idx_skumap_cat on public.tsp_sku_category_map (category_id) where is_active = true;

alter table public.tsp_sku_category_map enable row level security;

drop policy if exists skumap_read_auth on public.tsp_sku_category_map;
create policy skumap_read_auth
    on public.tsp_sku_category_map for select
    using (auth.uid() is not null);

drop policy if exists skumap_admin_write on public.tsp_sku_category_map;
create policy skumap_admin_write
    on public.tsp_sku_category_map for all
    using (public.fn_is_admin())
    with check (public.fn_is_admin());

-- ============================================================
-- SECTION 7 SUMMARY (M4 + M6 EXTENSION)
-- ============================================================
-- Tables altered (additive):
--   batches    +8 columns, status CHECK expanded (12 states + 1 legacy)
--   pools      +5 columns, status CHECK expanded (10 states + 5 legacy),
--              pool_request_id NOT NULL → nullable
--   pool_requests  deprecated (comment only, rows preserved)
--
-- Tables created (13):
--   pool_lines, pool_regions, offers,
--   livestock_categories, livestock_category_rules,
--   reference_prices, minimum_prices, tsp_config,
--   batch_events, review_dimensions, deal_reviews, deal_review_dimension_scores,
--   tsp_sku_category_map (D-TSP-CATEGORY-BRIDGE, 2026-06-15)
--
-- FK added: batches.pool_line_id → pool_lines.id
-- Indexes: 17 | RLS enabled: 6 tables | Policies: 4 | Seeds: 1+4 rows
--
-- Pending (implementation sprint):
--   □ RLS policies for pool_lines, pool_regions (MPK org ownership model)
--   □ updated_at triggers on pool_lines, deal_reviews
--   □ rpc_derive_category() — defer until AI Gateway needs photo/text classification
--   ✅ rpc_create_pool(pool_lines[], pool_regions[]) — replaces rpc_create_pool_request
--   ✅ D-TSP-CATEGORY-BRIDGE: admin self-service via A-CAT-01..04 screens
--      (closes Q-TSP-CATEGORY-CLASSIFIER; CEO+zoologist fill data in admin UI)
-- ============================================================

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Summary:
--   Reference tables:    5 (grade_standards, tsp_skus, valid_sku_combinations,
--                           weight_classes, price_index_methodologies)
--   Operational tables:  8 (batches, pool_requests, pools, pool_matches,
--                           delivery_records, pool_manifests,
--                           price_grids, price_indices)
--   Log/Append tables:   2 (price_grid_log, price_index_values)
--   Total:              15 tables
--
--   Indexes:            24
--   RLS policies:       28
--   Triggers:            8 (7 updated_at + 1 price_grid_log)
--   Seed data:          30 SKUs + 3 grades + 9 valid combos + 3 weight classes + 1 methodology
--
-- Verified decisions:
--   D28 D29 D30 D31 D32 D33 D34 D35 D36 D37 D38 D39 D40 D41 D84 D90
--
-- Open questions resolved:
--   Q17 ✅ TspCategory: breed_group (3) × sex (3) × age (4) × weight (3) = 30 SKU cells
--   Q18 ✅ WeightClass: light/standard/heavy with exact kg ranges per animal type in tsp_skus
--
-- Cross-module FK pending:
--   None — TSP module is self-contained. HerdGroup link is soft (nullable FK, D32).
--
-- Antitrust compliance points:
--   1. price_grids.legal_disclaimer_shown = MANDATORY field
--   2. valid_sku_combinations blocks crossbred from S/VS grades
--   3. D40: farmer/MPK contacts isolated until Pool.status = executing
--   4. Aggregated supply/demand = computed RPC (get_aggregated_supply/demand) — no raw data
--
-- Next migration: 003_feed.sql
--   Entities: FeedCategory*, FeedItem*, FeedPrice, NutrientRequirement*,
--             PeriodType*, FarmFeedInventory, Ration, RationVersion,
--             FeedingPlan, FeedingPeriod (10 entities)
-- ============================================================


-- ============================================================
-- SLICE 5a: Market Farmer RPCs
-- D-LEGAL-1: Build without legal gate (CEO decision 2026-04-01)
-- RPC-11: rpc_cancel_batch
-- RPC-17: rpc_get_price_for_sku
-- RPC-18: rpc_get_market_summary
-- ============================================================

-- ============================================================
-- RPC-11: rpc_cancel_batch
-- Dok 3 §4 | Callers: [WEB] [AI] [ADMIN]
-- FSM: draft|published → cancelled. Matched requires rollback first.
-- Events: market.batch.cancelled
-- ============================================================
create or replace function public.rpc_cancel_batch(
    p_organization_id   uuid,
    p_batch_id          uuid,
    p_reason            text        default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch record;
begin
    select * into v_batch
    from public.batches
    where id = p_batch_id and organization_id = p_organization_id;

    if v_batch is null then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_batch.status = 'cancelled' then
        return true;  -- idempotent
    end if;

    if v_batch.status not in ('draft', 'published') then
        raise exception 'INVALID_STATUS: cannot cancel batch in status %', v_batch.status
            using errcode = 'P0001';
    end if;

    -- If published, check no matches exist
    if v_batch.status = 'published' then
        if exists (select 1 from public.pool_matches where batch_id = p_batch_id) then
            raise exception 'HAS_MATCHES: batch has pool matches, rollback first'
                using errcode = 'P0001';
        end if;
    end if;

    update public.batches
    set status = 'cancelled',
        cancelled_at = now(),
        rollback_reason = p_reason,
        updated_at = now()
    where id = p_batch_id;

    -- Emit event
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.batch.cancelled', 'batches', p_batch_id, p_organization_id,
        'farmer', public.fn_current_user_id(),
        jsonb_build_object('batch_id', p_batch_id, 'reason', p_reason,
            'previous_status', v_batch.status),
        true
    );

    return true;
end;
$$;

comment on function public.rpc_cancel_batch(uuid, uuid, text) is
    'RPC-11 | Dok 3 §4 | Slice 5a
     FSM: draft|published → cancelled. Published requires no matches.
     Idempotent (already cancelled = true).
     Events: market.batch.cancelled (is_audit=true).';


-- ============================================================
-- RPC-17: rpc_get_price_for_sku
-- Dok 3 §4 | Callers: [WEB] [AI]
-- Returns price + MANDATORY disclaimer_text (Article 171)
-- ============================================================
create or replace function public.rpc_get_price_for_sku(
    p_organization_id   uuid,
    p_sku_id            uuid,
    p_region_id         uuid        default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_result jsonb;
begin
    select jsonb_build_object(
        'sku_id', pg.tsp_sku_id,
        'sku_name', s.name_ru,
        'region_id', pg.region_id,
        'base_price_per_kg', pg.base_price_per_kg,
        'premium_per_kg', pg.premium_per_kg,
        'total_price_per_kg', pg.base_price_per_kg + pg.premium_per_kg,
        'valid_from', pg.valid_from,
        'disclaimer_text', 'Справочные цены являются индикативными рыночными ориентирами и не являются обязательными для применения. Участие добровольное.'
    ) into v_result
    from public.price_grids pg
    join public.tsp_skus s on s.id = pg.tsp_sku_id
    where pg.tsp_sku_id = p_sku_id
      and pg.is_active = true
      and (p_region_id is null or pg.region_id = p_region_id or pg.region_id is null)
    order by
        case when pg.region_id = p_region_id then 0 else 1 end,  -- region match first
        pg.valid_from desc
    limit 1;

    -- If no price found, return null with disclaimer
    if v_result is null then
        v_result := jsonb_build_object(
            'sku_id', p_sku_id,
            'base_price_per_kg', null,
            'disclaimer_text', 'Справочные цены являются индикативными рыночными ориентирами и не являются обязательными для применения. Участие добровольное.'
        );
    end if;

    return v_result;
end;
$$;

comment on function public.rpc_get_price_for_sku(uuid, uuid, uuid) is
    'RPC-17 | Dok 3 §4 | Slice 5a
     Returns price for SKU + region with MANDATORY disclaimer_text (Article 171).
     Region matching: exact match first, then national (null region).
     STABLE read — no side effects.';


-- ============================================================
-- RPC-18: rpc_get_market_summary
-- Dok 3 §4 | Callers: [WEB] [AI]
-- Anonymous aggregates: supply by SKU, demand by category.
-- MANDATORY disclaimer_text.
-- ============================================================
create or replace function public.rpc_get_market_summary(
    p_organization_id   uuid,
    p_region_id         uuid        default null,
    p_month             date        default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_month         date;
    v_supply        jsonb;
    v_demand        jsonb;
begin
    v_month := coalesce(p_month, date_trunc('month', current_date)::date);

    -- Supply: aggregate published + matched batches by SKU (anonymous)
    select coalesce(jsonb_agg(jsonb_build_object(
        'sku_id', b.tsp_sku_id,
        'sku_name', s.name_ru,
        'total_heads', sum(b.heads),
        'batch_count', count(*),
        'avg_weight_kg', round(avg(b.avg_weight_kg), 1)
    )), '[]'::jsonb) into v_supply
    from public.batches b
    join public.tsp_skus s on s.id = b.tsp_sku_id
    where b.status in ('published', 'matched')
      and b.target_month = v_month
      and (p_region_id is null or b.region_id = p_region_id)
    group by b.tsp_sku_id, s.name_ru;

    -- Demand: aggregate active pool requests (anonymous)
    select coalesce(jsonb_agg(jsonb_build_object(
        'total_heads', pr.total_heads,
        'target_month', pr.target_month,
        'status', pr.status
    )), '[]'::jsonb) into v_demand
    from public.pool_requests pr
    where pr.status = 'active'
      and pr.target_month = v_month
      and (p_region_id is null or pr.region_id = p_region_id);

    return jsonb_build_object(
        'month', v_month,
        'region_id', p_region_id,
        'supply', v_supply,
        'demand', v_demand,
        'disclaimer_text', 'Справочные цены являются индикативными рыночными ориентирами и не являются обязательными для применения. Участие добровольное.'
    );
end;
$$;

comment on function public.rpc_get_market_summary(uuid, uuid, date) is
    'RPC-18 | Dok 3 §4 | Slice 5a
     Anonymous market aggregates: supply by SKU + demand by MPK category.
     All farmer identities anonymized. MANDATORY disclaimer_text.
     STABLE read — no side effects.';


-- ============================================================
-- SLICE 5a: rpc_name_registry
-- ============================================================
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_cancel_batch',        'rpc_cancel_batch',        null, 'd02_tsp.sql (Slice 5a)', 'RPC-11: Cancel batch (draft|published → cancelled)'),
    ('rpc_get_price_for_sku',   'rpc_get_price_for_sku',   null, 'd02_tsp.sql (Slice 5a)', 'RPC-17: Price + disclaimer (Article 171)'),
    ('rpc_get_market_summary',  'rpc_get_market_summary',  null, 'd02_tsp.sql (Slice 5a)', 'RPC-18: Anonymous market aggregates + disclaimer')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;

-- ============================================================
-- END Slice 5a d02_tsp.sql RPCs
-- ============================================================



-- ============================================================
-- SLICE 5b: Market Admin RPCs (7 functions)
-- ============================================================

-- RPC-12: rpc_create_pool_request
create or replace function public.rpc_create_pool_request(
    p_organization_id uuid, p_total_heads int, p_target_month date,
    p_region_id uuid default null, p_accepted_categories jsonb default '[]'
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
    insert into public.pool_requests (organization_id, total_heads, target_month, region_id, accepted_categories, status)
    values (p_organization_id, p_total_heads, p_target_month, p_region_id, p_accepted_categories, 'draft')
    returning id into v_id;
    insert into public.platform_events (event_type,entity_type,entity_id,organization_id,actor_type,actor_id,payload,is_audit)
    values ('market.pool_request.created','pool_requests',v_id,p_organization_id,'admin',public.fn_current_user_id(),
        jsonb_build_object('request_id',v_id,'total_heads',p_total_heads,'target_month',p_target_month),false);
    return v_id;
end; $$;

-- RPC-13: rpc_activate_pool_request
create or replace function public.rpc_activate_pool_request(
    p_organization_id uuid, p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_req record; v_pool_id uuid;
begin
    select * into v_req from public.pool_requests where id = p_request_id and organization_id = p_organization_id;
    if v_req is null then raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0001'; end if;
    if v_req.status != 'draft' then raise exception 'INVALID_STATUS: must be draft' using errcode = 'P0001'; end if;

    update public.pool_requests set status = 'active', updated_at = now() where id = p_request_id;

    insert into public.pools (pool_request_id, target_heads, matched_heads, status)
    values (p_request_id, v_req.total_heads, 0, 'filling')
    returning id into v_pool_id;

    insert into public.platform_events (event_type,entity_type,entity_id,organization_id,actor_type,actor_id,payload,is_audit)
    values ('market.pool.created','pools',v_pool_id,p_organization_id,'admin',public.fn_current_user_id(),
        jsonb_build_object('pool_id',v_pool_id,'request_id',p_request_id,'target_heads',v_req.total_heads),true);

    return jsonb_build_object('request_id', p_request_id, 'pool_id', v_pool_id);
end; $$;

-- RPC-14: rpc_match_batch_to_pool
create or replace function public.rpc_match_batch_to_pool(
    p_organization_id uuid, p_pool_id uuid, p_batch_id uuid,
    p_matched_heads int, p_price_per_kg int default null
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_match_id uuid; v_pool record;
begin
    select * into v_pool from public.pools where id = p_pool_id and status = 'filling';
    if v_pool is null then raise exception 'POOL_NOT_FILLING' using errcode = 'P0001'; end if;

    if not exists (select 1 from public.batches where id = p_batch_id and status = 'published') then
        raise exception 'BATCH_NOT_PUBLISHED' using errcode = 'P0001'; end if;

    insert into public.pool_matches (pool_id, batch_id, matched_heads, reference_price_at_match)
    values (p_pool_id, p_batch_id, p_matched_heads, p_price_per_kg)
    returning id into v_match_id;

    -- Update batch status
    update public.batches set status = 'matched', matched_at = now(), updated_at = now() where id = p_batch_id;

    -- Update pool counter
    update public.pools set matched_heads = matched_heads + p_matched_heads, updated_at = now() where id = p_pool_id;

    -- Auto-fill if target reached
    if (v_pool.matched_heads + p_matched_heads) >= v_pool.target_heads then
        update public.pools set status = 'filled', filled_at = now(), updated_at = now() where id = p_pool_id;
    end if;

    insert into public.platform_events (event_type,entity_type,entity_id,organization_id,actor_type,actor_id,payload,is_audit)
    values ('market.batch.matched','pool_matches',v_match_id,p_organization_id,'admin',public.fn_current_user_id(),
        jsonb_build_object('match_id',v_match_id,'pool_id',p_pool_id,'batch_id',p_batch_id,'heads',p_matched_heads),true);

    return v_match_id;
end; $$;

-- RPC-15: rpc_advance_pool_status
create or replace function public.rpc_advance_pool_status(
    p_organization_id uuid, p_pool_id uuid, p_new_status text
)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pool record; v_valid_transitions jsonb;
begin
    select * into v_pool from public.pools where id = p_pool_id;
    if v_pool is null then raise exception 'POOL_NOT_FOUND' using errcode = 'P0001'; end if;

    -- FSM validation
    v_valid_transitions := jsonb_build_object(
        'filling', '["filled","closed"]'::jsonb,
        'filled', '["executing","closed"]'::jsonb,
        'executing', '["dispatched","executed","closed"]'::jsonb,
        'dispatched', '["delivered","closed"]'::jsonb,
        'delivered', '["executed","closed"]'::jsonb
    );

    if not (v_valid_transitions->v_pool.status) @> to_jsonb(p_new_status) then
        raise exception 'INVALID_TRANSITION: % → % not allowed', v_pool.status, p_new_status
            using errcode = 'P0001';
    end if;

    update public.pools set status = p_new_status, updated_at = now() where id = p_pool_id;

    -- D40: reveal contacts at executing transition
    if p_new_status = 'executing' then
        update public.pools set mpk_contact_revealed_at = now(), executing_at = now() where id = p_pool_id;
    end if;
    if p_new_status = 'filled' then update public.pools set filled_at = now() where id = p_pool_id; end if;
    if p_new_status = 'executed' then update public.pools set executed_at = now() where id = p_pool_id; end if;
    if p_new_status = 'closed' then update public.pools set closed_at = now(), closed_by = public.fn_current_user_id() where id = p_pool_id; end if;

    insert into public.platform_events (event_type,entity_type,entity_id,organization_id,actor_type,actor_id,payload,is_audit)
    values ('market.pool.status_changed','pools',p_pool_id,p_organization_id,'admin',public.fn_current_user_id(),
        jsonb_build_object('pool_id',p_pool_id,'from',v_pool.status,'to',p_new_status),true);

    return true;
end; $$;

-- RPC-16: rpc_rollback_batch_match
create or replace function public.rpc_rollback_batch_match(
    p_organization_id uuid, p_pool_id uuid, p_batch_id uuid, p_reason text default null
)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare v_match record;
begin
    select * into v_match from public.pool_matches where pool_id = p_pool_id and batch_id = p_batch_id;
    if v_match is null then raise exception 'MATCH_NOT_FOUND' using errcode = 'P0001'; end if;

    delete from public.pool_matches where id = v_match.id;

    update public.pools set matched_heads = matched_heads - v_match.matched_heads, updated_at = now() where id = p_pool_id;
    -- If was filled, revert to filling
    update public.pools set status = 'filling' where id = p_pool_id and status = 'filled';

    update public.batches set status = 'published', rollback_reason = p_reason, rollback_at = now(), updated_at = now() where id = p_batch_id;

    insert into public.platform_events (event_type,entity_type,entity_id,organization_id,actor_type,actor_id,payload,is_audit)
    values ('market.match.rolled_back','pool_matches',v_match.id,p_organization_id,'admin',public.fn_current_user_id(),
        jsonb_build_object('pool_id',p_pool_id,'batch_id',p_batch_id,'reason',p_reason),true);

    return true;
end; $$;

-- RPC-19: rpc_set_price_grid
create or replace function public.rpc_set_price_grid(
    p_organization_id uuid, p_sku_id uuid, p_base_price_per_kg int,
    p_premium_per_kg int default 0, p_region_id uuid default null
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
    if not public.fn_is_admin() then raise exception 'FORBIDDEN' using errcode = 'P0001'; end if;

    insert into public.price_grids (tsp_sku_id, region_id, base_price_per_kg, premium_per_kg, valid_from, is_active)
    values (p_sku_id, p_region_id, p_base_price_per_kg, p_premium_per_kg, current_date, true)
    on conflict (tsp_sku_id, region_id, valid_from) do update
        set base_price_per_kg = excluded.base_price_per_kg,
            premium_per_kg = excluded.premium_per_kg,
            is_active = true,
            updated_at = now()
    returning id into v_id;

    -- fn_log_price_grid_change trigger fires automatically

    insert into public.platform_events (event_type,entity_type,entity_id,organization_id,actor_type,actor_id,payload,is_audit)
    values ('market.price.updated','price_grids',v_id,p_organization_id,'admin',public.fn_current_user_id(),
        jsonb_build_object('sku_id',p_sku_id,'base_price',p_base_price_per_kg,'premium',p_premium_per_kg),true);

    return v_id;
end; $$;

-- RPC-20: rpc_publish_price_index_value
create or replace function public.rpc_publish_price_index_value(
    p_organization_id uuid, p_index_id uuid, p_period_date date, p_value numeric
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
    if not public.fn_is_admin() then raise exception 'FORBIDDEN' using errcode = 'P0001'; end if;

    insert into public.price_index_values (index_id, period_date, value_per_kg, data_source, published, published_by, published_at)
    values (p_index_id, p_period_date, p_value, 'expert_assessment', true, public.fn_current_user_id(), now())
    returning id into v_id;

    return v_id;
end; $$;

-- Registry
insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
    ('rpc_create_pool_request','rpc_create_pool_request','d02_tsp.sql (Slice 5b)','RPC-12'),
    ('rpc_activate_pool_request','rpc_activate_pool_request','d02_tsp.sql (Slice 5b)','RPC-13'),
    ('rpc_match_batch_to_pool','rpc_match_batch_to_pool','d02_tsp.sql (Slice 5b)','RPC-14'),
    ('rpc_advance_pool_status','rpc_advance_pool_status','d02_tsp.sql (Slice 5b)','RPC-15'),
    ('rpc_rollback_batch_match','rpc_rollback_batch_match','d02_tsp.sql (Slice 5b)','RPC-16'),
    ('rpc_set_price_grid','rpc_set_price_grid','d02_tsp.sql (Slice 5b)','RPC-19'),
    ('rpc_publish_price_index_value','rpc_publish_price_index_value','d02_tsp.sql (Slice 5b)','RPC-20')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;


-- ============================================================
-- SECTION 8: M4 + M6 RPC IMPLEMENTATIONS (2026-06-15)
-- ============================================================
-- Sources: Docs/AGOS-TSP-Flow-Microsteps/AGOS-Microstep4-BatchPoolOffer-v1_0.md
--          Docs/AGOS-TSP-Flow-Microsteps/AGOS-Microstep6-TSPFlow-v1_0.md
-- Decisions implemented: D-M6-1..14, D-TSP-1..16
--
-- Known compromise (DEF-TSP-M4-OWNERSHIP):
--   pools table has no organization_id column; MPK identity is traced via
--   pool_request_id -> pool_requests.organization_id. rpc_create_pool creates
--   a vestigial pool_request stub to preserve this ownership chain until a
--   future schema migration adds pools.organization_id directly.
--
-- Closed (Q-TSP-CATEGORY-CLASSIFIER, 2026-06-15) — D-TSP-CATEGORY-BRIDGE (A2):
--   New table tsp_sku_category_map bridges tsp_skus → livestock_categories
--   (many SKU → one Category). rpc_lower_batch_price and rpc_create_pool now
--   resolve category via the bridge transparently. Empty bridge ⇒ floor check
--   is a no-op (graceful), so schema ships safely before the admin fills data.
--   A-CAT-01..04 admin screens (AC-1..7 write + AR-1..4 read RPCs in §8 below)
--   let TURAN admin own this dataset via self-service. P8: standards-as-data.
--
-- Closed (Q-TSP-RETRY-MATCH, 2026-06-15):
--   rpc_publish_pool calls rpc_retry_match_pool inline (same transaction).
--   Eligible batches in published state receive Offers immediately; FCFS
--   semantics preserved via rpc_accept_offer. Re-broadcast on price lowering
--   remains inline in rpc_lower_batch_price. rpc_retry_match_pool is
--   idempotent and safe to invoke from a periodic sweep job if added later.
-- ============================================================


-- ------------------------------------------------------------
-- RPC-M6-01: rpc_create_pool (M4 §2.4 + D-M6-13)
-- Caller: MPK organization member.
-- Replaces legacy rpc_create_pool_request + rpc_activate_pool_request.
-- Inputs:
--   p_pool_lines   jsonb array of:
--                  { tsp_sku_id?: uuid,
--                    category_label?: text,
--                    mpk_price_per_kg: int (required, > 0),
--                    max_volume_kg?: int,
--                    livestock_category_id?: uuid  -- triggers floor check }
--   p_pool_regions jsonb array of:
--                  { region_type: 'rayon'|'oblast', region_id: uuid }
-- Hard-block: line's mpk_price_per_kg >= minimum_price(livestock_category_id)
--             when livestock_category_id provided.
-- Atomic: all-or-nothing (single transaction).
-- ------------------------------------------------------------
create or replace function public.rpc_create_pool(
    p_organization_id           uuid,
    p_pool_lines                jsonb,
    p_pool_regions              jsonb,
    p_delivery_from             date,
    p_delivery_to               date,
    p_total_target_volume_kg    int
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_line              jsonb;
    v_region            jsonb;
    v_floor             int;
    v_category_id       uuid;
    v_pool_request_id   uuid;
    v_pool_id           uuid;
    v_target_heads      int;
    v_pool_line_id      uuid;
    v_pool_line_ids     uuid[] := array[]::uuid[];
begin
    -- Input validation
    if p_pool_lines is null
       or jsonb_typeof(p_pool_lines) != 'array'
       or jsonb_array_length(p_pool_lines) = 0 then
        raise exception 'INVALID_INPUT: p_pool_lines must be a non-empty jsonb array'
            using errcode = 'P0001';
    end if;
    if p_pool_regions is null
       or jsonb_typeof(p_pool_regions) != 'array'
       or jsonb_array_length(p_pool_regions) = 0 then
        raise exception 'INVALID_INPUT: p_pool_regions must be a non-empty jsonb array'
            using errcode = 'P0001';
    end if;
    if p_delivery_from is null or p_delivery_to is null then
        raise exception 'INVALID_INPUT: delivery_from and delivery_to required'
            using errcode = 'P0001';
    end if;
    if p_delivery_to < p_delivery_from then
        raise exception 'INVALID_INPUT: delivery_to < delivery_from'
            using errcode = 'P0001';
    end if;
    if p_total_target_volume_kg is null or p_total_target_volume_kg <= 0 then
        raise exception 'INVALID_INPUT: total_target_volume_kg must be > 0'
            using errcode = 'P0001';
    end if;

    -- Ownership: caller must belong to p_organization_id
    if not (p_organization_id = any(public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: caller is not a member of organization %', p_organization_id
            using errcode = 'P0001';
    end if;

    -- Per-line validation + floor enforcement (D-M6-13)
    for v_line in select jsonb_array_elements(p_pool_lines) loop
        if (v_line->>'mpk_price_per_kg') is null
           or (v_line->>'mpk_price_per_kg')::int <= 0 then
            raise exception 'INVALID_INPUT: each pool_line requires mpk_price_per_kg > 0'
                using errcode = 'P0001';
        end if;

        -- D-TSP-CATEGORY-BRIDGE (A2, 2026-06-15): explicit livestock_category_id
        -- still wins (back-compat); when caller omits it, resolve via bridge
        -- (tsp_sku_id → tsp_sku_category_map → category_id). Empty bridge →
        -- v_category_id stays NULL → floor check is skipped (graceful).
        v_category_id := coalesce(
            nullif(v_line->>'livestock_category_id', '')::uuid,
            (select m.category_id
               from public.tsp_sku_category_map m
              where m.tsp_sku_id = nullif(v_line->>'tsp_sku_id', '')::uuid
                and m.is_active  = true
              limit 1)
        );
        if v_category_id is not null then
            -- Strictest floor across all covered regions (D-M6-13: hard floor must
            -- be satisfied for EVERY region in pool_regions). MAX wins, with national
            -- floor (region_id IS NULL) eligible as a fallback for any covered region.
            select max(mp.price_per_kg) into v_floor
            from public.minimum_prices mp
            where mp.category_id = v_category_id
              and mp.is_active = true
              and (
                  mp.region_id is null
                  or mp.region_id::text in (
                      select x->>'region_id'
                      from jsonb_array_elements(p_pool_regions) x
                  )
              );

            if v_floor is not null
               and (v_line->>'mpk_price_per_kg')::int < v_floor then
                raise exception
                    'PRICE_BELOW_FLOOR: line mpk_price % below strictest floor % for category %',
                    (v_line->>'mpk_price_per_kg')::int, v_floor, v_category_id
                    using errcode = 'P0001';
            end if;
        end if;
    end loop;

    -- Per-region validation
    for v_region in select jsonb_array_elements(p_pool_regions) loop
        if (v_region->>'region_type') not in ('rayon', 'oblast') then
            raise exception 'INVALID_INPUT: region_type must be rayon or oblast'
                using errcode = 'P0001';
        end if;
        if not exists (
            select 1 from public.regions r
            where r.id = (v_region->>'region_id')::uuid
        ) then
            raise exception 'INVALID_INPUT: unknown region_id %', v_region->>'region_id'
                using errcode = 'P0001';
        end if;
    end loop;

    -- Legacy column placeholder (pools.target_heads is NOT NULL > 0; 400kg assumed)
    v_target_heads := greatest(1, ceil(p_total_target_volume_kg::numeric / 400)::int);

    -- DEF-TSP-M4-OWNERSHIP (resolved): pools.organization_id is the source of truth
    -- for MPK ownership. No more pool_request stub.
    -- pool_request_id stays NULL on M4-native pools.
    -- filling_deadline = p_delivery_to: pool stops accepting new matches when
    -- the delivery window closes. Backend offer-expiry job reads filling_deadline
    -- and triggers awaiting_mpk_decision when reached without total reached.
    v_pool_request_id := null;
    insert into public.pools (
        organization_id, pool_request_id,
        target_heads, matched_heads, status,
        total_target_volume_kg, delivery_from, delivery_to,
        filling_deadline
    ) values (
        p_organization_id, null,
        v_target_heads, 0, 'draft',
        p_total_target_volume_kg, p_delivery_from, p_delivery_to,
        p_delivery_to
    )
    returning id into v_pool_id;

    -- pool_lines
    for v_line in select jsonb_array_elements(p_pool_lines) loop
        insert into public.pool_lines (
            pool_id, tsp_sku_id, category_label,
            mpk_price_per_kg, max_volume_kg
        ) values (
            v_pool_id,
            nullif(v_line->>'tsp_sku_id', '')::uuid,
            v_line->>'category_label',
            (v_line->>'mpk_price_per_kg')::int,
            nullif(v_line->>'max_volume_kg', '')::int
        )
        returning id into v_pool_line_id;
        v_pool_line_ids := v_pool_line_ids || v_pool_line_id;
    end loop;

    -- pool_regions
    for v_region in select jsonb_array_elements(p_pool_regions) loop
        insert into public.pool_regions (pool_id, region_type, region_id)
        values (
            v_pool_id,
            v_region->>'region_type',
            (v_region->>'region_id')::uuid
        )
        on conflict (pool_id, region_id) do nothing;
    end loop;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.created', 'pools', v_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object(
            'pool_id', v_pool_id,
            'pool_request_id', v_pool_request_id,
            'total_target_volume_kg', p_total_target_volume_kg,
            'delivery_from', p_delivery_from,
            'delivery_to', p_delivery_to,
            'pool_line_count', jsonb_array_length(p_pool_lines),
            'pool_region_count', jsonb_array_length(p_pool_regions)
        ),
        true
    );

    return jsonb_build_object(
        'pool_id', v_pool_id,
        'pool_line_ids', to_jsonb(v_pool_line_ids)
    );
end; $$;

comment on function public.rpc_create_pool(uuid, jsonb, jsonb, date, date, int) is
    'M4 §2.4 + D-M6-13 + D-TSP-CATEGORY-BRIDGE | Container Pool model | Caller: MPK org member.
     Creates Pool (status=draft) + N pool_lines + M pool_regions atomically.
     Floor enforcement: explicit livestock_category_id per line wins; otherwise
     tsp_sku_id is resolved via tsp_sku_category_map (bridge). Empty bridge →
     floor check skipped (graceful), preserving back-compat behaviour.
     Returns: {pool_id, pool_line_ids[]}.';


-- ------------------------------------------------------------
-- RPC-M6-02: rpc_publish_pool (M4 §2.4)
-- Caller: MPK organization member (owner of the pool).
-- FSM: draft -> filling. Calls rpc_retry_match_pool inline so any batches
--      already in published state get Offers atomically with publication
--      (Q-TSP-RETRY-MATCH / BT-05).
-- ------------------------------------------------------------
create or replace function public.rpc_publish_pool(
    p_organization_id   uuid,
    p_pool_id           uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool          record;
begin
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    select p.*
      into v_pool
    from public.pools p
    where p.id = p_pool_id
    for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_pool.organization_id != p_organization_id then
        raise exception 'FORBIDDEN: caller does not own pool %', p_pool_id
            using errcode = 'P0001';
    end if;

    if v_pool.status = 'filling' then
        return true;  -- idempotent
    end if;
    if v_pool.status != 'draft' then
        raise exception 'INVALID_STATUS: pool must be draft (current %)', v_pool.status
            using errcode = 'P0001';
    end if;

    update public.pools
    set status = 'filling',
        published_at = now(),
        updated_at = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.published', 'pools', p_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id),
        true
    );

    -- Q-TSP-RETRY-MATCH / BT-05: broadcast offers to batches already in published
    -- state that fit this pool's lines. Same transaction — guarantees visibility
    -- of the new pool to all eligible published batches at the moment of publish.
    perform public.rpc_retry_match_pool(p_organization_id, p_pool_id);

    return true;
end; $$;

comment on function public.rpc_publish_pool(uuid, uuid) is
    'M4 §2.4 | FSM pools: draft -> filling | Caller: MPK org member.
     Idempotent. Inline call to rpc_retry_match_pool broadcasts offers to
     batches already in published state (Q-TSP-RETRY-MATCH / BT-05).';


-- ------------------------------------------------------------
-- RPC-M6-02b: rpc_retry_match_pool (Q-TSP-RETRY-MATCH / BT-05)
-- Caller: system / internal (called inline by rpc_publish_pool; safe to
--         invoke from a periodic sweep job — idempotent via offers
--         unique(batch_id, mpk_org_id)).
-- Scans batches.status='published' that fit at least one pool_line of the
-- given filling pool and upserts an Offer for the pool's MPK org, then
-- transitions newly-broadcast batches published -> offering (TSP-FLOW-01,
-- M4 §2.2 step 3) so rpc_accept_offer is reachable. FCFS semantics preserved
-- via rpc_accept_offer (mirrors rpc_lower_batch_price re-broadcast pattern).
-- Match predicate (mirrors rpc_lower_batch_price, inverted on direction):
--   pool.status='filling'
--   pool_line.is_active AND pool_line.mpk_price_per_kg >= batch.farmer_price_per_kg
--   (pool_line.tsp_sku_id IS NULL OR pool_line.tsp_sku_id = batch.tsp_sku_id)
--   capacity:  pl.current_volume_kg + heads*avg_weight_kg <= pl.max_volume_kg
--   region:    rayon exact OR oblast contains batch.region_id / its parent
--   window:    [ready_from, ready_to] overlaps [delivery_from, delivery_to]
-- ------------------------------------------------------------
create or replace function public.rpc_retry_match_pool(
    p_organization_id   uuid,
    p_pool_id           uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool                  record;
    v_mpk_org_id            uuid;
    v_offer_window_hours    int;
    v_offers_upserted       int := 0;
    v_batches_count         int := 0;
begin
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner comes from pools.organization_id.
    select p.* into v_pool
    from public.pools p
    where p.id = p_pool_id;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0001';
    end if;

    -- Only filling pools accept new matches. Other statuses are no-ops
    -- (idempotent: callers shouldn't have to pre-check).
    if v_pool.status != 'filling' then
        return jsonb_build_object(
            'offers_created', 0,
            'batches_matched_count', 0,
            'skipped_reason', 'pool_status_' || v_pool.status
        );
    end if;

    v_mpk_org_id := v_pool.organization_id;
    if v_mpk_org_id is null then
        raise exception 'POOL_HAS_NO_MPK_ORG: pool %', p_pool_id
            using errcode = 'P0001';
    end if;
    if v_mpk_org_id != p_organization_id then
        raise exception
            'ORG_MISMATCH: p_organization_id (%) does not match pool owner (%)',
            p_organization_id, v_mpk_org_id
            using errcode = 'P0001';
    end if;

    select offer_window_hours into v_offer_window_hours
    from public.tsp_config where is_active = true limit 1;
    v_offer_window_hours := coalesce(v_offer_window_hours, 24);

    with eligible as (
        select distinct b.id          as batch_id,
                        b.farmer_price_per_kg
        from public.batches b
        join public.pool_lines pl
            on  pl.pool_id = p_pool_id
            and pl.is_active = true
            and pl.mpk_price_per_kg >= b.farmer_price_per_kg
            and (pl.tsp_sku_id is null or pl.tsp_sku_id = b.tsp_sku_id)
            and (pl.max_volume_kg is null
                 or pl.current_volume_kg
                    + coalesce(b.heads * b.avg_weight_kg, 0)::int
                    <= pl.max_volume_kg)
        -- TSP-FLOW-01 (M4 §2.2 step 3): include 'offering' so additional MPK
        -- pools can also broadcast to a batch already offering (multi-MPK FCFS);
        -- 'published' batches are transitioned to 'offering' below on Offer upsert.
        where b.status in ('published', 'offering')
          and b.farmer_price_per_kg is not null
          -- window overlap (D-M6-8)
          and (v_pool.delivery_from is null or b.ready_to   is null
               or v_pool.delivery_from <= b.ready_to)
          and (v_pool.delivery_to   is null or b.ready_from is null
               or v_pool.delivery_to   >= b.ready_from)
          -- region overlap (D-M6-4)
          and exists (
              select 1 from public.pool_regions pgr
              where pgr.pool_id = p_pool_id
                and (
                    (pgr.region_type = 'rayon'
                        and pgr.region_id = b.region_id)
                    or (pgr.region_type = 'oblast' and (
                        pgr.region_id = b.region_id
                        or pgr.region_id = (
                            select parent_id from public.regions
                            where id = b.region_id
                        )
                    ))
                )
          )
    ),
    upserted as (
        insert into public.offers (
            batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at
        )
        select e.batch_id, v_mpk_org_id, e.farmer_price_per_kg, 'pending',
               now() + make_interval(hours => v_offer_window_hours), now()
        from eligible e
        on conflict (batch_id, mpk_org_id) do update
            set offered_price_per_kg = excluded.offered_price_per_kg,
                status               = 'pending',
                expires_at           = excluded.expires_at,
                responded_at         = null,
                responded_by         = null
        returning batch_id
    )
    select count(*), count(distinct batch_id)
      into v_offers_upserted, v_batches_count
    from upserted;

    if v_offers_upserted > 0 then
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        select u.batch_id,
               'broadcast_sent',
               jsonb_build_object(
                   'trigger', 'retry_match_pool',
                   'pool_id', p_pool_id,
                   'mpk_org_id', v_mpk_org_id
               ),
               null
        from (
            select distinct o.batch_id
            from public.offers o
            where o.mpk_org_id = v_mpk_org_id
              and o.status = 'pending'
              and o.batch_id in (
                  select b.id from public.batches b where b.status = 'published'
              )
        ) u;

        insert into public.platform_events (
            event_type, entity_type, entity_id, organization_id,
            actor_type, actor_id, payload, is_audit
        ) values (
            'market.pool.retry_match', 'pools', p_pool_id, v_mpk_org_id,
            'system', null,
            jsonb_build_object(
                'pool_id', p_pool_id,
                'offers_created', v_offers_upserted,
                'batches_matched_count', v_batches_count
            ),
            true
        );

        -- TSP-FLOW-01 / TSP-SCHEMA-02 fix (M4 §2.2 step 3): AFTER the broadcast_sent
        -- log above (which filters status='published'), transition newly-broadcast
        -- batches published -> offering so rpc_accept_offer's 'offering' guard is
        -- satisfiable. Mirrors rpc_lower_batch_price. Batches already 'offering'
        -- (multi-MPK) are left untouched.
        update public.batches b
        set status      = 'offering',
            offering_at = now(),
            updated_at  = now()
        where b.status = 'published'
          and exists (
              select 1 from public.offers o
              where o.batch_id = b.id
                and o.mpk_org_id = v_mpk_org_id
                and o.status     = 'pending'
          );
    end if;

    return jsonb_build_object(
        'offers_created', v_offers_upserted,
        'batches_matched_count', v_batches_count
    );
end; $$;

comment on function public.rpc_retry_match_pool(uuid, uuid) is
    'Q-TSP-RETRY-MATCH / BT-05 | Caller: system (inline from rpc_publish_pool
     or periodic sweep). p_organization_id MUST equal pools.organization_id
     (sanity-check, P-AI-2). Scans published batches that fit any pool_line of
     the given filling pool and upserts Offers for the pool MPK org. Idempotent
     via offers unique(batch_id, mpk_org_id). Transitions newly-broadcast
     batches published -> offering (TSP-FLOW-01) so rpc_accept_offer is reachable;
     FCFS semantics preserved via rpc_accept_offer.';


-- ------------------------------------------------------------
-- RPC-M6-03: rpc_accept_offer (M4 §2.3, §5)
-- Caller: MPK organization member.
-- FCFS: accept this offer, withdraw siblings (atomically), batch->matched
--       in best-matching pool_line, deal_price = offered_price.
-- Auto-close pool if sum(pool_lines.current_volume_kg) >= total_target_volume_kg.
-- ------------------------------------------------------------
create or replace function public.rpc_accept_offer(
    p_organization_id   uuid,
    p_offer_id          uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_offer         record;
    v_batch         record;
    v_volume_kg     int;
    v_pool_line     record;
    v_pool_id       uuid;
    v_total_volume  int;
    v_target_volume int;
begin
    select * into v_offer from public.offers where id = p_offer_id for update;
    if not found then
        raise exception 'OFFER_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_offer.mpk_org_id != p_organization_id then
        raise exception 'FORBIDDEN: offer belongs to another MPK' using errcode = 'P0001';
    end if;
    if v_offer.status != 'pending' then
        raise exception 'INVALID_STATUS: offer is % (must be pending)', v_offer.status
            using errcode = 'P0001';
    end if;
    if v_offer.expires_at < now() then
        update public.offers set status = 'expired' where id = p_offer_id;
        raise exception 'OFFER_EXPIRED' using errcode = 'P0001';
    end if;

    select * into v_batch from public.batches where id = v_offer.batch_id for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;
    -- Offer acceptance is only valid from canonical 'offering' state (M4 §2.3 + §5).
    -- Other transitional states ('published', 'awaiting_price_decision') would imply
    -- offer lifecycle desync — reject defensively.
    if v_batch.status != 'offering' then
        raise exception 'INVALID_STATUS: batch is % (must be offering)', v_batch.status
            using errcode = 'P0001';
    end if;

    v_volume_kg := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;
    if v_volume_kg <= 0 then
        raise exception 'BATCH_NO_VOLUME: heads x avg_weight_kg = 0; cannot match'
            using errcode = 'P0001';
    end if;

    -- Find MPK's best-matching pool_line for this batch.
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    -- Region filter mirrors D-M6-4 (rayon-exact OR oblast-via-parent_id) to enforce
    -- geographic match.
    select pl.id as pl_id,
           pl.pool_id as p_id,
           pl.mpk_price_per_kg as pl_price,
           pl.max_volume_kg as pl_max,
           pl.current_volume_kg as pl_current,
           p.total_target_volume_kg as p_total,
           p.delivery_from as p_dfrom,
           p.delivery_to as p_dto
      into v_pool_line
    from public.pool_lines pl
    join public.pools p               on p.id = pl.pool_id
    where p.status = 'filling'
      and p.organization_id = p_organization_id
      and pl.is_active = true
      and (pl.tsp_sku_id is null or pl.tsp_sku_id = v_batch.tsp_sku_id)
      -- C1 fix (TSP-ACCEPT-PRICE): direction must mirror rpc_retry_match_pool /
      -- rpc_lower_batch_price eligibility (pl.mpk_price >= offered ask). The prior
      -- '<=' allowed a match only when mpk_price == offered_price exactly, rejecting
      -- every above-ask bid (the normal case) with NO_MATCHING_POOL_LINE.
      and pl.mpk_price_per_kg >= v_offer.offered_price_per_kg
      and (pl.max_volume_kg is null
           or pl.current_volume_kg + v_volume_kg <= pl.max_volume_kg)
      and (p.delivery_from is null or v_batch.ready_to   is null
           or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null
           or p.delivery_to   >= v_batch.ready_from)
      and exists (
          select 1 from public.pool_regions pgr
          where pgr.pool_id = p.id
            and (
                (pgr.region_type = 'rayon'
                    and pgr.region_id = v_batch.region_id)
                or (pgr.region_type = 'oblast' and (
                    pgr.region_id = v_batch.region_id
                    or pgr.region_id = (
                        select parent_id from public.regions
                        where id = v_batch.region_id
                    )
                ))
            )
      )
    order by pl.mpk_price_per_kg desc
    limit 1
    for update;
    if not found then
        raise exception
            'NO_MATCHING_POOL_LINE: MPK has no filling pool_line accepting batch % (region/window/sku/capacity/price mismatch)', v_batch.id
            using errcode = 'P0001';
    end if;

    v_pool_id       := v_pool_line.p_id;
    v_target_volume := v_pool_line.p_total;

    -- 1) Accept this offer
    update public.offers
    set status       = 'accepted',
        responded_at = now(),
        responded_by = public.fn_current_user_id()
    where id = p_offer_id;

    -- 2) Withdraw siblings (FCFS)
    update public.offers
    set status       = 'withdrawn',
        responded_at = now()
    where batch_id = v_offer.batch_id
      and id != p_offer_id
      and status = 'pending';

    -- 3) Batch -> matched.
    -- D-M6-DEALPRICE (CEO 2026-06-23): the farmer is paid the MATCHED pool line's
    -- MPK bid (v_pool_line.pl_price, the highest eligible line picked by the
    -- ORDER BY ... desc above), NOT merely their own ask (offered_price). The
    -- ask is the floor; any higher MPK bid accrues to the farmer.
    update public.batches
    set status            = 'matched',
        pool_line_id      = v_pool_line.pl_id,
        deal_price_per_kg = v_pool_line.pl_price,
        matched_at        = now(),
        updated_at        = now()
    where id = v_batch.id;

    -- 4) pool_line volume
    update public.pool_lines
    set current_volume_kg = current_volume_kg + v_volume_kg,
        updated_at        = now()
    where id = v_pool_line.pl_id;

    -- 5) pool aggregate counter
    update public.pools
    set matched_heads = matched_heads + v_batch.heads,
        updated_at    = now()
    where id = v_pool_id;

    -- 6) Auto-close if total volume target reached (D-TSP-9)
    -- Sum is read AFTER the pool_line UPDATE above; pools row is locked by the
    -- SELECT...JOIN FOR UPDATE earlier (locks pool_lines + pools + pool_requests),
    -- so concurrent accepts on the same pool serialize. The "where status='filling'"
    -- guard on the UPDATE + "if found" gate add defensive idempotency in case any
    -- future call path reaches this branch with the pool already auto-closed.
    select coalesce(sum(current_volume_kg), 0) into v_total_volume
    from public.pool_lines where pool_id = v_pool_id;

    if v_target_volume is not null and v_total_volume >= v_target_volume then
        update public.pools
        set status       = 'closed_filled',
            completed_at = now(),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()),  -- TSP-FLOW-07: reveal MPK to farmer at confirmed (D-M6-5/12); mirrors rpc_self_accept_offer
            updated_at   = now()
        where id = v_pool_id
          and status = 'filling';

        if found then
            -- All matched batches in this pool -> confirmed
            update public.batches b
            set status       = 'confirmed',
                confirmed_at = now(),
                updated_at   = now()
            from public.pool_lines pl
            where pl.pool_id = v_pool_id
              and b.pool_line_id = pl.id
              and b.status = 'matched';

            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            select b.id, 'confirmed',
                   jsonb_build_object('pool_id', v_pool_id, 'auto_close', true),
                   public.fn_current_user_id()
            from public.batches b
            join public.pool_lines pl on pl.id = b.pool_line_id
            where pl.pool_id = v_pool_id and b.status = 'confirmed';

            insert into public.platform_events (
                event_type, entity_type, entity_id, organization_id,
                actor_type, actor_id, payload, is_audit
            ) values (
                'market.pool.closed_filled', 'pools', v_pool_id, p_organization_id,
                'system', public.fn_current_user_id(),
                jsonb_build_object('pool_id', v_pool_id, 'total_volume_kg', v_total_volume),
                true
            );
        end if;
    end if;

    -- batch_events: matched + offer_accepted (M4 §6.4 canonical audit log)
    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (v_batch.id, 'matched',
        jsonb_build_object(
            'pool_id', v_pool_id,
            'pool_line_id', v_pool_line.pl_id,
            'via', 'offer_accept',
            'deal_price_per_kg', v_offer.offered_price_per_kg
        ),
        public.fn_current_user_id());

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (v_batch.id, 'offer_accepted',
        jsonb_build_object(
            'offer_id', p_offer_id,
            'mpk_org_id', p_organization_id,
            'pool_id', v_pool_id,
            'pool_line_id', v_pool_line.pl_id,
            'deal_price_per_kg', v_offer.offered_price_per_kg,
            'volume_kg', v_volume_kg
        ),
        public.fn_current_user_id());

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.offer.accepted', 'offers', p_offer_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object(
            'offer_id', p_offer_id,
            'batch_id', v_batch.id,
            'pool_line_id', v_pool_line.pl_id,
            'deal_price_per_kg', v_offer.offered_price_per_kg
        ),
        true
    );

    return jsonb_build_object(
        'batch_id', v_batch.id,
        'pool_id', v_pool_id,
        'pool_line_id', v_pool_line.pl_id,
        'deal_price_per_kg', v_offer.offered_price_per_kg,
        'volume_kg', v_volume_kg
    );
end; $$;

comment on function public.rpc_accept_offer(uuid, uuid) is
    'M4 §2.3 + §5 | FCFS broadcast accept | Caller: MPK org member.
     Picks best-matching pool_line (highest mpk_price), withdraws siblings,
     batch -> matched, auto-closes pool if total volume target reached
     (matched batches in pool -> confirmed).';


-- ------------------------------------------------------------
-- RPC-M6-04: rpc_reject_offer (M4 §2.3)
-- Caller: MPK org member.
-- ------------------------------------------------------------
create or replace function public.rpc_reject_offer(
    p_organization_id   uuid,
    p_offer_id          uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_offer record;
begin
    select * into v_offer from public.offers where id = p_offer_id for update;
    if not found then
        raise exception 'OFFER_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_offer.mpk_org_id != p_organization_id then
        raise exception 'FORBIDDEN: offer belongs to another MPK' using errcode = 'P0001';
    end if;
    if v_offer.status = 'rejected' then
        return true;  -- idempotent
    end if;
    if v_offer.status != 'pending' then
        raise exception 'INVALID_STATUS: offer is % (must be pending)', v_offer.status
            using errcode = 'P0001';
    end if;

    update public.offers
    set status       = 'rejected',
        responded_at = now(),
        responded_by = public.fn_current_user_id()
    where id = p_offer_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (v_offer.batch_id, 'offer_rejected',
        jsonb_build_object('offer_id', p_offer_id, 'mpk_org_id', p_organization_id),
        public.fn_current_user_id());

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.offer.rejected', 'offers', p_offer_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('offer_id', p_offer_id, 'batch_id', v_offer.batch_id),
        false
    );

    return true;
end; $$;

comment on function public.rpc_reject_offer(uuid, uuid) is
    'M4 §2.3 | Caller: MPK org member. Idempotent.';


-- ------------------------------------------------------------
-- RPC-M6-05: rpc_lower_batch_price (M4 §2.6 + D-M6-3)
-- Caller: farmer (batch owner).
-- Stop-rule: clamped = GREATEST(requested, minimum_price). Lower than floor
-- is allowed only by clamping back to floor (no silent acceptance).
-- Re-broadcast: creates / refreshes Offer rows for MPK orgs whose active
-- filling pools have at least one pool_line matching this batch at >= clamped.
-- FSM: awaiting_price_decision -> offering.
-- ------------------------------------------------------------
create or replace function public.rpc_lower_batch_price(
    p_organization_id   uuid,
    p_batch_id          uuid,
    p_new_price_per_kg  int
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch                 record;
    v_floor                 int;
    v_clamped               int;
    v_was_clamped           boolean := false;
    v_offer_window_hours    int;
    v_mpk_count             int := 0;
begin
    if p_new_price_per_kg is null or p_new_price_per_kg <= 0 then
        raise exception 'INVALID_INPUT: p_new_price_per_kg must be > 0'
            using errcode = 'P0001';
    end if;

    select * into v_batch
    from public.batches
    where id = p_batch_id and organization_id = p_organization_id
    for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_batch.status != 'awaiting_price_decision' then
        raise exception
            'INVALID_STATUS: can lower price only from awaiting_price_decision (current %)',
            v_batch.status using errcode = 'P0001';
    end if;

    -- D-M6-3 floor clamp — enabled via D-TSP-CATEGORY-BRIDGE (A2, 2026-06-15).
    -- Resolution: batch.tsp_sku_id → tsp_sku_category_map → minimum_prices.
    -- Region match: exact rayon wins; national (region_id IS NULL) fallback.
    -- When the bridge is empty for this SKU OR no minimum_prices row matches,
    -- v_floor stays NULL → clamp is no-op (graceful degradation).
    select mp.price_per_kg
      into v_floor
    from public.tsp_sku_category_map m
    join public.minimum_prices mp on mp.category_id = m.category_id
    where m.tsp_sku_id = v_batch.tsp_sku_id
      and m.is_active  = true
      and mp.is_active = true
      and (mp.region_id = v_batch.region_id or mp.region_id is null)
      and (mp.valid_to is null or mp.valid_to >= current_date)
    order by (mp.region_id = v_batch.region_id) desc nulls last,
             mp.valid_from desc
    limit 1;

    v_clamped     := greatest(p_new_price_per_kg, coalesce(v_floor, p_new_price_per_kg));
    v_was_clamped := (v_floor is not null and p_new_price_per_kg < v_floor);

    -- Move batch -> offering with new price
    update public.batches
    set farmer_price_per_kg = v_clamped,
        status              = 'offering',
        offering_at         = now(),
        updated_at          = now()
    where id = p_batch_id;

    -- Offer window from tsp_config
    select offer_window_hours into v_offer_window_hours
    from public.tsp_config where is_active = true limit 1;
    v_offer_window_hours := coalesce(v_offer_window_hours, 24);

    -- Re-broadcast: upsert offers for MPK with matching active filling pools.
    -- Capacity predicate mirrors rpc_accept_offer (line + batch volume <= max);
    -- a 1-kg gap on a line should NOT trigger an offer for a multi-tonne batch.
    with matching_mpks as (
        -- DEF-TSP-M4-OWNERSHIP (resolved): owner comes from pools.organization_id.
        select distinct p.organization_id as mpk_org_id
        from public.pools p
        join public.pool_lines pl    on pl.pool_id = p.id and pl.is_active = true
        where p.status = 'filling'
          and p.organization_id is not null
          and pl.mpk_price_per_kg >= v_clamped
          and (pl.tsp_sku_id is null or pl.tsp_sku_id = v_batch.tsp_sku_id)
          and (pl.max_volume_kg is null
               or pl.current_volume_kg
                  + coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int
                  <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null
               or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null
               or p.delivery_to   >= v_batch.ready_from)
          and exists (
              select 1 from public.pool_regions pgr
              where pgr.pool_id = p.id
                and (
                    (pgr.region_type = 'rayon'
                        and pgr.region_id = v_batch.region_id)
                    or (pgr.region_type = 'oblast' and (
                        pgr.region_id = v_batch.region_id
                        or pgr.region_id = (
                            select parent_id from public.regions
                            where id = v_batch.region_id
                        )
                    ))
                )
          )
    ),
    upserted as (
        insert into public.offers (
            batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at
        )
        select p_batch_id, mm.mpk_org_id, v_clamped, 'pending',
               now() + make_interval(hours => v_offer_window_hours), now()
        from matching_mpks mm
        on conflict (batch_id, mpk_org_id) do update
            set offered_price_per_kg = excluded.offered_price_per_kg,
                status               = 'pending',
                expires_at           = excluded.expires_at,
                responded_at         = null,
                responded_by         = null
        returning 1
    )
    select count(*) into v_mpk_count from upserted;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'price_lowered',
        jsonb_build_object(
            'requested_price_per_kg', p_new_price_per_kg,
            'old_price_per_kg', v_batch.farmer_price_per_kg,
            'new_price_per_kg', v_clamped,
            'was_clamped', v_was_clamped,
            'floor_price_per_kg', v_floor,
            'broadcast_mpk_count', v_mpk_count
        ),
        public.fn_current_user_id());

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.batch.price_lowered', 'batches', p_batch_id, p_organization_id,
        'farmer', public.fn_current_user_id(),
        jsonb_build_object(
            'batch_id', p_batch_id,
            'new_price', v_clamped,
            'was_clamped', v_was_clamped,
            'broadcast_mpk_count', v_mpk_count
        ),
        true
    );

    return jsonb_build_object(
        'new_price', v_clamped,
        'was_clamped', v_was_clamped,
        'broadcast_mpk_count', v_mpk_count
    );
end; $$;

comment on function public.rpc_lower_batch_price(uuid, uuid, int) is
    'M4 §2.6 + D-M6-3 | Stop-rule clamp + re-broadcast | Caller: farmer (batch owner).
     FSM batches: awaiting_price_decision -> offering. Clamps requested price to
     minimum_price floor. Refreshes offers for MPK orgs whose filling pools have
     matching lines (region overlap D-M6-4 + ready/delivery overlap D-M6-8 +
     tsp_sku + capacity).';


-- ------------------------------------------------------------
-- RPC-M6-05b: rpc_set_batch_terms (TSP-FLOW-03)
-- Caller: farmer (batch owner). Sets farmer_price_per_kg + ready window on a
-- batch BEFORE matching. Additive (P7): does NOT change rpc_create_batch /
-- rpc_publish_batch signatures. Without a non-null farmer_price_per_kg a batch
-- is invisible to rpc_retry_match_pool eligibility. Allowed from draft|published
-- (terms lock once offering/matched). D-M6-6 invariant ready_to >= ready_from.
-- ------------------------------------------------------------
create or replace function public.rpc_set_batch_terms(
    p_organization_id     uuid,
    p_batch_id            uuid,
    p_farmer_price_per_kg int  default null,
    p_ready_from          date default null,
    p_ready_to            date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch  record;
    v_price  int;
    v_from   date;
    v_to     date;
begin
    select * into v_batch
    from public.batches
    where id = p_batch_id and organization_id = p_organization_id
    for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_batch.status not in ('draft', 'published') then
        raise exception
            'INVALID_STATUS: batch terms can be set only from draft|published (current %)',
            v_batch.status using errcode = 'P0001';
    end if;

    v_price := coalesce(p_farmer_price_per_kg, v_batch.farmer_price_per_kg);
    v_from  := coalesce(p_ready_from, v_batch.ready_from);
    v_to    := coalesce(p_ready_to,   v_batch.ready_to);

    if v_price is not null and v_price <= 0 then
        raise exception 'INVALID_INPUT: farmer_price_per_kg must be > 0'
            using errcode = 'P0001';
    end if;
    if v_from is not null and v_to is not null and v_to < v_from then
        raise exception 'INVALID_INPUT: ready_to (%) must be >= ready_from (%)', v_to, v_from
            using errcode = 'P0001';
    end if;

    update public.batches
    set farmer_price_per_kg = v_price,
        ready_from          = v_from,
        ready_to            = v_to,
        updated_at          = now()
    where id = p_batch_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'terms_set',
        jsonb_build_object(
            'farmer_price_per_kg', v_price,
            'ready_from', v_from,
            'ready_to', v_to
        ),
        public.fn_current_user_id());

    return jsonb_build_object(
        'batch_id', p_batch_id,
        'farmer_price_per_kg', v_price,
        'ready_from', v_from,
        'ready_to', v_to,
        'status', v_batch.status
    );
end; $$;

comment on function public.rpc_set_batch_terms(uuid, uuid, int, date, date) is
    'TSP-FLOW-03 | Caller: farmer (batch owner). Sets farmer_price_per_kg + ready
     window on a draft|published batch so it becomes eligible for pool matching
     (rpc_retry_match_pool requires non-null farmer_price_per_kg). Additive RPC
     (P7): does not change rpc_create_batch/rpc_publish_batch signatures.
     D-M6-6 invariant ready_to >= ready_from enforced.';

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_set_batch_terms', 'rpc_set_batch_terms', null, 'd02_tsp.sql (TSP-FLOW-03 / Phase 2)',
     'Set farmer_price_per_kg + ready window on draft|published batch; unblocks matching eligibility')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;


-- ------------------------------------------------------------
-- RPC-M6-06: rpc_confirm_dispatch (D-M6-10)
-- Caller: farmer (batch owner). FSM: confirmed -> dispatched.
-- ------------------------------------------------------------
create or replace function public.rpc_confirm_dispatch(
    p_organization_id   uuid,
    p_batch_id          uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_batch record;
begin
    select * into v_batch
    from public.batches
    where id = p_batch_id and organization_id = p_organization_id
    for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_batch.status = 'dispatched' then
        return true;  -- idempotent
    end if;
    if v_batch.status != 'confirmed' then
        raise exception 'INVALID_STATUS: must be confirmed (current %)', v_batch.status
            using errcode = 'P0001';
    end if;

    update public.batches
    set status        = 'dispatched',
        dispatched_at = now(),
        updated_at    = now()
    where id = p_batch_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'dispatched',
        jsonb_build_object('batch_id', p_batch_id),
        public.fn_current_user_id());

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.batch.dispatched', 'batches', p_batch_id, p_organization_id,
        'farmer', public.fn_current_user_id(),
        jsonb_build_object('batch_id', p_batch_id),
        true
    );

    return true;
end; $$;

comment on function public.rpc_confirm_dispatch(uuid, uuid) is
    'D-M6-10 | FSM batches: confirmed -> dispatched | Caller: farmer (batch owner). Idempotent.';


-- ------------------------------------------------------------
-- RPC-M6-07: rpc_confirm_delivery (D-M6-10)
-- Caller: MPK (derived via batch.pool_line_id -> pools.organization_id).
-- FSM: dispatched -> delivered.
-- ------------------------------------------------------------
create or replace function public.rpc_confirm_delivery(
    p_organization_id   uuid,
    p_batch_id          uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch         record;
    v_mpk_org_id    uuid;
begin
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    select b.*, p.organization_id as mpk_org_id
      into v_batch
    from public.batches b
    left join public.pool_lines pl on pl.id = b.pool_line_id
    left join public.pools p       on p.id = pl.pool_id
    where b.id = p_batch_id
    for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;

    v_mpk_org_id := v_batch.mpk_org_id;
    if v_mpk_org_id is null or v_mpk_org_id != p_organization_id then
        raise exception 'FORBIDDEN: only the receiving MPK confirms delivery (D-M6-10)'
            using errcode = 'P0001';
    end if;
    if v_batch.status = 'delivered' then
        return true;  -- idempotent
    end if;
    if v_batch.status != 'dispatched' then
        raise exception 'INVALID_STATUS: must be dispatched (current %)', v_batch.status
            using errcode = 'P0001';
    end if;

    update public.batches
    set status       = 'delivered',
        delivered_at = now(),
        updated_at   = now()
    where id = p_batch_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'delivered',
        jsonb_build_object('batch_id', p_batch_id, 'mpk_org_id', p_organization_id),
        public.fn_current_user_id());

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.batch.delivered', 'batches', p_batch_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('batch_id', p_batch_id),
        true
    );

    return true;
end; $$;

comment on function public.rpc_confirm_delivery(uuid, uuid) is
    'D-M6-10 | FSM batches: dispatched -> delivered | Caller: MPK (deal counterparty). Idempotent.';


-- ------------------------------------------------------------
-- RPC-M6-08: rpc_submit_deal_review (D-M6-11 + D-M6-12)
-- Caller: farmer (batch owner) or MPK (counterparty).
-- Inserts deal_reviews row + 1 dimension_score row.
-- D-M6-12 double-blind: if the other side already submitted, set visible_at
-- on BOTH reviews to now() in a single update.
-- ------------------------------------------------------------
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

    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    select b.*, p.organization_id as mpk_org_id
      into v_batch
    from public.batches b
    left join public.pool_lines pl on pl.id = b.pool_line_id
    left join public.pools p       on p.id = pl.pool_id
    where b.id = p_batch_id;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;
    -- Microstep6 §4c + D-M6-11: review window opens only after `delivered`.
    -- A farmer rating MPK weight accuracy before delivery is undefined;
    -- an MPK rating livestock condition before receiving them is undefined.
    if v_batch.status != 'delivered' then
        raise exception 'INVALID_STATUS: reviews only from delivered (current %)',
            v_batch.status using errcode = 'P0001';
    end if;

    v_mpk_org_id := v_batch.mpk_org_id;

    -- Q3 / Resolution: derive reviewer_role from p_organization_id
    if v_batch.organization_id = p_organization_id then
        v_reviewer_role := 'farmer';
    elsif v_mpk_org_id is not null and v_mpk_org_id = p_organization_id then
        v_reviewer_role := 'mpk';
    else
        raise exception 'FORBIDDEN: organization is not a party to this batch'
            using errcode = 'P0001';
    end if;

    -- Insert review (unique batch_id + reviewer_org_id prevents duplicate)
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

    -- D-M6-12 double-blind reveal: if other side already submitted, reveal both
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
end; $$;

comment on function public.rpc_submit_deal_review(uuid, uuid, int, uuid, int, text) is
    'D-M6-11 + D-M6-12 | Mutual deal review with double-blind reveal.
     Role derived from p_organization_id: farmer = batch.organization_id,
     mpk = pool_line -> pools -> pool_requests.organization_id.
     visible_at set on BOTH reviews when both sides submitted.';


-- ------------------------------------------------------------
-- RPC-M6-09: rpc_pool_return_batches (D-TSP-10 / Microstep6 §4f шаг 6 A)
-- Caller: MPK (pool owner). FSM pools: awaiting_mpk_decision -> closed_unfilled.
-- All matched batches in pool -> published (pool_line_id=NULL, deal_price=NULL).
-- ------------------------------------------------------------
create or replace function public.rpc_pool_return_batches(
    p_organization_id   uuid,
    p_pool_id           uuid
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool          record;
    v_count         int := 0;
    v_batch_id      uuid;
begin
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    select p.*
      into v_pool
    from public.pools p
    where p.id = p_pool_id
    for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_pool.organization_id != p_organization_id then
        raise exception 'FORBIDDEN: caller does not own pool %', p_pool_id
            using errcode = 'P0001';
    end if;
    if v_pool.status != 'awaiting_mpk_decision' then
        raise exception 'INVALID_STATUS: pool must be awaiting_mpk_decision (current %)',
            v_pool.status using errcode = 'P0001';
    end if;

    -- Withdraw any still-pending offers for matched batches in this pool BEFORE
    -- resetting batch.pool_line_id (M4 §2.4 close_pool: pending offers to MPKs
    -- for this category are withdrawn when the pool closes).
    update public.offers o
    set status = 'withdrawn', responded_at = now()
    from public.batches b
    join public.pool_lines pl on pl.id = b.pool_line_id
    where pl.pool_id = p_pool_id
      and b.id = o.batch_id
      and o.status = 'pending';

    -- Return each matched batch -> published
    for v_batch_id in
        select b.id
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
        for update
    loop
        update public.batches
        set status            = 'published',
            pool_line_id      = null,
            deal_price_per_kg = null,
            updated_at        = now()
        where id = v_batch_id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch_id, 'returned_to_published',
            jsonb_build_object('pool_id', p_pool_id),
            public.fn_current_user_id());

        v_count := v_count + 1;
    end loop;

    -- Reset pool_line volumes
    update public.pool_lines
    set current_volume_kg = 0,
        updated_at        = now()
    where pool_id = p_pool_id;

    -- Pool -> closed_unfilled
    update public.pools
    set status        = 'closed_unfilled',
        matched_heads = 0,
        completed_at  = now(),
        updated_at    = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.closed_unfilled', 'pools', p_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id, 'returned_batches', v_count),
        true
    );

    return v_count;
end; $$;

comment on function public.rpc_pool_return_batches(uuid, uuid) is
    'D-TSP-10 / Microstep6 §4f step 6A | FSM pools: awaiting_mpk_decision -> closed_unfilled.
     Returns: count of batches returned to published.';


-- ------------------------------------------------------------
-- RPC-M6-10: rpc_pool_accept_partial (D-TSP-10 / Microstep6 §4f шаг 6 B)
-- Caller: MPK (pool owner). FSM pools: awaiting_mpk_decision -> closed_partial.
-- All matched batches in pool -> confirmed.
-- ------------------------------------------------------------
create or replace function public.rpc_pool_accept_partial(
    p_organization_id   uuid,
    p_pool_id           uuid
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool          record;
    v_count         int := 0;
    v_batch_id      uuid;
begin
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    select p.*
      into v_pool
    from public.pools p
    where p.id = p_pool_id
    for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_pool.organization_id != p_organization_id then
        raise exception 'FORBIDDEN: caller does not own pool %', p_pool_id
            using errcode = 'P0001';
    end if;
    if v_pool.status != 'awaiting_mpk_decision' then
        raise exception 'INVALID_STATUS: pool must be awaiting_mpk_decision (current %)',
            v_pool.status using errcode = 'P0001';
    end if;

    for v_batch_id in
        select b.id
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
        for update
    loop
        update public.batches
        set status       = 'confirmed',
            confirmed_at = now(),
            updated_at   = now()
        where id = v_batch_id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch_id, 'confirmed',
            jsonb_build_object('pool_id', p_pool_id, 'partial_accept', true),
            public.fn_current_user_id());

        v_count := v_count + 1;
    end loop;

    update public.pools
    set status       = 'closed_partial',
        completed_at = now(),
        updated_at   = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.closed_partial', 'pools', p_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id, 'confirmed_batches', v_count),
        true
    );

    return v_count;
end; $$;

comment on function public.rpc_pool_accept_partial(uuid, uuid) is
    'D-TSP-10 / Microstep6 §4f step 6B | FSM pools: awaiting_mpk_decision -> closed_partial.
     All matched batches -> confirmed. Returns: count of confirmed batches.';


-- ------------------------------------------------------------
-- RPC-M6-13: rpc_cancel_pool (Microstep4 §4.1 + Microstep6 §4f шаг 8a)
-- Caller: MPK (pool owner). FSM pools: filling -> cancelled.
-- Strict (option A): cancel allowed only from 'filling'. Draft pools should
-- use a delete RPC (not implemented in this pass).
-- Atomically: withdraw pending offers, return matched batches to 'published'
-- (pool_line_id=NULL, deal_price=NULL), zero out pool_line volumes, mark pool.
-- Idempotent: returns 0 if already cancelled.
-- ------------------------------------------------------------
create or replace function public.rpc_cancel_pool(
    p_organization_id   uuid,
    p_pool_id           uuid,
    p_reason            text default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool          record;
    v_count         int := 0;
    v_batch_id      uuid;
begin
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    select p.* into v_pool
    from public.pools p
    where p.id = p_pool_id
    for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_pool.organization_id != p_organization_id then
        raise exception 'FORBIDDEN: caller does not own pool %', p_pool_id
            using errcode = 'P0001';
    end if;

    if v_pool.status = 'cancelled' then
        return 0;
    end if;
    if v_pool.status != 'filling' then
        raise exception 'INVALID_STATUS: cancel allowed only from filling (current %)',
            v_pool.status using errcode = 'P0001';
    end if;

    -- Withdraw any pending offers for matched batches BEFORE resetting pool_line_id
    update public.offers o
    set status = 'withdrawn', responded_at = now()
    from public.batches b
    join public.pool_lines pl on pl.id = b.pool_line_id
    where pl.pool_id = p_pool_id
      and b.id = o.batch_id
      and o.status = 'pending';

    -- Return each matched batch -> published
    for v_batch_id in
        select b.id
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
        for update
    loop
        update public.batches
        set status            = 'published',
            pool_line_id      = null,
            deal_price_per_kg = null,
            updated_at        = now()
        where id = v_batch_id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch_id, 'returned_to_pool_cancelled',
            jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason),
            public.fn_current_user_id());

        v_count := v_count + 1;
    end loop;

    -- Reset pool_line running volumes
    update public.pool_lines
    set current_volume_kg = 0,
        updated_at        = now()
    where pool_id = p_pool_id;

    -- Pool -> cancelled
    update public.pools
    set status        = 'cancelled',
        matched_heads = 0,
        cancelled_at  = now(),
        updated_at    = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.cancelled', 'pools', p_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object(
            'pool_id', p_pool_id,
            'reason', p_reason,
            'returned_batches', v_count
        ),
        true
    );

    return v_count;
end; $$;

comment on function public.rpc_cancel_pool(uuid, uuid, text) is
    'Microstep4 §4.1 / Microstep6 §4f step 8a | FSM pools: filling -> cancelled.
     Caller: MPK (pool owner). Atomically withdraws pending offers, returns matched
     batches to published, resets pool_line volumes, marks pool cancelled.
     Returns: count of batches returned to published. Idempotent (already cancelled = 0).';


-- ------------------------------------------------------------
-- RPC-M6-11: rpc_get_reference_price (M4 §1.1 / D-M6-12 reference)
-- Caller: any. STABLE read. MANDATORY disclaimer_text in response (Art.171).
-- ------------------------------------------------------------
create or replace function public.rpc_get_reference_price(
    p_organization_id   uuid,
    p_category_id       uuid,
    p_region_id         uuid default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_disclaimer text :=
        'Справочные цены являются индикативными рыночными ориентирами и не являются обязательными для применения. Участие добровольное.';
    v_result jsonb;
begin
    select jsonb_build_object(
        'category_id',     rp.category_id,
        'region_id',       rp.region_id,
        'price_per_kg',    rp.price_per_kg,
        'valid_from',      rp.valid_from,
        'valid_to',        rp.valid_to,
        'disclaimer_text', v_disclaimer
    ) into v_result
    from public.reference_prices rp
    where rp.category_id = p_category_id
      and rp.is_active = true
      and (p_region_id is null or rp.region_id = p_region_id or rp.region_id is null)
    order by
        case when p_region_id is not null and rp.region_id = p_region_id then 0 else 1 end,
        rp.valid_from desc
    limit 1;

    if v_result is null then
        v_result := jsonb_build_object(
            'category_id',     p_category_id,
            'region_id',       p_region_id,
            'price_per_kg',    null,
            'disclaimer_text', v_disclaimer
        );
    end if;

    return v_result;
end; $$;

comment on function public.rpc_get_reference_price(uuid, uuid, uuid) is
    'M4 §1.1 | Reference price (indicative) per livestock category.
     Region match: exact first, then national fallback (region_id IS NULL).
     MANDATORY disclaimer_text in every response (Art.171 PK RK). STABLE.';


-- ------------------------------------------------------------
-- RPC-M6-12: rpc_get_minimum_price (M4 §1.1 / D-M6-3 floor)
-- Caller: any. STABLE read. MANDATORY disclaimer_text in response (Art.171).
-- ------------------------------------------------------------
create or replace function public.rpc_get_minimum_price(
    p_organization_id   uuid,
    p_category_id       uuid,
    p_region_id         uuid default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_disclaimer text :=
        'Минимальная цена — защитный стандарт ассоциации TURAN для фермеров. Это индикативный ориентир, не обязательный к применению. Участие в TSP добровольное.';
    v_result jsonb;
begin
    select jsonb_build_object(
        'category_id',     mp.category_id,
        'region_id',       mp.region_id,
        'price_per_kg',    mp.price_per_kg,
        'valid_from',      mp.valid_from,
        'valid_to',        mp.valid_to,
        'disclaimer_text', v_disclaimer
    ) into v_result
    from public.minimum_prices mp
    where mp.category_id = p_category_id
      and mp.is_active = true
      and (p_region_id is null or mp.region_id = p_region_id or mp.region_id is null)
    order by
        case when p_region_id is not null and mp.region_id = p_region_id then 0 else 1 end,
        mp.valid_from desc
    limit 1;

    if v_result is null then
        v_result := jsonb_build_object(
            'category_id',     p_category_id,
            'region_id',       p_region_id,
            'price_per_kg',    null,
            'disclaimer_text', v_disclaimer
        );
    end if;

    return v_result;
end; $$;

comment on function public.rpc_get_minimum_price(uuid, uuid, uuid) is
    'M4 §1.1 + D-M6-3 | Protective floor price per livestock category.
     Region match: exact first, then national fallback (region_id IS NULL).
     MANDATORY disclaimer_text in every response (Art.171 PK RK). STABLE.';


-- ============================================================
-- SECTION 8a: A-CAT ADMIN RPC (D-TSP-CATEGORY-BRIDGE, 2026-06-15)
-- ============================================================
-- Source: Docs/AGOS-Dok6-A-CAT-AdminScreens-v1_0.md §2.4
-- All RPCs gated by fn_is_admin() and return jsonb {ok, id?, error?}
-- (write RPCs) or TABLE (read RPCs). No platform_events emitted —
-- spec is silent; pending Dok 4 admin-event family (Architect call).
-- ------------------------------------------------------------

-- AC-1: rpc_admin_upsert_livestock_category
create or replace function public.rpc_admin_upsert_livestock_category(
    p_code              text,
    p_name_ru           text,
    p_description_ru    text default null,
    p_sort_order        int  default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_code is null or btrim(p_code) = '' or p_name_ru is null or btrim(p_name_ru) = '' then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;

    insert into public.livestock_categories (code, name_ru, description_ru, sort_order, is_active)
    values (p_code, p_name_ru, p_description_ru, coalesce(p_sort_order, 0), true)
    on conflict (code) do update
        set name_ru        = excluded.name_ru,
            description_ru = excluded.description_ru,
            sort_order     = excluded.sort_order,
            is_active      = true
    returning id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

comment on function public.rpc_admin_upsert_livestock_category(text, text, text, int) is
    'A-CAT AC-1 | Admin upsert of livestock_categories by code. Re-activates on collision.';


-- AC-2: rpc_admin_deactivate_livestock_category
create or replace function public.rpc_admin_deactivate_livestock_category(
    p_category_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_category_id is null then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;
    if not exists (select 1 from public.livestock_categories where id = p_category_id) then
        return jsonb_build_object('ok', false, 'error', 'CATEGORY_NOT_FOUND');
    end if;

    -- Hard-block: any active SKU mapping or active price referencing this category.
    if exists (
        select 1 from public.tsp_sku_category_map
         where category_id = p_category_id and is_active = true
    ) or exists (
        select 1 from public.minimum_prices
         where category_id = p_category_id and is_active = true
    ) or exists (
        select 1 from public.reference_prices
         where category_id = p_category_id and is_active = true
    ) then
        return jsonb_build_object('ok', false, 'error', 'CATEGORY_IN_USE');
    end if;

    update public.livestock_categories
       set is_active = false
     where id = p_category_id;

    return jsonb_build_object('ok', true);
end; $$;

comment on function public.rpc_admin_deactivate_livestock_category(uuid) is
    'A-CAT AC-2 | Admin deactivate category. Blocks if active SKU mappings or active prices reference it.';


-- AC-3: rpc_admin_set_category_rule
create or replace function public.rpc_admin_set_category_rule(
    p_category_id   uuid,
    p_breed_group   text default null,
    p_sex           text default null,
    p_age_min       int  default null,
    p_age_max       int  default null,
    p_weight_min    int  default null,
    p_weight_max    int  default null,
    p_bcs_min       numeric(3,1) default null,
    p_bcs_max       numeric(3,1) default null,
    p_priority      int  default 0,
    p_version       int  default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_version int;
    v_id      uuid;
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_category_id is null then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;
    if not exists (select 1 from public.livestock_categories where id = p_category_id) then
        return jsonb_build_object('ok', false, 'error', 'CATEGORY_NOT_FOUND');
    end if;

    -- Caller may pin a version; otherwise stage as next (max+1).
    v_version := coalesce(
        p_version,
        (select coalesce(max(version), 0) + 1
           from public.livestock_category_rules
          where category_id = p_category_id)
    );

    insert into public.livestock_category_rules (
        category_id, version,
        breed_group, sex,
        age_min_months, age_max_months,
        weight_min_kg, weight_max_kg,
        bcs_min, bcs_max,
        priority, is_active
    ) values (
        p_category_id, v_version,
        p_breed_group, p_sex,
        p_age_min, p_age_max,
        p_weight_min, p_weight_max,
        p_bcs_min, p_bcs_max,
        coalesce(p_priority, 0),
        false  -- staged inactive; rpc_admin_activate_rule_version flips it on
    )
    returning id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id, 'version', v_version);
end; $$;

comment on function public.rpc_admin_set_category_rule(uuid, text, text, int, int, int, int, numeric, numeric, int, int) is
    'A-CAT AC-3 | Admin stage a new category rule (inactive). Activate via rpc_admin_activate_rule_version.';


-- AC-4: rpc_admin_activate_rule_version
create or replace function public.rpc_admin_activate_rule_version(
    p_category_id   uuid,
    p_version       int
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_activated int;
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_category_id is null or p_version is null then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;
    if not exists (
        select 1 from public.livestock_category_rules
         where category_id = p_category_id and version = p_version
    ) then
        return jsonb_build_object('ok', false, 'error', 'VERSION_NOT_FOUND');
    end if;

    -- Atomic flip within a single transaction.
    update public.livestock_category_rules
       set is_active = false
     where category_id = p_category_id
       and version    <> p_version
       and is_active   = true;

    update public.livestock_category_rules
       set is_active = true
     where category_id = p_category_id
       and version     = p_version
       and is_active   = false;
    get diagnostics v_activated = row_count;

    return jsonb_build_object('ok', true, 'activated_count', v_activated, 'version', p_version);
end; $$;

comment on function public.rpc_admin_activate_rule_version(uuid, int) is
    'A-CAT AC-4 | Admin atomically switch the active rule version for a category.';


-- AC-5: rpc_admin_map_sku_to_category
create or replace function public.rpc_admin_map_sku_to_category(
    p_tsp_sku_id    uuid,
    p_category_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_prev_version int := 0;
    v_id           uuid;
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_tsp_sku_id is null or p_category_id is null then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;
    if not exists (select 1 from public.tsp_skus where id = p_tsp_sku_id) then
        return jsonb_build_object('ok', false, 'error', 'SKU_NOT_FOUND');
    end if;
    if not exists (
        select 1 from public.livestock_categories
         where id = p_category_id and is_active = true
    ) then
        return jsonb_build_object('ok', false, 'error', 'CATEGORY_NOT_FOUND_OR_INACTIVE');
    end if;

    select coalesce(max(version), 0) into v_prev_version
      from public.tsp_sku_category_map
     where tsp_sku_id = p_tsp_sku_id;

    -- Partial unique index ux_skumap_active_sku enforces ≤1 active row per SKU.
    update public.tsp_sku_category_map
       set is_active = false
     where tsp_sku_id = p_tsp_sku_id
       and is_active  = true;

    insert into public.tsp_sku_category_map (
        tsp_sku_id, category_id, version, is_active, created_by
    ) values (
        p_tsp_sku_id, p_category_id, v_prev_version + 1, true,
        public.fn_current_user_id()
    )
    returning id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id, 'version', v_prev_version + 1);
end; $$;

comment on function public.rpc_admin_map_sku_to_category(uuid, uuid) is
    'A-CAT AC-5 | Admin atomic re-map: deactivate prior active mapping, insert new (version+1).';


-- AC-6: rpc_admin_set_minimum_price
create or replace function public.rpc_admin_set_minimum_price(
    p_category_id   uuid,
    p_region_id     uuid,
    p_price_per_kg  int,
    p_valid_from    date,
    p_valid_to      date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_category_id is null or p_valid_from is null
       or p_price_per_kg is null or p_price_per_kg <= 0 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;
    if not exists (
        select 1 from public.livestock_categories
         where id = p_category_id and is_active = true
    ) then
        return jsonb_build_object('ok', false, 'error', 'CATEGORY_NOT_FOUND_OR_INACTIVE');
    end if;
    if p_valid_to is not null and p_valid_to < p_valid_from then
        return jsonb_build_object('ok', false, 'error', 'INVALID_PERIOD');
    end if;

    -- Deactivate currently-active rows for the same (category, region).
    -- IS NOT DISTINCT FROM treats NULL=NULL (national row matches national).
    update public.minimum_prices
       set is_active = false
     where category_id = p_category_id
       and region_id is not distinct from p_region_id
       and is_active = true;

    -- Versioned by valid_from. If the exact tuple already exists, refresh it.
    insert into public.minimum_prices (
        category_id, region_id, price_per_kg,
        valid_from, valid_to, is_active,
        approved_by, approved_at
    ) values (
        p_category_id, p_region_id, p_price_per_kg,
        p_valid_from, p_valid_to, true,
        public.fn_current_user_id(), now()
    )
    on conflict (category_id, region_id, valid_from) do update
        set price_per_kg = excluded.price_per_kg,
            valid_to     = excluded.valid_to,
            is_active    = true,
            approved_by  = excluded.approved_by,
            approved_at  = excluded.approved_at
    returning id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

comment on function public.rpc_admin_set_minimum_price(uuid, uuid, int, date, date) is
    'A-CAT AC-6 | Admin set/refresh protective floor (versioned).
     Deactivates current active row for (category, region) first.
     Art.171 PK RK: floor = TURAN association standard, not price-fixing.';


-- AC-7: rpc_admin_set_reference_price
create or replace function public.rpc_admin_set_reference_price(
    p_category_id   uuid,
    p_region_id     uuid,
    p_price_per_kg  int,
    p_valid_from    date,
    p_valid_to      date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_category_id is null or p_valid_from is null
       or p_price_per_kg is null or p_price_per_kg <= 0 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;
    if not exists (
        select 1 from public.livestock_categories
         where id = p_category_id and is_active = true
    ) then
        return jsonb_build_object('ok', false, 'error', 'CATEGORY_NOT_FOUND_OR_INACTIVE');
    end if;
    if p_valid_to is not null and p_valid_to < p_valid_from then
        return jsonb_build_object('ok', false, 'error', 'INVALID_PERIOD');
    end if;

    update public.reference_prices
       set is_active = false
     where category_id = p_category_id
       and region_id is not distinct from p_region_id
       and is_active = true;

    insert into public.reference_prices (
        category_id, region_id, price_per_kg,
        legal_disclaimer_shown,
        valid_from, valid_to, is_active,
        approved_by, approved_at
    ) values (
        p_category_id, p_region_id, p_price_per_kg,
        true,
        p_valid_from, p_valid_to, true,
        public.fn_current_user_id(), now()
    )
    on conflict (category_id, region_id, valid_from) do update
        set price_per_kg = excluded.price_per_kg,
            valid_to     = excluded.valid_to,
            is_active    = true,
            approved_by  = excluded.approved_by,
            approved_at  = excluded.approved_at,
            legal_disclaimer_shown = true
    returning id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

comment on function public.rpc_admin_set_reference_price(uuid, uuid, int, date, date) is
    'A-CAT AC-7 | Admin set/refresh indicative price (versioned).
     legal_disclaimer_shown always true — Art.171 PK RK disclaimer mandatory.';


-- AR-1: rpc_admin_list_categories_with_stats
create or replace function public.rpc_admin_list_categories_with_stats()
returns table (
    id                  uuid,
    code                text,
    name_ru             text,
    description_ru      text,
    sort_order          int,
    is_active           boolean,
    active_rule_count   bigint,
    sku_mapped_count    bigint,
    has_minimum_price   boolean,
    has_reference_price boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin role required' using errcode = 'P0001';
    end if;
    return query
    select
        lc.id, lc.code, lc.name_ru, lc.description_ru, lc.sort_order, lc.is_active,
        (select count(*)::bigint from public.livestock_category_rules r
            where r.category_id = lc.id and r.is_active = true),
        (select count(*)::bigint from public.tsp_sku_category_map m
            where m.category_id = lc.id and m.is_active = true),
        exists(select 1 from public.minimum_prices mp
            where mp.category_id = lc.id and mp.is_active = true),
        exists(select 1 from public.reference_prices rp
            where rp.category_id = lc.id and rp.is_active = true)
    from public.livestock_categories lc
    order by lc.sort_order, lc.code;
end; $$;

comment on function public.rpc_admin_list_categories_with_stats() is
    'A-CAT AR-1 | Admin list of categories + derived stats for A-CAT-01 screen.';


-- AR-2: rpc_admin_list_category_rules
create or replace function public.rpc_admin_list_category_rules(
    p_category_id uuid
)
returns table (
    id              uuid,
    version         int,
    breed_group     text,
    sex             text,
    age_min_months  int,
    age_max_months  int,
    weight_min_kg   int,
    weight_max_kg   int,
    bcs_min         numeric(3,1),
    bcs_max         numeric(3,1),
    priority        int,
    is_active       boolean,
    created_at      timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin role required' using errcode = 'P0001';
    end if;
    if p_category_id is null then
        raise exception 'INVALID_INPUT: p_category_id required' using errcode = 'P0001';
    end if;
    return query
    select r.id, r.version, r.breed_group, r.sex,
           r.age_min_months, r.age_max_months,
           r.weight_min_kg, r.weight_max_kg,
           r.bcs_min, r.bcs_max,
           r.priority, r.is_active, r.created_at
      from public.livestock_category_rules r
     where r.category_id = p_category_id
     order by r.version desc, r.priority desc, r.created_at desc;
end; $$;

comment on function public.rpc_admin_list_category_rules(uuid) is
    'A-CAT AR-2 | Admin list of all rule versions (active + staged) for a category.';


-- AR-3: rpc_admin_get_sku_coverage
create or replace function public.rpc_admin_get_sku_coverage()
returns table (
    tsp_sku_id          uuid,
    sku_code            text,
    breed_group         text,
    sex                 text,
    age_group           text,
    weight_category     text,
    grade_code          text,
    map_id              uuid,
    category_id         uuid,
    category_code       text,
    category_name_ru    text
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin role required' using errcode = 'P0001';
    end if;
    return query
    select
        s.id, s.sku_code, s.breed_group, s.sex, s.age_group,
        s.weight_category, g.code,
        m.id, m.category_id, lc.code, lc.name_ru
      from public.tsp_skus s
      left join public.grade_standards g on g.id = s.grade_id
      left join public.tsp_sku_category_map m
        on m.tsp_sku_id = s.id and m.is_active = true
      left join public.livestock_categories lc on lc.id = m.category_id
     where s.is_active = true
     order by s.sort_order, s.sku_code;
end; $$;

comment on function public.rpc_admin_get_sku_coverage() is
    'A-CAT AR-3 | Admin 30-SKU × current mapping projection for A-CAT-03 screen.
     NULL category_id ⇒ SKU not yet mapped (red plate in UI).';


-- AR-4: rpc_admin_list_prices
create or replace function public.rpc_admin_list_prices(
    p_kind text
)
returns table (
    id                  uuid,
    category_id         uuid,
    category_code       text,
    category_name_ru    text,
    region_id           uuid,
    region_name_ru      text,
    price_per_kg        int,
    valid_from          date,
    valid_to            date,
    is_active           boolean,
    approved_by         uuid,
    approved_at         timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin role required' using errcode = 'P0001';
    end if;
    if p_kind not in ('minimum', 'reference') then
        raise exception 'INVALID_INPUT: p_kind must be minimum or reference'
            using errcode = 'P0001';
    end if;

    if p_kind = 'minimum' then
        return query
        select mp.id, mp.category_id, lc.code, lc.name_ru,
               mp.region_id, r.name_ru, mp.price_per_kg,
               mp.valid_from, mp.valid_to, mp.is_active,
               mp.approved_by, mp.approved_at
          from public.minimum_prices mp
          join public.livestock_categories lc on lc.id = mp.category_id
          left join public.regions r on r.id = mp.region_id
         where mp.is_active = true
         order by lc.code, r.name_ru nulls first, mp.valid_from desc;
    else
        return query
        select rp.id, rp.category_id, lc.code, lc.name_ru,
               rp.region_id, r.name_ru, rp.price_per_kg,
               rp.valid_from, rp.valid_to, rp.is_active,
               rp.approved_by, rp.approved_at
          from public.reference_prices rp
          join public.livestock_categories lc on lc.id = rp.category_id
          left join public.regions r on r.id = rp.region_id
         where rp.is_active = true
         order by lc.code, r.name_ru nulls first, rp.valid_from desc;
    end if;
end; $$;

comment on function public.rpc_admin_list_prices(text) is
    'A-CAT AR-4 | Admin list of active prices (minimum | reference) for A-CAT-04 screen.
     region_name_ru NULL ⇒ national row.';


-- ============================================================
-- SECTION 8 REGISTRY (M4 + M6 RPCs)
-- ============================================================
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_create_pool',           'rpc_create_pool',           null, 'd02_tsp.sql (Section 8 / M4+M6)', 'M4 §2.4 + D-M6-13: create Pool + N pool_lines + M pool_regions'),
    ('rpc_publish_pool',          'rpc_publish_pool',          null, 'd02_tsp.sql (Section 8 / M4+M6)', 'M4 §2.4: pools draft -> filling; calls rpc_retry_match_pool inline'),
    ('rpc_retry_match_pool',      'rpc_retry_match_pool',      null, 'd02_tsp.sql (Section 8 / M4+M6)', 'Q-TSP-RETRY-MATCH / BT-05: scan published batches, broadcast Offers to pool MPK; idempotent'),
    ('rpc_accept_offer',          'rpc_accept_offer',          null, 'd02_tsp.sql (Section 8 / M4+M6)', 'M4 §2.3 + §5: FCFS accept; withdraw siblings; batch -> matched'),
    ('rpc_reject_offer',          'rpc_reject_offer',          null, 'd02_tsp.sql (Section 8 / M4+M6)', 'M4 §2.3: offer -> rejected'),
    ('rpc_lower_batch_price',     'rpc_lower_batch_price',     null, 'd02_tsp.sql (Section 8 / M4+M6)', 'M4 §2.6 + D-M6-3: clamp to floor, re-broadcast offers'),
    ('rpc_confirm_dispatch',      'rpc_confirm_dispatch',      null, 'd02_tsp.sql (Section 8 / M4+M6)', 'D-M6-10: batch confirmed -> dispatched (farmer)'),
    ('rpc_confirm_delivery',      'rpc_confirm_delivery',      null, 'd02_tsp.sql (Section 8 / M4+M6)', 'D-M6-10: batch dispatched -> delivered (MPK)'),
    ('rpc_submit_deal_review',    'rpc_submit_deal_review',    null, 'd02_tsp.sql (Section 8 / M4+M6)', 'D-M6-11 + D-M6-12: mutual deal review with double-blind reveal'),
    ('rpc_pool_return_batches',   'rpc_pool_return_batches',   null, 'd02_tsp.sql (Section 8 / M4+M6)', 'D-TSP-10: awaiting_mpk_decision -> closed_unfilled; matched -> published'),
    ('rpc_pool_accept_partial',   'rpc_pool_accept_partial',   null, 'd02_tsp.sql (Section 8 / M4+M6)', 'D-TSP-10: awaiting_mpk_decision -> closed_partial; matched -> confirmed'),
    ('rpc_get_reference_price',   'rpc_get_reference_price',   null, 'd02_tsp.sql (Section 8 / M4+M6)', 'M4 §1.1: indicative price + mandatory disclaimer (Art.171)'),
    ('rpc_get_minimum_price',     'rpc_get_minimum_price',     null, 'd02_tsp.sql (Section 8 / M4+M6)', 'M4 §1.1 + D-M6-3: floor price + mandatory disclaimer (Art.171)'),
    ('rpc_cancel_pool',           'rpc_cancel_pool',           null, 'd02_tsp.sql (Section 8 / M4+M6 addendum)', 'Microstep4 §4.1 / Microstep6 §4f step 8a: filling -> cancelled (MPK)'),
    -- A-CAT admin RPCs (D-TSP-CATEGORY-BRIDGE, 2026-06-15) — closes Q-TSP-CATEGORY-CLASSIFIER
    ('rpc_admin_upsert_livestock_category',     'A-CAT AC-1', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin upsert livestock_categories by code'),
    ('rpc_admin_deactivate_livestock_category', 'A-CAT AC-2', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin deactivate category; blocks on active SKU map / prices'),
    ('rpc_admin_set_category_rule',             'A-CAT AC-3', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin stage livestock_category_rules row (inactive)'),
    ('rpc_admin_activate_rule_version',         'A-CAT AC-4', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin atomic switch of active rule version per category'),
    ('rpc_admin_map_sku_to_category',           'A-CAT AC-5', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin atomic re-map of tsp_sku → livestock_category (versioned)'),
    ('rpc_admin_set_minimum_price',             'A-CAT AC-6', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin set/refresh protective floor (versioned, Art.171 standard)'),
    ('rpc_admin_set_reference_price',           'A-CAT AC-7', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin set/refresh indicative price (versioned, Art.171 disclaimer)'),
    ('rpc_admin_list_categories_with_stats',    'A-CAT AR-1', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin list categories + rule_count + sku_count + price flags'),
    ('rpc_admin_list_category_rules',           'A-CAT AR-2', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin list all rule versions for a category'),
    ('rpc_admin_get_sku_coverage',              'A-CAT AR-3', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin 30-SKU × current mapping projection (for A-CAT-03)'),
    ('rpc_admin_list_prices',                   'A-CAT AR-4', null, 'd02_tsp.sql (Section 8a / A-CAT)', 'Admin list active minimum_prices | reference_prices (for A-CAT-04)')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name,
        notes     = excluded.notes,
        created_in = excluded.created_in;

-- ============================================================
-- END SECTION 8 (M4 + M6 RPC IMPLEMENTATIONS)
-- ============================================================

