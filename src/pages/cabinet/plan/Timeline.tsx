/**
 * F21 — Таймлайн (Timeline View)
 * Dok 6 Slice 4: /cabinet-legacy/plan/timeline
 * RPC: rpc_get_active_plan (RPC-37) → phases with dates
 * Read-only visualization — no writes.
 */
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { ArrowLeft, ClipboardList } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'

interface Phase {
  id: string; name_ru: string; start_date: string; end_date: string
  status: string; herd_group_name: string | null
  tasks_total: number; tasks_completed: number
}

interface PlanData {
  plan: { cycle_start_date: string; cycle_end_date: string; name: string }
  phases: Phase[]
}

const STATUS_COLORS: Record<string, string> = {
  upcoming: 'hsl(var(--muted))',
  active: 'hsl(var(--primary))',
  completed: 'hsl(142, 71%, 45%)',
  skipped: 'hsl(var(--muted))',
}

export function Timeline() {
  useSetTopbar({ title: 'Таймлайн', titleIcon: <ClipboardList size={15} /> })
  const navigate = useNavigate()
  const { organization, farm } = useAuth()

  const { data, isLoading } = useRpc<PlanData>('rpc_get_active_plan', {
    p_organization_id: organization?.id,
    p_farm_id: farm?.id,
  }, { enabled: !!organization?.id && !!farm?.id })

  if (isLoading) {
    return <div className="page"><Skeleton className="h-8 w-32 mb-4" /><Skeleton className="h-64 w-full" /></div>
  }

  if (!data) {
    return (
      <div className="page">
        <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/plan')}><ArrowLeft className="h-5 w-5" /></Button>
        <Card className="mt-4"><CardContent className="p-8 text-center text-muted-foreground">План не создан</CardContent></Card>
      </div>
    )
  }

  const { plan, phases } = data
  const planStart = new Date(plan.cycle_start_date).getTime()
  const planEnd = new Date(plan.cycle_end_date || plan.cycle_start_date).getTime()
  
  const today = Date.now()
  const todayPct = Math.min(100, Math.max(0, ((today - planStart) / (planEnd - planStart)) * 100))

  // Generate month labels
  const months: { label: string; pct: number }[] = []
  const startDate = new Date(plan.cycle_start_date)
  const endDate = new Date(plan.cycle_end_date || plan.cycle_start_date)
  const d = new Date(startDate.getFullYear(), startDate.getMonth(), 1)
  while (d <= endDate) {
    const pct = ((d.getTime() - planStart) / (planEnd - planStart)) * 100
    if (pct >= 0 && pct <= 100) {
      months.push({ label: d.toLocaleDateString('ru-RU', { month: 'short' }), pct })
    }
    d.setMonth(d.getMonth() + 1)
  }

  return (
    <div className="page space-y-6">
      <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/plan')}>
        <ArrowLeft className="h-5 w-5" />
      </Button>

      <Card>
        <CardContent className="p-5">
          {/* Month headers */}
          <div className="relative h-6 mb-2">
            {months.map((m, i) => (
              <span key={i} className="absolute text-xs text-muted-foreground" style={{ left: `${m.pct}%` }}>
                {m.label}
              </span>
            ))}
          </div>

          {/* Phase bars */}
          <div className="relative space-y-2">
            {/* Today marker */}
            <div className="absolute top-0 bottom-0 border-l-2 border-primary z-10"
              style={{ left: `${todayPct}%` }}>
              <span className="absolute -top-5 -left-4 text-[10px] font-medium text-primary">
                сегодня
              </span>
            </div>

            {phases.map(phase => {
              const phaseStart = new Date(phase.start_date).getTime()
              const phaseEnd = new Date(phase.end_date).getTime()
              const left = Math.max(0, ((phaseStart - planStart) / (planEnd - planStart)) * 100)
              const width = Math.max(2, ((phaseEnd - phaseStart) / (planEnd - planStart)) * 100)

              return (
                <div key={phase.id} className="relative h-10 cursor-pointer group"
                  onClick={() => navigate(`/cabinet-legacy/plan/cascade/${phase.id}`)}>
                  <div
                    className="absolute h-8 rounded-md flex items-center px-2 text-xs text-white font-medium overflow-hidden whitespace-nowrap transition-opacity group-hover:opacity-90"
                    style={{
                      left: `${left}%`,
                      width: `${width}%`,
                      backgroundColor: STATUS_COLORS[phase.status] || STATUS_COLORS.upcoming,
                      minWidth: '20px',
                    }}
                    title={`${phase.name_ru}: ${new Date(phase.start_date).toLocaleDateString('ru-RU')} — ${new Date(phase.end_date).toLocaleDateString('ru-RU')}`}
                  >
                    {width > 8 && phase.name_ru}
                  </div>
                </div>
              )
            })}
          </div>

          {/* Legend */}
          <div className="flex gap-4 mt-4 text-xs text-muted-foreground">
            {Object.entries({ upcoming: 'Предстоящая', active: 'Активная', completed: 'Завершена' }).map(([k, v]) => (
              <div key={k} className="flex items-center gap-1">
                <div className="w-3 h-3 rounded-sm" style={{ backgroundColor: STATUS_COLORS[k] }} />
                {v}
              </div>
            ))}
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
