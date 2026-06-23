# Dok 6 — Interface Contracts: Slice 2 "Членство"

> Version: 1.0 | Date: 2026-03-19
> Author: Architect Agent
> Status: ✅ APPROVED — CEO decisions resolved 2026-03-19
>
> **Scope:** 2 admin screens (A01, A02) — membership application review.
> **User story:** Admin sees pending applications → reviews details → approves or rejects → farmer sees updated status.

> ⚠️ **MEMBERSHIP LIFECYCLE CANON — Microstep 2 / Decision A1**
> The membership lifecycle is canonically defined by **Microstep 2** (6-state FSM) and **Decision A1** (binary tier model: `registered` / `member`).
> The level-stack model (`observer` / `associate` / `member`) and `membership_type` field referenced in earlier drafts of this slice are **retired** — they do not reflect deployed reality.
> Code references to level-stack and `membership_type` are implementation debt tracked as **MEMBERSHIP-01..06**; migration is a Phase 2 task.
> This slice's screen contracts remain valid for the application-review flow but UI labels and status values must align to the 6-state FSM: `draft` → `submitted` → `under_review` → `approved` / `rejected` / `withdrawn`.

---

## Design System

All Slice 2 screens use the **Admin Panel** neutral palette:

```css
.light {
  --bg-primary: #f8f9fa;
  --text-primary: #1a1a2e;
  --accent: #4361ee;
  --accent-hover: #3a56d4;
  --surface: #ffffff;
  --border: #e2e8f0;
  --text-secondary: #64748b;
  --success: #22c55e;
  --error: #ef4444;
  --warning: #f59e0b;
  --badge-submitted: #3b82f6;
  --badge-under-review: #f59e0b;
  --badge-approved: #22c55e;
  --badge-rejected: #ef4444;
}
```

**Typography:** System font stack. Headings: 600 weight. Body: 400.
**Layout:** Max-width 1024px centered (desktop-first, admin uses laptop).
**Language:** Russian UI. Field labels in Russian.

---

## Navigation Structure

```
/admin                    → Admin Dashboard (stub for now)
├── /admin/membership     → A01 (Membership Queue)
└── /admin/membership/:id → A02 (Membership Decision)
```

**Route guard:** Every `/admin/*` route MUST check `fn_is_admin()` via RPC before rendering. If not admin → redirect to `/cabinet` with toast "Доступ запрещён".

---

## A01 — Очередь заявок на членство

### Meta

| Field | Value |
|-------|-------|
| Screen ID | A01 |
| Route | `/admin/membership` |
| Auth | Authenticated + `fn_is_admin()` |
| User story | Админ видит список заявок на членство с фильтрами по статусу. Кликает на заявку → переходит к A02. |
| RPCs | `rpc_get_membership_queue` (NEW — admin read) |

### User Flow

```
1. Page load → rpc_get_membership_queue({ p_status_filter, p_page, p_page_size })
   - Returns: paginated list of applications with org info
   - Default filter: 'submitted' (pending applications first)

2. Filter bar:
   - StatusFilter: Все | Ожидает (submitted) | На рассмотрении (under_review) | Одобрено | Отклонено
   - Default: "Ожидает"

3. Application list (table on desktop, cards on mobile):
   | # | Организация | Тип | Регион | Текущий уровень | Запрошенный | Подана | Статус |
   Each row clickable → navigate to /admin/membership/:id (A02)

4. Empty state: "Нет заявок с таким статусом"
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_membership_queue` (NEW) | Page load + filter change | `{ p_organization_id uuid, p_status_filter text default null, p_page int default 1, p_page_size int default 20 }` | `{ items: [{ application_id, org_id, org_name, org_type, region_name, bin, from_level, to_level, status, submitted_at, notes }], total_count, page, page_size }` |

**NOTE:** `p_organization_id` is required by P-AI-2 convention but admin RPCs verify `fn_is_admin()` instead of org ownership. Pass any valid org_id or a sentinel value — the RPC uses admin check, not org filter.

**Implementation option:** This RPC does not exist in Dok 3. Two paths:
1. **New RPC** `rpc_get_membership_queue` in d01 — purpose-built for A01
2. **Direct query** via admin RLS policy — `membership_applications` already has `mem_apps_read_own` policy that grants admin SELECT

**Recommendation:** Use a dedicated RPC for consistency with the "all data via RPC" rule. But if DB Agent prefers, a simple `supabase.from('membership_applications').select('*, organizations(*), memberships(*)').order('submitted_at')` would also work because RLS policy `mem_apps_read_own` already grants admin full SELECT access. **CEO decision needed.**

### Validation Rules

No user input on this screen (read-only list).

### UI Components

