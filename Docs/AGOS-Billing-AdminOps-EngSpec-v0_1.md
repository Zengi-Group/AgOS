# Eng-Spec — Billing Iteration 2: Admin Subscription Ops + функциональное замыкание биллинга

> In-repo engineering spec (detailed intent). The thin synthesis lives in the Brain
> (`apex-brain/projects/agos/specs/membership-billing.md`) and POINTS here via `sources:`.
> Graphify indexes this file — entity/RPC/table names match SQL tokens.
> Apply order reminder: d01 → … → d11 → d12 → d13 → d14.

- **Brain synthesis:** [[projects/agos/specs/membership-billing]]
- **Linear epic:** ARS-202 (итерация 2 — дочерние задачи созданы 2026-07-16 по аудиту)
- **Canon domain owner:** Membership = Microstep 2; Feature Governance = Microstep 3; подписочная FSM = этот файл (+ d13_billing.sql = reality)
- **Status:** agreed (G2 итерации 2 закрыт CEO 2026-07-16 — см. DECISIONS_LOG D-BILL-*)

## G2-решения CEO (2026-07-16) — приняты, снимают все needs-decision
- **D-BILL-TRUTH-01:** источник истины = `membership_subscription.state`; `memberships.level` = legacy (заморожен, не удалять); `AssociationMembership.state` отдельной колонкой не строится. → мост-предикат (§1, ARS-263).
- **D-BILL-NOAPP-01:** подписка НЕ требует одобренной заявки (§2.3 (b) снят).
- **D-BILL-CRON-01:** renewals через `pg_cron` на проде; `grace_days`=3 в план (P8); прод-включение после провайдера.
- **D-BILL-MANUAL-01:** ручной приём оплаты админом — в пилот (§2.2, ARS-267).
- **D-BILL-REVOKE-01:** дисциплинарный revoke (MS2 T10) в пилот-скоуп — значение `'revoked'` в CHECK state (§2.2, ARS-267).

## 0. Контекст (из аудита 2026-07-16)

Итерация ARS-202..207 задеплоена (d13_billing, d14_governance, SubscribeSheet, BillingPlansAdmin),
но продуктовая петля разорвана:

1. Подписка **ничего не открывает**: TSP-гейты (SEC-GATE-MEMBERSHIP-01: `d07_ai_gateway.sql:1241`,
   `d07_ai_gateway.sql:1374`, `supabase/migrations/20260701150000_tsp_district_sort.sql:130`)
   проверяют только `memberships.level <> 'registered'`. `rpc_check_feature_access` — 0 вызывающих.
2. Кабинет/админка не видят подписку как источник статуса: `deriveMembership` читает только
   `level`+заявку; `membership_paid` в admin-RPC — только `level`.
3. `rpc_process_membership_renewals` никто не запускает: pg_cron НЕ установлен на проде, edge-шедулера
   нет → trialing вечен, FSM мертва.
4. Управления подписками в админке нет вовсе (только каталог планов).
5. Живая межорг-утечка старого флоу: `rpc_get_membership_status(p_organization_id)` — SECURITY DEFINER
   без единого guard, PUBLIC/anon-executable → кто угодно по org-UUID читает level, pending-заявку,
   is_restricted чужой организации (класс SEC-RPC-ORGTRUST-01).
6. SEC-GRANT-PUBLIC-01-остаток: на 7 RPC ARS-205/207 `revoke from anon` не снял PUBLIC execute
   (держится на внутренних guard; у `rpc_list_membership_plans` guard нет — anon читает прайс).

Сверка канон↔прод (2026-07-16): тела 10 функций d13/d14, политики и seed на проде идентичны канону
(хотфикс C1/C2/S1 на месте). `membership_subscription` на проде = 0 строк — новый флоу ещё никем не
использован, фиксы успевают до первого пользователя. Старый стек жив: memberships 36 (21 registered /
15 observer), 23 заявки, 39 организаций.

Этот спек закрывает 1–6 + admin-операции. Полный список дефектов — в Linear-задачах эпика ARS-202.

## 1. Data model (P1 — first)

Новых таблиц НЕТ. Только additive-колонки (P7):

| Таблица | Колонка | Тип | Зачем |
|---|---|---|---|
| `membership_payment` | `created_by uuid null references users(id)` | uuid | кто внёс ручной платёж (аудит; null = движок) |
| `membership_payment` | `note text null` | text | основание ручного платежа (обязателен в RPC при provider='manual') |
| `membership_payment` | `provider_ref` (уже есть) | — | № квитанции/референс Kaspi-перевода (обязателен в RPC при manual) |
| `membership_plan` | `grace_days integer not null default 3 check (grace_days between 0 and 60)` | int | P8: льготное окно — данные, не хардкод (сейчас `v_grace_days := 3` в движке) |

