-- AgOS · Доводка админ-управления:
--   1. fn_normalize_phone_kz — нормализация номера к виду 7XXXXXXXXXX (11 цифр,
--      как хранит GoTrue в auth.users.phone → вход по логину работает).
--   2. rpc_admin_create_user — нормализует телефон + СРАЗУ активирует членство
--      организации (level: registered → observer), чтобы созданные аккаунты были
--      «как обычные, но уже с активированным членством» и могли входить.
--   3. rpc_admin_update_user — при смене телефона синхронизирует auth.users.phone
--      и identity (иначе вход остаётся на старом номере).
-- Аддитивно/идемпотентно. Применять ПОСЛЕ 20260629140000_*. Supabase → SQL Editor.

-- ------------------------------------------------------------
-- 0. Нормализация телефона КЗ → '7XXXXXXXXXX' (11 цифр) или NULL, если мусор.
--    GoTrue хранит phone без '+', только цифры. Вход: signInWithPassword({phone:'+7…'})
--    → GoTrue вырезает '+' → '7XXXXXXXXXX'. Совпадение по этому виду.
-- ------------------------------------------------------------
create or replace function public.fn_normalize_phone_kz(p_phone text)
returns text
language plpgsql
immutable
as $$
declare
    v text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
    if v = '' then
        return null;
    end if;
    if length(v) = 10 then
        v := '7' || v;                 -- 7710856566 → 77710856566
    elsif length(v) = 11 and left(v, 1) = '8' then
        v := '7' || right(v, 10);      -- 87710856566 → 77710856566
    end if;
    if length(v) <> 11 or left(v, 1) <> '7' then
        return null;
    end if;
    return v;
end;
$$;

-- ------------------------------------------------------------
-- 1. rpc_admin_create_user — нормализация телефона + активация членства
--    (та же сигнатура, что в 140000 → create or replace без drop).
-- ------------------------------------------------------------
create or replace function public.rpc_admin_create_user(
    p_phone           text,
    p_pin             text,
    p_organization_id uuid,
    p_role            text default 'owner',
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
    v_uid      uuid := gen_random_uuid();
    v_email    text := nullif(trim(p_email), '');
    v_digits   text := public.fn_normalize_phone_kz(p_phone);  -- '7XXXXXXXXXX'
    v_e164     text;
    v_pid      uuid;
    v_is_first boolean;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;
    if v_digits is null then
        raise exception 'PHONE_INVALID: телефон в формате +7XXXXXXXXXX' using errcode = 'P0001';
    end if;
    v_e164 := '+' || v_digits;
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
    if exists (select 1 from auth.users where phone = v_digits) then
        raise exception 'PHONE_EXISTS: %', v_e164 using errcode = 'P0001';
    end if;
    if v_email is not null and exists (select 1 from auth.users where email = v_email) then
        raise exception 'EMAIL_EXISTS: %', v_email using errcode = 'P0001';
    end if;

    -- 1. auth.users (телефон — только цифры, как у GoTrue; ПИН → bcrypt)
    insert into auth.users (
        instance_id, id, aud, role,
        email, phone, encrypted_password,
        email_confirmed_at, phone_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at
    ) values (
        '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
        v_email, v_digits, extensions.crypt(p_pin, extensions.gen_salt('bf')),
        case when v_email is not null then now() end,
        now(),
        jsonb_build_object('provider', 'phone', 'providers', jsonb_build_array('phone')),
        jsonb_build_object('full_name', p_full_name, 'phone', v_digits, 'preferred_language', coalesce(p_language, 'ru')),
        now(), now()
    );

    -- 2. identities
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
    values (gen_random_uuid(), v_uid, v_uid::text, 'phone',
            jsonb_build_object('sub', v_uid::text, 'phone', v_digits), now(), now(), now());
    if v_email is not null then
        insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
        values (gen_random_uuid(), v_uid, v_uid::text, 'email',
                jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true), now(), now(), now());
    end if;

    -- 3. public.users (создан триггером) — язык + телефон в E.164 для отображения
    update public.users
       set preferred_language = coalesce(p_language, 'ru'),
           phone              = v_e164
     where auth_id = v_uid;
    select id into v_pid from public.users where auth_id = v_uid;

    -- 4. Привязка к выбранной организации
    select not exists (
        select 1 from public.user_organization_roles where user_id = v_pid and is_primary
    ) into v_is_first;

    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values (v_pid, p_organization_id, coalesce(p_role, 'owner'), v_is_first)
    on conflict (user_id, organization_id) do update set role = excluded.role;

    -- 5. Активируем членство организации (registered → observer), чтобы аккаунт
    --    был «обычным, но с активированным членством». Уже активные не трогаем.
    update public.memberships
       set previous_level   = level,
           level            = 'observer',
           level_changed_at = now(),
           level_changed_by = public.fn_current_user_id(),
           updated_at       = now()
     where organization_id = p_organization_id
       and level = 'registered';

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.user.created', 'users', v_pid, p_organization_id, 'admin', public.fn_current_user_id(),
         jsonb_build_object('phone', v_e164, 'email', v_email, 'role', coalesce(p_role, 'owner'), 'membership', 'observer'), true);

    return v_pid;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_create_user', null, '20260629150000_admin_phone_membership_login.sql', 'Admin creates user (normalized phone, attached to org, membership activated)')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ------------------------------------------------------------
