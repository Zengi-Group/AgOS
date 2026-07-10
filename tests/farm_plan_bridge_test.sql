-- ============================================================
-- FARM BRIDGE — archetype→farm_type + draft-ЦТК из профиля (ARS-213)
-- ============================================================
-- Proves the profile→plan bridge (final SECTION of d05_ops_edu.sql) behaves
-- per canon F-D11/F-D12/F-D13/F-D14 (Docs/AGOS-Farm-Module-FunctionalSpec-v0_1.md):
--   1) fn_activity_to_farm_type — полный мост F-D11:
--      cow_calf→cow_calf, finishing→finishing, mixed→combined,
--      breeding→breeding, dairy→null (F-D1)
--   2) BELOW_THRESHOLD: маточное есть, calving_system NULL → generated=false,
--      профиль не тронут (никакого плана)
--   3) BELOW_THRESHOLD: только бычки (finishing-архетип, маточное=0) →
--      generated=false даже при заданном calving_system
--   4) сезонный отёл (spring + p_first_calving_month=след. месяц) → draft-план
--      из BEEF_COMBINED_KZ (стадо COW+STEER → mixed → combined),
--      cycle_start_date = 1-е число месяца первого отёла (D78)
--   5) year_round → план ГЕНЕРИРУЕТСЯ (не отказ, F-D14), архетип cow_calf →
--      BEEF_COW_CALF_KZ, cycle_start_date = 1-е число текущего месяца,
--      фазы созданы (у cow_calf-шаблона есть контент)
--   6) повторный вызов → generated=false, reason=PLAN_ALREADY_EXISTS (graceful)
--
-- HOW TO RUN (no schema/data mutation persists — wrapped in a rolled-back tx):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/farm_plan_bridge_test.sql
-- The DO block raises 'FARM_BRIDGE_TEST_PASS' on success (forces rollback) or a
-- 'FARM_BRIDGE_TEST_FAIL: ...' assertion on the first broken step. Setup problems
-- raise 'FARM_BRIDGE_TEST_SETUP: ...' (missing reference rows).
--
-- REQUIRES: d01_kernel.sql + d05_ops_edu.sql (включая SECTION ARS-213) applied,
-- seed animal_categories + production_cycle_templates, >=1 organization with
-- >=1 user_organization_roles row.
--
-- @case FARM-BRIDGE-01 (мост F-D11) FARM-BRIDGE-02 (порог: нет ответа про отёл)
--       FARM-BRIDGE-03 (порог: нет маточного) FARM-BRIDGE-04 (сезонный отёл, D78)
--       FARM-BRIDGE-05 (year_round легален) FARM-BRIDGE-06 (PLAN_ALREADY_EXISTS)
-- ============================================================

begin;

do $$
declare
    v_org        uuid;
    v_actor      uuid;
    v_farm_a     uuid;   -- COW+STEER (mixed→combined), сезонный отёл
    v_farm_b     uuid;   -- COW only (cow_calf), year_round
    v_cat_cow    uuid;
    v_cat_steer  uuid;
    v_res        jsonb;
    v_plan_id    uuid;
    v_status     text;
    v_start      date;
    v_exp_month  int;
    v_exp_start  date;
    v_phase_cnt  int;
