-- ============================================================================
-- ARS-695 · Выход из недобравшейся заявки — комбинат выбирает, фермер получает ход
-- Слайс-спек: Docs/AGOS-TSP-PoolDecision-Underfill-ARS-695.md (G2 · 2026-09-14)
--
-- ЧТО ЗДЕСЬ: только НОВОЕ — хелперы недобора и три self-serve RPC точки выбора.
-- Правки тел существующих функций живут в ИХ домах, не здесь (P4, один факт — один дом):
--   · rpc_self_close_due_pools      → 20260622120000_tsp_canonical_rebind.sql:1499
--   · rpc_self_advance_pool_status  → 20260622120000_tsp_canonical_rebind.sql:1339
--   · fn_tsp_alloc_chunk (filled_at)→ 20260702190000_tsp_chunk_dispatch.sql:251
--   · rpc_self_accept_offer (filled_at) → 20260726140000_tsp_slice9_defer_revert_selfserve.sql:392
--   · tsp_config.min_pool_heads     → d02_tsp.sql §9.4
-- L-1: ни одна функция этого файла не переопределяется где-либо ещё — проверено
-- grep'ом `create or replace function public.<имя>` по всем .sql репозитория.
--
-- ПОЧЕМУ self-serve, а не подъём канонических rpc_pool_accept_partial/return_batches
-- (FR-013, D-TSP-CANON-01): канон торгового слоя = self-serve adapter, а канонические
-- функции знают только ОДИН маршрут матча (batches.pool_line_id) и оставили бы куски
-- (batch_allocations) в тупике. Им этим же PR добавлен ownership-гейт + revoke (d02).
--
-- ДВА МАРШРУТА МАТЧА (FR-005) — предикат взят у read-model ARS-684 дословно, чтобы
-- решение и монитор делили ОДНО правило (P4):
--   маршрут 1 «кусок»   — batch_allocations по этой заявке, status <> 'cancelled'
--   маршрут 2 «целиком» — batches.pool_line_id ∈ строк заявки И у батча НЕТ НИ ОДНОЙ
--                         строки batch_allocations (любой пул, любой статус, cancelled
--                         включительно). Сужать guard нельзя: fn_tsp_alloc_chunk пишет
--                         batches.pool_line_id на ПЕРВОМ куске и rollup его никогда не
--                         очищает — узкий guard впустил бы дроблёный батч второй раз,
--                         целиком, с полными b.heads (разбор в 20260910120000:126-141).
-- ============================================================================


-- ── 1. fn_tsp_pool_min_heads — порог осмысленности заявки (FR-008, P8) ────────
-- Один дом значения: и кнопка комбината, и подметание читают отсюда (P4).
create or replace function public.fn_tsp_pool_min_heads()
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select coalesce(
        (select min_pool_heads from public.tsp_config where is_active = true limit 1),
        10
    );
$$;
comment on function public.fn_tsp_pool_min_heads() is
    'ARS-695 (FR-008) | Порог голов, ниже которого недобравшаяся заявка НЕ получает точки
     выбора МПК. Данные, не код: tsp_config.min_pool_heads (P8). Фолбэк 10 — на случай
     пустого конфига, чтобы правило порога не исчезло молча вместе со строкой.';
revoke execute on function public.fn_tsp_pool_min_heads() from public, anon, authenticated;


