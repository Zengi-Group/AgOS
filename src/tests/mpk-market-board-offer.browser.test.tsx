// AgOS · ARS-687 · Маркет-борд: предложение только в настоящую заявку (браузерный тест).
// До этого файла машинного покрытия BatchDetailModal.tsx не было вовсе — именно поэтому
// выдуманный путь («Без привязки» → «Сделка состоялась» на РЕАЛЬНОЙ партии, при пустой БД)
// жил незамеченным. Предмет — Docs/AGOS-TSP-MarketBoard-RequirePool-ARS-687.md,
// раздел `## I/O & Edge-Case Matrix`.
//
// Покрывает все 13 id матрицы ARS-687: M-001 … M-013. Для M-003 и M-006 — по два отдельных
// `it`: матрица требует двух независимых утверждений (M-003 — подстановка единственной заявки
// И неотмена ручного выбора; M-006 — демо-партия при «Без привязки» И при выбранной реальной
// заявке, «селектор в любом состоянии»).
//
// ГРАНИЦА этого файла. M-001 требует ещё и «партия видна в мониторе этой заявки строкой
// маршрута «кусок»» — это утверждение о теле задеплоенной rpc_self_match_batch_to_pool
// (fn_tsp_alloc_chunk) и о read-model монитора, а не о модалке. Слайс их не менял
// (FR-005/FR-011/FR-012), дом монитора — ARS-684; здесь утверждается только то, с какими
// АРГУМЕНТАМИ модалка зовёт onMatch. Сама проверка «строка появилась в мониторе» стоит в
// спеке как ручная после выкладки (§Verification).
//
// Компонент «чистый» — всё внешнее приходит пропсами (см. `interface Props`), сети у него
// нет. Мок @/lib/supabase стоит НЕ для ответа, а наоборот — он бросает на любое обращение:
// если модалка когда-нибудь заведёт собственное чтение, тест станет громким, а не тихим.
//
// @case-тегов здесь намеренно нет: в qa/scenarios/06-tsp-mpk.md нет сценария на привязку
// партии с маркет-борда (сверено в спеке, §Verification), а M-NNN — идентификаторы СПЕКОВОЙ
// матрицы ARS-687, не qa/scenarios/. Тег дал бы qa/check_coverage.sh сироту, то есть
// обещание покрытия, которого нет (`IMPL_DEBT` QA-CASE-ID-NAMESPACE-01).

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import { BatchDetailModal } from '@/pages/cabinet/shell/mpk/modals/BatchDetailModal'
import type { MarketBatch } from '@/pages/cabinet/shell/mpk/data/pools'
import type { Pool } from '@/pages/cabinet/shell/mpk/types'

vi.mock('@/lib/supabase', () => ({
  supabase: {
    rpc: (fn: string) => {
      throw new Error(`mpk-market-board-offer: BatchDetailModal не должен звать RPC (${fn}) — всё приходит пропсами`)
    },
    from: (table: string) => {
      throw new Error(`mpk-market-board-offer: неожиданный supabase.from(${table})`)
    },
  },
}))

// Реальность строки = UUID (так её опознаёт сам компонент, FR-007 и Assumptions спека).
const REAL_BATCH_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const DEMO_BATCH_ID = 'mb1'               // так выглядят id из seedMarketBatches()
const REAL_POOL_A = '11111111-1111-4111-8111-111111111111'
const REAL_POOL_B = '22222222-2222-4222-8222-222222222222'
const DEMO_POOL_ID = 'demo-pool-1'        // так выглядят id из seedPools()

const MIN_PRICE = 1600
const DEFAULT_OFFER = MIN_PRICE + 90      // компонент подставляет minPrice + 90
const HEADS = 40

function makeBatch(overrides: Partial<MarketBatch> = {}): MarketBatch {
  return {
    id: REAL_BATCH_ID,
    catName: 'Бычки откормочные',
    region: 'Тестовый район',
    heads: HEADS,
    avgWeight: 450,
    minPrice: MIN_PRICE,
    breed: 'Казахская белоголовая',
    vaccinated: true,
    suitable: true,
    ...overrides,
  }
}

