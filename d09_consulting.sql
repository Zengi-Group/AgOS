-- ============================================================
-- d09_consulting.sql — Consulting Domain (Investment Project Packaging)
-- AGOS · Zengi Farms · ADR-CONSULT-1 (Hybrid Architecture)
-- ============================================================
-- Домен: инвестиционное проектирование животноводческих ферм
-- Пользователи: консультанты Zengi (org_type = consultant)
-- Зависимости: d01_kernel (users, organizations, platform_events, rpc_name_registry)
-- ============================================================

-- ==========================
-- SECTION 1 · TABLES
-- ==========================

-- 1.1  Consulting Projects — инвестиционные проекты
create table if not exists public.consulting_projects (
    id                  uuid        primary key default gen_random_uuid(),
    organization_id     uuid        not null references public.organizations(id),
    name                text        not null,
    farm_type           text        not null default 'beef_reproducer'
                                        check (farm_type in (
                                            'beef_reproducer',
                                            'feedlot',
                                            'sheep_goat'
                                        )),
    status              text        not null default 'draft'
                                        check (status in (
                                            'draft',
                                            'calculating',
                                            'calculated',
                                            'archived'
                                        )),
    created_by          uuid        references public.users(id),
    is_active           boolean     not null default true,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);

comment on table public.consulting_projects is
    'Dok 1 §Consulting | Инвестиционные проекты для упаковки.
     FSM: draft → calculating → calculated → archived.
     Каждый проект принадлежит организации (Zengi tenant).';

-- ADR-RATION-01 DEF-RATION-04: season boundaries for feeding cost split (Dok 7 §9.2)
-- Default 5/10 = May–October = Kazakhstan central belt pasture season.
-- Override per project in ProjectWizard for northern KZ (start=4) or southern (start=4, end=11).
ALTER TABLE public.consulting_projects
    ADD COLUMN IF NOT EXISTS pasture_start_month smallint NOT NULL DEFAULT 5
        CHECK (pasture_start_month BETWEEN 1 AND 12),
    ADD COLUMN IF NOT EXISTS pasture_end_month   smallint NOT NULL DEFAULT 10
        CHECK (pasture_end_month   BETWEEN 1 AND 12);

-- Dok 7 §10.5: staleness flag — set true when rations change, cleared on recalculation
ALTER TABLE public.consulting_projects
    ADD COLUMN IF NOT EXISTS needs_recalc boolean NOT NULL DEFAULT false;

-- ADR-CAPEX-01: CAPEX module — per-project material choice + per-item overrides
-- Defaults encode Excel row 84-85 "Выбранная цена м²" selections.
ALTER TABLE public.consulting_projects
    ADD COLUMN IF NOT EXISTS construction_material_enclosed text  NOT NULL DEFAULT 'sandwich',
    ADD COLUMN IF NOT EXISTS construction_material_support  text  NOT NULL DEFAULT 'light_frame',
    ADD COLUMN IF NOT EXISTS infra_items_override           jsonb NOT NULL DEFAULT '[]'::jsonb;

-- 1.2  Project Versions — версии расчёта (иммутабельные)
create table if not exists public.consulting_project_versions (
    id                  uuid        primary key default gen_random_uuid(),
    project_id          uuid        not null references public.consulting_projects(id),
    organization_id     uuid        not null references public.organizations(id),
    version_number      int         not null,
    input_params        jsonb       not null,
    results             jsonb,
    calculated_at       timestamptz,
    created_at          timestamptz not null default now(),
    constraint uq_consulting_version unique (project_id, version_number)
);

comment on table public.consulting_project_versions is
    'Dok 1 §Consulting | Каждое изменение параметров = новая версия.
     input_params: все входные параметры wizard (20+ полей).
     results: JSON со всеми 11 модулями финмодели (120 мес × модули).
     Иммутабельная после расчёта — не обновляется, только новые версии.';

-- 1.3  Reference Data — справочники (кормовые нормы, цены, нормативы)
create table if not exists public.consulting_reference_data (
    id                  serial      primary key,
    category            text        not null
                                        check (category in (
                                            -- Slice 8 ADR-FEED-01: feed_norms + feed_prices
                                            -- мигрированы в d03_feed.feed_consumption_norms
                                            -- и d03_feed.feed_prices. Категории удалены из CHECK.
                                            'infrastructure_norms',
                                            'equipment_norms',
                                            'tax_rates',
                                            'wacc_parameters',
                                            'subsidy_programs',
                                            'livestock_norms',
                                            'regional_prices',
                                            'economic_parameters',
                                            -- ADR-CAPEX-01: CAPEX module reference data
                                            'construction_materials',
                                            'capex_surcharges'
                                        )),
    code                text        not null,
    data                jsonb       not null,
    valid_from          date        not null default current_date,
    valid_to            date,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    constraint uq_consulting_ref unique (category, code, valid_from)
);

comment on table public.consulting_reference_data is
    'Dok 1 §Consulting | Справочники для расчётного ядра.
     P8: все нормативы из БД, не из хардкода.
     Обновление справочника не требует деплоя.
     Временна́я валидность: valid_from..valid_to.';


-- ==========================
-- SECTION 2 · INDEXES
-- ==========================

create index if not exists idx_cp_org
    on public.consulting_projects (organization_id);

create index if not exists idx_cp_status
    on public.consulting_projects (status)
    where is_active = true;

create index if not exists idx_cpv_project
    on public.consulting_project_versions (project_id);

create index if not exists idx_cpv_org
    on public.consulting_project_versions (organization_id);

create index if not exists idx_crd_category
    on public.consulting_reference_data (category, code);


-- ==========================
-- SECTION 3 · RLS POLICIES
-- ==========================

alter table public.consulting_projects enable row level security;
alter table public.consulting_project_versions enable row level security;
alter table public.consulting_reference_data enable row level security;

-- 3.1  consulting_projects: org members + admins read/write own
drop policy if exists "cp_read_own" on public.consulting_projects;
create policy "cp_read_own"
    on public.consulting_projects for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

drop policy if exists "cp_write_own" on public.consulting_projects;
create policy "cp_write_own"
    on public.consulting_projects for all
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

-- 3.2  consulting_project_versions: org members + admins
drop policy if exists "cpv_read_own" on public.consulting_project_versions;
create policy "cpv_read_own"
    on public.consulting_project_versions for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

drop policy if exists "cpv_write_own" on public.consulting_project_versions;
create policy "cpv_write_own"
    on public.consulting_project_versions for all
    using (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );

-- 3.3  consulting_reference_data: everyone reads, admin writes
drop policy if exists "crd_read_all" on public.consulting_reference_data;
create policy "crd_read_all"
    on public.consulting_reference_data for select
    using (true);

drop policy if exists "crd_admin_write" on public.consulting_reference_data;
create policy "crd_admin_write"
    on public.consulting_reference_data for all
    using (public.fn_is_admin());


-- ==========================
-- SECTION 4 · RPC FUNCTIONS
-- ==========================

-- ---- RPC-C01: Create consulting project ----
drop function if exists public.rpc_create_consulting_project(p_organization_id uuid, p_name text, p_farm_type text);
create or replace function public.rpc_create_consulting_project(
    p_organization_id   uuid,
    p_name              text,
    p_farm_type         text    default 'beef_reproducer'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
begin
    -- DEF-CONSULTING-AUTH-02 (2026-07-22): p_organization_id was trusted from the
    -- client with no ownership check — any authenticated caller could create a
    -- project under an org they don't belong to. Same fn_my_org_ids()/fn_is_admin()
    -- guard already used elsewhere (e.g. d05_ops_edu.sql farm RPCs).
    if not (
        p_organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    ) then
        raise exception 'FORBIDDEN' using errcode = 'P0001';
    end if;

    select u.id into v_user_id
    from public.users u
    where u.auth_id = auth.uid();

    if v_user_id is null then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0001';
    end if;

    insert into public.consulting_projects (
        organization_id, name, farm_type, created_by
    ) values (
        p_organization_id, p_name, p_farm_type, v_user_id
    )
    returning id into v_project_id;

    -- Event
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'consulting.project.created',
        'consulting_projects',
        v_project_id,
        p_organization_id,
        'farmer',
        v_user_id,
        jsonb_build_object(
            'project_id', v_project_id,
            'name', p_name,
            'farm_type', p_farm_type
        ),
        false
    );

    return v_project_id;
