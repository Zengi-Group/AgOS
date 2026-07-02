-- AgOS · БЕТА · Слайс 9 (S3) · ПО-КУСКОВАЯ отгрузка и приёмка (per-chunk dispatch).
-- ============================================================================
-- ФИЧА (CEO, 2026-07-02): после дробления батча продажа идёт КУСКАМИ, но отгрузка/
-- приёмка оставались batch-level и висели на ЛЕГАСИ b.pool_line_id (первый кусок).
-- Из-за этого:
--   • у дроблёного батча, чей пул заполнился, не было кнопки «Отгрузить» (dispatch
--     требовал status='confirmed', а батч висел 'partially_matched'/'matched');
--   • МПК видел в пуле только ПЕРВЫЙ кусок (rpc_get_pool_matches джойнил b.pool_line_id),
--     вторичные куски были невидимы и не подтверждались.
--
-- РЕШЕНИЕ («полный цикл по кускам»): dispatched/delivered трекаются НА УРОВНЕ КУСКА
--   (batch_allocations), а статус БАТЧА — производная (rollup) от его активных кусков.
--   • Фермер жмёт «Отгрузить готовое» → все confirmed-куски → dispatched.
--   • МПК подтверждает приёмку ПО КУСКУ (в мониторе пула строка = кусок).
--   • Батч = самый «отстающий» активный кусок: все delivered→delivered, есть
--     dispatched→dispatched, есть confirmed→confirmed, есть matched→matched.
--
-- МОДЕЛЬ (схема FINAL — только аддитивно, HS-2):
--   • batch_allocations += dispatched_at, delivered_at; статус CHECK += dispatched/delivered.
--   • fn_tsp_rollup_batch_status(batch) — статус батча из активных кусков (только off-market).
--   • rpc_self_dispatch_ready(batch) — фермер отгружает confirmed-куски (+ легаси-фолбэк).
--   • rpc_self_confirm_delivery_alloc(alloc) — МПК подтверждает приёмку куска.
--   • fn_tsp_alloc_chunk — закрытие пула зовёт rollup (вместо хардкод-confirm).
--   • rpc_self_withdraw_batch — статус через rollup; v_active считает все не-cancelled.
--   • rpc_get_pool_matches — по КУСКАМ (batch_allocations), а не по b.pool_line_id.
--
-- Сигнатуры существующих RPC не меняются (P7). Идемпотентно. Зависимости:
-- 20260702160000 (batch_allocations, fn_tsp_alloc_chunk), 20260702170000 (batch_json),
-- 20260702180000 (rpc_self_withdraw_batch). Применять через SQL Editor.
-- ============================================================================


-- ── 0. batch_allocations += статусы отгрузки/приёмки + таймстемпы ──────────────
alter table public.batch_allocations
    add column if not exists dispatched_at timestamptz,
    add column if not exists delivered_at  timestamptz;

-- Пересобираем CHECK статуса куска: + dispatched/delivered (matched/confirmed/cancelled — как были).
alter table public.batch_allocations drop constraint if exists batch_allocations_status_check;
alter table public.batch_allocations add  constraint batch_allocations_status_check
    check (status in ('matched', 'confirmed', 'dispatched', 'delivered', 'cancelled'));


