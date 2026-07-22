// AgOS · ARS-285 (Ферма 2.0 · F9) · Данные таба «Стадо» (SCR-HD) + режима «Обход» (SCR-WK).
// Один вызов rpc_get_herd_board = SCR-HD + SCR-WK = один кэш-юнит (Slice8 §4/§5, D145).
// Мутации: rpc_mark_walkthrough (отметка обхода, NK-идемпотентность) · rpc_log_animal_event
// (отклонение по бирке, lazy-создание животного, D140) · rpc_close_animal_event (закрытие,
// FSM-идемпотентность). Карточка животного (SHEET-AN) — отдельный кэш-юнит
// rpc_get_animal_card. Словарь типов отклонений (animal_event_types) — платформенный
// справочник без organization_id (P8), читается напрямую — тот же паттерн, что regions в
// farm-profile.ts:100. client_event_id/client_task_id: F6-F8 (farm-tasks.ts createFarmTask)
// уже решили передавать null до полного offline-слоя (F10/ARS-286) — держим тот же выбор
// здесь, а не изобретаем client-side id для функции, которую пока некому реплеить (P4).
// Формы возврата сверены с телом задеплоенных функций (pg_proc, prod, 2026-07-22 — L-6).

import { supabase } from '@/lib/supabase'
import { localToday } from './farm-overview'
import type { RpcResult } from './farm-overview'

export type { RpcResult }

export interface HerdGroupRow {
  id: string
  category_name: string
  head_count: number
  avg_weight_kg: number | null
}

export interface OpenEventRow {
  event_id: string
  animal_id: string
  tag_number: string
  type_code: string
  type_name: string
  occurred_at: string
  note: string | null
  vet_case_id: string | null
  task_id: string | null
}

export interface RecentAnimal {
  animal_id: string
  tag_number: string
  herd_group_id: string | null
}

export interface HerdBoard {
  ok: true
  herd_total: number
  groups: HerdGroupRow[]
  walkthrough: { marked: boolean; marked_at: string | null }
  open_events: OpenEventRow[]
  today_events_count: number
  animals_recent: RecentAnimal[]
}

export interface AnimalEventTypeOption {
  id: string
  code: string
  name_ru: string
}

export interface AnimalCardEvent {
  event_id: string
  type_code: string
  type_name: string
  status: 'open' | 'closed'
  note: string | null
  photo_url: string | null
  occurred_at: string
  recorded_by_name: string | null
  closed_at: string | null
  closed_by_name: string | null
  resolution_note: string | null
  vet_case_id: string | null
}

export interface AnimalCardData {
  ok: true
  animal: {
    id: string
    tag_number: string
    status: 'in_herd' | 'left_herd'
    herd_group_id: string | null
    herd_group_name: string | null
    left_at: string | null
    left_reason: string | null
    notes: string | null
    created_at: string
  }
  events: AnimalCardEvent[]
}

export async function loadHerdBoard(orgId: string, farmId: string): Promise<HerdBoard> {
  const { data, error } = await supabase.rpc('rpc_get_herd_board', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_today: localToday(),
  })
  if (error) throw error
  return data as HerdBoard
}

// «Обход сделан» (§4.2). already_marked=true при повторе (NK farm_id+walk_date) — UI не даёт
// повторный тап (кнопки нет после отметки), но идемпотентность не полагается на это.
export async function markWalkthrough(
  orgId: string, farmId: string,
): Promise<RpcResult & { walkthrough_id?: string; marked_at?: string; already_marked?: boolean }> {
  const { data, error } = await supabase.rpc('rpc_mark_walkthrough', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_walk_date: localToday(),
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult & { walkthrough_id?: string; marked_at?: string; already_marked?: boolean }
}

// Отклонение (§4.4, шаг 2 завершает ввод). tagNumber: реестр lazy (D140) — новый номер легален,
// создаёт animal (animal_created=true в ответе).
export async function logAnimalEvent(
  orgId: string, farmId: string,
  args: { tagNumber: string; eventTypeCode: string; herdGroupId?: string | null; note?: string | null; photoUrl?: string | null },
): Promise<RpcResult & { event_id?: string; animal_id?: string; animal_created?: boolean }> {
  const { data, error } = await supabase.rpc('rpc_log_animal_event', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_tag_number: args.tagNumber,
    p_event_type_code: args.eventTypeCode,
    p_herd_group_id: args.herdGroupId ?? null,
    p_note: args.note ?? null,
    p_photo_url: args.photoUrl ?? null,
    p_occurred_at: new Date().toISOString(),
    p_client_event_id: null,
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult & { event_id?: string; animal_id?: string; animal_created?: boolean }
}

// «Закрыть событие» (SHEET-AN). already_closed=true при повторе (FSM-идемпотентность).
export async function closeAnimalEvent(
  orgId: string, eventId: string, resolutionNote?: string | null,
): Promise<RpcResult & { status?: string; already_closed?: boolean }> {
  const { data, error } = await supabase.rpc('rpc_close_animal_event', {
    p_organization_id: orgId,
    p_event_id: eventId,
    p_resolution_note: resolutionNote ?? null,
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult & { status?: string; already_closed?: boolean }
}

export async function loadAnimalCard(
  orgId: string, animalId: string,
): Promise<AnimalCardData | { ok: false; reason: string }> {
  const { data, error } = await supabase.rpc('rpc_get_animal_card', {
    p_organization_id: orgId,
    p_animal_id: animalId,
  })
  if (error) throw error
  return data as AnimalCardData | { ok: false; reason: string }
}

// Словарь типов отклонений (§4.4, шаг 2) — платформенный справочник (P8): read authenticated
// (RLS animal_event_types_read_authenticated), без organization_id. Прямой .from() — тот же
// паттерн, что regions в farm-profile.ts:100.
export async function loadEventTypes(): Promise<AnimalEventTypeOption[]> {
  const { data, error } = await supabase
    .from('animal_event_types')
    .select('id, code, name_ru')
    .eq('is_active', true)
    .order('sort_order')
  if (error) throw error
  return (data ?? []) as AnimalEventTypeOption[]
}

// «Осмотр» — предложение действия после отклонения (§4.4/§2.2 inspect). Отдельная обёртка от
// createFarmTask (farm-tasks.ts, «+»-ручная задача, category='management', без animal_event_id):
// здесь category='veterinary' + p_animal_event_id — не расширяем существующий вызов, чтобы не
// трогать протестированный флоу «+» ручной задачи. NO_ACTIVE_PLAN — доменный отказ (нет плана).
export async function createInspectionTask(
  orgId: string, farmId: string, eventId: string, tagNumber: string,
): Promise<RpcResult & { task_id?: string }> {
  const { data, error } = await supabase.rpc('rpc_create_farm_task', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_name_ru: `Осмотр — №${tagNumber}`,
    p_due_date: localToday(),
    p_due_time: null,
    p_category: 'veterinary',
    p_assigned_to: null,
    p_animal_event_id: eventId,
    p_client_task_id: null,
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult & { task_id?: string }
}

// «Ветврачу» — эскалация события в vet_cases (§2.6/D147). already_linked=true при повторе.
export async function createVetCaseFromEvent(
  orgId: string, eventId: string,
): Promise<RpcResult & { vet_case_id?: string; already_linked?: boolean }> {
  const { data, error } = await supabase.rpc('rpc_create_vet_case_from_event', {
    p_organization_id: orgId,
    p_event_id: eventId,
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult & { vet_case_id?: string; already_linked?: boolean }
}
