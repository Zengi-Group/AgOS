-- ============================================================================
-- ВЫКЛАДКА TSP-WITHDRAW-POOLCOUNTER-01 · снятие партии возвращает место в заявке
-- PR #200 (смержен 2026-09-17) · спек Docs/AGOS-TSP-WithdrawBatch-PoolCounter-FIX.md
--
-- ⚠️ ТОЧЕЧНО, а не миграцией целиком: 20260702190000_tsp_chunk_dispatch.sql содержит
-- rpc_get_pool_matches, чья живая версия — в 20260910120000 (двухмаршрутная read-model
-- ARS-684, починена 10.09). Полный реплей откатил бы монитор заявки. Берём ровно одну
-- функцию, которую изменил фикс.
--
-- ЗАПУСК: python3 scripts/run_sql_rollback.py scripts/deploy/deploy_withdraw_counter.sql
--         (по умолчанию ROLLBACK; --apply применяет)
-- ПОСЛЕ:  python3 scripts/prod_diff.py
-- ============================================================================

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
    v_pool_id   uuid;     -- маршрут «целиком»: заявка, в которой висит партия
    v_pool_st   text;     -- её статус — терминальной счётчик не правим (FR-006)
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

    -- 2b. ВТОРОЙ МАРШРУТ МАТЧА — партия, привязанная ЦЕЛИКОМ (TSP-WITHDRAW-POOLCOUNTER-01).
    -- Цикл выше знает только куски, поэтому для партии без аллокаций не срабатывало НИЧЕГО:
    -- у заявки не уменьшалось набранное (она навсегда считала эти головы своими и не могла
    -- добрать), а событие писалось как 'cancelled_before_match' — «снята до матча», хотя
    -- партия была продана, то есть фермер не отвечал за отказ от сделки. Канон требует обоих
    -- действий: MS6 §4f шаг 8c — «у МПК filled −= … Авто-пишется в cancelled_after_match →
    -- рейтинг фермера (D-TSP-14)». Эмпирика 17.09: заявка 80/80 при 29 реальных головах.
    --
    -- Предикат маршрута — «нет НИ ОДНОЙ аллокации у партии» (как в read-model ARS-684,
    -- 20260910120000:126-141): fn_tsp_alloc_chunk пишет batches.pool_line_id на первом куске,
    -- поэтому дроблёная партия тоже имеет привязку — и без этого условия её головы вычлись бы
    -- дважды: раз циклом по кускам, раз здесь (M-004).
    if v_batch.pool_line_id is not null
       and coalesce(v_batch.matched_heads, 0) > 0
       and not exists (select 1 from public.batch_allocations a where a.batch_id = p_batch_id)
    then
        select p.id, p.status into v_pool_id, v_pool_st
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.id = v_batch.pool_line_id;

        -- FR-006: у терминальной заявки счётчик — история закрытой сделки, а не живой
        -- остаток; её числа не трогаем. Живой заявке возвращаем место, чтобы она добрала.
        if v_pool_st is not null and v_pool_st not in
           ('cancelled','closed_filled','closed_partial','closed_unfilled',
            'completed','expired_empty','executed','closed') then
            v_vol := coalesce(round(v_batch.matched_heads * v_batch.avg_weight_kg)::int, 0);
            update public.pool_lines
            set current_heads     = greatest(current_heads - v_batch.matched_heads, 0),
                current_volume_kg = greatest(current_volume_kg - v_vol, 0),
                updated_at        = now()
            where id = v_batch.pool_line_id;
            update public.pools
            set matched_heads = greatest(matched_heads - v_batch.matched_heads, 0),
                updated_at    = now()
            where id = v_pool_id;
        end if;

        -- FR-004: партия была продана — за отказ отвечают одинаково, каким бы маршрутом
        -- она ни была привязана. v_penalized ниже превращает событие в cancelled_after_match.
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (p_batch_id, 'cancelled_after_match',
            jsonb_build_object('pool_id', v_pool_id, 'pool_line_id', v_batch.pool_line_id,
                               'heads', v_batch.matched_heads, 'penalty', true,
                               'route', 'batch'), v_uid);
        v_reversed  := v_reversed + v_batch.matched_heads;
        v_penalized := v_penalized + 1;
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
     confirmed/dispatched/delivered батч снять нельзя. Гейт fn_my_org_ids().
     TSP-WITHDRAW-POOLCOUNTER-01: реверс и штраф покрывают ОБА маршрута матча — куски
     (batch_allocations) и партию целиком (batches.pool_line_id у партии без аллокаций).
     Второй маршрут раньше не обрабатывался вовсе: заявка навсегда считала снятые головы
     набранными и не могла добрать, а снятие проданной партии писалось как
     cancelled_before_match — без штрафа репутации (MS6 §4f шаг 8c). У ТЕРМИНАЛЬНОЙ заявки
     счётчик не правится: её числа — история закрытой сделки.';
revoke execute on function public.rpc_self_withdraw_batch(uuid, boolean) from public, anon;
grant  execute on function public.rpc_self_withdraw_batch(uuid, boolean) to authenticated;

