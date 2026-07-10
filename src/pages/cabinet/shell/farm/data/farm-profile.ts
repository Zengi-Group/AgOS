// AgOS · ARS-212 · Чтение/запись профиля фермы для мастера. Переиспользует существующие RPC
// (аддитивно, HS-1/2/5; сигнатуры не меняем): rpc_get_my_context, rpc_get_farm_summary,
// rpc_upsert_farm, rpc_upsert_herd_group, rpc_set_farm_activity_types. Точка хэндоффа плана —
// rpc_generate_plan_from_profile (ARS-213, ветка claude/ars-213-bridge-eb1dd1): вызывается
// graceful — при отсутствии функции флоу не ломается (финал F7).
//
// Все записи в try/catch: черновик мастера всегда сохранён локально (useFarmDraft), запись в
// БД — best-effort. Нет org/фермы/бэкенда → мастер работает, профиль не пишется (P11).

import { supabase } from '@/lib/supabase'
import { loadMyContext } from '@/lib/account'
import {
  HERD_FIELDS, deriveActivityType, calvingSystemValue, shelterTypeValue,
  type FwState, type HerdKey, type CalvingAnswer, type HousingAnswer, type YoungAnswer,
} from '../types'

export interface FarmCtx {
  organizationId: string | null
  farmId: string | null
  farmName: string | null
  region: string | null
  heads: Record<HerdKey, number>
  calving: CalvingAnswer
  housing: HousingAnswer
  hasHerd: boolean
}

interface RawHerdGroup { animal_category_code?: string | null; head_count?: number | null }
interface RawFarm { calving_system?: string | null; shelter_type?: string | null }
interface RawSummary { farm?: RawFarm; herd_groups?: RawHerdGroup[] }

// code (animal_categories.code) → поле мастера. BULL_CALF складываем в «бычки» вместе со STEER.
const CODE_TO_KEY: Record<string, HerdKey> = {
  COW: 'cows',
  YOUNG_CALF: 'calves',
  SUCKLING_CALF: 'calves',
  HEIFER_YOUNG: 'heifers',
  STEER: 'steers',
  BULL_CALF: 'steers',
  BULL_BREEDING: 'bull',
}

// farms.calving_system → ответ мастера (two_season не имеет чипа → «по-разному»).
function calvingFromDb(v: string | null | undefined): CalvingAnswer {
  if (v === 'spring' || v === 'autumn' || v === 'year_round') return v
  if (v === 'two_season') return 'varies'
  return ''
}
function housingFromDb(v: string | null | undefined): HousingAnswer {
  return v === 'pasture' || v === 'stall' || v === 'mixed' || v === 'feedlot' ? v : ''
}

// Читает контекст фермы для мастера. null = не авторизован / бэкенд недоступен (аноним-демо).
export async function loadFarmCtx(): Promise<FarmCtx | null> {
  const ctx = await loadMyContext()
  if (!ctx) return null

  const org =
    ctx.organizations.find((o) => o.org_types.includes('farmer')) ??
    ctx.organizations.find((o) => o.is_primary) ??
    ctx.organizations[0] ?? null
  const farm = ctx.farms.find((f) => f.is_primary) ?? ctx.farms[0] ?? null

  const region = org?.region_id ? await resolveRegion(org.region_id) : null
  const base: FarmCtx = {
    organizationId: org?.id ?? null,
    farmId: farm?.id ?? null,
    farmName: farm?.name ?? org?.legal_name ?? null,
    region,
    heads: { cows: 0, calves: 0, heifers: 0, steers: 0, bull: 0 },
    calving: '',
    housing: '',
    hasHerd: false,
  }
  if (!farm || !org) return base

  try {
    const { data, error } = await supabase.rpc('rpc_get_farm_summary', {
      p_organization_id: org.id,
      p_farm_id: farm.id,
    })
    if (error || !data) return base
    const s = data as RawSummary
    const groups = Array.isArray(s.herd_groups) ? s.herd_groups : []
    for (const g of groups) {
      const key = g.animal_category_code ? CODE_TO_KEY[g.animal_category_code] : undefined
      if (key) base.heads[key] += g.head_count ?? 0
    }
    base.hasHerd = (Object.values(base.heads) as number[]).some((n) => n > 0)
    base.calving = calvingFromDb(s.farm?.calving_system)
    base.housing = housingFromDb(s.farm?.shelter_type)
    return base
  } catch {
    return base
  }
}

async function resolveRegion(regionId: string): Promise<string | null> {
  try {
    const { data } = await supabase.from('regions').select('name_ru').eq('id', regionId).single()
    return (data as { name_ru: string } | null)?.name_ru ?? null
  } catch { return null }
}