begin
    -- ---- discover reference rows from the deployed DB ----
    select uor.organization_id, uor.user_id
    into   v_org, v_actor
    from   public.user_organization_roles uor
    join   public.organizations o on o.id = uor.organization_id
    order by uor.created_at
    limit 1;
    if v_org is null then
        raise exception 'FARM_BRIDGE_TEST_SETUP: нет ни одной user_organization_roles';
    end if;

    select id into v_cat_cow   from public.animal_categories where code = 'COW';
    select id into v_cat_steer from public.animal_categories where code = 'STEER';
    if v_cat_cow is null or v_cat_steer is null then
        raise exception 'FARM_BRIDGE_TEST_SETUP: seed animal_categories (COW/STEER) отсутствует';
    end if;
    if not exists (select 1 from public.production_cycle_templates
                   where code in ('BEEF_COW_CALF_KZ', 'BEEF_COMBINED_KZ') and is_active) then
        raise exception 'FARM_BRIDGE_TEST_SETUP: seed production_cycle_templates отсутствует';
    end if;

    -- свежие фермы под контролируемое стадо; is_primary=false чтобы не задеть
    -- primary-ферму организации; в RPC передаём p_farm_id явно
    insert into public.farms (organization_id, name, is_primary)
    values (v_org, 'TEST ARS-213 bridge farm A', false)
    returning id into v_farm_a;
    insert into public.farms (organization_id, name, is_primary)
    values (v_org, 'TEST ARS-213 bridge farm B', false)
    returning id into v_farm_b;

    insert into public.herd_groups (farm_id, organization_id, animal_category_id, head_count)
    values (v_farm_a, v_org, v_cat_cow,   20),
           (v_farm_a, v_org, v_cat_steer, 10),
           (v_farm_b, v_org, v_cat_cow,   15);

    -- ---- FARM-BRIDGE-01: мост F-D11 (полный словарь) ----
    if public.fn_activity_to_farm_type('cow_calf')  is distinct from 'cow_calf'
       or public.fn_activity_to_farm_type('finishing') is distinct from 'finishing'
       or public.fn_activity_to_farm_type('mixed')     is distinct from 'combined'
       or public.fn_activity_to_farm_type('breeding')  is distinct from 'breeding'
       or public.fn_activity_to_farm_type('dairy')     is not null then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-01): мост F-D11 отдаёт неверный farm_type';
    end if;

    -- вывод архетипа из состава (F-D14)
    if public.fn_derive_farm_archetype(v_farm_a) is distinct from 'mixed'
       or public.fn_derive_farm_archetype(v_farm_b) is distinct from 'cow_calf' then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-01): fn_derive_farm_archetype неверен (A=%, B=%)',
            public.fn_derive_farm_archetype(v_farm_a), public.fn_derive_farm_archetype(v_farm_b);
    end if;

    -- ---- FARM-BRIDGE-02: маточное есть, ответа про отёл нет → BELOW_THRESHOLD ----
    v_res := public.rpc_generate_plan_from_profile(
        p_organization_id => v_org, p_farm_id => v_farm_a, p_actor_id => v_actor);
    if coalesce((v_res ->> 'generated')::boolean, true)
       or v_res ->> 'reason' is distinct from 'BELOW_THRESHOLD'
       or (v_res ->> 'has_calving_answer')::boolean then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-02): ожидался BELOW_THRESHOLD без calving_system, got %', v_res;
    end if;
    if exists (select 1 from public.farm_production_plans where farm_id = v_farm_a) then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-02): ниже порога план НЕ должен создаваться';
    end if;

    -- ---- FARM-BRIDGE-03: только бычки (маточное=0) → BELOW_THRESHOLD ----
    update public.herd_groups set is_active = false
    where  farm_id = v_farm_a and animal_category_id = v_cat_cow;
    update public.farms set calving_system = 'spring' where id = v_farm_a;

    v_res := public.rpc_generate_plan_from_profile(
        p_organization_id => v_org, p_farm_id => v_farm_a, p_actor_id => v_actor);
    if coalesce((v_res ->> 'generated')::boolean, true)
       or v_res ->> 'reason' is distinct from 'BELOW_THRESHOLD'
       or (v_res ->> 'has_breeding_stock')::boolean then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-03): ожидался BELOW_THRESHOLD без маточного, got %', v_res;
    end if;

    -- вернуть маточное для позитивного пути
    update public.herd_groups set is_active = true
    where  farm_id = v_farm_a and animal_category_id = v_cat_cow;

    -- ---- FARM-BRIDGE-04: сезонный отёл → draft из BEEF_COMBINED_KZ, якорь D78 ----
    -- месяц выбираем следующий (гарантированно в будущем → год не сдвигается)
    v_exp_month := extract(month from current_date + interval '1 month')::int;
    v_exp_start := make_date(extract(year from current_date)::int, v_exp_month, 1);
    if v_exp_start < (current_date - interval '90 days')::date then
        v_exp_start := make_date(extract(year from current_date)::int + 1, v_exp_month, 1);
    end if;

    v_res := public.rpc_generate_plan_from_profile(
        p_organization_id     => v_org,
        p_farm_id             => v_farm_a,
        p_first_calving_month => v_exp_month,
        p_actor_id            => v_actor);
    if not coalesce((v_res ->> 'generated')::boolean, false) then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-04): генерация не прошла: %', v_res;
    end if;
    if v_res ->> 'farm_type' is distinct from 'combined'
       or v_res ->> 'template_code' is distinct from 'BEEF_COMBINED_KZ' then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-04): ожидался combined/BEEF_COMBINED_KZ, got %', v_res;
    end if;

    v_plan_id := (v_res ->> 'plan_id')::uuid;
    select fpp.cycle_start_date, fpp.status
    into   v_start, v_status
    from   public.farm_production_plans fpp
    where  fpp.id = v_plan_id;
    if v_start is distinct from v_exp_start then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-04): cycle_start_date=% ожидался % (D78)', v_start, v_exp_start;
    end if;
    if v_status is distinct from 'draft' then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-04): план должен быть draft (F-D12), got %', v_status;
    end if;

    -- ---- FARM-BRIDGE-05: year_round — легальный путь (не отказ) ----
    update public.farms set calving_system = 'year_round' where id = v_farm_b;

    v_res := public.rpc_generate_plan_from_profile(
        p_organization_id => v_org, p_farm_id => v_farm_b, p_actor_id => v_actor);
    if not coalesce((v_res ->> 'generated')::boolean, false) then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-05): year_round должен генерировать план, got %', v_res;
    end if;
    if v_res ->> 'farm_type' is distinct from 'cow_calf'
       or v_res ->> 'template_code' is distinct from 'BEEF_COW_CALF_KZ' then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-05): ожидался cow_calf/BEEF_COW_CALF_KZ, got %', v_res;
    end if;
    if (v_res ->> 'cycle_start_date')::date is distinct from date_trunc('month', current_date)::date then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-05): year_round якорь = 1-е текущего месяца, got %',
            v_res ->> 'cycle_start_date';
    end if;
    select count(*) into v_phase_cnt
    from   public.farm_phases
    where  plan_id = (v_res ->> 'plan_id')::uuid;
    if v_phase_cnt = 0 then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-05): у cow_calf-плана нет фаз — движок не сработал';
    end if;

    -- ---- FARM-BRIDGE-06: повторный вызов → PLAN_ALREADY_EXISTS (graceful) ----
    v_res := public.rpc_generate_plan_from_profile(
        p_organization_id => v_org, p_farm_id => v_farm_b, p_actor_id => v_actor);
    if coalesce((v_res ->> 'generated')::boolean, true)
       or v_res ->> 'reason' is distinct from 'PLAN_ALREADY_EXISTS'
       or (v_res ->> 'plan_id') is null then
        raise exception 'FARM_BRIDGE_TEST_FAIL (FARM-BRIDGE-06): ожидался graceful PLAN_ALREADY_EXISTS, got %', v_res;
    end if;

    raise exception 'FARM_BRIDGE_TEST_PASS: мост F-D11 + порог F-D14 + D78 якорь + year_round + already-exists all hold (plan %)', v_plan_id;
end $$;

rollback;
-- ============================================================
-- Caveats: BEEF_COMBINED_KZ пока без phase_templates (контент = ARS-172, R4) —
-- FARM-BRIDGE-04 проверяет корректность моста/якоря, а богатство плана
-- проверяет FARM-BRIDGE-05 на BEEF_COW_CALF_KZ (контент засеян).
-- ============================================================
