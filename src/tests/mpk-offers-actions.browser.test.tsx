// AgOS · ARS-786 · Ходы по входящему офферу в консоли МПК — строки §Приёмки.
// Предмет — Docs/AGOS-TSP-IncomingOffers-Desktop-B-ARS-786.md.
//
// Один тест = одна строка приёмки, её текст — в названии. Сетевая граница — единственный
// мок; роутинг, состояние и раскладка настоящие.
// Запуск: npm run test:routers.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

interface RawOffer {
  id: string; batchId: string; cat: string; breed: string; heads: number
  avgWeight: number; region: string; windowLabel: string; offeredPrice: number
  expiresAtIso: string; status: string
}

const store = vi.hoisted(() => ({
  offers: [] as RawOffer[],
  calls: [] as { name: string; args: Record<string, unknown> }[],
  /** Отказ, который база вернёт на следующий ход: точный текст `raise exception`. */
  failWith: null as string | null,
  /** Ответ `rpc_self_accept_offer` — форма проверена по телу функции. */
  acceptResult: { batchId: 'b1', poolId: 'p-1', poolLineId: 'pl-1', dealPrice: 1810 },
  /** Задержка ответа обоих ходов: пока не `null`, RPC ждёт, и окно «ход идёт» становится
   *  наблюдаемым. Без него блокировка кнопок непроверяема — мок отвечает мгновенно. */
  hold: null as null | Promise<void>,
  release: null as null | (() => void),
  /** Отказ чтения списка заявок: имя заявки-получателя тогда взять неоткуда. */
  failPools: false,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-act-user', user_metadata: { full_name: 'Асхат Оператор' }, phone: '' }
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
      rpc: async (name: string, args: Record<string, unknown> = {}) => {
        store.calls.push({ name, args })
        switch (name) {
          case 'rpc_get_my_context':
            return ok({
              user_id: 'mpk-act-user',
              organizations: [{ id: 'org-1', name: 'МК «Семей Ет»', org_types: ['mpk'], is_primary: true, bin: '123456789012' }],
              farms: [], memberships: [],
            })
          case 'rpc_get_incoming_offers':
            return ok(store.offers)
          case 'rpc_get_my_pools':
            // Заявка-получатель: её ИМЯ экран собирает отсюда — RPC принятия отдаёт
            // только `poolId` (проверено по телу функции).
            if (store.failPools) return { data: null, error: { message: 'pools rpc недоступна' } }
            return ok([{
              id: 'p-1', status: 'filling', totalHeads: 200, filledHeads: 24,
              region: 'Алматинская обл.', targetMonthIso: '2026-10-01', createdAtIso: '2026-09-01',
              // `vysshaya` — настоящий ключ `MpkCatKey`. С выдуманным (`bychki`) `toLines`
              // отфильтровал бы строку, и заявка получила бы ЗАПАСНОЕ имя «Закупка · …» —
              // тест доказывал бы не то, что утверждает.
              lines: [{ code: 'vysshaya', price: 1810 }], contactRevealed: false, minPoolHeads: 10,
            }])
          case 'rpc_self_accept_offer': {
            if (store.hold) await store.hold
            if (store.failWith) { const m = store.failWith; store.failWith = null; return { data: null, error: { message: m } } }
            store.offers = store.offers.filter((o) => o.id !== args.p_offer_id)
            return ok(store.acceptResult)
          }
          case 'rpc_self_reject_offer': {
            if (store.hold) await store.hold
            if (store.failWith) { const m = store.failWith; store.failWith = null; return { data: null, error: { message: m } } }
            store.offers = store.offers.filter((o) => o.id !== args.p_offer_id)
            return ok(true)
          }
          default:
            return ok(null)
        }
      },
    },
  }
})

