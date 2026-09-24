// AgOS · ARS-785 · Исход чтения входящих офферов: «офферов нет» ≠ «не прочитали».
// Предмет — Docs/AGOS-TSP-IncomingOffers-Desktop-A-ARS-785.md, §Приёмка, строки
// `mpk-offers-read.browser.test.ts`.
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ (тот же довод, что у mpk-pools-read.browser.test.ts): экранный тест
// подаёт состояние пропом, то есть доказуемо НЕ исполняет код, который решает, в какое из
// трёх состояний попадёт раздел. Свернуть классификацию обратно в один исход — как её и
// отдаёт старый loadIncomingOffers (`IncomingOffer[] | null`) — и экранный тест остался бы
// зелёным, а оператору сбой сети показался бы пустым рынком: ровно то, против чего слайс.
//
// Проект `routers` (браузерный) выбран не из-за DOM — его здесь нет, — а потому что проект
// `unit` включает только `src/platform/**` (vite.config.ts), то есть другого дома для
// теста модуля из `src/pages/**` в репозитории нет.

import { beforeEach, expect, it, vi } from 'vitest'
import { readIncomingOffers } from '@/pages/cabinet/shell/mpk/data/offers-load'
import { sortByDeadline } from '@/pages/cabinet/shell/mpk/offers/offers-model'
import type { IncomingOffer } from '@/pages/cabinet/shell/mpk/types'

// Оба обращения, которые делает readIncomingOffers, — под контролем теста: rpc за списком
// и auth.getSession за различением «аноним» / «не смогли».
const rpc = vi.fn()
const getSession = vi.fn()

vi.mock('@/lib/supabase', () => ({
  supabase: {
    rpc: (fn: string, args: unknown) => rpc(fn, args),
    auth: { getSession: () => getSession() },
  },
}))

const rawOffer = (id: string, expiresAtIso: string) => ({
  id,
  batchId: '22222222-2222-4222-8222-222222222222',
  cat: 'bychki',
  breed: 'Казахская белоголовая',
  heads: 40,
  avgWeight: 420,
  region: 'Акмолинская область',
  windowLabel: 'в октябре',
  offeredPrice: 1750,
  expiresAtIso,
  status: 'pending',
})

// Уже смапленный оффер — вход `sortByDeadline` (она работает с `IncomingOffer`, а не с
// сырым ответом RPC). Срок подставляет каждый тест: он и есть предмет сортировки.
const BASE_OFFER: IncomingOffer = {
  id: 'base',
  batchId: '22222222-2222-4222-8222-222222222222',
  cat: 'bychki',
  breed: 'Казахская белоголовая',
  heads: 40,
  avgWeight: 420,
  region: 'Акмолинская область',
  windowLabel: 'в октябре',
  offeredPrice: 1750,
  expiresAt: new Date(),
  status: 'pending',
}

const SESSION = { data: { session: { access_token: 't' } }, error: null }
const NO_SESSION = { data: { session: null }, error: null }

beforeEach(() => {
  rpc.mockReset()
  getSession.mockReset()
})

it('ARS-785: rpc отдал массив — исход ok, офферы смаплены (getSession не нужен)', async () => {
  const iso = new Date(Date.now() + 5 * 3_600_000).toISOString()
  rpc.mockResolvedValue({ data: [rawOffer('o1', iso)], error: null })

  const r = await readIncomingOffers()

  expect(r.kind).toBe('ok')
  expect(r.kind === 'ok' && r.offers.length).toBe(1)
  expect(r.kind === 'ok' && r.offers[0]!.id).toBe('o1')
  expect(r.kind === 'ok' && r.offers[0]!.expiresAt.toISOString()).toBe(iso)
  expect(rpc).toHaveBeenCalledWith('rpc_get_incoming_offers', {})
  expect(getSession).not.toHaveBeenCalled()
})

