/**
 * F23 — Показатели (KPI Dashboard)
 * Dok 6 Slice 4: /cabinet-legacy/plan/kpi
 * RPC: rpc_get_active_plan (RPC-37) → kpis from phases
 * Read-only for farmer.
 */
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { ArrowLeft, BarChart3 } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Progress } from '@/components/ui/progress'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'


interface Phase {
  id: string
  name_ru: string
  start_date: string
  end_date: string
}

interface PlanData {
  plan: { name: string }
  phases: Phase[]
  kpis_summary: { total: number; achieved: number; missed: number; pending: number }
}

// We need KPI details per phase — rpc_get_active_plan gives summary counts.
// For detailed KPIs, we'll use the summary and show what we have.
// Full per-phase KPI detail would need a separate RPC (future improvement).

export function KpiDashboard() {
  useSetTopbar({ title: 'Показатели', titleIcon: <BarChart3 size={15} /> })
  const navigate = useNavigate()
  const { organization, farm } = useAuth()

  const { data, isLoading } = useRpc<PlanData>('rpc_get_active_plan', {
    p_organization_id: organization?.id,
    p_farm_id: farm?.id,
  }, { enabled: !!organization?.id && !!farm?.id })

  if (isLoading) {
    return <div className="page"><Skeleton className="h-8 w-32 mb-4" /><Skeleton className="h-48 w-full" /></div>
  }

  if (!data) {
    return (
      <div className="page">
        <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/plan')}><ArrowLeft className="h-5 w-5" /></Button>
        <Card className="mt-4"><CardContent className="p-8 text-center text-muted-foreground">Нет показателей — план не создан</CardContent></Card>
      </div>
    )
  }

  const ks = data.kpis_summary

  return (
    <div className="page space-y-6">
      <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/plan')}>
        <ArrowLeft className="h-5 w-5" />
      </Button>

      {/* Summary cards */}
      <div className="grid grid-cols-3 gap-3">
        <Card>
          <CardContent className="p-4 text-center">
            <div className="text-2xl font-bold text-green-600">{ks.achieved}</div>
            <div className="text-xs text-muted-foreground">Достигнуто</div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="p-4 text-center">
            <div className="text-2xl font-bold text-destructive">{ks.missed}</div>
            <div className="text-xs text-muted-foreground">Провалено</div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="p-4 text-center">
            <div className="text-2xl font-bold text-muted-foreground">{ks.pending}</div>
            <div className="text-xs text-muted-foreground">В процессе</div>
          </CardContent>
        </Card>
      </div>

      {/* Overall progress */}
      {ks.total > 0 && (
        <Card>
          <CardContent className="p-4">
            <div className="flex justify-between text-sm mb-2">
              <span>Общий прогресс</span>
              <span>{ks.achieved + ks.missed}/{ks.total} оценено</span>
            </div>
            <Progress value={((ks.achieved + ks.missed) / ks.total) * 100} />
            <div className="flex gap-4 mt-2 text-xs text-muted-foreground">
              <span className="text-green-600">{ks.achieved} достигнуто</span>
              <span className="text-destructive">{ks.missed} провалено</span>
              <span>{ks.pending} ожидают</span>
            </div>
          </CardContent>
        </Card>
      )}

      {/* Phase list with KPI count */}
      <div className="space-y-3">
        <h3 className="font-medium">Фазы</h3>
        {data.phases.map(phase => (
          <Card key={phase.id}>
            <CardContent className="p-4">
              <div className="font-medium">{phase.name_ru}</div>
              <div className="text-xs text-muted-foreground mt-1">
                {new Date(phase.start_date).toLocaleDateString('ru-RU')} — {new Date(phase.end_date).toLocaleDateString('ru-RU')}
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      {ks.total === 0 && (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            Показатели ещё не установлены зоотехником
          </CardContent>
        </Card>
      )}
    </div>
  )
}
