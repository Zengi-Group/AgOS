-- AgOS · БЕТА · Слайс 6 · Аддитив: мультирегион + порода в матчинге TSP.
-- ============================================================================
-- КОНТЕКСТ / ТРЕБОВАНИЕ (CEO, 2026-07-01):
--   (1) Фермер при выставлении партии НЕ выбирает регион — он берётся из данных
--       регистрации хозяйства (organizations.region_id). Бэкенд это уже делал
--       (fn_tsp_region_id фолбэк на org.region_id в rpc_create_batch) — здесь
--       ничего менять не нужно; правка только на фронте (убрать селектор района).
--   (2) МПК при закупке может выбрать НЕСКОЛЬКО областей (или «Все области»),
--       а также ПОРОДУ желаемого скота — по каждой строке пула (порода+категория).
--       Матчинг — ЖЁСТКИЙ фильтр по ВСЕМ параметрам: сорт + цена + окно + ёмкость
--       + РЕГИОН (мультивыбор) + ПОРОДА.
--
-- ПОДХОД (схема FINAL — только аддитивно):
--   • pool_requests += region_ids uuid[]   — мультивыбор областей (NULL/пусто = все).
--     Легаси region_id сохраняется для обратной совместимости (мягкий фолбэк).
--   • pool_lines    += breed_label text     — желаемая порода строки (NULL/'' = любая).
--   • accepted_categories JSON строки визарда МПК += breed (round-trip для UI).
--   • Порода партии — из batches.notes(JSON)->>'breed' (свободный текст визарда).
--     Сравнение нормализованное (fn_tsp_norm_breed): регистр/пробелы/пунктуация.
--   • Перевыпуск (CREATE OR REPLACE) торговых матч-RPC с добавленными предикатами
--     региона (fn_tsp_region_match) и породы (fn_tsp_breed_match).
--
-- Применять через Supabase Dashboard → SQL Editor. Идемпотентно (ADD COLUMN IF
-- NOT EXISTS + CREATE OR REPLACE). ЗАВИСИМОСТИ: 20260622120000_tsp_canonical_rebind.
-- ============================================================================


-- ── 1. Аддитивные колонки ────────────────────────────────────────────────────
alter table public.pool_requests add column if not exists region_ids uuid[];
alter table public.pool_lines    add column if not exists breed_label text;

comment on column public.pool_requests.region_ids is
    'Мультивыбор областей закупа МПК (regions.id уровня области). NULL/пусто = все
     области. Легаси region_id — обратная совместимость (мягкий фолбэк матчинга).';
comment on column public.pool_lines.breed_label is
    'Желаемая порода строки пула (свободный лейбл, сверяется с batches.notes breed
     через fn_tsp_norm_breed). NULL/пусто = любая порода.';


-- ── 2. Хелперы матчинга ──────────────────────────────────────────────────────

-- 2a. Нормализация породы: нижний регистр + отбрасывание всего, кроме букв/цифр.
-- «Ангус» = «ангус» = «Ангус ». «Смешанная/другая» = «смешаннаядругая».
create or replace function public.fn_tsp_norm_breed(p_breed text)
returns text
language sql
immutable
as $$
    select regexp_replace(lower(coalesce(p_breed, '')), '[^a-zа-яё0-9]', '', 'g');
$$;

-- 2b. Совпадение породы строки пула с породой партии. Пустой лейбл строки = любая.
create or replace function public.fn_tsp_breed_match(p_line_breed text, p_batch_breed text)
returns boolean
language sql
immutable
as $$
    select p_line_breed is null
        or btrim(p_line_breed) = ''
        or public.fn_tsp_norm_breed(p_line_breed) = public.fn_tsp_norm_breed(p_batch_breed);
$$;

-- 2c. Совпадение региона: мультивыбор (region_ids) в приоритете, иначе легаси
-- region_id (мягкий предикат канона). Область партии сверяется напрямую и через
-- parent_id (район → его область). Пусто/NULL = «все области».
create or replace function public.fn_tsp_region_match(
    p_region_ids uuid[], p_legacy_region uuid, p_batch_region uuid
)
returns boolean
language sql
stable
as $$
    select case
        when p_region_ids is not null and cardinality(p_region_ids) > 0 then
            p_batch_region = any (p_region_ids)
            or (select parent_id from public.regions where id = p_batch_region) = any (p_region_ids)
        else
            p_legacy_region is null
            or p_legacy_region = p_batch_region
            or p_legacy_region = (select parent_id from public.regions where id = p_batch_region)
    end;
