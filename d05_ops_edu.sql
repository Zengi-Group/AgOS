-- ============================================================
-- AGOS Schema: d05_ops_edu
-- Project: TURAN Agricultural Operating System
-- Consolidated: 2026-03-05 (pre-development baseline)
--
-- Operations module (Production Plans, Phases, Tasks, KPIs)
-- + Education module (Courses, Modules, Lessons, Enrollments).
-- CTK seed data for Kazakhstan Cow-Calf production cycle.
-- Cascade date shift logic. fn_generate_production_plan.
--
-- Depends on: d01_kernel.sql, d03_feed.sql, d04_vet.sql
-- Consolidated from: 005_ops_edu.sql, 006_patch_ops.sql, 007_ctk_seed.sql, 008_patch_cascade__1_.sql, 010_fn_generate_production_plan__1_.sql, 012_patch_production_plan_auth.sql, 015_tech_debt.sql (ops parts)
--
-- Convention: All statements are idempotent.
--   CREATE TABLE IF NOT EXISTS
--   CREATE OR REPLACE FUNCTION
--   ALTER TABLE ADD COLUMN IF NOT EXISTS
--   INSERT ... ON CONFLICT DO NOTHING
-- ============================================================
-- ============================================================
-- AGOS Migration 005: OPERATIONS + EDUCATION MODULES
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 4 March 2026
--
-- Part A: Operations (10 tables)
--   Reference (6):  production_cycle_templates*, phase_templates*,
--                   task_templates*, sop_documents*,
--                   task_template_sops*, kpi_templates*
--   Operational (4): farm_production_plans, farm_phases,
--                    farm_tasks, farm_kpis
--
-- Part B: Education (8 tables)
--   courses, modules, lessons,
--   course_enrollments, user_progress, certificates,
--   course_preregistrations, course_instructors
--
-- Decisions implemented:
--   D73  Operations = separate domain (Farm = data, Operations = work plan)
--   D74  Template → Plan: system generates, expert adapts
--   D75  Feed/Vet plans NOT subordinate to FarmPhase (coordinate by dates)
--   D76  SOPDocument = files in Supabase Storage
--   D77  FarmTask.erp_sync = AGOS↔ERP boundary
--   D78  Cycle ≠ calendar year (calving to calving)
--   D79  Expert consults farm via expert_profile_id in FarmProductionPlan
--   D80  FarmTask completion: WhatsApp primary (AI Gateway confirms)
--   D81  FarmPhase (sale) → TSP supply prediction (by dates, not FK)
--   D82  One FarmProductionPlan per farm (farm thinks as one unit)
--   D83  TaskTemplateSOP many-to-many (one SOP used by multiple tasks)
--   D85  7 Operations event types in Event Bus (ops.*)
--   D86  SOPDocument indexed in KnowledgeChunk (source_domain=zootechnical)
--   D12  EDU.DC merges into AGOS (one auth, one User, Data Flywheel)
--   D13  Course → Module → Lesson 3-level hierarchy preserved
--   D14  CourseInstructor = ExpertProfile (experts are entities)
--   D15  UserProgress at Lesson level (granular tracking)
--   D16  Free courses for any registered user
--   D17  AI Knowledge → KnowledgeChunk (source_domain=education)
--
-- FSMs implemented:
--   FarmProductionPlan: draft → active → completed             (Dok 1 5.7)
--   FarmPhase: upcoming → active → completed | skipped         (Dok 1 5.7)
--   FarmTask:  scheduled → reminded → in_progress → completed | skipped | overdue (Dok 1 5.7)
--   FarmKPI:   pending → achieved | missed                     (Dok 1 5.7)
--   Course:    draft → coming_soon | published                  (Dok 1 5.7)
--   CourseEnrollment: enrolled → in_progress → completed | expired (Dok 1 5.7)
--
-- Event Bus (Dok 1 Section 5.5, events 19–25, D85):
--   19: ops.plan.activated    → Expert → Notification (farmer), AI context
--   20: ops.phase.started     → System (cron) → AI weekly briefing
--   21: ops.phase.completed   → System → Next phase trigger, Analytics
--   22: ops.task.due_soon     → System (cron) → Notification via AI WhatsApp
--   23: ops.task.overdue      → System (cron) → Notification farmer + expert
--   24: ops.task.completed    → Farmer/AI/ERP → HerdEvent (cross-domain RPC), KPI update
--   25: ops.kpi.missed        → System → Notification (expert), plan review
--   Education:
--   18: education.enrollment.completed → System → Certificate issue, Notification
--
-- Cross-domain integration:
--   D75: FarmPhase ↔ FeedingPeriod, FarmPhase ↔ VaccinationPlanItem
--        — coordinate by overlapping dates, NOT FK
--   D81: FarmPhase (sale_preparation) → TSP supply prediction
--        — FarmPhase.target_sale_month read by AI/TSP RPC (Dok 3)
--   D80+D77: FarmTask.completed → HerdEvent cross-domain
--        — some task categories auto-create HerdEvent (Dok 3 RPC)
--   D86: SOPDocument → KnowledgeChunk trigger (source_domain=zootechnical)
--   D17: Course/Lesson content → KnowledgeChunk (source_domain=education)
--
-- Open questions (do NOT block this migration):
--   Q65: Full CTK template data — zootechnician fills via Expert Console
--   Q67: KPI measurement: structured form vs free text to AI — Dok 6
--   Q68: Multiple production lines on one farm — D82 says one plan, but
--        multiple HerdGroups per FarmPhase handles most cases
--   Q70: Expert dashboard metrics — Dok 6 scope
--   Q11: EDU.DC migration plan — data migration, not schema
--
-- Depends on: 001_kernel.sql (organizations, farms, herd_groups,
--             users, expert_profiles, knowledge_chunks, payments,
--             purchased_products, platform_events)
-- ============================================================

-- ============================================================
-- PART A: OPERATIONS MODULE (10 tables)
-- ============================================================

-- ============================================================
-- SECTION A1: REFERENCE TABLES (6 tables)
-- P8: Templates = Standards as Data. Updated by zootechnicians
-- via Expert Console. No code deployment needed.
-- Template hierarchy: ProductionCycleTemplate → PhaseTemplate
--                     → TaskTemplate → SOPDocument
--                     PhaseTemplate → KPITemplate
-- ============================================================

