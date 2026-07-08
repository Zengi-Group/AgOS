# AGOS — Модуль «Ферма» · Карта покрытия «построено vs нужно» (ARS-169)

> **Reconciliation audit. Ноль изменений кода** — только аудит + карта (HS-1/2/5).
> Спутник функциональной спеки `AGOS-Farm-Module-FunctionalSpec-v0_1.md` §A7 (реконсиляция с построенным).
> Метод: 4 параллельных read-only инвентаризации (ядро d01 · ЦТК-движок d05 · RPC-слой · UI src/),
> каждый факт сверен с задеплоенным SQL (номера строк ниже — эффективные, последние определения; L-1/L-6).
> Дата: 2026-07-08. База: `origin/main` @ c5265de.

## Легенда
✅ **есть** (построено, живое) · 🟡 **частично** (есть каркас, неполный контент/фича) · 🔨 **нужно** (строить аддитивно) · ⛔ **дефект** (код ≠ канон / сломано)

---

## TL;DR (для декомпозиции 170/171/172)

1. **Ядро + ЦТК-движок построены и живые** — углубляем аддитивно, НЕ переписываем (HS-1/2/5). Движок ЦТК = `d05` (шаблоны + `fn_generate_production_plan` + инстанс), подтверждает F-D9.
2. **3 конфликта C1/C2/C3 → решены (F-D10/11/12) и сверены с кодом:** C1 ✅ код уже соответствует; C3 ✅ схема соответствует (nullable expert, draft-статус, one-active индекс); C2 🔨 решение принято, но **мост в коде отсутствует**.
3. **Главные «нужно»:** (а) архетип-**опросник Узла 1 отсутствует** → ARS-170; (б) **мост `activity_type→farm_type`** (F-D11) не реализован; (в) 8 farm-компонентов живут на `/cabinet-legacy`, не в primary `/cabinet`.
4. **2 настоящих дефекта в ЦТК-lifecycle:** `rpc_get_production_plan` сломан (читатель draft), нет `rpc_activate_production_plan` (draft→active). **Self-service петля F-D12 собрана только на 1/3** (создание draft ✅, просмотр ⛔, активация ❌).
5. **Контент шаблонов ЦТК:** заполнен только `cow_calf` (= репродуктор, критический путь R4 ✅ имеет первый cut); `finishing/combined/breeding` — пустые шапки (F-D8, отдельные итерации).

---

## Слой 1 — Данные (прогрессивное накопление, лестница L1→L4)

| Факт | Реальность в коде | Статус |
|---|---|---|
| `data_source` enum `registration/ai_extracted/platform/erp` | `farms` d01:738 · `herd_groups` d01:803 · `herd_events` d01:876 · `farm_feed_inventory` d03:229 | ✅ |
| `confidence` на **стаде** | `herd_groups.confidence` int 0–100 default 25 — d01:810 | ✅ |
| `confidence` на **запасе кормов** | `farm_feed_inventory.confidence` in(25,50,75,95) default 25 — d03:243 | ✅ |
| `confidence` **НЕ** на `farms` (рамка канона F-D10) | отсутствует — подтверждено grep | ✅ |
| маппинг data_source→confidence (higher перезаписывает lower, D21) | `rpc_upsert_herd_group` пишет `ai_extracted`; d03 `rpc_upsert_feed_inventory` маппит (d03:1077) | ✅ |
| **полнота профиля фермы = вычисляемый %** (F-D10, без хранимой колонки) | нет RPC/вьюхи, считающей % | 🔨 нужно (индикатор для Узла 1) |

---

## Слой 2 — Ядро «Ферма» (владелец модуля, D20 = уровень групп)

| Сущность | Таблица (строка) | Ключевое | RLS/org | Статус |
|---|---|---|---|---|
| Паспорт фермы | `farms` d01:716 | `shelter_type`[stall/pasture/mixed/feedlot], `calving_system`[spring/autumn/year_round/two_season], `data_source`, `is_primary` | ✅ RLS d01:1630, org denorm | ✅ |
| Виды деятельности (архетип) | `farm_activity_types` d01:761 (junction D19) | `activity_type`[cow_calf/finishing/dairy/breeding/mixed], UNIQUE(farm,type) | ✅ через parent-farm | ✅ |
| Стадо (группы) | `herd_groups` d01:793 | `head_count`, `avg_weight_kg`, `confidence`, `data_source`, категория = FK `animal_categories` (P6/P8, не CHECK) | ✅ RLS d01:1668, org denorm | ✅ |
| Журнал событий | `herd_events` d01:843 | **17 event_type** (d01:851-869), append-only (нет `updated_at`, нет update/delete policy — D25), `delta` GENERATED | ✅ RLS d01:1698 insert-only | ✅ |

