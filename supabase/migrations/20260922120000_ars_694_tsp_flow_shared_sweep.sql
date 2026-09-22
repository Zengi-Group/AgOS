-- AgOS · ARS-694 · ОБЩЕЕ ТЕЛО ПРАВИЛ ЗАКУПОЧНОГО ФЛОУ + ГЛОБАЛЬНЫЕ ВХОДЫ ДЖОБА.
-- ============================================================================
-- Спек (G2 2026-09-22): Docs/AGOS-TSP-Scheduler-ARS-694.md
-- Закрывает: S-1 (FR-006, FR-007, FR-009, FR-011, FR-012, FR-014, M-007, M-008,
--            M-010, M-011, M-013) и S-2 (FR-008, FR-010, M-009, M-012).
-- Расписание (S-3, FR-001..FR-005) — в отдельной миграции 20260922130000.
--
-- ЗАЧЕМ. Четыре правила флоу исполняются только из открытого браузера: их зовёт
-- кабинет, каждый по СВОИМ организациям (fn_my_org_ids()). Судьба сделки зависит
-- от того, чья вкладка открыта. Слайс не меняет ни одного правила — он меняет
-- вызывающего: рядом с кабинетным свипом появляется джоб по всем организациям.
--
-- ЧТО ЗДЕСЬ. Тело каждого правила выносится в хелпер с ПАРАМЕТРОМ охвата (FR-006:
-- одно тело, не две копии предиката, P4):
--   fn_tsp_sweep_due_pools(p_org_ids, p_limit)    — закрытие по дедлайну + возврат
--                                                   по молчанию комбината (ARS-695)
--   fn_tsp_sweep_due_batches(p_org_ids, p_limit)  — истечение офферов + вход в точку
--                                                   решения по цене (ARS-760)
-- p_org_ids = null означает «все организации» и достижим ТОЛЬКО через глобальные
-- входы rpc_process_tsp_*, закрытые для anon/authenticated (FR-010). Кабинетные
-- rpc_self_* сохраняют сигнатуру и передают fn_my_org_ids() — охват как сегодня
-- (FR-018: ленивые вызовы остаются org-скоупными).
--
-- ДОМ КОДА — МИГРАЦИЯ, НЕ d02_tsp.sql. Живые тела обеих rpc_self_* лежат в
-- supabase/migrations/ (20260622120000:1534 и 20260921120000:70), а миграции
-- применяются ПОСЛЕ d-файлов и выигрывают. Делегация, положенная в d02_tsp.sql,
-- была бы молча затёрта первым же деплоем — это L-1 и долг
-- MIGRATION-COPY-OUTSIDE-CROSSCHECK-01. Прецедент ARS-695/ARS-731/ARS-760 тот же.
--
-- AUTH_REQUIRED ОСТАЁТСЯ В ОБЁРТКАХ (FR-009). В общее тело он НЕ переезжает: у
-- джоба нет пользователя, fn_current_user_id() пуст (d01_kernel.sql:1594), и
-- каждый прогон падал бы на первой строке. Вход джоба закрыт грантами, а не
-- предусловием: revoke from anon/authenticated + grant service_role (FR-010).
--
-- SKIP LOCKED — ИЗМЕНЕНИЕ МЕХАНИКИ, НЕ ПРАВИЛА (FR-008, правило CLAUDE.md
-- «use SKIP LOCKED», образец rpc_process_membership_renewals d13_billing.sql:893).
-- Сегодня свип заявок берёт строку простым FOR UPDATE и ЖДЁТ; под джобом это
-- означало бы прогон, висящий за кабинетной транзакцией. Занятая строка теперь
-- пропускается и достаётся следующему прогону — исход по строке не меняется
-- (её всё равно кто-то досчитает), меняется только момент. Записи в Spec Change
-- Log обеих спек-домов (ARS-695, ARS-760) идут этим же PR.
--
-- ПЕРЕЧТЕНИЕ СТАТУСА ПОД БЛОКИРОВКОЙ СОХРАНЕНО ДОСЛОВНО (FR-012, M-007): курсор
-- открыт по снапшоту, и пока мы ждали строку, оператор мог нажать кнопку. FOR
-- UPDATE сам по себе перепроверяет квалификацию, но требование говорит «механизм
-- наследуется буквально» — явная проверка остаётся.
--
-- ФОРМА ОТВЕТА rpc_self_* НЕ МЕНЯЕТСЯ (FR-011, P7, D-RPC-CONTRACT-SYNC-01).
-- Обёртка собирает ответ СВОИМ json_build_object, а не отдаёт jsonb хелпера
-- насквозь: снапшот CHECK 11 строит ключи из текста тела
-- (scripts/contract_snapshot.py:15), и сквозной возврат стёр бы обе строки из
-- contracts/rpc_return_keys.txt как REMOVED. Ключи payload событий при этом
-- уезжают в регион хелпера (fn_*, снапшотом не снимается) — это ИЗМЕРЕННОЕ
-- следствие выноса тела, форма ответа RPC им не затронута; см. Spec Change Log
-- спека ARS-694 и запись в DECISIONS_LOG этим же PR.
--
-- Зависимости: 20260622120000 (тело закрытия заявок), 20260921120000 (тело
-- ценового решения), d02_tsp.sql (fn_tsp_pool_settle_underfill, fn_tsp_pool_*).
-- Выкладка: python3 scripts/deploy.py --files supabase/migrations/20260922120000_ars_694_tsp_flow_shared_sweep.sql
-- ============================================================================


