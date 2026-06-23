-- AgOS · БЕТА · Слайс 2 · Self-serve подтверждение членства (без админов).
-- Контекст: на этапе беты нет администраторов ассоциации, поэтому организация
-- подтверждает своё членство сама. Аддитивно (P7): существующие admin-RPC не трогаем,
-- добавляем отдельную self-serve функцию. Позже легко вернуть admin-гейт.
--
-- Применять через Supabase Dashboard → SQL Editor (НЕ через deploy_sql.py — он тянет d-файлы).
-- Идемпотентно: CREATE OR REPLACE; повторный вызов для уже-члена безопасен.

create or replace function public.rpc_self_join_membership(p_organization_id uuid)
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
begin
    v_uid := public.fn_current_user_id();
    if v_uid is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    -- Доступ только к своим организациям (вместо fn_is_admin) — self-serve беты.
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

    -- Одобряем последнюю ожидающую заявку, если она есть.
    update public.membership_applications
       set status         = 'approved',
           reviewed_at    = now(),
           reviewed_by    = v_uid,
           reviewer_notes = coalesce(reviewer_notes, 'self-approved (beta, no admin)'),
           updated_at     = now()
     where id = (
         select id
         from   public.membership_applications
         where  organization_id = p_organization_id
           and  status in ('submitted', 'under_review')
         order by submitted_at desc
         limit  1
     )
     returning id into v_app_id;

    -- Ожидающей заявки не было — создаём сразу одобренную (бета self-join).
    if v_app_id is null then
        insert into public.membership_applications (
            membership_id, organization_id, from_level, to_level,
            status, reviewed_at, reviewed_by, reviewer_notes
        ) values (
            v_membership_id, p_organization_id, v_current_level, 'observer',
            'approved', now(), v_uid, 'self-approved (beta, no admin)'
        )
        returning id into v_app_id;
    end if;

    -- Поднимаем уровень членства registered → observer.
    update public.memberships
       set previous_level   = level,
           level            = 'observer',
           level_changed_at = now(),
           level_changed_by = v_uid,
           updated_at       = now()
     where id = v_membership_id;

    return jsonb_build_object(
        'membership_id', v_membership_id,
        'level', 'observer',
        'application_id', v_app_id,
        'already_member', false
    );
end;
$$;

grant execute on function public.rpc_self_join_membership(uuid) to authenticated;

comment on function public.rpc_self_join_membership(uuid) is
    'BETA self-serve | Слайс 2 | Подтверждение членства без админа.
     Одобряет последнюю ожидающую membership_application (или создаёт сразу approved)
     и поднимает memberships.level registered→observer.
     Доступ только к своим org (fn_my_org_ids), без fn_is_admin. Идемпотентно для уже-члена.';