**Ядро построено полностью.** Категории стада — через справочник `animal_categories` + маппинги (P8-совместимо), не хардкод.

---

## Слой 3 — ЦТК-движок (шаблон ∘ профиль → инстанс) — **уже построен, F-D9**

### Template-сторона (стандарт, per архетип)
| Объект | Строка | Ключевое | Статус |
|---|---|---|---|
| `production_cycle_templates` | d05:119 | `farm_type` CHECK **[cow_calf/finishing/combined/breeding]**; версия = флаг `is_active`+`is_recurring` (НЕ temporal `version/valid_from`) | ✅ структура |
| `phase_templates` | d05:156 | offset-от-старта, `date_type`[sequential/calendar/parallel], `depends_on_phase_code`+`lag_days`, `animal_category_codes[]` | ✅ |
| `task_templates` | d05:189 | category[zootechnical/veterinary/management], `creates_herd_event`+`herd_event_type` | ✅ |
| `kpi_templates` | d05:311 | kpi_type (weight_gain/daily_gain/calving_rate/…), target+tolerance | ✅ |
| `sop_documents` | d05:242 | все seed = `status='draft'`, `storage_url` NULL (плейсхолдеры) | 🟡 контент |
| **Контент шаблонов** | d05:1603+ | `cow_calf`: BEEF_COW_CALF_KZ + BEEF_FARM_LAUNCH_KZ → 16 phase + 13 task + 1 kpi INSERT. `finishing/combined/breeding` = только header-строки, 0 фаз/задач | 🟡 репродуктор✅ / остальные 🔨 (F-D8) |

### Instance-сторона (ферма × год)
| Объект | Строка | Ключевое | Статус |
|---|---|---|---|
| `farm_production_plans` | d05:360 | `expert_profile_id` **NULLABLE** (d05:366), `status`[draft/active/completed/cancelled] default draft, partial-unique `idx_farm_plan_one_active` on `status='active'` (d05:396) | ✅ |
| `farm_phases` | d05:406 | `start_date`/`end_date` NOT NULL + CHECK(end>start) — **строго date-based**; cascade-deps | ✅ (R1 ниже) |
| `farm_tasks` | d05:448 | status[scheduled/reminded/in_progress/completed/skipped/overdue], `herd_event_id` линк | ✅ |
| `farm_kpis` | d05:506 | target/actual, авто-evaluate триггером (d05:1340) | ✅ |
| `fn_generate_production_plan()` | d05:3309 | шаблон → plan+phases+tasks+kpis (batch INSERT), emit `ops.production_plan.started` | ✅ |

> **R1 (из F-D9):** `farm_phases` строго date-based; **вес-триггерный цикл откорма** («перевод при 450 кг») в текущую схему **не ложится**. Не закрывать этот путь при проектировании репродуктора — откорм отложен, но модель фаз к нему вернётся.

---

## Слой 4 — RPC (SECURITY DEFINER, org-scoped)

| RPC / fn | Файл:строка | Назначение | Статус |
|---|---|---|---|
| `rpc_upsert_farm` | d01:3789 | create/update фермы | ✅ RPC-05 |
| `rpc_set_farm_activity_types` | d01:3906 | заменить виды деятельности | ✅ RPC-05b |
| `rpc_upsert_herd_group` | **d07:1856** | create/update группы стада | ✅ |
| `rpc_log_herd_event` | d01:4736 | append-only событие | ✅ RPC-07 |
| `rpc_get_farm_summary` | d01:4862 | кросс-доменный срез (стадо+корма+вет+задачи) | ✅ RPC-08 |
| `rpc_list/resolve/get/add/deprecate/migrate_*_category` | d01:5444+ | таксономия стада (справочник, admin-gated) | ✅ |
| `rpc_start_production_plan` | d05:3159 | **self-service** запуск ЦТК из шаблона (draft по умолчанию; activate только при `p_auto_activate`) | ✅ |
| `rpc_get_active_plan` | d05:3637 | активный план + фазы + KPI (**только active**) | ✅ RPC-37 |
| `rpc_get_farm_tasks` | d07:130 | ближайшие задачи | ✅ |
| `rpc_complete_farm_task` | d07:184 | закрыть задачу | ✅ |
| `rpc_get_feeding_plan` / `rpc_get_ai_farm_context` | d07:58 / d07:1570 | крючок Feed / контекст AI | ✅ |
| `fn_shift_phase_cascade` / `fn_preview_cascade` | d05:2842 / d05:3004 | сдвиг фаз с каскадом | ✅ RPC-35/36 |
| `rpc_get_production_plan` (**единственный читатель draft**) | d07:260 | фазы плана по статусу | ⛔ **FARM-01** |
| `rpc_activate_production_plan` (draft→active) | — | перевод draft в active после создания | ❌ **FARM-02** |
| мост `activity_type → farm_type` (F-D11) | — | авто-выбор шаблона по архетипу фермы | ❌ нужно |
| вычисление полноты профиля % (F-D10) | — | индикатор прогрессии для Узла 1 | 🔨 нужно |

