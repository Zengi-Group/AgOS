# Eng-Spec — Нативное приложение фермера (Capacitor + Ionic)

> In-repo engineering spec (detailed intent). Тонкая синтеза — в Brain
> (`apex-brain/projects/agos/specs/native-farmer-app.md`) и ссылается сюда через `sources:`.
> Graphify индексирует этот файл — держи имена сущностей/файлов совпадающими с кодом.

- **Brain synthesis:** [[projects/agos/specs/native-farmer-app]]
- **Linear epic:** ARS-110 (миграция флоу на нативный фронт) · ARS-109 (UI-кит)
- **Партнёрский трек (Ернур):** ARS-135 (A/B/C серия) — общий Host Bridge контракт + push-инфра
- **Canon owner:** shell = ADR-CABINET-SHELL-01 · data = D-TSP-CANON-01 · push = C-серия (ARS-139..145)
- **Status:** draft
- **Аддитивность:** HS-1 / HS-5 — новый platform-adapter + Host Bridge слои; контент экранов и data-хуки НЕ трогаем.

---

## 1. Обзор + карта

### Что упаковываем
Существующий React-shell фермера (`src/pages/cabinet/shell/`, 85 файлов, ~14K строк) и МПК (`src/pages/cabinet/shell/mpk/`) выходят как **iOS / Android приложение И web mobile из одной кодовой базы**. Стек: **Capacitor** (нативная обёртка WebView + плагины) + **Ionic React** (нативное ощущение: переходы push/pop, edge-swipe-назад, pull-to-refresh, safe-area, нативные пикеры). RN отклонён (CEO 2026-07-03: второсортный web-таргет ломает требование «нативно и в вебе»).

### Три поверхности, один билд
| Поверхность | Хост | Транспорт | Auth-хранилище | Push |
|---|---|---|---|---|
| **web mobile** | браузер (Vercel) | — | localStorage | Web Push (опц.) / нет |
| **iOS / Android (наш)** | Capacitor WebView | нативные плагины | Capacitor Preferences (secure) | FCM / APNs через Capacitor |
| **партнёрский WebView (Ернур)** | внешнее нативное приложение | `postMessage` мост (ARS-133) | сессия инжектится хостом (ARS-134) | нативный токен хоста → C-серия (ARS-140) |

Единый Vite-билд с рантайм-детектом хоста (см. §2). Нативный бандл использует **app-target флаг** (§8): грузит только `/cabinet` + `/mpk`, без публичного сайта и админки (Apple 4.2 — фокус на функции фермера).

### Ключевая карта кода (из graphify)
- **Роутинг-корни:** `src/App.tsx` (react-router, `/cabinet/*` → `CabinetApp`, `/mpk/*` → `MpkApp`, под `RequireAuth`).
- **Фермер:** `CabinetApp.tsx` (L78) — собственный `Route` state-machine (`useState<Route>`, `go(r)`), 8 экранов в `screens/`, 10 шторок в `components/sheets/`, `ShellTabBar.tsx`, `Sheet.tsx` (backdrop-шторка), `context.tsx` (`ShellCtx`).
- **МПК:** `mpk/MpkApp.tsx` (L43) — свой `MpkRoute` state-machine (home/tsp/offers), 3 экрана, 4 модала, 1 шторка.
- **Типы навигации:** `shell/types.ts` — `Route`, `RouteName`, `SheetState`, `SheetKind`, `ShellState`, `ShellContextValue`.
- **Auth:** `contexts/AuthContext` + `hooks/useAuth.ts` (`signOut`, `session`, `userContext`); телефон+PIN через `signInWithPassword` (edge bird-otp). Без OAuth-редиректов.
- **Supabase:** `src/lib/supabase.ts` — `createClient`, env через `import.meta.env.VITE_*`.
- **Data:** `shell/data/*` + `shell/hooks/useBatches.ts`; 17+ RPC self-serve (`rpc_self_*`), поллинг 20–30с (`setInterval`).
- **File upload:** `sheets/MembDocsSheet.tsx` — `input type=file` → `supabase.storage.from('membership-documents')`.
- **Offline:** заглушка — `const [offline] = useState(false)` в `CabinetApp.tsx` (L103).
- **PWA:** нет `public/manifest*`, нет service worker.

---

## 2. Host Bridge — единый анти-дивергентный контракт

**Проблема, которую решаем.** Два трека идут параллельно: наш Capacitor и партнёрская WebView-интеграция Ернура (ARS-135). Если ядро зовёт платформенные API напрямую — код форкается на два несовместимых пути. Решение: **ядро AgOS зовёт ТОЛЬКО host-agnostic интерфейс `AgOSHost`**, реализаций — три.

