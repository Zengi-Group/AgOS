-- AgOS · БЕТА · Слайс 9 (S4) · ПОЛЯ ДЛЯ ДОКУМЕНТА СДЕЛКИ (deal doc).
-- ============================================================================
-- ФИЧА (CEO, 2026-07-02): когда пул собрался, фермер И МПК должны видеть ПОЛНУЮ
-- информацию о сделке и мочь скачать документ-спецификацию (печать → PDF).
-- Сейчас у обеих сторон данных «будто бы не полностью»:
--   • МПК (rpc_get_pool_matches) не отдавал сорт (grade), породу (breed) и даты
--     этапов куска (matched/confirmed/dispatched/delivered) — только cat/heads/price.
--   • Фермер (fn_tsp_batch_json.allocations) не отдавал даты этапов по каждому куску.
--
-- РЕШЕНИЕ (аддитивно, HS-2; сигнатуры RPC НЕ меняются, P7):
--   • rpc_get_pool_matches  += grade, breed, matchedAt, confirmedAt, dispatchedAt, deliveredAt.
--   • fn_tsp_batch_json.allocations += matchedAt, confirmedAt, dispatchedAt, deliveredAt.
-- Всё остальное в обеих функциях идентично 20260702190000 / 20260702170000.
-- Таймстемпы отдаём как есть (jsonb сериализует timestamptz в ISO8601) — фронт форматирует.
-- Зависимости: 20260702190000 (rpc_get_pool_matches, batch_allocations += dispatched/delivered_at),
-- 20260702170000 (fn_tsp_batch_json += allocations). Применять через SQL Editor. Идемпотентно.
-- ============================================================================


-- ── 1. fn_tsp_batch_json — allocations += даты этапов куска ────────────────────
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
        -- Слайс 9: прогресс частичной продажи.
        'matchedHeads',   coalesce(b.matched_heads, 0),
        'remainingHeads', greatest(b.heads - coalesce(b.matched_heads, 0), 0),
        -- Слайс 9 (+S4): список проданных кусков + даты этапов (для документа сделки).
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
        -- S4: батч-уровневые даты этапов (для таймлайна в документе сделки).
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
    where b.id = p_batch_id;

    return v;
end;
$$;
comment on function public.fn_tsp_batch_json(uuid) is
    'КАНОН d02 +Слайс 9 (S4) | Batch-форма для фронта. +matchedHeads/remainingHeads, state
     ''partial'', allocations[] (куски + даты этапов), батч-уровневые *AtIso — для документа
     сделки (deal doc). Контакты по куску раскрыты по закрытию его пула. Сигнатура не меняется.';


-- ── 2. rpc_get_pool_matches — += grade, breed, даты этапов куска ──────────────
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
                'matchId',   a.id,
                'batchId',   b.id,
                'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'grade',     public.fn_tsp_batch_grade(b.id),
                'breed',     coalesce(public.fn_tsp_meta(b.notes)->>'breed', ''),
                'heads',     a.heads,
                'avgWeight', b.avg_weight_kg,
                'price',     a.price_per_kg,
                'region',    coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'status',    case when a.status = 'delivered'  then 'delivered'
                                  when a.status = 'dispatched' then 'dispatched'
                                  when a.status = 'confirmed'  then 'confirmed'
                                  else 'active' end,
                'matchedAt',    a.matched_at,
                'confirmedAt',  a.confirmed_at,
                'dispatchedAt', a.dispatched_at,
                'deliveredAt',  a.delivered_at,
                'farmName',  case when v_revealed then o.legal_name else null end,
                'farmPhone', case when v_revealed then o.phone     else null end
            )
            order by a.matched_at desc
        ), '[]'::jsonb)
        from public.batch_allocations a
        join public.batches b       on b.id = a.batch_id
        join public.organizations o on o.id = b.organization_id
        left join public.regions r  on r.id = b.region_id
        where a.pool_id = p_pool_id
          and a.status <> 'cancelled'
    );
end;
$$;
comment on function public.rpc_get_pool_matches(uuid) is
    'КАНОН d02 +Слайс 9 (S3+S4) | Матчи пула по КУСКАМ (batch_allocations). matchId=allocation.id,
     heads/price с куска, status из статуса куска. +grade/breed/даты этапов — для документа сделки.
     Контакты фермы после mpk_contact_revealed_at (D40). Сигнатура не меняется (P7).';
revoke execute on function public.rpc_get_pool_matches(uuid) from anon;
grant  execute on function public.rpc_get_pool_matches(uuid) to authenticated;
