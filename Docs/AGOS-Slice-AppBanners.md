# Eng-Spec / Slice — App Banners (Главная: Фермер + МПК)

> In-repo engineering spec (detailed intent). Thin-синтез — Brain [[projects/agos/specs/app-banners]].
> Graphify индексирует этот файл — имена сущностей/RPC/таблиц держим = SQL-токенам.
> Apply order: d01 → d02 → d03 → d04 → d05 → d07 → d08 → **d10**.

- **Brain synthesis:** `apex-brain/projects/agos/specs/app-banners.md`
- **Linear epic:** [ARS-193](https://linear.app/arshidin/issue/ARS-193) (баннеры = пункт №1)
- **Canon domain owner:** UI/Screens (Dok 6 slices) + Public-site CMS-паттерн (`d10_public_site.sql`)
- **Status:** agreed (G2 2026-07-15)

---

## 1. Data model (P1 — first) → `d10_public_site.sql`

Новая таблица `home_banners` — калька паттерна `news_articles` (та же RLS/триггер-модель).

```sql
create table if not exists public.home_banners (
  id                 uuid        not null default gen_random_uuid() primary key,
  app                text        not null check (app in ('farmer','mpk')),
  title              text        not null,               -- крупный текст плитки
  subtitle           text,                               -- подпись / лейбл CTA
  kicker             text,                               -- мелкий верхний лейбл («ЦЕНЫ TURAN»)
  image_path         text,                               -- фон: asset-ключ ('banner-prices') ИЛИ https-URL
  icon               text,                               -- Phosphor-ключ (fallback без картинки)
  tone               text        not null default 'neutral'
                                 check (tone in ('gold','green','neutral')),
  action_type        text        not null default 'none'
                                 check (action_type in ('internal','external','none')),
  action_target      text,                               -- internal: enum-ключ; external: https-URL; none: NULL
  membership_variant text        not null default 'all'
                                 check (membership_variant in ('all','season','campaign','join')),
  sort_order         int         not null default 0,
  active_from        timestamptz,                        -- NULL = без нижней границы
  active_until       timestamptz,                        -- NULL = бессрочно; иначе «актуальность» уходит авто
  is_active          boolean     not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists idx_home_banners_live
  on public.home_banners (app, is_active, sort_order);

drop trigger if exists set_home_banners_updated_at on public.home_banners;
create trigger set_home_banners_updated_at
  before update on public.home_banners
  for each row execute function public.update_updated_at_column();
```

**Ownership (P2):** создаёт/обновляет — expert/admin через `admin_*` RPC; авторитет — БД (единственный
источник, P4). **История vs current (P12):** только current-state (баннер = эфемерный контент; при
нужде аудита — позже). **Incomplete-state (P11):** все поля кроме `app`/`title`/`tone`/`action_type`/
`membership_variant` — nullable; баннер валиден с минимумом (app + title).

**`action_target` — контракт значений:**
- `action_type='internal'` → enum-ключ: `open_prices · open_market · join_membership ·
  pay_membership · open_course · open_tsp · open_offers · none`. Валидация — в админ-форме (клиент)
  + defensive-маппинг в клиенте (неизвестный ключ → no-op/тост, не краш).
- `action_type='external'` → `https://…` (URL-валидатор в форме; открытие безопасным внешним переходом).
- `action_type='none'` → `action_target IS NULL` (информационная плитка).

### RLS (калька news_articles)
```sql
alter table public.home_banners enable row level security;

-- чтение живых баннеров — любому аутентифицированному (фильтр окна/флага делает клиентский RPC)
drop policy if exists "home_banners_select_live" on public.home_banners;
create policy "home_banners_select_live"
  on public.home_banners for select using (is_active = true);

drop policy if exists "home_banners_select_admin" on public.home_banners;
create policy "home_banners_select_admin"
  on public.home_banners for select to authenticated
  using (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "home_banners_insert_admin" on public.home_banners;
create policy "home_banners_insert_admin"
  on public.home_banners for insert to authenticated
  with check (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "home_banners_update_admin" on public.home_banners;
create policy "home_banners_update_admin"
  on public.home_banners for update to authenticated
  using (public.fn_is_admin() or public.fn_is_expert())
  with check (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "home_banners_delete_admin" on public.home_banners;
create policy "home_banners_delete_admin"
  on public.home_banners for delete to authenticated
  using (public.fn_is_admin());
```

> Примечание RLS: баннеры — НЕ per-organization данные (общий ассоциативный контент), поэтому
> `organization_id`-изоляции здесь нет by design — это не операционная таблица фермера. Cross-org
> утечки нет: контент одинаков для всех в рамках `app` + `membership_variant`.

### Сид текущих баннеров (HS-2 — не теряем работающее)
`ON CONFLICT DO NOTHING`, чтобы визуально не регрессировать. Маппинг из `HomeBanner.tsx` +
`banners.ts`:

| kicker / title | app | tone | action_type | action_target | membership_variant |
|---|---|---|---|---|---|
| Членство TURAN | farmer | gold | internal | join_membership | join |
| Курс TURAN: сезон отёла | farmer | green | internal | open_course | all |
| Справочные цены | farmer | green | internal | open_prices | all |
| Маркет · скоро | farmer | neutral | none | — | all |

`image_path` = asset-ключи `banner-membership`/`banner-course`/`banner-prices`/`banner-market`
(остаются в `src/assets/turan/`; клиент резолвит ключ→импорт). Вариант членства из `CabinetApp.tsx`
переносится в `membership_variant` (первая плитка «Членство» реагирует на статус — логика в клиенте
поверх данных).

## 2. RPC (Dok 3 contract) — additive, `d10_public_site.sql`

Все `SECURITY DEFINER set search_path = public`. Клиентский read — не admin-only.

- `rpc_list_home_banners(p_app text, p_membership_variant text default 'all')
   returns setof public.home_banners` — активные + попавшие в окно `now()`, `membership_variant IN ('all', p_variant)`, `order by sort_order`.
- `admin_list_home_banners(p_app text default null) returns setof public.home_banners` — все, `order by app, sort_order`.
- `admin_save_home_banner(p_id uuid default null, p_app text, p_title text, … все поля …)
   returns public.home_banners` — upsert (id NULL → insert, иначе update).
- `admin_toggle_home_banner(p_id uuid, p_is_active boolean) returns public.home_banners`.

**P7:** новые имена, ни одной существующей сигнатуры не трогаем. **Web+AI одна функция** — здесь
только web (AI баннерами не управляет), дублирования нет. Имена → внести в `rpc_name_registry`.

## 3. Events (Dok 4)

MVP — **событий нет** (аналитика показов/кликов отложена). Задел: при добавлении аналитики —
`market.banner.impression` / `market.banner.click` (аддитивно, не в этом срезе).

## 4. UI contract (Dok 6)

### 4B. Админка `/admin/content/banners` (Slice B)
- Роут под `<Route path="/admin">` (гард `fn_is_expert() OR fn_is_admin()`), страница
  `src/pages/admin/content/BannersAdmin.tsx`, хук `useAdminHomeBanners` (React-Query, паттерн
  `useAdminNewsArticles`).
- Sidebar: новый пункт «Контент» в группе «Платформа» (`Sidebar.tsx` `ADMIN_GROUPS`), lucide-иконка
  (admin-зона = Dok12 design system, НЕ Phosphor).
- `useSetTopbar({ title: 'Контент приложений', titleIcon: <… same as Sidebar> })` (D-UI-TOPBAR-01).
- Список: вкладки Фермер / МПК. Форма: title/subtitle/kicker/tone/icon/image · `action_type`-селект →
  условно enum-селект целей ИЛИ URL-поле · membership_variant · sort_order · active_from/until ·
  is_active-тумблер. **Живой превью** карточки. Валидация URL для external.

### 4C. Фермер `HomeBanner.tsx` (Slice C)
- Источник плиток = `rpc_list_home_banners('farmer', variant)` вместо хардкод-массива `tiles`.
- **Сохраняем** (HS-2): карусель, scroll-snap, точки, автосмену 22.5с, реактивность первой плитки на
  членство. Variant вычисляется в клиенте (как сейчас в `CabinetApp.tsx`), передаётся в RPC.
- `action`-диспетч: маппинг enum-ключ → существующие `ctx.*`-хендлеры (`openPrices`, `memberAct`,
  `toast`, …); `external` → безопасный внешний переход; неизвестный ключ → no-op (defensive).
- Farmer-зона design canon: Phosphor-иконки, Geist, тёплые токены (`Docs/AGOS-DesignRules-FarmerCabinet.md`).

### 4D. МПК `MpkHomeScreen.tsx` (Slice D)
- **Добавляем** промо-плейсмент (сейчас его нет — только статус-баннеры `MpkTypeBanner`/`MpkMemberBanner`,
  их НЕ трогаем, аддитивно). Читает `rpc_list_home_banners('mpk', …)`.
- Плейсмент — под героем / над «первыми шагами» (точное место — на этапе кода по превью).

## 5. Slices → Tasks

| Task | Tier | Acceptance |
|------|------|-----------|
| A · `home_banners` + RLS + 4 RPC + сид | semantic | Таблица+RLS создаются идемпотентно; `rpc_list_home_banners('farmer')` возвращает 4 сид-баннера в окне; admin-RPC доступны только expert/admin; `cross_check.sh` зелёный; имена в `rpc_name_registry` |
| B · Админка `/admin/content/banners` + Sidebar + хук | semantic | CRUD баннеров из UI; вкладки Фермер/МПК; превью; URL-валидация; пункт Sidebar в «Платформа»; топбар по D-UI-TOPBAR-01 |
| C · Фермер `HomeBanner` ← БД | mechanical | Карусель фермера рендерит баннеры из БД; поведение (snap/точки/автосмена/реакция на членство) не регрессирует; action-диспетч работает для всех enum + external |
| D · МПК промо-плейсмент | mechanical | На Главной МПК появляется промо из БД; статус-баннеры не тронуты; пустой список → плейсмент не рендерится (нет пустой рамки) |

Порядок: A → (B ∥ C) → D. «Где живёт» не фризим — собираем из graphify на старте кода.

## 6. Conflict / invariant check (G1 inputs)

- **P7:** только новые таблица/RPC/имена — существующие сигнатуры не трогаем. ✅
- **FINAL schema:** новая таблица (не изменение существующих). ✅
- **DECISIONS_LOG:** прецедент «изменение = запись» (`tsp_config`); противоречий нет. ✅
- **Art. 171:** баннеры могут показывать справочные цены/CTA — **дисклеймер ст.171 обязателен**, где
  всплывают справочные цены; НЕ даём в баннер-CRUD произвольный обязывающий ценовой текст. Юр-дисклеймер
  вне этого CRUD (отдельный пункт ARS-193). ⚠️ инвариант.
- **RLS/cross-org:** баннеры — общий контент, не per-org; утечки нет by design (см. примечание §1).

## 7. Verification (G3 inputs)

- `cross_check.sh` зелёный (SQL идемпотентность, RPC-registry).
- Тест: `rpc_list_home_banners` фильтрует по `is_active`+окно+variant; admin-RPC отклоняет
  не-expert/admin (RLS).
- Preview (qa-agent): фермер — карусель из БД, все action-типы кликабельны и ведут куда надо
  («рабочие ссылки» — буквальный критерий задачи); МПК — промо появляется; toggle is_active в
  админке → баннер исчезает у клиента.
- `graphify update .` после кода; reality↔intent сверка; расхождение → `IMPL_DEBT.md`.