-- ── 1. fn_tsp_rollup_batch_status — статус батча = «отстающий» активный кусок ──
-- Пересчитывает batches.status из активных (не-cancelled) кусков — ТОЛЬКО когда батч
-- УЖЕ вне рынка (matched/confirmed/dispatched/delivered). partially_matched/published/
-- offering (остаток на рынке) и терминальные (cancelled/failed/expired) НЕ трогает.
-- Правило: батч продвинут ровно настолько, насколько продвинут его самый «отстающий»
-- активный кусок: min(level) → matched(1)/confirmed(2)/dispatched(3)/delivered(4).
create or replace function public.fn_tsp_rollup_batch_status(p_batch_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_status text;
    v_level  int;
    v_new    text;
begin
    select status into v_status from public.batches where id = p_batch_id for update;
    if not found then return; end if;
    -- Только off-market батч: остаток на рынке (partially_matched/published/offering)
    -- или терминальный статус — не трогаем (rollup не должен снимать батч с рынка).
    if v_status not in ('matched', 'confirmed', 'dispatched', 'delivered') then
        return;
    end if;

    select min(case a.status
                    when 'matched'    then 1
                    when 'confirmed'  then 2
                    when 'dispatched' then 3
                    when 'delivered'  then 4
               end)
      into v_level
    from public.batch_allocations a
    where a.batch_id = p_batch_id and a.status <> 'cancelled';

    if v_level is null then return; end if;   -- нет активных кусков — оставляем как есть

    v_new := case v_level when 1 then 'matched' when 2 then 'confirmed'
                          when 3 then 'dispatched' else 'delivered' end;

    update public.batches
    set status       = v_new,
        confirmed_at  = case when v_level >= 2 then coalesce(confirmed_at, now())  else confirmed_at  end,
        dispatched_at = case when v_level >= 3 then coalesce(dispatched_at, now()) else dispatched_at end,
        delivered_at  = case when v_level >= 4 then coalesce(delivered_at, now())  else delivered_at  end,
        updated_at    = now()
    where id = p_batch_id;
end;
$$;
comment on function public.fn_tsp_rollup_batch_status(uuid) is
    'Слайс 9 (S3) | Пересчёт batches.status из активных кусков (batch_allocations) — только
     для off-market батча (matched/confirmed/dispatched/delivered). Статус = самый отстающий
     активный кусок: min(matched<confirmed<dispatched<delivered) + соответствующие таймстемпы.';
revoke execute on function public.fn_tsp_rollup_batch_status(uuid) from anon;
revoke execute on function public.fn_tsp_rollup_batch_status(uuid) from authenticated;


-- ── 2. rpc_self_dispatch_ready — фермер отгружает готовые (confirmed) куски ────
-- Дроблёный батч: переводит ВСЕ confirmed-куски → dispatched (+ dispatched_at + событие
-- по каждому куску) и делает rollup статуса батча. Легаси-фолбэк: если по батчу нет
-- кусков вовсе (старый цельный матч) и батч 'confirmed' — отгружаем батч целиком.
create or replace function public.rpc_self_dispatch_ready(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch     public.batches%rowtype;
    v_alloc     record;
    v_cnt       int;
    v_dispatched int := 0;
    v_uid       uuid := public.fn_current_user_id();
begin
    if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;

    select count(*) into v_cnt from public.batch_allocations where batch_id = p_batch_id;

    -- Легаси-фолбэк: цельный батч без кусков — как rpc_dispatch_batch (confirmed→dispatched).
    if v_cnt = 0 then
        if v_batch.status <> 'confirmed' then
            raise exception 'INVALID_STATUS: batch is % (must be confirmed)', v_batch.status
                using errcode = 'P0003';
        end if;
        update public.batches
        set status = 'dispatched', dispatched_at = now(),
            notes = (public.fn_tsp_meta(notes) || jsonb_build_object('dispatchedAt', to_char(now(),'YYYY-MM-DD')))::text,
            updated_at = now()
        where id = p_batch_id;
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (p_batch_id, 'dispatched', jsonb_build_object('via', 'farmer', 'legacy', true), v_uid);
        return jsonb_build_object('batchId', p_batch_id, 'dispatchedChunks', 0, 'legacy', true, 'status', 'dispatched');
    end if;

    -- По-кусковая отгрузка: все готовые (confirmed) куски → dispatched.
    for v_alloc in
        select * from public.batch_allocations
        where batch_id = p_batch_id and status = 'confirmed' for update
    loop
        update public.batch_allocations
        set status = 'dispatched', dispatched_at = now()
        where id = v_alloc.id;
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (p_batch_id, 'dispatched',
            jsonb_build_object('via', 'farmer', 'allocation_id', v_alloc.id,
                               'pool_id', v_alloc.pool_id, 'heads', v_alloc.heads), v_uid);
        v_dispatched := v_dispatched + 1;
    end loop;

    if v_dispatched = 0 then
        raise exception 'NO_CONFIRMED_CHUNKS: нет готовых к отгрузке кусков (пул ещё набирается)'
            using errcode = 'P0004';
    end if;

    perform public.fn_tsp_rollup_batch_status(p_batch_id);
    select status into v_batch.status from public.batches where id = p_batch_id;

    return jsonb_build_object('batchId', p_batch_id, 'dispatchedChunks', v_dispatched,
                              'legacy', false, 'status', v_batch.status);
end;
$$;
comment on function public.rpc_self_dispatch_ready(uuid) is
    'Слайс 9 (S3) | Фермер отгружает готовые куски: все confirmed batch_allocations → dispatched
     (+ событие per-кусок) + rollup статуса батча. Легаси-фолбэк: цельный батч без кусков
     (confirmed→dispatched). Гейт fn_my_org_ids(). Заменяет batch-level dispatch для дроблёных.';
revoke execute on function public.rpc_self_dispatch_ready(uuid) from anon;
grant  execute on function public.rpc_self_dispatch_ready(uuid) to authenticated;


-- ── 3. rpc_self_confirm_delivery_alloc — МПК подтверждает приёмку КУСКА ────────
-- dispatched→delivered по конкретному куску (+ delivered_at + событие) + rollup батча.
-- Пул → completed, когда все его куски delivered/cancelled. Гейт «пул моей org».
create or replace function public.rpc_self_confirm_delivery_alloc(p_allocation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_alloc     public.batch_allocations%rowtype;
    v_owner     uuid;
    v_remaining int;
    v_uid       uuid := public.fn_current_user_id();
begin
    if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;

    select * into v_alloc from public.batch_allocations where id = p_allocation_id for update;
    if not found then raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002'; end if;

    -- Гейт «пул моей org» через pool_request (у pools нет надёжного organization_id).
    select pr.organization_id into v_owner
    from public.pools po
    join public.pool_requests pr on pr.id = po.pool_request_id
    where po.id = v_alloc.pool_id;
    if not (v_owner = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    if v_alloc.status <> 'dispatched' then
        raise exception 'INVALID_STATUS: allocation is % (must be dispatched)', v_alloc.status
            using errcode = 'P0003';
    end if;

    update public.batch_allocations
    set status = 'delivered', delivered_at = now()
    where id = p_allocation_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (v_alloc.batch_id, 'delivered',
        jsonb_build_object('via', 'mpk', 'allocation_id', p_allocation_id,
                           'pool_id', v_alloc.pool_id, 'heads', v_alloc.heads), v_uid);

    -- Статус батча — производная от его кусков.
    perform public.fn_tsp_rollup_batch_status(v_alloc.batch_id);

    -- Пул завершён, когда все его куски delivered/cancelled.
    select count(*) into v_remaining
    from public.batch_allocations
    where pool_id = v_alloc.pool_id and status not in ('delivered', 'cancelled');
    if v_remaining = 0 then
        update public.pools
        set status = 'completed', completed_at = coalesce(completed_at, now()), updated_at = now()
        where id = v_alloc.pool_id and status <> 'completed';
    end if;

    return jsonb_build_object('allocationId', p_allocation_id, 'batchId', v_alloc.batch_id,
                              'poolCompleted', v_remaining = 0);
end;
$$;
comment on function public.rpc_self_confirm_delivery_alloc(uuid) is
    'Слайс 9 (S3) | МПК подтверждает приёмку КУСКА: batch_allocations dispatched→delivered
     (+ событие) + rollup статуса батча. Пул→completed, когда все куски delivered/cancelled.
     Гейт «пул моей org» через pool_request. Заменяет batch-level rpc_self_confirm_delivery.';
revoke execute on function public.rpc_self_confirm_delivery_alloc(uuid) from anon;
grant  execute on function public.rpc_self_confirm_delivery_alloc(uuid) to authenticated;


-- ── 4. fn_tsp_alloc_chunk — закрытие пула через rollup (вместо хардкод-confirm) ─
-- Единственное изменение против 20260702180000: блок закрытия пула подтверждает куски
-- (matched→confirmed) и затем зовёт fn_tsp_rollup_batch_status для КАЖДОГО off-market
-- батча пула — статус батча вычисляется из его кусков (matched→confirmed и т.д.).
create or replace function public.fn_tsp_alloc_chunk(
    p_batch_id     uuid,
    p_pool_line_id uuid,
    p_via          text,
    p_created_by   uuid    default null,
    p_max_heads    int     default null,
    p_price        int     default null
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
    v_bid       uuid;
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

    if p_max_heads is null and v_take < v_remaining then
        select min_split_heads into v_min from public.tsp_config where is_active = true limit 1;
        v_min := coalesce(v_min, 5);
        if v_take < v_min then return 0; end if;
        if (v_remaining - v_take) < v_min then
            v_take := v_remaining - v_min;
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
        pool_line_id      = case when v_batch.matched_heads = 0 then v_pl.id else pool_line_id end,
        deal_price_per_kg = case when v_batch.matched_heads = 0 then v_price else deal_price_per_kg end,
        matched_at        = coalesce(matched_at, now()),
        updated_at        = now()
    where id = p_batch_id;

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

    -- Пул набрался по головам → закрыть + раскрыть контакт + подтвердить его куски + rollup.
    if (v_pool.matched_heads + v_take) >= v_pool.target_heads then
        update public.pools
        set status = 'closed_filled', completed_at = now(),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
        where id = v_pool.id and status = 'filling';
        if found then
            update public.batch_allocations
            set status = 'confirmed', confirmed_at = now()
            where pool_id = v_pool.id and status = 'matched';
            -- Статус каждого off-market батча пула вычисляем из его кусков (matched→confirmed).
            -- rollup сам пропустит батчи с остатком на рынке (partially_matched).
            for v_bid in select distinct batch_id from public.batch_allocations where pool_id = v_pool.id loop
                perform public.fn_tsp_rollup_batch_status(v_bid);
            end loop;
        end if;
    end if;

    return v_take;
end;
$$;
comment on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) is
    'Слайс 9 (+S3) | Аллокатор куска батча в строку пула. take=min(остаток,свободно строки/
     пула/kg[,кап]) + правило min_split (авто) + инкременты + FSM батча. Закрытие пула:
     куски matched→confirmed, затем fn_tsp_rollup_batch_status по каждому батчу пула
     (статус = отстающий кусок, off-market only). Возвращает взятые головы (0=ничего).';
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from anon;
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from authenticated;


-- ── 5. rpc_self_withdraw_batch — итоговый статус через rollup ──────────────────
-- Против 20260702180000: v_active считает ВСЕ не-cancelled куски (в т.ч. dispatched/
-- delivered — фермер мог отгрузить готовый кусок, пока остаток ещё на рынке). Итоговый
-- статус (кроме v_active=0→cancelled) считает rollup — батч = его отстающий кусок.
create or replace function public.rpc_self_withdraw_batch(
    p_batch_id        uuid,
    p_include_matched boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch     public.batches%rowtype;
    v_alloc     record;
    v_vol       int;
    v_reversed  int := 0;
    v_penalized int := 0;
    v_active    int;
    v_new_status text;
    v_evt       text;
    v_uid       uuid := public.fn_current_user_id();
begin
    if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;

    if v_batch.status in ('confirmed', 'dispatched', 'delivered') then
        raise exception 'BATCH_LOCKED: партия подтверждена/в отгрузке — снять нельзя'
            using errcode = 'P0003';
    end if;
    if v_batch.status in ('cancelled', 'failed', 'expired') then
        raise exception 'BATCH_NOT_ACTIVE: партия уже завершена' using errcode = 'P0004';
    end if;

    -- Отмена matched-кусков (только по флагу) — реверс счётчиков + штрафное событие.
    if p_include_matched then
        for v_alloc in
            select * from public.batch_allocations
            where batch_id = p_batch_id and status = 'matched' for update
        loop
            v_vol := coalesce(round(v_alloc.heads * v_batch.avg_weight_kg)::int, 0);
            update public.pool_lines
            set current_heads     = greatest(current_heads - v_alloc.heads, 0),
                current_volume_kg = greatest(current_volume_kg - v_vol, 0),
                updated_at        = now()
            where id = v_alloc.pool_line_id;
            update public.pools
            set matched_heads = greatest(matched_heads - v_alloc.heads, 0), updated_at = now()
            where id = v_alloc.pool_id;
            update public.batch_allocations
            set status = 'cancelled', cancelled_at = now()
            where id = v_alloc.id;
            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            values (p_batch_id, 'cancelled_after_match',
                jsonb_build_object('allocation_id', v_alloc.id, 'pool_id', v_alloc.pool_id,
                                   'pool_line_id', v_alloc.pool_line_id, 'heads', v_alloc.heads,
                                   'penalty', true), v_uid);
            v_reversed  := v_reversed + v_alloc.heads;
            v_penalized := v_penalized + 1;
        end loop;
    end if;

    -- Снять остаток с рынка: отозвать «висящие» pending-офферы (безплатно).
    update public.offers set status = 'withdrawn', responded_at = now()
    where batch_id = p_batch_id and status = 'pending';

    -- Активные головы = все не-cancelled куски (matched|confirmed|dispatched|delivered).
    select coalesce(sum(heads), 0) into v_active
    from public.batch_allocations where batch_id = p_batch_id and status <> 'cancelled';

    if v_active = 0 then
        -- Ничего не продано (либо всё отменено) + остаток снят → батч отменён.
        update public.batches
        set matched_heads = 0, status = 'cancelled', cancelled_at = now(), updated_at = now()
        where id = p_batch_id;
        v_new_status := 'cancelled';
    else
        -- Остаток снят: батч уходит с рынка → base 'matched', затем rollup продвигает
        -- статус до отстающего активного куска (confirmed/dispatched/delivered).
        update public.batches
        set matched_heads = v_active, status = 'matched',
            matched_at = coalesce(matched_at, now()), updated_at = now()
        where id = p_batch_id;
        perform public.fn_tsp_rollup_batch_status(p_batch_id);
        select status into v_new_status from public.batches where id = p_batch_id;
    end if;

    v_evt := case
                 when v_penalized > 0            then 'cancelled_after_match'
                 when v_new_status = 'cancelled' then 'cancelled_before_match'
                 else 'remainder_withdrawn'
             end;
    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, v_evt,
        jsonb_build_object('include_matched', p_include_matched, 'reversed_heads', v_reversed,
                           'reversed_chunks', v_penalized, 'active_heads', v_active,
                           'new_status', v_new_status), v_uid);

    return jsonb_build_object(
        'batchId',        p_batch_id,
        'status',         v_new_status,
        'reversedHeads',  v_reversed,
        'reversedChunks', v_penalized,
        'activeHeads',    v_active,
        'penalty',        v_penalized > 0
    );
end;
$$;
comment on function public.rpc_self_withdraw_batch(uuid, boolean) is
    'Слайс 9 (S1b+S3) | Самоотмена партии с учётом дробления. Остаток снимается всегда/безплатно.
     matched-куски — только p_include_matched=true и ЗА ШТРАФ (реверс + cancelled_after_match).
     Итоговый статус: v_active=0→cancelled, иначе rollup (батч = отстающий активный кусок).
     confirmed/dispatched/delivered батч снять нельзя. Гейт fn_my_org_ids().';
revoke execute on function public.rpc_self_withdraw_batch(uuid, boolean) from anon;
grant  execute on function public.rpc_self_withdraw_batch(uuid, boolean) to authenticated;


-- ── 6. rpc_get_pool_matches — карточки по КУСКАМ (batch_allocations) ───────────
-- Против 20260622120000: джойн по batch_allocations (а не b.pool_line_id) — МПК видит
-- ВСЕ куски пула (не только первый). matchId = allocation.id (фронт зовёт по нему
-- rpc_self_confirm_delivery_alloc). heads/price — с куска; status — из статуса куска.
create or replace function public.rpc_get_pool_matches(p_pool_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool     public.pools%rowtype;
    v_req      public.pool_requests%rowtype;
    v_revealed boolean;
begin
    select * into v_pool from public.pools where id = p_pool_id;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    v_revealed := v_pool.mpk_contact_revealed_at is not null;

    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'matchId',   a.id,
                'batchId',   b.id,
                'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'heads',     a.heads,
                'avgWeight', b.avg_weight_kg,
                'price',     a.price_per_kg,
                'region',    coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'status',    case when a.status = 'delivered'  then 'delivered'
                                  when a.status = 'dispatched' then 'dispatched'
                                  when a.status = 'confirmed'  then 'confirmed'
                                  else 'active' end,
                'farmName',  case when v_revealed then o.legal_name else null end,
                'farmPhone', case when v_revealed then o.phone     else null end
            )
            order by a.matched_at desc
        ), '[]'::jsonb)
        from public.batch_allocations a
        join public.batches b       on b.id = a.batch_id
        join public.organizations o on o.id = b.organization_id
        left join public.regions r  on r.id = b.region_id
        where a.pool_id = p_pool_id
          and a.status <> 'cancelled'
    );
end;
$$;
comment on function public.rpc_get_pool_matches(uuid) is
    'КАНОН d02 +Слайс 9 (S3) | Матчи пула по КУСКАМ (batch_allocations, а не b.pool_line_id) —
     МПК видит все куски. matchId=allocation.id (для rpc_self_confirm_delivery_alloc), heads/
     price с куска, status из статуса куска. Контакты фермы после mpk_contact_revealed_at (D40).';
revoke execute on function public.rpc_get_pool_matches(uuid) from anon;
grant  execute on function public.rpc_get_pool_matches(uuid) to authenticated;
