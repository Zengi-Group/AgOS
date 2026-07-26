-- AgOS · SEC · Trap 2b систем-фикс: revoke ... from anon без public не закрывает
-- доступ (Supabase грантит execute PUBLIC по умолчанию всем новым функциям;
-- anon/authenticated — члены роли PUBLIC → execute остаётся у обеих).
--
-- Контекст (аудит прод-дрейфа 2026-07-26, продолжение PR #157): authoritative
-- прогон scripts/prod_diff.py после деплоя PR #157 + 20260703120000_admin_rpc_
-- revoke_anon.sql показал 79 сигнатур (80 строк ролей anon/authenticated),
-- у которых канон явно "revoke ... from anon[, authenticated]", но PUBLIC-грант
-- остался — функция реально anon-исполнима на проде.
--
-- Триаж (механический: grep тела на fn_is_admin()/fn_my_org_ids()/auth.uid()/
-- FORBIDDEN-паттерн + ручная проверка 18 "негейченых" + фронт-сверка 12 read-RPC
-- через Explore-агент): ни одна из 79 не имеет легитимного anon-сценария
-- (публичного лендинга/маркетингового просмотра) — все либо гейтятся org/admin-
-- проверкой в теле (defense-in-depth, ~61), либо предназначены ТОЛЬКО для
-- service_role/backend (rpc_get_user_phone, rpc_get_treatment_protocols,
-- rpc_get_aggregated_demand/supply, rpc_get_price_grid, rpc_search_knowledge_
-- chunks, fn_auth_custom_claims, publish_platform_event и др. AI-Gateway/DEF-013
-- инструменты — P-AI-6, вызываются исключительно через service_role, ни разу
-- не найдены в src/ ни на одном anon-доступном роуте). rpc_get_user_phone —
-- PII (телефон пользователя), сейчас реально читаема anon/authenticated ролью
-- на проде без какого-либо org-гейта в теле (полагается целиком на ACL) — самая
-- серьёзная позиция в этом наборе.
--
-- Действие: ноль create-or-replace. Только revoke ... from public добавлен
-- к уже существующим (но неполным) revoke-строкам канона. Точечные правки тех
-- же строк внесены и в сами канон-файлы (d02/d05/d07 + 15 TSP/admin-миграций)
-- этим же коммитом — чтобы будущий deploy.py --all не воскрешал дыру повторно.
-- Идемпотентно, обратимо (grant ролям не менялся, только revoke ужесточён).
--
-- Отдельно: rpc_admin_create_user(text,text,text,text,text) — легаси 5-arg
-- overload (канон уже дропнул её в пользу 7-arg версии, "перегрузка дропнута
-- в 20260629140000" по комментариям канона), но DROP на проде до сих пор не
-- выполнен → сигнатура жива и anon-доступна. Revoke здесь как контейнмент;
-- решение "дропнуть ли overload целиком" — отдельный тикет (Слайс D overload
-- class, см. IMPL_DEBT).

revoke execute on function public.fn_activity_to_farm_type(text) from public, anon;
revoke execute on function public.fn_auth_custom_claims(jsonb) from public, anon, authenticated;
revoke execute on function public.fn_derive_farm_archetype(uuid) from public, anon;
revoke execute on function public.fn_tsp_breed_match(text,text) from public, anon;
revoke execute on function public.fn_tsp_district_match(text[],uuid) from public, anon;
revoke execute on function public.fn_tsp_grade_id_from_fatness(text) from public, anon;
revoke execute on function public.fn_tsp_norm_breed(text) from public, anon;
revoke execute on function public.fn_tsp_region_match(uuid[],uuid,uuid) from public, anon;
revoke execute on function public.publish_platform_event(text,uuid,uuid,jsonb) from public, anon, authenticated;
revoke execute on function public.rpc_add_batch_animal(uuid,uuid,text,numeric,text,integer,text,integer) from public, anon;
revoke execute on function public.rpc_add_batch_media(uuid,uuid,text,text,integer) from public, anon;
revoke execute on function public.rpc_add_vet_symptoms(uuid,uuid,jsonb,uuid,jsonb) from public, anon;
revoke execute on function public.rpc_admin_advance_pool_status(uuid,text) from public, anon;
revoke execute on function public.rpc_admin_cancel_batch(uuid,text) from public, anon;
revoke execute on function public.rpc_admin_cancel_pool(uuid,text) from public, anon;
revoke execute on function public.rpc_admin_edit_pool(uuid,date,date,jsonb) from public, anon;
revoke execute on function public.rpc_admin_match_batch_to_pool(uuid,uuid,integer) from public, anon;
revoke execute on function public.rpc_admin_set_batch_terms(uuid,integer,date,date) from public, anon;
revoke execute on function public.rpc_admin_tsp_batches() from public, anon;
revoke execute on function public.rpc_admin_tsp_deals() from public, anon;
revoke execute on function public.rpc_admin_tsp_pools() from public, anon;
revoke execute on function public.rpc_admin_unmatch(uuid,uuid,text) from public, anon;
revoke execute on function public.rpc_admin_upsert_grade_formula(text,text,text,integer,integer,text[],integer,integer) from public, anon;
-- легаси overload (см. header) — containment, не полный фикс класса overload
revoke execute on function public.rpc_admin_create_user(text,text,text,text,text) from public, anon;
revoke execute on function public.rpc_cancel_batch(uuid) from public, anon;
revoke execute on function public.rpc_cancel_batch(uuid,uuid,text) from public, anon;
revoke execute on function public.rpc_clear_confirmation(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.rpc_complete_farm_task(uuid,uuid,text,jsonb,uuid,jsonb) from public, anon;
revoke execute on function public.rpc_complete_vaccination_item(uuid,uuid,uuid,integer,text,text,uuid,jsonb) from public, anon;
revoke execute on function public.rpc_create_batch(text,text,integer,numeric,integer,text,text,numeric,date,date,boolean) from public, anon;
revoke execute on function public.rpc_create_batch(uuid,uuid,uuid,integer,numeric,date,uuid,uuid,text,uuid,jsonb) from public, anon, authenticated;
revoke execute on function public.rpc_create_consultation_request(uuid,text,text,text,uuid,text,uuid,jsonb) from public, anon;
revoke execute on function public.rpc_create_vet_case(uuid,uuid,text,text,uuid,integer,text,uuid,jsonb) from public, anon;
revoke execute on function public.rpc_dispatch_batch(uuid) from public, anon;
revoke execute on function public.rpc_generate_plan_from_profile(uuid,uuid,integer,uuid) from public, anon;
revoke execute on function public.rpc_get_aggregated_demand(uuid,date,uuid,integer) from public, anon;
revoke execute on function public.rpc_get_aggregated_supply(uuid,date,uuid,integer) from public, anon;
revoke execute on function public.rpc_get_ai_farm_context(uuid,uuid) from public, anon;
revoke execute on function public.rpc_get_conversation_state(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.rpc_get_demand_board(uuid,uuid) from public, anon;
revoke execute on function public.rpc_get_farm_tasks(uuid,uuid,integer,text) from public, anon;
revoke execute on function public.rpc_get_feeding_plan(uuid,uuid,uuid) from public, anon;
revoke execute on function public.rpc_get_grade_formula() from public, anon;
revoke execute on function public.rpc_get_incoming_offers() from public, anon;
revoke execute on function public.rpc_get_market_batches(text) from public, anon;
revoke execute on function public.rpc_get_my_pools() from public, anon;
revoke execute on function public.rpc_get_org_batches() from public, anon;
revoke execute on function public.rpc_get_org_batches(uuid,text) from public, anon, authenticated;
revoke execute on function public.rpc_get_pool_matches(uuid) from public, anon;
revoke execute on function public.rpc_get_price_grid(uuid,uuid,date) from public, anon;
revoke execute on function public.rpc_get_production_plan(uuid,uuid,text) from public, anon;
revoke execute on function public.rpc_get_treatment_protocols(uuid,uuid,text) from public, anon;
-- rpc_get_user_phone — PII (телефон), сейчас БЕЗ org-гейта в теле (полагается
-- на ACL целиком) — самый серьёзный leak в этом наборе, см. header.
revoke execute on function public.rpc_get_user_phone(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.rpc_get_vaccination_schedule(uuid,uuid,integer) from public, anon;
revoke execute on function public.rpc_get_vet_diagnosis(uuid,uuid,integer) from public, anon;
revoke execute on function public.rpc_lower_price(uuid,numeric) from public, anon;
revoke execute on function public.rpc_publish_batch(uuid,uuid,uuid,jsonb) from public, anon, authenticated;
revoke execute on function public.rpc_remove_batch_animal(uuid,uuid) from public, anon;
revoke execute on function public.rpc_remove_batch_media(uuid,uuid) from public, anon;
revoke execute on function public.rpc_search_knowledge_chunks(uuid,text,vector,text,text,integer) from public, anon;
revoke execute on function public.rpc_self_accept_offer(uuid) from public, anon;
revoke execute on function public.rpc_self_activate_pool_request(uuid) from public, anon;
revoke execute on function public.rpc_self_advance_pool_status(uuid,text) from public, anon;
revoke execute on function public.rpc_self_auto_match_batch(uuid) from public, anon;
revoke execute on function public.rpc_self_close_due_pools() from public, anon;
revoke execute on function public.rpc_self_confirm_delivery(uuid) from public, anon;
revoke execute on function public.rpc_self_confirm_delivery_alloc(uuid) from public, anon;
revoke execute on function public.rpc_self_create_pool_request(uuid,integer,date,uuid,jsonb,text,uuid[],text[]) from public, anon;
revoke execute on function public.rpc_self_dispatch_ready(uuid) from public, anon;
revoke execute on function public.rpc_self_match_batch_to_pool(uuid,uuid,integer,integer) from public, anon;
revoke execute on function public.rpc_self_reject_offer(uuid) from public, anon;
revoke execute on function public.rpc_self_review_due_batches() from public, anon;
revoke execute on function public.rpc_self_submit_mpk_review(uuid,integer,integer,text) from public, anon;
revoke execute on function public.rpc_self_withdraw_batch(uuid,boolean) from public, anon;
revoke execute on function public.rpc_submit_review(uuid,integer,integer,text) from public, anon;
revoke execute on function public.rpc_sync_conversation_role(uuid,uuid,text) from public, anon, authenticated;
revoke execute on function public.rpc_update_batch_animal(uuid,uuid,text,numeric,text,integer,text) from public, anon;
revoke execute on function public.rpc_update_conversation_language(uuid,text,uuid) from public, anon;
revoke execute on function public.rpc_update_price(uuid,numeric) from public, anon;
revoke execute on function public.rpc_upsert_herd_group(uuid,uuid,text,integer,numeric,uuid,uuid,uuid,jsonb,text) from public, anon;
