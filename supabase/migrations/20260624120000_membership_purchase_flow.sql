-- AgOS · Слайс 2+ · Флоу покупки членства: документы → одобрение админом → оплата.
-- Контекст: возвращаем реальный админ-гейт (заменяет бета self-join). Новая модель:
--   1) Организация подаёт заявку с документами (Storage bucket membership-documents).
--   2) Админ просматривает документы и одобряет/отклоняет заявку
--      (rpc_process_membership_application). ВАЖНО: одобрение БОЛЬШЕ НЕ выдаёт членство —
--      оно лишь помечает заявку approved (статус «одобрено, взнос не оплачен»).
--   3) Только после одобрения организация оплачивает взнос (симуляция на пилоте) через
--      новый rpc_pay_membership_dues — он и поднимает memberships.level registered→observer.
--
-- Применять через Supabase Dashboard → SQL Editor (НЕ через deploy_sql.py — он тянет d-файлы).
-- Идемпотентно: CREATE OR REPLACE; повторный вызов оплаты для уже-члена безопасен.
-- Аддитивно (P7): rpc_self_join_membership не удаляем (исторический бета-RPC), но UI на него
-- больше не ссылается.

-- ============================================================
-- 1. rpc_process_membership_application — одобрение БЕЗ выдачи членства
--    Отличие от d01_kernel: удалён блок UPDATE memberships (повышение level).
--    Одобрение теперь = только статус заявки 'approved' + событие + уведомления.
-- ============================================================
create or replace function public.rpc_process_membership_application(
    p_organization_id   uuid,           -- P-AI-2 convention; the org whose application is being processed
    p_application_id    uuid,
    p_decision          text,           -- 'approved' | 'rejected'
    p_decision_notes    text    default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_admin_user_id     uuid;
    v_app               record;
    v_membership_id     uuid;
    v_farmer_user_id    uuid;
    v_farmer_org_id     uuid;
    v_event_id          uuid;
    v_new_level         text;
    v_org_name          text;
begin
    -- 1. Admin guard
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin access required'
            using errcode = 'P0001';
    end if;

    v_admin_user_id := public.fn_current_user_id();

    -- 2. Validate decision
    if p_decision not in ('approved', 'rejected') then
        raise exception 'INVALID_DECISION: must be approved or rejected, got %', p_decision
            using errcode = 'P0001';
    end if;

    -- 3. Load application
    select ma.id, ma.membership_id, ma.organization_id, ma.from_level, ma.to_level, ma.status
    into   v_app
    from   public.membership_applications ma
    where  ma.id = p_application_id;

    if v_app is null then
        raise exception 'APPLICATION_NOT_FOUND: application_id=% not found', p_application_id
            using errcode = 'P0001';
    end if;

    -- 4. Validate FSM: only submitted or under_review can be decided
    if v_app.status not in ('submitted', 'under_review') then
        raise exception 'ALREADY_DECIDED: application already has status=%', v_app.status
            using errcode = 'P0001';
    end if;

    v_membership_id := v_app.membership_id;
    v_farmer_org_id := v_app.organization_id;
    v_new_level     := v_app.to_level;   -- целевой уровень (для уведомления; выдаётся ОПЛАТОЙ)

    -- Get org name for notification
    select o.legal_name into v_org_name
    from public.organizations o
    where o.id = v_farmer_org_id;

    -- 5. Update application status (FSM). НЕ трогаем memberships.level — выдача идёт оплатой.
    update public.membership_applications
    set    status         = p_decision,
           reviewed_at    = now(),
           reviewed_by    = v_admin_user_id,
           reviewer_notes = p_decision_notes,
           updated_at     = now()
    where  id = p_application_id;

    -- 6. Event: фиксируем решение (без активации членства).
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'identity.membership_application.decided',
        'membership_applications',
        p_application_id,
        v_farmer_org_id,
        'admin',
        v_admin_user_id,
        jsonb_build_object(
            'decision', p_decision,
            'from_level', v_app.from_level,
            'to_level', v_new_level,
            'decision_notes', p_decision_notes
        ),
        true
    )
    returning id into v_event_id;

    -- 7. D-S2-2: Insert notifications (WhatsApp + in_app)
    -- Find the farmer user (organization owner)
    select u.id into v_farmer_user_id
    from public.users u
    join public.user_organization_roles uor on uor.user_id = u.id
    where uor.organization_id = v_farmer_org_id
      and uor.role = 'owner'
    limit 1;

    if v_farmer_user_id is not null then
        if p_decision = 'approved' then
            -- WhatsApp notification: application_approved
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'whatsapp',
                'application_approved',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'new_level', v_new_level
                ),
                v_event_id, 'pending'
            );
            -- In-app notification
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'in_app',
                'application_approved',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'new_level', v_new_level
                ),
                v_event_id, 'pending'
            );
        else
            -- WhatsApp notification: application_rejected
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'whatsapp',
                'application_rejected',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'reject_reason', coalesce(p_decision_notes, 'Не указана'),
                    'contact_info', '+7 (700) 000-00-00'
                ),
                v_event_id, 'pending'
            );
            -- In-app notification
            insert into public.notifications (
                user_id, organization_id, channel, template_id, params,
                platform_event_id, delivery_status
            ) values (
                v_farmer_user_id, v_farmer_org_id, 'in_app',
                'application_rejected',
                jsonb_build_object(
                    'org_name', v_org_name,
                    'reject_reason', coalesce(p_decision_notes, 'Не указана'),
                    'contact_info', '+7 (700) 000-00-00'
                ),
                v_event_id, 'pending'
            );
        end if;
    end if;

    return v_membership_id;