-- -------------------------------------------------------
-- production_cycle_templates
-- D78: Цикл ≠ календарный год. Цикл = отёл → отёл (~12 мес).
-- D74: Шаблон → основа для генерации FarmProductionPlan.
-- Зоотехник ТУРАН разрабатывает шаблоны по типу хозяйства.
-- -------------------------------------------------------
create table if not exists public.production_cycle_templates (
    id                  uuid    primary key default gen_random_uuid(),
    code                text    not null unique,  -- 'BEEF_COW_CALF_KZ', 'BEEF_FINISHING_KZ'
    name_ru             text    not null,
    description_ru      text,
    -- Тип хозяйства
    farm_type           text    not null
                                    check (farm_type in (
                                        'cow_calf',     -- маточное: отёл + подсос
                                        'finishing',    -- откорм на убой
                                        'combined',     -- маточное + откорм
                                        'breeding'      -- племенное
                                    )),
    -- D78: длительность цикла в днях (~365 для cow_calf, ~180 для finishing)
    cycle_duration_days int     not null check (cycle_duration_days > 0),
    -- Какой породной направленности (nullable = любая)
    productivity_direction_id   uuid    references public.productivity_directions(id),
    -- Минимальный размер стада для применения шаблона
    min_herd_size       int     default 1,
    is_active           boolean not null default true,
    sort_order          int     not null default 0,
    notes               text,
    created_by          uuid    references public.expert_profiles(id),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.production_cycle_templates is
    'D74: Шаблон производственного цикла. Зоотехник ТУРАН создаёт через Expert Console.
     D78: Цикл = от отёла до отёла (~365 дней для cow_calf), не = январь-декабрь.
     Q65: Начальный контент вносит зоотехник (не сидируется здесь — нет данных).
     Seed: минимальный набор типов. Зоотехник наполняет фазами через Expert Console.';

-- -------------------------------------------------------
-- phase_templates
-- D74: Фазы в составе шаблона цикла.
-- Порядок задаётся sort_order. Даты вычисляются от cycle_start_date.
-- -------------------------------------------------------
create table if not exists public.phase_templates (
    id                          uuid    primary key default gen_random_uuid(),
    cycle_template_id           uuid    not null references public.production_cycle_templates(id) on delete cascade,
    code                        text    not null,     -- 'CALVING', 'SUCKLING', 'WEANING', 'FINISHING'
    name_ru                     text    not null,
    description_ru              text,
    -- Позиция фазы в цикле
    sort_order                  int     not null default 0,
    -- Длительность (дни от начала предыдущей фазы)
    -- offset_from_cycle_start_days: старт фазы = cycle_start_date + offset
    offset_from_cycle_start_days    int not null default 0,
    duration_days               int     not null check (duration_days > 0),
    -- Категория: на какие HerdGroup применяется (подсказка, не constraint)
    applicable_category_hint    text,  -- 'cows', 'calves', 'steers' — для генерации
    -- D81: фаза продажи? AI и TSP используют для прогноза предложения
    is_sale_phase               boolean not null default false,
    -- D75: связи с Feed/Vet по датам — не FK. Но подсказки для генерации:
    suggested_period_type_code  text,   -- 'calving', 'suckling', 'stall', 'pasture'
    unique (cycle_template_id, code),
    created_at                  timestamptz not null default now(),
    updated_at                  timestamptz not null default now()
);
comment on table public.phase_templates is
    'D74: Фаза в шаблоне цикла. Даты = cycle_start_date + offset.
     D75: suggested_period_type_code — подсказка для генерации FeedingPeriod.
           Связь Feed↔Ops только через данные (даты), не FK.
     D81: is_sale_phase=true → AI отслеживает avg_weight_kg группы и предлагает создать Batch.';

-- -------------------------------------------------------
-- task_templates
-- D74: Типовые задачи в составе фазы.
-- D80: WhatsApp как основной способ отметки выполнения.
-- -------------------------------------------------------
create table if not exists public.task_templates (
    id                  uuid    primary key default gen_random_uuid(),
    phase_template_id   uuid    not null references public.phase_templates(id) on delete cascade,
    code                text    not null,           -- 'WEIGH_CALVES', 'VACCINATE_FMD'
    name_ru             text    not null,
    description_ru      text,
    category            text    not null
                                    check (category in (
                                        'zootechnical', -- взвешивание, бонитировка, сортировка
                                        'veterinary',   -- вакцинация, лечение, диагностика
                                        'management'    -- закупка, продажа, отчётность
                                    )),
    -- Когда выполнять: смещение от начала фазы
    offset_from_phase_start_days    int not null default 0,
    -- D77: нужна ли синхронизация с ERP (задачи с индивидуальным учётом)
    erp_sync_required   boolean not null default false,
    -- D80: как AI задаст вопрос о выполнении в WhatsApp
    ai_completion_question_ru   text,  -- 'Взвесили бычков? Какой средний вес?'
    -- Что AI извлекает из ответа фермера (подсказка для Dok 5)
    -- [{field: 'avg_weight_kg', unit: 'kg', entity: 'herd_group'}]
    ai_extraction_hints jsonb,
    -- Результат задачи генерирует HerdEvent? (D80 cross-domain)
    creates_herd_event  boolean not null default false,
    herd_event_type     text    check (
                            herd_event_type in (
                                'weight_update', 'head_count_change', 'birth',
                                'death', 'sale', 'purchase', 'weaning',
                                'breeding_start', 'breeding_end',
                                'calving_start', 'calving_end',
                                'stall_start', 'stall_end',
                                'pasture_start', 'pasture_end'
                            )
                        ),
    -- D83: SOPs через junction table task_template_sops
    is_active           boolean not null default true,
    sort_order          int     not null default 0,
    unique (phase_template_id, code),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.task_templates is
    'D80: ai_completion_question_ru — как AI спрашивает у фермера в WhatsApp.
     D80: ai_extraction_hints — что AI извлекает из ответа → validates via RPC (Dok 3).
     D77: erp_sync_required=true → FarmTask.erp_sync флаг устанавливается.
     D80: creates_herd_event=true → при complete FarmTask система создаёт HerdEvent.
     herd_event_type: CHECK constraint ссылается на тип, не FK — перечисление стабильно.
     D83: SOPs — отдельная таблица task_template_sops (many-to-many).';

-- -------------------------------------------------------
-- sop_documents
-- D76: SOPs = реальные файлы (PDF/docx) в Supabase Storage.
-- D86: При публикации → KnowledgeChunk для RAG-поиска.
-- -------------------------------------------------------
create table if not exists public.sop_documents (
    id                  uuid    primary key default gen_random_uuid(),
    code                text    not null unique,   -- 'SOP_CALVING_ASSISTANCE', 'SOP_FMD_VACCINATION'
    title_ru            text    not null,
    category            text    not null
                                    check (category in (
                                        'zootechnical',
                                        'veterinary',
                                        'management',
                                        'safety'
                                    )),
    -- D76: файл в Supabase Storage
    storage_url         text,                      -- null = SOP написан но не загружен
    file_format         text    check (file_format in ('pdf', 'docx', 'md')),
    file_size_bytes     int,
    version             text    not null default '1.0',
    -- D86: связь с KnowledgeChunk (заполняется триггером при публикации)
    knowledge_chunk_id  uuid    references public.knowledge_chunks(id),
    -- Жизненный цикл
    status              text    not null default 'draft'
                                    check (status in (
                                        'draft',
                                        'published',    -- D86: триггер создаёт KnowledgeChunk
                                        'archived'
                                    )),
    published_at        timestamptz,
    authored_by         uuid    references public.expert_profiles(id),
    reviewed_by         uuid    references public.expert_profiles(id),
    notes               text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.sop_documents is
    'D76: Файлы в Supabase Storage. storage_url = путь к файлу.
     D86: Триггер fn_sop_create_knowledge_chunk: при status→published
          создаёт KnowledgeChunk (source_domain=zootechnical).
          AI находит SOPs через семантический поиск pgvector.
     Пример: фермер спрашивает "как помочь при трудных родах?" →
             AI ищет в KnowledgeChunk → находит SOP_CALVING_ASSISTANCE →
             отправляет ссылку на PDF.';

-- -------------------------------------------------------
-- task_template_sops
-- D83: many-to-many TaskTemplate ↔ SOPDocument.
-- Один SOP может применяться в нескольких задачах.
-- -------------------------------------------------------
create table if not exists public.task_template_sops (
    id                  uuid    primary key default gen_random_uuid(),
    task_template_id    uuid    not null references public.task_templates(id) on delete cascade,
    sop_document_id     uuid    not null references public.sop_documents(id),
    -- Как именно связаны: SOP обязателен к прочтению перед задачей, или справочно
    relation_type       text    not null default 'reference'
                                    check (relation_type in (
                                        'required',     -- обязательно для выполнения задачи
                                        'reference'     -- справочный материал
                                    )),
    unique (task_template_id, sop_document_id),
    created_at          timestamptz not null default now()
);
comment on table public.task_template_sops is
    'D83: Один SOP → много задач (e.g., SOP_FMD_VACCINATION используется в весенней и осенней фазах).
     D86: AI видит задачу → ищет связанные SOPs → отправляет фермеру нужный документ.
     APPEND-ONLY: нет updated_at.';

-- -------------------------------------------------------
-- kpi_templates
-- Целевые показатели для фазы. Зоотехник задаёт нормативы.
-- FarmKPI.target_value берётся отсюда при генерации плана.
-- -------------------------------------------------------
create table if not exists public.kpi_templates (
    id                  uuid    primary key default gen_random_uuid(),
    phase_template_id   uuid    not null references public.phase_templates(id) on delete cascade,
    code                text    not null,           -- 'AVG_WEIGHT_GAIN', 'CALVING_RATE', 'MORTALITY_RATE'
    name_ru             text    not null,
    description_ru      text,
    -- Тип измерения
    kpi_type            text    not null
                                    check (kpi_type in (
                                        'weight_gain_kg',       -- прирост живой массы
                                        'daily_gain_g',         -- среднесуточный прирост (г)
                                        'calving_rate_pct',     -- выход телят (%)
                                        'mortality_rate_pct',   -- падёж (%)
                                        'feed_conversion',      -- конверсия корма
                                        'conception_rate_pct',  -- оплодотворяемость (%)
                                        'custom_numeric'        -- произвольный числовой показатель
                                    )),
    unit                text    not null,           -- 'kg', 'g/day', '%', 'kg/kg'
    -- Нормативные значения (целевые)
    target_value        numeric(10,4),
    -- Допустимые границы для оценки achieved/missed
    -- achieved: actual >= target * (1 - tolerance_pct/100)
    tolerance_pct       numeric(5,2) not null default 5.0,
    -- Направление: больше = лучше или меньше = лучше
    higher_is_better    boolean not null default true,
    -- Q67: измерение — структурированное или через AI
    -- measurement_source уточняется в Dok 6
    is_active           boolean not null default true,
    unique (phase_template_id, code),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.kpi_templates is
    'Нормативные KPI для фазы. Зоотехник задаёт target_value и tolerance_pct.
     Q67: Как измеряется actual_value — отдельный вопрос (Dok 6).
     Для weight_gain: берётся из HerdGroup.avg_weight_kg (начало и конец фазы).
     Для calving_rate: задаётся фермером или AI извлекает из диалога.
     FarmKPI.status = achieved если actual >= target * (1 - tolerance_pct/100).';

-- ============================================================
-- SECTION A2: OPERATIONAL TABLES (4 tables)
-- ============================================================

-- -------------------------------------------------------
-- farm_production_plans
-- D82: Один план на ферму (фермер думает "моя ферма в марте").
-- D79: Зоотехник ТУРАН ведёт ферму через expert_profile_id.
-- D74: Генерируется из шаблона, потом адаптируется экспертом.
-- -------------------------------------------------------
create table if not exists public.farm_production_plans (
    id                      uuid    primary key default gen_random_uuid(),
    farm_id                 uuid    not null references public.farms(id),
    organization_id         uuid    not null references public.organizations(id), -- denorm RLS
    cycle_template_id       uuid    not null references public.production_cycle_templates(id),
    -- D79: зоотехник, ведущий эту ферму
    expert_profile_id       uuid    references public.expert_profiles(id),
    name                    text    not null,   -- 'Цикл 2026 — ферма Берекет'
    -- D78: дата начала цикла (не обязательно 1 января)
    cycle_start_date        date    not null,
    cycle_end_date          date,              -- вычисляется: start + cycle_duration_days
    -- FSM (Dok 1 5.7)
    status                  text    not null default 'draft'
                                        check (status in (
                                            'draft',      -- план создан, редактируется экспертом
                                            'active',     -- фермер уведомлён, задачи идут
                                            'completed',  -- цикл завершён
                                            'cancelled'   -- план отменён (ферма вышла из программы)
                                        )),
    -- D82: один активный план на ферму (проверяется RPC, не UNIQUE — нужен partial index)
    activated_at            timestamptz,
    completed_at            timestamptz,
    notes                   text,
    created_by              uuid    references public.users(id),
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now()
);
comment on table public.farm_production_plans is
    'D82: Один активный план на ферму.
     Partial unique index: только один status=active per farm_id.
     D79: expert_profile_id — зоотехник ТУРАН ведёт ферму (адаптирует план, отслеживает KPI).
     D78: cycle_start_date = дата первого отёла цикла.
     D74: сначала expert создаёт план из шаблона (RPC), потом адаптирует фазы вручную.
     Event #19: ops.plan.activated → Notification (farmer) + AI context update.';

-- D82: только один active план на ферму
create unique index if not exists idx_farm_plan_one_active
    on public.farm_production_plans (farm_id)
    where status = 'active';

-- -------------------------------------------------------
-- farm_phases
-- D74: Генерируется из phase_templates при создании плана.
-- D75: Координация с Feed/Vet — по датам, не FK.
-- D81: is_sale_phase=true → TSP supply prediction.
-- -------------------------------------------------------
create table if not exists public.farm_phases (
    id                  uuid    primary key default gen_random_uuid(),
    plan_id             uuid    not null references public.farm_production_plans(id) on delete cascade,
    organization_id     uuid    not null references public.organizations(id), -- denorm RLS
    phase_template_id   uuid    references public.phase_templates(id), -- null = вручную добавлена
    -- Какая группа животных (D75: по датам Ops ↔ Vet ↔ Feed)
    herd_group_id       uuid    references public.herd_groups(id),
    name_ru             text    not null,
    -- Даты конкретной фазы для этой фермы (эксперт может сдвинуть)
    start_date          date    not null,
    end_date            date    not null,
    check (end_date > start_date),
    -- D81: если фаза предполагает продажу — целевой месяц для TSP
    is_sale_phase       boolean not null default false,
    target_sale_month   date,  -- первый день месяца, e.g. 2026-05-01
    -- FSM (Dok 1 5.7)
    status              text    not null default 'upcoming'
                                    check (status in (
                                        'upcoming',     -- создана, ещё не началась
                                        'active',       -- start_date наступил
                                        'completed',    -- end_date прошёл или все задачи выполнены
                                        'skipped'       -- эксперт пропустил (нет животных в группе)
                                    )),
    skip_reason         text,
    notes               text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.farm_phases is
    'D75: FarmPhase координируется с FeedingPeriod и VaccinationPlanItem через overlapping dates.
     Query pattern: SELECT * FROM feeding_periods fp
                    WHERE fp.herd_group_id = farm_phases.herd_group_id
                    AND daterange(fp.start_date, fp.end_date) && daterange(start_date, end_date)
     D81: is_sale_phase=true + target_sale_month → AI/TSP RPC агрегируют предложение.
     Events: #20 ops.phase.started (cron, start_date), #21 ops.phase.completed.';

-- -------------------------------------------------------
-- farm_tasks
-- D80: WhatsApp — основной интерфейс подтверждения.
-- D77: erp_sync — граница AGOS↔ERP.
-- D80: creates_herd_event — некоторые задачи порождают HerdEvent.
-- -------------------------------------------------------
create table if not exists public.farm_tasks (
    id                  uuid    primary key default gen_random_uuid(),
    farm_phase_id       uuid    not null references public.farm_phases(id) on delete cascade,
    organization_id     uuid    not null references public.organizations(id), -- denorm RLS
    task_template_id    uuid    references public.task_templates(id), -- null = вручную создана
    name_ru             text    not null,
    category            text    not null
                                    check (category in (
                                        'zootechnical',
                                        'veterinary',
                                        'management'
                                    )),
    due_date            date    not null,
    -- FSM (Dok 1 5.7)
    status              text    not null default 'scheduled'
                                    check (status in (
                                        'scheduled',    -- запланировано
                                        'reminded',     -- напоминание отправлено
                                        'in_progress',  -- фермер/эксперт начал
                                        'completed',    -- выполнено
                                        'skipped',      -- пропущено с причиной
                                        'overdue'       -- срок прошёл
                                    )),
    skip_reason         text,
    -- D77: нужна ли синхронизация с ERP
    erp_sync            boolean not null default false,
    erp_synced_at       timestamptz,
    -- D80: результат выполнения (что фермер сообщил AI)
    -- Структура зависит от task_template (ai_extraction_hints)
    -- Пример: {avg_weight_kg: 380, head_count: 45, notes: "бычки в хорошей форме"}
    result_data         jsonb,
    -- D80: creates_herd_event=true → RPC создаст HerdEvent при complete
    herd_event_created  boolean not null default false,
    herd_event_id       uuid    references public.herd_events(id),
    -- Timestamps reminder flow (аналогично VaccinationPlanItem)
    reminded_at         timestamptz,
    overdue_notified_at timestamptz,
    completed_by        uuid    references public.users(id),
    completed_at        timestamptz,
    notes               text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.farm_tasks is
    'D80: Основной способ отметки = WhatsApp. AI задаёт вопрос из task_template.ai_completion_question_ru.
     AI извлекает result_data из ответа (ai_extraction_hints подсказывает поля).
     D77: erp_sync=true → внешний ERP подтверждает выполнение (erp_synced_at).
     D80: herd_event_created=true при complete + creates_herd_event шаблона →
          RPC fn_complete_farm_task создаёт HerdEvent + публикует farm.herd_group.updated.
     Events: #22 ops.task.due_soon (3 дня до due_date, cron),
             #23 ops.task.overdue (день после due_date),
             #24 ops.task.completed → HerdEvent + KPI update.';

-- -------------------------------------------------------
-- farm_kpis
-- Привязан к фазе. Actual измеряется системой или AI.
-- FSM: pending → achieved | missed.
-- -------------------------------------------------------
create table if not exists public.farm_kpis (
    id                  uuid    primary key default gen_random_uuid(),
    farm_phase_id       uuid    not null references public.farm_phases(id) on delete cascade,
    organization_id     uuid    not null references public.organizations(id), -- denorm RLS
    kpi_template_id     uuid    not null references public.kpi_templates(id),
    -- Целевое значение (берётся из шаблона, эксперт может скорректировать)
    target_value        numeric(10,4) not null,
    actual_value        numeric(10,4),  -- null = ещё не измерен
    unit                text    not null,
    -- FSM (Dok 1 5.7)
    status              text    not null default 'pending'
                                    check (status in (
                                        'pending',    -- цель поставлена, цикл ещё идёт
                                        'achieved',   -- actual >= target * (1 - tolerance/100)
                                        'missed'      -- actual < target * (1 - tolerance/100)
                                    )),
    -- Кто и когда измерил
    measured_by         uuid    references public.users(id),   -- null = система
    measured_at         timestamptz,
    measurement_source  text    check (measurement_source in (
                                    'herd_group',   -- вычислено из HerdGroup данных
                                    'ai_extracted', -- AI извлёк из диалога
                                    'expert_manual',-- эксперт ввёл вручную
                                    'erp_sync'      -- синхронизировано из ERP
                                )),
    notes               text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.farm_kpis is
    'FSM: pending → achieved | missed. Вычисляется системой при наличии actual_value.
     Источники actual: HerdGroup.avg_weight_kg (weight_gain), AI диалог, эксперт, ERP.
     Event #25: ops.kpi.missed → Notification (expert) + план к пересмотру.
     Q67: Какой именно measurement_source для каждого kpi_type — Dok 6 scope.';

-- ============================================================
-- PART B: EDUCATION MODULE (8 tables)
-- D12: EDU.DC merges into AGOS. Единая авторизация (User).
-- D13: Course → Module → Lesson. 3-уровневая иерархия.
-- ============================================================

-- -------------------------------------------------------
-- courses
-- D16: Бесплатные курсы для любого зарегистрированного пользователя.
-- D12: Единая auth — User из 001_kernel.sql.
-- -------------------------------------------------------
create table if not exists public.courses (
    id                  uuid    primary key default gen_random_uuid(),
    code                text    not null unique,   -- 'BEEF_BASICS_KZ', 'TSP_INTRO'
    title_ru            text    not null,
    title_kz            text,
    description_ru      text,
    -- Категория курса
    category            text
                                    check (category in (
                                        'zootechnical', -- скотоводство, породы, кормление
                                        'veterinary',   -- болезни, профилактика
                                        'management',   -- TSP, рынок, субсидии
                                        'association',  -- ТУРАН, членство, стандарты
                                        'other'
                                    )),
    -- D16: доступность
    is_paid             boolean not null default false,
    price               numeric(10,2)
                                    check (price is null or price >= 0),
    currency            text    not null default 'KZT',
    -- Prerequisite (nullable = нет требований)
    prerequisite_course_id  uuid    references public.courses(id),
    -- Оценочное время прохождения
    estimated_hours     numeric(5,2),
    -- FSM (Dok 1 5.7)
    status              text    not null default 'draft'
                                    check (status in (
                                        'draft',        -- в разработке
                                        'coming_soon',  -- анонсирован, пре-регистрация открыта
                                        'published',    -- доступен для записи
                                        'archived'      -- снят с публикации
                                    )),
    published_at        timestamptz,
    -- D17: AI знает о курсах через KnowledgeChunk
    knowledge_chunk_id  uuid    references public.knowledge_chunks(id),
    -- SEO / preview
    cover_image_url     text,
    created_by          uuid    references public.users(id),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.courses is
    'D12: EDU.DC слит в AGOS. Та же auth (User), тот же Data Flywheel.
     D16: is_paid=false → доступен любому зарегистрированному User.
     D17: Триггер fn_course_create_knowledge_chunk при status→published.
          AI отвечает на вопросы "какие курсы есть?" через KnowledgeChunk RAG.
     FSM: coming_soon позволяет собирать пре-регистрации до публикации.
     Q11: EDU.DC migration plan — отдельная операция, не влияет на схему.';

-- -------------------------------------------------------
-- modules
-- D13: Course → Module → Lesson.
-- Средний уровень структуры курса.
-- -------------------------------------------------------
create table if not exists public.modules (
    id                  uuid    primary key default gen_random_uuid(),
    course_id           uuid    not null references public.courses(id) on delete cascade,
    title_ru            text    not null,
    description_ru      text,
    sort_order          int     not null default 0,
    -- Свободен для просмотра без записи (preview)
    is_preview          boolean not null default false,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.modules is
    'D13: Средний уровень. Группирует уроки по теме.
     is_preview=true: модуль виден без записи — маркетинговый preview.';

-- -------------------------------------------------------
-- lessons
-- D13: Базовая единица контента.
-- D15: Прогресс отслеживается на уровне урока (granular).
-- -------------------------------------------------------
create table if not exists public.lessons (
    id                  uuid    primary key default gen_random_uuid(),
    module_id           uuid    not null references public.modules(id) on delete cascade,
    title_ru            text    not null,
    lesson_type         text    not null default 'video'
                                    check (lesson_type in (
                                        'video',        -- видеоурок (Supabase Storage / CDN)
                                        'text',         -- текстовый материал (JSONB или markdown)
                                        'quiz',         -- тест с вопросами
                                        'document',     -- PDF или docx файл
                                        'webinar'       -- live-вебинар (ссылка Zoom/Teams)
                                    )),
    sort_order          int     not null default 0,
    -- Контент (зависит от lesson_type)
    content_url         text,                      -- video/document: Supabase Storage URL
    -- Q10: схема JSONB для текстового контента и квизов
    -- video: {duration_seconds, transcript_url}
    -- text: {body_markdown, reading_time_minutes}
    -- quiz: {questions: [{q, options, correct_idx, explanation}]}
    -- webinar: {scheduled_at, join_url, recording_url}
    content_data        jsonb,
    estimated_minutes   int,
    is_free_preview     boolean not null default false,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.lessons is
    'D15: Прогресс трекается на уровне урока (UserProgress.lesson_id).
     Q10: content_data JSONB схема по lesson_type — данные вносятся при создании контента.
     is_free_preview=true: урок доступен без записи (демо-урок).';

-- -------------------------------------------------------
-- course_enrollments
-- D16: Бесплатные курсы — любой User записывается сам.
-- D12: Платные — через Payment → PurchasedProduct → CourseEnrollment.
-- FSM: enrolled → in_progress → completed | expired
-- -------------------------------------------------------
create table if not exists public.course_enrollments (
    id                  uuid    primary key default gen_random_uuid(),
    user_id             uuid    not null references public.users(id),
    course_id           uuid    not null references public.courses(id),
    -- Как получил доступ
    access_type         text    not null default 'free'
                                    check (access_type in (
                                        'free',         -- D16: бесплатный курс
                                        'purchased',    -- оплатил (payment_id)
                                        'granted'       -- выдан администратором (бонус/промо)
                                    )),
    payment_id          uuid    references public.payments(id),  -- null для free/granted
    -- FSM (Dok 1 5.7)
    status              text    not null default 'enrolled'
                                    check (status in (
                                        'enrolled',     -- записан, не начал
                                        'in_progress',  -- хотя бы один урок начат
                                        'completed',    -- все обязательные уроки пройдены
                                        'expired'       -- платный доступ истёк
                                    )),
    -- Прогресс сводно
    progress_pct        numeric(5,2) not null default 0
                                    check (progress_pct between 0 and 100),
    -- Дата завершения (для completed)
    completed_at        timestamptz,
    -- Срок действия доступа (null = бессрочно)
    expires_at          timestamptz,
    unique (user_id, course_id),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.course_enrollments is
    'D16: Бесплатные курсы — любой зарегистрированный User (не обязательно член ассоциации).
     D12: Платные — Payment.type=course_payment связывает с enrollment.
     unique(user_id, course_id): пользователь записывается на курс один раз.
     progress_pct: денормализованный агрегат из UserProgress (обновляется триггером).
     Event #18: education.enrollment.completed → Certificate auto-issue.';

-- -------------------------------------------------------
-- user_progress
-- D15: Гранулярный трекинг на уровне урока.
-- Append-only: каждое посещение урока = одна запись.
-- -------------------------------------------------------
create table if not exists public.user_progress (
    id                  uuid    primary key default gen_random_uuid(),
    user_id             uuid    not null references public.users(id),
    lesson_id           uuid    not null references public.lessons(id),
    enrollment_id       uuid    not null references public.course_enrollments(id),
    -- Статус прохождения урока
    status              text    not null default 'started'
                                    check (status in (
                                        'started',      -- открыл урок
                                        'completed'     -- завершил (видео досмотрел, тест сдал)
                                    )),
    -- Для видео: досмотрел до какой секунды
    watch_progress_seconds  int,
    -- Для квиза: сколько правильных ответов из total
    quiz_score          numeric(5,2),   -- 0-100%
    quiz_attempts       int     not null default 0,
    completed_at        timestamptz,
    -- Последнее посещение (для resume from where left off)
    last_accessed_at    timestamptz not null default now(),
    unique (user_id, lesson_id),  -- один прогресс per user per lesson
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
comment on table public.user_progress is
    'D15: Гранулярный трекинг. Обновляется при каждом взаимодействии с уроком.
     Триггер fn_update_enrollment_progress: при UPDATE status=completed
       пересчитывает course_enrollments.progress_pct.
     quiz_score: для lesson_type=quiz. Порог сдачи — в course/lesson бизнес-логике (Dok 3).';

-- -------------------------------------------------------
-- certificates
-- Выдаётся автоматически при completed enrollment.
-- D12: Принадлежит User (не Organization) — знания личные.
-- -------------------------------------------------------
create table if not exists public.certificates (
    id                  uuid    primary key default gen_random_uuid(),
    user_id             uuid    not null references public.users(id),
    course_id           uuid    not null references public.courses(id),
    enrollment_id       uuid    not null references public.course_enrollments(id),
    -- Уникальный номер сертификата (для верификации)
    certificate_number  text    not null unique,   -- 'TURAN-2026-00001'
    -- Данные на момент выдачи (snapshot — курс может измениться)
    issued_at           timestamptz not null default now(),
    -- Срок действия (null = бессрочно; платные курсы могут иметь срок)
    valid_until         timestamptz,
    -- URL файла сертификата (PDF, генерируется системой)
    certificate_url     text,
    -- Статус (может быть отозван при обнаружении нарушений)
    is_valid            boolean not null default true,
    revoked_at          timestamptz,
    revoke_reason       text,
    created_at          timestamptz not null default now()
    -- APPEND-ONLY: нет updated_at (is_valid может меняться через отдельный RPC)
);
comment on table public.certificates is
    'D12: Знания принадлежат User (не Organization).
     Триггер fn_issue_certificate: при enrollment status→completed.
     certificate_number: генерируется как TURAN-{YYYY}-{sequence}.
     Публичная верификация: по certificate_number (без авторизации).
     is_valid=false: аннулирован администратором (крайний случай).
     APPEND-ONLY для основного контента. is_valid/revoked_at меняются только через RPC.';

-- -------------------------------------------------------
-- course_preregistrations
-- Для курсов со статусом coming_soon.
-- Фермер оставляет email/телефон — получает уведомление при публикации.
-- -------------------------------------------------------
create table if not exists public.course_preregistrations (
    id                  uuid    primary key default gen_random_uuid(),
    course_id           uuid    not null references public.courses(id),
    -- Пользователь может быть не зарегистрирован (только email)
    user_id             uuid    references public.users(id),  -- null = анонимный
    email               text,
    phone               text,
    -- Уведомлён ли при публикации
    notified_at         timestamptz,
    notes               text,
    check (user_id is not null or email is not null or phone is not null),
    unique (course_id, user_id),  -- один раз на курс per user
    created_at          timestamptz not null default now()
    -- APPEND-ONLY
);
comment on table public.course_preregistrations is
    'Пре-регистрация на курс (status=coming_soon).
     user_id nullable: анонимный пользователь оставляет email/phone.
     При course status→published: система рассылает уведомления всем pre-reg
     и ставит notified_at.';

-- -------------------------------------------------------
-- course_instructors
-- D14: Инструктор = ExpertProfile (не просто текстовое поле).
-- Junction: Course ↔ ExpertProfile (many-to-many).
-- -------------------------------------------------------
create table if not exists public.course_instructors (
    id                  uuid    primary key default gen_random_uuid(),
    course_id           uuid    not null references public.courses(id) on delete cascade,
    expert_profile_id   uuid    not null references public.expert_profiles(id),
    -- Роль в курсе
    role                text    not null default 'instructor'
                                    check (role in (
                                        'instructor',   -- ведёт занятия
                                        'reviewer',     -- рецензент контента
                                        'curator'       -- куратор курса
                                    )),
    sort_order          int     not null default 0,
    unique (course_id, expert_profile_id),
    created_at          timestamptz not null default now()
    -- APPEND-ONLY
);
comment on table public.course_instructors is
    'D14: Инструктор = ExpertProfile. Не текстовое поле — сущность.
     Связь с ExpertProfile позволяет: находить курсы по инструктору,
     показывать bio инструктора из ExpertProfile, связывать с ConsultationRequest.
     Junction: у курса несколько инструкторов, инструктор ведёт несколько курсов.
     APPEND-ONLY.';

-- ============================================================
-- SECTION 3: INDEXES
-- ============================================================

-- Operations: Reference tables
create index if not exists idx_pct_type           on public.production_cycle_templates (farm_type);
create index if not exists idx_pct_active         on public.production_cycle_templates (is_active) where is_active = true;
create index if not exists idx_pt_cycle           on public.phase_templates (cycle_template_id, sort_order);
create index if not exists idx_pt_sale_phase      on public.phase_templates (is_sale_phase) where is_sale_phase = true;
create index if not exists idx_tt_phase           on public.task_templates (phase_template_id, sort_order);
create index if not exists idx_tt_category        on public.task_templates (category);
create index if not exists idx_tt_herd_event      on public.task_templates (creates_herd_event) where creates_herd_event = true;
create index if not exists idx_sop_status         on public.sop_documents (status);
create index if not exists idx_sop_published      on public.sop_documents (status) where status = 'published';
create index if not exists idx_sop_knowledge      on public.sop_documents (knowledge_chunk_id) where knowledge_chunk_id is not null;
create index if not exists idx_tts_task           on public.task_template_sops (task_template_id);
create index if not exists idx_tts_sop            on public.task_template_sops (sop_document_id);
create index if not exists idx_kpit_phase         on public.kpi_templates (phase_template_id);
create index if not exists idx_kpit_type          on public.kpi_templates (kpi_type);

-- Operations: Operational tables
create index if not exists idx_fpp_org_status     on public.farm_production_plans (organization_id, status);
create index if not exists idx_fpp_farm           on public.farm_production_plans (farm_id);
create index if not exists idx_fpp_expert         on public.farm_production_plans (expert_profile_id) where expert_profile_id is not null;
create index if not exists idx_fpp_active         on public.farm_production_plans (farm_id, status) where status = 'active';

-- BUG FIX (deploy 2026-07-07): farm_phases.sort_order used by the index below but
-- never declared in the CREATE TABLE above — genuine gap in the canonical file,
-- not just live/file drift. Additive column (P7), safe default preserves insert order.
alter table public.farm_phases add column if not exists sort_order int not null default 0;
create index if not exists idx_fp_plan            on public.farm_phases (plan_id, sort_order);
create index if not exists idx_fp_org             on public.farm_phases (organization_id, status);
create index if not exists idx_fp_herd            on public.farm_phases (herd_group_id) where herd_group_id is not null;
create index if not exists idx_fp_dates           on public.farm_phases (start_date, end_date);  -- D75: date overlap queries
create index if not exists idx_fp_sale            on public.farm_phases (target_sale_month) where is_sale_phase = true;  -- D81
create index if not exists idx_fp_active          on public.farm_phases (status) where status = 'active';

create index if not exists idx_ft_phase           on public.farm_tasks (farm_phase_id);
create index if not exists idx_ft_org_status      on public.farm_tasks (organization_id, status);
create index if not exists idx_ft_due_date        on public.farm_tasks (due_date, status)
    where status in ('scheduled', 'reminded');  -- cron reminder queries
create index if not exists idx_ft_overdue         on public.farm_tasks (status) where status = 'overdue';
create index if not exists idx_ft_erp             on public.farm_tasks (erp_sync, erp_synced_at)
    where erp_sync = true;

create index if not exists idx_fk_phase           on public.farm_kpis (farm_phase_id);
create index if not exists idx_fk_org             on public.farm_kpis (organization_id);
create index if not exists idx_fk_missed          on public.farm_kpis (status) where status = 'missed';
create index if not exists idx_fk_template        on public.farm_kpis (kpi_template_id);

-- Education
create index if not exists idx_crs_status         on public.courses (status);
create index if not exists idx_crs_published      on public.courses (status) where status = 'published';
create index if not exists idx_crs_category       on public.courses (category);
create index if not exists idx_crs_paid           on public.courses (is_paid);
create index if not exists idx_crs_knowledge      on public.courses (knowledge_chunk_id) where knowledge_chunk_id is not null;

create index if not exists idx_mod_course         on public.modules (course_id, sort_order);
create index if not exists idx_les_module         on public.lessons (module_id, sort_order);
create index if not exists idx_les_type           on public.lessons (lesson_type);

create index if not exists idx_ce_user            on public.course_enrollments (user_id);
create index if not exists idx_ce_course          on public.course_enrollments (course_id);
create index if not exists idx_ce_status          on public.course_enrollments (status);
create index if not exists idx_ce_in_progress     on public.course_enrollments (user_id, status)
    where status = 'in_progress';
create index if not exists idx_ce_expiry          on public.course_enrollments (expires_at)
    where expires_at is not null;

create index if not exists idx_up_user            on public.user_progress (user_id);
create index if not exists idx_up_enrollment      on public.user_progress (enrollment_id);
create index if not exists idx_up_lesson          on public.user_progress (lesson_id);
create index if not exists idx_up_completed       on public.user_progress (enrollment_id, status)
    where status = 'completed';

create index if not exists idx_cert_user          on public.certificates (user_id);
create index if not exists idx_cert_course        on public.certificates (course_id);
create index if not exists idx_cert_number        on public.certificates (certificate_number);  -- public verification
create index if not exists idx_cert_valid         on public.certificates (is_valid) where is_valid = true;

create index if not exists idx_prereg_course      on public.course_preregistrations (course_id);
create index if not exists idx_prereg_unnotified  on public.course_preregistrations (course_id, notified_at)
    where notified_at is null;

create index if not exists idx_ci_course          on public.course_instructors (course_id, sort_order);
create index if not exists idx_ci_expert          on public.course_instructors (expert_profile_id);

-- ============================================================
-- SECTION 4: ROW LEVEL SECURITY
-- ============================================================

alter table public.production_cycle_templates  enable row level security;
alter table public.phase_templates             enable row level security;
alter table public.task_templates              enable row level security;
alter table public.sop_documents               enable row level security;
alter table public.task_template_sops          enable row level security;
alter table public.kpi_templates               enable row level security;
alter table public.farm_production_plans       enable row level security;
alter table public.farm_phases                 enable row level security;
alter table public.farm_tasks                  enable row level security;
alter table public.farm_kpis                   enable row level security;
alter table public.courses                     enable row level security;
alter table public.modules                     enable row level security;
alter table public.lessons                     enable row level security;
alter table public.course_enrollments          enable row level security;
alter table public.user_progress               enable row level security;
alter table public.certificates                enable row level security;
alter table public.course_preregistrations     enable row level security;
alter table public.course_instructors          enable row level security;

-- Operations: Reference tables (читают все, пишет только expert/admin)
drop policy if exists "pct_read_all" on public.production_cycle_templates;
create policy "pct_read_all"    on public.production_cycle_templates  for select using (auth.uid() is not null);
drop policy if exists "pct_expert_write" on public.production_cycle_templates;
create policy "pct_expert_write" on public.production_cycle_templates for all   using (public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "pt_read_all" on public.phase_templates;
create policy "pt_read_all"     on public.phase_templates             for select using (auth.uid() is not null);
drop policy if exists "pt_expert_write" on public.phase_templates;
create policy "pt_expert_write" on public.phase_templates             for all   using (public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "tt_read_all" on public.task_templates;
create policy "tt_read_all"     on public.task_templates              for select using (auth.uid() is not null);
drop policy if exists "tt_expert_write" on public.task_templates;
create policy "tt_expert_write" on public.task_templates              for all   using (public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "sop_read_published" on public.sop_documents;
create policy "sop_read_published" on public.sop_documents            for select using (status = 'published' or public.fn_is_expert() or public.fn_is_admin());
drop policy if exists "sop_expert_write" on public.sop_documents;
create policy "sop_expert_write"   on public.sop_documents            for all   using (public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "tts_read_all" on public.task_template_sops;
create policy "tts_read_all"    on public.task_template_sops          for select using (auth.uid() is not null);
drop policy if exists "tts_expert_write" on public.task_template_sops;
create policy "tts_expert_write" on public.task_template_sops         for all   using (public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "kpit_read_all" on public.kpi_templates;
create policy "kpit_read_all"   on public.kpi_templates               for select using (auth.uid() is not null);
drop policy if exists "kpit_expert_write" on public.kpi_templates;
create policy "kpit_expert_write" on public.kpi_templates             for all   using (public.fn_is_expert() or public.fn_is_admin());

-- Operations: Operational (фермер видит только своё)
drop policy if exists "fpp_read_own" on public.farm_production_plans;
create policy "fpp_read_own"    on public.farm_production_plans  for select using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());
drop policy if exists "fpp_write_own" on public.farm_production_plans;
create policy "fpp_write_own"   on public.farm_production_plans  for all    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "fp_read_own" on public.farm_phases;
create policy "fp_read_own"     on public.farm_phases            for select using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());
drop policy if exists "fp_write_own" on public.farm_phases;
create policy "fp_write_own"    on public.farm_phases            for all    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "ft_read_own" on public.farm_tasks;
create policy "ft_read_own"     on public.farm_tasks             for select using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());
drop policy if exists "ft_write_own" on public.farm_tasks;
create policy "ft_write_own"    on public.farm_tasks             for all    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());

drop policy if exists "fk_read_own" on public.farm_kpis;
create policy "fk_read_own"     on public.farm_kpis              for select using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());
drop policy if exists "fk_write_own" on public.farm_kpis;
create policy "fk_write_own"    on public.farm_kpis              for all    using (organization_id = any(public.fn_my_org_ids()) or public.fn_is_expert() or public.fn_is_admin());

-- Education: Курсы — читают все (D16). Контент защищён через enrollment.
drop policy if exists "crs_read_published" on public.courses;
create policy "crs_read_published" on public.courses          for select using (status = 'published' or status = 'coming_soon' or public.fn_is_admin());
drop policy if exists "crs_admin_write" on public.courses;
create policy "crs_admin_write"    on public.courses          for all    using (public.fn_is_admin());

drop policy if exists "mod_read_enrolled" on public.modules;
create policy "mod_read_enrolled"  on public.modules          for select
    using (
        course_id in (select course_id from public.course_enrollments where user_id = auth.uid())
        or is_preview = true
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
drop policy if exists "mod_admin_write" on public.modules;
create policy "mod_admin_write"    on public.modules          for all    using (public.fn_is_admin());

drop policy if exists "les_read_enrolled" on public.lessons;
create policy "les_read_enrolled"  on public.lessons          for select
    using (
        module_id in (
            select m.id from public.modules m
            join public.course_enrollments ce on ce.course_id = m.course_id
            where ce.user_id = auth.uid()
        )
        or is_free_preview = true
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
drop policy if exists "les_admin_write" on public.lessons;
create policy "les_admin_write"    on public.lessons          for all    using (public.fn_is_admin());

drop policy if exists "ce_read_own" on public.course_enrollments;
create policy "ce_read_own"        on public.course_enrollments for select using (user_id = auth.uid() or public.fn_is_admin());
drop policy if exists "ce_insert_own" on public.course_enrollments;
create policy "ce_insert_own"      on public.course_enrollments for insert with check (user_id = auth.uid() or public.fn_is_admin());
drop policy if exists "ce_update_system" on public.course_enrollments;
create policy "ce_update_system"   on public.course_enrollments for update using (public.fn_is_admin());  -- только system/admin обновляет статус

drop policy if exists "up_read_own" on public.user_progress;
create policy "up_read_own"        on public.user_progress    for select using (user_id = auth.uid() or public.fn_is_admin());
drop policy if exists "up_write_own" on public.user_progress;
create policy "up_write_own"       on public.user_progress    for all    using (user_id = auth.uid() or public.fn_is_admin());

drop policy if exists "cert_read_own" on public.certificates;
create policy "cert_read_own"      on public.certificates     for select using (user_id = auth.uid() or public.fn_is_admin());
drop policy if exists "cert_admin_write" on public.certificates;
create policy "cert_admin_write"   on public.certificates     for all    using (public.fn_is_admin());
-- Публичная верификация по certificate_number — реализуется через Edge Function (без RLS)

drop policy if exists "prereg_read_own" on public.course_preregistrations;
create policy "prereg_read_own"    on public.course_preregistrations for select using (user_id = auth.uid() or public.fn_is_admin());
drop policy if exists "prereg_insert" on public.course_preregistrations;
create policy "prereg_insert"      on public.course_preregistrations for insert with check (true);  -- любой
drop policy if exists "prereg_admin" on public.course_preregistrations;
create policy "prereg_admin"       on public.course_preregistrations for update using (public.fn_is_admin());

drop policy if exists "ci_read_all" on public.course_instructors;
create policy "ci_read_all"        on public.course_instructors for select using (auth.uid() is not null);
drop policy if exists "ci_admin_write" on public.course_instructors;
create policy "ci_admin_write"     on public.course_instructors for all    using (public.fn_is_admin());

-- ============================================================
-- SECTION 5: TRIGGERS
-- ============================================================

-- updated_at
drop trigger if exists trg_pct_upd on public.production_cycle_templates;
create trigger trg_pct_upd          before update on public.production_cycle_templates for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_pt_upd on public.phase_templates;
create trigger trg_pt_upd           before update on public.phase_templates            for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_tt_upd on public.task_templates;
create trigger trg_tt_upd           before update on public.task_templates             for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_sop_upd on public.sop_documents;
create trigger trg_sop_upd          before update on public.sop_documents              for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_kpit_upd on public.kpi_templates;
create trigger trg_kpit_upd         before update on public.kpi_templates              for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_fpp_upd on public.farm_production_plans;
create trigger trg_fpp_upd          before update on public.farm_production_plans      for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_fp_upd on public.farm_phases;
create trigger trg_fp_upd           before update on public.farm_phases                for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_ft_upd on public.farm_tasks;
create trigger trg_ft_upd           before update on public.farm_tasks                 for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_fk_upd on public.farm_kpis;
create trigger trg_fk_upd           before update on public.farm_kpis                  for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_crs_upd on public.courses;
create trigger trg_crs_upd          before update on public.courses                    for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_mod_upd on public.modules;
create trigger trg_mod_upd          before update on public.modules                    for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_les_upd on public.lessons;
create trigger trg_les_upd          before update on public.lessons                    for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_ce_upd on public.course_enrollments;
create trigger trg_ce_upd           before update on public.course_enrollments         for each row execute function public.fn_set_updated_at();
drop trigger if exists trg_up_upd on public.user_progress;
create trigger trg_up_upd           before update on public.user_progress              for each row execute function public.fn_set_updated_at();

-- -------------------------------------------------------
-- D86: SOPDocument published → auto-create KnowledgeChunk
-- -------------------------------------------------------
create or replace function public.fn_sop_create_knowledge_chunk()
returns trigger language plpgsql security definer as $$
declare
    v_chunk_id  uuid;
    v_content   text;
begin
    if new.status = 'published' and
       (tg_op = 'INSERT' or old.status != 'published') then

        v_content := format(
            'СОП: %s. Категория: %s. Версия: %s. %s',
            new.title_ru,
            new.category,
            new.version,
            coalesce(new.notes, '')
        );

        if new.knowledge_chunk_id is null then
            insert into public.knowledge_chunks (source_domain, title, content, metadata)
            values (
                'zootechnical',
                new.title_ru,
                v_content,
                jsonb_build_object(
                    'sop_id', new.id,
                    'sop_code', new.code,
                    'category', new.category,
                    'storage_url', new.storage_url
                )
            ) returning id into v_chunk_id;
            new.knowledge_chunk_id := v_chunk_id;
        else
            update public.knowledge_chunks
            set content = v_content,
                title = new.title_ru,
                metadata = jsonb_build_object(
                    'sop_id', new.id, 'sop_code', new.code,
                    'category', new.category, 'storage_url', new.storage_url
                )
            where id = new.knowledge_chunk_id;
        end if;
        new.published_at := now();
    end if;
    return new;
end;
$$;
comment on function public.fn_sop_create_knowledge_chunk() is
    'D86: SOP status→published → KnowledgeChunk (source_domain=zootechnical).
     AI находит SOPs через pgvector semantic search.
     Embedding вычисляется Edge Function (отдельным вызовом после INSERT).';

drop trigger if exists trg_sop_knowledge_chunk on public.sop_documents;
create trigger trg_sop_knowledge_chunk
    before insert or update on public.sop_documents
    for each row execute function public.fn_sop_create_knowledge_chunk();

-- -------------------------------------------------------
-- D17: Course published → auto-create KnowledgeChunk
-- -------------------------------------------------------
create or replace function public.fn_course_create_knowledge_chunk()
returns trigger language plpgsql security definer as $$
declare
    v_chunk_id  uuid;
    v_content   text;
begin
    if new.status = 'published' and
       (tg_op = 'INSERT' or old.status != 'published') then

        v_content := format(
            'Курс: %s. Категория: %s. %s Продолжительность: %s часов.',
            new.title_ru,
            coalesce(new.category, 'общий'),
            coalesce(new.description_ru, ''),
            coalesce(new.estimated_hours::text, '?')
        );

        if new.knowledge_chunk_id is null then
            insert into public.knowledge_chunks (source_domain, title, content, metadata)
            values (
                'education',
                new.title_ru,
                v_content,
                jsonb_build_object(
                    'course_id', new.id,
                    'course_code', new.code,
                    'is_paid', new.is_paid,
                    'category', new.category
                )
            ) returning id into v_chunk_id;
            new.knowledge_chunk_id := v_chunk_id;
        else
            update public.knowledge_chunks
            set content = v_content, title = new.title_ru
            where id = new.knowledge_chunk_id;
        end if;
        new.published_at := now();
    end if;
    return new;
end;
$$;
comment on function public.fn_course_create_knowledge_chunk() is
    'D17: Course status→published → KnowledgeChunk (source_domain=education).
     AI отвечает на "какие курсы есть по кормлению?" через pgvector RAG.';

drop trigger if exists trg_course_knowledge_chunk on public.courses;
create trigger trg_course_knowledge_chunk
    before insert or update on public.courses
    for each row execute function public.fn_course_create_knowledge_chunk();

-- -------------------------------------------------------
-- Education: UserProgress completed → update enrollment progress_pct
-- и auto-issue Certificate при 100%
-- -------------------------------------------------------
create or replace function public.fn_update_enrollment_progress()
returns trigger language plpgsql security definer as $$
declare
    v_total_lessons     int;
    v_completed_lessons int;
    v_new_progress      numeric(5,2);
    v_enrollment        record;
    v_cert_number       text;
begin
    -- Пересчёт прогресса enrollment
    select count(*) into v_total_lessons
    from public.lessons l
    join public.modules m on m.id = l.module_id
    join public.courses c on c.id = m.course_id
    join public.course_enrollments ce on ce.course_id = c.id
    where ce.id = new.enrollment_id;

    select count(*) into v_completed_lessons
    from public.user_progress
    where enrollment_id = new.enrollment_id and status = 'completed';

    if v_total_lessons > 0 then
        v_new_progress := round((v_completed_lessons::numeric / v_total_lessons) * 100, 2);
    else
        v_new_progress := 0;
    end if;

    -- Обновляем enrollment
    update public.course_enrollments
    set progress_pct = v_new_progress,
        status = case
            when v_new_progress >= 100 then 'completed'
            when v_new_progress > 0 then 'in_progress'
            else status
        end,
        completed_at = case when v_new_progress >= 100 then now() else completed_at end,
        updated_at = now()
    where id = new.enrollment_id
    returning * into v_enrollment;

    -- Auto-issue Certificate при 100% (D12)
    if v_enrollment.status = 'completed' then
        -- Проверяем нет ли уже сертификата
        if not exists (
            select 1 from public.certificates
            where enrollment_id = new.enrollment_id
        ) then
            -- Генерируем номер: TURAN-{YYYY}-{sequence}
            v_cert_number := 'TURAN-' || extract(year from now())::text || '-' ||
                             lpad(nextval('public.certificate_number_seq')::text, 5, '0');

            insert into public.certificates (
                user_id, course_id, enrollment_id, certificate_number, issued_at
            ) values (
                v_enrollment.user_id,
                v_enrollment.course_id,
                new.enrollment_id,
                v_cert_number,
                now()
            );

            -- Event #18: education.enrollment.completed
            insert into public.platform_events (
                event_type, entity_type, entity_id, actor_type, payload
            ) values (
                'education.enrollment.completed',
                'course_enrollment',
                new.enrollment_id,
                'system',
                jsonb_build_object(
                    'user_id', v_enrollment.user_id,
                    'course_id', v_enrollment.course_id,
                    'certificate_number', v_cert_number
                )
            );
        end if;
    end if;

    return new;
end;
$$;
comment on function public.fn_update_enrollment_progress() is
    'D15: При каждом UserProgress update → пересчёт course_enrollments.progress_pct.
     Auto-issue Certificate при 100% прогрессе (event #18 education.enrollment.completed).
     certificate_number_seq: sequence создаётся ниже.';

-- Sequence для номеров сертификатов
create sequence if not exists public.certificate_number_seq start with 1 increment by 1;

drop trigger if exists trg_user_progress_enrollment on public.user_progress;
create trigger trg_user_progress_enrollment
    after insert or update on public.user_progress
    for each row execute function public.fn_update_enrollment_progress();

-- -------------------------------------------------------
-- FarmTask completed → PlatformEvent (D80, Event #24)
-- Сам HerdEvent создаётся через RPC в Dok 3 (нужна бизнес-логика)
-- -------------------------------------------------------
create or replace function public.fn_farm_task_completed_event()
returns trigger language plpgsql security definer as $$
begin
    if new.status = 'completed' and
       (tg_op = 'INSERT' or old.status != 'completed') then
        insert into public.platform_events (
            event_type, entity_type, entity_id,
            organization_id, actor_type, payload
        ) values (
            'ops.task.completed',
            'farm_task',
            new.id,
            new.organization_id,
            'system',
            jsonb_build_object(
                'farm_phase_id', new.farm_phase_id,
                'category', new.category,
                'result_data', new.result_data,
                'erp_sync', new.erp_sync,
                'creates_herd_event',
                    coalesce(
                        (select creates_herd_event
                         from public.task_templates
                         where id = new.task_template_id),
                        false
                    )
            )
        );
    end if;
    return new;
end;
$$;
comment on function public.fn_farm_task_completed_event() is
    'D80: FarmTask status→completed → Event #24 ops.task.completed.
     AI Gateway / Dok 3 RPC обрабатывает событие:
       if creates_herd_event=true → вызывает fn_create_herd_event_from_task(task_id).
     Триггер публикует событие, RPC выполняет бизнес-логику (D87: FSM в RPC).';

drop trigger if exists trg_farm_task_completed on public.farm_tasks;
create trigger trg_farm_task_completed
    after insert or update on public.farm_tasks
    for each row execute function public.fn_farm_task_completed_event();

-- -------------------------------------------------------
-- FarmKPI auto-evaluate: при actual_value → статус achieved/missed
-- -------------------------------------------------------
create or replace function public.fn_evaluate_farm_kpi()
returns trigger language plpgsql security definer as $$
declare
    v_template  record;
    v_threshold numeric;
begin
    if new.actual_value is not null and
       (tg_op = 'INSERT' or old.actual_value is null or old.actual_value != new.actual_value) then

        select * into v_template
        from public.kpi_templates
        where id = new.kpi_template_id;

        v_threshold := new.target_value * (1 - v_template.tolerance_pct / 100.0);

        if v_template.higher_is_better then
            new.status := case when new.actual_value >= v_threshold then 'achieved' else 'missed' end;
        else
            -- Для mortality_rate: меньше = лучше
            -- threshold = target * (1 + tolerance/100)
            v_threshold := new.target_value * (1 + v_template.tolerance_pct / 100.0);
            new.status := case when new.actual_value <= v_threshold then 'achieved' else 'missed' end;
        end if;

        -- Event #25: ops.kpi.missed
        if new.status = 'missed' then
            insert into public.platform_events (
                event_type, entity_type, entity_id,
                organization_id, actor_type, payload
            ) values (
                'ops.kpi.missed',
                'farm_kpi',
                new.id,
                new.organization_id,
                'system',
                jsonb_build_object(
                    'kpi_template_id', new.kpi_template_id,
                    'target_value', new.target_value,
                    'actual_value', new.actual_value,
                    'unit', new.unit,
                    'farm_phase_id', new.farm_phase_id
                )
            );
        end if;
    end if;
    return new;
end;
$$;
comment on function public.fn_evaluate_farm_kpi() is
    'При actual_value → автоматически вычисляет status achieved/missed.
     higher_is_better=false (mortality_rate): tolerance работает в обратную сторону.
     Event #25: ops.kpi.missed → Notification эксперту + план к пересмотру.';

drop trigger if exists trg_farm_kpi_evaluate on public.farm_kpis;
create trigger trg_farm_kpi_evaluate
    before insert or update on public.farm_kpis
    for each row execute function public.fn_evaluate_farm_kpi();

-- ============================================================
-- SECTION 6: SEED DATA
-- ============================================================

-- Production cycle templates: минимальный набор типов (Q65: зоотехник наполняет)
insert into public.production_cycle_templates
    (code, name_ru, description_ru, farm_type, cycle_duration_days, is_active)
values
    ('BEEF_COW_CALF_KZ',
     'Мясное скотоводство: маточное стадо (КЗ)',
     'Цикл от отёла до отёла для мясного маточного стада. Адаптирован для условий Казахстана.',
     'cow_calf', 365, true),
    ('BEEF_FINISHING_KZ',
     'Мясное скотоводство: откорм бычков (КЗ)',
     'Цикл интенсивного откорма бычков 8-18 мес. до убойных кондиций.',
     'finishing', 180, true),
    ('BEEF_COMBINED_KZ',
     'Мясное скотоводство: маточное + откорм (КЗ)',
     'Комбинированное хозяйство: собственный отёл и доращивание молодняка.',
     'combined', 365, true)
on conflict (code) do nothing;

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Summary:
--   Part A: Operations
--     Reference (6): production_cycle_templates, phase_templates,
--                    task_templates, sop_documents,
--                    task_template_sops, kpi_templates
--     Operational (4): farm_production_plans, farm_phases,
--                      farm_tasks, farm_kpis
--
--   Part B: Education (8):
--     courses, modules, lessons,
--     course_enrollments, user_progress, certificates,
--     course_preregistrations, course_instructors
--
--   Total: 18 tables
--   Indexes: 57
--   RLS policies: 36
--   Triggers: 19 (14 updated_at + 5 business logic)
--   Functions: 5 business logic
--   Sequences: 1 (certificate_number_seq)
--   Partial unique index: 1 (one active plan per farm, D82)
--
-- Decisions implemented: D12–D17, D73–D83, D85–D86
-- Deferred to Dok 3 (RPC):
--   fn_create_herd_event_from_task() — D80, event #24
--   fn_generate_production_plan()   — D74, template → plan
--   fn_complete_farm_task()         — D80, business logic
--   fn_notify_prereg_on_publish()   — course coming_soon → published
--
-- Cross-domain links:
--   → 001_kernel.sql: organizations, farms, herd_groups, users,
--                     expert_profiles, knowledge_chunks, payments,
--                     platform_events, herd_events
--   → 002_tsp.sql: FarmPhase.target_sale_month → TSP (D81, via RPC)
--   → 003_feed.sql: FarmPhase ↔ FeedingPeriod (D75, by dates)
--   → 004_vet.sql: FarmPhase ↔ VaccinationPlanItem (D75, by dates)
--
-- This is the final migration. All 91 entities from Dok 1 v1.3 are now
-- implemented across 001–005 migrations.
--
-- Next: Dok 3 — RPC Catalog
-- ============================================================


-- === FROM 006: animal_category_codes, is_recurring (D101, D102) ===
-- ============================================================
-- AGOS Migration 006: OPERATIONS SCHEMA PATCH
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 5 March 2026
--
-- Purpose:
--   Structural patch for 005_ops_edu.sql.
--   Adds two fields required by fn_generate_production_plan() (Dok 3).
--
-- Decisions implemented:
--   D101  phase_templates.animal_category_codes text[]
--         Машиночитаемая привязка фазы к HerdGroup.
--         Заменяет слабую строковую подсказку applicable_category_hint.
--   D102  production_cycle_templates.is_recurring boolean
--         Разовые шаблоны (запуск фермы) vs циклические (ежегодные).
--
-- Context (P5 — Design for the Physical World):
--   Структура farm_type в production_cycle_templates ПРАВИЛЬНАЯ.
--   Cow_calf, finishing, breeding — принципиально разные производственные
--   циклы. ЦТК файл — это ЦТК только для cow_calf модели.
--   Этот патч не меняет farm_type логику. Он добавляет точность:
--   fn_generate_production_plan() теперь знает к какой HerdGroup
--   привязать каждую FarmPhase автоматически через animal_category_codes.
--
-- Depends on: 005_ops_edu.sql
-- Required by: 007_ctk_seed.sql
-- ============================================================

-- ============================================================
-- PATCH 1: production_cycle_templates — добавить is_recurring
-- D102: Подготовительный период до запуска фермы — разовый шаблон.
--       Все производственные циклы (cow_calf, finishing и т.д.) — цикличные.
-- ============================================================

alter table public.production_cycle_templates
    add column if not exists is_recurring boolean not null default true;

comment on column public.production_cycle_templates.is_recurring is
    'D102: true = ежегодный цикл (cow_calf, finishing, breeding и т.д.).
     false = разовый onboarding-шаблон (подготовительный период до запуска фермы).
     Expert Console показывает все шаблоны.
     UI фермера показывает только is_recurring=true при создании плана.';

-- Подготовительный период — разовый. Обновляем если уже засеян.
update public.production_cycle_templates
set is_recurring = false
where code = 'BEEF_FARM_LAUNCH_KZ';

-- ============================================================
-- PATCH 2: phase_templates — добавить animal_category_codes
-- D101: fn_generate_production_plan() (Dok 3 RPC) при создании FarmPhase
--   ищет HerdGroup фермы по совпадению с кодом категории:
--
--   SELECT hg.id FROM herd_groups hg
--   JOIN animal_categories ac ON ac.id = hg.animal_category_id
--   WHERE hg.farm_id = $farm_id
--     AND hg.is_active = true
--     AND ac.code = ANY($phase_template.animal_category_codes)
--   LIMIT 1
--
--   Если найдено → FarmPhase.herd_group_id заполняется автоматически.
--   Если не найдено → FarmPhase.herd_group_id = NULL (эксперт назначает вручную).
--   applicable_category_hint сохранён для обратной совместимости (UI).
-- ============================================================

alter table public.phase_templates
    add column if not exists animal_category_codes text[] not null default '{}';

comment on column public.phase_templates.animal_category_codes is
    'D101: Коды из animal_categories.code для автопривязки к HerdGroup.
     fn_generate_production_plan() (Dok 3): ищет HerdGroup фермы,
     у которой animal_categories.code = ANY(animal_category_codes).
     Пустой массив = эксперт назначает HerdGroup вручную.
     Примеры:
       Фаза «Отёл»:            [''COW'', ''HEIFER_PREG'']
       Фаза «Подсосный период»: [''COW'', ''SUCKLING_CALF'', ''YOUNG_CALF'']
       Фаза «Откорм бычков»:   [''BULL_CALF'', ''STEER'']
       Фаза «Быки на случку»:  [''BULL_BREEDING'']';

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Changes:
--   production_cycle_templates: +1 column (is_recurring)
--   phase_templates:            +1 column (animal_category_codes)
--
-- Zero breaking changes. Zero existing data affected.
-- P7 (Additive Architecture): новые колонки с DEFAULT, все
--   существующие строки получают безопасные значения.
--
-- Next migration: 007_ctk_seed.sql
--   Полный контент ЦТК cow_calf модели:
--   5 шаблонов цикла, 15 фаз, ~45 задач, ~30 KPI, ~25 SOP-документов
-- ============================================================


-- === FROM 007: CTK Seed Data — Cow-Calf Model ===
-- ============================================================
-- AGOS Migration 007: ЦТК SEED DATA — COW_CALF MODEL
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 5 March 2026
--
-- Purpose: Closes Q65 — full CTK content for cow_calf production model.
--          P8 (Standards as Data): все нормативы — строки в БД,
--          не константы в коде. Зоотехник редактирует через Expert Console.
--
-- Decisions implemented:
--   D100  ЦТК шаблоны — по типу хозяйства (farm_type).
--         Этот файл = cow_calf модель. Финишинг, бридинг — отдельные ЦТК.
--   D103  Весь контент ЦТК сидируется программно из исходного файла.
--   D101  animal_category_codes на каждой фазе (D101 patch из 006).
--   D102  BEEF_FARM_LAUNCH_KZ — is_recurring=false (разовый onboarding).
--
-- Source: ЦТК.xlsx (4 листа):
--   «маточное поголовье»      → BEEF_COW_CALF_KZ фазы для коров
--   «молодняк»                → BEEF_COW_CALF_KZ фазы для тёлок и бычков
--   «быки-производители»      → BEEF_COW_CALF_KZ фазы для быков
--   «подгот. период до запуска» → BEEF_FARM_LAUNCH_KZ (is_recurring=false)
--
-- Cow_calf цикл (D78): от отёла до следующего отёла ≈ 365 дней.
--   cycle_start_date = дата начала массовых отёлов (обычно декабрь-январь).
--   Все offset_from_cycle_start_days отсчитываются от этой даты.
--
-- Depends on: 005_ops_edu.sql, 006_patch_ops.sql
-- ============================================================

-- ============================================================
-- SECTION 1: PRODUCTION CYCLE TEMPLATES (5 шаблонов)
-- ============================================================
-- Существующие 3 шаблона обновляем (ON CONFLICT DO UPDATE).
-- Добавляем 2 новых: BEEF_BREEDING_BULLS_KZ + BEEF_FARM_LAUNCH_KZ.
-- farm_type='cow_calf' охватывает всю ферму целиком — коров, молодняк
-- и быков-производителей. Это один тип хозяйства, один FarmProductionPlan,
-- параллельные фазы для разных HerdGroup (D82, Q60-A).
-- ============================================================

insert into public.production_cycle_templates
    (code, name_ru, description_ru, farm_type, cycle_duration_days, is_recurring, sort_order)
values
    -- Основные типы хозяйств
    ('BEEF_COW_CALF_KZ',
     'Мясное скотоводство: маточное стадо (КЗ)',
     'Цикл от отёла до отёла для мясного маточного стада. '
     'Охватывает маточное поголовье, ремонтных тёлок, бычков и быков-производителей. '
     'Адаптирован для условий Казахстана. Источник: ЦТК ТУРАН v1.0.',
     'cow_calf', 365, true, 1),

    ('BEEF_FINISHING_KZ',
     'Мясное скотоводство: откорм бычков (КЗ)',
     'Цикл интенсивного откорма бычков 8–24 мес до убойных кондиций (400–550 кг). '
     'Покупка отъёмышей → адаптация → откорм → реализация.',
     'finishing', 180, true, 2),

    ('BEEF_COMBINED_KZ',
     'Мясное скотоводство: маточное + откорм (КЗ)',
     'Комбинированное хозяйство: собственный отёл, доращивание молодняка и финишинг.',
     'combined', 365, true, 3),

    -- Племенное хозяйство
    ('BEEF_BREEDING_KZ',
     'Мясное скотоводство: племенное хозяйство (КЗ)',
     'Цикл племенного репродуктора: производство и реализация племенного молодняка. '
     'Бонитировка, отбор, подбор пар — ключевые фазы.',
     'breeding', 365, true, 4),

    -- Разовый onboarding-шаблон (D102: is_recurring=false)
    ('BEEF_FARM_LAUNCH_KZ',
     'Запуск мясной фермы: подготовительный период (КЗ)',
     'Разовый чек-лист для запуска новой фермы с нуля: выбор участка, '
     'подготовка помещений, закуп кормов, подбор персонала, приобретение животных, карантин. '
     'Применяется один раз. Источник: ЦТК ТУРАН v1.0.',
     'cow_calf', 240, false, 10)

on conflict (code) do update set
    name_ru             = excluded.name_ru,
    description_ru      = excluded.description_ru,
    cycle_duration_days = excluded.cycle_duration_days,
    is_recurring        = excluded.is_recurring,
    sort_order          = excluded.sort_order;

-- ============================================================
-- SECTION 2: SOP DOCUMENTS
-- D76: SOP = файлы в Supabase Storage. storage_url заполняется
--      после загрузки файлов. Записи создаём сейчас как placeholder.
-- D86: При status→published триггер создаёт KnowledgeChunk.
-- ============================================================

-- BUG FIX (deploy 2026-07-07): domain/source/sort_order used by the seed insert
-- below but never declared in the CREATE TABLE above — genuine gap in the
-- canonical file. Additive columns (P7); domain has no CHECK yet — only 'farm'
-- observed so far, not enough vocabulary to constrain (P8: standards as data).
alter table public.sop_documents add column if not exists domain     text;
alter table public.sop_documents add column if not exists source     text;
alter table public.sop_documents add column if not exists sort_order int not null default 0;

insert into public.sop_documents
    (code, title_ru, category, domain, status, source, sort_order)
values
    -- Зоотехнические СОПы
    ('SOP_CALVING_ORG',         'Организация отёла',                                  'zootechnical', 'farm', 'draft', 'TURAN', 1),
    ('SOP_CALF_ID',             'Идентификация и биркование телят (МСХ РК)',           'zootechnical', 'farm', 'draft', 'MSH_RK', 2),
    ('SOP_CALF_REARING',        'Выращивание телят на подсосе',                       'zootechnical', 'farm', 'draft', 'TURAN', 3),
    ('SOP_WEANING',             'Отъём телят и формирование групп молодняка',         'zootechnical', 'farm', 'draft', 'TURAN', 4),
    ('SOP_GRADING',             'Бонитировка мясных пород КРС (МСХ РК)',              'zootechnical', 'farm', 'draft', 'MSH_RK', 5),
    ('SOP_CULLING',             'Выбраковка и постановка на откорм',                  'zootechnical', 'farm', 'draft', 'TURAN', 6),
    ('SOP_WINTER_PREP',         'Подготовка к зимне-стойловому содержанию',           'zootechnical', 'farm', 'draft', 'TURAN', 7),
    ('SOP_WINTER_HOUSING',      'Содержание животных в зимний период',                'zootechnical', 'farm', 'draft', 'TURAN', 8),
    ('SOP_BREEDING_PREP',       'Подготовка к случной кампании',                      'zootechnical', 'farm', 'draft', 'TURAN', 9),
    ('SOP_BREEDING_CAMPAIGN',   'Организация случной кампании',                       'zootechnical', 'farm', 'draft', 'TURAN', 10),
    ('SOP_AI',                  'Искусственное осеменение КРС',                       'zootechnical', 'farm', 'draft', 'TURAN', 11),
    ('SOP_PREGNANCY_DIAG',      'Диагностика стельности КРС',                        'zootechnical', 'farm', 'draft', 'TURAN', 12),
    ('SOP_PASTURE_MGMT',        'Пастбищное содержание: ротационный выпас',           'zootechnical', 'farm', 'draft', 'TURAN', 13),
    ('SOP_BULL_MANAGEMENT',     'Содержание и эксплуатация быков-производителей',     'zootechnical', 'farm', 'draft', 'TURAN', 14),
    ('SOP_DRY_PERIOD',          'Перевод коров в сухостой и подготовка к отёлу',      'zootechnical', 'farm', 'draft', 'TURAN', 15),
    -- Управленческие СОПы
    ('SOP_HERD_MOVEMENT',       'Отчёт о движении скота',                             'management',   'farm', 'draft', 'TURAN', 20),
    ('SOP_SALE_CONTRACT',       'Договор купли-продажи скота',                        'management',   'farm', 'draft', 'TURAN', 21),
    ('SOP_FEED_PLAN',           'Расчёт потребности и баланс кормов',                 'management',   'farm', 'draft', 'TURAN', 22),
    -- Ветеринарные СОПы (placeholder — детализирует ветврач)
    ('SOP_VET_PLAN',            'Ветеринарный план мероприятий (шаблон)',              'veterinary',   'farm', 'draft', 'TURAN', 30),
    ('SOP_VET_CALVING',         'Ветеринарные мероприятия при отёле',                 'veterinary',   'farm', 'draft', 'TURAN', 31),
    ('SOP_VET_SPRING',          'Весенняя обработка скота (противопаразитарная)',      'veterinary',   'farm', 'draft', 'TURAN', 32),
    ('SOP_VET_AUTUMN',          'Осенняя обработка перед стойловым периодом',         'veterinary',   'farm', 'draft', 'TURAN', 33),
    -- Onboarding СОПы
    ('SOP_FACILITY_AUDIT',      'Инвентаризация и аудит помещений',                   'zootechnical', 'farm', 'draft', 'TURAN', 40),
    ('SOP_ANIMAL_SELECTION',    'Отбор и закупка ремонтных телят',                    'zootechnical', 'farm', 'draft', 'TURAN', 41),
    ('SOP_QUARANTINE',          'Карантин: ветеринарные обработки при поступлении',   'veterinary',   'farm', 'draft', 'TURAN', 42)

on conflict (code) do nothing;

-- ============================================================
-- SECTION 3: PHASE TEMPLATES — BEEF_COW_CALF_KZ
-- 15 фаз полного цикла маточной фермы.
-- offset_from_cycle_start_days: 0 = день начала массовых отёлов.
-- Источник: листы «маточное поголовье», «молодняк», «быки-производители».
-- ============================================================

-- Временная переменная для FK
do $$
declare
    v_cow_calf_id   uuid;
    v_launch_id     uuid;

    -- Phase IDs
    v_calving       uuid;
    v_suckling      uuid;
    v_winter_end    uuid;
    v_pasture_prep  uuid;
    v_pasture       uuid;
    v_weaning       uuid;
    v_grading       uuid;
    v_culling       uuid;
    v_sale          uuid;
    v_winter_prep   uuid;
    v_winter_stall  uuid;
    v_breed_prep    uuid;
    v_bull_select   uuid;
    v_breeding      uuid;
    v_preg_check    uuid;
    v_dry_period    uuid;

    -- Launch phase IDs
    v_site          uuid;
    v_facility_aud  uuid;
    v_facility_prep uuid;
    v_feed_calc     uuid;
    v_feed_proc     uuid;
    v_staff         uuid;
    v_animal_proc   uuid;
    v_quarantine    uuid;
    v_farm_start    uuid;

begin

select id into v_cow_calf_id from public.production_cycle_templates where code = 'BEEF_COW_CALF_KZ';
select id into v_launch_id   from public.production_cycle_templates where code = 'BEEF_FARM_LAUNCH_KZ';

-- ============================================================
-- ФАЗЫ: BEEF_COW_CALF_KZ
-- Цикл начинается с отёла (декабрь-январь).
-- ============================================================

-- ФАЗА 1: ОТЁЛ (0–70 дней)
-- Маточное поголовье: декабрь-январь, 60-70 дней
-- Животные: COW, HEIFER_PREG
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'CALVING', 'Туровые отёлы', 
     'Массовые отёлы коров и нетелей. Организация круглосуточного дежурства, '
     'оказание помощи при отёлах, биркование телят, внесение в ИСЖ.',
     1, 0, 65,
     array['COW', 'HEIFER_PREG'], false, 'calving')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_calving;

-- ФАЗА 2: ПОДСОСНЫЙ ПЕРИОД (0–240 дней)
-- Декабрь-июль, 180-240 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'SUCKLING', 'Подсосный период',
     'Выращивание телят на подсосе. Приучение к грубым кормам с 15-20 дней. '
     'Контроль состояния коров и молодняка. Формирование плана реализации.',
     2, 7, 210,
     array['COW', 'SUCKLING_CALF', 'YOUNG_CALF'], false, 'suckling')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_suckling;

-- ФАЗА 3: ПЕРЕВОД НА ПАСТБИЩЕ (120–150 дней от старта)
-- Апрель-май, 30 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'PASTURE_PREP', 'Подготовка к пастбищному периоду',
     'Ремонт ограждений, анализ продуктивности пастбищ, уничтожение ядовитых трав, '
     'подготовка водопоя. Ветеринарная обработка перед выгоном.',
     3, 120, 30,
     array['COW', 'HEIFER_PREG', 'HEIFER_YOUNG', 'BULL_BREEDING', 'YOUNG_CALF'], false, 'pasture')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_pasture_prep;

-- ФАЗА 4: ЛЕТНИЙ ПАСТБИЩНЫЙ ПЕРИОД (150–330 дней)
-- Май-октябрь, 180 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'SUMMER_PASTURE', 'Летний пастбищный период',
     'Выпас. Контроль состояния пастбищ и водопоя. '
     'Наблюдение за нагулом. Заготовка сена и сенажа. '
     'Обеспечение средней и выше средней упитанности.',
     4, 150, 180,
     array['COW', 'HEIFER_PREG', 'HEIFER_YOUNG', 'BULL_BREEDING',
           'YOUNG_CALF', 'BULL_CALF', 'STEER'], false, 'pasture')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_pasture;

-- ФАЗА 5: ОТЪЁМ ТЕЛЯТ (240–285 дней)
-- Август, 40-45 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'WEANING', 'Отъём телят',
     'Отъём телят от матерей в 7-8 мес. Формирование групп тёлок и бычков '
     'по живой массе и назначению. Обеспечение полноценного кормления '
     'в послеотъёмный период (40-45 дней) во избежание задержки роста.',
     5, 240, 45,
     array['COW', 'YOUNG_CALF', 'BULL_CALF', 'HEIFER_YOUNG'], false, 'weaning')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_weaning;

-- ФАЗА 6: БОНИТИРОВКА (270–330 дней)
-- Сентябрь-октябрь, 30-60 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'GRADING', 'Бонитировка поголовья',
     'Бонитировка коров, тёлок и бычков по инструкции МСХ. '
     'Взвешивание. Оценка продуктивности и определение назначения животных: '
     'ремонт стада, племпродажа, откорм/выбраковка.',
     6, 270, 45,
     array['COW', 'HEIFER_YOUNG', 'BULL_CALF', 'BULL_BREEDING'], false, null)
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_grading;

-- ФАЗА 7: ВЫБРАКОВКА И ОТКОРМ (300–330 дней)
-- Октябрь, 30 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'CULLING', 'Выбраковка и постановка на откорм',
     'Постановка выбракованных коров, нетелей и бычков на откорм. '
     'Формирование плана откорма. Контроль достижения плановой упитанности.',
     7, 300, 30,
     array['COW_CULL', 'BULL_CULL', 'HEIFER_YOUNG'], false, null)
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_culling;

-- ФАЗА 8: РЕАЛИЗАЦИЯ (315–345 дней) — SALE PHASE
-- Октябрь-ноябрь, 30 дней
-- D81: is_sale_phase=true → AI и TSP агрегируют предложение по target_sale_month
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'SALE', 'Реализация животных',
     'Реализация выбракованного поголовья, достигшего плановой упитанности, '
     'и племенного молодняка. Оформление договоров. Отчёт о движении скота.',
     8, 315, 30,
     array['COW_CULL', 'BULL_CULL', 'HEIFER_YOUNG', 'BULL_CALF', 'STEER'], true, null)
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_sale;

-- ФАЗА 9: ПОДГОТОВКА К ЗИМОВКЕ (270–365 дней)
-- Июнь-октябрь, 120-150 дней (параллельно с пастбищем и бонитировкой)
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'WINTER_PREP', 'Подготовка к зимне-стойловому периоду',
     'Заготовка качественных кормов, расчёт потребности. '
     'Ремонт помещений, выгульных дворов, кормушек, поилок, курганов. '
     'Формирование животноводческих бригад. Закупка добавок на зимний период.',
     9, 270, 90,
     array['COW', 'HEIFER_PREG', 'HEIFER_YOUNG', 'BULL_CALF', 'BULL_BREEDING'], false, 'stall')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_winter_prep;

-- ФАЗА 10: ЗИМНИЙ СТОЙЛОВЫЙ ПЕРИОД (330–540 дней / переходит в новый цикл)
-- Ноябрь-апрель, 180-210 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'WINTER_STALL', 'Зимний стойловый период',
     'Стойловое содержание. Составление и контроль рационов для разных групп. '
     'Организация бесперебойного поения. Контроль микроклимата (без сырости и сквозняков). '
     'Ежедневный мониторинг состояния животных.',
     10, 330, 180,
     array['COW', 'HEIFER_PREG', 'HEIFER_YOUNG', 'BULL_CALF',
           'BULL_BREEDING', 'SUCKLING_CALF'], false, 'stall')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_winter_stall;

-- ФАЗА 11: ПОДГОТОВКА К СЛУЧНОЙ КАМПАНИИ (390–420 дней)
-- Февраль, 30 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'BREEDING_PREP', 'Подготовка к случной кампании',
     'Формирование групп тёлок случного возраста (70% от живой массы взрослой коровы). '
     'Стимулирующее кормление за 2-3 недели до случки. '
     'Наблюдение за половой активностью. Усиленное кормление быков.',
     11, 390, 30,
     array['COW', 'HEIFER_YOUNG'], false, null)
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_breed_prep;

-- ФАЗА 12: ПОДБОР БЫКОВ-ПРОИЗВОДИТЕЛЕЙ (390–420 дней)
-- Февраль-март, 30 дней (параллельно с подготовкой маточного стада)
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'BULL_SELECTION', 'Подбор быков-производителей',
     'Клиническая оценка быков: состояние половых органов, контроль качества спермы. '
     'Проверка на отсутствие репродуктивных инфекций. '
     'Составление плана подбора производителей и графика работы.',
     12, 390, 30,
     array['BULL_BREEDING'], false, null)
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_bull_select;

-- ФАЗА 13: СЛУЧНАЯ КАМПАНИЯ (420–490 дней)
-- Март-апрель, 60-70 дней
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'BREEDING', 'Случная кампания',
     'Вольная случка или искусственное осеменение тёлок и коров. '
     'Ежедневная фиксация признаков охоты. Подкорм быков концентратами. '
     'Ведение журнала осеменения и календаря отёлов.',
     13, 420, 65,
     array['COW', 'HEIFER_YOUNG', 'BULL_BREEDING'], false, null)
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_breeding;

-- ФАЗА 14: ДИАГНОСТИКА СТЕЛЬНОСТИ (480–510 дней)
-- Через 45-60 дней после последней случки
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'PREGNANCY_CHECK', 'Диагностика стельности',
     'Ректальное исследование или УЗИ для подтверждения стельности. '
     'Стимулирование охоты у яловых животных простагландинами. '
     'Выбраковка яловых и бесплодных животных.',
     14, 485, 30,
     array['COW', 'HEIFER_YOUNG'], false, null)
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_preg_check;

-- ФАЗА 15: СУХОСТОЙ И ПОДГОТОВКА К ОТЁЛУ (630–695 дней)
-- Октябрь-ноябрь, за 60-70 дней до отёлов
insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase, suggested_period_type_code)
values
    (v_cow_calf_id, 'DRY_PERIOD', 'Сухостой и подготовка к отёлу',
     'Перевод коров и нетелей в сухостой за 60-70 дней до родов. '
     'Оборудование денников и станков за 2 недели до отёлов. '
     'Обеспечение достаточного уровня энергии и минеральных веществ. '
     'Выбраковка яловых и бесплодных коров.',
     15, 630, 65,
     array['COW', 'HEIFER_PREG'], false, 'stall')
on conflict (cycle_template_id, code) do update set name_ru = excluded.name_ru
returning id into v_dry_period;

-- ============================================================
-- SECTION 4: TASK TEMPLATES — BEEF_COW_CALF_KZ
-- Источник: ЦТК.xlsx, строки «Зоотехнические работы».
-- Ветеринарные задачи помечены category='veterinary' и координируются
-- с VaccinationPlan через даты (D75 — не FK, а пересечение дат).
-- ============================================================

-- ── ОТЁЛ ────────────────────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_calving, 'CALVING_SETUP',
     'Подготовка денников и родильного отделения',
     'Оборудование денников и станков за 2 недели до массовых отёлов. '
     'Дезинфекция помещений. Подготовка инструментов и медикаментов.',
     'zootechnical', -14, false, false, null,
     'Денники подготовлены к отёлам?',
     '[{"field": "ready", "type": "boolean"}]', 1),

    (v_calving, 'CALVING_MONITOR',
     'Круглосуточное дежурство и помощь при отёлах',
     'Организация круглосуточного дежурства. Оказание акушерской помощи '
     'первотёлкам и коровам. Наблюдение за новотельными коровами и телятами.',
     'zootechnical', 0, false, true, 'birth',
     'Сколько телят родилось за последние сутки?',
     '[{"field": "births_count", "unit": "heads", "entity": "herd_event"}]', 2),

    (v_calving, 'CALF_TAGGING',
     'Биркование и регистрация телят в ИСЖ',
     'Присвоение индивидуального номера. Биркование по истечении 7 дней. '
     'Внесение данных в ИСЖ и/или ИАС. Оформление племенных свидетельств.',
     'management', 7, true, false, null,
     'Сколько телят забирковали? Все внесены в ИСЖ?',
     '[{"field": "tagged_count", "unit": "heads"}]', 3),

    (v_calving, 'CALVING_VET',
     'Ветеринарные мероприятия в период отёлов',
     'Ветеринарный контроль отёлов. Профилактика задержания последа '
     'и послеродового пареза. Обработка пуповины. Контроль состояния '
     'здоровья новотельных коров.',
     'veterinary', 0, false, false, null,
     'Есть больные или ослабленные телята после отёла?',
     '[{"field": "sick_calves", "unit": "heads"}]', 4),

    (v_calving, 'INVENTORY',
     'Инвентаризация поголовья',
     'Проведение инвентаризации скота. Нумерация и запись телят '
     'в журналы. Сверка с данными ИСЖ.',
     'management', 7, true, true, 'head_count_change',
     'Сколько голов всего сейчас на ферме? Коровы, телята.',
     '[{"field": "head_count", "unit": "heads", "entity": "herd_group"}]', 5)
