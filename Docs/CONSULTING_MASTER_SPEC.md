# ZENGI FARMS — Мастер-спецификация проекта
## Для архитектора / Claude Code · Версия 1.0 · Апрель 2026

> ⚠️ HISTORICAL v1.0. Superseded by Dok7 (current Consulting canon, A2). §3 generic table names (projects/project_versions/reference_data) and §5.1 REST API do NOT reflect deployed reality (consulting_* tables + stateless POST /api/v1/calculate + GET /api/v1/references/{category}). Retained for history only.

---

# ЧАСТЬ 1. СУТЬ ПРОДУКТА

## 1.1 Что делаем

Внутренний веб-инструмент для автоматизации консалтинговых услуг Zengi Farms в агросекторе Казахстана.

**Услуга v1 — Упаковка инвестиционного проекта:**
Клиент хочет создать животноводческую ферму с нуля → Zengi разрабатывает полный инвестиционный пакет:
- Детальная финансовая модель на 10 лет
- Бизнес-план
- Презентация для банка/СПК/инвестора

**Без системы:** вручную в Excel + Word, 2–4 недели.
**С системой:** консультант вводит параметры → система рассчитывает → показывает результат в web-UI.

## 1.2 Что делаем сейчас (Sprint 1–3)

**Только расчётное ядро + web-UI для просмотра результатов.**
- Python считает точную финансовую модель (11 модулей, 120 месяцев)
- Next.js показывает таблицы и графики
- Без генерации Excel/Word/PPTX — это Sprint 4–5

## 1.3 Пользователи

| Роль | Доступ | Что делает |
|---|---|---|
| Консультант Zengi | Полный UI | Создаёт проекты, вводит параметры, смотрит результаты |
| Администратор | + Справочники | Обновляет нормативы, цены, шаблоны |
| Клиент (фермер) | Нет доступа | Получает только финальные документы |

## 1.4 Типы ферм (v1)

| Тип | Код | Статус |
|---|---|---|
| КРС мясной репродуктор | `beef_reproducer` | **MVP — первый** |
| КРС откормочная (фидлот) | `feedlot` | После репродуктора |
| МРС (овцы/козы) | `sheep_goat` | После КРС |

---

# ЧАСТЬ 2. ТЕХНИЧЕСКИЙ СТЕК И АРХИТЕКТУРА

## 2.1 Стек

- **Frontend:** Next.js 14 (App Router) + shadcn/ui + Tailwind CSS
- **Backend:** Python FastAPI (расчётное ядро)
- **БД:** PostgreSQL
- **Расчёты:** numpy, pandas
- **Деплой:** Docker Compose

## 2.2 Pipeline

```
[1. Параметры проекта] → [2. Производственный протокол] → [3. CapEx] → [4. Финмодель] → [5. Документы]
     ProjectConfig           ProductionModelData         CapExConfig    FinancialModelData   (Sprint 4-5)
       (wizard UI)             (расчёт Python)           (авто+ред.)     (авто+просмотр)
```

## 2.3 Архитектурные принципы

1. **Один источник правды** — Python расчётное ядро. Excel-шаблон используется только как эталон для тестирования, не как runtime-зависимость.
2. **Модульность** — каждый модуль: INPUT → логика → OUTPUT, взаимодействие только через контракт.
3. **Строгий pipeline** — шаги не пропускаются.
4. **Прозрачность** — каждое значение traceable до формулы.
5. **Версионирование** — каждое изменение допущений = новая версия.
6. **Справочники отдельно от кода** — обновление норматива не требует деплоя.
7. **Никаких магических чисел** — все нормативы из справочников или Input.

## 2.4 Структура проекта

```
zengi/
├── docker-compose.yml
├── backend/
│   ├── app/
│   │   ├── main.py                    # FastAPI app
│   │   ├── api/
│   │   │   ├── projects.py            # CRUD проектов
│   │   │   └── calculations.py        # Запуск расчёта, результаты
│   │   ├── engine/                    # Расчётное ядро
│   │   │   ├── timeline.py            # Временна́я ось 120 мес.
│   │   │   ├── input_params.py        # Парсинг Input
│   │   │   ├── herd_turnover.py       # Оборот стада (6 групп)
│   │   │   ├── feeding_model.py       # Кормовая модель
│   │   │   ├── capex.py               # Капитальные затраты
│   │   │   ├── staff.py               # ФОТ + налоги РК
│   │   │   ├── opex.py                # Себестоимость
│   │   │   ├── revenue.py             # Выручка + субсидии
│   │   │   ├── pnl.py                 # P&L
│   │   │   ├── loans.py               # Долговая нагрузка
│   │   │   ├── cashflow.py            # Cash Flow
│   │   │   ├── wacc.py                # WACC + NPV/IRR
│   │   │   └── orchestrator.py        # Запуск всех модулей по порядку
│   │   ├── models/                    # SQLAlchemy / Pydantic
│   │   │   ├── project.py
│   │   │   ├── reference_data.py      # Справочники
│   │   │   └── results.py             # Результаты расчёта
│   │   └── db/
│   │       ├── session.py
│   │       └── migrations/
│   └── tests/
│       ├── fixtures/
│       │   └── excel_reference.json   # Эталонные значения из Excel
│       ├── test_herd_turnover.py
│       ├── test_feeding_model.py
│       └── ...
├── frontend/
│   ├── app/
│   │   ├── page.tsx                   # Dashboard
│   │   ├── projects/
│   │   │   ├── page.tsx               # Список проектов
│   │   │   ├── new/
│   │   │   │   └── page.tsx           # Wizard ввода
│   │   │   └── [id]/
│   │   │       ├── page.tsx           # Результаты
│   │   │       ├── herd/page.tsx      # Оборот стада
│   │   │       ├── pnl/page.tsx       # P&L
│   │   │       ├── cashflow/page.tsx  # Cash Flow
│   │   │       └── summary/page.tsx   # Сводка
│   │   └── admin/
│   │       └── references/page.tsx    # Управление справочниками
│   └── components/
│       ├── wizard/                    # Шаги wizard'а
│       ├── tables/                    # Таблицы результатов
│       └── charts/                    # Графики
└── scripts/
    └── extract_excel_reference.py     # Извлечение эталона из Excel
```

