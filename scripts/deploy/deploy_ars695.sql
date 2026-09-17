-- ============================================================================
-- ВЫКЛАДКА ARS-695 · точка выбора комбината при недоборе заявки
-- PR #196 (смержен 2026-09-14) · спек Docs/AGOS-TSP-PoolDecision-Underfill-ARS-695.md
--
-- ⚠️ ПОЧЕМУ ЭТОТ ФАЙЛ, А НЕ deploy.py --files
-- На d02_tsp.sql стоит guard ARS-314. Но опасность шире, чем говорит guard, и
-- измерена перед сборкой (2026-09-14):
--   · полный реплей 20260622120000 откатил бы 13 функций к старым версиям —
--     включая rpc_get_pool_matches (монитор заявки ARS-684, починен 10.09),
--     rpc_self_accept_offer / _auto_match_batch / _activate_pool_request
--     (revert 26.07) и rpc_self_match_batch_to_pool (Слайс 9);
--   · полный реплей 20260702190000 откатил бы rpc_get_pool_matches туда же.
-- Поэтому из этих двух миграций берутся ТОЛЬКО функции, которые изменил ARS-695.
-- Целиком применяются лишь две: 20260726140000 (проверено — ничего не откатывает)
-- и 20260914120000 (новая, только свои объекты).
--
-- ПОРЯДОК: этот файл → фронт. Новые кнопки кабинета зовут RPC, которых без него нет.
-- Обратной несовместимости нет: старый фронт на новом бэке покажет недобор как раньше.
--
-- ЗАПУСК: python3 scripts/run_sql_rollback.py scripts/deploy/deploy_ars695.sql
--         (по умолчанию ROLLBACK; --apply применяет)
-- ПОСЛЕ:  python3 scripts/prod_diff.py
-- ============================================================================


-- ── 1. d02: порог как данные (FR-008) ────────────────────────────────────────

-- ARS-695 (FR-008, P8): порог осмысленности закупки — сколько голов должно набраться,
-- чтобы недобравшаяся заявка вообще получила право на решение МПК. Ниже порога выбора
-- нет: партии возвращаются автоматически (FR-006). НЕ путать с min_split_heads выше —
-- та про размер КУСКА при дроблении, эта про осмысленность ЗАЯВКИ целиком.
-- Дефолт 10 голов (владелец, 11.09). Право правки — у инженера: меняется строкой
-- tsp_config, без выкладки кода и без экрана в админке.
alter table public.tsp_config
    add column if not exists min_pool_heads int not null default 10;
-- Урок ARS-690: `add column if not exists` не трогает дефолт уже существующей колонки.
-- Для новой колонки это неважно (её ещё нет нигде), но явный `set default` держит
-- инвариант «канон = прод» и при повторной выкладке файла.
alter table public.tsp_config
    alter column min_pool_heads set default 10;
alter table public.tsp_config drop constraint if exists chk_tsp_config_min_pool_heads;
alter table public.tsp_config add  constraint chk_tsp_config_min_pool_heads
    check (min_pool_heads > 0);
comment on column public.tsp_config.min_pool_heads is
    'ARS-695 (FR-008): минимум голов на ЗАЯВКУ, при котором недобор даёт МПК точку выбора
     (awaiting_mpk_decision: принять частично | вернуть партии). Набрано меньше порога —
     выбора нет, партии возвращаются автоматически (closed_unfilled, FR-006); набрано
     ноль — expired_empty (MS4 PT-04). Дефолт 10 (владелец 11.09). Отличать от
     min_split_heads: та — минимальный размер куска, эта — осмысленность заявки.
     Отступление от MS4 §2.5 (там порога нет вовсе) — FR-021, канон правится этим же PR.';


