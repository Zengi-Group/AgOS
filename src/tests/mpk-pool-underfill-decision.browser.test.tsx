// AgOS · ARS-695 · Выход из недобравшейся заявки — точка выбора комбината (браузерный тест).
// Предмет — Docs/AGOS-TSP-PoolDecision-Underfill-ARS-695.md, раздел `## I/O & Edge-Case Matrix`.
//
// ЧТО ЭТОТ ФАЙЛ ПОКРЫВАЕТ — только ту часть матрицы, которая живёт во ФРОНТЕ: что показано
// оператору и с какой RPC-обёрткой уходит его нажатие. Покрываемые id: M-001 (фронтовая
// половина — «принять частично» зовёт accept), M-002 (то же для возврата), M-003 (экран
// объясняет, что минимум не набран), M-009 (FORBIDDEN → тост, экран не меняется),
// M-010 (INVALID_STATUS → тост), M-013 (сеть не дошла — кнопки снова доступны), FR-010
// (недобор показан как «Нужно ваше решение», а не «Набрана»).
//
// ЧЕГО ЭТОТ ФАЙЛ НЕ ПОКРЫВАЕТ И ПОЧЕМУ — вся серверная половина матрицы: M-004..M-008,
// M-011, M-012, M-014 и серверные половины M-001/M-002/M-009/M-010. Это переходы FSM заявки,
// покрытие ОБОИХ маршрутов матча, реверс счётчиков, порог из tsp_config, блокировка строки
// при гонке и ленивое подметание — то есть поведение SQL на фикстурах БД, которое модалка
// наблюдать не может в принципе. Их дом — rollback-tx прогон на живой базе и qa/scenarios/
// 06-tsp-mpk.md (TSPM-CLOSE-02/03, TSPM-POOL-07) + 05/08 (TSPF-LIFE-11, E2E-TSP-04) через
// /qa-run. Утверждать «M-001 покрыт» по этому файлу нельзя: он проверяет, что нажатие зовёт
// нужную обёртку, а не что заявка после этого действительно закрылась.
//
// Компонент «чистый» — всё внешнее приходит пропсами; мок @/lib/supabase нужен только потому,
// что модалка безусловно зовёт useGradeFormula() (rpc_get_grade_formula). Диспетчер по имени
// с throw на незамоканном — чтобы опечатка в имени RPC была громкой (приём взят из
// mpk-pool-monitor.browser.test.tsx).
//
// @case TSPM-CLOSE-02 TSPM-CLOSE-03
//   (qa/scenarios/06-tsp-mpk.md. Тегов вида `M-NNN` здесь намеренно нет: M-001..M-014 —
//   идентификаторы СПЕКОВОЙ матрицы ARS-695, а не qa/scenarios/, и те же номера заняты
//   чужими слайсами — одинаковый тег дал бы qa/check_coverage.sh ложное «покрыто».)

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { PoolMonitorModal } from '@/pages/cabinet/shell/mpk/modals/PoolMonitorModal'
import type { Pool } from '@/pages/cabinet/shell/mpk/types'

vi.mock('@/lib/supabase', () => ({
  supabase: {
    rpc: async (fn: string) => {
      if (fn === 'rpc_get_grade_formula') return { data: null, error: null }
      throw new Error(`mpk-pool-underfill: незамоканный RPC ${fn}`)
    },
    from: (table: string) => {
      throw new Error(`mpk-pool-underfill: неожиданный supabase.from(${table})`)
    },
  },
}))

const REAL_POOL_ID = '11111111-1111-1111-1111-111111111111'
const T = { timeout: 15_000 }

// Живой случай из интента слайса: заявка 24/220 от 11.09, порог 10.
function makePool(overrides: Partial<Pool> = {}): Pool {
  return {
    id: REAL_POOL_ID,
    status: 'awaiting_decision',
    title: 'Высшая · Тестовый район',
    region: 'Тестовый район',
    totalHeads: 220,
    filledHeads: 24,
    targetMonth: 'этот месяц',
    lines: [{ catKey: 'vysshaya', price: 1700 }],
    createdAt: '11 сен',
    minPoolHeads: 10,
    ...overrides,
  }
}

