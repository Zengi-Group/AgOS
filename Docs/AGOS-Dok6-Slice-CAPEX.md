# Dok 6 — Interface Contracts: ADR-CAPEX-01 (CAPEX Module)

> Version: 1.0 | Date: 2026-04-18
> Author: Architect Agent
> Status: ✅ APPROVED — shipped 2026-04-17/18 (commits cfce152, 259fe49, 92dfbb5, eb88bea, 560829c)
>
> **Scope:** 5 screen contracts covering the CAPEX module UI surface.
> - 3 admin screens (CAPEX-ADMIN-01..03) under `/admin/capex/*`
> - 1 consulting-project screen (CONSULTING-CAPEX-EDIT-01) — editable CapexTab
> - 1 wizard integration (CONSULTING-WIZARD-MATERIAL-01) — material selectors in Параметры
>
> Architectural context: Dok 7 §11. SQL: [d09_consulting.sql](../d09_consulting.sql) §ADR-CAPEX-01. RPCs: Dok 3 §13c.

---

## Design System

All CAPEX screens use the **Admin Panel** neutral palette (`.light`) for admin screens and project-admin grey for consulting-project screens (existing `.param-card` styling). No new tokens.

**Access control:**
- A-series (`/admin/capex/*`) — `useAdminGuard()` → redirect if not admin
- Consulting-project screens — authenticated org member with project access (existing `/admin/consulting/:projectId/*` guard)

**Language:** Russian. Field labels + CTAs in Russian. Code/enum values stay English.

---

## Navigation Structure

```
/admin/directories/capex                     → redirect to /admin/directories/capex/materials
├── /admin/directories/capex/materials       → CAPEX-ADMIN-01
├── /admin/directories/capex/norms           → CAPEX-ADMIN-02
└── /admin/directories/capex/surcharges      → CAPEX-ADMIN-03

/admin/consulting/:projectId
├── /edit                        → ProjectWizard (Edit mode) — hosts CONSULTING-WIZARD-MATERIAL-01
├── /params  (View mode)         → hosts CONSULTING-WIZARD-MATERIAL-01 (row-card)
└── /capex                       → CONSULTING-CAPEX-EDIT-01
```

Sidebar entry (admin nav): «Справочники» → `/admin/directories/capex`, icon `Building2` (lucide-react).

> **Route update (MARKET-UI-07):** Routes updated from `/admin/capex/*` to `/admin/directories/capex/*` to match deployed `src/App.tsx` (Справочники sidebar section).

---

## CAPEX-ADMIN-01 — Материалы (каталог)

### Meta

| Field | Value |
|-------|-------|
| Screen ID | CAPEX-ADMIN-01 |
| Route | `/admin/directories/capex/materials` |
| Auth | `fn_is_admin()` |
| User story | Админ видит каталог из 4 базовых материалов с ценой за м². Кликает строку → редактирует name_ru + cost_per_m2. Код material readonly в режиме edit. |
| Component | `CapexMaterialsTab` exported from [CapexReferenceAdmin.tsx](../src/pages/admin/capex/CapexReferenceAdmin.tsx) |
| RPCs | Read: `rpc_list_construction_materials()` (RPC-CAPEX-1). Write: `rpc_upsert_construction_material(p_code, p_name_ru, p_cost_per_m2)` (RPC-CAPEX-3) |

### Data requirements

Returned by `rpc_list_construction_materials`:
- `code: string` — light_frame | sandwich | steel | brick (defaults)
- `name_ru: string`
- `cost_per_m2: numeric` (тг/м²)
- `currency: string` (fixed to KZT in MVP)
- `valid_from, valid_to: date`

### User Flow

1. Page load → `useRpc<Material[]>('rpc_list_construction_materials')` → rows sorted by price asc
2. Table (CSS grid): Название | Код | Цена 1 м² (₸) | Валюта | Edit icon
3. Click row → `MaterialDialog` opens (mode=edit)
4. «+ Новый материал» button → `MaterialDialog` opens (mode=create)
5. Dialog fields: Код (readonly in edit, free in create), Название (RU), Цена 1 м² (number)
6. Save → `rpc_upsert_construction_material` → toast success + refetch + dialog closes
7. Error: toast with backend message (ADMIN_REQUIRED, INVALID_COST)

