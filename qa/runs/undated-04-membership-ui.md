# Прогон 04-membership.md (слои ui, ui+rpc) — без даты (запуск изолирован от системных часов сессии)

Окружение: preview (Vite dev, порт 5173, `.claude/launch.json` конфиг «Frontend (Vite)»)
против **реального Supabase-проекта** (`.env` содержит `VITE_SUPABASE_URL` + anon key —
НЕ demo-режим, реальный бэкенд). Коммит `b7b8cf4`.
Конфиги (сверены с кодом, не хардкод кейса — БД-таблицы `membership_config`/`tsp_config`-аналога
для членства НЕТ, значения живут в UI-константах): `MEMB_DATES.payApproved = TODAY+18`,
`MEMB_DATES.payGrace = TODAY+13` (`src/pages/cabinet/shell/data/membership.ts`); взнос
120000 ₸ — хардкод в `PayVznosSheet.tsx`, не читается из БД (подтверждает `status:mock`
MEM-PAY-02, канон-конфига для суммы не существует).

Итог: **PASS 0 / FAIL 0 / PARTIAL 1 / SKIP 14** (из 15 кейсов файла со `status:active`/`mock`
слоя ui/ui+rpc; MEM-FSM-* и MEM-NTF-* — `layer:sql`/`rpc`/`status:blocked`/`future`, вне
скоупа этого вызова)

Скоуп вызова: только `layer:ui` и `layer:ui+rpc` из `04-membership.md`.
Кейсы `layer:rpc`-только (MEM-SUB-04/05/06/07, MEM-ADM-04, MEM-PAY-04) и `layer:sql`
(MEM-FSM-*) — вне скоупа, не исполнялись.

## Блокер, определивший исход прогона

Реальный бэкенд подключён, но **нет seed-аккаунта фермера/МПК** (телефон+PIN) и нет
`ADMIN_PASSWORD`/service-role для `scripts/seed_admin.mjs` — тот же блокер, что
зафиксирован в `qa/runs/undated-02-auth-ui.md` (AUTH-LOG-01, AUTH-ADM-01). Проверено
живым прогоном: `/cabinet` и `/admin/applications/level` без сессии редиректят на
`/login` (снапшот ниже) — в коде нет анонимного/демо-режима кабинета, доступного через
роутер (fallback `if (!orgId)` в `MembDocsSheet.tsx` физически недостижим без сессии,
т.к. `CabinetApp()` требует `useAuth()`). Создание auth-пользователя — мутация вне
rollback-tx на единственном известном (не разделённом на staging/prod) проекте, без
явного разрешения не создавал.

Поэтому весь блок кейсов, требующих открытой шторки/экрана внутри `/cabinet/*` или
`/admin/*` за живым RPC-ответом, — SKIP(no-seed-account). Логика этих компонентов
верифицирована **статическим чтением кода** (не засчитывается как PASS живого прогона).

