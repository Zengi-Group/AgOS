-- AgOS · БЕТА · Слайс 8 · Аддитив: жёсткий потолок голов + цена-гейт на broadcast.
-- ============================================================================
-- КОНТЕКСТ / ДЕФЕКТЫ (CEO-тест, 2026-07-02):
--   (1) ПЕРЕЛИВ ЛИМИТА. Пул на 40 голов набирал 41/40 — потому что ни один матч-RPC
--       не проверял ВПИСЫВАЕТСЯ ЛИ партия ДО матча. Проверка «пул заполнен?» стояла
--       ПОСЛЕ добавления партии → последняя партия перебирала лимит (38+3 → 41, затем
--       close). Партия атомарна (не делится), поэтому правило: партию НЕ матчим, если
--       matched_heads + heads > target_heads. Пул закрывается только при точном наборе;
--       остаток ждёт партию подходящего размера. «Отдаётся столько, сколько нужно».
--   (2) ЦЕНА НА BROADCAST. Прямой матч / accept / ручной матч уже требуют bid >= ask.
--       Но broadcast рассылался БЕЗ проверки цены («цена игнор») → фермер с ценой ВЫШЕ
--       бида пула всё равно получал оффер и попадал в offering (выглядит как матч).
--       По требованию CEO: цена фермера выше бида пула → НЕТ ни матча, ни broadcast.
--       Добавляем pl.mpk_price_per_kg >= farmer_ask в предикаты broadcast.
--
-- ПОДХОД (схема FINAL — только аддитивно, CREATE OR REPLACE тел RPC):
--   • Перевыпуск rpc_self_activate_pool_request / rpc_self_auto_match_batch /
--     rpc_self_accept_offer — база = 20260701150000 (сохраняем предикаты района/
--     региона/породы/сорта/цены/окна), + потолок голов в матч- и broadcast-выборках,
--     + цена-гейт в broadcast.
--   • Перевыпуск rpc_self_match_batch_to_pool (ручной матч) — база = 20260701120000
--     (район намеренно не трогаем), + явная проверка потолка голов до апдейта.
--   Сигнатуры НЕ меняются (P7) — только тела. Идемпотентно.
--
-- Применять через Supabase Dashboard → SQL Editor. ЗАВИСИМОСТИ:
-- 20260701120000_tsp_breed_multiregion_match, 20260701150000_tsp_district_sort.
-- ============================================================================


-- ── 1. rpc_self_activate_pool_request — потолок голов + цена-гейт broadcast ────
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

        -- 1) Прямой матч: бид >= ask, сорт=, окно, ёмкость(kg), ПОТОЛОК ГОЛОВ, РЕГИОН, РАЙОН, ПОРОДА.
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
          and p.matched_heads + v_batch.heads <= p.target_heads
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

        -- 2) Нет прямого матча → broadcast-оффер. ЦЕНА-ГЕЙТ: бид >= ask (иначе оффер
        --    бессмыслен — МПК не платит выше своего бида). + сорт+РЕГИОН+РАЙОН+ПОРОДА+
        --    окно+ёмкость+ПОТОЛОК ГОЛОВ.
        perform 1
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.pool_id = v_pool_id
          and p.status = 'filling'
          and pl.is_active = true
          and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and p.matched_heads + v_batch.heads <= p.target_heads
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
    'КАНОН d02 +аддитив Слайс 8 | Заявка(draft)→Pool(filling). Свип published-партий:
     жёсткий фильтр сорт+цена+окно+ёмкость+ПОТОЛОК ГОЛОВ+РЕГИОН+РАЙОН+ПОРОДА → matched,
     иначе broadcast (тоже с цена-гейтом bid>=ask и потолком голов).';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;


-- ── 2. rpc_self_auto_match_batch — потолок голов + цена-гейт broadcast ─────────
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

    -- 1) Прямой авто-матч: высший бид >= ask, сорт=, окно, ёмкость, ПОТОЛОК ГОЛОВ, РЕГИОН, РАЙОН, ПОРОДА.
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
      and p.matched_heads + v_batch.heads <= p.target_heads
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

    -- 2) Нет прямого матча → broadcast. ЦЕНА-ГЕЙТ (bid>=ask) + ПОТОЛОК ГОЛОВ +
    --    сорт+РЕГИОН+РАЙОН+ПОРОДА+окно+ёмкость.
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
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and p.matched_heads + v_batch.heads <= p.target_heads
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
    'КАНОН d02 +аддитив Слайс 8 | Авто-матч при публикации: высший бид >= ask → matched;
     иначе broadcast (цена-гейт bid>=ask). Жёсткий фильтр: сорт+цена+окно+ёмкость+
     ПОТОЛОК ГОЛОВ+РЕГИОН+РАЙОН+ПОРОДА.';
revoke execute on function public.rpc_self_auto_match_batch(uuid) from anon;
grant  execute on function public.rpc_self_auto_match_batch(uuid) to authenticated;


-- ── 3. rpc_self_accept_offer — потолок голов ──────────────────────────────────
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

    -- лучшая строка МПК: бид >= offered ask, сорт/окно/ёмкость/ПОТОЛОК ГОЛОВ/РЕГИОН/РАЙОН/ПОРОДА
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
      and p.matched_heads + v_batch.heads <= p.target_heads
      and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
      and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
      and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
    order by pl.mpk_price_per_kg desc
    limit 1
    for update;
    if not found then
        raise exception 'NO_MATCHING_POOL_LINE: нет активной строки пула (бид >= ask %, сорт/порода/регион/район) с достаточной ёмкостью по головам', v_offer.offered_price_per_kg
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
    'КАНОН d02 +аддитив Слайс 8 | МПК принимает broadcast-оффер (FCFS): offering → matched.
     Строка пула: бид >= offered ask, сорт+окно+ёмкость+ПОТОЛОК ГОЛОВ+РЕГИОН+РАЙОН+ПОРОДА.';
revoke execute on function public.rpc_self_accept_offer(uuid) from anon;
grant  execute on function public.rpc_self_accept_offer(uuid) to authenticated;


-- ── 4. rpc_self_match_batch_to_pool — явная проверка потолка голов ─────────────
-- База = 20260701120000 (район намеренно не трогаем — осознанный ручной выбор МПК).
-- Добавлено: проверка matched_heads + heads <= target_heads ДО апдейта.
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

    -- ПОТОЛОК ГОЛОВ: партия атомарна — не даём перелить лимит пула.
    if v_pool.matched_heads + v_heads > v_pool.target_heads then
        raise exception 'POOL_CAPACITY_EXCEEDED: % + % > лимит %', v_pool.matched_heads, v_heads, v_pool.target_heads
            using errcode = 'P0008';
    end if;

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
    'КАНОН d02 +аддитив Слайс 8 | Ручной матч МПК: published|offering-партию → matched
     при p_price_per_kg (>= ask). Строка по сорту И ПОРОДЕ. +ПОТОЛОК ГОЛОВ (не перелить
     target_heads). auto-close по головам → confirmed. Гейт pools.organization_id.';
revoke execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) from anon;
grant  execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) to authenticated;
