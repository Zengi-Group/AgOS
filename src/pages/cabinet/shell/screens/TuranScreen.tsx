// AgOS · SCR-10 · Обращение в TURAN (фермер) — реcкин под прототип (market-wizard.jsx TuranScreen):
// контакты (PhIcon вместо emoji) + тема (MkSelect) + сообщение (MkField) → success .mk-res.
// Логика/тексты/темы/prefillTopic сохранены. Маршрут: route.name === 'thread' && route.tid === 'turan'.

import { useState } from 'react'
import { IonShellFrame } from '../components/IonShellFrame'
import { SubHead } from '../components/SubHead'
import { PhIcon } from '../components/icons/PhIcon'
import { MkCta } from '../tsp/components/MkCta'
import { MkField } from '../tsp/components/MkField'
import { MkErr } from '../tsp/components/MkErr'
import { MkSelect } from '../tsp/components/MkSelect'

const TOPICS = [
  'Проблема с партией',
  'Вопрос по членству',
  'Документы и оплата',
  'Сделка или покупатель',
  'Другое',
]

interface Props {
  onBack: () => void
  toast: (text: string) => void
  prefillTopic?: string
}

export function TuranScreen({ onBack, toast, prefillTopic }: Props) {
  const initTopic = prefillTopic && TOPICS.includes(prefillTopic) ? prefillTopic : TOPICS[0]!
  const [topic, setTopic] = useState(initTopic)
  const [message, setMessage] = useState('')
  const [sent, setSent] = useState(false)

  const canSend = message.trim().length >= 5

  const handleSend = () => {
    if (!canSend) return
    setSent(true)
    toast('Обращение принято · ответим в течение 1 рабочего дня')
  }

  if (sent) {
    return (
      <IonShellFrame noTabs label="TURAN · отправлено" footer={<MkCta variant="ghost" onClick={onBack}>Вернуться назад</MkCta>}>
        <SubHead onBack={onBack} star tone="accent" title="TURAN" sub="Поддержка ассоциации" />
        <div className="mk">
          <div className="mk-res">
            <div className="mk-res-ic tone-green"><PhIcon name="checkCircle" size={30} /></div>
            <h1 className="mk-res-h">Обращение принято</h1>
            <div className="mk-res-b"><p>Ответим в течение 1 рабочего дня. Ответ придёт в этот раздел.</p></div>
          </div>
        </div>
      </IonShellFrame>
    )
  }

  return (
    <IonShellFrame noTabs label="TURAN" footer={<>
      <MkCta disabled={!canSend} onClick={handleSend}>Отправить обращение</MkCta>
      <MkCta variant="ghost" onClick={onBack}>Отмена</MkCta>
    </>}>
      <SubHead onBack={onBack} star tone="accent" title="TURAN" sub="Поддержка ассоциации" />
      <div className="mk mk-pt">
        <div className="mk-infonote">
          <div className="mk-infonote-t">Контакты</div>
          <div className="mk-infonote-b">
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <PhIcon name="phone" size={16} color="var(--primary)" />
              <span style={{ color: 'var(--primary)', fontWeight: 600 }}>+7 (727) 000-00-00</span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 6 }}>
              <PhIcon name="clock" size={16} />
              <span>Пн–Пт, 9:00–18:00 (Алматы)</span>
            </div>
          </div>
        </div>
        <MkSelect label="Тема обращения" value={topic} onChange={(e) => setTopic(e.target.value)} options={TOPICS} />
        <MkField label="Сообщение" miss={message.length > 0 && !canSend}>
          <textarea className="mk-input area" rows={4} value={message}
            placeholder="Опишите ситуацию подробнее…" onChange={(e) => setMessage(e.target.value)} />
        </MkField>
        {message.length > 0 && !canSend && <MkErr>Минимум 5 символов</MkErr>}
        <div className="mk-note mk-mono" style={{ marginTop: 8 }}>обращения обрабатываются в течение 1 рабочего дня</div>
      </div>
    </IonShellFrame>
  )
}
