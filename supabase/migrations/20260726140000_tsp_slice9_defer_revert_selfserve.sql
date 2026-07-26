-- AgOS · TSP-SLICE9-ROLLBACK-01 — продуктовое решение CEO (2026-07-26, см. DECISIONS_LOG):
-- дробление партии на куски (Слайс 9, BATCH-SPLIT-01, 20260702160000_tsp_batch_split_
-- allocations.sql) ПОКА НЕ включаем. Слайс 9 был реально живым на проде 2026-07-02 —
-- 07-05 (16 строк batch_allocations), затем кто-то откатил 3 self-serve RPC обратно на
-- до-Слайс-9 логику (20260625120000_tsp_defect_ab_redeploy.sql) вручную, вне git —
-- откат нигде не был зафиксирован. Эта миграция ЗАКРЫВАЕТ дыру канон↔прод в обратную
-- сторону: канон (в migration-файлах Слайс 9) до сих пор объявлял дробящую версию, и
-- любой будущий `deploy.py --all` тихо ВКЛЮЧИЛ бы дробление обратно — теперь канон
-- явно = тому, что реально работает на проде и что подтверждено решением CEO.
--
-- Ничего не удалено (HS-1/HS-2/P7): код Слайс 9 остаётся в
-- 20260702160000_tsp_batch_split_allocations.sql, fn_tsp_alloc_chunk/fn_tsp_rollup_
-- batch_status/batch_allocations/min_split_heads — в схеме, готовы к реактивации.
-- Это переопределение (CREATE OR REPLACE) трёх RPC телом из pg_get_functiondef с
-- прода (сверено байт-в-байт, единственный вызывающий на фронте — TSP wizard/self-
-- serve поток /cabinet и /mpk, RequireAuth). Retire-when: решение развернётся —
-- вернуть Слайс 9 версии (уже есть в 20260702160000) новой миграцией той же схемы.

