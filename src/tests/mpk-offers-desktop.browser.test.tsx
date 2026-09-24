// AgOS · ARS-785 · Раздел «Входящие офферы» десктопной консоли МПК — строки §Приёмки.
// Предмет — Docs/AGOS-TSP-IncomingOffers-Desktop-A-ARS-785.md.
//
// Один тест = одна строка приёмки, её текст — в названии. Сетевая граница — единственный
// мок; роутинг, состояние и раскладка настоящие.
//
// Браузерный проект обязателен по той же причине, что у «Моих заявок»: под `/mpk` живёт
// v5-остров Ionic, который node-окружение не воспроизводит.
// Запуск: npm run test:routers.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

interface RawOffer {
  id: string
  batchId: string
  cat: string
  breed: string
  heads: number
  avgWeight: number
  region: string
  windowLabel: string
  offeredPrice: number
  expiresAtIso: string
  status: string
}

const store = vi.hoisted(() => ({
  offers: [] as RawOffer[],
  calls: [] as { name: string; args: Record<string, unknown> }[],
  failOffers: false,
  offersDelayMs: 0,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-off-user', user_metadata: { full_name: 'Асхат Оператор' }, phone: '' }
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
              user_id: 'mpk-off-user',
              organizations: [{ id: 'org-1', name: 'МК «Семей Ет»', org_types: ['mpk'], is_primary: true, bin: '123456789012' }],
              farms: [], memberships: [],
            })
          case 'rpc_get_incoming_offers':
            if (store.offersDelayMs) await new Promise((r) => setTimeout(r, store.offersDelayMs))
            if (store.failOffers) return { data: null, error: { message: 'rpc недоступна' } }
            return ok(store.offers)
          case 'rpc_get_my_pools':
            return ok([])
          default:
            return ok(null)
        }
      },
    },
  }
})

/** Срок ответа задаётся в ЧАСАХ от «сейчас» — окно FCFS живое, и тест обязан говорить о
 *  нём теми же единицами, какими карточка. */