### Validation

- Код: non-empty (create only)
- Название: non-empty
- Цена 1 м²: numeric, `>= 0`
- Client-side guard before RPC; server-side enforces via INVALID_COST

### Empty state

"Нет материалов. Добавьте первый через «+ Новый материал»."

### Non-functional

- Sort: by `cost_per_m2` asc (RPC-enforced)
- Caching: TanStack Query `staleTime=30s` (from `useRpc` default)
- Invalidation on save via `useRpcMutation.onSuccess → onSaved() → refetch()`

---

## CAPEX-ADMIN-02 — Нормативы инфраструктуры

### Meta

| Field | Value |
|-------|-------|
| Screen ID | CAPEX-ADMIN-02 |
| Route | `/admin/directories/capex/norms` |
| Auth | `fn_is_admin()` |
| User story | Админ видит 53 норматива инфраструктуры grouped by блок, фильтрует по блоку, ищет по коду/названию. Кликает строку → Dialog с полным JSONB editor. |
| Component | `CapexNormsTab` + `NormDialog` |
| RPCs | Read: `rpc_list_infrastructure_norms()` (RPC-CAPEX-2). Write: `rpc_upsert_infrastructure_norm(p_code, p_data, p_block)` (RPC-CAPEX-4) |

### Data requirements

Returned grouped by block:
```json
{
  "farm": [...], "pasture": [...], "equipment": [...], "tools": [...]
}
```

Per-item fields (from `data` JSONB — see Dok 7 §11.3-§11.5):
- Identity: `name_ru`, `block`, `display_order`, `depreciation_years`
- Model: `cost_model` (enum 6 values), `applies_to` (enum 8), `material_target` (enclosed|support|null)
- Model params (set based on cost_model): `area_per_head_m2`, `fixed_area_m2`, `unit_cost`, `fixed_qty`, `fixed_cost`, `area_divisor_ha`
- Optional: `unit_cost_per_m2_override` (bespoke price for Excel parity), `calving_scenario_multiplier: {Зимний, Летний}`

### User Flow

1. Page load → `useRpc<InfraNormsByBlock>('rpc_list_infrastructure_norms')`
2. Toolbar: Search input (code + name_ru), Block filter dropdown (all/farm/pasture/equipment/tools), «+ Новый норматив» button, row-count badge
3. Flattened table with 7 columns: Код | Название | Блок badge | Модель (cost_model) | Applies to | Депр., лет | Edit icon
4. Row click → `NormDialog` opens (mode=edit, code readonly)
5. «+ Новый норматив» → `NormDialog` (mode=create)
6. Dialog sections (all visible):
   - **Identity:** code, block (select), name_ru, display_order, depreciation_years
   - **Cost model:** cost_model select (6 options with human-readable labels)
   - **Context:** applies_to select (8), material_target select (enclosed/support/NONE)
   - **Model parameters:** conditionally shown based on cost_model
     - area_per_head: area_per_head_m2
     - fixed_area: fixed_area_m2
     - per_head_unit: unit_cost
     - fixed_qty: fixed_qty + unit_cost
     - fixed_per_project: fixed_cost
     - per_area_ha: area_divisor_ha + unit_cost
   - **Bespoke price (area models only):** unit_cost_per_m2_override (optional, empty = use material catalog)
   - **Calving multiplier (optional):** Зимний / Летний numbers, both empty = no multiplier applied
7. Save → constructs `p_data` JSONB → `rpc_upsert_infrastructure_norm({p_code, p_data, p_block})` → toast + refetch

### Validation

- Код: non-empty (create only)
- Название: non-empty
- Block: required (server-side INVALID_BLOCK)
- Cost model selected → corresponding param fields must have values; engine tolerates 0 as «absent» but UI should warn on unexpected empty
- Calving multiplier: if one of (Зимний, Летний) is set, both must be ≥0. Empty = no multiplier.