-- ── 2. fn_tsp_emit_batch_confirmed — событие A7 по подтверждённой партии ──────
-- FR-022 + закрывает половину долга TSP-FLOW-05 (вторая половина — путь полного
-- набора, заморожен FR-001, дом ARS-314). Payload — по Dok 4 §3.3 (A7 identity).
create or replace function public.fn_tsp_emit_batch_confirmed(
    p_batch_id uuid, p_pool_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_mpk_org   uuid;
    v_mpk_name  text;
    v_farm_org  uuid;
    v_farm_name text;
begin
    -- mpk_org: у self-serve заявок pools.organization_id бывает NULL — авторитет
    -- заявки живёт в pool_requests (гейт всего адаптера идёт через него).
    select coalesce(p.organization_id, pr.organization_id), o.legal_name
      into v_mpk_org, v_mpk_name
    from public.pools p
    left join public.pool_requests pr on pr.id = p.pool_request_id
    left join public.organizations o
           on o.id = coalesce(p.organization_id, pr.organization_id)
    where p.id = p_pool_id;

    select b.organization_id, o.legal_name
      into v_farm_org, v_farm_name
    from public.batches b
    left join public.organizations o on o.id = b.organization_id
    where b.id = p_batch_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.batch.confirmed', 'batches', p_batch_id, v_mpk_org,
        'admin', public.fn_current_user_id(),
        jsonb_build_object(
            'batch_id',          p_batch_id,
            'pool_id',           p_pool_id,
            'mpk_org_id',        v_mpk_org,
            'mpk_legal_name',    v_mpk_name,
            'farmer_org_id',     v_farm_org,
            'farmer_legal_name', v_farm_name
        ),
        -- Dok 4 §3.3: у market.batch.confirmed аудиторий две — уведомление и Audit.
        -- is_audit=true = строка уедет в audit_log триггером (d01_kernel.sql §PART 1).
        true
    );
end;
$$;
comment on function public.fn_tsp_emit_batch_confirmed(uuid, uuid) is
    'ARS-695 (FR-022) | market.batch.confirmed с identity-payload A7 (Dok 4 §3.3):
     обе стороны названы — событие эмитится ТОЛЬКО после закрытия заявки, когда контакты
     уже раскрыты (D-M6-5/12), поэтому анонимность не нарушается. Закрывает половину
     TSP-FLOW-05; вторая половина (путь полного набора) заморожена FR-001 → ARS-314.
     Слайс пишет событие, но не доставляет его человеку — уведомления дом ARS-685.';
revoke execute on function public.fn_tsp_emit_batch_confirmed(uuid, uuid) from public, anon, authenticated;


-- ── 3. fn_tsp_pool_confirm_matches — подтвердить ОБА маршрута (FR-003/FR-005) ─
create or replace function public.fn_tsp_pool_confirm_matches(p_pool_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_count int := 0;
    v_bid   uuid;
begin
    -- Маршрут 1: куски этой заявки matched → confirmed, затем статус батча
    -- пересчитывается из кусков. rollup сам оставит партию с остатком на рынке
    -- в partially_matched (M-008) — она продолжает продаваться.
    update public.batch_allocations
    set status = 'confirmed', confirmed_at = now()
    where pool_id = p_pool_id and status = 'matched';
    get diagnostics v_count = row_count;

    for v_bid in
        select distinct a.batch_id
        from public.batch_allocations a
        where a.pool_id = p_pool_id and a.status <> 'cancelled'
    loop
        perform public.fn_tsp_rollup_batch_status(v_bid);
        perform public.fn_tsp_emit_batch_confirmed(v_bid, p_pool_id);
    end loop;

    -- Маршрут 2: партии, привязанные целиком и НИКОГДА не дробившиеся.
    for v_bid in
        select b.id
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
          and not exists (
              select 1 from public.batch_allocations a where a.batch_id = b.id
          )
        for update of b
    loop
        update public.batches
        set status       = 'confirmed',
            confirmed_at = coalesce(confirmed_at, now()),
            updated_at   = now()
        where id = v_bid;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_bid, 'confirmed',
            jsonb_build_object('pool_id', p_pool_id, 'partial_accept', true,
                               'route', 'batch'),
            public.fn_current_user_id());

        perform public.fn_tsp_emit_batch_confirmed(v_bid, p_pool_id);
        v_count := v_count + 1;
    end loop;

    return v_count;
end;
$$;
comment on function public.fn_tsp_pool_confirm_matches(uuid) is
    'ARS-695 (FR-003/FR-005) | Подтверждение матчей заявки по ОБОИМ маршрутам: куски
     (batch_allocations → confirmed + rollup статуса батча) и партии целиком
     (batches.pool_line_id у батчей без единой аллокации). Возвращает число
     подтверждённых единиц (кусков + целых партий). Событие A7 по каждой партии.';
