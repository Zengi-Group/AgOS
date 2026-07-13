-- =============================================================================
-- d12_messaging.sql — Внутриплатформенное общение (Messaging Channels)
-- =============================================================================
-- Canonical domain file for the `messaging` domain (prefix comm_).
-- Apply after d11_norms.sql.
-- Canon (design intent): Docs/AGOS-Messaging-EngSpec-v0_1.md (ARS-221 / ARS-222).
--
-- Модель Kaspi / супергруппы (НЕ свободный Telegram-чат). MVP-ось:
--   фермер/МПК ↔ админ  → channel_type='support' (двусторонний, get-or-create)
-- Схема (без RPC/UI в MVP):
--   система → орг       → channel_type='system_broadcast' (слайс 2)
--
-- P1 data-model-first · P4 один факт — одно место (notifications = транспорт,
-- контент живёт в comm_messages) · P6 FSM = text+CHECK · P7 аддитивно (новые
-- таблицы/RPC, существующие сигнатуры не трогаем) · RLS обязательна (орг A ≠ орг B).
--
-- Все statements идемпотентны. PK uuid gen_random_uuid(). timestamptz (UTC).
-- Soft-delete: is_active (каналы/участники) / is_deleted (сообщения).
-- =============================================================================


-- ============================================================
-- SECTION 1: TABLES
-- ============================================================