### Empty state

- Filter no results: "Ничего не найдено"
- Table empty: "Нет нормативов в справочнике"

### Non-functional

- Sort: by `data.display_order` asc, then `code` alphabetically (RPC-enforced)
- Large form (~20 fields) — Dialog uses `max-h-[85vh] overflow-y-auto`
- Bundle impact: contributes ~20kB (minified) to CapexReferenceAdmin chunk

---

## CAPEX-ADMIN-03 — Надбавки

### Meta

| Field | Value |
|-------|-------|
| Screen ID | CAPEX-ADMIN-03 |
| Route | `/admin/directories/capex/surcharges` |
| Auth | `fn_is_admin()` |
| User story | Админ видит единственную активную конфигурацию надбавок (works_rate, contingency_rate, applies_to_blocks, contingency_base_by_block). Редактирует и сохраняет. Следующий recalc проекта подхватит изменения. |
| Component | `CapexSurchargesTab` |
| RPCs | **Read (tech debt):** direct `.from('consulting_reference_data').select().eq('category', 'capex_surcharges')` — admin-only exception from «always via supabase.rpc()» principle; RLS `crd_read_all` permits. Future: dedicated `rpc_list_capex_surcharges`. **Write:** `rpc_upsert_consulting_reference(p_category='capex_surcharges', p_code='default', p_data, p_valid_from=null)` (existing RPC-C08). |

### Data requirements

Shape of `data` JSONB:
```json
{
  "works_rate": 0.06,
  "contingency_rate": 0.025,
  "applies_to_blocks": ["farm", "pasture"],
  "contingency_base_by_block": {"farm": "items_plus_work", "pasture": "items_only"}
}
```

### User Flow

1. Page load → direct table read → hydrate form with latest row (code='default')
2. Form fields:
   - **Работы (rate):** number input, step 0.001, default 0.06 — label «6% надбавки за работы»
   - **Непредвиденные (rate):** number input, step 0.001, default 0.025 — label «Excel фактический 2.5% (не 3%)»
   - **Applies to blocks:** 4 checkboxes (Ферма / Пастбища / Техника / Инструменты)
   - **Contingency base (per block):** 2 selects (Ферма + Пастбища) with options `items_only` / `items_plus_work` — explainer «Excel row 28 farm = items+works, row 37 pasture = items only»
3. Save button → builds `data` payload → `rpc_upsert_consulting_reference` → toast + local state update

### Validation

- Rates: numeric, ≥0, no explicit upper bound (admin trusted)
- At least 1 block selected (client-side warning, engine tolerates empty list but nothing will get surcharges applied)

### Empty state

Never empty — seed row exists; if reads fail, form uses hardcoded defaults (0.06 / 0.025 / [farm,pasture] / items_plus_work+items_only).

---

## CONSULTING-CAPEX-EDIT-01 — Редактируемый CapexTab

### Meta

| Field | Value |
|-------|-------|
| Screen ID | CONSULTING-CAPEX-EDIT-01 |
| Route | `/admin/consulting/:projectId/capex` |
| Auth | Authenticated + project ownership (existing project guard) |
| User story | Эксперт открывает CAPEX-таб проекта → видит 4 блока с editable таблицами. Включает/выключает позиции, меняет qty (для qty-based моделей), выбирает материал per-item override. Сохраняет → проект пересчитывается. Если проект на Priority 3 (legacy) — banner + disable edit. |
| Component | `CapexTab` in [src/pages/admin/consulting/tabs/CapexTab.tsx](../src/pages/admin/consulting/tabs/CapexTab.tsx) |
| RPCs | Read: `rpc_list_construction_materials()` + `rpc_get_consulting_project` (via `useProjectData`). Write: `rpc_save_project_infra_override(p_org_id, p_project_id, p_enclosed=null, p_support=null, p_overrides)` (RPC-CAPEX-5) + `POST /api/v1/calculate` (Railway). |

