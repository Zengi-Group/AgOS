# 04 — Членство TURAN (MEM-*)

> Канон: **Microstep 2 (Membership FSM)** — 6 состояний
> `not_member / submitted / grace_period / active / expired / revoked`, переходы T1–T10.
> UI-контракт: Dok6-Slice2 (A01 очередь, A02 решение).
> Реальность: `TuranScreen.tsx`, MembDocsSheet, PayVznosSheet, MembershipQueue/Decision;
> `rpc_submit_membership_application`, `rpc_process_membership_application`,
> `rpc_pay_membership_dues`, `rpc_get_membership_queue` (d01_kernel.sql).
>
> **ГЛАВНОЕ РАСХОЖДЕНИЕ (IMPL_DEBT MEMBERSHIP-01/02/03/04/06, BREAKING):**
> задеплоенная схема не реализует канонический 6-state FSM: нет полей
> `state/grace_reason/grace_until/paid_until/tier/revoke_reason`, нет переходов T5–T10,
> нет cron-джобов таймаутов, нет audit-таблицы переходов. UI оперирует словарём
> `pending/approved/active/expiring/grace/expired/rejected/terminated`.
> Кейсы UI-отображения — active (рендер по статусу); кейсы канонических
> переходов — blocked:MEMBERSHIP-03 до имплементации.
>
> Конфиг: grace = 30 дней (обе ветки), tier по умолчанию 'standard', взнос на пилоте
> 120 000 ₸ (мок), срок оплаты после одобрения — 18 дней (UI-копирайт, сверить с конфигом).
> Маппинг из концепта: блок E → MEM-SUB/PAY/UI.

---

## MEM-SUB — подача заявки (T1)

#### MEM-SUB-01 · HAPPY · Подача документов на членство
`layer:ui+rpc` `canon:MS2-T1;Dok6S2` `impl:d01_kernel.sql:rpc_submit_membership_application` `auto:candidate:sql` `status:active`
- **Предусловие:** гейт Рынка открыт, нажата «Подать заявку».
- **Шаги:** в MembDocsSheet загрузить 3 обязательных документа (гос.регистрация с БИН, удостоверение руководителя, банковские реквизиты) → «Отправить на проверку».
- **Ожидание:** кнопка disabled до 3/3; файлы в bucket `membership-documents/{orgId}/docs/{slot}_{ts}.{ext}`; замена файла удаляет предыдущий файл слота; `rpc_submit_membership_application` создаёт заявку; статус членства → pending (канон: submitted).

#### MEM-SUB-02 · UNHAPPY · Файл больше лимита
`layer:ui` `canon:code` `impl:src/pages/cabinet/shell (MembDocsSheet)` `auto:none` `status:active`
- **Ожидание:** toast «Файл больше N МБ» (MAX_FILE_SIZE_MB); слот не заполнен.

#### MEM-SUB-03 · UNHAPPY · Не все документы
`layer:ui` `canon:code` `impl:MembDocsSheet` `auto:none` `status:active`
- **Ожидание:** кнопка неактивна; «Загрузите все обязательные документы (*)»; счётчик «2 / 3 готово».

#### MEM-SUB-04 · EDGE · Повторная подача при активной заявке
`layer:rpc` `canon:MS2-§2.5` `impl:d01_kernel.sql` `auto:candidate:sql` `status:active`
- **Канон:** одна активная (draft/submitted) заявка на организацию.
- **Ожидание:** ответ `PENDING_EXISTS` трактуется как успех (документы обновлены) — без ошибки пользователю.

#### MEM-SUB-05 · UNHAPPY · Заявка при активном членстве
`layer:rpc` `canon:code` `impl:d01_kernel.sql:3502` `auto:candidate:sql` `status:active`
- **Ожидание:** ошибка `ALREADY_ACTIVE` → toast «Членство уже активно» для ЛЮБОГО активного уровня, включая observer (на пилоте observer = активное членство).
- **Деплой 2026-07-07:** MEMBERSHIP-07 задеплоен — гейт сужен до `v_current_level <> 'registered'`, подтверждено прямым запросом к БД.

#### MEM-SUB-06 · EDGE · До одобрения записи членства нет (канон)
`layer:sql` `canon:MS2-T1` `impl:d01_kernel.sql` `auto:candidate:sql` `status:blocked:MEMBERSHIP-01`
- **Канон:** после T1 существует только MembershipApplication(submitted); запись AssociationMembership создаётся ТОЛЬКО при T2 (одобрение).
- **Проверка:** после подачи заявки в таблице членств нет строки организации.

#### MEM-SUB-07 · EDGE · Повторная подача после отклонения — без ограничений
`layer:rpc` `canon:MS2-D-MEM-4` `impl:d01_kernel.sql` `auto:candidate:sql` `status:active`
- **Канон:** reject возвращает в not_member; история попыток — отдельные записи MembershipApplication (append-only); количество повторов не ограничено.
- **Ожидание:** после отклонения кнопка «Подать заново» открывает сбор документов; новая заявка создаётся как новая запись.

