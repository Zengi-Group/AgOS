// AgOS · Заявка на членство — ЕДИНЫЙ полноэкранный процесс (/membership).
// Все CTA «Вступить» / «Подать заявку» из кабинета ведут сюда (memberAct('apply') → navigate).
// Дизайн портирован из прототипа agos-farmer (routes/membership.tsx).
// Реальная логика: загрузка документов в Supabase Storage (bucket membership-documents,
// путь {orgId}/docs/{slotKey}_{ts}.{ext}) + rpc_submit_membership_application.
// orgId берём из контекста (rpc_get_my_context через useAuth).
import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  Storefront,
  Headset,
  UsersThree,
  Tag,
  Plus,
  Check,
  CircleNotch,
  Clock,
  FileText,
  IdentificationCard,
  Bank,
  Eye,
  X,
  type Icon as PhosphorIcon,
} from '@phosphor-icons/react'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { useAuth } from '@/hooks/useAuth'
import { ACCEPTED_FILE_TYPES, MAX_FILE_SIZE_MB } from '@/types/application-flow'
import { T } from '@/lib/auth-ui/tokens'
import { AuthShell, AuthBody, TopBar, H1, Lede, StickyDock, CTA } from '@/lib/auth-ui/primitives'

type Step = 'intro' | 'docs' | 'submitting' | 'pending'
// slotKey совпадает с REQUIRED_DOCUMENTS (application-flow) — для Storage-путей и RPC.
type SlotKey = 'registration_certificate' | 'identity_document' | 'bank_details'

const STEP_LABELS: Record<Step, string> = {
  intro: 'О заявке',
  docs: 'Документы',
  submitting: 'Отправка',
  pending: 'На рассмотрении',
}
const ORDER: Step[] = ['intro', 'docs', 'pending']

type IconComp = PhosphorIcon

const DOC_SLOTS: { key: SlotKey; title: string; hint: string; Icon: IconComp }[] = [
  { key: 'registration_certificate', title: 'Гос. регистрация', hint: 'Свидетельство или справка с БИН', Icon: FileText },
  { key: 'identity_document', title: 'Удостоверение', hint: 'Руководитель · обе стороны', Icon: IdentificationCard },
  { key: 'bank_details', title: 'Реквизиты счёта', hint: 'Для расчётов с ассоциацией', Icon: Bank },
]

type FileMeta = { name: string; storageName?: string; url?: string }

const ANIM_CSS = `
@keyframes memSpin { to { transform: rotate(360deg) } }
@keyframes memFadeUp { from { opacity: 0 } to { opacity: 1 } }
@keyframes memFadeUpInner { from { opacity: 0; transform: translate3d(0,8px,0) } to { opacity: 1; transform: none } }
@keyframes memPop { 0% { transform: scale(0.6); opacity: 0 } 60% { transform: scale(1.08); opacity: 1 } 100% { transform: scale(1) } }
@keyframes memPulse { 0%,100% { transform: scale(1); opacity: 1 } 50% { transform: scale(1.5); opacity: 0 } }
.mem-step { animation: memFadeUp 260ms ease-out both }
.mem-stagger > * { animation: memFadeUpInner 360ms cubic-bezier(0.16,1,0.3,1) both; opacity: 0 }
.mem-stagger > *:nth-child(1) { animation-delay: 40ms }
.mem-stagger > *:nth-child(2) { animation-delay: 100ms }
.mem-stagger > *:nth-child(3) { animation-delay: 160ms }
.mem-stagger > *:nth-child(4) { animation-delay: 220ms }
.mem-press { transition: transform 120ms ease, background 140ms ease, border-color 140ms ease }
.mem-press:active { transform: scale(0.985) }
`