function makePool(id: string, title: string): Pool {
  return {
    id,
    status: 'filling',
    title,
    region: 'Тестовый район',
    totalHeads: 100,
    filledHeads: 10,
    targetMonth: 'этот месяц',
    lines: [{ catKey: 'vysshaya', price: 1700 }],
    createdAt: '1 сен',
  }
}

type ModalProps = Parameters<typeof BatchDetailModal>[0]

// Дефолт — реальная партия, список прочитан, в нём ДВЕ реальные заявки: так авто-подстановка
// единственной заявки (FR-003) не вмешивается в сценарии, которые её не проверяют.
function baseProps(overrides: Partial<ModalProps> = {}): ModalProps {
  return {
    batch: makeBatch(),
    pools: [makePool(REAL_POOL_A, 'Высшая · А'), makePool(REAL_POOL_B, 'Высшая · Б')],
    poolsState: 'ready',
    onClose: vi.fn(),
    toast: vi.fn(),
    onMatch: vi.fn(async () => {}),
    onCreatePool: vi.fn(),
    onRetryPools: vi.fn(),
    onOffer: vi.fn(),
    ...overrides,
  }
}

let root: Root | null = null
let mountEl: HTMLElement | null = null

function mountModal(props: ModalProps) {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<BatchDetailModal {...props} />)
}

// Пере-рендер теми же корнем и состоянием компонента — нужен там, где матрица говорит о
// СМЕНЕ пропсов на живом экране (список заявок дочитался позже открытия окна).
function rerender(props: ModalProps) {
  root?.render(<BatchDetailModal {...props} />)
}

// Кнопка отправки: на время отправки надпись меняется на «Отправляем…» (обе надписи
// существующие, FR-014 их не менял).
function findSendButton(): HTMLButtonElement | null {
  const b = Array.from(document.querySelectorAll('button.cta')).find((el) => {
    const t = el.textContent?.trim()
    return t === 'Отправить предложение' || t === 'Отправляем…'
  })
  return (b as HTMLButtonElement | undefined) ?? null
}

function sendButton(): HTMLButtonElement {
  const b = findSendButton()
  if (!b) throw new Error('mpk-market-board-offer: кнопки отправки нет на экране')
  return b
}

const poolSelect = (): HTMLSelectElement | null => document.querySelector('select.mpk-select')
const priceInput = (): HTMLInputElement => {
  const el = document.querySelector('input.mpk-input')
  if (!el) throw new Error('mpk-market-board-offer: поля цены нет на экране')
  return el as HTMLInputElement
}
const hints = (): string[] =>
  Array.from(document.querySelectorAll('.mpk-error-hint, .mpk-ok-hint, .pool-card-sub'))
    .map((el) => el.textContent?.trim() ?? '')