type ModalProps = Parameters<typeof PoolMonitorModal>[0]

function baseProps(overrides: Partial<ModalProps> = {}): ModalProps {
  return {
    pool: makePool(),
    onClose: vi.fn(),
    onPatch: vi.fn(),
    toast: vi.fn(),
    onContactTuran: vi.fn(),
    ...overrides,
  }
}

let root: Root | null = null
let mountEl: HTMLElement | null = null

function mountModal(props: ModalProps) {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  root.render(
    <QueryClientProvider client={client}>
      <PoolMonitorModal {...props} />
    </QueryClientProvider>,
  )
}

beforeEach(async () => {
  await page.viewport(1440, 900)
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
})

// ── FR-010 · недобор ≠ «Набрана» ─────────────────────────────────────────────────────
it('ARS-695 FR-010: заявка, ждущая решения, показана отдельным состоянием с двумя ходами', async () => {
  mountModal(baseProps())

  await expect.element(page.getByText('Нужно ваше решение'), T).toBeInTheDocument()
  // Набрано/из скольких — оператор обязан видеть числа, а не только статус.
  expect(document.body.textContent).toContain('Набрано 24 из 220')
  expect(document.body.textContent).toContain('Принять частично (24 гол.)')
  expect(document.body.textContent).toContain('Вернуть партии')
  // Ровно два хода: старой кнопки «набрана» в этом состоянии быть не должно.
  expect(document.body.textContent).not.toContain('Заявка набрана')
})

// ── M-001 (фронтовая половина) ───────────────────────────────────────────────────────
it('ARS-695 M-001: «Принять частично» зовёт onAcceptPartial с id заявки и закрывает окно', async () => {
  const onAcceptPartial = vi.fn(async () => {})
  const onClose = vi.fn()
  const toast = vi.fn()
  mountModal(baseProps({ onAcceptPartial, onClose, toast }))

  await page.getByText('Принять частично (24 гол.)').click()

  await expect.poll(() => onAcceptPartial.mock.calls.length, T).toBe(1)
  expect(onAcceptPartial).toHaveBeenCalledWith(REAL_POOL_ID)
  await expect.poll(() => onClose.mock.calls.length, T).toBe(1)
})

// ── M-002 (фронтовая половина) ───────────────────────────────────────────────────────
it('ARS-695 M-002: «Вернуть партии» зовёт onReturnBatches, а не accept', async () => {
  const onAcceptPartial = vi.fn(async () => {})
  const onReturnBatches = vi.fn(async () => {})
  mountModal(baseProps({ onAcceptPartial, onReturnBatches }))

  await page.getByText('Вернуть партии').click()

  await expect.poll(() => onReturnBatches.mock.calls.length, T).toBe(1)
  expect(onReturnBatches).toHaveBeenCalledWith(REAL_POOL_ID)
  expect(onAcceptPartial).not.toHaveBeenCalled()
})

// ── M-013 · запрос не дошёл ──────────────────────────────────────────────────────────
it('ARS-695 M-013: решение не применилось — сказано об этом, кнопки снова доступны, окно открыто', async () => {
  const onAcceptPartial = vi.fn(async () => { throw new Error('сеть недоступна') })
  const onClose = vi.fn()
  const toast = vi.fn()
  mountModal(baseProps({ onAcceptPartial, onClose, toast }))

  await page.getByText('Принять частично (24 гол.)').click()

  await expect.poll(() => toast.mock.calls.length, T).toBe(1)
  expect(String(toast.mock.calls[0]![0])).toContain('Не удалось применить решение')
  // Окно НЕ закрыто: заявка осталась в точке выбора, оператор может повторить.
  expect(onClose).not.toHaveBeenCalled()
  // Кнопка вернулась из «Применяем…» в рабочее состояние — повтор безопасен.
  await expect.element(page.getByText('Принять частично (24 гол.)'), T).toBeInTheDocument()
})

