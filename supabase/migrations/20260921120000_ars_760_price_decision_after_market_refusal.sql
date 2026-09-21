-- AgOS · ARS-760 · В ТОЧКУ РЕШЕНИЯ ПО ЦЕНЕ — ТОЛЬКО ПОСЛЕ ОТКАЗА РЫНКА.
-- ============================================================================
-- Спек (G2 2026-09-21, переподписан после правки FR-001):
--   Docs/AGOS-TSP-PriceDecisionEntry-ARS-760.md
-- Предмет: тело public.rpc_self_review_due_batches(). Сигнатура НЕ меняется (P7),
-- новых функций, таблиц и колонок нет.
--
-- ЗАЧЕМ. Точка решения по цене задумана как ответ на отказ рынка (канон MS4-BT-09:
-- offering → awaiting_price_decision при «all Offers expired»). Задеплоенное тело
-- (20260702200000) спрашивало не про отказ, а про возраст: брало ЛЮБУЮ непроданную
-- партию на рынке старше N минут, включая ту, которой никто ничего не предлагал.
-- Замерено на проде: партия c6ef90f8 прошла 1700 → 1600 → 1500 → 1400 ₸/кг при НУЛЕ
-- офферов за всё время; партия f473d040 висит в точке решения со 2 июля, офферов ноль.
--
-- ЧТО МЕНЯЕТСЯ — два независимых шага вместо одного связанного:
--   (а) FR-002: оффер гаснет по СВОЕМУ сроку (pending + expires_at < now() → expired),
--       независимо от статуса партии и от того, сколько у неё продано голов. Охват
--       строк прежний — партии организаций вызывающего (fn_my_org_ids()), не шире:
--       SECURITY DEFINER, пишущий чужие строки, — отдельное решение, здесь не принятое.
--   (б) FR-001: в точку решения уходит партия в статусе offering, у которой среди
--       офферов НЫНЕШНЕГО выхода на рынок есть хотя бы один expired и нет ни одного
--       pending. Возраст партии из предиката убран целиком.
--
-- ПОЧЕМУ ОКНО МЕРИТСЯ expires_at, А НЕ created_at (правка FR-001 от 21.09, решение
-- владельца, Clarifications спека). У offers стоит unique (batch_id, mpk_org_id) —
-- одна строка на пару «партия ↔ комбинат» навсегда. Повторная рассылка не вставляет
-- новую строку, а переписывает старую, и created_at при этом НЕ трогается ни в одном
-- живом писателе: rpc_self_auto_match_batch (оба апсерта, 20260918120000:299 и :462),
-- rpc_retry_match_pool (d02_tsp.sql:3060), rpc_lower_batch_price (d02_tsp.sql:3656).
-- С окном по created_at оффер того же комбината в новом круге оставался бы «старше»
-- нового published_at, то есть вне окна, — и канонический путь BT-09 умер бы для всех
-- повторных кругов (M-012). expires_at апсерт обновляет всегда. M-011 при этом
-- сохраняется: у прежнего expired-оффера expires_at лежит в прошлом, то есть раньше
-- нового published_at, который rpc_lower_price ставит в now().
-- Долг, из которого растёт эта оговорка, заведён отдельно: IMPL_DEBT.md
-- TSP-OFFER-SLOT-NO-HISTORY-01 (история торга по партии не сохраняется вовсе).
--
-- published_at = NULL. Тогда окно пусто и партия НЕ двигается — направление безопасное
-- (FR-003: партия остаётся продаваться). Проверено, что состояние недостижимо: статус
-- offering ставится только после броадкаста, броадкаст идёт по published-партиям, а
-- published_at заполняется при публикации (20260622120000:350) и при снижении цены;
-- пути возврата на рынок (d02_tsp.sql:4260, :4481, :4594, :6253, :6693, :6890) статус
-- переписывают, но партия к тому моменту уже была опубликована.
--
-- matched_heads = 0 СОХРАНЁН сознательно. FR-001 говорит «только из offering и только
-- если рынок отказал» — это необходимые условия, а не исчерпывающие. Сегодняшнее тело
-- частично проданную партию в точку решения не пускает; снятие этого гейта было бы
-- расширением поведения, которого никто не просил. Убран из предиката ровно один член
-- — возраст.
--
-- Идемпотентность и параллельные прогоны (FR-015, M-013): свип зовётся из каждой
-- открытой вкладки раз в 20 с. Второй прогон по той же партии не создаёт второго
-- события price_decision_due — UPDATE несёт собственный гейт b.status = 'offering', и
-- при конкурентном прогоне повторная проверка условия по обновлённой строке его
-- отбрасывает, поэтому RETURNING такую строку не отдаёт и вставки события не будет.
--
-- ОТВЕТ: к moved/afterMinutes добавлен аддитивный ключ offersExpired (P7). Ключ
-- afterMinutes сохранён (FR-008/FR-011): значение порога не меняется, но в предикат
-- FR-001 оно больше не входит — порог остаётся сроком рассылки офферов. Миграция
-- регистрируется в SQL_FILES (cross_check.sh), поэтому снапшот контрактов по этой
-- функции перегенерируется — запись в DECISIONS_LOG идёт тем же PR (D-RPC-CONTRACT-SYNC-01).
--
-- Зависимость: 20260702200000 (текущее тело), 20260622120000 (rpc_lower_price).
-- Выкладка: python3 scripts/deploy.py --files supabase/migrations/20260921120000_ars_760_price_decision_after_market_refusal.sql
-- Разовый ремонт застрявших партий идёт ПОСЛЕ этой миграции:
--   scripts/deploy/repair_ars760_stuck_price_decision.sql
-- ============================================================================


