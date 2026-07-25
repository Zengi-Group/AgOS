-- =============================================================================
-- d11_norms.sql — Нормативно-технологический справочник КРС (НТС-КРС)
-- =============================================================================
-- Canonical domain file for farm norms reference data.
-- Source: Zengi.Farm_Model "Справочник" sheet (FAC-/PAD-/SCN-/REG-/COEF- codes).
-- Apply after d09_consulting.sql.
-- P8: все нормативы хранятся в БД; обновление = data update, не code deploy.
-- =============================================================================


-- ==========================
-- SECTION 1 · TABLE
-- ==========================

create table if not exists public.farm_norms_ref (
    id          serial      primary key,
    category    text        not null
                                check (category in (
                                    'facility_norms',       -- FAC-* помещения и сооружения
                                    'paddock_norms',        -- PAD-* нормы выгульных площадок
                                    'calving_scenarios',    -- SCN-* сценарии отёла
                                    'regional_pasture_norms', -- REG-* пастбищный блок
                                    'capex_coefficients'    -- COEF-* коэффициенты CAPEX
                                )),
    code        text        not null,
    data        jsonb       not null,
    valid_from  date        not null default current_date,
    valid_to    date,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    constraint uq_farm_norms_ref unique (category, code, valid_from)
);

comment on table public.farm_norms_ref is
    'НТС-КРС: нормативно-технологический справочник репродуктора мясного КРС РК.
     P8: нормативы из БД через XLOOKUP-аналоги (JSONB). Временна́я валидность.
     Категории: facility_norms / paddock_norms / calving_scenarios /
                regional_pasture_norms / capex_coefficients.';

create index if not exists idx_farm_norms_category
    on public.farm_norms_ref (category)
    where valid_to is null;


-- ==========================
-- SECTION 2 · RPC FUNCTIONS
-- ==========================

-- RPC-NORMS-1: список нормативов помещений (FAC-*)
create or replace function public.rpc_list_facility_norms()
returns table (code text, data jsonb, valid_from date, valid_to date)
language sql stable security definer
as $$
    select code, data, valid_from, valid_to
    from public.farm_norms_ref
    where category = 'facility_norms'
      and valid_from <= current_date
      and (valid_to is null or valid_to > current_date)
    order by code;
$$;

comment on function public.rpc_list_facility_norms() is
    'RPC-NORMS-1: список активных нормативов помещений и сооружений (FAC-001..FAC-020).';

-- RPC-NORMS-2: список нормативов площадок (PAD-*)
create or replace function public.rpc_list_paddock_norms()
returns table (code text, data jsonb, valid_from date, valid_to date)
language sql stable security definer
as $$
    select code, data, valid_from, valid_to
    from public.farm_norms_ref
    where category = 'paddock_norms'
      and valid_from <= current_date
      and (valid_to is null or valid_to > current_date)
    order by code;
$$;

comment on function public.rpc_list_paddock_norms() is
    'RPC-NORMS-2: список активных нормативов выгульно-кормовых площадок (PAD-001..PAD-008).';

-- RPC-NORMS-3: список сценариев отёла (SCN-*)
create or replace function public.rpc_list_calving_scenarios()
returns table (code text, data jsonb, valid_from date, valid_to date)
language sql stable security definer
as $$
    select code, data, valid_from, valid_to
    from public.farm_norms_ref
    where category = 'calving_scenarios'
      and valid_from <= current_date
      and (valid_to is null or valid_to > current_date)
    order by code;
$$;

comment on function public.rpc_list_calving_scenarios() is
    'RPC-NORMS-3: список активных сценариев отёла (SCN-WIN, SCN-SUM).';

-- RPC-NORMS-4: список пастбищных норм по регионам (REG-*)
create or replace function public.rpc_list_regional_pasture_norms()
returns table (code text, data jsonb, valid_from date, valid_to date)
language sql stable security definer
as $$
    select code, data, valid_from, valid_to
    from public.farm_norms_ref
    where category = 'regional_pasture_norms'
      and valid_from <= current_date
      and (valid_to is null or valid_to > current_date)
    order by code;
$$;

comment on function public.rpc_list_regional_pasture_norms() is
    'RPC-NORMS-4: список активных региональных пастбищных норм (REG-*), 17 областей РК.';

