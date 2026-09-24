-- ARS-754 / ремонт «частями» — ЧАСТЬ 1 из 2: фикстуры и снимок «до».
--
-- Файл НЕ самостоятелен: проверяет НАСТОЯЩИЙ скрипт
-- scripts/deploy/repair_ars754_partial_batches.sql, а не его копию. Склейка (скрипт
-- ремонта идёт ДВАЖДЫ — так проверяется M-012 на живом артефакте):
--   cat tests/ars_754_repair_fixtures.sql \
--       scripts/deploy/repair_ars754_partial_batches.sql \
--       scripts/deploy/repair_ars754_partial_batches.sql \
--       tests/ars_754_repair_test.sql > /tmp/ars754_repair_run.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars754_repair_run.sql
-- Всё идёт одной откатываемой транзакцией: ни одной строки не остаётся.
--
-- Стоп FR-010 (партия без живых кусков) — отдельной склейкой, прогон ОБЯЗАН упасть с
-- текстом стопа ДО цикла; команда приёмки — в шапке tests/ars_754_repair_stop_fixture.sql.
--
-- Под признак ремонта попадают и ЖИВЫЕ партии прода (сегодня две) — проверки части 2
-- смотрят и на них: снимок «до» берётся по признаку, а не по фикстурам.

\set ON_ERROR_STOP on

begin;

do $$
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-754_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции '
                        '(begin … rollback) — QA-ENV-ISOLATION-01';
    end if;
end;
$$;

create temp table ars754_fx (name text primary key, id uuid, ts timestamptz);

do $$
declare
    v_region   uuid := gen_random_uuid();
    v_org_mpk  uuid := gen_random_uuid();
    v_org_farm uuid := gen_random_uuid();
    v_sku_id   uuid;
    v_month    date := date_trunc('month', now())::date;
    v_pool     uuid := gen_random_uuid();
    v_pl       uuid := gen_random_uuid();
    v_b1 uuid := gen_random_uuid();   -- как живые: один кусок delivered, второй cancelled, pending-оффер
    v_b2 uuid := gen_random_uuid();   -- два живых куска: delivered + dispatched (отстающий)
    v_b3 uuid := gen_random_uuid();   -- ВНЕ признака: published с pending-оффером
    v_o1 uuid := gen_random_uuid();
    v_o3 uuid := gen_random_uuid();
begin
    select s.id into v_sku_id from public.tsp_skus s where s.is_active = true limit 1;
    if v_sku_id is null then raise exception 'ARS-754_TEST_SETUP: нет активного tsp_sku'; end if;

    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-754R-' || substr(replace(v_region::text, '-', ''), 1, 8),
            'QA ARS-754 ремонт', 'oblast');
    insert into public.organizations (id, legal_name, legal_form, region_id, address_text)
    values (v_org_mpk, 'QA ARS-754R МПК', 'too', v_region, 'г. QA'),
           (v_org_farm, 'QA ARS-754R КХ', 'kh', v_region, 'г. QA');

    insert into public.pools (id, organization_id, target_heads, matched_heads, status)
    values (v_pool, v_org_mpk, 30, 30, 'closed_filled');
    insert into public.pool_lines (id, pool_id, tsp_sku_id, category_label, mpk_price_per_kg, current_heads)
    values (v_pl, v_pool, v_sku_id, 'QA', 1300, 30);

    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, matched_heads, matched_at, pool_line_id, deal_price_per_kg)
    values (v_b1, v_org_farm, v_sku_id, 20, 400.00, v_month, v_region, 'partially_matched', 10,
            now() - interval '10 days', v_pl, 1300),
           (v_b2, v_org_farm, v_sku_id, 30, 400.00, v_month, v_region, 'partially_matched', 20,
            now() - interval '10 days', v_pl, 1300),
           (v_b3, v_org_farm, v_sku_id, 15, 400.00, v_month, v_region, 'published', 0, null, null, null);

    insert into public.batch_allocations (batch_id, pool_line_id, pool_id, heads, price_per_kg, status,
                                          matched_at, confirmed_at, dispatched_at, delivered_at, cancelled_at)
    values (v_b1, v_pl, v_pool, 10, 1300, 'delivered',
            now() - interval '10 days', now() - interval '9 days', now() - interval '8 days', now() - interval '7 days', null),
           (v_b1, v_pl, v_pool, 10, 1300, 'cancelled',
            now() - interval '10 days', null, null, null, now() - interval '6 days'),
           (v_b2, v_pl, v_pool, 10, 1300, 'delivered',
            now() - interval '10 days', now() - interval '9 days', now() - interval '8 days', now() - interval '7 days', null),
           (v_b2, v_pl, v_pool, 10, 1300, 'dispatched',
            now() - interval '10 days', now() - interval '5 days', now() - interval '4 days', null, null);

    insert into public.offers (id, batch_id, mpk_org_id, offered_price_per_kg, status, expires_at)
    values (v_o1, v_b1, v_org_mpk, 1300, 'pending', now() + interval '1 day'),
           (v_o3, v_b3, v_org_mpk, 1300, 'pending', now() + interval '1 day');

    insert into ars754_fx (name, id, ts) values
        ('b1', v_b1, null), ('b2', v_b2, null), ('b3', v_b3, null),
        ('o1', v_o1, null), ('o3', v_o3, null), ('pool', v_pool, null), ('pl', v_pl, null),
        ('b1_confirmed',  null, now() - interval '9 days'),
        ('b1_dispatched', null, now() - interval '8 days'),
        ('b1_delivered',  null, now() - interval '7 days'),
        ('b2_confirmed',  null, now() - interval '5 days'),   -- позднейшая из двух кусков
        ('b2_dispatched', null, now() - interval '4 days');   -- позднейшая из двух кусков
end;
$$;

-- Снимок «до» по ПРИЗНАКУ (живые партии прода + фикстуры) — M-011 сверяет с ним.
create temp table ars754_before as
select b.id, b.heads, b.matched_heads,
       (select coalesce(sum(a.heads), 0) from public.batch_allocations a
        where a.batch_id = b.id and a.status <> 'cancelled') as live_heads,
       (select string_agg(a.id::text || ':' || a.status || ':' || coalesce(a.delivered_at::text, '-'), ',' order by a.id)
        from public.batch_allocations a where a.batch_id = b.id) as chunks,
       (select string_agg(p.id::text || ':' || p.status || ':' || p.matched_heads, ',' order by p.id)
        from public.pools p where p.id in (select a.pool_id from public.batch_allocations a where a.batch_id = b.id)) as pools,
       (select string_agg(pl.id::text || ':' || pl.current_heads, ',' order by pl.id)
        from public.pool_lines pl where pl.id in (select a.pool_line_id from public.batch_allocations a where a.batch_id = b.id)) as lines
from public.batches b
where b.status = 'partially_matched';

create temp table ars754_b3_before as
select b.*, (select ctid from public.batches where id = b.id) as tid
from public.batches b where b.id = (select id from ars754_fx where name = 'b3');
