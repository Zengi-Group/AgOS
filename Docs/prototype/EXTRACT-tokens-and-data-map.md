# Извлечение из прототипа «Кабинет МПК v4»

> **Источник:** `Docs/prototype/Кабинет МПК v4.dc.html` (2280 строк, 188K)
> **Дата извлечения:** 2026-09-01
> **Статус:** рабочая выписка, НЕ канонический контракт. Канон = `AGOS-Dok6-Slice10-MPK-Profile.md`
> (не написан; пишется после подтверждения скоупа — см. §4 «Открытые вопросы»).
> **Эталонный вьюпорт спеки:** 1440×900, `theme=dark`, `contrast=max`, `uiScale=1`.

---

## 1. Токены дизайна

Прототип определяет **шесть** наборов через комбинацию `data-theme` × `data-contrast`.
Комментарий автора в файле: «Читаемость: тип-шкала и контраст усилены (осознанное
отклонение от DS)» — т.е. значения намеренно расходятся с базовой дизайн-системой.

### 1.1. Тип-шкала (общая для всех наборов)

| Токен | Значение |
|---|---|
| `--fs-2xs` | 11px |
| `--fs-xs` | 13px |
| `--fs-sm` | 13px |
| `--fs-base` | 15px |
| `--fs-md` | 16px |
| `--fs-lg` | 18px |
| `--fs-xl` | 24px |

Базовый размер body — 15px, `line-height: 1.55`.

### 1.2. Матрица наборов

| Селектор | Роль |
|---|---|
| `:root` | тёмная, по умолчанию |
| `:root[data-contrast="max"]` | тёмная, максимальный контраст ← **эталон спеки** |
| `:root[data-contrast="ds"]` | тёмная, контраст дизайн-системы |
| `:root[data-theme="light"]` | светлая, по умолчанию |
| `:root[data-theme="light"][data-contrast="max"]` | светлая, максимальный контраст |
| `:root[data-theme="light"][data-contrast="ds"]` | светлая, контраст DS |

### 1.3. Значения по наборам

**Тёмная / default**
```
--bg:#0c0b0a  --bg-s:#171614  --bg-c:#211f1e  --bg-m:#2f2c28
--fg:#f8f7f4  --fg2:#c2bbb1   --fg3:#918a83
--bd:#37332e  --bd-s:#2a2724  --bd-h:#4d4841
--cta:#f2efe9 --cta-fg:#12110f --cta-h:#ffffff
--blue:#82b4f0    --blue-m:rgba(130,180,240,0.13)
--green:#6ed189   --green-m:rgba(110,209,137,0.13)
--emerald:#5cd8ac --emerald-m:rgba(92,216,172,0.13)
--amber:#f5bd55   --amber-m:rgba(245,189,85,0.13)
--red:#f0796a     --red-m:rgba(240,121,106,0.13)
```

**Тёмная / max** (эталон приёмки)
```
--bg:#070706  --bg-s:#141312  --bg-c:#1f1e1c  --bg-m:#332f2b
--fg:#ffffff  --fg2:#d5cfc6   --fg3:#a8a19a
--bd:#423d37  --bd-s:#302c28  --bd-h:#5d574f
--cta:#fbf9f5 --cta-fg:#0b0a09 --cta-h:#ffffff
--blue:#9cc6f7    --blue-m:rgba(156,198,247,0.16)
--green:#86dc9c   --green-m:rgba(134,220,156,0.16)
--emerald:#74e5bd --emerald-m:rgba(116,229,189,0.16)
--amber:#ffd06a   --amber-m:rgba(255,208,106,0.16)
--red:#ff8f7e     --red-m:rgba(255,143,126,0.16)
```