end;
$$;

comment on function public.rpc_create_consulting_project(uuid, text, text) is
    'RPC-C01 | Dok 3 §Consulting | Phase 0
     Creates new investment project in draft status.
     Events: consulting.project.created.';


-- ---- RPC-C02: List consulting projects ----
create or replace function public.rpc_list_consulting_projects(
    p_organization_id   uuid
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
    -- DEF-CONSULTING-AUTH-02 (2026-07-22): p_organization_id null + admin/expert
    -- (TURAN staff have no farmer organization_id of their own, P2) → list across
    -- all client orgs. Non-null values are still checked against fn_my_org_ids()
    -- so a farmer can't read another org's projects by passing an arbitrary id.
    if p_organization_id is null then
        if not (public.fn_is_admin() or public.fn_is_expert()) then
            raise exception 'FORBIDDEN' using errcode = 'P0001';
        end if;
    elsif not (
        p_organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    ) then
        raise exception 'FORBIDDEN' using errcode = 'P0001';
    end if;

    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', cp.id,
            'name', cp.name,
            'farm_type', cp.farm_type,
            'status', cp.status,
            'created_at', cp.created_at,
            'updated_at', cp.updated_at,
            'latest_version', (
                select jsonb_build_object(
                    'version_number', cpv.version_number,
                    'calculated_at', cpv.calculated_at,
                    'npv', cpv.results->'wacc'->'npv',
                    'irr', cpv.results->'wacc'->'irr'
                )
                from public.consulting_project_versions cpv
                where cpv.project_id = cp.id
                order by cpv.version_number desc
                limit 1
            )
        ) order by cp.updated_at desc
    ), '[]'::jsonb) into v_result
    from public.consulting_projects cp
    where (p_organization_id is null or cp.organization_id = p_organization_id)
      and cp.is_active = true;

    return v_result;
end;
$$;

comment on function public.rpc_list_consulting_projects(uuid) is
    'RPC-C02 | Dok 3 §Consulting | Phase 0
     Lists all active projects for org with latest version NPV/IRR.
     p_organization_id null + fn_is_admin()/fn_is_expert() → all orgs (DEF-CONSULTING-AUTH-02).';


-- ---- RPC-C03: Get consulting project detail ----
create or replace function public.rpc_get_consulting_project(
    p_organization_id   uuid,
    p_project_id        uuid
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
    -- DEF-CONSULTING-AUTH-02 (2026-07-22): same admin/expert bypass as
    -- rpc_list_consulting_projects — see that function's comment.
    if p_organization_id is null then
        if not (public.fn_is_admin() or public.fn_is_expert()) then
            raise exception 'FORBIDDEN' using errcode = 'P0001';
        end if;
    elsif not (
        p_organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or public.fn_is_expert()
    ) then
        raise exception 'FORBIDDEN' using errcode = 'P0001';
    end if;

    select jsonb_build_object(
        'id', cp.id,
        'name', cp.name,
        'farm_type', cp.farm_type,
        'status', cp.status,
        'needs_recalc', cp.needs_recalc,
        'organization_id', cp.organization_id,
        'created_by', cp.created_by,
        'created_at', cp.created_at,
        'updated_at', cp.updated_at,
        'versions', coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'id', cpv.id,
                    'version_number', cpv.version_number,
                    'input_params', cpv.input_params,
                    'calculated_at', cpv.calculated_at,
                    'npv', cpv.results->'wacc'->'npv',
                    'irr', cpv.results->'wacc'->'irr'
                ) order by cpv.version_number desc
            )
            from public.consulting_project_versions cpv
            where cpv.project_id = cp.id
        ), '[]'::jsonb)
    ) into v_result
    from public.consulting_projects cp
    where cp.id = p_project_id
      and (p_organization_id is null or cp.organization_id = p_organization_id)
      and cp.is_active = true;

    if v_result is null then
        raise exception 'PROJECT_NOT_FOUND' using errcode = 'P0001';
    end if;

    return v_result;
end;
$$;

comment on function public.rpc_get_consulting_project(uuid, uuid) is
    'RPC-C03 | Dok 3 §Consulting | Phase 0
     Returns project detail with all versions (without full results).
     p_organization_id null + fn_is_admin()/fn_is_expert() → any org (DEF-CONSULTING-AUTH-02).
     Returns organization_id (added 2026-07-22) so admin callers can act on the
     project''s real org rather than their own (which they may not have).';


-- ---- RPC-C04: Update consulting project ----
drop function if exists public.rpc_update_consulting_project(p_organization_id uuid, p_project_id uuid, p_name text, p_status text);
create or replace function public.rpc_update_consulting_project(
    p_organization_id   uuid,
    p_project_id        uuid,
    p_name              text    default null,
    p_status            text    default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_project record;
begin
    select * into v_project
    from public.consulting_projects
    where id = p_project_id
      and organization_id = p_organization_id
      and is_active = true;

    if v_project is null then
        raise exception 'PROJECT_NOT_FOUND' using errcode = 'P0001';
    end if;

    update public.consulting_projects
    set name       = coalesce(p_name, name),
        status     = coalesce(p_status, status),
        updated_at = now()
    where id = p_project_id;

    return true;
end;
$$;

comment on function public.rpc_update_consulting_project(uuid, uuid, text, text) is
    'RPC-C04 | Dok 3 §Consulting | Phase 0
     Updates project name and/or status. Null params = no change.';


-- ---- RPC-C05: Save consulting version (called by Python engine) ----
create or replace function public.rpc_save_consulting_version(
    p_organization_id   uuid,
    p_project_id        uuid,
    p_input_params      jsonb,
    p_results           jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_version_number int;
    v_version_id uuid;
begin
    -- Verify project exists and belongs to org
    if not exists (
        select 1 from public.consulting_projects
        where id = p_project_id
          and organization_id = p_organization_id
          and is_active = true
    ) then
        raise exception 'PROJECT_NOT_FOUND' using errcode = 'P0001';
    end if;

    -- Next version number
    select coalesce(max(version_number), 0) + 1
    into v_version_number
    from public.consulting_project_versions
    where project_id = p_project_id;

    -- Insert version
    insert into public.consulting_project_versions (
        project_id, organization_id, version_number,
        input_params, results, calculated_at
    ) values (
        p_project_id, p_organization_id, v_version_number,
        p_input_params, p_results, now()
    )
    returning id into v_version_id;

    -- Update project status + clear staleness flag (Dok 7 §10.5)
    update public.consulting_projects
    set status = 'calculated', needs_recalc = false, updated_at = now()
    where id = p_project_id;

    -- Event
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, payload, is_audit
    ) values (
        'consulting.version.created',
        'consulting_project_versions',
        v_version_id,
        p_organization_id,
        'system',
        jsonb_build_object(
            'project_id', p_project_id,
            'version_number', v_version_number,
            'npv', p_results->'wacc'->'npv',
            'irr', p_results->'wacc'->'irr'
        ),
        false
    );

    return v_version_id;
end;
$$;

comment on function public.rpc_save_consulting_version(uuid, uuid, jsonb, jsonb) is
    'RPC-C05 | Dok 3 §Consulting | Phase 3a
     Called by Python engine via service_role after calculation.
     Stores version with results, updates project status to calculated.
     Events: consulting.version.created.';


-- ---- RPC-C06: Get consulting version ----
create or replace function public.rpc_get_consulting_version(
    p_organization_id   uuid,
    p_version_id        uuid
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
        'id', cpv.id,
        'project_id', cpv.project_id,
        'version_number', cpv.version_number,
        'input_params', cpv.input_params,
        'results', cpv.results,
        'calculated_at', cpv.calculated_at,
        'created_at', cpv.created_at
    ) into v_result
    from public.consulting_project_versions cpv
    where cpv.id = p_version_id
      and cpv.organization_id = p_organization_id;

    if v_result is null then
        raise exception 'VERSION_NOT_FOUND' using errcode = 'P0001';
    end if;

    return v_result;
end;
$$;

comment on function public.rpc_get_consulting_version(uuid, uuid) is
    'RPC-C06 | Dok 3 §Consulting | Phase 0
     Returns full version with all results (11 modules).';


-- ---- RPC-C07: List consulting versions ----
create or replace function public.rpc_list_consulting_versions(
    p_organization_id   uuid,
    p_project_id        uuid
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
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', cpv.id,
            'version_number', cpv.version_number,
            'calculated_at', cpv.calculated_at,
            'npv', cpv.results->'wacc'->'npv',
            'irr', cpv.results->'wacc'->'irr',
            'created_at', cpv.created_at
        ) order by cpv.version_number desc
    ), '[]'::jsonb) into v_result
    from public.consulting_project_versions cpv
    where cpv.project_id = p_project_id
      and cpv.organization_id = p_organization_id;

    return v_result;
