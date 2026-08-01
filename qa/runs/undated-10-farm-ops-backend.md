# QA-прогон — 10-farm-ops · слой BACKEND/RPC (Ферма 2.0)

- **Дата:** 2026-07-23
- **Эпик/задача:** ARS-276 / F11 QA = ARS-288
- **Метод:** статическая верификация тел RPC + runtime-ACL (`has_function_privilege`) + метаданные RLS/грантов на **проде** (`mwtbozflyldcadypherr`), read-only. Мутирующих вызовов на прод НЕ делалось.
- **Скоуп прогона:** только backend/RPC-слой + грант/RLS-гигиена. UI-слой (FARM2-OV/TA/WK/SYNC/OFF) — `pending-run` (требует расширенного сида 86 голов + dev-server + браузер под seed-фермером; см. ARS-288 §Что).

## Итог: 7 PASS · 1 FAIL (Significant)

| Кейс | Вердикт | Заметка |
|---|---|---|
| FARM2-RPC-01 Обзор контракт §4 | ✅ PASS | as_of/herd/cycle/tasks/resources/attention/today/today_more_count 1:1 с §4.1–4.4; `burning=ends_in_days<=2` |
| FARM2-RPC-02 внимание §2.2/§2.6 | ✅ PASS | vocab `{open_animal,open_window,reschedule_today,open_resources}` ↔ Dok6 Slice8 §2.2 совпадает; дрейф #132 закрыт |
| FARM2-RPC-03 обход идемпотент+сброс | ✅ PASS | `on conflict (farm_id,walk_date)`; событие только на insert; суточный сброс §7 |
| FARM2-RPC-04 отклонение lazy+реплей | ✅ PASS | lazy `animals`; словарь P8; `client_event_id` replay-safe (F10) |
| FARM2-RPC-05 сдвиг случки future-only | ✅ PASS | обёртка guard'ит; completed/skipped фазы не двигаются §9.4 |
| FARM2-RPC-06 закрытие события | ✅ PASS | идемпотентно; `already_closed` |
| FARM2-RPC-07 RLS F2-таблиц | ✅ PASS | RLS enabled + `_read_own`/`_write_own` на 3 табл; `animal_event_types` = read_auth+admin_write |
| **FARM2-RPC-08 грант каскад-fn** | 🔴 **FAIL** | см. дефект ниже |

## Дефект FARM2-SEC-01 (Significant) — internal cascade fns anon/authenticated-executable

- **Что:** `fn_shift_phase_cascade(uuid,date,uuid)` и `fn_preview_cascade(uuid,date)` — `SECURITY DEFINER`, но `EXECUTE` выдан `PUBLIC`/`anon`/`authenticated` (подтверждено `has_function_privilege` = true для anon и authenticated по обеим).
- **Почему опасно:** `fn_shift_phase_cascade` НЕ содержит проверки владения (`fn_my_org_ids`). Единственный корректный вход — guard'нутая обёртка `rpc_shift_breeding_start` (org-check есть). Но внутреннюю функцию можно вызвать напрямую (supabase-js `.rpc('fn_shift_phase_cascade',…)`) с чужим `farm_phases.id` → сдвиг фаз/дат цикла чужой фермы, минуя изоляцию. `fn_preview_cascade` — cross-tenant read (превью каскада чужого плана), доступен даже `anon`.
- **Severity:** Significant (не Critical: эксплойт требует знания `farm_phases.id` UUID — не перечислим через API; урон = целостность дат, не утечка PII/финансы). `fn_preview_cascade` info-leak = Significant/Minor.
- **Корень:** D104-функции из `d05_ops_edu.sql`, старше секфикса ARS-279/PR #127 (тот покрыл `fn_feed_days_left` + 1 др. — теперь чистые). Совпадает с `security-definer-review-checklist` Trap 2b (Supabase default-privileges выдаёт authenticated; для внутренних fn нужен явный `revoke from authenticated`).
- **Фикс (DB Agent, аддитивно, в `d05_ops_edu.sql`):**
  ```sql
  revoke execute on function public.fn_shift_phase_cascade(uuid, date, uuid) from public, anon, authenticated;
  revoke execute on function public.fn_preview_cascade(uuid, date)          from public, anon, authenticated;
  ```
  Обёртка `rpc_shift_breeding_start` (SECURITY DEFINER) продолжит вызывать их как owner — регрессии UI нет. Аналогично проверить `fn_preview_cascade`-вызовы: если UI-превью зовёт его напрямую, завернуть в guard'нутый `rpc_preview_breeding_shift`.
- **Проверка после фикса:** `has_function_privilege('authenticated', 'public.fn_shift_phase_cascade(uuid,date,uuid)','EXECUTE')` → false; F8 «изменить старт случки» под seed-фермером всё ещё работает.

## Что НЕ прогонялось (остаток F11)
- UI-слой: FARM2-OV-01..06, TA-01..07, WK-01..03, SYNC-01, OFF-01..02 → `status:pending`.
- Живой cross-org SELECT под сессией фермера B (RLS в бою, не только метаданные).
- Блокер UI-прогона: расширение `scripts/seed_farmer.mjs` до референс-фермы 86 голов (ARS-288 §Что).

## Cross-check
- ⚠️ После фикса FARM2-SEC-01 — прогнать `./cross_check.sh` (изменение в d05).
