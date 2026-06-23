// AgOS · SCR-10 · Обращение в TURAN (фермер).
// Маршрут: route.name === 'thread' && route.tid === 'turan'

import { useState } from 'react'
import { ShellFrame } from '../components/ShellFrame'
import { Cta } from '../components/Cta'

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
  const initTopic = prefillTopic && TOPICS.includes(prefillTopic) ? prefillTopic : TOPICS[0]
  const [topic, setTopic] = useState(initTopic)
  const [message, setMessage] = useState('')
  const [sent, setSent] = useState(false)

  const canSend = message.trim().length >= 5

  const handleSend = () => {
    if (!canSend) return
    setSent(true)
    toast('Обращение принято · ответим в течение 1 рабочего дня')
  }

  return (
    <ShellFrame noTabs label="TURAN">
      <div className="lst-head">
        <button className="lst-back" onClick={onBack} aria-label="Назад">←</button>
        <div className="lst-title">TURAN · Поддержка</div>
      </div>

      {sent ? (
        <div style={{ padding: '40px 20px', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16, textAlign: 'center' }}>
          <div style={{ fontSize: 48 }}>✓</div>
          <div style={{ fontSize: 17, fontWeight: 800, color: 'var(--ok)' }}>Обращение принято</div>
          <div style={{ fontSize: 13, color: 'var(--ink-2)', lineHeight: 1.5, maxWidth: 260 }}>
            Ответим в течение 1 рабочего дня. Ответ придёт в этот раздел.
          </div>
          <div style={{ marginTop: 8, width: '100%' }}>
            <Cta variant="ghost" onClick={onBack}>Вернуться назад</Cta>
          </div>
        </div>
      ) : (
        <div style={{ padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: 16 }}>

          <div style={{ background: 'var(--paper-2)', borderRadius: 11, padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--ink-3)', letterSpacing: '.05em', textTransform: 'uppercase' }}>Контакты</div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
              <span style={{ fontSize: 16 }}>📞</span>
              <span style={{ color: 'var(--primary)', fontWeight: 600 }}>+7 (727) 000-00-00</span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
              <span style={{ fontSize: 16 }}>⏰</span>
              <span style={{ color: 'var(--ink-2)' }}>Пн–Пт, 9:00–18:00 (Алматы)</span>
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--ink-3)', letterSpacing: '.05em', textTransform: 'uppercase', marginBottom: 6 }}>Тема обращения</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {TOPICS.map((t) => (
                <button
                  key={t}
                  onClick={() => setTopic(t)}
                  style={{
                    display: 'flex', alignItems: 'center', gap: 10,
                    padding: '10px 12px', borderRadius: 9, cursor: 'pointer',
                    border: `1.5px solid ${topic === t ? 'var(--primary)' : 'var(--line-soft)'}`,
                    background: topic === t ? 'color-mix(in srgb, var(--primary) 8%, transparent)' : 'var(--card)',
                    textAlign: 'left', fontSize: 13, fontWeight: topic === t ? 700 : 400,
                    color: topic === t ? 'var(--primary)' : 'var(--ink)',
                  }}
                >
                  <span style={{
                    width: 16, height: 16, borderRadius: '50%', flexShrink: 0,
                    border: `2px solid ${topic === t ? 'var(--primary)' : 'var(--line)'}`,
                    background: topic === t ? 'var(--primary)' : 'transparent',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                  }}>
                    {topic === t && <span style={{ width: 6, height: 6, borderRadius: '50%', background: '#fff', display: 'block' }} />}
                  </span>
                  {t}
                </button>
              ))}
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--ink-3)', letterSpacing: '.05em', textTransform: 'uppercase', marginBottom: 6 }}>Сообщение</div>
            <textarea
              style={{
                width: '100%',
                border: `1.5px solid ${message.length > 0 && !canSend ? 'var(--red)' : 'var(--line-soft)'}`,
                borderRadius: 9, padding: '10px 12px', fontSize: 13,
                background: 'var(--card)', color: 'var(--ink)', outline: 'none',
                resize: 'none', minHeight: 110, fontFamily: 'inherit', lineHeight: 1.5,
                boxSizing: 'border-box',
              }}
              placeholder="Опишите ситуацию подробнее..."
              value={message}
              onChange={(e) => setMessage(e.target.value)}
            />
            {message.length > 0 && !canSend && (
              <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 3 }}>Минимум 5 символов</div>
            )}
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <Cta disabled={!canSend} onClick={handleSend}>Отправить обращение</Cta>
            <Cta variant="ghost" onClick={onBack}>Отмена</Cta>
          </div>

          <div style={{ fontSize: 11, color: 'var(--ink-4)', textAlign: 'center', lineHeight: 1.4 }}>
            Обращения обрабатываются в течение 1 рабочего дня
          </div>
        </div>
      )}
    </ShellFrame>
  )
}
