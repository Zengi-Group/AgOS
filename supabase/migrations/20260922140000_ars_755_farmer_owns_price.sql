-- AgOS · ARS-755 · «Цену назначает фермер, и записывается ровно она».
-- Слайс-спек: Docs/AGOS-TSP-FarmerOwnsPrice-ARS-755.md (G2 подписан 2026-09-22).
--
-- ДЕФЕКТ (воспроизведён на проде 21.09, партия c6ef90f8): фермер в точке решения
-- вводит 1600 при текущей 1500, экран подтверждает 1600 — в базу уходит 1400.
-- Корень: `least(v_new, v_current - v_step)` в rpc_lower_price. Любое значение выше
-- «текущая − шаг» схлопывается, подъём и сохранение цены механически невозможны.
-- Зажим не был решением: D-TSP-8 отдаёт понижение фермеру, а шаг называет подсказкой
-- ассоциации; D-M6-3 (MS6 §229) прямо оставляет «задать вручную (soft warning)» и
-- «оставить и ждать (→ published)». Потолка ручного ввода канон не вводил никогда —
-- это дрейф кода. Новое здесь ровно одно: ПОДЪЁМ цены (решение CEO 22.09).
--
-- ГДЕ ПИШЕМ И ПОЧЕМУ ЗДЕСЬ, А НЕ В d02_tsp.sql: живые тела rpc_lower_price и
-- fn_tsp_batch_json существуют ТОЛЬКО в supabase/migrations/ (TSP-адаптер ложится
-- поверх d-файлов, CLAUDE.md §SQL). Версия rpc_lower_batch_price в d02_tsp.sql —
-- Слайс-9-aware и на прод не выкладывалась (IMPL_DEBT DEBT-PROD-DRIFT-01, там же
-- guard «не гонять deploy.py --files d02_tsp.sql»). Прецедент — ARS-760
-- (20260921120000), выложен неделю назад ровно с этим обоснованием.
--
-- Зависимости: 20260702200000 (текущее тело rpc_lower_price), 20260921120000
-- (текущее тело rpc_lower_batch_price), 20260731074557 (текущее тело
-- fn_tsp_batch_json). Идемпотентно. Сигнатуры не трогаются (P7, FR-009).


-- ── 1. rpc_lower_price — записывается ровно названная цена ────────────────────
-- FR-001: ни шаг, ни пол, ни множитель цену не меняют. Единственная нормализация —
--         round() до целого ₸/кг и требование > 0. Снят `least(…, v_current − v_step)`;
--         снят и `greatest(v_new, 1)` — он тоже подменял названную цену (0 → 1), а
--         подмена ровно то, что слайс лечит. Вместо него — явный отказ INVALID_INPUT,
--         по образцу соседней rpc_lower_batch_price. Фронт до этого не доводит (M-005).
-- FR-006: цена не изменилась («Оставить цену и ждать») — партия ВОЗВРАЩАЕТСЯ на рынок
--         с той же ценой, событие returned_to_published (существующий словарь), живые
--         предложения НЕ гасятся (M-017): они по-прежнему честны, а действие, обещающее
--         «партия остаётся в продаже», не должно убивать живой интерес рынка.
-- FR-007: цена изменилась — все pending-предложения партии гаснут в withdrawn ДО записи
--         новой цены. Без этого FR-001 держался бы только на заявке: строка со старой
--         ценой остаётся принимаемой, и сделка уходит по цене, которую фермер отменил
--         (с разрешённым подъёмом знак дефекта переворачивается против фермера).
--         Ре-броадкаст делает существующий вызов rpc_self_auto_match_batch, который
--         кабинет зовёт сразу после смены цены (useBatches.ts) — он здесь не дублируется.
-- Имя функции и события `price_lowered` становятся неточными (функция больше не только
-- «lower»). Переименование запрещено (P7, FR-009) — неточность зарегистрирована в
-- IMPL_DEBT; batch_events фермеру не показывается, поэтому ложь внутренняя.
create or replace function public.rpc_lower_price(p_batch_id uuid, p_new_price numeric)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch   public.batches%rowtype;
    v_step    int;
    v_current int;
    v_new     int;
    v_changed boolean;
