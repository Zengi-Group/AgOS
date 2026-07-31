-- AgOS · ARS-355 · MPK organization documents registry and private Storage workflow.
-- Additive deployment migration (production version 20260731074054). Keep in sync with d01_kernel.sql and d10_public_site.sql.
--
-- This migration deliberately creates a new private org-documents bucket. The
-- legacy membership-documents bucket and its direct-Storage callers are untouched.

-- =============================================================================
-- ARS-355 · MPK organization document registry and lifecycle.
--
-- The registry, rather than raw Storage rows, is the sole authority for the
-- document lifecycle. `org-documents` Storage configuration and RLS live in d10.
-- Existing `membership-documents` callers remain a separate legacy flow.
-- =============================================================================

create table if not exists public.org_documents (
    id                       uuid primary key default gen_random_uuid(),
    organization_id          uuid not null
                             references public.organizations(id) on delete restrict,
    kind                     text not null,
    title                    text not null,
    storage_path             text not null unique,
    original_file_name       text not null,
    mime_type                text,
    byte_size                bigint,
    issued_on                date,
    expires_on               date,
    upload_state             text not null default 'uploading'
                             check (upload_state in ('uploading', 'finalized', 'abandoned')),
    review_state             text not null default 'pending'
                             check (review_state in ('pending', 'accepted', 'rejected')),
    upload_expires_at        timestamptz not null,
    created_by_user_id       uuid references public.users(id) on delete set null,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    finalized_by_user_id     uuid references public.users(id) on delete set null,
    finalized_at             timestamptz,
    reviewed_by_user_id      uuid references public.users(id) on delete set null,
    reviewed_at              timestamptz,
    review_note              text,
    abandoned_at             timestamptz,
    storage_cleanup_at       timestamptz,
    cleanup_claim_token      uuid,
    cleanup_claimed_at       timestamptz,
    is_active                boolean not null default true,
    constraint org_documents_kind_check check (
        kind = lower(btrim(kind))
        and kind ~ '^[a-z][a-z0-9_]{0,63}$'
    ),
    constraint org_documents_title_check check (
        title = btrim(title) and length(title) between 1 and 300
    ),
    constraint org_documents_original_file_name_check check (
        original_file_name = btrim(original_file_name)
        and length(original_file_name) between 1 and 255
        and position('/' in original_file_name) = 0
        and position(chr(92) in original_file_name) = 0
        and original_file_name !~ '[[:cntrl:]]'
    ),
    constraint org_documents_mime_type_check check (
        mime_type is null
        or mime_type in ('application/pdf', 'image/jpeg', 'image/png')
    ),
    constraint org_documents_byte_size_check check (
        byte_size is null or (byte_size > 0 and byte_size <= 10485760)
    ),
    constraint org_documents_issue_expiry_check check (
        expires_on is null or issued_on is null or expires_on >= issued_on
    ),
    constraint org_documents_upload_window_check check (
        upload_expires_at >= created_at
        and (
            (upload_state = 'uploading'
                and is_active
                and finalized_at is null
                and finalized_by_user_id is null
                and abandoned_at is null
                and mime_type is null
                and byte_size is null)
            or
            (upload_state = 'finalized'
                and finalized_at is not null
                and finalized_by_user_id is not null
                and abandoned_at is null
                and mime_type is not null
                and byte_size is not null)
            or
            (upload_state = 'abandoned'
                and finalized_at is null
                and finalized_by_user_id is null
                and abandoned_at is not null
                and mime_type is null
                and byte_size is null
                and not is_active)
        )
    ),
    constraint org_documents_review_fsm_check check (
        (review_state = 'pending'
            and reviewed_at is null
            and reviewed_by_user_id is null
            and review_note is null)
        or
        (review_state in ('accepted', 'rejected')
            and upload_state = 'finalized'
            and reviewed_at is not null
            and reviewed_by_user_id is not null)
    ),
    constraint org_documents_cleanup_after_abandon_check check (
        storage_cleanup_at is null or upload_state = 'abandoned'
    ),
    constraint org_documents_cleanup_claim_check check (
        (cleanup_claim_token is null and cleanup_claimed_at is null)
        or (
            cleanup_claim_token is not null
            and cleanup_claimed_at is not null
            and upload_state = 'abandoned'
            and storage_cleanup_at is null
        )
    )
);

