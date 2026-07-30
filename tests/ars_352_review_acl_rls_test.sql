-- ARS-352 regression contract.
-- Run after supabase/migrations/20260730085800_ars_352_review_acl_rls.sql.

begin;

do $$
declare
    v_name text;
begin
    if not (
        select c.relrowsecurity
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = 'deal_review_dimension_scores'
    ) then
        raise exception 'ARS-352: deal_review_dimension_scores RLS is disabled';
    end if;

    if not exists (
        select 1
        from pg_policies
        where schemaname = 'public'
          and tablename = 'deal_review_dimension_scores'
          and policyname = 'deal_review_dimension_scores_read'
          and roles @> array['authenticated'::name]
          and cmd = 'SELECT'
    ) then
        raise exception 'ARS-352: authenticated dimension-score read policy missing';
    end if;

    if has_table_privilege('anon', 'public.deal_reviews', 'select')
       or has_table_privilege('anon', 'public.deal_review_dimension_scores', 'select') then
        raise exception 'ARS-352: anon can still read review tables';
    end if;

    if not has_table_privilege('authenticated', 'public.deal_reviews', 'select')
       or not has_table_privilege('authenticated', 'public.deal_review_dimension_scores', 'select') then
        raise exception 'ARS-352: authenticated review read grant missing';
    end if;

    if has_table_privilege('authenticated', 'public.deal_reviews', 'insert')
       or has_table_privilege('authenticated', 'public.deal_review_dimension_scores', 'insert') then
        raise exception 'ARS-352: authenticated can bypass review RPC with direct insert';
    end if;

    if has_function_privilege(
        'anon',
        'public.rpc_submit_deal_review(uuid,uuid,integer,uuid,integer,text)',
        'execute'
    ) then
        raise exception 'ARS-352: anon can still execute rpc_submit_deal_review';
    end if;

    if not has_function_privilege(
        'authenticated',
        'public.rpc_submit_deal_review(uuid,uuid,integer,uuid,integer,text)',
        'execute'
    ) then
        raise exception 'ARS-352: authenticated review RPC grant missing';
    end if;

    if not exists (
        select 1
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = 'rpc_submit_deal_review'
          and pg_get_function_identity_arguments(p.oid) =
              'p_organization_id uuid, p_batch_id uuid, p_overall_score integer, p_dimension_id uuid, p_dimension_score integer, p_comment text'
          and position('caller is not a member of organization' in pg_get_functiondef(p.oid)) > 0
          and position(
              'coalesce(p_organization_id = any(public.fn_my_org_ids()), false)'
              in lower(pg_get_functiondef(p.oid))
          ) > 0
    ) then
        raise exception 'ARS-352: NULL-safe caller-to-organization guard missing from review RPC';
    end if;

    foreach v_name in array array[
        'rpc_get_or_create_support_channel(uuid)',
        'rpc_send_message(uuid,text,jsonb)',
        'rpc_list_channels()',
        'rpc_list_messages(uuid,timestamp with time zone,integer)',
        'rpc_mark_channel_read(uuid)',
        'rpc_archive_channel(uuid)'
    ] loop
        if has_function_privilege('anon', 'public.' || v_name, 'execute') then
            raise exception 'ARS-352: anon can execute messaging entry point %', v_name;
        end if;
        if not has_function_privilege('authenticated', 'public.' || v_name, 'execute') then
            raise exception 'ARS-352: authenticated messaging grant missing for %', v_name;
        end if;
    end loop;

    if has_function_privilege(
        'authenticated',
        'public.fn_fanout_comm_notifications(uuid)',
        'execute'
    ) then
        raise exception 'ARS-352: internal notification fan-out helper is client-executable';
    end if;
end;
$$;

rollback;
