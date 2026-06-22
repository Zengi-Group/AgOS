# AGOS Dok 7 — Архитектура: Унификация Рационов и Консалтинга
## Версия 1.1 · Апрель 2026

> **v1.1 (2026-04-14):** добавлены §9 «Сезонная модель рациона» и §10 «Simple ↔ NASEM: разделение ответственности». Новые ADR-FEED-05 и ADR-FEED-06. Остальные разделы 1.0 без изменений.

> **Статус:** Утверждено · Аршидин + Architect Agent  
> **Контекст:** Решение принято в ходе сессии 08.04.2026 после анализа дублирования между `d03_feed.sql` и `d09_consulting.sql`

---

## 1. Проблема

### 1.1 Дублирование справочных данных

В системе существуют **два независимых хранилища** данных о кормах:

```
d03_feed.sql                           d09_consulting.sql
──────────────────────────────         ─────────────────────────────────────
feed_items          (справочник)       consulting_reference_data
feed_prices         (цены)               category = 'feed_prices'   ← ДУБЛЬ
nutrient_requirements (NASEM нормы)      category = 'feed_norms'    ← ДУБЛЬ
```

Admin вынужден обновлять данные в двух местах. Риск расхождения цен и норм между модулями.  
Нарушение принципа **P8 — единственный источник правды для нормативов**.

### 1.2 Различие между `nutrient_requirements` и `feed_norms`

Это **разные уровни абстракции** — не дубликаты, но связанные:

| | `nutrient_requirements` | `consulting_reference_data.feed_norms` |
|---|---|---|
| **Что хранит** | Что животному нужно (NASEM) | Что животное ест (практика) |
| **Формат** | 20+ числовых полей (me_mj, cp_g, dm_kg...) | JSONB: [{feed_code, kg_per_day}] |
| **Используется** | LP-solver как constraint | Python engine как lookup |
| **Происхождение** | Зоотехнический стандарт | Экспертная оценка или кэш NASEM |

`feed_norms` — это по сути **кэш результата NASEM-расчёта**, записанный вручную:

```
nutrient_requirements → [LP Solver] → ration items == feed_norms
   "сколько нужно"                     "сколько кормить"
```

### 1.3 Consulting не использует NASEM калькулятор

Python `feeding_model.py` читает упрощённые нормы из `consulting_reference_data`  
и умножает напрямую: `kg_per_day × price × head_count × days → COGS`.  
Точный NASEM-расчёт для консалтинговых проектов недоступен.

### 1.4 Нет пути переноса Consulting → Ферма

Консалтинговый проект содержит параметры стада и технологию — всё нужное для онбординга реальной фермы. Но данные несовместимы по формату с `rations`/`ration_versions`.

---

## 2. Архитектурное решение: три независимых слоя

### Слой 0 — Справочник (shared reference, admin-managed)

**Единственный источник правды для всей системы.**

```
d03_feed.sql
├── feed_categories              ← таксономия кормов
├── feed_items                   ← каталог кормов (18+ позиций)
├── feed_prices                  ← цены (расширить: + valid_from, valid_to, region_id)
├── nutrient_requirements        ← NASEM стандарты (потребности животных)
├── feed_consumption_norms       ← NEW: типовые нормы кормления (кг/день по категориям)
└── animal_categories            ← shared (d01_kernel)
```

**`feed_consumption_norms` (новая таблица в d03_feed):**
```sql
CREATE TABLE feed_consumption_norms (
    id          UUID PRIMARY KEY,
    farm_type   TEXT NOT NULL,               -- beef_reproducer | feedlot | sheep_goat
    animal_category_id UUID NOT NULL REFERENCES animal_categories(id),
    season      TEXT NOT NULL,               -- winter | summer | transition
    items       JSONB NOT NULL,              -- [{feed_item_id, kg_per_day}]
    valid_from  DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to    DATE,
    notes       TEXT
);
```

Заменяет `consulting_reference_data category='feed_norms'`.  
Доступна **всем модулям** — не только консалтингу.

**Что удаляется из `consulting_reference_data`:**
- `category = 'feed_prices'` → мигрирует в `d03_feed.feed_prices`
- `category = 'feed_norms'` → мигрирует в `d03_feed.feed_consumption_norms`

**Что остаётся в `consulting_reference_data`** (consulting-специфичное):
- `infrastructure_norms`, `equipment_norms`, `tax_rates`
- `wacc_parameters`, `subsidy_programs`, `livestock_norms`, `regional_prices`

---

### Слой 1 — NASEM Калькулятор (чистая функция, без контекста)

```
Edge Function: calculate-ration

Input:
  animal_category_id   UUID
  avg_weight_kg        number
  objective            maintenance | growth | finishing | gestation | lactation
  feed_item_ids        UUID[]      ← из feed_items (Слой 0)
  head_count           number
  quick_mode           boolean     ← true = не сохранять результат

Output:
  items[]              {feed_item_id, kg_per_day, cost_per_day}
  nutrients_met{}      {dm: bool, me: bool, cp: bool, ...}
  total_cost_per_day   number
  solver_status        feasible | infeasible
```

**Принцип:** калькулятор не знает ни о ферме, ни о консалтинговом проекте.  
Результат может быть сохранён в любом контексте.

**Статус:** Edge Function `calculate-ration` **уже реализована**.  
Изменение: убрать `farm_id` из обязательных (уже есть `quick_mode=true`).

---

