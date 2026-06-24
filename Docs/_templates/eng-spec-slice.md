# Eng-Spec / Slice — <Feature / Slice name>

> In-repo engineering spec (detailed intent). The thin synthesis lives in the Brain
> (`apex-brain/projects/agos/specs/<feature>.md`) and POINTS here via `sources:`.
> Graphify indexes this file — keep entity/RPC/table names matching the SQL tokens.
> Apply order reminder: d01 → d02 → d03 → d04 → d05 → d07 → d08.

- **Brain synthesis:** [[projects/agos/specs/<feature>]]
- **Linear epic:** <link>
- **Canon domain owner:** <Microstep N | Dok X> (per CLAUDE.md Source-of-Truth table)
- **Status:** draft | agreed | building | shipped

## 1. Data model (P1 — first)
<entities touched, new columns (additive only), FK, FSM (text+CHECK). Who creates / updates /
is authority on conflict (P2). History vs current-only (P12). Incomplete-state behaviour (P11).>

## 2. RPC (Dok 3 contract)
<rpc_ names (registry-canonical), signatures (additive only — never modify existing, P7),
SECURITY DEFINER, organization_id in every call. Same fn for web + AI (no duplication).>

## 3. Events (Dok 4)
<domain.entity.action events produced/consumed; notification templates; proactive triggers.>

## 4. UI contract (Dok 6)
<screens, useSetTopbar() declaration (icon = Sidebar icon), states (empty/partial/error),
farmer-centric framing (P9). Warm palette = cabinet; neutral = expert console.>

## 5. Slices → Tasks
<feature decomposed: slice → concrete tasks. Each task = tier (mechanical | semantic) +
acceptance criteria. "Where it lives" is NOT frozen here — assembled at code-start from graphify.>

| Task | Tier | Acceptance |
|------|------|-----------|
| | mechanical / semantic | |

## 6. Conflict / invariant check (G1 inputs)
<does this break P7, touch FINAL schema, contradict a DECISIONS_LOG entry, or risk Art. 171 /
cross-org RLS leak? List the invariants this slice must not violate.>

## 7. Verification (G3 inputs)
<cross_check.sh expectations; RLS/FSM/compliance tests; preview proof; reality↔intent reconcile.>
