-- AgOS · Фикс: rpc_pay_membership_dues падал на вставке platform_events с
-- actor_type='user' — это значение НЕ входит в check-constraint
-- platform_events_actor_type_check (farmer|admin|expert|system|ai_gateway).
-- Из-за этого вся транзакция оплаты откатывалась и memberships.level оставался
-- 'registered' (на UI «оплачено» из локального фолбэка, а в БД — нет; админ видел «не оплачено»).
-- Исправление: actor_type='user' → 'farmer'. Остальное идентично 20260624120000.
-- Применять в Supabase Dashboard → SQL Editor. Идемпотентно (create or replace).

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

    if not (p_organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: organization not owned by current user' using errcode = 'P0001';
    end if;

    select id, level
    into   v_membership_id, v_current_level
    from   public.memberships
    where  organization_id = p_organization_id
    limit  1;

    if v_membership_id is null then
        raise exception 'NO_MEMBERSHIP: organization % has no membership record', p_organization_id using errcode = 'P0001';
    end if;

    if v_current_level <> 'registered' then
        return jsonb_build_object('membership_id', v_membership_id, 'level', v_current_level, 'already_member', true);
    end if;

    select id, to_level
    into   v_app_id, v_to_level
    from   public.membership_applications
    where  organization_id = p_organization_id
      and  status = 'approved'
    order by reviewed_at desc nulls last, submitted_at desc
    limit  1;

    if v_app_id is null then
        raise exception 'NO_APPROVED_APPLICATION: organization % has no approved application', p_organization_id using errcode = 'P0001';
    end if;

    v_to_level := coalesce(v_to_level, 'observer');

    update public.memberships
       set previous_level   = level,
           level            = v_to_level,
           level_changed_at = now(),
           level_changed_by = v_uid,
           updated_at       = now()
     where id = v_membership_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'identity.membership.activated',
        'memberships',
        v_membership_id,
        p_organization_id,
        'farmer',  -- FIX: было 'user' (нарушало platform_events_actor_type_check)
        v_uid,
        jsonb_build_object('application_id', v_app_id, 'old_level', 'registered', 'new_level', v_to_level, 'payment', 'simulated'),
        true
    )
    returning id into v_event_id;

    return jsonb_build_object('membership_id', v_membership_id, 'level', v_to_level, 'application_id', v_app_id, 'event_id', v_event_id, 'already_member', false);
end;
$$;

grant execute on function public.rpc_pay_membership_dues(uuid) to authenticated;