**Тёмная / ds**
```
--bg:#0e0d0c  --bg-s:#161513  --bg-c:#1d1c1a  --bg-m:#252320
--fg:#ededea  --fg2:#a8a29a   --fg3:#706a63
--bd:#2a2825  --bd-s:#1f1d1b  --bd-h:#3a3732
--cta:#e6e2dc --cta-fg:#141312 --cta-h:#f0ebe2
--blue:#6b9fe0 --green:#5ec47a --emerald:#4ecba0 --amber:#f0b040 --red:#e06050
(модификаторы -m: alpha 0.08)
```

**Светлая / default**
```
--bg:#f5f1ea  --bg-s:#e9e3d7  --bg-c:#fffefb  --bg-m:#ded6c7
--fg:#241a11  --fg2:#4e463c   --fg3:#6f675b
--bd:#d7cfc0  --bd-s:#e6e0d4  --bd-h:#b6ab97
--cta:#2b1d13 --cta-fg:#fffefb --cta-h:#150d06
--blue:#35619f --green:#2c7442 --emerald:#1f7358 --amber:#8f5f06 --red:#b02f22
(модификаторы -m: alpha 0.09–0.10)
```

**Светлая / max**
```
--bg:#faf8f3  --bg-s:#e6dfd1  --bg-c:#ffffff  --bg-m:#d5ccbc
--fg:#14100b  --fg2:#3b342b   --fg3:#5b5449
--bd:#cbc2b0  --bd-s:#ddd6c8  --bd-h:#a19681
--cta:#1b120a --cta-fg:#ffffff --cta-h:#000000
--blue:#2a5390 --green:#1f6435 --emerald:#12654b --amber:#7a5004 --red:#97241a
(модификаторы -m: alpha 0.10–0.11)
```

**Светлая / ds** — ⚠️ важное совпадение
```
--bg:#f6f3ed  ← совпадает с фоном фермерского кабинета (см. IMPL_DEBT L5)
--bg-s:#ece7dd --bg-c:#fbfaf6 --bg-m:#e4ddd0
--fg:#3d2b1f  --fg2:#6b6359   --fg3:#9a9288
--bd:#e0d9cc  --bd-s:#ebe6dc  --bd-h:#c7beac
--cta:#3d2b1f --cta-fg:#fbfaf6 --cta-h:#2c1e14
--blue:#4571b8 --green:#3a8a52 --emerald:#2d8a6e --amber:#b37a10 --red:#c0392b
(модификаторы -m: alpha 0.07–0.08)
```

Светлый `ds`-набор намеренно приведён к daylight-палитре AgOS. Это снимает остроту
конфликта с `D-UI-FARMER-RULES-01` (канон требует daylight): тёмная тема — режим, а не
единственное состояние, переключатель есть в сайдбаре (`onThemeToggle`).

### 1.4. Используются, но НЕ определены в файле

Приходят из отсутствующего `_ds/…/colors_and_type.css`:

| Токен | Где используется |
|---|---|
| `--font-sans` | `font-family` корня, inputs/buttons |
| `--mono` | цифровые значения KPI (`font-variant-numeric: tabular-nums`) |
| `--ease` | `transition` на карточках и кнопках |

### 1.5. Анимации

```
fadeUp   : opacity 0→1, translateY(6px)→0
panelIn  : opacity 0→1, translateX(20px)→0
pulseDot : opacity 1→0.25→1  (индикатор ожидания)
```

---

## 2. Внешние зависимости — ✅ все на месте (2026-09-01)

Все 4 ссылки из прототипа резолвятся:

| Ссылка из прототипа | Размер | Статус |
|---|---|---|
| `./support.js` | 68K | ✅ |
| `agos-readable.js` | 368K | ✅ |
| `_ds/…/colors_and_type.css` | — | ✅ |
| `_ds/…/styles.css` | — | ✅ |

Экспорт принёс больше заявленного — в `_ds/agos-9d11d37b-242b-4955-a814-eac7bd2332de/`:

| Файл | Что даёт |
|---|---|
| `_ds_manifest.json` | **полный реестр токенов** со значениями, типами и скоупами + 39 карточек превью компонентов |
| `_ds_bundle.js` | сборка компонентов DS |
| `_adherence.oxlintrc.json` | правила линтинга приверженности DS (запрет импорта внутренностей компонентов — только через `index.js`) |
| `README.md` | контекст бренда и позиционирование |

Итого папка `Docs/prototype/` — 1.1 МБ.

**Не приехали** `preview/` и `ui_kits/` (упомянуты в манифесте) — но `preview/` уже
есть в репозитории: `Docs/design-system-v12/preview/` (39 файлов документации
компонентов). Потери нет.

### 2.1. Сверка токенов — совпадение точное

`:root[data-contrast="ds"]` прототипа **побайтово совпадает** с
`Docs/design-system-v12/colors_and_type.css`:

| Токен | Прототип (`ds`) | Файл репозитория |
|---|---|---|
| `--bg` | `#0e0d0c` | стр. 16 `#0e0d0c` |
| `--bg-s` | `#161513` | стр. 17 `#161513` |
| `--bg-c` | `#1d1c1a` | стр. 18 `#1d1c1a` |
| `--bg-m` | `#252320` | стр. 19 `#252320` |
| `--fg` | `#ededea` | стр. 22 `#ededea` |
| `--fg2` | `#a8a29a` | стр. 23 `#a8a29a` |
| `--fg3` | `#706a63` | стр. 24 `#706a63` |

Светлая тема тоже: прототип `[data-theme="light"][data-contrast="ds"]` → `--bg:#f6f3ed`,
файл стр. 127 → `--bg: #f6f3ed`.

**Вывод:** `_ds/` — это копия канонической дизайн-системы репозитория. Режим `ds` =
«как в DS», режимы `default`/`max` = осознанные усиления контраста поверх неё.

### 2.2. Три «неопределённых» токена — определены в репозитории

| Токен | Значение | Источники |
|---|---|---|
| `--font-sans` | `'Geist', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif` | `src/index.css:227`, `src/pages/cabinet/shell/cabinet.css:48`, `Docs/design-system-v12/colors_and_type.css:95` |
| `--mono` | `var(--font-mono)` → Geist Mono | `src/index.css:230`, `colors_and_type.css:98` |
| `--ease` | `cubic-bezier(0.16, 1, 0.3, 1)` | `src/index.css:284`, `cabinet.css:47`, `colors_and_type.css:51` |

Шрифты подключаются через Google Fonts (`colors_and_type.css:7`):
Geist 400/500/600/700 + Geist Mono 400/500.

### 2.3. Тип-шкала: прототип ≠ DS — ✅ РЕШЕНО (шкала прототипа)

Прототип переопределяет **все** размеры шрифта, увеличивая их на 1–4px. Это и есть
«осознанное отклонение от DS», о котором написано в комментарии файла.

| Токен | DS (`colors_and_type.css`) | Прототип (inline) | Δ | Реализуем |
|---|---|---|---|---|
| `--fs-2xs` | 10px | 11px | +1 | 11px |
| `--fs-xs` | 11px | 13px | +2 | 13px |
| `--fs-sm` | 12px | 13px | +1 | 13px |
| `--fs-base` | 13px | 15px | +2 | 15px |
| `--fs-md` | 14px | 16px | +2 | 16px |
| `--fs-lg` | 15px | 18px | +3 | 18px |
| `--fs-xl` | 20px | 24px | +4 | 24px |

**Решение (Dias, 2026-09-01):** следуем **шкале прототипа**. Обоснование —
пользователь МПК работает за настольным монитором в рабочем режиме, читаемость
приоритетнее плотности; шкала DS калибровалась под фермерскую мобилку.
Зеркало решения — `DECISIONS_LOG.md` (D-MPK-TYPE-01).

