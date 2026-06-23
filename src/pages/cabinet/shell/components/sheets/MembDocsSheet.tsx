// AgOS · Этап 1 · Сбор документов для членства (shell/cabinet.jsx MembDocsSheet).
// Тексты — слово в слово из прототипа. Рег.документ (ТОО/ИП) · удостоверение · контакты · гео · согласие · оплата.

import { useState } from 'react'
import { Sheet } from '../Sheet'
import { Cta } from '../Cta'

function Seg2({ items, value, onPick }: { items: [string, string][]; value: string; onPick: (v: string) => void }) {
  return (
    <div className="seg2">
      {items.map(([v, label]) => (
        <button key={v} className={'seg2-b' + (value === v ? ' on' : '')} onClick={() => onPick(v)}>
          {label}
        </button>
      ))}
    </div>
  )
}

type GeoState = null | 'locating' | { coords: string; region: string }

interface Slot {
  key: string
  kind: 'upload' | 'contacts' | 'geo' | 'consent' | 'payment'
  req?: boolean
  name: string
  hint?: string
}

export function MembDocsSheet({ onClose, onSubmit }: { onClose: () => void; onSubmit: () => void }) {
  const [legal, setLegal] = useState('ТОО')
  const [up, setUp] = useState<Record<string, boolean>>({})
  const [phone, setPhone] = useState('+7 705 4')
  const [email, setEmail] = useState('')
  const [geo, setGeo] = useState<GeoState>(null)
  const located = geo && geo !== 'locating'
  const contactsOk = phone.replace(/\D/g, '').length >= 10 && /@/.test(email)

  const regMeta = legal === 'ТОО'
    ? { name: 'Документ о гос. регистрации (с БИН)', hint: 'Копия с указанием БИН' }
    : { name: 'Свидетельство / талон ИП', hint: 'Талон уведомления о начале деятельности' }

  const slots: Slot[] = [
    { key: 'reg', kind: 'upload', req: true, name: regMeta.name, hint: regMeta.hint },
    { key: 'id', kind: 'upload', req: true, name: 'Удостоверение личности руководителя', hint: 'Лицевая и обратная сторона' },
    { key: 'contacts', kind: 'contacts', req: true, name: 'Контактные данные' },
    { key: 'geo', kind: 'geo', req: true, name: 'Геолокация фермы' },
    { key: 'consent', kind: 'consent', req: true, name: 'Согласие на обработку данных' },
    { key: 'pay', kind: 'payment', name: 'Документ об оплате взноса', hint: 'Загрузится после оплаты взноса' },
  ]

  const isDone = (s: Slot) =>
    s.kind === 'contacts' ? contactsOk : s.kind === 'geo' ? !!located : !!up[s.key]
  const counted = slots.filter((s) => s.kind !== 'payment')
  const total = counted.length
  const doneCount = counted.filter(isDone).length
  const canSubmit = counted.filter((s) => s.req).every(isDone)
  const locate = () => {
    setGeo('locating')
    setTimeout(() => setGeo({ coords: '51.1605° N · 71.4704° E', region: 'Акмолинская' }), 900)
  }
  const toggle = (k: string) => setUp((p) => ({ ...p, [k]: !p[k] }))

  const slotRow = (s: Slot) => {
    const done = isDone(s)
    if (s.kind === 'payment')
      return (
        <div className="cb-row" key={s.key} style={{ opacity: 0.55 }}>
          <span className="cb-box" style={{ borderColor: 'var(--ink-4)' }} />
          <span style={{ flex: 1 }}><b style={{ fontSize: 12.5 }}>{s.name}</b><div className="hint-inline">{s.hint}</div></span>
          <span className="hint-inline mono" style={{ alignSelf: 'center' }}>после оплаты</span>
        </div>
      )
    if (s.kind === 'consent')
      return (
        <button className="cb-row" key={s.key} onClick={() => toggle(s.key)}>
          <span className={'cb-box' + (done ? ' ch' : '')}>{done ? '✓' : ''}</span>
          <span style={{ flex: 1 }}>{s.name} · <span style={{ textDecoration: 'underline' }}>читать</span></span>
        </button>
      )
    if (s.kind === 'contacts')
      return (
        <div className="cb-row" key={s.key} style={{ flexDirection: 'column', gap: 7, alignItems: 'stretch' }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <span className={'cb-box' + (done ? ' ch' : '')}>{done ? '✓' : ''}</span>
            <b style={{ fontSize: 12.5 }}>{s.name} *</b>
          </div>
          <input className="finput" inputMode="tel" placeholder="+7 ___ ___ __ __" value={phone} onChange={(e) => setPhone(e.target.value)} style={{ fontSize: 14 }} />
          <input className="finput" inputMode="email" placeholder="email@example.kz" value={email} onChange={(e) => setEmail(e.target.value)} style={{ fontSize: 14, fontWeight: 400 }} />
        </div>
      )
    if (s.kind === 'geo')
      return (
        <div className="cb-row" key={s.key} style={{ flexDirection: 'column', gap: 7, alignItems: 'stretch' }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <span className={'cb-box' + (done ? ' ch' : '')}>{done ? '✓' : ''}</span>
            <b style={{ fontSize: 12.5 }}>{s.name} *</b>
          </div>
          {located ? (
            <div className="hint-inline mono" style={{ color: 'var(--ok)' }}>
              {(geo as { coords: string; region: string }).coords} · {(geo as { coords: string; region: string }).region} обл.
            </div>
          ) : (
            <button className="cta ghost" style={{ marginTop: 0, padding: 9, fontSize: 12.5 }} disabled={geo === 'locating'} onClick={locate}>
              {geo === 'locating' ? 'Определяем…' : 'Определить по GPS'}
            </button>
          )}
        </div>
      )
    // upload
    return (
      <button className="cb-row" key={s.key} onClick={() => toggle(s.key)}>
        <span className={'cb-box' + (done ? ' ch' : '')}>{done ? '✓' : ''}</span>
        <span style={{ flex: 1 }}><b style={{ fontSize: 12.5 }}>{s.name} *</b><div className="hint-inline">{done ? 'Загружено · нажмите чтобы убрать' : s.hint}</div></span>
      </button>
    )
  }

  return (
    <Sheet open onClose={onClose}>
      <div className="sh-t">Документы для членства</div>
      <div className="sh-b">Заявка в ассоциацию ТУРАН. Прикрепите документы — после одобрения откроется оплата взноса и Рынок (TSP).</div>
      <div style={{ maxHeight: 430, overflowY: 'auto', margin: '0 -2px' }}>
        <div className="field" style={{ marginBottom: 8 }}>
          <div className="lab">Форма организации</div>
          <Seg2 items={[['ТОО', 'ТОО'], ['ИП', 'ИП']]} value={legal} onPick={setLegal} />
        </div>
        <div className="blk-h mono" style={{ padding: '4px 2px 2px' }}>
          <span>ДОКУМЕНТЫ</span>
          <span style={{ color: doneCount >= total ? 'var(--ok)' : 'var(--ink-3)', fontWeight: 700 }}>{doneCount} / {total} готово</span>
        </div>
        <div className="progress" style={{ padding: '2px 2px 4px' }}>
          {counted.map((s, i) => <div key={i} className={isDone(s) ? 'done' : ''} />)}
        </div>
        {slots.map(slotRow)}
      </div>
      <Cta variant="primary-green" disabled={!canSubmit} onClick={canSubmit ? onSubmit : undefined}>Отправить на проверку</Cta>
      {!canSubmit && <div className="footnote">Заполните обязательные пункты (*)</div>}
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}
