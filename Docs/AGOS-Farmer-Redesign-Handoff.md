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

### ✅ Phase 4 — Рынок (4a+4b+4c+4d+4e готовы, проверены скриншотами)

**Ключевое:** CSS модуля «Рынок» прототипа живёт в ДВУХ местах — база в `market-data.jsx` (`#turan-market-css`, 216 `.mk-*`) + полиш в `ds/turan-market-polish.css` (172 `.mk-*`, переопределяет базу). Оба портированы.

- **✅ 4a — фундамент (аддитивно):** новый `src/pages/cabinet/shell/market-proto.css` = база+полиш, рескоуп в `.agos-cabinet-stage` (скрипт `scratchpad/build_market_css.py`: `.sh-screen`/голые `.mk-*` → `.agos-cabinet-stage`, `@keyframes`/`@media` корректно; +keyframes `sh-fade`/`sh-sheet-up`). Импорт в `CabinetApp.tsx` ПОСЛЕ `shell-proto.css`. 15 market-иконок в `PhIcon`. 5 tone-токенов в `cabinet.css` (`--cta-h/--green-m/--red-m/--amber-m/--blue-m`).
- **✅ 4b — Market + List (проверено скриншотом):** таб «Рынок» (`MarketScreen`) → полный список «Мои партии»: `HomeHead` ask-бар + `.mk-tabs` + группы `.mk-grp` + ledger-карточки `.mk-card` + док-футер «Продать» (`IonShellFrame` получил `footer`/`footBare`; `.sh-foot` в shell-proto.css). Общий `components/BatchListCard.tsx` (`BatchCard`+`StatusChip`). `ListScreen` (p1list) реcкин теми же `.mk-*`. Gating (SellGate/ApprovedPlate/expired), лимит-5 (перенесён в `renderMarket.onNew`), пропсы/nav сохранены.
- **✅ 4c — BatchScreen (проверено b1/b2 скриншотами):** карточка партии по `market.jsx BatchDetail` — верт. трекер `.mk-trk` (focus+peek+expand, PATH_STAGES/stageIndex), `.mk-money` (ЦЕНА/СДЕЛКИ+lockchip), `.mk-buyer`, `.mk-acc` аккордеоны (Данные/История), `.mk-dec-blk` DecisionActions (`.mk-rec`+`.dec-row-actions.stack`), SplitPanel (`.mk-headsum`), kebab-меню вторичных действий (`.mk-kebab`+`ActionMenu` через общий `Sheet`/IonModal). Сохранены: onPatch-сигналы `_withdraw`/`_dispatchReady`, prot-price валидация (custom ≥ prot), deal-doc, 3 шторки, haptics. **Фикс:** `.dec-row-actions.stack` (вертикаль) не был портирован в Phase 3 из `turan-base.css` → добавлен в `shell-proto.css`. `.mk-topbar` (back+kebab) добавлен в `market-proto.css`. HeadsScreen — в приложении нет heads-роута → Поголовье-nav опущено.
- **✅ 4d — Wizard «Продать новую партию» (СЕССИЯ 3, проверено скриншотами всех 5 шагов + PubResult):** `tsp/wizard/{WizShell,WizStep1Animals..WizStep5Review,PubResult}` переверстаны под `.mk-*` + PhIcon. `BatchWizard.tsx` (оркестратор) **не тронут** — вся логика публикации уже там. **Новые mk-атомы** (`tsp/components/`): `MkCta` (`.mk-cta`), `MkField` (`.mk-field`+`.mk-lab`/`.mk-hint`), `MkErr` (`.mk-err`), `CheckRow` (`.mk-cb`), `MkSelect` (`.mk-seltrig`+нижний пикер `.mk-pick*`, порт `market-ui.jsx`, порог поиска 8). **Реверс существующих атомов** (используются только визардом): `WizProgress`→`.mk-wiz-prog`, `StepperCtl`→`.mk-stp`, `BigRadio`→`.mk-big-radio`, `InfoNote`→`.mk-infonote` (сигнатура `{title,children}`, tone убран). **WizShell** несёт `WizTop` (`.mk-wiz-bar`: back+`WizProgress`+exit) + `DraftNote` + рендерит `IonContent` (скролл `.phone-scroll`) + док-футер `.sh-foot` — **БЕЗ** вложенного IonPage (внешний `<IonPage className="agos-flow-page">` даёт `CabinetApp.renderMarket`, slide-up сохранён). `wizScrollTo` переписан под shadow-скроллер ion-content (`getScrollElement`+`scrollToPoint`). **Сохранено дословно (проверено в preview):** `rpc_create_batch`+`rpc_self_auto_match_batch`+`buildLocalBatch` fallback (публикация без бэка → variant B), `useBatchDraft`, `lowOk`/floor через `mpkSortFloor` (в preview показал 1650 ₸/кг для сорта «КРС·Высшая», не cat.prot 1400), `useGradeFormula`+`deriveCategory`/`deriveMpkGrade`+карточка сорта МПК (шаг 3, богаче прототипа — сохранена), дисклеймер ст.171 (`.mk-ref-d`), **регион = бейдж из профиля** (не пикер — осознанное отклонение от прототипа, `farmRegion`). `WizStep3` категория — мок-таймаут 1400мс. Иконки визарда: chevronLeft/x/check/chevronRight/minus/plus/search/pencil/checkCircle/send/clock/calendar. `tsc -b` = 0 ошибок; console-ошибки только ожидаемые `Failed to fetch` (placeholder-бэк).
- **✅ 4e — Review + Turan (тела, проверено скриншотами):** `ReviewScreen` — `.mk-h1`/`.mk-sub` + два `.mk-rev-q` (`.mk-rev-k`+`.mk-rev-sub`) с новым атомом `Stars` (`.mk-stars`/`.mk-star` + PhIcon `starOutline`) + `MkField` (textarea `.mk-input.area`) + экран благодарности `.mk-res` с `InfoNote` «перекрёстная оценка». `TuranScreen` — блок контактов (emoji 📞⏰ → PhIcon `phone`(добавлена в PhIcon)/`clock`) + тема через `MkSelect` + сообщение через `MkField`+`MkErr` + success `.mk-res`; footer `.sh-foot` (send+ghost). **Сохранено:** `ReviewScreen.onPatch({review:{r1,r2,comment}})` → `useBatches` → `rpc_submit_review` (форма-контракт не тронута); `TuranScreen` TOPICS/`prefillTopic`/`canSend`. Новый атом: `tsp/components/Stars.tsx`.

