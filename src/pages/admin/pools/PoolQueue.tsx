/**
 * A11 — Очередь пул-запросов
 * Dok 6 Slice 5b: /admin/pools
 * Flows: list pool_requests → create (RPC-12) → activate draft (RPC-13) → navigate to pool detail
 */
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Package, Plus } from 'lucide-react'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { useAuth } from '@/hooks/useAuth'
import { useRpcMutation } from '@/hooks/useRpc'
import { supabase } from '@/lib/supabase'

interface PoolRequest {
  id: string
  status: string
  total_heads: number
  target_month: string
  created_at: string
  pools: Array<{ id: string; status: string; matched_heads: number; target_heads: number }>
}

const ST: Record<string, string> = {
  draft: 'Черновик',
  active: 'Активен',
  closed: 'Закрыт',
  expired: 'Истёк',
}

export function PoolQueue() {
  useSetTopbar({ title: 'Торговые пулы', titleIcon: <Package size={15} /> })
  const { isAdmin, checking: adminChecking } = useAdminGuard()
  const navigate = useNavigate()
  const { organization } = useAuth()
  const [requests, setRequests] = useState<PoolRequest[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [totalHeads, setTotalHeads] = useState('')
  const [targetMonth, setTargetMonth] = useState('')

  const load = () => {
    supabase
      .from('pool_requests')
      .select('*, pools(id, status, matched_heads, target_heads)')
      .order('created_at', { ascending: false })
      .limit(50)
      .then(({ data }) => {
        setRequests((data as any) || [])
        setLoading(false)
      })
  }

  useEffect(load, [])

  // RPC-12: create pool_request
  const createMutation = useRpcMutation('rpc_create_pool_request', {
    successMessage: 'Пул-запрос создан',
    onSuccess: () => {
      setShowCreate(false)
      setTotalHeads('')
      setTargetMonth('')
      load()
    },
  })

  // RPC-13: activate draft → creates Pool record
  const activateMutation = useRpcMutation('rpc_activate_pool_request', {
    successMessage: 'Пул активирован',
    onSuccess: (result: any) => {
      load()
      if (result?.pool_id) navigate(`/admin/pools/${result.pool_id}`)
    },
  })

  const handleCreate = () => {
    if (!totalHeads || !targetMonth || !organization?.id) return
    createMutation.mutate({
      p_organization_id: organization.id,
      p_total_heads: parseInt(totalHeads),
      p_target_month: targetMonth + '-01',
    } as any)
  }

  const handleActivate = (e: React.MouseEvent, requestId: string) => {
    e.stopPropagation()
    if (!organization?.id) return
    activateMutation.mutate({
      p_organization_id: organization.id,
      p_request_id: requestId,
    } as any)
  }

  if (adminChecking) return <div className="page">Проверка доступа...</div>
  if (!isAdmin) return null

  return (
    <div className="page space-y-6">
      {/* ARS-200: экран использует устаревшие pre-M6 RPC и старую D40-семантику раскрытия
          контактов (на executing вместо confirmed, D-M6-5/12). Управление ТСП перенесено
          в «Торговую площадку» (/admin/marketplace, M6-канон). Экран сохранён (HS-2). */}
      <div className="rounded-[10px] border border-[var(--amber)] bg-[var(--amber-bg,transparent)] p-4 text-sm">
        <div className="font-medium">Устаревший экран</div>
        <div className="mt-1 text-[var(--fg2)]">
          Управление торговыми пулами и батчами перенесено в «Торговую площадку» (канон M6).
          Этот экран работает на прежнем pre-M6 потоке и оставлен только для справки.
        </div>
        <Button variant="outline" size="sm" className="mt-3" onClick={() => navigate('/admin/marketplace')}>
          Перейти в «Торговую площадку»
        </Button>
      </div>

      <div className="flex items-center justify-between">
        <Button onClick={() => setShowCreate(true)}>
          <Plus className="mr-2 h-4 w-4" />
          Создать
        </Button>
      </div>

      {loading ? (
        <Skeleton className="h-32 w-full" />
      ) : requests.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">Нет запросов</CardContent>
        </Card>
      ) : (
        requests.map(r => {
          const pool = r.pools?.[0]
          return (
            <Card
              key={r.id}
              className={`${pool ? 'cursor-pointer hover:border-primary/50' : ''}`}
              onClick={() => pool ? navigate(`/admin/pools/${pool.id}`) : undefined}
            >
              <CardContent className="p-4 flex items-center justify-between gap-3">
                <div>
                  <div className="font-medium">
                    {r.total_heads} голов ·{' '}
                    {r.target_month
                      ? new Date(r.target_month).toLocaleDateString('ru-RU', { month: 'long', year: 'numeric' })
                      : ''}
                  </div>
                  {pool && (
                    <div className="text-sm text-muted-foreground">
                      Пул: {pool.matched_heads}/{pool.target_heads} подобрано · {pool.status}
                    </div>
                  )}
                  {!pool && r.status === 'draft' && (
                    <div className="text-sm text-muted-foreground">Пул ещё не создан</div>
                  )}
                </div>
                <div className="flex items-center gap-2">
                  <Badge variant={r.status === 'active' ? 'default' : 'secondary'}>
                    {ST[r.status] || r.status}
                  </Badge>
                  {/* DEF-022 fix: activate draft requests → creates Pool via RPC-13 */}
                  {r.status === 'draft' && !pool && (
                    <Button
                      size="sm"
                      onClick={e => handleActivate(e, r.id)}
                      disabled={activateMutation.isPending}
                    >
                      Активировать
                    </Button>
                  )}
                </div>
              </CardContent>
            </Card>
          )
        })
      )}

      {/* DEF-021 fix: Create pool_request dialog → RPC-12 */}
      <Dialog open={showCreate} onOpenChange={setShowCreate}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Новый пул-запрос</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-2">
            <div>
              <Label>Количество голов</Label>
              <Input
                type="number"
                min={1}
                value={totalHeads}
                onChange={e => setTotalHeads(e.target.value)}
                placeholder="например 500"
              />
            </div>
            <div>
              <Label>Целевой месяц отгрузки</Label>
              <Input
                type="month"
                value={targetMonth}
                onChange={e => setTargetMonth(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowCreate(false)}>Отмена</Button>
            <Button
              onClick={handleCreate}
              disabled={!totalHeads || !targetMonth || createMutation.isPending}
            >
              Создать
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
