# ADR-MPK-CONVERGENCE-01 · MPK Profile canonical convergence

> **Linear:** ARS-353 · MP-0.3
> **Status:** Accepted for implementation
> **Accepted:** 2026-07-30
> **Scope:** membership · verification · RBAC · reviews · appeals · `mpk_profiles`
> **Production deploy:** not authorized by this ADR; G3 remains a separate gate
> **Evidence baseline:** `Docs/AGOS-MPK-Profile-Live-Drift-Audit-ARS-352.md`
> **Parent contract:** `Docs/AGOS-MPK-Profile-EngSpec-v0_1.md`, D-MPK-CANON-05

## 1. Decision

MPK Profile is a composed read model over existing domain authorities. It must not
create a second vertical data model for facts that already have an owner.

The accepted authorities are:

- membership lifecycle and dates: `membership_subscription`; access predicate:
  `fn_org_membership_active`;
- organization classification: `organization_type_assignments`; verification history:
  append-only `verification_records`;
- role assignment: `user_organization_roles`; permissions are resolved above that
  assignment, not in a second membership/role table;
- review history: `deal_reviews` and `deal_review_dimension_scores`;
- message bodies and attachments: `comm_messages`; appeal case/topic/reference/status
  are metadata above the permanent support channel;
- MPK-only editorial data: a narrow `mpk_profiles` organization extension;
- organization identity, site/capacity, bank details, documents, and field-review state
  remain in their owners defined by the EngSpec and are not copied into `mpk_profiles`.

Convergence is additive. Existing signatures remain available while their internals
are rebound to canonical storage. After backfill, compatibility reads may fall back to
legacy storage, but all new writes go to one canonical store only. Destructive cleanup
happens only after the retirement gates in §9.

## 2. Context and evidence

ARS-352 established these repo/live facts:

1. `membership_subscription` already owns `state`, `current_period_start`, and
   `current_period_end`; `fn_org_membership_active` also preserves the legacy
   `memberships.level` bridge.
2. `organization_type_assignments` contains type and assignment metadata, not a
   verification FSM. `verification_records` is the append-only evidence timeline.
3. `user_organization_roles` is the existing user↔organization assignment authority.
4. Canonical double-blind review tables exist, while `batches.notes.review` and
   `batches.notes.mpk_review` are still used through compatibility RPCs.
5. Messaging has one permanent `support` channel per organization and append-only
   `comm_messages`; it has no multi-case appeal model.
6. `mpk_profiles` is absent from canonical SQL and the audited live database. Its
   handwritten TypeScript interface and direct `as any` hook have no consumers and
   are not a storage contract.
7. The review ACL/RLS defect found by ARS-352 must be closed before review convergence.

The decision also follows the accepted G2 constraint D-MPK-CANON-05: one authority per
fact and one server-derived organization-card read model for both MPK preview and the
farmer-facing surface.

## 3. Entity map

| Concern | Entity / boundary | Cardinality and key | Canonical facts | Explicitly excluded |
|---|---|---|---|---|
| Organization identity | `organizations` | one row per organization, PK `id` | `legal_name`, `bin_iin`, `region_id`, `district_id`, `address_text`, contacts | subscription, verification, roles, reviews |
| MPK classification | `organization_type_assignments` | unique organization + `org_type` | `org_type`, `assigned_at`, `assigned_by` | approval state, expiry, evidence |
| MPK editorial extension | `mpk_profiles` | exactly zero/one row per MPK organization; PK/FK `organization_id` | `public_description`, `logo_path`, timestamps | legal identity, dates/state of membership, site capacity, bank data, verification, roles, reputation, appeal state |
| Membership lifecycle | `membership_subscription` | history per organization; partial unique live row | `state`, trial/period/billing dates, plan snapshot | verification or org type |
| Membership access | `fn_org_membership_active(uuid)` | derived boolean | access-on for subscription `trialing/active/grace`, with documented legacy level fallback | caller authorization; callers must still check org ownership |
| Verification timeline | `verification_records` | append-only rows per membership/org | type, result, verifier, evidence, verification/expiry dates | current org classification |
| Role assignment | `user_organization_roles` | unique user + organization | one assigned role, primary-org marker | invitation lifecycle, permission definition |
| Permission definition | permission catalog/helper delivered by ARS-356 | role + permission code | allowed capability set and legacy-role mapping | duplicate user↔org assignment |
| Canonical reviews | `deal_reviews` | unique batch + reviewer organization | reviewer role, overall score, comment, submission/reveal time | aggregates copied to profile |
| Review dimensions | `deal_review_dimension_scores` | unique review + dimension | per-dimension score | separate visibility rule; it inherits the parent review |
| Messaging channel | `comm_channels` | one permanent support channel per organization | channel lifecycle and inbox ordering | appeal case lifecycle |
| Message content | `comm_messages` | append-only ordered messages per channel | body, attachments, author, time | case answer/status/topic fields |
| Appeal case | `org_appeal_cases` | many cases per support channel | org, channel, topic, immutable reference, status, actors/timestamps | message body or duplicated `answer` |
| Appeal↔message link | `org_appeal_case_messages` | many messages per case; unique `message_id` | case membership and ordering link | duplicated message content |

