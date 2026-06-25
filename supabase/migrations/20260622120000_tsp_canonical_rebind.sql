-- AgOS · БЕТА · Слайс 6 · КАНОН d02: перепривязка торговых RPC на задеплоенную схему.
-- ============================================================================
-- КОНТЕКСТ / ДЕФЕКТ (SQL≠deployed, CLAUDE.md «Conflict resolution»):
--   Миграции TSP-1..5 (20260617090000_tsp1_batches.sql и далее) написаны под
--   ДЕНОРМАЛИЗОВАННУЮ модель прототипа: batches(cat, price, state, district,
--   window_*), tsp_skus(code, name_ru), pool_requests(accepted_skus),
--   pools(organization_id), pool_matches(status). Эти таблицы в задеплоенной БД
--   так и НЕ создались: `create table if not exists` стал no-op поверх уже
--   существующих КАНОНИЧЕСКИХ таблиц d02 (d02_tsp.sql). Поэтому торговые RPC
--   ломались на лету: «column s.code does not exist», «column pr.accepted_skus
--   does not exist», вставка pools.organization_id и pool_matches.status падала.
--
-- РЕШЕНИЕ CEO (2026-06-22): «Переписать RPC под d02» + «Канон d02 + реф. цены».
--   Торговые RPC перепривязываются на КАНОНИЧЕСКУЮ схему d02:
--     batches(tsp_sku_id, avg_weight_kg, target_month, region_id, status,
--             grade_standard_id, notes, published_at, matched_at, cancelled_at)
--     pool_requests(accepted_categories jsonb, region_id, target_month)
--     pools(pool_request_id  — БЕЗ organization_id; гейт через pool_requests)
--     pool_matches(reference_price_at_match, grade_at_match, tsp_sku_at_match
--                  — БЕЗ status)
--     price_grids(base_price_per_kg, region_id, is_active — реф. цены, ст.171)
--
-- КЛЮЧЕВОЙ ПРИНЦИП АДАПТЕРА (минимум правок фронта, HS-5 аддитивно):
--   Новые RPC ВОЗВРАЩАЮТ те же JSON-формы, что фронт уже потребляет
--   (Batch / RawMarketBatch / RawPool / RawMatch). Резолверы (категория→SKU,
--   район→region_id, реф.цена) живут в SQL. Поле `price` = СПРАВОЧНАЯ цена из
--   price_grids (НЕ цена фермера) — фермер цену больше не задаёт (ст.171 ПК РК:
--   TSP не устанавливает цены сделок; price_grids — индикативные ориентиры).
--   Поля визарда (cat/breed/age/fatness/district/окно) хранятся как JSON в
--   batches.notes — без потери для UI; структурная истина — в колонках d02.
--
-- АНТИМОНОПОЛЬ (ст.171 ПК РК, D40): контакты фермера раскрываются МПК ТОЛЬКО при
--   переходе пула в executing (pools.mpk_contact_revealed_at). Инвариант сохранён.
--
-- FLAG (отдельный дефект, НЕ чиним здесь): на pools/pool_matches задеплоены
--   RLS-политики с «infinite recursion». Прямой .from() по ним падает. Торговые
--   RPC это НЕ затрагивает (SECURITY DEFINER исполняется владельцем и обходит RLS),
--   но прямые чтения из фронта по этим таблицам сломаны. Требуется отдельная
--   ревизия RLS — вне рамок этой миграции (риск сломать рабочие RPC).
--
-- Применять через Supabase Dashboard → SQL Editor (НЕ через deploy_sql.py).
-- Идемпотентно: CREATE OR REPLACE + guarded seed. ЗАВИСИМОСТИ: d01 (fn_my_org_ids,
-- fn_current_user_id, fn_set_updated_at), d02 (batches/pool_*/tsp_skus/price_grids).
-- ============================================================================


-- ── 0. Снос старых сигнатур (освобождаем имена под канон-адаптер) ────────────
-- Канонический rpc_create_batch(uuid,...) из d07 мог быть задеплоен — дропаем,
-- чтобы единственным был text-адаптер визарда.
drop function if exists public.rpc_create_batch(
    uuid, uuid, uuid, int, numeric, date, uuid, uuid, text, uuid, jsonb
) cascade;
drop function if exists public.rpc_get_org_batches(uuid, text) cascade;


-- ============================================================
-- 1. ХЕЛПЕРЫ-РЕЗОЛВЕРЫ
-- ============================================================

-- 1a. Безопасный разбор batches.notes как JSON (канон-партии без notes → {}).
create or replace function public.fn_tsp_meta(p_notes text)
returns jsonb
language plpgsql
immutable
as $$
begin
    if p_notes is null or p_notes = '' then
        return '{}'::jsonb;
    end if;
    begin
        return p_notes::jsonb;
    exception when others then
        return '{}'::jsonb;
    end;
end;
$$;

-- 1b. Категория визарда (bychki/telki/korovy/molodnyak) + порода + возраст(мес)
--     + средний вес → tsp_sku_id (лучшее совпадение по полу/возрасту/весу/группе
--     породы). Всегда возвращает SKU (мягкий фолбэк).
create or replace function public.fn_tsp_resolve_sku(
    p_cat        text,
    p_breed      text,
    p_age        int,
    p_avg_weight numeric
)
returns uuid
language plpgsql
stable
as $$
declare
    v_sex_code text;
    v_bg  text;
    v_sku uuid;
