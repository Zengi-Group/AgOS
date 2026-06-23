/**
 * F12 — Мои ветеринарные случаи (Farmer Vet Case List)
 * Route: /cabinet-legacy/vet
 * Shows all vet cases for the farmer's organization.
 */
import React from 'react'
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Plus, ChevronRight, Stethoscope } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'

interface VetCaseSummary {
  id: string
  severity: string | null
  status: string
  symptoms_text: string | null
  affected_head_count: number | null
  created_at: string
  created_via: string
}

interface FarmSummary {
  active_vet_cases: VetCaseSummary[]
}

const STATUS_LABELS: Record<string, { label: string; variant: 'default' | 'secondary' | 'outline' | 'destructive' }> = {
  open: { label: 'Открыт', variant: 'default' },
  in_progress: { label: 'В работе', variant: 'default' },
  escalated: { label: 'У эксперта', variant: 'destructive' },
  resolved: { label: 'Закрыт', variant: 'outline' },
}

const SEVERITY_STYLES: Record<string, React.CSSProperties> = {
  critical: { background: 'var(--red)',   color: '#fff' },
  severe:   { background: 'var(--amber)', color: '#fff' },
  moderate: { background: 'var(--amber)', color: '#fff' },
  mild:     { background: 'var(--green)', color: '#fff' },
}

export function VetCaseList() {
  useSetTopbar({ title: 'Ветеринария', titleIcon: <Stethoscope size={15} /> })
  const navigate = useNavigate()
  const { organization, farm } = useAuth()

  const { data, isLoading } = useRpc<FarmSummary>('rpc_get_farm_summary', {
    p_organization_id: organization?.id,
    p_farm_id: farm?.id,
  }, { enabled: !!organization?.id && !!farm?.id })

  const cases = data?.active_vet_cases ?? []

  if (isLoading) {
    return (
      <div className="page space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-24 w-full" />
      </div>
    )
  }

  return (
    <div className="page space-y-6">
      <div className="flex items-center justify-between">
        {cases.length > 0 && (
          <p className="text-sm text-muted-foreground">
            {cases.length} активных обращений
          </p>
        )}
        <Button onClick={() => navigate('/cabinet-legacy/vet/new')}>
          <Plus className="mr-2 h-4 w-4" />
          Сообщить о болезни
        </Button>
      </div>

      {cases.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center">
            <p className="text-muted-foreground mb-4">
              Нет активных ветеринарных обращений
            </p>
            <Button variant="outline" onClick={() => navigate('/cabinet-legacy/vet/new')}>
              <Plus className="mr-2 h-4 w-4" />
              Создать обращение
            </Button>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {cases.map((c) => {
            const st = STATUS_LABELS[c.status] ?? { label: c.status, variant: 'secondary' as const }
            return (
              <Card
                key={c.id}
                className="cursor-pointer hover:border-primary/50 transition-colors"
                onClick={() => navigate(`/cabinet-legacy/vet/${c.id}`)}
              >
                <CardContent className="p-4">
                  <div className="flex items-start justify-between">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 mb-2">
                        {c.severity && (
                          <Badge className="text-xs" style={SEVERITY_STYLES[c.severity]}>
                            {c.severity}
                          </Badge>
                        )}
                        <Badge variant={st.variant} className="text-xs">
                          {st.label}
                        </Badge>
                      </div>
                      <p className="text-sm line-clamp-2">
                        {c.symptoms_text || 'Нет описания симптомов'}
                      </p>
                      <div className="flex items-center gap-3 mt-2 text-xs text-muted-foreground">
                        {c.affected_head_count && (
                          <span>{c.affected_head_count} гол.</span>
                        )}
                        <span>
                          {new Date(c.created_at).toLocaleDateString('ru-RU', {
                            day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'
                          })}
                        </span>
                      </div>
                    </div>
                    <ChevronRight className="h-5 w-5 text-muted-foreground flex-shrink-0 ml-3" />
                  </div>
                </CardContent>
              </Card>
            )
          })}
        </div>
      )}
    </div>
  )
}
