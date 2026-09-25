// AgOS · ARS-831 · «Средняя закупочная» — модельный тест функции `purchaseAvgPrice`.
//
// Предмет — Docs/AGOS-TSP-MpkPurchaseAvgPrice-ARS-831.md, `## I/O & Edge-Case Matrix`.
// Здесь — строки, которые решает сама формула (число, `basis`, `kind`): M-001…M-004, M-012.
// Экранные строки — `ars-831-purchase-avg.browser.test.tsx`.
// Браузерный проект — единственный, что запускает `src/tests/` (`vite.config.ts`, `routers`).

import { expect, it } from 'vitest'
import type { SupplierRow } from '@/pages/cabinet/shell/mpk/types'
import {
  purchaseAvgPrice, purchaseAvgText, supplierPriceText,
} from '@/pages/cabinet/shell/mpk/requests/requests-model'

const row = (heads: number, price: number, avgWeight?: number): SupplierRow => ({
  id: `s-${heads}-${price}`, heads, price, avgWeight, deliveryStatus: 'awaiting_dispatch',
})
const plain = (s: string) => s.replace(/ /g, ' ')

it('ARS-831 M-001: пример владельца — 80 × 2 000 и 20 × 2 100 по 400 кг → 2 020 по кг', () => {
  const r = purchaseAvgPrice([row(80, 2000, 400), row(20, 2100, 400)])
  expect(r).toEqual({ kind: 'value', value: 2020, basis: 'kg' })
  expect(plain(purchaseAvgText(r))).toBe('2 020 ₸/кг')
})

it('ARS-831 M-002: разный вес — деньги ÷ килограммы дают 2 029, а не 2 020 по головам', () => {
  const r = purchaseAvgPrice([row(80, 2000, 300), row(20, 2100, 500)])
  expect(r).toEqual({ kind: 'value', value: 2029, basis: 'kg' })
})

it('ARS-831 FR-002: округление до целого тенге — к ближайшему, а не отбрасыванием', () => {
  // 2 000,5 и 2 000,75: отбрасывание дробной части (floor/trunc) дало бы 2 000.
  expect(purchaseAvgPrice([row(1, 2001, 400), row(1, 2000, 400)])).toEqual({ kind: 'value', value: 2001, basis: 'kg' })
  expect(purchaseAvgPrice([row(3, 2001, 400), row(1, 2000, 400)])).toEqual({ kind: 'value', value: 2001, basis: 'kg' })
})

it('ARS-831 M-003: у строки нет веса — ВСЁ число по головам и подписано «по головам»', () => {
  const r = purchaseAvgPrice([row(80, 2000, 400), row(20, 2100)])
  expect(r).toEqual({ kind: 'value', value: 2020, basis: 'heads' })
  expect(plain(purchaseAvgText(r))).toBe('2 020 ₸/кг · по головам')
})

it('ARS-831 M-004: одна строка — её цена, без подписи «по головам»', () => {
  const r = purchaseAvgPrice([row(24, 1950, 400)])
  expect(r).toEqual({ kind: 'value', value: 1950, basis: 'kg' })
  expect(plain(purchaseAvgText(r))).toBe('1 950 ₸/кг')
})

it('ARS-831 M-012: у поставщика нет цены — числа нет, в строке «—», нигде не 0', () => {
  // «Нет цены» приходит из базы как null под типом number (Design contract спека).
  const noPrice = { ...row(20, 0, 400), price: null as unknown as number }
  const r = purchaseAvgPrice([row(80, 2000, 400), noPrice])
  expect(r).toEqual({ kind: 'no_price' })
  expect(purchaseAvgText(r)).toBe('нельзя посчитать: у поставщика нет цены')
  expect(supplierPriceText(noPrice)).toBe('—')
  expect(plain(supplierPriceText(row(80, 2000, 400)))).toBe('2 000 ₸/кг')
})