begin
    v_sex_code := case p_cat
        when 'bychki'    then 'bull'
        when 'telki'     then 'heifer'
        when 'korovy'    then 'cow'
        when 'molodnyak' then 'bull'   -- молодняк: пол неоднозначен → бычок (мягко)
        else 'bull'
    end;

    v_bg := case
        when p_breed ~* 'ангус|герефорд|абердин|вагю|wagyu|angus|hereford|шароле|лимузин|limousin|charolais|симмент' then 'elite_meat'
        when p_breed ~* 'помес|кросс|метис|cross|гибрид' then 'crossbred'
        else 'local'   -- казахская белоголовая, калмыцкая, аулиекольская и пр.
    end;

    select s.id into v_sku
    from public.tsp_skus s
    where s.is_active = true and s.sex = v_sex_code
    order by
        ( (case when coalesce(p_age,0) between s.age_min_months and s.age_max_months then 0 else 1 end)
        + (case when coalesce(p_avg_weight,0) between s.weight_min_kg and s.weight_max_kg then 0 else 1 end)
        + (case when s.breed_group = v_bg then 0 else 1 end) ) asc,
        abs(((s.weight_min_kg + s.weight_max_kg) / 2.0) - coalesce(p_avg_weight, 0)) asc,
        s.sort_order asc
    limit 1;

    if v_sku is null then
        select s.id into v_sku from public.tsp_skus s
        where s.is_active = true and s.sex = v_sex_code
        order by s.sort_order limit 1;
    end if;
    if v_sku is null then
        select s.id into v_sku from public.tsp_skus s
        where s.is_active = true order by s.sort_order limit 1;
    end if;

    return v_sku;
end;
$$;

-- 1c. Текст района/региона → regions.id (best-effort). null = национальная цена.
create or replace function public.fn_tsp_region_id(p_district text)
returns uuid
language plpgsql
stable
as $$
declare
    v_id uuid;
begin
    if p_district is null or trim(p_district) = '' then
        return null;
    end if;
    select r.id into v_id
    from public.regions r
    where r.is_active = true
      and (
            lower(r.name_ru) = lower(trim(p_district))
         or lower(trim(p_district)) like '%' || lower(r.name_ru) || '%'
         or lower(r.name_ru)        like '%' || lower(trim(p_district)) || '%'
      )
    order by r.level desc
    limit 1;
    return v_id;   -- null → национальная (region_id is null) цена в price_grids
end;
$$;

-- 1d. Справочная цена (₸/кг) для SKU+регион: регион-специфичная приоритетнее
--     национальной (region_id is null). Только активные с показанным дисклеймером.
create or replace function public.fn_tsp_ref_price(p_sku_id uuid, p_region_id uuid)
returns int
language sql
stable
as $$
    select pg.base_price_per_kg
    from public.price_grids pg
    where pg.tsp_sku_id = p_sku_id
      and pg.is_active = true
      and pg.legal_disclaimer_shown = true
      and (pg.region_id = p_region_id or pg.region_id is null)
    order by (pg.region_id is null) asc, pg.valid_from desc
    limit 1;
$$;

-- 1e. Ключ категории МПК (premium/vysshaya/...) → код сорта (NS/S/VS).
--     МРС (mrs_*) — нет SKU КРС → null (не матчится).
create or replace function public.fn_tsp_grade_for_mpk_key(p_code text)
returns text
language sql
immutable
as $$
    select case p_code
        when 'premium'  then 'VS'
        when 'vysshaya' then 'VS'
        when 'pervaya'  then 'S'
        when 'vtoraya'  then 'NS'
        else null
    end;
$$;

-- 1f. Отображаемая фронту категория (cat) для партии: из notes, иначе из пола SKU.
create or replace function public.fn_tsp_cat_display(p_notes text, p_sku_id uuid)
returns text
language plpgsql
stable
as $$
declare
    v_cat text;
    v_sex text;
begin
    v_cat := public.fn_tsp_meta(p_notes) ->> 'cat';
    if v_cat is not null and v_cat <> '' then
        return v_cat;
    end if;
    select s.sex into v_sex from public.tsp_skus s where s.id = p_sku_id;
    return case v_sex
        when 'bull'   then 'bychki'
        when 'heifer' then 'telki'
        when 'cow'    then 'korovy'
        else 'bychki'
    end;
end;
$$;

-- 1g. (Конвергенция B3) Сорт партии (VS/S/NS) для матчинга: из grade_standard_id,
-- фолбэк через grade_id её SKU. Сравнивается с fn_tsp_grade_for_mpk_key(pool_line.category_label).
create or replace function public.fn_tsp_batch_grade(p_batch_id uuid)
returns text
language sql
stable
as $$
    select gs.code
    from public.batches b
    left join public.grade_standards gs
        on gs.id = coalesce(
            b.grade_standard_id,
            (select s.grade_id from public.tsp_skus s where s.id = b.tsp_sku_id)
        )
    where b.id = p_batch_id;
$$;


-- ============================================================
-- 2. SEED price_grids — плейсхолдер-ориентиры (заменить реальными данными ассоц.)
-- Национальные (region_id = null) реф. цены по каждому активному SKU. Базовая
-- цена по сорту + поправка по полу. Только если строки ещё нет (идемпотентно).
-- ============================================================
insert into public.price_grids (
    tsp_sku_id, region_id, base_price_per_kg, premium_per_kg,
    legal_disclaimer_shown, valid_from, is_active, version
)
select
    s.id,
    null,
    ( case gs.code when 'VS' then 1700 when 'S' then 1500 else 1300 end
      + case s.sex when 'bull' then 50 when 'cow' then -150 else 0 end ),
    case gs.code when 'VS' then 150 else 0 end,
    true, current_date, true, 1
