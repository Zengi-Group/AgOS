-- AgOS · БЕТА · Слайс 9 (S1b) · САМООТМЕНА партии с учётом дробления.
-- ============================================================================
-- ФИЧА (CEO, 2026-07-02): после дробления батча фермер должен уметь корректно
-- снимать партию с учётом того, что часть уже продана КУСКАМИ:
--   • ОСТАТОК (непроданные головы) — снимается ВСЕГДА и БЕЗПЛАТНО (просто уходит
--     с рынка: отзываем pending-офферы, батч выходит из matchable-набора).
--   • MATCHED-куски (пул ещё набирается) — можно отменить, но ЗА ШТРАФ
--     (batch_events 'cancelled_after_match' → драйвер репутации D-TSP-14).
--     Только по явному флагу p_include_matched = true.
--   • CONFIRMED-куски (пул заполнился, готов к отгрузке) — ЗАЛОЧЕНЫ, снять нельзя.
--   • Батч в статусе confirmed/dispatched/delivered — снять нельзя целиком.
--
-- ПОЧЕМУ БЕЗ НОВОЙ КОЛОНКИ: снятие остатка = перевод статуса из matchable-набора
--   (published/offering/partially_matched) в 'matched' (или 'cancelled', если ничего
--   не продано). Матч-RPC матчат только status ∈ (published/offering/partially_matched)
--   AND matched_heads < heads — 'matched' автоматически исключает батч из матчинга.
--   Фронт трактует «matched при matched_heads < heads» как «остаток снят».
--
-- ПОБОЧНО (аддитивно, чинит совместимость с дроблением):
--   • fn_tsp_alloc_chunk: закрытие пула теперь подтверждает батч по условию
--     status='matched' (а не matched_heads=heads) и игнорирует cancelled-куски —
--     иначе remainder-withdrawn/частично-отменённый батч не смог бы дойти до confirmed.
--   • rpc_cancel_batch: жёсткий гейт — если по батчу есть аллокации, слепой
--     status='cancelled' осиротил бы проданные куски → перенаправляем на withdraw.
--
-- Сигнатуры существующих RPC не меняются (P7). Идемпотентно. Зависимость:
-- 20260702160000 (batch_allocations, fn_tsp_alloc_chunk, matched_heads). SQL Editor.
-- ============================================================================


-- ── 1. fn_tsp_alloc_chunk — устойчивое закрытие пула (confirm по status) ──────
-- Единственное изменение против 20260702160000: блок закрытия пула подтверждает
-- батч по status='matched' (а не matched_heads=heads) и «нет активных matched-кусков»
-- (cancelled игнорируются). Это нужно, чтобы remainder-withdrawn батч (status='matched'
-- при matched_heads<heads) и частично-отменённый батч корректно доходили до confirmed.
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
            -- Батч → confirmed, когда он уже вне рынка (status='matched': полностью продан
            -- ИЛИ остаток снят) и не осталось активных matched-кусков (cancelled игнорируем).
            update public.batches b
            set status = 'confirmed', confirmed_at = now(), updated_at = now()
            where b.id in (select batch_id from public.batch_allocations where pool_id = v_pool.id)
              and b.status = 'matched'
              and not exists (select 1 from public.batch_allocations a
                              where a.batch_id = b.id and a.status = 'matched');
        end if;
    end if;

    return v_take;
end;
$$;
comment on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) is
    'Слайс 9 (+S1b) | Аллокатор куска батча в строку пула. take=min(остаток,свободно строки/
     пула/kg[,кап]) + правило min_split (авто) + инкременты + FSM батча. Закрытие пула
     подтверждает батч по status=''matched'' (полностью продан ИЛИ остаток снят), cancelled
     куски игнорируются. Возвращает взятые головы (0=ничего). Зовётся из 4 матч-RPC.';
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from anon;
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from authenticated;