### Data requirements

Reads `results.capex.*` from last version:
- `farm`, `pasture`, `equipment`, `tools` blocks with per-item metadata: `code, name, cost, cost_model, applies_to, material_target, material_resolved, depreciation_years, qty, area_m2, calving_multiplier, included`
- `grand_total`, `priority_used` (2 or 3), `materials_used: {enclosed, support}`, `depreciation_per_block`

Initial overrides state seeded from `version.input_params.infra_items_override`.

### User Flow

1. Load `useProjectData()` → version.results.capex
2. If `priority_used !== 2` → Banner «Этот проект на старой модели CAPEX. Пересчитайте...» + edit controls disabled
3. Pie chart (existing) shows cost distribution across 4 blocks
4. Per-block editable tables:
   - ☐ Включить (checkbox, default true, toggle emits `include: false` override)
   - Код + Название (readonly)
   - Модель badge (cost_model label in short form, hidden on mobile)
   - Кол-во/Площадь: editable input for fixed_qty / per_head_unit models; read-only value (computed area or qty) for area_per_head / fixed_area / fixed_per_project / per_area_ha
   - Материал select (4 options + «По умолчанию») — only visible when `material_target !== null`
   - Стоимость (readonly, from `item.cost`)
5. Block footer: Subtotal / Работы 6% / Непредвиденные 2.5% / Итого блока
6. Bottom card: CAPEX Итого + materials_used summary («закрытые — Сэндвич-панель, вспомогательные — Лёгкий каркас»)
7. Sticky save bar (fixed bottom, visible only when `isDirty && !isLegacy`):
   - Left: «Несохранённых изменений: N. Сохраните — проект пересчитается.»
   - Right: «Отмена» (revert to initial) + «Сохранить и пересчитать»
8. Save flow:
   - `rpc_save_project_infra_override` with overrides only (materials stay null = preserved)
   - On success: toast «Сохранено. Пересчитываю…»
   - Call `calculateProject({project_id, organization_id, input_params: version.input_params})` — calculate.py reads fresh DB override
   - On calc success: `cacheResults` + `refetch()` + update `initialOverridesRef` + toast «Пересчёт готов (версия N)»
   - Error: toast with backend message (MATERIAL_NOT_FOUND, INVALID_OVERRIDES, PROJECT_NOT_FOUND, or HTTP error from /calculate)

### Validation

- Override cleanup: when all optional fields of a row are default (include=true, qty_override=undefined, material_override=undefined), the entry is removed from the array (no noise in DB).
- Material override: value must be a known material code (checked server-side — MATERIAL_NOT_FOUND).

### Empty state

- `!version` → «Нет данных. Запустите расчёт.»
- 0 items in a block → block Card not rendered
- Pie chart: rendered only when at least one block has `value > 0`

### Non-functional

- Save cycle ~3-5 sec (RPC write + /calculate Railway round-trip + Supabase version save)
- Mobile: Модель column hidden; model badge appears under item name
- Legacy (Priority 3) render: same layout, edit controls disabled, banner visible

---

## CONSULTING-WIZARD-MATERIAL-01 — Выбор материалов в Мастере

### Meta

| Field | Value |
|-------|-------|
| Screen ID | CONSULTING-WIZARD-MATERIAL-01 |
| Mounts inside | `ProjectWizard` ([src/pages/admin/consulting/ProjectWizard.tsx](../src/pages/admin/consulting/ProjectWizard.tsx)) — both Edit mode (Step 3 «Технология» subsection) and View mode (separate «Строительство» row-card) |
| User story | Эксперт при настройке проекта выбирает 2 материала: для закрытых построек (ангар, изолятор, крытое отёла, КПП) и для вспомогательных (навесы, зернохранилище, кормостол, загоны). Цены берутся из admin-каталога и применяются в CAPEX Priority 2. |
| RPCs | Read: `rpc_list_construction_materials()`. Write (before /calculate): `rpc_save_project_infra_override(p_org_id, p_project_id, p_enclosed, p_support, p_overrides=lastVersionOverrides)` — preserves CapexTab edits. |

