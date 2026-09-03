# AgOS · MPK Profile — Engineering Specification v0.1

> **Linear:** ARS-351 (epic), ARS-354 (G2 architecture sign-off)
> **Status:** agreed — architecture G2 approved 2026-07-30
> **Evidence baseline:** `Docs/AGOS-MPK-Profile-Live-Drift-Audit-ARS-352.md`
> **Reference viewport:** 1440×900, `theme=dark`, `contrast=max`, `uiScale=1`

This document is the normative engineering contract for the MPK organization profile.
It fixes the architecture needed by MP-1/MP-2 and the shell boundary needed by MP-3.
It does not replace the missing high-fidelity prototype, Slice10, or exact design-token
artifact. Their restoration remains a visual-fidelity gate, not a database gate.

## 0. G2 decision

**Decision:** `APPROVE-WITH-BOUNDARIES`.

- D-MPK-DESKTOP-01 through D-MPK-NARROW-06 are locked by this spec and
  `DECISIONS_LOG.md`.
- Schema/RPC implementation may start only after ARS-353 records the detailed
  convergence/migration ADR. It must follow the sources of truth in §6.
- Desktop visual implementation may build the shell geometry and isolation boundary.
  ✅ **Resolved 2026-09-01:** the prototype is in the repository at
  `Docs/prototype/Кабинет МПК v4.dc.html`, and the token artifact is
  `Docs/prototype/_ds/agos-9d11d37b-242b-4955-a814-eac7bd2332de/_ds_manifest.json`
  (full token registry) — a separate `DESIGN-TOKENS.md` is not needed. Extracted
  values, screen→data map and RPC coverage: `Docs/prototype/EXTRACT-tokens-and-data-map.md`.
  Type scale deviates from the DS by design — see `D-MPK-TYPE-01` in `DECISIONS_LOG.md`.
- No production migration or rollout is authorized by this document.

## 1. Product boundary

The profile answers one primary question for an MPK employee: **“Can we purchase
right now, and what needs action?”** It exposes six deep-linkable sections:

1. Overview (`overview`)
2. Enterprise (`enterprise`)
3. Admission (`admission`)
4. Team (`team`)
5. Reputation (`reputation`)
6. Appeals (`appeals`)

The feature is additive. Existing `/mpk`, `/mpk/tsp`, and `/mpk/offers` routes and
their Ionic navigation continue to work. A profile implementation must not silently
replace those screens, their mobile behavior, or their router history.

Out of scope for v0.1: multi-site editing UI, a new payment provider, WhatsApp,
redesign of the purchasing flows, and direct cancellation of a confirmed deal.

## 2. D-MPK-DESKTOP-01 — dedicated desktop console

**Choice.** `/mpk/profile/*` renders a dedicated desktop console inside the existing
authenticated MPK application boundary. It has its own 272 px sidebar, header, and
six-section navigation. The canonical route is `/mpk/profile/:tab`; an absent or
unknown tab redirects with `replace` to `/mpk/profile/overview`.

The console is a sibling surface to the Ionic purchasing shell, not a rewrite of
`MpkApp`. Authentication, selected organization, typed data clients, and logout are
shared; layout state, CSS scope, tab navigation, and page composition are profile-owned.

**Why.** The reference experience is information-dense and optimized for a 1440×900
workstation. Forcing it into the current phone frame would distort navigation and make
six operational sections compete with the purchasing flow.

**Rejected alternatives.** (a) Re-skin all `/mpk/*` routes as desktop: rejected because
it breaks the existing Ionic product and native navigation. (b) Mount the console in an
iframe or separate application: rejected because it duplicates auth, organization
selection, error handling, and release control. (c) Keep profile as a modal: rejected
because deep links, browser history, and long-form editing become unreliable.

**Consequences.** The application has two presentation shells under `/mpk`, so route
ownership and CSS containment must be explicit. Shared domain/data code is allowed;
shared global layout CSS is not.

**Migration impact.** Extend `MpkRoute`, `mpkRouteToUrl`, `mpkUrlToRoute`, and the v5
router outlet additively. Existing route keys and paths remain unchanged. Add router
tests for all six cold deep links, reload, back/forward, and return to `/mpk`.

**Rollback.** Remove the profile route registrations and entry affordance. Existing
Ionic routes remain deployable because no old path or route key is renamed.

## 3. D-MPK-THEME-02 — scoped dark/max theme

