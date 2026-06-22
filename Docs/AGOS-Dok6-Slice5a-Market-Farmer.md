# Dok 6 — Interface Contracts: Slice 5a "Хочу продать бычков" (Farmer)

> Version: 1.0 | Date: 2026-04-01
> Author: Architect Agent
> Status: DRAFT — D-LEGAL-1: build without legal gate, disclaimer placeholders
>
> **Scope:** 5 farmer screens (F05–F09) — batch management + market overview + pricing.
> **User story:** Farmer creates batch of animals for sale → publishes → sees market prices → tracks status.

---

## Navigation Structure

```
/cabinet
├── /cabinet/market              → F08 (My Batches + Market Summary)
├── /cabinet/market/new          → F05 (Create Batch)
├── /cabinet/market/batch/:id    → F06 (Batch Detail — publish/cancel)
├── /cabinet/market/prices       → F09 (Price Info)
```

---

## F08 — Мои батчи и рынок (My Batches + Market Summary)

### Meta
| Field | Value |
|-------|-------|
| Screen ID | F08 |
| Route | `/cabinet/market` |
| Auth | Authenticated farmer |
| RPCs | `rpc_get_org_batches` (AI-19, d07, deployed) — farmer's batches; `rpc_get_market_summary` (RPC-18, new) — anonymous aggregates |

### UI Components
```
F08-MarketDashboard
├── Header "Рынок" + "Создать батч" button → F05
├── MyBatchesSection
│   ├── BatchCard[] (per batch)
│   │   ├── SKU name + heads + avg weight
│   │   ├── StatusBadge (draft|published|matched|cancelled|expired)
│   │   ├── TargetMonth
│   │   └── Click → F06
│   └── EmptyState "Нет батчей — создайте первый"
├── MarketSummarySection (collapsible)
│   ├── SupplyByCategory (anonymous aggregates)
│   ├── DemandSummary (anonymous)
│   └── DisclaimerText ⚠️ (Article 171)
└── PricesLink → F09
```

---

## F05 — Создать батч

### Meta
| Field | Value |
|-------|-------|
| Screen ID | F05 |
| Route | `/cabinet/market/new` |
| Auth | Authenticated farmer |
| RPCs | `rpc_create_batch` (RPC-09, d07, deployed) |

### User Flow
```
1. Form:
   - Select: tsp_sku_id (from tsp_skus table) — required
   - Input: heads (int > 0) — required
   - Input: avg_weight_kg (numeric, optional)
   - Select: target_month (date picker, YYYY-MM) — required
   - Select: breed_id (optional, for premium)
   - Textarea: notes (optional)

2. Health restriction check:
   - If farmer has active restrictions → show warning, block submit

3. Submit → rpc_create_batch({
     p_organization_id, p_farm_id, p_herd_group_id,
     p_sku_id, p_heads, p_avg_weight_kg,
     p_target_month, p_breed_id, p_notes
   })

4. On success → redirect to F06 (batch detail)
```

### Validation
| Field | Rule | Error |
|-------|------|-------|
| tsp_sku_id | Required | "Выберите категорию" |
| heads | Required, int > 0, max 5000 | "Укажите количество голов" |
| target_month | Required, future month | "Выберите месяц поставки" |

---

## F06 — Детали батча (Batch Detail)

### Meta
| Field | Value |
|-------|-------|
| Screen ID | F06 |
| Route | `/cabinet/market/batch/:batchId` |
| Auth | Authenticated farmer (batch owner) |
| RPCs | `rpc_publish_batch` (RPC-10, d07, deployed); `rpc_cancel_batch` (RPC-11, new); `rpc_get_price_for_sku` (RPC-17, new) |

### User Flow
```
1. Load batch data (from rpc_get_org_batches filtered by id)

2. Status-dependent actions:
   - draft: "Опубликовать" button + "Отменить" button + edit fields
   - published: "Отменить" button (if no matches). Show estimated price.
   - matched: Read-only. "Покупатель подобран" banner.
   - cancelled/expired: Read-only with status.

3. Publish → rpc_publish_batch → status=published, expires_at set
4. Cancel → rpc_cancel_batch → status=cancelled

5. Price preview: rpc_get_price_for_sku({ p_sku_id }) → show base_price + disclaimer
```

### UI Components
```
F06-BatchDetail
├── Header "Батч" + StatusBadge
├── BatchInfoCard (SKU, heads, weight, target_month, breed)
├── PricePreview (base_price + DisclaimerText ⚠️)
├── ActionButtons (Publish | Cancel — status-dependent)
├── MatchInfo (if matched: "Покупатель подобран, ожидайте")
│   └── After batch.confirmed / pool.closed_filled (A7, MARKET-UI-06): contact info revealed
│       ~~Legacy D40: pool.executing~~ — superseded by A7
└── Timeline (created → published → matched → confirmed → ...)
```

> **Contact-reveal canon (A7, MARKET-UI-06):** Contacts are revealed when `batch.status = confirmed` (which aligns with pool reaching `closed_filled` after `rpc_accept_offer`). The F06 banner MUST trigger on `batch.confirmed`, not on legacy `pool.executing` (D40).
>
> **Code debt MARKET-UI-02/06:** BatchDetail.tsx currently triggers the contact-reveal banner on legacy `pool.executing`. Must be updated to `batch.status = confirmed`. Not yet built.

---

## F07 — НЕ ОТДЕЛЬНЫЙ ЭКРАН

> CTO Decision: F07 (Cancel Batch) не нужен как отдельный экран. Отмена — кнопка на F06. Экономим экран.

---

## F09 — Справочные цены

### Meta
| Field | Value |
|-------|-------|
| Screen ID | F09 |
| Route | `/cabinet/market/prices` |
| Auth | Authenticated farmer |
| RPCs | `rpc_get_price_for_sku` (RPC-17, new) — per SKU; or bulk load from price_grids |

### UI Components
```
F09-PriceInfo
├── Header "Справочные цены" + DisclaimerBanner ⚠️ (ALWAYS visible)
├── PriceTable
│   ├── Row per SKU: | Категория | Базовая цена | Премиум | Регион |
│   └── Last updated date
├── DisclaimerText (Article 171 — full legal text)
└── EmptyState "Цены ещё не установлены"
```

### ⚠️ Article 171 Disclaimer
Every screen showing prices MUST display:
> "Справочные цены являются индикативными рыночными ориентирами. Участие добровольное."

---

## RPC Implementation Plan

| RPC | Screen | Status | File | Notes |
|-----|--------|--------|------|-------|
| `rpc_create_batch` (RPC-09) | F05 | ✅ Deployed | d07 | Health restriction check (D98) |
| `rpc_publish_batch` (RPC-10) | F06 | ✅ Deployed | d07 | Locks product cell |
| `rpc_get_org_batches` (AI-19) | F08 | ✅ Deployed | d07 | Farmer's own batches |
| `rpc_cancel_batch` (RPC-11) | F06 | ❌ NEW | d02 | draft/published → cancelled |
| `rpc_get_price_for_sku` (RPC-17) | F06, F09 | ❌ NEW | d02 | + disclaimer_text |
| `rpc_get_market_summary` (RPC-18) | F08 | ❌ NEW | d02 | Anonymous aggregates |

**3 new RPCs in d02_tsp.sql.**

---

## CTO Decisions

**D-S5-1:** F07 merged into F06 — cancel is a button, not a screen.
**D-S5-2:** F08 is the main market landing page (batches + summary). F05 is create form.
**D-S5-3:** Disclaimer text hardcoded as placeholder until legal review (D-LEGAL-1).
