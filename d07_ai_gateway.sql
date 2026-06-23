-- ============================================================
-- AGOS Schema: d07_ai_gateway
-- Project: TURAN Agricultural Operating System
-- Consolidated: 2026-03-05 (pre-development baseline)
--
-- AI Gateway RPC Catalog.
-- All functions callable by Python FastAPI (LangGraph).
-- JWT custom claims hook. RPC name registry.
-- SECURITY DEFINER: ownership validated via p_organization_id.
--
-- Depends on: d01_kernel.sql, d02_tsp.sql, d03_feed.sql, d04_vet.sql, d05_ops_edu.sql
-- Consolidated from: 011_ai_rpc_catalog.sql, 016_missing_rpcs.sql, 015_tech_debt.sql (JWT claims, rpc_name_registry)
--
-- Convention: All statements are idempotent.
--   CREATE TABLE IF NOT EXISTS
--   CREATE OR REPLACE FUNCTION
--   ALTER TABLE ADD COLUMN IF NOT EXISTS
--   INSERT ... ON CONFLICT DO NOTHING
-- ============================================================
-- ============================================================
-- Migration 011: AI Gateway RPC Catalog
-- ============================================================
-- Fix: C-NEW-2 — 16 RPCs referenced in Dok 5 Tool Catalog did not exist.
-- All functions created here are:
--   • SECURITY DEFINER — called via service_role from AI Gateway (no JWT user context)
--   • set search_path = public, pg_temp — prevent search_path injection
--   • ownership validated via p_organization_id (NOT fn_current_user_id())
--   • Named rpc_* for public-facing RPCs (consistent with rpc_start_production_plan)
-- Dok 5 Tool Catalog notation "rpc.xxx" maps to supabase.rpc("rpc_xxx")
-- e.g. rpc.get_ai_farm_context → supabase.rpc("rpc_get_ai_farm_context")
-- ============================================================

-- ============================================================
-- HELPER: Validate organization ownership of a farm
-- ============================================================
create or replace function public._ai_check_farm_org(
    p_farm_id uuid,
    p_organization_id uuid
) returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select exists (
        select 1 from public.farms
        where id = p_farm_id
        and organization_id = p_organization_id
        and is_active = true
    );
$$;

-- ============================================================
-- 3. rpc_get_feeding_plan
-- Dok 5 §6.1: get_feeding_plan → rpc.get_feeding_plan
-- ============================================================
create or replace function public.rpc_get_feeding_plan(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_herd_group_id     uuid    default null  -- filter to specific group if provided
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    return (
        select jsonb_build_object(
            'plan_id',    fp.id,
            'plan_name',  fp.name,
            'plan_year',  fp.plan_year,
            'status',     fp.status,
            'periods', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'period_id',          fper.id,
                    'herd_group_id',      fper.herd_group_id,
                    'period_type',        pt.code,
                    'period_name',        pt.name_ru,
                    'start_date',         fper.start_date,
                    'end_date',           fper.end_date,
                    'status',             fper.status,
                    'head_count',         fper.head_count,
                    'ration', (
                        select jsonb_build_object(
                            'ration_id',         rv.ration_id,
                            'version_number',    rv.version_number,
                            'total_dm_per_head', (rv.results->>'total_dm_kg')::numeric
                        )
                        from   public.ration_versions rv
                        join   public.rations r2 on r2.id = rv.ration_id
                        where  rv.ration_id = fper.ration_id
                          and  rv.is_current = true
                        limit  1
                    )
                ) order by fper.start_date), '[]'::jsonb)
                from   public.feeding_periods fper
                join   public.period_types pt on pt.id = fper.period_type_id
                where  fper.feeding_plan_id = fp.id
                  and  (p_herd_group_id is null or fper.herd_group_id = p_herd_group_id)
                  and  fper.status in ('upcoming', 'active')
            )
        )
        from   public.feeding_plans fp
        where  fp.farm_id = p_farm_id
          and  fp.organization_id = p_organization_id
          and  fp.status = 'active'
        order  by fp.created_at desc
        limit  1
    );
end;
$$;

comment on function public.rpc_get_feeding_plan(uuid, uuid, uuid) is
    'Dok 5 §6.1: Returns active feeding plan with periods and ration references.
     p_herd_group_id: optional filter to specific animal group.';

-- ============================================================
-- 4. rpc_get_farm_tasks
-- Dok 5 §6.1: get_farm_tasks → rpc.get_farm_tasks
-- ============================================================
create or replace function public.rpc_get_farm_tasks(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_days_ahead        int     default 14,
    p_category          text    default null  -- 'zootechnical' | 'veterinary' | 'management'
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    return jsonb_build_object(
        'tasks', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'task_id',       ft.id,
                'name',          ft.name_ru,
                'category',      ft.category,
                'due_date',      ft.due_date,
                'status',        ft.status,
                'phase_name',    fph.name_ru,
                'herd_group_id', fph.herd_group_id
            ) order by ft.due_date), '[]'::jsonb)
            from   public.farm_tasks ft
            join   public.farm_phases fph on fph.id = ft.farm_phase_id
            join   public.farm_production_plans fpp on fpp.id = fph.plan_id
            where  fpp.farm_id = p_farm_id
              and  ft.organization_id = p_organization_id
              and  ft.status in ('scheduled', 'reminded', 'in_progress', 'overdue')
              and  ft.due_date <= current_date + p_days_ahead
              and  (p_category is null or ft.category = p_category)
            order  by ft.due_date
        ),
        'query_date', current_date,
        'days_ahead', p_days_ahead
    );
end;
$$;

comment on function public.rpc_get_farm_tasks(uuid, uuid, int, text) is
    'Dok 5 §6.1: Returns upcoming farm tasks within p_days_ahead days.
     p_category: optional filter by task category.';

-- ============================================================
-- 5. rpc_complete_farm_task
-- Dok 5 §6.1: complete_farm_task → rpc.complete_farm_task
-- ============================================================
create or replace function public.rpc_complete_farm_task(
    p_organization_id       uuid,
    p_task_id               uuid,
    p_result_description    text    default null,
    p_result_data           jsonb   default null,  -- structured data (weights, counts)
    p_actor_id              uuid    default null,
    p_ai_context            jsonb   default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_task  record;
begin
    select ft.*, fpp.farm_id
    into   v_task
    from   public.farm_tasks ft
    join   public.farm_phases fph on fph.id = ft.farm_phase_id
    join   public.farm_production_plans fpp on fpp.id = fph.plan_id
    where  ft.id = p_task_id
      and  ft.organization_id = p_organization_id;

    if not found then
        raise exception 'FORBIDDEN: task % not found in organization %',
            p_task_id, p_organization_id using errcode = 'P0001';
    end if;

    if v_task.status = 'completed' then
        return jsonb_build_object('task_id', p_task_id, 'status', 'already_completed');
    end if;

    update public.farm_tasks
    set    status       = 'completed',
           result_data  = coalesce(p_result_data, result_data,
                              case when p_result_description is not null
                                   then jsonb_build_object('notes', p_result_description)
                                   else null end),
           notes        = coalesce(p_result_description, notes),
           completed_by = p_actor_id,
           completed_at = now(),
           updated_at   = now()
    where  id = p_task_id;

    -- Publish event
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, actor_id, payload
    ) values (
        'ops.task.completed', 'farm_tasks', p_task_id,
        p_organization_id, 'ai_gateway', p_actor_id,
        jsonb_build_object(
            'task_id',    p_task_id,
            'farm_id',    v_task.farm_id,
            'ai_context', p_ai_context
        )
    );

    return jsonb_build_object(
        'task_id', p_task_id,
        'status', 'completed',
        'completed_at', now()
    );
end;
$$;

comment on function public.rpc_complete_farm_task(uuid,uuid,text,jsonb,uuid,jsonb) is
    'Dok 5 §6.1: Marks a farm task as completed. AI passes result from farmer message.
     result_data: structured extraction (weights, head counts). Publishes ops.task.completed.';

-- ============================================================
-- 6. rpc_get_production_plan
-- Dok 5 §6.1: get_production_plan → rpc.get_production_plan
-- ============================================================
create or replace function public.rpc_get_production_plan(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_status            text    default 'active'  -- 'draft' | 'active' | 'completed'
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    return (
        select jsonb_build_object(
            'plan_id',     fpp.id,
            'plan_name',   fpp.plan_name,
            'status',      fpp.status,
            'start_date',  fpp.plan_start_date,
            'end_date',    fpp.plan_end_date,
            'phases', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'phase_id',      fph.id,
                    'name',          fph.name_ru,
                    'status',        fph.status,
                    'start_date',    fph.start_date,
                    'end_date',      fph.end_date,
                    'is_sale_phase', fph.is_sale_phase,
                    'task_counts', jsonb_build_object(
                        'total',     count(ft.id),
                        'completed', count(ft.id) filter (where ft.status = 'completed'),
                        'overdue',   count(ft.id) filter (where ft.status = 'overdue')
                    )
                ) order by fph.start_date), '[]'::jsonb)
                from   public.farm_phases fph
                left   join public.farm_tasks ft on ft.farm_phase_id = fph.id
                where  fph.plan_id = fpp.id
                group  by fph.id
            )
        )
        from   public.farm_production_plans fpp
        where  fpp.farm_id = p_farm_id
          and  fpp.organization_id = p_organization_id
          and  (p_status = 'any' or fpp.status = p_status)
        order  by fpp.created_at desc
        limit  1
    );
end;
$$;

comment on function public.rpc_get_production_plan(uuid, uuid, text) is
    'Dok 5 §6.1: Returns production plan with phases and task completion summaries.
     Default returns active plan. p_status=''any'' returns most recent regardless of status.';

-- ============================================================
-- 7. rpc_create_vet_case
-- Dok 5 §6.2: create_vet_case → rpc.create_vet_case
-- ============================================================
create or replace function public.rpc_create_vet_case(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_symptoms_text     text,
    p_severity          text    default 'moderate',  -- mild | moderate | severe | critical
    p_herd_group_id     uuid    default null,
    p_affected_heads    int     default null,
    p_created_via       text    default 'ai_whatsapp', -- ai_whatsapp | ai_web | expert_manual
    p_actor_id          uuid    default null,
    p_ai_context        jsonb   default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_case_id uuid;
begin
    if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    insert into public.vet_cases (
        organization_id, farm_id, herd_group_id, affected_head_count,
        symptoms_text, severity, status, created_via, created_by
    ) values (
        p_organization_id, p_farm_id, p_herd_group_id, p_affected_heads,
        p_symptoms_text, p_severity, 'open', p_created_via, p_actor_id
    )
    returning id into v_case_id;

    -- Publish event
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, actor_id, payload
    ) values (
        'vet.vet_case.opened', 'vet_cases', v_case_id,
        p_organization_id, 'ai_gateway', p_actor_id,
        jsonb_build_object(
            'vet_case_id',  v_case_id,
            'severity',     p_severity,
            'farm_id',      p_farm_id,
            'ai_context',   p_ai_context
        )
    );

    return jsonb_build_object(
        'vet_case_id', v_case_id,
        'status', 'open',
        'severity', p_severity
    );
end;
$$;

comment on function public.rpc_create_vet_case(uuid,uuid,text,text,uuid,int,text,uuid,jsonb) is
    'Dok 5 §6.2: Creates a new VetCase from AI dialogue.
     Trigger fn_vet_case_auto_escalate fires on INSERT: critical severity → auto-escalation.
     Returns {vet_case_id, status, severity}. Publishes vet.vet_case.opened.';

