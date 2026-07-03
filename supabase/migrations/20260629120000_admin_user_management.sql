-- AgOS · Slice 6b расширение: админ полностью управляет профилями пользователей
-- фермеров и МПК (редактирование, список). Создание/удаление auth-пользователя —
-- через Edge Functions admin-create-user / admin-delete-user (service-role).
--
-- Паттерн повторяет rpc_assign_role (d01_kernel.sql): security definer +
-- guard fn_is_admin() + аудит в platform_events (actor_type='admin', is_audit=true).
-- Аддитивно и идемпотентно (P7). Применять: Supabase Dashboard → SQL Editor.

-- ------------------------------------------------------------
-- rpc_admin_update_user — редактирование профиля в public.users
-- UI присылает полный объект; поля устанавливаются напрямую
-- (пустая строка → NULL для phone/email/avatar_url).
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
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;

    select to_jsonb(u.*) into v_before from public.users u where u.id = p_user_id;
    if v_before is null then
        raise exception 'USER_NOT_FOUND: %', p_user_id using errcode = 'P0001';
    end if;

    update public.users set
        full_name          = p_full_name,
        phone              = nullif(p_phone, ''),
        email              = nullif(p_email, ''),
        preferred_language = coalesce(p_language, preferred_language),
        is_active          = coalesce(p_is_active, is_active),
        avatar_url         = nullif(p_avatar_url, ''),
        updated_at         = now()
    where id = p_user_id
    returning * into v_row;

    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.user.updated', 'users', p_user_id, null, 'admin', public.fn_current_user_id(),
         jsonb_build_object('before', v_before, 'after', to_jsonb(v_row)), true);

    return v_row;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_update_user', null, '20260629120000_admin_user_management.sql', 'Admin edits farmer/MPK user profile fields')
on conflict (sql_name) do update set notes = excluded.notes;

-- ------------------------------------------------------------
-- rpc_admin_list_farmer_mpk_users — список пользователей, привязанных
-- к организациям типа farmer или mpk, с инфо об орг и членстве.
-- distinct on (user_id): пользователь в нескольких орг показывается один раз.
-- ------------------------------------------------------------
create or replace function public.rpc_admin_list_farmer_mpk_users(
    p_search text default null
)
returns table (
    user_id            uuid,
    full_name          text,
    phone              text,
    email              text,
    avatar_url         text,
    preferred_language text,
    is_active          boolean,
    created_at         timestamptz,
    organization_id   uuid,
    organization_name text,
    org_types         text[],
    membership_level  text,
    membership_paid   boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;

    return query
    select distinct on (u.id)
        u.id,
        u.full_name,
        u.phone,
        u.email,
        u.avatar_url,
        u.preferred_language,
        u.is_active,
        u.created_at,
        o.id,
        o.legal_name,
        (select array_agg(distinct ota.org_type)
           from public.organization_type_assignments ota
          where ota.organization_id = o.id),
        m.level,
        (m.level is not null and m.level <> 'registered')
    from public.users u
    join public.user_organization_roles uor on uor.user_id = u.id
    join public.organizations o on o.id = uor.organization_id
    join public.organization_type_assignments ota2
        on ota2.organization_id = o.id
       and ota2.org_type in ('farmer', 'mpk')
    left join public.memberships m on m.organization_id = o.id
    where p_search is null
       or p_search = ''
       or u.full_name ilike '%' || p_search || '%'
       or u.phone     ilike '%' || p_search || '%'
       or u.email     ilike '%' || p_search || '%'
    order by u.id, u.created_at desc;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_list_farmer_mpk_users', null, '20260629120000_admin_user_management.sql', 'Admin list of farmer/MPK users with org + membership')
on conflict (sql_name) do update set notes = excluded.notes;
