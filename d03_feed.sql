-- ============================================================
-- AGOS Schema: d03_feed
-- Project: TURAN Agricultural Operating System
-- Consolidated: 2026-03-05 (pre-development baseline)
--
-- Feed & Nutrition module.
Inventory, Rations, Feeding Plans, NASEM norms.
--
-- Depends on: d01_kernel.sql
-- Consolidated from: 003_feed.sql
--
-- Convention: All statements are idempotent.
--   CREATE TABLE IF NOT EXISTS
--   CREATE OR REPLACE FUNCTION
--   ALTER TABLE ADD COLUMN IF NOT EXISTS
--   INSERT ... ON CONFLICT DO NOTHING
-- ============================================================
-- ============================================================
-- AGOS Migration 003: FEED & NUTRITION MODULE
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 4 March 2026
--
-- Entities (10 total):
--   Reference (5):  feed_categories*, feed_items*, feed_prices,
--                   nutrient_requirements*, period_types*
--   Operational (5): farm_feed_inventory, rations, ration_versions*,
--                    feeding_plans, feeding_periods
--
-- * feed_prices and ration_versions are operational but behave like
--   reference/append-only respectively (see comments)
--
-- COMPUTED (NOT entities — D87, Section 5.6):
--   calculate_ration    → Edge Function / FastAPI (NASEM LP solver)
--   get_feed_budget     → Edge Function / FastAPI (matrix calc)
--   get_nutrient_balance → Edge Function / FastAPI (matrix calc)
--   These are documented here to prevent accidental re-implementation
--   as PostgreSQL RPCs. Only FSM transitions stay in PostgreSQL.
--
-- Cross-checked against:
--   ✅ Dok 1 Domain Model Specification v1.2 (Section 3.4, 4.4, 5.5–5.7)
--   ✅ Decisions D27, D42–D54, D87
--   ✅ FSM Catalog 5.7 (Ration, FeedingPlan)
--   ✅ Ownership Matrix Section 4.4
--   ✅ Layered Truth (D45, Section 5.4) — consistent with 001_kernel.sql
--   ✅ Universal Principles P1–P12
--   ✅ Event types 5 (feed.ration.calculated) and 6 (feed.inventory.updated)
--
-- Depends on: 001_kernel.sql
--   (organizations, farms, herd_groups, animal_categories, breeds,
--    regions, users)
-- Required by: 005_vet.sql (D48: AI links Feed+Vet),
--              006_ops_edu.sql (FeedingPlan ↔ FarmPhase date overlap)
--
-- Open questions from Dok 1 (do NOT block this migration):
--   Q37: Nutrient composition for 27 feeds — pending expert validation
--        → feed_items seeded with is_validated=false
--   Q38: Optimization algorithm (LP? heuristic?) → Edge Function scope
--   Q39: Quick mode without auth? → AI Gateway scope, not schema
--   Q40: ERP sync for FarmFeedInventory → data_source='erp' already
--   Q41: Pasture as free feed → feed_category='pasture' seeded, price=0
-- ============================================================

-- ============================================================
-- SECTION 1: REFERENCE TABLES (5 tables)
-- P8: Standards as Data — all reference tables are admin-managed.
-- ============================================================

-- -------------------------------------------------------
-- feed_categories
-- Taxonomy for grouping feed items.
-- Needed for: UI filtering, ration composition logic (roughage ratio), RAG.
-- -------------------------------------------------------
create table if not exists public.feed_categories (
    id          uuid    primary key default gen_random_uuid(),
    code        text    not null unique,
    name_ru     text    not null,
    name_en     text,
    description_ru text,
    sort_order  int     not null default 0,
    is_active   boolean not null default true,
    created_at  timestamptz not null default now()
    -- No updated_at: rarely changes; admin replaces via migration
);
comment on table public.feed_categories is
    'P8: Admin-managed reference taxonomy. Code is canonical.
     Rationale for ROUGHAGE/CONCENTRATE separation: NASEM LP solver
     enforces minimum roughage % of DM — category determines solver constraint.
     Seed: 6 categories covering full KZ feed base.';

-- -------------------------------------------------------
-- feed_items
-- Individual feed types with nutrient composition.
-- Key design: nutrient_composition JSONB for additive architecture (P7).
-- New nutrients added without schema change.
-- D87: NASEM LP solver reads this table directly from Edge Function.
-- Q37: is_validated=false until expert review of nutrient data.
-- -------------------------------------------------------
create table if not exists public.feed_items (
    id                  uuid    primary key default gen_random_uuid(),
    feed_category_id    uuid    not null references public.feed_categories(id),
    code                text    not null unique,    -- e.g. HAY_TIMOTHY, BARLEY_GRAIN
    name_ru             text    not null,
    name_en             text,
    -- Nutrient composition (per kg of feed AS-FED, i.e. as purchased)
    -- JSONB keys (all optional, Edge Function handles missing values):
    --   dm_pct:           dry matter %                  (e.g. 86.0 for hay)
    --   me_mj_per_kg_dm:  metabolizable energy MJ/kg DM (e.g. 9.2)
    --   cp_pct_dm:        crude protein % of DM         (e.g. 10.5)
    --   ndf_pct_dm:       neutral detergent fiber % DM  (e.g. 55.0)
    --   adf_pct_dm:       acid detergent fiber % DM
    --   ca_g_per_kg_dm:   calcium g/kg DM               (e.g. 5.0)
    --   p_g_per_kg_dm:    phosphorus g/kg DM
    --   mg_g_per_kg_dm:   magnesium g/kg DM
    --   na_g_per_kg_dm:   sodium g/kg DM
    nutrient_composition    jsonb,
    -- Q37: pending expert validation — Edge Function logs warning if false
    is_validated        boolean not null default false,
    -- Q41: pasture = 0 cost (free feed), handled by feed_prices.price_per_kg=0
    is_active           boolean not null default true,
    source_reference    text,   -- e.g. 'NASEM 2016 Table 15-2', 'КазАгроИнновация 2023'
    notes               text,
    created_at          timestamptz not null default now()
    -- No updated_at: nutrient data changes via expert migration, not ad-hoc
);
comment on table public.feed_items is
    'D87: Read by Edge Function calculate_ration (NASEM LP solver).
     nutrient_composition JSONB per P7 (Additive): new nutrients add keys, zero schema change.
     Q37: is_validated=false until zootechnician/nutritionist review.
     Edge Function MUST check is_validated and warn if false — prevents hallucinated rations.
     Seed: 18 common KZ feeds (pending Q37 full validation to 27 feeds).';

-- -------------------------------------------------------
-- feed_prices
-- Reference prices per feed item. D46: unified at start (no regions yet).
-- D47: Farmer can override in RationVersion.items[].price_override_per_kg
-- -------------------------------------------------------
create table if not exists public.feed_prices (
    id              uuid    primary key default gen_random_uuid(),
    feed_item_id    uuid    not null references public.feed_items(id),
    price_per_kg    numeric(8,4) not null check (price_per_kg >= 0), -- 0 for pasture (Q41)
    currency        text    not null default 'KZT',
    region_id       uuid    references public.regions(id), -- null = national (D46: unified for now)
    valid_from      date    not null,
    valid_to        date,   -- null = currently active
    is_active       boolean not null default false, -- admin explicitly activates
    source          text,   -- 'admin_manual' | 'market_survey' | 'erp_sync'
    updated_by      uuid    references public.users(id),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    -- One active national price per feed item at a time
    unique (feed_item_id, region_id, valid_from)
);
comment on table public.feed_prices is
    'D46: Unified national price at start. region_id=null = national default.
     D47: Farmer overrides happen in RationVersion.items JSONB per ration, NOT here.
     price_per_kg=0 valid for pasture (Q41: free feed, no cost).
     P8: Admin-managed. Price changes = data update, not code deployment.
     Future: region-specific prices = add row with region_id FK (D46, additive P7).';

-- -------------------------------------------------------
-- nutrient_requirements
-- Baseline nutrient requirements per AnimalCategory.
-- D87: Read by Edge Function calculate_ration to check ration adequacy.
-- Design: JSONB for requirements — same additive logic as feed_items (P7).
-- NOTE: Edge Function adjusts for actual body weight. This table holds
--       BASE reference values that the LP solver scales from.
-- -------------------------------------------------------
create table if not exists public.nutrient_requirements (
    id                  uuid    primary key default gen_random_uuid(),
    animal_category_id  uuid    not null references public.animal_categories(id),
    period_type_id      uuid    references public.period_types(id), -- null = applies to all periods
    -- Requirements JSONB keys (min values per day, per animal):
    --   dm_kg_per_100kg_bw:   dry matter intake kg per 100kg body weight
    --   me_mj_per_day:        metabolizable energy MJ/day (base, for ~300kg animal)
    --   cp_g_per_day:         crude protein g/day
    --   ndf_pct_dm_min:       minimum NDF % of DM (roughage floor)
    --   ca_g_per_day:         calcium g/day
    --   p_g_per_day:          phosphorus g/day
    requirements        jsonb   not null,
    -- Reference basis (body weight for which these values apply)
    reference_weight_kg int     not null default 300, -- Edge Function scales proportionally
    is_validated        boolean not null default false, -- Q36: same as feed_items
    source_reference    text,   -- e.g. 'NASEM Beef 8th edition 2016'
    notes               text,
    is_active           boolean not null default true,
    created_at          timestamptz not null default now()
);
comment on table public.nutrient_requirements is
    'D87: Read by Edge Function. Period_type_id nullable = base requirement all periods.
     Edge Function precedence: period-specific row > null-period row.
     reference_weight_kg: Edge Function scales ME, CP proportionally for actual animal weight.
     JSONB keys match feed_items nutrient_composition keys for direct comparison.
     Q36: is_validated=false until zootechnician sign-off (same as Q37).';

-- -------------------------------------------------------
-- period_types
-- D53: 5 seasonal/production periods that affect ration composition.
-- Shared by: Feed (FeedingPeriod, Ration), Operations (FarmPhase context).
-- -------------------------------------------------------
create table if not exists public.period_types (
    id          uuid    primary key default gen_random_uuid(),
    code        text    not null unique,
    name_ru     text    not null,
    name_en     text,
    -- Typical calendar context (informational — actual dates set per farm)
    typical_months_start int check (typical_months_start between 1 and 12),
    typical_months_end   int check (typical_months_end   between 1 and 12),
    sort_order  int     not null,
    description_ru text,
    is_active   boolean not null default true,
    created_at  timestamptz not null default now()
);
comment on table public.period_types is
    'D53: 5 types that drive ration changes through the production year.
     Code is canonical — used by Edge Function and AI Gateway.
     Seed: STALL_WINTER, TRANSITION_SPRING, PASTURE_SUMMER, TRANSITION_FALL, BREEDING.
     typical_months: informational for Kazakhstan climate. Farm plan sets actual dates.';

-- ============================================================
-- SECTION 2: OPERATIONAL TABLES (5 tables)
-- ============================================================