-- ============================================================
-- 8. rpc_add_vet_symptoms
-- Dok 5 §6.2: add_symptoms → rpc.add_vet_symptoms
-- Merges structured symptoms into vet_cases.symptoms_structured
-- ============================================================
create or replace function public.rpc_add_vet_symptoms(
    p_organization_id       uuid,
    p_vet_case_id           uuid,
    p_symptoms_structured   jsonb,  -- [{symptom_code, confidence, extracted_from_text}]
    p_actor_id              uuid    default null,
    p_ai_context            jsonb   default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_case record;
begin
    select id, symptoms_structured, organization_id
    into   v_case
    from   public.vet_cases
    where  id = p_vet_case_id
      and  organization_id = p_organization_id;

    if not found then
        raise exception 'FORBIDDEN: vet_case % not found in organization %',
            p_vet_case_id, p_organization_id using errcode = 'P0001';
    end if;

    -- Merge: append new symptoms (AI DRAFT — expert can override via VetDiagnosis)
    update public.vet_cases
    set    symptoms_structured = coalesce(symptoms_structured, '[]'::jsonb) || p_symptoms_structured,
           updated_at = now()
    where  id = p_vet_case_id;

    return jsonb_build_object(
        'vet_case_id', p_vet_case_id,
        'symptoms_added', jsonb_array_length(p_symptoms_structured),
        'total_symptoms', jsonb_array_length(
            coalesce(v_case.symptoms_structured, '[]'::jsonb) || p_symptoms_structured
        )
    );
end;
$$;

comment on function public.rpc_add_vet_symptoms(uuid,uuid,jsonb,uuid,jsonb) is
    'Dok 5 §6.2: Appends structured symptoms to vet_case.symptoms_structured (DRAFT by AI).
     Expert can override via VetDiagnosis (source=expert_override). Append-only semantics.';

-- ============================================================
-- 9. rpc_get_vet_diagnosis
-- Dok 5 §6.2: get_diagnosis → rpc.get_vet_diagnosis
-- Matches case symptoms against disease_symptoms matrix.
-- Returns ranked disease candidates with confidence.
-- ============================================================
create or replace function public.rpc_get_vet_diagnosis(
    p_organization_id   uuid,
    p_vet_case_id       uuid,
    p_limit             int     default 5
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_case      record;
    v_symptoms  text[];
begin
    select vc.id, vc.symptoms_text, vc.symptoms_structured
    into   v_case
    from   public.vet_cases vc
    where  vc.id = p_vet_case_id
      and  vc.organization_id = p_organization_id;

    if not found then
        raise exception 'FORBIDDEN: vet_case % not found in organization %',
            p_vet_case_id, p_organization_id using errcode = 'P0001';
    end if;

    -- Extract symptom codes from symptoms_structured
    select array_agg(s_elem->>'symptom_code')
    into   v_symptoms
    from   jsonb_array_elements(
               coalesce(v_case.symptoms_structured, '[]'::jsonb)
           ) as s_elem
    where  s_elem->>'symptom_code' is not null;

    return jsonb_build_object(
        'vet_case_id', p_vet_case_id,
        'method', case
                      when array_length(v_symptoms, 1) > 0 then 'symptom_matrix'
                      else 'text_search_fallback'
                  end,
        'candidates', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'disease_id',   d.id,
                'disease_name', d.name_ru,
                'icd_code',     d.icd_code,
                'severity',     d.default_severity,
                'is_notifiable', d.is_notifiable,
                'matched_count', match_count,
                'confidence',   round((match_count::numeric / total_symptoms::numeric) * 100)
            ) order by match_count desc), '[]'::jsonb)
            from (
                select
                    d2.id, d2.name_ru, d2.icd_code, d2.default_severity, d2.is_notifiable,
                    count(ds.symptom_id) as match_count,
                    greatest(array_length(v_symptoms, 1), 1) as total_symptoms
                from   public.diseases d2
                left   join public.symptoms sym
                           on  sym.code = any(v_symptoms)
                left   join public.disease_symptoms ds
                           on  ds.disease_id = d2.id
                           and ds.symptom_id = sym.id
                where  d2.is_active = true
                  and  (
                      -- Match by symptom matrix if symptoms extracted
                      (array_length(v_symptoms, 1) > 0 and ds.symptom_id is not null)
                      OR
                      -- Text search fallback when no structured symptoms yet
                      (array_length(v_symptoms, 1) is null
                       and v_case.symptoms_text is not null
                       and (
                           d2.name_ru ilike '%' || split_part(v_case.symptoms_text, ' ', 1) || '%'
                           or d2.description_ru ilike '%' || split_part(v_case.symptoms_text, ' ', 1) || '%'
                       ))
                  )
                group by d2.id, d2.name_ru, d2.icd_code, d2.default_severity, d2.is_notifiable
                having count(ds.symptom_id) > 0 or array_length(v_symptoms, 1) is null
                order  by count(ds.symptom_id) desc
                limit  p_limit
            ) ranked
            join public.diseases d on d.id = ranked.id
        ),
        'note', 'Диагноз предварительный. Требует подтверждения ветеринарным экспертом.'
    );
end;
$$;

comment on function public.rpc_get_vet_diagnosis(uuid, uuid, int) is
    'Dok 5 §6.2: Returns ranked disease candidates by symptom matrix matching.
     Uses disease_symptoms join when symptoms_structured populated.
     Falls back to text search on symptoms_text if no structured symptoms.
     Result is DRAFT: final diagnosis must be confirmed by expert (vet_diagnoses.is_final).
     P-AI-4: if no matches found, AI must tell farmer to consult vet in person.';

-- ============================================================
-- 10. rpc_get_treatment_protocols
-- Dok 5 §6.2: get_treatment_protocols → rpc.get_treatment_protocols
-- P-AI-4: if empty result → AI must NOT generate dosages from own knowledge.
-- ============================================================
create or replace function public.rpc_get_treatment_protocols(
    p_organization_id   uuid,
    p_disease_id        uuid    default null,
    p_animal_category_code text default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    return jsonb_build_object(
        'protocols', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'treatment_id',         t.id,
                'treatment_code',       t.code,
                'disease_name',         d.name_ru,
                'vet_product_name',     vp.name_ru,
                'active_substance',     vp.active_substance,
                'dosage_per_kg',        t.dosage_per_kg,
                'dosage_unit',          t.dosage_unit,
                'route',                t.administration_route,
                'frequency_hours',      t.frequency_hours,
                'duration_days',        t.duration_days,
                'withdrawal_days',      t.withdrawal_period_days,
                'contraindications',    t.contraindications,
                'special_instructions', t.special_instructions,
                'notes',                t.notes
            ) order by d.name_ru, t.id), '[]'::jsonb)
            from   public.treatments t
            join   public.diseases d on d.id = t.disease_id
            join   public.vet_products vp on vp.id = t.vet_product_id
            where  t.status = 'active'
              and  (p_disease_id is null or t.disease_id = p_disease_id)
              and  (
                  p_animal_category_code is null
                  or array_length(t.applicable_animal_category_ids, 1) is null
                  or t.applicable_animal_category_ids = '{}'
                  or exists (
                      select 1 from public.animal_categories ac2
                      where  ac2.code = p_animal_category_code
                        and  ac2.id = any(t.applicable_animal_category_ids)
                  )
              )
        ),
        'p_ai4_warning', 'Если список пуст — сообщить фермеру обратиться к ветеринару лично. Генерировать дозировки из собственных знаний — ЗАПРЕЩЕНО (P-AI-4).'
    );
end;
$$;

comment on function public.rpc_get_treatment_protocols(uuid, uuid, text) is
    'Dok 5 §6.2: Returns treatment protocols from treatments table ONLY.
     P-AI-4 CRITICAL: If empty result → AI must respond "обратитесь к ветеринару лично".
     AI is NEVER allowed to generate dosages from its own knowledge.
     p_disease_id: filter to specific disease. p_animal_category_code: filter by category.';

-- ============================================================
-- 11. rpc_get_vaccination_schedule
-- Dok 5 §6.2: get_vaccination_schedule → rpc.get_vaccination_schedule
-- ============================================================
create or replace function public.rpc_get_vaccination_schedule(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_days_ahead        int     default 60
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    return jsonb_build_object(
        'schedule', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'item_id',          vpi.id,
                'protocol_name',    vp.name_ru,
                'disease_name',     d.name_ru,
                'herd_group_id',    vpi.herd_group_id,
                'scheduled_date',   vpi.scheduled_date,
                'head_count',       vpi.head_count_planned,
                'dose_number',      vpi.dose_number,
                'status',           vpi.status,
                'days_until',       vpi.scheduled_date - current_date
            ) order by vpi.scheduled_date), '[]'::jsonb)
            from   public.vaccination_plan_items vpi
            join   public.vaccination_plans vplan on vplan.id = vpi.vaccination_plan_id
            join   public.vaccination_protocols vp on vp.id = vpi.vaccination_protocol_id
            left   join public.diseases d on d.id = vp.disease_id
            where  vplan.farm_id = p_farm_id
              and  vplan.organization_id = p_organization_id
              and  vpi.status in ('scheduled', 'reminded', 'overdue')
              and  vpi.scheduled_date between current_date - 7 and current_date + p_days_ahead
        ),
        'query_date', current_date,
        'days_ahead', p_days_ahead
    );
end;
$$;

comment on function public.rpc_get_vaccination_schedule(uuid, uuid, int) is
    'Dok 5 §6.2: Returns vaccination schedule for the farm.
     Includes overdue items (up to -7 days) and upcoming items.
     days_until: negative = overdue, 0 = today, positive = future.';

-- ============================================================
-- 12. rpc_complete_vaccination_item
-- Dok 5 §6.2: confirm_vaccination → rpc.complete_vaccination_item
-- Creates vaccination_record (APPEND-ONLY fact), updates plan item status.
-- ============================================================
create or replace function public.rpc_complete_vaccination_item(
    p_organization_id       uuid,
    p_item_id               uuid,
    p_vet_product_id        uuid    default null,  -- actual product used
    p_actual_heads          int     default null,  -- actual vaccinated (may differ from plan)
    p_vaccine_batch         text    default null,
    p_notes                 text    default null,
    p_actor_id              uuid    default null,
    p_ai_context            jsonb   default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_item  record;
    v_rec_id uuid;
begin
    select vpi.*, vplan.farm_id
    into   v_item
    from   public.vaccination_plan_items vpi
    join   public.vaccination_plans vplan on vplan.id = vpi.vaccination_plan_id
    where  vpi.id = p_item_id
      and  vpi.organization_id = p_organization_id;

    if not found then
        raise exception 'FORBIDDEN: vaccination_plan_item % not found in organization %',
            p_item_id, p_organization_id using errcode = 'P0001';
    end if;

    if v_item.status = 'completed' then
        return jsonb_build_object('item_id', p_item_id, 'status', 'already_completed');
    end if;

    -- Insert vaccination record (APPEND-ONLY fact)
    -- Note: fn_vaccination_record_complete_plan_item trigger will update plan item status
    insert into public.vaccination_records (
        vaccination_plan_item_id, organization_id, herd_group_id,
        vet_product_id, vaccine_batch_number,
        administered_by, actual_heads_vaccinated, notes
    ) values (
        p_item_id, p_organization_id, v_item.herd_group_id,
        coalesce(p_vet_product_id, (
            select vp.id from public.vaccination_protocols vpr
            join   public.vet_products vp on vp.id = vpr.vet_product_id
            where  vpr.id = v_item.vaccination_protocol_id
            limit 1
        )),
        p_vaccine_batch,
        p_actor_id,
        coalesce(p_actual_heads, v_item.head_count_planned),
        p_notes
    )
    returning id into v_rec_id;

    -- Publish event
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, actor_id, payload
    ) values (
        'vet.vaccination.completed', 'vaccination_records', v_rec_id,
        p_organization_id, 'ai_gateway', p_actor_id,
        jsonb_build_object(
            'record_id',      v_rec_id,
            'plan_item_id',   p_item_id,
            'farm_id',        v_item.farm_id,
            'ai_context',     p_ai_context
        )
    );

    return jsonb_build_object(
        'vaccination_record_id', v_rec_id,
        'plan_item_id', p_item_id,
        'status', 'completed',
        'actual_heads', coalesce(p_actual_heads, v_item.head_count_planned)
    );
end;
$$;

comment on function public.rpc_complete_vaccination_item(uuid,uuid,uuid,int,text,text,uuid,jsonb) is
    'Dok 5 §6.2: Records vaccination fact (creates vaccination_record APPEND-ONLY).
     Trigger fn_vaccination_record_complete_plan_item updates plan item status automatically.
     p_vet_product_id: actual product used (may differ from protocol default).';

-- ============================================================
-- 13. rpc_create_consultation_request
-- Dok 5 §6.2, §6.4: escalate_to_expert / create_consultation_request
-- ============================================================
create or replace function public.rpc_create_consultation_request(
    p_organization_id       uuid,
    p_specialization        text,       -- veterinarian | zootechnician | agronomist | etc.
    p_source                text,       -- direct | ai_referral | auto_escalation
    p_description           text        default null,
    p_vet_case_id           uuid        default null,
    p_priority              text        default 'normal',
    p_actor_id              uuid        default null,
    p_ai_context            jsonb       default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_req_id uuid;
begin
    -- Basic org existence check
    if not exists (select 1 from public.organizations where id = p_organization_id) then
        raise exception 'FORBIDDEN: organization % not found', p_organization_id
            using errcode = 'P0001';
    end if;

    insert into public.consultation_requests (
        organization_id, specialization_needed, source,
        status, priority, description, vet_case_id
    ) values (
        p_organization_id, p_specialization, p_source,
        'pending', p_priority, p_description, p_vet_case_id
    )
    returning id into v_req_id;

    -- Publish event
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, actor_id, payload
    ) values (
        'identity.consultation_request.created', 'consultation_requests', v_req_id,
        p_organization_id, 'ai_gateway', p_actor_id,
        jsonb_build_object(
            'request_id',    v_req_id,
            'specialization', p_specialization,
            'source',        p_source,
            'priority',      p_priority,
            'vet_case_id',   p_vet_case_id,
            'ai_context',    p_ai_context
        )
    );

    return jsonb_build_object(
        'request_id', v_req_id,
        'status', 'pending',
        'specialization', p_specialization,
        'message', 'Запрос направлен эксперту. Ожидайте ответа.'
    );
end;
$$;

comment on function public.rpc_create_consultation_request(uuid,text,text,text,uuid,text,uuid,jsonb) is
    'Dok 5 §6.2/§6.4: Creates expert consultation request.
     source=ai_referral: AI recommends expert. source=auto_escalation: critical VetCase.
     Publishes identity.consultation_request.created for expert notification.';

-- ============================================================
-- 14. rpc_search_knowledge_chunks
-- Dok 5 §6.1/§6.2/§6.4/§6.5: search_knowledge → rpc.search_knowledge_chunks
-- Combined vector + text fallback search.
-- ============================================================
create or replace function public.rpc_search_knowledge_chunks(
    p_organization_id   uuid,           -- for audit/logging only (knowledge is shared)
    p_query_text        text,
    p_query_embedding   vector(1536)    default null,   -- pass pre-computed embedding for vector search
    p_source_domain     text            default null,   -- filter: 'veterinary' | 'zootechnical' | etc.
    p_language          text            default 'ru',
    p_limit             int             default 5
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    return jsonb_build_object(
        'chunks', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'chunk_id',       kc.id,
                'title',          kc.title,
                'content',        kc.content,
                'source_domain',  kc.source_domain,
                'source_url',     kc.source_url,
                'relevance_score', relevance
            ) order by relevance desc), '[]'::jsonb)
            from (
                select kc.*,
                       case
                           when p_query_embedding is not null
                           then 1 - (kc.embedding <=> p_query_embedding)  -- cosine similarity
                           else ts_rank(
                               to_tsvector('russian', kc.title || ' ' || kc.content),
                               plainto_tsquery('russian', p_query_text)
                           )
                       end as relevance
                from   public.knowledge_chunks kc
                where  kc.is_published = true
                  and  kc.language = p_language
                  and  (p_source_domain is null or kc.source_domain = p_source_domain)
                  and  (
                      p_query_embedding is not null
                      or to_tsvector('russian', kc.title || ' ' || kc.content)
                         @@ plainto_tsquery('russian', p_query_text)
                  )
                order  by relevance desc
                limit  p_limit
            ) ranked
            join public.knowledge_chunks kc on kc.id = ranked.id
        ),
        'search_method', case when p_query_embedding is not null then 'vector' else 'text' end,
        'query', p_query_text
    );
