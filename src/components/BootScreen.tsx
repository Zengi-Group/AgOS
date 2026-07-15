/**
 * BootScreen — единый брендовый плейсхолдер загрузки нативного фермера (P-2, ARS-218).
 *
 * Заменяет разрозненные белые провалы (`return null`, `Suspense fallback={null}`,
 * голый Loader2) на всём пути в кабинет: cold-start auth-resolve, lazy-чанк CabinetApp,
 * RequireAuth, profileLoading. Фон = `#fdf6ee` — канонический тёплый кремовый
 * (совпадает с theme-color в index.html, manifest.background_color, body и фоном
 * кабинета), поэтому переход boot→кабинет бесшовный, без светлой вспышки.
 *
 * Спокойная «дышащая» марка вместо резкого спиннера — читается как
 * «приложение запускается», а не «завис».
 *
 * Марка = TuranLoader variant="breathe" (единственный лоадер проекта, см. TuranLoader.tsx):
 * boot — это полноэкранная загрузка → breathe. Только марка: полоса-индикатор и подпись
 * убраны (решение CEO 2026-07-14) — на экране запуска остаётся одна иконка логотипа.
 */
import { TuranLoader } from './TuranLoader'

interface BootScreenProps {
  /** Опциональная подпись под маркой, напр. «Загрузка кабинета…». */
  label?: string
}

export function BootScreen({ label }: BootScreenProps) {
  return (
    <div
      role="status"
      aria-live="polite"
      aria-label={label ?? 'Загрузка'}
      style={{
        position: 'fixed',
        inset: 0,
        background: 'var(--boot-bg, #fdf6ee)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        paddingTop: 'env(safe-area-inset-top)',
        paddingBottom: 'env(safe-area-inset-bottom)',
        fontFamily: "'Geist', -apple-system, BlinkMacSystemFont, system-ui, sans-serif",
      }}
    >
      {/* Только марка (иконка логотипа) — breathe, единственный лоадер проекта.
          label остаётся aria-label обёртки для доступности, но визуально не рендерится. */}
      <TuranLoader variant="breathe" size={54} label={label ?? 'Загрузка'} />
    </div>
  )
}
