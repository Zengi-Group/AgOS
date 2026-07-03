-- AgOS · Управление организациями админом + привязка нового пользователя к
-- СУЩЕСТВУЮЩЕЙ организации (без создания новой при заведении пользователя).
--
-- Изменения:
--   1. rpc_admin_create_user — теперь принимает p_organization_id (обязателен) и
--      p_role; НЕ создаёт организацию/тип/членство/ферму, только привязывает
--      пользователя к выбранной организации через user_organization_roles.
--   2. rpc_admin_list_organizations — список организаций (для таблицы и для
--      выпадающего списка при создании пользователя), с типами и числом участников.
--   3. rpc_admin_create_organization — создаёт организацию + тип + членство
--      (+ ферму для фермера); пользователь не требуется.
--   4. rpc_admin_update_organization — правка реквизитов.
--   5. rpc_admin_delete_organization — жёсткое удаление (динамический NULL-out
--      nullable-FK на organizations, затем delete → каскад).
-- Аддитивно/идемпотентно. Применять: Supabase Dashboard → SQL Editor.

-- ------------------------------------------------------------
-- 1. Пересоздание rpc_admin_create_user под выбор существующей организации.
--    Сигнатура изменилась → сначала дропаем старую версию.
-- ------------------------------------------------------------
drop function if exists public.rpc_admin_create_user(text, text, text, text, text, text, text);

create or replace function public.rpc_admin_create_user(
    p_phone           text,
    p_pin             text,
    p_organization_id uuid,
    p_role            text default 'owner',          -- owner|manager|employee|viewer
    p_full_name       text default null,
    p_email           text default null,
    p_language        text default 'ru'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    v_uid    uuid := gen_random_uuid();
    v_email  text := nullif(trim(p_email), '');
    v_phone  text := nullif(trim(p_phone), '');
    v_pid    uuid;
    v_is_first boolean;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;
    if v_phone is null then
        raise exception 'PHONE_REQUIRED: телефон обязателен' using errcode = 'P0001';
    end if;
    if p_pin is null or p_pin !~ '^\d{6}$' then
        raise exception 'INVALID_PIN: ПИН-код — ровно 6 цифр' using errcode = 'P0001';
    end if;
    if p_organization_id is null then
        raise exception 'ORG_REQUIRED: организация обязательна' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.organizations where id = p_organization_id) then
        raise exception 'ORG_NOT_FOUND: %', p_organization_id using errcode = 'P0001';
    end if;
    if coalesce(p_role, 'owner') not in ('owner', 'manager', 'employee', 'viewer') then
        raise exception 'INVALID_ROLE: %', p_role using errcode = 'P0001';
    end if;
    if exists (select 1 from auth.users where phone = v_phone) then
        raise exception 'PHONE_EXISTS: %', v_phone using errcode = 'P0001';
    end if;
    if v_email is not null and exists (select 1 from auth.users where email = v_email) then
        raise exception 'EMAIL_EXISTS: %', v_email using errcode = 'P0001';
    end if;

    -- 1. auth.users (ПИН хранится как пароль, bcrypt)
    insert into auth.users (
        instance_id, id, aud, role,
        email, phone, encrypted_password,
        email_confirmed_at, phone_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at
    ) values (
        '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
        v_email, v_phone, extensions.crypt(p_pin, extensions.gen_salt('bf')),
        case when v_email is not null then now() end,
        now(),
        jsonb_build_object('provider', 'phone', 'providers', jsonb_build_array('phone')),
        jsonb_build_object('full_name', p_full_name, 'phone', v_phone, 'preferred_language', coalesce(p_language, 'ru')),
        now(), now()
    );

    -- 2. identities (логин по телефону + email при наличии)
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
    values (gen_random_uuid(), v_uid, v_uid::text, 'phone',
            jsonb_build_object('sub', v_uid::text, 'phone', v_phone), now(), now(), now());
    if v_email is not null then
        insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
        values (gen_random_uuid(), v_uid, v_uid::text, 'email',
                jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true), now(), now(), now());
    end if;

    -- 3. public.users создаётся триггером trg_on_auth_user_created; язык
    update public.users set preferred_language = coalesce(p_language, 'ru') where auth_id = v_uid;
    select id into v_pid from public.users where auth_id = v_uid;

    -- 4. Привязка к ВЫБРАННОЙ организации. is_primary = true, если у пользователя
    --    ещё нет основной организации (первая привязка).
    select not exists (
        select 1 from public.user_organization_roles
        where user_id = v_pid and is_primary
    ) into v_is_first;

    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values (v_pid, p_organization_id, coalesce(p_role, 'owner'), v_is_first)
    on conflict (user_id, organization_id)
        do update set role = excluded.role;

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.user.created', 'users', v_pid, p_organization_id, 'admin', public.fn_current_user_id(),
         jsonb_build_object('phone', v_phone, 'email', v_email, 'role', coalesce(p_role, 'owner')), true);

    return v_pid;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_create_user', null, '20260629140000_admin_org_management.sql', 'Admin creates auth user and attaches to an EXISTING organization')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ------------------------------------------------------------
