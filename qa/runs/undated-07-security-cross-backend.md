# Прогон 07-security-cross (backend-слой: sql/rpc/e2e) — undated

Окружение: staging (REST-режим, service_role + anon+JWT тестового пользователя), коммит b7b8cf4
Область: только кейсы с layer ∈ {sql, rpc, e2e} — чистый ui / ui+rpc отданы UI-волне (SEC-GATE-04, SEC-RVL-04, SEC-ART-01, SEC-ART-03, SEC-MISC-01 — НЕ прогонялись здесь). SEC-RVL-01/02, SEC-ART-04 (rpc+ui / ui+rpc) — прогнан только rpc/данные-слой.
Конфиги: tsp_config.offer_window_hours=24 (default при отсутствии), лимит партий — в конфиге отсутствует (нет поля).

Итог: PASS 6 / FAIL 5 / PARTIAL 1 / SKIP 0 (из 12 backend-кейсов файла)

| ID | Вердикт | Evidence / причина |
|---|---|---|
| SEC-GATE-01 | **FAIL** | rpc_create_batch не имеет membership-гейта. Эмпирика: аутентиф. QA-пользователь (без членства) создал draft-партию для QA-org без строки в `memberships` → `{"status":"draft","batch_id":...}`. В теле функции (d07:1133) только `_ai_check_farm_org` + health-gate, проверки членства НЕТ. Не в IMPL_DEBT → находка. |
| SEC-GATE-02 | **FAIL** | Лимита партий на RPC нет вообще. Эмпирика: через rpc_create_batch создано 7 draft-партий подряд, ни одна не отклонена (FEATURE_LIMIT не срабатывает); в коде нет ни count(batches), ни лимита. Конфиг: поля лимита в `tsp_config` нет. Не в IMPL_DEBT → находка. |
| SEC-GATE-03 | PASS | rpc_get_membership_queue под не-админом → `P0001 FORBIDDEN: admin access required`. rpc_process_membership_application — тот же guard `fn_is_admin()` (d01:4305, статически). fn_is_admin: JWT fast-path + DB fallback admin_roles. |
| SEC-RLS-01 | **FAIL** (critical) | SECURITY DEFINER self-RPC доверяют параметру `p_organization_id` и НЕ сверяют его с `fn_my_org_ids()`. Эмпирика: QA-пользователь A (не член org B) вызвал `rpc_cancel_batch(org_B, batch_B)` → `true`, партия B стала `cancelled` с причиной атакующего. Класс касается rpc_create/publish/cancel/lower_price/get_org_batches. Табличный RLS (`batches_read_own`) при этом работает (прямой SELECT batches под чужим JWT → []). Не в IMPL_DEBT → находка. |
| SEC-RLS-02 | PASS | Табличная изоляция МПК: под чужим JWT `pool_requests`→[], `offers`→[], `pool_lines`→[] (offers/pool_lines: RLS enabled, политик нет → deny-all для не-service). service_role видит данные (baseline). Прим.: rpc-класс param-trust из SEC-RLS-01 симметрично применим к pool self-RPC — покрыт находкой SEC-RLS-01. |
| SEC-RLS-03 | **FAIL** (critical) | Bucket `membership-documents` (private) НЕ изолирован по orgId. Эмпирика: QA-пользователь A (аутентиф., без членства в какой-либо org) через Storage API: (1) листинг корня — перечислены папки всех org (UUID); (2) листинг внутри чужой папки `{orgId}/docs` — виден `bank_details_...png`, `identity_document_...jpg`; (3) **скачивание чужого файла bank_details (476 КБ) → HTTP 200**. Полная кросс-org утечка банковских/идентификационных документов. Не в IMPL_DEBT → находка (critical). |
| SEC-RVL-01 | PASS | fn_tsp_batch_json (migration 20260702170000) отдаёт `buyer`/`buyerPhone` только `case when mpk_contact_revealed_at is not null then ... else null` — и на уровне batch (L55-56), и per-кусок allocations (L47-48). rpc/данные-слой соответствует канону (D-M6-5). UI-половина — за UI-волной. |
| SEC-RVL-02 | PARTIAL | Идентичность фермера скрыта на данных-слое: batches/organizations не читаемы МПК кросс-org (RLS), offers не несёт legal_name фермера; раскрытие симметрично через mpk_contact_revealed_at. НО «анонимная репутация ★» до confirmed НЕ реализована — документированный TODO (migration 20260622120000:1675 «Анонимная репутация (★) — TODO (нет агрегата)»). Полный MPK-view (ui) — за UI-волной. |
| SEC-RVL-03 | PASS | Оба пути раскрытия ставят `mpk_contact_revealed_at`: canon `rpc_accept_offer` auto-close (d02:2849, фикс TSP-FLOW-07) и adapter-путь через общий аллокатор `fn_tsp_alloc_chunk` при closed_filled→confirmed (migration 20260702160000:76-77), которым пользуются и rpc_self_auto_match_batch, и rpc_self_accept_offer. Регресс-защита на месте. |
| SEC-ART-02 | PASS | deal_price_per_kg ставится только из цены сделки: canon accept `= v_pool_line.pl_price` (MPK-бид, d02:2822), аллокатор — из цены строки/оффера (`null = бид строки`). `reference_price_at_match` в pool_matches — только аудит-снимок (d02:380, «preserved if price_grid changes»), в deal_price никогда не попадает. |
| SEC-ART-04 | PASS | Горизонтальная ценовая информация недоступна: `offers` и `pool_lines` под чужим JWT → [] (RLS enabled, deny-all для не-service). Оффер чужого МПК и его цена не читаются ни в таблице, ни (следствие SEC-RLS-02) кросс-org. |
| SEC-MISC-02 | **FAIL** | Антигейт самосделки отсутствует. В матчинге (`rpc_self_auto_match_batch` L465-477, broadcast `eligible_mpks` L500-517, `rpc_self_accept_offer`, `fn_tsp_alloc_chunk`) нет условия `pool.organization_id <> batch.organization_id` / `mpk_org_id <> batch.organization_id`. Мульти-тип org (farmer+mpk) может сматчить свою партию в свой же пул. Статически подтверждено (полная эмпирика требует развёртывания пула — не выполнялась). Не в IMPL_DEBT → находка. |

