# Сводная QA-прогона — backend + UI слои (14 отчётов, коммит `b7b8cf4`)

Собрано из 14 файлов `qa/runs/undated-*.md` (8 backend + 6 ui/ui+rpc с реальным контентом;
`03-onboarding-backend` — 0 кейсов в скоупе, файл целиком UI-слойный) плюс уже существующая
`qa/runs/2026-07-05-SUMMARY.md` (backend-only срез) как перекрёстная сверка чисел.
Окружение всех прогонов: staging `mwtbozflyldcadypherr.supabase.co`, REST-режим (нет
`DATABASE_URL` → без rollback-tx, дисциплина QA-префиксов + ручная зачистка), **живых
клиентов нет**, UI-волна — реальный (не demo) backend через `.env`.

## Итог по файлам

| Файл | Слой | PASS | FAIL | PARTIAL | SKIP | Отчёт |
|---|---|---|---|---|---|---|
| 01-registration | backend | 5 | 0 | 0 | 1 | undated-01-registration-backend.md |
| 01-registration | ui | 4 | 1 | 0 | 20 | undated-01-registration-ui.md |
| 02-auth | backend | 2 | 0 | 0 | 8 | undated-02-auth-backend.md |
| 02-auth | ui | 4 | 0 | 0 | 4 | undated-02-auth-ui.md |
| 03-onboarding | backend | 0 | 0 | 0 | 0 (файл целиком UI) | undated-03-onboarding-backend.md |
| 03-onboarding | ui | 3 | 1 | 0 | 1 | undated-03-onboarding-ui.md |
| 04-membership | backend | 2 | 0 | 2 | 11 | undated-04-membership-backend.md |
| 04-membership | ui | 0 | 0 | 1 | 14 | undated-04-membership-ui.md |
| 05-tsp-farmer | backend | 4 | 2 | 0 | 0 | undated-05-tsp-farmer-backend.md |
| 05-tsp-farmer | ui | 20 | 1 | 1 | 1 | undated-05-tsp-farmer-ui.md |
| 06-tsp-mpk | backend | 4 | 2 | 2 | 0 | undated-06-tsp-mpk-backend.md |
| 06-tsp-mpk | ui | 3 | 0 | 3 | 5 | undated-06-tsp-mpk-ui.md |
| 07-security-cross | backend | 6 | 5 | 1 | 0 | undated-07-security-cross-backend.md |
| 07-security-cross | ui | 4 | 1 | 3 | 0 | undated-07-security-cross-ui.md |
| 08-backend-e2e | backend | 5 | 2 | 3 | 1 | undated-08-backend-e2e-backend.md |
| **Итого** | | **66** | **15** | **16** | **66** | (из 163 кейсов исполнено; часть кейсов вне скоупа своей волны — см. "Вне скоупа" в отчётах) |

Сверка с `2026-07-05-SUMMARY.md` (backend-only): та сводка даёт PASS 28/FAIL 11/PARTIAL
8/SKIP 21 — цифры этой сводки по backend-строкам совпадают построково (5+2+0+2+4+4+6+5=28
PASS, 0+0+0+0+2+2+5+2=11 FAIL и т.д.). Разница итога — добавлен UI-слой (38 PASS / 4 FAIL /
9 PARTIAL / 45 SKIP), которого не было в прошлой сводке.

`qa/check_coverage.sh`: 177 кейсов всего, 150 active / 4 mock / 2 future / 21 blocked
(9 MEMBERSHIP-03, 3 TSP-FLOW-10, 1 каждый: TSP-FLOW-02, SEC-STORAGE-01, SEC-SELFDEAL-01,
SEC-RPC-ORGTRUST-01, SEC-GATE-MEMBERSHIP-01, SEC-GATE-LIMIT-01, MEMBERSHIP-07,
MEMBERSHIP-01, IDENTITY-06). Автотестами покрыто 5 (E2E-TSP-01, TSPF-LIFE-10,
TSPF-PUB-01, TSPM-CLOSE-01, TSPM-OFF-02), тегов-сирот 0.

## Все FAIL одним списком

