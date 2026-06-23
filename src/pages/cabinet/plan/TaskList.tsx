/**
 * F20 — Задачи (Task List)
 * Dok 6 Slice 4: /cabinet-legacy/plan/tasks
 * RPCs: rpc_get_farm_tasks (d07), rpc_complete_farm_task (d07, RPC-34)
 */
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { ArrowLeft, Check, ClipboardList } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'

interface Task {
  task_id: string
  name: string
  category: string
  due_date: string
  status: string
  phase_name: string
  herd_group_id: string | null
}

interface TasksResponse {
  tasks: Task[]
}

const CATEGORY_LABELS: Record<string, string> = {
  zootechnical: 'Зоотехния',
  veterinary: 'Ветеринария',
  management: 'Управление',
}

const TABS = [
  { key: 'upcoming', label: 'Предстоящие', filter: (t: Task) => ['scheduled', 'reminded', 'in_progress'].includes(t.status) },
  { key: 'overdue', label: 'Просроченные', filter: (t: Task) => t.status === 'overdue' },
]

function relativeDays(dateStr: string): string {
  const diff = Math.ceil((new Date(dateStr).getTime() - Date.now()) / 86400000)
  if (diff < -1) return `просрочено ${Math.abs(diff)} дн.`
  if (diff === -1) return 'вчера'
  if (diff === 0) return 'сегодня'
  if (diff === 1) return 'завтра'
  return `через ${diff} дн.`
}

export function TaskList() {
  useSetTopbar({ title: 'Задачи', titleIcon: <ClipboardList size={15} /> })
  const navigate = useNavigate()
  const { organization, farm, userContext } = useAuth()
  const [activeTab, setActiveTab] = useState('upcoming')

  const { data, isLoading, refetch } = useRpc<TasksResponse>('rpc_get_farm_tasks', {
    p_organization_id: organization?.id,
    p_farm_id: farm?.id,
    p_days_ahead: 90,
  }, { enabled: !!organization?.id && !!farm?.id })

  const completeMutation = useRpcMutation('rpc_complete_farm_task', {
    successMessage: 'Задача выполнена',
    invalidateKeys: [['rpc_get_farm_tasks'], ['rpc_get_active_plan']],
    onSuccess: () => refetch(),
  })

  const tasks = data?.tasks ?? []
  const currentFilter = TABS.find(t => t.key === activeTab)?.filter ?? (() => true)
  const filtered = tasks.filter(currentFilter)

  if (isLoading) {
    return (
      <div className="page space-y-4">
        <Skeleton className="h-8 w-32" />
        <Skeleton className="h-20 w-full" />
        <Skeleton className="h-20 w-full" />
      </div>
    )
  }

  return (
    <div className="page space-y-6">
      <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/plan')}>
        <ArrowLeft className="h-5 w-5" />
      </Button>

      {/* Tabs */}
      <div className="flex gap-2">
        {TABS.map(tab => {
          const count = tasks.filter(tab.filter).length
          return (
            <Button
              key={tab.key}
              variant={activeTab === tab.key ? 'default' : 'outline'}
              size="sm"
              onClick={() => setActiveTab(tab.key)}
            >
              {tab.label} {count > 0 && `(${count})`}
            </Button>
          )
        })}
      </div>

      {filtered.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            {activeTab === 'upcoming' ? 'Нет предстоящих задач' :
             activeTab === 'overdue' ? 'Нет просроченных задач' : 'Нет выполненных задач'}
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {filtered.map(task => (
            <Card key={task.task_id}>
              <CardContent className="p-4">
                <div className="flex items-start justify-between">
                  <div className="flex-1">
                    <div className="font-medium">{task.name}</div>
                    <div className="flex items-center gap-2 mt-1 text-xs text-muted-foreground">
                      <span>{task.phase_name}</span>
                      <Badge variant="secondary" className="text-xs">
                        {CATEGORY_LABELS[task.category] || task.category}
                      </Badge>
                    </div>
                    <div className={`text-sm mt-2 ${task.status === 'overdue' ? 'text-destructive font-medium' : 'text-muted-foreground'}`}>
                      {new Date(task.due_date).toLocaleDateString('ru-RU')} · {relativeDays(task.due_date)}
                    </div>
                  </div>
                  {!['completed', 'skipped'].includes(task.status) && (
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => completeMutation.mutate({
                        p_organization_id: organization?.id || '',
                        p_task_id: task.task_id,
                        p_actor_id: userContext?.user_id || '',
                      } as any)}
                      disabled={completeMutation.isPending}
                    >
                      <Check className="h-4 w-4 mr-1" />
                      Готово
                    </Button>
                  )}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