### Слой 2 — Хранилище рационов (контекст-зависимое)

Сделать `ration_versions` контекст-независимым через расширение схемы:

**Изменения в `ration_versions` (d03_feed.sql):**
```sql
ALTER TABLE ration_versions
    ALTER COLUMN ration_id DROP NOT NULL,                    -- было NOT NULL
    ADD COLUMN consulting_project_id UUID                    -- NEW
        REFERENCES consulting_projects(id),
    ADD COLUMN animal_category_id UUID                       -- NEW (для consulting ctx)
        REFERENCES animal_categories(id),
    ADD CONSTRAINT ration_versions_context_check
        CHECK (ration_id IS NOT NULL OR consulting_project_id IS NOT NULL);
```

**Два контекста, один формат данных:**

```
ration_versions
├── ration_id IS NOT NULL          → контекст ФЕРМЫ
│     farm → herd_group → ration → ration_versions
│
└── consulting_project_id IS NOT NULL  → контекст КОНСАЛТИНГА
      consulting_project → ration_versions (+ animal_category_id)
```

JSONB-формат `items` и `results` — **идентичен** в обоих контекстах.  
UI-компоненты RationViewer, GroupRations переиспользуются без изменений.

---

### Слой 3 — Финансовая интеграция

Python `feeding_model.py` получает **fallback chain** для расчёта COGS:

```
Для каждой animal_category:

1. ПРИОРИТЕТ 1: consulting_project ration_versions (Слой 2)
   ↓ Если привязаны рационы → берём items[] из них
   ↓ Точный NASEM-расчёт. kg × price × head_count × days → COGS

2. ПРИОРИТЕТ 2: feed_consumption_norms (Слой 0, d03_feed)
   ↓ Если нет attached rations → используем типовые нормы
   ↓ Приближённый расчёт

3. ПРИОРИТЕТ 3: константы в коде
   ↓ Grубая оценка, только для первого черновика
```

Система **работает на любом уровне данных**. Ранние проекты → fallback.  
Детальные проекты → точные рационы.

---

## 3. Сквозной путь данных

```
┌─────────────────────────────────────────────────────────────────────┐
│  СЛОЙ 0: Справочник (d03_feed.sql)                                  │
│  feed_items · feed_prices · nutrient_requirements                   │
│  feed_consumption_norms · animal_categories                         │
└──────────────────────┬──────────────────────┬───────────────────────┘
                       │                      │
          ┌────────────▼───────────┐          │ (потребности животных)
          │  СЛОЙ 1: Калькулятор  │◄─────────┘
          │  Edge Function NASEM  │
          │  (stateless, shared)  │
          └────────────┬──────────┘
                       │ items[] + nutrients + cost
          ┌────────────▼──────────────────────────────┐
          │  СЛОЙ 2: ration_versions (единая таблица) │
          │  ration_id=X (farm ctx) OR                │
          │  consulting_project_id=Y (consulting ctx) │
          └─────────┬────────────────────┬────────────┘
                    │                    │
     ┌──────────────▼──┐       ┌─────────▼──────────────┐
     │  ФЕРМА          │       │  КОНСАЛТИНГ            │
     │  GroupRations   │       │  feeding_model.py      │
     │  FeedBudget     │       │  → cogs[120 мес]       │
     │  Summary        │       │  → P&L / Cash Flow     │
     └─────────────────┘       └────────────────────────┘
```

---

## 4. Сценарий переноса: Consulting → Ферма

Когда консалтинговый проект «активируется» как реальная ферма:

```
Consulting Project                  →  Farm Account

WizardParams.initial_cows           →  HerdGroup (Маточные, N голов)
WizardParams.reproducer_capacity    →  HerdGroup (Репродуктор, N голов)
WizardParams.project_start_date     →  FeedingPlan.start_date

ration_versions                     →  ration_versions
  (consulting_project_id = X)            (ration_id = Y, consulting_project_id = NULL)
  Рацион не копируется — меняется только FK

tech_card.phases[]                  →  ProductionPlan + phases
```

**Новый RPC (Фаза 4):** `rpc_activate_consulting_project(p_project_id, p_organization_id)`  
Создаёт Farm + HerdGroups + Rations из данных проекта. Атомарная транзакция.

---

## 5. План реализации по фазам

### Фаза 1 — Устранение дублирования (DB Agent)
**Приоритет: Высокий · Срок: 1 день**

- [ ] Расширить `feed_prices`: + `valid_from DATE`, `valid_to DATE`, `region_id UUID` (nullable)
- [ ] Создать `feed_consumption_norms` в d03_feed.sql
- [ ] Мигрировать данные из `consulting_reference_data` (feed_prices, feed_norms) в d03_feed
- [ ] Удалить категории `feed_prices`, `feed_norms` из `consulting_reference_data` (после миграции)
- [ ] Python engine: обновить `feeding_model.py` читать из `d03_feed` вместо `consulting_reference_data`
- [ ] Dok 1 update: добавить `feed_consumption_norms` в ERD и Ownership Matrix

### Фаза 2 — Контекст-независимый калькулятор (DB Agent)
**Приоритет: Высокий · Срок: 0.5 дня**

