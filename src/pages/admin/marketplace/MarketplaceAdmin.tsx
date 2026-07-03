/**
 * Админ · Торговая площадка — единый read-only обзор ТСП.
 * Три вкладки: Батчи (партии ферм) · Пулы (заявки МПК) · Сделки (batch_allocations).
 * Данные: rpc_admin_tsp_batches / rpc_admin_tsp_pools / rpc_admin_tsp_deals
 * (security-definer, гейт fn_is_admin(), контакты сторон раскрыты — админ = оператор).
 * Read-only: никаких действий над чужими сделками. Ст. 171 ПК РК — дисклеймер (есть цены).
 */
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useState, useEffect } from 'react'
import { Store } from 'lucide-react'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
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
interface AdminPoolLine { code: string; price: number }
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

export function MarketplaceAdmin() {
  useSetTopbar({ title: 'Торговая площадка', titleIcon: <Store size={15} /> })
  const { isAdmin, checking } = useAdminGuard()

  const [batches, setBatches] = useState<AdminBatch[] | null>(null)
  const [pools, setPools] = useState<AdminPool[] | null>(null)
  const [deals, setDeals] = useState<AdminDeal[] | null>(null)
  const [q, setQ] = useState('')

  useEffect(() => {
    if (!isAdmin) return
    supabase.rpc('rpc_admin_tsp_batches').then(({ data }) => setBatches((data as AdminBatch[]) ?? []))
    supabase.rpc('rpc_admin_tsp_pools').then(({ data }) => setPools((data as AdminPool[]) ?? []))
    supabase.rpc('rpc_admin_tsp_deals').then(({ data }) => setDeals((data as AdminDeal[]) ?? []))
  }, [isAdmin])

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
                      {p.lines.map((l, i) => (
                        <div key={i} className="text-sm">
                          {CAT_RU[l.code] ?? l.code}: {money(l.price)} ₸/кг
                        </div>
                      ))}
                    </div>
                  )}
                  <KV k="Создан" v={day(p.createdAtIso)} />
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
