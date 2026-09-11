-- AgOS · ARS-684 · Pool Monitor — двухмаршрутная read-model для rpc_get_pool_matches.
--
-- С 26 июля матч партии к пулу вернулся в модель «партия целиком привязана к строке
-- пула» (batches.pool_line_id), а rpc_get_pool_matches осталась в модели кусков
-- (batch_allocations): оператор комбината открывает набранный пул со статусом
-- «заполнен, контакты раскрыты» и видит ПУСТОЙ список поставщиков. Данные о сделке
-- в базе есть — их некому показать. Эта миграция расширяет read-model на оба
-- маршрута набора; ничего не пишет и не создаёт.
--
-- Авторитет при конфликте маршрутов (P2) — тот же порядок, что в
-- fn_ars_360_mpk_counterparty_ids (d02_tsp.sql:5632): есть batch_allocations —
-- источник они; нет — legacy-хвост batches.pool_line_id → pool_lines. Решается на
-- уровне КАЖДОЙ партии, а не всего пула целиком, поэтому смешанный пул показывает
-- обе группы без дублей (M-003, спек §I/O M-003).
--
-- Что этот файл НЕ делает:
--   * не включает дробление партий обратно — решение CEO от 26.07
--     (TSP-SLICE9-ROLLBACK-01) в силе; функция только читает уже записанное, ни
--     одной строки в batch_allocations не добавляет;
--   * не трогает d02_tsp.sql — 6 канон-функций домена принадлежат ARS-314, его
--     deploy.py --files d02_tsp.sql / --all не запускаются (FR-011); правка идёт
--     только новой миграцией поверх;
--   * не меняет сигнатуру rpc_get_pool_matches(uuid) и не убирает/переименовывает ни
--     одного поля ответа — поля только добавляются (FR-008, P7): плюс ровно одно —
--     'source' ('allocation' | 'batch'); существующая проекция myRating (ARS-360 /
--     ADR-353) сохранена как есть;
--   * не заводит новых таблиц, колонок или RPC (FR-012) и не трогает
--     rpc_name_registry / Dok 3.
--
-- Зависимости (уже задеплоены, применяются раньше по порядку миграций):
--   fn_my_org_ids            — d01_kernel.sql (переопределена в d07, тот же порядок)
--   fn_tsp_meta,
--   fn_tsp_cat_display,
--   fn_tsp_batch_grade        — supabase/migrations/20260622120000_tsp_canonical_rebind.sql
--   batches, batch_allocations,
--   pool_lines, pools,
--   pool_requests, organizations,
--   regions, deal_reviews     — d02_tsp.sql (все колонки уже существуют, ничего не добавляется)
--
-- Базовое (заменяемое) определение функции:
--   supabase/migrations/20260731074557_ars_360_review_convergence.sql:1177 (ARS-360).
--   Этот файл — create or replace поверх него; по имени файла (2026-09-10 > 2026-07-31)
--   применяется позже и становится действующим определением (L-1: единственная
--   версия create or replace function public.rpc_get_pool_matches в проекте, которая
--   применяется ПОСЛЕ этой, — отсутствует на момент написания).
--
-- Спек (подписан G2 2026-09-10): Docs/AGOS-TSP-PoolMonitor-ReadModel-ARS-684.md
-- Закрывает: FR-001, FR-002, FR-003, FR-004, FR-008, FR-009, FR-012 · M-001..M-005, M-014.

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
    if not coalesce(v_req.organization_id = any(public.fn_my_org_ids()), false) then
        raise exception 'FORBIDDEN: pool not owned by current user' using errcode = '42501';
    end if;

    v_revealed := v_pool.mpk_contact_revealed_at is not null;

    return (
        select coalesce(jsonb_agg(routed.row_json order by routed.row_sort_at desc), '[]'::jsonb)
        from (
            -- Route 1 (ARS-360, unchanged): chunk sold via batch_allocations.
            select
                a.matched_at as row_sort_at,
                jsonb_build_object(
                    'matchId',   a.id,
                    'batchId',   b.id,
                    'source',    'allocation',
                    'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                    'grade',     public.fn_tsp_batch_grade(b.id),
                    'breed',     coalesce(meta->>'breed', ''),
                    'heads',     a.heads,
                    'avgWeight', b.avg_weight_kg,
                    'price',     a.price_per_kg,
                    'region',    coalesce(meta->>'district', coalesce(r.name_ru, '')),
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
                    'myRating',  coalesce(
                        canonical_review.overall_score,
                        case
                            when jsonb_typeof(meta->'mpk_review') = 'object'
                             and (meta->'mpk_review'->>'r1') ~ '^[1-5]$'
                             and (meta->'mpk_review'->>'r2') ~ '^[1-5]$'
                                then (meta->'mpk_review'->>'r1')::int
                        end
                    )
                ) as row_json
            from public.batch_allocations a
            join public.batches b       on b.id = a.batch_id
            join public.organizations o on o.id = b.organization_id
            left join public.regions r  on r.id = b.region_id
            cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
            left join lateral (
                select dr.overall_score
                from public.deal_reviews dr
                where dr.batch_id = b.id
                  and dr.reviewer_org_id = v_req.organization_id
                  and dr.reviewer_role = 'mpk'
                limit 1
            ) canonical_review on true
            where a.pool_id = p_pool_id
              and a.status <> 'cancelled'

            union all

            -- Route 2 (ARS-684): batch bound directly to a pool_line (pre-Slice-9
            -- shape) and never split into allocations at all. The not-exists guard
            -- spans EVERY allocation row of the batch — any pool, any status,
            -- 'cancelled' included — because that is what the authority order of
            -- fn_ars_360_mpk_counterparty_ids actually is (d02_tsp.sql:5641 counts
            -- count(*) over all allocations of the batch and only then falls back to
            -- pool_line). Narrowing it to this pool and to non-cancelled rows looked
            -- equivalent and is not: fn_tsp_alloc_chunk writes batches.pool_line_id
            -- on the FIRST chunk (20260702160000:203) and the rollup never clears it
            -- ('нет активных кусков — оставляем как есть', 20260702190000:78), so a
            -- batch whose only chunk was cancelled still points here — and the
            -- narrow guard let it back in as a whole-batch row carrying the FULL
            -- b.heads, the very thing M-014 forbids. The same narrowing also split
            -- the routes apart: the read model said 'batch' while the review
            -- resolver said 'allocation' and refused with NO_DELIVERED_MPK_COUNTERPARTY.
            -- Mixed pools still show both groups (M-003): a batch sold in chunks is
            -- carried by Route 1, a batch never split by Route 2.
            -- Only 'cancelled' batches are excluded (M-014); 'expired' stays visible.
            select
                b.matched_at as row_sort_at,
                jsonb_build_object(
                    'matchId',   b.id,
                    'batchId',   b.id,
                    'source',    'batch',
                    'cat',       public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                    'grade',     public.fn_tsp_batch_grade(b.id),
                    'breed',     coalesce(meta->>'breed', ''),
                    'heads',     b.heads,
                    'avgWeight', b.avg_weight_kg,
                    'price',     coalesce(b.deal_price_per_kg, b.farmer_price_per_kg),
                    'region',    coalesce(meta->>'district', coalesce(r.name_ru, '')),
                    'status',    case when b.status = 'delivered'  then 'delivered'
                                      when b.status = 'dispatched' then 'dispatched'
                                      when b.status = 'confirmed'  then 'confirmed'
                                      else 'active' end,
                    'matchedAt',    b.matched_at,
                    'confirmedAt',  b.confirmed_at,
                    'dispatchedAt', b.dispatched_at,
                    'deliveredAt',  b.delivered_at,
                    'farmName',  case when v_revealed then o.legal_name else null end,
                    'farmPhone', case when v_revealed then o.phone     else null end,
                    'myRating',  coalesce(
                        canonical_review.overall_score,
                        case
                            when jsonb_typeof(meta->'mpk_review') = 'object'
                             and (meta->'mpk_review'->>'r1') ~ '^[1-5]$'
                             and (meta->'mpk_review'->>'r2') ~ '^[1-5]$'
                                then (meta->'mpk_review'->>'r1')::int
                        end
                    )
                ) as row_json
            from public.batches b
            join public.pool_lines pl   on pl.id = b.pool_line_id
            join public.organizations o on o.id = b.organization_id
            left join public.regions r  on r.id = b.region_id
            cross join lateral (select public.fn_tsp_meta(b.notes) as meta) m
            left join lateral (
                select dr.overall_score
                from public.deal_reviews dr
                where dr.batch_id = b.id
                  and dr.reviewer_org_id = v_req.organization_id
                  and dr.reviewer_role = 'mpk'
                limit 1
            ) canonical_review on true
            where pl.pool_id = p_pool_id
              and b.status <> 'cancelled'
              and not exists (
                  select 1 from public.batch_allocations a2
                  where a2.batch_id = b.id
              )
        ) routed
    );
end;
$$;

comment on function public.rpc_get_pool_matches(uuid) is
    'ARS-684: dual-route read model, extends ARS-360. Route 1 = batch_allocations
     (chunk sale, unchanged). Route 2 = legacy batches.pool_line_id fallback for a
     batch that has NO allocation row at all (any pool, any status) — the same
     allocations-first precedence as fn_ars_360_mpk_counterparty_ids, so the read
     model and the review resolver can never pick different routes for one batch.
     A mixed pool still shows both groups with no duplicates. Each row adds
     source = allocation or batch (FR-002); matchId stays unique. Signature and every
     existing response field are unchanged (P7) — myRating projection (ARS-360 /
     ADR-353) preserved as-is. No counterparty identity is exposed before
     pools.mpk_contact_revealed_at (D-M6-5/12, ст. 171 ЗК РК).';

revoke execute on function public.rpc_get_pool_matches(uuid) from public, anon;
grant execute on function public.rpc_get_pool_matches(uuid) to authenticated, service_role;
