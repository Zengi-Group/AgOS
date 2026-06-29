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

    delete from auth.users where id = v_auth_id;  -- cascade → public.users и связанные
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
    p_email     text default null,
    p_phone     text default null,
    p_password  text default null,
    p_full_name text default null,
    p_language  text default 'ru'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    v_uid   uuid := gen_random_uuid();
    v_email text := nullif(trim(p_email), '');
    v_phone text := nullif(trim(p_phone), '');
    v_pid   uuid;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;
    if v_email is null and v_phone is null then
        raise exception 'EMAIL_OR_PHONE_REQUIRED' using errcode = 'P0001';
    end if;
    if p_password is null or length(p_password) < 6 then
        raise exception 'WEAK_PASSWORD: минимум 6 символов' using errcode = 'P0001';
    end if;
    if v_email is not null and exists (select 1 from auth.users where email = v_email) then
        raise exception 'EMAIL_EXISTS: %', v_email using errcode = 'P0001';
    end if;
    if v_phone is not null and exists (select 1 from auth.users where phone = v_phone) then
        raise exception 'PHONE_EXISTS: %', v_phone using errcode = 'P0001';
    end if;

    insert into auth.users (
        instance_id, id, aud, role,
        email, phone, encrypted_password,
        email_confirmed_at, phone_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at
    ) values (
        '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
        v_email, v_phone, extensions.crypt(p_password, extensions.gen_salt('bf')),
        case when v_email is not null then now() end,
        case when v_phone is not null then now() end,
        jsonb_build_object(
            'provider',  case when v_email is not null then 'email' else 'phone' end,
            'providers', case when v_email is not null then jsonb_build_array('email')
                                                        else jsonb_build_array('phone') end
        ),
        jsonb_build_object('full_name', p_full_name, 'phone', v_phone, 'preferred_language', coalesce(p_language, 'ru')),
        now(), now()
    );

    -- identities (нужны для логина)
    if v_email is not null then
        insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
        values (gen_random_uuid(), v_uid, v_uid::text, 'email',
                jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
                now(), now(), now());
    end if;
    if v_phone is not null then
        insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
        values (gen_random_uuid(), v_uid, v_uid::text, 'phone',
                jsonb_build_object('sub', v_uid::text, 'phone', v_phone),
                now(), now(), now());
    end if;

    -- public.users создаётся триггером trg_on_auth_user_created; проставим язык
    update public.users set preferred_language = coalesce(p_language, 'ru') where auth_id = v_uid;

    select id into v_pid from public.users where auth_id = v_uid;
    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.user.created', 'users', v_pid, null, 'admin', public.fn_current_user_id(),
         jsonb_build_object('email', v_email, 'phone', v_phone), true);

    return v_uid;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_create_user', null, '20260629130000_admin_user_create_delete.sql', 'Admin creates auth user + identity with password')
on conflict (sql_name) do update set notes = excluded.notes;
