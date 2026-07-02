-- AgOS · БЕТА · Слайс 9 · ДРОБЛЕНИЕ БАТЧА НА ЧАСТИ (partial batch splitting).
-- ============================================================================
-- ФИЧА (CEO, 2026-07-02, /feature G2 approved):
--   Батч фермера теперь продаётся ЧАСТЯМИ, а не только целиком. Пример: пул 100
--   (50 Ангус + 50 Аулиеколь), в строке Ангус свободно 30 → партия 60 Ангус
--   больше НЕ отклоняется целиком: 30 голов уходят в строку, остаток 30 остаётся
--   на рынке и матчится дальше (в другой пул / broadcast).
--
-- РЕШЕНИЯ (G2):
--   • Минимум дробления — ФИКС. в tsp_config.min_split_heads (default 5). Кусок
--     обязан быть >= min, и остаток либо 0, либо >= min (нет неликвидных огрызков).
--     Продажа ВСЕГО остатка целиком разрешена всегда (даже если он < min).
--   • Контакт раскрывается ПО КАЖДОМУ КУСКУ — источник = строка batch_allocations
--     (её появление = сделка на этот кусок; читается фронтом S2). D40 соблюдён.
--
-- МОДЕЛЬ (схема FINAL — только аддитивно, старые данные не ломаем HS-2):
--   • НОВАЯ таблица batch_allocations — источник правды «кому и сколько продано».
--     Одна строка = один проданный кусок батча (batch × pool_line × heads × price).
--   • batches += matched_heads (сумма активных кусков; remaining = heads - matched).
--   • batches.status += 'partially_matched' (часть продана, остаток на рынке).
--   • tsp_config += min_split_heads.
--   • pool_lines.current_heads (уже есть, Слайс 8b) инкрементится РАЗМЕРОМ КУСКА.
--   • Старые batches.pool_line_id / deal_price_per_kg СОХРАНЯЮТСЯ (legacy: пишем по
--     первому куску для обратной совместимости старого фронта до S2).
--   • fn_tsp_alloc_chunk() — единый аллокатор куска (take-расчёт + min-правило +
--     инкременты + FSM батча + доборка/закрытие пула). 4 матч-RPC зовут его в цикле.
--
--   Сигнатуры RPC не меняются (P7). Идемпотентно. Зависимости:
--   20260702140000 (per-line max_heads/current_heads), 20260702120000, 20260701150000,
--   20260701120000, 20260622120000 (fn_tsp_* helpers). Применять через SQL Editor.
-- ============================================================================


-- ── 0. tsp_config += min_split_heads (фикс. минимум куска) ────────────────────
alter table public.tsp_config
    add column if not exists min_split_heads int not null default 5;
alter table public.tsp_config drop constraint if exists chk_tsp_config_min_split_heads;
alter table public.tsp_config add  constraint chk_tsp_config_min_split_heads check (min_split_heads > 0);
comment on column public.tsp_config.min_split_heads is
    'Слайс 9: минимальный размер куска при дроблении батча (голов). Кусок >= min и
     остаток либо 0, либо >= min. Продажа всего остатка целиком разрешена всегда.';


-- ── 1. batches += matched_heads + статус partially_matched ────────────────────
alter table public.batches
    add column if not exists matched_heads int not null default 0;
alter table public.batches drop constraint if exists chk_batches_matched_heads;
alter table public.batches add  constraint chk_batches_matched_heads
    check (matched_heads >= 0 and matched_heads <= heads);
comment on column public.batches.matched_heads is
    'Слайс 9: сумма голов по активным batch_allocations. remaining = heads - matched_heads.
     0 = ничего не продано; = heads → полностью продан (matched); между → partially_matched.';

-- Расширяем CHECK статуса: + partially_matched. Канон d02 = constraint batches_status_check
-- с ПОЛНЫМ набором (draft/scheduled/published/offering/awaiting_price_decision/matched/
-- confirmed/dispatched/delivered/cancelled/failed/expired). Пересобираем с тем же набором
-- + partially_matched — иначе существующие строки этих статусов отвалятся.
alter table public.batches drop constraint if exists batches_status_check;
alter table public.batches add  constraint batches_status_check check (status in (
    'draft', 'scheduled', 'published', 'offering', 'awaiting_price_decision',
    'matched', 'partially_matched',   -- Слайс 9: часть продана, остаток на рынке
    'confirmed', 'dispatched', 'delivered', 'cancelled', 'failed', 'expired'
));