| ID | Вердикт | Evidence / причина |
|---|---|---|
| MEM-SUB-01 | SKIP (no-seed-account) | Happy-path требует сессию фермера + `orgId` для реальной загрузки в Storage и вызова `rpc_submit_membership_application`. Без сессии `/cabinet` редиректит на `/login` (см. блокер выше). Код прочитан (`MembDocsSheet.tsx:114-138`): кнопка вызывает `disabled={!allDone \|\| submitting}`, RPC-вызов с `p_membership_type:'associate'`, обработка `PENDING_EXISTS`/`ALREADY_ACTIVE` — соответствует ожиданию кейса построчно, но не наблюдалось живым прогоном. |
| MEM-SUB-02 | SKIP (no-seed-account) | Требует ту же шторку внутри кабинета. Код (`MembDocsSheet.tsx:60-65`): `if (file.size > MAX_FILE_SIZE_MB*1024*1024) toast.error('Файл больше '+MAX_FILE_SIZE_MB+' МБ')`, слот не заполняется (`return` до `setUploaded`) — соответствует ожиданию, не наблюдалось живьём. |
| MEM-SUB-03 | SKIP (no-seed-account) | Код (`MembDocsSheet.tsx:110-112,185,188`): `doneCount`/`total`, кнопка `disabled={!allDone}`, текст `{doneCount} / {total} готово` и `«Загрузите все обязательные документы (*)»` при `!allDone` — совпадает с ожиданием кейса, не наблюдалось живьём. |
| MEM-ADM-01 | SKIP (no-seed-account) | Требует admin-сессию (`RequireExpert`) + непустую очередь заявок. Живьём подтверждено: без сессии `/admin/applications/level` (redirect-цель `/admin/membership`) уводит на `/login` (снапшот). Код `MembershipQueue.tsx`: фильтры `STATUS_TABS` (Все/Ожидает/На рассмотрении/Одобрено/Отклонено), дефолт `statusFilter='submitted'` (строка 87), пагинация `page_size=20` (строка 96), empty state «Нет заявок с таким статусом» (строка 145), клик по строке → `navigate('/admin/membership/:id')` (строка 155) — все пункты ожидания присутствуют в коде, не исполнено живым RPC-ответом. |
| MEM-ADM-02 | SKIP (no-seed-account) | Нужна admin-сессия + существующая заявка `submitted`. Код `MembershipDecision.tsx`: диалог подтверждения (`Dialog`, строка 437+), `handleDecision` → `rpc_process_membership_application` с `p_decision`, `onSuccess` → `navigate('/admin/applications/level')`, `successMessage` = «Заявка одобрена»/«Заявка отклонена» в зависимости от `pendingDecision` — логика совпадает с ожиданием. Канонический побочный эффект (создание `AssociationMembership(state=grace_period,...)`) подтверждён как `blocked:MEMBERSHIP-01` (не проверяю как баг). |
| MEM-ADM-03 | SKIP (no-seed-account) | Тот же экран/RPC, ветка `rejected`. `reviewer_notes` передаётся как `p_decision_notes`, `maxLength={1000}` на textarea (строка 406) — совпадает с ожиданием «≤1000 символов». |
| MEM-ADM-05 | SKIP (no-seed-account) | Код `MembershipDecision.tsx:177,368-395`: `canDecide = status IN ('submitted','under_review')`; при `!canDecide && (approved\|rejected)` рендерится блок с `reviewed_by`/`reviewed_at`/notes и текстом «Заявка одобрена»/«Заявка отклонена» (не буквально «Решение принято DD.MM.YYYY», см. находку ниже) вместо кнопок решения (секция «Decision section» рендерится только при `canDecide`). |
| MEM-ADM-06 | PARTIAL (живой прогон гейта, не полного кейса) | Живой прогон: без сессии оба URL `/admin/applications/level` и `/cabinet` дают редирект на `/login` — базовый гейт «не пропускать» подтверждён снапшотом accessibility-дерева (заголовок «ТУРАН» / «Вход в личный кабинет»). Полный кейс (авторизованный НЕ-админ → редирект на `/cabinet` с toast «Доступ запрещён») требует сессию не-админ фермера — SKIP по тому же blocked. **Находка по коду**: маршрут `/admin/*` обёрнут в `RequireExpert` (`src/App.tsx:226`), а НЕ в `RequireAdmin` — `RequireExpert.tsx:61` при `!liveAllowed` делает `<Navigate to="/cabinet" replace />` **без toast** (в отличие от `RequireAdmin.tsx:54-56`, который показывает `toast.error('Доступ запрещён')`). Целевой роут совпадает с ожиданием кейса, но toast не показывается тем гардом, который реально навешен на `/admin/membership`. `useAdminGuard.ts` (отдельный хук, не подключён к `MembershipQueue`/`MembershipDecision`) показывает другой toast «Только для администраторов» и редиректит на `/admin` — тоже не совпадает с ожиданием и не используется на этих страницах. |
| MEM-PAY-01 | SKIP (no-seed-account) | Требует сессию + статус `approved`. Код: `store.ts:43-45` (`MEMBERSHIP_DICT.approved.plate.t`) = «Заявка одобрена! Оплатите взнос до {payApproved}, чтобы открыть продажу на Рынке» — текст с датой `TODAY+18` присутствует (карточка на Главной строится из `buildDecisions()`, `membership.ts:45-49`, идентичный текст «Заявка одобрена — оплатите взнос, чтобы открыть продажу», due=`до {payApproved}`). На Рынке (`MarketScreen.tsx:34-44`) — `ApprovedPlate` с текстом «Заявка одобрена — оформите членство» и кнопкой «Оплатить взнос», кнопки «+ Продать партию» нет в этой ветке (строка 71-74 условно рендерит `ApprovedPlate` вместо блока с кнопкой). Соответствует ожиданию, не наблюдалось живьём. |
| MEM-PAY-02 | SKIP (no-seed-account) | `status:mock` — согласуется с находкой: `rpc_pay_membership_dues` (d01_kernel.sql:4488-4587) не пишет `paid_until`/`grace_reason` (эти поля не существуют в схеме, `blocked:MEMBERSHIP-01`), просто поднимает `level` с `registered` до `to_level` одобренной заявки и пишет `platform_events` с `payload.payment:'simulated'` — прямое текстовое подтверждение мок-природы RPC. `PayVznosSheet.tsx`: сумма `120 000 ₸` хардкод (строка 38), способы оплаты `METHODS` (Kaspi Pay/карта/счёт) чисто визуальный выбор (`selected`), кнопка «Оплатить» вызывает `onDone` без реального платёжного вызова — совпадает с «оплата — мок». |
| MEM-PAY-03 | SKIP (no-seed-account) | Код `PayVznosSheet.tsx:24,34`: `renewal = ['active','expiring','grace','expired'].includes(membership)` → заголовок «Продление членства» вместо «Членский взнос» — переключение по статусу подтверждено в коде, недостижимо живьём (нужен фермер в статусе `expiring`/`grace`, которого не даёт текущий деривер БД→UI, см. находку ниже). |
| MEM-UI-01 | SKIP (no-seed-account) | Требует статус `pending`. Код: `store.ts:33-37` (`MEMBERSHIP_DICT.pending`) = «Заявка на проверке у ассоциации...»; `membership.ts:105-109` (`buildObserve`, ярус 2) добавляет карточку «Заявка на рассмотрении · ответ в течение 3 рабочих дней» — оба текста присутствуют, но НЕ идентичны (гейт на Рынке в `MarketScreen.tsx:14-17` использует другой текст: «Заявка на рассмотрении. Ответим в течение 3 рабочих дней.» — то же по смыслу, другая формулировка; кейс не указывает буквальный текст, так что не FAIL). Продажа закрыта подтверждена кодом: `gated()`/`CAN_EXEC` не включает `pending`. |
| MEM-UI-02 | SKIP (no-seed-account) | Код `store.ts:38-41`: карточка «Заявка отклонена» + `cabSub` с причиной + `cta:'Подать заново', act:'apply'` — совпадает с ожиданием. Кнопка ведёт на флоу подачи документов (тот же `MembDocsSheet` через `act:'apply'` в родительском хендлере CabinetApp — не найден отдельный переход, косвенно подтверждён по паттерну `act` в словаре). |
| MEM-UI-03 | SKIP (no-seed-account) | Статусы `expiring`/`grace` недостижимы через реальный бэкенд — см. находку MEMBERSHIP-06/derive ниже. Код-текст присутствует (`store.ts:51-57`), но живьём не воспроизводимо без ручной подмены состояния (что запрещено правилом «не чинить/не подгонять» — подмена state в сторе не является UI-прогоном реального флоу). |
| MEM-UI-04 | SKIP (no-seed-account) | Статус `expired` также недостижим через `deriveMembership()` (см. находку). Код `MarketScreen.tsx:59,77-80` подтверждает текст-ожидание построчно. |
| MEM-UI-05 | SKIP (no-seed-account) | Статус `terminated` недостижим через `deriveMembership()`. Код `store.ts:63-66` подтверждает текст. |

