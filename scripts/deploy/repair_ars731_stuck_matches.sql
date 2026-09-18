-- ============================================================================
-- РЕМОНТ ARS-731 · сделки, застрявшие в `matched` при закрытой-набранной заявке
-- Спек: Docs/AGOS-TSP-PoolClose-ConfirmBothForms-ARS-731.md (FR-004/FR-005/FR-014)
--
-- ЗАЧЕМ. До ARS-731 каждый из четырёх путей закрытия заявки подтверждал только
-- СВОЮ форму записи сделки и оставлял чужую в `matched`. Такая сделка — тупик:
-- у фермера нет хода «Отметьте отгрузку», у комбината строка врёт «Ожидает
-- отгрузки». Миграция 20260918120000 закрывает путь на будущее; этот скрипт
-- лечит то, что уже застряло (на проде — как минимум партия 30 гол. при заявке
-- 80/80 `completed`, IMPL_DEBT → MPK-AWAITING-DISPATCH-FALSE-01).
--
-- ПОЧЕМУ НЕ ЗОВЁМ fn_tsp_pool_confirm_matches. Она — правильный дом правила для
-- живых путей, но для ремонта не годится: её маршрут 1 эмитит batch.confirmed по
-- КАЖДОЙ не-отменённой аллокации заявки, включая давно подтверждённые. Повторный
-- прогон вставлял бы новые строки в batch_events, а FR-005 требует ровно ноль
-- изменённых строк на повторе. Поэтому ремонт пишет статусы напрямую и НЕ эмитит
-- событий: подтверждение произошло в прошлом, задним числом его никто не слышал.
--
-- ИДЕМПОТЕНТНОСТЬ (FR-005). Обе формы правятся только из `matched`; rollup
-- статуса партии зовётся ТОЛЬКО для партий, чьи куски изменил ЭТОТ прогон
-- (rollup пишет updated_at безусловно — вызов «на всякий случай» сам по себе
-- был бы изменением строки).
--
-- ЗАПУСК: python3 scripts/run_sql_rollback.py scripts/deploy/repair_ars731_stuck_matches.sql
--         (по умолчанию ROLLBACK — прогон показывает счётчики и откатывается;
--          --apply применяет). ПОСЛЕ: python3 scripts/prod_diff.py
-- ============================================================================

do $repair$
declare
    -- FR-004: заявка закрыта КАК НАБРАННАЯ. Перечень сверен с pools_status_check
    -- (d02_tsp.sql): все 15 разрешённых значений распределены между этим списком
    -- и FR-014. Легаси-значения названы поимённо, а не подразумеваются.
    c_filled   constant text[] := array[
        'closed_filled', 'closed_partial', 'completed', 'executing', 'executed',
        'filled', 'dispatched', 'delivered'
    ];
    v_alloc_before int;
    v_batch_before int;
    v_alloc_fixed  int := 0;
    v_batch_fixed  int := 0;
    v_rolled       int := 0;
    v_bid          uuid;
    v_touched      uuid[] := array[]::uuid[];
