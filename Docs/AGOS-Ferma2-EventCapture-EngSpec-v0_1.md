# Eng-Spec / Slice — Ферма 2.0 · Диспетчер «Записать событие» + связь с «Обходом»

> **Статус:** agreed · **G2 закрыт CEO 2026-07-22** — CAP-1..4 (ARS-301..304) → Ready for Dev
> **Feature:** глобальный вход захвата событий фермы «Записать событие» как **диспетчер-роутер** (fan-out по типу факта), переработка по прототипу `FarmEventCta.tsx`.
> **Под-фича:** **ARS-300** (под эпиком ARS-276 · Ферма 2.0). CAP-1..4 = ARS-301..304 (Ready for Dev); под-эпики LIFECYCLE/CASCADE/WEIGHT/REPRO/ENTITY/VOICE = ARS-305..310 (Backlog).
> **Родительский канон:** `Docs/AGOS-Ferma2-OpsCabinet-EngSpec-v0_1.md` (F1, ARS-277) + `Docs/AGOS-Dok6-Slice8-Ferma2-OpsCabinet.md`.
> **Sources (reality, verified 2026-07-22):** `d01_kernel.sql` (animals, animal_events, animal_event_types, herd_events, herd_groups, rpc_log_animal_event, rpc_mark_walkthrough, rpc_close_animal_event, rpc_get_herd_board, rpc_get_animal_card, rpc_log_herd_event), `d04_vet.sql` (rpc_create_vet_case_from_event, vet_cases, treatment_logs), `d05_ops_edu.sql` (rpc_create_farm_task, rpc_get_farm_overview), `src/pages/cabinet/shell/farm/HerdScreen.tsx` + `data/farm-herd.ts`, `src/pages/cabinet/shell/screens/FarmScreen.tsx`, `src/pages/cabinet/shell/components/IonShellFrame.tsx`.

---

## 0. Решения CEO (locked на G1/G2, 2026-07-22)

| # | Развилка | Решение |
|---|----------|---------|
| DEC-1 | Архитектура входа | **Диспетчер-роутер.** Глобальный CTA как в прототипе, но каждая плитка **fan-out-ит в правильный дом по типу факта** (отклонения → `animal_events`; счёт/жизненный цикл → `herd_events`). НЕ плоский `animal_events`-поток. Сохраняет **D147** и инвариант «ввод по исключению». |
| DEC-2 | Scope | **Проектируем и планируем полностью** (все плитки, все дома, все контракты) + **разбиваем на задачи**. **Реализуем в этой итерации только «Проблема» + «Лечение».** Остальное — отдельные под-эпики. |
| DEC-3 | Авто-каскад задач (отёл → биркование + вет-осмотр + контроль сосания) | **В этой итерации — без авто-каскада.** Авто-каскад вынесен в **отдельный эпик** (зафиксирован, чтобы не потерять — §12 EPIC-CASCADE). |
| DEC-4 | Голосовой захват | **Отдельным тактом** через AI Gateway (Dok5 two-run, extract≠write). В этой спеке — только шов (§7), внутрь не проектируем. |

---

## 1. Что это и где стоит

### 1.1 Определение узла

**«Записать событие»** — единая точка входа фермера, чтобы за ≤2 действия зафиксировать факт из поля («отелилась 347-я», «347-я хромает», «пала 512-я»). Это **не журнал одного типа**, а **диспетчер**: плитка → определяет **класс факта** → пишет в **свой дом** через **свой RPC** → предлагает уместные пост-действия.

Прототип `FarmEventCta.tsx` (плитки + голос + каскады) — источник **UX-направления**, но его модель (`farmRecord`: 7 «kind»-ов в один reducer) канонически неверна: она сваливает адресные отклонения и групповые количественно-жизненные факты в один поток. Диспетчер это исправляет, сохраняя UX.

### 1.2 Инварианты, которые узел ОБЯЗАН сохранить