-- ── 2. d02: контейнмент канонических RPC (FR-013) ────────────────────────────
create or replace function public.rpc_pool_return_batches(
    p_organization_id   uuid,
    p_pool_id           uuid
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
    select p.*
      into v_pool
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
    -- ARS-695 FR-013 (контейнмент, аддитивно — сигнатура не трогается, P7): выше
    -- проверяется лишь то, что клиент прислал СВОЙ же p_organization_id — параметр,
    -- который он полностью контролирует. Любой вызывающий мог передать чужую пару
    -- (org, pool) и закрыть чужую заявку. До этого слайса дыра была недостижима
    -- только потому, что недостижим сам статус awaiting_mpk_decision; слайс делает
    -- статус достижимым, поэтому гейт ставится тем же PR. Отставка функции — ARS-98.
    if not (p_organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: caller does not belong to organization %', p_organization_id
            using errcode = 'P0001';
    end if;
    if v_pool.status != 'awaiting_mpk_decision' then
        raise exception 'INVALID_STATUS: pool must be awaiting_mpk_decision (current %)',
            v_pool.status using errcode = 'P0001';
    end if;

    -- Withdraw any still-pending offers for matched batches in this pool BEFORE
    -- resetting batch.pool_line_id (M4 §2.4 close_pool: pending offers to MPKs
    -- for this category are withdrawn when the pool closes).
    -- + emit market.offer.withdrawn (TSP-FLOW-06, reason=pool_returned, Dok4 §3.3a).
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
               'reason', 'pool_returned'
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
        values (v_batch_id, 'returned_to_published',
            jsonb_build_object('pool_id', p_pool_id),
            public.fn_current_user_id());

        v_count := v_count + 1;
    end loop;

    -- Reset pool_line volumes
    update public.pool_lines
    set current_volume_kg = 0,
        updated_at        = now()
    where pool_id = p_pool_id;

    -- Pool -> closed_unfilled
    update public.pools
    set status        = 'closed_unfilled',
        matched_heads = 0,
        completed_at  = now(),
        updated_at    = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.closed_unfilled', 'pools', p_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id, 'returned_batches', v_count),
        true
    );

    return v_count;
end; $$;

comment on function public.rpc_pool_return_batches(uuid, uuid) is
    'D-TSP-10 / Microstep6 §4f step 6A | FSM pools: awaiting_mpk_decision -> closed_unfilled.
     Returns: count of batches returned to published.
     ARS-695 FR-013: НЕ в рабочем пути. Канон торгового слоя = self-serve adapter
     (D-TSP-CANON-01); рабочий возврат — rpc_self_pool_return_batches, который покрывает
     ОБА маршрута матча (batch_allocations + batches.pool_line_id). Эта функция знает
     только второй, поэтому оставила бы куски в тупике. Оставлена под revoke до отставки
     (дом — ARS-98 / Слайс D).';
-- ARS-695 FR-013: функция не попала в систем-ревок 26.07 (20260726130000) — на ней жил
-- дефолтный PUBLIC-грант. Пока статус awaiting_mpk_decision был недостижим, дыра была
-- недостижима вместе с ним; этот слайс делает статус достижимым → отзываем явно.
revoke execute on function public.rpc_pool_return_batches(uuid, uuid) from public, anon, authenticated;


create or replace function public.rpc_pool_accept_partial(
    p_organization_id   uuid,
    p_pool_id           uuid
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
    select p.*
      into v_pool
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
    -- ARS-695 FR-013 (контейнмент, аддитивно — сигнатура не трогается, P7): см. тот же
    -- гейт в rpc_pool_return_batches выше. p_organization_id приходит от клиента и им же
    -- сверяется — этого мало; org обязана принадлежать вызывающему.
    if not (p_organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: caller does not belong to organization %', p_organization_id
            using errcode = 'P0001';
    end if;
    if v_pool.status != 'awaiting_mpk_decision' then
        raise exception 'INVALID_STATUS: pool must be awaiting_mpk_decision (current %)',
            v_pool.status using errcode = 'P0001';
    end if;

    for v_batch_id in
        select b.id
        from public.batches b
        join public.pool_lines pl on pl.id = b.pool_line_id
        where pl.pool_id = p_pool_id
          and b.status = 'matched'
        for update
    loop
        update public.batches
        set status       = 'confirmed',
            confirmed_at = now(),
            updated_at   = now()
        where id = v_batch_id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch_id, 'confirmed',
            jsonb_build_object('pool_id', p_pool_id, 'partial_accept', true),
            public.fn_current_user_id());

        v_count := v_count + 1;
    end loop;

    update public.pools
    set status       = 'closed_partial',
        completed_at = now(),
        updated_at   = now()
    where id = p_pool_id;

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.pool.closed_partial', 'pools', p_pool_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('pool_id', p_pool_id, 'confirmed_batches', v_count),
        true
    );

    return v_count;
end; $$;

comment on function public.rpc_pool_accept_partial(uuid, uuid) is
    'D-TSP-10 / Microstep6 §4f step 6B | FSM pools: awaiting_mpk_decision -> closed_partial.
     All matched batches -> confirmed. Returns: count of confirmed batches.
     ARS-695 FR-013: НЕ в рабочем пути. Рабочее подтверждение — rpc_self_pool_accept_partial
     (оба маршрута матча + приведение target_heads к набранному). Оставлена под revoke до
     отставки (дом — ARS-98 / Слайс D).';
-- ARS-695 FR-013: см. rpc_pool_return_batches выше — тот же пропуск систем-ревока 26.07.
revoke execute on function public.rpc_pool_accept_partial(uuid, uuid) from public, anon, authenticated;


-- ── 3. 20260622120000, ТОЧЕЧНО: advance_pool_status ──────────────────────────
-- 15. rpc_self_advance_pool_status — МПК двигает статус пула. executing →
-- раскрытие контактов (D40). Гейт «пул моей org» (через pool_request).
-- ============================================================
create or replace function public.rpc_self_advance_pool_status(
    p_pool_id uuid, p_new_status text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool    public.pools%rowtype;
    v_req     public.pool_requests%rowtype;
    -- ARS-695 (FR-002): + awaiting_mpk_decision — статус, который до этого слайса был
    -- недостижим на self-serve пути вовсе (QA TSPM-CLOSE-03, долг TSP-FLOW-10).
    v_allowed text[] := array['filled','executing','dispatched','delivered','executed',
                              'closed','awaiting_mpk_decision'];
begin
    if not (p_new_status = any (v_allowed)) then
        raise exception 'INVALID_STATUS' using errcode = 'P0002';
    end if;
    select * into v_pool from public.pools where id = p_pool_id;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0003'; end if;
    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    if p_new_status = 'executing' and v_pool.mpk_contact_revealed_at is null then
        update public.pools
        set status = 'executing', mpk_contact_revealed_at = now(), executing_at = now(), updated_at = now()
        where id = p_pool_id;
    elsif p_new_status = 'executed' then
        update public.pools
        set status = 'executed', executed_at = now(), updated_at = now()
        where id = p_pool_id;
    elsif p_new_status = 'closed' then
        update public.pools
        set status = 'closed', closed_at = now(), updated_at = now()
        where id = p_pool_id;
    elsif p_new_status = 'awaiting_mpk_decision' then
        -- FR-006: ниже порога заявка выбора НЕ получает. Без этой проверки ручной перевод
        -- был бы дырой в обход правила порога: оператор загоняет заявку 2/220 прямо в точку
        -- выбора и закрывает её принятием — правило живёт в fn_tsp_pool_settle_underfill,
        -- мимо которого такой путь проходит. Из UI статус недостижим (REAL_STATUSES его не
        -- содержит), но функция открыта роли authenticated, поэтому гейт нужен в теле.
        if v_pool.matched_heads < public.fn_tsp_pool_min_heads() then
            raise exception 'BELOW_MIN_HEADS: набрано % при минимуме % — точка выбора не положена',
                v_pool.matched_heads, public.fn_tsp_pool_min_heads() using errcode = 'P0002';
        end if;
        -- FR-012: у входа в точку выбора есть своя отметка времени — от неё считается
        -- окно молчания FR-007. coalesce: повторный перевод не перезапускает окно.
        update public.pools
        set status = 'awaiting_mpk_decision',
            awaiting_decision_at = coalesce(awaiting_decision_at, now()),
            updated_at = now()
        where id = p_pool_id;
    else
        update public.pools set status = p_new_status, updated_at = now() where id = p_pool_id;
    end if;
    return true;
end;
$$;
comment on function public.rpc_self_advance_pool_status(uuid, text) is
    'КАНОН d02 | Слайс 6 | ARS-695 | МПК двигает статус пула. executing → раскрытие
     контактов (D40). Гейт «пул моей org» (через pool_request). + awaiting_mpk_decision
     со своей отметкой времени (FR-002/FR-012).
     ИСПРАВЛЕНО ARS-695: прежний текст утверждал, будто «в d02 у партий нет состояний
     confirmed/delivered». Это неверно — batches_status_check содержит их обоих
     (d02_tsp.sql:5572-5574), а D-TSP-11 прямо требует confirmed после закрытия заявки
     и только из него dispatch. Ложная посылка прожила в комментарии до 14.09 и чуть не
     стала «противоречием канона» в тикете ARS-695; переходы партий делают
     rpc_self_pool_accept_partial / rpc_self_pool_return_batches, не эта функция.';
revoke execute on function public.rpc_self_advance_pool_status(uuid, text) from public, anon;
grant  execute on function public.rpc_self_advance_pool_status(uuid, text) to authenticated;


-- ── 4. 20260622120000, ТОЧЕЧНО: rpc_get_my_pools ─────────────────────────────
-- Комментарий стоит ЗДЕСЬ, а не внутри jsonb_build_object, намеренно: contract_snapshot.py
-- режет аргументы по запятым и матчит ключ с позиции 0, поэтому `--`-строка между парами
-- съедает следующий ключ — он молча исчезает из contracts/rpc_return_keys.txt, и CHECK 11
-- перестаёт видеть контракт, который обязан стеречь. Баг экстрактора зарегистрирован в
-- IMPL_DEBT (CONTRACT-SNAPSHOT-COMMENT-01); пока он жив — комментарии держим снаружи.
-- ============================================================
create or replace function public.rpc_get_my_pools()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'id',              p.id,
                'status',          p.status,
                'totalHeads',      p.target_heads,
                'filledHeads',     p.matched_heads,
                'region',          coalesce(r.name_ru, 'Все регионы'),
                'targetMonthIso',  to_char(pr.target_month, 'YYYY-MM-DD'),
                'createdAtIso',    to_char(p.created_at, 'YYYY-MM-DD'),
                'lines',           coalesce((
                    select jsonb_agg(
                        jsonb_build_object('code', pl.category_label, 'price', pl.mpk_price_per_kg)
                        order by pl.mpk_price_per_kg desc
                    )
                    from public.pool_lines pl
                    where pl.pool_id = p.id and pl.is_active = true
                ), '[]'::jsonb),
                'contactRevealed', (p.mpk_contact_revealed_at is not null),
                'minPoolHeads',    public.fn_tsp_pool_min_heads()
            )
            order by p.created_at desc
        ), '[]'::jsonb)
        from public.pools p
        join public.pool_requests pr on pr.id = p.pool_request_id
        left join public.regions r on r.id = pr.region_id
        where pr.organization_id = any (public.fn_my_org_ids())
    );
