-- AgOS · БЕТА · Слайс 7 · Аддитив: ЖЁСТКИЙ матч по району + единая формула сорта.
-- ============================================================================
-- КОНТЕКСТ / ТРЕБОВАНИЕ (CEO, 2026-07-01):
--   (1) МАТЧ ПО РАЙОНУ. Раньше матчинг был на уровне ОБЛАСТИ — МПК не мог целиться
--       в конкретные районы, а «без района 100% матча не будет». Теперь МПК при
--       закупке выбирает область(и) → район(ы) в шторке. Матч ЖЁСТКИЙ: если у пула
--       выбраны районы — партия матчится только если её район входит в список.
--       Пусто = вся область (район не ограничивает). Район партии = district_id её
--       организации-фермера (заполняется при регистрации/через админку, слаг).
--   (2) ЕДИНАЯ ФОРМУЛА СОРТА. Сорт (Премиум/Высшая/Первая/Вторая → VS/S/NS)
--       определяется по УПИТАННОСТИ (+порода/вес/возраст как модификатор Премиум).
--       Одна логика на фронте (фермер видит сорт в визарде) И в бэкенде (матч):
--         Хорошая      → VS  (Высшая; Премиум если элитная порода и вес ≥ 450)
--         Средняя      → S   (Первая)
--         Ниже средней → NS  (Вторая)
--       Упитанность становится ОСНОВОЙ сорта: rpc_create_batch пишет
--       batches.grade_standard_id по формуле (фолбэк на grade SKU, если упитанность
--       не распознана). fn_tsp_batch_grade уже отдаёт приоритет grade_standard_id —
--       матч автоматически согласован с тем, что видит фермер.
--
-- ПОДХОД (схема FINAL — только аддитивно):
--   • pool_requests += district_ids text[]  — выбор районов (слаги). NULL/пусто = вся
--     область. Легаси/мультирегион (region_ids) остаётся — район уточняет внутри.
--   • fn_tsp_district_match(text[], uuid) — предикат: у партии район = org.district_id;
--     пусто у пула = любой район. Жёсткий: заданы районы → район партии обязан входить.
--   • fn_tsp_grade_id_from_fatness(text) — упитанность → grade_standards.id (VS/S/NS).
--   • Перевыпуск (CREATE OR REPLACE) rpc_create_batch (grade из упитанности) и
--     торговых матч-RPC (activate-свип / auto-match / accept-offer) с +предикатом района.
--     Ручной матч (rpc_self_match_batch_to_pool) НЕ трогаем — это осознанный выбор МПК.
--
-- Применять через Supabase Dashboard → SQL Editor. Идемпотентно (ADD COLUMN IF NOT
-- EXISTS + CREATE OR REPLACE). ЗАВИСИМОСТИ: 20260701120000_tsp_breed_multiregion_match,
-- 20260701140000_org_district (organizations.district_id).
-- ============================================================================


-- ── 1. Аддитивная колонка: выбор районов у заявки МПК ─────────────────────────
alter table public.pool_requests add column if not exists district_ids text[];

comment on column public.pool_requests.district_ids is
    'Выбор районов закупа МПК (слаги DISTRICTS фронта, сверяются с
     organizations.district_id фермера). NULL/пусто = вся область (район не
     ограничивает). Жёсткий матч: заданы районы → район партии обязан входить.';


-- ── 2. Хелперы ────────────────────────────────────────────────────────────────

-- 2a. Совпадение района: пусто у пула = любой район (в рамках выбранных областей).
-- Иначе ЖЁСТКО: район партии (organizations.district_id её фермера) обязан входить
-- в список. Партия без района при заданном фильтре районов НЕ проходит (hard).
create or replace function public.fn_tsp_district_match(
    p_district_ids text[], p_batch_org uuid
)
returns boolean
language sql
stable
as $$
    select p_district_ids is null
        or cardinality(p_district_ids) = 0
        or (select o.district_id from public.organizations o where o.id = p_batch_org)
             = any (p_district_ids);
$$;

-- 2b. Упитанность → grade_standards.id (VS/S/NS). Единая формула сорта (основа —
-- упитанность). NULL, если упитанность не распознана → вызывающий фолбэчит на
-- grade SKU. Нормализация: регистр/пробелы/пунктуация («ниже средней» = «Ниже средней»).
create or replace function public.fn_tsp_grade_id_from_fatness(p_fatness text)
returns uuid
language sql
stable
as $$
    select gs.id
    from public.grade_standards gs
    where gs.code = case regexp_replace(lower(coalesce(p_fatness, '')), '[^a-zа-яё]', '', 'g')
        when 'хорошая'     then 'VS'
        when 'средняя'     then 'S'
        when 'нижесредней' then 'NS'
        else null
    end
    limit 1;