| Инвариант | Источник | Как соблюдаем |
|-----------|----------|---------------|
| **D147** — флоу захвата НИКОГДА не пишет `herd_events` из walkthrough-пути; `animal_events` (адресные отклонения по идентичности) ≠ `herd_events` (количественный журнал групп) | `d01_kernel.sql:6443-6447`, EngSpec §1.7 | Диспетчер fan-out-ит: отклонения → `rpc_log_animal_event`; количество/цикл → `rpc_log_herd_event` (**отдельный, не-walkthrough путь**). Оба дома живут раздельно. |
| **Ввод по исключению** — фермер вводит только то, что случилось; «зелёного без данных не бывает» | brain `farm-ops-cabinet.md`, Slice8 §0 | Диспетчер — необязательный вход; ничего не требует заполнять; норма считается из плана/обхода, а не из событий. |
| **Express-path ≤2 действия** | Slice8 §5, handoff §10 | «Проблема» = кто → что (2 тапа); тип коммитит сразу. |
| **P7 Additive** | CLAUDE.md | Новый CTA = аддитивный слот (`IonShellFrame footer`, сегодня не используется в `FarmScreen`); ни один существующий флоу/RPC-сигнатура не меняется. |
| **P8 — справочники как данные** | CLAUDE.md | Типы отклонений грузятся из `animal_event_types` (не хардкод — прототипный `FARM_TILES`/`classifyAnimal` c русскими строками нарушал P8). |
| **D61 — дозы только из `vet_products`** | CLAUDE.md, `d04_vet.sql` | «Лечение» = наблюдение → эскалация в vet_case; НИКАКИХ доз/диагнозов в этом слое. |
| **D-UI-FARMER-RULES-01** — фермерская зона: Phosphor-only через `PhIcon`, Geist, daylight-токены, flat cards; `mk-mono` только для цифр | `Docs/AGOS-DesignRules-FarmerCabinet.md` | Плитки рисуем `PhIcon` (Phosphor), **НЕ** инлайн-SVG прототипа (`Icon`/`FTileIc`) — см. §15. |

### 1.3 Что в scope / вне scope

**В scope этой спеки (проектируем полностью):** модель диспетчера, под-флоу всех 8 плиток, data-model reuse↔net-new, RPC-контракты, событийная шина, офлайн, декомпозиция, связь с «Обходом».

**Реализуем сейчас (DEC-2):** только **«Проблема»** и **«Лечение»**.

**Вне scope (по-прежнему, из родительского F1):** раскол-чек (режим 2), инвентаризация (режим 3), поголовный учёт как таковой, WhatsApp-канал. Плитки, зависящие от них, — design-only + под-эпики.

---

## 2. Точка входа и UX-каркас

### 2.1 Монтирование CTA

- Каркас модуля = `IonShellFrame` (label «Ферма») → `TabHead` → `.mk` → `.mk-tabs` (Обзор·Задачи·Стадо·Ещё) → тело активного таба (`FarmScreen.tsx:81-162`).
- `IonShellFrame` уже имеет **аддитивный слот `footer`** → рендерит `.sh-foot` — «sticky CTA над таб-баром» (`IonShellFrame.tsx:18,46`). `FarmScreen` сегодня footer **не передаёт** → добавление чистое (P7).
- **Решение:** глобальный «Записать событие» монтируется как `footer` каркаса `FarmScreen` (sticky, над нижним таб-баром `Главная·Ферма·Рынок·Сообщения`). Это ровно паттерн из скриншотов прототипа (плашка над баром).
- **Видимость:** CTA показывается только когда `!empty` (есть стадо/план). В состоянии-хуке SCR-F0a (профиля нет) — не показываем (нечего фиксировать).
- **Область охвата (open question OQ-1):** CTA живёт на всех 4 табах Фермы или только на Обзор/Стадо? Рекоменд.: на всех табах Фермы (единый вход — суть узла). Глобально-кабинетный (вне таба Ферма) — НЕ делаем: захват фермо-скоупный, нужен `farm_id` (§14 R-3).

### 2.2 Шторка (bottom-sheet)

- Примитивы уже есть: `Sheet` + `Cta` (`shell/components/Sheet.tsx`, `Cta.tsx`) — те же, что использует `HerdScreen`. Диспетчер переиспользует их (НЕ вводим `sh-scrim/sh-sheet` прототипа — у нас свой `Sheet`).
- Уровень 1 (грид плиток): сезонно-зависимый набор (`season` из активного `farm_production_plans`/фазы). Календарь: сезон **calving** (отёл) и **breeding** (случка) — как в прототипе `FARM_TILES`, но плитки идут в правильные дома.
- Уровень 2 (под-форма плитки): для «Проблема» = `DeviationForm` (кто→что). Для «Лечение» = «Проблема»+эскалация. Для design-only плиток — под-формы спроектированы в §4, реализация отложена.
- Иконки плиток — `PhIcon` (Phosphor), подписи — Geist sans, номера бирок — `mk-mono`.

### 2.3 Связь с существующим «+ Отклонение» в «Обходе»

- В «Обходе» (SCR-WK) уже есть кнопка `.wk-add` «+ Отклонение» → `DeviationForm` (`HerdScreen.tsx:313-325`). Она **остаётся** (HS-2 — ничего не удаляем).
- Диспетчер и «Обход» — **два входа к одному под-флоу** «Проблема». Оба монтируют один и тот же `DeviationForm`. Разница только в контексте (Обход = в рамках суточной отметки; диспетчер = ad-hoc отовсюду). См. §5.