- [ ] `ration_versions.ration_id` → NULLABLE
- [ ] `ration_versions` + `consulting_project_id UUID` (nullable FK)
- [ ] `ration_versions` + `animal_category_id UUID` (nullable FK, для consulting ctx)
- [ ] CHECK constraint: `(ration_id IS NOT NULL OR consulting_project_id IS NOT NULL)`
- [ ] RLS: consulting context rations видны org members + admins
- [ ] Edge Function `calculate-ration`: убрать `farm_id` из обязательных параметров
- [ ] Dok 3 update: добавить новые RPC для ration в consulting context

### Фаза 3 — Таб «Рационы» в Consulting (UI Agent + Backend Agent)
**Приоритет: Средний · Срок: 3 дня**

- [ ] Новый таб `RationTab` в `/admin/consulting/:projectId/ration`
- [ ] Маршрут в App.tsx + топбар в ProjectPage.tsx
- [ ] Per-category NASEM калькулятор: выбор кормов → расчёт → сохранение
- [ ] Отображение attached ration versions per animal_category
- [ ] Показ расчётного COGS от рациона (сравнение с current consulting results)
- [ ] Python engine: реализовать fallback chain (ration_versions → feed_consumption_norms → defaults)
- [ ] Dok 6: screen contract A-RationTab

### Фаза 4 — Перенос проекта на ферму (DB Agent + UI Agent)
**Приоритет: Низкий · Срок: 2 дня · Зависит от: RPC-24 (rpc_get_current_ration)**

- [ ] `rpc_activate_consulting_project` — атомарный перенос в farm account
- [ ] UI: кнопка «Активировать как ферму» в ProjectPage
- [ ] Dok 1: новый FSM state `activated` для ConsultingProject
- [ ] Dok 3: RPC-C09 `rpc_activate_consulting_project`

---

## 6. Затронутые файлы

| Файл | Изменение | Фаза |
|------|-----------|------|
| `d03_feed.sql` | + `feed_consumption_norms` table; расширить `feed_prices` | 1 |
| `d09_consulting.sql` | Удалить `feed_prices`/`feed_norms` из category CHECK | 1 |
| `feeding_model.py` (Railway) | Читать из `d03_feed` вместо `consulting_reference_data` | 1 |
| `d03_feed.sql` | `ration_versions`: nullable FK + consulting_project_id | 2 |
| `calculate-ration` (Edge Fn) | Убрать `farm_id` из required | 2 |
| `src/pages/admin/consulting/ProjectPage.tsx` | + таб Рационы | 3 |
| `src/pages/admin/consulting/tabs/RationTab.tsx` | Новый компонент | 3 |
| `src/App.tsx` | + маршрут `/ration` | 3 |
| `Docs/AGOS-Dok1-v1_9.md` | + `feed_consumption_norms` в ERD; FSM update | 1, 4 |
| `Docs/AGOS-Dok3-RPC-Catalog-v1_5.md` | + RPC-C09; обновить RPC-22 | 2, 4 |

---

## 7. Ключевые решения (Architecture Decision Records)

### ADR-FEED-01: Унификация источника данных о кормах
**Решение:** Все данные о кормах (каталог, цены, нормы) живут в `d03_feed.sql`.  
`consulting_reference_data` не хранит данные, которые есть в `d03_feed`.  
**Обоснование:** P8 — единственный источник правды. Admin обновляет в одном месте.  
**Последствие:** Python engine требует обновления при переключении источника.

### ADR-FEED-02: `ration_versions` как контекст-независимое хранилище
**Решение:** `ration_versions.ration_id` nullable; добавить `consulting_project_id`.  
CHECK constraint гарантирует наличие хотя бы одного контекста.  
**Обоснование:** Единый формат данных = переиспользование UI + путь к переносу проекта.  
**Последствие:** Аддитивное изменение схемы (D87 — additive only). Существующие данные не затронуты.

### ADR-FEED-03: Fallback chain в feeding_model.py
**Решение:** Приоритет: attached ration_versions → feed_consumption_norms → defaults.  
**Обоснование:** Система работает на любом уровне данных. Детальность опциональна.  
**Последствие:** Первые черновые проекты не требуют рациона — работают на нормативах.

### ADR-FEED-04: `feed_norms` — это кэш NASEM, а не самостоятельная сущность
**Решение:** `feed_consumption_norms` в d03_feed — это стартовые нормы для быстрого расчёта.  
В Фазе 3 они вытесняются реальными `ration_versions`, привязанными к проекту.  
**Обоснование:** Точность нарастает по мере ввода данных. Не блокирует ранний расчёт.

### ADR-FEED-05: Simple = единственный writer, NASEM = advisor (2026-04-14)
**Решение:** В Consulting-контексте рацион пишется только через Simple-редактор. NASEM-калькулятор перестаёт сохранять напрямую — он становится помощником двух видов:
- **«Проверить баланс»** — читает рацион из Simple, считает нутриентный баланс, возвращает отчёт (read-only).
- **«Подобрать»** — запускает greedy solver по заданным параметрам (вес, цель, набор кормов), возвращает предлагаемый рацион; пользователь видит diff-preview, жмёт «Вставить в Simple» → **Replace** всей секции группы/сезона.

Engine в Priority 1 читает `ration_versions` без различия источника — форма `results` одинаковая.

**Обоснование:** Устраняет конкуренцию двух writer'ов за `is_current`. Один источник правды для P&L. Simple сохраняется как единый вход эксперта; NASEM становится ценнее (не просто «создать», но и «проверить»).

