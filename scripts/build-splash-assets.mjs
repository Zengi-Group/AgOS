// Сборка входных сплэш-ассетов для @capacitor/assets (Custom Mode) из ВЕКТОРНОГО мастера
// бренд-марки — `public/turan-icon.svg` (те же пути, что в TuranLoader/favicon).
//
// Зачем скрипт, а не «просто картинка от дизайна»: сплэш обязан совпадать с ПЕРВЫМ кадром
// JS-приложения (BootScreen, P-2 / ARS-218: единый тёплый `#fdf6ee`, только марка — решение
// CEO 2026-07-14). Оба берутся из одного вектора и одного числа размера — поэтому переход
// нативный сплэш → BootScreen бесшовный: марка не прыгает и фон не мигает. Ручной PNG
// такую связь не держит (прошлая заглушка `logo.png` = апскейл 512→1024).
//
// Геометрия (почему 176 px в квадрате 2732):
//   iOS  — Splash.imageset = один квадрат 2732², сторибордом растянут scaleAspectFill.
//          На @3x-телефоне (390×844 pt): 2732/3 = 910.67 pt, fill-scale = 844/910.67 = 0.9268
//          → марка 176/3 × 0.9268 = 54.4 pt ≈ 54 px BootScreen'а.
//   Android — тул кроп-ресайзит квадрат в per-density drawable (cover), плагин кладёт его
//          в ImageView. На типичном 1080×2400 xxhdpi: 176 × (1600/2732) = 103 px в drawable
//          960×1600, CENTER_CROP ×1.5 → 155 px = 51.5 dp ≈ те же 54 dp.
// Итог: одна и та же видимая марка ~52–54 pt/dp на обеих платформах.
//
// Светлый и тёмный сплэш НАМЕРЕННО одинаковые: нативная сборка — это только фермерский
// кабинет (VITE_APP_TARGET=native), а он daylight-only. Дефолт тула для dark — #111111,
// т.е. на телефоне в тёмной теме был чёрный экран → вспышка в кремовый кабинет; ровно то,
// с чем боролся P-2. Отдельный файл `splash-dark.png` нужен, чтобы тул зарегистрировал
// dark-appearance СВОИМ ассетом и не ушёл в этот дефолт.
import sharp from 'sharp'
import { readFile } from 'fs/promises'

const MARK_SVG = 'public/turan-icon.svg' // канонический вектор марки TURAN (#F7931E)
const CANVAS = 2732 // размер универсального сплэша Capacitor (iOS Splash.imageset)
const MARK = 176 // сторона марки в канвасе — см. расчёт в шапке
const BG = '#fdf6ee' // --boot-bg: BootScreen + body + theme-color + manifest.background_color
const OUTPUTS = ['assets/splash.png', 'assets/splash-dark.png']

// density 1200 → librsvg растрирует вектор много крупнее целевых 176 px, дальше
// один downscale lanczos3. Так марка приходит из вектора, а не из апскейла растра.
const mark = await sharp(await readFile(MARK_SVG), { density: 1200 })
  .resize(MARK, MARK, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 }, kernel: 'lanczos3' })
  .png()
  .toBuffer()

const offset = (CANVAS - MARK) / 2 // 1278 — целое, марка на пиксельной сетке

for (const dest of OUTPUTS) {
  const info = await sharp({
    create: { width: CANVAS, height: CANVAS, channels: 3, background: BG },
  })
    .composite([{ input: mark, left: offset, top: offset }])
    .png({ compressionLevel: 9 })
    .toFile(dest)
  console.log(`BUILD splash source ${dest} (${info.width}x${info.height}, марка ${MARK}px, фон ${BG})`)
}
