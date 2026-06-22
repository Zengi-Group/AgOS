# Dok 6 — Interface Contracts: Slice 4 "Мой план на сезон"

> Version: 1.0 | Date: 2026-03-30
> Author: Architect Agent
> Status: DRAFT — awaiting CEO review
>
> **Scope:** 5 farmer screens (F19–F23) — production plan, tasks, timeline, cascade, KPIs.
> **User story:** Farmer sees active production plan → views tasks → checks timeline → adjusts dates → tracks KPIs.

---

## Design System

All Slice 4 screens use **Farmer Cabinet** warm palette (same as Slice 1–3).

---

## Navigation Structure

```
/cabinet
├── /cabinet/plan              → F19 (Production Plan Overview)
├── /cabinet/plan/tasks        → F20 (Task List)
├── /cabinet/plan/timeline     → F21 (Timeline View)
├── /cabinet/plan/cascade/:phaseId → F22 (Phase Cascade Preview)
└── /cabinet/plan/kpi          → F23 (KPI Dashboard)
```

---

## F19 — Производственный план

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F19 |
| Route | `/cabinet/plan` |
| Auth | Authenticated farmer |
| User story | Фермер видит активный план: название, статус, фазы, прогресс. Может перейти к задачам или KPI. |
| RPCs | `rpc_get_active_plan` (RPC-37) → full plan with phases |

### User Flow

```
1. Page load → rpc_get_active_plan({ p_organization_id, p_farm_id })
   - If no active plan: empty state + info about contacting expert

2. Plan card:
   - Plan name + cycle template name
   - Status badge (draft | active | completed | cancelled)
   - Expert name (who manages this farm)
   - Cycle dates: start → end
   - Overall progress: N/M tasks completed

3. Phase list (accordion or cards):
   Each phase shows:
   | Фаза | Группа | Начало | Конец | Статус | Задач |
   - Click phase → expand to show tasks for that phase
   - Click "Сдвинуть даты" → F22 (cascade preview)

4. Quick links:
   - "Все задачи" → F20
   - "Таймлайн" → F21
   - "Показатели" → F23
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_active_plan` (RPC-37) | Page load | `{ p_organization_id, p_farm_id }` | `{ plan, phases[], tasks_summary, kpis_summary }` |

### RPC-37 Return Structure (CTO Decision)

```json
{
  "plan": {
    "id": "uuid", "name": "text", "status": "text",
    "cycle_start_date": "date", "cycle_end_date": "date",
    "expert_name": "text", "template_name": "text"
  },
  "phases": [
    {
      "id": "uuid", "name_ru": "text", "herd_group_id": "uuid",
      "herd_group_name": "text", "start_date": "date", "end_date": "date",
      "status": "text", "is_sale_phase": "bool",
      "tasks_total": "int", "tasks_completed": "int",
      "tasks_overdue": "int"
    }
  ],
  "tasks_summary": { "total": "int", "completed": "int", "overdue": "int", "upcoming_7d": "int" },
  "kpis_summary": { "total": "int", "achieved": "int", "missed": "int", "pending": "int" }
}
```

### UI Components

```
F19-ProductionPlan
├── Header "Мой план на сезон"
├── PlanCard (name, status, expert, dates, progress bar)
├── PhaseList (accordion)
│   └── PhaseItem[] (name, group, dates, status, task count)
│       └── PhaseTaskPreview[] (top 3 upcoming tasks)  ⚠️ PENDING DATA: per-phase task preview not yet returned by RPC-37 (OPERATIONS-03: extend RPC-37 to include task arrays per phase — Phase 2 debt)
├── QuickLinks (Tasks, Timeline, KPI)
└── EmptyState "План будет создан зоотехником ТУРАН"
```

---

## F20 — Задачи

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F20 |
| Route | `/cabinet/plan/tasks` |
| Auth | Authenticated farmer |
| User story | Фермер видит все задачи: предстоящие, просроченные, выполненные. Может отметить задачу. |
| RPCs | `rpc_get_active_plan` (RPC-37) → tasks from phases; or `rpc_get_farm_tasks` (already in d07) |

### User Flow

```
1. Page load → load tasks grouped by status
   - Tabs: "Предстоящие" | "Просроченные" | "Выполненные"

2. Task card:
   | Задача | Фаза | Категория | Срок | Статус |
   - Category badge: zootechnical | veterinary | management
   - Overdue tasks highlighted in red
   - Due date with relative time ("через 3 дня", "просрочено 2 дня")

3. Task detail (expand or drawer):
   - Full task description
   - Due date
   - Result data (if completed)
   - "Выполнить" button → marks task as completed

4. Complete task flow:
   - Click "Выполнить"
   - Optional: enter result notes
   - Calls rpc_complete_farm_task (RPC-34, already deployed)
   - On success: task moves to completed tab, toast confirmation
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_farm_tasks` (d07, deployed) | Page load | `{ p_organization_id, p_farm_id, p_days_ahead: 90 }` | `{ tasks[] }` |
| `rpc_complete_farm_task` (d07, RPC-34) | Complete button | `{ p_organization_id, p_task_id, p_result_description? }` | `jsonb` |

