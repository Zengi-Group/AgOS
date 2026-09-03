# TURAN AgOS — Design System

Аграрный CRM/ERP для фермерских хозяйств Казахстана.
Тёплый, тихий интерфейс. Громкое действие. Один оранжевый акцент — только на звезде.

---

## Контекст

**TURAN AgOS** — веб-платформа для фермерских хозяйств:
- **Кабинет фермера** — профиль фермы, поля, животные, отчёты, ветеринарные кейсы, заявки в консалтинг.
- **Админ-панель** — очередь заявок, модерация профилей, управление проектами и специалистами.
- **Консалтинг и проекты** — сопровождение фермеров агро- и вет-специалистами.

**Стек:** React 18+, TypeScript, Vite, Tailwind (опционально — всё через CSS-переменные из `colors_and_type.css`), shadcn/ui, Supabase. Иконки — inline-SVG набор в стиле `lucide` (stroke 1.5). Текст и моно — **Geist** / **Geist Mono** (Vercel, SIL OFL).

**Бренд:** turan.kz — тёплая палитра (бежево-коричневые нейтралы), оранжевая звезда логотипа. Позиционирование: «технологично, спокойно, уверенно. Корни в казахской агрокультуре, подача современная и минималистичная».

**Эталоны:** Attio, Vercel Dashboard. Плотная сетка, тонкие бордюры, типографика как главный носитель иерархии, минимум декора.

---

## Источники

Если у вас есть доступ, вот откуда это собрано:

- **Скриншоты реального продукта** — `source_screens/` (из исходного zip). Главный визуальный эталон: консоль эксперта (инвестпроекты, KPI-карточки, вкладки, клиника).
- **Codebase** (в этот проект не вложен) — исходный `Design_System/`: `tokens.ts`, `AgOS_AppShell_v11.jsx`, `AgOS_Components_Tier1/2.jsx`, `AgOS_UI_Implementation_Guide*.md`, `AgOS_Design_System_Docs.md`. Если понадобится сверка — прикрепите его через Import.
- **Рекреации компонентов** (React) — атомы в корне: `sidebar.jsx`, `header.jsx`, `primitives.jsx`; демо `Sidebar.html`, `Header.html`. Их же используют UI-киты.
- **Логотип** — `assets/turan-logo.svg` (wordmark) и `assets/turan-star.svg` (звезда).
- **Бренд-сайт** — turan.kz (референс палитры).

---

## Index (манифест проекта)

```
.
├── README.md                       ← этот файл — контекст, источники, content + visual foundations, iconography, манифест
├── SKILL.md                        ← агент-skill для генерации TURAN-брендированных артефактов
├── colors_and_type.css             ← канонические CSS-переменные: базовые + семантические роли. Default dark, [data-theme="light"]
├── assets/
│   ├── turan-logo.svg              ← Turan wordmark + star
│   └── turan-star.svg              ← одинокая 8-лучевая звезда (единственное «громкое» место в интерфейсе)
├── source_screens/                 ← скриншоты реального продукта (визуальный эталон: консоль эксперта)
├── preview/                        ← карточки для вкладки Design System (36 шт). Каждая — мелкий, сфокусированный кусок.
│   ├── _shared.css                 ← общая подложка карточек: фон, типографика, нейтральные параметры
│   ├── logo-mark.html / logo-usage.html / iconography.html / typography.html
│   ├── colors-neutral-{dark,light}.html / colors-brand.html / colors-cta.html / colors-status.html
│   ├── spacing.html / radii.html / shadows.html / heights.html / surface-hierarchy.html / motion.html
│   ├── buttons.html / inputs.html / badges.html / avatars.html / card-component.html
│   ├── table-row.html / dropdown.html / filter-chips.html / accordion.html / breadcrumb.html
│   ├── date-picker.html / option-list.html / pagination.html / scrollbar.html / skeleton.html
│   ├── tabs.html / toast.html / disclaimer.html
│   └── header-anatomy.html / header-list.html / header-record.html
├── sidebar.jsx / header.jsx / primitives.jsx   ← канонические React-атомы (источник карточек и китов)
├── Sidebar.html / Header.html / design-canvas.jsx   ← демо/исследования (sidebar-bold/-conservative — варианты)
└── ui_kits/
    ├── console/                    ← КОНСОЛЬ ЭКСПЕРТА (реальный продукт): инвестпроекты + клиника
    │   ├── README.md / index.html              ← кликабельный прототип (список ↔ запись, вкладки)
    │   ├── ProjectsList.jsx / ProjectDetail.jsx
    │   └── sidebar.jsx / header.jsx / primitives.jsx
    └── farmer/                     ← КАБИНЕТ ФЕРМЕРА: обзор + стадо с detail-панелью
        ├── README.md / index.html
        ├── FarmDashboard.jsx / HerdList.jsx
        └── sidebar.jsx / header.jsx / primitives.jsx
```

