# AGOS — Dok 3: RPC Catalog

**Project:** TURAN Agricultural Operating System
**Version:** 1.4
**Date:** 5 March 2026
**Status:** АКТУАЛЬНЫЙ — прошёл Architecture Audit + Schema Consolidation
**Depends on:** Dok 1 (v1.8), Dok 4 (Event Bus v1.1)
**Authors:** Arshidin (CEO/Domain Expert), Claude (CTO/Architect)

**Changelog v1.3 → v1.4:**

| # | Тип | Изменение |
|---|-----|-----------|
| C-AUDIT-6 | 🔴 | RPC-25: `rpc_open_vet_case` → `rpc_create_vet_case` (SQL canonical name) |
| C-NEW-3 | 🔴 | RPC-41 `rpc_extract_farm_data_from_dialogue` — DEPRECATED (заменён Dok 5 §7 two-run flow) |
| D-NEW-A | 🔵 | SQL-миграции = единственный канонический источник имён. `rpc_name_registry` таблица в БД |
| NEW | 🔵 | Раздел 1: добавлены 22 AI Gateway RPCs из d07_ai_gateway.sql (были реализованы, но не задокументированы) |
| NEW | 🔵 | Раздел 11: Canonical Name Registry (таблица rpc_name_registry) |
| NEW | 🔵 | Статус каждого RPC: ✅ Implemented (в SQL) | 📋 Planned (только spec) |
| D138 | 🔵 | Обновлена секция миграций: 17 files → 7 consolidated files |

---

## 0. Назначение документа

Этот документ — **единственный каталог всех PostgreSQL RPC-функций**, доступных через Supabase. Каждый интерфейс — Веб-кабинет (Lovable), AI Gateway (Python FastAPI), Административная консоль — вызывает только функции из этого каталога.

**Vibecoding-команде:**
- `✅ Implemented` — функция уже создана в SQL, можно вызывать прямо сейчас
- `📋 Planned` — функция задокументирована, требует реализации в sprint
- При написании промпта для Lovable — ссылайтесь на ID (RPC-09)
- Canonical имя = колонка "SQL-функция" в Разделе 11
- **Принцип D-NEW-A:** SQL-файл выигрывает при любом расхождении с документом

**⚠ Edge Functions:** Вычислительные функции (NASEM LP-оптимизация, ration calculation) — Edge Function / FastAPI, не PostgreSQL RPC. Список в Приложении A.

---

## Типы вызывающих (Callers)

| Метка | Кто вызывает | Примечания |
|-------|-------------|------------|
| `[WEB]` | React/Lovable (кабинет) | Аутентифицирован через Supabase Auth JWT. RLS применяется автоматически |
| `[AI]` | Python AI Gateway | Использует service_role key + явную проверку org_id. Никогда не обходит RLS без явного reason |
| `[ADMIN]` | Административная консоль | Только пользователи с активной записью в admin_roles. fn_is_admin() = true |

---

## 1. Сводный каталог

**67 функций:** 45 бизнес-RPCs + 22 AI Gateway RPCs (d07). Статус отдельно для каждой.

### 1.1. Identity & Farm

| ID | Функция | Домен | Вызов | Статус | Возвращает |
|----|---------|-------|-------|--------|------------|
| RPC-01 | `rpc_register_organization` | Identity | web, ai | 📋 Planned | jsonb { org_id, farm_id? } |
| RPC-02 | `rpc_submit_membership_application` | Identity | web, ai | 📋 Planned | uuid (application_id) |
| RPC-03 | `rpc_process_membership_application` | Identity | admin | 📋 Planned | uuid (membership_id) |
| RPC-04 | `rpc_get_my_context` | Identity | web, ai | 📋 Planned | jsonb |
| RPC-05 | `rpc_upsert_farm` | Farm | web, ai | 📋 Planned | uuid (farm_id) |
| RPC-05b | `rpc_set_farm_activity_types` | Farm | web, ai | 📋 Planned | jsonb { inserted, removed } |
| RPC-06 | `rpc_upsert_herd_group` | Farm | web, ai | ✅ Implemented | uuid (group_id) |
| RPC-07 | `rpc_log_herd_event` | Farm | web, ai | 📋 Planned | uuid (event_id) |
| RPC-08 | `rpc_get_farm_summary` | Farm | web, ai | 📋 Planned | jsonb |

### 1.2. Market / TSP

| ID | Функция | Домен | Вызов | Статус | Возвращает |
|----|---------|-------|-------|--------|------------|
| RPC-09 | `rpc_create_batch` | Market/TSP | web, ai | ✅ Implemented | uuid (batch_id) |
| RPC-10 | `rpc_publish_batch` | Market/TSP | web, ai | ✅ Implemented | jsonb { batch_id, expires_at, sku_locked } |
| RPC-11 | `rpc_cancel_batch` | Market/TSP | web, ai, admin | 📋 Planned | boolean |
| RPC-12 | `rpc_create_pool_request` | Market/TSP | web | 📋 Planned | uuid (request_id) |
| RPC-13 | `rpc_activate_pool_request` | Market/TSP | web, admin | 📋 Planned | jsonb { request_id, pool_id } |
| RPC-14 | `rpc_match_batch_to_pool` | Market/TSP | admin | 📋 Planned | uuid (match_id) |
| RPC-15 | `rpc_advance_pool_status` | Market/TSP | admin | 📋 Planned | boolean |
| RPC-16 | `rpc_rollback_batch_match` | Market/TSP | admin | 📋 Planned | boolean |
| RPC-17 | `rpc_get_price_for_sku` | Market/TSP | web, ai | 📋 Planned | jsonb { base_price, premium, disclaimer_text } |
| RPC-18 | `rpc_get_market_summary` | Market/TSP | web, ai | 📋 Planned | jsonb |
| RPC-19 | `rpc_set_price_grid` | Market/TSP | admin | 📋 Planned | uuid (price_grid_id) |
| RPC-20 | `rpc_publish_price_index_value` | Market/TSP | admin | 📋 Planned | uuid (value_id) |

### 1.3. Feed & Nutrition

| ID | Функция | Домен | Вызов | Статус | Возвращает |
|----|---------|-------|-------|--------|------------|
| RPC-21 | `rpc_upsert_feed_inventory` | Feed | web, ai | 📋 Planned | jsonb { updated_items, total_kg } |
| RPC-22 | `rpc_save_ration` | Feed | web, ai | 📋 Planned | jsonb { ration_id } |
| RPC-23 | `rpc_archive_ration` | Feed | web, ai | 📋 Planned | boolean |
| RPC-24 | `rpc_get_current_ration` | Feed | web, ai | 📋 Planned | jsonb (ration + last version + nutrient summary) |

### 1.4. Veterinary

| ID | Функция | Домен | Вызов | Статус | Возвращает |
|----|---------|-------|-------|--------|------------|
| RPC-25 | `rpc_create_vet_case` | Veterinary | web, ai | ✅ Implemented | uuid (case_id) |
| RPC-26 | `rpc_add_vet_diagnosis` | Veterinary | web | 📋 Planned | uuid (diagnosis_id) |
| RPC-27 | `rpc_add_vet_recommendation` | Veterinary | web | 📋 Planned | uuid (recommendation_id) |
| RPC-28 | `rpc_close_vet_case` | Veterinary | web | 📋 Planned | boolean |
| RPC-29 | `rpc_create_vaccination_plan` | Veterinary | web, ai | 📋 Planned | uuid (plan_id) |
| RPC-30 | `rpc_add_vaccination_plan_item` | Veterinary | web | 📋 Planned | uuid (plan_item_id) |
| RPC-31 | `rpc_record_vaccination` | Veterinary | web, ai | 📋 Planned | uuid (record_id) |
| RPC-32 | `rpc_report_epidemic_signal` | Veterinary | ai, admin | 📋 Planned | uuid (signal_id) |

### 1.5. Operations

| ID | Функция | Домен | Вызов | Статус | Возвращает |
|----|---------|-------|-------|--------|------------|
| RPC-33 | `rpc_start_production_plan` | Operations | web, ai | ✅ Implemented | uuid (plan_id) |
| RPC-34 | `rpc_complete_farm_task` | Operations | web, ai | ✅ Implemented | jsonb { task_id, next_tasks[], kpi_updates[] } |
| RPC-35 | `fn_shift_phase_cascade` | Operations | web, ai | ✅ Implemented | jsonb [{ phase_id, phase_name, old_start, new_start, shift_days, date_type }, ...] |
| RPC-36 | `fn_preview_cascade` | Operations | web, ai | ✅ Implemented | TABLE (phase_id, phase_name, current_start, new_start, shift_days, date_type, depth) |
| RPC-37 | `rpc_get_active_plan` | Operations | web, ai | 📋 Planned | jsonb |

### 1.6. Education

| ID | Функция | Домен | Вызов | Статус | Возвращает |
|----|---------|-------|-------|--------|------------|
| RPC-38 | `rpc_enroll_in_course` | Education | web, ai | 📋 Planned | uuid (enrollment_id) |
| RPC-39 | `rpc_complete_lesson` | Education | web, ai | 📋 Planned | jsonb { progress_pct, is_course_complete, certificate_id? } |

### 1.7. Platform

| ID | Функция | Домен | Вызов | Статус | Возвращает |
|----|---------|-------|-------|--------|------------|
| RPC-40 | `rpc_start_ai_conversation` | Platform | ai | 📋 Planned | jsonb { conv_id, context: FarmSummary } |
| RPC-41 | ~~`rpc_extract_farm_data_from_dialogue`~~ | Platform | — | ⛔ DEPRECATED v1.3 | — |
| RPC-42 | `rpc_search_knowledge` | Platform | ai | 📋 Planned | TABLE (chunk_id, title, content, score, source_domain, metadata) |
| RPC-43 | `rpc_create_proactive_alert` | Platform | ai, admin | 📋 Planned | jsonb { alert_id, requires_expert_approval } |
| RPC-44 | `rpc_add_knowledge_chunk` | Platform | admin | 📋 Planned | uuid (chunk_id) |
| RPC-45 | `rpc_restrict_organization` | Platform | admin | 📋 Planned | uuid (restriction_id) |

### 1.8. Standards / Animal Taxonomy (ADR-ANIMAL-01, 2026-04-15)