```
A01-MembershipQueue
├── AdminGuard (fn_is_admin() check → redirect if false)
├── Header
│   ├── Title "Заявки на членство"
│   └── Badge[count] (pending applications count)
├── FilterBar
│   └── StatusTabs: Все | Ожидает | На рассмотрении | Одобрено | Отклонено
├── ApplicationTable (desktop) / ApplicationCards (mobile)
│   ├── Row/Card per application
│   │   ├── OrgName + OrgTypeBadge (farmer/mpk/services/feed_producer)
│   │   ├── RegionName
│   │   ├── LevelTransition (from_level → to_level)
│   │   ├── SubmittedDate (relative: "2 дня назад")
│   │   ├── StatusBadge (submitted=blue, under_review=yellow, approved=green, rejected=red)
│   │   └── ClickAction → navigate to A02
│   └── Pagination (if > 20 items)
└── EmptyState "Нет заявок с таким статусом"
```

---

## A02 — Решение по заявке

### Meta

| Field | Value |
|-------|-------|
| Screen ID | A02 |
| Route | `/admin/membership/:applicationId` |
| Auth | Authenticated + `fn_is_admin()` |
| User story | Админ просматривает детали заявки: информация об организации, ферме, поголовье. Принимает решение: одобрить или отклонить с комментарием. |
| RPCs | `rpc_get_membership_queue` (with filter by ID) or `rpc_get_application_detail` (NEW); `rpc_process_membership_application` (RPC-03) |

### User Flow

```
1. Page load → load application detail
   - Application info: org_name, org_type, bin, region, submitted_at, notes
   - Organization info: created_at, farms count, herd_groups summary
   - Current membership: level, since when
   - Application history: any previous applications (approved/rejected)

2. Review section (read-only):
   - Organization card:
     | Поле | Значение |
     | Название | "Ферма Жаңа" |
     | Тип | Фермер |
     | БИН/ИИН | 123456789012 |
     | Регион | Алматинская область |
     | Зарегистрирован | 15 марта 2026 |

   - Farm summary (if farmer):
     | Поголовье | 45 голов |
     | Породы | Казахская белоголовая, Ангус |
     | Направление | Мясное скотоводство |

   - Application notes from farmer (if any):
     "Хочу участвовать в программе коллективных продаж"

3. Decision section:
   - TextArea: reviewer_notes (optional) — "Комментарий к решению"
   - Two action buttons:
     ✅ "Одобрить" (green) → rpc_process_membership_application({ p_decision: 'approved' })
     ❌ "Отклонить" (red) → rpc_process_membership_application({ p_decision: 'rejected' })
   - Confirmation dialog before action:
     "Одобрить заявку [OrgName] на уровень [observer]?"
     [Отмена] [Подтвердить]

4. After decision:
   - Toast: "Заявка одобрена" / "Заявка отклонена"
   - Redirect to A01 (queue)
   - Event: identity.membership.activated (on approve)

5. Already-decided state:
   - If application.status is 'approved' or 'rejected':
     Show decision info (reviewed_by, reviewed_at, reviewer_notes)
     Hide action buttons
     Show badge: "Решение принято DD.MM.YYYY"
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| Application detail load | Page load | Application ID | Full application + org + farm + membership data |
| `rpc_process_membership_application` (RPC-03) | Decision submit | `{ p_organization_id uuid, p_application_id uuid, p_decision text, p_decision_notes text default null }` | `uuid (membership_id)` |

**RPC-03 behavior (from Dok 3 §2):**
- Validates: application exists, status is 'submitted' or 'under_review'
- If `p_decision = 'approved'`:
  - Updates `membership_applications.status = 'approved'`, sets `reviewed_at`, `reviewed_by`
  - Updates `memberships.level` from `from_level` to `to_level`
  - Emits event: `identity.membership.activated`
- If `p_decision = 'rejected'`:
  - Updates `membership_applications.status = 'rejected'`, sets `reviewed_at`, `reviewed_by`
  - Emits event: `identity.membership_application.decided`
- Error codes: `APPLICATION_NOT_FOUND`, `ALREADY_DECIDED`, `INVALID_DECISION`

**Application detail data:** Can be loaded via the same `rpc_get_membership_queue` with an ID filter, or a dedicated `rpc_get_application_detail`. Since Slice 2 is lightweight, using the queue RPC with a single-item filter is acceptable. **CEO decision: dedicated RPC or reuse queue?**

### Validation Rules

| Field | Rule | Error message |
|-------|------|---------------|
| p_decision | Required, 'approved' or 'rejected' | — (UI enforces via buttons) |
| reviewer_notes | Optional, max 1000 chars | "Комментарий не должен превышать 1000 символов" |
| Confirmation | Required before submit | Dialog must be confirmed |

### UI Components

```
A02-MembershipDecision
├── AdminGuard (fn_is_admin() check)
├── Header
│   ├── BackLink → /admin/membership
│   ├── Title "Заявка на членство"
│   └── StatusBadge (submitted | under_review | approved | rejected)
├── OrganizationCard
│   ├── OrgName + OrgTypeBadge
│   ├── BIN/IIN
│   ├── Region
│   ├── RegisteredDate
│   └── CurrentMembershipLevel
├── FarmSummaryCard (if org_type = farmer)
│   ├── TotalHeadCount
│   ├── HerdGroups[] (category + breed + count)
│   └── ActivityTypes[]
├── ApplicationCard
│   ├── LevelTransition: from_level → to_level
│   ├── SubmittedDate
│   └── FarmerNotes (if any, blockquote style)
├── ApplicationHistoryCard (if previous applications exist)
│   └── PreviousApplication[] (status, date, reviewer_notes)
├── DecisionSection (hidden if already decided)
│   ├── TextArea[reviewer_notes] — "Комментарий к решению (опционально)"
│   ├── ApproveButton "Одобрить" (green, with confirmation dialog)
│   └── RejectButton "Отклонить" (red, with confirmation dialog)
├── DecisionResultCard (visible if already decided)
│   ├── DecisionBadge (approved/rejected)
│   ├── ReviewedDate
│   ├── ReviewerName
│   └── ReviewerNotes
└── ConfirmationDialog
    ├── Message "Одобрить заявку [OrgName]?"
    ├── CancelButton
    └── ConfirmButton
