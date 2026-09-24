// AgOS · Slice11 (ARS-718) · SCR-R1/R2/R3 — строки матрицы раздела «Мои заявки».
//
// Один тест = одна строка матрицы, id в названии: `M-001`…`M-020`. Сетевая граница —
// единственный мок; роутинг, состояние и раскладка настоящие.
//
// Браузерный проект обязателен по той же причине, что и у консоли профиля: под `/mpk`
// живёт v5-остров Ionic, который node-окружение не воспроизводит.
// Запуск: npm run test:routers.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

interface RawPool {
  id: string
  status: string
  totalHeads: number
  filledHeads: number
  region: string
  targetMonthIso: string | null
  createdAtIso: string | null
  lines: { code: string; price: number }[]
  contactRevealed: boolean
  minPoolHeads: number
}

interface RawMatch {
  matchId: string; batchId: string; cat: string; grade: string | null; breed: string
  heads: number; avgWeight: number; price: number; region: string; status: string
  matchedAt: string | null; confirmedAt: string | null; dispatchedAt: string | null
  deliveredAt: string | null; farmName: string | null; farmPhone: string | null
  myRating: number | null; source: string
}

const store = vi.hoisted(() => ({
  pools: [] as RawPool[],
  matches: [] as RawMatch[],
  calls: [] as { name: string; args: Record<string, unknown> }[],
  failPools: false,
  failActivate: false,
  failDecisionOnce: false,
  failConfirmOnce: false,
  // ARS-691: точный текст отказа для решения / создания / запуска (null — без отказа).
  decisionErrorMessage: null as string | null,
  createErrorMessage: null as string | null,
  activateErrorMessage: null as string | null,
  activateNoPoolId: false,
  poolsDelayMs: 0,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-req-user', user_metadata: { full_name: 'Асхат Оператор' }, phone: '' }
  const session = { access_token: 't', refresh_token: 't', token_type: 'bearer', expires_in: 3600, user }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: null }) as Promise<unknown> & Record<string, unknown>
    for (const m of ['select', 'eq', 'order', 'limit', 'single', 'maybeSingle']) q[m] = () => q
    return q
  }
  const ok = (data: unknown) => ({ data, error: null })
  const findPool = (id: unknown) => store.pools.find((p) => p.id === id)
  return {
    supabase: {
      auth: {
        getSession: async () => ({ data: { session }, error: null }),
        getUser: async () => ({ data: { user }, error: null }),
        setSession: async () => ({ data: { session, user }, error: null }),
        signOut: async () => ({ error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      },
      from: () => chain(),
      channel: () => {
        const ch: Record<string, () => unknown> = {}
        for (const m of ['on', 'subscribe', 'unsubscribe']) ch[m] = () => ch
        return ch
      },
      removeChannel: async () => 'ok',
      rpc: async (name: string, args: Record<string, unknown> = {}) => {
        store.calls.push({ name, args })
        switch (name) {
          case 'rpc_get_my_context':
            return ok({
              user_id: 'mpk-req-user',
              organizations: [{ id: 'org-1', name: 'МК «Семей Ет»', org_types: ['mpk'], is_primary: true, bin: '123456789012' }],
              farms: [], memberships: [],
            })
          case 'rpc_get_my_pools':
            if (store.poolsDelayMs) await new Promise((r) => setTimeout(r, store.poolsDelayMs))
            if (store.failPools) return { data: null, error: { message: 'rpc недоступна' } }
            return ok(store.pools)
          case 'rpc_get_pool_matches':
            return ok(store.matches)
          case 'rpc_self_pool_accept_partial': {
            if (store.decisionErrorMessage !== null) return { data: null, error: { message: store.decisionErrorMessage } }
            if (store.failDecisionOnce) {
              store.failDecisionOnce = false
              // Заявку уже перевели мимо этого экрана (подметание/телефон) — база отвечает
              // ровно так, как названо в колонке «обработка ошибки» строки M-006.
              const p0 = findPool(args.p_pool_id)
              if (p0) p0.status = 'closed_unfilled'
              return { data: null, error: { message: 'INVALID_STATUS' } }
            }
            const p = findPool(args.p_pool_id)
            if (p) p.status = 'closed_partial'
            return ok(true)
          }
          case 'rpc_self_pool_return_batches': {
            const p = findPool(args.p_pool_id)
            if (p) { p.status = 'closed_unfilled'; p.filledHeads = 0 }
            return ok(true)
          }
          case 'rpc_self_pool_close_now':
            return ok({ outcome: 'awaiting_mpk_decision' })
          case 'rpc_self_confirm_delivery':
          case 'rpc_self_confirm_delivery_alloc': {
            if (store.failConfirmOnce) {
              store.failConfirmOnce = false
              return { data: null, error: { message: 'INVALID_STATUS: allocation is delivered, expected dispatched' } }
            }
            const id = (args.p_batch_id ?? args.p_allocation_id) as string
            const row = store.matches.find((m) => m.batchId === id || m.matchId === id)
            if (row) row.status = 'delivered'
            return ok(true)
          }
          case 'rpc_self_create_pool_request':
            if (store.createErrorMessage !== null) return { data: null, error: { message: store.createErrorMessage } }
            return ok('req-1')
          case 'rpc_self_activate_pool_request':
            if (store.activateErrorMessage !== null) return { data: null, error: { message: store.activateErrorMessage } }
            if (store.activateNoPoolId) return ok({})
            if (store.failActivate) return { data: null, error: { message: 'ACTIVATION_FAILED' } }
            store.pools.push(makePool({ id: 'p-new', status: 'filling', totalHeads: 220, filledHeads: 0 }))
            return ok({ pool_id: 'p-new' })
          default:
            return ok(null)
        }
      },
    },
  }
})