comment on table public.org_documents is
    'ARS-355: canonical registry for MPK organization documents. Storage objects are private implementation detail; UI status, days-left, and meter/tone are derived from lifecycle and dates, never stored.';
comment on column public.org_documents.storage_path is
    'Server-generated private object key: {organization_id}/{document_id}/upload. It is not exposed in client read models.';
comment on column public.org_documents.upload_state is
    'Internal upload lifecycle: uploading -> finalized | abandoned. This is not the user-facing document status.';
comment on column public.org_documents.review_state is
    'Review FSM reserved for the TURAN document queue: pending -> accepted | rejected.';

-- Composite/partial indexes match the active organization list, expiry scan, and
-- abandoned-upload cleanup predicates. FK actor columns are indexed separately.
create index if not exists idx_org_documents_active_org_review_created
    on public.org_documents (organization_id, review_state, created_at desc)
    where is_active;
create index if not exists idx_org_documents_active_accepted_expiry
    on public.org_documents (organization_id, expires_on)
    where is_active
      and upload_state = 'finalized'
      and review_state = 'accepted'
      and expires_on is not null;
create index if not exists idx_org_documents_expired_upload_cleanup
    on public.org_documents (upload_expires_at)
    where is_active and upload_state = 'uploading';
create index if not exists idx_org_documents_abandoned_cleanup_claim
    on public.org_documents (cleanup_claimed_at, abandoned_at)
    where upload_state = 'abandoned' and storage_cleanup_at is null;
create index if not exists idx_org_documents_created_by
    on public.org_documents (created_by_user_id)
    where created_by_user_id is not null;
create index if not exists idx_org_documents_finalized_by
    on public.org_documents (finalized_by_user_id)
    where finalized_by_user_id is not null;
create index if not exists idx_org_documents_reviewed_by
    on public.org_documents (reviewed_by_user_id)
    where reviewed_by_user_id is not null;

-- The document key is always server-derived. The trigger also makes terminal upload
-- and review states monotonic so a direct privileged update cannot reopen history.
create or replace function public.fn_guard_org_document_lifecycle()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
    v_expected_path text;
begin
    if tg_op = 'INSERT' then
        if new.id is null then
            new.id := gen_random_uuid();
        end if;
        v_expected_path := new.organization_id::text || '/' || new.id::text || '/upload';
        new.storage_path := v_expected_path;
        if new.upload_state <> 'uploading' or new.review_state <> 'pending' then
            raise exception 'ORG_DOCUMENT_INTENT_REQUIRED' using errcode = 'P0001';
        end if;
        return new;
    end if;

    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.kind is distinct from old.kind
       or new.title is distinct from old.title
       or new.storage_path is distinct from old.storage_path
       or new.original_file_name is distinct from old.original_file_name
       or new.issued_on is distinct from old.issued_on
       or new.expires_on is distinct from old.expires_on
       or new.upload_expires_at is distinct from old.upload_expires_at
       or new.created_by_user_id is distinct from old.created_by_user_id
       or new.created_at is distinct from old.created_at then
        raise exception 'ORG_DOCUMENT_IDENTITY_IMMUTABLE' using errcode = 'P0001';
    end if;

    if old.upload_state = 'uploading' then
        if new.upload_state not in ('uploading', 'finalized', 'abandoned') then
            raise exception 'ORG_DOCUMENT_INVALID_UPLOAD_TRANSITION' using errcode = 'P0001';
        end if;
    elsif new.upload_state is distinct from old.upload_state then
        raise exception 'ORG_DOCUMENT_UPLOAD_TERMINAL' using errcode = 'P0001';
    end if;

    if old.upload_state = 'finalized'
       and (
           new.finalized_by_user_id is distinct from old.finalized_by_user_id
           or new.finalized_at is distinct from old.finalized_at
           or new.mime_type is distinct from old.mime_type
           or new.byte_size is distinct from old.byte_size
       ) then
        raise exception 'ORG_DOCUMENT_FINALIZED_METADATA_IMMUTABLE' using errcode = 'P0001';
    end if;

    if old.upload_state = 'abandoned'
       and new.abandoned_at is distinct from old.abandoned_at then
        raise exception 'ORG_DOCUMENT_ABANDONED_AT_IMMUTABLE' using errcode = 'P0001';
    end if;

    if old.review_state = 'pending' then
        if new.review_state not in ('pending', 'accepted', 'rejected') then
            raise exception 'ORG_DOCUMENT_INVALID_REVIEW_TRANSITION' using errcode = 'P0001';
        end if;
    elsif new.review_state is distinct from old.review_state then
        raise exception 'ORG_DOCUMENT_REVIEW_TERMINAL' using errcode = 'P0001';
    end if;

    if old.review_state in ('accepted', 'rejected')
       and (
           new.reviewed_by_user_id is distinct from old.reviewed_by_user_id
           or new.reviewed_at is distinct from old.reviewed_at
           or new.review_note is distinct from old.review_note
       ) then
        raise exception 'ORG_DOCUMENT_REVIEW_IMMUTABLE' using errcode = 'P0001';
    end if;

    if old.upload_state <> 'abandoned'
       and new.storage_cleanup_at is not null then
        raise exception 'ORG_DOCUMENT_CLEANUP_REQUIRES_ABANDONED' using errcode = 'P0001';
    end if;

    new.updated_at := now();
    return new;
