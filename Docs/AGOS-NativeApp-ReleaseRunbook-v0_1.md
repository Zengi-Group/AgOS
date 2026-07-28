# Release Runbook — публикация AgOS в App Store и Google Play (v0.1)

> Релизный слайс эпика **ARS-110** (`native-farmer-app`). Не новая фича — вывод уже
> построенной Capacitor-обёртки (S1–S4, S6) в сторы. Что уже в коде — см.
> [`AGOS-NativeApp-S4-BuildAndAcceptance.md`](AGOS-NativeApp-S4-BuildAndAcceptance.md)
> (не дублируем). Здесь — путь «код готов → в сторах», с владельцем каждого шага.
> Контент листингов (описания, приватность, Data Safety) — в
> [`AGOS-NativeApp-StoreListings-v0_1.md`](AGOS-NativeApp-StoreListings-v0_1.md).

---

## App identity (зафиксировано в коде — НЕ менять после первой публикации)

| Поле | Значение | Источник |
|---|---|---|
| Bundle ID / applicationId | `kz.turan.agos` | `capacitor.config.ts`, `build.gradle`, `project.pbxproj` |
| Отображаемое имя | `AgOS · TURAN` | `strings.xml`, `Info.plist CFBundleDisplayName` |
| Marketing version | `1.0` | `versionName`, `MARKETING_VERSION` |
| Build number | `1` | `versionCode`, `CURRENT_PROJECT_VERSION` |
| Universal-link домен | `app.turanstandard.kz` | `App.entitlements`, `capacitor.config.ts` |
| Custom scheme (fallback) | `kz.turan.agos` | `strings.xml` |
| **Store-аккаунты (юрлицо)** | **Zengi** (зарегистрированы, CEO 2026-07-27) | решение сессии |

> ⚠️ Publisher в сторах = **Zengi**, а приложение брендировано **TURAN**. Это ок (Zengi —
> оператор/разработчик, TURAN — ассоциация), но: (1) в листинге дать «Разработчик: Zengi
> для ассоциации TURAN»; (2) юр-сверка со ст.171 — publisher не должен читаться как продавец
> скота. См. ст.171-блок в листингах.

---

## §1. Блокеры до сборки (что закрыть ПЕРВЫМ)

Аккаунты есть → критический путь короткий. B5 и B6 закрыты (2026-07-27); остались 4 пункта; **B1 —
жёсткий гейт ревью обоих сторов**, без него отклонят.

| # | Блокер | Почему гейт | Владелец | Правит |
|---|---|---|---|---|
| **B1** 🔴 | **Публичный URL политики конфиденциальности** | App Store и Play **требуют** валидный privacy-URL до сабмита | я готовлю текст → Zengi/Аршидин хостят | текст в листингах §Privacy → хост `app.turanstandard.kz/privacy` |
| **B6** ✅ | **Удаление аккаунта в приложении** | Apple 5.1.1(v) + Google Play (data-deletion) — обязательно для приложений с регистрацией; частая причина отклонения | код готов (2026-07-27) | кабинет → «О приложении» кнопка + confirm-шторка → `rpc_delete_account` |
| **B2** 🟡 | **Android release signing** (сейчас `buildTypes.release` без `signingConfig`) | без подписи AAB не собрать/не загрузить | Mac/build-машина | `android/app/build.gradle` + upload-keystore + Play App Signing |
| **B3** 🟡 | **iOS Team + capabilities** (`DEVELOPMENT_TEAM` пуст; Associated Domains/Push не привязаны) | без Team ID нет подписи и universal links | Mac + Xcode (Zengi Apple-аккаунт) | Xcode Signing & Capabilities |
| **B4** 🟢 | **Deep-link плейсхолдеры** `TEAMID` / `REPLACE_WITH_SIGNING_CERT_SHA256` | universal/app links не заработают | я подставлю по значениям от Zengi | `public/.well-known/{apple-app-site-association,assetlinks.json}` |
| **B5** ✅ | **Финальная бренд-иконка + portrait-lock** | иконка была апскейл-заглушкой; iOS Info.plist разрешал landscape | обе части закрыты 2026-07-27 (иконка = ассеты ARS-109) | `assets/icon-only.png` + `icon-foreground/background.png`, `Info.plist`/`AndroidManifest` |

