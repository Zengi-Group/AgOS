---
name: feature
description: Entry orchestrator for AgOS feature development. One command owns the end-to-end flow from "хотим фичу X" to shipped — orient, Linear task, conflict scan, design, record intent, code, verify, close. Hybrid automation (Mode C): mechanical anchors run automatically, semantic anchors stop at a human gate. Delegates to the existing architect/db/backend/ui/qa agents; never replaces them.
command: /feature
---

# /feature — Feature Flow Orchestrator (AgOS)

Single entry point. The human says **«хотим фичу X — …»** and you drive the whole flow.

You are the **conductor, not a new worker.** You run 8 anchors and delegate to the existing
domain agents (`architect`, `db-agent`, `backend-agent`, `ui-agent`, `qa-agent`) at the right
points. Your job is to **move facts between homes so the human doesn't have to.**

**Mode = C (hybrid):** mechanical anchors run automatically (🤖); semantic anchors stop at a
human gate (🚦). This is the deliberate quality contract — every past regression (HS-1…6)
happened when automation skipped a *semantic* gate. Speed comes from automating mechanics,
not from blurring decisions.

---

## The homes — one fact, one home (never duplicate)

| Home | Fact it owns | Kind |
|------|--------------|------|
| Brain (`apex-brain`) | decision, status, synthesis, open questions | замысел |
| Claude Design (Anthropic) | UX prototype | замысел (UI) |
| Repo `Docs/` (Dok/Microstep/Slice) | engineering spec: data-model · RPC · events · UI | замысел (detailed) |
| Linear | task: assignee, status, priority, pointer + acceptance | работа |
| GitHub / Supabase | code, schema, data | реальность |
| Graphify (`graphify-out/`) | machine map over code+docs — "where things live" | реальность (index) |

Graphify is **not a home** — it is the engine's eyes. Query it; never copy it into the Brain.

## Two altitudes of intent (the rule that keeps homes clean)

- **Brain** `apex-brain/projects/agos/specs/<feature>.md` — the **synthesis**: what the feature
  *is*, the decision, status (`draft→agreed→building→shipped`), open questions, links. Thin.
  Template: `apex-brain/_templates/spec.md`.
- **Repo** `Docs/` (Dok / Microstep / Slice) — the **engineering spec**: data-model, RPC,
  events, UI-contract. Detailed, graphify-indexed. Template: `Docs/_templates/eng-spec-slice.md`.
- The Brain page **points** to the Doc via `sources:`. **Never copy the engineering spec into
  the Brain** (Brain canon: sources are read, never copied whole).

## The 6 artifacts + contract

| # | Artifact | Home | Who writes | Opened by |
|---|----------|------|-----------|-----------|
| 1 | Feature-brief | Brain `specs/<f>.md` | /feature (draft) | anchor 1 |
| 2 | UX prototype | Claude Design | human + assist | anchor 4 |
| 3 | Eng-spec / Slice | Repo `Docs/` | `architect` (+ db/ui input) | G2 passed |
| 4 | Task | Linear | /feature | anchor 5 |
| 5 | Code / Migration | GitHub / Supabase | db/backend/ui (tiered) | anchor 6 |
| 6 | Decision | `DECISIONS_LOG.md` + Brain | `architect` / /feature | anchor 8 |

---

## The 8 anchors

**1 · Orient** 🤖
Read Brain `specs/<feature>.md` (if exists) + `graphify query "<feature>"` (what's in code, where
canon lives) + `git log --oneline -10` + `git diff --stat`. Emit a 5-line **intake card**:
`что это · какие сущности трогает · дельта замысел↔код · риски-конфликты · затронутые файлы/коммьюнити`.

**2 · Linear task** 🤖
Create a Linear task for X with the intake card as context, a content-hash for dedup, and a
*draft* priority/assignee the human can flip. Store only a **pointer + acceptance**, not a spec copy.

