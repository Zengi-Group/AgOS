# Dok 6 — Interface Contracts: Slice 6a "Эксперт-консоль"

> Version: 1.0 | Date: 2026-03-31
> Author: Architect Agent
> Status: DRAFT — CTO decisions inline
>
> **Scope:** 6 expert screens (M01–M06) + 3 admin screens (A03–A05).
> **User story:** Expert manages vet cases, vaccination plans, epidemic signals, KPIs. Admin manages knowledge base, restrictions, audit.

---

## Design System

Expert (M-series) and Admin (A-series) screens use **neutral `.light` palette** — data-dense, professional layouts.

---

## Navigation Structure

```
/admin
├── /admin/expert/queue        → M01 (Vet Case Queue)
├── /admin/expert/case/:id     → M02 (Case Consultation)
├── /admin/expert/vaccination  → M03 (Vaccination Plans)
├── /admin/expert/vaccination/:planId/record → M04 (Record Vaccination)
├── /admin/expert/epidemic     → M05 (Epidemic Signals)
├── /admin/expert/kpi          → M06 (Expert KPI)
├── /admin/knowledge           → A03 (Knowledge Base)
├── /admin/restrictions        → A04 (Restrictions)
└── /admin/audit               → A05 (Audit Log)
```

---

## M01 — Очередь ветеринарных кейсов

### Meta

| Field | Value |
|-------|-------|
| Screen ID | M01 |
| Route | `/admin/expert/queue` |
| Auth | `fn_is_expert()` — redirect if false |
| User story | Эксперт видит все открытые вет. кейсы по своим регионам: сортировка по severity, статус, дата. |
| RPCs | `rpc_get_vet_case_detail` (existing, d04) for list mode; new list RPC or reuse with filters |

### UI Components

```
M01-VetCaseQueue
├── Header "Ветеринарные кейсы" + StatusFilter (open|in_progress|escalated|all)
├── SeverityTabs (critical → severe → moderate → mild)
├── CaseCard[] (per case)
│   ├── FarmName + OrganizationName
│   ├── SeverityBadge (color-coded)
│   ├── StatusBadge (open|in_progress|escalated)
│   ├── SymptomsPreview (first 100 chars)
│   ├── AffectedHeads count
│   ├── CreatedAt (relative)
│   └── Click → M02
└── EmptyState "Нет открытых кейсов"
```

### Data: Uses `rpc_list_vet_cases` (READ-RPC, see D-S6a-FIX-1) with expert RLS. `rpc_get_vet_case_detail` requires a valid `case_id` and raises `VET_CASE_NOT_FOUND` when called without one — it cannot be used as a list endpoint.

### CTO Decision D-S6-1 (superseded for M01, M03, M05 by D-S6a-FIX-1): Expert/Admin list screens originally planned to use `.from()` with admin/expert RLS policies. Superseded for M-series vet screens — see D-S6a-FIX-1 below.

---

## M02 — Консультация (Case Detail)

### Meta

| Field | Value |
|-------|-------|
| Screen ID | M02 |
| Route | `/admin/expert/case/:caseId` |
| Auth | `fn_is_expert()` |
| User story | Эксперт видит полный кейс: симптомы, диагнозы, рекомендации. Может добавить диагноз, рекомендацию, закрыть кейс. |
| RPCs | `rpc_get_vet_case_detail` (existing), `rpc_add_vet_diagnosis` (RPC-26, existing), `rpc_add_vet_recommendation` (RPC-27, existing), `rpc_close_vet_case` (RPC-28, new) |

### User Flow

```
1. Load case detail via rpc_get_vet_case_detail
2. Display: symptoms, evidence, diagnoses[], recommendations[], timeline
3. Actions:
   - "Добавить диагноз" → inline form (disease_id, text, confidence, is_final)
   - "Добавить рекомендацию" → inline form (treatment, dosage_note from DB only!)
   - "Закрыть кейс" → rpc_close_vet_case (outcome: recovered|died|referral)
```

### P-AI-4 CRITICAL: Dosage display ONLY from `rpc_add_vet_recommendation` result. UI NEVER lets expert type free-form dosage that bypasses DB validation.

---

## M03 — Планы вакцинации

### Meta

| Field | Value |
|-------|-------|
| Screen ID | M03 |
| Route | `/admin/expert/vaccination` |
| Auth | `fn_is_expert()` |
| User story | Эксперт видит планы вакцинации по фермам. Может создать план из протокола, просмотреть статус пунктов. |
| RPCs | `rpc_create_vaccination_plan` (RPC-29, new) for creating; `.from('vaccination_plans')` for listing |