$$;

revoke execute on function public.fn_tsp_district_match(text[], uuid) from anon;
revoke execute on function public.fn_tsp_grade_id_from_fatness(text) from anon;


-- ── 3. rpc_create_batch — grade_standard_id по формуле упитанности ─────────────
-- Единственное изменение против 20260625120000: v_grade_id берётся из упитанности
-- (фолбэк на grade SKU). fn_tsp_batch_grade отдаёт приоритет grade_standard_id →
-- матч согласован с сортом, который фермер видит в визарде (deriveMpkGrade).
create or replace function public.rpc_create_batch(
    p_cat         text,
    p_breed       text,
    p_heads       int,
    p_avg_weight  numeric,
    p_age         int,
    p_fatness     text,
    p_district    text,
    p_price       numeric,
    p_window_from date,
    p_window_to   date,
    p_scheduled   boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_org_id    uuid;
    v_sku_id    uuid;
    v_grade_id  uuid;
    v_region_id uuid;
    v_batch_id  uuid;
    v_status    text;
    v_notes     text;
begin
    v_org_id := (public.fn_my_org_ids())[1];
    if v_org_id is null then
        raise exception 'ORG_NOT_FOUND' using errcode = 'P0001';
    end if;

    v_sku_id    := public.fn_tsp_resolve_sku(p_cat, p_breed, p_age, p_avg_weight);
    v_region_id := public.fn_tsp_region_id(p_district);
    if v_region_id is null then
        select region_id into v_region_id from public.organizations where id = v_org_id;
    end if;

    -- ЕДИНАЯ ФОРМУЛА СОРТА (2026-07-01): grade из упитанности; фолбэк — grade SKU
    -- (когда упитанность не задана/не распознана). fn_tsp_batch_grade приоритезирует
    -- grade_standard_id → тот же сорт, что фронт показывает фермеру (deriveMpkGrade).
    v_grade_id := coalesce(
        public.fn_tsp_grade_id_from_fatness(p_fatness),
        (select grade_id from public.tsp_skus where id = v_sku_id)
    );

    v_status := case when p_scheduled then 'draft' else 'published' end;

    if p_window_from is not null and p_window_to is not null and p_window_to < p_window_from then
        raise exception 'INVALID_WINDOW: ready_to before ready_from' using errcode = 'P0001';
    end if;

    v_notes := jsonb_build_object(
        'cat',       p_cat,
        'breed',     p_breed,
        'age',       p_age,
        'fatness',   p_fatness,
        'district',  p_district,
        'wf',        to_char(p_window_from, 'YYYY-MM-DD'),
        'wt',        to_char(p_window_to,   'YYYY-MM-DD'),
        'scheduled', coalesce(p_scheduled, false)
    )::text;

    insert into public.batches (
        organization_id, tsp_sku_id, grade_standard_id, breed_id,
        heads, avg_weight_kg, target_month, region_id,
        farmer_price_per_kg, ready_from, ready_to,
        status, notes, published_at, created_by, created_at
    ) values (
        v_org_id, v_sku_id, v_grade_id, null,
        p_heads, p_avg_weight, date_trunc('month', p_window_from)::date, v_region_id,
        case when p_price is not null and p_price > 0 then round(p_price)::int else null end,
        p_window_from, p_window_to,
        v_status, v_notes,
        case when v_status = 'published' then now() else null end,
        public.fn_current_user_id(), now()
    )
    returning id into v_batch_id;

    return public.fn_tsp_batch_json(v_batch_id);
end;
$$;
comment on function public.rpc_create_batch(text, text, int, numeric, int, text, text, numeric, date, date, boolean) is
    'КАНОН d02 +аддитив Слайс 7 | Адаптер визарда. grade_standard_id из УПИТАННОСТИ
     (fn_tsp_grade_id_from_fatness; фолбэк grade SKU) — единая формула сорта с фронтом.
     p_price → farmer_price_per_kg; окно → ready_from/ready_to; поля визарда → notes(JSON).';
revoke execute on function public.rpc_create_batch(text, text, int, numeric, int, text, text, numeric, date, date, boolean) from anon;
grant  execute on function public.rpc_create_batch(text, text, int, numeric, int, text, text, numeric, date, date, boolean) to authenticated;


-- ── 4. rpc_self_create_pool_request — +p_district_ids (районы) ─────────────────
-- Дроп 7-арг сигнатуры (без district), чтобы не осталось overload-двойника.
drop function if exists public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text, uuid[]) cascade;

