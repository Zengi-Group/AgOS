# Нативные ассеты (иконка / сплэш) — ARS-150 §8

Источник генерации иконок и сплэш-экранов iOS/Android через `@capacitor/assets`.

## Пайплайн

```bash
npm run cap:assets   # capacitor-assets generate --iconBackgroundColor '#fdf6ee' --splashBackgroundColor '#fdf6ee'
```

Инструмент читает `assets/logo.png` и пишет:
- `android/app/src/main/res/**` — mipmap-иконки + splash (light/dark, все плотности);
- `ios/App/App/Assets.xcassets/**` — AppIcon + Splash imageset.

## Входные файлы

| Файл | Требование | Статус |
|---|---|---|
| `logo.png` | квадрат ≥1024×1024, бренд-марка TURAN | **временный** — апскейл `public/favicon-512.png` до 1024 (лосси) |

## Долг (DEBT-NATIVE-ASSETS-01)

`logo.png` сейчас — апскейл 512→1024, а не векторный мастер. Финальная бренд-иконка
(и, при необходимости, отдельный `logo-dark.png` + кастомный сплэш) приходит из
дизайн-прохода UI-кита **ARS-109**. После замены `logo.png` — перегенерировать
`npm run cap:assets` и `npx cap sync`.
