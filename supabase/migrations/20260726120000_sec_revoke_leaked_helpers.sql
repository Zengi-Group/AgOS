-- SEC: re-assert canon ACL for 5 leaked internal helpers (process-audit 2026-07-26).
--
-- prod_diff (2026-07-26) нашёл: канон отзывает execute у этих 5 функций, а на проде
-- anon/authenticated его имеют (revoke-строки в d07/chunk_dispatch не долились при
-- ручных psql-деплоях). Классификация по гейту: у всех 5 НЕТ ownership-гейта в теле
-- И они ПИШУТ (Trap 2b, класс SEC-NORMS-UPSERT-01). Самая опасная — fn_tsp_alloc_chunk
-- (ядро сделок TSP, p_created_by спуфится, вызывалась любым authenticated в обход
-- guarded rpc_self_*).
--
-- Почему revoke безопасен (урок ARS-311 — сверка вызывающих ДО revoke):
--   * embedding claim/complete/fail: легитимный вызывающий = AI-gateway ролью
--     service_role (P-AI-6) — грант service_role СОХРАНЯЕТСЯ (строки ниже, идемпотентно);
--   * fn_tsp_alloc_chunk / fn_tsp_rollup_batch_status: вызываются только из SECURITY
--     DEFINER rpc_self_* (исполняются от owner) — owner execute не зависит от этих грантов.
--
-- ACL-only: НИ ОДНОГО create or replace — тела прода не трогаются (у d07/chunk_dispatch
-- есть body-drift, полный реплей файлов опасен; здесь только права). Идемпотентно.
--
-- ⚠ Trap 2b (пойман верификацией прода 2026-07-26): канон d07/chunk_dispatch отзывает
-- `from anon, authenticated`, но НЕ от `public`. Supabase грантит execute роли PUBLIC
-- по умолчанию, а anon/authenticated — её члены → revoke без `from public` НЕ закрывает
-- доступ (has_function_privilege('anon',…) остаётся true). Поэтому здесь revoke ВКЛЮЧАЕТ
-- public — это исправление неполной формулировки канона. Миграция по timestamp ложится
-- последней (после d07 и chunk_dispatch), поэтому финальное состояние корректно даже
-- при полном реплее — d07/chunk_dispatch править не нужно.

-- AI embedding queue (service_role — воркер шлюза; клиентам не нужно)
grant  execute on function public.claim_embedding_batch(int, text)      to service_role;
grant  execute on function public.complete_embedding_job(uuid, vector)  to service_role;
grant  execute on function public.fail_embedding_job(uuid, text)        to service_role;
revoke execute on function public.claim_embedding_batch(int, text)      from public, anon, authenticated;
revoke execute on function public.complete_embedding_job(uuid, vector)  from public, anon, authenticated;
revoke execute on function public.fail_embedding_job(uuid, text)        from public, anon, authenticated;

-- TSP internal helpers (вызываются только из SECURITY DEFINER rpc_self_*)
revoke execute on function public.fn_tsp_alloc_chunk(uuid, uuid, text, uuid, int, int) from public, anon, authenticated;
revoke execute on function public.fn_tsp_rollup_batch_status(uuid)                      from public, anon, authenticated;