end;
$$;

revoke execute on function public.fn_guard_org_document_lifecycle()
    from public, anon, authenticated;

drop trigger if exists trg_org_documents_lifecycle on public.org_documents;
create trigger trg_org_documents_lifecycle
    before insert or update on public.org_documents
    for each row execute function public.fn_guard_org_document_lifecycle();

-- No direct Data API access: all user mutations are permission-checked RPCs and
-- service-only maintenance. RLS remains enabled as defence in depth.
alter table public.org_documents enable row level security;

drop policy if exists org_documents_service_role_all on public.org_documents;
create policy org_documents_service_role_all
    on public.org_documents for all
    to service_role
    using (true)
    with check (true);

revoke all on table public.org_documents
    from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.org_documents to service_role;

-- Phase 1 of an upload is an intent. It returns only the opaque id and path needed
-- for Storage upload; profile read models must never return storage_path.
create or replace function public.rpc_create_org_document_upload_intent(
    p_organization_id    uuid,
    p_kind               text,
    p_title              text,
    p_original_file_name text,
    p_issued_on          date default null,
    p_expires_on         date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id public.users.id%type := public.fn_current_user_id();
    v_document public.org_documents%rowtype;
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.documents.manage') then
        raise exception 'FORBIDDEN: mpk.documents.manage required' using errcode = '42501';
    end if;
    if not exists (
        select 1
        from public.organizations o
        join public.organization_type_assignments ota
          on ota.organization_id = o.id and ota.org_type = 'mpk'
        where o.id = p_organization_id and o.is_active
    ) then
        raise exception 'ORG_NOT_ACTIVE_MPK' using errcode = 'P0001';
    end if;

    insert into public.org_documents (
        organization_id, kind, title, original_file_name,
        issued_on, expires_on, upload_expires_at, created_by_user_id
    ) values (
        p_organization_id,
        lower(btrim(p_kind)),
        btrim(p_title),
        btrim(p_original_file_name),
        p_issued_on,
        p_expires_on,
        clock_timestamp() + interval '15 minutes',
        v_actor_id
    ) returning * into v_document;

    return jsonb_build_object(
        'id', v_document.id,
        'storage_path', v_document.storage_path,
        'upload_expires_at', v_document.upload_expires_at
    );
end;
$$;

-- Phase 2 is server-verified against the Storage metadata. A failed/missing upload
-- never becomes a finalized or reviewable document.
create or replace function public.rpc_finalize_org_document_upload(
    p_organization_id uuid,
    p_document_id     uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id  public.users.id%type := public.fn_current_user_id();
    v_document  public.org_documents%rowtype;
    v_metadata  jsonb;
    v_mime_type text;
    v_size_text text;
    v_byte_size bigint;
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.documents.manage') then
        raise exception 'FORBIDDEN: mpk.documents.manage required' using errcode = '42501';
    end if;

    select * into v_document
    from public.org_documents d
    where d.id = p_document_id and d.organization_id = p_organization_id
    for update;
    if not found then
        raise exception 'ORG_DOCUMENT_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_document.upload_state = 'finalized' then
        return jsonb_build_object(
            'id', v_document.id,
            'review_state', v_document.review_state,
            'finalized_at', v_document.finalized_at,
            'idempotent', true
        );
    end if;
    if v_document.upload_state <> 'uploading'
       or not v_document.is_active
       or v_document.upload_expires_at <= clock_timestamp() then
        raise exception 'ORG_DOCUMENT_UPLOAD_NOT_OPEN' using errcode = 'P0001';
    end if;

    -- Lock the Storage row while validating it. An authorized client upsert takes
    -- the same row lock, so it either completes before this read or is rechecked
    -- against the now-finalized registry state after this transaction commits.
    select o.metadata into v_metadata
    from storage.objects o
    where o.bucket_id = 'org-documents'
      and o.name = v_document.storage_path
    for update;
    if not found then
        raise exception 'ORG_DOCUMENT_UPLOAD_OBJECT_NOT_FOUND' using errcode = 'P0001';
    end if;

    v_mime_type := coalesce(v_metadata ->> 'mimetype', '');
    v_size_text := coalesce(v_metadata ->> 'size', '');
    if v_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
        raise exception 'ORG_DOCUMENT_UNSUPPORTED_MIME_TYPE' using errcode = 'P0001';
    end if;
    if v_size_text !~ '^[0-9]+$' then
        raise exception 'ORG_DOCUMENT_INVALID_OBJECT_SIZE' using errcode = 'P0001';
    end if;
    v_byte_size := v_size_text::bigint;
    if v_byte_size <= 0 or v_byte_size > 10485760 then
        raise exception 'ORG_DOCUMENT_FILE_SIZE_LIMIT_EXCEEDED' using errcode = 'P0001';
    end if;

    update public.org_documents
       set upload_state = 'finalized',
           finalized_by_user_id = v_actor_id,
           finalized_at = clock_timestamp(),
           mime_type = v_mime_type,
           byte_size = v_byte_size
     where id = v_document.id
     returning * into v_document;

    return jsonb_build_object(
        'id', v_document.id,
        'review_state', v_document.review_state,
        'finalized_at', v_document.finalized_at,
        'idempotent', false
    );
end;
$$;

create or replace function public.rpc_abandon_org_document_upload(
    p_organization_id uuid,
    p_document_id     uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_actor_id public.users.id%type := public.fn_current_user_id();
    v_document public.org_documents%rowtype;
begin
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not public.fn_org_has_permission(p_organization_id, 'mpk.documents.manage') then
        raise exception 'FORBIDDEN: mpk.documents.manage required' using errcode = '42501';
    end if;

    select * into v_document
    from public.org_documents d
    where d.id = p_document_id and d.organization_id = p_organization_id
    for update;
    if not found then
        raise exception 'ORG_DOCUMENT_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_document.upload_state = 'abandoned' then
        return jsonb_build_object('id', v_document.id, 'idempotent', true);
    end if;
    if v_document.upload_state <> 'uploading' then
        raise exception 'ORG_DOCUMENT_UPLOAD_ALREADY_FINALIZED' using errcode = 'P0001';
    end if;

    update public.org_documents
       set upload_state = 'abandoned',
           is_active = false,
           abandoned_at = clock_timestamp()
     where id = v_document.id
     returning * into v_document;

    return jsonb_build_object('id', v_document.id, 'idempotent', false);
end;
$$;

-- Service-only maintenance is called by the Edge Function, which removes actual
-- Storage objects through the Storage API rather than mutating storage.objects SQL.
create or replace function public.fn_claim_org_document_storage_cleanup(
    p_limit integer default 100,
    p_claim_token uuid default null,
    p_organization_id uuid default null
)
returns table(document_id uuid, storage_path text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
    v_claim_token uuid := coalesce(p_claim_token, gen_random_uuid());
begin
    update public.org_documents d
       set upload_state = 'abandoned',
           is_active = false,
           abandoned_at = clock_timestamp()
     where d.id in (
        select stale.id
        from public.org_documents stale
        where stale.is_active
          and stale.upload_state = 'uploading'
          and stale.upload_expires_at <= clock_timestamp()
          and (p_organization_id is null or stale.organization_id = p_organization_id)
        order by stale.upload_expires_at
        limit v_limit
        for update skip locked
     );

    return query
    with candidates as (
        select d.id
        from public.org_documents d
        where d.upload_state = 'abandoned'
          and d.storage_cleanup_at is null
          and (p_organization_id is null or d.organization_id = p_organization_id)
          and (
              d.cleanup_claimed_at is null
              or d.cleanup_claimed_at <= clock_timestamp() - interval '15 minutes'
          )
        order by d.abandoned_at nulls last, d.created_at
        limit v_limit
        for update skip locked
    ), claimed as (
        update public.org_documents d
           set cleanup_claim_token = v_claim_token,
               cleanup_claimed_at = clock_timestamp()
          from candidates c
         where d.id = c.id
         returning d.id, d.storage_path
    )
    select c.id, c.storage_path
    from claimed c;
end;
$$;

create or replace function public.fn_mark_org_document_storage_cleaned(
    p_document_ids uuid[],
    p_claim_token uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_updated integer;
begin
    update public.org_documents d
       set storage_cleanup_at = clock_timestamp(),
           cleanup_claim_token = null,
           cleanup_claimed_at = null
     where d.id = any(coalesce(p_document_ids, array[]::uuid[]))
       and d.upload_state = 'abandoned'
       and d.storage_cleanup_at is null
       and d.cleanup_claim_token = p_claim_token;
    get diagnostics v_updated = row_count;
    return v_updated;
end;
$$;

-- Only the trusted signed-URL Edge Function receives a raw path. Its service-role
-- caller has already verified the user's JWT and passes the auth subject below.
create or replace function public.fn_get_org_document_download_path(
    p_actor_auth_id   uuid,
    p_organization_id uuid,
    p_document_id     uuid
)
returns text
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_storage_path text;
begin
    if p_actor_auth_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;
    if not (
        exists (
            select 1
            from public.admin_roles ar
            join public.users u on u.id = ar.user_id
            where u.auth_id = p_actor_auth_id
              and u.is_active
              and ar.is_active
        )
        or exists (
            select 1
            from public.users u
            join public.user_organization_roles uor on uor.user_id = u.id
            join public.organization_role_permissions rp on rp.role = uor.role
            join public.organization_permissions p
              on p.code = rp.permission_code and p.is_active
            where u.auth_id = p_actor_auth_id
              and u.is_active
              and uor.organization_id = p_organization_id
              and rp.permission_code = 'mpk.documents.manage'
        )
    ) then
        raise exception 'FORBIDDEN: mpk.documents.manage required' using errcode = '42501';
    end if;

    select d.storage_path into v_storage_path
    from public.org_documents d
    where d.id = p_document_id
      and d.organization_id = p_organization_id
      and d.is_active
      and d.upload_state = 'finalized';
    if not found then
        raise exception 'ORG_DOCUMENT_NOT_FOUND' using errcode = 'P0001';
    end if;
    return v_storage_path;
end;
$$;

revoke execute on function public.rpc_create_org_document_upload_intent(uuid, text, text, text, date, date)
    from public, anon;
revoke execute on function public.rpc_finalize_org_document_upload(uuid, uuid)
    from public, anon;
revoke execute on function public.rpc_abandon_org_document_upload(uuid, uuid)
    from public, anon;
revoke execute on function public.fn_claim_org_document_storage_cleanup(integer, uuid, uuid)
    from public, anon, authenticated;
revoke execute on function public.fn_mark_org_document_storage_cleaned(uuid[], uuid)
    from public, anon, authenticated;
revoke execute on function public.fn_get_org_document_download_path(uuid, uuid, uuid)
    from public, anon, authenticated;

grant execute on function public.rpc_create_org_document_upload_intent(uuid, text, text, text, date, date)
    to authenticated, service_role;
grant execute on function public.rpc_finalize_org_document_upload(uuid, uuid)
    to authenticated, service_role;
grant execute on function public.rpc_abandon_org_document_upload(uuid, uuid)
    to authenticated, service_role;
grant execute on function public.fn_claim_org_document_storage_cleanup(integer, uuid, uuid)
    to service_role;
grant execute on function public.fn_mark_org_document_storage_cleaned(uuid[], uuid)
    to service_role;
grant execute on function public.fn_get_org_document_download_path(uuid, uuid, uuid)
    to service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
    ('rpc_create_org_document_upload_intent', 'rpc_create_org_document_upload_intent', 'ARS-355', 'Creates an authorized private document upload intent and server-derived storage path'),
    ('rpc_finalize_org_document_upload', 'rpc_finalize_org_document_upload', 'ARS-355', 'Finalizes an uploaded object only after metadata validation'),
    ('rpc_abandon_org_document_upload', 'rpc_abandon_org_document_upload', 'ARS-355', 'Marks an in-progress document upload abandoned for Storage API cleanup')
on conflict (sql_name) do update
set dok3_name = excluded.dok3_name,
    notes = excluded.notes,
    created_in = excluded.created_in,
    status = 'active';

-- =============================================================================
-- ARS-355 · private Storage bucket and exact intent-bound policies.
-- =============================================================================

-- ARS-355: an isolated private bucket for the registry-backed MPK document
-- workflow. Keep membership-documents untouched: its legacy direct-Storage
-- callers have a different path and authorization contract.
insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) values (
  'org-documents',
  'org-documents',
  false,
  10485760,
  array['application/pdf', 'image/jpeg', 'image/png']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- ARS-355: exact registry-bound authorization for org-documents. The object key
-- is server-derived as {organization_id}/{document_id}/upload. Matching the
-- complete path against public.org_documents (rather than just folder [1])
-- prevents a same-org caller from writing arbitrary document keys.
--
-- This deliberately permits SELECT/UPDATE only while the intent is open. Storage
-- needs SELECT + UPDATE for client upsert, but finalized documents are downloaded
-- through the JWT-protected Edge Function that creates a 60-second signed URL.
create or replace function public.fn_org_document_storage_upload_allowed(
  p_object_name text
)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select (select auth.uid()) is not null
       and exists (
            select 1
            from public.org_documents d
            where d.storage_path = p_object_name
              and d.is_active
              and d.upload_state = 'uploading'
              and d.upload_expires_at > now()
              and (
                    public.fn_is_admin()
                    or public.fn_org_has_permission(
                        d.organization_id, 'mpk.documents.manage'
                    )
              )
       );
$$;

comment on function public.fn_org_document_storage_upload_allowed(text) is
  'ARS-355. RLS-only predicate for exact, unexpired org-document upload intents. Allows INSERT/SELECT/UPDATE needed by Storage upsert; finalized objects require a signed URL.';

-- The predicate is called by storage.objects policies under the authenticated
-- role. PUBLIC/anon must not execute it; authenticated is intentionally granted
-- so the policy can evaluate it (the function itself requires auth.uid()).
revoke execute on function public.fn_org_document_storage_upload_allowed(text)
  from public, anon;
grant execute on function public.fn_org_document_storage_upload_allowed(text)
  to authenticated, service_role;

-- org-documents (ARS-355): private, registry-backed two-phase upload.
-- No anonymous policy and no client DELETE policy are intentional. Orphan cleanup
-- uses the Storage API with the service role after the registry marks it abandoned.
drop policy if exists "org_documents_insert_intent" on storage.objects;
create policy "org_documents_insert_intent"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'org-documents'
    and (select public.fn_org_document_storage_upload_allowed(name))
  );

-- Required alongside INSERT for Storage's RETURNING behaviour and alongside
-- UPDATE for the client upsert protocol. Once finalized, this policy no longer
-- matches, so a raw Storage download/list is denied.
drop policy if exists "org_documents_select_open_intent" on storage.objects;
create policy "org_documents_select_open_intent"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'org-documents'
    and (select public.fn_org_document_storage_upload_allowed(name))
  );

drop policy if exists "org_documents_update_open_intent" on storage.objects;
create policy "org_documents_update_open_intent"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'org-documents'
    and (select public.fn_org_document_storage_upload_allowed(name))
  )
  with check (
    bucket_id = 'org-documents'
    and (select public.fn_org_document_storage_upload_allowed(name))
  );
