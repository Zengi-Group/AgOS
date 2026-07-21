# Eng-Spec / Slice — Ферма 2.0 · Операционный кабинет фермера (F1, ARS-277)

> In-repo engineering spec (detailed intent). Тонкий синтез живёт в Мозге
> (`apex-brain/projects/agos/specs/farm-ops-cabinet.md`) и УКАЗЫВАЕТ сюда через `sources:`.
> Graphify индексирует этот файл — имена сущностей/RPC/таблиц совпадают с SQL-токенами.
> Apply order: d01 → d02 → d03 → d04 → d05 → d07 → d08 → d09 → d10 → d11 → d12 → d13 → d14.

- **Brain synthesis:** [[projects/agos/specs/farm-ops-cabinet]]
- **Linear epic:** ARS-276 (подзадачи F1..F12 = ARS-277..288); этот слайс = **G2-артефакт** — до подписи CEO остальные подзадачи не переводятся в Ready for Dev
- **Канон-вход (verbatim):** `apex-brain/raw/agos-farm-cabinet-ux-handoff-2026-07-21.md` (§2 инварианты, §4–7 экраны/связи, §8 модель, §9 бизнес-правила, §10 приёмка, §12 вопросы)
- **Canon domain owner:** этот слайс — канон дизайна Ферма 2.0. Секции Dok1 §2/§3/§4/§5.7/§5.8/§6, Dok3 §7a, Dok4 §1/§3.6a УКАЗЫВАЮТ сюда (reference model P4, D-DOC-RECON-01) и не дублируют. UI-контракты — `Docs/AGOS-Dok6-Slice8-Ferma2-OpsCabinet.md`.
- **Status:** draft (G2 sign-off CEO pending)

## 0. Скоуп и терминология

UX-переработка модуля «Ферма» кабинета (`/cabinet/farm`) под ежедневную полевую работу:
верхние табы **Обзор · Задачи · Стадо · Ещё**, норма↔факт, ввод по исключению, офлайн — штатный
режим. Максимальный reuse: движок ЦТК (d05: `farm_production_plans`/`farm_phases`/`farm_tasks`,
каскад `fn_shift_phase_cascade` D104), остатки кормов (d03 `farm_feed_inventory` D43/D45),
вет-контур (d04 `vet_cases`). Новое — только аддитивно (P7): 4 таблицы, 8 колонок, 12 RPC, 4 события.

**⚠️ Сверка нумерации «узлов» (двух канонов):**

| Термин | «Узлы 1–3» handoff'а кабинета | «Узлы» Farm-Module-FunctionalSpec-v0_1 |
|---|---|---|
| Узел 1 | экран «Обзор» | профиль-опросник (ARS-212, построен) |
| Узел 2 | экран «Задачи» | (не определён) |
| Узел 3 | экран «Обход» | (не определён) |
| Узел 4 | учёт кормов (не спроектирован) | — |

Чтобы dev-агенты не путали каноны: **в этом слайсе и во всех подзадачах F2..F12 слова «узел N»
не используются** — только имена экранов (Обзор / Задачи / Обход) и SCR-коды Dok6 Slice8.
`AGOS-Farm-Module-FunctionalSpec-v0_1.md` остаётся каноном профиля-опросника (Узел 1 = ARS-212).

**Не в скоупе F1..F12:** раскол-чек (режим 2) и инвентаризация (режим 3) — модель их
поддерживает (см. §1.5 `head_count_done`, §1.1 `animals`), UI не строится; полный учёт
прихода/расхода кормов (узел 4 handoff §12); WhatsApp-канал (AI Gateway читает те же RPC — Dok 5, отдельный такт).

---

## 1. Data model (P1 — first)

Все таблицы: PK `uuid gen_random_uuid()`, timestamps `timestamptz`, статусы `text + CHECK`,
soft-delete `is_active`, RLS по `organization_id` (зеркало политик `herd_groups`: `*_read_own` /
`*_write_own` через `fn_my_org_ids()`-паттерн d01). Размещение: §1.1–1.4 → `d01_kernel.sql`
(Farm Graph, рядом с `herd_events`); §1.5–1.6 → `d05_ops_edu.sql`; FK `animal_events.vet_case_id` →
`d04_vet.sql` (deferred FK — паттерн D57 `consultation_request_id`, разрывает цикл порядка применения d01→d04).

### 1.1 `animals` — лёгкий identity-слой ПОВЕРХ D20 (D140)

D20 не отменяется: AGOS оперирует группами, `head_count` живёт на `herd_groups` (P4).
`animals` — реестр идентичностей «номер бирки», нужный ровно там, где отклонение адресное
(«№41 хромает»). **НЕ поголовный учёт движения**: строки НЕ участвуют в подсчёте поголовья,
никаких триггеров синка head_count. Наполнение — lazy: запись создаётся при первом событии
по номеру (P11: фермер не заполняет реестр на старте). Инвентаризация/раскол-чек (след. скоуп)
наполняют реестр дальше.

```sql
create table if not exists public.animals (
    id              uuid primary key default gen_random_uuid(),
    farm_id         uuid not null references public.farms(id) on delete cascade,
    organization_id uuid not null references public.organizations(id),   -- denorm RLS
    herd_group_id   uuid references public.herd_groups(id) on delete set null,  -- текущая группа; nullable (может быть неизвестна)
    tag_number      text not null,                     -- номер бирки как вводит фермер («41», «KZ-870112»); нормализация btrim в RPC
    status          text not null default 'in_herd'
                        check (status in ('in_herd','left_herd')),        -- FSM §5.7
    left_at         date,
    left_reason     text check (left_reason in ('sold','died','transferred','other')),
    data_source     text not null default 'platform'
                        check (data_source in ('registration','ai_extracted','platform','erp')),  -- D21-паттерн; confidence НЕ вводим (нет потребителя, HS-4)
    notes           text,
    is_active       boolean not null default true,     -- false = создано ошибкой (опечатка номера); ≠ left_herd (реальное выбытие)
    created_by      uuid references public.users(id),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
-- Живой номер уникален в пределах фермы; история выбывших может повторять номера (P5: короткие бирки реиспользуются)
create unique index if not exists uq_animals_farm_tag_live
    on public.animals (farm_id, lower(btrim(tag_number)))
    where status = 'in_herd' and is_active;
create index if not exists idx_animals_farm   on public.animals (farm_id) where status = 'in_herd' and is_active;
create index if not exists idx_animals_org    on public.animals (organization_id);  -- RLS
create index if not exists idx_animals_group  on public.animals (herd_group_id) where herd_group_id is not null;
```

