/**
 * Админ · Торговая площадка — единый read-only обзор ТСП.
 * Три вкладки: Батчи (партии ферм) · Пулы (заявки МПК) · Сделки (batch_allocations).
 * Данные: rpc_admin_tsp_batches / rpc_admin_tsp_pools / rpc_admin_tsp_deals
 * (security-definer, гейт fn_is_admin(), контакты сторон раскрыты — админ = оператор).
 * Read-only: никаких действий над чужими сделками. Ст. 171 ПК РК — дисклеймер (есть цены).
 */
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useState, useEffect, useCallback } from 'react'
import { Store } from 'lucide-react'
import { toast } from 'sonner'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import {
  Dialog, DialogTrigger, DialogContent, DialogHeader, DialogFooter, DialogTitle, DialogDescription,
} from '@/components/ui/dialog'
import {
  Select, SelectTrigger, SelectValue, SelectContent, SelectItem,
} from '@/components/ui/select'
import { supabase } from '@/lib/supabase'

const DISCLAIMER =
  'Цены являются индикативными рыночными ориентирами и не являются обязательными для применения. Участие добровольное. Ст. 171 ПК РК.'

// ── типы (форма JSON из RPC) ────────────────────────────────────────────────
interface AdminBatch {
  id: string
  farmName: string | null
  farmPhone: string | null
  cat: string | null
  grade: string | null
  breed: string
  heads: number
  matchedHeads: number
  remainingHeads: number
  avgWeight: number | null
  price: number | null
  dealPrice: number | null
  status: string
  region: string
  poolId: string | null
  createdAtIso: string | null
  publishedAtIso: string | null
  matchedAtIso: string | null
  deliveredAtIso: string | null
}
interface AdminPoolLine { id: string; code: string; price: number }
interface AdminPool {
  id: string
  mpkName: string | null
  mpkPhone: string | null
  status: string
  targetHeads: number
  matchedHeads: number
  region: string
  targetMonthIso: string | null
  createdAtIso: string | null
  contactRevealed: boolean
  lines: AdminPoolLine[]
}
interface AdminDeal {
  id: string
  batchId: string
  poolId: string
  farmName: string | null
  farmPhone: string | null
  mpkName: string | null
  mpkPhone: string | null
  cat: string | null
  grade: string | null
  breed: string
  heads: number
  avgWeight: number | null
  price: number | null
  sum: number | null
  status: string
  via: string | null
  region: string
  matchedAtIso: string | null
  confirmedAtIso: string | null
  dispatchedAtIso: string | null
  deliveredAtIso: string | null
}

// ── словари ─────────────────────────────────────────────────────────────────
const CAT_RU: Record<string, string> = { bychki: 'Бычки', telki: 'Тёлки', korovy: 'Коровы' }
const GRADE_RU: Record<string, string> = { VS: 'Высшая', S: 'Первая', NS: 'Вторая' }
const STATUS_RU: Record<string, string> = {
  // batch
  draft: 'Черновик', scheduled: 'Запланирована', published: 'На продаже', offering: 'Рассылка оффера',
  awaiting_price_decision: 'Решение по цене', matched: 'Подобран покупатель', partially_matched: 'Продана частично',
  confirmed: 'Подтверждена', dispatched: 'Отгружена', delivered: 'Доставлена',
  cancelled: 'Отменена', failed: 'Не состоялась', expired: 'Истекла',
  // pool
  filling: 'Набирается', filled: 'Набран', closed_filled: 'Закрыт (набран)', closed_partial: 'Закрыт (частично)',
  awaiting_mpk_decision: 'Решение МПК', executing: 'Приёмка', executed: 'Завершён', completed: 'Завершён',
  expired_empty: 'Истёк (пусто)', closed_unfilled: 'Закрыт (не набран)', closed: 'Закрыт',
}
const rus = (s: string): string => STATUS_RU[s] ?? s
const catLabel = (cat: string | null, grade: string | null): string => {
  const c = cat ? (CAT_RU[cat] ?? cat) : ''
  const g = grade ? (GRADE_RU[grade] ?? grade) : ''
  return [c, g].filter(Boolean).join(' · ') || '—'
}

