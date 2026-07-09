-- AgOS · ARS-208 · Удаление организации админом: гарда «0 участников» +
-- генерический разбор FK на organizations (чинит FK-ошибку каскада).
--
-- Изменения к rpc_admin_delete_organization (сигнатура НЕ меняется, P7-safe):
--   1. Гарда: если у организации есть привязанные пользователи
--      (user_organization_roles) — удаление запрещено с внятной ошибкой.
--   2. Генерический разбор одноколоночных FK, ссылающихся на organizations:
--        cascade-FK            → пропускаем (снесётся при delete орга);
--        nullable-FK           → set null (как было в 20260629140000);
--        NOT NULL без cascade  → delete строк по organization_id.
--      Покрывает membership_applications, verification_records,
--      agreement_acceptances, payments, consultation_requests, herd_groups,
--      herd_events, ai_conversations, notifications и любые будущие
--      денорм-таблицы (иначе — L-2: баг переезжает на следующую таблицу).
-- Аддитивно/идемпотентно. Применять: Supabase Dashboard → SQL Editor.

create or replace function public.rpc_admin_delete_organization(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_info    jsonb;
    v_members bigint;
    r         record;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin required' using errcode = 'P0001';
    end if;

    select to_jsonb(o.*) into v_info from public.organizations o where o.id = p_org_id;
    if v_info is null then
        raise exception 'ORG_NOT_FOUND: %', p_org_id using errcode = 'P0001';
    end if;

    -- Гарда: удалять можно только организации без привязанных пользователей.
    select count(*) into v_members
    from public.user_organization_roles
    where organization_id = p_org_id;
    if v_members > 0 then
        raise exception 'ORG_HAS_MEMBERS: в организации % участник(ов) — удаление запрещено', v_members
            using errcode = 'P0001';
    end if;

    -- аудит ДО удаления
    insert into public.platform_events
        (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload, is_audit)
    values
        ('identity.org.deleted', 'organizations', p_org_id, null, 'admin', public.fn_current_user_id(),
         jsonb_build_object('deleted', v_info), true);

    -- Разбираем все одноколоночные FK, ссылающиеся на organizations:
    --   confdeltype = 'c' (cascade)  → пропускаем, снесётся при delete орга;
    --   nullable                     → set null;
    --   NOT NULL без cascade         → delete строк по org (иначе FK заблокирует delete).
    for r in
        select c.conrelid::regclass::text as tbl,
               a.attname                  as col,
               a.attnotnull               as notnull,
               c.confdeltype              as deltype
        from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
        where c.confrelid = 'public.organizations'::regclass
          and c.contype   = 'f'
          and array_length(c.conkey, 1) = 1
    loop
        if r.deltype = 'c' then
            continue;
        elsif r.notnull then
            execute format('delete from %s where %I = $1', r.tbl, r.col) using p_org_id;
        else
            execute format('update %s set %I = null where %I = $1', r.tbl, r.col, r.col) using p_org_id;
        end if;
    end loop;

    delete from public.organizations where id = p_org_id;
end;
$$;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values ('rpc_admin_delete_organization', null, '20260709130000_admin_delete_org_zero_members_guard.sql',
        'Admin hard-deletes an organization with ZERO members (guard on user_organization_roles); generic FK teardown: cascade skip / nullable set-null / not-null delete')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;
