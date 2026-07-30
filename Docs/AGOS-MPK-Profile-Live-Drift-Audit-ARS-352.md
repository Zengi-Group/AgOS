# ARS-352 · MPK Profile — live schema and drift audit

**Статус:** аудит завершён и передан в downstream-задачи; security DDL подготовлен локально, к live DB не применялся.
**Дата:** 2026-07-30 (Asia/Almaty).
**Repo baseline:** `origin/main@f367bcf` (локальный checkout `6086d24` отстаёт на 12 коммитов; evidence получен через read-only `git show/git grep origin/main`).
**Live baseline:** Supabase project `mwtbozflyldcadypherr`, PostgreSQL 17.6.
**Режим live-проверки:** `default_transaction_read_only=on`; единственные пробные вызовы выполнены в read-only транзакциях с rollback.

## 1. Executive result

Модель МПК Profile нельзя строить как новый изолированный вертикальный стек. В live DB уже существуют канонические сущности для организации, RBAC, членства, верификации, отзывов, сообщений и Storage. Их нужно переиспользовать и расширять аддитивно.

Главные результаты:

1. `organizations` в repo и live использует `legal_name`, `bin_iin`, `region_id`, `address_text`, `phone`, `email`, `website`, плюс live/repo extension `district_id`. Поля handoff `name/bin/region` не являются DB-контрактом.
2. `mpk_profiles` отсутствует и в канонических SQL-файлах, и в live schema. Frontend-хук скрывает этот факт через `as any`.
3. `user_organization_roles` уже содержит ровно четыре роли: `owner/manager/employee/viewer`. Параллельная `org_member_roles` запрещена.
4. Источник срока и состояния членства — `membership_subscription` + `fn_org_membership_active`. На live сейчас 0 подписок; `pg_cron` не установлен намеренно, потому что charge-provider остаётся stub.
5. `organization_type_assignments` — только классификация типа организации. История проверки живёт в append-only `verification_records`. На live 36 type assignments и 0 verification records.
6. Канонические `deal_reviews` и `deal_review_dimension_scores` существуют, но notes-based adapters также живы. Конвергенция обязательна до нового reputation UI.
7. `comm_channels/comm_messages` пригодны как message store, но текущий инвариант — один постоянный support-канал на организацию. Для нескольких обращений нужны case/topic/ref/status сущности поверх канала, а не новая таблица сообщений.
8. Bucket `membership-documents` существует, private и org-isolated. Его можно переиспользовать, но registry, MIME/size contract и document lifecycle остаются отдельной моделью.
9. Найден security conflict: `deal_review_dimension_scores` имеет RLS off и полные Data API grants; `rpc_submit_deal_review` anon-executable и не связывает переданный `p_organization_id` с caller. Это не новый MPK DDL, а существующий defect, который должен быть закрыт до конвергенции отзывов.
10. Четыре артефакта, объявленные каноном в ARS-351, отсутствуют в repo и Linear attachments/documents: `AGOS-MPK-Profile-EngSpec-v0_1.md`, `AGOS-Dok6-Slice10-MPK-Profile.md`, `DESIGN-TOKENS.md`, `prototype/mpk-cabinet-v4.dc.html`. Поэтому требование «EngSpec amended» физически заблокировано.

## 2. Gap table