---

# ЧАСТЬ 3. СХЕМА БАЗЫ ДАННЫХ

```sql
-- Проекты
CREATE TABLE projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    farm_type VARCHAR(50) NOT NULL DEFAULT 'beef_reproducer',
    status VARCHAR(20) NOT NULL DEFAULT 'draft',  -- draft, calculated, archived
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Версии расчёта (каждое изменение = новая версия)
CREATE TABLE project_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID REFERENCES projects(id),
    version_number INT NOT NULL,
    input_params JSONB NOT NULL,        -- Все входные параметры
    results JSONB,                       -- Результаты расчёта (все модули)
    calculated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(project_id, version_number)
);

-- Справочники (ключ-значение, обновляются без деплоя)
CREATE TABLE reference_data (
    id SERIAL PRIMARY KEY,
    category VARCHAR(50) NOT NULL,       -- feed_norms, infrastructure_norms, etc.
    code VARCHAR(50) NOT NULL,           -- FAC-001, PAD-001, MAT-001, etc.
    data JSONB NOT NULL,                 -- Все параметры элемента
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to DATE,
    UNIQUE(category, code, valid_from)
);

-- Категории справочников:
-- feed_norms         — рационы по группам и сезонам
-- feed_prices        — цены кормов по регионам
-- infrastructure_norms — FAC/PAD/MAT коды
-- equipment_norms    — EQP коды (техника)
-- tax_rates          — СО, СН, ОСМС, ОПВ, КПН
-- wacc_parameters    — безрисковая ставка, страновой риск, бета
-- subsidy_programs   — программы МСХ РК
-- livestock_norms    — привесы, падёж, яловость по породам
-- regional_prices    — цены скота по регионам
```

---

# ЧАСТЬ 4. РАСЧЁТНОЕ ЯДРО — ПОЛНАЯ СПЕЦИФИКАЦИЯ

## 4.1 Временна́я ось

- **Горизонт:** 10 лет = 120 месяцев
- **Гранулярность:** помесячно
- **Дата старта:** настраиваемая (образец: 31.08.2026)
- **Все суммы:** в тыс. тенге (деление на 1000)
- **Поголовье:** дробное в расчётах, округление только на UI

```python
@dataclass
class MonthlyTimeline:
    dates: list[date]         # EOMONTH от старта, 120 элементов
    days_in_month: list[int]  # кол-во дней в каждом месяце
    month_index: list[int]    # 1..120
    year_index: list[int]     # 1..10+
    calendar_year: list[int]  # 2026..2036
```

## 4.2 Модуль INPUT — Мастер-параметры

### Общие параметры

| Параметр | Тип | Образец | Описание |
|---|---|---|---|
| `purchase_price_cow` | int | 550 000 | Цена 1 маточной головы, тг |
| `purchase_price_bull` | int | 650 000 | Цена 1 быка-производителя, тг |
| `bull_ratio` | float | 1/15 | Норма быков на маточное поголовье |
| `pasture_norm_ha` | int | 10 | Га пастбищ на 1 голову |
| `subsidy_switch` | enum | 1 | 1=с субсидиями, 2=без |
| `wc_loan_switch` | enum | 1 | 1=с займами на ПОС, 2=без |
| `bioasset_revaluation_switch` | enum | 1 | 1=без переоценки, 2=с |
| `project_start_date` | date | 2026-08-31 | Дата старта |
| `initial_cows` | int | 200 | Закуп маточного поголовья |
| `initial_bulls` | int | calc | =ROUNDUP(initial_cows × bull_ratio) = 14 |
| `reproducer_capacity` | int | 300 | Мощность репродуктора |
| `equity_share` | float | 0.15 | Доля собственного участия |
| `calving_scenario` | enum | "Летний" | Летний / Зимний |

### Условия финансирования

| Параметр | Образец |
|---|---|
| `capex_loan_rate` | = WACC rate (из расчёта) |
| `capex_loan_term_years` | 10 |
| `capex_grace_period_years` | 2 |
| `capex_loan_share` | 0.9 (90%) |
| `livestock_loan_rate` | 0.05 |
| `livestock_loan_term_years` | 10 |
| `livestock_grace_period_years` | 2 |
| `livestock_loan_share` | 0.9 |
| `wc_loan_rate` | 0.06 |
| `wc_loan_term_months` | 15 |

---

## 4.3 Модуль ОБОРОТ СТАДА — КРИТИЧЕСКИЙ

> Ошибка здесь каскадирует на кормовую модель, OPEX, выручку, Cash Flow, NPV.

### 4.3.1 Маточное поголовье (Operating Model, строки 50–58)

