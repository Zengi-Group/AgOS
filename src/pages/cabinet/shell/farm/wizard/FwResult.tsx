// AgOS · ARS-212 · SCR-F6 (генерация) + SCR-F7 (финал без плана). Порог достигнут → F6-лоадер
// (паттерн PubResult.searching, ротация фраз) во время которого срабатывает хэндофф генерации
// draft-ЦТК (ARS-213, graceful) → затем финал. Показ самого плана — ARS-215 (вне слайса), поэтому
// приземляемся на F7 «Стадо записано» (D-FW-5: финал — тоже награда, зелёный checkCircle).
// Ниже порога / skip → сразу F7 + link «Ответить сейчас» (→ первый неотвеченный вопрос).

import { useEffect, useState } from 'react'
import { IonContent } from '@ionic/react'
import { MkCta } from '../../tsp/components/MkCta'
import { PhIcon } from '../../components/icons/PhIcon'

const GEN_MS = 2200
const GEN_PHRASES = [
  'Собираем план под ваше стадо…',
  'Расставляем работы по месяцам…',
  'Сверяем с вет-календарём…',
]

interface Props {
  generating: boolean            // порог достигнут → сначала F6-лоадер + хэндофф
  onGenerate: () => Promise<void> // хэндофф ARS-213 (graceful)
  hasUnanswered: boolean         // показать link «Ответить сейчас»
  onToFarm: () => void
  onAnswerNow: () => void
}

export function FwResult({ generating, onGenerate, hasUnanswered, onToFarm, onAnswerNow }: Props) {
  const [phase, setPhase] = useState<'gen' | 'final'>(generating ? 'gen' : 'final')
  const [idx, setIdx] = useState(0)

  useEffect(() => {
    if (phase !== 'gen') return
    const step = Math.round(GEN_MS / GEN_PHRASES.length)
    const rot = setInterval(() => setIdx((i) => Math.min(i + 1, GEN_PHRASES.length - 1)), step)
    // Хэндофф генерации плана параллельно лоадеру; финал не раньше GEN_MS (награда читается
    // как результат работы системы). Ошибка/отсутствие RPC (ARS-213) не блокирует — всё равно F7.
    let done = false
    const finish = () => { if (!done) { done = true; setPhase('final') } }
    const timer = setTimeout(finish, GEN_MS)
    onGenerate().catch(() => { /* graceful */ })
    return () => { clearInterval(rot); clearTimeout(timer) }
  }, [phase, onGenerate])

  if (phase === 'gen') {
    return (
      <IonContent className="agos-ion-content">
        <div className="phone-scroll">
          <div className="mk" data-screen-label="SCR-F6 · генерация плана">
            <div className="mk-loader">
              <div className="mk-spin" />
              <div>{GEN_PHRASES[idx]}</div>
            </div>
          </div>
        </div>
      </IonContent>
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
