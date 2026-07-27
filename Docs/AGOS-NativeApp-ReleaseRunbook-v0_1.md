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

Аккаунты есть → критический путь короткий. Остались 6 пунктов; **B1 и B6 — жёсткие гейты
ревью обоих сторов**, без них отклонят.

| # | Блокер | Почему гейт | Владелец | Правит |
|---|---|---|---|---|
| **B1** 🔴 | **Публичный URL политики конфиденциальности** | App Store и Play **требуют** валидный privacy-URL до сабмита | я готовлю текст → Zengi/Аршидин хостят | текст в листингах §Privacy → хост `app.turanstandard.kz/privacy` |
| **B6** 🔴 | **Удаление аккаунта в приложении** | Apple 5.1.1(v) + Google Play (data-deletion) — обязательно для приложений с регистрацией; частая причина отклонения | нужен код (новый слайс) | кабинет → «Профиль/О приложении» + RPC мягкого удаления |
| **B2** 🟡 | **Android release signing** (сейчас `buildTypes.release` без `signingConfig`) | без подписи AAB не собрать/не загрузить | Mac/build-машина | `android/app/build.gradle` + upload-keystore + Play App Signing |
| **B3** 🟡 | **iOS Team + capabilities** (`DEVELOPMENT_TEAM` пуст; Associated Domains/Push не привязаны) | без Team ID нет подписи и universal links | Mac + Xcode (Zengi Apple-аккаунт) | Xcode Signing & Capabilities |
| **B4** 🟢 | **Deep-link плейсхолдеры** `TEAMID` / `REPLACE_WITH_SIGNING_CERT_SHA256` | universal/app links не заработают | я подставлю по значениям от Zengi | `public/.well-known/{apple-app-site-association,assetlinks.json}` |
| **B5** 🟢 | **Финальная бренд-иконка + portrait-lock** | иконка = апскейл-заглушка (DEBT-NATIVE-ASSETS-01); iOS Info.plist разрешает landscape | иконка — дизайн ARS-109; lock — я | `assets/logo.png`, `Info.plist`/`AndroidManifest` |

> **B1/B6 — решение владельца:** можно ли релизить v1.0 **без** B6 (риск отклонения Apple ~высокий)
> или заводим короткий слайс «удаление аккаунта» в кабинет ПЕРЕД сабмитом? Рекомендую — завести
> (1–2 экрана + RPC, ~полдня). B1 обязателен всегда.

### ✅ Сделано в релиз-сессии 2026-07-27 (аддитивно)
- **B1 (частично):** privacy-страница `public/privacy/index.html` (RU/KK) создана → задеплоится на `https://<домен>/privacy` с фронтом. ⚠️ Осталось: убедиться, что ящик `support@turanstandard.kz` существует (или заменить контакт); в тексте — удаление аккаунта по email (в приложении добавить, когда сделаем B6).
- **B5 portrait-lock:** iOS `Info.plist` (обе идиомы) + Android `screenOrientation="portrait"` — залочено на портрет.
- **B2 (scaffold):** `android/app/build.gradle` — `signingConfigs.release` из `AGOS_UPLOAD_*` (guard `hasProperty`, keystore/пароли НЕ в git; без свойств поведение как раньше). Осталось: создать keystore на build-машине + прописать свойства.
- **B5 (иконка, финал):** финальная бренд-иконка ARS-109 передана и вкручена — `assets/icon-only.png` + `icon-foreground.png` + `icon-background.png` (Custom Mode `@capacitor/assets`, заменили `logo.png` для иконки), `npm run cap:assets` перегенерирован → `ios/App/App/Assets.xcassets/AppIcon.appiconset` + Android legacy/adaptive mipmap-иконки. Play-листинг `icon-play-512.png` → `Docs/store-assets/`. Сплэш вне скоупа (см. `assets/README.md`) — остаётся апскейл-заглушка.
- Остаётся владельцу/build-машине: B3 (iOS Team), B4 (Team ID/SHA256), B6 (удаление аккаунта), деплой privacy-страницы, сборка/подпись.

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
| Удаление аккаунта (B6) | код (если решим делать) | решение делать/нет | | |
| Android keystore + signingConfig (B2) | правку gradle | хранение ключа | сборка | |
| iOS Team/capabilities (B3) | | Apple-аккаунт Zengi | Xcode | |
| Team ID / SHA256 → мне | подстановка (B4) | прислать значения | | |
| Иконка/portrait (B5) | portrait-lock ✅ + иконка вкручена ✅ | иконка (ARS-109) ✅ передана | | |
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
- **DEBT-NATIVE-STORE-01** — юрлицо определено (Zengi), аккаунты есть; остаток = B1–B6.
- **DEBT-NATIVE-ASSETS-01** — иконка (B5) ✅ закрыта 2026-07-27 (ARS-109); сплэш остаётся открытым (см. `assets/README.md`).
- **DEBT-NATIVE-VERIFY-01** — device smoke-тест на реальной сборке (§2 + тест-матрица S4-дока).
