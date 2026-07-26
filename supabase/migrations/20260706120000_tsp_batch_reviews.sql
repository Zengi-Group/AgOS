-- AgOS · GAP-REVIEW-MOCK-01 · Отзывы о сделке — реальный гэп меньше, чем казалось.
-- ============================================================================
-- ИСПРАВЛЕНИЕ СОБСТВЕННОЙ ОШИБКИ (в этом же коммите): первая версия файла заводила
-- НОВУЮ таблицу batch_reviews + дублировала rpc_submit_review — не прочитав, что:
--   (а) supabase/migrations/20260622120000_tsp_canonical_rebind.sql:656 УЖЕ содержит
--       rpc_submit_review(p_batch_id,p_r1,p_r2,p_comment) — ТОЧНО тот контракт, который
--       зовёт useBatches.ts. Пишет в batches.notes.review (нет отдельной колонки в d02).
--       Повторное CREATE OR REPLACE с той же сигнатурой в более позднем файле молча
--       перезаписало бы работающую реализацию (Lesson L1) — убрано отсюда полностью.
--   (б) d02_tsp.sql уже содержит ПОЛНУЮ каноническую систему (review_dimensions,
--       deal_reviews, deal_review_dimension_scores, rpc_submit_deal_review, §7.13-7.15) —
--       но она НЕ вызывается ни одним фронтовым файлом (grep по src/ — 0 совпадений).
--       Полностью orphan, как и Success.tsx (см. ONB-SUCCESS-ORPHAN-01 в этом же коммите).
--       Не трогаем — конвергенция self-serve↔canon систем ревью — отдельный слайс,
--       не в скоупе точечного фикса.
--
-- РЕАЛЬНЫЙ ГЭП (сузился после перечитывания): rpc_submit_review УЖЕ пишет
-- notes.review — но fn_tsp_batch_json НИКОГДА не отдавал это поле обратно фронту.
-- Поэтому «Оставить отзыв» технически мог сохраниться на бэкенде, но кнопка
-- «Ваш отзыв сохранён» не персистилась после перезагрузки (batch.review терялся).
-- МПК-сторона (PoolMonitorModal.tsx myRating) — по-прежнему чистый локальный стейт,
-- это единственная часть, где действительно не было НИКАКОГО RPC.
--
-- Эта миграция делает ТОЛЬКО two additive вещи:
--   1. fn_tsp_batch_json += 'review' (читает уже существующее notes.review).
--   2. rpc_self_submit_mpk_review — НОВЫЙ RPC (имя не пересекается ни с чем существующим),
--      симметричный rpc_submit_review, пишет notes.mpk_review; rpc_get_pool_matches
--      += 'myRating' (читает его обратно).
-- Ни double-blind, ни дименшены каноничного deal_reviews здесь НЕ реализованы —
-- сознательное упрощение, тот же уровень, что и у уже существующего rpc_submit_review
-- (тоже без double-blind). Полная канон-реализация — через wiring на deal_reviews,
-- отдельная задача (не в скоупе «починить сломанную кнопку»).
-- ============================================================================

-- ── 1. fn_tsp_batch_json += review (уже сохранённое notes.review — просто отдать) ──
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
        -- GAP-REVIEW-MOCK-01: rpc_submit_review (20260622120000) уже пишет это в
        -- notes.review — просто не было отдано обратно фронту. Теперь персистится.
        'review',     meta->'review',
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
    where b.id = p_batch_id;

    return v;
end;
$$;
comment on function public.fn_tsp_batch_json(uuid) is
    'КАНОН d02 +Слайс 9 (S4) +GAP-REVIEW-MOCK-01 | Batch-форма для фронта. +matchedHeads/
     remainingHeads, state ''partial'', allocations[] (куски + даты этапов), батч-уровневые
     *AtIso, review (уже сохранённый rpc_submit_review — теперь читается обратно).
     Контакты по куску раскрыты по закрытию его пула. Сигнатура не меняется.';

-- ── 2. rpc_self_submit_mpk_review — НОВЫЙ RPC. МПК оценивает фермера. Симметричен
--      существующему rpc_submit_review (тот же уровень простоты: notes-based,
--      без double-blind — сознательное упрощение, см. заголовок файла). ─────────
create or replace function public.rpc_self_submit_mpk_review(
    p_batch_id uuid,
    p_r1       int,
    p_r2       int,
    p_comment  text default ''
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ok boolean;
begin
    if p_r1 is null or p_r1 not between 1 and 5 or p_r2 is null or p_r2 not between 1 and 5 then
        raise exception 'INVALID_INPUT: rating must be 1..5' using errcode = 'P0001';
    end if;

    -- Каллер должен владеть пулом хотя бы одного delivered-куска этого батча
    -- (без клиент-переданного org_id — не повторяет класс SEC-RPC-ORGTRUST-01).
    select exists (
        select 1
        from public.batch_allocations ba
        join public.pools po on po.id = ba.pool_id
        where ba.batch_id = p_batch_id
          and ba.status = 'delivered'
          and po.organization_id = any (public.fn_my_org_ids())
    ) into v_ok;

    if not v_ok then
        raise exception 'FORBIDDEN: no delivered allocation of batch % belongs to caller''s pool', p_batch_id
            using errcode = 'P0001';
    end if;

    update public.batches
    set notes = (public.fn_tsp_meta(notes) || jsonb_build_object(
                    'mpk_review', jsonb_build_object('r1', p_r1, 'r2', p_r2, 'comment', coalesce(p_comment, ''))))::text,
        updated_at = now()
    where id = p_batch_id;

    return true;
end;
$$;
comment on function public.rpc_self_submit_mpk_review(uuid, int, int, text) is
    'GAP-REVIEW-MOCK-01 | МПК оценивает фермера → batches.notes.mpk_review (тот же паттерн,
     что rpc_submit_review для фермерской стороны — без отдельной колонки/таблицы, без
     double-blind). Гейт: caller владеет пулом delivered-куска этого батча.';
revoke execute on function public.rpc_self_submit_mpk_review(uuid, int, int, text) from public, anon;
grant  execute on function public.rpc_self_submit_mpk_review(uuid, int, int, text) to authenticated;

-- ── 3. rpc_get_pool_matches += myRating (читает notes.mpk_review обратно МПК) ──
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
                'farmPhone', case when v_revealed then o.phone     else null end,
                -- GAP-REVIEW-MOCK-01: собственная оценка МПК о фермере персистится.
                'myRating', (public.fn_tsp_meta(b.notes)->'mpk_review'->>'r1')::int
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
    'КАНОН d02 +Слайс 9 (S3+S4) +GAP-REVIEW-MOCK-01 | Матчи пула по КУСКАМ (batch_allocations).
     matchId=allocation.id, heads/price с куска, status из статуса куска. +grade/breed/даты
     этапов + myRating (notes.mpk_review, персистит отзыв МПК о фермере). Контакты фермы
     после mpk_contact_revealed_at (D40). Сигнатура не меняется (P7).';
revoke execute on function public.rpc_get_pool_matches(uuid) from public, anon;
grant  execute on function public.rpc_get_pool_matches(uuid) to authenticated;