**Альтернативы:**
- (A) Иерархия Simple/NASEM с per-category override — отвергнуто: сохраняет два источника правды, усложняет engine резолвер, зависит от незакрытого вопроса «5 vs 10 групп».
- (C) Унификация в одну сущность с двумя UI-проекциями — отвергнуто: нарушает «Simple — оставляем как есть», требует рефакторинга схемы.

**Последствие:**
- Easy: простой ментальный модель для эксперта (Simple — план, NASEM — инструмент).
- Easy: балансовый чекер работает автоматически на Simple (on-change, non-blocking бейджи).
- Hard: existing NASEM-рационы в `ration_versions` с `calculated_by='consulting_edge_function'` остаются как legacy (тестовые проекты — не мигрируем).
- Edge Function `calculate-ration` для consulting-контекста теперь не сохраняет через `rpc_save_consulting_ration` автоматически — возвращает результат для preview. Сохраняет UI при подтверждении «Вставить».

### ADR-FEED-06: Сезонная модель рациона (2026-04-14)
**Решение:** Рацион хранится **раздельно для пастбищного и стойлового сезона** в одной записи `ration_versions` (атомарно). Граница сезонов — параметр проекта, не хардкод.

Новая форма `ration_versions.results`:
```json
{
  "pasture": { "items": [...], "total_cost_per_day": N, "nutrients_met": {...}, "deficiencies": [...], "solver_status": "optimal|feasible|infeasible" },
  "stall":   { "items": [...], "total_cost_per_day": N, "nutrients_met": {...}, "deficiencies": [...], "solver_status": "..." },
  "source":  "simple_editor" | "nasem_import",
  "calc_avg_weight_kg": N,
  "calc_objective": "maintenance|growth|finishing|..."
}
```

Новые поля проекта (аддитивно в `consulting_projects` + Pydantic ProjectInput):
- `pasture_start_month smallint default 5` (май)
- `pasture_end_month smallint default 10` (октябрь)

Engine (`feeding_model._calc_from_consulting_rations`) для месяца `t` выбирает секцию:
```
is_pasture = pasture_start_month <= month_in_year(t) <= pasture_end_month
cpd = results.pasture.total_cost_per_day if is_pasture else results.stall.total_cost_per_day
monthly_cost = −(cpd × inflation(t) × heads[t] × days_in_month[t]) / 1000
```

Для частичного покрытия (группа без рациона): `total_cost_per_day = 0` → нулевой COGS группы, **без fallback на Priority 3** (подтверждённое решение CEO).

**Обоснование:** Реальность в Казахстане — бимодальный режим содержания: пастбище май-октябрь (green_mass ≈ 0 ₸/кг), стойло ноябрь-апрель (полноценный рацион). Усреднение `avgKg = (pasture×183 + stall×182)/365` в `SimpleRationEditor.handleSave` теряет эту бимодальность — P&L не отражает сезонные впадины кормовых затрат. Параметризация границы на уровне проекта нужна для регионального различия (север vs юг КЗ) без правок кода (P8).

**Альтернативы:**
- Два отдельных row в `ration_versions` (pasture row + stall row) — отвергнуто: рассинхрон `is_current`, JOIN для получения группы целиком, неатомарный save.
- Хардкод месяцев 5-10 в engine — отвергнуто: нарушает P8 (Standards as Data), не работает для севера КЗ.
- Дневная точность на границе сезона — отвергнуто: ломает `days_in_month × heads × cpd` арифметику; CFC-Excel уже использует целомесячное назначение.

**Последствие:**
- Easy: Simple-редактор уже имеет колонки «Пастбище» / «Стойло» — меняется только `handleSave` (удаляется усреднение).
- Easy: P&L теперь видит сезонные плато — корректная финансовая модель.
- Easy: баланс нутриентов считается отдельно по сезону — бейдж вида «🟢 pasture | 🟡 stall (ME −8 МДж)».
- Hard: форма `ration_versions.results` меняется. Legacy-записи (плоский `total_cost_per_day`) остаются читаемыми через fallback: если `results.pasture` отсутствует — engine берёт плоский `total_cost_per_day` для всех месяцев.
- Hard: погрешность ≤30 дней/год на переходном месяце — задокументировано допущение.

---

## 8. Принципы, которые соблюдает это решение

| Принцип | Соблюдение |
|---------|------------|
| **P8 — Standards as Data** | Все нормы в d03_feed, admin-managed, не в коде |
| **D42 — Quick Mode** | `ration_versions.ration_id` nullable (quick без фермы) |
| **D51 — Append-only** | `ration_versions` не меняются, только добавляются |
| **D87 — Compute outside DB** | NASEM в Edge Function, финансы в Python FastAPI |
| **P7 — Additive** | JSONB в items/results — расширяемый формат |
| **ADR-CONSULT-1** | Python engine остаётся на Railway, только источники данных меняются |

---

## 9. Сезонная модель рациона (v1.1, ADR-FEED-06)

### 9.1 Принцип
Стадо в Казахстане содержится в двух физических режимах:
- **Пастбище (май–октябрь по умолчанию):** подножный корм ≈ 90% рациона, green_mass ≈ 0 ₸/кг. Минимальные кормовые затраты.
- **Стойло (ноябрь–апрель по умолчанию):** полноценный рацион из закупаемых кормов. Максимальные затраты.

Финансовая модель обязана отражать бимодальность: P&L видит два разных плато COGS по кормам. Усреднение теряет экономическую картину.