```python
culling_rate_monthly = 0.15 / 12   # выбраковка 15%/год → 1.25%/мес
mortality_rate_monthly = 0.03 / 12  # падёж 3%/год → 0.25%/мес

for t in range(120):
    cows_bop[t] = 0 if t == 0 else cows_eop[t-1]
    cows_purchased[t] = initial_cows * farms_added[t]
    cows_from_heifers[t] = -heifers_to_cows[t]
    
    # ⚠️ В шаблоне выбраковка = 0 для всех месяцев (строка 53 — хардкод 0)
    # В реальности должна быть: -culling_rate_monthly * cows_bop[t] после месяца 17
    cows_culled[t] = 0
    
    cows_mortality[t] = -mortality_rate_monthly * cows_bop[t]
    
    cows_interim[t] = cows_bop[t] + cows_purchased[t] + cows_from_heifers[t] + cows_culled[t] + cows_mortality[t]
    
    # Продажа племенных тёлок при превышении мощности
    cows_sold_breeding[t] = -min(cows_interim[t] - min(cows_interim[t], reproducer_capacity * farm_count[t]))
    
    cows_eop[t] = cows_interim[t] + cows_sold_breeding[t]
    cows_avg[t] = (cows_bop[t] + cows_purchased[t] + cows_eop[t]) / 2
```

### 4.3.2 Быки-производители (строки 60–67)

```python
bull_culling_monthly = 0.25 / 12
bull_mortality_monthly = 0.03 / 12

for t in range(120):
    bulls_bop[t] = 0 if t == 0 else bulls_eop[t-1]
    bulls_purchased[t] = initial_bulls * farms_added[t]
    bulls_from_steers[t] = -steers_to_bulls[t]
    
    # ⚠️ Выбраковка и падёж ТОЛЬКО после месяца 17
    if month_index[t] > 17:
        bulls_culled[t] = -bull_culling_monthly * bulls_bop[t]
        bulls_mortality[t] = -bull_mortality_monthly * bulls_bop[t]
    else:
        bulls_culled[t] = 0
        bulls_mortality[t] = 0
    
    bulls_eop[t] = bulls_bop[t] + bulls_purchased[t] + bulls_from_steers[t] + bulls_culled[t] + bulls_mortality[t]
    bulls_avg[t] = (bulls_bop[t] + bulls_purchased[t] + bulls_eop[t]) / 2
```

### 4.3.3 Приплод (строки 69–77)

```python
calf_yield = 0.85  # 85%
calving_month_index = 18 if calving_scenario == "Зимний" else 12

for t in range(120):
    calves_bop[t] = 0 if t == 0 else calves_eop[t-1]
    
    # Приплод ТОЛЬКО в месяце отёла
    if month_index[t] == calving_month_index or (month_index[t] > calving_month_index and (month_index[t] - calving_month_index) % 12 == 0):
        new_calves[t] = calf_yield * (cows_bop[t] + cows_purchased[t])
    else:
        new_calves[t] = 0
    
    calves_before_split[t] = calves_bop[t] + new_calves[t]
    to_heifers[t] = -calves_before_split[t] * 0.5
    to_steers[t] = -calves_before_split[t] * 0.5
    calves_eop[t] = calves_before_split[t] + to_heifers[t] + to_steers[t]  # = 0
    calves_avg[t] = (calves_bop[t] + calves_eop[t]) / 2
```

### 4.3.4 Тёлки (строки 79–88)

> **ОБНОВЛЕНО 2026-04-14 (см. DECISIONS_LOG):** падёж — ежемесячный 0.25%/мес × BOP
> (а не 3% разово на inflow). Это устраняет задвоение с падежом приплода (4.3.3).

```python
heifer_mortality_monthly = heifer_mortality_rate / 12  # параметр из ProjectInput, default 3%/12

for t in range(120):
    heifers_bop[t] = 0 if t == 0 else heifers_eop[t-1]
    heifers_from_calves[t] = -to_heifers[t]

    # Падёж: ежемесячный на BOP, начиная с mi > 17 (после первого отёла)
    if heifers_bop[t] > 0 and mi[t] > 17:
        heifer_mortality_t[t] = -heifer_mortality_monthly * heifers_bop[t]
    else:
        heifer_mortality_t[t] = 0

    heifers_before[t] = heifers_bop[t] + heifers_from_calves[t] + heifer_mortality_t[t]

    # Перевод в маточное: лумп в декабре каждого года (после первого отёла)
    heifers_to_cows[t] = -heifers_before[t] if (is_december and mi[t] > calving_mi) else 0

    heifers_sold_breeding[t] = 0  # племенные продажи опциональны

    heifers_eop[t] = heifers_before[t] + heifers_to_cows[t]
    heifers_avg[t] = (heifers_bop[t] + heifers_from_calves[t] + heifers_eop[t]) / 2
```

### 4.3.5 Бычки (строки 90–97)

> **ОБНОВЛЕНО 2026-04-14 (см. DECISIONS_LOG):** падёж переведён на ежемесячный
> 0.25%/мес × BOP (как у тёлок и коров). Было: 3% разово на (BOP + inflow).
> Также: продажа бычков теперь age-based (когортный трекинг) с настраиваемым
> параметром `steer_sale_age_months` (диапазон 6–24 мес. или 0=декабрь legacy).