revoke execute on function public.fn_tsp_pool_confirm_matches(uuid) from public, anon, authenticated;


-- ── 4. fn_tsp_pool_release_matches — вернуть ОБА маршрута (FR-004/FR-005) ─────
create or replace function public.fn_tsp_pool_release_matches(p_pool_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_count    int := 0;
    v_alloc    record;
    v_batch    record;
    v_vol      int;
    v_active   int;
    v_org      uuid;
    v_returned uuid[] := array[]::uuid[];   -- партии, реально вернувшиеся на рынок
begin
    -- Маршрут 1: куски этой заявки → cancelled, счётчики заявки и строки
    -- уменьшаются на возвращённое (инварианты дословно как в rpc_self_withdraw_batch,
    -- 20260702180000:216-237 — иначе FR-010 показывал бы оператору неправду).
    for v_alloc in
        select a.*, b.avg_weight_kg
        from public.batch_allocations a
        join public.batches b on b.id = a.batch_id
        where a.pool_id = p_pool_id and a.status = 'matched'
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
        where id = p_pool_id;

        update public.batch_allocations
        set status = 'cancelled', cancelled_at = now()
        where id = v_alloc.id;

        -- Возврат по решению заявки — НЕ вина фермера: событие нейтральное, без
        -- penalty-флага (штрафное cancelled_after_match драйвит репутацию D-TSP-14
        -- и здесь было бы клеветой на фермера).
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_alloc.batch_id, 'returned_to_published',
            jsonb_build_object('pool_id', p_pool_id, 'pool_line_id', v_alloc.pool_line_id,
                               'allocation_id', v_alloc.id, 'heads', v_alloc.heads,
                               'reason', 'pool_underfilled', 'route', 'allocation'),
            public.fn_current_user_id());

        -- Статус партии пересчитывается из ОСТАВШИХСЯ активных кусков: партия могла
        -- быть распродана кусками нескольким заявкам, и возврат по этой не отменяет
        -- сделку с другой. Активный = ЛЮБОЙ не-cancelled кусок, включая dispatched и
        -- delivered: куски давно закрытой соседней заявки уже уехали к её комбинату,
        -- и считать их свободными значило бы вернуть на рынок отгруженный скот.
        -- (batch_allocations расширены до 5 статусов в 20260702190000:40-42; формула
        -- «matched|confirmed» из rpc_self_withdraw_batch старше этого расширения и
        -- там безопасна лишь потому, что снятие партии запрещено после dispatch.)
        select coalesce(sum(heads), 0) into v_active
        from public.batch_allocations
        where batch_id = v_alloc.batch_id and status <> 'cancelled';

        select * into v_batch from public.batches where id = v_alloc.batch_id for update;

        if v_batch.status in ('cancelled', 'failed', 'expired', 'delivered') then
            -- ARS-314 (FR-004 фикса отмены заявки): терминальную партию не воскрешаем.
            -- Первая редакция этой ветки различала только «есть живые куски / нет» и
            -- поэтому возвращала на рынок снятую фермером партию, а уже доставленную
            -- откатывала в partially_matched — по сути выдавала вторую жизнь закрытой
            -- сделке. Найдено на прогоне ремонта осиротевших кусков 14.09; здесь тот же
            -- дефект того же класса, вылеченный тем же правилом.
            update public.batches
            set matched_heads = v_active, updated_at = now()
            where id = v_alloc.batch_id;
        elsif v_active = 0 then
            -- Кусков не осталось — партия снова целиком на рынке (FR-004).
            update public.batches
            set matched_heads     = 0,
                status            = 'published',
                pool_line_id      = null,
                deal_price_per_kg = null,
                updated_at        = now()
            where id = v_alloc.batch_id;
            v_returned := v_returned || v_alloc.batch_id;
        else
            -- Часть партии продана другой заявке — цену и привязку не трогаем.
            update public.batches
            set matched_heads = v_active,
                status        = case when v_active < v_batch.heads
                                     then 'partially_matched' else v_batch.status end,
                updated_at    = now()
            where id = v_alloc.batch_id;
        end if;

        v_count := v_count + 1;
    end loop;

    -- Маршрут 2: партии, привязанные целиком и никогда не дробившиеся.
    for v_batch in
        select b.*
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
          and not exists (
              select 1 from public.batch_allocations a where a.batch_id = b.id
          )
        for update of b
    loop
        v_vol := coalesce(round(v_batch.heads * v_batch.avg_weight_kg)::int, 0);

        update public.pool_lines
        set current_heads     = greatest(current_heads - v_batch.heads, 0),
            current_volume_kg = greatest(current_volume_kg - v_vol, 0),
            updated_at        = now()
        where id = v_batch.pool_line_id;

        update public.pools
        set matched_heads = greatest(matched_heads - v_batch.heads, 0), updated_at = now()
        where id = p_pool_id;

        update public.batches
        set status            = 'published',
            pool_line_id      = null,
            deal_price_per_kg = null,
            matched_heads     = 0,
            updated_at        = now()
        where id = v_batch.id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch.id, 'returned_to_published',
            jsonb_build_object('pool_id', p_pool_id, 'pool_line_id', v_batch.pool_line_id,
                               'heads', v_batch.heads, 'reason', 'pool_underfilled',
                               'route', 'batch'),
            public.fn_current_user_id());

        v_returned := v_returned || v_batch.id;
        v_count := v_count + 1;
    end loop;

    -- Pending-офферы ТОЛЬКО по возвращённым партиям и ТОЛЬКО адресованные комбинату
    -- ЭТОЙ заявки (FR-004). У offers нет pool_id — адресат оффера это mpk_org_id
    -- (d02_tsp.sql:1453-1472), поэтому «адресован этой заявке» = адресован её
    -- владельцу. Оффер той же партии другому комбинату — чужая сделка, закрытие
    -- этой заявки её не касается и он остаётся pending.
    if array_length(v_returned, 1) is not null then
        select coalesce(p.organization_id, pr.organization_id) into v_org
        from public.pools p
        left join public.pool_requests pr on pr.id = p.pool_request_id
        where p.id = p_pool_id;

        -- Событие обязательно: канонический rpc_pool_return_batches эмитил
        -- market.offer.withdrawn с reason='pool_returned' (d02_tsp.sql:4235-4248, долг
        -- TSP-FLOW-06, Dok 4 §3.3a), и Dok 4 называет его продюсером. Замена, которая
        -- гасит офферы молча, оставила бы МПК без Realtime-уведомления о смерти его
        -- оффера, а строку Dok 4 — ложной.
        with w as (
            update public.offers o
            set status = 'withdrawn', responded_at = now()
            where o.status = 'pending'
              and o.batch_id = any (v_returned)
              and o.mpk_org_id = v_org
            returning o.id as offer_id, o.batch_id, o.mpk_org_id
        )
        insert into public.platform_events (
            event_type, entity_type, entity_id, organization_id,
            actor_type, actor_id, payload, is_audit
        )
        select 'market.offer.withdrawn', 'offers', w.offer_id, w.mpk_org_id,
               'system', public.fn_current_user_id(),
               jsonb_build_object('offer_id', w.offer_id, 'batch_id', w.batch_id,
                                  'mpk_org_id', w.mpk_org_id,
                                  'reason', 'pool_returned'),
               false
        from w;
    end if;

    return v_count;
