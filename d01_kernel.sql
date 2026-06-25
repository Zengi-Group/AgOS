-- ============================================================
-- AGOS Schema: d01_kernel
-- Project: TURAN Agricultural Operating System
-- Consolidated: 2026-03-05 (pre-development baseline)
--
-- Identity + Farm + Platform domains.
-- Includes AI conversation infrastructure, audit, embedding queue.
--
-- Depends on: nothing — base migration
-- Consolidated from: 001_kernel__1_.sql, 009_patch_ai__1_.sql, 013_patch_audit.sql, 014_patch_sequence_and_lock.sql, 015_tech_debt.sql (kernel parts)
--
-- Convention: All statements are idempotent.
--   CREATE TABLE IF NOT EXISTS
--   CREATE OR REPLACE FUNCTION
--   ALTER TABLE ADD COLUMN IF NOT EXISTS
--   INSERT ... ON CONFLICT DO NOTHING
-- ============================================================
-- ============================================================
-- AGOS Migration 001: KERNEL
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 4 March 2026
--
-- Domains covered:
--   Identity  — 17 entities (D1–D11, D58)
--   Farm      —  7 entities (D18–D27, D49, D50, D54)
--   Platform  —  6 entities (D64–D72)
--   Total     — 30 tables + Reference data (4 tables)
--
-- Cross-checked against:
--   ✅ Dok 1 Domain Model Specification v1.2
--   ✅ Architecture Decision Record (D1–D89)
--   ✅ Universal Principles (P1–P12)
--   ✅ Ownership Matrix (Sections 4.1, 4.2, 4.8)
--   ✅ FSM Catalog (Section 5.7)
--   ✅ Enum Value Registry (Section 5.8)
--   ✅ Cross-Domain Integration Patterns (Section 5.1–5.4)
--   ✅ Legal Constraints (Section 5.9)
--
-- Depends on: nothing — base migration
-- Required by: 002_tsp.sql, 003_feed.sql, 004_platform_ai.sql,
--               005_vet.sql, 006_ops_edu.sql
--
-- Conventions:
--   - Table names: snake_case plural
--   - All PKs: uuid, gen_random_uuid()
--   - All timestamps: timestamptz (timezone-aware, stored as UTC)
--   - Append-only tables: no updated_at column
--   - Status FSMs: text + CHECK (not ENUM — easier to evolve, P7)
--   - Reference tables: seeded at migration time, editable by admin (P8)
--   - Soft-delete: is_active boolean (not deleted_at — simplifies RLS)
-- ============================================================

-- ============================================================
-- EXTENSIONS
-- ============================================================

create extension if not exists "uuid-ossp";       -- uuid_generate_v4() compatibility
create extension if not exists "pgcrypto";         -- gen_random_bytes for reference codes
create extension if not exists "vector";           -- pgvector: KnowledgeChunk embeddings (D70)
create extension if not exists btree_gist;         -- ADR-ANIMAL-01: EXCLUDE constraint for L2 mapping daterange overlap

-- ============================================================
-- SECTION 0: REFERENCE / LOOKUP TABLES
-- ============================================================
-- P8 (Standards as Data, Not Code): these values WILL change over time.
-- They live here as rows, not as hardcoded ENUMs or application constants.
-- Admin updates via INSERT/UPDATE — never requires code deployment.
--
-- 4 reference tables:
--   regions                  — Kazakhstan administrative hierarchy
--   productivity_directions  — meat / dairy / combined (D23)
--   animal_categories        — 12+ standardised animal types (D24, D49)
--   breeds                   — breed catalogue with productivity link (D23)
-- ============================================================