from public.tsp_skus s
join public.grade_standards gs on gs.id = s.grade_id
where s.is_active = true
  and not exists (
      select 1 from public.price_grids pg
      where pg.tsp_sku_id = s.id and pg.region_id is null
  );


-- ============================================================
-- 3. rpc_create_batch — визард «Новая партия» (адаптер визарда → канон d02)
-- Резолвит SKU/регион/целевой месяц; цена фермера ИГНОРИРУЕТСЯ (ст.171);
-- поля визарда → notes(JSON). Возвращает Batch-форму с price = реф.цена.
-- ============================================================
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


-- ============================================================
-- 3b. fn_tsp_batch_json — единая сборка Batch-формы для фронта из канон-партии.
-- state маппится из d02-status (+ статус пула для matched→confirmed/delivered).
-- ============================================================
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


-- ============================================================
-- 4. rpc_get_org_batches — партии текущей организации (Batch[])
-- ============================================================
create or replace function public.rpc_get_org_batches()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    return (
        select coalesce(jsonb_agg(public.fn_tsp_batch_json(b.id) order by b.created_at desc), '[]'::jsonb)
        from public.batches b
        where b.organization_id = any (public.fn_my_org_ids())
    );
end;
$$;

comment on function public.rpc_get_org_batches() is
    'КАНОН d02 | Слайс 6 | Партии своих org в форме Batch[] (адаптер). Гейт fn_my_org_ids().';

revoke execute on function public.rpc_get_org_batches() from anon;
grant  execute on function public.rpc_get_org_batches() to authenticated;


-- ============================================================
-- 5. rpc_cancel_batch — снять партию (любое не финальное состояние → cancelled)
-- ============================================================
create or replace function public.rpc_cancel_batch(p_batch_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch public.batches%rowtype;
begin
    select * into v_batch from public.batches where id = p_batch_id;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002';
    end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;

    update public.batches
    set status = 'cancelled', cancelled_at = now(), updated_at = now()
    where id = p_batch_id;
    return true;
end;
$$;

comment on function public.rpc_cancel_batch(uuid) is
    'КАНОН d02 | Слайс 6 | Снятие своей партии → status=cancelled. Гейт fn_my_org_ids().';

revoke execute on function public.rpc_cancel_batch(uuid) from anon;
grant  execute on function public.rpc_cancel_batch(uuid) to authenticated;


-- ============================================================
-- 6. rpc_dispatch_batch — Слайс C: фермер отмечает отгрузку (BT-16, D-M6-10).
-- confirmed→dispatched + dispatched_at; dispatchedAt в notes для UI-лейбла.
-- Двусторонний handshake: приёмку подтверждает МПК (rpc_self_confirm_delivery).
-- ============================================================
create or replace function public.rpc_dispatch_batch(p_batch_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch public.batches%rowtype;
begin
    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002';
    end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;
    if v_batch.status <> 'confirmed' then
        raise exception 'INVALID_STATUS: batch is % (must be confirmed)', v_batch.status using errcode = 'P0003';
    end if;

    update public.batches
    set status = 'dispatched', dispatched_at = now(),
        notes = (public.fn_tsp_meta(notes) || jsonb_build_object('dispatchedAt', to_char(now(),'YYYY-MM-DD')))::text,
        updated_at = now()
    where id = p_batch_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'dispatched', jsonb_build_object('via', 'farmer'), public.fn_current_user_id());

    return true;
end;
$$;

comment on function public.rpc_dispatch_batch(uuid) is
    'КАНОН d02 | Слайс C | Фермер: confirmed→dispatched (BT-16, D-M6-10) + dispatched_at;
     dispatchedAt в notes для UI. Гейт fn_my_org_ids().';

revoke execute on function public.rpc_dispatch_batch(uuid) from anon;
grant  execute on function public.rpc_dispatch_batch(uuid) to authenticated;


-- ============================================================
-- 7. rpc_lower_price — B4 (Слайс C): фермер понижает ask → ре-broadcast.
-- D-TSP-MATCH-01 развернул price-less позицию: фермер снова задаёт ask (пол).
-- D-M6-3: шаг понижения = tsp_config.price_step_down_amount (фикс 100 ₸/кг).
-- Бэкенд клампит НАПРАВЛЕНИЕ (только вниз, не выше current − шаг) и >0; floor-подсказку
-- (minimum_price) держит фронт (soft-warn, D-M6-3 «фермер может вручную ниже»).
-- После понижения партия → published; фронт затем зовёт rpc_self_auto_match_batch
-- (ре-broadcast по новой цене, BT-11 awaiting_price_decision→offering).
-- rpc_update_price — без понижения (touch), сохранён для совместимости.
-- ============================================================
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

    select coalesce(price_step_down_amount, 100) into v_step
    from public.tsp_config where is_active = true limit 1;
    v_step := coalesce(v_step, 100);

    -- текущий ask (фолбэк на реф.цену, если ask ещё не задан)
    v_current := coalesce(v_batch.farmer_price_per_kg,
                          public.fn_tsp_ref_price(v_batch.tsp_sku_id, v_batch.region_id));

    -- clamp + step-down: только вниз и не выше (current − шаг); пол = 1 (CHECK >0).
    v_new := round(p_new_price)::int;
    if v_current is not null then
        v_new := least(v_new, v_current - v_step);
    end if;
    v_new := greatest(v_new, 1);

    update public.batches
    set farmer_price_per_kg        = v_new,
        status                     = 'published',
        offering_at                = null,
        awaiting_price_decision_at = null,
        published_at               = coalesce(published_at, now()),
        updated_at                 = now()
    where id = p_batch_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'price_lowered',
        jsonb_build_object('old_ask', v_current, 'new_ask', v_new, 'step', v_step),
        public.fn_current_user_id());

    return true;