end;
$$;
comment on function public.fn_tsp_pool_release_matches(uuid) is
    'ARS-695 (FR-004/FR-005) | Возврат матчей заявки по ОБОИМ маршрутам: куски →
     cancelled с реверсом счётчиков (pools.matched_heads, pool_lines.current_heads/
     current_volume_kg), партии целиком → published с обнулённой ценой. Партия,
     проданная кусками нескольким заявкам, теряет только куски ЭТОЙ. Pending-офферы
     гасятся только адресованные этой заявке. Возврат не штрафует фермера
     (событие returned_to_published, не cancelled_after_match).';
revoke execute on function public.fn_tsp_pool_release_matches(uuid) from public, anon, authenticated;


-- ── 5. fn_tsp_pool_assert_settled — страж нераспознанного маршрута (M-007) ────
create or replace function public.fn_tsp_pool_assert_settled(p_pool_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_stuck int;
begin
    -- Ловим ровно «наш маршрут не отработал», а НЕ «партия законно ещё matched».
    -- Партия, проданная кусками в ДВЕ заявки, после подтверждения этой остаётся
    -- 'matched' совершенно законно: fn_tsp_rollup_batch_status берёт min по ВСЕМ
    -- активным кускам батча без фильтра по пулу (20260702190000:69-83), и живой
    -- 'matched'-кусок соседней открытой заявки удерживает батч. Первая редакция стража
    -- считала такую партию застрявшей (условие было `status <> 'cancelled'`, под него
    -- попадали и куски, только что переведённые в 'confirmed' этой же транзакцией) —
    -- и accept_partial по такой заявке падал UNSETTLED_MATCHES навсегда, то есть
    -- заявку нельзя было закрыть принятием вовсе. Поэтому маршрут 1 проверяется по
    -- НЕобработанному куску ('matched' в ЭТОЙ заявке), а маршрут 2 — тем же предикатом
    -- «нет ни одной аллокации», которым он и обрабатывается.
    select count(*) into v_stuck
    from public.batches b
    where b.status = 'matched'
      and (
          exists (select 1 from public.batch_allocations a
                   where a.batch_id = b.id and a.pool_id = p_pool_id
                     and a.status = 'matched')
          or (
              b.pool_line_id in (select id from public.pool_lines where pool_id = p_pool_id)
              and not exists (
                  select 1 from public.batch_allocations a where a.batch_id = b.id
              )
          )
      );

    if v_stuck > 0 then
        raise exception
            'UNSETTLED_MATCHES: % партий заявки остались matched — маршрут не распознан',
            v_stuck using errcode = 'P0001';
    end if;
end;
$$;
comment on function public.fn_tsp_pool_assert_settled(uuid) is
    'ARS-695 (M-007) | После применения решения ни одна партия заявки не смеет остаться
     matched. Осталась — значит есть третий, неизвестный способ привязки, и молча
     закрывать заявку нельзя: исключение откатывает транзакцию целиком, статус заявки
     не меняется, оператор видит, что решение не применено. Партия с остатком на рынке
     (partially_matched, M-008) под стража не попадает — она и не должна быть закрыта.';
revoke execute on function public.fn_tsp_pool_assert_settled(uuid) from public, anon, authenticated;


-- ── 6. fn_tsp_pool_settle_underfill — ОДНО правило порога (FR-002/006/021) ────
-- Зовут и кнопка комбината (rpc_self_pool_close_now), и подметание
-- (rpc_self_close_due_pools) — «одно правило, один дом» (P4). Вызывающий обязан
-- держать блокировку строки заявки.
create or replace function public.fn_tsp_pool_settle_underfill(p_pool_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool    public.pools%rowtype;
    v_min     int := public.fn_tsp_pool_min_heads();
    v_outcome text;
    v_org     uuid;
begin
    select * into v_pool from public.pools where id = p_pool_id;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0003';
    end if;

    select coalesce(p.organization_id, pr.organization_id) into v_org
    from public.pools p
    left join public.pool_requests pr on pr.id = p.pool_request_id
    where p.id = p_pool_id;

    if v_pool.matched_heads >= v_pool.target_heads then
        -- Край: заявка набралась, но закрыть её некому (аллокатор закрывает сам,
        -- 20260702190000:357). Семантика та же, что у живого пути (FR-001).
        perform public.fn_tsp_pool_confirm_matches(p_pool_id);
        update public.pools
        set status                  = 'closed_filled',
            filled_at               = coalesce(filled_at, now()),
            completed_at            = coalesce(completed_at, now()),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()),
            updated_at              = now()
        where id = p_pool_id;
        v_outcome := 'closed_filled';

    elsif v_pool.matched_heads = 0 then
        -- MS4 PT-04: окно истекло, не набрано ничего — решать нечего.
        update public.pools
        set status       = 'expired_empty',
            completed_at = coalesce(completed_at, now()),
            updated_at   = now()
        where id = p_pool_id;
        -- matched_heads — денормализация. Если счётчик разошёлся с реальностью и партии
        -- всё-таки привязаны, «пустая» заявка утащила бы их в терминал молча. Страж
        -- делает такое расхождение громким вместо тихого.
        perform public.fn_tsp_pool_assert_settled(p_pool_id);
        v_outcome := 'expired_empty';

    elsif v_pool.matched_heads >= v_min then
        -- FR-002: набрано осмысленно, но меньше цели → ход за комбинатом.
        update public.pools
        set status               = 'awaiting_mpk_decision',
            awaiting_decision_at = coalesce(awaiting_decision_at, now()),
            updated_at           = now()
        where id = p_pool_id;
        v_outcome := 'awaiting_mpk_decision';

    else
        -- FR-006: ниже порога выбора нет — партии возвращаются автоматически.
        perform public.fn_tsp_pool_release_matches(p_pool_id);
        update public.pools
        set status     = 'closed_unfilled',
            closed_at  = coalesce(closed_at, now()),
            updated_at = now()
        where id = p_pool_id;
        perform public.fn_tsp_pool_assert_settled(p_pool_id);

        insert into public.platform_events (
            event_type, entity_type, entity_id, organization_id,
            actor_type, actor_id, payload, is_audit
        ) values (
            'market.pool.closed_unfilled', 'pools', p_pool_id, v_org,
            'system', public.fn_current_user_id(),
            jsonb_build_object('pool_id', p_pool_id, 'reason', 'below_min_heads',
                               'matched_heads', v_pool.matched_heads,
                               'min_pool_heads', v_min),
            -- is_audit=true — как у канонической rpc_pool_return_batches (d02_tsp.sql:4293).
            -- Закрытие заявки решает судьбу чужих партий: событие обязано уехать в
            -- audit_log, иначе закрытия исчезают из аудит-трейла целиком.
            true
        );
        v_outcome := 'closed_unfilled';
    end if;

    return v_outcome;
end;
$$;
comment on function public.fn_tsp_pool_settle_underfill(uuid) is
    'ARS-695 (FR-002/FR-006/FR-021) | ОДНО правило порога для кнопки комбината и для
     подметания (P4). Исход: >= target → closed_filled · 0 голов → expired_empty ·
     >= min_pool_heads → awaiting_mpk_decision (точка выбора) · иначе → closed_unfilled
     с автоматическим возвратом партий. Порог — отступление от MS4 §2.5 (там в точку
     выбора уходит любой недобор): решение владельца 11.09, канон MS4/MS6 правится
     этим же PR. Вызывающий обязан держать блокировку строки заявки (M-011).';
revoke execute on function public.fn_tsp_pool_settle_underfill(uuid) from public, anon, authenticated;


-- ============================================================================
-- SELF-SERVE RPC — то, что зовёт кабинет комбината
-- ============================================================================

-- ── 7. rpc_self_pool_close_now — «Закрыть заявку» (FR-002, M-003/M-010/M-011) ─
create or replace function public.rpc_self_pool_close_now(p_pool_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool    public.pools%rowtype;
    v_req     public.pool_requests%rowtype;
    v_org     uuid;
    v_outcome text;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    -- M-011: блокировка строки заявки, не advisory-лок (запрет CLAUDE.md). В READ
    -- COMMITTED FOR UPDATE перечитывает строку после снятия чужой блокировки —
    -- второй оператор увидит уже НОВЫЙ статус и получит INVALID_STATUS.
    select * into v_pool from public.pools where id = p_pool_id for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0003';
    end if;

    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    v_org := coalesce(v_pool.organization_id, v_req.organization_id);
    -- NULL-ловушка: pools.pool_request_id nullable (d02_tsp.sql:1253, «M4: PoolRequest
    -- absorbed»), organization_id тоже бывает пустым. При v_org IS NULL выражение
    -- `NULL = any(...)` даёт NULL, `not NULL` — тоже NULL, и `if` НЕ срабатывает: гейт
    -- молча пропускает. Поэтому пустой владелец проверяется отдельно и явно.
    if v_org is null or not (v_org = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    if v_pool.status <> 'filling' then
        raise exception 'INVALID_STATUS: pool must be filling (current %)', v_pool.status
            using errcode = 'P0002';
    end if;

    v_outcome := public.fn_tsp_pool_settle_underfill(p_pool_id);

    return jsonb_build_object(
        'poolId',       p_pool_id,
        'outcome',      v_outcome,
        'matchedHeads', v_pool.matched_heads,
        'targetHeads',  v_pool.target_heads,
        'minPoolHeads', public.fn_tsp_pool_min_heads()
    );
end;
$$;
comment on function public.rpc_self_pool_close_now(uuid) is
    'ARS-695 (FR-002) | Кнопка «Закрыть заявку» у комбината. Применяет ТЕ ЖЕ правила
     порога, что подметание (fn_tsp_pool_settle_underfill) — одно правило, один дом.
     Заявка молча не меняет статус: недобор ведёт в точку выбора, а не в «набрана».
     Гейт fn_my_org_ids() по владельцу заявки, без клиентского org-параметра.';
revoke execute on function public.rpc_self_pool_close_now(uuid) from public, anon;
grant  execute on function public.rpc_self_pool_close_now(uuid) to authenticated;


-- ── 8. rpc_self_pool_accept_partial — «Принять частично» (FR-003, M-001) ──────
create or replace function public.rpc_self_pool_accept_partial(p_pool_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool  public.pools%rowtype;
    v_req   public.pool_requests%rowtype;
    v_org   uuid;
    v_count int;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_pool from public.pools where id = p_pool_id for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0003';
    end if;

    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    v_org := coalesce(v_pool.organization_id, v_req.organization_id);
    -- NULL-ловушка: при v_org IS NULL `not (NULL = any(...))` даёт NULL и `if` не
    -- срабатывает — гейт молча пропускает. См. разбор в rpc_self_pool_close_now выше.
    if v_org is null or not (v_org = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    if v_pool.status <> 'awaiting_mpk_decision' then
        raise exception 'INVALID_STATUS: pool must be awaiting_mpk_decision (current %)',
            v_pool.status using errcode = 'P0002';
    end if;

    v_count := public.fn_tsp_pool_confirm_matches(p_pool_id);

    -- FR-003: цель приводится к набранному, иначе заявка остаётся вечно недобранной
    -- в своих же числах и на экране FR-010 (канон MS4 §2.5 B, QA TSPM-CLOSE-02).
    -- Контакты раскрываются тем же фактом закрытия, что и при полном наборе (D-M6-5/12).
    update public.pools
    set status                  = 'closed_partial',
        target_heads            = greatest(matched_heads, 1),
        closed_at               = coalesce(closed_at, now()),
        mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()),
        updated_at              = now()
    where id = p_pool_id;

    perform public.fn_tsp_pool_assert_settled(p_pool_id);

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.closed_partial', 'pools', p_pool_id, v_org,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id, 'confirmed_units', v_count,
                           'matched_heads', v_pool.matched_heads,
                           'original_target_heads', v_pool.target_heads),
        -- is_audit=true — как у канонической rpc_pool_accept_partial (d02_tsp.sql:4384).
        true
    );

    return jsonb_build_object(
        'poolId',         p_pool_id,
        'outcome',        'closed_partial',
        'confirmedUnits', v_count,
        'matchedHeads',   v_pool.matched_heads
    );
end;
$$;
comment on function public.rpc_self_pool_accept_partial(uuid) is
    'ARS-695 (FR-003) | «Принять частично»: awaiting_mpk_decision → closed_partial, матчи
     ОБОИХ маршрутов → confirmed, контакты раскрыты, target_heads приведён к набранному.
     У фермера после этого появляется кнопка отгрузки (FR-011). Гейт fn_my_org_ids().
     Рабочая замена канонической rpc_pool_accept_partial (FR-013): та знает лишь маршрут
     batches.pool_line_id и оставила бы куски в тупике.';
revoke execute on function public.rpc_self_pool_accept_partial(uuid) from public, anon;
grant  execute on function public.rpc_self_pool_accept_partial(uuid) to authenticated;


-- ── 9. rpc_self_pool_return_batches — «Вернуть партии» (FR-004, M-002) ────────
create or replace function public.rpc_self_pool_return_batches(p_pool_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool  public.pools%rowtype;
    v_req   public.pool_requests%rowtype;
    v_org   uuid;
    v_count int;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_pool from public.pools where id = p_pool_id for update;
    if not found then
        raise exception 'POOL_NOT_FOUND' using errcode = 'P0003';
    end if;

    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    v_org := coalesce(v_pool.organization_id, v_req.organization_id);
    -- NULL-ловушка: при v_org IS NULL `not (NULL = any(...))` даёт NULL и `if` не
    -- срабатывает — гейт молча пропускает. См. разбор в rpc_self_pool_close_now выше.
    if v_org is null or not (v_org = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    if v_pool.status <> 'awaiting_mpk_decision' then
        raise exception 'INVALID_STATUS: pool must be awaiting_mpk_decision (current %)',
            v_pool.status using errcode = 'P0002';
    end if;

    v_count := public.fn_tsp_pool_release_matches(p_pool_id);

    update public.pools
    set status     = 'closed_unfilled',
        closed_at  = coalesce(closed_at, now()),
        updated_at = now()
    where id = p_pool_id;

    perform public.fn_tsp_pool_assert_settled(p_pool_id);

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.closed_unfilled', 'pools', p_pool_id, v_org,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id, 'returned_units', v_count,
                           'reason', 'mpk_returned'),
        -- is_audit=true — как у канонической rpc_pool_return_batches (d02_tsp.sql:4293).
        true
    );

    return jsonb_build_object(
        'poolId',       p_pool_id,
        'outcome',      'closed_unfilled',
        'returnedUnits', v_count
    );
end;
$$;
comment on function public.rpc_self_pool_return_batches(uuid) is
    'ARS-695 (FR-004) | «Вернуть партии»: awaiting_mpk_decision → closed_unfilled, матчи
     ОБОИХ маршрутов отменены, партии снова published с обнулённой ценой, счётчики заявки
     уменьшены на возвращённое, pending-офферы этой заявки withdrawn. Гейт fn_my_org_ids().
     Рабочая замена канонической rpc_pool_return_batches (FR-013).';
revoke execute on function public.rpc_self_pool_return_batches(uuid) from public, anon;
grant  execute on function public.rpc_self_pool_return_batches(uuid) to authenticated;


-- ── 10. Реестр имён (D-NEW-A) ────────────────────────────────────────────────
-- Канон имени RPC = строка rpc_name_registry. Функция вне реестра — функция, чьё имя
-- нигде не закреплено, и Dok 3 с кодом расходятся молча.
insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
    ('rpc_self_pool_close_now',      'rpc_self_pool_close_now',
     '20260914120000_ars_695_pool_underfill_decision.sql (ARS-695)',
     'ARS-695 FR-002: кнопка «Закрыть заявку» у МПК. Исход по порогу min_pool_heads.'),
    ('rpc_self_pool_accept_partial', 'rpc_self_pool_accept_partial',
     '20260914120000_ars_695_pool_underfill_decision.sql (ARS-695)',
     'ARS-695 FR-003: awaiting_mpk_decision → closed_partial, оба маршрута → confirmed.'),
    ('rpc_self_pool_return_batches', 'rpc_self_pool_return_batches',
     '20260914120000_ars_695_pool_underfill_decision.sql (ARS-695)',
     'ARS-695 FR-004: awaiting_mpk_decision → closed_unfilled, партии обратно на рынок.')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;