**Choice.** Dark/max styling is scoped below a single profile root, for example
`[data-mpk-profile-theme="dark-max"]`. Profile tokens use a dedicated `--mpk-profile-*`
namespace or locally remap design-system primitives inside that root. No profile style
may mutate `:root`, `html`, `body`, `.phone`, Ionic variables, or the farmer-cabinet
palette. Product code exposes no theme/contrast toggle for this surface in v0.1.

**Why.** The prototype requires a stable dark, maximum-contrast console while the
rest of AgOS contains warm farmer and Ionic surfaces. Root-level overrides would leak
across persistent router outlets and modals.

**Rejected alternatives.** (a) Global `.dark`/body class: rejected due to cross-shell
leakage. (b) Runtime theme switcher: rejected because it multiplies visual acceptance
states without a product requirement. (c) Recalculate “close enough” tokens from the
current design system: rejected because the epic requires exact fidelity.

**Consequences.** Modals, portals, toasts, and popovers belonging to profile must carry
the same scope explicitly if they render outside the root. Exact token values remain
blocked on the missing token/prototype artifacts; invented replacement values are not
canonical.

**Migration impact.** Add a profile-only stylesheet/token module and a leak regression
that mounts an Ionic MPK screen and the profile shell in one test document. Fonts and
assets must be self-hosted or loaded through the existing app asset pipeline.

**Rollback.** Remove the profile root and stylesheet. Since no global variable changes
are allowed, other product surfaces require no compensating rollback.

## 4. D-MPK-CRIT-03 — critical organization fields

The production organization identity remains in `organizations` using canonical names:
`legal_name`, `bin_iin`, `region_id`, `address_text`, `phone`, and `email`.

| Field | Save behavior | Review behavior | Rejection behavior |
|---|---|---|---|
| `legal_name` | Apply to `organizations.legal_name` immediately | Append a pending `org_field_reviews` record with old/new values and actor/time | Reviewer requests correction; no silent automatic revert |
| `address_text` | Apply immediately | Same append-only review trail | Reviewer requests correction; no silent automatic revert |
| `bin_iin` | Keep production value unchanged | Store proposed value as pending | Reject proposal; production value is untouched |

BIN approval must atomically lock the pending proposal, update
`organizations.bin_iin`, and mark the review approved with reviewer/time. At most one
pending proposal per organization and field is allowed. All three write paths require
an MPK profile-edit permission; approve/reject requires TURAN authority.

**Why.** Name/address corrections need immediate operational usefulness and an audit
trail. BIN is a regulated identifier whose premature replacement can corrupt deal and
document identity.

**Rejected alternatives.** (a) Hold all three fields until approval: rejected because
ordinary name/address corrections would unnecessarily block the business. (b) Apply
BIN immediately then roll it back: rejected because downstream documents could observe
the unapproved identifier. (c) Overwrite a single “pending values” JSON object: rejected
because concurrency, field authority, and audit history become ambiguous.

**Consequences.** Name/address review is supervisory rather than a publication gate.
Deal documents must continue to snapshot the identity used at deal time; they never
re-read mutable organization fields to rewrite history.

**Migration impact.** ARS-359 adds the field-review entity, partial pending index, RPC
authorization, and an idempotent migration. There is no `mpk_profiles` backfill on the
audited live baseline because the table is absent.

**Rollback.** Disable the new write RPCs first. Pending proposals remain auditable.
BIN has a deterministic old value in the approved review record for an operator-led
compensating change; name/address are restored only by a new audited edit, never by
destructive deletion of history.

## 5. D-MPK-ROLES-04 — MPK roles and permission enforcement

**Choice.** The four MPK-facing roles are:

| Role key | UI label | Intended authority |
|---|---|---|
| `mpk_admin` | Администратор | Profile, documents, team/invitations, and all operational permissions |
| `procurement` | Закупщик | Purchasing, counterparty review, and permitted deal documents |
| `receiver` | Приёмщик | Receiving/acceptance operations and related evidence |
| `accountant` | Бухгалтер | Banking and permitted financial/deal-document reads/writes |

They are additional allowed values in the existing `user_organization_roles` store;
there is no `org_member_roles` or second role-assignment table. Existing
`owner/manager/employee/viewer` rows remain valid. ARS-353/356 must define a one-way
compatibility permission mapping for legacy rows; it must not bulk-relabel users based
on guesses.

