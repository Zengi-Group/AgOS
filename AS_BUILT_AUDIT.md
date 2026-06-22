# AS-BUILT AUDIT — TSP domain (READ-ONLY)

> ⚠️ **SUPERSEDED 2026-06-15.** This is the pre-M4 baseline snapshot @ `d1807e0` only. M4+M6 were deployed 2026-06-15 (commits `3415f64`..`0450823`); `offers`, `pool_lines`, `pool_regions`, `deal_reviews` now exist. Do not read as current state. Current drift map: `DOC_DRIFT_AUDIT-2026-06-22.md`.

**Дата:** 2026-06-04
**Branch:** `main` @ `d1807e0` (= origin/main)
**Целевая БД:** Supabase project `mwtbozflyldcadypherr` (AgOS, ACTIVE_HEALTHY, PG 17.6)
**Режим:** инспекция, без изменений. Ни одна миграция не применена, ни один файл кода не правлен, коммитов не было.

---

## Раздел 0 — Применённое состояние БД (одной строкой)

> **до-M4 baseline** (TSP в варианте «pool_request + pool_match + tsp_sku + target_month»). Ни M4, ни M6 не применены: на стороне БД отсутствуют `offers`, `pool_lines`, `pool_regions`, `deal_reviews`, `review_dimensions`, `deal_review_dimension_scores`. Последняя применённая миграция — `20260505073124__phone_auth_migration`.

Применённые миграции (по `supabase_migrations.schema_migrations`, 38 строк):

```
d01_p1..p6              (d01_kernel.sql)
d02_tsp                 (d02_tsp.sql)
d03_feed
d04_vet
d05_ops_edu
d07_pre_health_restrictions_is_active
d07_ai_gateway_part1..part4
d08_epidemic
slice1_*                (created_via_cabinet, severity_nullable)
slice2_*                (membership_rpcs + fixes)
expert_console_read_rpcs
d09_consulting_tables + d09_consulting_rpcs
slice8_feed_consumption_norms_and_rpcs
fix_feed_price_updated_by_fk
add_economic_parameters_to_consulting_reference_data
taxonomy_adranimal01_m1_m2_m3a_m4_m5         ← это TAXONOMY-M, не TSP-M4
ration_v2_pasture_season_params
adr_capex_02_null_preserve_and_list_surcharges
adr_prices_01_livestock_sale_prices
td1_memberships_constraint_idempotent
d10_public_site
d11_norms_table_and_rpcs
create_otp_codes
create_get_user_id_by_email
phone_auth_migration                         ← последняя, 2026-05-05
```

> Внимание: `taxonomy_adranimal01_m1_m2_m3a_m4_m5` — это M-стадии **ADR-ANIMAL-01 (таксономия)**, не TSP-микрошаги. К TSP-M4 отношения не имеет.

Cross_check.sh: **8/8 OK, 0 critical / 0 significant / 0 minor**. Гейт зелёный.

---

## Раздел 1 — Сущности TSP (as-built vs. target M4+M6)

«Целевая M4+M6» — модель, описанная в задании; не сверяется ни с одним документом — это эталон сравнения, заданный CEO.

