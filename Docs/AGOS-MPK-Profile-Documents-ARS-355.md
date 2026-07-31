# ARS-355 · MPK organization documents implementation record

> **Status:** deployed to production and smoke-tested on 2026-07-31
> **Migration:** `supabase/migrations/20260731074054_ars_355_org_documents_registry.sql`
> **Parent contracts:** `AGOS-MPK-Profile-EngSpec-v0_1.md`,
> `AGOS-MPK-Profile-Convergence-ADR-ARS-353.md`

## 1. Scope and compatibility decision

ARS-355 establishes the single persistence and private-Storage authority for MPK
organization documents. It does not migrate, delete, or relax the existing
`membership-documents` flow. That bucket is already consumed by legacy cabinet and
admin callers with a different raw-Storage path and access contract.

The implementation therefore creates a separate private `org-documents` bucket. This
is compatible with EngSpec §9: `membership-documents` *may* be reused only when its
registry, MIME/size, ownership, and short-link requirements are all enforced; it does
not require reuse. Isolating the new flow prevents a security tightening from breaking
legacy callers and keeps the new exact registry-bound policies auditable.

ARS-355 owns the database mutation/download primitive. ARS-363 consumes these exact
primitives for UI upload orchestration and typed admission/read projections; it must not
create another document registry, bucket, lifecycle state machine, or raw
`storage.objects` read path. An eventual legacy cutover is a separate, explicit change.

## 2. Registry authority and lifecycle

`public.org_documents` is the only lifecycle authority. A Storage object alone is not a
document. The row contains the owning organization, kind/title, original file name,
server-derived `storage_path`, issue/expiry dates, upload/review actors and timestamps,
validated MIME/size metadata, and cleanup lease state.

```text
uploading ──finalize──> finalized / pending-review ──future MP-11.1──> accepted | rejected
    └──abandon/expiry──> abandoned ──Storage API cleanup──> cleaned
```

`upload_state` is internal (`uploading`, `finalized`, `abandoned`); `review_state` is
the reserved review FSM (`pending`, `accepted`, `rejected`). Review approve/reject is
intentionally not exposed by ARS-355: the trigger makes the transition monotonic and
MP-11.1 will add the TURAN-admin write endpoint. A terminal lifecycle value cannot be
reopened, and finalized MIME/size/audit metadata cannot be overwritten.

The UI must derive status, `days_left`, expiry condition, meter percentage, and tone from
`review_state`, `upload_state`, and `expires_on`; none is stored. Accepted expiry is
`expires_on < current_date`; an absent `expires_on` is indefinite.

`organization_id` uses `ON DELETE RESTRICT`. An organization cannot be removed while it
still has registry rows because that would make private object keys unrecoverable. A
future destructive organization deletion workflow must first process its document
cleanup explicitly.

## 3. Upload, finalization, and cleanup

1. An authenticated user with `mpk.documents.manage` calls
   `rpc_create_org_document_upload_intent`. The server creates an active 15-minute
   intent and derives `{organization_id}/{document_id}/upload`.
2. The caller uploads/upserts only that exact object while the intent remains open.
3. `rpc_finalize_org_document_upload` row-locks the registry and Storage object,
   verifies object existence, MIME (`application/pdf`, `image/jpeg`, `image/png`) and
   size (1–10 MiB), then atomically records immutable validated metadata.
4. `rpc_abandon_org_document_upload` is idempotent. The service-only cleanup worker
   claims abandoned paths using a 15-minute lease token, removes objects through the
   Storage API, and acknowledges only its own lease.

The intent response contains `storage_path` solely as an ephemeral, exact upload
capability required by the Linear `intent/path → upload → finalize` contract. It is not
returned by finalize, by a document read projection, or by the download endpoint, and
must not be logged or persisted in client state. If the EngSpec’s “paths never leave the
server” statement is later interpreted literally rather than as a read-model rule, the
consumer must replace this narrow capability with an Edge-issued signed-upload URL; that
would be a deliberate contract change, not a silent rewrite.