-- 2. rpc_admin_update_user — нормализация телефона + синхронизация в auth.users
--    и identity (чтобы вход по логину работал на новом номере).
-- ------------------------------------------------------------
create or replace function public.rpc_admin_update_user(
    p_user_id   uuid,
    p_full_name text,
    p_phone     text    default null,
    p_email     text    default null,
    p_language  text    default null,
    p_is_active boolean default null,
    p_avatar_url text   default null
)
returns public.users
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_before jsonb;
    v_row    public.users;
    v_auth   uuid;
    v_digits text;
    v_email  text := nullif(trim(p_email), '');
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;

    select to_jsonb(u.*), u.auth_id into v_before, v_auth from public.users u where u.id = p_user_id;
    if v_before is null then
        raise exception 'USER_NOT_FOUND: %', p_user_id using errcode = 'P0001';
    end if;

    -- Телефон: пусто → очистить; непусто → строго нормализовать (иначе ошибка).
    if p_phone is not null and trim(p_phone) <> '' then
        v_digits := public.fn_normalize_phone_kz(p_phone);
        if v_digits is null then
            raise exception 'PHONE_INVALID: телефон в формате +7XXXXXXXXXX' using errcode = 'P0001';
        end if;
        if exists (select 1 from auth.users where phone = v_digits and id <> v_auth) then
            raise exception 'PHONE_EXISTS: +%', v_digits using errcode = 'P0001';
        end if;
    end if;

    update public.users set
        full_name          = p_full_name,
        phone              = case when p_phone is null then phone
                                  when trim(p_phone) = '' then null
                                  else '+' || v_digits end,
        email              = v_email,
        preferred_language = coalesce(p_language, preferred_language),
        is_active          = coalesce(p_is_active, is_active),
        avatar_url         = nullif(p_avatar_url, ''),
        updated_at         = now()
    where id = p_user_id
    returning * into v_row;

    -- Синхронизация в auth.users + phone-identity (только при валидном новом номере)
    if v_auth is not null and v_digits is not null then
        update auth.users
           set phone = v_digits, phone_confirmed_at = coalesce(phone_confirmed_at, now()), updated_at = now()
         where id = v_auth;
        update auth.identities
           set identity_data = jsonb_set(coalesce(identity_data, '{}'::jsonb), '{phone}', to_jsonb(v_digits)),
               updated_at = now()
         where user_id = v_auth and provider = 'phone';
    end if;
    if v_auth is not null and v_email is not null then
        update auth.users set email = v_email, updated_at = now() where id = v_auth;
    end if;

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.user.updated', 'users', p_user_id, null, 'admin', public.fn_current_user_id(),
         jsonb_build_object('before', v_before, 'after', to_jsonb(v_row)), true);

    return v_row;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_update_user', null, '20260629150000_admin_phone_membership_login.sql', 'Admin edits user; phone synced to auth.users + identity')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;