### 3.1 `mpk_profiles` canonical contract

The first canonical DDL is deliberately narrow:

| Column | Contract |
|---|---|
| `organization_id uuid` | primary key and FK to `organizations(id)`; the extension cannot exist without its organization |
| `public_description text` | nullable editorial description; bounded and trimmed by the write RPC |
| `logo_path text` | nullable storage asset path, never a trusted arbitrary HTML/image payload |
| `created_at timestamptz` | immutable creation timestamp |
| `updated_at timestamptz` | maintained by the standard update trigger |

The table is sparse: do not create an empty row for every MPK. The read model uses a
left join, and the first authorized edit performs an upsert. Adding any future column
requires an ownership review proving that no existing domain already owns the fact.

The following legacy TypeScript fields do **not** define this table:
`annual_demand_heads`, `processing_capacity_per_day`, `preferred_categories`,
`preferred_regions`, and generic `notes`. Capacity belongs to `mpk_sites`; procurement
preferences need their own approved domain owner if product scope later requires them.
Ambiguous `notes` are never auto-published as `public_description`.

### 3.2 Appeal composition

The permanent support-channel invariant remains unchanged. An organization may have
many `org_appeal_cases` referencing that one channel. Messages are created through
messaging and linked to exactly one appeal case by `org_appeal_case_messages`.
Unlinked messages remain valid general support conversation.

New appeal RPCs atomically:

1. authorize the caller for the organization/case;
2. create or lock the case;
3. call the canonical messaging write path;
4. link the returned message to the case;
5. advance case status and emit the platform event.

There is no `answer`, `answer_text`, or duplicated attachment column on a case.
TURAN replies are ordinary `comm_messages` linked to the case. The case stores only
workflow metadata.

## 4. Ownership map

| Entity / operation | Organization user | TURAN admin/operator | Service/system | Read model |
|---|---|---|---|---|
| `mpk_profiles` editorial write | allowed only with the MPK profile permission for own org, through RPC | allowed with audited admin permission | no routine write | own-org profile RPC; farmer-facing RPC suppresses identity/logo before server-derived reveal |
| `membership_subscription` lifecycle | subscribe/cancel through guarded billing RPC where already allowed | lifecycle/revoke through guarded admin RPC | renewal engine; service role only | state/real dates from subscription; access boolean from `fn_org_membership_active` |
| `verification_records` append | no direct write | append verification result; never update history | expiry/notification checks may read, not rewrite evidence | latest applicable result derived by org/type/date |
| `user_organization_roles` | invitation/role changes only with team-management permission | audited support override | accepted invitation may materialize assignment atomically | permission helper resolves role; clients do not authorize from raw role alone |
| `deal_reviews` write | delivered deal party, derived from caller organizations | no impersonated party write | reveal timeout job may set `visible_at` under defined policy | own review before reveal; counterparty only after mutual/timeout reveal |
| `deal_review_dimension_scores` write | only inside canonical review transaction | no direct Data API write | same transaction/service maintenance | visibility inherited from parent review |
| `org_appeal_cases` open/reply | own org with appeal permission | reply and allowed status transitions | expiry/reminder checks, no message fabrication | own org or authorized operator |
| `comm_messages` appeal content | through appeal/message RPC | through appeal/message RPC | notification fan-out reads preview only | tenant-scoped, case-linked thread projection |

Hard ownership rules:

- every mutating RPC derives the current user and validates organization membership and
  permission inside the database;
- a client-supplied `organization_id` selects context but never proves authorization;
- admins act as admins and are recorded as such; they do not masquerade as a deal party;
- generated UI types and role labels are consumers, not authorization authorities;
- aggregates such as reputation score and readiness are derived, never writable fields.

## 5. Domain convergence rules

### 5.1 Membership