end;
$$;
comment on function public.rpc_get_my_pools() is
    'КАНОН d02 | Слайс 6 | Пулы своего МПК (RawPool[]). Гейт через pool_request.organization_id
     (pools без organization_id). lines = accepted_categories.';
revoke execute on function public.rpc_get_my_pools() from public, anon;
grant  execute on function public.rpc_get_my_pools() to authenticated;


-- ── 5. 20260622120000, ТОЧЕЧНО: rpc_self_close_due_pools ─────────────────────
-- 18. rpc_self_close_due_pools — авто-закрытие просроченных пулов своих org.
-- Гейт через pool_request (pools без organization_id).
-- ============================================================
create or replace function public.rpc_self_close_due_pools()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_filled    int := 0;
    v_closed    int := 0;
    v_awaiting  int := 0;
    v_unfilled  int := 0;
    v_empty     int := 0;
    v_failed    int := 0;
    v_window    int;
    v_id        uuid;
    v_outcome   text;
    v_org       uuid;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    -- ARS-695 (FR-009): правило 30 % снято. Оно подменяло решение комбината: недобор
    -- ≥30 % принудительно засчитывался как «набрана» (анти-farmer-friendly, D-TSP-10
    -- нарушен — QA TSPM-CLOSE-03), а <30 % уходил в legacy 'closed', оставляя партии
    -- висеть matched на мёртвой заявке. Замена — порог из данных + точка выбора
    -- (fn_tsp_pool_settle_underfill). Снимается ТЕМ ЖЕ деплоем, что вводится порог:
    -- раньше — у авто-закрытия не осталось бы порога вообще и возврата не было бы.
    for v_id in
        select p.id
        from public.pools p
        join public.pool_requests pr on pr.id = p.pool_request_id
        where pr.organization_id = any (public.fn_my_org_ids())
          and p.status = 'filling'
          and current_date >= (date_trunc('month', pr.target_month) + interval '1 month')::date
    loop
        -- Блокировка строки заявки (M-011): подметание и кнопка комбината ходят одним
        -- маршрутом, поэтому обе берут строку под FOR UPDATE и не смешивают исходы.
        -- Курсор выше открыт по снапшоту: пока мы ждали блокировку, оператор мог нажать
        -- «Закрыть заявку» и заявка уже не в filling. Перечитываем статус ПОД блокировкой
        -- и молча пропускаем — применить решение второй раз значило бы закрыть заявку
        -- дважды и разойтись со своим же INVALID_STATUS на кнопке.
        perform 1 from public.pools where id = v_id for update;
        if not exists (select 1 from public.pools where id = v_id and status = 'filling') then
            continue;
        end if;
        -- Каждая заявка обрабатывается в своей подтранзакции: до ARS-695 подметание было
        -- одним UPDATE и упасть не могло, теперь оно зовёт settle_underfill со стражом
        -- M-007, который умеет raise. Без изоляции ОДНА заявка с нераспознанным маршрутом
        -- откатывала бы всё подметание org — и у остальных заявок отказал бы и авто-возврат,
        -- и вход в точку выбора, молча и навсегда (фронт зовёт эту RPC в пустом catch).
        begin
            v_outcome := public.fn_tsp_pool_settle_underfill(v_id);
            if    v_outcome = 'closed_filled'         then v_filled   := v_filled   + 1;
            elsif v_outcome = 'awaiting_mpk_decision' then v_awaiting := v_awaiting + 1;
            elsif v_outcome = 'expired_empty'         then v_empty    := v_empty    + 1;
            else                                           v_unfilled := v_unfilled + 1;
            end if;
        exception when others then
            v_failed := v_failed + 1;
            raise warning 'ARS-695 sweep: заявка % не закрыта (%): %', v_id, sqlstate, sqlerrm;
        end;
    end loop;

    -- FR-007: молчание комбината дольше окна решения = «вернуть» (D-M6-1, дефолт в
    -- пользу фермера). Исполняется этим же ленивым подметанием, а не планировщиком
    -- (ARS-694 заблокирован ARS-264) — значит не в минуту истечения окна, а при
    -- первом заходе в кабинет. Обещать мгновенность слайс не вправе (FR-015).
    select mpk_decision_window_hours into v_window
    from public.tsp_config where is_active = true limit 1;
    v_window := coalesce(v_window, 24);

    for v_id in
        select p.id
        from public.pools p
        join public.pool_requests pr on pr.id = p.pool_request_id
        where pr.organization_id = any (public.fn_my_org_ids())
          and p.status = 'awaiting_mpk_decision'
          and p.awaiting_decision_at is not null
          and p.awaiting_decision_at + make_interval(hours => v_window) <= now()
    loop
        -- Та же гонка, что и в первом цикле: пока ждали блокировку, комбинат мог сам
        -- выбрать ход и заявка уже не ждёт решения. Дефолт «вернуть» не должен
        -- перебивать состоявшееся решение оператора.
        perform 1 from public.pools where id = v_id for update;
        if not exists (
            select 1 from public.pools where id = v_id and status = 'awaiting_mpk_decision'
        ) then
            continue;
        end if;
        -- Та же изоляция подтранзакцией, что и в первом цикле.
        begin
        perform public.fn_tsp_pool_release_matches(v_id);
        update public.pools
        set status     = 'closed_unfilled',
            closed_at  = coalesce(closed_at, now()),
            updated_at = now()
        where id = v_id;
        perform public.fn_tsp_pool_assert_settled(v_id);

        select coalesce(p.organization_id, pr.organization_id) into v_org
        from public.pools p
        left join public.pool_requests pr on pr.id = p.pool_request_id
        where p.id = v_id;

        insert into public.platform_events (
            event_type, entity_type, entity_id, organization_id,
            actor_type, actor_id, payload, is_audit
        ) values (
            'market.pool.closed_unfilled', 'pools', v_id, v_org,
            'system', public.fn_current_user_id(),
            jsonb_build_object('pool_id', v_id, 'reason', 'decision_window_elapsed',
                               'window_hours', v_window),
            -- is_audit=true — как у канонической rpc_pool_return_batches (d02_tsp.sql:4293):
            -- закрытие по молчанию тоже решает судьбу чужих партий.
            true
        );
        v_unfilled := v_unfilled + 1;
        exception when others then
            v_failed := v_failed + 1;
            raise warning 'ARS-695 sweep (окно решения): заявка % не закрыта (%): %',
                v_id, sqlstate, sqlerrm;
        end;
    end loop;

    -- Форма расширена АДДИТИВНО (D-RPC-CONTRACT-SYNC-01): filled/closed остаются на
    -- месте для существующих потребителей, closed теперь = сумма терминально закрытых
    -- без набора. contracts/rpc_return_keys.txt и Dok 3 обновлены этим же PR.
    v_closed := v_unfilled + v_empty;
    return jsonb_build_object(
        'filled',           v_filled,
        'closed',           v_closed,
        'awaitingDecision', v_awaiting,
        'unfilled',         v_unfilled,
        'expiredEmpty',     v_empty,
        'failed',           v_failed
    );
