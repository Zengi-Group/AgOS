-- AgOS | TSP | РЕДЕПЛОЙ Defect A + Defect B + grade-показ (2026-06-25).
-- Идемпотентные create or replace — безопасно применять на прод повторно.
-- Источник правок: 20260622120000_tsp_canonical_rebind.sql.

-- == 1/4 fn_tsp_region_id (Defect A: нормализация района) ==
create or replace function public.fn_tsp_region_id(p_district text)
returns uuid
language plpgsql
stable
as $$
declare
    v_id uuid;
    v_in text;
begin
    if p_district is null or trim(p_district) = '' then
        return null;
    end if;
    -- Нормализация (DEFECT-A): срезаем типовые токены формата — «район», «город»,
    -- «г.», «область», «обл.» — и схлопываем пробелы. Визард шлёт «Сайрамский район»
    -- / «Туркестанская область»; приводим к ядру названия, чтобы матчить
    -- regions.name_ru независимо от суффикса. Без активных rayon-строк район всё
    -- равно не зарезолвится — вызывающий дофолбэчит на область org (rpc_create_batch).
    v_in := lower(trim(p_district));
    v_in := regexp_replace(v_in, '\m(район|города|город|г\.|область|обл\.)\M', '', 'g');
    v_in := trim(regexp_replace(v_in, '\s+', ' ', 'g'));
    if v_in = '' then
        return null;
    end if;
    select r.id into v_id
    from public.regions r
    where r.is_active = true
      and (
            lower(r.name_ru) = v_in
         or v_in like '%' || lower(r.name_ru) || '%'
         or lower(r.name_ru) like '%' || v_in || '%'
      )
    order by r.level desc   -- rayon специфичнее oblast (когда строки засеяны)
    limit 1;
    return v_id;   -- null → национальная (region_id is null) цена в price_grids
end;
$$;

