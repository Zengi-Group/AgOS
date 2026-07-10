// AgOS · ARS-231 · AI-консультант — порт app/messages.jsx ConsultantScreen.
// Чат с typing-индикатором и голосовым вводом (мок волны → распознанный текст).
// Ответы — мок aiReply по справочным данным TURAN; реальный AI Gateway (Dok 5,
// ai_conversations/ai_messages) подключается отдельной задачей — контракт экрана не меняется.

import { useEffect, useRef, useState } from 'react'
import { IonShellFrame } from '../components/IonShellFrame'
import { PhIcon } from '../components/icons/PhIcon'
import { TuranStar } from '../components/icons/TuranStar'
import { AI_FIRST } from '../data/threads'
import type { AiMsg } from '../types'

const AI_VOICE = 'Какая сейчас цена на бычков?'

interface Props {
  aiLog: AiMsg[]
  typing: boolean
  offline: boolean
  offlineToast: () => void
  onSend: (text: string) => void
  onBack: () => void
}

export function ConsultantScreen({ aiLog, typing, offline, offlineToast, onSend, onBack }: Props) {
  const [val, setVal] = useState('')
  const [rec, setRec] = useState(false)
  const anchor = useRef<HTMLDivElement | null>(null)
  const shown: AiMsg[] = aiLog.length ? aiLog : [{ who: 'c', t: AI_FIRST }]

  useEffect(() => {
    anchor.current?.scrollIntoView({ block: 'end' })
  }, [aiLog.length, typing, rec])

  // мок голосового ввода: волна → распознанный текст
  useEffect(() => {
    if (!rec) return
    const t = setTimeout(() => { setRec(false); setVal(AI_VOICE) }, 1900)
    return () => clearTimeout(t)
  }, [rec])

  const send = () => {
    const t = val.trim()
    if (!t || typing) return
    if (offline) { offlineToast(); return }
    onSend(t)
    setVal('')
  }

  const footer = (
    <>
      {rec ? (
        <div className="ai-inrow">
          <div className="ai-wave">{Array.from({ length: 16 }).map((_, i) => <i key={i} style={{ animationDelay: (i * 60) + 'ms' }} />)}</div>
          <button className="ai-mic on" onClick={() => setRec(false)} title="Остановить"><PhIcon name="mic" size={17} /></button>
        </div>
      ) : (
        <div className="ai-inrow">
          <input
            className="ai-input" value={val} placeholder="Спросите Консультанта…"
            onChange={(e) => setVal(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && send()}
          />
          {val.trim()
            ? <button className="ai-mic send" onClick={send} title="Отправить"><PhIcon name="send" size={15} /></button>
            : <button className="ai-mic" onClick={() => setRec(true)} title="Голосовой ввод"><PhIcon name="mic" size={17} /></button>}
        </div>
      )}
      <div className="ai-foot">Консультант отвечает по справочным данным TURAN</div>
    </>
  )

  return (
    <IonShellFrame noTabs label="Консультант" footBare footer={footer}>
      <div className="mk">
        <div className="thr-head">
          <button className="thr-back" title="Сообщения" onClick={onBack}><PhIcon name="chevronLeft" size={20} /></button>
          <span className="thr-av tone-accent"><TuranStar size={16} /></span>
          <div className="thr-head-t"><b>Консультант TURAN</b><span>всегда на связи</span></div>
        </div>
        <div className="ai-feed">
          {shown.map((m, i) => (
            <div key={i} className={'ai-msg ' + (m.who === 'c' ? 'from-c' : 'from-u')}>
              {m.who === 'c' && <span className="ai-msg-star"><TuranStar size={12} /></span>}
              <div className="ai-bubble">{m.t}</div>
            </div>
          ))}
          {typing && (
            <div className="ai-msg from-c">
              <span className="ai-msg-star"><TuranStar size={12} /></span>
              <div className="ai-bubble typing"><i /><i /><i /></div>
            </div>
          )}
          <div ref={anchor} />
        </div>
      </div>
    </IonShellFrame>
  )
}
