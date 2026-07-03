-- AgOS · Доводка аудита PR #20: privilege hardening админ-функций.
-- Функции из 20260629120000/130000/140000/150000 и 20260701130000/140000
-- создавались без revoke/grant — в отличие от TSP-паттерна проекта
-- (revoke ... from anon; grant ... to authenticated). Guard fn_is_admin()
-- в телах есть, утечки нет — это defense-in-depth.
--
-- Важно: у функций в public EXECUTE по умолчанию есть у PUBLIC (все роли,
-- включая anon, наследуют его), поэтому revoke только from anon путь через
-- PUBLIC не закрывает — отзываем from public, anon. service_role получает
-- явный grant (админ-вызовы из Edge Functions / сервисных скриптов).
--
-- Сигнатуры — последние актуальные версии (старые перегрузки уже дропнуты
-- в 20260629140000 и 20260701130000/140000). Идемпотентно: grant/revoke
-- повторяемы. Применять: Supabase Dashboard → SQL Editor.

-- ------------------------------------------------------------
-- Пользователи (20260629120000 / 130000 / 140000 / 150000)
-- ------------------------------------------------------------

-- rpc_admin_update_user — актуальная версия из 20260629150000
revoke execute on function public.rpc_admin_update_user(uuid, text, text, text, text, boolean, text) from public, anon;
grant  execute on function public.rpc_admin_update_user(uuid, text, text, text, text, boolean, text) to authenticated, service_role;

-- rpc_admin_list_farmer_mpk_users — 20260629120000
revoke execute on function public.rpc_admin_list_farmer_mpk_users(text) from public, anon;
grant  execute on function public.rpc_admin_list_farmer_mpk_users(text) to authenticated, service_role;

-- rpc_admin_delete_user — 20260629130000
revoke execute on function public.rpc_admin_delete_user(uuid) from public, anon;
grant  execute on function public.rpc_admin_delete_user(uuid) to authenticated, service_role;

-- rpc_admin_create_user — актуальная версия из 20260629150000
-- (7×text-перегрузка из 130000 дропнута в 140000)
revoke execute on function public.rpc_admin_create_user(text, text, uuid, text, text, text, text) from public, anon;
grant  execute on function public.rpc_admin_create_user(text, text, uuid, text, text, text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Организации (20260629140000 / 20260701130000 / 20260701140000)
-- ------------------------------------------------------------

-- rpc_admin_list_organizations — актуальная версия из 20260701140000
revoke execute on function public.rpc_admin_list_organizations(text) from public, anon;
grant  execute on function public.rpc_admin_list_organizations(text) to authenticated, service_role;

-- rpc_admin_create_organization — актуальная версия из 20260701140000
-- (7- и 8-арг перегрузки дропнуты там же)
revoke execute on function public.rpc_admin_create_organization(text, text, text, text, text, text, text, uuid, text) from public, anon;
grant  execute on function public.rpc_admin_create_organization(text, text, text, text, text, text, text, uuid, text) to authenticated, service_role;

-- rpc_admin_update_organization — актуальная версия из 20260701140000
-- (8- и 9-арг перегрузки дропнуты там же)
revoke execute on function public.rpc_admin_update_organization(uuid, text, text, text, text, text, text, boolean, uuid, text) from public, anon;
grant  execute on function public.rpc_admin_update_organization(uuid, text, text, text, text, text, text, boolean, uuid, text) to authenticated, service_role;

-- rpc_admin_delete_organization — 20260629140000
revoke execute on function public.rpc_admin_delete_organization(uuid) from public, anon;
grant  execute on function public.rpc_admin_delete_organization(uuid) to authenticated, service_role;

-- ------------------------------------------------------------
-- Хелперы
-- ------------------------------------------------------------

-- fn_normalize_phone_kz — 20260629150000; вызывается только изнутри
-- security definer админ-RPC (владелец postgres), grant authenticated —
-- на случай прямого использования из клиентских запросов.
revoke execute on function public.fn_normalize_phone_kz(text) from public, anon;
grant  execute on function public.fn_normalize_phone_kz(text) to authenticated, service_role;

-- fn_sync_org_district — 20260701140000; триггерная функция, напрямую
-- не вызывается (PostgREST функции returns trigger не экспонирует),
-- revoke — чтобы не светилась как исполняемая для anon.
revoke execute on function public.fn_sync_org_district() from public, anon;
grant  execute on function public.fn_sync_org_district() to authenticated, service_role;