The profile membership projection returns both lifecycle and access, without conflating
them:

- `state`, `current_period_start`, `current_period_end`, `trial_end`, and plan data come
  from the current `membership_subscription`;
- `is_active` comes from `fn_org_membership_active(organization_id)`;
- `past_due`, `expired`, `canceled`, and `revoked` are not access-active;
- if the predicate is true only because of its documented legacy
  `memberships.level <> 'registered'` fallback, the projection returns
  `source='legacy_membership'`, `state=null`, and `current_period_end=null`;
- no UI or adapter may invent a period end from `memberships`, plan duration, or current
  time;
- the renewal cron remains disabled until the real charge provider and G3 authorize it.

No new membership table, `memberships.expires_at`, or profile-owned status is allowed.

### 5.2 Verification

`organization_type_assignments` answers “what kind of organization is this?” and
provides assignment metadata. It never gains `status`, `approved_at`, `expires_at`, or
review evidence.

The verification projection:

1. selects the MPK assignment;
2. follows the relevant `memberships` row for `org_type='mpk'`;
3. reads append-only `verification_records`;
4. derives the latest result per verification type using `verified_at`, with
   `expires_at <= now()` treated as expired;
5. keeps rejected/conditional history and never updates old evidence in place.

An empty verification history is an honest incomplete state, not a synthetic first
approval step.

### 5.3 RBAC

`user_organization_roles` remains the only role-assignment store. ARS-356 may extend
its role CHECK with the accepted MPK job roles `mpk_admin`, `procurement`, `receiver`,
and `accountant`, while preserving `owner`, `manager`, `employee`, and `viewer`.

Permission codes are stable API contracts. A catalog/helper may map both new and
legacy role values to permissions, but it must not contain a second user↔organization
assignment. The legacy mapping is explicit seed/config reviewed by ARS-356; no RPC may
guess permissions from string prefixes or UI labels.

Safe order: expand CHECK → seed permission mapping → deploy helper and contract matrix
→ deploy dependent invitation/write RPCs → allow assignment of new role values.
Rollback stops new assignments and dependent entry points; it never narrows the CHECK
while rows still use the added values.

### 5.4 Reviews

After convergence, all review writes land only in `deal_reviews` and
`deal_review_dimension_scores`.

The existing client signatures remain temporarily:

- `rpc_submit_review(uuid,int,int,text)` maps farmer `r1` to `overall_score`, `r2` to the
  pilot `weight_accuracy` dimension, derives the farmer organization from the caller,
  and delegates to the canonical transaction;
- `rpc_self_submit_mpk_review(uuid,int,int,text)` maps `r1` to `overall_score`, `r2` to
  the pilot `livestock_condition` dimension, derives the MPK organization from the
  delivered allocation/pool and delegates to the same canonical transaction;
- `fn_tsp_batch_json(...).review` and `rpc_get_pool_matches(...).myRating` synthesize
  their legacy response shapes from canonical rows, with a read-only fallback to notes
  only when the canonical row is absent.

Adapters preserve signatures and response shapes, not legacy storage. They must not
dual-write notes after cutover.

Legacy notes backfill is idempotent:

- `notes.review`: reviewer is `batches.organization_id`; `r1` is overall and `r2` is
  `weight_accuracy`;
- `notes.mpk_review`: reviewer is backfilled only when exactly one delivered
  counterparty organization can be derived; `r1` is overall and `r2` is
  `livestock_condition`;
- existing canonical `(batch_id, reviewer_org_id)` rows win and are never overwritten;
- malformed ratings, ambiguous MPK counterparties, missing delivered state, or unknown
  dimensions go to a reconciliation report and are not guessed;
- visibility is not widened by backfill. A backfilled pair is revealed only when the
  canonical mutual/timeout rule says so.

### 5.5 Appeals

Appeals are a workflow projection over messaging:

- topic, immutable deal/batch reference, case status, and audit timestamps live in
  `org_appeal_cases`;
- every message body, author, attachment, and creation time lives once in
  `comm_messages`;
- `org_appeal_case_messages` associates the content with the case;
- existing support-channel RPCs keep their signatures and general-support behavior;
- the MPK Profile uses case-specific RPCs, so one permanent support channel can expose
  multiple independent case threads;
- direct cancellation of a confirmed deal is not introduced; the appeal records the
  request and immutable reference.

### 5.6 `mpk_profiles`

Implementation begins with a catalog preflight in every environment:

1. record whether `public.mpk_profiles` exists and snapshot its columns, constraints,
   RLS, policies, grants, row count, and dependent objects;