end;
$$;
comment on function public.rpc_lower_price(uuid, numeric) is
    'КАНОН d02 | Слайс C B4 | Фермер понижает ask (D-TSP-MATCH-01): clamp вниз на
     (current − price_step_down_amount, D-M6-3) и >0; партия → published для ре-broadcast
     (фронт затем зовёт rpc_self_auto_match_batch). Гейт fn_my_org_ids().';
revoke execute on function public.rpc_lower_price(uuid, numeric) from anon;
grant  execute on function public.rpc_lower_price(uuid, numeric) to authenticated;

create or replace function public.rpc_update_price(p_batch_id uuid, p_new_price numeric)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_batch public.batches%rowtype;
begin
    select * into v_batch from public.batches where id = p_batch_id;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN' using errcode = 'P0001';
    end if;
    update public.batches set updated_at = now() where id = p_batch_id;
    return true;
end;
$$;
comment on function public.rpc_update_price(uuid, numeric) is
    'КАНОН d02 | Слайс 6 | Цена фермера упразднена (ст.171). No-op-success (touch).
     Сохранён для совместимости с фронтом.';
revoke execute on function public.rpc_update_price(uuid, numeric) from anon;
grant  execute on function public.rpc_update_price(uuid, numeric) to authenticated;


-- ============================================================
-- 8. rpc_submit_review — отзыв фермера о покупателе → в notes (нет колонки в d02).
-- ============================================================
create or replace function public.rpc_submit_review(
    p_batch_id uuid, p_r1 int, p_r2 int, p_comment text default ''
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_batch public.batches%rowtype;
begin
    select * into v_batch from public.batches where id = p_batch_id;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN' using errcode = 'P0001';
    end if;
    update public.batches
    set notes = (public.fn_tsp_meta(notes) || jsonb_build_object(
                    'review', jsonb_build_object('r1', p_r1, 'r2', p_r2, 'comment', coalesce(p_comment,''))))::text,
        updated_at = now()
    where id = p_batch_id;
    return true;
end;
$$;
comment on function public.rpc_submit_review(uuid, int, int, text) is
    'КАНОН d02 | Слайс 6 | Отзыв фермера о покупателе → batches.notes.review
     (в d02 нет отдельной колонки review). Гейт fn_my_org_ids().';
revoke execute on function public.rpc_submit_review(uuid, int, int, text) from anon;
grant  execute on function public.rpc_submit_review(uuid, int, int, text) to authenticated;


-- ============================================================
-- 9. rpc_self_review_due_batches — Слайс C: продюсер истечения 24ч-офферов (нет
-- pg_cron). Свои offering-партии без живых pending-офферов (expires_at истёк) →
-- офферы pending→expired, партия offering→awaiting_price_decision (BT-09). Фронт
-- затем показывает экран снижения цены (B4). Self-serve sweep (фермер-шелл зовёт
-- лениво + поллингом). Паттерн = rpc_self_close_due_pools. Гейт fn_my_org_ids().
-- ============================================================
create or replace function public.rpc_self_review_due_batches()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_moved int := 0;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    with my_due as (
        select b.id as batch_id
        from public.batches b
        where b.organization_id = any (public.fn_my_org_ids())
          and b.status = 'offering'
          and not exists (
              select 1 from public.offers o
              where o.batch_id = b.id and o.status = 'pending' and o.expires_at > now()
          )
    ),
    exp_offers as (
        update public.offers o
        set status = 'expired', responded_at = now()
        where o.batch_id in (select batch_id from my_due) and o.status = 'pending'
        returning 1
    ),
    moved as (
        update public.batches b
        set status = 'awaiting_price_decision', awaiting_price_decision_at = now(), updated_at = now()
        where b.id in (select batch_id from my_due) and b.status = 'offering'
        returning b.id
    ),
    ev as (
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        select m.id, 'offer_window_expired', jsonb_build_object('trigger', 'review_due'),
               public.fn_current_user_id()
        from moved m
        returning 1
    )
    select count(*) into v_moved from moved;

    return jsonb_build_object('moved', v_moved);
end;
$$;
comment on function public.rpc_self_review_due_batches() is
    'КАНОН d02 | Слайс C | Продюсер истечения 24ч-офферов (нет pg_cron): свои
     offering-партии без живых pending-офферов → офферы expired, партия →
     awaiting_price_decision (BT-09). Self-serve sweep. Гейт fn_my_org_ids().';
revoke execute on function public.rpc_self_review_due_batches() from anon;
grant  execute on function public.rpc_self_review_due_batches() to authenticated;


-- ============================================================
-- 10. rpc_self_auto_match_batch — авто-матч партии в пул (канон, без цены).
-- Критерий: пул filling со свободными головами, чьи accepted_categories
-- принимают СОРТ партии (через fn_tsp_grade_for_mpk_key). Регион — мягкий
-- приоритет. Среди кандидатов: ближе регион → старше пул (FIFO). Контакты НЕ
-- раскрываются (D40).
-- ============================================================
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

    -- 1) Прямой авто-матч (BT-01/BT-05): высший стоящий бид >= ask среди filling-пулов,
    -- сорт совпадает, окно overlap (D-M6-8), регион, ёмкость. deal = бид (D-M6-DEALPRICE).
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
      and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
      and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
      and (pr.region_id is null
           or pr.region_id = v_batch.region_id
           or pr.region_id = (select parent_id from public.regions where id = v_batch.region_id))
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

        -- auto-close по головам → closed_filled + matched-партии этого пула → confirmed
        if (v_line.matched_heads + v_batch.heads) >= v_line.target_heads then
            update public.pools
            set status = 'closed_filled', completed_at = now(),
                mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
            where id = v_line.pool_id and status = 'filling';
            if found then
                update public.batches b
                set status = 'confirmed', confirmed_at = now(), updated_at = now()
                from public.pool_lines pl
                where pl.pool_id = v_line.pool_id and b.pool_line_id = pl.id and b.status = 'matched';
            end if;
        end if;

        -- снять прочие висящие офферы на эту партию (FCFS-консистентность)
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

    -- 2) Нет прямого матча → broadcast офферов всем подходящим МПК (M4 §2.2 step3):
    -- сорт+регион+окно+ёмкость, ЦЕНА игнорируется; offered_price = ask. Партия → offering.
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
          and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
          and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
          and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
          and (pr.region_id is null
               or pr.region_id = v_batch.region_id
               or pr.region_id = (select parent_id from public.regions where id = v_batch.region_id))
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
    'КАНОН d02 | Конвергенция B3 | Авто-матч при публикации (BT-01/BT-05): высший стоящий
     бид МПК >= ask → партия matched, deal=бид (D-M6-DEALPRICE), pool_line_id; auto-close
     по головам → confirmed. Иначе broadcast офферов (offered_price=ask; сорт+регион+окно)
     → offering. Иначе NO_POOL (остаётся published). Контакты НЕ раскрываются (D40).';
