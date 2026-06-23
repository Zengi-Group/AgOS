import { useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ArrowLeft, Loader2, AlertTriangle, Clock, Shield, Stethoscope } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { StatusBadge, SeverityBadge } from '@/components/ui/status-badge'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

interface VetCaseData {
  case_id: string
  farm_id: string
  farm_name: string
  herd_group: { id: string; category_name: string; head_count: number } | null
  status: 'open' | 'in_progress' | 'resolved' | 'escalated'
  severity: 'minor' | 'moderate' | 'severe' | 'critical' | null
  symptoms_text: string
  symptoms_structured: { symptom_code: string; confidence: number }[] | null
  affected_heads: number | null
  created_at: string
  created_via: string
  diagnoses: {
    id: string
    disease_name: string
    confidence_pct: number
    source: string
    created_at: string
  }[]
  recommendations: {
    id: string
    type: string
    treatment_name: string | null
    application_method: string | null
    duration_days: number | null
    dosage_note: string
    withdrawal_days: number | null
    notes: string | null
    source: string
    created_at: string
  }[]
  health_restrictions: {
    restriction_type: string
    reason: string
    expires_at: string
  }[]
  consultation_request: {
    id: string | null
    status: string | null
    expert_name: string | null
  } | null
}

const CREATED_VIA_LABELS: Record<string, string> = {
  cabinet_farmer: 'Кабинет',
  ai_whatsapp: 'WhatsApp',
  expert_manual: 'Эксперт',
}

const REC_TYPE_LABELS: Record<string, string> = {
  medication: 'Лечение',
  isolation: 'Изоляция',
  nutrition: 'Питание',
  monitoring: 'Наблюдение',
  specialist: 'Специалист',
}