it('ARS-785: rpc отказал, сессия есть — исход failed (а не «офферов нет» и не демо-фолбэк)', async () => {
  rpc.mockResolvedValue({ data: null, error: { message: 'permission denied' } })
  getSession.mockResolvedValue(SESSION)

  expect((await readIncomingOffers()).kind).toBe('failed')
})

it('ARS-785: rpc отказал, сессии нет и стор ответил без ошибки — исход no_session', async () => {
  rpc.mockResolvedValue({ data: null, error: { message: 'JWT missing' } })
  getSession.mockResolvedValue(NO_SESSION)

  expect((await readIncomingOffers()).kind).toBe('no_session')
})

// Не перестраховка: @supabase/auth-js внутри EXPIRY_MARGIN_MS (90 с до истечения) уходит в
// СЕТЬ за refresh и при её недоступности отдаёт `{ session: null, error }`. Реальный
// оператор в оффлайне с почти истёкшим токеном обязан увидеть «не загрузилось», а не
// «офферов нет».
it('ARS-785: getSession вернул ошибку (оффлайн) — исход failed, НЕ no_session', async () => {
  rpc.mockResolvedValue({ data: null, error: { message: 'JWT expired' } })
  getSession.mockResolvedValue({ data: { session: null }, error: { message: 'network error' } })

  expect((await readIncomingOffers()).kind).toBe('failed')
})

it('ARS-785: rpc бросил, а стор сессии недоступен — исход failed, не no_session', async () => {
  rpc.mockRejectedValue(new Error('network down'))
  getSession.mockRejectedValue(new Error('storage unavailable'))

  expect((await readIncomingOffers()).kind).toBe('failed')
})

it('ARS-785: пустой ответ базы — это ok с пустым списком, а не failed', async () => {
  rpc.mockResolvedValue({ data: [], error: null })

  const r = await readIncomingOffers()

  expect(r.kind).toBe('ok')
  expect(r.kind === 'ok' && r.offers.length).toBe(0)
  expect(getSession).not.toHaveBeenCalled()
})

// Порядок карточек этот модуль НЕ задаёт — его дом один, `sortByDeadline` (P4), и он
// закреплён там же. Здесь проверяется только то, за что отвечает читатель: ответ базы
// доходит до экрана целиком и в том порядке, в каком база его отдала.
it('ARS-785: читатель отдаёт все офферы ответа, не переставляя их', async () => {
  const h = (n: number) => new Date(Date.now() + n * 3_600_000).toISOString()
  rpc.mockResolvedValue({
    data: [rawOffer('late', h(20)), rawOffer('soon', h(2)), rawOffer('mid', h(9))],
    error: null,
  })

  const r = await readIncomingOffers()

  expect(r.kind === 'ok' && r.offers.map((o) => o.id)).toEqual(['late', 'soon', 'mid'])
})

// ── порядок карточек: дом правила — offers-model, здесь его и закрепляем ─────
// Порядок задаёт ЭКРАН, а не `order by` чужого RPC: если RPC когда-нибудь отдаст строки
// иначе, раздел обязан остаться отсортированным по сроку ответа.
it('ARS-785: sortByDeadline ставит первым оффер с ближайшим сроком ответа', async () => {
  const at = (h: number) => new Date(Date.now() + h * 3_600_000)
  const mk = (id: string, h: number) => ({ ...BASE_OFFER, id, expiresAt: at(h) })

  const sorted = sortByDeadline([mk('late', 20), mk('soon', 2), mk('mid', 9)])

  expect(sorted.map((o) => o.id)).toEqual(['soon', 'mid', 'late'])
})

it('ARS-785: sortByDeadline не мутирует вход (порядок исходного массива сохранён)', async () => {
  const at = (h: number) => new Date(Date.now() + h * 3_600_000)
  const input = [
    { ...BASE_OFFER, id: 'late', expiresAt: at(20) },
    { ...BASE_OFFER, id: 'soon', expiresAt: at(2) },
  ]

  sortByDeadline(input)

  expect(input.map((o) => o.id)).toEqual(['late', 'soon'])
})
