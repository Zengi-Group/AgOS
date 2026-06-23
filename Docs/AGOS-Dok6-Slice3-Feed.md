# Dok 6 — Interface Contracts: Slice 3 "Сколько корма нужно?"

> Version: 1.1 | Date: 2026-03-30
> Author: Architect Agent
> Status: ✅ APPROVED — v1.1 review fixes (D-S3-1, D-S3-2, D-S3-3) applied 2026-03-30
>
> **Scope:** 6 farmer screens (F03, F04, F15–F18) — herd overview + feed management.
> **User story:** Farmer sees herd overview → adds/edits groups → manages feed inventory → views ration → gets feed budget.

---

## Design System

All Slice 3 screens use **Farmer Cabinet** warm palette (same as Slice 1).

---

## Navigation Structure

```
/cabinet
├── /cabinet/herd              → F03 (Herd Overview)
├── /cabinet/herd/add          → F04 (Add/Edit Herd Group)
├── /cabinet/feed              → F15 (Feed Inventory)
├── /cabinet/feed/add          → F16 (Add/Edit Feed Item)
├── /cabinet/ration            → F17 (Ration Viewer)
└── /cabinet/ration/budget     → F18 (Feed Budget)
```

---

## F03 — Обзор поголовья

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F03 |
| Route | `/cabinet/herd` |
| Auth | Authenticated farmer |
| User story | Фермер видит все группы скота: категория, порода, кол-во голов, средний вес. Может добавить группу или перейти к деталям. |
| RPCs | `rpc_get_my_context` (RPC-04) → herd groups inside farm data; `rpc_get_farm_summary` (RPC-08) → full summary |

### User Flow

```
1. Page load → rpc_get_my_context() or rpc_get_farm_summary()
   - Display herd groups as cards/table
   - Show total head count

2. Herd group cards:
   | Категория | Порода | Голов | Ср. вес | Источник | Обновлено |
   - Click → F04 (edit mode)

3. "Добавить группу" button → F04 (create mode)

4. Herd events log (collapsible):
   - Recent changes: "+5 голов (ручной ввод)", "Вес обновлён AI"
   - Source badge: manual / ai_extracted / erp
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_my_context` (RPC-04) | Page load | — (JWT) | farms[].herd_groups[] |
| `rpc_get_farm_summary` (RPC-08) | Page load | `{ p_organization_id, p_farm_id }` | `{ farm, herd_groups[], feed_inventory[], active_vet_cases[], upcoming_tasks[] }` |

### UI Components

```
F03-HerdOverview
├── Header "Моё стадо"
│   └── TotalHeadCount badge
├── HerdGroupCard[] (per group)
│   ├── CategoryName + BreedName
│   ├── HeadCount + AvgWeight
│   ├── DataSourceBadge (manual | ai_extracted | erp)
│   ├── LastUpdated (relative)
│   └── EditButton → F04
├── AddGroupButton → F04 (create mode)
├── HerdEventsLog (collapsible)
│   └── EventEntry[] (type, value change, date, source)
└── EmptyState "Добавьте группы животных для учёта"
```

---

## F04 — Добавить / редактировать группу скота

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F04 |
| Route | `/cabinet/herd/add` or `/cabinet/herd/:groupId` |
| Auth | Authenticated farmer |
| User story | Фермер добавляет или редактирует группу: категория, порода, кол-во, вес. |
| RPCs | `rpc_upsert_herd_group` (RPC-06, deployed) → create/update; `rpc_log_herd_event` (RPC-07) → log change |

### User Flow

```
1. Create mode (no groupId): empty form
   Edit mode (groupId): pre-fill from context

2. Form:
   - Select: animal_category — display name_ru, store `code` (text, not uuid!) — required
   - Input: head_count (integer > 0) — required
   - Input: avg_weight_kg (numeric, optional)
   - Select: breed_id (from breeds table, optional)

3. Submit → rpc_upsert_herd_group({
     p_organization_id, p_farm_id,
     p_animal_category_code (text — e.g. 'BULL_CALF'),
     p_head_count, p_avg_weight_kg, p_breed_id,
     p_herd_group_id (null for create),
     p_actor_id (auth.uid())
   })

   ⚠️ NOTE: SQL signature uses `p_animal_category_code` (text),
   NOT `p_animal_category_id` (uuid). UI select must store code, not id.

4. On success → log herd event via rpc_log_herd_event() + redirect to F03
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_upsert_herd_group` (RPC-06) | Submit | `{ p_organization_id, p_farm_id, p_animal_category_code (text!), p_head_count, p_avg_weight_kg?, p_breed_id?, p_actor_id }` | `{ herd_group_id }` |
| `rpc_log_herd_event` (RPC-07) | After successful upsert | `{ p_organization_id, p_farm_id, p_herd_group_id, p_event_type, p_value_after, p_data_source }` | `uuid` |