---

## Content Fundamentals

**Язык:** русский по умолчанию. В интерфейсе смешиваются домены — агрономия, ветеринария, финансы, — но тон один.

**Тон:**
- Технологичный и спокойный. Как диспетчер. Никаких восклицательных знаков, капса, маркетинг-клише.
- «Заявка принята» — не «Ура! Заявка успешно создана! 🎉».
- «Стадо №4 · 128 голов» — не «Ваше прекрасное стадо!».

**Местоимения:**
- «Вы» в адресации пользователя (формальное, нейтральное).
- Вне адресации — безличные формулировки: «Нет активных заявок», а не «У вас нет…».
- CTA — инфинитив или первое лицо по контексту: «Отправить заявку», «Добавить поле», «Сохранить».

**Регистр:**
- Кнопки — Sentence case: «Добавить контакт», «Отправить заявку».
- Навигация — Sentence case: «Мои поля», «Ветеринарные кейсы».
- Section headers в таблицах и deta­il-панелях — UPPERCASE 10px / 600 с letter-spacing `0.06em`: `ПОСЛЕДНЯЯ АКТИВНОСТЬ`, `КОНТАКТЫ`.
- Бейджи статусов — Sentence case: `• Активна`, `• Ожидает модерации`.

**Плотность:**
- Короткие метки. «Вет. кейс», «Кол-во голов», «Площадь, га».
- В таблицах — одно числовое значение на ячейку, моноширинный шрифт, выравнивание справа.
- В detail-панели — лейбл (112px) + значение. Без двоеточий после лейбла.

**Эмодзи:** не используются. Никогда. Ни в интерфейсе, ни в копирайтинге, ни в пустых состояниях.

**Числа и единицы:**
- Тысячи — неразрывный пробел: `12 450 ₸`, `128 голов`, `340 га`.
- Валюта — `₸` после числа с неразрывным пробелом.
- Даты — `15 мар 2026`, `Сегодня`, `Вчера`, `2 дн назад`. В таблицах моноширинный.
- Проценты — `92%` (без пробела).

**Примеры живого копирайтинга:**

| Место | Копия |
|-|-|
| Пустое состояние | `Заявок пока нет. Добавьте первую, чтобы начать работу с консалтингом.` |
| Ошибка загрузки | `Не удалось загрузить список. Попробуйте ещё раз.` |
| Кнопка CTA | `Отправить на модерацию` · `Добавить поле` · `Создать вет-кейс` |
| Подтверждение | `Заявка принята. Мы свяжемся с вами в течение 24 часов.` |
| Сайдбар-счётчики | `Заявки 12` · `Стадо 248` |
| Бейдж статуса | `• На модерации` · `• Принят` · `• Требует правок` · `• Отклонён` |

---

## Visual Foundations

### Палитра

Три ролевых слоя:

1. **Нейтралы** — тёплые бежево-коричневые. Несут 95%+ интерфейса.
   - Light: `#f0ebe2 → #e9e3d8 → #f7f4ee → #e3ddd2` (page → sidebar → card → hover).
   - Dark: `#141312 → #1b1a18 → #222120 → #2c2b28`. Намеренно близкие, чтобы иерархия считывалась по тени и бордюру, а не по яркости.
2. **Акцент** — оранжевая звезда `#E8920B` (light) / `#F0A020` (dark). Используется **только** на логотипе и, в порядке исключения, на звёздочках «Избранное» в сайдбаре (там берёт семантический цвет, не акцент).
3. **CTA** — тёмно-коричневый `#3d2b1f` (light) / кремовый `#e6e2dc` (dark). Это единственная громкая кнопка на экране. Одна за раз.