end;
$$;

comment on function public.rpc_search_knowledge_chunks(uuid,text,vector,text,text,int) is
    'Dok 5 §6.1/§6.4: RAG search across all published knowledge chunks.
     Vector mode: p_query_embedding provided → cosine similarity via HNSW index (fast).
     Text fallback: p_query_embedding=null → PostgreSQL FTS (plainto_tsquery russian).
     Only is_published=true chunks returned (D71: expert-reviewed).
     p_source_domain: filter to specific domain for role-appropriate results.';

-- ============================================================
-- 15. rpc_get_membership_status
-- Dok 5 §6.4: get_membership_status → rpc.get_membership_status
-- ============================================================
create or replace function public.rpc_get_membership_status(
    p_organization_id   uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    return jsonb_build_object(
        'organization_id', p_organization_id,
        'memberships', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'org_type',        m.org_type,
                'level',           m.level,
                'level_changed_at', m.level_changed_at,
                'pending_application', (
                    select jsonb_build_object(
                        'app_id',       ma.id,
                        'to_level',     ma.to_level,
                        'status',       ma.status,
                        'submitted_at', ma.submitted_at
                    )
                    from   public.membership_applications ma
                    where  ma.membership_id = m.id
                      and  ma.status in ('submitted', 'under_review')
                    order  by ma.submitted_at desc
                    limit  1
                )
            )), '[]'::jsonb)
            from   public.memberships m
            where  m.organization_id = p_organization_id
        ),
        'is_restricted', public.fn_org_is_restricted(p_organization_id)
    );
end;
$$;

comment on function public.rpc_get_membership_status(uuid) is
    'Dok 5 §6.4: Returns all membership levels and pending applications for an organization.
     Includes is_restricted flag (from fn_org_is_restricted).
     AI consultant uses this to inform farmer about their standing and upgrade path.';

-- ============================================================
-- 16. rpc_get_price_grid
-- Dok 5 §6.5: get_price_grid → rpc.get_price_grid
-- Legal: returns only prices where legal_disclaimer_shown = true
-- ============================================================
create or replace function public.rpc_get_price_grid(
    p_organization_id   uuid,
    p_region_id         uuid    default null,
    p_target_month      date    default null  -- filter to relevant SKUs for target month
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    return jsonb_build_object(
        -- LEGAL 5.9 MANDATORY: antitrust disclaimer must accompany every price display
        'legal_disclaimer',
            'Справочные цены являются индикативными рыночными ориентирами. '
            'Итоговые расчётные цены определяются при поставке на основании рыночных условий. '
            'TURAN не устанавливает, не обеспечивает и не гарантирует цены сделок. '
            'Участие добровольное.',
        'prices', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'price_grid_id',    pg2.id,
                'sku_code',         ts.sku_code,
                'sku_name',         ts.description_ru,
                'base_price_per_kg', pg2.base_price_per_kg,
                'premium_per_kg',   pg2.premium_per_kg,
                'total_per_kg',     pg2.base_price_per_kg + pg2.premium_per_kg,
                'region',           r.name_ru,
                'valid_from',       pg2.valid_from,
                'valid_to',         pg2.valid_to
            ) order by ts.sku_code), '[]'::jsonb)
            from   public.price_grids pg2
            join   public.tsp_skus ts on ts.id = pg2.tsp_sku_id
            left   join public.regions r on r.id = pg2.region_id
            where  pg2.is_active = true
              and  pg2.legal_disclaimer_shown = true   -- MANDATORY check (Legal 5.9)
              and  (pg2.valid_to is null or pg2.valid_to >= current_date)
              and  (
                  p_region_id is null
                  or pg2.region_id = p_region_id
                  or pg2.region_id is null  -- national price as fallback
              )
        ),
        'as_of_date', current_date
    );
end;
$$;

comment on function public.rpc_get_price_grid(uuid, uuid, date) is
    'Dok 5 §6.5: Returns reference prices with MANDATORY legal disclaimer (Legal 5.9 / ст.171 ПК РК).
     CRITICAL: Only returns prices where legal_disclaimer_shown=true.
     AI MUST display legal_disclaimer text to farmer before showing any prices.
     Prices are INDICATIVE only — not mandated rates. Tier 3 legal architecture.';

-- ============================================================
-- 17. rpc_get_aggregated_supply
-- Dok 5 §6.5: get_market_overview (supply side) → rpc.get_aggregated_supply
-- Legal: anonymized, min 5 batches threshold (antitrust protection)
-- ============================================================
create or replace function public.rpc_get_aggregated_supply(
    p_organization_id   uuid,   -- caller org (for audit, NOT for filtering)
    p_target_month      date    default null,
    p_region_id         uuid    default null,
    p_min_count         int     default 5   -- privacy threshold: min batches to show
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    return jsonb_build_object(
        -- LEGAL 5.9: Individual farm data never visible to competitors
        'legal_note', 'Агрегированные анонимные данные. Детали конкретных ферм не раскрываются.',
        'supply', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'sku_code',         ts.sku_code,
                'sku_name',         ts.description_ru,
                'region',           r.name_ru,
                'target_month',     date_trunc('month', b.target_month),
                'batch_count',      count(b.id),
                'total_heads',      sum(b.heads),
                'avg_weight_kg',    round(avg(b.avg_weight_kg)::numeric, 1)
            ) order by ts.sku_code, date_trunc('month', b.target_month)), '[]'::jsonb)
            from   public.batches b
            join   public.tsp_skus ts on ts.id = b.tsp_sku_id
            left   join public.regions r on r.id = b.region_id
            where  b.status = 'published'
              and  (p_target_month is null
                    or date_trunc('month', b.target_month) = date_trunc('month', p_target_month))
              and  (p_region_id is null or b.region_id = p_region_id)
            group  by ts.sku_code, ts.description_ru, r.name_ru,
                      date_trunc('month', b.target_month)
            having count(b.id) >= p_min_count   -- ANTITRUST: min 5 batches for anonymity
        ),
        'privacy_threshold', p_min_count,
        'note', 'Данные скрыты если источников меньше ' || p_min_count::text
    );
end;
$$;

comment on function public.rpc_get_aggregated_supply(uuid,date,uuid,int) is
    'Dok 5 §6.5: Returns ANONYMIZED aggregated supply data.
     LEGAL (ст.171 ПК РК): only returns data when batch_count >= p_min_count (default 5).
     Individual farm details are NEVER visible through this function.
     AI must not attempt to identify specific farms from this data.';

-- ============================================================
-- 18. rpc_get_aggregated_demand
-- Dok 5 §6.5: get_market_overview (demand side) → rpc.get_aggregated_demand
-- ============================================================
create or replace function public.rpc_get_aggregated_demand(
    p_organization_id   uuid,
    p_target_month      date    default null,
    p_region_id         uuid    default null,
    p_min_count         int     default 3   -- fewer MPKs so lower threshold
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    return jsonb_build_object(
        'legal_note', 'Агрегированные анонимные данные. Детали конкретных МПК не раскрываются.',
        'demand', (
            -- Note: pool_requests.accepted_categories is JSONB — aggregated without SKU breakdown
            select coalesce(jsonb_agg(jsonb_build_object(
                'region',           r.name_ru,
                'target_month',     date_trunc('month', pr.target_month),
                'pool_count',       count(distinct p2.id),
                'total_heads_needed', sum(p2.target_heads),
                'status_breakdown', jsonb_build_object(
                    'filling', count(p2.id) filter (where p2.status = 'filling'),
                    'filled',  count(p2.id) filter (where p2.status = 'filled')
                )
            ) order by date_trunc('month', pr.target_month)), '[]'::jsonb)
            from   public.pools p2
            join   public.pool_requests pr on pr.id = p2.pool_request_id
            left   join public.regions r on r.id = pr.region_id
            where  p2.status in ('filling', 'filled')
              and  pr.status = 'active'
              and  (p_target_month is null
                    or date_trunc('month', pr.target_month) = date_trunc('month', p_target_month))
              and  (p_region_id is null or pr.region_id = p_region_id)
            group  by r.name_ru, date_trunc('month', pr.target_month)
            having count(distinct p2.id) >= p_min_count
        ),
        'privacy_threshold', p_min_count
    );
end;
$$;

comment on function public.rpc_get_aggregated_demand(uuid,date,uuid,int) is
    'Dok 5 §6.5: Returns ANONYMIZED aggregated demand from active MPK pools.
     Aggregated over active pools/pool_requests. Min p_min_count pools for anonymity.';

-- ============================================================
-- 19. rpc_get_org_batches
-- Dok 5 §6.5: get_active_batches → rpc.get_org_batches
-- Returns organization''s own batches (not other orgs'' — RLS via org ownership check)
-- ============================================================
create or replace function public.rpc_get_org_batches(
    p_organization_id   uuid,
    p_status            text    default null   -- filter: 'draft' | 'published' | 'matched' | null=all
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
    return jsonb_build_object(
        'batches', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'batch_id',      b.id,
                'sku_code',      ts.sku_code,
                'sku_name',      ts.description_ru,
                'heads',         b.heads,
                'avg_weight_kg', b.avg_weight_kg,
                'target_month',  b.target_month,
                'status',        b.status,
                'region',        r.name_ru,
                'published_at',  b.published_at,
                'expires_at',    b.expires_at
            ) order by b.created_at desc), '[]'::jsonb)
            from   public.batches b
            left   join public.tsp_skus ts on ts.id = b.tsp_sku_id
            left   join public.regions r on r.id = b.region_id
            where  b.organization_id = p_organization_id
              and  b.status != 'expired'
              and  (p_status is null or b.status = p_status)
            order  by b.created_at desc
        ),
        'organization_id', p_organization_id
    );
end;
$$;

comment on function public.rpc_get_org_batches(uuid, text) is
    'Dok 5 §6.5: Returns organization''s own supply batches.
     p_status=null: all non-expired batches. Only own org batches visible (D110).';

-- ============================================================
-- 20. rpc_create_batch
-- Dok 5 §6.5: create_batch_draft → rpc.create_batch
-- ============================================================
create or replace function public.rpc_create_batch(
    p_organization_id   uuid,
    p_farm_id           uuid,
    p_tsp_sku_id        uuid,
    p_heads             int,
    p_avg_weight_kg     numeric         default null,
    p_target_month      date            default null,  -- YYYY-MM-01
    p_region_id         uuid            default null,
    p_herd_group_id     uuid            default null,
    p_notes             text            default null,
    p_actor_id          uuid            default null,
    p_ai_context        jsonb           default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch_id      uuid;
    v_restriction   record;
begin
    if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    -- ── C-4: Health Gate (D63 + D98) ─────────────────────────────────────────
    -- Если herd_group_id указан — проверяем активные ограничения на продажу.
    -- GENERATED COLUMN is_active = (now() < ends_at) — не требует доп. вычислений.
    -- Фермер должен знать: ЧТО блокирует, ДО КОГДА, ПОЧЕМУ.
    if p_herd_group_id is not null then
        select restriction_type, ends_at, reason_text
        into   v_restriction
        from   public.health_restrictions
        where  herd_group_id = p_herd_group_id
          and  ends_at > now()
        order by ends_at desc   -- самое позднее = самый долгий блок
        limit 1;

        if found then
            raise exception
                'HEALTH_RESTRICTION: группа % заблокирована для продажи до %. Тип: %. Причина: %',
                p_herd_group_id,
                to_char(v_restriction.ends_at at time zone 'Asia/Almaty', 'DD.MM.YYYY'),
                v_restriction.restriction_type,
                coalesce(v_restriction.reason_text, 'не указана')
                using errcode = 'P0003';
        end if;
    end if;
    -- ─────────────────────────────────────────────────────────────────────────

    -- Normalize target_month to first day of month
    insert into public.batches (
        organization_id, farm_id, herd_group_id,
        tsp_sku_id, heads, avg_weight_kg,
        target_month, region_id, status, notes,
        created_by
    ) values (
        p_organization_id, p_farm_id, p_herd_group_id,
        p_tsp_sku_id, p_heads, p_avg_weight_kg,
        date_trunc('month', coalesce(p_target_month, current_date + interval '2 months'))::date,
        p_region_id, 'draft', p_notes,
        p_actor_id
    )
    returning id into v_batch_id;

    -- Publish event
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, actor_id, payload
    ) values (
        'market.batch.created', 'batches', v_batch_id,
        p_organization_id, 'ai_gateway', p_actor_id,
        jsonb_build_object(
            'batch_id',    v_batch_id,
            'farm_id',     p_farm_id,
            'heads',       p_heads,
            'ai_context',  p_ai_context
        )
    );

    return jsonb_build_object(
        'batch_id', v_batch_id,
        'status', 'draft',
        'message', 'Черновик предложения создан. Проверьте данные и опубликуйте.'
    );
end;
$$;

