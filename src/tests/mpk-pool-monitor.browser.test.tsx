// AgOS · ARS-684 · Монитор пула МПК — двухмаршрутная read-model (браузерный тест).
// До этого файла машинного покрытия PoolMonitorModal.tsx не было вовсе: и до, и после
// правок ARS-684 `npm run test:routers` даёт ровно 101/101 — ни один существующий тест не
// наблюдает изменённое поведение. Предмет — Docs/AGOS-TSP-PoolMonitor-ReadModel-ARS-684.md,
// раздел `## I/O & Edge-Case Matrix`.
//
// Покрывает id матрицы ARS-684: M-005, M-006, M-007, M-008, M-010, M-011, M-012, M-013
// (два отдельных `it` — сбой ПОСЛЕ успешного чтения и сбой ПЕРВЫМ ответом, матрица требует
// оба утверждения отдельно), M-015, M-016, M-017, M-018.
//
// НЕ покрывает этот файл — id матрицы M-001, M-002, M-003, M-004, M-009, M-014: это форма
// ОТВЕТА rpc_get_pool_matches на конкретных фикстурах БД (какие строки/поля отдаёт SQL), а
// не поведение модалки над уже полученными строками. Их дом —
// tests/ars_684_pool_monitor_dual_route_test.sql (см. §Verification в спеке).
//
// Также НЕ покрывает: саму маршрутизацию «имя RPC → параметр» (rpc_self_confirm_delivery vs
// rpc_self_confirm_delivery_alloc по признаку source) — она живёт в MpkApp.confirmDelivery, а
// не в PoolMonitorModal. Тест копии этой развилки проверял бы копию, а не код — поэтому здесь
// утверждается только то, с какими АРГУМЕНТАМИ модалка зовёт onConfirmDelivery (id/batchId +
// source), а не какую именно RPC-функцию выберет MpkApp по этому source.
//
// Компонент «чистый» — всё внешнее приходит пропсами (см. `interface Props` в
// PoolMonitorModal.tsx). Мок @/lib/supabase нужен всё равно: компонент безусловно вызывает
// useGradeFormula() (useRpc → supabase.rpc('rpc_get_grade_formula')), поэтому нужен и
// QueryClientProvider, и диспетчер по имени RPC с throw на незамоканном (приём
// mpk-profile-states.browser.test.tsx) — мок, отвечающий одинаково на любое имя, пропустил бы
// опечатку в имени RPC. Второй сетевой потребитель компонента — useRevealedBatch
// (supabase.from(...) внутри RevealedBatchDetail) — в этих сценариях не срабатывает: чтение
// ленивое (enabled = секция «Фото и детализация» раскрыта кликом), и ни один сценарий этого
// файла её не раскрывает, поэтому .from() здесь настроен бросать — неожиданный вызов будет
// громким, а не тихим.
//
// @case TSPM-CLOSE-04 TSPM-CLOSE-05
//   (qa/scenarios/06-tsp-mpk.md — «приёмка поставок» и «отзыв МПК о фермере»: единственные
//   существующие идентификаторы сценариев для предмета этого файла. Тегов вида `M-NNN` здесь
//   намеренно нет: M-005..M-018 — идентификаторы СПЕКОВОЙ матрицы ARS-684, а не qa/scenarios/,
//   и часть из них (M-007/M-008/M-018) уже занята ЧУЖИМ слайсом
//   (mpk-profile-org-section.browser.test.tsx, профиль МПК) — одинаковый id-тег в двух файлах
//   дал бы qa/check_coverage.sh ложное «покрыто» на чужом кейсе.)

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { PoolMonitorModal } from '@/pages/cabinet/shell/mpk/modals/PoolMonitorModal'
import type { Pool, SupplierRow } from '@/pages/cabinet/shell/mpk/types'

// Единственный реальный сетевой вызов в этих сценариях — rpc_get_grade_formula (useGradeFormula,
// безусловно на каждом монтировании). Диспетчер по имени, throw на незамоканном.
vi.mock('@/lib/supabase', () => ({
  supabase: {
    rpc: async (fn: string) => {
      if (fn === 'rpc_get_grade_formula') return { data: null, error: null }
      throw new Error(`mpk-pool-monitor: незамоканный RPC ${fn}`)
    },
    from: (table: string) => {
      throw new Error(
        `mpk-pool-monitor: неожиданный supabase.from(${table}) — ни один сценарий этого файла не раскрывает "Фото и детализация"`,
      )
    },
  },
}))

const REAL_POOL_ID = '11111111-1111-1111-1111-111111111111'
const DEMO_POOL_ID = 'demo-pool-1'

