-- ============================================================================
-- РЕМОНТ ARS-754 · партии, которые уже оказались «частями» (partially_matched)
-- Спек: Docs/AGOS-TSP-WholeBatchOnly-ARS-754.md (FR-010 / FR-011 / FR-012)
--
-- ЗАЧЕМ. До ARS-754 ручная привязка резала партию: брала столько голов, сколько
-- влезало в заявку, и оставляла остаток в `partially_matched`. Остаток не продаётся
-- нигде (маркет-борд и автоматика его не берут), а экран фермера обещал обратное.
-- Замер 24.09: таких партий две — cdb6e93c (20 гол., продано 10) и fecf6595
-- (23 гол., продано 9); проданная часть обеих уже `delivered`.
--
-- ПРЕДИКАТ — ПРИЗНАК, А НЕ СПИСОК ID (FR-010): все партии в `partially_matched` на
-- момент прогона.
--
-- ИСХОД — КАК У КНОПКИ ФЕРМЕРА «Снять остаток» (rpc_self_withdraw_batch без отмены
-- проданного, живое тело — scripts/deploy/deploy_withdraw_counter.sql):
--   · остаток снимается без штрафа; офферы партии в `pending` → `withdrawn`;
--   · matched_heads = сумма живых (не-cancelled) кусков;
--   · статус партии = статус её отстающего живого куска;
--   · событие `remainder_withdrawn` (тот же набор ключей metadata, что у кнопки).
-- Скрипт воспроизводит этот исход СВОИМИ запросами, а не зовёт RPC: кнопка через
-- fn_tsp_rollup_batch_status ставит отметкам этапов момент нажатия (нарушило бы
-- FR-011) и пишет действие от имени фермера. Здесь created_by = null,
-- metadata.repair = 'ARS-754'.
--
-- ИСТОРИЯ СДЕЛКИ НЕ ПЕРЕПИСЫВАЕТСЯ (FR-011) — намеренное отличие от кнопки:
--   · batches.heads не меняется;
--   · куски, их заявки и счётчики заявок/строк не трогаются;
--   · пустые отметки этапов партии (confirmed_at / dispatched_at / delivered_at)
--     берутся из живых кусков: для каждого этапа — самая поздняя отметка среди
--     кусков, дошедших до этого этапа, и только для этапов, до которых дошла сама
--     партия (как у rollup). Моментом ремонта отметки этапов НЕ ставятся (прецедент
--     ARS-733: дату аудита не подделываем). Служебные отметки — batches.updated_at
--     (ставит триггер) и offers.responded_at у гасимых офферов — получают время
--     ремонта: это время записи, а не событие сделки.
--
-- СТОП ДО ПЕРВОЙ ЗАПИСИ (FR-010): если под признак попала хоть одна партия без
-- живых кусков, скрипт печатает её и прерывает ВЕСЬ прогон в любом режиме —
-- транзакция откатывается, не ремонтируется ни одна партия, решение за владельцем.
--
-- ПОРЯДОК (FR-012): построчная распечатка в откатываемой транзакции → «да» владельца
-- → применение. ИДЕМПОТЕНТНОСТЬ: после прогона под признак не попадает ни одна
-- партия — повторный прогон ничего не меняет; строки вне признака не меняются.
-- От миграции 20260924120000 ремонт не зависит (порядок выкладки: ремонт → миграция
-- → мерж, Verification спека).
--
-- ЗАПУСК: python3 scripts/run_sql_rollback.py scripts/deploy/repair_ars754_partial_batches.sql
--         (по умолчанию ROLLBACK — распечатка и откат; --apply применяет)
-- ПОСЛЕ:  select count(*) from batches where status = 'partially_matched';  -- M-009: 0
-- ============================================================================

do $repair$
declare
    v_b        record;
    v_row      record;
    v_dead     text;
    v_total    int := 0;
    v_fixed    int := 0;
    v_offers   int;
    v_level    int;
    v_status   text;
    v_active   int;
    v_left     int;