-- ── 2. НОВАЯ таблица batch_allocations (кусок = сделка) ───────────────────────
create table if not exists public.batch_allocations (
    id            uuid primary key default gen_random_uuid(),
    batch_id      uuid not null references public.batches(id) on delete cascade,
    pool_line_id  uuid not null references public.pool_lines(id),
    pool_id       uuid not null references public.pools(id),
    heads         int  not null check (heads > 0),
    price_per_kg  int  not null check (price_per_kg > 0),
    status        text not null default 'matched'
                       check (status in ('matched','confirmed','cancelled')),
    via           text,          -- канал матча: auto_match|pool_activate_sweep|offer_accept|manual_match
    matched_at    timestamptz not null default now(),
    confirmed_at  timestamptz,
    cancelled_at  timestamptz,
    created_by    uuid references public.users(id),
    created_at    timestamptz not null default now()
);
comment on table public.batch_allocations is
    'Слайс 9: одна строка = один проданный КУСОК батча (партия дробится между покупателями).
     Источник правды «кому и сколько продано» + триггер раскрытия контакта по куску (D40).
     batches.matched_heads = SUM(heads) активных (matched|confirmed) аллокаций батча.';

create index if not exists idx_batch_alloc_batch   on public.batch_allocations (batch_id);
create index if not exists idx_batch_alloc_line    on public.batch_allocations (pool_line_id);
create index if not exists idx_batch_alloc_pool    on public.batch_allocations (pool_id);
create index if not exists idx_batch_alloc_status  on public.batch_allocations (status);

alter table public.batch_allocations enable row level security;

-- Фермер видит аллокации своих батчей (кому продал куски + контакты через S2).
drop policy if exists batch_alloc_farmer_read on public.batch_allocations;
create policy batch_alloc_farmer_read on public.batch_allocations for select
    using (batch_id in (
        select id from public.batches where organization_id = any (public.fn_my_org_ids())
    ));
-- МПК видит аллокации в своих пулах (что набралось в строки).
drop policy if exists batch_alloc_mpk_read on public.batch_allocations;
create policy batch_alloc_mpk_read on public.batch_allocations for select
    using (pool_id in (
        select id from public.pools where organization_id = any (public.fn_my_org_ids())
    ));
-- Запись — только через security-definer RPC (аллокатор). Прямых INSERT/UPDATE-политик нет.


