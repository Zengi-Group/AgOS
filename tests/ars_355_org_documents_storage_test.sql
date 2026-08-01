-- ARS-355 regression contract.
-- Run after supabase/migrations/20260731074054_ars_355_org_documents_registry.sql.
-- The transaction rolls back all fixtures, including temporary Storage rows.

begin;

do $$
declare
    v_actor_user_id       uuid;
    v_actor_auth_id       uuid;
    v_other_user_id       uuid;
    v_other_auth_id       uuid;
    v_org_a               uuid := gen_random_uuid();
    v_org_b               uuid := gen_random_uuid();
    v_intent              jsonb;
    v_other_intent        jsonb;
    v_result              jsonb;
    v_document_id         uuid;
    v_missing_document_id uuid;
    v_bad_mime_document_id uuid;
    v_bad_size_document_id uuid;
    v_storage_path        text;
    v_other_storage_path  text;
    v_bad_mime_path       text;
    v_bad_size_path       text;
    v_count               integer;
    v_updated             integer;
    v_marked              integer;
    v_claimed             integer;
    v_second_claimed      integer;
    v_claim_token_a       uuid := gen_random_uuid();
    v_claim_token_b       uuid := gen_random_uuid();
    v_error               text;
    v_role                text;
    v_fk_delete_action    "char";
