# A-CAT — Admin Screens for Livestock Categories & Pricing
## Dok 6 contract draft v1.0

| Field | Value |
|---|---|
| Date | 2026-06-15 |
| Status | ✅ Approved by CEO (Arshidin) — pivot from brief→seed-PR to admin UI · **UI: NOT YET BUILT (debt MARKET-UI-01)** |
| Builds on | D-TSP-CATEGORY-BRIDGE (DECISIONS_LOG 2026-06-15), Microstep4 §1.1, Microstep6 (admin flow) |
| Replaces | `Docs/Q-TSP-CATEGORY-CLASSIFIER-Zoologist-Brief.md` (deleted — same content rolled into A-CAT-03 mockup + default seed hypothesis) |
| Scope | 4 admin screens (A-CAT-01..04) + 1 bridge table + 7 admin RPCs; closes Q-TSP-CATEGORY-CLASSIFIER via P8 self-service |
| Out of scope | Farmer UX (BCS input on Batch publish is **not** added in this iteration — `livestock_category_rules.bcs_min/max` stays NULL by default) |
| Owners | DB Agent (§3 SQL) + UI Agent (§4 screens), parallel work; Architect (this doc) |

---

## 0. TL;DR

- Из админки TURAN админ управляет 4 связанными таблицами: `livestock_categories`, `livestock_category_rules`, `tsp_sku_category_map` (новая), `minimum_prices` / `reference_prices`.
- Никаких сидов в SQL. Никаких брифов зоологу. Зоолог садится за админку (или ему даётся admin-роль) и наполняет данные сам.
- **Floor-clamp в `rpc_lower_batch_price` включается безопасно**: пока `tsp_sku_category_map` пустой — `v_floor = NULL`, поведение не меняется. Как только админ замапит SKU и установит `minimum_prices` для соответствующих категорий — clamp начнёт работать **для этих SKU**. Постепенный rollout без feature flag.
- Архитектура **D-TSP-CATEGORY-BRIDGE (A2)** реализуется один раз. Дальше — pure P8 data-as-content.

---

## 1. Архитектурный контекст (для DB и UI агентов)

### 1.1. Две таксономии — почему так

| | `tsp_skus` (30 строк, deployed) | `livestock_categories` (TBD count, пустая) |
|---|---|---|
| Назначение | Продуктовая ячейка для матчинга Batch ↔ Pool | Защитные цены + индикативы |
| Хранится | Каталог `TSP-Ассортимент-КРС-v2.xlsx` (D90, fixed) | TURAN admin via A-CAT-01 |
| Юридическая роль | Товарная маркировка | Антитраст (Art.171 ПК РК): «защитный стандарт ассоциации по категории», не price-fixing |

Между ними — мост `tsp_sku_category_map` (many SKU → one Category). Каждая SKU должна попадать **ровно в одну активную категорию**.

### 1.2. Гипотеза TURAN — стартовые категории

Подсказка для админа на первом запуске (можно изменить):

| code | name_ru | Что включает (приблизительно) |
|------|---------|-------------------------------|
| `YOUNG_MEAT_ELITE` | Молодняк мясной | Бычки/тёлки 6–24 мес мясного направления (elite + local) |
| `YOUNG_CROSSBRED` | Молодняк беспородный | Бычки/тёлки 6–24 мес crossbred |
| `ADULT_BULL_MEAT` | Взрослый бычок мясной | Бычки 24–48 мес мясного направления |
| `ADULT_BULL_CROSSBRED` | Взрослый бычок беспородный | Бычки 24–48 мес crossbred |
| `COW_FATTENING` | Корова на откорм/убой | Коровы 24–48 мес |
| `COW_CULL_SENIOR` | Корова на выбраковку | Коровы 48+ мес |

Это **подсказка**, не seed. Админ создаёт категории сам через A-CAT-01.

---

## 2. Схема — что нужно добавить в `d02_tsp.sql`

### 2.1. Новая таблица — `tsp_sku_category_map` (bridge)