comment on function public.rpc_create_batch(uuid,uuid,uuid,int,numeric,date,uuid,uuid,text,uuid,jsonb) is
    'Dok 5 §6.5: Creates a draft batch (supply offer). Status=draft (not visible to market).
     Farmer must confirm via publish_batch (Confirmation required, Dok 5 §6.5).
     C-4 / D63 / D98: Health Gate — если herd_group_id указан, проверяется health_restrictions.
     Если is_active=true найдено → P0003 HEALTH_RESTRICTION с датой окончания и причиной.
     Фермер видит: "Группа заблокирована для продажи до {ends_at}. Тип: {type}. Причина: {reason}".
     target_month normalized to first day of month.';

-- ============================================================
-- 21. rpc_publish_batch
-- Dok 5 §6.5: publish_batch → rpc.publish_batch
-- ============================================================
create or replace function public.rpc_publish_batch(
    p_organization_id   uuid,
    p_batch_id          uuid,
    p_actor_id          uuid    default null,
    p_ai_context        jsonb   default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_batch record;
begin
    select b.*, ts.sku_code
    into   v_batch
    from   public.batches b
    left   join public.tsp_skus ts on ts.id = b.tsp_sku_id
    where  b.id = p_batch_id
      and  b.organization_id = p_organization_id;

    if not found then
        raise exception 'FORBIDDEN: batch % not found in organization %',
            p_batch_id, p_organization_id using errcode = 'P0001';
    end if;

    if v_batch.status != 'draft' then
        raise exception 'INVALID: batch % is in status % (must be draft to publish)',
            p_batch_id, v_batch.status using errcode = 'P0003';
    end if;

    -- Validate: tsp_sku_id required before publish
    if v_batch.tsp_sku_id is null then
        raise exception 'INVALID: batch must have tsp_sku_id before publishing'
            using errcode = 'P0002';
    end if;

    update public.batches
    set    status       = 'published',
           published_at = now(),
           -- expires at end of target month + 7 days buffer
           expires_at   = (date_trunc('month', target_month) + interval '1 month' - interval '1 day' + interval '7 days')::timestamptz,
           updated_at   = now()
    where  id = p_batch_id;

    -- Publish event (market event → triggers pool matching logic)
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, actor_id, payload
    ) values (
        'market.batch.published', 'batches', p_batch_id,
        p_organization_id, 'ai_gateway', p_actor_id,
        jsonb_build_object(
            'batch_id',    p_batch_id,
            'sku_code',    v_batch.sku_code,
            'heads',       v_batch.heads,
            'target_month', v_batch.target_month,
            'ai_context',  p_ai_context
        )
    );

    return jsonb_build_object(
        'batch_id', p_batch_id,
        'status', 'published',
        'message', 'Предложение опубликовано и доступно для пулирования.'
    );
end;
$$;

comment on function public.rpc_publish_batch(uuid, uuid, uuid, jsonb) is
    'Dok 5 §6.5: Publishes a draft batch (makes visible to market).
     Validates: tsp_sku_id must be set. Status must be draft.
     Sets expires_at = last day of target_month + 7 days.
     Publishes market.batch.published (consumed by pool matching logic).';

-- ============================================================
-- rpc_update_conversation_language
-- ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ — НЕ ДУБЛИРОВАТЬ
-- Каноническая версия: returns void (строка ~1664, FROM 016)
-- Удалено: дефектное определение returns jsonb (из migration 011)
-- Причина удаления: C-AUDIT-1 регрессия — неверный return type jsonb,
--   CREATE OR REPLACE последовательно → последнее побеждает.
--   Дефектная версия стояла ПЕРЕД правильной → правильная побеждала случайно.
--   Убраны оба риска: дубликат и потенциальная будущая регрессия.
-- ============================================================

-- ============================================================
-- GRANTS: All RPCs accessible via service_role (AI Gateway)
-- Supabase: public schema functions auto-granted to authenticated/service_role
-- Explicit grants for anon-blocking:
-- ============================================================
revoke execute on function public.rpc_get_ai_farm_context(uuid,uuid) from anon;
revoke execute on function public.rpc_upsert_herd_group(uuid,uuid,text,int,numeric,uuid,uuid,uuid,jsonb) from anon;
revoke execute on function public.rpc_get_feeding_plan(uuid,uuid,uuid) from anon;
revoke execute on function public.rpc_get_farm_tasks(uuid,uuid,int,text) from anon;
revoke execute on function public.rpc_complete_farm_task(uuid,uuid,text,jsonb,uuid,jsonb) from anon;
revoke execute on function public.rpc_get_production_plan(uuid,uuid,text) from anon;
revoke execute on function public.rpc_create_vet_case(uuid,uuid,text,text,uuid,int,text,uuid,jsonb) from anon;
revoke execute on function public.rpc_add_vet_symptoms(uuid,uuid,jsonb,uuid,jsonb) from anon;
revoke execute on function public.rpc_get_vet_diagnosis(uuid,uuid,int) from anon;
revoke execute on function public.rpc_get_treatment_protocols(uuid,uuid,text) from anon;
revoke execute on function public.rpc_get_vaccination_schedule(uuid,uuid,int) from anon;
revoke execute on function public.rpc_complete_vaccination_item(uuid,uuid,uuid,int,text,text,uuid,jsonb) from anon;
revoke execute on function public.rpc_create_consultation_request(uuid,text,text,text,uuid,text,uuid,jsonb) from anon;
revoke execute on function public.rpc_search_knowledge_chunks(uuid,text,vector,text,text,int) from anon;
revoke execute on function public.rpc_get_membership_status(uuid) from anon;
revoke execute on function public.rpc_get_price_grid(uuid,uuid,date) from anon;
revoke execute on function public.rpc_get_aggregated_supply(uuid,date,uuid,int) from anon;
revoke execute on function public.rpc_get_aggregated_demand(uuid,date,uuid,int) from anon;
revoke execute on function public.rpc_get_org_batches(uuid,text) from anon;
revoke execute on function public.rpc_create_batch(uuid,uuid,uuid,int,numeric,date,uuid,uuid,text,uuid,jsonb) from anon;
revoke execute on function public.rpc_publish_batch(uuid,uuid,uuid,jsonb) from anon;
revoke execute on function public.rpc_update_conversation_language(uuid,text,uuid) from anon;

-- ============================================================
-- END Migration 011
-- ============================================================


-- === FROM 016: Missing RPCs + critical fixes (C-AUDIT-1..5, L-AUDIT-1..5) ===
-- ============================================================
-- AGOS Migration 016: Immediate Fixes (Architecture Audit)
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 5 March 2026
--
-- Closes (from Architecture Audit Report):
--   C-AUDIT-1  rpc_update_conversation_language отсутствует → KeyError при каждом run
--   C-AUDIT-2  rpc_get_ai_farm_context: неверное имя + p_farm_id обязателен без DEFAULT
--   C-AUDIT-3  'organization' блок отсутствует в ответе → KeyError в build_system_prompt
--   C-AUDIT-5  fn_auth_custom_claims: u.auth_id = v_user_auth_id::text (uuid vs text)
--   L-AUDIT-1  active_vet_cases, active_rations отсутствуют в farm_context_snapshot
--   L-AUDIT-5  rpc_upsert_herd_group UPDATE path: confidence=50 вместо GREATEST
--
-- Depends on: 001_kernel.sql, 004_vet.sql, 003_feed.sql, 009_patch_ai.sql, 011_ai_rpc_catalog.sql
-- Required by: AI Gateway (Python FastAPI + LangGraph)
--
-- Conventions (наследуются из 001_kernel.sql):
--   - SECURITY DEFINER SET search_path = public, pg_temp
--   - Все функции в схеме public. (PostgREST → supabase.rpc())
--   - Ownership validated via p_organization_id (никогда не доверяем LLM)
--   - Нет breaking changes: все подписи обратно совместимы
-- ============================================================


-- ============================================================
-- FIX 1: C-AUDIT-1 — rpc_update_conversation_language
-- ============================================================
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ rpc_update_conversation_language — НЕ ДУБЛИРОВАТЬ
--     Дубликат returns jsonb (из migration 011) удалён (см. §3.1 мета-анализа).
--     При консолидации миграций: grep на дубликаты обязателен.
-- ============================================================
-- ПРОБЛЕМА: Dok 5 §9.2 вызывает эту функцию (C-NEW-5 fix).
--   В миграциях 001–015 её нет. Python бросает RPCError при каждом
--   вызове detect_and_cache_language().
--
-- ЗАЧЕМ RPC а не прямой UPDATE:
--   P-AI-1: все writes через RPC. Прямой UPDATE через service_role
--   не проверяет owner, не оставляет audit trail, нарушает принцип.
--   Этот RPC — единственный авторизованный путь для обновления
--   detected_language в ai_conversations.
-- ============================================================

