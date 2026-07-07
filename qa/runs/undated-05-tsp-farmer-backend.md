# Прогон 05-tsp-farmer.md (backend-слой) — 2026-07-05

Окружение: **staging, REST-режим** (`SUPABASE_URL` + service_role из `.env`; psql/DATABASE_URL нет → rollback-tx недоступен, применена дисциплина QA-префиксов с полной зачисткой). Коммит `b7b8cf4`.

Конфиги (прочитаны из `tsp_config`, is_active=true, перед прогоном — P8):
`price_decision_after_minutes=1` (⚠ тестовый дефолт, НЕ 24 ч из текста кейсов), `offer_window_hours=24`, `mpk_decision_window_hours=24`, `price_step_down_amount=100`, `publish_lead_days=7`, `min_split_heads=5`.

Отбор: только кейсы с `layer:` sql / rpc / e2e (`sql+ui` — прогнан **SQL-слой**, UI-часть у UI-волны). Чистый `ui` и `ui+rpc` не прогонялись (23 кейса файла — UI-волна). Отобрано 6 кейсов, все `status:active`.

Изоляция от живых staging-данных: QA-пулы с жёстким district-фильтром `qa-tspf-district` (реальные партии не проходят hard-match района, fn_tsp_district_match); QA-партии с ask 90000 ₸/кг — выше максимального бида действующих filling-пулов (53100) → чужие пулы взять их не могли.

Примечание: этот файл перезаписывает более ранний прогон той же волны — вердикты полностью совпали (4 PASS / 2 FAIL, те же ID); его доп-наблюдение про `rpc_pool_return_batches` сохранено в находке 1.

Итог: **PASS 4 / FAIL 2 / PARTIAL 0 / SKIP 0** (из 6 backend-кейсов; в файле всего 29)

| ID | Вердикт | Evidence / причина |
|---|---|---|
| TSPF-LIFE-12 | **PASS** | Батч 10 гол. (grade VS, ask 90000, Акмолинская обл.) существовал ДО пула: `rpc_create_batch` → `status=published`. МПК: `rpc_self_create_pool_request` (25 гол., vysshaya, бид 90100) → `rpc_self_activate_pool_request` → `{"sweptMatched":1,"sweptOffered":0}`; батч → `matched`, `matched_heads=10`, `deal_price_per_kg=90100` (бид > ask — best execution D-TSP-5), allocation `via=pool_activate_sweep`. Свип published-партий (фикс TSP-FLOW-08, миграции 20260625120000/20260702160000) задеплоен и работает. |
| TSPF-LIFE-10 | **PASS** (sql-часть) | Батч B 15 гол. → `rpc_self_auto_match_batch` → `{"fully":true}` → пул 25/25 → `pools.status=closed_filled`, `mpk_contact_revealed_at` установлен В МОМЕНТ закрытия (D-M6-5); allocations `matched→confirmed` (confirmed_at); оба батча пула → `confirmed` (rollup fn_tsp_rollup_batch_status). Раскрытие фермеру: `rpc_get_org_batches` → `buyer="QA-TSPF МПК"`, `buyerPhone=+70000001102`, `deal=90100`. Per-кусок: alloc → confirmed при закрытии ЕГО пула. |
| TSPF-LIFE-15 | **PASS** (sql-часть) | Цепочка от confirmed (LIFE-10): фермер `rpc_self_dispatch_ready` → `{"dispatchedChunks":1}`, батч `dispatched` (dispatched_at); МПК `rpc_self_confirm_delivery` → `true`, батч → `delivered` (delivered_at, терминальный успех BT-18); после доставки всех партий пул → `completed`. Окно отзыва (LIFE-16, ui+rpc) — вне этого прогона. |
| TSPF-LIFE-01 | **PASS** (sql-часть, с примечанием) | Батч C 10 гол. → пул 3 гол.: аллокация заблокирована `min_split_heads=5` → broadcast: оффер `pending` (expires_at=+24ч = offer_window из конфига), батч `offering`. Бэкдейт `offering_at` −10 мин → фермерский `rpc_self_review_due_batches` → `{"moved":1,"afterMinutes":1}`; батч → `awaiting_price_decision` (+awaiting_price_decision_at), pending-оффер принудительно → `expired` (responded_at). Переход BT-09 работает. Триггер — конфиг `price_decision_after_minutes=1 мин` (D-PRICEREC-01, poll-driven, published И offering), не «24 ч» из текста кейса. Карточка на Главной — UI-волна. |
| TSPF-LIFE-11 | **FAIL** (находка) | Батч D → matched в пул 100 гол. (10/100, deal 90100). target_month откатан на 2026-05 → `rpc_self_close_due_pools` (МПК) → `{"closed":1,"filled":0}`: пул → `closed` (10 < 30% target). **Ожидание канона (BT-14, D-TSP-10): батч → published, deal_price сброшен, снова участвует в matching. Факт: батч остался `matched` (`deal_price_per_kg=90100`, allocation `matched`) на мёртвом closed-пуле — партия молча снята с рынка навсегда.** Self-serve путь underfill вообще не возвращает батчи. В IMPL_DEBT не зарегистрировано (TSP-SCHEMA-04/TSP-FLOW-04 — про cancel) → настоящий дефект. |
| TSPF-LIFE-17 | **FAIL** (находка/known-gap) | Механизма авто-выхода scheduled-партии (BT-21) НЕТ. Evidence: `rpc_create_batch(p_scheduled=true)` → `status='draft'` + `notes.scheduled=true`, `published_at=null`, `scheduled_publish_at=null` — колонка в схеме есть (d02_tsp.sql:994), но НИКЕМ не заполняется; publish-due функции не существует (grep `scheduled_publish_at|auto_publish|publish_due` по d02+миграциям — только схема/комментарии); комментарий миграции 20260622120000:323 прямо фиксирует «scheduled → draft (нет планировщика на бете)»; событие `auto_published` заведено в CHECK (d02:1489), но не эмитится. Осознанный MVP-пропуск, частично пересекается с TSP-FLOW-02 (d07 rpc_publish_batch), но self-serve джоб не зарегистрирован. |