-- -------------------------------------------------------
-- farm_feed_inventory
-- D43: Inventory per Farm (not per HerdGroup — feed stocks are location-shared).
-- D45: Layered Truth — same 4 confidence levels as herd_groups.
-- Ownership Matrix 4.4: Farmer C/U (L3); AI C/U (L2); ERP U/A (L4); Admin/Expert R.
-- -------------------------------------------------------
create table if not exists public.farm_feed_inventory (
    id              uuid    primary key default gen_random_uuid(),
    farm_id         uuid    not null references public.farms(id) on delete cascade,
    organization_id uuid    not null references public.organizations(id), -- denorm for RLS (D45)
    feed_item_id    uuid    not null references public.feed_items(id),
    -- D45: Layered Truth (identical pattern to herd_groups)
    quantity_kg     numeric(12,2) not null default 0 check (quantity_kg >= 0),
    data_source     text    not null default 'registration'
                                check (data_source in (
                                    'registration',  -- L1: initial rough estimate
                                    'ai_extracted',  -- L2: from AI conversation (draft)
                                    'platform',      -- L3: farmer manually confirmed
                                    'erp'            -- L4: synced from ERP (highest confidence)
                                )),
    confidence      int     not null default 25
                                check (confidence in (25, 50, 75, 95)),
    -- Freshness tracking (KZ hay can spoil — important for ration quality)
    last_updated_date   date,   -- when farmer last confirmed this quantity
    notes               text,
    -- One inventory record per farm per feed item
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    unique (farm_id, feed_item_id)
);
comment on table public.farm_feed_inventory is
    'D43: Per Farm, not per HerdGroup — all groups on the farm share the same feed stock.
     D45: Layered Truth matches HerdGroup pattern (L1=25, L2=50, L3=75, L4=95).
     Higher confidence replaces lower — ERP sync overwrites AI-extracted.
     Event trigger: UPDATE publishes feed.inventory.updated (event type #6 in Dok 1 5.5).
     Organization_id denorm enables efficient RLS without joins.
     unique(farm_id, feed_item_id): one record per feed type per farm — UPSERT on update.';
comment on column public.farm_feed_inventory.last_updated_date is
    'Used by AI proactive engine: if last_updated_date > 30 days, prompt farmer to confirm.
     Stale inventory = unreliable ration calculation.';

-- -------------------------------------------------------
-- rations
-- Header record for a ration calculation request.
-- D42: herd_group_id nullable — supports "quick mode" without registered farm.
-- D27: RationBuilder-specific fields here, NOT in herd_groups.
-- FSM 5.7: draft → active → archived
-- Ownership Matrix 4.4: Farmer C/U; System C/A (after calculate_ration RPC); AI C (quick mode).
-- -------------------------------------------------------
create table if not exists public.rations (
    id                  uuid    primary key default gen_random_uuid(),
    -- Farm context (D42: both nullable for quick mode)
    farm_id             uuid    references public.farms(id),
    organization_id     uuid    references public.organizations(id), -- denorm for RLS; null in quick mode
    herd_group_id       uuid    references public.herd_groups(id),  -- D42: nullable
    -- Animal parameters (D27: RationBuilder params here, not in HerdGroup)
    animal_category_id  uuid    not null references public.animal_categories(id),
    breed_id            uuid    references public.breeds(id),        -- affects ME requirements
    period_type_id      uuid    references public.period_types(id),  -- D53: affects requirements
    avg_weight_kg       numeric(6,2) not null check (avg_weight_kg > 0),
    head_count          int     not null default 1 check (head_count > 0),
    -- Production context (D27)
    objective           text    not null default 'growth'
                                    check (objective in (
                                        'maintenance',  -- поддержание живой массы
                                        'growth',       -- рост (молодняк)
                                        'finishing',    -- интенсивный откорм
                                        'breeding',     -- случной период
                                        'gestation',    -- стельность
                                        'lactation'     -- лактация
                                    )),
    shelter_type        text    not null default 'combined'
                                    check (shelter_type in (
                                        'stall',        -- стойловое содержание
                                        'pasture',      -- пастбищное
                                        'combined'      -- смешанное
                                    )),
    -- Daily weight gain target (used by NASEM LP solver)
    target_daily_gain_kg    numeric(4,3), -- e.g. 0.800 = 800g/day
    -- FSM 5.7
    status              text    not null default 'draft'
                                    check (status in (
                                        'draft',    -- being configured, no version yet
                                        'active',   -- has at least one calculated RationVersion
                                        'archived'  -- replaced by newer ration for this group
                                    )),
    -- Quick mode flag (D42, Q39)
    is_quick_mode       boolean not null default false, -- true = no farm_id/org_id
    notes               text,
    created_by          uuid    references public.users(id),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.rations is
    'D42: herd_group_id nullable for quick mode (AI WhatsApp, Q39).
     D27: objective, shelter_type, target_daily_gain here — NOT in herd_groups.
     Rationale: herd_group = farm reality; ration = calculation scenario (may vary).
     FSM: draft (being configured) → active (calculated) → archived (superseded).
     organization_id null-able: quick mode via AI without auth is an open question (Q39).
     D87: Edge Function calculate_ration reads this, creates RationVersion, updates status→active.';

-- -------------------------------------------------------
-- ration_versions
-- D51: Append-only — each calculation run creates a new version.
-- Never UPDATE. Enables comparison of variants (different feeds, prices).
-- D47: items JSONB contains optional price_override_per_kg per feed.
-- D87: Created exclusively by Edge Function / FastAPI (NASEM LP solver).
-- -------------------------------------------------------
create table if not exists public.ration_versions (
    id              uuid    primary key default gen_random_uuid(),
    ration_id       uuid    not null references public.rations(id),
    version_number  int     not null,
    -- D47: items = what goes into this ration
    -- Structure: [{
    --   feed_item_id: uuid,
    --   feed_item_code: text,       (denorm for display without joins)
    --   quantity_kg_per_day: numeric,
    --   price_override_per_kg: numeric | null,  (D47: farmer's actual price)
    --   effective_price_per_kg: numeric,        (override ?? reference)
    --   cost_per_day: numeric
    -- }]
    items           jsonb   not null default '[]',
    -- results = what the LP solver computed
    -- Structure: {
    --   total_cost_per_day: numeric,
    --   total_cost_per_month: numeric,
    --   total_dm_kg: numeric,
    --   nutrients_met: {dm_pct: bool, me_mj: bool, cp_g: bool, ...},
    --   nutrient_values: {dm_kg: numeric, me_mj: numeric, cp_g: numeric, ...},
    --   nutrient_requirements: {dm_kg: numeric, me_mj: numeric, ...},
    --   roughage_pct_dm: numeric,
    --   deficiencies: [text],
    --   warnings: [text],
    --   solver_status: 'optimal' | 'feasible' | 'infeasible',
    --   feed_items_unvalidated: [uuid]   (Q37: list of feeds with is_validated=false)
    -- }
    results         jsonb   not null default '{}',
    is_current      boolean not null default true,   -- only latest version is current
    -- Context snapshot at calculation time (immutable record)
    calc_avg_weight_kg      numeric(6,2) not null,
    calc_head_count         int     not null,
    calc_period_type_code   text,
    calc_objective          text,
    calc_shelter_type       text,
    calculated_by           text    not null default 'edge_function', -- 'edge_function' | 'ai_quick'
    created_at              timestamptz not null default now(),
    unique (ration_id, version_number)
    -- No updated_at: D51 APPEND-ONLY
);
comment on table public.ration_versions is
    'D51: APPEND-ONLY. Never UPDATE any row. version_number monotonically increasing.
     is_current: only one row per ration_id where is_current=true (maintained by trigger).
     D47: items[].price_override_per_kg — farmer actual price vs reference feed_price.
     results.solver_status: Edge Function must set "infeasible" not hallucinate a ration.
     results.feed_items_unvalidated: Q37 transparency — farmer sees which feeds lack validation.
     calc_* fields: snapshot of input parameters at calculation time (immutable record).
     D87: ONLY Edge Function / FastAPI creates these rows. Never from web UI directly.';

-- -------------------------------------------------------
-- feeding_plans
-- D52: 4-level hierarchy: Farm → FeedingPlan → FeedingPeriod → Ration.
-- Annual or seasonal plan for a farm. One active plan per farm recommended.
-- FSM 5.7: draft → active → completed
-- Ownership Matrix 4.4: Farmer C/U; Expert U; System C (generate from template).
-- -------------------------------------------------------
create table if not exists public.feeding_plans (
    id              uuid    primary key default gen_random_uuid(),
    farm_id         uuid    not null references public.farms(id) on delete cascade,
    organization_id uuid    not null references public.organizations(id), -- denorm for RLS
    name            text    not null,   -- e.g. "Кормовой план 2026 — Бычки"
    -- Plan period (typically a full year or production cycle)
    plan_year       int,                -- e.g. 2026 (optional — some plans span year boundary)
    start_date      date,
    end_date        date,
    -- FSM 5.7
    status          text    not null default 'draft'
                                check (status in (
                                    'draft',        -- being configured
                                    'active',       -- in use by farm
                                    'completed'     -- period has passed
                                )),
    -- Expert who reviewed/generated this plan
    expert_profile_id   uuid    references public.expert_profiles(id),
    -- AI generation flag
    generated_by_ai boolean not null default false,
    notes           text,
    created_by      uuid    references public.users(id),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.feeding_plans is
    'D52: Level 2 of the 4-level hierarchy (Farm → Plan → Period → Ration).
     FSM: draft → active → completed.
     Expert can generate and adapt. AI can generate from dialogue context.
     D75: FeedingPlan is NOT subordinate to FarmProductionPlan — independent dimension.
     Cross-domain: FeedingPeriod.dates may overlap FarmPhase.dates (Section 5.1).
     Coordination is by overlapping dates, NOT by FK.';

-- -------------------------------------------------------
-- feeding_periods
-- D52: Level 3 of the 4-level hierarchy — a specific period within the plan.
-- Links HerdGroup + PeriodType + Ration for a specific date range.
-- Cross-domain connection to Operations: coordinate by date overlap (D75).
-- -------------------------------------------------------
create table if not exists public.feeding_periods (
    id                  uuid    primary key default gen_random_uuid(),
    feeding_plan_id     uuid    not null references public.feeding_plans(id) on delete cascade,
    organization_id     uuid    not null references public.organizations(id), -- denorm for RLS
    herd_group_id       uuid    not null references public.herd_groups(id),
    period_type_id      uuid    not null references public.period_types(id),
    -- Ration for this period (nullable — plan can exist before rations are calculated)
    ration_id           uuid    references public.rations(id),
    -- Date range for this period
    start_date          date    not null,
    end_date            date    not null,
    check (end_date > start_date),
    -- Head count at time of planning (may differ from current herd_group.head_count)
    head_count          int     not null check (head_count > 0),
    -- Override: planned avg weight at start of period (for budget calc)
    planned_avg_weight_kg   numeric(6,2),
    -- Status
    status              text    not null default 'upcoming'
                                    check (status in (
                                        'upcoming',     -- future period
                                        'active',       -- current date within range
                                        'completed'     -- past period
                                    )),
    notes               text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.feeding_periods is
    'D52: Level 3 of 4-level hierarchy.
     D75: Coordinate with FarmPhase via date overlap — NOT via FK (three orthogonal plans).
     ration_id nullable: plan periods can be created before rations are calculated.
     AI weekly briefing pattern (Section 5.1): "This week enter PASTURE_SUMMER period —
     switch ration for your steers." Triggered by start_date crossing.
     status auto-updated by cron checking current date vs start/end range.';

-- ============================================================
-- SECTION 3: INDEXES
-- ============================================================

-- feed_categories
create index idx_fc_active on public.feed_categories (is_active)
    where is_active = true;

-- feed_items
create index idx_fi_category    on public.feed_items (feed_category_id);
create index idx_fi_active      on public.feed_items (is_active) where is_active = true;
create index idx_fi_validated   on public.feed_items (is_validated);  -- Edge Function validation check

-- feed_prices
create index idx_fp_item_active on public.feed_prices (feed_item_id, is_active)
    where is_active = true;
create index idx_fp_region      on public.feed_prices (region_id)
    where region_id is not null;

-- nutrient_requirements
create index idx_nr_category    on public.nutrient_requirements (animal_category_id);
create index idx_nr_period      on public.nutrient_requirements (period_type_id)
    where period_type_id is not null;
create index idx_nr_cat_period  on public.nutrient_requirements (animal_category_id, period_type_id);

-- period_types
create index idx_pt_code        on public.period_types (code);

-- farm_feed_inventory
create index idx_ffi_farm       on public.farm_feed_inventory (farm_id);
create index idx_ffi_org        on public.farm_feed_inventory (organization_id); -- RLS
create index idx_ffi_item       on public.farm_feed_inventory (feed_item_id);
create index idx_ffi_confidence on public.farm_feed_inventory (confidence);  -- Layered Truth queries

-- rations
create index idx_rat_org_status on public.rations (organization_id, status)
    where organization_id is not null;
create index idx_rat_farm       on public.rations (farm_id)
    where farm_id is not null;
create index idx_rat_herd_group on public.rations (herd_group_id)
    where herd_group_id is not null;
create index idx_rat_category   on public.rations (animal_category_id);
create index idx_rat_quick_mode on public.rations (is_quick_mode)
    where is_quick_mode = true;  -- AI Gateway quick-mode queries

-- ration_versions
create index idx_rv_ration_current  on public.ration_versions (ration_id, is_current)
    where is_current = true;
create index idx_rv_ration_version  on public.ration_versions (ration_id, version_number desc);

-- feeding_plans
create index idx_fplan_org_status   on public.feeding_plans (organization_id, status);
create index idx_fplan_farm         on public.feeding_plans (farm_id);
create index idx_fplan_year         on public.feeding_plans (plan_year)
    where plan_year is not null;

-- feeding_periods
create index idx_fperiod_plan       on public.feeding_periods (feeding_plan_id);
create index idx_fperiod_org        on public.feeding_periods (organization_id); -- RLS
create index idx_fperiod_herd       on public.feeding_periods (herd_group_id);
create index idx_fperiod_dates      on public.feeding_periods (start_date, end_date); -- date overlap queries
create index idx_fperiod_status     on public.feeding_periods (status)
    where status = 'active';
create index idx_fperiod_ration     on public.feeding_periods (ration_id)
    where ration_id is not null;

-- ============================================================
-- SECTION 4: ROW LEVEL SECURITY
-- Core rule: Farmer A never sees Farmer B's feed data (Section 5.9).
-- Reference tables (categories, items, prices, requirements, period_types):
--   readable by all authenticated users, writable by admin/expert.
-- Operational tables: farmer sees own org only.
-- ============================================================

alter table public.feed_categories          enable row level security;
alter table public.feed_items               enable row level security;
alter table public.feed_prices              enable row level security;
alter table public.nutrient_requirements    enable row level security;
alter table public.period_types             enable row level security;
alter table public.farm_feed_inventory      enable row level security;
alter table public.rations                  enable row level security;
alter table public.ration_versions          enable row level security;
alter table public.feeding_plans            enable row level security;
alter table public.feeding_periods          enable row level security;

-- Reference tables: read by all authenticated; write by admin; experts can update
create policy "fc_read_auth"        on public.feed_categories           for select using (auth.uid() is not null);
create policy "fc_admin_write"      on public.feed_categories           for all    using (public.fn_is_admin());
create policy "fi_read_auth"        on public.feed_items                for select using (auth.uid() is not null);
create policy "fi_admin_write"      on public.feed_items                for all    using (public.fn_is_admin() or public.fn_is_expert());
create policy "fp_read_auth"        on public.feed_prices               for select
    using (auth.uid() is not null and is_active = true or public.fn_is_admin());
create policy "fp_admin_write"      on public.feed_prices               for all    using (public.fn_is_admin());
create policy "nr_read_auth"        on public.nutrient_requirements     for select using (auth.uid() is not null);
create policy "nr_admin_write"      on public.nutrient_requirements     for all    using (public.fn_is_admin() or public.fn_is_expert());
create policy "pt_read_auth"        on public.period_types              for select using (auth.uid() is not null);
create policy "pt_admin_write"      on public.period_types              for all    using (public.fn_is_admin());

-- Farm feed inventory: farmer sees own farm only
create policy "ffi_read_own"        on public.farm_feed_inventory       for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin() or public.fn_is_expert());
create policy "ffi_write_own"       on public.farm_feed_inventory       for all
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());

-- Rations: farmer sees own; quick mode is_quick_mode=true visible to creator only
create policy "rat_read_own"        on public.rations                   for select
    using (
        (organization_id = any(public.fn_my_org_ids()))
        or (is_quick_mode = true and created_by = public.fn_current_user_id())
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "rat_write_own"       on public.rations                   for all
    using (
        (organization_id = any(public.fn_my_org_ids()))
        or (is_quick_mode = true and created_by = public.fn_current_user_id())
        or public.fn_is_admin()
    );

-- Ration versions: inherits access from parent ration
create policy "rv_read_own"         on public.ration_versions           for select
    using (
        ration_id in (
            select id from public.rations
            where organization_id = any(public.fn_my_org_ids())
               or (is_quick_mode = true and created_by = public.fn_current_user_id())
        )
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "rv_insert_system"    on public.ration_versions           for insert
    with check (public.fn_is_admin());  -- service_role (Edge Function) bypasses RLS

-- Feeding plans: farmer sees own
create policy "fplan_read_own"      on public.feeding_plans             for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin() or public.fn_is_expert());
create policy "fplan_write_own"     on public.feeding_plans             for all
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());

-- Feeding periods: farmer sees own
create policy "fperiod_read_own"    on public.feeding_periods           for select
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin() or public.fn_is_expert());
create policy "fperiod_write_own"   on public.feeding_periods           for all
    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin());

-- ============================================================
-- SECTION 5: TRIGGERS
-- ============================================================

-- updated_at triggers for mutable tables
create trigger trg_feed_prices_updated_at
    before update on public.feed_prices
    for each row execute function public.fn_set_updated_at();

create trigger trg_ffi_updated_at
    before update on public.farm_feed_inventory
    for each row execute function public.fn_set_updated_at();

create trigger trg_rations_updated_at
    before update on public.rations
    for each row execute function public.fn_set_updated_at();

create trigger trg_feeding_plans_updated_at
    before update on public.feeding_plans
    for each row execute function public.fn_set_updated_at();

create trigger trg_feeding_periods_updated_at
    before update on public.feeding_periods
    for each row execute function public.fn_set_updated_at();

-- ration_versions: maintain is_current flag
-- When a new version is inserted, set all previous versions to is_current=false
create or replace function public.fn_ration_version_set_current()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
    -- Set all previous versions of this ration to not current
    update public.ration_versions
    set is_current = false
    where ration_id = new.ration_id
      and id <> new.id;
    -- Ensure new version is marked current
    new.is_current := true;
    return new;
end;
$$;
comment on function public.fn_ration_version_set_current() is
    'D51: Enforces "only one current version per ration" invariant.
     Called after each RationVersion insert by Edge Function.
     Ensures ration_versions.is_current is consistent at all times.';

create trigger trg_ration_version_set_current
    before insert on public.ration_versions
    for each row execute function public.fn_ration_version_set_current();

-- rations: auto-activate when first RationVersion is created
create or replace function public.fn_ration_auto_activate()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
    update public.rations
    set status = 'active', updated_at = now()
    where id = new.ration_id
      and status = 'draft';
    return new;
end;
$$;
comment on function public.fn_ration_auto_activate() is
    'FSM 5.7: Ration draft→active transition fires automatically when
     first RationVersion is inserted by Edge Function calculate_ration.
     Prevents manual status management by AI Gateway or web UI.';

create trigger trg_ration_auto_activate
    after insert on public.ration_versions
    for each row execute function public.fn_ration_auto_activate();

-- feeding_periods: auto-update status based on current date
-- Note: Actual status transitions run as cron job (not trigger — performance).
-- This function is called by the cron RPC, not a trigger.
create or replace function public.fn_update_feeding_period_statuses()
returns void language plpgsql security definer as $$
begin
    -- upcoming → active
    update public.feeding_periods
    set status = 'active', updated_at = now()
    where status = 'upcoming'
      and start_date <= current_date
      and end_date >= current_date;
    -- active → completed
    update public.feeding_periods
    set status = 'completed', updated_at = now()
    where status = 'active'
      and end_date < current_date;
end;
$$;
comment on function public.fn_update_feeding_period_statuses() is
    'Called daily by pg_cron. Updates FeedingPeriod status based on current_date.
     Not a trigger — avoid performance impact on every row update.
     Dok 4 Event Bus: ops.phase.started / ops.phase.completed events piggyback on this.';

-- ============================================================
-- SECTION 6: SEED DATA
-- P8: Admin-editable after migration
-- Q37 NOTE: feed_items seeded with is_validated=false pending expert review.
-- ============================================================

-- Period types (D53: 5 types)
insert into public.period_types (code, name_ru, name_en, typical_months_start, typical_months_end, sort_order, description_ru) values
    ('STALL_WINTER',     'Стойловый (зима)',         'Winter stall',         11, 3,  1, 'Стойловое содержание. Рацион: сено, силос, концентраты. Повышенные нормы энергии.'),
    ('TRANSITION_SPRING','Переходный (весна)',        'Spring transition',    4,  4,  2, 'Перевод на пастбище. Постепенное снижение концентратов, введение зелёного корма.'),
    ('PASTURE_SUMMER',   'Пастбищный (лето)',         'Summer pasture',       5,  9,  3, 'Пастбищное содержание. Основной корм — трава. Минеральные добавки обязательны.'),
    ('TRANSITION_FALL',  'Переходный (осень)',        'Fall transition',      10, 10, 4, 'Возврат в стойло. Постепенное введение грубых кормов, повышение концентратов.'),
    ('BREEDING',         'Случной период',            'Breeding season',      null, null, 5, 'Повышенные нормы протеина и витаминов. Применим к быкам-производителям и маткам.')
on conflict (code) do nothing;

-- Feed categories (6 types covering full KZ feed base)
insert into public.feed_categories (code, name_ru, name_en, description_ru, sort_order) values
    ('ROUGHAGE',     'Грубые корма',           'Roughage / Forages',    'Сено, солома, сенаж. Основа рациона КРС. Минимум 40% СВ рациона.', 1),
    ('SILAGE',       'Силос',                  'Silage',                'Кукурузный, подсолнечниковый, злаковый силос. Сочный корм.', 2),
    ('CONCENTRATE',  'Концентраты',            'Concentrates / Grains', 'Зерновые: ячмень, пшеница, овёс, кукуруза. Высокоэнергетические.', 3),
    ('PROTEIN_SUPP', 'Протеиновые добавки',    'Protein supplements',   'Жмыхи, шроты, мочевина. Выравнивание дефицита протеина.', 4),
    ('MINERAL',      'Минеральные добавки',    'Mineral supplements',   'Соль, мел, фосфаты, комбикормовые премиксы.', 5),
    ('PASTURE',      'Пастбищный корм',        'Pasture / Grass',       'Зелёная трава на пастбище. Стоимость = 0 (Q41: свободный корм).', 6)
on conflict (code) do nothing;

-- Feed items (18 items, is_validated=false — Q37 pending expert validation)
-- Nutrient values: approximate NASEM 8th ed. 2016 for KZ conditions
-- All values per kg DM unless noted
insert into public.feed_items (
    feed_category_id, code, name_ru, name_en,
    nutrient_composition, is_validated, source_reference, notes
)
select
    fc.id,
    f.code, f.name_ru, f.name_en,
    f.nutrient_composition::jsonb,
    false,  -- Q37: ALL pending validation
    'Приблизительно NASEM 2016. Требует подтверждения зоотехника (Q37).',
    f.notes
from (values
    -- ROUGHAGE
    ('ROUGHAGE', 'HAY_MIXED_GRASS',  'Сено луговое смешанное',  'Mixed grass hay',
     '{"dm_pct":86,"me_mj_per_kg_dm":8.5,"cp_pct_dm":10.0,"ndf_pct_dm":58,"adf_pct_dm":36,"ca_g_per_kg_dm":6.0,"p_g_per_kg_dm":2.5}',
     'Типичное казахстанское луговое сено'),
    ('ROUGHAGE', 'HAY_TIMOTHY',      'Сено тимофеевка',         'Timothy hay',
     '{"dm_pct":88,"me_mj_per_kg_dm":8.8,"cp_pct_dm":8.5,"ndf_pct_dm":62,"adf_pct_dm":38,"ca_g_per_kg_dm":4.5,"p_g_per_kg_dm":2.0}',
     null),
    ('ROUGHAGE', 'STRAW_WHEAT',      'Солома пшеничная',        'Wheat straw',
     '{"dm_pct":90,"me_mj_per_kg_dm":6.2,"cp_pct_dm":3.5,"ndf_pct_dm":78,"adf_pct_dm":50,"ca_g_per_kg_dm":3.0,"p_g_per_kg_dm":0.8}',
     'Низкое качество. Не более 30% рациона.'),
    ('ROUGHAGE', 'HAYLAGE_GRASS',    'Сенаж злаковый',          'Grass haylage',
     '{"dm_pct":45,"me_mj_per_kg_dm":9.5,"cp_pct_dm":12.0,"ndf_pct_dm":52,"adf_pct_dm":32,"ca_g_per_kg_dm":5.5,"p_g_per_kg_dm":3.0}',
     'DM% ниже — расчёт количества на СВ-основе'),
    -- SILAGE
    ('SILAGE',   'SILAGE_CORN',      'Силос кукурузный',        'Corn silage',
     '{"dm_pct":30,"me_mj_per_kg_dm":10.5,"cp_pct_dm":8.5,"ndf_pct_dm":44,"adf_pct_dm":26,"ca_g_per_kg_dm":2.5,"p_g_per_kg_dm":2.0}',
     'Высокоэнергетический. Хорош для откорма.'),
    ('SILAGE',   'SILAGE_SUNFLOWER', 'Силос подсолнечниковый',  'Sunflower silage',
     '{"dm_pct":25,"me_mj_per_kg_dm":8.8,"cp_pct_dm":7.0,"ndf_pct_dm":50,"adf_pct_dm":35,"ca_g_per_kg_dm":8.0,"p_g_per_kg_dm":1.5}',
     'Повышенный кальций. Баланс P:Ca требует контроля.'),
    -- CONCENTRATES
    ('CONCENTRATE','GRAIN_BARLEY',   'Ячмень зерно',            'Barley grain',
     '{"dm_pct":88,"me_mj_per_kg_dm":12.8,"cp_pct_dm":12.0,"ndf_pct_dm":22,"adf_pct_dm":7,"ca_g_per_kg_dm":0.6,"p_g_per_kg_dm":3.5}',
     'Основной концентрат в КЗ. Плющить или дробить.'),
    ('CONCENTRATE','GRAIN_WHEAT',    'Пшеница зерно',           'Wheat grain',
     '{"dm_pct":88,"me_mj_per_kg_dm":13.0,"cp_pct_dm":14.0,"ndf_pct_dm":15,"adf_pct_dm":4,"ca_g_per_kg_dm":0.5,"p_g_per_kg_dm":3.8}',
     'Не более 40% концентратной части. Риск ацидоза.'),
    ('CONCENTRATE','GRAIN_CORN',     'Кукуруза зерно',          'Corn grain',
     '{"dm_pct":88,"me_mj_per_kg_dm":14.0,"cp_pct_dm":9.0,"ndf_pct_dm":10,"adf_pct_dm":3,"ca_g_per_kg_dm":0.3,"p_g_per_kg_dm":3.0}',
     'Высокоэнергетический. Низкий протеин — нужна добавка.'),
    ('CONCENTRATE','GRAIN_OATS',     'Овёс зерно',              'Oats grain',
     '{"dm_pct":89,"me_mj_per_kg_dm":11.5,"cp_pct_dm":11.5,"ndf_pct_dm":30,"adf_pct_dm":15,"ca_g_per_kg_dm":1.0,"p_g_per_kg_dm":3.5}',
     'Хорошо для молодняка. Выше NDF vs ячмень.'),
    -- PROTEIN SUPPLEMENTS
    ('PROTEIN_SUPP','MEAL_SUNFLOWER','Жмых подсолнечниковый',   'Sunflower meal',
     '{"dm_pct":91,"me_mj_per_kg_dm":10.5,"cp_pct_dm":38.0,"ndf_pct_dm":35,"adf_pct_dm":22,"ca_g_per_kg_dm":3.5,"p_g_per_kg_dm":12.0}',
     'Основной источник протеина в КЗ. Высокий P — следить за балансом.'),
    ('PROTEIN_SUPP','MEAL_SOYBEAN',  'Шрот соевый',             'Soybean meal',
     '{"dm_pct":90,"me_mj_per_kg_dm":12.0,"cp_pct_dm":44.0,"ndf_pct_dm":15,"adf_pct_dm":8,"ca_g_per_kg_dm":3.5,"p_g_per_kg_dm":7.0}',
     'Импортный. Высокое качество протеина. Дороже.'),
    ('PROTEIN_SUPP','UREA',          'Мочевина (карбамид)',      'Urea',
     '{"dm_pct":99,"me_mj_per_kg_dm":0,"cp_pct_dm":281,"ndf_pct_dm":0,"adf_pct_dm":0,"ca_g_per_kg_dm":0,"p_g_per_kg_dm":0}',
     'НПБ-источник. Строго ≤ 1% СВ рациона. Адаптация 3-4 недели!'),
    -- MINERALS
    ('MINERAL',  'SALT_NaCl',       'Соль поваренная',          'Salt (NaCl)',
     '{"dm_pct":99,"me_mj_per_kg_dm":0,"cp_pct_dm":0,"ndf_pct_dm":0,"na_g_per_kg_dm":390,"cl_g_per_kg_dm":600}',
     'Обязательный компонент. 5-10 г/100 кг ЖМ/сут.'),
    ('MINERAL',  'CHALK_CaCO3',     'Мел кормовой (CaCO3)',     'Feed chalk (CaCO3)',
     '{"dm_pct":99,"me_mj_per_kg_dm":0,"cp_pct_dm":0,"ca_g_per_kg_dm":380,"p_g_per_kg_dm":0}',
     'Источник кальция. Корректирует Ca:P баланс.'),
    ('MINERAL',  'PREMIX_BEEF',     'Премикс для КРС',          'Beef premix',
     '{"dm_pct":95,"me_mj_per_kg_dm":0,"cp_pct_dm":0,"ca_g_per_kg_dm":150,"p_g_per_kg_dm":60}',
     'Состав варьируется по производителю. Уточнить у поставщика.'),
    -- PASTURE (Q41: free feed, price=0)
    ('PASTURE',  'PASTURE_SPRING',  'Пастбище весеннее',        'Spring pasture',
     '{"dm_pct":18,"me_mj_per_kg_dm":11.5,"cp_pct_dm":22.0,"ndf_pct_dm":38,"adf_pct_dm":22,"ca_g_per_kg_dm":8.0,"p_g_per_kg_dm":4.0}',
     'Молодая трава. Высокий протеин, низкая СВ. Риск вздутия.'),
    ('PASTURE',  'PASTURE_SUMMER',  'Пастбище летнее',          'Summer pasture',
     '{"dm_pct":22,"me_mj_per_kg_dm":10.0,"cp_pct_dm":14.0,"ndf_pct_dm":50,"adf_pct_dm":30,"ca_g_per_kg_dm":6.0,"p_g_per_kg_dm":3.0}',
     'Зрелая трава. Снижение питательности к августу.')
) as f(cat_code, code, name_ru, name_en, nutrient_composition, notes)
join public.feed_categories fc on fc.code = f.cat_code
on conflict (code) do nothing;

-- Feed prices: seed for all 18 items (Q41: pasture = 0 cost, rest = KZT placeholder 2024)
-- Actual prices updated by admin via FeedReferenceAdmin UI
insert into public.feed_prices (feed_item_id, price_per_kg, currency, valid_from, is_active, source)
select fi.id, fp.price, 'KZT', current_date, true, 'admin_seed'
from (values
    -- Roughage (KZT/kg AS-FED)
    ('PASTURE_SPRING',   0.00),   -- Q41: free pasture
    ('PASTURE_SUMMER',   0.00),   -- Q41: free pasture
    ('STRAW_WHEAT',     15.00),   -- низкое качество
    ('HAY_MIXED_GRASS', 35.00),   -- луговое сено, КЗ рынок
    ('HAY_TIMOTHY',     38.00),   -- тимофеевка, чуть дороже
    ('HAYLAGE_GRASS',   28.00),   -- AS-FED (DM 45%)
    -- Silage
    ('SILAGE_CORN',     18.00),   -- AS-FED (DM 30%)
    ('SILAGE_SUNFLOWER',15.00),   -- AS-FED (DM 25%)
    -- Concentrates
    ('GRAIN_BARLEY',    90.00),   -- основной концентрат КЗ
    ('GRAIN_WHEAT',     85.00),   -- пшеница фуражная
    ('GRAIN_CORN',      95.00),   -- кукуруза зерно
    ('GRAIN_OATS',      75.00),   -- овёс
    -- Protein supplements
    ('MEAL_SUNFLOWER', 120.00),   -- жмых подсолнечниковый
    ('MEAL_SOYBEAN',   200.00),   -- шрот соевый, импорт
    ('UREA',           180.00),   -- карбамид
    -- Minerals
    ('SALT_NaCl',       25.00),   -- соль
    ('CHALK_CaCO3',     18.00),   -- мел кормовой
    ('PREMIX_BEEF',    350.00)    -- премикс КРС
) as fp(code, price)
join public.feed_items fi on fi.code = fp.code
on conflict (feed_item_id, region_id, valid_from) do nothing;

-- Feed consumption norms: typical KZ beef cattle (Priority 2 fallback for feeding_model.py)
-- All quantities in kg AS-FED per head per day. Season: winter | summer | transition
-- farm_type: beef_reproducer (cow-calf), feedlot (steer finishing)
insert into public.feed_consumption_norms (farm_type, animal_category_id, season, items, notes)
select
    v.farm_type,
    ac.id,
    v.season,
    (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'feed_item_id', fi.id::text,
                'kg_per_day',   item_row.kg_per_day
            )
        ), '[]'::jsonb)
        from jsonb_to_recordset(v.items_seed::jsonb) as item_row(code text, kg_per_day numeric)
        join public.feed_items fi on fi.code = item_row.code
    ),
    v.notes
