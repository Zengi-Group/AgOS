// AgOS · ARS-731 · «Закрытие заявки подтверждает сделку в обеих формах записи» —
// UI-строки матрицы. Предмет: Docs/AGOS-TSP-PoolClose-ConfirmBothForms-ARS-731.md,
// раздел `## I/O & Edge-Case Matrix`, строки M-008, M-009, M-010.
//
// Один тест = одна строка матрицы, id в названии. Без этих тестов провал C-3/C-4
// неотличим от успеха до ручного взгляда на экран (§Verification спека).
//
// M-008/M-009 монтируют НАСТОЯЩЕЕ приложение по адресу `/mpk/requests/:id?view=suppliers`:
// так в кадр попадает и маппер (`pools-load.toSupplier` — дом различия состояний, FR-008),
// и десктопная поверхность (`RequestMonitor`). Тест над готовым `SupplierRow` проверял бы
// только вторую половину и пропустил бы ровно тот дефект, который чинит слайс, —
// схлопывание `active` в «ждёт отгрузки» происходит именно в маппере.
//
// M-010 монтирует `BatchScreen` напрямую: экран фермера «чистый», всё внешнее приходит
// пропсами; сетевой мок нужен лишь потому, что ядро шелла безусловно ходит в supabase.
//
// Запуск: npx vitest run --project routers
//
// @case TSPM-POOL-05 TSPF-LIFE-10
//   (qa/scenarios/ — «монитор заявки у МПК» и «жизненный цикл партии у фермера».
//   Теги вида M-NNN здесь намеренно не проставлены: M-008..M-010 — id СПЕКОВОЙ матрицы
//   ARS-731, а не qa/scenarios/, и те же номера заняты чужими слайсами.)

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import App from '@/App'
import { HostProvider } from '@/platform/host/HostContext'
import { BatchScreen } from '@/pages/cabinet/shell/screens/BatchScreen'
import { PoolMonitorModal } from '@/pages/cabinet/shell/mpk/modals/PoolMonitorModal'
import type { Pool, SupplierRow } from '@/pages/cabinet/shell/mpk/types'
import type { Batch } from '@/pages/cabinet/shell/types'

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
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'ars731-user', user_metadata: { full_name: 'Асхат Оператор' }, phone: '' }
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
      storage: { from: () => ({ list: async () => ok([]), createSignedUrl: async () => ok(null) }) },
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
              user_id: 'ars731-user',
              organizations: [{ id: 'org-1', name: 'МК «Семей Ет»', org_types: ['mpk'], is_primary: true, bin: '123456789012' }],
              farms: [], memberships: [],
            })
          case 'rpc_get_my_pools':
            return ok(store.pools)
          case 'rpc_get_pool_matches':
            return ok(store.matches)
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

/** Статус по умолчанию — `active`: ровно то, чем `rpc_get_pool_matches` отвечает для
 *  неподтверждённой сделки (ветка `else 'active'`, 20260910120000:90/159). */