Статусы (`green / blue / emerald / amber / red`) — семантические, theme-aware. Не бренд. Принцип: «сине-красно-зелёный палитра для данных, коричневая — для UI».

### Типографика

- **Geist** — всё UI-тело. Стек: `'Geist', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`. Причина выбора: cyrillic-first (включая казахский ҒҚҢӨҰҮҺ), низкий визуальный шум на 11–13px, парный mono, табличные цифры по умолчанию.
- **Geist Mono** — числа, код, tabular-nums, IDs, shortcut-бейджи. Спроектирован в паре с Geist, совпадают метрики.
- Шкала без половинок: `10 / 11 / 12 / 13 / 14 / 15 / 20 px`. Всё прочее запрещено.
- Веса: 400 / 500 / 600 / 700. 500 для полумощного акцента (имя в таблице), 600 для заголовков и лейблов секций, 700 — только XL (20px) на record-странице.
- Line-height: 1.5 body, 1.4 заголовки, 1.2 у numeric XL.
- Letter-spacing: `-0.01em` на логотипе и 20px-заголовке, `0.04–0.06em` UPPERCASE на section headers, 0 — остальное.

Иерархия строится шрифтом и плотностью. Крупные яркие заголовки — антипаттерн.

### Сетка, плотность, layout

- CSS Grid на уровне AppShell: `var(--sw) 1fr var(--pw)` × `44px 1fr`.
- Строки в таблицах — 44px. Header row — 36px, sticky top, bg `--bg-s`.
- Разделители между колонками: `var(--bd-s)` вертикальные линии — плотная Attio-сетка.
- Inline-редактирование вместо модалок для простых полей (клик по значению → поле с `--bd-h` и warm ring).
- Detail-панель 348–360px, slide-in справа 250ms. Открывается по клику на строку.

### Фон, текстуры, изображения

- Плоский цвет. Никаких градиентов на фоне. Никаких паттернов, текстур, нарисованных иллюстраций.
- Фото фермы / полей, если используются, — в прямоугольных карточках с `--r-lg` (8px), без параллакса и эффектов. Placeholder — `var(--bg-m)` с маленькой иконкой `--fg3`.
- Тон фотографий — тёплый, натуральный свет. Без фильтров. Без ч/б. Без плёночного зерна.

### Бордюры, shadows, эффекты

- Бордюры: `1px solid var(--bd)` — дефолт, `var(--bd-s)` — субтильные (строки таблицы), `var(--bd-h)` — hover/focus. Толще 1px — только focus ring (2px).
- Shadows — 4 уровня (sm / md / lg / xl). В light тенях — тёплая коричневая база `rgba(61,43,31,...)`, не pure black.
- Tooltips — `sh-md`, dropdowns — `sh-lg`, modals и command palette — `sh-xl`.
- Без glow-эффектов. Без цветных теней. Без inner shadows.
- Прозрачность + blur — только на backdrop command palette (`rgba(0,0,0,0.35) + blur(8px)`). Больше нигде.

### Углы (радиусы)

- 4 — чекбоксы, kbd-бейджи, skeleton bars, type-labels.
- 6 — кнопки, icon-buttons, nav-айтемы, menu-items, inputs.
- 8 — карточки, nav-айтемы (альт), search bar, dropdowns, marks.
- 12 — modals, command palette, sheets.
- 9999 — pill-badges, avatars.

Никаких «squircle» или декоративных углов. Прямые линии приветствуются — особенно в таблицах, где рамки важнее углов.

### Hover & press

- Hover: поднимаем фон на один шаг — `--bg-s` → `--bg-m`. Цветовой shift, не opacity-shift.
- На тексте — `--fg3` → `--fg2` → `--fg`.
- На бордюре — `--bd` → `--bd-h`.
- Press: чуть темнее, без scale-transform. Кнопка CTA на press уходит в `--cta-h` (в dark — чуть светлее, в light — темнее).
- Никаких bounce, spring, «squish». Интерфейс не заигрывает.

### Анимация

- Один easing: `cubic-bezier(0.16, 1, 0.3, 1)` — spring-like, плавный.
- 4 тайминга:
  - `60ms` fast — hover, dropdown-open, focus ring
  - `80ms` default — цвет, бордюр
  - `150ms` slow — modal, command palette
  - `250ms` layout — sidebar collapse, panel slide, grid reflow
