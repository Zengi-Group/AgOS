-- ============================================================================
-- AgOS · Админ-обзор торговой площадки (read-only).
-- Админ видит ВСЕ батчи (партии ферм), ВСЕ пулы (заявки МПК) и ВСЕ сделки
-- (batch_allocations) с полными данными. Гейт — public.fn_is_admin().
--
-- У batches/pools/batch_allocations нет admin-read RLS-политики (только farmer/mpk),
-- поэтому обзор строится через security-definer RPC (канон-паттерн rpc_admin_*).
-- Решение (G2): админ видит контакты сторон ВСЕГДА (двойная слепота D40 — только
-- между контрагентами, не против оператора платформы). Только чтение, без write.
-- P7: существующие RPC (rpc_get_my_pools/rpc_get_pool_matches) НЕ трогаем.
-- Применять через Supabase SQL Editor. Идемпотентно.
-- ============================================================================


-- ── 1. rpc_admin_tsp_batches — все партии ферм (AdminBatch[]) ─────────────────
create or replace function public.rpc_admin_tsp_batches()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = 'P0001';
    end if;
    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'id',             b.id,
                'farmName',       fo.legal_name,
                'farmPhone',      fo.phone,
                'cat',            public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'grade',          public.fn_tsp_batch_grade(b.id),
                'breed',          coalesce(public.fn_tsp_meta(b.notes)->>'breed', ''),
                'heads',          b.heads,
                'matchedHeads',   coalesce(b.matched_heads, 0),
                'remainingHeads', greatest(b.heads - coalesce(b.matched_heads, 0), 0),
                'avgWeight',      b.avg_weight_kg,
                'price',          coalesce(b.farmer_price_per_kg, public.fn_tsp_ref_price(b.tsp_sku_id, b.region_id)),
                'dealPrice',      b.deal_price_per_kg,
                'status',         b.status,
                'region',         coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'poolId',         po.id,
                'createdAtIso',   b.created_at,
                'publishedAtIso', b.published_at,
                'matchedAtIso',   b.matched_at,
                'deliveredAtIso', b.delivered_at
            )
            order by b.created_at desc
        ), '[]'::jsonb)
        from public.batches b
        join public.organizations fo on fo.id = b.organization_id
        left join public.regions r      on r.id = b.region_id
        left join public.pool_lines pl  on pl.id = b.pool_line_id
        left join public.pools po       on po.id = pl.pool_id
    );
end;
$$;
comment on function public.rpc_admin_tsp_batches() is
    'Админ-обзор ТСП | Все батчи ферм (read-only). Гейт fn_is_admin(). Контакты фермы видны
     всегда (админ — оператор платформы). Сигнатура read-only, схему не меняет.';
revoke execute on function public.rpc_admin_tsp_batches() from anon;
grant  execute on function public.rpc_admin_tsp_batches() to authenticated;


-- ── 2. rpc_admin_tsp_pools — все пулы МПК (AdminPool[]) ───────────────────────
create or replace function public.rpc_admin_tsp_pools()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = 'P0001';
    end if;
    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'id',              p.id,
                'mpkName',         mo.legal_name,
                'mpkPhone',        mo.phone,
                'status',          p.status,
                'targetHeads',     p.target_heads,
                'matchedHeads',    p.matched_heads,
                'region',          coalesce(r.name_ru, 'Все регионы'),
                'targetMonthIso',  to_char(pr.target_month, 'YYYY-MM-DD'),
                'createdAtIso',    p.created_at,
                'contactRevealed', (p.mpk_contact_revealed_at is not null),
                'lines',           coalesce((
                    select jsonb_agg(
                        jsonb_build_object('code', pl.category_label, 'price', pl.mpk_price_per_kg)
                        order by pl.mpk_price_per_kg desc
                    )
                    from public.pool_lines pl
                    where pl.pool_id = p.id and pl.is_active = true
                ), '[]'::jsonb)
            )
            order by p.created_at desc
        ), '[]'::jsonb)
        from public.pools p
        join public.pool_requests pr  on pr.id = p.pool_request_id
        left join public.organizations mo on mo.id = pr.organization_id
        left join public.regions r        on r.id = pr.region_id
    );
end;
$$;
comment on function public.rpc_admin_tsp_pools() is
    'Админ-обзор ТСП | Все пулы (read-only) с реквизитами МПК (через pool_request.organization_id),
     строками и прогрессом. Гейт fn_is_admin(). Схему не меняет.';
revoke execute on function public.rpc_admin_tsp_pools() from anon;
grant  execute on function public.rpc_admin_tsp_pools() to authenticated;


-- ── 3. rpc_admin_tsp_deals — все сделки (batch_allocations, AdminDeal[]) ──────
create or replace function public.rpc_admin_tsp_deals()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin only' using errcode = 'P0001';
    end if;
    return (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'id',             a.id,
                'batchId',        a.batch_id,
                'poolId',         a.pool_id,
                'farmName',       fo.legal_name,
                'farmPhone',      fo.phone,
                'mpkName',        mo.legal_name,
                'mpkPhone',       mo.phone,
                'cat',            public.fn_tsp_cat_display(b.notes, b.tsp_sku_id),
                'grade',          public.fn_tsp_batch_grade(b.id),
                'breed',          coalesce(public.fn_tsp_meta(b.notes)->>'breed', ''),
                'heads',          a.heads,
                'avgWeight',      b.avg_weight_kg,
                'price',          a.price_per_kg,
                'sum',            case when b.avg_weight_kg is not null
                                       then round(a.heads * b.avg_weight_kg * a.price_per_kg)
                                       else null end,
                'status',         a.status,
                'via',            a.via,
                'region',         coalesce(public.fn_tsp_meta(b.notes)->>'district', coalesce(r.name_ru, '')),
                'matchedAtIso',   a.matched_at,
                'confirmedAtIso', a.confirmed_at,
                'dispatchedAtIso', a.dispatched_at,
                'deliveredAtIso', a.delivered_at
            )
            order by a.matched_at desc
        ), '[]'::jsonb)
        from public.batch_allocations a
        join public.batches b        on b.id = a.batch_id
        join public.organizations fo on fo.id = b.organization_id
        join public.pools p          on p.id = a.pool_id
        join public.pool_requests pr on pr.id = p.pool_request_id
        left join public.organizations mo on mo.id = pr.organization_id
        left join public.regions r        on r.id = b.region_id
    );
end;
$$;
comment on function public.rpc_admin_tsp_deals() is
    'Админ-обзор ТСП | Все сделки-куски (batch_allocations, read-only): обе стороны раскрыты,
     голов/цена/сумма/статус/даты этапов. Гейт fn_is_admin(). Схему не меняет.';
revoke execute on function public.rpc_admin_tsp_deals() from anon;
grant  execute on function public.rpc_admin_tsp_deals() to authenticated;


-- ── 4. Реестр RPC (для трассируемости) ───────────────────────────────────────
insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes)
values
  ('rpc_admin_tsp_batches', null, '20260702220000_admin_tsp_marketplace_read.sql', 'Admin read-only: all batches'),
  ('rpc_admin_tsp_pools',   null, '20260702220000_admin_tsp_marketplace_read.sql', 'Admin read-only: all pools'),
  ('rpc_admin_tsp_deals',   null, '20260702220000_admin_tsp_marketplace_read.sql', 'Admin read-only: all deals (batch_allocations)')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;