| Сущность | Есть в БД | As-built (FSM / ключевые колонки) | Целевая M4+M6 | Дельта | Риск по P7 |
|---|---|---|---|---|---|
| `batches` | ✅ | FSM = `draft → published → matched \| cancelled \| expired` (5 состояний). Колонки: `tsp_sku_id`, `breed_id`, `heads`, `avg_weight_kg`, `target_month` (date), `region_id`, `grade_standard_id`, `notes`, `rollback_*`, `expires_at`, `published_at`, `matched_at`, `cancelled_at` | FSM 11 состояний: `draft / scheduled / published / offering / awaiting_price_decision / matched / confirmed / dispatched / delivered / cancelled / failed`. Колонки: `ready_from`, `ready_to` (заменяют `target_month`), `farmer_price`, `deal_price`, `pool_line_id`, `classifier_version`, `category_id`, `rayon/region`. `tsp_sku_id` → DEPRECATED как primary | + 7 новых статусов; `target_month` → `ready_from/ready_to`; +6 новых колонок; `tsp_sku_id` теряет primary-роль | **Ломающее**: расширение CHECK-констрейнта status — аддитивно. Удаление `target_month` — НЕ аддитивно (P7-violation, нужен 2-фазный путь: добавить ready_from/ready_to, бэкфилл, переключить writers, потом deprecate колонку) |
| `pool_requests` | ✅ | FSM = `draft → active → closed \| expired`. Колонки: `total_heads`, `target_month`, `region_id`, `accepted_categories` jsonb, `premium_bulls/heifers/cows`, `closed_*`, `activated_at` | **DEPRECATED** целиком (заменяется `pool` + `pool_line` multi-category) | Удаление сущности | **Ломающее**: P7 запрещает удалять. Путь: помечать `is_deprecated`/`status='archived'`, остановить writers, читатели перевести на новую модель, физическое удаление — только после миграции данных |
| `pools` | ✅ | FSM = `filling → filled → executing → dispatched → delivered → executed \| closed` (7 состояний). Колонки: `pool_request_id` (UNIQUE FK), `matched_heads`, `target_heads`, `execution_result`, `mpk_contact_revealed_at`, `filling_deadline`, `filled_at`, `executing_at`, `executed_at`, `closed_at` | FSM 9 состояний: `filling / awaiting_mpk_decision / closed_filled / closed_partial / closed_unfilled / executing / completed / cancelled / expired_empty`. Колонки: `total_target_volume`, `delivery_from`, `delivery_to`. **Раскрытие контакта на `confirmed`** (batch-side), не на `executing` (pool-side) | Из 7 текущих состояний с целевыми пересекаются только 2 имени (`filling`, `executing`). 5 состояний переименовываются/удаляются. `pool_request_id` теряет смысл (нет requests). Семантика `mpk_contact_revealed_at` смещается | **Ломающее**: смена CHECK status целиком. Любой запрос с `WHERE status='filled'` сломается. Аддитивный путь: завести новый столбец `status_v2` + двойная запись, дождаться миграции читателей |
| `pool_matches` | ✅ | Junction Pool↔Batch. Колонки: `pool_id`, `batch_id`, `matched_heads`, `reference_price_at_match`, `premium_at_match`, `grade_at_match`, `tsp_sku_at_match`, `matched_by`, `matched_at` | **DEPRECATED** целиком (заменяется через `pool_line` + `offer` flow) | Удаление сущности | **Ломающее**, аналогично `pool_requests`. Используется в `delivery_records.pool_match_id` (FK!). Удаление каскадом обрушит delivery_records |
| `delivery_records` | ✅ | Колонки: `pool_match_id` (NOT NULL FK), `planned_heads`, `actual_heads`, `actual_*`, `status`, `is_disputed`, `delivery_date` | Сохраняется, но `pool_match_id` → `pool_line_id` (или `offer_id`) | Смена FK | **Ломающее**: NOT NULL FK на удаляемой таблице. Нужен путь: добавить новый FK nullable, бэкфилл, switch writers, drop старый FK, set NOT NULL |
| `pool_manifests` | ✅ | Колонки: `pool_id`, `document_url`, `version`, `generated_at`, `is_current` | Вероятно сохраняется | Нет дельты на as-built уровне | Безопасно |
| `tsp_skus` | ✅ | Reference, 30 SKU из `TSP-Ассортимент-КРС-v2.xlsx`. Колонки: `code`, `name_ru`, `weight_min/max_kg`, `available`, `sort_order` и др. | Сохраняется как справочник, но теряет primary-роль в `batches` (заменяется `category_id` + классификатором) | Семантическая, не структурная | Аддитивно, если оставить таблицу как lookup |
| `grade_standards`, `valid_sku_combinations`, `weight_classes`, `price_index_methodologies` | ✅ | Reference | Сохраняются | — | Безопасно |
| `price_grids`, `price_grid_log`, `price_indices`, `price_index_values` | ✅ | Ценовой стек. В `price_grids`: `base_price_per_kg`, `premium_per_kg`. **`minimum_price` отсутствует** | `minimum_price` отдельно от `reference_price` | +1 колонка | Аддитивно |
| `offers` | ❌ нет | — | Новая сущность: FSM `pending / accepted / rejected / expired / withdrawn` | Полностью новая | Аддитивно (новая таблица) |
| `pool_lines` | ❌ нет | — | Новая сущность: `pool_id`, `category_id`, `mpk_price`, `max_volume` | Полностью новая | Аддитивно |
| `pool_regions` | ❌ нет | — | Новая (oblast/rayon) | Полностью новая | Аддитивно |
| `review_dimensions` | ❌ нет | — | Справочник дименсий оценки | Полностью новая | Аддитивно |
| `deal_reviews` | ❌ нет | — | Шапка отзыва по сделке | Полностью новая | Аддитивно |
| `deal_review_dimension_scores` | ❌ нет | — | Оценки по дименсиям | Полностью новая | Аддитивно |