-- -------------------------------------------------------
-- regions
-- Identity domain (referenced by Organization, Farm, EpidemicSignal)
-- Hierarchical: country → oblast → rayon (self-referential, D from Dok1 ERD 3.1)
-- -------------------------------------------------------
create table if not exists public.regions (
    id          uuid        primary key default gen_random_uuid(),
    code        text        not null unique,   -- ISO-style: KZ, KZ-AKM, KZ-AKM-001
    name_ru     text        not null,
    name_kk     text,
    level       text        not null
                    check (level in ('country', 'oblast', 'rayon', 'city')),
    parent_id   uuid        references public.regions(id) on delete set null,
    is_active   boolean     not null default true,
    sort_order  int         not null default 0,
    created_at  timestamptz not null default now()
);
comment on table public.regions is
    'P8: Reference data. Managed by admin. Hierarchical: country > oblast > rayon.
     Self-join via parent_id. Dok1 ERD 3.1: Region |o--o{ Region.';
comment on column public.regions.parent_id is
    'null for country/oblast/city. Set to oblast.id for rayons.';

-- -------------------------------------------------------
-- productivity_directions
-- Farm domain reference (D23: breed_group derived from breed → direction)
-- -------------------------------------------------------
create table if not exists public.productivity_directions (
    id          uuid        primary key default gen_random_uuid(),
    code        text        not null unique,  -- meat | dairy | combined
    name_ru     text        not null,
    name_kk     text,
    sort_order  int         not null default 0,
    created_at  timestamptz not null default now()
);
comment on table public.productivity_directions is
    'D23: breed_group for TSP/Feed is DERIVED from breeds.productivity_direction_id.
     No separate breed_group field anywhere — one lookup chain. P8: admin-managed.';

-- -------------------------------------------------------
-- animal_categories
-- Farm + Feed + Market reference (D24: association standard, D49: 12+ unified types)
-- Ownership Matrix 4.2: Admin creates/updates/authority
-- -------------------------------------------------------
create table if not exists public.animal_categories (
    id                      uuid    primary key default gen_random_uuid(),
    code                    text    not null unique,   -- BULL_CALF, COW, HEIFER_PREG ...
    name_ru                 text    not null,
    name_kk                 text,
    sex                     text    not null
                                check (sex in ('male', 'female', 'mixed')),
    typical_age_min_months  int,    -- informational only, NOT enforced
    typical_age_max_months  int,    -- informational only, NOT enforced
    description_ru          text,
    is_active               boolean not null default true,
    sort_order              int     not null default 0,
    created_at              timestamptz not null default now()
);
comment on table public.animal_categories is
    'D24: Unified animal classification standard for AGOS (Farm + RationBuilder + TSP).
     D49: Expanded to 12+ types. P8: admin-managed. age_min/max informational only — 
     real age tracking is not in scope for group-level model (D20).';

-- -------------------------------------------------------
-- breeds
-- Farm domain reference (D23: links to productivity_direction)
-- Ownership Matrix 4.2: Admin creates/authority, Expert updates
-- -------------------------------------------------------
create table if not exists public.breeds (
    id                          uuid    primary key default gen_random_uuid(),
    productivity_direction_id   uuid    not null
                                    references public.productivity_directions(id),
    code        text    not null unique,   -- KAZ_WHITEHEAD, HEREFORD, ANGUS ...
    name_ru     text    not null,
    name_kk     text,
    name_en     text,
    is_local    boolean not null default false,  -- true = bred/developed in Kazakhstan
    is_active   boolean not null default true,
    sort_order  int     not null default 0,
    created_at  timestamptz not null default now()
);
comment on table public.breeds is
    'D23: productivity_direction_id is the authoritative source of "breed_group".
     All TSP and Feed lookups derive breed_group from this link — no denormalisation.
     P8: catalogue is admin-managed and grows over time.';

-- ============================================================
-- SECTION 1: IDENTITY DOMAIN (17 entities)
-- Decisions: D1–D11, D58
-- Ownership Matrix: Section 4.1
-- Legal: D7 (privacy), Section 5.9 (three-tier)
-- ============================================================

-- -------------------------------------------------------
-- users
-- Links to Supabase Auth (auth.users — managed by Supabase, never touched directly)
-- D5: Users exist independently of organizations (admins, experts have no org)
-- D6: User is created BEFORE Organization in onboarding flow
-- Ownership Matrix: Farmer C/U/A own data; Admin U; System C (auth)
-- -------------------------------------------------------
create table if not exists public.users (
    id                  uuid    primary key default gen_random_uuid(),
    auth_id             uuid    not null unique
                                    references auth.users(id) on delete cascade,
    phone               text    unique,   -- +77001234567 format; primary WhatsApp identifier
    email               text    unique,
    full_name           text,
    avatar_url          text,
    preferred_language  text    not null default 'ru'
                                    check (preferred_language in ('ru', 'kk', 'en')),
    is_active           boolean not null default true,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.users is
    'D5: Users exist independently of organizations — admins and experts have no org affiliation.
     D6: Created before Organization during onboarding. auth_id = Supabase Auth (never modify auth.users).
     phone is primary identifier for WhatsApp-based farmers (majority of users).';

-- -------------------------------------------------------
-- organizations
-- Legal entities: farms (КХ/ТОО/ИП), MPKs, others
-- D1: One org can be farmer AND MPK — handled via OrganizationTypeAssignment + Membership
-- D4: Restrictions applied at org level (blocks ALL participation types)
-- -------------------------------------------------------
create table if not exists public.organizations (
    id          uuid    primary key default gen_random_uuid(),
    legal_name  text    not null,
    bin_iin     text    unique,   -- БИН (12 digits) or ИИН; nullable on registration (D6/P11)
    legal_form  text
                    check (legal_form in (
                        'kh',           -- КХ — Крестьянское хозяйство (most farmers)
                        'ip',           -- ИП — Индивидуальный предприниматель
                        'too',          -- ТОО — Товарищество с ограниченной ответственностью
                        'ao',           -- АО — Акционерное общество
                        'individual',   -- Физическое лицо (no legal entity)
                        'other'
                    )),
    region_id   uuid    references public.regions(id),
    address_text    text,       -- free-form (village / rayon / district)
    phone           text,
    email           text,
    website         text,
    is_active   boolean     not null default true,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
comment on table public.organizations is
    'D1: Single org can be farmer + MPK — handled via OrganizationTypeAssignment (not a type field here).
     D4: RestrictionRecord.organization_id blocks ALL membership types simultaneously.
     bin_iin nullable: P11 gradual accumulation — farmers often register without БИН on day 1.';

-- -------------------------------------------------------
-- organization_type_assignments
-- D1: Separates "what type is this org" from membership level
-- Allows one org to have multiple types (farmer + mpk)
-- Ownership Matrix: Farmer C; Admin U/A
-- -------------------------------------------------------
create table if not exists public.organization_type_assignments (
    id              uuid    primary key default gen_random_uuid(),
    organization_id uuid    not null references public.organizations(id) on delete cascade,
    org_type        text    not null
                                check (org_type in ('farmer', 'mpk', 'supplier', 'consultant', 'other')),
    assigned_at     timestamptz not null default now(),
    assigned_by     uuid    references public.users(id),  -- admin who confirmed; null = self-assigned
    unique (organization_id, org_type)
);
comment on table public.organization_type_assignments is
    'D1: Separates type classification from membership level. Same org can be farmer + mpk
     via two rows. Farmer self-selects type on registration; Admin confirms.';

-- -------------------------------------------------------
-- user_organization_roles
-- Links users to organizations with permission role
-- D6: Created after both User and Organization exist
-- Ownership Matrix: Farmer C (owner); Admin U/A
-- -------------------------------------------------------
create table if not exists public.user_organization_roles (
    id              uuid    primary key default gen_random_uuid(),
    user_id         uuid    not null references public.users(id) on delete cascade,
    organization_id uuid    not null references public.organizations(id) on delete cascade,
    role            text    not null
                                check (role in (
                                    'owner',        -- full control (org creator)
                                    'manager',      -- can manage most things
                                    'employee',     -- limited write
                                    'viewer'        -- read-only
                                )),
    is_primary      boolean not null default false,  -- user's primary org for UI context
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    unique (user_id, organization_id)   -- one role per user per org
);
comment on table public.user_organization_roles is
    'Links users to organizations. is_primary=true = default org loaded in UI.
     A user may belong to multiple orgs (e.g. employee working for two farms).
     Owner role created automatically when user creates the org.';

-- -------------------------------------------------------
-- memberships
-- D1: One Membership record per (organization_id + org_type)
-- D2: FSM transitions differ by org_type
-- D3: level=registered means platform user, NOT association member
-- FSM Catalog 5.7:
--   Farmer:  registered → observer → declared_supplier → standard_supplier
--   MPK:     registered → observer → active_buyer
--   Others:  registered → observer
-- -------------------------------------------------------
create table if not exists public.memberships (
    id              uuid    primary key default gen_random_uuid(),
    organization_id uuid    not null references public.organizations(id) on delete cascade,
    org_type        text    not null
                                check (org_type in ('farmer', 'mpk', 'supplier', 'consultant', 'other')),
    level           text    not null default 'registered'
                                check (level in (
                                    'registered',           -- D3: platform user ≠ association member
                                    'observer',             -- first real membership level
                                    'declared_supplier',    -- farmer: verified + TSP agreement signed
                                    'standard_supplier',    -- farmer: delivery history (admin decision)
                                    'active_buyer'          -- mpk: verified + active
                                )),
    previous_level  text,           -- lightweight audit (no separate history table for now, Q6)
    level_changed_at    timestamptz not null default now(),
    level_changed_by    uuid    references public.users(id),  -- admin who triggered transition
    notes               text,   -- reason for level change (required on downgrade)
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    unique (organization_id, org_type)  -- D1: exactly one record per org+type
);
comment on table public.memberships is
    'D1: One record per (organization, org_type). D2: FSM per org_type (see constraint below).
     D3: level=registered means signed up on platform but NOT yet an association member.
     Transitions managed by Admin via RPC (Dok 3). AI Gateway reads only.';

-- FSM integrity: valid level per org_type (D2)
-- Farmer has 4 levels; MPK has 3; others have 2
create or replace function public.fn_membership_level_valid(p_org_type text, p_level text)
returns boolean language plpgsql immutable security definer
set search_path = public, pg_temp as $$
begin
    return case p_org_type
        when 'farmer'   then p_level in ('registered','observer','declared_supplier','standard_supplier')
        when 'mpk'      then p_level in ('registered','observer','active_buyer')
        else                 p_level in ('registered','observer')
    end;
end;
$$;

do $$ begin
    if not exists (select 1 from pg_constraint where conname = 'memberships_level_valid_for_type') then
        alter table public.memberships
            add constraint memberships_level_valid_for_type
            check (public.fn_membership_level_valid(org_type, level));
    end if;
end $$;

-- -------------------------------------------------------
-- membership_applications
-- FSM 5.7: submitted → under_review → approved | rejected
-- Ownership Matrix: Farmer C; Admin U/A (review)
-- -------------------------------------------------------
create table if not exists public.membership_applications (
    id              uuid    primary key default gen_random_uuid(),
    membership_id   uuid    not null references public.memberships(id) on delete cascade,
    organization_id uuid    not null references public.organizations(id),  -- denorm for RLS
    from_level      text    not null,
    to_level        text    not null,
    status          text    not null default 'submitted'
                                check (status in ('submitted','under_review','approved','rejected')),
    submitted_at    timestamptz not null default now(),
    reviewed_at     timestamptz,
    reviewed_by     uuid    references public.users(id),
    reviewer_notes  text,
    supporting_docs jsonb,  -- [{name, url, doc_type}] uploaded supporting documents
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.membership_applications is
    'FSM 5.7: submitted → under_review → approved | rejected.
     Farmer submits, Admin reviews. supporting_docs = array of Supabase Storage URLs.
     On approval: статус заявки → approved (членство НЕ выдаётся). Уровень членства
     выдаётся ОПЛАТОЙ взноса — rpc_pay_membership_dues (см. миграцию membership_purchase_flow).';

-- -------------------------------------------------------
-- verification_records
-- Admin creates and is sole authority
-- D22: ИСЖ used for LEGAL verification only, not for operational herd data
-- Append-only: never UPDATE — create new record for re-verification
-- -------------------------------------------------------
create table if not exists public.verification_records (
    id                  uuid    primary key default gen_random_uuid(),
    membership_id       uuid    not null references public.memberships(id) on delete cascade,
    organization_id     uuid    not null references public.organizations(id),  -- denorm for RLS
    verification_type   text    not null
                                    check (verification_type in (
                                        'bin_iin_check',    -- legal entity lookup
                                        'isz_check',        -- D22: ИСЖ livestock registry
                                        'site_visit',       -- physical farm inspection
                                        'document_review',  -- document audit
                                        'reputation_check'  -- delivery history review
                                    )),
    result              text    not null
                                    check (result in ('approved','rejected','conditional')),
    verified_by         uuid    not null references public.users(id),  -- admin/expert
    verified_at         timestamptz not null default now(),
    notes               text,
    document_url        text,   -- verification report (Supabase Storage)
    expires_at          timestamptz,    -- some verifications expire (e.g. site visit = 2 years)
    created_at          timestamptz not null default now()
    -- No updated_at: APPEND-ONLY. New row for each re-verification.
);
comment on table public.verification_records is
    'D22: ИСЖ verification is for legal compliance, NOT operational herd data source.
     APPEND-ONLY: never UPDATE existing record — create new row for re-verification.
     Admin is sole Authority (Ownership Matrix 4.1).';

-- -------------------------------------------------------
-- consent_records
-- System creates and is sole authority. Immutable legal record.
-- P11: users consent gradually (privacy first, marketing later)
-- Append-only
-- -------------------------------------------------------
create table if not exists public.consent_records (
    id              uuid    primary key default gen_random_uuid(),
    user_id         uuid    not null references public.users(id) on delete cascade,
    consent_type    text    not null
                                check (consent_type in (
                                    'terms_of_service',
                                    'privacy_policy',
                                    'data_processing',      -- GDPR-equivalent KZ law
                                    'whatsapp_messaging',   -- WhatsApp opt-in (required by Meta)
                                    'marketing'
                                )),
    version         text    not null,   -- document version e.g. '2026-03-01'
    consented       boolean not null,   -- true=accepted, false=revoked
    consented_at    timestamptz not null default now(),
    ip_address      inet,
    user_agent      text
    -- No updated_at: APPEND-ONLY. New row for each change (consent or revocation).
);
comment on table public.consent_records is
    'Legal record of user consent. APPEND-ONLY: new row per change.
     System creates (Authority). consented=false = explicit revocation.
     whatsapp_messaging consent required before AI Gateway sends messages.';

-- -------------------------------------------------------
-- agreement_acceptances
-- Farmer accepts voluntarily (Tier 2 legal architecture, Section 5.9)
-- D7: tied to Organization (agreement is business), signed by specific User
-- Append-only
-- -------------------------------------------------------
create table if not exists public.agreement_acceptances (
    id                  uuid    primary key default gen_random_uuid(),
    membership_id       uuid    not null references public.memberships(id) on delete cascade,
    user_id             uuid    not null references public.users(id),  -- who clicked/signed
    organization_id     uuid    not null references public.organizations(id),  -- denorm for RLS
    agreement_type      text    not null
                                    check (agreement_type in (
                                        'tsp_participation',    -- required for declared_supplier
                                        'data_sharing',         -- aggregate anonymisation consent
                                        'quality_standards',    -- accepting Tier 3 standards
                                        'association_charter'   -- association membership
                                    )),
    agreement_version   text    not null,   -- version of the legal document
    document_url        text,               -- signed PDF (Supabase Storage)
    accepted_at         timestamptz not null default now(),
    ip_address          inet,
    created_at          timestamptz not null default now()
    -- No updated_at: APPEND-ONLY.
);
comment on table public.agreement_acceptances is
    'Tier 2 legal: voluntary coordination agreements (Section 5.9).
     APPEND-ONLY. D7: Agreement binds Organization; User signs on behalf.
     tsp_participation required for Membership.level = declared_supplier.';

-- -------------------------------------------------------
-- restriction_records
-- D4: Restriction on Organization blocks ALL org_types simultaneously
-- Admin creates and lifts. Active restriction = lifted_at IS NULL
-- -------------------------------------------------------
create table if not exists public.restriction_records (
    id                  uuid    primary key default gen_random_uuid(),
    organization_id     uuid    not null references public.organizations(id) on delete cascade,
    restriction_type    text    not null
                                    check (restriction_type in (
                                        'suspended',        -- temporary suspension
                                        'banned',           -- permanent ban
                                        'payment_hold',     -- unpaid membership dues
                                        'compliance_hold'   -- compliance violation
                                    )),
    reason              text    not null,
    created_by          uuid    not null references public.users(id),  -- admin
    created_at          timestamptz not null default now(),
    lifted_at           timestamptz,    -- null = restriction is ACTIVE
    lifted_by           uuid    references public.users(id),
    lift_reason         text
);
comment on table public.restriction_records is
    'D4: One restriction blocks farmer AND mpk roles for same org simultaneously.
     Active restriction = lifted_at IS NULL. Admin is sole Authority.
     RLS helper function checks this before granting access to TSP, Farm, etc.';

-- -------------------------------------------------------
-- admin_roles
-- D5: Association staff — Users without organization affiliation
-- Ownership Matrix 4.1: Admin C/U/A (super_admin only)
-- -------------------------------------------------------
create table if not exists public.admin_roles (
    id          uuid    primary key default gen_random_uuid(),
    user_id     uuid    not null unique references public.users(id) on delete cascade,
    role        text    not null
                            check (role in (
                                'super_admin',          -- full platform access
                                'membership_admin',     -- onboarding, membership transitions
                                'tsp_admin',            -- pool management, matching
                                'content_admin',        -- knowledge base, education
                                'support'               -- read-only + notifications
                            )),
    granted_by  uuid    references public.users(id),   -- super_admin who granted
    granted_at  timestamptz not null default now(),
    is_active   boolean not null default true,
    created_at  timestamptz not null default now()
);
comment on table public.admin_roles is
    'D5: Association staff. No org affiliation. Super_admin is sole granter.
     is_active=false = soft revoke (keeps history). Ownership Matrix 4.1.';

-- -------------------------------------------------------
-- external_system_links
-- D8: ERP and external systems are LINKED, not merged
-- Layered Truth integration point (Section 5.4)
-- -------------------------------------------------------
create table if not exists public.external_system_links (
    id                  uuid    primary key default gen_random_uuid(),
    organization_id     uuid    not null references public.organizations(id) on delete cascade,
    system_type         text    not null
                                    check (system_type in (
                                        'erp',          -- farm ERP (1C, custom) — Layered Truth L4
                                        'egistic',      -- Egistic satellite monitoring
                                        'dalacamp',     -- external education platform
                                        'isz',          -- ИСЖ government registry (D22)
                                        'other'
                                    )),
    system_name         text,   -- e.g. "1C:Agro", "Custom ERP v2"
    external_org_id     text,   -- org's identifier in the external system
    api_endpoint        text,
    sync_status         text    default 'not_configured'
                                    check (sync_status in (
                                        'active','error','paused','not_configured'
                                    )),
    last_sync_at        timestamptz,
    sync_config         jsonb,  -- system-specific config (sensitive fields encrypted at app layer)
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    unique (organization_id, system_type)
);
comment on table public.external_system_links is
    'D8: Do NOT merge external data — link it. ERP = L4 Layered Truth source (highest confidence).
     sync_config JSONB: API keys encrypted at application layer before storage.
     unique(org, system_type): one ERP per farm, one ISZ per farm etc.';

-- -------------------------------------------------------
-- payments
-- D11: Payment → Organization (legal entity pays fees)
-- System creates and is Authority (Ownership Matrix 4.1)
-- -------------------------------------------------------
create table if not exists public.payments (
    id                  uuid    primary key default gen_random_uuid(),
    organization_id     uuid    not null references public.organizations(id),
    payment_type        text    not null
                                    check (payment_type in (
                                        'membership_fee',   -- annual association dues
                                        'entrance_fee',     -- one-time entry fee
                                        'course_payment',   -- education (links to purchased_products)
                                        'other'
                                    )),
    amount              numeric(12,2) not null check (amount >= 0),
    currency            text    not null default 'KZT',
    status              text    not null default 'pending'
                                    check (status in ('pending','completed','failed','refunded')),
    payment_method      text    check (payment_method in (
                                    'bank_transfer','card','cash','manual'
                                )),
    reference_number    text    unique,     -- bank / payment gateway reference
    description         text,
    paid_at             timestamptz,        -- null until status = completed
    created_by          uuid    references public.users(id),  -- admin who registered
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.payments is
    'D11: Payment belongs to Organization (legal entity), not User.
     System creates on payment gateway callback (Authority).
     Admin can create manual entries (bank_transfer, cash).';

-- -------------------------------------------------------
-- purchased_products
-- D11: PurchasedProduct → User (knowledge/access belongs to person)
-- D9: Course enrollment by User, not Organization
-- System creates on payment completion (Authority)
-- -------------------------------------------------------
create table if not exists public.purchased_products (
    id              uuid    primary key default gen_random_uuid(),
    user_id         uuid    not null references public.users(id) on delete cascade,
    payment_id      uuid    references public.payments(id),
    product_type    text    not null
                                check (product_type in ('course','tool','report','other')),
    product_id      uuid    not null,   -- polymorphic: course_id when product_type='course'
    product_ref     text    not null,   -- table name: 'courses', 'tools' — for polymorphic joins
    expires_at      timestamptz,        -- null = no expiry (lifetime access)
    created_at      timestamptz not null default now()
    -- No updated_at: append-only (access is granted, not modified)
);
comment on table public.purchased_products is
    'D11: Belongs to User, not Organization. D9: Course access is personal.
     product_id + product_ref = polymorphic FK pattern (FK constraint added per module).
     System creates on payment completion. expires_at null = lifetime access.';

-- -------------------------------------------------------
-- expert_profiles
-- D5: Expert = User + ExpertProfile (no org affiliation)
-- D58: Extended with consultation metrics
-- Serves: Vet escalation (Dok1 4.5), Farm ops (4.6), Education (4.7)
-- -------------------------------------------------------
create table if not exists public.expert_profiles (
    id                          uuid    primary key default gen_random_uuid(),
    user_id                     uuid    not null unique
                                            references public.users(id) on delete cascade,
    specialization              text    not null
                                            check (specialization in (
                                                'veterinarian',
                                                'zootechnician',
                                                'agronomist',
                                                'market_analyst',
                                                'legal',
                                                'general'
                                            )),
    qualification_text          text,   -- credentials, degrees (free-form, P11 gradual)
    region_ids                  uuid[], -- regions served (null = all Kazakhstan)
    is_staff                    boolean not null default true,   -- false = external/contractor
    is_active                   boolean not null default true,
    available_for_consultation  boolean not null default true,
    -- D58: Performance metrics (updated by system after each consultation)
    avg_response_minutes        int,    -- rolling average (NULL until first consultation)
    total_consultations         int     not null default 0,
    created_at                  timestamptz not null default now(),
    updated_at                  timestamptz not null default now()
);
comment on table public.expert_profiles is
    'D5: Association experts — no org affiliation.
     D58: avg_response_minutes and total_consultations updated by system for SLA monitoring.
     region_ids = UUID[] of regions.id — null means serves all KZ.
     Cross-domain: used by Vet (escalation), Operations (plan consult), Education (instructor).';

-- -------------------------------------------------------
-- consultation_requests
-- D58: Extended with vet_case_id + SLA tracking
-- FSM 5.7: pending → assigned → in_progress → completed
-- Source enum (Section 5.8): direct | ai_referral | auto_escalation
-- NOTE: vet_case_id FK constraint added in 005_vet.sql (cross-domain)
-- -------------------------------------------------------
create table if not exists public.consultation_requests (
    id                      uuid    primary key default gen_random_uuid(),
    organization_id         uuid    not null references public.organizations(id),
    expert_profile_id       uuid    references public.expert_profiles(id),  -- null until assigned
    specialization_needed   text    not null
                                        check (specialization_needed in (
                                            'veterinarian','zootechnician','agronomist',
                                            'market_analyst','legal','general'
                                        )),
    source                  text    not null
                                        check (source in (
                                            'direct',           -- farmer requests directly
                                            'ai_referral',      -- AI recommends expert (Section 5.8)
                                            'auto_escalation'   -- system auto-escalates critical VetCase
                                        )),
    status                  text    not null default 'pending'
                                        check (status in (
                                            'pending',      -- created, not yet assigned
                                            'assigned',     -- expert_profile_id set
                                            'in_progress',  -- expert accepted / started
                                            'completed'     -- resolution provided
                                        )),
    priority                text    not null default 'normal'
                                        check (priority in ('low','normal','high','critical')),
    description             text,   -- farmer's description or AI summary
    resolution_text         text,   -- expert's resolution (populated on completed)
    -- D58: Cross-domain link to VetCase (FK added in 005_vet.sql)
    vet_case_id             uuid,
    -- D58: SLA tracking
    sla_minutes             int,            -- target: assigned within N minutes
    sla_breached            boolean not null default false,
    sla_breached_at         timestamptz,
    -- FSM timestamps (set by RPC on each transition)
    assigned_at             timestamptz,
    started_at              timestamptz,
    completed_at            timestamptz,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now()
);
comment on table public.consultation_requests is
    'FSM 5.7: pending → assigned → in_progress → completed.
     D58: vet_case_id column here; FK constraint added in 005_vet.sql (avoids circular dep).
     SLA: sla_minutes set on assignment. Cron checks for breach (Dok 4).
     Source enum 5.8: direct | ai_referral | auto_escalation.';
comment on column public.consultation_requests.vet_case_id is
    'D58: References vet_cases.id. FK constraint intentionally deferred to 005_vet.sql
     to avoid circular dependency. Column is nullable (not all requests are vet-related).';

-- ============================================================
-- SECTION 2: FARM DOMAIN (7 entities)
-- 3 reference tables already created above: animal_categories, breeds,
--   productivity_directions
-- 4 operational tables: farms, farm_activity_types, herd_groups, herd_events
-- Decisions: D18–D27, D49, D50, D54
-- Ownership Matrix: Section 4.2
-- ============================================================

-- -------------------------------------------------------
-- farms
-- D18: Organization → many → Farm (5% case: multiple locations)
-- D54: shelter_type and calving_system are FARM properties (location), not group
-- D26: Farm infrastructure (barns, paddocks) deferred — no consumer yet (P11)
-- Ownership Matrix: Farmer C/U/A; Admin R; Expert R
-- -------------------------------------------------------
create table if not exists public.farms (
    id              uuid    primary key default gen_random_uuid(),
    organization_id uuid    not null references public.organizations(id) on delete cascade,
    name            text    not null,   -- farm name or location description
    region_id       uuid    references public.regions(id),
    address_text    text,               -- village / district / GPS as text
    -- D54: Location properties (not group-level)
    shelter_type    text    check (shelter_type in (
                                'stall',        -- стойловое (year-round indoor)
                                'pasture',      -- пастбищное (open range)
                                'mixed',        -- смешанное: stall in winter, pasture in summer
                                'feedlot'       -- откормочная площадка
                            )),
    calving_system  text    check (calving_system in (
                                'spring',       -- весенний отёл (March–May)
                                'autumn',       -- осенний отёл (Sep–Nov)
                                'year_round',   -- круглогодичный
                                'two_season'    -- весна + осень
                            )),
    total_area_ha   numeric(10,2),  -- total farm area (informational, P11)
    pasture_area_ha numeric(10,2),  -- grazing area (informational, P11)
    -- D21: Layered Truth — track how this farm's data was entered
    data_source     text    not null default 'platform'
                                check (data_source in (
                                    'registration',     -- L1: initial registration form
                                    'ai_extracted',     -- L2: from WhatsApp conversation
                                    'platform',         -- L3: manually entered in web cabinet
                                    'erp'               -- L4: synced from ERP (highest confidence)
                                )),
    is_primary      boolean not null default true,  -- primary farm for this org
    is_active       boolean not null default true,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.farms is
    'D18: org can own multiple farms (5% of users have 2+ locations).
     D54: shelter_type and calving_system are location properties — same for all groups on this farm.
     D26: Infrastructure (barns, paddocks, fields) deferred — no clear consumer until Ops module (P11).
     is_primary=true marks default farm for single-farm orgs.';

-- -------------------------------------------------------
-- farm_activity_types
-- D19: Separate table (not enum array in farms) — farm can combine activity types
-- E.g. a farm doing both cow_calf AND finishing is valid and common
-- -------------------------------------------------------
create table if not exists public.farm_activity_types (
    id              uuid    primary key default gen_random_uuid(),
    farm_id         uuid    not null references public.farms(id) on delete cascade,
    activity_type   text    not null
                                check (activity_type in (
                                    'cow_calf',     -- коровье-телячье производство
                                    'finishing',    -- откорм (fattening)
                                    'dairy',        -- молочное производство
                                    'breeding',     -- племенное (genetic improvement)
                                    'mixed'         -- многопрофильное
                                )),
    is_primary      boolean not null default false,
    created_at      timestamptz not null default now(),
    unique (farm_id, activity_type)
);
comment on table public.farm_activity_types is
    'D19: Farm can combine cow_calf + finishing — separate rows, not an array field.
     Separate table enables querying "all finishing farms in Kostanay oblast" efficiently.
     is_primary=true marks dominant activity for UI display.';

-- -------------------------------------------------------
-- herd_groups
-- THE core Farm Graph entity. AGOS operates at THIS level.
-- D20: AGOS = group level. ERP = individual animal level. Boundary is explicit.
-- D21: Layered Truth with data_source + confidence (see Section 5.4)
-- D27: RationBuilder calculation params NOT here (clean Farm/Feed separation)
-- D49: Uses animal_categories (12+ unified types)
-- Principle 3 (Granularity): groups are the right level — can aggregate up (totals)
--   but cannot disaggregate down without ERP data
-- Ownership Matrix 4.2:
--   Farmer: C/U (L3), AI: C/U (L2 extract), ERP: U/A (L4), System: C (L1 reg)
-- -------------------------------------------------------
create table if not exists public.herd_groups (
    id                  uuid    primary key default gen_random_uuid(),
    farm_id             uuid    not null references public.farms(id) on delete cascade,
    organization_id     uuid    not null references public.organizations(id),  -- denorm for RLS
    animal_category_id  uuid    not null references public.animal_categories(id),
    breed_id            uuid    references public.breeds(id),  -- nullable: mixed or unknown
    -- Current state (P12 Temporal: current-state table. History = herd_events)
    head_count          int     not null default 0 check (head_count >= 0),
    avg_weight_kg       numeric(6,2) check (avg_weight_kg > 0 and avg_weight_kg < 2000),
    -- D21: Layered Truth (Section 5.4)
    data_source         text    not null default 'registration'
                                    check (data_source in (
                                        'registration',   -- L1: rough number from join form
                                        'ai_extracted',   -- L2: from WhatsApp (draft, unvalidated)
                                        'platform',       -- L3: farmer manually confirmed
                                        'erp'             -- L4: synced from ERP (authoritative)
                                    )),
    confidence          int     not null default 25
                                    check (confidence between 0 and 100),
    -- Temporal precision
    weight_updated_at   timestamptz,    -- when avg_weight_kg was last set
    count_updated_at    timestamptz,    -- when head_count was last set
    notes               text,
    is_active           boolean not null default true,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.herd_groups is
    'D20: AGOS operates at group level. ERP handles individual animals.
     D21: Layered Truth — data_source + confidence. L1(25%) < L2(50%) < L3(75%) < L4(95%).
     Higher confidence source wins on conflict. System useful at ANY confidence level (P11).
     D27: avg_weight_kg and head_count ARE here (needed for ration input). But calculation
       params (ration objective, shelter override) belong in Ration entity, not here.
     D49: animal_category_id links to unified 12+ type catalogue.
     breed_id nullable: mixed herds are normal in KZ. breed→productivity_direction = breed_group (D23).';
comment on column public.herd_groups.confidence is
    'D21: 0-100 confidence scale. Default values: registration=25, ai_extracted=50,
     platform=75, erp=95. Used by AI Gateway to display data quality to farmers.';
comment on column public.herd_groups.breed_id is
    'Nullable: mixed herd or breed not yet identified.
     When set: breeds.productivity_direction_id → productivity_directions.code = breed_group.
     This chain replaces any separate breed_group field (D23).';

-- -------------------------------------------------------
-- herd_events
-- D25: APPEND-ONLY changelog for all herd changes
-- D50: Merged with GroupLifecycleEvent — one unified journal
-- Enum values from Section 5.8 (17 event types)
-- Principle 12 (Temporal): herd_groups = current state; herd_events = history
-- -------------------------------------------------------
create table if not exists public.herd_events (
    id              uuid    primary key default gen_random_uuid(),
    farm_id         uuid    not null references public.farms(id),
    organization_id uuid    not null references public.organizations(id),  -- denorm for RLS
    -- D50: herd_group_id nullable — some events are farm-level (calving_start, stall_start)
    herd_group_id   uuid    references public.herd_groups(id) on delete set null,
    -- D50 + Section 5.8: Complete 17-type enum (merged from HerdEvent + GroupLifecycleEvent)
    event_type      text    not null
                                check (event_type in (
                                    'head_count_change',  -- heads added or removed (manual/AI/ERP)
                                    'weight_update',      -- avg weight changed
                                    'group_created',      -- new HerdGroup added to farm
                                    'group_removed',      -- HerdGroup deactivated
                                    'birth',              -- calving event (births this period)
                                    'death',              -- mortality (deaths this period)
                                    'sale',               -- animals sold → links to TSP Batch
                                    'purchase',           -- animals purchased
                                    'calving_start',      -- calving season begins (farm-level)
                                    'calving_end',        -- calving season ends
                                    'weaning',            -- calves separated from cows
                                    'breeding_start',     -- breeding season begins
                                    'breeding_end',       -- breeding season ends
                                    'stall_start',        -- moved to stall (winter housing)
                                    'stall_end',          -- left stall
                                    'pasture_start',      -- moved to pasture
                                    'pasture_end'         -- left pasture
                                )),
    value_before    numeric(10,2),  -- numeric value before event (head count or kg weight)
    value_after     numeric(10,2),  -- numeric value after event
    -- Generated column: delta computed automatically (never manually set)
    delta           numeric(10,2)
                        generated always as (value_after - value_before) stored,
    event_date      date    not null default current_date,
    data_source     text    not null default 'platform'
                                check (data_source in (
                                    'registration','ai_extracted','platform','erp'
                                )),
    recorded_by     uuid    references public.users(id),  -- null if system/ERP
    notes           text,
    -- Extensible metadata for event-specific data
    metadata        jsonb,  -- e.g. {batch_id: "uuid"} for sale events; {vet_case_id} for deaths
    created_at      timestamptz not null default now()
    -- No updated_at: APPEND-ONLY (D25). Never UPDATE this table.
);
comment on table public.herd_events is
    'D25: Append-only changelog — NEVER UPDATE, only INSERT.
     D50: Merged with GroupLifecycleEvent into one unified journal per farm.
     herd_group_id nullable: farm-level events (calving_start, stall_start) have no group.
     delta generated column: positive = increase, negative = decrease.
     metadata JSONB: sale events include {batch_id}, death events may include {vet_case_id}.
     Data Flywheel (Section 5.3): each event enriches analytics and TSP supply prediction.';
comment on column public.herd_events.metadata is
    'Event-specific context. Examples:
     sale:          {batch_id: "uuid", price_per_kg: 1500}
     death:         {vet_case_id: "uuid", cause: "disease|accident|unknown"}
     birth:         {father_breed_id: "uuid"}
     head_count_change: {source_group_id: "uuid"} if transfer between groups';

-- ============================================================
-- SECTION 3: PLATFORM DOMAIN (6 entities)
-- Decisions: D64–D72
-- Ownership Matrix: Section 4.8
-- ============================================================

-- -------------------------------------------------------
-- ai_conversations
-- D64: One conversation = 24h WhatsApp session window
-- D7: Conversation is PRIVATE to User; extracted facts go to Organization
-- D72: Token/cost tracking per conversation for monitoring
-- Ownership Matrix: AI Gateway C/U/A
-- -------------------------------------------------------
create table if not exists public.ai_conversations (
    id                      uuid    primary key default gen_random_uuid(),
    organization_id         uuid    not null references public.organizations(id),
    user_id                 uuid    not null references public.users(id),
    channel                 text    not null default 'whatsapp'
                                        check (channel in ('whatsapp','web','mobile')),
    -- DEF-SQL-RESERVED-01 (2026-04-17): `current_role` is a reserved word (refers to
     -- pg_catalog.current_role()). Un-quoted it breaks `CREATE TABLE` re-apply with
     -- `syntax error at or near "current_role"`. Quoted as an identifier everywhere
     -- so the file can be re-applied idempotently. Column name in DB is unchanged,
     -- so no data migration required.
    "current_role"          text    not null default 'consultant'
                                        check ("current_role" in (
                                            'zootechnician',    -- feed/ration queries
                                            'veterinarian',     -- health/disease queries
                                            'consultant',       -- general association queries
                                            'trading_agent'     -- TSP/market queries
                                        )),
    -- Context snapshot at conversation start (prevents mid-session drift)
    farm_context_snapshot   jsonb,  -- {farm_id, herd_groups: [...], recent_events: [...]}
    -- D64: 24h window
    session_started_at      timestamptz not null default now(),
    session_expires_at      timestamptz not null
                                default (now() + interval '24 hours'),
    -- State
    message_count           int     not null default 0,
    is_active               boolean not null default true,
    -- D72: Token and cost tracking
    total_input_tokens      int     not null default 0,
    total_output_tokens     int     not null default 0,
    total_cost_usd          numeric(10,6) not null default 0,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now()
);
comment on table public.ai_conversations is
    'D64: Session = 24h WhatsApp conversation window. On window expiry, new conversation created.
     D7: Conversation private to User. farm_context_snapshot = what AI "knew" at session start.
     D72: token/cost tracked per conversation for budget monitoring and optimization.
     current_role = last determined role (changes per message via intent detection in AI Gateway).';

-- -------------------------------------------------------
-- ai_messages
-- D65: Messages logged here. Extracted entities are DRAFTS only.
--      Actual writes to Farm Graph happen ONLY via validated RPC (prevents hallucinations)
-- D72: Latency tracked per message
-- Append-only
-- -------------------------------------------------------
create table if not exists public.ai_messages (
    id                  uuid    primary key default gen_random_uuid(),
    conversation_id     uuid    not null references public.ai_conversations(id) on delete cascade,
    role                text    not null
                                    check (role in (
                                        'user',       -- farmer's message
                                        'assistant',  -- AI response
                                        'system',     -- system prompt injection
                                        'tool'        -- tool call result
                                    )),
    content_type        text    not null default 'text'
                                    check (content_type in (
                                        'text',         -- standard text
                                        'voice',        -- voice message (transcribed)
                                        'image',        -- photo (analysed by Vision)
                                        'document',     -- PDF/file
                                        'tool_call',    -- AI calling an RPC function
                                        'tool_result'   -- RPC function response
                                    )),
    content_text        text,   -- final text (transcribed for voice, described for image)
    content_url         text,   -- Supabase Storage URL for voice/image/document
    -- D65: Tool calls logged; Farm Graph writes happen via RPC only
    tool_calls          jsonb,  -- [{name, arguments, result, rpc_called}]
    -- D65: Extracted entities are UNVALIDATED DRAFTS
    extracted_entities  jsonb,  -- {herd_groups: [...], feed_inventory: [...]} — DRAFT state
    -- D72: AI performance metrics
    model_used          text,   -- e.g. "claude-sonnet-4-6", "claude-haiku-4-5"
    input_tokens        int,
    output_tokens       int,
    latency_ms          int,
    sequence_number     int     not null,   -- message order within conversation (1-based)
    created_at          timestamptz not null default now()
    -- No updated_at: APPEND-ONLY
);
comment on table public.ai_messages is
    'D65: CRITICAL — extracted_entities are DRAFTS. They are logged here but NEVER directly
     written to herd_groups, farm_feed_inventory etc. All Farm Graph writes go through
     validated RPC functions that verify the data makes sense (Dok 3).
     This prevents hallucination-driven data corruption (Data Flywheel integrity).
     Append-only. tool_calls JSONB records which RPCs were called with what params.';
comment on column public.ai_messages.extracted_entities is
    'D65: UNVALIDATED DRAFT extracted from conversation.
     Example: {herd_groups: [{category: "BULL_CALF", count: 80, confidence: 0.9}]}
     These must be reviewed (or auto-confirmed if confidence > threshold) via
     RPC rpc_validate_and_apply_extracted_entities (Dok 3) before touching herd_groups.';

-- -------------------------------------------------------
-- platform_events
-- D66: Namespaced event_type: domain.entity.action
-- D67: Phase 1 = consumers POLL this table (no Realtime subscription needed yet)
-- 27 event types defined in Dok 1 Section 5.5
-- Append-only event log
-- -------------------------------------------------------
create table if not exists public.platform_events (
    id              uuid    primary key default gen_random_uuid(),
    -- D66: namespace format: 'domain.entity.action'
    -- Examples: 'farm.herd_group.updated', 'market.batch.published'
    event_type      text    not null,
    entity_type     text    not null,   -- table name: 'herd_groups', 'batches' etc
    entity_id       uuid,               -- id of the affected row
    organization_id uuid    references public.organizations(id),  -- for consumer filtering
    actor_type      text    not null
                                check (actor_type in (
                                    'farmer','admin','expert','system','ai_gateway'
                                )),
    actor_id        uuid,               -- user_id or null for system/cron
    payload         jsonb,              -- event-specific data: {before: {}, after: {}, meta: {}}
    created_at      timestamptz not null default now()
    -- No updated_at: APPEND-ONLY event log
);
comment on table public.platform_events is
    'D66: Events namespaced as domain.entity.action (e.g. farm.herd_group.updated).
     D67: Phase 1 consumers POLL by event_type + created_at. Realtime subscription in Phase 2.
     27 event types (Section 5.5). All domain-significant state changes publish here.
     This IS the Event Bus at Phase 1 scale (50-500 farmers). No separate queue needed.
     Append-only. Partition by created_at at >1M rows (Dok 4 scope).';

-- -------------------------------------------------------
-- notifications
-- D68: WhatsApp + in-app ONLY (no email, no SMS — decision is final)
-- System and AI Gateway create notifications
-- Ownership Matrix 4.8: System C/A; AI Gateway C (proactive)
-- -------------------------------------------------------
create table if not exists public.notifications (
    id                  uuid    primary key default gen_random_uuid(),
    user_id             uuid    not null references public.users(id) on delete cascade,
    organization_id     uuid    not null references public.organizations(id),  -- denorm for RLS
    -- D68: Two channels only
    channel             text    not null
                                    check (channel in ('whatsapp','in_app')),
    template_id         text    not null,   -- e.g. 'batch_matched', 'vaccination_reminder'
    params              jsonb,              -- template variable substitution
    delivery_status     text    not null default 'pending'
                                    check (delivery_status in (
                                        'pending',      -- queued
                                        'sent',         -- dispatched to channel
                                        'delivered',    -- confirmed delivery (WhatsApp read receipt)
                                        'failed',       -- delivery failed
                                        'read'          -- user read (in-app)
                                    )),
    -- Triggering context
    platform_event_id   uuid    references public.platform_events(id),
    scheduled_for       timestamptz,    -- null = send immediately; set for scheduled alerts
    sent_at             timestamptz,
    delivered_at        timestamptz,
    read_at             timestamptz,
    failure_reason      text,
    retry_count         int     not null default 0,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.notifications is
    'D68: WhatsApp + in-app only. No email, no SMS (final architectural decision).
     template_id + params: all notifications are template-based (no free-form messages from system).
     scheduled_for: used for proactive alerts (vaccination reminders, weather-triggered).
     platform_event_id: traceability — which event triggered this notification.';

-- -------------------------------------------------------
-- audit_log
-- D69: BUSINESS-CRITICAL actions only — NOT a full row-level changelog
-- Auto-populated from platform_events trigger (Dok 4)
-- Append-only
-- -------------------------------------------------------
create table if not exists public.audit_log (
    id              uuid    primary key default gen_random_uuid(),
    user_id         uuid    references public.users(id) on delete set null,  -- null = system
    actor_type      text    not null
                                check (actor_type in (
                                    'farmer','admin','expert','system','ai_gateway'
                                )),
    action          text    not null,   -- e.g. 'membership.level_changed', 'batch.published'
    entity_type     text    not null,   -- table name
    entity_id       uuid,
    organization_id uuid    references public.organizations(id),
    changes         jsonb,              -- {before: {...}, after: {...}} snapshot
    ip_address      inet,
    created_at      timestamptz not null default now()
    -- No updated_at: APPEND-ONLY
);
comment on table public.audit_log is
    'D69: Business-critical actions only (NOT full row changelog).
     Tracked: membership level changes, batch state transitions, price grid updates,
     admin role grants, restriction creation/lift, expert verifications.
     Auto-populated by trigger on platform_events (subset with is_audit flag — Dok 4).
     Admin read-only (Ownership Matrix 4.8).';

-- -------------------------------------------------------
-- knowledge_chunks
-- D70: Single pgvector RAG index across ALL domains (one search endpoint)
-- D71: Quarterly expert review — only is_published=true chunks used in RAG
-- D86: SOPDocument (Ops domain, 006_ops_edu.sql) also indexed here
-- Ownership Matrix 4.8: Expert C/U/A (review); AI Gateway R (RAG search)
-- -------------------------------------------------------
create table if not exists public.knowledge_chunks (
    id              uuid    primary key default gen_random_uuid(),
    -- D70: All domains in one table
    source_domain   text    not null
                                check (source_domain in (
                                    'veterinary',       -- disease reference, treatment protocols
                                    'zootechnical',     -- NASEM norms, breeding standards, SOPs
                                    'tsp',              -- TSP rules, coordination procedures
                                    'legal',            -- association rules, antitrust compliance
                                    'education',        -- course content summaries
                                    'faq'               -- general association FAQ
                                )),
    title           text    not null,
    content         text    not null,
    -- D70: pgvector embedding. Dimension 1536 = text-embedding-3-small compatible
    -- NOTE: NULL until AI Gateway async worker processes the chunk
    embedding       vector(1536),
    -- Filtering metadata
    metadata        jsonb,  -- {tags: [], animal_category_codes: [], region_ids: [], lang: "ru"}
    language        text    not null default 'ru'
                                check (language in ('ru','kk','en')),
    -- D71: Expert review lifecycle
    reviewed_by     uuid    references public.users(id),  -- expert who approved
    reviewed_at     timestamptz,
    next_review_at  timestamptz,    -- quarterly: reviewed_at + 3 months
    is_published    boolean not null default false, -- AI Gateway uses ONLY published chunks
    -- Source traceability
    source_url      text,           -- original document URL
    source_version  text,           -- version of source document
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.knowledge_chunks is
    'D70: Single cross-domain RAG index. AI Gateway searches all domains in one vector query.
     D71: is_published=false = in review. AI Gateway NEVER uses unpublished chunks.
     D86: SOPDocument (Ops domain, added in 006_ops_edu.sql) also stored here via source_domain=zootechnical.
     embedding populated ASYNC by AI Gateway worker — chunk usable for text search while pending.
     Quarterly review: expert sets next_review_at = reviewed_at + interval 3 months.';
comment on column public.knowledge_chunks.embedding is
    'vector(1536): compatible with text-embedding-3-small (OpenAI) or equivalent.
     NULL until processed by AI Gateway embedding worker.
     HNSW index created below for cosine similarity search (pgvector best practice).';

-- ============================================================
-- SECTION 4: INDEXES
-- Strategy: index every FK + every column used in WHERE/ORDER BY
-- ============================================================

-- regions
create index idx_regions_parent       on public.regions (parent_id) where parent_id is not null;
create index idx_regions_level_active on public.regions (level, is_active);

-- productivity_directions (small table, full scan is fine — index for completeness)
create index idx_prod_dir_code on public.productivity_directions (code);

-- animal_categories
create index idx_animal_cat_sex      on public.animal_categories (sex, is_active);

-- breeds
create index idx_breeds_direction    on public.breeds (productivity_direction_id, is_active);

-- users
create index idx_users_auth_id on public.users (auth_id);
create index idx_users_phone   on public.users (phone)  where phone is not null;
create index idx_users_email   on public.users (email)  where email is not null;

-- organizations
create index idx_orgs_bin_iin  on public.organizations (bin_iin)   where bin_iin is not null;
create index idx_orgs_region   on public.organizations (region_id) where region_id is not null;
create index idx_orgs_active   on public.organizations (is_active);

-- organization_type_assignments
create index idx_org_type_org  on public.organization_type_assignments (organization_id);
create index idx_org_type_type on public.organization_type_assignments (org_type);

-- user_organization_roles
create index idx_uor_user  on public.user_organization_roles (user_id);
create index idx_uor_org   on public.user_organization_roles (organization_id);

-- memberships
create index idx_memberships_org      on public.memberships (organization_id);
create index idx_memberships_type_lvl on public.memberships (org_type, level);

-- membership_applications
create index idx_mem_apps_membership on public.membership_applications (membership_id);
create index idx_mem_apps_org_status on public.membership_applications (organization_id, status);

-- verification_records
create index idx_verif_membership on public.verification_records (membership_id);
create index idx_verif_org        on public.verification_records (organization_id);

-- restriction_records (fast "is this org restricted?" lookup)
create index idx_restrictions_org_active
    on public.restriction_records (organization_id)
    where lifted_at is null;   -- partial index: only active restrictions

-- admin_roles
create index idx_admin_roles_active on public.admin_roles (user_id, is_active);

-- expert_profiles
create index idx_expert_spec_active on public.expert_profiles (specialization, is_active);

-- consultation_requests
create index idx_consult_org    on public.consultation_requests (organization_id, status);
create index idx_consult_expert on public.consultation_requests (expert_profile_id)
    where expert_profile_id is not null;
create index idx_consult_status on public.consultation_requests (status, created_at desc);

-- external_system_links
create index idx_ext_links_org on public.external_system_links (organization_id);

-- payments
create index idx_payments_org    on public.payments (organization_id);
create index idx_payments_status on public.payments (status, created_at desc);

-- farms
create index idx_farms_org    on public.farms (organization_id);
create index idx_farms_region on public.farms (region_id) where region_id is not null;
create index idx_farms_active on public.farms (organization_id, is_active) where is_active = true;

-- farm_activity_types
create index idx_farm_activities_farm on public.farm_activity_types (farm_id);

-- herd_groups (critical — heavily queried)
create index idx_herd_groups_farm     on public.herd_groups (farm_id);
create index idx_herd_groups_org      on public.herd_groups (organization_id);   -- RLS
create index idx_herd_groups_category on public.herd_groups (animal_category_id);
create index idx_herd_groups_active   on public.herd_groups (farm_id, is_active)
    where is_active = true;

-- herd_events (time-series — order matters)
create index idx_herd_events_farm_date  on public.herd_events (farm_id, event_date desc);
create index idx_herd_events_group_date on public.herd_events (herd_group_id, event_date desc)
    where herd_group_id is not null;
create index idx_herd_events_org        on public.herd_events (organization_id);  -- RLS
create index idx_herd_events_type_date  on public.herd_events (event_type, event_date desc);

-- ai_conversations
create index idx_ai_conv_org    on public.ai_conversations (organization_id);
create index idx_ai_conv_user   on public.ai_conversations (user_id);
create index idx_ai_conv_active on public.ai_conversations (user_id, is_active)
    where is_active = true;

-- ai_messages
create index idx_ai_msg_conv_seq on public.ai_messages (conversation_id, sequence_number);

-- platform_events (Event Bus polling — critical for Phase 1)
create index idx_pe_type_created on public.platform_events (event_type, created_at desc);
create index idx_pe_org_created  on public.platform_events (organization_id, created_at desc);
create index idx_pe_entity       on public.platform_events (entity_type, entity_id);

-- notifications
create index idx_notif_user_status on public.notifications (user_id, delivery_status);
create index idx_notif_scheduled   on public.notifications (scheduled_for)
    where delivery_status = 'pending' and scheduled_for is not null;

-- audit_log
create index idx_audit_entity  on public.audit_log (entity_type, entity_id);
create index idx_audit_org     on public.audit_log (organization_id, created_at desc);
create index idx_audit_action  on public.audit_log (action, created_at desc);

-- knowledge_chunks (vector similarity search — HNSW is best for pgvector)
create index idx_kc_embedding on public.knowledge_chunks
    using hnsw (embedding vector_cosine_ops)
    where embedding is not null and is_published = true;
create index idx_kc_domain_published on public.knowledge_chunks (source_domain, is_published);
create index idx_kc_review_due on public.knowledge_chunks (next_review_at)
    where is_published = true and next_review_at is not null;

-- ============================================================
-- SECTION 5: HELPER FUNCTIONS FOR RLS
-- ============================================================

-- Returns current user's UUID (from our users table, not auth.uid())
create or replace function public.fn_current_user_id()
returns uuid language sql security definer stable
set search_path = public, pg_temp as $$
    select id from public.users where auth_id = auth.uid() limit 1;
$$;

-- Returns all organization_ids the current user belongs to
create or replace function public.fn_my_org_ids()
returns uuid[] language sql security definer stable
set search_path = public, pg_temp as $$
    select coalesce(array_agg(uor.organization_id), array[]::uuid[])
    from public.user_organization_roles uor
    join public.users u on u.id = uor.user_id
    where u.auth_id = auth.uid();
$$;

-- Is current user an admin?
create or replace function public.fn_is_admin()
returns boolean language sql security definer stable
set search_path = public, pg_temp as $$
    select exists (
        select 1 from public.admin_roles ar
        join public.users u on u.id = ar.user_id
        where u.auth_id = auth.uid() and ar.is_active = true
    );
$$;

-- Is current user an expert?
create or replace function public.fn_is_expert()
returns boolean language sql security definer stable
set search_path = public, pg_temp as $$
    select exists (
        select 1 from public.expert_profiles ep
        join public.users u on u.id = ep.user_id
        where u.auth_id = auth.uid() and ep.is_active = true
    );
$$;

-- Is org currently restricted? (active restriction = lifted_at IS NULL)
create or replace function public.fn_org_is_restricted(p_org_id uuid)
returns boolean language sql security definer stable
set search_path = public, pg_temp as $$
    select exists (
        select 1 from public.restriction_records
        where organization_id = p_org_id and lifted_at is null
    );
$$;

-- ============================================================
-- SECTION 6: ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================
-- Core principle: Farmer A NEVER sees Farmer B's data (Section 5.9)
-- Aggregated/anonymous data is handled at RPC level, not RLS
-- AI Gateway uses service_role to bypass RLS, but always filters by org_id in RPC
-- ============================================================

-- Enable RLS on all tables
alter table public.regions                      enable row level security;
alter table public.productivity_directions      enable row level security;
alter table public.animal_categories            enable row level security;
alter table public.breeds                       enable row level security;
alter table public.users                        enable row level security;
alter table public.organizations                enable row level security;
alter table public.organization_type_assignments enable row level security;
alter table public.user_organization_roles      enable row level security;
alter table public.memberships                  enable row level security;
alter table public.membership_applications      enable row level security;
alter table public.verification_records         enable row level security;
alter table public.consent_records              enable row level security;
alter table public.agreement_acceptances        enable row level security;
alter table public.restriction_records          enable row level security;
alter table public.admin_roles                  enable row level security;
alter table public.external_system_links        enable row level security;
alter table public.payments                     enable row level security;
alter table public.purchased_products           enable row level security;
alter table public.expert_profiles              enable row level security;
alter table public.consultation_requests        enable row level security;
alter table public.farms                        enable row level security;
alter table public.farm_activity_types          enable row level security;
alter table public.herd_groups                  enable row level security;
alter table public.herd_events                  enable row level security;
alter table public.ai_conversations             enable row level security;
alter table public.ai_messages                  enable row level security;
alter table public.platform_events              enable row level security;
alter table public.notifications                enable row level security;
alter table public.audit_log                    enable row level security;
alter table public.knowledge_chunks             enable row level security;

-- -------------------------------------------------------
-- REFERENCE TABLES: readable by all authenticated users, writable by admin only
-- -------------------------------------------------------
create policy "regions_read_authenticated"
    on public.regions for select using (auth.uid() is not null);
create policy "regions_admin_write"
    on public.regions for all using (public.fn_is_admin());

create policy "productivity_dirs_read_authenticated"
    on public.productivity_directions for select using (auth.uid() is not null);
create policy "productivity_dirs_admin_write"
    on public.productivity_directions for all using (public.fn_is_admin());

create policy "animal_categories_read_authenticated"
    on public.animal_categories for select using (auth.uid() is not null);
create policy "animal_categories_admin_write"
    on public.animal_categories for all using (public.fn_is_admin());

create policy "breeds_read_authenticated"
    on public.breeds for select using (auth.uid() is not null);
create policy "breeds_admin_expert_write"
    on public.breeds for all using (public.fn_is_admin() or public.fn_is_expert());

-- -------------------------------------------------------
-- -------------------------------------------------------
-- ORGANIZATION TYPE ASSIGNMENTS
-- -------------------------------------------------------
create policy "org_type_read_own"
    on public.organization_type_assignments for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "org_type_write_own"
    on public.organization_type_assignments for insert
    with check (organization_id = any(public.fn_my_org_ids()));
create policy "org_type_admin_update"
    on public.organization_type_assignments for update
    using (public.fn_is_admin());

-- -------------------------------------------------------
-- USERS
-- -------------------------------------------------------
create policy "users_read_own"
    on public.users for select
    using (auth_id = auth.uid() or public.fn_is_admin() or public.fn_is_expert());
create policy "users_insert_own"
    on public.users for insert
    with check (auth_id = auth.uid());
create policy "users_update_own"
    on public.users for update
    using (auth_id = auth.uid() or public.fn_is_admin());

-- -------------------------------------------------------
-- ORGANIZATIONS
-- -------------------------------------------------------
create policy "orgs_read_own"
    on public.organizations for select
    using (
        id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "orgs_insert_authenticated"
    on public.organizations for insert
    with check (auth.uid() is not null);
create policy "orgs_update_own"
    on public.organizations for update
    using (
        id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

-- -------------------------------------------------------
-- MEMBERSHIPS & RELATED
-- -------------------------------------------------------
create policy "memberships_read_own"
    on public.memberships for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
create policy "memberships_admin_write"
    on public.memberships for all
    using (public.fn_is_admin());

create policy "mem_apps_read_own"
    on public.membership_applications for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
create policy "mem_apps_farmer_insert"
    on public.membership_applications for insert
    with check (organization_id = any(public.fn_my_org_ids()));
create policy "mem_apps_admin_update"
    on public.membership_applications for update
    using (public.fn_is_admin());

create policy "verif_records_read_own"
    on public.verification_records for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
create policy "verif_records_admin_write"
    on public.verification_records for insert
    with check (public.fn_is_admin() or public.fn_is_expert());

-- -------------------------------------------------------
-- CONSENT & AGREEMENTS (user-private)
-- -------------------------------------------------------
create policy "consent_read_own"
    on public.consent_records for select
    using (
        user_id = public.fn_current_user_id()
        or public.fn_is_admin()
    );
create policy "consent_system_insert"
    on public.consent_records for insert
    with check (user_id = public.fn_current_user_id() or public.fn_is_admin());

create policy "agreements_read_own"
    on public.agreement_acceptances for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
create policy "agreements_farmer_insert"
    on public.agreement_acceptances for insert
    with check (organization_id = any(public.fn_my_org_ids()));

-- -------------------------------------------------------
-- RESTRICTIONS (admin only)
-- -------------------------------------------------------
create policy "restrictions_admin_all"
    on public.restriction_records for all
    using (public.fn_is_admin());
-- Farmers cannot read their own restriction records (prevent gaming)
-- They experience restrictions as "access denied" responses

-- -------------------------------------------------------
-- ADMIN & EXPERT PROFILES
-- -------------------------------------------------------
create policy "admin_roles_super_admin"
    on public.admin_roles for all
    using (public.fn_is_admin());

create policy "expert_profiles_read_authenticated"
    on public.expert_profiles for select
    using (auth.uid() is not null);  -- farmers can see expert list (for consultation requests)
create policy "expert_profiles_admin_write"
    on public.expert_profiles for all
    using (public.fn_is_admin());
create policy "expert_profiles_self_update"
    on public.expert_profiles for update
    using (user_id = public.fn_current_user_id());

-- -------------------------------------------------------
-- CONSULTATION REQUESTS
-- -------------------------------------------------------
create policy "consult_read_own_or_expert"
    on public.consultation_requests for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "consult_farmer_insert"
    on public.consultation_requests for insert
    with check (organization_id = any(public.fn_my_org_ids()));
create policy "consult_admin_expert_update"
    on public.consultation_requests for update
    using (public.fn_is_admin() or public.fn_is_expert());

-- -------------------------------------------------------
-- EXTERNAL SYSTEM LINKS & PAYMENTS
-- -------------------------------------------------------
create policy "ext_links_read_own"
    on public.external_system_links for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
create policy "ext_links_own_write"
    on public.external_system_links for all
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

create policy "payments_read_own"
    on public.payments for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
create policy "payments_admin_write"
    on public.payments for all
    using (public.fn_is_admin());

create policy "purchased_products_read_own"
    on public.purchased_products for select
    using (
        user_id = public.fn_current_user_id()
        or public.fn_is_admin()
    );

-- -------------------------------------------------------
-- FARMS & HERD DATA (core data isolation)
-- Principle from Section 5.9: Farmer A NEVER sees Farmer B's data
-- -------------------------------------------------------
create policy "farms_read_own"
    on public.farms for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()  -- experts read for consultation
    );
create policy "farms_write_own"
    on public.farms for all
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

create policy "farm_activities_read_own"
    on public.farm_activity_types for select
    using (
        farm_id in (
            select id from public.farms
            where organization_id = any(public.fn_my_org_ids())
        )
        or public.fn_is_admin()
    );
create policy "farm_activities_write_own"
    on public.farm_activity_types for all
    using (
        farm_id in (
            select id from public.farms
            where organization_id = any(public.fn_my_org_ids())
        )
        or public.fn_is_admin()
    );

create policy "herd_groups_read_own"
    on public.herd_groups for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "herd_groups_write_own"
    on public.herd_groups for all
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

create policy "herd_events_read_own"
    on public.herd_events for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "herd_events_insert_own"
    on public.herd_events for insert
    with check (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
-- No UPDATE/DELETE policy for herd_events: append-only (D25)

-- -------------------------------------------------------
-- AI CONVERSATIONS & MESSAGES (D7: private to User)
-- -------------------------------------------------------
create policy "ai_conv_read_own"
    on public.ai_conversations for select
    using (
        user_id = public.fn_current_user_id()
        or public.fn_is_admin()
    );
create policy "ai_conv_write_own"
    on public.ai_conversations for all
    using (
        user_id = public.fn_current_user_id()
        or public.fn_is_admin()
    );

create policy "ai_msg_read_own"
    on public.ai_messages for select
    using (
        conversation_id in (
            select id from public.ai_conversations
            where user_id = public.fn_current_user_id()
        )
        or public.fn_is_admin()
    );
create policy "ai_msg_insert_own"
    on public.ai_messages for insert
    with check (
        conversation_id in (
            select id from public.ai_conversations
            where user_id = public.fn_current_user_id()
        )
    );

-- -------------------------------------------------------
-- PLATFORM EVENTS, NOTIFICATIONS, AUDIT
-- -------------------------------------------------------
create policy "platform_events_read_own"
    on public.platform_events for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

create policy "notifications_read_own"
    on public.notifications for select
    using (
        user_id = public.fn_current_user_id()
        or public.fn_is_admin()
    );
create policy "notifications_update_own"
    on public.notifications for update
    using (user_id = public.fn_current_user_id());  -- allow marking as read

create policy "audit_log_admin_only"
    on public.audit_log for select
    using (public.fn_is_admin());

-- -------------------------------------------------------
-- KNOWLEDGE CHUNKS (published = all authenticated; full = expert/admin)
-- -------------------------------------------------------
create policy "knowledge_read_published"
    on public.knowledge_chunks for select
    using (
        is_published = true
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
create policy "knowledge_expert_write"
    on public.knowledge_chunks for all
    using (public.fn_is_admin() or public.fn_is_expert());

-- ============================================================
-- SECTION 7: UPDATED_AT TRIGGER
-- Applied to all tables with updated_at column
-- ============================================================

create or replace function public.fn_set_updated_at()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger trg_users_updated_at
    before update on public.users
    for each row execute function public.fn_set_updated_at();

create trigger trg_organizations_updated_at
    before update on public.organizations
    for each row execute function public.fn_set_updated_at();

create trigger trg_user_org_roles_updated_at
    before update on public.user_organization_roles
    for each row execute function public.fn_set_updated_at();

create trigger trg_memberships_updated_at
    before update on public.memberships
    for each row execute function public.fn_set_updated_at();

create trigger trg_mem_apps_updated_at
    before update on public.membership_applications
    for each row execute function public.fn_set_updated_at();

create trigger trg_expert_profiles_updated_at
    before update on public.expert_profiles
    for each row execute function public.fn_set_updated_at();

create trigger trg_consultation_reqs_updated_at
    before update on public.consultation_requests
    for each row execute function public.fn_set_updated_at();

create trigger trg_ext_links_updated_at
    before update on public.external_system_links
    for each row execute function public.fn_set_updated_at();

create trigger trg_payments_updated_at
    before update on public.payments
    for each row execute function public.fn_set_updated_at();

create trigger trg_farms_updated_at
    before update on public.farms
    for each row execute function public.fn_set_updated_at();

create trigger trg_herd_groups_updated_at
    before update on public.herd_groups
    for each row execute function public.fn_set_updated_at();

create trigger trg_ai_conversations_updated_at
    before update on public.ai_conversations
    for each row execute function public.fn_set_updated_at();

create trigger trg_notifications_updated_at
    before update on public.notifications
    for each row execute function public.fn_set_updated_at();

create trigger trg_knowledge_chunks_updated_at
    before update on public.knowledge_chunks
    for each row execute function public.fn_set_updated_at();

-- ============================================================
-- SECTION 8: SEED DATA
-- P8: Standards as Data, Not Code
-- All values editable by admin after migration via INSERT/UPDATE
-- ============================================================

-- -------------------------------------------------------
-- productivity_directions (3 types — stable)
-- -------------------------------------------------------
insert into public.productivity_directions (code, name_ru, name_kk, sort_order) values
    ('meat',     'Мясное',        'Ет',     1),
    ('dairy',    'Молочное',      'Сүт',    2),
    ('combined', 'Мясо-молочное', 'Ет-сүт', 3)
on conflict (code) do nothing;

-- -------------------------------------------------------
-- animal_categories (12 types — D49: unified Farm + RationBuilder)
-- Sex: male | female | mixed
-- Age ranges: informational only
-- -------------------------------------------------------
insert into public.animal_categories
    (code, name_ru, name_kk, sex, typical_age_min_months, typical_age_max_months, sort_order)
values
    ('SUCKLING_CALF', 'Телята-сосуны',       'Емізулі бұзаулар',    'mixed',  0,    3,    1),
    ('YOUNG_CALF',    'Телята отъёмные',      'Жас бұзаулар',        'mixed',  3,    8,    2),
    ('BULL_CALF',     'Бычки',                'Бұқашықтар',          'male',   8,    18,   3),
    ('STEER',         'Бычки на откорме',     'Бордақы бұқашықтар',  'male',   12,   30,   4),
    ('HEIFER_YOUNG',  'Тёлки',                'Қашарлар',            'female', 8,    18,   5),
    ('HEIFER_PREG',   'Нетели',               'Буаз қашарлар',       'female', 18,   30,   6),
    ('COW',           'Коровы',               'Сиырлар',             'female', 30,   null, 7),
    ('COW_CULL',      'Коровы выбракованные', 'Шығарылатын сиырлар', 'female', 48,   null, 8),
    ('BULL_BREEDING', 'Быки-производители',   'Тұқымдық бұқалар',    'male',   24,   null, 9),
    ('BULL_CULL',     'Быки выбракованные',   'Шығарылатын бұқалар', 'male',   36,   null, 10),
    ('OX',            'Волы',                 'Өгіздер',             'male',   12,   null, 11),
    ('MIXED',         'Смешанная группа',     'Аралас топ',          'mixed',  null, null, 12)
on conflict (code) do nothing;

-- -------------------------------------------------------
-- breeds (16 breeds covering main KZ production — expandable by admin)
-- -------------------------------------------------------
insert into public.breeds
    (productivity_direction_id, code, name_ru, name_en, is_local, sort_order)
select pd.id, b.code, b.name_ru, b.name_en, b.is_local, b.sort_order
from (values
    -- Meat breeds
    ('meat', 'KAZ_WHITEHEAD', 'Казахская белоголовая', 'Kazakh Whiteheaded',  true,  1),
    ('meat', 'AULIEKOL',      'Аулиекольская',          'Auliekol',            true,  2),
    ('meat', 'HEREFORD',      'Герефорд',               'Hereford',            false, 3),
    ('meat', 'ANGUS',         'Абердин-ангус',          'Aberdeen Angus',      false, 4),
    ('meat', 'LIMOUSIN',      'Лимузин',                'Limousin',            false, 5),
    ('meat', 'CHAROLAIS',     'Шароле',                 'Charolais',           false, 6),
    ('meat', 'KALMYK',        'Калмыцкая',              'Kalmyk',              false, 7),
    ('meat', 'MIXED_MEAT',    'Помесная мясная',        'Mixed Meat',          false, 8),
    -- Dairy breeds
    ('dairy', 'HOLSTEIN',    'Голштинская',             'Holstein',            false, 9),
    ('dairy', 'BLACK_PIED',  'Чёрно-пёстрая',          'Black Pied',          false, 10),
    ('dairy', 'RED_STEPPE',  'Красная степная',         'Red Steppe',          false, 11),
    ('dairy', 'BROWN_SWISS', 'Бурая швицкая',           'Brown Swiss',         false, 12),
    ('dairy', 'MIXED_DAIRY', 'Помесная молочная',       'Mixed Dairy',         false, 13),
    -- Combined breeds
    ('combined', 'SIMMENTAL', 'Симментальская',         'Simmental',           false, 14),
    ('combined', 'ALATAU',    'Алатауская',             'Alatau',              true,  15),
    ('combined', 'KOSTANAY',  'Костанайская',           'Kostanay',            true,  16)
) as b(pd_code, code, name_ru, name_en, is_local, sort_order)
join public.productivity_directions pd on pd.code = b.pd_code
on conflict (code) do nothing;

-- -------------------------------------------------------
-- regions (Kazakhstan: 1 country + 17 oblasts + 3 cities = 21 rows)
-- ISO 3166-2:KZ codes
-- -------------------------------------------------------
insert into public.regions (code, name_ru, name_kk, level, sort_order) values
    ('KZ',      'Казахстан',                         'Қазақстан',                   'country', 0),
    ('KZ-AKM',  'Акмолинская область',               'Ақмола облысы',               'oblast',  1),
    ('KZ-AKT',  'Актюбинская область',               'Ақтөбе облысы',               'oblast',  2),
    ('KZ-ALA',  'Алматинская область',               'Алматы облысы',               'oblast',  3),
    ('KZ-ATY',  'Атырауская область',                'Атырау облысы',               'oblast',  4),
    ('KZ-VKO',  'Восточно-Казахстанская область',    'Шығыс Қазақстан облысы',      'oblast',  5),
    ('KZ-ZHA',  'Жамбылская область',                'Жамбыл облысы',               'oblast',  6),
    ('KZ-ZKO',  'Западно-Казахстанская область',     'Батыс Қазақстан облысы',      'oblast',  7),
    ('KZ-KAR',  'Карагандинская область',            'Қарағанды облысы',            'oblast',  8),
    ('KZ-KUS',  'Костанайская область',              'Қостанай облысы',             'oblast',  9),
    ('KZ-KZY',  'Кызылординская область',            'Қызылорда облысы',            'oblast',  10),
    ('KZ-MAN',  'Мангистауская область',             'Маңғыстау облысы',            'oblast',  11),
    ('KZ-PAV',  'Павлодарская область',              'Павлодар облысы',             'oblast',  12),
    ('KZ-SKO',  'Северо-Казахстанская область',      'Солтүстік Қазақстан облысы',  'oblast',  13),
    ('KZ-TUR',  'Туркестанская область',             'Түркістан облысы',            'oblast',  14),
    ('KZ-ABY',  'Абайская область',                  'Абай облысы',                 'oblast',  15),
    ('KZ-ZHT',  'Жетысуская область',                'Жетісу облысы',               'oblast',  16),
    ('KZ-ULY',  'Улытауская область',                'Ұлытау облысы',               'oblast',  17),
    ('KZ-AST',  'Астана (г.)',                       'Астана (қ.)',                  'city',    18),
    ('KZ-ALM',  'Алматы (г.)',                       'Алматы (қ.)',                  'city',    19),
    ('KZ-SHY',  'Шымкент (г.)',                      'Шымкент (қ.)',                 'city',    20)
on conflict (code) do nothing;

-- Set parent_id: all oblasts and cities → Kazakhstan root
update public.regions r
set parent_id = (select id from public.regions where code = 'KZ')
where r.code != 'KZ' and r.parent_id is null;

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Summary:
--   Reference tables:  4  (regions, productivity_directions, animal_categories, breeds)
--   Identity tables:  17  (users...consultation_requests)
--   Farm tables:       4  (farms, farm_activity_types, herd_groups, herd_events)
--                     [+ 3 reference tables above = 7 Farm domain entities]
--   Platform tables:   6  (ai_conversations, ai_messages, platform_events,
--                          notifications, audit_log, knowledge_chunks)
--   Total:            30 tables (34 including reference lookup tables separately)
--
--   Indexes:          48
--   RLS policies:     42
--   Helper functions:  5 (fn_current_user_id, fn_my_org_ids, fn_is_admin,
--                         fn_is_expert, fn_org_is_restricted)
--   Triggers:         14 (updated_at on all mutable tables)
--   Seed data:         4 tables seeded
--
-- Verified decisions:
--   Identity: D1 D2 D3 D4 D5 D6 D7 D8 D9 D10 D11 D58
--   Farm:     D18 D19 D20 D21 D22 D23 D24 D25 D26 D27 D49 D50 D54
--   Platform: D64 D65 D66 D67 D68 D69 D70 D71 D72
--
-- Cross-module FK pending (to be added in downstream migrations):
--   005_vet.sql:     ALTER TABLE consultation_requests
--                      ADD CONSTRAINT fk_consult_vet_case
--                      FOREIGN KEY (vet_case_id) REFERENCES vet_cases(id);
--   006_ops_edu.sql: Purchased_products → courses FK
--
-- Next migration: 002_tsp.sql
--   Entities: Batch, PoolRequest, Pool, PoolMatch, DeliveryRecord, PoolManifest,
--             PriceGrid, PriceGridLog, TspCategory*, WeightClass*, GradeStandard*,
--             ValidCombination*, PriceIndex, PriceIndexValue, PriceIndexMethodology*
--             (15 entities, 4 reference)
-- ============================================================


-- === FROM 009: AI Gateway conversation fields, ai_prompts, notification dispatch ===
-- ============================================================
-- AGOS Migration 009: AI GATEWAY PATCH
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 5 March 2026
--
-- Purpose:
--   Закрывает все критические дефекты AI Gateway,
--   выявленные в Architecture Audit (март 2026).
--
-- Дефекты:
--   C-1  ai_conversations: 8 новых колонок отсутствуют в БД
--   C-2  Все Gateway RPCs в схеме rpc. — создаём в public.
--   C-3  pg_try_advisory_lock → pg_try_advisory_xact_lock (session→xact)
--   C-4  current_role CHECK: 'veterinarian' → 'vet'
--   C-5  ai_messages.whatsapp_message_id отсутствует
--   C-6  notifications: поля dispatch отсутствуют
--   C-7  ai_conversations.detected_language (profiles не существует)
--   C-8  Таблица ai_prompts + get_active_prompt() + seed data
--   L-4  mark_notification_sent / mark_notification_failed не реализованы
--   L-6  invalidate_ai_context() как RPC (не прямая запись)
--   L-8  get_active_prompt ORDER BY tiebreaker
--
-- Depends on: 001_kernel.sql
-- Required by: AI Gateway (Python FastAPI + LangGraph)
--
-- Conventions (from 001_kernel.sql):
--   - Все функции в public. (PostgREST вызывает через supabase.rpc())
--   - SECURITY DEFINER SET search_path = public, pg_temp
--   - Advisory lock: xact-level (pg_try_advisory_xact_lock)
--   - Все ALTER TABLE используют IF NOT EXISTS / IF EXISTS
--   - Нет breaking changes к существующим таблицам
-- ============================================================

-- ============================================================
-- PATCH 1: ai_conversations — новые поля (C-1, C-4, C-7)
--
-- C-1: Поля для confirmation flow, rolling summary,
--      context TTL-инвалидации (Dok 5 §3.3, §3.6, §5.3)
-- C-4: Исправить CHECK constraint current_role:
--      'veterinarian' → 'vet' (должно совпадать с AI Gateway)
-- C-7: detected_language (profiles не существует → правильно здесь)
-- ============================================================

-- ── Confirmation flow (D117, D121) ──────────────────────────
alter table public.ai_conversations
    add column if not exists confirmation_pending  boolean     not null default false,
    add column if not exists confirmation_payload  jsonb       default null,
    add column if not exists active_farm_id        uuid        references public.farms(id)
                                                       on delete set null;

comment on column public.ai_conversations.confirmation_pending is
    'C-1/D117: TRUE = предыдущий run ожидает подтверждения от фермера.
     check_confirmation читает это поле в начале каждого run.
     Устанавливается в TRUE после extract_entities → save_confirmation_payload.
     Сбрасывается в FALSE после write_entities (confirm) или clear_confirmation (reject).';

comment on column public.ai_conversations.confirmation_payload is
    'C-1/D117: Что ждёт подтверждения. Формат:
     {entity_type: "herd_group", rpc: "upsert_herd_group",
      data: {animal_category_code: "BULL_CALF", head_count: 80, avg_weight_kg: 280}}
     NULL когда confirmation_pending = FALSE.
     LLM никогда не видит это поле напрямую — читает только Gateway.';

comment on column public.ai_conversations.active_farm_id is
    'C-1/S-3: Активная ферма в текущем разговоре (для мультифермных орг-ий).
     NULL = не уточнено. Уточняется при первом farm-specific запросе.
     Сбрасывается при новой сессии (24h window).';

-- ── Rolling summary (D120, D126) ────────────────────────────
alter table public.ai_conversations
    add column if not exists message_history_summary    text    default null,
    add column if not exists summary_last_message_index int     not null default 0;

comment on column public.ai_conversations.message_history_summary is
    'C-1/D120: Incremental rolling summary старых сообщений.
     Обновляется каждые SUMMARIZE_EVERY_N=10 новых сообщений через Claude Haiku.
     Передаётся в Claude API как первое сообщение [user: summary, assistant: "Понял"].
     NULL = история короче MAX_RECENT_MESSAGES=10, summary не нужен.';

comment on column public.ai_conversations.summary_last_message_index is
    'C-1/D126: Индекс последнего сообщения включённого в summary.
     get_rolling_summary(): если (total - summary_last_message_index) >= 10 → пересоздать.
     При пересоздании: new_summary = summarize(old_summary + messages[last_idx:]).
     Гарантирует что ни одно сообщение не потеряется.';

-- ── Context invalidation TTL (D128) ─────────────────────────
alter table public.ai_conversations
    add column if not exists context_invalidated_at timestamptz default null;

comment on column public.ai_conversations.context_invalidated_at is
    'C-1/D128: Принудительная инвалидация context snapshot от Event Bus.
     Устанавливается через rpc.invalidate_ai_context() когда внешний агент
     (веб-кабинет) изменяет herd_groups организации в активной сессии.
     load_context node: if context_invalidated_at IS NOT NULL → полный reload.
     Сбрасывается после reload: UPDATE SET context_invalidated_at = NULL.';

-- ── Processing lock timestamp (D121) ────────────────────────
-- Примечание: реальный lock делается через pg_try_advisory_xact_lock (Patch 4).
-- Это поле — fallback timestamp для мониторинга зависших runs.
alter table public.ai_conversations
    add column if not exists processing_locked_at timestamptz default null;

comment on column public.ai_conversations.processing_locked_at is
    'C-1/D121: Timestamp начала обработки текущего run (мониторинг).
     НЕ является механизмом блокировки — реальный lock через pg_try_advisory_xact_lock().
     Используется для детектирования зависших runs: если > 5 минут → считать orphan.
     Устанавливается: UPDATE SET processing_locked_at = now() в начале run.
     Сбрасывается: UPDATE SET processing_locked_at = NULL в конце run.';

-- ── Detected language (D131, R-10) ──────────────────────────
-- C-7: Dok 5 §9.2 содержал ALTER TABLE profiles — таблицы profiles нет.
--      users.preferred_language уже есть в 001_kernel.sql.
--      Добавляем только detected_language в ai_conversations.
alter table public.ai_conversations
    add column if not exists detected_language text not null default 'ru'
        check (detected_language in ('ru', 'kk'));

comment on column public.ai_conversations.detected_language is
    'C-7/D131: Язык определённый из входящих сообщений (не явный выбор пользователя).
     detect_and_cache_language() обновляет это поле при каждом новом сообщении.
     Proactive templates: приоритет users.preferred_language → detected_language → "ru".
     Только ru/kk: English не поддерживается как язык интерфейса фермера.';

-- ── DEF-ROLE-01: role_was_overridden — missing column ───────
-- Referenced by rpc_get_conversation_state (d07_ai_gateway.sql:2822)
-- but never defined. Caused runtime error on every load_context_node call.
alter table public.ai_conversations
    add column if not exists role_was_overridden boolean not null default false;

comment on column public.ai_conversations.role_was_overridden is
    'DEF-ROLE-01: TRUE when rpc_sync_conversation_role was called with an explicit
     role override (e.g. user typed "поговори со мной как ветеринар").
     FALSE = role was auto-detected by intent classification.
     Read by rpc_get_conversation_state → load_context_node in AI Gateway.';

-- ── C-4: Исправить CHECK constraint current_role ────────────
-- 'veterinarian' в SQL vs 'vet' в AI Gateway Python code — несовпадение.
-- Решение: 'vet' (короче, совпадает с Dok 5 AgentState TypedDict).
-- Безопасно: existing rows имеют default 'consultant', не 'veterinarian'.

do $$
begin
    -- Найти и удалить старый constraint по имени
    if exists (
        select 1 from information_schema.table_constraints
        where table_name = 'ai_conversations'
          and constraint_type = 'CHECK'
          and constraint_name like '%current_role%'
    ) then
        execute (
            select 'alter table public.ai_conversations drop constraint ' || constraint_name
            from information_schema.table_constraints
            where table_name = 'ai_conversations'
              and constraint_type = 'CHECK'
              and constraint_name like '%current_role%'
            limit 1
        );
    end if;
end $$;

alter table public.ai_conversations
    add constraint ai_conversations_current_role_check
    check ("current_role" in (
        'zootechnician',   -- управление стадом, кормление, план
        'vet',             -- C-4: было 'veterinarian' — исправлено
        'consultant',      -- субсидии, документы, членство
        'trading_agent'    -- TSP, батчи, цены
    ));

comment on column public.ai_conversations."current_role" is
    'C-4: Роль AI агента в текущем разговоре. Совпадает с AgentState.current_role в Python.
     ИСПРАВЛЕНИЕ: было ''veterinarian'' (001_kernel.sql) → стало ''vet'' (Dok 5 standard).
     Изменяется через sync_role_to_db node при каждом route_role.
     Default = ''consultant'' (самая безопасная роль при неопределённости).';

-- ── Индексы для новых полей ──────────────────────────────────
create index if not exists idx_ai_conv_confirmation
    on public.ai_conversations (confirmation_pending)
    where confirmation_pending = true;
-- Быстро найти все разговоры ожидающие подтверждения (мониторинг)

create index if not exists idx_ai_conv_invalidated
    on public.ai_conversations (organization_id, context_invalidated_at)
    where context_invalidated_at is not null;
-- invalidate_ai_context(): UPDATE WHERE organization_id = X AND is_active = true

-- ============================================================
-- PATCH 2: ai_messages — dedup field (C-5)
--
-- Dok 5 §10.2 R-7: атомарный INSERT ON CONFLICT (whatsapp_message_id)
-- Без этого поля и индекса дубли WhatsApp webhook возможны.
-- ============================================================

alter table public.ai_messages
    add column if not exists whatsapp_message_id text default null;

comment on column public.ai_messages.whatsapp_message_id is
    'C-5/D129: Уникальный ID сообщения от WhatsApp провайдера (wamid.xxx).
     NULL для сообщений из веб-кабинета (у них нет WA message_id).
     UNIQUE INDEX: insert_user_message_dedup использует ON CONFLICT (whatsapp_message_id).
     Гарантирует атомарный dedup без race condition SELECT→INSERT.';

create unique index if not exists ai_messages_wa_msgid_key
    on public.ai_messages (whatsapp_message_id)
    where whatsapp_message_id is not null;
-- Partial unique index: только WA сообщения, web не затронуты

-- ── prompt_version для трекинга качества (D132, R-11) ───────
alter table public.ai_messages
    add column if not exists prompt_version text default null;

comment on column public.ai_messages.prompt_version is
    'D132/R-11: Версия системного промпта использованного при генерации ответа.
     Формат: "base=1.0;role=1.2" (из build_system_prompt()).
     Сохраняется в metadata или напрямую в AIMessage при role=assistant.
     Позволяет коррелировать версию промпта с negative_feedback_rate (D130).
     NULL для role=user и role=tool сообщений.';

-- ============================================================
-- PATCH 3: notifications — dispatch fields (C-6)
--
-- Dok 5 §9.3: claim_pending_notifications, mark_notification_sent,
--             mark_notification_failed используют эти поля.
-- ============================================================

alter table public.notifications
    add column if not exists locked_by  text        default null,
    add column if not exists locked_at  timestamptz default null,
    add column if not exists failed_at  timestamptz default null,
    add column if not exists error_text text        default null;

comment on column public.notifications.locked_by is
    'C-6/D127: ID воркера захватившего это уведомление для отправки.
     Формат: FLY_MACHINE_ID или "local" при разработке.
     claim_pending_notifications(): UPDATE SET locked_by = p_worker_id WHERE id IN (...FOR UPDATE SKIP LOCKED).
     Stale lock: если locked_at < now() - 10 min → считать брошенным, можно захватить снова.';

comment on column public.notifications.locked_at is
    'C-6/D127: Время захвата уведомления воркером.
     Используется для stale lock detection (> 10 минут → orphan).';

comment on column public.notifications.failed_at is
    'C-6: Время последней неуспешной попытки отправки.
     mark_notification_failed() устанавливает это поле.';

comment on column public.notifications.error_text is
    'C-6: Текст ошибки последней неуспешной попытки.
     Сохраняется для диагностики (WhatsApp API error, timeout и т.д.).';

-- ── Индекс для dispatch polling ──────────────────────────────
create index if not exists idx_notif_dispatch
    on public.notifications (scheduled_for, locked_by)
    where delivery_status = 'pending';
-- claim_pending_notifications(): WHERE status='pending' AND scheduled_for<=now()
--   AND (locked_by IS NULL OR locked_at < now()-10min)

-- ============================================================
-- PATCH 4: ai_prompts table + get_active_prompt RPC (C-8, L-8)
--
-- Dok 5 §4.6 R-11: versioned system prompts в БД.
-- load_system_prompt() вызывает get_active_prompt() при каждом run.
-- L-8: ORDER BY active_from DESC, id DESC (tiebreaker для одновременных вставок)
-- ============================================================

create table if not exists public.ai_prompts (
    id           uuid        primary key default gen_random_uuid(),
    role         text        not null
                                 check (role in (
                                     'base',           -- базовый промпт (всегда включается)
                                     'zootechnician',  -- роль зоотехника
                                     'vet',            -- роль ветеринара
                                     'consultant',     -- роль консультанта
                                     'trading_agent'   -- роль торгового ассистента
                                 )),
    version      text        not null,   -- semver: "1.0", "1.1", "2.0"
    content      text        not null,   -- текст промпта с {переменными}
    active_from  timestamptz not null default now(),
    active_until timestamptz default null,  -- NULL = текущая активная версия
    created_by   uuid        references public.users(id) on delete set null,
    change_reason text,      -- "Улучшен ответ на ветеринарные вопросы"
    created_at   timestamptz not null default now(),

    unique (role, version)   -- одна версия на роль
);

comment on table public.ai_prompts is
    'C-8/D132: Версионированные system prompts для AI Gateway ролей.
     Все 5 ролей (base + 4 domain) хранятся здесь, не в коде.
     load_system_prompt(role) → get_active_prompt(role) → (content, version).
     version сохраняется в ai_messages.prompt_version для трекинга качества.
     Rollout: установить active_until на старой версии, вставить новую с active_from=now().
     A/B тест: временно две версии с одинаковым active_from — не рекомендуется,
     используй active_from с разницей в 1 секунду для детерминизма.';

-- ── RPC: получить активный промпт для роли (C-8, L-8) ───────
-- L-8 fix: ORDER BY active_from DESC, id DESC — детерминированный tiebreaker
create or replace function public.get_active_prompt(p_role text)
returns table(version text, content text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
    select  version,
            content
    from    public.ai_prompts
    where   role         = p_role
      and   active_from  <= now()
      and   (active_until is null or active_until > now())
    order by active_from desc,
             id          desc    -- L-8: tiebreaker — детерминированный результат
    limit 1;
$$;

comment on function public.get_active_prompt(text) is
    'C-8/L-8: Вернуть текущий активный промпт для роли.
     Используется load_system_prompt() в AI Gateway.
     STABLE: безопасно кешируется в рамках транзакции.
     Если результат пустой — Gateway бросает RuntimeError (Dok 5 §4.6).
     Ensure seed data ниже вставлена перед деплоем Gateway.
     L-8 fix: ORDER BY active_from DESC, id DESC — нет недетерминированности.';

-- ── Seed: начальные промпты (Dok 5 §4.6) ────────────────────
-- Версия 1.0 для каждой роли. Текст соответствует Dok 5 §4.6.
-- В переменных {org_name}, {region} и т.д. — подстановка в Python,
-- не в PostgreSQL (format() не используется здесь).
insert into public.ai_prompts (role, version, content, change_reason)
values
(
    'base', '1.0',
    'Ты — AI-консультант ассоциации ТУРАН для казахстанского фермера.
Говори на языке фермера: по-русски если пишет по-русски, по-казахски если пишет на казахском.
Отвечай коротко — 2-4 предложения. Фермер занят — он не читает длинные тексты.
Никогда не выдумывай факты о конкретной ферме — используй только данные из инструментов.
Организация: {org_name}, регион: {region}, уровень членства: {membership_level}.
Активных групп скота: {herd_groups_count}.',
    'Initial version — Dok 5 §4.6'
),
(
    'zootechnician', '1.0',
    'Ты — зоотехник. Помогаешь с управлением стадом, кормлением, производственным планом.
Если фермер говорит о болезни животных — переключись в ветеринарный режим.',
    'Initial version — Dok 5 §4.6'
),
(
    'vet', '1.0',
    'Ты — ветеринарный консультант. Помогаешь с симптомами, диагностикой, вакцинацией.
КРИТИЧЕСКИ ВАЖНО: дозировки препаратов — ТОЛЬКО из базы данных (tool:get_treatment_protocols).
НИКОГДА не называй конкретные дозы из своих знаний.
При тяжёлых симптомах (высокая температура, отказ от корма 2+ дня, падёж) — СРАЗУ предложи эксперта.',
    'Initial version — Dok 5 §4.6'
),
(
    'consultant', '1.0',
    'Ты — консультант по вопросам ассоциации ТУРАН, субсидиям и документам.
Отвечай на основе базы знаний (tool:search_knowledge).
Не давай юридических заключений — только информацию и ориентиры.',
    'Initial version — Dok 5 §4.6'
),
(
    'trading_agent', '1.0',
    'Ты — торговый ассистент. Помогаешь создать предложение о продаже скота.
КРИТИЧЕСКИ ВАЖНО (ст. 171 ПК РК): НИКОГДА не обсуждай цены других ферм.
Справочные цены ТУРАН — только ориентир, не обязательство.',
    'Initial version — Dok 5 §4.6'
)
on conflict (role, version) do nothing;

-- ============================================================
-- PATCH 5: Advisory lock RPCs — xact-level (C-2, C-3)
--
-- C-2: Все Dok 5 RPCs в схеме rpc. → создаём в public.
-- C-3: pg_try_advisory_lock (session) → pg_try_advisory_xact_lock (xact).
--
-- ПОЧЕМУ xact, не session:
--   Supabase REST API: каждый HTTP-запрос использует connection из пула.
--   pg_try_advisory_lock = session lock: снимается при возврате connection
--   в пул (между HTTP acquire и HTTP release).
--   pg_try_advisory_xact_lock = xact lock: держится до COMMIT/ROLLBACK
--   текущей транзакции (= весь HTTP-запрос к RPC).
--   Lock снимается автоматически — release не нужен.
-- ============================================================

create or replace function public.try_lock_conversation(
    p_lock_key bigint,
    p_context  text default 'conversation'  -- D-3 fix: для логирования
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- C-3: xact-level lock. Держится до конца транзакции.
    -- Не требует явного release — автоснятие при commit/rollback.
    -- Конвертация UUID → bigint: int(uuid.UUID(conversation_id)) % (2**63) в Python.
    return jsonb_build_object(
        'locked',  pg_try_advisory_xact_lock(p_lock_key),
        'context', p_context
    );
end;
$$;

comment on function public.try_lock_conversation(bigint, text) is
    '⚠️ DEPRECATED для inbound /chat flow (L-2, мета-анализ §3.2 Исправление #4).

     КОРЕНЬ ПРОБЛЕМЫ (тот же что L-NEW-2 для proactive):
       supabase.rpc("try_lock_conversation") = отдельная HTTP-транзакция.
       PostgreSQL: BEGIN → pg_try_advisory_xact_lock(key) → COMMIT → lock снят.
       run_agent() запускается ПОСЛЕ завершения RPC-транзакции — БЕЗ блокировки.
       Lock никогда не защищал run_agent(). Ложная уверенность.

     ПРАВИЛЬНАЯ ЗАЩИТА inbound /chat (достаточно для Phase 1):
       1. insert_user_message_dedup (ON CONFLICT whatsapp_message_id DO NOTHING)
          → Один WhatsApp message_id = ровно один вызов run_agent().
          → is_new=false → caller делает early return до run_agent().
       2. confirmation_pending flag (ai_conversations)
          → Два разных сообщения одновременно (edge case):
            Run 2 читает confirmation_pending в check_confirmation node.
            Confirmation payload атомарно записывается RPC в Run 1.

     ФУНКЦИЯ СОХРАНЕНА для обратной совместимости.
     Вызовы безопасны: xact lock снимается при COMMIT, ничего не ломает.
     ❌ НЕ использовать в новом коде для /chat flow.
     ❌ НЕ использовать в proactive_dispatch (L-NEW-2 — SKIP LOCKED достаточно).
     Dok5 §3.3.1 обновлён с корректным описанием (v1.7).';

-- release_conversation_lock сохраняем для совместимости с Dok 5 кодом,
-- но для xact lock он no-op (xact lock нельзя снять вручную до конца транзакции).
create or replace function public.release_conversation_lock(p_lock_key bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- C-3: При xact lock это no-op. Lock снимается при commit/rollback.
    -- Функция сохранена для совместимости с Dok 5 Python кодом.
    -- TODO Dok 6: убрать вызовы release_conversation_lock из Python.
    null;
end;
$$;

comment on function public.release_conversation_lock(bigint) is
    '⚠️ DEPRECATED (L-2, мета-анализ §3.2 Исправление #4). No-op при xact lock.
     pg_try_advisory_xact_lock снимается при COMMIT транзакции.
     Явный release невозможен и не нужен при xact lock.
     ФУНКЦИЯ СОХРАНЕНА для совместимости — вызов безопасен, ничего не делает.
     ❌ НЕ использовать в новом коде.';

-- ── mark_notification_sent ───────────────────────────────────
create or replace function public.mark_notification_sent(
    p_notification_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- L-4: Функция не существовала — создаём.
    update public.notifications
    set    delivery_status = 'sent',
           sent_at         = now(),
           locked_by       = null,    -- освободить lock
           locked_at       = null,
           updated_at      = now()
    where  id = p_notification_id;
end;
$$;

comment on function public.mark_notification_sent(uuid) is
    'C-2/L-4: Отметить уведомление как отправленное.
     Освобождает locked_by/locked_at — notification больше не захвачена.
     Вызывается после успешного send_proactive_message().';

-- ============================================================
-- PATCH 8: invalidate_ai_context RPC (L-6)
--
-- L-6: Dok 5 §5.3 писал напрямую в таблицу через Data API —
--      нарушение P-AI-1 (все writes через RPC).
-- Создаём RPC как единственный путь для инвалидации контекста.
-- ============================================================

create or replace function public.invalidate_ai_context(
    p_organization_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- L-6: Единственный авторизованный путь для инвалидации context snapshot.
    -- Event Bus consumer on_herd_group_updated() должен вызывать эту функцию,
    -- не писать напрямую в таблицу через supabase.table("ai_conversations").update().
    update public.ai_conversations
    set    context_invalidated_at = now(),
           updated_at             = now()
    where  organization_id = p_organization_id
      and  is_active        = true;
end;
$$;

comment on function public.invalidate_ai_context(uuid) is
    'L-6: RPC для инвалидации farm_context в активных сессиях организации.
     Вызывается Event Bus consumer при изменении herd_groups, farm_phases и т.д.
     Заменяет прямую запись в таблицу (нарушение P-AI-1).
     Gateway load_context: if context_invalidated_at IS NOT NULL → полный reload.
     После reload: UPDATE ai_conversations SET context_invalidated_at = NULL.
     
     Пример вызова из Python (Event Bus consumer):
       await supabase.rpc("invalidate_ai_context",
           {"p_organization_id": org_id}).execute()';

-- ============================================================
-- PATCH 9: resolve_user_by_phone — необходимо для Gateway (C-2)
--
-- Dok 5 §10.3 вызывает rpc.resolve_user_by_phone().
-- Создаём в public. (C-2 fix: rpc. → public.)
-- ============================================================

create or replace function public.resolve_user_by_phone(
    p_phone text
)
returns table(
    user_id          uuid,
    organization_id  uuid,
    membership_level text,
    org_name         text,
    region_name      text
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
    select
        u.id                                        as user_id,
        o.id                                        as organization_id,
        coalesce(m.level, 'registered')             as membership_level,
        o.legal_name                                as org_name,
        r.name_ru                                   as region_name
    from   public.users u
    join   public.user_organization_roles uor on uor.user_id = u.id
                                             and uor.is_primary = true
    join   public.organizations           o   on o.id = uor.organization_id
                                             and o.is_active = true
    left   join public.memberships        m   on m.organization_id = o.id
                                             and m.org_type = 'farmer'
    left   join public.regions            r   on r.id = o.region_id
    where  u.phone     = p_phone
      and  u.is_active = true   -- users.is_active ✅ (001_kernel.sql)
      -- uor.is_active НЕ существует в user_organization_roles (только is_primary)
    limit  1;
$$;

comment on function public.resolve_user_by_phone(text) is
    'C-2: phone (E.164) → user_id, organization_id, membership_level.
     Используется WhatsApp webhook handler в начале каждого run.
     Возвращает пустой результат если номер не зарегистрирован.
     Gateway: if not result.data → send "Ваш номер не зарегистрирован. turanstandard.kz"
     Только primary org (is_primary=true) — фермер с несколькими орг решает это через disambig.';

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Summary of changes:
--
--   ai_conversations:  +8 columns (confirmation_pending, confirmation_payload,
--                       active_farm_id, message_history_summary,
--                       summary_last_message_index, context_invalidated_at,
--                       processing_locked_at, detected_language)
--                      CHECK constraint current_role: 'veterinarian' → 'vet'
--                      +2 indexes (idx_ai_conv_confirmation, idx_ai_conv_invalidated)
--
--   ai_messages:       +2 columns (whatsapp_message_id, prompt_version)
--                      +1 unique partial index (ai_messages_wa_msgid_key)
--
--   notifications:     +4 columns (locked_by, locked_at, failed_at, error_text)
--                      +1 index (idx_notif_dispatch)
--
--   ai_prompts:        NEW TABLE (versioned system prompts)
--                      Seed: 5 rows (base + 4 roles)
--
--   New RPCs (all in public. schema):
--     get_active_prompt(p_role)               — C-8/L-8
--     try_lock_conversation(p_lock_key, ...)  — C-2/C-3 (xact lock)
--     release_conversation_lock(p_lock_key)   — C-2/C-3 (no-op, compat)
--     insert_user_message_dedup(...)          — C-2/C-5
--     claim_pending_notifications(...)        — C-2/C-6
--     mark_notification_sent(...)             — C-2/L-4
--     mark_notification_failed(...)           — C-2/L-4
--     invalidate_ai_context(...)              — L-6
--     resolve_user_by_phone(...)              — C-2
--
-- Defects closed:
--   C-1  ✅  8 новых колонок ai_conversations
--   C-2  ✅  Все Gateway RPCs в public. (не rpc.)
--   C-3  ✅  pg_try_advisory_xact_lock (не session)
--   C-4  ✅  current_role CHECK: 'vet' (не 'veterinarian')
--   C-5  ✅  ai_messages.whatsapp_message_id + UNIQUE INDEX
--   C-6  ✅  notifications dispatch fields
--   C-7  ✅  detected_language в ai_conversations (не в несуществующей profiles)
--   C-8  ✅  ai_prompts table + get_active_prompt() + seed data
--   L-4  ✅  mark_notification_sent / mark_notification_failed
--   L-6  ✅  invalidate_ai_context() как RPC
--   L-8  ✅  get_active_prompt ORDER BY с tiebreaker
--
-- Defects NOT closed here (требуют отдельных файлов или изменений Python):
--   L-1  Создать 010_fn_generate_production_plan.sql
--   L-2  Python: validate amend_data в confirm_handler
--   L-3  Python: detect_language_pure() без DB-записи
--   L-5  010: обернуть fn_shift_phase_cascade в savepoint или CTE UPDATE
--   L-7  008: добавить org check в fn_preview_cascade
--   L-9  Dok 5: scheduled_for/scheduled_at — исправить в тексте документа
--   L-10 Dok 1: обновить нумерацию миграций в §8 v1.5
--   D-1  Мониторинг: fn_my_org_ids() в RLS — приемлемо на Phase 1
--   D-2  008: добавить SET search_path к fn_shift_phase_cascade
--   D-3  Переименовать try_lock_conversation → try_advisory_lock (breaking)
--   D-4  Python: datetime.utcnow() → datetime.now(timezone.utc)
--   D-5  008: добавить CALVING в header comment
--   D-6  Backlog: рекурсия → CTE UPDATE (не срочно)
--
-- Zero breaking changes:
--   P7 (Additive Architecture): все новые колонки с DEFAULT-значениями.
--   Существующие строки ai_conversations получают:
--     confirmation_pending=false, confirmation_payload=null,
--     detected_language='ru', processing_locked_at=null и т.д.
--   Существующие строки ai_messages получают whatsapp_message_id=null.
--   CHECK constraint current_role: существующие 'consultant' / 'zootechnician'
--     не затронуты. 'veterinarian' не встречается в существующих строках
--     (поле добавлено в 001_kernel.sql но никогда не использовалось AI Gateway).
--
-- Next migrations:
--   010_fn_generate_production_plan.sql  — L-1 (Operations)
--   011_finishing_seed.sql               — ЦТК finishing (Dok 1 §8 v1.5)
--   012_breeding_seed.sql                — ЦТК breeding
-- ============================================================


-- === FROM 013: Audit trigger on platform_events, notification retry cap ===
-- ============================================================
-- Migration 013: Patch Audit Trigger + Notifications Retry Cap
-- ============================================================
-- Fix C-NEW-4: platform_events → audit_log trigger was described in Dok 4 §2.1
--   but never implemented. audit_log table exists but remains empty (silent failure).
--
-- Fix L-NEW-4: notifications infinite retry loop — no MAX_RETRY cap.
--   Expired/invalid notifications were retried forever.
--
-- Architecture decision D-NEW-A: SQL migrations are the canonical source for function names.
--   (Registered here: fn_audit_from_platform_event)
-- ============================================================

-- ============================================================
-- PART 1: Add is_audit flag to platform_events (Dok 4 §2.1)
-- Dok 4: "Subset of events with is_audit=true flows into audit_log"
-- ============================================================
alter table public.platform_events
    add column if not exists is_audit boolean not null default false;

comment on column public.platform_events.is_audit is
    'Dok 4 §2.1: When true, trigger fn_audit_from_platform_event copies this event
     into audit_log. Only business-critical events (membership changes, batch state
     transitions, price grid updates, admin grants) set is_audit=true.
     Events that set is_audit=true (Dok 4 §2.2):
       identity.membership.level_changed
       market.batch.published, market.batch.matched, market.batch.cancelled
       identity.consultation_request.created
       ops.plan.activated
       vet.vet_case.opened (severity=critical only — see trigger logic)';

-- ============================================================
-- PART 2: Trigger function — platform_events → audit_log
-- Dok 4 §2.1: fn_audit_from_platform_event
-- ============================================================
create or replace function public.fn_audit_from_platform_event()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- Only copy events flagged as audit-worthy
    if not new.is_audit then
        return new;
    end if;

    insert into public.audit_log (
        user_id,
        actor_type,
        action,
        entity_type,
        entity_id,
        organization_id,
        changes,
        created_at
    ) values (
        new.actor_id,                               -- user_id (null for system/cron)
        new.actor_type,                             -- farmer | admin | expert | system | ai_gateway
        new.event_type,                             -- e.g. 'identity.membership.level_changed'
        new.entity_type,                            -- table name: 'memberships', 'batches', etc.
        new.entity_id,
        new.organization_id,
        new.payload,                                -- {before, after, meta} from event payload
        new.created_at
    );

    return new;
end;
$$;

comment on function public.fn_audit_from_platform_event() is
    'Dok 4 §2.1: Trigger that copies platform_events with is_audit=true into audit_log.
     Fires AFTER INSERT on platform_events.
     audit_log is APPEND-ONLY: no updates, no deletes (Legal compliance, D69).
     Scope: business-critical state transitions only (not every DB write).';

-- ============================================================
-- PART 3: Attach trigger to platform_events
-- ============================================================
drop trigger if exists trg_platform_event_to_audit on public.platform_events;

create trigger trg_platform_event_to_audit
    after insert on public.platform_events
    for each row
    execute function public.fn_audit_from_platform_event();

comment on trigger trg_platform_event_to_audit on public.platform_events is
    'Dok 4 §2.1: AFTER INSERT trigger. Copies is_audit=true events to audit_log.
     Fix C-NEW-4: this trigger was described in Dok 4 but not implemented in migrations 001-010.';

-- ============================================================
-- PART 4: Mark existing audit-worthy RPCs to set is_audit=true
-- These helper functions set is_audit on specific platform_events
-- ============================================================

-- Helper: mark an event as audit (called by RPCs after inserting platform_event)
-- NOTE: RPCs that publish audit-worthy events should set is_audit=true inline:
--   insert into platform_events (..., is_audit, ...) values (..., true, ...)
-- The following marks the key event types that MUST always be audit events.
-- This is enforced via application convention + this documentation (Dok 4 §2.2).

comment on table public.audit_log is
    'D69: Business-critical actions only (NOT full row changelog).
     Tracked: membership level changes, batch state transitions, price grid updates,
     admin role grants, restriction creation/lift, expert verifications,
     consultation requests, critical vet cases, production plan activations.
     Auto-populated by trigger trg_platform_event_to_audit on platform_events (Dok 4 §2.1).
     Admin read-only (Ownership Matrix 4.8).
     APPEND-ONLY: never UPDATE or DELETE rows.
     Fix C-NEW-4: trigger implemented in migration 013 (was missing from 001-010).';

-- ============================================================
-- PART 5: Notifications retry cap (Fix L-NEW-4)
-- Adds max_retry_count column and updates mark_notification_failed
-- to transition to permanent failure after threshold.
-- ============================================================
alter table public.notifications
    add column if not exists max_retry_count int not null default 5;

comment on column public.notifications.max_retry_count is
    'L-NEW-4 fix: Maximum retry attempts before transitioning to failed_permanent.
     Default 5. If retry_count >= max_retry_count → mark_notification_failed sets
     delivery_status = ''failed_permanent''. Prevents infinite retry on bad phone numbers.';

-- Add failed_permanent status (requires dropping and recreating constraint)
-- Note: Supabase doesn't support ALTER CHECK directly — use constraint replacement
alter table public.notifications
    drop constraint if exists notifications_delivery_status_check;

alter table public.notifications
    add constraint notifications_delivery_status_check
    check (delivery_status in (
        'pending',
        'sent',
        'delivered',
        'failed',
        'failed_permanent',   -- L-NEW-4: terminal state after max retries
        'read'
    ));

comment on column public.notifications.delivery_status is
    'FSM: pending → sent → delivered | failed → retry → failed_permanent (after max_retry_count).
     failed_permanent: terminal state. claim_pending_notifications excludes this status.
     L-NEW-4 fix: added failed_permanent to prevent infinite retry loops.';

-- Update mark_notification_failed to respect max_retry_count
create or replace function public.mark_notification_failed(
    p_notification_id   uuid,
    p_error             text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_notif record;
begin
    select retry_count, max_retry_count
    into   v_notif
    from   public.notifications
    where  id = p_notification_id;

    if not found then return; end if;

    update public.notifications
    set    delivery_status = case
                                 when v_notif.retry_count + 1 >= v_notif.max_retry_count
                                 then 'failed_permanent'   -- L-NEW-4: terminal after max retries
                                 else 'failed'             -- will be retried
                             end,
           failure_reason = p_error,
           retry_count    = retry_count + 1,
           locked_by      = null,
           locked_at      = null,
           updated_at     = now()
    where  id = p_notification_id;
end;
$$;

comment on function public.mark_notification_failed(uuid, text) is
    'L-NEW-4 fix: Increments retry_count. When retry_count >= max_retry_count → status=failed_permanent.
     failed_permanent excluded from claim_pending_notifications → stops infinite retry.
     Previous version had no cap → invalid phone numbers retried forever (L-NEW-4).';

-- Update claim_pending_notifications to exclude failed_permanent
create or replace function public.claim_pending_notifications(
    p_batch_size    int,
    p_worker_id     text
)
returns setof public.notifications
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    return query
    update public.notifications
    set    locked_by = p_worker_id,
           locked_at = now()
    where  id in (
        select id from public.notifications
        where  delivery_status = 'pending'
          and  delivery_status != 'failed_permanent'  -- L-NEW-4: exclude terminal failures
          and  (locked_by is null or locked_at < now() - interval '10 minutes')
          and  (scheduled_for is null or scheduled_for <= now())
        order  by coalesce(scheduled_for, created_at)
        limit  p_batch_size
        for update skip locked
    )
    returning *;
end;
$$;

comment on function public.claim_pending_notifications(int, text) is
    'Atomically claims a batch of pending notifications for processing (SKIP LOCKED).
     L-NEW-4 fix: excludes failed_permanent status → no infinite retry.
     Stale locks (>10 min) are reclaimed automatically.';

-- ============================================================
-- PART 6: Index for is_audit queries
-- ============================================================
create index if not exists idx_platform_events_audit
    on public.platform_events (is_audit, created_at desc)
    where is_audit = true;

comment on index idx_platform_events_audit is
    'Partial index for audit queries: only is_audit=true events.
     Used by Admin Console audit trail queries and compliance reporting.';

-- ============================================================
-- PART 7: Document D-NEW-B architecture decision
-- ============================================================
comment on function public.rpc_update_conversation_language(uuid, text, uuid) is
    'Fix C-NEW-5: Replaces direct ai_conversations UPDATE in detect_and_cache_language().
     D-NEW-B: service_role MUST NOT use direct table writes. All writes via RPC.
     Validates: language in (ru, kk). Ownership: conversation must belong to organization.
     Called via supabase.rpc("rpc_update_conversation_language") from Python AI Gateway.
     Created in migration 011.';

-- ============================================================
-- END Migration 013
-- ============================================================


-- === FROM 014: Sequence number race fix, UNIQUE constraint ===
-- ============================================================
-- Migration 014: Sequence Number Race Fix + Advisory Lock Cleanup
-- ============================================================
-- Fix L-NEW-1: sequence_number race condition in insert_user_message_dedup
--   Root cause: SELECT MAX(seq)+1 then INSERT = two simultaneous messages
--   read max=5, both compute seq=6, INSERT collision or silent duplicate seq.
--   Fix: atomic UPDATE ai_conversations SET message_count = message_count + 1
--   RETURNING message_count. UPDATE serializes on the row lock — second caller
--   waits, reads incremented value. Guaranteed monotonic sequence.
--
-- Fix D-NEW-5: add UNIQUE(conversation_id, sequence_number) constraint.
--   Without this, any bug that produces duplicate sequence_numbers is
--   silently accepted. UNIQUE makes violations hard errors, not silent data drift.
--
-- Fix L-NEW-2: remove advisory lock from proactive_dispatch Python code.
--   Current lock is pg_try_advisory_xact_lock (xact-scoped). It is acquired and
--   released within the RPC transaction. process_notification_batch() runs AFTER
--   the transaction (and lock) ends. The lock never protected the batch.
--   Real protection: claim_pending_notifications uses FOR UPDATE SKIP LOCKED.
--   That IS sufficient. The advisory lock gave false confidence and should be removed
--   from proactive_dispatch (see updated Python code below).
--
-- Fix L-NEW-3: D-NEW-A — canonical RPC name registry table.
--   SQL migrations are the canonical source of RPC names.
--   Dok 3 had RPC-25 named rpc_open_vet_case; migration 011 created rpc_create_vet_case.
--   This table documents the canonical mapping.
-- ============================================================

-- ============================================================
-- PART 1: Fix sequence_number race condition (L-NEW-1)
-- Strategy: atomic UPDATE message_count → use as sequence_number
-- ai_conversations.message_count already exists (001_kernel.sql, default 0)
-- ============================================================

-- Step 1a: Add UNIQUE constraint on (conversation_id, sequence_number)
-- D-NEW-5: without this, duplicate sequence_numbers are silent
-- NOTE: if existing data has duplicates, run dedup query first (see comment below)
-- For fresh systems (Phase 1): no existing duplicate data expected.

-- Dedup check (run manually before applying constraint if data already exists):
-- SELECT conversation_id, sequence_number, count(*)
-- FROM ai_messages
-- GROUP BY conversation_id, sequence_number
-- HAVING count(*) > 1;

alter table public.ai_messages
    drop constraint if exists ai_messages_conv_seq_unique;

alter table public.ai_messages
    add constraint ai_messages_conv_seq_unique
    unique (conversation_id, sequence_number);

comment on constraint ai_messages_conv_seq_unique on public.ai_messages is
    'D-NEW-5 fix: Enforces monotonic sequence per conversation.
     Without this, L-NEW-1 race condition produces silent duplicate sequence_numbers.
     With this, any race condition causes a hard constraint violation (detectable in logs).
     Migration 014 rewrites insert_user_message_dedup to use atomic message_count increment
     which makes this constraint always satisfiable under concurrent load.';

-- Step 1b: Rewrite insert_user_message_dedup to use atomic counter
-- OLD pattern (race condition):
--   SELECT MAX(sequence_number) + 1 INTO v_seq ...   ← two callers can both read max=5
--   INSERT ... (sequence_number = v_seq)              ← both try seq=6 → collision/wrong data
--
-- NEW pattern (atomic):
--   UPDATE ai_conversations SET message_count = message_count + 1
--   WHERE id = p_conversation_id
--   RETURNING message_count INTO v_seq               ← PostgreSQL row lock serializes callers
--   INSERT ... (sequence_number = v_seq)              ← each caller gets unique value
--
-- Why this is safe:
--   PostgreSQL UPDATE takes an exclusive row lock on ai_conversations row.
--   Second concurrent caller blocks on UPDATE until first commits.
--   After first commits: message_count=6. Second UPDATE reads 6, returns 7.
--   Both callers get different sequence numbers. Zero probability of collision.

create or replace function public.insert_user_message_dedup(
    p_conversation_id       uuid,
    p_content               text,
    p_whatsapp_message_id   text,
    -- Optional additional fields (extend as needed without signature change)
    p_content_type          text    default 'text',
    p_content_url           text    default null,
    p_model_used            text    default null,
    p_prompt_version        text    default null,
    p_latency_ms            int     default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id    uuid;
    v_seq   int;
begin
    -- L-NEW-1 FIX: atomic sequence via UPDATE row lock.
    -- UPDATE serializes concurrent callers on the ai_conversations row.
    -- Returns NEW value of message_count = this message's sequence number.
    update public.ai_conversations
    set    message_count = message_count + 1,
           updated_at    = now()
    where  id = p_conversation_id
    returning message_count into v_seq;

    if v_seq is null then
        raise exception 'INVALID: conversation % not found', p_conversation_id
            using errcode = 'P0002';
    end if;

    -- Atomic dedup INSERT: ON CONFLICT(whatsapp_message_id) DO NOTHING.
    -- Two concurrent webhooks with the same wamid → only one INSERT succeeds.
    -- Second caller: v_id IS NULL → is_new=false → Gateway skips processing.
    insert into public.ai_messages (
        conversation_id,
        role,
        content_type,
        content_text,
        content_url,
        whatsapp_message_id,
        sequence_number,
        model_used,
        prompt_version,
        latency_ms
    )
    values (
        p_conversation_id,
        'user',
        p_content_type,
        p_content,
        p_content_url,
        p_whatsapp_message_id,
        v_seq,
        p_model_used,
        p_prompt_version,
        p_latency_ms
    )
    on conflict (whatsapp_message_id) do nothing
    returning id into v_id;

    -- Edge case: whatsapp_message_id collision (duplicate webhook).
    -- message_count was already incremented — we have a "gap" in the sequence.
    -- This is acceptable: sequence_numbers are ordered but not required to be gapless.
    -- The UNIQUE constraint is on (conversation_id, sequence_number) —
    -- since v_seq came from atomic increment, it is unique. No constraint violation.
    -- The duplicate webhook is silently dropped (is_new=false).

    return jsonb_build_object(
        'is_new',         v_id is not null,
        'message_id',     v_id,
        'sequence_number', v_seq
    );
end;
$$;

comment on function public.insert_user_message_dedup(uuid, text, text, text, text, text, text, int) is
    'L-NEW-1 FIX: Atomic sequence_number via UPDATE ai_conversations.message_count.
     UPDATE row lock serializes concurrent callers — each gets a unique sequence number.
     Replaces SELECT MAX(sequence_number)+1 pattern which had race condition under concurrency.

     D-NEW-5: UNIQUE(conversation_id, sequence_number) constraint enforces uniqueness.
     Sequence may have gaps (duplicate webhooks increment counter but not insert message)
     — this is intentional and acceptable. Use created_at for ordering if needed.

     Returns: {is_new: bool, message_id: uuid|null, sequence_number: int}
     is_new=false → duplicate webhook, Gateway must return early (skip processing).

     Old signature: (uuid, text, text) — 3 params.
     New signature: (uuid, text, text, text, text, text, text, int) — 8 params.
     BACKWARD COMPATIBLE: params 4-8 have defaults. Old callers with 3 args still work.';

-- ============================================================
-- PART 2: insert_ai_response helper
-- Complement to insert_user_message_dedup for assistant messages.
-- Uses same atomic counter pattern for consistent sequencing.
-- ============================================================
create or replace function public.insert_ai_message(
    p_conversation_id   uuid,
    p_role              text,   -- 'assistant' | 'tool' | 'system'
    p_content_type      text    default 'text',
    p_content_text      text    default null,
    p_tool_calls        jsonb   default null,
    p_extracted_entities jsonb  default null,
    p_model_used        text    default null,
    p_input_tokens      int     default null,
    p_output_tokens     int     default null,
    p_latency_ms        int     default null,
    p_prompt_version    text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id    uuid;
    v_seq   int;
begin
    -- Same atomic counter pattern as insert_user_message_dedup
    update public.ai_conversations
    set    message_count        = message_count + 1,
           -- Track aggregate token counts at conversation level (D72)
           total_input_tokens   = total_input_tokens  + coalesce(p_input_tokens, 0),
           total_output_tokens  = total_output_tokens + coalesce(p_output_tokens, 0),
           updated_at           = now()
    where  id = p_conversation_id
    returning message_count into v_seq;

    if v_seq is null then
        raise exception 'INVALID: conversation % not found', p_conversation_id
            using errcode = 'P0002';
    end if;

    insert into public.ai_messages (
        conversation_id,
        role,
        content_type,
        content_text,
        tool_calls,
        extracted_entities,
        model_used,
        input_tokens,
        output_tokens,
        latency_ms,
        prompt_version,
        sequence_number
    )
    values (
        p_conversation_id,
        p_role,
        p_content_type,
        p_content_text,
        p_tool_calls,
        p_extracted_entities,
        p_model_used,
        p_input_tokens,
        p_output_tokens,
        p_latency_ms,
        p_prompt_version,
        v_seq
    )
    returning id into v_id;

    return jsonb_build_object(
        'message_id',      v_id,
        'sequence_number', v_seq
    );
end;
$$;

comment on function public.insert_ai_message(uuid,text,text,text,jsonb,jsonb,text,int,int,int,text) is
    'Companion to insert_user_message_dedup for assistant/tool/system messages.
     Uses same atomic message_count increment → same race-free sequence guarantee.
     Also updates ai_conversations.total_input/output_tokens (D72 cost tracking).
     Called by AI Gateway after each Claude API response.';

-- ============================================================
-- PART 3: Advisory lock cleanup documentation (L-NEW-2)
-- The SQL functions are fine. The bug is in Python proactive_dispatch.
-- This migration documents the fix and updates function comments.
-- ============================================================

comment on function public.try_lock_conversation(bigint, text) is
    '⚠️ DEPRECATED для inbound /chat flow (L-2, мета-анализ §3.2 Исправление #4).
     Повторно обновлён (L-NEW-2 закрывал только proactive, L-2 закрывает /chat).

     МЕХАНИКА (почему не работает для Python-клиента):
       supabase.rpc() = HTTP-запрос = отдельная PG-транзакция.
       xact lock снимается при COMMIT этой транзакции.
       run_agent() стартует ПОСЛЕ возврата из rpc() — lock уже снят.

     ПРАВИЛЬНАЯ ЗАЩИТА:
       /chat:               insert_user_message_dedup (ON CONFLICT DO NOTHING)
       proactive_dispatch:  claim_pending_notifications (FOR UPDATE SKIP LOCKED)

     ФУНКЦИЯ СОХРАНЕНА для обратной совместимости. Вызовы безопасны.
     ❌ НЕ использовать в новом коде ни для /chat, ни для proactive.';

-- ============================================================
-- PART 4: D-NEW-A — Canonical RPC name registry (L-NEW-3)
-- SQL migrations are the canonical source. Dok 3 had stale names.
-- This table is the source of truth for AI Gateway tool → RPC mapping.
-- ============================================================
create table if not exists public.rpc_name_registry (
    id              uuid    primary key default gen_random_uuid(),
    -- D-NEW-A: canonical SQL function name (as created in migrations)
    sql_name        text    not null unique,   -- e.g. rpc_create_vet_case
    -- Dok 3 name (may differ from SQL name — these are the known discrepancies)
    dok3_name       text,           -- e.g. rpc_open_vet_case (stale Dok 3 name)
    -- Dok 5 tool name (snake_case, 2-4 words)
    dok5_tool_name  text,           -- e.g. create_vet_case
    -- Supabase call (always same as sql_name, but explicit for clarity)
    supabase_call   text    not null generated always as
                        ('supabase.rpc("' || sql_name || '")') stored,
    -- Migration where this RPC was created
    created_in      text    not null,   -- e.g. '011_ai_rpc_catalog.sql'
    -- Status
    status          text    not null default 'active'
                                check (status in ('active', 'deprecated', 'renamed')),
    -- If renamed: what replaced it
    replaced_by     text,
    notes           text,
    created_at      timestamptz not null default now()
);

comment on table public.rpc_name_registry is
    'D-NEW-A: Canonical RPC name registry.
     SQL migrations (sql_name column) are the single source of truth for function names.
     dok3_name: Dok 3 name — may differ from sql_name (known discrepancies documented here).
     AI Gateway code MUST use sql_name via supabase.rpc(sql_name).
     Dok 3 name is documentation only — not a callable name.
     Status=deprecated: function exists but should not be called from new code.
     Status=renamed: sql_name is old name, replaced_by is current name.';

-- Populate with all AI Gateway RPCs (from migration 011 + existing RPCs)
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    -- Migration 011: new RPCs
    ('rpc_get_ai_farm_context',        null,                'get_farm_context',           '011_ai_rpc_catalog.sql',            'Farm context snapshot for AI'),
    ('rpc_upsert_herd_group',          null,                'update_herd_group',          '011_ai_rpc_catalog.sql',            'Create or update herd group (data_source=ai_extracted)'),
    ('rpc_get_feeding_plan',           null,                'get_feeding_plan',           '011_ai_rpc_catalog.sql',            'Active feeding plan with periods'),
    ('rpc_get_farm_tasks',             null,                'get_farm_tasks',             '011_ai_rpc_catalog.sql',            'Upcoming farm tasks'),
    ('rpc_complete_farm_task',         null,                'complete_farm_task',         '011_ai_rpc_catalog.sql',            'Mark task completed'),
    ('rpc_get_production_plan',        null,                'get_production_plan',        '011_ai_rpc_catalog.sql',            'Production plan phases'),
    ('rpc_create_vet_case',            'rpc_open_vet_case', 'create_vet_case',            '011_ai_rpc_catalog.sql',            'L-NEW-3: Dok3 had rpc_open_vet_case. SQL canonical name is rpc_create_vet_case.'),
    ('rpc_add_vet_symptoms',           null,                'add_symptoms',               '011_ai_rpc_catalog.sql',            'Append structured symptoms to vet case'),
    ('rpc_get_vet_diagnosis',          null,                'get_diagnosis',              '011_ai_rpc_catalog.sql',            'Symptom matrix matching'),
    ('rpc_get_treatment_protocols',    null,                'get_treatment_protocols',    '011_ai_rpc_catalog.sql',            'P-AI-4: dosages from treatments table only'),
    ('rpc_get_vaccination_schedule',   null,                'get_vaccination_schedule',   '011_ai_rpc_catalog.sql',            'Upcoming vaccinations'),
    ('rpc_complete_vaccination_item',  null,                'confirm_vaccination',        '011_ai_rpc_catalog.sql',            'Record vaccination fact'),
    ('rpc_create_consultation_request',null,                'escalate_to_expert',         '011_ai_rpc_catalog.sql',            'Request expert consultation'),
    ('rpc_search_knowledge_chunks',    null,                'search_knowledge',           '011_ai_rpc_catalog.sql',            'Vector+text RAG search'),
    ('rpc_get_membership_status',      null,                'get_membership_status',      '011_ai_rpc_catalog.sql',            'Org membership levels and applications'),
    ('rpc_get_price_grid',             null,                'get_price_grid',             '011_ai_rpc_catalog.sql',            'Reference prices with legal disclaimer (ст.171 ПК РК)'),
    ('rpc_get_aggregated_supply',      null,                'get_market_overview',        '011_ai_rpc_catalog.sql',            'Anonymized supply aggregates (antitrust-safe)'),
    ('rpc_get_aggregated_demand',      null,                'get_market_overview',        '011_ai_rpc_catalog.sql',            'Anonymized demand aggregates (antitrust-safe)'),
    ('rpc_get_org_batches',            null,                'get_active_batches',         '011_ai_rpc_catalog.sql',            'Own org batches only'),
    ('rpc_create_batch',               null,                'create_batch_draft',         '011_ai_rpc_catalog.sql',            'Create draft supply offer'),
    ('rpc_publish_batch',              null,                'publish_batch',              '011_ai_rpc_catalog.sql',            'Publish batch to market'),
    ('rpc_update_conversation_language',null,               null,                         '011_ai_rpc_catalog.sql',            'C-NEW-5: replaces direct DB write in detect_and_cache_language'),
    -- Migration 012: patched existing RPC
    ('rpc_start_production_plan',      'rpc_start_production_plan', null,                 '010+012',                           'C-NEW-7: added p_actor_id for service_role compat'),
    -- Migration 009: existing RPCs
    ('insert_user_message_dedup',      null,                null,                         '009_patch_ai.sql+014',              'L-NEW-1: rewritten in 014 to use atomic counter'),
    ('insert_ai_message',              null,                null,                         '014_patch_sequence_and_lock.sql',   'New: companion for assistant messages'),
    ('try_lock_conversation',          null,                null,                         '009_patch_ai.sql',                  'Advisory xact lock. NOT for proactive_dispatch (L-NEW-2)'),
    ('claim_pending_notifications',    null,                null,                         '009_patch_ai.sql+013',              'L-NEW-4: updated in 013 to exclude failed_permanent'),
    ('mark_notification_sent',         null,                null,                         '009_patch_ai.sql',                  null),
    ('mark_notification_failed',       null,                null,                         '009_patch_ai.sql+013',              'L-NEW-4: updated in 013 with max_retry_count cap'),
    ('invalidate_ai_context',          null,                null,                         '009_patch_ai.sql',                  'L-6: C-NEW-5 pattern — RPC instead of direct write'),
    ('resolve_user_by_phone',          null,                null,                         '009_patch_ai.sql',                  'WhatsApp webhook: phone → user_id'),
    ('get_active_prompt',              null,                null,                         '009_patch_ai.sql',                  'Get current system prompt by role')
on conflict (sql_name) do update
    set dok3_name      = excluded.dok3_name,
        dok5_tool_name = excluded.dok5_tool_name,
        notes          = excluded.notes,
        created_in     = excluded.created_in;

-- ============================================================
-- PART 5: Updated proactive_dispatch Python code (L-NEW-2 fix)
-- Documents the correct implementation — advisory lock removed.
-- ============================================================

comment on table public.rpc_name_registry is
    'D-NEW-A: Canonical RPC name registry. SQL function name = supabase.rpc() call name.
     Dok 3 names are documentation only — not callable.

     L-NEW-2 FIX for proactive_dispatch (Python code, not SQL):
     ============================================================
     WRONG (current Dok 5 v1.4, will be fixed in v1.5 proactive section):

       locked = await supabase.rpc("try_lock_conversation", {...}).execute()
       # ↑ This lock is released when RPC transaction ends (before process_notification_batch)
       # ↑ process_notification_batch() runs WITHOUT lock protection
       # ↑ Advisory lock is a no-op here

     CORRECT (Dok 5 v1.5 fix):

       @app.post("/proactive/dispatch")
       async def proactive_dispatch(req: Request):
           verify_internal_key(req)
           # NO advisory lock here — SKIP LOCKED in claim_pending_notifications
           # is the real concurrency protection. Two instances calling dispatch
           # simultaneously both call claim_pending_notifications, which uses
           # FOR UPDATE SKIP LOCKED — they claim different non-overlapping batches.
           # No duplication, no coordination needed beyond SKIP LOCKED.
           await process_notification_batch()
           return {"status": "ok"}

     Why SKIP LOCKED is sufficient:
       claim_pending_notifications does:
         UPDATE notifications SET locked_by = p_worker_id
         WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED)
       Two concurrent callers each claim non-overlapping rows.
       Even if both start simultaneously, PostgreSQL ensures each row
       is claimed by exactly one caller. Zero duplicates. Zero coordination needed.
     ============================================================';

-- ============================================================
-- PART 6: Index for rpc_name_registry queries
-- ============================================================
create index if not exists idx_rpc_registry_dok3
    on public.rpc_name_registry (dok3_name)
    where dok3_name is not null;

create index if not exists idx_rpc_registry_dok5
    on public.rpc_name_registry (dok5_tool_name)
    where dok5_tool_name is not null;

-- ============================================================
-- Summary of fixes in this migration:
--
-- L-NEW-1 ✅  insert_user_message_dedup: SELECT MAX → UPDATE message_count (atomic)
-- D-NEW-5 ✅  UNIQUE(conversation_id, sequence_number) constraint added
-- L-NEW-2 ✅  Documented: remove advisory lock from proactive_dispatch Python
-- L-NEW-3 ✅  rpc_name_registry table created with all 30 known RPCs
-- D-NEW-A ✅  SQL migrations = canonical RPC names (enforced by registry)
-- ============================================================


-- === FROM 015: JWT claims, fn_my_org_ids fast path, embedding_queue ===
-- ============================================================
-- Migration 015: Priority 3 Technical Debt
-- AGOS | Date: 2026-03-05
-- ============================================================
-- Fixes:
--   D-NEW-1  fn_my_org_ids() DB hit on every RLS row → JWT claims fast path
-- NOTE: Migration 015 content was truncated during consolidation.
-- TODO: Restore fn_auth_custom_claims + embedding_queue from original file.
-- ============================================================


-- ============================================================
-- SECTION: SLICE 1 — Sick Calf RPCs
-- Date: 2026-03-18
-- RPCs: RPC-01, RPC-02, RPC-04, RPC-05, RPC-05b, RPC-40
-- Dok 3 §2 (Identity), §3 (Farm), §9 (Platform)
-- ============================================================

-- ============================================================
-- RPC-01: rpc_register_organization
-- Dok 3 §2.1 | Callers: [WEB] [AI]
-- Atomic: Organization + OrganizationTypeAssignment + UserOrganizationRole + Farm (if farmer) + Membership
-- ============================================================
-- AUTO-CREATE public.users ON AUTH SIGNUP
-- When Supabase Auth creates auth.users row, this trigger
-- creates the corresponding public.users row so that
-- fn_current_user_id() works immediately after signup.
-- Without this: rpc_register_organization fails with AUTH_REQUIRED.
-- ============================================================
create or replace function public.fn_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    insert into public.users (auth_id, phone, email, full_name)
    values (
        new.id,
        new.phone,
        new.email,
        coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name')
    )
    on conflict (auth_id) do nothing;
    return new;
end;
$$;

-- Create trigger (idempotent: drop if exists first)
drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
    after insert on auth.users
    for each row
    execute function public.fn_handle_new_auth_user();

comment on function public.fn_handle_new_auth_user() is
    'Auto-creates public.users row when Supabase Auth user is created.
     Ensures fn_current_user_id() returns non-null immediately after signup.
     Phone/email extracted from auth.users. full_name from raw_user_meta_data.
     ON CONFLICT DO NOTHING: idempotent if user already exists.';

-- CEO Decision D-F01-3: supports org_types from schema CHECK (farmer, mpk, supplier, consultant, other)
-- CEO Decision D-F01-2: Auth is OTP; user already authenticated before this RPC
-- ============================================================
create or replace function public.rpc_register_organization(
    p_organization_id   uuid,       -- ignored for this RPC; included for P-AI-2 signature consistency
    p_org_type          text,
    p_name              text,
    p_bin               text        default null,
    p_region_id         uuid        default null,
    p_phone             text        default null,
    p_invited_by        uuid        default null,
    p_role_data         jsonb       default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_user_id       uuid;
    v_org_id        uuid;
    v_farm_id       uuid;
    v_membership_id uuid;
begin
    -- Resolve current user
    v_user_id := public.fn_current_user_id();
    if v_user_id is null then
        raise exception 'AUTH_REQUIRED: user not authenticated'
            using errcode = 'P0001';
    end if;

    -- Validate org_type against schema CHECK values
    if p_org_type not in ('farmer', 'mpk', 'supplier', 'consultant', 'other') then
        raise exception 'INVALID_ORG_TYPE: % is not a valid org_type', p_org_type
            using errcode = 'P0001';
    end if;

    -- Check BIN uniqueness (if provided)
    if p_bin is not null then
        if exists (select 1 from public.organizations where bin_iin = p_bin and is_active = true) then
            raise exception 'BIN_DUPLICATE: organization with BIN % already exists', p_bin
                using errcode = 'P0001';
        end if;
    end if;

    -- 1. Create Organization
    insert into public.organizations (
        legal_name,
        bin_iin,
        region_id,
        phone
    ) values (
        p_name,
        p_bin,
        p_region_id,
        p_phone
    )
    returning id into v_org_id;

    -- 2. Create OrganizationTypeAssignment
    insert into public.organization_type_assignments (
        organization_id,
        org_type,
        assigned_by
    ) values (
        v_org_id,
        p_org_type,
        v_user_id
    );

    -- 3. Create UserOrganizationRole (owner)
    insert into public.user_organization_roles (
        user_id,
        organization_id,
        role,
        is_primary
    ) values (
        v_user_id,
        v_org_id,
        'owner',
        true
    );

    -- 4. Create Membership record (level = registered, D3)
    insert into public.memberships (
        organization_id,
        org_type,
        level
    ) values (
        v_org_id,
        p_org_type,
        'registered'
    )
    returning id into v_membership_id;

    -- 5. Auto-create Farm if org_type = 'farmer'
    if p_org_type = 'farmer' then
        insert into public.farms (
            organization_id,
            name,
            region_id,
            is_primary,
            data_source
        ) values (
            v_org_id,
            coalesce(p_role_data->>'farm_name', p_name || ' — ферма'),
            p_region_id,
            true,
            'registration'
        )
        returning id into v_farm_id;
    end if;

    -- 6. Emit event: identity.organization.registered
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
        'identity.organization.registered',
        'organizations',
        v_org_id,
        v_org_id,
        'farmer',
        v_user_id,
        jsonb_build_object(
            'org_type', p_org_type,
            'name', p_name,
            'farm_id', v_farm_id,
            'invited_by', p_invited_by,
            'role_data', p_role_data
        ),
        true
    );

    return jsonb_build_object(
        'org_id',  v_org_id,
        'farm_id', v_farm_id
    );
end;
$$;

comment on function public.rpc_register_organization(uuid, text, text, text, uuid, text, uuid, jsonb) is
    'RPC-01 | Dok 3 §2.1 | Slice 1
     Atomic registration: Organization + TypeAssignment + UserOrganizationRole(owner) + Membership(registered) + Farm(if farmer).
     D-F01-2: User authenticated via OTP before this call.
     D-F01-3: org_types from schema CHECK (farmer, mpk, supplier, consultant, other).
     p_role_data jsonb: role-specific fields stored in platform_events payload (not in org table — no metadata column exists).
     DEFECT FLAG: CEO decision D-F01-3 mentions services/feed_producer org_types that do not exist in schema CHECK.
     Error codes: BIN_DUPLICATE, INVALID_ORG_TYPE, AUTH_REQUIRED.
     Event: identity.organization.registered (is_audit=true).';


-- ============================================================
-- RPC-02: rpc_submit_membership_application
-- Dok 3 §2.2 | Callers: [WEB] [AI]
-- Creates MembershipApplication with status='submitted'
-- ============================================================
create or replace function public.rpc_submit_membership_application(
    p_organization_id   uuid,
    p_membership_type   text,
    p_notes             text    default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_membership_id     uuid;
    v_current_level     text;
    v_application_id    uuid;
    v_to_level          text;
begin
    -- Validate membership_type
    if p_membership_type not in ('associate', 'full', 'premium', 'honorary') then
        raise exception 'INVALID_MEMBERSHIP_TYPE: % is not valid', p_membership_type
            using errcode = 'P0001';
    end if;

    -- Find existing membership for this org
    select id, level
    into   v_membership_id, v_current_level
    from   public.memberships
    where  organization_id = p_organization_id
    limit  1;

    if v_membership_id is null then
        raise exception 'NO_MEMBERSHIP: organization % has no membership record', p_organization_id
            using errcode = 'P0001';
    end if;

    -- Check: already active at a real membership level (beyond registered)
    if v_current_level not in ('registered', 'observer') then
        raise exception 'ALREADY_ACTIVE: organization already has active membership level %', v_current_level
            using errcode = 'P0001';
    end if;

    -- Check: no pending application exists
    if exists (
        select 1 from public.membership_applications
        where  organization_id = p_organization_id
          and  status in ('submitted', 'under_review')
    ) then
        raise exception 'PENDING_EXISTS: an application is already pending for this organization'
            using errcode = 'P0001';
    end if;

    -- Determine target level: observer (first step from registered)
    v_to_level := 'observer';

    -- Create application
    insert into public.membership_applications (
        membership_id,
        organization_id,
        from_level,
        to_level,
        status,
        reviewer_notes,
        supporting_docs
    ) values (
        v_membership_id,
        p_organization_id,
        v_current_level,
        v_to_level,
        'submitted',
        p_notes,
        null
    )
    returning id into v_application_id;

    -- Emit event: identity.membership_application.submitted
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
        'identity.membership_application.submitted',
        'membership_applications',
        v_application_id,
        p_organization_id,
        'farmer',
        public.fn_current_user_id(),
        jsonb_build_object(
            'from_level', v_current_level,
            'to_level', v_to_level,
            'membership_type', p_membership_type,
            'notes', p_notes
        ),
        true
    );

    return v_application_id;
end;
$$;

comment on function public.rpc_submit_membership_application(uuid, text, text) is
    'RPC-02 | Dok 3 §2.2 | Slice 1
     Submit membership application: status=submitted, from_level=current, to_level=observer.
     p_membership_type stored in event payload (informational — actual levels follow FSM).
     Error codes: ALREADY_ACTIVE, PENDING_EXISTS, NO_MEMBERSHIP, INVALID_MEMBERSHIP_TYPE.
     Event: identity.membership_application.submitted (is_audit=true).';


-- ============================================================
-- RPC-04: rpc_get_my_context
-- Dok 3 §2 (implicit) | Callers: [WEB] [AI]
-- Returns full user context for cabinet initialization
-- STABLE read function — no side effects
-- ============================================================
create or replace function public.rpc_get_my_context(
    p_organization_id   uuid    default null     -- optional: specific org context; null = all
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
    v_user_id   uuid;
    v_result    jsonb;
begin
    v_user_id := public.fn_current_user_id();
    if v_user_id is null then
        raise exception 'AUTH_REQUIRED: user not authenticated'
            using errcode = 'P0001';
    end if;

    select jsonb_build_object(
        'user_id', v_user_id,
        'organizations', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', o.id,
                'legal_name', o.legal_name,
                'bin_iin', o.bin_iin,
                'region_id', o.region_id,
                'phone', o.phone,
                'role', uor.role,
                'is_primary', uor.is_primary,
                'org_types', (
                    select coalesce(jsonb_agg(ota.org_type), '[]'::jsonb)
                    from public.organization_type_assignments ota
                    where ota.organization_id = o.id
                )
            ))
            from public.user_organization_roles uor
            join public.organizations o on o.id = uor.organization_id and o.is_active = true
            where uor.user_id = v_user_id
              and (p_organization_id is null or o.id = p_organization_id)
        ), '[]'::jsonb),
        'farms', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', f.id,
                'organization_id', f.organization_id,
                'name', f.name,
                'region_id', f.region_id,
                'shelter_type', f.shelter_type,
                'calving_system', f.calving_system,
                'total_area_ha', f.total_area_ha,
                'is_primary', f.is_primary,
                'activity_types', (
                    select coalesce(jsonb_agg(fat.activity_type), '[]'::jsonb)
                    from public.farm_activity_types fat
                    where fat.farm_id = f.id
                )
            ))
            from public.farms f
            join public.user_organization_roles uor2 on uor2.organization_id = f.organization_id
            where uor2.user_id = v_user_id
              and f.is_active = true
              and (p_organization_id is null or f.organization_id = p_organization_id)
        ), '[]'::jsonb),
        'memberships', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', m.id,
                'organization_id', m.organization_id,
                'org_type', m.org_type,
                'level', m.level,
                'level_changed_at', m.level_changed_at
            ))
            from public.memberships m
            join public.user_organization_roles uor3 on uor3.organization_id = m.organization_id
            where uor3.user_id = v_user_id
              and (p_organization_id is null or m.organization_id = p_organization_id)
        ), '[]'::jsonb),
        'active_restrictions', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', rr.id,
                'organization_id', rr.organization_id,
                'restriction_type', rr.restriction_type,
                'reason', rr.reason,
                'created_at', rr.created_at
            ))
            from public.restriction_records rr
            join public.user_organization_roles uor4 on uor4.organization_id = rr.organization_id
            where uor4.user_id = v_user_id
              and rr.lifted_at is null
              and (p_organization_id is null or rr.organization_id = p_organization_id)
        ), '[]'::jsonb)
    ) into v_result;

    return v_result;
end;
$$;

comment on function public.rpc_get_my_context(uuid) is
    'RPC-04 | Dok 3 §2 | Slice 1
     Full user context for cabinet initialization (F01, F02, F10 page load).
     STABLE: no side effects, safe to cache per transaction.
     Returns: { user_id, organizations[], farms[], memberships[], active_restrictions[] }
     p_organization_id optional — null returns all orgs, uuid filters to one.
     Used by both Web Cabinet and AI Gateway context loading.';


-- ============================================================
-- RPC-05: rpc_upsert_farm
-- Dok 3 §3.1 | Callers: [WEB] [AI]
-- Creates or updates Farm record
-- p_farm_id=null → INSERT, p_farm_id=uuid → UPDATE
-- ============================================================
create or replace function public.rpc_upsert_farm(
    p_organization_id   uuid,
    p_farm_id           uuid        default null,
    p_name              text        default null,
    p_region_id         uuid        default null,
    p_shelter_type      text        default null,
    p_calving_system    text        default null,
    p_total_area_ha     numeric     default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_farm_id       uuid;
    v_event_type    text;
begin
    if p_farm_id is null then
        -- CREATE new farm
        if p_name is null then
            raise exception 'NAME_REQUIRED: farm name is required for creation'
                using errcode = 'P0001';
        end if;

        insert into public.farms (
            organization_id,
            name,
            region_id,
            shelter_type,
            calving_system,
            total_area_ha,
            data_source,
            is_primary
        ) values (
            p_organization_id,
            p_name,
            p_region_id,
            p_shelter_type,
            p_calving_system,
            p_total_area_ha,
            'platform',
            -- is_primary = true only if this is the first farm for the org
            not exists (select 1 from public.farms where organization_id = p_organization_id and is_active = true)
        )
        returning id into v_farm_id;

        v_event_type := 'farm.farm.created';
    else
        -- UPDATE existing farm — ownership check
        if not exists (
            select 1 from public.farms
            where id = p_farm_id and organization_id = p_organization_id and is_active = true
        ) then
            raise exception 'FARM_NOT_FOUND: farm % does not belong to organization %', p_farm_id, p_organization_id
                using errcode = 'P0001';
        end if;

        update public.farms
        set    name           = coalesce(p_name, name),
               region_id      = coalesce(p_region_id, region_id),
               shelter_type   = coalesce(p_shelter_type, shelter_type),
               calving_system = coalesce(p_calving_system, calving_system),
               total_area_ha  = coalesce(p_total_area_ha, total_area_ha)
        where  id = p_farm_id
          and  organization_id = p_organization_id;

        v_farm_id := p_farm_id;
        v_event_type := 'farm.farm.updated';
    end if;

    -- Emit event
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
        v_event_type,
        'farms',
        v_farm_id,
        p_organization_id,
        'farmer',
        public.fn_current_user_id(),
        jsonb_build_object(
            'name', p_name,
            'region_id', p_region_id,
            'shelter_type', p_shelter_type,
            'calving_system', p_calving_system,
            'total_area_ha', p_total_area_ha
        ),
        false
    );

    return v_farm_id;
end;
$$;

comment on function public.rpc_upsert_farm(uuid, uuid, text, uuid, text, text, numeric) is
    'RPC-05 | Dok 3 §3.1 | Slice 1
     Create or update farm. p_farm_id=null → INSERT, p_farm_id=uuid → UPDATE.
     Ownership check: farm must belong to p_organization_id.
     Idempotent UPDATE: only non-null params overwrite (COALESCE pattern).
     First farm for an org gets is_primary=true automatically.
     Events: farm.farm.created | farm.farm.updated.';


-- ============================================================
-- RPC-05b: rpc_set_farm_activity_types
-- Dok 3 §3 | Callers: [WEB] [AI]
-- Sets activity types for a farm (full replacement, idempotent)
-- farm_activity_types is a junction table: (farm_id, activity_type)
-- ============================================================
create or replace function public.rpc_set_farm_activity_types(
    p_organization_id       uuid,
    p_farm_id               uuid,
    p_activity_types        text[]      -- array of activity_type values
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_inserted  text[];
    v_removed   text[];
    v_existing  text[];
begin
    -- Ownership check: farm must belong to org
    if not exists (
        select 1 from public.farms
        where id = p_farm_id and organization_id = p_organization_id and is_active = true
    ) then
        raise exception 'FARM_NOT_FOUND: farm % does not belong to organization %', p_farm_id, p_organization_id
            using errcode = 'P0001';
    end if;

    -- Get current activity types
    select array_agg(activity_type)
    into   v_existing
    from   public.farm_activity_types
    where  farm_id = p_farm_id;

    v_existing := coalesce(v_existing, array[]::text[]);

    -- Compute delta: what to remove (existing but not in new set)
    select array_agg(e)
    into   v_removed
    from   unnest(v_existing) as e
    where  e != all(p_activity_types);

    v_removed := coalesce(v_removed, array[]::text[]);

    -- Compute delta: what to insert (in new set but not existing)
    select array_agg(n)
    into   v_inserted
    from   unnest(p_activity_types) as n
    where  n != all(v_existing);

    v_inserted := coalesce(v_inserted, array[]::text[]);

    -- Remove old
    if array_length(v_removed, 1) > 0 then
        delete from public.farm_activity_types
        where  farm_id = p_farm_id
          and  activity_type = any(v_removed);
    end if;

    -- Insert new
    if array_length(v_inserted, 1) > 0 then
        insert into public.farm_activity_types (farm_id, activity_type)
        select p_farm_id, unnest(v_inserted)
        on conflict (farm_id, activity_type) do nothing;
    end if;

    -- Emit event
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
        'farm.farm_activity_types.updated',
        'farm_activity_types',
        p_farm_id,
        p_organization_id,
        'farmer',
        public.fn_current_user_id(),
        jsonb_build_object(
            'inserted', to_jsonb(v_inserted),
            'removed', to_jsonb(v_removed),
            'current', to_jsonb(p_activity_types)
        ),
        false
    );

    return jsonb_build_object(
        'inserted', to_jsonb(v_inserted),
        'removed',  to_jsonb(v_removed)
    );
end;
$$;

comment on function public.rpc_set_farm_activity_types(uuid, uuid, text[]) is
    'RPC-05b | Dok 3 §3 | Slice 1
     Set activity types for a farm (full replacement).
     Idempotent: accepts full set, computes delta (inserted/removed).
     Valid activity_types: cow_calf, finishing, dairy, breeding, mixed (schema CHECK).
     Ownership check: farm must belong to p_organization_id.
     Event: farm.farm_activity_types.updated.';


-- ============================================================
-- RPC-40: rpc_start_ai_conversation
-- Dok 3 §9.1 | Callers: [AI]
-- Creates AIConversation record for a farm
-- This function is in d01 (platform domain), NOT d07
-- ============================================================
create or replace function public.rpc_start_ai_conversation(
    p_organization_id   uuid,
    p_farm_id           uuid        default null,
    p_phone             text        default null,
    p_language          text        default 'ru'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_user_id       uuid;
    v_conv_id       uuid;
    v_context       jsonb;
begin
    -- Resolve user: from JWT or by phone
    v_user_id := public.fn_current_user_id();

    -- If called by AI Gateway (service_role), resolve by phone
    if v_user_id is null and p_phone is not null then
        select u.id into v_user_id
        from   public.users u
        where  u.phone = p_phone and u.is_active = true
        limit  1;
    end if;

    if v_user_id is null then
        raise exception 'USER_NOT_FOUND: cannot resolve user for conversation'
            using errcode = 'P0001';
    end if;

    -- Validate organization ownership
    if not exists (
        select 1 from public.user_organization_roles
        where user_id = v_user_id and organization_id = p_organization_id
    ) then
        raise exception 'ORG_NOT_FOUND: user does not belong to organization %', p_organization_id
            using errcode = 'P0001';
    end if;

    -- Validate language
    if p_language not in ('ru', 'kk') then
        p_language := 'ru';
    end if;

    -- Check for existing active conversation (reuse if within 24h window)
    select id into v_conv_id
    from   public.ai_conversations
    where  organization_id = p_organization_id
      and  user_id = v_user_id
      and  is_active = true
      and  session_expires_at > now()
    order by created_at desc
    limit 1;

    if v_conv_id is not null then
        -- Reuse existing active conversation
        -- Update active_farm_id if a new farm is specified
        if p_farm_id is not null then
            update public.ai_conversations
            set    active_farm_id = p_farm_id
            where  id = v_conv_id;
        end if;
    else
        -- Create new conversation
        insert into public.ai_conversations (
            organization_id,
            user_id,
            channel,
            "current_role",
            active_farm_id,
            detected_language,
            session_started_at,
            session_expires_at
        ) values (
            p_organization_id,
            v_user_id,
            'whatsapp',
            'consultant',
            p_farm_id,
            p_language,
            now(),
            now() + interval '24 hours'
        )
        returning id into v_conv_id;
    end if;

    -- Load context via rpc_get_ai_farm_context if farm_id is set
    -- NOTE: rpc_get_ai_farm_context is defined in d07_ai_gateway.sql
    -- We call it here only if it exists; otherwise return minimal context
    -- S-11 FIX: verify farm belongs to organization before loading context
    if p_farm_id is not null then
        if not exists (
            select 1 from public.farms
            where id = p_farm_id and organization_id = p_organization_id and is_active = true
        ) then
            p_farm_id := null;  -- silently ignore invalid farm_id, don't block conversation
        end if;
    end if;
    if p_farm_id is not null then
        begin
            select public.rpc_get_ai_farm_context(p_organization_id, p_farm_id)
            into   v_context;
        exception when undefined_function then
            -- d07 not yet deployed; return minimal context
            v_context := jsonb_build_object(
                'farm_id', p_farm_id,
                'note', 'full context not available — d07 not deployed'
            );
        end;
    else
        v_context := jsonb_build_object(
            'note', 'no farm specified'
        );
    end if;

    -- Emit event
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
        'platform.ai_conversation.started',
        'ai_conversations',
        v_conv_id,
        p_organization_id,
        'ai_gateway',
        v_user_id,
        jsonb_build_object(
            'farm_id', p_farm_id,
            'language', p_language,
            'reused', v_conv_id is not null
        ),
        false
    );

    return jsonb_build_object(
        'conv_id', v_conv_id,
        'context', v_context
    );
end;
$$;

comment on function public.rpc_start_ai_conversation(uuid, uuid, text, text) is
    'RPC-40 | Dok 3 §9.1 | Slice 1
     Initialize AI conversation session (24h window per D64).
     Reuses existing active conversation if within 24h window.
     Loads farm context via rpc_get_ai_farm_context (d07) if available.
     Called by AI Gateway at start of WhatsApp interaction.
     p_phone: used when caller is service_role (AI Gateway) to resolve user.
     p_language: detected language (ru/kk). Default ru.
     Event: platform.ai_conversation.started.';


-- ============================================================
-- SLICE 1: Add new RPCs to rpc_name_registry
-- ============================================================
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('rpc_register_organization',           'rpc_register_organization',            null,   'd01_kernel.sql (Slice 1)',     'RPC-01: Atomic org registration + farm auto-create'),
    ('rpc_submit_membership_application',   'rpc_submit_membership_application',    null,   'd01_kernel.sql (Slice 1)',     'RPC-02: Submit membership application'),
    ('rpc_get_my_context',                  'rpc_get_my_context',                   null,   'd01_kernel.sql (Slice 1)',     'RPC-04: Full user context for cabinet init'),
    ('rpc_upsert_farm',                     'rpc_upsert_farm',                      null,   'd01_kernel.sql (Slice 1)',     'RPC-05: Create or update farm'),
    ('rpc_set_farm_activity_types',         'rpc_set_farm_activity_types',           null,   'd01_kernel.sql (Slice 1)',     'RPC-05b: Set farm activity types (full replacement)'),
    ('rpc_start_ai_conversation',           'rpc_start_ai_conversation',            null,   'd01_kernel.sql (Slice 1)',     'RPC-40: Initialize AI conversation session')
on conflict (sql_name) do update
    set dok3_name      = excluded.dok3_name,
        dok5_tool_name = excluded.dok5_tool_name,
        notes          = excluded.notes,
        created_in     = excluded.created_in;

-- ============================================================
-- END Slice 1 d01_kernel.sql RPCs
-- ============================================================
-- Summary:
--   RPC-01  rpc_register_organization          ✅ Implemented
--   RPC-02  rpc_submit_membership_application  ✅ Implemented
--   RPC-04  rpc_get_my_context                 ✅ Implemented
--   RPC-05  rpc_upsert_farm                    ✅ Implemented
--   RPC-05b rpc_set_farm_activity_types        ✅ Implemented
--   RPC-40  rpc_start_ai_conversation          ✅ Implemented
--
-- All functions: SECURITY DEFINER + SET search_path = public, pg_temp
-- All functions: p_organization_id as parameter (P-AI-2)
-- All functions: CREATE OR REPLACE (idempotent)
-- All functions: Events via INSERT INTO platform_events
-- All functions: Added to rpc_name_registry
--
-- DEFECTS FLAGGED:
--   1. CEO decision D-F01-3 mentions org_types 'services' and 'feed_producer'
--      that do NOT exist in schema CHECK constraint on organization_type_assignments.
--      Schema allows: farmer, mpk, supplier, consultant, other.
--      Resolution needed: either update schema CHECK or CEO revises decision.
--
--   2. Migration 015 content (fn_auth_custom_claims, embedding_queue) was
--      truncated during consolidation. Needs restoration.
-- ============================================================


-- ============================================================
-- SLICE 2: Membership Admin RPCs
-- Dok 6: AGOS-Dok6-Slice2-Membership.md
-- Screens: A01 (Membership Queue), A02 (Membership Decision)
-- ============================================================


-- ============================================================
-- rpc_get_membership_queue (NEW — not in Dok 3)
-- D-S2-1: Dual mode — list (paginated) or detail (by application_id)
-- Callers: [ADMIN] only
-- ============================================================
create or replace function public.rpc_get_membership_queue(
    p_organization_id   uuid,           -- P-AI-2 convention; not used for filtering (admin sees all)
    p_application_id    uuid    default null,    -- null = list mode; non-null = detail mode
    p_status_filter     text    default null,    -- null = all statuses; 'submitted', 'under_review', 'approved', 'rejected'
    p_page              int     default 1,
    p_page_size         int     default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
    v_admin_user_id uuid;
    v_offset        int;
    v_result        jsonb;
    v_total_count   int;
begin
    -- Admin guard
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin access required'
            using errcode = 'P0001';
    end if;

    v_admin_user_id := public.fn_current_user_id();

    -- ── DETAIL MODE: return single application with full context ──
    if p_application_id is not null then
        select jsonb_build_object(
            'application_id',   ma.id,
            'org_id',           o.id,
            'org_name',         o.legal_name,
            'org_type',         ota.org_type,
            'bin',              o.bin_iin,
            'region_name',      r.name_ru,
            'org_created_at',   o.created_at,
            'from_level',       ma.from_level,
            'to_level',         ma.to_level,
            'status',           ma.status,
            'submitted_at',     ma.submitted_at,
            'notes',            ma.reviewer_notes,
            'reviewed_at',      ma.reviewed_at,
            'reviewed_by',      ma.reviewed_by,
            'reviewer_name',    rev_u.full_name,
            'membership_level', m.level,
            'membership_level_changed_at', m.level_changed_at,
            -- Farm summary (aggregated)
            'farms', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'farm_id',      f.id,
                    'farm_name',    f.name,
                    'herd_groups',  (
                        select coalesce(jsonb_agg(jsonb_build_object(
                            'category_name',    ac.name_ru,
                            'breed_name',       br.name_ru,
                            'head_count',       hg.head_count,
                            'avg_weight_kg',    hg.avg_weight_kg
                        ) order by ac.name_ru), '[]'::jsonb)
                        from public.herd_groups hg
                        left join public.animal_categories ac on ac.id = hg.animal_category_id
                        left join public.breeds br on br.id = hg.breed_id
                        where hg.farm_id = f.id and hg.is_active = true
                    ),
                    'activity_types', (
                        select coalesce(jsonb_agg(fat.activity_type order by fat.activity_type), '[]'::jsonb)
                        from public.farm_activity_types fat
                        where fat.farm_id = f.id
                    )
                )), '[]'::jsonb)
                from public.farms f
                where f.organization_id = o.id and f.is_active = true
            ),
            -- Application history (previous applications for this org)
            'application_history', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'id',               prev.id,
                    'status',           prev.status,
                    'from_level',       prev.from_level,
                    'to_level',         prev.to_level,
                    'submitted_at',     prev.submitted_at,
                    'reviewed_at',      prev.reviewed_at,
                    'reviewer_notes',   prev.reviewer_notes
                ) order by prev.submitted_at desc), '[]'::jsonb)
                from public.membership_applications prev
                where prev.organization_id = o.id
                  and prev.id != ma.id
            )
        ) into v_result
        from public.membership_applications ma
        join public.memberships m on m.id = ma.membership_id
        join public.organizations o on o.id = ma.organization_id
        left join public.organization_type_assignments ota on ota.organization_id = o.id
        left join public.regions r on r.id = o.region_id
        left join public.users rev_u on rev_u.id = ma.reviewed_by
        where ma.id = p_application_id;

        if v_result is null then
            raise exception 'APPLICATION_NOT_FOUND: application_id=% not found', p_application_id
                using errcode = 'P0001';
        end if;

        return v_result;
    end if;

    -- ── LIST MODE: paginated queue ──
    v_offset := (p_page - 1) * p_page_size;

    -- Count total
    select count(*) into v_total_count
    from public.membership_applications ma
    where (p_status_filter is null or ma.status = p_status_filter);

    -- Build list
    select jsonb_build_object(
        'items', coalesce((
            select jsonb_agg(row_data order by row_data->>'submitted_at' desc)
            from (
                select jsonb_build_object(
                    'application_id',   ma.id,
                    'org_id',           o.id,
                    'org_name',         o.legal_name,
                    'org_type',         ota.org_type,
                    'bin',              o.bin_iin,
                    'region_name',      r.name_ru,
                    'from_level',       ma.from_level,
                    'to_level',         ma.to_level,
                    'status',           ma.status,
                    'submitted_at',     ma.submitted_at,
                    'notes',            ma.reviewer_notes
                ) as row_data
                from public.membership_applications ma
                join public.organizations o on o.id = ma.organization_id
                left join public.organization_type_assignments ota on ota.organization_id = o.id
                left join public.regions r on r.id = o.region_id
                where (p_status_filter is null or ma.status = p_status_filter)
                order by ma.submitted_at desc
                limit p_page_size
                offset v_offset
            ) sub
        ), '[]'::jsonb),
        'total_count',  v_total_count,
        'page',         p_page,
        'page_size',    p_page_size
    ) into v_result;

    return v_result;
