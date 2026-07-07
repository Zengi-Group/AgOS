# Прогон qa/scenarios/01-registration.md — backend-слой (sql/rpc/e2e) — 2026-07-05

Окружение: **staging, REST-режим** (`SUPABASE_URL` + service_role из `.env`; `DATABASE_URL` отсутствует → rollback-tx недоступен, применена дисциплина QA-префиксов). Коммит `b7b8cf4`.
Конфиги: OTP TTL = 300 c, MAX_ATTEMPTS = 3 — **константы edge-функции** `supabase/functions/bird-otp/index.ts:11-12`, в БД конфиг-дома нет (`tsp_config` содержит только TSP-параметры: offer_window_hours=24, price_step_down_amount=100 и т.д.). Значения совпали с ожиданиями кейсов.

Скоуп: только `layer:sql|rpc|e2e` (6 кейсов из 36 в файле); `ui`/`ui+rpc` — UI-волна.
SMS: живые отправки Mobizon не триггерились — `otp_codes` сеялись напрямую через service_role, проверялся только `action=check/register`.

**Итог: PASS 5 / FAIL 0 / PARTIAL 0 / SKIP 1** (из 6 кейсов backend-слоя)

| ID | Вердикт | Evidence / причина |
|---|---|---|
| REG-OTP-08 | PASS | Seed `otp_codes` (+70000001002, код 222222, attempts=0). 3 неверных check → каждый `«Неверный код — попробуйте ещё raz»`, attempts 1→2→3 (сверено чтением таблицы после каждого). 4-я попытка **верным** кодом → `«Превышено число попыток — запросите новый код»`, запись удалена (`[]`). 5-я попытка верным кодом → `«Код не найден — запросите новый»`. Полное совпадение с ожиданием. |
| REG-OTP-09 | PASS | Seed с `expires_at` в прошлом (2026-07-05T00:00Z). Check верным кодом → `{"verified":false,"error":"Код истёк — запросите новый"}`; запись удалена; повторный check верным кодом → `«Код не найден»` — переход невозможен даже при верном коде. TTL сверен с реальным конфигом (константа 300 с в edge-функции). |
| REG-PIN-03 | PASS | `action=register` (+70000001003, pin) → `{"success":true}`, auth-пользователь создан, триггер `fn_handle_new_auth_user` создал ровно 1 строку `public.users`. Повторный `action=register` тем же номером → `{"error":"Этот номер уже зарегистрирован"}`, второй аккаунт не создан. UI-часть («остаётся на шаге / уход на /login») — за UI-волной. |
| REG-ROLE-02 | SKIP | `status:blocked:IDENTITY-06` — known gap (requires_approval у типов организаций не реализован, IMPL_DEBT.md:67). Не исполнялся по правилу blocked→SKIP. |
| REG-SUB-04 | PASS | Под JWT QA-пользователя: первая регистрация (farmer, БИН 000000777701, предпроверено — свободен) → `{"org_id":…,"farm_id":…}`. Повторный вызов `rpc_register_organization` с тем же БИН → `P0001 "BIN_DUPLICATE: organization with BIN 000000777701 already exists"`; побочных строк от упавшего вызова нет (org «QA-REG-Ферма-2» не создана — атомарность подтверждена). Toast-текст — UI-волна. |
| REG-SUB-07 | PASS | Тот же пользователь зарегистрировал вторую орг (mpk, без БИН) → success, первая орг не сломана (organizations, роли — целы). `rpc_get_my_context` вернул ОБЕ организации (farmer c farm + membership `registered`, mpk c membership `registered`), обе роли `owner`. Канон MS1 D-IDM-2 (M:N) подтверждён кодом. |

## Evidence-детали

- bird-otp контракт полностью соответствует кейсам: тексты ошибок дословно совпадают («Неверный код — попробуйте ещё раз», «Превышено число попыток — запросите новый код», «Код истёк — запросите новый», «Этот номер уже зарегистрирован»).
- Инкремент `attempts` на бэкенде подтверждён построчным чтением `otp_codes` между попытками.
- `rpc_register_organization` атомарен: при BIN_DUPLICATE ни одной побочной строки.

## Находки (кандидаты в дефекты / IMPL_DEBT)

1. **P8-гэп: OTP-параметры захардкожены в edge-функции.** TTL (300 c), лимит попыток (3), resend-кулдаун (60 c — UI) не имеют дома в БД; README qa требует «сверять конфиг с БД», но сверять не с чем. Предложение: строка долга (identity, standards-as-data) или отдельная конфиг-таблица/строка. Не FAIL — поведение совпало с ожиданиями кейсов.
2. **`user_organization_roles.is_primary` всегда true.** `rpc_register_organization` (d01_kernel.sql:3383) ставит `is_primary=true` каждой новой связке — после REG-SUB-07 у пользователя ДВЕ primary-организации. Семантика «primary» вырождается; уникального ограничения на (user_id, is_primary=true) нет. В IMPL_DEBT не зарегистрировано → новая находка. Влияет на маршрутизацию оболочек (ONB-ROUTE-03).
3. **Нормализация телефона расходится по слоям.** Supabase auth / `public.users.phone` хранит `70000001003` (без `+`), `organizations.phone` — `+7…`, `otp_codes.phone` — `+7…`. Прямых падений нет, но `rpc_get_my_context.phone` отдаёт номер без `+`, а REG-OTP-04 ожидает E.164 `+7XXXXXXXXXX` «на бэкенд». Кандидат в мелкий долг (identity, normalization).

## Предложения по кейсам

- REG-OTP-08/09: пометить в кейсах, что TTL/attempts — константы `bird-otp/index.ts`, а не БД-конфиг (пока не закрыта находка 1) — иначе инструкция «сверять с БД» невыполнима.
- REG-SUB-07: добавить в ожидание проверку `is_primary` (сейчас кейс молчит, а поведение спорное — см. находку 2).
- REG-PIN-03: «ожидаемое развитие — уход на /login» вынести в отдельный future-кейс UI, чтобы backend-вердикт не смешивался с нереализованным UX.

## Зачистка QA-данных (REST-режим, без транзакций)

Создано и удалено (обратный FK-порядок), финальный контроль — пусто:
- `otp_codes`: +70000001001, +70000001002 — удалены самой edge-функцией по ходу кейсов (проверено `[]`).
- `platform_events`: 2 строки (identity.organization.registered) — удалены.
- `audit_log`: 2 строки (появились каскадом от событий; первый DELETE organizations упал по FK `audit_log_organization_id_fkey` — дочищено) — удалены.
- `farms`: 1 — удалена. `memberships`: 2 — удалены. `user_organization_roles`: 2 — удалены. `organization_type_assignments`: 2 — удалены. `organizations`: 2 (QA-REG-Ферма, QA-REG-МПК) — удалены.
- `public.users`: 1 — удалён. auth-пользователь +70000001003 — удалён через admin API (HTTP 200).

Не удалённых остатков нет: контрольные выборки по префиксам `QA-REG-*` и диапазону `+7000000XXXX` пусты.
