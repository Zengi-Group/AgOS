# Прогон qa/scenarios/04-membership.md (backend-слой: sql/rpc/e2e) — 2026-07-05

Окружение: **staging REST** (`mwtbozflyldcadypherr.supabase.co`, service_role для сидинга,
RPC — anon key + JWT реальных QA-пользователей), коммит `b7b8cf4`.
DATABASE_URL отсутствовал → режим B (REST, без rollback-tx) с дисциплиной зачистки QA-префиксов.
Охват: только кейсы `layer:sql|rpc|e2e`; кейсы `ui` / `ui+rpc` (12 шт.: MEM-SUB-01..03,
MEM-ADM-01..03/05/06, MEM-PAY-01..03, MEM-UI-01..05) — UI-волна, здесь не прогонялись.
Конфиги: значения из шапки файла (grace 30д, взнос 120 000 ₸, 18 дней) — UI-копирайт;
backend-RPC членства конфигурируемых таймингов/лимитов в БД не используют (проверено по
телу функций d01_kernel.sql), сверять было нечего.

Сид (создано и зачищено): auth-пользователи `qa-mem-farmer@qa-turan.test` /
`qa-mem-admin@qa-turan.test`, public.users (QA-MEM Farmer/Admin, +70000000401/402),
организация QA-MEM-ORG-1 (kh), membership(farmer, registered), owner-роль, admin_roles(membership_admin).

**Итог: PASS 2 / FAIL 0 / PARTIAL 2 / SKIP 11 (из 15 backend-кейсов файла; всего в файле 27)**

| ID | Вердикт | Evidence / причина |
|---|---|---|
| MEM-SUB-04 | PASS | 1-я подача (level=registered) → HTTP 200, uuid заявки `341f1145`; повторная при pending → HTTP 400 `P0001 PENDING_EXISTS: an application is already pending for this organization`. Контракт RPC = канон MS2-§2.5 (одна активная заявка). «Трактуется как успех без ошибки пользователю» — клиентская обработка, проверяет UI-волна (MEM-SUB-01). |
| MEM-SUB-05 | PARTIAL | При level=`declared_supplier` → HTTP 400 `ALREADY_ACTIVE: organization already has active membership level declared_supplier` ✅. НО при level=`observer` — уровне, который на пилоте и есть «активное членство» (его выдаёт rpc_pay_membership_dues, UI открывает Рынок) — подача ПРОХОДИТ: HTTP 200, создана заявка `723c5256` observer→observer. См. находку F-1. |
| MEM-SUB-06 | SKIP | blocked:MEMBERSHIP-01 (запись memberships существует до одобрения — канон T2 не реализован). Не прогонялся как баг: known gap. |
| MEM-SUB-07 | PASS | Заявка №1 отклонена админом (reviewer_notes='QA-MEM test reject') → повторная подача HTTP 200, новый uuid `1636cc9c` ≠ `341f1145`; история org: 2 записи append-only (`rejected` + новая `submitted`), ограничений на повтор нет. Канон D-MEM-4 соблюдён. |
| MEM-ADM-04 | PARTIAL | `APPLICATION_NOT_FOUND` (несуществующий id) ✅; `INVALID_DECISION: must be approved or rejected, got maybe` ✅; `ALREADY_DECIDED: application already has status=rejected` (повторное решение) ✅; не-админ (farmer JWT) отклонён, но с кодом **`FORBIDDEN: admin access required`**, а кейс ожидает `UNAUTHORIZED`. Семантика гейта работает; расхождение имени кода — см. предложение C-1. |
| MEM-PAY-04 | SKIP | blocked:MEMBERSHIP-03 (T9 восстановление из expired не реализовано). |
| MEM-FSM-01 | SKIP | blocked:MEMBERSHIP-03 (T5 таймаут первой оплаты, cron нет). |
| MEM-FSM-02 | SKIP | blocked:MEMBERSHIP-03 (T6 просрочка продления). |
| MEM-FSM-03 | SKIP | blocked:MEMBERSHIP-03 (T8 истечение grace). |
| MEM-FSM-04 | SKIP | blocked:MEMBERSHIP-03 (T10 дисциплинарный revoke). |
| MEM-FSM-05 | SKIP | blocked:MEMBERSHIP-03 (grace_period capabilities). |
| MEM-FSM-06 | SKIP | blocked:MEMBERSHIP-03 (audit-trail переходов; частично компенсируется platform_events, см. ниже). |
| MEM-FSM-07 | SKIP | blocked:MEMBERSHIP-03 (cron-пачка). |
| MEM-NTF-01 | SKIP | status:future (WA-воркер). Попутно: reject-ветка УЖЕ вставляет notifications (см. side-effects). |
| MEM-NTF-02 | SKIP | status:future. Попутно: 2 записи `application_rejected` (whatsapp + in_app, delivery_status=pending) реально созданы RPC — при написании кейсов NTF учесть, что insert-часть уже реализована в rpc_process_membership_application. |

