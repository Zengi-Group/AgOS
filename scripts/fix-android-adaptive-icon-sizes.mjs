// @capacitor/assets@3.0.5 генерирует Android adaptive-icon foreground/background из
// ОТДЕЛЬНЫХ source-файлов (assets/icon-foreground.png, assets/icon-background.png — Custom Mode)
// по таблице размеров ЛЕГАСИ-иконки (mdpi 48..xxxhdpi 192), а не adaptive-icon (mdpi 108..xxxhdpi 432).
// В Easy Mode (один assets/logo.png) тот же тул использует правильную adaptive-icon таблицу —
// расхождение воспроизведено на установленной версии (см. node_modules/@capacitor/assets/dist/
// platforms/android/index.js: generateAdaptiveIconForeground/Background фильтруют kind==="icon").
// Итог без этого фикса: на xxhdpi/xxxhdpi (подавляющее большинство Android-телефонов) лаунчер
// апскейлит 144/192px до 324/432px — видимая размытость иконки на главном экране.
//
// Перегенерирует foreground/background в правильных размерах поверх вывода `capacitor-assets
// generate`, не трогая остальное (legacy ic_launcher.png, XML, iOS, сплэши).
import sharp from 'sharp'
import { join } from 'path'

const RES_DIR = 'android/app/src/main/res'
const ADAPTIVE_ICON_SIZES = { ldpi: 81, mdpi: 108, hdpi: 162, xhdpi: 216, xxhdpi: 324, xxxhdpi: 432 }

const LAYERS = [
  ['assets/icon-foreground.png', 'ic_launcher_foreground.png'],
  ['assets/icon-background.png', 'ic_launcher_background.png'],
]

for (const [source, filename] of LAYERS) {
  for (const [density, size] of Object.entries(ADAPTIVE_ICON_SIZES)) {
    const dest = join(RES_DIR, `mipmap-${density}`, filename)
    await sharp(source).resize(size, size).png().toFile(dest)
    console.log(`FIX android adaptive-icon ${dest} (${size}x${size})`)
  }
}