on conflict (phase_template_id, code) do nothing;

-- ── ПОДСОСНЫЙ ПЕРИОД ─────────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_suckling, 'CALF_FEEDING_SOLID',
     'Приучение телят к грубым кормам и концентратам',
     'Начало приучения с 15-20 дней. Устройство специальных загонов '
     'для подкормки подсосных телят с навесами и кормушками.',
     'zootechnical', 15, false, false, null,
     'Телята начали есть сено и концентраты?',
     '[{"field": "done", "type": "boolean"}]', 1),

    (v_suckling, 'CALF_PASTURE_SETUP',
     'Устройство загонов для подкормки телят на пастбище',
     'С 4-5 мес организация загонов для подкормки подсосных телят '
     'на пастбище. Контроль состояния молодняка в первые дни выпаса.',
     'zootechnical', 120, false, false, null,
     'Загоны для телят на пастбище готовы?',
     '[{"field": "done", "type": "boolean"}]', 2),

    (v_suckling, 'SUCKLING_WEIGH',
     'Ежеквартальное взвешивание молодняка',
     'Контрольное взвешивание телят каждые 3 месяца. '
     'Оценка среднесуточных приростов.',
     'zootechnical', 90, false, true, 'weight_update',
     'Взвесили телят? Какой средний вес?',
     '[{"field": "avg_weight_kg", "unit": "kg", "entity": "herd_group"}]', 3),

    (v_suckling, 'SALE_PLAN',
     'Составление плана реализации телят',
     'Формирование плана реализации и послеотъёмного выращивания телят '
     'с учётом живой массы и назначения (ремонт, откорм, продажа).',
     'management', 150, false, false, null,
     'План продажи телят составлен?',
     '[{"field": "done", "type": "boolean"}]', 4)