function makePool(patch: Partial<RawPool> & { id: string; status: string }): RawPool {
  return {
    totalHeads: 200,
    filledHeads: 24,
    region: 'Алматинская обл.',
    targetMonthIso: '2026-10-01',
    createdAtIso: '2026-09-01',
    lines: [{ code: 'vysshaya', price: 1700 }],
    contactRevealed: false,
    minPoolHeads: 10,
    ...patch,
  }
}

function makeMatch(patch: Partial<RawMatch> & { matchId: string; batchId: string }): RawMatch {
  return {
    cat: 'bychki', grade: null, breed: 'Ангус', heads: 12, avgWeight: 430, price: 1700,
    region: 'Илийский район', status: 'matched', matchedAt: '2026-09-05', confirmedAt: null,
    dispatchedAt: null, deliveredAt: null, farmName: null, farmPhone: null, myRating: null,
    source: 'allocation',
    ...patch,
  }
}

const initialUrl = window.location.pathname + window.location.search
let root: Root | null = null
let mountEl: HTMLElement | null = null

function mountAppAt(path: string) {
  window.history.replaceState(null, '', path)
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<App />)
}

function unmount() {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
}

/** «Перезагрузка страницы» в терминах теста: тот же URL, новое дерево, пустое состояние. */
function reload() {
  const path = window.location.pathname + window.location.search
  unmount()
  mountAppAt(path)
}

const T = { timeout: 15_000 }

beforeEach(async () => {
  await page.viewport(1440, 900)
  expect(window.innerWidth, 'ширина раннера < 1024px — консоль подменяется мостом').toBeGreaterThanOrEqual(1024)
  store.pools = []
  store.matches = []
  store.calls = []
  store.failPools = false
  store.failActivate = false
  store.failDecisionOnce = false
  store.failConfirmOnce = false
  store.decisionErrorMessage = null
  store.createErrorMessage = null
  store.activateErrorMessage = null
  store.activateNoPoolId = false
  store.poolsDelayMs = 0
})