| ID | SQL canonical name | Domain | Caller | Status | Return |
|----|--------------------|--------|--------|--------|--------|
| RPC-T1 | `rpc_list_animal_categories(p_at_date, p_include_deprecated)` | Standards | web, ai, admin | ✅ Implemented | SETOF jsonb (incl. `id`; L1 codes as of date) |
| ~~RPC-T1-legacy~~ | ~~`rpc_list_animal_categories()`~~ | — | — | ⛔ DROPPED 2026-04-17 (DEF-RATION-SAVE-01) | PostgREST не мог разрешить overload при вызове `.rpc(name, {})` → PGRST203. Wrapper удалён; canonical теперь возвращает `id` в jsonb. |
| RPC-T2 | `rpc_resolve_category(p_source_code, p_target_taxonomy, p_at_date)` | Standards | web, ai, backend | ✅ Implemented | text (canonical target, is_primary-first) |
| RPC-T3 | `rpc_get_category_mappings(p_target_taxonomy, p_at_date)` | Standards | web, ai, backend | ✅ Implemented | SETOF jsonb (all L1→target pairs at date) |
| RPC-T4 | `rpc_add_animal_category(p_code, p_name_ru, p_name_kk, p_sex, p_purpose, p_physiological_state, p_age_band, p_required_mappings, p_description_ru, p_sort_order)` | Standards | admin | ✅ Implemented | jsonb (I3: required mappings enforced) |
| RPC-T5 | `rpc_deprecate_animal_category(p_code, p_replaced_by, p_valid_to)` | Standards | admin | ✅ Implemented | jsonb (I1: never delete; closes L2 via valid_to) |
| RPC-T6 | `rpc_migrate_animal_category(p_from_code, p_to_code, p_strategy)` | Standards | admin | ✅ Implemented | jsonb (auto_remap \| flag_farmer_task) |

### 1.8. AI Gateway RPCs (d07_ai_gateway.sql) — ✅ Все реализованы

Эти функции были созданы в migration 011_ai_rpc_catalog.sql (теперь в d07_ai_gateway.sql) для прямого использования из Python AI Gateway. Все имеют SECURITY DEFINER + `_ai_check_farm_org()` guard.

| ID | SQL-функция | Dok 5 tool | Возвращает |
|----|-------------|------------|------------|
| AI-01 | `rpc_get_ai_farm_context` | `get_farm_context` | jsonb { farm, herd_groups[], active_plans[], vet_cases[] } |
| AI-02 | `rpc_upsert_herd_group` | `update_herd_group` | uuid (group_id) |
| AI-03 | `rpc_get_feeding_plan` | `get_feeding_plan` | jsonb { plan, periods[], current_ration } |
| AI-04 | `rpc_get_farm_tasks` | `get_farm_tasks` | jsonb [{ task_id, name, due_date, status }] |
| AI-05 | `rpc_complete_farm_task` | `complete_farm_task` | jsonb { task_id, next_tasks[], kpi_updates[] } |
| AI-06 | `rpc_get_production_plan` | `get_production_plan` | jsonb { plan, phases[], current_phase } |
| AI-07 | `rpc_create_vet_case` | `create_vet_case` | uuid (case_id) |
| AI-08 | `rpc_add_vet_symptoms` | `add_symptoms` | jsonb { case_id, severity, escalate? } |
| AI-09 | `rpc_get_vet_diagnosis` | `get_diagnosis` | jsonb { possible_diseases[], recommended_actions[] } |
| AI-10 | `rpc_get_treatment_protocols` | `get_treatment_protocols` | jsonb [{ disease, protocol, dosage_note: "назначает ветврач" }] |
| AI-11 | `rpc_get_vaccination_schedule` | `get_vaccination_schedule` | jsonb [{ item_id, vaccine, due_date, herd_group, heads }] |
| AI-12 | `rpc_complete_vaccination_item` | `confirm_vaccination` | uuid (record_id) |
| AI-13 | `rpc_create_consultation_request` | `escalate_to_expert` | uuid (request_id) |
| AI-14 | `rpc_search_knowledge_chunks` | `search_knowledge` | TABLE (chunk_id, title, content, score, source_domain) |
| AI-15 | `rpc_get_membership_status` | `get_membership_status` | jsonb { level, valid_until, restrictions[] } |
| AI-16 | `rpc_get_price_grid` | `get_price_grid` | jsonb { prices[], disclaimer_text } |
| AI-17 | `rpc_get_aggregated_supply` | `get_market_overview` | jsonb { by_sku[], by_region[], total_heads } |
| AI-18 | `rpc_get_aggregated_demand` | `get_market_overview` | jsonb { by_sku[], by_region[], total_heads } |
| AI-19 | `rpc_get_org_batches` | `get_active_batches` | jsonb [{ batch_id, sku, heads, status, created_at }] |
| AI-20 | `rpc_create_batch` | `create_batch_draft` | uuid (batch_id) |
| AI-21 | `rpc_publish_batch` | `publish_batch` | jsonb { batch_id, expires_at, sku_locked } |
| AI-22 | `rpc_update_conversation_language` | — | boolean |

> ⚠️ **Nota bene для vibecoding:** AI-02 = RPC-06, AI-05 = RPC-34, AI-07 = RPC-25, AI-20 = RPC-09, AI-21 = RPC-10. Одна и та же SQL функция — разные контексты вызова. Для AI Gateway используйте AI-XX, для Web-кабинета — RPC-XX.

### 1.9. Consulting CAPEX RPCs (d09_consulting.sql, ADR-CAPEX-01) — ✅ Все реализованы

5 RPC для data-driven CAPEX engine. Подробности — §13c.

| ID | SQL-функция | Caller | Returns |
|----|-------------|--------|---------|
| RPC-CAPEX-1 | `rpc_list_construction_materials()` | UI ProjectWizard, CapexTab, /admin/capex | jsonb [{code, name_ru, cost_per_m2, currency}] |
| RPC-CAPEX-2 | `rpc_list_infrastructure_norms()` | /admin/capex | jsonb {farm:[...], pasture:[...], equipment:[...], tools:[...]} |
| RPC-CAPEX-3 | `rpc_upsert_construction_material(code, name_ru, cost_per_m2)` | /admin/capex (admin) | int (id) |
| RPC-CAPEX-4 | `rpc_upsert_infrastructure_norm(code, data, block?)` | /admin/capex (admin) | int (id) |
| RPC-CAPEX-5 | `rpc_save_project_infra_override(org_id, project_id, enclosed?, support?, overrides?)` | ProjectWizard + CapexTab | boolean (needs_recalc=true) |

---

## 2. Identity — Идентификация и членство

### RPC-01 `rpc_register_organization` [WEB] [AI] 📋 Planned

Регистрация новой организации (ферма или МПК) → jsonb { org_id, farm_id? }

*Атомарная операция: создаёт Organization + присваивает роль создателю + создаёт Farm (если org_type="farmer").*

**Параметры:**

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_org_type` | text | ✓ | farmer \| mpk \| supplier \| consultant \| other |
| `p_name` | text | ✓ | Официальное наименование |
| `p_bin` | text | — | БИН (12 цифр). null = физлицо |
| `p_region_id` | uuid | — | Регион регистрации |
| `p_phone` | text | — | Контактный телефон (WhatsApp) |
| `p_invited_by` | uuid | — | user_id пригласившего |

**Публикует события:** `identity.organization.registered`

**Исключения:** `BIN_DUPLICATE` | `INVALID_ORG_TYPE`

### RPC-02 `rpc_submit_membership_application` [WEB] [AI] 📋 Planned

Подача заявки на членство → uuid (application_id)

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_org_id` | uuid | ✓ | Организация-заявитель |
| `p_membership_type` | text | ✓ | associate \| full \| premium \| honorary |
| `p_notes` | text | — | Примечания |

**Исключения:** `ALREADY_ACTIVE` | `PENDING_EXISTS`

### RPC-03 `rpc_process_membership_application` [ADMIN] 📋 Planned

