/**
 * F19 — Производственный план (Production Plan Overview)
 * Dok 6 Slice 4: /cabinet-legacy/plan
 * RPC: rpc_get_active_plan (RPC-37)
 */
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { ListChecks, Clock, BarChart3, ChevronRight, ClipboardList } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Progress } from '@/components/ui/progress'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'

interface Phase {
  id: string
  name_ru: string
  herd_group_id: string | null
  herd_group_name: string | null
  start_date: string
  end_date: string
  status: string
  is_sale_phase: boolean
  tasks_total: number
  tasks_completed: number
  tasks_overdue: number
}

interface PlanData {
  plan: {
    id: string; name: string; status: string
    cycle_start_date: string; cycle_end_date: string
    expert_name: string | null; template_name: string | null
  }
  phases: Phase[]
  tasks_summary: { total: number; completed: number; overdue: number; upcoming_7d: number }
  kpis_summary: { total: number; achieved: number; missed: number; pending: number }
}

const STATUS_COLORS: Record<string, string> = {
  upcoming: 'secondary', active: 'default', completed: 'outline', skipped: 'secondary',
  draft: 'secondary', cancelled: 'destructive',
}

export function ProductionPlan() {
  useSetTopbar({ title: 'Производственный план', titleIcon: <ClipboardList size={15} /> })
  const navigate = useNavigate()
  const { organization, farm } = useAuth()

  const { data, isLoading } = useRpc<PlanData>('rpc_get_active_plan', {
    p_organization_id: organization?.id,
    p_farm_id: farm?.id,
  }, { enabled: !!organization?.id && !!farm?.id })

  if (isLoading) {
    return (
      <div className="page space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-32 w-full" />
        <Skeleton className="h-24 w-full" />
      </div>
    )
  }

  if (!data) {
    return (
      <div className="page">
        <Card>
          <CardContent className="p-8 text-center">
            <p className="text-muted-foreground mb-2">
              План будет создан зоотехником ТУРАН
            </p>
            <p className="text-sm text-muted-foreground">
              После присвоения зоотехника вы увидите план кормления, задачи и показатели
            </p>
          </CardContent>
        </Card>
      </div>
    )
  }

  const { plan, phases, tasks_summary: ts, kpis_summary: ks } = data
  const progress = ts.total > 0 ? Math.round((ts.completed / ts.total) * 100) : 0

  return (
    <div className="page space-y-6">
      {/* Plan card */}
      <Card>
        <CardContent className="p-5">
          <div className="flex items-start justify-between">
            <div>
              <h2 className="font-semibold text-lg">{plan.name}</h2>
              {plan.template_name && (
                <p className="text-sm text-muted-foreground">{plan.template_name}</p>
              )}
            </div>
            <Badge variant={STATUS_COLORS[plan.status] as any || 'secondary'}>
              {plan.status}
            </Badge>
          </div>
          <div className="mt-3 flex items-center gap-4 text-sm text-muted-foreground">
            <span>{new Date(plan.cycle_start_date).toLocaleDateString('ru-RU')} — {plan.cycle_end_date ? new Date(plan.cycle_end_date).toLocaleDateString('ru-RU') : '...'}</span>
            {plan.expert_name && <span>Зоотехник: {plan.expert_name}</span>}
          </div>
          <div className="mt-4">
            <div className="flex justify-between text-sm mb-1">
              <span>Прогресс</span>
              <span>{ts.completed}/{ts.total} задач</span>
            </div>
            <Progress value={progress} />
          </div>
        </CardContent>
      </Card>

      {/* Quick links */}
      <div className="grid grid-cols-3 gap-3">
        <Button variant="outline" className="h-auto py-3 flex-col" onClick={() => navigate('/cabinet-legacy/plan/tasks')}>
          <ListChecks className="h-5 w-5 mb-1" />
          <span className="text-xs">Задачи</span>
          {ts.overdue > 0 && <Badge variant="destructive" className="text-xs mt-1">{ts.overdue}</Badge>}
        </Button>
        <Button variant="outline" className="h-auto py-3 flex-col" onClick={() => navigate('/cabinet-legacy/plan/timeline')}>
          <Clock className="h-5 w-5 mb-1" />
          <span className="text-xs">Таймлайн</span>
        </Button>
        <Button variant="outline" className="h-auto py-3 flex-col" onClick={() => navigate('/cabinet-legacy/plan/kpi')}>
          <BarChart3 className="h-5 w-5 mb-1" />
          <span className="text-xs">KPI</span>
          {ks.missed > 0 && <Badge variant="destructive" className="text-xs mt-1">{ks.missed}</Badge>}
        </Button>
      </div>

      {/* Phases */}
      <div className="space-y-3">
        <h3 className="font-medium">Фазы ({phases.length})</h3>
        {phases.map((phase) => {
          const phaseProgress = phase.tasks_total > 0 ? Math.round((phase.tasks_completed / phase.tasks_total) * 100) : 0
          return (
            <Card key={phase.id} className="cursor-pointer hover:border-primary/50 transition-colors"
              onClick={() => navigate(`/cabinet-legacy/plan/cascade/${phase.id}`)}>
              <CardContent className="p-4">
                <div className="flex items-start justify-between">
                  <div>
                    <div className="font-medium">{phase.name_ru}</div>
                    {phase.herd_group_name && (
                      <p className="text-sm text-muted-foreground">{phase.herd_group_name}</p>
                    )}
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant={STATUS_COLORS[phase.status] as any || 'secondary'} className="text-xs">
                      {phase.status}
                    </Badge>
                    <ChevronRight className="h-4 w-4 text-muted-foreground" />
                  </div>
                </div>
                <div className="mt-2 flex items-center gap-4 text-xs text-muted-foreground">
                  <span>{new Date(phase.start_date).toLocaleDateString('ru-RU')} — {new Date(phase.end_date).toLocaleDateString('ru-RU')}</span>
                  <span>{phase.tasks_completed}/{phase.tasks_total} задач</span>
                  {phase.tasks_overdue > 0 && (
                    <span className="text-destructive">{phase.tasks_overdue} просроч.</span>
                  )}
                </div>
                {phase.tasks_total > 0 && (
                  <Progress value={phaseProgress} className="mt-2 h-1.5" />
                )}
              </CardContent>
            </Card>
          )
        })}
      </div>
    </div>
  )
}
