// AgOS · ARS-831 · «Средняя закупочная» на двух поверхностях — браузерный тест.
//
// Предмет — Docs/AGOS-TSP-MpkPurchaseAvgPrice-ARS-831.md, `## I/O & Edge-Case Matrix`.
// Один `it` = одна строка матрицы, id в названии с префиксом слайса (`ARS-831 M-NNN`), чтобы
// не совпасть с одноимёнными id соседних спеков.
//   десктоп (`/mpk/requests/<id>`, настоящий роутинг App): M-001, M-003, M-005, M-006, M-007,
//     M-010, M-012, M-014;
//   телефон (`PoolMonitorModal`): M-009, M-011, M-012, M-013, M-014;
//   M-008 — одна фикстура набранной заявки на обеих поверхностях, числа сверены между собой.
// Формула сама по себе — `ars-831-purchase-avg-model.browser.test.ts`.
//
// Сетевая граница — единственный мок. Телефон читает строки тем же `loadPoolMatches`, что и
// шелл, через тот же мок `rpc_get_pool_matches`: у обеих поверхностей один путь от фикстуры
// до экрана, и M-008 сравнивает экраны, а не две копии входа.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import App from '@/App'
import { PoolMonitorModal } from '@/pages/cabinet/shell/mpk/modals/PoolMonitorModal'
import { loadPoolMatches, readMyPools } from '@/pages/cabinet/shell/mpk/data/pools-load'
import type { Pool, SupplierRow } from '@/pages/cabinet/shell/mpk/types'

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
  heads: number; avgWeight: number | null; price: number | null; region: string; status: string
  matchedAt: string | null; confirmedAt: string | null; dispatchedAt: string | null
  deliveredAt: string | null; farmName: string | null; farmPhone: string | null
  myRating: number | null; source: string
}

const store = vi.hoisted(() => ({
  pools: [] as unknown[],
  matches: [] as unknown[],
  // Ответ `rpc_get_pool_matches`: очередь исходов по вызовам ('ok' | 'fail'), пусто — 'ok'.
  matchesPlan: [] as ('ok' | 'fail')[],
  // Удержание ответа: пока промис не разрешён, строки «читаются» (M-006).
  matchesGate: null as Promise<void> | null,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-831-user', user_metadata: { full_name: 'Асхат Оператор' }, phone: '' }
  const session = { access_token: 't', refresh_token: 't', token_type: 'bearer', expires_in: 3600, user }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: null }) as Promise<unknown> & Record<string, unknown>
    for (const m of ['select', 'eq', 'order', 'limit', 'single', 'maybeSingle']) q[m] = () => q
    return q
  }
  const ok = (data: unknown) => ({ data, error: null })
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
      rpc: async (name: string) => {
        switch (name) {
          case 'rpc_get_my_context':
            return ok({
              user_id: 'mpk-831-user',
              organizations: [{ id: 'org-1', name: 'МК «Семей Ет»', org_types: ['mpk'], is_primary: true, bin: '123456789012' }],
              farms: [], memberships: [],
            })
          case 'rpc_get_my_pools':
            return ok(store.pools)
          case 'rpc_get_pool_matches': {
            if (store.matchesGate) await store.matchesGate
            const outcome = store.matchesPlan.shift() ?? 'ok'
            if (outcome === 'fail') return { data: null, error: { message: 'rpc недоступна' } }
            return ok(store.matches)
          }
          default:
            return ok(null)
        }
      },
    },
  }
})

const POOL_ID = '83183183-1831-4831-8831-831831831831'

function makePool(patch: Partial<RawPool> & { status: string }): RawPool {
  return {
    id: POOL_ID,
    totalHeads: 100,
    filledHeads: 100,
    region: 'Алматинская обл.',
    targetMonthIso: '2026-10-01',
    createdAtIso: '2026-09-01',
    // Заявка владельца (замер 25.09): строки 2 000 и 1 800 → «цена заявки» 1 900.
    lines: [{ code: 'vysshaya', price: 2000 }, { code: 'pervaya', price: 1800 }],
    contactRevealed: false,
    minPoolHeads: 10,
    ...patch,
  }
}

