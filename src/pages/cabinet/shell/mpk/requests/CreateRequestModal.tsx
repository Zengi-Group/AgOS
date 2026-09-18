// AgOS · Slice11 (ARS-718) · SCR-R3 — заведение заявки с десктопа (FR-024).
//
// Пишет ТОЙ ЖЕ парой RPC, что мобильная форма (`pool-actions.createPoolRequest`), без
// второй ветки создания на клиенте (`P4`). Пол цены, лимиты строк и прочие правила
// проверяет база; форма лишь не даёт отправить заведомо неполное и показывает причину
// отказа, а не «что-то пошло не так» (M-020).

import { useEffect, useState } from 'react'
import { REGIONS, DISTRICTS } from '@/pages/registration/constants'
import { BREEDS } from '@/pages/cabinet/shell/tsp/data/tsp-dicts'
import { useGradeFormula } from '@/hooks/useGradeFormula'
import { PhIcon } from '../../components/icons/PhIcon'
import { createPoolRequest } from '../data/pool-actions'
import { MPK_CATS, mpkCatFloor, mpkCatName, type MpkCatKey } from '../types'

interface Props {
  organizationId: string
  onClose: () => void
  /** Успех: заявка заведена и опубликована. Вызывающий перечитывает список. */
  onCreated: (poolId: string) => void
}

interface FormLine { catKey: MpkCatKey; price: number; maxHeads?: number; breed: string }

// Окно поставки → первый день целевого месяца. Строка собирается из ЛОКАЛЬНЫХ компонент:
// `toISOString()` сдвигает локальную полночь 1-го числа в UTC и при UTC+5 откатывает дату
// на конец прошлого месяца — заявка рождалась просроченной. Тот же приём, что в мобильной
// форме; правило одно, домов пока два (см. `IMPL_DEBT`, `MPK-POOL-RPC-TWO-HOMES-01`).
function monthToDate(offset: number): string {
  const d = new Date()
  d.setMonth(d.getMonth() + offset, 1)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}

const MONTHS: { offset: number; label: string }[] = [
  { offset: 0, label: 'Этот месяц' },
  { offset: 1, label: 'Следующий' },
  { offset: 2, label: 'Через 2 месяца' },
]

const CAT_KEYS = Object.keys(MPK_CATS) as MpkCatKey[]

