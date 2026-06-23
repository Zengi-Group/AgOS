/**
 * F06 — Детали батча (publish/cancel + price preview)
 * Dok 6 Slice 5a: /cabinet-legacy/market/batch/:batchId
 * RPCs: rpc_publish_batch (RPC-10), rpc_cancel_batch (RPC-11), rpc_get_price_for_sku (RPC-17)
 */
import { useNavigate, useParams } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { ArrowLeft, ShoppingCart } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'

const STATUS_LABELS: Record<string, string> = {
  draft: 'Черновик', published: 'Опубликован', matched: 'Покупатель подобран',
  cancelled: 'Отменён', expired: 'Истёк',
}

export function BatchDetail() {
  useSetTopbar({ title: 'Детали партии', titleIcon: <ShoppingCart size={15} /> })
  const navigate = useNavigate()
  const { batchId } = useParams()
  const { organization } = useAuth()

  const { data: batchesData, isLoading, refetch } = useRpc<any>('rpc_get_org_batches', {
    p_organization_id: organization?.id,
  }, { enabled: !!organization?.id })

  const batchList = batchesData?.batches ?? batchesData ?? []
  const batch = batchList.find((b: any) => (b.batch_id || b.id) === batchId)

  const { data: priceData } = useRpc<any>('rpc_get_price_for_sku', {
    p_organization_id: organization?.id,
    p_sku_id: batch?.tsp_sku_id || batch?.sku_id,
  }, { enabled: !!organization?.id && !!(batch?.tsp_sku_id || batch?.sku_id) })

  const publishMutation = useRpcMutation('rpc_publish_batch', {
    successMessage: 'Батч опубликован', invalidateKeys: [['rpc_get_org_batches']],
    onSuccess: () => refetch(),
  })
  const cancelMutation = useRpcMutation('rpc_cancel_batch', {
    successMessage: 'Батч отменён', invalidateKeys: [['rpc_get_org_batches']],
    onSuccess: () => refetch(),
  })

  if (isLoading) return <div className="page"><Skeleton className="h-8 w-48 mb-4" /><Skeleton className="h-48 w-full" /></div>
  if (!batch) return <div className="page"><Button variant="ghost" onClick={() => navigate('/cabinet-legacy/market')}><ArrowLeft className="mr-2 h-4 w-4" />Назад</Button><p className="mt-4 text-muted-foreground">Батч не найден</p></div>

  const status = batch.status
  const isDraft = status === 'draft'
  const isPublished = status === 'published'

  return (
    <div className="page space-y-6">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/market')}><ArrowLeft className="h-5 w-5" /></Button>
        <Badge variant={status === 'matched' ? 'default' : status === 'cancelled' ? 'outline' : 'secondary'}>
          {STATUS_LABELS[status] || status}
        </Badge>
      </div>

      <Card>
        <CardContent className="p-5 space-y-3">
          <div className="flex justify-between"><span className="text-muted-foreground">Категория</span><span className="font-medium">{batch.sku_name || '—'}</span></div>
          <div className="flex justify-between"><span className="text-muted-foreground">Голов</span><span className="font-medium">{batch.heads}</span></div>
          {batch.avg_weight_kg && <div className="flex justify-between"><span className="text-muted-foreground">Ср. вес</span><span>{batch.avg_weight_kg} кг</span></div>}
          <div className="flex justify-between"><span className="text-muted-foreground">Месяц поставки</span><span>{batch.target_month ? new Date(batch.target_month).toLocaleDateString('ru-RU', { month: 'long', year: 'numeric' }) : '—'}</span></div>
          {batch.expires_at && <div className="flex justify-between"><span className="text-muted-foreground">Истекает</span><span>{new Date(batch.expires_at).toLocaleDateString('ru-RU')}</span></div>}
        </CardContent>
      </Card>

      {/* Price preview */}
      {priceData && (
        <Card>
          <CardHeader><CardTitle className="text-lg">Справочная цена</CardTitle></CardHeader>
          <CardContent>
            {priceData.base_price_per_kg ? (
              <div className="text-2xl font-bold">{priceData.total_price_per_kg || priceData.base_price_per_kg} ₸/кг</div>
            ) : (
              <p className="text-muted-foreground">Цена не установлена</p>
            )}
            {priceData.disclaimer_text && (
              <p className="text-xs text-muted-foreground italic mt-2">{priceData.disclaimer_text}</p>
            )}
          </CardContent>
        </Card>
      )}

      {/* Matched banner */}
      {status === 'matched' && (
        <Card className="border-green-500"><CardContent className="p-4 text-center">
          <p className="font-medium text-green-700">Покупатель подобран</p>
          <p className="text-sm text-muted-foreground">Ожидайте информацию о доставке</p>
        </CardContent></Card>
      )}

      {/* Actions */}
      {(isDraft || isPublished) && (
        <div className="flex gap-3">
          {isDraft && (
            <Button className="flex-1" onClick={() => publishMutation.mutate({
              p_organization_id: organization?.id, p_batch_id: batchId,
            } as any)}>Опубликовать</Button>
          )}
          <Button variant="outline" className={isDraft ? '' : 'flex-1'} onClick={() => cancelMutation.mutate({
            p_organization_id: organization?.id, p_batch_id: batchId,
          } as any)}>Отменить</Button>
        </div>
      )}
    </div>
  )
}