let seq = 0
function makeMatch(heads: number, price: number | null, avgWeight: number | null): RawMatch {
  seq += 1
  return {
    matchId: `m-${seq}`, batchId: `b-${seq}`, cat: 'bychki', grade: null, breed: 'Ангус',
    heads, avgWeight, price, region: 'Илийский район', status: 'confirmed',
    matchedAt: '2026-09-05', confirmedAt: null, dispatchedAt: null, deliveredAt: null,
    farmName: null, farmPhone: null, myRating: null, source: 'allocation',
  }
}

let root: Root | null = null
let mountEl: HTMLElement | null = null
const initialUrl = window.location.pathname + window.location.search

function mount(node: React.ReactNode) {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(node)
}

function mountDesktop(path: string) {
  window.history.replaceState(null, '', path)
  mount(<App />)
}

/** Телефон: заявка — тем же `readMyPools` (схлопывание статусов шелла), строки — тем же
 *  `loadPoolMatches`, что у шелла. */
async function mountPhone(onLoadMatches: (id: string) => Promise<SupplierRow[] | null> = loadPoolMatches) {
  const r = await readMyPools()
  const pool: Pool | undefined = r.kind === 'ok' ? r.pools[0] : undefined
  if (!pool) throw new Error('фикстура заявок не прочиталась')
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  mount(
    <QueryClientProvider client={client}>
      <PoolMonitorModal
        pool={pool} onClose={vi.fn()} onPatch={vi.fn()} toast={vi.fn()} onContactTuran={vi.fn()}
        onLoadMatches={onLoadMatches}
      />
    </QueryClientProvider>,
  )
}

function unmount() {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
}

const T = { timeout: 15_000 }
const plain = (s: string | null | undefined) => (s ?? '').replace(/ /g, ' ').replace(/\s+/g, ' ').trim()

/** Значение поля обзора десктопа по подписи; null — поля нет. */
function field(label: string): string | null {
  const all = Array.from(document.querySelectorAll('.agos-mpk-console .mpkr-field'))
  const f = all.find((el) => plain(el.querySelector('.mpkr-field-l')?.textContent) === label)
  return f ? plain(f.querySelector('.mpkr-field-v')?.textContent) : null
}

/** Строка закупочной в телефоне (без подписи); null — строки нет. */
function phonePurchase(): string | null {
  const el = Array.from(document.querySelectorAll('.pool-card-sub'))
    .find((e) => plain(e.textContent).startsWith('Средняя закупочная'))
  return el ? plain(el.textContent).replace(/^Средняя закупочная\s*/, '') : null
}

beforeEach(async () => {
  await page.viewport(1440, 900)
  store.pools = []
  store.matches = []
  store.matchesPlan = []
  store.matchesGate = null
})

afterEach(() => {
  unmount()
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

// ── десктоп ───────────────────────────────────────────────────────────────────

it('ARS-831 M-001: десктоп, пример владельца — «Средняя закупочная 2 020 ₸/кг», «Цена заявки» как была', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = [makeMatch(80, 2000, 400), makeMatch(20, 2100, 400)]
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('2 020 ₸/кг')
  expect(field('Цена заявки')).toBe('1 900 ₸/кг · средняя по строкам')
  expect(field('Цена'), 'прежней подписи «Цена» больше нет').toBeNull()
})

it('ARS-831 M-003: десктоп, у строки нет веса — «2 020 ₸/кг · по головам»', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = [makeMatch(80, 2000, 400), makeMatch(20, 2100, null)]
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('2 020 ₸/кг · по головам')
})

it('ARS-831 M-005: десктоп, заявка набирается и поставщиков нет — «пока нет сделок», цена заявки видна', async () => {
  store.pools = [makePool({ status: 'filling', filledHeads: 0 })]
  store.matches = []
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('пока нет сделок')
  expect(field('Цена заявки')).toBe('1 900 ₸/кг · средняя по строкам')
})

it('ARS-831 M-006: десктоп, строки ещё читаются — «считается…», не 0 и не «пока нет сделок»', async () => {
  let release = () => {}
  store.matchesGate = new Promise<void>((r) => { release = r })
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = [makeMatch(80, 2000, 400), makeMatch(20, 2100, 400)]
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('считается…')
  release()
  await expect.poll(() => field('Средняя закупочная'), T).toBe('2 020 ₸/кг')
})