begin
    -- ── СТОП: партии без живых кусков (FR-010) — до первой записи ────────────
    select string_agg(b.id::text || ' (гол. ' || b.heads || ', продано ' || b.matched_heads
                      || ', орг. ' || b.organization_id || ')', '; ')
      into v_dead
    from public.batches b
    where b.status = 'partially_matched'
      and not exists (select 1 from public.batch_allocations a
                      where a.batch_id = b.id and a.status <> 'cancelled');
    if v_dead is not null then
        raise exception 'ARS-754 РЕМОНТ ОСТАНОВЛЕН: под признак попали партии без живых кусков — %. '
                        'Не отремонтировано ни одной партии; решение за владельцем (FR-010)', v_dead;
    end if;

    -- ── РАСПЕЧАТКА (FR-012, M-010) ──────────────────────────────────────────
    for v_b in
        select b.* from public.batches b
        where b.status = 'partially_matched'
        order by b.created_at
        for update
    loop
        v_total := v_total + 1;
        raise notice '── партия % · орг. % · голов % · продано % · статус % · этапы: confirmed=% dispatched=% delivered=%',
            v_b.id, v_b.organization_id, v_b.heads, v_b.matched_heads, v_b.status,
            v_b.confirmed_at, v_b.dispatched_at, v_b.delivered_at;
        for v_row in
            select a.id, a.heads, a.status, a.pool_id, p.status as pool_status,
                   p.matched_heads as pool_matched, p.target_heads as pool_target,
                   a.confirmed_at, a.dispatched_at, a.delivered_at, a.cancelled_at
            from public.batch_allocations a
            left join public.pools p on p.id = a.pool_id
            where a.batch_id = v_b.id
            order by a.created_at
        loop
            raise notice '     кусок % · % гол. · % · заявка % (% · набрано %/%) · confirmed=% dispatched=% delivered=% cancelled=%',
                v_row.id, v_row.heads, v_row.status, v_row.pool_id, v_row.pool_status,
                v_row.pool_matched, v_row.pool_target,
                v_row.confirmed_at, v_row.dispatched_at, v_row.delivered_at, v_row.cancelled_at;
        end loop;
        for v_row in
            select o.id, o.status, o.mpk_org_id, o.expires_at
            from public.offers o where o.batch_id = v_b.id order by o.created_at
        loop
            raise notice '     оффер % · % · МПК % · истекает %',
                v_row.id, v_row.status, v_row.mpk_org_id, v_row.expires_at;
        end loop;

        -- ── РЕМОНТ ОДНОЙ ПАРТИИ (FR-010 + FR-011) ──────────────────────────
        -- Снять остаток с рынка: pending-офферы гасятся без штрафа, как у кнопки.
        update public.offers set status = 'withdrawn', responded_at = now()
        where batch_id = v_b.id and status = 'pending';
        get diagnostics v_offers = row_count;

        select coalesce(sum(a.heads), 0),
               min(case a.status when 'matched' then 1 when 'confirmed' then 2
                                 when 'dispatched' then 3 when 'delivered' then 4 end)
          into v_active, v_level
        from public.batch_allocations a
        where a.batch_id = v_b.id and a.status <> 'cancelled';
        -- Страховка стопа выше: без живого куска `else` ниже дал бы ложный `delivered`.
        if v_level is null then
            raise exception 'ARS-754 РЕМОНТ ОСТАНОВЛЕН: у партии % нет живых кусков (FR-010)', v_b.id;
        end if;
        v_status := case v_level when 1 then 'matched' when 2 then 'confirmed'
                                 when 3 then 'dispatched' else 'delivered' end;

        update public.batches b
        set matched_heads = v_active,
            status        = v_status,
            confirmed_at  = case when v_level >= 2 then coalesce(b.confirmed_at,
                              (select max(a.confirmed_at) from public.batch_allocations a
                               where a.batch_id = b.id and a.status in ('confirmed', 'dispatched', 'delivered')))
                              else b.confirmed_at end,
            dispatched_at = case when v_level >= 3 then coalesce(b.dispatched_at,
                              (select max(a.dispatched_at) from public.batch_allocations a
                               where a.batch_id = b.id and a.status in ('dispatched', 'delivered')))
                              else b.dispatched_at end,
            delivered_at  = case when v_level >= 4 then coalesce(b.delivered_at,
                              (select max(a.delivered_at) from public.batch_allocations a
                               where a.batch_id = b.id and a.status = 'delivered'))
                              else b.delivered_at end
        where b.id = v_b.id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_b.id, 'remainder_withdrawn',
            jsonb_build_object('include_matched', false, 'reversed_heads', 0,
                               'reversed_chunks', 0, 'active_heads', v_active,
                               'new_status', v_status, 'repair', 'ARS-754',
                               'withdrawn_offers', v_offers),
            null);

        select * into v_row from public.batches where id = v_b.id;
        raise notice '  → статус % · продано % из % · этапы: confirmed=% dispatched=% delivered=% · офферов погашено %',
            v_row.status, v_row.matched_heads, v_row.heads,
            v_row.confirmed_at, v_row.dispatched_at, v_row.delivered_at, v_offers;
        v_fixed := v_fixed + 1;
    end loop;

    select count(*) into v_left from public.batches where status = 'partially_matched';
    raise notice 'ARS-754 РЕМОНТ: под признаком было %, отремонтировано %, осталось в partially_matched % (M-009 ждёт 0)',
        v_total, v_fixed, v_left;
    if v_left <> 0 then
        raise exception 'ARS-754 РЕМОНТ: после прогона в partially_matched осталось % партий', v_left;
    end if;
end;
$repair$;