Одобрение или отклонение заявки → uuid (membership_id)

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_application_id` | uuid | ✓ | Статус: submitted / under_review |
| `p_decision` | text | ✓ | approved \| rejected |
| `p_decision_notes` | text | — | Комментарий |
| `p_valid_from` | date | — | Дата начала (default: today) |

**Публикует:** `identity.membership.activated` | `identity.membership_application.rejected`

### RPC-04 `rpc_get_my_context` [WEB] [AI] 📋 Planned

Контекст текущего пользователя → jsonb

Возвращает: { user_id, organizations[], memberships[], expert_profile?, farms[], active_restrictions[] }

*Используется при загрузке кабинета и инициализации AI-сессии.*

---

## 3. Farm — Управление фермой

### RPC-05 `rpc_upsert_farm` [WEB] [AI] 📋 Planned

Создание / обновление фермы → uuid (farm_id)

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | Организация-владелец |
| `p_farm_id` | uuid | — | null = создать новую |
| `p_name` | text | ✓ | Название |
| `p_region_id` | uuid | — | Регион |
| `p_shelter_type` | text | — | stall \| combined \| pasture_only |
| `p_calving_system` | text | — | spring \| autumn \| year_round |
| `p_total_area_ha` | numeric | — | Площадь |

### RPC-05b `rpc_set_farm_activity_types` [WEB] [AI] 📋 Planned

Установка типов деятельности фермы → jsonb { inserted, removed }

*Идемпотентный: принимает полный набор, сам вычисляет delta.*

### RPC-06 `rpc_upsert_herd_group` [WEB] [AI] ✅ Implemented

Создание / обновление группы скота → uuid (group_id)

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | Владелец (AI Gateway: добавляется автоматически) |
| `p_farm_id` | uuid | ✓ | Ферма |
| `p_group_id` | uuid | — | null = новая группа |
| `p_animal_category_id` | uuid | ✓ | AnimalCategory |
| `p_breed_id` | uuid | — | Порода |
| `p_head_count` | int | — | Поголовье |
| `p_avg_weight_kg` | numeric | — | Средний вес |
| `p_data_source` | text | — | manual \| ai_extracted \| erp \| registration |
| `p_label` | text | — | Метка группы |
| `p_confidence` | int | — | 1–100 (Layered Truth) |

**Триггер:** → `farm.herd_group.updated` event

> ⚠️ **Confirmation required:** AI Gateway не пишет напрямую. Сначала `save_confirmation_payload`, фермер подтверждает, затем вызов в Run 2. Исключение: если head_count < 5 или изменение < 5% — auto-confirm.

### RPC-07 `rpc_log_herd_event` [WEB] [AI] 📋 Planned

Запись события в HerdEvent (append-only) → uuid (event_id)

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | — |
| `p_farm_id` | uuid | ✓ | — |
| `p_herd_group_id` | uuid | — | Конкретная группа или null (всё стадо) |
| `p_event_type` | text | ✓ | head_count_change / weight_update / group_created / ... |
| `p_value_before` | numeric | — | Значение до |
| `p_value_after` | numeric | ✓ | Значение после |
| `p_data_source` | text | ✓ | manual / erp / ai_extracted |
| `p_event_date` | date | — | default: today |
| `p_notes` | text | — | — |

### RPC-08 `rpc_get_farm_summary` [WEB] [AI] 📋 Planned

Сводка по ферме → jsonb

Возвращает: { farm, herd_groups[], feed_inventory[], active_vet_cases[], upcoming_tasks[], active_plan_summary }

---

## 4. Market / TSP

> ⚠️ **Юридическое требование (ст. 171 ПК РК):** При каждом вызове rpc_get_price_for_sku, rpc_get_price_grid, rpc_get_market_summary ответ ДОЛЖЕН содержать `disclaimer_text`: *"Справочные цены являются индикативными рыночными ориентирами..."*

### RPC-09 `rpc_create_batch` [WEB] [AI] ✅ Implemented

Создание черновика supply-offer → uuid (batch_id)

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | Продавец |
| `p_farm_id` | uuid | — | Ферма отгрузки |
| `p_herd_group_id` | uuid | — | Группа (soft link) |
| `p_sku_id` | uuid | ✓ | TspSku (категория + вес класс) |
| `p_heads` | int | ✓ | Поголовье |
| `p_avg_weight_kg` | numeric | — | Средний вес |
| `p_target_month` | date | ✓ | Планируемый месяц отгрузки |
| `p_breed_id` | uuid | — | Порода (для премиума) |
| `p_grade_standard_id` | uuid | — | Грейд (Phase 2) |
| `p_notes` | text | — | — |

**Проверки:** health_restrictions.is_active = false (TSP Safety Gate, D98)

### RPC-10 `rpc_publish_batch` [WEB] [AI] ✅ Implemented

Публикация черновика в market → jsonb { batch_id, expires_at, sku_locked }

*После публикации: TspSku, WeightClass, GradeStandard — заблокированы.*

### RPC-11 `rpc_cancel_batch` [WEB] [AI] [ADMIN] 📋 Planned

Отмена лота → boolean

### RPC-12 `rpc_create_pool_request` [WEB] 📋 Planned

Заявка MPK на закупку → uuid (request_id)

### RPC-13 `rpc_activate_pool_request` [WEB] [ADMIN] 📋 Planned

Активация заявки (создаёт Pool) → jsonb { request_id, pool_id }

### RPC-14 `rpc_match_batch_to_pool` [ADMIN] 📋 Planned

Матчинг лота в пул → uuid (match_id)

### RPC-15 `rpc_advance_pool_status` [ADMIN] 📋 Planned

Сдвиг статуса пула по FSM → boolean

### RPC-16 `rpc_rollback_batch_match` [ADMIN] 📋 Planned

Отмена матча с причиной → boolean

### RPC-17 `rpc_get_price_for_sku` [WEB] [AI] 📋 Planned

Справочная цена для конкретного SKU → jsonb { base_price, premium, disclaimer_text, valid_from }

> Заменяет или дополняет AI-16 `rpc_get_price_grid` — более детальный запрос для web UI.

### RPC-18 `rpc_get_market_summary` [WEB] [AI] 📋 Planned

Анонимизированный обзор рынка → jsonb { supply_by_sku[], demand_by_mpk[], price_trends[] }

> В AI Gateway аналог: AI-17 `rpc_get_aggregated_supply` + AI-18 `rpc_get_aggregated_demand`.

### RPC-19 `rpc_set_price_grid` [ADMIN] 📋 Planned

Установка / обновление цены → uuid (price_grid_id)

### RPC-20 `rpc_publish_price_index_value` [ADMIN] 📋 Planned

Публикация значения индекса → uuid (value_id)

---

## 4a. Market / TSP — M4 + M6 Extension (canonical, 2026-06-15)

> **Источник:** [d02_tsp.sql SECTION 8](../d02_tsp.sql) (Section 8 + addendum).
> **Покрытие:** Microstep 4 (Batch/Pool/Offer FSM) + Microstep 6 (TSP UX flow).
> **Статус:** все 14 функций ✅ Implemented + deployed на prod (2026-06-15) + registered в `rpc_name_registry`.
>
> **Конвенции (все 14):** `SECURITY DEFINER` + `set search_path = public, pg_temp`; `p_organization_id` первый параметр (P-AI-2); idempotent state checks; `batch_events` + `platform_events` на каждом FSM-переходе батча.
>
> **Backward compat:** RPC-12..16, 19, 20 выше (старая Slice 5b модель PoolRequest) **не модифицированы** (P7). Они остаются callable для legacy-данных, но в новых M4/M6 потоках использовать не следует — будущий deprecation ADR.

### RPC-M4-01 `rpc_create_pool` [WEB] [ADMIN] ✅ Implemented (Section 8)

Создание Pool-контейнера с N pool_lines и M pool_regions → `jsonb { pool_id, pool_line_ids: uuid[] }`. M4 §2.4 + D-M6-13.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | МПК-владелец Pool'а. Сохраняется в `pools.organization_id` (DEF-TSP-M4-OWNERSHIP). |
| `p_pool_lines` | jsonb | ✓ | Массив объектов: `[{tsp_sku_id, category_label?, mpk_price_per_kg, max_volume_kg?, livestock_category_id?}, ...]`. `livestock_category_id` опц. — если указан, проверяется floor (M4 §1.1). |
| `p_pool_regions` | jsonb | ✓ | Массив: `[{region_type: 'oblast'|'rayon', region_id}, ...]` (D-M6-4). |
| `p_delivery_from` | date | ✓ | `pools.delivery_from` (D-M6-8). |
| `p_delivery_to` | date | ✓ | `pools.delivery_to` (D-M6-8). `delivery_to >= delivery_from`. |
| `p_total_target_volume_kg` | int | ✓ | Аггрегированный объём (D-M6-13). |

**Floor enforcement (D-TSP-CATEGORY-BRIDGE, 2026-06-15):** для каждой `pool_line` `v_category_id` резолвится через `coalesce(explicit livestock_category_id, tsp_sku_category_map.category_id WHERE tsp_sku_id = pool_line.tsp_sku_id AND is_active=true)`. При `v_category_id IS NOT NULL` — `MAX(price_per_kg)` по `minimum_prices` для всех regions Pool'а (C3 finding closed); если `mpk_price_per_kg < floor` — `PRICE_BELOW_FLOOR`. Explicit param wins для back-compat (P7). Пустой bridge → `v_category_id IS NULL` → floor check пропускается (graceful — pilot SKU постепенно покрываются через A-CAT-03 admin screen).

### RPC-M4-02 `rpc_publish_pool` [WEB] [ADMIN] ✅ Implemented (Section 8)

`pools.draft → filling`. Вызывает `rpc_retry_match_pool` inline → broadcast Offers всем подходящим published-батчам (BT-05). Идемпотентна.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | МПК (= `pools.organization_id`). |
| `p_pool_id` | uuid | ✓ | — |

→ `boolean` (true при переходе или уже-filling).

### RPC-M4-03 `rpc_retry_match_pool` [WEB] [ADMIN] [SYSTEM] ✅ Implemented (Section 8)

Сканирует `batches.status='published'`, удовлетворяющие pool_lines (sku, цена, capacity), region (D-M6-4) и window overlap (D-M6-8); upsert'ит `offers` для МПК. Идемпотентна (через `unique(batch_id, mpk_org_id)`). Q-TSP-RETRY-MATCH closed.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | МПК (для caller-check). Также вызывается inline из `rpc_publish_pool`. |
| `p_pool_id` | uuid | ✓ | — |

→ `int` (число созданных/обновлённых Offer'ов).

### RPC-M4-04 `rpc_accept_offer` [WEB] [AI] ✅ Implemented (Section 8)

FCFS-приём предложения МПК → `jsonb { batch_id, pool_id, pool_line_id, deal_price_per_kg, volume_kg }`. M4 §2.3 + §5.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | МПК (= `offers.mpk_org_id`). |
| `p_offer_id` | uuid | ✓ | — |

**Семантика:**
- Принимает только при `batch.status='offering'` (S1 fix).
- `FOR UPDATE` на `pools` сериализует concurrent accepts (FCFS).
- Region-фильтр на pool_line: `pool_regions ∩ batch.region` (S2 fix, D-M6-4).
- Capacity: `current_volume_kg + batch.volume_kg <= max_volume_kg` (S6 fix).
- Атомарно: `offer.status='accepted'`; sibling pending offers → `withdrawn`; `batch.status='matched'`; `pool_line.current_volume_kg += batch.volume_kg`; `batch.pool_line_id = pool_line.id`; `batch.deal_price_per_kg = offered_price_per_kg`.
- Auto-close pool: при достижении `total_target_volume_kg` → `pools.status='closed_filled'`, все matched batches → `confirmed` (C1 defensive gate: `where status='filling'`).
- Emits `batch_events('matched')` (M2 fix).

### RPC-M4-05 `rpc_reject_offer` [WEB] [AI] ✅ Implemented (Section 8)

`offers.status: pending → rejected`. M4 §2.3.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_offer_id` | uuid | ✓ |

→ `boolean`. Не влияет на batch.status — батч продолжает ждать sibling-Offer'ов или истечения окна.

### RPC-M4-06 `rpc_lower_batch_price` [WEB] [AI] ✅ Implemented (Section 8)

Понижение цены батча в `awaiting_price_decision` → re-broadcast Offers. M4 §2.6 + D-M6-3.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | Фермер (= `batches.organization_id`). |
| `p_batch_id` | uuid | ✓ | — |
| `p_new_price_per_kg` | int | ✓ | Clamp'нута к floor через D-TSP-CATEGORY-BRIDGE. |

→ `jsonb { new_price, was_clamped, broadcast_mpk_count }`.

**Floor clamp (D-TSP-CATEGORY-BRIDGE, 2026-06-15):** ✅ ВКЛЮЧЁН. Resolution path: `batch.tsp_sku_id → tsp_sku_category_map (is_active=true) → minimum_prices`. Region match: exact rayon wins (`ORDER BY (mp.region_id = v_batch.region_id) DESC NULLS LAST, valid_from DESC`); национальная строка (`region_id IS NULL`) — fallback. Дополнительный фильтр `valid_to IS NULL OR valid_to >= current_date`. `v_clamped := greatest(p_new_price_per_kg, coalesce(v_floor, p_new_price_per_kg))`; `v_was_clamped := (v_floor is not null and p_new_price_per_kg < v_floor)`. Пустой bridge для этой SKU → `v_floor=NULL` → clamp = no-op (graceful, idempotent semantics сохранена).

**Re-broadcast:** пересоздаёт Offer'ы (UPSERT по `unique(batch_id, mpk_org_id)`) для всех МПК с активными filling pools, удовлетворяющими pool_lines (mpk_price ≥ new_price, sku-match, capacity, region overlap, window overlap). `batch.status: awaiting_price_decision → offering`.

### RPC-M4-07 `rpc_confirm_dispatch` [WEB] [AI] ✅ Implemented (Section 8)

`batches.status: confirmed → dispatched` (фермер). D-M6-10.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_batch_id` | uuid | ✓ |

→ `boolean`. Идемпотентна (повторный вызов в `dispatched` → true). Emits `batch_events('dispatched')`.

### RPC-M4-08 `rpc_confirm_delivery` [WEB] [AI] ✅ Implemented (Section 8)

`batches.status: dispatched → delivered` (МПК). D-M6-10.

Caller вычисляется через `batch.pool_line_id → pools.organization_id` (DEF-TSP-M4-OWNERSHIP resolved).

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_batch_id` | uuid | ✓ |

→ `boolean`. Идемпотентна. Emits `batch_events('delivered')`.

### RPC-M4-09 `rpc_submit_deal_review` [WEB] [AI] ✅ Implemented (Section 8)