$$;

revoke execute on function public.fn_tsp_norm_breed(text) from anon;
revoke execute on function public.fn_tsp_breed_match(text, text) from anon;
revoke execute on function public.fn_tsp_region_match(uuid[], uuid, uuid) from anon;


-- ── 3. rpc_self_create_pool_request — +p_region_ids (мультивыбор) ─────────────
-- Дроп старой 6-арг сигнатуры, чтобы не осталось overload-двойника (PGRST203).
drop function if exists public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text) cascade;

create or replace function public.rpc_self_create_pool_request(
    p_organization_id uuid,
    p_total_heads     int,
    p_target_month    date,
    p_region_id       uuid    default null,
    p_accepted_skus   jsonb   default '[]'::jsonb,
    p_notes           text    default null,
    p_region_ids      uuid[]  default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;
    if not (p_organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: organization not owned by current user' using errcode = 'P0001';
    end if;

    insert into public.pool_requests (
        organization_id, total_heads, target_month, region_id, region_ids,
        accepted_categories, notes, status
    ) values (
        p_organization_id, p_total_heads, p_target_month,
        -- легаси region_id: первый из мультивыбора, иначе явный одиночный
        coalesce(p_region_id, (case when p_region_ids is not null and cardinality(p_region_ids) > 0
                                    then p_region_ids[1] else null end)),
        nullif(p_region_ids, '{}'::uuid[]),
        coalesce(p_accepted_skus, '[]'::jsonb), p_notes, 'draft'
    ) returning id into v_id;
    return v_id;
end;
$$;
comment on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text, uuid[]) is
    'КАНОН d02 | Слайс 6 +аддитив мультирегион | МПК создаёт заявку. p_region_ids —
     мультивыбор областей (NULL/пусто = все); region_id хранит первую для легаси.
     accepted_categories хранит [{code,price,maxHeads,breed}] (round-trip UI; матч
     резолвит сорт по code, породу по breed). Гейт fn_my_org_ids.';
revoke execute on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text, uuid[]) from anon;
grant  execute on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text, uuid[]) to authenticated;


-- ── 4. rpc_self_activate_pool_request — breed_label в pool_lines + мультирегион ─
-- в pool_regions + жёсткий фильтр (порода+мультирегион) в свипе published-партий.
create or replace function public.rpc_self_activate_pool_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_req       public.pool_requests%rowtype;
    v_pool_id   uuid;
    v_batch     public.batches%rowtype;
    v_grade     text;
    v_vol       int;
    v_line      record;
    v_win_hours int;
    v_matched   int := 0;
    v_offered   int := 0;
    v_rid       uuid;