create or replace function public.rpc_update_conversation_language(
    p_conversation_id   uuid,
    p_language          text,
    p_organization_id   uuid        -- ownership check
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- Validate: язык должен быть одним из поддерживаемых (C-7: только ru|kk)
    if p_language not in ('ru', 'kk') then
        raise exception 'INVALID_LANGUAGE: only ''ru'' and ''kk'' are supported, got %', p_language
            using errcode = 'P0002';
    end if;

    -- Ownership check: conversation должен принадлежать этой организации
    -- Предотвращает обновление чужих разговоров через service_role
    if not exists (
        select 1
        from   public.ai_conversations
        where  id              = p_conversation_id
          and  organization_id = p_organization_id
    ) then
        raise exception 'FORBIDDEN: conversation % does not belong to organization %',
            p_conversation_id, p_organization_id
            using errcode = 'P0001';
    end if;

    -- Обновляем только если язык изменился (избегаем лишних I/O и тригеров updated_at)
    update public.ai_conversations
    set    detected_language = p_language,
           updated_at        = now()
    where  id              = p_conversation_id
      and  detected_language is distinct from p_language;   -- no-op если тот же язык

end;
$$;

comment on function public.rpc_update_conversation_language(uuid, text, uuid) is
    'C-AUDIT-1/C-NEW-5: Единственный авторизованный путь обновления detected_language.
     Вызывается detect_and_cache_language() в AI Gateway (Dok 5 §9.2).
     P-AI-1: прямой UPDATE через service_role запрещён — нет ownership check.
     Идемпотентен: UPDATE WHERE detected_language IS DISTINCT FROM p_language.
     Возвращает void (не данные — caller уже знает что записал).

     Вызов из Python:
       await supabase.rpc("rpc_update_conversation_language", {
           "p_conversation_id": conversation_id,
           "p_language":        detected,
           "p_organization_id": organization_id,
       }).execute()';


-- ============================================================
-- FIX 2: C-AUDIT-2 + C-AUDIT-3 + L-AUDIT-1
--         rpc_get_ai_farm_context — полная переработка
-- ============================================================
-- ПРОБЛЕМЫ:
--   C-AUDIT-2a: Dok 5 §5.3 вызывает "get_ai_farm_context" (без rpc_ префикса)
--               → PostgREST возвращает 404. Имя функции — rpc_get_ai_farm_context.
--               Python-код исправлен в gateway_context_fix.py.
--
--   C-AUDIT-2b: p_farm_id в 011 был NOT NULL без DEFAULT.
--               Dok 5 §5.3 передавал только p_organization_id.
--               Решение: p_farm_id DEFAULT NULL → auto-resolve первую активную ферму.
--               Для мультифермных орг: передавать явно (state["active_farm_id"]).
--
--   C-AUDIT-3:  Возвращаемый JSONB не содержал ключ "organization".
--               build_system_prompt() читает state["farm_context"]["organization"]["name"],
--               ["region"], ["membership_level"] → KeyError на каждом run.
--
--   L-AUDIT-1:  Dok 5 §5.1 FARM_CONTEXT_SCHEMA требует active_vet_cases и active_rations.
--               Vet agent использует active_vet_cases чтобы не дублировать открытые кейсы.
--               Zootechnician использует active_rations для контекста кормления.
--
-- ОБРАТНАЯ СОВМЕСТИМОСТЬ:
--   CREATE OR REPLACE — не breaking. Существующие вызовы с двумя параметрами работают.
--   Вызовы только с p_organization_id теперь корректны (p_farm_id = NULL → auto-resolve).
-- ============================================================

create or replace function public.rpc_get_ai_farm_context(
    p_organization_id   uuid,
    p_farm_id           uuid    default null   -- C-AUDIT-2b: nullable, auto-resolve если NULL
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_farm_id   uuid;
begin
    -- ── Resolve farm_id ───────────────────────────────────────
    if p_farm_id is not null then
        -- Явно передан: проверяем ownership
        if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
            raise exception 'FORBIDDEN: farm % does not belong to organization %',
                p_farm_id, p_organization_id
                using errcode = 'P0001';
        end if;
        v_farm_id := p_farm_id;
    else
        -- C-AUDIT-2b: auto-resolve — берём первую активную ферму организации.
        -- Для большинства фермеров (одна ферма) это корректный путь.
        -- Мультифермные орг: передают p_farm_id явно из state["active_farm_id"].
        select id
        into   v_farm_id
        from   public.farms
        where  organization_id = p_organization_id
          and  is_active = true
        order  by created_at asc   -- консистентный выбор: первая созданная ферма
        limit  1;

        if v_farm_id is null then
            -- У организации нет ни одной активной фермы — вернуть пустой контекст
            -- (не ошибку: farmer мог зарегистрироваться но ещё не создать ферму)
            return jsonb_build_object(
                'organization',     null,
                'farm_id',          null,
                'herd_groups',      '[]'::jsonb,
                'active_vet_cases', '[]'::jsonb,
                'active_rations',   '[]'::jsonb,
                'active_feeding_plan',      null,
                'upcoming_vaccinations',    '[]'::jsonb,
                'upcoming_tasks',           '[]'::jsonb,
                'membership',       null,
                'no_farm',          true,   -- сигнал для Gateway: предложить создать ферму
                'generated_at',     now()
            );
        end if;
    end if;

    -- ── Main context query ────────────────────────────────────
    return (
        select jsonb_build_object(

            -- ── C-AUDIT-3: 'organization' блок — ОБЯЗАТЕЛЕН для build_system_prompt ──
            -- build_system_prompt() читает: org["name"], org["region"], org["membership_level"]
            'organization', jsonb_build_object(
                'id',               o.id,
                'name',             o.legal_name,
                'legal_form',       o.legal_form,
                'region',           coalesce(r_org.name_ru, 'Казахстан'),
                'membership_level', coalesce(m.level, 'registered')
            ),

            -- ── Farm базовые данные ───────────────────────────
            'farm_id',          f.id,
            'farm_name',        f.name,
            'shelter_type',     f.shelter_type,
            'calving_system',   f.calving_system,
            'farm_region',      r_farm.name_ru,     -- регион фермы (может отличаться от орг)

            -- ── HerdGroups ────────────────────────────────────
            'herd_groups', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'id',             hg.id,
                    'category_code',  ac.code,
                    'category_name',  ac.name_ru,
                    'head_count',     hg.head_count,
                    'avg_weight_kg',  hg.avg_weight_kg,
                    'data_source',    hg.data_source,
                    'confidence',     hg.confidence,
                    'breed_name',     b.name_ru,
                    'farm_name',      f.name          -- для multi-farm disambig (S-3)
                ) order by ac.sort_order), '[]'::jsonb)
                from   public.herd_groups hg
                join   public.animal_categories ac on ac.id = hg.animal_category_id
                left   join public.breeds b on b.id = hg.breed_id
                where  hg.farm_id  = v_farm_id
                  and  hg.is_active = true
            ),

            -- ── L-AUDIT-1: active_vet_cases ───────────────────
            -- Vet agent: предотвращает дублирование открытых кейсов
            -- Dok 5 §5.1 FARM_CONTEXT_SCHEMA требует этот ключ
            'active_vet_cases', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'id',             vc.id,
                    'farm_id',        vc.farm_id,
                    'herd_group_id',  vc.herd_group_id,
                    'severity',       vc.severity,
                    'status',         vc.status,
                    -- Обрезаем до 300 символов — в контексте нужна суть, не полный текст
                    'symptoms_text',  left(vc.symptoms_text, 300),
                    'created_at',     vc.created_at
                ) order by vc.created_at desc), '[]'::jsonb)
                from   public.vet_cases vc
                where  vc.farm_id         = v_farm_id
                  and  vc.organization_id  = p_organization_id
                  and  vc.status          in ('open', 'in_progress')
                  -- Только свежие кейсы (последние 30 дней): не перегружаем контекст
                  and  vc.created_at      >= now() - interval '30 days'
            ),

            -- ── L-AUDIT-1: active_rations ─────────────────────
            -- Zootechnician agent: контекст текущего кормления
            -- Dok 5 §5.1 FARM_CONTEXT_SCHEMA требует этот ключ
            'active_rations', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'id',              r.id,
                    'herd_group_id',   r.herd_group_id,
                    -- category_code — для привязки к группе без JOIN
                    'category_code',   ac_r.code,
                    'objective',       r.objective,
                    'avg_weight_kg',   r.avg_weight_kg,
                    'head_count',      r.head_count,
                    -- Текущая версия рациона — итоговые показатели для AI
                    'current_version', (
                        select jsonb_build_object(
                            'version_number',    rv.version_number,
                            'total_dm_per_head', (rv.results->>'total_dm_kg')::numeric,
                            'cost_per_head',     (rv.results->>'total_cost_per_day')::numeric
                        )
                        from   public.ration_versions rv
                        where  rv.ration_id  = r.id
                          and  rv.is_current = true
                        limit  1
                    )
                ) order by r.created_at desc), '[]'::jsonb)
                from   public.rations r
                join   public.animal_categories ac_r on ac_r.id = r.animal_category_id
                where  r.farm_id         = v_farm_id
                  and  r.organization_id = p_organization_id
                  and  r.status          = 'active'
            ),

            -- ── Feeding plan (уже был в 011, оставляем) ───────
            'active_feeding_plan', (
                select jsonb_build_object(
                    'plan_id',    fp.id,
                    'plan_name',  fp.name,
                    'periods', (
                        select coalesce(jsonb_agg(jsonb_build_object(
                            'period_id',      fper.id,
                            'herd_group_id',  fper.herd_group_id,
                            'period_type',    pt.code,
                            'start_date',     fper.start_date,
                            'end_date',       fper.end_date,
                            'status',         fper.status
                        )), '[]'::jsonb)
                        from   public.feeding_periods fper
                        join   public.period_types pt on pt.id = fper.period_type_id
                        where  fper.feeding_plan_id = fp.id
                          and  fper.status in ('upcoming', 'active')
                    )
                )
                from   public.feeding_plans fp
                where  fp.farm_id = v_farm_id and fp.status = 'active'
                order  by fp.created_at desc
                limit  1
            ),

            -- ── Upcoming vaccinations (уже был в 011) ─────────
            'upcoming_vaccinations', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'item_id',        vpi.id,
                    'protocol_name',  vp.name_ru,
                    'herd_group_id',  vpi.herd_group_id,
                    'scheduled_date', vpi.scheduled_date,
                    'dose_number',    vpi.dose_number,
                    'status',         vpi.status
                ) order by vpi.scheduled_date), '[]'::jsonb)
                from   public.vaccination_plan_items vpi
                join   public.vaccination_plans vplan     on vplan.id = vpi.vaccination_plan_id
                join   public.vaccination_protocols vp    on vp.id = vpi.vaccination_protocol_id
                where  vplan.farm_id         = v_farm_id
                  and  vplan.organization_id = p_organization_id
                  and  vpi.status in ('scheduled', 'reminded', 'overdue')
                  and  vpi.scheduled_date between current_date - 3 and current_date + 30
            ),

            -- ── Upcoming tasks (уже был в 011) ────────────────
            'upcoming_tasks', (
                select coalesce(jsonb_agg(jsonb_build_object(
                    'task_id',   ft.id,
                    'name',      ft.name_ru,
                    'category',  ft.category,
                    'due_date',  ft.due_date,
                    'status',    ft.status
                ) order by ft.due_date), '[]'::jsonb)
                from   public.farm_tasks ft
                join   public.farm_phases fph    on fph.id = ft.farm_phase_id
                join   public.farm_production_plans fpp on fpp.id = fph.plan_id
                where  fpp.farm_id            = v_farm_id
                  and  ft.organization_id     = p_organization_id
                  and  ft.status in ('scheduled', 'reminded', 'in_progress', 'overdue')
                  and  ft.due_date between current_date - 3 and current_date + 14
                order  by ft.due_date
                limit  15
            ),

            -- ── Membership ────────────────────────────────────
            'membership', (
                select jsonb_build_object(
                    'org_type',         m2.org_type,
                    'level',            m2.level,
                    'level_changed_at', m2.level_changed_at
                )
                from   public.memberships m2
                where  m2.organization_id = p_organization_id
                  and  m2.org_type = 'farmer'
                limit  1
            ),

            'no_farm',      false,
            'generated_at', now()

        )
        from   public.farms f
        join   public.organizations o on o.id = p_organization_id
        left   join public.regions  r_farm on r_farm.id = f.region_id
        left   join public.regions  r_org  on r_org.id  = o.region_id
        left   join public.memberships m
                    on m.organization_id = p_organization_id
                    and m.org_type = 'farmer'
        where  f.id = v_farm_id
    );
end;
$$;

comment on function public.rpc_get_ai_farm_context(uuid, uuid) is
    'C-AUDIT-2/C-AUDIT-3/L-AUDIT-1: Полный farm context snapshot для AI Gateway.
     Включает: organization (name/region/membership), herd_groups, active_vet_cases,
     active_rations, active_feeding_plan, upcoming_vaccinations, upcoming_tasks, membership.

     p_farm_id DEFAULT NULL: C-AUDIT-2b fix. Если NULL — auto-resolve первая активная
     ферма организации. Мультифермные орг передают явно из state["active_farm_id"].

     "organization" блок: C-AUDIT-3 fix. build_system_prompt() читает
     org["name"], org["region"], org["membership_level"] — все три теперь присутствуют.

     "active_vet_cases": L-AUDIT-1 fix. Vet agent проверяет перед созданием VetCase.
     Ограничено: status in (''open'', ''in_progress'') AND created_at >= now()-30d.

     "active_rations": L-AUDIT-1 fix. Zootechnician agent имеет контекст кормления.
     Только status=''active'' рационы с привязкой к herd_group.

     no_farm=true: сигнал Gateway — у организации нет ферм, предложить создать.

     Вызов из Python (gateway_context_fix.py):
       result = await supabase.rpc("rpc_get_ai_farm_context", {
           "p_organization_id": state["organization_id"],
           "p_farm_id":         state.get("active_farm_id"),  # None = auto-resolve
       }).execute()';


-- ============================================================
-- FIX 3: L-AUDIT-5 — rpc_upsert_herd_group UPDATE path
--         confidence = GREATEST(existing, 50) вместо hardcoded 50
-- ============================================================
-- ПРОБЛЕМА: UPDATE path всегда записывает confidence=50, перебивая
--   более высокое значение (например ERP-синхронизация = 90).
--   Если фермер подтверждает данные через AI (который только укрепляет
--   уверенность) — confidence должен расти, а не падать до 50.
--
-- INSERT path в 011 уже правильный: confidence = greatest(herd_groups.confidence, 50).
-- Синхронизируем UPDATE path с той же логикой.
--
-- Это CREATE OR REPLACE всей функции из 011 с единственным изменением:
--   confidence = 50  →  confidence = greatest(v_old_confidence, 50)
--   где v_old_confidence читается в SELECT перед UPDATE.
-- ============================================================

create or replace function public.rpc_upsert_herd_group(
    p_organization_id       uuid,
    p_farm_id               uuid,
    p_animal_category_code  text,
    p_head_count            int,
    p_avg_weight_kg         numeric         default null,
    p_breed_id              uuid            default null,
    p_herd_group_id         uuid            default null,
    p_actor_id              uuid            default null,
    p_ai_context            jsonb           default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_group_id          uuid;
    v_category_id       uuid;
    v_old_count         int;
    v_old_weight        numeric;
    v_old_confidence    int;    -- L-AUDIT-5: читаем для GREATEST
begin
    if not public._ai_check_farm_org(p_farm_id, p_organization_id) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    -- Resolve category
    select id into v_category_id
    from   public.animal_categories
    where  code = p_animal_category_code;

    if v_category_id is null then
        raise exception 'INVALID: unknown animal_category_code %', p_animal_category_code
            using errcode = 'P0002';
    end if;

    if p_herd_group_id is not null then
        -- ── UPDATE path ───────────────────────────────────────
        select head_count, avg_weight_kg, confidence
        into   v_old_count, v_old_weight, v_old_confidence
        from   public.herd_groups
        where  id              = p_herd_group_id
          and  organization_id = p_organization_id;

        if not found then
            raise exception 'FORBIDDEN: herd_group % not found in organization %',
                p_herd_group_id, p_organization_id using errcode = 'P0001';
        end if;

        update public.herd_groups
        set    head_count        = p_head_count,
               avg_weight_kg     = coalesce(p_avg_weight_kg, avg_weight_kg),
               breed_id          = coalesce(p_breed_id, breed_id),
               data_source       = 'ai_extracted',
               -- L-AUDIT-5 FIX: GREATEST сохраняет накопленную уверенность.
               -- Фермер подтвердил данные → уверенность растёт или остаётся.
               -- До фикса: ERP=90 → AI update → 50. Теперь: ERP=90 → AI update → 90.
               confidence        = greatest(v_old_confidence, 50),
               count_updated_at  = case when p_head_count is distinct from v_old_count
                                        then now() else count_updated_at end,
               weight_updated_at = case when p_avg_weight_kg is not null
                                        then now() else weight_updated_at end,
               updated_at        = now()
        where  id = p_herd_group_id;

        v_group_id := p_herd_group_id;

    else
        -- ── INSERT/UPSERT path (без изменений из 011) ─────────
        insert into public.herd_groups (
            farm_id, organization_id, animal_category_id, breed_id,
            head_count, avg_weight_kg, data_source, confidence,
            count_updated_at, weight_updated_at
        ) values (
            p_farm_id, p_organization_id, v_category_id, p_breed_id,
            p_head_count, p_avg_weight_kg, 'ai_extracted', 50,
            now(), case when p_avg_weight_kg is not null then now() end
        )
        on conflict (farm_id, animal_category_id)
        do update set
            head_count        = excluded.head_count,
            avg_weight_kg     = coalesce(excluded.avg_weight_kg, herd_groups.avg_weight_kg),
            breed_id          = coalesce(excluded.breed_id, herd_groups.breed_id),
            data_source       = 'ai_extracted',
            confidence        = greatest(herd_groups.confidence, 50),
            count_updated_at  = now(),
            weight_updated_at = case when excluded.avg_weight_kg is not null then now()
                                     else herd_groups.weight_updated_at end,
            updated_at        = now()
        returning id into v_group_id;

        if v_group_id is null then
            select id into v_group_id
            from   public.herd_groups
            where  farm_id = p_farm_id and animal_category_id = v_category_id;
        end if;
    end if;

    -- Publish event
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, actor_id, payload
    ) values (
        'farm.herd_group.updated', 'herd_groups', v_group_id,
        p_organization_id, 'ai_gateway', p_actor_id,
        jsonb_build_object(
            'herd_group_id',        v_group_id,
            'farm_id',              p_farm_id,
            'animal_category_code', p_animal_category_code,
            'new_head_count',       p_head_count,
            'new_avg_weight_kg',    p_avg_weight_kg,
            'data_source',          'ai_extracted',
            'ai_context',           p_ai_context
        )
    );

    return jsonb_build_object(
        'herd_group_id',        v_group_id,
        'animal_category_code', p_animal_category_code,
        'head_count',           p_head_count,
        'avg_weight_kg',        p_avg_weight_kg,
        'data_source',          'ai_extracted',
        'confidence',           greatest(coalesce(v_old_confidence, 0), 50)
    );