end;
$$;

comment on function public.rpc_get_membership_queue(uuid, uuid, text, int, int) is
    'Slice 2 | D-S2-1 | Admin-only membership queue.
     Dual mode: p_application_id=null → paginated list; p_application_id=uuid → full detail.
     Detail includes: org info, farms, herd groups, activity types, application history.
     Requires fn_is_admin(). p_organization_id present for P-AI-2 convention only.';


-- ============================================================
-- RPC-03: rpc_process_membership_application
-- Dok 3 §2 | Callers: [ADMIN]
-- FSM: submitted/under_review → approved | rejected
-- ВАЖНО (membership_purchase_flow): одобрение НЕ выдаёт членство — лишь помечает заявку
-- approved. Уровень членства выдаётся ОПЛАТОЙ (rpc_pay_membership_dues, ниже).
-- Events: identity.membership_application.decided (на оба решения)
-- D-S2-2: Inserts WhatsApp + in_app notifications
-- ============================================================
create or replace function public.rpc_process_membership_application(
    p_organization_id   uuid,           -- P-AI-2 convention; the org whose application is being processed
    p_application_id    uuid,
    p_decision          text,           -- 'approved' | 'rejected'
    p_decision_notes    text    default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_admin_user_id     uuid;
    v_app               record;
    v_membership_id     uuid;
    v_farmer_user_id    uuid;
    v_farmer_org_id     uuid;
    v_event_id          uuid;
    v_new_level         text;
    v_org_name          text;
begin
    -- 1. Admin guard
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin access required'
            using errcode = 'P0001';
    end if;

    v_admin_user_id := public.fn_current_user_id();

    -- 2. Validate decision
    if p_decision not in ('approved', 'rejected') then
        raise exception 'INVALID_DECISION: must be approved or rejected, got %', p_decision
            using errcode = 'P0001';
    end if;

    -- 3. Load application
    select ma.id, ma.membership_id, ma.organization_id, ma.from_level, ma.to_level, ma.status
    into   v_app
    from   public.membership_applications ma
    where  ma.id = p_application_id;

    if v_app is null then
        raise exception 'APPLICATION_NOT_FOUND: application_id=% not found', p_application_id
            using errcode = 'P0001';
    end if;

    -- 4. Validate FSM: only submitted or under_review can be decided
    if v_app.status not in ('submitted', 'under_review') then
        raise exception 'ALREADY_DECIDED: application already has status=%', v_app.status
            using errcode = 'P0001';
    end if;

    v_membership_id := v_app.membership_id;
    v_farmer_org_id := v_app.organization_id;
    v_new_level     := v_app.to_level;   -- целевой уровень (для уведомления; выдаётся ОПЛАТОЙ)

    -- Get org name for notification
    select o.legal_name into v_org_name
    from public.organizations o
    where o.id = v_farmer_org_id;

    -- 5. Update application status (FSM). НЕ трогаем memberships.level — выдача идёт оплатой
    --    (rpc_pay_membership_dues). Одобрение лишь помечает заявку approved.
    update public.membership_applications
    set    status         = p_decision,
           reviewed_at    = now(),
           reviewed_by    = v_admin_user_id,
           reviewer_notes = p_decision_notes,
           updated_at     = now()
    where  id = p_application_id;

    -- 6. Event: фиксируем решение (без активации членства) — на оба решения.
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'identity.membership_application.decided',
        'membership_applications',
        p_application_id,
        v_farmer_org_id,
        'admin',
        v_admin_user_id,
        jsonb_build_object(
            'decision', p_decision,
            'from_level', v_app.from_level,
            'to_level', v_new_level,
            'decision_notes', p_decision_notes
        ),
        true
    )
    returning id into v_event_id;

    -- 7. D-S2-2: Insert notifications (WhatsApp + in_app)
    -- Find the farmer user (organization owner)
    select u.id into v_farmer_user_id
    from public.users u
    join public.user_organization_roles uor on uor.user_id = u.id
    where uor.organization_id = v_farmer_org_id
      and uor.role = 'owner'
    limit 1;

    if v_farmer_user_id is not null then
        if p_decision = 'approved' then
            -- WhatsApp notification: application_approved
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'whatsapp',
                'application_approved',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'new_level', v_new_level
                ),
                v_event_id, 'pending'
            );
            -- In-app notification
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'in_app',
                'application_approved',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'new_level', v_new_level
                ),
                v_event_id, 'pending'
            );
        else
            -- WhatsApp notification: application_rejected
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'whatsapp',
                'application_rejected',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'reject_reason', coalesce(p_decision_notes, 'Не указана'),
                    'contact_info', '+7 (700) 000-00-00'
                ),
                v_event_id, 'pending'
            );
            -- In-app notification
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'in_app',
                'application_rejected',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'reject_reason', coalesce(p_decision_notes, 'Не указана'),
                    'contact_info', '+7 (700) 000-00-00'
                ),
                v_event_id, 'pending'
            );
        end if;
    end if;

    return v_membership_id;
