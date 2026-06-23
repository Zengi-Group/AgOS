// AgOS · TSP-1 · 5 точек прогресса визарда (p1/ui.jsx WizProgress).

export function WizProgress({ step }: { step: number }) {
  return (
    <div className="progress">
      {[1, 2, 3, 4, 5].map((n) => (
        <div key={n} className={n < step ? 'done' : n === step ? 'cur' : ''} />
      ))}
    </div>
  )
}
