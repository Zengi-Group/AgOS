/**
 * F03 — Обзор поголовья (Herd Overview)
 * Dok 6 Slice 3: /cabinet-legacy/herd
 * RPC: rpc_get_farm_summary (RPC-08)
 */
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Plus, ChevronRight, Fence } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'

interface HerdGroupData {
  id: string
  animal_category_id: string
  animal_category_code: string
  animal_category_name_ru: string
  breed_id: string | null
  breed_name_ru: string | null
  head_count: number
  avg_weight_kg: number | null
  data_source: string
  confidence: number
  updated_at: string
}

interface FarmSummary {
  farm: { id: string; name: string }
  herd_groups: HerdGroupData[]
  feed_inventory: unknown[]
  active_vet_cases: unknown[]
  upcoming_tasks: unknown[]
}

const SOURCE_LABELS: Record<string, string> = {
  registration: 'Регистрация',
  ai_extracted: 'AI',
  platform: 'Кабинет',
  erp: 'ERP',
}

export function HerdOverview() {
  useSetTopbar({ title: 'Стадо', titleIcon: <Fence size={15} /> })
  const navigate = useNavigate()
  const { organization, farm } = useAuth()

  const { data, isLoading } = useRpc<FarmSummary>('rpc_get_farm_summary', {
    p_organization_id: organization?.id,
    p_farm_id: farm?.id,
  }, { enabled: !!organization?.id && !!farm?.id })

  const groups = data?.herd_groups ?? []
  const totalHeads = groups.reduce((sum, g) => sum + (g.head_count || 0), 0)

  if (!farm) {
    return (
      <div className="page">
        <Card><CardContent className="p-8 text-center">
          <p className="text-muted-foreground mb-4">Сначала создайте ферму</p>
          <Button variant="outline" onClick={() => navigate('/cabinet-legacy/farm')}>Создать ферму</Button>
        </CardContent></Card>
      </div>
    )
  }

  if (isLoading) {
    return (
      <div className="page space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-32 w-full" />
        <Skeleton className="h-32 w-full" />
      </div>
    )
  }

  return (
    <div className="page space-y-6">
      <div className="flex items-center justify-between">
        {totalHeads > 0 && (
          <p className="text-sm text-muted-foreground">
            Всего: {totalHeads} голов в {groups.length} группах
          </p>
        )}
        <Button onClick={() => navigate('/cabinet-legacy/herd/add')}>
          <Plus className="mr-2 h-4 w-4" />
          Добавить группу
        </Button>
      </div>

      {groups.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center">
            <p className="text-muted-foreground mb-4">
              Добавьте группы животных для учёта
            </p>
            <Button variant="outline" onClick={() => navigate('/cabinet-legacy/herd/add')}>
              <Plus className="mr-2 h-4 w-4" />
              Добавить первую группу
            </Button>
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-4 md:grid-cols-2">
          {groups.map((group) => (
            <Card
              key={group.id}
              className="cursor-pointer hover:border-primary/50 transition-colors"
              onClick={() => navigate(`/cabinet-legacy/herd/${group.id}`)}
            >
              <CardContent className="p-5">
                <div className="flex items-start justify-between">
                  <div className="space-y-1">
                    <h3 className="font-medium">
                      {group.animal_category_name_ru}
                    </h3>
                    {group.breed_name_ru && (
                      <p className="text-sm text-muted-foreground">
                        {group.breed_name_ru}
                      </p>
                    )}
                  </div>
                  <ChevronRight className="h-5 w-5 text-muted-foreground" />
                </div>

                <div className="mt-4 flex items-center gap-4 text-sm">
                  <span className="font-semibold text-lg">{group.head_count} гол.</span>
                  {group.avg_weight_kg && (
                    <span className="text-muted-foreground">
                      ~{group.avg_weight_kg} кг
                    </span>
                  )}
                </div>

                <div className="mt-3 flex items-center gap-2">
                  <Badge variant="secondary" className="text-xs">
                    {SOURCE_LABELS[group.data_source] || group.data_source}
                  </Badge>
                  <span className="text-xs text-muted-foreground">
                    {new Date(group.updated_at).toLocaleDateString('ru-RU')}
                  </span>
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