2. if absent, create the narrow canonical table;
3. if present with the canonical shape, apply only missing constraints/policies/grants;
4. if present with the handwritten legacy shape, preserve a backup/export, add or
   create the narrow canonical surface, and route each legacy field to its real owner;
5. never let `CREATE TABLE IF NOT EXISTS` silently accept an incompatible live shape.

Because the audited production table is absent, production has no profile rows to
backfill. In another environment:

- organization linkage is retained only for valid MPK assignments;
- capacity fields move to the primary `mpk_sites` record when ARS-359 provides it;
- preferred category/region fields remain quarantined until an approved procurement
  preference owner exists;
- generic notes require explicit operator review before becoming public description;
- no membership, verification, role, review, or appeal fact is copied.

The deprecated direct hook is replaced by typed RPCs. There is no compatibility
Data API table grant for old frontend code.

## 6. Migration and compatibility plan

The logical order below is mandatory. Implementation issues create their own migration
files through the Supabase CLI; this ADR does not invent future migration filenames.

| Order | Change | Compatibility state | Gate to proceed |
|---:|---|---|---|
| 0 | Re-run schema/ACL preflight and capture counts/checksums for legacy notes and any `mpk_profiles` | read-only | baseline attached to implementation evidence |
| 1 | Apply and verify the ARS-352 review ACL/RLS fix | no product behavior change intended | anon denied; cross-tenant review write denied; score visibility inherits parent |
| 2 | Add/verify explicit grants, RLS policy foundations, FK/RLS indexes, and fixed helper ACL | existing consumers retained | security checklist §8 and advisors clean |
| 3 | Expand `user_organization_roles` CHECK, seed permission catalog, deploy permission helper | legacy roles continue | role×permission and tenant matrix green |
| 4 | Add narrow `mpk_profiles`; add appeal case/link entities | additive, no readers switched | canonical shape and empty-state tests green |
| 5 | Backfill legacy review notes and any non-production legacy MPK profile data; produce reconciliation report | old writers paused during bounded backfill | counts/checksums reconcile; ambiguous rows enumerated |
| 6 | Rebind legacy review write/read adapters to canonical tables; deploy case-specific appeal RPCs | signatures preserved; canonical-only writes | old and new contract suites green |
| 7 | Deploy typed profile/read-model RPCs and generated TypeScript/Zod contracts | feature flag off; direct profile hook deprecated | no `as any`; anonymity payload tests green |
| 8 | Enable MPK Profile progressively in staging, then production only after G3 | old surfaces remain available | functional, RLS, latency, router, visual/accessibility gates green |
| 9 | Observe adapters, remove fallbacks, then retire legacy signatures per §9 | one removal at a time | zero-caller windows and rollback evidence recorded |

### 6.1 Write/read behavior by phase

| Phase | New writes | Reads |
|---|---|---|
| Before order 5 | legacy behavior | legacy behavior |
| Backfill window | pause affected legacy review writers or serialize with a lock; do not accept unsynchronized writes | legacy readers remain |
| Orders 6–8 | canonical tables only | canonical first; notes fallback only for unreconciled legacy rows |
| After fallback retirement | canonical tables only | canonical only |

There is never an open-ended dual-write period. If a compatibility adapter cannot
atomically reach canonical storage, it fails; it does not write only to notes.

### 6.2 Rollback

Production rollback is consumer-first and non-destructive:

1. disable the MPK Profile feature flag;
2. restore the previous readers while compatibility adapters still exist;
3. stop new profile/case writers;
4. roll back adapter routing only if doing so cannot lose canonical writes;
5. preserve new tables, backfill provenance, and audit history for diagnosis.

Do not drop tables, delete backfilled reviews, copy derived state into a legacy profile,
or shrink role constraints as an incident response. Destructive cleanup is a separately
approved migration after the retirement gates.

## 7. Compatibility contracts

| Contract | During migration | Canonical implementation |
|---|---|---|
| `fn_org_membership_active(uuid)` | signature and boolean semantics preserved | subscription states first plus documented legacy level fallback |
| `rpc_submit_review(uuid,int,int,text)` | signature/boolean result preserved | canonical review transaction; no notes write |
| `rpc_self_submit_mpk_review(uuid,int,int,text)` | signature/boolean result preserved | canonical review transaction; caller MPK derived |
| `fn_tsp_batch_json(...).review` | legacy JSON shape preserved | projection from canonical review, temporary notes fallback |
| `rpc_get_pool_matches(...).myRating` | field preserved | projection from canonical MPK review, temporary notes fallback |
| existing messaging RPCs | unchanged for general support | continue to own channels/messages |
| new appeal RPCs | additive | compose case metadata with messaging |
| `useMpkProfile` / `useUpdateMpkProfile` | no new consumers allowed | replaced by typed query/mutation hooks over RPC |