**Явное следствие для ARS-133 (A4):** задачу «postMessage-мост» следует **расширить из транспорта в транспорт-агностичный Host Bridge контракт**. `WebViewHost` — реализация моста поверх `postMessage`; наш `CapacitorHost` — вторая реализация того же контракта. Один интерфейс, две (три) обвязки.

### 2.1 Интерфейс (новый файл `src/platform/host/AgOSHost.ts`)
```ts
export interface AgOSHost {
  kind: 'web' | 'webview' | 'capacitor'
  // Сессия: web читает из supabase-js persistSession; webview принимает инъекцию хоста (ARS-134);
  // capacitor восстанавливает из secure Preferences.
  bootstrapSession(): Promise<{ access_token: string; refresh_token: string } | null>
  signOut(): Promise<void>
  // Push: возвращает нативный device-token (или null для web без web-push).
  registerPushToken(): Promise<string | null>
  onPushToken(handler: (token: string) => void): void
  // Deep-link: и cold-start, и в рантайме. Отдаёт path вида '/cabinet/batch/:id'.
  onDeepLink(handler: (path: string) => void): void
  // Capability-gated (могут быть no-op):
  readonly caps: { haptics: boolean; camera: boolean; secureStorage: boolean; statusBar: boolean }
  haptics(style: 'light' | 'medium' | 'heavy'): void
  pickImage(opts?: { source?: 'camera' | 'library' }): Promise<Blob | null>
}
```
Ядро (`AuthContext`, `supabase.ts`-bootstrap, shell-навигация, push-регистрация, `MembDocsSheet` upload) обращается к `useHost()` (React-контекст), **никогда** к `@capacitor/*` или `window.parent.postMessage` напрямую.

### 2.2 Три реализации (`src/platform/host/`)
- `WebHost.ts` — браузер. `bootstrapSession` = no-op (supabase-js сам читает localStorage). push = Web Push или null. `pickImage` = `<input type=file capture>`. haptics = no-op.
- `CapacitorHost.ts` — `@capacitor/preferences`, `@capacitor/push-notifications`, `@capacitor/app` (deep-link `appUrlOpen`), `@capacitor/camera`, `@capacitor/haptics`, `@capacitor/status-bar`.
- `WebViewHost.ts` — `postMessage`-мост (ARS-133). `bootstrapSession` ждёт инъекцию сессии от хоста (ARS-134). `registerPushToken` запрашивает токен у хоста (ARS-140). `onDeepLink` слушает сообщения хоста (ARS-144). Реализует ТОТ ЖЕ интерфейс.

Детект (`src/platform/host/detect.ts`): `Capacitor.isNativePlatform()` → capacitor; наличие моста (`window.AgOSNativeBridge` / `ReactNativeWebView`) → webview; иначе → web.

### 2.3 Таблица «метод × реализация»
| Метод | WebHost | CapacitorHost | WebViewHost (Ернур) |
|---|---|---|---|
| `bootstrapSession()` | no-op (localStorage) | secure Preferences → setSession | инъекция хоста (ARS-134) |
| `signOut()` | supabase.signOut | + очистка Preferences | postMessage хосту + supabase.signOut |
| `registerPushToken()` | Web Push / null | FCM/APNs токен | запрос у хоста (ARS-140) |
| `onDeepLink(h)` | `popstate` / URL | `App.appUrlOpen` | postMessage (ARS-144) |
| `haptics()` | no-op | `@capacitor/haptics` | postMessage (опц.) |
| `pickImage()` | `<input file>` | `@capacitor/camera` | postMessage / `<input>` fallback |
| `caps.secureStorage` | false | true | зависит от хоста |

**Общий бэкенд (не дублировать):** C-серия (ARS-139 `push_token` модель, ARS-141 edge-отправка FCM/APNs, ARS-142 канал в Notification Worker per Dok4) — один бэкенд для всех трёх хостов. Хосты отличаются только тем, ОТКУДА берётся токен; путь токен → БД → отправка общий.

---

## 3. Роутинг-миграция shell → Ionic