end;
$$;
comment on function public.rpc_self_close_due_pools() is
    'КАНОН d02 | Слайс 6 | ARS-695 | Ленивое подметание просроченных заявок своих org
     (гейт через pool_request, без pg_cron). filling + месяц истёк → правило порога
     fn_tsp_pool_settle_underfill (одно на кнопку и на подметание, P4): closed_filled |
     awaiting_mpk_decision | closed_unfilled | expired_empty. Плюс FR-007: заявка,
     простоявшая в awaiting_mpk_decision дольше tsp_config.mpk_decision_window_hours,
     закрывается возвратом партий (дефолт в пользу фермера, D-M6-1). Правило 30 %
     снято — его заменил tsp_config.min_pool_heads.';
revoke execute on function public.rpc_self_close_due_pools() from public, anon;
grant  execute on function public.rpc_self_close_due_pools() to authenticated;


-- ── 6. 20260702190000, ТОЧЕЧНО: fn_tsp_alloc_chunk (filled_at, FR-012) ───────
-- Единственное изменение против 20260702180000: блок закрытия пула подтверждает куски
-- (matched→confirmed) и затем зовёт fn_tsp_rollup_batch_status для КАЖДОГО off-market
-- батча пула — статус батча вычисляется из его кусков (matched→confirmed и т.д.).
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
    v_min       int;
    v_remaining int;
    v_line_free int;
    v_pool_free int;
    v_kg_free   int;
    v_free      int;
    v_take      int;
    v_price     int;
    v_vol       int;
    v_full      boolean;
    v_bid       uuid;
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
    v_take := least(v_remaining, v_free);
    if v_take <= 0 then return 0; end if;

    if p_max_heads is null and v_take < v_remaining then
        select min_split_heads into v_min from public.tsp_config where is_active = true limit 1;
        v_min := coalesce(v_min, 5);
        if v_take < v_min then return 0; end if;
        if (v_remaining - v_take) < v_min then
            v_take := v_remaining - v_min;
        end if;
        if v_take < v_min then return 0; end if;
    end if;

    v_price := coalesce(p_price, v_pl.mpk_price_per_kg);
    if v_batch.farmer_price_per_kg is not null and v_price < v_batch.farmer_price_per_kg then
        raise exception 'BID_BELOW_ASK: цена куска % < ask фермера %', v_price, v_batch.farmer_price_per_kg
            using errcode = 'P0007';
    end if;
    v_vol  := coalesce(round(v_take * v_batch.avg_weight_kg)::int, 0);
    v_full := (v_batch.matched_heads + v_take) >= v_batch.heads;

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

    update public.batches
    set matched_heads     = matched_heads + v_take,
        status            = case when v_full then 'matched' else 'partially_matched' end,
        pool_line_id      = case when v_batch.matched_heads = 0 then v_pl.id else pool_line_id end,
        deal_price_per_kg = case when v_batch.matched_heads = 0 then v_price else deal_price_per_kg end,
        matched_at        = coalesce(matched_at, now()),
        updated_at        = now()
    where id = p_batch_id;

    if v_full then
        update public.offers set status = 'withdrawn', responded_at = now()
        where batch_id = p_batch_id and status = 'pending';
    end if;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'matched',
        jsonb_build_object('pool_id', v_pool.id, 'pool_line_id', v_pl.id,
                           'via', p_via, 'chunk_heads', v_take, 'deal_price_per_kg', v_price,
                           'partial', not v_full),
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
            update public.batch_allocations
            set status = 'confirmed', confirmed_at = now()
            where pool_id = v_pool.id and status = 'matched';
            -- Статус каждого off-market батча пула вычисляем из его кусков (matched→confirmed).
            -- rollup сам пропустит батчи с остатком на рынке (partially_matched).
            for v_bid in select distinct batch_id from public.batch_allocations where pool_id = v_pool.id loop
                perform public.fn_tsp_rollup_batch_status(v_bid);
            end loop;
        end if;
    end if;

    return v_take;
