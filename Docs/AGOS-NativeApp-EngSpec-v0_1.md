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

### Развилка (главный вопрос слайсинга)
- **(a) Полный `IonReactRouter`** — оба корня (`CabinetApp`, `MpkApp`) переводятся на `IonRouterOutlet` + `IonPage`. Даёт бесплатно: нативные page-transitions push/pop, edge-swipe-назад, правильный стек истории. Цена: рефактор собственного `Route` state-machine на URL-роуты (react-router уже в проекте на верхнем уровне — `App.tsx`; конфликт `BrowserRouter` vs `IonReactRouter` нужно развести: Ionic-роутер монтируется под `/cabinet/*` и `/mpk/*` как вложенный).
- **(b) Только Ionic-компоненты** — `IonModal`/`IonContent`/`ion-tab-bar`/`IonRefresher` без замены роутера. Меньше рефактор. Но НЕТ бесплатных page-transitions и edge-swipe — а это и есть «нативное ощущение», ради которого выбран Ionic (см. бриф: нативность = слой ремесла, жесты/переходы). Вариант (b) не выполняет исходное требование CEO.

### Рекомендация: **(a) полный IonReactRouter**, поэтапно
Без него Ionic не даёт того, ради чего выбран. Смягчаем риск рефактора инкрементальностью: `Route`/`MpkRoute` state-machine → URL-роуты 1:1, а **контент экранов и data-хуки сохраняются дословно** (аддитивно к бизнес-логике, HS-1). `go(r)` становится тонкой обёрткой над `useIonRouter().push/pop`. `ShellCtx.go` сохраняет сигнатуру `(r: Route) => void` — экраны не переписываются.

Маппинг `Route` → URL (фермер):
`home`→`/cabinet`, `market`→`/cabinet/market`, `p1list`→`/cabinet/list`, `batch`→`/cabinet/batch/:id`, `review`→`/cabinet/review/:id`, `cabinet`→`/cabinet/account`, `thread(turan)`→`/cabinet/turan`, `farm`/`shop`/`messages`→плейсхолдеры. `back?: Route` заменяется нативным стеком.
МПК: `home`→`/mpk`, `tsp`→`/mpk/tsp`, `offers`→`/mpk/offers`. Модалы → `IonModal` (не роут).

### Затронутые файлы (из graphify)
- **Заменяются на Ionic-навигацию:** `CabinetApp.tsx`, `mpk/MpkApp.tsx`, `types.ts` (`Route`/`MpkRoute`/`RouteName`), `components/ShellTabBar.tsx` → `IonTabBar`, `components/ShellFrame.tsx`, `components/Sheet.tsx` → `IonModal`.
- **Оборачиваются в `IonPage`/`IonContent` (контент не трогаем):** 8 фермерских экранов (`screens/*`), 3 МПК экрана (`mpk/screens/*`).
- **Шторки → `IonModal`:** 10 фермерских (`components/sheets/*`) + `mpk/sheets/ContactTuranSheet`. МПК 4 модала (`mpk/modals/*`) → `IonModal`.
- **Не трогаем:** `context.tsx`, `store.ts`, все `data/*`, `hooks/useBatches.ts`, `tsp/*` — чистая бизнес-логика/данные.

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
5. Deep-link из push: `host.onDeepLink(path => ionRouter.push(path))`. Пример: пуш о матче партии → `/cabinet/batch/:id`. Маппинг path → экран един с §3.

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
