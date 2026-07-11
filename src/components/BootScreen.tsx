/**
 * BootScreen — единый брендовый плейсхолдер загрузки нативного фермера (P-2, ARS-218).
 *
 * Заменяет разрозненные белые провалы (`return null`, `Suspense fallback={null}`,
 * голый Loader2) на всём пути в кабинет: cold-start auth-resolve, lazy-чанк CabinetApp,
 * RequireAuth, profileLoading. Фон = `#fdf6ee` — канонический тёплый кремовый
 * (совпадает с theme-color в index.html, manifest.background_color, body и фоном
 * кабинета), поэтому переход boot→кабинет бесшовный, без светлой вспышки.
 *
 * Спокойная «дышащая» марка + тонкая индетерминантная полоса вместо резкого спиннера —
 * читается как «приложение запускается», а не «завис».
 *
 * Марка = TuranLoader variant="breathe" (единственный лоадер проекта, см. TuranLoader.tsx):
 * boot — это полноэкранная загрузка → breathe. Полоса/подпись остаются как boot-специфика.
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
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 22,
        paddingTop: 'env(safe-area-inset-top)',
        paddingBottom: 'env(safe-area-inset-bottom)',
        fontFamily: "'Geist', -apple-system, BlinkMacSystemFont, system-ui, sans-serif",
      }}
    >
      <style>{`
        @keyframes agosBootBar {
          0% { transform: translateX(-100%); }
          100% { transform: translateX(300%); }
        }
        @media (prefers-reduced-motion: reduce) {
          .agos-boot-bar-fill { animation-duration: 2.4s !important; }
        }
      `}</style>

      {/* TURAN brand mark — breathe (единственный лоадер проекта) */}
      <TuranLoader variant="breathe" size={54} label={label ?? 'Загрузка'} />

      {/* Slim indeterminate bar */}
      <div
        style={{
          width: 96,
          height: 3,
          borderRadius: 3,
          background: 'rgba(20,19,18,0.08)',
          overflow: 'hidden',
        }}
      >
        <div
          className="agos-boot-bar-fill"
          style={{
            width: '40%',
            height: '100%',
            borderRadius: 3,
            background: '#F0A020',
            animation: 'agosBootBar 1.15s ease-in-out infinite',
          }}
        />
      </div>

      {label ? (
        <div style={{ fontSize: 13, color: '#706a63', letterSpacing: '.01em', fontWeight: 500 }}>{label}</div>
      ) : null}
    </div>
  )
}
