# Нативные ассеты (иконка / сплэш) — ARS-150 §8

Источник генерации иконок и сплэш-экранов iOS/Android через `@capacitor/assets`.

## Пайплайн

```bash
npm run cap:assets   # capacitor-assets generate --ios --android --iconBackgroundColor '#fdf6ee' --splashBackgroundColor '#fdf6ee'
                     #   + node scripts/fix-android-adaptive-icon-sizes.mjs (см. долг ниже)
```

`--ios --android` — намеренно (без этого тул по умолчанию гоняет ещё и `pwa`, пишет в
`./icons` **вне** `public/` — Vite это не сервит — и переписывает `public/manifest.webmanifest`
битыми `../icons/...`-путями; PWA-манифест поддерживается вручную, `vite.config.ts` → `VitePWA({ manifest: false })`).

Custom Mode (раздельные иконка + adaptive-слои — режим тула, задокументирован в его README):
инструмент читает `assets/icon-only.png` + `assets/icon-foreground.png` + `assets/icon-background.png`,
а также (для splash — своих ассетов пока нет, см. ниже) `assets/logo.png`, и пишет:
- `android/app/src/main/res/**` — legacy + adaptive mipmap-иконки, splash (light/dark, все плотности);
- `ios/App/App/Assets.xcassets/**` — AppIcon + Splash imageset.

## Входные файлы

| Файл | Требование | Статус |
|---|---|---|
| `icon-only.png` | квадрат 1024×1024, полностью непрозрачный | **финал** — бренд-иконка ARS-109 (iOS + Android legacy-фоллбэк) |
| `icon-foreground.png` | квадрат 1024×1024, RGBA, знак на прозрачном | **финал** — ARS-109 (Android adaptive icon, API 26+) |
| `icon-background.png` | квадрат 1024×1024, полностью непрозрачный | **финал** — ARS-109 (Android adaptive icon, API 26+) |
| `logo.png` | квадрат ≥1024×1024, бренд-марка TURAN | **временный** — используется ТОЛЬКО для сплэш-экранов (иконку больше не читает — переопределена `icon-only`/`-foreground`/`-background` выше); апскейл `public/favicon-512.png`, не векторный мастер |

## Долг (DEBT-NATIVE-ASSETS-01) — иконка закрыта, сплэш открыт

Иконка (эта папка, ARS-109, 2026-07-27) — финал, долг по иконке снят. Сплэш всё ещё
генерируется из `logo.png`-заглушки (апскейл). Финальный сплэш (опц. `logo-dark.png` или
готовые `splash.png`/`splash-dark.png` в Custom Mode) — отдельная передача дизайна;
после неё — перегенерировать `npm run cap:assets`.

## Известный баг тула (@capacitor/assets@3.0.5)

В Custom Mode `generateAdaptiveIconForeground`/`generateAdaptiveIconBackground` (см.
`node_modules/@capacitor/assets/dist/platforms/android/index.js`) ошибочно берут таблицу
размеров ЛЕГАСИ-иконки (48..192px) вместо adaptive-icon (108..432px) — в Easy Mode (один
`logo.png`) тот же тул использует правильную таблицу. Без фикса — размытая иконка на
xxhdpi/xxxhdpi (большинство Android-телефонов). `scripts/fix-android-adaptive-icon-sizes.mjs`
перегенерирует foreground/background в правильных размерах поверх вывода тула; вызывается
автоматически из `npm run cap:assets` — при апгрейде `@capacitor/assets` проверить, не
починили ли размер апстрим (тогда скрипт становится избыточным, но не вредным).