begin
    select * into v_req from public.pool_requests where id = p_request_id;
    if not found then raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool request not owned by current user' using errcode = 'P0001';
    end if;
    if v_req.status <> 'draft' then
        raise exception 'REQUEST_NOT_DRAFT' using errcode = 'P0003';
    end if;

    insert into public.pools (
        organization_id, pool_request_id, status, target_heads, matched_heads,
        filling_deadline, delivery_from, delivery_to, published_at
    ) values (
        v_req.organization_id, v_req.id, 'filling', v_req.total_heads, 0,
        (date_trunc('month', v_req.target_month) + interval '1 month - 1 day')::date,
        date_trunc('month', v_req.target_month)::date,
        (date_trunc('month', v_req.target_month) + interval '1 month - 1 day')::date,
        now()
    ) returning id into v_pool_id;

    -- Бид МПК → структурные pool_lines. breed_label из ln->>'breed' (пусто = любая).
    insert into public.pool_lines (
        pool_id, tsp_sku_id, category_label, breed_label, mpk_price_per_kg,
        max_volume_kg, current_volume_kg, is_active
    )
    select v_pool_id, null, ln->>'code', nullif(ln->>'breed', ''),
           round((ln->>'price')::numeric)::int, null, 0, true
    from jsonb_array_elements(coalesce(v_req.accepted_categories, '[]'::jsonb)) ln
    where coalesce(ln->>'price', '') <> ''
      and (ln->>'price')::numeric > 0;

    -- Перенос всех выбранных областей в pool_regions (видимость канон-путям).
    -- Мультивыбор region_ids в приоритете; иначе легаси region_id (одна область).
    if v_req.region_ids is not null and cardinality(v_req.region_ids) > 0 then
        foreach v_rid in array v_req.region_ids loop
            insert into public.pool_regions (pool_id, region_type, region_id)
            values (v_pool_id, 'oblast', v_rid)
            on conflict (pool_id, region_id) do nothing;
        end loop;
    elsif v_req.region_id is not null then
        insert into public.pool_regions (pool_id, region_type, region_id)
        values (v_pool_id, 'oblast', v_req.region_id)
        on conflict (pool_id, region_id) do nothing;
    end if;

    select offer_window_hours into v_win_hours from public.tsp_config where is_active = true limit 1;
    v_win_hours := coalesce(v_win_hours, 24);

    for v_batch in
        select b.* from public.batches b
        where b.status = 'published'
          and b.farmer_price_per_kg is not null
        order by b.created_at asc
        for update
    loop
        v_grade := public.fn_tsp_batch_grade(v_batch.id);
        if v_grade is null then continue; end if;
        v_vol := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;

        -- 1) Прямой матч: бид >= ask, сорт=, окно, ёмкость, РЕГИОН(мультивыбор), ПОРОДА.
        select pl.id              as pl_id,
               pl.pool_id          as pool_id,
               pl.mpk_price_per_kg as bid,
               p.target_heads      as target_heads,
               p.matched_heads     as matched_heads
          into v_line
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.pool_id = v_pool_id
          and p.status = 'filling'
          and pl.is_active = true
          and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and public.fn_tsp_region_match(v_req.region_ids, v_req.region_id, v_batch.region_id)
        order by pl.mpk_price_per_kg desc
        limit 1
        for update;

        if found then
            update public.batches
            set status            = 'matched',
                pool_line_id      = v_line.pl_id,
                deal_price_per_kg = v_line.bid,
                matched_at        = now(),
                updated_at        = now()
            where id = v_batch.id;

            update public.pool_lines
            set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
            where id = v_line.pl_id;

            update public.pools
            set matched_heads = matched_heads + v_batch.heads, updated_at = now()
            where id = v_pool_id;

            update public.offers set status = 'withdrawn', responded_at = now()
            where batch_id = v_batch.id and status = 'pending';

            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            values (v_batch.id, 'matched',
                jsonb_build_object('pool_id', v_pool_id, 'pool_line_id', v_line.pl_id,
                                   'via', 'pool_activate_sweep', 'deal_price_per_kg', v_line.bid),
                public.fn_current_user_id());

            v_matched := v_matched + 1;

            if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
                update public.pools
                set status = 'closed_filled', completed_at = now(),
                    mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
                where id = v_pool_id and status = 'filling';
                update public.batches b
                set status = 'confirmed', confirmed_at = now(), updated_at = now()
                from public.pool_lines pl
                where pl.pool_id = v_pool_id and b.pool_line_id = pl.id and b.status = 'matched';
                exit;
            end if;
            continue;
        end if;

        -- 2) Нет прямого матча → broadcast-оффер (сорт+РЕГИОН+ПОРОДА+окно+ёмкость).
        perform 1
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.pool_id = v_pool_id
          and p.status = 'filling'
          and pl.is_active = true
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and public.fn_tsp_region_match(v_req.region_ids, v_req.region_id, v_batch.region_id)
        limit 1;

        if found then
            insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
            values (v_batch.id, v_req.organization_id, v_batch.farmer_price_per_kg, 'pending',
                    now() + make_interval(hours => v_win_hours), now())
            on conflict (batch_id, mpk_org_id) do update
                set offered_price_per_kg = excluded.offered_price_per_kg,
                    status = 'pending', expires_at = excluded.expires_at,
                    responded_at = null, responded_by = null;

            update public.batches
            set status = 'offering', offering_at = now(), updated_at = now()
            where id = v_batch.id and status = 'published';

            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            values (v_batch.id, 'broadcast_sent',
                jsonb_build_object('trigger', 'pool_activate_sweep', 'pool_id', v_pool_id),
                public.fn_current_user_id());

            v_offered := v_offered + 1;
        end if;
    end loop;

    update public.pool_requests
    set status = 'active', activated_at = now(), updated_at = now()
    where id = p_request_id;

    return jsonb_build_object(
        'request_id', p_request_id, 'pool_id', v_pool_id,
        'sweptMatched', v_matched, 'sweptOffered', v_offered
    );
