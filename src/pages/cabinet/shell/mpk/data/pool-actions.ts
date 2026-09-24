// AgOS · Slice11 (ARS-718) · Мутирующие ходы по заявке МПК с десктопной консоли.
//
// FR-008/FR-009/FR-015: зовём ТЕ ЖЕ RPC, что и мобильный шелл, ни одной новой и ни одной
// изменённой. `rpc_self_pool_close_now` среди них НЕТ: досрочного закрытия набора ни один
// `FR`/`M` замороженного блока с десктопа не требует, а обёртка без вызывающего — мёртвый
// код (`HS-4`). Появится требование — вернётся и обёртка.
//
// Правила исходов (порог, возврат партий, раскрытие контактов) живут в SQL — экран
// показывает то, что вернула база, и своей ветки решения не заводит.
//
// FR-025: роли внутри организации ни одна из этих функций не различает — гейт только
// членством (`fn_my_org_ids()`). Это решение владельца 2026-09-17 с названной ценой;
// расхождение с каталогом ролей живёт записью `MPK-TRADE-ROLES-UNENFORCED-01` в
// `IMPL_DEBT`, а не молчанием здесь.
//
// Почему отдельный модуль, а не переиспользование колбэков `MpkApp`: мобильный шелл слайс
// не правит ни строкой (FR-014), а его вызовы живут прямо в теле компонента. Долг «две
// точки вызова одних RPC» записан в `IMPL_DEBT` (`MPK-POOL-RPC-TWO-HOMES-01`), а не
// оставлен молчанием.

import { supabase } from '@/lib/supabase'
import type { SupplierRow } from '../types'
import { LocalError } from './rpc-error-text'

/** Ошибка RPC → Error с сообщением базы: оператору показывают причину, а не
 *  «что-то пошло не так» (FR-024, урок IDENTITY-14 — сырой текст SDK идёт в причину,
 *  а решение, что именно показать, принимает экран). Текста базы нет — своя запасная
 *  фраза, помеченная `LocalError`: экран покажет её как есть, мимо словаря (ARS-691 FR-013). */
function fail(message: string | undefined, fallback: string): never {
  throw message && message.trim() ? new Error(message) : new LocalError(fallback)
}

/** Точка выбора · принять набранное (ARS-695 M-001). */
export async function acceptPartial(poolId: string): Promise<void> {
  const { error } = await supabase.rpc('rpc_self_pool_accept_partial', { p_pool_id: poolId })
  if (error) fail(error.message, 'Не удалось принять набранное')
}

/** Точка выбора · вернуть партии поставщикам (ARS-695 M-002). */
export async function returnBatches(poolId: string): Promise<void> {
  const { error } = await supabase.rpc('rpc_self_pool_return_batches', { p_pool_id: poolId })
  if (error) fail(error.message, 'Не удалось вернуть партии')
}

/** FR-009 · приёмка по строке поставщика идёт по маршруту строки (ARS-684):
 *  `batch` — партия целиком (`batches.id`), иначе кусок партии (`batch_allocations.id`).
 *  Легаси-строка без `source` читается как кусок — так же, как в мобильном шелле. */
export async function confirmDeliveryRow(id: string, source?: SupplierRow['source']): Promise<void> {
  const { error } = source === 'batch'
    ? await supabase.rpc('rpc_self_confirm_delivery', { p_batch_id: id })
    : await supabase.rpc('rpc_self_confirm_delivery_alloc', { p_allocation_id: id })
  if (error) fail(error.message, 'Не удалось подтвердить приёмку')
}

export interface CreateRequestInput {
  organizationId: string
  totalHeads: number
  /** Первое число целевого месяца, `YYYY-MM-01`, собранное из ЛОКАЛЬНЫХ компонент даты. */
  targetMonth: string
  regionIds: string[]
  districtIds: string[]
  lines: { code: string; price: number; maxHeads: number | null; breed: string | null }[]
}

/** FR-024 · заведение заявки с десктопа — той же парой RPC, что мобильная форма.
 *  Второй ветки создания на клиенте нет: правила (пол цены, лимиты строк) остаются
 *  за базой, экран лишь не даёт отправить заведомо неполную форму.
 *
 *  M-020: если активация отказала после успешного создания, заявка остаётся
 *  НЕАКТИВИРОВАННОЙ — `rpc_get_my_pools` отдаёт пулы, а пул создаёт именно активация,
 *  поэтому в списке она не появится, и повтор формы не даст дубля в списке. */
export async function createPoolRequest(input: CreateRequestInput): Promise<string> {
  const { data: reqId, error: e1 } = await supabase.rpc('rpc_self_create_pool_request', {
    p_organization_id: input.organizationId,
    p_total_heads: input.totalHeads,
    p_target_month: input.targetMonth,
    p_region_id: input.regionIds[0] ?? null,
    p_region_ids: input.regionIds.length ? input.regionIds : null,
    p_district_ids: input.districtIds.length ? input.districtIds : null,
    p_accepted_skus: input.lines,
    p_notes: null,
  })
  if (e1) fail(e1.message, 'Не удалось создать заявку')
  if (!reqId) throw new LocalError('Заявка не создана (пустой ответ сервера)')

  const { data: act, error: e2 } = await supabase.rpc('rpc_self_activate_pool_request', {
    p_request_id: reqId,
  })
  if (e2) fail(e2.message, 'Заявка создана, но не опубликована')
  const poolId = (act as { pool_id?: string } | null)?.pool_id
  if (!poolId) throw new LocalError('Заявка создана, но не опубликована (нет pool_id)')
  return poolId
}