Создание/обновление взаимного отзыва. D-M6-11 + D-M6-12.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | Reviewer (роль выводится: `=batch.org` → 'farmer'; `=pool.org` → 'mpk'; иначе `FORBIDDEN`). |
| `p_batch_id` | uuid | ✓ | Должен быть `delivered` (S3 fix). |
| `p_overall_score` | int | ✓ | 1–5. |
| `p_dimension_id` | uuid | ✓ | `review_dimensions.id` (пилот: is_pilot_primary для роли). |
| `p_dimension_score` | int | ✓ | 1–5. |
| `p_comment` | text | — | — |

→ `uuid` (deal_review_id). При повторном вызове — UPDATE. Triggers double-blind reveal: если оба отзыва submitted — set `visible_at=now()` на обоих. Иначе оставляет `visible_at=NULL` до истечения review_window.

### RPC-M4-10 `rpc_pool_return_batches` [WEB] [AI] ✅ Implemented (Section 8)

МПК возвращает batches после `awaiting_mpk_decision`. D-TSP-10.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_pool_id` | uuid | ✓ |

→ `int` (число возвращённых батчей).

**Семантика:** `pools.status: awaiting_mpk_decision → closed_unfilled`; matched batches → `published`; `batch.pool_line_id = NULL`; pending offers → `withdrawn` (S5 fix); reset `pool_lines.current_volume_kg = 0`.

### RPC-M4-11 `rpc_pool_accept_partial` [WEB] [AI] ✅ Implemented (Section 8)

МПК принимает partial fill. D-TSP-10.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_pool_id` | uuid | ✓ |

→ `int` (число конфирмованных батчей). `pools.status: awaiting_mpk_decision → closed_partial`; matched → `confirmed`.

### RPC-M4-12 `rpc_cancel_pool` [WEB] [ADMIN] ✅ Implemented (Section 8 addendum)

`pools.status: filling → cancelled` (МПК). Strict option A. Microstep4 §4.1 / Microstep6 §4f step 8a.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_pool_id` | uuid | ✓ |
| `p_reason` | text | — |

→ `int` (число затронутых батчей). Атомарно: withdraw pending offers + matched → `published` + reset `pool_lines.current_volume_kg = 0` + `pool.status='cancelled'`. Идемпотентна (повторный вызов в `cancelled` → 0).

### RPC-M4-13 `rpc_get_reference_price` [WEB] [AI] [STABLE] ✅ Implemented (Section 8)

Индикативная цена + **обязательный disclaimer** (Art.171 ПК РК). M4 §1.1.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_category_id` | uuid | ✓ | (`livestock_categories.id`) |
| `p_region_id` | uuid | — | `NULL` → national fallback. |

→ `jsonb { price_per_kg, region_id, valid_from, valid_to, source: 'national'|'regional', legal_disclaimer_text }`. `legal_disclaimer_text` обязательный non-null. Если нет активной строки — `{ price_per_kg: null, legal_disclaimer_text }`.

### RPC-M4-14 `rpc_get_minimum_price` [WEB] [AI] [STABLE] ✅ Implemented (Section 8)

Floor цена + **обязательный disclaimer** (Art.171 ПК РК + D-M6-3). M4 §1.1.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_organization_id` | uuid | ✓ |
| `p_category_id` | uuid | ✓ |
| `p_region_id` | uuid | — |

→ `jsonb { price_per_kg, region_id, valid_from, valid_to, source: 'national'|'regional', legal_disclaimer_text }`. Используется UI для soft-warn при публикации батча и валидации pool_lines.mpk_price_per_kg.

### Адверсариальный code review (13 findings, 11 fixed)

| ID | Sev | Резолюция |
|----|-----|-----------|
| C1 | Critical | `rpc_accept_offer` auto-close race → defensive `where status='filling'` + `if found` gate. |
| C2 | Critical | `rpc_accept_offer` INNER→LEFT JOIN на pool_requests (поддержка M4 pools с NULL pool_request_id). |
| C3 | Critical | `rpc_create_pool` floor lookup → `MAX(price_per_kg)` по всем regions (был under-clamp). |
| C4 | Critical | `rpc_lower_batch_price` floor clamp → пропущен пока Q-TSP-CATEGORY-CLASSIFIER не закрыт (wrong-category floor хуже чем no clamp). |
| S1 | Sig | `rpc_accept_offer`: принимать только `batch.status='offering'`. |
| S2 | Sig | `rpc_accept_offer`: добавить region-фильтр (D-M6-4). |
| S3 | Sig | `rpc_submit_deal_review`: принимать только `delivered` (D-M6-11). |
| S4 | Sig | Double-blind race на `now()` — **rejected**, UPDATE идемпотентен через `visible_at IS NULL`. |
| S5 | Sig | `rpc_pool_return_batches`: withdraw pending offers перед reset. |
| S6 | Sig | `rpc_lower_batch_price` capacity check → mirror accept_offer predicate. |
| M1 | Minor | `filling_deadline = p_delivery_to` — inline-comment добавлен. |
| M2 | Minor | `batch_events('matched')` добавлен в accept_offer. |
| M3 | Minor | `p_organization_id` в read-only RPC — **rejected**, конвенция P-AI-2. |

---

## 4b. A-CAT Admin RPC (D-TSP-CATEGORY-BRIDGE, 2026-06-15)

> **Источник:** [d02_tsp.sql SECTION 8a](../d02_tsp.sql) (commit `0450823`, deployed на prod `mwtbozflyldcadypherr`).
> **Спека:** [`Docs/AGOS-Dok6-A-CAT-AdminScreens-v1_0.md`](AGOS-Dok6-A-CAT-AdminScreens-v1_0.md) §2.4.
> **Покрытие:** закрывает Q-TSP-CATEGORY-CLASSIFIER на SQL-уровне. Admin (CEO+зоолог) наполняют данные через A-CAT-01..04 экраны (UI Agent track).
>
> **Конвенции (все 11):**
> - `SECURITY DEFINER` + `set search_path = public, pg_temp`.
> - Гейт: **`fn_is_admin()`**, без `p_organization_id` — admin reference-data RPC (P-AI-2 documented exception, whitelisted в `cross_check.sh` CHECK-5).
> - Write RPC возвращают `jsonb {ok: bool, id?: uuid, error?: text}`. Read RPC возвращают `TABLE` (postgrest проецирует в JSON-массив).
> - **Events:** В MVP **не эмитятся** (audit через `approved_by`/`approved_at` колонки на `minimum_prices` / `reference_prices`). См. [Dok 4 §3.3b](AGOS-Dok4-EventBus-v1_1.md#33b-a-cat-admin-events-d-tsp-category-bridge-2026-06-15).

### RPC-AC-1 `rpc_admin_upsert_livestock_category` [ADMIN] ✅ Implemented

Создаёт или обновляет категорию по `code` (unique). При collision: UPDATE `name_ru/description_ru/sort_order`, re-activate.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_code` | text | ✓ | Уникальный код (PASCAL_CASE / SCREAMING_SNAKE, валидируется на UI). |
| `p_name_ru` | text | ✓ | Человекочитаемое имя. |
| `p_description_ru` | text | — | Опц. описание. |
| `p_sort_order` | int | — | default 0. |

→ `{ok: true, id: uuid}` или `{ok: false, error: 'FORBIDDEN' \| 'INVALID_INPUT'}`.

### RPC-AC-2 `rpc_admin_deactivate_livestock_category` [ADMIN] ✅ Implemented

`livestock_categories.is_active = false`. Hard-блок при наличии активных ссылок.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_category_id` | uuid | ✓ |

→ `{ok: true}` или `{ok: false, error: 'CATEGORY_NOT_FOUND' \| 'CATEGORY_IN_USE'}`. `CATEGORY_IN_USE` если есть active `tsp_sku_category_map` ИЛИ active `minimum_prices` ИЛИ active `reference_prices` для этой категории.

### RPC-AC-3 `rpc_admin_set_category_rule` [ADMIN] ✅ Implemented

Создаёт новое правило `livestock_category_rules` (всегда `is_active=false` — staged). Активация через AC-4.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_category_id` | uuid | ✓ | — |
| `p_breed_group` | text | — | `elite_meat \| local \| crossbred` (NULL = wildcard). |
| `p_sex` | text | — | `bull \| heifer \| cow` (NULL = wildcard). |
| `p_age_min`, `p_age_max` | int | — | месяцы. |
| `p_weight_min`, `p_weight_max` | int | — | кг. |
| `p_bcs_min`, `p_bcs_max` | numeric(3,1) | — | Body Condition Score. |
| `p_priority` | int | — | default 0; высший wins при множественном match. |
| `p_version` | int | — | если NULL → `max(version)+1` для категории (staging). |

→ `{ok: true, id: uuid, version: int}`.

### RPC-AC-4 `rpc_admin_activate_rule_version` [ADMIN] ✅ Implemented

Атомарный flip: все `is_active=true` rules для категории → `false`; целевая version → `true`. Одна транзакция.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_category_id` | uuid | ✓ |
| `p_version` | int | ✓ |

→ `{ok: true, activated_count: int, version: int}` или `{ok: false, error: 'VERSION_NOT_FOUND'}`.

### RPC-AC-5 `rpc_admin_map_sku_to_category` [ADMIN] ✅ Implemented

Атомарный re-mapping SKU → Category. Старая активная строка `is_active=false`; новая INSERT с `version = prev_max+1`, `is_active=true`. Partial unique index `ux_skumap_active_sku` гарантирует ≤1 active per SKU.

| Параметр | Тип | Обяз. |
|----------|-----|-------|
| `p_tsp_sku_id` | uuid | ✓ |
| `p_category_id` | uuid | ✓ |

→ `{ok: true, id: uuid, version: int}` или `{ok: false, error: 'SKU_NOT_FOUND' \| 'CATEGORY_NOT_FOUND_OR_INACTIVE'}`.

### RPC-AC-6 `rpc_admin_set_minimum_price` [ADMIN] ✅ Implemented

Версионирование защитного floor. Сначала deactivates active rows для `(category_id, region_id)` (`IS NOT DISTINCT FROM` для NULL=NULL match национальных строк); затем INSERT (или UPSERT по `unique(category_id, region_id, valid_from)` с реактивацией).

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_category_id` | uuid | ✓ | — |
| `p_region_id` | uuid | — | NULL = национальная строка. |
| `p_price_per_kg` | int | ✓ | > 0. |
| `p_valid_from` | date | ✓ | — |
| `p_valid_to` | date | — | NULL = no upper bound. `valid_to >= valid_from`. |

→ `{ok: true, id: uuid}`. Set: `approved_by = fn_current_user_id()`, `approved_at = now()`. **Art.171 ПК РК:** floor = TURAN association standard (защита фермера), не price-fixing.

### RPC-AC-7 `rpc_admin_set_reference_price` [ADMIN] ✅ Implemented