end;
$$;
comment on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) is
    'Слайс 9 (+S3) | Аллокатор куска батча в строку пула. take=min(остаток,свободно строки/
     пула/kg[,кап]) + правило min_split (авто) + инкременты + FSM батча. Закрытие пула:
     куски matched→confirmed, затем fn_tsp_rollup_batch_status по каждому батчу пула
     (статус = отстающий кусок, off-market only). Возвращает взятые головы (0=ничего).';
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from anon;
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from authenticated;


-- ── 7. 20260726140000 ЦЕЛИКОМ (filled_at в трёх писателях; ничего не откатывает)
-- AgOS · TSP-SLICE9-ROLLBACK-01 — продуктовое решение CEO (2026-07-26, см. DECISIONS_LOG):
-- дробление партии на куски (Слайс 9, BATCH-SPLIT-01, 20260702160000_tsp_batch_split_
-- allocations.sql) ПОКА НЕ включаем. Слайс 9 был реально живым на проде 2026-07-02 —
-- 07-05 (16 строк batch_allocations), затем кто-то откатил 3 self-serve RPC обратно на
-- до-Слайс-9 логику (20260625120000_tsp_defect_ab_redeploy.sql) вручную, вне git —
-- откат нигде не был зафиксирован. Эта миграция ЗАКРЫВАЕТ дыру канон↔прод в обратную
-- сторону: канон (в migration-файлах Слайс 9) до сих пор объявлял дробящую версию, и
-- любой будущий `deploy.py --all` тихо ВКЛЮЧИЛ бы дробление обратно — теперь канон
-- явно = тому, что реально работает на проде и что подтверждено решением CEO.
--
-- Ничего не удалено (HS-1/HS-2/P7): код Слайс 9 остаётся в
-- 20260702160000_tsp_batch_split_allocations.sql, fn_tsp_alloc_chunk/fn_tsp_rollup_
-- batch_status/batch_allocations/min_split_heads — в схеме, готовы к реактивации.
-- Это переопределение (CREATE OR REPLACE) трёх RPC телом из pg_get_functiondef с
-- прода (сверено байт-в-байт, единственный вызывающий на фронте — TSP wizard/self-
-- serve поток /cabinet и /mpk, RequireAuth). Retire-when: решение развернётся —
-- вернуть Слайс 9 версии (уже есть в 20260702160000) новой миграцией той же схемы.

-- ── rpc_self_activate_pool_request — без дробления (Слайс 6 + DEFECT-B) ──────────
create or replace function public.rpc_self_activate_pool_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_req       public.pool_requests%rowtype;
    v_pool_id   uuid;
    v_batch     public.batches%rowtype;
    v_grade     text;
    v_vol       int;
    v_line      record;
    v_win_hours int;
    v_matched   int := 0;
    v_offered   int := 0;
