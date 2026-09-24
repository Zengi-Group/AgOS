// AgOS · ARS-691 · Отказы базы — словами оператора МПК.
//
// Один словарь зоны МПК (FR-001): каждая точка вывода отказа из таблицы P спека
// `Docs/AGOS-TSP-MpkErrorText-ARS-691.md` берёт текст отсюда, а не из `e.message`.
// Фраза выбирается по тексту кода до первого двоеточия, не по `errcode` (FR-002): один код
// несёт разные `errcode` в разных функциях (`BATCH_NOT_FOUND` = P0002/P0004/P0005).
// Технический хвост после двоеточия оператору не показывается никогда (FR-003).
//
// Разбор кода свой, а не `parseRpcCode` профиля: у той нет проверки вида, а профиль этот
// слайс не трогает (FR-011). Новый код в RPC закупочного флоу = новая строка в PHRASES;
// без неё он уйдёт в FALLBACK и будет виден оператору строкой «Код: …» (FR-004).

/** Собственный текст фронта (FR-013): показывается как есть, мимо словаря. */
export class LocalError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'LocalError'
  }
}

/** Таблица D. */
const PHRASES: Record<string, string> = {
  AUTH_REQUIRED: 'Сессия истекла. Войдите заново и повторите.',
  FORBIDDEN: 'У вашей учётной записи нет прав на это действие.',
  POOL_NOT_FOUND: 'Заявка не найдена — возможно, её уже отменили. Обновите экран.',
  REQUEST_NOT_FOUND: 'Заявка не найдена — возможно, её уже отменили. Обновите экран.',
  BATCH_NOT_FOUND: 'Партия не найдена — возможно, фермер её снял. Обновите экран.',
  OFFER_NOT_FOUND: 'Предложение не найдено. Обновите экран.',
  ALLOCATION_NOT_FOUND: 'Поставка не найдена. Обновите экран.',
  INVALID_STATUS: 'Статус уже изменился. Обновите экран и проверьте, что сейчас.',
  POOL_NOT_FILLING: 'Заявка больше не набирает партии — привязать к ней нельзя.',
  BATCH_NOT_AVAILABLE: 'Партия уже недоступна для привязки.',
  BATCH_FULLY_MATCHED: 'Все головы этой партии уже разобраны.',
  NO_MATCHING_LINE: 'В заявке нет строки под сорт и породу этой партии со свободным местом.',
  ALLOC_FAILED: 'В подходящей строке заявки не хватает места для этой партии.',
  BID_BELOW_ASK: 'Ваша цена ниже цены, которую назначил фермер.',
  OFFER_EXPIRED: 'Срок предложения истёк.',
  NO_MATCHING_POOL_LINE: 'Эта партия не подходит ни в одну вашу набирающую заявку: не совпадает сорт, порода, район, срок поставки, объём или цена. Проверьте свои заявки.',
  BATCH_NOT_IN_POOL: 'Эта партия не входит в вашу заявку.',
  REQUEST_NOT_DRAFT: 'Эта заявка уже запущена. Обновите список.',
  NO_DELIVERED_MPK_COUNTERPARTY: 'Отзыв можно оставить только после приёмки партии.',
  REVIEW_ALREADY_SUBMITTED: 'Отзыв по этой поставке уже отправлен.',
  REVIEW_IMMUTABLE_AFTER_REVEAL: 'Отзывы по этой сделке уже открыты сторонам — оценку изменить нельзя.',
}
const NETWORK = 'Нет связи с сервером. Проверьте интернет и повторите.'
const FALLBACK = 'Не удалось выполнить действие. Повторите или сообщите в поддержку.'

const CODE_RE = /^[A-Z][A-Z0-9_]*$/
// supabase-js при недошедшем запросе отдаёт `TypeError: <текст fetch>`: Chrome — «Failed to
// fetch», Firefox — «NetworkError when attempting…», Safari — «Load failed» (FR-005).
const NETWORK_RE = /failed to fetch|networkerror|load failed/i

/** Отказ → текст для оператора. `code` — только для строки «Код: …» (FR-004), иначе null. */
export function rpcErrorText(raw: unknown): { text: string; code: string | null } {
  const message = raw instanceof Error ? raw.message : ''
  // FR-006: разработчику — полный исходный текст, оператору — фраза.
  console.error('МПК · отказ:', raw instanceof Error ? raw.message : raw)
  if (raw instanceof LocalError) return { text: message, code: null }
  const i = message.indexOf(':')
  const head = (i === -1 ? message : message.slice(0, i)).trim()
  if (CODE_RE.test(head)) {
    const phrase = PHRASES[head]
    return phrase ? { text: phrase, code: null } : { text: FALLBACK, code: head }
  }
  if (NETWORK_RE.test(message)) return { text: NETWORK, code: null }
  return { text: FALLBACK, code: null }
}
