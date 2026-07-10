// AgOS · ARS-231 · AI-консультант на Chatscope (@chatscope/chat-ui-kit-react) —
// решение CEO 2026-07-11: чат-механика (скролл, группировка, инпут) из проверенного
// kit, перекраска в daylight-токены (messages-chatscope.css), доменный слой наш.
// Кнопки — свои с PhIcon (sendButton/attachButton kit'а отключены: FontAwesome
// в фермерской зоне запрещён, Phosphor-only). Мок голосового ввода сохранён.
// Ответы — мок aiReply по справочным данным TURAN; реальный AI Gateway (Dok 5)
// подключается отдельной задачей (кандидат: @ai-sdk/react useChat) — контракт не меняется.

import { useEffect, useState } from 'react'
import { ChatContainer, MessageList, Message, MessageInput, TypingIndicator, Avatar } from '@chatscope/chat-ui-kit-react'
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
  const shown: AiMsg[] = aiLog.length ? aiLog : [{ who: 'c', t: AI_FIRST }]

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
    // kit после очистки оставляет selection на пустом contenteditable —
    // браузер красил плейсхолдер синим выделением; снимаем диапазон.
    window.getSelection()?.removeAllRanges()
  }

  // Группировка пузырей: соседние сообщения одного автора слипаются (first/normal/last).
  const posOf = (i: number): 'single' | 'first' | 'normal' | 'last' => {
    const prev = shown[i - 1]?.who === shown[i]!.who
    const next = shown[i + 1]?.who === shown[i]!.who
    if (prev && next) return 'normal'
    if (prev) return 'last'
    if (next) return 'first'
    return 'single'
  }

  return (
    <IonShellFrame noTabs noScroll label="Консультант">
      <div className="ai-chat">
        <div className="thr-head">
          <button className="thr-back" title="Сообщения" onClick={onBack}><PhIcon name="chevronLeft" size={20} /></button>
          <span className="thr-av tone-accent"><TuranStar size={16} /></span>
          <div className="thr-head-t"><b>Консультант TURAN</b><span>всегда на связи</span></div>
        </div>
        <ChatContainer className="ai-cs">
          <MessageList typingIndicator={typing ? <TypingIndicator content="Консультант печатает" /> : undefined}>
            {shown.map((m, i) => (
              <Message
                key={i}
                model={{
                  message: m.t,
                  direction: m.who === 'c' ? 'incoming' : 'outgoing',
                  position: posOf(i),
                }}
                avatarSpacer={m.who === 'c' && posOf(i) !== 'last' && posOf(i) !== 'single'}
              >
                {m.who === 'c' && (posOf(i) === 'last' || posOf(i) === 'single') ? (
                  <Avatar><span className="ai-msg-star"><TuranStar size={12} /></span></Avatar>
                ) : undefined}
              </Message>
            ))}
          </MessageList>
        </ChatContainer>
        <div className="ai-dock">
          {rec ? (
            <div className="ai-inrow">
              <div className="ai-wave">{Array.from({ length: 16 }).map((_, i) => <i key={i} style={{ animationDelay: (i * 60) + 'ms' }} />)}</div>
              <button className="ai-mic on" onClick={() => setRec(false)} title="Остановить"><PhIcon name="mic" size={17} /></button>
            </div>
          ) : (
            <div className="ai-inrow">
              <MessageInput
                className="ai-cs-input"
                placeholder="Спросите Консультанта…"
                value={val}
                onChange={(_html, text) => setVal(text)}
                onSend={send}
                attachButton={false}
                sendButton={false}
                fancyScroll={false}
              />
              {val.trim()
                ? <button className="ai-mic send" onClick={send} title="Отправить"><PhIcon name="send" size={15} /></button>
                : <button className="ai-mic" onClick={() => setRec(true)} title="Голосовой ввод"><PhIcon name="mic" size={17} /></button>}
            </div>
          )}
          <div className="ai-foot">Консультант отвечает по справочным данным TURAN</div>
        </div>
      </div>
    </IonShellFrame>
  )
}
