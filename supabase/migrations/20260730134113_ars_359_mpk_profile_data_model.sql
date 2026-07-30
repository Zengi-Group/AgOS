-- AgOS · ARS-359 · MPK Profile organization/site/bank/field-review model.
--
-- G2/ADR authority:
--   Docs/AGOS-MPK-Profile-EngSpec-v0_1.md (D-MPK-CRIT-03/CANON-05)
--   Docs/AGOS-MPK-Profile-Convergence-ADR-ARS-353.md
--
-- The 2026-07-30 live audit found none of the four target tables. This migration
-- therefore performs no legacy-data backfill. If an unaudited environment contains
-- an incompatible mpk_profiles/table shape, fail before any DDL instead of silently
-- accepting it through CREATE TABLE IF NOT EXISTS.

-- -----------------------------------------------------------------------------
-- 0. Preflight: a legacy/wide table requires a field-by-field audit first.
-- -----------------------------------------------------------------------------

do $$
declare
    v_table text;
    v_required text[];
    v_column text;
begin
    foreach v_table in array array[
        'mpk_profiles', 'mpk_sites', 'org_bank_accounts', 'org_field_reviews'
    ] loop
        if to_regclass('public.' || v_table) is null then
            continue;
        end if;

        v_required := case v_table
            when 'mpk_profiles' then array[
                'organization_id', 'public_description', 'logo_path',
                'created_at', 'updated_at'
            ]
            when 'mpk_sites' then array[
                'id', 'organization_id', 'site_name', 'address_text',
                'processing_capacity_heads_per_day', 'is_primary', 'is_active',
                'created_at', 'updated_at'
            ]
            when 'org_bank_accounts' then array[
                'id', 'organization_id', 'logical_account_id', 'version_no',
                'supersedes_id', 'bank_name', 'bik', 'iban',
                'account_holder_name', 'currency_code', 'is_primary',
                'valid_from', 'valid_to', 'created_at'
            ]
            when 'org_field_reviews' then array[
                'id', 'organization_id', 'field_name', 'previous_value',
                'proposed_value', 'status', 'requested_by_user_id',
                'requested_at', 'reviewed_by_user_id', 'reviewed_at',
                'review_note', 'production_value_applied_at'
            ]
        end;

        foreach v_column in array v_required loop
            if not exists (
                select 1
                from information_schema.columns c
                where c.table_schema = 'public'
                  and c.table_name = v_table
                  and c.column_name = v_column
            ) then
                raise exception
                    'ARS_359_PREFLIGHT_REQUIRED: public.% exists without canonical column %',
                    v_table, v_column;
            end if;
        end loop;
    end loop;

    if to_regclass('public.mpk_profiles') is not null and exists (
        select 1
        from information_schema.columns c
        where c.table_schema = 'public'
          and c.table_name = 'mpk_profiles'
          and c.column_name = any(array[
              'annual_demand_heads', 'processing_capacity_per_day',
              'preferred_categories', 'preferred_regions', 'notes'
          ])
    ) then
        raise exception
            'ARS_359_LEGACY_MPK_PROFILES_REQUIRES_AUDIT: preserve/export and reconcile before migration';
    end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 1. Canonical organization semantics. No aliases or destructive renames.
-- -----------------------------------------------------------------------------

alter table public.organizations
    add column if not exists head_full_name text,
    add column if not exists head_title text;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.organizations'::regclass
          and conname = 'organizations_head_full_name_check'
    ) then
        alter table public.organizations
            add constraint organizations_head_full_name_check
            check (
                head_full_name is null
                or (head_full_name = btrim(head_full_name)
                    and length(head_full_name) between 1 and 300)
            ) not valid;
    end if;
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.organizations'::regclass
          and conname = 'organizations_head_title_check'
    ) then
        alter table public.organizations
            add constraint organizations_head_title_check
            check (
                head_title is null
                or (head_title = btrim(head_title)
                    and length(head_title) between 1 and 200)
            ) not valid;
    end if;
end;
$$;

alter table public.organizations
    validate constraint organizations_head_full_name_check;
alter table public.organizations
    validate constraint organizations_head_title_check;

comment on column public.organizations.head_full_name is
    'ARS-359: legal head/director full name. A contact person is derived from the organization team and is not duplicated here.';
comment on column public.organizations.head_title is
    'ARS-359: legal head/director title.';
comment on column public.organizations.address_text is
    'Canonical organization legal/mailing address for MPK Profile v0.1. Site addresses belong to mpk_sites.';
comment on column public.organizations.phone is
    'Canonical organization contact phone; not a user/team contact-person identity.';