### UI Components

```
F20-TaskList
├── Header "Задачи" + filter tabs
├── StatusTabs (upcoming | overdue | completed)
├── TaskCard[] (per task)
│   ├── TaskName + PhaseName
│   ├── CategoryBadge (zootechnical | veterinary | management)
│   ├── DueDate (relative + absolute)
│   ├── StatusBadge
│   └── CompleteButton (for non-completed)
├── TaskDetailDrawer (expanded view)
│   ├── Description + Notes
│   ├── ResultData (if completed)
│   └── CompleteForm (notes input + submit)
└── EmptyState "Нет задач — план не создан"
```

---

## F21 — Таймлайн

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F21 |
| Route | `/cabinet/plan/timeline` |
| Auth | Authenticated farmer |
| User story | Фермер видит фазы на горизонтальной шкале времени. Видит текущую дату, прошедшие и будущие фазы. |
| RPCs | `rpc_get_active_plan` (RPC-37) → phases with dates |

### User Flow

```
1. Page load → load active plan phases

2. Timeline visualization:
   - Horizontal bar chart / Gantt-like view
   - Each phase = colored bar (start_date → end_date)
   - Current date marker (vertical line)
   - Phase colors by status: upcoming=gray, active=accent, completed=green, skipped=muted

3. Phase info on hover/tap:
   - Phase name + herd group
   - Dates + duration
   - Task progress

4. "Сдвинуть" button per phase → F22
```

### UI Components

```
F21-Timeline
├── Header "Таймлайн"
├── TimelineChart
│   ├── MonthHeaders (horizontal axis)
│   ├── TodayMarker (vertical line)
│   └── PhaseBar[] (colored bars per phase)
│       ├── PhaseName label
│       └── HoverTooltip (dates, tasks, status)
├── PhaseLegend (color codes by status)
└── EmptyState "План не создан"
```

### Implementation Note

Timeline is a **read-only visualization** — no writes. Simple implementation with CSS flexbox or grid, no heavy charting library needed.

---

## F22 — Сдвиг фаз (Cascade Preview)

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F22 |
| Route | `/cabinet/plan/cascade/:phaseId` |
| Auth | Authenticated farmer |
| User story | Фермер хочет сдвинуть дату фазы. Видит каскад: какие фазы сдвинутся вместе. Подтверждает или отменяет. |
| RPCs | `fn_preview_cascade` (RPC-36, deployed) → preview; `fn_shift_phase_cascade` (RPC-35, deployed) → apply |

### User Flow

```
1. Page load with phaseId → load phase info
   - Show current start_date and end_date

2. Date picker: "Новая дата начала"
   - On date change → fn_preview_cascade({ p_phase_id, p_new_start_date })

3. Cascade preview table:
   | Фаза | Текущее начало | Новое начало | Сдвиг (дни) |
   - Changed phases highlighted
   - Warning if any phase shifts past a sale deadline

4. "Применить сдвиг" button:
   - Calls fn_shift_phase_cascade({ p_phase_id, p_new_start_date, p_actor_id })
   - On success → redirect to F19 + toast "Даты обновлены"

5. "Отмена" → back to F19
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `fn_preview_cascade` (RPC-36) | Date change | `{ p_phase_id, p_new_start_date }` | table: `{ phase_id, name, old_start, new_start, shift_days }` |
| `fn_shift_phase_cascade` (RPC-35) | Apply button | `{ p_phase_id, p_new_start_date date, p_actor_id }` | void |

### UI Components

```
F22-CascadePreview
├── Header "Сдвиг фаз"
├── CurrentPhaseCard (name, current dates)
├── DatePicker "Новая дата начала"
├── CascadeTable (preview)
│   ├── Row per affected phase:
│   │   ├── PhaseName
│   │   ├── OldStartDate
│   │   ├── NewStartDate
│   │   └── ShiftDays (highlighted if > 0)
│   └── Warning (if sale phase shifts)
├── ActionButtons (Apply | Cancel)
└── EmptyPreview "Выберите новую дату"
```

---

## F23 — Показатели (KPI Dashboard)

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F23 |
| Route | `/cabinet/plan/kpi` |
| Auth | Authenticated farmer |
| User story | Фермер видит целевые показатели плана: что достигнуто, что провалено, что ещё в процессе. |
| RPCs | `rpc_get_active_plan` (RPC-37) → kpis from phases |

### User Flow

```
1. Page load → load KPIs from active plan

