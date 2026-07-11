/**
 * TuranLoader — ЕДИНСТВЕННЫЙ лоадер проекта (бренд-звезда TURAN в движении).
 *
 * Геометрия = 4-лучевая звезда логотипа TURAN (те же пути, что в turan-icon.svg
 * и BootScreen). Цвет по умолчанию = фирменный оранжевый логотипа `#F7931E`.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 *  КАКОЙ ВАРИАНТ ГДЕ (канон — единственные два допустимых лоадера в проекте):
 *
 *  variant="breathe"  — спокойное «дыхание» лучей.
 *     Полноэкранная / маршрутная / страничная загрузка: route-guard'ы,
 *     lazy-чанки, «страница/раздел загружается», boot. Размер крупный (44–64).
 *     Читается как «приложение работает», а не «завис».
 *
 *  variant="spin"     — вращение звезды.
 *     Инлайн / в кнопке / точечная операция «идёт прямо сейчас»:
 *     сохранение, отправка, расчёт. Размер мелкий (14–20), обычно рядом с
 *     текстом кнопки. Наследует поток строки.
 *
 *  Никаких других спиннеров (lucide `Loader2`, `.mk-spin`, border-спиннеры,
 *  IonSpinner) в проекте быть не должно. Новый лоадер = этот компонент.
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * Классы `tl-spin` / `tl-ray` + keyframes живут в `src/index.css` (глобальный
 * бренд-примитив). Namespaced `tl-*` намеренно — чтобы не наследовать
 * border-спиннеры кабинета (`.agos-cabinet-stage .spin`, `.mk-spin`).
 * `prefers-reduced-motion` учтён там же.
 */

interface TuranLoaderProps {
  /** 'breathe' — полноэкранная/страничная загрузка; 'spin' — инлайн/в кнопке. */
  variant?: 'breathe' | 'spin'
  /** Сторона в px. По умолчанию 20 (инлайн). Для полноэкранной — 44–64. */
  size?: number
  /** Цвет лучей. По умолчанию фирменный оранжевый логотипа TURAN. */
  color?: string
  className?: string
  style?: React.CSSProperties
  /** Доступное имя (aria-label). По умолчанию «Загрузка». */
  label?: string
}

// Пути 4-лучевой звезды TURAN в системе координат viewBox="42.88 -0.13 130 130".
// transform-origin у каждого луча — его внешний угол (для «дыхания» из угла).
const RAYS: { d: string; origin: string; delay: string }[] = [
  { d: 'M63.62,33.3l24.23,24.23c1.01,1.01,2.64,1.01,3.64,0l5.92-5.92c13.08-13.08,20.43-30.82,20.43-49.31V0h-18.38v43.15l-22.84-22.84-13,13h0Z', origin: '100% 100%', delay: '-1.214s' },
  { d: 'M139.46,20.61l-24.23,24.23c-1.01,1.01-1.01,2.64,0,3.64l5.92,5.92c13.08,13.08,30.82,20.43,49.31,20.43h2.29v-18.38h-43.15l22.84-22.84-13-13h.02Z', origin: '0% 100%', delay: '-1.15s' },
  { d: 'M152.15,96.45l-24.23-24.23c-1.01-1.01-2.64-1.01-3.64,0l-5.92,5.92c-13.08,13.08-20.43,30.82-20.43,49.31v2.29h18.38v-43.15l22.84,22.84,13-13v.02Z', origin: '0% 0%', delay: '-1.086s' },
  { d: 'M76.31,109.14l24.23-24.23c1.01-1.01,1.01-2.64,0-3.64l-5.92-5.92c-13.08-13.08-30.82-20.43-49.31-20.43h-2.29v18.38h43.15l-22.84,22.84,13,13h-.02Z', origin: '100% 0%', delay: '-1.021s' },
]

export function TuranLoader({
  variant = 'spin',
  size = 20,
  color = '#F7931E',
  className = '',
  style,
  label = 'Загрузка',
}: TuranLoaderProps) {
  const isBreathe = variant === 'breathe'
  return (
    <svg
      className={`${isBreathe ? 'tl-breathe' : 'tl-spin'} ${className}`.trim()}
      width={size}
      height={size}
      viewBox="42.88 -0.13 130 130"
      role="img"
      aria-label={label}
      style={{ display: 'block', flexShrink: 0, ...style }}
    >
      <g fill={color}>
        {RAYS.map((r, i) => (
          <path
            key={i}
            d={r.d}
            className={isBreathe ? 'tl-ray' : undefined}
            style={isBreathe ? { transformOrigin: r.origin, animationDelay: r.delay } : undefined}
          />
        ))}
      </g>
    </svg>
  )
}

export default TuranLoader