То же поведение что AC-6, но для `reference_prices`. Дополнительно set: `legal_disclaimer_shown = true`.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_category_id` | uuid | ✓ | — |
| `p_region_id` | uuid | — | NULL = национальная. |
| `p_price_per_kg` | int | ✓ | > 0. |
| `p_valid_from` | date | ✓ | — |
| `p_valid_to` | date | — | NULL = no upper bound. |

→ `{ok: true, id: uuid}`. **Art.171:** indicative-only; disclaimer mandatory на UI-уровне.

### RPC-AR-1 `rpc_admin_list_categories_with_stats` [ADMIN] ✅ Implemented (STABLE)

Возвращает TABLE для экрана A-CAT-01.

Columns: `id, code, name_ru, description_ru, sort_order, is_active, active_rule_count, sku_mapped_count, has_minimum_price, has_reference_price`. ORDER BY `sort_order, code`.

### RPC-AR-2 `rpc_admin_list_category_rules(p_category_id uuid)` [ADMIN] ✅ Implemented (STABLE)

Все версии правил для категории (для A-CAT-02). Columns: `id, version, breed_group, sex, age_min/max_months, weight_min/max_kg, bcs_min/max, priority, is_active, created_at`. ORDER BY `version DESC, priority DESC, created_at DESC`.

### RPC-AR-3 `rpc_admin_get_sku_coverage` [ADMIN] ✅ Implemented (STABLE)

30 SKU × текущий маппинг (для A-CAT-03). Columns: `tsp_sku_id, sku_code, breed_group, sex, age_group, weight_category, grade_code, map_id, category_id, category_code, category_name_ru`. `LEFT JOIN tsp_sku_category_map (is_active=true) LEFT JOIN livestock_categories`. NULL `category_id` ⇒ SKU ещё не замаплена. ORDER BY `s.sort_order, s.sku_code`.

### RPC-AR-4 `rpc_admin_list_prices(p_kind text)` [ADMIN] ✅ Implemented (STABLE)

Активные цены — minimum или reference (для A-CAT-04 двух табов).

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_kind` | text | ✓ | `minimum \| reference` (else `INVALID_INPUT`). |

Columns: `id, category_id, category_code, category_name_ru, region_id, region_name_ru, price_per_kg, valid_from, valid_to, is_active, approved_by, approved_at`. `WHERE is_active=true`. ORDER BY `lc.code, r.name_ru NULLS FIRST, valid_from DESC`. `region_name_ru IS NULL` ⇒ национальная строка.

---

### A-CAT интеграция с floor-clamp

После того как admin (CEO+зоолог) через A-CAT-03 наполнят `tsp_sku_category_map` (30 SKU → 5-8 категорий) И через A-CAT-04 зададут `minimum_prices`:
- `rpc_lower_batch_price` (RPC-M4-06) автоматически начинает clamp'ать к floor через bridge JOIN — **без redeploy**.
- `rpc_create_pool` (RPC-M4-01) автоматически начинает hard-block'ать pool_lines ниже floor через bridge resolve.

До наполнения: clamp = no-op (graceful degradation), система работает как до commit `0450823`.

---

## 5. Feed & Nutrition

### RPC-21 `rpc_upsert_feed_inventory` [WEB] [AI] 📋 Planned

Обновление запасов кормов на ферме (Layered Truth: data_source определяет confidence)

> ⚠️ **Confirmation required (AI):** Inventory update влияет на ration calculation и feed budget. AI использует `save_confirmation_payload` перед записью.

### RPC-22 `rpc_save_ration` [WEB] [AI] 📋 Planned

Сохранение варианта рациона → jsonb { ration_id }

*Создаёт новую RationVersion. Предыдущие версии сохраняются (append-only per D51).*

### RPC-23 `rpc_archive_ration` [WEB] [AI] 📋 Planned

Архивирование рациона → boolean

### RPC-24 `rpc_get_current_ration` [WEB] [AI] 📋 Planned

Текущий активный рацион → jsonb (ration + last_version + nutrient_summary)

> В AI Gateway аналог: AI-03 `rpc_get_feeding_plan` (более широкий контекст).

---

## 6. Veterinary

> ⚠️ **P-AI-4 (CRITICAL):** Дозировки лекарств ТОЛЬКО из таблицы `treatments` через `rpc_get_treatment_protocols`. AI никогда не генерирует дозировки самостоятельно (D61).

### RPC-25 `rpc_create_vet_case` [WEB] [AI] ✅ Implemented

Открытие ветеринарного случая → uuid (case_id)

> ⚠️ **C-AUDIT-6:** Renamed from `rpc_open_vet_case` (Dok 3 v1.3) to `rpc_create_vet_case` (canonical SQL name). При разработке использовать `rpc_create_vet_case`.

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | Владелец |
| `p_farm_id` | uuid | ✓ | Ферма |
| `p_herd_group_id` | uuid | — | Группа (уточняется после) |
| `p_symptoms_text` | text | ✓ | Свободное описание симптомов |
| `p_severity` | text | — | mild \| moderate \| severe \| critical |

**Поведение:** severity=critical → автоматически создаёт ConsultationRequest (escalation).

### RPC-26 `rpc_add_vet_diagnosis` [WEB] 📋 Planned

Добавление диагноза ветеринаром → uuid (diagnosis_id)

### RPC-27 `rpc_add_vet_recommendation` [WEB] 📋 Planned

Добавление рекомендации → uuid (recommendation_id)

*Если treatment_id указан и vet_product имеет withdrawal_period > 0 → автоматически создаёт health_restriction (D98).*

### RPC-28 `rpc_close_vet_case` [WEB] 📋 Planned

Закрытие случая → boolean

*При смерти животного: вызывает rpc_log_herd_event(event_type=death) для обновления Farm Graph.*

### RPC-29 `rpc_create_vaccination_plan` [WEB] [AI] 📋 Planned

Создание плана вакцинации из протокола → uuid (plan_id)

### RPC-30 `rpc_add_vaccination_plan_item` [WEB] 📋 Planned

Добавление пункта в план → uuid (plan_item_id)

### RPC-31 `rpc_record_vaccination` [WEB] [AI] 📋 Planned

Запись факта вакцинации → uuid (record_id)

*Автоматически закрывает plan_item. Если withdrawal_period > 0 → создаёт health_restriction.*

> В AI Gateway аналог: AI-12 `rpc_complete_vaccination_item`.

### RPC-32 `rpc_report_epidemic_signal` [AI] [ADMIN] 📋 Planned

Регистрация эпидемического сигнала → uuid (signal_id)

---

## 7. Operations

### RPC-33 `rpc_start_production_plan` [WEB] [AI] ✅ Implemented

