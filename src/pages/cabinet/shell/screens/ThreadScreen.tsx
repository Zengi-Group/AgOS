// AgOS · ARS-231 · Тред модуля (Рынок / Ферма / TURAN) на Chatscope MessageList
// (решение CEO 2026-07-11, R-19). Лента = проекция событий модуля: pinned «ТРЕБУЕТ РЕШЕНИЯ»
// + сообщения дня. Доменный пузырь рендерится через Message.CustomContent — kit даёт
// скролл/группировку/каркас, содержимое (текст, действия, дисклеймеры) наше. Кнопки зовут
// те же хендлеры, что ярусы Главной (один объект — две поверхности).

import { ChatContainer, MessageList, Message, MessageSeparator } from '@chatscope/chat-ui-kit-react'
import { IonShellFrame } from '../components/IonShellFrame'
import { PhIcon } from '../components/icons/PhIcon'
import { ThreadAv } from '../components/ThreadAv'
import { MSG_META, buildThreadMsgs, type ThreadEnv, type ThreadId, type ThreadMsg } from '../data/threads'

// Message рендерим ФУНКЦИЕЙ, не компонентом: Chatscope MessageList валидирует тип
// прямых детей (allowed: Message/MessageGroup/MessageSeparator) — обёртка-компонент
// отвергается варнингом. Функция возвращает элемент с type===Message → проходит.
function renderBubble(m: ThreadMsg) {
  const acts = m.actions ?? []
  const hasFooter = acts.length > 0 || m.open
  return (
    <Message key={m.id} model={{ direction: m.dir ?? 'incoming', position: 'single' }} className={m.pin ? 'thr-pin' : undefined}>
      <Message.CustomContent>
        <div className="msg-t">{m.t}</div>
        {m.s && <div className="msg-s">{m.s}</div>}
        {hasFooter && (
          <div className="msg-acts">
            {acts.map((a) => (
              <button key={a.t} className={'msg-act ' + a.kind} onClick={a.fn}>
                {a.icon && <PhIcon name={a.icon} size={16} />}{a.t}
              </button>
            ))}
            {m.open && (
              <button className="msg-act ghost" onClick={m.open}>
                Открыть партию <PhIcon name="chevronRight" size={13} />
              </button>
            )}
          </div>
        )}
        {m.time && <div className="msg-time">{m.time}</div>}
      </Message.CustomContent>
    </Message>
  )
}

interface Props {
  tid: Exclude<ThreadId, 'consultant'>
  env: ThreadEnv
  onBack: () => void
}

export function ThreadScreen({ tid, env, onBack }: Props) {
  const m = MSG_META[tid]
  const msgs = buildThreadMsgs(tid, env)
  const pinned = msgs.filter((x) => x.pin)
  const feed = msgs.filter((x) => !x.pin)
  return (
    <IonShellFrame noTabs noScroll label={'Сообщения · тред ' + m.n}>
      <div className="ai-chat">
        <div className="thr-head">
          <button className="thr-back" title="Сообщения" onClick={onBack}><PhIcon name="chevronLeft" size={20} /></button>
          <ThreadAv tid={tid} size={30} />
          <div className="thr-head-t"><b>{m.n}</b><span>{m.sub}</span></div>
        </div>
        <ChatContainer className="ai-cs thr-cs">
          <MessageList>
            {pinned.length > 0 && (
              <MessageSeparator>ТРЕБУЕТ РЕШЕНИЯ · ЗАКРЕПЛЕНО</MessageSeparator>
            )}
            {pinned.map(renderBubble)}
            <MessageSeparator>СЕГОДНЯ</MessageSeparator>
            {feed.map(renderBubble)}
          </MessageList>
        </ChatContainer>
      </div>
    </IonShellFrame>
  )
}