## Находки (кандидаты в дефекты / IMPL_DEBT)

- **SEC-STORAGE-01 (critical, эмпирика):** bucket `membership-documents` отдаёт листинг и **скачивание** документов любой org любому аутентифицированному пользователю (проверено: чужой bank_details.png → HTTP 200). Нарушение «Data Isolation» и P-AI-2. Нужна storage-политика с проверкой orgId по `fn_my_org_ids()`/членству. (SEC-RLS-03)
- **SEC-RPC-ORGTRUST-01 (critical, эмпирика):** SECURITY DEFINER self-RPC TSP (`rpc_cancel_batch`, `rpc_create_batch`, `rpc_publish_batch`, `rpc_lower_batch_price`, `rpc_get_org_batches`) принимают `p_organization_id` параметром и не сверяют его с `fn_my_org_ids()` → кросс-org мутация/создание любым аутентиф. пользователем (проверено на cancel/create). Табличный RLS их не защищает (DEFINER его обходит). Нужен guard `if not (p_organization_id = any(fn_my_org_ids()) or fn_is_admin()) then raise FORBIDDEN`. (SEC-RLS-01, SEC-GATE-01)
- **SEC-GATE-MEMBERSHIP-01 (эмпирика):** rpc_create_batch/rpc_publish_batch без backend membership-гейта — не-член публикует партию. (SEC-GATE-01)
- **SEC-GATE-LIMIT-01 (эмпирика):** лимит активных партий на RPC отсутствует (создано 7 подряд); поля лимита в tsp_config нет. (SEC-GATE-02)
- **SEC-SELFDEAL-01 (статика):** матчинг не исключает самосделку (org продавец=покупатель в одном пуле). (SEC-MISC-02)
- **BUG-GETORGBATCHES-01 (эмпирика):** `rpc_get_org_batches` ссылается на `ts.description_ru`, которой нет в `tsp_skus` (колонки: sku_code, grade_id, breed_group...) → RPC всегда падает `42703 column ts.description_ru does not exist` (и для anon, и для authenticated). d07:1103. Функционально сломан; косвенно «fail-closed» для утечки, но это баг.
- **NOTE-ANON-EXEC-01 (эмпирика):** anon достаёт до тела rpc_get_org_batches (получен SQL-ошибка, а не permission denied) → на staging EXECUTE у anon не отозван, хотя репо содержит `revoke execute ... from anon` (d07:1344). Deployed БД отстаёт от репо; частично противоречит формулировке SEC-GATE-03 «EXECUTE отозван у public/anon».

## Предложения по кейсам (устаревшие ожидания, смена status)

- SEC-GATE-01/02, SEC-RLS-01, SEC-RLS-03, SEC-MISC-02: ожидания = канон, код расходится и долг НЕ зарегистрирован → завести строки в IMPL_DEBT (по CLAUDE.md: конфликт флагуется). После регистрации кейсы перевести в `blocked:<DEBT-ID>` до фикса.
- SEC-RVL-02: уточнить ожидание — «анонимная репутация ★» помечена TODO в коде; либо снять из ожидания, либо статус `blocked` до реализации агрегата.

## Дисциплина зачистки

Все QA-артефакты (auth-пользователь qa-sec-crossread@qa.local, QA-SEC-ORG-B, QA-SEC-FARM-B, 8 QA-партий, связанные batch_events/platform_events/audit_log) удалены; финальная проверка: org=[], user=User not found. Реальные данные staging не мутировались (кросс-org cancel применялся только к QA-партии).