// ── M-009 / M-010 · отказ бэкенда ────────────────────────────────────────────────────
it('ARS-695 M-009/M-010: FORBIDDEN и INVALID_STATUS доходят до оператора текстом, окно не закрывается', async () => {
  const onReturnBatches = vi.fn(async () => { throw new Error('INVALID_STATUS: pool must be awaiting_mpk_decision (current filling)') })
  const onClose = vi.fn()
  const toast = vi.fn()
  mountModal(baseProps({ onReturnBatches, onClose, toast }))

  await page.getByText('Вернуть партии').click()

  await expect.poll(() => toast.mock.calls.length, T).toBe(1)
  // ARS-691: INVALID_STATUS — ответ базы; на экране его фраза, сырого кода и хвоста нет.
  expect(toast.mock.calls[0]![0]).toBe('Не удалось применить решение: Статус уже изменился. Обновите экран и проверьте, что сейчас.')
  expect(String(toast.mock.calls[0]![0])).not.toContain('INVALID_STATUS')
  expect(onClose).not.toHaveBeenCalled()
})

// ── M-003 · ниже порога — экран объясняет, почему хода не было ───────────────────────
// Причина закрытия берётся из dbStatus, а НЕ из чисел: возврат обнуляет matched_heads
// (FR-004), поэтому filledHeads у недобравшей заявки такой же нулевой, как у пустой.
// Ветка «по числам» показывала бы оператору ложное «не набрано ни одной партии».
it('ARS-695 M-003: закрытая ниже порога объясняет минимум — при обнулённом счётчике', async () => {
  mountModal(baseProps({
    pool: makePool({ status: 'closed', dbStatus: 'closed_unfilled', filledHeads: 0, minPoolHeads: 10 }),
  }))

  await expect.element(page.getByText('Заявка закрыта'), T).toBeInTheDocument()
  expect(document.body.textContent).toContain('минимум для закупки — 10 гол.')
  expect(document.body.textContent).not.toContain('не набрано ни одной партии')
})

// ── M-004 (фронтовая половина) · пустая заявка ───────────────────────────────────────
it('ARS-695 M-004: закрытая заявка без единой партии говорит именно это, а не про минимум', async () => {
  mountModal(baseProps({
    pool: makePool({ status: 'closed', dbStatus: 'expired_empty', filledHeads: 0 }),
  }))

  await expect.element(page.getByText('Заявка закрыта'), T).toBeInTheDocument()
  expect(document.body.textContent).toContain('не набрано ни одной партии')
  expect(document.body.textContent).not.toContain('минимум для закупки')
})

// ── FR-002 · кнопка закрытия не утверждает исход ─────────────────────────────────────
it('ARS-695 FR-002: «Закрыть заявку» отдаёт исход базе — тост берётся из ответа, а не угадывается', async () => {
  const onClosePool = vi.fn(async () => 'awaiting_mpk_decision')
  const toast = vi.fn()
  mountModal(baseProps({ pool: makePool({ status: 'filling' }), onClosePool, toast }))

  await page.getByText('Закрыть заявку').click()

  await expect.poll(() => toast.mock.calls.length, T).toBe(1)
  expect(onClosePool).toHaveBeenCalledWith(REAL_POOL_ID)
  expect(String(toast.mock.calls[0]![0])).toContain('нужно ваше решение')
})

// Тот же путь, другой исход из базы: экран обязан назвать порог, а не «Заявка набрана».
it('ARS-695 FR-002/M-003: исход closed_unfilled из базы → тост называет минимум', async () => {
  const onClosePool = vi.fn(async () => 'closed_unfilled')
  const toast = vi.fn()
  mountModal(baseProps({ pool: makePool({ status: 'filling', filledHeads: 4 }), onClosePool, toast }))

  await page.getByText('Закрыть заявку').click()

  await expect.poll(() => toast.mock.calls.length, T).toBe(1)
  expect(String(toast.mock.calls[0]![0])).toContain('10 гол.')
  expect(String(toast.mock.calls[0]![0])).not.toContain('Заявка набрана')
})
