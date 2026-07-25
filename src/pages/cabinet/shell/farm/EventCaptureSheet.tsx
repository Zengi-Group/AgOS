// AgOS · ARS-300/301/302/303 (Ферма 2.0 · Захват «Записать событие») · Диспетчер-роутер захвата.
// Канон: Docs/AGOS-Ferma2-EventCapture-EngSpec-v0_1.md.
// CAP-1: глобальный CTA (монтируется как IonShellFrame footer = .sh-foot, аддитивно P7) + шторка
//   плиток. Плитки = ДИСПЕТЧЕР: каждая ведёт в свой дом по типу факта (§3), не плоский журнал.
// CAP-2 «Проблема» = reuse DeviationForm (то же тело «кто→что», что в «Обходе» — P4, ноль нового
//   кода в ядре) → rpc_log_animal_event.
// CAP-3 «Лечение» = наблюдение + эскалация в vet_case (createVetCaseFromEvent). Пути «лечение
//   применено» фермером НЕТ (treatment_logs без писателей, дозы D61) → «Лечение» = «нужен ветврач».
// Плитки жизненного цикла (Отёл/Падёж/Перевод/Взвешивание/Осеменение) пишут herd_events отдельным
//   не-walkthrough путём (D147) — спроектированы, отложены (ARS-305..310) → заглушки «скоро».
// Голос — EPIC-VOICE (ARS-310, Dok5 two-run): место mic зарезервировано, действие отложено.
// Иконки — PhIcon (Phosphor), не инлайн-SVG (D-UI-FARMER-RULES-01); mk-mono только цифры.

import { useState } from 'react'
import { PhIcon, type PhIconName } from '../components/icons/PhIcon'
import { Sheet } from '../components/Sheet'
import { DeviationForm } from './HerdScreen'
import { createVetCaseFromEvent } from './data/farm-herd'

interface Tile {
  k: string
  t: string
  icon: PhIconName
  sub?: string
  accent?: boolean
  active?: boolean   // true → реализовано (CAP-2/3); иначе «скоро» (спроектировано, ARS-305..310)
}

const TILES: Tile[] = [
  { k: 'problem', t: 'Проблема', icon: 'alert', sub: 'болезнь, травма, «что-то не так»', accent: true, active: true },
  { k: 'treat', t: 'Лечение', icon: 'firstAid', sub: 'нужен ветврач', active: true },
  { k: 'calving', t: 'Отёл', icon: 'cow' },
  { k: 'weigh', t: 'Взвешивание', icon: 'scales' },
  { k: 'move', t: 'Перевод', icon: 'arrowLeftRight' },
  { k: 'death', t: 'Падёж', icon: 'skull' },
  { k: 'insem', t: 'Осеменение', icon: 'syringe' },
  { k: 'add', t: 'Добавить', icon: 'plus', sub: 'группу или животное' },
]

type View = 'tiles' | 'problem' | 'treat'

export function FarmEventCapture({ orgId, farmId, toast, onRecorded }: {
  orgId: string
  farmId: string
  toast: (text: string) => void
  onRecorded?: () => void
}) {
  const [open, setOpen] = useState(false)
  const [view, setView] = useState<View>('tiles')

  const close = () => { setOpen(false); setView('tiles') }

  // «Лечение»: событие уже записано (DeviationForm.onDone) → сразу эскалируем в vet_case (§4.2).
  // Ошибка эскалации не теряет наблюдение — оно уже в animal_events (open) и в «Требует внимания».
  const escalate = async (_eventId: string, tag: string) => {
    try {
      const r = await createVetCaseFromEvent(orgId, _eventId)
      toast(r.ok === false ? `№${tag} записано — случай открыть не удалось` : `Случай ветврачу открыт · №${tag}`)
    } catch {
      toast(`№${tag} записано — случай открыть не удалось`)
    }
    close()
    onRecorded?.()
  }

  return (
    <>
      <button className="fm-cap-cta" onClick={() => setOpen(true)}>
        <PhIcon name="plus" size={18} />
        <span>Записать событие</span>
        <span className="fm-cap-cta-mic"><PhIcon name="mic" size={16} /></span>
      </button>

      <Sheet open={open} onClose={close}>
        {view === 'tiles' && (
          <>
            <div className="sh-t">Записать событие</div>
            <div className="fm-cap-grid">
              {TILES.map((tl) => (
                <button
                  key={tl.k}
                  className={'fm-cap-tile' + (tl.accent ? ' accent' : '') + (tl.active ? '' : ' soon')}
                  disabled={!tl.active}
                  onClick={tl.active ? () => setView(tl.k as View) : undefined}
                >
                  <span className="fm-cap-tile-ic"><PhIcon name={tl.icon} size={22} /></span>
                  <span className="fm-cap-tile-t">{tl.t}</span>
                  {tl.sub && <span className="fm-cap-tile-s">{tl.sub}</span>}
                  {!tl.active && <span className="fm-cap-tile-soon">скоро</span>}
                </button>
              ))}
            </div>
            <div className="fm-cap-voice">
              <span className="fm-cap-voice-ic"><PhIcon name="mic" size={15} /></span>
              <span>Голосом — скоро: «отелилась триста сорок седьмая…»</span>
            </div>
            <div className="fm-cap-foot">Запись создаёт событие в «Требует внимания». Отметка обхода — на табе «Стадо».</div>
          </>
        )}

        {view === 'problem' && (
          <DeviationForm
            orgId={orgId}
            farmId={farmId}
            animalsRecent={[]}
            onCancel={() => setView('tiles')}
            onDone={(_id, tag) => { toast(`Записано · №${tag}`); close(); onRecorded?.() }}
          />
        )}

        {view === 'treat' && (
          <>
            <div className="sh-b">Опишите, что с животным — сразу откроем случай ветврачу.</div>
            <DeviationForm
              orgId={orgId}
              farmId={farmId}
              animalsRecent={[]}
              onCancel={() => setView('tiles')}
              onDone={escalate}
            />
          </>
        )}
      </Sheet>
    </>
  )
}
