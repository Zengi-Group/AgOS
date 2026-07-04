# S4 — Capacitor-упаковка: сборка, deep links, тест-матрица, Apple 4.2 (ARS-150)

> Слайс S4 эпика ARS-110. Спека: [`AGOS-NativeApp-EngSpec-v0_1.md`](AGOS-NativeApp-EngSpec-v0_1.md) §8, §10.
> Что вошло в код в этой сессии — раздел «Реализовано». Что делается на build-машине с
> полным нативным тулчейном (acceptance) — разделы «Сборка» и «Тест-матрица».

---

## Реализовано (в репозитории)

| Область | Артефакт |
|---|---|
| Capacitor-конфиг | `capacitor.config.ts` (`appId: kz.turan.agos`, `webDir: dist`, StatusBar/Splash/Keyboard/Push) |
| Нативные проекты | `android/`, `ios/` (сгенерированы `npx cap add`; свои `.gitignore` на build-артефакты) |
| `CapacitorHost` | `src/platform/host/CapacitorHost.ts` — полная реализация `AgOSHost` (storage/network/push/deep-link/camera/haptics/statusbar) |
| Подключение хоста | `HostContext.tsx` — динамический импорт CapacitorHost (отдельный чанк, web-бандл чист) |
| App-target | `App.tsx` — `VITE_APP_TARGET=native` монтирует только `/cabinet` + `/mpk` + auth; `.env.native.example`; `npm run build:native` |
| Deep links | Android intent-filter (app links + `agos://`), iOS `App.entitlements` (associated domains); `public/.well-known/{apple-app-site-association,assetlinks.json}` |
| Разрешения | Android: CAMERA, POST_NOTIFICATIONS; iOS: NSCamera/NSPhotoLibrary usage descriptions |
| Иконка/сплэш | `assets/logo.png` → `npm run cap:assets` (74 android + 7 ios) |
| Юр-дисклеймер ст.171 | `CabinetScreen.tsx` блок «О ПРИЛОЖЕНИИ» (D-LEGAL-1) |

Проверено локально: `npm run build` (web) ✓, `VITE_APP_TARGET=native npm run build:native` ✓
(main-чанк 2 896 kB → 1 870 kB — админка/экспертка вырезаны tree-shaking'ом мёртвой ветки
`!IS_NATIVE`), `npm run test:unit` 8/8 ✓, CapacitorHost = отдельный чанк 16.8 kB (не в web-бандле).

---

## Сборка (build-машина: macOS + Xcode + CocoaPods + Android SDK)

```bash
# 1. Нативный веб-бандл (только фермер/МПК) + синхронизация в нативные проекты
npm run cap:sync            # = build:native + cap sync (обе платформы)

# 2a. iOS (нужен полный Xcode, не Command Line Tools, + CocoaPods)
sudo gem install cocoapods  # один раз
npm run cap:ios             # cap sync ios + open ios → архив/симулятор в Xcode

# 2b. Android (нужен Android SDK / Android Studio)
npm run cap:android         # cap sync android + open android → сборка в Android Studio
```

> ⚠️ В песочнице разработки iOS `pod install` пропущен (CocoaPods не установлен, активны
> только Command Line Tools). Xcode-проект `ios/` сгенерирован; `pod install` + сборка —
> на настроенной Mac-build-машине. Это и есть шаг acceptance (реальные устройства).

### Ручная до-настройка при первой публикации (одноразово в Xcode/Gradle)

1. **iOS Associated Domains:** в Xcode → target App → Signing & Capabilities →
   привязать `App/App.entitlements` (`CODE_SIGN_ENTITLEMENTS`), добавить capability
   «Associated Domains». Домен уже прописан: `applinks:app.turanstandard.kz`.
2. **Team ID → AASA:** заменить `TEAMID` в `public/.well-known/apple-app-site-association`
   на реальный Apple Team ID (зависит от store-аккаунта — см. открытый вопрос ниже).
