-- AgOS · Админ видит и меняет область (region_id) организации.
-- При изменении region_id хозяйства последующие партии фермера публикуются уже
-- с нового местоположения — rpc_create_batch дофолбэчивает регион партии на
-- organizations.region_id, так что менять batch-логику не нужно.
--
-- Изменения:
--   1. rpc_admin_list_organizations — в выдачу добавлены region_id + region_name.
--   2. rpc_admin_update_organization — новый параметр p_region_id (меняет область).
--   3. rpc_admin_create_organization — новый параметр p_region_id (опционально).
-- Аддитивно/идемпотентно. Применять: Supabase Dashboard → SQL Editor.

-- ------------------------------------------------------------
-- 1. Список организаций + область (region_id / region_name)
--    Return-type меняется (новые out-колонки) → сначала дропаем старую версию.
-- ------------------------------------------------------------
drop function if exists public.rpc_admin_list_organizations(text);

create or replace function public.rpc_admin_list_organizations(p_search text default null)
returns table (
    id            uuid,
    legal_name    text,
    bin_iin       text,
    legal_form    text,
    phone         text,
    email         text,
    address_text  text,
    is_active     boolean,
    created_at    timestamptz,
    region_id     uuid,
    region_name   text,
    org_types     text[],
    member_count  bigint
)
language sql
security definer
set search_path = public, pg_temp
as $$
    select
        o.id, o.legal_name, o.bin_iin, o.legal_form, o.phone, o.email,
        o.address_text, o.is_active, o.created_at,
        o.region_id,
        rg.name_ru as region_name,
        coalesce(array_agg(distinct t.org_type) filter (where t.org_type is not null), '{}') as org_types,
        (select count(*) from public.user_organization_roles r where r.organization_id = o.id) as member_count
    from public.organizations o
    left join public.organization_type_assignments t on t.organization_id = o.id
    left join public.regions rg on rg.id = o.region_id
    where public.fn_is_admin()
      and (
        p_search is null or p_search = ''
        or o.legal_name ilike '%' || p_search || '%'
        or o.bin_iin    ilike '%' || p_search || '%'
        or o.phone      ilike '%' || p_search || '%'
      )
    group by o.id, rg.name_ru
    order by o.created_at desc
    limit 200;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_list_organizations', null, '20260701130000_admin_org_region.sql', 'Admin lists organizations with types, member count and region')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ------------------------------------------------------------
-- 2. Обновление реквизитов + области организации
--    Сигнатура меняется (новый параметр) → дропаем старую версию.
--    p_region_id: null = не трогать; иначе выставить новую область.
-- ------------------------------------------------------------
drop function if exists public.rpc_admin_update_organization(uuid, text, text, text, text, text, text, boolean);

create or replace function public.rpc_admin_update_organization(
    p_org_id      uuid,
    p_legal_name  text default null,
    p_bin_iin     text default null,
    p_phone       text default null,
    p_email       text default null,
    p_address     text default null,
    p_legal_form  text default null,
    p_is_active   boolean default null,
    p_region_id   uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_old_region uuid;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;
    select region_id into v_old_region from public.organizations where id = p_org_id;
    if not found then
        raise exception 'ORG_NOT_FOUND: %', p_org_id using errcode = 'P0001';
    end if;
    if p_region_id is not null and not exists (select 1 from public.regions where id = p_region_id) then
        raise exception 'REGION_NOT_FOUND: %', p_region_id using errcode = 'P0001';
    end if;

    update public.organizations set
        legal_name   = coalesce(nullif(trim(p_legal_name), ''), legal_name),
        bin_iin      = case when p_bin_iin   is null then bin_iin      else nullif(trim(p_bin_iin), '')   end,
        phone        = case when p_phone     is null then phone        else nullif(trim(p_phone), '')     end,
        email        = case when p_email     is null then email        else nullif(trim(p_email), '')     end,
        address_text = case when p_address   is null then address_text else nullif(trim(p_address), '')   end,
        legal_form   = case when p_legal_form is null then legal_form   else nullif(trim(p_legal_form), '') end,
        is_active    = coalesce(p_is_active, is_active),
        region_id    = coalesce(p_region_id, region_id),
        updated_at   = now()
    where id = p_org_id;

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.org.updated', 'organizations', p_org_id, p_org_id, 'admin', public.fn_current_user_id(),
         jsonb_build_object(
             'org_id', p_org_id,
             'region_from', v_old_region,
             'region_to', coalesce(p_region_id, v_old_region)
         ), true);
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_update_organization', null, '20260701130000_admin_org_region.sql', 'Admin updates organization details incl. region')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ------------------------------------------------------------
-- 3. Создание организации + область (опционально)
--    Добавлен параметр p_region_id в конец → CREATE OR REPLACE достаточно.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_create_organization(
    p_legal_name  text,
    p_org_type    text default 'farmer',            -- farmer|mpk|supplier|consultant|other
    p_bin_iin     text default null,
    p_phone       text default null,
    p_email       text default null,
    p_address     text default null,
    p_legal_form  text default null,
    p_region_id   uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_org_id uuid;
    v_name   text := nullif(trim(p_legal_name), '');
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;
    if v_name is null then
        raise exception 'NAME_REQUIRED: название обязательно' using errcode = 'P0001';
    end if;
    if p_org_type not in ('farmer', 'mpk', 'supplier', 'consultant', 'other') then
        raise exception 'INVALID_ORG_TYPE: %', p_org_type using errcode = 'P0001';
    end if;
    if p_region_id is not null and not exists (select 1 from public.regions where id = p_region_id) then
        raise exception 'REGION_NOT_FOUND: %', p_region_id using errcode = 'P0001';
    end if;

    insert into public.organizations (legal_name, bin_iin, legal_form, phone, email, address_text, region_id)
    values (v_name, nullif(trim(p_bin_iin), ''), nullif(trim(p_legal_form), ''),
            nullif(trim(p_phone), ''), nullif(trim(p_email), ''), nullif(trim(p_address), ''), p_region_id)
    returning id into v_org_id;

    insert into public.organization_type_assignments (organization_id, org_type, assigned_by)
    values (v_org_id, p_org_type, public.fn_current_user_id());

    insert into public.memberships (organization_id, org_type, level)
    values (v_org_id, p_org_type, 'registered');

    if p_org_type = 'farmer' then
        insert into public.farms (organization_id, name, is_primary, data_source)
        values (v_org_id, v_name || ' — ферма', true, 'platform');
    end if;

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.org.created', 'organizations', v_org_id, v_org_id, 'admin', public.fn_current_user_id(),
         jsonb_build_object('legal_name', v_name, 'org_type', p_org_type, 'region_id', p_region_id), true);

    return v_org_id;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_create_organization', null, '20260701130000_admin_org_region.sql', 'Admin creates organization (no user required) incl. region')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;