export function Membership() {
  const navigate = useNavigate()
  const { organization, refreshContext, userContext } = useAuth()
  const orgId = organization?.id ?? null

  const [step, setStep] = useState<Step>('intro')
  const [files, setFiles] = useState<Record<SlotKey, FileMeta | null>>({
    registration_certificate: null,
    identity_document: null,
    bank_details: null,
  })
  const [error, setError] = useState<string | null>(null)

  // Подтягиваем контекст (org) и уже загруженные документы из Storage.
  useEffect(() => {
    void refreshContext()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Нет организации (незавершённая регистрация) → членство невозможно без юр. хозяйства (БИН).
  // Уводим достраивать регистрацию (создать орг); оттуда снова откроется членство. Гейтим по
  // userContext (загружен, но организаций нет) — так не редиректим валидного фермера до резолва
  // контекста при холодной загрузке прямо на /membership.
  useEffect(() => {
    if (userContext && !orgId) navigate('/register', { replace: true })
  }, [userContext, orgId, navigate])

  // Резюме: возвращаем туда, где фермер остановился. Заявка уже отправлена → сразу статус
  // «на рассмотрении» (без повторной подачи); есть черновик документов → шаг «Документы».
  // Меняем стартовый шаг только из 'intro', чтобы не сбивать навигацию пользователя.
  useEffect(() => {
    if (!orgId) return
    let alive = true
    Promise.all([
      supabase.storage.from('membership-documents').list(`${orgId}/docs`, { limit: 100 }),
      supabase
        .from('membership_applications')
        .select('status')
        .eq('organization_id', orgId)
        .order('submitted_at', { ascending: false })
        .limit(1),
    ]).then(([docsRes, appRes]) => {
      if (!alive) return
      const data = docsRes.data
      if (data) {
        setFiles((prev) => {
          const next = { ...prev }
          for (const slot of DOC_SLOTS) {
            const f = data.find((x) => x.name.startsWith(`${slot.key}_`))
            if (f && !next[slot.key]) next[slot.key] = { name: f.name, storageName: f.name }
          }
          return next
        })
      }
      const st = (appRes.data?.[0] as { status: string } | undefined)?.status
      const hasDocs = !!data && DOC_SLOTS.some((s) => data.find((x) => x.name.startsWith(`${s.key}_`)))
      setStep((prev) =>
        prev !== 'intro' ? prev
          : (st === 'submitted' || st === 'under_review') ? 'pending'
            : hasDocs ? 'docs'
              : 'intro'
      )
    })
    return () => {
      alive = false
    }
  }, [orgId])

  const readyCount = (Object.values(files) as (FileMeta | null)[]).filter(Boolean).length
  const idx = Math.max(0, ORDER.indexOf(step === 'submitting' ? 'docs' : step))

  const back = () => {
    if (step === 'docs') {
      setStep('intro')
      return
    }
    navigate('/cabinet')
  }

  const setFile = (key: SlotKey, meta: FileMeta | null, err?: string) => {
    setError(err ?? null)
    setFiles((prev) => {
      const prevF = prev[key]
      if (prevF?.url) {
        try {
          URL.revokeObjectURL(prevF.url)
        } catch {
          /* ignore */
        }
      }
      return { ...prev, [key]: meta }
    })
  }

  const submit = async () => {
    if (readyCount < 3) return
    // Без организации заявку подать нельзя — раньше здесь показывался фейковый «pending»
    // (RPC пропускался), из-за чего статус не сохранялся и фермер подавал по кругу. Уводим
    // достраивать регистрацию (создать орг), затем членство.
    if (!orgId) { navigate('/register', { replace: true }); return }
    setStep('submitting')
    try {
      const { error: rpcErr } = await supabase.rpc('rpc_submit_membership_application', {
        p_organization_id: orgId,
        p_membership_type: 'associate',
        p_notes: null,
      })
      // PENDING_EXISTS = заявка уже на проверке — считаем успехом (документы обновлены).
      if (rpcErr && !rpcErr.message?.includes('PENDING_EXISTS')) {
        if (rpcErr.message?.includes('ALREADY_ACTIVE')) toast.error('Членство уже активно')
        else toast.error('Не удалось отправить заявку: ' + rpcErr.message)
        setStep('docs')
        return
      }
      // Обновляем контекст → кабинет увидит applicationStatus='pending' при возврате.
      void refreshContext()
      setStep('pending')
    } catch (e) {
      toast.error('Ошибка отправки: ' + (e instanceof Error ? e.message : 'сеть'))
      setStep('docs')
    }
  }

  return (
    <AuthShell>
      <style>{ANIM_CSS}</style>
      <TopBar
        label={STEP_LABELS[step]}
        onBack={back}
        idx={idx}
        total={ORDER.length}
        hideBack={step === 'submitting' || step === 'pending'}
      />
      <AuthBody>
        <div key={step} className="mem-step">
          {step === 'intro' && <IntroStep onNext={() => setStep('docs')} />}
          {step === 'docs' && (
            <DocsStep files={files} orgId={orgId} setFile={setFile} error={error} readyCount={readyCount} onSubmit={submit} onExit={() => navigate('/cabinet')} />
          )}
          {step === 'submitting' && <SubmittingStep />}
          {step === 'pending' && <PendingStep onCabinet={() => navigate('/cabinet')} />}
        </div>
      </AuthBody>
    </AuthShell>
  )
}

function IntroStep({ onNext }: { onNext: () => void }) {
  const bullets: { Icon: IconComp; t: string; d: string }[] = [
    { Icon: Storefront, t: 'Доступ к Рынку', d: 'Продажа партий с защитой сделок.' },
    { Icon: Headset, t: 'Экспертная поддержка', d: 'Персональный менеджер и консультации.' },
    { Icon: UsersThree, t: 'Сообщество ассоциации', d: 'Прямая связь с ТУРАН и коллегами.' },
    { Icon: Tag, t: 'Партнёрские скидки', d: 'Спецусловия у поставщиков и сервисов.' },
  ]
  return (
    <>
      <H1>Членство в TURAN</H1>
      <Lede>Заявка в ассоциацию. После одобрения оплатите годовой взнос — откроется Рынок и всё, что доступно членам.</Lede>
      <div className="mem-stagger" style={{ display: 'flex', flexDirection: 'column', gap: 10, marginBottom: 24 }}>
        {bullets.map(({ Icon, t, d }) => (
          <div key={t} className="mem-press" style={{ display: 'flex', gap: 14, alignItems: 'flex-start', padding: '14px 16px', borderRadius: 14, background: T.bgC, border: `1px solid ${T.bd}` }}>
            <div style={{ width: 36, height: 36, borderRadius: 10, flexShrink: 0, background: T.bgM, display: 'grid', placeItems: 'center', color: T.accent }}>
              <Icon size={20} weight="duotone" />
            </div>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: '-0.01em' }}>{t}</div>
              <div style={{ fontSize: 13, color: T.fg2, marginTop: 3, lineHeight: 1.45 }}>{d}</div>
            </div>
          </div>
        ))}
      </div>
      <StickyDock>
        <CTA onClick={onNext}>Начать</CTA>
      </StickyDock>
    </>
  )
}