### ⚠️ Проверено спайком (2026-07-03, ADR-NATIVE-ROUTER-01 AMEND-1) — движок нативного стека живёт в @ionic/react-router (v5), НЕ в ядре
Эмпирический спайк (браузер, приложение на react-router v6, `@ionic/react@8`+`@ionic/core@8`,
БЕЗ `@ionic/react-router`): standalone `<IonRouterOutlet>`, которому скормили v6 `<Routes>`,
рендерит НОЛЬ детей — белый экран. Исходники подтверждают: `@ionic/react-router@8.8.13`
(`dist/index.js`) содержит `StackManager`/`ReactRouterViewStack` — движок стека страниц и
переходов — и его НЕТ в ядре `@ionic/react`. Пакет статически импортирует v5-only API
(`withRouter`, v5 `matchPath`), поэтому на v6 не работает в принципе. Ionic v6-роутер
не планируется (#24177 открыт с 2021, #28558 closed-not-planned).
Вывод: нативные URL-переходы push/pop + edge-swipe возможны ТОЛЬКО через `@ionic/react-router`,
а он требует react-router v5. Всё приложение — на v6.

### Решение: вариант A — изолированный v5-остров под `/cabinet/*` и `/mpk/*` (за спайк-гейтом)
`@ionic/react-router` монтируем на изолированном поддереве react-router **v5** для оболочек;
остальное приложение остаётся на v6. v5-импорты пакета — статические ESM bare-спецификаторы,
поэтому Vite `resolve.alias`/resolver-plugin (+ пакет `history`) перенаправляет их на этапе
сборки — вероятно БЕЗ patch-package. `go(r)` становится обёрткой над `useIonRouter().push/pop`;
сигнатура `ShellCtx.go: (r: Route) => void` сохраняется — экраны не переписываются.

**ГЕЙТ (обязателен до кода оболочки):** 1-дневный спайк должен доказать сосуществование двух
react-router в ЭТОМ Vite 6: v5-поддерево `<IonReactRouter>` и верхнеуровневый v6
`<BrowserRouter>` делят один `window.history` без конфликта back/forward, а Vite-alias
изолирует v5 только для пакета Ionic (приложение остаётся v6). Провал спайка / необходимость
patch-package → откат на вариант C.

**Вариант C (фолбэк):** «плоский» Ionic на v6 — `IonPage`/`IonModal`/`IonTabs` (активная вкладка
через state, без независимого back-стека на вкладку)/`IonContent`/`IonRefresher` рендерятся на v6
БЕЗ outlet (проверено спайком: не требуют роутера). Deep-link — тривиально через v6 `navigate`.
Push/pop — вручную CSS-переход; **edge-swipe откладывается** до появления v6-роутера Ionic.
Явно жертвуем acceptance-пунктом «edge-swipe» (трек fast-follow, D-ROADMAP-01).

**Вариант B (IonNav + ручной URL-мост): ОТКЛОНЁН.** Спайк доказал: `IonNav` работает без роутера
(push/pop с анимацией). Но документация Ionic: «ion-nav is not meant to be used for routing», он
«не привязан к роутеру» (назначение — суб-навигация внутри модала). Мост URL↔IonNav на 5 вкладок +
под-роуты + deep-link — большой самописный слой против назначения компонента (риск L-1/L-2),
дороже конфиг-уровня варианта A.

Маппинг `Route` → URL (фермер, для A и C):
`home`→`/cabinet`, `market`→`/cabinet/market`, `p1list`→`/cabinet/list`,
`batch`→`/cabinet/batch/:id`, `review`→`/cabinet/review/:id`, `cabinet`→`/cabinet/account`,
`thread(turan)`→`/cabinet/turan`, `farm`/`shop`/`messages`→плейсхолдеры.
МПК: `home`→`/mpk`, `tsp`→`/mpk/tsp`, `offers`→`/mpk/offers`. Модалы → `IonModal` (не роут).
`App.tsx` уже отдаёт `/cabinet/*` и `/mpk/*` целиком в `CabinetApp`/`MpkApp` (v6 splat) —
внутри острова (A) роуты объявляются v5 `<Route>` в `IonRouterOutlet`.

### Затронутые файлы
- **A:** `package.json` (+`@ionic/react-router`, alias `react-router-dom-v5@npm:react-router-dom@5`,
  `react-router-v5@npm:react-router@5`, `history@4`), `vite.config.ts` (scoped alias/resolver-plugin),
  `CabinetApp.tsx`/`mpk/MpkApp.tsx` (единственный санкционированный 1:1 rewrite оболочки —
  бизнес-логика и `go`-контракт сохраняются), `ShellTabBar.tsx`→`IonTabs`/`IonTabBar`,
  `Sheet.tsx`→`IonModal`, экраны `screens/*`/`mpk/screens/*`→`IonPage`/`IonContent` (контент дословно).
  `types.ts` — `Route`/`RouteName` СОХРАНЯЮТСЯ (не ломаем).
- **C:** как A, но без `@ionic/react-router`/alias; `IonTabs` активная вкладка через state;
  переходы — CSS; edge-swipe отсутствует.
- **Шторки → `IonModal` (оба варианта):** 10 фермерских (`components/sheets/*`) + МПК модалы
  (`mpk/modals/*`, `mpk/sheets/ContactTuranSheet`). Контент шторок сохраняется, меняется только
  обёртка (HS-2).
- **Не трогаем (оба варианта):** `context.tsx`, `store.ts`, все `data/*`, `hooks/useBatches.ts`, `tsp/*`.

---

## 4. Platform-adapter слой (`src/platform/`)

Тонкие адаптеры поверх Host Bridge (или напрямую capability). Ядро зовёт адаптер, адаптер — Host.

| Область | Сейчас | Адаптер | web | capacitor | webview |
|---|---|---|---|---|---|
| **storage** | `localStorage` (сессия, черновики, `agos.*`) | `platform/storage.ts` | localStorage | `@capacitor/preferences` (secure) | localStorage / мост |
| **files** | `input type=file` (`MembDocsSheet`) | `host.pickImage()` | `<input file>` | `@capacitor/camera` + Filesystem | мост / `<input>` |
| **network/offline** | заглушка `offline=false` | `platform/network.ts` → реальный `ctx.offline` | `navigator.onLine` | `@capacitor/network` | `navigator.onLine` |
| **safe-area** | CSS 440px frame | Ionic CSS-переменные `--ion-safe-area-*` | env(safe-area) | нативные insets | нативные insets |
| **StatusBar/Keyboard** | нет | — | no-op | `@capacitor/status-bar` + `@capacitor/keyboard` | зависит от хоста |
| **haptics** | нет | `host.haptics()` | no-op | `@capacitor/haptics` | мост |

**Storage-миграция важна:** supabase-js по умолчанию персистит сессию в `localStorage`. В Capacitor это WebView-хранилище (может чиститься ОС). → `createClient` получает кастомный `storage` адаптер поверх `@capacitor/preferences` для нативки (secure, переживает). Это единственное изменение в `src/lib/supabase.ts` — аддитивно, web-путь не меняется.

**Offline реально:** `network.ts` подписывается на статус → `ShellContextValue.offline` наконец получает правду; `offlineToast()` и гейты (`memberAct` при offline) начинают работать.

**S3 реализован (ARS-149, PR #28, смержен 2026-07-03) — constraint для S4:** seam `KVStorage` в `src/platform/storage.ts` — **синхронный** (call-sites shell читают при инициализации, `authStorage` обёрнут в async под supabase-js), а API `@capacitor/preferences` — async. CapacitorHost (S4) обязан: (1) реализовать Preferences-бэкенд как write-through in-memory кеш, **гидратированный ДО маунта React** (и до первого чтения supabase-сессии в `AuthContext`); (2) вызвать `setAppStorageBackend` / `setDraftStorageBackend` / `setNetworkBackend` в bootstrap до рендера. Сетевой бэкенд S4 — `@capacitor/network` через `setNetworkBackend` (web/webview остаются на `navigator.onLine`). Пункт «safe-area / StatusBar / Keyboard / haptics» из тикета ARS-149 сознательно НЕ реализован в S3 — принадлежит S4 (CapacitorHost + theme CSS) per §9; в S3 только seam'ы, `host.haptics()` уже в контракте S1.

---

## 5. PWA-гигиена (web mobile)
Отсутствует полностью — нужна для «нативного ощущения в вебе» и как fallback-инсталляция.
- `public/manifest.webmanifest`: `display: standalone`, иконки (192/512/maskable), `theme_color` `#fdf6ee`, `background_color`, `start_url: /cabinet`, `scope: /`.
- Service worker (vite-plugin-pwa / Workbox): precache app-shell, runtime-cache статики. RPC/поллинг НЕ кешировать (данные свежие). Registration через Host Bridge только на web.
- `<meta name=viewport viewport-fit=cover>` + `apple-mobile-web-app-capable`.

---

## 6. Push через Host Bridge → C-серия
1. После auth ядро (в `AuthContext` или shell-bootstrap) зовёт `host.registerPushToken()`.
2. Хост возвращает токен (FCM/APNs для capacitor; токен хоста для webview; null для web).
3. Ядро отправляет токен в общий бэкенд: `rpc_register_push_token` (модель ARS-139) с `organization_id` + platform.
4. Отправка: edge-функция (ARS-141) + канал Notification Worker (ARS-142, Dok4) — общие для всех хостов.
5. Deep-link из push: при A — `host.onDeepLink(path => ionRouter.push(path, 'forward'))`; при C — `host.onDeepLink(path => navigate(path))` (v6). См. ADR-NATIVE-ROUTER-01 AMEND-1. Пример: пуш о матче партии → `/cabinet/batch/:id`. Маппинг path → экран един с §3.

**Не дублировать:** C-серия — ОДИН бэкенд. Наш Capacitor и WebView Ернура кладут токены в ту же таблицу через тот же RPC; различие только в источнике токена (Host Bridge абстрагирует).

---

## 7. UI-кит нативности (ARS-109)
- **Ionic-тема под TURAN:** переопределить Ionic CSS-переменные (`--ion-color-primary` = оранжевый TURAN, `--ion-background-color` `#fdf6ee`) в глобальном theme-файле; существующий `cabinet.css` (440px frame, safe-area) сохраняется для контента экранов, хром отдаём Ionic. Согласовать с Dok6 / AGOS-DesignSystem-v12.
- **`IonModal` вместо backdrop-шторок:** `Sheet.tsx` (простой backdrop) → `IonModal` с `breakpoints`/`initialBreakpoint` (нативный bottom-sheet с drag-to-dismiss). 10 фермерских шторок + МПК модалы.
- **`IonTabs` + `IonTabBar`:** `ShellTabBar.tsx` → нативный таб-бар с бейджами (`marketDot`, `msgBadge`, `avatarDot` из `ShellContextValue`).
- **`IonRefresher`:** pull-to-refresh на экранах с поллингом (HomeScreen, MarketScreen, MpkHomeScreen) → вручную дёргает `pullFarm`/`refetchPools`.
- **Haptics:** на ключевых действиях (публикация партии, оплата, match) через `host.haptics()`.

---

## 8. Build / deploy
- **App-target флаг:** `VITE_APP_TARGET=native|web`. При `native` роутер (`App.tsx`) монтирует только `/cabinet/*` + `/mpk/*` + auth-экраны (`/login`, `/forgot-pin`, `/register`), исключает публичный сайт (`/news`, `/finance`, `/subsidies`, `/card`) и админку (`/admin/*`). Реализация: условный набор `<Route>` по флагу (аддитивно). Apple 4.2 — нативка = фокус на функции фермера, не «обёрнутый сайт».
- **Env в рантайме:** `import.meta.env.VITE_*` фиксируется на билд-тайме. Для нативки — отдельный `.env.native` (Supabase URL/anon key одинаковые; отличается `VITE_APP_TARGET`). Секретов в бандле нет (anon key публичный по дизайну).
- **Capacitor проекты:** `capacitor.config.ts` (`webDir: dist`, `appId: kz.turan.agos`), `npx cap add ios`, `npx cap add android`. CI: `vite build` → `cap sync` → сборка нативных проектов. Web mobile — тот же `dist` на Vercel.

> **S4 РЕАЛИЗОВАН (2026-07-04, ARS-150):** `CapacitorHost` + `capacitor.config.ts` + `android/`/`ios/` проекты + app-target флаг (`VITE_APP_TARGET=native`, режет native-бандл tree-shaking'ом) + deep links + ст.171 дисклеймер. Детали, тест-матрица, Apple 4.2 risk-чеклист, шаги сборки на build-машине → **[`AGOS-NativeApp-S4-BuildAndAcceptance.md`](AGOS-NativeApp-S4-BuildAndAcceptance.md)** + DECISIONS_LOG 2026-07-04. Долги: DEBT-NATIVE-ASSETS-01, DEBT-NATIVE-STORE-01 (IMPL_DEBT).

---

## 9. Слайс-декомпозиция

| Слайс | Цель | Tier | Затронутые файлы | Зависит | Задачи Ернура (стык) |
|---|---|---|---|---|---|
| **S1 · Host Bridge + WebHost + PWA** | `AgOSHost` интерфейс + `WebHost` + детект + PWA manifest/SW. Ядро переведено на `useHost()`. | semantic | new `src/platform/host/*`; `src/lib/supabase.ts`; `contexts/AuthContext`; new `public/manifest.webmanifest`, SW | — | **Определяет контракт для ARS-133 (A4)** — расширить из postMessage-моста в Host Bridge |
| **S2 · Ionic-навигация фермер** | `CabinetApp` → `IonReactRouter`+`IonPage`; `ShellTabBar`→`IonTabs`; `Sheet`→`IonModal`. Контент/хуки сохранены. | semantic | `CabinetApp.tsx`, `types.ts`, `screens/*` (8), `sheets/*` (10), `ShellTabBar.tsx`, `ShellFrame.tsx`, `Sheet.tsx` | S1 | — |
| **S3 · Platform-adapter storage/files/offline** | `storage.ts` (Preferences), `network.ts` (реальный offline), `MembDocsSheet` → `host.pickImage()` | mechanical→semantic | new `platform/storage.ts`, `platform/network.ts`; `CabinetApp.tsx` (offline); `sheets/MembDocsSheet.tsx`; `lib/supabase.ts` storage | S1 | — |
| **S4 · Capacitor iOS/Android упаковка** | `CapacitorHost`, `capacitor.config.ts`, ios/android проекты, app-target флаг, safe-area/StatusBar/haptics | semantic | new `platform/host/CapacitorHost.ts`, `capacitor.config.ts`, `App.tsx` (app-target), theme CSS | S1,S2,S3 | — |
| **S5 · Push через Host Bridge** | `registerPushToken` в ядре → C-серия RPC; deep-link → экран | semantic | `AuthContext`/shell-bootstrap; `CapacitorHost`; router deep-link | S4 + C-серия backend | **ARS-139** (модель), **ARS-140** (токен), **ARS-141** (edge), **ARS-142** (worker), **ARS-144** (deep-link) — общий бэкенд |
| **S6 · МПК нативность** | `MpkApp` → `IonReactRouter`+`IonPage`; 4 модала→`IonModal`; `ContactTuranSheet`→`IonModal`; refresher | semantic | `mpk/MpkApp.tsx`, `mpk/types.ts`, `mpk/screens/*` (3), `mpk/modals/*` (4), `mpk/sheets/*` (1) | S2 (паттерн) | — |
| **S7 · WebViewHost (партнёрский)** | `WebViewHost` реализует контракт S1 поверх postMessage — трек Ернура | semantic | new `platform/host/WebViewHost.ts` | S1 | **ARS-133** (мост=транспорт), **ARS-134** (bootstrap сессии), **ARS-140/144** (push/deep-link) |

**Порядок:** S1 → (S2, S3 параллельно) → S4 → S5 → S6. S7 идёт трекингом Ернура на контракте S1.

---

## 10. Риски / инварианты (G1)
- **Apple 4.2 «minimum functionality»:** обёрнутый сайт отклоняют. Митигация: app-target флаг (§8, только фермер/МПК), + нативные возможности (push, камера, secure storage, offline) как аргумент «это приложение, не сайт».
- **Дешёвые Android / 3G (Dok6 бюджеты):** Ionic + WebView оверхед. Тест на low-end устройствах; поллинг 20–30с оставить, precache app-shell (S1). Замерять TTI.
- **ст.171 дисклеймер (D-LEGAL-1):** дисклеймер о непубличном предложении должен присутствовать В приложении и в store-описании. Добавить в S4 (about/footer).
- **HS-1/HS-5 (аддитивность):** контент экранов, data-хуки, RPC-контракты (D-TSP-CANON-01) НЕ меняются — только навигация/хром/платформ-слой. Роутинг-рефактор — единственное «переписывание», и оно 1:1.
- **Двойной роутер:** `BrowserRouter` (App.tsx) + `IonReactRouter` (shell) — развести: Ionic под `/cabinet/*`,`/mpk/*` вложенно, верхний react-router для сайта/auth. Проверить, что `RequireAuth` guard сохраняется.
- **Анти-дивергенция:** любой новый вызов платформы обязан идти через `AgOSHost`. Ревью-инвариант: `grep '@capacitor/'` вне `platform/host/` = нарушение.

---

## Verification (G3)
- `cross_check.sh` — имена RPC (`rpc_self_*`, `rpc_pay_membership_dues`, `rpc_submit_membership_application`) не изменились.
- Preview на web mobile: табы/шторки/переходы ощущаются нативно; offline-бар реагирует на реальную сеть.
- Capacitor: сессия переживает рестарт приложения (Preferences); push-токен долетает до `push_token`; deep-link из пуша открывает `/cabinet/batch/:id`.
- Reality↔intent: `WebViewHost` и `CapacitorHost` реализуют идентичный `AgOSHost` (типы совпадают) — единый контракт с треком Ернура.