- **P2:** создаёт Farmer (RPC lazy) / AI (те же RPC); обновляет Farmer; авторитет при конфликте — ERP (L4), когда появится ИСЖ/RFID-синк (ADR-ANIMAL-01 канал готов).
- **P12:** current-state таблица; история — `animal_events`.
- **§9.6 handoff:** выбытие (`left_herd`) убирает животное из чипов/чек-листов, история событий сохраняется (FK не рвётся).

### 1.2 `animal_event_types` — словарь типов отклонений (D142, P8)

Платформенный справочник (без `organization_id`) — стандарт ассоциации, финализируется с
ветврачом (handoff §12): правка словаря = data update, не деплой. RLS: read authenticated,
write `fn_is_admin()` (зеркало `feed_consumption_norms`).

```sql
create table if not exists public.animal_event_types (
    id          uuid primary key default gen_random_uuid(),
    code        text not null unique,       -- 'LYING' | 'LAME' | 'NOT_EATING' | 'INJURY' | 'HEAT_SIGNS' | 'OTHER'
    name_ru     text not null,              -- «лежит» · «хромает» · «не ест» · «травма» · «признаки охоты» · «другое»
    sort_order  int  not null default 0,
    is_active   boolean not null default true,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
-- seed через ON CONFLICT (code) DO NOTHING — 6 строк выше в порядке sort_order 10..60
```

Это НЕ дозировки и НЕ диагнозы (D61 не затрагивается): тип отклонения — наблюдение фермера,
диагноз остаётся в `vet_diagnoses`.

### 1.3 `animal_events` — событие по животному (D140/D147)

```sql
create table if not exists public.animal_events (
    id              uuid primary key default gen_random_uuid(),
    organization_id uuid not null references public.organizations(id),   -- denorm RLS
    farm_id         uuid not null references public.farms(id),
    animal_id       uuid not null references public.animals(id),
    herd_group_id   uuid references public.herd_groups(id) on delete set null,  -- снапшот группы на момент события
    event_type_id   uuid not null references public.animal_event_types(id),
    note            text,
    photo_url       text,                               -- Supabase Storage (опционально, handoff §6.4)
    status          text not null default 'open'
                        check (status in ('open','closed')),             -- открытое держит строку в «Требует внимания»
    occurred_at     timestamptz not null default now(), -- полевое время; офлайн-реплей передаёт клиентский таймстамп
    recorded_by     uuid references public.users(id),
    created_via     text not null default 'cabinet' check (created_via in ('cabinet','ai')),
    client_event_id uuid,                               -- идемпотентность offline-реплея (D145)
    vet_case_id     uuid,                               -- FK → vet_cases добавляется в d04 (deferred, паттерн D57)
    closed_at       timestamptz,
    closed_by       uuid references public.users(id),
    resolution_note text,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
create unique index if not exists uq_animal_events_client
    on public.animal_events (client_event_id) where client_event_id is not null;
create index if not exists idx_animal_events_farm_open on public.animal_events (farm_id) where status = 'open';
create index if not exists idx_animal_events_animal    on public.animal_events (animal_id, occurred_at desc);
create index if not exists idx_animal_events_org       on public.animal_events (organization_id);  -- RLS
```

- **≠ `herd_events`** (D147): `herd_events` — количественный/жизненный журнал ГРУПП (append-only,
  D25); `animal_events` — адресные отклонения по ИДЕНТИЧНОСТИ. Разные факты, оба дома живут.
  Никаких записей в `herd_events` из флоу обхода.
- **FSM:** `open → closed` (закрывает фермер; авто-закрытие при resolve связанного vet_case —
  кандидат след. скоупа, v1 вручную).
- Задача «осмотр», созданная из события, ссылается обратно: `farm_tasks.animal_event_id` (§1.5).

### 1.4 `farm_walkthroughs` — отметка обхода (суточный факт)

```sql
create table if not exists public.farm_walkthroughs (
    id              uuid primary key default gen_random_uuid(),
    farm_id         uuid not null references public.farms(id) on delete cascade,
    organization_id uuid not null references public.organizations(id),   -- denorm RLS
    walk_date       date not null,                      -- ЛОКАЛЬНАЯ дата фермера (клиент передаёт явно)
    marked_at       timestamptz not null default now(),
    marked_by       uuid references public.users(id),
    created_at      timestamptz not null default now(),
    unique (farm_id, walk_date)                          -- один факт на сутки = естественный ключ идемпотентности
);
create index if not exists idx_farm_walkthroughs_farm on public.farm_walkthroughs (farm_id, walk_date desc);
create index if not exists idx_farm_walkthroughs_org  on public.farm_walkthroughs (organization_id);
```

- **Границы суток** — календарные сутки фермера (P5): все read/write RPC принимают
  `p_walk_date` / `p_today` от клиента (локальная дата устройства); серверный `current_date` —
  только fallback. Реплей вчерашней отметки ложится на вчера — зона «Стадо» за сегодня честно
  остаётся «нет данных» (§2.1 инвариант «ок без данных запрещён»).
- «Назавтра снова не отмечен» — не job/cron, а чистая функция чтения: `walk_date = p_today`.
- Эволюция «вечерней отметки» (handoff §12): аддитивно колонка `slot text not null default 'day'`
  + пересборка unique на `(farm_id, walk_date, slot)` — путь зафиксирован, v1 не строим.

### 1.5 `farm_tasks` — window-семантика + связи (D141, аддитивная дельта d05)

Окно = НЕ отдельная сущность. Окно — это massовая задача над группой с диапазоном дат и
плановым поголовьем; вся FSM/RLS/генерация/просрочка у `farm_tasks` уже есть — вторая сущность
раздвоила бы факт «работа к сроку» (P4). Координация с вет-окнами (`vaccination_plan_items`,
d04) — ПО ДАТАМ, не FK (D75): read-сторона мержит оба источника в календарь Месяца.

```sql
alter table public.farm_tasks
    add column if not exists window_start       date,
    add column if not exists window_end         date,
    add column if not exists head_count_planned int  check (head_count_planned > 0),
    add column if not exists head_count_done    int  not null default 0 check (head_count_done >= 0),
    add column if not exists parent_task_id     uuid references public.farm_tasks(id),   -- подготовительная → её задача-окно
    add column if not exists animal_event_id    uuid references public.animal_events(id),-- задача «по отклонению»
    add column if not exists assigned_to        uuid references public.users(id),        -- исполнитель (handoff §5.1)
    add column if not exists due_time           time,                                    -- время дня («10:00»), опционально
    add column if not exists client_task_id     uuid;                                    -- идемпотентность офлайн-создания (D145)

alter table public.farm_tasks drop constraint if exists farm_tasks_window_pair_check;
alter table public.farm_tasks add constraint farm_tasks_window_pair_check
    check ( (window_start is null) = (window_end is null)
            and (window_end is null or window_end >= window_start) );
-- Конвенция-инвариант: у задачи-окна due_date = window_end (закрытие окна) —
-- существующие due_soon/overdue кроны и FSM работают без изменений.
alter table public.farm_tasks drop constraint if exists farm_tasks_window_due_check;
alter table public.farm_tasks add constraint farm_tasks_window_due_check
    check ( window_end is null or due_date = window_end );
create index if not exists idx_farm_tasks_window on public.farm_tasks (window_end)
    where window_start is not null and status not in ('completed','skipped');
create index if not exists idx_farm_tasks_event  on public.farm_tasks (animal_event_id) where animal_event_id is not null;
create unique index if not exists uq_farm_tasks_client
    on public.farm_tasks (client_task_id) where client_task_id is not null;
```