---

## 3. Ядро: модель диспетчера (fan-out по типу факта)

Центральная таблица маршрутизации. **Каждая плитка → класс факта → дом → RPC → пост-действия.**

| Плитка | Класс факта | Дом (store) | Пишущий RPC | Пост-действия | Статус |
|--------|-------------|-------------|-------------|---------------|--------|
| **Проблема** | адресное отклонение по идентичности | `animal_events` (+ `animals` lazy D140) | `rpc_log_animal_event` | «Осмотр» (`rpc_create_farm_task`) · «Ветврачу» (`rpc_create_vet_case_from_event`) | ✅ **BUILD NOW** |
| **Лечение** | наблюдение здоровья → вет-кейс | `animal_events` → `vet_cases` | `rpc_log_animal_event` + `rpc_create_vet_case_from_event` | открытый кейс виден в «Требует внимания» + бейдж | ✅ **BUILD NOW** |
| **Падёж** | выбытие (количество + идентичность) | `herd_events` (`death`) + `animals` (`left_herd`/`died`) + `herd_groups.head_count` | `rpc_log_herd_event` (+ мутатор head_count) | нет | 🎯 design-only → EPIC-LIFECYCLE |
| **Перевод** | межгрупповое перемещение | `herd_events` (`head_count_change` + `metadata.source_group_id`) + `animals.herd_group_id` | `rpc_log_herd_event` ×2 (или новый transfer) | нет | 🎯 design-only → EPIC-LIFECYCLE |
| **Отёл** | пополнение (рождение) | `herd_events` (`birth`) + `animals` (телёнок lazy) | `rpc_log_herd_event` + `rpc_log_animal_event` | (каскад задач — EPIC-CASCADE) | 🎯 design-only → EPIC-LIFECYCLE |
| **Взвешивание** | измерение веса | групповой `herd_events` (`weight_update`) / `herd_groups.avg_weight_kg` | `rpc_log_herd_event` | нет | 🎯 design-only → EPIC-WEIGHT (net-new для per-animal) |
| **Осеменение** | репродуктивное событие | **нет дома** (net-new repro-сущность) | net-new `rpc_log_breeding_event` | нет | 🎯 design-only → EPIC-REPRO |
| **Добавить** группу/животное | заведение сущности | `animals` (lazy) / `herd_groups` | `rpc_log_animal_event` (lazy) / визард ARS-212 / ARS-171 | нет | 🎯 design-only → EPIC-ENTITY |

**Правило диспетчера:** тип факта определяет дом. Никогда не писать групповой количественно-жизненный факт (Отёл/Падёж/Перевод/Взвешивание) в `animal_events`, и никогда не писать в `herd_events` из под-флоу «Проблема»/«Обход» (D147). Плитки, чей дом = `herd_events`, идут через `rpc_log_herd_event` — **отдельный, не-walkthrough путь** (это соблюдает букву D147: запрещены записи в `herd_events` *из флоу обхода*, а диспетчерский lifecycle-путь — не обход).

---

## 4. Под-флоу по типам факта

### 4.1 «Проблема» — ✅ BUILD NOW

**Дом:** `animal_events`. **Reuse-ядро:** `DeviationForm` (`HerdScreen.tsx:339-412`) — уже props-driven и переиспользуется в 2 местах.

**Флоу (2 шага, express ≤2):**
1. **Кто** (`step='who'`): чипы `animals_recent` (`mk-mono`, `№{tag}`) + свободный ввод номера (lazy — новый номер легально создаёт `animals` по D140). Диспетчер, в отличие от «Обхода», грузит `animals_recent` не из `rpc_get_herd_board` (его нет вне таба Стадо) — см. §14 R-2; MVP: `animalsRecent={[]}` → степ 1 деградирует в свободный поиск (ровно как `AnimalCardSheet`, `HerdScreen.tsx:498`).
2. **Что** (`step='what'`): чипы типов из `animal_event_types` (`loadEventTypes()`, P8, org-independent) + опц. заметка. Выбор типа **коммитит сразу** → `rpc_log_animal_event(p_organization_id, p_farm_id, p_tag_number, p_event_type_code, p_herd_group_id=null, p_note, p_photo_url=null, p_occurred_at=now, p_client_event_id=null, p_actor_id=null)`.

**Возврат:** `{ok, event_id, animal_id, animal_created}`. `onDone(event_id, tag_number)`.
**Пост-действия** (как в WalkView, `HerdScreen.tsx:292-310`): пока `!vet_case_id` → «Осмотр» / «Ветврачу».
**Событие:** `ops.animal_event.opened` (O-10).
**Edge:** новый номер → `animal_created=true` (тихо, П11); дубль-сабмит не дедуплится (нет CID — §8); тип коммитит без confirm (осознанно).

