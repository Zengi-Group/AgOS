/**
 * F05 — Создать батч
 * Dok 6 Slice 5a: /cabinet-legacy/market/new
 * RPC: rpc_create_batch (RPC-09, d07, deployed)
 */
import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Loader2, ShoppingCart } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useAuth } from '@/hooks/useAuth'
import { useRpcMutation } from '@/hooks/useRpc'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

interface SkuOption { id: string; code: string; name_ru: string }

export function CreateBatch() {
  useSetTopbar({ title: 'Новая партия', titleIcon: <ShoppingCart size={15} /> })
  const navigate = useNavigate()
  const { organization, farm, userContext } = useAuth()
  const [skus, setSkus] = useState<SkuOption[]>([])
  const [skuId, setSkuId] = useState('')
  const [heads, setHeads] = useState('')
  const [avgWeight, setAvgWeight] = useState('')
  const [targetMonth, setTargetMonth] = useState('')
  const [notes, setNotes] = useState('')
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    supabase.from('tsp_skus').select('id, code, name_ru').eq('available', true).order('sort_order')
      .then(({ data }) => { if (data) setSkus(data) })
  }, [])

  // Check health restrictions
  const hasRestrictions = (userContext?.health_restrictions?.length ?? 0) > 0

  const createMutation = useRpcMutation('rpc_create_batch', {
    successMessage: 'Батч создан',
    invalidateKeys: [['rpc_get_org_batches']],
    onSuccess: (data: any) => {
      const id = data?.batch_id || data?.id
      if (id) navigate(`/cabinet-legacy/market/batch/${id}`)
      else navigate('/cabinet-legacy/market')
    },
  })

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!organization?.id || !farm?.id) { toast.error('Сначала создайте ферму'); return }
    if (!skuId || !heads || !targetMonth) { toast.error('Заполните обязательные поля'); return }
    if (hasRestrictions) { toast.error('Есть активное ограничение на продажу'); return }

    setLoading(true)
    try {
      await createMutation.mutateAsync({
        p_organization_id: organization.id,
        p_farm_id: farm.id,
        p_sku_id: skuId,
        p_heads: parseInt(heads),
        p_avg_weight_kg: avgWeight ? parseFloat(avgWeight) : null,
        p_target_month: targetMonth + '-01',
        p_notes: notes || null,
      } as any)
    } finally { setLoading(false) }
  }

  return (
    <div className="page">
      {hasRestrictions && (
        <Card className="mb-4 border-destructive">
          <CardContent className="p-4 text-sm text-destructive">
            У вас есть активное ограничение на продажу. Создание батча заблокировано.
          </CardContent>
        </Card>
      )}
      <Card>
        <CardHeader><CardTitle>Создать батч на продажу</CardTitle></CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div><Label>Категория ТСП *</Label>
              <select className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                value={skuId} onChange={e => setSkuId(e.target.value)} required>
                <option value="">Выберите категорию</option>
                {skus.map(s => <option key={s.id} value={s.id}>{s.name_ru}</option>)}
              </select>
            </div>
            <div><Label>Количество голов *</Label>
              <Input type="number" min={1} max={5000} value={heads} onChange={e => setHeads(e.target.value)} required />
            </div>
            <div><Label>Средний вес (кг)</Label>
              <Input type="number" min={1} step={0.1} value={avgWeight} onChange={e => setAvgWeight(e.target.value)} />
            </div>
            <div><Label>Месяц поставки *</Label>
              <Input type="month" value={targetMonth} onChange={e => setTargetMonth(e.target.value)} required />
            </div>
            <div><Label>Примечания</Label>
              <textarea className="flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm min-h-[60px]"
                value={notes} onChange={e => setNotes(e.target.value)} />
            </div>
            <div className="flex gap-3">
              <Button type="submit" disabled={loading || hasRestrictions} className="flex-1">
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Создать батч
              </Button>
              <Button type="button" variant="outline" onClick={() => navigate('/cabinet-legacy/market')}>Отмена</Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
