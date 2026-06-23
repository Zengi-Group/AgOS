// AgOS · TSP-1 · Степпер +/− с инпутом (p1/ui.jsx StepperCtl).

export function StepperCtl({ value, onChange, min, max }: { value: number; onChange: (v: number) => void; min: number; max: number }) {
  const set = (v: number) => onChange(Math.min(max, Math.max(min, v)))
  return (
    <div className="stp">
      <button className="stp-b" onClick={() => set(value - 1)}>−</button>
      <input
        className="stp-i mono"
        inputMode="numeric"
        value={value}
        onChange={(e) => { const n = parseInt(e.target.value.replace(/\D/g, '') || '0', 10); onChange(n) }}
        onBlur={() => set(value)}
      />
      <button className="stp-b" onClick={() => set(value + 1)}>+</button>
    </div>
  )
}