| ID | Слой/файл | Суть | Отчёт |
|---|---|---|---|
| REG-OTP-04 | ui/01-reg | `PhoneInput.tsx` не нормализует ведущую «8»→«7»; номер `8XXXXXXXXX` уходит на бэкенд как невалидный `+78XXXXXXXXX` вместо `+77XXXXXXXXX` | undated-01-registration-ui.md |
| ONB-SUC-01 | ui/03-onb | `Success.tsx` — orphan-компонент, 0 импортов; `Registration.tsx` после Agreement идёт прямиком в `/cabinet`/`/mpk`, экран онбординга (KPI/«Первые шаги»/баннер заявки) никогда не рендерится | undated-03-onboarding-ui.md |
| TSPF-LIFE-11 | backend/05-tspf | Underfill: батч остаётся `matched` с `deal_price` на мёртвом `closed`-пуле, не возвращается в published (BT-14/D-TSP-10) — KNOWN-GAP TSP-FLOW-10 | undated-05-tsp-farmer-backend.md |
| TSPF-LIFE-17 | backend/05-tspf | Scheduled-публикация не реализована в self-serve: `scheduled_publish_at` мёртвая колонка, джоба публикации нет — KNOWN-GAP TSP-FLOW-02 | undated-05-tsp-farmer-backend.md |
| TSPF-RES-01 | ui/05-tspf | Экран результата публикации всегда показывает вариант B/D, даже когда автоматч реально сработал (`matched:true`) — `BatchWizard.tsx:138-139` не проверяет `match?.matched`. Новая находка BUG-PUBRESULT-VARIANT-01 | undated-05-tsp-farmer-ui.md |
| TSPF-LIFE-16 | ui/05-tspf | `ReviewScreen.tsx` — чистый UI-мок отзыва о сделке: нет RPC, нет таблицы `batch_reviews` (`PGRST205`), нет персистентности/double-blind. Новая находка GAP-REVIEW-MOCK-01 | undated-05-tsp-farmer-ui.md |
| TSPM-POOL-07 | backend/06-tspm | `rpc_self_close_due_pools` живёт на legacy-FSM (`filled`/`closed`, порог 30%), канонический терминал `expired_empty` недостижим — KNOWN-GAP TSP-FLOW-10 | undated-06-tsp-mpk-backend.md |
| TSPM-CLOSE-03 | backend/06-tspm | Недобранный пул (33%) принудительно засчитан `filled` без решения МПК; `mpk_decision_window_hours` не используется; `rpc_pool_return_batches` недостижим — KNOWN-GAP TSP-FLOW-10 | undated-06-tsp-mpk-backend.md |
| SEC-GATE-01 | backend/07-sec | `rpc_create_batch` без backend membership-гейта — не-член опубликовал партию — KNOWN-GAP SEC-GATE-MEMBERSHIP-01 | undated-07-security-cross-backend.md |
| SEC-GATE-02 | backend/07-sec | Лимита активных партий на RPC нет (7 подряд без отказа); поля лимита в `tsp_config` нет — KNOWN-GAP SEC-GATE-LIMIT-01 | undated-07-security-cross-backend.md |
| SEC-RLS-01 | backend/07-sec | **CRITICAL.** SECURITY DEFINER self-RPC не сверяют `p_organization_id` с `fn_my_org_ids()` → кросс-org мутация (`rpc_cancel_batch` чужой партии прошёл) — KNOWN-GAP SEC-RPC-ORGTRUST-01 | undated-07-security-cross-backend.md |
| SEC-RLS-03 | backend/07-sec | **CRITICAL.** Bucket `membership-documents` не изолирован — чужой `bank_details.png` скачан HTTP 200 — KNOWN-GAP SEC-STORAGE-01 | undated-07-security-cross-backend.md |
| SEC-MISC-02 | backend/07-sec | Матчинг не исключает самосделку (org продавец=покупатель) — KNOWN-GAP SEC-SELFDEAL-01 | undated-07-security-cross-backend.md |
| SEC-ART-01 | ui/07-sec | `CreatePoolModal.tsx` (МПК, ввод цены в заявке на закупку) без антитраст-дисклеймера — требует сверки с MS4-§8 (относится ли к «справочной цене» канона), не зарегистрировано в IMPL_DEBT | undated-07-security-cross-ui.md |
| SEC-ART-03 | ui/07-sec | Слово «пул» утекает в фермерский словарь: `BatchScreen.tsx:202` («ждёт заполнения пула»), `WithdrawSheet.tsx:43,55` — нарушение антитраст-словаря фермера, не зарегистрировано в IMPL_DEBT | undated-07-security-cross-ui.md |
| E2E-TSP-04 | backend/08-e2e | Underfill-исходы канона отсутствуют в адаптере целиком (оба сценария A/B) — тот же корень TSP-FLOW-10 | undated-08-backend-e2e-backend.md |
| E2E-TSP-05 | backend/08-e2e | Scheduled-публикация недостижима (draft-заглушка) — KNOWN-GAP TSP-FLOW-02 | undated-08-backend-e2e-backend.md |

