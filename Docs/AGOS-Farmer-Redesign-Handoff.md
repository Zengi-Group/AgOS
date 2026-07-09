# AGOS — Редизайн фермерского приложения по прототипу · HANDOFF

> Рабочий хендофф для продолжения в новой чат-сессии. Ветка: `claude/farmer-app-redesign-d9bedf`.
> Дата фиксации: 2026-07-09.

## Цель

Полностью воспроизвести дизайн визуального прототипа **`Zengi-Group/agos-farmer`** (Lovable) в основном приложении AgOS: цвета, компоненты, иконки, структура, статичный контент. Охват — весь фермерский кабинет + вход/регистрация/membership.

## Источник дизайна (прототип)

Репозиторий: `https://github.com/Zengi-Group/agos-farmer.git` (в новой сессии — **склонировать заново** в scratchpad; прошлый клон эфемерен).

- **Вход-фаннел (React, светлая «бумага»):** `src/routes/{index,register,login,membership}.tsx`, `src/lib/auth-ui/tokens.ts`, `src/components/{PhonePicker,SelectSheet}.tsx`, `src/data/kz-regions.ts`.
- **Кабинет (статический iframe React-18):** `public/agos/app/{shell,home,membership,messages,services,market,market-ui,market-data,market-wizard,farm}.jsx`, `public/agos/ds/turan-tokens.css`.
- Прототип показан в **тёмной** теме, но DS содержит и светлую (`[data-theme="light"]`, «daylight»).

## Ключевой принцип (усвоенный урок)

**Портируем СТРУКТУРУ прототипа (разметку + CSS + иконки), а не ре-темизируем старый код.** Текущий кабинет был ранним, разошедшимся портом (5 табов, стикер в хедере, icon-баннеры, lucide-иконки). Ошибка первого захода по Home — просто перекрасил старую структуру; правильно — переписать под структуру прототипа. Дальше так со всеми экранами.

Инварианты (сохраняем всегда): все `supabase.rpc(...)`, навигация (Ionic v5-island, `nav.ts`), 5 ролей регистрации, membership-FSM, offline/seed-fallback, MPK. Меняем презентацию — не логику.

## Зафиксированные решения

1. **Только СВЕТЛАЯ тема кабинета** (решение 2026-07-09). Тёмная «night» + переключатель тем — отложены (обе палитры есть в `turan-tokens.css`). Кабинет = светлая «daylight» (`#f6f3ed`/`#fbfaf6`/`#3d2b1f`, акцент `#E8920B`, Geist).
2. **Все 5 ролей** регистрации сохранены (farmer/mpk/services/feed_producer/expert) — не редуцируем до 2 как в прототипе.
3. **Membership** = отдельный светлый экран `/membership` (добавлен) + существующие in-cabinet шторки (реcкин отложен в Phase 3-остаток).
4. **Welcome** = стартовый экран native-приложения (веб-лендинг на `/` не трогаем).
5. **Иконки** — `@phosphor-icons/react` (установлен) + inline `PhIcon` (пути 1:1 из прототипа).

## Прогресс

### ✅ Phase 0 — Фундамент
- Geist уже был загружен (`src/index.css:1`). Ассеты `turan-logo.png` + `banner-*.jpg` → `src/assets/turan/`.
- `@phosphor-icons/react@2.1.10` установлен (peer-tree чист, D-DEP-BUMP-01 ✓).
- `src/lib/auth-ui/tokens.ts` — светлые «paper» токены (порт `T`), scoped (глобальный `:root` не тронут).

### ✅ Phase 1 — Вход-фаннел (светлая «paper»)
- `src/lib/auth-ui/primitives.tsx` — общие примитивы (AuthShell, AuthBody, TopBar[hideBack], H1, Lede, StickyDock, CTA, Field, inputStyle, PinCells, Chevron, Check).
- **Login** (`src/pages/auth/Login.tsx`) — реcкин, `signInWithPassword`/`loadMyContext`/`pickShellPath`/`/forgot-pin` сохранены.
- **Register** — оркестратор (`src/pages/registration/Registration.tsx`) → AuthShell+прогресс-TopBar; ВСЕ шаги переверстаны (Contact, CreatePin, RoleSelect[5 ролей], BenefitScreen, Farmer/Mpk/Services/FeedProducer/ExpertDetails, ExpertDocs, Agreement, Success). Shared: PinInput, OtpInput, FloatingInput, BottomSheet, ChipSelect, `.reg-btn-primary` → paper. Логика (`bird-otp`, `rpc_register_organization`, sessionStorage) сохранена. `PhoneInput` осиротел (не трогаем).
- **Welcome** (`src/pages/auth/Welcome.tsx`, тёмный) + `/welcome` + `NativeEntry`-гейт в `src/App.tsx` (native unauth→Welcome, authed→/cabinet).

### ✅ Phase 2 — Membership
- `src/pages/membership/Membership.tsx` — светлый экран заявки (intro→docs→submitting→pending, Phosphor duotone, таймлайн). Реальная загрузка в Storage `membership-documents/{orgId}/docs/{slot}_{ts}` + `rpc_submit_membership_application` (паттерн из `MembDocsSheet`). Маршрут `/membership` в `App.tsx`. Success(farmer) → CTA «Подать заявку на членство».
- **Осталось:** реcкин тёмных in-cabinet шторок (`MembGateSheet/MembDocsSheet/PayVznosSheet/ProGateSheet/PayProSheet`) — теперь под СВЕТЛУЮ тему (перенесено в остаток Phase 3, т.к. они в кабинете).