begin
    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN' using errcode = 'P0001';
    end if;
    if v_batch.status not in ('published', 'offering', 'awaiting_price_decision') then
        raise exception 'INVALID_STATUS: batch is % (must be published/offering/awaiting_price_decision)', v_batch.status
            using errcode = 'P0003';
    end if;

    -- Шаг остаётся подсказкой ассоциации (D-TSP-8) и живёт в журнале события.
    -- Ценой он больше не распоряжается.
    select coalesce(price_step_down_amount, 100) into v_step
    from public.tsp_config where is_active = true limit 1;
    v_step := coalesce(v_step, 100);

    v_current := coalesce(v_batch.farmer_price_per_kg,
                          public.fn_tsp_ref_price(v_batch.tsp_sku_id, v_batch.region_id));

    if p_new_price is null then
        raise exception 'INVALID_INPUT: p_new_price must be > 0' using errcode = 'P0001';
    end if;
    v_new := round(p_new_price)::int;
    if v_new <= 0 then
        raise exception 'INVALID_INPUT: p_new_price must be > 0' using errcode = 'P0001';
    end if;

    v_changed := (v_current is distinct from v_new);

    -- FR-007 — гасим ДО записи новой цены, и только при фактической смене.
    if v_changed then
        update public.offers
        set status       = 'withdrawn',
            responded_at = now()
        where batch_id = p_batch_id
          and status   = 'pending';
    end if;

    update public.batches
    set farmer_price_per_kg        = v_new,
        status                     = 'published',
        offering_at                = null,
        awaiting_price_decision_at = null,
        published_at               = now(),   -- рестарт таймера цикла (20260702200000)
        updated_at                 = now()
    where id = p_batch_id;

    if v_changed then
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (p_batch_id, 'price_lowered',
            jsonb_build_object('old_ask', v_current, 'new_ask', v_new, 'step', v_step),
            public.fn_current_user_id());
    else
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        values (p_batch_id, 'returned_to_published',
            jsonb_build_object('ask', v_new, 'reason', 'farmer_kept_price'),
            public.fn_current_user_id());
    end if;

    return true;
end;
$$;
comment on function public.rpc_lower_price(uuid, numeric) is
    'КАНОН d02 | Слайс C B4 | ARS-755 | Фермер НАЗНАЧАЕТ ask: записывается ровно названная
     цена — выше текущей, ниже или та же (зажим на current − step снят, FR-001). Смена цены
     гасит pending-офферы в withdrawn (FR-007); цена не изменилась — офферы живы, событие
     returned_to_published (FR-006). Партия → published (published_at=now() — рестарт таймера
     ценового решения) для ре-broadcast (фронт затем зовёт rpc_self_auto_match_batch).
     Гейт fn_my_org_ids(). Имя функции и событие price_lowered неточны с ARS-755 (IMPL_DEBT).';
-- ACL воспроизводится ровно как в 20260702200000:96-97 — преэкзистентный, слайс его не
-- трогает. Здесь НЕТ гранта service_role, хотя у соседки ниже он есть: сверка
-- замысел↔реальность (прогон 2) назвала такой грант `unrequested` — единственное
-- требование про права, FR-017, говорит только о rpc_lower_batch_price, а расширять доступ
-- к функции, которой AI-шлюз не пользуется (вызовов нет ни в ai_gateway/, ни где-либо ещё),
-- слайсу никто не поручал. Прав, которых не просили, в коде не остаётся.
revoke execute on function public.rpc_lower_price(uuid, numeric) from public, anon;
grant  execute on function public.rpc_lower_price(uuid, numeric) to authenticated;