it('ARS-831 M-007: десктоп, чтение отказало — «не удалось посчитать» + «Повторить»; повтор перечитывает → число', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = [makeMatch(80, 2000, 400), makeMatch(20, 2100, 400)]
  store.matchesPlan = ['fail']
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('не удалось посчитатьПовторить')
  expect(field('Цена заявки')).toBe('1 900 ₸/кг · средняя по строкам')
  // Отказ виден и во вкладке «Поставщики» — состояние числа = состояние списка (FR-004).
  await page.getByRole('tab', { name: 'Поставщики' }).click()
  await expect.element(page.getByText('Поставщики не загрузились'), T).toBeInTheDocument()
  await page.getByRole('tab', { name: 'Обзор' }).click()

  // Повторное чтение тоже «считается…» (FR-004: «первое или повторное»).
  let release = () => {}
  store.matchesGate = new Promise<void>((r) => { release = r })
  await page.getByRole('button', { name: 'Повторить' }).click()
  await expect.poll(() => field('Средняя закупочная'), T).toBe('считается…')
  release()
  await expect.poll(() => field('Средняя закупочная'), T).toBe('2 020 ₸/кг')
})

it('ARS-831 M-010: список — колонка «Цена заявки», число и подпись «средняя» как раньше', async () => {
  store.pools = [makePool({ status: 'filling', filledHeads: 40 })]
  mountDesktop('/mpk/requests')

  await expect.poll(() => document.querySelectorAll('.agos-mpk-console .mpkr-row').length, T).toBe(1)
  const head = Array.from(document.querySelectorAll('.agos-mpk-console .mpkr-head .mpkr-cell')).map((c) => plain(c.textContent))
  expect(head).toContain('Цена заявки')
  expect(head).not.toContain('Цена')
  const row = document.querySelector('.agos-mpk-console .mpkr-row')
  expect(plain(row?.querySelector('.mpkr-price')?.textContent)).toBe('1 900 ₸/кг')
  expect(plain(row?.textContent)).toContain('средняя')
  expect(plain(row?.textContent), 'закупочной в списке нет (FR-009)').not.toContain('закупочная')
})

it('ARS-831 M-012: десктоп, у поставщика нет цены — «нельзя посчитать…», в строке «—», нигде не 0', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = [makeMatch(80, 2000, 400), makeMatch(20, null, 400)]
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('нельзя посчитать: у поставщика нет цены')

  await page.getByRole('tab', { name: 'Поставщики' }).click()
  await expect.poll(() => document.querySelectorAll('.agos-mpk-console .mpkr-srow').length, T).toBe(2)
  const prices = Array.from(document.querySelectorAll('.agos-mpk-console .mpkr-srow'))
    .map((r) => plain(r.children[2]?.textContent))
  expect(prices).toEqual(['2 000 ₸/кг', '—'])
})

it('ARS-831 M-014: десктоп, заявка не состоялась — поля закупочной нет, блок причины как был', async () => {
  const cases: [string, string][] = [
    ['closed_unfilled', 'Заявка недобрала'],
    ['expired_empty', 'Заявка не набрала ни одной партии'],
    ['cancelled', 'Заявка отменена'],
    ['closed', 'Заявка закрыта'],
  ]
  for (const [status, title] of cases) {
    // Строки поставщиков есть (у ручного `closed` они не освобождаются) — поле всё равно скрыто.
    store.pools = [makePool({ status, filledHeads: 0 })]
    store.matches = [makeMatch(80, 2000, 400)]
    mountDesktop(`/mpk/requests/${POOL_ID}`)
    await expect.element(page.getByText(title, { exact: true }), T).toBeInTheDocument()
    expect(field('Цена заявки'), status).toBe('1 900 ₸/кг · средняя по строкам')
    expect(field('Средняя закупочная'), status).toBeNull()
    expect(plain(document.body.textContent), status).not.toContain('закупочная')
    unmount()
  }
})

// ── телефон ───────────────────────────────────────────────────────────────────

it('ARS-831 M-009: телефон, сделка завершена — «100 гол · средняя закупочная 2 029 ₸/кг · сумма ≈ 69 000 000 ₸»', async () => {
  store.pools = [makePool({ status: 'completed', filledHeads: 100 })]
  store.matches = [makeMatch(80, 2000, 300), makeMatch(20, 2100, 500)]
  await mountPhone()

  const line = () => Array.from(document.querySelectorAll('.pool-card-sub'))
    .map((e) => plain(e.textContent)).find((t) => t.startsWith('100 гол')) ?? null
  await expect.poll(line, T).toBe('100 гол · средняя закупочная 2 029 ₸/кг · сумма ≈ 69 000 000 ₸')
  expect(plain(document.body.textContent), 'прежней «ср. цена» нет').not.toContain('ср. цена')
})

