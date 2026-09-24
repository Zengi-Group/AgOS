-- ARS-754 · Партия продаётся только целиком: ручная привязка не режет.
--
-- Спек (G2 2026-09-24): Docs/AGOS-TSP-WholeBatchOnly-ARS-754.md.
-- Решение владельца 26.07, подтверждённое 24.09: дробление выключено
-- (TSP-SLICE9-ROLLBACK-01 в силе). Запись 14.09 «дробление принимается как включённое»
-- ошибочна — см. DECISIONS_LOG 2026-09-24 (ARS-754).
--
-- Правятся ТЕЛА двух функций; сигнатуры, форма ответа и права — прежние (FR-016, P7).
-- d02_tsp.sql не трогается (FR-019): функции живут в supabase/migrations/, эта миграция
-- ложится поверх 20260918120000 (живое тело аллокатора) и 20260702160000 (живое тело
-- ручной привязки). Выкладка точечная (guard TSP-SLICE9-ROLLBACK-01).
--
--   1. fn_tsp_alloc_chunk — единственное место, где решается «вмещает ли строка и заявка
--      партию целиком» (FR-006). Не вмещает → 0 до первой записи. partially_matched
--      больше не пишет (FR-007); правило min_split снято — без частичного взятия ему
--      нечего проверять.
--   2. rpc_self_match_batch_to_pool — порядок проверок FR-021, только партия, из которой
--      ничего не продано (FR-004), просьба разрезать → отказ (FR-003), перебор
--      кандидатов от высшей цены (FR-020), новый отказ BATCH_DOES_NOT_FIT (FR-002).
--
-- Не трогаются (FR-007, FR-014): fn_tsp_release_pool_allocations,
-- fn_tsp_pool_release_matches, rpc_self_activate_pool_request, rpc_self_auto_match_batch,
-- rpc_self_accept_offer.


-- ── 1. fn_tsp_alloc_chunk — аллокатор: партия целиком или ничего ───────────────
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
    v_remaining int;
    v_line_free int;
    v_pool_free int;
    v_kg_free   int;
    v_free      int;
    v_take      int;
    v_price     int;
    v_vol       int;
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
    -- ARS-754 (FR-001, FR-006): партия продаётся только целиком. Строка, заявка (цель
    -- минус набранное) или вес в головах не вмещают весь остаток → 0, ничего не записано.
    -- Раньше здесь брался least(остаток, свободно) и партия резалась (fecf6595, 14.09).
    if v_free < v_remaining then return 0; end if;
    v_take := v_remaining;

    v_price := coalesce(p_price, v_pl.mpk_price_per_kg);
    if v_batch.farmer_price_per_kg is not null and v_price < v_batch.farmer_price_per_kg then
        raise exception 'BID_BELOW_ASK: цена куска % < ask фермера %', v_price, v_batch.farmer_price_per_kg
            using errcode = 'P0007';
    end if;
    v_vol  := coalesce(round(v_take * v_batch.avg_weight_kg)::int, 0);

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

    -- ARS-754 (FR-007): статус всегда `matched` — взят весь остаток. `pool_line_id` и
    -- `deal_price_per_kg` пишутся как раньше: по ним BuyerCard показывает покупателя и цену
    -- (FR-009).
    update public.batches
    set matched_heads     = matched_heads + v_take,
        status            = 'matched',
        pool_line_id      = case when v_batch.matched_heads = 0 then v_pl.id else pool_line_id end,
        deal_price_per_kg = case when v_batch.matched_heads = 0 then v_price else deal_price_per_kg end,
        matched_at        = coalesce(matched_at, now()),
        updated_at        = now()
    where id = p_batch_id;

    update public.offers set status = 'withdrawn', responded_at = now()
    where batch_id = p_batch_id and status = 'pending';

    -- Ключ `partial` оставлен в форме события (читатели журнала не меняются); после
    -- ARS-754 он всегда false.
    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'matched',
        jsonb_build_object('pool_id', v_pool.id, 'pool_line_id', v_pl.id,
                           'via', p_via, 'chunk_heads', v_take, 'deal_price_per_kg', v_price,
                           'partial', false),
        p_created_by);

    -- Пул набрался по головам → закрыть + раскрыть контакт + подтвердить его куски + rollup.
    if (v_pool.matched_heads + v_take) >= v_pool.target_heads then
        -- ARS-695 (FR-012): + filled_at. Статусная логика НЕ меняется (FR-001) — дописана
        -- одна отметка времени. Без неё у колонки не осталось бы писателя вовсе: единственный
        -- стоял в снятой ветке 30 % (rpc_self_close_due_pools), а этот живой путь пишет
        -- completed_at. Расхождение «completed_at на closed_filled» преэкзистентное и здесь
        -- не чинится — это менять статусную логику замороженного пути (FR-020, дом ARS-314).
        update public.pools
        set status = 'closed_filled', completed_at = now(),
            filled_at = coalesce(filled_at, now()),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
        where id = v_pool.id and status = 'filling';
        if found then
            -- ARS-731 (FR-001): подтверждение ОБЕИХ форм записи (куски + партии, привязанные
            -- ссылкой авто-матчем); rollup статуса батча живёт внутри.
            perform public.fn_tsp_pool_confirm_matches(v_pool.id);
        end if;
    end if;

    return v_take;