revoke execute on function public.rpc_self_auto_match_batch(uuid) from anon;
grant  execute on function public.rpc_self_auto_match_batch(uuid) to authenticated;


-- ============================================================
-- 11. rpc_get_market_batches — обезличенный маркет-борд для МПК (RawMarketBatch[])
-- Только published. Без organization_id/контактов (D40). minPrice = реф.цена.
-- ============================================================
create or replace function public.rpc_get_market_batches(p_cat text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'id',        b.id,
                'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'skuName',   s.sku_code,
                'breed',     coalesce(public.fn_tsp_meta(b.notes)->>'breed', ''),
                'heads',     b.heads,
                'avgWeight', b.avg_weight_kg,
                'age',       coalesce((public.fn_tsp_meta(b.notes)->>'age')::int, 0),
                'fatness',   coalesce(public.fn_tsp_meta(b.notes)->>'fatness', ''),
                'region',    coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'minPrice',  coalesce(b.farmer_price_per_kg, public.fn_tsp_ref_price(b.tsp_sku_id, b.region_id)),
                'state',     'published',
                'windowLabel', to_char(b.target_month, 'TMMonth YYYY')
            )
            order by b.created_at desc
        ), '[]'::jsonb)
        from public.batches b
        join public.tsp_skus s on s.id = b.tsp_sku_id
        left join public.regions r on r.id = b.region_id
        where b.status in ('published', 'offering')
          and (p_cat is null or public.fn_tsp_cat_display(b.notes, b.tsp_sku_id) = p_cat)
    );
end;
$$;
comment on function public.rpc_get_market_batches(text) is
    'КАНОН d02 | Слайс 6 | Обезличенный маркет-борд: published-партии всех ферм.
     Без organization_id/контактов (D40). minPrice = справочная цена. Любой authenticated.';
revoke execute on function public.rpc_get_market_batches(text) from anon;
grant  execute on function public.rpc_get_market_batches(text) to authenticated;


-- ============================================================
-- 12. rpc_self_create_pool_request — МПК создаёт заявку (accepted_categories из
-- фронтовых [{code,price,maxHeads}]). p_region_id опционален. Гейт fn_my_org_ids.
-- ============================================================
create or replace function public.rpc_self_create_pool_request(
    p_organization_id uuid,
    p_total_heads     int,
    p_target_month    date,
    p_region_id       uuid  default null,
    p_accepted_skus   jsonb default '[]'::jsonb,
    p_notes           text  default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;
    if not (p_organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: organization not owned by current user' using errcode = 'P0001';
    end if;

    insert into public.pool_requests (
        organization_id, total_heads, target_month, region_id,
        accepted_categories, notes, status
    ) values (
        p_organization_id, p_total_heads, p_target_month, p_region_id,
        coalesce(p_accepted_skus, '[]'::jsonb), p_notes, 'draft'
    ) returning id into v_id;
    return v_id;
end;
$$;
comment on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text) is
    'КАНОН d02 | Слайс 6 | МПК создаёт заявку. accepted_categories хранит фронтовые
     [{code,price,maxHeads}] (round-trip для UI; матч резолвит сорт по code). Гейт fn_my_org_ids.';
revoke execute on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text) from anon;
grant  execute on function public.rpc_self_create_pool_request(uuid, int, date, uuid, jsonb, text) to authenticated;


-- ============================================================
-- 13. rpc_self_activate_pool_request — заявка(draft)→Pool(filling). pools БЕЗ
-- organization_id (канон): связь только через pool_request_id.
-- ============================================================
create or replace function public.rpc_self_activate_pool_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_req     public.pool_requests%rowtype;
    v_pool_id uuid;
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

    update public.pool_requests
    set status = 'active', activated_at = now(), updated_at = now()
    where id = p_request_id;

    return jsonb_build_object('request_id', p_request_id, 'pool_id', v_pool_id);
end;
$$;
comment on function public.rpc_self_activate_pool_request(uuid) is
    'КАНОН d02 | Слайс 6 | Заявка(draft)→Pool(filling). pools.organization_id =
     org заявки (колонка NOT NULL в задеплоенной схеме). filling_deadline = конец
     target_month. Гейт fn_my_org_ids через pool_requests.';