it('ARS-831 M-011: телефон, ветка набора — считается… · не удалось посчитать · пока нет сделок · число по прежним строкам', async () => {
  store.pools = [makePool({ status: 'filling', filledHeads: 40 })]
  const rows: SupplierRow[] = [
    { id: 'a', heads: 80, price: 2000, avgWeight: 400, deliveryStatus: 'not_confirmed' },
    { id: 'b', heads: 20, price: 2100, avgWeight: 400, deliveryStatus: 'not_confirmed' },
  ]

  // первое чтение идёт
  await mountPhone(() => new Promise<SupplierRow[] | null>(() => {}))
  await expect.poll(phonePurchase, T).toBe('считается…')
  unmount()

  // первое чтение отказало
  await mountPhone(async () => null)
  await expect.poll(phonePurchase, T).toBe('не удалось посчитать')
  unmount()

  // прочитано и пусто
  await mountPhone(async () => [])
  await expect.poll(phonePurchase, T).toBe('пока нет сделок')
  expect(plain(document.body.textContent)).toContain('Поставщиков пока нет')
  unmount()

  // опрос (раз в 8 с) отказал после показанных строк — число по прежним строкам
  let call = 0
  await mountPhone(async () => { call += 1; return call === 1 ? rows : null })
  await expect.poll(phonePurchase, T).toBe('2 020 ₸/кг')
  await expect.element(page.getByText('Не удалось обновить список'), { timeout: 20_000 }).toBeInTheDocument()
  expect(phonePurchase()).toBe('2 020 ₸/кг')
}, 40_000)

it('ARS-831 M-012: телефон, у поставщика нет цены — «нельзя посчитать…», в строке «—», нигде не 0', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = [makeMatch(80, 2000, 400), makeMatch(20, null, 400)]
  await mountPhone()

  await expect.poll(phonePurchase, T).toBe('нельзя посчитать: у поставщика нет цены')
  const lines = Array.from(document.querySelectorAll('.supplier-row .supplier-row-s'))
    .map((e) => plain(e.textContent)).filter((t) => t.includes(' гол'))
  expect(lines).toEqual(['80 гол · ~400 кг · 2 000 ₸/кг · ≈ 64 000 000 ₸', '20 гол · ~400 кг · —'])
})

it('ARS-831 M-013: телефон, по головам рядом с суммой — «… 2 020 ₸/кг · по головам · сумма ≈ 64 000 000 ₸»', async () => {
  store.pools = [makePool({ status: 'completed', filledHeads: 100 })]
  store.matches = [makeMatch(80, 2000, 400), makeMatch(20, 2100, null)]
  await mountPhone()

  const line = () => Array.from(document.querySelectorAll('.pool-card-sub'))
    .map((e) => plain(e.textContent)).find((t) => t.startsWith('100 гол')) ?? null
  await expect.poll(line, T).toBe('100 гол · средняя закупочная 2 020 ₸/кг · по головам · сумма ≈ 64 000 000 ₸')
})

it('ARS-831 M-014: телефон, заявка не состоялась — строки закупочной нет, «Заявка закрыта» как была', async () => {
  for (const status of ['closed_unfilled', 'expired_empty', 'cancelled', 'closed']) {
    store.pools = [makePool({ status, filledHeads: 0 })]
    store.matches = [makeMatch(80, 2000, 400)]
    await mountPhone()
    await expect.element(page.getByText('Заявка закрыта', { exact: true }), T).toBeInTheDocument()
    expect(plain(document.body.textContent), status).not.toContain('закупочная')
    unmount()
  }
})

// ── одна фикстура на двух поверхностях ────────────────────────────────────────

it('ARS-831 M-008: набранная заявка (closed_filled) — на десктопе и в телефоне одно число и тот же признак расчёта', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = [makeMatch(80, 2000, 300), makeMatch(20, 2100, null)]

  mountDesktop(`/mpk/requests/${POOL_ID}`)
  await expect.poll(() => field('Средняя закупочная'), T).toMatch(/₸\/кг/)
  const desktop = field('Средняя закупочная')
  unmount()

  await mountPhone()
  await expect.poll(phonePurchase, T).toMatch(/₸\/кг/)
  const phone = phonePurchase()

  expect(desktop).toBe('2 020 ₸/кг · по головам')
  expect(phone).toBe(desktop)
})