### 9.2 Границы сезона — параметр проекта
**Решение:** `pasture_start_month` (1–12, default 5) и `pasture_end_month` (1–12, default 10) — колонки `consulting_projects`, поля `ProjectInput` (Pydantic), видны в ProjectWizard блоке «Кормление».

**Где НЕ задаётся:** хардкод в `feeding_model._is_pasture_month` удаляется — функция читает параметры из `enriched_input`.

**Гранулярность:** целомесячная. Если проект стартует 31 августа (месяц 8 — пастбище), весь август считается пастбищным. Задокументированная погрешность ≤30 дней/год.

**Валидация:** `pasture_start_month <= pasture_end_month` — линейный интервал внутри года. Инвертированный интервал (декабрь–февраль) в MVP не поддерживается.

### 9.3 Схема хранения — один row, двойной контейнер
**ration_versions.results** (новая форма):
```json
{
  "pasture": {
    "items":              [{ "feed_item_id", "feed_item_code",
                             "quantity_kg_per_day", "effective_price_per_kg",
                             "cost_per_day" }],
    "total_cost_per_day": 1280,
    "nutrients_met":      { "dm_kg": true, "me_mj": true, "cp_g": true, ... },
    "deficiencies":       [],
    "solver_status":      "optimal"
  },
  "stall": { "...same shape as pasture..." },
  "source":             "simple_editor" | "nasem_import",
  "calc_avg_weight_kg": 600,
  "calc_objective":     "maintenance"
}
```

**Инварианты:**
1. Одна запись `ration_versions` = атомарная пара (pasture, stall). Save/версионирование — на пару, не на сезон.
2. `items` у pasture и stall — независимые списки (состав рационов в сезонах разный).
3. `calc_*` поля (вес, цель) — общие для пары: одно животное в двух режимах.
4. Legacy-форма (плоский `total_cost_per_day`) остаётся читаемой — engine fallback.

### 9.4 Сквозной расчёт сезонного COGS
**`feeding_model._calc_from_consulting_rations`** — псевдокод:
```
for each category in ration:
    section_pasture = ration.results.pasture  (или flat-fallback)
    section_stall   = ration.results.stall    (или flat-fallback)
    cpd_pasture = section_pasture.total_cost_per_day
    cpd_stall   = section_stall.total_cost_per_day

for t in range(horizon_months):
    month = calendar_month(t)
    is_pasture = (pasture_start <= month <= pasture_end)
    cpd = cpd_pasture if is_pasture else cpd_stall
    monthly_cost[t] = −(cpd × inflation(t) × heads[t] × days[t]) / 1000
```

Физические количества кормов (tonnes/feed/month) агрегируются аналогично — по сезону для каждого месяца.

### 9.5 Балансовый чекер — сезонно, автоматически, non-blocking
**UX:**
- В Simple-таблице рядом с каждой группой — два бейджа: левый для pasture, правый для stall
- Зелёный: все `nutrients_met = true`. Жёлтый: ≥1 дефицит, показывается какой и на сколько (например, «ME −8 МДж»). Серый: не рассчитано (корма без `nutrient_composition`).
- Клик → раскрывается детальная таблица требуется/фактически/∆ по СВ, ME, СП, НДК, Ca, P.

**Расчёт:**
- Триггер — on-change в таблице, debounce 300ms. Save — не блокирующий (эксперт может сохранить дефицитный рацион).
- Nutrient requirements берутся из `nutrient_requirements` по типичной категории группы: COW→COW, SUCKLING_CALF→SUCKLING_CALF, HEIFER_YOUNG→HEIFER_YOUNG, STEER→STEER, BULL_BREEDING→BULL_BREEDING.
- Вес берётся из `weight` results проекта (existing `getDefaultWeight`).
- Математика — общая с Edge Function `calculate-ration` (строки 130-218), выносится в shared либу (TS на клиенте либо вызов Edge Function в режиме `mode=check_only`).

### 9.6 Обратная совместимость
**Legacy-записи `ration_versions`** (форма с плоским `total_cost_per_day`, без `pasture`/`stall`):
- Engine читает плоский `total_cost_per_day` для всех месяцев года (как было до v1.1).
- UI помечает их бейджем «v1.0 (устарело)» + кнопка «Мигрировать» — открывает Simple с предзаполненными значениями в колонке «Стойло» (0 в пастбище), эксперт подтверждает.
- Автомиграция не делается (решение CEO: тестовые проекты — не трогаем).

---

## 10. Simple ↔ NASEM: разделение ответственности (v1.1, ADR-FEED-05)

### 10.1 Роли
| Компонент | Роль | Пишет в БД | Что делает |
|-----------|------|-----------|------------|
| **Simple-редактор** | **Единственный writer** в Consulting | ✅ через `rpc_save_consulting_ration` | Табличный ввод 5 групп × (пастбище, стойло) × feeds. Автоматический балансовый чекер. |
| **NASEM «Проверить баланс»** | Advisor (read-only) | ❌ | Читает текущий рацион группы из `ration_versions`, считает нутриентный отчёт, показывает дефициты. |
| **NASEM «Подобрать»** | Advisor (suggest) | ❌ напрямую | Greedy solver по заданным параметрам → preview с diff → кнопка «Вставить в Simple» → **Replace** секции (см. 10.3). |

