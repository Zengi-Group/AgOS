# 08 — Сквозные backend-прогоны (E2E-*)

> Формат: SQL rollback-tx (паттерн `tests/tsp_happy_path_test.sql`: полный прогон в
> транзакции с ROLLBACK — ноль мутаций, можно гнать на проде). Каждый сьют при успехе
> делает `RAISE 'XXX_TEST_PASS'`. Это основной слой автоматизации FSM-переходов.

---

#### E2E-TSP-01 · HAPPY · Полный happy-path партии
`layer:sql` `canon:MS4/MS6` `impl:tests/tsp_happy_path_test.sql` `auto:tests/tsp_happy_path_test.sql` `status:active`
- **Шаги:** `rpc_create_batch` (10 голов, 400 кг) → draft; `rpc_set_batch_terms` (1200 ₸/кг, окно +30…+60 дн) → draft; `rpc_publish_batch` → published/offering; `rpc_create_pool`+publish (broadcast) → offering + Offer(pending); accept_offer от МПК → matched; добор пула → auto-close → confirmed.
- **Ожидание:** `TSP_TEST_PASS`; транзакция откатывается.
- **Регресс-защита:** падение на publish_pool (батч застрял в published) или `INVALID_STATUS: batch is published` на accept = провал (регресс TSP-FLOW-01/03).

#### E2E-TSP-02 · HAPPY · Продолжение до delivered + reveal
`layer:sql` `canon:MS4-BT-16/18;D-M6-5` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Шаги:** …confirmed → reveal-render (`fn_tsp_batch_json` отдаёт buyer) → dispatch → dispatched → confirm_delivery → delivered.
- **Ожидание:** buyer виден только после confirmed; delivered терминален. (Уже доказан вручную rollback-tx 2026-06-24 — оформить постоянным сьютом.)

#### E2E-TSP-03 · UNHAPPY→OK · Цикл снижения цены
`layer:sql` `canon:MS4-BT-09/11;D-M6-3` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Шаги:** offering → истечение окна (симулировать сдвигом expires_at) → awaiting_price_decision → lower_price (−100) → offering → повторно до клэмпа на защитной цене.
- **Ожидание:** система не предлагает цену < пола; шаг из конфига.

#### E2E-TSP-04 · UNHAPPY→OK · Underfill: оба исхода
`layer:sql` `canon:MS4-§2.5;D-TSP-10;D-M6-14` `impl:d02_tsp.sql` `auto:candidate:sql` `status:blocked:TSP-FLOW-10`
- **Сценарий A:** window expired, filled<target → accept_partial → target=filled, партии confirmed.
- **Сценарий B:** return_batches (или дефолт по молчанию 24 ч) → партии published, deal_price=NULL, pool closed_unfilled.

#### E2E-TSP-05 · HAPPY · Scheduled-партия
`layer:sql` `canon:MS6-§3` `impl:d02_tsp.sql` `auto:candidate:sql` `status:blocked:TSP-FLOW-02`
- **Шаги:** publish с окном >7 дней → scheduled; симулировать наступление publish_at → джоб → matching → matched/offering/published.

#### E2E-TSP-06 · EDGE · Дробление: кусок = сделка
`layer:sql` `canon:DECISIONS_LOG:BATCH-SPLIT-01` `impl:d02 SECTION 9 batch_allocations` `auto:candidate:sql` `status:active`
- **Шаги:** партия 40 голов → пул со строкой max 15 → кусок 15 matched, партия partially_matched; второй пул → ещё кусок; отгрузка/приёмка per-кусок.
- **Ожидание:** статус батча = rollup «отстающего» куска; min-правило куска (≥5, остаток 0 или ≥5); confirmed-куски не отменяются фермером.

#### E2E-TSP-07 · EDGE · FCFS-гонка на accept
`layer:sql` `canon:MS4-§2.3` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Шаги:** два конкурентных accept одной партии (две сессии / advisory-free, SKIP LOCKED).
- **Ожидание:** ровно один matched; второй — ошибка; filled инкрементирован один раз.

#### E2E-MEM-01 · HAPPY · Членство: submit → approve → pay → active
`layer:sql` `canon:MS2-T1/T2/T4` `impl:d01_kernel.sql` `auto:candidate:sql` `status:active`
- **Шаги:** rpc_submit_membership_application → rpc_process_membership_application(approved) → rpc_pay_membership_dues.
- **Ожидание:** статусы по задеплоенной модели (pending → approved → active); гейт Рынка открывается (проверить `rpc_get_membership_status`).

#### E2E-MEM-02 · UNHAPPY · Членство: reject → resubmit
`layer:sql` `canon:MS2-T3;D-MEM-4` `impl:d01_kernel.sql` `auto:candidate:sql` `status:active`
- **Ожидание:** rejected не блокирует новую заявку; история заявок append-only.

#### E2E-MEM-03 · HAPPY · Канонический FSM T1–T10 полным циклом
`layer:sql` `canon:MS2-§3` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Ожидание:** после имплементации 6-state FSM — сьют по всем переходам, включая cron-таймауты (grace 30 дней, T5/T6/T8) и audit-trail. Приоритет №1 при закрытии долга.

#### E2E-REG-01 · HAPPY · Регистрация через bird-otp (стейджинг)
`layer:sql` `canon:code` `impl:supabase/functions/bird-otp` `auto:candidate:integration` `status:active`
- **Шаги:** send (мок Mobizon либо тестовый номер) → check → register → rpc_register_organization.
- **Ожидание:** созданы auth-пользователь, organizations, users.full_name; повторный register того же телефона → «уже зарегистрирован». Прогонять на staging (env scoping), не на проде — создаёт auth-записи, которые rollback-tx не покрывает.

#### E2E-FARM-01 · HAPPY · Узел 1: порог → генерация draft-ЦТК → читатель плана
`layer:sql` `canon:F-D11/F-D12/F-D14;D78` `impl:d05_ops_edu.sql;d07_ai_gateway.sql` `auto:candidate:sql` `status:active`
- **Шаги (rollback-tx):** ферма с записью в user_organization_roles; herd_groups += COW>0
  (`data_source='platform'`, confidence 75); `farms.calving_system='spring'` →
  `rpc_generate_plan_from_profile(org, farm, 3, actor)` → `rpc_get_production_plan(org, farm, 'any')`.
- **Ожидание:** `generated:true`, шаблон `BEEF_COW_CALF_KZ`, `cycle_start_date` = 1-е число
  месяца отёла (D78); читатель возвращает draft-план (`plan_id`/`plan_name`/`status='draft'`/
  даты + `phases[]`, каждая с `task_counts{total,completed,overdue}`). Транзакция откатывается.
- **Регресс-защита:** 42803 `aggregate function calls cannot be nested` в
  `rpc_get_production_plan` (FARM-01-bis, пофикшен ARS-215) — до фикса читатель падал на
  ЛЮБОМ существующем плане. Прогон 2026-07-11: PASS (15 фаз, первая «Туровые отёлы», 5 задач).