function makeOffer(patch: Partial<RawOffer> & { id: string; hoursLeft: number }): RawOffer {
  const { hoursLeft, ...rest } = patch
  return {
    batchId: `b-${patch.id}`,
    cat: 'bychki',
    breed: 'Ангус',
    heads: 40,
    avgWeight: 420,
    region: 'Илийский район',
    windowLabel: 'в октябре',
    offeredPrice: 1750,
    status: 'pending',
    ...rest,
    expiresAtIso: new Date(Date.now() + hoursLeft * 3_600_000).toISOString(),
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

const T = { timeout: 15_000 }

const rows = () => document.querySelectorAll('.agos-mpk-console .mpko-row')
const rowText = (i: number) => rows()[i]?.textContent ?? ''

beforeEach(async () => {
  await page.viewport(1440, 900)
  expect(window.innerWidth, 'ширина раннера < 1024px — консоль подменяется мобильным шеллом').toBeGreaterThanOrEqual(1024)
  store.offers = []
  store.calls = []
  store.failOffers = false
  store.offersDelayMs = 0
})

afterEach(() => {
  unmount()
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

// ── строка приёмки: сортировка + состав карточки ─────────────────────────────
it('список отсортирован по сроку ответа; карточка несёт категорию · породу · регион · головы · ср. вес · тоннаж · цену поставщика · «осталось ответить ~N ч»', async () => {
  store.offers = [
    makeOffer({ id: 'late', hoursLeft: 20 }),
    makeOffer({ id: 'soon', hoursLeft: 2, heads: 25, avgWeight: 400, offeredPrice: 1690, breed: 'Герефорд', region: 'Аршалынский район' }),
    makeOffer({ id: 'mid', hoursLeft: 9 }),
  ]
  mountAppAt('/mpk/offers')

  await expect.poll(() => rows().length, T).toBe(3)

  // Порядок — по сроку ответа, а не по порядку ответа базы.
  expect(rowText(0)).toContain('Осталось ответить: ~2 ч')
  expect(rowText(1)).toContain('Осталось ответить: ~9 ч')
  expect(rowText(2)).toContain('Осталось ответить: ~20 ч')

  // Состав первой карточки — каждое поле названо приёмкой.
  const first = rowText(0)
  expect(first, 'категория').toContain('Бычки')
  expect(first, 'порода').toContain('Герефорд')
  expect(first, 'регион').toContain('Аршалынский район')
  expect(first, 'головы').toContain('25 гол')
  expect(first, 'средний вес').toContain('400')
  // тоннаж = головы × ср. вес = 25 × 400 кг = 10 т. Значение выводится, а не берётся из
  // ответа RPC — поэтому проверяется числом, а не «есть какая-то буква т».
  expect(first, 'тоннаж').toContain('10')
  // Цена поставщика — из ответа базы (`offeredPrice`), с разделителем разрядов fmtMoney.
  expect(first, 'цена поставщика').toMatch(/1\s690/)
  expect(first).toContain('₸/кг')
})

// ── пока не прочитали — это третье состояние, не «пусто» и не отказ ──────────
it('ARS-785: пока база не ответила — скелет, а не «офферов нет» и не отказ', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  store.offersDelayMs = 400
  mountAppAt('/mpk/offers')

  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-skel'), T).not.toBeNull()
  // Утверждать «офферов нет» до ответа базы нельзя — это разные факты.
  expect(document.querySelector('.agos-mpk-console .mpkc-stub-title')).toBeNull()

  await expect.poll(() => rows().length, T).toBe(1)
  expect(document.querySelector('.agos-mpk-console .mpkc-skel')).toBeNull()
})

// ── строка приёмки: пусто ≠ отказ ────────────────────────────────────────────
it('офферов нет → пустое состояние с объяснением, не пустой экран и не отказ', async () => {
  store.offers = []
  mountAppAt('/mpk/offers')

  await expect.poll(
    () => document.querySelector('.agos-mpk-console .mpkc-stub-title')?.textContent?.trim(),
    T,
  ).toBe('Нет входящих офферов')

  const stub = document.querySelector('.agos-mpk-console .mpkc-stub')?.textContent ?? ''
  expect(stub, 'пусто обязано объяснять себя, иначе читается как поломка').toContain('прямого матча')
  // «Повторить» принадлежит ОТКАЗУ: у пустого рынка повторять нечего.
  expect(stub).not.toContain('Повторить')
  expect(rows().length).toBe(0)
})

// ── строка приёмки: отказ чтения ─────────────────────────────────────────────
it('при failed список пуст + отказ с «Повторить», ни одной seed-карточки', async () => {
  store.failOffers = true
  mountAppAt('/mpk/offers')

  await expect.poll(
    () => document.querySelector('.agos-mpk-console .mpkc-stub-title')?.textContent?.trim(),
    T,
  ).toBe('Список не загрузился')

  // Ни одной карточки: демо-офферы реальному оператору не показываются ни в одном исходе.
  expect(rows().length, 'seed-карточек в отказе быть не должно').toBe(0)
  const stub = document.querySelector('.agos-mpk-console .mpkc-stub')?.textContent ?? ''
  expect(stub, 'отказ обязан отличать себя от пустого рынка').toContain('не пустой список')

  // «Повторить» действительно перечитывает базу и поднимает список, когда база ответила.
  store.failOffers = false
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  const before = store.calls.filter((c) => c.name === 'rpc_get_incoming_offers').length
  await page.getByRole('button', { name: 'Повторить' }).click()
  await expect.poll(() => store.calls.filter((c) => c.name === 'rpc_get_incoming_offers').length, T)
    .toBeGreaterThan(before)
  await expect.poll(() => rows().length, T).toBe(1)
})

// ── строка приёмки: сайдбар ──────────────────────────────────────────────────
it('сайдбар: offers построен, подсказки «Раздел в разработке» у него нет; у трёх оставшихся — сохраняется', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-side'), T).not.toBeNull()

  // Построен: пункт ВЕДЁТ на свой экран и подсказки не показывает.
  await page.getByRole('button', { name: 'Входящие офферы' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)
  expect(document.querySelector('.mpkc-soon'), 'у построенного раздела подсказки быть не должно').toBeNull()

  // Три оставшихся непостроенных сохраняют прежнее поведение (Slice 10 FR-013).
  for (const label of ['Главная', 'Маркет-борд', 'Документы сделок']) {
    await page.getByRole('button', { name: label }).click()
    await expect.poll(() => document.querySelector('.mpkc-soon')?.textContent?.trim(), T).toBe('Раздел в разработке')
    expect(window.location.pathname, `пункт «${label}» не должен менять URL`).toBe('/mpk/offers')
  }

  // Выходы из раздела: в «Мои заявки», в консоль профиля и в мобильные закупки.
  await page.getByRole('button', { name: 'Мои заявки' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/requests')
  await page.getByRole('button', { name: 'Входящие офферы' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/offers')
  await page.getByRole('button', { name: 'Профиль МПК' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/overview')
  await page.getByRole('button', { name: 'Входящие офферы' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/offers')
  await page.getByRole('button', { name: /Вернуться в закупки/ }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

// ── незаполненный вес: «не указан» ≠ «ноль» (P11) ────────────────────────────
// `batches.avg_weight_kg` nullable (`d02_tsp.sql:231`), и RPC отдаёт его без `coalesce` —
// в отличие от `breed`/`region`. Партия заполняется постепенно, поэтому пустой вес штатен.
it('ARS-785: у оффера без среднего веса карточка говорит «не указан», а не «0 т»', async () => {
  store.offers = [{ ...makeOffer({ id: 'o1', hoursLeft: 5 }), avgWeight: null as unknown as number }]
  mountAppAt('/mpk/offers')

  await expect.poll(() => rows().length, T).toBe(1)
  const text = rowText(0)
  expect(text).toContain('вес не указан')
  expect(text).toContain('тоннаж не посчитать')
  expect(text, 'ноль был бы утверждением о весе, которого база не делала').not.toMatch(/\b0\s?т\b/)
  // Остальные поля партии при этом на месте — карточка не разваливается.
  expect(text).toContain('40 гол')
})

// ── узкий экран: один URL, две поверхности (решение владельца 24.09) ─────────
// Единственное место в репозитории, где десктопный раздел забирает УЖЕ ЖИВОЙ адрес
// мобильного шелла. У соседей (`/mpk/requests`, `/mpk/profile`) адреса были новыми, и ниже
// 1024px они показывают мост-заглушку; здесь мобильный экран офферов существует и обязан
// открываться. Без этого теста регрессия «отдать телефону заглушку» (или снять ветку
// `!wide`) прошла бы мимо CI: остальные тесты файла forced-wide.
it('ниже 1024px тот же адрес отдаёт мобильный шелл закупок, URL не переписан', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  await page.viewport(900, 800)
  mountAppAt('/mpk/offers')

  // Мобильная поверхность: Ionic-остров в телефонном каркасе, а не десктопная консоль.
  await expect.poll(() => document.querySelector('.phone'), T).not.toBeNull()
  expect(document.querySelector('.agos-mpk-console'), 'на узком экране консоли быть не должно').toBeNull()
  // Заглушки «откройте на компьютере» здесь нет намеренно — экран офферов работает.
  expect(document.querySelector('.mpkc-narrow')).toBeNull()
  expect(window.location.pathname, 'живой адрес не переписан (P7)').toBe('/mpk/offers')
})

// ── чтение ничего не мутирует ────────────────────────────────────────────────
// Прежняя редакция этого теста утверждала, что кнопок «Принять»/«Отклонить» в разделе
// НЕТ — верная граница слайса ARS-785, снятая слайсом ARS-786, который эти ходы и
// построил. Утверждение про кнопки переехало в `mpk-offers-actions.browser.test.tsx`
// (там оно теперь обратное и доказывается). Здесь остаётся то, что ARS-785 утверждает
// по-прежнему: САМО ЧТЕНИЕ раздела не зовёт ни одной мутирующей RPC.
it('ARS-785: открытие раздела только читает — ни одного мутирующего вызова', async () => {
  store.offers = [makeOffer({ id: 'o1', hoursLeft: 5 })]
  mountAppAt('/mpk/offers')
  await expect.poll(() => rows().length, T).toBe(1)

  const called = store.calls.map((c) => c.name)
  expect(called).not.toContain('rpc_self_accept_offer')
  expect(called).not.toContain('rpc_self_reject_offer')
})