afterEach(() => {
  unmount()
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

const rows = () => document.querySelectorAll('.agos-mpk-console .mpkr-row')
const tabByLabel = (label: string): HTMLElement | null => {
  const all = Array.from(document.querySelectorAll<HTMLElement>('.agos-mpk-console [role="tab"]'))
  return all.find((el) => el.textContent?.trim().startsWith(label)) ?? null
}
const tabCount = (label: string): string | null =>
  tabByLabel(label)?.querySelector('.mpkr-count')?.textContent?.trim() ?? null

const FIVE_POOLS = (): RawPool[] => [
  makePool({ id: 'p-fill', status: 'filling', filledHeads: 85 }),
  makePool({ id: 'p-dec', status: 'awaiting_mpk_decision', filledHeads: 24 }),
  makePool({ id: 'p-ship', status: 'closed_filled', filledHeads: 200, contactRevealed: true }),
  makePool({ id: 'p-done', status: 'completed', filledHeads: 200, contactRevealed: true }),
  makePool({ id: 'p-fail', status: 'closed_unfilled', filledHeads: 0 }),
]

// ── M-001 · happy path списка ────────────────────────────────────────────────
it('M-001: пять заявок в разных статусах — список, активная вкладка «Все», счётчики сходятся', async () => {
  store.pools = FIVE_POOLS()
  mountAppAt('/mpk/requests')

  await expect.poll(() => rows().length, T).toBe(5)
  expect(tabByLabel('Все')?.getAttribute('aria-selected')).toBe('true')
  expect(tabCount('Все')).toBe('5')
  const sum = ['Набираются', 'Требуют решения', 'Отгрузка и приёмка', 'Завершённые', 'Не состоялись']
    .reduce((s, l) => s + Number(tabCount(l)), 0)
  expect(sum, 'каждая заявка попадает ровно в одну вкладку').toBe(5)
})

// ── M-002 · заявок нет ───────────────────────────────────────────────────────
it('M-002: чтение успешно и заявок ноль — пустое состояние с ходом «Новая заявка»', async () => {
  mountAppAt('/mpk/requests')
  await expect.element(page.getByText('Заявок пока нет'), T).toBeInTheDocument()
  await expect.element(page.getByRole('button', { name: 'Новая заявка' }).first(), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Список не загрузился')
})

// ── M-003 · список не прочитан ───────────────────────────────────────────────
it('M-003: RPC отказала — «Список не загрузился» + «Повторить», демо-заявок нет', async () => {
  store.failPools = true
  mountAppAt('/mpk/requests')

  await expect.element(page.getByText('Список не загрузился'), T).toBeInTheDocument()
  // Сид-демо мобильного шелла на этом экране не появляется ни в одном исходе (FR-012).
  expect(document.body.textContent).not.toContain('КРС Премиум · ЮКО')
  expect(rows().length).toBe(0)

  // Повтор перечитывает: чинится не перезагрузкой страницы, а кнопкой.
  store.failPools = false
  store.pools = FIVE_POOLS()
  await page.getByRole('button', { name: 'Повторить' }).click()
  await expect.poll(() => rows().length, T).toBe(5)
})

// ── M-004 · чтение идёт ──────────────────────────────────────────────────────
it('M-004: пока список читается — виден скелет, счётчики вкладок не показывают нулей', async () => {
  store.poolsDelayMs = 400
  store.pools = FIVE_POOLS()
  mountAppAt('/mpk/requests')

  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-skel'), T).not.toBeNull()
  expect(tabCount('Все'), 'ноль как факт до чтения — ложь о данных').toBeNull()
  await expect.poll(() => rows().length, T).toBe(5)
  expect(tabCount('Все')).toBe('5')
})

// ── M-005 · фильтр ───────────────────────────────────────────────────────────
it('M-005: вкладка «Требуют решения» показывает только точку выбора и переживает reload', async () => {
  store.pools = FIVE_POOLS()
  mountAppAt('/mpk/requests')
  await expect.poll(() => rows().length, T).toBe(5)

  await page.getByRole('tab', { name: /Требуют решения/ }).click()
  await expect.poll(() => rows().length, T).toBe(1)
  expect(document.querySelector('.mpkr-row')?.textContent).toContain('Нужно ваше решение')
  expect(window.location.search).toBe('?tab=decision')

  reload()
  await expect.poll(() => rows().length, T).toBe(1)
  expect(tabByLabel('Требуют решения')?.getAttribute('aria-selected')).toBe('true')
})

// ── M-006 · точка выбора · принять частично ──────────────────────────────────
it('M-006: «Принять частично» зовёт rpc_self_pool_accept_partial, экран показывает новое состояние', async () => {
  store.pools = [makePool({ id: 'p-dec', status: 'awaiting_mpk_decision', filledHeads: 24, totalHeads: 220 })]
  mountAppAt('/mpk/requests/p-dec')

  // `.first()`: подпись «Нужно ваше решение» стоит и чипом статуса, и заголовком блока
  // хода — оба верны, локатор не должен падать на строгом режиме из-за двух совпадений.
  await expect.element(page.getByText('Нужно ваше решение').first(), T).toBeInTheDocument()
  await page.getByRole('button', { name: /Принять частично/ }).click()

  await expect.poll(() => store.calls.some((c) => c.name === 'rpc_self_pool_accept_partial'), T).toBe(true)
  // Новое состояние заявки экран берёт из перечитанного ответа базы, а не рисует сам.
  await expect.element(page.getByText('Принято частично'), T).toBeInTheDocument()
})

// ── M-006 · обработка ошибки: INVALID_STATUS → перечитать и показать актуальное ──────────
// ARS-691 M-005: причина названа фразой словаря в красной плашке, сырого кода нет.
it('M-006 · ARS-691 M-005: INVALID_STATUS — названа причина И показано актуальное состояние заявки', async () => {
  store.pools = [makePool({ id: 'p-dec', status: 'awaiting_mpk_decision', filledHeads: 24, totalHeads: 220 })]
  store.failDecisionOnce = true
  mountAppAt('/mpk/requests/p-dec')

  await expect.element(page.getByText('Нужно ваше решение').first(), T).toBeInTheDocument()
  await page.getByRole('button', { name: /Принять частично/ }).click()

  await expect.element(page.getByText('Статус уже изменился. Обновите экран и проверьте, что сейчас.'), T).toBeInTheDocument()
  expect(document.querySelector('.mpkr-flash.bad')?.textContent).not.toContain('INVALID_STATUS')
  // Главное: экран не остался с прежними кнопками над изменившейся заявкой.
  await expect.element(page.getByText('Заявка недобрала'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Принять частично')
})

// ── M-007 · точка выбора · вернуть партии ────────────────────────────────────
it('M-007: «Вернуть партии» зовёт rpc_self_pool_return_batches и заявка уходит в «Недобрала»', async () => {
  store.pools = [makePool({ id: 'p-dec', status: 'awaiting_mpk_decision', filledHeads: 24, totalHeads: 220 })]
  mountAppAt('/mpk/requests/p-dec')

  // `.first()`: подпись «Нужно ваше решение» стоит и чипом статуса, и заголовком блока
  // хода — оба верны, локатор не должен падать на строгом режиме из-за двух совпадений.
  await expect.element(page.getByText('Нужно ваше решение').first(), T).toBeInTheDocument()
  await page.getByRole('button', { name: 'Вернуть партии' }).click()

  await expect.poll(() => store.calls.some((c) => c.name === 'rpc_self_pool_return_batches'), T).toBe(true)
  await expect.element(page.getByText('Заявка недобрала'), T).toBeInTheDocument()
})

// ── M-008 · решения нет ──────────────────────────────────────────────────────
it('M-008: набрано меньше порога — вместо ходов объяснение с минимумом', async () => {
  store.pools = [makePool({ id: 'p-low', status: 'filling', filledHeads: 4, totalHeads: 220, minPoolHeads: 10 })]
  mountAppAt('/mpk/requests/p-low')

  await expect.element(page.getByText(/Набрано 4 из 220 гол\. Минимум для закупки/), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Закрыть набор сейчас')
})

// ── M-009 · открытие заявки ──────────────────────────────────────────────────
it('M-009: клик по строке открывает заявку, «назад» возвращает в список на ту же вкладку', async () => {
  store.pools = FIVE_POOLS()
  mountAppAt('/mpk/requests?tab=decision')
  await expect.poll(() => rows().length, T).toBe(1)

  await page.getByRole('button', { name: /Нужно ваше решение/ }).first().click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests/p-dec')
  // Две вкладки, и только две: «События» слайс не строит (FR-020).
  await expect.poll(() => document.querySelectorAll('.agos-mpk-console [role="tab"]').length, T).toBe(2)

  // Переключение вкладок монитора — тоже часть «экран соответствует URL»: до этой
  // проверки список поставщиков открывался только прямым адресом, и перепутанные ветки
  // `setView` прошли бы зелёным.
  await page.getByRole('tab', { name: 'Поставщики' }).click()
  await expect.poll(() => window.location.search, T).toBe('?tab=decision&view=suppliers')
  await page.getByRole('tab', { name: 'Обзор' }).click()
  await expect.poll(() => window.location.search, T).toBe('?tab=decision')

  await page.getByRole('button', { name: 'К списку заявок' }).click()
  await expect.poll(() => window.location.search, T).toBe('?tab=decision')
  await expect.poll(() => rows().length, T).toBe(1)
})

// ── M-010 · несуществующая заявка ────────────────────────────────────────────
it('M-010: прямой заход на чужой id — «Заявка не найдена», чужие данные не показаны', async () => {
  store.pools = FIVE_POOLS()
  mountAppAt('/mpk/requests/00000000-0000-4000-8000-000000000999')

  await expect.element(page.getByText('Заявка не найдена'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Нужно ваше решение')
  await page.getByRole('button', { name: 'К списку заявок' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests')
})

// ── M-011 · приёмка обоими маршрутами ────────────────────────────────────────
it('M-011: приёмка по маршруту «кусок» и «партия целиком» — строка становится «Принято» и переживает reload', async () => {
  store.pools = [makePool({ id: 'p-ship', status: 'closed_filled', filledHeads: 200, contactRevealed: true })]
  store.matches = [
    // Кусок партии: адрес приёмки — id строки (`matchId`).
    makeMatch({ matchId: 'alloc-1', batchId: 'b-1', source: 'allocation', status: 'dispatched', farmName: 'КХ Жаксылык' }),
    // Партия целиком: read-model кладёт `'matchId', b.id`, поэтому у batch-строки эти поля
    // РАВНЫ (20260910120000:146). Фикстура обязана повторять контракт, иначе тест закрепит
    // состояние, которого прод не производит.
    makeMatch({ matchId: 'b-2', batchId: 'b-2', source: 'batch', status: 'dispatched', farmName: 'ТОО Агро-Бек' }),
  ]
  mountAppAt('/mpk/requests/p-ship?view=suppliers')

  await expect.poll(() => document.querySelectorAll('.mpkr-srow').length, T).toBe(2)
  const buttons = () => Array.from(document.querySelectorAll<HTMLButtonElement>('.mpkr-srow button'))
  const clickFirst = () => {
    const btn = buttons()[0]
    if (!btn) throw new Error('кнопки приёмки нет — строка поставщика не отрисовалась')
    btn.click()
  }
  clickFirst()
  await expect.poll(() => store.calls.some((c) => c.name === 'rpc_self_confirm_delivery_alloc'), T).toBe(true)
  // ARS-684: маршрут «кусок» адресуется id СТРОКИ, а не id партии — проверяем аргумент,
  // иначе перепутанный адрес прошёл бы зелёным (имя RPC от него не зависит).
  expect(store.calls.find((c) => c.name === 'rpc_self_confirm_delivery_alloc')?.args.p_allocation_id).toBe('alloc-1')
  await expect.poll(() => buttons().length, T).toBe(1)   // у принятой строки кнопки больше нет

  clickFirst()
  await expect.poll(() => store.calls.some((c) => c.name === 'rpc_self_confirm_delivery'), T).toBe(true)
  expect(store.calls.find((c) => c.name === 'rpc_self_confirm_delivery')?.args.p_batch_id).toBe('b-2')

  reload()
  await expect.poll(
    () => Array.from(document.querySelectorAll('.mpkr-srow')).every((r) => r.textContent?.includes('Принято')),
    T,
  ).toBe(true)
})

// ── ARS-691 M-013 · приёмка уже подтверждена (десктоп) ───────────────────────
// Спек `Docs/AGOS-TSP-MpkErrorText-ARS-691.md`: на десктопе подавления INVALID_STATUS нет
// (FR-007) — оператор видит фразу словаря в красной плашке, а не сырой код с хвостом.
it('ARS-691 M-013: приёмка отвергнута INVALID_STATUS — красная плашка с фразой, кода и хвоста нет', async () => {
  store.pools = [makePool({ id: 'p-ship', status: 'closed_filled', filledHeads: 200, contactRevealed: true })]
  store.matches = [makeMatch({ matchId: 'alloc-1', batchId: 'b-1', source: 'allocation', status: 'dispatched', farmName: 'КХ Жаксылык' })]
  store.failConfirmOnce = true
  mountAppAt('/mpk/requests/p-ship?view=suppliers')

  await expect.poll(() => document.querySelectorAll('.mpkr-srow button').length, T).toBe(1)
  document.querySelector<HTMLButtonElement>('.mpkr-srow button')!.click()

  await expect.poll(() => document.querySelector('.mpkr-flash.bad')?.textContent ?? null, T)
    .toBe('Статус уже изменился. Обновите экран и проверьте, что сейчас.')
  expect(document.querySelector('.mpkr-flash.bad .rpc-error-code'), 'знакомый код — строки кода нет').toBeNull()
  expect(document.body.textContent).not.toContain('expected dispatched')
})

// ── M-012 · контакты до сделки ───────────────────────────────────────────────
it('M-012: заявка ещё не закрыта — имя, телефон и район хозяйства не показаны', async () => {
  store.pools = [makePool({ id: 'p-fill', status: 'filling', filledHeads: 85, contactRevealed: false })]
  store.matches = [makeMatch({ matchId: 'alloc-1', batchId: 'b-1', farmName: null, farmPhone: null })]
  mountAppAt('/mpk/requests/p-fill?view=suppliers')

  await expect.poll(() => document.querySelectorAll('.mpkr-srow').length, T).toBe(1)
  const text = document.querySelector('.mpkr-srow')?.textContent ?? ''
  expect(text).toContain('Поставщик скрыт')
  // Район хозяйства — тоже адресная привязка: `rpc_get_pool_matches` отдаёт его всегда,
  // и молчать обязан экран (D-M6-5/12, ст. 171).
  expect(text, 'район хозяйства виден до раскрытия контактов').not.toContain('Илийский район')
  expect(document.body.textContent).toContain('раскрываются после закрытия заявки')
})

// ── M-016 · контакты после сделки ────────────────────────────────────────────
it('M-016: заявка закрыта и contactRevealed — в строке видны хозяйство и телефон', async () => {
  store.pools = [makePool({ id: 'p-ship', status: 'closed_filled', filledHeads: 200, contactRevealed: true })]
  store.matches = [makeMatch({
    matchId: 'alloc-1', batchId: 'b-1', farmName: 'КХ Жаксылык', farmPhone: '+7 701 000 00 00',
  })]
  mountAppAt('/mpk/requests/p-ship?view=suppliers')

  await expect.poll(() => document.querySelector('.mpkr-srow')?.textContent ?? '', T)
    .toContain('КХ Жаксылык')
  expect(document.querySelector('.mpkr-srow')?.textContent).toContain('+7 701 000 00 00')
  expect(document.querySelector('.mpkr-srow')?.textContent).toContain('Илийский район')
  expect(document.body.textContent).not.toContain('раскрываются после закрытия заявки')
})

// ── M-013 · узкий экран ──────────────────────────────────────────────────────
it('M-013: ниже 1024px — мост под тем же адресом, ссылка в мобильный шелл, URL не переписан', async () => {
  store.pools = FIVE_POOLS()
  await page.viewport(900, 800)
  mountAppAt('/mpk/requests/p-dec')

  await expect.element(page.getByText(/Полный вид раздела открывается/), T).toBeInTheDocument()
  expect(window.location.pathname, 'мост не переписывает deep-link').toBe('/mpk/requests/p-dec')
  expect(document.querySelector('.mpkc-narrow-link')?.textContent).toBe('/mpk/requests/p-dec')
  await expect.element(page.getByRole('button', { name: /мобильном кабинете/ }), T).toBeInTheDocument()
  // Мост ничего не мутирует: подметания просроченных заявок с него не происходит.
  expect(store.calls.some((c) => c.name === 'rpc_self_close_due_pools')).toBe(false)
})

// ── M-014 · навигация браузера ───────────────────────────────────────────────
it('M-014: reload, назад и вперёд — экран всегда соответствует URL', async () => {
  store.pools = FIVE_POOLS()
  mountAppAt('/mpk/requests')
  await expect.poll(() => rows().length, T).toBe(5)

  await page.getByRole('tab', { name: /Набираются/ }).click()
  await expect.poll(() => window.location.search, T).toBe('?tab=filling')
  await page.getByRole('button', { name: /КРС · Высшая · Алматинская обл\./ }).first().click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests/p-fill')

  reload()
  await expect.element(page.getByRole('button', { name: 'К списку заявок' }), T).toBeInTheDocument()

  window.history.back()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests')
  await expect.poll(() => rows().length, T).toBe(1)

  window.history.forward()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests/p-fill')
})

// ── M-015 · сайдбар ──────────────────────────────────────────────────────────
// ARS-785: «Входящие офферы» вышли из этого списка — раздел построен, у него свой экран и
// своя строка приёмки (mpk-offers-desktop.browser.test.tsx). M-015 продолжает утверждать
// ровно то же, что утверждал: непостроенные пункты честно сообщают о себе и не меняют URL.
// Их стало трое — счёт в названии поправлен, предмет строки не менялся.
it('M-015: «Мои заявки» ведут на экран, остальные три показывают подсказку и не меняют URL', async () => {
  store.pools = FIVE_POOLS()
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-side'), T).not.toBeNull()

  await page.getByRole('button', { name: 'Мои заявки' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests')
  await expect.poll(() => rows().length, T).toBe(5)

  for (const label of ['Главная', 'Маркет-борд', 'Документы сделок']) {
    await page.getByRole('button', { name: label }).click()
    await expect.poll(() => document.querySelector('.mpkc-soon')?.textContent?.trim(), T).toBe('Раздел в разработке')
    expect(window.location.pathname, `пункт «${label}» не должен менять URL`).toBe('/mpk/requests')
  }

  // Оба выхода из раздела: в консоль профиля и в мобильные закупки. Опечатка в адресе
  // («/mpk/profile» без таба, «/mpk/requests/profile») оставила бы оператора в тупике.
  await page.getByRole('button', { name: 'Профиль МПК' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/overview')
  await page.getByRole('button', { name: 'Мои заявки' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests')
  await page.getByRole('button', { name: /Вернуться в закупки/ }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

// ── M-017 · закрытая заявка ──────────────────────────────────────────────────
it('M-017: три причины закрытия названы по-своему — недобравшая не выглядит пустой', async () => {
  const cases: [string, string][] = [
    ['closed_unfilled', 'Заявка недобрала'],
    ['expired_empty', 'Заявка не набрала ни одной партии'],
    ['cancelled', 'Заявка отменена'],
  ]
  for (const [status, title] of cases) {
    // У всех трёх filledHeads = 0 — по числам они неразличимы, причину даёт только статус.
    store.pools = [makePool({ id: `p-${status}`, status, filledHeads: 0 })]
    mountAppAt(`/mpk/requests/p-${status}`)
    await expect.element(page.getByText(title), T).toBeInTheDocument()
    unmount()
  }
})

// ── M-018 · подметание при открытии ──────────────────────────────────────────
it('M-018: открытие списка зовёт rpc_self_close_due_pools ДО чтения, заявка видна в новом состоянии', async () => {
  store.pools = [makePool({ id: 'p-dec', status: 'awaiting_mpk_decision', filledHeads: 24 })]
  mountAppAt('/mpk/requests')
  await expect.poll(() => rows().length, T).toBe(1)

  const names = store.calls.map((c) => c.name)
  const sweep = names.indexOf('rpc_self_close_due_pools')
  const read = names.indexOf('rpc_get_my_pools')
  expect(sweep, 'подметание вызвано').toBeGreaterThanOrEqual(0)
  expect(sweep, 'подметание идёт до чтения списка').toBeLessThan(read)
})

// ── M-019 · создание заявки ──────────────────────────────────────────────────
it('M-019: заявка заведена с десктопа той же парой RPC и появилась во вкладке «Набираются»', async () => {
  mountAppAt('/mpk/requests')
  await expect.element(page.getByText('Заявок пока нет'), T).toBeInTheDocument()

  await page.getByRole('button', { name: 'Новая заявка' }).first().click()
  await page.getByLabelText('Общий объём закупа, голов').fill('220')
  await page.getByRole('button', { name: 'Следующий' }).click()
  await page.getByLabelText('Цена ₸/кг').first().fill('1700')
  await page.getByRole('button', { name: 'Опубликовать заявку' }).click()

  await expect.poll(() => store.calls.some((c) => c.name === 'rpc_self_create_pool_request'), T).toBe(true)
  await expect.poll(() => store.calls.some((c) => c.name === 'rpc_self_activate_pool_request'), T).toBe(true)
  const created = store.calls.find((c) => c.name === 'rpc_self_create_pool_request')
  expect(created?.args.p_total_heads, 'на запись уходят введённые числа').toBe(220)
  // Месяц поставки — первое число ВЫБРАННОГО месяца по локальному календарю. Без этой
  // проверки переход на `toISOString()` (UTC+5 откатывает дату на прошлый месяц) прошёл бы
  // зелёным, а заявка рождалась бы просроченной и закрывалась первым же подметанием.
  const next = new Date()
  next.setMonth(next.getMonth() + 1, 1)
  const expectedMonth = `${next.getFullYear()}-${String(next.getMonth() + 1).padStart(2, '0')}-01`
  expect(created?.args.p_target_month).toBe(expectedMonth)
  // Область не выбрана → «все области»: null, а не пустой массив (иначе матч сузится в ноль).
  expect(created?.args.p_region_ids).toBeNull()
  expect(created?.args.p_district_ids).toBeNull()
  expect(created?.args.p_accepted_skus).toEqual([
    { code: 'vysshaya', price: 1700, maxHeads: null, breed: null },
  ])

  await expect.poll(() => window.location.search, T).toBe('?tab=filling')
  await expect.poll(() => rows().length, T).toBe(1)
})

// ── M-020 · создание сорвалось ───────────────────────────────────────────────
it('M-020: активация отказала — названа причина, заявки в списке нет, повтор безопасен', async () => {
  store.failActivate = true
  mountAppAt('/mpk/requests')
  await expect.element(page.getByText('Заявок пока нет'), T).toBeInTheDocument()

  await page.getByRole('button', { name: 'Новая заявка' }).first().click()
  await page.getByLabelText('Общий объём закупа, голов').fill('220')
  await page.getByRole('button', { name: 'Следующий' }).click()
  await page.getByLabelText('Цена ₸/кг').first().fill('1700')
  await page.getByRole('button', { name: 'Опубликовать заявку' }).click()

  await expect.element(page.getByText(/ACTIVATION_FAILED/), T).toBeInTheDocument()
  expect(store.pools.length, 'неактивированная заявка пулом не становится').toBe(0)

  // Повтор: вторая попытка не плодит дублей в списке — список читается из базы.
  store.failActivate = false
  await page.getByRole('button', { name: 'Опубликовать заявку' }).click()
  await expect.poll(() => rows().length, T).toBe(1)
})

// ── ARS-691 · десктоп: плашка отказа и собственные тексты фронта ─────────────
// Спек `Docs/AGOS-TSP-MpkErrorText-ARS-691.md`. Здесь — точный текст плашки, а не регулярка
// по коду: `/ACTIVATION_FAILED/` находит и сырую строку базы, и «Код: …», и поэтому не
// различает старое и новое поведение.
const FALLBACK_PHRASE = 'Не удалось выполнить действие. Повторите или сообщите в поддержку.'
const flashBad = () => document.querySelector('.agos-mpk-console .mpkr-flash.bad')

async function openFormAndPublish() {
  mountAppAt('/mpk/requests')
  await expect.element(page.getByText('Заявок пока нет'), T).toBeInTheDocument()
  await page.getByRole('button', { name: 'Новая заявка' }).first().click()
  await page.getByLabelText('Общий объём закупа, голов').fill('220')
  await page.getByRole('button', { name: 'Следующий' }).click()
  await page.getByLabelText('Цена ₸/кг').first().fill('1700')
  await page.getByRole('button', { name: 'Опубликовать заявку' }).click()
}

it('ARS-691 M-007 · FR-004 · решение по заявке: незнакомый код — фраза и «Код: …» 12px цветом плашки', async () => {
  store.pools = [makePool({ id: 'p-dec', status: 'awaiting_mpk_decision', filledHeads: 24, totalHeads: 220 })]
  store.decisionErrorMessage = 'UNSETTLED_MATCHES: 2 allocations still pending'
  mountAppAt('/mpk/requests/p-dec')

  await expect.element(page.getByText('Нужно ваше решение').first(), T).toBeInTheDocument()
  await page.getByRole('button', { name: /Принять частично/ }).click()

  await expect.poll(() => flashBad()?.querySelector('.rpc-error-code')?.textContent ?? null, T).toBe('Код: UNSETTLED_MATCHES')
  const flash = flashBad()!
  expect(flash.textContent).toBe(FALLBACK_PHRASE + 'Код: UNSETTLED_MATCHES')
  const line = getComputedStyle(flash.querySelector('.rpc-error-code')!)
  expect(line.fontSize).toBe('12px')
  expect(line.opacity).toBe('1')
  expect(line.color).toBe(getComputedStyle(flash).color)
})

it('ARS-691 M-007 · заведение заявки: запуск отказал незнакомым кодом — общая фраза под префиксом и код отдельно', async () => {
  store.failActivate = true
  await openFormAndPublish()

  await expect.poll(() => flashBad()?.textContent ?? null, T)
    .toBe('Заявка не заведена: ' + FALLBACK_PHRASE + 'Код: ACTIVATION_FAILED')
})

it('ARS-691 M-011: создание отвергнуто FORBIDDEN — «Заявка не заведена: » + фраза прав, хвоста нет', async () => {
  store.createErrorMessage = 'FORBIDDEN: organization not owned by current user'
  await openFormAndPublish()

  await expect.poll(() => flashBad()?.textContent ?? null, T)
    .toBe('Заявка не заведена: У вашей учётной записи нет прав на это действие.')
})

it('ARS-691 M-014: запуск прошёл без pool_id — собственный текст фронта показан как есть', async () => {
  store.activateNoPoolId = true
  await openFormAndPublish()

  await expect.poll(() => flashBad()?.textContent ?? null, T)
    .toBe('Заявка не заведена: Заявка создана, но не опубликована (нет pool_id)')
})

it('ARS-691 M-010 · FR-013 (десктоп): база отказала без текста — запасная фраза fail() как есть', async () => {
  store.activateErrorMessage = ''
  await openFormAndPublish()

  await expect.poll(() => flashBad()?.textContent ?? null, T)
    .toBe('Заявка не заведена: Заявка создана, но не опубликована')
})