```python
steer_mortality_monthly = heifer_mortality_rate / 12  # один параметр для тёлок и бычков
bull_transfer_rate = bull_ratio  # параметр из ProjectInput, default 1/15
steer_sale_age = steer_sale_age_months  # параметр: 0=декабрь, 6-24 = age-based

steer_cohorts = []  # [[birth_mi, count], ...] — для age-based продажи

for t in range(120):
    steers_bop[t] = 0 if t == 0 else steers_eop[t-1]
    steers_from_calves[t] = -to_steers[t]

    # Регистрация новой когорты для age-based продажи
    if steers_from_calves[t] > 0.01:
        steer_cohorts.append([mi[t], steers_from_calves[t]])

    # Перевод в быки-производители: только если bull_need > 0
    bull_need = bull_transfer_rate * cows_bop[t] - (bulls_bop[t] + bulls_culled[t] + bulls_mortality[t])
    available = steers_bop[t] + steers_from_calves[t]
    if bull_need > 0 and available > 0:
        steers_to_bulls[t] = -min(bull_need, available)
        # списать из старшей когорты
    else:
        steers_to_bulls[t] = 0

    # Падёж: ежемесячный на BOP с mi > 17
    if steers_bop[t] > 0 and mi[t] > 17:
        steer_mortality_t[t] = -steer_mortality_monthly * steers_bop[t]
    else:
        steer_mortality_t[t] = 0

    # Продажа: age-based (cohort-based) или decembre legacy
    if steer_sale_age > 0:
        # продать когорты, у которых age >= steer_sale_age
        steers_sold[t] = -sum(c[1] for c in steer_cohorts if mi[t] - c[0] >= steer_sale_age)
    elif is_december and mi[t] > calving_mi:
        steers_sold[t] = -(steers_bop[t] + steers_from_calves[t] + steers_to_bulls[t] + steer_mortality_t[t])
    else:
        steers_sold[t] = 0

    steers_eop[t] = max(0, steers_bop[t] + steers_from_calves[t] + steers_to_bulls[t] + steer_mortality_t[t] + steers_sold[t])
    steers_avg[t] = (steers_bop[t] + steers_eop[t]) / 2
```

### 4.3.6 Доращивание (строки 133–158)

```python
fattening_capacity = 0       # единовременная мощность (= 0 в образце)
purchase_weight_kg = 190     # вес при закупе бычков

for t in range(120):
    fattening_bop[t] = 0 if t == 0 else fattening_eop[t-1]
    fattening_in[t] = (-steers_sold[t]) + purchased_steers[t]
    
    # ⚠️ Продажа после доращивания — ArrayFormula в Excel
    # Логика: бычки продаются через G152 (=5) месяцев после поступления
    # Реализация: OFFSET на -5 месяцев от текущего
    fattening_sold[t] = ...  # требует отдельной проработки
    
    fattening_eop[t] = fattening_bop[t] + fattening_in[t] + fattening_sold[t]
    
    # Живой вес
    own_steers_weight[t] = avg_weight_own * (-steers_sold[t])
    purchased_weight[t] = -avg_weight_purchased * fattening_sold[t]
```

### 4.3.7 Сводка реализации (строки 162–170)

```python
sold_heifers_breeding[t] = -cows_sold_breeding[t]
sold_cows_culled[t] = -cows_culled[t]
sold_bulls_culled[t] = -bulls_culled[t]
sold_own_steers[t] = -steers_sold[t]
sold_purchased_steers[t] = -fattening_sold[t]
total_sold[t] = sold_heifers_breeding[t] + sold_cows_culled[t] + sold_bulls_culled[t] + sold_own_steers[t]

total_avg_livestock[t] = cows_avg[t] + bulls_avg[t] + calves_avg[t] + heifers_avg[t] + steers_avg[t]
```

---

## 4.4 Модуль КОРМОВАЯ МОДЕЛЬ

### 4.4.1 Справочник рационов (лист Feeding Rations → Cattle Feeding Cycle)

Рационы привязаны к реальным датам с учётом даты старта. Сезонность РК: пастбище май–октябрь, стойло ноябрь–апрель.

**Формула стоимости (единая для всех кормов всех групп):**
```python
feed_cost[t] = -(price_per_kg[t] * daily_ration_kg[t] * days_in_month[t] * head_count[t]) / 1000
```

### 4.4.2 Группы расчёта (8 групп)

| # | Группа | Строки CFC | Кол-во кормов | Поголовье из |
|---|---|---|---|---|
| 1 | Молодняк | 184–192 | 7 | Operating Model (тёлки до распред. + бычки до распред.) |
| 2 | Тёлки предыдущего периода | 194–203 | 8 | CFC tracking |
| 3 | Тёлки текущего периода | 205–214 | 8 | CFC tracking |
| 4 | Маточное поголовье 12 мес. | 216–225 | 9 | CFC tracking |
| 5 | Маточное поголовье 9 мес. | 227–236 | 9 | CFC tracking |
| 6 | Быки-производители | 238–245 | 7 | Operating Model |
| 7 | Бычки племенные (доращивание) | 252–257 | 4 | 0 в образце |
| 8 | Бычки товарные (доращивание) | 259–264 | 4 | Operating Model |

**Итого репродуктор** (строка 247) = SUM(группы 1–6)

### 4.4.3 Цены кормов (строки 85–99)

| Корм | Цена, тг/кг | Инфляция |
|---|---|---|
| Молоко | 250 | раз в год |
| Зелёная масса | 8 | раз в год |
| Концентраты | 100 | раз в год |
| Соль | 145 | раз в год |
| Сено | 28 | раз в год |
| Солома | 15 | раз в год |
| Отруби/шроты | 120 | раз в год |
| Кормовой фосфат | 145 | раз в год |
| ДАФ | 145 | раз в год |
| МКФ | 145 | раз в год |
| БМВД | 145 | раз в год |
| Дерть ячменная | 36 | раз в год |
| Зерноотходы | 63 | раз в год |

