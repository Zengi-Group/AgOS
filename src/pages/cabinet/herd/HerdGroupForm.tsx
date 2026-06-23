/**
 * F04 — Добавить / редактировать группу скота
 * Dok 6 Slice 3: /cabinet-legacy/herd/add or /cabinet-legacy/herd/:groupId
 * RPCs: rpc_upsert_herd_group (RPC-06), rpc_log_herd_event (RPC-07)
 * NOTE: SQL uses p_animal_category_code (text), NOT _id (uuid) — F-1 fix
 */
import { useState, useEffect } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Loader2, Fence } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useAuth } from '@/hooks/useAuth'
import { useRpcMutation } from '@/hooks/useRpc'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

interface AnimalCategory {
  id: string
  code: string
  name_ru: string
}

export function HerdGroupForm() {
  useSetTopbar({ title: 'Группа стада', titleIcon: <Fence size={15} /> })
  const navigate = useNavigate()
  const { groupId } = useParams()
  const isEdit = !!groupId
  const { organization, farm, userContext } = useAuth()

  const [categoryCode, setCategoryCode] = useState('')
  const [headCount, setHeadCount] = useState('')
  const [avgWeight, setAvgWeight] = useState('')
  const [categories, setCategories] = useState<AnimalCategory[]>([])
  const [loading, setLoading] = useState(false)

  // Load animal categories from DB (P8: Standards as Data)
  useEffect(() => {
    supabase
      .from('animal_categories')
      .select('id, code, name_ru')
      .eq('is_active', true)
      .order('name_ru')
      .then(({ data }) => {
        if (data) setCategories(data)
      })
  }, [])

  // Pre-fill in edit mode
  useEffect(() => {
    if (isEdit && userContext?.farms) {
      for (const f of userContext.farms) {
        const group = f.herd_groups?.find((g) => g.id === groupId)
        if (group) {
          setCategoryCode(group.animal_category_code || '')
          setHeadCount(String(group.head_count || ''))
          setAvgWeight(group.avg_weight_kg ? String(group.avg_weight_kg) : '')
          break
        }
      }
    }
  }, [isEdit, groupId, userContext])

  const upsertMutation = useRpcMutation('rpc_upsert_herd_group', {
    successMessage: isEdit ? 'Группа обновлена' : 'Группа создана',
    invalidateKeys: [['rpc_get_farm_summary'], ['rpc_get_my_context']],
    onSuccess: () => navigate('/cabinet-legacy/herd'),
  })

  const logEventMutation = useRpcMutation('rpc_log_herd_event')

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!organization?.id || !farm?.id) {
      toast.error('Сначала создайте ферму')
      navigate('/cabinet-legacy/farm')
      return
    }
    if (!categoryCode || !headCount) {
      toast.error('Заполните обязательные поля')
      return
    }

    const count = parseInt(headCount, 10)
    if (isNaN(count) || count <= 0 || count > 50000) {
      toast.error('Количество голов: от 1 до 50 000')
      return
    }

    const weight = avgWeight ? parseFloat(avgWeight) : null
    if (weight !== null && (weight < 1 || weight > 2000)) {
      toast.error('Вес от 1 до 2000 кг')
      return
    }

    setLoading(true)
    try {
      // F-1 fix: use p_animal_category_code (text), not _id
      // F-2 fix: include p_actor_id
      const result = await upsertMutation.mutateAsync({
        p_organization_id: organization!.id,
        p_farm_id: farm!.id,
        p_animal_category_code: categoryCode,
        p_head_count: count,
        p_avg_weight_kg: weight,
        p_herd_group_id: isEdit ? groupId : null,
        p_actor_id: userContext!.user_id,
      } as any)

      // Log herd event (RPC-07)
      if (result) {
        const groupResult = result as { herd_group_id?: string }
        logEventMutation.mutate({
          p_organization_id: organization!.id,
          p_farm_id: farm!.id,
          p_herd_group_id: groupResult.herd_group_id || groupId,
          p_event_type: isEdit ? 'head_count_change' : 'group_created',
          p_value_after: count,
          p_data_source: 'platform',
        } as any)
      }
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="page">
      <Card>
        <CardHeader>
          <CardTitle>{isEdit ? 'Редактировать группу' : 'Новая группа'}</CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="space-y-2">
              <Label>Категория животных *</Label>
              <select
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                value={categoryCode}
                onChange={(e) => setCategoryCode(e.target.value)}
                required
              >
                <option value="">Выберите категорию</option>
                {categories.map((c) => (
                  <option key={c.code} value={c.code}>
                    {c.name_ru}
                  </option>
                ))}
              </select>
            </div>

            <div className="space-y-2">
              <Label>Количество голов *</Label>
              <Input
                type="number"
                min={1}
                max={50000}
                value={headCount}
                onChange={(e) => setHeadCount(e.target.value)}
                placeholder="Например: 80"
                required
              />
            </div>

            <div className="space-y-2">
              <Label>Средний вес (кг)</Label>
              <Input
                type="number"
                min={1}
                max={2000}
                step={0.1}
                value={avgWeight}
                onChange={(e) => setAvgWeight(e.target.value)}
                placeholder="Необязательно"
              />
            </div>

            <div className="flex gap-3 pt-2">
              <Button type="submit" disabled={loading} className="flex-1">
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                {isEdit ? 'Сохранить' : 'Создать группу'}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => navigate('/cabinet-legacy/herd')}
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
