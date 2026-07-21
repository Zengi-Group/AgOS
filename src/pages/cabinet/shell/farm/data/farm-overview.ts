// AgOS · ARS-281 (Ферма 2.0 · F5) · Данные экрана «Обзор» (SCR-OV).
// Один вызов rpc_get_farm_overview = весь экран = один кэш-юнит (eng-spec §2.7, D145).
// Действия строк/зон переиспользуют существующие RPC (аддитивно, сигнатуры не меняем — P7):
// rpc_complete_farm_task (чек задачи), rpc_reschedule_farm_task («На сегодня»),
// rpc_activate_production_plan (state D «Активировать план»). AI и веб зовут те же RPC.
// Формы возврата ниже сверены с телом задеплоенных функций (pg_proc, prod), не с доком (L-6).

import { supabase } from '@/lib/supabase'

// Локальная дата фермера (YYYY-MM-DD) — окно/обход считаются от локального дня (Slice8 §1.4),
// поэтому p_today передаём явно, а не полагаемся на серверный current_date.
export function localToday(): string {
  const d = new Date()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${d.getFullYear()}-${m}-${day}`
}

export interface FeedSignal {
  feed_item_id: string | null
  feed: string
  feed_code: string
  days_left: number
  buy: boolean
}

// action.type задеплоенного _fn_farm_attention: open_animal · open_window · reschedule_today ·
// open_resources (inspect/to_vet из дока §2.2 создаются на экране Обхода F9, здесь их нет).
export type AttentionAction =
  | 'open_animal' | 'open_window' | 'reschedule_today' | 'open_resources'

export interface AttentionItem {
  kind: 'animal' | 'window' | 'task' | 'feed'
  priority: number
  title: string
  subtitle: string
  action: { type: AttentionAction; ref_id: string | null }
}

export interface TodayTask {
  task_id: string
  name: string
  status: string
  category: string | null
  due_date: string
  due_time: string | null   // 'HH:MM:SS'
  source: 'cycle' | 'deviation' | 'manual'
  window_end: string | null // date
  heads: number | null
}

export interface OverviewCycle {
  plan_id: string | null
  no_plan: boolean
  draft_plan_id: string | null
  phase_name: string | null
  day: number | null
  days_total: number | null
  next_window: { task_id: string; name: string; ends_in_days: number; burning: boolean } | null
}

export interface FarmOverview {
  as_of: string
  herd: { total: number; walkthrough_marked: boolean; marked_at: string | null; groups_count: number }
  cycle: OverviewCycle
  tasks: { today_total: number; today_done: number; overdue: number }
  resources: { tracked: boolean; min_days_left: number | null; signals: FeedSignal[] }
  attention: AttentionItem[]
  today: TodayTask[]
  today_more_count: number
}

// Доменный ответ мутаций-RPC (SKIP LOCKED / guard-паттерн): {ok:false, reason} при отказе.
export interface RpcResult { ok?: boolean; reason?: string; [k: string]: unknown }

export async function loadFarmOverview(orgId: string, farmId: string): Promise<FarmOverview> {
  const { data, error } = await supabase.rpc('rpc_get_farm_overview', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_today: localToday(),
  })
  if (error) throw error
  return data as FarmOverview
}

// Чек задачи дня (§2.3). actor=null → RPC берёт auth.uid() (клиент авторизован JWT фермера).
export async function completeFarmTask(orgId: string, taskId: string): Promise<void> {
  const { error } = await supabase.rpc('rpc_complete_farm_task', {
    p_organization_id: orgId,
    p_task_id: taskId,
    p_result_description: null,
    p_result_data: null,
    p_actor_id: null,
    p_ai_context: null,
  })
  if (error) throw error
}

// «На сегодня» для просрочки (§2.2). Guard задачи-окна → {ok:false, reason:'WINDOW_TASK_IMMOVABLE'}.
export async function rescheduleFarmTaskToday(orgId: string, taskId: string): Promise<RpcResult | null> {
  const { data, error } = await supabase.rpc('rpc_reschedule_farm_task', {
    p_organization_id: orgId,
    p_task_id: taskId,
    p_new_due_date: localToday(),
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult | null
}

// State D: активация draft-плана (§2.4 / eng-spec §2.11). PLAN_ALREADY_ACTIVE_EXISTS → {ok:false}.
export async function activateProductionPlan(orgId: string, planId: string): Promise<RpcResult | null> {
  const { data, error } = await supabase.rpc('rpc_activate_production_plan', {
    p_organization_id: orgId,
    p_plan_id: planId,
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult | null
}
