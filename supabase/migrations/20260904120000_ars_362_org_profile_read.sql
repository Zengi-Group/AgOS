-- ARS-362 / MP-2.1 · rpc_get_org_profile — read path for the MPK «Предприятие» tab.
-- Canonical home of this DDL: d01_kernel.sql (ARS-362 section). This migration is the
-- deploy vehicle only: d-files are applied first, supabase/migrations/ on top
-- (CLAUDE.md §Code Rules, TSP-ADAPTER-02). The body below is a byte-identical copy —
-- edit d01_kernel.sql and re-extract, never patch this file alone.
-- Spec: Docs/AGOS-MPK-Profile-ReadRPC-ARS-362.md


-- =============================================================================
-- ARS-362 / MP-2.1 — rpc_get_org_profile: the single self-read of the «Предприятие» tab.
-- Spec: Docs/AGOS-MPK-Profile-ReadRPC-ARS-362.md (frozen FR-001…FR-014 / M-001…M-012).
--
-- Why SECURITY DEFINER (ADR-MPK-CONVERGENCE-01 §8 requires a written reason):
-- mpk_profiles / mpk_sites / org_bank_accounts / org_field_reviews are revoked from
-- `authenticated` by ARS-359. The definer path reads them without reopening those grants,
-- so the dead SELECT policies stay ARS-358's problem (FR-011) instead of this slice's.
--
-- Additive (FR-007): no new tables, no new columns, no existing signature touched, the
-- ARS-359 writers are untouched. All needed indexes already exist (idx_org_bank_accounts_
-- org_current, org_bank_accounts_version_unique, idx_org_field_reviews_org_status,
-- uq_mpk_sites_active_primary) — no speculative index is added.
-- =============================================================================
create or replace function public.rpc_get_org_profile(
    p_organization_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_is_service        boolean := coalesce(auth.role(), '') = 'service_role';
    v_is_admin          boolean;
    v_can_edit          boolean;
    v_can_manage_bank   boolean;
    v_bank_read         boolean;
    v_org               public.organizations%rowtype;
    v_region_name       text;
    v_org_types         text[];
    v_profile           public.mpk_profiles%rowtype;
    v_has_profile       boolean := false;
    v_site              public.mpk_sites%rowtype;
    v_has_site          boolean := false;
    v_site_region_name  text;
    v_bank_current_id   uuid;
    v_bank_current      jsonb;
    v_bank_history      jsonb := '[]'::jsonb;
    v_pending           jsonb := '[]'::jsonb;
    v_resolved_recent   jsonb := '[]'::jsonb;
    v_resolved_total    int := 0;
begin
    -- M-005: no session → a typed authentication error, deliberately distinguishable from
    -- the access denial below. A service_role call carries no auth.uid() and is exempt.
    if public.fn_current_user_id() is null and not v_is_service then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;

    v_is_admin := public.fn_is_admin();

    -- FR-002 / M-004 / M-010: ownership is proven in the database. p_organization_id is an
    -- argument, never evidence (defect class VET-02).
    -- FR-003 / M-010: a null id, a foreign organization and a non-existent organization all
    -- raise the SAME error, so the answer never confirms that someone else's org exists.
    -- auth.role() is NULL when request.jwt.claims carries no role — coalesced above so an
    -- unauthenticated request cannot turn the whole predicate NULL (ARS-361 lesson).
    if p_organization_id is null
       or not (
           p_organization_id = any(coalesce(public.fn_my_org_ids(), array[]::uuid[]))
           or v_is_admin
           or v_is_service
       ) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    -- FR-004 / M-003: reading the bank sub-block needs mpk.bank.manage or admin — the same
    -- boundary the deployed policy org_bank_accounts_read_authorized draws. The rest of the
    -- section stays readable for every member.
    v_can_edit        := public.fn_org_has_permission(p_organization_id, 'mpk.profile.edit');
    v_can_manage_bank := public.fn_org_has_permission(p_organization_id, 'mpk.bank.manage');
    v_bank_read       := v_can_manage_bank or v_is_admin or v_is_service;

    -- FR-008 / M-011: everything below is data reading. Any failure in it leaves as a typed
    -- code plus a human-readable reason; the SQL exception text goes to the server log only.
    -- The 42501 guards above are outside this block and re-raise untouched.
    begin
        select o.* into v_org
          from public.organizations o
         where o.id = p_organization_id;
        if not found then
            -- Only an admin/service caller can arrive here (a member's org exists by
            -- definition). The identical denial keeps FR-003 whole.
            raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
                using errcode = '42501';
        end if;

        select rg.name_ru into v_region_name
          from public.regions rg
         where rg.id = v_org.region_id;

        -- M-009: org types travel with the payload so a non-MPK organization is recognised
        -- by the consumer instead of being refused — a 403 on type would promise a check
        -- this reader does not perform.
        select coalesce(array_agg(ota.org_type order by ota.org_type), array[]::text[])
          into v_org_types
          from public.organization_type_assignments ota
         where ota.organization_id = p_organization_id;

        -- M-002: an unfilled profile yields JSON null — distinguishable from the bank's
        -- explicit access flag, which is what «нет доступа» looks like.
        select mp.* into v_profile
          from public.mpk_profiles mp
         where mp.organization_id = p_organization_id;
        v_has_profile := found;

        select ms.* into v_site
          from public.mpk_sites ms
         where ms.organization_id = p_organization_id
           and ms.is_primary
           and ms.is_active
         limit 1;
        v_has_site := found;

        if v_has_site then
            select rg.name_ru into v_site_region_name
              from public.regions rg
             where rg.id = v_site.region_id;
        end if;

        if v_bank_read then
            -- FR-006 / M-007: the live version is resolved once and returned under its own
            -- key; the client never has to compute «which of these is current».
            select a.id into v_bank_current_id
              from public.org_bank_accounts a
             where a.organization_id = p_organization_id
               and a.valid_to is null
             order by a.is_primary desc, a.valid_from desc, a.version_no desc, a.id desc
             limit 1;

            select to_jsonb(cur) into v_bank_current
              from (
                select a.id as account_id, a.logical_account_id, a.version_no,
                       a.bank_name, a.bik, a.iban, a.account_holder_name,
                       a.currency_code, a.is_primary, a.valid_from, a.valid_to,
                       a.created_by_user_id, a.created_at
                  from public.org_bank_accounts a
                 where a.id = v_bank_current_id
              ) cur;

            -- Append-only history, newest version first. logical_account_id travels with
            -- each row: an org may hold several logical accounts, each with its own version
            -- ladder, and nothing is hidden or deleted.
            select coalesce(
                       jsonb_agg(
                           to_jsonb(hist)
                           order by hist.version_no desc, hist.valid_from desc, hist.id desc
                       ),
                       '[]'::jsonb
                   )
              into v_bank_history
              from (
                select a.id, a.id as account_id, a.logical_account_id, a.version_no,
                       a.supersedes_id, a.bank_name, a.bik, a.iban, a.account_holder_name,
                       a.currency_code, a.is_primary, a.valid_from, a.valid_to,
                       a.created_by_user_id, a.created_at
                  from public.org_bank_accounts a
                 where a.organization_id = p_organization_id
                   and (v_bank_current_id is null or a.id <> v_bank_current_id)
              ) hist;
        end if;

        -- FR-006 / M-006: pending proposals arrive under their own key with the previous and
        -- proposed values, the actor and the time. organizations.bin_iin above stays the
        -- production value — a pending bin_iin proposal never overwrites what is shown.
        select coalesce(
                   jsonb_agg(to_jsonb(pend) order by pend.requested_at desc, pend.id desc),
                   '[]'::jsonb
               )
          into v_pending
          from (
            select r.id, r.field_name, r.previous_value, r.proposed_value, r.status,
                   r.requested_by_user_id, r.requested_at
              from public.org_field_reviews r
             where r.organization_id = p_organization_id
               and r.status = 'pending'
          ) pend;

        -- FR-001: the payload stays bounded — the 20 newest resolved proposals plus a total,
        -- not the whole trail.
        select coalesce(
                   jsonb_agg(to_jsonb(res) order by res.reviewed_at desc, res.id desc),
                   '[]'::jsonb
               )
          into v_resolved_recent
          from (
            select r.id, r.field_name, r.previous_value, r.proposed_value, r.status,
                   r.requested_by_user_id, r.requested_at,
                   r.reviewed_by_user_id, r.reviewed_at, r.review_note,
                   r.production_value_applied_at
              from public.org_field_reviews r
             where r.organization_id = p_organization_id
               and r.status in ('approved', 'rejected')
             order by r.reviewed_at desc, r.id desc
             limit 20
          ) res;

        select count(*) into v_resolved_total
          from public.org_field_reviews r
         where r.organization_id = p_organization_id
           and r.status in ('approved', 'rejected');
    exception
        when insufficient_privilege then
            raise;
        when others then
            raise log 'ARS-362 rpc_get_org_profile read failed for organization %: % (%)',
                p_organization_id, sqlerrm, sqlstate;
            raise exception 'PROFILE_READ_FAILED'
                using errcode = 'P0001',
                      detail = 'Не удалось прочитать профиль организации. Повторите попытку.';
    end;

    -- Response contract. NOTE: no comment may sit between the arguments of
    -- jsonb_build_object below — scripts/contract_snapshot.py (cross_check CHECK 11) only
    -- recognises an argument that is exactly a quoted literal, so a comment in front of a
    -- key silently drops that key out of the snapshot. FR-005 names CHECK 11 as its own
    -- verification, so the comments live here instead:
    --   contract_version — FR-005, lets the consumer tell editions apart.
    --   bank.access      — FR-004 / M-003: an explicit 'denied' rather than a silently
    --                      missing block, so the screen shows the boundary.
    --   permissions      — effective WRITE rights, so the screen knows where it is
    --                      read-only. These are the permission checks the ARS-359 writers
    --                      actually perform: an admin without mpk.bank.manage may READ the
    --                      bank block yet still be refused by rpc_append_org_bank_account,
    --                      so promising 'editable' here would be a lie.
    --   The two dotted permission keys cannot be snapshotted at all (CHECK 11 reads
    --   [A-Za-z0-9_]+ only) — recorded in IMPL_DEBT as CONTRACT-SNAPSHOT-DOTTED-KEYS-01.
    return jsonb_build_object(
        'contract_version', 1,
        'organization', jsonb_build_object(
            'id', v_org.id,
            'legal_name', v_org.legal_name,
            'bin_iin', v_org.bin_iin,
            'legal_form', v_org.legal_form,
            'region_id', v_org.region_id,
            'region_name', v_region_name,
            'district_id', v_org.district_id,
            'address_text', v_org.address_text,
            'phone', v_org.phone,
            'email', v_org.email,
            'website', v_org.website,
            'head_full_name', v_org.head_full_name,
            'head_title', v_org.head_title,
            'is_active', v_org.is_active,
            'org_types', to_jsonb(v_org_types)
        ),
        'profile', case
            when v_has_profile then jsonb_build_object(
                'public_description', v_profile.public_description,
                'logo_path', v_profile.logo_path,
                'created_at', v_profile.created_at,
                'updated_at', v_profile.updated_at
            )
            else 'null'::jsonb
        end,
        'primary_site', case
            when v_has_site then jsonb_build_object(
                'id', v_site.id,
                'site_name', v_site.site_name,
                'region_id', v_site.region_id,
                'region_name', v_site_region_name,
                'address_text', v_site.address_text,
                'processing_capacity_heads_per_day', v_site.processing_capacity_heads_per_day,
                'phone', v_site.phone,
                'email', v_site.email,
                'is_primary', v_site.is_primary,
                'is_active', v_site.is_active,
                'created_at', v_site.created_at,
                'updated_at', v_site.updated_at
            )
            else 'null'::jsonb
        end,
        'bank', jsonb_build_object(
            'access', case when v_bank_read then 'granted' else 'denied' end,
            'current', case when v_bank_read then coalesce(v_bank_current, 'null'::jsonb)
                            else 'null'::jsonb end,
            'history', case when v_bank_read then v_bank_history else '[]'::jsonb end
        ),
        'field_reviews', jsonb_build_object(
            'pending', v_pending,
            'resolved_recent', v_resolved_recent,
            'resolved_total', v_resolved_total
        ),
        'permissions', jsonb_build_object(
            'mpk.profile.edit', v_can_edit,
            'mpk.bank.manage', v_can_manage_bank
        )
    );
end;
$$;

comment on function public.rpc_get_org_profile(uuid) is
    'ARS-362 / MP-2.1. Single bounded self-read for the MPK «Предприятие» tab: organization
     requisites, primary site, versioned bank details, field-review trail and the caller''s
     effective write permissions. Member/admin/trusted-service only; a null, foreign or
     non-existent organization gives one indistinguishable denial (FR-003). The bank
     sub-block needs mpk.bank.manage or admin and reports access explicitly instead of
     disappearing (FR-004). Reads only — no writes, no events (FR-013).';

revoke execute on function public.rpc_get_org_profile(uuid) from public, anon;
grant  execute on function public.rpc_get_org_profile(uuid) to authenticated, service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
    ('rpc_get_org_profile', 'rpc_get_org_profile', '20260904120000_ars_362_org_profile_read.sql', 'ARS-362 MP-2.1 bounded self-read of the MPK organization profile (org/site/bank/field-reviews/permissions)')
on conflict (sql_name) do update
set notes = excluded.notes,
    created_in = excluded.created_in,
    status = 'active';