-- ── 2. rpc_self_withdraw_batch — самоотмена остатка / matched-кусков ──────────
create or replace function public.rpc_self_withdraw_batch(
    p_batch_id        uuid,
    p_include_matched boolean default false   -- true = отменить и matched-куски (за штраф)
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
    v_reversed  int := 0;   -- всего снято голов из matched-кусков
    v_penalized int := 0;   -- сколько matched-кусков отменено (штрафных)
    v_matched   int;        -- активные matched-головы (после реверса)
    v_confirmed int;        -- подтверждённые (залоченные) головы
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

    -- Пул заполнен и готов к отгрузке / уже в отгрузке → снимать нельзя (CEO 2026-07-02).
    if v_batch.status in ('confirmed', 'dispatched', 'delivered') then
        raise exception 'BATCH_LOCKED: партия подтверждена/в отгрузке — снять нельзя'
            using errcode = 'P0003';
    end if;
    if v_batch.status in ('cancelled', 'failed', 'expired') then
        raise exception 'BATCH_NOT_ACTIVE: партия уже завершена' using errcode = 'P0004';
    end if;

    -- 2a. Отмена matched-кусков (только по флагу) — реверс счётчиков + штрафное событие.
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
            -- Штрафное событие BT-15 → репутация фермера (D-TSP-14).
            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            values (p_batch_id, 'cancelled_after_match',
                jsonb_build_object('allocation_id', v_alloc.id, 'pool_id', v_alloc.pool_id,
                                   'pool_line_id', v_alloc.pool_line_id, 'heads', v_alloc.heads,
                                   'penalty', true), v_uid);
            v_reversed  := v_reversed + v_alloc.heads;
            v_penalized := v_penalized + 1;
        end loop;
    end if;

    -- 2b. Снять остаток с рынка: отозвать «висящие» pending-офферы (безплатно).
    update public.offers set status = 'withdrawn', responded_at = now()
    where batch_id = p_batch_id and status = 'pending';

    -- 2c. Пересчёт активных голов и нового статуса.
    select coalesce(sum(heads) filter (where status = 'matched'), 0),
           coalesce(sum(heads) filter (where status = 'confirmed'), 0)
      into v_matched, v_confirmed
    from public.batch_allocations where batch_id = p_batch_id;
    v_active := v_matched + v_confirmed;

    if v_active = 0 then
        v_new_status := 'cancelled';       -- ничего не продано (либо всё отменено) + остаток снят
    elsif v_matched = 0 then
        v_new_status := 'confirmed';       -- остались только подтверждённые куски → готов к отгрузке
    else
        v_new_status := 'matched';         -- часть продана, остаток снят, ждём заполнения пулов
    end if;

    update public.batches
    set matched_heads = v_active,
        status        = v_new_status,
        matched_at    = case when v_active > 0 then coalesce(matched_at, now()) else matched_at end,
        confirmed_at  = case when v_new_status = 'confirmed' then coalesce(confirmed_at, now()) else confirmed_at end,
        cancelled_at  = case when v_new_status = 'cancelled' then now() else cancelled_at end,
        updated_at    = now()
    where id = p_batch_id;

    -- Итоговое событие: штраф был → after_match; ничего не продано → before_match; иначе — снят остаток.
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
    'Слайс 9 (S1b) | Самоотмена партии с учётом дробления. Остаток снимается всегда/безплатно
     (отзыв pending-офферов, батч выходит из matchable). matched-куски — только при
     p_include_matched=true и ЗА ШТРАФ (реверс счётчиков + cancelled_after_match, D-TSP-14).
     confirmed-куски залочены; confirmed/dispatched/delivered батч снять нельзя. Гейт fn_my_org_ids().';
revoke execute on function public.rpc_self_withdraw_batch(uuid, boolean) from anon;
grant  execute on function public.rpc_self_withdraw_batch(uuid, boolean) to authenticated;


-- ── 3. rpc_cancel_batch — жёсткий гейт против осиротения проданных кусков ─────
-- Старый rpc_cancel_batch слепо ставил status='cancelled'. Для дроблёного батча это
-- осиротило бы проданные куски (МПК считает, что купил). Теперь: если по батчу есть
-- аллокации (matched_heads>0) — запрещаем и просим использовать rpc_self_withdraw_batch.
-- Для draft/published/scheduled/offering без аллокаций поведение прежнее.
create or replace function public.rpc_cancel_batch(p_batch_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch public.batches%rowtype;
begin
    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002';
    end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;
    -- Дроблёный батч: слепая отмена осиротила бы проданные куски.
    if coalesce(v_batch.matched_heads, 0) > 0 then
        raise exception 'HAS_ALLOCATIONS: у партии есть проданные куски — используйте rpc_self_withdraw_batch'
            using errcode = 'P0005';
    end if;
    if v_batch.status in ('confirmed', 'dispatched', 'delivered') then
        raise exception 'BATCH_LOCKED: партия подтверждена/в отгрузке — снять нельзя'
            using errcode = 'P0003';
    end if;

    -- Снять «висящие» офферы (если батч был на broadcast).
    update public.offers set status = 'withdrawn', responded_at = now()
    where batch_id = p_batch_id and status = 'pending';

    update public.batches
    set status = 'cancelled', cancelled_at = now(), updated_at = now()
    where id = p_batch_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'cancelled_before_match',
        jsonb_build_object('via', 'farmer', 'prev_status', v_batch.status), public.fn_current_user_id());
    return true;
end;
$$;
comment on function public.rpc_cancel_batch(uuid) is
    'КАНОН d02 | Слайс 6 (+S1b) | Снятие своей партии БЕЗ проданных кусков → cancelled
     (отзыв pending-офферов + cancelled_before_match). При matched_heads>0 отсылает на
     rpc_self_withdraw_batch. confirmed/dispatched/delivered залочены. Гейт fn_my_org_ids().';
revoke execute on function public.rpc_cancel_batch(uuid) from anon;
grant  execute on function public.rpc_cancel_batch(uuid) to authenticated;
