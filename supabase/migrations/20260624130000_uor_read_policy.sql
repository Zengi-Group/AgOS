-- AgOS · Фикс: у public.user_organization_roles включён RLS (d01_kernel.sql:1336),
-- но НЕ создано ни одной policy → клиент (включая админа) читает 0 строк из таблицы.
-- Это ломало админскую вкладку «Пользователи»: маппинг user→org (а значит «оплачено ли
-- членство») строится через user_organization_roles, и без SELECT-политики он всегда пуст.
--
-- Добавляем SELECT-политику по тому же паттерну, что и у соседних таблиц
-- (orgs_read_own / memberships_read_own): свои строки + админ + эксперт.
-- Применять в Supabase Dashboard → SQL Editor. Идемпотентно (drop policy if exists).

drop policy if exists "uor_read_own_admin" on public.user_organization_roles;

create policy "uor_read_own_admin"
    on public.user_organization_roles for select
    using (
        user_id = public.fn_current_user_id()
        or public.fn_is_admin()
        or public.fn_is_expert()
    );
