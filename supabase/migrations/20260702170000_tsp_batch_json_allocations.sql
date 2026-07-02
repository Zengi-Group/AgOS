-- AgOS · БЕТА · Слайс 9 (S2-адаптер) · fn_tsp_batch_json += частичная продажа.
-- ============================================================================
-- Фронт фермера (BatchScreen) читает партию через fn_tsp_batch_json. После Слайса 9
-- батч может быть распродан ЧАСТЯМИ (batch_allocations) — старый адаптер джойнил
-- ОДНУ строку пула (b.pool_line_id) и не показывал ни прогресс, ни покупателей по
-- кускам. Аддитивно добавляем:
--   • matchedHeads / remainingHeads — прогресс продажи;
--   • state 'partial' — маппинг из batches.status = 'partially_matched';
--   • allocations[] — список кусков {heads, price, status, buyer, buyerPhone}.
-- Контакт покупателя по куску раскрывается по факту закрытия ЕГО пула
-- (pools.mpk_contact_revealed_at) — та же логика D-M6-5/D40, но per-кусок.
-- Существующие поля (buyer/dealPrice/state и т.д.) СОХРАНЕНЫ. Сигнатура не меняется.
-- Зависимость: 20260702160000 (batch_allocations, matched_heads). Через SQL Editor.
-- ============================================================================

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
        -- Слайс 9: список проданных кусков (покупатель раскрыт по факту закрытия его пула).
        'allocations', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'heads',      a.heads,
                       'price',      a.price_per_kg,
                       'status',     a.status,
                       'buyer',      case when pa.mpk_contact_revealed_at is not null then oa.legal_name else null end,
                       'buyerPhone', case when pa.mpk_contact_revealed_at is not null then oa.phone     else null end
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
    'КАНОН d02 +Слайс 9 | Batch-форма для фронта. +matchedHeads/remainingHeads (прогресс
     частичной продажи), state ''partial'' (partially_matched), allocations[] (куски с
     покупателями, контакт раскрыт по закрытию пула куска). Гейт через RLS/адаптеры.';