```sql
create table if not exists public.tsp_sku_category_map (
    id              uuid    primary key default gen_random_uuid(),
    tsp_sku_id      uuid    not null references public.tsp_skus(id),
    category_id     uuid    not null references public.livestock_categories(id),
    version         int     not null default 1,
    is_active       boolean not null default true,
    created_by      uuid    references public.users(id),
    created_at      timestamptz not null default now(),
    -- Один активный маппинг на SKU
    unique (tsp_sku_id) where (is_active = true)
);

comment on table public.tsp_sku_category_map is
    'D-TSP-CATEGORY-BRIDGE (A2, 2026-06-15): bridge tsp_skus → livestock_categories
     (many SKU → one Category). Versioned: admin может создать version=2 с is_active=false,
     потом атомарно переключить. Floor-check читает только is_active=true строки.
     Empty map → no floor-clamp (graceful degradation in rpc_lower_batch_price).';

create index if not exists idx_skumap_sku    on public.tsp_sku_category_map (tsp_sku_id) where is_active = true;
create index if not exists idx_skumap_cat    on public.tsp_sku_category_map (category_id) where is_active = true;

alter table public.tsp_sku_category_map enable row level security;

create policy "skumap_read_auth"   on public.tsp_sku_category_map for select using (auth.uid() is not null);
create policy "skumap_admin_write" on public.tsp_sku_category_map for all    using (public.fn_is_admin());
```

**Где разместить в `d02_tsp.sql`:** Section 7 (M4+M6 extension), сразу после §7.7 `livestock_categories` (line ~1330). До seed-блоков и до §8 RPC-функций.

### 2.2. Доработка `rpc_lower_batch_price` — включить floor-clamp

В [d02_tsp.sql:2944](d02_tsp.sql:2944) сейчас:
```sql
-- D-M6-3 floor clamp: SKIPPED while Q-TSP-CATEGORY-CLASSIFIER is open.
v_floor := null;
v_clamped := p_new_price_per_kg;
```

Заменить на (псевдокод):

```sql
-- D-M6-3 floor clamp: enabled via D-TSP-CATEGORY-BRIDGE (A2).
-- Resolution: batch.tsp_sku_id → bridge.category_id → minimum_prices(category_id, region_id).
-- Region match: exact rayon first; if not found → national fallback (region_id IS NULL).
-- If map empty for this SKU → v_floor stays NULL → clamp = no-op (graceful).
select mp.price_per_kg into v_floor
from public.tsp_sku_category_map m
join public.minimum_prices mp on mp.category_id = m.category_id
where m.tsp_sku_id = v_batch.tsp_sku_id
  and m.is_active  = true
  and mp.is_active = true
  and (mp.region_id = v_batch.region_id or mp.region_id is null)
  and (mp.valid_to is null or mp.valid_to >= current_date)
order by (mp.region_id = v_batch.region_id) desc nulls last,  -- exact region wins
         mp.valid_from desc
limit 1;

v_clamped := greatest(p_new_price_per_kg, coalesce(v_floor, p_new_price_per_kg));
v_was_clamped := (v_floor is not null and p_new_price_per_kg < v_floor);
```

**Возврат** уже содержит `was_clamped` (см. имеющуюся переменную `v_was_clamped`) — клиент узнаёт о применённом полу.

### 2.3. Доработка `rpc_create_pool` — floor-enforcement через bridge

В [d02_tsp.sql:2151](d02_tsp.sql:2151) сейчас floor работает **только если** клиент передал `livestock_category_id` явно в jsonb-строке. Это back-compat-fallback оставляем, но добавляем безусловный путь через мост:

```sql
-- Resolve category via bridge if caller didn't provide it explicitly.
v_category_id := coalesce(
    (line ->> 'livestock_category_id')::uuid,
    (select category_id from public.tsp_sku_category_map
     where tsp_sku_id = (line ->> 'tsp_sku_id')::uuid
       and is_active = true
     limit 1)
);

-- Hard-block as before (unchanged), now driven by bridged category_id.
```

Сигнатура `rpc_create_pool` не меняется — P7 additive.

### 2.4. 7 admin RPCs (`SECURITY DEFINER`, гейт через `fn_is_admin()`)

Все возвращают `jsonb` со структурой `{ok: boolean, id?: uuid, error?: text}`. Сигнатуры:

