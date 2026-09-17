-- РЕМОНТ ДАННЫХ · счётчики живых заявок, разошедшиеся с реальностью
-- Причина — TSP-WITHDRAW-POOLCOUNTER-01: `rpc_self_withdraw_batch` не уменьшал счётчики
-- заявки при снятии партии, привязанной ЦЕЛИКОМ (реверс жил только в цикле по кускам).
-- Заявка навсегда считала снятые головы набранными и не могла добрать.
--
-- ЗАПУСК — сначала ВСЕГДА вхолостую (по умолчанию):
--   python3 scripts/run_sql_rollback.py scripts/repair_pool_matched_heads.sql
-- Печатает состояние ДО и ПОСЛЕ и откатывается. Применять — `--apply`, по решению человека.
--
-- ЧТО СЧИТАЕТСЯ ИСТИНОЙ: набранное заявки = активные куски (`batch_allocations` не
-- `cancelled`) + партии маршрута «целиком» (привязаны через `pool_line_id`, аллокаций нет
-- вовсе, статус не рыночный и не терминальный). Предикат маршрута — тот же, что в
-- read-model ARS-684 и в фиксе: «нет НИ ОДНОЙ аллокации у партии».
--
-- ЧЕГО РЕМОНТ НЕ ДЕЛАЕТ:
--   · не трогает ТЕРМИНАЛЬНЫЕ заявки (closed_*, completed, cancelled, expired_empty,
--     executed, closed) — их числа это история закрытой сделки, а не живой остаток (FR-006);
--   · не трогает события и репутацию: двое фермеров, снявших проданные партии до фикса,
--     штрафа избежали, и переписывать историю снятий задним числом запрещено (FR-010) —
--     это был бы подлог, а не ремонт;
--   · не меняет статусы партий — только счётчики заявок и их строк.
--
-- Идемпотентность: берёт только заявки, где счётчик расходится с пересчётом. Повторный
-- прогон после успешного применения не найдёт ничего.

do $$
declare
    v_pool   record;
    v_line   record;
    v_real   int;
    v_fixed  int := 0;
    v_lines  int := 0;
begin
    raise notice '=== ДО РЕМОНТА: живые заявки, где счётчик врёт ===';
    for v_pool in
        select p.id, p.status, p.target_heads, p.matched_heads,
               coalesce((select sum(a.heads) from public.batch_allocations a
                          where a.pool_id = p.id and a.status <> 'cancelled'), 0)
             + coalesce((select sum(b.heads) from public.batches b
                          join public.pool_lines pl on pl.id = b.pool_line_id
                         where pl.pool_id = p.id
                           and b.status in ('matched','partially_matched','confirmed','dispatched','delivered')
                           and not exists (select 1 from public.batch_allocations a2
                                            where a2.batch_id = b.id)), 0) as real_heads
        from public.pools p
        where p.status not in ('cancelled','closed_filled','closed_partial','closed_unfilled',
                               'completed','expired_empty','executed','closed')
        order by p.matched_heads desc
    loop
        if v_pool.matched_heads <> v_pool.real_heads then
            raise notice 'заявка % (%): счётчик % → реально % (из % целевых)',
                left(v_pool.id::text, 8), v_pool.status, v_pool.matched_heads,
                v_pool.real_heads, v_pool.target_heads;
        end if;
    end loop;

    -- ── Ремонт счётчика заявки ────────────────────────────────────────────────────────
    for v_pool in
        select p.id, p.matched_heads,
               coalesce((select sum(a.heads) from public.batch_allocations a
                          where a.pool_id = p.id and a.status <> 'cancelled'), 0)
             + coalesce((select sum(b.heads) from public.batches b
                          join public.pool_lines pl on pl.id = b.pool_line_id
                         where pl.pool_id = p.id
                           and b.status in ('matched','partially_matched','confirmed','dispatched','delivered')
                           and not exists (select 1 from public.batch_allocations a2
                                            where a2.batch_id = b.id)), 0) as real_heads
        from public.pools p
        where p.status not in ('cancelled','closed_filled','closed_partial','closed_unfilled',
                               'completed','expired_empty','executed','closed')
        for update of p
    loop
        if v_pool.matched_heads <> v_pool.real_heads then
            update public.pools
            set matched_heads = v_pool.real_heads, updated_at = now()
            where id = v_pool.id;
            v_fixed := v_fixed + 1;
        end if;
    end loop;

    -- ── Ремонт счётчиков строк той же формулой, но в разрезе строки ───────────────────
    for v_line in
        select pl.id, pl.pool_id, pl.current_heads, pl.current_volume_kg,
               coalesce((select sum(a.heads) from public.batch_allocations a
                          where a.pool_line_id = pl.id and a.status <> 'cancelled'), 0)
             + coalesce((select sum(b.heads) from public.batches b
                         where b.pool_line_id = pl.id
                           and b.status in ('matched','partially_matched','confirmed','dispatched','delivered')
                           and not exists (select 1 from public.batch_allocations a2
                                            where a2.batch_id = b.id)), 0) as real_heads,
               coalesce((select sum(round(a.heads * b2.avg_weight_kg)::int)
                           from public.batch_allocations a
                           join public.batches b2 on b2.id = a.batch_id
                          where a.pool_line_id = pl.id and a.status <> 'cancelled'), 0)
             + coalesce((select sum(round(b.heads * b.avg_weight_kg)::int) from public.batches b
                         where b.pool_line_id = pl.id
                           and b.status in ('matched','partially_matched','confirmed','dispatched','delivered')
                           and not exists (select 1 from public.batch_allocations a2
                                            where a2.batch_id = b.id)), 0) as real_vol
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where p.status not in ('cancelled','closed_filled','closed_partial','closed_unfilled',
                               'completed','expired_empty','executed','closed')
        for update of pl
    loop
        if v_line.current_heads <> v_line.real_heads
           or v_line.current_volume_kg <> v_line.real_vol then
            update public.pool_lines
            set current_heads     = v_line.real_heads,
                current_volume_kg = v_line.real_vol,
                updated_at        = now()
            where id = v_line.id;
            v_lines := v_lines + 1;
        end if;
    end loop;

    raise notice '=== ИСПРАВЛЕНО: заявок % · строк % ===', v_fixed, v_lines;

    -- ── Контроль: после ремонта расхождений быть не должно ───────────────────────────
    select count(*) into v_real
    from public.pools p
    where p.status not in ('cancelled','closed_filled','closed_partial','closed_unfilled',
                           'completed','expired_empty','executed','closed')
      and p.matched_heads <>
          coalesce((select sum(a.heads) from public.batch_allocations a
                     where a.pool_id = p.id and a.status <> 'cancelled'), 0)
        + coalesce((select sum(b.heads) from public.batches b
                     join public.pool_lines pl on pl.id = b.pool_line_id
                    where pl.pool_id = p.id
                      and b.status in ('matched','partially_matched','confirmed','dispatched','delivered')
                      and not exists (select 1 from public.batch_allocations a2
                                       where a2.batch_id = b.id)), 0);
    if v_real > 0 then
        raise exception 'РЕМОНТ НЕ ПОЛНЫЙ: у % живых заявок счётчик всё ещё расходится', v_real;
    end if;
    raise notice 'контроль пройден: у живых заявок счётчик сходится с реальностью';
end;
$$;
