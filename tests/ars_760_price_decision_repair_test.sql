-- ARS-760 / ЧАСТЬ 2 из 2 — разовый ремонт застрявших партий (M-007…M-010).
--
-- Этот файл НЕ самостоятелен: он читает фикстуры части 1 из временной таблицы
-- ars760_fixtures и проверяет результат работы НАСТОЯЩЕГО скрипта
-- scripts/deploy/repair_ars760_stuck_price_decision.sql, а не его копии.
-- Порядок склейки (скрипт ремонта идёт ДВАЖДЫ — так проверяется M-009 на живом
-- артефакте, а не на пересказе его логики):
--   cat supabase/migrations/20260921120000_ars_760_price_decision_after_market_refusal.sql \
--       tests/ars_760_price_decision_after_market_refusal_test.sql \
--       scripts/deploy/repair_ars760_stuck_price_decision.sql \
--       scripts/deploy/repair_ars760_stuck_price_decision.sql \
--       tests/ars_760_price_decision_repair_test.sql > /tmp/ars760_run.sql
--   python3 scripts/run_sql_rollback.py /tmp/ars760_run.sql

do $$
declare
    v_b7        uuid;
    v_b8        uuid;
    v_b11       uuid;
    v_auth_farm uuid;
    v_ask       constant int := 1400;   -- цена фикстур части 1

    v_status  text;
    v_price   int;
    v_at      timestamptz;
    v_pub     timestamptz;
    v_off     timestamptz;
    v_int     int;
    v_by      uuid;
    v_has_by  boolean;
begin
    select id into v_b7        from ars760_fixtures where name = 'm007';
    select id into v_b8        from ars760_fixtures where name = 'm008';
    select id into v_b11       from ars760_fixtures where name = 'm007b';
    select id into v_auth_farm from ars760_fixtures where name = 'auth_farm';
    if v_b7 is null or v_b8 is null or v_b11 is null or v_auth_farm is null then
        raise exception 'ARS-760_TEST_SETUP: фикстуры части 1 не найдены — файлы склеены '
                        'не в том порядке; часть 2 обязана идти ПОСЛЕ части 1 и ремонта';
    end if;

    -- ── M-007 · ремонт возвращает застрявших ─────────────────────────────────────────
    select status, farmer_price_per_kg, awaiting_price_decision_at, published_at, offering_at
      into v_status, v_price, v_at, v_pub, v_off
    from public.batches where id = v_b7;

    if v_status <> 'published' then
        raise exception 'ARS-760 M-007 ПРОВАЛ: партия без единого оффера осталась в «%» — '
                        'ремонт её не достал, фермер по-прежнему не видит её на рынке', v_status;
    end if;
    -- FR-006: цену ремонт не восстанавливает и не меняет.
    if v_price <> v_ask then
        raise exception 'ARS-760 M-007 ПРОВАЛ: ремонт изменил цену % → % — переписана история '
                        'торга (нарушен FR-006)', v_ask, v_price;
    end if;
    -- FR-014: возврат — полная смена состояния, а не правка одного поля.
    if v_at is not null then
        raise exception 'ARS-760 M-007 ПРОВАЛ (FR-014): awaiting_price_decision_at не обнулён';
    end if;
    if v_pub < now() - interval '1 hour' then
        raise exception 'ARS-760 M-007 ПРОВАЛ (FR-014): published_at = % — партия не вышла на '
                        'рынок заново, и окно FR-001 для неё начнётся не с чистого листа', v_pub;
    end if;
    if v_off is not null then
        raise exception 'ARS-760 M-007 ПРОВАЛ (FR-014): offering_at = % — строка утверждает '
                        'активную рассылку, которой нет', v_off;
    end if;
    raise notice 'ARS-760 M-007 OK: партия вернулась на рынок по прежней цене %', v_price;

    -- FR-014 · след в журнале: массовая смена статусов без записи недопустима.
    select count(*) into v_int
    from public.batch_events
    where batch_id = v_b7 and event_type = 'returned_to_published';
    if v_int < 1 then
        raise exception 'ARS-760 M-007 ПРОВАЛ (FR-014): возврат не оставил следа в batch_events';
    end if;

    select created_by is null into v_has_by
    from public.batch_events
    where batch_id = v_b7 and event_type = 'returned_to_published'
    order by created_at desc limit 1;
    if v_has_by is not true then
        raise exception 'ARS-760 M-007 ПРОВАЛ (FR-014): у события возврата проставлен created_by — '
                        'ремонт идёт скриптом, пользователя нет';
    end if;

    -- ── M-008 · ремонт не трогает законно застрявших ─────────────────────────────────
    select status into v_status from public.batches where id = v_b8;
    if v_status <> 'awaiting_price_decision' then
        raise exception 'ARS-760 M-008 ПРОВАЛ: партия с expired-оффером нынешнего круга уехала '
                        'в «%» — ремонт достал того, кому рынок ДЕЙСТВИТЕЛЬНО отказал', v_status;
    end if;
    raise notice 'ARS-760 M-008 OK: законно застрявшая партия осталась в точке решения';

    -- ── FR-005 (зеркало) · ремонт достаёт партию со СНЯТЫМИ офферами ─────────────────
    -- Прибор на РАСШИРЕНИЕ предиката ремонта. Найдено ревью якоря 7: сужение предиката
    -- до «ноль офферов» не роняло ни M-007, ни M-008, ни контрольный замер скрипта.
    select status into v_status from public.batches where id = v_b11;
    if v_status <> 'published' then
        raise exception 'ARS-760 FR-005 (зеркало) ПРОВАЛ: партия, у которой офферы только '
                        'withdrawn/rejected, осталась в «%». Отказа по цене у неё не было, '
                        'новое правило её туда больше не пустит — значит ремонт оставил её '
                        'в точке решения НАВСЕГДА', v_status;
    end if;
    raise notice 'ARS-760 FR-005 (зеркало) OK: партия со снятыми офферами возвращена на рынок';

    -- ── M-009 · повтор ремонта ───────────────────────────────────────────────────────
    -- Скрипт ремонта в склейке выполнен ДВАЖДЫ. Если бы второй прогон что-то менял,
    -- у партии M-007 было бы два события возврата.
    select count(*) into v_int
    from public.batch_events
    where batch_id = v_b7 and event_type = 'returned_to_published';
    if v_int <> 1 then
        raise exception 'ARS-760 M-009 ПРОВАЛ: после двух прогонов ремонта событий возврата = % '
                        '(ожидалось 1) — повтор меняет строки', v_int;
    end if;
    raise notice 'ARS-760 M-009 OK: второй прогон ремонта не изменил ни строки';

    -- ── M-010 · ремонт после правила, а не до ────────────────────────────────────────
    -- Фермер открывает кабинет — свип зовётся снова. Возвращённая партия обратно
    -- в точку решения уходить НЕ должна: офферов у неё нет, отказа не было.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_auth_farm::text, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.rpc_self_review_due_batches();
    execute 'reset role';

    select status into v_status from public.batches where id = v_b7;
    if v_status <> 'published' then
        raise exception 'ARS-760 M-010 ПРОВАЛ: после ремонта первый же прогон свипа утащил партию '
                        'обратно в «%» — правило и ремонт спорят друг с другом', v_status;
    end if;
    raise notice 'ARS-760 M-010 OK: открытый кабинет не утащил возвращённую партию обратно';

    raise notice 'ARS-760: часть 2 пройдена. Все 13 сценариев матрицы, проверяемые на данных, закрыты.';
end;
$$;

rollback;
