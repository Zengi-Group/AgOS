// AgOS · ARS-231 · Таб «Сообщения» — список тредов на Chatscope ConversationList
// (решение CEO 2026-07-11, R-19: чат-механику берём из kit). Каждый модуль — собеседник
// (Kaspi-паттерн): Консультант · Рынок · Ферма · TURAN. Доменный контент (превью, mini-CTA
// решения, unread) — наш, через Conversation.Content; хендлеры = ярусы Главной.

import { ConversationList, Conversation, Avatar } from '@chatscope/chat-ui-kit-react'
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
            <ConversationList className="thr-cs-list">
              {threads.map((th) => {
                const m = MSG_META[th.tid]
                return (
                  <Conversation
                    key={th.tid}
                    unreadCnt={th.unread > 0 ? th.unread : undefined}
                    onClick={() => onOpen(th.tid)}
                  >
                    <Avatar><ThreadAv tid={th.tid} /></Avatar>
                    <Conversation.Content>
                      <div className="thr-body">
                        <div className="thr-top">
                          <span className="thr-n">{m.n}</span>
                          {th.time && <span className="thr-time">{th.time}</span>}
                        </div>
                        <div className={'thr-prev' + (th.unread > 0 ? ' unread' : '')}>{th.prev}</div>
                        {th.interactive && env.h && (
                          <div className="thr-cta-row">
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
                          </div>
                        )}
                      </div>
                    </Conversation.Content>
                  </Conversation>
                )
              })}
            </ConversationList>
            <p className="thr-foot">События сделок и сигналы фермы приходят сюда — не в отдельный центр уведомлений.</p>
          </>
        )}
      </div>
    </IonShellFrame>
  )
}