Итого FAIL: **16** строк (часть — уже известные KNOWN-GAP по существующим долгам TSP-FLOW-10/TSP-FLOW-02/SEC-*, часть — новые находки без регистрации в IMPL_DEBT: REG-OTP-04, ONB-SUC-01, TSPF-RES-01/BUG-PUBRESULT-VARIANT-01, TSPF-LIFE-16/GAP-REVIEW-MOCK-01, SEC-ART-01, SEC-ART-03).

## Находки-кандидаты в IMPL_DEBT (не зарегистрированы)

Уже в IMPL_DEBT (для справки, не повторяю): SEC-STORAGE-01, SEC-RPC-ORGTRUST-01,
SEC-GATE-MEMBERSHIP-01, SEC-GATE-LIMIT-01, SEC-SELFDEAL-01, TSP-FLOW-10, TSP-FLOW-02,
BUG-GETORGBATCHES-01, MEMBERSHIP-07, MEMBERSHIP-01, MEMBERSHIP-03, IDENTITY-06.

Новые (эта волна, backend+UI), кандидаты на строки долга:

1. **BUG-PUBRESULT-VARIANT-01** (ui, TSPF-RES-01) — `BatchWizard.tsx:138-139`: `variant = delayed ? 'D' : 'B'` не проверяет `match?.matched` → вариант A («Покупатель найден!») физически недостижим даже при реальном матче. Фикс: `variant = delayed ? 'D' : (batch.state==='matched' ? 'A' : 'B')`.
2. **GAP-REVIEW-MOCK-01** (ui, TSPF-LIFE-16 + TSPM-CLOSE-05) — двусторонний: `ReviewScreen.tsx` (фермер→МПК) и `PoolMonitorModal.tsx` (МПК→фермер, `myRating`) — оба чисто локальный React-state, нет RPC, нет таблицы `batch_reviews` (`PGRST205`). Канон D-M6-11 (double-blind, обязательная вторая размерность, неизменяемость) полностью нереализован на бэкенде.
3. **ONB-SUCCESS-ORPHAN-01** (ui, ONB-SUC-01) — `Success.tsx` не подключён к `Registration.tsx`/`STEP_ORDER`; после Agreement — прямой `navigate('/cabinet'|'/mpk')`, минуя онбординг-экран (KPI, «Первые шаги», баннер заявки). Архитектурное решение нужно: подключить шаг или удалить файл (не решать самостоятельно — HS-2/HS-5).
4. **REG-PHONE-NORM-01** (ui, REG-OTP-04) — `PhoneInput.tsx` не нормализует ввод, начинающийся с «8» → на бэкенд уходит `+78XXXXXXXXX` вместо `+77XXXXXXXXX`.
5. **OTP-CONFIG-HARDCODE-01** (P8, backend, повторяется в 01/02/08) — OTP TTL (300с) и MAX_ATTEMPTS (3) — константы `supabase/functions/bird-otp/index.ts:11-12`, нет конфиг-таблицы в БД для OTP (в отличие от `tsp_config`).
6. **REG-PRIMARY-ORG-01** (backend, REG-SUB-07) — `rpc_register_organization` ставит `is_primary=true` каждой новой связке без уникальности → пользователь с 2+ организациями получает 2+ primary одновременно; влияет на маршрутизацию оболочек (ONB-ROUTE-03).
7. **SEC-ART-TSP-VOCAB-01** (ui, SEC-ART-03) — слово «пул» в фермерском UI (`BatchScreen.tsx:202`, `WithdrawSheet.tsx:43,55`) — нарушение антитраст-словаря (Ст.171).
8. **SEC-ART-DISCLAIMER-CREATEPOOL-01** (ui, SEC-ART-01) — `CreatePoolModal.tsx` без антитраст-дисклеймера на поле цены МПК; требует уточнения текста кейса или фикса — не решать молча.
9. **TSP-CANCELPOOL-ORPHAN-01** (backend, TSPM-POOL-06) — `rpc_cancel_pool` возвращает батч в `published`, но не сбрасывает `matched_heads`/не отменяет `batch_allocations`/не сбрасывает `pool_lines.current_heads`/не меняет `pool_requests.status` → возвращённая партия невидима матчерам навсегда. Отдельный от TSP-FLOW-10 путь (cancel, не close_due).
10. **TSP-PRICEFLOOR-01** (backend, E2E-TSP-03) — `rpc_lower_price` клэмпает только до 1 ₸/кг; `minimum_prices` пустая таблица и не проверяется — защитный пол цены (MS4-BT-11/D-M6-3) не работает.
11. **TSP-DEADLOCK-ACCEPT-01** (backend, TSPM-OFF-05 / E2E-TSP-07) — конкурентный `rpc_self_accept_offer` двух МПК на один батч отдаёт проигравшему `40P01 deadlock detected` вместо бизнес-ошибки; разный lock-order offers→batches vs batches→pool_lines→pools; правило «no advisory locks — use SKIP LOCKED» не соблюдено. Целостность данных не страдает.
12. **MPK-REVIEW-NONPERSIST-01** — см. пункт 2 (GAP-REVIEW-MOCK-01), дублируется из TSPM-CLOSE-05 в UI-06.
13. **MPK-FLOORPRICE-HARDCODE-01** (P8, ui, 06-tspm) — `MPK_CATS` (floor-цены категорий) захардкожены в `src/pages/cabinet/shell/mpk/types.ts`, не читаются из БД-справочника.
14. **MEM-OBSERVER-REAPPLY-01** — уже F-1 в отчёте 04-membership-backend, дублирует по смыслу MEMBERSHIP-07, но это отдельный guard-гэп (`ALREADY_ACTIVE` не покрывает `level=observer`) — уточнить, покрыт ли уже task_8b750f23 или нужна отдельная строка.
15. **MEM-ADMIN-GUARD-MISMATCH-01** (ui, MEM-ADM-06 / SEC-ART-03-отчёт) — `/admin/*` защищён `RequireExpert`, не `RequireAdmin`; редирект без toast «Доступ запрещён»; неиспользуемый `RequireAdmin.tsx` и отдельный неподключённый `useAdminGuard.ts` с третьим текстом/целью — 3 несогласованных гарда на одну область.
16. **BATCH-GRADE-SKU-MISMATCH-01** (backend, E2E-TSP-08 находка №4) — `fn_tsp_resolve_sku` даёт SKU c grade_id=VS, но `batches.grade_standard_id` записан как S — расхождение внутри одного создания батча (наблюдение, не влияло на матчинг в прогоне).