### UI Components

```
M03-VaccinationPlans
├── Header "Планы вакцинации" + "Создать план" button
├── PlanCard[] (per plan)
│   ├── FarmName + PlanYear
│   ├── StatusBadge (pending_review|active|completed|expired)
│   ├── ItemsSummary (N scheduled, M completed, K overdue)
│   ├── Click → expand items list
│   └── "Записать вакцинацию" → M04
├── CreatePlanDialog
│   ├── FarmSelect
│   ├── ProtocolSelect (from vaccination_protocols)
│   ├── PlanYear input
│   └── Submit → rpc_create_vaccination_plan
└── EmptyState "Нет планов вакцинации"
```

---

## M04 — Запись вакцинации

### Meta

| Field | Value |
|-------|-------|
| Screen ID | M04 |
| Route | `/admin/expert/vaccination/:planId/record` |
| Auth | `fn_is_expert()` |
| User story | Эксперт записывает факт вакцинации: выбирает пункт плана, вводит данные. |
| RPCs | `rpc_record_vaccination` (RPC-31, new) |

### User Flow

```
1. Load plan items (scheduled/reminded status)
2. Select item to record
3. Form:
   - vet_product_id (from vet_products where product_type='vaccine')
   - actual_heads_vaccinated (int)
   - vaccine_batch_number (text, D101 export cert)
   - administered_date (date, default today)
4. Submit → rpc_record_vaccination
5. Warning if withdrawal_period > 0: "Будет создано ограничение на N дней"
```

---

## M05 — Эпидемиологические сигналы

### Meta

| Field | Value |
|-------|-------|
| Screen ID | M05 |
| Route | `/admin/expert/epidemic` |
| Auth | `fn_is_expert()` |
| User story | Эксперт видит эпидемиологические сигналы, может подтвердить или отклонить. |
| RPCs | `rpc_report_epidemic_signal` (RPC-32, new) for reporting; `.from('epidemic_signals')` for listing |

### UI Components

```
M05-EpidemicSignals
├── Header "Эпидемиология" + "Сообщить" button
├── SignalCard[] (per signal)
│   ├── RegionName + DiseaseName
│   ├── SeverityBadge (watch|warning|alert|emergency)
│   ├── StatusBadge (detected|confirmed|false_positive|resolved)
│   ├── CaseCount + TimeWindow
│   └── Actions: Confirm | Reject (false_positive)
├── ReportDialog (new signal form)
└── EmptyState "Нет активных сигналов"
```

---

## M06 — KPI эксперта

### Meta

| Field | Value |
|-------|-------|
| Screen ID | M06 |
| Route | `/admin/expert/kpi` |
| Auth | `fn_is_expert()` |
| User story | Эксперт видит свои показатели: кол-во консультаций, среднее время ответа, закрытые кейсы. |

### Data: Computed from `expert_profiles` (total_consultations, avg_response_minutes) + aggregated vet_cases counts.

### UI Components

```
M06-ExpertKpi
├── Header "Мои показатели"
├── StatsGrid
│   ├── TotalConsultations
│   ├── AvgResponseMinutes
│   ├── OpenCases
│   └── ClosedThisMonth
├── RecentCasesTable (last 10 closed)
└── EmptyState (new expert, no data yet)
```

---

## A03 — База знаний

### Meta

| Field | Value |
|-------|-------|
| Screen ID | A03 |
| Route | `/admin/knowledge` |
| Auth | `fn_is_admin()` |
| User story | Админ управляет базой знаний: добавляет, редактирует чанки для AI RAG. |
| RPCs | `rpc_add_knowledge_chunk` (RPC-44, new) for create; `.from('knowledge_chunks')` for list |

### UI Components

```
A03-KnowledgeBase
├── Header "База знаний" + "Добавить" button
├── SearchInput (filter by title/domain)
├── ChunkCard[] (per chunk)
│   ├── Title + SourceDomain badge
│   ├── ContentPreview (first 200 chars)
│   ├── Language badge (ru|kk)
│   └── EditButton
├── AddChunkDialog
│   ├── Title, Content (textarea), SourceDomain select, Language
│   └── Submit → rpc_add_knowledge_chunk
└── EmptyState "База знаний пуста"
```

---

## A04 — Ограничения