comment on column public.organizations.email is
    'Canonical organization contact email; not a user/team contact-person identity.';

-- -----------------------------------------------------------------------------
-- 2. Narrow profile, multi-site capacity, versioned bank details, field reviews.
-- -----------------------------------------------------------------------------

create table if not exists public.mpk_profiles (
    organization_id    uuid primary key
                       references public.organizations(id) on delete cascade,
    public_description text,
    logo_path          text,
    created_at         timestamptz not null default now(),
    updated_at         timestamptz not null default now(),
    constraint mpk_profiles_description_check check (
        public_description is null
        or (public_description = btrim(public_description)
            and length(public_description) between 1 and 4000)
    ),
    constraint mpk_profiles_logo_path_check check (
        logo_path is null
        or (logo_path = btrim(logo_path)
            and length(logo_path) between 1 and 1024
            and logo_path !~ '^[a-zA-Z][a-zA-Z0-9+.-]*://'
            and logo_path !~ '^/')
    )
);

comment on table public.mpk_profiles is
    'ARS-359 / D-MPK-CANON-05: sparse, narrow MPK editorial extension. Legal identity, membership, verification, sites, bank data, reviews, and appeals remain in their domain owners.';

create table if not exists public.mpk_sites (
    id                                  uuid primary key default gen_random_uuid(),
    organization_id                     uuid not null
                                        references public.organizations(id) on delete cascade,
    site_name                            text not null,
    region_id                            uuid references public.regions(id) on delete restrict,
    address_text                         text not null,
    processing_capacity_heads_per_day    int not null,
    phone                                text,
    email                                text,
    is_primary                           boolean not null default false,
    is_active                            boolean not null default true,
    created_by_user_id                   uuid references public.users(id) on delete set null,
    created_at                           timestamptz not null default now(),
    updated_at                           timestamptz not null default now(),
    constraint mpk_sites_name_check check (
        site_name = btrim(site_name) and length(site_name) between 1 and 200
    ),
    constraint mpk_sites_address_check check (
        address_text = btrim(address_text) and length(address_text) between 1 and 1000
    ),
    constraint mpk_sites_capacity_positive_check check (
        processing_capacity_heads_per_day > 0
    ),
    constraint mpk_sites_primary_active_check check (
        not is_primary or is_active
    ),
    constraint mpk_sites_phone_check check (
        phone is null or (phone = btrim(phone) and length(phone) between 3 and 50)
    ),
    constraint mpk_sites_email_check check (
        email is null or (email = lower(btrim(email)) and length(email) between 3 and 320)
    )
);

comment on table public.mpk_sites is
    'ARS-359: multi-site MPK receiving/processing model. v0.1 UI edits only the active primary site; capacity is positive heads/day.';

create table if not exists public.org_bank_accounts (
    id                    uuid primary key default gen_random_uuid(),
    organization_id       uuid not null
                          references public.organizations(id) on delete cascade,
    logical_account_id    uuid not null default gen_random_uuid(),
    version_no            int not null check (version_no > 0),
    supersedes_id         uuid references public.org_bank_accounts(id) on delete restrict,
    bank_name             text not null,
    bik                   text not null,
    iban                  text not null,
    account_holder_name   text not null,
    currency_code         text not null default 'KZT',
    is_primary            boolean not null default false,
    valid_from            timestamptz not null default now(),
    valid_to              timestamptz,
    created_by_user_id    uuid references public.users(id) on delete set null,
    created_at            timestamptz not null default now(),
    constraint org_bank_accounts_version_unique
        unique (organization_id, logical_account_id, version_no),
    constraint org_bank_accounts_supersedes_unique unique (supersedes_id),
    constraint org_bank_accounts_bank_name_check check (
        bank_name = btrim(bank_name) and length(bank_name) between 1 and 300
    ),
    constraint org_bank_accounts_bik_check check (
        bik = upper(btrim(bik)) and bik ~ '^[A-Z0-9]{8,12}$'
    ),
    constraint org_bank_accounts_iban_check check (
        iban = upper(btrim(iban)) and iban ~ '^KZ[A-Z0-9]{18}$'
    ),
    constraint org_bank_accounts_holder_check check (
        account_holder_name = btrim(account_holder_name)
        and length(account_holder_name) between 1 and 500
    ),
    constraint org_bank_accounts_currency_check check (
        currency_code = upper(currency_code) and currency_code ~ '^[A-Z]{3}$'
    ),
    constraint org_bank_accounts_validity_check check (
        valid_to is null or valid_to >= valid_from
    ),
    constraint org_bank_accounts_primary_current_check check (
        not is_primary or valid_to is null
    )
);