### ✅ Phase 3 — Пере-темизация кабинета (light) + Home (ПЕРЕПИСАН по прототипу)
- **Токены кабинета:** `cabinet.css` `.agos-cabinet-stage` пере-базирован на DS daylight + Geist + легаси-алиасы (`--ink/--line/--card/--primary`→DS). `ionic.css`: `--ion-font-family`→Geist (**фикс:** Ionic перебивал шрифт внутри `ion-content`), `--ion-color-primary`→`#E8920B`. Кнопки: `font-family:inherit`.
- **Иконки:** `src/pages/cabinet/shell/components/icons/PhIcon.tsx` (Phosphor-пути 1:1 из `shell.jsx`), `TuranStar.tsx` (лого).
- **CSS прототипа:** `src/pages/cabinet/shell/shell-proto.css` — порт `home.jsx`+`shell.jsx` CSS (скоуп `.agos-cabinet-stage`), импорт **после** cabinet.css/ionic.css в `CabinetApp.tsx` → переопределяет старые правила.
- **Home переписан:** HomeHead (ask-бар TuranStar+Спросить+mic, аватар, **без стикера**), HomeBanner (полноширинные image-плитки `banner-*.jpg` + точки, membership-реактивная 1-я), ServiceGrid (4: Торговать/Магазин/Цены/Сервисы, Phosphor 28), TierHead (лейбл 18px + пилюля), DecisionCard (dec-row), ObserveCard (sh-row), HomeScreen (home-stack/blk/home-div/work-farm). Данные/RPC/props сохранены — `CabinetApp` не тронут.
- **Таб-бар → 4 таба** (Главная/Ферма/Рынок/Сообщения, Phosphor, амбер-актив, `.agos-tabbar` в стиле `.sh-tabbar`). «Магазин» теперь через грид, не таб. `ShellTabBarIon.tsx`.
- Проверено скриншотом на `/cabinet` — совпадает с прототипом.

## Осталось (следующие фазы)

Подход тот же: **портировать структуру прототипа + CSS в `shell-proto.css`, переиспользовать `PhIcon`/`Row`/`sh-*`, сохранить RPC/данные.**

- **Phase 3-остаток:** реcкин membership-шторок (`src/pages/cabinet/shell/components/sheets/*`) под светлую тему + дизайн Join/Pay прототипа (`public/agos/app/membership.jsx`).
- **Phase 4 — Рынок:** `screens/{MarketScreen,ListScreen,BatchScreen,ReviewScreen}` + `tsp/wizard/*` → под `.mk-*` прототипа (`market*.jsx`). Сохранить `rpc_create_batch`, `rpc_self_auto_match_batch`, `useBatches`, gating, лимит 5, дисклеймер цен (Article 171).
- **Phase 5 — Ферма:** `/cabinet/farm` (сейчас Placeholder) → построить по `farm.jsx` (Сегодня/Стадо/План/Цифры). Wire `rpc_get_farm_summary` + seed-fallback. Большой экран — можно подфазами.
- **Phase 6 — Сообщения + Консультант:** `/cabinet/messages`, `/thread/:tid` (Placeholder) → 4 треда + AI-чат по `messages.jsx`. Дисклеймер цен в треде TURAN. P-AI для реального AI.
- **Phase 7 — Сервисы/Магазин/Кабинет:** реcкин `CabinetScreen`, построить Shop (`/cabinet/shop`), сетку Сервисов по `services.jsx`. Переключатель тем — ОТЛОЖЕН (только светлая).
- **Phase 8 — MPK-шелл:** проверить/подправить `mpk/*` (наследует cabinet.css). Обновить apex-brain.

## Как возобновить / проверить

1. Прочитать этот файл + `CLAUDE.md` + этот раздел `DECISIONS_LOG.md`.
2. Склонировать прототип заново (`git clone https://github.com/Zengi-Group/agos-farmer.git` в scratchpad) — источник дизайна.
3. Dev-сервер: `npm run dev` (порт 5173) или preview `Frontend (Vite)`. Проверять: `/welcome`, `/register`, `/login`, `/membership`, `/cabinet`.
4. Кабинет **доступен в preview** без бэкенда (seed-fallback) — можно смотреть визуально.
5. `npx tsc -b --noEmit` — типы. SQL не трогаем → `cross_check.sh` не нужен.

## Гочи (усвоено)

- **Ionic перебивает шрифт:** внутри `ion-content` шрифт берётся из `--ion-font-family`, а не наследуется — задан Geist в `ionic.css`.
- **Кнопки не наследуют `font-family`** — добавлено `.agos-cabinet-stage button/input/… { font-family: inherit }`.
- **Стейл-ошибки в консоли preview:** старые HMR-версии `<Registration>` с разными `?t=` — не текущие, чистятся после reload.
- **Прототип в scratchpad эфемерен** — реклонировать в новой сессии.
- **`shell-proto.css` грузится последним** — так переопределяет старые `cabinet.css` правила без их удаления (additive).

## Ключевые новые/изменённые файлы

Новые: `src/lib/auth-ui/{tokens.ts,primitives.tsx}`, `src/pages/auth/Welcome.tsx`, `src/pages/membership/Membership.tsx`, `src/pages/cabinet/shell/shell-proto.css`, `src/pages/cabinet/shell/components/icons/{PhIcon,TuranStar}.tsx`, `src/assets/turan/*`.
Изменены: `src/App.tsx`, `src/index.css`, `src/pages/auth/Login.tsx`, `src/pages/registration/**`, `src/pages/cabinet/shell/{cabinet.css,ionic.css,CabinetApp.tsx}`, `src/pages/cabinet/shell/components/{HomeHead,HomeBanner,ServiceGrid,TierHead,DecisionCard,ObserveCard,ShellTabBarIon}.tsx`, `src/pages/cabinet/shell/screens/HomeScreen.tsx`.