function makeOffer(patch: Partial<RawOffer> & { id: string; hoursLeft: number }): RawOffer {
  const { hoursLeft, ...rest } = patch
  return {
    batchId: `b-${patch.id}`, cat: 'bychki', breed: 'Ангус', heads: 40, avgWeight: 420,
    region: 'Илийский район', windowLabel: 'в октябре', offeredPrice: 1750, status: 'pending',
    ...rest,
    expiresAtIso: new Date(Date.now() + hoursLeft * 3_600_000).toISOString().replace(/\.\d+Z$/, 'Z'),
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
  root?.unmount(); root = null
  mountEl?.remove(); mountEl = null
}

const T = { timeout: 15_000 }
const rows = () => document.querySelectorAll('.agos-mpk-console .mpko-row')
const flashText = () => document.querySelector('.agos-mpk-console .mpkr-flash')?.textContent ?? ''
const called = (n: string) => store.calls.filter((c) => c.name === n)

beforeEach(async () => {
  await page.viewport(1440, 900)
  expect(window.innerWidth, 'ширина раннера < 1024px — вместо консоли встанет мобильный шелл').toBeGreaterThanOrEqual(1024)
  store.offers = []
  store.calls = []
  store.failWith = null
  store.acceptResult = { batchId: 'b1', poolId: 'p-1', poolLineId: 'pl-1', dealPrice: 1810 }
  store.hold = null
  store.release = null
  store.failPools = false
})

/** Подвесить ответ обеих мутирующих RPC до явного `release()`. Только так окно «ход идёт»
 *  существует дольше микротаска и блокировку кнопок можно наблюдать. */
function holdRpc() {
  store.hold = new Promise<void>((res) => { store.release = res })
}
function releaseRpc() {
  store.release?.()
  store.hold = null
  store.release = null
}

afterEach(() => {
  unmount()
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

// ── строка приёмки 1 · принятие ──────────────────────────────────────────────
it('принятие: вызван rpc_self_accept_offer; по ответу названа заявка и цена сделки (dealPrice = бид, не ask); список перечитан', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5, offeredPrice: 1750 })]
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)
  const readsBefore = called('rpc_get_incoming_offers').length

  await page.getByRole('button', { name: 'Принять' }).click()

  // Вызвана та самая RPC, с id этого оффера.
  await expect.poll(() => called('rpc_self_accept_offer').length, T).toBe(1)
  expect(called('rpc_self_accept_offer')[0]!.args.p_offer_id).toBe('o1')

  // Исход назван: заявка — по имени из списка, цена — `dealPrice` из ответа базы.
  await expect.poll(() => flashText(), T).toContain('Партия принята')
  const txt = flashText()
  // Заявка названа ИМЕНЕМ: кавычки доказывают, что имя разрешилось, а не сработал
  // запасной путь «в вашу заявку» (он кавычек не ставит).
  expect(txt, 'заявка-получатель названа именем').toContain('в заявку «')
  expect(txt).toContain('Алматинская обл.')
  expect(txt, 'цена сделки = dealPrice (бид комбината)').toMatch(/1\s810/)
  // Ask фермера (1750) ценой сделки НЕ называется — это и есть D-M6-DEALPRICE.
  expect(txt).not.toMatch(/1\s750/)

  // Список перечитан, отвеченный оффер ушёл.
  await expect.poll(() => called('rpc_get_incoming_offers').length, T).toBeGreaterThan(readsBefore)
  await expect.poll(() => rows().length, T).toBe(0)
})

// ── строка приёмки 2 · отклонение ────────────────────────────────────────────
it('отклонение: вызван rpc_self_reject_offer, оффер ушёл, остальные на месте', async () => {
  store.offers = [
    makeOffer({ id: 'o1', hoursLeft: 3 }),
    makeOffer({ id: 'o2', hoursLeft: 9 }),
  ]
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(2)

  // Первая строка — ближайший срок (o1). Жмём её «Отклонить».
  await rows()[0]!.querySelectorAll('button')[1]!.click()

  await expect.poll(() => called('rpc_self_reject_offer').length, T).toBe(1)
  expect(called('rpc_self_reject_offer')[0]!.args.p_offer_id).toBe('o1')
  expect(called('rpc_self_accept_offer').length, 'принятие не зовётся').toBe(0)

  await expect.poll(() => flashText(), T).toContain('отклонено')
  // Ушёл ровно один: второй оффер на месте.
  await expect.poll(() => rows().length, T).toBe(1)
  expect(rows()[0]!.textContent).toContain('~9 ч')
})