| ID | Область | Repo evidence | Live evidence | Вердикт | Решение / owner |
|---|---|---|---|---|---|
| MPK-CANON-01 | EngSpec/Slice10/tokens/prototype | Файлы отсутствуют в `origin/main`, доступных ветках/worktree | В Linear ARS-351/352 нет documents/attachments/comments | **отсутствует** | Вернуть артефакты в repo или исправить canonical paths. Отдельный блокирующий documentation defect; до этого G2 не может подтвердить fidelity/копирайт. |
| MPK-ORG-01 | Организация | `origin/main:d01_kernel.sql:201-241` | `legal_name`, `bin_iin`, `legal_form`, `region_id`, `address_text`, `phone`, `email`, `website`, `district_id` | **переиспользуем** | Handoff mapping: `name→legal_name`, `bin→bin_iin`, `region→region_id` + join `regions`; address=`address_text`, contacts=`phone/email/website`. `contact_name` не хранить в `organizations`: это user/member projection. ARS-359/362. |
| MPK-PROFILE-01 | `mpk_profiles` | Нет DDL; `src/hooks/cabinet/useMpkProfile.ts:17,38` вызывает `.from('mpk_profiles' as any)`; shape задан вручную в `src/types/membership.ts:55-64` | Таблица отсутствует в `information_schema.columns` | **отсутствует / frontend deprecated** | Не считать hook или TS interface источником истины. После G2: разложить поля по каноническим entities/read-model либо добавить обоснованный DDL в ARS-359; затем удалить `as any` через generated contract в MP-2.8. |
| MPK-RBAC-01 | Сотрудники/роли | `origin/main:d01_kernel.sql:268-287` | CHECK `owner/manager/employee/viewer`; UNIQUE `(user_id, organization_id)` | **переиспользуем** | Расширять permission catalog/RPC поверх `user_organization_roles`; invitations — отдельная temporal entity, не второй role store. ARS-356. |
| MPK-MEM-01 | Членство/срок | `origin/main:d13_billing.sql:64-143,281-310,631+`; D-BILL-TRUTH-01 | Поля `state/current_period_start/current_period_end/next_billing_at`; `fn_org_membership_active` совпадает с каноном; renewal engine live и service-role-only; 0 rows; `pg_cron` отсутствует | **переиспользуем** | Единственный source: subscription FSM, predicate = `trialing/active/grace OR legacy level<>registered`. UI обязан честно показывать empty/no subscription, не synthetic dates. Renewal cron не армировать до payment-provider/G3. ARS-361, ARS-270. |
| MPK-VER-01 | Тип организации / верификация | `origin/main:d01_kernel.sql:249-260,380-405` | assignments: 36 rows, только `org_type/assigned_at/assigned_by`; verification: 0 rows, append-only shape с `result/verified_at/expires_at` | **переиспользуем** | Type assignment отвечает «что это за org»; timeline допуска строить из `verification_records`. Не добавлять status в assignment. ARS-361. |
| MPK-REV-01 | Репутация/отзывы | `origin/main:d02_tsp.sql:1734-1796,3751-3863`; adapters: `20260622120000...:673`, `20260706120000...:140-191` | Канонические таблицы/RPC есть; notes adapters есть; score table RLS off; canonical RPC anon-executable | **есть + deprecated adapter + defect** | `deal_reviews` становится единственным store; legacy signatures остаются adapters до backfill/retire. Security defect закрыть до ARS-360; RLS gap уже учтён ARS-274, финальная матрица — ARS-358. |
| MPK-APPEAL-01 | Обращения | `origin/main:d12_messaging.sql:31-58,96-119,233-290`; Messaging EngSpec — один support channel/org | Один `support` channel/org обеспечен partial unique index; `comm_messages` append-only; case/topic/ref/status отсутствуют | **переиспользуем частично** | Content остаётся в `comm_messages`; добавить appeal-case entity поверх channel с отдельными topic/status/deal ref и несколькими case threads. Не добавлять `answer` в case. ARS-357/364. |
| MPK-STOR-01 | Membership documents | `origin/main:d10_public_site.sql:921-989` | Bucket private; SELECT/INSERT/UPDATE org-scoped через `fn_storage_org_id(name)=ANY(fn_my_org_ids())`; DELETE admin-only | **переиспользуем** | Сохранить path `{orgId}/...`; добавить registry/workflow, MIME/file-size contract, upload tests. Не создавать второй bucket без причины. ARS-355. |
| MPK-ACL-01 | Data API/RLS | Canon не содержит явных minimal table grants для legacy target tables; score RLS omission виден после `d02:1796` | Все target tables имеют broad grants для `anon/authenticated/service_role`; RLS on кроме `deal_review_dimension_scores`; `rpc_submit_deal_review`/`rpc_send_message` anon-executable | **конфликт / defect** | Explicit revoke/minimal grants и advisor pass. `rpc_submit_deal_review` — urgent defect; `rpc_send_message` имеет auth guard, но ACL всё равно закрыть. ARS-274/358. |
| MPK-LIVEFUNC-01 | Live-only functions | Отсутствуют в d-files + migrations baseline | `fn_health_restrictions_is_active`, `get_auth_user_id_by_email`, `get_auth_user_id_by_phone` | **live-only / неканонично** | Не переиспользовать в MPK invitations/read-model до canonicalization. Вынести в deploy-drift defect: добавить в канон с ACL/tests либо удалить из live. |

## 3. Canonical sources of truth

Порядок источников для MPK Profile:

1. `d01_kernel.sql` — organization identity, organization types, user↔org roles, legacy membership and verification history.
2. `d13_billing.sql` + `DECISIONS_LOG.md` D-BILL-TRUTH-01 — subscription lifecycle, actual period dates, canonical membership predicate.
3. `d02_tsp.sql` — canonical deal review model and double-blind contract.
4. `d12_messaging.sql` + `Docs/AGOS-Messaging-EngSpec-v0_1.md` — channel/message store and messaging RPC.
5. `d10_public_site.sql` — Storage bucket path ownership and policies.
6. `supabase/migrations/*.sql` — deployed compatibility adapters and later additive changes; later migration wins over earlier d-file definition only when explicitly documented.
7. Live `pg_catalog/information_schema` — evidence of what is deployed, not an authoring source. Live-only objects must be canonicalized or removed.
8. Generated DB types/RPC contracts — consumer contract after schema convergence. Handwritten TS interfaces and `as any` are not canonical.