// Гарантирует наличие farm-строки. Есть farmId → возвращаем его; иначе создаём через
// rpc_upsert_farm (data_source='platform' проставляется в RPC при создании). Нет org → null.
export async function ensureFarm(ctx: FarmCtx): Promise<string | null> {
  if (ctx.farmId) return ctx.farmId
  if (!ctx.organizationId) return null
  try {
    const { data, error } = await supabase.rpc('rpc_upsert_farm', {
      p_organization_id: ctx.organizationId,
      p_farm_id: null,
      p_name: ctx.farmName || 'Моя ферма',
      p_region_id: null,
      p_shelter_type: null,
      p_calving_system: null,
    })
    if (error) { console.warn('rpc_upsert_farm (create) недоступен:', error.message); return null }
    return (data as string) ?? null
  } catch (e) {
    console.warn('rpc_upsert_farm (create) исключение:', e)
    return null
  }
}

// Записывает состав стада (herd_groups, ON CONFLICT по farm_id+category → идемпотентно, дублей
// нет) + выведенный архетип (farm_activity_types). Категории с 0 голов не пишем.
// p_data_source='platform' → confidence 75/L3 в RPC (Узел 1 §4, D21; аддитивный параметр ARS-212).
export async function saveHerdAndArchetype(orgId: string, farmId: string, heads: FwState['heads']): Promise<void> {
  for (const f of HERD_FIELDS) {
    const n = heads[f.key]
    if (!n || n <= 0) continue
    try {
      const { error } = await supabase.rpc('rpc_upsert_herd_group', {
        p_organization_id: orgId,
        p_farm_id: farmId,
        p_animal_category_code: f.code,
        p_head_count: n,
        p_data_source: 'platform',
      })
      if (error) console.warn('rpc_upsert_herd_group', f.code, error.message)
    } catch (e) { console.warn('rpc_upsert_herd_group исключение', f.code, e) }
  }
  try {
    const { error } = await supabase.rpc('rpc_set_farm_activity_types', {
      p_organization_id: orgId,
      p_farm_id: farmId,
      p_activity_types: [deriveActivityType(heads)],
    })
    if (error) console.warn('rpc_set_farm_activity_types', error.message)
  } catch (e) { console.warn('rpc_set_farm_activity_types исключение', e) }
}

// D78: месяц первого отёла (1–12) → якорная дата цикла = ближайшее будущее 1-е число месяца
// (комментарий колонки farms.cycle_start_date). year_round/«по-разному»/skip → null (не пишем).
function cycleStartFromMonth(month: number): string {
  const now = new Date()
  const year = now.getFullYear() + (month < now.getMonth() + 1 ? 1 : 0)
  return `${year}-${String(month).padStart(2, '0')}-01`
}

// Обновляет поля фермы (calving_system / shelter_type / cycle_start_date / calf_strategy).
// rpc_upsert_farm(coalesce) — null-поля не затирают существующие; поэтому смена сезонного отёла
// на year_round НЕ чистит старый cycle_start_date — мост ARS-213 смотрит calving_system и
// игнорирует нерелевантный якорь. Токены calf_strategy = CHECK колонки (L-7).
export async function saveFarmField(
  orgId: string, farmId: string,
  patch: { calving?: CalvingAnswer; calvingMonth?: number | null; housing?: HousingAnswer; young?: YoungAnswer },
): Promise<void> {
  try {
    const { error } = await supabase.rpc('rpc_upsert_farm', {
      p_organization_id: orgId,
      p_farm_id: farmId,
      p_name: null,
      p_region_id: null,
      p_shelter_type: patch.housing !== undefined ? shelterTypeValue(patch.housing) : null,
      p_calving_system: patch.calving !== undefined ? calvingSystemValue(patch.calving) : null,
      p_cycle_start_date: patch.calvingMonth ? cycleStartFromMonth(patch.calvingMonth) : null,
      p_calf_strategy: patch.young || null,
    })
    if (error) console.warn('rpc_upsert_farm (update) недоступен:', error.message)
  } catch (e) { console.warn('rpc_upsert_farm (update) исключение:', e) }
}

// Точка хэндоффа генерации draft-ЦТК (ARS-213, ветка claude/ars-213-bridge-eb1dd1):
// rpc_generate_plan_from_profile (порог: маточное>0 + ответ про отёл; year_round легален;
// ниже порога — graceful). Вызывается только при достигнутом пороге. RPC может отсутствовать в
// этом деплое (несмёрженная ветка) → любую ошибку глотаем: мастер завершится финалом F7.
// Показ плана — ARS-215 (вне этого слайса).
export async function generatePlan(orgId: string, farmId: string): Promise<void> {
  try {
    const { error } = await supabase.rpc('rpc_generate_plan_from_profile', {
      p_organization_id: orgId,
      p_farm_id: farmId,
    })
    if (error) console.warn('rpc_generate_plan_from_profile (ARS-213) недоступен:', error.message)
  } catch (e) { console.warn('rpc_generate_plan_from_profile (ARS-213) исключение:', e) }
}