**Точная проверка несуществующих таблиц** (`to_regclass`):
`offers=null, pool_lines=null, pool_regions=null, deal_reviews=null, review_dimensions=null, deal_review_dimension_scores=null`.

---

## Раздел 2 — RPC реестр

### 2.1 Что есть в БД (TSP-related, из `pg_proc`)

Из d02_tsp.sql:
- `rpc_create_pool_request(p_organization_id, p_total_heads, p_target_month, p_region_id, p_accepted_categories)`
- `rpc_activate_pool_request(p_organization_id, p_request_id)`
- `rpc_match_batch_to_pool(p_organization_id, p_pool_id, p_batch_id, p_matched_heads, p_price_per_kg)`
- `rpc_advance_pool_status(p_organization_id, p_pool_id, p_new_status)`
- `rpc_rollback_batch_match(p_organization_id, p_pool_id, p_batch_id, p_reason)`
- `rpc_cancel_batch(p_organization_id, p_batch_id, p_reason)`
- `rpc_get_price_for_sku(p_organization_id, p_sku_id, p_region_id)`
- `rpc_get_market_summary(p_organization_id, p_region_id, p_month)`
- `rpc_set_price_grid(p_organization_id, p_sku_id, p_base_price_per_kg, p_premium_per_kg, p_region_id)`
- `rpc_publish_price_index_value(p_organization_id, p_index_id, p_period_date, p_value)`

Из d07_ai_gateway.sql (AI-расширения, TSP-relevant):
- `rpc_create_batch(p_organization_id, p_farm_id, p_tsp_sku_id, p_heads, p_avg_weight_kg, p_target_month, p_region_id, p_herd_group_id, p_notes, p_actor_id, p_ai_context)`
- `rpc_publish_batch(p_organization_id, p_batch_id, p_actor_id, p_ai_context)`
- `rpc_get_org_batches(p_organization_id, p_status)`
- `rpc_get_aggregated_supply(p_organization_id, p_target_month, p_region_id, p_min_count)`
- `rpc_get_aggregated_demand(p_organization_id, p_target_month, p_region_id, p_min_count)`
- `rpc_get_price_grid(p_organization_id, p_region_id, p_target_month)`

### 2.2 Целевая дельта (M4 + M6) — что нужно будет добавить

Новые (минимум, по логике эталонной модели):
- `rpc_create_pool` (с `total_target_volume`, окном `delivery_from/to`)
- `rpc_add_pool_line(pool_id, category_id, mpk_price, max_volume)`
- `rpc_create_offer(batch_id, pool_line_id, ...)` + FSM-переходы (`accept`, `reject`, `withdraw`, `expire`)
- `rpc_confirm_deal` (раскрытие контакта на `confirmed`)
- `rpc_advance_batch_status` (для расширенного FSM)
- `rpc_submit_deal_review` (+ dimensions)
- `rpc_classify_batch(category_id, classifier_version)`

Старые, **подлежащие deprecate** (нельзя удалять одномоментно по P7):
- `rpc_create_pool_request`, `rpc_activate_pool_request` — сущность уходит
- `rpc_match_batch_to_pool`, `rpc_rollback_batch_match` — junction уходит
- `rpc_advance_pool_status` — FSM меняется

### 2.3 Сверка трёх источников

| Источник | TSP-RPC покрытие | Дрифт |
|---|---|---|
| `rpc_name_registry` (БД) | 16 TSP-related строк, все указывают на существующие в pg_proc функции | — |
| `Docs/AGOS-Dok3-RPC-Catalog-v1_4.md` | TSP-блок отражает d02-набор. Единственное упоминание «offer» в файле — комментарий к `rpc_create_batch`: *«Создание черновика supply-offer»* (строка 322), сущности `offer` в каталоге нет | OK для baseline |
| `pg_proc` (live DB) | Все 16 функций реально присутствуют, signatures совпадают | OK |