revoke execute on function public.rpc_self_activate_pool_request(uuid) from anon;
grant  execute on function public.rpc_self_activate_pool_request(uuid) to authenticated;


-- ============================================================
-- 14. rpc_self_match_batch_to_pool — ручной оффер МПК на published-партию.
-- Гейт: пул моей org (через pool_request). Снапшот реф.цены/сорта/SKU.
-- ============================================================
-- Конвергенция B3: сигнатура +p_price_per_kg. Дроп старой 3-арг версии, чтобы не
-- осталось overload-двойника (PGRST203 при вызове с 3 аргами). Идемпотентно.
drop function if exists public.rpc_self_match_batch_to_pool(uuid, uuid, int) cascade;

create or replace function public.rpc_self_match_batch_to_pool(
    p_pool_id uuid, p_batch_id uuid, p_matched_heads int, p_price_per_kg int default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool   public.pools%rowtype;
    v_batch  public.batches%rowtype;
    v_grade  text;
    v_line   record;
    v_deal   int;
    v_vol    int;
    v_heads  int;
begin
    select * into v_pool from public.pools where id = p_pool_id for update;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    -- DEF-TSP-M4-OWNERSHIP (resolved): owner через pools.organization_id напрямую.
    if not (v_pool.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;
    if v_pool.status <> 'filling' then
        raise exception 'POOL_NOT_FILLING' using errcode = 'P0003';
    end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0004'; end if;
    if v_batch.status not in ('published', 'offering') then
        raise exception 'BATCH_NOT_AVAILABLE' using errcode = 'P0005';
    end if;

    v_grade := public.fn_tsp_batch_grade(p_batch_id);
    v_vol   := coalesce(v_batch.heads * v_batch.avg_weight_kg, 0)::int;
    v_heads := coalesce(p_matched_heads, v_batch.heads);

    -- строка пула под сорт партии (линковка + фолбэк-бид)
    select pl.id as pl_id, pl.mpk_price_per_kg as bid
      into v_line
    from public.pool_lines pl
    where pl.pool_id = p_pool_id
      and pl.is_active = true
      and public.fn_tsp_grade_for_mpk_key(pl.category_label) = v_grade
    order by pl.mpk_price_per_kg desc
    limit 1
    for update;
    if not found then
        raise exception 'NO_MATCHING_LINE: pool has no active line for batch grade %', v_grade
            using errcode = 'P0006';
    end if;

    -- deal = явный бид МПК (p_price_per_kg), иначе бид строки; не ниже ask (пол).
    v_deal := coalesce(p_price_per_kg, v_line.bid);
    if v_batch.farmer_price_per_kg is not null and v_deal < v_batch.farmer_price_per_kg then
        raise exception 'BID_BELOW_ASK: bid % < farmer ask %', v_deal, v_batch.farmer_price_per_kg
            using errcode = 'P0007';
    end if;

    update public.batches
    set status = 'matched', pool_line_id = v_line.pl_id, deal_price_per_kg = v_deal,
        matched_at = now(), updated_at = now()
    where id = p_batch_id;

    update public.pool_lines
    set current_volume_kg = current_volume_kg + v_vol, updated_at = now()
    where id = v_line.pl_id;

    update public.pools
    set matched_heads = matched_heads + v_heads, updated_at = now()
    where id = p_pool_id;

    -- снять прочие висящие офферы на эту партию (FCFS)
    update public.offers set status = 'withdrawn', responded_at = now()
    where batch_id = p_batch_id and status = 'pending';

    -- auto-close по головам → closed_filled + matched-партии пула → confirmed
    if (v_pool.matched_heads + v_heads) >= v_pool.target_heads then
        update public.pools set status = 'closed_filled', completed_at = now(),
            mpk_contact_revealed_at = coalesce(mpk_contact_revealed_at, now()), updated_at = now()
        where id = p_pool_id and status = 'filling';
        if found then
            update public.batches b
            set status = 'confirmed', confirmed_at = now(), updated_at = now()
            from public.pool_lines pl
            where pl.pool_id = p_pool_id and b.pool_line_id = pl.id and b.status = 'matched';
        end if;
    end if;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'matched',
        jsonb_build_object('pool_id', p_pool_id, 'pool_line_id', v_line.pl_id,
                           'via', 'manual_match', 'deal_price_per_kg', v_deal),
        public.fn_current_user_id());

    return v_line.pl_id;
end;
$$;
comment on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) is
    'КАНОН d02 | Конвергенция B3 | Ручной матч МПК: published|offering-партию → matched
     в свой пул при p_price_per_kg (бид МПК, >= ask). deal=бид (D-M6-DEALPRICE), pool_line_id;
     висящие офферы снимаются (FCFS); auto-close по головам → confirmed. Гейт pools.organization_id.';
revoke execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) from anon;
grant  execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int, int) to authenticated;


-- ============================================================
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
    v_allowed text[] := array['filled','executing','dispatched','delivered','executed','closed'];
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
    else
        update public.pools set status = p_new_status, updated_at = now() where id = p_pool_id;
    end if;
    return true;
end;
$$;
comment on function public.rpc_self_advance_pool_status(uuid, text) is
    'КАНОН d02 | Слайс 6 | МПК двигает статус пула. executing → раскрытие контактов (D40).
     Гейт «пул моей org» (через pool_request). Партии остаются matched (в d02 у них нет
     состояний confirmed/delivered — фермеру это показывается по статусу пула).';
revoke execute on function public.rpc_self_advance_pool_status(uuid, text) from anon;
grant  execute on function public.rpc_self_advance_pool_status(uuid, text) to authenticated;