begin
    select * into v_req from public.pool_requests where id = p_request_id;
    if not found then raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool request not owned by current user' using errcode = 'P0001';
    end if;
    if v_req.status <> 'draft' then
        raise exception 'REQUEST_NOT_DRAFT' using errcode = 'P0003';
    end if;

    -- pools.organization_id NOT NULL (прод-сверено 2026-06-23). Берём org из заявки.
    -- Конвергенция B2: пишем delivery-окно (из target_month) и published_at — нужны
    -- канон-матчеру (overlap D-M6-8). total_target_volume_kg=NULL: auto-close по головам.
    insert into public.pools (
        organization_id, pool_request_id, status, target_heads, matched_heads,
        filling_deadline, delivery_from, delivery_to, published_at
    ) values (
        v_req.organization_id, v_req.id, 'filling', v_req.total_heads, 0,
        (date_trunc('month', v_req.target_month) + interval '1 month - 1 day')::date,
        date_trunc('month', v_req.target_month)::date,
        (date_trunc('month', v_req.target_month) + interval '1 month - 1 day')::date,
        now()
    ) returning id into v_pool_id;

    -- Конвергенция B2: бид МПК → структурные pool_lines (D-TSP-MATCH-01). Категория-код
    -- фронта (premium/vysshaya/...) → category_label; матч резолвит сорт через
    -- fn_tsp_grade_for_mpk_key(category_label). tsp_sku_id=NULL (бид по категории, не SKU).
    -- max_volume_kg=NULL (UI потолок не шлёт). Только строки с ценой > 0 (CHECK mpk_price>0).
    insert into public.pool_lines (
        pool_id, tsp_sku_id, category_label, mpk_price_per_kg,
        max_volume_kg, current_volume_kg, is_active
    )
    select v_pool_id, null, ln->>'code',
           round((ln->>'price')::numeric)::int, null, 0, true
    from jsonb_array_elements(coalesce(v_req.accepted_categories, '[]'::jsonb)) ln
    where coalesce(ln->>'price', '') <> ''
      and (ln->>'price')::numeric > 0;

    -- ── DEFECT-B fix (2026-06-25) ──────────────────────────────────────────
    -- (a) Перенос региона заявки в pool_regions (D-M6-4): даёт пулу видимость
    -- канон-путям (rpc_retry_match_pool / rpc_accept_offer EXISTS pool_regions).
    -- pool_regions.region_id NOT NULL → "Все области" (v_req.region_id is null)
    -- НЕ пишет строк: такой пул матчит только через мягкий предикат ниже
    -- (канон-hard требует явные регионы — осознанное ограничение схемы).
    if v_req.region_id is not null then
        insert into public.pool_regions (pool_id, region_type, region_id)
        values (v_pool_id, 'oblast', v_req.region_id)
        on conflict (pool_id, region_id) do nothing;
    end if;

    -- (b) Свип уже ОПУБЛИКОВАННЫХ партий: до этого фикса self-serve пул матчил
    -- только партии, созданные ПОСЛЕ него (батч-инициированный rpc_self_auto_match_
    -- batch). Теперь свежий пул сам «подхватывает» висящие published-партии —
    -- зеркало batch-матча, но pool-initiated: НЕ гейтит владельца партии (МПК
    -- матчит чужие фермерские партии, как канон rpc_retry_match_pool). Сорт —
    -- строгое равенство (=), регион — мягкий приоритет через v_req.region_id.
    select offer_window_hours into v_win_hours from public.tsp_config where is_active = true limit 1;
    v_win_hours := coalesce(v_win_hours, 24);

    for v_batch in
        select b.* from public.batches b
        where b.status = 'published'
          and b.farmer_price_per_kg is not null
        order by b.created_at asc
        for update
    loop
        v_grade := public.fn_tsp_batch_grade(v_batch.id);
        if v_grade is null then continue; end if;
        v_vol := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;

        -- 1) Прямой матч: стоящий бид этого пула >= ask, сорт=, окно, ёмкость, регион.
        select pl.id              as pl_id,
               pl.pool_id          as pool_id,
               pl.mpk_price_per_kg as bid,
               p.target_heads      as target_heads,
               p.matched_heads     as matched_heads
          into v_line
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.pool_id = v_pool_id
          and p.status = 'filling'
          and pl.is_active = true
          and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and (v_req.region_id is null
               or v_req.region_id = v_batch.region_id
               or v_req.region_id = (select parent_id from public.regions where id = v_batch.region_id))
        order by pl.mpk_price_per_kg desc
        limit 1
        for update;

        if found then
            update public.batches
            set status            = 'matched',
                pool_line_id      = v_line.pl_id,
                deal_price_per_kg = v_line.bid,
                matched_at        = now(),
                updated_at        = now()
            where id = v_batch.id;

            update public.pool_lines
            set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
            where id = v_line.pl_id;

            update public.pools
            set matched_heads = matched_heads + v_batch.heads, updated_at = now()
            where id = v_pool_id;

            -- снять прочие висящие офферы на эту партию (FCFS-консистентность)
            update public.offers set status = 'withdrawn', responded_at = now()
            where batch_id = v_batch.id and status = 'pending';

            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            values (v_batch.id, 'matched',
                jsonb_build_object('pool_id', v_pool_id, 'pool_line_id', v_line.pl_id,
                                   'via', 'pool_activate_sweep', 'deal_price_per_kg', v_line.bid),
                public.fn_current_user_id());

            v_matched := v_matched + 1;

            -- auto-close по головам → closed_filled + matched-партии → confirmed; стоп свипа
            if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
                -- ARS-695 (FR-012): + filled_at, аддитивно. Статусная логика не меняется
                -- (FR-001). Путь полного набора имеет несколько входов — отметка дописана
                -- в каждый активный, иначе колонка оставалась бы пустой в части случаев.
                update public.pools
                set status = 'closed_filled', completed_at = now(),
                    filled_at = coalesce(filled_at, now()),
                    mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
                where id = v_pool_id and status = 'filling';
                update public.batches b
                set status = 'confirmed', confirmed_at = now(), updated_at = now()
                from public.pool_lines pl
                where pl.pool_id = v_pool_id and b.pool_line_id = pl.id and b.status = 'matched';
                exit;  -- пул заполнен — дальнейшие партии не матчим
            end if;
            continue;
        end if;

        -- 2) Нет прямого матча → broadcast-оффер этому МПК (сорт+регион+окно+ёмкость,
        -- цена игнорируется; offered_price = ask). Партия published → offering.
        perform 1
        from public.pool_lines pl
        join public.pools p on p.id = pl.pool_id
        where pl.pool_id = v_pool_id
          and p.status = 'filling'
          and pl.is_active = true
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and (v_req.region_id is null
               or v_req.region_id = v_batch.region_id
               or v_req.region_id = (select parent_id from public.regions where id = v_batch.region_id))
        limit 1;

        if found then
            insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
            values (v_batch.id, v_req.organization_id, v_batch.farmer_price_per_kg, 'pending',
                    now() + make_interval(hours => v_win_hours), now())
            on conflict (batch_id, mpk_org_id) do update
                set offered_price_per_kg = excluded.offered_price_per_kg,
                    status = 'pending', expires_at = excluded.expires_at,
                    responded_at = null, responded_by = null;

            update public.batches
            set status = 'offering', offering_at = now(), updated_at = now()
            where id = v_batch.id and status = 'published';

            insert into public.batch_events (batch_id, event_type, metadata, created_by)
            values (v_batch.id, 'broadcast_sent',
                jsonb_build_object('trigger', 'pool_activate_sweep', 'pool_id', v_pool_id),
                public.fn_current_user_id());

            v_offered := v_offered + 1;
        end if;
    end loop;

    update public.pool_requests
    set status = 'active', activated_at = now(), updated_at = now()
    where id = p_request_id;

    return jsonb_build_object(
        'request_id', p_request_id, 'pool_id', v_pool_id,
        'sweptMatched', v_matched, 'sweptOffered', v_offered
    );
