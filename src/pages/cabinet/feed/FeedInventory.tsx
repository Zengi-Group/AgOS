/**
 * F15 — Складские запасы кормов (Feed Inventory)
 * Dok 6 Slice 3: /cabinet-legacy/feed
 * RPC: rpc_get_farm_summary (RPC-08) → feed_inventory[]
 */
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Plus, ChevronRight, Wheat } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'

interface FeedInventoryItem {
  id: string
  feed_item_id: string
  feed_item_code: string
  feed_item_name_ru: string
  feed_category_code: string
  feed_category_name_ru: string
  quantity_kg: number
  data_source: string
  confidence: number
  last_updated_date: string | null
  updated_at: string
}

interface FarmSummary {
  farm: { id: string; name: string }
  herd_groups: unknown[]
  feed_inventory: FeedInventoryItem[]
}

const CONFIDENCE_LABELS: Record<number, { label: string; variant: 'default' | 'secondary' | 'outline' }> = {
  25: { label: 'Низкая', variant: 'outline' },
  50: { label: 'AI', variant: 'secondary' },
  75: { label: 'Подтв.', variant: 'default' },
  95: { label: 'ERP', variant: 'default' },
}

function formatKg(kg: number): string {
  if (kg >= 1000) return `${(kg / 1000).toFixed(1)} т`
  return `${kg.toLocaleString('ru-RU')} кг`
}

export function FeedInventory() {
  useSetTopbar({ title: 'Склад кормов', titleIcon: <Wheat size={15} /> })
  const navigate = useNavigate()
  const { organization, farm } = useAuth()

  const { data, isLoading } = useRpc<FarmSummary>('rpc_get_farm_summary', {
    p_organization_id: organization?.id,
    p_farm_id: farm?.id,
  }, { enabled: !!organization?.id && !!farm?.id })

  const items = data?.feed_inventory ?? []
  const totalKg = items.reduce((sum, i) => sum + (i.quantity_kg || 0), 0)

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
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-24 w-full" />
      </div>
    )
  }

  return (
    <div className="page space-y-6">
      <div className="flex items-center justify-between">
        {items.length > 0 && (
          <p className="text-sm text-muted-foreground">
            {items.length} видов · {formatKg(totalKg)}
          </p>
        )}
        <Button onClick={() => navigate('/cabinet-legacy/feed/add')}>
          <Plus className="mr-2 h-4 w-4" />
          Добавить корм
        </Button>
      </div>

      {items.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center">
            <p className="text-muted-foreground mb-4">
              Добавьте корма для расчёта рациона
            </p>
            <Button variant="outline" onClick={() => navigate('/cabinet-legacy/feed/add')}>
              <Plus className="mr-2 h-4 w-4" />
              Добавить первый корм
            </Button>
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-3">
          {items.map((item) => {
            const conf = CONFIDENCE_LABELS[item.confidence] ?? { label: "—", variant: "secondary" as const }
            return (
              <Card
                key={item.id}
                className="cursor-pointer hover:border-primary/50 transition-colors"
                onClick={() => navigate(`/cabinet-legacy/feed/${item.id}`)}
              >
                <CardContent className="p-4 flex items-center justify-between">
                  <div className="space-y-1">
                    <div className="font-medium">{item.feed_item_name_ru}</div>
                    <div className="text-sm text-muted-foreground">
                      {item.feed_category_name_ru}
                    </div>
                  </div>
                  <div className="flex items-center gap-3">
                    <div className="text-right">
                      <div className="font-semibold">{formatKg(item.quantity_kg)}</div>
                      <Badge variant={conf.variant} className="text-xs mt-1">
                        {conf.label}
                      </Badge>
                    </div>
                    <ChevronRight className="h-5 w-5 text-muted-foreground" />
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