-- ── 2. rpc_lower_batch_price — вторая дверь записи цены ───────────────────────
-- FR-016: пол снят и здесь. Функция достижима по HTTP (execute был выдан authenticated
--         И anon — зафиксировано миграцией ARS-760) и помечена [WEB][AI] в Dok 3, то есть
--         это настоящая вторая дверь, а не спящий код. Она клэмпала названную цену ВВЕРХ
--         к minimum_price: инвариант FR-001, верный на одной двери из двух, — не инвариант.
-- FR-017: у неё же отзываются лишние права — revoke execute from public, anon, по образцу
--         соседней rpc_lower_price. authenticated и service_role сохраняются: этого хватает
--         и вебу, и AI-шлюзу (P-AI-6 — шлюз ходит сервисным аккаунтом). Утечки данных нет
--         и сегодня (у анонима fn_my_org_ids() пуст, fn_is_admin() false, auth.role()='anon'),
--         но защита стоит в ОДИН слой ровно у функции, чьё тело слайс правит.
--         Замер перед правкой: вызовов rpc_lower_batch_price нет ни в ai_gateway/, ни в src/,
--         ни в consulting_engine/, ни в supabase/functions/ — обоснование ARS-760 «revoke
--         сломает AI-шлюз» опровергнуто. Закрывает долг SEC-CANON-RPC-ANON-EXECUTE-01.
-- ТЕЛО ВЗЯТО из 20260921120000 (= прод + строка published_at ARS-760), изменены ровно две
-- строки присваивания клэмпа. d02_tsp.sql намеренно не трогаем (DEBT-PROD-DRIFT-01).
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

    -- ARS-755 FR-016: пол снят и на ЭТОЙ двери. Записывается ровно названная цена —
    -- клэмп `greatest(…, v_floor)` подменял её вверх, а инвариант, верный на одной двери
    -- из двух, не инвариант (функция достижима по HTTP и помечена [WEB][AI] в Dok 3).
    -- v_floor по-прежнему читается выше — он остаётся ОРИЕНТИРОМ и едет в журнал события
    -- (floor_price_per_kg), а ценой не распоряжается. Ключ was_clamped сохранён ради формы
    -- ответа (CHECK 11 контракт-снапшот) и теперь всегда false.
    v_clamped     := p_new_price_per_kg;
    v_was_clamped := false;

    -- ARS-755 FR-007 на ВТОРОЙ двери. Ревью якоря 7: без этого инвариант FR-001 снова
    -- держится на одной двери из двух. Ре-броадкаст ниже делает upsert по ключу
    -- (batch_id, mpk_org_id) и воскрешает в pending только тех МПК, чей бид подходит под
    -- НОВУЮ цену; строка МПК, который под новую цену НЕ подходит, осталась бы pending со
    -- старой ценой — и сделка ушла бы по цене, которую фермер уже отменил. Гасим до записи
    -- цены и только при фактической смене (при неизменной — предложения честны, M-017).
    if v_clamped is distinct from v_batch.farmer_price_per_kg then
        update public.offers
        set status       = 'withdrawn',
            responded_at = now()
        where batch_id = p_batch_id
          and status   = 'pending';
    end if;

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
    'КАНОН M6 RPC-M6-05 | ARS-760 | ARS-755 | Фермер/AI НАЗНАЧАЕТ ask: записывается ровно
     названная цена (клэмп к полу снят, FR-016; пол остался ориентиром в журнале), партия →
     offering с ре-броадкастом. published_at = now() (ARS-760) — смена цены начинает НОВЫЙ
     круг торга. Права сужены до authenticated + service_role (FR-017).';

-- FR-017 · ACL. CREATE OR REPLACE сохраняет прежние гранты, поэтому revoke идёт ПОСЛЕ тела.
revoke execute on function public.rpc_lower_batch_price(uuid, uuid, int) from public, anon;
grant  execute on function public.rpc_lower_batch_price(uuid, uuid, int) to authenticated;
-- Грант service_role явный — его требует `M-018` («execute есть у authenticated и
-- service_role, нет у anon и PUBLIC»). На проде он уже выдан, но держаться право не должно
-- на том, что кто-то выдал его раньше: при накате на чистую базу функция создаётся с
-- дефолтным EXECUTE у PUBLIC, и строка revoke выше отняла бы доступ у шлюза (`P-AI-6`).
grant  execute on function public.rpc_lower_batch_price(uuid, uuid, int) to service_role;