### 4.2 «Лечение» — ✅ BUILD NOW (как эскалация, не self-treatment)

**Критический факт (verified):** фермерского пути «лечение применено» **не существует** — `treatment_logs` (0 писателей во всём репо), `vet_recommendations.is_completed` (нет сеттера). Дозы/диагнозы — D61 (только `vet_products`, только эксперт).

**Честная buildable-семантика:** «Лечение» = «у животного проблема со здоровьем, нужен ветврач» → **залогировать наблюдение + открыть вет-кейс** в одном флоу, переиспользуя существующие RPC.

**Флоу:**
1. Кто (как §4.1).
2. Что: тип-наблюдение из `animal_event_types` (напр. `LAME`, `INJURY`, `NOT_EATING`) + заметка → `rpc_log_animal_event` → `event_id`.
3. Эскалация: `rpc_create_vet_case_from_event(p_organization_id, p_event_id, p_actor_id=null)` → `{ok, vet_case_id, already_linked}`. Replay-safe (`already_linked` short-circuit).

**Что происходит на сервере** (`d04_vet.sql:2938-2997`): создаётся `vet_cases` (`created_via='cabinet_farmer'`, `status='open'`, `severity='moderate'`, `affected_head_count=1`, `symptoms_text` = тип+бирка+заметка); проставляется `animal_events.vet_case_id`; эмитится `vet.vet_case.opened` c `payload.animal_event_id`. **Никаких доз/диагнозов** (D61 подтверждён — 0 совпадений vet_product/dosage в теле).

**Как кейс возвращается фермеру:** линкованный `animal_event` остаётся `open` → висит в «Требует внимания» (`rpc_get_farm_overview` → `_fn_farm_attention`); бейдж `vet_case_id` в herd board / карточке; полный экран — `rpc_get_vet_case_detail` (F11).

**Решения к G2 (§13):** DEC-VET-1 (нужен ли настоящий «дозвон до ветврача» = `status→escalated` + `consultation_request`, т.к. `severity='moderate'` авто-эскалацию не триггерит); DEC-VET-2 (закрывать ли `animal_event` при открытии кейса — сейчас остаётся `open`); DEC-VET-3 (drift токена `vet.vet_case.opened` ↔ Dok4 `vet.case.opened`, чинить в этом PR по D-RPC-CONTRACT-SYNC-01).

### 4.3 «Падёж» — 🎯 design-only → EPIC-LIFECYCLE

**Дом:** `herd_events` (`event_type='death'`, `metadata={vet_case_id?, cause:'disease|accident|unknown'}`) + `animals` (`status='left_herd'`, `left_reason='died'`, `left_at`) + декремент `herd_groups.head_count`.
**Путь:** `rpc_log_herd_event(... p_event_type='death', p_value_before=<текущий head_count>, p_value_after=<head_count-1>, p_metadata=...)` + мутатор `head_count` + update `animals`. **Не-walkthrough путь** (D147 соблюдён).
**Флоу:** кто (бирка/группа) → причина (справочник) → опц. заметка/фото.
**Gaps (net-new, §10):** `rpc_log_herd_event` не имеет `p_actor_id`, `client_event_id`, не мутирует `head_count` и не трогает `animals` — падёж требует **атомарности 3 операций** → нужен комбинированный `rpc_record_death` (P7 — новый RPC, не правка существующего).

### 4.4 «Перевод» — 🎯 design-only → EPIC-LIFECYCLE

**Дом:** `animals.herd_group_id` (индивид.) + `herd_events` групповые дельты. **В вокабуляре `herd_events` НЕТ `transfer`** — конвенция: `head_count_change` + `metadata.source_group_id` (`d01:955`), что для реального перемещения = **два парных события** (декремент источника + инкремент назначения) без атомарной связки.
**Решение к G2 (DEC-MOVE-1):** (A, рек.) добавить выделенный `event_type='transfer'` (P7 additive в CHECK) + один атомарный `rpc_record_transfer(source_group, target_group, count|identity)`; (B) держать конвенцию парных `head_count_change`.

### 4.5 «Отёл» — 🎯 design-only → EPIC-LIFECYCLE (+ каскад в EPIC-CASCADE)

