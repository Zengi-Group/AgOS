# Прогон qa/scenarios/02-auth.md (backend-слой) — 2026-07-05

Окружение: staging (REST-режим: SUPABASE_URL + service_role из .env; живых клиентов нет), коммит b7b8cf4.
Волна: backend — только `layer:sql|rpc|e2e`; кейсы `ui`/`ui+rpc` → SKIP(ui-wave), их прогоняет UI-волна.
Конфиги (фактические): OTP TTL = 300 s, MAX_ATTEMPTS = 3 — захардкожены в `supabase/functions/bird-otp/index.ts` (в БД конфиг-таблицы для OTP нет; `tsp_config` содержит только TSP-тайминги). SMS через Mobizon НЕ триггерились: `action=send` не вызывался, OTP-строки сажались напрямую в `otp_codes`.

Итог: **PASS 2 / FAIL 0 / PARTIAL 0 / SKIP 8** (из 10 кейсов файла)

| ID | Вердикт | Evidence / причина |
|---|---|---|
| AUTH-LOG-01 | SKIP | layer:ui+rpc → ui-wave |
| AUTH-LOG-02 | SKIP | layer:ui → ui-wave |
| AUTH-LOG-03 | SKIP | layer:ui → ui-wave |
| AUTH-LOG-04 | SKIP | layer:ui → ui-wave |
| AUTH-RST-01 | SKIP | layer:ui+rpc → ui-wave |
| AUTH-RST-02 | PASS | Предусловие подтверждено: `rpc/get_auth_user_id_by_phone(+70000001042)` → `null`. `POST functions/v1/bird-otp {action:reset_pin, phone:+70000001042, newPin:9999}` → `{"error":"Пользователь с этим номером не найден"}`. PIN не изменён (пользователя нет, updateUserById не достигается — ветка index.ts:175 возвращает до update). |
| AUTH-RST-03 | SKIP | layer:ui → ui-wave |
| AUTH-RST-04 | PASS | Все 4 ветки `action=check` (общая edge-функция ⇒ покрывает REG-OTP-07…09): (a) без записи → `{"verified":false,"error":"Код не найден — запросите новый"}`; (b) неверный код при живой записи (+70000001043, code=111111, check=222222) → «Неверный код — попробуйте ещё раз», attempts 0→1; (c) попытки 2–3 → attempts=3; 4-я попытка с ВЕРНЫМ кодом → «Превышено число попыток — запросите новый код», запись удалена (REST-select → `[]`), повторный верный код → «Код не найден»; (d) истёкшая запись (+70000001044, expires_at −10 мин, верный код 555555) → «Код истёк — запросите новый», запись удалена. |
| AUTH-ADM-01 | SKIP | layer:ui → ui-wave |
| AUTH-ADM-02 | SKIP | layer:ui → ui-wave |

## Зачистка QA-префиксов

Создавались только строки `otp_codes` с телефонами QA-диапазона +70000001043, +70000001044 — обе удалены самой edge-функцией по ходу кейсов (delete on exhaust/expire), финальный select `otp_codes?phone=like.+7000000*` → `[]`. Auth-пользователи не создавались. Не удалено: ничего.

## Находки (кандидаты в дефекты / IMPL_DEBT)

1. **P8-кандидат: OTP-конфиг захардкожен.** `OTP_TTL_SECONDS=300` и `MAX_ATTEMPTS=3` — константы в `supabase/functions/bird-otp/index.ts:11-12`, конфиг-таблицы в БД нет. REG-OTP-09 формулирует «TTL из конфига» — конфига как данных не существует. В IMPL_DEBT.md не зарегистрировано (grep otp/mobizon — пусто) → новая находка, предлагаю строку долга (standards-as-data, P8).
2. **Наблюдение (не дефект по кейсам):** в `otp_codes` лежит чужая протухшая строка `+77777777777` (expires 2026-07-01) — записи чистятся только лениво при `action=check`, TTL-свипера нет. Истёкшие коды накапливаются; риска нет (проверка expires_at на чтении), но таблица растёт.

## Предложения по кейсам

- **AUTH-RST-04** ссылается на «REG-OTP-07…09» — при backend-прогоне это фактически один и тот же прогон общей edge-функции; предлагаю в 01-registration.md пометить REG-OTP-08/09 тегом `auto:` на будущий SQL/REST-скрипт из этого прогона (шаги воспроизводимы без SMS).
- **AUTH-RST-02**: ожидание «PIN не изменён» при несуществующем пользователе неверифицируемо напрямую (нечего проверять) — формулировка ок, но проверяемая часть = точный текст ошибки; так и прогнано.