Индексация: `price[year+1] = price_base * (1 + inflation_rate)`

### 4.4.4 Привесы (строки 101–108)

| Группа | Суточный привес | Ввод |
|---|---|---|
| Маточное | 0 г/сут | стабильный вес |
| Быки | 0 г/сут | стабильный вес |
| Молодняк | 850 г/сут | эксперт |
| Тёлки | 810 г/сут | эксперт |
| Бычки | 850 г/сут | эксперт |
| Закупаемые бычки | 800 г/сут | эксперт |

**Вес реализации:**
```python
weight_at_exit = start_weight + period_months * 30 * daily_gain_g / 1000
# Тёлки: 170 + 4 * 30 * 810 / 1000 = 267.2 кг
# Маточное (выбраковка): 600 кг (константа)
# Быки: 750 кг (константа)
```

---

## 4.5 Модуль CAPEX

### 4.5.1 Структура (лист CAPEX, 87 строк)

**4 блока:**
1. Основная ферма (строки 5–29): 24 позиции, FAC/INF/PAD коды
2. Пастбища (строки 32–38): вагончик, поилки, скважина, ограждение
3. Техника (строки 41–49): 8 позиций (трактор, кормораздатчик и т.д.)
4. Инструменты (строки 52–70): RFID, весы, вакцинаторы

**Формулы:**
```python
# Площадь: норма × мощность_репродуктора
area = round(norm_m2_per_head * reproducer_capacity)

# Стоимость: включено × площадь × цена_за_м2
cost = enabled * area * price_per_m2

# Contingency
work_surcharge = sum(items) * 0.06
contingency = (sum(items) + work_surcharge) * 0.025
subtotal = sum(items) + work_surcharge + contingency
```

**Зависимость от сценария отёла:**
```python
# FAC-001 (коровник закрытый) и FAC-017 (тёплые поилки):
enabled = 1 if calving_scenario == "Зимний" else 0
```

**Нормативные ссылки:** FAC-001 → Справочник!G7, PAD-001 → Справочник!D30 (lookup из БД)

---

## 4.6 Модуль STAFF — ФОТ

### 4.6.1 Штатное расписание (5 позиций на 300 голов)

| # | Позиция | FTE | Нетто ЗП, тыс.тг/мес |
|---|---|---|---|
| 1 | Директор фермы | 1.0 | 600 |
| 2 | Ветеринар | 0.5 | задаётся |
| 3 | Повар | 0.5 | задаётся |
| 4 | Тракторист | 1.0 | задаётся |
| 5 | Бухгалтер | 0.3 | задаётся |

### 4.6.2 Налоги РК

```python
SO_rate = 0.035       # Социальные отчисления
SN_rate = 0.095       # Социальный налог
OSMS_employer = 0.03  # ОСМС работодатель
OSMS_employee = 0.02  # ОСМС работник
OPV_rate = 0.10       # Пенсионные
net_to_gross = 1.21   # Коэффициент нетто → брутто

mrp_base = 3932       # МРП, тг (индексируется ежегодно)
min_wage = 93_000     # МЗП, тг/мес (индексируется ежегодно)
max_so_base = 7 * min_wage
max_osms_base = 10 * min_wage

# Итого ФОТ = Нетто ЗП × Gross-up + СО + СН + ОСМС
# Каждый налог рассчитывается по каждому сотруднику отдельно с учётом лимитов
```

---

## 4.7 Модуль OPEX — Себестоимость

### 4.7.1 Себестоимость репродуктора (строки 204–214)

```python
cogs_reproducer[t] = sum(
    CFC.total_feed_reproducer[t],                     # строка 205
    -6500 * total_avg_livestock[t] * (1+inflation[t]) / 1000 / 12,  # строка 206: вет
    -500 * total_avg_livestock[t] * (1+inflation[t]) / 1000 / 12,   # строка 207: RFID
    -500 * total_livestock_eop[t] * (1+inflation[t]) / 1000 / 12,   # строка 208: бирки
    -(cow_price_kg[t] * 600 * cows_eop[t]) / 1000 * 0.015 * 0.2 / 12,  # строка 209: страхование
    -Staff.total_payroll[t],                           # строка 210: ФОТ штат
    -500 * (1 + inflation_annual),                     # строка 211: пастухи (индексируется)
    herders[t] * 0.35,                                 # строка 212: платежи в бюджет
    -200 * (1 + inflation_annual),                     # строка 213: текущие расходы
    -0.001 * sum(revenue_livestock[t]),                 # строка 214: 0.1% от выручки
)
```

### 4.7.2 Себестоимость доращивания (строки 216–220)

```python
cogs_fattening[t] = sum(
    CFC.feed_own_steers[t],      # строка 217
    CFC.feed_purchased[t],        # строка 218
    -herders_fattening[t],        # строка 219
    -purchase_cost[t],            # строка 220
)
```

---

## 4.8 Модуль P&L

### 4.8.1 Выручка (строки 172–198)