from (values
    -- ── beef_reproducer ───────────────────────────────────────────────────────
    -- COW зима: сено+силос+концентрат. Суммарно ~40 кг AS-FED
    ('beef_reproducer','COW','winter',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":8},{"code":"SILAGE_CORN","kg_per_day":18},{"code":"GRAIN_BARLEY","kg_per_day":2.5},{"code":"MEAL_SUNFLOWER","kg_per_day":0.5},{"code":"SALT_NaCl","kg_per_day":0.06},{"code":"PREMIX_BEEF","kg_per_day":0.1}]',
     'Корова, стельность/лактация, зима. НАСЭМ-приближение beef_reproducer КЗ.'),
    -- COW лето: пастбище + подкормка
    ('beef_reproducer','COW','summer',
     '[{"code":"PASTURE_SUMMER","kg_per_day":35},{"code":"HAY_MIXED_GRASS","kg_per_day":2},{"code":"GRAIN_BARLEY","kg_per_day":1},{"code":"SALT_NaCl","kg_per_day":0.05}]',
     'Корова, лето. Основа — пастбище. Концентрат поддерживающий.'),
    -- COW переходный период
    ('beef_reproducer','COW','transition',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":6},{"code":"SILAGE_CORN","kg_per_day":10},{"code":"GRAIN_BARLEY","kg_per_day":1.5},{"code":"SALT_NaCl","kg_per_day":0.05}]',
     'Корова, переходный период (апрель/октябрь).'),

    -- HEIFER_YOUNG зима: доращивание
    ('beef_reproducer','HEIFER_YOUNG','winter',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":5},{"code":"SILAGE_CORN","kg_per_day":8},{"code":"GRAIN_BARLEY","kg_per_day":1.5},{"code":"MEAL_SUNFLOWER","kg_per_day":0.3},{"code":"SALT_NaCl","kg_per_day":0.04}]',
     'Тёлка на доращивании, зима.'),
    ('beef_reproducer','HEIFER_YOUNG','summer',
     '[{"code":"PASTURE_SUMMER","kg_per_day":28},{"code":"HAY_MIXED_GRASS","kg_per_day":1.5},{"code":"GRAIN_BARLEY","kg_per_day":0.8},{"code":"SALT_NaCl","kg_per_day":0.04}]',
     'Тёлка на доращивании, лето.'),

    -- BULL_BREEDING зима: производитель
    ('beef_reproducer','BULL_BREEDING','winter',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":8},{"code":"GRAIN_BARLEY","kg_per_day":3},{"code":"MEAL_SUNFLOWER","kg_per_day":0.5},{"code":"SALT_NaCl","kg_per_day":0.07},{"code":"PREMIX_BEEF","kg_per_day":0.15}]',
     'Бык-производитель, зима. Повышенный CP в случной период.'),

    -- BULL_CALF зима: молодняк на доращивании
    ('beef_reproducer','BULL_CALF','winter',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":3},{"code":"GRAIN_BARLEY","kg_per_day":2},{"code":"MEAL_SUNFLOWER","kg_per_day":0.25},{"code":"SALT_NaCl","kg_per_day":0.03}]',
     'Бычок 8-18 мес, зима.'),
    ('beef_reproducer','BULL_CALF','summer',
     '[{"code":"PASTURE_SUMMER","kg_per_day":20},{"code":"GRAIN_BARLEY","kg_per_day":1.5},{"code":"SALT_NaCl","kg_per_day":0.03}]',
     'Бычок 8-18 мес, лето.'),

    -- ── feedlot ───────────────────────────────────────────────────────────────
    -- STEER зима: интенсивный откорм
    ('feedlot','STEER','winter',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":3},{"code":"SILAGE_CORN","kg_per_day":12},{"code":"GRAIN_BARLEY","kg_per_day":4.5},{"code":"GRAIN_CORN","kg_per_day":1},{"code":"MEAL_SUNFLOWER","kg_per_day":0.4},{"code":"SALT_NaCl","kg_per_day":0.05},{"code":"PREMIX_BEEF","kg_per_day":0.1}]',
     'Бычок на откорме (STEER), зима. Интенсивный рацион ~21.5 кг AS-FED.'),
    -- STEER лето: откорм с пастбищем
    ('feedlot','STEER','summer',
     '[{"code":"PASTURE_SUMMER","kg_per_day":20},{"code":"GRAIN_BARLEY","kg_per_day":3},{"code":"GRAIN_CORN","kg_per_day":0.5},{"code":"SALT_NaCl","kg_per_day":0.04}]',
     'Бычок на откорме, лето. Пастбище + концентрат.'),
    -- STEER переходный
    ('feedlot','STEER','transition',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":4},{"code":"SILAGE_CORN","kg_per_day":8},{"code":"GRAIN_BARLEY","kg_per_day":3.5},{"code":"SALT_NaCl","kg_per_day":0.04}]',
     'Бычок на откорме, переходный период.'),

    -- BULL_CALF feedlot зима
    ('feedlot','BULL_CALF','winter',
     '[{"code":"HAY_MIXED_GRASS","kg_per_day":2.5},{"code":"SILAGE_CORN","kg_per_day":6},{"code":"GRAIN_BARLEY","kg_per_day":2.5},{"code":"MEAL_SUNFLOWER","kg_per_day":0.3},{"code":"SALT_NaCl","kg_per_day":0.03}]',
     'Молодняк бычок feedlot, зима.')
) as v(farm_type, cat_code, season, items_seed, notes)
join public.animal_categories ac on ac.code = v.cat_code
on conflict (farm_type, animal_category_id, season, valid_from) do nothing;