**Общие дрифты по реестру (не только TSP, для полноты):**

| sql_name | dok3_name | dok5_tool_name | Комментарий |
|---|---|---|---|
| `rpc_create_vet_case` | `rpc_open_vet_case` | `create_vet_case` | имена расходятся между SQL ↔ Dok 3 (D-NEW-A: побеждает SQL) |
| `rpc_get_aggregated_supply` / `rpc_get_aggregated_demand` | (null) | оба = `get_market_overview` | две SQL-функции — один AI-tool. Намеренно (объединяющий tool), но dok3_name пустой |
| `rpc_start_ai_conversation` | — | — | две перегрузки в БД (4 и 5 аргументов). Реестр одну строку имеет, перегрузка не задокументирована |
| `rpc_publish_batch`, `rpc_create_batch`, `rpc_get_org_batches`, `rpc_get_aggregated_*`, `rpc_get_price_grid` | dok3_name = NULL | tool name есть | Эти RPC живут в d07_ai_gateway.sql, не в d02. В Dok 3 (катал. RPC) их явно нет |

Для TSP-ре-базлайна это означает: **AI-tools часть TSP-RPC физически в `d07_ai_gateway.sql`, а не в `d02_tsp.sql`**. При переименовании сущностей придётся править оба файла.

---

## Раздел 3 — Точки в коде приложения (что сломает ре-базлайн)

### 3.1 Frontend (`src/`)

**Прямые вызовы TSP-RPC** через `useRpcMutation`:

| Файл:строка | RPC | Использует |
|---|---|---|
| `src/pages/cabinet/market/CreateBatch.tsx:41` | `rpc_create_batch` | `p_target_month`, `p_tsp_sku_id` |
| `src/pages/cabinet/market/CreateBatch.tsx:65` | (params) | `p_target_month: targetMonth + '-01'` |
| `src/pages/cabinet/market/BatchDetail.tsx:39` | `rpc_publish_batch` | `p_batch_id` |
| `src/pages/cabinet/market/BatchDetail.tsx:43` | `rpc_cancel_batch` | `p_batch_id`, `p_reason` |
| `src/pages/cabinet/market/BatchDetail.tsx:36` | (params) | `p_sku_id: batch?.tsp_sku_id` |
| `src/pages/admin/pools/PoolQueue.tsx:64,88` | `rpc_create_pool_request` | `p_target_month`, `p_total_heads`, `p_region_id`, `p_accepted_categories` |
| `src/pages/admin/pools/PoolQueue.tsx:75` | `rpc_activate_pool_request` | `p_request_id` |
| `src/pages/admin/pools/PoolDetail.tsx:56` | `rpc_match_batch_to_pool` | `p_pool_id`, `p_batch_id`, `p_matched_heads`, `p_price_per_kg` |
| `src/pages/admin/pools/PoolDetail.tsx:59` | `rpc_advance_pool_status` | `p_new_status` (`'filling'→'filled'→'executing'…`) |
| `src/pages/admin/pools/PoolDetail.tsx:62` | `rpc_rollback_batch_match` | `p_pool_id`, `p_batch_id` |
| `src/pages/admin/pricing/PriceGridManagement.tsx:82` | `rpc_set_price_grid` | `p_sku_id`, `p_base_price_per_kg`, `p_premium_per_kg` |
| `src/pages/admin/pricing/PriceGridManagement.tsx:89` | `rpc_publish_price_index_value` | — |
| `src/hooks/cabinet/useCreateBatch.ts:33` | `rpc_create_batch` (через useRpcMutation) | `p_target_month`, `p_tsp_sku_id` |
| `src/hooks/cabinet/useUpdateBatch.ts:73` | (update RPC) | `p_target_month` |
| `src/hooks/cabinet/useCreatePoolRequest.ts:30,33` | `create_pool_request` (через `(supabase.rpc as any)`) | `p_target_month` |
| `src/hooks/cabinet/useActivatePoolRequest.ts:13` | `activate_pool_request` | — |
| `src/hooks/cabinet/useClosePoolRequest.ts:13` | `close_pool_request` (⚠ нет в БД) | — |
| `src/hooks/cabinet/useCancelPoolRequest.ts:13` | `cancel_pool_request` (⚠ нет в БД) | — |
| `src/hooks/admin/useCreatePoolMatch.ts:21` | `create_pool_match` (⚠ нет в БД) | — |
| `src/hooks/cabinet/useDemandByCategory.ts:12` | (params) | `p_target_month` |