-- -------------------------------------------------------
-- comm_channels — контейнер-канал
-- P2 ownership: создаёт фермер/МПК (get-or-create) либо админ; авторитет статуса — админ.
-- P12: current-state; история диалога — в comm_messages (append-only).
-- -------------------------------------------------------
create table if not exists public.comm_channels (
    id              uuid    primary key default gen_random_uuid(),
    organization_id uuid    references public.organizations(id),  -- клиентская орг; null = broadcast 'all' (слайс 2)
    channel_type    text    not null
                                check (channel_type in (
                                    'support',          -- двусторонний фермер/МПК ↔ админ (MVP)
                                    'system_broadcast'  -- система → орг (слайс 2)
                                )),
    status          text    not null default 'active'
                                check (status in ('active','archived')),
    title           text,       -- support = имя орг (денорм для inbox); broadcast = заголовок
    last_message_at timestamptz,  -- денорм, сортировка inbox
    created_by      uuid    references public.users(id),  -- null для системных
    is_active       boolean not null default true,  -- soft-delete
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
comment on table public.comm_channels is
    'Messaging (Docs/AGOS-Messaging-EngSpec-v0_1.md): контейнер-канал модели Kaspi.
     support = постоянный двусторонний канал техподдержки (один на орг, get-or-create);
     system_broadcast = канал-объявление (слайс 2). status FSM active/archived (без closed,
     реш. CEO 2026-07-13): новое сообщение в archived возвращает active (rpc_send_message).';

-- Инвариант: ровно ОДИН support-канал на орг (Kaspi-стиль постоянный диалог).
-- Опора rpc_get_or_create_support_channel (переиспользует его даже если archived).
create unique index if not exists uq_comm_support_channel_per_org
    on public.comm_channels (organization_id)
    where channel_type = 'support' and is_active;

create index if not exists idx_comm_channels_org
    on public.comm_channels (organization_id);
create index if not exists idx_comm_channels_type_last
    on public.comm_channels (channel_type, last_message_at desc);

-- -------------------------------------------------------
-- comm_participants — участники (RLS + курсор непрочитанного)
-- Все активные члены орг — участники role='member' support-канала (лениво заводятся
-- при первом входе/сообщении). Каждый может писать (реш. G2). Админ = role='admin'.
-- -------------------------------------------------------
create table if not exists public.comm_participants (
    id          uuid    primary key default gen_random_uuid(),
    channel_id  uuid    not null references public.comm_channels(id) on delete cascade,
    user_id     uuid    not null references public.users(id) on delete cascade,
    role        text    not null default 'member'
                            check (role in ('member','admin')),
    last_read_at timestamptz,  -- курсор прочтения → счётчик непрочитанного
    joined_at   timestamptz not null default now(),
    is_active   boolean not null default true,
    unique (channel_id, user_id)   -- одно членство на пару
);
comment on table public.comm_participants is
    'Messaging: участники канала. role member = сторона орг; admin = техподдержка.
     last_read_at — курсор для unread-счётчика. UNIQUE(channel_id,user_id).';

create index if not exists idx_comm_participants_user
    on public.comm_participants (user_id);
create index if not exists idx_comm_participants_channel
    on public.comm_participants (channel_id);

-- -------------------------------------------------------
-- comm_messages — сообщения (свободный текст + вложения), append-only
-- author_user_id null = система. author_actor_type в тон platform_events.actor_type.
-- attachments jsonb = [{storage_path, mime, size, width?, height?}] (Supabase Storage
-- private bucket comm-attachments, путь {organization_id}/{channel_id}/{uuid}).
-- -------------------------------------------------------
create table if not exists public.comm_messages (
    id                uuid    primary key default gen_random_uuid(),
    channel_id        uuid    not null references public.comm_channels(id) on delete cascade,
    organization_id   uuid    references public.organizations(id),  -- денорм для RLS; null для broadcast 'all'
    author_user_id    uuid    references public.users(id),  -- null = система
    author_actor_type text    not null
                                check (author_actor_type in (
                                    'farmer','admin','expert','system'
                                )),
    body              text,   -- свободный текст (может быть null если только вложение)
    attachments       jsonb   not null default '[]'::jsonb,
    is_deleted        boolean not null default false,  -- soft-delete сообщения
    created_at        timestamptz not null default now()
    -- No updated_at: APPEND-ONLY
);
comment on table public.comm_messages is
    'Messaging: сообщения канала (свободный текст + вложения). APPEND-ONLY (без updated_at).
     author_user_id null = система; author_actor_type согласован с platform_events.actor_type.
     P4: полный контент здесь; notifications несёт только preview+deep-link (template-only).';

create index if not exists idx_comm_messages_channel_created
    on public.comm_messages (channel_id, created_at desc);
create index if not exists idx_comm_messages_org
    on public.comm_messages (organization_id);   -- RLS


-- ============================================================
-- SECTION 2: ROW LEVEL SECURITY
-- Core principle (CLAUDE.md §Data Isolation): орг A НЕ видит данные орг B.
-- Helpers из d01: fn_current_user_id(), fn_my_org_ids(), fn_is_admin(), fn_is_expert().
-- SECURITY DEFINER RPC ниже пишут от владельца (обходят RLS); политики защищают
-- прямой доступ PostgREST.
-- ============================================================

alter table public.comm_channels     enable row level security;
alter table public.comm_participants  enable row level security;
alter table public.comm_messages       enable row level security;

-- comm_channels: читает участник / член орг канала / админ. Пишет напрямую — админ
-- (фермер создаёт/пишет только через RPC).
drop policy if exists "comm_channels_read" on public.comm_channels;
create policy "comm_channels_read"
    on public.comm_channels for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or id in (
            select channel_id from public.comm_participants
            where user_id = public.fn_current_user_id() and is_active
        )
        or public.fn_is_admin()
    );
drop policy if exists "comm_channels_admin_write" on public.comm_channels;
create policy "comm_channels_admin_write"
    on public.comm_channels for all
    using (public.fn_is_admin());

-- comm_participants: читает сам участник / член орг канала / админ. Пишет — админ.
drop policy if exists "comm_participants_read" on public.comm_participants;
create policy "comm_participants_read"
    on public.comm_participants for select
    using (
        user_id = public.fn_current_user_id()
        or channel_id in (
            select id from public.comm_channels
            where organization_id = any(public.fn_my_org_ids())
        )
        or public.fn_is_admin()
    );
drop policy if exists "comm_participants_admin_write" on public.comm_participants;
create policy "comm_participants_admin_write"
    on public.comm_participants for all
    using (public.fn_is_admin());