-- == 2/4 rpc_create_batch (Defect A: фолбэк на область организации) ==
create or replace function public.rpc_create_batch(
    p_cat         text,
    p_breed       text,
    p_heads       int,
    p_avg_weight  numeric,
    p_age         int,
    p_fatness     text,
    p_district    text,
    p_price       numeric,          -- ask фермера (пол) → batches.farmer_price_per_kg (D-TSP-MATCH-01)
    p_window_from date,
    p_window_to   date,
    p_scheduled   boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_org_id    uuid;
    v_sku_id    uuid;
    v_grade_id  uuid;
    v_region_id uuid;
    v_batch_id  uuid;
    v_status    text;
    v_notes     text;
begin
    v_org_id := (public.fn_my_org_ids())[1];
    if v_org_id is null then
        raise exception 'ORG_NOT_FOUND' using errcode = 'P0001';
    end if;

    v_sku_id    := public.fn_tsp_resolve_sku(p_cat, p_breed, p_age, p_avg_weight);
    v_region_id := public.fn_tsp_region_id(p_district);
    -- DEFECT-A fix (2026-06-25): район (свободный текст визарда) не резолвится в
    -- regions — в схеме нет активных rayon-строк, name-only резолв даёт null, и
    -- ВСЕ партии получали region_id=null (ломая регион-таргетинг канон-пулов).
    -- Фолбэк: область организации фермера (выбрана при регистрации). Гарантирует
    -- region_id уровня области — та гранулярность, на которой таргетируют пулы МПК.
    -- (Rayon-точность — будущее: засев rayon-строк в public.regions + parent_id.)
    if v_region_id is null then
        select region_id into v_region_id from public.organizations where id = v_org_id;
    end if;
    select grade_id into v_grade_id from public.tsp_skus where id = v_sku_id;

    -- scheduled → draft (не на витрине; нет планировщика на бете); иначе published.
    v_status := case when p_scheduled then 'draft' else 'published' end;

    -- D-M6-6: окно готовности валидно (ready_to >= ready_from).
    if p_window_from is not null and p_window_to is not null and p_window_to < p_window_from then
        raise exception 'INVALID_WINDOW: ready_to before ready_from' using errcode = 'P0001';
    end if;

    v_notes := jsonb_build_object(
        'cat',       p_cat,
        'breed',     p_breed,
        'age',       p_age,
        'fatness',   p_fatness,
        'district',  p_district,
        'wf',        to_char(p_window_from, 'YYYY-MM-DD'),
        'wt',        to_char(p_window_to,   'YYYY-MM-DD'),
        'scheduled', coalesce(p_scheduled, false)
    )::text;

    insert into public.batches (
        organization_id, tsp_sku_id, grade_standard_id, breed_id,
        heads, avg_weight_kg, target_month, region_id,
        farmer_price_per_kg, ready_from, ready_to,
        status, notes, published_at, created_by, created_at
    ) values (
        v_org_id, v_sku_id, v_grade_id, null,
        p_heads, p_avg_weight, date_trunc('month', p_window_from)::date, v_region_id,
        case when p_price is not null and p_price > 0 then round(p_price)::int else null end,
        p_window_from, p_window_to,
        v_status, v_notes,
        case when v_status = 'published' then now() else null end,
        public.fn_current_user_id(), now()
    )
    returning id into v_batch_id;

    return public.fn_tsp_batch_json(v_batch_id);
end;
$$;

comment on function public.rpc_create_batch(text, text, int, numeric, int, text, text, numeric, date, date, boolean) is
    'КАНОН d02 | Конвергенция Слайс B | Адаптер визарда: резолвит tsp_sku_id/region_id/target_month;
     p_price → farmer_price_per_kg (ask=пол, D-TSP-MATCH-01); окно → ready_from/ready_to (D-M6-6);
     поля визарда дублируются в notes(JSON) для совместимости UI. published|draft.
     deal = высший бид МПК ≥ ask; price_grids остаётся индикативным ориентиром.';

revoke execute on function public.rpc_create_batch(text, text, int, numeric, int, text, text, numeric, date, date, boolean) from anon;
grant  execute on function public.rpc_create_batch(text, text, int, numeric, int, text, text, numeric, date, date, boolean) to authenticated;

-- == 3/4 fn_tsp_batch_json (поле grade — показ сорта фермеру) ==
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
        -- Сорт партии (VS/S/NS) — тот же, по которому матчится закупка МПК
        -- (fn_tsp_grade_for_mpk_key). Фронт показывает его фермеру для паритета
        -- с логикой покупки. null = сорт ещё не присвоен (нет SKU/grade).
        'grade',      public.fn_tsp_batch_grade(b.id),
        'breed',      coalesce(meta->>'breed', ''),
        'heads',      b.heads,
        'avgWeight',  b.avg_weight_kg,
        'age',        coalesce((meta->>'age')::int, 0),
        'fatness',    coalesce(meta->>'fatness', ''),
        'district',   coalesce(meta->>'district', coalesce(r.name_ru, '')),
        'price',      coalesce(b.farmer_price_per_kg, public.fn_tsp_ref_price(b.tsp_sku_id, b.region_id)),
        'dealPrice',  b.deal_price_per_kg,
        -- Раскрытие покупателя фермеру при confirmed (D-M6-5): личность МПК видна
        -- только после mpk_contact_revealed_at пула партии.
        'buyer',      case when po.mpk_contact_revealed_at is not null then bo.legal_name else null end,
        'buyerPhone', case when po.mpk_contact_revealed_at is not null then bo.phone     else null end,
        'state',      case
                          when b.status = 'draft' and coalesce(meta->>'scheduled','false') = 'true' then 'scheduled'
                          when b.status = 'draft'                  then 'draft'
                          when b.status = 'published'              then 'published'
                          when b.status = 'offering'               then 'offering'
                          when b.status = 'awaiting_price_decision' then 'decision'
                          when b.status = 'matched'                then 'matched'
                          when b.status = 'confirmed'              then 'confirmed'
                          when b.status = 'dispatched'             then 'dispatched'
                          when b.status = 'delivered'              then 'delivered'
                          when b.status in ('cancelled','failed','expired') then 'cancelled'
                          else b.status
                      end,
        'windowLabel',
            case when meta ? 'wf' and meta ? 'wt'
                 then to_char((meta->>'wf')::date, 'DD Mon') || ' — ' || to_char((meta->>'wt')::date, 'DD Mon')
                 else to_char(b.target_month, 'TMMonth YYYY') end,
        'publishAtLabel', null,
        -- Дедлайн ответа покупателей (offering): крайний срок живых pending-офферов.
        'deadlineLabel', (
            select to_char(max(o.expires_at), 'DD Mon')
            from public.offers o
            where o.batch_id = b.id and o.status = 'pending'
        ),
        'history',    jsonb_build_array(
            jsonb_build_object('t', 'Создана', 'd', to_char(b.created_at, 'DD Mon')),
            jsonb_build_object('t',
                case when b.status = 'draft' then 'Черновик'
                     when b.status in ('matched','confirmed','dispatched','delivered') then 'Подобран покупатель'
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
    where b.id = p_batch_id;

    return v;
end;
$$;

-- == 4/4 rpc_self_activate_pool_request (Defect B: pool_regions + свип) ==
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
                update public.pools
                set status = 'closed_filled', completed_at = now(),
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
    -- ───────────────────────────────────────────────────────────────────────

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
    'КАНОН d02 | Слайс 6 + DEFECT-B fix | Заявка(draft)→Pool(filling). pools.
     organization_id = org заявки (NOT NULL). filling_deadline = конец target_month.
     DEFECT-B: (a) переносит region_id заявки в pool_regions (видимость канон-путям);
     (b) свипит уже published-партии — прямой матч (бид>=ask, сорт=, окно, регион,
     ёмкость) → matched/confirmed, иначе broadcast-оффер → offering. Зеркало
     rpc_self_auto_match_batch, но pool-initiated (не гейтит владельца партии).
     Гейт fn_my_org_ids через pool_requests.';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;