-- ── 1. fn_tsp_sweep_due_pools — общее тело правил заявок (ARS-695) ────────────
-- Охват строк — параметр (FR-007). Тело правила побайтно то же, что жило в
-- rpc_self_close_due_pools: порог из fn_tsp_pool_settle_underfill, дефолт
-- «вернуть» по молчанию комбината, подтранзакция на заявку (M-010).
create or replace function public.fn_tsp_sweep_due_pools(
    p_org_ids uuid[]  default null,
    p_limit   integer default null
)
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
    v_seen_due  int := 0;   -- строк ВЗЯТО первым циклом (для truncated, FR-008)
    v_seen_wait int := 0;   -- строк ВЗЯТО вторым циклом
    v_budget    int;        -- ОСТАТОК предела на прогон, общий для обоих циклов
    v_window    int;
    v_id        uuid;
    v_outcome   text;
    v_org       uuid;
begin
    -- FR-008: предел объёма принадлежит ПРОГОНУ, а не запросу. Ноль и отрицательное
    -- значение — ошибка вызывающего, а не «ничего не делать молча»: под limit 0 прогон
    -- отдал бы truncated=true, не тронув ни строки, и затор было бы не отличить от
    -- опечатки в расписании.
    if p_limit is not null and p_limit < 1 then
        raise exception 'INVALID_LIMIT: p_limit must be >= 1 (got %)', p_limit
            using errcode = 'P0001';
    end if;
    v_budget := p_limit;
    -- ARS-695 (FR-009): правило 30 % снято. Оно подменяло решение комбината: недобор
    -- ≥30 % принудительно засчитывался как «набрана» (анти-farmer-friendly, D-TSP-10
    -- нарушен — QA TSPM-CLOSE-03), а <30 % уходил в legacy 'closed', оставляя партии
    -- висеть matched на мёртвой заявке. Замена — порог из данных + точка выбора
    -- (fn_tsp_pool_settle_underfill).
    --
    -- ARS-694 (FR-007/FR-008): охват — параметр (null = все организации, доступно
    -- только глобальному входу); объём — p_limit (null = без предела, как у кабинета);
    -- занятые строки пропускаются, а не ждутся (skip locked).
    for v_id in
        select p.id
        from public.pools p
        join public.pool_requests pr on pr.id = p.pool_request_id
        where (p_org_ids is null or pr.organization_id = any (p_org_ids))
          and p.status = 'filling'
          and current_date >= (date_trunc('month', pr.target_month) + interval '1 month')::date
        order by p.id
        limit v_budget
        for update of p skip locked
    loop
        v_seen_due := v_seen_due + 1;
        -- Перечтение статуса ПОД блокировкой (M-007): пока мы брали строку, оператор
        -- мог нажать «Закрыть заявку» и заявка уже не в filling. Применить решение
        -- второй раз значило бы закрыть заявку дважды и разойтись со своим же
        -- INVALID_STATUS на кнопке.
        perform 1 from public.pools where id = v_id for update;
        if not exists (select 1 from public.pools where id = v_id and status = 'filling') then
            continue;
        end if;
        -- Каждая заявка обрабатывается в своей подтранзакции (M-010): settle_underfill
        -- умеет raise, и без изоляции ОДНА заявка с нераспознанным маршрутом откатывала
        -- бы весь прогон — у остальных отказал бы и авто-возврат, и вход в точку выбора.
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

    -- FR-007 (ARS-695): молчание комбината дольше окна решения = «вернуть» (D-M6-1,
    -- дефолт в пользу фермера). ARS-694: с джобом эта формулировка впервые получает
    -- буквальный смысл — «через 24 ч», а не «при первом заходе в кабинет».
    select mpk_decision_window_hours into v_window
    from public.tsp_config where is_active = true limit 1;
    v_window := coalesce(v_window, 24);

    -- Остаток предела ПРОГОНА: второй цикл не начинает счёт заново, иначе один прогон
    -- трогал бы до 2 × p_limit строк, и объявленная граница длины транзакции была бы
    -- вдвое меньше настоящей (находка ревью якоря 7).
    if p_limit is not null then
        v_budget := greatest(p_limit - v_seen_due, 0);
    end if;

    for v_id in
        select p.id
        from public.pools p
        join public.pool_requests pr on pr.id = p.pool_request_id
        where (p_org_ids is null or pr.organization_id = any (p_org_ids))
          and p.status = 'awaiting_mpk_decision'
          and p.awaiting_decision_at is not null
          and p.awaiting_decision_at + make_interval(hours => v_window) <= now()
        order by p.id
        limit v_budget
        for update of p skip locked
    loop
        v_seen_wait := v_seen_wait + 1;
        -- Та же гонка, что и в первом цикле: комбинат мог сам выбрать ход. Дефолт
        -- «вернуть» не должен перебивать состоявшееся решение оператора.
        perform 1 from public.pools where id = v_id for update;
        if not exists (
            select 1 from public.pools where id = v_id and status = 'awaiting_mpk_decision'
        ) then
            continue;
        end if;
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
            -- actor_id под джобом = null: fn_current_user_id() пуст, колонка нуллабельна
            -- («or null for system/cron», d01_kernel.sql:1249). Новых событий слайс не
            -- заводит (FR-016) — это существующее, и пишется оно как сегодня.
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

    -- closed = сумма терминально закрытых без набора (форма ARS-695, не меняется).
    -- truncated (FR-008): прогон выбрал предел ЦЕЛИКОМ (сумма обоих циклов) — значит
    -- созревшие строки могли остаться, и затор виден, а не молчалив. Остаток уходит в
    -- следующий прогон (M-012).
    v_closed := v_unfilled + v_empty;
    return jsonb_build_object(
        'filled',           v_filled,
        'closed',           v_closed,
        'awaitingDecision', v_awaiting,
        'unfilled',         v_unfilled,
        'expiredEmpty',     v_empty,
        'failed',           v_failed,
        'truncated',        (p_limit is not null and (v_seen_due + v_seen_wait) >= p_limit)
    );