### Reference Data

| Source | Data |
|--------|------|
| `animal_categories` table | Category list for select |
| `breeds` table | Breed list for select |

### Validation Rules

| Field | Rule | Error |
|-------|------|-------|
| animal_category | Required | "Выберите категорию" |
| head_count | Required, int > 0, max 50000 | "Укажите количество голов" |
| avg_weight_kg | Optional, 1–2000 | "Вес от 1 до 2000 кг" |

---

## F15 — Складские запасы кормов

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F15 |
| Route | `/cabinet/feed` |
| Auth | Authenticated farmer |
| User story | Фермер видит запасы кормов на ферме: тип, кол-во, цена, источник данных. Может добавить/обновить запас. |
| RPCs | `rpc_get_farm_summary` (RPC-08) → feed_inventory[]; or dedicated query |

### User Flow

```
1. Page load → load feed inventory for farm
   - Display as cards/table:
     | Корм | Категория | Кол-во (кг) | Цена/кг | Источник | Обновлено |

2. "Добавить корм" button → F16

3. Click existing item → F16 (edit mode)

4. Summary at top:
   - Total feeds: N видов
   - Total weight: X тонн
   - Estimated value: Y тенге
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_farm_summary` (RPC-08) | Page load | `{ p_organization_id, p_farm_id }` | feed_inventory[] with feed_item details |

### UI Components

```
F15-FeedInventory
├── Header "Запасы кормов"
├── SummaryBar (total items, total kg, estimated value)
├── FeedItemCard[] (per inventory item)
│   ├── FeedName + CategoryName
│   ├── QuantityKg (formatted: "1,250 кг" or "1.2 т")
│   ├── PricePerKg (if available)
│   ├── DataSourceBadge
│   ├── ConfidenceBadge (D45 Layered Truth: 25/50/75/95 → low/med/high/verified)
│   └── EditButton → F16
├── AddFeedButton → F16
└── EmptyState "Добавьте корма для расчёта рациона"
```

---

## F16 — Добавить / обновить запас корма

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F16 |
| Route | `/cabinet/feed/add` or `/cabinet/feed/:inventoryId` |
| Auth | Authenticated farmer |
| User story | Фермер добавляет или обновляет запас конкретного корма. |
| RPCs | `rpc_upsert_feed_inventory` (RPC-21) |

### User Flow

```
1. Create mode: select feed item + enter quantity
   Edit mode: pre-fill from existing inventory

2. Form:
   - Select: feed_item_id (from feed_items table) — required
     Grouped by feed_category for easier selection
   - Input: quantity_kg (numeric > 0) — required
   - Input: price_per_kg (numeric, optional) — farmer override (D47)
   - data_source: always 'platform' for manual entry (hidden from user)
   - confidence: set to 75 for platform entries (D45 Layered Truth)

3. Submit → rpc_upsert_feed_inventory({
     p_organization_id, p_farm_id,
     p_feed_item_id, p_quantity_kg,
     p_price_per_kg?, p_data_source: 'platform'
   })

4. On success → redirect to F15 + toast "Запас обновлён"
```

### Validation Rules

| Field | Rule | Error |
|-------|------|-------|
| feed_item_id | Required | "Выберите корм" |
| quantity_kg | Required, > 0 | "Укажите количество" |
| price_per_kg | Optional, > 0 | "Цена должна быть положительной" |

---

## F17 — Просмотр рациона

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F17 |
| Route | `/cabinet/ration` |
| Auth | Authenticated farmer |
| User story | Фермер видит текущий рацион для каждой группы: какие корма, сколько кг/день, нутриенты. Может запросить расчёт. |
| RPCs | `rpc_get_current_ration` (RPC-24) → all active rations for farm (D-S3-2: farm-level, not per-group) |

### User Flow