**Дом:** `herd_events` (`event_type='birth'`, `metadata={father_breed_id?}`, инкремент группы телят) + lazy-`animals` для телёнка (пол, бирка позже). Канонический отёл — **количественный групповой факт**, не per-cow `animal_event`.
**Флоу:** корова (бирка) → пол телёнка (Бычок/Тёлочка) → опц. «телёнок слабый».
**Каскад (DEC-3, отложен в EPIC-CASCADE):** отёл → задачи «биркование (день 1-3)», «вет-осмотр коровы (день 3)», «контроль сосания (сутки)»; «слабый телёнок» → срочная SOP-задача. В этой итерации — **без авто-каскада** (максимум одна ручная задача, §6).

### 4.6 «Взвешивание» — 🎯 design-only → EPIC-WEIGHT

**Дом сегодня:** только групповой — `herd_events` (`weight_update`) / `herd_groups.avg_weight_kg`. **Per-animal веса нет** (пересекается с решением D-FW-2 «весов нет — не выдумываем»).
**Флоу (групповой MVP):** группа → средний вес, кг → `rpc_log_herd_event(p_event_type='weight_update', p_value_after=<кг>)`.
**Net-new (отложено):** per-animal вес = новая модель весов (таблица `animal_weights` + RPC) — вне F1..F12, отдельный эпик, отдельное решение CEO.

### 4.7 «Осеменение» — 🎯 design-only → EPIC-REPRO

**Дома нет вообще.** `herd_events` `breeding_start/end` — сезонного уровня; `HEAT_SIGNS` — единственное repro-наблюдение в `animal_event_types`. Осеменение per-animal требует **net-new repro-сущности** (таблица `breeding_events` + `rpc_log_breeding_event`: корова, дата, бык/семя, метод). **НЕ впихивать в `animal_event_types`** (D142 = наблюдения, не события жизненного цикла). Появляется во второй половине сезона (breeding).

### 4.8 «Добавить группу/животное» — 🎯 design-only → EPIC-ENTITY

- **Животное:** канон = lazy-only (рождается как side-effect `rpc_log_animal_event` по бирке, D140/P11 — фермер не заполняет реестр на старте). Явный «add-animal» противоречит инварианту → либо не делаем, либо это тонкий «завести бирку заранее» (net-new).
- **Группа:** дублирует deep group CRUD (ARS-171, unbuilt) и визард «Поправить состав» (ARS-212) → **риск P4** (несколько точек входа к одному факту). Рекоменд.: «Добавить группу» из диспетчера = deep-link в существующий визард ARS-212, не новая форма.
- **Прототипный `classifyAnimal`** (русские роль-строки хардкодом) — **нарушает P8** + баг: «Бычок» 8-83 мес без purpose проваливается в «Маточное поголовье». Не переносим; классификация — из `animal_categories` (12 seeded кодов, `d01:2005-2016`).

---

## 5. Связь с «Обходом» (SCR-WK)

- **«Обход»** = суточная дисциплина: отметка обхода (`rpc_mark_walkthrough`, NK-идемпотентность farm+date) + логирование отклонений найденных в обходе. Остаётся как есть (HS-2).
- **Диспетчер «Записать событие»** = ad-hoc вход отовсюду в Ферме, тот же под-флоу «Проблема» = тот же `DeviationForm`.
- **Общий код:** оба монтируют `DeviationForm`; оба зовут `rpc_log_animal_event`. Никакого дублирования логики (P4).
- **Граница D147:** и «Обход», и диспетчерская ветка «Проблема»/«Лечение» пишут только `animals`/`animal_events`/`vet_cases`. Диспетчерские lifecycle-плитки (Отёл/Падёж/Перевод/Взвешивание) пишут `herd_events` **вне** обхода — это разные пути, инвариант не нарушается.
- **Отметка обхода** остаётся эксклюзивно в SCR-WK (диспетчер её не дублирует — это не «событие», а суточный факт).

---

## 6. Генерация задач

- **DEC-3: без авто-каскада в этой итерации.** Из захвата — максимум **одна ручная задача** «Осмотр» (`rpc_create_farm_task`, `p_category='veterinary'`, `p_animal_event_id`) + эскалация «Ветврачу». Ровно как в WalkView сегодня.
- Окна (`window_*`) рождаются **только генератором ЦТК** (`fn_generate_production_plan`), никогда вручную из захвата.
- Многозадачные каскады — **только** через фазовый движок (`rpc_shift_breeding_start` / `fn_preview_cascade`, confirm-via-preview D144), не через захват.
- **EPIC-CASCADE** (отдельно, §12): событие → набор задач с богатой формой (targets[]/sop/urgent) — расширяет контракт `farm_tasks`; проектируется отдельным тактом, чтобы не дублировать фазовый движок.

---

## 7. Голосовой захват (DEC-4 — отдельным тактом)

