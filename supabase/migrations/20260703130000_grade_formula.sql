-- ============================================================
-- 20260703130000 · A-GRADE — Формула сорта МПК (data-driven)
-- ============================================================
-- Зеркало d02_tsp.sql SECTION 8b (канон = d02, эта миграция = механизм применения
-- на живую базу, как вся июльская TSP-работа). Всё идемпотентно.
--
-- Единый источник правды для сорта партии (Премиум/Высшая/Первая/Вторая · КРС/МРС).
-- Раньше формула была захардкожена в 4 местах (tsp-utils.ts deriveMpkGrade,
-- mpk/types.ts MPK_CATS, fn_tsp_grade_id_from_fatness CASE, grade_standards).
-- Теперь: маппинг упитанность→сорт, floor-цены, порог веса Премиум и список
-- элитных пород редактируются из админки (/admin/grade-formula).
-- Сид повторяет текущие значения → поведение не меняется до правок админа.
-- ------------------------------------------------------------
create table if not exists public.livestock_grade_formula (
    id            uuid    primary key default gen_random_uuid(),
    sort_key      text    not null unique,   -- premium|vysshaya|pervaya|vtoraya|mrs_vyssh|mrs_perv
    species       text    not null,          -- КРС | МРС
    name_ru       text    not null,          -- 'КРС · Высшая'
    fatness_match text,                       -- Хорошая|Средняя|Ниже средней (NULL = premium overlay)
    grade_code    text    references public.grade_standards(code),  -- VS|S|NS (NULL для МРС)
    floor_price   int     not null,          -- ₸/кг — жёсткий минимум, блокирует публикацию
    recommended_price int,                    -- ₸/кг — индикативный ориентир (ст.171)
    elite_only    boolean not null default false,  -- premium: только элитные породы
    min_weight_kg int,                        -- premium: порог веса (450)
    elite_breeds  text[],                     -- premium: фрагменты названий элитных пород
    sort_order    int     not null default 0,
    is_active     boolean not null default true,
    updated_at    timestamptz not null default now()
);
comment on table public.livestock_grade_formula is
    'A-GRADE | Data-driven формула сорта МПК. Единый источник для фронта (deriveMpkGrade
     через rpc_get_grade_formula) и бэка (fn_tsp_grade_id_from_fatness). P8/P4.
     floor_price — жёсткий пол, блокирует публикацию (Legal 5.9: стандарт, не мандат цены).';

alter table public.livestock_grade_formula add column if not exists recommended_price int;
do $$ begin
    if not exists (select 1 from pg_constraint where conname = 'grade_formula_rec_price_positive') then
        alter table public.livestock_grade_formula
            add constraint grade_formula_rec_price_positive
            check (recommended_price is null or recommended_price > 0);
    end if;
end $$;

create index if not exists idx_grade_formula_active on public.livestock_grade_formula (is_active, sort_order);

alter table public.livestock_grade_formula enable row level security;
drop policy if exists "grade_formula_read_auth"  on public.livestock_grade_formula;
drop policy if exists "grade_formula_admin_write" on public.livestock_grade_formula;
create policy "grade_formula_read_auth"  on public.livestock_grade_formula for select using (auth.uid() is not null);
create policy "grade_formula_admin_write" on public.livestock_grade_formula for all    using (public.fn_is_admin());

-- Сид: 6 сортов = текущие захардкоженные значения (tsp-utils.ts + mpk/types.ts).
insert into public.livestock_grade_formula
    (sort_key, species, name_ru, fatness_match, grade_code, floor_price, recommended_price, elite_only, min_weight_kg, elite_breeds, sort_order)
values
    ('premium',   'КРС', 'КРС · Премиум', 'Хорошая',      'VS', 1850, 2000, true,  450,
        array['ангус','герефорд','абердин','вагю','wagyu','angus','hereford','шароле','лимузин','limousin','charolais','симмент'], 1),
    ('vysshaya',  'КРС', 'КРС · Высшая',  'Хорошая',      'VS', 1650, 1800, false, null, null, 2),
    ('pervaya',   'КРС', 'КРС · Первая',  'Средняя',      'S',  1500, 1650, false, null, null, 3),
    ('vtoraya',   'КРС', 'КРС · Вторая',  'Ниже средней', 'NS', 1350, 1500, false, null, null, 4),
    ('mrs_vyssh', 'МРС', 'МРС · Высшая',  'Хорошая',      null, 950,  1050, false, null, null, 5),
    ('mrs_perv',  'МРС', 'МРС · Первая',  'Средняя',      null, 850,  950,  false, null, null, 6)
on conflict (sort_key) do nothing;

update public.livestock_grade_formula set recommended_price = 2000 where sort_key = 'premium'   and recommended_price is null;
update public.livestock_grade_formula set recommended_price = 1800 where sort_key = 'vysshaya'  and recommended_price is null;
update public.livestock_grade_formula set recommended_price = 1650 where sort_key = 'pervaya'   and recommended_price is null;
update public.livestock_grade_formula set recommended_price = 1500 where sort_key = 'vtoraya'   and recommended_price is null;
update public.livestock_grade_formula set recommended_price = 1050 where sort_key = 'mrs_vyssh' and recommended_price is null;
update public.livestock_grade_formula set recommended_price = 950  where sort_key = 'mrs_perv'  and recommended_price is null;

