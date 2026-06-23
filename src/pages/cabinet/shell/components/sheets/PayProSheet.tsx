// AgOS · Этап 1 · Шторка подписки Platform Pro (shell/app.jsx kind="paypro").
// Тексты — слово в слово из прототипа.

import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import { NBSP } from '../../store'

const BENEFITS = [
  'Безлимитные запросы к Консультанту',
  'Глубокая аналитика стада',
  'Экспорт отчётов и рационов',
]
const METHODS: [string, string][] = [
  ['Kaspi Pay', 'быстрая оплата'],
  ['Банковская карта', 'Visa, Mastercard'],
]

export function PayProSheet({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  return (
    <Sheet open onClose={onClose}>
      <div className="sh-t">Platform Pro</div>
      <div className="sh-b">Личная подписка. Открывает Консультанта TURAN — AI-зоотехника без ограничений.</div>
      <div className="gate-list" style={{ margin: '2px 0 10px' }}>
        {BENEFITS.map((t) => (
          <div className="gate-row" key={t}><span className="gate-ck">✓</span><span>{t}</span></div>
        ))}
      </div>
      <div className="win-sum" style={{ marginTop: 0 }}>
        <div className="ws-hint mono">ПОДПИСКА</div>
        <div className="ws-big" style={{ fontSize: 22 }}>4 900{NBSP}₸ / мес</div>
      </div>
      <div className="ws-hint" style={{ margin: '8px 2px 4px', color: 'var(--ink-3)', lineHeight: 1.4 }}>
        Не открывает Рынок — для продажи скота нужно членство организации.
      </div>
      <div className="blk-h mono" style={{ margin: '10px 0 6px' }}>СПОСОБ ОПЛАТЫ</div>
      <div className="stack8">
        {METHODS.map((m) => (
          <button key={m[0]} className="big-radio" onClick={onDone}>
            <span className="br-dot" />
            <span><span className="br-t">{m[0]}</span><span className="br-s">{m[1]}</span></span>
          </button>
        ))}
      </div>
      <Cta variant="primary-green" onClick={onDone}>Подключить Pro · 4 900{NBSP}₸/мес</Cta>
      <Cta variant="ghost" onClick={onClose}>Позже</Cta>
    </Sheet>
  )
}
