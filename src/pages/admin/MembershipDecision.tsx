import { useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ArrowLeft, CheckCircle, XCircle, Loader2, Building2, MapPin, Hash, Calendar, Users, Users2, Leaf, FileText, Download } from 'lucide-react'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { useAuth } from '@/hooks/useAuth'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'
import { useOrgDocuments } from '@/hooks/admin/useOrgDocuments'
import { REQUIRED_DOCUMENTS } from '@/types/application-flow'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Skeleton } from '@/components/ui/skeleton'
import { StatusBadge } from '@/components/ui/status-badge'

/**
 * A02 — Membership Decision
 * Dok 6 Slice 2: Admin reviews application detail, approves or rejects.
 * RPCs: rpc_get_membership_queue (detail mode), rpc_process_membership_application (RPC-03)
 */

interface HerdGroup {
  category_code: string
  category_name: string
  breed_name: string | null
  head_count: number
  avg_weight_kg: number | null
}

interface FarmData {
  farm_id: string
  farm_name: string
  herd_groups: HerdGroup[]
  activity_types: string[]
}

interface AppHistory {
  id: string
  status: string
  from_level: string
  to_level: string
  submitted_at: string
  reviewed_at: string | null
  reviewer_notes: string | null
}

interface ApplicationDetail {
  application_id: string
  org_id: string
  org_name: string
  org_type: string
  bin: string | null
  region_name: string | null
  org_created_at: string
  from_level: string
  to_level: string
  status: string
  submitted_at: string
  notes: string | null
  reviewed_at: string | null
  reviewed_by: string | null
  reviewer_name: string | null
  membership_level: string
  membership_level_changed_at: string
  farms: FarmData[]
  application_history: AppHistory[]
}

const STATUS_LABELS: Record<string, string> = {
  submitted: 'Ожидает',
  under_review: 'На рассмотрении',
  approved: 'Одобрено',
  rejected: 'Отклонено',
}

const ORG_TYPE_LABELS: Record<string, string> = {
  farmer: 'Фермер',
  mpk: 'МПК',
  supplier: 'Поставщик',
  consultant: 'Консультант',
  services: 'Услуги',
  feed_producer: 'Кормопроизводитель',
  other: 'Другое',
}

const LEVEL_LABELS: Record<string, string> = {
  registered: 'Зарегистрирован',
  observer: 'Наблюдатель',
  declared_supplier: 'Заявленный поставщик',
  standard_supplier: 'Стандартный поставщик',
  active_buyer: 'Активный покупатель',
}

// Подписи слотов документов (для просмотра админом).
const DOC_LABELS: Record<string, string> = {
  registration_certificate: 'Документ о гос. регистрации',
  identity_document: 'Удостоверение личности руководителя',
  bank_details: 'Банковские реквизиты',
}