| # | RPC | Назначение |
|---|-----|-----------|
| AC-1 | `rpc_admin_upsert_livestock_category(p_code text, p_name_ru text, p_description_ru text, p_sort_order int) → jsonb` | INSERT или UPDATE по `code`. Возвращает category_id. |
| AC-2 | `rpc_admin_deactivate_livestock_category(p_category_id uuid) → jsonb` | `is_active = false`. Hard-блок если на категорию есть активные `tsp_sku_category_map.is_active = true` или активные `minimum_prices` — возвращает `{ok:false, error:'CATEGORY_IN_USE'}`. |
| AC-3 | `rpc_admin_set_category_rule(p_category_id, p_breed_group?, p_sex?, p_age_min?, p_age_max?, p_weight_min?, p_weight_max?, p_bcs_min?, p_bcs_max?, p_priority int, p_version int) → jsonb` | INSERT rule. Версионирование: новые правила — version=N+1, активируется атомарно через AC-4. |
| AC-4 | `rpc_admin_activate_rule_version(p_category_id uuid, p_version int) → jsonb` | Атомарный switch: предыдущие версии правил → `is_active=false`, целевая → `is_active=true`. |
| AC-5 | `rpc_admin_map_sku_to_category(p_tsp_sku_id uuid, p_category_id uuid) → jsonb` | Upsert в `tsp_sku_category_map`: предыдущая активная строка для этой SKU → `is_active=false`, новая создаётся с `is_active=true`, `version=prev+1`. Атомарно. |
| AC-6 | `rpc_admin_set_minimum_price(p_category_id uuid, p_region_id uuid, p_price_per_kg int, p_valid_from date, p_valid_to date) → jsonb` | INSERT (versioned). Старая запись `(category_id, region_id)` с пересекающимся периодом → `is_active=false`, новая активируется. |
| AC-7 | `rpc_admin_set_reference_price(p_category_id uuid, p_region_id uuid, p_price_per_kg int, p_valid_from date, p_valid_to date) → jsonb` | То же для `reference_prices`. |

**Read RPCs** (отдельная группа, для экранов):

| # | RPC | Возвращает |
|---|-----|------------|
| AR-1 | `rpc_admin_list_categories_with_stats() → table` | category + кол-во активных правил + кол-во замапленных SKU + есть ли minimum_price |
| AR-2 | `rpc_admin_list_category_rules(p_category_id uuid) → table` | все правила (все версии) для категории |
| AR-3 | `rpc_admin_get_sku_coverage() → table` | 30 SKU × текущий маппинг (NULL если не замаплено). Для A-CAT-03. |
| AR-4 | `rpc_admin_list_prices(p_kind text) → table` | `p_kind ∈ {'minimum','reference'}` — все активные цены × регион × категория. Для A-CAT-04. |

### 2.5. Реестр имён

Добавить в `rpc_name_registry` все 11 новых RPC (AC-1..7 + AR-1..4). Per D-NEW-A.

---

## 3. UI экраны — A-CAT-01..04

### 3.0. Общее

- **Маршрут:** `/admin/livestock-categories/*` (новая папка `src/pages/admin/livestock-categories/`).
- **AppShell:** существующий admin layout, neutral theme (`.light`), без warm palette.
- **Sidebar пункт:** «Категории и цены TSP» с иконкой (см. Sidebar.tsx convention; икона — `Tag` или `Layers`).
- **Topbar (D-UI-TOPBAR-01):** `useSetTopbar({title: 'Категории и цены TSP', titleIcon: <Tag size={15}/>, tabs: [Категории, Правила, SKU маппинг, Цены]})`.
- **Disclaimer Art.171 ПК РК** на A-CAT-04 (внутри карточки цен).
- Гейт доступа: `fn_is_admin()` на RPC + клиентская проверка роли через `useAdminGuard()` (если такого хука нет — создать; UI Agent сверится с MembershipDecision.tsx как pattern).

### 3.1. A-CAT-01 — Категории

**Назначение:** CRUD `livestock_categories`. Стартовый экран, где админ создаёт 5–8 категорий.

**Контент:**
- Таблица колонок: `Код` (code), `Название (RU)`, `Описание (RU)`, `Sort`, `Активна`, `Правил derive`, `SKU замаплено`, `Floor задан` (✅/—), `Reference задан` (✅/—).
- Колонки 5–9 — derived из `rpc_admin_list_categories_with_stats`.
- Кнопка «Создать категорию» открывает modal с полями: code (kebab/SCREAMING_SNAKE — валидация regex), name_ru, description_ru, sort_order.
- Inline-редактирование name_ru / sort_order / description_ru (через `rpc_admin_upsert_livestock_category`).
- Меню «⋯» на строке: «Деактивировать» (RPC AC-2, показывает error если категория in use).
- **Подсказка-баннер сверху на первом запуске** (когда таблица пуста): «Создайте 5–8 категорий. Стандартный набор TURAN: Молодняк мясной, Молодняк беспородный, Взрослый бычок мясной…» с кнопкой «Создать набор по умолчанию» — клиентский цикл из 6 вызовов AC-1 с гипотезой §1.2.

