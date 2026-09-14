-- ============================================================================
-- ARS-314 / TSP-CANCELPOOL-ALLOC-01 · отмена заявки освобождает ОБА маршрута матча
-- Спек (G2 · 2026-09-14): Docs/AGOS-TSP-CancelPool-Chunks-FIX.md
--
-- ПОЧЕМУ ОТДЕЛЬНАЯ МИГРАЦИЯ, А НЕ РЕПЛЕЙ d02 (FR-012): на d02_tsp.sql стоит guard
-- ARS-314 — полный реплей канона перепишет прод телами шести функций, чья
-- согласованность с продом не проверена. Эта миграция применяет ТОЛЬКО то, что
-- изменил фикс, и ложится поверх канона, чтобы будущая реконсиляция его не снесла.
--
-- Тела ниже — точная копия канона d02_tsp.sql (извлечены скриптом, не переписаны
-- руками, чтобы канон и прод не разъехались молча — L-1).
--
-- Что чинится:
--   1. fn_tsp_release_pool_allocations — НОВЫЙ хелпер: куски отменённой заявки →
--      cancelled, batches.matched_heads пересчитан, терминальные партии не воскресают.
--   2. rpc_cancel_pool        — зовёт хелпер + обнуляет pool_lines.current_heads.
--   3. rpc_admin_cancel_pool  — то же (дефект был идентичен в обеих; урок L-2).
--
-- Четвёртое место того же класса — fn_tsp_pool_release_matches из ARS-695 — живёт в
-- своей миграции 20260914120000 и переприменяется вместе с ней (deploy.py следит за
-- sha файла), поэтому здесь не дублируется.
-- ============================================================================


-- ── 1. Новый хелпер (канон d02_tsp.sql) ──────────────────────────────────────
-- fn_tsp_release_pool_allocations (ARS-314 / TSP-CANCELPOOL-ALLOC-01)
-- Освобождение партий, проданных КУСКОМ, при отмене заявки — второй маршрут матча.
--
-- Зачем: обе функции отмены (rpc_cancel_pool у МПК и rpc_admin_cancel_pool у админа)
-- возвращали только партии, привязанные ЦЕЛИКОМ (batches.pool_line_id), и не знали про
-- batch_allocations вовсе. Кусок оставался 'matched' в отменённой заявке, а
-- batches.matched_heads продолжал считать его проданным: партия либо висела 'matched' и её
-- нельзя было отгрузить (сделки нет), либо формально 'published', но матчеры её не брали —
-- условие matched_heads < heads не выполнялось. Так на проде зависли 580 голов в 3 заявках.
-- Канон это требовал с самого начала: MS6 §4f шаг 8a — «Matched ВСЕХ СТРОК → published».
--
-- Почему хелпер, а не копия в каждой функции: тела обеих отмен совпадают до метаданных
-- события, и починка одной из двух — ровно тот способ вернуть баг, о котором предупреждает
-- урок L-2 в CLAUDE.md. Один дом логики (P4).
-- ------------------------------------------------------------
create or replace function public.fn_tsp_release_pool_allocations(
    p_pool_id uuid, p_reason text default null, p_via text default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_alloc  record;
    v_batch  record;
    v_active int;
    v_freed  int := 0;
begin
    for v_alloc in
        select a.id, a.batch_id, a.pool_line_id, a.heads
        from public.batch_allocations a
        where a.pool_id = p_pool_id and a.status = 'matched'
        for update of a
    loop
        update public.batch_allocations
        set status = 'cancelled', cancelled_at = now()
        where id = v_alloc.id;

        -- FR-005: отмену инициировал покупатель (или админ) — фермер не виноват. Событие
        -- нейтральное, а НЕ штрафное 'cancelled_after_match': то драйвит репутацию фермера
        -- (D-TSP-14), и повесить на него чужую отмену значит оклеветать.
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_alloc.batch_id, 'returned_to_pool_cancelled',
            jsonb_build_object('pool_id', p_pool_id, 'pool_line_id', v_alloc.pool_line_id,
                               'allocation_id', v_alloc.id, 'heads', v_alloc.heads,
                               'reason', coalesce(p_reason, 'pool_cancelled'),
                               'route', 'allocation', 'via', p_via),
            public.fn_current_user_id());

        -- FR-002: активным считается ЛЮБОЙ не-cancelled кусок, включая dispatched/delivered:
        -- те уже уехали к своему покупателю и свободными не являются. Формула
        -- «matched|confirmed» из rpc_self_withdraw_batch старше расширения статусов куска
        -- (20260702190000) и здесь дала бы партии вторую жизнь поверх отгруженной сделки.
        select coalesce(sum(heads), 0) into v_active
        from public.batch_allocations
        where batch_id = v_alloc.batch_id and status <> 'cancelled';

        select * into v_batch from public.batches where id = v_alloc.batch_id for update;

        if v_batch.status in ('cancelled', 'failed', 'expired', 'delivered') then
            -- FR-004: терминальную партию не воскрешаем. Снятую фермером нельзя вернуть на
            -- рынок отменой чужой заявки, доставленную — тем более. Правим только счётчик.
            update public.batches
            set matched_heads = v_active, updated_at = now()
            where id = v_alloc.batch_id;
        elsif v_active = 0 then
            -- FR-003: живых кусков не осталось — партия снова целиком на рынке.
            update public.batches
            set matched_heads = 0, status = 'published',
                pool_line_id = null, deal_price_per_kg = null, updated_at = now()
            where id = v_alloc.batch_id;
            v_freed := v_freed + 1;
        else
            -- M-003/M-004: часть партии продана другой заявке — ту сделку не трогаем.
            update public.batches
            set matched_heads = v_active,
                status = case when v_active < v_batch.heads
                              then 'partially_matched' else v_batch.status end,
                updated_at = now()
            where id = v_alloc.batch_id;
        end if;
    end loop;

    return v_freed;