2. Summary cards at top:
   - ✅ Достигнуто: N
   - ❌ Провалено: M
   - ⏳ В процессе: K

3. KPI list (grouped by phase):
   Phase name header
   | Показатель | Цель | Факт | Статус |
   - Status: pending (gray), achieved (green), missed (red)
   - Progress bar: actual / target
   - Unit display (кг, г/сут, %, кг/кг)

4. KPI detail (expand):
   - Description
   - Tolerance (допустимое отклонение)
   - Measurement source
   - Measured by / date
```

### UI Components

```
F23-KpiDashboard
├── Header "Показатели"
├── SummaryCards (achieved | missed | pending counts)
├── PhaseKpiGroup[] (per phase)
│   ├── PhaseHeader (name + dates)
│   └── KpiCard[] (per KPI)
│       ├── KpiName + Unit
│       ├── TargetValue        ⚠️ PENDING DATA: target/actual/tolerance not yet returned by RPC-37 (OPERATIONS-02: extend RPC-37 or add KPI-detail RPC — Phase 2 debt)
│       ├── ActualValue (or "—" if not measured)
│       ├── ProgressBar (actual/target)
│       ├── StatusBadge (pending | achieved | missed)
│       └── ToleranceNote ("допуск ±5%")
└── EmptyState "Нет показателей — план не создан"
```

---

## Cross-Screen Data Flow

```
F19 (Plan Overview)
  │ Shows: active plan + phases + summaries
  │ Actions: "Задачи" → F20, "Таймлайн" → F21, "Показатели" → F23
  │          Phase "Сдвинуть" → F22
  ▼
F20 (Tasks)                     F21 (Timeline)
  │ Shows: all tasks              │ Shows: phases as bars
  │ Action: complete task         │ Action: "Сдвинуть" → F22
  ▼                               ▼
F22 (Cascade Preview)
  │ Preview: fn_preview_cascade
  │ Apply: fn_shift_phase_cascade
  │ Returns to F19
  ▼
F23 (KPI Dashboard)
  │ Shows: KPIs by phase
  │ Read-only for farmer
```

---

## RPC Implementation Plan

| RPC | Screen | Status | File | Notes |
|-----|--------|--------|------|-------|
| `rpc_get_active_plan` (RPC-37) | F19, F21, F23 | ✅ Deployed | d05 | Deployed; KPI detail and per-phase task arrays pending (OPERATIONS-02/03) |
| `rpc_get_farm_tasks` (d07) | F20 | ✅ Deployed | d07 | Existing |
| `rpc_complete_farm_task` (RPC-34) | F20 | ✅ Deployed | d07 | Existing |
| `fn_preview_cascade` (RPC-36) | F22 | ✅ Deployed | d05 | Existing |
| `fn_shift_phase_cascade` (RPC-35) | F22 | ✅ Deployed | d05 | Existing |
| `rpc_create_proactive_alert` (RPC-43) | — (backend only) | ❌ NOT IMPLEMENTED | d01 | Backend Agent — proactive dispatch |
| `rpc_add_knowledge_chunk` (RPC-44) | — (admin only, Slice 6) | ✅ Deployed | d05 | Deployed; admin-only, scoped to Slice 6 screens |
| `rpc_restrict_organization` (RPC-45) | — (admin only, Slice 6) | ❌ DEFERRED | d01 | Moved to Slice 6 (Admin screens) |

### CTO Decisions

**D-S4-1:** RPC-44 (`rpc_add_knowledge_chunk`) and RPC-45 (`rpc_restrict_organization`) deferred to Slice 6. These are admin-only operations with no farmer-facing screens in Slice 4. Farmer screens F19–F23 only need RPC-37 (new) + existing RPCs. *(Update 2026-06-22: RPC-44 has since been deployed in Slice 6a — decision superseded.)*

**D-S4-2:** RPC-43 (`rpc_create_proactive_alert`) implemented by Backend Agent as part of proactive dispatch pipeline. No farmer UI — alerts appear as WhatsApp notifications.

**D-S4-3:** RPC-37 (`rpc_get_active_plan`) returns a comprehensive jsonb with plan + phases + task/KPI summaries. Single RPC serves F19, F21, F23 — avoiding multiple round-trips.

---

## Slice 4 Reduced Scope

| Layer | What | Components |
|-------|------|------------|
| Dok 6 | F19–F23 (5 screens) | This document |
| DB | RPC-37 in d05 | 1 new RPC (read-only) |
| Backend | AI-04..06 ops tools + proactive dispatch | Ops tools + SKIP LOCKED consumer |
| UI | F19–F23 | 5 farmer screens |
| QA | Slice 4 gate | FSM + cascade + health_restriction |