end;
$$;
comment on function public.rpc_self_activate_pool_request(uuid) is
    'TSP-SLICE9-ROLLBACK-01 (2026-07-26, CEO): без дробления партии — Слайс 6 +
     DEFECT-B fix (2026-06-25). Слайс 9 (batch-split) отложен по продуктовому
     решению; версия с дроблением сохранена в 20260702160000, реактивация — новой
     миграцией. Заявка(draft)→Pool(filling), свип уже опубликованных партий целиком.';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from public, anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;


-- ── rpc_self_auto_match_batch — без дробления, целиком в одну строку пула ───────
create or replace function public.rpc_self_auto_match_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch     public.batches%rowtype;
    v_grade     text;
    v_vol       int;
    v_line      record;
    v_win_hours int;
    v_offers    int := 0;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;
    if v_batch.status <> 'published' then
        return jsonb_build_object('matched', false, 'reason', 'BATCH_NOT_AVAILABLE');
    end if;
    if v_batch.farmer_price_per_kg is null then
        return jsonb_build_object('matched', false, 'reason', 'NO_ASK');
    end if;

    v_grade := public.fn_tsp_batch_grade(p_batch_id);
    v_vol   := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;

    -- 1) Прямой авто-матч: высший бид >= ask, сорт=, окно, РЕГИОН, РАЙОН(жёсткий), ПОРОДА, ёмкость.
    select pl.id              as pl_id,
           pl.pool_id          as pool_id,
           pl.mpk_price_per_kg as bid,
           p.target_heads      as target_heads,
           p.matched_heads     as matched_heads
      into v_line
    from public.pool_lines pl
    join public.pools p          on p.id = pl.pool_id
    join public.pool_requests pr on pr.id = p.pool_request_id
    where p.status = 'filling'
      and pl.is_active = true
      and pl.mpk_price_per_kg >= v_batch.farmer_price_per_kg
      and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
      and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
      and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
      and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
      and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
      and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
    order by pl.mpk_price_per_kg desc, p.created_at asc
    limit 1
    for update;

    if found then
        update public.batches
        set status            = 'matched',
            pool_line_id      = v_line.pl_id,
            deal_price_per_kg = v_line.bid,
            matched_at        = now(),
            updated_at        = now()
        where id = v_batch.id;

        update public.pool_lines
        set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
        where id = v_line.pl_id;

        update public.pools
        set matched_heads = matched_heads + v_batch.heads, updated_at = now()
        where id = v_line.pool_id;

        if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
            -- ARS-695 (FR-012): + filled_at, аддитивно (см. пояснение выше).
            update public.pools
            set status = 'closed_filled', completed_at = now(),
                filled_at = coalesce(filled_at, now()),
                mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
            where id = v_line.pool_id and status = 'filling';
            if found then
                update public.batches b
                set status = 'confirmed', confirmed_at = now(), updated_at = now()
                from public.pool_lines pl
                where pl.pool_id = v_line.pool_id and b.pool_line_id = pl.id and b.status = 'matched';
            end if;
        end if;

        update public.offers set status = 'withdrawn', responded_at = now()
        where batch_id = v_batch.id and status = 'pending';

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch.id, 'matched',
            jsonb_build_object('pool_id', v_line.pool_id, 'pool_line_id', v_line.pl_id,
                               'via', 'auto_match', 'deal_price_per_kg', v_line.bid),
            public.fn_current_user_id());

        return jsonb_build_object(
            'matched', true, 'poolId', v_line.pool_id, 'poolLineId', v_line.pl_id,
            'matchedHeads', v_batch.heads, 'dealPrice', v_line.bid
        );
    end if;

    -- 2) Нет прямого матча → broadcast (сорт+РЕГИОН+РАЙОН+ПОРОДА+окно+ёмкость; цена игнор).
    select offer_window_hours into v_win_hours from public.tsp_config where is_active = true limit 1;
    v_win_hours := coalesce(v_win_hours, 24);

    with eligible_mpks as (
        select distinct p.organization_id as mpk_org_id
        from public.pool_lines pl
        join public.pools p          on p.id = pl.pool_id
        join public.pool_requests pr on pr.id = p.pool_request_id
        where p.status = 'filling'
          and pl.is_active = true
          and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
          and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
          and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
    ),
    upserted as (
        insert into public.offers (batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at)
        select v_batch.id, em.mpk_org_id, v_batch.farmer_price_per_kg, 'pending',
               now() + make_interval(hours => v_win_hours), now()
        from eligible_mpks em
        on conflict (batch_id, mpk_org_id) do update
            set offered_price_per_kg = excluded.offered_price_per_kg,
                status = 'pending', expires_at = excluded.expires_at,
                responded_at = null, responded_by = null
        returning batch_id
    )
    select count(*) into v_offers from upserted;

    if v_offers > 0 then
        update public.batches
        set status = 'offering', offering_at = now(), updated_at = now()
        where id = v_batch.id;

        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (v_batch.id, 'broadcast_sent',
            jsonb_build_object('trigger', 'auto_match', 'offers', v_offers),
            public.fn_current_user_id());

        return jsonb_build_object('matched', false, 'reason', 'BROADCAST', 'offers', v_offers);
    end if;

    return jsonb_build_object('matched', false, 'reason', 'NO_POOL');
