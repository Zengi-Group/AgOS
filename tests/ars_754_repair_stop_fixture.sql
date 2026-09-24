-- ARS-754 / ремонт — стоп FR-010: под признак попала партия БЕЗ живых кусков.
-- Склейка (прогон ОБЯЗАН упасть с «РЕМОНТ ОСТАНОВЛЕН», база не изменена):
--   cat tests/ars_754_repair_stop_fixture.sql \
--       scripts/deploy/repair_ars754_partial_batches.sql > /tmp/ars754_repair_stop.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars754_repair_stop.sql \
--       | grep -q 'под признак попали партии без живых кусков' && echo 'FR-010 stop ok'
-- Приёмка — ИМЕННО эта строка: «прогон упал» сам по себе не доказательство (ревью якоря 7).
-- Раннер выходит с 1 и на ожидаемом, и на любом другом отказе, а у страховки внутри цикла
-- тот же префикс «РЕМОНТ ОСТАНОВЛЕН». Текст стопа ДО цикла — единственный, кто его отличает.
-- Стоп стоит в скрипте ДО цикла ремонта, поэтому вместе с фикстурой не ремонтируются и
-- живые партии прода под признаком — это и требует FR-010 («весь прогон»).

\set ON_ERROR_STOP on

begin;

do $$
declare
    v_region   uuid := gen_random_uuid();
    v_org_farm uuid := gen_random_uuid();
    v_sku_id   uuid;
begin
    if transaction_timestamp() = statement_timestamp() then
        raise exception 'ARS-754_TEST_SETUP: файл обязан идти в ЯВНОЙ транзакции — QA-ENV-ISOLATION-01';
    end if;
    select s.id into v_sku_id from public.tsp_skus s where s.is_active = true limit 1;
    insert into public.regions (id, code, name_ru, level)
    values (v_region, 'QA-754S-' || substr(replace(v_region::text, '-', ''), 1, 8), 'QA ARS-754 стоп', 'oblast');
    insert into public.organizations (id, legal_name, legal_form, region_id, address_text)
    values (v_org_farm, 'QA ARS-754S КХ', 'kh', v_region, 'г. QA');
    -- partially_matched без единого куска — «решение за владельцем»
    insert into public.batches (id, organization_id, tsp_sku_id, heads, avg_weight_kg, target_month,
                                region_id, status, matched_heads)
    values (gen_random_uuid(), v_org_farm, v_sku_id, 10, 400.00, date_trunc('month', now())::date,
            v_region, 'partially_matched', 5);
end;
$$;