### ✅ Сессия 2 — доп. к Phase 4 (хедеры + фиксы, всё проверено скриншотами)
- **Система хедеров (3 уровня):** `HomeHead` (ask-бар — ТОЛЬКО Главная) · новый `TabHead` (универсальная шапка вкладок: заголовок + `AccountBtn`) на Рынок/Ферма/Сообщения · новый `SubHead` (порт прототипа: `‹ back-label` + опц. иконка/звезда/аватар + title/sub + right, sticky, сплошной фон) на Партия/Отзыв/TURAN (и готов для Диалога Phase 6). Аватар-монограмма «АД» → тонкая `PhIcon userThin` в общей `AccountBtn`. `backLabelFor(route.back)` в CabinetApp даёт нативную подпись «‹ Рынок»/«‹ Мои партии».
- **Артефакты перехода (устранены):** (1) убран `backdrop-filter: blur` у `.hh-row`; (2) ГЛАВНОЕ — `ion-content.agos-ion-content --background: transparent → var(--bg)` + `.ion-page { background: var(--bg) }` (ionic.css): прозрачные страницы давали bleed-through предыдущего экрана во время слайда. Теперь страницы непрозрачны.
- **Нативные анимации:** route→route уже нативны (`setupIonicReact({mode:'ios'})`, swipe-back); добавлен present-переход `.agos-flow-page` (slide-up+fade) для входа в Wizard/PubResult (не роут).
- **Аудит роутов/CTA:** дефект «Сервисы→Главная» исправлен (`services`→`/cabinet/services` placeholder). Остальные CTA/роуты — верны.
- **Иконки:** правило Phosphor-only (память `icons-phosphor-only`); «Торговать» → настоящий Phosphor `ArrowsLeftRight` **bold** (вес сервис-плиток). Новые: `userThin`, `arrowLeftRight`, +market-набор.
- **Мелочь:** decision-карточка Главной — CTA сокращены («Снизить цену»/«Варианты»); блок «РЕКОМЕНДУЕМ» на карточке партии сделан плоским (без подложки).
- **Новые компоненты:** `components/{AccountBtn,TabHead,SubHead,BatchListCard}.tsx`.