comment on table public.org_bank_accounts is
    'ARS-359: append-new/versioned organization bank details. Business fields are immutable after insert; a new version closes and supersedes the prior row. Deal documents must store the JSON snapshot of one explicit version, never re-read the current primary account.';

create table if not exists public.org_field_reviews (
    id                          uuid primary key default gen_random_uuid(),
    organization_id             uuid not null
                                references public.organizations(id) on delete cascade,
    field_name                  text not null
                                check (field_name in ('legal_name', 'address_text', 'bin_iin')),
    previous_value              text,
    proposed_value              text not null,
    status                      text not null default 'pending'
                                check (status in ('pending', 'approved', 'rejected')),
    requested_by_user_id        uuid references public.users(id) on delete set null,
    requested_at                timestamptz not null default now(),
    reviewed_by_user_id         uuid references public.users(id) on delete set null,
    reviewed_at                 timestamptz,
    review_note                 text,
    production_value_applied_at timestamptz,
    constraint org_field_reviews_proposed_check check (
        proposed_value = btrim(proposed_value)
        and length(proposed_value) between 1 and 1000
    ),
    constraint org_field_reviews_note_check check (
        review_note is null
        or (review_note = btrim(review_note) and length(review_note) between 1 and 2000)
    ),
    constraint org_field_reviews_state_check check (
        (status = 'pending' and reviewed_by_user_id is null and reviewed_at is null)
        or
        (status in ('approved', 'rejected')
            and reviewed_by_user_id is not null and reviewed_at is not null)
    ),
    constraint org_field_reviews_apply_timing_check check (
        (field_name = 'bin_iin' and status = 'pending'
            and production_value_applied_at is null)
        or
        (field_name = 'bin_iin' and status = 'approved'
            and production_value_applied_at is not null)
        or
        (field_name = 'bin_iin' and status = 'rejected'
            and production_value_applied_at is null)
        or
        (field_name in ('legal_name', 'address_text')
            and production_value_applied_at is not null)
    )
);

comment on table public.org_field_reviews is
    'ARS-359 / D-MPK-CRIT-03: append-only proposal/review trail. legal_name/address_text apply immediately; bin_iin changes only on TURAN approval.';

-- -----------------------------------------------------------------------------
-- 3. FK/RLS/query indexes and uniqueness invariants.
-- -----------------------------------------------------------------------------

create index if not exists idx_mpk_sites_organization
    on public.mpk_sites (organization_id, is_active, created_at desc);
create index if not exists idx_mpk_sites_region
    on public.mpk_sites (region_id) where region_id is not null;
create index if not exists idx_mpk_sites_created_by
    on public.mpk_sites (created_by_user_id) where created_by_user_id is not null;
create unique index if not exists uq_mpk_sites_active_primary
    on public.mpk_sites (organization_id)
    where is_primary and is_active;

create index if not exists idx_org_bank_accounts_org_current
    on public.org_bank_accounts (organization_id, valid_from desc)
    where valid_to is null;
create index if not exists idx_org_bank_accounts_created_by
    on public.org_bank_accounts (created_by_user_id)
    where created_by_user_id is not null;
create unique index if not exists uq_org_bank_accounts_current_iban
    on public.org_bank_accounts (organization_id, iban)
    where valid_to is null;
create unique index if not exists uq_org_bank_accounts_current_primary
    on public.org_bank_accounts (organization_id)
    where is_primary and valid_to is null;

create index if not exists idx_org_field_reviews_org_status
    on public.org_field_reviews (organization_id, status, requested_at desc);
create index if not exists idx_org_field_reviews_requested_by
    on public.org_field_reviews (requested_by_user_id)
    where requested_by_user_id is not null;
create index if not exists idx_org_field_reviews_reviewed_by
    on public.org_field_reviews (reviewed_by_user_id)
    where reviewed_by_user_id is not null;
create unique index if not exists uq_org_field_reviews_pending
    on public.org_field_reviews (organization_id, field_name)
    where status = 'pending';

-- -----------------------------------------------------------------------------
-- 4. RLS is defense in depth; tables are RPC-only for authenticated clients.
-- -----------------------------------------------------------------------------

alter table public.mpk_profiles enable row level security;
alter table public.mpk_sites enable row level security;
alter table public.org_bank_accounts enable row level security;
alter table public.org_field_reviews enable row level security;

drop policy if exists mpk_profiles_read_own_admin on public.mpk_profiles;
create policy mpk_profiles_read_own_admin
    on public.mpk_profiles for select
    to authenticated
    using (
        organization_id = any(
            coalesce((select public.fn_my_org_ids()), array[]::uuid[])
        )
        or (select public.fn_is_admin())
    );