---

## MEM-ADM — сторона админа (T2/T3, Dok6-Slice2 A01/A02)

#### MEM-ADM-01 · HAPPY · Очередь заявок A01
`layer:ui+rpc` `canon:Dok6S2-A01` `impl:MembershipQueue` `auto:none` `status:active`
- **Ожидание:** /admin/membership: список заявок (org_name, тип, регион, БИН, статус, дата); фильтры Все/Ожидает/На рассмотрении/Одобрено/Отклонено, по умолчанию — ожидающие; пагинация 20/стр; empty state «Нет заявок с таким статусом»; клик по строке → A02.

#### MEM-ADM-02 · HAPPY · Одобрение заявки (T2)
`layer:ui+rpc` `canon:MS2-T2;Dok6S2-A02` `impl:d01_kernel.sql:rpc_process_membership_application` `auto:candidate:sql` `status:active`
- **Шаги:** A02: карточка организации + документы → «Одобрить» → подтвердить в диалоге.
- **Ожидание:** заявка approved (reviewed_by/reviewed_at заполнены); toast «Заявка одобрена»; редирект в A01; событие `identity.membership.activated`. **Канон T2 дополнительно:** создаётся AssociationMembership(state=grace_period, grace_reason='pending_first_payment', grace_until=+30д, tier='standard') — эта часть blocked:MEMBERSHIP-01, у нас статус → approved.

#### MEM-ADM-03 · HAPPY · Отклонение заявки (T3)
`layer:ui+rpc` `canon:MS2-T3;Dok6S2-A02` `impl:rpc_process_membership_application` `auto:candidate:sql` `status:active`
- **Ожидание:** заявка rejected с причиной (reviewer_notes ≤1000 символов); членство НЕ создаётся; организация может податься заново (канон: возврат в not_member, D-MEM-4).

#### MEM-ADM-04 · UNHAPPY · Ошибки RPC решения
`layer:rpc` `canon:Dok6S2-RPC-03` `impl:rpc_process_membership_application` `auto:candidate:sql` `status:active`
- **Ожидание:** `APPLICATION_NOT_FOUND` (нет заявки), `ALREADY_DECIDED` (повторное решение), `INVALID_DECISION` (не approved/rejected), `FORBIDDEN` (не админ — код и канон Dok6-Slice2 отдают FORBIDDEN, не UNAUTHORIZED).

#### MEM-ADM-05 · EDGE · Заявка уже решена — экран A02
`layer:ui` `canon:Dok6S2-A02` `impl:MembershipDecision` `auto:none` `status:active`
- **Ожидание:** кнопки решения скрыты; показаны reviewed_by/reviewed_at/notes; бейдж «Решение принято DD.MM.YYYY».

#### MEM-ADM-06 · UNHAPPY · Не-админ на /admin/membership
`layer:ui+rpc` `canon:Dok6S2` `impl:RequireExpert/fn_is_admin` `auto:candidate:sql` `status:active`
- **Ожидание:** редирект на /cabinet с toast «Доступ запрещён»; RPC-уровень также отклоняет (см. SEC-GATE-03).

---

## MEM-PAY — оплата взноса (T4/T7/T9)

#### MEM-PAY-01 · HAPPY · Заявка одобрена — карточка оплаты
`layer:ui` `canon:code` `impl:HomeScreen/MarketScreen` `auto:none` `status:active`
- **Предусловие:** статус approved.
- **Ожидание:** на Главной карточка-решение «Заявка одобрена — оплатите взнос, чтобы открыть продажу» (срок «до <дата+18дн>»); на Рынке — плашка «Оплатите взнос», кнопки «+ Продать партию» нет.

#### MEM-PAY-02 · HAPPY · Оплата взноса (мок пилота)
`layer:ui+rpc` `canon:MS2-T4` `impl:d01_kernel.sql:rpc_pay_membership_dues` `auto:candidate:sql` `status:mock`
- **Шаги:** PayVznosSheet: выбрать способ (Kaspi Pay / карта / счёт) → «Оплатить 120 000 ₸».
- **Ожидание:** оплата — мок: `rpc_pay_membership_dues` поднимает уровень членства; членство → active; Рынок открывается («+ Продать партию» появляется); при недоступности RPC — локальный фолбэк с предупреждением в консоли. **Канон T4:** paid_until = дата+срок членства, grace_reason=NULL — blocked:MEMBERSHIP-01.

#### MEM-PAY-03 · HAPPY · Продление из expiring/grace
`layer:ui` `canon:MS2-T7` `impl:PayVznosSheet` `auto:none` `status:active`
- **Ожидание:** кнопка «Продлить» ведёт в PayVznosSheet в режиме «Продление членства»; после оплаты статус снова active.

#### MEM-PAY-04 · HAPPY · Восстановление из expired оплатой (T9, канон)
`layer:rpc` `canon:MS2-T9;D-MEM-5` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** expired — рекуррентное состояние: оплата возвращает в active БЕЗ нового одобрения админа.
- **Проверка:** оплата из expired → active; заявку подавать не требуется.

