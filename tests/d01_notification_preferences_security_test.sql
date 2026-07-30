-- d01 post-replay regression contract: notification preferences must never retain
-- Supabase's broad default grants, and invitation audit FKs need covering indexes.

begin;

do $$
begin
    if not (
        select c.relrowsecurity
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = 'user_notification_preferences'
    ) then
        raise exception 'd01 security: user_notification_preferences RLS is disabled';
    end if;

    if has_table_privilege('anon', 'public.user_notification_preferences', 'select')
       or has_table_privilege('anon', 'public.user_notification_preferences', 'insert')
       or has_table_privilege('anon', 'public.user_notification_preferences', 'update')
       or has_table_privilege('anon', 'public.user_notification_preferences', 'delete') then
        raise exception 'd01 security: anon retains notification-preference privileges';
    end if;

    if not has_table_privilege(
        'authenticated', 'public.user_notification_preferences', 'select'
    ) or not has_table_privilege(
        'authenticated', 'public.user_notification_preferences', 'insert'
    ) or not has_table_privilege(
        'authenticated', 'public.user_notification_preferences', 'update'
    ) or not has_table_privilege(
        'authenticated', 'public.user_notification_preferences', 'delete'
    ) then
        raise exception 'd01 security: authenticated own-settings grants are incomplete';
    end if;

    if (
        select count(*)
        from pg_policies
        where schemaname = 'public'
          and tablename = 'user_notification_preferences'
          and policyname in (
              'notification_preferences_read_own',
              'notification_preferences_insert_own',
              'notification_preferences_update_own',
              'notification_preferences_delete_own'
          )
          and roles @> array['authenticated'::name]
    ) <> 4 then
        raise exception 'd01 security: expected four authenticated own-user policies';
    end if;

    if not exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_invitations'
          and indexname = 'idx_org_invitations_accepted_by_user'
    ) or not exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'org_invitations'
          and indexname = 'idx_org_invitations_created_by_user'
    ) then
        raise exception 'd01 performance: invitation user FK indexes are missing';
    end if;
end;
$$;

rollback;