- Прототип: `record → voice-confirm → KV (СОБЫТИЕ/КОРОВА/ФЛАГ) → Записать/Исправить`.
- Канон: голос = **Dok5 AI Gateway two-run** (P-AI-3, extract≠write): распознать → сохранить извлечённое → показать пользователю → записать в **следующем** run через **те же** RPC диспетчера. «Исправить» = префилл соответствующей под-формы.
- **Шов в этой спеке:** место под mic-CTA в шторке зарезервировано; «Исправить» открывает под-форму нужной плитки (диспетчер уже её умеет). Внутрь NLU/extract — **не проектируем**; отдельный такт (EPIC-VOICE).

---

## 8. Офлайн и идемпотентность

- Сегодня офлайн-outbox **не построен** (F10/ARS-286): `p_client_event_id=null` везде (`farm-herd.ts:131`), только optimistic reload + toast.
- **Проблема/Лечение** наследуют это ограничение (нет client-side дедупа дубль-сабмита) — приемлемо для BUILD NOW; полноценный outbox = F10.
- **Для lifecycle-плиток (§4.3-4.6):** `rpc_log_herd_event` **не имеет `client_event_id`** → ретрай задваивает `herd_events`. Реальный outbox должен нести `(kind, data, client_event_id)`, а lifecycle-RPC — получить CID-идемпотентность (net-new, §10). Прототипная очередь `Farm.queue = {t:string}[]` (label-only, без payload) — **не** подходит: обещание «записи не теряются никогда» не подкреплено для не-`animal_events` фактов.

---

## 9. Data-model: reuse ↔ net-new

**Reuse (без изменений схемы):**
- `animals` (D140, lazy identity) — `Проблема/Лечение/Отёл(телёнок)/Падёж/Перевод`.
- `animal_events` + `animal_event_types` (P8, is_active/sort_order) — `Проблема/Лечение`.
- `herd_events` (17-значный `event_type` CHECK: `head_count_change, weight_update, group_created/removed, birth, death, sale, purchase, calving_start/end, weaning, breeding_start/end, stall_start/end, pasture_start/end`) + `value_before/after` + generated `delta` + `metadata` — дома для `Падёж(death)/Отёл(birth)/Взвешивание(weight_update)/Перевод(head_count_change)`.
- `herd_groups.head_count` (единственный источник поголовья, P4/D20) + `animal_categories` (12 кодов).
- `vet_cases` (`created_via` включает `cabinet_farmer`) — `Лечение`.

**Net-new (design-only, отложено):**
| Что | Зачем | Эпик |
|-----|-------|------|
| `event_type='transfer'` в `herd_events` CHECK (additive) | атомарный перевод вместо парных head_count_change | EPIC-LIFECYCLE |
| `animal_weights` (таблица) | per-animal вес (сегодня только групповой avg) | EPIC-WEIGHT |
| `breeding_events` (таблица) | осеменение per-animal | EPIC-REPRO |
| CID-колонка/оверлоад для lifecycle-RPC | офлайн-дедуп herd_events-фактов | EPIC-LIFECYCLE + F10 |

---

## 10. RPC-контракты

**Reuse (P7 — сигнатуры НЕ трогаем):**

| RPC | Дом | Использует плитка | Примечание |
|-----|-----|-------------------|------------|
| `rpc_log_animal_event(p_organization_id, p_farm_id, p_tag_number, p_event_type_code, p_herd_group_id, p_note, p_photo_url, p_occurred_at, p_client_event_id, p_actor_id)` | animal_events | Проблема, Лечение | CID-idem; lazy animal D140; O-10 |
| `rpc_create_vet_case_from_event(p_organization_id, p_event_id, p_actor_id)` | vet_cases | Лечение | replay-safe (already_linked); D61; `vet.vet_case.opened` |
| `rpc_create_farm_task(... p_animal_event_id ...)` | farm_tasks | пост-действие «Осмотр» | CID-idem; одна задача |
| `rpc_get_herd_board`, `rpc_get_animal_card`, `rpc_close_animal_event`, `rpc_mark_walkthrough` | animal_events/walkthrough | Обход/карточка | без изменений |
| `rpc_log_herd_event(p_organization_id, p_farm_id, p_herd_group_id, p_event_type, p_value_before, p_value_after, p_data_source, p_event_date, p_notes, p_metadata) → uuid` | herd_events | Падёж/Отёл/Взвешивание/Перевод | ⚠ см. gaps ниже |