end;
$$;

grant execute on function public.rpc_process_membership_application(uuid, uuid, text, text) to authenticated;

comment on function public.rpc_process_membership_application(uuid, uuid, text, text) is
    'RPC-03 | Slice 2+ | Admin одобряет/отклоняет заявку на членство.
     FSM: submitted/under_review → approved/rejected.
     ВАЖНО: одобрение НЕ выдаёт членство (level не меняется) — членство выдаётся ОПЛАТОЙ
     (rpc_pay_membership_dues). Событие identity.membership_application.decided + уведомления.
     Error codes: FORBIDDEN, INVALID_DECISION, APPLICATION_NOT_FOUND, ALREADY_DECIDED.';


-- ============================================================
-- 2. rpc_pay_membership_dues — оплата взноса после одобрения (симуляция, пилот)
--    Требует одобренную заявку. Поднимает level registered → to_level (observer).
--    Доступ только к своим org (fn_my_org_ids). Идемпотентно для уже-члена.
-- ============================================================
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

    -- Доступ только к своим организациям.
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

    -- Требуется ОДОБРЕННАЯ заявка (админ-гейт). Без неё оплата невозможна.
    select id, to_level
    into   v_app_id, v_to_level
    from   public.membership_applications
    where  organization_id = p_organization_id
      and  status = 'approved'
    order by reviewed_at desc nulls last, submitted_at desc
    limit  1;

    if v_app_id is null then
        raise exception 'NO_APPROVED_APPLICATION: organization % has no approved application', p_organization_id
            using errcode = 'P0001';
    end if;

    v_to_level := coalesce(v_to_level, 'observer');

    -- Поднимаем уровень членства registered → to_level (оплата = активация).
    update public.memberships
       set previous_level   = level,
           level            = v_to_level,
           level_changed_at = now(),
           level_changed_by = v_uid,
           updated_at       = now()
     where id = v_membership_id;

    -- Событие активации членства (оплата взноса, симуляция на пилоте).
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'identity.membership.activated',
        'memberships',
        v_membership_id,
        p_organization_id,
        'farmer',  -- platform_events_actor_type_check: farmer|admin|expert|system|ai_gateway ('user' невалиден)
        v_uid,
        jsonb_build_object(
            'application_id', v_app_id,
            'old_level', 'registered',
            'new_level', v_to_level,
            'payment', 'simulated'
        ),
        true
    )
    returning id into v_event_id;

    return jsonb_build_object(
        'membership_id', v_membership_id,
        'level', v_to_level,
        'application_id', v_app_id,
        'event_id', v_event_id,
        'already_member', false
    );
end;
$$;

grant execute on function public.rpc_pay_membership_dues(uuid) to authenticated;

comment on function public.rpc_pay_membership_dues(uuid) is
    'Slice 2+ | Оплата членского взноса после одобрения (симуляция на пилоте).
     Требует membership_application со статусом approved; поднимает memberships.level
     registered→to_level (observer). Доступ только к своим org (fn_my_org_ids).
     Идемпотентно для уже-члена. Error: AUTH_REQUIRED, FORBIDDEN, NO_MEMBERSHIP, NO_APPROVED_APPLICATION.';

-- ============================================================
-- 3. Registry
-- ============================================================
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('rpc_pay_membership_dues', null, null, '20260624120000_membership_purchase_flow.sql', 'Оплата взноса после одобрения (симуляция): registered→observer')
on conflict (sql_name) do update
    set notes      = excluded.notes,
        created_in = excluded.created_in;