### 10.2 Flow создания рациона
```
Эксперт открывает RationTab проекта
  │
  ├─► Simple-таблица (default view)
  │     заполняет кг/сут по группам и сезонам
  │     видит балансовые бейджи on-change
  │     Save → rpc_save_consulting_ration (Priority 1 в engine)
  │
  └─► Кнопка «🧮 Подобрать» (опционально, по клику)
        выбор группы + сезона + параметров (вес, цель, corма)
        Edge Function calculate-ration (mode=suggest)
        preview: «было → станет» diff
        «Вставить в Simple» → Replace секции в буфере UI
        эксперт смотрит, корректирует
        Save → rpc_save_consulting_ration
```

### 10.3 Семантика «Вставить в Simple»
**Решение:** Replace, но явно.
- Preview показывает старый состав секции vs предлагаемый NASEM.
- Применение перезаписывает секцию (pasture или stall — одну за раз) в UI-буфере, не трогая сохранённые значения до Save.
- Альтернатива Merge отвергнута: размывает гарантию баланса NASEM (см. ADR-FEED-05).

### 10.4 Edge Function `calculate-ration` в Consulting-контексте
- Дополнительный параметр `mode: 'suggest' | 'save'` (default `save` — для farm-контекста обратная совместимость).
- Consulting вызывает `mode=suggest` — Edge Function возвращает items + nutrients, **не** пишет `ration_versions`.
- Дополнительный параметр `season: 'pasture' | 'stall'` — greedy solver запускается для одного сезона за раз.
- Farm-контекст без изменений (всегда сохраняет).

### 10.5 Staleness и пересчёт
- После `rpc_save_consulting_ration` (и Simple, и NASEM-импорт) → `consulting_projects.needs_recalc = true`.
- ProjectPage показывает бейдж «Требуется пересчёт» + кнопка триггера `orchestrator`.
- Автопересчёт на Save не делается (дорогая операция, контроль за экспертом).

---

## 11. CAPEX модель (v1.2, ADR-CAPEX-01)

### 11.1 Проблема и принцип решения
Предыдущая версия `capex.py` хардкодила 53 позиции инфраструктуры с финальными
₸-числами. `reproducer_capacity` и `calving_scenario` читались, но в формулах
не использовались — 300 голов и 3000 голов давали одинаковый CAPEX. Это
нарушало P8 (Standards as Data) и P5 (Design for Physical World).

Excel-шаблон [Zengi.Farm_Model](../Docs/Zengi.Farm_Model%20farm_020426_v10_WintSumm.xlsx)
показывает правильную формулу для area-based items:
`норма_м²/гол × capacity × цена_м²`. Каталог из 4 материалов (Лёгкий каркас
15k, Сэндвич 25k, Металлоконструкция 35k, Кирпич 50k ₸/м²) — 2 выбора на
проект: enclosed (ангар/изолятор/крытое отёла/КПП) и support (загоны/навесы/
кормовой стол/зернохранилище).

### 11.2 Priority chain (mirrors ADR-FEED-03)

```
Priority 1: project.infra_items_override[code]   — expert per-project edit
Priority 2: norm.data × project material choice  — data-driven from
            consulting_reference_data (infrastructure_norms +
            construction_materials + capex_surcharges)
Priority 3: capex.py _legacy_calculate_capex()   — hardcoded Excel numbers
            (fires only when refs['infrastructure_norms'] is empty,
            preserves Тест 7 parity and pre-seed project results)
```

### 11.3 cost_model enum (6 случаев)

| Value | Формула | Примеры позиций |
|---|---|---|
| `area_per_head` | `area_per_head_m2 × heads × price_per_m2` | FAC-001 ангар (8 м²/гол × 300 × 12500) |
| `fixed_area` | `fixed_area_m2 × price_per_m2` | FAC-013 изолятор (120 м² × 83333, subgroup "15 голов") |
| `per_head_unit` | `heads × unit_cost` | FAC-017 тёплая поилка (300 × 4830) |
| `fixed_qty` | `qty × unit_cost` | EQP-001 трактор (1 × 20M) |
| `fixed_per_project` | `fixed_cost` | INF-001 жилой дом (30M) |
| `per_area_ha` | `ceil(pasture_area_ha / area_divisor_ha) × unit_cost` | PST-003 пастбищная скважина (1 на 3000 га × 3M) |

### 11.4 applies_to enum — resolve head_count

| Value | Источник числа голов |
|---|---|
| `capacity` | `reproducer_capacity` (default) |
| `always` | 1 (marker for fixed_* models) |
| `pasture_area_ha` | `capacity × pasture_norm_ha` |
| `cows_eop` / `bulls_eop` | `herd.cows.eop[0]` / `herd.bulls.eop[0]` (month 0) |
| `calves_avg` / `heifers_avg` / `steers_avg` | year-1 average of `herd.<group>.avg[0:12]` |

Herd-dependent values require `herd` dict passed to `calculate_capex(enriched,
refs, herd=herd)`. Orchestrator передаёт `herd` после модуля herd_turnover.

### 11.5 material_target + bespoke prices

Площадные позиции (`area_per_head`, `fixed_area`) требуют цену за м². Resolve:
```
if override.material_override:           material_prices[override.material_override]
elif norm.unit_cost_per_m2_override:     use it  # bespoke (Excel parity)
elif material_target == 'enclosed':      project.construction_material_enclosed price
elif material_target == 'support':       project.construction_material_support price
```

