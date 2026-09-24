// AgOS · ARS-786 · Ходы по входящему офферу из десктопной консоли МПК.
//
// Зовём ТЕ ЖЕ две RPC, что и мобильный шелл (`rpc_self_accept_offer` /
// `rpc_self_reject_offer`), ни одной новой и ни одной изменённой: слайс UI-only.
//
// Почему отдельный модуль, а не переиспользование колбэков `MpkApp`: мобильный шелл слайс
// не правит ни строкой, а его вызовы живут прямо в теле компонента. Тот же довод и тот же
// долг, что у `pool-actions.ts` (`MPK-POOL-RPC-TWO-HOMES-01` в `IMPL_DEBT`).
//
// Выбор заявки-получателя делает БАЗА (`order by pl.mpk_price_per_kg desc limit 1`), а не
// экран: здесь нет и не должно быть второго дома правила матчинга (`P4`).

import { supabase } from '@/lib/supabase'
import { LocalError, rpcErrorText } from './rpc-error-text'

/** Ответ `rpc_self_accept_offer` — проверено по телу
 *  (`supabase/migrations/20260918120000_ars_731_pool_close_confirm_both_forms.sql:601`):
 *  `jsonb_build_object('batchId', …, 'poolId', …, 'poolLineId', …, 'dealPrice', …)`.
 *  Названия заявки RPC НЕ отдаёт — только `poolId`; имя экран берёт из своего списка
 *  заявок. `dealPrice` — бид комбината (`pl.mpk_price_per_kg`), не ask фермера
 *  (`D-M6-DEALPRICE`). */
export interface AcceptedOffer {
  batchId: string
  poolId: string
  poolLineId: string
  dealPrice: number
}

// ── Отказы базы человеческим языком ─────────────────────────────────────────
//
// Свой словарь фраз здесь СНЯТ. ARS-691 («Отказы базы в зоне МПК — фразой из словаря»)
// выложен на прод (PR #220/#221), и его `rpcErrorText` покрывает все семь кодов этого
// экрана плюс сеть, той же логикой «код до первого двоеточия». Спек ARS-786 назвал ровно
// это условием снятия временной карты: «опровергло бы: ARS-691 выходит раньше сборки —
// тогда раздел берёт общий словарь, а карта удаляется, а не остаётся вторым домом (P4)».
// Условие наступило — карта удалена, дом один.

/** Отказ базы, разобранный для экрана: фраза человеку + сырой код, если он не опознан. */
export interface OfferActionFailure {
  text: string
  /** Непустой ТОЛЬКО для неопознанного кода — экран печатает его мелким. Опознанный код
   *  в теле сообщения не показывается: оператору он ничего не говорит. */
  rawCode: string | null
}

// Ответ пришёл, но разобрать его нечем. `LocalError` — собственный текст фронта: словарь
// пропускает его как есть, а не гонит через таблицу кодов (контракт `rpc-error-text`).
const UNREADABLE = 'Не удалось выполнить действие. Повторите или сообщите в поддержку.'

/** Отказ хода → то, что показать оператору. Тонкая обёртка над общим словарём зоны МПК:
 *  своей таблицы фраз у раздела нет. */
export function explainOfferFailure(raw: unknown): OfferActionFailure {
  const { text, code } = rpcErrorText(raw)
  return { text, rawCode: code }
}

/** Ошибка RPC → Error с сообщением базы; разбирает его словарь. Тот же приём, что в
 *  `pool-actions.ts`: сырой текст идёт в причину, а решение, что показать, принимает
 *  словарь, а не место броска. */
function fail(message: string | undefined): never {
  throw new Error(message && message.trim() ? message : UNREADABLE)
}

/** Принять оффер: партия уходит в заявку, которую выбрала база по наибольшему биду.
 *  `try/catch` не декоративен: `supabase.rpc` при обрыве сети не возвращает `error`, а
 *  БРОСАЕТ — без перехвата английский текст SDK ушёл бы оператору «кодом поддержки». */
export async function acceptOffer(offerId: string): Promise<AcceptedOffer> {
  let data: unknown
  try {
    const res = await supabase.rpc('rpc_self_accept_offer', { p_offer_id: offerId })
    if (res.error) fail(res.error.message)
    data = res.data
  } catch (e) {
    fail(e instanceof Error ? e.message : undefined)
  }
  // Успех без разбираемого ответа — не успех: экран обещает назвать заявку и ЦЕНУ, и
  // сказать это «на глаз» ему не из чего. Проверяем именно те два поля, которые печатаются:
  // без них вышло бы «цена сделки NaN ₸/кг» поверх реально состоявшегося принятия.
  const d = data as Partial<AcceptedOffer> | null
  if (!d || typeof d !== 'object' || !d.poolId || typeof d.dealPrice !== 'number'
      || !Number.isFinite(d.dealPrice)) {
    // Ответ без печатаемых полей — свой текст фронта, а не код базы.
    throw new LocalError(UNREADABLE)
  }
  return d as AcceptedOffer
}

/** Отклонить оффер: партия остаётся доступной другим комбинатам. */
export async function rejectOffer(offerId: string): Promise<void> {
  try {
    const { error } = await supabase.rpc('rpc_self_reject_offer', { p_offer_id: offerId })
    if (error) fail(error.message)
  } catch (e) {
    fail(e instanceof Error ? e.message : undefined)
  }
}