begin
    -- Use two normal authenticated users so global-admin bypass cannot hide a
    -- tenant-isolation defect in the Storage policies.
    select u.id, u.auth_id
      into v_actor_user_id, v_actor_auth_id
    from public.users u
    where u.auth_id is not null
      and u.is_active
      and not exists (
          select 1 from public.admin_roles ar
          where ar.user_id = u.id and ar.is_active
      )
    order by u.created_at
    limit 1;

    select u.id, u.auth_id
      into v_other_user_id, v_other_auth_id
    from public.users u
    where u.auth_id is not null
      and u.is_active
      and u.id <> v_actor_user_id
      and not exists (
          select 1 from public.admin_roles ar
          where ar.user_id = u.id and ar.is_active
      )
    order by u.created_at
    limit 1;

    if v_actor_user_id is null or v_other_user_id is null then
        raise exception 'ARS-355_TEST_SETUP: requires two active non-admin auth-backed users';
    end if;

    -- Storage bucket, exact RLS policies, registry-only table access, and ACLs.
    if not exists (
        select 1
        from storage.buckets b
        where b.id = 'org-documents'
          and b.name = 'org-documents'
          and not b.public
          and b.file_size_limit = 10485760
          and b.allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']::text[]
    ) then
        raise exception 'ARS-355: org-documents bucket privacy/MIME/size contract missing';
    end if;

    foreach v_role in array array[
        'org_documents_insert_intent',
        'org_documents_select_open_intent',
        'org_documents_update_open_intent'
    ] loop
        if not exists (
            select 1
            from pg_policies p
            where p.schemaname = 'storage'
              and p.tablename = 'objects'
              and p.policyname = v_role
              and p.roles @> array['authenticated'::name]
        ) then
            raise exception 'ARS-355: Storage policy % missing or not authenticated-only', v_role;
        end if;
    end loop;
    if exists (
        select 1
        from pg_policies p
        where p.schemaname = 'storage'
          and p.tablename = 'objects'
          and p.policyname ilike 'org_documents_delete%'
    ) then
        raise exception 'ARS-355: client delete policy must not exist';
    end if;
    if has_table_privilege('anon', 'public.org_documents', 'select')
       or has_table_privilege('authenticated', 'public.org_documents', 'select')
       or has_table_privilege('authenticated', 'public.org_documents', 'insert')
       or has_table_privilege('authenticated', 'public.org_documents', 'update')
       or has_table_privilege('authenticated', 'public.org_documents', 'delete') then
        raise exception 'ARS-355: direct org_documents Data API access exists';
    end if;
    if has_function_privilege(
        'anon',
        'public.rpc_create_org_document_upload_intent(uuid,text,text,text,date,date)',
        'execute'
    ) or has_function_privilege(
        'anon', 'public.rpc_finalize_org_document_upload(uuid,uuid)', 'execute'
    ) or has_function_privilege(
        'anon', 'public.rpc_abandon_org_document_upload(uuid,uuid)', 'execute'
    ) then
        raise exception 'ARS-355: anonymous mutation RPC access exists';
    end if;
    if not has_function_privilege(
        'authenticated',
        'public.rpc_create_org_document_upload_intent(uuid,text,text,text,date,date)',
        'execute'
    ) or not has_function_privilege(
        'authenticated', 'public.rpc_finalize_org_document_upload(uuid,uuid)', 'execute'
    ) or not has_function_privilege(
        'authenticated', 'public.rpc_abandon_org_document_upload(uuid,uuid)', 'execute'
    ) then
        raise exception 'ARS-355: authenticated mutation RPC grant missing';
    end if;
    if has_function_privilege(
        'authenticated',
        'public.fn_claim_org_document_storage_cleanup(integer,uuid,uuid)',
        'execute'
    ) or has_function_privilege(
        'authenticated',
        'public.fn_mark_org_document_storage_cleaned(uuid[],uuid)',
        'execute'
    ) or has_function_privilege(
        'authenticated',
        'public.fn_get_org_document_download_path(uuid,uuid,uuid)',
        'execute'
    ) then
        raise exception 'ARS-355: service-only helper is client-executable';
    end if;
    if not has_function_privilege(
        'authenticated', 'public.fn_org_document_storage_upload_allowed(text)', 'execute'
    ) then
        raise exception 'ARS-355: Storage RLS predicate cannot execute for authenticated clients';
    end if;
    if exists (
        select 1
        from information_schema.columns c
        where c.table_schema = 'public'
          and c.table_name = 'org_documents'
          and c.column_name = any(array['status', 'days_left', 'meter_pct', 'tone'])
    ) then
        raise exception 'ARS-355: derived document status/expiry UI fields were persisted';
    end if;
    if not exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_documents'
          and indexname = 'idx_org_documents_active_org_review_created'
    ) or not exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_documents'
          and indexname = 'idx_org_documents_active_accepted_expiry'
    ) or not exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_documents'
          and indexname = 'idx_org_documents_expired_upload_cleanup'
    ) then
        raise exception 'ARS-355: required active/expiry/cleanup index missing';
    end if;
    select c.confdeltype
      into v_fk_delete_action
    from pg_constraint c
    where c.conrelid = 'public.org_documents'::regclass
      and c.confrelid = 'public.organizations'::regclass
      and c.contype = 'f';
    if v_fk_delete_action is distinct from 'r' then
        raise exception 'ARS-355: organization deletion must be restricted until Storage cleanup';
    end if;

    insert into public.organizations (id, legal_name)
    values
        (v_org_a, 'QA ARS-355 MPK A'),
        (v_org_b, 'QA ARS-355 MPK B');
    insert into public.organization_type_assignments (organization_id, org_type)
    values (v_org_a, 'mpk'), (v_org_b, 'mpk');
    insert into public.user_organization_roles (user_id, organization_id, role, is_primary)
    values
        (v_actor_user_id, v_org_a, 'mpk_admin', false),
        (v_other_user_id, v_org_b, 'mpk_admin', false);

    -- Tenant A receives a server-derived exact upload intent. The returned path is
    -- an ephemeral upload capability only; it is never part of final read output.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_actor_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    v_intent := public.rpc_create_org_document_upload_intent(
        v_org_a, 'registration_certificate', '  QA registration  ', '  certificate.pdf  ',
        current_date - 2, current_date - 1
    );
    v_document_id := (v_intent->>'id')::uuid;
    v_storage_path := v_intent->>'storage_path';
    if v_storage_path is distinct from (
        v_org_a::text || '/' || v_document_id::text || '/upload'
    )
       or v_intent->>'upload_expires_at' is null
       or not exists (
           select 1 from public.org_documents d
           where d.id = v_document_id
             and d.organization_id = v_org_a
             and d.kind = 'registration_certificate'
             and d.title = 'QA registration'
             and d.original_file_name = 'certificate.pdf'
             and d.upload_state = 'uploading'
             and d.review_state = 'pending'
             and d.is_active
       ) then
        raise exception 'ARS-355: intent/path/lifecycle contract failed';
    end if;

    -- The authorized uploader gets INSERT + SELECT + UPDATE while the intent is
    -- open. This mirrors the Storage API upsert permission sequence.
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (
        'org-documents', v_storage_path, v_actor_auth_id::text,
        jsonb_build_object('mimetype', 'application/pdf', 'size', '42')
    );
    select count(*) into v_count
    from storage.objects o
    where o.bucket_id = 'org-documents' and o.name = v_storage_path;
    update storage.objects
       set metadata = jsonb_build_object('mimetype', 'application/pdf', 'size', '42')
     where bucket_id = 'org-documents' and name = v_storage_path;
    get diagnostics v_updated = row_count;
    execute 'reset role';
    if v_count <> 1 or v_updated <> 1 then
        raise exception 'ARS-355: open intent did not allow Storage insert/select/update upsert';
    end if;

    -- Tenant B gets its own intent. Tenant A cannot create, list, or overwrite its
    -- object even when it knows the exact object name.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_other_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    v_other_intent := public.rpc_create_org_document_upload_intent(
        v_org_b, 'tax_registration', 'QA tax', 'tax.pdf', null, null
    );
    v_other_storage_path := v_other_intent->>'storage_path';

    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_actor_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    v_error := null;
    execute 'set local role authenticated';
    begin
        insert into storage.objects (bucket_id, name, owner_id, metadata)
        values (
            'org-documents', v_other_storage_path, v_actor_auth_id::text,
            jsonb_build_object('mimetype', 'application/pdf', 'size', '42')
        );
        raise exception 'ARS-355: tenant A unexpectedly uploaded into tenant B intent';
    exception
        when insufficient_privilege then
            get stacked diagnostics v_error = message_text;
    end;
    execute 'reset role';
    if v_error is null then
        raise exception 'ARS-355: cross-tenant Storage INSERT was not denied';
    end if;

    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_other_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (
        'org-documents', v_other_storage_path, v_other_auth_id::text,
        jsonb_build_object('mimetype', 'application/pdf', 'size', '42')
    );
    execute 'reset role';

    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_actor_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
    select count(*) into v_count
    from storage.objects o
    where o.bucket_id = 'org-documents' and o.name = v_other_storage_path;
    update storage.objects
       set metadata = jsonb_build_object('mimetype', 'application/pdf', 'size', '43')
     where bucket_id = 'org-documents' and name = v_other_storage_path;
    get diagnostics v_updated = row_count;
    execute 'reset role';
    if v_count <> 0 or v_updated <> 0 then
        raise exception 'ARS-355: tenant A can read or update tenant B Storage object';
    end if;

    -- The supplied organization id is not trusted by public mutation RPCs.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_other_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    begin
        perform public.rpc_finalize_org_document_upload(v_org_a, v_document_id);
        raise exception 'ARS-355: tenant B unexpectedly finalized tenant A document';
    exception
        when insufficient_privilege then null;
    end;

    -- Role names are not enough: the canonical permission mapping denies both.
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', v_actor_auth_id::text, 'role', 'authenticated')::text,
        true
    );
    foreach v_role in array array['procurement', 'accountant'] loop
        update public.user_organization_roles
           set role = v_role
         where user_id = v_actor_user_id and organization_id = v_org_a;
        begin
            perform public.rpc_create_org_document_upload_intent(
                v_org_a, 'other', 'Denied', 'denied.pdf', null, null
            );
            raise exception 'ARS-355: % unexpectedly created document intent', v_role;
        exception
            when insufficient_privilege then null;
        end;
    end loop;
    update public.user_organization_roles
       set role = 'mpk_admin'
     where user_id = v_actor_user_id and organization_id = v_org_a;

    -- Missing objects and metadata validation cannot create a finalized document.
    v_intent := public.rpc_create_org_document_upload_intent(
        v_org_a, 'other', 'Missing', 'missing.pdf', null, null
    );
    v_missing_document_id := (v_intent->>'id')::uuid;
    begin
        perform public.rpc_finalize_org_document_upload(v_org_a, v_missing_document_id);
        raise exception 'ARS-355: missing object unexpectedly finalized';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'ORG_DOCUMENT_UPLOAD_OBJECT_NOT_FOUND' then raise; end if;
    end;

    v_intent := public.rpc_create_org_document_upload_intent(
        v_org_a, 'other', 'Bad MIME', 'bad-mime.pdf', null, null
    );
    v_bad_mime_document_id := (v_intent->>'id')::uuid;
    v_bad_mime_path := v_intent->>'storage_path';
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (
        'org-documents', v_bad_mime_path, v_actor_auth_id::text,
        jsonb_build_object('mimetype', 'application/pdf', 'size', '42')
    );
    execute 'reset role';
    -- Simulate a corrupt/forged object metadata row after a valid upload. The
    -- Storage API bucket gate is smoke-tested separately; finalize must still
    -- fail closed if metadata does not match the registry contract.
    update storage.objects
       set metadata = jsonb_build_object('mimetype', 'text/plain', 'size', '42')
     where bucket_id = 'org-documents' and name = v_bad_mime_path;
    begin
        perform public.rpc_finalize_org_document_upload(v_org_a, v_bad_mime_document_id);
        raise exception 'ARS-355: unsupported MIME unexpectedly finalized';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'ORG_DOCUMENT_UNSUPPORTED_MIME_TYPE' then raise; end if;
    end;

    v_intent := public.rpc_create_org_document_upload_intent(
        v_org_a, 'other', 'Too large', 'too-large.pdf', null, null
    );
    v_bad_size_document_id := (v_intent->>'id')::uuid;
    v_bad_size_path := v_intent->>'storage_path';
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (
        'org-documents', v_bad_size_path, v_actor_auth_id::text,
        jsonb_build_object('mimetype', 'application/pdf', 'size', '42')
    );
    execute 'reset role';
    update storage.objects
       set metadata = jsonb_build_object('mimetype', 'application/pdf', 'size', '10485761')
     where bucket_id = 'org-documents' and name = v_bad_size_path;
    begin
        perform public.rpc_finalize_org_document_upload(v_org_a, v_bad_size_document_id);
        raise exception 'ARS-355: oversized object unexpectedly finalized';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'ORG_DOCUMENT_FILE_SIZE_LIMIT_EXCEEDED' then raise; end if;
    end;

    -- Finalize is locked, idempotent, stores validated metadata, and never returns
    -- the object path. After finalization raw Storage SELECT/UPDATE is closed.
    v_result := public.rpc_finalize_org_document_upload(v_org_a, v_document_id);
    if (v_result->>'id')::uuid <> v_document_id
       or (v_result->>'idempotent')::boolean
       or v_result ? 'storage_path'
       or not exists (
           select 1 from public.org_documents d
           where d.id = v_document_id
             and d.upload_state = 'finalized'
             and d.review_state = 'pending'
             and d.mime_type = 'application/pdf'
             and d.byte_size = 42
       ) then
        raise exception 'ARS-355: finalize contract or metadata audit failed';
    end if;
    v_result := public.rpc_finalize_org_document_upload(v_org_a, v_document_id);
    if not (v_result->>'idempotent')::boolean then
        raise exception 'ARS-355: second finalize was not idempotent';
    end if;

    execute 'set local role authenticated';
    select count(*) into v_count
    from storage.objects o
    where o.bucket_id = 'org-documents' and o.name = v_storage_path;
    update storage.objects
       set metadata = jsonb_build_object('mimetype', 'application/pdf', 'size', '43')
     where bucket_id = 'org-documents' and name = v_storage_path;
    get diagnostics v_updated = row_count;
    execute 'reset role';
    if v_count <> 0 or v_updated <> 0 then
        raise exception 'ARS-355: finalized object is directly readable or mutable';
    end if;

    -- The reserved review FSM is monotonic; expiry is a predicate over accepted
    -- data, not a stored UI status/meter.
    update public.org_documents
       set review_state = 'accepted',
           reviewed_by_user_id = v_actor_user_id,
           reviewed_at = clock_timestamp(),
           review_note = 'QA accepted'
     where id = v_document_id;
    begin
        update public.org_documents
           set review_state = 'rejected',
               reviewed_by_user_id = v_actor_user_id,
               reviewed_at = clock_timestamp(),
               review_note = 'Illegal rewrite'
         where id = v_document_id;
        raise exception 'ARS-355: terminal review state was rewritten';
    exception
        when raise_exception then
            get stacked diagnostics v_error = message_text;
            if v_error <> 'ORG_DOCUMENT_REVIEW_TERMINAL' then raise; end if;
    end;
    if not exists (
        select 1 from public.org_documents d
        where d.id = v_document_id
          and d.review_state = 'accepted'
          and d.expires_on < current_date
    ) then
        raise exception 'ARS-355: accepted expiry derivation fixture failed';
    end if;

    -- Abandon is idempotent; cleanup claims are lease-token-bound so concurrent
    -- workers cannot acknowledge the same object.
    v_result := public.rpc_abandon_org_document_upload(v_org_a, v_bad_mime_document_id);
    if (v_result->>'idempotent')::boolean then
        raise exception 'ARS-355: first abandon unexpectedly idempotent';
    end if;
    v_result := public.rpc_abandon_org_document_upload(v_org_a, v_bad_mime_document_id);
    if not (v_result->>'idempotent')::boolean then
        raise exception 'ARS-355: second abandon was not idempotent';
    end if;
    select count(*) into v_claimed
    from public.fn_claim_org_document_storage_cleanup(
        10, v_claim_token_a, v_org_a
    ) c
    where c.document_id = v_bad_mime_document_id;
    select count(*) into v_second_claimed
    from public.fn_claim_org_document_storage_cleanup(
        10, v_claim_token_b, v_org_a
    ) c
    where c.document_id = v_bad_mime_document_id;
    select public.fn_mark_org_document_storage_cleaned(
        array[v_bad_mime_document_id], v_claim_token_b
    ) into v_marked;
    if v_claimed <> 1 or v_second_claimed <> 0 or v_marked <> 0 then
        raise exception 'ARS-355: cleanup claim lease is not exclusive';
    end if;
    select public.fn_mark_org_document_storage_cleaned(
        array[v_bad_mime_document_id], v_claim_token_a
    ) into v_marked;
    if v_marked <> 1 or not exists (
        select 1 from public.org_documents d
        where d.id = v_bad_mime_document_id
          and d.storage_cleanup_at is not null
          and d.cleanup_claim_token is null
          and d.cleanup_claimed_at is null
    ) then
        raise exception 'ARS-355: acknowledged cleanup did not clear its lease';
    end if;

    -- Parent removal is blocked until a durable cleanup/cutover process removes
    -- registry rows, so Storage paths cannot silently become unrecoverable orphans.
    begin
        delete from public.organizations where id = v_org_a;
        raise exception 'ARS-355: organization deletion unexpectedly cascaded registry rows';
    exception
        when foreign_key_violation then null;
    end;
end;
$$;

rollback;