// ── форматтеры ────────────────────────────────────────────────────────────────
const money = (n: number | null | undefined): string =>
  n == null ? '—' : Math.round(n).toLocaleString('ru-RU')
const day = (iso: string | null | undefined): string =>
  iso ? new Date(iso).toLocaleDateString('ru-RU', { day: 'numeric', month: 'short', year: 'numeric' }) : '—'
const month = (iso: string | null | undefined): string =>
  iso ? new Date(iso).toLocaleDateString('ru-RU', { month: 'long', year: 'numeric' }) : '—'

function KV({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-3 text-sm">
      <span className="text-[var(--fg2)]">{k}</span>
      <span className="font-medium text-right">{v}</span>
    </div>
  )
}

function Empty({ text }: { text: string }) {
  return (
    <Card>
      <CardContent className="p-8 text-center text-muted-foreground">{text}</CardContent>
    </Card>
  )
}

// ── управление (ARS-199) ──────────────────────────────────────────────────────
// Все действия идут ТОЛЬКО через admin-RPC (security definer, гейт fn_is_admin()).
// RPC бросают исключения (не {ok,error}); { error } supabase-клиента несёт message.
// Кнопки FSM-гейтятся, чтобы недопустимые переходы не отправлялись зря.

// M6 карта переходов пула (зеркало rpc_admin_advance_pool_status; cancel — отдельно).
const POOL_NEXT: Record<string, string[]> = {
  draft: ['filling'],
  filling: ['closed_filled', 'awaiting_mpk_decision', 'expired_empty'],
  awaiting_mpk_decision: ['closed_partial', 'closed_unfilled'],
  closed_filled: ['executing'],
  closed_partial: ['executing'],
  executing: ['completed'],
}

function useRpcAction(onDone: () => void) {
  const [busy, setBusy] = useState(false)
  const call = async (
    fn: string,
    args: Record<string, unknown>,
    okMsg: string,
  ): Promise<boolean> => {
    setBusy(true)
    const { error } = await supabase.rpc(fn, args)
    setBusy(false)
    if (error) {
      toast.error(error.message)
      return false
    }
    toast.success(okMsg)
    onDone()
    return true
  }
  return { busy, call }
}