**3 · Conflict scan** 🤖 → 🚦 **G1 (conditional)**
Two-level: (a) light — does X overlap existing prior art or contradict a Brain/`DECISIONS_LOG`
decision? (b) once targets are known — does X break P7 (RPC signature), touch FINAL schema, or
violate an invariant? **Clean → continue without stopping. Conflict → STOP, human decides.**

**4 · Design** 👤 + assist → 🚦 **G2 (always)**
Brainstorm intent; for UI build the prototype in Claude Design; **data-model first (P1)**. Derive
backend/DB/frontend requirements by filling the eng-spec template (Dok1 data-model · Dok3 RPC ·
Dok4 events · Dok6 UI). `architect` drafts the spec; `db-agent`/`ui-agent` give input.
**G2 = human approves the intent/spec.** This is the main semantic gate — quality is decided here.

**5 · Record intent** 🤖 (after G2)
Write Brain `specs/<feature>.md` (synthesis + decision + `sources:` links to graphify nodes/Doc),
update `index.md` + `log.md`; `architect` commits the eng-spec/slice to `Docs/`; fill Linear task
details + decompose feature → slices → tasks.

**6 · Code** 👤 (tiered)
Delegate to `db-agent` / `backend-agent` / `ui-agent`. **Tiering:** *mechanical* task (additive
column, wire existing RPC, port a screen) → agent may code autonomously; *semantic* task
(new data-model, FSM/RLS/business-rule, RPC signature) → human-led. `graphify` finds **all**
edit sites (L-2). Edit not Write; additive; SQL into canonical domain files.

**7 · Verify** 🤖
`cross_check.sh` + tests + preview via `qa-agent`; `graphify update .`; compare reality↔intent.
Any divergence → auto-draft an `IMPL_DEBT.md` entry.

**8 · Close** 🤖 → 🚦 **G3 (always)**
`qa-agent` verdict → `architect` gate sign-off. **G3 = human approves merge/deploy (Vercel).**
After merge: append `DECISIONS_LOG.md` (what/why/files), Brain status → `shipped`, Linear → done,
brain `log.md` line.

---

## The 3 gates (what blocks)

- **G1 — conflict** (anchor 3, conditional): fires only on a detected conflict with intent/canon.
- **G2 — approve intent/spec** (anchor 4, always): the quality gate.
- **G3 — merge/deploy** (anchor 8, always): the irreversible gate. Never auto.

Everything else is 🤖 mechanical and runs without asking.

## Prompt assembly — variant B (never store a frozen prompt)

At code-start, **assemble the run-prompt fresh**: Brain spec (what + why + acceptance) + a live
`graphify query`/`path` (where it lives: files / RPC / tables) + inherited hard rules below.
Linear holds only the pointer + acceptance — so the prompt is rebuilt against the *current* graph
and can never go stale (respects P4: spec lives in one home).

## Inherited hard rules — never violate (from CLAUDE.md)

- **graphify-first** before reading source (the repo hook enforces this).
- **Edit, not Write**; **additive only** (HS-1/5); **never delete working features** (HS-2).
- **Confirm before commit** in both repos; **ask then fix** (architect principle).
- SQL idempotent, into **canonical domain files**, no patch files; never modify RPC signatures (P7).
- RLS mandatory; `organization_id` in every call; dosages only from `vet_products` (D61).
- TSP is coordination infra, not a marketplace (Art. 171) — antitrust disclaimer where prices show.

## What /feature does NOT do

- Does **not** replace `architect` — architect still owns Dok/`DECISIONS_LOG` and the gate sign-off.
- Does **not** auto-merge or auto-deploy — G3 is always human.
- Does **not** write the engineering spec itself — it delegates to architect/db/ui.

Canonical process record: `apex-brain/patterns/feature-flow.md`. Pairs with
`apex-brain/patterns/parallel-dev-process.md` (the git/branch/preview layer).