Authorization is permission-based. A canonical helper/catalog maps roles to permissions
such as `mpk.profile.edit`, `mpk.team.manage`, `mpk.purchase`, `mpk.receive`,
`mpk.bank.manage`, and `mpk.review.submit`. Every mutating RPC checks organization
ownership and the required permission inside the database. UI hiding/disabling is only
an affordance and is never the security boundary.

**Why.** The four jobs have materially different duties, while a single existing
user↔organization assignment store preserves tenant membership and avoids conflicting
role truth.

**Rejected alternatives.** (a) Frontend-only role gates: rejected as bypassable.
(b) A parallel MPK membership/role table: rejected because assignments drift.
(c) Force-fit the four jobs onto `owner/manager/employee/viewer`: rejected because
receiver and accountant permissions are not a safe synonym for employee/viewer.

**Consequences.** The role CHECK and all consumers must accept legacy and MPK role
keys during transition. Permissions, not raw role-string comparisons, become the stable
contract for new profile RPCs.

**ARS-356 permission matrix.** `organization_permissions` is the stable code catalog;
`organization_role_permissions` is definition data only and contains no user or
organization assignment. `fn_org_has_permission(organization_id, permission_code)`
derives the current caller and resolves the following explicit mapping:

| Role | Permissions |
|---|---|
| `owner`, `manager`, `mpk_admin` | all nine permissions below |
| `employee` | `mpk.purchase`, `mpk.receive`, `mpk.review.submit`, `mpk.deal_documents.read` |
| `viewer` | `mpk.deal_documents.read` |
| `procurement` | `mpk.purchase`, `mpk.review.submit`, `mpk.deal_documents.read`, `mpk.deal_documents.manage` |
| `receiver` | `mpk.receive`, `mpk.deal_documents.read`, `mpk.deal_documents.manage` |
| `accountant` | `mpk.bank.manage`, `mpk.deal_documents.read`, `mpk.deal_documents.manage` |

The nine catalog codes are `mpk.profile.edit`, `mpk.documents.manage`,
`mpk.team.manage`, `mpk.purchase`, `mpk.receive`, `mpk.review.submit`,
`mpk.deal_documents.read`, `mpk.deal_documents.manage`, and `mpk.bank.manage`.
In particular, `procurement` and `accountant` do not receive profile, organization-
document, or team-management authority.

**ARS-356 invitation contract.** `org_invitations` is a temporal FSM, not a role
assignment store. It allows `sent→accepted|revoked|expired`; terminal states cannot
reopen. A partial unique index permits one `sent` row per
`(organization_id, lower(email))`. Tokens are 32 random bytes represented as hex;
only SHA-256 is stored. Create/resend return the raw token once for the delivery layer,
and no table/RPC read returns `token_hash`. Resend rotates the token, extends expiry to
72 hours, and has a 60-second minimum interval.

| RPC | Required authority | Exact result contract |
|---|---|---|
| `rpc_create_org_invitation(org_id,email,role)` | `mpk.team.manage` | JSON `{ok,id,organization_id,email,role,status,token,expires_at,resend_count}` |
| `rpc_resend_org_invitation(org_id,invitation_id)` | `mpk.team.manage` | same JSON on success; `{ok,id,status}` when terminal/expired |
| `rpc_revoke_org_invitation(org_id,invitation_id)` | `mpk.team.manage` | JSON `{ok,id,status,idempotent?}` |
| `rpc_accept_org_invitation(token)` | authenticated user with matching verified email | JSON `{ok,id,organization_id?,role?,status,idempotent?}` |
| `rpc_list_org_invitations(org_id)` | `mpk.team.manage` | rows `{id,email,role,status,sent_at,last_sent_at,expires_at,accepted_at,revoked_at,expired_at,resend_count,created_at,updated_at}` |

Acceptance locks the invitation row, binds the verified Auth email, and atomically
inserts into `user_organization_roles`. A same-user retry is idempotent; a competing
user cannot consume an accepted token. The token itself carries the organization
binding, so acceptance deliberately does not trust a client-supplied organization ID.

**Migration impact.** Add CHECK values without rewriting rows; deploy the permission
helper before RPCs that depend on it; then add invitations. Contract tests cover every
role/permission pair, cross-tenant denial, and legacy compatibility.

**Rollback.** Stop assigning the four new values and disable dependent write entry
points. Do not shrink the CHECK while any rows use them. Existing legacy rows and
permissions remain intact.

## 6. D-MPK-CANON-05 — sources of truth

The profile is a composed read model, not a new vertical database. The normative map is:

| Concern | Canonical write/history source | Profile rule |
|---|---|---|
| Organization identity | `organizations` | Use real column names; UI aliases never rename storage |
| MPK editorial metadata | narrow `mpk_profiles` extension keyed by `organization_id` | Only fields with no better domain owner, initially public description/logo metadata |
| Sites/capacity | `mpk_sites` | Multi-site model; v0.1 UI edits the primary site only |
| Bank details | versioned `org_bank_accounts` | Append/version updates; deal snapshots remain immutable |
| Field review | `org_field_reviews` | Append-only proposal/review trail described in §4 |
| Membership | `membership_subscription` + `fn_org_membership_active` | State and real `current_period_*`; never invent `memberships.expires_at` |
| Verification | append-only `verification_records` | `organization_type_assignments` classifies org type; it is not approval evidence |
| Documents | `org_documents` + private document Storage | Registry owns lifecycle; raw Storage rows do not |
| Roles | `user_organization_roles` + permission helper | One assignment store; UI is not enforcement |
| Reviews | `deal_reviews` + `deal_review_dimension_scores` | Notes-based paths are compatibility adapters only |
| Appeals | `comm_messages` for content + `org_appeal_cases` metadata over the permanent support channel | Multiple cases per org; no duplicated `answer` field |

`mpk_profiles` does not exist in the audited repo/live baseline. G2 chooses to create it
only as a **narrow organization extension**, not as a catch-all snapshot. It must not
duplicate legal identity, membership dates/state, verification status, roles, reviews,
document lifecycle, site capacity, or bank data. The legacy handwritten TypeScript
shape and direct `.from('mpk_profiles' as any)` hook are deprecated and may not define
the new table. Reads/writes go through typed RPC contracts.

**Why.** This mapping preserves one authority per fact while allowing MPK-specific
editorial fields that do not belong in the organization kernel.

**Rejected alternatives.** (a) One wide `mpk_profiles` table mirroring every tab:
rejected because membership, verification, roles, reviews, and appeals would drift.
(b) No extension table at all: rejected because public MPK description/logo metadata
has no stable domain owner. (c) Treat live schema or handwritten TS as authoring canon:
rejected; live is deployment evidence and TS is a generated consumer contract.

**Consequences.** Overview and farmer-preview RPCs join canonical entities. Empty live
subscription/verification data is a valid empty state; UI must not synthesize dates,
approval, or progress. MPK preview and the real farmer-facing card use one read-model/RPC,
including the same pre/post anonymity policy.

**Migration impact.** Detailed entity ownership, adapter retirement, backfill logic,
and deployment order are locked by
`Docs/AGOS-MPK-Profile-Convergence-ADR-ARS-353.md`. Required order is additive:
security defect fixes/permission base → narrow entities → compatibility/backfill →
typed RPCs → UI → adapter retirement after observed zero legacy callers.

**Rollback.** Preserve old adapters while the new read model rolls out behind a feature
flag. Disable new writers/readers before removing new objects. Never roll back by
copying derived profile data into a second authority.

## 7. D-MPK-NARROW-06 — narrow/mobile behavior and Ionic entry

**Choice.** The full console is supported at viewport widths **≥1024 px**. At narrower
widths, `/mpk/profile/:tab` renders a profile-owned Ionic bridge page, not a compressed
272 px desktop canvas. The bridge shows organization name, current admission/action
summary from the same overview RPC, the requested section label, and a clear message
that full viewing/editing requires a larger screen. It provides “Back to MPK” and a
copyable deep link. It performs no profile mutation.

The existing `/mpk` home gets a first-class “Профиль предприятия” card/row. It routes
to `/mpk/profile/overview` through the existing Ionic router. Browser history and the
hardware/system back action return to the originating MPK screen. Direct links to any
of the six profile tabs are preserved; narrow rendering must not rewrite them to the
overview path.

**Why.** This keeps the operational profile discoverable on installed/mobile AgOS
without pretending the approved desktop interaction fits a phone. A read-only status
bridge still answers whether action is required and gives users a stable handoff URL.

**Rejected alternatives.** (a) CSS-scale or horizontally scroll the desktop console:
rejected for accessibility and accidental-edit risk. (b) Hide the feature on mobile or
404 deep links: rejected because the installed Ionic shell is an existing entry point.
(c) Build a second editable mobile profile now: rejected because it doubles interaction,
validation, and visual acceptance scope.