**10 позиций Excel имеют bespoke prices** (preserve parity 282.4M):
FAC-015 (19500), FAC-019 (40000), FAC-015b (9000), FAC-012 (80000), FAC-001
(12500), FAC-013 (83333), FAC-009 (3450), INF-008 (6900), PAD-001 (4140),
PAD-007 (4968). Admin может удалить override в `/admin/capex` — активируется
catalog pricing (sandwich 25k для enclosed / light_frame 15k для support).

### 11.6 Surcharges + Excel quirk
`capex_surcharges` seed (one row, `code='default'`):
```json
{
  "works_rate": 0.06,
  "contingency_rate": 0.025,
  "applies_to_blocks": ["farm", "pasture"],
  "contingency_base_by_block": {"farm": "items_plus_work", "pasture": "items_only"}
}
```

Excel row 28 visually показывает 0.03, но computed cost (4,335,027.94 ₸) даёт
rate = 2.5% от (subtotal+works). Farm contingency base = items+works, pasture
base = items only (Excel row 37 = 43.4M × 0.025 = 1.085M).

### 11.7 Per-item depreciation
Заменяет blanket 20y-buildings / 5y-equipment (Priority 3 fallback). Каждая
норма несёт `depreciation_years` в seed:
- Здания (ангар, загоны, кормовой стол): 20 лет
- Временные / быстро-изнашиваемые (раскол, трап, тёплая поилка): 10 лет
- Ограждения пастбищ: 15 лет
- Техника (EQP-*): 5 лет
- Инструменты (TOL-*): 3 года
- Спецодежда: 2 года

**Поведенческий эффект:** при recalc legacy проекта после Phase 1 deploy
`depreciation_buildings_monthly` +6.4% (936.77 → 997.01 тыс.тг), 
`depreciation_equipment_monthly` +2.2% (960.67 → 981.94 тыс.тг). NPV/IRR
движение ≤1%. Задокументировано в D-GATE-CAPEX-01-PHASE2-QA.

### 11.8 Project fields + override shape
Новые колонки на `consulting_projects` (Phase 1 DDL):
- `construction_material_enclosed text NOT NULL DEFAULT 'sandwich'`
- `construction_material_support  text NOT NULL DEFAULT 'light_frame'`
- `infra_items_override           jsonb NOT NULL DEFAULT '[]'::jsonb`

Override shape:
```json
[
  {
    "code": "FAC-015",
    "include": false,                     // optional — omit item from sum
    "qty_override": 8,                    // optional — override computed qty
    "material_override": "brick",         // optional — override material_target
    "unit_cost_override": 25000           // optional — override unit price
  }
]
```

Пустой объект `{code: "FAC-015"}` эквивалентен отсутствию override — default
behavior. UI CapexTab нормализует: когда все опциональные поля сброшены,
запись удаляется из массива.

### 11.9 Write paths + staleness
| Источник | RPC | Эффект |
|---|---|---|
| ProjectWizard → Материал enclosed/support | `rpc_save_project_infra_override(p_enclosed, p_support, p_overrides=existing)` | materials обновляются, `needs_recalc=true` |
| CapexTab → toggle / qty / material_override | `rpc_save_project_infra_override(p_enclosed=null, p_support=null, p_overrides)` | overrides перезаписываются, `needs_recalc=true` |
| Admin `/admin/capex` → Материалы cost_per_m2 | `rpc_upsert_construction_material` | новая цена, все проекты при recalc подхватят |
| Admin `/admin/capex` → Нормативы | `rpc_upsert_infrastructure_norm` | новые параметры, все проекты при recalc подхватят |

После любого write → `consulting_projects.needs_recalc = true` → UI badge →
expert triggers `/calculate` → calculate.py читает проектную строку →
инжектирует в `input_params` → engine выполняет Priority 2 → сохраняет версию.

### 11.10 Cross-edit race — RESOLVED в ADR-CAPEX-02 (2026-04-18)
**Историческая проблема (L-P3-WIZARD, ADR-CAPEX-01 MVP):**
`rpc_save_project_infra_override` версии Phase 1 всегда перезаписывал
`infra_items_override` (default `'[]'::jsonb`). Wizard вынужденно передавал
stale snapshot `lastVersionOverrides` из `version.input_params` — race:
если CapexTab сохранил override → /calculate failed → пользователь идёт в
Wizard → wizard перезаписывает CapexTab-изменения stale snapshot'ом.

**Решение (ADR-CAPEX-02, deploy commits `174485f` + `8bf5339`):**
1. DB: default p_overrides изменён с `'[]'::jsonb` на `null`. UPDATE использует
   `coalesce(p_overrides, infra_items_override)` — null значение preserves
   existing column. Validation обновлена: non-null non-array → INVALID_OVERRIDES;
   null проходит validation silently. Event payload `override_count = null`
   когда overrides не тронуты.
2. UI: `ProjectWizard.handleCalculate` передаёт `p_overrides: null`. Dead code
   `lastVersionOverrides` state удалён. CapexTab остаётся строгим owner
   `infra_items_override` массива.

**Семантика после ADR-CAPEX-02:**
| p_overrides | effect |
|---|---|
| `null` | preserves existing array (wizard write path) |
| `[]` | resets to empty |
| `[...]` | replaces (CapexTab write path) |

### 11.11 CapexSurchargesTab lookup — RESOLVED в ADR-CAPEX-02
**Историческая проблема (L-P4-1):** Phase 4 shipped с admin-only прямым
`.from('consulting_reference_data').select().eq('category', 'capex_surcharges')`
в CapexSurchargesTab — нарушение UI principle «every data fetch = one RPC call».