> ⚠ **Уже сейчас в коде есть «висячие» вызовы**: `close_pool_request`, `cancel_pool_request`, `create_pool_match` — RPC под этими именами в pg_proc нет. Это **прежде существующий дефект**, не последствие будущего ре-базлайна.

**Прямой SQL-доступ к таблицам** (`supabase.from(...)`), будет затронут переименованием/удалением:

| Файл:строка | Таблица | Поля |
|---|---|---|
| `src/hooks/cabinet/usePoolRequests.ts:10`, `usePoolRequest.ts:10` | `pool_requests` | весь select |
| `src/hooks/admin/useAdminRequests.ts:10` | `pool_requests` | весь select |
| `src/hooks/cabinet/useRequestMatches.ts:14,20` | `pool_matches` | `pool_request_id` |
| `src/hooks/cabinet/useBatchMatches.ts:11` | `pool_matches` | — |
| `src/pages/admin/pools/PoolDetail.tsx:47,48,49` | `pools`, `pool_matches`, `batches` | `pool_request_id`, `mpk_contact_revealed_at`, `tsp_sku_id`, `status='published'` |
| `src/pages/cabinet/market/MarketDashboard.tsx:74,77` | (batches) | `tsp_sku_id`, `target_month` |
| `src/pages/cabinet/market/PriceInfo.tsx:29,57` | `price_grids`, `tsp_skus` | — |
| `src/pages/cabinet/market/CreateBatch.tsx:34` | `tsp_skus` | filter `available=true` |
| `src/pages/admin/pricing/PriceGridManagement.tsx:48,52` | `price_grids`, `tsp_skus` | — |

**Status-literal сравнения** (CHECK-зависимые):
- `PoolQueue.tsx:141,146,150`: `r.status === 'draft' / 'active'` (pool_request FSM)
- `PoolDetail.tsx:106,116`: `pool.status === 'filling'` (pool FSM)

**TypeScript-типы:**
- `src/types/tsp.ts` — содержит `target_month`, `pool_request_id`, `tsp_sku_id` в интерфейсах строк 83, 99, 120, 148, 159, 166. Эти типы используются всеми TSP-хуками.

**M4/M6 токены в коде:** `scheduled`, `offering`, `awaiting_*`, `closed_filled/partial/unfilled`, `expired_empty`, `ready_from`, `ready_to`, `farmer_price`, `deal_price`, `pool_line` — **0 совпадений** ни в `src/`, ни в `ai_gateway/` (все «scheduled» относятся к vaccinations/farm_tasks, все «ready_to_sell» — к полю формы регистрации).

### 3.2 AI Gateway (`ai_gateway/tools/market.py`)

Прямые вызовы `sb.rpc(...)`:

| Строка | RPC | Параметры |
|---|---|---|
| 174 | `rpc_get_price_grid` | `p_region_id` |
| 178 | `rpc_get_aggregated_supply` | `p_target_month`, `p_region_id` |
| 182 | `rpc_get_aggregated_demand` | `p_target_month`, `p_region_id` |
| 189 | `rpc_get_org_batches` | — |
| 193 | `rpc_create_batch` | `p_target_month` |
| 203 | `rpc_publish_batch` | — |
| 210 | `rpc_cancel_batch` | — |
| 217 | `rpc_get_price_for_sku` | `p_sku_id` |
| 224 | `rpc_get_market_summary` | — |

Tool-schemas (строки 47, 59, 88, 91) объявляют параметр `target_month` (`YYYY-MM-01`) как required — это контракт LLM↔gateway, его придётся переписывать при переходе на `ready_from/ready_to`.

### 3.3 UI/AI surface вкратце

UI-экраны TSP, уже завязанные на baseline:
- Farmer cabinet: `MarketDashboard`, `CreateBatch`, `BatchDetail`, `PriceInfo`
- Admin: `pools/PoolQueue`, `pools/PoolDetail`, `pricing/PriceGridManagement`
- Hooks: 18 файлов в `src/hooks/cabinet/` и `src/hooks/admin/` (см. список выше)

AI-tools (`market.py`): 9 функций. Полная их перерегистрация в LLM-контракте будет частью ре-базлайна.

---