end;
$$;
comment on function public.rpc_self_auto_match_batch(uuid) is
    'TSP-SLICE9-ROLLBACK-01 (2026-07-26, CEO): без дробления — матч партии целиком
     в одну строку пула (высший подходящий бид) либо broadcast. Слайс 9 отложен,
     версия с дроблением сохранена в 20260702160000.';
revoke execute on function public.rpc_self_auto_match_batch(uuid) from public, anon;
grant  execute on function public.rpc_self_auto_match_batch(uuid) to authenticated;


-- ── rpc_self_accept_offer — без дробления, принятие оффера целиком ──────────────
create or replace function public.rpc_self_accept_offer(p_offer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_offer public.offers%rowtype;
    v_batch public.batches%rowtype;
    v_grade text;
    v_vol   int;
    v_line  record;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_offer from public.offers where id = p_offer_id for update;
    if not found then raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_offer.mpk_org_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: offer belongs to another MPK' using errcode = 'P0001';
    end if;
    if v_offer.status <> 'pending' then
        raise exception 'INVALID_STATUS: offer is %', v_offer.status using errcode = 'P0003';
    end if;
    if v_offer.expires_at < now() then
        update public.offers set status = 'expired' where id = p_offer_id;
        raise exception 'OFFER_EXPIRED' using errcode = 'P0004';
    end if;

    select * into v_batch from public.batches where id = v_offer.batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0005'; end if;
    if v_batch.status <> 'offering' then
        raise exception 'INVALID_STATUS: batch is % (must be offering)', v_batch.status using errcode = 'P0006';
    end if;

    v_grade := public.fn_tsp_batch_grade(v_batch.id);
    v_vol   := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;

    -- лучшая строка МПК: бид >= offered ask, сорт/окно/РЕГИОН/РАЙОН(жёсткий)/ПОРОДА/ёмкость
    select pl.id as pl_id, pl.pool_id as pool_id, pl.mpk_price_per_kg as bid,
           p.target_heads as target_heads, p.matched_heads as matched_heads
      into v_line
    from public.pool_lines pl
    join public.pools p          on p.id = pl.pool_id
    join public.pool_requests pr on pr.id = p.pool_request_id
    where p.status = 'filling'
      and p.organization_id = v_offer.mpk_org_id
      and pl.is_active = true
      and pl.mpk_price_per_kg >= v_offer.offered_price_per_kg
      and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
      and public.fn_tsp_breed_match(pl.breed_label, public.fn_tsp_meta(v_batch.notes)->>'breed')
      and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
      and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
      and public.fn_tsp_region_match(pr.region_ids, pr.region_id, v_batch.region_id)
      and public.fn_tsp_district_match(pr.district_ids, v_batch.organization_id)
    order by pl.mpk_price_per_kg desc
    limit 1
    for update;
    if not found then
        raise exception 'NO_MATCHING_POOL_LINE: raise a pool line bid >= ask % first', v_offer.offered_price_per_kg
            using errcode = 'P0007';
    end if;

    update public.offers
    set status = 'accepted', responded_at = now(), responded_by = public.fn_current_user_id()
    where id = p_offer_id;
    update public.offers
    set status = 'withdrawn', responded_at = now()
    where batch_id = v_offer.batch_id and id <> p_offer_id and status = 'pending';

    update public.batches
    set status = 'matched', pool_line_id = v_line.pl_id, deal_price_per_kg = v_line.bid,
        matched_at = now(), updated_at = now()
    where id = v_batch.id;

    update public.pool_lines
    set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
    where id = v_line.pl_id;

    update public.pools
    set matched_heads = matched_heads + v_batch.heads, updated_at = now()
    where id = v_line.pool_id;

    if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
        -- ARS-695 (FR-012): + filled_at, аддитивно (см. пояснение выше).
        update public.pools set status = 'closed_filled', completed_at = now(),
            filled_at = coalesce(filled_at, now()),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
        where id = v_line.pool_id and status = 'filling';
        if found then
            update public.batches b
            set status = 'confirmed', confirmed_at = now(), updated_at = now()
            from public.pool_lines pl
            where pl.pool_id = v_line.pool_id and b.pool_line_id = pl.id and b.status = 'matched';
        end if;
    end if;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (v_batch.id, 'offer_accepted',
        jsonb_build_object('offer_id', p_offer_id, 'pool_id', v_line.pool_id,
                           'pool_line_id', v_line.pl_id, 'deal_price_per_kg', v_line.bid),
        public.fn_current_user_id());

    return jsonb_build_object('batchId', v_batch.id, 'poolId', v_line.pool_id,
                              'poolLineId', v_line.pl_id, 'dealPrice', v_line.bid);
end;
$$;
comment on function public.rpc_self_accept_offer(uuid) is
    'TSP-SLICE9-ROLLBACK-01 (2026-07-26, CEO): без дробления — принятие оффера
     закрывает партию целиком в одну строку пула МПК. Слайс 9 отложен, версия
     с дроблением сохранена в 20260702160000.';
revoke execute on function public.rpc_self_accept_offer(uuid) from public, anon;
grant  execute on function public.rpc_self_accept_offer(uuid) to authenticated;

-- ── 8. 20260914120000 ЦЕЛИКОМ (ядро ARS-695) ─────────────────────────────────
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