function makeMatch(patch: Partial<RawMatch> & { matchId: string; batchId: string }): RawMatch {
  return {
    cat: 'bychki', grade: null, breed: 'Ангус', heads: 12, avgWeight: 430, price: 1700,
    region: 'Илийский район', status: 'active', matchedAt: '2026-09-05', confirmedAt: null,
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

function mountBatch(batch: Batch) {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(
    <HostProvider>
      <BatchScreen
        batch={batch}
        onBack={vi.fn()}
        onPatch={vi.fn()}
        onNew={vi.fn()}
        onReview={vi.fn()}
        onTuran={vi.fn()}
        toast={vi.fn()}
      />
    </HostProvider>,
  )
}

/** Мобильная поверхность монитора. FR-008 называет ОБЕ — десктопную и мобильную;
 *  тест только над `.mpkr-srow` проверял бы половину требования. */
function mountMonitor(suppliers: SupplierRow[]) {
  const pool: Pool = {
    id: '11111111-1111-1111-1111-111111111111',
    status: 'filled',
    title: 'Высшая · Тестовый район',
    region: 'Тестовый район',
    totalHeads: 100,
    filledHeads: 100,
    targetMonth: 'этот месяц',
    lines: [{ catKey: 'vysshaya', price: 1700 }],
    createdAt: '1 сен',
  }
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  root.render(
    <QueryClientProvider client={client}>
      <PoolMonitorModal
        pool={pool}
        onClose={vi.fn()}
        onPatch={vi.fn()}
        toast={vi.fn()}
        onContactTuran={vi.fn()}
        onLoadMatches={async () => suppliers}
      />
    </QueryClientProvider>,
  )
}

function makeSupplier(overrides: Partial<SupplierRow> = {}): SupplierRow {
  return {
    id: 's1', heads: 20, price: 1700, deliveryStatus: 'not_confirmed',
    farmName: 'КХ Тест', district: 'Тестовый район', batchId: 'batch-1', source: 'allocation',
    ...overrides,
  }
}

const T = { timeout: 15_000 }
const srowText = () =>
  Array.from(document.querySelectorAll('.mpkr-srow')).map((el) => el.textContent ?? '')
const acceptButtons = () =>
  Array.from(document.querySelectorAll('button')).filter(
    (b) => b.textContent?.includes('Подтвердить приёмку'),
  )

beforeEach(async () => {
  await page.viewport(1440, 900)
  expect(window.innerWidth, 'ширина раннера < 1024px — консоль подменяется мостом').toBeGreaterThanOrEqual(1024)
  store.pools = []
  store.matches = []
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

// ── M-008 · подпись неподтверждённой строки ──────────────────────────────────
it('ARS-731 M-008: заявка набирается, строка active — «Сделка ещё не подтверждена», кнопки приёмки нет', async () => {
  store.pools = [makePool({ id: 'p-fill', status: 'filling', filledHeads: 85 })]
  store.matches = [makeMatch({ matchId: 'alloc-1', batchId: 'b-1', status: 'active' })]
  mountAppAt('/mpk/requests/p-fill?view=suppliers')

  await expect.poll(() => srowText().length, T).toBe(1)
  expect(srowText()[0]).toContain('Сделка ещё не подтверждена')
  // Именно та ложь, которую чинит слайс: `active` выдавал себя за ждущего отгрузки.
  expect(srowText()[0], 'неподтверждённая сделка снова показана ждущей отгрузки')
    .not.toContain('Ожидает отгрузки')
  expect(acceptButtons(), 'у неподтверждённой строки есть ход приёмки — RPC его отвергнет').toHaveLength(0)
})

// ── M-009 · подписи остальных состояний ──────────────────────────────────────
it('ARS-731 M-009: confirmed/dispatched/delivered — свои подписи, кнопка приёмки только у «В пути»', async () => {
  store.pools = [makePool({ id: 'p-ship', status: 'closed_filled', filledHeads: 200, contactRevealed: true })]
  store.matches = [
    makeMatch({ matchId: 'a-conf', batchId: 'b-conf', status: 'confirmed', farmName: 'КХ Подтверждена' }),
    makeMatch({ matchId: 'a-disp', batchId: 'b-disp', status: 'dispatched', farmName: 'КХ В пути' }),
    makeMatch({ matchId: 'a-del', batchId: 'b-del', status: 'delivered', farmName: 'КХ Принята' }),
  ]
  mountAppAt('/mpk/requests/p-ship?view=suppliers')

  await expect.poll(() => srowText().length, T).toBe(3)
  const [conf, disp, del] = srowText()
  expect(conf).toContain('Ожидает отгрузки')
  expect(disp).toContain('В пути')
  expect(del).toContain('Принято')
  // Обе RPC приёмки требуют `dispatched` — ход есть ровно у одной строки из трёх.
  expect(acceptButtons()).toHaveLength(1)
})

it('ARS-731 M-009: значение вне четвёрки — «Состояние неизвестно», за известное не выдаётся, хода нет', async () => {
  store.pools = [makePool({ id: 'p-ship', status: 'closed_filled', filledHeads: 200, contactRevealed: true })]
  store.matches = [makeMatch({ matchId: 'a-x', batchId: 'b-x', status: 'какой-то_новый_статус' })]
  mountAppAt('/mpk/requests/p-ship?view=suppliers')

  await expect.poll(() => srowText().length, T).toBe(1)
  expect(srowText()[0]).toContain('Состояние неизвестно')
  expect(acceptButtons()).toHaveLength(0)
})

// ── M-008/M-009 · та же правда на МОБИЛЬНОЙ поверхности (FR-008) ──────────────
it('ARS-731 M-008: мобильный монитор, неподтверждённая строка — та же подпись, кнопки приёмки нет', async () => {
  mountMonitor([makeSupplier({ deliveryStatus: 'not_confirmed', farmName: 'КХ Неподтверждён' })])

  await expect.poll(() => document.body.textContent ?? '', T).toContain('Сделка ещё не подтверждена')
  // Прежнее молчание (`default: return ''`) выглядело точно так же, как строка без состояния.
  expect(acceptButtons(), 'у неподтверждённой строки мобильного монитора есть ход приёмки').toHaveLength(0)
})

it('ARS-731 M-009: мобильный монитор, значение вне четвёрки — «Состояние неизвестно», хода нет', async () => {
  mountMonitor([makeSupplier({ deliveryStatus: 'unknown', farmName: 'КХ Неизвестно' })])

  await expect.poll(() => document.body.textContent ?? '', T).toContain('Состояние неизвестно')
  expect(acceptButtons()).toHaveLength(0)
})

// ── M-010 · экран фермера при matched ────────────────────────────────────────
it('ARS-731 M-010: партия matched — видно, чего ждать; предупреждение о штрафе сохранено; хода отгрузки нет', async () => {
  mountBatch({
    id: 'b-1', state: 'matched', cat: 'bychki', breed: 'Ангус',
    heads: 30, avgWeight: 430, price: 1700, district: 'Илийский район',
  })

  // Текст говорит о факте, а не о процессе: `matched` достижим и при заявке в
  // awaiting_mpk_decision, где «набирается» было бы ложью (Spec Change Log, 2026-09-18).
  await expect.poll(() => document.body.textContent ?? '', T)
    .toContain('Покупатель ещё не закрыл заявку')
  expect(document.body.textContent, 'вернулась формулировка про процесс набора')
    .not.toContain('ещё набирается')
  const text = document.body.textContent ?? ''
  // HS-2 / FR-009: объяснение ДОБАВЛЕНО к предупреждению, а не заменило его.
  expect(text, 'предупреждение о штрафе исчезло вместе с добавлением объяснения')
    .toContain('Снятие может привести к штрафу')
  // MS4-BT-16: отгружать нечего, пока сделка не подтверждена.
  const dispatch = Array.from(document.querySelectorAll('button'))
    .filter((b) => b.textContent?.includes('Партия отгружена'))
  expect(dispatch, 'ход отгрузки открыт до подтверждения сделки').toHaveLength(0)
})