## Раздел 4 — cross_check.sh

Запуск **2026-06-04 10:05 локально**: PASS.

```
CHECK 1: Duplicate function definitions      OK (whitelisted intentional upgrades)
CHECK 2: SQL files exist and non-empty       OK (9 файлов)
CHECK 3: SECURITY DEFINER on all rpc_*       OK
CHECK 4: No advisory locks (L-NEW-2)         OK
CHECK 5: organization_id in rpc_* (P-AI-2)   OK
CHECK 6: UI values match SQL CHECK           OK
CHECK 7: rpc_name_registry coverage          OK
CHECK 8: Article 171 disclaimer_text         OK

SUMMARY:  Critical=0  Significant=0  Minor=0
RESULT:   0 critical errors
```

> `cross_check.sh` НЕ проверяет соответствие с целевой M4/M6-моделью. Он валидирует консистентность внутри baseline. Поэтому «зелёный» статус не означает готовность к ре-базлайну — он означает, что текущий baseline сам по себе непротиворечив.

---

## Раздел 5 — Рекомендованный порядок миграции (P7-аддитивный)

Без написания SQL. Только зависимости и порядок шагов.

### Фаза A — Аддитивное расширение (не ломает существующее)

1. **A1.** В `d02_tsp.sql` добавить новые таблицы (CREATE TABLE IF NOT EXISTS):
   `pool_regions`, `pool_lines`, `offers`, `review_dimensions`, `deal_reviews`, `deal_review_dimension_scores`.
   Зависит от: `pools`, `batches`, `regions` (всё уже есть). Риск: 0.

2. **A2.** В `batches` добавить колонки (`ALTER TABLE ... ADD COLUMN IF NOT EXISTS`):
   `ready_from`, `ready_to`, `farmer_price`, `deal_price`, `pool_line_id` (nullable FK), `classifier_version`, `category_id`, `rayon`.
   Зависит от: A1 (pool_lines, category-таблица). Риск: 0 (все nullable).

3. **A3.** В `pools` добавить колонки: `total_target_volume`, `delivery_from`, `delivery_to`.
   Зависит от: — . Риск: 0.

4. **A4.** В `price_grids` добавить `minimum_price` (nullable).
   Риск: 0.

5. **A5.** Расширить CHECK на `batches.status` — **добавить** новые состояния в `ANY(ARRAY[...])`, **не удаляя старые**. Аналогично `pools.status`.
   Риск: низкий (CHECK расширение — аддитивно), но требует DROP/ADD constraint в одной транзакции; нужно подтверждение, что в проде не пишут одновременно.

6. **A6.** Зарегистрировать новые RPC-имена в `rpc_name_registry` (INSERT ... ON CONFLICT DO NOTHING). Без создания самих функций — только бронирование имён.
   Риск: 0.

**После Фазы A:** старая модель работает, новая — пустая. cross_check должен оставаться зелёным.

### Фаза B — Реализация новой бизнес-логики (новые RPC, аддитивно)

7. **B1.** Реализовать новые RPC (`rpc_create_pool`, `rpc_add_pool_line`, `rpc_create_offer`, `rpc_confirm_deal`, `rpc_advance_batch_status`, `rpc_submit_deal_review`, `rpc_classify_batch`). Все `SECURITY DEFINER`, все с `p_organization_id`.
   Зависит от: A1–A5.

8. **B2.** Обновить `d07_ai_gateway.sql`: новые AI-tools для новой модели. Старые AI-tools оставить в работе.
   Зависит от: B1.

9. **B3.** Обновить Dok 1 / Dok 3 / Dok 4 / Dok 5 / Dok 6 — внести новые сущности, RPC, FSM, события.
   Зависит от: B1–B2. Это документация, риска для рантайма нет.

### Фаза C — Двойная запись и миграция данных

10. **C1.** В UI и AI-tools добавить запись в новые таблицы ПАРАЛЛЕЛЬНО старым (двойная запись). Старые читатели всё ещё работают со старой моделью.
    Зависит от: B1.

11. **C2.** Backfill: перенести данные `pool_requests + pool_matches → pool_lines + offers`. Идемпотентный скрипт.
    Зависит от: C1.

12. **C3.** Бэкфилл `batches.ready_from := target_month`, `batches.ready_to := target_month + interval '1 month' - 1 day` (или согласованное правило). Бэкфилл `batches.category_id` через classifier.
    Зависит от: A2.