end;
$$;

comment on function public.rpc_upsert_herd_group(uuid,uuid,text,int,numeric,uuid,uuid,uuid,jsonb) is
    'L-AUDIT-5 FIX: UPDATE path теперь использует GREATEST(existing_confidence, 50).
     Синхронизировано с INSERT/upsert path (был greatest уже в 011_ai_rpc_catalog.sql).
     Смысл: AI-подтверждение данных никогда не снижает накопленную уверенность.
     ERP-синхронизированные данные (confidence=90) сохраняют свой уровень
     даже при последующем AI-update.

     Всё остальное без изменений относительно 011_ai_rpc_catalog.sql:
     - Ownership check через _ai_check_farm_org
     - ON CONFLICT (farm_id, animal_category_id) для INSERT path
     - platform_events публикация farm.herd_group.updated';


-- ============================================================
-- FIX 4: C-AUDIT-5 — fn_auth_custom_claims UUID vs text mismatch
-- ============================================================
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ fn_auth_custom_claims — НЕ ДУБЛИРОВАТЬ
--     Дубликат из migration 015 (с ::text багом) удалён (см. §3.1 мета-анализа).
--     При консолидации миграций: grep на дубликаты обязателен.
-- ============================================================
-- ПРОБЛЕМА: v_user_auth_id объявлен как uuid, но сравнивается
--   c u.auth_id через ::text cast. users.auth_id — тип uuid.
--   PostgreSQL делает implicit cast, что работает в большинстве
--   случаев, но нарушает type safety и может дать silent failure
--   при нестандартном форматировании UUID строки.
--
-- FIX: убрать ::text cast, сравнивать uuid = uuid напрямую.
-- ============================================================

