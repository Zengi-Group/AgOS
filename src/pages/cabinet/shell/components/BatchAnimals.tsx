// AgOS · TSP · ARS-228 · Секция «Детализация по животным» карточки партии.
// Манифест продажи по ИНЖ — строго per-batch (не herd-реестр, граница D20). Заполнение
// опционально (P11); агрегат heads — источник правды, строки могут быть меньше heads.
// Добавление/редактирование/удаление — владельцу в статусах draft|published; иначе
// только просмотр. Канон: PhIcon-only, плоские строки, тактильный отклик R-28.

import { useState } from 'react'
import { Sheet } from './Sheet'
import { Cta } from './Cta'
import { PhIcon } from './icons/PhIcon'
import { useBatchAnimals, type BatchAnimal, type BatchAnimalInput, type AnimalSex } from '../hooks/useBatchAnimals'

interface BatchAnimalsProps {
  batchId: string
  orgId: string | null | undefined
  editable: boolean               // статус draft|published + владелец
  heads?: number                  // агрегат партии — для мягкой подсказки о дрейфе
  toast?: (text: string) => void
}

const SEX_LABEL: Record<AnimalSex, string> = { m: 'бычок', f: 'тёлка' }

function attrLine(a: BatchAnimal): string {
  const parts: string[] = []
  if (a.weightKg != null) parts.push(`${a.weightKg} кг`)
  if (a.sex) parts.push(SEX_LABEL[a.sex])
  if (a.ageMonths != null) parts.push(`${a.ageMonths} мес`)
  return parts.join(' · ')
}

// ── Шторка добавления/редактирования одного животного ────────────────────────
function AnimalSheet({ open, initial, saving, onClose, onSave }: {
  open: boolean
  initial: BatchAnimal | null
  saving: boolean
  onClose: () => void
  onSave: (input: BatchAnimalInput) => void
}) {
  const [inzh, setInzh] = useState('')
  const [weight, setWeight] = useState('')
  const [sex, setSex] = useState<AnimalSex | null>(null)
  const [age, setAge] = useState('')
  const [note, setNote] = useState('')
  // Сброс полей при каждом открытии (по initial).
  const [seed, setSeed] = useState<string | null>(null)
  const key = (initial?.id ?? 'new') + String(open)
  if (open && seed !== key) {
    setSeed(key)
    setInzh(initial?.inzhNumber ?? '')
    setWeight(initial?.weightKg != null ? String(initial.weightKg) : '')
    setSex(initial?.sex ?? null)
    setAge(initial?.ageMonths != null ? String(initial.ageMonths) : '')
    setNote(initial?.notes ?? '')
  }

  const save = () => {
    const w = parseFloat(weight.replace(',', '.'))
    const ag = parseInt(age, 10)
    onSave({
      inzhNumber: inzh.trim() || null,
      weightKg:   Number.isFinite(w) && w > 0 ? w : null,
      sex:        sex,
      ageMonths:  Number.isFinite(ag) && ag >= 0 ? ag : null,
      notes:      note.trim() || null,
    })
  }

  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t">{initial ? 'Изменить животное' : 'Добавить животное'}</div>
      <div className="sh-b">Все поля необязательны — заполняйте, что знаете.</div>

      <label className="mk-field">
        <span className="mk-lab">ИНЖ / номер бирки</span>
        <input className="mk-input mono" value={inzh} placeholder="напр. KZ0123456789"
          onChange={(e) => setInzh(e.target.value)} />
      </label>

      <label className="mk-field">
        <span className="mk-lab">Вес, кг</span>
        <input className="mk-input mono" inputMode="decimal" value={weight} placeholder="—"
          onChange={(e) => setWeight(e.target.value.replace(/[^\d.,]/g, '').slice(0, 7))} />
      </label>

      <div className="mk-field">
        <span className="mk-lab">Пол</span>
        <div className="mk-anml-sex">
          {(['m', 'f'] as AnimalSex[]).map((s) => (
            <button key={s} type="button"
              className={'mk-anml-sexb' + (sex === s ? ' on' : '')}
              onClick={() => setSex(sex === s ? null : s)}>
              {SEX_LABEL[s]}
            </button>
          ))}
        </div>
      </div>

      <label className="mk-field">
        <span className="mk-lab">Возраст, мес</span>
        <input className="mk-input mono" inputMode="numeric" value={age} placeholder="—"
          onChange={(e) => setAge(e.target.value.replace(/\D/g, '').slice(0, 3))} />
      </label>

      <label className="mk-field">
        <span className="mk-lab">Заметка</span>
        <input className="mk-input" value={note} placeholder="напр. комолая"
          onChange={(e) => setNote(e.target.value)} />
      </label>

      <Cta onClick={save} disabled={saving}>{initial ? 'Сохранить' : 'Добавить'}</Cta>
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}