> **Наблюдение (гигиена доменов, не баг):** 6 farm/plan RPC (`upsert_herd_group`, `get_farm_tasks`, `complete_farm_task`, `get_production_plan`, `get_feeding_plan`, `get_ai_farm_context`) физически определены в `d07_ai_gateway.sql`, хотя зарегистрированы в `rpc_name_registry` внутри d01. Домен «Ферма» размазан по d01+d05+d07.

---

## Слой 5 — UI (Vite+React+TS)

Все 8 компонентов спеки существуют и **живо подключены** (реальные `supabase.rpc`, без моков), в `src/pages/cabinet/`:

| Компонент | Путь | RPC | Статус |
|---|---|---|---|
| FarmProfile (907 стр) | `cabinet/FarmProfile.tsx` | upsert_farm · set_farm_activity_types · upsert_herd_group | ✅ live |
| HerdOverview | `cabinet/herd/HerdOverview.tsx` | get_farm_summary | ✅ live |
| HerdGroupForm | `cabinet/herd/HerdGroupForm.tsx` | upsert_herd_group · log_herd_event | ✅ live |
| ProductionPlan | `cabinet/plan/ProductionPlan.tsx` | get_active_plan | ✅ live |
| TaskList | `cabinet/plan/TaskList.tsx` | get_farm_tasks · complete_farm_task | ✅ live |
| Timeline | `cabinet/plan/Timeline.tsx` | get_active_plan | ✅ live |
| CascadePreview | `cabinet/plan/CascadePreview.tsx` | fn_preview_cascade · fn_shift_phase_cascade | ✅ live |
| KpiDashboard | `cabinet/plan/KpiDashboard.tsx` | get_active_plan | 🟡 только summary-счётчики (per-phase detail = future) |

**Структурные находки:**
- ⚠️ Все 8 смонтированы на **`/cabinet-legacy`** (App.tsx:197-225), НЕ на primary `/cabinet` (`CabinetApp` shell, CEO-решение 2026-06-23). Primary cabinet имеет отдельную farm-поверхность с `seedFarm()` demo-фолбэком. → перенос/переиспользование в primary — отдельная работа.
- ⛔ **Архетип-опросник Узла 1 ОТСУТСТВУЕТ.** `FarmProfile` = плоская edit-форма + мульти-селект из 5 чипов (`cow_calf/finishing/dairy/breeding/mixed`), **без ветвления** по архетипу (репродуктор/откорм/полный-цикл). Единственные `*Wizard*` в репо — TSP BatchWizard и consulting ProjectWizard (не farm).
- ✅ Topbar-принцип соблюдён во всех 8 (`useSetTopbar` + иконка = Sidebar).

---

## Переиспользуем vs строим (явно — HS-1/2/5)

### ✅ Переиспользуем как есть (НЕ трогаем)
- **Ядро:** `farms`/`farm_activity_types`/`herd_groups`/`herd_events` + RLS + `rpc_upsert_farm`/`set_farm_activity_types`/`upsert_herd_group`/`log_herd_event`/`get_farm_summary` + таксономия `animal_categories`.
- **ЦТК-движок целиком:** template-таблицы + `fn_generate_production_plan` + instance-таблицы + `rpc_start_production_plan` + cascade-функции.
- **8 UI-компонентов** (live-wired).
- **Контент репродуктора** (`cow_calf`) — первый cut уже засеян (R4 критический путь ✅ не пустой).

### 🟡 Углубляем аддитивно
- Контент шаблонов `finishing/combined/breeding` (F-D8 — отдельные итерации; репродуктор доводим первым).
- `KpiDashboard` — per-phase KPI-детализация (нужен доп. read-RPC).
- Перенос 8 компонентов в primary `/cabinet`.
- SOP-документы: залить реальные файлы вместо draft-плейсхолдеров.

### 🔨 Строим новое (аддитивно, поверх готового)
- **Узел 1 — архетип-опросник** (ARS-170): новый wizard поверх существующих `rpc_upsert_farm`/`set_farm_activity_types`/`upsert_herd_group`; ветвление по архетипу; не переспрашивать известное (F-Q3).
- **Мост `activity_type→farm_type`** (F-D11): функция/справочник `cow_calf→cow_calf, finishing→finishing, mixed→combined, breeding→breeding` для авто-преселекта шаблона ЦТК.
- **`rpc_activate_production_plan`** (FARM-02): недостающий переход draft→active.
- **Вычисление полноты профиля %** (F-D10).