**Решение (ADR-CAPEX-02):** новый `rpc_list_capex_surcharges()` (RPC-CAPEX-6),
STABLE SECURITY DEFINER, возвращает jsonb array активных строк
`capex_surcharges` (нормально 1 строка, code='default'), sorted by valid_from desc.
CapexSurchargesTab переключён на RPC (commit `8bf5339`). UI теперь консистентен.

---

## 12. Livestock Sale Prices модель (v1.4, ADR-PRICES-01)

### 12.1 Проблема

Цены продажи КРС (бычки, тёлки плем., коровы-культ, быки-культ) жили в
`ProjectInput` как required float с hardcoded defaults (DEF-REVENUE-PRICES-01,
2026-04-17). Минусы:
- Рыночные цены меняются чаще, чем релизы кода — каждое обновление требовало
  изменения Pydantic defaults и передеплоя.
- Разные проекты инвесторов не могли использовать общий откалиброванный
  catalog — каждый стартовал с кодовых defaults.
- Нарушен P8 (Standards as Data) — цены = данные, не код.

### 12.2 Архитектурное решение — Priority chain (mirrors ADR-FEED-03)

```
P1  Project override  (ProjectInput.price_*_per_kg not null)  → инвестор задал явно
 ↓
P2  DB reference       (consulting_reference_data, category='livestock_prices')
 ↓
P3  Safety default     (hardcoded 1800/2200/1800/2000 — pre-seed/recovery safety)
```

Все 4 поля `ProjectInput` стали `Optional[float]`. null = «использовать catalog».
Resolver [price_resolver.py](consulting_engine/app/engine/price_resolver.py) вызывается
из `orchestrator.py` после `validate_and_enrich_input`. Revenue module получает
уже resolved `enriched_input["price_params"]` — формула не изменилась.

### 12.3 Data model

Таблица: `consulting_reference_data` (уже существующая, категория `livestock_prices` добавлена в CHECK).

```json
// code format: {livestock_category}:{year}[:{age_months}mo]
// code example: "steer_own:2026"  |  "steer_own:2026:12mo" (future ADR-PRICES-02)
{
  "livestock_category": "steer_own",    // steer_own | heifer_breeding | cow_culled | bull_culled
  "year":               2026,
  "region_id":          null,           // MVP always null (reserved)
  "age_months":         null,           // MVP always null (reserved for ADR-PRICES-02 per-strategy)
  "price_per_kg":       1800,
  "currency":           "KZT",
  "source":             "AgOS default 2026"
}
```

**Temporal versioning** через `valid_from` / `valid_to`:
- Новая цена для года 2027 → `INSERT` с `valid_from = 2027-01-01`.
- Ретрограда → `rpc_retire_livestock_price(code)` устанавливает `valid_to = yesterday`.
- Engine выбирает рядок с max(year ≤ project_year) среди active на `project_start_date`.

### 12.4 RPCs (3)

| ID | Функция | Caller | Guard |
|----|---------|--------|-------|
| RPC-PRICES-1 | `rpc_list_livestock_prices(p_organization_id, p_as_of_date)` | engine, ProjectWizard, LivestockPricesAdmin | — (public read) |
| RPC-PRICES-2 | `rpc_upsert_livestock_price(...)` | LivestockPricesAdmin | `fn_is_admin()` |
| RPC-PRICES-3 | `rpc_retire_livestock_price(code)` | LivestockPricesAdmin | `fn_is_admin()` |

Полные сигнатуры: Dok 3 §«Consulting Livestock Prices RPCs».

### 12.5 UI

- **`/admin/livestock-prices`** — CRUD справочника, паттерн от `FeedReferenceAdmin` / `CapexReferenceAdmin`. Dialog-based editor: категория (disabled при edit), год, цена, age_months (опц.), источник. Кнопка «Архивировать» = soft-delete.
- **ProjectWizard Step 3** — поля цен стали nullable. Пустое поле → placeholder показывает catalog-значение («1800 (из справочника)»). Явно введённое число → override (P1).

### 12.6 Open follow-ups

- **ADR-PRICES-02** — цена per-стратегия (age_months = 6/12/18 для steer_own). Резолвер уже читает `age_months`, seed добавит строки.
- **Region dimension** — `ProjectInput.region_id` не существует; если появится, resolver начнёт матчить по region (код уже ignores NULL-region при match).
- **Per-org price overrides** — сейчас catalog глобален. `p_organization_id` в RPC-PRICES-1 зарезервирован.

---

*Документ создан: 08.04.2026*  
*Версия 1.1: 14.04.2026 — добавлены ADR-FEED-05 (Simple=writer) и ADR-FEED-06 (сезонная модель)*  
*Версия 1.2: 2026-04-18 — добавлен §11 CAPEX модель (ADR-CAPEX-01: data-driven Priority chain, 4 материала, per-item depreciation, 10 bespoke overrides для Excel parity)*  
*Версия 1.3: 2026-04-18 — §11.10 + §11.11 обновлены с ADR-CAPEX-02 resolutions (L-P3-WIZARD + L-P4-1 closed)*  
*Версия 1.4: 2026-04-18 — добавлен §12 Livestock Sale Prices модель (ADR-PRICES-01: 3-level Priority chain, `livestock_prices` category в consulting_reference_data, 3 RPC, `/admin/livestock-prices` страница)*