### Meta

| Field | Value |
|-------|-------|
| Screen ID | A04 |
| Route | `/admin/restrictions` |
| Auth | `fn_is_admin()` |
| User story | Админ видит активные ограничения (карантин, период ожидания). Может создать или снять ограничение. |
| RPCs | `rpc_restrict_organization` (RPC-45, new) for create; `.from('health_restrictions')` for list |

### UI Components

```
A04-Restrictions
├── Header "Ограничения" + "Создать" button
├── ActiveRestrictions[] (is_active=true)
│   ├── OrgName + RestrictionType badge
│   ├── Reason + ValidUntil
│   └── "Снять" button (deactivate early)
├── ExpiredRestrictions (collapsible, is_active=false)
├── CreateDialog
│   ├── OrganizationSelect
│   ├── RestrictionType select (withdrawal_period|quarantine|health_investigation)
│   ├── ValidUntil date
│   ├── Reason textarea
│   └── Submit → rpc_restrict_organization
└── EmptyState "Нет активных ограничений"
```

---

## A05 — Аудит лог

### Meta

| Field | Value |
|-------|-------|
| Screen ID | A05 |
| Route | `/admin/audit` |
| Auth | `fn_is_admin()` |
| User story | Админ просматривает журнал аудита: кто, когда, что сделал. Read-only. |

### Data: `.from('audit_log')` with admin RLS. Paginated, filterable.

### UI Components

```
A05-AuditLog
├── Header "Журнал аудита"
├── Filters (date range, entity_type, action)
├── AuditTable (paginated)
│   ├── Timestamp
│   ├── ActorType + ActorName
│   ├── Action (event_type)
│   ├── EntityType + EntityId
│   └── DetailsExpander (payload jsonb)
└── EmptyState "Нет записей за период"
```

---

## RPC Implementation Plan

| RPC | Screen | Status | File | Notes |
|-----|--------|--------|------|-------|
| `rpc_get_vet_case_detail` | M01, M02 | ✅ Deployed | d04 | Existing |
| `rpc_add_vet_diagnosis` (RPC-26) | M02 | ✅ Deployed | d04 | Existing |
| `rpc_add_vet_recommendation` (RPC-27) | M02 | ✅ Deployed | d04 | Existing |
| `rpc_close_vet_case` (RPC-28) | M02 | ❌ NEW | d04 | FSM: in_progress→resolved/closed. If death→log_herd_event. |
| `rpc_create_vaccination_plan` (RPC-29) | M03 | ❌ NEW | d04 | Protocol→Plan generation. Status=pending_review. |
| `rpc_record_vaccination` (RPC-31) | M04 | ❌ NEW | d04 | Append-only. Triggers plan_item completion + health_restriction. |
| `rpc_report_epidemic_signal` (RPC-32) | M05 | ❌ NEW | d04 | Creates signal in detected status. |
| `rpc_add_knowledge_chunk` (RPC-44) | A03 | ❌ NEW | d05 | Admin knowledge base CRUD. |
| `rpc_restrict_organization` (RPC-45) | A04 | ❌ NEW | d01 | Creates health_restriction. D98 TSP safety gate. |

**Total new RPCs: 5 in d04 + 1 in d05 + 1 in d01 = 7**

### CTO Decisions

**D-S6-1:** Expert/Admin list screens originally planned to use `.from()` with admin/expert RLS policies for M01, M03, M05. **Superseded for M01/M03/M05 by D-S6a-FIX-1.** Remains valid for A03, A04, A05 (non-vet admin screens).

**D-S6a-FIX-1 (2026-06-22):** M03/M04/M05 (and M01) use dedicated `rpc_list_*` READ-RPCs instead of direct `.from()` table queries. Rationale: `rpc_get_vet_case_detail` requires a non-null `case_id` — omitting it raises `VET_CASE_NOT_FOUND` and is not a viable list mode. Dedicated list RPCs (`rpc_list_vet_cases`, `rpc_list_vaccination_plans`, `rpc_list_epidemic_signals`) provide proper filtering, pagination, and consistent RLS enforcement. This supersedes D-S6-1 for M-series vet screens.

**D-S6-2:** RPC-30 (`rpc_add_vaccination_plan_item`) deferred — RPC-29 generates items from protocol. Manual item addition is a later enhancement.

**D-S6-3:** Slice 6b (A06–A10: user management, settings, role assignment) deferred to after farmer feedback.