-- comm_messages: читает член орг / участник канала / админ. Insert через RPC, но политика
-- согласована (member своей орг / админ). Update — только админ (soft-delete). Append-only:
-- нет delete-политики.
drop policy if exists "comm_messages_read" on public.comm_messages;
create policy "comm_messages_read"
    on public.comm_messages for select
    using (
        organization_id = any(public.fn_my_org_ids())
        or channel_id in (
            select channel_id from public.comm_participants
            where user_id = public.fn_current_user_id() and is_active
        )
        or public.fn_is_admin()
    );
drop policy if exists "comm_messages_insert" on public.comm_messages;
create policy "comm_messages_insert"
    on public.comm_messages for insert
    with check (
        organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
    );
drop policy if exists "comm_messages_admin_update" on public.comm_messages;
create policy "comm_messages_admin_update"
    on public.comm_messages for update
    using (public.fn_is_admin());


-- ============================================================
-- SECTION 3: TRIGGERS (updated_at) — reuse d01 fn_set_updated_at()
-- ============================================================

drop trigger if exists trg_comm_channels_updated_at on public.comm_channels;
create trigger trg_comm_channels_updated_at
    before update on public.comm_channels
    for each row execute function public.fn_set_updated_at();


-- ============================================================
-- SECTION 4: RPC (SECURITY DEFINER, rpc_ префикс, аддитивно P7)
-- organization_id выводится из канала/членства и проверяется в каждом вызове.
-- Web и AI вызывают ОДНИ и те же RPC (без дублирования логики).
-- ============================================================

-- -------------------------------------------------------
-- rpc_get_or_create_support_channel — вернуть/создать единственный support-канал орг
-- и добавить вызывающего в participants (get-or-create, Kaspi-стиль).
-- -------------------------------------------------------
create or replace function public.rpc_get_or_create_support_channel(
    p_organization_id uuid
)
returns public.comm_channels
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
    v_user_id uuid := public.fn_current_user_id();
    v_is_admin boolean := public.fn_is_admin();
    v_ch public.comm_channels%rowtype;
    v_title text;
begin
    if v_user_id is null then
        raise exception 'FORBIDDEN: no authenticated user';
    end if;
    -- Authz: член орг либо админ.
    if not (p_organization_id = any(public.fn_my_org_ids()) or v_is_admin) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id;
    end if;

    -- get: единственный активный support-канал орг (переиспользуем даже если archived).
    select * into v_ch
    from public.comm_channels
    where organization_id = p_organization_id
      and channel_type = 'support'
      and is_active
    limit 1;

    -- create
    if not found then
        select legal_name into v_title from public.organizations where id = p_organization_id;
        insert into public.comm_channels (organization_id, channel_type, status, title, created_by)
        values (p_organization_id, 'support', 'active', v_title, v_user_id)
        returning * into v_ch;
    end if;

    -- ensure participant (лениво). Админ входит как admin, иначе member.
    insert into public.comm_participants (channel_id, user_id, role)
    values (v_ch.id, v_user_id, case when v_is_admin then 'admin' else 'member' end)
    on conflict (channel_id, user_id) do nothing;

    return v_ch;
end;
$$;
comment on function public.rpc_get_or_create_support_channel(uuid) is
    'Messaging: вернуть/создать единственный support-канал орг + добавить вызывающего в
     participants. Authz: член орг либо админ. Idempotent (get-or-create).';

-- -------------------------------------------------------
-- rpc_send_message — вставить сообщение, обновить last_message_at, un-archive,
-- опубликовать platform_event comm.message.created.
-- (org_id выводится из канала — CHECK 5 exception, web-JWT класс.)
-- -------------------------------------------------------
create or replace function public.rpc_send_message(
    p_channel_id   uuid,
    p_body         text,
    p_attachments  jsonb default '[]'::jsonb
)
returns public.comm_messages
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
    v_user_id uuid := public.fn_current_user_id();
    v_is_admin boolean := public.fn_is_admin();
    v_is_expert boolean := public.fn_is_expert();
    v_ch public.comm_channels%rowtype;
    v_actor_type text;
    v_msg public.comm_messages%rowtype;