function DocsStep({
  files,
  orgId,
  setFile,
  error,
  readyCount,
  onSubmit,
  onExit,
}: {
  files: Record<SlotKey, FileMeta | null>
  orgId: string | null
  setFile: (k: SlotKey, m: FileMeta | null, err?: string) => void
  error: string | null
  readyCount: number
  onSubmit: () => void
  onExit: () => void
}) {
  return (
    <>
      <H1>Документы</H1>
      <Lede>
        Загрузите три документа. Форматы PDF, JPG, PNG · до {MAX_FILE_SIZE_MB} МБ.
        <br />
        <span style={{ color: T.fg3, fontSize: 13 }}>Черновик сохраняется — можно выйти и вернуться позже.</span>
      </Lede>

      {error && (
        <div className="mem-step" style={{ padding: '10px 14px', borderRadius: 12, background: 'rgba(224,96,80,0.1)', border: `1px solid ${T.red}`, color: T.fg, fontSize: 13, marginBottom: 12 }}>
          {error}
        </div>
      )}

      <div className="mem-stagger" style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {DOC_SLOTS.map((s) => (
          <FileSlot key={s.key} slot={s} orgId={orgId} file={files[s.key]} onFile={(m, err) => setFile(s.key, m, err)} onRemove={() => setFile(s.key, null)} />
        ))}
      </div>

      <StickyDock>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <CTA disabled={readyCount < 3} onClick={onSubmit}>
            {readyCount < 3 ? `Загрузите ещё ${3 - readyCount}` : 'Отправить на проверку'}
          </CTA>
          <button
            type="button"
            onClick={onExit}
            className="mem-press"
            style={{ appearance: 'none', background: 'transparent', border: 'none', color: T.fg2, fontFamily: T.font, fontSize: 14, fontWeight: 500, height: 40, cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}
          >
            Продолжить позже
          </button>
        </div>
      </StickyDock>
    </>
  )
}

function FileSlot({
  slot,
  orgId,
  file,
  onFile,
  onRemove,
}: {
  slot: { key: SlotKey; title: string; hint: string; Icon: IconComp }
  orgId: string | null
  file: FileMeta | null
  onFile: (m: FileMeta | null, err?: string) => void
  onRemove: () => void
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const filled = !!file
  const canPreview = !!file?.url
  const SlotIcon = slot.Icon

  const pick = () => inputRef.current?.click()
  const preview = () => {
    if (file?.url) window.open(file.url, '_blank', 'noopener,noreferrer')
  }

  const onChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    e.currentTarget.value = ''
    if (!f) return
    if (f.size > MAX_FILE_SIZE_MB * 1024 * 1024) {
      onFile(null, `Файл «${f.name}» больше ${MAX_FILE_SIZE_MB} МБ.`)
      return
    }
    setBusy(true)
    try {
      const url = URL.createObjectURL(f)
      if (!orgId) {
        // Демо/аноним — без реальной загрузки.
        onFile({ name: f.name, url })
        return
      }
      // Убираем прежний файл слота, затем загружаем новый.
      const { data: existing } = await supabase.storage.from('membership-documents').list(`${orgId}/docs`, { limit: 100 })
      const toRemove = (existing ?? []).filter((x) => x.name.startsWith(`${slot.key}_`)).map((x) => `${orgId}/docs/${x.name}`)
      if (toRemove.length) await supabase.storage.from('membership-documents').remove(toRemove)
      const ext = f.name.split('.').pop()?.toLowerCase() || 'pdf'
      const storageName = `${slot.key}_${Date.now()}.${ext}`
      const { error: upErr } = await supabase.storage.from('membership-documents').upload(`${orgId}/docs/${storageName}`, f, { upsert: true })
      if (upErr) throw upErr
      onFile({ name: f.name, storageName, url })
    } catch (err) {
      onFile(null, 'Не удалось загрузить файл: ' + (err instanceof Error ? err.message : 'ошибка'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div style={{ position: 'relative', display: 'flex', gap: 12, alignItems: 'center', padding: 12, borderRadius: 14, background: filled ? T.bgM : T.bgC, border: `1px solid ${filled ? T.accent : T.bd}`, transition: 'border-color 140ms, background 140ms' }}>
      <button
        type="button"
        onClick={busy ? undefined : canPreview ? preview : pick}
        disabled={busy}
        className="mem-press"
        style={{ appearance: 'none', font: 'inherit', textAlign: 'left', flex: 1, minWidth: 0, display: 'flex', gap: 12, alignItems: 'center', padding: 0, background: 'transparent', border: 'none', color: T.fg, cursor: busy ? 'wait' : 'pointer', WebkitTapHighlightColor: 'transparent' }}
      >
        <div style={{ width: 36, height: 36, borderRadius: 10, flexShrink: 0, background: filled ? T.accent : T.bgM, color: filled ? T.ctaFg : T.fg2, display: 'grid', placeItems: 'center', transition: 'background 200ms, color 200ms' }}>
          {busy ? (
            <CircleNotch size={18} weight="bold" style={{ animation: 'memSpin 700ms linear infinite' }} />
          ) : filled ? (
            <span style={{ display: 'inline-flex', animation: 'memPop 360ms cubic-bezier(0.16,1,0.3,1) both' }}>
              <Check size={18} weight="bold" />
            </span>
          ) : (
            <SlotIcon size={18} weight="duotone" />
          )}
        </div>
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 600, letterSpacing: '-0.01em', color: T.fg, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{slot.title}</div>
          <div style={{ fontSize: 12, color: filled ? T.fg2 : T.fg3, marginTop: 2, lineHeight: 1.35, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {busy ? 'Загружаем…' : filled ? file!.name : slot.hint}
          </div>
        </div>
      </button>

      <div style={{ display: 'inline-flex', gap: 6, alignItems: 'center', flexShrink: 0 }}>
        {canPreview && (
          <button type="button" onClick={preview} aria-label="Открыть документ" className="mem-press" style={{ appearance: 'none', background: 'transparent', border: `1px solid ${T.bd}`, color: T.fg, width: 36, height: 32, borderRadius: 999, display: 'grid', placeItems: 'center', cursor: 'pointer' }}>
            <Eye size={16} weight="bold" />
          </button>
        )}
        {filled ? (
          <>
            <button type="button" onClick={pick} disabled={busy} aria-label="Заменить файл" className="mem-press" style={{ appearance: 'none', font: 'inherit', display: 'inline-flex', alignItems: 'center', gap: 6, height: 32, padding: '0 12px', borderRadius: 999, background: 'transparent', color: T.fg2, border: `1px solid ${T.bd}`, fontSize: 13, fontWeight: 600, whiteSpace: 'nowrap', cursor: busy ? 'wait' : 'pointer' }}>
              Заменить
            </button>
            <button type="button" onClick={onRemove} aria-label="Удалить файл" className="mem-press" style={{ appearance: 'none', background: 'transparent', border: `1px solid ${T.bd}`, color: T.fg3, width: 32, height: 32, borderRadius: 999, display: 'grid', placeItems: 'center', cursor: 'pointer' }}>
              <X size={14} weight="bold" />
            </button>
          </>
        ) : (
          <button type="button" onClick={pick} disabled={busy} aria-label={`${slot.title}. Загрузить файл`} className="mem-press" style={{ appearance: 'none', font: 'inherit', display: 'inline-flex', alignItems: 'center', gap: 6, height: 32, padding: '0 12px', borderRadius: 999, background: T.cta, color: T.ctaFg, border: 'none', fontSize: 13, fontWeight: 600, whiteSpace: 'nowrap', cursor: busy ? 'wait' : 'pointer' }}>
            <Plus size={14} weight="bold" />
            Загрузить
          </button>
        )}
      </div>

      <input ref={inputRef} type="file" accept={ACCEPTED_FILE_TYPES} onChange={onChange} style={{ display: 'none' }} />
    </div>
  )
}

function SubmittingStep() {
  return (
    <div style={{ paddingTop: 120, textAlign: 'center' }}>
      <div style={{ display: 'inline-grid', placeItems: 'center', width: 56, height: 56, margin: '0 auto 20px', color: T.accent }}>
        <CircleNotch size={44} weight="bold" style={{ animation: 'memSpin 800ms linear infinite' }} />
      </div>
      <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: '-0.01em' }}>Отправляем заявку</div>
      <div style={{ fontSize: 14, color: T.fg2, marginTop: 6 }}>Секунду…</div>
    </div>
  )
}

function PendingStep({ onCabinet }: { onCabinet: () => void }) {
  return (
    <div style={{ paddingTop: 40, textAlign: 'center' }}>
      <div style={{ width: 72, height: 72, borderRadius: 999, background: 'rgba(184,113,10,0.12)', border: `1px solid ${T.accent}`, display: 'grid', placeItems: 'center', margin: '0 auto 24px', color: T.accent, animation: 'memPop 480ms cubic-bezier(0.16,1,0.3,1) both' }}>
        <Clock size={34} weight="duotone" />
      </div>
      <h1 style={{ fontFamily: T.font, fontSize: 26, lineHeight: 1.2, letterSpacing: '-0.02em', fontWeight: 600, margin: '0 0 10px' }}>Заявка на рассмотрении</h1>
      <p style={{ fontSize: 15, color: T.fg2, lineHeight: 1.5, maxWidth: 320, margin: '0 auto 20px' }}>
        Ответим в течение 3 рабочих дней. Уведомим в кабинете и по SMS. Продажа партий и Рынок откроются после одобрения и оплаты взноса.
      </p>
      <div className="mem-stagger" style={{ maxWidth: 360, margin: '0 auto 24px', padding: '14px 16px', borderRadius: 14, background: T.bgC, border: `1px solid ${T.bd}`, display: 'flex', flexDirection: 'column', gap: 10 }}>
        <TimelineRow done label="Документы отправлены" sub="Только что" />
        <TimelineRow current label="Проверка ТУРАН" sub="1–3 рабочих дня" />
        <TimelineRow label="Оплата взноса" sub="Откроется после одобрения" />
      </div>
      <StickyDock>
        <CTA onClick={onCabinet}>В кабинет</CTA>
      </StickyDock>
    </div>
  )
}

function TimelineRow({ done, current, label, sub }: { done?: boolean; current?: boolean; label: string; sub: string }) {
  const color = done ? T.accent : current ? T.fg : T.fg3
  return (
    <div style={{ display: 'flex', gap: 12, alignItems: 'center', textAlign: 'left' }}>
      <div style={{ position: 'relative', width: 22, height: 22, borderRadius: 999, flexShrink: 0, border: `1.5px solid ${done ? T.accent : current ? T.fg2 : T.bdH}`, background: done ? T.accent : 'transparent', display: 'grid', placeItems: 'center', color: T.ctaFg }}>
        {done ? (
          <Check size={12} weight="bold" />
        ) : current ? (
          <>
            <div style={{ width: 8, height: 8, borderRadius: 999, background: T.fg }} />
            <div style={{ position: 'absolute', inset: -1, borderRadius: 999, border: `1.5px solid ${T.fg2}`, animation: 'memPulse 1600ms ease-out infinite' }} />
          </>
        ) : null}
      </div>
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 14, fontWeight: 500, color }}>{label}</div>
        <div style={{ fontSize: 12, color: T.fg3, marginTop: 2 }}>{sub}</div>
      </div>
    </div>
  )
}
