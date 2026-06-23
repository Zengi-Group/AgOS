// AgOS · Этап 1 · Искра Консультанта — 8-лучевая звезда TURAN.
// Геометрия — слово в слово из прототипа shell/ui.jsx.

export function SparkIc({ size }: { size?: number }) {
  const s = size || 16
  return (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 2l1.8 6.2L20 10l-6.2 1.8L12 18l-1.8-6.2L4 10l6.2-1.8z" />
      <path d="M18.5 3.5l.7 2.3 2.3.7-2.3.7-.7 2.3-.7-2.3-2.3-.7 2.3-.7z" opacity=".75" />
    </svg>
  )
}
