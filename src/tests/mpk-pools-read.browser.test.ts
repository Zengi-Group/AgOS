// AgOS · ARS-687 · Исход чтения заявок МПК: «пусто» ≠ «не прочитали» (readMyPools).
// Предмет — Docs/AGOS-TSP-MarketBoard-RequirePool-ARS-687.md, `FR-009` и строки матрицы
// M-004 / M-012 / M-013.
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. mpk-market-board-offer.browser.test.tsx — дом покрытия самой
// МОДАЛКИ, и он подаёт `poolsState` литералом пропа, а supabase у него замокан на throw.
// Значит он доказуемо не исполняет код, который РЕШАЕТ, в какое из состояний попадёт
// приложение. Свернуть классификацию обратно в один исход (как было до ARS-687, когда
// loadMyPools отдавал `Pool[] | null`) — и тот файл остался бы зелёным, а реальному
// оператору в селектор вернулись бы seed-демо заявки. Этот файл закрывает именно ту границу.
//
// Проект `routers` (браузерный) выбран не из-за DOM — его здесь нет, — а потому что проект
// `unit` включает только `src/platform/**` (vite.config.ts), то есть другого дома для
// теста модуля из `src/pages/**` в репозитории нет.
//
// @case-тегов нет намеренно — см. шапку mpk-market-board-offer.browser.test.tsx.

import { beforeEach, expect, it, vi } from 'vitest'
import { readMyPools, nextPoolsRead } from '@/pages/cabinet/shell/mpk/data/pools-load'
import type { PoolsRead } from '@/pages/cabinet/shell/mpk/types'

// Оба обращения, которые делает readMyPools, — под контролем теста: rpc за списком и
// auth.getSession за различением «аноним» / «не смогли».
const rpc = vi.fn()
const getSession = vi.fn()

vi.mock('@/lib/supabase', () => ({
  supabase: {
    rpc: (fn: string, args: unknown) => rpc(fn, args),
    auth: { getSession: () => getSession() },
  },
}))

const RAW_POOL = {
  id: '11111111-1111-4111-8111-111111111111',
  status: 'filling',
  totalHeads: 100,
  filledHeads: 10,
  region: 'Тестовый район',
  targetMonthIso: null,
  createdAtIso: null,
  lines: [{ code: 'vysshaya', price: 1700 }],
  contactRevealed: false,
}

const SESSION = { data: { session: { access_token: 't' } }, error: null }
const NO_SESSION = { data: { session: null }, error: null }

beforeEach(() => {
  rpc.mockReset()
  getSession.mockReset()
})

it('ARS-687 FR-009: rpc отдал массив — исход ok, список смаплен (getSession не нужен)', async () => {
  rpc.mockResolvedValue({ data: [RAW_POOL], error: null })

  const r = await readMyPools()

  expect(r.kind).toBe('ok')
  expect(r.kind === 'ok' && r.pools.length).toBe(1)
  expect(r.kind === 'ok' && r.pools[0]!.id).toBe(RAW_POOL.id)
  expect(rpc).toHaveBeenCalledWith('rpc_get_my_pools', {})
  expect(getSession).not.toHaveBeenCalled()
})

it('ARS-687 FR-009: rpc отказал, сессия есть — исход failed (а не «заявок нет» и не демо-фолбэк)', async () => {
  rpc.mockResolvedValue({ data: null, error: { message: 'permission denied' } })
  getSession.mockResolvedValue(SESSION)

  expect((await readMyPools()).kind).toBe('failed')
})

it('ARS-687 FR-009: rpc отказал, сессии нет и стор ответил без ошибки — исход no_session (демо-шелл как до ARS-687)', async () => {
  rpc.mockResolvedValue({ data: null, error: { message: 'JWT missing' } })
  getSession.mockResolvedValue(NO_SESSION)

  expect((await readMyPools()).kind).toBe('no_session')
})

// Это не перестраховка: @supabase/auth-js внутри EXPIRY_MARGIN_MS (90с до истечения) уходит
// в СЕТЬ за refresh и при её недоступности отдаёт `{ session: null, error }`. Реальный
// оператор в оффлайне с почти истёкшим токеном не должен попасть в демо-фолбэк (FR-009).
it('ARS-687 FR-009: getSession вернул ошибку (не смогли обновить токен) — исход failed, не no_session', async () => {
  rpc.mockResolvedValue({ data: null, error: { message: 'JWT expired' } })
  getSession.mockResolvedValue({ data: { session: null }, error: { message: 'network error' } })

  expect((await readMyPools()).kind).toBe('failed')
})

it('ARS-687 FR-009: rpc бросил, а стор сессии недоступен — исход failed, не no_session', async () => {
  rpc.mockRejectedValue(new Error('network down'))
  getSession.mockRejectedValue(new Error('storage blocked'))

  expect((await readMyPools()).kind).toBe('failed')
})

it('ARS-687 FR-009: rpc ответил без ошибки, но не массивом, сессия есть — исход failed', async () => {
  rpc.mockResolvedValue({ data: { oops: true }, error: null })
  getSession.mockResolvedValue(SESSION)

  expect((await readMyPools()).kind).toBe('failed')
})

// ── исход чтения → состояние экрана (nextPoolsRead) ───────────────────────────────────

it('ARS-687 M-012/M-013: до первого успеха «не прочитали» доезжает как failed, а «нет сессии» — как ready', () => {
  expect(nextPoolsRead('loading', { kind: 'failed' })).toBe('failed')
  expect(nextPoolsRead('loading', { kind: 'no_session' })).toBe('ready')
  expect(nextPoolsRead('failed', { kind: 'failed' })).toBe('failed')
})

it('ARS-687 FR-009: успешное чтение всегда даёт ready — из любого состояния', () => {
  const from: PoolsRead[] = ['loading', 'ready', 'failed']
  for (const cur of from) {
    expect(nextPoolsRead(cur, { kind: 'ok', pools: [] })).toBe('ready')
  }
})

// «Не загрузился» — про то, что список не прочитан НИ РАЗУ. Отказ поллинга (20с) после
// успешного чтения не отбрасывает оператора назад: список у него уже есть, и селектор с
// выбранной заявкой не должен исчезать из-за транзиентного сбоя.
it('ARS-687 FR-009: отказ ПОСЛЕ успешного чтения не возвращает экран в «не загрузился»', () => {
  expect(nextPoolsRead('ready', { kind: 'failed' })).toBe('ready')
  expect(nextPoolsRead('ready', { kind: 'no_session' })).toBe('ready')
})
