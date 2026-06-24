// AgOS · Слайс 2+ · Сбор документов для членства (реальная загрузка в Supabase Storage).
// Флоу: загрузить обязательные документы → «Отправить на проверку» (rpc_submit_membership_application).
// После одобрения админом откроется оплата взноса (см. состояние 'approved').
// Файлы кладём в bucket membership-documents по схеме {orgId}/docs/{slotKey}_{ts}.{ext}.

import { useState, useEffect, useRef } from 'react'
import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { REQUIRED_DOCUMENTS, ACCEPTED_FILE_TYPES, MAX_FILE_SIZE_MB } from '@/types/application-flow'

// Русские подписи для слотов (i18n-ключи REQUIRED_DOCUMENTS не используем — шелл на русском).
const DOC_LABELS: Record<string, { name: string; hint: string }> = {
  registration_certificate: { name: 'Документ о гос. регистрации (с БИН)', hint: 'Свидетельство / справка с указанием БИН' },
  identity_document: { name: 'Удостоверение личности руководителя', hint: 'Лицевая и обратная сторона' },
  bank_details: { name: 'Банковские реквизиты', hint: 'Реквизиты счёта для расчётов' },
}

interface Props {
  orgId: string | null
  onClose: () => void
  onSubmitted: () => void
}

export function MembDocsSheet({ orgId, onClose, onSubmitted }: Props) {
  // slotKey → имя загруженного файла (null = не загружен).
  const [uploaded, setUploaded] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState<string | null>(null)        // slotKey в процессе загрузки
  const [submitting, setSubmitting] = useState(false)
  const inputs = useRef<Record<string, HTMLInputElement | null>>({})

  // Предзаполняем состояние из уже загруженных файлов (если возвращается к заявке).
  useEffect(() => {
    if (!orgId) return
    let alive = true
    supabase.storage
      .from('membership-documents')
      .list(`${orgId}/docs`, { limit: 100 })
      .then(({ data }) => {
        if (!alive || !data) return
        const next: Record<string, string | null> = {}
        for (const slot of REQUIRED_DOCUMENTS) {
          const f = data.find((x) => x.name.startsWith(`${slot.key}_`))
          next[slot.key] = f ? f.name : null
        }
        setUploaded(next)
      })
    return () => { alive = false }
  }, [orgId])

  const onFile = async (slotKey: string, file: File | undefined) => {
    if (!file) return
    if (file.size > MAX_FILE_SIZE_MB * 1024 * 1024) {
      toast.error(`Файл больше ${MAX_FILE_SIZE_MB} МБ`)
      return
    }
    // Демо/аноним (нет orgId) — помечаем локально, без реальной загрузки.
    if (!orgId) {
      setUploaded((p) => ({ ...p, [slotKey]: file.name }))
      return
    }
    setBusy(slotKey)
    try {
      // Убираем прежний файл этого слота.
      const { data: existing } = await supabase.storage
        .from('membership-documents')
        .list(`${orgId}/docs`, { limit: 100 })
      const toRemove = (existing ?? [])
        .filter((f) => f.name.startsWith(`${slotKey}_`))
        .map((f) => `${orgId}/docs/${f.name}`)
      if (toRemove.length) await supabase.storage.from('membership-documents').remove(toRemove)

      const ext = file.name.split('.').pop()?.toLowerCase() || 'pdf'
      const name = `${slotKey}_${Date.now()}.${ext}`
      const { error } = await supabase.storage
        .from('membership-documents')
        .upload(`${orgId}/docs/${name}`, file, { upsert: true })
      if (error) throw error
      setUploaded((p) => ({ ...p, [slotKey]: name }))
    } catch (e) {
      toast.error('Не удалось загрузить файл: ' + (e instanceof Error ? e.message : 'ошибка'))
    } finally {
      setBusy(null)
    }
  }

  const total = REQUIRED_DOCUMENTS.length
  const doneCount = REQUIRED_DOCUMENTS.filter((s) => uploaded[s.key]).length
  const allDone = doneCount >= total

  const submit = async () => {
    if (!allDone || submitting) return
    setSubmitting(true)
    try {
      if (orgId) {
        const { error } = await supabase.rpc('rpc_submit_membership_application', {
          p_organization_id: orgId,
          p_membership_type: 'associate',
          p_notes: null,
        })
        // PENDING_EXISTS = заявка уже на проверке — считаем успехом (документы обновлены).
        if (error && !error.message?.includes('PENDING_EXISTS')) {
          if (error.message?.includes('ALREADY_ACTIVE')) {
            toast.error('Членство уже активно')
          } else {
            toast.error('Не удалось отправить заявку: ' + error.message)
          }
          return
        }
      }
      onSubmitted()
    } finally {
      setSubmitting(false)
    }
  }

  const slotRow = (slot: typeof REQUIRED_DOCUMENTS[number]) => {
    const meta = DOC_LABELS[slot.key] ?? { name: slot.key, hint: '' }
    const done = !!uploaded[slot.key]
    const loading = busy === slot.key
    return (
      <div className="cb-row" key={slot.key}>
        <input
          ref={(el) => { inputs.current[slot.key] = el }}
          type="file"
          accept={ACCEPTED_FILE_TYPES}
          style={{ display: 'none' }}
          onChange={(e) => { onFile(slot.key, e.target.files?.[0]); e.target.value = '' }}
        />
        <span className={'cb-box' + (done ? ' ch' : '')}>{done ? '✓' : ''}</span>
        <span style={{ flex: 1 }}>
          <b style={{ fontSize: 12.5 }}>{meta.name} *</b>
          <div className="hint-inline">{done ? 'Загружено — нажмите, чтобы заменить' : meta.hint}</div>
        </span>
        <button
          className="cta ghost"
          style={{ marginTop: 0, padding: '7px 12px', fontSize: 12.5, width: 'auto' }}
          disabled={loading}
          onClick={() => inputs.current[slot.key]?.click()}
        >
          {loading ? 'Загрузка…' : done ? 'Заменить' : 'Загрузить'}
        </button>
      </div>
    )
  }

  return (
    <Sheet open onClose={onClose}>
      <div className="sh-t">Документы для членства</div>
      <div className="sh-b">Заявка в ассоциацию ТУРАН. Прикрепите документы — после одобрения откроется оплата взноса и Рынок (TSP).</div>
      <div style={{ maxHeight: 430, overflowY: 'auto', margin: '0 -2px' }}>
        <div className="blk-h mono" style={{ padding: '4px 2px 2px' }}>
          <span>ДОКУМЕНТЫ</span>
          <span style={{ color: doneCount >= total ? 'var(--ok)' : 'var(--ink-3)', fontWeight: 700 }}>{doneCount} / {total} готово</span>
        </div>
        <div className="progress" style={{ padding: '2px 2px 4px' }}>
          {REQUIRED_DOCUMENTS.map((s, i) => <div key={i} className={uploaded[s.key] ? 'done' : ''} />)}
        </div>
        {REQUIRED_DOCUMENTS.map(slotRow)}
        <div className="footnote" style={{ padding: '8px 2px 0' }}>Форматы: PDF, JPG, PNG · до {MAX_FILE_SIZE_MB} МБ</div>
      </div>
      <Cta variant="primary-green" disabled={!allDone || submitting} onClick={allDone && !submitting ? submit : undefined}>
        {submitting ? 'Отправка…' : 'Отправить на проверку'}
      </Cta>
      {!allDone && <div className="footnote">Загрузите все обязательные документы (*)</div>}
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}