**Consequences.** Responsive behavior is a rendering decision under the same routes,
not a UA redirect. Server/RPC authorization is identical on desktop and narrow. Mobile
editing can be added later as explicit section-specific flows without changing URLs.

**Migration impact.** Add the home entry, media-query/matchMedia host boundary, bridge
screen, focus announcement, and router tests at 375×812, 768×1024, 1024×768, and
1440×900. Test rotation/resizing without losing the requested tab.

**Rollback.** Remove the entry and profile route host; existing `/mpk` screens remain
unchanged. If the desktop console is feature-flagged off, profile deep links return a
controlled unavailable screen rather than falling through to `/mpk` home.

## 8. RPC and read-model boundary

The exact catalog and signatures are delivered by MP-2, but these invariants are locked:

- one typed initial read per tab; no direct table reads from profile UI;
- one shared organization-card read model for profile preview and farmer-facing use;
- callers cannot request `post` identity disclosure; the server derives disclosure from
  the deal relationship/state;
- pre-disclosure payload and DOM contain no legal name, BIN, address, phone, or hidden
  review content;
- all writes derive/check caller, organization membership, and permission inside the RPC;
- `SECURITY DEFINER` functions use a fixed `search_path`, revoke `PUBLIC` and `anon`,
  and grant only the minimum intended roles;
- errors are typed and safe for UI; token hashes, auth internals, private file paths,
  and hidden counterparty content never leave the server.

## 9. Security and data acceptance

Before any MPK Profile object is production-ready:

1. RLS is enabled on every exposed table; UPDATE has SELECT, USING, and WITH CHECK.
2. Every FK, tenant predicate, status filter, and expiry scan used by the profile has a
   supporting index; active/pending/open queries use partial indexes where appropriate.
3. Tenant A cannot list/read/write tenant B through tables, RPCs, or Storage.
4. Anonymous users cannot select private data or execute profile writes.
5. `deal_review_dimension_scores` RLS/grants and `rpc_submit_deal_review` caller binding
   are fixed and behavior-tested before reputation convergence.
6. The `membership-documents` private bucket may be reused only with an explicit
   registry, MIME/size limits, organization path ownership, and short-lived signed URLs.
7. Empty subscription and verification datasets render honest empty/incomplete states.

## 10. Migration, rollout, and rollback sequence

1. Merge ARS-352 audit evidence and this sign-off.
2. Apply the accepted ARS-353 convergence ADR with entity ownership, compatibility
   adapters, retirement conditions, and exact apply order.
3. Close prerequisite review ACL/RLS defect locally/preview before review convergence.
4. Apply additive schema changes and permission catalog; no destructive rename/drop.
5. Add typed RPC contracts and generated TypeScript/Zod consumers; remove profile
   `as any` usage.
6. Ship profile routing and shell behind an organization-scoped feature flag.
7. Seed staging with empty, partial, pending, approved, expired, and cross-tenant cases.
8. Pass DB contracts, router regressions, 1440×900 visual regression, accessibility,
   and anonymity payload/DOM tests.
9. Roll out progressively. Monitor RPC error rate, authorization denials, read latency,
   invitation delivery, document failures, and appeal unread drift.
10. Retire compatibility adapters only after code search, production telemetry, and a
    documented zero-caller window.

Rollback proceeds in reverse at the consumer boundary: disable flag → restore old
readers/adapters → stop new writers → preserve additive tables/history for diagnosis.
Destructive down migrations are not the production rollback mechanism.

## 11. G2 acceptance record

ARS-354 is complete when both this EngSpec and `DECISIONS_LOG.md` contain the six locked
decisions with choice, reason, consequences, rejected alternatives, migration impact,
and rollback impact. This file satisfies the engineering side of that contract.

Remaining gates are explicit and owned elsewhere:

- ARS-353: accepted convergence ADR; downstream schema/RPC work must follow it;
- ~~missing `DESIGN-TOKENS.md` and `prototype/mpk-cabinet-v4.dc.html`~~ ✅ **closed
  2026-09-01**: prototype → `Docs/prototype/Кабинет МПК v4.dc.html`; token registry →
  `Docs/prototype/_ds/…/_ds_manifest.json`; extraction → `Docs/prototype/EXTRACT-tokens-and-data-map.md`;
  `AGOS-Dok6-Slice10-MPK-Profile.md` → written 2026-09-01 (screen contract);
- ARS-358/360 and the recorded security defect: close review ACL/RLS behavior before
  the reputation surface can ship;
- G3: production migration/deployment approval after tests and staging evidence.