Explicitly non-canonical/deprecated for the new profile:

- `src/types/membership.ts` legacy `Organization` fields `name/bin/region/contact_*`;
- `src/hooks/cabinet/useMpkProfile.ts` direct `mpk_profiles as any` access;
- `batches.notes.review` and `batches.notes.mpk_review` as final review storage;
- one support channel interpreted as one appeal case;
- `memberships.level` or invented `memberships.expires_at` as subscription expiry source.

## 4. Live evidence queries

The following catalog queries were executed read-only.

### 4.1 Columns and constraints

```sql
select table_name, ordinal_position, column_name, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = any(array[
    'organizations','mpk_profiles','user_organization_roles','memberships',
    'membership_subscription','verification_records','organization_type_assignments',
    'deal_reviews','deal_review_dimension_scores','comm_channels','comm_messages'
  ])
order by table_name, ordinal_position;

select c.relname as table_name, con.conname, con.contype,
       pg_get_constraintdef(con.oid, true) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = any($target_tables)
order by c.relname, con.conname;
```

### 4.2 RLS, policies and Data API grants

```sql
select n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where (n.nspname = 'public' and c.relname = any($target_tables))
   or (n.nspname = 'storage' and c.relname in ('buckets','objects'));

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where (schemaname = 'public' and tablename = any($target_tables))
   or (schemaname = 'storage' and tablename in ('buckets','objects'));

select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = any($target_tables)
  and grantee in ('anon','authenticated','service_role')
order by table_name, grantee, privilege_type;
```

### 4.3 Function ACL and definitions

```sql
select p.proname, pg_get_function_identity_arguments(p.oid), p.prosecdef, p.proconfig,
       has_function_privilege('anon', p.oid, 'execute') as anon_execute,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_execute,
       pg_get_functiondef(p.oid)
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'fn_org_membership_active','rpc_subscribe_org_membership',
    'rpc_cancel_org_membership','rpc_process_membership_renewals',
    'rpc_submit_deal_review','rpc_submit_review','rpc_self_submit_mpk_review',
    'rpc_get_or_create_support_channel','rpc_send_message'
  );
```

Anonymous reachability probes were run under `SET TRANSACTION READ ONLY; SET LOCAL ROLE anon;` with nonexistent UUIDs and rollback:

```text
rpc_submit_deal_review → SQLSTATE P0001 BATCH_NOT_FOUND
rpc_send_message       → SQLSTATE P0001 FORBIDDEN: no authenticated user
```

Interpretation: both functions are reachable through anon ACL. Messaging fails closed in the body; review proceeds past ACL and caller authentication and only stops because the batch does not exist.

### 4.4 Storage and runtime facts

```sql
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'membership-documents';

select extname from pg_extension where extname in ('pg_cron','pg_graphql');

select count(*), min(current_period_start), max(current_period_end)
from public.membership_subscription;

select count(*), array_agg(distinct org_type)
from public.organization_type_assignments;

select count(*), array_agg(distinct verification_type), array_agg(distinct result)
from public.verification_records;
```

Observed:

- bucket exists, `public=false`, `file_size_limit=null`, `allowed_mime_types=null`;
- neither `pg_cron` nor `pg_graphql` is installed;
- `membership_subscription=0`, dates are null;
- `organization_type_assignments=36`, types `farmer/mpk/consultant`;
- `verification_records=0`.

### 4.5 Live-only functions

Live non-extension `public` function names were compared with function definitions parsed from `origin/main` d-files and migrations. System/extension prefixes were excluded.

```text
fn_health_restrictions_is_active
get_auth_user_id_by_email
get_auth_user_id_by_phone
```

These functions must not become an implicit dependency of MPK Profile until they have canonical DDL, explicit ACL and contract tests.

## 5. Security disposition

### 5.1 Immediate defect: canonical review write

`rpc_submit_deal_review` is `SECURITY DEFINER`, anon-executable and accepts a client-supplied organization ID. It confirms only that this organization is a party to the batch; it does not confirm that the caller belongs to it. The safe anonymous probe reached `BATCH_NOT_FOUND`, proving body reachability.

Implemented locally before ARS-360:

- revoke execute from `PUBLIC` and `anon`;
- grant only intended roles;
- bind reviewer org to `fn_my_org_ids()` / authenticated caller inside the function;
- keep fixed `search_path` and double-blind atomic reveal;
- add DB contract tests: anon denied at ACL, tenant A cannot submit as tenant B.

Files: `d02_tsp.sql`, `supabase/migrations/20260730085800_ars_352_review_acl_rls.sql`,
`tests/ars_352_review_acl_rls_test.sql`. The migration has not been deployed to live.

### 5.2 Existing defect: dimension score table

`deal_review_dimension_scores` is an exposed `public` table with RLS disabled and broad Data API grants. This is already named in ARS-274. The local migration enables inherited double-blind RLS and replaces broad grants with an authenticated read-only surface; ARS-358 must verify the final MPK tenant/anon matrix after deployment and ARS-360.

### 5.3 Legacy Data API grants

Every audited legacy table currently reports the complete privilege set for `anon`, `authenticated` and `service_role`. RLS still protects rows on most tables, but grants and RLS are separate layers. Explicit least-privilege grants/revokes are required, especially because Supabase is moving projects toward opt-in Data API exposure in 2026:

- https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically
- https://supabase.com/docs/guides/api/securing-your-api

## 6. EngSpec / epic amendments ready to apply

The missing MPK EngSpec should receive these normative statements before any DDL:

1. **Organization mapping:** DB names are `legal_name/bin_iin/region_id/address_text`; UI aliases do not rename storage fields.
2. **MPK profile:** no canonical `mpk_profiles` exists. The table/interface is a design decision, not an existing source. No direct frontend table writes; use typed read/write RPC after G2.
3. **RBAC:** extend `user_organization_roles`; four UI role names must map to `owner/manager/employee/viewer` or explicitly evolve its CHECK in one place.
4. **Membership:** source is `membership_subscription.state/current_period_*` plus `fn_org_membership_active`; never add `memberships.expires_at`.
5. **Verification:** `organization_type_assignments` classifies type; `verification_records` is append-only evidence timeline.
6. **Reviews:** `deal_reviews`/scores are the only final store; notes-based paths are compatibility adapters with a retire condition.
7. **Appeals:** messages stay in `comm_messages`; multiple cases are modeled above the permanent support channel with case/topic/ref/status.
8. **Storage:** reuse private `membership-documents` with org-scoped path; registry/workflow does not rely on raw Storage rows alone.
9. **Data API:** every new/existing object touched by MPK Profile gets explicit grants, RLS, indexes and anon/tenant tests. `SECURITY DEFINER` must revoke `PUBLIC` as well as `anon`.
10. **Production facts:** empty subscription/verification datasets are valid empty states. The UI must not fabricate dates or a completed verification timeline.

## 7. Conflict/defect register

Evidence was published as comments in ARS-351, ARS-352, ARS-274 and ARS-360 after explicit user approval. Creating separate issues was attempted twice, but Linear rejected both requests because the workspace exceeded its free issue limit.

### Capacity-blocked defect A — urgent security defect

**Title:** `SEC · anon может вызывать rpc_submit_deal_review от имени стороны сделки`

Scope: ACL revoke, caller↔org binding, tenant/anon contract tests. Local fix exists and the dependency is recorded on ARS-360; create the standalone defect when issue capacity becomes available.

### Capacity-blocked defect B — blocking documentation defect

**Title:** `MPK Profile · Канонические EngSpec/Slice10/tokens/prototype отсутствуют в репозитории`

Scope: add the four artifacts or correct ARS-351 canonical paths; add owner/version/checksum and this gap table. The blocker is recorded on ARS-351/352; create the standalone defect when issue capacity becomes available.

### Existing defect

ARS-274 already covers RLS disabled on `deal_review_dimension_scores`; live evidence and the local fix paths are published there.

## 8. Exit decision

ARS-352 is complete: the live evidence, gap table, conflict register and canonical source list have been produced and published. The audit itself does not deploy schema changes; the prepared review ACL/RLS migration remains an implementation deliverable for ARS-274/358/360 and must pass a local/preview DB behavioral gate before production.

The following findings remain explicit downstream blockers rather than reasons to keep the audit open:

- ARS-351/354: restore the declared EngSpec/Slice10/prototype/token artifacts or correct their canonical paths before fidelity sign-off;
- ARS-353/354: accept the source-of-truth and convergence decisions before new MPK Profile DDL;
- ARS-274/358/360: deploy and behavior-test the review ACL/RLS fix and complete the tenant/anon matrix;
- workspace administration: create the two standalone defects from §7 when Linear issue capacity becomes available.

No MPK Profile DDL should begin before MPK-CANON-01 is resolved and ARS-353/354 signs off the source-of-truth choices above.
