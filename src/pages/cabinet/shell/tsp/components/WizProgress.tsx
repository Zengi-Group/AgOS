// AgOS · TSP-1 · Точки прогресса визарда (порт market-ui.jsx WizProgress) — .mk-wiz-prog.
// ARS-212 (аддитивно, HS-5): опциональный проп `count` (default 5) — фермерский мастер
// параметризует число точек по ветке; TSP-вызовы `<WizProgress step={step} />` не меняются.

export function WizProgress({ step, count = 5 }: { step: number; count?: number }) {
  return (
    <div className="mk-wiz-prog">
      {Array.from({ length: count }, (_, i) => i + 1).map((n) => (
        <div key={n} className={n < step ? 'done' : n === step ? 'cur' : ''} />
      ))}
    </div>
  )
}