```python
# Вес молодняка — динамически из weight_model (D-WEIGHT-1, 2026-04-09):
# W_sale = birth_weight + Σ(daily_gain[season] × days_in_month)
weight_heifers[t]  = weight_model.heifer_transfer_weight[t] * sold_heifers[t]
weight_steers[t]   = weight_model.steer_sale_weight[t]      * sold_steers[t]

# Вес выбракованных — статично из ProjectInput.weight_params:
weight_cows[t]     = weight_params.cow_culled_weight_kg  * sold_cows[t]     # default 600 кг
weight_bulls[t]    = weight_params.bull_culled_weight_kg * sold_bulls[t]    # default 750 кг

# Цены (тг/кг ЖВ) — из ProjectInput.price_params (DEF-REVENUE-PRICES-01, 2026-04-18).
# Defaults откалиброваны под рынок КЗ 2026 (было 2200 везде):
base_prices = {
    "steer_own":       1800,  # молодняк 10-12 мес, стокер для откормочника
    "heifer_breeding": 2200,  # племенные тёлки (премия за разведение)
    "cow_culled":      1800,  # выбракованные коровы (мясо низкой категории)
    "bull_culled":     2000,  # выбракованные быки (тяжёлая туша)
}

# Выручка = цена × вес × (1 + ИПЦ)^(год-1) / 1000 + субсидии
# cpi_annual — из ProjectInput (default 0.105, range 0-0.5), применяется с года 2.
# DEF-CPI-PARAM-01 (2026-04-18): вынесен из module-level hardcode. Тот же параметр
# используется модулем OPEX (opex.py). feed_inflation_rate — независимый параметр.
revenue[t] = sum(
    price_heifer[t] * weight_heifers[t] / 1000,
    price_cow[t] * weight_cows[t] / 1000,
    price_bull[t] * weight_bulls[t] / 1000,
    price_steer[t] * weight_steers[t] / 1000,
    subsidy_purchase[t] if subsidy_switch == 1 else 0,
    subsidy_breeding[t] if subsidy_switch == 1 else 0,
    subsidy_bulls[t] if subsidy_switch == 1 else 0,
    subsidy_capex[t] if subsidy_switch == 1 else 0,
)
```

> **P8 — Standards as Data:** цены и веса выбракованных — параметры проекта в `ProjectInput`,
> а не хардкод в коде. Цены молодняка, тёлок плем., коров-культ, быков-культ настраиваются
> инвестором через ProjectWizard (view-mode: секция «Цены реализации»; edit-mode: Step 3).
> Следующий шаг P8: `price_reference` таблица в БД с версионированием по годам/регионам (ADR TBD).

### 4.8.2 Субсидии (строки 478–483)

```python
subsidy_purchase[t] = 260_000 * (cows_purchased[t] + bulls_purchased[t]) / 1000
subsidy_breeding[t] = 15_000 * (1 + inflation[t]) * (heifers_before[t] + steers_94[t]) / 1000
subsidy_bulls[t] = 100_000 * bulls_eop[t] / 1000  # при наличии
subsidy_capex[t] = 0  # задаётся вручную
subsidy_insurance_factor = 0.2  # 20% компенсация страховки
```

### 4.8.3 P&L (строки 222–240)

```python
gross_profit[t] = revenue[t] + cogs_reproducer[t] + cogs_fattening[t]

admin_expenses[t] = admin_payroll[t] + office_rent[t] + tech_repair[t] + building_repair[t] + land_tax[t]
# land_tax = -12.05 * pasture_area / 1000 / 12

EBITDA[t] = gross_profit[t] + admin_expenses[t]

depreciation_equipment[t] = capex_equipment / (5 * 12)   # 5 лет
depreciation_buildings[t] = capex_buildings / (20 * 12)   # 20 лет

EBIT[t] = EBITDA[t] - depreciation_equipment[t] - depreciation_buildings[t]

finance_costs[t] = -(wc_loan_interest[t] + investment_interest[t])

profit_before_tax[t] = EBIT[t] + finance_costs[t]
cit[t] = -0.2 * max(0, annual_profit)  # КПН 20%, раз в год
net_profit[t] = profit_before_tax[t] + cit[t]
```

---

## 4.9 Модуль LOANS

### 4.9.1 Инвестиционный кредит (Loans, строки 1–37)

```python
loan_amount = total_investment * 0.9  # 90%
rate = wacc_rate
grace_years = 2
repayment_schedule = [0, 0, 0.11, 0.11, 0.11, 0.11, 0.11, 0.11, 0.11, 0.11, остаток]  # годы 1-10+

for t in range(120):
    od_bop[t] = loan_amount if t == 0 else od_eop[t-1]
    interest[t] = od_bop[t] * rate * days_between(date[t], date[t-1]) / 365
    accumulated_interest[t] = interest[t] - interest_paid[t] + prev_accumulated
    
    # Погашение процентов: каждые 12 мес.
    # Погашение ОД: после льготного периода, ежегодно по графику
    od_eop[t] = od_bop[t] - od_repayment[t]
```

### 4.9.2 Оборотный кредит (Operating Model, строки 304–316)

```python
wc_interest_rate = 0.06

# Потребность = -(запасы_формирование + доращивание_запасы + непрямые_затраты) × switch
wc_need[t] = ...  # сложная логика MOD(COLUMN) для периодического формирования запасов

wc_balance_eop[t] = wc_balance_bop[t] + wc_received[t] + wc_repaid[t]
wc_interest[t] = wc_balance_eop[t] * wc_interest_rate / 12
```

---

## 4.10 Модуль CASH FLOW (строки 318–348)

```python
# Операционная деятельность
cf_operations[t] = net_profit[t] + depreciation[t] + wc_change_inventory[t] + wc_change_prepaid[t]

# Инвестиционная деятельность
cf_investing[t] = -(construction[t] + equipment[t] + cow_purchase[t] + bull_purchase[t])

# Финансовая деятельность
cf_financing[t] = wc_loan_net[t] + investment_loan_net[t]

# Денежный баланс
cash_bop[t] = equity_contribution if t == 0 else cash_eop[t-1]
cash_eop[t] = cash_bop[t] + cf_operations[t] + cf_investing[t] + cf_financing[t]
```

