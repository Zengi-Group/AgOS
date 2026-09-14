-- РЕМОНТ ДАННЫХ · куски, осиротевшие в ОТМЕНЁННЫХ заявках
-- Найдено при приёмке ARS-695 (2026-09-14). Причина — TSP-CANCELPOOL-ALLOC-01:
-- rpc_cancel_pool переводит заявку в 'cancelled' и НЕ трогает batch_allocations,
-- поэтому кусок партии остаётся 'matched' в мёртвой заявке. Последствия для фермера:
-- batches.matched_heads продолжает считать эти головы проданными, партия висит
-- 'matched' (rollup берёт минимум по активным кускам), отгрузить её нельзя — сделки
-- нет, — и на рынок остаток не возвращается.
--
-- ЭТО РЕМОНТ СЛЕДСТВИЯ. Причина живёт в rpc_cancel_pool и здесь НЕ чинится: правка
-- боевой функции — отдельное решение с отдельной проверкой (долг зарегистрирован).
-- Без неё каждая новая отмена заявки с кусками породит ту же сироту.
--
-- ЗАПУСК — сначала ВСЕГДА в откатываемом виде (по умолчанию):
--   python3 scripts/run_sql_rollback.py scripts/repair_ars695_stranded_allocations.sql
-- Скрипт печатает состояние ДО и ПОСЛЕ и откатывается. Применять по-настоящему —
-- только после того, как человек прочитал вывод и согласился.
--
-- Идемпотентность: берёт только куски в статусе 'matched', заявка которых 'cancelled'.
-- Повторный прогон после успешного применения не найдёт ничего и ничего не изменит.

do $$
declare
    v_alloc   record;
    v_vol     int;
    v_active  int;
    v_batch   record;
    v_fixed   int := 0;