create or replace function public.rpc_self_review_due_batches()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_moved   int := 0;
    v_expired int := 0;
    v_min     int;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    -- FR-011: значение порога не меняется и продолжает отдаваться в ответе (FR-008).
    -- В предикат шага (б) оно НЕ входит — решают офферы, а не возраст.
    select coalesce(price_decision_after_minutes, 1) into v_min
    from public.tsp_config where is_active = true limit 1;
    v_min := coalesce(v_min, 1);

    -- ── Шаг (а) · FR-002: оффер гаснет по своему собственному сроку ───────────
    -- Без статуса партии и без matched_heads (M-004): срок предложения принадлежит
    -- предложению. Гейт по организации — как сегодня (M-006: чужие статусы
    -- accepted/rejected/withdrawn не трогаем, фильтр status = 'pending').
    with expired_now as (
        update public.offers o
        set status       = 'expired',
            responded_at = now()
        from public.batches b
        where o.batch_id = b.id
          and b.organization_id = any (public.fn_my_org_ids())
          and o.status     = 'pending'
          and o.expires_at < now()
        returning 1
    )
    select count(*) into v_expired from expired_now;

    -- ── Шаг (б) · FR-001: в точку решения — только после отказа рынка ─────────
    -- Отдельный оператор, а не CTE шага (а): предикат ниже обязан ВИДЕТЬ офферы,
    -- погашенные шагом (а). В одном операторе они остались бы pending для снапшота.
    with moved as (
        update public.batches b
        set status                     = 'awaiting_price_decision',
            awaiting_price_decision_at = now(),
            updated_at                 = now()
        where b.organization_id = any (public.fn_my_org_ids())
          and b.status = 'offering'
          and coalesce(b.matched_heads, 0) = 0
          and exists (
              select 1 from public.offers o
              where o.batch_id   = b.id
                and o.status     = 'expired'
                and o.expires_at >= b.published_at
          )
          -- Член окна здесь СЕГОДНЯ ничего не исключает, и это сказано вслух (находка
          -- ревью якоря 7): шаг (а) выше уже погасил все pending с истёкшим сроком у
          -- партий тех же организаций, поэтому у любой уцелевшей pending-строки
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
               -- ни один FR/M не просит их менять, Design contract говорит «существующий
               -- price_decision_due пишется как сегодня», а читателей у этих ключей нет.
               -- Смена значения на более правдивое — отдельное решение владельца.
               jsonb_build_object('trigger', 'review_due', 'after_minutes', v_min),
               public.fn_current_user_id()
        from moved m
        returning 1
    )
    select count(*) into v_moved from moved;

    return jsonb_build_object(
        'moved',         v_moved,
        'afterMinutes',  v_min,
        'offersExpired', v_expired
    );