-- ── rpc_self_activate_pool_request — без дробления (Слайс 6 + DEFECT-B) ──────────
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
begin
    select * into v_req from public.pool_requests where id = p_request_id;
    if not found then raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool request not owned by current user' using errcode = 'P0001';
    end if;
    if v_req.status <> 'draft' then
        raise exception 'REQUEST_NOT_DRAFT' using errcode = 'P0003';
    end if;

    -- pools.organization_id NOT NULL (прод-сверено 2026-06-23). Берём org из заявки.
    -- Конвергенция B2: пишем delivery-окно (из target_month) и published_at — нужны
    -- канон-матчеру (overlap D-M6-8). total_target_volume_kg=NULL: auto-close по головам.
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

    -- Конвергенция B2: бид МПК → структурные pool_lines (D-TSP-MATCH-01). Категория-код
    -- фронта (premium/vysshaya/...) → category_label; матч резолвит сорт через
    -- fn_tsp_grade_for_mpk_key(category_label). tsp_sku_id=NULL (бид по категории, не SKU).
    -- max_volume_kg=NULL (UI потолок не шлёт). Только строки с ценой > 0 (CHECK mpk_price>0).
    insert into public.pool_lines (
        pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
        max_volume_kg, current_volume_kg, is_active
    )
    select v_pool_id, null, ln->>'code',
           round((ln->>'price')::numeric)::int, null, 0, true
    from jsonb_array_elements(coalesce(v_req.accepted_categories, '[]'::jsonb)) ln
    where coalesce(ln->>'price', '') <> ''
      and (ln->>'price')::numeric > 0;

    -- ── DEFECT-B fix (2026-06-25) ──────────────────────────────────────────
    -- (a) Перенос региона заявки в pool_regions (D-M6-4): даёт пулу видимость
    -- канон-путям (rpc_retry_match_pool / rpc_accept_offer EXISTS pool_regions).
    -- pool_regions.region_id NOT NULL → "Все области" (v_req.region_id is null)
    -- НЕ пишет строк: такой пул матчит только через мягкий предикат ниже
    -- (канон-hard требует явные регионы — осознанное ограничение схемы).
    if v_req.region_id is not null then
        insert into public.pool_regions (pool_id, region_type, region_id)
        values (v_pool_id, 'oblast', v_req.region_id)
        on conflict (pool_id, region_id) do nothing;
    end if;

    -- (b) Свип уже ОПУБЛИКОВАННЫХ партий: до этого фикса self-serve пул матчил
    -- только партии, созданные ПОСЛЕ него (батч-инициированный rpc_self_auto_match_
    -- batch). Теперь свежий пул сам «подхватывает» висящие published-партии —
    -- зеркало batch-матча, но pool-initiated: НЕ гейтит владельца партии (МПК
    -- матчит чужие фермерские партии, как канон rpc_retry_match_pool). Сорт —
    -- строгое равенство (=), регион — мягкий приоритет через v_req.region_id.
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

        -- 1) Прямой матч: стоящий бид этого пула >= ask, сорт=, окно, ёмкость, регион.
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
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and (v_req.region_id is null
               or v_req.region_id = v_batch.region_id
               or v_req.region_id = (select parent_id from public.regions where id = v_batch.region_id))
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

            -- снять прочие висящие офферы на эту партию (FCFS-консистентность)
            update public.offers set status = 'withdrawn', responded_at = now()
            where batch_id = v_batch.id and status = 'pending';

            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            values (v_batch.id, 'matched',
                jsonb_build_object('pool_id', v_pool_id, 'pool_line_id', v_line.pl_id,
                                   'via', 'pool_activate_sweep', 'deal_price_per_kg', v_line.bid),
                public.fn_current_user_id());

            v_matched := v_matched + 1;

            -- auto-close по головам → closed_filled + matched-партии → confirmed; стоп свипа
            if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
                update public.pools
                set status = 'closed_filled', completed_at = now(),
                    mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
                where id = v_pool_id and status = 'filling';
                update public.batches b
                set status = 'confirmed', confirmed_at = now(), updated_at = now()
                from public.pool_lines pl
                where pl.pool_id = v_pool_id and b.pool_line_id = pl.id and b.status = 'matched';
                exit;  -- пул заполнен — дальнейшие партии не матчим
            end if;
            continue;
        end if;

        -- 2) Нет прямого матча → broadcast-оффер этому МПК (сорт+регион+окно+ёмкость,
        -- цена игнорируется; offered_price = ask). Партия published → offering.
        perform 1
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.pool_id = v_pool_id
          and p.status = 'filling'
          and pl.is_active = true
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and (v_req.region_id is null
               or v_req.region_id = v_batch.region_id
               or v_req.region_id = (select parent_id from public.regions where id = v_batch.region_id))
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
    'TSP-SLICE9-ROLLBACK-01 (2026-07-26, CEO): без дробления партии — Слайс 6 +
     DEFECT-B fix (2026-06-25). Слайс 9 (batch-split) отложен по продуктовому
     решению; версия с дроблением сохранена в 20260702160000, реактивация — новой
     миграцией. Заявка(draft)→Pool(filling), свип уже опубликованных партий целиком.';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from public, anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;


-- ── rpc_self_auto_match_batch — без дробления, целиком в одну строку пула ───────
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
    'TSP-SLICE9-ROLLBACK-01 (2026-07-26, CEO): без дробления — матч партии целиком
     в одну строку пула (высший подходящий бид) либо broadcast. Слайс 9 отложен,
     версия с дроблением сохранена в 20260702160000.';
revoke execute on function public.rpc_self_auto_match_batch(uuid) from public, anon;
grant  execute on function public.rpc_self_auto_match_batch(uuid) to authenticated;


-- ── rpc_self_accept_offer — без дробления, принятие оффера целиком ──────────────
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
    'TSP-SLICE9-ROLLBACK-01 (2026-07-26, CEO): без дробления — принятие оффера
     закрывает партию целиком в одну строку пула МПК. Слайс 9 отложен, версия
     с дроблением сохранена в 20260702160000.';
revoke execute on function public.rpc_self_accept_offer(uuid) from public, anon;
grant  execute on function public.rpc_self_accept_offer(uuid) to authenticated;