Область действия: **только** зона `/mpk/profile/*`. Переопределение обязано быть
scoped (см. §2.8), иначе увеличенная шкала протечёт в фермерский кабинет и
разъедется с `Docs/AGOS-DesignRules-FarmerCabinet.md`.

### 2.4. Токены DS, которых нет в inline-переопределении

Прототип наследует их из `colors_and_type.css` — при реализации использовать эти:

| Группа | Токены |
|---|---|
| Радиусы | `--r-sm` 4px · `--r-md` 6px · `--r-lg` 8px · `--r-xl` 12px · `--r-full` 9999px |
| Длительности | `--dur-fast` 60ms · `--dur-default` 80ms · `--dur-slow` 150ms · `--dur-layout` 250ms |
| Высоты контролов | `--h-xs` 24 · `--h-sm` 28 · `--h-md` 32 · `--h-lg` 36 · `--h-row` 48 · `--h-xl` 56 |
| Отступы (сетка 4px) | `--sp-05` 2 · `--sp-1` 4 · `--sp-15` 6 · `--sp-2` 8 · `--sp-25` 10 · `--sp-3` 12 · `--sp-4` 16 · `--sp-5` 20 · `--sp-6` 24 · `--sp-8` 32 · `--sp-12` 48 |
| Тени | `--sh-sm` · `--sh-md` · `--sh-lg` · `--sh-xl` (в светлой теме база тёплая, `rgba(61,43,31,…)`) |
| Веса | `--fw-regular` 400 · `--fw-medium` 500 · `--fw-semibold` 600 · `--fw-bold` 700 |
| Трекинг | `--ls-tighter` −0.02em · `--ls-tight` −0.01em · `--ls-normal` 0 · `--ls-wide` 0.04em · `--ls-wider` 0.06em |
| Шрифты | `--font-sans` Geist · `--font-mono` Geist Mono · `--font-display` Geist |

### 2.5. 🔶 Акцентный цвет — жёсткое ограничение

| Токен | Тёмная | Светлая |
|---|---|---|
| `--accent` | `#F0A020` | `#E8920B` |

Оранжевый Turan. Ограничение из `README.md` и манифеста: **«Один оранжевый акцент —
только на звезде»**, «Turan orange — star only, **≤5% of surface**». То есть акцент
НЕ используется для кнопок, ссылок или статусов — для них есть семантическая палитра
(`--blue`/`--green`/`--emerald`/`--amber`/`--red`).

### 2.6. Практический вывод

Всё необходимое для кода есть. `support.js` / `agos-readable.js` нужны только чтобы
открыть прототип в браузере и потыкать интерактивно — теперь это возможно.
Компоненты (`Sidebar`, `Button`, `Icon`) реализуем свои на React; `_ds_bundle.js`
и `preview/` — референс, не зависимость сборки.

### 2.7. Что НЕ в git и как восстановить

Четыре файла папки в `.gitignore` (решение 2026-09-01 — 24 345 строк = 82% объёма,
регенерируемо, плюс `P4` по токенам):

| Файл | Как вернуть |
|---|---|
| `support.js` | повторный экспорт проекта из Claude Design (не копирование одного артборда) |
| `agos-readable.js` | то же |
| `_ds/**/_ds_bundle.js` | то же |
| `_ds/**/colors_and_type.css` | скопировать `Docs/design-system-v12/colors_and_type.css` в путь `_ds/agos-9d11d37b-242b-4955-a814-eac7bd2332de/` (значения идентичны) |

Без них макет **не откроется корректно в браузере** (компоненты `Sidebar`/`Button`/`Icon`
приходят из `_ds_bundle.js`), но разработка не блокируется: все значения выписаны
в этом документе, а токены — в `_ds_manifest.json` (в git).

### 2.8. Изоляция темы — обязательное требование

Прототип задаёт токены на `:root`. При реализации так делать **нельзя**: тёмная
палитра и увеличенная тип-шкала протекут в фермерский кабинет и нарушат
`D-UI-FARMER-RULES-01` (daylight-канон).