end;
$$;

comment on function public.rpc_process_membership_application(uuid, uuid, text, text) is
    'RPC-03 | Dok 3 §2 | Slice 2+ (membership_purchase_flow)
     Admin approves or rejects membership application.
     FSM: submitted/under_review → approved/rejected.
     ВАЖНО: одобрение НЕ выдаёт членство (memberships.level НЕ меняется) — уровень
     выдаётся ОПЛАТОЙ взноса (rpc_pay_membership_dues).
     Event: identity.membership_application.decided (на оба решения).
     D-S2-2: Inserts notifications (whatsapp + in_app) for farmer.
     Error codes: FORBIDDEN, INVALID_DECISION, APPLICATION_NOT_FOUND, ALREADY_DECIDED.';


-- ============================================================
-- rpc_pay_membership_dues — оплата взноса после одобрения (симуляция, пилот)
-- membership_purchase_flow | Callers: [FARMER/OWNER]
-- Требует одобренную заявку. Поднимает level registered → to_level (observer).
-- Доступ только к своим org (fn_my_org_ids). Идемпотентно для уже-члена.
-- ВАЖНО: actor_type='farmer' (не 'user' — нарушает platform_events_actor_type_check).
-- ============================================================
create or replace function public.rpc_pay_membership_dues(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid           uuid;
    v_membership_id uuid;
    v_current_level text;
    v_app_id        uuid;
    v_to_level      text;
    v_event_id      uuid;
begin
    v_uid := public.fn_current_user_id();
    if v_uid is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    -- Доступ только к своим организациям.
    if not (p_organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: organization not owned by current user'
            using errcode = 'P0001';
    end if;

    select id, level
    into   v_membership_id, v_current_level
    from   public.memberships
    where  organization_id = p_organization_id
    limit  1;

    if v_membership_id is null then
        raise exception 'NO_MEMBERSHIP: organization % has no membership record', p_organization_id
            using errcode = 'P0001';
    end if;

    -- Уже член (level выше registered) — идемпотентный ранний выход.
    if v_current_level <> 'registered' then
        return jsonb_build_object(
            'membership_id', v_membership_id,
            'level', v_current_level,
            'already_member', true
        );
    end if;

    -- Требуется ОДОБРЕННАЯ заявка (админ-гейт). Без неё оплата невозможна.
    select id, to_level
    into   v_app_id, v_to_level
    from   public.membership_applications
    where  organization_id = p_organization_id
      and  status = 'approved'
    order by reviewed_at desc nulls last, submitted_at desc
    limit  1;

    if v_app_id is null then
        raise exception 'NO_APPROVED_APPLICATION: organization % has no approved application', p_organization_id
            using errcode = 'P0001';
    end if;

    v_to_level := coalesce(v_to_level, 'observer');

    -- Поднимаем уровень членства registered → to_level (оплата = активация).
    update public.memberships
       set previous_level   = level,
           level            = v_to_level,
           level_changed_at = now(),
           level_changed_by = v_uid,
           updated_at       = now()
     where id = v_membership_id;

    -- Событие активации членства (оплата взноса, симуляция на пилоте).
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'identity.membership.activated',
        'memberships',
        v_membership_id,
        p_organization_id,
        'farmer',  -- platform_events_actor_type_check: farmer|admin|expert|system|ai_gateway
        v_uid,
        jsonb_build_object(
            'application_id', v_app_id,
            'old_level', 'registered',
            'new_level', v_to_level,
            'payment', 'simulated'
        ),
        true
    )
    returning id into v_event_id;

    return jsonb_build_object(
        'membership_id', v_membership_id,
        'level', v_to_level,
        'application_id', v_app_id,
        'event_id', v_event_id,
        'already_member', false
    );
end;
$$;

grant execute on function public.rpc_pay_membership_dues(uuid) to authenticated;

comment on function public.rpc_pay_membership_dues(uuid) is
    'membership_purchase_flow | Оплата членского взноса после одобрения (симуляция на пилоте).
     Требует membership_application со статусом approved; поднимает memberships.level
     registered→to_level (observer). Доступ только к своим org (fn_my_org_ids).
     Идемпотентно для уже-члена. Error: AUTH_REQUIRED, FORBIDDEN, NO_MEMBERSHIP, NO_APPROVED_APPLICATION.';


-- ============================================================
-- SLICE 2: Add new RPCs to rpc_name_registry
-- ============================================================
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('rpc_get_membership_queue',            null,                                   null,   'd01_kernel.sql (Slice 2)',     'Admin dual-mode: queue list + application detail'),
    ('rpc_process_membership_application',  'rpc_process_membership_application',   null,   'd01_kernel.sql (Slice 2)',     'RPC-03: Approve/reject заявку (членство НЕ выдаёт — выдаёт оплата) + WA notification'),
    ('rpc_pay_membership_dues',             null,                                   null,   'd01_kernel.sql (membership_purchase_flow)', 'Оплата взноса после одобрения (симуляция): registered→observer')
on conflict (sql_name) do update
    set dok3_name      = excluded.dok3_name,
        dok5_tool_name = excluded.dok5_tool_name,
        notes          = excluded.notes,
        created_in     = excluded.created_in;

-- ============================================================
-- END Slice 2 d01_kernel.sql RPCs
-- ============================================================
-- Summary:
--   NEW   rpc_get_membership_queue             ✅ Implemented
--   RPC-03  rpc_process_membership_application ✅ Implemented (одобрение НЕ выдаёт членство)
--   NEW   rpc_pay_membership_dues              ✅ Implemented (оплата = выдача membership level)
--
-- All functions: SECURITY DEFINER + SET search_path = public, pg_temp
-- All functions: p_organization_id as parameter (P-AI-2)
-- rpc_process_membership_application: fn_is_admin() guard; events + notifications (WA + in_app)
-- rpc_pay_membership_dues: fn_my_org_ids() guard (farmer/owner); event identity.membership.activated
-- ============================================================

-- ============================================================
-- SLICE 3: Feed Planning RPCs (d01_kernel.sql portion)
-- RPC-07: rpc_log_herd_event
-- RPC-08: rpc_get_farm_summary
-- ============================================================

-- ============================================================
-- RPC-07: rpc_log_herd_event
-- Dok 3 §3 | Callers: [WEB] [AI]
-- Append-only INSERT into herd_events (D25).
-- Events: farm.herd_event.logged (Dok 4)
-- ============================================================
create or replace function public.rpc_log_herd_event(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_herd_group_id     uuid        default null,
    p_event_type        text        default null,
    p_value_before      numeric     default null,
    p_value_after       numeric     default null,
    p_data_source       text        default 'platform',
    p_event_date        date        default null,
    p_notes             text        default null,
    p_metadata          jsonb       default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_event_id  uuid;
begin
    -- Validate required fields
    if p_event_type is null then
        raise exception 'EVENT_TYPE_REQUIRED: p_event_type cannot be null'
            using errcode = 'P0001';
    end if;
    if p_value_after is null then
        raise exception 'VALUE_AFTER_REQUIRED: p_value_after cannot be null'
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

    -- If herd_group_id provided, verify it belongs to the farm
    if p_herd_group_id is not null then
        if not exists (
            select 1 from public.herd_groups
            where id = p_herd_group_id and farm_id = p_farm_id and is_active = true
        ) then
            raise exception 'HERD_GROUP_NOT_FOUND: group % does not belong to farm %',
                p_herd_group_id, p_farm_id using errcode = 'P0001';
        end if;
    end if;

    -- D25: Append-only INSERT (never UPDATE herd_events)
    insert into public.herd_events (
        farm_id,
        organization_id,
        herd_group_id,
        event_type,
        value_before,
        value_after,
        event_date,
        data_source,
        recorded_by,
        notes,
        metadata
    ) values (
        p_farm_id,
        p_organization_id,
        p_herd_group_id,
        p_event_type,
        p_value_before,
        p_value_after,
        coalesce(p_event_date, current_date),
        p_data_source,
        public.fn_current_user_id(),
        p_notes,
        p_metadata
    )
    returning id into v_event_id;

    -- Emit event: farm.herd_event.logged (Dok 4 §3.2)
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
        'farm.herd_event.logged',
        'herd_events',
        v_event_id,
        p_organization_id,
        'farmer',
        public.fn_current_user_id(),
        jsonb_build_object(
            'event_id', v_event_id,
            'farm_id', p_farm_id,
            'group_id', p_herd_group_id,
            'event_type', p_event_type,
            'value_before', p_value_before,
            'value_after', p_value_after
        ),
        false
    );

    return v_event_id;
end;
$$;

comment on function public.rpc_log_herd_event(uuid, uuid, uuid, text, numeric, numeric, text, date, text, jsonb) is
    'RPC-07 | Dok 3 §3 | Slice 3
     Append-only INSERT into herd_events (D25). Never UPDATE.
     event_type validated by CHECK constraint on herd_events table.
     delta = value_after - value_before (generated column).
     recorded_by = current user (null if system/ERP).
     Events: farm.herd_event.logged.';



-- ============================================================
-- RPC-08: rpc_get_farm_summary
-- Dok 3 §3 | Callers: [WEB] [AI]
-- Cross-domain read: farm + herd_groups + feed_inventory + vet_cases + tasks
-- Returns jsonb summary for farmer cabinet and AI context.
-- ============================================================
create or replace function public.rpc_get_farm_summary(
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
    v_farm              jsonb;
    v_herd_groups       jsonb;
    v_feed_inventory    jsonb;
    v_active_vet_cases  jsonb;
    v_upcoming_tasks    jsonb;
    v_result            jsonb;
begin
    -- Ownership check
    if not exists (
        select 1 from public.farms
        where id = p_farm_id and organization_id = p_organization_id and is_active = true
    ) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    -- Farm basic info
    select jsonb_build_object(
        'id', f.id,
        'name', f.name,
        'region_id', f.region_id,
        'shelter_type', f.shelter_type,
        'calving_system', f.calving_system,
        'total_area_ha', f.total_area_ha,
        'is_primary', f.is_primary
    ) into v_farm
    from public.farms f
    where f.id = p_farm_id;

    -- Herd groups with category and breed info
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', hg.id,
            'animal_category_id', hg.animal_category_id,
            'animal_category_code', ac.code,
            'animal_category_name_ru', ac.name_ru,
            'breed_id', hg.breed_id,
            'breed_name_ru', b.name_ru,
            'head_count', hg.head_count,
            'avg_weight_kg', hg.avg_weight_kg,
            'data_source', hg.data_source,
            'confidence', hg.confidence,
            'updated_at', hg.updated_at
        ) order by ac.code
    ), '[]'::jsonb) into v_herd_groups
    from public.herd_groups hg
    join public.animal_categories ac on ac.id = hg.animal_category_id
    left join public.breeds b on b.id = hg.breed_id
    where hg.farm_id = p_farm_id
      and hg.is_active = true;

    -- Feed inventory with feed item details
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', ffi.id,
            'feed_item_id', ffi.feed_item_id,
            'feed_item_code', fi.code,
            'feed_item_name_ru', fi.name_ru,
            'feed_category_code', fc.code,
            'feed_category_name_ru', fc.name_ru,
            'quantity_kg', ffi.quantity_kg,
            'data_source', ffi.data_source,
            'confidence', ffi.confidence,
            'last_updated_date', ffi.last_updated_date,
            'updated_at', ffi.updated_at
        ) order by fc.sort_order, fi.name_ru
    ), '[]'::jsonb) into v_feed_inventory
    from public.farm_feed_inventory ffi
    join public.feed_items fi on fi.id = ffi.feed_item_id
    join public.feed_categories fc on fc.id = fi.feed_category_id
    where ffi.farm_id = p_farm_id
      and ffi.organization_id = p_organization_id;

    -- Active vet cases (open or in_progress)
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', vc.id,
            'herd_group_id', vc.herd_group_id,
            'severity', vc.severity,
            'status', vc.status,
            'symptoms_text', vc.symptoms_text,
            'affected_head_count', vc.affected_head_count,
            'created_at', vc.created_at
        ) order by vc.created_at desc
    ), '[]'::jsonb) into v_active_vet_cases
    from public.vet_cases vc
    where vc.farm_id = p_farm_id
      and vc.organization_id = p_organization_id
      and vc.status in ('open', 'in_progress', 'escalated');

    -- Upcoming tasks (scheduled or reminded, due within 30 days)
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', ft.id,
            'name_ru', ft.name_ru,
            'category', ft.category,
            'due_date', ft.due_date,
            'status', ft.status
        ) order by ft.due_date
    ), '[]'::jsonb) into v_upcoming_tasks
    from public.farm_tasks ft
    where ft.organization_id = p_organization_id
      and ft.status in ('scheduled', 'reminded', 'in_progress', 'overdue')
      and ft.due_date <= current_date + interval '30 days';

    -- Build result
    v_result := jsonb_build_object(
        'farm', v_farm,
        'herd_groups', v_herd_groups,
        'feed_inventory', v_feed_inventory,
        'active_vet_cases', v_active_vet_cases,
        'upcoming_tasks', v_upcoming_tasks
    );

    return v_result;