-- ============================================================
-- 16. rpc_get_pool_matches — карточки матчей пула (RawMatch[]). Контакты фермы
-- только после mpk_contact_revealed_at (D40). status выводится из статуса пула.
-- ============================================================
create or replace function public.rpc_get_pool_matches(p_pool_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool     public.pools%rowtype;
    v_req      public.pool_requests%rowtype;
    v_revealed boolean;
begin
    select * into v_pool from public.pools where id = p_pool_id;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    v_revealed := v_pool.mpk_contact_revealed_at is not null;

    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'matchId',   b.id,
                'batchId',   b.id,
                'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'heads',     b.heads,
                'avgWeight', b.avg_weight_kg,
                'price',     b.deal_price_per_kg,
                'region',    coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'status',    case when b.status = 'delivered'  then 'delivered'
                                  when b.status = 'dispatched'  then 'dispatched'
                                  when b.status = 'confirmed'   then 'confirmed'
                                  else 'active' end,
                'farmName',  case when v_revealed then o.legal_name else null end,
                'farmPhone', case when v_revealed then o.phone     else null end
            )
            order by b.matched_at desc
        ), '[]'::jsonb)
        from public.batches b
        join public.pool_lines pl   on pl.id = b.pool_line_id
        join public.organizations o on o.id = b.organization_id
        left join public.regions r  on r.id = b.region_id
        where pl.pool_id = p_pool_id
          and b.status in ('matched','confirmed','dispatched','delivered')
    );
end;
$$;
comment on function public.rpc_get_pool_matches(uuid) is
    'КАНОН d02 | Слайс 6 | Матчи пула (RawMatch[]). Контакты фермы только после
     mpk_contact_revealed_at (D40). status выводится из статуса пула (нет колонки status
     в pool_matches). Гейт «пул моей org» (через pool_request).';
revoke execute on function public.rpc_get_pool_matches(uuid) from anon;
grant  execute on function public.rpc_get_pool_matches(uuid) to authenticated;


-- ============================================================
-- 17. rpc_get_my_pools — пулы текущего МПК (RawPool[]). Гейт через pool_request.
-- lines = accepted_categories (фронтовые [{code,price}]).
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
                'contactRevealed', (p.mpk_contact_revealed_at is not null)
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
revoke execute on function public.rpc_get_my_pools() from anon;
grant  execute on function public.rpc_get_my_pools() to authenticated;


-- ============================================================
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
    v_filled int := 0;
    v_closed int := 0;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    with due as (
        select p.id, p.target_heads, p.matched_heads
        from public.pools p
        join public.pool_requests pr on pr.id = p.pool_request_id
        where pr.organization_id = any (public.fn_my_org_ids())
          and p.status = 'filling'
          and current_date >= (date_trunc('month', pr.target_month) + interval '1 month')::date
    ),
    upd_filled as (
        update public.pools p
        set status = 'filled', filled_at = now(), updated_at = now()
        from due
        where p.id = due.id and due.matched_heads >= ceil(due.target_heads * 0.30)
        returning 1
    ),
    upd_closed as (
        update public.pools p
        set status = 'closed', closed_at = now(), updated_at = now()
        from due
        where p.id = due.id and due.matched_heads < ceil(due.target_heads * 0.30)
        returning 1
    )
    select (select count(*) from upd_filled), (select count(*) from upd_closed)
    into v_filled, v_closed;

    return jsonb_build_object('filled', v_filled, 'closed', v_closed);
end;
$$;
comment on function public.rpc_self_close_due_pools() is
    'КАНОН d02 | Слайс 6 | Авто-закрытие просроченных пулов своих org (гейт через
     pool_request). filling + месяц истёк → filled (>=30%) | closed (<30%). Без pg_cron.';
revoke execute on function public.rpc_self_close_due_pools() from anon;
grant  execute on function public.rpc_self_close_due_pools() to authenticated;


-- ============================================================
-- 19. rpc_self_accept_offer — МПК принимает broadcast-оффер (FCFS). Self-serve
-- (org через fn_my_org_ids). deal = бид строки пула >= offered ask (D-M6-DEALPRICE),
-- сиблинг-офферы → withdrawn. Партия offering → matched; auto-close по головам.
-- ВАЖНО: consumer broadcast-пути из §10; UI «входящих офферов» появится в Слайсе C.
-- ============================================================
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

    -- лучшая строка МПК: бид >= offered ask, сорт/окно/регион/ёмкость
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
      and (pl.max_volume_kg is null or pl.current_volume_kg + v_vol <= pl.max_volume_kg)
      and (p.delivery_from is null or v_batch.ready_to   is null or p.delivery_from <= v_batch.ready_to)
      and (p.delivery_to   is null or v_batch.ready_from is null or p.delivery_to   >= v_batch.ready_from)
      and (pr.region_id is null
           or pr.region_id = v_batch.region_id
           or pr.region_id = (select parent_id from public.regions where id = v_batch.region_id))
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
        update public.pools set status = 'closed_filled', completed_at = now(),
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
    'КАНОН d02 | Конвергенция B3 | МПК принимает broadcast-оффер (FCFS): партия offering →
     matched, deal=бид строки >= offered ask (D-M6-DEALPRICE); сиблинг-офферы withdrawn;
     auto-close по головам → confirmed. Гейт offer.mpk_org_id ∈ fn_my_org_ids().';
revoke execute on function public.rpc_self_accept_offer(uuid) from anon;
grant  execute on function public.rpc_self_accept_offer(uuid) to authenticated;