end;
$$;

comment on function public.rpc_self_review_due_batches() is
    'КАНОН d02 | ARS-760 | Продюсер ценового решения (нет pg_cron, зовётся из кабинета).
     Два шага: (а) FR-002 — pending-офферы с истёкшим expires_at → expired, без оглядки
     на статус партии; (б) FR-001 — партия offering, у которой среди офферов НЫНЕШНЕГО
     выхода на рынок (offers.expires_at >= batches.published_at) есть expired и нет
     pending → awaiting_price_decision. Возраст партии из предиката убран (был до
     ARS-760): партию, которой никто не делал предложений, никто и не уценивает.
     price_decision_after_minutes остаётся сроком РАССЫЛКИ офферов и отдаётся в ответе.
     Гейт fn_my_org_ids().';

revoke execute on function public.rpc_self_review_due_batches() from public, anon;
grant  execute on function public.rpc_self_review_due_batches() to authenticated;


-- ── 3. rpc_lower_batch_price — второй путь снижения цены начинает НОВЫЙ круг ──
-- Найдено ревью якоря 7 и подтверждено на живом проде: кроме адаптерного
-- rpc_lower_price (его зовёт кабинет) задеплоен канонический rpc_lower_batch_price,
-- и он ставит партии status='offering' БЕЗУСЛОВНО, а published_at не трогает вовсе.
-- Значит круг торга для неё не начинается заново: протухшие офферы прошлого круга
-- остаются внутри окна FR-001, и если при снижении цены ни один МПК не подошёл
-- (ре-броадкаст дал ноль строк), первый же прогон свипа уводит партию обратно в точку
-- решения — не показав рынку новую цену ни секунды. Это ровно тот храповик, ради
-- которого написан слайс, только через вторую дверь. Функция достижима по HTTP
-- (execute выдан authenticated и anon) и помечена [WEB][AI] в Dok 3.
--
-- ПРАВКА — ОДНА СТРОКА, аддитивно (P7): published_at = now() в том же UPDATE, что уже
-- ставит offering_at. Ровно то, что с 20260702200000 делает rpc_lower_price.
--
-- ТЕЛО ВЗЯТО С ПРОДА (pg_get_functiondef), а НЕ из d02_tsp.sql. Версия в d02 —
-- Слайс-9-aware и на прод не выкладывалась (IMPL_DEBT DEBT-PROD-DRIFT-01, там же
-- guard «не гонять deploy.py --files d02_tsp.sql»); выложить её отсюда значило бы
-- протащить дробление партий под видом однострочной правки. Сверка: в живом теле
-- published_at не встречался ни разу, якорь offering_at единственный.
-- Права НЕ трогаем: CREATE OR REPLACE сохраняет ACL, а сужение доступа к канонической
-- RPC — отдельное решение (вынесено в IMPL_DEBT, не в этот слайс).