begin
    raise notice '=== ДО РЕМОНТА ===';
    for v_alloc in
        select a.id, a.batch_id, a.pool_id, a.pool_line_id, a.heads,
               b.heads as batch_heads, b.status as batch_status,
               b.matched_heads as batch_matched, b.avg_weight_kg,
               p.status as pool_status
        from public.batch_allocations a
        join public.batches b on b.id = a.batch_id
        join public.pools  p on p.id = a.pool_id
        where a.status = 'matched' and p.status = 'cancelled'
        order by a.matched_at
    loop
        raise notice 'кусок % (% гол) в ОТМЕНЁННОЙ заявке % | партия %: статус=%, matched_heads=% из % гол',
            left(v_alloc.id::text, 8), v_alloc.heads, left(v_alloc.pool_id::text, 8),
            left(v_alloc.batch_id::text, 8), v_alloc.batch_status,
            v_alloc.batch_matched, v_alloc.batch_heads;
    end loop;

    -- ---------------------------------------------------------------------------------
    -- Сам ремонт. Инварианты повторяют rpc_self_withdraw_batch (20260702180000:216-237)
    -- и fn_tsp_pool_release_matches (ARS-695): реверс счётчиков заявки и строки, затем
    -- пересчёт статуса партии из ОСТАВШИХСЯ активных кусков.
    -- ---------------------------------------------------------------------------------
    for v_alloc in
        select a.id, a.batch_id, a.pool_id, a.pool_line_id, a.heads, b.avg_weight_kg
        from public.batch_allocations a
        join public.batches b on b.id = a.batch_id
        join public.pools  p on p.id = a.pool_id
        where a.status = 'matched' and p.status = 'cancelled'
        for update of a
    loop
        v_vol := coalesce(round(v_alloc.heads * v_alloc.avg_weight_kg)::int, 0);

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

        -- Событие нейтральное: заявку отменил комбинат, фермер ни при чём. Штрафной
        -- cancelled_after_match здесь был бы клеветой на фермера (драйвер репутации D-TSP-14).
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_alloc.batch_id, 'returned_to_published',
            jsonb_build_object('pool_id', v_alloc.pool_id, 'pool_line_id', v_alloc.pool_line_id,
                               'allocation_id', v_alloc.id, 'heads', v_alloc.heads,
                               'reason', 'pool_cancelled_repair', 'route', 'allocation',
                               'repair', 'TSP-CANCELPOOL-ALLOC-01'),
            null);

        -- Статус партии из оставшихся активных кусков (не-cancelled: сюда входят и
        -- dispatched/delivered — они уже уехали к своему покупателю и свободными не являются).
        select coalesce(sum(heads), 0) into v_active
        from public.batch_allocations
        where batch_id = v_alloc.batch_id and status <> 'cancelled';

        select * into v_batch from public.batches where id = v_alloc.batch_id for update;

        if v_batch.status in ('cancelled', 'failed', 'expired', 'delivered') then
            -- ТЕРМИНАЛЬНУЮ партию не воскрешаем: снятую фермером нельзя вернуть на
            -- рынок ремонтом счётчиков, а доставленную — тем более. Правим ТОЛЬКО
            -- matched_heads, чтобы счётчик перестал врать. (Первый откатываемый прогон
            -- 14.09 показал, почему эта ветка обязана быть: без неё скрипт переводил
            -- три `cancelled`-партии в `published` — возвращал на рынок снятый скот.)
            update public.batches
            set matched_heads = v_active, updated_at = now()
            where id = v_alloc.batch_id;
        elsif v_active = 0 then
            -- Активная партия без единого живого куска — снова целиком на рынке.
            update public.batches
            set matched_heads = 0, status = 'published',
                pool_line_id = null, deal_price_per_kg = null, updated_at = now()
            where id = v_alloc.batch_id;
        else
            update public.batches
            set matched_heads = v_active,
                status = case when v_active < v_batch.heads
                              then 'partially_matched' else v_batch.status end,
                updated_at = now()
            where id = v_alloc.batch_id;
        end if;

        v_fixed := v_fixed + 1;
    end loop;

    raise notice '=== ОТРЕМОНТИРОВАНО КУСКОВ: % ===', v_fixed;

    raise notice '=== ПОСЛЕ РЕМОНТА ===';
    for v_batch in
        select b.id, b.heads, b.status, b.matched_heads,
               (select string_agg(a.status || ':' || a.heads, ' | ' order by a.matched_at)
                  from public.batch_allocations a where a.batch_id = b.id) as allocs
        from public.batches b
        where exists (
            select 1 from public.batch_events e
            where e.batch_id = b.id and e.metadata->>'repair' = 'TSP-CANCELPOOL-ALLOC-01'
        )
    loop
        raise notice 'партия % (% гол): статус=%, matched_heads=%, куски: %',
            left(v_batch.id::text, 8), v_batch.heads, v_batch.status,
            v_batch.matched_heads, v_batch.allocs;
    end loop;

    -- Контроль №2: ремонт не имеет права воскрешать терминальные партии.
    select count(*) into v_active
    from public.batches b
    where b.status = 'published'
      and exists (select 1 from public.batch_events e
                   where e.batch_id = b.id and e.metadata->>'repair' = 'TSP-CANCELPOOL-ALLOC-01')
      and exists (select 1 from public.batch_events e2
                   where e2.batch_id = b.id
                     and e2.event_type in ('cancelled_before_match', 'cancelled_after_match'));
    if v_active > 0 then
        raise exception 'РЕМОНТ ВОСКРЕСИЛ % снятых партий — это порча данных, а не ремонт', v_active;
    end if;

    -- Контроль: ни одного куска в отменённой заявке остаться не должно.
    select count(*) into v_active
    from public.batch_allocations a join public.pools p on p.id = a.pool_id
    where a.status = 'matched' and p.status = 'cancelled';
    if v_active > 0 then
        raise exception 'РЕМОНТ НЕ ПОЛНЫЙ: осталось % кусков в отменённых заявках', v_active;
    end if;
    raise notice 'контроль пройден: кусков в отменённых заявках не осталось';
end;
$$;