```
1. Page load → rpc_get_current_ration({ p_organization_id, p_farm_id })
   - If no ration exists: empty state + "Рассчитать рацион" button

2. Ration display (per herd group):
   - Group name + head count
   - Table: | Корм | кг/день | кг/голову | Стоимость/день |
   - Nutrient summary: Обменная энергия, Протеин, Сухое вещество
   - Status badge: draft | active | archived

3. "Рассчитать рацион" → triggers calculate_ration Edge Function
   (Slice 3 Backend: POST to Supabase Edge Function)
   - Edge Function creates ration (status=draft), then saves version
   - Farmer clicks "Применить" → rpc_save_ration sets status=active
   - Status transitions: draft→active (farmer), active→archived (farmer or system)

4. Version history (collapsible):
   - Previous ration versions with dates
```

### UI Components

```
F17-RationViewer
├── Header "Рацион кормления"
├── GroupRationCard[] (per herd group that has a ration)
│   ├── GroupName + HeadCount
│   ├── StatusBadge (draft | active | archived)
│   ├── RationTable
│   │   ├── Row: FeedName | KgPerDay | KgPerHead | CostPerDay
│   │   └── TotalRow
│   └── NutrientSummary (energy, protein, dry_matter)
├── CalculateButton "Рассчитать рацион"
├── VersionHistory (collapsible)
│   └── PreviousVersion[] (date, nutrient summary)
└── EmptyState "Добавьте группы и корма для расчёта рациона"
```

---

## F18 — Бюджет кормления

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F18 |
| Route | `/cabinet/ration/budget` |
| Auth | Authenticated farmer |
| User story | Фермер видит прогноз расхода кормов: сколько кормов нужно на период, хватает ли запасов, сколько докупить. |
| RPCs | `get_feed_budget` Edge Function (POST `/functions/v1/get-feed-budget`) |

### User Flow

```
1. Page load → compute budget based on:
   - Current rations (active versions)
   - Current feed inventory
   - Selected period (30 / 60 / 90 days)

2. Per-head summary card (top):
   - "Стоимость кормления 1 головы в сутки: X ₸"
   - Breakdown: корм A — Y ₸, корм B — Z ₸

3. Period selector: 30 / 60 / 90 дней

4. Total budget table (for entire herd × period):
   | Корм | кг/день (всё стадо) | Нужно на период (кг) | Есть (кг) | Дефицит | Стоимость |
   Each row: green if enough, red if deficit

5. Summary:
   - Total cost for period
   - Total deficit items
   - "Хватает на X дней" per feed item
```

### UI Components

```
F18-FeedBudget
├── Header "Бюджет кормления"
├── PerHeadCard (CEO requirement: unit economics)
│   ├── CostPerHeadPerDay "X ₸ / голову / сутки"
│   └── FeedBreakdown[] (feed → cost per head per day)
├── PeriodSelector (30 | 60 | 90 дней)
├── TotalBudgetSummary
│   ├── TotalCost (for period)
│   ├── DeficitCount
│   └── DaysUntilShortage
├── BudgetTable (total herd × period)
│   ├── Row per feed item:
│   │   ├── FeedName
│   │   ├── DailyKgTotal (all herd)
│   │   ├── RequiredKgPeriod (daily × days)
│   │   ├── AvailableKg (from inventory)
│   │   ├── DeficitKg (red if > 0)
│   │   ├── CostEstimate
│   │   └── DaysLeft badge
│   └── TotalRow
└── EmptyState "Сначала рассчитайте рацион"
```

---

## Cross-Screen Data Flow

```
F03 (Herd Overview)
  │ Shows: herd_groups from rpc_get_my_context
  │ Action: "Add group" → F04
  ▼
F04 (Add/Edit Group)
  │ Creates: HerdGroup via rpc_upsert_herd_group (RPC-06)
  │ Logs: HerdEvent via rpc_log_herd_event (RPC-07)
  │ Returns to F03
  ▼
F15 (Feed Inventory)
  │ Shows: farm_feed_inventory from rpc_get_farm_summary
  │ Action: "Add feed" → F16
  ▼
F16 (Add/Edit Feed)
  │ Creates: FarmFeedInventory via rpc_upsert_feed_inventory (RPC-21)
  │ Returns to F15
  ▼
F17 (Ration Viewer)
  │ Shows: rpc_get_current_ration (RPC-24)
  │ Action: "Calculate" → Edge Function
  │ Result: new RationVersion
  ▼
F18 (Feed Budget)
  │ Computed from: active rations + feed inventory
  │ Shows: deficit, cost, days left
```

---

## RPC Implementation Plan