### Фаза D — Переключение читателей

13. **D1.** Перевести фронт (`src/pages/cabinet/market/*`, `src/pages/admin/pools/*`, `src/hooks/cabinet|admin/*`, `src/types/tsp.ts`) на новую модель. Это ~20 файлов из Раздела 3.1.
    Зависит от: C1–C3.

14. **D2.** Перевести `ai_gateway/tools/market.py` на новые RPC.
    Зависит от: C1–C3.

15. **D3.** Починить «висячие» вызовы: `close_pool_request`, `cancel_pool_request`, `create_pool_match` — либо реализовать соответствующие RPC, либо удалить вызовы (рекомендуется второе, т.к. сущности уходят).

### Фаза E — Сужение и deprecation

16. **E1.** Перевести `delivery_records.pool_match_id` → `delivery_records.pool_line_id` (nullable add, бэкфилл, set NOT NULL, drop старого FK).

17. **E2.** Удалить из CHECK старые состояния `batches.status` (`matched`, etc.) и `pools.status` (`filled`, `executing`, `dispatched`, `delivered`, `executed`, `closed`) — только после того, как ни одна строка их не использует.

18. **E3.** Удалить `pool_requests`, `pool_matches`. Удалить `batches.target_month`, `batches.tsp_sku_id` (если решено окончательно отказаться от primary-роли SKU).
    Зависит от: D1–E2.

19. **E4.** `cross_check.sh`: расширить контракт — добавить проверки на новые сущности (offers FSM, pool_line обязательность category_id, и т.д.).

> Каждая фаза должна заканчиваться зелёным `cross_check.sh` и зелёным smoke на UI. Между фазами — паузы для наблюдения.

---

## РЕЗЮМЕ

**Безопасно ли начинать ре-базлайн TSP сейчас?** — **Условно безопасно по Фазе A** (чисто аддитивные ALTER/CREATE TABLE). Дальше — нет, без подготовки.

**Что блокирует немедленный полный ре-базлайн:**

1. **3 «висячих» вызова RPC** в коде, которых нет в pg_proc (`close_pool_request`, `cancel_pool_request`, `create_pool_match`) — это уже существующий дефект baseline. Их нужно либо реализовать, либо удалить **до** того, как трогать TSP-домен, иначе они затеряются в шуме изменений.
2. **`delivery_records.pool_match_id` — NOT NULL FK** на удаляемой таблице. Любая попытка дропнуть `pool_matches` без предварительной миграции FK обрушит вставки в delivery_records.
3. **FSM `pools` и `batches` пересекаются с целевыми только частично** (`filling`, `executing` у pools; `draft`, `published`, `cancelled` у batches). Прямая замена CHECK сломает существующие строки. Нужен двухфазный путь (расширить → переключить writers → сузить).
4. **20+ файлов фронта и `ai_gateway/tools/market.py`** жёстко завязаны на `target_month`, `tsp_sku_id`, `pool_request_id`, status-литералы baseline. Без двойной записи переключение читателей невозможно за один шаг.
5. **Dok 1 / Dok 3 / Dok 6** не содержат описания `offer`, `pool_line`, `ready_from/ready_to`, новых FSM (нашёлся только один комментарий «supply-offer» в Dok 3). До нормативной фиксации модели в Dok любая реализация будет противоречить принципу «Data Model First» (P1) и `One Source of Truth` (P4).
6. **Версионность миграций**: в проекте используется один консолидированный файл на домен (`d02_tsp.sql`), а не серия инкрементов. Ре-базлайн TSP в этой модели = переписать ~1400 строк d02 в одном PR. Рекомендуется временный режим — серия отдельных файлов `d02_tsp_M4_*.sql` для фаз A–E, с последующей консолидацией обратно в d02 после завершения D-фазы.

**Что НЕ блокирует, готово к использованию:** cross_check зелёный, schema_migrations согласован с d0X-файлами, rpc_name_registry полный, никаких сюрпризов в применённой схеме относительно SQL-файлов не обнаружено.

**Рекомендация перед стартом:** обновить Dok 1 (новые сущности, новые FSM) и Dok 3 (новый каталог RPC) **до** Фазы A. По P1: модель данных — это архитектура; реализация без зафиксированной модели породит десятки решений, которые будут конфликтовать.
