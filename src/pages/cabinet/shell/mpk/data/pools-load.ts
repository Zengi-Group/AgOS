// AgOS · Слайс 4 · Загрузка пулов МПК и матчей из БД.
// rpc_get_my_pools — пулы текущего МПК; rpc_get_pool_matches — поставщики пула
// (контакты раскрыты только после executing, D40). Фолбэк — caller берёт seed.

import { supabase } from '@/lib/supabase'
import { MPK_CATS, type MpkCatKey, type Pool, type PoolLine, type PoolStatus, type SupplierRow } from '../types'

interface RawPool {
  id: string
  status: string
  totalHeads: number
  filledHeads: number
  region: string
  targetMonthIso: string | null
  createdAtIso: string | null
  lines: { code?: string; price?: number }[]
  contactRevealed: boolean
}

interface RawMatch {
  matchId: string
  batchId: string
  cat: string
  heads: number
  avgWeight: number
  price: number
  region: string
  status: string
  farmName: string | null
  farmPhone: string | null
}

// DB-статус пула → фронтовый PoolStatus (dispatched/delivered показываем как «Приёмка»).
function mapStatus(s: string): PoolStatus {
  if (s === 'dispatched' || s === 'delivered') return 'executing'
  // Канон-статусы close: авто-закрытый/частичный пул → «набран, готов к приёмке».
  if (s === 'closed_filled' || s === 'closed_partial' || s === 'awaiting_mpk_decision') return 'filled'
  if (s === 'completed') return 'executed'
  if (s === 'expired_empty' || s === 'closed_unfilled' || s === 'cancelled') return 'closed'
  if (s === 'filling' || s === 'filled' || s === 'executing' || s === 'executed' || s === 'closed') {
    return s as PoolStatus
  }
  return 'filling'
}

const fmtMonth = (iso: string | null): string =>
  iso ? new Intl.DateTimeFormat('ru-RU', { month: 'long', year: 'numeric' }).format(new Date(iso)) : 'этот месяц'
const fmtDay = (iso: string | null): string =>
  iso ? new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short' }).format(new Date(iso)) : 'сегодня'

function toLines(raw: { code?: string; price?: number }[]): PoolLine[] {
  if (!Array.isArray(raw)) return []
  return raw
    .filter((l) => l.code && l.code in MPK_CATS)
    .map((l) => ({ catKey: l.code as MpkCatKey, price: l.price ?? 0 }))
}

function toPool(r: RawPool): Pool {
  const lines = toLines(r.lines)
  const first = lines[0]
  return {
    id: r.id,
    status: mapStatus(r.status),
    title: first ? `${MPK_CATS[first.catKey].name} · ${r.region}` : `Закупка · ${r.region}`,
    region: r.region,
    totalHeads: r.totalHeads,
    filledHeads: r.filledHeads,
    targetMonth: fmtMonth(r.targetMonthIso),
    lines,
    suppliers: [],
    createdAt: fmtDay(r.createdAtIso),
  }
}

// Пулы МПК. null = backend недоступен/аноним → caller берёт seedPools.
export async function loadMyPools(): Promise<Pool[] | null> {
  try {
    const { data, error } = await supabase.rpc('rpc_get_my_pools', {})
    if (error || !Array.isArray(data)) return null
    return (data as RawPool[]).map(toPool)
  } catch {
    return null
  }
}

// Авто-закрытие просроченных пулов (D-AUTOCLOSE-01): дедлайн (конец target_month)
// прошёл → >=30% набрано = filled (успех), иначе = closed. Ленивый вызов из шелла.
// Ошибки/нет backend/аноним — тихо пропускаем (фолбэк на seed остаётся у caller).
export async function closeDuePools(): Promise<void> {
  try {
    await supabase.rpc('rpc_self_close_due_pools', {})
  } catch {
    /* нет backend / аноним — пропускаем */
  }
}

function toSupplier(m: RawMatch): SupplierRow {
  return {
    id: m.matchId,
    rating: 4.5,
    heads: m.heads,
    price: m.price,
    deliveryStatus:
      m.status === 'delivered' ? 'delivered'
      : m.status === 'dispatched' ? 'in_transit'
      : 'awaiting_dispatch',
    farmName: m.farmName ?? undefined,
    district: m.region,
  }
}

// Матчи пула → поставщики. null = ошибка/нет доступа.
export async function loadPoolMatches(poolId: string): Promise<SupplierRow[] | null> {
  try {
    const { data, error } = await supabase.rpc('rpc_get_pool_matches', { p_pool_id: poolId })
    if (error || !Array.isArray(data)) return null
    return (data as RawMatch[]).map(toSupplier)
  } catch {
    return null
  }
}
