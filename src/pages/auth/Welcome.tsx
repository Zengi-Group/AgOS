import { useNavigate } from 'react-router-dom'

/**
 * Тёмный приветственный экран (вход мобильного приложения для неавторизованных).
 * Портирован из прототипа agos-farmer (routes/index.tsx Welcome). Собственные
 * тёмные токены — единственный тёмный экран вход-фаннела (контраст со светлыми
 * формами регистрации/входа, как в прототипе).
 */
const T = {
  bg: '#0e0d0c',
  fg: '#ededea',
  fg2: '#a8a29a',
  fg3: '#706a63',
  bd: '#2a2825',
  accent: '#F0A020',
  cta: '#e6e2dc',
  ctaFg: '#141312',
  font: "'Geist', -apple-system, BlinkMacSystemFont, system-ui, sans-serif",
}

function Star() {
  return (
    <svg width="20" height="20" viewBox="0 0 32 32" fill="none">
      <g transform="translate(16,16)">
        {[0, 45, 90, 135, 180, 225, 270, 315].map((a, i) => (
          <path key={i} d="M 0 -12 L 2 -2 L 0 0 L -2 -2 Z" fill={T.accent} transform={`rotate(${a})`} />
        ))}
        <circle r="2.5" fill={T.accent} />
      </g>
    </svg>
  )
}

export function Welcome() {
  const navigate = useNavigate()
  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: T.bg,
        color: T.fg,
        fontFamily: T.font,
        WebkitFontSmoothing: 'antialiased',
        display: 'flex',
        justifyContent: 'center',
        paddingTop: 'env(safe-area-inset-top)',
        paddingBottom: 'env(safe-area-inset-bottom)',
      }}
    >
      <div style={{ width: '100%', maxWidth: 480, padding: 24, display: 'flex', flexDirection: 'column' }}>
        {/* brand */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, paddingTop: 8 }}>
          <Star />
          <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: '.02em' }}>
            TURAN <span style={{ color: T.fg3, fontWeight: 500 }}>AgOS</span>
          </div>
        </div>

        {/* hero */}
        <div style={{ marginTop: 'auto', paddingTop: 64 }}>
          <div style={{ fontSize: 11, letterSpacing: '.18em', textTransform: 'uppercase', color: T.accent, fontWeight: 600, marginBottom: 16 }}>
            Кабинет фермера
          </div>
          <h1 style={{ fontFamily: T.font, fontSize: 34, lineHeight: 1.05, letterSpacing: '-0.025em', fontWeight: 600, margin: 0 }}>
            Работа с рынком — <span style={{ color: T.fg2 }}>в одном приложении.</span>
          </h1>
          <p style={{ fontSize: 15, color: T.fg2, lineHeight: 1.5, margin: '18px 0 0', maxWidth: 340 }}>
            Продажа партий, справочные цены, услуги и членство TURAN. Без бумаги, с одного номера.
          </p>
        </div>

        {/* actions */}
        <div style={{ marginTop: 'auto', paddingTop: 48, display: 'flex', flexDirection: 'column', gap: 10 }}>
          <button
            onClick={() => navigate('/register')}
            style={{ height: 54, borderRadius: 12, border: 'none', background: T.cta, color: T.ctaFg, fontFamily: T.font, fontSize: 16, fontWeight: 600, letterSpacing: '-0.01em', cursor: 'pointer' }}
          >
            Зарегистрироваться
          </button>
          <button
            onClick={() => navigate('/login')}
            style={{ height: 54, borderRadius: 12, background: 'transparent', border: `1px solid ${T.bd}`, color: T.fg, fontFamily: T.font, fontSize: 16, fontWeight: 500, letterSpacing: '-0.01em', cursor: 'pointer' }}
          >
            Авторизоваться
          </button>
        </div>
      </div>
    </div>
  )
}