Переопределение обязано быть привязано к контейнеру профиля МПК — по образцу
существующего `.agos-cabinet-stage` в `src/pages/cabinet/shell/shell-proto.css`.
Проверка при приёмке: открыть `/cabinet` рядом с `/mpk/profile` — фермерский кабинет
должен остаться светлым, размеры шрифтов неизменными.

---

## 3. Карта «экран → данные»

Оболочка: `display:flex` на всю высоту; слева `Sidebar` (`hint-size="272px,100%"`,
`flex-shrink:0`), справа `<main>`. Контент центрируется `max-width:1264px`,
паддинг `40px 44px 64px`.

### 3.1. Сайдбар

```
orgName   : "МК «Семей Ет»"
farmName  : "Turan Standard Pool · закупки"
userName  : "Дамир Оспанов"
role      : "Снабженец"
state     : "expanded"
theme     : dark | light  (+ onThemeToggle)
```

| Группа | id | Иконка | Подпись | Счётчик |
|---|---|---|---|---|
| primary | `dashboard` | dashboard | Главная | — |
| primary | `requests` | fileText | Мои заявки | кол-во заявок |
| primary | `offers` | mail | Входящие офферы | кол-во pending, тон `amber` |
| primary | `market` | barChart | Маркет-борд | — |
| secondary | `profile` | building | Профиль МПК | — |
| secondary | `docs` | folder | Документы сделок | — |

Экран `monitor` подсвечивает `requests` (вложенный маршрут).

### 3.2. Семь экранов

| `data-screen-label` | Флаг | Ключевые привязки |
|---|---|---|
| Главная | `s_dash` | `greet`, `acts`/`actsEmpty`, `dActive`, 3 KPI-карточки: `kpi_fill_*`, `kpi_off_*`, `kpi_ship_*`; `dec_on` |
| Мои заявки | `s_reqs` | `reqCount`, `viewTabs` (5 фильтров), `reqRows`, `reqFoot` |
| Мониторинг заявки | `s_mon` | `chrome` (parent/back/prev/next/current/total), `tabs` (Обзор/Поставщики/События), `m`, баннеры `mb_decision`/`mb_ok`/`mb_closedNote` |
| Входящие офферы | `s_offers` | `offers[]`, `offersPending` |
| Маркет-борд | `s_market` | `b.*` — карточка партии (см. 3.4) |
| Профиль МПК | `s_profile` | `ptabs` — 6 подразделов (см. 3.5) |
| Документы сделок | `s_docs` | `d.*` — документ (см. 3.4) |

**KPI главной:**
- `kpi_fill_n` / `_d` / `_pct` / `_c` — набор голов, прогресс-бар `--blue`
- `kpi_off_n` / `_d` / `_c` / `_urgent` — офферы, дедлайн («через 3:05»)
- `kpi_ship_n` / `_d` / `_c` — отгрузка

**Фильтры «Мои заявки»:** `all` Все · `active` Набираются · `decision` Требуют решения ·
`shipping` Отгрузка · `closed` Закрытые — каждый со счётчиком `cnt(id)`.

**Действия мониторинга:** `acceptShortfall` (принять недобор), `askReturn` (вернуть
поставщикам), `askCancel` (отменить заявку), `makeDoc` (документ сделки), `sendAppeal`
(обращение в TURAN — при отмене подтверждённой сделки).

### 3.3. Модальные окна и оверлеи