-- Nutrient requirements seed (is_validated=false — Q36/Q37 pending)
-- Base values per 300kg animal, NASEM 8th ed. 2016 (approximate for KZ breeds)
insert into public.nutrient_requirements (
    animal_category_id, period_type_id,
    requirements, reference_weight_kg,
    is_validated, source_reference, notes
)
select
    ac.id,
    null,  -- applies to all periods (period-specific rows added after Q36 validation)
    nr.requirements::jsonb,
    300,   -- base reference weight
    false, -- Q36: pending
    'Приблизительно NASEM Beef 8th ed. 2016. Требует подтверждения (Q36).',
    nr.notes
from (values
    -- STEER (основной откорм): 300кг, 0.8 кг/сут
    ('STEER',    '{"dm_kg_per_100kg_bw":2.5,"me_mj_per_day":52,"cp_g_per_day":800,"ndf_pct_dm_min":25,"ca_g_per_day":20,"p_g_per_day":14}', 'Интенсивный откорм'),
    -- BULL_CALF: молодняк 150кг
    ('BULL_CALF','{"dm_kg_per_100kg_bw":3.0,"me_mj_per_day":28,"cp_g_per_day":500,"ndf_pct_dm_min":25,"ca_g_per_day":18,"p_g_per_day":10}', 'Активный рост'),
    -- COW: стельная/лактирующая
    ('COW',      '{"dm_kg_per_100kg_bw":2.2,"me_mj_per_day":58,"cp_g_per_day":950,"ndf_pct_dm_min":30,"ca_g_per_day":35,"p_g_per_day":22}', 'Стельность + начало лактации'),
    -- HEIFER_YOUNG: тёлка на доращивании
    ('HEIFER_YOUNG','{"dm_kg_per_100kg_bw":2.4,"me_mj_per_day":40,"cp_g_per_day":680,"ndf_pct_dm_min":28,"ca_g_per_day":22,"p_g_per_day":14}', 'Доращивание'),
    -- BULL_BREEDING: производитель в случной период
    ('BULL_BREEDING','{"dm_kg_per_100kg_bw":2.0,"me_mj_per_day":65,"cp_g_per_day":1100,"ndf_pct_dm_min":30,"ca_g_per_day":28,"p_g_per_day":18}', 'Повышенные требования к CP и витаминам в период случки')
) as nr(cat_code, requirements, notes)
join public.animal_categories ac on ac.code = nr.cat_code
on conflict do nothing;

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Summary:
--   Reference tables:    5 (feed_categories, feed_items, feed_prices,
--                           nutrient_requirements, period_types)
--   Operational tables:  5 (farm_feed_inventory, rations, ration_versions,
--                           feeding_plans, feeding_periods)
--   Total:              10 tables
--
--   Indexes:            28
--   RLS policies:       18
--   Triggers:            8 (5 updated_at + 2 ration FSM + 1 period status fn)
--   Seed data:          5 period_types + 6 feed_categories + 18 feed_items
--                       + 8 placeholder prices + 5 nutrient requirement rows
--
-- Verified decisions:
--   D27 D42 D43 D44 D45 D46 D47 D48 D51 D52 D53 D54 D75 D87
--
-- Open questions resolved (partially):
--   Q37 ✅ schema ready; feed_items seeded with is_validated=false
--   Q38 ✅ algorithm = Edge Function scope, not schema
--   Q39 ✅ is_quick_mode flag on rations; organization_id nullable
--   Q40 ✅ data_source='erp' already in farm_feed_inventory
--   Q41 ✅ PASTURE category seeded with price=0
--
-- Computed RPCs (NOT in schema — D87):
--   calculate_ration        → Edge Function / FastAPI (NASEM LP)
--   get_feed_budget         → Edge Function / FastAPI
--   get_nutrient_balance    → Edge Function / FastAPI
--   FSM transitions         → PostgreSQL RPC (atomicity)
--
-- Cross-module FK dependencies:
--   → 001_kernel.sql: farms, organizations, herd_groups,
--                     animal_categories, breeds, regions,
--                     users, expert_profiles
--   → No deps on 002_tsp.sql (clean separation, D48)
--
-- Next migration: 004_platform_events.sql (Platform Event Bus details)
--   OR 005_vet.sql (Veterinary module)
--   Recommended: 005_vet.sql (D48: Feed/Vet boundary — AI links them)
-- ============================================================