Генерация плана из шаблона → uuid (plan_id)

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_farm_id` | uuid | ✓ | Ферма |
| `p_cycle_template_id` | uuid | ✓ | Шаблон производственного цикла |
| `p_cycle_start_date` | date | ✓ | Дата начала цикла |
| `p_expert_profile_id` | uuid | — | Прикреплённый зоотехник |
| `p_actor_id` | uuid | ✓ | Инициатор (service_role compat, C-NEW-7) |

*Внутренне вызывает `fn_generate_production_plan()` → создаёт FarmPhase и FarmTask по шаблону.*

### RPC-34 `rpc_complete_farm_task` [WEB] [AI] ✅ Implemented

Завершение задачи → jsonb { task_id, next_tasks[], kpi_updates[] }

| Параметр | Тип | Обяз. | Описание |
|----------|-----|-------|----------|
| `p_organization_id` | uuid | ✓ | — |
| `p_task_id` | uuid | ✓ | — |
| `p_result_data` | jsonb | — | Результат (вес, количество, заметки) |
| `p_completed_at` | timestamptz | — | default: now() |

**Триггер:** → `ops.task.completed` event → fn_farm_task_completed_event() → HerdEvent log

### RPC-35 `fn_shift_phase_cascade` [WEB] [AI] ✅ Implemented

Каскадный сдвиг дат фаз → jsonb [{ phase_id, phase_name, old_start, new_start, shift_days, date_type }]

| Параметр | Тип | Описание |
|----------|-----|----------|
| `p_phase_id` | uuid | Фаза-якорь, которую сдвигаем |
| `p_new_start_date` | date | Новая дата начала |
| `p_actor_id` | uuid | Для аудита |

> ⚠️ **Naming:** SQL canonical name = `fn_shift_phase_cascade`, вызов через `supabase.rpc("fn_shift_phase_cascade")`. Dok 3 v1.3 называл `rpc_shift_phase_cascade` — это неверно (D-NEW-A).

*Calendar и parallel фазы = якоря, каскад останавливается на них. Sequential фазы = сдвигаются.*

### RPC-36 `fn_preview_cascade` [WEB] [AI] ✅ Implemented

Превью каскада без изменений → TABLE (phase_id, phase_name, current_start, new_start, shift_days, date_type, depth)

*Показать фермеру список что изменится → он подтверждает → вызов RPC-35.*

### RPC-37 `rpc_get_active_plan` [WEB] [AI] 📋 Planned

Получение активного плана → jsonb

> В AI Gateway аналог: AI-06 `rpc_get_production_plan`.

---

## 8. Education

### RPC-38 `rpc_enroll_in_course` [WEB] [AI] 📋 Planned

Запись на курс → uuid (enrollment_id)

### RPC-39 `rpc_complete_lesson` [WEB] [AI] 📋 Planned

Завершение урока → jsonb { progress_pct, is_course_complete, certificate_id? }

*При is_course_complete=true → автоматически создаёт Certificate.*

---

## 9. Platform

### RPC-40 `rpc_start_ai_conversation` [AI] 📋 Planned

Инициализация AI-сессии → jsonb { conv_id, context: FarmSummary }

### RPC-41 `rpc_extract_farm_data_from_dialogue` [DEPRECATED] ⛔

**⛔ DEPRECATED с v1.3. НЕ РЕАЛИЗОВЫВАТЬ.**

Заменён двухшаговым extraction flow в Dok 5 §7:
- Run 1: AI вызывает individual tools (AI-02 rpc_upsert_herd_group, AI-07 rpc_create_vet_case и др.) → save_confirmation_payload
- Run 2: После подтверждения фермером → фактическая запись в БД

SQL-функция не существует ни в одном файле (d01–d07). Решение D117.

### RPC-42 `rpc_search_knowledge` [AI] 📋 Planned

Семантический поиск по KnowledgeChunk → TABLE (chunk_id, title, content, score, source_domain, metadata)

> В AI Gateway реализован как AI-14 `rpc_search_knowledge_chunks` (canonical SQL name).

### RPC-43 `rpc_create_proactive_alert` [AI] [ADMIN] 📋 Planned

Создание проактивного уведомления → jsonb { alert_id, requires_expert_approval }

### RPC-44 `rpc_add_knowledge_chunk` [ADMIN] 📋 Planned

Добавление чанка в базу знаний → uuid (chunk_id)

## 9b. Standards / Animal Taxonomy (ADR-ANIMAL-01, 2026-04-15)

Каноничный слой L1 + декларативные проекции L2 + мосты L4 для внешних систем.
Подробное обоснование и инварианты I1–I7 — см. `DECISIONS_LOG.md § 2026-04-15 ADR-ANIMAL-01` и Dok 1 §"Animal Taxonomy Lifecycle".

### RPC-T1 `rpc_list_animal_categories(p_at_date, p_include_deprecated)` [WEB] [AI] [ADMIN] ✅ Implemented

Возвращает активные L1 коды на дату. `p_include_deprecated=false` (default) скрывает депрекированные. Jsonb содержит `id` (с 2026-04-17, DEF-RATION-SAVE-01) — для UI-callers, которым нужен `animal_category_id` при сохранении связанных сущностей (например, `rpc_save_consulting_ration`).

**~~Legacy no-arg overload~~** ⛔ **DROPPED 2026-04-17** (DEF-RATION-SAVE-01). Два overload'а создавали ambiguity для PostgREST при вызове `supabase.rpc('rpc_list_animal_categories', {})` → `PGRST203 "Could not choose the best candidate function"`. 4 UI callers (`Calculator.tsx`, `RationTab.tsx`, `SimpleRationEditor.tsx`, `FeedReferenceAdmin.tsx`) теперь передают explicit params `{ p_at_date: null, p_include_deprecated: false }`.

### RPC-T2 `rpc_resolve_category(p_source_code, p_target_taxonomy, p_at_date)` [WEB] [AI] [BACKEND] ✅ Implemented

Возвращает каноничный target_code. Порядок: `is_primary DESC, valid_from DESC, target_code`. NULL если нет активной проекции.
Для many-to-many ответов — используйте RPC-T3.

### RPC-T3 `rpc_get_category_mappings(p_target_taxonomy, p_at_date)` [WEB] [AI] [BACKEND] ✅ Implemented

Возвращает полный набор активных L1→target пар для одной таксономии. Используется Python engine-ом и TS UI для read-through кэша на старт сессии.

### RPC-T4 `rpc_add_animal_category(p_code, p_name_ru, p_name_kk, p_sex, p_purpose, p_physiological_state, p_age_band, p_required_mappings, p_description_ru, p_sort_order)` [ADMIN] ✅ Implemented

Admin-only (guard: `fn_is_admin()`). Создаёт L1 код и обязательные L2 проекции. I3 invariant: `p_required_mappings` ДОЛЖНО содержать `feeding_group`, `turnover_key`, `market_sex`.

### RPC-T5 `rpc_deprecate_animal_category(p_code, p_replaced_by, p_valid_to)` [ADMIN] ✅ Implemented

Admin-only. Устанавливает `status='deprecated'`, `deprecated_at=now()`, `valid_to` на всех L2 проекциях. I1 invariant: НИКОГДА не удаляет.

### RPC-T6 `rpc_migrate_animal_category(p_from_code, p_to_code, p_strategy)` [ADMIN] ✅ Implemented

Admin-only. Перенос L3 `herd_groups` между L1 кодами. Стратегии: `auto_remap` (UPDATE FK с аудитом) или `flag_farmer_task` (создание FarmTask для ручного решения фермером).

### RPC-45 `rpc_restrict_organization` [ADMIN] 📋 Planned

Ограничение организации → uuid (restriction_id)

---

## 10. AI Gateway RPCs — детальное описание

> Все функции в d07_ai_gateway.sql. SECURITY DEFINER. Все проверяют farm ownership через `_ai_check_farm_org()`. AI Gateway добавляет `p_organization_id` из state — LLM никогда не передаёт org_id напрямую (D110).

### AI-01 `rpc_get_ai_farm_context` [AI] ✅ Implemented

Снимок контекста фермы для AI-сессии → jsonb

| Параметр | Тип | Описание |
|----------|-----|----------|
| `p_organization_id` | uuid | Из Gateway state (не от LLM) |
| `p_farm_id` | uuid | — |

Возвращает: farm details + herd_groups[] + active_production_plan + active_vet_cases[] + upcoming_vaccinations[] + upcoming_tasks[]

*Кешируется в AIConversation.farm_context_snapshot TTL 5 мин + invalidation по Event Bus.*

### AI-02 `rpc_upsert_herd_group` [AI] ✅ Implemented

Аналог RPC-06, оптимизирован для AI-extracted data. `data_source` автоматически = `ai_extracted`.

> ⚠️ Confirmation flow (D107): изменение > 5% поголовья требует подтверждения фермера.

### AI-07 `rpc_create_vet_case` [AI] ✅ Implemented

Аналог RPC-25. `herd_group_id` может быть null (уточняется в следующем run).

### AI-08 `rpc_add_vet_symptoms` [AI] ✅ Implemented

Добавление структурированных симптомов к vet case → jsonb { case_id, severity, escalate? }

| Параметр | Тип | Описание |
|----------|-----|----------|
| `p_vet_case_id` | uuid | — |
| `p_herd_group_id` | uuid | — |
| `p_symptoms` | text[] | Массив симптомов |
| `p_ai_message_id` | uuid | Трекинг источника (symptom_evidence) |

### AI-09 `rpc_get_vet_diagnosis` [AI] ✅ Implemented

Матрица симптомов → дифференциальный диагноз → jsonb { possible_diseases[], confidence_scores[], recommended_actions[] }

*Использует disease_symptoms матрицу. Confidence score = процент совпадающих симптомов.*

### AI-10 `rpc_get_treatment_protocols` [AI] ✅ Implemented

Протоколы лечения → jsonb [{ disease, drug_name, dosage_note: "назначает ветврач", withdrawal_days }]

> **P-AI-4:** `dosage_note` всегда = "дозировку определяет ветеринарный врач" или "см. инструкцию vet_products.dosage_reference_jsonb". AI никогда не генерирует числовые дозировки.

### AI-22 `rpc_update_conversation_language` [AI] ✅ Implemented

Обновление detected_language в AIConversation → boolean

| Параметр | Тип | Описание |
|----------|-----|----------|
| `p_conversation_id` | uuid | — |
| `p_language` | text | kz / ru / en |

*Вызывается из detect_and_cache_language. Заменяет прямой UPDATE (C-NEW-5, P-AI-1).*

---

## 10.4. Последовательность вызовов AI Gateway (типичный сценарий)

```
Inbound webhook:
  1. resolve_user_by_phone(p_phone) → user_id, org_id
  2. insert_user_message_dedup(p_conversation_id, p_message_id, ...) — dedup + save
  3. try_lock_conversation(p_lock_key) — advisory lock на conversation
  4. get_active_prompt(p_role) → system_prompt с версией
  5. rpc_get_ai_farm_context(p_organization_id, p_farm_id) → farm snapshot
  
  Agent loop:
  6. По намерению пользователя:
     - rpc_upsert_herd_group (AI-02) — update herd, requires confirmation
     - rpc_create_vet_case (AI-07) → rpc_add_vet_symptoms (AI-08)
     - rpc_get_treatment_protocols (AI-10) — always from DB (P-AI-4)
     - rpc_search_knowledge_chunks (AI-14) — RAG
     - rpc_create_batch (AI-20) — requires confirmation
     - fn_shift_phase_cascade (RPC-35) / fn_preview_cascade (RPC-36)
  
  7. Extraction → save_confirmation_payload (если нужно подтверждение)
  8. insert_ai_message — сохранить ответ AI с prompt_version
  9. rpc_update_conversation_language — если язык изменился