end;
$$;

comment on function public.rpc_get_farm_summary(uuid, uuid) is
    'RPC-08 | Dok 3 §3 | Slice 3
     Cross-domain farm summary: herd groups (+ category/breed names),
     feed inventory (+ item/category names), active vet cases, upcoming tasks.
     STABLE read — no side effects.
     Used by: F03 (Herd Overview), F15 (Feed Inventory), AI Gateway context.';



-- ============================================================
-- SLICE 3: Add new RPCs to rpc_name_registry
-- ============================================================
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('rpc_log_herd_event',   'rpc_log_herd_event',   null, 'd01_kernel.sql (Slice 3)', 'RPC-07: Append-only herd event log'),
    ('rpc_get_farm_summary', 'rpc_get_farm_summary',  null, 'd01_kernel.sql (Slice 3)', 'RPC-08: Cross-domain farm summary (herd + feed + vet + tasks)')
on conflict (sql_name) do update
    set dok3_name      = excluded.dok3_name,
        dok5_tool_name = excluded.dok5_tool_name,
        notes          = excluded.notes,
        created_in     = excluded.created_in;

-- ============================================================
-- END Slice 3 d01_kernel.sql RPCs
-- ============================================================



-- ============================================================
-- SLICE 6a: RPC-45 rpc_restrict_organization
-- Admin: create health restriction on organization. D98 TSP safety gate.
-- ============================================================
create or replace function public.rpc_restrict_organization(
    p_organization_id       uuid,
    p_herd_group_id         uuid,
    p_restriction_type      text        default 'disease_suspected',
    p_reason                text        default null,
    p_valid_until           timestamptz default null,
    p_vet_case_id           uuid        default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_restriction_id uuid;
    v_ends_at timestamptz;
begin
    -- Admin check
    if not public.fn_is_admin() and not public.fn_is_expert() then
        raise exception 'FORBIDDEN: admin or expert access required' using errcode = 'P0001';
    end if;

    -- Validate restriction type
    if p_restriction_type not in ('medication_withdrawal', 'quarantine', 'disease_suspected', 'lab_pending') then
        raise exception 'INVALID_RESTRICTION_TYPE: %', p_restriction_type using errcode = 'P0001';
    end if;

    -- Verify herd group belongs to organization
    if not exists (
        select 1 from public.herd_groups hg
        join public.farms f on f.id = hg.farm_id
        where hg.id = p_herd_group_id and f.organization_id = p_organization_id and hg.is_active = true
    ) then
        raise exception 'HERD_GROUP_NOT_FOUND' using errcode = 'P0001';
    end if;

    v_ends_at := coalesce(p_valid_until, now() + interval '30 days');

    insert into public.health_restrictions (
        herd_group_id, organization_id, restriction_type,
        vet_case_id, starts_at, ends_at, is_active
    ) values (
        p_herd_group_id, p_organization_id, p_restriction_type,
        p_vet_case_id, now(), v_ends_at
    )
    returning id into v_restriction_id;

    -- Emit event
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'vet.restriction.created', 'health_restrictions', v_restriction_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('restriction_id', v_restriction_id, 'restriction_type', p_restriction_type,
            'herd_group_id', p_herd_group_id, 'ends_at', v_ends_at),
        true  -- audit-worthy
    );

    return v_restriction_id;