- **Источник задачи — derived, без новой колонки** (P4): `task_template_id is not null` → из
  техкарты (`cycle`); `animal_event_id is not null` → «по отклонению» (`deviation`); обе null →
  ручная (`manual`). Правило маркировки §9.3 handoff.
- **Подготовительная задача:** `parent_task_id` → задача-окно; её `due_date = parent.window_start`
  (дедлайн = старт окна, handoff §5.2). Кросс-строчный инвариант держат генератор и
  `rpc_shift_breeding_start` (CHECK невозможен — документировано).
- **«Горит»** (§9.2): `window_end - p_today <= 2` и статус не терминальный — вычисляется при
  чтении, не хранится.
- **«Окно закрылось с остатком»**: `due_date < p_today` и `head_count_done < head_count_planned`
  → строка «Требует внимания» (derived при чтении; cron-событие O-12 — planned, §3).
- **Раскол-чек (след. скоуп)** доращивает `head_count_done` поголовно; v1: единственный писатель —
  `rpc_complete_farm_task.result_data.head_count` → `head_count_done`.

### 1.6 `task_templates` — окно в шаблоне (аддитивно, контент — ARS-172)

```sql
alter table public.task_templates
    add column if not exists window_duration_days int check (window_duration_days > 0),  -- null = точечная задача
    add column if not exists is_prep_for_code     text;  -- code задачи-окна в той же фазе (паттерн depends_on_phase_code d05)
```

Генератор (`fn_generate_production_plan`, F3): `window_duration_days is not null` →
`window_start = phase.start_date + offset`, `window_end = window_start + duration`,
`due_date = window_end`, `head_count_planned = herd_groups.head_count` группы фазы на момент
генерации; `is_prep_for_code` → `parent_task_id` + `due_date = parent.window_start`.

### 1.7 Не трогаем (инвентарь reuse)

| Объект | Роль в Ферма 2.0 | Файл |
|---|---|---|
| `herd_groups.head_count` | единственный источник поголовья (D20/P4) | d01 |
| `herd_events` | журнал количеств/жизненного цикла — вне флоу обхода (D147) | d01 |
| `farm_production_plans` / `farm_phases` | цикл/фазы; день N/M, таймлайн Года | d05 |
| `fn_shift_phase_cascade` (D104) / `fn_preview_cascade` | движок каскада; фермерский путь — ТОЛЬКО через обёртку §2.9 | d05 |
| `farm_feed_inventory` (D43/D45) | остатки кормов → дни запаса (D143) | d03 |
| `rations`/`ration_versions` · `feed_consumption_norms` | плановый суточный расход: Priority 1 · 2 (ADR-FEED-02) | d03 |
| `vet_cases` (`created_via='cabinet_farmer'` уже в CHECK, D-F10-1) | эскалация «Ветврачу» (D147) | d04 |
| `vaccination_plan_items` | вет-окна в календаре Месяца — merge по датам (D75), не FK | d04 |
| `rpc_get_active_plan` (RPC-37) | остаётся; Обзор использует агрегат §2.7 (один вызов = один кэш-юнит) | d05 |

---

## 2. RPC (Dok 3 contract — §7a)

Все: `SECURITY DEFINER`, `set search_path = public, pg_temp`, `p_organization_id` в каждом
вызове (P-AI-2) + ownership-guard `farm_id/entity → organization_id` (SEC-RPC-ORGTRUST-01),
`grant execute to authenticated` + `revoke from anon` + `revoke from public`
(SEC-GRANT-PUBLIC-01 — новые RPC сразу чистые). Web и AI зовут одни и те же функции (P-AI-1).
Доменные исходы — graceful jsonb (`{ok:false, reason}`), не exception (паттерн RPC-33a).

Idempotency-классы (D145): **NK** = natural key · **CID** = client_event_id · **FSM** =
идемпотентность по состоянию (повтор → текущее состояние, не ошибка).

| # | RPC | Файл (build-такт) | Idem | Возврат |
|---|---|---|---|---|
| 2.1 | `rpc_mark_walkthrough` | d01 (F2) | NK | `{walkthrough_id, walk_date, marked_at, already_marked}` |
| 2.2 | `rpc_log_animal_event` | d01 (F2) | CID | `{event_id, animal_id, animal_created, status}` |
| 2.3 | `rpc_close_animal_event` | d01 (F2) | FSM | `{event_id, status, closed_at}` |
| 2.4 | `rpc_get_herd_board` | d01 (F2) | read | экран «Стадо»+«Обход» одним вызовом |
| 2.5 | `rpc_get_animal_card` | d01 (F2) | read | животное + история событий |
| 2.6 | `rpc_create_vet_case_from_event` | d04 (F2) | FSM | `{vet_case_id, already_linked}` |
| 2.7 | `rpc_get_farm_overview` | d05 (F3) | read | весь экран «Обзор» одним вызовом |
| 2.8 | `rpc_get_tasks_horizon` | d05 (F3) | read | Неделя/Месяц/Год по `p_horizon` |
| 2.9 | `rpc_shift_breeding_start` | d05 (F3) | FSM | `{shifted_phases[], shifted_tasks_count}` |
| 2.10 | `rpc_reschedule_farm_task` | d05 (F3) | NK | `{task_id, due_date}` |
| 2.11 | `rpc_activate_production_plan` | d05 (F3) | FSM | `{plan_id, status, activated_at}` — retire IMPL_DEBT FARM-02 |
| 2.12 | `rpc_get_feed_days_left` | d03 (F12) | read | дни запаса по позициям (§7) |
| 2.13 | поправка `rpc_complete_farm_task` | d07 (F3) | FSM | повтор-complete → success `{already_completed:true}` |
| 2.14 | `rpc_create_farm_task` | d05 (F3) | CID | ручная задача («+») и задача «Осмотр» из отклонения |

### Сигнатуры и семантика

**2.1** `rpc_mark_walkthrough(p_organization_id uuid, p_farm_id uuid, p_walk_date date default current_date, p_actor_id uuid default null) returns jsonb`
`insert … on conflict (farm_id, walk_date) do nothing`; конфликт → вернуть существующую строку,
`already_marked=true`, событие НЕ эмитить повторно. Эмитит `ops.walkthrough.marked` (O-09) только при первой вставке.