end;
$$;
comment on function public.rpc_self_activate_pool_request(uuid) is
    'КАНОН d02 +аддитив | Заявка(draft)→Pool(filling). pool_lines.breed_label из
     accepted_categories breed; все region_ids → pool_regions. Свип published-партий:
     жёсткий фильтр сорт+цена+окно+ёмкость+РЕГИОН(мультивыбор)+ПОРОДА → matched, иначе
     broadcast-оффер. Гейт fn_my_org_ids через pool_requests.';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;


-- ── 5. rpc_self_auto_match_batch — жёсткий фильтр порода+мультирегион ──────────
create or replace function public.rpc_self_auto_match_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch     public.batches%rowtype;
    v_grade     text;
    v_vol       int;
    v_line      record;
    v_win_hours int;
    v_offers    int := 0;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;
    if v_batch.status <> 'published' then
        return jsonb_build_object('matched', false, 'reason', 'BATCH_NOT_AVAILABLE');
    end if;
    if v_batch.farmer_price_per_kg is null then
        return jsonb_build_object('matched', false, 'reason', 'NO_ASK');
    end if;

    v_grade := public.fn_tsp_batch_grade(p_batch_id);
    v_vol   := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;

    -- 1) Прямой авто-матч: высший бид >= ask, сорт=, окно, РЕГИОН(мультивыбор),
    -- ПОРОДА, ёмкость. deal = бид.
    select pl.id              as pl_id,
           pl.pool_id          as pool_id,
           pl.mpk_price_per_kg as bid,
           p.target_heads      as target_heads,
           p.matched_heads     as matched_heads
      into v_line
    from public.pool_lines pl
    join public.pools p          on p.id = pl.pool_id
    join public.pool_requests pr on pr.id = p.pool_request_id
    where p.status = 'filling'
      and pl.is_active = true
      and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
      and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
      and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
      and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
      and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
      and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
    order by pl.mpk_price_per_kg desc, p.created_at asc
    limit 1
    for update;

    if found then
        update public.batches
        set status            = 'matched',
            pool_line_id      = v_line.pl_id,
            deal_price_per_kg = v_line.bid,
            matched_at        = now(),
            updated_at        = now()
        where id = v_batch.id;

        update public.pool_lines
        set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
        where id = v_line.pl_id;

        update public.pools
        set matched_heads = matched_heads + v_batch.heads, updated_at = now()
        where id = v_line.pool_id;

        if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
            update public.pools
            set status = 'closed_filled', completed_at = now(),
                mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
            where id = v_line.pool_id and status = 'filling';
            if found then
                update public.batches b
                set status = 'confirmed', confirmed_at = now(), updated_at = now()
                from public.pool_lines pl
                where pl.pool_id = v_line.pool_id and b.pool_line_id = pl.id and b.status = 'matched';
            end if;
        end if;

        update public.offers set status = 'withdrawn', responded_at = now()
        where batch_id = v_batch.id and status = 'pending';

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch.id, 'matched',
            jsonb_build_object('pool_id', v_line.pool_id, 'pool_line_id', v_line.pl_id,
                               'via', 'auto_match', 'deal_price_per_kg', v_line.bid),
            public.fn_current_user_id());

        return jsonb_build_object(
            'matched', true, 'poolId', v_line.pool_id, 'poolLineId', v_line.pl_id,
            'matchedHeads', v_batch.heads, 'dealPrice', v_line.bid
        );
    end if;

    -- 2) Нет прямого матча → broadcast (сорт+РЕГИОН+ПОРОДА+окно+ёмкость; цена игнор).
    select offer_window_hours into v_win_hours from public.tsp_config where is_active = true limit 1;
    v_win_hours := coalesce(v_win_hours, 24);

    with eligible_mpks as (
        select distinct p.organization_id as mpk_org_id
        from public.pool_lines pl
        join public.pools p          on p.id = pl.pool_id
        join public.pool_requests pr on pr.id = p.pool_request_id
        where p.status = 'filling'
          and pl.is_active = true
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
    ),
    upserted as (
        insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
        select v_batch.id, em.mpk_org_id, v_batch.farmer_price_per_kg, 'pending',
               now() + make_interval(hours => v_win_hours), now()
        from eligible_mpks em
        on conflict (batch_id, mpk_org_id) do update
            set offered_price_per_kg = excluded.offered_price_per_kg,
                status = 'pending', expires_at = excluded.expires_at,
                responded_at = null, responded_by = null
        returning batch_id
    )
    select count(*) into v_offers from upserted;

    if v_offers > 0 then
        update public.batches
        set status = 'offering', offering_at = now(), updated_at = now()
        where id = v_batch.id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch.id, 'broadcast_sent',
            jsonb_build_object('trigger', 'auto_match', 'offers', v_offers),
            public.fn_current_user_id());

        return jsonb_build_object('matched', false, 'reason', 'BROADCAST', 'offers', v_offers);
    end if;

    return jsonb_build_object('matched', false, 'reason', 'NO_POOL');