```

> ⚠️ **RPC-41 (`rpc_extract_farm_data_from_dialogue`) — DEPRECATED.** Extraction происходит через individual tools (шаг 6), не через один монолитный RPC.

---

## 11. Canonical RPC Name Registry

**Принцип D-NEW-A:** SQL-миграции — единственный канонический источник имён. Dok 3 и Dok 5 — производные.

Таблица `public.rpc_name_registry` в d01_kernel.sql содержит актуальный маппинг. При расхождении — `sql_name` выигрывает.

**Ключевые расхождения (исторические):**

| SQL-функция (canonical) | Dok 3 v1.3 имя | Статус | Примечание |
|-------------------------|----------------|--------|------------|
| `rpc_create_vet_case` | rpc_open_vet_case | ✅ Fixed v1.4 | C-AUDIT-6 |
| `fn_shift_phase_cascade` | rpc_shift_phase_cascade | ✅ Fixed v1.4 | fn_ prefix = SECURITY DEFINER, callable |
| `fn_preview_cascade` | rpc_preview_cascade | ✅ Fixed v1.4 | fn_ prefix = SECURITY DEFINER, callable |
| `rpc_search_knowledge_chunks` | rpc_search_knowledge | ✅ Fixed v1.4 | AI-14 canonical |
| `rpc_get_ai_farm_context` | *(не было в Dok 3)* | ✅ Added v1.4 | AI-01, только AI Gateway |
| `rpc_list_animal_categories(date, bool)` | *(новая — ADR-ANIMAL-01)* | ✅ Added 2026-04-15; updated 2026-04-17 | RPC-T1 temporal (d01_kernel). Включает `id` в jsonb с 2026-04-17. d03 legacy no-arg wrapper ⛔ DROPPED 2026-04-17 (DEF-RATION-SAVE-01). |
| `rpc_resolve_category` | *(новая — ADR-ANIMAL-01)* | ✅ Added 2026-04-15 | RPC-T2, deterministic via is_primary |
| `rpc_get_category_mappings` | *(новая — ADR-ANIMAL-01)* | ✅ Added 2026-04-15 | RPC-T3 |
| `rpc_add_animal_category` | *(новая — ADR-ANIMAL-01)* | ✅ Added 2026-04-15 | RPC-T4, admin-only |
| `rpc_deprecate_animal_category` | *(новая — ADR-ANIMAL-01)* | ✅ Added 2026-04-15 | RPC-T5, admin-only |
| `rpc_migrate_animal_category` | *(новая — ADR-ANIMAL-01)* | ✅ Added 2026-04-15 | RPC-T6, admin-only |
| `rpc_get_production_plan` | rpc_get_active_plan | ⚠️ Dual | RPC-37 = planned web version; AI-06 = implemented AI version |
| ~~`rpc_extract_farm_data_from_dialogue`~~ | rpc_extract_farm_data_from_dialogue | ⛔ DEPRECATED | не существует в SQL |

**Правило:** Если имя в коде расходится с `sql_name` в rpc_name_registry → это баг. Открыть issue.

---

## 12. Внутренние функции

### Trigger-функции (вызываются только через TRIGGER, не из приложения)

```
fn_set_updated_at                    — updated_at триггер на всех таблицах
fn_log_price_grid_change             — → price_grid_log
fn_ration_version_set_current        — новая версия → is_current=true, старые=false
fn_ration_auto_activate              — первая версия → ration.status=active
fn_update_feeding_period_statuses    — статусы периодов по датам
fn_vet_case_auto_escalate            — severity=critical → ConsultationRequest
fn_disease_create_knowledge_chunk    — Disease → KnowledgeChunk (RAG)
fn_create_health_restriction_from_rec — VetRecommendation → HealthRestriction
fn_vaccination_record_complete_plan_item — Vaccination → VaccPlanItem.status=completed
fn_check_vaccination_plan_readiness  — все items done → plan.status=completed
fn_check_epidemic_thresholds         — VetCase insert → EpidemicSignal если порог достигнут
fn_vet_case_progress_on_diagnosis    — diagnosis added → case.status=in_progress
fn_sop_create_knowledge_chunk        — SOPDocument → KnowledgeChunk (AI finds SOPs)
fn_course_create_knowledge_chunk     — Course lesson → KnowledgeChunk
fn_update_enrollment_progress        — UserProgress → CourseEnrollment.progress_pct
fn_farm_task_completed_event         — FarmTask.completed → HerdEvent (cross-domain)
fn_evaluate_farm_kpi                 — FarmTask.completed → FarmKPI recalculate
fn_audit_from_platform_event         — PlatformEvent.is_audit=true → AuditLog
fn_generate_production_plan          — генерирует FarmPhase + FarmTask из шаблона
fn_shift_phase_cascade               — каскад дат (SECURITY DEFINER, callable as RPC-35)
fn_preview_cascade                   — превью каскада (SECURITY DEFINER, callable as RPC-36)
```

### RLS-хелперы (используются в POLICY, не из приложения)

```
fn_current_user_id()      — текущий user_id из JWT
fn_my_org_ids()           — uuid[] организаций пользователя (JWT fast path, D-NEW-1)
fn_is_admin()             — проверка admin_roles
fn_is_expert()            — проверка expert_profiles
fn_org_is_restricted()    — проверка restriction_records
```

### AI Gateway internal helpers

```
get_active_prompt(p_role)                       — системный промпт по роли из ai_prompts
try_lock_conversation(p_lock_key, p_identifier) — advisory xact lock
release_conversation_lock(p_lock_key)           — явное освобождение
insert_user_message_dedup(...)                  — dedup + atomic sequence + save user msg
insert_ai_message(...)                          — save assistant/tool/system msg
claim_pending_notifications(p_worker_id, n)     — SKIP LOCKED batch claim
mark_notification_sent(...)                     — confirmed delivery
mark_notification_failed(...)                   — failed, retry или permanent fail
invalidate_ai_context(p_organization_id)        — сброс farm_context_snapshot TTL
resolve_user_by_phone(p_phone)                  — WhatsApp webhook → user_id, org_id
fn_auth_custom_claims(event jsonb)              — Supabase Auth hook: JWT + org_ids claims
```

---

## 13. RPC Development Priority

Порядок реализации **Planned** функций по доменам (sprint-план):

**Sprint 1: Identity + Farm (базовый онбординг)**
- RPC-01 `rpc_register_organization`
- RPC-02 `rpc_submit_membership_application`
- RPC-03 `rpc_process_membership_application`
- RPC-04 `rpc_get_my_context`
- RPC-05 `rpc_upsert_farm` + RPC-05b `rpc_set_farm_activity_types`
- RPC-07 `rpc_log_herd_event`
- RPC-08 `rpc_get_farm_summary`

**Sprint 2: Veterinary (core AI use case)**
- RPC-26 `rpc_add_vet_diagnosis`
- RPC-27 `rpc_add_vet_recommendation`
- RPC-28 `rpc_close_vet_case`
- RPC-29 `rpc_create_vaccination_plan`
- RPC-31 `rpc_record_vaccination`
- RPC-32 `rpc_report_epidemic_signal`

**Sprint 3: Feed & Nutrition**
- RPC-21 `rpc_upsert_feed_inventory`
- RPC-22 `rpc_save_ration`
- RPC-23 `rpc_archive_ration`
- RPC-24 `rpc_get_current_ration`

**Sprint 4: Operations**
- RPC-37 `rpc_get_active_plan`

**Sprint 5: Market / TSP**
- RPC-11..RPC-20 (согласно бизнес-приоритету TSP)

**Sprint 6: Education + Platform**
- RPC-38..RPC-45 (Education + Platform helpers)

**Slice 8: Feed Reference + Consulting Ration**
- RPC-F01 `rpc_list_feed_items` (verify/create)
- RPC-F02 `rpc_list_animal_categories` (verify/create)
- RPC-F03 `rpc_upsert_feed_item`
- RPC-F04 `rpc_upsert_feed_price`
- RPC-F05 `rpc_upsert_feed_consumption_norm`
- C-RPC-09 `rpc_save_consulting_ration`
- C-RPC-10 `rpc_get_consulting_rations`

---

## 13b. Slice 8 RPCs — Feed Reference + Consulting Ration

> Добавлено: 2026-04-09 · Решение: D-S8-1, D-S8-3, D-S8-4

### Feed Reference Admin RPCs (d03_feed.sql)

| RPC ID | Функция | File | Caller | Status |
|--------|---------|------|--------|--------|
| RPC-F01 | `rpc_list_feed_items` | d03_feed.sql | UI Calculator, Admin | ✅ Implemented (2026-04-09) — DEF-027 fix |
| RPC-F02 | `rpc_list_animal_categories(p_at_date, p_include_deprecated)` | d01_kernel.sql (canonical) | UI Calculator, Admin, RationTab, SimpleRationEditor | ✅ Canonical in d01 since 2026-04-15 (ADR-ANIMAL-01); d03 no-arg wrapper dropped 2026-04-17 (DEF-RATION-SAVE-01) |
| RPC-F03 | `rpc_upsert_feed_item` | d03_feed.sql | Admin UI `/admin/feeds` | ✅ Implemented (2026-04-09) |
| RPC-F04 | `rpc_upsert_feed_price` | d03_feed.sql | Admin UI `/admin/feeds` | ✅ Implemented (2026-04-09) |
| RPC-F05 | `rpc_upsert_feed_consumption_norm` | d03_feed.sql | Admin UI `/admin/feeds` | ✅ Implemented (2026-04-09) |
| RPC-F06 | `rpc_list_feed_categories` | d03_feed.sql | Admin UI `/admin/feeds` | ✅ Implemented (2026-04-09) |
| RPC-F07 | `rpc_list_feed_consumption_norms` | d03_feed.sql | Admin UI `/admin/feeds` | ✅ Implemented (2026-04-09) |

**`rpc_upsert_feed_item` signature:**
```sql
rpc_upsert_feed_item(
    p_feed_item_id          uuid DEFAULT NULL,
    p_feed_category_code    text,
    p_code                  text,
    p_name_ru               text,
    p_nutrient_composition  jsonb DEFAULT '{}',
    p_is_validated          boolean DEFAULT false,
    p_notes                 text DEFAULT NULL
) RETURNS uuid
```

**`rpc_upsert_feed_price` signature:**
```sql
rpc_upsert_feed_price(
    p_feed_item_id  uuid,
    p_price_per_kg  numeric,
    p_region_id     uuid DEFAULT NULL,
    p_valid_from    date DEFAULT CURRENT_DATE,
    p_valid_to      date DEFAULT NULL,
    p_currency      text DEFAULT 'KZT'
) RETURNS uuid
```

**`rpc_upsert_feed_consumption_norm` signature:**
```sql
rpc_upsert_feed_consumption_norm(
    p_norm_id               uuid DEFAULT NULL,
    p_farm_type             text,
    p_animal_category_id    uuid,
    p_season                text,
    p_items                 jsonb,
    p_valid_from            date DEFAULT CURRENT_DATE,
    p_valid_to              date DEFAULT NULL,
    p_notes                 text DEFAULT NULL
) RETURNS uuid
```

### Consulting Ration RPCs (d09_consulting.sql)

| RPC ID | Функция | File | Caller | Status |
|--------|---------|------|--------|--------|
| C-RPC-09 | `rpc_save_consulting_ration` | d09_consulting.sql | Edge Function `calculate-ration` (consulting ctx), SimpleRationEditor | ✅ Implemented (2026-04-09). Устанавливает `consulting_projects.needs_recalc=true`. |
| C-RPC-10 | `rpc_get_consulting_rations` | d09_consulting.sql | UI RationTab, Python consulting_engine (Priority 1) | ✅ Implemented (2026-04-09). **Auth helpers `fn_my_org_ids()/fn_is_admin()` removed 2026-04-17 (DEF-CONSULTING-AUTH-01)** — они возвращали false при вызове из service_role (`auth.uid()=null`), из-за чего RPC raised UNAUTHORIZED и `calculate.py` молча падал в Priority 2. Защита через `consulting_projects.id = p_consulting_project_id AND organization_id = p_organization_id` сохранена. |

**`rpc_save_consulting_ration` signature:**
```sql
rpc_save_consulting_ration(
    p_organization_id           uuid,
    p_consulting_project_id     uuid,
    p_animal_category_id        uuid,
    p_items                     jsonb,
    p_results                   jsonb
) RETURNS uuid  -- ration_version_id
-- INSERT INTO ration_versions (consulting_project_id, context_animal_category_id, ...)
```

**`rpc_get_consulting_rations` signature:**
```sql
rpc_get_consulting_rations(
    p_organization_id           uuid,
    p_consulting_project_id     uuid
) RETURNS jsonb
-- [{animal_category_id, animal_category_name, ration_version_id, version_number, items, results, created_at}]
-- Последняя версия per animal_category
```

---

## 13c. CAPEX Module RPCs — ADR-CAPEX-01 (2026-04-17)

5 RPCs добавлены в `d09_consulting.sql` для data-driven CAPEX engine. См.
Dok 7 §11 для полного архитектурного контекста.

### Lookup RPCs (public read)

| RPC ID | Функция | File | Caller | Status |
|--------|---------|------|--------|--------|
| RPC-CAPEX-1 | `rpc_list_construction_materials` | d09_consulting.sql | UI ProjectWizard + CapexTab material selectors, `/admin/capex` | ✅ Implemented (2026-04-17) |
| RPC-CAPEX-2 | `rpc_list_infrastructure_norms` | d09_consulting.sql | UI `/admin/capex` | ✅ Implemented (2026-04-17) |

**`rpc_list_construction_materials` signature:**
```sql
rpc_list_construction_materials() RETURNS jsonb
-- [{code, name_ru, cost_per_m2, currency, valid_from, valid_to}, ...] ordered by price asc
-- Reads category='construction_materials' from consulting_reference_data
-- STABLE, readable to authenticated
```

**`rpc_list_infrastructure_norms` signature:**
```sql
rpc_list_infrastructure_norms() RETURNS jsonb
-- {farm: [...], pasture: [...], equipment: [...], tools: [...]}
-- Grouped by data.block, each item: {code, data, valid_from, valid_to}, sorted by display_order
-- STABLE, readable to authenticated
```

### Admin CRUD RPCs (fn_is_admin guard)

| RPC ID | Функция | File | Caller | Status |
|--------|---------|------|--------|--------|
| RPC-CAPEX-3 | `rpc_upsert_construction_material` | d09_consulting.sql | UI `/admin/capex` | ✅ Implemented (2026-04-17) |
| RPC-CAPEX-4 | `rpc_upsert_infrastructure_norm` | d09_consulting.sql | UI `/admin/capex` | ✅ Implemented (2026-04-17) |

**`rpc_upsert_construction_material` signature:**
```sql
rpc_upsert_construction_material(
    p_code        text,     -- e.g., 'sandwich', 'brick'
    p_name_ru     text,
    p_cost_per_m2 numeric   -- тг/м²
) RETURNS int  -- consulting_reference_data.id
-- Raises ADMIN_REQUIRED if not fn_is_admin()
-- Raises INVALID_COST if p_cost_per_m2 < 0
```

**`rpc_upsert_infrastructure_norm` signature:**
```sql
rpc_upsert_infrastructure_norm(
    p_code  text,    -- e.g., 'FAC-001', 'PST-002'
    p_data  jsonb,   -- see Dok 7 §11.3-§11.5 for JSONB shape
    p_block text     -- optional: farm|pasture|equipment|tools; can also be inside p_data.block
) RETURNS int
-- Raises ADMIN_REQUIRED, BLOCK_REQUIRED, INVALID_BLOCK
```

### Project-scoped override save (ownership guard)

| RPC ID | Функция | File | Caller | Status |
|--------|---------|------|--------|--------|
| RPC-CAPEX-5 | `rpc_save_project_infra_override` | d09_consulting.sql | UI ProjectWizard (save materials) + CapexTab (save overrides) | ✅ Implemented (2026-04-17) |

**`rpc_save_project_infra_override` signature (ADR-CAPEX-02, 2026-04-18):**
```sql
rpc_save_project_infra_override(
    p_organization_id uuid,
    p_project_id      uuid,
    p_enclosed        text   default null,       -- nullable: preserves existing on null
    p_support         text   default null,       -- nullable: preserves existing on null
    p_overrides       jsonb  default null        -- nullable: preserves existing on null (ADR-CAPEX-02)
) RETURNS boolean
-- UPDATE consulting_projects SET
--   construction_material_enclosed = COALESCE(p_enclosed, ...),
--   construction_material_support  = COALESCE(p_support, ...),
--   infra_items_override           = COALESCE(p_overrides, ...),   -- null-preserve
--   needs_recalc                   = true;
-- Emits Dok4 event: consulting.capex_override.saved
-- Raises PROJECT_NOT_FOUND, MATERIAL_NOT_FOUND, INVALID_OVERRIDES (non-null non-array only)
```

**NULL-preserve semantics:**
- `p_overrides=null`   → preserves existing array (wizard changes materials without touching CapexTab edits)
- `p_overrides=[]`     → resets overrides to empty array
- `p_overrides=[...]`  → replaces overrides (CapexTab save path)

**Override array shape** (per-item, всё опционально кроме code):
```json
[
  {
    "code": "FAC-015",
    "include": false,                  // optional
    "qty_override": 8,                 // optional
    "material_override": "brick",      // optional — must be a valid material code
    "unit_cost_override": 25000        // optional — overrides unit_cost / fixed_cost
  }
]
```

**Legacy limitation (resolved in ADR-CAPEX-02):** Phase 1 (commit `cfce152`) shipped
with `p_overrides default '[]'::jsonb`, which forced wizard to pass a stale overrides
snapshot to avoid wiping CapexTab edits (L-P3-WIZARD race). Phase 2 fix (commit
`174485f`) changed the default to `null` + added COALESCE preserve logic. Wizard now
passes `p_overrides: null` (commit `8bf5339`). L-P3-WIZARD closed.

---

### RPC-CAPEX-6 — list capex surcharges (ADR-CAPEX-02, 2026-04-18)

| RPC ID | Функция | File | Caller | Status |
|--------|---------|------|--------|--------|
| RPC-CAPEX-6 | `rpc_list_capex_surcharges()` | d09_consulting.sql | UI `/admin/capex/surcharges` (CapexSurchargesTab) | ✅ Implemented (2026-04-18) |

**Signature:**
```sql
rpc_list_capex_surcharges() RETURNS jsonb
-- [{id, code, data, valid_from, valid_to}] ordered by valid_from desc
-- Reads category='capex_surcharges' from consulting_reference_data
-- STABLE, readable to authenticated. No org scoping (reference data).
```

**Rationale:** replaces direct `.from('consulting_reference_data').select()` fallback
used in CapexSurchargesTab (L-P4-1 tech debt from ADR-CAPEX-01 shipping). UI now
follows the «every data fetch = one RPC call» principle consistently.

---

### Consulting Livestock Prices RPCs (ADR-PRICES-01, 2026-04-18)

| RPC ID | Функция | File | Caller | Status |
|--------|---------|------|--------|--------|
| RPC-PRICES-1 | `rpc_list_livestock_prices(p_organization_id, p_as_of_date)` | d09_consulting.sql | engine (Priority 2), ProjectWizard (placeholder hint), LivestockPricesAdmin | ✅ Implemented (2026-04-18) |
| RPC-PRICES-2 | `rpc_upsert_livestock_price(p_code, p_livestock_category, p_year, p_price_per_kg, p_region_id, p_age_months, p_source, p_valid_from)` | d09_consulting.sql | LivestockPricesAdmin (admin UI) | ✅ Implemented (2026-04-18) |
| RPC-PRICES-3 | `rpc_retire_livestock_price(p_code)` | d09_consulting.sql | LivestockPricesAdmin (admin UI) | ✅ Implemented (2026-04-18) |

**Signatures:**
```sql
-- RPC-PRICES-1 (public read, STABLE, SECURITY DEFINER, no org scoping)
rpc_list_livestock_prices(
    p_organization_id uuid DEFAULT NULL,  -- reserved for future per-org overrides
    p_as_of_date      date DEFAULT current_date
) RETURNS jsonb
-- [{code, livestock_category, year, region_id, age_months, price_per_kg, currency, source, valid_from, valid_to}]
-- Reads category='livestock_prices' from consulting_reference_data
-- Temporal filter: valid_from <= p_as_of_date AND (valid_to IS NULL OR valid_to > p_as_of_date)