- Skeletons — linear shimmer (единственное исключение из easing).
- Страничные переходы — без анимации (мгновенно).

### Слои поверхностей (правило плотности)

```
L0 page     — var(--bg)      — самый тёмный/светлый базовый
L1 sidebar  — var(--bg-s)    — +1 к контрасту
L2 card     — var(--bg-c)    — +2, поднят над страницей
L3 hover    — var(--bg-m)    — +3, активное состояние
```

**Инпуты всегда на уровень темнее карточки, в которой лежат.** Это инверсия привычного паттерна — но именно так выглядит Attio и Vercel.

### Фиксированные элементы

- Header 44px fixed top, Sidebar fixed left, Panel fixed right.
- Footer таблицы 40px — sticky bottom внутри Content.
- Command palette — центр, `position: fixed`.

### Прозрачность

- Почти нет. Полупрозрачные фоны — только `--blue-m` и аналоги для выделенных строк (`rgba(blue, 0.08)`) и backdrop command palette.
- Иконки статусов в activity feed — icon-circle с `color-mix(in srgb, <status> 10%, transparent)`. Единственное место, где используется `color-mix`.

---

## Iconography

**Основная библиотека:** `lucide-react` (npm), подключена через CDN как SVG в наших preview. Стандартный набор — `Search`, `ChevronRight`, `Plus`, `MoreHorizontal`, `Filter`, `Download`, `Mail`, `Phone`, `Calendar`, `MapPin`, `Users`, `Building2`, `Briefcase`, `LayoutDashboard`, `BarChart3`, `Settings`, `Bell`, `Check`, `X`, `Edit3`, `Star`, `PanelLeft`, `Sun`, `Moon`.

**Правила:**
- **Stroke 1.5** на большинстве размеров. 1.8 — для активного состояния в навигации (даёт +15% веса без смены иконки).
- **Размеры:** 11 (kbd-inline), 12 (dot-badge), 13 (ghost-button), 14 (CTA-button, sheet-close), 15 (icon-button default), 16 (nav, inputs), 28 (workspace logo), 48 (empty states).
- **Цвет:** `var(--fg3)` по умолчанию, `var(--fg2)` hover, `var(--fg)` активное. Иконки не окрашиваются в бренд.
- **Emoji** не используются. **Юникод-символы** — только `⌘`, `↑`, `↓`, `←`, `→` в keyboard-badges.
- **Звезда Turan** — отдельный SVG-asset (`assets/turan-star.svg`), не часть icon-набора. 8-лучевая, `--accent`. Единственное место, где появляется оранжевый.

**Реализация в китах:** иконки — это собственный inline-SVG набор в `primitives.jsx` (объект `ICON_PATHS` + компонент `<Icon name size stroke color />`), повторяющий геометрию lucide (stroke 1.5, viewBox 24) — без сетевых зависимостей. Нет нужной иконки — добавьте путь в `ICON_PATHS` (скопируйте `d` из `https://unpkg.com/lucide-static@latest/icons/<name>.svg`). Отдельно — `<TuranStar>` (звезда, `--accent`).

**Статусные «точки»:** плотный круг 5px, заполненный цветом статуса. Не иконка — геометрия.

**Почему lucide:** совпадает с shadcn/ui (наш стек), stroke 1.5 подходит под плотный UI Attio-стиля, покрытие всех агро- и админ-сценариев (tractor и farm icons в AgOS не нужны — имена сущностей делает типографика, не иконка).

---

## Далее

- **UI kits** — кликабельные прототипы с реальными компонентами:
  - `ui_kits/console/index.html` — **консоль эксперта** (реальный продукт): инвестпроекты + клиника, список ↔ карточка с KPI и графиками.
  - `ui_kits/farmer/index.html` — **кабинет фермера**: обзор + таблица стада с detail-панелью.
- **Агентская skill** — `SKILL.md`. Совместима с Claude Code Agent Skills.
- **Шрифты** — Geist / Geist Mono подключены через Google Fonts `@import` в `colors_and_type.css`. Для полностью автономной работы положите woff2 в `fonts/` и замените `@import` на `@font-face`.