| RPC | Screen | Status | File | Notes |
|-----|--------|--------|------|-------|
| `rpc_get_my_context` (RPC-04) | F03 | ✅ Deployed | d01 | Existing — includes herd_groups |
| `rpc_upsert_herd_group` (RPC-06) | F04 | ✅ Deployed | d07 | Existing |
| `rpc_log_herd_event` (RPC-07) | F04 | ❌ NOT IMPLEMENTED | d01 | DB Agent — log head count / weight changes |
| `rpc_get_farm_summary` (RPC-08) | F03, F15 | ❌ NOT IMPLEMENTED | d01 | DB Agent — full farm summary with feed inventory |
| `rpc_upsert_feed_inventory` (RPC-21) | F16 | ✅ Deployed | d03 | Deployed in d03_feed.sql |
| `rpc_save_ration` (RPC-22) | F17 | ✅ Deployed | d03 | Deployed in d03_feed.sql |
| `rpc_archive_ration` (RPC-23) | F17 | ✅ Deployed | d03 | Deployed in d03_feed.sql |
| `rpc_get_current_ration` (RPC-24) | F17 | ✅ Deployed | d03 | Deployed in d03_feed.sql |
| `calculate_ration` Edge Function | F17 | ❌ NOT IMPLEMENTED | supabase/functions/ | Backend Agent — NASEM LP calculation |
| `get_feed_budget` Edge Function | F18 | ❌ NOT IMPLEMENTED | supabase/functions/ | Backend Agent — budget computation |

---

## CEO Decisions (2026-03-19)

1. ~~**F04 reference data:**~~ **RESOLVED.** Load `animal_categories` and `breeds` from DB (P8). No hardcoded lists.

2. ~~**F17 ration trigger:**~~ **RESOLVED.** Farmer-triggered button "Рассчитать рацион" for Slice 3. Automatic recalculation in Slice 4+.

3. ~~**F18 budget periods:**~~ **RESOLVED.** 30/60/90 days.

4. **F18 budget structure (CEO addition):** Two views:
   - **Per head per day:** cost of feeding 1 animal for 1 day (unit economics)
   - **Total for period:** cost for entire herd × selected period (30/60/90 days)

   Both views in one screen. Per-head-per-day at top as summary metric, total-for-period in the detail table.


---

## CTO Decisions (2026-03-30) — Architect Review Fixes

### D-S3-1 — Feed Inventory RPC: Individual Fields

**WHAT:** `rpc_upsert_feed_inventory` (RPC-21) accepts individual fields per call, not jsonb array.

**Signature:** `(p_organization_id, p_farm_id, p_feed_item_id, p_quantity_kg, p_price_per_kg?, p_data_source default 'platform')`

**WHY:** Simpler UI (one form = one call). P-AI-3 confirmation works per-item. Batch mode can be added as separate RPC later (P7 additive).

### D-S3-2 — Current Ration: Farm-Level Return

**WHAT:** `rpc_get_current_ration` (RPC-24) takes `p_farm_id`, returns array of all active rations for the farm with their current versions.

**Signature:** `(p_organization_id, p_farm_id)` → `jsonb[]` (one element per herd group with active ration)

**WHY:** F17 shows all groups on one page. One RPC call, small dataset. Per-group filtering done client-side.

### F-1 Fix — animal_category_code, not _id

**WHAT:** `rpc_upsert_herd_group` (RPC-06, deployed in d07) uses `p_animal_category_code` (text), not `p_animal_category_id` (uuid). UI select stores code.

### F-2 Fix — p_actor_id required

**WHAT:** `rpc_upsert_herd_group` requires `p_actor_id` (uuid). UI passes `auth.uid()`.

### F-5/F-6 Fix — Confidence display + mapping

**WHAT:** F15 shows confidence badge (D45 Layered Truth). F16 sets confidence=75 for platform data source.

### F-7 Fix — Status transition ownership

**WHAT:** Ration FSM transitions: draft→active (farmer confirms), active→archived (farmer or system). Documented in F17 flow.

### F-8 Fix — Edge Function endpoint

**WHAT:** `get_feed_budget` endpoint path documented: POST `/functions/v1/get-feed-budget`.

**Input:** `{ organization_id, farm_id, period_days: 30|60|90 }`

**Output:** `{ per_head_per_day: { total_cost, feeds[] }, total_budget: { total_cost, feeds[], deficit_count, days_until_shortage } }`