- Ownership (P2): `membership_subscription` создаёт орг (self-serve) или админ; обновляет движок
  (renewal) + админ-RPC; авторитет при конфликте = движок (FSM), админ-операции идут через RPC с событиями.
- «Один trial на организацию»: НЕ новая колонка — правило считается из истории
  (`exists (select 1 from membership_subscription where organization_id = X)` — терминальные строки
  хранятся, P12). Повторная подписка стартует сразу `active` с немедленным биллингом периода.
- Источник истины статуса членства (P4): **`membership_subscription.state` — канонический источник
  «оплачено/активно»**; `memberships.level` остаётся legacy-градацией старого стека (не удаляем — HS-2).
  Везде, где сейчас читается только level (гейты, derive, admin membership_paid), — предикат-мост:
  `level <> 'registered' OR exists live subscription (trialing|active|grace)`.

## 2. RPC (Dok 3 contract)

Все новые: `SECURITY DEFINER`, `set search_path = public, pg_temp`, гейт `fn_is_admin()` внутри,
ACL: `revoke from public; revoke from anon; grant to authenticated (guard внутри) + service_role`
(урок SEC-GRANT-PUBLIC-01 — `revoke from anon` недостаточно). Регистрация в `rpc_name_registry` (D-NEW-A).
Существующие сигнатуры НЕ меняются (P7) — только тела (мост-предикаты, trial-guard).

### 2.1 Read (admin)

| RPC | Сигнатура | Возврат |
|---|---|---|
| `rpc_admin_list_subscriptions` | `(p_state text default null, p_plan_code text default null, p_search text default null, p_limit int default 50, p_offset int default 0)` | jsonb `{total, counts_by_state:{trialing,active,grace,past_due,expired,canceled}, rows:[{…sub, org_name, org_bin, plan_title, last_payment_at}]}`; поиск по названию/БИН орг; сортировка `next_billing_at asc nulls last` |
| `rpc_admin_get_subscription` | `(p_subscription_id uuid)` | jsonb `{subscription, plan, organization:{id,name,bin}, membership_level, payments:[последние 20], events:[последние 20 platform_events по entity_id]}` |
| `rpc_admin_list_membership_payments` | `(p_organization_id uuid default null, p_status text default null, p_from timestamptz default null, p_to timestamptz default null, p_limit int default 50, p_offset int default 0)` | jsonb `{total, sum_succeeded, rows:[{…payment, org_name, plan_code}]}` |

### 2.2 Write (admin) — каждая операция публикует события и оставляет след

| RPC | Сигнатура | Семантика |
|---|---|---|
| `rpc_admin_record_manual_payment` | `(p_subscription_id uuid, p_amount numeric, p_reference text, p_note text)` | MS2 authority «Billing / manual admin confirm» — НЕ тихий admin-override: `p_reference`+`p_note` обязательны, пишется `membership_payment(provider='manual', status='succeeded', provider_ref, created_by=fn_current_user_id(), note)`, период катится как success-ветка движка: `state→'active'`, `current_period_start = greatest(current_period_end, now())` бейз, `+billing_period`, `next_billing_at = новый period_end`. События: `membership.payment.succeeded` (payload.provider='manual') + `membership.subscription.renewed` + `entitlements.invalidated` (если доступ восстановлен из past_due/expired) |
| `rpc_admin_extend_subscription` | `(p_subscription_id uuid, p_days integer, p_note text)` | комп/жест: `check p_days between 1 and 90`, `p_note` обязателен; `current_period_end += days`, `next_billing_at += days`; из `grace/past_due/expired` → `state='active'` (реактивация без оплаты — осознанная админ-власть). Событие `membership.subscription.extended` payload `{days, note}` (+`entitlements.invalidated` при восстановлении доступа) |
| `rpc_admin_change_subscription_plan` | `(p_subscription_id uuid, p_new_plan_code text)` | эффект со следующего периода: меняется `plan_code`; `price_snapshot` НЕ трогаем (перетарификация произойдёт в движке при следующем продлении: snapshot := новая plan_price). Немедленной доплаты/возврата нет (просто и юр-чисто). Событие `membership.subscription.plan_changed` |
| `rpc_resume_org_membership` | `(p_organization_id uuid)` | снять `cancel_at_period_end=false` у live-подписки (undo отмены до конца периода). Guard: member-or-admin (симметрично cancel, S3). Событие `membership.subscription.resumed` |