Compatibility does not include:

- accepting client-provided org identity as authorization;
- public/anonymous execute grants for write RPCs;
- direct profile-table writes;
- fabricated membership dates or verification progress;
- exposing a counterparty review before the canonical reveal rule.

## 8. RLS, grants, `search_path`, and performance checklist

Every implementation PR must attach evidence for all applicable items.

### Tables and views

- [ ] RLS is enabled on every table in an exposed schema before client grants.
- [ ] `anon` receives no access to private MPK, membership, verification, role, review,
      appeal, or message tables.
- [ ] `authenticated` receives only the verbs required by the chosen API boundary;
      RPC-only tables have no direct client write grants.
- [ ] `service_role` grants are explicit; ownership/service bypass is not treated as an
      RLS test.
- [ ] SELECT policies are present where UPDATE is expected.
- [ ] UPDATE policies have both `USING` and `WITH CHECK`.
- [ ] Policies specify `TO authenticated`; role membership alone is never the tenant
      predicate.
- [ ] Tenant predicates use caller-derived org IDs and are behavior-tested for A→B
      denial.
- [ ] Review dimension visibility is inherited from the parent review.
- [ ] Any view exposed to clients uses `security_invoker=true` on supported Postgres,
      or stays unexposed with explicit revokes.

### Functions

- [ ] Prefer `SECURITY INVOKER`; each `SECURITY DEFINER` use has a written reason.
- [ ] Every definer function fixes `search_path` and schema-qualifies referenced
      objects. Existing repo convention may use `public, pg_temp`; new security-critical
      helpers should prefer an empty path plus qualified names where feasible.
- [ ] `EXECUTE` is revoked from `PUBLIC` and `anon` immediately after creation.
- [ ] Grants name exact function signatures and minimum caller roles.
- [ ] Definer write RPCs check authentication, org membership, permission, entity
      relationship, allowed FSM transition, and immutable references inside the body.
- [ ] Internal predicates that accept arbitrary organization IDs are not client-callable.
- [ ] Functions are registered in `rpc_name_registry` where repository convention
      requires it.

### Indexes and constraints

- [ ] Every FK has a supporting index unless a reviewed query-plan exception is recorded.
- [ ] Tenant/RLS columns are indexed.
- [ ] Appeal case lists have an org + status + updated/opened ordering index; case-message
      links have case/order and unique message indexes.
- [ ] Verification latest/expiry reads have an org/membership + type + date index.
- [ ] Active/pending/open subsets use partial indexes where they materially reduce scans.
- [ ] Review adapters use existing batch/reviewer unique constraints and do not create
      duplicate canonical rows.
- [ ] Constraints are added idempotently using catalog checks where PostgreSQL has no
      `ADD CONSTRAINT IF NOT EXISTS`.

### Verification

- [ ] Run DB contract tests as `anon`, tenant A, tenant B, operator, and service roles.
- [ ] Run `supabase db advisors` or the connected advisor equivalent after schema work.
- [ ] Use `EXPLAIN (ANALYZE, BUFFERS)` on seeded non-production data for profile summary,
      review list, appeal list/thread, and current verification reads.
- [ ] Confirm explicit grants separately from RLS behavior.
- [ ] Confirm pre-disclosure RPC payloads and DOM omit legal name, BIN, address, phone,
      logo, and hidden review content.

Current Supabase references:

- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/guides/api/securing-your-api
- https://supabase.com/docs/guides/database/functions

## 9. Legacy adapters and retirement

Target dates are planning limits, not permission to remove. Every condition in the
corresponding row is mandatory; if a condition is unmet, the adapter stays.