## Находки (кандидаты в дефекты / IMPL_DEBT)

1. **TSP underfill-release отсутствует (новый долг, BT-14 / D-TSP-10).** `rpc_self_close_due_pools` (20260622120000:1502) переводит недобранный пул в `closed`, не трогая его matched-батчи/allocations: партии осиротевают `matched` с `deal_price` на закрытом пуле и никогда не возвращаются в matching. Прежний прогон дополняет: canonical `rpc_pool_return_batches` (d02, admin-пайплайн) возвращает батч в `published`, но не сбрасывает `matched_heads` и не отменяет куски `batch_allocations` → партия всё равно невидима матчерам (`matched_heads < heads`); self-serve продюсера `filling → awaiting_mpk_decision` нет. Предлагаемая строка: `TSP-FLOW-10 | TSP-flow | code lags | underfill close не возвращает батчи (BT-14): matched-партии осиротевают на closed-пуле | rpc_self_close_due_pools; rpc_pool_return_batches (без allocations) | в close-ветке: allocations → cancelled, batches: status=published, deal_price=null, matched_heads −= chunk, событие + уведомление D-TSP-10`.
2. **Scheduled-публикация (BT-21) не реализована в self-serve (новый долг или расширение TSP-FLOW-02).** `scheduled_publish_at` — мёртвая колонка; батч живёт как `draft`+meta; sweep-RPC нет; `auto_published` не эмитится. TSP-FLOW-02 покрывает только d07 `rpc_publish_batch` (AI gateway), не self-serve джоб.

## Предложения по кейсам

- **TSPF-LIFE-01:** заменить в предусловии «24 ч прошли» на «прошло `tsp_config.price_decision_after_minutes` (сейчас 1 мин, тестовый дефолт; poll-driven через rpc_self_review_due_batches, срабатывает для published И offering)» — миграция 20260702200000; реальность также принудительно гасит ещё-живые pending-офферы, а не ждёт их истечения.
- **TSPF-LIFE-11 / TSPF-LIFE-17:** перевести в `status:blocked:<DEBT-ID>` после заведения долгов (находки 1–2).
- **TSPF-LIFE-12:** примечание «проверить деплой миграции 20260625*» можно снять — свип подтверждён живым прогоном (дважды: оба прогона волны).

## Зачистка QA-префиксов (REST-режим, без транзакций)

Создавалось с префиксом `QA-TSPF` (org bin 990000000101/102, телефоны +70000001101/02, auth `qa-tspf-farmer@qa.agos.local` / `qa-tspf-mpk@qa.agos.local`). Удалено в обратном порядке FK, все DELETE → 204/200: batch_events, batch_allocations, offers, 5 батчей, pool_regions, pool_lines, 3 пула, 3 pool_requests, 2 user_organization_roles, 2 public.users, 2 auth-пользователя, 2 организации.

Не удалилось: ничего. Residual-check: `organizations legal_name like QA-TSPF*` → `[]`; `batches notes like *QA-TSPF*` → `[]`.

SMS/OTP не триггерились. Код не правился (HS-3/HS-6): FAIL'ы — только evidence.