// ── строка приёмки 3 · семь кодов + неизвестный ──────────────────────────────
const CODES: [string, string, string][] = [
  ['AUTH_REQUIRED', 'AUTH_REQUIRED', 'Сессия истекла'],
  ['OFFER_NOT_FOUND', 'OFFER_NOT_FOUND', 'Предложение не найдено'],
  // База конкатенирует код с деталью — фраза обязана находиться и так.
  ['FORBIDDEN', 'FORBIDDEN: offer belongs to another MPK', 'нет прав'],
  ['INVALID_STATUS', 'INVALID_STATUS: offer is accepted', 'Статус уже изменился'],
  ['OFFER_EXPIRED', 'OFFER_EXPIRED', 'Срок предложения истёк'],
  ['BATCH_NOT_FOUND', 'BATCH_NOT_FOUND', 'Партия не найдена'],
  ['NO_MATCHING_POOL_LINE', 'NO_MATCHING_POOL_LINE: raise a pool line bid >= ask 1700 first', 'не подходит ни в одну'],
]

it('семь кодов → фраза без кода в теле; неизвестный → общая фраза + код мелким', async () => {
  for (const [code, raised, phrase] of CODES) {
    store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
    store.calls = []
    store.failWith = raised
    mountAppAt('/mpk/offers')
    await expect.poll(() => rows().length, T).toBe(1)

    await page.getByRole('button', { name: 'Принять' }).click()
    await expect.poll(() => document.querySelector('.mpkr-flash.bad')?.textContent ?? '', T).toContain(phrase)

    const box = document.querySelector('.mpkr-flash.bad')!
    // Опознанный код в теле сообщения не печатается — оператору он ничего не говорит.
    expect(box.textContent, `код ${code} не должен утечь в текст`).not.toContain(code)
    expect(box.querySelector('.mpko-code'), `у опознанного ${code} нет строки кода`).toBeNull()
    unmount()
  }

  // Неопознанный код: общая фраза + сам код мелким — иначе в поддержку не с чем прийти.
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  store.calls = []
  store.failWith = 'P0042_SOMETHING_NEW'
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)
  await page.getByRole('button', { name: 'Принять' }).click()

  await expect.poll(() => document.querySelector('.mpkr-flash.bad')?.textContent ?? '', T)
    .toContain('Не удалось выполнить действие')
  expect(document.querySelector('.mpko-code')?.textContent).toBe('P0042_SOMETHING_NEW')
})

// ── строка приёмки 4 · истёк при нажатии ─────────────────────────────────────
it('истёк при нажатии → причина показана, список обновлён', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 1 })]
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)
  const readsBefore = called('rpc_get_incoming_offers').length

  // Пока оператор смотрел, окно закрылось: база отвечает отказом, а оффер уходит из выдачи.
  store.failWith = 'OFFER_EXPIRED'
  store.offers = []

  await page.getByRole('button', { name: 'Принять' }).click()

  await expect.poll(() => document.querySelector('.mpkr-flash.bad')?.textContent ?? '', T)
    .toContain('Срок предложения истёк')
  // Список перечитан ПОСЛЕ отказа: иначе оператор остался бы с мёртвой строкой и нажал
  // бы по ней второй раз.
  await expect.poll(() => called('rpc_get_incoming_offers').length, T).toBeGreaterThan(readsBefore)
  await expect.poll(() => rows().length, T).toBe(0)
})