---

## Верификация 3 конфликтов (канон ↔ код) → F-D10/11/12

| # | Решение CEO (2026-07-08) | Код-реальность | Вердикт |
|---|---|---|---|
| **C1 / F-D10** | Layered Truth сужен: `confidence` только `herd_groups`+`farm_feed_inventory`; полнота фермы = вычисляемый % | `confidence` на herd_groups (d01:810) + farm_feed_inventory (d03:243); НЕТ на farms; % не считается нигде | ✅ **схема уже соответствует.** Остаётся построить вычисление % (не меняя схему — P4) |
| **C2 / F-D11** | Канон архетипа для ЦТК = `production_cycle_templates.farm_type`; мост `mixed→combined` | `farm_type`[cow_calf/finishing/combined/breeding] есть (d05:125); `activity_type`[…/mixed] есть (d01:765); **моста в коде НЕТ** (grep пусто) | 🔨 **решение принято, мост не реализован.** Сейчас шаблон выбирается вручную по UUID (`p_template_id`) |
| **C3 / F-D12** | Инстанс = self-service `draft`; эксперт опционален (`expert_profile_id` nullable) | `expert_profile_id` nullable (d05:366) ✅; `draft` в статус-FSM ✅; `idx_farm_plan_one_active` только на active ✅; создание draft = `rpc_start_production_plan` ✅ | ✅ **схема + создание draft соответствуют**, НО просмотр+активация draft сломаны/отсутствуют → FARM-01/02. Петля F-D12 собрана на 1/3 |

---

## Дефекты и дивергенции (surfaced — НЕ чиню, ARS-169 = zero-code)

Драфты для `IMPL_DEBT.md` (Phase-2). Флагирую, не резолвлю (CLAUDE.md conflict-resolution).

| id | что | файл | суть | предлагаемый фикс | блокирует |
|---|---|---|---|---|---|
| **FARM-01** | `rpc_get_production_plan` сломан | d07:280-283 | селектит `fpp.plan_name`/`plan_start_date`/`plan_end_date`, а таблица имеет `name`/`cycle_start_date`/`cycle_end_date` (d05:367-370) → runtime `column does not exist`. Единственный читатель draft-плана | переименовать колонки в SELECT (аддитивно, сигнатура не меняется — P7) | ARS-172 (просмотр draft перед активацией) |
| **FARM-02** | нет `rpc_activate_production_plan` | — | draft переводится в active **только при создании** (`p_auto_activate:=true`); после создания перехода draft→active нет ни одного RPC (`rpc_activate_*` есть только в d02/d04) | новый аддитивный RPC draft→active (+ проверка `idx_farm_plan_one_active`) | ARS-172 (self-service активация, петля F-D12) |

**Заметки (не дефекты, low-prio):**
- `activity_type` включает `dairy` (d01:769), что противоречит F-D1 «только мясное» — аддитивная чистка когда-нибудь, не срочно.
- CHECK `confidence` рассинхрон: `herd_groups` = континуум 0–100, `farm_feed_inventory` = дискрет in(25,50,75,95). Косметика.
- Домен «Ферма» размазан d01+d05+d07 (6 RPC в d07) — гигиена, не баг.

---

## Привязка к downstream (разблокирует ARS-170/171/172)

- **ARS-170 · Профиль-опросник:** 🔨 BUILD wizard (архетип-ветвление, F-Q3 не-переспрашивание). ✅ REUSE `rpc_upsert_farm`/`set_farm_activity_types`/`upsert_herd_group`. Нужен: мост F-D11 (преселект шаблона) + вычисление полноты % (F-D10).
- **ARS-171 · Стадо/группы:** ✅ в основном ГОТОВО — REUSE `herd_groups` + `HerdOverview`/`HerdGroupForm` + `rpc_upsert_herd_group` + таксономия. Углубление, не постройка.
- **ARS-172 · ЦТК-движок (каркас):** ✅ REUSE весь движок. 🔨 BUILD: фикс **FARM-01** + новый **FARM-02** + мост F-D11; доводка контента `cow_calf`. Без FARM-01/02 self-service петля F-D12 неполна.
- **ARS-173/174 · крючки Vet/Feed** (позже): REUSE кросс-доменного `rpc_get_farm_summary` + `rpc_get_feeding_plan`.

---

*Аудит выполнен параллельными read-only агентами, каждый факт сверен с задеплоенным SQL/src. Ноль изменений кода.*