**Проверка в preview без бэкенда:** нет `.env` в свежем worktree → RequireAuth редиректит на /login. Обход: заинжектить фейковую сессию в localStorage (`sb-placeholder-auth-token`, непросроченный `expires_at`) + сид-партии в `agos.cabinet.batches.v1.<userId>`, reload → seed-fallback рендерит кабинет. Ошибки консоли `Failed to fetch`/`Failed to load user context` = ожидаемо (placeholder-бэкенд).

### ✅ Phase 6 — Сообщения + Консультант (ARS-231, проверено живым прогоном с реальным логином)

- **Модель:** `data/threads.ts` — порт `app/messages.jsx` (Фаза 03 прототипа): `MSG_META` (§16 семантика аватаров), `buildThreadList`/`buildThreadMsgs` (проекция событий модуля), `aiReply` (мок по справочным данным, антитраст). Хендлеры тредов = `decH` ярусов Главной («один объект — две поверхности»: decision решён из треда — погашен на Главной).
- **Экраны:** `MessagesScreen` (TabHead + `.thr-list`, mini-CTA решения в списке, футер «не в отдельный центр уведомлений»), `ThreadScreen` (Рынок/Ферма/TURAN: `.thr-head` sticky + pinned «ТРЕБУЕТ РЕШЕНИЯ» + `MsgBubble`), `ConsultantScreen` (AI-чат: пузыри, typing, мок голосового ввода-волны, док-инпут через `IonShellFrame footer footBare`). Новый атом `components/ThreadAv.tsx`.
- **CSS:** `messages-proto.css` (рескоуп `.agos-cabinet-stage`, импорт после market-proto). R-9 применён: времена «сегодня/утром» и день-разделители — sans (в прототипе были mono), mono остался только у цифровых бейджей.
- **Навигация:** тред TURAN — лента `/cabinet/thread/turan`; форма обращения — отдельный route `turan` (`/cabinet/turan`, TuranScreen сохранён HS-2, доступен из ленты «Написать в TURAN»; три onTuran-входа переведены на форму). `hideTabBar` + `'thread'`. Бейдж таба: + decision-партии (pinned не гаснет до решения).
- **Сохранено:** Pro-гейт Консультанта (`openAI` → progate), эффект гашения непрочитанных по входу в тред, TuranScreen целиком.
- **Реальный AI Gateway и чтение таблицы `notifications`** — отдельные задачи (мок aiReply / локальные notifs, см. IMPL_DEBT-кандидатов в спеке мозга farmer-messages).

## Осталось (следующие фазы)

Подход тот же: **портировать структуру прототипа + CSS, переиспользовать `PhIcon`/`.mk-*`/`.sh-*`, сохранить RPC/данные.**

- **Phase 3-остаток:** реcкин membership-шторок (`src/pages/cabinet/shell/components/sheets/*`) под светлую тему + дизайн Join/Pay прототипа (`public/agos/app/membership.jsx`).
- **Phase 4 — Рынок:** ✅ полностью закрыт (4a–4e). Следующее — Phase 5 (Ферма).
- **Phase 5 — Ферма:** `/cabinet/farm` (сейчас Placeholder) → построить по `farm.jsx` (Сегодня/Стадо/План/Цифры). Wire `rpc_get_farm_summary` + seed-fallback. Большой экран — можно подфазами.
- **Phase 6 — Сообщения + Консультант:** ✅ закрыт (ARS-231, см. выше). Остаток: реальный AI Gateway вместо мока aiReply + чтение таблицы `notifications` (RPC list/mark-read нет в Dok 3) — отдельные задачи.
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
