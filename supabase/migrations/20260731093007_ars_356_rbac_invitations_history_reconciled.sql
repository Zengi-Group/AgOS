-- ARS-356 history reconciliation marker.
--
-- The canonical RBAC/invitation schema was previously provisioned through
-- d01_kernel.sql, without a discrete Supabase migration history entry. This
-- assertion-only marker records that verified baseline; it deliberately does
-- not recreate or alter the already-live schema.

do $$
begin
    if to_regclass('public.organization_permissions') is null
       or to_regclass('public.organization_role_permissions') is null
       or to_regclass('public.org_invitations') is null then
        raise exception 'ARS-356_HISTORY_RECONCILIATION: RBAC/invitation relations missing';
    end if;

    if not exists (
        select 1 from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = 'org_invitations'
          and c.relrowsecurity
    ) then
        raise exception 'ARS-356_HISTORY_RECONCILIATION: org_invitations RLS missing';
    end if;

    if to_regprocedure('public.fn_org_has_permission(uuid,text)') is null
       or to_regprocedure('public.rpc_create_org_invitation(uuid,text,text)') is null
       or to_regprocedure('public.rpc_resend_org_invitation(uuid,uuid)') is null
       or to_regprocedure('public.rpc_revoke_org_invitation(uuid,uuid)') is null
       or to_regprocedure('public.rpc_accept_org_invitation(text)') is null
       or to_regprocedure('public.rpc_list_org_invitations(uuid)') is null then
        raise exception 'ARS-356_HISTORY_RECONCILIATION: canonical function surface missing';
    end if;

    if not exists (
        select 1
        from public.organization_role_permissions rp
        join public.organization_permissions p
          on p.code = rp.permission_code and p.is_active
        where rp.permission_code = 'mpk.documents.manage'
          and rp.role in ('owner', 'manager', 'mpk_admin')
        group by rp.permission_code
        having count(distinct rp.role) = 3
    ) then
        raise exception 'ARS-356_HISTORY_RECONCILIATION: MPK document permission mapping missing';
    end if;

    if not exists (
        select 1
        from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_invitations'
          and indexname = 'uq_org_invitations_open_email'
    ) then
        raise exception 'ARS-356_HISTORY_RECONCILIATION: open invitation uniqueness index missing';
    end if;

    if exists (
        select 1
        from pg_class c
        cross join lateral aclexplode(
            coalesce(c.relacl, acldefault('r', c.relowner))
        ) as acl
        left join pg_roles grantee on grantee.oid = acl.grantee
        where c.oid = 'public.org_invitations'::regclass
          and (acl.grantee = 0 or grantee.rolname in ('authenticated', 'anon'))
          and acl.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    ) then
        raise exception 'ARS-356_HISTORY_RECONCILIATION: direct invitation table access exists';
    end if;
end;
$$;