| Префикс | Что | Поля |
|---|---|---|
| `cm_*` | Создание заявки | `f_head`, `f_deadline`, `f_obl`, `f_ray`, `fl` (строки), `addLine`, `fv`/`fvNot`, `f_msg`, `publish` |
| `cf_*` | Подтверждение | `cf_title`, `cf_body`, `cf_label`, `cf_yes`, `cf_no` |
| `iv_*` | Приглашение сотрудника | `iv_email`, `iv_role`, `iv_scope` (из `SCOPES[role]`), `iv_ok`/`iv_bad`, `iv_msg` |
| `ap_*` | Обращение в TURAN | `ap_topic`, `ap_msg`, `ap_hint`, `ap_ok`/`ap_bad`, `ap_waitTxt` |
| `rt_*` | Оценка поставщика | `rt_overall`, `rt_spec` (звёзды), `rt_comment`, `rt_sub`, `rt_ok`/`rt_bad` |
| `p_*` | Боковая панель | `p_open`, `p`, `closePanel` (анимация `panelIn`) |
| `t_*` | Тост | `t_on`, `t_msg` |

Форма создания заявки: голов + дедлайн + область + район + строки
(`sort`, `price`, `limit`, `breed`) — совпадает с контейнерной моделью `D-M6-13`
(общий тотал + категорийные строки).

### 3.4. Повторяющиеся сущности

**`b.*` — партия (маркет-борд / поставщик):**
`pid`, `farm`, `region`, `regionFull`, `addr`, `phone`, `telHref`, `gisUrl`, `heads`,
`weight`, `price`, `rating`, `sortName`, `srcDate`, `stLabel`, `stTone`, `canReceive`,
`receive`, `noAction`, `openP`

⚠️ `farm`, `phone`, `addr`, `gisUrl` — данные, раскрываемые **только после `confirmed`**
(`D-M6-5`/`D-M6-12`, ст. 171). В прототипе это отражено флагом `pvPost` (см. 3.5 «org»).

**`d.*` — документ:**
`kind`, `name`, `file`, `label`, `st`, `tone`, `dl`, `left`, `untilLabel`, `bar`, `v`, `w`

**`a.*` — обращение:**
`topic`, `msg`, `date`, `answer`, `aDate`, `hasAnswer`, `waiting`, `stLabel`, `tone`, `dot`

### 3.5. Профиль МПК — шесть подразделов

Совпадает с `EngSpec §1` один в один.

| `ptabs.id` | Подпись | Иконка | Счётчик |
|---|---|---|---|
| `overview` | Обзор | dashboard | — |
| `org` | Предприятие | building | кол-во правок на проверке |
| `adm` | Допуск | shield | — |
| `team` | Команда | users | кол-во сотрудников |
| `rep` | Репутация | star | — |
| `appeals` | Обращения | messageCircle | кол-во открытых |

Шапка профиля: `pr_name`, `pr_email`, `pr_me`, `pr_mono` (монограмма «СЕ»),
`pr_sub` = «БИН … · юр.адрес · допуск TURAN с …».

**overview** — `ov_title` («Допущен к закупкам»), `ov_sub`, `ov_checked`
(«обновлено сегодня, 09:14»), `ov_gates` (гейты допуска), `ov_todo`/`ov_todoN`/`ov_clean`
(«Требует внимания» / «Ничего не требует действий»), `ov_facts`, `goRep`.

**org (Предприятие)** — `pr_cards` (карточки реквизитов), `pr_pend`/`pr_pendTxt`
(правки на проверке). Плюс **превью карточки, которую видит фермер**:
`pv_tabs`, `pv_rows`, `pv_title`, `pv_sub`, `pv_mono`, `pv_foot`, `pv_note`.
Переключается флагом `pvPost` (до/после подтверждения сделки) — прямая проекция
правила анонимности: до `confirmed` фермер видит «Мясокомбинат · обл. Абай», после —
название, телефон, адрес. Поля с «глазом» уходят фермеру, остальные остаются внутри.

**adm (Допуск)** — верификация: `v_tone`, `v_label`, `v_steps`.
Членство: `mem_tone`, `mem_label`, `mem_left`, `mem_w`, `mem_bar`, `mem_rows`
(ассоциация / номер / взнос), `mem_canRenew`, `mem_renewing`, `renewMem`.
Документы: `pr_docs`, `docN`, `uploadDoc`.