-- ── 3. fn_tsp_alloc_chunk — единый аллокатор куска ────────────────────────────
-- Берёт из батча кусок в конкретную строку пула: take = min(remaining, свободно_строки,
-- свободно_пула, свободно_по_kg [, p_max_heads]). Правило минимума (только для авто,
-- p_max_heads is null): кусок >= min и остаток либо 0, либо >= min; продажа ВСЕГО
-- остатка целиком разрешена всегда. Возвращает фактически взятые головы (0 = ничего).
create or replace function public.fn_tsp_alloc_chunk(
    p_batch_id     uuid,
    p_pool_line_id uuid,
    p_via          text,
    p_created_by   uuid    default null,
    p_max_heads    int     default null,   -- явный кап (manual). null = взять сколько влезет
    p_price        int     default null    -- override цены (manual). null = бид строки
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch     public.batches%rowtype;
    v_pl        public.pool_lines%rowtype;
    v_pool      public.pools%rowtype;
    v_min       int;
    v_remaining int;
    v_line_free int;
    v_pool_free int;
    v_kg_free   int;
    v_free      int;
    v_take      int;
    v_price     int;
    v_vol       int;
    v_full      boolean;
begin
    select * into v_batch from public.batches   where id = p_batch_id     for update;
    if not found then return 0; end if;
    select * into v_pl    from public.pool_lines where id = p_pool_line_id for update;
    if not found or not v_pl.is_active then return 0; end if;
    select * into v_pool  from public.pools     where id = v_pl.pool_id    for update;
    if not found or v_pool.status <> 'filling' then return 0; end if;

    v_remaining := v_batch.heads - v_batch.matched_heads;
    if v_remaining <= 0 then return 0; end if;

    v_line_free := case when v_pl.max_heads is null then v_remaining
                        else greatest(v_pl.max_heads - v_pl.current_heads, 0) end;
    v_pool_free := greatest(v_pool.target_heads - v_pool.matched_heads, 0);
    v_kg_free   := case when v_pl.max_volume_kg is null or v_batch.avg_weight_kg is null then v_remaining
                        else greatest(floor((v_pl.max_volume_kg - v_pl.current_volume_kg)
                                            / v_batch.avg_weight_kg), 0)::int end;

    v_free := least(v_line_free, v_pool_free, v_kg_free);
    if p_max_heads is not null then v_free := least(v_free, p_max_heads); end if;
    v_take := least(v_remaining, v_free);
    if v_take <= 0 then return 0; end if;

    -- Правило минимума дробления — только для АВТО (p_max_heads is null).
    -- Manual (явный кап) уважает число МПК как есть.
    if p_max_heads is null and v_take < v_remaining then
        select min_split_heads into v_min from public.tsp_config where is_active = true limit 1;
        v_min := coalesce(v_min, 5);
        if v_take < v_min then return 0; end if;                 -- кусок слишком мал
        if (v_remaining - v_take) < v_min then
            v_take := v_remaining - v_min;                       -- оставить жизнеспособный остаток
        end if;
        if v_take < v_min then return 0; end if;
    end if;

    v_price := coalesce(p_price, v_pl.mpk_price_per_kg);
    if v_batch.farmer_price_per_kg is not null and v_price < v_batch.farmer_price_per_kg then
        raise exception 'BID_BELOW_ASK: цена куска % < ask фермера %', v_price, v_batch.farmer_price_per_kg
            using errcode = 'P0007';
    end if;
    v_vol  := coalesce(round(v_take * v_batch.avg_weight_kg)::int, 0);
    v_full := (v_batch.matched_heads + v_take) >= v_batch.heads;

    insert into public.batch_allocations
        (batch_id, pool_line_id, pool_id, heads, price_per_kg, status, via, created_by)
    values (p_batch_id, v_pl.id, v_pool.id, v_take, v_price, 'matched', p_via, p_created_by);

    update public.pool_lines
    set current_heads     = current_heads + v_take,
        current_volume_kg = current_volume_kg + v_vol,
        updated_at        = now()
    where id = v_pl.id;

    update public.pools
    set matched_heads = matched_heads + v_take, updated_at = now()
    where id = v_pool.id;

    update public.batches
    set matched_heads     = matched_heads + v_take,
        status            = case when v_full then 'matched' else 'partially_matched' end,
        -- legacy-совместимость: пишем по ПЕРВОМУ куску (когда до этого ничего не продано)
        pool_line_id      = case when v_batch.matched_heads = 0 then v_pl.id else pool_line_id end,
        deal_price_per_kg = case when v_batch.matched_heads = 0 then v_price else deal_price_per_kg end,
        matched_at        = coalesce(matched_at, now()),
        updated_at        = now()
    where id = p_batch_id;

    -- Полностью распродан → снять «висящие» broadcast-офферы.
    if v_full then
        update public.offers set status = 'withdrawn', responded_at = now()
        where batch_id = p_batch_id and status = 'pending';
    end if;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'matched',
        jsonb_build_object('pool_id', v_pool.id, 'pool_line_id', v_pl.id,
                           'via', p_via, 'chunk_heads', v_take, 'deal_price_per_kg', v_price,
                           'partial', not v_full),
        p_created_by);

    -- Пул набрался по головам → закрыть + раскрыть контакт + подтвердить его куски.
    if (v_pool.matched_heads + v_take) >= v_pool.target_heads then
        update public.pools
        set status = 'closed_filled', completed_at = now(),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
        where id = v_pool.id and status = 'filling';
        if found then
            update public.batch_allocations
            set status = 'confirmed', confirmed_at = now()
            where pool_id = v_pool.id and status = 'matched';
            -- батч, полностью проданный и все куски подтверждены → confirmed
            update public.batches b
            set status = 'confirmed', confirmed_at = now(), updated_at = now()
            where b.id in (select batch_id from public.batch_allocations where pool_id = v_pool.id)
              and b.matched_heads = b.heads
              and not exists (select 1 from public.batch_allocations a
                              where a.batch_id = b.id and a.status <> 'confirmed');
        end if;
    end if;

    return v_take;