> **B1/B6 — решение владельца:** ~~можно ли релизить v1.0 **без** B6~~ — **РЕШЕНО CEO 2026-07-27:
> строим.** B6 закрыт (см. ниже). B1 обязателен всегда.

### ✅ Сделано в релиз-сессии 2026-07-27 (аддитивно)
- **B1 (частично):** privacy-страница `public/privacy/index.html` (RU/KK) создана → задеплоится на `https://<домен>/privacy` с фронтом. ⚠️ Осталось: убедиться, что ящик `support@turanstandard.kz` существует (или заменить контакт).
- **B5 portrait-lock:** iOS `Info.plist` (обе идиомы) + Android `screenOrientation="portrait"` — залочено на портрет.
- **B2 (scaffold):** `android/app/build.gradle` — `signingConfigs.release` из `AGOS_UPLOAD_*` (guard `hasProperty`, keystore/пароли НЕ в git; без свойств поведение как раньше). Осталось: создать keystore на build-машине + прописать свойства.
- **B5 (иконка, финал, 2026-07-27):** финальная бренд-иконка ARS-109 передана и вкручена — `assets/icon-only.png` + `icon-foreground.png` + `icon-background.png` (Custom Mode `@capacitor/assets` переопределяет `logo.png` для иконок), `npm run cap:assets` перегенерирован → `ios/App/App/Assets.xcassets/AppIcon.appiconset` + Android legacy/adaptive mipmap-иконки. Play-листинг `icon-play-512.png` → `Docs/store-assets/`. Проверено: iOS без альфы и без запечённых скруглений, Android под маской лаунчера 1:1 с iOS (Δ2.1%).
- **Сплэш (финал, 2026-07-27):** заглушка-апскейл `logo.png` заменена на сборку из **векторного** мастера марки — `scripts/build-splash-assets.mjs` (`public/turan-icon.svg` → `assets/splash.png` + `splash-dark.png`, 2732², марка 176 px на `#fdf6ee`), первым звеном `npm run cap:assets`; отдельная передача от дизайна не потребовалась. Размер привязан к первому кадру JS (`BootScreen` 54 px) → замер 55.0 pt на iPhone @3x и 53.0 dp на Android 1080×2400 xxhdpi: переход сплэш→кабинет без прыжка марки и смены фона. Попутно: тёмный сплэш был `#111111` (чёрная вспышка на телефоне в тёмной теме при daylight-only кабинете) → все `*-night-*`/`*-dark` теперь `#fdf6ee`; `androidScaleType: 'CENTER_CROP'` в `capacitor.config.ts` вместо дефолтного `FIT_XY`, который сплющивал марку (39.3×53.0 dp вместо 53×53). Удалены неиспользуемые шаблонные `splash-2732x2732*.png` (синий логотип Capacitor). Долг `DEBT-NATIVE-ASSETS-01` закрыт полностью. ⚠️ Визуальная проверка на реальном устройстве — в DEBT-NATIVE-VERIFY-01 (в песочнице нет Xcode-сборки/эмулятора).
- **B6 (закрыт, 2026-07-27):** self-service удаление аккаунта. `rpc_delete_account()` (`d01_kernel.sql`, RPC-46, Dok3 §2) — soft-delete (`users.is_active=false` + `auth.users.encrypted_password` обнулён, блокирует вход), блокирует `ACCOUNT_HAS_ACTIVE_DEALS` при незавершённых TSP-сделках, организация/аудит-история не трогается (ст.171). UI: кнопка «Удалить аккаунт» в кабинете → «О приложении» + confirm-шторка `DeleteAccountSheet`. `cross_check.sh`/`tsc -b` зелёные. ⚠️ **Не прогнано на реальном auth-схеме** (нет прод-доступа в этой сессии) — перед сабмитом прогнать вживую (`rpc_delete_account` на тестовом аккаунте, не на общем QA-сиде) и обновить privacy-страницу (сделано, см. §Privacy ниже).
- Остаётся владельцу/build-машине: B3 (iOS Team), B4 (Team ID/SHA256), деплой privacy-страницы, сборка/подпись, live-прогон B6 на устройстве.