**2.2** `rpc_log_animal_event(p_organization_id uuid, p_farm_id uuid, p_tag_number text, p_event_type_code text, p_herd_group_id uuid default null, p_note text default null, p_photo_url text default null, p_occurred_at timestamptz default now(), p_client_event_id uuid default null, p_actor_id uuid default null) returns jsonb`
Порядок: (1) `p_client_event_id` уже существует → вернуть существующее событие (реплей);
(2) найти животное `farm_id + lower(btrim(tag_number))`, `in_herd`+active; нет → **lazy-создать**
(D140) с `herd_group_id`; (3) insert события `open`; (4) эмит `ops.animal_event.opened` (O-10).
Тип по `code` из `animal_event_types` (L-7: UI шлёт code, не name).

**2.3** `rpc_close_animal_event(p_organization_id uuid, p_event_id uuid, p_resolution_note text default null, p_actor_id uuid default null) returns jsonb`
Уже `closed` → вернуть как есть (реплей-safe). Переход → `closed_at/closed_by` + эмит O-11.

**2.4** `rpc_get_herd_board(p_organization_id uuid, p_farm_id uuid, p_today date default current_date) returns jsonb`
`{herd_total, groups:[{id, category_name, head_count, avg_weight_kg}], walkthrough:{marked, marked_at}, open_events:[{event_id, tag_number, type_code, type_name, occurred_at, note, vet_case_id, task_id}], today_events_count, animals_recent:[{animal_id, tag_number, herd_group_id}]}` — `animals_recent` (последние ~30 по активности) = источник чипов шага 1 визарда отклонения; новый номер вводится свободно (lazy).

**2.5** `rpc_get_animal_card(p_organization_id uuid, p_animal_id uuid) returns jsonb`
`{animal:{id, tag_number, status, herd_group…}, events:[… occurred_at desc]}`.

**2.6** `rpc_create_vet_case_from_event(p_organization_id uuid, p_event_id uuid, p_actor_id uuid default null) returns jsonb`
Событие уже связано (`vet_case_id not null`) → вернуть существующий кейс, `already_linked=true`.
Иначе: создать `vet_cases` (`created_via='cabinet_farmer'`, `herd_group_id` из события,
`affected_head_count=1`, `symptoms_text = '<name_ru>; бирка №<tag_number>; <note>'`) + проставить
`animal_events.vet_case_id` атомарно. Эмитит существующий `vet.vet_case.opened` (V-01) с
`payload.animal_event_id` — нового события не вводим. Дозы/диагнозы НЕ генерируются (D61).

**2.7** `rpc_get_farm_overview(p_organization_id uuid, p_farm_id uuid, p_today date default current_date) returns jsonb`
Один вызов = весь Обзор = один кэш-юнит офлайна (D145):
```jsonc
{
  "as_of": "…",                       // серверный now(); UI показывает «данные на HH:MM» из кэша
  "herd":      { "total": 86, "walkthrough_marked": true, "marked_at": "…", "groups_count": 5 },
  "cycle":     { "plan_id": "…", "phase_name": "Случка", "day": 18, "days_total": 60,
                 "next_window": { "task_id|vpi_id": "…", "name": "…", "ends_in_days": 4, "burning": false },
                 "no_plan": false, "draft_plan_id": null },          // плана нет → CTA (см. 2.11)
  "tasks":     { "today_total": 8, "today_done": 3, "overdue": 2 },
  "resources": { "tracked": true, "min_days_left": 9, "signals": [ {"feed":"сено","days_left":9,"buy":true} ] },
  "attention": [ { "kind": "animal|window|task|feed", "priority": 1,   // §2.6 handoff: сортировка на сервере
                   "title": "№41, 87 — не ест повторно", "subtitle": "просрочено 2 дн · 8 голов",
                   "action": { "type": "open_animal|open_window|reschedule_today|open_resources", "ref_id": "…" } } ],
                   // action.type: РОВНО эти 4 (verified прод _fn_farm_attention + d05, 2026-07-21). inspect/to_vet — экран «Обход» SCR-WK (F9), НЕ Обзор — Dok6 Slice8 §2.2/§4
  "today":     [ /* 3 ближайшие невыполненные задачи, анатомия §4.3 handoff */ ],
  "today_more_count": 5
}
```
Источники «attention»: открытые `animal_events` → просроченные/закрывающиеся окна с остатком
(`head_count_done < head_count_planned`) → просроченные задачи → сигналы кормов (§7).
Зоны без данных возвращают явный null-статус («обход не отмечен», «не ведётся») — «ок» без
данных запрещён (§2.1 handoff).

**2.8** `rpc_get_tasks_horizon(p_organization_id uuid, p_farm_id uuid, p_horizon text, p_anchor date default current_date) returns jsonb`
`check p_horizon in ('week','month','year')`. Один RPC — три формы (один реестровый токен,
кэш-юнит = `(horizon, anchor)`):
- `week`: `{context:{phase_name, day, days_total}, burning:[{kind:'overdue'|'window', task_id, name, sub, action}], days:[{d, load, has_overdue, tasks:[{id, name, status, sop_code, heads, assigned_to_name, due_time, source, window_end?, deviation?}]}]}` — «горит» непролистываем (первый блок).
- `month`: `{grid:[{d, load, has_overdue, window_ids[]}], windows:[{id, source:'ops'|'vet', name, date_start, date_end, heads_planned, heads_done}], prep:[{task_id, name, deadline, days_left, window_ref}], milestones:[…]}` — вет-окна замержены по датам из `vaccination_plan_items` (D75); вехи derived (D146).
- `year`: `{plan:{id, name, cycle_start, cycle_end}, phases:[{id, name_ru, start_date, end_date, status, day?, days_total?, progress_pct?, milestones:[…], annotation?}], breeding:{phase_id, start_date, editable:true}}`.