export function CreateRequestModal({ organizationId, onClose, onCreated }: Props) {
  useGradeFormula()
  const [heads, setHeads] = useState('')
  const [monthOffset, setMonthOffset] = useState<number | null>(null)
  const [regionIds, setRegionIds] = useState<string[]>([])
  const [districtIds, setDistrictIds] = useState<string[]>([])
  const [lines, setLines] = useState<FormLine[]>([{ catKey: 'vysshaya', price: 0, breed: '' }])
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const headsNum = parseInt(heads, 10)
  const headsValid = !Number.isNaN(headsNum) && headsNum > 0
  const allocated = lines.reduce((s, l) => s + (l.maxHeads ?? 0), 0)
  const overCapacity = headsValid && allocated > headsNum
  const priceOk = lines.every((l) => l.price >= mpkCatFloor(l.catKey))
  const canPublish = headsValid && monthOffset !== null && lines.length > 0 && priceOk && !overCapacity

  const toggleRegion = (id: string) =>
    setRegionIds((ids) => {
      if (ids.includes(id)) {
        const slugs = (DISTRICTS[id] ?? []).map((d) => d.value)
        setDistrictIds((ds) => ds.filter((s) => !slugs.includes(s)))
        return ids.filter((x) => x !== id)
      }
      return [...ids, id]
    })

  const patchLine = (i: number, patch: Partial<FormLine>) =>
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)))

  const publish = () => {
    if (!canPublish || saving) return
    setSaving(true)
    setError(null)
    createPoolRequest({
      organizationId,
      totalHeads: headsNum,
      targetMonth: monthToDate(monthOffset ?? 0),
      regionIds,
      districtIds,
      lines: lines.map((l) => ({
        code: l.catKey,
        price: l.price,
        maxHeads: l.maxHeads ?? null,
        breed: l.breed || null,
      })),
    })
      .then((poolId) => onCreated(poolId))
      .catch((e) => {
        // M-020: причина названа, модалка остаётся открытой, в список ничего не добавляем —
        // список перечитывается из базы, а не дорисовывается на клиенте.
        setError(e instanceof Error ? e.message : 'Не удалось создать заявку')
        setSaving(false)
      })
  }

  // Esc закрывает модалку — привычный жест; без него `stopPropagation` ниже защищал от
  // клика, которого никто не обрабатывал.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !saving) onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose, saving])

  return (
    <div
      className="mpkr-scrim"
      role="dialog"
      aria-modal="true"
      aria-label="Новая заявка на закупку"
      onClick={() => { if (!saving) onClose() }}
    >
      <div className="mpkr-modal" onClick={(e) => e.stopPropagation()}>
        <div className="mpkr-modal-head">
          <div className="mpkr-modal-title">Новая заявка на закупку</div>
          <button type="button" className="mpkr-modal-x" onClick={onClose} aria-label="Закрыть">
            <PhIcon name="x" size={16} />
          </button>
        </div>

        <div className="mpkr-modal-body">
          <label className="mpkr-field-l" htmlFor="mpkr-heads">Общий объём закупа, голов</label>
          <input
            id="mpkr-heads"
            className="mpkr-input"
            inputMode="numeric"
            value={heads}
            placeholder="Сколько голов"
            // Только цифры: `parseInt('12abc')` дал бы 12 — в поле одно, в базе другое
            // (FR-022). Отбрасываем лишнее сразу, чтобы оператор видел, что записано.
            onChange={(e) => setHeads(e.target.value.replace(/\D/g, ''))}
          />

          <div className="mpkr-field-l">Месяц поставки</div>
          <div className="mpkr-chips">
            {MONTHS.map((m) => (
              <button
                key={m.offset}
                type="button"
                className={`mpkr-chip${monthOffset === m.offset ? ' on' : ''}`}
                onClick={() => setMonthOffset(m.offset)}
              >
                {m.label}
              </button>
            ))}
          </div>

          <div className="mpkr-field-l">География закупа</div>
          <div className="mpkr-geo">
            {REGIONS.map((r) => {
              const on = regionIds.includes(r.id)
              const districts = DISTRICTS[r.id] ?? []
              return (
                <div key={r.id}>
                  <button
                    type="button"
                    className={`mpkr-chip${on ? ' on' : ''}`}
                    onClick={() => toggleRegion(r.id)}
                  >
                    {r.name}
                  </button>
                  {on && districts.length > 0 && (
                    <div className="mpkr-geo-sub">
                      {districts.map((d) => (
                        <button
                          key={d.value}
                          type="button"
                          className={`mpkr-chip sm${districtIds.includes(d.value) ? ' on' : ''}`}
                          onClick={() => setDistrictIds((ds) =>
                            ds.includes(d.value) ? ds.filter((x) => x !== d.value) : [...ds, d.value])}
                        >
                          {d.label}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
          <div className="mpkr-hint">
            Не выбрано — все области. Районы сужают область: партия подойдёт, только если её
            район в списке.
          </div>

          <div className="mpkr-field-l">Категории и цены</div>
          {lines.map((l, i) => {
            const floor = mpkCatFloor(l.catKey)
            const below = l.price < floor
            return (
              <div className="mpkr-line-edit" key={i}>
                <select
                  className="mpkr-input"
                  aria-label="Категория"
                  value={l.catKey}
                  onChange={(e) => patchLine(i, { catKey: e.target.value as MpkCatKey })}
                >
                  {CAT_KEYS.map((k) => <option key={k} value={k}>{mpkCatName(k)}</option>)}
                </select>
                <input
                  className={`mpkr-input${below ? ' bad' : ''}`}
                  inputMode="numeric"
                  aria-label="Цена ₸/кг"
                  placeholder="Цена ₸/кг"
                  value={l.price || ''}
                  onChange={(e) => patchLine(i, { price: parseInt(e.target.value, 10) || 0 })}
                />
                <input
                  className="mpkr-input"
                  inputMode="numeric"
                  aria-label="Предел голов"
                  placeholder="Макс. голов"
                  value={l.maxHeads ?? ''}
                  onChange={(e) => {
                    const v = parseInt(e.target.value, 10)
                    patchLine(i, { maxHeads: Number.isNaN(v) ? undefined : v })
                  }}
                />
                <select
                  className="mpkr-input"
                  aria-label="Порода"
                  value={l.breed}
                  onChange={(e) => patchLine(i, { breed: e.target.value })}
                >
                  <option value="">Любая порода</option>
                  {BREEDS.map((b) => <option key={b} value={b}>{b}</option>)}
                </select>
                {lines.length > 1 && (
                  <button
                    type="button"
                    className="mpkr-line-del"
                    aria-label="Удалить строку"
                    onClick={() => setLines((ls) => ls.filter((_, idx) => idx !== i))}
                  >
                    <PhIcon name="x" size={14} />
                  </button>
                )}
                {below && (
                  <div className="mpkr-bad-hint">
                    {l.price > 0 ? `Минимум ${floor} ₸/кг` : `Укажите цену — минимум ${floor} ₸/кг`}
                  </div>
                )}
              </div>
            )
          })}
          <button
            type="button"
            className="mpkr-add-line"
            onClick={() => setLines((ls) => [...ls, { catKey: 'pervaya', price: 0, breed: '' }])}
          >
            <PhIcon name="plus" size={13} /> Добавить строку
          </button>

          {overCapacity && (
            <div className="mpkr-bad-hint">
              Сумма «Макс. голов» ({allocated}) больше объёма закупа ({headsNum}).
            </div>
          )}
          {/* Выключенная кнопка обязана объяснить себя: иначе оператор видит «Опубликовать»
              серым и не знает, чего не хватает — тот же класс, что M-008. */}
          {!canPublish && !saving && (
            <div className="mpkr-hint">
              Чтобы опубликовать: {[
                !headsValid ? 'укажите объём закупа' : null,
                monthOffset === null ? 'выберите месяц поставки' : null,
                !priceOk ? 'поднимите цены до минимума' : null,
                overCapacity ? 'уменьшите пределы голов' : null,
              ].filter(Boolean).join(' · ')}
            </div>
          )}
          {error && <div className="mpkr-flash bad" role="alert">Заявка не заведена: {error}</div>}
        </div>

        <div className="mpkr-modal-foot">
          <button type="button" className="mpkc-stub-act" onClick={onClose}>Отмена</button>
          <button
            type="button"
            className="mpkc-stub-act primary"
            disabled={!canPublish || saving}
            onClick={publish}
          >
            {saving ? 'Публикуем…' : 'Опубликовать заявку'}
          </button>
        </div>
      </div>
    </div>
  )
}
