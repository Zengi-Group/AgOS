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
    p_price       numeric,          -- принимается для совместимости, НЕ хранится как цена сделки
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
        status, notes, published_at, created_by, created_at
    ) values (
        v_org_id, v_sku_id, v_grade_id, null,
        p_heads, p_avg_weight, date_trunc('month', p_window_from)::date, v_region_id,
        v_status, v_notes,
        case when v_status = 'published' then now() else null end,
        public.fn_current_user_id(), now()
    )
    returning id into v_batch_id;

    return public.fn_tsp_batch_json(v_batch_id);
end;
$$;

comment on function public.rpc_create_batch(text, text, int, numeric, int, text, text, numeric, date, date, boolean) is
    'КАНОН d02 | Слайс 6 | Адаптер визарда: резолвит tsp_sku_id/region_id/target_month,
     поля визарда → notes(JSON), цена фермера НЕ хранится (ст.171). published|draft.
     Возвращает Batch-форму (price = справочная цена price_grids).';

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
        'breed',      coalesce(meta->>'breed', ''),
        'heads',      b.heads,
        'avgWeight',  b.avg_weight_kg,
        'age',        coalesce((meta->>'age')::int, 0),
        'fatness',    coalesce(meta->>'fatness', ''),
        'district',   coalesce(meta->>'district', coalesce(r.name_ru, '')),
        'price',      public.fn_tsp_ref_price(b.tsp_sku_id, b.region_id),
        'dealPrice',  pm.reference_price_at_match,
        'state',      case
                          when b.status = 'draft' and coalesce(meta->>'scheduled','false') = 'true' then 'scheduled'
                          when b.status = 'draft'     then 'draft'
                          when b.status = 'published' then 'published'
                          when b.status = 'cancelled' then 'cancelled'
                          when b.status = 'expired'   then 'cancelled'
                          when b.status = 'matched' then case
                              when px.pool_status = 'executed'  then 'delivered'
                              when px.pool_status in ('executing','dispatched','delivered') then 'confirmed'
                              else 'matched'
                          end
                          else b.status
                      end,
        'windowLabel',
            case when meta ? 'wf' and meta ? 'wt'
                 then to_char((meta->>'wf')::date, 'DD Mon') || ' — ' || to_char((meta->>'wt')::date, 'DD Mon')
                 else to_char(b.target_month, 'TMMonth YYYY') end,
        'publishAtLabel', null,
        'deadlineLabel',  null,
        'history',    jsonb_build_array(
            jsonb_build_object('t', 'Создана', 'd', to_char(b.created_at, 'DD Mon')),
            jsonb_build_object('t',
                case when b.status = 'draft' then 'Черновик'
                     when b.status = 'matched' then 'Подобран покупатель'
                     when b.status = 'cancelled' then 'Снята'
                     else 'Выставлена на продажу' end,
                'd', to_char(coalesce(b.published_at, b.created_at), 'DD Mon'))
        )
    )
    into v
    from public.batches b
    left join public.regions r on r.id = b.region_id
    left join lateral (
        select pm2.reference_price_at_match
        from public.pool_matches pm2
        where pm2.batch_id = b.id
        order by pm2.matched_at desc limit 1
    ) pm on true
    left join lateral (
        select pl.status as pool_status
        from public.pool_matches pm3
        join public.pools pl on pl.id = pm3.pool_id
        where pm3.batch_id = b.id
        order by pm3.matched_at desc limit 1
    ) px on true
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
-- 6. rpc_dispatch_batch — confirmed→dispatched (нет в каноне; no-op success)
-- В d02 у партии нет состояний dispatched/delivered (это поля пула). Сохраняем
-- RPC, чтобы вызов фронта не падал; отметку об отгрузке кладём в notes.
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
    select * into v_batch from public.batches where id = p_batch_id;
    if not found then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002';
    end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;

    update public.batches
    set notes = (public.fn_tsp_meta(notes) || jsonb_build_object('dispatchedAt', to_char(now(),'YYYY-MM-DD')))::text,
        updated_at = now()
    where id = p_batch_id;
    return true;
end;
$$;

comment on function public.rpc_dispatch_batch(uuid) is
    'КАНОН d02 | Слайс 6 | Отметка отгрузки в notes (в d02 у партии нет dispatched-состояния).
     Сохранён для совместимости с фронтом. Гейт fn_my_org_ids().';

revoke execute on function public.rpc_dispatch_batch(uuid) from anon;
grant  execute on function public.rpc_dispatch_batch(uuid) to authenticated;