begin
    -- ── ИЗМЕРЕНИЕ ДО ────────────────────────────────────────────────────────
    select count(*) into v_alloc_before
    from public.batch_allocations a
    join public.pools p on p.id = a.pool_id
    where a.status = 'matched' and p.status = any (c_filled);

    select count(*) into v_batch_before
    from public.batches b
    join public.pool_lines pl on pl.id = b.pool_line_id
    join public.pools p on p.id = pl.pool_id
    where b.status = 'matched' and p.status = any (c_filled)
      and not exists (select 1 from public.batch_allocations a where a.batch_id = b.id);

    raise notice 'ДО ремонта: аллокаций в matched = %, партий-ссылок в matched = %',
        v_alloc_before, v_batch_before;

    -- ── ФОРМА 1: строка в batch_allocations (ручной матч с маркет-борда) ─────
    with fixed as (
        update public.batch_allocations a
        set status = 'confirmed', confirmed_at = now()
        from public.pools p
        where p.id = a.pool_id
          and a.status = 'matched'
          and p.status = any (c_filled)
        returning a.batch_id
    )
    select count(*), coalesce(array_agg(distinct batch_id), array[]::uuid[])
      into v_alloc_fixed, v_touched
    from fixed;

    -- Статус партии = её отстающий кусок. Зовём rollup только по партиям, чьи
    -- куски реально изменились в этом прогоне: партия с остатком на рынке
    -- останется partially_matched — rollup сам её пропустит (M-005).
    foreach v_bid in array v_touched loop
        perform public.fn_tsp_rollup_batch_status(v_bid);
        v_rolled := v_rolled + 1;
    end loop;

    -- ── ФОРМА 2: ссылка в самой партии (авто-матч при публикации) ────────────
    -- Предикат дословно как маршрут 2 fn_tsp_pool_confirm_matches: партия,
    -- привязанная целиком и НИКОГДА не дробившаяся (ни одной аллокации, в любой
    -- заявке и в любом статусе). У дроблёных партий статус считает rollup выше.
    with fixed as (
        update public.batches b
        set status       = 'confirmed',
            confirmed_at = coalesce(b.confirmed_at, now()),
            updated_at   = now()
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.id = b.pool_line_id
          and b.status = 'matched'
          and p.status = any (c_filled)
          and not exists (select 1 from public.batch_allocations a where a.batch_id = b.id)
        returning b.id
    )
    select count(*) into v_batch_fixed from fixed;

    -- ── ИЗМЕРЕНИЕ ПОСЛЕ ─────────────────────────────────────────────────────
    -- Приёмка не «одна известная партия», а множество: всё, что попало под
    -- FR-004, перешло в confirmed; ничего вне множества не изменилось
    -- (последнее доказывается предикатами выше — заявки из FR-014 в них не входят).
    -- M-006 закрывается этой парой чисел: всё, что попало под FR-004, перешло в
    -- confirmed. Id назван явно — Matrix Test Audit слайса сверяет ПО ID, совпадение
    -- «по смыслу» считается непокрытым, а прибор для M-006/M-007 по §Verification —
    -- именно этот прогон, а не отдельный тест.
    raise notice 'M-006 отремонтировано: аллокаций = %, партий-ссылок = %, rollup партий = %',
        v_alloc_fixed, v_batch_fixed, v_rolled;

    -- Что этот сторож ловит НА САМОМ ДЕЛЕ: измерение и update ходят по байт-в-байт
    -- одинаковым предикатам в одной транзакции, поэтому разойтись они могут только из-за
    -- ПАРАЛЛЕЛЬНОГО писателя. Ошибку в самом перечне c_filled он поймать не может — она
    -- одинаково сместит оба числа. Сообщение говорит ровно это, чтобы сторож не выдавал
    -- себя за проверку полноты ремонта, которой он не является.
    if v_alloc_fixed <> v_alloc_before or v_batch_fixed <> v_batch_before then
        raise exception 'СЧЁТ РАЗОШЁЛСЯ: до = %/%, починено = %/% — между измерением и '
                        'правкой кто-то писал в те же строки; прогони заново',
            v_alloc_before, v_batch_before, v_alloc_fixed, v_batch_fixed;
    end if;

    if v_alloc_fixed = 0 and v_batch_fixed = 0 then
        raise notice 'Изменений нет — ремонт уже применён (FR-005: повтор ничего не меняет).';
    end if;

    -- ── КОНТРОЛЬ FR-014: заявки без набора и ещё живые не тронуты ────────────
    -- Печатается NOTICE, а не select'ом: прогон идёт через run_sql_rollback.py, который
    -- результирующие наборы не показывает — контроль, который никто не видит, контролем
    -- не является. Строки здесь — НЕ дефект: их сделки обязаны остаться в `matched`
    -- (партии возвращаются на рынок либо продолжают набор, дом ARS-314).
    -- Две формы считаются РАЗНЫМИ подзапросами, а не одним многоджойновым: один join
    -- pools→аллокации и pools→строки→партии перемножает строки и печатает завышенные
    -- числа — контроль, врущий в свою пользу, хуже отсутствующего.
    declare
        r record;
    begin
        for r in
            select s.pool_status,
                   (select count(*) from public.batch_allocations a
                     join public.pools p on p.id = a.pool_id
                    where a.status = 'matched' and p.status = s.pool_status) as allocs_matched,
                   (select count(*) from public.batches b
                     join public.pool_lines pl on pl.id = b.pool_line_id
                     join public.pools p on p.id = pl.pool_id
                    where b.status = 'matched' and p.status = s.pool_status) as batches_matched
            from (select unnest(array['cancelled', 'closed_unfilled', 'expired_empty', 'closed',
                                      'filling', 'awaiting_mpk_decision', 'draft']) as pool_status) s
            order by s.pool_status
        loop
            if r.allocs_matched > 0 or r.batches_matched > 0 then
                raise notice 'M-007 · FR-014 не тронуто: заявки % — аллокаций в matched %, партий-ссылок %',
                    r.pool_status, r.allocs_matched, r.batches_matched;
            end if;
        end loop;
    end;
end
$repair$;
