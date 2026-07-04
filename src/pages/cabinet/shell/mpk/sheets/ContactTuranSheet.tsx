// AgOS · TSP-3 · Шторка «Обратиться в TURAN».

import { useEffect, useState } from 'react'
import { Sheet } from '../../components/Sheet'
import { Cta } from '../../components/Cta'

interface Props {
  open: boolean
  topic?: string
  onClose: () => void
  onSubmit: () => void
}

const TOPICS = ['Отклонение типа МПК', 'Документы', 'Членство TURAN', 'Другое']

export function ContactTuranSheet({ open, topic, onClose, onSubmit }: Props) {
  const [selTopic, setSelTopic] = useState(topic && TOPICS.includes(topic) ? topic : TOPICS[0])
  const [message, setMessage] = useState('')
  const canSend = message.trim().length >= 5

  // S6 (ARS-152): шторка смонтирована постоянно (open-флаг, S2-паттерн PR #27) —
  // каждый показ с чистого состояния и актуальной темой (реинициализация по open).
  useEffect(() => {
    if (!open) return
    setSelTopic(topic && TOPICS.includes(topic) ? topic : TOPICS[0])
    setMessage('')
  }, [open, topic])

  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t" style={{ fontSize: 16, fontWeight: 800, marginBottom: 10 }}>Обратиться в TURAN</div>

      <div className="mpk-field-label">Тема</div>
      <select className="mpk-select" value={selTopic} onChange={(e) => setSelTopic(e.target.value)}>
        {TOPICS.map((t) => <option key={t} value={t}>{t}</option>)}
      </select>

      <div className="mpk-field-label" style={{ marginTop: 12 }}>Сообщение</div>
      <textarea
        className="mpk-input"
        style={{ minHeight: 90, resize: 'vertical' }}
        placeholder="Опишите ситуацию..."
        value={message}
        onChange={(e) => setMessage(e.target.value)}
      />

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 12 }}>
        <Cta onClick={onSubmit} disabled={!canSend}>Отправить</Cta>
        <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
      </div>
    </Sheet>
  )
}