on conflict (phase_template_id, code) do nothing;

-- ── ОТЪЁМ ────────────────────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_weaning, 'WEANING_SEPARATION',
     'Отъём телят и формирование групп',
     'Отъём телят от матерей. Формирование отдельных групп тёлок и бычков '
     'по живой массе и назначению: ремонт стада, племпродажа, откорм.',
     'zootechnical', 0, true, true, 'weaning',
     'Сколько телят отняли? Тёлок и бычков отдельно.',
     '[{"field": "weaned_heifers", "unit": "heads"}, {"field": "weaned_bulls", "unit": "heads"}]', 1),

    (v_weaning, 'WEANING_WEIGH',
     'Взвешивание при отъёме',
     'Контрольное взвешивание в момент отъёма. '
     'Живая масса тёлок ≥ 155-165 кг, бычков ≥ 170-180 кг в 7-8 мес.',
     'zootechnical', 0, false, true, 'weight_update',
     'Какой средний вес тёлок и бычков при отъёме?',
     '[{"field": "avg_weight_heifers_kg", "unit": "kg"}, {"field": "avg_weight_bulls_kg", "unit": "kg"}]', 2),

    (v_weaning, 'WEANING_NUTRITION',
     'Контроль питания в послеотъёмный период',
     'Обеспечение полноценного кормления и содержания 40-45 дней '
     'после отъёма, чтобы телята не отстали в росте.',
     'zootechnical', 0, false, false, null,
     'Телята нормально едят после отъёма? Есть отставшие в росте?',
     '[{"field": "underweight_count", "unit": "heads"}]', 3)
on conflict (phase_template_id, code) do nothing;

-- ── БОНИТИРОВКА ─────────────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_grading, 'GRADING_PREP',
     'Подготовка к бонитировке',
     'Подготовка весов, расколов, первичной документации. '
     'Бонитировочные ведомости по форме МСХ РК.',
     'zootechnical', 0, false, false, null,
     'Оборудование и документация для бонитировки готовы?',
     '[{"field": "done", "type": "boolean"}]', 1),

    (v_grading, 'GRADING_EXEC',
     'Проведение бонитировки',
     'Бонитировка коров, тёлок и быков по инструкции МСХ. '
     'Оценка продуктивности, определение назначения животных. '
     'Обработка данных перед постановкой на стойловое содержание.',
     'zootechnical', 7, true, false, null,
     'Бонитировка проведена? Сколько животных 1 класса и выше?',
     '[{"field": "class1_count", "unit": "heads"}, {"field": "total_graded", "unit": "heads"}]', 2)
on conflict (phase_template_id, code) do nothing;

-- ── ВЫБРАКОВКА ───────────────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_culling, 'CULLING_PLAN',
     'Составление плана откорма выбракованного скота',
     'Отбор животных на выбраковку по результатам бонитировки. '
     'Постановка выбракованных коров, тёлок и бычков на откорм. '
     'Расчёт сроков достижения плановой упитанности.',
     'zootechnical', 0, false, false, null,
     'Сколько голов поставили на откорм после выбраковки?',
     '[{"field": "culled_count", "unit": "heads"}]', 1),

    (v_culling, 'CULLING_FATTING_MONITOR',
     'Контроль откорма выбракованного поголовья',
     'Взвешивание и контроль привесов откармливаемых животных. '
     'Кормление по рациону откорма до достижения плановой упитанности.',
     'zootechnical', 15, false, true, 'weight_update',
     'Какой вес выбракованных коров на откорме?',
     '[{"field": "avg_weight_kg", "unit": "kg", "entity": "herd_group"}]', 2)
on conflict (phase_template_id, code) do nothing;

-- ── РЕАЛИЗАЦИЯ ───────────────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_sale, 'SALE_BATCH',
     'Формирование партии и реализация через TSP',
     'Реализация выбракованных животных, достигших плановой упитанности, '
     'и племенного молодняка. Оформление договоров купли-продажи '
     'и отчёта о движении скота.',
     'management', 0, false, true, 'sale',
     'Сколько голов продали и по какой цене за кг?',
     '[{"field": "sold_count", "unit": "heads"}, {"field": "price_per_kg", "unit": "KZT"}]', 1)
on conflict (phase_template_id, code) do nothing;

-- ── ПОДГОТОВКА К ЗИМОВКЕ ─────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_winter_prep, 'FEED_HARVEST',
     'Заготовка кормов на зимний период',
     'Заготовка сена, сенажа, силоса. Расчёт потребности в кормах '
     'по гуртам и фермам. Контроль качества: протокол анализа с лаборатории.',
     'zootechnical', 0, false, false, null,
     'Сколько тонн сена и сенажа заготовлено? Хватит до следующего пастбищного периода?',
     '[{"field": "hay_tons", "unit": "tons"}, {"field": "haylage_tons", "unit": "tons"}]', 1),

    (v_winter_prep, 'FACILITY_WINTERIZE',
     'Подготовка помещений к зиме',
     'Ремонт коровников, выгульных дворов, кормушек, поилок, курганов. '
     'Дезинфекция. Контроль соответствия нормативным требованиям.',
     'zootechnical', 30, false, false, null,
     'Помещения готовы к зиме? Всё починено?',
     '[{"field": "ready", "type": "boolean"}]', 2),

    (v_winter_prep, 'STAFF_WINTER',
     'Формирование животноводческих бригад',
     'Комплектация штата к зимнему периоду. Закупка кормовых белков '
     'и соле-минеральных добавок на стойловый период.',
     'management', 45, false, false, null,
     'Бригады укомплектованы? Добавки закуплены?',
     '[{"field": "staff_ready", "type": "boolean"}]', 3)
on conflict (phase_template_id, code) do nothing;

-- ── ЗИМНИЙ СТОЙЛОВЫЙ ПЕРИОД ──────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_winter_stall, 'RATION_CONTROL',
     'Контроль рационов и поения',
     'Составление и контроль рационов для разных половозрастных групп. '
     'Организация бесперебойного доступа к воде. '
     'Соблюдение условий содержания: отсутствие сырости и сквозняков.',
     'zootechnical', 0, false, false, null,
     'Как едят животные? Есть проблемы с кормлением или поением?',
     '[{"field": "issues_noted", "type": "boolean"}]', 1),

    (v_winter_stall, 'WINTER_WEIGH',
     'Ежеквартальное взвешивание в стойловый период',
     'Взвешивание молодняка каждые 3 месяца для контроля '
     'живой массы и среднесуточных приростов.',
     'zootechnical', 90, false, true, 'weight_update',
     'Взвесили животных? Какой средний вес по группам?',
     '[{"field": "avg_weight_kg", "unit": "kg", "entity": "herd_group"}]', 2),

    (v_winter_stall, 'VET_WINTER',
     'Ежедневный ветеринарный мониторинг',
     'Наблюдение за аппетитом, хромотой, выделениями. '
     'Контроль микроклимата. Профилактика респираторных заболеваний '
     'и маститов. Обработка по плану ветеринарных мероприятий.',
     'veterinary', 0, false, false, null,
     'Есть больные животные? Симптомы?',
     '[{"field": "sick_count", "unit": "heads"}, {"field": "symptoms", "type": "text"}]', 3)
on conflict (phase_template_id, code) do nothing;

-- ── ПОДГОТОВКА К СЛУЧНОЙ КАМПАНИИ ────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_breed_prep, 'GROUP_BREEDING_FORM',
     'Формирование групп тёлок случного возраста',
     'Отбор тёлок, достигших 70% живой массы взрослой коровы. '
     'Возраст первой случки — не позднее 18 мес. '
     'Формирование плана случки / осеменения.',
     'zootechnical', 0, false, false, null,
     'Сколько тёлок готовы к случке? Средний вес?',
     '[{"field": "ready_count", "unit": "heads"}, {"field": "avg_weight_kg", "unit": "kg"}]', 1),

    (v_breed_prep, 'FLUSH_FEEDING',
     'Стимулирующее кормление (фlushing)',
     'Усиленное кормление коров и тёлок концентратами за 2-3 недели '
     'до начала случки для повышения оплодотворяемости. '
     'Усиленное кормление быков-производителей.',
     'zootechnical', -21, false, false, null,
     'Стимулирующий рацион введён? Сколько дней до начала случки?',
     '[{"field": "days_to_breeding", "unit": "days"}]', 2)
on conflict (phase_template_id, code) do nothing;

-- ── ПОДБОР БЫКОВ-ПРОИЗВОДИТЕЛЕЙ ──────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_bull_select, 'BULL_HEALTH_CHECK',
     'Клиническая оценка быков перед случкой',
     'Оценка состояния половых органов. Контроль качества спермы. '
     'Проверка на репродуктивные инфекции (трихомоноз, лептоспироз). '
     'Исключение быков с патологиями.',
     'veterinary', 0, false, false, null,
     'Все быки-производители прошли проверку? Есть проблемы?',
     '[{"field": "bulls_approved", "unit": "heads"}, {"field": "issues", "type": "text"}]', 1),

    (v_bull_select, 'BULL_PAIRING_PLAN',
     'Составление плана подбора производителей',
     'Формирование плана подбора быков-производителей к маточному стаду. '
     'График работы быков. Проверка племенных свидетельств.',
     'zootechnical', 7, false, false, null,
     'План подбора быков составлен?',
     '[{"field": "done", "type": "boolean"}]', 2)
on conflict (phase_template_id, code) do nothing;

-- ── СЛУЧНАЯ КАМПАНИЯ ─────────────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_breeding, 'BREEDING_START',
     'Начало вольной случки / искусственного осеменения',
     'Вольная случка согласно графику или искусственное осеменение. '
     'Ведение журнала осеменения и календаря отёлов.',
     'zootechnical', 0, true, false, null,
     'Случка началась? Сколько коров уже осеменены?',
     '[{"field": "inseminated_count", "unit": "heads"}]', 1),

    (v_breeding, 'ESTRUS_MONITOR',
     'Ежедневный контроль охоты',
     'Ежедневная фиксация признаков охоты. Отбор животных для осеменения '
     'в оптимальный срок. Подкорм концентратами для оплодотворяемости.',
     'zootechnical', 0, false, false, null,
     'Сколько коров в охоте сегодня?',
     '[{"field": "in_heat_today", "unit": "heads"}]', 2),

    (v_breeding, 'BREEDING_END',
     'Завершение случки и отделение быков',
     'Отделение быков от стада по окончании кампании. '
     'Сводные данные: сколько осеменено, индекс выявления охоты.',
     'zootechnical', 65, false, false, null,
     'Случная кампания завершена? Сколько всего коров осеменено?',
     '[{"field": "total_inseminated", "unit": "heads"}, {"field": "total_in_group", "unit": "heads"}]', 3)
on conflict (phase_template_id, code) do nothing;

-- ── ДИАГНОСТИКА СТЕЛЬНОСТИ ───────────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_preg_check, 'PREGNANCY_TEST',
     'Диагностика стельности (ректальное / УЗИ)',
     'Проведение через 45-60 дней после последней случки. '
     'Ректальное исследование или УЗИ. Протокол исследования на стельность.',
     'veterinary', 0, true, false, null,
     'Диагностику провели? Сколько коров стельных из скольки проверенных?',
     '[{"field": "pregnant_count", "unit": "heads"}, {"field": "total_checked", "unit": "heads"}]', 1),

    (v_preg_check, 'ESTRUS_STIMULATION',
     'Стимулирование охоты у яловых коров',
     'Применение простагландинов для стимулирования охоты у коров, '
     'не ставших стельными. Повторное осеменение.',
     'veterinary', 7, false, false, null,
     'Сколько яловых коров получили гормональную обработку?',
     '[{"field": "treated_count", "unit": "heads"}]', 2),

    (v_preg_check, 'CULL_BARREN',
     'Выбраковка яловых и бесплодных животных',
     'Постановка на откорм коров, не ставших стельными после повторного осеменения. '
     'Обновление данных по поголовью.',
     'zootechnical', 21, false, true, 'head_count_change',
     'Сколько яловых коров выбраковываете?',
     '[{"field": "culled_barren_count", "unit": "heads"}]', 3)
on conflict (phase_template_id, code) do nothing;

-- ── СУХОСТОЙ И ПОДГОТОВКА К ОТЁЛУ ────────────────────────────
insert into public.task_templates
    (phase_template_id, code, name_ru, description_ru, category,
     offset_from_phase_start_days, erp_sync_required,
     creates_herd_event, herd_event_type,
     ai_completion_question_ru, ai_extraction_hints, sort_order)
values
    (v_dry_period, 'DRY_OFF',
     'Перевод коров и нетелей в сухостой',
     'Перевод за 60-70 дней до ожидаемого отёла. '
     'Акт перевода. Проверка ожидаемых сроков отёлов из журнала осеменений.',
     'zootechnical', 0, false, false, null,
     'Сколько коров перевели в сухостой?',
     '[{"field": "dry_cows_count", "unit": "heads"}]', 1),

    (v_dry_period, 'PRE_CALVING_SETUP',
     'Оборудование денников за 2 недели до отёлов',
     'Подготовка родильного отделения. Дезинфекция. '
     'Обеспечение коров и нетелей достаточным уровнем энергии '
     'и минеральных веществ перед отёлами.',
     'zootechnical', 50, false, false, null,
     'Денники готовы? Сколько коров ожидается в ближайшие 2 недели?',
     '[{"field": "expected_calving_count", "unit": "heads"}]', 2),

    (v_dry_period, 'VET_PRE_CALVING',
     'Ветеринарные мероприятия перед отёлами',
     'Вакцинации по эпизоотическому плану (разрешённые для стельных). '
     'Профилактика задержания последа. Контроль состояния стельных коров.',
     'veterinary', 0, false, false, null,
     'Стельные коровы в порядке? Ест ли профилактические препараты?',
     '[{"field": "issues", "type": "text"}]', 3)
on conflict (phase_template_id, code) do nothing;

-- ============================================================
-- SECTION 5: KPI TEMPLATES — BEEF_COW_CALF_KZ
-- Источник: ЦТК.xlsx, строки «KPI зоотехнических работ».
-- Нормативные значения из ЦТК — корректируются зоотехником.
-- ============================================================

insert into public.kpi_templates
    (phase_template_id, code, name_ru, description_ru,
     kpi_type, unit, target_value, tolerance_pct, higher_is_better)
values
    -- ОТЁЛ
    (v_calving, 'CALVING_RATE',
     'Выход телят, %',
     'Количество рождённых живых телят / количество коров в отёле × 100. '
     'Норматив ЦТК: не менее 80%.',
     'calving_rate_pct', '%', 80.0, 5.0, true),

    -- ПОДСОСНЫЙ ПЕРИОД
    (v_suckling, 'CALF_SURVIVAL',
     'Сохранность телят, %',
     'Количество телят на отъёме / количество рождённых телят × 100. '
     'Норматив ЦТК: не менее 80%.',
     'mortality_rate_pct', '%', 80.0, 5.0, true),

    -- ОТЪЁМ
    (v_weaning, 'WEANING_WEIGHT_HEIFER',
     'Живая масса тёлок при отъёме, кг',
     'Средняя живая масса ремонтных тёлок при отъёме в 7-8 мес. '
     'Норматив ЦТК: не менее 155-165 кг.',
     'weight_gain_kg', 'кг', 160.0, 5.0, true),

    (v_weaning, 'WEANING_WEIGHT_BULL',
     'Живая масса бычков при отъёме, кг',
     'Средняя живая масса бычков при отъёме в 7-8 мес. '
     'Норматив ЦТК: не менее 170-180 кг.',
     'weight_gain_kg', 'кг', 175.0, 5.0, true),

    -- БОНИТИРОВКА
    (v_grading, 'CLASS1_RATE',
     'Доля животных 1 класса и выше, %',
     'Количество животных 1 класса и выше / всего бонитировано × 100.',
     'custom_numeric', '%', 70.0, 10.0, true),

    -- ВЫБРАКОВКА
    (v_culling, 'CULLING_RATE',
     'Процент выбраковки, %',
     'Количество выбракованных коров / общее маточное поголовье × 100. '
     'Норматив ЦТК: не более 15-20%.',
     'mortality_rate_pct', '%', 15.0, 5.0, false),

    -- ЗИМНИЙ СТОЙЛОВЫЙ
    (v_winter_stall, 'WINTER_DAILY_GAIN',
     'Среднесуточный прирост молодняка в стойловый период, г',
     'Среднесуточный прирост живой массы молодняка в зимний период.',
     'daily_gain_g', 'г/сут', 700.0, 10.0, true),

    -- ПОДГОТОВКА К СЛУЧКЕ
    (v_breed_prep, 'HEIFER_BREEDING_AGE',
     'Возраст первой случки тёлок, мес',
     'Средний возраст ремонтных тёлок при первой случке. '
     'Норматив ЦТК: не позднее 18 мес.',
     'custom_numeric', 'мес', 18.0, 0.0, false),

    (v_breed_prep, 'HEIFER_BREEDING_WEIGHT',
     'Живая масса тёлок перед первой случкой, %',
     'Живая масса тёлки / живая масса взрослой коровы × 100. '
     'Норматив ЦТК: не менее 70%.',
     'custom_numeric', '%', 70.0, 5.0, true),

    -- СЛУЧНАЯ КАМПАНИЯ
    (v_breeding, 'ESTRUS_DETECTION_INDEX',
     'Индекс выявления охоты, %',
     '% коров, осеменённых в течение первых 21 дня / общее маточное поголовье. '
     'Норматив ЦТК: не менее 70% за первые 21 день.',
     'conception_rate_pct', '%', 70.0, 10.0, true),

    -- ДИАГНОСТИКА СТЕЛЬНОСТИ
    (v_preg_check, 'CONCEPTION_RATE',
     'Процент стельных, %',
     'Количество стельных коров / количество осеменённых × 100. '
     'Норматив ЦТК: ≥ 85%.',
     'conception_rate_pct', '%', 85.0, 5.0, true),

    (v_preg_check, 'INSEMINATION_INDEX',
     'Индекс осеменения',
     'Среднее количество осеменений на одну стельность. '
     'Норматив ЦТК: 1.5-1.6.',
     'custom_numeric', 'доз', 1.55, 5.0, false)