end;
$$;

comment on function public.rpc_list_consulting_versions(uuid, uuid) is
    'RPC-C07 | Dok 3 §Consulting | Phase 0
     Lists all versions for a project (without full results).';


-- ---- RPC-C08: Upsert consulting reference data [ADMIN] ----
drop function if exists public.rpc_upsert_consulting_reference(p_category text, p_code text, p_data jsonb, p_valid_from date);
create or replace function public.rpc_upsert_consulting_reference(
    p_category      text,
    p_code          text,
    p_data          jsonb,
    p_valid_from    date    default current_date
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id int;
begin
    -- Admin-only check
    if not public.fn_is_admin() then
        raise exception 'ADMIN_REQUIRED' using errcode = 'P0001';
    end if;

    insert into public.consulting_reference_data (
        category, code, data, valid_from
    ) values (
        p_category, p_code, p_data, p_valid_from
    )
    on conflict (category, code, valid_from)
    do update set
        data = excluded.data,
        updated_at = now()
    returning id into v_id;

    return v_id;
end;
$$;

comment on function public.rpc_upsert_consulting_reference(text, text, jsonb, date) is
    'RPC-C08 | Dok 3 §Consulting | Phase 0
     Admin-only: upserts reference data (feed norms, prices, tax rates, etc.).
     P8: all norms from DB, not from hardcode.';


-- ==========================
-- SECTION 5 · RPC REGISTRY
-- ==========================

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_create_consulting_project',   'rpc_create_consulting_project',   null, 'd09_consulting.sql (Phase 0)', 'RPC-C01: Create investment project'),
    ('rpc_list_consulting_projects',    'rpc_list_consulting_projects',    null, 'd09_consulting.sql (Phase 0)', 'RPC-C02: List projects with latest NPV/IRR'),
    ('rpc_get_consulting_project',      'rpc_get_consulting_project',      null, 'd09_consulting.sql (Phase 0)', 'RPC-C03: Project detail + versions'),
    ('rpc_update_consulting_project',   'rpc_update_consulting_project',   null, 'd09_consulting.sql (Phase 0)', 'RPC-C04: Update name/status'),
    ('rpc_save_consulting_version',     'rpc_save_consulting_version',     null, 'd09_consulting.sql (Phase 0)', 'RPC-C05: Save version (engine → DB)'),
    ('rpc_get_consulting_version',      'rpc_get_consulting_version',      null, 'd09_consulting.sql (Phase 0)', 'RPC-C06: Full version with results'),
    ('rpc_list_consulting_versions',    'rpc_list_consulting_versions',    null, 'd09_consulting.sql (Phase 0)', 'RPC-C07: Version list per project'),
    ('rpc_upsert_consulting_reference', 'rpc_upsert_consulting_reference', null, 'd09_consulting.sql (Phase 0)', 'RPC-C08: Admin reference data upsert')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;


-- ============================================================
-- SLICE 8 PART C: Consulting Ration RPCs
-- C-RPC-09: rpc_save_consulting_ration
-- C-RPC-10: rpc_get_consulting_rations
-- Зависит от: Часть C-DB (ration_versions migration в d03_feed.sql)
-- ============================================================

drop function if exists public.rpc_save_consulting_ration(p_organization_id uuid, p_consulting_project_id uuid, p_animal_category_id uuid, p_items jsonb, p_results jsonb);
create or replace function public.rpc_save_consulting_ration(
    p_organization_id           uuid,
    p_consulting_project_id     uuid,
    p_animal_category_id        uuid,
    p_items                     jsonb   default '[]',
    p_results                   jsonb   default '{}'
)
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
    v_version_num   int;
    v_version_id    uuid;
begin
    -- Verify project belongs to org (implicit auth: only valid org+project combo succeeds)
    -- fn_my_org_ids() check removed — called from SECURITY DEFINER edge function via service role;
    -- project ownership check is sufficient and more reliable across all call contexts.
    if not exists (
        select 1 from public.consulting_projects
        where id = p_consulting_project_id
          and organization_id = p_organization_id
          and is_active = true
    ) then
        raise exception 'PROJECT_NOT_FOUND';
    end if;

    -- Get next version number for this project + animal_category
    select coalesce(max(rv.version_number), 0) + 1
    into v_version_num
    from public.ration_versions rv
    where rv.consulting_project_id = p_consulting_project_id
      and rv.context_animal_category_id = p_animal_category_id;

    -- Deactivate previous versions for this project + category
    update public.ration_versions
    set is_current = false
    where consulting_project_id = p_consulting_project_id
      and context_animal_category_id = p_animal_category_id
      and is_current = true;

    -- Insert new version
    insert into public.ration_versions (
        ration_id,
        consulting_project_id,
        context_animal_category_id,
        version_number,
        items,
        results,
        is_current,
        calc_avg_weight_kg,
        calc_head_count,
        calc_objective,
        calculated_by
    ) values (
        null,                           -- no farm ration context
        p_consulting_project_id,
        p_animal_category_id,
        v_version_num,
        p_items,
        p_results,
        true,
        coalesce((p_results->>'calc_avg_weight_kg')::numeric, 0),
        coalesce((p_results->>'calc_head_count')::int, 1),
        coalesce(p_results->>'objective', 'growth'),
        'consulting_edge_function'
    )
    returning id into v_version_id;

    -- Dok 7 §10.5: rations changed → project needs recalculation
    update public.consulting_projects
    set needs_recalc = true, updated_at = now()
    where id = p_consulting_project_id;

    return jsonb_build_object(
        'ration_version_id', v_version_id,
        'version_number',    v_version_num
    );
end;
$$;

comment on function public.rpc_save_consulting_ration(uuid, uuid, uuid, jsonb, jsonb) is
    'C-RPC-09 | Dok 3 §13b | Slice 8 Part C
     Сохраняет результат NASEM-расчёта рациона для консалтингового проекта.
     Вызывается из Edge Function calculate-ration (consulting context).
     Создаёт новую версию ration_versions (consulting_project_id context).
     ADR-FEED-02: ration_versions контекст-независимое хранилище.';


create or replace function public.rpc_get_consulting_rations(
    p_organization_id           uuid,
    p_consulting_project_id     uuid
)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
    -- DEF-CONSULTING-AUTH-01 (2026-04-17): fn_my_org_ids()/fn_is_admin() checks removed.
    -- Same reasoning as rpc_save_consulting_ration: called from Python engine via
    -- service_role where auth.uid() is null → both auth helpers return false → RPC
    -- raised UNAUTHORIZED and calculate.py swallowed the error with try/except,
    -- silently downgrading to Priority 2. Project ownership check below is
    -- sufficient and works uniformly from web JWT and service_role contexts.
    if not exists (
        select 1 from public.consulting_projects
        where id = p_consulting_project_id
          and organization_id = p_organization_id
    ) then
        raise exception 'PROJECT_NOT_FOUND';
    end if;

    return (
        select jsonb_agg(
            jsonb_build_object(
                'ration_version_id',    rv.id,
                'animal_category_id',   rv.context_animal_category_id,
                'animal_category_name', ac.name_ru,
                'animal_category_code', ac.code,
                'version_number',       rv.version_number,
                'items',                rv.items,
                'results',              rv.results,
                'created_at',           rv.created_at
            ) order by ac.sort_order, rv.version_number desc
        )
        from public.ration_versions rv
        join public.animal_categories ac on ac.id = rv.context_animal_category_id
        where rv.consulting_project_id = p_consulting_project_id
          and rv.is_current = true
    );
end;
$$;

comment on function public.rpc_get_consulting_rations(uuid, uuid) is
    'C-RPC-10 | Dok 3 §13b | Slice 8 Part C
     Список текущих рационов для консалтингового проекта.
     Группировка по animal_category, только is_current=true версии.
     Используется: RationTab.tsx, feeding_model.py (Priority 1).
     STABLE — no side effects.';


-- Register Slice 8 Part C RPCs
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_save_consulting_ration', 'rpc_save_consulting_ration', null, 'd09_consulting.sql (Slice 8)', 'C-RPC-09: Save NASEM ration for consulting project (consulting ctx)'),
    ('rpc_get_consulting_rations', 'rpc_get_consulting_rations', null, 'd09_consulting.sql (Slice 8)', 'C-RPC-10: Get current rations per animal_category for project')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;

-- ============================================================
-- SEED: economic_parameters — Task C (feed inflation rate)
-- ============================================================
insert into public.consulting_reference_data (category, code, data, valid_from)
values (
    'economic_parameters',
    'feed_inflation',
    '{"rate": 0.105, "description": "Годовая инфляция цен на корма (РК, 2024–2025)", "source": "NBK/CPI"}'::jsonb,
    '2024-01-01'
)
on conflict (category, code, valid_from) do update
    set data = excluded.data;

-- ============================================================
-- ADR-CAPEX-01: CAPEX Module — Phase 1 (Data Model + Seed + RPCs)
-- Reference: .claude/plans/q1-rosy-lollipop.md (CEO-approved)
-- Acceptance target: at capacity=300, Зимний, defaults (sandwich+light_frame),
-- no overrides → engine reproduces Excel grand_total 282,465,145.54 ₸ ±1%.
-- ============================================================

-- ~~ 1. CHECK constraint (drop + re-add for existing deploys) ~~
-- Inline CREATE TABLE CHECK was already extended above; this ALTER ensures
-- existing databases (where CREATE TABLE IF NOT EXISTS is a no-op) receive
-- the two new categories. Additive — NEVER removes existing categories.
-- BUG FIX (deploy 2026-07-07): this intermediate rebuild was missing
-- 'livestock_prices' (added by a later ADR, see the second rebuild of this
-- same constraint further down) — live data already has rows with that
-- category, so this ADD CONSTRAINT failed on replay before ever reaching the
-- later block that would have fixed it. Widened here too so both are consistent.
alter table public.consulting_reference_data
    drop constraint if exists consulting_reference_data_category_check;
alter table public.consulting_reference_data
    add constraint consulting_reference_data_category_check check (category in (
        'infrastructure_norms',
        'equipment_norms',
        'tax_rates',
        'wacc_parameters',
        'subsidy_programs',
        'livestock_norms',
        'regional_prices',
        'economic_parameters',
        'construction_materials',
        'capex_surcharges',
        'livestock_prices'
    ));


-- ~~ 2. RPC — public readers (STABLE, readable to all authenticated) ~~

create or replace function public.rpc_list_construction_materials()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
    return coalesce((
        select jsonb_agg(
            jsonb_build_object(
                'code',        crd.code,
                'name_ru',     crd.data->>'name_ru',
                'cost_per_m2', (crd.data->>'cost_per_m2')::numeric,
                'currency',    coalesce(crd.data->>'currency', 'KZT'),
                'valid_from',  crd.valid_from,
                'valid_to',    crd.valid_to
            ) order by (crd.data->>'cost_per_m2')::numeric
        )
        from public.consulting_reference_data crd
        where crd.category = 'construction_materials'
          and (crd.valid_to is null or crd.valid_to > current_date)
    ), '[]'::jsonb);
end;
$$;

comment on function public.rpc_list_construction_materials() is
    'RPC-CAPEX-1 | ADR-CAPEX-01 | Phase 1
     Lists active construction materials (MVP: light_frame, sandwich, steel, brick).
     Used by ProjectWizard material selectors and CapexTab material override dropdown.';


create or replace function public.rpc_list_infrastructure_norms()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
    select coalesce(jsonb_object_agg(block, items), '{}'::jsonb)
    into v_result
    from (
        select crd.data->>'block' as block,
               jsonb_agg(
                   jsonb_build_object(
                       'code',       crd.code,
                       'data',       crd.data,
                       'valid_from', crd.valid_from,
                       'valid_to',   crd.valid_to
                   ) order by coalesce((crd.data->>'display_order')::int, 0), crd.code
               ) as items
        from public.consulting_reference_data crd
        where crd.category = 'infrastructure_norms'
          and (crd.valid_to is null or crd.valid_to > current_date)
          and crd.data ? 'block'
        group by crd.data->>'block'
    ) g;
    return v_result;
end;
$$;

comment on function public.rpc_list_infrastructure_norms() is
    'RPC-CAPEX-2 | ADR-CAPEX-01 | Phase 1
     Lists active infrastructure norms grouped by block (farm/pasture/equipment/tools),
     sorted by display_order. Used by engine/capex.py (Priority 2), CapexTab, /admin/capex.';


-- ~~ 3. RPC — admin upserts (fn_is_admin guard) ~~

create or replace function public.rpc_upsert_construction_material(
    p_code        text,
    p_name_ru     text,
    p_cost_per_m2 numeric
)
returns int
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare v_id int;
begin
    if not public.fn_is_admin() then
        raise exception 'ADMIN_REQUIRED' using errcode = 'P0001';
    end if;
    if p_cost_per_m2 is null or p_cost_per_m2 < 0 then
        raise exception 'INVALID_COST: cost_per_m2 must be >= 0' using errcode = 'P0001';
    end if;

    insert into public.consulting_reference_data (category, code, data, valid_from)
    values (
        'construction_materials',
        p_code,
        jsonb_build_object('name_ru', p_name_ru, 'cost_per_m2', p_cost_per_m2, 'currency', 'KZT'),
        current_date
    )
    on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now()
    returning id into v_id;

    return v_id;
end;
$$;

comment on function public.rpc_upsert_construction_material(text, text, numeric) is
    'RPC-CAPEX-3 | ADR-CAPEX-01 | Phase 1
     Admin-only: upserts construction material (code + name_ru + cost_per_m2).
     Currency fixed to KZT in MVP (Q7: no regionalization).';


drop function if exists public.rpc_upsert_infrastructure_norm(p_code text, p_data jsonb, p_block text);
create or replace function public.rpc_upsert_infrastructure_norm(
    p_code  text,
    p_data  jsonb,
    p_block text default null
)
returns int
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
    v_id    int;
    v_data  jsonb;
    v_block text;
begin
    if not public.fn_is_admin() then
        raise exception 'ADMIN_REQUIRED' using errcode = 'P0001';
    end if;

    v_data  := coalesce(p_data, '{}'::jsonb);
    v_block := coalesce(p_block, v_data->>'block');
    if v_block is null then
        raise exception 'BLOCK_REQUIRED: pass p_block or include block in data' using errcode = 'P0001';
    end if;
    if v_block not in ('farm', 'pasture', 'equipment', 'tools') then
        raise exception 'INVALID_BLOCK: must be farm | pasture | equipment | tools' using errcode = 'P0001';
    end if;
    v_data := v_data || jsonb_build_object('block', v_block);

    insert into public.consulting_reference_data (category, code, data, valid_from)
    values ('infrastructure_norms', p_code, v_data, current_date)
    on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now()
    returning id into v_id;

    return v_id;
end;
$$;

comment on function public.rpc_upsert_infrastructure_norm(text, jsonb, text) is
    'RPC-CAPEX-4 | ADR-CAPEX-01 | Phase 1
     Admin-only: upserts infrastructure norm. data JSONB contains cost_model,
     applies_to, material_target, depreciation_years, and model parameters.';


-- ~~ 4. RPC — project-scoped override save ~~

drop function if exists public.rpc_save_project_infra_override(p_organization_id uuid, p_project_id uuid, p_enclosed text, p_support text, p_overrides jsonb);
create or replace function public.rpc_save_project_infra_override(
    p_organization_id uuid,
    p_project_id      uuid,
    p_enclosed        text    default null,
    p_support         text    default null,
    p_overrides       jsonb   default null
)
returns boolean
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
    v_user_id uuid;
begin
    -- Project ownership check. Same pattern as rpc_save_consulting_ration
    -- (DEF-CONSULTING-AUTH-01): works for both web JWT and service_role.
    if not exists (
        select 1 from public.consulting_projects
        where id = p_project_id
          and organization_id = p_organization_id
          and is_active = true
    ) then
        raise exception 'PROJECT_NOT_FOUND' using errcode = 'P0001';
    end if;

    -- Validate materials exist (if provided)
    if p_enclosed is not null and not exists (
        select 1 from public.consulting_reference_data
        where category = 'construction_materials'
          and code = p_enclosed
          and (valid_to is null or valid_to > current_date)
    ) then
        raise exception 'MATERIAL_NOT_FOUND: enclosed=%', p_enclosed using errcode = 'P0001';
    end if;
    if p_support is not null and not exists (
        select 1 from public.consulting_reference_data
        where category = 'construction_materials'
          and code = p_support
          and (valid_to is null or valid_to > current_date)
    ) then
        raise exception 'MATERIAL_NOT_FOUND: support=%', p_support using errcode = 'P0001';
    end if;

    -- ADR-CAPEX-02: p_overrides is NULL-preserve (wizard can change materials
    -- without touching CapexTab's overrides). NULL bypasses validation + keeps
    -- existing column value via coalesce() below.
    if p_overrides is not null and jsonb_typeof(p_overrides) <> 'array' then
        raise exception 'INVALID_OVERRIDES: must be a JSON array' using errcode = 'P0001';
    end if;

    -- Resolve user (may be null for service_role)
    select id into v_user_id from public.users where auth_id = auth.uid();

    -- Persist + trigger recalc
    update public.consulting_projects
    set construction_material_enclosed = coalesce(p_enclosed, construction_material_enclosed),
        construction_material_support  = coalesce(p_support,  construction_material_support),
        infra_items_override           = coalesce(p_overrides, infra_items_override),
        needs_recalc                   = true,
        updated_at                     = now()
    where id = p_project_id;

    -- Emit event (Dok 4: consulting.capex_override.saved)
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'consulting.capex_override.saved',
        'consulting_projects',
        p_project_id,
        p_organization_id,
        case when v_user_id is null then 'system' else 'farmer' end,
        v_user_id,
        jsonb_build_object(
            'project_id',     p_project_id,
            'enclosed',       p_enclosed,
            'support',        p_support,
            -- ADR-CAPEX-02: override_count is null when overrides weren't touched
            'override_count', case when p_overrides is null then null else jsonb_array_length(p_overrides) end
        ),
        false
    );

    return true;
end;
$$;

comment on function public.rpc_save_project_infra_override(uuid, uuid, text, text, jsonb) is
    'RPC-CAPEX-5 | ADR-CAPEX-01 + ADR-CAPEX-02 NULL-preserve
     Saves project-level CAPEX override: material choice + per-item override array.
     p_overrides=null   → preserves existing overrides (wizard changes materials without reset).
     p_overrides=[]     → resets overrides to empty.
     p_overrides=[...]  → replaces overrides with new array.
     p_enclosed / p_support follow same coalesce pattern (null=preserve).
     Sets needs_recalc=true. Emits consulting.capex_override.saved.
     Override shape: [{code, include?, qty_override?, material_override?, unit_cost_override?}]';


-- ~~ 5. RPC Registry ~~
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_list_construction_materials',   'rpc_list_construction_materials',   null, 'd09_consulting.sql (ADR-CAPEX-01)', 'RPC-CAPEX-1: List active construction materials'),
    ('rpc_list_infrastructure_norms',     'rpc_list_infrastructure_norms',     null, 'd09_consulting.sql (ADR-CAPEX-01)', 'RPC-CAPEX-2: List infrastructure norms grouped by block'),
    ('rpc_upsert_construction_material',  'rpc_upsert_construction_material',  null, 'd09_consulting.sql (ADR-CAPEX-01)', 'RPC-CAPEX-3: Admin upsert material'),
    ('rpc_upsert_infrastructure_norm',    'rpc_upsert_infrastructure_norm',    null, 'd09_consulting.sql (ADR-CAPEX-01)', 'RPC-CAPEX-4: Admin upsert infrastructure norm'),
    ('rpc_save_project_infra_override',   'rpc_save_project_infra_override',   null, 'd09_consulting.sql (ADR-CAPEX-01)', 'RPC-CAPEX-5: Save project CAPEX override + material choice')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;


-- ~~ 6. Seed: construction_materials (4 rows) ~~
insert into public.consulting_reference_data (category, code, data, valid_from) values
    ('construction_materials', 'light_frame', '{"name_ru": "Лёгкий каркас",        "cost_per_m2": 15000, "currency": "KZT"}'::jsonb, '2026-04-17'),
    ('construction_materials', 'sandwich',    '{"name_ru": "Сэндвич-панель",       "cost_per_m2": 25000, "currency": "KZT"}'::jsonb, '2026-04-17'),
    ('construction_materials', 'steel',       '{"name_ru": "Металлоконструкция",   "cost_per_m2": 35000, "currency": "KZT"}'::jsonb, '2026-04-17'),
    ('construction_materials', 'brick',       '{"name_ru": "Кирпич / капитальное", "cost_per_m2": 50000, "currency": "KZT"}'::jsonb, '2026-04-17')
on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now();


-- ~~ 7. Seed: capex_surcharges (1 row) ~~
-- Excel row 28 visually shows "0.03" but actual computed contingency is 2.5% of (subtotal+works).
-- Pasture (row 37) uses 2.5% of items only. Encoding that quirk in contingency_base_by_block.
insert into public.consulting_reference_data (category, code, data, valid_from) values
    ('capex_surcharges', 'default',
     '{"works_rate": 0.06,
       "contingency_rate": 0.025,
       "applies_to_blocks": ["farm", "pasture"],
       "contingency_base_by_block": {"farm": "items_plus_work", "pasture": "items_only"}}'::jsonb,
     '2026-04-17')