## 4. Bucket, RLS, and signed download

`storage.buckets.org-documents` is private with a 10 MiB limit and a PDF/JPEG/PNG
allowlist. Its `storage.objects` policies are authenticated-only and bind the complete
object key to an active, unexpired `org_documents` intent plus
`mpk.documents.manage`/admin authorization. A path that merely shares the first
organization folder cannot pass.

`INSERT`, `SELECT`, and `UPDATE` are allowed only while an intent is open. `SELECT` is
present because Supabase Storage uses `RETURNING`, and with `UPDATE` it enables the
required client `upsert` protocol. There is no client DELETE policy. Once finalized,
raw Storage list/read/update are denied, preventing a durable direct download path.

`supabase/functions/org-document-download` validates the caller JWT, has a
service-role-only database helper authorize `(user, organization, document)`, and
returns a signed URL with a fixed 60-second TTL. It never returns the raw Storage key.
`supabase/functions/cleanup-org-document-uploads` accepts only the service-role bearer
credential and uses the Storage API rather than modifying `storage.objects` with SQL.

## 5. Security and performance controls

- `org_documents` has RLS enabled and no `anon`/`authenticated` table grants; user
  mutations use three guarded `SECURITY DEFINER` RPCs with a fixed `search_path`.
- Public RPC execution is revoked from `PUBLIC` and `anon`; service helpers/path
  resolver are revoked from `authenticated` too. The one RLS predicate helper is
  executable by `authenticated` solely so Storage policies can evaluate it; it requires
  a JWT and returns only an allow/deny boolean.
- Composite/partial indexes cover active organization lists, accepted expiry scans,
  expired uploads, abandoned cleanup leases, and nullable actor foreign keys.
- Finalization locks the object row so an in-flight upsert either completes before
  validation or is rechecked after the finalized registry state closes the policy.

## 6. Verification and release gate

For a new environment, run after the ARS-356 RBAC base:

1. Apply `20260731074054_ars_355_org_documents_registry.sql`.
2. Run `tests/ars_355_org_documents_storage_test.sql`.
3. Run `bash cross_check.sh` and the Supabase security/performance advisors.
4. Run a real Storage API smoke test (not direct SQL): authorized `upload(...,
   { upsert: true })`, cross-tenant upload/list/download denial, malformed MIME/size
   rejection, finalize retry, and a signed URL that expires after 60 seconds.

Production verification completed on 2026-07-31: the transactional SQL contract passed
with rollback; both Edge Functions are `ACTIVE` with JWT verification; unauthorized
requests were rejected; and a real authenticated flow completed with HTTP 200 at each
step: Storage upload under the standard RLS policy, finalize RPC, signed-URL issuance
with `expires_in=60`, and signed-file retrieval. All temporary smoke fixtures and
temporary Storage policies were removed and checked absent afterwards.
5. Deploy and schedule the cleanup Edge Function only after the service-role scheduler
   credential and operational ownership are configured.

The SQL contract rolls its data back and covers bucket configuration, exact-path RLS,
anonymous/table ACL denial, A/B isolation, role denial, insert/select/update upsert,
metadata validation, finalize/abandon idempotency, terminal FSM, cleanup leases, derived
expiry fields, and restricted organization deletion.

## 7. Rollback plan

Rollback is consumer-first and non-destructive:

1. Disable new documents UI/read consumers and stop issuing new intents.
2. Revoke the three public mutation RPCs and signed-download Edge endpoint.
3. Keep the registry and bucket intact for audit and cleanup; let the service worker
   remove abandoned objects through the API.
4. Do not delete `org_documents`, loosen its parent-delete restriction, or repoint the
   legacy `membership-documents` callers as part of incident rollback.

Dropping the registry/bucket is a later destructive migration only after zero callers,
an object inventory, confirmed cleanup, backup, and separate production authorization.