**team (Команда)** — `st_sub` («N в кабинете · M ждёт входа»), `pr_staff`,
модалка приглашения `iv_*`, роли через `SCOPES`.

**rep (Репутация)** — `pr_rating` («4.7»), `pr_ratingN` («18 оценок · 12 хозяйств»),
`pr_dims` (общая + «Приёмка и расчёт по договорённости»), `pr_dist` (5→1 звёзд),
`pr_reviews`, `pr_hidden`/`pr_hiddenFarm` (двойная слепота до взаимного раскрытия).

**appeals (Обращения)** — `pr_appeals`, `ap_sub`, `ap_waitTxt`.

---

## 4. Сопоставление с RPC (существует / нет)

Все перечисленные ниже RPC проверены: присутствуют в SQL и задеплоены
(`prod_diff.py` 2026-09-01 — дрейф 0).

| Подраздел | RPC | Тикет | Статус |
|---|---|---|---|
| adm · верификация + членство | `rpc_get_org_membership_verification` | ARS-361 | ✅ есть |
| org · реквизиты | `rpc_upsert_mpk_profile`, `rpc_update_mpk_org_details` | ARS-359 | ✅ есть |
| org · площадка | `rpc_save_mpk_primary_site` | ARS-359 | ✅ есть |
| org · банк | `rpc_append_org_bank_account` | ARS-359 | ✅ есть |
| org · правки на проверке | `rpc_propose_org_field_change`, `rpc_review_org_field_change` | ARS-359 | ✅ есть |
| adm · документы | `rpc_create_org_document_upload_intent`, `rpc_finalize_org_document_upload`, `rpc_abandon_org_document_upload` | ARS-355 | ✅ есть |
| rep · репутация | `rpc_get_mpk_reputation` | ARS-360 | ✅ есть |
| team · RBAC + приглашения | (RBAC поверх `user_organization_roles`) | ARS-356 | ✅ есть |
| **overview · агрегат** | `MP-2.1` — read RPC overview | **ARS-362** | ❌ Backlog |
| **appeals · модель + RPC** | `MP-1.6` + `MP-2.6` | **ARS-357**, **ARS-364** | ❌ Backlog |
| adm · admission RPC | `MP-2.3` | **ARS-363** | ❌ Backlog |
| — · RLS/grants/тесты | `MP-1.7` | **ARS-358** | ❌ Backlog |

**Итог:** 4 из 6 подразделов имеют полное задеплоенное покрытие
(`org`, `adm` частично, `team`, `rep`). Две дыры: **Обращения** (нет ни модели, ни RPC)
и **агрегат Обзора**. Плюс открытый гейт `ARS-358` (RLS/grants) — спека требует закрыть
его до отгрузки поверхности репутации.

---

## 5. Открытые вопросы (блокируют написание Slice10)

1. **Скоуп.** Прототип — весь десктопный кабинет (7 экранов). `ARS-351` описывает только
   «Профиль МПК» (1 из 7) как аддитивный раздел `/mpk/profile/:tab`. Строим профиль по
   эпику или весь кабинет по макету (тогда эпик + спека расширяются)?
2. **Судьба мобильного шелла.** 5 из 7 экранов макета дублируют то, что уже работает в
   `/mpk` на мобилке. Остаётся, выводится, или сосуществует?
3. **Отсутствующие зависимости** (§2) — нужны `_ds/` + 2 `.js`, иначе визуальную приёмку
   не пройти (требование `EngSpec §0`).
4. **Тема.** Тёмная по умолчанию против daylight-канона `D-UI-FARMER-RULES-01`.
   Светлый `ds`-набор совпадает с фоном фермерского кабинета — фиксируем как
   изолированное исключение (`D-MPK-THEME-02`) или ведущей делаем светлую?
