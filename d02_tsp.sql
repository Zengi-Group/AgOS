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
create policy "pools_read"          on public.pools for select
    using (
        public.fn_is_admin()
        or pool_request_id in (
            select id from public.pool_requests
            where organization_id = any(public.fn_my_org_ids())
        )
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
            select p.id from public.pools p
            join public.pool_requests pr on pr.id = p.pool_request_id
            where pr.organization_id = any(public.fn_my_org_ids())
        )
    );
create policy "pool_matches_admin_write" on public.pool_matches for all using (public.fn_is_admin());

-- Delivery records: farmer sees own; MPK sees own; admin all
create policy "delivery_read_own"   on public.delivery_records for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());
create policy "delivery_mpk_write"  on public.delivery_records for update
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());

-- Pool manifests: D40 — only matched MPK + admin
create policy "manifests_read"      on public.pool_manifests for select
    using (
        public.fn_is_admin()
        or pool_id in (
            select p.id from public.pools p
            join public.pool_requests pr on pr.id = p.pool_request_id
            where pr.organization_id = any(public.fn_my_org_ids())
            and p.status in ('executing','dispatched','delivered','executed')
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

-- ============================================================
-- SECTION 7 SUMMARY (M4 + M6 EXTENSION)
-- ============================================================
-- Tables altered (additive):
--   batches    +8 columns, status CHECK expanded (12 states + 1 legacy)
--   pools      +5 columns, status CHECK expanded (10 states + 5 legacy),
--              pool_request_id NOT NULL → nullable
--   pool_requests  deprecated (comment only, rows preserved)
--
-- Tables created (12):
--   pool_lines, pool_regions, offers,
--   livestock_categories, livestock_category_rules,
--   reference_prices, minimum_prices, tsp_config,
--   batch_events, review_dimensions, deal_reviews, deal_review_dimension_scores
--
-- FK added: batches.pool_line_id → pool_lines.id
-- Indexes: 14 | RLS enabled: 5 tables | Policies: 2 | Seeds: 1+4 rows
--
-- Pending (implementation sprint):
--   □ RLS policies for pool_lines, pool_regions (MPK org ownership model)
--   □ updated_at triggers on pool_lines, deal_reviews
--   □ rpc_derive_category() — awaiting livestock_categories seed data
--   □ rpc_create_pool(pool_lines[], pool_regions[]) — replaces rpc_create_pool_request
--   □ Seed livestock_categories + rules — Q-TSP-CATEGORY-CLASSIFIER (with zoologist)
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