| Legacy surface | Owner | Target no earlier than | Removal conditions |
|---|---|---:|---|
| `fn_org_membership_active` legacy `memberships.level` fallback | ARS-361 / billing | 2026-10-31 | all access-active orgs represented by valid subscription rows or explicitly exempted; fallback-only metric is zero for 30 consecutive days; TSP/admin gates pass without fallback; rollback query documented |
| `rpc_submit_review(uuid,int,int,text)` | ARS-360 / TSP | 2026-10-31 | all supported farmer clients call typed canonical RPC for two production releases; 30-day zero-call telemetry; code search and RPC registry show no consumer; notes backfill/reconciliation complete |
| `rpc_self_submit_mpk_review(uuid,int,int,text)` | ARS-360 / TSP | 2026-10-31 | all supported MPK clients call typed canonical RPC for two production releases; 30-day zero-call telemetry; no code/registry consumer; backfill complete |
| notes fallback in `fn_tsp_batch_json(...).review` | ARS-360 / TSP | 2026-10-31 | zero valid note-only farmer reviews after reconciliation; canonical projection contract/E2E green; fallback-hit metric zero for 30 days |
| notes fallback in `rpc_get_pool_matches(...).myRating` | ARS-360 / TSP | 2026-10-31 | zero valid note-only MPK reviews; ambiguous rows explicitly resolved or waived; fallback-hit metric zero for 30 days |
| `batches.notes.review` / `batches.notes.mpk_review` keys | ARS-360 / data cleanup | 2026-11-30 | writers and readers removed first; immutable backup/checksum retained; legal/audit retention reviewed; separate destructive migration approved |
| direct `useMpkProfile` / `useUpdateMpkProfile` and handwritten `MpkProfile` shape | MP-2.8 / frontend | 2026-09-30 | typed RPC hooks shipped; `rg` finds zero imports/uses; generated contracts committed; old hook was never reintroduced as a consumer |
| any incompatible non-production legacy `mpk_profiles` columns | ARS-359 / data cleanup | 2026-11-30 | field-by-field reconciliation report accepted; valid capacity data moved to `mpk_sites`; ambiguous/public text reviewed; dependents and grants are zero; backup exists |

The permanent support-channel RPCs are **not** legacy adapters and are not scheduled
for deletion. Appeal RPCs compose with them.

## 10. Rejected alternatives

1. **A wide `mpk_profiles` snapshot of all six tabs.** Rejected because it duplicates
   organization, billing, verification, RBAC, review, and messaging facts.
2. **A second `org_member_roles` table.** Rejected because user↔org assignment would
   split across two authorities.
3. **`memberships.expires_at` or profile-owned membership state.** Rejected because
   billing already owns real periods and the access predicate.
4. **Verification status on `organization_type_assignments`.** Rejected because type
   classification and evidence history have different lifecycles and owners.
5. **New `batch_reviews` or continued notes-only reviews.** Rejected because canonical
   double-blind review entities already exist.
6. **Appeal `answer` text on the case.** Rejected because messages, replies, authors,
   attachments, and ordering already belong to messaging.
7. **Long-lived dual writes.** Rejected because retry/partial failure creates immediate
   divergence. Compatibility is canonical-only write plus temporary read fallback.
8. **Destructive down migrations for rollback.** Rejected because additive history is
   safer to preserve while consumer routing is reverted.

## 11. Consequences

Positive:

- each fact has one writable authority;
- legacy clients can survive the migration without preserving legacy stores;
- MPK preview and farmer view cannot drift on membership/reputation/disclosure;
- security and tenant isolation are enforced below UI role labels;
- empty production data remains truthful and testable.

Costs:

- read RPCs join several domains and require explicit indexes and latency budgets;
- review backfill needs a reconciliation report for ambiguous split-batch MPK reviews;
- legacy membership fallback cannot be removed until billing coverage is measured;
- appeals add case/link metadata and case-specific RPCs while retaining messaging;
- schema changes must be sequenced across ARS-356/357/359/360/361/358.

## 12. Acceptance and downstream gates

This ADR satisfies ARS-353 when:

- [x] entity map is explicit;
- [x] ownership map is explicit;
- [x] migration order and compatibility behavior are explicit;
- [x] legacy adapters have owners, earliest dates, and hard removal conditions;
- [x] RLS/grants/`search_path`/index verification checklist is explicit;
- [x] `mpk_profiles` has a live-preflight, canonical contract, backfill, and deprecation
      path;
- [x] no table or RPC is created by this design-only task.

Downstream implementation remains gated as follows:

- ARS-356 owns role CHECK/permission/invitation implementation;
- ARS-361 owns membership and verification projection;
- ARS-360 owns review backfill and adapter convergence;
- ARS-357/364 own appeal entities and RPC composition;
- ARS-359 owns canonical `mpk_profiles`, site/capacity, and related organization data;
- ARS-358 owns the final grants/RLS/index/contract-test matrix;
- G3 owns production deployment authorization.