end;
$$;
comment on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) is
    'Слайс 9: единый аллокатор куска батча в строку пула. take=min(остаток,свободно строки/
     пула/kg[,кап]) + правило min_split (авто) + инкременты + FSM батча (matched|partially_
     matched) + закрытие пула. Возвращает взятые головы (0=ничего). Зовётся из 4 матч-RPC.';
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from anon;
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from authenticated;


-- ── 4. rpc_self_activate_pool_request — свип с ДРОБЛЕНИЕМ ──────────────────────
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
    v_line      record;
    v_win_hours int;
    v_tried     uuid[];
    v_took      int;
    v_any       boolean;
    v_rem       int;
    v_matched   int := 0;
    v_offered   int := 0;
    v_uid       uuid := public.fn_current_user_id();
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
        max_volume_kg, current_volume_kg, max_heads, current_heads, is_active
    )
    select v_pool_id, null, ln->>'code', nullif(ln->>'breed', ''),
           round((ln->>'price')::numeric)::int, null, 0,
           nullif(ln->>'maxHeads', '')::int, 0, true
    from jsonb_array_elements(coalesce(v_req.accepted_categories, '[]'::jsonb)) ln
    where coalesce(ln->>'price', '') <> '' and (ln->>'price')::numeric > 0;

    if v_req.region_ids is not null and cardinality(v_req.region_ids) > 0 then
        foreach v_rid in array v_req.region_ids loop
            insert into public.pool_regions (pool_id, region_type, region_id)
            values (v_pool_id, 'oblast', v_rid) on conflict (pool_id, region_id) do nothing;
        end loop;
    elsif v_req.region_id is not null then
        insert into public.pool_regions (pool_id, region_type, region_id)
        values (v_pool_id, 'oblast', v_req.region_id) on conflict (pool_id, region_id) do nothing;
    end if;

    select offer_window_hours into v_win_hours from public.tsp_config where is_active = true limit 1;
    v_win_hours := coalesce(v_win_hours, 24);

    -- Свип: published + partially_matched (у второго добираем ОСТАТОК).
    for v_batch in
        select b.* from public.batches b
        where b.status in ('published', 'partially_matched')
          and b.farmer_price_per_kg is not null
          and b.matched_heads < b.heads
        order by b.created_at asc
        for update
    loop
        v_grade := public.fn_tsp_batch_grade(v_batch.id);
        if v_grade is null then continue; end if;

        -- 1) Прямое дробление в строки ЭТОГО пула, пока есть остаток и подходящие строки.
        v_tried := '{}';
        v_any   := false;
        loop
            select pl.id as pl_id
              into v_line
            from public.pool_lines pl
            join public.pools p on p.id = pl.pool_id
            where pl.pool_id = v_pool_id
              and p.status = 'filling'
              and pl.is_active = true
              and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
              and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
              and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
              and (pl.max_heads is null or pl.current_heads < pl.max_heads)
              and (pl.max_volume_kg is null or pl.current_volume_kg < pl.max_volume_kg)
              and p.matched_heads < p.target_heads
              and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
              and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
              and public.fn_tsp_region_match(v_req.region_ids, v_req.region_id, v_batch.region_id)
              and public.fn_tsp_district_match(v_req.district_ids, v_batch.organization_id)
              and pl.id <> all (v_tried)
            order by pl.mpk_price_per_kg desc
            limit 1
            for update;
            exit when not found;

            v_took := public.fn_tsp_alloc_chunk(v_batch.id, v_line.pl_id, 'pool_activate_sweep', v_uid);
            if v_took = 0 then v_tried := v_tried || v_line.pl_id; continue; end if;
            v_any := true;
            select heads - matched_heads into v_rem from public.batches where id = v_batch.id;
            exit when v_rem <= 0;
        end loop;
        if v_any then v_matched := v_matched + 1; end if;

        -- 2) Остаток > 0 → broadcast подходящим строкам (цена-гейт), если ещё не оффер.
        select heads - matched_heads into v_rem from public.batches where id = v_batch.id;
        if v_rem > 0 then
            perform 1
            from public.pool_lines pl
            join public.pools p on p.id = pl.pool_id
            where pl.pool_id = v_pool_id
              and p.status = 'filling'
              and pl.is_active = true
              and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
              and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
              and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
              and (pl.max_heads is null or pl.current_heads < pl.max_heads)
              and (pl.max_volume_kg is null or pl.current_volume_kg < pl.max_volume_kg)
              and p.matched_heads < p.target_heads
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
                update public.batches set status = 'offering', offering_at = now(), updated_at = now()
                where id = v_batch.id and status = 'published';
                insert into public.batch_events (batch_id, event_type, metadata, created_by)
                values (v_batch.id, 'broadcast_sent',
                    jsonb_build_object('trigger', 'pool_activate_sweep', 'pool_id', v_pool_id, 'remaining_heads', v_rem),
                    v_uid);
                v_offered := v_offered + 1;
            end if;
        end if;
    end loop;

    update public.pool_requests
    set status = 'active', activated_at = now(), updated_at = now()
    where id = p_request_id;

    return jsonb_build_object('request_id', p_request_id, 'pool_id', v_pool_id,
                              'sweptMatched', v_matched, 'sweptOffered', v_offered);
