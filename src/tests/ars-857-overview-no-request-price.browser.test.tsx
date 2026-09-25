// AgOS · ARS-857 · обзор заявки МПК без поля «Цена заявки» — браузерный тест.
//
// Предмет — Docs/AGOS-TSP-MpkOverviewNoRequestPrice-ARS-857.md, `## I/O & Edge-Case Matrix`.
// Один `it` = одна строка матрицы, id в названии с префиксом слайса (`ARS-857 M-NNN`).
//   десктоп (`/mpk/requests/<id>`, настоящий роутинг App): M-001…M-005;
//   телефон (`PoolMonitorModal`): M-006.
// Мутант: вернуть поле «Цена заявки» в обзор — падают M-001…M-004.
//
// Сетевая граница — единственный мок (как в ars-831-purchase-avg.browser.test.tsx).

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import App from '@/App'
import { PoolMonitorModal } from '@/pages/cabinet/shell/mpk/modals/PoolMonitorModal'
import { loadPoolMatches, readMyPools } from '@/pages/cabinet/shell/mpk/data/pools-load'
import type { Pool } from '@/pages/cabinet/shell/mpk/types'

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

const store = vi.hoisted(() => ({
  pools: [] as unknown[],
  matches: [] as unknown[],
  // Ответ `rpc_get_pool_matches`: очередь исходов по вызовам ('ok' | 'fail'), пусто — 'ok'.
  matchesPlan: [] as ('ok' | 'fail')[],
  // Удержание ответа: пока промис не разрешён, поставщики «загружаются» (M-003).
  matchesGate: null as Promise<void> | null,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-857-user', user_metadata: { full_name: 'Асхат Оператор' }, phone: '' }
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
              user_id: 'mpk-857-user',
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

const POOL_ID = '85785785-7857-4857-8857-857857857857'
const TWO_LINES = [{ code: 'vysshaya', price: 2000 }, { code: 'pervaya', price: 1800 }]
const ONE_LINE = [{ code: 'vysshaya', price: 1950 }]

function makePool(patch: Partial<RawPool> & { status: string }): RawPool {
  return {
    id: POOL_ID,
    totalHeads: 100,
    filledHeads: 100,
    region: 'Алматинская обл.',
    targetMonthIso: '2026-10-01',
    createdAtIso: '2026-09-01',
    lines: TWO_LINES,
    contactRevealed: false,
    minPoolHeads: 10,
    ...patch,
  }
}

let seq = 0
function makeMatch(heads: number, price: number | null, avgWeight: number | null) {
  seq += 1
  return {
    matchId: `m-${seq}`, batchId: `b-${seq}`, cat: 'bychki', grade: null, breed: 'Ангус',
    heads, avgWeight, price, region: 'Илийский район', status: 'confirmed',
    matchedAt: '2026-09-05', confirmedAt: null, dispatchedAt: null, deliveredAt: null,
    farmName: null, farmPhone: null, myRating: null, source: 'allocation',
  }
}
/** Поставщики примера владельца: 80 × 2 000 и 20 × 2 100 при 400 кг → 2 020 ₸/кг. */
const OWNER_MATCHES = () => [makeMatch(80, 2000, 400), makeMatch(20, 2100, 400)]

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

async function mountPhone() {
  const r = await readMyPools()
  const pool: Pool | undefined = r.kind === 'ok' ? r.pools[0] : undefined
  if (!pool) throw new Error('фикстура заявок не прочиталась')
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  mount(
    <QueryClientProvider client={client}>
      <PoolMonitorModal
        pool={pool} onClose={vi.fn()} onPatch={vi.fn()} toast={vi.fn()} onContactTuran={vi.fn()}
        onLoadMatches={loadPoolMatches}
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
const plain = (s: string | null | undefined) => (s ?? '').replace(/ /g, ' ').replace(/\s+/g, ' ').trim()

/** Подписи полей обзора десктопа по порядку. */
function fieldLabels(): string[] {
  return Array.from(document.querySelectorAll('.agos-mpk-console .mpkr-field .mpkr-field-l'))
    .map((el) => plain(el.textContent))
}

/** Значение поля обзора десктопа по подписи; null — поля нет. */
function field(label: string): string | null {
  const all = Array.from(document.querySelectorAll('.agos-mpk-console .mpkr-field'))
  const f = all.find((el) => plain(el.querySelector('.mpkr-field-l')?.textContent) === label)
  return f ? plain(f.querySelector('.mpkr-field-v')?.textContent) : null
}

/** Блок «Категории заявки»: «<категория> <цена>» по строкам. */
function categoryLines(): string[] {
  return Array.from(document.querySelectorAll('.agos-mpk-console .mpkr-lines .mpkr-line'))
    .map((row) => Array.from(row.children).map((c) => plain(c.textContent)).join(' '))
}

function consoleText(): string {
  return plain(document.querySelector('.agos-mpk-console')?.textContent)
}

/** Поля «Цена заявки» и подписи «средняя по строкам» на обзоре нет (FR-002). */
function expectNoRequestPrice(msg: string) {
  expect(field('Цена заявки'), msg).toBeNull()
  expect(consoleText(), msg).not.toContain('средняя по строкам')
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

it('ARS-857 M-001: пример владельца — поля по порядку без «Цены заявки», числа 1 900 нет, цены категорий видны', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = OWNER_MATCHES()
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('2 020 ₸/кг')
  expect(fieldLabels()).toEqual([
    'Набрано', 'Средняя закупочная', 'Срок поставки', 'География', 'Минимум для закупки', 'Заявка создана',
  ])
  expectNoRequestPrice('M-001')
  expect(consoleText(), 'числа 1 900 на обзоре нет').not.toContain('1 900')
  expect(categoryLines()).toEqual(['КРС · Высшая 2 000 ₸/кг', 'КРС · Первая 1 800 ₸/кг'])
})

it('ARS-857 M-002: одна категория, заявка набирается, поставщиков нет — поля нет, цена категории видна', async () => {
  store.pools = [makePool({ status: 'filling', filledHeads: 0, lines: ONE_LINE })]
  store.matches = []
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  await expect.poll(() => field('Средняя закупочная'), T).toBe('пока нет сделок')
  expectNoRequestPrice('M-002')
  expect(categoryLines()).toEqual(['КРС · Высшая 1 950 ₸/кг'])
})

it('ARS-857 M-003: поставщики загружаются · загрузка не удалась → «Повторить» — поля нет ни в одном состоянии', async () => {
  let release = () => {}
  store.matchesGate = new Promise<void>((r) => { release = r })
  store.matchesPlan = ['fail']
  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = OWNER_MATCHES()
  mountDesktop(`/mpk/requests/${POOL_ID}`)

  // загружаются
  await expect.poll(() => field('Средняя закупочная'), T).toBe('считается…')
  expectNoRequestPrice('M-003 · загружаются')
  expect(categoryLines()).toEqual(['КРС · Высшая 2 000 ₸/кг', 'КРС · Первая 1 800 ₸/кг'])

  // загрузка не удалась
  store.matchesGate = null
  release()
  await expect.poll(() => field('Средняя закупочная'), T).toBe('не удалось посчитатьПовторить')
  expectNoRequestPrice('M-003 · не удалось')
  expect(categoryLines()).toEqual(['КРС · Высшая 2 000 ₸/кг', 'КРС · Первая 1 800 ₸/кг'])

  // «Повторить» → число, поля по-прежнему нет
  await page.getByRole('button', { name: 'Повторить' }).click()
  await expect.poll(() => field('Средняя закупочная'), T).toBe('2 020 ₸/кг')
  expectNoRequestPrice('M-003 · после «Повторить»')
})

it('ARS-857 M-004: заявка с каждой вкладки — поля нет, цены категорий видны; у «Не состоялись» нет и закупочной', async () => {
  const live: [string, number][] = [
    ['filling', 40],
    ['awaiting_mpk_decision', 40],
    ['closed_filled', 100],
    ['completed', 100],
  ]
  for (const [status, filledHeads] of live) {
    store.pools = [makePool({ status, filledHeads })]
    store.matches = OWNER_MATCHES()
    mountDesktop(`/mpk/requests/${POOL_ID}`)
    await expect.poll(() => field('Средняя закупочная'), T).toBe('2 020 ₸/кг')
    expectNoRequestPrice(status)
    expect(categoryLines(), status).toEqual(['КРС · Высшая 2 000 ₸/кг', 'КРС · Первая 1 800 ₸/кг'])
    unmount()
  }

  // Блок причины закрытия — как до слайса: заголовок и текст причины (тексты — requests-model.ts).
  const failed: [string, string, string][] = [
    ['closed_unfilled', 'Заявка недобрала', 'Набранного не хватило для закупки — партии вернулись поставщикам на рынок.'],
    ['expired_empty', 'Заявка не набрала ни одной партии', 'За время действия заявки к ней не привязалась ни одна партия.'],
    ['cancelled', 'Заявка отменена', 'Заявку отменили — набор по ней не ведётся.'],
    ['closed', 'Заявка закрыта', 'Заявка закрыта вручную — набор по ней не ведётся.'],
  ]
  for (const [status, title, note] of failed) {
    store.pools = [makePool({ status, filledHeads: 0 })]
    store.matches = [makeMatch(80, 2000, 400)]
    mountDesktop(`/mpk/requests/${POOL_ID}`)
    await expect.element(page.getByText(title, { exact: true }), T).toBeInTheDocument()
    expect(plain(document.querySelector('.agos-mpk-console .mpkr-act.closed .mpkr-act-n')?.textContent), status).toBe(note)
    expectNoRequestPrice(status)
    expect(field('Средняя закупочная'), status).toBeNull()
    expect(categoryLines(), status).toEqual(['КРС · Высшая 2 000 ₸/кг', 'КРС · Первая 1 800 ₸/кг'])
    unmount()
  }
}, 60_000)

it('ARS-857 M-005: список — колонка «Цена заявки», «1 900 ₸/кг» и подпись «средняя» как до слайса', async () => {
  store.pools = [makePool({ status: 'closed_filled' })]
  mountDesktop('/mpk/requests')

  await expect.poll(() => document.querySelectorAll('.agos-mpk-console .mpkr-row').length, T).toBe(1)
  const head = Array.from(document.querySelectorAll('.agos-mpk-console .mpkr-head .mpkr-cell')).map((c) => plain(c.textContent))
  expect(head).toContain('Цена заявки')
  const row = document.querySelector('.agos-mpk-console .mpkr-row')
  expect(plain(row?.querySelector('.mpkr-price')?.textContent)).toBe('1 900 ₸/кг')
  expect(plain(row?.textContent)).toContain('средняя')
})

// ── телефон ───────────────────────────────────────────────────────────────────

it('ARS-857 M-006: телефон — набранная «Средняя закупочная 2 020 ₸/кг»; набирающаяся — категория и «пока нет сделок»', async () => {
  const phoneText = () => plain(document.body.textContent)

  store.pools = [makePool({ status: 'closed_filled' })]
  store.matches = OWNER_MATCHES()
  await mountPhone()
  await expect.poll(phoneText, T).toContain('Средняя закупочная 2 020 ₸/кг')
  unmount()

  store.pools = [makePool({ status: 'filling', filledHeads: 0, lines: ONE_LINE })]
  store.matches = []
  await mountPhone()
  await expect.poll(phoneText, T).toContain('Средняя закупочная пока нет сделок')
  expect(phoneText()).toContain('КРС · Высшая: 1 950 ₸/кг')
})