-- RPC-NORMS-5: список коэффициентов CAPEX (COEF-*)
create or replace function public.rpc_list_capex_coefficients()
returns table (code text, data jsonb, valid_from date, valid_to date)
language sql stable security definer
as $$
    select code, data, valid_from, valid_to
    from public.farm_norms_ref
    where category = 'capex_coefficients'
      and valid_from <= current_date
      and (valid_to is null or valid_to > current_date)
    order by code;
$$;

comment on function public.rpc_list_capex_coefficients() is
    'RPC-NORMS-5: список активных коэффициентов CAPEX (COEF-001..COEF-008).';

-- RPC-NORMS-6: admin upsert (добавление/обновление норматива)
drop function if exists public.rpc_upsert_farm_norm(p_category text, p_code text, p_data jsonb, p_valid_from date);
create or replace function public.rpc_upsert_farm_norm(
    p_category  text,
    p_code      text,
    p_data      jsonb,
    p_valid_from date default current_date
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
    -- SEC-NORMS-UPSERT-01 (2026-07-25): гейта не было — SECURITY DEFINER-запись в
    -- ГЛОБАЛЬНЫЙ справочник (кормит CAPEX/консалтинг) была доступна любому, кому
    -- Supabase выдал execute по умолчанию (Trap 2b). Комментарий функции всегда
    -- заявлял «admin upsert» — здесь заявленное намерение стало исполняемым.
    -- Образец: d09_consulting.sql rpc_upsert_infrastructure_norm.
    if not public.fn_is_admin() then
        raise exception 'ADMIN_REQUIRED' using errcode = 'P0001';
    end if;

    insert into public.farm_norms_ref (category, code, data, valid_from)
    values (p_category, p_code, p_data, p_valid_from)
    on conflict (category, code, valid_from)
    do update set data = excluded.data, updated_at = now();
end;
$$;

-- ACL (SEC-NORMS-UPSERT-01): у d11 не было НИ ОДНОГО grant/revoke — функции жили на
-- default privileges Supabase (authenticated execute). Читающие справочники остаются
-- доступны приложению (P8: стандарты = данные), запись — только admin через гейт выше.
-- ВАЖНО: у upsert грант authenticated СОХРАНЯЕТСЯ — админ в Supabase ходит именно
-- ролью authenticated, авторизацию даёт fn_is_admin() в теле. revoke от authenticated
-- здесь убил бы админский путь (ровно инцидент ARS-311: revoke без сверки вызывающих).
grant  execute on function public.rpc_upsert_farm_norm(text, text, jsonb, date) to authenticated;
revoke execute on function public.rpc_upsert_farm_norm(text, text, jsonb, date) from public, anon;
grant  execute on function public.rpc_list_facility_norms()         to authenticated;
grant  execute on function public.rpc_list_paddock_norms()          to authenticated;
grant  execute on function public.rpc_list_calving_scenarios()      to authenticated;
grant  execute on function public.rpc_list_regional_pasture_norms() to authenticated;
grant  execute on function public.rpc_list_capex_coefficients()     to authenticated;
revoke execute on function public.rpc_list_facility_norms()         from public, anon;
revoke execute on function public.rpc_list_paddock_norms()          from public, anon;
revoke execute on function public.rpc_list_calving_scenarios()      from public, anon;
revoke execute on function public.rpc_list_regional_pasture_norms() from public, anon;
revoke execute on function public.rpc_list_capex_coefficients()     from public, anon;

comment on function public.rpc_upsert_farm_norm(text, text, jsonb, date) is
    'RPC-NORMS-6: admin upsert норматива. P7: additive, не меняет существующие записи если valid_from отличается.';


-- ==========================
-- SECTION 3 · RPC REGISTRY
-- ==========================

-- BUG FIX (deploy 2026-07-07): rpc_name_registry has no rpc_id/canonical_name/
-- alias_of/source_file/description columns — that's a pre-D-NEW-A shape. Live
-- columns are sql_name/dok3_name/dok5_tool_name/created_in/notes (supabase_call
-- is trigger-derived from sql_name, not client-supplied — matches the pattern
-- used by every other rpc_name_registry insert in d02/d05/d09).
insert into public.rpc_name_registry (sql_name, created_in, notes)
values
    ('rpc_list_facility_norms',         'd11_norms.sql', 'RPC-NORMS-1: List active facility norms (FAC-*)'),
    ('rpc_list_paddock_norms',          'd11_norms.sql', 'RPC-NORMS-2: List active paddock norms (PAD-*)'),
    ('rpc_list_calving_scenarios',      'd11_norms.sql', 'RPC-NORMS-3: List active calving scenarios (SCN-*)'),
    ('rpc_list_regional_pasture_norms', 'd11_norms.sql', 'RPC-NORMS-4: List active regional pasture norms (REG-*)'),
    ('rpc_list_capex_coefficients',     'd11_norms.sql', 'RPC-NORMS-5: List active CAPEX coefficients (COEF-*)'),
    ('rpc_upsert_farm_norm',            'd11_norms.sql', 'RPC-NORMS-6: Admin upsert farm norm row')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;


-- ==========================
-- SECTION 4 · SEED DATA
-- ==========================

-- ~~ 1. Нормы помещений и сооружений (FAC-001..FAC-020) ~~
insert into public.farm_norms_ref (category, code, data, valid_from) values
('facility_norms', 'FAC-001', '{"name_ru":"Коровник закрытый","type":"Закрытое","animal_category":"Коровы мясные","unit":"гол.","area_driver":"Поголовье коров","area_per_unit_m2":8,"min_width_m":3,"min_height_no_bedding_m":3,"min_height_with_bedding_m":4,"scenario_dependent":true,"allowed_materials":["MAT-001","MAT-003","MAT-004"]}', '2026-01-01'),
('facility_norms', 'FAC-002', '{"name_ru":"Коровник полуоткрытый (навес)","type":"Полуоткрытое","animal_category":"Коровы мясные","unit":"гол.","area_driver":"Поголовье коров","area_per_unit_m2":4.5,"min_width_m":3,"min_height_no_bedding_m":3,"min_height_with_bedding_m":4,"scenario_dependent":true,"allowed_materials":["MAT-003","MAT-002"]}', '2026-01-01'),
('facility_norms', 'FAC-003', '{"name_ru":"Помещение для отёла (родильное)","type":"Закрытое","animal_category":"Коровы на отёле","unit":"гол.одн.","area_driver":"10–15% маточного погол.","area_per_unit_m2":9,"min_width_m":3,"min_height_no_bedding_m":3,"min_height_with_bedding_m":4,"scenario_dependent":true,"allowed_materials":["MAT-001","MAT-003","MAT-004"]}', '2026-01-01'),
('facility_norms', 'FAC-004', '{"name_ru":"Денник индивидуальный","type":"Внутри FAC-003","animal_category":"Корова+телёнок","unit":"денник","area_driver":"Внутри FAC-003","area_per_unit_m2":9,"min_width_m":3,"min_height_no_bedding_m":3,"min_height_with_bedding_m":4,"scenario_dependent":true,"allowed_materials":[]}', '2026-01-01'),
('facility_norms', 'FAC-005', '{"name_ru":"Телятник (до отъёма)","type":"Закр./полуоткр.","animal_category":"Телята 0–6 мес.","unit":"гол.","area_driver":"Поголовье телят","area_per_unit_m2":2.5,"min_width_m":2.5,"min_height_no_bedding_m":3,"min_height_with_bedding_m":3.5,"scenario_dependent":true,"allowed_materials":["MAT-001","MAT-003","MAT-002"]}', '2026-01-01'),
('facility_norms', 'FAC-006', '{"name_ru":"Помещение тёлок/нетелей","type":"Закр./полуоткр.","animal_category":"Тёлки/нетели","unit":"гол.","area_driver":"Поголовье тёлок","area_per_unit_m2":4,"min_width_m":3,"min_height_no_bedding_m":3,"min_height_with_bedding_m":4,"scenario_dependent":"Частично","allowed_materials":["MAT-001","MAT-003","MAT-002"]}', '2026-01-01'),
('facility_norms', 'FAC-007', '{"name_ru":"Помещение быков-производит.","type":"Закрытое","animal_category":"Быки","unit":"гол.","area_driver":"Кол-во быков","area_per_unit_m2":9,"min_width_m":3.5,"min_height_no_bedding_m":3,"min_height_with_bedding_m":4,"scenario_dependent":false,"allowed_materials":["MAT-001","MAT-003"]}', '2026-01-01'),
('facility_norms', 'FAC-008', '{"name_ru":"Выгул-корм. площадка (тв. покр.)","type":"Открытая","animal_category":"Коровы+телята","unit":"гол.","area_driver":"Поголовье","area_per_unit_m2":8,"scenario_dependent":false,"allowed_materials":["MAT-011","MAT-012"]}', '2026-01-01'),
('facility_norms', 'FAC-009', '{"name_ru":"Выгул-корм. площадка (без покр.)","type":"Открытая","animal_category":"Коровы+телята","unit":"гол.","area_driver":"Поголовье","area_per_unit_m2":20,"scenario_dependent":false,"allowed_materials":["MAT-013"]}', '2026-01-01'),
('facility_norms', 'FAC-010', '{"name_ru":"Выгул откорм (тв. покр.)","type":"Открытая","animal_category":"Откорм. скот","unit":"гол.","area_driver":"Погол. откорма","area_per_unit_m2":5,"scenario_dependent":false,"allowed_materials":["MAT-011","MAT-012"]}', '2026-01-01'),
('facility_norms', 'FAC-011', '{"name_ru":"Выгул откорм (без покр.)","type":"Открытая","animal_category":"Откорм. скот","unit":"гол.","area_driver":"Погол. откорма","area_per_unit_m2":15,"scenario_dependent":false,"allowed_materials":["MAT-013"]}', '2026-01-01'),
('facility_norms', 'FAC-012', '{"name_ru":"Ветпункт / изолятор","type":"Закрытое","animal_category":"Все","unit":"объект","area_driver":"1 на ферму","scenario_dependent":false,"allowed_materials":["MAT-001","MAT-003"]}', '2026-01-01'),
('facility_norms', 'FAC-013', '{"name_ru":"Карантин","type":"Закрытое","animal_category":"Карантинные","unit":"гол.","area_driver":"2–5% поголовья","area_per_unit_m2":8,"min_width_m":3,"min_height_no_bedding_m":3,"scenario_dependent":false,"allowed_materials":["MAT-001","MAT-003"]}', '2026-01-01'),
('facility_norms', 'FAC-014', '{"name_ru":"Раскол / загон обработки","type":"Открытое","animal_category":"Все","unit":"объект","area_driver":"1 компл. на ферму","scenario_dependent":false,"allowed_materials":["MAT-002"]}', '2026-01-01'),
('facility_norms', 'FAC-015', '{"name_ru":"Сенохранилище / навес кормов","type":"Полуоткр./откр.","animal_category":"—","unit":"тн кормов","area_driver":"Годовая потр. в кормах","scenario_dependent":false,"allowed_materials":["MAT-003","MAT-002"]}', '2026-01-01'),
('facility_norms', 'FAC-016', '{"name_ru":"Силосная яма / траншея","type":"Открытое","animal_category":"—","unit":"тн силоса","area_driver":"Годовая потребность","scenario_dependent":false,"allowed_materials":["MAT-014"]}', '2026-01-01'),
('facility_norms', 'FAC-017', '{"name_ru":"Водопойный пункт / поилки","type":"Оборуд.","animal_category":"Все","unit":"шт.","area_driver":"1 поилка на 40 гол.","scenario_dependent":false,"allowed_materials":[]}', '2026-01-01'),
('facility_norms', 'FAC-018', '{"name_ru":"Навозохранилище","type":"Открытое","animal_category":"—","unit":"м³","area_driver":"Погол. × накопл./гол.","scenario_dependent":false,"allowed_materials":["MAT-014","MAT-012"]}', '2026-01-01'),
('facility_norms', 'FAC-019', '{"name_ru":"Дезбарьер","type":"Инфра","animal_category":"—","unit":"шт.","area_driver":"1 на въезд","scenario_dependent":false,"allowed_materials":[]}', '2026-01-01'),
('facility_norms', 'FAC-020', '{"name_ru":"Ограждение периметра","type":"Инфра","animal_category":"—","unit":"п.м.","area_driver":"Периметр территории","scenario_dependent":false,"allowed_materials":["MAT-002"]}', '2026-01-01')
on conflict do nothing;

-- ~~ 2. Нормы выгульно-кормовых площадок (PAD-001..PAD-008) ~~
insert into public.farm_norms_ref (category, code, data, valid_from) values
('paddock_norms', 'PAD-001', '{"animal_category":"Коровы мясные с подс. телятами","surface_type":"Твёрдое","norm_m2_per_head":20,"min_m2":6,"max_m2":10,"source":"НТП-1-99 (ref)","user_override":true}', '2026-01-01'),
('paddock_norms', 'PAD-002', '{"animal_category":"Коровы мясные с подс. телятами","surface_type":"Без покрытия","norm_m2_per_head":22.5,"min_m2":20,"max_m2":25,"source":"НТП-1-99 (ref)","user_override":true}', '2026-01-01'),
('paddock_norms', 'PAD-003', '{"animal_category":"Откормочный скот","surface_type":"Твёрдое","norm_m2_per_head":5,"min_m2":4,"max_m2":6,"source":"НТП-1-99 (ref)","user_override":true}', '2026-01-01'),
('paddock_norms', 'PAD-004', '{"animal_category":"Откормочный скот","surface_type":"Без покрытия","norm_m2_per_head":15,"min_m2":12,"max_m2":18,"source":"НТП-1-99 (ref)","user_override":true}', '2026-01-01'),
('paddock_norms', 'PAD-005', '{"animal_category":"Тёлки / нетели","surface_type":"Твёрдое","norm_m2_per_head":5,"min_m2":4,"max_m2":7,"source":"Практика","user_override":true}', '2026-01-01'),
('paddock_norms', 'PAD-006', '{"animal_category":"Тёлки / нетели","surface_type":"Без покрытия","norm_m2_per_head":15,"min_m2":12,"max_m2":20,"source":"Практика","user_override":true}', '2026-01-01'),
('paddock_norms', 'PAD-007', '{"animal_category":"Быки-производители","surface_type":"Твёрдое","norm_m2_per_head":25,"min_m2":8,"max_m2":12,"source":"Практика","user_override":true}', '2026-01-01'),
('paddock_norms', 'PAD-008', '{"animal_category":"Телята (после отъёма)","surface_type":"Без покрытия","norm_m2_per_head":8,"min_m2":5,"max_m2":10,"source":"Практика","user_override":true}', '2026-01-01')
on conflict do nothing;

-- ~~ 3. Сценарии отёла (SCN-WIN, SCN-SUM) ~~
insert into public.farm_norms_ref (category, code, data, valid_from) values
('calving_scenarios', 'SCN-WIN', '{"name_ru":"Зимний отёл","period":"Янв–Мар","enclosed_demand":"Max: 100% в помещении","share_enclosed_pct":"60–80%","share_semi_open_pct":"10–20%","share_open_pct":"10–20%","bedding_notes":"Глубокая подстилка обязат.; +1 м высоты","capex_impact":"Высокий (утепл., энергия)","opex_impact":"Высокий (отопл., подстилка, корма)"}', '2026-01-01'),
('calving_scenarios', 'SCN-SUM', '{"name_ru":"Летний отёл","period":"Май–Июл","enclosed_demand":"Min: на пастбище/площадке","share_enclosed_pct":"20–40%","share_semi_open_pct":"30–40%","share_open_pct":"30–40%","bedding_notes":"Минимальна / не требуется","capex_impact":"Ниже (меньше утеплённых)","opex_impact":"Ниже (пастбище снижает корма)"}', '2026-01-01')
on conflict do nothing;

-- ~~ 4. Пастбищный блок — региональные нормы (REG-*), 17 областей РК ~~
insert into public.farm_norms_ref (category, code, data, valid_from) values
('regional_pasture_norms', 'REG-SKO', '{"region_name":"Северо-Казахстанская","natural_zone":"Лесостепная","base_ha_per_head":3.5,"grazing_months":"5","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-KOS', '{"region_name":"Костанайская","natural_zone":"Степная","base_ha_per_head":5.5,"grazing_months":"5–6","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-AKM', '{"region_name":"Акмолинская","natural_zone":"Лесостепная/степная","base_ha_per_head":4.5,"grazing_months":"5","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-PAV', '{"region_name":"Павлодарская","natural_zone":"Степная/полупустынная","base_ha_per_head":6,"grazing_months":"5","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-ABY', '{"region_name":"Абайская","natural_zone":"Степная","base_ha_per_head":5.5,"grazing_months":"5","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-VKO', '{"region_name":"Восточно-Казахстанская","natural_zone":"Лесостепная/горная","base_ha_per_head":3.5,"grazing_months":"5–6","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-KAR', '{"region_name":"Карагандинская","natural_zone":"Степная/полупустынная","base_ha_per_head":6,"grazing_months":"5","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-ULY', '{"region_name":"Улытауская","natural_zone":"Полупустынная","base_ha_per_head":8,"grazing_months":"5","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-AKT', '{"region_name":"Актюбинская","natural_zone":"Полупустынная/степная","base_ha_per_head":7,"grazing_months":"5–6","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-ZKO', '{"region_name":"Западно-Казахстанская","natural_zone":"Степная","base_ha_per_head":5,"grazing_months":"5–6","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-ATY', '{"region_name":"Атырауская","natural_zone":"Полупустынная/пустынная","base_ha_per_head":10,"grazing_months":"6–7","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-MAN', '{"region_name":"Мангистауская","natural_zone":"Пустынная","base_ha_per_head":15,"grazing_months":"8–9","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-ZHA', '{"region_name":"Жамбылская","natural_zone":"Полупустынная/предгорная","base_ha_per_head":6,"grazing_months":"6–7","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-TUR', '{"region_name":"Туркестанская","natural_zone":"Полупуст./пустынная","base_ha_per_head":10,"grazing_months":"7–8","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-KYZ', '{"region_name":"Кызылординская","natural_zone":"Пустынная","base_ha_per_head":12,"grazing_months":"7–8","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-ALM', '{"region_name":"Алматинская","natural_zone":"Предгорная/горная","base_ha_per_head":3,"grazing_months":"6–7","needs_local_plan":true}', '2026-01-01'),
('regional_pasture_norms', 'REG-ZHE', '{"region_name":"Жетысуская","natural_zone":"Предгорная/степная","base_ha_per_head":4,"grazing_months":"6","needs_local_plan":true}', '2026-01-01')
on conflict do nothing;

-- ~~ 5. Коэффициенты CAPEX (COEF-001..COEF-008) ~~
insert into public.farm_norms_ref (category, code, data, valid_from) values
('capex_coefficients', 'COEF-001', '{"name_ru":"К утепления (зима)","description":"Удорожание при зимнем варианте строительства","default_value":1.3,"min_value":1.0,"max_value":1.8,"unit":"множ.","applies_when":"Зимний сценарий, закрытые помещ."}', '2026-01-01'),
('capex_coefficients', 'COEF-002', '{"name_ru":"К сезонности строит.","description":"Корректировка по сезону строительства (зимнее ≈ 1.1–1.2)","default_value":1.0,"min_value":0.8,"max_value":1.2,"unit":"множ.","applies_when":"Зимнее строительство"}', '2026-01-01'),
('capex_coefficients', 'COEF-003', '{"name_ru":"К строит. сложности","description":"Логистика, удалённость, грунтовые условия","default_value":1.0,"min_value":0.8,"max_value":1.5,"unit":"множ.","applies_when":"Всегда; определяется по участку"}', '2026-01-01'),
('capex_coefficients', 'COEF-004', '{"name_ru":"К региональный","description":"Удорожание по региону строительства","default_value":1.0,"min_value":0.9,"max_value":1.4,"unit":"множ.","applies_when":"По региону"}', '2026-01-01'),
('capex_coefficients', 'COEF-005', '{"name_ru":"К инфляции строит.","description":"Годовой рост строительных расходов (прогнозный)","default_value":1.08,"min_value":1.0,"max_value":1.2,"unit":"множ./год","applies_when":"Прогнозный период"}', '2026-01-01'),
('capex_coefficients', 'COEF-006', '{"name_ru":"К непредвиденных расходов","description":"Contingency резерв","default_value":1.1,"min_value":1.05,"max_value":1.2,"unit":"множ.","applies_when":"Всегда"}', '2026-01-01'),
('capex_coefficients', 'COEF-007', '{"name_ru":"К ПИР","description":"Проектно-изыскательские работы","default_value":0.05,"min_value":0.03,"max_value":0.1,"unit":"доля CAPEX","applies_when":"Всегда"}', '2026-01-01'),
('capex_coefficients', 'COEF-008', '{"name_ru":"К технадзора","description":"Строительный надзор","default_value":0.03,"min_value":0.02,"max_value":0.05,"unit":"доля CAPEX","applies_when":"При внешнем надзоре"}', '2026-01-01')
on conflict do nothing;