end;
$$;
comment on function public.rpc_self_activate_pool_request(uuid) is
    'КАНОН d02 +Слайс 9 | Заявка(draft)→Pool(filling). Свип с ДРОБЛЕНИЕМ: батч (published|
     partially_matched) раскладывается кусками по строкам пула (цена+сорт+порода+регион+
     район+окно+ёмкость), остаток → broadcast. Дробление уважает tsp_config.min_split_heads.';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;


-- ── 5. rpc_self_auto_match_batch — при публикации, с ДРОБЛЕНИЕМ по всем пулам ──
create or replace function public.rpc_self_auto_match_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch     public.batches%rowtype;
    v_grade     text;
    v_line      record;
    v_win_hours int;
    v_tried     uuid[];
    v_took      int;
    v_rem       int;
    v_alloc     int := 0;
    v_offers    int := 0;
    v_uid       uuid := public.fn_current_user_id();
begin
    if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;
    if v_batch.status not in ('published', 'partially_matched') then
        return jsonb_build_object('matched', false, 'reason', 'BATCH_NOT_AVAILABLE');
    end if;
    if v_batch.farmer_price_per_kg is null then
        return jsonb_build_object('matched', false, 'reason', 'NO_ASK');
    end if;

    v_grade := public.fn_tsp_batch_grade(p_batch_id);
    if v_grade is null then return jsonb_build_object('matched', false, 'reason', 'NO_GRADE'); end if;

    -- 1) Дробление по строкам ЛЮБЫХ filling-пулов (лучшая цена первой), пока есть остаток.
    v_tried := '{}';
    loop
        select pl.id as pl_id
          into v_line
        from public.pool_lines pl
        join public.pools p          on p.id = pl.pool_id
        join public.pool_requests pr on pr.id = p.pool_request_id
        where p.status = 'filling'
          and pl.is_active = true
          and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_heads is null or pl.current_heads < pl.max_heads)
          and (pl.max_volume_kg is null or pl.current_volume_kg < pl.max_volume_kg)
          and p.matched_heads < p.target_heads
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
          and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
          and pl.id <> all (v_tried)
        order by pl.mpk_price_per_kg desc, p.created_at asc
        limit 1
        for update;
        exit when not found;

        v_took := public.fn_tsp_alloc_chunk(p_batch_id, v_line.pl_id, 'auto_match', v_uid);
        if v_took = 0 then v_tried := v_tried || v_line.pl_id; continue; end if;
        v_alloc := v_alloc + v_took;
        select heads - matched_heads into v_rem from public.batches where id = p_batch_id;
        exit when v_rem <= 0;
    end loop;

    select heads - matched_heads into v_rem from public.batches where id = p_batch_id;

    if v_rem <= 0 then
        return jsonb_build_object('matched', true, 'fully', true, 'matchedHeads', v_alloc);
    end if;

    -- 2) Остаток > 0 → broadcast подходящим МПК (цена-гейт).
    select offer_window_hours into v_win_hours from public.tsp_config where is_active = true limit 1;
    v_win_hours := coalesce(v_win_hours, 24);

    with eligible_mpks as (
        select distinct p.organization_id as mpk_org_id
        from public.pool_lines pl
        join public.pools p          on p.id = pl.pool_id
        join public.pool_requests pr on pr.id = p.pool_request_id
        where p.status = 'filling'
          and pl.is_active = true
          and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_heads is null or pl.current_heads < pl.max_heads)
          and (pl.max_volume_kg is null or pl.current_volume_kg < pl.max_volume_kg)
          and p.matched_heads < p.target_heads
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
        update public.batches set status = 'offering', offering_at = now(), updated_at = now()
        where id = v_batch.id and status = 'published';
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch.id, 'broadcast_sent',
            jsonb_build_object('trigger', 'auto_match', 'offers', v_offers, 'remaining_heads', v_rem), v_uid);
        return jsonb_build_object('matched', v_alloc > 0, 'fully', false,
                                  'matchedHeads', v_alloc, 'reason', 'BROADCAST', 'offers', v_offers);
    end if;

    return jsonb_build_object('matched', v_alloc > 0, 'fully', false, 'matchedHeads', v_alloc,
                              'reason', case when v_alloc > 0 then 'PARTIAL_NO_MORE' else 'NO_POOL' end);
