-- AgOS · Создание и удаление пользователей админом без Edge Functions —
-- напрямую через SQL (security definer от роли postgres имеет доступ к auth.*).
--
-- rpc_admin_delete_user — удаляет auth.users → каскад сносит public.users.
-- rpc_admin_create_user — заводит auth.users + auth.identities (пароль через
-- pgcrypto bcrypt); триггер trg_on_auth_user_created создаёт public.users.
-- Аддитивно/идемпотентно. Применять: Supabase Dashboard → SQL Editor.

-- ------------------------------------------------------------
-- Полное удаление пользователя (необратимо)
-- ------------------------------------------------------------
create or replace function public.rpc_admin_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_auth_id uuid;
    v_info    jsonb;
    r         record;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;

    select auth_id, to_jsonb(u.*) into v_auth_id, v_info
    from public.users u where u.id = p_user_id;
    if v_auth_id is null then
        raise exception 'USER_NOT_FOUND: %', p_user_id using errcode = 'P0001';
    end if;

    -- аудит ДО удаления (после каскада строки уже не будет)
    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.user.deleted', 'users', p_user_id, null, 'admin', public.fn_current_user_id(),
         jsonb_build_object('deleted', v_info), true);

    -- Обнуляем все nullable-ссылки на пользователя (audit-поля created_by/assigned_by/
    -- approved_by и т.п.), иначе каскадное удаление профиля упрётся в их FK.
    -- NOT NULL-ссылки (user_id …) уйдут каскадом при удалении auth.users.
    for r in
        select c.conrelid::regclass::text as tbl, a.attname as col
        from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
        where c.confrelid = 'public.users'::regclass
          and c.contype = 'f'
          and array_length(c.conkey, 1) = 1
          and not a.attnotnull
    loop
        execute format('update %s set %I = null where %I = $1', r.tbl, r.col, r.col)
            using p_user_id;
    end loop;

    delete from auth.users where id = v_auth_id;  -- cascade → public.users и NOT NULL-ссылки
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_delete_user', null, '20260629130000_admin_user_create_delete.sql', 'Admin hard-deletes user (auth.users cascade)')
on conflict (sql_name) do update set notes = excluded.notes;

-- ------------------------------------------------------------
-- Создание пользователя с паролем (email и/или телефон)
-- pgcrypto (crypt/gen_salt) в Supabase живёт в схеме extensions.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_create_user(
    p_phone     text,
    p_pin       text,
    p_full_name text default null,
    p_org_type  text default 'farmer',          -- 'farmer' | 'mpk'
    p_org_name  text default null,
    p_email     text default null,
    p_language  text default 'ru'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    v_uid      uuid := gen_random_uuid();
    v_email    text := nullif(trim(p_email), '');
    v_phone    text := nullif(trim(p_phone), '');
    v_pid      uuid;
    v_org_id   uuid;
    v_org_name text := coalesce(nullif(trim(p_org_name), ''), nullif(trim(p_full_name), ''), 'Без названия');
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
    if p_org_type not in ('farmer', 'mpk') then
        raise exception 'INVALID_ORG_TYPE: только farmer или mpk' using errcode = 'P0001';
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

    -- 2. identities (для логина по телефону + email при наличии)
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
    values (gen_random_uuid(), v_uid, v_uid::text, 'phone',
            jsonb_build_object('sub', v_uid::text, 'phone', v_phone), now(), now(), now());
    if v_email is not null then
        insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
        values (gen_random_uuid(), v_uid, v_uid::text, 'email',
                jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true), now(), now(), now());
    end if;

    -- 3. public.users создаётся триггером trg_on_auth_user_created; язык + id
    update public.users set preferred_language = coalesce(p_language, 'ru') where auth_id = v_uid;
    select id into v_pid from public.users where auth_id = v_uid;

    -- 4. Организация + тип + роль владельца + членство (чтобы попал в список)
    insert into public.organizations (legal_name, phone)
    values (v_org_name, v_phone)
    returning id into v_org_id;

    insert into public.organization_type_assignments (organization_id, org_type, assigned_by)
    values (v_org_id, p_org_type, public.fn_current_user_id());

    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values (v_pid, v_org_id, 'owner', true);

    insert into public.memberships (organization_id, org_type, level)
    values (v_org_id, p_org_type, 'registered');

    -- 5. Ферма для фермера (как при обычной регистрации)
    if p_org_type = 'farmer' then
        insert into public.farms (organization_id, name, is_primary, data_source)
        values (v_org_id, v_org_name || ' — ферма', true, 'platform');
    end if;

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.user.created', 'users', v_pid, v_org_id, 'admin', public.fn_current_user_id(),
         jsonb_build_object('phone', v_phone, 'email', v_email, 'org_type', p_org_type), true);

    return v_pid;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_create_user', null, '20260629130000_admin_user_create_delete.sql', 'Admin creates auth user + identity with password')
on conflict (sql_name) do update set notes = excluded.notes;