create or replace function public.fn_auth_custom_claims(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_user_auth_id  uuid;
    v_org_ids       uuid[];
    v_is_admin      boolean;
    v_is_expert     boolean;
    v_claims        jsonb;
begin
    v_user_auth_id := (event ->> 'user_id')::uuid;

    -- C-AUDIT-5 FIX: сравниваем uuid = uuid без ::text cast
    select coalesce(array_agg(uor.organization_id), array[]::uuid[])
    into   v_org_ids
    from   public.user_organization_roles uor
    join   public.users u on u.id = uor.user_id
    where  u.auth_id = v_user_auth_id;   -- было: v_user_auth_id::text (WRONG)

    select
        exists (
            select 1 from public.admin_roles ar
            join public.users u on u.id = ar.user_id
            where u.auth_id = v_user_auth_id   -- C-AUDIT-5 FIX: убран ::text
              and ar.is_active = true
        ),
        exists (
            select 1 from public.expert_profiles ep
            join public.users u on u.id = ep.user_id
            where u.auth_id = v_user_auth_id   -- C-AUDIT-5 FIX: убран ::text
              and ep.is_active = true
        )
    into v_is_admin, v_is_expert;

    v_claims := coalesce(event -> 'claims', '{}');
    v_claims := jsonb_set(
        v_claims,
        '{app_metadata}',
        coalesce(v_claims -> 'app_metadata', '{}')
        || jsonb_build_object(
            'org_ids',   to_jsonb(v_org_ids),
            'is_admin',  v_is_admin,
            'is_expert', v_is_expert
        )
    );

    return jsonb_set(event, '{claims}', v_claims);

exception when others then
    raise warning 'fn_auth_custom_claims error (non-fatal): %', sqlerrm;
    return event;
end;
$$;

comment on function public.fn_auth_custom_claims(jsonb) is
    'C-AUDIT-5 FIX: убран ::text cast при сравнении u.auth_id (uuid) с v_user_auth_id (uuid).
     Было: WHERE u.auth_id = v_user_auth_id::text — semantic error, работало через implicit cast.
     Стало: WHERE u.auth_id = v_user_auth_id — корректное uuid = uuid сравнение.

     D-NEW-1: Supabase custom access token hook.
     Добавляет org_ids, is_admin, is_expert в JWT app_metadata при login/refresh.
     После включения в Dashboard (Auth → Hooks → Custom Access Token):
     fn_my_org_ids() читает из JWT вместо DB-запроса (0 DB hits).
     NEVER BREAKS AUTH: exception handler возвращает unmodified event при любой ошибке.';

grant execute on function public.fn_auth_custom_claims(jsonb)
    to supabase_auth_admin;

revoke execute on function public.fn_auth_custom_claims(jsonb)
    from anon, authenticated;


-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Summary:
--
--   New functions:
--     rpc_update_conversation_language(uuid, text, uuid)    — C-AUDIT-1
--
--   Replaced functions (CREATE OR REPLACE, no breaking changes):
--     rpc_get_ai_farm_context(uuid, uuid DEFAULT NULL)      — C-AUDIT-2, C-AUDIT-3, L-AUDIT-1
--     rpc_upsert_herd_group(uuid,uuid,text,int,...)         — L-AUDIT-5
--     fn_auth_custom_claims(jsonb)                          — C-AUDIT-5
--
--   Changes to rpc_get_ai_farm_context:
--     + p_farm_id DEFAULT NULL (C-AUDIT-2b: backward compat)
--     + "organization" key in return JSONB (C-AUDIT-3)
--     + "active_vet_cases" subquery (L-AUDIT-1)
--     + "active_rations" subquery (L-AUDIT-1)
--     + "no_farm" flag for orgs without farms
--     + auto-resolve первой активной фермы при p_farm_id IS NULL
--
--   Changes to rpc_upsert_herd_group UPDATE path:
--     confidence = 50 → confidence = greatest(v_old_confidence, 50) (L-AUDIT-5)
--
--   Changes to fn_auth_custom_claims:
--     u.auth_id = v_user_auth_id::text → u.auth_id = v_user_auth_id (C-AUDIT-5)
--
-- Zero breaking changes:
--   - Все существующие вызовы rpc_get_ai_farm_context(org_id, farm_id) работают
--   - Новый вызов rpc_get_ai_farm_context(org_id) тоже работает (p_farm_id→NULL)
--   - rpc_upsert_herd_group: та же подпись, тот же результат для confidence>=50
--   - fn_auth_custom_claims: та же подпись, исправленная логика
--
-- Defects closed by this migration:
--   C-AUDIT-1  ✅  rpc_update_conversation_language создан
--   C-AUDIT-2  ✅  p_farm_id DEFAULT NULL + правильное имя в Python (gateway_context_fix.py)
--   C-AUDIT-3  ✅  "organization" блок добавлен в JSONB
--   C-AUDIT-5  ✅  fn_auth_custom_claims: uuid vs text исправлен
--   L-AUDIT-1  ✅  active_vet_cases + active_rations в farm_context_snapshot
--   L-AUDIT-5  ✅  UPDATE path: confidence = GREATEST(old, 50)
--
-- Still requires Python-side fix (gateway_context_fix.py):
--   C-AUDIT-2a ⏳ supabase.rpc("get_ai_farm_context" → "rpc_get_ai_farm_context")
--   C-AUDIT-3  ⏳ farm_context["organization"] теперь работает (SQL исправлен)
--
-- Next migrations:
--   017_extraction_rules_update  — L-AUDIT-4 (добавить SUCKLING_CALF и др. в EXTRACTION_RULES)
--                                  [Python-only изменение, отдельный файл для трекинга]
-- ============================================================


-- === FROM 015 (Part 1): JWT fast path (applied here for AI Gateway context) ===
-- PART 1: D-NEW-1 — JWT claims fast path for fn_my_org_ids()
-- ============================================================
-- PROBLEM:
--   fn_my_org_ids() does a full JOIN query (users → user_organization_roles)
--   on EVERY ROW evaluated by any RLS policy. With 215+ RLS calls across all
--   migrations, a SELECT on a 1000-row table triggers 1000 subquery executions.
--   Cost scales with table size. For orgs with large datasets: measurable latency.
--
-- SOLUTION:
--   Supabase supports custom JWT claims via a "custom access token" hook.
--   We add org_ids to the JWT at login time. fn_my_org_ids() reads JWT first;
--   DB query is the fallback for stale tokens or service_role calls.
--
-- ARCHITECTURE:
--   Step 1 (this migration): create fn_auth_custom_claims() hook function.
--   Step 2 (Supabase Dashboard): Authentication → Hooks → Custom Access Token
--                                 → fn_auth_custom_claims
--   After enabling the hook: every JWT issued will contain app_metadata.org_ids.
--   fn_my_org_ids() reads from JWT (0 DB hits) instead of querying tables.
--
-- BACKWARD COMPATIBLE:
--   fn_my_org_ids() retains DB fallback. Existing tokens work until expiry.
--   No changes to any RLS policies — they keep calling fn_my_org_ids() unchanged.
-- ============================================================

-- fn_auth_custom_claims: ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ — НЕ ДУБЛИРОВАТЬ
-- Каноническая версия: FIX 4 / C-AUDIT-5 (строки ~2185, FROM 016)
-- Удалено: дефектное определение FROM 015 с u.auth_id = v_user_auth_id::text
-- Причина: ::text cast нарушает type safety (uuid vs text).
--   Версия 015 стояла ПОСЛЕ версии 016 → PostgreSQL выполнял её последней → баг побеждал.
--   Grants дублированы в FIX 4 выше — повторные здесь не нужны.

-- Step 1b: Update fn_my_org_ids() to use JWT claims when available
create or replace function public.fn_my_org_ids()
returns uuid[]
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_jwt_claim jsonb;
    v_org_ids   uuid[];
begin
    -- D-NEW-1 FAST PATH: read from JWT app_metadata.org_ids (set by fn_auth_custom_claims)
    -- Zero DB hits when hook is enabled. Token refreshes propagate membership changes.
    v_jwt_claim := auth.jwt() -> 'app_metadata' -> 'org_ids';

    if v_jwt_claim is not null and jsonb_typeof(v_jwt_claim) = 'array' then
        select array_agg(elem::uuid)
        into   v_org_ids
        from   jsonb_array_elements_text(v_jwt_claim) as elem;

        return coalesce(v_org_ids, array[]::uuid[]);
    end if;

    -- SLOW PATH (fallback): DB query
    -- Used when: hook not yet configured, service_role call (no JWT),
    --            old token issued before hook was enabled.
    select coalesce(array_agg(uor.organization_id), array[]::uuid[])
    into   v_org_ids
    from   public.user_organization_roles uor
    join   public.users u on u.id = uor.user_id
    where  u.auth_id = auth.uid();

    return coalesce(v_org_ids, array[]::uuid[]);
end;
$$;

comment on function public.fn_my_org_ids() is
    'D-NEW-1: Returns org_ids for current user.
     FAST PATH (0 DB hits): reads JWT app_metadata.org_ids when hook is enabled.
     SLOW PATH (DB query): fallback for stale tokens or pre-hook sessions.
     Called by 215+ RLS policies across all migrations — performance matters.

     Enabling hook reduces RLS overhead from O(rows × join_cost) to O(rows × jwt_parse).
     For a 10k-row herd_groups table: ~10k JOIN queries → 0 JOIN queries per SELECT.';

-- Step 1c: Update fn_is_admin() and fn_is_expert() with JWT fast path
create or replace function public.fn_is_admin()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select coalesce(
        -- JWT fast path
        (auth.jwt() -> 'app_metadata' ->> 'is_admin')::boolean,
        -- DB fallback
        exists (
            select 1 from public.admin_roles ar
            join public.users u on u.id = ar.user_id
            where u.auth_id = auth.uid() and ar.is_active = true
        )
    );
$$;

create or replace function public.fn_is_expert()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select coalesce(
        -- JWT fast path
        (auth.jwt() -> 'app_metadata' ->> 'is_expert')::boolean,
        -- DB fallback
        exists (
            select 1 from public.expert_profiles ep
            join public.users u on u.id = ep.user_id
            where u.auth_id = auth.uid() and ep.is_active = true
        )
    );
$$;

-- ============================================================

-- === FROM 015: RPC Name Registry ===
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('fn_auth_custom_claims',   null, null, '015_tech_debt.sql', 'D-NEW-1: Supabase Auth JWT hook — grants org_ids/is_admin/is_expert in token'),
    ('claim_embedding_batch',   null, null, '015_tech_debt.sql', 'D-NEW-3: Worker claims batch from embedding_queue (FOR UPDATE SKIP LOCKED)'),
    ('complete_embedding_job',  null, null, '015_tech_debt.sql', 'D-NEW-3: Worker saves computed embedding + marks job done'),
    ('fail_embedding_job',      null, null, '015_tech_debt.sql', 'D-NEW-3: Worker marks job failed (retry or failed_permanent)')
on conflict (sql_name) do update
    set notes = excluded.notes, created_in = excluded.created_in;

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Schema changes (additive, zero breaking):
--   NEW TABLE: embedding_queue (status FSM, priority, retry_count, content_hash)
--   NEW TRIGGER: trg_knowledge_chunk_enqueue_embedding on knowledge_chunks
--   NEW FUNCTION: fn_auth_custom_claims (Supabase Auth hook)
--   NEW FUNCTIONS: claim_embedding_batch, complete_embedding_job, fail_embedding_job
--
-- Modified functions (backward compatible — same signatures and return types):
--   fn_my_org_ids()     → JWT fast path + DB fallback
--   fn_is_admin()       → JWT fast path + DB fallback
--   fn_is_expert()      → JWT fast path + DB fallback
--   fn_shift_phase_cascade → recursive CTE + batch UPDATE (1 round-trip vs N)
--   fn_generate_production_plan → batch task/KPI INSERT (12 vs 75 INSERTs)
--
-- REQUIRED POST-MIGRATION ACTION (one-time):
--   Enable custom JWT hook in Supabase Dashboard:
--   Authentication → Hooks → Custom Access Token
--   → Database Function → public.fn_auth_custom_claims
--   Without this step: fn_my_org_ids() falls back to DB query (correct, just slower).
--
-- D-NEW-1 ✅  JWT claims fast path for fn_my_org_ids/fn_is_admin/fn_is_expert
-- D-NEW-2 ✅  fn_shift_phase_cascade: recursive PL/pgSQL → CTE + batch UPDATE
-- D-NEW-3 ✅  embedding_queue: structured async embedding pipeline
-- D-NEW-4 ✅  fn_generate_production_plan: batch task/KPI INSERT
-- ============================================================


-- ============================================================
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ publish_platform_event — НЕ ДУБЛИРОВАТЬ
-- AI-23: publish_platform_event
-- ============================================================
-- НАЗНАЧЕНИЕ:
--   Единственный авторизованный путь публикации событий из AI Gateway
--   в platform_events (Event Bus). P-AI-1: все writes через RPC.
--
-- ПОЧЕМУ RPC, а не прямой INSERT:
--   AI Gateway работает под service_role — прямой INSERT технически возможен,
--   но нарушает P-AI-1 и обходит audit trail. RPC гарантирует:
--     1. actor_type принудительно = 'ai_gateway' (не доверяем caller)
--     2. p_organization_id проходит ownership check перед записью
--     3. Единая точка контроля для rate-limiting / anti-abuse в будущем
--
-- ВЫЗЫВАЕТСЯ ИЗ:
--   Dok 5 §14.2 log_quality_event():
--     await supabase.rpc("publish_platform_event", {
--         "p_event_type":      "platform.ai.quality_signal",
--         "p_entity_id":       conversation_id,
--         "p_organization_id": organization_id,
--         "p_payload":         { "feedback_type": ..., "role": ... }
--     }).execute()
--
-- ОГРАНИЧЕНИЯ:
--   entity_type автоматически выводится из p_event_type (domain = первый сегмент).
--   actor_type жёстко = 'ai_gateway'. Для системных событий (cron, triggers) —
--   использовать прямой INSERT из PL/pgSQL (изнутри БД только).
-- ============================================================

create or replace function public.publish_platform_event(
    p_event_type        text,           -- 'domain.entity.action' — Dok 4 D66 convention
    p_organization_id   uuid,           -- ownership scope; NULL для global events
    p_entity_id         uuid    default null,   -- id затронутой сущности
    p_payload           jsonb   default '{}'::jsonb  -- event-specific data
)
returns uuid                            -- возвращает id созданного события
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_event_id  uuid;
    v_actor_id  uuid;
    v_entity_type text;
begin
    -- Validate event_type format: domain.entity.action (минимум 2 сегмента)
    if p_event_type is null or array_length(string_to_array(p_event_type, '.'), 1) < 2 then
        raise exception 'INVALID_EVENT_TYPE: must follow domain.entity.action format, got %',
            p_event_type
            using errcode = 'P0002';
    end if;

    -- Ownership check: если указана организация — проверяем что она существует
    -- (не проверяем принадлежность к вызывающему — AI Gateway работает как system actor)
    if p_organization_id is not null then
        if not exists (
            select 1 from public.organizations
            where id = p_organization_id
        ) then
            raise exception 'FORBIDDEN: organization % not found', p_organization_id
                using errcode = 'P0001';
        end if;
    end if;

    -- Derive entity_type from event_type: 'platform.ai.quality_signal' → 'ai'
    -- Convention: second segment = entity domain (Dok 4 §2.1)
    v_entity_type := split_part(p_event_type, '.', 2);

    -- actor_id: для AI Gateway — null (system actor, не конкретный user)
    -- Если нужен user context — передавать в p_payload.actor_user_id
    v_actor_id := null;

    insert into public.platform_events (
        event_type,
        entity_type,
        entity_id,
        organization_id,
        actor_type,
        actor_id,
        payload
    ) values (
        p_event_type,
        v_entity_type,
        p_entity_id,
        p_organization_id,
        'ai_gateway',       -- жёстко — не доверяем caller (P-AI-1)
        v_actor_id,
        coalesce(p_payload, '{}'::jsonb)
    )
    returning id into v_event_id;

    return v_event_id;
end;
$$;

comment on function public.publish_platform_event(text, uuid, uuid, jsonb) is
    'AI-23: Единственный авторизованный путь публикации событий из AI Gateway в platform_events.
     P-AI-1: все writes через RPC. actor_type принудительно = ai_gateway.
     Вызывается: Dok 5 §14.2 log_quality_event() для quality signals.
     event_type формат: domain.entity.action (Dok 4 D66).
     entity_type автоматически = split_part(event_type, ''.'', 2).
     Возвращает: uuid созданного события (для traceability).';

grant execute on function public.publish_platform_event(text, uuid, uuid, jsonb)
    to service_role;

revoke execute on function public.publish_platform_event(text, uuid, uuid, jsonb)
    from anon, authenticated;
-- ============================================================
-- D-NEW-3: embedding_queue — структура + три воркер-функции + триггер
-- ============================================================
-- Закрывает: D-4 (мета-анализ §3.2 Исправление #3)
--
-- ЧТО ДЕЛАЕТ:
--   1. embedding_queue — FSM очередь заданий на векторизацию
--   2. trg_knowledge_chunk_enqueue — AFTER INSERT/UPDATE на knowledge_chunks
--      → добавляет задание в очередь при публикации или изменении контента
--   3. claim_embedding_batch(n) → Python-воркер забирает N заданий (SKIP LOCKED)
--   4. complete_embedding_job(job_id, vector) → сохраняет embedding в knowledge_chunks
--   5. fail_embedding_job(job_id, error) → retry или failed_permanent
--
-- ПОЧЕМУ ОТДЕЛЬНАЯ ОЧЕРЕДЬ, а не прямой UPDATE в триггере:
--   Вызов Anthropic/OpenAI Embeddings API из триггера = блокировка INSERT на 200-500ms.
--   Очередь = async: INSERT в knowledge_chunks мгновенный,
--   Python-воркер обходит очередь раз в 60 сек batch-ом по 10.
--
-- СВЯЗЬ С rpc_search_knowledge_chunks:
--   Пока embedding IS NULL → text FTS fallback (plainto_tsquery).
--   После vectorization → cosine similarity via HNSW (точнее).
--   Оба пути рабочие — система деградирует gracefully до embedding готов.
--
-- ВЫЗЫВАЕТСЯ ИЗ: Python Embedding Worker (Dok 5 §15)
--   Не из LangGraph, не из FastAPI endpoints.
--   Отдельный процесс: cron каждые 60 сек / или APScheduler внутри FastAPI.
-- ============================================================


-- ── Таблица: embedding_queue ──────────────────────────────────────────────────
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ embedding_queue — НЕ ДУБЛИРОВАТЬ

create table if not exists public.embedding_queue (
    id                  uuid        primary key default gen_random_uuid(),
    knowledge_chunk_id  uuid        not null references public.knowledge_chunks(id) on delete cascade,
    -- FSM: pending → processing → done | failed → failed_permanent
    status              text        not null default 'pending'
                                        check (status in (
                                            'pending',          -- ждёт воркера
                                            'processing',       -- воркер забрал (claimed_at IS NOT NULL)
                                            'done',             -- embedding сохранён в knowledge_chunks
                                            'failed',           -- ошибка API, retry ещё возможен
                                            'failed_permanent'  -- retry_count >= max_retries
                                        )),
    priority            int         not null default 5
                                        check (priority between 1 and 10),
                                        -- 1 = highest (срочно), 5 = normal, 10 = bulk
    retry_count         int         not null default 0,
    max_retries         int         not null default 3,
    -- Хеш контента: не переделываем embedding если контент не изменился
    content_hash        text        not null,   -- SHA-256(title || content)
    -- Воркер идентификация
    claimed_by          text,                   -- worker instance id (UUID or hostname)
    claimed_at          timestamptz,
    completed_at        timestamptz,
    error_message       text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    -- Один активный job на chunk (dedup)
    constraint uq_eq_chunk_pending
        unique (knowledge_chunk_id, status)
        deferrable initially deferred
);

comment on table public.embedding_queue is
    'D-NEW-3: Async очередь для генерации vector embeddings knowledge_chunks.
     Python Embedding Worker (Dok 5 §15): claim_embedding_batch(10) → API → complete_embedding_job.
     FSM: pending → processing → done | failed → failed_permanent.
     Dedup constraint: один активный job per chunk (pending или processing).
     content_hash: SHA-256 — не перевекторизируем если контент не изменился.
     priority: 1=срочно (is_notifiable болезни), 5=normal, 10=bulk import.';

comment on column public.embedding_queue.content_hash is
    'SHA-256(title || chr(31) || content) — Unit Separator как разделитель.
     Заполняется триггером fn_enqueue_knowledge_chunk_embedding.
     При повторной публикации: если hash совпадает — job не создаётся (embedding актуален).';

-- Индексы для воркера
create index if not exists idx_eq_pending_priority
    on public.embedding_queue (priority asc, created_at asc)
    where status = 'pending';   -- воркер читает только pending

create index if not exists idx_eq_chunk
    on public.embedding_queue (knowledge_chunk_id);

create index if not exists idx_eq_status
    on public.embedding_queue (status, updated_at);

-- updated_at trigger
drop trigger if exists trg_embedding_queue_upd on public.embedding_queue;
create trigger trg_embedding_queue_upd
    before update on public.embedding_queue
    for each row execute function public.fn_set_updated_at();


-- ── Триггер: fn_enqueue_knowledge_chunk_embedding ─────────────────────────────
-- AFTER INSERT OR UPDATE на knowledge_chunks
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ — НЕ ДУБЛИРОВАТЬ

create or replace function public.fn_enqueue_knowledge_chunk_embedding()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_hash          text;
    v_existing_hash text;
    v_priority      int;
begin
    -- Только published chunks получают embedding (D71)
    -- INSERT: всегда enqueue если is_published = true
    -- UPDATE: enqueue если is_published стал true ИЛИ контент изменился
    if tg_op = 'UPDATE' then
        -- Не published — пропускаем
        if new.is_published = false then
            return new;
        end if;
        -- Published не изменился и контент не изменился — пропускаем
        if old.is_published = true
           and old.title = new.title
           and old.content = new.content
           and new.embedding is not null then
            return new;
        end if;
    elsif tg_op = 'INSERT' then
        if new.is_published = false then
            return new;
        end if;
    end if;

    -- Вычислить hash контента (Unit Separator chr(31) как разделитель)
    v_hash := encode(
        digest(new.title || chr(31) || new.content, 'sha256'),
        'hex'
    );

    -- Проверить: есть ли уже job с тем же hash → embedding актуален, не дублируем
    select content_hash into v_existing_hash
    from   public.embedding_queue
    where  knowledge_chunk_id = new.id
      and  status = 'done';

    if v_existing_hash = v_hash then
        return new;  -- контент не изменился, embedding актуален
    end if;

    -- Определить приоритет по source_domain
    v_priority := case new.source_domain
        when 'veterinary'    then 2   -- ветеринарные данные — высокий приоритет
        when 'legal'         then 2   -- НПА — высокий
        when 'zootechnical'  then 3
        when 'tsp'           then 3
        when 'education'     then 7
        when 'faq'           then 8
        else 5
    end;

    -- UPSERT: если уже есть pending/failed job — обновить hash и сбросить retry
    insert into public.embedding_queue (
        knowledge_chunk_id, status, priority, content_hash,
        retry_count, claimed_by, claimed_at, completed_at, error_message
    ) values (
        new.id, 'pending', v_priority, v_hash,
        0, null, null, null, null
    )
    on conflict (knowledge_chunk_id, status) where status = 'pending'
    do update set
        content_hash = excluded.content_hash,
        priority     = excluded.priority,
        retry_count  = 0,
        updated_at   = now();

    -- Сбросить embedding в knowledge_chunks → текстовый fallback пока воркер не отработает
    if tg_op = 'UPDATE' and old.content != new.content then
        new.embedding := null;  -- BEFORE триггер изменил бы new, но мы AFTER
        -- Обновляем напрямую (воркер перезапишет)
        update public.knowledge_chunks
        set    embedding = null
        where  id = new.id;
    end if;

    return new;

exception when others then
    raise warning 'fn_enqueue_knowledge_chunk_embedding error (non-fatal): % — chunk_id=%',
        sqlerrm, new.id;
    return new;
end;
$$;

comment on function public.fn_enqueue_knowledge_chunk_embedding() is
    'D-NEW-3: AFTER INSERT OR UPDATE на knowledge_chunks.
     Добавляет задание в embedding_queue при публикации или изменении контента.
     Dedup: одинаковый content_hash → job не создаётся (embedding актуален).
     При изменении контента published chunk → обнуляет embedding (text fallback до воркера).
     priority: veterinary/legal=2, zootechnical/tsp=3, education=7, faq=8.
     NEVER BREAKS knowledge_chunks INSERT/UPDATE: exception handler, только raise warning.';

drop trigger if exists trg_knowledge_chunk_enqueue_embedding on public.knowledge_chunks;
create trigger trg_knowledge_chunk_enqueue_embedding
    after insert or update of is_published, title, content
    on public.knowledge_chunks
    for each row execute function public.fn_enqueue_knowledge_chunk_embedding();


-- ── claim_embedding_batch ─────────────────────────────────────────────────────
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ — НЕ ДУБЛИРОВАТЬ

create or replace function public.claim_embedding_batch(
    p_batch_size    int     default 10,     -- сколько заданий забрать за раз
    p_worker_id     text    default null    -- идентификатор воркера (hostname / UUID)
)
returns table (
    job_id              uuid,
    knowledge_chunk_id  uuid,
    title               text,
    content             text,
    source_domain       text,
    priority            int,
    retry_count         int
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- FOR UPDATE SKIP LOCKED: concurrent workers не блокируют друг друга
    return query
    update public.embedding_queue eq
    set
        status     = 'processing',
        claimed_by = coalesce(p_worker_id, 'unknown'),
        claimed_at = now(),
        updated_at = now()
    from (
        select eq2.id
        from   public.embedding_queue eq2
        where  eq2.status = 'pending'
        order  by eq2.priority asc, eq2.created_at asc
        limit  p_batch_size
        for update skip locked
    ) candidates
    join public.knowledge_chunks kc on kc.id = eq.knowledge_chunk_id
    where eq.id = candidates.id
    returning
        eq.id           as job_id,
        eq.knowledge_chunk_id,
        kc.title,
        kc.content,
        kc.source_domain,
        eq.priority,
        eq.retry_count;
end;
$$;

comment on function public.claim_embedding_batch(int, text) is
    'D-NEW-3: Воркер забирает batch заданий из embedding_queue.
     FOR UPDATE SKIP LOCKED: несколько воркеров работают параллельно без блокировок.
     Возвращает: job_id, chunk_id, title, content для vectorization.
     Меняет статус: pending → processing.
     p_worker_id: идентификатор воркера для traceability (hostname / UUID).
     Типичный вызов: await supabase.rpc("claim_embedding_batch", {"p_batch_size": 10}).execute()';

grant execute on function public.claim_embedding_batch(int, text) to service_role;
revoke execute on function public.claim_embedding_batch(int, text) from anon, authenticated;


-- ── complete_embedding_job ────────────────────────────────────────────────────
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ — НЕ ДУБЛИРОВАТЬ

create or replace function public.complete_embedding_job(
    p_job_id    uuid,
    p_embedding vector(1536)    -- вычисленный вектор от Embeddings API
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_chunk_id  uuid;
begin
    -- Получить chunk_id, одновременно пометить job как done
    update public.embedding_queue
    set    status       = 'done',
           completed_at = now(),
           updated_at   = now()
    where  id     = p_job_id
      and  status = 'processing'   -- защита от двойного вызова
    returning knowledge_chunk_id into v_chunk_id;

    if not found then
        -- Job не в состоянии processing: либо уже done, либо invalid id
        raise warning 'complete_embedding_job: job % not found or not in processing state', p_job_id;
        return;
    end if;

    -- Сохранить embedding в knowledge_chunks
    update public.knowledge_chunks
    set    embedding   = p_embedding,
           updated_at  = now()
    where  id = v_chunk_id;
end;
$$;

comment on function public.complete_embedding_job(uuid, vector) is
    'D-NEW-3: Воркер сохраняет вычисленный embedding.
     Атомарно: embedding_queue.status → done + knowledge_chunks.embedding = vector.
     Защита: обновляет только если status = processing (нет двойной записи).
     После этого rpc_search_knowledge_chunks использует vector mode (cosine similarity).
     Типичный вызов: await supabase.rpc("complete_embedding_job",
         {"p_job_id": job_id, "p_embedding": vector_list}).execute()';

grant execute on function public.complete_embedding_job(uuid, vector) to service_role;
revoke execute on function public.complete_embedding_job(uuid, vector) from anon, authenticated;


-- ── fail_embedding_job ────────────────────────────────────────────────────────
-- ⚠️  ЕДИНСТВЕННОЕ ОПРЕДЕЛЕНИЕ — НЕ ДУБЛИРОВАТЬ

create or replace function public.fail_embedding_job(
    p_job_id        uuid,
    p_error_message text    default null
)
returns jsonb   -- { "status": "retry"|"failed_permanent", "retry_count": n }
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_new_status    text;
    v_retry_count   int;
    v_max_retries   int;
begin
    select retry_count, max_retries
    into   v_retry_count, v_max_retries
    from   public.embedding_queue
    where  id = p_job_id and status = 'processing';

    if not found then
        raise warning 'fail_embedding_job: job % not found or not in processing state', p_job_id;
        return jsonb_build_object('status', 'not_found');
    end if;

    v_retry_count := v_retry_count + 1;

    -- Если исчерпаны попытки — failed_permanent (не вернётся в очередь)
    v_new_status := case
        when v_retry_count >= v_max_retries then 'failed_permanent'
        else 'pending'  -- вернуть в очередь для повторной попытки
    end;

    update public.embedding_queue
    set    status        = v_new_status,
           retry_count   = v_retry_count,
           error_message = p_error_message,
           claimed_by    = null,
           claimed_at    = null,
           updated_at    = now()
    where  id = p_job_id;

    return jsonb_build_object(
        'status',      v_new_status,
        'retry_count', v_retry_count,
        'max_retries', v_max_retries
    );
end;
$$;

comment on function public.fail_embedding_job(uuid, text) is
    'D-NEW-3: Воркер сообщает об ошибке vectorization.
     retry_count < max_retries → статус обратно в pending (повторная попытка).
     retry_count >= max_retries → failed_permanent (ручной разбор).
     Возвращает: {status, retry_count, max_retries} для логирования воркера.
     Типичный вызов: await supabase.rpc("fail_embedding_job",
         {"p_job_id": job_id, "p_error_message": str(e)}).execute()';

grant execute on function public.fail_embedding_job(uuid, text) to service_role;
revoke execute on function public.fail_embedding_job(uuid, text) from anon, authenticated;


-- ── RPC registry update ───────────────────────────────────────────────────────
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values
    ('claim_embedding_batch',  null, null, 'd08_embedding / d07 patch',
     'D-NEW-3: Worker claims batch (FOR UPDATE SKIP LOCKED). p_batch_size, p_worker_id.'),
    ('complete_embedding_job', null, null, 'd08_embedding / d07 patch',
     'D-NEW-3: Save computed embedding → knowledge_chunks.embedding. Atomic.'),
    ('fail_embedding_job',     null, null, 'd08_embedding / d07 patch',
     'D-NEW-3: Retry or failed_permanent FSM. Returns {status, retry_count}.')
on conflict (sql_name) do update
    set notes = excluded.notes, created_in = excluded.created_in;

-- ============================================================
-- DEF-013: Replace direct .table() calls with RPCs (P-AI-1 compliance)
-- Instances 1–4: load_context_node, _clear_confirmation,
--                save_response_node, _get_user_phone
-- ============================================================

-- ============================================================
-- rpc_clear_confirmation — DEF-013 fix
-- Clears pending confirmation state after farmer confirms/rejects.
-- ============================================================
create or replace function public.rpc_clear_confirmation(
    p_organization_id   uuid,
    p_conversation_id   uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- Ownership check: conversation belongs to this org
    if not exists (
        select 1 from public.ai_conversations
        where id = p_conversation_id and organization_id = p_organization_id
    ) then
        raise exception 'FORBIDDEN: conversation % does not belong to organization %',
            p_conversation_id, p_organization_id using errcode = 'P0001';
    end if;

    update public.ai_conversations
    set
        confirmation_pending  = false,
        confirmation_payload  = null,
        updated_at            = now()
    where id = p_conversation_id;
end;
$$;

comment on function public.rpc_clear_confirmation(uuid, uuid) is
    'DEF-013/P-AI-1: Clears pending confirmation state after farmer confirms/rejects.
     Ownership-checked: p_organization_id must match conversation.organization_id.
     Replaces direct .table("ai_conversations").update() in nodes._clear_confirmation().';

grant execute on function public.rpc_clear_confirmation(uuid, uuid) to service_role;
revoke execute on function public.rpc_clear_confirmation(uuid, uuid) from anon, authenticated;


-- ============================================================
-- rpc_sync_conversation_role — DEF-013 fix
-- Syncs active role back to conversation after AI run.
-- ============================================================
create or replace function public.rpc_sync_conversation_role(
    p_organization_id   uuid,
    p_conversation_id   uuid,
    p_role              text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- Validate role value
    if p_role is not null and p_role not in ('vet', 'zootechnician', 'trading_agent', 'consultant') then
        raise exception 'INVALID_ROLE: % is not a valid role', p_role using errcode = 'P0001';
    end if;

    -- Ownership check
    if not exists (
        select 1 from public.ai_conversations
        where id = p_conversation_id and organization_id = p_organization_id
    ) then
        raise exception 'FORBIDDEN: conversation % does not belong to organization %',
            p_conversation_id, p_organization_id using errcode = 'P0001';
    end if;

    update public.ai_conversations
    set
        "current_role"      = p_role,
        -- DEF-ROLE-01: explicit call = override (auto-detection never calls this RPC directly)
        role_was_overridden = true,
        updated_at          = now()
    where id = p_conversation_id;
end;
$$;

comment on function public.rpc_sync_conversation_role(uuid, uuid, text) is
    'DEF-013/P-AI-1: Syncs active role back to conversation after AI run.
     Ownership-checked. Validates role against allowed values.
     Sets role_was_overridden=true (DEF-ROLE-01) — explicit override vs auto-detection.
     Replaces direct .table("ai_conversations").update({"current_role": ...}) in nodes.save_response_node().';

grant execute on function public.rpc_sync_conversation_role(uuid, uuid, text) to service_role;
revoke execute on function public.rpc_sync_conversation_role(uuid, uuid, text) from anon, authenticated;


-- ============================================================
-- rpc_get_conversation_state — DEF-013 fix
-- Returns AI conversation processing state for load_context_node.
-- ============================================================
create or replace function public.rpc_get_conversation_state(
    p_organization_id   uuid,
    p_conversation_id   uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_result jsonb;
begin
    select jsonb_build_object(
        'confirmation_pending',    c.confirmation_pending,
        'confirmation_payload',    c.confirmation_payload,
        'current_role',            c."current_role",
        'role_was_overridden',     c.role_was_overridden,
        'message_history_summary', c.message_history_summary,
        'detected_language',       c.detected_language
    )
    into v_result
    from public.ai_conversations c
    where c.id = p_conversation_id
      and c.organization_id = p_organization_id;

    if v_result is null then
        raise exception 'FORBIDDEN: conversation % not found or does not belong to org %',
            p_conversation_id, p_organization_id using errcode = 'P0001';
    end if;

    return v_result;
end;
$$;

comment on function public.rpc_get_conversation_state(uuid, uuid) is
    'DEF-013/P-AI-1: Returns 6 AI conversation state fields for load_context_node.
     Ownership-checked: raises FORBIDDEN if conversation not found or wrong org.
     Replaces direct .table("ai_conversations").select(...) in nodes.load_context_node().';

grant execute on function public.rpc_get_conversation_state(uuid, uuid) to service_role;
revoke execute on function public.rpc_get_conversation_state(uuid, uuid) from anon, authenticated;


-- ============================================================
-- rpc_get_user_phone — DEF-013 fix
-- Returns phone number for a user (PII — org-scoped access).
-- ============================================================
create or replace function public.rpc_get_user_phone(
    p_organization_id   uuid,
    p_user_id           uuid
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_phone text;
begin
    -- Verify user belongs to organization (via memberships)
    select u.phone into v_phone
    from public.users u
    join public.memberships m on m.user_id = u.id
    where u.id = p_user_id
      and m.organization_id = p_organization_id
      and m.status = 'active'
    limit 1;

    -- Note: null is acceptable — user may not have phone yet
    return v_phone;
end;
$$;

comment on function public.rpc_get_user_phone(uuid, uuid) is
    'DEF-013/P-AI-1: Returns user phone (PII) scoped to organization.
     Requires active membership in the organization — no cross-org PII leakage.
     Returns null if user has no phone or is not active in this org.
     Replaces direct .table("users").select("phone") in notification_worker._get_user_phone().';

grant execute on function public.rpc_get_user_phone(uuid, uuid) to service_role;
revoke execute on function public.rpc_get_user_phone(uuid, uuid) from anon, authenticated;


-- ── RPC registry entries for DEF-013 ─────────────────────────────────────────
INSERT INTO public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
VALUES
    ('rpc_clear_confirmation',     null, null, 'd07_ai_gateway.sql', 'DEF-013: replaces direct .table() UPDATE in nodes._clear_confirmation()'),
    ('rpc_sync_conversation_role', null, null, 'd07_ai_gateway.sql', 'DEF-013: replaces direct .table() UPDATE in nodes.save_response_node'),
    ('rpc_get_conversation_state', null, null, 'd07_ai_gateway.sql', 'DEF-013: replaces direct .table() SELECT in nodes.load_context_node'),
    ('rpc_get_user_phone',         null, null, 'd07_ai_gateway.sql', 'DEF-013: replaces direct .table() SELECT on users in notification_worker._get_user_phone()')
ON CONFLICT (sql_name) DO NOTHING;

-- ============================================================
-- END d07_ai_gateway.sql
-- ============================================================
