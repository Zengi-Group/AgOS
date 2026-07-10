// AgOS · ARS-231 · Тред модуля (Рынок / Ферма / TURAN) — порт app/messages.jsx ThreadScreen.
// Лента = проекция событий модуля: pinned «ТРЕБУЕТ РЕШЕНИЯ» + сообщения дня.
// Кнопки pinned зовут те же хендлеры, что ярусы Главной (один объект — две поверхности).

import { IonShellFrame } from '../components/IonShellFrame'
import { PhIcon } from '../components/icons/PhIcon'
import { TuranStar } from '../components/icons/TuranStar'
import { ThreadAv } from '../components/ThreadAv'
import { MSG_META, buildThreadMsgs, type ThreadEnv, type ThreadId, type ThreadMsg } from '../data/threads'

function MsgBubble({ m }: { m: ThreadMsg }) {
  const acts = m.actions ?? []
  const hasFooter = acts.length > 0 || m.open
  return (
    <div className="msg">
      <div className={'msg-b' + (m.pin ? ' pin' : '')}>
        <div className="msg-t">{m.t}</div>
        {m.s && <div className="msg-s">{m.s}</div>}
        {hasFooter && (
          <div className="msg-acts">
            {acts.map((a) => (
              <button key={a.t} className={'msg-act ' + a.kind} onClick={a.fn}>{a.t}</button>
            ))}
            {m.open && (
              <button className="msg-act ghost" onClick={m.open}>
                Открыть партию <PhIcon name="chevronRight" size={13} />
              </button>
            )}
          </div>
        )}
        {m.time && <div className="msg-time">{m.time}</div>}
      </div>
    </div>
  )
}

interface Props {
  tid: Exclude<ThreadId, 'consultant'>
  env: ThreadEnv
  onBack: () => void
  onAsk: () => void
}

export function ThreadScreen({ tid, env, onBack, onAsk }: Props) {
  const m = MSG_META[tid]
  const msgs = buildThreadMsgs(tid, env)
  const pinned = msgs.filter((x) => x.pin)
  const feed = msgs.filter((x) => !x.pin)
  return (
    <IonShellFrame noTabs label={'Сообщения · тред ' + m.n}>
      <div className="mk">
        <div className="thr-head">
          <button className="thr-back" title="Сообщения" onClick={onBack}><PhIcon name="chevronLeft" size={20} /></button>
          <ThreadAv tid={tid} size={16} />
          <div className="thr-head-t"><b>{m.n}</b><span>{m.sub}</span></div>
          <button className="thr-ask" title="Спросить Консультанта" onClick={onAsk}><TuranStar size={16} /></button>
        </div>
        {pinned.length > 0 && (
          <>
            <div className="msg-day">ТРЕБУЕТ РЕШЕНИЯ · ЗАКРЕПЛЕНО</div>
            {pinned.map((x) => <MsgBubble key={x.id} m={x} />)}
          </>
        )}
        <div className="msg-day">СЕГОДНЯ</div>
        {feed.map((x) => <MsgBubble key={x.id} m={x} />)}
      </div>
    </IonShellFrame>
  )
}