-- Заголовок приведён к стилю репозитория (нижний регистр): pg_get_functiondef отдаёт
-- его заглавными, и CHECK 7 cross_check.sh такую форму имени не узнаёт. Тело ниже —
-- побайтно с прода, кроме одной добавленной строки published_at.
create or replace function public.rpc_lower_batch_price(p_organization_id uuid, p_batch_id uuid, p_new_price_per_kg integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_batch                 record;
    v_floor                 int;
    v_clamped               int;
    v_was_clamped           boolean := false;
    v_offer_window_hours    int;
    v_mpk_count             int := 0;
begin
    -- OWNERSHIP GUARD (SEC-RPC-ORGTRUST-01, data-isolation/Art.171): SECURITY DEFINER
    -- bypasses RLS — p_organization_id is client-supplied and must be verified against
    -- the caller, not trusted as given. service_role bypasses (Dok3 registry lists this
    -- as an AI-Gateway-capable RPC, per P-AI-2 org-scoping happens before the call).
    if not (
        p_organization_id = any(public.fn_my_org_ids())
        or public.fn_is_admin()
        or auth.role() = 'service_role'
    ) then
        raise exception 'FORBIDDEN: caller does not belong to organization %', p_organization_id
            using errcode = 'P0001';
    end if;

    if p_new_price_per_kg is null or p_new_price_per_kg <= 0 then
        raise exception 'INVALID_INPUT: p_new_price_per_kg must be > 0'
            using errcode = 'P0001';
    end if;

    select * into v_batch
    from public.batches
    where id = p_batch_id and organization_id = p_organization_id
    for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_batch.status != 'awaiting_price_decision' then
        raise exception
            'INVALID_STATUS: can lower price only from awaiting_price_decision (current %)',
            v_batch.status using errcode = 'P0001';
    end if;

    -- D-M6-3 floor clamp — enabled via D-TSP-CATEGORY-BRIDGE (A2, 2026-06-15).
    -- Resolution: batch.tsp_sku_id → tsp_sku_category_map → minimum_prices.
    -- Region match: exact rayon wins; national (region_id IS NULL) fallback.
    -- When the bridge is empty for this SKU OR no minimum_prices row matches,
    -- v_floor stays NULL → clamp is no-op (graceful degradation).
    select mp.price_per_kg
      into v_floor
    from public.tsp_sku_category_map m
    join public.minimum_prices mp on mp.category_id = m.category_id
    where m.tsp_sku_id = v_batch.tsp_sku_id
      and m.is_active  = true
      and mp.is_active = true
      and (mp.region_id = v_batch.region_id or mp.region_id is null)
      and (mp.valid_to is null or mp.valid_to >= current_date)
    order by (mp.region_id = v_batch.region_id) desc nulls last,
             mp.valid_from desc
    limit 1;

    v_clamped     := greatest(p_new_price_per_kg, coalesce(v_floor, p_new_price_per_kg));
    v_was_clamped := (v_floor is not null and p_new_price_per_kg < v_floor);

    -- Move batch -> offering with new price
    update public.batches
    set farmer_price_per_kg = v_clamped,
        status              = 'offering',
        offering_at         = now(),
        published_at        = now(),   -- ARS-760: новый круг окна FR-001
        updated_at          = now()
    where id = p_batch_id;

    -- Offer window from tsp_config
    select offer_window_hours into v_offer_window_hours
    from public.tsp_config where is_active = true limit 1;
    v_offer_window_hours := coalesce(v_offer_window_hours, 24);

    -- Re-broadcast: upsert offers for MPK with matching active filling pools.
    -- Capacity predicate mirrors rpc_accept_offer (line + batch volume <= max);
    -- a 1-kg gap on a line should NOT trigger an offer for a multi-tonne batch.
    with matching_mpks as (
        -- DEF-TSP-M4-OWNERSHIP (resolved): owner comes from pools.organization_id.
        select distinct p.organization_id as mpk_org_id
        from public.pools p
        join public.pool_lines pl    on pl.pool_id = p.id and pl.is_active = true
        where p.status = 'filling'
          and p.organization_id is not null
          and pl.mpk_price_per_kg >= v_clamped
          and (pl.tsp_sku_id is null or pl.tsp_sku_id = v_batch.tsp_sku_id)
          and (pl.max_volume_kg is null
               or pl.current_volume_kg
                  + coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int
                  <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null
               or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null
               or p.delivery_to   >= v_batch.ready_from)
          and exists (
              select 1 from public.pool_regions pgr
              where pgr.pool_id = p.id
                and (
                    (pgr.region_type = 'rayon'
                        and pgr.region_id = v_batch.region_id)
                    or (pgr.region_type = 'oblast' and (
                        pgr.region_id = v_batch.region_id
                        or pgr.region_id = (
                            select parent_id from public.regions
                            where id = v_batch.region_id
                        )
                    ))
                )
          )
    ),
    upserted as (
        insert into public.offers (
            batch_id, mpk_org_id, offered_price_per_kg, status, expires_at, created_at
        )
        select p_batch_id, mm.mpk_org_id, v_clamped, 'pending',
               now() + make_interval(hours => v_offer_window_hours), now()
        from matching_mpks mm
        on conflict (batch_id, mpk_org_id) do update
            set offered_price_per_kg = excluded.offered_price_per_kg,
                status               = 'pending',
                expires_at           = excluded.expires_at,
                responded_at         = null,
                responded_by         = null
        returning id as offer_id, mpk_org_id, offered_price_per_kg, expires_at
    ),
    -- TSP-FLOW-06: emit market.offer.created per re-broadcast offer (Dok4 §3.3a)
    -- so the push/notification path (offer_created_mpk, Dok4 §7) can fire. Recipient
    -- org = each matching MPK (per-row, P-AI-2). System actor (broadcast, no user).
    -- Additive: existing market.batch.price_lowered event below is untouched.
    ev_offer_created as (
        insert into public.platform_events (
            event_type, entity_type, entity_id, organization_id,
            actor_type, actor_id, payload, is_audit
        )
        select 'market.offer.created', 'offers', u.offer_id, u.mpk_org_id,
               'system', null,
               jsonb_build_object(
                   'offer_id', u.offer_id,
                   'batch_id', p_batch_id,
                   'mpk_org_id', u.mpk_org_id,
                   'offered_price_per_kg', u.offered_price_per_kg,
                   'expires_at', u.expires_at
               ),
               false
        from upserted u
        returning id as event_id, organization_id as org_id, payload
    ),
    -- Slice-4 dispatcher (Dok4 §6.1 transactional): fan each just-emitted event
    -- out to notifications for EVERY active user of the recipient MPK org, on each
    -- channel enabled in user_notification_preferences (absent row = enabled).
    -- template=offer_created_mpk (Dok4 §7: in_app + push); payload already carries
    -- offered_price_per_kg + expires_at (the template's placeholders). Recipient
    -- resolution via user_organization_roles (users have no org FK, D5). org_id
    -- here is per-row (each matching MPK, from the event's organization_id).
    notif_offer_created as (
        insert into public.notifications (
            user_id, organization_id, channel, template_id, params,
            platform_event_id, delivery_status
        )
        select uor.user_id, e.org_id, ch.channel, 'offer_created_mpk', e.payload,
               e.event_id, 'pending'
        from ev_offer_created e
        join public.user_organization_roles uor
            on uor.organization_id = e.org_id
        join public.users usr
            on usr.id = uor.user_id and usr.is_active = true
        cross join unnest(array['in_app','push']) as ch(channel)
        left join public.user_notification_preferences pref
            on pref.user_id = uor.user_id and pref.channel = ch.channel
        where coalesce(pref.is_enabled, true) = true
    )
    select count(*) into v_mpk_count from upserted;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'price_lowered',
        jsonb_build_object(
            'requested_price_per_kg', p_new_price_per_kg,
            'old_price_per_kg', v_batch.farmer_price_per_kg,
            'new_price_per_kg', v_clamped,
            'was_clamped', v_was_clamped,
            'floor_price_per_kg', v_floor,
            'broadcast_mpk_count', v_mpk_count
        ),
        public.fn_current_user_id());

    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'market.batch.price_lowered', 'batches', p_batch_id, p_organization_id,
        'farmer', public.fn_current_user_id(),
        jsonb_build_object(
            'batch_id', p_batch_id,
            'new_price', v_clamped,
            'was_clamped', v_was_clamped,
            'broadcast_mpk_count', v_mpk_count
        ),
        true
    );

    return jsonb_build_object(
        'new_price', v_clamped,
        'was_clamped', v_was_clamped,
        'broadcast_mpk_count', v_mpk_count
    );
end; $function$
;

comment on function public.rpc_lower_batch_price(uuid, uuid, int) is
    'КАНОН M6 RPC-M6-05 | ARS-760 | Фермер/AI снижает ask: clamp к полу, партия → offering
     с ре-броадкастом. published_at = now() (добавлено ARS-760) — снижение цены начинает
     НОВЫЙ круг торга, поэтому протухшие офферы прошлого круга не попадают в окно
     FR-001 и не читаются как отказ от новой цены.';
