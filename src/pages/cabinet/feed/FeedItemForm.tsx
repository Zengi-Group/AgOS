/**
 * F16 — Добавить / обновить запас корма
 * Dok 6 Slice 3: /cabinet-legacy/feed/add or /cabinet-legacy/feed/:inventoryId
 * RPC: rpc_upsert_feed_inventory (RPC-21) — D-S3-1 individual fields
 */
import { useState, useEffect } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Loader2, Wheat } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useAuth } from '@/hooks/useAuth'
import { useRpcMutation } from '@/hooks/useRpc'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

interface FeedItemOption {
  id: string
  code: string
  name_ru: string
  category_name: string
  category_code: string
}

export function FeedItemForm() {
  useSetTopbar({ title: 'Запись корма', titleIcon: <Wheat size={15} /> })
  const navigate = useNavigate()
  const { inventoryId } = useParams()
  const isEdit = !!inventoryId
  const { organization, farm } = useAuth()

  const [feedItemId, setFeedItemId] = useState('')
  const [quantityKg, setQuantityKg] = useState('')
  const [pricePerKg, setPricePerKg] = useState('')
  const [feedItems, setFeedItems] = useState<FeedItemOption[]>([])
  const [loading, setLoading] = useState(false)

  // Load feed items grouped by category (P8)
  useEffect(() => {
    supabase
      .from('feed_items')
      .select('id, code, name_ru, feed_categories!inner(name_ru, code)')
      .eq('is_active', true)
      .order('name_ru')
      .then(({ data }) => {
        if (data) {
          setFeedItems(
            data.map((d: any) => ({
              id: d.id,
              code: d.code,
              name_ru: d.name_ru,
              category_name: d.feed_categories.name_ru,
              category_code: d.feed_categories.code,
            }))
          )
        }
      })
  }, [])

  // Pre-fill in edit mode
  useEffect(() => {
    if (isEdit && organization?.id) {
      supabase
        .from('farm_feed_inventory')
        .select('feed_item_id, quantity_kg')
        .eq('id', inventoryId)
        .eq('organization_id', organization.id)
        .single()
        .then(({ data }) => {
          if (data) {
            setFeedItemId(data.feed_item_id)
            setQuantityKg(String(data.quantity_kg))
          }
        })
    }
  }, [isEdit, inventoryId, organization?.id])

  const upsertMutation = useRpcMutation('rpc_upsert_feed_inventory', {
    successMessage: 'Запас обновлён',
    invalidateKeys: [['rpc_get_farm_summary']],
    onSuccess: () => navigate('/cabinet-legacy/feed'),
  })

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!organization?.id || !farm?.id) {
      toast.error('Сначала создайте ферму')
      navigate('/cabinet-legacy/farm')
      return
    }
    if (!feedItemId || !quantityKg) {
      toast.error('Заполните обязательные поля')
      return
    }

    const qty = parseFloat(quantityKg)
    if (isNaN(qty) || qty < 0) {
      toast.error('Количество должно быть >= 0')
      return
    }

    const price = pricePerKg ? parseFloat(pricePerKg) : null
    if (price !== null && price <= 0) {
      toast.error('Цена должна быть положительной')
      return
    }

    setLoading(true)
    try {
      await upsertMutation.mutateAsync({
        p_organization_id: organization!.id,
        p_farm_id: farm!.id,
        p_feed_item_id: feedItemId,
        p_quantity_kg: qty,
        p_price_per_kg: price,
        p_data_source: 'platform',
      } as any)
    } finally {
      setLoading(false)
    }
  }

  // Group feed items by category for select
  const grouped = feedItems.reduce<Record<string, FeedItemOption[]>>((acc, item) => {
    const key = item.category_name
    if (!acc[key]) acc[key] = []
    acc[key].push(item)
    return acc
  }, {})

  return (
    <div className="page">
      <Card>
        <CardHeader>
          <CardTitle>{isEdit ? 'Обновить запас' : 'Добавить корм'}</CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="space-y-2">
              <Label>Корм *</Label>
              <select
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                value={feedItemId}
                onChange={(e) => setFeedItemId(e.target.value)}
                required
              >
                <option value="">Выберите корм</option>
                {Object.entries(grouped).map(([cat, items]) => (
                  <optgroup key={cat} label={cat}>
                    {items.map((item) => (
                      <option key={item.id} value={item.id}>
                        {item.name_ru}
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
            </div>

            <div className="space-y-2">
              <Label>Количество (кг) *</Label>
              <Input
                type="number"
                min={0}
                step={0.01}
                value={quantityKg}
                onChange={(e) => setQuantityKg(e.target.value)}
                placeholder="Например: 5000"
                required
              />
            </div>

            <div className="space-y-2">
              <Label>Цена за кг (₸)</Label>
              <Input
                type="number"
                min={0}
                step={0.01}
                value={pricePerKg}
                onChange={(e) => setPricePerKg(e.target.value)}
                placeholder="Необязательно"
              />
            </div>

            <div className="flex gap-3 pt-2">
              <Button type="submit" disabled={loading} className="flex-1">
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                {isEdit ? 'Сохранить' : 'Добавить'}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => navigate('/cabinet-legacy/feed')}
              >
                Отмена
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