export function MembershipDecision() {
  useSetTopbar({ title: 'Рассмотрение заявки', titleIcon: <Users size={15} /> })
  const { applicationId } = useParams<{ applicationId: string }>()
  const navigate = useNavigate()
  const { organization } = useAuth()

  const [reviewerNotes, setReviewerNotes] = useState('')
  const [confirmAction, setConfirmAction] = useState<'approved' | 'rejected' | null>(null)

  const { data: detail, isLoading } = useRpc<ApplicationDetail>(
    'rpc_get_membership_queue',
    {
      p_organization_id: organization?.id ?? '00000000-0000-0000-0000-000000000000',
      p_application_id: applicationId,
    },
    { enabled: !!applicationId }
  )

  const { data: orgDocs, downloadFile } = useOrgDocuments(detail?.org_id)

  const processMutation = useRpcMutation<Record<string, unknown>, string>(
    'rpc_process_membership_application',
    {
      successMessage: confirmAction === 'approved' ? 'Заявка одобрена' : 'Заявка отклонена',
      invalidateKeys: [['rpc_get_membership_queue']],
      onSuccess: () => {
        navigate('/admin/applications/level')
      },
    }
  )

  const handleDecision = () => {
    if (!confirmAction || !applicationId) return
    processMutation.mutate({
      p_organization_id: organization?.id ?? '00000000-0000-0000-0000-000000000000',
      p_application_id: applicationId,
      p_decision: confirmAction,
      p_decision_notes: reviewerNotes || null,
    })
    setConfirmAction(null)
  }

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-32 w-full rounded-xl" />
        <Skeleton className="h-40 w-full rounded-xl" />
        <Skeleton className="h-24 w-full rounded-xl" />
      </div>
    )
  }

  if (!detail) {
    return (
      <div className="space-y-4">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="icon" onClick={() => navigate('/admin/applications/level')}>
            <ArrowLeft className="h-5 w-5" />
          </Button>
          <span className="text-sm text-muted-foreground">Назад к списку</span>
        </div>
        <div className="p-6 bg-card rounded-[10px] border border-border text-center">
          <p className="text-sm text-[var(--fg2)]">Заявка не найдена</p>
        </div>
      </div>
    )
  }

  const canDecide = detail.status === 'submitted' || detail.status === 'under_review'
  const totalHeads = detail.farms.reduce(
    (sum, f) => sum + f.herd_groups.reduce((s, hg) => s + hg.head_count, 0), 0
  )

  return (
    <div className="page space-y-5">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="icon" onClick={() => navigate('/admin/applications/level')}>
            <ArrowLeft className="h-5 w-5" />
          </Button>
          <h2 className="text-xl font-semibold">Заявка на членство</h2>
        </div>
        <StatusBadge status={detail.status} label={STATUS_LABELS[detail.status] ?? detail.status} />
      </div>

      {/* Organization card */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-[10px] flex items-center justify-center bg-[var(--bg-s)]">
            <Building2 className="h-5 w-5 text-[var(--fg2)]" />
          </div>
          <div>
            <h3 className="font-medium text-[var(--fg)]">{detail.org_name}</h3>
            <span className="text-xs text-[var(--fg2)]">
              {ORG_TYPE_LABELS[detail.org_type] ?? detail.org_type}
            </span>
          </div>
        </div>
        <div className="grid grid-cols-2 gap-3 text-sm">
          {detail.bin && (
            <div className="flex items-center gap-2 text-[var(--fg2)]">
              <Hash className="h-3.5 w-3.5" />
              <span>БИН: {detail.bin}</span>
            </div>
          )}
          {detail.region_name && (
            <div className="flex items-center gap-2 text-[var(--fg2)]">
              <MapPin className="h-3.5 w-3.5" />
              <span>{detail.region_name}</span>
            </div>
          )}
          <div className="flex items-center gap-2 text-[var(--fg2)]">
            <Calendar className="h-3.5 w-3.5" />
            <span>Регистрация: {new Date(detail.org_created_at).toLocaleDateString('ru-RU')}</span>
          </div>
          <div className="flex items-center gap-2 text-[var(--fg2)]">
            <Users2 className="h-3.5 w-3.5" />
            <span>Уровень: {LEVEL_LABELS[detail.membership_level] ?? detail.membership_level}</span>
          </div>
        </div>
      </div>

      {/* Farm summary (if farmer) */}
      {detail.farms.length > 0 && (
        <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
          <h3 className="text-sm font-medium text-[var(--fg)] flex items-center gap-2">
            <Leaf className="h-4 w-4" style={{ color: 'var(--green)' }} />
            Хозяйство
          </h3>
          {detail.farms.map((farm) => (
            <div key={farm.farm_id} className="space-y-2">
              <p className="text-sm font-medium text-[var(--fg)]">{farm.farm_name}</p>

              {farm.herd_groups.length > 0 && (
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="text-[var(--fg2)] border-b border-[var(--bd)]">
                        <th className="text-left py-1.5 font-medium">Группа</th>
                        <th className="text-left py-1.5 font-medium">Порода</th>
                        <th className="text-right py-1.5 font-medium">Голов</th>
                        <th className="text-right py-1.5 font-medium">Ср. вес</th>
                      </tr>
                    </thead>
                    <tbody>
                      {farm.herd_groups.map((hg, idx) => (
                        <tr key={idx} className="border-b border-[var(--bg-s)] last:border-0">
                          <td className="py-1.5 text-[var(--fg)]">{hg.category_name}</td>
                          <td className="py-1.5 text-[var(--fg2)]">{hg.breed_name ?? '—'}</td>
                          <td className="py-1.5 text-right text-[var(--fg)]">{hg.head_count}</td>
                          <td className="py-1.5 text-right text-[var(--fg2)]">
                            {hg.avg_weight_kg ? `${hg.avg_weight_kg} кг` : '—'}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              {totalHeads > 0 && (
                <p className="text-xs text-[var(--fg2)]">Всего: {totalHeads} голов</p>
              )}

              {farm.activity_types.length > 0 && (
                <div className="flex flex-wrap gap-1.5">
                  {farm.activity_types.map((at, idx) => (
                    <span key={idx} className="px-2 py-0.5 rounded text-[10px]" style={{ background: 'rgba(58,138,82,0.08)', color: 'var(--green)' }}>
                      {at}
                    </span>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Documents (from Storage: membership-documents/{orgId}/docs) */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
        <h3 className="text-sm font-medium text-[var(--fg)] flex items-center gap-2">
          <FileText className="h-4 w-4 text-[var(--fg2)]" />
          Документы заявки
        </h3>
        <div className="space-y-2">
          {REQUIRED_DOCUMENTS.map((slot) => {
            const path = orgDocs?.documents[slot.key] ?? null
            return (
              <div key={slot.key} className="flex items-center justify-between text-sm p-2.5 bg-[var(--bg)] rounded-lg">
                <div className="flex items-center gap-2 min-w-0">
                  {path
                    ? <CheckCircle className="h-4 w-4 shrink-0" style={{ color: 'var(--green)' }} />
                    : <XCircle className="h-4 w-4 shrink-0" style={{ color: 'var(--fg3)' }} />}
                  <span className={'truncate ' + (path ? 'text-[var(--fg)]' : 'text-[var(--fg3)]')}>
                    {DOC_LABELS[slot.key] ?? slot.key}
                  </span>
                </div>
                {path && (
                  <button
                    onClick={() => downloadFile(path)}
                    className="flex items-center gap-1.5 px-2.5 py-1 text-xs rounded-md border border-[var(--bd)] text-[var(--fg2)] hover:bg-[var(--bg-s)] transition-colors shrink-0"
                  >
                    <Download className="h-3.5 w-3.5" />
                    Открыть
                  </button>
                )}
              </div>
            )
          })}
        </div>
        {!orgDocs?.allDocsUploaded && (
          <p className="text-xs text-[var(--fg3)]">Не все обязательные документы загружены.</p>
        )}
      </div>

      {/* Application info */}
      <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
        <h3 className="text-sm font-medium text-[var(--fg)]">Заявка</h3>
        <div className="flex items-center gap-2 text-sm text-[var(--fg2)]">
          <span>{LEVEL_LABELS[detail.from_level] ?? detail.from_level}</span>
          <span>→</span>
          <span className="font-medium text-[var(--fg)]">{LEVEL_LABELS[detail.to_level] ?? detail.to_level}</span>
        </div>
        <p className="text-xs text-[var(--fg3)]">
          Подана: {new Date(detail.submitted_at).toLocaleDateString('ru-RU', {
            day: 'numeric', month: 'long', year: 'numeric'
          })}
        </p>
        {detail.notes && (
          <blockquote className="text-sm text-[var(--fg)]/80 bg-[var(--bg)] p-3 rounded-lg border-l-3 border-[var(--blue)] italic">
            {detail.notes}
          </blockquote>
        )}
      </div>

      {/* Application history */}
      {detail.application_history.length > 0 && (
        <div className="bg-card rounded-[10px] border border-border p-5 space-y-3">
          <h3 className="text-sm font-medium text-[var(--fg)]">Предыдущие заявки</h3>
          <div className="space-y-2">
            {detail.application_history.map((prev) => (
                <div key={prev.id} className="flex items-center justify-between text-xs p-2 bg-[var(--bg)] rounded-lg">
                  <div className="flex items-center gap-2">
                    <StatusBadge status={prev.status} label={STATUS_LABELS[prev.status] ?? prev.status} showDot={false} />
                    <span className="text-[var(--fg2)]">
                      {new Date(prev.submitted_at).toLocaleDateString('ru-RU')}
                    </span>
                  </div>
                  {prev.reviewer_notes && (
                    <span className="text-[var(--fg3)] truncate max-w-[200px]">{prev.reviewer_notes}</span>
                  )}
                </div>
              ))}
          </div>
        </div>
      )}

      {/* Decision result (if already decided) */}
      {!canDecide && (detail.status === 'approved' || detail.status === 'rejected') && (
        <div
          className="rounded-[10px] border p-5 space-y-2"
          style={{
            background: detail.status === 'approved' ? 'rgba(58,138,82,0.08)' : 'rgba(192,57,43,0.08)',
            borderColor: detail.status === 'approved' ? 'var(--green)' : 'var(--red)',
          }}
        >
          <div className="flex items-center gap-2">
            {detail.status === 'approved'
              ? <CheckCircle className="h-5 w-5" style={{ color: 'var(--green)' }} />
              : <XCircle className="h-5 w-5" style={{ color: 'var(--red)' }} />
            }
            <span className="font-medium text-sm" style={{ color: detail.status === 'approved' ? 'var(--green)' : 'var(--red)' }}>
              {detail.status === 'approved' ? 'Заявка одобрена' : 'Заявка отклонена'}
            </span>
          </div>
          {detail.reviewed_at && (
            <p className="text-xs text-[var(--fg2)]">
              {new Date(detail.reviewed_at).toLocaleDateString('ru-RU', {
                day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit'
              })}
              {detail.reviewer_name && ` — ${detail.reviewer_name}`}
            </p>
          )}
          {detail.notes && <p className="text-sm text-[var(--fg2)]">{detail.notes}</p>}
        </div>
      )}

      {/* Decision section (only for pending applications) */}
      {canDecide && (
        <div className="bg-card rounded-[10px] border border-border p-5 space-y-4">
          <h3 className="text-sm font-medium text-[var(--fg)]">Решение</h3>

          <textarea
            value={reviewerNotes}
            onChange={(e) => setReviewerNotes(e.target.value)}
            placeholder="Комментарий к решению (опционально)"
            maxLength={1000}
            rows={3}
            className="w-full px-3 py-2 text-sm border border-[var(--bd)] rounded-lg bg-[var(--bg)] focus:outline-none focus:ring-2 focus:ring-[var(--blue)] focus:border-[var(--blue)] resize-none"
          />

          <div className="flex gap-3">
            <button
              onClick={() => setConfirmAction('approved')}
              disabled={processMutation.isPending}
              aria-label="Одобрить заявку"
              className="flex-1 flex items-center justify-center gap-2 px-4 py-2.5 text-white rounded-lg font-medium text-sm hover:brightness-90 disabled:opacity-50 transition-colors"
              style={{ background: 'var(--green)' }}
            >
              <CheckCircle className="h-4 w-4" />
              Одобрить
            </button>
            <button
              onClick={() => setConfirmAction('rejected')}
              disabled={processMutation.isPending}
              aria-label="Отклонить заявку"
              className="flex-1 flex items-center justify-center gap-2 px-4 py-2.5 text-white rounded-lg font-medium text-sm hover:brightness-90 disabled:opacity-50 transition-colors"
              style={{ background: 'var(--red)' }}
            >
              <XCircle className="h-4 w-4" />
              Отклонить
            </button>
          </div>
        </div>
      )}

      {/* Confirmation dialog */}
      <Dialog open={!!confirmAction} onOpenChange={(open) => { if (!open) setConfirmAction(null) }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {confirmAction === 'approved' ? 'Одобрить заявку?' : 'Отклонить заявку?'}
            </DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            {confirmAction === 'approved'
              ? `Заявка ${detail?.org_name} будет одобрена. Членство (${LEVEL_LABELS[detail?.to_level ?? ''] ?? detail?.to_level}) активируется после оплаты взноса. Фермер получит уведомление в WhatsApp.`
              : `Заявка ${detail?.org_name} будет отклонена. Фермер получит уведомление в WhatsApp.`
            }
          </p>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmAction(null)}>Отмена</Button>
            <Button
              onClick={handleDecision}
              disabled={processMutation.isPending}
              style={{ background: confirmAction === 'approved' ? 'var(--green)' : 'var(--red)', color: '#fff' }}
            >
              {processMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Подтвердить'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