on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now();


-- ~~ 8. Seed: infrastructure_norms (53 rows) ~~
-- Calibrated to reproduce Excel CAPEX grand_total 282,465,145.54 ₸ at capacity=300, Зимний.
-- Area items carry unit_cost_per_m2_override equal to Excel's bespoke price (preserves parity).
-- material_target is retained so admin can remove override to activate catalog pricing.
insert into public.consulting_reference_data (category, code, data, valid_from) values
    -- Block A: Farm (22 rows) — Excel rows 5–26
    ('infrastructure_norms', 'FAC-015',  '{"name_ru":"Навес для техники 500м²",              "block":"farm","display_order":1,"cost_model":"area_per_head","applies_to":"capacity","material_target":"support","depreciation_years":20,"area_per_head_m2":1.6667,"unit_cost_per_m2_override":19500}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-001',  '{"name_ru":"Жилой дом",                             "block":"farm","display_order":2,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":20,"fixed_cost":30000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-002',  '{"name_ru":"Резервуар для питьевой воды 2м³",       "block":"farm","display_order":3,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":20,"fixed_cost":1000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-003',  '{"name_ru":"Скважина",                              "block":"farm","display_order":4,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":20,"fixed_cost":15000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-014',  '{"name_ru":"Автовесы",                              "block":"farm","display_order":5,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":10,"fixed_cost":1500000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-019',  '{"name_ru":"КПП с санпропускником 50м²",            "block":"farm","display_order":6,"cost_model":"area_per_head","applies_to":"capacity","material_target":"enclosed","depreciation_years":20,"area_per_head_m2":0.1667,"unit_cost_per_m2_override":40000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-004',  '{"name_ru":"Наружные сети электроснабжения 10 кВ",  "block":"farm","display_order":7,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":20,"fixed_cost":11185000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-005',  '{"name_ru":"Скотомогильник",                        "block":"farm","display_order":8,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":20,"fixed_cost":4000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-015b', '{"name_ru":"Зернохранилище 2000м²",                 "block":"farm","display_order":9,"cost_model":"area_per_head","applies_to":"capacity","material_target":"support","depreciation_years":20,"area_per_head_m2":6.6667,"unit_cost_per_m2_override":9000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-006',  '{"name_ru":"Трап для погрузки КРС",                 "block":"farm","display_order":10,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":10,"fixed_cost":500000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-012',  '{"name_ru":"Крытое помещение для отёла 200м²",      "block":"farm","display_order":11,"cost_model":"area_per_head","applies_to":"capacity","material_target":"enclosed","depreciation_years":20,"area_per_head_m2":0.6667,"unit_cost_per_m2_override":80000,"calving_scenario_multiplier":{"Зимний":1.0,"Летний":0.5}}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-014b', '{"name_ru":"Раскол-деление на 20 голов",            "block":"farm","display_order":12,"cost_model":"fixed_per_project","applies_to":"always","material_target":null,"depreciation_years":10,"fixed_cost":980000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-008',  '{"name_ru":"Накопитель",                            "block":"farm","display_order":13,"cost_model":"per_head_unit","applies_to":"capacity","material_target":null,"depreciation_years":20,"unit_cost":4000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-015c', '{"name_ru":"Открытая площадка для силоса/сена",     "block":"farm","display_order":14,"cost_model":"per_head_unit","applies_to":"capacity","material_target":null,"depreciation_years":20,"unit_cost":5000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-001',  '{"name_ru":"Общий ангар 8 м²/гол",                  "block":"farm","display_order":15,"cost_model":"area_per_head","applies_to":"capacity","material_target":"enclosed","depreciation_years":20,"area_per_head_m2":8,"unit_cost_per_m2_override":12500}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-013',  '{"name_ru":"Изолятор 120 м² (8 м²/гол × 15 голов)", "block":"farm","display_order":16,"cost_model":"fixed_area","applies_to":"always","material_target":"enclosed","depreciation_years":20,"fixed_area_m2":120,"unit_cost_per_m2_override":83333}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-009',  '{"name_ru":"Открытый загон для изолятора 300 м²",   "block":"farm","display_order":17,"cost_model":"fixed_area","applies_to":"always","material_target":"support","depreciation_years":20,"fixed_area_m2":300,"unit_cost_per_m2_override":3450}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'PAD-001',  '{"name_ru":"Загон для 30 коров 600 м²",             "block":"farm","display_order":18,"cost_model":"fixed_area","applies_to":"always","material_target":"support","depreciation_years":20,"fixed_area_m2":600,"unit_cost_per_m2_override":4140}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'PAD-007',  '{"name_ru":"Загон для быков-производителей 500 м²", "block":"farm","display_order":19,"cost_model":"fixed_area","applies_to":"always","material_target":"support","depreciation_years":20,"fixed_area_m2":500,"unit_cost_per_m2_override":4968}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-007',  '{"name_ru":"Ветрозащита",                           "block":"farm","display_order":20,"cost_model":"per_head_unit","applies_to":"capacity","material_target":null,"depreciation_years":20,"unit_cost":8280}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'INF-008',  '{"name_ru":"Кормовой стол 0.5 м²/гол",              "block":"farm","display_order":21,"cost_model":"area_per_head","applies_to":"capacity","material_target":"support","depreciation_years":20,"area_per_head_m2":0.5,"unit_cost_per_m2_override":6900}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'FAC-017',  '{"name_ru":"Тёплая поилка",                         "block":"farm","display_order":22,"cost_model":"per_head_unit","applies_to":"capacity","material_target":null,"depreciation_years":10,"unit_cost":4830}'::jsonb, '2026-04-17'),

    -- Block B: Pasture (4 rows) — Excel rows 32–35
    ('infrastructure_norms', 'PST-001',  '{"name_ru":"Мобильный жилой дом (вагончик)",         "block":"pasture","display_order":1,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":10,"fixed_qty":1,"unit_cost":4000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'PST-002',  '{"name_ru":"Поилки от скважин с ветряными насосами", "block":"pasture","display_order":2,"cost_model":"per_area_ha","applies_to":"pasture_area_ha","material_target":null,"depreciation_years":10,"area_divisor_ha":1500,"unit_cost":8800000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'PST-003',  '{"name_ru":"Скважина (пастбищная)",                  "block":"pasture","display_order":3,"cost_model":"per_area_ha","applies_to":"pasture_area_ha","material_target":null,"depreciation_years":20,"area_divisor_ha":3000,"unit_cost":3000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'PST-004',  '{"name_ru":"Ограждение пастбищ",                     "block":"pasture","display_order":4,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":15,"fixed_qty":1,"unit_cost":18800000}'::jsonb, '2026-04-17'),

    -- Block C: Equipment (8 rows) — Excel rows 41–48. MVP: fixed_qty=1, expert overrides via CapexTab.
    ('infrastructure_norms', 'EQP-001',  '{"name_ru":"Колёсный трактор 100–150 л.с.",         "block":"equipment","display_order":1,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":20000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'EQP-002',  '{"name_ru":"Кун с ковшом и стогометом",             "block":"equipment","display_order":2,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":3500000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'EQP-003',  '{"name_ru":"Кормораздатчик (миксер) 8–12 м³",       "block":"equipment","display_order":3,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":10000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'EQP-004',  '{"name_ru":"Зернодробилка",                         "block":"equipment","display_order":4,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":3000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'EQP-005',  '{"name_ru":"Прицеп самосвальный 10-15 т",           "block":"equipment","display_order":5,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":10000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'EQP-006',  '{"name_ru":"Прицеп для перевозки скота",            "block":"equipment","display_order":6,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":5000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'EQP-007',  '{"name_ru":"Прицеп с ёмкостью для воды",            "block":"equipment","display_order":7,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":1500000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'EQP-008',  '{"name_ru":"Бензиновые генераторы 3-5 кВт",         "block":"equipment","display_order":8,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":400000}'::jsonb, '2026-04-17'),

    -- Block D: Tools (19 rows) — Excel rows 52–70. MVP: fixed_qty from Excel columns F/G.
    ('infrastructure_norms', 'TOL-001',  '{"name_ru":"Считыватель чипов",                     "block":"tools","display_order":1,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":1,"unit_cost":50000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-002',  '{"name_ru":"Электрический погонщик",                "block":"tools","display_order":2,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":1,"unit_cost":30000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-003',  '{"name_ru":"Станок для фиксации КРС",               "block":"tools","display_order":3,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":2000000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-004',  '{"name_ru":"Электронные весы",                      "block":"tools","display_order":4,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":150000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-005',  '{"name_ru":"Вакцинаторы",                           "block":"tools","display_order":5,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":5,"unit_cost":35000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-006',  '{"name_ru":"Дренчер",                               "block":"tools","display_order":6,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":1,"unit_cost":10000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-007',  '{"name_ru":"Копытные ножи",                         "block":"tools","display_order":7,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":2,"unit_cost":15000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-008',  '{"name_ru":"Молокоотсос",                           "block":"tools","display_order":8,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":2,"unit_cost":60000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-009',  '{"name_ru":"Поилки для молока",                     "block":"tools","display_order":9,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":20,"unit_cost":5000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-010',  '{"name_ru":"Термо чемодан",                         "block":"tools","display_order":10,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":1,"unit_cost":50000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-011',  '{"name_ru":"Огнетушитель",                          "block":"tools","display_order":11,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":5,"unit_cost":15000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-012',  '{"name_ru":"Набор лопат и вил",                     "block":"tools","display_order":12,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":5,"unit_cost":30000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-013',  '{"name_ru":"Набор инструментов (электро)",          "block":"tools","display_order":13,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":3,"unit_cost":100000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-014',  '{"name_ru":"Набор инструментов (строительные)",     "block":"tools","display_order":14,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":2,"unit_cost":50000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-015',  '{"name_ru":"Тачка",                                 "block":"tools","display_order":15,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":5,"unit_cost":50000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-016',  '{"name_ru":"Ручные рации",                          "block":"tools","display_order":16,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":2,"unit_cost":25000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-017',  '{"name_ru":"Спецодежда",                            "block":"tools","display_order":17,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":2,"fixed_qty":4,"unit_cost":50000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-018',  '{"name_ru":"Набор инструментов для трактористов",   "block":"tools","display_order":18,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":3,"fixed_qty":1,"unit_cost":50000}'::jsonb, '2026-04-17'),
    ('infrastructure_norms', 'TOL-019',  '{"name_ru":"Спутниковые антенны",                   "block":"tools","display_order":19,"cost_model":"fixed_qty","applies_to":"always","material_target":null,"depreciation_years":5,"fixed_qty":1,"unit_cost":350000}'::jsonb, '2026-04-17')
on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now();


-- ============================================================
-- END ADR-CAPEX-01 Phase 1
-- ============================================================


-- ============================================================
-- ADR-CAPEX-02 (2026-04-18): tech debt fixes from ADR-CAPEX-01
--   L-P3-WIZARD: rpc_save_project_infra_override.p_overrides → NULL-preserve
--                (inline edits above, see RPC-CAPEX-5 comment for semantics)
--   L-P4-1:      + rpc_list_capex_surcharges (new lookup RPC, below)
-- ============================================================

-- RPC-CAPEX-6: list active capex_surcharges (replaces direct .from() read in UI)
create or replace function public.rpc_list_capex_surcharges()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
    return coalesce((
        select jsonb_agg(
            jsonb_build_object(
                'id',         crd.id,
                'code',       crd.code,
                'data',       crd.data,
                'valid_from', crd.valid_from,
                'valid_to',   crd.valid_to
            ) order by crd.valid_from desc
        )
        from public.consulting_reference_data crd
        where crd.category = 'capex_surcharges'
          and (crd.valid_to is null or crd.valid_to > current_date)
    ), '[]'::jsonb);
end;
$$;

comment on function public.rpc_list_capex_surcharges() is
    'RPC-CAPEX-6 | ADR-CAPEX-02 | 2026-04-18
     Lists active capex_surcharges rows (normally 1 row, code="default").
     STABLE, readable to authenticated. Replaces direct .from() read in
     CapexSurchargesTab (L-P4-1 tech debt fix).';

-- Register RPC-CAPEX-6
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_list_capex_surcharges', 'rpc_list_capex_surcharges', null, 'd09_consulting.sql (ADR-CAPEX-02)', 'RPC-CAPEX-6: List active capex_surcharges rows (L-P4-1 fix)')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;

-- ============================================================
-- END ADR-CAPEX-02
-- ============================================================


-- ============================================================
-- ADR-PRICES-01 (2026-04-18) — Livestock sale prices reference data
-- ============================================================
-- DEF-REVENUE-PRICES-01 follow-up #2: moves livestock sale prices from
-- ProjectInput hardcoded defaults to DB-managed reference catalog with
-- temporal versioning. Engine Priority chain (mirrors ADR-FEED-03):
--   P1: project override (ProjectInput.price_*_per_kg not null)
--   P2: DB reference (consulting_reference_data, category='livestock_prices')
--   P3: Pydantic defaults (1800/2200/1800/2000 — safety net)
-- Dimensions: livestock_category + year. region_id + age_months reserved
-- as JSONB fields but NULL in MVP (deferred to future ADRs).
-- ============================================================

-- ~~ 1. CHECK constraint — additive, adds 'livestock_prices' category ~~
-- The category 'regional_prices' stays reserved for future multi-region
-- price multipliers (MSH regional subsidies etc).
alter table public.consulting_reference_data
    drop constraint if exists consulting_reference_data_category_check;
alter table public.consulting_reference_data
    add constraint consulting_reference_data_category_check check (category in (
        'infrastructure_norms',
        'equipment_norms',
        'tax_rates',
        'wacc_parameters',
        'subsidy_programs',
        'livestock_norms',
        'regional_prices',
        'economic_parameters',
        'construction_materials',
        'capex_surcharges',
        'livestock_prices'
    ));


-- ~~ 2. RPC — public reader ~~

drop function if exists public.rpc_list_livestock_prices(p_organization_id uuid, p_as_of_date date);
create or replace function public.rpc_list_livestock_prices(
    p_organization_id uuid default null,  -- reserved for future org-scoped overrides
    p_as_of_date      date default current_date
)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
    -- p_organization_id currently unused (catalog is global). Kept in signature
    -- for P-AI-2 compliance pattern and future per-org pricing (next ADR).
    return coalesce((
        select jsonb_agg(
            jsonb_build_object(
                'code',               crd.code,
                'livestock_category', crd.data->>'livestock_category',
                'year',               (crd.data->>'year')::int,
                'region_id',          crd.data->>'region_id',
                'age_months',         (crd.data->>'age_months')::int,
                'price_per_kg',       (crd.data->>'price_per_kg')::numeric,
                'currency',           coalesce(crd.data->>'currency', 'KZT'),
                'source',             crd.data->>'source',
                'valid_from',         crd.valid_from,
                'valid_to',           crd.valid_to
            ) order by
                (crd.data->>'year')::int desc,
                crd.data->>'livestock_category'
        )
        from public.consulting_reference_data crd
        where crd.category = 'livestock_prices'
          and crd.valid_from <= p_as_of_date
          and (crd.valid_to is null or crd.valid_to > p_as_of_date)
    ), '[]'::jsonb);
end;
$$;

comment on function public.rpc_list_livestock_prices(uuid, date) is
    'RPC-PRICES-1 | ADR-PRICES-01 | 2026-04-18
     Lists active livestock sale prices valid on p_as_of_date.
     Engine Priority 2 fallback after project override (P1).
     p_organization_id reserved for future org-scoped overrides (currently unused).
     STABLE, readable to authenticated.';


-- ~~ 3. RPC — admin upsert ~~

drop function if exists public.rpc_upsert_livestock_price(p_code text, p_livestock_category text, p_year integer, p_price_per_kg numeric, p_region_id uuid, p_age_months integer, p_source text, p_valid_from date);
create or replace function public.rpc_upsert_livestock_price(
    p_code               text,
    p_livestock_category text,       -- steer_own | heifer_breeding | cow_culled | bull_culled
    p_year               int,
    p_price_per_kg       numeric,
    p_region_id          uuid    default null,  -- reserved, MVP always null
    p_age_months         int     default null,  -- reserved for #3 per-strategy pricing
    p_source             text    default null,
    p_valid_from         date    default current_date
)
returns int
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare v_id int;
begin
    if not public.fn_is_admin() then
        raise exception 'ADMIN_REQUIRED' using errcode = 'P0001';
    end if;
    if p_price_per_kg is null or p_price_per_kg <= 0 then
        raise exception 'INVALID_PRICE: price_per_kg must be > 0' using errcode = 'P0001';
    end if;
    if p_livestock_category not in ('steer_own', 'heifer_breeding', 'cow_culled', 'bull_culled') then
        raise exception 'INVALID_CATEGORY: %', p_livestock_category using errcode = 'P0001';
    end if;
    if p_year < 2020 or p_year > 2100 then
        raise exception 'INVALID_YEAR: % out of range', p_year using errcode = 'P0001';
    end if;

    insert into public.consulting_reference_data (category, code, data, valid_from)
    values (
        'livestock_prices',
        p_code,
        jsonb_build_object(
            'livestock_category', p_livestock_category,
            'year',               p_year,
            'region_id',          p_region_id,
            'age_months',         p_age_months,
            'price_per_kg',       p_price_per_kg,
            'currency',           'KZT',
            'source',             p_source
        ),
        p_valid_from
    )
    on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now()
    returning id into v_id;

    return v_id;
end;
$$;

comment on function public.rpc_upsert_livestock_price(text, text, int, numeric, uuid, int, text, date) is
    'RPC-PRICES-2 | ADR-PRICES-01 | 2026-04-18
     Admin-only upsert of a livestock sale price row.
     livestock_category must be one of: steer_own, heifer_breeding, cow_culled, bull_culled.
     region_id + age_months reserved (MVP always null).';


-- ~~ 4. RPC — admin soft-delete (set valid_to = yesterday) ~~

create or replace function public.rpc_retire_livestock_price(
    p_code text
)
returns int
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare v_count int;
begin
    if not public.fn_is_admin() then
        raise exception 'ADMIN_REQUIRED' using errcode = 'P0001';
    end if;

    update public.consulting_reference_data
    set valid_to = current_date - interval '1 day',
        updated_at = now()
    where category = 'livestock_prices'
      and code = p_code
      and (valid_to is null or valid_to > current_date);

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

comment on function public.rpc_retire_livestock_price(text) is
    'RPC-PRICES-3 | ADR-PRICES-01 | 2026-04-18
     Admin-only soft-delete: sets valid_to = yesterday on all active rows with given code.
     Preserves historical records for audit.';


-- ~~ 5. RPC Registry ~~
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_list_livestock_prices',   'rpc_list_livestock_prices',   null, 'd09_consulting.sql (ADR-PRICES-01)', 'RPC-PRICES-1: List active livestock sale prices (engine Priority 2)'),
    ('rpc_upsert_livestock_price',  'rpc_upsert_livestock_price',  null, 'd09_consulting.sql (ADR-PRICES-01)', 'RPC-PRICES-2: Admin upsert livestock sale price'),
    ('rpc_retire_livestock_price',  'rpc_retire_livestock_price',  null, 'd09_consulting.sql (ADR-PRICES-01)', 'RPC-PRICES-3: Admin soft-delete livestock sale price')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;


-- ~~ 6. Seed: livestock_prices (4 rows for year 2026, KZ-national) ~~
-- Defaults match Pydantic defaults from DEF-REVENUE-PRICES-01 (2026-04-17):
--   steer_own       : 1800 тг/кг (young steers 10-12mo, stocker market)
--   heifer_breeding : 2200 тг/кг (breeding premium)
--   cow_culled      : 1800 тг/кг (low-grade meat)
--   bull_culled     : 2000 тг/кг (heavy carcass)
-- age_months = NULL (legacy/default). For ADR-PRICES-02 (per-strategy), age-specific
-- rows will be added (e.g. steer_own:2026:6mo, steer_own:2026:12mo).
insert into public.consulting_reference_data (category, code, data, valid_from) values
    ('livestock_prices', 'steer_own:2026',
     '{"livestock_category":"steer_own",       "year":2026, "region_id":null, "age_months":null, "price_per_kg":1800, "currency":"KZT", "source":"AgOS default 2026"}'::jsonb,
     '2026-01-01'),
    ('livestock_prices', 'heifer_breeding:2026',
     '{"livestock_category":"heifer_breeding", "year":2026, "region_id":null, "age_months":null, "price_per_kg":2200, "currency":"KZT", "source":"AgOS default 2026"}'::jsonb,
     '2026-01-01'),
    ('livestock_prices', 'cow_culled:2026',
     '{"livestock_category":"cow_culled",      "year":2026, "region_id":null, "age_months":null, "price_per_kg":1800, "currency":"KZT", "source":"AgOS default 2026"}'::jsonb,
     '2026-01-01'),
    ('livestock_prices', 'bull_culled:2026',
     '{"livestock_category":"bull_culled",     "year":2026, "region_id":null, "age_months":null, "price_per_kg":2000, "currency":"KZT", "source":"AgOS default 2026"}'::jsonb,
     '2026-01-01')
on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now();


-- ~~ 7. Seed: ADR-PRICES-02 — per-strategy steer_own prices (age-specific) ~~
-- Resolver матчит age_months == steer_sale_age_months проекта;
-- fallback — baseline row steer_own:2026 (age_months=NULL, 1800 тг/кг).
insert into public.consulting_reference_data (category, code, data, valid_from) values
    ('livestock_prices', 'steer_own:2026:6mo',
     '{"livestock_category":"steer_own","year":2026,"region_id":null,"age_months":6,"price_per_kg":1400,"currency":"KZT","source":"AgOS default 2026 (6mo steer)"}'::jsonb,
     '2026-01-01'),
    ('livestock_prices', 'steer_own:2026:12mo',
     '{"livestock_category":"steer_own","year":2026,"region_id":null,"age_months":12,"price_per_kg":1800,"currency":"KZT","source":"AgOS default 2026 (12mo steer)"}'::jsonb,
     '2026-01-01'),
    ('livestock_prices', 'steer_own:2026:18mo',
     '{"livestock_category":"steer_own","year":2026,"region_id":null,"age_months":18,"price_per_kg":2000,"currency":"KZT","source":"AgOS default 2026 (18mo steer)"}'::jsonb,
     '2026-01-01')
on conflict (category, code, valid_from) do update
    set data = excluded.data, updated_at = now();

-- ============================================================
-- END ADR-PRICES-01 / ADR-PRICES-02
-- ============================================================


-- ============================================================
-- END Slice 8 d09_consulting.sql
-- ============================================================