Reuse без изменений: `rpc_cancel_org_membership` (админ проходит guard),
`rpc_subscribe_org_membership` (админ может оформить за орг).
Self-serve `rpc_change_membership_plan` (долг приёмки ARS-205) — отдельная Backlog-задача, не этот слайс.

### 2.3 Правки тел существующих RPC (сигнатуры не трогаем)

- `rpc_subscribe_org_membership`: trial-guard «один trial на орг» (история подписок → старт `active` c
  `next_billing_at = now()` и немедленным прогоном charge при первом renewal-тике; или явный charge в момент
  подписки — решение при имплементации, приёмка: второй trial невозможен). **Заявка НЕ требуется**
  (D-BILL-NOAPP-01): подписка самодостаточна, связь с `membership_applications` не вводим.
- `rpc_process_membership_renewals`: `v_grace_days` → `mp.grace_days` (из плана).
- Гейты SEC-GATE-MEMBERSHIP-01 (3 места) + `membership_paid` в admin_user_management + derive-цепочка
  кабинета: предикат-мост из §1.

## 3. Events (Dok 4)

Уже эмитятся, но НЕ зарегистрированы в Dok 4 (флаг в d13): `membership.subscription.started`,
`.canceled`, `.renewed`, `.expired`, `membership.payment.succeeded`, `.failed`, `entitlements.invalidated`.
Новые в этом спеке: `membership.subscription.extended`, `.plan_changed`, `.resumed`.
Задача канон-синка: зарегистрировать все 10 в Dok 4 одним проходом + решить notification-шаблоны
(минимум: `subscription.expired` и `payment.failed` — уведомление владельцу орг; остальное — без шаблона).

## 4. UI contract (Dok 6) — админ-зона (neutral `.light`, lucide, D-UI-TOPBAR-01)

Расширение существующего раздела биллинга (`/admin/billing/plans`, Sidebar «Планы членства», icon CreditCard).
Роут-схема: `/admin/billing/{plans|subscriptions|payments}`; топбар-табы через `useSetTopbar({tabs})`
(паттерн RationPage), titleIcon = CreditCard (= Sidebar).

### Экран «Подписки» (`/admin/billing/subscriptions`)
- KPI-строка: активные · в триале · grace+past_due (риск) · истекают ≤7 дней · сумма succeeded-платежей за 30 дней.
- Фильтры: чипы state (все/trialing/active/grace/past_due/expired/canceled), поиск (название/БИН), фильтр плана.
- Таблица: Организация · План · Состояние (badge) · Период до (current_period_end) · След. списание ·
  Автопродление (или «отменится DD.MM») · Цена (snapshot, mk-mono на цифрах) · [строка → карточка].
- Состояния: loading skeleton / error с retry (НЕ пустой список — урок B7) / empty («Подписок пока нет»).

### Карточка подписки (drawer поверх списка)
- Шапка: орг + план + state-badge + период.
- Действия: **Принять оплату вручную** (форма: сумма prefill=price_snapshot, № квитанции*, основание*) ·
  **Продлить (комп)** (дни 1–90*, основание*) · **Сменить план** (select планов; подпись «со следующего периода») ·
  **Отменить** (radio: в конце периода / немедленно + confirm) · **Возобновить** (если cancel_at_period_end).
- История платежей: таблица последних 20 (дата · сумма · статус · провайдер · референс · кто внёс).
- Каждое действие: confirm-шаг, disabled-on-submit, тост успеха, рефетч карточки+списка.

### Экран «Платежи» (`/admin/billing/payments`)
- Фильтры: статус, провайдер, период дат, поиск орг; итог `sum_succeeded` за фильтр.
- Таблица: Дата · Организация · Сумма · Статус · Провайдер · Референс · Кто внёс (для manual).

Антимонопольный дисклеймер (ст. 171) в админке не требуется (не reference prices TSP; членские взносы).
В кабинете (SubscribeSheet) — проверить наличие по приёмке ARS-207 (аудит: строки дисклеймера в шите НЕ найдено — включено в фикс-задачу).

## 5. Slices → Tasks

Дом задач — Linear, эпик ARS-202 (итерация 2). Здесь — состав; acceptance в задачах.