drop policy if exists mpk_sites_read_own_admin on public.mpk_sites;
create policy mpk_sites_read_own_admin
    on public.mpk_sites for select
    to authenticated
    using (
        organization_id = any(
            coalesce((select public.fn_my_org_ids()), array[]::uuid[])
        )
        or (select public.fn_is_admin())
    );

drop policy if exists org_bank_accounts_read_authorized on public.org_bank_accounts;
create policy org_bank_accounts_read_authorized
    on public.org_bank_accounts for select
    to authenticated
    using (
        (select public.fn_org_has_permission(
            organization_id, 'mpk.bank.manage'
        ))
        or (select public.fn_is_admin())
    );

drop policy if exists org_field_reviews_read_own_admin on public.org_field_reviews;
create policy org_field_reviews_read_own_admin
    on public.org_field_reviews for select
    to authenticated
    using (
        organization_id = any(
            coalesce((select public.fn_my_org_ids()), array[]::uuid[])
        )
        or (select public.fn_is_admin())
    );

revoke all on table public.mpk_profiles
    from public, anon, authenticated, service_role;
revoke all on table public.mpk_sites
    from public, anon, authenticated, service_role;
revoke all on table public.org_bank_accounts
    from public, anon, authenticated, service_role;
revoke all on table public.org_field_reviews
    from public, anon, authenticated, service_role;

grant select, insert, update, delete on table public.mpk_profiles to service_role;
grant select, insert, update, delete on table public.mpk_sites to service_role;
grant select, insert, update, delete on table public.org_bank_accounts to service_role;
grant select, insert, update, delete on table public.org_field_reviews to service_role;

-- -----------------------------------------------------------------------------
-- 5. Update/version guards and timestamps.
-- -----------------------------------------------------------------------------

create or replace function public.fn_guard_org_bank_account_version()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if new.organization_id is distinct from old.organization_id
       or new.logical_account_id is distinct from old.logical_account_id
       or new.version_no is distinct from old.version_no
       or new.supersedes_id is distinct from old.supersedes_id
       or new.bank_name is distinct from old.bank_name
       or new.bik is distinct from old.bik
       or new.iban is distinct from old.iban
       or new.account_holder_name is distinct from old.account_holder_name
       or new.currency_code is distinct from old.currency_code
       or new.valid_from is distinct from old.valid_from
       or new.created_by_user_id is distinct from old.created_by_user_id
       or new.created_at is distinct from old.created_at then
        raise exception 'BANK_ACCOUNT_APPEND_NEW_REQUIRED' using errcode = 'P0001';
    end if;
    return new;
end;
$$;

revoke execute on function public.fn_guard_org_bank_account_version()
    from public, anon, authenticated;

drop trigger if exists trg_org_bank_accounts_version_guard
    on public.org_bank_accounts;
create trigger trg_org_bank_accounts_version_guard
    before update on public.org_bank_accounts
    for each row execute function public.fn_guard_org_bank_account_version();

create or replace function public.fn_guard_org_critical_field_updates()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if (
        new.legal_name is distinct from old.legal_name
        or new.address_text is distinct from old.address_text
        or new.bin_iin is distinct from old.bin_iin
    ) and current_user in ('anon', 'authenticated', 'authenticator') then
        raise exception 'CRITICAL_FIELD_RPC_REQUIRED' using errcode = '42501';
    end if;
    return new;
end;
$$;

comment on function public.fn_guard_org_critical_field_updates() is
    'ARS-359: prevents authenticated direct-table updates from bypassing the legal_name/address review trail or BIN apply-on-approve invariant. Trusted SECURITY DEFINER/admin/service paths remain available.';

revoke execute on function public.fn_guard_org_critical_field_updates()
    from public, anon, authenticated;

drop trigger if exists trg_organizations_critical_field_guard
    on public.organizations;
create trigger trg_organizations_critical_field_guard
    before update of legal_name, address_text, bin_iin on public.organizations
    for each row execute function public.fn_guard_org_critical_field_updates();

drop trigger if exists trg_mpk_profiles_updated_at on public.mpk_profiles;
create trigger trg_mpk_profiles_updated_at
    before update on public.mpk_profiles
    for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_mpk_sites_updated_at on public.mpk_sites;
create trigger trg_mpk_sites_updated_at
    before update on public.mpk_sites
    for each row execute function public.fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6. Permission-checked write paths.
-- -----------------------------------------------------------------------------

