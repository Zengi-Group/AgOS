// AgOS · TSP-1 · Степпер +/− с инпутом (порт market-ui.jsx Stepper) — .mk-stp.

import { PhIcon } from '../../components/icons/PhIcon'

export function StepperCtl({ value, onChange, min, max }: { value: number; onChange: (v: number) => void; min: number; max: number }) {
  const set = (v: number) => onChange(Math.min(max, Math.max(min, v)))
  return (
    <div className="mk-stp">
      <button className="mk-stp-b" onClick={() => set(value - 1)} aria-label="минус"><PhIcon name="minus" size={18} /></button>
      <input
        className="mk-stp-i mk-mono"
        inputMode="numeric"
        value={value}
        onChange={(e) => { const n = parseInt(e.target.value.replace(/\D/g, '') || '0', 10); onChange(n) }}
        onBlur={() => set(value)}
      />
      <button className="mk-stp-b" onClick={() => set(value + 1)} aria-label="плюс"><PhIcon name="plus" size={18} /></button>
    </div>
  )
}
