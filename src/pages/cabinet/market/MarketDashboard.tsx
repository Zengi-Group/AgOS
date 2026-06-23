/**
 * F08 — Мои батчи и рынок (Market Dashboard)
 * Dok 6 Slice 5a: /cabinet-legacy/market
 * RPCs: rpc_get_org_batches (AI-19, d07), rpc_get_market_summary (RPC-18, d02)
 */
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Plus, ChevronRight, TrendingUp, ShoppingCart } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'

const STATUS_LABELS: Record<string, { label: string; variant: 'default' | 'secondary' | 'outline' | 'destructive' }> = {
  draft: { label: 'Черновик', variant: 'secondary' },
  published: { label: 'Опубликован', variant: 'default' },
  matched: { label: 'Подобран', variant: 'default' },
  cancelled: { label: 'Отменён', variant: 'outline' },
  expired: { label: 'Истёк', variant: 'destructive' },
}

export function MarketDashboard() {
  useSetTopbar({ title: 'Рынок', titleIcon: <ShoppingCart size={15} /> })
  const navigate = useNavigate()
  const { organization } = useAuth()

  const { data: batches, isLoading: batchesLoading } = useRpc<any>('rpc_get_org_batches', {
    p_organization_id: organization?.id,
  }, { enabled: !!organization?.id })

  const { data: summary } = useRpc<any>('rpc_get_market_summary', {
    p_organization_id: organization?.id,
  }, { enabled: !!organization?.id })

  const batchList = batches?.batches ?? batches ?? []

  if (batchesLoading) {
    return <div className="page space-y-4"><Skeleton className="h-8 w-48" /><Skeleton className="h-32 w-full" /></div>
  }

  return (
    <div className="page space-y-6">
      <div className="flex items-center justify-end gap-2">
        <div className="flex gap-2">
          <Button variant="outline" onClick={() => navigate('/cabinet-legacy/market/prices')}>
            <TrendingUp className="mr-2 h-4 w-4" />Цены
          </Button>
          <Button onClick={() => navigate('/cabinet-legacy/market/new')}>
            <Plus className="mr-2 h-4 w-4" />Создать батч
          </Button>
        </div>
      </div>

      {/* My Batches */}
      <div className="space-y-3">
        <h3 className="font-medium">Мои батчи</h3>
        {batchList.length === 0 ? (
          <Card><CardContent className="p-8 text-center">
            <p className="text-muted-foreground mb-4">Нет батчей — создайте первый</p>
            <Button variant="outline" onClick={() => navigate('/cabinet-legacy/market/new')}>
              <Plus className="mr-2 h-4 w-4" />Создать батч
            </Button>
          </CardContent></Card>
        ) : (
          batchList.map((b: any) => {
            const st = STATUS_LABELS[b.status] ?? { label: b.status, variant: 'secondary' as const }
            return (
              <Card key={b.batch_id || b.id} className="cursor-pointer hover:border-primary/50 transition-colors"
                onClick={() => navigate(`/cabinet-legacy/market/batch/${b.batch_id || b.id}`)}>
                <CardContent className="p-4 flex items-center justify-between">
                  <div>
                    <div className="font-medium">{b.sku_name || b.tsp_sku_id}</div>
                    <div className="text-sm text-muted-foreground">
                      {b.heads} гол. {b.avg_weight_kg ? `· ~${b.avg_weight_kg} кг` : ''}
                      {b.target_month ? ` · ${new Date(b.target_month).toLocaleDateString('ru-RU', { month: 'long', year: 'numeric' })}` : ''}
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant={st.variant}>{st.label}</Badge>
                    <ChevronRight className="h-4 w-4 text-muted-foreground" />
                  </div>
                </CardContent>
              </Card>
            )
          })
        )}
      </div>

      {/* Market Summary */}
      {summary && (
        <div className="space-y-3">
          <h3 className="font-medium">Обзор рынка</h3>
          {summary.supply?.length > 0 && (
            <Card><CardContent className="p-4">
              <div className="text-sm font-medium mb-2">Предложение</div>
              {summary.supply.map((s: any, i: number) => (
                <div key={i} className="flex justify-between text-sm py-1">
                  <span className="text-muted-foreground">{s.sku_name}</span>
                  <span>{s.total_heads} гол.</span>
                </div>
              ))}
            </CardContent></Card>
          )}
          {summary.disclaimer_text && (
            <p className="text-xs text-muted-foreground italic">{summary.disclaimer_text}</p>
          )}
        </div>
      )}
    </div>
  )
}
