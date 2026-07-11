// AgOS · ARS-212 · SCR-F6 (генерация) + SCR-F7 (финал без плана) + SCR-F8 (финал «план готов»,
// ARS-215). Порог достигнут → F6-лоадер (паттерн PubResult.searching, ротация фраз), во время
// которого срабатывает хэндофф генерации draft-ЦТК (ARS-213, graceful). Финал ветвится по
// результату: план создан → F8 «План работ на год готов» + CTA «Посмотреть план» (→ таб «Ферма»,
// state C); не создан (ниже порога / RPC недоступен / ошибка) → F7 «Стадо записано» (D-FW-5:
// финал без плана — тоже награда). Ниже порога / skip → сразу F7 + link «Ответить сейчас».

import { useEffect, useState } from 'react'
import { IonContent } from '@ionic/react'
import { MkCta } from '../../tsp/components/MkCta'
import { TuranLoader } from '@/components/TuranLoader'
import { PhIcon } from '../../components/icons/PhIcon'

const GEN_MS = 2200
const GEN_MAX_MS = 10_000 // хард-кап: генерация зависла → не держим фермера на лоадере (→ F7)
const GEN_PHRASES = [
  'Собираем план под ваше стадо…',
  'Расставляем работы по месяцам…',
  'Сверяем с вет-календарём…',
]

interface Props {
  generating: boolean               // порог достигнут → сначала F6-лоадер + хэндофф
  onGenerate: () => Promise<boolean> // хэндофф ARS-213 (graceful); true = draft-план создан
  hasUnanswered: boolean            // показать link «Ответить сейчас» (только F7)
  onToFarm: () => void
  onAnswerNow: () => void
}

export function FwResult({ generating, onGenerate, hasUnanswered, onToFarm, onAnswerNow }: Props) {
  const [phase, setPhase] = useState<'gen' | 'final'>(generating ? 'gen' : 'final')
  const [planReady, setPlanReady] = useState(false)
  const [idx, setIdx] = useState(0)

  useEffect(() => {
    if (phase !== 'gen') return
    const step = Math.round(GEN_MS / GEN_PHRASES.length)
    const rot = setInterval(() => setIdx((i) => Math.min(i + 1, GEN_PHRASES.length - 1)), step)
    // Хэндофф генерации параллельно лоадеру; финал не раньше GEN_MS (награда читается как
    // результат работы системы) и не раньше ответа генерации — результат ветвит F7/F8 (ARS-215).
    // Хард-кап GEN_MAX_MS: RPC завис → выходим на F7, не блокируем фермера.
    let alive = true
    let timerDone = false
    let genDone = false
    let genOk = false
    const finish = () => {
      if (alive && timerDone && genDone) { setPlanReady(genOk); setPhase('final') }
    }
    const timer = setTimeout(() => { timerDone = true; finish() }, GEN_MS)
    const cap = setTimeout(() => { timerDone = true; genDone = true; finish() }, GEN_MAX_MS)
    onGenerate()
      .then((ok) => { genOk = ok })
      .catch(() => { /* graceful → F7 */ })
      .finally(() => { genDone = true; finish() })
    return () => { alive = false; clearInterval(rot); clearTimeout(timer); clearTimeout(cap) }
  }, [phase, onGenerate])

  if (phase === 'gen') {
    return (
      <IonContent className="agos-ion-content">
        <div className="phone-scroll">
          <div className="mk" data-screen-label="SCR-F6 · генерация плана">
            <div className="mk-loader">
              <TuranLoader variant="breathe" size={44} />
              <div>{GEN_PHRASES[idx]}</div>
            </div>
          </div>
        </div>
      </IonContent>
    )
  }

  // SCR-F8 · финал «план готов» (ARS-215): payoff Узла 1 — «отдал факты → увидел план».
  // Один путь вперёд (R-14): primary CTA → таб «Ферма», где план показан (state C).
  if (planReady) {
    return (
      <>
        <IonContent className="agos-ion-content">
          <div className="phone-scroll">
            <div className="mk" data-screen-label="SCR-F8 · финал · план готов">
              <div className="mk-res">
                <div className="mk-res-ic tone-green"><PhIcon name="calendar" size={30} /></div>
                <h1 className="mk-res-h">План работ на год готов</h1>
                <div className="mk-res-b">
                  <p>Работы по вашему стаду расставлены по месяцам. План живёт на вкладке «Ферма» — дополним его по мере ваших ответов.</p>
                </div>
              </div>
            </div>
          </div>
        </IonContent>
        <div className="sh-foot">
          <MkCta onClick={onToFarm}>Посмотреть план</MkCta>
        </div>
      </>
    )
  }

  return (
    <>
      <IonContent className="agos-ion-content">
        <div className="phone-scroll">
          <div className="mk" data-screen-label="SCR-F7 · финал · стадо записано">
            <div className="mk-res">
              <div className="mk-res-ic tone-green"><PhIcon name="checkCircle" size={30} /></div>
              <h1 className="mk-res-h">Стадо записано</h1>
              <div className="mk-res-b">
                <p>Цены по вашим категориям теперь на Главной и в «Рынке». Ответите на вопросы про отёл и содержание — соберём план работ на год.</p>
              </div>
            </div>
          </div>
        </div>
      </IonContent>
      <div className="sh-foot">
        <MkCta onClick={onToFarm}>На Ферму</MkCta>
        {hasUnanswered && <button className="mk-link" onClick={onAnswerNow}>Ответить сейчас</button>}
      </div>
    </>
  )
}