end;
$$;
comment on function public.fn_tsp_sweep_due_pools(uuid[], integer) is
    'ARS-694 | Общее тело правил заявок (ARS-695): filling + месяц истёк → порог
     fn_tsp_pool_settle_underfill; awaiting_mpk_decision дольше окна → возврат партий.
     ВНУТРЕННИЙ хелпер: охват организаций — параметр (null = все, достижимо только из
     rpc_process_tsp_pool_closures), предел — p_limit (null = без предела, кабинет),
     занятые строки пропускаются (skip locked). AUTH_REQUIRED сюда НЕ переезжает
     (FR-009) — он живёт в обёртке rpc_self_close_due_pools.';
revoke execute on function public.fn_tsp_sweep_due_pools(uuid[], integer) from public;
revoke execute on function public.fn_tsp_sweep_due_pools(uuid[], integer) from anon, authenticated;


-- ── 2. fn_tsp_sweep_due_batches — общее тело правил партий (ARS-760) ──────────
-- Тело правила побайтно то же, что жило в rpc_self_review_due_batches: два
-- независимых шага, set-based (M-011 — счётчика failed у этой ветки нет и он не
-- вводится: отказ роняет оператор целиком, полу-записи не бывает).
create or replace function public.fn_tsp_sweep_due_batches(
    p_org_ids uuid[]  default null,
    p_limit   integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_moved   int := 0;
    v_expired int := 0;
    v_min     int;
    v_budget  int;    -- ОСТАТОК предела на прогон, общий для обоих шагов
begin
    -- FR-008: предел принадлежит прогону, а не оператору (см. близнеца выше).
    if p_limit is not null and p_limit < 1 then
        raise exception 'INVALID_LIMIT: p_limit must be >= 1 (got %)', p_limit
            using errcode = 'P0001';
    end if;
    v_budget := p_limit;

    -- FR-011 (ARS-760): значение порога не меняется и продолжает отдаваться в ответе.
    -- В предикат шага (б) оно НЕ входит — решают офферы, а не возраст.
    select coalesce(price_decision_after_minutes, 1) into v_min
    from public.tsp_config where is_active = true limit 1;
    v_min := coalesce(v_min, 1);

    -- ── Шаг (а) · FR-002 (ARS-760): оффер гаснет по своему собственному сроку ──
    -- Без статуса партии и без matched_heads (M-004 ARS-760): срок предложения
    -- принадлежит предложению. Чужие статусы accepted/rejected/withdrawn не трогаем
    -- (фильтр status = 'pending').
    -- ARS-694: охват — параметр; строки берутся под блокировку порцией p_limit,
    -- занятые пропускаются (FR-008). Предикат UPDATE сохранён дословно и лишь
    -- сужен по взятым строкам — правило не переписано (FR-014).
    with locked_offers as (
        select o.id
        from public.offers o
        join public.batches b on b.id = o.batch_id
        where (p_org_ids is null or b.organization_id = any (p_org_ids))
          and o.status     = 'pending'
          and o.expires_at < now()
        order by o.expires_at
        limit v_budget
        for update of o skip locked
    ),
    expired_now as (
        update public.offers o
        set status       = 'expired',
            responded_at = now()
        from public.batches b
        where o.batch_id = b.id
          and (p_org_ids is null or b.organization_id = any (p_org_ids))
          and o.status     = 'pending'
          and o.expires_at < now()
          and o.id in (select id from locked_offers)
        returning 1
    )
    select count(*) into v_expired from expired_now;

    -- Остаток предела ПРОГОНА (та же причина, что у близнеца по заявкам): шаг (б) не
    -- начинает счёт заново, иначе один прогон трогал бы до 2 × p_limit строк.
    if p_limit is not null then
        v_budget := greatest(p_limit - v_expired, 0);
    end if;

    -- ── Шаг (б) · FR-001 (ARS-760): в точку решения — только после отказа рынка ─
    -- Отдельный оператор, а не CTE шага (а): предикат ниже обязан ВИДЕТЬ офферы,
    -- погашенные шагом (а). В одном операторе они остались бы pending для снапшота.
    with cand as (
        select b.id
        from public.batches b
        where (p_org_ids is null or b.organization_id = any (p_org_ids))
          and b.status = 'offering'
          and coalesce(b.matched_heads, 0) = 0
          and exists (
              select 1 from public.offers o
              where o.batch_id   = b.id
                and o.status     = 'expired'
                and o.expires_at >= b.published_at
          )
          and not exists (
              select 1 from public.offers o
              where o.batch_id   = b.id
                and o.status     = 'pending'
                and o.expires_at >= b.published_at
          )
        order by b.id
        limit v_budget
        for update skip locked
    ),
    moved as (
        update public.batches b
        set status                     = 'awaiting_price_decision',
            awaiting_price_decision_at = now(),
            updated_at                 = now()
        where b.id in (select id from cand)
          and (p_org_ids is null or b.organization_id = any (p_org_ids))
          and b.status = 'offering'
          and coalesce(b.matched_heads, 0) = 0
          and exists (
              select 1 from public.offers o
              where o.batch_id   = b.id
                and o.status     = 'expired'
                and o.expires_at >= b.published_at
          )
          -- Член окна здесь СЕГОДНЯ ничего не исключает, и это сказано вслух (находка
          -- ревью якоря 7 ARS-760): шаг (а) выше уже погасил все pending с истёкшим
          -- сроком у партий того же охвата, поэтому у любой уцелевшей pending-строки
          -- expires_at > now() >= published_at (отложенная публикация живёт в отдельной
          -- колонке scheduled_publish_at, d02_tsp.sql:1169). Оставлен, потому что
          -- FR-001 формулирует ОБЕ половины предиката «в нынешнем выходе на рынок», и
          -- потому что он держит правило верным, если охват шага (а) когда-нибудь
          -- сузится. Убирать его — менять букву замороженного требования.
          and not exists (
              select 1 from public.offers o
              where o.batch_id   = b.id
                and o.status     = 'pending'
                and o.expires_at >= b.published_at
          )
        returning b.id
    ),
    ev as (
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        select m.id, 'price_decision_due',
               -- Значения metadata оставлены КАК БЫЛИ ('review_due', after_minutes):
               -- ни один FR/M не просит их менять. created_by под джобом = null
               -- (fn_current_user_id() пуст) — ровно то, что ждёт M-002 ARS-694.
               jsonb_build_object('trigger', 'review_due', 'after_minutes', v_min),
               public.fn_current_user_id()
        from moved m
        returning 1
    )
    select count(*) into v_moved from moved;

    return jsonb_build_object(
        'moved',         v_moved,
        'afterMinutes',  v_min,
        'offersExpired', v_expired,
        -- truncated (FR-008): прогон выбрал предел ЦЕЛИКОМ (сумма обоих шагов) →
        -- созревшие строки могли остаться, остаток уходит в следующий прогон (M-012).
        'truncated',     (p_limit is not null and (v_expired + v_moved) >= p_limit)
    );
end;
$$;
comment on function public.fn_tsp_sweep_due_batches(uuid[], integer) is
    'ARS-694 | Общее тело правил партий (ARS-760): (а) pending-офферы с истёкшим
     expires_at → expired; (б) партия offering, у которой среди офферов нынешнего
     выхода на рынок есть expired и нет pending → awaiting_price_decision + событие
     price_decision_due. ВНУТРЕННИЙ хелпер: охват — параметр (null = все организации),
     предел — p_limit, занятые строки пропускаются (skip locked). AUTH_REQUIRED живёт
     в обёртке rpc_self_review_due_batches (FR-009).';
revoke execute on function public.fn_tsp_sweep_due_batches(uuid[], integer) from public;
revoke execute on function public.fn_tsp_sweep_due_batches(uuid[], integer) from anon, authenticated;


-- ── 3. rpc_self_close_due_pools — кабинетная обёртка, сигнатура НЕ меняется ───
-- FR-011: форма ответа та же, собирается СВОИМ json_build_object. FR-018: охват
-- остаётся org-скоупным, предела нет (кабинет подметает свои заявки целиком).
create or replace function public.rpc_self_close_due_pools()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_res jsonb;
begin
    -- FR-009: предусловие живёт ЗДЕСЬ, а не в общем теле — у джоба пользователя нет.
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    v_res := public.fn_tsp_sweep_due_pools(public.fn_my_org_ids(), null);

    return jsonb_build_object(
        'filled',           (v_res->>'filled')::int,
        'closed',           (v_res->>'closed')::int,
        'awaitingDecision', (v_res->>'awaitingDecision')::int,
        'unfilled',         (v_res->>'unfilled')::int,
        'expiredEmpty',     (v_res->>'expiredEmpty')::int,
        'failed',           (v_res->>'failed')::int
    );
end;
$$;
comment on function public.rpc_self_close_due_pools() is
    'КАНОН d02 | Слайс 6 | ARS-695 | ARS-694 | Ленивое подметание просроченных заявок
     своих org (гейт fn_my_org_ids()). Тело правила — общее с джобом:
     fn_tsp_sweep_due_pools(fn_my_org_ids(), null). Форма ответа не меняется
     (filled/closed/awaitingDecision/unfilled/expiredEmpty/failed). Гарантию «без
     открытой вкладки» даёт джоб tsp-pool-closures, этот вызов — мгновенный отклик.';
revoke execute on function public.rpc_self_close_due_pools() from public, anon;
grant  execute on function public.rpc_self_close_due_pools() to authenticated;


-- ── 4. rpc_self_review_due_batches — кабинетная обёртка, сигнатура НЕ меняется ─
create or replace function public.rpc_self_review_due_batches()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_res jsonb;
begin
    -- FR-009: см. выше.
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    v_res := public.fn_tsp_sweep_due_batches(public.fn_my_org_ids(), null);

    return jsonb_build_object(
        'moved',         (v_res->>'moved')::int,
        'afterMinutes',  (v_res->>'afterMinutes')::int,
        'offersExpired', (v_res->>'offersExpired')::int
    );
end;
$$;
comment on function public.rpc_self_review_due_batches() is
    'КАНОН d02 | ARS-760 | ARS-694 | Продюсер ценового решения, зовётся из кабинета.
     Тело правила — общее с джобом: fn_tsp_sweep_due_batches(fn_my_org_ids(), null).
     Форма ответа не меняется (moved/afterMinutes/offersExpired). Гарантию «без
     открытой вкладки» даёт джоб tsp-batch-reviews.';
revoke execute on function public.rpc_self_review_due_batches() from public, anon;
grant  execute on function public.rpc_self_review_due_batches() to authenticated;


-- ── 5. rpc_process_tsp_pool_closures — глобальный вход джоба ──────────────────
-- FR-010: anon/authenticated закрыты, только service_role (и роль, под которой
-- заведён cron.schedule — в Supabase postgres, владелец функции). Иначе любой
-- вошедший пользователь подметал бы чужие организации, то есть получил бы запись
-- в чужие сделки (изоляция данных, ст. 171).
-- M-009: отказ идёт на уровне грантов СУБД, ни одной строки не тронуто.
create or replace function public.rpc_process_tsp_pool_closures(p_limit integer default 500)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_res jsonb;
begin
    v_res := public.fn_tsp_sweep_due_pools(null, p_limit);

    -- Ключи — тот же набор, что у org-скоупного близнеца, плюс truncated (FR-008).
    return jsonb_build_object(
        'filled',           (v_res->>'filled')::int,
        'closed',           (v_res->>'closed')::int,
        'awaitingDecision', (v_res->>'awaitingDecision')::int,
        'unfilled',         (v_res->>'unfilled')::int,
        'expiredEmpty',     (v_res->>'expiredEmpty')::int,
        'failed',           (v_res->>'failed')::int,
        'truncated',        (v_res->>'truncated')::boolean
    );
end;
$$;
comment on function public.rpc_process_tsp_pool_closures(integer) is
    'ARS-694 | Глобальный вход джоба tsp-pool-closures: то же тело правил заявок
     (fn_tsp_sweep_due_pools), но по ВСЕМ организациям и порцией p_limit со
     skip locked. Org-параметра нет сознательно (CHECK 5): охват здесь и есть
     «все», а принимать его от клиента — отдать право записи в чужие сделки.
     service_role only (FR-010).';
revoke execute on function public.rpc_process_tsp_pool_closures(integer) from public;
revoke execute on function public.rpc_process_tsp_pool_closures(integer) from anon, authenticated;
grant  execute on function public.rpc_process_tsp_pool_closures(integer) to service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_process_tsp_pool_closures', 'RPC-M4-16', null,
        'supabase/migrations/20260922120000_ars_694_tsp_flow_shared_sweep.sql',
        'ARS-694 планировщик: глобальный вход закрытия заявок (skip locked, p_limit); service_role only')