---

## §2. Сборка и подпись (Mac build-машина: macOS + Xcode + CocoaPods + Android SDK)

Веб-бандл общий: `npm run build:native` (VITE_APP_TARGET=native → только `/cabinet` + `/mpk` + auth).

### 2a. Android → AAB
```bash
npm run cap:sync:android          # build:native + cap sync android
```
1. **Upload keystore** (одноразово): `keytool -genkey -v -keystore agos-upload.keystore -alias agos -keyalg RSA -keysize 2048 -validity 10000`. Хранить в секрет-менеджере Zengi, НЕ в git.
2. Прописать `signingConfigs.release` в `android/app/build.gradle` (ключ из `~/.gradle/gradle.properties`, не хардкод) и `buildTypes.release { signingConfig signingConfigs.release }`.
3. `cd android && ./gradlew bundleRelease` → `app/build/outputs/bundle/release/app-release.aab`.
4. **Play App Signing** (рекомендация): Google хранит app-signing-ключ, вы грузите upload-ключом. **SHA256 для `assetlinks.json` брать из Play Console → Setup → App integrity → App signing key** (НЕ upload-ключа — уточнение к S4-доку, там сказано «upload», это неверно для Play App Signing).

### 2b. iOS → App Store Connect / TestFlight
```bash
sudo gem install cocoapods         # один раз
npm run cap:sync:ios               # build:native + cap sync ios (pod install)
npm run cap:ios                    # + cap open ios (Xcode)
```
В Xcode (target **App**):
1. Signing & Capabilities → Team = **Zengi**, Automatically manage signing.
2. Добавить capability **Associated Domains** (привязать `App/App.entitlements`, домен уже там) + **Push Notifications** (для S5).
3. Записать **Apple Team ID** (Membership) → отдать мне для B4 (AASA).
4. Product → Archive → Distribute → App Store Connect → TestFlight.

---

## §3. Заведение приложений в консолях

### App Store Connect
- [ ] Создать App: bundle `kz.turan.agos`, имя «AgOS · TURAN», основной язык **русский**, доп. **казахский**, SKU `agos-turan`.
- [ ] Листинг (из [листингов](AGOS-NativeApp-StoreListings-v0_1.md)): описание, что нового, ключевые слова, категория **Бизнес**, скриншоты (§4 листингов).
- [ ] **App Privacy** (Privacy Nutrition) — по таблице листингов.
- [ ] **Privacy Policy URL** (B1).
- [ ] Age Rating (4+; отметить UGC — рынок/сообщения).
- [ ] Цена — **Free**.
- [ ] Reviewer notes: демо-логин (сид-фермер), пояснение ст.171 (текст в листингах).
- [ ] Submit → App Review.

### Google Play Console
- [ ] Создать приложение: `kz.turan.agos`, ру+kk.
- [ ] **Data Safety** форма (таблица листингов).
- [ ] **Content rating** (IARC-опросник → Everyone).
- [ ] Privacy Policy URL (B1).
- [ ] Store listing: описания, иконка 512×512, **feature graphic 1024×500** (дизайн — нет в `cap:assets`), скриншоты.
- [ ] Загрузить AAB → **Internal testing** → прогон → **Production** (можно поэтапный rollout).
- [ ] Указать целевую аудиторию, рекламу (нет), гос-приложение (нет).

---