-- ============================================================
-- 7. rpc_lower_price / rpc_update_price — цена фермера упразднена (ст.171).
-- Сохранены как no-op-success: цену сделки определяет реф.грид, не фермер.
-- Любой вызов лишь продлевает видимость (touch updated_at), не падает.
-- ============================================================
create or replace function public.rpc_lower_price(p_batch_id uuid, p_new_price numeric)
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
    -- Канон: цена фермера не хранится. Возвращаем партию в published (на витрину).
    update public.batches
    set status = case when status in ('draft') then 'published' else status end,
        published_at = coalesce(published_at, now()),
        updated_at = now()
    where id = p_batch_id;
    return true;
end;
$$;
comment on function public.rpc_lower_price(uuid, numeric) is
    'КАНОН d02 | Слайс 6 | Цена фермера упразднена (ст.171). No-op-success: партия
     остаётся/возвращается published. Сохранён для совместимости с фронтом.';
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
-- 9. rpc_self_review_due_batches — 24ч-рекомендация цены. В каноне нет цены
-- фермера и состояния decision → no-op {moved:0}. Сохранён для совместимости.
-- ============================================================
create or replace function public.rpc_self_review_due_batches()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;
    return jsonb_build_object('moved', 0);
end;
$$;
comment on function public.rpc_self_review_due_batches() is
    'КАНОН d02 | Слайс 6 | No-op (цена фермера/состояние decision упразднены).
     Сохранён для совместимости с фермер-шеллом.';
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
    v_skucode   text;
    v_pool      record;
    v_take      int;
    v_match_id  uuid;
    v_ref_price int;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select * into v_batch from public.batches where id = p_batch_id;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002'; end if;
    if not (v_batch.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: batch not owned by current user' using errcode = 'P0001';
    end if;
    if v_batch.status <> 'published' then
        return jsonb_build_object('matched', false, 'reason', 'BATCH_NOT_AVAILABLE');
    end if;

    select gs.code, s.sku_code into v_grade, v_skucode
    from public.tsp_skus s join public.grade_standards gs on gs.id = s.grade_id
    where s.id = v_batch.tsp_sku_id;

    select
        p.id            as pool_id,
        p.target_heads  as target_heads,
        p.matched_heads as matched_heads,
        case
            when pr.region_id is null then 0
            when pr.region_id = v_batch.region_id then 0
            else 1
        end             as region_rank
    into v_pool
    from public.pools p
    join public.pool_requests pr on pr.id = p.pool_request_id
    where p.status = 'filling'
      and p.matched_heads < p.target_heads
      and exists (
          select 1
          from jsonb_array_elements(coalesce(pr.accepted_categories, '[]'::jsonb)) ln
          where public.fn_tsp_grade_for_mpk_key(ln->>'code') = v_grade
      )
      and not exists (
          select 1 from public.pool_matches pm
          where pm.pool_id = p.id and pm.batch_id = v_batch.id
      )
    order by region_rank asc, p.created_at asc
    limit 1;

    if not found then
        return jsonb_build_object('matched', false, 'reason', 'NO_POOL');
    end if;

    v_take      := least(v_batch.heads, v_pool.target_heads - v_pool.matched_heads);
    v_ref_price := public.fn_tsp_ref_price(v_batch.tsp_sku_id, v_batch.region_id);

    insert into public.pool_matches (
        pool_id, batch_id, matched_heads,
        reference_price_at_match, premium_at_match, grade_at_match, tsp_sku_at_match,
        matched_by, matched_at
    ) values (
        v_pool.pool_id, v_batch.id, v_take,
        v_ref_price, 0, v_grade, v_skucode,
        public.fn_current_user_id(), now()
    ) returning id into v_match_id;

    update public.pools
    set matched_heads = matched_heads + v_take,
        status        = case when matched_heads + v_take >= target_heads then 'filled' else status end,
        filled_at     = case when matched_heads + v_take >= target_heads then now() else filled_at end,
        updated_at    = now()
    where id = v_pool.pool_id;

    update public.batches
    set status = 'matched', matched_at = now(), updated_at = now()
    where id = v_batch.id;

    return jsonb_build_object(
        'matched', true, 'poolId', v_pool.pool_id, 'matchId', v_match_id,
        'matchedHeads', v_take, 'dealPrice', v_ref_price
    );
end;
$$;
comment on function public.rpc_self_auto_match_batch(uuid) is
    'КАНОН d02 | Слайс 6 | Авто-матч партии в filling-пул, принимающий её СОРТ
     (accepted_categories→grade). Регион — мягкий приоритет. Реф.цена снапшотится
     в pool_matches. Партия → matched. Контакты НЕ раскрываются (D40).';
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
                'minPrice',  public.fn_tsp_ref_price(b.tsp_sku_id, b.region_id),
                'state',     'published',
                'windowLabel', to_char(b.target_month, 'TMMonth YYYY')
            )
            order by b.created_at desc
        ), '[]'::jsonb)
        from public.batches b
        join public.tsp_skus s on s.id = b.tsp_sku_id
        left join public.regions r on r.id = b.region_id
        where b.status = 'published'
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

    -- ПРАВКА (live-верификация 2026-06-23): задеплоенная pools имеет
    -- organization_id NOT NULL (вопреки исходному допущению «pools без org»).
    -- Берём org из заявки — это всегда МПК-владелец пула. Гейт уже выше.
    insert into public.pools (
        organization_id, pool_request_id, status, target_heads, matched_heads, filling_deadline
    ) values (
        v_req.organization_id, v_req.id, 'filling', v_req.total_heads, 0,
        (date_trunc('month', v_req.target_month) + interval '1 month - 1 day')::date
    ) returning id into v_pool_id;

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
create or replace function public.rpc_self_match_batch_to_pool(
    p_pool_id uuid, p_batch_id uuid, p_matched_heads int
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pool      public.pools%rowtype;
    v_req       public.pool_requests%rowtype;
    v_batch     public.batches%rowtype;
    v_grade     text;
    v_skucode   text;
    v_ref_price int;
    v_match_id  uuid;
begin
    select * into v_pool from public.pools where id = p_pool_id;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;
    if v_pool.status <> 'filling' then
        raise exception 'POOL_NOT_FILLING' using errcode = 'P0003';
    end if;

    select * into v_batch from public.batches where id = p_batch_id;
    if not found then raise exception 'BATCH_NOT_FOUND' using errcode = 'P0004'; end if;
    if v_batch.status <> 'published' then
        raise exception 'BATCH_NOT_AVAILABLE' using errcode = 'P0005';
    end if;

    select gs.code, s.sku_code into v_grade, v_skucode
    from public.tsp_skus s join public.grade_standards gs on gs.id = s.grade_id
    where s.id = v_batch.tsp_sku_id;

    v_ref_price := public.fn_tsp_ref_price(v_batch.tsp_sku_id, v_batch.region_id);

    insert into public.pool_matches (
        pool_id, batch_id, matched_heads,
        reference_price_at_match, premium_at_match, grade_at_match, tsp_sku_at_match,
        matched_by, matched_at
    ) values (
        p_pool_id, p_batch_id, p_matched_heads,
        v_ref_price, 0, v_grade, v_skucode,
        public.fn_current_user_id(), now()
    ) returning id into v_match_id;

    update public.pools
    set matched_heads = matched_heads + p_matched_heads,
        status        = case when matched_heads + p_matched_heads >= target_heads then 'filled' else status end,
        filled_at     = case when matched_heads + p_matched_heads >= target_heads then now() else filled_at end,
        updated_at    = now()
    where id = p_pool_id;

    update public.batches
    set status = 'matched', matched_at = now(), updated_at = now()
    where id = p_batch_id;

    return v_match_id;
end;
$$;
comment on function public.rpc_self_match_batch_to_pool(uuid, uuid, int) is
    'КАНОН d02 | Слайс 6 | Ручной оффер МПК: матчит published-партию в свой пул.
     Снапшот реф.цены/сорта/SKU в pool_matches (без status-колонки). Партия → matched.
     Гейт «пул моей org» (через pool_request). Контакты НЕ раскрываются (D40).';
revoke execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int) from anon;
grant  execute on function public.rpc_self_match_batch_to_pool(uuid, uuid, int) to authenticated;


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
    v_delivered boolean;