end;
$$;
comment on function public.rpc_self_auto_match_batch(uuid) is
    'КАНОН d02 +Слайс 9 | Авто-матч при публикации с ДРОБЛЕНИЕМ: батч раскладывается кусками
     по строкам всех filling-пулов (бид>=ask, сорт+порода+регион+район+окно+ёмкость), остаток
     → broadcast. Дробление уважает tsp_config.min_split_heads.';
revoke execute on function public.rpc_self_auto_match_batch(uuid) from anon;
grant  execute on function public.rpc_self_auto_match_batch(uuid) to authenticated;


-- ── 6. rpc_self_accept_offer — МПК берёт КУСОК(и) в свои строки ────────────────
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
    v_line  record;
    v_tried uuid[];
    v_took  int;
    v_alloc int := 0;
    v_rem   int;
    v_uid   uuid := public.fn_current_user_id();
begin
    if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;

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
    if v_batch.status not in ('offering', 'partially_matched') then
        raise exception 'INVALID_STATUS: batch is % (must be offering/partially_matched)', v_batch.status using errcode = 'P0006';
    end if;
    if v_batch.matched_heads >= v_batch.heads then
        raise exception 'BATCH_FULLY_MATCHED' using errcode = 'P0006';
    end if;

    v_grade := public.fn_tsp_batch_grade(v_batch.id);

    -- Берём кусок(и) в строки ЭТОГО МПК (бид>=offered ask), пока есть остаток и место.
    v_tried := '{}';
    loop
        select pl.id as pl_id
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
          and (pl.max_heads is null or pl.current_heads < pl.max_heads)
          and (pl.max_volume_kg is null or pl.current_volume_kg < pl.max_volume_kg)
          and p.matched_heads < p.target_heads
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
          and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
          and pl.id <> all (v_tried)
        order by pl.mpk_price_per_kg desc
        limit 1
        for update;
        exit when not found;

        v_took := public.fn_tsp_alloc_chunk(v_batch.id, v_line.pl_id, 'offer_accept', v_uid);
        if v_took = 0 then v_tried := v_tried || v_line.pl_id; continue; end if;
        v_alloc := v_alloc + v_took;
        select heads - matched_heads into v_rem from public.batches where id = v_batch.id;
        exit when v_rem <= 0;
    end loop;

    if v_alloc = 0 then
        raise exception 'NO_MATCHING_POOL_LINE: нет активной строки (бид>=ask %, сорт/порода/регион/район) с местом по головам', v_offer.offered_price_per_kg
            using errcode = 'P0007';
    end if;

    -- Этот оффер отработан. Sibling-офферы НЕ снимаем, пока батч не распродан целиком
    -- (их снимет аллокатор при полном матче). Остаток остаётся доступен другим МПК.
    update public.offers
    set status = 'accepted', responded_at = now(), responded_by = v_uid
    where id = p_offer_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (v_batch.id, 'offer_accepted',
        jsonb_build_object('offer_id', p_offer_id, 'mpk_org_id', v_offer.mpk_org_id,
                           'allocated_heads', v_alloc), v_uid);

    select heads - matched_heads into v_rem from public.batches where id = v_batch.id;
    return jsonb_build_object('batchId', v_batch.id, 'allocatedHeads', v_alloc,
                              'remainingHeads', v_rem, 'fully', v_rem <= 0);
