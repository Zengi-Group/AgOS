// AgOS · TSP-1 · Селект модуля «Рынок» (порт market-ui.jsx MkSelect) — триггер .mk-seltrig
// + нижний пикер .mk-pick* (паттерн ДС: не нативный OS-дропдаун). onChange отдаёт
// { target: { value } } — совместимо с прежним <select onChange>.

import { useEffect, useRef, useState } from 'react'
import { MkField } from './MkField'
import { PhIcon } from '../../components/icons/PhIcon'

type Opt = string | { value: string; label: string }

interface MkSelectProps {
  value: string
  onChange: (e: { target: { value: string } }) => void
  options: Opt[]
  placeholder?: string
  label?: string
  hint?: string
  miss?: boolean
  // Строка поиска: авто для длинных списков (район/порода 20+), можно форсировать.
  searchable?: boolean
}

// Порог, с которого справочник получает строку поиска (короткие списки — без неё).
const MK_SEARCH_AT = 8
function mkNorm(s: string) { return (s || '').toString().toLowerCase().replace(/ё/g, 'е').trim() }

export function MkSelect({ value, onChange, options, placeholder, label, hint, miss, searchable }: MkSelectProps) {
  const [open, setOpen] = useState(false)
  const [q, setQ] = useState('')
  const searchRef = useRef<HTMLInputElement>(null)
  const opts = options.map((o) => (typeof o === 'object' ? o : { value: o, label: o }))
  const sel = opts.find((o) => o.value === value)
  const withSearch = searchable !== false && (searchable === true || opts.length > MK_SEARCH_AT)
  const nq = mkNorm(q)
  const shown = nq ? opts.filter((o) => mkNorm(o.label).includes(nq)) : opts
  const pick = (v: string) => { onChange({ target: { value: v } }); setOpen(false) }
  const openSheet = () => { setQ(''); setOpen(true) }
  useEffect(() => {
    if (open && withSearch) {
      const t = setTimeout(() => searchRef.current?.focus(), 260)
      return () => clearTimeout(t)
    }
  }, [open, withSearch])

  return (
    <MkField label={label} hint={hint} miss={miss}>
      <button type="button" className={'mk-seltrig' + (sel ? '' : ' is-ph') + (open ? ' open' : '')}
        aria-haspopup="listbox" aria-expanded={open} onClick={openSheet}>
        <span className="mk-seltrig-v">{sel ? sel.label : (placeholder || 'Выберите')}</span>
        <span className="mk-seltrig-ch"><PhIcon name="chevronRight" size={15} style={{ transform: 'rotate(90deg)' }} /></span>
      </button>
      {open && (
        <div className="mk-pick-scrim" onClick={() => setOpen(false)}>
          <div className="mk-pick" role="listbox" onClick={(e) => e.stopPropagation()}>
            <div className="mk-pick-grip" />
            {label && <div className="mk-pick-h">{label}</div>}
            {withSearch && (
              <div className="mk-pick-search">
                <span className="mk-pick-search-ic"><PhIcon name="search" size={16} /></span>
                <input ref={searchRef} className="mk-pick-search-in" type="text" inputMode="search"
                  value={q} onChange={(e) => setQ(e.target.value)} placeholder="Поиск по справочнику"
                  aria-label="Поиск по справочнику" />
                {q && (
                  <button type="button" className="mk-pick-search-x" aria-label="Очистить"
                    onClick={() => { setQ(''); searchRef.current?.focus() }}>
                    <PhIcon name="x" size={15} />
                  </button>
                )}
              </div>
            )}
            <div className="mk-pick-list">
              {shown.map((o) => {
                const on = o.value === value
                return (
                  <button type="button" key={o.value} role="option" aria-selected={on}
                    className={'mk-pick-opt' + (on ? ' on' : '')} onClick={() => pick(o.value)}>
                    <span className="mk-pick-opt-l">{o.label}</span>
                    {on && <PhIcon name="check" size={17} color="var(--green)" />}
                  </button>
                )
              })}
              {shown.length === 0 && <div className="mk-pick-empty">Ничего не найдено по «{q.trim()}»</div>}
            </div>
          </div>
        </div>
      )}
    </MkField>
  )
}