end;
$$;
comment on function public.rpc_self_auto_match_batch(uuid) is
    'КАНОН d02 +аддитив | Авто-матч при публикации: высший бид >= ask → matched;
     иначе broadcast. Жёсткий фильтр: сорт+цена+окно+ёмкость+РЕГИОН(мультивыбор)+ПОРОДА.
     Контакты НЕ раскрываются (D40).';
revoke execute on function public.rpc_self_auto_match_batch(uuid) from anon;
grant  execute on function public.rpc_self_auto_match_batch(uuid) to authenticated;


-- ── 6. rpc_self_match_batch_to_pool — ручной матч МПК + фильтр породы ──────────
create or replace function public.rpc_self_match_batch_to_pool(
    p_pool_id uuid, p_batch_id uuid, p_matched_heads int, p_price_per_kg int default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool   public.pools%rowtype;
    v_batch  public.batches%rowtype;
    v_grade  text;
    v_line   record;
    v_deal   int;
    v_vol    int;
    v_heads  int;
begin
    select * into v_pool from public.pools where id = p_pool_id for update;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_pool.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;
    if v_pool.status <> 'filling' then
        raise exception 'POOL_NOT_FILLING' using errcode = 'P0003';
    end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0004'; end if;
    if v_batch.status not in ('published', 'offering') then
        raise exception 'BATCH_NOT_AVAILABLE' using errcode = 'P0005';
    end if;

    v_grade := public.fn_tsp_batch_grade(p_batch_id);
    v_vol   := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;
    v_heads := coalesce(p_matched_heads, v_batch.heads);

    -- строка пула под сорт+ПОРОДУ партии (жёсткий фильтр; фолбэк-бид)
    select pl.id as pl_id, pl.mpk_price_per_kg as bid
      into v_line
    from public.pool_lines pl
    where pl.pool_id = p_pool_id
      and pl.is_active = true
      and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
      and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
    order by pl.mpk_price_per_kg desc
    limit 1
    for update;
    if not found then
        raise exception 'NO_MATCHING_LINE: pool has no active line for batch grade/breed %', v_grade
            using errcode = 'P0006';
    end if;

    v_deal := coalesce(p_price_per_kg, v_line.bid);
    if v_batch.farmer_price_per_kg is not null and v_deal < v_batch.farmer_price_per_kg then
        raise exception 'BID_BELOW_ASK: bid % < farmer ask %', v_deal, v_batch.farmer_price_per_kg
            using errcode = 'P0007';
    end if;

    update public.batches
    set status = 'matched', pool_line_id = v_line.pl_id, deal_price_per_kg = v_deal,
        matched_at = now(), updated_at = now()
    where id = p_batch_id;

    update public.pool_lines
    set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
    where id = v_line.pl_id;

    update public.pools
    set matched_heads = matched_heads + v_heads, updated_at = now()
    where id = p_pool_id;

    update public.offers set status = 'withdrawn', responded_at = now()
    where batch_id = p_batch_id and status = 'pending';

    if (v_pool.matched_heads + v_heads) >= v_pool.target_heads then
        update public.pools set status = 'closed_filled', completed_at = now(),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
        where id = p_pool_id and status = 'filling';
        if found then
            update public.batches b
            set status = 'confirmed', confirmed_at = now(), updated_at = now()
            from public.pool_lines pl
            where pl.pool_id = p_pool_id and b.pool_line_id = pl.id and b.status = 'matched';
        end if;
    end if;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'matched',
        jsonb_build_object('pool_id', p_pool_id, 'pool_line_id', v_line.pl_id,
                           'via', 'manual_match', 'deal_price_per_kg', v_deal),
        public.fn_current_user_id());

    return v_line.pl_id;
end;
$$;
comment on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) is
    'КАНОН d02 +аддитив | Ручной матч МПК: published|offering-партию → matched при
     p_price_per_kg (>= ask). Строка пула резолвится по сорту И ПОРОДЕ партии.
     auto-close по головам → confirmed. Гейт pools.organization_id.';