---

## MEM-FSM — канонические переходы и таймауты (T5–T10)

> Все кейсы этого блока — по канону MS2; код не реализует (MEMBERSHIP-03).
> При имплементации переводить в active и покрывать SQL-тестами в первую очередь.

#### MEM-FSM-01 · UNHAPPY · Таймаут первой оплаты (T5)
`layer:sql` `canon:MS2-T5` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** grace_period(pending_first_payment), grace_until наступил, оплаты нет → cron переводит в revoked, revoke_reason='first_payment_timeout'; capabilities OFF; восстановление только новой заявкой.

#### MEM-FSM-02 · EDGE · Просрочка продления (T6)
`layer:sql` `canon:MS2-T6;D-MEM-3` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** active, paid_until наступил → grace_period(renewal_overdue), grace_until=paid_until+30д; **capabilities остаются ON** (мягкий переход).

#### MEM-FSM-03 · UNHAPPY · Истечение grace продления (T8)
`layer:sql` `canon:MS2-T8` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** grace_period(renewal_overdue), grace_until наступил → expired; capabilities OFF; восстановимо оплатой (T9).

#### MEM-FSM-04 · UNHAPPY · Дисциплинарное исключение (T10)
`layer:sql` `canon:MS2-T10;D-MEM-5` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** админ переводит {active, grace_period, expired} → revoked с revoke_reason; оплата НЕ восстанавливает; только новая заявка → submitted → approve → grace_period.

#### MEM-FSM-05 · EDGE · Grace_period включает возможности (обе ветки)
`layer:rpc` `canon:MS2-D-MEM-3` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** membership_active = state IN ('active','grace_period') — в grace обеих причин продажа в TSP доступна.

#### MEM-FSM-06 · EDGE · Audit-trail переходов
`layer:sql` `canon:MS2-§4` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** каждый переход T1–T10 пишет запись в append-only лог переходов (state, state_changed_at, grace_*, paid_until, revoke_reason).

#### MEM-FSM-07 · EDGE · Cron обрабатывает пачку организаций
`layer:sql` `canon:MS2-§5` `impl:—` `auto:none` `status:blocked:MEMBERSHIP-03`
- **Канон:** ежедневный джоб; несколько организаций с одинаковым дедлайном обрабатываются за один прогон без пропусков.

---

## MEM-UI — статусы членства в кабинете

#### MEM-UI-01 · HAPPY · Статус pending в кабинете
`layer:ui` `canon:code` `impl:HomeScreen/MarketScreen` `auto:none` `status:active`
- **Ожидание:** на Главной в ярусе «Идёт само» карточка «Заявка на рассмотрении · ответ в течение 3 рабочих дней»; на Рынке гейт с тем же текстом; продажа закрыта.

#### MEM-UI-02 · UNHAPPY · Заявка отклонена
`layer:ui` `canon:code` `impl:HomeScreen` `auto:none` `status:active`
- **Ожидание:** карточка «Заявка отклонена» с причиной и кнопкой «Подать заново» → сбор документов заново.

#### MEM-UI-03 · EDGE · Членство истекает / grace
`layer:ui` `canon:code` `impl:HomeScreen` `auto:none` `status:active`
- **Ожидание:** карточки «Продлите членство» (expiring, до даты) / «Продлите членство — иначе доступ закроется» (grace); кнопка → PayVznosSheet «Продление членства».

#### MEM-UI-04 · UNHAPPY · Членство истекло
`layer:ui` `canon:code` `impl:MarketScreen` `auto:none` `status:active`
- **Ожидание:** «+ Продать партию» нет; примечание «Членство истекло. Текущие сделки можно довести до конца, новые партии — после оплаты»; активные сделки видны и управляемы; MembGate-шторка предлагает «Оплатить».

#### MEM-UI-05 · UNHAPPY · Членство прекращено
`layer:ui` `canon:code` `impl:HomeScreen` `auto:none` `status:active`
- **Ожидание:** карточка «Членство прекращено · Чтобы вернуться — подайте заявку заново» → флоу подачи документов с нуля (канон: revoked, D-MEM-5).

---

## MEM-NTF — уведомления о решении

#### MEM-NTF-01 · HAPPY · Уведомление об одобрении
`layer:rpc` `canon:Dok6S2-CEO-3;Dok4-§5` `impl:—` `auto:none` `status:future`
- **Канон:** RPC решения вставляет в `notifications` (channel='whatsapp', template `application_approved`: «Заявка одобрена! …»); воркер забирает через claim_pending_notifications, шлёт WhatsApp Cloud API, отмечает sent/failed.

#### MEM-NTF-02 · HAPPY · Уведомление об отклонении
`layer:rpc` `canon:Dok6S2-CEO-3;Dok4-§5` `impl:—` `auto:none` `status:future`
- **Канон:** template `application_rejected` с причиной и контактом.