## Side-effects (доп. evidence)

- `platform_events` организации за прогон: 3× `identity.membership_application.submitted`
  (actor=farmer, is_audit=true) + 2× `identity.membership_application.decided` (actor=admin,
  is_audit=true) — события решений эмитятся на оба исхода, как в Dok4.
- `notifications` на reject: `application_rejected` whatsapp + in_app, delivery_status=pending
  (D-S2-2 insert-часть работает; отправка — future).

## Находки (кандидаты в дефекты / IMPL_DEBT)

- **F-1 (MEM-SUB-05):** `rpc_submit_membership_application` (d01_kernel.sql:3502) пропускает
  подачу при `level='observer'`: guard `ALREADY_ACTIVE` срабатывает только для уровней выше
  observer, при этом на пилоте именно observer = «членство активно» (rpc_pay_membership_dues
  поднимает registered→observer, UI открывает Рынок). Оплаченный член может создать вторую
  бессмысленную заявку observer→observer (to_level захардкожен 'observer'), которая снова
  попадёт в очередь админа. В IMPL_DEBT не зарегистрировано (MEMBERSHIP-01/04/06 — про словарь
  и сигнатуру, эту дыру не покрывают) → **настоящая находка**: завести строку долга или
  точечный фикс guard'а (`ALREADY_ACTIVE` при level <> 'registered' без pending-апгрейд-пути).
- **F-2 (наблюдение, вне кейсов):** `audit_log` имеет FK на organizations без каскада — при
  зачистке пришлось удалять `audit_log` вручную (5 строк аудита создались от QA-операций).
  Для QA-процедур учитывать в порядке зачистки; дефектом не считаю.

## Предложения по кейсам

- **C-1 (MEM-ADM-04):** заменить ожидание `UNAUTHORIZED` на `FORBIDDEN` — так в коде
  (комментарий функции: «Error codes: FORBIDDEN, INVALID_DECISION, APPLICATION_NOT_FOUND,
  ALREADY_DECIDED») и канон Dok6-Slice2 (строка Error codes RPC-03) UNAUTHORIZED вообще
  не упоминает. Проверить согласованно SEC-GATE-03 в 07-security-cross.md.
- **C-2 (MEM-SUB-05):** уточнить в кейсе, какой уровень считается «активным членством»
  на пилоте (observer после оплаты) — сейчас ожидание ALREADY_ACTIVE выполняется только
  для declared_supplier/standard_supplier. Связать с решением по F-1.
- **C-3 (MEM-NTF-01/02):** при переводе из future разделить: insert в notifications уже
  реализован (можно active для insert-части), future — только воркер/отправка.

## Зачистка

Удалено (обратный порядок FK, verify = 0 строк по всем): notifications (4), platform_events (5),
membership_applications (3), memberships (1), user_organization_roles (1), admin_roles (1),
audit_log (5, вне плана — FK-блок), organizations (1), users (2), auth-пользователи (2).
Хвостов QA-MEM в staging не осталось (проверено фильтрами по префиксу и org id).
SMS/WhatsApp не триггерились: pending-нотификации удалены до какого-либо воркера, Mobizon не вызывался.
