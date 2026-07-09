// AgOS · TSP-1 · Большой радио-выбор с подзаголовком (порт market-ui.jsx BigRadio) — .mk-big-radio.

import { PhIcon } from '../../components/icons/PhIcon'

export function BigRadio({ sel, onClick, title, sub }: { sel: boolean; onClick: () => void; title: string; sub?: string }) {
  return (
    <button className={'mk-big-radio' + (sel ? ' sel' : '')} onClick={onClick}>
      <span className={'mk-br-dot' + (sel ? ' on' : '')}>{sel && <PhIcon name="check" size={12} color="var(--cta-fg)" />}</span>
      <span className="mk-br-body">
        <span className="mk-br-t">{title}</span>
        {sub && <span className="mk-br-s mk-mono">{sub}</span>}
      </span>
    </button>
  )
}