begin
    if v_user_id is null then
        raise exception 'FORBIDDEN: no authenticated user';
    end if;
    if coalesce(btrim(p_body), '') = '' and coalesce(jsonb_array_length(p_attachments), 0) = 0 then
        raise exception 'EMPTY_MESSAGE: body and attachments are both empty';
    end if;

    select * into v_ch from public.comm_channels where id = p_channel_id and is_active;
    if not found then
        raise exception 'CHANNEL_NOT_FOUND: %', p_channel_id;
    end if;

    -- Authz: член орг канала, действующий участник, либо админ.
    if not (
        v_ch.organization_id = any(public.fn_my_org_ids())
        or v_is_admin
        or exists (
            select 1 from public.comm_participants
            where channel_id = v_ch.id and user_id = v_user_id and is_active
        )
    ) then
        raise exception 'FORBIDDEN: cannot post to channel %', p_channel_id;
    end if;

    v_actor_type := case when v_is_admin then 'admin'
                         when v_is_expert then 'expert'
                         else 'farmer' end;

    -- Лениво заводим участника (не-админ член орг).
    if not v_is_admin then
        insert into public.comm_participants (channel_id, user_id, role)
        values (v_ch.id, v_user_id, 'member')
        on conflict (channel_id, user_id) do nothing;
    end if;

    insert into public.comm_messages (
        channel_id, organization_id, author_user_id, author_actor_type, body, attachments
    ) values (
        v_ch.id, v_ch.organization_id, v_user_id, v_actor_type,
        nullif(btrim(p_body), ''), coalesce(p_attachments, '[]'::jsonb)
    )
    returning * into v_msg;

    -- Денорм last_message_at + un-archive (archived → active при новом сообщении).
    update public.comm_channels
    set last_message_at = v_msg.created_at,
        status = 'active',
        updated_at = now()
    where id = v_ch.id;

    -- Событие → диспетчер уведомлений (ARS-224). preview = срез, НЕ полный текст (P4).
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'comm.message.created',
        'comm_messages',
        v_msg.id,
        v_ch.organization_id,
        v_actor_type,
        v_user_id,
        jsonb_build_object(
            'channel_id', v_ch.id,
            'message_id', v_msg.id,
            'author_user_id', v_user_id,
            'author_actor_type', v_actor_type,
            'preview', left(coalesce(nullif(btrim(p_body), ''), '[вложение]'), 120)
        ),
        false
    );

    return v_msg;
end;
$$;
comment on function public.rpc_send_message(uuid, text, jsonb) is
    'Messaging: отправить сообщение в канал. Проставляет author_actor_type по роли,
     обновляет last_message_at, возвращает archived→active, публикует platform_event
     comm.message.created (payload.preview — срез, не полный текст, P4). org_id из канала.';

-- -------------------------------------------------------
-- rpc_list_channels — админ: все support-каналы (inbox, сорт по last_message_at);
-- фермер/МПК: каналы своих орг + где он участник.
-- (без org_id параметра — CHECK 5 exception.)
-- -------------------------------------------------------
create or replace function public.rpc_list_channels()
returns setof public.comm_channels
language plpgsql security definer stable
set search_path = public, pg_temp as $$
begin
    if public.fn_is_admin() then
        return query
            select * from public.comm_channels
            where channel_type = 'support' and is_active
            order by last_message_at desc nulls last;
    else
        return query
            select * from public.comm_channels c
            where c.is_active
              and (
                c.organization_id = any(public.fn_my_org_ids())
                or c.id in (
                    select channel_id from public.comm_participants
                    where user_id = public.fn_current_user_id() and is_active
                )
              )
            order by c.last_message_at desc nulls last;
    end if;
end;
$$;
comment on function public.rpc_list_channels() is
    'Messaging: список каналов. Админ → все active support (inbox, сорт last_message_at);
     фермер/МПК → каналы своих орг + где участник. org-scope через fn_my_org_ids().';