**⚠ `rpc_log_herd_event` gaps (для lifecycle-плиток — требуют net-new, P7-additive):**
1. **Нет `p_actor_id`** — `recorded_by` из `fn_current_user_id()` (JWT). Для offline-replay/service нужен явный actor → additive overload.
2. **Нет `client_event_id`** — ретрай задваивает. Нужна CID-идемпотентность.
3. **Не мутирует `herd_groups.head_count`** — journal-only; head_count правит отдельный `rpc_upsert_herd_group` (в `011_ai_rpc_catalog.sql`, тело не в d01 — **сверить с прод перед wiring**). → каждый lifecycle-захват = 2 не-атомарных вызова.
4. **`p_value_before` nullable** → если не передать, generated `delta` = NULL (единственный живой вызыватель `HerdGroupForm.tsx:121` уже так делает — его строки с NULL delta). Спека обязывает передавать `value_before`.

**Net-new RPC (design-only):** `rpc_record_death`, `rpc_record_transfer`, `rpc_log_breeding_event`, (опц.) `rpc_log_treatment` — каждый комбинирует journal + head_count + animals атомарно в одном SECURITY DEFINER теле, с `p_actor_id` + `p_client_event_id`. Все — additive (P7).

---

## 11. Событийная шина (Dok4)

- **Reuse:** `ops.animal_event.opened` (O-10), `ops.animal_event.closed` (O-11) — Проблема/Лечение. `vet.vet_case.opened` (V-01) c `payload.animal_event_id` — Лечение. `farm.herd_event.logged` (`entity_type='herd_events'`) — lifecycle-плитки.
- **Drift к починке (D-RPC-CONTRACT-SYNC-01):** код эмитит `vet.vet_case.opened` (`d04_vet.sql:2985`, `d07:376`), Dok4 V-01 называет `vet.case.opened` (`Dok4:77,473`). Reality = `vet.vet_case.opened`. Чинить в том же PR (док или код).
- **Новых токенов не вводим** для BUILD NOW.

---

## 12. Декомпозиция на задачи (эпик)

Родитель: **ARS-276 (Ферма 2.0)**. Новые под-задачи (создаём в Linear на anchor 5, после G2).

### Реализуем сейчас (Ready for Dev)
| ID | Название | tier | Acceptance |
|-----------|----------|------|------------|
| **CAP-1 · ARS-301** | Диспетчер-каркас: `IonShellFrame footer` CTA в `FarmScreen` + шторка плиток (сезонный грид, `PhIcon`) | semantic | CTA виден при `!empty` на табах Фермы; шторка открывается; плитки = PhIcon; ничего из F4-F9 не сломано (HS-2) |
| **CAP-2 · ARS-302** | Плитка «Проблема» = `DeviationForm` из шторки + пост-действия «Осмотр»/«Ветврачу» | mechanical | кто→что ≤2 тапа; `rpc_log_animal_event`; событие видно в «Требует внимания»; reuse `DeviationForm` без форка |
| **CAP-3 · ARS-303** | Плитка «Лечение» = наблюдение + `rpc_create_vet_case_from_event` | semantic | 3 шага → открытый vet_case (`cabinet_farmer`); бейдж `vet_case_id`; D61 (никаких доз); DEC-VET-1/2/3 разрешены |
| **CAP-4 · ARS-304** | Doc↔code sync: `vet.vet_case.opened` (Dok4 V-01) в этом же PR | mechanical | Dok4 и код совпадают (D-RPC-CONTRACT-SYNC-01) |

### Отложенные под-эпики (спроектированы, не реализуем) — Backlog
| Эпик | Содержимое | Блокеры |
|------|-----------|---------|
| **EPIC-LIFECYCLE · ARS-305** | Падёж, Перевод, Отёл(без каскада): `rpc_record_death`/`rpc_record_transfer` + head_count-атомарность + `event_type='transfer'` | заходит в поголовный учёт (раскол-чек, вне F1..F12); решение CEO |
| **EPIC-CASCADE · ARS-306** | Авто-каскад событие→задачи (отёл→биркование/вет-осмотр/сосание; слабый телёнок→SOP) | расширяет `farm_tasks`; не дублировать фазовый движок |
| **EPIC-WEIGHT · ARS-307** | Взвешивание per-animal (`animal_weights` + RPC) | net-new модель; D-FW-2 «весов нет» |
| **EPIC-REPRO · ARS-308** | Осеменение (`breeding_events` + RPC) | net-new repro-сущность |
| **EPIC-ENTITY · ARS-309** | «Добавить» животное/группу (dedup с ARS-171/212) | риск P4; lazy-only инвариант D140 |
| **EPIC-VOICE · ARS-310** | Голосовой захват (Dok5 two-run, NLU per kind) | AI Gateway; extract≠write |
| **F10 · ARS-286** | Офлайн-outbox с `(kind,data,client_event_id)` + CID для lifecycle-RPC | already planned |

---

## 13. Решения к G2