**RPC:** AC-1, AC-2, AR-1.

### 3.2. A-CAT-02 — Правила derive

**Назначение:** управление `livestock_category_rules`. Версионирование visible.

**Контент:**
- Селектор категории (dropdown сверху, из AR-1).
- Таблица правил выбранной категории: `Версия`, `breed_group`, `sex`, `age_min–max`, `weight_min–max`, `bcs_min–max`, `priority`, `Активна`.
- Кнопка «Добавить правило в новую версию» — создаёт правило с `version = max(version) + 1`, `is_active = false`.
- Кнопка «Активировать версию N» — AC-4 атомарно переключает.
- Поля BCS помечены как «Не обязательно (NULL = wildcard)» — подсказка в UI.

**RPC:** AC-3, AC-4, AR-2.

### 3.3. A-CAT-03 — SKU маппинг (главный экран моста)

**Назначение:** связать каждую из 30 SKU с одной категорией. Сердце D-TSP-CATEGORY-BRIDGE.

**Контент:**
- Индикатор покрытия сверху: «Замаплено: 27 из 30 SKU» (зелёная плашка если 30/30).
- Таблица из 30 строк (из `tsp_skus` × current bridge):
  - Колонки read-only: `sku_code`, `Описание` (= breed_group / sex / age_group / weight_category из tsp_skus с человекочитаемыми лейблами), `Сорт` (grade).
  - Колонка `Категория`: dropdown из активных категорий, или плашка «не замаплено» (красная) если NULL.
  - Изменение dropdown → немедленный вызов AC-5 → row reload.
- Фильтры в шапке: «Показать только незамапленные», по breed_group, по sex.
- Bulk-action: «Замапить все выбранные на категорию X» (checkbox + dropdown в шапке).

**RPC:** AC-5, AR-3, AR-1 (для dropdown).

### 3.4. A-CAT-04 — Защитные / индикативные цены

**Назначение:** управление `minimum_prices` и `reference_prices`. Юридически — это **публикация защитного стандарта ассоциации**.

**Контент:**
- **Два таба:** «Минимальные (защитные)» и «Индикативные (рекомендованные)».
- **Disclaimer Art.171 ПК РК** прибит к шапке таба «Индикативные»: «Справочные цены являются индикативными рыночными ориентирами. TURAN не устанавливает и не гарантирует цены сделок.»
- Таблица колонок: `Категория`, `Регион` (или «Национальная» если NULL), `₸/кг`, `Действует с`, `Действует до`, `Активна`.
- Кнопка «Создать запись цены» — modal с полями: категория (dropdown), регион (dropdown с опцией «Национальная (для всех регионов)»), price_per_kg, valid_from, valid_to.
- Inline indication: если на эту `(категория, регион)` пара уже есть пересекающаяся активная запись — предупреждение «Существующая запись будет деактивирована при сохранении» (это и есть поведение AC-6/AC-7).
- **Approved_by снимок:** запись о том, кто из админов утвердил цену, отображается в строке.

**RPC:** AC-6, AC-7, AR-1, AR-4.

---

## 4. Что делает админ (Arshidin + зоолог) за один час

1. Открыть `/admin/livestock-categories/categories` → нажать «Создать набор по умолчанию» → отредактировать названия → 6 категорий есть.
2. Перейти в «Правила derive» → для каждой категории добавить 1 правило (version=1) → активировать.
3. Перейти в «SKU маппинг» → проставить 30 dropdown'ов (~2 минуты) → покрытие 30/30.
4. Перейти в «Цены» → ввести 6 minimum_prices (национальная) + 6 reference_prices → готово.

После этого:
- `rpc_lower_batch_price` floor-clamp **активен**.
- `rpc_create_pool` floor-enforcement **безусловный**.
- Q-TSP-CATEGORY-CLASSIFIER **closed**.
- Пилот TSP **разблокирован**.

---

## 5. Hand-off для DB Agent

**Файл:** только `d02_tsp.sql` (single canonical, no patches per CLAUDE.md).