begin
    select * into v_pool from public.pools where id = p_pool_id;
    if not found then raise exception 'POOL_NOT_FOUND' using errcode = 'P0002'; end if;
    select * into v_req from public.pool_requests where id = v_pool.pool_request_id;
    if not (v_req.organization_id = any (public.fn_my_org_ids())) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = 'P0001';
    end if;

    v_revealed  := v_pool.mpk_contact_revealed_at is not null;
    v_delivered := v_pool.status in ('delivered','executed');

    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'matchId',   pm.id,
                'batchId',   pm.batch_id,
                'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'heads',     pm.matched_heads,
                'avgWeight', b.avg_weight_kg,
                'price',     pm.reference_price_at_match,
                'region',    coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'status',    case when v_delivered then 'delivered' else 'active' end,
                'farmName',  case when v_revealed then o.legal_name else null end,
                'farmPhone', case when v_revealed then o.phone     else null end
            )
            order by pm.matched_at desc
        ), '[]'::jsonb)
        from public.pool_matches pm
        join public.batches b       on b.id = pm.batch_id
        join public.organizations o on o.id = b.organization_id
        left join public.regions r  on r.id = b.region_id
        where pm.pool_id = p_pool_id
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
                'lines',           coalesce(pr.accepted_categories, '[]'::jsonb),
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