-- -------------------------------------------------------
-- rpc_list_messages — тред с keyset-пагинацией (created_at < p_before).
-- (org_id из канала — CHECK 5 exception.)
-- -------------------------------------------------------
create or replace function public.rpc_list_messages(
    p_channel_id uuid,
    p_before     timestamptz default null,
    p_limit      int default 50
)
returns setof public.comm_messages
language plpgsql security definer stable
set search_path = public, pg_temp as $$
declare
    v_ch public.comm_channels%rowtype;
begin
    select * into v_ch from public.comm_channels where id = p_channel_id;
    if not found then
        raise exception 'CHANNEL_NOT_FOUND: %', p_channel_id;
    end if;
    if not (
        v_ch.organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or exists (
            select 1 from public.comm_participants
            where channel_id = v_ch.id and user_id = public.fn_current_user_id() and is_active
        )
    ) then
        raise exception 'FORBIDDEN: cannot read channel %', p_channel_id;
    end if;

    return query
        select * from public.comm_messages
        where channel_id = p_channel_id
          and is_deleted = false
          and (p_before is null or created_at < p_before)
        order by created_at desc
        limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;
comment on function public.rpc_list_messages(uuid, timestamptz, int) is
    'Messaging: сообщения канала (keyset-пагинация created_at < p_before, desc, limit≤200).
     Authz: член орг / участник / админ. org-scope через fn_my_org_ids().';

-- -------------------------------------------------------
-- rpc_mark_channel_read — курсор прочтения участника.
-- (без org_id параметра — CHECK 5 exception.)
-- -------------------------------------------------------
create or replace function public.rpc_mark_channel_read(
    p_channel_id uuid
)
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
    v_user_id uuid := public.fn_current_user_id();
begin
    if v_user_id is null then
        raise exception 'FORBIDDEN: no authenticated user';
    end if;
    update public.comm_participants
    set last_read_at = now()
    where channel_id = p_channel_id and user_id = v_user_id;
end;
$$;
comment on function public.rpc_mark_channel_read(uuid) is
    'Messaging: отметить канал прочитанным для текущего участника (last_read_at = now()).';

-- -------------------------------------------------------
-- rpc_archive_channel — админ архивирует канал (status='archived').
-- (без org_id параметра, admin-guarded — CHECK 5 exception.)
-- -------------------------------------------------------
create or replace function public.rpc_archive_channel(
    p_channel_id uuid
)
returns public.comm_channels
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
    v_ch public.comm_channels%rowtype;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only';
    end if;
    update public.comm_channels
    set status = 'archived', updated_at = now()
    where id = p_channel_id
    returning * into v_ch;
    if not found then
        raise exception 'CHANNEL_NOT_FOUND: %', p_channel_id;
    end if;
    return v_ch;
end;
$$;
comment on function public.rpc_archive_channel(uuid) is
    'Messaging: админ архивирует канал (status=archived). Новое сообщение вернёт active.';


-- ============================================================
-- SECTION 5: rpc_name_registry entries
-- ============================================================

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('rpc_get_or_create_support_channel', null, null, 'd12_messaging.sql', 'Messaging: get-or-create единственного support-канала орг + participant'),
    ('rpc_send_message',                  null, null, 'd12_messaging.sql', 'Messaging: отправить сообщение; событие comm.message.created; org_id из канала'),
    ('rpc_list_channels',                 null, null, 'd12_messaging.sql', 'Messaging: inbox админа / каналы орг; org-scope через fn_my_org_ids()'),
    ('rpc_list_messages',                 null, null, 'd12_messaging.sql', 'Messaging: тред с keyset-пагинацией; org_id из канала'),
    ('rpc_mark_channel_read',             null, null, 'd12_messaging.sql', 'Messaging: курсор прочтения (last_read_at)'),
    ('rpc_archive_channel',               null, null, 'd12_messaging.sql', 'Messaging: админ архивирует канал')
on conflict (sql_name) do update
    set notes      = excluded.notes,
        created_in = excluded.created_in;

-- =============================================================================
-- END d12_messaging.sql
-- =============================================================================