### Data requirements

- WizardParams extended with `construction_material_enclosed: string`, `construction_material_support: string` (both default to Phase 1 seed defaults: 'sandwich' / 'light_frame')
- Materials options loaded via `supabase.rpc('rpc_list_construction_materials')` on wizard mount

### User Flow

**Edit mode (Step 3 Технология):**
1. New subsection «Строительство» inserted between «Пастбищный сезон» and «Производственный цикл»
2. Two native `<select>` controls:
   - Label: «Материал для закрытых построек» → hint «Цена м² для ангара, изолятора, крытого отёла, КПП»
   - Label: «Материал для вспомогательных построек» → hint «Цена м² для навесов, зернохранилища, кормового стола, загонов»
3. Options: `"${name_ru} · ${cost_per_m2.toLocaleString('ru-RU')} ₸/м²"`

**View mode:**
1. New row-card «Строительство» below the 2-column grid (Технология + Финансирование)
2. Two `.param-select` rows using the same `Row()` renderer as other view-mode fields

**handleCalculate flow (both modes):**
1. Before `calculateProject` call → `rpc_save_project_infra_override` with new materials + `lastVersionOverrides` (array preserved from last version.input_params.infra_items_override)
2. Continue to `/calculate` — `calculate.py` reads fresh project row, injects materials + overrides into `input_params`, Priority 2 engine uses them
3. On success: cache results, update `savedParamsStr`, navigate to `/summary`

### Validation

- Material codes: must exist in `rpc_list_construction_materials` result (server-side MATERIAL_NOT_FOUND if user somehow injects invalid code).
- No client-side required-field check — defaults ensure non-empty values.

### Empty state

If material catalog fails to load → both selects show current value as single option; wizard still works with defaults.

### Known limitation (L-P3-WIZARD)

`rpc_save_project_infra_override` always writes `infra_items_override` (no NULL-preserve). Wizard sends `lastVersionOverrides` read from last version.input_params — may be stale if user saved CapexTab overrides but recalc failed in between. Window for loss is small (user must fail recalc AND jump to wizard AND recalc again). Fix: DB Agent extends `rpc_update_consulting_project` with materials-only semantic (ADR-CAPEX-02 scope or dedicated session).

---

## Cross-cutting: Non-functional requirements

- **Admin gate:** `fn_is_admin()` SQL-level on 3 admin RPCs + `useAdminGuard()` UI-level for route; non-admins redirected.
- **RLS:** `consulting_reference_data` read=all, write=admin (existing d09 policy). `consulting_projects` org-scoped read/write.
- **Performance:** Admin tabs load ≤500ms (RPC + single table render ≤60 rows). CapexTab on Тест 7 (53 rows + 4 blocks) renders ≤200ms client-side. Save cycle ≤5sec (Railway round-trip).
- **Bundle:** +26kB minified (Phase 4 only); Phase 3 CapexTab + wizard additions +10kB. Total CAPEX UI impact ~36kB.
- **Error strategy:** All RPC errors surface as `toast.error` with backend message; no silent failures.
- **Legacy preservation:** Priority 3 projects (Тест 7, pre-seed) render read-only with banner; users can trigger recalc to upgrade to Priority 2.

---

## Shipped commits

| Phase | Commit | Scope |
|-------|--------|-------|
| Phase 1 | `cfce152` | DB schema + seed + 5 RPCs |
| Phase 2 | `259fe49` | Engine Priority chain + 14 tests |
| Phase 3 | `92dfbb5` | CapexTab editable + wizard materials + price-params refactor |
| Phase 5 (partial) | `eb88bea` | Dok 1 §6 + Dok 3 §1.9/§13c + Dok 4 §3.10 + Dok 7 §11 |
| Phase 4 | `560829c` | /admin/capex 3-tab page + price-params docs followup |

---

*Dok 6 Slice CAPEX v1.0 | TURAN AgOS | 2026-04-18*
