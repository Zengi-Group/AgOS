// AgOS · TSP-1 · 5 точек прогресса визарда (порт market-ui.jsx WizProgress) — .mk-wiz-prog.

export function WizProgress({ step }: { step: number }) {
  return (
    <div className="mk-wiz-prog">
      {[1, 2, 3, 4, 5].map((n) => (
        <div key={n} className={n < step ? 'done' : n === step ? 'cur' : ''} />
      ))}
    </div>
  )
}