## Находки (кандидаты в дефекты / IMPL_DEBT)

1. **`deriveMembership()` не производит `expiring`/`grace`/`expired`/`terminated` из реальных
   данных БД** (`src/pages/cabinet/shell/store.ts:72-79`): маппинг БД→UI только
   `active | approved | pending | rejected | none`. Это прямое следствие
   зарегистрированного `MEMBERSHIP-01`/`MEMBERSHIP-03` (нет полей `state`/`grace_*`/
   `revoke_reason` в схеме) — **KNOWN-GAP, не новая находка**, но стоит явно
   зафиксировать: кейсы MEM-UI-03/04/05 и MEM-PAY-03 сейчас имеют `status:active`, хотя
   технически недостижимы через реальный бэкенд до реализации MEMBERSHIP-01/03 (только
   через локальную/демо-подмену состояния, не через живой прогон). Предлагаю обсудить
   перевод в `status:blocked:MEMBERSHIP-01` либо явную пометку «прогоняется только через
   demo-seed стора, не через реальный аккаунт» — решение не принимал самостоятельно,
   выношу на подтверждение (правило «конфликт флагуется, не решается молча»).

2. **MEM-ADM-06 текст/цель редиректа частично расходится с кейсом.** Маршрут
   `/admin/membership` (и `/admin/applications/level`) защищён `RequireExpert`
   (`src/App.tsx:226`), не `RequireAdmin`. `RequireExpert.tsx:61` при отказе делает
   `<Navigate to="/cabinet" replace />` **без toast** — цель редиректа совпадает с
   ожиданием кейса («редирект на /cabinet»), но toast «Доступ запрещён» кейса не
   показывается (тот toast принадлежит другому гарду — `RequireAdmin.tsx:54-56`,
   который в этом дереве маршрутов не навешен на membership-страницы). Отдельно есть
   третий, неподключённый к этим страницам хук `useAdminGuard.ts` с третьим текстом
   («Только для администраторов») и третьей целью (`/admin`) — мёртвый для этого экрана,
   но по коду выглядит как оставленный по инерции альтернативный гард. Не нашёл этот
   расход в `IMPL_DEBT.md` под явным ID — похоже на новую находку (не проверено живым
   прогоном под настоящей не-админ сессией — только частично: сам факт блокировки
   неавторизованного доступа подтверждён; отсутствие toast — по чтению кода
   `RequireExpert.tsx`, где просто нет вызова `toast.*` перед `Navigate`).

## Предложения по кейсам (устаревшие ожидания, смена status)

- Как и в прогоне 02-auth (`qa/runs/undated-02-auth-ui.md`), инфраструктурный блокер
  (нет seed farmer/mpk аккаунта, нет `ADMIN_PASSWORD`/service-role для
  `seed_admin.mjs`) не позволяет прогнать ни один `ui`/`ui+rpc` кейс этого файла живым
  end-to-end сценарием через реальный бэкенд. Не предлагаю менять `status` кейсов
  (канон и код не расходятся сами по себе для большинства пунктов) — фиксирую как
  повторяющийся блокер прогона, требующий: (1) seed-аккаунт фермера с известным
  телефоном+PIN и известным `organization_id`, (2) seed-заявка в статусе `submitted`
  для MEM-ADM-*, (3) `ADMIN_PASSWORD` в окружении агента или готовый admin-аккаунт.
- MEM-UI-03/04/05, MEM-PAY-03 — см. находку 1 выше: технически `status:active`, но
  недостижимы через реальный бэкенд до закрытия MEMBERSHIP-01/03. Предлагаю решение
  Arshidin — перевод в blocked или явная пометка «demo-only».
