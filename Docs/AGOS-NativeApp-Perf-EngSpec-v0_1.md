# AGOS — Native Farmer: Perceived Performance & Fluidity (Eng-Spec v0.1)

> Sub-feature of the native-app epic (ARS-110, project «Нативное приложение (redesign)»).
> Canon (замысел, синтез): `apex-brain/projects/agos/specs/native-farmer-app.md`.
> Parent eng-spec: `Docs/AGOS-NativeApp-EngSpec-v0_1.md` (Host Bridge, routing, Capacitor).
> This doc is the engineering spec for the fluidity/loading-UX slices only.

## 0. Problem (CEO, 2026-07-10)

Нативный фермер (web / PWA / Capacitor) «тормозит». Три разных явления слиты в одну жалобу:
1. **Белые лоадеры** после регистрации / после кнопки «Получить код» — фермер не понимает, загрузка это или переход.
2. **Нет общего скелета** — у каждого экрана своя «дыра загрузки»; где-то спиннер, где-то пусто.
3. **Ощущается медленно** реально (не только восприятие) на web/PWA.

Аудит (/feature, 4 параллельных агента, 2026-07-10) локализовал корни по коду. Кнопки OTP —
в порядке (inline pending есть). Белые экраны и лаг — от роутинга, бандла и отсутствия единого
loading/chrome-слоя.

## 1. Findings → root causes (evidence)

| # | Симптом | Корень | Файл:строка |
|---|---------|--------|-------------|
| F1 | 3 белых провала на пути в кабинет | `NativeEntry` `return null`; `Suspense fallback={null}`; голый `Loader2` профиля | `App.tsx:151`, `App.tsx:209`, `CabinetApp.tsx:599` |
| F2 | Светлые вспышки между шагами | Разные фоны boot/auth/Welcome (`#fdf6ee`/`#fafaf7`/тёмный) в null-гэпах | `index.css:389`, `auth-ui/tokens.ts:9`, `Welcome.tsx:11` |
| F3 | Нет брендового первого кадра | `#root` пустой, только `body{background}` | `index.html:18`, `index.css:387` |
| F4 | Ложный empty-state («Партий нет») | `ListScreen` не знает про `loading`, показывает пусто пока грузится | `ListScreen.tsx:13`, `CabinetApp.tsx:523` |
| F5 | Ложный «Партия не найдена» на deep-link | `renderBatch`/`renderReview` `find()` без проверки `loading` | `CabinetApp.tsx:543`, `:564` |
| F6 | Скелет прикрывает не те данные | Home gated на `batchesLoading`, а шапка «Ферма·N голов» грузится отдельно и поповит демо-сид | `CabinetApp.tsx:146`, `HomeScreen.tsx:44`, `store.ts:115` |
| F7 | Нет общего паттерна загрузки | 3 ad-hoc подхода; `SkeletonBlocks` в 2 из 8 экранов; DS `Skeleton` не используется | `HomeScreen.tsx:67`, `MarketScreen.tsx:95`, `SkeletonBlocks.tsx:7` |
| F8 | Табы переключаются мгновенно, вход в партию слайдит | `root`/`replace` в nav = без анимации, разный «язык» движения | `nav.ts:8,67`, `CabinetApp.tsx:285` |
| F9 | Хрома пересобирается на каждом переходе | Нет `IonTabs`/`IonHeader`; таб-бар+хедер внутри каждого экрана | `CabinetApp.tsx:614`, `IonShellFrame.tsx:39`, `ShellTabBarIon.tsx:20` |
| F10 | Визард фейкает вертикальный переход | Wizard/PubResult — свопы стейта, не роуты; CSS-хак | `ionic.css:92`, `CabinetApp.tsx:472` |
| F11 | Фермер качает код админки на первом кадре | Весь admin/expert/consulting/legacy статически импортирован в entry | `App.tsx:58-127` |
| F12 | recharts в entry-чанке | Тянется через eager consulting-табы | `App.tsx:119-125` |
| F13 | Нет vendor-сплита | Нет `manualChunks`/`rollupOptions` | `vite.config.ts` |
| F14 | Рендер-блок 9 семейств шрифтов + дубль | `@import` 9 families + дубль с `index.html` | `index.css:1`, `index.html:15` |

### Brain-spec corrections (стали неверны — исправлено в canon)
- **PWA-инфра ЕСТЬ** (manifest + SW + `vite-plugin-pwa`): `vite.config.ts:57`, `public/manifest.webmanifest`, `HostContext.tsx:44`. Спека утверждала «PWA-инфры нет вообще» — устарело.
- **Навигация мигрирована на Ionic** (react-router v5-остров, нативные slide/swipe): `CabinetApp.tsx:607`. Раздел аудита спеки писал «custom Route state-machine без react-router» — устарело.

### Verified NON-issues (не трогаем)
- QueryClient defaults хорошие (`staleTime 30s`, `refetchOnWindowFocus:false`) — `App.tsx:130`.
- Поллинг тихий (`silent:true`) — рефетч не мигает — `useBatches.ts:89`.
- Шторки — чистые `IonModal` drag-to-dismiss — `Sheet.tsx:14`.
- OTP-кнопки имеют inline pending — `Contact.tsx:196`, `CreatePin.tsx:80`.

