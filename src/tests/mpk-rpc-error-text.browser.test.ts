// AgOS · ARS-691 · Словарь отказов зоны МПК — `rpcErrorText`.
//
// Спек: `Docs/AGOS-TSP-MpkErrorText-ARS-691.md`, раздел `## I/O & Edge-Case Matrix`.
// Один тест = одна строка матрицы, id в названии. Строки, которые видны только на экране
// (M-006, M-013, M-016, M-017), проверяются браузерными тестами монитора, консоли и
// `mpk-error-text-ui`; здесь — сам выбор фразы.
// Запуск: npm run test:routers.

import { afterEach, beforeEach, expect, it, vi, type MockInstance } from 'vitest'
import { LocalError, rpcErrorText } from '@/pages/cabinet/shell/mpk/data/rpc-error-text'

let consoleError: MockInstance<typeof console.error>

beforeEach(() => {
  consoleError = vi.spyOn(console, 'error').mockImplementation(() => {})
})
afterEach(() => {
  consoleError.mockRestore()
})

const FALLBACK = 'Не удалось выполнить действие. Повторите или сообщите в поддержку.'

it('ARS-691 M-001: BATCH_FULLY_MATCHED — фраза про разобранные головы, строки кода нет', () => {
  expect(rpcErrorText(new Error('BATCH_FULLY_MATCHED'))).toEqual({
    text: 'Все головы этой партии уже разобраны.', code: null,
  })
})

it('ARS-691 M-002: ALLOC_FAILED с хвостом — фраза про место, «кусок» и «ask» не показаны', () => {
  const r = rpcErrorText(new Error('ALLOC_FAILED: строка не смогла принять кусок (нет места / цена < ask)'))
  expect(r).toEqual({ text: 'В подходящей строке заявки не хватает места для этой партии.', code: null })
  expect(r.text).not.toContain('кусок')
  expect(r.text).not.toContain('ask')
})

it('ARS-691 M-003: латинский сорт в хвосте не показан, полный текст — в консоли', () => {
  const raw = 'NO_MATCHING_LINE: no line for grade vysshaya / breed angus with free capacity'
  const r = rpcErrorText(new Error(raw))
  expect(r).toEqual({ text: 'В заявке нет строки под сорт и породу этой партии со свободным местом.', code: null })
  expect(r.text).not.toContain('vysshaya')
  expect(consoleError.mock.calls.some((c) => c.some((a) => String(a).includes(raw)))).toBe(true)
})

it('ARS-691 M-004: FORBIDDEN с техническим хвостом — фраза без хвоста', () => {
  const r = rpcErrorText(new Error('FORBIDDEN: pool not owned by current user'))
  expect(r).toEqual({ text: 'У вашей учётной записи нет прав на это действие.', code: null })
  expect(r.text).not.toContain('pool not owned')
})

it('ARS-691 M-005: INVALID_STATUS — фраза «Статус уже изменился»', () => {
  expect(rpcErrorText(new Error('INVALID_STATUS: pool must be awaiting_mpk_decision (current closed_partial)'))).toEqual({
    text: 'Статус уже изменился. Обновите экран и проверьте, что сейчас.', code: null,
  })
})

it('ARS-691 M-007: незнакомый код — общая фраза и код без хвоста', () => {
  const r = rpcErrorText(new Error('UNKNOWN_DIMENSION: livestock_condition'))
  expect(r).toEqual({ text: FALLBACK, code: 'UNKNOWN_DIMENSION' })
  expect(r.text).not.toContain('livestock_condition')
})

it('ARS-691 M-008: сообщение без кода (нарушение CHECK) — общая фраза без кода, полный текст в консоли', () => {
  const raw = 'new row for relation "pools" violates check constraint "pools_status_check"'
  expect(rpcErrorText(new Error(raw))).toEqual({ text: FALLBACK, code: null })
  expect(consoleError.mock.calls.some((c) => c.some((a) => String(a).includes(raw)))).toBe(true)
})

it('ARS-691 M-009: запрос не дошёл (supabase-js: TypeError: Failed to fetch) — фраза про связь, кода нет', () => {
  const NETWORK = { text: 'Нет связи с сервером. Проверьте интернет и повторите.', code: null }
  expect(rpcErrorText(new Error('TypeError: Failed to fetch'))).toEqual(NETWORK)
  expect(rpcErrorText(new Error('TypeError: NetworkError when attempting to fetch resource.'))).toEqual(NETWORK)
  expect(rpcErrorText(new Error('TypeError: Load failed'))).toEqual(NETWORK)
})

it('ARS-691 M-010: пустое сообщение базы — общая фраза без кода', () => {
  expect(rpcErrorText(new Error(''))).toEqual({ text: FALLBACK, code: null })
})

it('ARS-691 M-011: FORBIDDEN при заведении заявки — фраза прав без хвоста', () => {
  const r = rpcErrorText(new Error('FORBIDDEN: organization not owned by current user'))
  expect('Заявка не заведена: ' + r.text).toBe('Заявка не заведена: У вашей учётной записи нет прав на это действие.')
  expect(r.code).toBeNull()
})

it('ARS-691 M-012: AUTH_REQUIRED — фраза про истёкшую сессию', () => {
  expect(rpcErrorText(new Error('AUTH_REQUIRED'))).toEqual({
    text: 'Сессия истекла. Войдите заново и повторите.', code: null,
  })
})

it('ARS-691 M-014: собственный текст фронта (LocalError) показан как есть, без кода', () => {
  const own = 'Заявка создана, но не опубликована (нет pool_id)'
  expect(rpcErrorText(new LocalError(own))).toEqual({ text: own, code: null })
})

it('ARS-691 M-015: повторная оценка — фраза «Отзыв уже отправлен»', () => {
  expect(rpcErrorText(new Error('REVIEW_ALREADY_SUBMITTED: review for this allocation exists'))).toEqual({
    text: 'Отзыв по этой поставке уже отправлен.', code: null,
  })
})

// ARS-754 FR-005: ручная привязка отказывает, когда партия не влезает целиком — фраза
// называет причину словами, без чисел и без технического хвоста RPC (code остаётся null).
it('FR-005 BATCH_DOES_NOT_FIT: партия продаётся только целиком — фраза без цифр и без хвоста, code = null', () => {
  const raw = 'BATCH_DOES_NOT_FIT: batch heads=23 exceed remaining capacity=9 in pool_line abc123'
  const r = rpcErrorText(new Error(raw))
  expect(r).toEqual({
    text: 'Партия продаётся только целиком — в заявке не хватает места для всех её голов.', code: null,
  })
  expect(r.code, 'технический хвост не должен утечь в code').toBeNull()
  expect(r.text, 'фраза не должна содержать цифр из технического хвоста').not.toMatch(/\d/)
})