end; $$;

comment on function public.fn_tsp_release_pool_allocations(uuid, text, text) is
    'ARS-314 / TSP-CANCELPOOL-ALLOC-01 | Отмена кусков заявки (batch_allocations) при её
     отмене — второй маршрут матча, которого обе функции отмены не знали. Куски → cancelled,
     batches.matched_heads пересчитывается из оставшихся НЕ-cancelled кусков (dispatched и
     delivered считаются занятыми). Партия без живых кусков → published; с остатком →
     partially_matched; терминальная (cancelled/failed/expired/delivered) статус СОХРАНЯЕТ.
     Возвращает число партий, полностью вернувшихся на рынок.';
revoke execute on function public.fn_tsp_release_pool_allocations(uuid, text, text)
    from public, anon, authenticated;


-- ── 2. rpc_cancel_pool (канон d02_tsp.sql) ───────────────────────────────────
drop function if exists public.rpc_cancel_pool(p_organization_id uuid, p_pool_id uuid, p_reason text);
create or replace function public.rpc_cancel_pool(
    p_organization_id   uuid,
    p_pool_id           uuid,
    p_reason            text default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool          record;
    v_count         int := 0;
    v_batch_id      uuid;
begin
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner-check via pools.organization_id column.
    select p.* into v_pool
    from public.pools p
    where p.id = p_pool_id
    for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_pool.organization_id != p_organization_id then
        raise exception 'FORBIDDEN: caller does not own pool %', p_pool_id
            using errcode = 'P0001';
    end if;

    if v_pool.status = 'cancelled' then
        return 0;
    end if;
    if v_pool.status != 'filling' then
        raise exception 'INVALID_STATUS: cancel allowed only from filling (current %)',
            v_pool.status using errcode = 'P0001';
    end if;

    -- Withdraw any pending offers for matched batches BEFORE resetting pool_line_id
    -- + emit market.offer.withdrawn (TSP-FLOW-06, reason=pool_cancelled, Dok4 §3.3a).
    with w as (
        update public.offers o
        set status = 'withdrawn', responded_at = now()
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.id = o.batch_id
          and o.status = 'pending'
        returning o.id as offer_id, o.batch_id, o.mpk_org_id
    )
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    )
    select 'market.offer.withdrawn', 'offers', w.offer_id, w.mpk_org_id,
           'system', null,
           jsonb_build_object(
               'offer_id', w.offer_id,
               'batch_id', w.batch_id,
               'mpk_org_id', w.mpk_org_id,
               'reason', 'pool_cancelled'
           ),
           false
    from w;

    -- Return each matched batch -> published
    for v_batch_id in
        select b.id
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
        for update
    loop
        update public.batches
        set status            = 'published',
            pool_line_id      = null,
            deal_price_per_kg = null,
            updated_at        = now()
        where id = v_batch_id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch_id, 'returned_to_pool_cancelled',
            jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason),
            public.fn_current_user_id());

        v_count := v_count + 1;
    end loop;

    -- ARS-314 (FR-001): второй маршрут матча — партии, проданные КУСКОМ. Цикл выше знает
    -- только привязанные целиком; без этой строки куски оставались 'matched' в отменённой
    -- заявке и вешали партию намертво (TSP-CANCELPOOL-ALLOC-01).
    v_count := v_count + public.fn_tsp_release_pool_allocations(p_pool_id, p_reason, null);

    -- Reset pool_line running counters.
    -- FR-002: current_heads обнуляется наравне с объёмом — раньше обнулялся только
    -- current_volume_kg, и у отменённой заявки счётчик голов строки оставался ненулевым.
    update public.pool_lines
    set current_volume_kg = 0,
        current_heads     = 0,
        updated_at        = now()
    where pool_id = p_pool_id;

    -- Pool -> cancelled
    update public.pools
    set status        = 'cancelled',
        matched_heads = 0,
        cancelled_at  = now(),
        updated_at    = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.cancelled', 'pools', p_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object(
            'pool_id', p_pool_id,
            'reason', p_reason,
            'returned_batches', v_count
        ),
        true
    );

    return v_count;