## Предложения по смене status кейсов

- **TSPF-LIFE-11, TSPF-LIFE-17** (05-tspf, backend) → `blocked:TSP-FLOW-10` / `blocked:TSP-FLOW-02` соответственно (долги уже существуют, кейсы пока `active`).
- **TSPM-POOL-07, TSPM-CLOSE-03** (06-tspm, backend) → уже фактически покрыты TSP-FLOW-10, синхронизировать статус в файле сценария.
- **TSPM-CLOSE-02** (06-tspm, ui) → `blocked:TSP-FLOW-10` (тот же корень: `rpc_self_advance_pool_status` вместо канонических `rpc_pool_accept_partial`/`return_batches`), сейчас не помечен, хотя POOL-07/CLOSE-03 помечены.
- **TSPF-RES-01** → `blocked:BUG-PUBRESULT-VARIANT-01` (после регистрации долга).
- **TSPF-LIFE-16, TSPM-CLOSE-05** → `blocked:GAP-REVIEW-MOCK-01` (после регистрации долга) — сейчас `active`, что ложно подразумевает полную реализацию.
- **TSPF-GATE-02** → `blocked:SEC-GATE-LIMIT-01` (долг уже существует, кейс до сих пор `active`).
- **E2E-TSP-04** → `blocked:TSP-FLOW-10` (текущее ожидание канона недостижимо в адаптере).
- **E2E-TSP-05** → `blocked:TSP-FLOW-02`.
- **MEM-ADM-04** → заменить ожидание `UNAUTHORIZED` на `FORBIDDEN` (текст кейса устарел, код и канон Dok6-Slice2 согласны на FORBIDDEN); сверить с SEC-GATE-03 в 07-security-cross (тот же паттерн).
- **SEC-RVL-02** → уточнить/снять «анонимная репутация ★» — документированный TODO в коде, не готовая фича.
- **MEM-UI-03/04/05, MEM-PAY-03** (04-membership, ui) → кандидаты на `blocked:MEMBERSHIP-01`/`MEMBERSHIP-03` — статусы `expiring/grace/expired/terminated` недостижимы через реальный бэкенд (`deriveMembership()` не производит их из БД); решение по переводу — на подтверждение, не принято самостоятельно.
- **TSPF-LIFE-01** (05-tspf, backend) → скорректировать формулировку «24ч» на «конфиг `price_decision_after_minutes` (сейчас 1 мин, тестовый дефолт)».
- **TSPM-POOL-08, TSPM-CLOSE-01** (06-tspm, backend) → убрать устаревшее «overshoot тотала допустим (D-TSP-9)» — заменено BATCH-SPLIT-01 (жёсткий потолок подтверждён живым прогоном).
- **REG-OTP-08/09, AUTH-RST-04** → пометить, что TTL/attempts — константы edge-функции, не БД-конфиг (пока не заведена строка OTP-CONFIG-HARDCODE-01).