on conflict (phase_template_id, code) do nothing;

-- ============================================================
-- SECTION 6: TASK TEMPLATE SOPs (связи задач с документами)
-- D83: many-to-many через task_template_sops
-- ============================================================

insert into public.task_template_sops (task_template_id, sop_document_id)
select tt.id, sd.id
from (values
    ('CALVING_SETUP',       'SOP_CALVING_ORG'),
    ('CALVING_MONITOR',     'SOP_CALVING_ORG'),
    ('CALVING_MONITOR',     'SOP_VET_CALVING'),
    ('CALF_TAGGING',        'SOP_CALF_ID'),
    ('CALF_TAGGING',        'SOP_HERD_MOVEMENT'),
    ('CALVING_VET',         'SOP_VET_CALVING'),
    ('INVENTORY',           'SOP_HERD_MOVEMENT'),
    ('CALF_FEEDING_SOLID',  'SOP_CALF_REARING'),
    ('WEANING_SEPARATION',  'SOP_WEANING'),
    ('WEANING_SEPARATION',  'SOP_HERD_MOVEMENT'),
    ('WEANING_WEIGH',       'SOP_WEANING'),
    ('GRADING_PREP',        'SOP_GRADING'),
    ('GRADING_EXEC',        'SOP_GRADING'),
    ('GRADING_EXEC',        'SOP_HERD_MOVEMENT'),
    ('CULLING_PLAN',        'SOP_CULLING'),
    ('CULLING_PLAN',        'SOP_HERD_MOVEMENT'),
    ('SALE_BATCH',          'SOP_SALE_CONTRACT'),
    ('SALE_BATCH',          'SOP_HERD_MOVEMENT'),
    ('FEED_HARVEST',        'SOP_FEED_PLAN'),
    ('FACILITY_WINTERIZE',  'SOP_WINTER_PREP'),
    ('RATION_CONTROL',      'SOP_WINTER_HOUSING'),
    ('VET_WINTER',          'SOP_VET_AUTUMN'),
    ('GROUP_BREEDING_FORM', 'SOP_BREEDING_PREP'),
    ('BREEDING_START',      'SOP_BREEDING_CAMPAIGN'),
    ('BREEDING_START',      'SOP_AI'),
    ('ESTRUS_MONITOR',      'SOP_BREEDING_CAMPAIGN'),
    ('BREEDING_END',        'SOP_BREEDING_CAMPAIGN'),
    ('PREGNANCY_TEST',      'SOP_PREGNANCY_DIAG'),
    ('BULL_HEALTH_CHECK',   'SOP_BULL_MANAGEMENT'),
    ('BULL_PAIRING_PLAN',   'SOP_BULL_MANAGEMENT'),
    ('DRY_OFF',             'SOP_DRY_PERIOD'),
    ('PRE_CALVING_SETUP',   'SOP_DRY_PERIOD'),
    ('VET_PRE_CALVING',     'SOP_VET_CALVING')
) as links(task_code, sop_code)
join public.task_templates tt on tt.code = links.task_code
join public.sop_documents  sd on sd.code = links.sop_code
on conflict do nothing;

-- ============================================================
-- SECTION 7: FARM LAUNCH TEMPLATE (is_recurring=false)
-- Источник: лист «подгот. период до запуска»
-- ============================================================

insert into public.phase_templates
    (cycle_template_id, code, name_ru, description_ru,
     sort_order, offset_from_cycle_start_days, duration_days,
     animal_category_codes, is_sale_phase)
values
    (v_launch_id, 'SITE_SELECTION',
     'Поиск территории и земельного участка', 
     'Выбор участка согласно требованиям к мясной ферме. '
     'Оценка доступа к воде, пастбищам, дорогам.',
     1, 0, 30, '{}', false),

    (v_launch_id, 'FACILITY_AUDIT',
     'Технический аудит помещений и оборудования',
     'Инвентаризационная опись с описанием технического состояния. '
     'Оценка соответствия требованиям к помещениям.',
     2, 30, 30, '{}', false),

    (v_launch_id, 'FACILITY_PREP',
     'Подготовка и ремонт помещений',
     'Ремонт коровников, загонов, оборудования. '
     'Дезинфекция помещений.',
     3, 60, 45, '{}', false),

    (v_launch_id, 'FEED_CALCULATION',
     'Расчёт потребности в кормах',
     'Расчёт потребности в кормах с резервным запасом на год '
     'по методике ТУРАН.',
     4, 105, 10, '{}', false),

    (v_launch_id, 'FEED_PROCUREMENT',
     'Поиск и закуп кормов',
     'Поиск надёжных поставщиков. Закупка высококачественных кормов '
     'с резервным запасом. Контроль качества.',
     5, 115, 30, '{}', false),

    (v_launch_id, 'STAFF_HIRING',
     'Подбор кадров и обслуживающего персонала',
     'Наём зоотехника, ветеринара, скотников. '
     'Оформление должностных инструкций.',
     6, 145, 30, '{}', false),

    (v_launch_id, 'ANIMAL_PROCUREMENT',
     'Приобретение племенных тёлок',
     'Поиск надёжных поставщиков. Отбор племенных тёлок '
     'по чек-листу ТУРАН. Акт отбора.',
     7, 175, 30, '{}', false),

    (v_launch_id, 'QUARANTINE',
     'Карантин и ветеринарные обработки при поступлении',
     'Обязательный карантин 30 дней. Ветеринарные обработки '
     'согласно законодательству РК.',
     8, 205, 30, array['HEIFER_YOUNG'], false),

    (v_launch_id, 'FARM_START',
     'Постановка животных в хозяйство',
     'Отправка животных из карантина в хозяйство. '
     'Акт приёма-передачи. Путевые листы.',
     9, 235, 5, array['HEIFER_YOUNG', 'COW'], false)

on conflict (cycle_template_id, code) do nothing;

end $$;

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- Summary:
--   production_cycle_templates:  5 (3 updated + 2 new)
--   sop_documents:               25
--   phase_templates (cow_calf):  15 фаз
--   phase_templates (launch):     9 фаз
--   task_templates:              ~45 задач
--   kpi_templates:               12 KPI
--   task_template_sops:          33 связи
--
-- Q65: CLOSED ✅
--   Весь контент ЦТК (cow_calf модель) сидирован программно.
--   P8 (Standards as Data): зоотехник редактирует через Expert Console.
--   Финишинг, бридинг — отдельные ЦТК, отдельные seed-миграции.
--
-- Что ПУСТОЕ намеренно (Q-статус):
--   sop_documents.storage_url — заполняется после загрузки PDF в Storage
--   task_templates.ai_extraction_hints — детализируется в Dok 5 (AI Gateway)
--   vet tasks — placeholder, детализирует ветврач ассоциации
-- ============================================================


-- === FROM 008: Cascade Date Shift (D104) ===
-- ============================================================
-- AGOS Migration 008: CASCADE DATE SHIFT
-- Project: TURAN Agricultural Operating System
-- Version: 1.0 | Date: 5 March 2026
--
-- Decision implemented: D104
--
-- Problem:
--   Если случная кампания сдвинулась на 3 недели (быки заболели,
--   задержка доставки) — зоотехник вручную двигает 5-7 зависимых фаз.
--   Это ошибки, потеря точности, расхождение план/факт.
--
-- Solution:
--   Двухуровневая модель зависимостей фаз:
--
--   УРОВЕНЬ 1 — Шаблон (phase_templates):
--     date_type: 'sequential' | 'calendar' | 'parallel'
--     depends_on_phase_code: какая фаза является основой
--     lag_days_after_dependency: пауза после завершения основной фазы
--     → Используется fn_generate_production_plan() при создании плана
--
--   УРОВЕНЬ 2 — Экземпляр (farm_phases):
--     depends_on_phase_id: FK на конкретную FarmPhase
--     lag_days: пауза (копируется из шаблона, эксперт может изменить)
--     date_type: копируется из шаблона
--     original_duration_days: исходная длительность (для сохранения при каскаде)
--     → Используется fn_shift_phase_cascade() при сдвиге
--
--   RPC: fn_shift_phase_cascade(phase_id, new_start_date, actor_id)
--     → Сдвигает фазу и каскадирует все зависимые (рекурсивно)
--     → Останавливается на date_type='calendar' (якорные фазы)
--     → Не трогает completed/skipped фазы
--     → Возвращает JSONB с итогом: что сдвинулось
--
-- Типы фаз cow_calf цикла (зафиксировано в D104):
--
--   CALENDAR (якорные — не каскадируются):
--     CALVING        — декабрь-январь, биологический якорь цикла (D-5 fix)
--     PASTURE_PREP   — май, определяется погодой/сезоном
--     WINTER_PREP    — июнь-октябрь, параллельно с пастбищем
--     WINTER_STALL   — ноябрь, сезонный переход
--     BREEDING_PREP  — февраль, готовность к сезону
--     BULL_SELECTION — параллельно с подготовкой
--
--   SEQUENTIAL (биологически последовательные — каскадируются):
--     SUCKLING        → зависит от CALVING     (lag 7 дней)
--     WEANING         → зависит от SUCKLING    (lag 0)
--     GRADING         → зависит от WEANING     (lag 5)
--     CULLING         → зависит от GRADING     (lag 0)
--     SALE            → зависит от CULLING     (lag 14)
--     BREEDING        → зависит от BREEDING_PREP (lag 0)
--     PREGNANCY_CHECK → зависит от BREEDING   (lag 45)
--     DRY_PERIOD      → зависит от BREEDING   (lag 235) -- ~280 дней стельности - 45 дней сухостоя
--
--   PARALLEL (идут параллельно, не зависят от других):
--     SUMMER_PASTURE  — параллельно с SUCKLING
--
-- Depends on: 005_ops_edu.sql, 007_ctk_seed.sql
-- Required by: Dok 3 fn_generate_production_plan() spec
-- ============================================================

-- ============================================================
-- PATCH 1: phase_templates — добавить тип и зависимость
-- Используется fn_generate_production_plan() при создании плана.
-- ============================================================

alter table public.phase_templates
    add column if not exists date_type text not null default 'calendar'
        check (date_type in (
            'sequential',   -- начинается через lag дней после окончания depends_on
            'calendar',     -- привязана к сезону/месяцу, не к другой фазе
            'parallel'      -- идёт параллельно, не зависит от других
        )),
    add column if not exists depends_on_phase_code text,  -- code фазы-основы в том же шаблоне
    add column if not exists lag_days_after_dependency int not null default 0
        check (lag_days_after_dependency >= 0);

comment on column public.phase_templates.date_type is
    'D104: Тип зависимости фазы.
     sequential: начинается через lag_days_after_dependency дней после окончания depends_on.
                 fn_generate_production_plan() ставит depends_on_phase_id при генерации.
                 fn_shift_phase_cascade() каскадирует при сдвиге.
     calendar:   привязана к сезону. Эксперт ставит дату вручную.
                 Каскад ОСТАНАВЛИВАЕТСЯ на этой фазе.
     parallel:   идёт параллельно. Не участвует в каскаде.';

comment on column public.phase_templates.depends_on_phase_code is
    'D104: code фазы-предшественника в том же production_cycle_template.
     NULL для calendar и parallel фаз.
     fn_generate_production_plan() резолвит code → id при создании FarmPhase.';

comment on column public.phase_templates.lag_days_after_dependency is
    'D104: Пауза в днях между окончанием depends_on фазы и началом этой.
     Биологический смысл:
       PREGNANCY_CHECK: 45 дней (минимальный срок после случки для диагностики)
       DRY_PERIOD: 235 дней (280 дней стельности - 45 дней сухостоя)
       GRADING: 5 дней (подготовка документов после отъёма)';

-- ============================================================
-- PATCH 2: farm_phases — добавить экземплярные зависимости
-- Используется fn_shift_phase_cascade() при каскаде.
-- ============================================================

alter table public.farm_phases
    add column if not exists depends_on_phase_id uuid
        references public.farm_phases(id) on delete set null,
    add column if not exists lag_days int not null default 0
        check (lag_days >= 0),
    add column if not exists date_type text not null default 'calendar'
        check (date_type in ('sequential', 'calendar', 'parallel')),
    add column if not exists original_duration_days int
        generated always as (end_date - start_date) stored;

comment on column public.farm_phases.depends_on_phase_id is
    'D104: FK на FarmPhase-предшественника в том же плане.
     NULL для calendar/parallel фаз или если эксперт отвязал зависимость вручную.
     При ON DELETE SET NULL: если предшественник удалён, эта фаза становится orphan.
     Эксперт должен вручную назначить новые даты.';

comment on column public.farm_phases.lag_days is
    'D104: Пауза в днях. Копируется из phase_template.lag_days_after_dependency.
     Эксперт может изменить для конкретной фермы.';

comment on column public.farm_phases.date_type is
    'D104: Копируется из phase_template.date_type при генерации плана.
     Эксперт может изменить (например, сделать фазу calendar чтобы
     заблокировать её от каскада).';

comment on column public.farm_phases.original_duration_days is
    'D104: GENERATED ALWAYS — автоматически вычисляется как end_date - start_date.
     fn_shift_phase_cascade() использует это значение чтобы сохранить длительность
     фазы при каскадном пересчёте дат:
       new_end_date = new_start_date + original_duration_days';

-- ============================================================
-- PATCH 3: Обновить seed data phase_templates из 007
-- Устанавливаем date_type и depends_on_phase_code для cow_calf цикла.
-- ============================================================

-- Сначала обновляем calendar фазы (якорные)
update public.phase_templates set
    date_type = 'calendar',
    depends_on_phase_code = null,
    lag_days_after_dependency = 0
where code in (
    'CALVING',        -- декабрь-январь, начало цикла
    'PASTURE_PREP',   -- май, сезонный переход
    'WINTER_PREP',    -- июнь-октябрь, подготовка
    'WINTER_STALL',   -- ноябрь, стойловый период
    'BREEDING_PREP',  -- февраль
    'BULL_SELECTION'  -- параллельно с BREEDING_PREP
);

-- Параллельная фаза
update public.phase_templates set
    date_type = 'parallel',
    depends_on_phase_code = null,
    lag_days_after_dependency = 0
where code = 'SUMMER_PASTURE';

-- Биологически последовательные фазы
update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'CALVING',
    lag_days_after_dependency = 7
where code = 'SUCKLING';

update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'SUCKLING',
    lag_days_after_dependency = 0
where code = 'WEANING';

update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'WEANING',
    lag_days_after_dependency = 5
where code = 'GRADING';

update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'GRADING',
    lag_days_after_dependency = 0
where code = 'CULLING';

update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'CULLING',
    lag_days_after_dependency = 14
where code = 'SALE';

update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'BREEDING_PREP',
    lag_days_after_dependency = 0
where code = 'BREEDING';

update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'BREEDING',
    lag_days_after_dependency = 45  -- минимальный срок для диагностики
where code = 'PREGNANCY_CHECK';

update public.phase_templates set
    date_type = 'sequential',
    depends_on_phase_code = 'BREEDING',
    lag_days_after_dependency = 235 -- 280 дней стельности - 45 дней сухостоя
where code = 'DRY_PERIOD';

-- ============================================================
-- PATCH 4: RPC fn_shift_phase_cascade()
-- D104: Каскадный сдвиг дат фаз.
-- Вызывается экспертом через Expert Console или AI-агентом.
-- ============================================================