end; $$;

comment on function public.rpc_cancel_pool(uuid, uuid, text) is
    'Microstep4 §4.1 / Microstep6 §4f step 8a | FSM pools: filling -> cancelled.
     Caller: MPK (pool owner). Atomically withdraws pending offers, returns matched
     batches to published, resets pool_line counters, marks pool cancelled.
     Returns: count of batches returned to published. Idempotent (already cancelled = 0).
     ARS-314: освобождает ОБА маршрута матча — партии, привязанные целиком
     (batches.pool_line_id), и проданные куском (batch_allocations, через
     fn_tsp_release_pool_allocations). До этого второй маршрут не обрабатывался вовсе:
     куски висели matched в отменённой заявке и вешали партию фермера намертво.';


-- ── 3. rpc_admin_cancel_pool (канон d02_tsp.sql) ─────────────────────────────
create or replace function public.rpc_admin_cancel_pool(
    p_pool_id   uuid,
    p_reason    text default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool      record;
    v_count     int := 0;
    v_batch_id  uuid;
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = 'P0001';
    end if;

    select p.* into v_pool from public.pools p where p.id = p_pool_id for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0001';
    end if;

    if v_pool.status = 'cancelled' then
        return 0;  -- idempotent
    end if;
    if v_pool.status not in ('draft', 'filling') then
        raise exception
            'INVALID_STATUS: admin cancel allowed only from draft|filling (current %)',
            v_pool.status using errcode = 'P0001';
    end if;

    -- Withdraw pending offers for matched batches BEFORE resetting pool_line_id
    -- + emit market.offer.withdrawn (reason=pool_cancelled), mirrors RPC-M6-13.
    with w as (
        update public.offers o
        set status = 'withdrawn', responded_at = now()
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.id = o.batch_id
          and o.status = 'pending'
        returning o.id as offer_id, o.batch_id, o.mpk_org_id
    )
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    )
    select 'market.offer.withdrawn', 'offers', w.offer_id, w.mpk_org_id,
           'admin', public.fn_current_user_id(),
           jsonb_build_object(
               'offer_id', w.offer_id, 'batch_id', w.batch_id,
               'mpk_org_id', w.mpk_org_id, 'reason', 'pool_cancelled', 'via', 'admin'),
           false
    from w;

    -- Return each matched batch -> published
    for v_batch_id in
        select b.id
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
        for update
    loop
        update public.batches
        set status            = 'published',
            pool_line_id      = null,
            deal_price_per_kg = null,
            updated_at        = now()
        where id = v_batch_id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch_id, 'returned_to_pool_cancelled',
            jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason, 'via', 'admin'),
            public.fn_current_user_id());

        v_count := v_count + 1;
    end loop;

    -- ARS-314 (FR-001): тот же второй маршрут, что и у rpc_cancel_pool. Дефект был
    -- идентичен в обеих функциях отмены — починка одной из двух вернула бы баг (урок L-2).
    v_count := v_count + public.fn_tsp_release_pool_allocations(p_pool_id, p_reason, 'admin');

    -- Reset pool_line running counters (FR-002: + current_heads, см. rpc_cancel_pool).
    update public.pool_lines
    set current_volume_kg = 0,
        current_heads     = 0,
        updated_at        = now()
    where pool_id = p_pool_id;

    -- Pool -> cancelled
    update public.pools
    set status        = 'cancelled',
        matched_heads = 0,
        cancelled_at  = now(),
        updated_at    = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.cancelled', 'pools', p_pool_id, v_pool.organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id, 'reason', p_reason,
            'returned_batches', v_count, 'previous_status', v_pool.status, 'via', 'admin'),
        true
    );

    return v_count;
end;
$$;
comment on function public.rpc_admin_cancel_pool(uuid, text) is
    'ARS-196 | Admin operator cancel of ANY org pool. Gate: fn_is_admin().
     FSM: draft|filling → cancelled (mirrors RPC-M6-13). Withdraws pending offers,
     returns matched batches → published, zeroes pool_line counters. Idempotent
     (already cancelled = 0). Returns count of batches returned. Additive (P7).
     ARS-314: освобождает ОБА маршрута матча — как и rpc_cancel_pool (дефект был
     идентичен в обеих функциях отмены, чинится одним хелпером
     fn_tsp_release_pool_allocations).';
revoke execute on function public.rpc_admin_cancel_pool(uuid, text) from public, anon;
grant  execute on function public.rpc_admin_cancel_pool(uuid, text) to authenticated;