// ── блокировка на время хода ─────────────────────────────────────────────────
// Прибор на FCFS-защиту. Без подвешенного ответа окно «ход идёт» закрывается в том же
// микротаске, и снятие `disabled` осталось бы незамеченным — прибор был бы декорацией.
it('ARS-786: пока ход идёт, заперты ВСЕ кнопки раздела, и «Отправляем…» стоит на нажатой', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 3 }), makeOffer({ id: 'o2', hoursLeft: 9 })]
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(2)

  holdRpc()
  rows()[0]!.querySelectorAll('button')[1]!.click()   // «Отклонить» первой строки

  // Заперты все четыре кнопки обеих строк — второй оффер мог быть отозван первым ходом.
  await expect.poll(
    () => Array.from(document.querySelectorAll<HTMLButtonElement>('.mpko-cell-acts button')).every((b) => b.disabled),
    T,
  ).toBe(true)

  // Подпись стоит на НАЖАТОЙ кнопке, а не на соседней.
  const first = rows()[0]!.querySelectorAll('button')
  expect(first[1]!.textContent?.trim(), 'нажали «Отклонить» — она и «Отправляем…»').toBe('Отправляем…')
  expect(first[0]!.textContent?.trim(), '«Принять» не присваивает себе чужой ход').toBe('Принять')

  // Клик по второй строке во время хода вторым вызовом не уходит.
  rows()[1]!.querySelectorAll('button')[0]!.click()
  expect(called('rpc_self_accept_offer').length, 'второй ход не ушёл в базу').toBe(0)

  releaseRpc()
  await expect.poll(() => rows().length, T).toBe(1)
  // Замок снят: оставшаяся строка снова активна.
  await expect.poll(
    () => Array.from(document.querySelectorAll<HTMLButtonElement>('.mpko-cell-acts button')).some((b) => !b.disabled),
    T,
  ).toBe(true)
})

// ── имя заявки не прочиталось ────────────────────────────────────────────────
it('ARS-786: список заявок не прочитан → «в вашу заявку», а не uuid и не пустое место', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  store.failPools = true
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)

  await page.getByRole('button', { name: 'Принять' }).click()

  await expect.poll(() => flashText(), T).toContain('Партия принята')
  const txt = flashText()
  expect(txt, 'нейтральная формулировка вместо имени').toContain('в вашу заявку')
  // Ни uuid, ни «undefined» оператору не показываем: принятие СОСТОЯЛОСЬ, и сообщение о
  // нём обязано быть человеческим.
  expect(txt).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}/)
  expect(txt).not.toContain('undefined')
  // Цена при этом названа: она из ответа хода, а не из несостоявшегося чтения заявок.
  expect(txt).toMatch(/1\s810/)
})

// ── отказ сети ───────────────────────────────────────────────────────────────
it('ARS-786: обрыв связи → фраза про связь, а не английский текст SDK кодом поддержки', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  store.failWith = 'TypeError: Failed to fetch'
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)

  await page.getByRole('button', { name: 'Принять' }).click()

  await expect.poll(() => document.querySelector('.mpkr-flash.bad')?.textContent ?? '', T)
    .toContain('Нет связи с сервером')
  // Английский текст SDK оператору не показывается ни в теле, ни «кодом».
  expect(document.querySelector('.mpkr-flash.bad')?.textContent).not.toContain('Failed to fetch')
  expect(document.querySelector('.mpko-code')).toBeNull()
})

// ── граница: ходы есть, но выбор заявки оператору не предлагается ────────────
it('ARS-786 граница: оператор не выбирает заявку — её называет ответ базы', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)

  // Смотрим ТОЛЬКО ячейку ответа: в сайдбаре консоли есть пункт «Мои заявки», и по всей
  // странице проверка ловила бы его, а не выбор заявки при ходе.
  const acts = Array.from(document.querySelectorAll<HTMLElement>('.mpko-cell-acts button'))
    .map((b) => b.textContent?.trim() ?? '')
  expect(acts).toContain('Принять')
  expect(acts).toContain('Отклонить')
  // Ходов ровно два — ни третьей кнопки, ни второго шага выбора.
  expect(acts.length).toBe(2)
  // Ни селектора заявки в строке: сигнатуру `rpc_self_accept_offer` слайс не меняет,
  // получателя выбирает база.
  expect(document.querySelectorAll('.mpko-row select').length).toBe(0)
})