-- AG-R1: rpc_get_grade_formula — публичное чтение формулы (фермер, МПК, админ).
drop function if exists public.rpc_get_grade_formula();
create or replace function public.rpc_get_grade_formula()
returns table (
    sort_key      text,
    species       text,
    name_ru       text,
    fatness_match text,
    grade_code    text,
    floor_price   int,
    recommended_price int,
    elite_only    boolean,
    min_weight_kg int,
    elite_breeds  text[],
    sort_order    int
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select gf.sort_key, gf.species, gf.name_ru, gf.fatness_match, gf.grade_code,
           gf.floor_price, gf.recommended_price, gf.elite_only, gf.min_weight_kg, gf.elite_breeds, gf.sort_order
      from public.livestock_grade_formula gf
     where gf.is_active = true
     order by gf.sort_order, gf.sort_key;
$$;

comment on function public.rpc_get_grade_formula() is
    'A-GRADE AG-R1 | Активная формула сорта для фронта (deriveMpkGrade / MPK_CATS).';

-- AG-1: rpc_admin_upsert_grade_formula — правка формулы из админки.
drop function if exists public.rpc_admin_upsert_grade_formula(text, text, text, int, int, text[], int);
create or replace function public.rpc_admin_upsert_grade_formula(
    p_sort_key          text,
    p_name_ru           text,
    p_fatness_match     text   default null,
    p_floor_price       int    default null,
    p_min_weight_kg     int    default null,
    p_elite_breeds      text[] default null,
    p_sort_order        int    default null,
    p_recommended_price int    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
    if not public.fn_is_admin() then
        return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
    end if;
    if p_sort_key is null or btrim(p_sort_key) = '' then
        return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT');
    end if;
    if not exists (select 1 from public.livestock_grade_formula where sort_key = p_sort_key) then
        return jsonb_build_object('ok', false, 'error', 'SORT_NOT_FOUND');
    end if;
    if p_floor_price is not null and p_floor_price <= 0 then
        return jsonb_build_object('ok', false, 'error', 'FLOOR_MUST_BE_POSITIVE');
    end if;

    update public.livestock_grade_formula gf
       set name_ru       = coalesce(nullif(btrim(p_name_ru), ''), gf.name_ru),
           fatness_match = case when p_fatness_match is null then gf.fatness_match
                                when btrim(p_fatness_match) = '' then null
                                else p_fatness_match end,
           floor_price   = coalesce(p_floor_price, gf.floor_price),
           recommended_price = case when p_recommended_price is null then gf.recommended_price
                                    when p_recommended_price <= 0 then null
                                    else p_recommended_price end,
           min_weight_kg = case when p_min_weight_kg is null then gf.min_weight_kg
                                when p_min_weight_kg <= 0 then null
                                else p_min_weight_kg end,
           elite_breeds  = coalesce(p_elite_breeds, gf.elite_breeds),
           sort_order    = coalesce(p_sort_order, gf.sort_order),
           updated_at    = now()
     where gf.sort_key = p_sort_key
    returning gf.id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

comment on function public.rpc_admin_upsert_grade_formula(text, text, text, int, int, text[], int, int) is
    'A-GRADE AG-1 | Admin правка формулы сорта по sort_key. floor_price>0, recommended_price>0 (≤0 очищает). Структура строки фиксирована.';

-- fn_tsp_grade_id_from_fatness — теперь читает маппинг из livestock_grade_formula
-- (базовые строки elite_only=false). Раньше — хардкод-CASE в миграции 20260701150000.
-- Нормализация упитанности совпадает: регистр/пробелы/пунктуация игнорируются.
create or replace function public.fn_tsp_grade_id_from_fatness(p_fatness text)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select gs.id
      from public.livestock_grade_formula gf
      join public.grade_standards gs on gs.code = gf.grade_code
     where gf.is_active = true
       and gf.elite_only = false
       and gf.grade_code is not null
       and regexp_replace(lower(coalesce(gf.fatness_match, '')), '[^a-zа-яё]', '', 'g')
         = regexp_replace(lower(coalesce(p_fatness, '')),       '[^a-zа-яё]', '', 'g')
     order by gf.sort_order
     limit 1;
$$;

comment on function public.fn_tsp_grade_id_from_fatness(text) is
    'A-GRADE | Упитанность → grade_standards.id (VS/S/NS) через livestock_grade_formula.
     КАНОН d02 (перевыпуск из миграции 20260701150000). Единая формула сорта с фронтом.';

grant execute on function public.rpc_get_grade_formula()        to authenticated;
grant execute on function public.rpc_admin_upsert_grade_formula(text, text, text, int, int, text[], int, int) to authenticated;
revoke execute on function public.rpc_get_grade_formula()        from public, anon;
revoke execute on function public.rpc_admin_upsert_grade_formula(text, text, text, int, int, text[], int, int) from public, anon;
revoke execute on function public.fn_tsp_grade_id_from_fatness(text) from public, anon;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
    ('rpc_get_grade_formula',          'A-GRADE AG-R1', null, 'd02_tsp.sql (Section 8b / A-GRADE)', 'Публичное чтение формулы сорта МПК для фронта'),
    ('rpc_admin_upsert_grade_formula', 'A-GRADE AG-1',  null, 'd02_tsp.sql (Section 8b / A-GRADE)', 'Admin правка формулы сорта (floor, упитанность, порог веса, породы)')
on conflict (sql_name) do update
    set dok3_name = excluded.dok3_name,
        notes     = excluded.notes,
        created_in = excluded.created_in;