export function VetCaseDetail() {
  const { caseId } = useParams<{ caseId: string }>()
  const { organization } = useAuth()
  const navigate = useNavigate()
  useSetTopbar({ title: 'Ветеринарный случай', titleIcon: <Stethoscope size={15} /> })

  const [vetCase, setVetCase] = useState<VetCaseData | null>(null)
  const [aiMessages, setAiMessages] = useState<Array<{role: string; content_text: string; created_at: string}>>([])
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [realtimeStatus, setRealtimeStatus] = useState<'connecting' | 'live' | 'error'>('connecting')

  // Load case data
  const loadCase = async () => {
    if (!organization?.id || !caseId) return

    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_get_vet_case_detail', {
        p_organization_id: organization.id,
        p_vet_case_id: caseId,
      })

      if (rpcError) {
        setError(rpcError.message || 'Ошибка загрузки')
        return
      }

      setVetCase(data as unknown as VetCaseData)

      // AI messages come from RPC now (via conversation_id link)
      const caseData = data as any
      if (caseData?.ai_messages) {
        setAiMessages(caseData.ai_messages)
      }
    } catch (err) {
      setError('Ошибка загрузки данных')
      console.error(err)
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => {
    loadCase()
  }, [organization?.id, caseId])

  // Poll for AI response every 3s until we get one
  useEffect(() => {
    if (!organization?.id || !caseId) return
    if (aiMessages.length > 0) { setRealtimeStatus('live'); return }

    setRealtimeStatus('connecting')
    const interval = setInterval(() => {
      loadCase()
    }, 3000)

    // Stop polling after 60s
    const timeout = setTimeout(() => {
      clearInterval(interval)
      setRealtimeStatus('error')
    }, 60000)

    return () => { clearInterval(interval); clearTimeout(timeout) }
  }, [organization?.id, caseId, aiMessages.length])

  if (isLoading) {
    return (
      <div className="space-y-4">
        <div className="flex items-center gap-3">
          <Skeleton className="h-8 w-8 rounded" />
          <Skeleton className="h-6 w-48" />
        </div>
        <Skeleton className="h-20 w-full rounded-xl" />
        <Skeleton className="h-32 w-full rounded-xl" />
        <Skeleton className="h-40 w-full rounded-xl" />
        <Skeleton className="h-40 w-full rounded-xl" />
      </div>
    )
  }

  if (error || !vetCase) {
    return (
      <div className="space-y-4">
        <button
          onClick={() => navigate('/cabinet-legacy/vet')}
          className="flex items-center gap-2 text-sm text-[var(--fg2)] hover:text-[var(--fg)]"
        >
          <ArrowLeft className="h-4 w-4" />
          Назад
        </button>
        <div className="p-4 rounded-xl text-center" style={{ background: 'rgba(192,57,43,0.08)' }}>
          <p className="text-sm" style={{ color: 'var(--red)' }}>{error || 'Случай не найден'}</p>
          <button
            onClick={loadCase}
            className="mt-2 text-sm underline" style={{ color: 'var(--red)' }}
          >
            Повторить
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="page space-y-5">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/vet')}>
            <ArrowLeft className="h-5 w-5" />
          </Button>
          <div>
            <div className="flex items-center gap-2">
              <StatusBadge status={vetCase.status} />
              <SeverityBadge severity={vetCase.severity} />
            </div>
          </div>
        </div>

        {/* Realtime indicator */}
        <div className="flex items-center gap-1.5" title={
          realtimeStatus === 'live' ? 'Обновления в реальном времени' : 'Подключение...'
        }>
          <div
            className={cn(
              'w-2 h-2 rounded-full',
              realtimeStatus === 'live' ? 'animate-pulse' : ''
            )}
            style={{
              background: realtimeStatus === 'live' ? 'var(--green)' :
                realtimeStatus === 'error' ? 'var(--red)' : 'var(--fg3)'
            }}
          />
        </div>
      </div>

      {/* Escalation banner */}
      {vetCase.status === 'escalated' && (
        <div className="p-3 rounded-xl flex items-start gap-3" style={{ background: 'rgba(192,57,43,0.08)', border: '1px solid rgba(192,57,43,0.15)' }}>
          <Shield className="h-5 w-5 shrink-0 mt-0.5" style={{ color: 'var(--red)' }} />
          <div>
            <p className="text-sm font-medium" style={{ color: 'var(--red)' }}>
              Случай передан эксперту-ветеринару ТУРАН
            </p>
            {vetCase.consultation_request?.expert_name && (
              <p className="text-xs mt-0.5" style={{ color: 'var(--red)' }}>
                Эксперт: {vetCase.consultation_request.expert_name}
              </p>
            )}
          </div>
        </div>
      )}

      {/* Withdrawal/restriction banner */}
      {vetCase.health_restrictions.length > 0 && (
        <div className="p-3 rounded-xl flex items-start gap-3" style={{ background: 'rgba(179,122,16,0.08)', border: '1px solid rgba(179,122,16,0.15)' }}>
          <AlertTriangle className="h-5 w-5 shrink-0 mt-0.5" style={{ color: 'var(--amber)' }} />
          <div>
            {vetCase.health_restrictions.map((hr, idx) => (
              <p key={idx} className="text-sm" style={{ color: 'var(--amber)' }}>
                Ограничение на продажу до {new Date(hr.expires_at).toLocaleDateString('ru-RU')}
                {hr.reason && <span className="text-xs block" style={{ color: 'var(--amber)' }}>{hr.reason}</span>}
              </p>
            ))}
          </div>
        </div>
      )}

      {/* Case info */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-2">
        <div className="flex items-center justify-between text-xs text-[var(--fg2)]">
          <span>
            {new Date(vetCase.created_at).toLocaleDateString('ru-RU', {
              day: 'numeric',
              month: 'long',
              year: 'numeric',
              hour: '2-digit',
              minute: '2-digit',
            })}
          </span>
          <span className="px-2 py-0.5 bg-[var(--bg)] rounded text-[10px]">
            {CREATED_VIA_LABELS[vetCase.created_via] || vetCase.created_via}
          </span>
        </div>
        {vetCase.farm_name && (
          <p className="text-sm text-[var(--fg)]">
            {vetCase.farm_name}
            {vetCase.herd_group && ` / ${vetCase.herd_group.category_name} (${vetCase.herd_group.head_count} гол.)`}
          </p>
        )}
        {vetCase.affected_heads && (
          <p className="text-xs text-[var(--fg2)]">
            Больных голов: {vetCase.affected_heads}
          </p>
        )}
      </div>

      {/* Symptoms */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
        <h3 className="text-sm font-medium text-[var(--fg)]">Симптомы</h3>
        <blockquote className="text-sm text-[var(--fg)]/80 bg-[var(--bg)] p-3 rounded-lg border-l-3 border-[var(--cta)] italic">
          {vetCase.symptoms_text}
        </blockquote>

        {vetCase.symptoms_structured && vetCase.symptoms_structured.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {vetCase.symptoms_structured.map((s, idx) => (
              <span
                key={idx}
                className="px-2.5 py-1 bg-[var(--bg)] rounded-full text-xs text-[var(--fg)]/70 border border-[var(--bd)]"
              >
                {s.symptom_code}
              </span>
            ))}
          </div>
        )}
      </div>

      {/* AI Response */}
      {aiMessages.filter(m => m.role === 'assistant').length > 0 && (
        <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
          <h3 className="text-sm font-medium text-[var(--fg)]">Ответ AI-ветеринара</h3>
          {aiMessages.filter(m => m.role === 'assistant').map((msg, idx) => (
            <div key={idx} className="p-3 bg-[var(--bg)] rounded-lg text-sm text-[var(--fg)]/80 whitespace-pre-wrap">
              {msg.content_text}
              <p className="text-[10px] text-[var(--fg2)] mt-2">
                {new Date(msg.created_at).toLocaleString('ru-RU')}
              </p>
            </div>
          ))}
        </div>
      )}

      {/* Diagnoses */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
        <h3 className="text-sm font-medium text-[var(--fg)]">Диагноз</h3>

        {vetCase.diagnoses.length > 0 ? (
          <div className="space-y-3">
            {vetCase.diagnoses.map((diag) => (
              <div key={diag.id} className="space-y-1.5">
                <div className="flex items-center justify-between">
                  <span className="text-sm font-medium text-[var(--fg)]">
                    {diag.disease_name}
                  </span>
                  <span className="text-xs text-[var(--fg2)] px-2 py-0.5 bg-[var(--bg)] rounded">
                    {diag.source === 'ai_analysis' ? 'AI-анализ' : 'Эксперт'}
                  </span>
                </div>
                {/* Confidence bar */}
                <div className="flex items-center gap-2">
                  <div className="flex-1 h-2 bg-[var(--bd)] rounded-full overflow-hidden">
                    <div
                      className="h-full rounded-full transition-all duration-500"
                      style={{
                        width: `${diag.confidence_pct}%`,
                        background: diag.confidence_pct >= 70 ? 'var(--green)' : diag.confidence_pct >= 40 ? 'var(--amber)' : 'var(--red)',
                      }}
                    />
                  </div>
                  <span className="text-xs text-[var(--fg2)] w-10 text-right">
                    {diag.confidence_pct}%
                  </span>
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="flex items-center gap-2 py-4 justify-center">
            <Loader2 className="h-4 w-4 animate-spin text-[var(--fg2)]" />
            <span className="text-sm text-[var(--fg2)]">
              AI анализирует симптомы...
            </span>
          </div>
        )}
      </div>

      {/* Recommendations */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
        <h3 className="text-sm font-medium text-[var(--fg)]">Рекомендации</h3>

        {vetCase.recommendations.length > 0 ? (
          <div className="space-y-3">
            {vetCase.recommendations.map((rec) => (
              <div
                key={rec.id}
                className="p-3 bg-[var(--bg)] rounded-lg border border-[var(--bd)] space-y-2"
              >
                <div className="flex items-center justify-between">
                  <span className="text-sm font-medium text-[var(--fg)]">
                    {REC_TYPE_LABELS[rec.type] || rec.type}
                    {rec.treatment_name ? `: ${rec.treatment_name}` : ''}
                  </span>
                  <span className="text-[10px] text-[var(--fg2)] px-1.5 py-0.5 bg-[var(--bg-c)] rounded">
                    {rec.source === 'ai_generated' ? 'AI' :
                     rec.source === 'expert_manual' ? 'Эксперт' : 'Протокол'}
                  </span>
                </div>

                {rec.application_method && (
                  <p className="text-xs text-[var(--fg2)]">
                    Способ: {rec.application_method}
                  </p>
                )}

                {rec.duration_days && (
                  <p className="text-xs text-[var(--fg2)]">
                    Длительность: {rec.duration_days} дней
                  </p>
                )}

                {/* P-AI-4 CRITICAL: NEVER show numeric dosage */}
                <p className="text-xs px-2 py-1.5 rounded flex items-center gap-1.5" style={{ color: 'var(--amber)', background: 'rgba(179,122,16,0.08)' }}>
                  <AlertTriangle className="h-3 w-3 shrink-0" />
                  {rec.dosage_note || 'Дозировку определяет ветеринарный врач'}
                </p>

                {rec.withdrawal_days != null && rec.withdrawal_days > 0 && (
                  <p className="text-xs px-2 py-1.5 rounded flex items-center gap-1.5" style={{ color: 'var(--red)', background: 'rgba(192,57,43,0.08)' }}>
                    <Clock className="h-3 w-3 shrink-0" />
                    Период выведения: {rec.withdrawal_days} дней
                  </p>
                )}

                {rec.notes && (
                  <p className="text-xs text-[var(--fg2)] italic">{rec.notes}</p>
                )}
              </div>
            ))}
          </div>
        ) : (
          <div className="flex items-center gap-2 py-4 justify-center">
            <Loader2 className="h-4 w-4 animate-spin text-[var(--fg2)]" />
            <span className="text-sm text-[var(--fg2)]">
              Рекомендации будут добавлены после анализа
            </span>
          </div>
        )}
      </div>

      {/* Timeline placeholder */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
        <h3 className="text-sm font-medium text-[var(--fg)]">Хронология</h3>
        <div className="space-y-3">
          {/* Case created */}
          <div className="flex items-start gap-3">
            <div className="w-2 h-2 rounded-full bg-[var(--cta)] mt-1.5 shrink-0" />
            <div>
              <p className="text-xs text-[var(--fg)]">Обращение создано</p>
              <p className="text-[10px] text-[var(--fg2)]">
                {new Date(vetCase.created_at).toLocaleDateString('ru-RU', {
                  day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'
                })}
              </p>
            </div>
          </div>

          {/* Diagnoses */}
          {vetCase.diagnoses.map((d) => (
            <div key={d.id} className="flex items-start gap-3">
              <div className="w-2 h-2 rounded-full mt-1.5 shrink-0" style={{ background: 'var(--blue)' }} />
              <div>
                <p className="text-xs text-[var(--fg)]">Диагноз: {d.disease_name}</p>
                <p className="text-[10px] text-[var(--fg2)]">
                  {new Date(d.created_at).toLocaleDateString('ru-RU', {
                    day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'
                  })}
                </p>
              </div>
            </div>
          ))}

          {/* Recommendations */}
          {vetCase.recommendations.map((r) => (
            <div key={r.id} className="flex items-start gap-3">
              <div className="w-2 h-2 rounded-full mt-1.5 shrink-0" style={{ background: 'var(--green)' }} />
              <div>
                <p className="text-xs text-[var(--fg)]">
                  Рекомендация: {r.treatment_name || REC_TYPE_LABELS[r.type] || r.type}
                </p>
                <p className="text-[10px] text-[var(--fg2)]">
                  {new Date(r.created_at).toLocaleDateString('ru-RU', {
                    day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'
                  })}
                </p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