## §4. Deep links (после того как Team ID и SHA256 известны — B4)
1. AASA: заменить `TEAMID` → реальный Apple Team ID в `public/.well-known/apple-app-site-association`.
2. assetlinks: заменить `REPLACE_WITH_SIGNING_CERT_SHA256` → SHA256 app-signing-ключа Play.
3. Задеплоить фронт (Vercel) → проверить, что оба файла отдаются с `https://app.turanstandard.kz/.well-known/…` с `Content-Type: application/json` (AASA — без расширения).
4. Проверка: Apple — установить сборку, тап по `https://app.turanstandard.kz/cabinet/...` открывает приложение; Android — `adb shell am start -a android.intent.action.VIEW -d "https://app.turanstandard.kz/cabinet/..."`.

---

## §5. Apple 4.2 «minimum functionality» — защита
Готово в коде (см. S4-док §Apple 4.2): app-target режет публичный сайт/админку; на борту push, камера, secure storage, offline-гейт, нативные переходы, ст.171-дисклеймер. **Довод ревьюеру:** это операционный инструмент фермера (стадо, план работ, координация сбыта), не обёртка сайта. Демо-доступ + этот довод — в reviewer notes.

---

## §6. Матрица владения

| Шаг | Я (Claude) | Аршидин / Zengi | Mac build-машина | Ернур |
|---|---|---|---|---|
| Runbook + листинги + privacy-текст | ✅ | ревью | | |
| Хостинг privacy URL (B1) | подготовлю страницу | деплой/подтвердить | | |
| Удаление аккаунта (B6) | код ✅ (2026-07-27) | ревью + live-прогон перед сабмитом | | |
| Android keystore + signingConfig (B2) | правку gradle | хранение ключа | сборка | |
| iOS Team/capabilities (B3) | | Apple-аккаунт Zengi | Xcode | |
| Team ID / SHA256 → мне | подстановка (B4) | прислать значения | | |
| Иконка/portrait (B5) | portrait-lock ✅ + иконка вкручена ✅ | иконка (ARS-109) ✅ передана | | |
| Сплэш | ✅ собран из вектора марки (`build-splash-assets.mjs`) | — (передача не нужна) | визуальная проверка на устройстве | |
| Скриншоты | шот-лист + размеры | | захват на устройстве | |
| Push (S5 / APNs / google-services) | | ключи | | клиент+бэкенд |
| Создание записей в консолях + сабмит | подготовка данных | **кнопки, оплата, сабмит** | | |

> По моим правилам создание аккаунтов, оплату, ввод учётных/платёжных данных и финальный
> сабмит на ревью делаешь ты — я довожу всё до кнопки.

---

## §7. После сабмита
- Apple review: обычно 24–48 ч; частые отклонения — 4.2 (митигировано), 5.1.1(v) удаление аккаунта (B6), приватность-несоответствие (сверить nutrition с реальностью).
- Play: internal testing мгновенно; production review — часы-дни; Data Safety должна совпадать с фактическим сбором.
- Версии: **каждая** новая загрузка = уникальный `versionCode` (Android) и `CURRENT_PROJECT_VERSION` (iOS build). Marketing `1.0` держим до фичевого релиза.

---

## §8. Долги, снимаемые этим релизом
- **DEBT-NATIVE-STORE-01** — юрлицо определено (Zengi), аккаунты есть, B5 + B6 закрыты; остаток = **B1–B4**.
- **DEBT-NATIVE-ASSETS-01** — ✅ закрыт полностью 2026-07-27: иконка (B5, ARS-109) + сплэш из вектора (см. `assets/README.md`). ✅ **Ассеты релиза закрыты полностью 2026-07-27:** `feature graphic 1024×500` передана дизайном и принята — `Docs/store-assets/feature-graphic-1024x500.png` (ТЗ + замеры приёмки: `Docs/AGOS-NativeApp-StoreListings-v0_1.md` §8.1). ⚠️ Перед загрузкой в Play — решение владельца по клейму «Сбыт» → «Координация сбыта» (ст.171).
- **DEBT-NATIVE-VERIFY-01** — device smoke-тест на реальной сборке (§2 + тест-матрица S4-дока).