**2.9** `rpc_shift_breeding_start(p_organization_id uuid, p_farm_id uuid, p_new_start_date date, p_actor_id uuid default null) returns jsonb`
Фермерская обёртка над D104 (D144): (1) ownership-guard org→farm→active plan (у
`fn_shift_phase_cascade` guard'а НЕТ — прямой вызов остаётся экспертным/AI путём);
(2) найти фазу случки активного плана (по `phase_templates.code` семейства `BREEDING` — F3
сверяет фактический seed-токен, L-7); (3) делегировать `fn_shift_phase_cascade`;
(4) **сдвинуть задачи** сдвинутых фаз на тот же delta: `status in ('scheduled','reminded','overdue')`
→ `due_date += shift`, `window_start/window_end += shift` (пары целиком); `completed/skipped`
не трогаются — прошлое неприкосновенно (§9.4); (5) эмит существующего `ops.farm_phase.rescheduled`
(O-04, payload уже несёт `cascaded_phases[]`). Confirm-семантика: UI сначала зовёт
`fn_preview_cascade` (RPC-36) → диалог «пересчитает все окна» → этот RPC. D104-канон:
каскад НЕ двигает задачи — расширение только внутри обёртки, `fn_shift_phase_cascade` не меняется (P7).

**2.10** `rpc_reschedule_farm_task(p_organization_id uuid, p_task_id uuid, p_new_due_date date, p_actor_id uuid default null) returns jsonb`
«На сегодня» для просрочек. Guard: задача-окно (`window_start is not null`) →
`{ok:false, reason:'WINDOW_TASK_IMMOVABLE'}` — перенос задачи не двигает окно (§9.4);
двигаются обычные, «по отклонению» и подготовительные (окно родителя не трогается).
`overdue → scheduled` при `p_new_due_date >= p_today`.

**2.11** `rpc_activate_production_plan(p_organization_id uuid, p_plan_id uuid, p_actor_id uuid default null) returns jsonb`
Закрывает **IMPL_DEBT FARM-02** (петля self-service F-D12: draft → просмотр → активация).
Guard: ownership; `draft` → `active` (+`activated_at`); уже `active` → вернуть как есть;
другой active-план фермы существует (`idx_farm_plan_one_active`) → `{ok:false,
reason:'PLAN_ALREADY_ACTIVE_EXISTS', active_plan_id}`. Эмитит `ops.production_plan.started`
(O-01, `payload.activation=true`). Обзор без active-плана отдаёт `cycle.no_plan=true` +
`draft_plan_id` → CTA «Активировать план» (Dok6 SCR-OV state D). Смежный дефект FARM-01
(draft-читатель `rpc_get_production_plan`, d07) чинится в F3 тем же тактом — 3 имени колонок.

**2.12** `rpc_get_feed_days_left(p_organization_id uuid, p_farm_id uuid, p_today date default current_date) returns jsonb`
Обёртка над внутренней `fn_feed_days_left(farm_id, today)` (её же зовёт 2.7 для зоны «Ресурсы»).
Формула и фолбэки — §7. Build: F12 (опционально; без F12 Обзор показывает «не ведётся» —
честное состояние, `fn_feed_days_left` строится в F3 вместе с 2.7).

**2.14** `rpc_create_farm_task(p_organization_id uuid, p_farm_id uuid, p_name_ru text, p_due_date date, p_due_time time default null, p_category text default 'management', p_assigned_to uuid default null, p_animal_event_id uuid default null, p_client_task_id uuid default null, p_actor_id uuid default null) returns jsonb`
Единственный создающий RPC вне генератора ЦТК: кнопка «+» (ручная) и действие «Осмотр»
(`p_animal_event_id` → задача «по отклонению», §1.5-derived source). Привязка: активная фаза
active-плана, покрывающая `p_due_date` (иначе ближайшая/активная); плана нет →
`{ok:false, reason:'NO_ACTIVE_PLAN'}` (v1: ручные задачи требуют план — зона «Задачи» без
плана и так в state D). Реплей: `p_client_task_id` конфликт → вернуть существующую задачу.
Окно/`window_*` НЕ задаются (окна рождаются только генератором из шаблонов).

**2.13 Поправка** `rpc_complete_farm_task` (d07, сигнатура НЕ меняется — P7):
повторный complete уже-completed задачи → success `{already_completed:true}`, первая запись
выигрывает (`completed_at/result_data` не перезаписываются, дубль `herd_event` не создаётся —
гард `herd_event_created` уже есть). Нужно для офлайн-реплея (D145): «отправил, ответ не дошёл,
реплей» не должен падать. Дополнительно: `result_data.head_count` у задачи-окна →
`head_count_done = least(head_count, head_count_planned)`.

### Реестр имён (D-NEW-A) — вставки при build

```sql
insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
  ('rpc_mark_walkthrough',            null, 'd01_kernel.sql (ARS-278)', 'Ferma 2.0: отметка обхода, NK-идемпотентность'),
  ('rpc_log_animal_event',            null, 'd01_kernel.sql (ARS-278)', 'Ferma 2.0: отклонение по бирке, lazy-создание animal (D140)'),
  ('rpc_close_animal_event',          null, 'd01_kernel.sql (ARS-278)', 'Ferma 2.0: закрытие события'),
  ('rpc_get_herd_board',              null, 'd01_kernel.sql (ARS-278)', 'Ferma 2.0: агрегат таба Стадо/Обход'),
  ('rpc_get_animal_card',             null, 'd01_kernel.sql (ARS-278)', 'Ferma 2.0: карточка животного'),
  ('rpc_create_vet_case_from_event',  null, 'd04_vet.sql (ARS-278)',    'Ferma 2.0: эскалация Ветврачу (D147)'),
  ('rpc_get_farm_overview',           null, 'd05_ops_edu.sql (ARS-279)','Ferma 2.0: агрегат Обзора'),
  ('rpc_get_tasks_horizon',           null, 'd05_ops_edu.sql (ARS-279)','Ferma 2.0: Неделя/Месяц/Год'),
  ('rpc_shift_breeding_start',        null, 'd05_ops_edu.sql (ARS-279)','Ferma 2.0: фермерская обёртка D104 (D144)'),
  ('rpc_reschedule_farm_task',        null, 'd05_ops_edu.sql (ARS-279)','Ferma 2.0: перенос без сдвига окна'),
  ('rpc_activate_production_plan',    null, 'd05_ops_edu.sql (ARS-279)','Ferma 2.0: draft→active, retire FARM-02'),
  ('rpc_create_farm_task',            null, 'd05_ops_edu.sql (ARS-279)','Ferma 2.0: ручная задача / задача из отклонения, CID-идемпотентность'),
  ('rpc_get_feed_days_left',          null, 'd03_feed.sql (ARS-287)',   'Ferma 2.0: дни запаса (D143)')
on conflict do nothing;
```

---

## 3. Events (Dok 4 — реестр §1, каталог §3.6a)

Продолжение нумерации Ops (O-01..O-08 существуют):

| # | canonical_event_type | Producer | Audit | RT | AI | Cron | Payload (ядро) |
|---|---|---|---|---|---|---|---|
| O-09 | `ops.walkthrough.marked` | rpc_mark_walkthrough [WEB,AI] | — | ✅ | — | — | `{farm_id, walk_date, marked_at, marked_by}` |
| O-10 | `ops.animal_event.opened` | rpc_log_animal_event [WEB,AI] | — | ✅ | ✅* | — | `{event_id, farm_id, animal_id, tag_number, event_type_code, herd_group_id, occurred_at}` |
| O-11 | `ops.animal_event.closed` | rpc_close_animal_event [WEB,AI] | — | ✅ | — | — | `{event_id, farm_id, animal_id, closed_at}` |
| O-12 | `ops.task.window_closed_incomplete` | System cron 📋 planned | — | — | ✅ | ✅ | `{task_id, farm_id, window_end, head_count_planned, head_count_done, remainder}` |

- RT-консьюмер — сам кабинет (live-инвалидация зон, паттерн `useEntitlementsRealtimeSync`;
  `platform_events` уже армирован в publication — миграция ARS-269, при F10 проверить на проде).
- *AI по O-10 — кандидат проактивной реакции vet-консультанта (Dok 5, отдельный такт; в v1 только запись).
- O-12 — planned: до крона состояние «окно закрылось с остатком» derived при чтении (§1.5);
  cron вводится, когда появится потребитель уведомления (P11/HS-4).
- Эскалация «Ветврачу» НЕ вводит нового события — существующий `vet.vet_case.opened` (V-01)
  получает `payload.animal_event_id` (аддитивно). Активация плана реиспользует O-01
  (`payload.activation=true`), перенос задачи события не эмитит (нет потребителя).
- Новых notification-шаблонов v1 НЕТ: обходные напоминания — открытый вопрос §12
  (вечерняя отметка), существующие `ops.farm_task.due_soon/overdue` покрывают задачи.

---

## 4. UI contract (Dok 6)

Канон экранов — **`Docs/AGOS-Dok6-Slice8-Ferma2-OpsCabinet.md`** (4 таба + 3 экрана: SCR-OV
Обзор · SCR-TA Задачи · SCR-WK Обход + композиция «Стадо»/«Ещё»; состояния, действия-в-1-тап,
офлайн-метки). Сюда не дублируется (P4). Рамка: farmer-канон
`Docs/AGOS-DesignRules-FarmerCabinet.md` (PhIcon/Geist/daylight), паттерн верхних табов —
`.mk-tabs` (`src/pages/cabinet/shell/screens/MarketScreen.tsx:123`), каркас `IonShellFrame` +
`TabHead` (Topbar-принцип к shell не применяется — прецедент FarmScreen.tsx:5).
HS-2: мастер профиля (ARS-212) и показ плана (ARS-215) сохраняются — маршруты в Dok6 §1.

---

## 5. Slices → Tasks (эпик ARS-276)

| Такт | Linear | Tier | Deliverable по этому слайсу | Acceptance (ядро) |
|---|---|---|---|---|
| F2 DB | ARS-278 | semantic | §1.1–1.4 таблицы+seed+RLS; RPC 2.1–2.6; FK vet_case_id в d04; события O-09..O-11; реестр имён | probe+rollback на проде (runtime-резолюция); RLS A≠B; реплей: повтор `client_event_id`/`walk_date` не дублирует; lazy-создание animal подтверждено |
| F3 DB | ARS-279 | semantic | §1.5–1.6 дельта; RPC 2.7–2.11, 2.14 + fn_feed_days_left; поправка 2.13 (d07) + фикс FARM-01; реестр | каскад сдвигает будущие задачи/окна, прошлое нетронуто; window-task immovable; PLAN_ALREADY_ACTIVE guard; повтор-complete → success |
| F4 UI | ARS-280 | semantic | каркас `.mk-tabs` Обзор·Задачи·Стадо·Ещё; Dok6 §1 маршруты; мастер+план сохранены (HS-2) | все существующие флоу ARS-212/215 достижимы; дефолт Обзор |
| F5 UI | ARS-281 | mechanical | SCR-OV по Dok6 §2 на `rpc_get_farm_overview` | handoff §10: ≤30 сек без скролла; действия в 1 тап |
| F6 UI | ARS-282 | mechanical | SCR-TA·Неделя по Dok6 §3 на `rpc_get_tasks_horizon('week')` | «горит» первым; чек синхронен с Обзором |
| F7 UI | ARS-283 | mechanical | SCR-TA·Месяц по Dok6 §3 (окна-диапазоны, подготовка, вехи) | окна = заливки диапазонов; вехи derived |
| F8 UI | ARS-284 | mechanical | SCR-TA·Год по Dok6 §3 + сдвиг случки (preview→confirm→2.9) | пересчёт только будущего; подтверждение обязательно |
| F9 UI | ARS-285 | mechanical | таб Стадо + SCR-WK по Dok6 §4–5 на RPC 2.1–2.6 (действие «Осмотр» — 2.14 из F3) | отклонение ≤2 действий; отметка мгновенно меняет зону «Стадо» |
| F10 | ARS-286 | semantic | offline-слой по §8 (кэш-юниты + outbox + реплей) | все экраны открываются из кэша с меткой; очередь переживает перезапуск |
| F11 QA | ARS-288 | mechanical | сид 86 голов + сценарии по handoff §10 + матрица §6 | прогон qa/scenarios |
| F12 | ARS-287 | mechanical | RPC 2.12 + UI ручного ввода остатков (опционально, решение CEO) | без F12 зона «Ресурсы» честно «не ведётся» |

Порядок: F2‖F3 → F4 → F5..F9 (после соответствующего DB-такта) → F10 → F11; F12 — по решению CEO.
«Where it lives» в коде не фиксируется здесь — собирается на code-start из graphify (feature-flow).

---

## 6. Матрица живых связей → контракт данных (handoff §7)

Кэш-юниты (D145): `overview` = 2.7 · `horizon(w|m|y)` = 2.8 · `herd_board` = 2.4 · `animal_card(id)` = 2.5.

| Действие | RPC | Пишет | Событие | Инвалидирует (refetch/patch) |
|---|---|---|---|---|
| «Обход сделан» | 2.1 | `farm_walkthroughs` | O-09 | `overview.herd` (янтарная→зелёная), `herd_board.walkthrough` |
| Добавлено отклонение | 2.2 | `animals` (lazy), `animal_events` | O-10 | `overview.attention`+счётчик, `herd_board.open_events`, `animal_card` |
| Закрыто отклонение | 2.3 | `animal_events` | O-11 | `overview.attention`, `herd_board`, `animal_card` |
| «Ветврачу» | 2.6 | `vet_cases`, `animal_events.vet_case_id` | V-01(+animal_event_id) | `overview.attention` (кнопка → «кейс открыт»), `herd_board`, `animal_card` |
| Отметка задачи (Обзор или Задачи) | 2.13 | `farm_tasks` (+`herd_events` по D80) | O-05 | `overview.tasks`+`today`, `horizon(week)`, `horizon(month).grid` — общий факт, обе поверхности |
| Создана задача (ручная «+» / «Осмотр» из отклонения) | 2.14 | `farm_tasks` | — (нет потребителя) | `horizon(week)`, `overview.today`+`attention` (у события появляется task_id) |
| Перенос «На сегодня» | 2.10 | `farm_tasks.due_date` | — (нет потребителя) | `horizon(week)`, `overview.today`; окно НЕ инвалидируется (не двигалось) |
| Сдвиг «старта случки» | 2.9 | `farm_phases`, `farm_tasks` | O-04 | ВСЕ: `overview`, `horizon(week|month|year)` — полная перегенерация |
| Активация плана | 2.11 | `farm_production_plans` | O-01 | `overview.cycle`, `horizon(*)` |
| Окно закрылось с остатком | — (derived чтением) | — | O-12 📋 | видно при следующем чтении `overview.attention` |
| Новые сутки | — | — | — | правило рендера: `walkthrough.walk_date ≠ p_today` → «нет данных»; кэш не трогается |

Live-канал (опционально v1, обязательно к F10-проверке): подписка на `platform_events` INSERT
(`event_type in ('ops.walkthrough.marked','ops.animal_event.opened','ops.animal_event.closed','ops.farm_task.completed','ops.farm_phase.rescheduled')`),
debounce, → точечный refetch затронутых кэш-юнитов. Базовый механизм без Realtime: refetch по
фокусу/PTR (паттерн FarmScreen reload).

---

## 7. «Дни запаса» — формула и фолбэки (D143)

`fn_feed_days_left(farm_id, today)` (build F3, экспозиция F12):

```
daily_kg(feed_item) = Σ по активным herd_groups фермы:
  Priority 1: активный рацион группы (rations.status='active' → последняя ration_versions.items
              [{feed_item_id, kg_per_day}]) × head_count
  Priority 2: feed_consumption_norms(farm_type, animal_category_id, season).items × head_count
              (farm_type ← fn_derive_farm_archetype → fn_activity_to_farm_type, reuse F-D11/F-D14)
  Priority 3: НЕТ. Группа без базы не считается; ни одного выдуманного кг (инвариант §2.1).

days_left(feed_item) = floor(farm_feed_inventory.quantity_kg / daily_kg)   -- показ в ДНЯХ
tracked = есть ли хоть одна позиция инвентаря И хоть одна группа с базой расхода
signal 'buy' = days_left < p_threshold_days (default 14 — гипотеза §9.7, параметр RPC;
               вынести в конфиг-таблицу при появлении второго потребителя порогов, P8-флаг)
```

- `season`: v1 — маппинг месяца (Nov–Mar `winter`, Jun–Sep `summer`, иначе `transition`),
  константа в fn с комментарием + override-параметром; кандидат в data-конфиг (P8) вместе с порогом.
- `tracked=false` → зона «Ресурсы» = «не ведётся» + вход в настройку (F12) — не нули и не прочерки-как-ноль.
- Порог «расход выше плана %» (§9.1 четвёртый источник отклонений) — НЕ строится в v1: расход
  не журналируется до узла 4 (открытый вопрос §12.5); сигналы кормов v1 = только `days_left`.

---

## 8. Offline-контракт (D145)

**Read-кэш.** Юнит кэша = ответ агрегатного RPC (§6) + `fetched_at`. UI всегда рендерит кэш
сразу; подзаголовок «данные на HH:MM» — из `fetched_at`, когда офлайн или кэш старше порога.
Хранение — локальное (IndexedDB/localStorage; выбор носителя — F10, human-led). Кэш переживает
перезапуск приложения. Никогда не блокировать экран сетью (handoff §2.5).

**Outbox (очередь записи).** Операции v1: `mark_walkthrough` · `log_animal_event` ·
`complete_farm_task` · `reschedule_farm_task` · `close_animal_event` · `create_farm_task`.
Формат: `{op_id(uuid), rpc_name, params, queued_at}`; `log_animal_event` кладёт
`client_event_id = op_id`, `create_farm_task` — `client_task_id = op_id`. FIFO в пределах
фермы; таймстампы полевые (`occurred_at`, `p_walk_date`, `p_completed_at`) — из очереди,
не из момента реплея.

**Идемпотентность реплея** (классы §2): NK — `(farm_id, walk_date)`; CID — `client_event_id`;
FSM — повтор complete/close/activate возвращает success с текущим состоянием (поправка 2.13 —
пререквизит F10). Реплей «отправил-не-узнал» безопасен для всех пяти операций.

**Ошибки реплея.** 5xx/сеть → retry с backoff, элемент остаётся. 4xx/доменный отказ
(`{ok:false}`) → элемент помечается «не записалось» и показывается пользователю списком
с выбором «повторить/убрать» — тихого дропа НЕТ. Конфликт «сервер уже другой» решает сервер
(server truth on read): после дренажа очереди — refetch затронутых юнитов.

**Часы клиента.** Сервер принимает полевые таймстампы в разумном окне (не будущее >1 сут),
иначе clamp к `now()` с флагом в ответе — защита от сбитых часов без потери факта.

---

## 9. Решения (D-записи; зеркала-строки в Dok1 §6)

| # | Решение | Альтернативы (отклонены) | Последствия |
|---|---|---|---|
| **D140** | `animals` = лёгкий identity-слой ПОВЕРХ D20: lazy-создание при первом событии; `head_count` остаётся на `herd_groups` (P4); НЕ поголовный учёт движения | (а) полный поголовный учёт — ломает D20, требует инвентаризации на старте (против P11 и «ввода по исключению»); (б) номер бирки текстом внутри события без сущности — нет истории животного, нет карточки, дубль факта в каждом событии | Легко: карточка животного, чипы, будущий ИСЖ/RFID-синк (ADR-ANIMAL-01). Трудно: «сколько голов» из animals не спросить — и не надо (граница явная). Инвентаризация/раскол наполняют реестр дальше |
| **D141** | Окно = window-семантика на `farm_tasks` (`window_start/end`, `head_count_planned/done`, `parent_task_id`; `due_date = window_end`) | отдельная сущность `farm_windows` — раздваивает факт «работа к сроку» (P4), дублирует FSM/RLS/кроны; синк task↔window стал бы источником дрейфа | Существующие due_soon/overdue кроны и FSM работают без изменений; координация с вет-окнами по датам (D75) сохраняется; раскол-чек садится на `head_count_done` аддитивно |
| **D142** | Словарь отклонений = `animal_event_types` lookup (P8), платформенный, seed 6 типов, admin-write | CHECK-enum на колонке — правка словаря стала бы деплоем кода, против P8 и «финализировать с ветврачом» | Ветврач правит словарь данными; org-кастомные типы — аддитивный путь (колонка organization_id nullable) при появлении потребности |
| **D143** | Дни запаса = `quantity_kg ÷ плановый суточный расход`; Priority 1 рацион → Priority 2 нормы → **Priority 3 НЕТ** (нет базы — «не ведётся») | хардкод-дефолты как Priority 3 (аналог consulting engine) — кабинет показал бы выдуманные цифры, нарушая инвариант «ок без данных запрещён» | Порог 14 дн = параметр (конфиг-кандидат P8); зона честно «не ведётся» до F12/узла 4; reuse fn_derive_farm_archetype |
| **D144** | Сдвиг «старта случки» = `rpc_shift_breeding_start`: ownership-guard + делегирование D104 + сдвиг задач сдвинутых фаз (будущее) + confirm через fn_preview_cascade | (а) прямой вызов fn_shift_phase_cascade из UI — нет org-guard (SEC-RPC-ORGTRUST-01), задачи остались бы на старых датах; (б) расширение самого fn_ — меняет контракт D104, которым владеет эксперт-консоль (P7) | Прошлое неприкосновенно; Месяц/Неделя перегенерируются следующим чтением; эксперт-путь не тронут |
| **D145** | Offline: read-кэш агрегатов с меткой + outbox; 3 класса идемпотентности (NK/CID/FSM); ошибки реплея видимы, тихого дропа нет | локальная БД с двусторонним синком (CRDT/etc) — несоразмерно v1; блокирующие спиннеры — против §2.5 handoff | Агрегатные RPC = границы кэша (дизайн-инвариант: новый экран = новый агрегат); поправка 2.13 обязательна до F10 |
| **D146** | Вехи = derived (границы фаз + задачи-окна + вет-items), без таблицы | таблица milestones — второй дом для фактов, которые уже лежат в фазах/задачах (P4), и её пришлось бы каскадно двигать при D104 | Вехи всегда согласованы с источником; кастомные вехи фермера — аддитивная таблица потом, если попросят |
| **D147** | «Ветврачу» = `animal_events.vet_case_id` → `vet_cases` (`created_via='cabinet_farmer'`), символиз V-01 + `payload.animal_event_id`; `herd_events` НЕ трогаем | писать отклонения в `herd_events` — там количественный журнал групп (D25/D50), адресное событие по бирке — другой факт; новое событие `ops.animal_event.escalated` — дубль V-01 | Вет-контур получает контекст (событие→кейс), фермер видит «кейс открыт» в той же строке; авто-закрытие события при resolve кейса — кандидат след. скоупа |

---

## 10. Conflict / invariant check (G1)

- **P7 additive:** только новые таблицы и `add column if not exists`; сигнатуры существующих
  RPC не меняются (2.13 — уточнение поведения без смены контракта: ошибка → success, вызывающие
  не ломаются); `fn_shift_phase_cascade`/`fn_preview_cascade` не редактируются.
- **Схема FINAL не нарушена:** ни одна существующая колонка/CHECK не модифицируется, кроме
  документированных idempotent-паттернов CHECK-эволюции — их в этом слайсе НЕТ.
- **RLS / межорг-утечка:** 4 новые таблицы с org-политиками; каждый RPC — `p_organization_id` +
  ownership-guard (SEC-RPC-ORGTRUST-01); `animal_event_types` — глобальный справочник без
  фермерских данных. Новые гранты сразу `revoke from public` (не наследуем SEC-GRANT-PUBLIC-01).
- **Ст. 171:** не затрагивается — нет цен, торговли, координации предложения.
- **D61:** словарь отклонений ≠ дозировки; RPC не генерируют назначения.
- **D20/D25/D50/D75/D104:** явно сохранены (§1.1, §1.3, §1.5, §2.9).
- **HS-2:** мастер (ARS-212), показ плана (ARS-215), HerdOverview/группы (ARS-171 скоуп) —
  сохраняются; Dok6 §1 фиксирует маршруты.
- **DECISIONS_LOG:** противоречий с D1–D139 не найдено; D140–D147 добавляются.
- **⚠️ Существующий долг (не создаём, фиксируем):** `fn_shift_phase_cascade` — SECURITY DEFINER
  без org-guard и с PUBLIC execute (класс SEC-GRANT-PUBLIC-01, IMPL_DEBT). Фермерский путь —
  только обёртка 2.9. Рекомендация F3: `revoke from public` на `fn_shift_phase_cascade`/
  `fn_preview_cascade` после сверки вызывающих эксперт-консоли (отдельный точечный чек).

## 11. Verification (G3)

- `cross_check.sh` — 0 critical после каждого DB-такта.
- **RLS-тесты:** org A ≠ org B на `animals`/`animal_events`/`farm_walkthroughs` под
  authenticated-JWT (не privileged-SQL — memory `agos-qa-seed-farmer`).
- **FSM/идемпотентность:** двойной `mark_walkthrough` (same date) = 1 строка; реплей
  `client_event_id` = 1 событие; двойной complete = success без дублей `herd_events`;
  `WINDOW_TASK_IMMOVABLE`; активация при живом active-плане = graceful отказ.
- **Каскад:** сдвиг случки двигает только будущие фазы/окна/задачи (fixture: смесь
  completed/scheduled) — прошлое побайтно нетронуто.
- **Runtime-резолюция:** новые RPC прогоняются probe+rollback на проде до merge
  (memory `plpgsql-runtime-resolution-blindspot`, `agos-db-verify-via-probe-rollback`).
- **Preview-прогон:** сид-ферма F11 (86 голов) → обход: отметка+отклонение ≤2 действий →
  Обзор обновился; критерии handoff §10 полностью.
- **Merge ≠ deploy:** прод-деплой дельт — отдельный шаг по решению CEO
  (memory `agos-merge-not-equal-deploy`); сверка pg_proc после «done».

## 12. Открытые вопросы (handoff §12) — владельцы и сроки

| # | Вопрос | Владелец | Срок/гейт | Заметка |
|---|---|---|---|---|
| 1 | Раздача задач помощникам: неделя вперёд или утро дня | CEO (полевая проверка 1–2 хозяйства) | до старта F6 (ARS-282) | модель уже держит `assigned_to`; влияет только на видимость в UI |
| 2 | Словарь отклонений — финал с ветврачом | CEO → ветврач TURAN | до прод-деплоя F2 (ARS-278) | словарь = данные (D142), правится без кода в любой момент |
| 3 | Роли: усечённый Обзор помощникам; кто выбирает дату в окне | CEO | до старта F5 (ARS-281) | v1: все члены org видят всё (текущая RLS-модель); сужение — аддитивно |
| 4 | Вечерняя отметка обхода | CEO (после полевой проверки) | после v1 | путь эволюции зафиксирован (§1.4 slot) |
| 5 | Узел 4 «Учёт кормов» (приход/расход) | CEO (приоритизация) | отдельный эпик | до него: F12 ручные остатки или честное «не ведётся» (D143) |

---

**Конец слайса.** Дельты канона: Dok1 (§2/§3/§4/§5.7/§5.8/§6), Dok3 (§7a), Dok4 (§1, §3.6a),
Dok6 Slice8 — все указывают сюда. DECISIONS_LOG.md — запись 2026-07-21 (ARS-277).