## 2. Slices (build order — full sweep, CEO 2026-07-10)

Все слайсы **аддитивны** (HS-1/2/5): существующий функционал не удаляется, только
добавляется/чинится loading-контракт и конфиг.

### P-1 · Bundle & fonts (🤖 mechanical) — реальная скорость (F11–F14)
- `App.tsx:58-127`: перевести eager-импорты admin/expert/consulting/legacy-cabinet + `MpkApp`
  в `lazy()`; обернуть их роуты в `<Suspense>` с общим fallback (см. P-2 `BootScreen`).
  → гейт `!IS_NATIVE` начинает реально вырезать этот код из native/farmer-бандла.
- `vite.config.ts`: добавить `build.rollupOptions.output.manualChunks` — изолировать
  `recharts`, `@ionic/*`, radix-набор, `@supabase/*`, `i18next`.
- `index.css:1`: убрать `@import` 9 семейств; перенести нужные (2–3 реально используемых)
  в `index.html` через `<link>` + дедуп с существующим (Inter/JetBrains Mono уже там).
- **Acceptance:** `npm run build` зелёный; farmer entry-чанк не содержит recharts/admin
  (проверка `dist/` или `rollup-plugin-visualizer`); шрифты грузятся одним запросом.

### P-2 · Branded boot + kill white gaps (🤖 mechanical) — жалоба 1 (F1–F3)
- Новый `src/components/BootScreen.tsx` — брендовый плейсхолдер (лого TURAN на фоне
  `--boot-bg`, деликатный спиннер, опц. подпись). Единый фон-токен на весь boot-путь.
- `App.tsx:151` `NativeEntry`: `if (loading) return <BootScreen/>` вместо `null`.
- `App.tsx:209` + все `Suspense fallback={null}` на фермерском пути → `fallback={<BootScreen/>}`.
- `RequireAuth.tsx`: голый `Loader2` → `<BootScreen/>`.
- `CabinetApp.tsx:599`: `profileLoading` спиннер → `<BootScreen/>` (в фон кабинета).
- `index.html`: инлайн-плейсхолдер в `#root` (лого + фон `--boot-bg`) — первый кадр не пустой.
- Унифицировать фон-токен boot↔Welcome↔auth (убрать светлую вспышку F2).
- **Acceptance:** от старта до кабинета — ни одного немаркированного белого экрана; фон не
  меняет цвет между шагами; на медленной сети видно лого, а не пустоту.

### P-3 · Unified loading / skeleton system (🤖→👤) — жалоба 2 (F4–F7)
- Единый контракт: `ShellFrame`/screen получает `loading`; общий `<ScreenSkeleton variant>`
  с силуэтами под Home / Market / List / Batch (переиспользовать DS `Skeleton`, не дженерик).
- `ListScreen`: добавить `loading` prop; при `loading` → скелет, НЕ empty-state (F4).
- `renderBatch`/`renderReview` (`CabinetApp.tsx`): при `loading && !found` → скелет карточки,
  не «не найдена» (F5).
- Home: gate на `farm`-загрузку тоже; убрать показ демо-сида залогиненному фермеру (F6).
- `CabinetScreen`, MPK-экраны: добавить loading-состояние.
- **Acceptance:** ни один экран не показывает ложный empty/not-found до загрузки; скелет
  повторяет форму контента; нет content-shift после mount на Home.

### P-4 · Persistent chrome (IonTabs) + consistent transitions (👤 semantic) — жалоба 3 (F8–F10)
- ⚠️ Трогает роутер-остров (ADR-NATIVE-ROUTER-01, DEBT-NATIVE-ROUTER-01) — осторожно, за
  smoke-гейтом `npm run test:routers`.
- Обернуть `IonRouterOutlet` в `IonTabs` c **одним** постоянным `IonTabBar` + `IonHeader`,
  чтобы хрома оставалась смонтированной между переходами (F9).
- Решение по табам: iOS-нативно табы переключаются **мгновенно** (это корректно) — фикс не
  «добавить анимацию», а «перестать пересобирать хрому». Зафиксировать как design-decision.
- Wizard/PubResult: сделать реальными роутами (нативный slide) ИЛИ выровнять CSS-переход с
  горизонтальным slide роутов + добавить exit-анимацию (F10).
- **Acceptance:** таб-бар/хедер не мигают при навигации; переход в партию и выход
  консистентны; `npm run test:routers` зелёный; свайп-назад работает.

## 3. Non-goals
- Не переписываем shell (HS-1). Не трогаем RPC/схему/RLS (чистый фронт, P7 не затронут).
- Не меняем полбинг-архитектуру (тихий silent-рефетч уже хорош).
- Не трогаем шторки (`IonModal` уже чисто).

## 4. Rollout / tiering
P-1, P-2 — mechanical (агент кодит). P-3 — mechanical по механике, семантика в выборе
loading-контракта. P-4 — human-led (роутер-остров). Каждый слайс: build/preview verify →
G3 (merge) человеком.
