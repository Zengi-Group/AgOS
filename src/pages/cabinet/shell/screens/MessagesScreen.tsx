// AgOS · ARS-231 · Таб «Сообщения» — список тредов (порт app/messages.jsx MessagesScreen).
// Каждый модуль — собеседник (паттерн Kaspi): Консультант · Рынок · Ферма · TURAN.
// mini-CTA решения прямо в списке — те же хендлеры, что у decision-карточки Главной.

import { IonShellFrame } from '../components/IonShellFrame'
import { TabHead } from '../components/TabHead'
import { ThreadAv } from '../components/ThreadAv'
import { ScreenSkeleton } from '../components/ScreenSkeleton'
import { MSG_META, buildThreadList, type ThreadEnv, type ThreadId } from '../data/threads'

interface Props {
  env: ThreadEnv
  loading: boolean
  onOpen: (tid: ThreadId) => void
}

export function MessagesScreen({ env, loading, onOpen }: Props) {
  const threads = buildThreadList(env)
  return (
    <IonShellFrame label="Сообщения · треды">
      <TabHead title="Сообщения" />
      <div className="mk">
        {loading ? <ScreenSkeleton variant="list" /> : (
          <>
            <div className="thr-list">
              {threads.map((th) => {
                const m = MSG_META[th.tid]
                return (
                  <button key={th.tid} className="thr" onClick={() => onOpen(th.tid)}>
                    <ThreadAv tid={th.tid} />
                    <span className="thr-body">
                      <span className="thr-top">
                        <span className="thr-n">{m.n}</span>
                        {th.time && <span className="thr-time">{th.time}</span>}
                      </span>
                      <span className={'thr-prev' + (th.unread > 0 ? ' unread' : '')}>{th.prev}</span>
                      {th.interactive && env.h && (
                        <span className="thr-cta-row">
                          <span
                            className="thr-mini-btn primary" role="button" tabIndex={0}
                            onClick={(e) => { e.stopPropagation(); env.h.lower(th.interactive!) }}
                          >
                            Снизить цену
                          </span>
                          <span
                            className="thr-mini-btn" role="button" tabIndex={0}
                            onClick={(e) => { e.stopPropagation(); env.h.open(th.interactive!) }}
                          >
                            Варианты
                          </span>
                        </span>
                      )}
                    </span>
                    {th.unread > 0 && <span className="thr-badge mono">{th.unread}</span>}
                  </button>
                )
              })}
            </div>
            <p className="thr-foot">События сделок и сигналы фермы приходят сюда — не в отдельный центр уведомлений.</p>
          </>
        )}
      </div>
    </IonShellFrame>
  )
}