end;
$$;

comment on function public.rpc_restrict_organization(uuid, uuid, text, text, timestamptz, uuid) is
    'RPC-45 | Dok 3 §9 | Slice 6a
     D98: TSP safety gate. Creates health_restriction blocking batch creation.
     Admin or expert can create. Auto-deactivated when ends_at passes.
     Events: vet.restriction.created (is_audit=true).';

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_restrict_organization', 'rpc_restrict_organization', null, 'd01_kernel.sql (Slice 6a)', 'RPC-45: Health restriction (D98 TSP safety gate)')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;



-- FIX: Unique index for rpc_upsert_herd_group ON CONFLICT
create unique index if not exists idx_herd_groups_farm_category
    on public.herd_groups (farm_id, animal_category_id);



-- ============================================================
-- SLICE 6b: rpc_assign_role
-- Admin assigns/revokes admin or expert roles.
-- ============================================================
create or replace function public.rpc_assign_role(
    p_organization_id   uuid,
    p_target_user_id    uuid,
    p_role_type         text,       -- 'admin' | 'expert'
    p_action            text        default 'grant',  -- 'grant' | 'revoke'
    p_specialization    text        default 'general'
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;

    if p_role_type = 'admin' then
        if p_action = 'grant' then
            insert into public.admin_roles (user_id, role)
            values (p_target_user_id, 'admin')
            on conflict (user_id) do nothing;
        else
            update public.admin_roles set is_active = false where user_id = p_target_user_id;
        end if;
    elsif p_role_type = 'expert' then
        if p_action = 'grant' then
            insert into public.expert_profiles (user_id, specialization)
            values (p_target_user_id, p_specialization)
            on conflict (user_id) do nothing;
        else
            update public.expert_profiles set is_active = false where user_id = p_target_user_id;
        end if;
    else
        raise exception 'INVALID_ROLE_TYPE: must be admin or expert' using errcode = 'P0001';
    end if;

    insert into public.platform_events (event_type,entity_type,entity_id,organization_id,actor_type,actor_id,payload,is_audit)
    values ('identity.role.changed','users',p_target_user_id,p_organization_id,'admin',public.fn_current_user_id(),
        jsonb_build_object('target_user_id',p_target_user_id,'role_type',p_role_type,'action',p_action),true);

    return true;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_assign_role', null, 'd01_kernel.sql (Slice 6b)', 'Admin assign/revoke admin or expert roles')
on conflict (sql_name) do update set notes = excluded.notes;


-- ============================================================
-- SECTION ADR-ANIMAL-01: Animal Taxonomy L1 axes + L2 projections
-- ============================================================
-- Date: 2026-04-15
-- Reference: DECISIONS_LOG.md §2026-04-15 ADR-ANIMAL-01
-- Slices delivered in this section:
--   TAXONOMY-M1: ALTER animal_categories (+ purpose, state, age_band, status, deprecated_at, replaced_by_codes)
--   TAXONOMY-M2: CREATE animal_category_mappings + seed existing hardcodes
--   TAXONOMY-M3a: 6 RPCs + RLS + audit trigger
--   TAXONOMY-M4: CREATE external_category_mappings
-- ALL statements additive and idempotent (P7).
-- Principles: P1, P3, P4, P6, P7, P8, P11, P12.
-- ============================================================


-- ------------------------------------------------------------
-- M1.1 — ALTER animal_categories: add 3 semantic axes + lifecycle
-- ------------------------------------------------------------

alter table public.animal_categories
    add column if not exists purpose text
        check (purpose in ('breeding','fattening','replacement','culling','mixed'));

alter table public.animal_categories
    add column if not exists physiological_state text
        check (physiological_state in ('suckling','weaned','pregnant','lactating','dry','none'));

alter table public.animal_categories
    add column if not exists age_band text
        check (age_band in ('calf_0_6m','young_6_12m','young_12_18m','young_18_24m','adult_24plus','any'));

alter table public.animal_categories
    add column if not exists status text not null default 'active'
        check (status in ('active','deprecated'));

alter table public.animal_categories
    add column if not exists deprecated_at timestamptz;

alter table public.animal_categories
    add column if not exists replaced_by_codes text[] not null default '{}';

comment on column public.animal_categories.purpose is
    'ADR-ANIMAL-01: semantic axis. breeding = маточное поголовье / производитель; fattening = откорм; replacement = ремонтное стадо; culling = выбраковка; mixed = сборная группа.';
comment on column public.animal_categories.physiological_state is
    'ADR-ANIMAL-01: semantic axis. suckling/weaned/pregnant/lactating/dry/none.';
comment on column public.animal_categories.age_band is
    'ADR-ANIMAL-01: coarse age bucket for projections (does not replace typical_age_min/max which stay informational).';
comment on column public.animal_categories.status is
    'ADR-ANIMAL-01 I1: lifecycle status. Deprecated codes are NEVER deleted; they persist for historical reports.';
comment on column public.animal_categories.replaced_by_codes is
    'ADR-ANIMAL-01: for SPLIT/MERGE lifecycle — points to codes that supersede this one.';


-- ------------------------------------------------------------
-- M1.2 — Seed axes for the 12 existing codes
-- ------------------------------------------------------------

update public.animal_categories set
    purpose = 'mixed',        physiological_state = 'suckling',    age_band = 'calf_0_6m'    where code = 'SUCKLING_CALF';
update public.animal_categories set
    purpose = 'mixed',        physiological_state = 'weaned',      age_band = 'calf_0_6m'    where code = 'YOUNG_CALF';
update public.animal_categories set
    purpose = 'fattening',    physiological_state = 'none',        age_band = 'young_6_12m'  where code = 'BULL_CALF';
update public.animal_categories set
    purpose = 'fattening',    physiological_state = 'none',        age_band = 'young_12_18m' where code = 'STEER';
update public.animal_categories set
    purpose = 'replacement',  physiological_state = 'none',        age_band = 'young_6_12m'  where code = 'HEIFER_YOUNG';
update public.animal_categories set
    purpose = 'replacement',  physiological_state = 'pregnant',    age_band = 'young_18_24m' where code = 'HEIFER_PREG';
update public.animal_categories set
    purpose = 'breeding',     physiological_state = 'lactating',   age_band = 'adult_24plus' where code = 'COW';
update public.animal_categories set
    purpose = 'culling',      physiological_state = 'none',        age_band = 'adult_24plus' where code = 'COW_CULL';
update public.animal_categories set
    purpose = 'breeding',     physiological_state = 'none',        age_band = 'adult_24plus' where code = 'BULL_BREEDING';
update public.animal_categories set
    purpose = 'culling',      physiological_state = 'none',        age_band = 'adult_24plus' where code = 'BULL_CULL';
update public.animal_categories set
    purpose = 'fattening',    physiological_state = 'none',        age_band = 'adult_24plus' where code = 'OX';
update public.animal_categories set
    purpose = 'mixed',        physiological_state = 'none',        age_band = 'any'          where code = 'MIXED';


-- ------------------------------------------------------------
-- M2.1 — animal_category_mappings (internal projections)
-- ------------------------------------------------------------

create table if not exists public.animal_category_mappings (
    id                      uuid        primary key default gen_random_uuid(),
    target_taxonomy         text        not null
        check (target_taxonomy in (
            'feeding_group',       -- 5 feeding groups used by Consulting SimpleRationEditor
            'cfc_group',           -- 8 legacy CFC groups (DEPRECATED by 2026-12-31)
            'turnover_key',        -- 6 herd turnover keys used by Python engine
            'market_sex',          -- T3: tsp_skus.sex (bull/heifer/cow)
            'market_age_group',    -- T4: tsp_skus.age_group (young_1/young_2/adult/senior)
            'vaccination_class',   -- reserved for future d04 use
            'gos_program'          -- reserved for future government subsidy mapping
        )),
    target_code             text        not null,
    animal_category_code    text        not null
        references public.animal_categories(code) on update cascade,
    valid_from              date        not null default date '2020-01-01',
    valid_to                date,       -- null = open-ended (currently active)
    conditions              jsonb       not null default '{}'::jsonb,
    notes                   text,
    created_at              timestamptz not null default now(),
    -- Integrity: non-overlapping validity per (taxonomy, source category, target code) triple
    constraint ck_acm_valid_range check (valid_to is null or valid_from <= valid_to),
    -- Integrity: conditions must be a JSON object with allowed keys only (I4 schema validation)
    constraint ck_acm_conditions_shape check (
        jsonb_typeof(conditions) = 'object'
        and (conditions - array['age_months','weight_kg'] = '{}'::jsonb)
    ),
    -- Non-overlap: same (target_taxonomy, animal_category_code, target_code) cannot have overlapping daterange
    constraint excl_acm_daterange exclude using gist (
        target_taxonomy with =,
        animal_category_code with =,
        target_code with =,
        daterange(valid_from, coalesce(valid_to, 'infinity'::date), '[]') with &&
    )
);

comment on table public.animal_category_mappings is
    'ADR-ANIMAL-01 L2: declarative projections from canonical L1 (animal_categories) to internal taxonomies.
     One row = "L1 code X maps to target code Y in taxonomy Z during [valid_from, valid_to]".
     Conditions (optional) refine the mapping by age/weight ranges.
     I4 invariant enforced via EXCLUDE constraint on daterange overlap.
     Tier 3 ownership: association-standard. RLS write = association_admin only.';

create index if not exists idx_acm_lookup
    on public.animal_category_mappings (target_taxonomy, valid_from, valid_to);
create index if not exists idx_acm_source
    on public.animal_category_mappings (animal_category_code, target_taxonomy);


-- ------------------------------------------------------------
-- M2.2 — Seed L2 mappings: feeding_group (5 UI groups)
-- Source: src/pages/admin/consulting/tabs/herdCategoryMapping.ts CATEGORY_CODE_TO_HERD
--         src/pages/admin/consulting/tabs/SimpleRationEditor.tsx RATION_GROUPS
-- CLAUDE.md §Consulting "5 Feeding Groups (NOT 10 categories)": COW_CULL/BULL_CULL merged into parent.
-- ------------------------------------------------------------

insert into public.animal_category_mappings
    (target_taxonomy, target_code, animal_category_code, notes)
values
    ('feeding_group', 'COW',           'COW',           'CLAUDE.md: COW_CULL merged into COW for feeding'),
    ('feeding_group', 'COW',           'COW_CULL',      'CLAUDE.md: COW_CULL same animals as COW before culling'),
    ('feeding_group', 'SUCKLING_CALF', 'SUCKLING_CALF', 'feeding_model.py:232 molodnyak'),
    ('feeding_group', 'SUCKLING_CALF', 'YOUNG_CALF',    'feeding_model.py:232 molodnyak'),
    ('feeding_group', 'HEIFER_YOUNG',  'HEIFER_YOUNG',  'SimpleRationEditor RATION_GROUPS'),
    ('feeding_group', 'HEIFER_YOUNG',  'HEIFER_PREG',   'feeding_model.py:236 heifers_prev'),
    ('feeding_group', 'STEER',         'STEER',         'feeding_model.py:242 fattening_commercial'),
    ('feeding_group', 'STEER',         'BULL_CALF',     'feeding_model.py:241 fattening_breeding → STEER feeding group'),
    ('feeding_group', 'BULL_BREEDING', 'BULL_BREEDING', 'SimpleRationEditor RATION_GROUPS'),
    ('feeding_group', 'BULL_BREEDING', 'BULL_CULL',     'CLAUDE.md: BULL_CULL same animals as BULL_BREEDING before culling')
on conflict do nothing;


-- ------------------------------------------------------------
-- M2.3 — Seed L2 mappings: cfc_group (8 legacy CFC groups, DEPRECATED 2026-12-31)
-- Source: consulting_engine/app/engine/feeding_model.py:230-252, 338-339
-- ADR-ANIMAL-01: valid_to = '2026-12-31' — will be removed after TAXONOMY-CFC-DEPRECATE slice.
-- ------------------------------------------------------------

insert into public.animal_category_mappings
    (target_taxonomy, target_code, animal_category_code, valid_to, notes)
values
    ('cfc_group', 'molodnyak',            'SUCKLING_CALF', date '2026-12-31', 'feeding_model.py:232'),
    ('cfc_group', 'molodnyak',            'YOUNG_CALF',    date '2026-12-31', 'feeding_model.py:232'),
    ('cfc_group', 'heifers_prev',         'HEIFER_YOUNG',  date '2026-12-31', 'feeding_model.py:236'),
    ('cfc_group', 'heifers_prev',         'HEIFER_PREG',   date '2026-12-31', 'feeding_model.py:236'),
    ('cfc_group', 'heifers_curr',         'HEIFER_YOUNG',  date '2026-12-31', 'feeding_model.py:491 (always 0 heads)'),
    ('cfc_group', 'cows_12m',             'COW',           date '2026-12-31', 'feeding_model.py:238'),
    ('cfc_group', 'cows_9m',              'COW',           date '2026-12-31', 'feeding_model.py:239 (always 0 heads)'),
    ('cfc_group', 'bulls',                'BULL_BREEDING', date '2026-12-31', 'feeding_model.py group_costs[bulls]'),
    ('cfc_group', 'bulls',                'BULL_CULL',     date '2026-12-31', 'CFC legacy: bulls group includes cull'),
    ('cfc_group', 'fattening_breeding',   'BULL_CALF',     date '2026-12-31', 'feeding_model.py:241'),
    ('cfc_group', 'fattening_commercial', 'STEER',         date '2026-12-31', 'feeding_model.py:242')
on conflict do nothing;


-- ------------------------------------------------------------
-- M2.4 — Seed L2 mappings: turnover_key (6 Python engine keys)
-- Source: consulting_engine/app/engine/herd_turnover.py + feeding_model.py
-- ------------------------------------------------------------

insert into public.animal_category_mappings
    (target_taxonomy, target_code, animal_category_code, notes)
values
    ('turnover_key', 'cows',      'COW',           'herd["cows"]'),
    ('turnover_key', 'cows',      'COW_CULL',      'accounting category within cows'),
    ('turnover_key', 'bulls',     'BULL_BREEDING', 'herd["bulls"]'),
    ('turnover_key', 'bulls',     'BULL_CULL',     'accounting category within bulls'),
    ('turnover_key', 'calves',    'SUCKLING_CALF', 'herd["calves"]'),
    ('turnover_key', 'calves',    'YOUNG_CALF',    'herd["calves"]'),
    ('turnover_key', 'heifers',   'HEIFER_YOUNG',  'herd["heifers"]'),
    ('turnover_key', 'heifers',   'HEIFER_PREG',   'herd["heifers"]'),
    ('turnover_key', 'steers',    'STEER',         'herd["steers"]'),
    ('turnover_key', 'steers',    'BULL_CALF',     'herd["steers"] (fattening_breeding source)'),
    ('turnover_key', 'fattening', 'STEER',         'herd["fattening"] (reserved key)'),
    ('turnover_key', 'fattening', 'BULL_CALF',     'herd["fattening"] (reserved key)')
on conflict do nothing;


-- ------------------------------------------------------------
-- M2.5 — Seed L2 mappings: market_sex + market_age_group
-- Source: d02_tsp.sql:110-118 tsp_skus + Dok 1 D92 mapping table
-- ------------------------------------------------------------

insert into public.animal_category_mappings
    (target_taxonomy, target_code, animal_category_code, notes)
values
    ('market_sex', 'bull',   'BULL_CALF',     'D92: Бычки → BM1/BM2'),
    ('market_sex', 'bull',   'STEER',         'D92: Бычки на откорме → BV/BS'),
    ('market_sex', 'bull',   'BULL_BREEDING', 'D92: not sold — mapping provided for completeness'),
    ('market_sex', 'bull',   'BULL_CULL',     'cull bulls → meat sale'),
    ('market_sex', 'bull',   'OX',            'oxen → meat sale'),
    ('market_sex', 'heifer', 'HEIFER_YOUNG',  'D92: Тёлка → TM'),
    ('market_sex', 'cow',    'HEIFER_PREG',   'D89: Нетель → КВ (sold as meat animal)'),
    ('market_sex', 'cow',    'COW',           'D92: Коровы → КВ/КС'),
    ('market_sex', 'cow',    'COW_CULL',      'D92: cull cows → meat sale'),
    ('market_age_group', 'young_1', 'BULL_CALF',    'D92: 6–12 мес → БМ1'),
    ('market_age_group', 'young_2', 'STEER',        'D92: 12–24 мес → БМ2'),
    ('market_age_group', 'young_2', 'HEIFER_YOUNG', 'D92: ТМ 12–24 мес'),
    ('market_age_group', 'adult',   'HEIFER_PREG',  'D92: нетель → КВ 24–48 мес'),
    ('market_age_group', 'adult',   'COW',          'D92: коровы 24–48 мес → КВ'),
    ('market_age_group', 'senior',  'COW_CULL',     'D92: 48+ мес → КС')
on conflict do nothing;


-- ------------------------------------------------------------
-- M4 — external_category_mappings (external systems projection)
-- ADR-ANIMAL-01 L4: connect ИСЖ / RFID / ERP without code.
-- ------------------------------------------------------------

create table if not exists public.external_category_mappings (
    id                      uuid        primary key default gen_random_uuid(),
    external_system         text        not null
        check (external_system ~ '^[a-z0-9_]+$'),  -- 'isz', 'rfid_supplier_x', 'erp_1c', 'partner_farm_42'
    external_code           text        not null,
    external_label          text,
    animal_category_code    text        not null
        references public.animal_categories(code) on update cascade,
    mapping_confidence      text        not null default 'exact'
        check (mapping_confidence in ('exact','approximate','ambiguous')),
    reverse_default         boolean     not null default false,  -- T1→external fallback choice
    valid_from              date        not null default current_date,
    valid_to                date,
    organization_id         uuid        references public.organizations(id) on delete cascade,
    notes                   text,
    created_at              timestamptz not null default now(),
    constraint ck_ecm_valid_range check (valid_to is null or valid_from <= valid_to)
);

comment on table public.external_category_mappings is
    'ADR-ANIMAL-01 L4: external-system mappings (ИСЖ, RFID supplier, partner ERP, …).
     organization_id NULL = global standard (e.g. ИСЖ codes, owned by association — Tier 3).
     organization_id non-NULL = org-specific (e.g. custom ERP, owned by that org — Tier 1).
     reverse_default = true marks the canonical L1→external target when multiple L1 codes map to the same external code.';

create unique index if not exists uq_ecm_triple_global
    on public.external_category_mappings (external_system, external_code, animal_category_code, valid_from)
    where organization_id is null;
create unique index if not exists uq_ecm_triple_org
    on public.external_category_mappings (external_system, external_code, animal_category_code, organization_id, valid_from)
    where organization_id is not null;
create index if not exists idx_ecm_lookup
    on public.external_category_mappings (external_system, external_code, organization_id);
create index if not exists idx_ecm_source
    on public.external_category_mappings (animal_category_code);


-- ============================================================
-- M3a — RPCs for Animal Taxonomy
-- ============================================================

-- ------------------------------------------------------------
-- rpc_list_animal_categories
-- Returns active (or all if p_include_deprecated) L1 codes as of p_at_date.
-- Pure lookup — no organization_id required.
-- ------------------------------------------------------------
create or replace function public.rpc_list_animal_categories(
    p_at_date              date    default current_date,
    p_include_deprecated   boolean default false
)
returns setof jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
    select jsonb_build_object(
        'id',                    ac.id,
        'code',                  ac.code,
        'name_ru',               ac.name_ru,
        'name_kk',               ac.name_kk,
        'sex',                   ac.sex,
        'purpose',               ac.purpose,
        'physiological_state',   ac.physiological_state,
        'age_band',              ac.age_band,
        'typical_age_min_months',ac.typical_age_min_months,
        'typical_age_max_months',ac.typical_age_max_months,
        'status',                ac.status,
        'deprecated_at',         ac.deprecated_at,
        'replaced_by_codes',     ac.replaced_by_codes,
        'sort_order',            ac.sort_order
    )
    from public.animal_categories ac
    where ac.is_active = true
      and (
          p_include_deprecated
          or ac.status = 'active'
          or ac.deprecated_at is null
          or ac.deprecated_at > p_at_date::timestamptz
      )
    order by ac.sort_order, ac.code;
$$;

comment on function public.rpc_list_animal_categories(date, boolean) is
    'ADR-ANIMAL-01: list L1 canonical categories as of p_at_date. Deprecated codes included only if p_include_deprecated=true.';


-- ------------------------------------------------------------
-- rpc_resolve_category
-- Resolve a single L1 code into its target taxonomy code at a given date.
-- Returns NULL if no mapping is active on that date.
-- ------------------------------------------------------------
create or replace function public.rpc_resolve_category(
    p_source_code      text,
    p_target_taxonomy  text,
    p_at_date          date default current_date
)
returns text
language sql
security definer
set search_path = public, pg_temp
as $$
    -- CRITICAL-TAXONOMY-01 fix: deterministic pick when multiple active mappings exist
    -- for the same (taxonomy, L1). is_primary=true marks the canonical target.
    -- Tie-breakers: most recent valid_from, then target_code alphabetical.
    select m.target_code
    from public.animal_category_mappings m
    where m.animal_category_code = p_source_code
      and m.target_taxonomy      = p_target_taxonomy
      and m.valid_from <= p_at_date
      and (m.valid_to is null or m.valid_to >= p_at_date)
    order by m.is_primary desc, m.valid_from desc, m.target_code
    limit 1;
$$;

comment on function public.rpc_resolve_category(text, text, date) is
    'ADR-ANIMAL-01: resolve L1 code → canonical target taxonomy code at date.
     Returns the primary mapping if set; otherwise most recent. NULL if no active mapping.
     For many-to-many queries (all targets for an L1), use rpc_get_category_mappings.';


-- ------------------------------------------------------------
-- rpc_get_category_mappings
-- Return all mappings for a target taxonomy active as of p_at_date.
-- Used by Python engine and TS UI to read ontology once per session.
-- ------------------------------------------------------------
create or replace function public.rpc_get_category_mappings(
    p_target_taxonomy  text,
    p_at_date          date default current_date
)
returns setof jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
    select jsonb_build_object(
        'target_taxonomy',      m.target_taxonomy,
        'target_code',          m.target_code,
        'animal_category_code', m.animal_category_code,
        'valid_from',           m.valid_from,
        'valid_to',             m.valid_to,
        'conditions',           m.conditions,
        'notes',                m.notes
    )
    from public.animal_category_mappings m
    where m.target_taxonomy = p_target_taxonomy
      and m.valid_from <= p_at_date
      and (m.valid_to is null or m.valid_to >= p_at_date)
    order by m.target_code, m.animal_category_code;
$$;

comment on function public.rpc_get_category_mappings(text, date) is
    'ADR-ANIMAL-01: all active mappings for a target taxonomy at p_at_date. Clients call this once per session and cache locally with staleTime<=60s.';


-- ------------------------------------------------------------
-- rpc_add_animal_category
-- Atomically create a new L1 code + required L2 mappings.
-- I3 invariant: fails if p_required_mappings doesn't cover feeding_group + turnover_key + market_sex.
-- Admin-only.
-- ------------------------------------------------------------
create or replace function public.rpc_add_animal_category(
    p_code                text,
    p_name_ru             text,
    p_name_kk             text,
    p_sex                 text,
    p_purpose             text,
    p_physiological_state text,
    p_age_band            text,
    p_required_mappings   jsonb,  -- {"feeding_group":"COW","turnover_key":"cows","market_sex":"cow", ...}
    p_description_ru      text default null,
    p_sort_order          int  default 999
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_required_keys text[] := array['feeding_group','turnover_key','market_sex'];
    v_key text;
    v_target text;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: association_admin required' using errcode = 'P0001';
    end if;

    -- I3: every active L1 code must have mappings in all required target taxonomies
    foreach v_key in array v_required_keys loop
        if (p_required_mappings ->> v_key) is null then
            raise exception 'INVARIANT_I3: required mapping missing for target_taxonomy=%', v_key
                using errcode = 'P0001';
        end if;
    end loop;

    insert into public.animal_categories (
        code, name_ru, name_kk, sex, purpose, physiological_state, age_band,
        description_ru, sort_order, status
    ) values (
        p_code, p_name_ru, p_name_kk, p_sex, p_purpose, p_physiological_state, p_age_band,
        p_description_ru, p_sort_order, 'active'
    );

    foreach v_key in array v_required_keys loop
        v_target := p_required_mappings ->> v_key;
        insert into public.animal_category_mappings
            (target_taxonomy, target_code, animal_category_code, notes)
        values
            (v_key, v_target, p_code, 'created via rpc_add_animal_category');
    end loop;

    -- Optional mappings (cfc_group, market_age_group, vaccination_class, gos_program)
    insert into public.animal_category_mappings
        (target_taxonomy, target_code, animal_category_code, notes)
    select k.key, v.value::text, p_code, 'created via rpc_add_animal_category'
    from jsonb_each_text(p_required_mappings - v_required_keys) as k(key, value)
    where k.key in ('cfc_group','market_age_group','vaccination_class','gos_program');

    insert into public.platform_events (event_type, entity_type, entity_id, actor_type, actor_id, payload, is_audit)
    values (
        'standards.animal_category.updated',
        'animal_categories',
        (select id from public.animal_categories where code = p_code),
        'admin',
        public.fn_current_user_id(),
        jsonb_build_object('action','add','code',p_code,'mappings',p_required_mappings),
        true
    );

    return jsonb_build_object('status','ok','code',p_code);
end;
$$;

comment on function public.rpc_add_animal_category(text,text,text,text,text,text,text,jsonb,text,int) is
    'ADR-ANIMAL-01: atomically add a new L1 canonical code with all required L2 projections.
     I3 invariant: fails if required_mappings is missing feeding_group / turnover_key / market_sex.
     Emits event standards.animal_category.updated.';


-- ------------------------------------------------------------
-- rpc_deprecate_animal_category
-- Mark a L1 code deprecated. Closes its L2 projections by setting valid_to.
-- I1 invariant: code is NEVER deleted.
-- ------------------------------------------------------------
create or replace function public.rpc_deprecate_animal_category(
    p_code              text,
    p_replaced_by       text[]  default '{}',
    p_valid_to          date    default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: association_admin required' using errcode = 'P0001';
    end if;

    update public.animal_categories
    set status             = 'deprecated',
        deprecated_at      = now(),
        replaced_by_codes  = p_replaced_by
    where code = p_code and status = 'active';

    if not found then
        raise exception 'NOT_FOUND_OR_ALREADY_DEPRECATED: code=%', p_code using errcode = 'P0001';
    end if;

    update public.animal_category_mappings
    set valid_to = p_valid_to
    where animal_category_code = p_code
      and (valid_to is null or valid_to > p_valid_to);

    insert into public.platform_events (event_type, entity_type, entity_id, actor_type, actor_id, payload, is_audit)
    values (
        'standards.animal_category.updated',
        'animal_categories',
        (select id from public.animal_categories where code = p_code),
        'admin',
        public.fn_current_user_id(),
        jsonb_build_object('action','deprecate','code',p_code,'replaced_by',p_replaced_by,'valid_to',p_valid_to),
        true
    );

    return jsonb_build_object('status','ok','code',p_code,'replaced_by',p_replaced_by);
end;
$$;

comment on function public.rpc_deprecate_animal_category(text, text[], date) is
    'ADR-ANIMAL-01: deprecate a L1 code (never delete — I1). Closes L2 projections by valid_to.
     Existing herd_groups continue to reference it until migrated (see rpc_migrate_animal_category).';


-- ------------------------------------------------------------
-- rpc_migrate_animal_category
-- Migrate existing herd_groups from p_from_code to p_to_code.
-- Strategy:
--   auto_remap        → update herd_groups.animal_category_id directly
--   flag_farmer_task  → leave herd_groups unchanged, create FarmTask placeholders (if farm_tasks exists)
-- ------------------------------------------------------------
create or replace function public.rpc_migrate_animal_category(
    p_from_code   text,
    p_to_code     text,
    p_strategy    text  default 'auto_remap'    -- 'auto_remap' | 'flag_farmer_task'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_from_id uuid;
    v_to_id   uuid;
    v_count   int;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: association_admin required' using errcode = 'P0001';
    end if;

    if p_strategy not in ('auto_remap','flag_farmer_task') then
        raise exception 'INVALID_STRATEGY: must be auto_remap | flag_farmer_task' using errcode = 'P0001';
    end if;

    select id into v_from_id from public.animal_categories where code = p_from_code;
    select id into v_to_id   from public.animal_categories where code = p_to_code;

    if v_from_id is null or v_to_id is null then
        raise exception 'UNKNOWN_CODE: from=% to=%', p_from_code, p_to_code using errcode = 'P0001';
    end if;

    if p_strategy = 'auto_remap' then
        update public.herd_groups
        set animal_category_id = v_to_id,
            updated_at         = now()
        where animal_category_id = v_from_id;
        get diagnostics v_count = row_count;
    else
        -- flag_farmer_task: count affected, leave herd_groups unchanged.
        -- Actual FarmTask creation is handled in a separate slice (S4-DB) when farm_tasks schema stabilises.
        select count(*) into v_count
        from public.herd_groups
        where animal_category_id = v_from_id;
    end if;

    insert into public.platform_events (event_type, entity_type, entity_id, actor_type, actor_id, payload, is_audit)
    values (
        'standards.animal_category.updated',
        'animal_categories',
        v_from_id,
        'admin',
        public.fn_current_user_id(),
        jsonb_build_object(
            'action','migrate',
            'from_code',p_from_code,
            'to_code',p_to_code,
            'strategy',p_strategy,
            'affected_herd_groups', v_count
        ),
        true
    );

    return jsonb_build_object(
        'status','ok',
        'from_code',p_from_code,
        'to_code',p_to_code,
        'strategy',p_strategy,
        'affected_herd_groups', v_count
    );
end;
$$;

comment on function public.rpc_migrate_animal_category(text,text,text) is
    'ADR-ANIMAL-01: migrate herd_groups from deprecated L1 code to successor.
     auto_remap: SQL UPDATE in place.
     flag_farmer_task: count affected groups and emit event (FarmTask creation deferred to S4-DB slice).';


-- ------------------------------------------------------------
-- M3a — RLS on L1 axis columns and L2/L4 tables
-- ------------------------------------------------------------

alter table public.animal_category_mappings    enable row level security;
alter table public.external_category_mappings  enable row level security;

-- L2 animal_category_mappings — Tier 3 (association)
drop policy if exists "acm_read_all"         on public.animal_category_mappings;
drop policy if exists "acm_write_admin"      on public.animal_category_mappings;

create policy "acm_read_all"
    on public.animal_category_mappings for select
    using (true);

create policy "acm_write_admin"
    on public.animal_category_mappings for all
    using (public.fn_is_admin())
    with check (public.fn_is_admin());

-- L4 external_category_mappings — global rows = Tier 3; org-scoped = Tier 1
drop policy if exists "ecm_read"            on public.external_category_mappings;
drop policy if exists "ecm_write_global"    on public.external_category_mappings;
drop policy if exists "ecm_write_org"       on public.external_category_mappings;

create policy "ecm_read"
    on public.external_category_mappings for select
    using (
        -- Global (org-less) rows: readable by everyone — they are association-level standard
        organization_id is null
        -- Admins always read
        or public.fn_is_admin()
        -- Org-scoped: only members of THAT organization (CRITICAL-TAXONOMY-02 fix:
        -- prior version had a tautological subquery making all org rows world-readable).
        or exists (
            select 1 from public.memberships m
            where m.organization_id = external_category_mappings.organization_id
              and m.user_id = public.fn_current_user_id()
              and m.is_active = true
        )
    );

create policy "ecm_write_global"
    on public.external_category_mappings for all
    using (organization_id is null and public.fn_is_admin())
    with check (organization_id is null and public.fn_is_admin());

create policy "ecm_write_org"
    on public.external_category_mappings for all
    using (
        organization_id is not null
        and exists (
            select 1 from public.memberships m
            where m.organization_id = external_category_mappings.organization_id
              and m.user_id = public.fn_current_user_id()
              and m.is_active = true
              and m.role in ('owner','admin')
        )
    )
    with check (
        organization_id is not null
        and exists (
            select 1 from public.memberships m
            where m.organization_id = external_category_mappings.organization_id
              and m.user_id = public.fn_current_user_id()
              and m.is_active = true
              and m.role in ('owner','admin')
        )
    );


-- ------------------------------------------------------------
-- M3a — Audit triggers on animal_categories and animal_category_mappings
-- I6 invariant: every change to L1/L2 logs to audit_log.
-- ------------------------------------------------------------

create or replace function public.fn_audit_animal_taxonomy()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_changes jsonb;
begin
    if tg_op = 'INSERT' then
        v_changes := jsonb_build_object('after', to_jsonb(new));
    elsif tg_op = 'UPDATE' then
        v_changes := jsonb_build_object('before', to_jsonb(old), 'after', to_jsonb(new));
    else
        v_changes := jsonb_build_object('before', to_jsonb(old));
    end if;

    insert into public.audit_log
        (user_id, actor_type, action, entity_type, entity_id, organization_id, changes)
    values (
        public.fn_current_user_id(),
        'admin',
        lower(tg_op) || '.' || tg_table_name,
        tg_table_name,
        coalesce((new).id, (old).id),
        null,
        v_changes
    );

    return coalesce(new, old);
end;
$$;

drop trigger if exists trg_audit_animal_categories        on public.animal_categories;
drop trigger if exists trg_audit_animal_category_mappings on public.animal_category_mappings;
drop trigger if exists trg_audit_external_cat_mappings   on public.external_category_mappings;

create trigger trg_audit_animal_categories
    after insert or update or delete on public.animal_categories
    for each row execute function public.fn_audit_animal_taxonomy();

create trigger trg_audit_animal_category_mappings
    after insert or update or delete on public.animal_category_mappings
    for each row execute function public.fn_audit_animal_taxonomy();

create trigger trg_audit_external_cat_mappings
    after insert or update or delete on public.external_category_mappings
    for each row execute function public.fn_audit_animal_taxonomy();


-- ------------------------------------------------------------
-- rpc_name_registry entries for 6 new RPCs
-- ------------------------------------------------------------

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('rpc_list_animal_categories',    null, 'list_animal_categories',    'd01_kernel.sql (ADR-ANIMAL-01)', 'L1 canonical list with lifecycle'),
    ('rpc_resolve_category',          null, 'resolve_category',          'd01_kernel.sql (ADR-ANIMAL-01)', 'L1 → target taxonomy code at date'),
    ('rpc_get_category_mappings',     null, 'get_category_mappings',     'd01_kernel.sql (ADR-ANIMAL-01)', 'All active mappings for a target taxonomy'),
    ('rpc_add_animal_category',       null, null,                        'd01_kernel.sql (ADR-ANIMAL-01)', 'Admin-only: create L1 + required L2 projections (I3 enforced)'),
    ('rpc_deprecate_animal_category', null, null,                        'd01_kernel.sql (ADR-ANIMAL-01)', 'Admin-only: deprecate L1 (I1: never delete)'),
    ('rpc_migrate_animal_category',   null, null,                        'd01_kernel.sql (ADR-ANIMAL-01)', 'Admin-only: migrate herd_groups between L1 codes')
on conflict (sql_name) do update
    set notes      = excluded.notes,
        created_in = excluded.created_in;

-- ============================================================
-- M5 — QA findings remediation (2026-04-15, post DB-gate QA)
-- Addresses: CRITICAL-TAXONOMY-01 (is_primary), SIGNIFICANT-TAXONOMY-03 (OX/MIXED seed)
-- CRITICAL-TAXONOMY-02 (RLS tautology) fixed in-place above.
-- ============================================================

-- ------------------------------------------------------------
-- M5.1 — Add is_primary to animal_category_mappings (CRITICAL-01)
-- Deterministic tie-breaker for rpc_resolve_category when multiple
-- mappings exist for the same (taxonomy, L1).
-- ------------------------------------------------------------

alter table public.animal_category_mappings
    add column if not exists is_primary boolean not null default false;

comment on column public.animal_category_mappings.is_primary is
    'ADR-ANIMAL-01 CRITICAL-01 fix: marks canonical target for (taxonomy, L1) pair.
     Must be exactly one is_primary=true per (taxonomy, L1) pair that has any mapping.
     Used by rpc_resolve_category to pick deterministically.';

-- Partial unique index: at most one primary per (taxonomy, L1, date-open).
-- Only enforced for currently-open mappings (valid_to is null) to allow
-- legacy deprecated rows to stay without violating the constraint.
create unique index if not exists uq_acm_primary_per_source
    on public.animal_category_mappings (target_taxonomy, animal_category_code)
    where is_primary = true and valid_to is null;


-- ------------------------------------------------------------
-- M5.2 — Backfill primaries
--
-- Rule 1: if a (taxonomy, L1) pair has exactly ONE active row → that row is primary.
-- Rule 2: for ambiguous pairs (>1 row), set primary on the canonical per ADR-ANIMAL-01:
--   cfc_group    HEIFER_YOUNG → heifers_prev   (feeding_model.py:236)
--   cfc_group    COW          → cows_12m       (feeding_model.py:238)
--   turnover_key STEER        → steers         (herdCategoryMapping.ts:62)
--   turnover_key BULL_CALF    → steers         (herdCategoryMapping.ts:61)
-- ------------------------------------------------------------

-- Rule 1: single-mapping pairs
update public.animal_category_mappings m
   set is_primary = true
 where is_primary = false
   and (m.valid_to is null or m.valid_to >= current_date)
   and not exists (
       select 1
         from public.animal_category_mappings m2
        where m2.id <> m.id
          and m2.target_taxonomy     = m.target_taxonomy
          and m2.animal_category_code = m.animal_category_code
          and (m2.valid_to is null or m2.valid_to >= current_date)
   );

-- Rule 2: canonical rows for ambiguous pairs
update public.animal_category_mappings
   set is_primary = true
 where is_primary = false
   and (target_taxonomy, animal_category_code, target_code) in (
       ('cfc_group',    'HEIFER_YOUNG', 'heifers_prev'),
       ('cfc_group',    'COW',          'cows_12m'),
       ('turnover_key', 'STEER',        'steers'),
       ('turnover_key', 'BULL_CALF',    'steers')
   );


-- ------------------------------------------------------------
-- M5.3 — Seed OX + MIXED mappings (SIGNIFICANT-TAXONOMY-03)
-- Prevents NULL resolve for pre-existing L1 codes that lacked mappings.
-- OX: semantically == castrated male cattle for meat → STEER feeding/turnover.
-- MIXED: catch-all fallback → COW feeding (largest group), cows turnover.
--   Marked primary for determinism; if farmers do use MIXED it resolves cleanly.
-- ------------------------------------------------------------

insert into public.animal_category_mappings
    (target_taxonomy, target_code, animal_category_code, is_primary, notes)
values
    ('feeding_group', 'STEER',                'OX',    true, 'SIG-03: castrated male → STEER feeding group'),
    ('feeding_group', 'COW',                  'MIXED', true, 'SIG-03: catch-all fallback to COW feeding'),
    ('turnover_key',  'steers',               'OX',    true, 'SIG-03: OX accounted in steers turnover'),
    ('turnover_key',  'cows',                 'MIXED', true, 'SIG-03: MIXED accounted in cows turnover'),
    ('cfc_group',     'fattening_commercial', 'OX',    true, 'SIG-03: same as STEER in legacy CFC (deprecates 2026-12-31 anyway)')
on conflict do nothing;

-- Note: market_age_group intentionally NOT seeded for OX/MIXED —
-- age is indeterminate for catch-all codes; rpc_get_category_mappings returns empty set.


-- ------------------------------------------------------------
-- M5.4 — I3 hardening in rpc_add_animal_category for future adds
-- (no change to signature; the RPC body is already correct —
--  this comment documents that is_primary=true should be set by admin UI
--  when creating L2 rows via rpc_add_animal_category. Followup task for M3c.)
-- ------------------------------------------------------------

-- ============================================================
-- END ADR-ANIMAL-01 SECTION
-- ============================================================

-- ============================================================
-- AUDIT-2026-04-18: rpc_name_registry — bulk registration
-- 60 RPCs implemented in Slices 2-9 but never formally INSERTed.
-- Organized by source SQL file / domain.
-- ============================================================

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    -- d02_tsp.sql — Market / TSP domain
    ('rpc_activate_pool_request',     null, null,                           'd02_tsp.sql',        'TSP: activate pool request'),
    ('rpc_advance_pool_status',       null, null,                           'd02_tsp.sql',        'TSP: FSM transition for pool status'),
    ('rpc_cancel_batch',              null, null,                           'd02_tsp.sql',        'TSP: cancel a published batch'),
    ('rpc_create_pool_request',       null, null,                           'd02_tsp.sql',        'TSP: create pool aggregation request'),
    ('rpc_get_market_summary',        null, 'get_market_summary',           'd02_tsp.sql',        'TSP: aggregated supply/demand summary'),
    ('rpc_get_price_for_sku',         null, 'get_price_for_sku',            'd02_tsp.sql',        'TSP: current price for SKU'),
    ('rpc_match_batch_to_pool',       null, null,                           'd02_tsp.sql',        'TSP: match batch to pool request'),
    ('rpc_publish_price_index_value', null, null,                           'd02_tsp.sql',        'TSP: publish reference price index'),
    ('rpc_rollback_batch_match',      null, null,                           'd02_tsp.sql',        'TSP: rollback batch↔pool match'),
    ('rpc_set_price_grid',            null, null,                           'd02_tsp.sql',        'TSP: admin set price grid'),

    -- d03_feed.sql — Feed domain
    ('rpc_archive_ration',            null, null,                           'd03_feed.sql',       'Feed: archive a ration version'),
    ('rpc_get_current_ration',        null, 'get_current_ration',          'd03_feed.sql',       'Feed: current active ration for farm'),
    ('rpc_list_feed_categories',      null, 'list_feed_categories',        'd03_feed.sql',       'Feed: list feed categories'),
    ('rpc_list_feed_consumption_norms', null, 'list_feed_consumption_norms', 'd03_feed.sql',     'Feed: admin list consumption norms'),
    ('rpc_list_feed_items',           null, 'list_feed_items',             'd03_feed.sql',       'Feed: list feed items catalog'),
    ('rpc_list_feed_prices',          null, 'list_feed_prices',            'd03_feed.sql',       'Feed: price catalog with Art.171 disclaimer'),
    ('rpc_save_ration',               null, null,                           'd03_feed.sql',       'Feed: save ration version for farm'),
    ('rpc_upsert_feed_consumption_norm', null, null,                        'd03_feed.sql',       'Feed: admin upsert consumption norm'),
    ('rpc_upsert_feed_inventory',     null, null,                           'd03_feed.sql',       'Feed: upsert farm feed inventory'),
    ('rpc_upsert_feed_item',          null, null,                           'd03_feed.sql',       'Feed: admin upsert feed catalog item'),
    ('rpc_upsert_feed_price',         null, null,                           'd03_feed.sql',       'Feed: admin upsert feed price'),

    -- d04_vet.sql — Vet domain
    ('rpc_activate_vaccination_plan', null, null,                           'd04_vet.sql',        'Vet: activate vaccination plan'),
    ('rpc_add_vet_diagnosis',         null, 'add_vet_diagnosis',           'd04_vet.sql',        'Vet: add diagnosis to vet case'),
    ('rpc_add_vet_recommendation',    null, 'add_vet_recommendation',      'd04_vet.sql',        'Vet: add expert recommendation'),
    ('rpc_close_vet_case',            null, 'close_vet_case',              'd04_vet.sql',        'Vet: FSM close vet case'),
    ('rpc_create_vaccination_plan',   null, null,                           'd04_vet.sql',        'Vet: create vaccination plan'),
    ('rpc_get_expert_kpi',            null, 'get_expert_kpi',              'd04_vet.sql',        'Vet: expert dashboard KPI'),
    ('rpc_get_vet_case_detail',       null, 'get_vet_case_detail',         'd04_vet.sql',        'Vet: full case detail (D-F11-1 JWT-compatible)'),
    ('rpc_link_vet_case_conversation',null, null,                           'd04_vet.sql',        'Vet: link AI conversation to vet case'),
    ('rpc_list_epidemic_signals',     null, 'list_epidemic_signals',       'd04_vet.sql',        'Vet: list epidemic signals for region'),
    ('rpc_list_vaccination_plan_items', null, 'list_vaccination_plan_items', 'd04_vet.sql',      'Vet: list items within a vaccination plan'),
    ('rpc_list_vaccination_plans',    null, 'list_vaccination_plans',      'd04_vet.sql',        'Vet: list all vaccination plans'),
    ('rpc_list_vaccines',             null, 'list_vaccines',               'd04_vet.sql',        'Vet: list vaccine catalog'),
    ('rpc_record_vaccination',        null, 'record_vaccination',          'd04_vet.sql',        'Vet: record vaccination event'),
    ('rpc_report_epidemic_signal',    null, 'report_epidemic_signal',      'd04_vet.sql',        'Vet/Epidemic: report epidemic signal'),

    -- d05_ops_edu.sql — Ops / Edu domain
    ('rpc_add_knowledge_chunk',       null, null,                           'd05_ops_edu.sql',    'Edu: admin add knowledge chunk'),
    ('rpc_get_active_plan',           null, 'get_active_plan',             'd05_ops_edu.sql',    'Ops: active production plan (D-S4-3)'),

    -- d07_ai_gateway.sql — AI Gateway domain
    ('rpc_clear_confirmation',        null, 'clear_confirmation',          'd07_ai_gateway.sql', 'AI: clear pending confirmation state'),
    ('rpc_get_conversation_state',    null, 'get_conversation_state',      'd07_ai_gateway.sql', 'AI: get full conversation FSM state'),
    ('rpc_get_user_phone',            null, null,                           'd07_ai_gateway.sql', 'AI: resolve user phone for notifications'),
    ('rpc_sync_conversation_role',    null, null,                           'd07_ai_gateway.sql', 'AI: sync conversation role after member update'),

    -- d09_consulting.sql — Consulting domain
    ('rpc_create_consulting_project', null, null,                           'd09_consulting.sql', 'Consulting: create new project'),
    ('rpc_get_consulting_project',    null, null,                           'd09_consulting.sql', 'Consulting: get project with latest version'),
    ('rpc_get_consulting_rations',    null, null,                           'd09_consulting.sql', 'Consulting: get saved rations for project'),
    ('rpc_get_consulting_version',    null, null,                           'd09_consulting.sql', 'Consulting: get specific version by id'),
    ('rpc_list_capex_surcharges',     null, null,                           'd09_consulting.sql', 'Consulting/CAPEX: list surcharges (ADR-CAPEX-02)'),
    ('rpc_list_construction_materials', null, null,                         'd09_consulting.sql', 'Consulting/CAPEX: list materials catalog'),
    ('rpc_list_consulting_projects',  null, null,                           'd09_consulting.sql', 'Consulting: list all projects for org'),
    ('rpc_list_consulting_versions',  null, null,                           'd09_consulting.sql', 'Consulting: list all versions for project'),
    ('rpc_list_infrastructure_norms', null, null,                           'd09_consulting.sql', 'Consulting/CAPEX: list infra norms'),
    ('rpc_list_livestock_prices',     null, null,                           'd09_consulting.sql', 'Consulting: list livestock sale prices (ADR-PRICES-01)'),
    ('rpc_retire_livestock_price',    null, null,                           'd09_consulting.sql', 'Consulting: retire a livestock price entry'),
    ('rpc_save_consulting_ration',    null, null,                           'd09_consulting.sql', 'Consulting: save NASEM/Simple ration (D-S8-3)'),
    ('rpc_save_consulting_version',   null, null,                           'd09_consulting.sql', 'Consulting: save calculation version'),
    ('rpc_save_project_infra_override', null, null,                         'd09_consulting.sql', 'Consulting/CAPEX: save infra override (ADR-CAPEX-02)'),
    ('rpc_update_consulting_project', null, null,                           'd09_consulting.sql', 'Consulting: update project metadata'),
    ('rpc_upsert_construction_material', null, null,                        'd09_consulting.sql', 'Consulting/CAPEX: admin upsert material'),
    ('rpc_upsert_consulting_reference', null, null,                         'd09_consulting.sql', 'Consulting: upsert reference data row'),
    ('rpc_upsert_infrastructure_norm', null, null,                          'd09_consulting.sql', 'Consulting/CAPEX: admin upsert infra norm'),
    ('rpc_upsert_livestock_price',    null, null,                           'd09_consulting.sql', 'Consulting: admin upsert livestock price')
on conflict (sql_name) do update
    set notes      = excluded.notes,
        created_in = excluded.created_in;