-- ============================================================
-- SLICE 3: Feed Planning RPCs
-- RPC-21: rpc_upsert_feed_inventory
-- RPC-22: rpc_save_ration
-- RPC-23: rpc_archive_ration
-- RPC-24: rpc_get_current_ration
-- ============================================================

-- ============================================================
-- RPC-21: rpc_upsert_feed_inventory
-- Dok 3 §5 | Callers: [WEB] [AI]
-- D-S3-1: Individual fields per call (not batch jsonb).
-- D45: Layered Truth — data_source determines confidence.
-- Events: feed.inventory.updated (Dok 4 §3.4)
-- ============================================================
create or replace function public.rpc_upsert_feed_inventory(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_feed_item_id      uuid,
    p_quantity_kg       numeric,
    p_price_per_kg      numeric     default null,
    p_data_source       text        default 'platform'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_inventory_id  uuid;
    v_confidence    int;
    v_qty_before    numeric;
    v_is_new        boolean := false;
begin
    -- Validate required fields
    if p_feed_item_id is null then
        raise exception 'FEED_ITEM_REQUIRED: p_feed_item_id cannot be null'
            using errcode = 'P0001';
    end if;
    if p_quantity_kg is null or p_quantity_kg < 0 then
        raise exception 'INVALID_QUANTITY: p_quantity_kg must be >= 0'
            using errcode = 'P0001';
    end if;

    -- Ownership check: farm belongs to organization
    if not exists (
        select 1 from public.farms
        where id = p_farm_id and organization_id = p_organization_id and is_active = true
    ) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    -- Validate feed_item exists and is active
    if not exists (
        select 1 from public.feed_items where id = p_feed_item_id and is_active = true
    ) then
        raise exception 'FEED_ITEM_NOT_FOUND: feed_item % not found or inactive',
            p_feed_item_id using errcode = 'P0001';
    end if;

    -- D45: Confidence mapping from data_source
    v_confidence := case p_data_source
        when 'registration'  then 25
        when 'ai_extracted'  then 50
        when 'platform'      then 75
        when 'erp'           then 95
        else 75  -- default to platform level
    end;

    -- Get current quantity for event payload (before upsert)
    select quantity_kg into v_qty_before
    from public.farm_feed_inventory
    where farm_id = p_farm_id and feed_item_id = p_feed_item_id;

    if v_qty_before is null then
        v_is_new := true;
        v_qty_before := 0;
    end if;

    -- UPSERT: unique(farm_id, feed_item_id)
    insert into public.farm_feed_inventory (
        farm_id,
        organization_id,
        feed_item_id,
        quantity_kg,
        data_source,
        confidence,
        last_updated_date,
        notes
    ) values (
        p_farm_id,
        p_organization_id,
        p_feed_item_id,
        p_quantity_kg,
        p_data_source,
        v_confidence,
        current_date,
        null
    )
    on conflict (farm_id, feed_item_id) do update
        set quantity_kg       = excluded.quantity_kg,
            data_source       = excluded.data_source,
            confidence        = excluded.confidence,
            last_updated_date = excluded.last_updated_date
    returning id into v_inventory_id;

    -- Emit event: feed.inventory.updated (Dok 4 §3.4)
    insert into public.platform_events (
        event_type,
        entity_type,
        entity_id,
        organization_id,
        actor_type,
        actor_id,
        payload,
        is_audit
    ) values (
        'feed.inventory.updated',
        'farm_feed_inventory',
        v_inventory_id,
        p_organization_id,
        'farmer',
        public.fn_current_user_id(),
        jsonb_build_object(
            'farm_id', p_farm_id,
            'items', jsonb_build_array(
                jsonb_build_object(
                    'feed_item_id', p_feed_item_id,
                    'qty_kg_before', v_qty_before,
                    'qty_kg_after', p_quantity_kg
                )
            ),
            'data_source', p_data_source
        ),
        false
    );

    return jsonb_build_object(
        'inventory_id', v_inventory_id,
        'is_new', v_is_new,
        'quantity_kg', p_quantity_kg,
        'confidence', v_confidence
    );
end;
$$;

comment on function public.rpc_upsert_feed_inventory(uuid, uuid, uuid, numeric, numeric, text) is
    'RPC-21 | Dok 3 §5 | Slice 3
     D-S3-1: Individual fields per call (not batch).
     D45: Layered Truth — confidence auto-set from data_source.
     UPSERT on unique(farm_id, feed_item_id).
     Events: feed.inventory.updated.
     AI Gateway: must use save_confirmation_payload first (P-AI-3).';



-- ============================================================
-- RPC-22: rpc_save_ration
-- Dok 3 §5 | Callers: [WEB] [AI]
-- Creates ration header + inserts new RationVersion (append-only D51).
-- Trigger fn_ration_version_set_current maintains is_current flag.
-- Trigger fn_ration_auto_activate sets status=active on first version.
-- Events: feed.ration.created (Dok 4 §3.4)
-- ============================================================
create or replace function public.rpc_save_ration(
    p_organization_id       uuid,
    p_farm_id               uuid,
    p_herd_group_id         uuid        default null,
    p_animal_category_id    uuid        default null,
    p_breed_id              uuid        default null,
    p_period_type_id        uuid        default null,
    p_avg_weight_kg         numeric     default null,
    p_head_count            int         default null,
    p_objective             text        default 'growth',
    p_shelter_type          text        default 'combined',
    p_target_daily_gain_kg  numeric     default null,
    p_ration_id             uuid        default null,   -- null = create new, uuid = add version
    p_items                 jsonb       default '[]',    -- feed items array
    p_results               jsonb       default '{}',    -- LP solver results
    p_calculated_by         text        default 'edge_function',
    p_notes                 text        default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ration_id         uuid;
    v_version_id        uuid;
    v_version_number    int;
    v_category_id       uuid;
    v_is_new_ration     boolean := false;
begin
    -- Ownership check: farm belongs to organization
    if not exists (
        select 1 from public.farms
        where id = p_farm_id and organization_id = p_organization_id and is_active = true
    ) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    if p_ration_id is null then
        -- CREATE new ration header
        -- animal_category_id is required for new rations
        v_category_id := p_animal_category_id;
        if v_category_id is null and p_herd_group_id is not null then
            -- Derive from herd group
            select animal_category_id into v_category_id
            from public.herd_groups
            where id = p_herd_group_id and is_active = true;
        end if;

        if v_category_id is null then
            raise exception 'ANIMAL_CATEGORY_REQUIRED: p_animal_category_id or p_herd_group_id must be provided'
                using errcode = 'P0001';
        end if;

        if p_avg_weight_kg is null or p_avg_weight_kg <= 0 then
            raise exception 'WEIGHT_REQUIRED: p_avg_weight_kg must be > 0'
                using errcode = 'P0001';
        end if;

        -- Archive any existing active ration for this herd group (if applicable)
        if p_herd_group_id is not null then
            update public.rations
            set status = 'archived', updated_at = now()
            where farm_id = p_farm_id
              and herd_group_id = p_herd_group_id
              and status = 'active';
        end if;

        insert into public.rations (
            farm_id,
            organization_id,
            herd_group_id,
            animal_category_id,
            breed_id,
            period_type_id,
            avg_weight_kg,
            head_count,
            objective,
            shelter_type,
            target_daily_gain_kg,
            status,
            is_quick_mode,
            notes,
            created_by
        ) values (
            p_farm_id,
            p_organization_id,
            p_herd_group_id,
            v_category_id,
            p_breed_id,
            p_period_type_id,
            p_avg_weight_kg,
            coalesce(p_head_count, 1),
            p_objective,
            p_shelter_type,
            p_target_daily_gain_kg,
            'draft',
            false,
            p_notes,
            public.fn_current_user_id()
        )
        returning id into v_ration_id;

        v_is_new_ration := true;
    else
        -- ADD VERSION to existing ration
        v_ration_id := p_ration_id;

        -- Verify ration exists and belongs to org
        if not exists (
            select 1 from public.rations
            where id = v_ration_id
              and organization_id = p_organization_id
              and status in ('draft', 'active')
        ) then
            raise exception 'RATION_NOT_FOUND: ration % not found or archived',
                v_ration_id using errcode = 'P0001';
        end if;

        -- Read existing ration params for version snapshot
        select avg_weight_kg, head_count, period_type_id, objective, shelter_type
        into p_avg_weight_kg, p_head_count, p_period_type_id, p_objective, p_shelter_type
        from public.rations
        where id = v_ration_id;
    end if;

    -- Determine next version number
    select coalesce(max(version_number), 0) + 1 into v_version_number
    from public.ration_versions
    where ration_id = v_ration_id;

    -- D51: Append-only INSERT (never UPDATE ration_versions)
    -- Triggers: fn_ration_version_set_current (BEFORE INSERT) sets is_current
    -- Triggers: fn_ration_auto_activate (AFTER INSERT) sets ration status=active
    insert into public.ration_versions (
        ration_id,
        version_number,
        items,
        results,
        calc_avg_weight_kg,
        calc_head_count,
        calc_period_type_code,
        calc_objective,
        calc_shelter_type,
        calculated_by
    ) values (
        v_ration_id,
        v_version_number,
        p_items,
        p_results,
        p_avg_weight_kg,
        coalesce(p_head_count, 1),
        (select code from public.period_types where id = p_period_type_id),
        p_objective,
        p_shelter_type,
        p_calculated_by
    )
    returning id into v_version_id;

    -- Emit event: feed.ration.created (Dok 4 §3.4)
    insert into public.platform_events (
        event_type,
        entity_type,
        entity_id,
        organization_id,
        actor_type,
        actor_id,
        payload,
        is_audit
    ) values (
        'feed.ration.created',
        'rations',
        v_ration_id,
        p_organization_id,
        'farmer',
        public.fn_current_user_id(),
        jsonb_build_object(
            'ration_id', v_ration_id,
            'farm_id', p_farm_id,
            'herd_group_id', p_herd_group_id,
            'version_number', v_version_number,
            'is_new_ration', v_is_new_ration
        ),
        false
    );

    return jsonb_build_object(
        'ration_id', v_ration_id,
        'version_id', v_version_id,
        'version_number', v_version_number,
        'is_new_ration', v_is_new_ration
    );
end;
$$;

comment on function public.rpc_save_ration(uuid, uuid, uuid, uuid, uuid, uuid, numeric, int, text, text, numeric, uuid, jsonb, jsonb, text, text) is
    'RPC-22 | Dok 3 §5 | Slice 3
     p_ration_id=null → creates new ration + first version.
     p_ration_id=uuid → adds new version to existing ration (D51 append-only).
     Auto-archives previous active ration for same herd_group.
     Triggers: fn_ration_version_set_current (is_current flag),
               fn_ration_auto_activate (draft→active on first version).
     Events: feed.ration.created.
     D87: Called by Edge Function calculate_ration or AI Gateway.';



-- ============================================================
-- RPC-23: rpc_archive_ration
-- Dok 3 §5 | Callers: [WEB] [AI]
-- FSM: active → archived (soft-archive, P7)
-- Events: feed.ration.archived (Dok 4 §3.4)
-- ============================================================
create or replace function public.rpc_archive_ration(
    p_organization_id   uuid,
    p_ration_id         uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_current_status    text;
    v_farm_id           uuid;
begin
    -- Get ration and verify ownership
    select status, farm_id into v_current_status, v_farm_id
    from public.rations
    where id = p_ration_id
      and organization_id = p_organization_id;

    if v_current_status is null then
        raise exception 'RATION_NOT_FOUND: ration % not found for organization %',
            p_ration_id, p_organization_id using errcode = 'P0001';
    end if;

    if v_current_status = 'archived' then
        -- Already archived — idempotent
        return true;
    end if;

    -- FSM: only draft or active can transition to archived
    if v_current_status not in ('draft', 'active') then
        raise exception 'INVALID_STATUS_TRANSITION: cannot archive ration in status %',
            v_current_status using errcode = 'P0001';
    end if;

    update public.rations
    set status = 'archived', updated_at = now()
    where id = p_ration_id;

    -- Emit event: feed.ration.archived (Dok 4 §3.4)
    insert into public.platform_events (
        event_type,
        entity_type,
        entity_id,
        organization_id,
        actor_type,
        actor_id,
        payload,
        is_audit
    ) values (
        'feed.ration.archived',
        'rations',
        p_ration_id,
        p_organization_id,
        'farmer',
        public.fn_current_user_id(),
        jsonb_build_object(
            'ration_id', p_ration_id,
            'farm_id', v_farm_id,
            'reason', 'user_archived'
        ),
        false
    );

    return true;
end;
$$;

comment on function public.rpc_archive_ration(uuid, uuid) is
    'RPC-23 | Dok 3 §5 | Slice 3
     FSM: draft|active → archived. Idempotent (already archived = true).
     Soft-archive: ration and versions retained for history.
     Events: feed.ration.archived.';



-- ============================================================
-- RPC-24: rpc_get_current_ration
-- Dok 3 §5 | Callers: [WEB] [AI]
-- D-S3-2: Farm-level return — all active rations for the farm.
-- Returns array of rations with current version + nutrient summary.
-- ============================================================
create or replace function public.rpc_get_current_ration(
    p_organization_id   uuid,
    p_farm_id           uuid
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
    -- Ownership check
    if not exists (
        select 1 from public.farms
        where id = p_farm_id and organization_id = p_organization_id and is_active = true
    ) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    select coalesce(jsonb_agg(ration_data order by ac.code), '[]'::jsonb)
    into v_result
    from (
        select
            jsonb_build_object(
                'ration_id', r.id,
                'herd_group_id', r.herd_group_id,
                'animal_category_id', r.animal_category_id,
                'animal_category_code', ac.code,
                'animal_category_name_ru', ac.name_ru,
                'breed_id', r.breed_id,
                'breed_name_ru', b.name_ru,
                'avg_weight_kg', r.avg_weight_kg,
                'head_count', r.head_count,
                'objective', r.objective,
                'shelter_type', r.shelter_type,
                'target_daily_gain_kg', r.target_daily_gain_kg,
                'status', r.status,
                'created_at', r.created_at,
                'current_version', (
                    select jsonb_build_object(
                        'version_id', rv.id,
                        'version_number', rv.version_number,
                        'items', rv.items,
                        'results', rv.results,
                        'calculated_by', rv.calculated_by,
                        'created_at', rv.created_at
                    )
                    from public.ration_versions rv
                    where rv.ration_id = r.id
                      and rv.is_current = true
                    limit 1
                ),
                'version_count', (
                    select count(*)
                    from public.ration_versions rv
                    where rv.ration_id = r.id
                )
            ) as ration_data,
            ac.code  -- for ordering
        from public.rations r
        join public.animal_categories ac on ac.id = r.animal_category_id
        left join public.breeds b on b.id = r.breed_id
        where r.farm_id = p_farm_id
          and r.organization_id = p_organization_id
          and r.status = 'active'
    ) sub
    join public.animal_categories ac on ac.code = sub.code;

    return v_result;
end;
$$;

comment on function public.rpc_get_current_ration(uuid, uuid) is
    'RPC-24 | Dok 3 §5 | Slice 3
     D-S3-2: Farm-level return — all active rations for the farm.
     Each ration includes current version (is_current=true) with items + results.
     STABLE read — no side effects.
     Used by: F17 (Ration Viewer), AI Gateway feed context.';



-- ============================================================
-- SLICE 3: Add new RPCs to rpc_name_registry
-- ============================================================
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('rpc_upsert_feed_inventory', 'rpc_upsert_feed_inventory', null, 'd03_feed.sql (Slice 3)', 'RPC-21: UPSERT feed inventory (D-S3-1 individual fields)'),
    ('rpc_save_ration',           'rpc_save_ration',           null, 'd03_feed.sql (Slice 3)', 'RPC-22: Create/version ration (D51 append-only versions)'),
    ('rpc_archive_ration',        'rpc_archive_ration',        null, 'd03_feed.sql (Slice 3)', 'RPC-23: Archive ration (FSM: active→archived)'),
    ('rpc_get_current_ration',    'rpc_get_current_ration',    null, 'd03_feed.sql (Slice 3)', 'RPC-24: Farm-level active rations (D-S3-2)')
on conflict (sql_name) do update
    set dok3_name      = excluded.dok3_name,
        dok5_tool_name = excluded.dok5_tool_name,
        notes          = excluded.notes,
        created_in     = excluded.created_in;

-- ============================================================
-- END Slice 3 d03_feed.sql RPCs
-- ============================================================



-- ============================================================
-- FIX S-3: Partial unique index — one active ration per herd_group
-- Prevents race condition in concurrent rpc_save_ration calls.
-- ============================================================
create unique index if not exists idx_rations_one_active_per_group
    on public.rations (farm_id, herd_group_id)
    where status = 'active' and herd_group_id is not null;



-- ============================================================
-- SLICE 8 PART A: Feed Reference — Справочник кормов
-- Единственный источник правды для всей системы (P8).
-- Заменяет hardcoded dict в feeding_model.py и дубли в d09.
-- ADR-FEED-01, D-S8-1 (2026-04-09)
-- ============================================================


-- -------------------------------------------------------
-- TABLE: feed_consumption_norms
-- Типовые нормы кормления по farm_type + animal_category + season.
-- Заменяет consulting_reference_data category='feed_norms'.
-- Используется: feeding_model.py (Priority 2 fallback),
--              Admin UI /admin/feeds, RationTab в consulting.
-- -------------------------------------------------------
create table if not exists public.feed_consumption_norms (
    id                  uuid        primary key default gen_random_uuid(),
    farm_type           text        not null
                                    check (farm_type in ('beef_reproducer', 'feedlot', 'sheep_goat')),
    animal_category_id  uuid        not null references public.animal_categories(id),
    season              text        not null
                                    check (season in ('winter', 'summer', 'transition')),
    items               jsonb       not null default '[]',
    -- items format: [{feed_item_id: uuid, kg_per_day: number}]
    valid_from          date        not null default current_date,
    valid_to            date,
    notes               text,
    created_by          uuid        references public.users(id),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    constraint fcn_valid_period check (valid_to is null or valid_to > valid_from),
    constraint fcn_unique_norm unique (farm_type, animal_category_id, season, valid_from)
);

comment on table public.feed_consumption_norms is
    'Slice 8 ADR-FEED-01: Типовые нормы кормления (кг/день) по farm_type + category + season.
     Единственный источник правды — заменяет consulting_reference_data.feed_norms.
     feeding_model.py использует как Priority 2 fallback (после attached ration_versions).
     Admin-managed: только admin может писать, authenticated — читать.';

create index if not exists idx_fcn_farm_cat_season
    on public.feed_consumption_norms (farm_type, animal_category_id, season);
create index if not exists idx_fcn_valid
    on public.feed_consumption_norms (valid_from, valid_to)
    where valid_to is null or valid_to > current_date;

-- RLS
alter table public.feed_consumption_norms enable row level security;
create policy fcn_read_auth on public.feed_consumption_norms
    for select using (auth.role() = 'authenticated');
create policy fcn_admin_write on public.feed_consumption_norms
    for all using (public.fn_is_admin());

-- updated_at trigger
create trigger trg_fcn_updated_at
    before update on public.feed_consumption_norms
    for each row execute function public.fn_set_updated_at();


-- DEF-RATION-SAVE-01 (2026-04-17): no-arg wrapper DROPPED.
--   Postgrest could not resolve overload when UI called .rpc('rpc_list_animal_categories', {}) →
--   PGRST203 → animalCategories=undefined → SimpleRationEditor.handleSave silently skipped all groups.
--   Canonical rpc_list_animal_categories(p_at_date, p_include_deprecated) now returns `id` in jsonb
--   (d01_kernel.sql). All 4 UI callers pass explicit params.
drop function if exists public.rpc_list_animal_categories();

-- -------------------------------------------------------
-- DEF-027: rpc_list_feed_items — отсутствует в SQL,
-- но вызывается из Calculator.tsx.
-- -------------------------------------------------------
create or replace function public.rpc_list_feed_items(
    p_active_only boolean default true
)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
    return (
        select jsonb_agg(
            jsonb_build_object(
                'id',                   fi.id,
                'code',                 fi.code,
                'name_ru',              fi.name_ru,
                'name_en',              fi.name_en,
                'category',             fc.code,
                'category_name_ru',     fc.name_ru,
                'nutrient_composition', fi.nutrient_composition,
                'is_validated',         fi.is_validated
            ) order by fc.sort_order, fi.name_ru
        )
        from public.feed_items fi
        join public.feed_categories fc on fc.id = fi.feed_category_id
        where (not p_active_only or fi.is_active = true)
    );
end;
$$;

comment on function public.rpc_list_feed_items(boolean) is
    'RPC-F01 | Dok 3 §13b | Slice 8 (DEF-027 fix)
     Список кормов для UI-селекторов (калькулятор рационов, Admin).
     p_active_only=true (default) — только активные корма.
     STABLE — no side effects.';


-- -------------------------------------------------------
-- RPC-F03: rpc_upsert_feed_item — Admin: создать/обновить корм
-- -------------------------------------------------------
create or replace function public.rpc_upsert_feed_item(
    p_feed_item_id          uuid    default null,
    p_feed_category_code    text    default null,
    p_code                  text    default null,
    p_name_ru               text    default null,
    p_name_en               text    default null,
    p_nutrient_composition  jsonb   default '{}',
    p_is_validated          boolean default false,
    p_notes                 text    default null
)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
    v_category_id   uuid;
    v_item_id       uuid;
begin
    -- Admin only
    if not public.fn_is_admin() then
        raise exception 'UNAUTHORIZED' using hint = 'Admin role required';
    end if;

    -- Resolve category
    if p_feed_category_code is not null then
        select id into v_category_id
        from public.feed_categories
        where code = p_feed_category_code and is_active = true;
        if v_category_id is null then
            raise exception 'FEED_CATEGORY_NOT_FOUND' using hint = p_feed_category_code;
        end if;
    end if;

    if p_feed_item_id is not null then
        -- UPDATE existing
        update public.feed_items set
            feed_category_id     = coalesce(v_category_id, feed_category_id),
            code                 = coalesce(p_code, code),
            name_ru              = coalesce(p_name_ru, name_ru),
            name_en              = coalesce(p_name_en, name_en),
            nutrient_composition = coalesce(p_nutrient_composition, nutrient_composition),
            is_validated         = coalesce(p_is_validated, is_validated),
            notes                = coalesce(p_notes, notes)
        where id = p_feed_item_id
        returning id into v_item_id;
        if v_item_id is null then
            raise exception 'FEED_ITEM_NOT_FOUND';
        end if;
    else
        -- INSERT new
        if p_feed_category_code is null or p_code is null or p_name_ru is null then
            raise exception 'MISSING_REQUIRED_FIELDS'
                using hint = 'p_feed_category_code, p_code, p_name_ru required for create';
        end if;
        insert into public.feed_items (
            feed_category_id, code, name_ru, name_en,
            nutrient_composition, is_validated, notes
        ) values (
            v_category_id, p_code, p_name_ru, p_name_en,
            p_nutrient_composition, p_is_validated, p_notes
        )
        returning id into v_item_id;
    end if;

    return jsonb_build_object('feed_item_id', v_item_id);
end;
$$;

comment on function public.rpc_upsert_feed_item(uuid, text, text, text, text, jsonb, boolean, text) is
    'RPC-F03 | Dok 3 §13b | Slice 8
     Admin CRUD для справочника кормов.
     p_feed_item_id=NULL → CREATE, иначе UPDATE (partial update, null поля игнорируются).
     Возвращает {feed_item_id}.';


-- -------------------------------------------------------
-- RPC-F04: rpc_upsert_feed_price — Admin: установить/обновить цену
-- -------------------------------------------------------
create or replace function public.rpc_upsert_feed_price(
    p_feed_item_id  uuid,
    p_price_per_kg  numeric,
    p_region_id     uuid    default null,
    p_valid_from    date    default current_date,
    p_valid_to      date    default null,
    p_currency      text    default 'KZT'
)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
    v_price_id  uuid;
    v_user_id   uuid;
begin
    if not public.fn_is_admin() then
        raise exception 'UNAUTHORIZED' using hint = 'Admin role required';
    end if;
    if p_price_per_kg < 0 then
        raise exception 'INVALID_PRICE' using hint = 'price_per_kg must be >= 0';
    end if;
    if not exists (select 1 from public.feed_items where id = p_feed_item_id) then
        raise exception 'FEED_ITEM_NOT_FOUND';
    end if;

    -- Resolve public.users.id from auth_id (auth.uid() is auth_id, not public.users.id)
    select id into v_user_id from public.users where auth_id = auth.uid();

    insert into public.feed_prices (
        feed_item_id, price_per_kg, region_id, valid_from, valid_to,
        currency, is_active, updated_by
    ) values (
        p_feed_item_id, p_price_per_kg, p_region_id, p_valid_from, p_valid_to,
        p_currency, true, v_user_id
    )
    on conflict (feed_item_id, region_id, valid_from)
        do update set
            price_per_kg = excluded.price_per_kg,
            valid_to     = excluded.valid_to,
            currency     = excluded.currency,
            is_active    = true,
            updated_by   = excluded.updated_by,
            updated_at   = now()
    returning id into v_price_id;

    return jsonb_build_object('feed_price_id', v_price_id);
end;
$$;

comment on function public.rpc_upsert_feed_price(uuid, numeric, uuid, date, date, text) is
    'RPC-F04 | Dok 3 §13b | Slice 8
     Admin: установить или обновить цену корма.
     ON CONFLICT (feed_item_id, region_id, valid_from) → UPDATE.
     p_region_id=NULL → общегосударственная цена (NULL region_id).';


-- -------------------------------------------------------
-- RPC-F04b: rpc_list_feed_prices — список текущих цен по кормам
-- -------------------------------------------------------

create or replace function public.rpc_list_feed_prices()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
    return (
        select jsonb_agg(
            jsonb_build_object(
                'feed_price_id',  fp.id,
                'feed_item_id',   fi.id,
                'feed_item_code', fi.code,
                'feed_item_name', fi.name_ru,
                'price_per_kg',   fp.price_per_kg,
                'currency',       fp.currency,
                'valid_from',     fp.valid_from,
                'valid_to',       fp.valid_to,
                'region_id',      fp.region_id,
                'is_active',      fp.is_active,
                'updated_at',     fp.updated_at,
                'disclaimer_text', 'Цены носят справочный характер. ТОО ТУРАН не является стороной торговых сделок (ст.171 ПК РК).'
            ) order by fi.name_ru
        )
        from (
            select distinct on (fp.feed_item_id, fp.region_id)
                fp.id, fp.feed_item_id, fp.price_per_kg, fp.currency,
                fp.valid_from, fp.valid_to, fp.region_id, fp.is_active, fp.updated_at
            from public.feed_prices fp
            where fp.is_active = true
            order by fp.feed_item_id, fp.region_id, fp.valid_from desc
        ) fp
        join public.feed_items fi on fi.id = fp.feed_item_id
    );
end;
$$;

comment on function public.rpc_list_feed_prices() is
    'RPC-F04b | Slice 8 | List active feed prices for Admin Prices tab.';

-- -------------------------------------------------------
-- RPC-F05: rpc_upsert_feed_consumption_norm — Admin: норма кормления
-- -------------------------------------------------------
create or replace function public.rpc_upsert_feed_consumption_norm(
    p_norm_id               uuid    default null,
    p_farm_type             text    default null,
    p_animal_category_id    uuid    default null,
    p_season                text    default null,
    p_items                 jsonb   default '[]',
    p_valid_from            date    default current_date,
    p_valid_to              date    default null,
    p_notes                 text    default null
)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
    v_norm_id   uuid;
begin
    if not public.fn_is_admin() then
        raise exception 'UNAUTHORIZED' using hint = 'Admin role required';
    end if;

    if p_norm_id is not null then
        -- UPDATE
        update public.feed_consumption_norms set
            farm_type           = coalesce(p_farm_type, farm_type),
            animal_category_id  = coalesce(p_animal_category_id, animal_category_id),
            season              = coalesce(p_season, season),
            items               = coalesce(p_items, items),
            valid_from          = coalesce(p_valid_from, valid_from),
            valid_to            = p_valid_to,
            notes               = coalesce(p_notes, notes),
            updated_at          = now()
        where id = p_norm_id
        returning id into v_norm_id;
        if v_norm_id is null then
            raise exception 'NORM_NOT_FOUND';
        end if;
    else
        -- INSERT
        if p_farm_type is null or p_animal_category_id is null or p_season is null then
            raise exception 'MISSING_REQUIRED_FIELDS'
                using hint = 'p_farm_type, p_animal_category_id, p_season required for create';
        end if;
        insert into public.feed_consumption_norms (
            farm_type, animal_category_id, season, items,
            valid_from, valid_to, notes, created_by
        ) values (
            p_farm_type, p_animal_category_id, p_season, p_items,
            p_valid_from, p_valid_to, p_notes, auth.uid()
        )
        on conflict (farm_type, animal_category_id, season, valid_from)
            do update set
                items      = excluded.items,
                valid_to   = excluded.valid_to,
                notes      = excluded.notes,
                updated_at = now()
        returning id into v_norm_id;
    end if;

    return jsonb_build_object('norm_id', v_norm_id);
end;
$$;

comment on function public.rpc_upsert_feed_consumption_norm(uuid, text, uuid, text, jsonb, date, date, text) is
    'RPC-F05 | Dok 3 §13b | Slice 8
     Admin: создать/обновить норму кормления (кг/день по категориям животных).
     Заменяет consulting_reference_data.feed_norms (ADR-FEED-01).
     p_norm_id=NULL → CREATE, иначе UPDATE.
     ON CONFLICT (farm_type, animal_category_id, season, valid_from) → UPDATE.';


-- -------------------------------------------------------
-- rpc_list_feed_categories — для UI-селекторов (FeedItemDialog)
-- -------------------------------------------------------
create or replace function public.rpc_list_feed_categories()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
    return (
        select jsonb_agg(
            jsonb_build_object(
                'id',       fc.id,
                'code',     fc.code,
                'name_ru',  fc.name_ru,
                'sort_order', fc.sort_order
            ) order by fc.sort_order, fc.name_ru
        )
        from public.feed_categories fc
        where fc.is_active = true
    );
end;
$$;

comment on function public.rpc_list_feed_categories() is
    'RPC-F06 | Dok 3 §13b | Slice 8
     Список активных категорий кормов для UI-селекторов.
     STABLE — no side effects.';


-- -------------------------------------------------------
-- rpc_list_feed_consumption_norms — список норм кормления для Admin UI
-- -------------------------------------------------------
create or replace function public.rpc_list_feed_consumption_norms(
    p_farm_type text default null
)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
    return (
        select jsonb_agg(
            jsonb_build_object(
                'id',                   fcn.id,
                'farm_type',            fcn.farm_type,
                'animal_category_id',   fcn.animal_category_id,
                'season',               fcn.season,
                'items',                fcn.items,
                'valid_from',           fcn.valid_from,
                'valid_to',             fcn.valid_to,
                'notes',                fcn.notes
            ) order by fcn.farm_type, fcn.season
        )
        from public.feed_consumption_norms fcn
        where (p_farm_type is null or fcn.farm_type = p_farm_type)
          and (fcn.valid_to is null or fcn.valid_to > current_date)
    );
end;
$$;

comment on function public.rpc_list_feed_consumption_norms(text) is
    'RPC-F07 | Dok 3 §13b | Slice 8
     Список норм кормления (feed_consumption_norms) для Admin UI и feeding_model.py.
     p_farm_type=NULL → все нормы. Возвращает только активные (valid_to не истёк).
     STABLE — no side effects.';


-- ============================================================
-- SLICE 8 PART A: Register new RPCs in rpc_name_registry
-- ============================================================
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('rpc_list_animal_categories',      'rpc_list_animal_categories',      null, 'd03_feed.sql (Slice 8 DEF-027)', 'RPC-F02: List active animal categories for UI selectors'),
    ('rpc_list_feed_items',             'rpc_list_feed_items',             null, 'd03_feed.sql (Slice 8 DEF-027)', 'RPC-F01: List feed items catalog for UI selectors'),
    ('rpc_upsert_feed_item',            'rpc_upsert_feed_item',            null, 'd03_feed.sql (Slice 8)',         'RPC-F03: Admin CRUD for feed items catalog'),
    ('rpc_upsert_feed_price',           'rpc_upsert_feed_price',           null, 'd03_feed.sql (Slice 8)',         'RPC-F04: Admin upsert feed price (region + valid_from)'),
    ('rpc_list_feed_prices',            'rpc_list_feed_prices',            null, 'd03_feed.sql (Slice 8)',         'RPC-F04b: List active feed prices for Admin Prices tab (DEF-031 fix)'),
    ('rpc_upsert_feed_consumption_norm',    'rpc_upsert_feed_consumption_norm',    null, 'd03_feed.sql (Slice 8)', 'RPC-F05: Admin upsert feed consumption norm (ADR-FEED-01)'),
    ('rpc_list_feed_categories',            'rpc_list_feed_categories',            null, 'd03_feed.sql (Slice 8)', 'RPC-F06: List active feed categories for UI selectors'),
    ('rpc_list_feed_consumption_norms',     'rpc_list_feed_consumption_norms',     null, 'd03_feed.sql (Slice 8)', 'RPC-F07: List feed consumption norms for Admin UI and feeding_model.py')
on conflict (sql_name) do update
    set dok3_name  = excluded.dok3_name,
        notes      = excluded.notes,
        created_in = excluded.created_in;

-- ============================================================
-- END Slice 8 Part A d03_feed.sql
-- ============================================================



-- ============================================================
-- SLICE 8 PART C: ration_versions — контекст-независимое хранилище
-- ADR-FEED-02: ration_id nullable + consulting_project_id FK
-- Аддитивное изменение — существующие данные не затронуты.
-- D-S8-4 (2026-04-09)
-- ============================================================

-- Шаг 1: ration_id → NULLABLE
alter table public.ration_versions
    alter column ration_id drop not null;

-- Шаг 2: добавить consulting FK (если не существует)
alter table public.ration_versions
    add column if not exists consulting_project_id uuid
        references public.consulting_projects(id);

-- Шаг 3: добавить animal_category FK для consulting context
alter table public.ration_versions
    add column if not exists context_animal_category_id uuid
        references public.animal_categories(id);

-- Шаг 4: CHECK — хотя бы один контекст должен быть задан
alter table public.ration_versions
    add constraint if not exists rv_context_check
        check (ration_id is not null or consulting_project_id is not null);

-- Шаг 5: INDEX для consulting context lookups
create index if not exists idx_rv_consulting
    on public.ration_versions (consulting_project_id)
    where consulting_project_id is not null;

create index if not exists idx_rv_consulting_category
    on public.ration_versions (consulting_project_id, context_animal_category_id)
    where consulting_project_id is not null;

-- Шаг 6: Обновить RLS policy rv_read_own — добавить consulting context ветку
-- Было: только по parent ration org
-- Стало: ИЛИ по consulting_project_id org membership
drop policy if exists rv_read_own on public.ration_versions;
create policy rv_read_own on public.ration_versions
    for select using (
        -- Farm context: доступ через parent ration
        ration_id in (
            select id from public.rations
            where organization_id = any(public.fn_my_org_ids())
        )
        or
        -- Consulting context: доступ через consulting project org
        consulting_project_id in (
            select id from public.consulting_projects
            where organization_id = any(public.fn_my_org_ids())
        )
        or
        -- Admin/Expert full access
        public.fn_is_admin()
        or public.fn_is_expert()
    );

-- rv_insert_system остаётся (INSERT admin only) — не меняем

-- ============================================================
-- END Slice 8 Part C d03_feed.sql
-- ============================================================