function makePool(overrides: Partial<Pool> = {}): Pool {
  return {
    id: REAL_POOL_ID,
    status: 'filled',
    title: 'Высшая · Тестовый район',
    region: 'Тестовый район',
    totalHeads: 100,
    filledHeads: 100,
    targetMonth: 'этот месяц',
    lines: [{ catKey: 'vysshaya', price: 1700 }],
    createdAt: '1 сен',
    ...overrides,
  }
}

function makeSupplier(overrides: Partial<SupplierRow> = {}): SupplierRow {
  return {
    id: 's1',
    heads: 20,
    price: 1700,
    deliveryStatus: 'in_transit',
    farmName: 'КХ Тест',
    district: 'Тестовый район',
    batchId: 'batch-1',
    source: 'allocation',
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

// Звёздные кнопки StarPicker (★) неотличимы друг от друга по имени/роли — единственный
// стабильный признак n-й звезды — позиция в DOM-порядке (StarPicker рисует [1,2,3,4,5] по
// порядку). Скоуп через `.supplier-row` — в тестах этого файла на экране всегда одна строка.
function starButtons(): HTMLButtonElement[] {
  return Array.from(document.querySelectorAll('.supplier-row button')).filter(
    (b) => b.textContent?.trim() === '★',
  ) as HTMLButtonElement[]
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

const T = { timeout: 15_000 }

// ── M-005 · пусто ──────────────────────────────────────────────────────────────────────
it('ARS-684 M-005: реальный пул, onLoadMatches вернул [] — видна подпись «Поставщиков пока нет»', async () => {
  const onLoadMatches = vi.fn(async () => [] as SupplierRow[])
  mountModal(baseProps({ pool: makePool({ status: 'filled' }), onLoadMatches }))

  await expect.element(page.getByText('Поставщиков пока нет'), T).toBeInTheDocument()
  expect(onLoadMatches).toHaveBeenCalledWith(REAL_POOL_ID)
})

// ── M-006 · приёмка партии целиком (маршрут batch) ───────────────────────────────────
it('ARS-684 M-006: строка source=batch, «в пути» — приёмка зовёт onConfirmDelivery(batchId,"batch"), список перечитывается', async () => {
  const row = makeSupplier({
    id: 'm-1', source: 'batch', batchId: 'batch-XYZ', deliveryStatus: 'in_transit', farmName: 'КХ Партия',
  })
  const onLoadMatches = vi.fn(async () => [row])
  const onConfirmDelivery = vi.fn(async () => {})
  mountModal(baseProps({ pool: makePool({ status: 'executing' }), onLoadMatches, onConfirmDelivery }))

  await expect.element(page.getByText('КХ Партия'), T).toBeInTheDocument()
  await page.getByText('Подтвердить приёмку').click()

  await expect.poll(() => onConfirmDelivery.mock.calls.length, T).toBe(1)
  expect(onConfirmDelivery).toHaveBeenCalledWith('batch-XYZ', 'batch')
  // Список перечитан после успешной приёмки (FR-005): второй вызов onLoadMatches.
  await expect.poll(() => onLoadMatches.mock.calls.length, T).toBeGreaterThanOrEqual(2)
})

// ── M-007 · приёмка куска (маршрут allocation) ───────────────────────────────────────
it('ARS-684 M-007: строка source=allocation, «в пути» — приёмка зовёт onConfirmDelivery(id,"allocation"), НЕ batchId', async () => {
  const row = makeSupplier({
    id: 'alloc-1', source: 'allocation', batchId: 'batch-SHOULD-NOT-BE-USED',
    deliveryStatus: 'in_transit', farmName: 'КХ Кусок',
  })
  const onLoadMatches = vi.fn(async () => [row])
  const onConfirmDelivery = vi.fn(async () => {})
  mountModal(baseProps({ pool: makePool({ status: 'executing' }), onLoadMatches, onConfirmDelivery }))

  await expect.element(page.getByText('КХ Кусок'), T).toBeInTheDocument()
  await page.getByText('Подтвердить приёмку').click()

  await expect.poll(() => onConfirmDelivery.mock.calls.length, T).toBe(1)
  expect(onConfirmDelivery).toHaveBeenCalledWith('alloc-1', 'allocation')
})

// ── M-008 · не в статусе приёмки ──────────────────────────────────────────────────────
it('ARS-684 M-008: строка «ожидает отгрузки» — кнопки приёмки на строке нет', async () => {
  const row = makeSupplier({ deliveryStatus: 'awaiting_dispatch', farmName: 'КХ Ожидание' })
  const onLoadMatches = vi.fn(async () => [row])
  mountModal(baseProps({ pool: makePool({ status: 'executing' }), onLoadMatches }))

  await expect.element(page.getByText('Ожидает отгрузки'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Подтвердить приёмку')
})

// ── M-010 · отзыв достижим сразу после приёмки партии ────────────────────────────────
it('ARS-684 M-010: партия «принята» — звезда есть, клик вызывает onSubmitReview(batchId,n)', async () => {
  const row = makeSupplier({
    id: 's-rated', source: 'batch', batchId: 'batch-777', deliveryStatus: 'delivered', farmName: 'КХ Принята',
  })
  const onLoadMatches = vi.fn(async () => [row])
  const onSubmitReview = vi.fn(async () => {})
  mountModal(baseProps({ pool: makePool({ status: 'executing' }), onLoadMatches, onSubmitReview }))

  await expect.element(page.getByText('КХ Принята'), T).toBeInTheDocument()
  await expect.poll(() => starButtons().length, T).toBe(5)
  starButtons()[3]!.click() // 4-я звезда слева = оценка 4

  await expect.poll(() => onSubmitReview.mock.calls.length, T).toBe(1)
  expect(onSubmitReview).toHaveBeenCalledWith('batch-777', 4)
})

// ── FR-003 · телефон хозяйства В СТРОКЕ ───────────────────────────────────────────────
// Находка converge #20: RPC телефон отдавал, а строка его не печатала — он попадал только в
// печатный документ сделки. Половина смысла слайса — «узнать, у кого купил, и позвонить»,
// и именно эту асимметрию FR-003 называет как причину (у фермера телефон покупателя в строке
// есть). Гейт раскрытия живёт в базе: до раскрытия приходит null (M-004), и печатать нечего.
it('ARS-684 FR-003: после раскрытия телефон хозяйства виден в строке; без телефона строка не ломается', async () => {
  const withPhone = makeSupplier({
    id: 's-phone', source: 'batch', batchId: 'batch-phone',
    farmName: 'КХ СТелефоном', farmPhone: '+7 701 000 11 22',
  })
  const anonymous = makeSupplier({ id: 's-anon', source: 'batch', batchId: 'batch-anon', farmName: undefined })
  const onLoadMatches = vi.fn(async () => [withPhone, anonymous])
  mountModal(baseProps({ pool: makePool({ status: 'filled' }), onLoadMatches }))

  await expect.element(page.getByText('КХ СТелефоном'), T).toBeInTheDocument()
  // Телефон печатается и остаётся кликабельным (tel:) — оператор звонит из монитора.
  const phone = page.getByRole('link', { name: '+7 701 000 11 22' })
  await expect.element(phone, T).toBeInTheDocument()
  await expect.element(phone, T).toHaveAttribute('href', 'tel:+7 701 000 11 22')
  // Строка без телефона (до раскрытия контактов) рисуется без него и не падает.
  await expect.element(page.getByText('Хозяйство'), T).toBeInTheDocument()
})

// ── M-011 · отзыв рано ────────────────────────────────────────────────────────────────
it('ARS-684 M-011: партия не «принята» — звёздной формы на строке нет', async () => {
  const row = makeSupplier({ source: 'batch', deliveryStatus: 'in_transit', farmName: 'КХ НеПринята' })
  const onLoadMatches = vi.fn(async () => [row])
  mountModal(baseProps({ pool: makePool({ status: 'executing' }), onLoadMatches }))

  await expect.element(page.getByText('КХ НеПринята'), T).toBeInTheDocument()
  expect(starButtons()).toHaveLength(0)
})

// ── M-012 · демо-пул ──────────────────────────────────────────────────────────────────
it('ARS-684 M-012: демо-пул (id не UUID), ветка набора — демо-элементы доступны', async () => {
  mountModal(baseProps({ pool: makePool({ id: DEMO_POOL_ID, status: 'filling' }) }))

  await expect.element(page.getByText('+ Добавить поставщика'), T).toBeInTheDocument()
  await expect.element(page.getByText('Истёк срок'), T).toBeInTheDocument()
})

// ── M-013 · сбой чтения ≠ пустой пул (матрица требует оба утверждения отдельно) ─────
it('ARS-684 M-013: сбой чтения ПОСЛЕ успешного — список остаётся, «не удалось обновить», без «поставщиков пока нет»', async () => {
  let call = 0
  const row = makeSupplier({ id: 's-keep', source: 'allocation', deliveryStatus: 'in_transit', farmName: 'КХ Стабильный' })
  const onLoadMatches = vi.fn(async () => { call += 1; return call === 1 ? [row] : null })
  const onConfirmDelivery = vi.fn(async () => {})
  mountModal(baseProps({ pool: makePool({ status: 'filled' }), onLoadMatches, onConfirmDelivery }))

  await expect.element(page.getByText('КХ Стабильный'), T).toBeInTheDocument()
  // Успешная приёмка запускает reloadMatches (FR-005) — это и есть «очередной опрос»,
  // который в этом сценарии отвечает null.
  await page.getByText('Подтвердить приёмку').click()

  await expect.element(page.getByText('Не удалось обновить список'), T).toBeInTheDocument()
  expect(document.body.textContent).toContain('КХ Стабильный')
  expect(document.body.textContent).not.toContain('Поставщиков пока нет')
})

it('ARS-684 M-013: null пришёл ПЕРВЫМ ответом — «поставщиков пока нет» тоже не показывается', async () => {
  const onLoadMatches = vi.fn(async () => null)
  mountModal(baseProps({ pool: makePool({ status: 'filled' }), onLoadMatches }))

  await expect.element(page.getByText('Не удалось обновить список'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Поставщиков пока нет')
})

// ── M-015 · реальный пул без демо-элементов ──────────────────────────────────────────
it('ARS-684 M-015: реальный пул (UUID), ветка набора — демо-элементов нет вовсе', async () => {
  mountModal(baseProps({ pool: makePool({ status: 'filling' }) }))

  await expect.element(page.getByText('Все набраны'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('+ Добавить поставщика')
  expect(document.body.textContent).not.toContain('Истёк срок')
})

// ── M-016 · первая загрузка ───────────────────────────────────────────────────────────
it('ARS-684 M-016: первая загрузка — видно «Загрузка…», демо-строки pool.suppliers не подставляются', async () => {
  const decoy = makeSupplier({ id: 'decoy', farmName: 'ПРИЗРАК-ДЕМО' })
  let resolveLoad!: (rows: SupplierRow[] | null) => void
  const onLoadMatches = vi.fn(() => new Promise<SupplierRow[] | null>((resolve) => { resolveLoad = resolve }))
  mountModal(baseProps({ pool: makePool({ status: 'filling', suppliers: [decoy] }), onLoadMatches }))

  await expect.element(page.getByText('Загрузка…'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('ПРИЗРАК-ДЕМО')

  resolveLoad!([])
  await expect.element(page.getByText('Поставщиков пока нет'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Загрузка…')
})

// ── M-017 · повторная приёмка не показывается оператору как ошибка ──────────────────
it('ARS-684 M-017: onConfirmDelivery отверг INVALID_STATUS, перечит вернул «принята» — тост не показан', async () => {
  let call = 0
  const row = makeSupplier({ id: 's-dup', source: 'allocation', deliveryStatus: 'in_transit', farmName: 'КХ Дубль' })
  const onLoadMatches = vi.fn(async () => {
    call += 1
    return call === 1 ? [row] : [{ ...row, deliveryStatus: 'delivered' as const }]
  })
  const onConfirmDelivery = vi.fn(async () => { throw new Error('INVALID_STATUS: already confirmed') })
  const toast = vi.fn()
  mountModal(baseProps({ pool: makePool({ status: 'executing' }), onLoadMatches, onConfirmDelivery, toast }))

  await expect.element(page.getByText('КХ Дубль'), T).toBeInTheDocument()
  await page.getByText('Подтвердить приёмку').click()

  await expect.element(page.getByText('✓ Принята'), T).toBeInTheDocument()
  expect(toast).not.toHaveBeenCalled()
})

// ── M-018 · собственная прошлая оценка / прочерк, константы 4.5 нет ─────────────────
it('ARS-684 M-018: своя прошлая оценка либо прочерк на каждой строке — константы 4.5 нет', async () => {
  const rowRated = makeSupplier({ id: 'r-rated', myRating: 3, heads: 15, farmName: 'КХ Оценённое' })
  const rowUnrated = makeSupplier({ id: 'r-unrated', heads: 12, farmName: 'КХ Без оценки' })
  const onLoadMatches = vi.fn(async () => [rowRated, rowUnrated])
  mountModal(baseProps({ pool: makePool({ status: 'filling' }), onLoadMatches }))

  await expect.poll(() => document.querySelectorAll('.supplier-row').length, T).toBe(2)
  const rowsText = Array.from(document.querySelectorAll('.supplier-row')).map((r) => r.textContent ?? '')
  expect(rowsText.some((t) => t.includes('★ 3.0'))).toBe(true)
  expect(rowsText.some((t) => t.includes('★ —'))).toBe(true)
  expect(document.body.textContent).not.toContain('4.5')
})