end;
$$;
comment on function public.rpc_self_accept_offer(uuid) is
    'КАНОН d02 +Слайс 9 | МПК принимает broadcast-оффер (FCFS) с ДРОБЛЕНИЕМ: берёт кусок(и)
     в свои строки (бид>=offered ask, сорт+порода+регион+район+окно+ёмкость). Остаток остаётся
     доступен другим МПК; sibling-офферы снимаются только при полном матче батча.';
revoke execute on function public.rpc_self_accept_offer(uuid) from anon;
grant  execute on function public.rpc_self_accept_offer(uuid) to authenticated;


-- ── 7. rpc_self_match_batch_to_pool — ручной матч КУСКА (явные головы) ─────────
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
    v_heads  int;
    v_took   int;
    v_uid    uuid := public.fn_current_user_id();
begin
    select * into v_pool from public.pools where id = p_pool_id for update;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_pool.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;
    if v_pool.status <> 'filling' then raise exception 'POOL_NOT_FILLING' using errcode = 'P0003'; end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0004'; end if;
    if v_batch.status not in ('published', 'offering', 'partially_matched') then
        raise exception 'BATCH_NOT_AVAILABLE' using errcode = 'P0005';
    end if;
    if v_batch.matched_heads >= v_batch.heads then
        raise exception 'BATCH_FULLY_MATCHED' using errcode = 'P0005';
    end if;

    v_grade := public.fn_tsp_batch_grade(p_batch_id);
    -- Кап явных голов: не больше остатка батча.
    v_heads := least(coalesce(p_matched_heads, v_batch.heads - v_batch.matched_heads),
                     v_batch.heads - v_batch.matched_heads);
    if v_heads <= 0 then raise exception 'NO_REMAINING_HEADS' using errcode = 'P0008'; end if;

    -- строка пула под сорт+породу + ЕСТЬ МЕСТО ПО ГОЛОВАМ
    select pl.id as pl_id
      into v_line
    from public.pool_lines pl
    where pl.pool_id = p_pool_id
      and pl.is_active = true
      and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
      and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
      and (pl.max_heads is null or pl.current_heads < pl.max_heads)
      and (pl.max_volume_kg is null or pl.current_volume_kg < pl.max_volume_kg)
    order by pl.mpk_price_per_kg desc
    limit 1
    for update;
    if not found then
        raise exception 'NO_MATCHING_LINE: нет активной строки под сорт/породу % с местом', v_grade
            using errcode = 'P0006';
    end if;

    v_took := public.fn_tsp_alloc_chunk(p_batch_id, v_line.pl_id, 'manual_match', v_uid, v_heads, p_price_per_kg);
    if v_took <= 0 then
        raise exception 'ALLOC_FAILED: строка не смогла принять кусок (нет места / цена < ask)'
            using errcode = 'P0007';
    end if;

    return v_line.pl_id;
end;
$$;
comment on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) is
    'КАНОН d02 +Слайс 9 | Ручной матч МПК: берёт КУСОК p_matched_heads (кап = остаток батча)
     в строку по сорту+породе+месту, цена p_price_per_kg (>= ask). Возвращает pool_line_id.';
revoke execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) from anon;
grant  execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) to authenticated;