on conflict (sql_name) do nothing;


-- ── 6. rpc_process_tsp_batch_reviews — глобальный вход джоба ──────────────────
-- Счётчика failed у этой ветки НЕТ и он не вводится (M-011): тело set-based, отказ
-- роняет оператор целиком, прогон помечается неуспешным в cron.job_run_details и
-- повторяется следующим тиком. Заводить failed значило бы переписать правило (FR-014).
create or replace function public.rpc_process_tsp_batch_reviews(p_limit integer default 500)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_res jsonb;
begin
    v_res := public.fn_tsp_sweep_due_batches(null, p_limit);

    return jsonb_build_object(
        'moved',         (v_res->>'moved')::int,
        'afterMinutes',  (v_res->>'afterMinutes')::int,
        'offersExpired', (v_res->>'offersExpired')::int,
        'truncated',     (v_res->>'truncated')::boolean
    );
end;
$$;
comment on function public.rpc_process_tsp_batch_reviews(integer) is
    'ARS-694 | Глобальный вход джоба tsp-batch-reviews: то же тело правил партий
     (fn_tsp_sweep_due_batches), но по ВСЕМ организациям и порцией p_limit со
     skip locked. Org-параметра нет сознательно (CHECK 5). service_role only (FR-010).';
revoke execute on function public.rpc_process_tsp_batch_reviews(integer) from public;
revoke execute on function public.rpc_process_tsp_batch_reviews(integer) from anon, authenticated;
grant  execute on function public.rpc_process_tsp_batch_reviews(integer) to service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_process_tsp_batch_reviews', 'RPC-M4-17', null,
        'supabase/migrations/20260922120000_ars_694_tsp_flow_shared_sweep.sql',
        'ARS-694 планировщик: глобальный вход истечения офферов и точки решения по цене; service_role only')
on conflict (sql_name) do nothing;