| Task | Tier | Суть |
|------|------|------|
| BILL-F0 🔴 SEC: rpc_get_membership_status — guard + revoke public/anon (живая утечка) | semantic | паттерн VET-02/C1: `fn_my_org_ids OR fn_is_admin OR service_role`; URGENT |
| BILL-F1 источник истины: мост подписка→гейты/derive/admin_paid + реальные даты в кабинете | semantic | закрывает 🔴 «подписка ничего не открывает» + B1/B2/B6 |
| BILL-F2 включить pg_cron (не установлен!) + job на renewals + grace_days в план (P8) | mechanical | закрывает 🔴 «движок никто не зовёт» |
| BILL-F3 trial один раз на орг | mechanical | закрывает 🔴 бесконечный trial |
| BILL-F4 SubscribeSheet: error/empty/retry, confirm отмены, resume, копия, R-9 mono, дисклеймер ст.171 | mechanical | B3/B5/B10/B11 + приёмка ARS-207 |
| BILL-F5 applies_org_type фильтрация каталога | mechanical | B4 |
| BILL-F6 админ-каталог планов: error-ветка, защита plan_code от тихой перезаписи | mechanical | B7/B8 |
| BILL-F7 канон-синк: Dok3 +12 RPC, Dok4 +10 событий, MS2-примечание, комментарии d12→d13/d14 (+registry.created_in), IMPL_DEBT реконсиляция (GOVERNANCE-01/02 устарели, мульти-org usage к GOV-ORGQUOTA-01), migration-бэкфилл d13/d14 в историю, brain spec | mechanical | долг документации |
| BILL-F8 ACL-проход биллинга: `revoke from public` на 7 RPC ARS-205/207 (канон d13 + прод) + RLS на rpc_name_registry (ERROR-advisor) | mechanical | SEC-GRANT-PUBLIC-01 точечно |
| BILL-A1 admin read-RPC (list/get/payments) | mechanical | §2.1 |
| BILL-A2 admin write-RPC (manual payment, extend, change plan, resume) + audit-колонки | semantic | §2.2 (needs-decision: Q2 manual payment) |
| BILL-A3 admin UI: табы биллинга + Подписки + карточка + Платежи | mechanical | §4; blocked by A1 (+A2 для действий) |
| BILL-B1 (Backlog) self-serve смена плана (rpc_change_membership_plan + шит) | semantic | долг приёмки ARS-205 |
| BILL-B2 (Backlog) платёжный провайдер + вебхуки (экс-«ARS-206b») | semantic | замена stub fn_charge_membership |
| BILL-B3 (Backlog) governance-интеграция: RPC зовут rpc_check_feature_access + rpc_record_feature_usage + entitlements в кабинете | semantic | полная M3-петля (сейчас 0 вызывающих; usage никто не пишет) |

## 6. Conflict / invariant check (G1 inputs)

- P7: ни одна существующая сигнатура не меняется; только тела + новые RPC + additive-колонки. ✓
- HS-2: старый флоу (`rpc_pay_membership_dues`, PayVznosSheet, level-stack) НЕ удаляется — вход из UI
  уже deprecated (memberAct→subscribe), код остаётся. ✓
- MS2 authority matrix: admin не «помечает оплату прошедшей» тихо — manual payment идёт billing-path
  (обязательный референс+основание, аудит-строка в ledger, события). ✓
- S3 (CEO 2026-07-16): любой член орг управляет подпиской — resume симметричен cancel, не ужесточаем. ✓
- Ст. 171: планы = членские взносы ассоциации, не плата за сделки; дисклеймер у цены в кабинете (F4). ✓
- RLS: новые admin-RPC — SECURITY DEFINER c fn_is_admin-guard; ledger-таблица уже RLS read-own. ✓
- ✅ CEO-вопросы G2 закрыты 2026-07-16 (D-BILL-TRUTH/NOAPP/CRON/MANUAL/REVOKE-01). Остаётся один
  не-блокирующий: судьба «observer»-орг старого level-stack (36 memberships) — когда/как выводится
  (мост-предикат делает их членами по level, синхронизация с подпиской — отдельный слайс миграции).

## 7. Verification (G3 inputs)

- `cross_check.sh` 0 critical; новые RPC в registry (CHECK 7); CHECK 5 (organization_id) — admin-RPC
  по subscription_id вносятся в whitelist осознанно (глобальный админ-скоуп) либо принимают org-параметр.
- ACL-проверка на живой БД: `proacl` новых функций НЕ содержит PUBLIC (`revoke from public` применён),
  anon=false; write-RPC service/admin-only фактически.
- FSM-прогон на staging-данных: trialing→(cron)→active→grace→past_due→expired; manual payment из
  past_due восстанавливает active + entitlements.invalidated.
- Preview-прогон админ-экранов (список/карточка/действия) + SubscribeSheet после F1 (статус переживает reload).
- `graphify update .` после кода; reality↔intent сверка перед G3.
