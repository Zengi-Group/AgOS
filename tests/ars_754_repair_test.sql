-- ARS-754 / ремонт «частями» — ЧАСТЬ 2 из 2: проверки после ДВУХ прогонов ремонта.
-- Склейка и запуск — в шапке tests/ars_754_repair_fixtures.sql.
--
-- Покрытие матрицы (id в каждом утверждении и в строке NOTICE «… ok»):
--   M-011 (применение: статус отстающего куска, heads и история сделки не тронуты,
--          отметки этапов — из кусков, журнал remainder_withdrawn),
--   M-012 (повтор: второй прогон ничего не меняет, строка вне признака не тронута),
--   M-009 (в имитации «после»: partially_matched на базе — 0).
-- M-010 (распечатка без изменения базы) — вывод прогона ПРОСМОТРА самого скрипта,
-- прикладывается к PR до «да» владельца.

do $$
declare
    v_b1 uuid := (select id from ars754_fx where name = 'b1');
    v_b2 uuid := (select id from ars754_fx where name = 'b2');
    v_b3 uuid := (select id from ars754_fx where name = 'b3');
    v_r  record;
    v_n  int;
begin
    -- ── M-011 · фикстура как живые партии: один delivered-кусок + cancelled + pending-оффер
    select * into v_r from public.batches where id = v_b1;
    if v_r.status <> 'delivered' or v_r.heads <> 20 or v_r.matched_heads <> 10 then
        raise exception 'ARS-754 M-011: b1 → % / гол. % / продано %, ожидалось delivered / 20 / 10',
            v_r.status, v_r.heads, v_r.matched_heads;
    end if;
    if v_r.confirmed_at  is distinct from (select ts from ars754_fx where name = 'b1_confirmed')
       or v_r.dispatched_at is distinct from (select ts from ars754_fx where name = 'b1_dispatched')
       or v_r.delivered_at  is distinct from (select ts from ars754_fx where name = 'b1_delivered') then
        raise exception 'ARS-754 M-011 (FR-011): отметки этапов b1 не взяты из куска: % / % / %',
            v_r.confirmed_at, v_r.dispatched_at, v_r.delivered_at;
    end if;
    if not exists (select 1 from public.offers
                   where id = (select id from ars754_fx where name = 'o1') and status = 'withdrawn') then
        raise exception 'ARS-754 M-011 (FR-010): pending-оффер партии не погашен';
    end if;

    -- ── M-011 · два живых куска: статус = отстающий, этап — позднейшая отметка среди дошедших
    select * into v_r from public.batches where id = v_b2;
    if v_r.status <> 'dispatched' or v_r.heads <> 30 or v_r.matched_heads <> 20 then
        raise exception 'ARS-754 M-011: b2 → % / гол. % / продано %, ожидалось dispatched / 30 / 20',
            v_r.status, v_r.heads, v_r.matched_heads;
    end if;
    if v_r.confirmed_at  is distinct from (select ts from ars754_fx where name = 'b2_confirmed')
       or v_r.dispatched_at is distinct from (select ts from ars754_fx where name = 'b2_dispatched')
       or v_r.delivered_at is not null then
        raise exception 'ARS-754 M-011 (FR-011): этапы b2 % / % / % — ожидались позднейшие из кусков и пустой delivered',
            v_r.confirmed_at, v_r.dispatched_at, v_r.delivered_at;
    end if;

    -- ── M-011 · все партии признака (живые + фикстуры): heads, куски, заявки, строки не тронуты
    for v_r in select * from ars754_before loop
        if not exists (
            select 1 from public.batches b
            where b.id = v_r.id and b.heads = v_r.heads and b.matched_heads = v_r.live_heads
              and b.status in ('matched', 'confirmed', 'dispatched', 'delivered')
              and (select string_agg(a.id::text || ':' || a.status || ':' || coalesce(a.delivered_at::text, '-'), ',' order by a.id)
                   from public.batch_allocations a where a.batch_id = b.id) = v_r.chunks
              and (select string_agg(p.id::text || ':' || p.status || ':' || p.matched_heads, ',' order by p.id)
                   from public.pools p where p.id in (select a.pool_id from public.batch_allocations a where a.batch_id = b.id)) = v_r.pools
              and (select string_agg(pl.id::text || ':' || pl.current_heads, ',' order by pl.id)
                   from public.pool_lines pl where pl.id in (select a.pool_line_id from public.batch_allocations a where a.batch_id = b.id)) = v_r.lines
        ) then
            raise exception 'ARS-754 M-011: партия % — heads/продано/куски/заявки/строки не как ожидалось', v_r.id;
        end if;
        -- Отметки этапов живых партий — не моментом ремонта (FR-011).
        if exists (select 1 from public.batches b where b.id = v_r.id
                   and (b.confirmed_at >= transaction_timestamp()
                        or b.dispatched_at >= transaction_timestamp()
                        or b.delivered_at >= transaction_timestamp())) then
            raise exception 'ARS-754 M-011 (FR-011): партии % поставлена отметка этапа моментом ремонта', v_r.id;
        end if;
    end loop;
    raise notice 'ARS-754 M-011 ok: % партий признака — статус отстающего куска, heads и история сделки не тронуты, этапы из кусков',
        (select count(*) from ars754_before);

    -- ── M-011 / M-012 · журнал: ровно одно remainder_withdrawn на партию после ДВУХ прогонов
    for v_r in select * from ars754_before loop
        select count(*) into v_n from public.batch_events e
        where e.batch_id = v_r.id and e.event_type = 'remainder_withdrawn'
          and e.metadata ->> 'repair' = 'ARS-754' and e.created_by is null;
        if v_n <> 1 then
            raise exception 'ARS-754 M-012: у партии % событий ремонта %, ожидалось ровно 1 после двух прогонов', v_r.id, v_n;
        end if;
    end loop;

    -- ── M-012 · строка вне признака не тронута
    if (select ctid from public.batches where id = v_b3) <> (select tid from ars754_b3_before)
       or not exists (select 1 from public.offers
                      where id = (select id from ars754_fx where name = 'o3') and status = 'pending') then
        raise exception 'ARS-754 M-012: партия вне признака или её оффер изменены ремонтом';
    end if;
    raise notice 'ARS-754 M-012 ok: второй прогон ничего не добавил, строка вне признака не тронута';

    -- ── M-009 · имитация «после»: partially_matched на базе нет
    select count(*) into v_n from public.batches where status = 'partially_matched';
    if v_n <> 0 then
        raise exception 'ARS-754 M-009: после ремонта в partially_matched % партий', v_n;
    end if;
    raise notice 'ARS-754 M-009 ok (имитация): partially_matched = 0';

    raise notice 'ARS-754 REPAIR TEST PASSED: M-011, M-012, M-009';
end;
$$;

rollback;