## Что зелёное (ядро работает, включая UI)

- Регистрация (OTP-контракт, дубли BIN, M:N организаций), вход/PIN, восстановление PIN — happy paths подтверждены и на backend, и на UI (там, где достижимо без живого SMS).
- Онбординг-роутинг (`pickShellPath`, гейт Рынка `SellGate`) работает корректно на реальных сессиях.
- TSP happy-path целиком: wizard (валидации, классификатор категории, floor-цена soft-warn, восстановление черновика) → publish → auto-match/pool-activate-sweep → accept (FCFS) → matched → confirmed → dispatch → delivered; раскрытие покупателя строго при confirmed на UI и в данных; withdraw/cancel корректно откатывает счётчики пула в happy-path (не в cancel-пути пула, см. находку 9).
- МПК-сторона: создание пула с валидацией (floor-цена, min_split, overshoot-потолок) полностью клиентски блокирует некорректный ввод до отправки RPC.
- Security: горизонтальная изоляция МПК (RLS на pool_requests/offers/pool_lines), антитраст deal_price (не reference), раскрытие фермера анонимизировано до confirmed на UI-слое.

## Дисциплина зачистки

Все backend-прогоны подтверждают полную зачистку QA-префиксов (residual-check пуст). Два
исключения зафиксированы явно в отчётах: (а) в 06-tsp-mpk-backend осталась orphan-строка
`public.users` от параллельного UI-агента (передана волне 06, не тронута намеренно);
(б) в 06-tsp-mpk-ui **реальная неоткатываемая мутация**: создан пул `pool_requests`/`pools`
(50 голов, «Все области», июль 2026) на seed-организации «QA-ONB Дуал-МПК» + активировано
её membership `observer` — UI-слой против реального backend без rollback-tx физически не
может быть очищен транзакцией; агент сознательно остановил дальнейшие мутации (не довёл
пул до filled/executed) и явно пометил находку №4 (процедурный риск: нужен отдельный
staging-проект для ui+rpc волны).

## Следующие шаги

1. **CRITICAL, немедленно** (уже отражено в `2026-07-05-SUMMARY.md`, повторно подтверждаю): SEC-STORAGE-01 (кросс-org утечка Storage), SEC-RPC-ORGTRUST-01 (кросс-org мутация TSP RPC).
2. Зарегистрировать 16 новых находок в IMPL_DEBT.md (список выше) и синхронизировать статусы 12 кейсов (список выше) — по правилу CLAUDE.md «конфликт флагуется, не решается молча», ни один статус не менялся самостоятельно в этом прогоне.
3. Процедурный гэп для будущих UI-прогонов: нет staging-проекта, отдельного от `.env`-backend — ui+rpc кейсы либо создают неоткатываемые мутации, либо массово SKIP(sms/no-seed). Нужны: (а) seed-аккаунты фермер-не-член/фермер-член/МПК×2/админ с известными телефон+PIN, (б) `ADMIN_PASSWORD` в окружении агента, (в) dev-only OTP-bypass (тестовый номер с детерминированным кодом) — без этого весь layer `ui+rpc` после экрана OTP систематически недостижим.
4. Долги TSP-FLOW-10/TSP-FLOW-02/SEC-GATE-*/SEC-SELFDEAL-01 уже в IMPL_DEBT — в backlog Phase-2, без изменений от этого прогона.
