// AgOS · Slice11 (ARS-718) · Модель раздела «Мои заявки»: раскладка по вкладкам.
//
// Здесь закрывается ТОЛЬКО `FR-004` — строки матрицы живут в
// `mpk-requests-desktop.browser.test.tsx`, чтобы у каждой был один дом (P4).
//
// Браузерный проект — единственный, который в этом репозитории вообще запускает тесты из
// `src/tests/` (`vite.config.ts`, проект `routers`). Тест без DOM, но незапускаемый тест
// не считается покрытием.

import { expect, it } from 'vitest'
import type { Pool } from '@/pages/cabinet/shell/mpk/types'
import {
  avgLinePrice, bucketOf, isAvgPrice, statusLabel, tabCounts,
} from '@/pages/cabinet/shell/mpk/requests/requests-model'

const pool = (dbStatus: string): Pool => ({
  id: `p-${dbStatus}`,
  status: 'filling',
  title: 'Заявка',
  region: 'Алматинская обл.',
  totalHeads: 100,
  filledHeads: 10,
  targetMonth: 'октябрь 2026',
  lines: [{ catKey: 'vysshaya', price: 1700 }],
  createdAt: '1 сент',
  dbStatus,
})

// Перечень взят из `pools_status_check` (`d02_tsp.sql`): 10 канонических M4 + 5 легаси.
// Если CHECK расширят, а раскладку — нет, этот тест не упадёт: он проверяет, что каждое
// ИЗВЕСТНОЕ значение разложено осознанно. Ловушку «новый статус молча уехал в
// „Не состоялись“» держит строка ниже про неназванный статус — она фиксирует, что
// catch-all существует и ведёт себя объявленно.
const EXPECTED: [string, ReturnType<typeof bucketOf>][] = [
  ['draft', 'filling'],
  ['filling', 'filling'],
  ['awaiting_mpk_decision', 'decision'],
  ['closed_filled', 'shipping'],
  ['closed_partial', 'shipping'],
  ['executing', 'shipping'],
  ['filled', 'shipping'],
  ['dispatched', 'shipping'],
  ['delivered', 'shipping'],
  ['completed', 'done'],
  ['executed', 'done'],
  ['closed_unfilled', 'failed'],
  ['expired_empty', 'failed'],
  ['cancelled', 'failed'],
  ['closed', 'failed'],
]

it('FR-004: каждое значение pools_status_check разложено по вкладкам явно', () => {
  for (const [status, bucket] of EXPECTED) {
    expect(bucketOf(pool(status)), `статус ${status}`).toBe(bucket)
  }
  // Легаси-шестёрка названа поимённо, а не «по смыслу»: `filled`/`dispatched`/`delivered`
  // — это набранная и отгружаемая заявка, а не несостоявшаяся (правка FR-004 от 18.09).
  expect(bucketOf(pool('filled'))).toBe('shipping')
  expect(bucketOf(pool('dispatched'))).toBe('shipping')
  expect(bucketOf(pool('delivered'))).toBe('shipping')
})

it('FR-004: статус вне перечня уходит в «Не состоялись» и не теряется из «Все»', () => {
  const unknown = pool('какой-то_новый_статус')
  expect(bucketOf(unknown)).toBe('failed')
  const counts = tabCounts([unknown])
  expect(counts.all).toBe(1)
  expect(counts.failed).toBe(1)
})

it('FR-003: сумма счётчиков пяти вкладок равна числу заявок — заявка ровно в одной', () => {
  const pools = EXPECTED.map(([status]) => pool(status))
  const c = tabCounts(pools)
  expect(c.filling + c.decision + c.shipping + c.done + c.failed).toBe(pools.length)
  expect(c.all).toBe(pools.length)
})

it('FR-004: у каждого статуса есть русская подпись чипа, а не сырое значение из базы', () => {
  // Раскладка по вкладкам и ПОДПИСЬ — разные утверждения: без этой строки удаление любой
  // записи `STATUS_LABEL` прошло бы зелёным, а оператор увидел бы английское `dispatched`.
  for (const [status] of EXPECTED) {
    const label = statusLabel(pool(status)).label
    expect(label, `статус ${status}`).not.toBe(status)
    expect(/[а-яё]/i.test(label), `подпись «${label}» не по-русски`).toBe(true)
  }
  // Неназванный статус подписи не выдумывает — показывает сырое значение, а не чужую.
  expect(statusLabel(pool('новый_статус')).label).toBe('новый_статус')
})

it('FR-005: цена строки — средняя по строкам заявки, с подписью только у многострочной', () => {
  const one = { ...pool('filling'), lines: [{ catKey: 'vysshaya' as const, price: 1700 }] }
  expect(avgLinePrice(one)).toBe(1700)
  expect(isAvgPrice(one)).toBe(false)

  const two = {
    ...pool('filling'),
    lines: [{ catKey: 'vysshaya' as const, price: 1700 }, { catKey: 'pervaya' as const, price: 1500 }],
  }
  expect(avgLinePrice(two), 'среднее, а не сумма').toBe(1600)
  expect(isAvgPrice(two)).toBe(true)

  // Заявка без строк не делит на ноль и не печатает NaN.
  expect(avgLinePrice({ ...pool('filling'), lines: [] })).toBe(0)
})