-- RPC-PRICES-2 (admin write, fn_is_admin() guard)
rpc_upsert_livestock_price(
    p_code               text,
    p_livestock_category text,       -- {steer_own | heifer_breeding | cow_culled | bull_culled}
    p_year               int,
    p_price_per_kg       numeric,    -- > 0
    p_region_id          uuid DEFAULT NULL,  -- MVP always NULL
    p_age_months         int  DEFAULT NULL,  -- reserved for ADR-PRICES-02 per-strategy
    p_source             text DEFAULT NULL,
    p_valid_from         date DEFAULT current_date
) RETURNS int  -- row id

-- RPC-PRICES-3 (admin write, fn_is_admin() guard)
rpc_retire_livestock_price(p_code text) RETURNS int  -- soft-delete: sets valid_to = yesterday
```

**Engine Priority chain** (mirrors ADR-FEED-03):
1. **P1** — project override: `ProjectInput.price_*_per_kg` not null
2. **P2** — DB reference: row with matching `livestock_category + year` (MVP: region_id + age_months must be NULL)
3. **P3** — safety default: hardcoded `{steer_own: 1800, heifer_breeding: 2200, cow_culled: 1800, bull_culled: 2000}`

**Resolver:** [consulting_engine/app/engine/price_resolver.py](consulting_engine/app/engine/price_resolver.py) invoked from `orchestrator.py` after `validate_and_enrich_input`.

**UI:**
- `/admin/livestock-prices` — CRUD admin page ([LivestockPricesAdmin.tsx](src/pages/admin/livestock-prices/LivestockPricesAdmin.tsx))
- ProjectWizard Step 3 (Технология) — price fields are nullable; placeholder shows catalog value

**Seed:** 4 rows for year 2026, KZ-national (no region, no age) — matches prior DEF-REVENUE-PRICES-01 defaults.

---

## 14. Decisions Log (Dok 3)

| # | Решение | Почему |
|---|---------|--------|
| D-NEW-A | SQL-миграции = canonical source of truth для имён RPC | Имена в Dok 3 и Dok 5 могут отставать. rpc_name_registry таблица в БД = живой truth |
| D117 | Confirmation flow двухходовой (два run) | WhatsApp: один webhook = один sync run. Нельзя await ответ пользователя |
| D-ARCH-1 | AI Gateway RPCs = отдельная секция d07_ai_gateway.sql | Web RPCs (d02-d05) и AI RPCs (d07) имеют разную security модель |
| D-ARCH-2 | fn_ prefix ≠ "не-callable" | fn_shift_phase_cascade, fn_preview_cascade имеют SECURITY DEFINER и callable via supabase.rpc() |

---

## 15. Open Questions (актуальные)

| # | Вопрос | Блокирует |
|---|--------|-----------|
| Q-RPC-01 | `rpc_get_active_plan` (RPC-37) vs `rpc_get_production_plan` (AI-06): два имени одной функции? Нужна одна реализация или две? | Sprint 1 planning |
| Q-RPC-02 | `rpc_search_knowledge` (RPC-42) vs `rpc_search_knowledge_chunks` (AI-14): объединить в одну функцию с флагом caller? | Sprint 6 |
| Q-RPC-03 | `rpc_get_price_for_sku` (RPC-17) vs `rpc_get_price_grid` (AI-16): дублирование? Уточнить ownership | Sprint 5 TSP |
| Q-RPC-04 | RPC-30 `rpc_add_vaccination_plan_item` — нужен ли в Sprint 2, или только rpc_create_vaccination_plan? | Sprint 2 |

---

## История изменений

| Версия | Дата | Автор | Изменения |
|--------|------|-------|-----------|
| v1.1 | Февраль 2026 | CTO | Initial catalog |
| v1.2 | Февраль 2026 | CTO | Feed, Vet, Operations RPCs |
| v1.3 | Март 2026 | CTO | event_type canonical (→ domain.entity.action per Dok 4) |
| v1.4 | Март 2026 | CTO | Architecture Audit + Schema Consolidation: RPC-25 rename, RPC-41 deprecated, 22 AI Gateway RPCs added, Canonical Name Registry, status marking, D-NEW-A |

---

## Приложение A: Edge Functions / FastAPI

Эти функции НЕ PostgreSQL RPC. Реализованы в Python AI Gateway (FastAPI):

| Функция | Где | Описание |
|---------|-----|----------|
| `calculate_ration` | FastAPI + Supabase Edge | NASEM LP-оптимизация рациона. Input: animal_category, weight, feeds[]. Output: RationVersion с нутриентным балансом |
| `get_feed_budget` | FastAPI | Годовая потребность и дефицит по кормам |
| `get_nutrient_balance` | FastAPI | Баланс нутриентов по RationVersion |
| `proactive_dispatch` | pg_cron + FastAPI | Батч обработки pending notifications. SKIP LOCKED, batch=50 |

*Код EXTRACTION_RULES (правила извлечения сущностей из диалога) — Python, файл: `ai_gateway/extraction/rules.py`.*

---

*Dok 3 RPC Catalog v1.4 | TURAN AgOS | 5 March 2026*
*SQL source of truth: d01_kernel.sql, d02_tsp.sql, d03_feed.sql, d04_vet.sql, d05_ops_edu.sql, d07_ai_gateway.sql*