**Чек-лист:**
- [ ] §7.x: добавить `tsp_sku_category_map` table + index + RLS policies (§2.1).
- [ ] §8: модифицировать `rpc_lower_batch_price` — заменить заглушку `v_floor := null` на bridge JOIN (§2.2).
- [ ] §8: модифицировать `rpc_create_pool` — добавить bridge lookup в category resolution (§2.3).
- [ ] §8: добавить 7 admin write-RPC (AC-1..7) и 4 admin read-RPC (AR-1..4) — все `SECURITY DEFINER`, гейт `fn_is_admin()`.
- [ ] §8: дополнить `rpc_name_registry` 11 строками.
- [ ] Обновить header-комментарий в §8 (удалить запись «Known gap (Q-TSP-CATEGORY-CLASSIFIER)»).
- [ ] Прогнать `bash cross_check.sh` — ожидаемо 0 Critical / 0 Significant.
- [ ] **НЕ применять миграцию на remote `mwtbozflyldcadypherr`** до явного «ок» от Arshidin.

**Идемпотентность:** `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, RPC re-create — всё безопасно к re-run.

**Дополнительная защита:** если по какой-либо причине bridge остаётся пустым в момент деплоя — поведение системы **идентично текущему** (floor=NULL, clamp=no-op). Это означает что схему можно мигрировать **до** того, как админ заполнит данные.

---

## 6. Hand-off для UI Agent

**Папка:** `src/pages/admin/livestock-categories/`.

**Файлы (новые):**
- `LivestockCategoriesLayout.tsx` — Tabs wrapper (D-UI-TOPBAR-01)
- `CategoriesTab.tsx` — A-CAT-01
- `RulesTab.tsx` — A-CAT-02
- `SkuMappingTab.tsx` — A-CAT-03
- `PricesTab.tsx` — A-CAT-04

**Изменяемые файлы:**
- `src/components/Sidebar.tsx` — добавить пункт «Категории и цены TSP» в admin-секции.
- `src/App.tsx` или `src/router.tsx` — добавить маршруты `/admin/livestock-categories/*`.
- ⚠ Sidebar и Router изменяются **аддитивно** (новый пункт + новые routes) — никакие существующие пункты не удаляются (HS-5).

**Паттерн:**
- AppShell + neutral theme (existing convention)
- Topbar через `useSetTopbar` (D-UI-TOPBAR-01)
- Data-fetching через `supabase.rpc(...)` напрямую (не Edge Functions — admin RPC)
- Гейт на роуте через существующий `useAdminGuard` (либо создать минимальный hook, если его нет — см. MembershipDecision.tsx)
- shadcn/ui компоненты (Table, Dialog, Select, Tabs) — на проекте уже установлены

**Чек-лист:**
- [ ] Все 4 экрана подключены к RPC AC-/AR- (после deploy DB Agent'ом)
- [ ] A-CAT-03 показывает индикатор покрытия SKU
- [ ] A-CAT-04 показывает disclaimer Art.171 на табе «Индикативные»
- [ ] Topbar tabs работают, активная вкладка подсвечивается
- [ ] Inline-edit + modal-create + bulk-action поведение по §3
- [ ] `pnpm typecheck` чистый
- [ ] Live-проверка локально: создать категорию → создать правило → замапить SKU → задать цену → опубликовать тестовый Batch → понизить цену → убедиться что floor-clamp сработал.

---

## 7. Что НЕ делаем в этой итерации

- **BCS на стороне фермера.** `livestock_category_rules.bcs_min/max` остаются NULL (wildcard). Если зоолог решит, что BCS нужен — это будет отдельная итерация: новое поле в `batches`, новый input в Batch publish form, переписывание `rpc_derive_category`.
- **`rpc_derive_category`.** Эта функция полезна для AI Gateway (extract category из фото/текста), но в текущем sprint её **не пишем** — bridge достаточен для floor-check, а AI extraction может прийти позже.
- **Региональные защитные цены.** Стартуем с национальных (region_id IS NULL). Региональные — когда админ сам решит добавить.
- **Эпохи цен (история).** `valid_to` поддерживается схемой, но UI на A-CAT-04 показывает только активные. Просмотр истории — Phase 2.
- **Зоолог как роль.** Сейчас всё через `fn_is_admin()`. Отдельная роль «livestock-classifier» — если понадобится — отдельная задача.
