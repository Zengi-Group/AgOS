// AgOS · ARS-785 · Чистые функции раздела «Входящие офферы» десктопной консоли.
//
// Здесь нет React и нет сети — ровно чтобы каждое число на карточке можно было закрепить
// тестом отдельно от экрана. Все значения выводятся из полей ответа
// `rpc_get_incoming_offers` (`cat`/`breed`/`region`/`heads`/`avgWeight`/`offeredPrice`/
// `expiresAtIso`); ни одной константы «на глаз».

import type { IncomingOffer } from '../types'

// Человекочитаемое имя категории. RPC отдаёт код (`cat`), а не витринный текст, поэтому
// отображение живёт на клиенте — как и в мобильном экране офферов.
const CAT_RU: Record<string, string> = {
  bychki: 'Бычки',
  telki: 'Тёлки',
  korovy: 'Коровы',
  molodnyak: 'Молодняк',
}

/** Категория + порода одной строкой. Порода может отсутствовать — тогда её нет в подписи,
 *  а не пустой хвост « · ». */
export function offerTitle(o: IncomingOffer): string {
  const base = CAT_RU[o.cat] ?? 'Партия КРС'
  return o.breed ? `${base} · ${o.breed}` : base
}

/** Тоннаж живого веса: головы × средний вес. Производная величина — RPC её не отдаёт
 *  (проверено по телу `rpc_get_incoming_offers`), поэтому считается здесь, как и в
 *  мобильной карточке. Один знак после запятой.
 *
 *  `null`, когда среднего веса нет: `batches.avg_weight_kg` — nullable
 *  (`d02_tsp.sql:231`, `check (avg_weight_kg > 0)` без NOT NULL), а `rpc_get_incoming_offers`
 *  отдаёт его без `coalesce`, в отличие от `breed`/`region`. Фермер заполняет партию
 *  постепенно (`P11`), поэтому «веса ещё нет» — штатное состояние, и показать его нулём
 *  значило бы соврать про партию: 0 т — это утверждение о весе, а не его отсутствие. */
export function offerTonnes(o: IncomingOffer): number | null {
  if (!o.avgWeight) return null
  return Math.round((o.heads * o.avgWeight) / 100) / 10
}

/** Часов до конца окна ответа (FCFS, 24 ч). Ноль — окно истекает: отрицательных «часов
 *  осталось» на экране не бывает. `now` параметром, чтобы тест не зависел от таймера.
 *  Не экспортируется: наружу модуля нужна подпись (`deadlineLabel`), а не число — лишний
 *  export был бы поверхностью, которой никто не пользуется. */
function hoursLeft(expiresAt: Date, now: number = Date.now()): number {
  const ms = expiresAt.getTime() - now
  return ms > 0 ? Math.ceil(ms / 3_600_000) : 0
}

/** Подпись срока ответа — та же формулировка, что в мобильной карточке: факт, без
 *  побуждения торопиться (ст. 171). */
export function deadlineLabel(o: IncomingOffer, now: number = Date.now()): string {
  const left = hoursLeft(o.expiresAt, now)
  return left > 0 ? `Осталось ответить: ~${left} ч` : 'Окно ответа истекает'
}

/** Сортировка по сроку ответа: первым — тот, по которому окно закроется раньше. Порядок
 *  задаёт ЭКРАН, а не порядок строк чужого RPC (тот же довод — в `readIncomingOffers`).
 *  Возвращает новый массив: вход не мутируется. */
export function sortByDeadline(offers: IncomingOffer[]): IncomingOffer[] {
  return [...offers].sort((a, b) => a.expiresAt.getTime() - b.expiresAt.getTime())
}
