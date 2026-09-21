-- ============================================================================
-- РЕМОНТ ARS-760 · партии, застрявшие в `awaiting_price_decision` без отказа рынка
-- Спек: Docs/AGOS-TSP-PriceDecisionEntry-ARS-760.md (FR-005/FR-006/FR-007/FR-014)
--
-- ЗАЧЕМ. До ARS-760 в точку решения по цене уходила ЛЮБАЯ непроданная партия на
-- рынке старше N минут — в том числе та, которой никто не делал предложений.
-- Для фермера это выглядело как «рынок не берёт, снижай цену», хотя рынок партию
-- не видел. Замерено на проде: c6ef90f8 прошла 1700 → 1600 → 1500 → 1400 ₸/кг при
-- нуле офферов; f473d040 висит в точке решения со 2 июля, офферов ноль.
-- Миграция 20260921120000 закрывает вход на будущее; этот скрипт возвращает на
-- рынок то, что уже застряло.
--
-- ПОРЯДОК ОБЯЗАТЕЛЕН (FR-005): сначала миграция, потом ремонт. Наоборот — первый же
-- открытый кабинет фермера утащит возвращённые партии обратно старым правилом.
--
-- ПРЕДИКАТ — ЗЕРКАЛО FR-001, А НЕ У́ЖЕ ЕГО. Возвращаем партии, у которых в нынешнем
-- выходе на рынок НЕТ НИ ОДНОГО expired-оффера: ноль офферов вовсе либо только
-- withdrawn/rejected. Если бы ремонт брал только «ноль офферов», партия со снятыми
-- офферами осталась бы в точке решения навсегда: новое правило её туда больше не
-- пустит, а ремонт бы не достал.
--
-- ЦЕНУ НЕ ТРОГАЕМ (FR-006). Какая цена стоит — с такой партия и возвращается.
-- Решение владельца 21.09 по c6ef90f8: оставить 1400. Переписывать историю торга
-- задним числом ремонт не берётся. Прибор FR-004 — в диффе слайса нет ни одной
-- новой записи в batches.farmer_price_per_kg, и этот файл её тоже не содержит.
--
-- ВОЗВРАТ — ПОЛНАЯ СМЕНА СОСТОЯНИЯ (FR-014), а не правка одного поля:
--   · awaiting_price_decision_at → null (партия больше не ждёт решения);
--   · published_at → now() — партия выходит на рынок заново, и окно FR-001 для неё
--     начинается с чистого листа: прежние протухшие офферы в него не попадут;
--   · offering_at → null — рассылки сейчас нет; ровно так же делает rpc_lower_price.
--     Для партий, пришедших в точку решения из `published`, это no-op.
--   · строка в batch_events с типом `returned_to_published` — тип уже живёт в коде
--     (d02_tsp.sql:6898, возврат партий отменённой заявки) и означает буквально то,
--     что здесь происходит. created_by = NULL: ремонт идёт скриптом, пользователя
--     нет, колонка это допускает (d02_tsp.sql:1656).
--     Массовая смена статусов на проде без следа в журнале недопустима.
--
-- ИДЕМПОТЕНТНОСТЬ (FR-007). Предикат требует status = 'awaiting_price_decision';
-- после прогона у отремонтированных партий статус `published`, поэтому повторный
-- прогон не меняет ни одной строки и не пишет ни одного события.
--
-- ЗАПУСК: python3 scripts/run_sql_rollback.py scripts/deploy/repair_ars760_stuck_price_decision.sql
--         (по умолчанию ROLLBACK — прогон показывает счётчики и откатывается;
--          --apply применяет). ПОСЛЕ: python3 scripts/prod_diff.py
-- ============================================================================

do $repair$
declare
    v_before   int;
    v_fixed    int := 0;
    v_events   int := 0;
    v_left     int;
    v_legit    int;
