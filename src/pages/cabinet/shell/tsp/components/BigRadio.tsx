// AgOS · TSP-1 · Большой радио-выбор с подзаголовком (p1/ui.jsx BigRadio).

export function BigRadio({ sel, onClick, title, sub }: { sel: boolean; onClick: () => void; title: string; sub?: string }) {
  return (
    <button className={'big-radio' + (sel ? ' sel' : '')} onClick={onClick}>
      <span className={'br-dot' + (sel ? ' on' : '')} />
      <span className="br-body">
        <span className="br-t">{title}</span>
        {sub && <span className="br-s">{sub}</span>}
      </span>
    </button>
  )
}