```

---

## Cross-Screen Data Flow

```
F01 (Register) — Slice 1
  │ Creates: Organization, Membership (level='registered')
  │ Optional: MembershipApplication (status='submitted')
  ▼
A01 (Membership Queue) — Slice 2
  │ Admin sees: pending applications
  │ Filters by status
  ▼
A02 (Membership Decision) — Slice 2
  │ Admin reviews org details + farm data
  │ Action: rpc_process_membership_application
  │ Result: membership.level = 'observer' (on approve)
  │ Event: identity.membership.activated
  ▼
F02 (Farm Profile) — Slice 1
  │ Farmer sees: MembershipBadge updated to "Наблюдатель"
  │ (via rpc_get_my_context → memberships[].level)
```

---

## RPC Implementation Plan

| RPC | Screen | Status | File | Notes |
|-----|--------|--------|------|-------|
| `rpc_get_membership_queue` (NEW) | A01, A02 | ❌ NOT IMPLEMENTED | d01_kernel.sql | Admin-only. Dual mode: list (paginated) or detail (by p_application_id). Joins membership_applications + organizations + memberships + farms + herd_groups. |
| `rpc_process_membership_application` (RPC-03) | A02 | ❌ NOT IMPLEMENTED | d01_kernel.sql | Dok 3 §2. Admin-only. FSM: submitted/under_review → approved/rejected. Inserts into `notifications` (WA + in_app). |

### Backend: WhatsApp Notification Sender (NEW for Slice 2)

RPC-03 inserts notification rows. A worker must deliver them:

```
notifications (status=pending, channel=whatsapp)
  → claim_pending_notifications(batch=10, worker_id)
  → WhatsApp Cloud API: POST /messages (template message)
  → mark_notification_sent(notification_id)
  → on failure: mark_notification_failed(notification_id) + retry
```

**Scope:** Minimal worker — only sends WhatsApp template messages from `notifications` table. No proactive AI triggers (that's Slice 4).

**Implementation options:**
- Supabase Edge Function + pg_cron (every 30s)
- Python worker in `ai_gateway/notification_worker.py` + cron
- Supabase Database Webhook → Edge Function (event-driven)

**Backend Agent decides implementation.** Must use existing `claim_pending_notifications` (SKIP LOCKED) and `mark_notification_sent/failed`.

---

## CEO Decisions (2026-03-19)

1. ~~**A01 data access:**~~ **RESOLVED.** Dedicated `rpc_get_membership_queue` RPC. Consistency with "all data via RPC" rule.

2. ~~**A02 detail load:**~~ **RESOLVED.** Single RPC with dual mode: `rpc_get_membership_queue({ p_application_id })` returns full detail for one application; without it returns paginated list. One RPC, two modes.

3. ~~**Notification to farmer:**~~ **RESOLVED.** WhatsApp notification required on approve/reject. RPC-03 inserts into `notifications` table (channel='whatsapp', template_id='application_approved' or 'application_rejected'). Backend Agent builds minimal WhatsApp sender worker. Templates from Dok 4 §5:
   - `application_approved`: *"Заявка одобрена! Ваш статус: {new_level}. Откройте кабинет."*
   - `application_rejected`: *"Заявка отклонена. Причина: {reject_reason}. Контакт: {contact_info}."*

**Consequence of #3:** Slice 2 scope expanded — Backend Agent must implement a minimal WhatsApp notification sender (claims from `notifications` table via `claim_pending_notifications`, sends via WhatsApp Cloud API, calls `mark_notification_sent`). This is a subset of the full proactive dispatch (Slice 4) but handles only the notification send path.