// Отменить батч (draft|published → cancelled). rpc_admin_cancel_batch.
function CancelBatchBtn({ batch, onDone }: { batch: AdminBatch; onDone: () => void }) {
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')
  const { busy, call } = useRpcAction(onDone)
  const submit = async () => {
    if (await call('rpc_admin_cancel_batch', { p_batch_id: batch.id, p_reason: reason || null }, 'Батч отменён')) {
      setOpen(false)
    }
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="destructive" size="sm">Отменить</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Отменить батч</DialogTitle>
          <DialogDescription>Батч будет переведён в статус «Отменена». Действие необратимо.</DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          <Label htmlFor="cb-reason">Причина (необязательно)</Label>
          <Textarea id="cb-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>Закрыть</Button>
          <Button variant="destructive" onClick={submit} disabled={busy}>Отменить батч</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Изменить условия батча (draft|published): цена + окно готовности. rpc_admin_set_batch_terms.
function EditBatchBtn({ batch, onDone }: { batch: AdminBatch; onDone: () => void }) {
  const [open, setOpen] = useState(false)
  const [price, setPrice] = useState(batch.price != null ? String(batch.price) : '')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const { busy, call } = useRpcAction(onDone)
  const submit = async () => {
    const ok = await call('rpc_admin_set_batch_terms', {
      p_batch_id: batch.id,
      p_farmer_price_per_kg: price ? Number(price) : null,
      p_ready_from: from || null,
      p_ready_to: to || null,
    }, 'Условия батча обновлены')
    if (ok) setOpen(false)
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">Изменить условия</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Условия батча</DialogTitle>
          <DialogDescription>Пустые поля даты не меняют текущее значение. ready_to ≥ ready_from.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1">
            <Label htmlFor="eb-price">Цена фермы, ₸/кг</Label>
            <Input id="eb-price" type="number" min={1} value={price} onChange={(e) => setPrice(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <Label htmlFor="eb-from">Готов с</Label>
              <Input id="eb-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="eb-to">Готов до</Label>
              <Input id="eb-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
            </div>
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>Закрыть</Button>
          <Button onClick={submit} disabled={busy}>Сохранить</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Отменить пул (draft|filling → cancelled, разматчивает батчи). rpc_admin_cancel_pool.
function CancelPoolBtn({ pool, onDone }: { pool: AdminPool; onDone: () => void }) {
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')
  const { busy, call } = useRpcAction(onDone)
  const submit = async () => {
    if (await call('rpc_admin_cancel_pool', { p_pool_id: pool.id, p_reason: reason || null }, 'Пул отменён')) {
      setOpen(false)
    }
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="destructive" size="sm">Отменить пул</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Отменить пул</DialogTitle>
          <DialogDescription>
            Пул будет отменён: pending-офферы снимаются, подобранные батчи возвращаются «На продаже».
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          <Label htmlFor="cp-reason">Причина (необязательно)</Label>
          <Textarea id="cp-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>Закрыть</Button>
          <Button variant="destructive" onClick={submit} disabled={busy}>Отменить пул</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Редактировать пул (draft|filling): окно поставки + цены линий. rpc_admin_edit_pool.
function EditPoolBtn({ pool, onDone }: { pool: AdminPool; onDone: () => void }) {
  const [open, setOpen] = useState(false)
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [prices, setPrices] = useState<Record<string, string>>(
    () => Object.fromEntries(pool.lines.map((l) => [l.id, String(l.price)])),
  )
  const { busy, call } = useRpcAction(onDone)
  const submit = async () => {
    const p_lines = pool.lines.map((l) => ({
      pool_line_id: l.id,
      mpk_price_per_kg: Number(prices[l.id]),
    }))
    const ok = await call('rpc_admin_edit_pool', {
      p_pool_id: pool.id,
      p_delivery_from: from || null,
      p_delivery_to: to || null,
      p_lines: p_lines.length ? p_lines : null,
    }, 'Пул обновлён')
    if (ok) setOpen(false)
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">Редактировать</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Редактировать пул</DialogTitle>
          <DialogDescription>
            Окно поставки (пустое — без изменений) и цены линий (₸/кг, не ниже минимальной цены категории).
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <Label htmlFor="ep-from">Поставка с</Label>
              <Input id="ep-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="ep-to">Поставка до</Label>
              <Input id="ep-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
            </div>
          </div>
          {pool.lines.length > 0 && (
            <div className="space-y-2 pt-1">
              <div className="text-xs uppercase tracking-wider text-[var(--fg2)]">Цены линий, ₸/кг</div>
              {pool.lines.map((l) => (
                <div key={l.id} className="flex items-center gap-3">
                  <span className="flex-1 text-sm">{CAT_RU[l.code] ?? l.code}</span>
                  <Input
                    type="number"
                    min={1}
                    className="w-32"
                    value={prices[l.id] ?? ''}
                    onChange={(e) => setPrices((s) => ({ ...s, [l.id]: e.target.value }))}
                  />
                </div>
              ))}
            </div>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>Закрыть</Button>
          <Button onClick={submit} disabled={busy}>Сохранить</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Подобрать батч к пулу (ручной оператор-matching, M6-предикат в RPC). rpc_admin_match_batch_to_pool.
function MatchBatchBtn({ pool, batches, onDone }: { pool: AdminPool; batches: AdminBatch[]; onDone: () => void }) {
  const [open, setOpen] = useState(false)
  const [batchId, setBatchId] = useState('')
  const { busy, call } = useRpcAction(onDone)
  const eligible = batches.filter((b) => b.status === 'published' && !b.poolId)
  const submit = async () => {
    if (!batchId) return
    if (await call('rpc_admin_match_batch_to_pool', { p_pool_id: pool.id, p_batch_id: batchId }, 'Батч подобран')) {
      setBatchId('')
      setOpen(false)
    }
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">Подобрать батч</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Подобрать батч к пулу</DialogTitle>
          <DialogDescription>
            Совпадение по цене, SKU, окну поставки и региону проверяет RPC — несовместимый батч будет отклонён.
          </DialogDescription>
        </DialogHeader>
        {eligible.length === 0 ? (
          <p className="text-sm text-muted-foreground">Нет свободных батчей «На продаже».</p>
        ) : (
          <Select value={batchId} onValueChange={setBatchId}>
            <SelectTrigger><SelectValue placeholder="Выберите батч" /></SelectTrigger>
            <SelectContent>
              {eligible.map((b) => (
                <SelectItem key={b.id} value={b.id}>
                  {catLabel(b.cat, b.grade)} · {b.heads} гол. · {money(b.price)} ₸/кг · {b.farmName ?? '—'}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>Закрыть</Button>
          <Button onClick={submit} disabled={busy || !batchId}>Подобрать</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Откатить подбор (matched → published). rpc_admin_unmatch.
function UnmatchBtn({ pool, batches, onDone }: { pool: AdminPool; batches: AdminBatch[]; onDone: () => void }) {
  const [open, setOpen] = useState(false)
  const [batchId, setBatchId] = useState('')
  const [reason, setReason] = useState('')
  const { busy, call } = useRpcAction(onDone)
  const matched = batches.filter((b) => b.poolId === pool.id && b.status === 'matched')
  const submit = async () => {
    if (!batchId) return
    const ok = await call('rpc_admin_unmatch', { p_pool_id: pool.id, p_batch_id: batchId, p_reason: reason || null }, 'Подбор откачён')
    if (ok) {
      setBatchId('')
      setReason('')
      setOpen(false)
    }
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">Откатить</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Откатить подбор</DialogTitle>
          <DialogDescription>Батч вернётся «На продаже», объём линии освободится.</DialogDescription>
        </DialogHeader>
        {matched.length === 0 ? (
          <p className="text-sm text-muted-foreground">Нет подобранных батчей в статусе «Подобран».</p>
        ) : (
          <div className="space-y-3">
            <Select value={batchId} onValueChange={setBatchId}>
              <SelectTrigger><SelectValue placeholder="Выберите батч" /></SelectTrigger>
              <SelectContent>
                {matched.map((b) => (
                  <SelectItem key={b.id} value={b.id}>
                    {catLabel(b.cat, b.grade)} · {b.heads} гол. · {b.farmName ?? '—'}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <div className="space-y-1">
              <Label htmlFor="um-reason">Причина (необязательно)</Label>
              <Textarea id="um-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
            </div>
          </div>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>Закрыть</Button>
          <Button variant="destructive" onClick={submit} disabled={busy || !batchId}>Откатить</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Продвинуть статус пула (M6 FSM). rpc_admin_advance_pool_status.
function AdvanceStatusBtn({ pool, onDone }: { pool: AdminPool; onDone: () => void }) {
  const [open, setOpen] = useState(false)
  const [next, setNext] = useState('')
  const { busy, call } = useRpcAction(onDone)
  const options = POOL_NEXT[pool.status] ?? []
  const submit = async () => {
    if (!next) return
    if (await call('rpc_admin_advance_pool_status', { p_pool_id: pool.id, p_new_status: next }, 'Статус пула обновлён')) {
      setNext('')
      setOpen(false)
    }
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">Продвинуть статус</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Продвинуть статус пула</DialogTitle>
          <DialogDescription>
            Текущий: «{rus(pool.status)}». Раскрытие контактов происходит при переходе в «Закрыт (набран/частично)».
          </DialogDescription>
        </DialogHeader>
        <Select value={next} onValueChange={setNext}>
          <SelectTrigger><SelectValue placeholder="Новый статус" /></SelectTrigger>
          <SelectContent>
            {options.map((s) => (
              <SelectItem key={s} value={s}>{rus(s)}</SelectItem>
            ))}
          </SelectContent>
        </Select>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>Закрыть</Button>
          <Button onClick={submit} disabled={busy || !next}>Применить</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function MarketplaceAdmin() {
  useSetTopbar({ title: 'Торговая площадка', titleIcon: <Store size={15} /> })
  const { isAdmin, checking } = useAdminGuard()

  const [batches, setBatches] = useState<AdminBatch[] | null>(null)
  const [pools, setPools] = useState<AdminPool[] | null>(null)
  const [deals, setDeals] = useState<AdminDeal[] | null>(null)
  const [q, setQ] = useState('')

  const load = useCallback(() => {
    supabase.rpc('rpc_admin_tsp_batches').then(({ data }) => setBatches((data as AdminBatch[]) ?? []))
    supabase.rpc('rpc_admin_tsp_pools').then(({ data }) => setPools((data as AdminPool[]) ?? []))
    supabase.rpc('rpc_admin_tsp_deals').then(({ data }) => setDeals((data as AdminDeal[]) ?? []))
  }, [])

  useEffect(() => {
    if (!isAdmin) return
    load()
  }, [isAdmin, load])

  if (checking) return <div className="page">Проверка доступа...</div>
  if (!isAdmin) return null

  const needle = q.trim().toLowerCase()
  const match = (...parts: (string | null | undefined)[]) =>
    !needle || parts.some((p) => (p ?? '').toLowerCase().includes(needle))

  const fBatches = (batches ?? []).filter((b) => match(b.farmName, b.region, b.breed, rus(b.status), CAT_RU[b.cat ?? '']))
  const fPools = (pools ?? []).filter((p) => match(p.mpkName, p.region, rus(p.status)))
  const fDeals = (deals ?? []).filter((d) => match(d.farmName, d.mpkName, d.region, d.breed, CAT_RU[d.cat ?? '']))

  return (
    <div className="page space-y-4">
      <Input
        placeholder="Поиск: ферма, МПК, район, порода, статус…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        className="max-w-md"
      />

      <Tabs defaultValue="batches">
        <TabsList>
          <TabsTrigger value="batches">Батчи{batches ? ` (${fBatches.length})` : ''}</TabsTrigger>
          <TabsTrigger value="pools">Пулы{pools ? ` (${fPools.length})` : ''}</TabsTrigger>
          <TabsTrigger value="deals">Сделки{deals ? ` (${fDeals.length})` : ''}</TabsTrigger>
        </TabsList>

        {/* ── Батчи ── */}
        <TabsContent value="batches" className="space-y-3">
          {batches === null ? (
            <Skeleton className="h-32 w-full" />
          ) : fBatches.length === 0 ? (
            <Empty text="Нет батчей" />
          ) : (
            fBatches.map((b) => (
              <Card key={b.id}>
                <CardContent className="p-4 space-y-2">
                  <div className="flex items-center justify-between gap-3">
                    <div className="font-medium">{catLabel(b.cat, b.grade)}{b.breed ? ` · ${b.breed}` : ''}</div>
                    <Badge variant="secondary">{rus(b.status)}</Badge>
                  </div>
                  <KV k="Ферма" v={b.farmName ?? '—'} />
                  {b.farmPhone && <KV k="Телефон" v={b.farmPhone} />}
                  <KV k="Голов" v={`${b.heads}${b.matchedHeads ? ` · подобрано ${b.matchedHeads}, осталось ${b.remainingHeads}` : ''}`} />
                  <KV k="Ср. вес" v={b.avgWeight ? `${b.avgWeight} кг` : '—'} />
                  <KV k="Цена / сделка" v={`${money(b.price)} / ${money(b.dealPrice)} ₸/кг`} />
                  <KV k="Район" v={b.region || '—'} />
                  <KV k="Создан" v={day(b.createdAtIso)} />
                  {['draft', 'published'].includes(b.status) && (
                    <div className="flex flex-wrap gap-2 pt-2">
                      <EditBatchBtn batch={b} onDone={load} />
                      <CancelBatchBtn batch={b} onDone={load} />
                    </div>
                  )}
                </CardContent>
              </Card>
            ))
          )}
        </TabsContent>

        {/* ── Пулы ── */}
        <TabsContent value="pools" className="space-y-3">
          {pools === null ? (
            <Skeleton className="h-32 w-full" />
          ) : fPools.length === 0 ? (
            <Empty text="Нет пулов" />
          ) : (
            fPools.map((p) => (
              <Card key={p.id}>
                <CardContent className="p-4 space-y-2">
                  <div className="flex items-center justify-between gap-3">
                    <div className="font-medium">{p.mpkName ?? 'МПК'} · {p.region}</div>
                    <Badge variant="secondary">{rus(p.status)}</Badge>
                  </div>
                  {p.mpkPhone && <KV k="Телефон" v={p.mpkPhone} />}
                  <KV k="Набор" v={`${p.matchedHeads}/${p.targetHeads} гол.`} />
                  <KV k="Целевой месяц" v={month(p.targetMonthIso)} />
                  <KV k="Контакты раскрыты" v={p.contactRevealed ? 'да' : 'нет'} />
                  {p.lines.length > 0 && (
                    <div className="pt-1 space-y-1">
                      <div className="text-xs uppercase tracking-wider text-[var(--fg2)]">Категории</div>
                      {p.lines.map((l) => (
                        <div key={l.id} className="text-sm">
                          {CAT_RU[l.code] ?? l.code}: {money(l.price)} ₸/кг
                        </div>
                      ))}
                    </div>
                  )}
                  <KV k="Создан" v={day(p.createdAtIso)} />
                  <div className="flex flex-wrap gap-2 pt-2">
                    {['draft', 'filling'].includes(p.status) && <EditPoolBtn pool={p} onDone={load} />}
                    {p.status === 'filling' && <MatchBatchBtn pool={p} batches={batches ?? []} onDone={load} />}
                    {(batches ?? []).some((b) => b.poolId === p.id && b.status === 'matched') && (
                      <UnmatchBtn pool={p} batches={batches ?? []} onDone={load} />
                    )}
                    {(POOL_NEXT[p.status]?.length ?? 0) > 0 && <AdvanceStatusBtn pool={p} onDone={load} />}
                    {['draft', 'filling'].includes(p.status) && <CancelPoolBtn pool={p} onDone={load} />}
                  </div>
                </CardContent>
              </Card>
            ))
          )}
        </TabsContent>

        {/* ── Сделки ── */}
        <TabsContent value="deals" className="space-y-3">
          {deals === null ? (
            <Skeleton className="h-32 w-full" />
          ) : fDeals.length === 0 ? (
            <Empty text="Нет сделок" />
          ) : (
            fDeals.map((d) => (
              <Card key={d.id}>
                <CardContent className="p-4 space-y-2">
                  <div className="flex items-center justify-between gap-3">
                    <div className="font-medium">{catLabel(d.cat, d.grade)}{d.breed ? ` · ${d.breed}` : ''}</div>
                    <Badge variant="secondary">{rus(d.status)}</Badge>
                  </div>
                  <KV k="Ферма" v={d.farmName ?? '—'} />
                  {d.farmPhone && <KV k="Тел. фермы" v={d.farmPhone} />}
                  <KV k="Покупатель (МПК)" v={d.mpkName ?? '—'} />
                  {d.mpkPhone && <KV k="Тел. МПК" v={d.mpkPhone} />}
                  <KV k="Голов" v={d.heads} />
                  <KV k="Ср. вес" v={d.avgWeight ? `${d.avgWeight} кг` : '—'} />
                  <KV k="Цена" v={`${money(d.price)} ₸/кг`} />
                  <KV k="Сумма" v={d.sum != null ? `≈ ${money(d.sum)} ₸` : '—'} />
                  <KV k="Район" v={d.region || '—'} />
                  <KV k="Матч → доставка" v={`${day(d.matchedAtIso)} → ${day(d.deliveredAtIso)}`} />
                  {d.via && <KV k="Канал матча" v={d.via} />}
                </CardContent>
              </Card>
            ))
          )}
        </TabsContent>
      </Tabs>

      <p className="text-xs text-[var(--fg2)] pt-2">{DISCLAIMER}</p>
    </div>
  )
}