begin
    -- ── СТОРОЖ ПОРЯДКА (FR-005) ─────────────────────────────────────────────
    -- «Ремонт идёт ПОСЛЕ правки правила» — до 21.09 это держалось одним комментарием
    -- в шапке (находка ревью якоря 7). Комментарий порядок не обеспечивает: прогон
    -- ремонта на старом правиле вернёт партии на рынок, а первый же открытый кабинет
    -- утащит их обратно возрастом — и это будет выглядеть как успешный ремонт.
    if coalesce(obj_description('public.rpc_self_review_due_batches()'::regprocedure, 'pg_proc'), '')
       not like '%ARS-760%' then
        raise exception 'ПРАВИЛО НЕ ВЫЛОЖЕНО: rpc_self_review_due_batches на этой базе — '
                        'старое (возрастное) тело. Сначала примени миграцию '
                        '20260921120000_ars_760_price_decision_after_market_refusal.sql, '
                        'потом этот ремонт (FR-005)';
    end if;

    -- ── ИЗМЕРЕНИЕ ДО ────────────────────────────────────────────────────────
    select count(*) into v_before
    from public.batches b
    where b.status = 'awaiting_price_decision'
      and not exists (
          select 1 from public.offers o
          where o.batch_id   = b.id
            and o.status     = 'expired'
            and o.expires_at >= b.published_at
      );

    select count(*) into v_legit
    from public.batches b
    where b.status = 'awaiting_price_decision'
      and exists (
          select 1 from public.offers o
          where o.batch_id   = b.id
            and o.status     = 'expired'
            and o.expires_at >= b.published_at
      );

    raise notice 'ДО ремонта: в точке решения без отказа рынка = % (вернём), по отказу = % (не трогаем, M-008)',
        v_before, v_legit;

    -- ── ВОЗВРАТ НА РЫНОК (FR-005 + FR-014) ──────────────────────────────────
    with fixed as (
        update public.batches b
        set status                     = 'published',
            awaiting_price_decision_at = null,
            published_at               = now(),
            offering_at                = null,
            updated_at                 = now()
        where b.status = 'awaiting_price_decision'
          and not exists (
              select 1 from public.offers o
              where o.batch_id   = b.id
                and o.status     = 'expired'
                and o.expires_at >= b.published_at
          )
        returning b.id
    ),
    ev as (
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        select f.id, 'returned_to_published',
               jsonb_build_object(
                   'via',    'repair_ars760',
                   'reason', 'no_market_refusal'
               ),
               null
        from fixed f
        returning 1
    )
    select (select count(*) from fixed), (select count(*) from ev)
      into v_fixed, v_events;

    raise notice 'M-007 возвращено на рынок: партий = %, событий записано = %', v_fixed, v_events;

    -- Что этот сторож ловит НА САМОМ ДЕЛЕ: измерение и update ходят по байт-в-байт
    -- одинаковым предикатам в одной транзакции, поэтому разойтись они могут только
    -- из-за ПАРАЛЛЕЛЬНОГО писателя (открытый кабинет фермера). Ошибку в самом
    -- предикате он поймать не может — она одинаково сместит оба числа.
    if v_fixed <> v_before then
        raise exception 'СЧЁТ РАЗОШЁЛСЯ: до = %, починено = % — между измерением и правкой '
                        'кто-то писал в те же строки; прогони заново', v_before, v_fixed;
    end if;

    -- Событие на каждую тронутую партию — иначе смена статуса осталась бы без следа.
    if v_events <> v_fixed then
        raise exception 'ЖУРНАЛ НЕПОЛОН: партий = %, событий = % — FR-014 требует строку '
                        'в batch_events на каждую возвращённую партию', v_fixed, v_events;
    end if;

    if v_fixed = 0 then
        raise notice 'Изменений нет — ремонт уже применён (FR-007: повтор ничего не меняет).';
    end if;

    -- ── КОНТРОЛЬНЫЙ ЗАМЕР ───────────────────────────────────────────────────
    -- §Verification спека формулирует его у́же ремонта — «партий в точке решения без
    -- единого оффера ноль». Меряем по ПРЕДИКАТУ РЕМОНТА (нет expired-оффера нынешнего
    -- круга), который эту формулировку включает в себя. Найдено ревью якоря 7: замер по
    -- узкой формулировке возвращал бы 0 и при сужении самого предиката до «ноль
    -- офферов» — то есть не отличал бы починенный ремонт от сломанного ровно на том
    -- классе, ради которого предикат расширяли (партия со снятыми офферами, FR-005).
    select count(*) into v_left
    from public.batches b
    where b.status = 'awaiting_price_decision'
      and not exists (
          select 1 from public.offers o
          where o.batch_id   = b.id
            and o.status     = 'expired'
            and o.expires_at >= b.published_at
      );

    if v_left <> 0 then
        raise exception 'КОНТРОЛЬНЫЙ ЗАМЕР НЕ СОШЁЛСЯ: в точке решения осталось % партий '
                        'без отказа рынка', v_left;
    end if;

    raise notice 'Контрольный замер: партий в точке решения без отказа рынка = 0.';
end
$repair$;
