// AgOS · Загрузка реальной сводки фермы для Главной (Сводка фермы на живых данных).
// Источник истины — rpc_get_farm_summary (RPC-08, d01_kernel.sql): стадо (herd_groups),
// корма, активные вет-кейсы, ближайшие задачи (farm_tasks). Здесь берём только то, что
// нужно Главной фермера: стадо (поголовье по группам) и задачи/горизонт «Впереди».
//
// null = аноним / нет бэкенда / нет фермы → caller (CabinetApp) оставляет seedFarm() (демо).

import { supabase } from '@/lib/supabase'
import { loadMyContext } from '@/lib/account'
import type { FarmState, FarmTask, FarmPlanItem, HerdSummary } from './farm-seed'

interface RawHerdGroup {
  animal_category_name_ru?: string | null
  animal_category_code?: string | null
  breed_name_ru?: string | null
  head_count?: number | null
  avg_weight_kg?: number | null
}

interface RawTask {
  id?: string
  name_ru?: string | null
  category?: string | null
  due_date?: string | null
  status?: string | null
}

interface RawSummary {
  herd_groups?: RawHerdGroup[]
  upcoming_tasks?: RawTask[]
}

function mapHerd(groups: RawHerdGroup[]): HerdSummary {
  const mapped = groups
    .map((g) => ({
      name: g.animal_category_name_ru ?? g.animal_category_code ?? 'Группа',
      heads: g.head_count ?? 0,
      weightKg: g.avg_weight_kg ?? null,
    }))
    .filter((g) => g.heads > 0)
  const totalHeads = mapped.reduce((s, g) => s + g.heads, 0)
  return { totalHeads, groupCount: mapped.length, groups: mapped }
}

const fmtDue = (iso: string | null | undefined): string =>
  iso ? new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short' }).format(new Date(iso)) : ''

function mapTasks(raw: RawTask[]): FarmTask[] {
  return raw.map((t, i) => ({
    id: t.id ?? 'ft' + i,
    title: t.name_ru ?? 'Задача',
    overdue: t.status === 'overdue' ? (fmtDue(t.due_date) || true) : undefined,
  }))
}

function mapPlanFuture(raw: RawTask[]): FarmPlanItem[] {
  // «Впереди» — задачи с датой, кроме просроченных, ближайшие сверху.
  return raw
    .filter((t) => t.due_date && t.status !== 'overdue')
    .slice(0, 4)
    .map((t) => ({ name: t.name_ru ?? 'Задача', dates: fmtDue(t.due_date) }))
}

// Реальная сводка фермы для вошедшего аккаунта. null → caller оставляет seedFarm().
export async function loadFarmState(): Promise<FarmState | null> {
  const ctx = await loadMyContext()
  if (!ctx) return null

  // Основная ферма фермерской орг: primary, иначе первая.
  const farm = ctx.farms.find((f) => f.is_primary) ?? ctx.farms[0] ?? null
  if (!farm) return null

  try {
    const { data, error } = await supabase.rpc('rpc_get_farm_summary', {
      p_organization_id: farm.organization_id,
      p_farm_id: farm.id,
    })
    if (error || !data) return null
    const s = data as RawSummary
    const groups = Array.isArray(s.herd_groups) ? s.herd_groups : []
    const tasks = Array.isArray(s.upcoming_tasks) ? s.upcoming_tasks : []
    return {
      herd: mapHerd(groups),
      tasks: mapTasks(tasks),
      planFuture: mapPlanFuture(tasks),
      // cycle намеренно не задаём — реальная БД его не хранит (см. FarmState).
    }
  } catch {
    return null
  }
}