export function BatchAnimals({ batchId, orgId, editable, heads, toast }: BatchAnimalsProps) {
  const { items, loading, saving, canUse, add, update, remove } = useBatchAnimals(batchId, orgId, toast)
  const [sheetOpen, setSheetOpen] = useState(false)
  const [editing, setEditing] = useState<BatchAnimal | null>(null)

  // Нет backend/локальная демо-партия — секции нет. Пусто и нельзя редактировать — тоже.
  if (!canUse) return null
  if (items.length === 0 && !editable && !loading) return null

  const openAdd = () => { setEditing(null); setSheetOpen(true) }
  const openEdit = (a: BatchAnimal) => { setEditing(a); setSheetOpen(true) }
  const onSave = async (input: BatchAnimalInput) => {
    const ok = editing ? await update(editing.id, input) : await add(input)
    if (ok) setSheetOpen(false)
  }

  // Мягкая подсказка о дрейфе: строк больше, чем голов в партии (heads — источник правды).
  const overCount = typeof heads === 'number' && heads > 0 && items.length > heads

  return (
    <div className="blk">
      <div className="tier-h">
        <span className="tier-h-l">
          <span className="tier-label">ДЕТАЛИЗАЦИЯ ПО ЖИВОТНЫМ</span>
          {items.length > 0 && <span className="tier-count mk-mono">{items.length}</span>}
        </span>
      </div>

      <div className="mk-anml">
        {items.map((a) => (
          <div key={a.id} className={'mk-anml-row' + (editable ? ' ed' : '')}
            onClick={editable ? () => openEdit(a) : undefined}>
            <span className="mk-anml-ic"><PhIcon name="cow" size={16} /></span>
            <div className="mk-anml-bd">
              <div className="mk-anml-t mk-mono">{a.inzhNumber || 'без ИНЖ'}</div>
              {attrLine(a) && <div className="mk-anml-m">{attrLine(a)}</div>}
              {a.notes && <div className="mk-anml-note">{a.notes}</div>}
            </div>
            {editable && (
              <button type="button" className="mk-anml-del" aria-label="Удалить"
                onClick={(e) => { e.stopPropagation(); remove(a.id) }}>
                <PhIcon name="trash" size={15} />
              </button>
            )}
          </div>
        ))}

        {editable && (
          <button type="button" className="mk-anml-add" onClick={openAdd}>
            <PhIcon name="plus" size={16} />
            <span>Добавить животное</span>
          </button>
        )}

        {editable && items.length === 0 && !loading && (
          <div className="mk-anml-hint">Опишите животных по ИНЖ — это помогает покупателю. Необязательно.</div>
        )}
        {overCount && (
          <div className="mk-anml-hint warn">Детализировано {items.length} — больше, чем голов в партии ({heads}).</div>
        )}
      </div>

      {editable && (
        <AnimalSheet
          open={sheetOpen}
          initial={editing}
          saving={saving}
          onClose={() => setSheetOpen(false)}
          onSave={onSave}
        />
      )}
    </div>
  )
}