// React отслеживает изменение `.value` через собственный сеттер на прототипе элемента
// (нужен для controlled-инпутов); присвоение `el.value = x` идёт мимо него, и последующий
// native 'input' React игнорирует. Вызываем сеттер прототипа, как реальный ввод.
function setNativeValue(el: HTMLInputElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set?.call(el, value)
  el.dispatchEvent(new Event('input', { bubbles: true }))
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

// ── M-001 · happy · привязка ──────────────────────────────────────────────────────────
it('ARS-687 M-001: реальная партия + выбранная реальная заявка — onMatch(pool, batch, heads, price), тост о привязке, окно закрыто', async () => {
  const onMatch = vi.fn(async () => {})
  const onClose = vi.fn()
  const toast = vi.fn()
  mountModal(baseProps({ onMatch, onClose, toast }))

  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  await expect.poll(() => sendButton().disabled, T).toBe(false)
  sendButton().click()

  await expect.poll(() => onMatch.mock.calls.length, T).toBe(1)
  expect(onMatch).toHaveBeenCalledWith(REAL_POOL_A, REAL_BATCH_ID, HEADS, DEFAULT_OFFER)
  await expect.poll(() => toast.mock.calls.length, T).toBe(1)
  expect(toast).toHaveBeenCalledWith('Оффер отправлен — партия привязана к закупке')
  await expect.poll(() => onClose.mock.calls.length, T).toBe(1)
})

// ── M-002 · заявка не выбрана ─────────────────────────────────────────────────────────
it('ARS-687 M-002: реальная партия, селектор на «Без привязки» — кнопка неактивна, рядом дословная причина', async () => {
  mountModal(baseProps())

  await expect.element(
    page.getByText('Выберите свою заявку: предложение уходит в конкретную закупку'), T,
  ).toBeInTheDocument()
  expect(poolSelect()?.value).toBe('')
  expect(sendButton().disabled).toBe(true)
})

// ── M-003 · одна заявка ───────────────────────────────────────────────────────────────
it('ARS-687 M-003: список прочитан, в нём ровно одна заявка — она выбрана заранее, отправка доступна', async () => {
  mountModal(baseProps({ pools: [makePool(REAL_POOL_A, 'Высшая · А')] }))

  await expect.poll(() => poolSelect()?.value, T).toBe(REAL_POOL_A)
  expect(sendButton().disabled).toBe(false)
})

it('ARS-687 M-003: подстановка идёт только ПОСЛЕ чтения списка и не отменяет выбор, сделанный руками', async () => {
  const loading = baseProps({ poolsState: 'loading', pools: [makePool(REAL_POOL_A, 'Высшая · А')] })
  mountModal(loading)

  // Пока список не прочитан — подставлять нечего, селектора нет вовсе (FR-003 ← FR-009).
  await expect.element(page.getByText('Заявки загружаются…'), T).toBeInTheDocument()
  expect(poolSelect()).toBeNull()

  // Список дочитался, в нём две заявки — оператор выбирает сам и возвращается на «Без привязки».
  const two = baseProps({ poolsState: 'ready' })
  rerender(two)
  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  await expect.poll(() => poolSelect()?.value, T).toBe(REAL_POOL_A)
  await page.getByRole('combobox').selectOptions('')
  await expect.poll(() => poolSelect()?.value, T).toBe('')

  // Список сузился до одной заявки — подстановка НЕ перебивает уже сделанный выбор.
  rerender(baseProps({ poolsState: 'ready', pools: [makePool(REAL_POOL_A, 'Высшая · А')] }))
  await expect.poll(() => sendButton().disabled, T).toBe(true)
  expect(poolSelect()?.value).toBe('')
})

// Список меняется под открытым окном (поллинг 20с, refetch после привязки/приёмки): выбор,
// ушедший из списка доступных для привязки, перестаёт быть выбором — иначе оффер уходил бы в
// заявку, которой в селекторе уже нет, при активной кнопке и молчащей причине.
it('ARS-687 FR-001/M-002: выбранная заявка ушла из списка — отправка закрывается, видна причина M-002', async () => {
  mountModal(baseProps())

  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  await expect.poll(() => sendButton().disabled, T).toBe(false)

  // Заявка A набралась и ушла из `filling` — в пропсе её больше нет.
  rerender(baseProps({ pools: [makePool(REAL_POOL_B, 'Высшая · Б')] }))

  await expect.poll(() => sendButton().disabled, T).toBe(true)
  await expect.element(
    page.getByText('Выберите свою заявку: предложение уходит в конкретную закупку'), T,
  ).toBeInTheDocument()
})

// ── M-004 · заявок нет ────────────────────────────────────────────────────────────────
it('ARS-687 M-004: список прочитан и пуст — отдельное состояние с текстом и кнопкой на создание заявки', async () => {
  const onCreatePool = vi.fn()
  mountModal(baseProps({ pools: [], onCreatePool }))

  await expect.element(
    page.getByText('Сначала создайте заявку на закупку — предложение уходит в неё'), T,
  ).toBeInTheDocument()
  // Отправлять некуда: ни селектора, ни кнопки отправки в этом состоянии нет.
  expect(poolSelect()).toBeNull()
  expect(findSendButton()).toBeNull()

  await page.getByText('Создать заявку на закупку').click()
  await expect.poll(() => onCreatePool.mock.calls.length, T).toBe(1)
})

// ── M-005 · несколько заявок ──────────────────────────────────────────────────────────
it('ARS-687 M-005: в списке две и более заявки — ни одна не выбрана сама, до выбора действует M-002', async () => {
  mountModal(baseProps())

  await expect.poll(() => poolSelect()?.options.length, T).toBe(3)
  expect(Array.from(poolSelect()!.options).map((o) => o.value)).toEqual(['', REAL_POOL_A, REAL_POOL_B])
  expect(poolSelect()!.value).toBe('')
  expect(sendButton().disabled).toBe(true)
  await expect.element(
    page.getByText('Выберите свою заявку: предложение уходит в конкретную закупку'), T,
  ).toBeInTheDocument()
})

// ── M-006 · демо-партия ───────────────────────────────────────────────────────────────
it('ARS-687 M-006: демо-партия при «Без привязки» — демо-путь как сегодня (onOffer), onMatch не зовётся', async () => {
  const onOffer = vi.fn()
  const onMatch = vi.fn(async () => {})
  mountModal(baseProps({ batch: makeBatch({ id: DEMO_BATCH_ID }), onOffer, onMatch }))

  await expect.poll(() => sendButton().disabled, T).toBe(false)
  sendButton().click()

  await expect.poll(() => onOffer.mock.calls.length, T).toBe(1)
  expect(onOffer.mock.calls[0]![0]).toMatchObject({ batchId: DEMO_BATCH_ID, price: DEFAULT_OFFER })
  expect(onMatch).not.toHaveBeenCalled()
})

it('ARS-687 M-006: демо-партия при ВЫБРАННОЙ реальной заявке — тот же демо-путь (селектор в любом состоянии)', async () => {
  const onOffer = vi.fn()
  const onMatch = vi.fn(async () => {})
  mountModal(baseProps({ batch: makeBatch({ id: DEMO_BATCH_ID }), onOffer, onMatch }))

  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  await expect.poll(() => poolSelect()?.value, T).toBe(REAL_POOL_A)
  sendButton().click()

  await expect.poll(() => onOffer.mock.calls.length, T).toBe(1)
  expect(onMatch).not.toHaveBeenCalled()
})

// ── M-007 · смешанная пара ────────────────────────────────────────────────────────────
it('ARS-687 M-007: реальная партия + демо-заявка — кнопка неактивна, рядом дословная причина', async () => {
  mountModal(baseProps({
    pools: [makePool(DEMO_POOL_ID, 'Демо · закупка'), makePool(REAL_POOL_A, 'Высшая · А')],
  }))

  await page.getByRole('combobox').selectOptions(DEMO_POOL_ID)
  await expect.element(page.getByText('Эта заявка демонстрационная — выберите настоящую'), T).toBeInTheDocument()
  expect(sendButton().disabled).toBe(true)
})

// ── M-008 · цена ниже минимума ────────────────────────────────────────────────────────
it('ARS-687 M-008: цена ниже минимума — подсказка под полем, но отправку не блокирует (отказ отдаёт база)', async () => {
  const onMatch = vi.fn(async () => {})
  mountModal(baseProps({ onMatch }))

  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  setNativeValue(priceInput(), String(MIN_PRICE - 100))

  await expect.poll(() => hints().some((t) => t.includes('мин. цены')), T).toBe(true)
  expect(sendButton().disabled).toBe(false)
  sendButton().click()

  await expect.poll(() => onMatch.mock.calls.length, T).toBe(1)
  expect(onMatch).toHaveBeenCalledWith(REAL_POOL_A, REAL_BATCH_ID, HEADS, MIN_PRICE - 100)
})

// ── M-009 · повторное нажатие ─────────────────────────────────────────────────────────
it('ARS-687 M-009: два нажатия подряд — привязка одна', async () => {
  // Отправка «висит», пока тест её не отпустит — так проверяется состояние «отправка идёт».
  let release: () => void = () => {}
  const onMatch = vi.fn(() => new Promise<void>((resolve) => { release = resolve }))
  mountModal(baseProps({ onMatch }))

  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  await expect.poll(() => sendButton().disabled, T).toBe(false)
  // Два синхронных нажатия — оба попадают в одно замыкание обработчика.
  sendButton().click()
  sendButton().click()

  await expect.poll(() => onMatch.mock.calls.length, T).toBe(1)
  await expect.poll(() => sendButton().disabled, T).toBe(true)
  // Ещё одно нажатие, пока отправка идёт — тоже не создаёт второй привязки.
  sendButton().click()
  expect(onMatch.mock.calls.length).toBe(1)
  release()
})

// ── M-010 · отказ привязки ────────────────────────────────────────────────────────────
it('ARS-687 M-010: база отказала — строка отказа показана дословно, сделка не объявляется, попытку можно повторить', async () => {
  const dbLine = 'ALLOC_FAILED: в заявке нет места / цена < ask фермера'
  const onMatch = vi.fn(async () => { throw new Error(dbLine) })
  const onClose = vi.fn()
  const onOffer = vi.fn()
  const toast = vi.fn()
  mountModal(baseProps({ onMatch, onClose, onOffer, toast }))

  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  sendButton().click()

  await expect.poll(() => toast.mock.calls.length, T).toBe(1)
  expect(String(toast.mock.calls[0]![0])).toContain(dbLine)
  expect(onClose).not.toHaveBeenCalled()
  expect(onOffer).not.toHaveBeenCalled()
  await expect.poll(() => sendButton().disabled, T).toBe(false)
})

// ── M-011 · «Сделка состоялась» недостижима ───────────────────────────────────────────
it('ARS-687 M-011: реальная партия — окно «Сделка состоялась» (onOffer) не достигается ни на одном пути', async () => {
  const onOffer = vi.fn()
  const onMatch = vi.fn(async () => { throw new Error('ALLOC_FAILED: нет места') })
  mountModal(baseProps({
    onOffer, onMatch,
    pools: [makePool(DEMO_POOL_ID, 'Демо · закупка'), makePool(REAL_POOL_A, 'Высшая · А')],
  }))

  // 1) «Без привязки» — нажатие по неактивной кнопке.
  await expect.poll(() => sendButton().disabled, T).toBe(true)
  sendButton().click()
  // 2) выбрана демо-заявка.
  await page.getByRole('combobox').selectOptions(DEMO_POOL_ID)
  await expect.poll(() => sendButton().disabled, T).toBe(true)
  sendButton().click()
  // 3) выбрана реальная заявка, но база отказала.
  await page.getByRole('combobox').selectOptions(REAL_POOL_A)
  await expect.poll(() => sendButton().disabled, T).toBe(false)
  sendButton().click()

  await expect.poll(() => onMatch.mock.calls.length, T).toBe(1)
  // Несущее утверждение — именно «onOffer не позван». Проверять здесь отсутствие «Берекет»
  // в DOM было бы вакуумно: выдуманное хозяйство живёт в АРГУМЕНТЕ onOffer, а DealClosedModal
  // рисует не эта модалка, так что такая проверка не может упасть по своей причине. Что
  // DealClosedModal достижим ТОЛЬКО из onOffer — факт проводки MpkApp (единственный вызов
  // openModal({kind:'deal_closed'})), и он держится не этим тестом.
  expect(onOffer).not.toHaveBeenCalled()
})

// ── M-012 · список грузится ───────────────────────────────────────────────────────────
it('ARS-687 M-012: список заявок ещё не пришёл — видно, что грузится; отправка недоступна; демо-заявки не подставлены', async () => {
  mountModal(baseProps({ poolsState: 'loading', pools: [makePool(DEMO_POOL_ID, 'Демо · закупка')] }))

  await expect.element(page.getByText('Заявки загружаются…'), T).toBeInTheDocument()
  expect(poolSelect()).toBeNull()
  expect(document.body.textContent).not.toContain('Демо · закупка')
  expect(sendButton().disabled).toBe(true)
})

// ── M-013 · список не прочитан ────────────────────────────────────────────────────────
it('ARS-687 M-013: чтение не удалось — сказано именно это (не «заявок нет»); отправка недоступна; повторная попытка доступна', async () => {
  const onRetryPools = vi.fn()
  mountModal(baseProps({
    poolsState: 'failed', pools: [makePool(DEMO_POOL_ID, 'Демо · закупка')], onRetryPools,
  }))

  await expect.element(page.getByText('Список заявок не загрузился'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Сначала создайте заявку на закупку')
  expect(poolSelect()).toBeNull()
  expect(document.body.textContent).not.toContain('Демо · закупка')
  expect(sendButton().disabled).toBe(true)

  await page.getByText('Повторить').click()
  await expect.poll(() => onRetryPools.mock.calls.length, T).toBe(1)
})
