# Нативные ассеты (иконка / сплэш) — ARS-150 §8

Источник генерации иконок и сплэш-экранов iOS/Android через `@capacitor/assets`.

## Пайплайн

```bash
npm run cap:assets   # node scripts/build-splash-assets.mjs                  (сплэш из вектора, см. ниже)
                     #   + capacitor-assets generate --ios --android
                     #       --iconBackgroundColor '#fdf6ee' --splashBackgroundColor '#fdf6ee'
                     #       --splashBackgroundColorDark '#fdf6ee'
                     #   + node scripts/fix-android-adaptive-icon-sizes.mjs   (баг тула, см. ниже)
```

`--splashBackgroundColorDark '#fdf6ee'` — тёплый и для тёмной темы (дефолт тула `#111111`).
Флаг работает только как страховка на случай пропажи `splash-dark.png`: сам сплэш приходит
готовой картинкой. Нативная сборка = только фермерский кабинет, а он daylight-only —
чёрный сплэш дал бы вспышку при переходе в кремовый кабинет (ровно то, с чем боролся P-2).

`--ios --android` — намеренно (без этого тул по умолчанию гоняет ещё и `pwa`, пишет в
`./icons` **вне** `public/` — Vite это не сервит — и переписывает `public/manifest.webmanifest`
битыми `../icons/...`-путями; PWA-манифест поддерживается вручную, `vite.config.ts` → `VitePWA({ manifest: false })`).

Custom Mode (раздельные иконка + adaptive-слои + свои сплэши — режим тула, задокументирован в его README):
инструмент читает `assets/icon-only.png` + `assets/icon-foreground.png` + `assets/icon-background.png`
+ `assets/splash.png` + `assets/splash-dark.png`, и пишет:
- `android/app/src/main/res/**` — legacy + adaptive mipmap-иконки, splash (light/dark, все плотности);
- `ios/App/App/Assets.xcassets/**` — AppIcon + Splash imageset.

Порядок внутри тула: сначала прогоняется `logo.png` (устаревший Easy-Mode-вход), потом
`icon-*` и `splash*` перетирают его вывод — последняя запись побеждает (`loadInputAssets`,
`generateAssets` идут по фиксированному порядку ключей). Поэтому `logo.png` больше НИ НА ЧТО
не влияет: и иконки, и сплэши переопределены. Файл оставлен как бренд-растр, но входом
пайплайна уже не является — при уборке удалять его безопасно (P4: один вход на один выход).

## Входные файлы

| Файл | Требование | Статус |
|---|---|---|
| `icon-only.png` | квадрат 1024×1024, полностью непрозрачный | **финал** — бренд-иконка ARS-109 (iOS + Android legacy-фоллбэк) |
| `icon-foreground.png` | квадрат 1024×1024, RGBA, знак на прозрачном | **финал** — ARS-109 (Android adaptive icon, API 26+) |
| `icon-background.png` | квадрат 1024×1024, полностью непрозрачный | **финал** — ARS-109 (Android adaptive icon, API 26+) |
| `splash.png` | квадрат 2732×2732, марка на фоне `#fdf6ee` | **финал, генерируется** — `scripts/build-splash-assets.mjs` из вектора `public/turan-icon.svg`; руками не править |
| `splash-dark.png` | то же, побайтово равен светлому | **финал, генерируется** — тем же скриптом; кабинет daylight-only, тёмного сплэша по дизайну нет |
| `logo.png` | квадрат ≥1024×1024, бренд-марка TURAN | **не вход пайплайна** — перетирается `icon-*` и `splash*` (см. порядок выше); остался как бренд-растр |

## Сплэш — почему он собирается скриптом

`scripts/build-splash-assets.mjs` кладёт марку из **векторного** мастера
(`public/turan-icon.svg` — те же пути, что в `TuranLoader`/favicon) в центр квадрата 2732².
Размер марки (176 px) подобран так, чтобы на экране она совпала с первым кадром JS —
`BootScreen` (54 px, `--boot-bg #fdf6ee`, только марка — решение CEO 2026-07-14):
замер по сгенерированным ассетам — **55.0 pt** на iPhone @3x и **53.0 dp** на Android
1080×2400 xxhdpi. Переход нативный сплэш → BootScreen без прыжка марки и без смены фона.

Ручной PNG такую связь не держит — прошлая заглушка была апскейлом `public/favicon-512.png`
до 1024 и марка в ней жила независимо от кабинета. Если дизайн когда-нибудь передаст
собственную композицию сплэша (напр. с логотипом-словом) — она кладётся вместо вывода
скрипта, скрипт из цепочки `cap:assets` убирается, дальше всё как раньше.

**`androidScaleType: 'CENTER_CROP'`** в `capacitor.config.ts` — обязателен вместе с этими
ассетами: дефолт плагина `FIT_XY` растягивает drawable (2:3) под пропорции экрана (9:20) и
сплющивает марку (замер: 39.3×53.0 dp вместо 53×53). Фон однотонный, обрезка краёв не видна.

## Известный баг тула (@capacitor/assets@3.0.5)

В Custom Mode `generateAdaptiveIconForeground`/`generateAdaptiveIconBackground` (см.
`node_modules/@capacitor/assets/dist/platforms/android/index.js`) ошибочно берут таблицу
размеров ЛЕГАСИ-иконки (48..192px) вместо adaptive-icon (108..432px) — в Easy Mode (один
`logo.png`) тот же тул использует правильную таблицу. Без фикса — размытая иконка на
xxhdpi/xxxhdpi (большинство Android-телефонов). `scripts/fix-android-adaptive-icon-sizes.mjs`
перегенерирует foreground/background в правильных размерах поверх вывода тула; вызывается
автоматически из `npm run cap:assets` — при апгрейде `@capacitor/assets` проверить, не
починили ли размер апстрим (тогда скрипт становится избыточным, но не вредным).