create or replace function public.rpc_upsert_mpk_profile(
    p_organization_id    uuid,
    p_public_description text,
    p_logo_path          text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id uuid := public.fn_current_user_id();
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.profile.edit') then
        raise exception 'FORBIDDEN: mpk.profile.edit required' using errcode = '42501';
    end if;
    if not exists (
        select 1
        from public.organizations o
        join public.organization_type_assignments ota
          on ota.organization_id = o.id and ota.org_type = 'mpk'
        where o.id = p_organization_id and o.is_active
    ) then
        raise exception 'ORG_NOT_ACTIVE_MPK' using errcode = 'P0001';
    end if;

    insert into public.mpk_profiles (
        organization_id, public_description, logo_path
    ) values (
        p_organization_id,
        nullif(btrim(p_public_description), ''),
        nullif(btrim(p_logo_path), '')
    )
    on conflict (organization_id) do update
       set public_description = excluded.public_description,
           logo_path = excluded.logo_path;

    return p_organization_id;
end;
$$;

create or replace function public.rpc_update_mpk_org_details(
    p_organization_id uuid,
    p_region_id       uuid,
    p_head_full_name  text,
    p_head_title      text,
    p_phone           text,
    p_email           text,
    p_website         text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.profile.edit') then
        raise exception 'FORBIDDEN: mpk.profile.edit required' using errcode = '42501';
    end if;
    if p_email is not null and (
        length(btrim(p_email)) > 320 or position('@' in btrim(p_email)) <= 1
    ) then
        raise exception 'INVALID_EMAIL' using errcode = 'P0001';
    end if;

    update public.organizations o
       set region_id = p_region_id,
           head_full_name = nullif(btrim(p_head_full_name), ''),
           head_title = nullif(btrim(p_head_title), ''),
           phone = nullif(btrim(p_phone), ''),
           email = lower(nullif(btrim(p_email), '')),
           website = nullif(btrim(p_website), '')
     where o.id = p_organization_id
       and o.is_active
       and exists (
            select 1 from public.organization_type_assignments ota
            where ota.organization_id = o.id and ota.org_type = 'mpk'
       );
    if not found then
        raise exception 'ORG_NOT_ACTIVE_MPK' using errcode = 'P0001';
    end if;
end;
$$;

create or replace function public.rpc_save_mpk_primary_site(
    p_organization_id                  uuid,
    p_site_name                        text,
    p_address_text                     text,
    p_processing_capacity_heads_per_day int,
    p_region_id                        uuid default null,
    p_phone                            text default null,
    p_email                            text default null,
    p_site_id                          uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id uuid := public.fn_current_user_id();
    v_site_id  uuid := p_site_id;
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.profile.edit') then
        raise exception 'FORBIDDEN: mpk.profile.edit required' using errcode = '42501';
    end if;
    if p_processing_capacity_heads_per_day is null
       or p_processing_capacity_heads_per_day <= 0 then
        raise exception 'CAPACITY_MUST_BE_POSITIVE' using errcode = 'P0001';
    end if;
    if p_email is not null and (
        length(btrim(p_email)) > 320 or position('@' in btrim(p_email)) <= 1
    ) then
        raise exception 'INVALID_EMAIL' using errcode = 'P0001';
    end if;

    perform 1
    from public.organizations o
    join public.organization_type_assignments ota
      on ota.organization_id = o.id and ota.org_type = 'mpk'
    where o.id = p_organization_id and o.is_active
    for update of o;
    if not found then
        raise exception 'ORG_NOT_ACTIVE_MPK' using errcode = 'P0001';
    end if;

    if v_site_id is null then
        select s.id into v_site_id
        from public.mpk_sites s
        where s.organization_id = p_organization_id
          and s.is_primary and s.is_active
        for update;
    elsif not exists (
        select 1 from public.mpk_sites s
        where s.id = v_site_id and s.organization_id = p_organization_id
    ) then
        raise exception 'SITE_NOT_FOUND' using errcode = 'P0001';
    end if;

    update public.mpk_sites
       set is_primary = false
     where organization_id = p_organization_id
       and is_primary
       and (v_site_id is null or id <> v_site_id);

    if v_site_id is null then
        insert into public.mpk_sites (
            organization_id, site_name, region_id, address_text,
            processing_capacity_heads_per_day, phone, email,
            is_primary, is_active, created_by_user_id
        ) values (
            p_organization_id, btrim(p_site_name), p_region_id, btrim(p_address_text),
            p_processing_capacity_heads_per_day,
            nullif(btrim(p_phone), ''), lower(nullif(btrim(p_email), '')),
            true, true, v_actor_id
        ) returning id into v_site_id;
    else
        update public.mpk_sites
           set site_name = btrim(p_site_name),
               region_id = p_region_id,
               address_text = btrim(p_address_text),
               processing_capacity_heads_per_day = p_processing_capacity_heads_per_day,
               phone = nullif(btrim(p_phone), ''),
               email = lower(nullif(btrim(p_email), '')),
               is_primary = true,
               is_active = true
         where id = v_site_id and organization_id = p_organization_id;
    end if;

    return v_site_id;
end;
$$;

create or replace function public.rpc_append_org_bank_account(
    p_organization_id     uuid,
    p_bank_name           text,
    p_bik                 text,
    p_iban                text,
    p_account_holder_name text,
    p_currency_code       text default 'KZT',
    p_is_primary          boolean default null,
    p_previous_account_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id          uuid := public.fn_current_user_id();
    v_previous          public.org_bank_accounts%rowtype;
    v_logical_id        uuid;
    v_version_no        int;
    v_make_primary      boolean;
    v_new_id            uuid;
    v_now               timestamptz := clock_timestamp();
    v_bik               text := regexp_replace(upper(coalesce(p_bik, '')), '\s+', '', 'g');
    v_iban              text := regexp_replace(upper(coalesce(p_iban, '')), '\s+', '', 'g');
    v_currency          text := upper(btrim(coalesce(p_currency_code, 'KZT')));
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.bank.manage') then
        raise exception 'FORBIDDEN: mpk.bank.manage required' using errcode = '42501';
    end if;

    perform 1
    from public.organizations o
    join public.organization_type_assignments ota
      on ota.organization_id = o.id and ota.org_type = 'mpk'
    where o.id = p_organization_id and o.is_active
    for update of o;
    if not found then
        raise exception 'ORG_NOT_ACTIVE_MPK' using errcode = 'P0001';
    end if;

    if v_bik !~ '^[A-Z0-9]{8,12}$' then
        raise exception 'INVALID_BIK' using errcode = 'P0001';
    end if;
    if v_iban !~ '^KZ[A-Z0-9]{18}$' then
        raise exception 'INVALID_IBAN' using errcode = 'P0001';
    end if;

    if p_previous_account_id is not null then
        select * into v_previous
        from public.org_bank_accounts a
        where a.id = p_previous_account_id
          and a.organization_id = p_organization_id
        for update;
        if not found then
            raise exception 'BANK_ACCOUNT_NOT_FOUND' using errcode = 'P0001';
        end if;
        if v_previous.valid_to is not null then
            raise exception 'BANK_ACCOUNT_VERSION_NOT_CURRENT' using errcode = 'P0001';
        end if;

        v_logical_id := v_previous.logical_account_id;
        v_version_no := v_previous.version_no + 1;
        v_make_primary := coalesce(p_is_primary, v_previous.is_primary);

        update public.org_bank_accounts
           set valid_to = v_now,
               is_primary = false
         where id = v_previous.id;
    else
        v_logical_id := gen_random_uuid();
        v_version_no := 1;
        v_make_primary := coalesce(
            p_is_primary,
            not exists (
                select 1 from public.org_bank_accounts a
                where a.organization_id = p_organization_id
                  and a.valid_to is null
            )
        );
    end if;

    if v_make_primary then
        update public.org_bank_accounts
           set is_primary = false
         where organization_id = p_organization_id
           and valid_to is null
           and is_primary;
    end if;

    insert into public.org_bank_accounts (
        organization_id, logical_account_id, version_no, supersedes_id,
        bank_name, bik, iban, account_holder_name, currency_code,
        is_primary, valid_from, created_by_user_id
    ) values (
        p_organization_id, v_logical_id, v_version_no, p_previous_account_id,
        btrim(p_bank_name), v_bik, v_iban, btrim(p_account_holder_name), v_currency,
        v_make_primary, v_now, v_actor_id
    ) returning id into v_new_id;

    return v_new_id;
end;
$$;

create or replace function public.fn_org_bank_account_snapshot(p_account_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    select jsonb_build_object(
        'account_id', a.id,
        'organization_id', a.organization_id,
        'logical_account_id', a.logical_account_id,
        'version_no', a.version_no,
        'bank_name', a.bank_name,
        'bik', a.bik,
        'iban', a.iban,
        'account_holder_name', a.account_holder_name,
        'currency_code', a.currency_code,
        'valid_from', a.valid_from
    )
    from public.org_bank_accounts a
    where a.id = p_account_id;
$$;

comment on function public.fn_org_bank_account_snapshot(uuid) is
    'ARS-359 deal-document invariant: resolve one explicit bank-account version once and persist this JSON in the document snapshot; never regenerate historical documents from the current primary account.';

create or replace function public.rpc_propose_org_field_change(
    p_organization_id uuid,
    p_field_name      text,
    p_proposed_value  text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id      uuid := public.fn_current_user_id();
    v_previous      text;
    v_proposed      text;
    v_review_id     uuid;
    v_applied_at    timestamptz;
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.profile.edit') then
        raise exception 'FORBIDDEN: mpk.profile.edit required' using errcode = '42501';
    end if;
    if p_field_name is null
       or p_field_name not in ('legal_name', 'address_text', 'bin_iin') then
        raise exception 'INVALID_REVIEW_FIELD: %', p_field_name using errcode = 'P0001';
    end if;

    select case p_field_name
               when 'legal_name' then o.legal_name
               when 'address_text' then o.address_text
               when 'bin_iin' then o.bin_iin
           end
      into v_previous
    from public.organizations o
    where o.id = p_organization_id
      and o.is_active
      and exists (
          select 1 from public.organization_type_assignments ota
          where ota.organization_id = o.id and ota.org_type = 'mpk'
      )
    for update;
    if not found then
        raise exception 'ORG_NOT_ACTIVE_MPK' using errcode = 'P0001';
    end if;

    v_proposed := case p_field_name
        when 'bin_iin' then regexp_replace(coalesce(p_proposed_value, ''), '\s+', '', 'g')
        else btrim(coalesce(p_proposed_value, ''))
    end;
    if v_proposed = '' then
        raise exception 'FIELD_VALUE_REQUIRED' using errcode = 'P0001';
    end if;
    if p_field_name = 'bin_iin' and v_proposed !~ '^[0-9]{12}$' then
        raise exception 'INVALID_BIN_IIN' using errcode = 'P0001';
    end if;
    if p_field_name = 'legal_name' and length(v_proposed) > 500 then
        raise exception 'LEGAL_NAME_TOO_LONG' using errcode = 'P0001';
    end if;
    if p_field_name = 'address_text' and length(v_proposed) > 1000 then
        raise exception 'ADDRESS_TOO_LONG' using errcode = 'P0001';
    end if;
    if v_proposed is not distinct from v_previous then
        raise exception 'FIELD_VALUE_UNCHANGED' using errcode = 'P0001';
    end if;
    if exists (
        select 1 from public.org_field_reviews r
        where r.organization_id = p_organization_id
          and r.field_name = p_field_name
          and r.status = 'pending'
    ) then
        raise exception 'FIELD_REVIEW_ALREADY_PENDING' using errcode = 'P0001';
    end if;

    if p_field_name = 'legal_name' then
        update public.organizations
           set legal_name = v_proposed
         where id = p_organization_id;
        v_applied_at := now();
    elsif p_field_name = 'address_text' then
        update public.organizations
           set address_text = v_proposed
         where id = p_organization_id;
        v_applied_at := now();
    end if;

    insert into public.org_field_reviews (
        organization_id, field_name, previous_value, proposed_value,
        requested_by_user_id, production_value_applied_at
    ) values (
        p_organization_id, p_field_name, v_previous, v_proposed,
        v_actor_id, v_applied_at
    ) returning id into v_review_id;

    return v_review_id;
end;
$$;

create or replace function public.rpc_review_org_field_change(
    p_review_id uuid,
    p_decision  text,
    p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id uuid := public.fn_current_user_id();
    v_review   public.org_field_reviews%rowtype;
    v_current  text;
    v_now      timestamptz := now();
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: TURAN admin required' using errcode = '42501';
    end if;
    if p_decision is null or p_decision not in ('approved', 'rejected') then
        raise exception 'INVALID_REVIEW_DECISION' using errcode = 'P0001';
    end if;

    select * into v_review
    from public.org_field_reviews r
    where r.id = p_review_id
    for update;
    if not found then
        raise exception 'FIELD_REVIEW_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_review.status = p_decision then
        return jsonb_build_object(
            'ok', true, 'id', v_review.id, 'status', v_review.status,
            'idempotent', true,
            'production_value_applied_at', v_review.production_value_applied_at
        );
    end if;
    if v_review.status <> 'pending' then
        raise exception 'FIELD_REVIEW_ALREADY_DECIDED' using errcode = 'P0001';
    end if;

    select case v_review.field_name
               when 'legal_name' then o.legal_name
               when 'address_text' then o.address_text
               when 'bin_iin' then o.bin_iin
           end
      into v_current
    from public.organizations o
    where o.id = v_review.organization_id
    for update;
    if not found then
        raise exception 'ORGANIZATION_NOT_FOUND' using errcode = 'P0001';
    end if;

    if p_decision = 'approved' then
        if v_review.field_name = 'bin_iin' then
            if v_current is distinct from v_review.previous_value then
                raise exception 'FIELD_BASELINE_CHANGED' using errcode = 'P0001';
            end if;
            begin
                update public.organizations
                   set bin_iin = v_review.proposed_value
                 where id = v_review.organization_id;
            exception
                when unique_violation then
                    raise exception 'BIN_IIN_ALREADY_EXISTS' using errcode = 'P0001';
            end;
        elsif v_current is distinct from v_review.proposed_value then
            raise exception 'FIELD_VALUE_CHANGED_AFTER_PROPOSAL' using errcode = 'P0001';
        end if;
    end if;

    update public.org_field_reviews
       set status = p_decision,
           reviewed_by_user_id = v_actor_id,
           reviewed_at = v_now,
           review_note = nullif(btrim(p_note), ''),
           production_value_applied_at = case
               when p_decision = 'approved' and field_name = 'bin_iin' then v_now
               else production_value_applied_at
           end
     where id = v_review.id
     returning * into v_review;

    return jsonb_build_object(
        'ok', true,
        'id', v_review.id,
        'organization_id', v_review.organization_id,
        'field_name', v_review.field_name,
        'status', v_review.status,
        'idempotent', false,
        'production_value_applied_at', v_review.production_value_applied_at
    );
end;
$$;

comment on function public.rpc_propose_org_field_change(uuid, text, text) is
    'ARS-359 / D-MPK-CRIT-03. Requires mpk.profile.edit. legal_name/address_text apply immediately with pending audit; bin_iin remains unchanged until TURAN approval.';
comment on function public.rpc_review_org_field_change(uuid, text, text) is
    'ARS-359 / D-MPK-CRIT-03. TURAN-only, row-locked approve/reject. BIN is atomically applied only on approve and only if its proposal baseline is unchanged.';

revoke execute on function public.rpc_upsert_mpk_profile(uuid, text, text)
    from public, anon;
revoke execute on function public.rpc_update_mpk_org_details(uuid, uuid, text, text, text, text, text)
    from public, anon;
revoke execute on function public.rpc_save_mpk_primary_site(uuid, text, text, int, uuid, text, text, uuid)
    from public, anon;
revoke execute on function public.rpc_append_org_bank_account(uuid, text, text, text, text, text, boolean, uuid)
    from public, anon;
revoke execute on function public.fn_org_bank_account_snapshot(uuid)
    from public, anon, authenticated;
revoke execute on function public.rpc_propose_org_field_change(uuid, text, text)
    from public, anon;
revoke execute on function public.rpc_review_org_field_change(uuid, text, text)
    from public, anon;

grant execute on function public.rpc_upsert_mpk_profile(uuid, text, text)
    to authenticated, service_role;
grant execute on function public.rpc_update_mpk_org_details(uuid, uuid, text, text, text, text, text)
    to authenticated, service_role;
grant execute on function public.rpc_save_mpk_primary_site(uuid, text, text, int, uuid, text, text, uuid)
    to authenticated, service_role;
grant execute on function public.rpc_append_org_bank_account(uuid, text, text, text, text, text, boolean, uuid)
    to authenticated, service_role;
grant execute on function public.fn_org_bank_account_snapshot(uuid)
    to service_role;
grant execute on function public.rpc_propose_org_field_change(uuid, text, text)
    to authenticated, service_role;
grant execute on function public.rpc_review_org_field_change(uuid, text, text)
    to authenticated, service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
    ('rpc_upsert_mpk_profile', 'rpc_upsert_mpk_profile', '20260730134113_ars_359_mpk_profile_data_model.sql', 'Authorized sparse MPK editorial profile upsert'),
    ('rpc_update_mpk_org_details', 'rpc_update_mpk_org_details', '20260730134113_ars_359_mpk_profile_data_model.sql', 'Authorized canonical organization head/contact update'),
    ('rpc_save_mpk_primary_site', 'rpc_save_mpk_primary_site', '20260730134113_ars_359_mpk_profile_data_model.sql', 'Authorized primary MPK site/capacity create or update'),
    ('rpc_append_org_bank_account', 'rpc_append_org_bank_account', '20260730134113_ars_359_mpk_profile_data_model.sql', 'Append-new versioned bank account write'),
    ('rpc_propose_org_field_change', 'rpc_propose_org_field_change', '20260730134113_ars_359_mpk_profile_data_model.sql', 'Critical organization field proposal'),
    ('rpc_review_org_field_change', 'rpc_review_org_field_change', '20260730134113_ars_359_mpk_profile_data_model.sql', 'TURAN critical-field approve/reject')
on conflict (sql_name) do update
set notes = excluded.notes,
    created_in = excluded.created_in,
    status = 'active';
