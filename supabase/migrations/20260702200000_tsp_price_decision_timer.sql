-- AgOS · БЕТА · Слайс C · ТАЙМЕР ЦЕНОВОГО РЕШЕНИЯ (D-PRICEREC-01, ускоренный).
-- ============================================================================
-- ФИЧА (CEO, 2026-07-02): если партия N времени не находит МПК (не смэтчилась),
-- система переводит её в awaiting_price_decision — фермеру показывается экран
-- «снизить цену (до рекомендованной или вручную)». Понизил → авто-ре-матч; если
-- снова не смэтчилось за те же N — система ЕЩЁ раз предложит снизить (цикл).
--
-- РЕШЕНИЯ:
--   • N — конфиг tsp_config.price_decision_after_minutes (ДЕФОЛТ 1 минута для теста;
--     меняется одним UPDATE / правкой дефолта). Раньше окно = 24ч (offer_window_hours).
--   • Триггерит для ЛЮБОЙ непроданной партии на рынке (published И offering,
--     matched_heads=0) — не только для offering с истёкшими офферами (старое поведение
--     ловило только broadcast-партии; партия без подходящего пула висела вечно).
--   • Отсчёт N идёт от «входа на рынок в текущем цикле» = coalesce(offering_at,
--     published_at, created_at). Сбрасывается при ре-публикации после снижения →
--     повторное предложение через N (цикл). Для этого rpc_lower_price теперь ставит
--     published_at = now() (а не coalesce), иначе таймер второго цикла не рестартовал.
--
-- Механика self-serve (нет pg_cron): фронт фермера лениво + поллингом (20с) зовёт
-- rpc_self_review_due_batches (уже подключено в useBatches). Сигнатуры RPC не меняются
-- (P7). Идемпотентно. Зависимость: 20260622120000 (rpc_lower_price, review_due).
-- Применять через SQL Editor.
-- ============================================================================


-- ── 0. tsp_config += price_decision_after_minutes (таймер решения) ────────────
alter table public.tsp_config
    add column if not exists price_decision_after_minutes int not null default 1;
alter table public.tsp_config drop constraint if exists chk_tsp_config_price_decision_after_minutes;
alter table public.tsp_config add  constraint chk_tsp_config_price_decision_after_minutes
    check (price_decision_after_minutes > 0);
comment on column public.tsp_config.price_decision_after_minutes is
    'Слайс C: через сколько минут непроданная партия (published/offering, matched_heads=0)
     переводится в awaiting_price_decision (экран снижения цены). Дефолт 1 мин (тест).';


-- ── 1. rpc_lower_price — сброс published_at для повторного цикла таймера ───────
-- Единственное изменение против 20260622120000: published_at = now() (было coalesce),
-- чтобы после снижения цены таймер ценового решения отсчитывался заново (цикл).
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

    v_current := coalesce(v_batch.farmer_price_per_kg,
                          public.fn_tsp_ref_price(v_batch.tsp_sku_id, v_batch.region_id));

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
        published_at               = now(),   -- рестарт таймера цикла (было coalesce)
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
    'КАНОН d02 | Слайс C B4 | Фермер понижает ask: clamp вниз на (current − price_step_down_amount)
     и >0; партия → published (published_at=now() — рестарт таймера ценового решения) для
     ре-broadcast (фронт затем зовёт rpc_self_auto_match_batch). Гейт fn_my_org_ids().';
revoke execute on function public.rpc_lower_price(uuid, numeric) from anon;
grant  execute on function public.rpc_lower_price(uuid, numeric) to authenticated;


-- ── 2. rpc_self_review_due_batches — таймер N-минут вместо истечения офферов ───
-- Против 20260622120000: переводит в awaiting_price_decision ЛЮБУЮ непроданную партию
-- на рынке (published|offering, matched_heads=0), провисевшую >= N минут (не только
-- offering с истёкшими офферами). N = tsp_config.price_decision_after_minutes (1 мин).
-- Отсчёт от coalesce(offering_at, published_at, created_at). Висящие офферы гасим.
create or replace function public.rpc_self_review_due_batches()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_moved int := 0;
    v_min   int;
begin
    if public.fn_current_user_id() is null then
        raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
    end if;

    select coalesce(price_decision_after_minutes, 1) into v_min
    from public.tsp_config where is_active = true limit 1;
    v_min := coalesce(v_min, 1);

    with my_due as (
        select b.id as batch_id
        from public.batches b
        where b.organization_id = any (public.fn_my_org_ids())
          and b.status in ('published', 'offering')
          and coalesce(b.matched_heads, 0) = 0
          and coalesce(b.offering_at, b.published_at, b.created_at) < now() - make_interval(mins => v_min)
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
        where b.id in (select batch_id from my_due) and b.status in ('published', 'offering')
        returning b.id
    ),
    ev as (
        insert into public.batch_events (batch_id, event_type, metadata, created_by)
        select m.id, 'price_decision_due',
               jsonb_build_object('trigger', 'review_due', 'after_minutes', v_min),
               public.fn_current_user_id()
        from moved m
        returning 1
    )
    select count(*) into v_moved from moved;

    return jsonb_build_object('moved', v_moved, 'afterMinutes', v_min);
end;
$$;
comment on function public.rpc_self_review_due_batches() is
    'КАНОН d02 | Слайс C (+таймер) | Продюсер ценового решения (нет pg_cron): непроданные
     партии на рынке (published|offering, matched_heads=0) старше N минут
     (tsp_config.price_decision_after_minutes, дефолт 1) → офферы expired, партия →
     awaiting_price_decision (экран снижения). Цикл: снизил цену → рестарт таймера. Гейт fn_my_org_ids().';
revoke execute on function public.rpc_self_review_due_batches() from anon;
grant  execute on function public.rpc_self_review_due_batches() to authenticated;