| # | Вопрос | Рекомендация |
|---|--------|--------------|
| OQ-1 | CTA на всех табах Фермы или только Обзор/Стадо? | На всех табах Фермы (единый вход = суть узла). |
| DEC-VET-1 | «Лечение» открывает `open`-кейс (severity moderate, авто-эскалации нет) — нужен ли настоящий «дозвон до ветврача» (`status→escalated` + `consultation_request`)? | Для BUILD NOW: открытый кейс + видимость в «Требует внимания». Реальный escalate — follow-up (не блокирует итерацию). |
| DEC-VET-2 | Закрывать `animal_event` при открытии кейса? Сейчас остаётся `open` (висит в attention). | Оставить `open` как живой пункт внимания, пока фермер/эксперт не закроет. |
| DEC-VET-3 | Drift токена `vet.vet_case.opened` ↔ Dok4 `vet.case.opened` | Чинить в PR CAP-3/CAP-4 (reality-имя `vet.vet_case.opened` → поправить Dok4). |
| DEC-MOVE-1 | Перевод: новый `event_type='transfer'` + атомарный RPC vs парные `head_count_change` | Новый `transfer` + атомарный RPC (P7 additive) — в EPIC-LIFECYCLE. |
| DEC-VOICE-1 | Резервировать mic-CTA в шторке сейчас (визуально) или добавить с EPIC-VOICE? | Зарезервировать место, действие — заглушка/«скоро» до EPIC-VOICE. |

---

## 14. Краевые случаи и риски

| # | Риск | Митигация |
|---|------|-----------|
| R-1 | Дубль-сабмит без CID (Проблема/Лечение) | приемлемо для BUILD NOW; полноценный дедуп = F10. `rpc_log_animal_event` уже поддерживает CID — включить, когда появится outbox. |
| R-2 | Глобальный CTA не грузит `rpc_get_herd_board` → нет `animals_recent` для чипов шага 1 | MVP: `animalsRecent={[]}` → свободный поиск номера (как `AnimalCardSheet`). Улучшение: лёгкий preload recent-animals. |
| R-3 | Захват фермо-скоупный: `rpc_log_animal_event` требует `p_farm_id` | CTA берёт `farm_id` из `FarmScreen` ctx; глобально-кабинетным (вне Фермы) НЕ делаем. |
| R-4 | Мёртвая бирка переиспользуется (P5): `uq_animals_farm_tag_live` уникален только для `in_herd`+`is_active` | новый event по номеру павшего животного создаст новую identity — корректно (история сохранена по FK). |
| R-5 | Prototype `classifyAnimal` баг (Бычок 8-83 мес → Маточное) + хардкод русских ролей (P8) | не переносим; классификация из `animal_categories`. |
| R-6 | Non-atomic lifecycle (journal + head_count раздельно) | EPIC-LIFECYCLE делает комбинированный RPC (одно SECURITY DEFINER тело). |
| R-7 | `rpc_upsert_herd_group` тело не в d01 (в `011_ai_rpc_catalog.sql`) | сверить с прод pg_proc перед wiring lifecycle-плиток. |

---

## 15. Дизайн-канон (D-UI-FARMER-RULES-01)

- **Иконки плиток = `PhIcon` (Phosphor)**, НЕ инлайн-SVG прототипа (`Icon`/`FTileIc` с hand-drawn path) — это дефект в фермерской зоне. Вес иконки = по блоку (в шторке — regular).
- **`mk-mono` только для цифр** (номера бирок, кг, головы). Русская микрокопия — Geist sans.
- **Flat cards, daylight-токены** (`var(--primary)`, `var(--fg)`, `var(--bd)`…). Переиспользовать `Sheet`/`Cta`, не вводить `sh-scrim/sh-sheet` из прототипа.
- **Реестр правил из правок CEO** (канон, тот же PR): R-N «Глобальный захват = диспетчер по типу факта, не плоский журнал»; «плитки захвата — PhIcon, не инлайн-SVG».

---

## Открытые вопросы (сводка для G2)
1. **OQ-1** — область охвата CTA (все табы Фермы / Обзор+Стадо).
2. **DEC-VET-1/2/3** — семантика эскалации, авто-закрытие события, drift токена.
3. **DEC-MOVE-1** — модель перевода.
4. Подтверждение декомпозиции §12 (CAP-1..4 сейчас; 7 под-эпиков — отдельно).

**Статус процесса:** G2 закрыт CEO 2026-07-22 → anchor 5 выполнен (Brain `farm-ops-cabinet.md` обновлён, спека в `Docs/`, Linear ARS-300 + ARS-301..310 созданы). Дальше — anchor 6 (код: CAP-1..4 = ARS-301..304, Ready for Dev) → anchor 7 (verify) → anchor 8 G3 (merge/deploy, CEO).
