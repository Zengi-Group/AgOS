// AgOS · Этап 2 · Грид сервисов — ЯКОРЬ зоны 3 (shell/ui.jsx ServiceGrid).

import { ShIc } from './icons/ShIc'
import type { IconKey } from './icons/ShIc'
import { SHELL_SERVICES, type ServiceDef } from '../data/banners'

export function ServiceGrid({ onOpen }: { onOpen: (s: ServiceDef) => void }) {
  return (
    <div className="svc-grid" data-screen-label="грид сервисов — якорь">
      {SHELL_SERVICES.map((s) => (
        <button
          key={s.k}
          className={'svc' + (s.green ? ' green' : '') + (s.soon ? ' soon' : '')}
          onClick={s.soon ? undefined : () => onOpen(s)}
          disabled={!!s.soon}
        >
          <span className="svc-ic"><ShIc k={s.ic as IconKey} size={19} /></span>
          <span className="svc-t">{s.t}</span>
          {s.soon && <span className="svc-soon mono">скоро</span>}
        </button>
      ))}
    </div>
  )
}