revoke execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) from anon;
grant  execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) to authenticated;


-- ── 7. rpc_self_accept_offer — жёсткий фильтр порода+мультирегион ──────────────
create or replace function public.rpc_self_accept_offer(p_offer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_offer public.offers%rowtype;
    v_batch public.batches%rowtype;
    v_grade text;
    v_vol   int;
    v_line  record;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_offer from public.offers where id = p_offer_id for update;
    if not found then raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_offer.mpk_org_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: offer belongs to another MPK' using errcode = 'P0001';
    end if;
    if v_offer.status <> 'pending' then
        raise exception 'INVALID_STATUS: offer is %', v_offer.status using errcode = 'P0003';
    end if;
    if v_offer.expires_at < now() then
        update public.offers set status = 'expired' where id = p_offer_id;
        raise exception 'OFFER_EXPIRED' using errcode = 'P0004';
    end if;

    select * into v_batch from public.batches where id = v_offer.batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0005'; end if;
    if v_batch.status <> 'offering' then
        raise exception 'INVALID_STATUS: batch is % (must be offering)', v_batch.status using errcode = 'P0006';
    end if;

    v_grade := public.fn_tsp_batch_grade(v_batch.id);
    v_vol   := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;

    -- лучшая строка МПК: бид >= offered ask, сорт/окно/РЕГИОН(мультивыбор)/ПОРОДА/ёмкость
    select pl.id as pl_id, pl.pool_id as pool_id, pl.mpk_price_per_kg as bid,
           p.target_heads as target_heads, p.matched_heads as matched_heads
      into v_line
    from public.pool_lines pl
    join public.pools p          on p.id = pl.pool_id
    join public.pool_requests pr on pr.id = p.pool_request_id
    where p.status = 'filling'
      and p.organization_id = v_offer.mpk_org_id
      and pl.is_active = true
      and pl.mpk_price_per_kg >= v_offer.offered_price_per_kg
      and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
      and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
      and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
      and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
      and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
    order by pl.mpk_price_per_kg desc
    limit 1
    for update;
    if not found then
        raise exception 'NO_MATCHING_POOL_LINE: raise a pool line bid >= ask % first', v_offer.offered_price_per_kg
            using errcode = 'P0007';
    end if;

    update public.offers
    set status = 'accepted', responded_at = now(), responded_by = public.fn_current_user_id()
    where id = p_offer_id;
    update public.offers
    set status = 'withdrawn', responded_at = now()
    where batch_id = v_offer.batch_id and id <> p_offer_id and status = 'pending';

    update public.batches
    set status = 'matched', pool_line_id = v_line.pl_id, deal_price_per_kg = v_line.bid,
        matched_at = now(), updated_at = now()
    where id = v_batch.id;

    update public.pool_lines
    set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
    where id = v_line.pl_id;

    update public.pools
    set matched_heads = matched_heads + v_batch.heads, updated_at = now()
    where id = v_line.pool_id;

    if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
        update public.pools set status = 'closed_filled', completed_at = now(),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
        where id = v_line.pool_id and status = 'filling';
        if found then
            update public.batches b
            set status = 'confirmed', confirmed_at = now(), updated_at = now()
            from public.pool_lines pl
            where pl.pool_id = v_line.pool_id and b.pool_line_id = pl.id and b.status = 'matched';
        end if;
    end if;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (v_batch.id, 'offer_accepted',
        jsonb_build_object('offer_id', p_offer_id, 'pool_id', v_line.pool_id,
                           'pool_line_id', v_line.pl_id, 'deal_price_per_kg', v_line.bid),
        public.fn_current_user_id());

    return jsonb_build_object('batchId', v_batch.id, 'poolId', v_line.pool_id,
                              'poolLineId', v_line.pl_id, 'dealPrice', v_line.bid);
end;
$$;
comment on function public.rpc_self_accept_offer(uuid) is
    'КАНОН d02 +аддитив | МПК принимает broadcast-оффер (FCFS): offering → matched.
     Строка пула: бид >= offered ask, сорт+окно+РЕГИОН(мультивыбор)+ПОРОДА+ёмкость.
     Гейт offer.mpk_org_id ∈ fn_my_org_ids().';
revoke execute on function public.rpc_self_accept_offer(uuid) from anon;
grant  execute on function public.rpc_self_accept_offer(uuid) to authenticated;