end;
$$;
comment on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) is
    'ARS-754 | Аллокатор: записывает партию ЦЕЛИКОМ (весь остаток) в строку пула или не
     записывает ничего. Вмещает ли — решается только здесь (FR-006): свободно строки /
     заявки (цель − набрано) / вес в головах [, кап p_max_heads] ≥ остатка. Не вмещает →
     0 до первой записи. Статус партии → matched (partially_matched не пишет, FR-007).
     Закрытие пула: ARS-731 — fn_tsp_pool_confirm_matches (обе формы записи).
     Возвращает взятые головы (0 = ничего).';
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from anon;
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from authenticated;


-- ── 2. rpc_self_match_batch_to_pool — ручная привязка: целиком или отказ ───────
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
    v_found  boolean := false;
    v_took   int;
    v_uid    uuid := public.fn_current_user_id();
begin
    -- ① заявка. Блокировка строки pools выстраивает привязки в одну заявку в очередь
    -- (M-008): вторая видит уже набранное первой.
    select * into v_pool from public.pools where id = p_pool_id for update;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_pool.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;
    if v_pool.status <> 'filling' then raise exception 'POOL_NOT_FILLING' using errcode = 'P0003'; end if;

    -- ② партия. ARS-754 (FR-004): partially_matched на входе больше не принимается;
    -- принимается только партия, из которой ничего не продано.
    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0004'; end if;
    if v_batch.status not in ('published', 'offering') then
        raise exception 'BATCH_NOT_AVAILABLE' using errcode = 'P0005';
    end if;
    if v_batch.matched_heads >= v_batch.heads then
        raise exception 'BATCH_FULLY_MATCHED' using errcode = 'P0005';
    end if;
    if v_batch.matched_heads > 0 then
        raise exception 'BATCH_NOT_AVAILABLE: из партии уже продано % из % гол.',
            v_batch.matched_heads, v_batch.heads
            using errcode = 'P0005';
    end if;

    -- ③ p_matched_heads (FR-003): параметр остаётся в сигнатуре (P7). null или ≥ голов —
    -- вся партия; 1…голов−1 — просьба разрезать, отказ.
    if p_matched_heads is not null and p_matched_heads <= 0 then
        raise exception 'NO_REMAINING_HEADS' using errcode = 'P0008';
    end if;
    if p_matched_heads is not null and p_matched_heads < v_batch.heads then
        raise exception 'BATCH_DOES_NOT_FIT: партия продаётся только целиком (запрошено % из % гол.)',
            p_matched_heads, v_batch.heads
            using errcode = 'P0007';
    end if;

    v_grade := public.fn_tsp_batch_grade(p_batch_id);

    -- ④ кандидаты — сегодняшний фильтр, без изменений (FR-006): строка под сорт+породу,
    -- в ней есть хоть одно место по головам и хоть 1 кг по весу.
    -- ⑤ ARS-754 (FR-020): перебор от высшей цены к низшей; партия ложится в первую строку,
    -- которая вмещает её целиком. Вмещает ли — отвечает аллокатор (FR-006): 0 = нет, и он
    -- ничего не записал. ⑥ Цену (BID_BELOW_ASK) проверяет аллокатор в первой вместившей
    -- строке: дальше по списку цена строки не выше.
    for v_line in
        select pl.id as pl_id
        from public.pool_lines pl
        where pl.pool_id = p_pool_id
          and pl.is_active = true
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_heads is null or pl.current_heads < pl.max_heads)
          and (pl.max_volume_kg is null or pl.current_volume_kg < pl.max_volume_kg)
        order by pl.mpk_price_per_kg desc
        for update
    loop
        v_found := true;
        v_took := public.fn_tsp_alloc_chunk(p_batch_id, v_line.pl_id, 'manual_match', v_uid,
                                            v_batch.heads, p_price_per_kg);
        if v_took > 0 then
            return v_line.pl_id;
        end if;
    end loop;

    if not v_found then
        raise exception 'NO_MATCHING_LINE: нет активной строки под сорт/породу % с местом', v_grade
            using errcode = 'P0006';
    end if;
    -- FR-002: кандидаты есть, но ни строка, ни заявка не вмещают партию целиком.
    raise exception 'BATCH_DOES_NOT_FIT: ни одна строка заявки не вмещает партию целиком (% гол.)',
        v_batch.heads
        using errcode = 'P0007';
end;
$$;
comment on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) is
    'ARS-754 | Ручной матч МПК: партия ЦЕЛИКОМ или отказ. Только партия published/offering,
     из которой ничего не продано (FR-004). p_matched_heads: null/≥голов — вся партия,
     1…голов−1 — BATCH_DOES_NOT_FIT (FR-003). Кандидаты — строки под сорт+породу с местом,
     от высшей цены (FR-020); вмещает ли — аллокатор (FR-006). Никто не вместил —
     BATCH_DOES_NOT_FIT. Цена p_price_per_kg (>= ask). Возвращает pool_line_id.';
revoke execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) from public, anon;
grant  execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) to authenticated;
