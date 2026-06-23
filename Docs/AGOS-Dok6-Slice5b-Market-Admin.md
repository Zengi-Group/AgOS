# Dok 6 — Interface Contracts: Slice 5b "Market Admin"

> Version: 1.0 | Date: 2026-04-01
> Author: Architect Agent
> Status: DRAFT — D-LEGAL-1 applies
>
> **Scope:** 5 admin screens (A11–A15) — pool management, batch matching, pricing.

---

## Navigation

```
/admin
├── /admin/pools              → A11 (Pool Requests Queue)
├── /admin/pools/:poolId      → A12+A13+A14 (Pool Detail — activate, match, advance)
└── /admin/pricing            → A15 (Price Grid Management)
```

## CTO Decision D-S5-4: Merge A12+A13+A14 into single Pool Detail screen. Pool lifecycle (activate → match → advance) is one continuous workflow, not 3 separate pages.

---

## A11 — Очередь пул-запросов

| Field | Value |
|-------|-------|
| Route | `/admin/pools` |
| Auth | `fn_is_admin()` |
| RPCs | `rpc_create_pool_request` (RPC-12) for create; `.from('pool_requests')` for list (D-S6-1) |

## A12/A13/A14 — Pool Detail (lifecycle)

| Field | Value |
|-------|-------|
| Route | `/admin/pools/:poolId` |
| Auth | `fn_is_admin()` |
| RPCs | `rpc_activate_pool_request` (RPC-13), `rpc_match_batch_to_pool` (RPC-14), `rpc_advance_pool_status` (RPC-15), `rpc_rollback_batch_match` (RPC-16) |

### Pool FSM displayed (M4 canon — A6, MARKET-UI-03):
```
draft → filling → awaiting_mpk_decision → closed_filled
                                        → closed_partial
                                        → closed_unfilled
closed_filled → executing → completed
             → cancelled
filling → expired_empty
```
M4 canonical statuses: `draft, filling, awaiting_mpk_decision, closed_filled, closed_partial, closed_unfilled, executing, completed, cancelled, expired_empty`.

> **Code debt MARKET-UI-04 / TSP-SCHEMA-03 (A6):** PoolDetail.tsx still renders the legacy 7-state chain; `rpc_advance_pool_status` needs migration to M4 transitions. Neither is complete — do not treat this contract as shipped.

~~D40 (legacy): contacts revealed at pool `executing` transition.~~ Superseded by A7 — see contact-reveal section below.

## A16 — MPK Offer Inbox + Accept Flow

> **UI: NOT YET BUILT (code debt MARKET-UI-05)**
> Contract defined as canon fallback for no-auto-match scenario (A6). Screen must exist before TSP pilot; build is blocked on MARKET-UI-04 completion (PoolDetail.tsx M4 migration).

| Field | Value |
|-------|-------|
| Screen ID | A16 |
| Route | `/admin/offers` |
| Auth | `fn_is_admin()` |
| RPCs | `rpc_accept_offer` (M4 RPC — accept offer, FCFS, sibling offers withdrawn); read: `.from('offers')` filtered by status `pending` |

### User Story
MPK (buyer) submits a pool-fill Offer. Admin (or system) reviews the Offer inbox and accepts one. On acceptance: `rpc_accept_offer` executes FCFS logic — the accepted offer becomes `accepted`, all sibling offers for the same pool are withdrawn (`withdrawn`), pool transitions to `closed_filled`.

### UI Components
```
A16-OfferInbox
├── Header "Офферы MPK" + badge (count of pending offers)
├── OfferTable
│   ├── Columns: pool_id (link → A12), mpk_org, heads_offered, price_per_kg, submitted_at, status
│   ├── StatusBadge: pending | accepted | withdrawn | expired
│   └── Row action "Принять оффер" (only for pending) → confirm dialog → rpc_accept_offer
├── AcceptConfirmDialog
│   ├── "Принять оффер от [mpk_org] на [heads] голов по [price] ₸/кг?"
│   ├── Warning: "Все остальные офферы на этот пул будут отозваны (FCFS)"
│   └── Confirm → rpc_accept_offer({ p_offer_id, p_admin_id }) → success toast
└── EmptyState "Нет активных офферов"
```

### RPC contract
```
rpc_accept_offer(
  p_offer_id uuid,
  p_admin_id uuid   -- organization_id of acting admin
) → jsonb { ok: boolean, pool_id: uuid, withdrawn_count: int, error?: text }
```
- FCFS enforcement: first `rpc_accept_offer` call wins; concurrent calls on same pool return `{ok: false, error: 'OFFER_ALREADY_RESOLVED'}`.
- On success: accepted offer → `accepted`; sibling `pending` offers → `withdrawn`; pool → `closed_filled`.
- Contact info reveal fires at this transition (A7) — see contact-reveal section.

### Contact-reveal point (A7, MARKET-UI-06)
Contacts are revealed to both parties when `rpc_accept_offer` succeeds (pool reaches `closed_filled` / batch reaches `confirmed`). Legacy D40 (`pool executing`) is superseded.

> **Code debt MARKET-UI-02/06:** BatchDetail.tsx contact-reveal banner currently triggers on legacy pool `executing`. Must be updated to `batch.status = confirmed` (A7). Not yet done.

---

## A15 — Управление ценами

| Field | Value |
|-------|-------|
| Route | `/admin/pricing` |
| Auth | `fn_is_admin()` |
| RPCs | `rpc_set_price_grid` (RPC-19), `rpc_publish_price_index_value` (RPC-20); `.from('price_grids')` for list |

---

## RPC Plan (7 new in d02)

| RPC | Function | Notes |
|-----|----------|-------|
| RPC-12 | `rpc_create_pool_request` | MPK creates demand request |
| RPC-13 | `rpc_activate_pool_request` | Admin activates → auto-creates Pool |
| RPC-14 | `rpc_match_batch_to_pool` | Admin matches batch → pool, price snapshot |
| RPC-15 | `rpc_advance_pool_status` | FSM transition (M4 states — code debt MARKET-UI-04); contact reveal superseded by A7 (now at batch `confirmed` / pool `closed_filled` via `rpc_accept_offer`) |
| RPC-16 | `rpc_rollback_batch_match` | Remove match, revert pool counts |
| RPC-19 | `rpc_set_price_grid` | Upsert price + audit log trigger |
| RPC-20 | `rpc_publish_price_index_value` | Append price index value |