-- ============================================================
-- 20. rpc_get_incoming_offers — Слайс C: входящие broadcast-офферы моего МПК.
-- Только pending + не истёкшие. Характеристики партии БЕЗ личности фермера
-- (D-M6-12: раскрытие при confirmed). Анонимная репутация (★) — TODO (нет агрегата).
-- Гейт offer.mpk_org_id ∈ fn_my_org_ids().
-- ============================================================
create or replace function public.rpc_get_incoming_offers()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;
    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'id',           o.id,
                'batchId',      b.id,
                'cat',          public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'breed',        coalesce(public.fn_tsp_meta(b.notes)->>'breed', ''),
                'heads',        b.heads,
                'avgWeight',    b.avg_weight_kg,
                'region',       coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'windowLabel',
                    case when b.ready_from is not null and b.ready_to is not null
                         then to_char(b.ready_from, 'DD Mon') || ' — ' || to_char(b.ready_to, 'DD Mon')
                         else to_char(b.target_month, 'TMMonth YYYY') end,
                'offeredPrice', o.offered_price_per_kg,
                'expiresAtIso', to_char(o.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'status',       o.status
            )
            order by o.expires_at asc
        ), '[]'::jsonb)
        from public.offers o
        join public.batches b      on b.id = o.batch_id
        left join public.regions r on r.id = b.region_id
        where o.mpk_org_id = any (public.fn_my_org_ids())
          and o.status = 'pending'
          and o.expires_at > now()
    );
end;
$$;
comment on function public.rpc_get_incoming_offers() is
    'КАНОН d02 | Слайс C | Входящие broadcast-офферы моего МПК (pending, не истёкшие):
     характеристики партии БЕЗ личности фермера (D-M6-12). Гейт fn_my_org_ids().';
revoke execute on function public.rpc_get_incoming_offers() from anon;
grant  execute on function public.rpc_get_incoming_offers() to authenticated;


-- ============================================================
-- 21. rpc_self_reject_offer — Слайс C: МПК отклоняет broadcast-оффер. pending→rejected.
-- Имя rpc_self_* (не rpc_reject_offer из d02 (uuid,uuid)) — избегаем PGRST203-перегрузки.
-- Гейт offer.mpk_org_id ∈ fn_my_org_ids().
-- ============================================================
create or replace function public.rpc_self_reject_offer(p_offer_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_offer public.offers%rowtype;
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
    update public.offers
    set status = 'rejected', responded_at = now(), responded_by = public.fn_current_user_id()
    where id = p_offer_id;
    return true;
end;
$$;
comment on function public.rpc_self_reject_offer(uuid) is
    'КАНОН d02 | Слайс C | МПК отклоняет broadcast-оффер: pending→rejected.
     rpc_self_* избегает PGRST203-перегрузки с d02 rpc_reject_offer(uuid,uuid). Гейт fn_my_org_ids().';
revoke execute on function public.rpc_self_reject_offer(uuid) from anon;
grant  execute on function public.rpc_self_reject_offer(uuid) to authenticated;


-- ============================================================
-- 22. rpc_self_confirm_delivery — Слайс C: МПК подтверждает приёмку партии (BT-18,
-- D-M6-10). dispatched→delivered + delivered_at (приёмка на уровне Batch, не Pool).
-- Все партии пула delivered → пул completed (§7 M6-B). Имя rpc_self_* избегает
-- PGRST203-перегрузки с d02 rpc_confirm_delivery(uuid,uuid). Гейт «пул моей org».
-- ============================================================
create or replace function public.rpc_self_confirm_delivery(p_batch_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch     public.batches%rowtype;
    v_pool_id   uuid;
    v_owner     uuid;
    v_remaining int;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_batch from public.batches where id = p_batch_id for update;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;

    -- пул партии + его org (через pool_line → pool); гейт «пул моей org»
    select po.id, po.organization_id
      into v_pool_id, v_owner
    from public.pool_lines pl
    join public.pools po on po.id = pl.pool_id
    where pl.id = v_batch.pool_line_id;
    if v_pool_id is null then
        raise exception 'BATCH_NOT_IN_POOL' using errcode = 'P0003';
    end if;
    if not (v_owner = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;
    if v_batch.status <> 'dispatched' then
        raise exception 'INVALID_STATUS: batch is % (must be dispatched)', v_batch.status using errcode = 'P0004';
    end if;

    update public.batches
    set status = 'delivered', delivered_at = now(), updated_at = now()
    where id = p_batch_id;

    insert into public.batch_events (batch_id, event_type, metadata, created_by)
    values (p_batch_id, 'delivered', jsonb_build_object('via', 'mpk', 'pool_id', v_pool_id),
            public.fn_current_user_id());

    -- все матч-партии пула доставлены → пул completed
    select count(*) into v_remaining
    from public.batches b
    join public.pool_lines pl on pl.id = b.pool_line_id
    where pl.pool_id = v_pool_id
      and b.status in ('matched', 'confirmed', 'dispatched');
    if v_remaining = 0 then
        update public.pools set status = 'completed', completed_at = coalesce(completed_at, now()), updated_at = now()
        where id = v_pool_id and status <> 'completed';
    end if;

    return true;
end;
$$;
comment on function public.rpc_self_confirm_delivery(uuid) is
    'КАНОН d02 | Слайс C | МПК подтверждает приёмку партии (BT-18, D-M6-10):
     dispatched→delivered + delivered_at; все партии пула delivered → пул completed.
     Гейт «пул моей org» (через pool_line→pool). rpc_self_* избегает PGRST203.';
revoke execute on function public.rpc_self_confirm_delivery(uuid) from anon;
grant  execute on function public.rpc_self_confirm_delivery(uuid) to authenticated;
