// AgOS · ARS-282 (Ферма 2.0 · F6) · Данные экрана «Задачи» (SCR-TA) — горизонт Неделя.
// rpc_get_tasks_horizon(p_horizon) — тот же кэш-юнит-паттерн, что у Обзора (eng-spec §2.8).
// Чек/перенос — общие RPC с Обзором (farm-overview.ts), НЕ дублируем (P4). Формы ниже сверены
// с телом задеплоенной функции на проде (pg_get_functiondef), не с доком (L-6) — включая
// ARS-282-дельту (assigned_to_name join + heads/ref_date в burning[]), которую в неё внесли.
// Горизонт Год (ARS-284, F8) — внизу файла: та же rpc_get_tasks_horizon('year') + сдвиг
// старта случки (fn_preview_cascade превью → rpc_shift_breeding_start, D144, slice §2.9).

import { supabase } from '@/lib/supabase'
import { localToday, type RpcResult } from './farm-overview'

export type Horizon = 'week' | 'month' | 'year'

export interface BurningItem {
  kind: 'overdue' | 'window'
  task_id: string
  name: string
  sub: string
  heads: number | null
  ref_date: string // due_date (overdue) либо window_end (window) — форматирует UI
  action: { type: 'reschedule_today' | 'open_window'; ref_id: string }
}

export interface WeekTask {
  id: string
  name: string
  status: string
  category: 'zootechnical' | 'veterinary' | 'management'
  heads: number | null
  due_time: string | null // 'HH:MM:SS'
  assigned_to: string | null
  assigned_to_name: string | null
  sop_code: string | null
  window_end: string | null
  source: 'cycle' | 'deviation' | 'manual'
}

export interface WeekDay {
  d: string
  load: number
  has_overdue: boolean
  tasks: WeekTask[]
}

export interface WeekHorizon {
  ok: true
  horizon: 'week'
  no_plan: false
  range: { from: string; to: string }
  context: { phase_name: string; day: number; days_total: number } | null
  burning: BurningItem[]
  days: WeekDay[]
}

export interface MonthMilestone { phase_id: string; name: string; date: string; kind: 'phase_start' }

export interface MonthHorizon {
  ok: true
  horizon: 'month'
  no_plan: false
  range: { from: string; to: string }
  milestones: MonthMilestone[]
  // grid/windows/prep не типизируем — Неделя (F6) их не читает (F7, ARS-283).
  [k: string]: unknown
}

export interface NoPlanHorizon {
  ok: true
  no_plan: true
  horizon: string
}

export type WeekHorizonResult = WeekHorizon | NoPlanHorizon

export async function loadWeekHorizon(orgId: string, farmId: string, anchor?: string): Promise<WeekHorizonResult> {
  const { data, error } = await supabase.rpc('rpc_get_tasks_horizon', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_horizon: 'week',
    p_anchor: anchor ?? localToday(),
  })
  if (error) throw error
  return data as WeekHorizonResult
}

// Только для «пустой недели» (межфазье, §3.1) — ближайшая веха месяца, когда в Неделе нечего показать.
export async function loadNextMilestone(orgId: string, farmId: string, anchor?: string): Promise<MonthMilestone | null> {
  const { data, error } = await supabase.rpc('rpc_get_tasks_horizon', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_horizon: 'month',
    p_anchor: anchor ?? localToday(),
  })
  if (error) throw error
  const month = data as MonthHorizon | NoPlanHorizon
  if (month.no_plan) return null
  const today = anchor ?? localToday()
  return (month as MonthHorizon).milestones.find((m) => m.date >= today) ?? null
}

// «+» ручная задача (slice §3, eng-spec §2.14). Исполнитель не выбираем — нет ростера участников
// (открытый вопрос handoff §12 «раздача помощникам» не решён CEO; поле — когда решится модель).
export async function createFarmTask(
  orgId: string, farmId: string,
  params: { nameRu: string; dueDate: string; dueTime?: string | null },
): Promise<RpcResult | null> {
  const { data, error } = await supabase.rpc('rpc_create_farm_task', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_name_ru: params.nameRu,
    p_due_date: params.dueDate,
    p_due_time: params.dueTime ?? null,
    p_category: 'management',
    p_assigned_to: null,
    p_animal_event_id: null,
    p_client_task_id: null,
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult | null
}

// ── Год (F8, ARS-284) — Slice8 §3.3: таймлайн фаз + сдвиг старта случки ───────

export interface YearMilestone { date: string; name: string }

export interface YearPhase {
  id: string
  name_ru: string
  start_date: string
  end_date: string
  status: 'upcoming' | 'active' | 'completed' | 'skipped'
  day: number | null
  days_total: number
  progress_pct: number
  milestones: YearMilestone[]
  expected_heads: number | null // herd_group.head_count фазы; null — группа не назначена (D143, честное отсутствие)
}

export interface YearBreeding { phase_id: string; start_date: string; editable: true }

export interface YearHorizon {
  ok: true
  horizon: 'year'
  no_plan: false
  plan: { id: string; name: string; cycle_start: string; cycle_end: string }
  phases: YearPhase[]
  breeding: YearBreeding | null
}

export type YearHorizonResult = YearHorizon | NoPlanHorizon

export async function loadYearHorizon(orgId: string, farmId: string, anchor?: string): Promise<YearHorizonResult> {
  const { data, error } = await supabase.rpc('rpc_get_tasks_horizon', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_horizon: 'year',
    p_anchor: anchor ?? localToday(),
  })
  if (error) throw error
  return data as YearHorizonResult
}

export interface CascadePreviewItem {
  phase_id: string
  phase_name: string
  old_start: string
  new_start: string
  old_end: string
  new_end: string
  shift_days: number
  date_type: string
  depth: number
}

// Превью каскада (slice §3.3, RPC-36) — read-only, ничего не пишет. fn_preview_cascade несёт
// собственный access-check (L-7: org фермы через user_organization_roles) — вызывается напрямую,
// без organization_id (не self-RPC). Остаточный долг: PUBLIC execute на fn_preview_cascade/
// fn_shift_phase_cascade не отозван (SEC-GRANT-PUBLIC-01, Dok6 §10) — не эксплойт (guard внутри
// защищает), точечный revoke — отдельный проход после сверки эксперт-консоли.
export async function previewBreedingShift(phaseId: string, newStartDate: string): Promise<CascadePreviewItem[]> {
  const { data, error } = await supabase.rpc('fn_preview_cascade', {
    p_phase_id: phaseId,
    p_new_start_date: newStartDate,
  })
  if (error) throw error
  return (data as CascadePreviewItem[]) ?? []
}

export type ShiftBreedingResult =
  | { ok: true; shifted_tasks_count: number; no_change?: boolean }
  | { ok: false; reason: string }

// Сдвиг старта случки (slice §2.9, D144) — фермерская обёртка: ownership-guard + fn_shift_phase_cascade
// (не меняется, P7) + сдвиг задач сдвинутых фаз на тот же delta. Прошлое не трогает (только
// scheduled/reminded/overdue). Вызывать ТОЛЬКО после confirm по превью — эта функция уже пишет.
export async function shiftBreedingStart(orgId: string, farmId: string, newStartDate: string): Promise<ShiftBreedingResult> {
  const { data, error } = await supabase.rpc('rpc_shift_breeding_start', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_new_start_date: newStartDate,
    p_actor_id: null,
  })
  if (error) throw error
  return data as ShiftBreedingResult
}