---

## 4.11 Модуль WACC + NPV/IRR

### WACC (лист WACC)

```python
equity_share = 0.10
debt_share = 0.90
loan_rate = 0.05
tax_rate = 0.10
cost_of_debt = loan_rate * (1 - tax_rate)  # 4.5%

risk_free = 0.0399    # US Treasury
country_risk = 0.0213  # Damodaran KZ
beta = 0.52
erp = 0.0646

ke_usd = risk_free + country_risk + beta * erp  # 9.48%
inflation_kz = 0.124
inflation_us = 0.03
ke_kzt = (1 + ke_usd) / (1 + inflation_us) * (1 + inflation_kz) - 1  # 19.47%

WACC = cost_of_debt * debt_share + ke_kzt * equity_share  # 5.997%
```

### NPV, IRR (Operating Model, строки 383–418)

```python
# FCFF помесячный → годовой
discount_factor[t] = 1 / (1 + WACC / 12) ** t
dfcff[t] = fcff[t] * discount_factor[t]

npv = sum(dfcff_annual)
irr = numpy_financial.irr(annual_fcff)

# Ликвидационная стоимость: стоимость КРС - долг + деньги
# MOIC и IRR для каждого года выхода (2028–2036)
```

---

## 4.12 Граф зависимостей

```
Input
│
├──→ CAPEX ──→ Loans ──→ P&L + Cash Flow
│
├──→ Оборот стада ──┬──→ Кормовая модель ──→ OPEX ──→ P&L
│                    ├──→ Реализация (голов) ──→ P&L (выручка)
│                    └──→ Среднее поголовье ──→ OPEX (вет, RFID)
│
├──→ Staff ──→ ФОТ ──→ OPEX
│
├──→ WACC ──→ NPV/IRR
│
└──→ P&L ──→ Cash Flow ──→ NPV/IRR ──→ Output
```

---

# ЧАСТЬ 5. API

## 5.1 Endpoints

```
POST   /api/projects                    # Создать проект
GET    /api/projects                    # Список проектов
GET    /api/projects/{id}               # Детали проекта
PUT    /api/projects/{id}/params        # Обновить параметры
POST   /api/projects/{id}/calculate     # Запустить расчёт → создать версию
GET    /api/projects/{id}/versions      # Список версий
GET    /api/projects/{id}/versions/{v}  # Результаты версии

# Результаты по модулям:
GET    /api/projects/{id}/versions/{v}/herd          # Оборот стада (120 мес × 6 групп)
GET    /api/projects/{id}/versions/{v}/feeding       # Кормовая модель
GET    /api/projects/{id}/versions/{v}/capex         # CAPEX
GET    /api/projects/{id}/versions/{v}/staff         # ФОТ
GET    /api/projects/{id}/versions/{v}/pnl           # P&L
GET    /api/projects/{id}/versions/{v}/cashflow      # Cash Flow
GET    /api/projects/{id}/versions/{v}/summary       # NPV, IRR, Payback, WACC

# Справочники:
GET    /api/references/{category}       # Получить справочник
PUT    /api/references/{category}/{code} # Обновить элемент
```

## 5.2 Формат ответа (пример: оборот стада)

```json
{
  "module": "herd_turnover",
  "timeline": {
    "months": [1, 2, 3, ...],
    "dates": ["2026-08-31", "2026-09-30", ...],
    "years": [2026, 2026, ...]
  },
  "groups": {
    "cows": {
      "bop": [0, 200, 199.5, ...],
      "purchased": [200, 0, 0, ...],
      "from_heifers": [0, 0, 0, ...],
      "culled": [0, 0, 0, ...],
      "mortality": [0, -0.5, -0.498, ...],
      "eop": [200, 199.5, 199.0, ...],
      "avg": [100, 199.75, 199.25, ...]
    },
    "bulls": { ... },
    "calves": { ... },
    "heifers": { ... },
    "steers": { ... },
    "fattening": { ... }
  },
  "summary": {
    "total_avg_livestock": [100, 213, ...],
    "total_sold": [0, 0, ...]
  },
  "annual": {
    "years": [2026, 2027, 2028, ...],
    "cows_eop": [200, 195, 285, ...],
    "total_sold": [0, 15, 42, ...]
  }
}
```

---

# ЧАСТЬ 6. UI — ЭКРАНЫ

## 6.1 Dashboard
- Список проектов (имя, тип, статус, дата, NPV/IRR)
- Кнопка "Новый проект"

## 6.2 Wizard ввода параметров (5 шагов)
1. Тип фермы + основные параметры (поголовье, мощность, регион)
2. Земля и инфраструктура (пастбища, сценарий отёла)
3. Условия финансирования (ставки, сроки, льготные периоды)
4. Переключатели (субсидии, оборотка, биоактивы)
5. Подтверждение + запуск расчёта

## 6.3 Результаты (табы)

**Оборот стада** — таблица помесячно (с группировкой по годам), 6 групп
**P&L** — годовой с drill-down в месяцы
**Cash Flow** — годовой
**Сводка** — карточки: NPV, IRR, Payback, WACC, итого CapEx, итого стоимость проекта
**Графики** — поголовье по группам, выручка vs OPEX, денежный баланс, EBITDA

---

# ЧАСТЬ 7. ПЛАН РЕАЛИЗАЦИИ

## Фаза 0 — Подготовка (2–3 дня)