-- 2. Список организаций (таблица + выпадающий список при создании пользователя)
-- ------------------------------------------------------------
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
        coalesce(array_agg(distinct t.org_type) filter (where t.org_type is not null), '{}') as org_types,
        (select count(*) from public.user_organization_roles r where r.organization_id = o.id) as member_count
    from public.organizations o
    left join public.organization_type_assignments t on t.organization_id = o.id
    where public.fn_is_admin()
      and (
        p_search is null or p_search = ''
        or o.legal_name ilike '%' || p_search || '%'
        or o.bin_iin    ilike '%' || p_search || '%'
        or o.phone      ilike '%' || p_search || '%'
      )
    group by o.id
    order by o.created_at desc
    limit 200;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_list_organizations', null, '20260629140000_admin_org_management.sql', 'Admin lists organizations with types and member count')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ------------------------------------------------------------
-- 3. Создание организации (без пользователя)
-- ------------------------------------------------------------
create or replace function public.rpc_admin_create_organization(
    p_legal_name  text,
    p_org_type    text default 'farmer',            -- farmer|mpk|supplier|consultant|other
    p_bin_iin     text default null,
    p_phone       text default null,
    p_email       text default null,
    p_address     text default null,
    p_legal_form  text default null
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

    insert into public.organizations (legal_name, bin_iin, legal_form, phone, email, address_text)
    values (v_name, nullif(trim(p_bin_iin), ''), nullif(trim(p_legal_form), ''),
            nullif(trim(p_phone), ''), nullif(trim(p_email), ''), nullif(trim(p_address), ''))
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
         jsonb_build_object('legal_name', v_name, 'org_type', p_org_type), true);

    return v_org_id;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_create_organization', null, '20260629140000_admin_org_management.sql', 'Admin creates organization (no user required)')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ------------------------------------------------------------
-- 4. Обновление реквизитов организации
-- ------------------------------------------------------------
create or replace function public.rpc_admin_update_organization(
    p_org_id      uuid,
    p_legal_name  text default null,
    p_bin_iin     text default null,
    p_phone       text default null,
    p_email       text default null,
    p_address     text default null,
    p_legal_form  text default null,
    p_is_active   boolean default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.organizations where id = p_org_id) then
        raise exception 'ORG_NOT_FOUND: %', p_org_id using errcode = 'P0001';
    end if;

    update public.organizations set
        legal_name   = coalesce(nullif(trim(p_legal_name), ''), legal_name),
        bin_iin      = case when p_bin_iin   is null then bin_iin      else nullif(trim(p_bin_iin), '')   end,
        phone        = case when p_phone     is null then phone        else nullif(trim(p_phone), '')     end,
        email        = case when p_email     is null then email        else nullif(trim(p_email), '')     end,
        address_text = case when p_address   is null then address_text else nullif(trim(p_address), '')   end,
        legal_form   = case when p_legal_form is null then legal_form   else nullif(trim(p_legal_form), '') end,
        is_active    = coalesce(p_is_active, is_active),
        updated_at   = now()
    where id = p_org_id;

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.org.updated', 'organizations', p_org_id, p_org_id, 'admin', public.fn_current_user_id(),
         jsonb_build_object('org_id', p_org_id), true);
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_update_organization', null, '20260629140000_admin_org_management.sql', 'Admin updates organization details')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ------------------------------------------------------------
-- 5. Жёсткое удаление организации (необратимо)
--    Динамически обнуляем nullable-FK на organizations, затем delete → каскад
--    снесёт type_assignments, memberships, user_organization_roles, farms и т.п.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_delete_organization(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_info jsonb;
    r      record;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;

    select to_jsonb(o.*) into v_info from public.organizations o where o.id = p_org_id;
    if v_info is null then
        raise exception 'ORG_NOT_FOUND: %', p_org_id using errcode = 'P0001';
    end if;

    -- аудит ДО удаления
    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.org.deleted', 'organizations', p_org_id, null, 'admin', public.fn_current_user_id(),
         jsonb_build_object('deleted', v_info), true);

    -- Обнуляем nullable-FK на organizations (иначе delete упрётся в их FK).
    -- NOT NULL-ссылки уйдут каскадом (on delete cascade) при delete организации.
    for r in
        select c.conrelid::regclass::text as tbl, a.attname as col
        from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
        where c.confrelid = 'public.organizations'::regclass
          and c.contype = 'f'
          and array_length(c.conkey, 1) = 1
          and not a.attnotnull
    loop
        execute format('update %s set %I = null where %I = $1', r.tbl, r.col, r.col)
            using p_org_id;
    end loop;

    delete from public.organizations where id = p_org_id;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_delete_organization', null, '20260629140000_admin_org_management.sql', 'Admin hard-deletes organization (cascade)')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;
