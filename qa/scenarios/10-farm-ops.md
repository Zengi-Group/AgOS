# 10 — Ферма 2.0: операционный кабинет (Обзор · Задачи · Стадо/Обход) — FARM2-*

> **Эпик:** ARS-276 (F11 QA = ARS-288). **Реальность (merged в main, авто-деплой Vercel):**
> - Каркас табов: `src/pages/cabinet/shell/farm/tabs.ts` + `FarmScreen.tsx` (F0a/F0b/StateC СОХРАНЕНЫ — HS-2).
> - Обзор: `src/pages/cabinet/shell/farm/OverviewScreen.tsx` + `data/farm-overview.ts` (F5/ARS-281, PR #131).
> - Задачи: `src/pages/cabinet/shell/farm/TasksScreen.tsx` + `data/farm-tasks.ts` + `data/farm-tasks-month.ts` (F6/F7/F8 = ARS-282/283/284, PR #134/#135/#136).
> - Стадо/Обход: `src/pages/cabinet/shell/farm/HerdScreen.tsx` + `data/farm-herd.ts` (F9/ARS-285, PR #137).
> - Офлайн: `src/pages/cabinet/shell/farm/data/outbox.ts` + read-cache (F10/ARS-286, PR #138).
> - Backend (на проде): `rpc_get_farm_overview`, `rpc_get_tasks_horizon`, `rpc_mark_walkthrough`,
>   `rpc_log_animal_event`, `rpc_close_animal_event`, `rpc_shift_breeding_start`, `_fn_farm_attention`,
>   `fn_feed_days_left` (F2/F3 = ARS-278/279, PR #124/#126/#127).
>
> **Канон приёмки:** `apex-brain/raw/agos-farm-cabinet-ux-handoff-2026-07-21.md` (§2 инварианты,
> §4–6 экраны, §7 живые связи, §9 бизнес-правила, §10 критерии приёмки);
> `Docs/AGOS-Ferma2-OpsCabinet-EngSpec-v0_1.md`; `Docs/AGOS-Dok6-Slice8-Ferma2-OpsCabinet.md` (§2.2 action-vocab).
>
> **Seed (обязателен для UI-кейсов):** `node scripts/seed_farmer.mjs` (телефон `+77010000001`, PIN `123456`).
> ⚠️ ARS-288 требует РАСШИРИТЬ сид до референс-фермы handoff §0 (86 голов в группах, активный
> план `cow_calf` с окнами/prep-задачами, номера животных, 1–2 открытых события, просрочка, окно
> «горит» ≤2 дн, остатки кормов) — без этого UI-состояния не демонстрируемы. Прогон под реальной
> authenticated-сессией (не service_role — ловушка FARM-02-bis), не только rollback-tx.
>
> **Инварианты приёмки (handoff §2, проверяются сквозь все кейсы):** норма↔факт (нет «ок» без данных
> за сегодня) · ввод по исключению · отклонение → действие в 1 тап · Обзор ничего не вводит (кроме
> чека задачи) · офлайн — штатный режим · приоритет §2.6 (животное → окно → просрочка → ресурсы) ·
> хиты ≥44px · статус = точка + цифра, без заливок.

---

## FARM2-RPC — контракты бэкенда (verified на проде 2026-07-23, rollback-tx / read-only)

#### FARM2-RPC-01 · HAPPY · Обзор: контракт rpc_get_farm_overview = зоны §4.1–4.4
`layer:rpc` `canon:handoff§4` `impl:rpc_get_farm_overview` `auto:sql` `status:PASS`
- **Ожидание:** JSON содержит `as_of` (метка §4.4); `herd{total,walkthrough_marked,marked_at,groups_count}` (зона Стадо §4.1); `cycle{phase_name,day,days_total,next_window{ends_in_days,burning}}` где `burning = ends_in_days<=2` (§4.1 Цикл + §9.2); `tasks{today_total,today_done,overdue}` (§4.1 Задачи); `resources{tracked,min_days_left,signals}` (§4.1 Ресурсы, `tracked=false` → «не ведётся» §4); `attention[]` (§4.2); `today[≤3]` + `today_more_count` (§4.3).
- **Проверено:** тело RPC 1:1 с §4; `today[].source ∈ {cycle,deviation,manual}` по `task_template_id`/`animal_event_id`. **PASS.**

#### FARM2-RPC-02 · HAPPY · «Требует внимания»: приоритет §2.6 + 4 action-типа §2.2
`layer:rpc` `canon:Dok6-Slice8§2.2` `impl:_fn_farm_attention` `auto:sql` `status:PASS`
- **Ожидание:** `_fn_farm_attention` эмитит РОВНО `action.type ∈ {open_animal, open_window, reschedule_today, open_resources}` с `kind ∈ {animal(1), window(2), task(3), feed(4)}`, сортировка `priority,ord` = §2.6.
- **Проверено:** deployed vocab ↔ Dok6 Slice8 §2.2 совпадают точно; `inspect`/`to_vet` — кнопки Обхода F9, НЕ action.type внимания (D-RPC-CONTRACT-SYNC-01, дрейф #132 закрыт). **PASS.**

#### FARM2-RPC-03 · HAPPY · Отметка обхода идемпотентна + суточный сброс §7
`layer:rpc` `canon:handoff§7` `impl:rpc_mark_walkthrough` `auto:sql` `status:PASS`
- **Ожидание:** `on conflict (farm_id, walk_date) do nothing`; повтор → `already_marked:true`, событие `ops.walkthrough.marked` эмитится только на реальной вставке; новые сутки = новый `walk_date` = «не отмечен» (§7 строка 7).
- **Проверено:** тело подтверждает. **PASS.**

#### FARM2-RPC-04 · HAPPY · Отклонение: lazy-животное + идемпотентность offline-реплея
`layer:rpc` `canon:handoff§6/§8` `impl:rpc_log_animal_event` `auto:sql` `status:PASS`
- **Ожидание:** создаёт `animals` лениво по tag (in_herd/active); тип из словаря `animal_event_types` (P8, `UNKNOWN_EVENT_TYPE` иначе); `client_event_id` уникален → повтор возвращает существующее `replayed:true` (F10 outbox-safe); событие `open` + `ops.animal_event.opened`.
- **Проверено:** тело подтверждает. **PASS.**

#### FARM2-RPC-05 · HAPPY · Сдвиг старта случки: будущее пересчитано, прошлое нетронуто §9.4
`layer:rpc` `canon:handoff§5.3/§9.4` `impl:rpc_shift_breeding_start` `auto:sql` `status:PASS`
- **Ожидание:** обёртка guard'ит org+active-plan; `fn_shift_phase_cascade` двигает только фазы `not in (completed,skipped)`; задачи сдвигаются на `delta` только для каскаднутых фаз (статусы scheduled/reminded/overdue); `no_change:true` при delta=0; событие `ops.farm_phase.rescheduled`.
- **Проверено:** тело подтверждает; завершённые фазы отклоняются (`raise`). **PASS.**

#### FARM2-RPC-06 · HAPPY · Закрытие события идемпотентно
`layer:rpc` `canon:handoff§8` `impl:rpc_close_animal_event` `auto:sql` `status:PASS`
- **Ожидание:** guard org; повтор → `already_closed:true`; `ops.animal_event.closed`; открытое событие держит строку внимания до закрытия (§4.2).
- **Проверено:** тело подтверждает. **PASS.**

#### FARM2-RPC-07 · SECURITY · RLS-изоляция новых таблиц F2 (фермер A ≠ B)
`layer:rpc` `canon:CLAUDE.md§Data-Isolation` `impl:animals,animal_events,farm_walkthroughs,animal_event_types` `auto:sql` `status:PASS`
- **Ожидание:** RLS enabled + политики `_read_own[SELECT]` / `_write_own[ALL]` на всех 3 операционных таблицах; `animal_event_types` = `read_authenticated[SELECT]` + `admin_write[ALL]` (P8 lookup).
- **Проверено:** `pg_class.relrowsecurity=true` + 2 политики на таблицу. **PASS.** (Живой cross-org SELECT под сессией B — добавить в UI-прогон.)

#### FARM2-RPC-08 · SECURITY · REGRESSION · Внутренние каскад-функции НЕ должны быть anon/authenticated-execute
`layer:rpc` `canon:security-definer-checklist(Trap2b)` `impl:fn_shift_phase_cascade,fn_preview_cascade` `auto:sql` `status:FAIL`
- **Ожидание:** `fn_shift_phase_cascade` / `fn_preview_cascade` — внутренние (единственный клиентский вход = guard'нутая обёртка `rpc_shift_breeding_start`); execute должен быть только у `service_role`/`postgres`.
- **Факт (FAIL):** `has_function_privilege('anon'|'authenticated', …,'EXECUTE') = true` для ОБЕИХ; `fn_shift_phase_cascade` НЕ содержит проверки владения (нет `fn_my_org_ids`) → любой authenticated может сдвинуть фазы чужой фермы прямым вызовом с чужим `phase_id`, минуя обёртку. См. дефект **FARM2-SEC-01** (Significant). Секфикс ARS-279/#127 покрыл 2 других farm-fn, эти D104-функции из d05 пропущены.

---

## FARM2-OV — экран «Обзор» (UI, §4 + §10) — status:pending-run

#### FARM2-OV-01 · HAPPY · 4 зоны контроля без скролла ≤30 сек (§4.1, §10)
`layer:ui` `canon:handoff§4.1/§10` `impl:src/pages/cabinet/shell/farm/OverviewScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** сетка 2×2: Стадо (86, точка+текст) · Цикл (фаза + «день N/M» + прогресс, ближайшее окно с остатком дней) · Задачи сегодня («N/M», «K просрочены» красным при K>0) · Ресурсы·корма (дни запаса или «не ведётся»). Крупная цифра mk-mono/tabular-nums. Всё видно без скролла на мобайле.

#### FARM2-OV-02 · EDGE · Зона «Стадо»: обход НЕ отмечен → янтарь «нет данных» (НЕ зелёное) (§4.1, §5-инвариант норма↔факт)
`layer:ui` `canon:handoff§4.1` `impl:OverviewScreen.tsx` `auto:none` `status:pending`
- **Предусловие:** сегодня обход не отмечен. **Ожидание:** янтарная точка + «обход не отмечен — нет данных»; НЕ зелёная, НЕ «ок». После отметки → зелёная «обход HH:MM · все группы».

#### FARM2-OV-03 · HAPPY · «Требует внимания»: сортировка §2.6 + действие в 1 тап (§4.2, §10)
`layer:ui` `canon:handoff§4.2/§2.6` `impl:OverviewScreen.tsx,data/farm-overview.ts` `auto:none` `status:pending`
- **Ожидание:** строки отсортированы животное→окно→просрочка→ресурсы; заголовок с №животных; кнопка-действие («Осмотр»/«К окну»/«На сегодня»/«Настроить») ведёт к цели за 1 тап. Маппинг action.type → §2.2.

#### FARM2-OV-04 · EDGE · Пусто → позитивная строка, блок не скрыт (§4.2)
`layer:ui` `canon:handoff§4.2` `impl:OverviewScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** `attention=[]` → зелёная точка + «Отклонений нет — техкарта идёт по плану»; блок виден, не молчит.

#### FARM2-OV-05 · HAPPY · «Сегодня — ближайшие»: 3 задачи + чек = мгновенный пересчёт (§4.3, §7)
`layer:ui` `canon:handoff§4.3/§7` `impl:OverviewScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** 3 невыполненные + «Ещё N — до вечера» → Задачи·Неделя; чекбокс (тап-зона 48px) → line-through + зона «Задачи сегодня» пересчитывается мгновенно (тот же факт).

#### FARM2-OV-06 · EDGE · Ресурсы «не ведётся» — без выдуманных цифр (§4.1)
`layer:ui` `canon:handoff§4.1` `impl:OverviewScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** `resources.tracked=false` → «не ведётся» + вход в настройку; никаких fake «дни запаса».

---

## FARM2-TA — экран «Задачи» (UI, §5 + §10) — status:pending-run

#### FARM2-TA-01 · HAPPY · Сегмент Неделя: блок «горит» первый, полоса недели, план дня (§5.1)
`layer:ui` `canon:handoff§5.1` `impl:src/pages/cabinet/shell/farm/TasksScreen.tsx,data/farm-tasks.ts` `auto:none` `status:pending`
- **Ожидание:** закреплённый «горит» (просрочки красн./окна янтарь) нельзя пролистать; полоса 7 дней с точками-нагрузкой, сегодня залит; план дня со счётчиком «N задач · K ✓», исполнитель-инициал; анатомия строки §4.3.

#### FARM2-TA-02 · HAPPY · ≤2 тапа с любого горизонта до задачи дня (§10)
`layer:ui` `canon:handoff§10` `impl:TasksScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** из Неделя/Месяц/Год до конкретной задачи дня ≤2 тапа.

#### FARM2-TA-03 · HAPPY · Сегмент Месяц: окна — ДИАПАЗОНЫ, не точки; prep-задачи; вехи (§5.2)
`layer:ui` `canon:handoff§5.2` `impl:TasksScreen.tsx,data/farm-tasks-month.ts` `auto:none` `status:pending`
- **Ожидание:** окна = янтарная заливка ВСЕХ дней окна (не одиночная дата); «Подготовиться к окнам» (дедлайн = старт окна, остаток дней mono); «Вехи месяца» → тап в окно/задачу; легенда; прошедшие дни приглушены.

#### FARM2-TA-04 · HAPPY · Сегмент Год: таймлайн фаз + правка «старта случки» (§5.3)
`layer:ui` `canon:handoff§5.3` `impl:TasksScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** вертикальный таймлайн (пройдено-галка / активная-карточка «день N/M» / будущее-контур+аннотация); единственная ручная правка «Старт случки · изменить» с припиской «пересчитает все окна».

#### FARM2-TA-05 · HAPPY · Сдвиг старта случки → пересчёт всех будущих дат, прошлое нетронуто (§7, §9.4, §10)
`layer:ui` `canon:handoff§7/§9.4` `impl:TasksScreen.tsx→rpc_shift_breeding_start` `auto:none` `status:pending`
- **Ожидание:** подтверждение → `rpc_shift_breeding_start` → Неделя/Месяц/Год перегенерированы на новые даты; прошедшие/завершённые фазы не сдвинуты; окна техкарты сдвинулись, ручной перенос отдельной задачи их НЕ двигал (см. TA-06).

#### FARM2-TA-06 · EDGE · Перенос просрочки «На сегодня» НЕ двигает окно техкарты (§5.1, §7)
`layer:ui` `canon:handoff§7` `impl:TasksScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** «На сегодня» переносит задачу в план дня; окно/веха на месте.

#### FARM2-TA-07 · EDGE · Пустая неделя (межфазье) → следующая веха, не пустота (§5.1)
`layer:ui` `canon:handoff§5.1` `impl:TasksScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** «Впереди: Пт 17 — открывается окно ИРТ/ПГ-3», не пустой экран.

---

## FARM2-WK — таб «Стадо» + режим «Обход» (UI, §6 + §10) — status:pending-run

#### FARM2-WK-01 · HAPPY · Отметка «Обход сделан» мгновенно меняет зону «Стадо» (§6.2, §7, §10)
`layer:ui` `canon:handoff§6.2/§7` `impl:src/pages/cabinet/shell/farm/HerdScreen.tsx,data/farm-herd.ts` `auto:none` `status:pending`
- **Ожидание:** кнопка «Обход сделан» ≥48px → зелёная галка «Обход сделан · HH:MM»; зона «Стадо» Обзора: янтарь→зелень (§7 строка 1).

#### FARM2-WK-02 · HAPPY · Добавление отклонения РОВНО за 2 шага (§6.4, §10)
`layer:ui` `canon:handoff§6.4` `impl:HerdScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** «+ Отклонение» → Шаг 1 «кто?» (чипы №, ≥44px, поиск) → Шаг 2 «что?» (чипы словаря `лежит·хромает·не ест·травма·признаки охоты·другое`) → выбор завершает: отклонение в список за сегодня + `rpc_log_animal_event` + +1 в «Требует внимания» Обзора + предложено действие (§7 строка 2).

#### FARM2-WK-03 · EDGE · Пусто → dashed «Пока ничего — это хорошо» (§6.3)
`layer:ui` `canon:handoff§6.3` `impl:HerdScreen.tsx` `auto:none` `status:pending`
- **Ожидание:** нет отклонений за сегодня → dashed-плейсхолдер, не пустой блок.

---

## FARM2-SYNC — живые связи (матрица §7) — status:pending-run

#### FARM2-SYNC-01 · HAPPY · Все 7 строк матрицы §7 отрабатывают немедленно (в т.ч. офлайн)
`layer:ui` `canon:handoff§7` `impl:OverviewScreen.tsx,TasksScreen.tsx,HerdScreen.tsx` `auto:none` `status:pending`
- **Ожидание (по строкам §7):** (1) обход→зона Стадо; (2) отклонение→+1 внимание+строка+карточка животного; (3) чек задачи→счётчики N/M везде; (4) перенос просрочки→план дня, окно на месте; (5) сдвиг случки→Месяц/Неделя перегенерированы; (6) окно закрылось с остатком голов→строка внимания; (7) новые сутки→Стадо «нет данных», обход «не отмечен». Optimistic-обновление, сервер догоняет.

---

## FARM2-OFF — офлайн-слой (§2.5, §10) — status:pending-run

#### FARM2-OFF-01 · HAPPY · Все экраны открываются из кэша с меткой «данные на HH:MM» (§10)
`layer:ui` `canon:handoff§2.5/§10` `impl:src/pages/cabinet/shell/farm/data/*` `auto:none` `status:pending`
- **Ожидание:** офлайн → Обзор/Задачи/Стадо читаются из кэша; в подзаголовке «данные на HH:MM» (из `as_of`). ⚠️ Проверять НЕ по innerText (ловушка QA-innertext-false-positive: opacity:0 не ловится) — по вычисленным стилям/скриншоту.

#### FARM2-OFF-02 · HAPPY · Outbox: отметки/отклонения/чек офлайн доезжают без дублей при связи (§8, §10)
`layer:ui` `canon:handoff§8` `impl:src/pages/cabinet/shell/farm/data/outbox.ts` `auto:none` `status:pending`
- **Ожидание:** офлайн-факты копятся в outbox с таймстампом момента действия; при связи реплеятся; `client_event_id` (отклонение) + `(farm_id,walk_date)` (обход) гарантируют идемпотентность — дублей нет (backend FARM2-RPC-03/04). Индикатор «офлайн — запишется» на Обходе; счётчик очереди.

---

## FARM2-SEC — сводка дефектов
- **FARM2-SEC-01 (Significant, OPEN):** `fn_shift_phase_cascade` + `fn_preview_cascade` execute доступны `anon`/`authenticated` без проверки владения → cross-tenant write/read мимо обёртки. Фикс = `revoke execute … from public, anon, authenticated` (DB Agent, аддитивно). См. FARM2-RPC-08.
