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
 */

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
        @keyframes agosBootPulse {
          0%, 100% { transform: scale(1); opacity: 1; }
          50% { transform: scale(0.9); opacity: 0.62; }
        }
        @keyframes agosBootBar {
          0% { transform: translateX(-100%); }
          100% { transform: translateX(300%); }
        }
        @media (prefers-reduced-motion: reduce) {
          .agos-boot-mark { animation: none !important; }
          .agos-boot-bar-fill { animation-duration: 2.4s !important; }
        }
      `}</style>

      {/* TURAN star mark (reuse of src/assets/turan-icon.svg geometry) */}
      <svg
        className="agos-boot-mark"
        width="54"
        height="54"
        viewBox="0 0 130 130"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        style={{ animation: 'agosBootPulse 1.6s ease-in-out infinite' }}
      >
        <path d="M20.5996 33.3L44.8296 57.53C45.8396 58.54 47.4696 58.54 48.4696 57.53L54.3896 51.61C67.4696 38.53 74.8196 20.79 74.8196 2.3V0H56.4396V43.15L33.5996 20.31L20.5996 33.31V33.3Z" fill="#F7931E" />
        <path d="M109.13 96.4499L84.9002 72.2199C83.8902 71.2099 82.2602 71.2099 81.2602 72.2199L75.3402 78.1399C62.2602 91.2199 54.9102 108.96 54.9102 127.45V129.74H73.2902V86.5899L96.1301 109.43L109.13 96.4299V96.4499Z" fill="#F7931E" />
        <path d="M96.4397 20.6099L72.2096 44.8399C71.1996 45.8499 71.1996 47.4799 72.2096 48.4799L78.1296 54.3999C91.2096 67.4799 108.95 74.8299 127.44 74.8299H129.73V56.4499H86.5797L109.42 33.6099L96.4196 20.6099H96.4397Z" fill="#F7931E" />
        <path d="M33.29 109.14L57.52 84.9099C58.53 83.8999 58.53 82.2699 57.52 81.2699L51.6 75.3499C38.52 62.2699 20.78 54.9199 2.29 54.9199H0V73.2999H43.15L20.31 96.1399L33.31 109.14H33.29Z" fill="#F7931E" />
      </svg>

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
