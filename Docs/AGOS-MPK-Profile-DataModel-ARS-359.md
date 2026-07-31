# ARS-359 · MPK Profile data model implementation record

> **Status:** implemented locally; production deployment is not authorized
> **Migration:** `supabase/migrations/20260730134113_ars_359_mpk_profile_data_model.sql`
> **Parent contracts:** `AGOS-MPK-Profile-EngSpec-v0_1.md`,
> `AGOS-MPK-Profile-Convergence-ADR-ARS-353.md`

## 1. Live preflight and backfill decision

The linked project `mwtbozflyldcadypherr` was inspected read-only on 2026-07-30 before
the migration was authored. `public.mpk_profiles`, `public.mpk_sites`,
`public.org_bank_accounts`, and `public.org_field_reviews` were all absent. The
canonical `organizations` columns were present:

`id`, `legal_name`, `bin_iin`, `region_id`, `district_id`, `address_text`, `phone`,
`email`, `website`, `created_at`, and `updated_at`.

Consequences:

- no production `mpk_profiles` rows exist to backfill;
- no capacity, bank, or field-review data is guessed from another source;
- the migration adds only `organizations.head_full_name` and `head_title`; it does not
  rename or remove any existing column;
- `address_text` remains the canonical legal/mailing address in profile v0.1;
  site-specific addresses live in `mpk_sites`;
- `phone` and `email` remain organization contacts. A contact person's identity is
  derived from `users` + `user_organization_roles`, not duplicated on `organizations`.

The migration starts with a catalog preflight. An environment containing a legacy or
partially incompatible target table fails with `ARS_359_PREFLIGHT_REQUIRED` or
`ARS_359_LEGACY_MPK_PROFILES_REQUIRES_AUDIT`. This is deliberate: preserve/export and
reconcile that environment before adding the canonical model.

## 2. Canonical entity contract

| Entity | Authority and invariant |
|---|---|
| `organizations` | Legal identity stays in `legal_name`, `bin_iin`, `region_id`, `address_text`, `phone`, and `email`; head name/title are additive. |
| `mpk_profiles` | Sparse 0/1 editorial extension keyed by `organization_id`; only public description and a Storage-relative logo path. |
| `mpk_sites` | Many sites per MPK; positive `processing_capacity_heads_per_day`; at most one active primary site. The v0.1 writer edits/promotes the primary site only. |
| `org_bank_accounts` | Bank business fields are immutable versions. An edit closes the prior row and appends one successor; one current primary account is enforced. |
| `org_field_reviews` | Append-only review history for `legal_name`, `address_text`, and `bin_iin`; one pending proposal per organization+field. |

The deprecated wide TypeScript fields (`annual_demand_heads`,
`processing_capacity_per_day`, `preferred_categories`, `preferred_regions`, and
generic `notes`) are not columns of `mpk_profiles`.

## 3. Write and snapshot behavior

- `rpc_upsert_mpk_profile` creates the sparse editorial row on first authorized edit.
- `rpc_update_mpk_org_details` writes canonical region/head/organization-contact data.
- `rpc_save_mpk_primary_site` serializes writers on the organization row, keeps one
  active primary, and rejects non-positive capacity.
- `rpc_append_org_bank_account` requires `mpk.bank.manage`; it never overwrites bank
  business fields. `fn_org_bank_account_snapshot(account_id)` resolves an explicit
  version to JSON for a deal-document writer.
- `rpc_propose_org_field_change` applies `legal_name`/`address_text` immediately and
  records a pending review. A BIN proposal is stored but does not alter
  `organizations.bin_iin`.
- `rpc_review_org_field_change` is TURAN-admin-only and locks the proposal. BIN approval
  checks the proposal baseline, updates the production BIN, and closes the review in
  one transaction. Rejecting name/address never silently reverts production.

Deal-document invariant: the document transaction must choose one bank-account version,
call `fn_org_bank_account_snapshot(id)`, and persist that JSON in the immutable document
snapshot. A historical document must never re-render from the current primary account.
ARS-359 preserves every bank version so this remains possible; the document entity and
its write transaction are owned by the documents/deal-document implementation.

## 4. Security and indexes

All four public tables have RLS enabled. The migration explicitly revokes table access
from `PUBLIC`, `anon`, and `authenticated`; authenticated clients mutate through guarded
RPCs only. The service role receives explicit table privileges. Every `SECURITY DEFINER`
writer has a fixed `search_path`, checks the current user plus organization permission,
and revokes `PUBLIC`/`anon` execution.

An `organizations` trigger also rejects direct authenticated updates to `legal_name`,
`address_text`, or `bin_iin`. This closes the pre-existing `orgs_update_own` Data API
path that would otherwise bypass the review/BIN-approval invariant; trusted admin and
service/RPC paths continue to work.

FK and RLS lookup columns are indexed. Partial unique indexes enforce:

- one active primary site per organization;
- one current primary bank account per organization;
- one current version per organization+IBAN;
- one pending field review per organization+field.

The explicit grant statements are required by Supabase's 2026 opt-in Data API exposure
default; grants and RLS remain separate controls.

## 5. Verification and cross-check

Run, in order, against a disposable/local database containing the ARS-356 permission
base:

1. Apply `20260730134113_ars_359_mpk_profile_data_model.sql` twice; the second run must
   be a no-op without errors.
2. Run `tests/ars_359_mpk_profile_data_model_test.sql`.
3. Run `./cross_check.sh` and Supabase security/performance advisors.
4. Verify the migration list and compare the target columns, constraints, policies,
   grants, and indexes with this document.

The SQL contract test rolls back all fixtures. It covers profile sparsity, positive
capacity, primary-site and primary-bank uniqueness, append-new bank versions, stable
historical snapshots, the bank overwrite guard, immediate name/address semantics,
BIN apply-on-approve, pending uniqueness, cross-tenant/role denial, RLS/ACLs, and FK
index coverage.

## 6. Rollback plan

Rollback is consumer-first and non-destructive:

1. Disable the MPK Profile feature flag/readers.
2. Revoke execution on the six ARS-359 mutating RPCs.
3. Stop profile/site/bank/field-review writers and return the previous UI/read path.
4. Preserve all four tables, bank versions, pending proposals, and review decisions for
   audit and diagnosis.
5. If an approved BIN must be corrected, create a new audited proposal/approval using
   the prior value stored in the review row. Restore name/address only through a new
   audited edit.

Do not drop tables, delete history, rewrite old bank versions, auto-revert rejected
name/address edits, or remove `organizations` columns during incident rollback. Object
removal is a later destructive migration requiring observed zero callers, backup, and
separate G3 authorization.