| Задача | Что делаем | Результат |
|---|---|---|
| 0.1 | Извлечь эталонные значения из Excel (`data_only=True`) | `excel_reference.json` — 120 мес × все модули |
| 0.2 | Scaffold: FastAPI + Next.js + Docker Compose + PostgreSQL | Проект запускается |
| 0.3 | Схема БД + миграции | Таблицы projects, project_versions, reference_data |
| 0.4 | Загрузка справочников в БД | feed_norms, infrastructure_norms, feed_prices, tax_rates |

## Фаза 1 — Расчётное ядро, базовые модули (7–10 дней)

| Задача | Что делаем | Тест |
|---|---|---|
| 1.1 | Timeline + Input (1 день) | Даты, дни в месяце = Excel |
| 1.2 | Оборот стада — 6 групп (4–5 дней) | Поголовье к.п. каждого мес = Excel ± 0.01 |
| 1.3 | CAPEX (1 день) | Итого строительство, техника = Excel |
| 1.4 | Staff — ФОТ (1 день) | Staff!J36 = Excel |

## Фаза 2 — Расчётное ядро, финансовые модули (5–7 дней)

| Задача | Что делаем | Тест |
|---|---|---|
| 2.1 | Кормовая модель — 8 групп × корма (3 дня) | CFC строка 247 = Excel |
| 2.2 | OPEX (1 день) | Строки 204–220 = Excel |
| 2.3 | P&L — выручка + субсидии + ЧП (1 день) | Строки 188, 222, 240 = Excel |
| 2.4 | Loans (1 день) | ОД на конец, проценты = Excel |
| 2.5 | Cash Flow + NPV/IRR (1 день) | NPV, IRR = Excel ± 1 тг |

## Фаза 3 — API + UI (5–7 дней)

| Задача | Что делаем |
|---|---|
| 3.1 | API endpoints (2 дня) — все модули |
| 3.2 | UI Wizard ввода (2 дня) — 5 шагов |
| 3.3 | UI Результаты (3 дня) — таблицы + графики |

## Контрольные точки

| Когда | Что проверяем |
|---|---|
| Конец Фазы 1 | Оборот стада: все 6 групп × 120 мес = Excel ± 0.01 |
| Конец Фазы 2 | Финмодель: NPV, IRR, Cash Balance = Excel ± 1 тг |
| Конец Фазы 3 | Эксперт вводит параметры → видит корректный результат в UI |

---

# ЧАСТЬ 8. ВАЛИДАЦИЯ

## 8.1 Эталонные значения (300 голов, летний отёл)

| Показатель | Значение | Источник |
|---|---|---|
| Маточное (закуп) | 200 голов | Input!F40 |
| Быки (закуп) | 14 голов | Input!F41 |
| Мощность | 300 голов | Input!F42 |
| Собственное участие (15%) | ~63 390 тыс.тг | Input!F44 |
| ФОТ/мес | ~1 940 тыс.тг | Staff!J36 |
| WACC | 5.997% | WACC!E18 |

## 8.2 Обязательные проверки (assert в тестах)

1. Баланс сходится: Активы = Пассивы (строка 277 = 0)
2. Поголовье ≥ 0 во всех месяцах и группах
3. Денежный баланс ≥ 0 после оборотного займа
4. Сумма погашения ОД = Сумма займа (100%)
5. Приплод строго в месяц отёла
6. Перевод тёлок через ~18 месяцев

## 8.3 Стратегия тестирования

```
1. Запустить расчёт с образцовыми Input
2. Сравнить КАЖДЫЙ массив помесячно с excel_reference.json
3. Допуск: < 1 тг (из-за округления float)
4. Расхождение > 1 тг → трассировка формулы до корня
```

---

# ЧАСТЬ 9. ПРАВИЛА ДЛЯ РАЗРАБОТКИ

```
Код                         → английский
Комментарии / документация   → русский
Каждая функция              → одна ответственность
Тесты на расчётные функции  → обязательны
При неопределённости        → вопрос эксперту, не предположение
Изменение OUTPUT модуля     → проверка всех downstream модулей
Магические числа            → запрещены, только из справочников/Input
Все нормативы               → из БД (reference_data), не из хардкода
```

---

# ЧАСТЬ 10. РИСКИ И ОТКРЫТЫЕ ВОПРОСЫ

| # | Вопрос | Действие |
|---|---|---|
| 1 | Строка 85 (перевод тёлок в маточное) = 0 в шаблоне, использует OFFSET | Разобрать формулу OFFSET, уточнить с экспертом |
| 2 | Строка 152 (продажа после доращивания) = ArrayFormula | Ручной разбор формулы, сверка значений |
| 3 | Строка 53 (выбраковка маточного) = 0 в шаблоне | Уточнить: это баг шаблона или осознанное решение? |
| 4 | Формирование запасов (MOD logic, строки 356–370) | Сложная логика OFFSET + MOD(COLUMN) — требует внимания |
| 5 | КПН (строка 238) начисляется через AI238 | Разобрать годовой расчёт налога |
| 6 | Стоимость поголовья (строки 108–131) | Балансовая стоимость КРС — формулы не полностью видны |
| 7 | Шаблон .xlsx для генерации | Нужен финальный мастер-файл (Sprint 4) |
| 8 | Логика МРС и фидлот | Не специфицирована, нужна сессия с зоотехником |

---

*Документ содержит полный контекст для реализации Sprint 1–3. При работе с этим документом в Claude Code — начинайте с Фазы 0 (extract_excel_reference.py), затем модули строго по порядку зависимостей.*