create or replace function public.rpc_self_create_pool_request(
    p_organization_id uuid,
    p_total_heads     int,
    p_target_month    date,
    p_region_id       uuid    default null,
    p_accepted_skus   jsonb   default '[]'::jsonb,
    p_notes           text    default null,
    p_region_ids      uuid[]  default null,
    p_district_ids    text[]  default null
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
        district_ids, accepted_categories, notes, status
    ) values (
        p_organization_id, p_total_heads, p_target_month,
        coalesce(p_region_id, (case when p_region_ids is not null and cardinality(p_region_ids) > 0
                                    then p_region_ids[1] else null end)),
        nullif(p_region_ids, '{}'::uuid[]),
        nullif(p_district_ids, '{}'::text[]),
        coalesce(p_accepted_skus, '[]'::jsonb), p_notes, 'draft'
    ) returning id into v_id;
    return v_id;
end;
$$;
comment on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text, uuid[], text[]) is
    'КАНОН d02 +аддитив Слайс 7 | МПК создаёт заявку. p_region_ids — мультивыбор
     областей (пусто = все); p_district_ids — районы (слаги; пусто = вся область,
     иначе ЖЁСТКИЙ матч по району). accepted_categories = [{code,price,maxHeads,breed}].';
revoke execute on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text, uuid[], text[]) from anon;
grant  execute on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text, uuid[], text[]) to authenticated;


-- ── 5. rpc_self_activate_pool_request — +предикат района в свипе ───────────────
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

    insert into public.pool_lines (
        pool_id, tsp_sku_id, category_label, breed_label, mpk_price_per_kg,
        max_volume_kg, current_volume_kg, is_active
    )
    select v_pool_id, null, ln->>'code', nullif(ln->>'breed', ''),
           round((ln->>'price')::numeric)::int, null, 0, true
    from jsonb_array_elements(coalesce(v_req.accepted_categories, '[]'::jsonb)) ln
    where coalesce(ln->>'price', '') <> ''
      and (ln->>'price')::numeric > 0;

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

        -- 1) Прямой матч: бид >= ask, сорт=, окно, ёмкость, РЕГИОН, РАЙОН(жёсткий), ПОРОДА.
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
          and public.fn_tsp_district_match(v_req.district_ids, v_batch.organization_id)
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

        -- 2) Нет прямого матча → broadcast-оффер (сорт+РЕГИОН+РАЙОН+ПОРОДА+окно+ёмкость).
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
          and public.fn_tsp_district_match(v_req.district_ids, v_batch.organization_id)
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
    'КАНОН d02 +аддитив Слайс 7 | Заявка(draft)→Pool(filling). Свип published-партий:
     жёсткий фильтр сорт+цена+окно+ёмкость+РЕГИОН+РАЙОН(district_ids)+ПОРОДА → matched,
     иначе broadcast-оффер. Гейт fn_my_org_ids через pool_requests.';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;


-- ── 6. rpc_self_auto_match_batch — +предикат района ───────────────────────────
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

    -- 1) Прямой авто-матч: высший бид >= ask, сорт=, окно, РЕГИОН, РАЙОН(жёсткий), ПОРОДА, ёмкость.
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
      and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
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

    -- 2) Нет прямого матча → broadcast (сорт+РЕГИОН+РАЙОН+ПОРОДА+окно+ёмкость; цена игнор).
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
          and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
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
    'КАНОН d02 +аддитив Слайс 7 | Авто-матч при публикации: высший бид >= ask → matched;
     иначе broadcast. Жёсткий фильтр: сорт+цена+окно+ёмкость+РЕГИОН+РАЙОН(district_ids)+ПОРОДА.';
revoke execute on function public.rpc_self_auto_match_batch(uuid) from anon;
grant  execute on function public.rpc_self_auto_match_batch(uuid) to authenticated;


-- ── 7. rpc_self_accept_offer — +предикат района ───────────────────────────────
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

    -- лучшая строка МПК: бид >= offered ask, сорт/окно/РЕГИОН/РАЙОН(жёсткий)/ПОРОДА/ёмкость
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
      and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
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
    'КАНОН d02 +аддитив Слайс 7 | МПК принимает broadcast-оффер (FCFS): offering → matched.
     Строка пула: бид >= offered ask, сорт+окно+РЕГИОН+РАЙОН(district_ids)+ПОРОДА+ёмкость.';
revoke execute on function public.rpc_self_accept_offer(uuid) from anon;
grant  execute on function public.rpc_self_accept_offer(uuid) to authenticated;