create or replace function public.fn_shift_phase_cascade(
    p_phase_id      uuid,       -- фаза которую сдвигаем
    p_new_start_date date,      -- новая дата начала
    p_actor_id      uuid        -- кто инициировал (для аудита в notes)
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp   -- D-2 fix: защита от schema hijacking
as $$
declare
    v_phase             record;
    v_new_end_date      date;
    v_shifted           jsonb := '[]'::jsonb;
    v_dependent         record;
    v_dep_new_start     date;
    v_dep_new_end       date;
    v_sub_result        jsonb;
    v_shift_days        int;
begin
    -- ── Шаг 1: Загрузить текущую фазу ────────────────────────
    select * into v_phase
    from public.farm_phases
    where id = p_phase_id;

    if not found then
        raise exception 'Phase not found: %', p_phase_id;
    end if;

    -- ── Шаг 2: Не двигать завершённые/пропущенные фазы ───────
    if v_phase.status in ('completed', 'skipped') then
        raise exception
            'Cannot shift phase % — status is %. Only upcoming/active phases can be shifted.',
            p_phase_id, v_phase.status;
    end if;

    -- ── Шаг 3: Вычислить новую дату окончания ─────────────────
    -- Длительность сохраняется: original_duration_days = end - start (GENERATED)
    v_new_end_date := p_new_start_date + v_phase.original_duration_days;

    -- Сдвиг в днях (может быть отрицательным — сдвиг назад)
    v_shift_days := p_new_start_date - v_phase.start_date;

    -- ── Шаг 4: Обновить саму фазу ─────────────────────────────
    update public.farm_phases
    set
        start_date  = p_new_start_date,
        end_date    = v_new_end_date,
        updated_at  = now(),
        notes       = coalesce(notes, '') ||
                      format(
                          E'\n[%s] Дата сдвинута на %s дней зоотехником/системой (actor=%s). '
                          'Было: %s–%s → Стало: %s–%s',
                          now()::date,
                          v_shift_days,
                          p_actor_id,
                          v_phase.start_date, v_phase.end_date,
                          p_new_start_date, v_new_end_date
                      )
    where id = p_phase_id;

    -- ── Шаг 5: Записать этот сдвиг в результат ────────────────
    v_shifted := v_shifted || jsonb_build_object(
        'phase_id',     p_phase_id,
        'phase_name',   v_phase.name_ru,
        'old_start',    v_phase.start_date,
        'old_end',      v_phase.end_date,
        'new_start',    p_new_start_date,
        'new_end',      v_new_end_date,
        'shift_days',   v_shift_days,
        'date_type',    v_phase.date_type
    );

    -- ── Шаг 6: Найти зависимые фазы и каскадировать ──────────
    -- Только sequential, только в том же плане, только не завершённые
    for v_dependent in
        select fp.*
        from public.farm_phases fp
        where fp.plan_id           = v_phase.plan_id
          and fp.depends_on_phase_id = p_phase_id
          and fp.date_type          = 'sequential'
          and fp.status         not in ('completed', 'skipped')
        order by fp.start_date
    loop
        -- Новый старт зависимой = конец сдвинутой фазы + lag
        v_dep_new_start := v_new_end_date + v_dependent.lag_days;

        -- Рекурсивный вызов для зависимой фазы
        v_sub_result := public.fn_shift_phase_cascade(
            v_dependent.id,
            v_dep_new_start,
            p_actor_id
        );

        -- Объединить результаты
        v_shifted := v_shifted || v_sub_result;
    end loop;

    return v_shifted;

exception
    when others then
        raise exception
            'fn_shift_phase_cascade failed for phase %: %', p_phase_id, sqlerrm;
end;
$$;

comment on function public.fn_shift_phase_cascade(uuid, date, uuid) is
    'D104: Каскадный сдвиг дат фаз.
     Алгоритм:
       1. Сдвигает целевую фазу, сохраняя original_duration_days.
       2. Находит все farm_phases с depends_on_phase_id = p_phase_id
          И date_type = sequential И status NOT IN (completed, skipped).
       3. Для каждой: new_start = сдвинутая.end_date + lag_days
       4. Рекурсивно повторяет для каждой зависимой.
       5. Останавливается когда нет зависимых sequential фаз.
       6. calendar/parallel фазы НЕ каскадируются — они "якоря".

     Возвращает JSONB массив сдвинутых фаз:
       [{phase_id, phase_name, old_start, old_end,
         new_start, new_end, shift_days, date_type}, ...]

     Пример использования:
       -- Случная кампания задержалась на 21 день
       select fn_shift_phase_cascade(
           ''<BREEDING phase_id>'',
           ''2026-03-22''::date,   -- вместо 2026-03-01
           auth.uid()
       );
       -- → автоматически сдвинет PREGNANCY_CHECK и DRY_PERIOD

     Атомарность (L-5 fix):
       Функция атомарна БЕЗ явного BEGIN/COMMIT в вызывающем коде.
       PL/pgSQL автоматически создаёт implicit SAVEPOINT в начале каждого
       рекурсивного блока с EXCEPTION clause. Если любая фаза в цепочке
       падает с ошибкой:
         1. Откат к savepoint этого уровня (локальные изменения отменяются)
         2. Исключение re-raise поднимается вверх
         3. Каждый уровень рекурсии откатывается к своему savepoint
         4. Итог: ВСЕ изменения отменены, состояние = до вызова
       Вызов через supabase.rpc() в autocommit режиме безопасен:
       SELECT fn_shift_phase_cascade(...) — это одна транзакция.
       Явный BEGIN/COMMIT НЕ нужен и НЕ добавляет защиты.

     Защита от циклов:
     Защита от циклов:
       Достигается через date_type=sequential: фазы без depends_on_phase_id
       не участвуют в каскаде. Круговые зависимости невозможны т.к.
       depends_on_phase_id создаётся только в fn_generate_production_plan()
       строго по шаблону (DAG по sort_order).';

-- ============================================================
-- SAFETY: L-7 FIX — добавить org check в fn_preview_cascade (008)
--
-- L-7: fn_preview_cascade() — SECURITY DEFINER без ownership check.
--      Любой аутентифицированный пользователь мог передать чужой phase_id
--      и получить полный оперативный план конкурента (дата случки,
--      отёла, продажи — ценная коммерческая информация).
--
-- Патчим здесь (не в 008) чтобы не создавать 011 только ради 5 строк.
-- ============================================================

create or replace function public.fn_preview_cascade(
    p_phase_id      uuid,
    p_new_start_date date
)
returns table (
    phase_id        uuid,
    phase_name      text,
    old_start       date,
    new_start       date,
    old_end         date,
    new_end         date,
    shift_days      int,
    date_type       text,
    depth           int
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
    -- L-7: Security check — актор должен иметь доступ к ферме этой фазы
    -- Выражено как CTE: если доступа нет — основной запрос вернёт 0 строк
    -- (не exception, чтобы не раскрывать существование объекта)
    -- BUG FIX (deploy 2026-07-07): cascade_preview ниже — рекурсивный CTE
    -- (union all ссылается сам на себя), но объявлен без RECURSIVE — Postgres
    -- отклонял forward-reference. RECURSIVE — модификатор всего WITH, не
    -- отдельного CTE; access_check рекурсией не становится, просто идёт первым.
    with recursive access_check as (
        select  fp.id
        from    public.farm_phases               fp
        join    public.farm_production_plans     pp on pp.id = fp.plan_id
        join    public.farms                      f  on f.id  = pp.farm_id
        join    public.user_organization_roles   uor on uor.organization_id = f.organization_id
        where   fp.id          = p_phase_id
          and   uor.user_id    = public.fn_current_user_id()
          -- uor.is_active НЕ существует в user_organization_roles (только is_primary)
    ),

    -- Рекурсивный CTE для вычисления каскада (читает, не меняет данные)
    cascade_preview as (
        -- Якорная фаза (глубина 0)
        select  fp.id             as phase_id,
                fp.name_ru        as phase_name,
                fp.start_date     as old_start,
                p_new_start_date  as new_start,
                fp.end_date       as old_end,
                (p_new_start_date + (fp.end_date - fp.start_date)) as new_end,
                (p_new_start_date - fp.start_date)                 as shift_days,
                fp.date_type,
                0                 as depth
        from    public.farm_phases fp
        join    access_check       ac on ac.id = fp.id   -- L-7: только при наличии доступа
        where   fp.id = p_phase_id
          and   fp.status not in ('completed', 'skipped')

        union all

        -- Зависимые sequential фазы (рекурсия)
        -- ARS-284 bugfix: было `+ 1` — расходилось с реальным писателем fn_shift_phase_cascade
        -- (v_dep_new_start := v_new_end_date + lag_days, БЕЗ +1) → превью всегда обещало на 1 день
        -- позже, чем каскад реально применял (обнаружено живым QA ARS-284: preview "10 авг → 21 июля",
        -- committed "20 июля"). Формула приведена к писателю — превью = зеркало, не разошедшийся дубль.
        select  child.id,
                child.name_ru,
                child.start_date,
                (parent.new_end + child.lag_days)::date,
                child.end_date,
                (parent.new_end + child.lag_days + (child.end_date - child.start_date))::date,
                (parent.new_end + child.lag_days - child.start_date),
                child.date_type,
                parent.depth + 1
        from    public.farm_phases child
        join    cascade_preview    parent on parent.phase_id = child.depends_on_phase_id
        where   child.date_type = 'sequential'
          and   child.status    not in ('completed', 'skipped')
    )

    select  phase_id,
            phase_name,
            old_start,
            new_start,
            old_end,
            new_end,
            shift_days,
            date_type,
            depth
    from    cascade_preview
    order   by depth asc, old_start asc;
$$;

comment on function public.fn_preview_cascade(uuid, date) is
    'L-7 PATCHED: Добавлен access check через CTE.
     Без доступа к org фермы — возвращает 0 строк (не exception).
     Предотвращает утечку оперативных планов конкурентов (ст. 5.9 Dok 1).

     Оригинальная функция: 008_patch_cascade.sql.
     Изменение: security fix в WHERE clause через access_check CTE.
     ARS-284: убран лишний `+ 1` из рекурсивной ветки (было расхождение с
     fn_shift_phase_cascade — превью обещало на 1 день позже реально применяемого
     каскада). Формула снова = зеркало писателя, fn_shift_phase_cascade не менялся (P7).';

-- ============================================================
-- MIGRATION COMPLETE
-- ============================================================
-- New functions:
--   fn_generate_production_plan(...)   → uuid  (core generation logic)
--   rpc_start_production_plan(...)     → jsonb (public RPC wrapper)
--   fn_preview_cascade() REPLACED      → table (L-7 security fix added)
--
-- Defects closed:
--   L-1  ✅  fn_generate_production_plan() реализована
--   L-7  ✅  fn_preview_cascade() — добавлен ownership check
--
-- Decisions implemented:
--   D74  Template → Plan: один вызов = весь план
--   D78  cycle_start_date = дата начала отёлов (не 1 января)
--   D79  expert_profile_id опционально передаётся при создании
--   D80  FarmTask.status='scheduled' сразу при генерации
--   D81  target_sale_month = первый день месяца end_date для sale фаз
--   D82  PLAN_ALREADY_EXISTS check (draft + active)
--   D85  Event ops.production_plan.started + ops.plan.activated
--   D101 auto-match HerdGroup по animal_category_codes
--   D104 depends_on_phase_code → depends_on_phase_id резолвинг
--
-- Zero breaking changes (P7 Additive Architecture):
--   fn_preview_cascade() signature не изменилась.
--   Новые функции — только additive.
--
-- Remaining open from Audit Report:
--   L-2  Python: validate amend_data в confirm_handler
--   L-3  Python: detect_language_pure() без DB-записи
--   L-5  fn_shift_phase_cascade: savepoint enforcement
--   L-9  Dok 5: scheduled_for/scheduled_at — исправить в тексте
--   L-10 Dok 1: обновить нумерацию миграций в §8 v1.5
--   D-2  SET search_path к fn_shift_phase_cascade (008)
--   D-3  Переименовать try_lock_conversation (breaking change — backlog)
--   D-4  Python: datetime.utcnow() → datetime.now(timezone.utc)
--   D-5  008: добавить CALVING в header comment
--   D-6  Backlog: рекурсия → CTE UPDATE
--
-- Next migrations:
--   011_finishing_seed.sql   — ЦТК BEEF_FINISHING_KZ (Dok 1 §8 v1.5)
--   012_breeding_seed.sql    — ЦТК BEEF_BREEDING_KZ
-- ============================================================


-- === FROM 012: rpc_start_production_plan (AI Gateway auth fix) ===
-- ============================================================
-- Migration 012: Patch rpc_start_production_plan for AI Gateway compatibility
-- ============================================================
-- Fix: C-NEW-7 — rpc_start_production_plan calls fn_current_user_id() which
-- returns NULL for service_role JWT (AI Gateway token). This causes UNAUTHORIZED
-- immediately on any AI-initiated production plan creation.
--
-- Root cause: fn_current_user_id() uses auth.uid() → NULL for service_role.
-- Fix: Add optional p_actor_id parameter. When provided (AI Gateway path),
--   use it directly. When NULL (frontend path), fall back to fn_current_user_id().
--
-- BACKWARD COMPATIBLE: p_actor_id defaults to null → existing frontend calls unchanged.
-- ============================================================

create or replace function public.rpc_start_production_plan(
    p_farm_id           uuid,
    p_template_id       uuid,
    p_plan_start_date   date,
    p_target_heads      int     default null,
    p_herd_group_ids    uuid[]  default null,
    p_expert_profile_id uuid    default null,
    p_plan_name         text    default null,
    p_auto_activate     boolean default false,
    p_ai_context        jsonb   default null,
    -- C-NEW-7 FIX: explicit actor_id for service_role / AI Gateway calls
    -- When NULL: falls back to fn_current_user_id() (frontend JWT path)
    -- When set: used directly (AI Gateway service_role path)
    p_actor_id          uuid    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id  uuid;
    v_plan_id   uuid;
begin
    -- C-NEW-7 FIX: resolve actor — explicit takes priority, then JWT, then fail
    v_actor_id := coalesce(p_actor_id, public.fn_current_user_id());

    if v_actor_id is null then
        raise exception 'UNAUTHORIZED: необходима аутентификация (JWT или p_actor_id)'
            using errcode = 'P0001';
    end if;

    -- Access check: actor belongs to the farm's organization
    -- (works for both paths: JWT user or AI Gateway service_role with explicit actor)
    if not exists (
        select 1
        from   public.farms               f
        join   public.user_organization_roles uor
               on uor.organization_id = f.organization_id
        where  f.id        = p_farm_id
          and  uor.user_id = v_actor_id
    ) then
        raise exception 'FORBIDDEN: у пользователя (actor %) нет доступа к ферме %',
            v_actor_id, p_farm_id
            using errcode = 'P0001';
    end if;

    -- Delegate to core generation function
    v_plan_id := public.fn_generate_production_plan(
        p_farm_id           := p_farm_id,
        p_template_id       := p_template_id,
        p_plan_start_date   := p_plan_start_date,
        p_actor_id          := v_actor_id,
        p_target_heads      := p_target_heads,
        p_herd_group_ids    := p_herd_group_ids,
        p_expert_profile_id := p_expert_profile_id,
        p_plan_name         := p_plan_name
    );

    -- Auto-activate for AI-initiated requests
    if p_auto_activate then
        update public.farm_production_plans
        set    status       = 'active',
               activated_at = now(),
               updated_at   = now()
        where  id = v_plan_id;

        insert into public.platform_events (
            event_type, entity_type, entity_id,
            organization_id, actor_type, actor_id, payload
        )
        select  'ops.plan.activated',
                'farm_production_plans',
                v_plan_id,
                organization_id,
                case when p_ai_context is not null then 'ai_gateway' else 'farmer' end,
                v_actor_id,
                jsonb_build_object(
                    'plan_id',           v_plan_id,
                    'farm_id',           p_farm_id,
                    'activated_by_ai',   (p_ai_context is not null),
                    'ai_context',        p_ai_context
                )
        from    public.farm_production_plans
        where   id = v_plan_id;
    end if;

    return jsonb_build_object(
        'plan_id', v_plan_id,
        'status',  case when p_auto_activate then 'active' else 'draft' end,
        'actor_id', v_actor_id,
        'message', case
                       when p_auto_activate
                       then 'Производственный план создан и активирован'
                       else 'Производственный план создан (черновик). '
                            'Проверьте даты фаз и активируйте в Expert Console.'
                   end
    );

exception
    when others then
        return jsonb_build_object(
            'error',   true,
            'code',    sqlstate,
            'message', sqlerrm
        );
end;
$$;

comment on function public.rpc_start_production_plan(
    uuid, uuid, date, int, uuid[], uuid, text, boolean, jsonb, uuid
) is
    'Dok 3 RPC-33 (patched 012): Launch production plan from ЦТК template.
     C-NEW-7 FIX: Added p_actor_id parameter (default null).
       - p_actor_id IS NULL  → frontend path: actor = fn_current_user_id() (JWT)
       - p_actor_id PROVIDED → AI Gateway path: actor = p_actor_id (service_role compat)
     BACKWARD COMPATIBLE: all existing frontend calls unchanged (p_actor_id defaults null).
     AI Gateway call pattern:
       supabase.rpc("rpc_start_production_plan", {
         ...,
         "p_actor_id": "<farmer_user_id_from_state>",
         "p_auto_activate": True,
         "p_ai_context": {...}
       })';


-- === FROM 015: fn_shift_phase_cascade iterative, fn_generate batch INSERT ===
-- PART 4: D-NEW-4 — Batch INSERT for tasks and KPIs
-- ============================================================
-- PROBLEM:
--   fn_generate_production_plan() has two nested FOR loops:
--   1. Phase loop (outer): processes phases in sort_order — CANNOT be batched
--      because sequential phases need predecessor's end_date from previous iteration.
--   2. Task loop (inner, nested in phase loop): creates tasks one-by-one per phase.
--   3. KPI loop (after phase loop): creates KPIs one-by-one.
--
--   For cow_calf template: 10 phases × ~5 tasks = 50 sequential INSERT statements.
--   Plus ~15 KPI INSERTs. Total: ~75 individual INSERTs for one production plan.
--
-- SOLUTION:
--   Keep phase loop (sequential dependency resolution is inherently row-by-row).
--   Remove nested task loop. After all phases are inserted:
--     - Batch INSERT all tasks via JOIN (task_templates → farm_phases via phase_template_id)
--     - Batch INSERT all KPIs via same JOIN
--   Result: 10 phase INSERTs + 1 task batch INSERT + 1 KPI batch INSERT = 12 statements.
--   ~6x fewer DB operations. PostgreSQL processes batch INSERT much more efficiently.
--
-- BACKWARD COMPATIBLE: same function signature, same return value (plan_id uuid).
-- ============================================================

create or replace function public.fn_generate_production_plan(
    p_farm_id           uuid,
    p_template_id       uuid,
    p_plan_start_date   date,
    p_actor_id          uuid,
    p_target_heads      int          default null,
    p_herd_group_ids    uuid[]       default null,
    p_expert_profile_id uuid         default null,
    p_plan_name         text         default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_plan_id           uuid;
    v_plan_name         text;
    v_cycle_end_date    date;
    v_organization_id   uuid;
    v_farm_name         text;
    v_template          record;
    v_cycle_days        int;
    v_phase_template    record;
    v_phase_id          uuid;
    v_phase_start       date;
    v_phase_end         date;
    v_herd_group_id     uuid;
    v_dep_phase_id      uuid;
    v_kpi_target_heads  int;
    v_phases_created    int := 0;
    v_tasks_created     int := 0;
    v_kpis_created      int := 0;
begin
    -- ── 1. ВАЛИДАЦИЯ ────────────────────────────────────────
    select f.organization_id, f.name
    into   v_organization_id, v_farm_name
    from   public.farms f
    where  f.id = p_farm_id and f.is_active = true;

    if not found then
        raise exception 'FARM_NOT_FOUND: ферма % не найдена или неактивна', p_farm_id
            using errcode = 'P0001';
    end if;

    select  pct.id, pct.code, pct.name_ru, pct.cycle_duration_days, pct.is_recurring
    into    v_template
    from    public.production_cycle_templates pct
    where   pct.id = p_template_id and pct.is_active = true;

    if not found then
        raise exception 'TEMPLATE_NOT_FOUND: шаблон ЦТК % не найден', p_template_id
            using errcode = 'P0001';
    end if;

    v_cycle_days := v_template.cycle_duration_days;

    if exists (
        select 1 from public.farm_production_plans
        where farm_id = p_farm_id and status in ('draft', 'active')
    ) then
        raise exception 'PLAN_ALREADY_EXISTS: у фермы % уже есть активный/черновой план', p_farm_id
            using errcode = 'P0001';
    end if;

    if p_plan_start_date < current_date - interval '90 days' then
        raise exception 'INVALID_START_DATE: дата % слишком далеко в прошлом (>90 дней)', p_plan_start_date
            using errcode = 'P0001';
    end if;

    -- ── 2. MAP: phase_code → {phase_id, end_date} ───────────
    create temporary table if not exists _phase_code_map (
        phase_code  text    primary key,
        phase_id    uuid    not null,
        start_date  date    not null,
        end_date    date    not null
    ) on commit drop;
    -- FARM-02-bis (ARS-215): DELETE без WHERE блокируется Supabase safeupdate-гардом для
    -- API-ролей (authenticated/service_role) — функция падала 21000 при ЛЮБОМ реальном
    -- вызове через rpc.*, работала только с прямого psql-подключения (маскировалось
    -- graceful-фоллбэком мастера на F7 «Стадо записано» — план молча не создавался никогда).
    -- TRUNCATE не подпадает под гард и корректен для temp-таблицы в транзакции.
    truncate _phase_code_map;

    -- ── 3. СОЗДАТЬ FarmProductionPlan ────────────────────────
    v_cycle_end_date := p_plan_start_date + (v_cycle_days - 1);
    v_plan_name := coalesce(
        p_plan_name,
        'ЦТК ' || to_char(p_plan_start_date, 'YYYY') || ' — ' || v_farm_name
    );

    insert into public.farm_production_plans (
        farm_id, organization_id, cycle_template_id, expert_profile_id,
        name, cycle_start_date, cycle_end_date, status, created_by
    ) values (
        p_farm_id, v_organization_id, p_template_id, p_expert_profile_id,
        v_plan_name, p_plan_start_date, v_cycle_end_date, 'draft', p_actor_id
    )
    returning id into v_plan_id;

    -- ── 4. PHASE LOOP: обязательно row-by-row ────────────────
    -- Sequential фазы зависят от end_date предшественника — вычисляется в _phase_code_map.
    -- D-NEW-4: задачи и KPI вынесены из этого цикла в batch INSERT ниже.
    for v_phase_template in
        select  pt.id as template_id, pt.code, pt.name_ru, pt.sort_order,
                pt.offset_from_cycle_start_days, pt.duration_days,
                pt.animal_category_codes, pt.is_sale_phase,
                pt.suggested_period_type_code, pt.date_type,
                pt.depends_on_phase_code, pt.lag_days_after_dependency
        from    public.phase_templates pt
        where   pt.cycle_template_id = p_template_id
        order   by pt.sort_order asc
    loop
        -- 4a. Вычислить start_date / end_date
        if v_phase_template.date_type = 'sequential' then
            if v_phase_template.depends_on_phase_code is null then
                raise exception
                    'TEMPLATE_ERROR: фаза % (code=%) имеет date_type=sequential но depends_on_phase_code=NULL',
                    v_phase_template.name_ru, v_phase_template.code
                    using errcode = 'P0001';
            end if;
            select m.end_date into v_phase_start
            from   _phase_code_map m
            where  m.phase_code = v_phase_template.depends_on_phase_code;
            if not found then
                raise exception
                    'TEMPLATE_ORDER_ERROR: фаза % зависит от % который ещё не создан. Проверьте sort_order.',
                    v_phase_template.code, v_phase_template.depends_on_phase_code
                    using errcode = 'P0001';
            end if;
            v_phase_start := v_phase_start + v_phase_template.lag_days_after_dependency;
            v_phase_end   := v_phase_start + (v_phase_template.duration_days - 1);
        else
            v_phase_start := p_plan_start_date + v_phase_template.offset_from_cycle_start_days;
            v_phase_end   := v_phase_start + (v_phase_template.duration_days - 1);
        end if;

        -- 4b. D101: найти herd_group_id
        v_herd_group_id := null;
        if p_herd_group_ids is not null and array_length(p_herd_group_ids, 1) > 0 then
            select hg.id into v_herd_group_id
            from   public.herd_groups hg
            join   public.animal_categories ac on ac.id = hg.animal_category_id
            where  hg.id = any(p_herd_group_ids) and hg.farm_id = p_farm_id
              and  hg.is_active = true
              and  ac.code = any(v_phase_template.animal_category_codes)
            limit 1;
        elsif array_length(v_phase_template.animal_category_codes, 1) > 0 then
            select hg.id into v_herd_group_id
            from   public.herd_groups hg
            join   public.animal_categories ac on ac.id = hg.animal_category_id
            where  hg.farm_id = p_farm_id and hg.is_active = true
              and  ac.code = any(v_phase_template.animal_category_codes)
            limit 1;
        end if;

        -- 4c. D104: резолвить depends_on_phase_id
        v_dep_phase_id := null;
        if v_phase_template.depends_on_phase_code is not null then
            select m.phase_id into v_dep_phase_id
            from   _phase_code_map m
            where  m.phase_code = v_phase_template.depends_on_phase_code;
        end if;

        -- 4d. INSERT FarmPhase
        insert into public.farm_phases (
            plan_id, organization_id, phase_template_id, herd_group_id,
            name_ru, start_date, end_date, is_sale_phase, target_sale_month,
            date_type, depends_on_phase_id, lag_days, status
        ) values (
            v_plan_id, v_organization_id, v_phase_template.template_id, v_herd_group_id,
            v_phase_template.name_ru, v_phase_start, v_phase_end,
            v_phase_template.is_sale_phase,
            case when v_phase_template.is_sale_phase
                 then date_trunc('month', v_phase_end)::date else null end,
            v_phase_template.date_type, v_dep_phase_id,
            v_phase_template.lag_days_after_dependency, 'upcoming'
        )
        returning id into v_phase_id;

        v_phases_created := v_phases_created + 1;

        -- Update map for downstream sequential phases
        insert into _phase_code_map (phase_code, phase_id, start_date, end_date)
        values (v_phase_template.code, v_phase_id, v_phase_start, v_phase_end);

        -- ── D-NEW-4: NO task loop here — batch INSERT after phase loop ──
    end loop;
    -- END phase loop

    -- ── 5. BATCH INSERT: все FarmTask за один запрос ─────────
    -- D-NEW-4: Заменяет вложенный FOR loop (N×M individual INSERTs → 1 batch INSERT).
    -- JOIN: farm_phases(plan_id=v_plan_id) → task_templates(phase_template_id)
    -- D141 (ARS-279): окна-задачи генерируются здесь (аддитивно к D-NEW-4 batch INSERT).
    -- window_duration_days is not null → window_start = phase.start + offset,
    -- window_end = window_start + (duration-1) [inclusive — конвенция фаз, ср. farm_phases
    -- end = start + duration-1], head_count_planned = head_count группы фазы на момент генерации,
    -- due_date = window_end (инвариант farm_tasks_window_due_check). Точечная задача
    -- (window_duration_days null) сохраняет прежнее поведение: window_* = null,
    -- due_date = phase.start + offset. Пока ни один task_template не задаёт window_duration_days
    -- (контент — ARS-172) ветка окна = no-op → генерация существующих планов байт-идентична.
    insert into public.farm_tasks (
        farm_phase_id, organization_id, task_template_id,
        name_ru, category, due_date, status, erp_sync,
        window_start, window_end, head_count_planned
    )
    select
        fp.id,
        v_organization_id,
        tt.id,
        tt.name_ru,
        tt.category,
        case when tt.window_duration_days is not null
             then fp.start_date + coalesce(tt.offset_from_phase_start_days, 0) + (tt.window_duration_days - 1)
             else fp.start_date + coalesce(tt.offset_from_phase_start_days, 0)
        end,
        'scheduled',
        coalesce(tt.erp_sync_required, false),
        case when tt.window_duration_days is not null
             then fp.start_date + coalesce(tt.offset_from_phase_start_days, 0) end,
        case when tt.window_duration_days is not null
             then fp.start_date + coalesce(tt.offset_from_phase_start_days, 0) + (tt.window_duration_days - 1) end,
        case when tt.window_duration_days is not null
             then (select nullif(hg.head_count, 0) from public.herd_groups hg where hg.id = fp.herd_group_id) end
    from   public.farm_phases fp
    join   public.task_templates tt on tt.phase_template_id = fp.phase_template_id
    where  fp.plan_id = v_plan_id
    order  by fp.start_date, tt.sort_order;

    get diagnostics v_tasks_created = row_count;

    -- D141 (ARS-279): prep-линк — подготовительная задача (task_templates.is_prep_for_code)
    -- ссылается на задачу-окно той же фазы; её due_date = window_start окна (дедлайн = старт
    -- окна, §5.2). Second-pass UPDATE, т.к. parent_task_id — ссылка на sibling-строку внутри
    -- одного batch INSERT. Пока is_prep_for_code не засеян (ARS-172) — 0 строк, no-op.
    update public.farm_tasks prep
    set    parent_task_id = win.id,
           due_date       = win.window_start,
           updated_at     = now()
    from   public.task_templates tt_prep
    join   public.task_templates tt_win
           on tt_win.phase_template_id = tt_prep.phase_template_id
          and tt_win.code = tt_prep.is_prep_for_code
    join   public.farm_phases fp_win on fp_win.plan_id = v_plan_id
    join   public.farm_tasks  win
           on win.task_template_id = tt_win.id and win.farm_phase_id = fp_win.id
    where  prep.task_template_id      = tt_prep.id
      and  prep.farm_phase_id         = fp_win.id
      and  tt_prep.is_prep_for_code is not null
      and  win.window_start        is not null;

    -- ── 6. BATCH INSERT: все FarmKPI за один запрос ──────────
    -- D-NEW-4: Заменяет отдельный FOR loop KPI (M individual INSERTs → 1 batch INSERT).
    if p_target_heads is not null then
        v_kpi_target_heads := p_target_heads;
    else
        select coalesce(sum(hg.head_count), 1) into v_kpi_target_heads
        from   public.herd_groups hg
        where  hg.farm_id = p_farm_id and hg.is_active = true;
    end if;

    insert into public.farm_kpis (
        farm_phase_id, organization_id, kpi_template_id,
        target_value, unit, status
    )
    select
        fp.id,
        v_organization_id,
        kt.id,
        kt.target_value,
        kt.unit,
        'pending'
    from   public.farm_phases fp
    join   public.kpi_templates kt on kt.phase_template_id = fp.phase_template_id
    where  fp.plan_id = v_plan_id;

    get diagnostics v_kpis_created = row_count;

    -- ── 7. ОПУБЛИКОВАТЬ EVENT ─────────────────────────────────
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload
    ) values (
        'ops.production_plan.started', 'farm_production_plans', v_plan_id,
        v_organization_id, 'system', p_actor_id,
        jsonb_build_object(
            'plan_id',          v_plan_id,
            'farm_id',          p_farm_id,
            'template_id',      p_template_id,
            'template_code',    v_template.code,
            'cycle_start_date', p_plan_start_date,
            'cycle_end_date',   v_cycle_end_date,
            'phases_created',   v_phases_created,
            'tasks_created',    v_tasks_created,
            'kpis_created',     v_kpis_created
        )
    );

    return v_plan_id;
end;
$$;

comment on function public.fn_generate_production_plan(uuid,uuid,date,uuid,int,uuid[],uuid,text) is
    'D-NEW-4: Batch task/KPI INSERT rewrite. D74/L-1: Template → Plan generator.

     Performance vs migration 010 (row-by-row loops):
       Before: phases(N) + tasks(N×M) + kpis(K) sequential INSERTs.
       After:  phases(N) loop + 1 task batch INSERT + 1 KPI batch INSERT.
       cow_calf example: 10+50+15=75 INSERTs → 10+1+1=12 INSERTs.

     Phase loop remains row-by-row: sequential phases need predecessor end_date
     from _phase_code_map — inherently iterative, cannot be batched.

     Task/KPI batch uses JOIN farm_phases(plan_id) → task_templates/kpi_templates.
     Same data as before, same result — different execution strategy.

     Algorithm, data model, return value: unchanged from migration 010.
     See migration 010 comment for full algorithm documentation.';

-- ============================================================
-- PART 5: Register new RPCs in rpc_name_registry (migration 014)
-- ============================================================
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
-- SLICE 4: Operations RPCs
-- RPC-37: rpc_get_active_plan
-- ============================================================

-- ============================================================
-- RPC-37: rpc_get_active_plan
-- Dok 3 §7 | Callers: [WEB] [AI]
-- D-S4-3: Comprehensive jsonb — plan + phases + task/KPI summaries.
-- Serves F19 (Plan Overview), F21 (Timeline), F23 (KPI Dashboard).
-- ============================================================
create or replace function public.rpc_get_active_plan(
    p_organization_id   uuid,
    p_farm_id           uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_plan_id       uuid;
    v_plan          jsonb;
    v_phases        jsonb;
    v_tasks_summary jsonb;
    v_kpis_summary  jsonb;
begin
    -- Ownership check
    if not exists (
        select 1 from public.farms
        where id = p_farm_id and organization_id = p_organization_id and is_active = true
    ) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %',
            p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    -- Find active plan (D82: one active plan per farm)
    select id into v_plan_id
    from public.farm_production_plans
    where farm_id = p_farm_id
      and organization_id = p_organization_id
      and status = 'active'
    limit 1;

    if v_plan_id is null then
        -- No active plan — return null (UI shows empty state)
        return null;
    end if;

    -- Plan header with expert name and template name
    select jsonb_build_object(
        'id', fpp.id,
        'name', fpp.name,
        'status', fpp.status,
        'cycle_start_date', fpp.cycle_start_date,
        'cycle_end_date', fpp.cycle_end_date,
        'activated_at', fpp.activated_at,
        'expert_name', (
            select u.full_name
            from public.expert_profiles ep
            join public.users u on u.id = ep.user_id
            where ep.id = fpp.expert_profile_id
        ),
        'template_name', (
            select pct.name_ru
            from public.production_cycle_templates pct
            where pct.id = fpp.cycle_template_id
        )
    ) into v_plan
    from public.farm_production_plans fpp
    where fpp.id = v_plan_id;

    -- Phases with task counts and herd group info
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', fp.id,
            'name_ru', fp.name_ru,
            'herd_group_id', fp.herd_group_id,
            'herd_group_name', (
                select ac.name_ru
                from public.herd_groups hg
                join public.animal_categories ac on ac.id = hg.animal_category_id
                where hg.id = fp.herd_group_id
            ),
            'start_date', fp.start_date,
            'end_date', fp.end_date,
            'status', fp.status,
            'is_sale_phase', fp.is_sale_phase,
            'target_sale_month', fp.target_sale_month,
            'tasks_total', (
                select count(*) from public.farm_tasks ft
                where ft.farm_phase_id = fp.id
            ),
            'tasks_completed', (
                select count(*) from public.farm_tasks ft
                where ft.farm_phase_id = fp.id and ft.status = 'completed'
            ),
            'tasks_overdue', (
                select count(*) from public.farm_tasks ft
                where ft.farm_phase_id = fp.id and ft.status = 'overdue'
            )
        ) order by fp.start_date
    ), '[]'::jsonb) into v_phases
    from public.farm_phases fp
    where fp.plan_id = v_plan_id;

    -- Tasks summary (across all phases)
    select jsonb_build_object(
        'total', count(*),
        'completed', count(*) filter (where ft.status = 'completed'),
        'overdue', count(*) filter (where ft.status = 'overdue'),
        'upcoming_7d', count(*) filter (
            where ft.status in ('scheduled', 'reminded')
            and ft.due_date <= current_date + 7
        )
    ) into v_tasks_summary
    from public.farm_tasks ft
    join public.farm_phases fp on fp.id = ft.farm_phase_id
    where fp.plan_id = v_plan_id;

    -- KPIs summary (across all phases)
    select jsonb_build_object(
        'total', count(*),
        'achieved', count(*) filter (where fk.status = 'achieved'),
        'missed', count(*) filter (where fk.status = 'missed'),
        'pending', count(*) filter (where fk.status = 'pending')
    ) into v_kpis_summary
    from public.farm_kpis fk
    join public.farm_phases fp on fp.id = fk.farm_phase_id
    where fp.plan_id = v_plan_id;

    return jsonb_build_object(
        'plan', v_plan,
        'phases', v_phases,
        'tasks_summary', v_tasks_summary,
        'kpis_summary', v_kpis_summary
    );
end;
$$;

comment on function public.rpc_get_active_plan(uuid, uuid) is
    'RPC-37 | Dok 3 §7 | Slice 4
     D-S4-3: Comprehensive read — plan + phases (with task/KPI counts) + summaries.
     D82: One active plan per farm (partial unique index).
     Returns null if no active plan (UI shows empty state).
     STABLE read — no side effects.
     Serves: F19 (Plan Overview), F21 (Timeline), F23 (KPI Dashboard).';


-- ============================================================
-- SLICE 4: Add new RPC to rpc_name_registry
-- ============================================================
insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('rpc_get_active_plan', 'rpc_get_active_plan', null, 'd05_ops_edu.sql (Slice 4)', 'RPC-37: Active plan + phases + task/KPI summaries (D-S4-3)')
on conflict (sql_name) do update
    set dok3_name      = excluded.dok3_name,
        dok5_tool_name = excluded.dok5_tool_name,
        notes          = excluded.notes,
        created_in     = excluded.created_in;

-- ============================================================
-- END Slice 4 d05_ops_edu.sql RPCs
-- ============================================================



-- ============================================================
-- SLICE 6a: RPC-44 rpc_add_knowledge_chunk
-- Admin: add content to knowledge base for AI RAG.
-- ============================================================
drop function if exists public.rpc_add_knowledge_chunk(p_organization_id uuid, p_title text, p_content text, p_source_domain text, p_language text, p_metadata jsonb, p_source_url text, p_is_published boolean);
create or replace function public.rpc_add_knowledge_chunk(
    p_organization_id   uuid,
    p_title             text,
    p_content           text,
    p_source_domain     text        default 'faq',
    p_language          text        default 'ru',
    p_metadata          jsonb       default null,
    p_source_url        text        default null,
    p_is_published      boolean     default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_chunk_id uuid;
begin
    -- Admin check
    if not public.fn_is_admin() then
        raise exception 'FORBIDDEN: admin access required' using errcode = 'P0001';
    end if;

    if p_title is null or p_content is null then
        raise exception 'TITLE_AND_CONTENT_REQUIRED' using errcode = 'P0001';
    end if;

    insert into public.knowledge_chunks (
        source_domain, title, content, language,
        metadata, source_url, is_published
    ) values (
        p_source_domain, p_title, p_content, p_language,
        p_metadata, p_source_url, p_is_published
    )
    returning id into v_chunk_id;

    -- Emit event (embedding worker will pick this up)
    insert into public.platform_events (
        event_type, entity_type, entity_id, organization_id,
        actor_type, actor_id, payload, is_audit
    ) values (
        'platform.knowledge.chunk_added', 'knowledge_chunks', v_chunk_id, p_organization_id,
        'admin', public.fn_current_user_id(),
        jsonb_build_object('chunk_id', v_chunk_id, 'source_domain', p_source_domain, 'title', p_title),
        false
    );

    return v_chunk_id;
end;
$$;

comment on function public.rpc_add_knowledge_chunk(uuid, text, text, text, text, jsonb, text, boolean) is
    'RPC-44 | Dok 3 §9 | Slice 6a
     Admin: add knowledge chunk for AI RAG. Embedding processed async by worker.
     D70: All domains in one table. D71: is_published=false until expert review.';

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_add_knowledge_chunk', 'rpc_add_knowledge_chunk', null, 'd05_ops_edu.sql (Slice 6a)', 'RPC-44: Admin knowledge base CRUD')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;

-- ============================================================
-- SLICE 4 QA FIX: Register fn_* cascade RPCs in rpc_name_registry
-- These functions are called by UI via supabase.rpc() but lacked registry entries.
-- ============================================================
INSERT INTO public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
VALUES
('fn_shift_phase_cascade', 'RPC-35', null, 'd05_ops_edu.sql',
 'fn_* prefix by convention (trigger-style function). Called by UI as supabase.rpc(). Cascade shifts linked phases.'),
('fn_preview_cascade',     'RPC-36', null, 'd05_ops_edu.sql',
 'fn_* prefix by convention. Read-only preview of cascade shift. Returns table of affected phases.')
ON CONFLICT (sql_name) DO NOTHING;


-- ============================================================
-- SECTION: ARS-213 — мост archetype→farm_type (F-D11) +
--          генерация draft-ЦТК из профиля хозяйства (F-D13/F-D14)
-- ============================================================
-- Канон: Docs/AGOS-Farm-Module-FunctionalSpec-v0_1.md (F-D11/F-D12/F-D13/F-D14).
-- Движок ЦТК уже построен выше (fn_generate_production_plan, F-D9) —
-- здесь ТОЛЬКО мост словарей + порог + wiring. Всё аддитивно (P7):
-- существующие функции не тронуты.
--
-- Цепочка: профиль (herd_groups + farms.calving_system)
--   → fn_derive_farm_archetype (F-D14: вычисленный архетип, словарь activity_type)
--   → fn_activity_to_farm_type (F-D11: мост в словарь production_cycle_templates.farm_type)
--   → преселект активного recurring-шаблона
--   → rpc_start_production_plan (draft, self-service — F-D12).
-- ============================================================

-- -------------------------------------------------------
-- fn_activity_to_farm_type — мост F-D11
-- activity_type (farm_activity_types) → farm_type (production_cycle_templates)
-- -------------------------------------------------------
create or replace function public.fn_activity_to_farm_type(p_activity_type text)
returns text
language sql
immutable
as $$
    select case p_activity_type
        when 'cow_calf'  then 'cow_calf'
        when 'finishing' then 'finishing'
        when 'mixed'     then 'combined'   -- «полный цикл» (F-D11)
        when 'breeding'  then 'breeding'
        else null                          -- 'dairy' не применяется (F-D1); неизвестное → null
    end;
$$;

comment on function public.fn_activity_to_farm_type(text) is
    'F-D11 (ARS-213): канонический мост словарей archetype→farm_type.
     cow_calf→cow_calf, finishing→finishing, mixed→combined, breeding→breeding;
     dairy→null (продукт только для мясного КРС, F-D1). Единственное место маппинга (P4).';

-- -------------------------------------------------------
-- fn_derive_farm_archetype — вывод архетипа из состава стада (F-D14)
-- Возвращает словарь activity_type: cow_calf | finishing | mixed | null.
-- Маточное = COW + HEIFER_PREG (нетели отелятся — цикл отёла применим);
-- откормочные бычки = BULL_CALF + STEER.
-- -------------------------------------------------------
create or replace function public.fn_derive_farm_archetype(p_farm_id uuid)
returns text
language sql
stable
as $$
    with herd as (
        select
            coalesce(sum(hg.head_count) filter (where ac.code in ('COW', 'HEIFER_PREG')), 0) as breeding_stock,
            coalesce(sum(hg.head_count) filter (where ac.code in ('BULL_CALF', 'STEER')), 0) as feeder_bulls
        from public.herd_groups hg
        join public.animal_categories ac on ac.id = hg.animal_category_id
        where hg.farm_id  = p_farm_id
          and hg.is_active = true
    )
    select case
        when breeding_stock > 0 and feeder_bulls > 0 then 'mixed'
        when breeding_stock > 0                      then 'cow_calf'
        when feeder_bulls   > 0                      then 'finishing'
        else null
    end
    from herd;
$$;

comment on function public.fn_derive_farm_archetype(uuid) is
    'F-D14 (ARS-213): архетип НЕ спрашивается — вычисляется из состава стада:
     маточное>0 → cow_calf; только откормочные бычки → finishing; оба → mixed
     (словарь activity_type; в farm_type переводит fn_activity_to_farm_type, F-D11).
     Маточное = COW+HEIFER_PREG; бычки = BULL_CALF+STEER. null = состав не определяет архетип.';

-- -------------------------------------------------------
-- rpc_generate_plan_from_profile — генерация draft-ЦТК из профиля
-- Вызывается опросником (ARS-212) после блока «План» и AI Gateway.
-- Доменные состояния возвращает graceful jsonb (generated:false + reason),
-- НЕ ошибкой: ниже порога — профиль и Payoff-1 сохраняются (F-D14).
-- -------------------------------------------------------
create or replace function public.rpc_generate_plan_from_profile(
    p_organization_id       uuid,
    p_farm_id               uuid default null,   -- null → primary-ферма организации
    p_first_calving_month   int  default null,   -- 1–12, «месяц первого отёла» из опросника (сезонный отёл)
    p_actor_id              uuid default null    -- C-NEW-7: AI Gateway / service_role path
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id        uuid;
    v_farm            record;
    v_breeding_stock  int;
    v_total_heads     int;
    v_archetype       text;
    v_farm_type       text;
    v_template        record;
    v_month           int;
    v_start           date;
    v_existing        uuid;
    v_result          jsonb;
begin
    -- actor: JWT или явный p_actor_id (паттерн rpc_start_production_plan, C-NEW-7)
    v_actor_id := coalesce(p_actor_id, public.fn_current_user_id());
    if v_actor_id is null then
        raise exception 'UNAUTHORIZED: необходима аутентификация (JWT или p_actor_id)'
            using errcode = 'P0001';
    end if;

    if not exists (
        select 1
        from   public.user_organization_roles uor
        where  uor.organization_id = p_organization_id
          and  uor.user_id         = v_actor_id
    ) then
        raise exception 'FORBIDDEN: у пользователя % нет доступа к организации %',
            v_actor_id, p_organization_id
            using errcode = 'P0001';
    end if;

    if p_first_calving_month is not null
       and p_first_calving_month not between 1 and 12 then
        raise exception 'INVALID_MONTH: p_first_calving_month = % (ожидается 1–12)',
            p_first_calving_month
            using errcode = 'P0001';
    end if;

    -- ферма: явная или primary-ферма организации (org-фильтр = P-AI-2)
    select f.id, f.calving_system
    into   v_farm
    from   public.farms f
    where  f.organization_id = p_organization_id
      and  f.is_active = true
      and  (p_farm_id is null or f.id = p_farm_id)
    order by f.is_primary desc, f.created_at
    limit 1;

    if not found then
        return jsonb_build_object(
            'generated', false,
            'reason',    'FARM_NOT_FOUND',
            'message',   'Активная ферма организации не найдена');
    end if;

    -- уже есть draft/active план — graceful (D82, не ошибка для опросника)
    select fpp.id into v_existing
    from   public.farm_production_plans fpp
    where  fpp.farm_id = v_farm.id
      and  fpp.status in ('draft', 'active')
    limit 1;

    if found then
        return jsonb_build_object(
            'generated', false,
            'reason',    'PLAN_ALREADY_EXISTS',
            'plan_id',   v_existing,
            'message',   'У фермы уже есть черновой или активный план');
    end if;

    -- порог генерации (F-D14): маточное>0 + любой ответ про отёл.
    -- year_round / «по-разному» — НЕ блокер (план держится на слое-1, F-D6).
    select
        coalesce(sum(hg.head_count) filter (where ac.code in ('COW', 'HEIFER_PREG')), 0),
        coalesce(sum(hg.head_count), 0)
    into   v_breeding_stock, v_total_heads
    from   public.herd_groups hg
    join   public.animal_categories ac on ac.id = hg.animal_category_id
    where  hg.farm_id  = v_farm.id
      and  hg.is_active = true;

    if v_breeding_stock = 0 or v_farm.calving_system is null then
        return jsonb_build_object(
            'generated',          false,
            'reason',             'BELOW_THRESHOLD',
            'has_breeding_stock', v_breeding_stock > 0,
            'has_calving_answer', v_farm.calving_system is not null,
            'message',            'Порог генерации не достигнут (нужно маточное поголовье '
                                  'и ответ про отёл); профиль сохранён');
    end if;

    -- вычисленный архетип (F-D14) → мост в farm_type (F-D11)
    v_archetype := public.fn_derive_farm_archetype(v_farm.id);
    v_farm_type := public.fn_activity_to_farm_type(v_archetype);

    if v_farm_type is null then
        return jsonb_build_object(
            'generated', false,
            'reason',    'ARCHETYPE_NOT_APPLICABLE',
            'archetype', v_archetype,
            'message',   'Архетип не определён или не применим для ЦТК (F-D1)');
    end if;

    -- преселект шаблона: активный годовой (recurring) шаблон нужного farm_type.
    -- is_recurring=true отсекает разовый onboarding-чеклист (BEEF_FARM_LAUNCH_KZ, D102).
    select pct.id, pct.code
    into   v_template
    from   public.production_cycle_templates pct
    where  pct.farm_type    = v_farm_type
      and  pct.is_active    = true
      and  pct.is_recurring = true
      and  coalesce(pct.min_herd_size, 1) <= v_total_heads
    order by pct.sort_order, pct.created_at
    limit 1;

    if not found then
        return jsonb_build_object(
            'generated', false,
            'reason',    'NO_TEMPLATE',
            'farm_type', v_farm_type,
            'message',   'Нет активного шаблона ЦТК для типа хозяйства ' || v_farm_type);
    end if;

    -- якорь цикла (D78): cycle_start_date = дата первого отёла.
    -- Сезонный отёл → 1-е число месяца первого отёла (год: ближайшее вхождение,
    -- допустимое гардом INVALID_START_DATE движка — не старше 90 дней).
    -- year_round / «по-разному» → 1-е число текущего месяца: якоря отёла нет,
    -- план держится на слое-1 (сквозной вет-календарь) + сезонных работах (F-D14).
    if v_farm.calving_system in ('spring', 'autumn', 'two_season') then
        v_month := coalesce(
            p_first_calving_month,
            case when v_farm.calving_system = 'autumn' then 9 else 3 end);
        v_start := make_date(extract(year from current_date)::int, v_month, 1);
        if v_start < (current_date - interval '90 days')::date then
            v_start := make_date(extract(year from current_date)::int + 1, v_month, 1);
        end if;
    else
        v_start := date_trunc('month', current_date)::date;
    end if;

    -- self-service draft (F-D12): делегируем существующему RPC (zero duplication)
    v_result := public.rpc_start_production_plan(
        p_farm_id         => v_farm.id,
        p_template_id     => v_template.id,
        p_plan_start_date => v_start,
        p_actor_id        => v_actor_id
    );

    if coalesce(v_result ->> 'error', 'false')::boolean then
        return v_result || jsonb_build_object('generated', false);
    end if;

    return v_result || jsonb_build_object(
        'generated',        true,
        'archetype',        v_archetype,
        'farm_type',        v_farm_type,
        'template_code',    v_template.code,
        'cycle_start_date', v_start
    );

exception
    when others then
        return jsonb_build_object(
            'error',     true,
            'generated', false,
            'code',      sqlstate,
            'message',   sqlerrm
        );
end;
$$;

comment on function public.rpc_generate_plan_from_profile(uuid, uuid, int, uuid) is
    'RPC-33a (ARS-213): генерация draft-ЦТК из профиля хозяйства.
     Порог (F-D14): маточное>0 + calving_system задан (year_round — легальный путь).
     Архетип вычисляется из состава стада (fn_derive_farm_archetype, F-D14),
     мост в farm_type — fn_activity_to_farm_type (F-D11), преселект активного
     recurring-шаблона, якорь cycle_start_date = месяц первого отёла (D78).
     Делегирует в rpc_start_production_plan (RPC-33) → draft, self-service (F-D12).
     Доменные исходы — graceful jsonb {generated:false, reason}, не ошибка:
     ниже порога профиль и Payoff-1 сохраняются. Вызывают: опросник ARS-212, AI Gateway.';

grant execute on function public.rpc_generate_plan_from_profile(uuid, uuid, int, uuid) to authenticated;
revoke execute on function public.rpc_generate_plan_from_profile(uuid, uuid, int, uuid) from anon;
revoke execute on function public.fn_derive_farm_archetype(uuid) from anon;
revoke execute on function public.fn_activity_to_farm_type(text) from anon;

insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes)
values ('rpc_generate_plan_from_profile', 'RPC-33a', null, 'd05_ops_edu.sql (ARS-213)',
        'F-D11/F-D14: мост archetype→farm_type + порог генерации + draft-ЦТК из профиля. '
        'Делегирует в rpc_start_production_plan (RPC-33).')
on conflict (sql_name) do update set notes = excluded.notes, created_in = excluded.created_in;


-- ============================================================================
-- SECTION: ARS-279 — Ферма 2.0 · F3 DB (задачи/окна/цикл)
-- Канон: Docs/AGOS-Ferma2-OpsCabinet-EngSpec-v0_1.md §1.5-1.6, §2 (2.7-2.11,2.14), §7.
-- Аддитивная дельта (P7): движок ЦТК (fn_generate_production_plan / fn_shift_phase_cascade /
-- fn_preview_cascade / rpc_get_active_plan) НЕ перестраивается. Зависит от F2/ARS-278
-- (animals/animal_events в d01) — apply order d01→…→d05.
-- ============================================================================

-- ---- §1.5  farm_tasks — window-семантика + связи (D141) --------------------
alter table public.farm_tasks
    add column if not exists window_start       date,
    add column if not exists window_end         date,
    add column if not exists head_count_planned int  check (head_count_planned > 0),
    add column if not exists head_count_done    int  not null default 0 check (head_count_done >= 0),
    add column if not exists parent_task_id     uuid references public.farm_tasks(id),
    add column if not exists animal_event_id    uuid references public.animal_events(id),
    add column if not exists assigned_to        uuid references public.users(id),
    add column if not exists due_time           time,
    add column if not exists client_task_id     uuid;

alter table public.farm_tasks drop constraint if exists farm_tasks_window_pair_check;
alter table public.farm_tasks add constraint farm_tasks_window_pair_check
    check ( (window_start is null) = (window_end is null)
            and (window_end is null or window_end >= window_start) );
-- Инвариант: у задачи-окна due_date = window_end (закрытие окна) — существующие
-- due_soon/overdue кроны и FSM работают без изменений.
alter table public.farm_tasks drop constraint if exists farm_tasks_window_due_check;
alter table public.farm_tasks add constraint farm_tasks_window_due_check
    check ( window_end is null or due_date = window_end );
create index if not exists idx_farm_tasks_window on public.farm_tasks (window_end)
    where window_start is not null and status not in ('completed','skipped');
create index if not exists idx_farm_tasks_event  on public.farm_tasks (animal_event_id) where animal_event_id is not null;
create unique index if not exists uq_farm_tasks_client
    on public.farm_tasks (client_task_id) where client_task_id is not null;

comment on column public.farm_tasks.window_start is
    'D141 (ARS-279): задача-окно = массовая задача над группой с диапазоном дат. Источник —
     derived (P4): task_template_id → cycle · animal_event_id → deviation · оба null → manual.';

-- ---- §1.6  task_templates — окно в шаблоне (контент — ARS-172) --------------
alter table public.task_templates
    add column if not exists window_duration_days int check (window_duration_days > 0),
    add column if not exists is_prep_for_code     text;
comment on column public.task_templates.window_duration_days is
    'D141 (ARS-279): not null → генератор создаёт задачу-окно (window_start/end, head_count_planned).
     is_prep_for_code → подготовительная задача с parent_task_id + due_date = window_start окна.';

-- ---- §7  fn_feed_days_left — дни запаса (D143), внутренняя (экспозиция 2.12/F12) ----
create or replace function public.fn_feed_days_left(
    p_farm_id        uuid,
    p_today          date default current_date,
    p_threshold_days int  default 14
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_today     date := coalesce(p_today, current_date);
    v_threshold int  := coalesce(p_threshold_days, 14);
    v_season    text;
    v_farm_type text;
    v_result    jsonb;
begin
    -- Сезон v1: маппинг месяца (константа, override-кандидат P8 §7)
    v_season := case
        when extract(month from v_today) in (11,12,1,2,3) then 'winter'
        when extract(month from v_today) in (6,7,8,9)     then 'summer'
        else 'transition'
    end;
    -- ⚠️ КОНФЛИКТ (flagged, IMPL_DEBT FEED-VOCAB-01): fn_activity_to_farm_type даёт словарь
    -- cow_calf/finishing/combined/breeding, а feed_consumption_norms.farm_type =
    -- beef_reproducer/feedlot/sheep_goat. Прямой маппинг архетип→норм-словарь (v1, до решения CEO).
    v_farm_type := case public.fn_derive_farm_archetype(p_farm_id)
        when 'cow_calf'  then 'beef_reproducer'
        when 'mixed'     then 'beef_reproducer'
        when 'finishing' then 'feedlot'
        else null
    end;

    with groups as (
        select hg.id, hg.animal_category_id, coalesce(hg.head_count,0) as head_count
        from public.herd_groups hg
        where hg.farm_id = p_farm_id and hg.is_active and coalesce(hg.head_count,0) > 0
    ),
    -- Priority 1: активный рацион группы → текущая версия → items[].quantity_kg_per_day
    p1 as (
        select g.id as group_id, g.head_count,
               (it->>'feed_item_id')::uuid           as feed_item_id,
               (it->>'quantity_kg_per_day')::numeric as kg_per_day
        from   groups g
        join   public.rations r
               on r.herd_group_id = g.id and r.status = 'active' and r.farm_id = p_farm_id
        join   public.ration_versions rv on rv.ration_id = r.id and rv.is_current
        cross  join lateral jsonb_array_elements(rv.items) as it
        where  (it ? 'feed_item_id') and (it ? 'quantity_kg_per_day')
    ),
    p1_groups as (select distinct group_id from p1),
    -- Priority 2: нормы (для групп БЕЗ активного рациона) → items[].kg_per_day
    p2 as (
        select g.id as group_id, g.head_count,
               (it->>'feed_item_id')::uuid as feed_item_id,
               (it->>'kg_per_day')::numeric as kg_per_day
        from   groups g
        join   public.feed_consumption_norms fcn
               on fcn.farm_type = v_farm_type
              and fcn.animal_category_id = g.animal_category_id
              and fcn.season = v_season
              and fcn.valid_from <= v_today
              and (fcn.valid_to is null or fcn.valid_to >= v_today)
        cross  join lateral jsonb_array_elements(fcn.items) as it
        where  v_farm_type is not null
          and  g.id not in (select group_id from p1_groups)
          and  (it ? 'feed_item_id') and (it ? 'kg_per_day')
    ),
    combined as (
        select feed_item_id, sum(kg_per_day * head_count) as daily_kg
        from ( select feed_item_id, kg_per_day, head_count from p1
               union all
               select feed_item_id, kg_per_day, head_count from p2 ) u
        where feed_item_id is not null
        group by feed_item_id
        having sum(kg_per_day * head_count) > 0
    ),
    days as (
        select fi.feed_item_id, fitem.code as feed_code, fitem.name_ru as feed_name,
               floor(fi.quantity_kg / c.daily_kg)::int as days_left
        from   public.farm_feed_inventory fi
        join   combined c on c.feed_item_id = fi.feed_item_id
        join   public.feed_items fitem on fitem.id = fi.feed_item_id
        where  fi.farm_id = p_farm_id
    )
    select jsonb_build_object(
        'tracked', (exists(select 1 from public.farm_feed_inventory where farm_id = p_farm_id)
                    and exists(select 1 from combined)),
        'min_days_left', (select min(days_left) from days),
        'signals', coalesce((select jsonb_agg(jsonb_build_object(
                        'feed_item_id', d.feed_item_id, 'feed', d.feed_name, 'feed_code', d.feed_code,
                        'days_left', d.days_left, 'buy', (d.days_left < v_threshold)
                    ) order by d.days_left asc) from days d), '[]'::jsonb),
        'threshold_days', v_threshold,
        'season', v_season
    ) into v_result;
    return v_result;
end;
$$;
-- Внутренняя (зовётся только definer-RPC 2.7/2.12 как owner) — authenticated НЕ должен звать
-- напрямую: у fn нет org-guard, прямой вызов = межорг-утечка сигналов кормов (advisor SEC).
-- Supabase default-privileges грантит execute authenticated на новые fn → снимаем явно.
revoke execute on function public.fn_feed_days_left(uuid, date, int) from public, anon, authenticated;
comment on function public.fn_feed_days_left(uuid, date, int) is
    'D143 (ARS-279): дни запаса = quantity_kg ÷ плановый суточный расход. Priority 1 активный
     рацион → Priority 2 feed_consumption_norms → Priority 3 НЕТ (группа без базы не считается).
     Внутренняя; зовётся 2.7 (зона Ресурсы) и 2.12/F12. FEED-VOCAB-01: маппинг farm_type flagged.';

-- ---- 2.7  rpc_get_farm_overview — весь экран «Обзор» одним вызовом ----------
create or replace function public.rpc_get_farm_overview(
    p_organization_id uuid,
    p_farm_id         uuid,
    p_today           date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_today   date := coalesce(p_today, current_date);
    v_plan    record;
    v_phase   record;
    v_result  jsonb;
    v_feed    jsonb;
    v_cycle   jsonb;
begin
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin() or public.fn_is_expert()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.farms f
                   where f.id = p_farm_id and f.organization_id = p_organization_id and f.is_active) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %', p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    -- Активный план + текущая фаза
    select fpp.* into v_plan
    from public.farm_production_plans fpp
    where fpp.farm_id = p_farm_id and fpp.organization_id = p_organization_id and fpp.status = 'active'
    limit 1;

    if v_plan.id is not null then
        select fp.* into v_phase
        from public.farm_phases fp
        where fp.plan_id = v_plan.id and fp.status <> 'skipped'
          and v_today between fp.start_date and fp.end_date
        order by fp.start_date limit 1;
        if v_phase.id is null then  -- между фазами — берём ближайшую будущую/активную
            select fp.* into v_phase from public.farm_phases fp
            where fp.plan_id = v_plan.id and fp.status not in ('completed','skipped')
            order by fp.start_date limit 1;
        end if;

        v_cycle := jsonb_build_object(
            'plan_id', v_plan.id, 'no_plan', false, 'draft_plan_id', null,
            'phase_name', v_phase.name_ru,
            'day', case when v_phase.id is not null then (v_today - v_phase.start_date) + 1 end,
            'days_total', case when v_phase.id is not null then (v_phase.end_date - v_phase.start_date) + 1 end,
            'next_window', (
                select jsonb_build_object('task_id', ft.id, 'name', ft.name_ru,
                            'ends_in_days', (ft.window_end - v_today),
                            'burning', (ft.window_end - v_today) <= 2)
                from public.farm_tasks ft
                join public.farm_phases fp2 on fp2.id = ft.farm_phase_id
                where fp2.plan_id = v_plan.id and ft.window_start is not null
                  and ft.status not in ('completed','skipped') and ft.window_end >= v_today
                order by ft.window_end asc limit 1
            )
        );
    else
        v_cycle := jsonb_build_object(
            'plan_id', null, 'no_plan', true, 'phase_name', null, 'day', null, 'days_total', null,
            'next_window', null,
            'draft_plan_id', (select id from public.farm_production_plans
                              where farm_id = p_farm_id and organization_id = p_organization_id
                                and status = 'draft' order by created_at desc limit 1)
        );
    end if;

    v_feed := public.fn_feed_days_left(p_farm_id, v_today);

    select jsonb_build_object(
        'as_of', now(),
        'herd', jsonb_build_object(
            'total', coalesce((select sum(head_count) from public.herd_groups where farm_id = p_farm_id and is_active),0),
            'walkthrough_marked', exists(select 1 from public.farm_walkthroughs where farm_id = p_farm_id and walk_date = v_today),
            'marked_at', (select marked_at from public.farm_walkthroughs where farm_id = p_farm_id and walk_date = v_today limit 1),
            'groups_count', (select count(*) from public.herd_groups where farm_id = p_farm_id and is_active)
        ),
        'cycle', v_cycle,
        'tasks', (
            select jsonb_build_object(
                'today_total', count(*) filter (where ft.due_date = v_today and ft.status <> 'skipped'),
                'today_done',  count(*) filter (where ft.due_date = v_today and ft.status = 'completed'),
                'overdue',     count(*) filter (where ft.due_date < v_today and ft.status not in ('completed','skipped'))
            )
            from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
            where fp.plan_id = coalesce(v_plan.id, '00000000-0000-0000-0000-000000000000'::uuid)
        ),
        'resources', jsonb_build_object(
            'tracked', (v_feed->>'tracked')::boolean,
            'min_days_left', (v_feed->'min_days_left'),
            'signals', (v_feed->'signals')
        ),
        'attention', public._fn_farm_attention(p_farm_id, v_plan.id, v_today, v_feed),
        'today', coalesce((
            select jsonb_agg(t order by t_due, t_time nulls last) from (
                select jsonb_build_object('task_id', ft.id, 'name', ft.name_ru, 'status', ft.status,
                            'category', ft.category, 'due_date', ft.due_date, 'due_time', ft.due_time,
                            'source', case when ft.task_template_id is not null then 'cycle'
                                           when ft.animal_event_id is not null then 'deviation' else 'manual' end,
                            'window_end', ft.window_end, 'heads', ft.head_count_planned) as t,
                       ft.due_date as t_due, ft.due_time as t_time
                from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                where fp.plan_id = coalesce(v_plan.id, '00000000-0000-0000-0000-000000000000'::uuid)
                  and ft.status not in ('completed','skipped') and ft.due_date >= v_today
                order by ft.due_date asc, ft.due_time asc nulls last limit 3
            ) sub), '[]'::jsonb),
        'today_more_count', greatest(0, coalesce((
            select count(*) from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
            where fp.plan_id = coalesce(v_plan.id, '00000000-0000-0000-0000-000000000000'::uuid)
              and ft.status not in ('completed','skipped') and ft.due_date >= v_today),0) - 3)
    ) into v_result;

    return v_result;
end;
$$;
grant execute on function public.rpc_get_farm_overview(uuid, uuid, date) to authenticated;
revoke execute on function public.rpc_get_farm_overview(uuid, uuid, date) from public, anon;
comment on function public.rpc_get_farm_overview(uuid, uuid, date) is
    'ARS-279 §2.7: агрегат экрана «Обзор» = кэш-юнит офлайна (D145). Зоны herd/cycle/tasks/
     resources + «Требует внимания» (приоритет §2.6: животное→окно→просрочка→корма) + 3 ближайшие.';

-- ---- attention-хелпер (§2.6 приоритеты, sort на сервере) --------------------
create or replace function public._fn_farm_attention(
    p_farm_id uuid, p_plan_id uuid, p_today date, p_feed jsonb
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    with items as (
        -- (1) угроза животному: открытые animal_events
        select 1 as priority, 'animal' as kind,
               ('№' || a.tag_number || ' — ' || aet.name_ru) as title,
               to_char(ae.occurred_at, 'DD.MM') as subtitle,
               jsonb_build_object('type','open_animal','ref_id', ae.animal_id) as action,
               ae.occurred_at as ord
        from public.animal_events ae
        join public.animals a on a.id = ae.animal_id
        join public.animal_event_types aet on aet.id = ae.event_type_id
        where ae.farm_id = p_farm_id and ae.status = 'open'
        union all
        -- (2) окно: закрылось с остатком ИЛИ горит (≤2 дн до закрытия)
        select 2, 'window', ft.name_ru,
               case when ft.window_end < p_today
                    then ('окно закрыто · ' || ft.head_count_done || '/' || coalesce(ft.head_count_planned,0) || ' голов')
                    else ('закрытие через ' || (ft.window_end - p_today) || ' дн') end,
               jsonb_build_object('type','open_window','ref_id', ft.id),
               ft.window_end::timestamptz
        from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
        where fp.plan_id = p_plan_id and ft.window_start is not null
          and ft.status not in ('completed','skipped')
          and ( (ft.window_end < p_today and ft.head_count_done < coalesce(ft.head_count_planned,0))
                or (ft.window_end - p_today between 0 and 2) )
        union all
        -- (3) просрочка: обычные задачи (не окна) с истёкшим сроком
        select 3, 'task', ft.name_ru,
               ('просрочено ' || (p_today - ft.due_date) || ' дн'),
               jsonb_build_object('type','reschedule_today','ref_id', ft.id),
               ft.due_date::timestamptz
        from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
        where fp.plan_id = p_plan_id and ft.window_start is null
          and ft.status not in ('completed','skipped') and ft.due_date < p_today
        union all
        -- (4) ресурсы: сигналы кормов buy=true
        select 4, 'feed', (s->>'feed'),
               ('осталось ' || (s->>'days_left') || ' дн'),
               jsonb_build_object('type','open_resources','ref_id', (s->>'feed_item_id')),
               p_today::timestamptz
        from jsonb_array_elements(coalesce(p_feed->'signals','[]'::jsonb)) s
        where (s->>'buy')::boolean is true
    )
    select coalesce(jsonb_agg(jsonb_build_object(
                'kind', kind, 'priority', priority, 'title', title,
                'subtitle', subtitle, 'action', action
           ) order by priority asc, ord asc), '[]'::jsonb)
    from items;
$$;
-- Внутренняя (зовётся только rpc_get_farm_overview как owner) — у fn нет org-guard,
-- прямой authenticated-вызов = межорг-утечка (открытые события/просрочки чужой фермы). Advisor SEC.
revoke execute on function public._fn_farm_attention(uuid, uuid, date, jsonb) from public, anon, authenticated;

-- ---- 2.8  rpc_get_tasks_horizon — Неделя / Месяц / Год ----------------------
create or replace function public.rpc_get_tasks_horizon(
    p_organization_id uuid,
    p_farm_id         uuid,
    p_horizon         text,
    p_anchor          date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_anchor date := coalesce(p_anchor, current_date);
    v_plan   record;
    v_phase  record;
    v_result jsonb;
    v_from   date;
    v_to     date;
begin
    if p_horizon is null or p_horizon not in ('week','month','year') then
        return jsonb_build_object('ok', false, 'reason', 'BAD_HORIZON');
    end if;
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin() or public.fn_is_expert()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.farms f
                   where f.id = p_farm_id and f.organization_id = p_organization_id and f.is_active) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %', p_farm_id, p_organization_id using errcode = 'P0001';
    end if;

    select fpp.* into v_plan from public.farm_production_plans fpp
    where fpp.farm_id = p_farm_id and fpp.organization_id = p_organization_id and fpp.status = 'active'
    limit 1;
    if v_plan.id is null then
        return jsonb_build_object('ok', true, 'no_plan', true, 'horizon', p_horizon);
    end if;

    if p_horizon = 'week' then
        v_from := date_trunc('week', v_anchor)::date;      -- понедельник
        v_to   := v_from + 6;
        select fp.* into v_phase from public.farm_phases fp
        where fp.plan_id = v_plan.id and fp.status <> 'skipped'
          and v_anchor between fp.start_date and fp.end_date order by fp.start_date limit 1;

        v_result := jsonb_build_object(
            'ok', true, 'horizon', 'week', 'no_plan', false,
            'range', jsonb_build_object('from', v_from, 'to', v_to),
            'context', case when v_phase.id is not null then jsonb_build_object(
                'phase_name', v_phase.name_ru, 'day', (v_anchor - v_phase.start_date) + 1,
                'days_total', (v_phase.end_date - v_phase.start_date) + 1) end,
            -- «горит» непролистываем: просрочки + окна ≤2 дн
            -- heads/ref_date (ARS-282): Slice8 §3.1 копирайт «план был Х · N голов» / «осталось N дн · M голов».
            'burning', coalesce((
                select jsonb_agg(jsonb_build_object('kind', b.kind, 'task_id', b.id, 'name', b.name_ru,
                            'sub', b.sub, 'action', b.action, 'heads', b.heads, 'ref_date', b.ord) order by b.ord)
                from (
                    select 'overdue' as kind, ft.id, ft.name_ru,
                           ('просрочено ' || (v_anchor - ft.due_date) || ' дн') as sub,
                           jsonb_build_object('type','reschedule_today','ref_id',ft.id) as action,
                           ft.due_date as ord, ft.head_count_planned as heads
                    from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                    where fp.plan_id = v_plan.id and ft.window_start is null
                      and ft.status not in ('completed','skipped') and ft.due_date < v_anchor
                    union all
                    select 'window', ft.id, ft.name_ru,
                           ('закрытие через ' || (ft.window_end - v_anchor) || ' дн'),
                           jsonb_build_object('type','open_window','ref_id',ft.id),
                           ft.window_end, ft.head_count_planned
                    from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                    where fp.plan_id = v_plan.id and ft.window_start is not null
                      and ft.status not in ('completed','skipped') and (ft.window_end - v_anchor between 0 and 2)
                ) b), '[]'::jsonb),
            'days', (
                select jsonb_agg(jsonb_build_object(
                    -- ARS-284 bugfix: generate_series(date,date,interval) возвращает timestamp,
                    -- не date — без каста jsonb сериализовал полный ISO-таймстамп ("...T00:00:00+00:00"),
                    -- фронт (parseD: `d + 'T00:00:00'`) склеивал два таймстампа → Invalid Date → NaN
                    -- по всей неделе (обнаружено живым QA ARS-284, баг существовал с F6/ARS-282).
                    'd', d.day::date,
                    'load', (select count(*) from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                             where fp.plan_id = v_plan.id and ft.due_date = d.day and ft.status <> 'skipped'),
                    'has_overdue', exists(select 1 from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                             where fp.plan_id = v_plan.id and ft.due_date = d.day and ft.due_date < v_anchor
                               and ft.status not in ('completed','skipped')),
                    'tasks', coalesce((
                        select jsonb_agg(jsonb_build_object('id', ft.id, 'name', ft.name_ru, 'status', ft.status,
                                    'category', ft.category, 'heads', ft.head_count_planned, 'due_time', ft.due_time,
                                    'assigned_to', ft.assigned_to, 'assigned_to_name', u.full_name, 'window_end', ft.window_end,
                                    'sop_code', (
                                        select sd.code from public.task_template_sops tts
                                        join public.sop_documents sd on sd.id = tts.sop_document_id
                                        where tts.task_template_id = ft.task_template_id
                                        order by (tts.relation_type = 'required') desc, sd.code
                                        limit 1
                                    ),
                                    'source', case when ft.task_template_id is not null then 'cycle'
                                                   when ft.animal_event_id is not null then 'deviation' else 'manual' end)
                                order by ft.due_time asc nulls last)
                        from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                        left join public.users u on u.id = ft.assigned_to
                        where fp.plan_id = v_plan.id and ft.due_date = d.day), '[]'::jsonb)
                ) order by d.day)
                from generate_series(v_from, v_to, interval '1 day') as d(day)
            )
        );

    elsif p_horizon = 'month' then
        v_from := date_trunc('month', v_anchor)::date;
        v_to   := (date_trunc('month', v_anchor) + interval '1 month - 1 day')::date;
        v_result := jsonb_build_object(
            'ok', true, 'horizon', 'month', 'no_plan', false,
            'range', jsonb_build_object('from', v_from, 'to', v_to),
            'grid', (
                select jsonb_agg(jsonb_build_object(
                    -- ARS-284 bugfix: generate_series(date,date,interval) возвращает timestamp,
                    -- не date — без каста jsonb сериализовал полный ISO-таймстамп ("...T00:00:00+00:00"),
                    -- фронт (parseD: `d + 'T00:00:00'`) склеивал два таймстампа → Invalid Date → NaN
                    -- по всей неделе (обнаружено живым QA ARS-284, баг существовал с F6/ARS-282).
                    'd', d.day::date,
                    'load', (select count(*) from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                             where fp.plan_id = v_plan.id and ft.due_date = d.day and ft.status <> 'skipped'),
                    'has_overdue', exists(select 1 from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                             where fp.plan_id = v_plan.id and ft.due_date = d.day and ft.due_date < v_anchor
                               and ft.status not in ('completed','skipped')),
                    'window_ids', coalesce((select jsonb_agg(ft.id)
                             from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                             where fp.plan_id = v_plan.id and ft.window_start is not null
                               and d.day between ft.window_start and ft.window_end), '[]'::jsonb)
                ) order by d.day)
                from generate_series(v_from, v_to, interval '1 day') as d(day)
            ),
            -- окна: ops (задачи-окна) + vet (vaccination_plan_items) замержены по датам (D75)
            'windows', (
                select coalesce(jsonb_agg(w order by w_start), '[]'::jsonb) from (
                    select jsonb_build_object('id', ft.id, 'source', 'ops', 'name', ft.name_ru,
                                'date_start', ft.window_start, 'date_end', ft.window_end,
                                'heads_planned', ft.head_count_planned, 'heads_done', ft.head_count_done) as w,
                           ft.window_start as w_start
                    from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                    where fp.plan_id = v_plan.id and ft.window_start is not null
                      and daterange(ft.window_start, ft.window_end, '[]') && daterange(v_from, v_to, '[]')
                    union all
                    select jsonb_build_object('id', vpi.id, 'source', 'vet', 'name', vp2.name_ru,
                                'date_start', vpi.scheduled_date, 'date_end', vpi.scheduled_date,
                                'heads_planned', vpi.head_count_planned, 'heads_done', null),
                           vpi.scheduled_date
                    from public.vaccination_plan_items vpi
                    join public.vaccination_plans vp on vp.id = vpi.vaccination_plan_id
                    left join public.vaccination_protocols vp2 on vp2.id = vpi.vaccination_protocol_id
                    where vp.farm_id = p_farm_id and vpi.scheduled_date between v_from and v_to
                      and vpi.status not in ('completed','skipped')
                ) merged
            ),
            'prep', coalesce((
                select jsonb_agg(jsonb_build_object('task_id', ft.id, 'name', ft.name_ru,
                            'deadline', ft.due_date, 'days_left', (ft.due_date - v_anchor), 'window_ref', ft.parent_task_id)
                        order by ft.due_date)
                from public.farm_tasks ft join public.farm_phases fp on fp.id = ft.farm_phase_id
                where fp.plan_id = v_plan.id and ft.parent_task_id is not null
                  and ft.status not in ('completed','skipped') and ft.due_date between v_from and v_to), '[]'::jsonb),
            -- вехи derived (D146): границы фаз, попадающие в месяц
            'milestones', coalesce((
                select jsonb_agg(jsonb_build_object('phase_id', fp.id, 'name', fp.name_ru,
                            'date', fp.start_date, 'kind', 'phase_start') order by fp.start_date)
                from public.farm_phases fp
                where fp.plan_id = v_plan.id and fp.status <> 'skipped' and fp.start_date between v_from and v_to), '[]'::jsonb)
        );

    else  -- year
        v_result := jsonb_build_object(
            'ok', true, 'horizon', 'year', 'no_plan', false,
            'plan', jsonb_build_object('id', v_plan.id, 'name', v_plan.name,
                        'cycle_start', v_plan.cycle_start_date, 'cycle_end', v_plan.cycle_end_date),
            'phases', coalesce((
                select jsonb_agg(jsonb_build_object('id', fp.id, 'name_ru', fp.name_ru,
                            'start_date', fp.start_date, 'end_date', fp.end_date, 'status', fp.status,
                            'day', case when v_anchor between fp.start_date and fp.end_date then (v_anchor - fp.start_date)+1 end,
                            'days_total', (fp.end_date - fp.start_date)+1,
                            'progress_pct', case when v_anchor >= fp.end_date then 100
                                                 when v_anchor <= fp.start_date then 0
                                                 else round(100.0 * (v_anchor - fp.start_date) / nullif(fp.end_date - fp.start_date,0)) end,
                            -- ARS-284 §3.3: "ближайшие вехи фазы" — только у активной (карточка), не у всех
                            -- (payload бы разросся на весь год). Источник — те же farm_tasks.window_start,
                            -- что у Месяца (§2.8 windows), но по фазе, не по календарю.
                            'milestones', case when v_anchor between fp.start_date and fp.end_date then coalesce((
                                select jsonb_agg(jsonb_build_object('date', m.window_start, 'name', m.name_ru) order by m.window_start)
                                from (
                                    select ft.window_start, ft.name_ru
                                    from public.farm_tasks ft
                                    where ft.farm_phase_id = fp.id and ft.window_start is not null
                                      and ft.status not in ('completed','skipped') and ft.window_start >= v_anchor
                                    order by ft.window_start limit 3
                                ) m), '[]'::jsonb) else '[]'::jsonb end,
                            -- ARS-284 §3.3: аннотация будущих фаз ("ожидается ~N голов") — herd_group
                            -- фазы, если эксперт его назначил (§1.5 automatch); NULL → фронт не рисует
                            -- аннотацию (D143: без данных — честное отсутствие, не выдуманное число).
                            'expected_heads', (select hg.head_count from public.herd_groups hg where hg.id = fp.herd_group_id)
                            ) order by fp.start_date)
                from public.farm_phases fp where fp.plan_id = v_plan.id), '[]'::jsonb),
            'breeding', (
                select jsonb_build_object('phase_id', fp.id, 'start_date', fp.start_date, 'editable', true)
                from public.farm_phases fp
                join public.phase_templates pt on pt.id = fp.phase_template_id
                where fp.plan_id = v_plan.id and pt.code = 'BREEDING' and fp.status not in ('completed','skipped')
                order by fp.start_date limit 1
            )
        );
    end if;

    return v_result;
end;
$$;
grant execute on function public.rpc_get_tasks_horizon(uuid, uuid, text, date) to authenticated;
revoke execute on function public.rpc_get_tasks_horizon(uuid, uuid, text, date) from public, anon;
comment on function public.rpc_get_tasks_horizon(uuid, uuid, text, date) is
    'ARS-279 §2.8: Неделя/Месяц/Год по p_horizon. Кэш-юнит = (horizon, anchor). Месяц мержит
     вет-окна (vaccination_plan_items) по датам (D75); вехи derived (D146). ARS-282
     (OPERATIONS-06, D-RPC-CONTRACT-SYNC-01, CEO 2026-07-21): week-ветка аддитивно несёт
     assigned_to_name (join users), sop_code (join task_template_sops→sop_documents, required
     приоритетнее reference) и heads/ref_date в burning[] — доводит RPC до контракта §2.5/§2.3,
     который F3 не заполнял. ARS-284 (D-RPC-CONTRACT-SYNC-01): year-ветка аддитивно несёт
     phases[].milestones (реальные ближайшие вехи активной фазы — было захардкожено ''[]'') и
     phases[].expected_heads (herd_group.head_count фазы, NULL если группа не назначена) —
     доводит до контракта Slice8 §3.3. Тем же ARS-284 закрыт баг F6: week/month `d.day` из
     generate_series кастуется в ::date (был timestamp → NaN на фронте, живёт с ARS-282).';

-- ---- 2.9  rpc_shift_breeding_start — фермерская обёртка D104 (D144) ---------
create or replace function public.rpc_shift_breeding_start(
    p_organization_id uuid,
    p_farm_id         uuid,
    p_new_start_date  date,
    p_actor_id        uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_plan_id     uuid;
    v_phase       record;
    v_old_start   date;
    v_delta       int;
    v_cascade     jsonb;
    v_phase_ids   uuid[];
    v_tasks_cnt   int := 0;
begin
    -- (1) ownership-guard org→farm→active plan (у fn_shift_phase_cascade guard'а НЕТ)
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id using errcode = 'P0001';
    end if;
    select fpp.id into v_plan_id from public.farm_production_plans fpp
    where fpp.farm_id = p_farm_id and fpp.organization_id = p_organization_id and fpp.status = 'active' limit 1;
    if v_plan_id is null then
        return jsonb_build_object('ok', false, 'reason', 'NO_ACTIVE_PLAN');
    end if;

    -- (2) фаза случки активного плана (phase_templates.code = 'BREEDING', сверено с seed L-7)
    select fp.* into v_phase
    from public.farm_phases fp
    join public.phase_templates pt on pt.id = fp.phase_template_id
    where fp.plan_id = v_plan_id and pt.code = 'BREEDING' and fp.status not in ('completed','skipped')
    order by fp.start_date limit 1;
    if v_phase.id is null then
        return jsonb_build_object('ok', false, 'reason', 'NO_BREEDING_PHASE');
    end if;

    v_old_start := v_phase.start_date;
    v_delta     := p_new_start_date - v_old_start;
    if v_delta = 0 then
        return jsonb_build_object('ok', true, 'shifted_phases', '[]'::jsonb, 'shifted_tasks_count', 0, 'no_change', true);
    end if;

    -- (3) делегировать D104 (каскад двигает фазы, задачи — НЕ его забота, P7)
    v_cascade := public.fn_shift_phase_cascade(v_phase.id, p_new_start_date, p_actor_id);

    -- (4) сдвинуть задачи сдвинутых фаз на тот же delta (uniform: длительности/лаги сохранены).
    --     Прошлое неприкосновенно: только будущие статусы; completed/skipped не трогаются (§9.4).
    select array_agg((e->>'phase_id')::uuid) into v_phase_ids
    from jsonb_array_elements(v_cascade) e;

    update public.farm_tasks ft
    set    due_date     = ft.due_date + v_delta,
           window_start = case when ft.window_start is not null then ft.window_start + v_delta end,
           window_end   = case when ft.window_end   is not null then ft.window_end   + v_delta end,
           updated_at   = now()
    where  ft.farm_phase_id = any(v_phase_ids)
      and  ft.status in ('scheduled','reminded','overdue');
    get diagnostics v_tasks_cnt = row_count;

    -- (5) эмит существующего ops.farm_phase.rescheduled (O-04) — payload несёт cascaded_phases[]
    insert into public.platform_events (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload)
    values ('ops.farm_phase.rescheduled', 'farm_phases', v_phase.id, p_organization_id,
            'farmer', p_actor_id,
            jsonb_build_object('phase_id', v_phase.id, 'old_start', v_old_start, 'new_start', p_new_start_date,
                'shift_days', v_delta, 'cascaded_phases', v_cascade, 'shifted_tasks_count', v_tasks_cnt));

    return jsonb_build_object('ok', true, 'shifted_phases', v_cascade, 'shifted_tasks_count', v_tasks_cnt);
end;
$$;
grant execute on function public.rpc_shift_breeding_start(uuid, uuid, date, uuid) to authenticated;
revoke execute on function public.rpc_shift_breeding_start(uuid, uuid, date, uuid) from public, anon;
comment on function public.rpc_shift_breeding_start(uuid, uuid, date, uuid) is
    'ARS-279 §2.9 (D144): фермерская обёртка D104. Ownership-guard + fn_shift_phase_cascade +
     сдвиг задач будущих фаз (scheduled/reminded/overdue) на тот же delta + emit O-04. UI: сначала
     fn_preview_cascade (RPC-36) → confirm → этот RPC. fn_shift_phase_cascade НЕ меняется (P7).';

-- ---- 2.10  rpc_reschedule_farm_task — «На сегодня» (окно неподвижно) --------
create or replace function public.rpc_reschedule_farm_task(
    p_organization_id uuid,
    p_task_id         uuid,
    p_new_due_date    date,
    p_actor_id        uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_task record;
begin
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id using errcode = 'P0001';
    end if;
    select ft.* into v_task from public.farm_tasks ft
    where ft.id = p_task_id and ft.organization_id = p_organization_id;
    if not found then
        return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND');
    end if;
    -- Перенос задачи НЕ двигает окно (§9.4): задача-окно immovable
    if v_task.window_start is not null then
        return jsonb_build_object('ok', false, 'reason', 'WINDOW_TASK_IMMOVABLE');
    end if;

    update public.farm_tasks
    set    due_date   = p_new_due_date,
           status     = case when status = 'overdue' and p_new_due_date >= current_date then 'scheduled' else status end,
           updated_at = now()
    where  id = p_task_id;

    return jsonb_build_object('ok', true, 'task_id', p_task_id, 'due_date', p_new_due_date);
end;
$$;
grant execute on function public.rpc_reschedule_farm_task(uuid, uuid, date, uuid) to authenticated;
revoke execute on function public.rpc_reschedule_farm_task(uuid, uuid, date, uuid) from public, anon;
comment on function public.rpc_reschedule_farm_task(uuid, uuid, date, uuid) is
    'ARS-279 §2.10: перенос просрочки. Задача-окно → WINDOW_TASK_IMMOVABLE (перенос не двигает
     окно, §9.4). overdue → scheduled при новой дате ≥ сегодня. NK-идемпотентность.';

-- ---- 2.11  rpc_activate_production_plan — draft→active (retire FARM-02) -----
create or replace function public.rpc_activate_production_plan(
    p_organization_id uuid,
    p_plan_id         uuid,
    p_actor_id        uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_plan     record;
    v_other    uuid;
begin
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id using errcode = 'P0001';
    end if;
    select fpp.* into v_plan from public.farm_production_plans fpp
    where fpp.id = p_plan_id and fpp.organization_id = p_organization_id;
    if not found then
        return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND');
    end if;
    if v_plan.status = 'active' then   -- FSM-идемпотентность
        return jsonb_build_object('ok', true, 'plan_id', p_plan_id, 'status', 'active',
                                  'activated_at', v_plan.activated_at, 'already_active', true);
    end if;
    if v_plan.status <> 'draft' then
        return jsonb_build_object('ok', false, 'reason', 'PLAN_NOT_DRAFT', 'status', v_plan.status);
    end if;
    -- один active-план на ферму (idx_farm_plan_one_active)
    select id into v_other from public.farm_production_plans
    where farm_id = v_plan.farm_id and status = 'active' and id <> p_plan_id limit 1;
    if v_other is not null then
        return jsonb_build_object('ok', false, 'reason', 'PLAN_ALREADY_ACTIVE_EXISTS', 'active_plan_id', v_other);
    end if;

    update public.farm_production_plans
    set status = 'active', activated_at = now(), updated_at = now()
    where id = p_plan_id;

    insert into public.platform_events (event_type, entity_type, entity_id, organization_id, actor_type, actor_id, payload)
    values ('ops.production_plan.started', 'farm_production_plans', p_plan_id, p_organization_id,
            'farmer', p_actor_id,
            jsonb_build_object('plan_id', p_plan_id, 'farm_id', v_plan.farm_id, 'activation', true));

    return jsonb_build_object('ok', true, 'plan_id', p_plan_id, 'status', 'active', 'activated_at', now());
end;
$$;
grant execute on function public.rpc_activate_production_plan(uuid, uuid, uuid) to authenticated;
revoke execute on function public.rpc_activate_production_plan(uuid, uuid, uuid) from public, anon;
comment on function public.rpc_activate_production_plan(uuid, uuid, uuid) is
    'ARS-279 §2.11: draft→active (retire IMPL_DEBT FARM-02). Guard одного active-плана
     (idx_farm_plan_one_active) → PLAN_ALREADY_ACTIVE_EXISTS. Эмит O-01 (payload.activation=true).';

-- ---- 2.14  rpc_create_farm_task — ручная задача / задача из отклонения ------
create or replace function public.rpc_create_farm_task(
    p_organization_id uuid,
    p_farm_id         uuid,
    p_name_ru         text,
    p_due_date        date,
    p_due_time        time  default null,
    p_category        text  default 'management',
    p_assigned_to     uuid  default null,
    p_animal_event_id uuid  default null,
    p_client_task_id  uuid  default null,
    p_actor_id        uuid  default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_plan_id  uuid;
    v_phase_id uuid;
    v_existing uuid;
    v_task_id  uuid;
begin
    if not (p_organization_id = any(public.fn_my_org_ids()) or public.fn_is_admin()) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.farms f
                   where f.id = p_farm_id and f.organization_id = p_organization_id and f.is_active) then
        raise exception 'FORBIDDEN: farm % does not belong to organization %', p_farm_id, p_organization_id using errcode = 'P0001';
    end if;
    -- CID-идемпотентность реплея
    if p_client_task_id is not null then
        select id into v_existing from public.farm_tasks where client_task_id = p_client_task_id;
        if v_existing is not null then
            return jsonb_build_object('ok', true, 'task_id', v_existing, 'already_created', true);
        end if;
    end if;

    select id into v_plan_id from public.farm_production_plans
    where farm_id = p_farm_id and organization_id = p_organization_id and status = 'active' limit 1;
    if v_plan_id is null then
        return jsonb_build_object('ok', false, 'reason', 'NO_ACTIVE_PLAN');
    end if;

    -- фаза, покрывающая due_date; иначе ближайшая незавершённая
    select fp.id into v_phase_id from public.farm_phases fp
    where fp.plan_id = v_plan_id and fp.status <> 'skipped' and p_due_date between fp.start_date and fp.end_date
    order by fp.start_date limit 1;
    if v_phase_id is null then
        select fp.id into v_phase_id from public.farm_phases fp
        where fp.plan_id = v_plan_id and fp.status not in ('completed','skipped')
        order by abs(fp.start_date - p_due_date) limit 1;
    end if;
    if v_phase_id is null then
        select fp.id into v_phase_id from public.farm_phases fp
        where fp.plan_id = v_plan_id order by fp.start_date desc limit 1;
    end if;

    insert into public.farm_tasks (
        farm_phase_id, organization_id, task_template_id, name_ru, category, due_date,
        due_time, assigned_to, animal_event_id, client_task_id, status
    ) values (
        v_phase_id, p_organization_id, null, p_name_ru, coalesce(p_category,'management'), p_due_date,
        p_due_time, p_assigned_to, p_animal_event_id, p_client_task_id, 'scheduled'
    ) returning id into v_task_id;

    return jsonb_build_object('ok', true, 'task_id', v_task_id,
        'source', case when p_animal_event_id is not null then 'deviation' else 'manual' end);
end;
$$;
grant execute on function public.rpc_create_farm_task(uuid, uuid, text, date, time, text, uuid, uuid, uuid, uuid) to authenticated;
revoke execute on function public.rpc_create_farm_task(uuid, uuid, text, date, time, text, uuid, uuid, uuid, uuid) from public, anon;
comment on function public.rpc_create_farm_task(uuid, uuid, text, date, time, text, uuid, uuid, uuid, uuid) is
    'ARS-279 §2.14: единственный создающий RPC вне генератора ЦТК — кнопка «+» (ручная) и «Осмотр»
     (p_animal_event_id → source=deviation). Привязка к фазе active-плана; нет плана → NO_ACTIVE_PLAN.
     Окно НЕ задаётся (окна только из генератора). CID-идемпотентность (client_task_id).';

-- ---- Реестр имён (D-NEW-A) --------------------------------------------------
insert into public.rpc_name_registry (sql_name, dok3_name, dok5_tool_name, created_in, notes) values
  ('rpc_get_farm_overview',        null, null, 'd05_ops_edu.sql (ARS-279)', 'Ferma 2.0 §2.7: агрегат Обзора'),
  ('rpc_get_tasks_horizon',        null, null, 'd05_ops_edu.sql (ARS-279)', 'Ferma 2.0 §2.8: Неделя/Месяц/Год'),
  ('rpc_shift_breeding_start',     null, null, 'd05_ops_edu.sql (ARS-279)', 'Ferma 2.0 §2.9: фермерская обёртка D104 (D144)'),
  ('rpc_reschedule_farm_task',     null, null, 'd05_ops_edu.sql (ARS-279)', 'Ferma 2.0 §2.10: перенос без сдвига окна'),
  ('rpc_activate_production_plan', null, null, 'd05_ops_edu.sql (ARS-279)', 'Ferma 2.0 §2.11: draft→active, retire FARM-02'),
  ('rpc_create_farm_task',         null, null, 'd05_ops_edu.sql (ARS-279)', 'Ferma 2.0 §2.14: ручная задача / из отклонения, CID-идемпотентность')
on conflict (sql_name) do update set created_in = excluded.created_in, notes = excluded.notes;

-- ============================================================================
-- END SECTION ARS-279
-- ============================================================================