-- ── 3. fn_tsp_batch_json — шаг подсказки доезжает до экрана ───────────────────
-- FR-005 / задача P-2: подсказка «Снизить и предложить снова» сохраняется (HS-2), но шаг
-- берётся из tsp_config.price_step_down_amount, а не из хардкода `cur − 100` на фронте
-- (P4 — один дом факта, P8 — справочные данные в таблице). Фолбэк живёт на сервере:
-- колонка объявлена `int not null default 100` (d02_tsp.sql), поэтому число всегда есть,
-- пока есть активная строка конфига; строки нет → ключ null → фронт подсказку не рисует
-- и своего числа не держит вовсе.
-- Аддитивный ключ в JSON партии; прецедент — ARS-695 (min_pool_heads с заявкой).
-- ⚠️ CHECK 11 ЭТОТ КЛЮЧ НЕ ВИДИТ: снапшот контрактов пропускает всё, что не начинается
-- с `rpc_` (scripts/contract_snapshot.py:83), а это `fn_`. Поэтому прибор ключа — не
-- снапшот, а прямое утверждение в tests/ars_755_farmer_owns_price_test.sql (§9):
-- `fn_tsp_batch_json(batch) ? 'priceStepDown'`. Без него пропажа ключа проходит мимо всех
-- зелёных приборов, а на экране фермера молча исчезает кнопка «Снизить и предложить снова».
-- ТЕЛО ВЗЯТО из 20260731074557 (текущее живое).
create or replace function public.fn_tsp_batch_json(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v jsonb;
begin
    select jsonb_build_object(
        'id',         b.id,
        'cat',        public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
        'grade',      public.fn_tsp_batch_grade(b.id),
        'breed',      coalesce(meta->>'breed', ''),
        'heads',      b.heads,
        'avgWeight',  b.avg_weight_kg,
        'age',        coalesce((meta->>'age')::int, 0),
        'fatness',    coalesce(meta->>'fatness', ''),
        'district',   coalesce(meta->>'district', coalesce(r.name_ru, '')),
        'price',      coalesce(b.farmer_price_per_kg, public.fn_tsp_ref_price(b.tsp_sku_id, b.region_id)),
        'dealPrice',  b.deal_price_per_kg,
        -- ARS-755 FR-005: шаг подсказки «снизить и предложить снова» едет к фермеру
        -- ИЗ НАСТРОЙКИ, а не хардкодом на фронте (P4/P8). Нет активной строки конфига
        -- → ключ null → экран подсказку не показывает (своего числа фронт не держит).
        'priceStepDown', coalesce((select c.price_step_down_amount
                                   from public.tsp_config c where c.is_active = true limit 1), 100),
        'matchedHeads',   coalesce(b.matched_heads, 0),
        'remainingHeads', greatest(b.heads - coalesce(b.matched_heads, 0), 0),
        'allocations', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'heads',        a.heads,
                       'price',        a.price_per_kg,
                       'status',       a.status,
                       'buyer',        case when pa.mpk_contact_revealed_at is not null then oa.legal_name else null end,
                       'buyerPhone',   case when pa.mpk_contact_revealed_at is not null then oa.phone     else null end,
                       'matchedAt',    a.matched_at,
                       'confirmedAt',  a.confirmed_at,
                       'dispatchedAt', a.dispatched_at,
                       'deliveredAt',  a.delivered_at
                   ) order by a.matched_at)
            from public.batch_allocations a
            join public.pools pa         on pa.id = a.pool_id
            join public.organizations oa on oa.id = pa.organization_id
            where a.batch_id = b.id and a.status <> 'cancelled'
        ), '[]'::jsonb),
        'buyer',      case when po.mpk_contact_revealed_at is not null then bo.legal_name else null end,
        'buyerPhone', case when po.mpk_contact_revealed_at is not null then bo.phone     else null end,
        'review',     case
            when coalesce(b.organization_id = any(public.fn_my_org_ids()), false) then
                coalesce(
                    canonical_review.review,
                    case
                        when jsonb_typeof(meta->'review') = 'object'
                         and (meta->'review'->>'r1') ~ '^[1-5]$'
                         and (meta->'review'->>'r2') ~ '^[1-5]$'
                            then meta->'review'
                    end
                )
        end,
        'state',      case
                          when b.status = 'draft' and coalesce(meta->>'scheduled','false') = 'true' then 'scheduled'
                          when b.status = 'draft'                   then 'draft'
                          when b.status = 'published'               then 'published'
                          when b.status = 'offering'                then 'offering'
                          when b.status = 'awaiting_price_decision' then 'decision'
                          when b.status = 'partially_matched'       then 'partial'
                          when b.status = 'matched'                 then 'matched'
                          when b.status = 'confirmed'               then 'confirmed'
                          when b.status = 'dispatched'              then 'dispatched'
                          when b.status = 'delivered'               then 'delivered'
                          when b.status in ('cancelled','failed','expired') then 'cancelled'
                          else b.status
                      end,
        'windowLabel',
            case when meta ? 'wf' and meta ? 'wt'
                 then to_char((meta->>'wf')::date, 'DD Mon') || ' — ' || to_char((meta->>'wt')::date, 'DD Mon')
                 else to_char(b.target_month, 'TMMonth YYYY') end,
        'publishAtLabel', null,
        'deadlineLabel', (
            select to_char(max(o.expires_at), 'DD Mon')
            from public.offers o
            where o.batch_id = b.id and o.status = 'pending'
        ),
        'createdAtIso',    b.created_at,
        'publishedAtIso',  b.published_at,
        'matchedAtIso',    b.matched_at,
        'confirmedAtIso',  b.confirmed_at,
        'dispatchedAtIso', b.dispatched_at,
        'deliveredAtIso',  b.delivered_at,
        'history',    jsonb_build_array(
            jsonb_build_object('t', 'Создана', 'd', to_char(b.created_at, 'DD Mon')),
            jsonb_build_object('t',
                case when b.status = 'draft' then 'Черновик'
                     when b.status in ('matched','partially_matched','confirmed','dispatched','delivered') then 'Подобран покупатель'
                     when b.status = 'cancelled' then 'Снята'
                     else 'Выставлена на продажу' end,
                'd', to_char(coalesce(b.published_at, b.created_at), 'DD Mon'))
        )
    )
    into v
    from public.batches b
    left join public.regions r        on r.id = b.region_id
    left join public.pool_lines pl    on pl.id = b.pool_line_id
    left join public.pools po         on po.id = pl.pool_id
    left join public.organizations bo on bo.id = po.organization_id
    cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
    left join lateral (
        select jsonb_build_object(
            'r1', dr.overall_score,
            'r2', score.score,
            'comment', coalesce(dr.comment, '')
        ) as review
        from public.deal_reviews dr
        left join lateral (
            select ds.score
            from public.deal_review_dimension_scores ds
            join public.review_dimensions d on d.id = ds.dimension_id
            where ds.deal_review_id = dr.id
              and d.code = 'weight_accuracy'
            limit 1
        ) score on true
        where dr.batch_id = b.id
          and dr.reviewer_org_id = b.organization_id
          and dr.reviewer_role = 'farmer'
        limit 1
    ) canonical_review on true
    where b.id = p_batch_id;

    return v;
end;
$$;

comment on function public.fn_tsp_batch_json(uuid) is
    'ARS-360 compatibility projection for the farmer Batch shape. review is canonical
     first (weight_accuracy), with a read-only valid-notes fallback only while legacy
     reconciliation remains. ARS-755: += priceStepDown (tsp_config.price_step_down_amount)
     — подсказка шага перестала быть хардкодом фронта. Direct client execution is
     intentionally forbidden.';

revoke execute on function public.fn_tsp_batch_json(uuid)
    from public, anon, authenticated, service_role;