3. **Android signing SHA256 → assetlinks:** заменить `REPLACE_WITH_SIGNING_CERT_SHA256`
   в `public/.well-known/assetlinks.json` на fingerprint релизного/upload-ключа
   (`keytool -list -v -keystore …` или из Play Console → App integrity).
4. **Push (S5 / C-серия):** iOS — APNs key в Apple Developer + capability Push
   Notifications; Android — `google-services.json` в `android/app/`. Клиентская привязка
   токен→БД (`rpc_register_push_token`) реализуется в S5 (ARS-140+).
5. Оба `.well-known/` файла должны отдаваться с домена `app.turanstandard.kz`
   (тот же Vercel-dist, `public/` копируется в `dist/`). Проверить `Content-Type` AASA.

---

## Тест-матрица (acceptance §10)

### Бюджеты производительности (Dok6, 3G / дешёвый Android)

| Метрика | Бюджет | Как мерить |
|---|---|---|
| FCP | < 2 s | Lighthouse mobile throttle 3G / реальное устройство |
| TTI | < 5 s | Lighthouse / WebPageTest, Slow 3G |
| Нативный cold start | сплэш → первый кадр | `SplashScreen.hide()` в CapacitorHost после init |

Меры уже в коде: precache app-shell (Workbox), поллинг 20–30 с не трогаем, CapacitorHost
и Ionic v5-остров — отдельные чанки; тяжёлые фоны публичного сайта в native-бандл не входят.

### Матрица устройств

| Устройство | Что проверяем |
|---|---|
| Дешёвый Android (Go/2 ГБ ОЗУ) | FCP/TTI-бюджеты; плавность IonTabs/переходов; клавиатура не ломает layout |
| iOS (notch, напр. iPhone SE + iPhone 14/15) | safe-area (`env(safe-area-inset-*)`, `viewport-fit=cover`); edge-swipe-назад; статус-бар тёмный на `#fdf6ee` |
| Планшет / без бара | StatusBar no-op не падает |

### Функциональные проверки нативки

- Сессия переживает рестарт приложения (Preferences, secure storage).
- Черновик визарда переживает рестарт (draftStorage → Preferences).
- Offline-бар реагирует на реальную сеть (`@capacitor/network`); при восстановлении — авто-retry.
- Документы членства снимаются камерой / берутся из галереи (`host.pickImage`).
- Deep-link из push открывает `/cabinet/batch/:id` (cold + warm start).
- Haptics на ключевых действиях (публикация/оплата/match).

---

## Apple 4.2 «minimum functionality» — risk-чеклист

Обёрнутый сайт отклоняют. Аргументы «это приложение, не сайт»:

| Пункт | Статус | Где |
|---|---|---|
| App-target: только функции фермера (нет публичного сайта/админки) | ✅ код | `App.tsx` `IS_NATIVE` |
| Push на борту | ✅ плагин + host-метод; клиент→БД = S5 | `capacitor.config.ts`, `CapacitorHost.registerPushToken` |
| Камера (нативный пикер) | ✅ | `CapacitorHost.pickImage` + usage descriptions |
| Secure storage (сессия переживает ОС-чистку WebView) | ✅ | `CapacitorHost` Preferences-бэкенд |
| Offline (реальный статус + оффлайн-гейт) | ✅ | `@capacitor/network` → `platform/network` |
| Нативные переходы (push/pop, edge-swipe, pull-to-refresh) | ✅ (S2) | Ionic v5-остров |
| Юр-дисклеймер ст.171 в приложении | ✅ | `CabinetScreen` (D-LEGAL-1) |

---

## Открытый вопрос (эскалация, НЕ решается кодом)

**Юрлицо store-аккаунтов (TURAN vs Zengi).** Apple Developer Program для организации требует
**D-U-N-S номер** (получение — недели). Play Console — проще, но тоже привязка к юрлицу.
От выбора зависят: Apple **Team ID** (→ AASA, universal links), сертификаты подписи
(→ Android assetlinks SHA256), владелец publisher-аккаунта. **Решить заранее** — блокирует
финальную привязку deep links и публикацию, но НЕ блокирует сборку/внутренний прогон.
