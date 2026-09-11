// AgOS · ARS-687 · Проводка исхода чтения заявок в приложении (уровень MpkApp).
// Предмет — Docs/AGOS-TSP-MarketBoard-RequirePool-ARS-687.md, `FR-009` и строки матрицы
// M-012 / M-013.
//
// ЗАЧЕМ ТРЕТИЙ ФАЙЛ. Два предыдущих закрывают разные границы и оба обходят эту:
//   · mpk-market-board-offer.browser.test.tsx — поведение МОДАЛКИ при заданном `poolsState`
//     (проп подаётся литералом, supabase замокан на throw);
//   · mpk-pools-read.browser.test.ts — КЛАССИФИКАЦИЯ исхода (readMyPools / nextPoolsRead).
// Между ними остаётся звено «исход → состояние MpkApp → проп модалки» и адрес «Повторить».
// Оба зазора показываются одинаково: заменить в MpkApp.applyPoolsRead исход на 'ready' —
// состояние M-013 становится в приложении недостижимым; подставить в onRetryPools соседний
// refetchMarket — «Повторить» молча перезагружает маркет-борд и ошибка не уходит никогда.
// Оба варианта оставляли зелёными и первые два файла, и `tsc -b`.
//
// Поэтому здесь мокается ТОЛЬКО сетевая граница (@/lib/supabase), а весь путь —
// App → /mpk/tsp → карточка партии → окно партии — настоящий, как в router-smoke.
//
// @case-тегов нет намеренно — см. шапку mpk-market-board-offer.browser.test.tsx.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

const REAL_BATCH_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const REAL_POOL_ID = '11111111-1111-4111-8111-111111111111'

// Ответы rpc_get_my_pools по порядку вызова: первый — отказ, дальше — успех. Так один
// прогон проходит оба состояния, M-013 → «Повторить» → список прочитан.
const poolsAnswers: { data: unknown; error: unknown }[] = []
let poolsCalls = 0

vi.mock('@/lib/supabase', () => {
  const user = { id: 'ars687-mpk', user_metadata: {}, phone: '' }
  const session = { access_token: 'ars687', refresh_token: 'ars687', token_type: 'bearer', expires_in: 3600, user }
  const noBackend = { message: 'ars687: backend отключён' }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: noBackend }) as Promise<unknown> & Record<string, unknown>
    for (const m of ['select', 'eq', 'order', 'limit', 'single', 'maybeSingle']) q[m] = () => q
    return q
  }
  return {
    supabase: {
      auth: {
        // Сессия есть — значит исход «не прочитали» должен быть failed, а не демо-фолбэк.
        getSession: async () => ({ data: { session }, error: null }),
        getUser: async () => ({ data: { user }, error: null }),
        setSession: async () => ({ data: { session, user }, error: null }),
        signOut: async () => ({ error: null }),
        signInWithPassword: async () => ({ data: null, error: noBackend }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      },
      rpc: async (fn: string) => {
        if (fn === 'rpc_get_my_pools') {
          const a = poolsAnswers[Math.min(poolsCalls, poolsAnswers.length - 1)]
          poolsCalls += 1
          return a ?? { data: null, error: noBackend }
        }
        if (fn === 'rpc_get_market_batches') {
          return {
            data: [{
              id: REAL_BATCH_ID, cat: 'steers', skuName: 'Бычки откормочные', breed: 'КБГ',
              heads: 40, avgWeight: 450, age: 18, fatness: 'high', region: 'Тестовый район',
              minPrice: 1600, state: 'published', windowLabel: 'сентябрь',
            }],
            error: null,
          }
        }
        if (fn === 'rpc_self_close_due_pools') return { data: null, error: null }
        // Профиль и всё прочее — отказ: МПК уходит в штатный демо-фолбэк профиля, но
        // заявки от этого демо-фолбэком НЕ становятся (в этом и смысл FR-009).
        return { data: null, error: noBackend }
      },
      from: () => chain(),
      channel: () => {
        const ch: Record<string, () => unknown> = {}
        for (const m of ['on', 'subscribe', 'unsubscribe']) ch[m] = () => ch
        return ch
      },
      removeChannel: async () => 'ok',
    },
  }
})

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

beforeEach(async () => {
  await page.viewport(1440, 900)
  poolsCalls = 0
  poolsAnswers.length = 0
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

const T = { timeout: 20_000 }

const sendButton = (): HTMLButtonElement | null => {
  const b = Array.from(document.querySelectorAll('button.cta')).find((el) => {
    const t = el.textContent?.trim()
    return t === 'Отправить предложение' || t === 'Отправляем…'
  })
  return (b as HTMLButtonElement | undefined) ?? null
}

it('ARS-687 M-013 → M-003 (проводка): отказ чтения доезжает до окна партии, «Повторить» перечитывает заявки', async () => {
  const rawPool = {
    id: REAL_POOL_ID, status: 'filling', totalHeads: 100, filledHeads: 10,
    region: 'Тестовый район', targetMonthIso: null, createdAtIso: null,
    lines: [{ code: 'vysshaya', price: 1700 }], contactRevealed: false,
  }
  poolsAnswers.push({ data: null, error: { message: 'ars687: rpc_get_my_pools отказал' } })
  poolsAnswers.push({ data: [rawPool], error: null })

  mountAppAt('/mpk/tsp')

  // Экран закупок поднялся; партии живут на вкладке «Маркет-борд» (по умолчанию открыты
  // «Мои заявки»), поэтому сначала переключаем вкладку — путь настоящий, как у оператора.
  await expect.element(page.getByText('Маркет-борд'), T).toBeInTheDocument()
  await page.getByText('Маркет-борд').click()

  // Реальная партия из rpc_get_market_batches видна.
  await expect.element(page.getByText('Бычки откормочные'), T).toBeInTheDocument()
  const card = document.querySelector<HTMLElement>('.mb-card')
  expect(card).not.toBeNull()
  card!.click()

  // M-013 в приложении: сказано именно «не загрузился», а не «заявок нет»; seed-заявки
  // (демо-фолбэк до ARS-687) в селектор реальному пользователю не подставлены.
  await expect.element(page.getByText('Список заявок не загрузился'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('Сначала создайте заявку на закупку')
  expect(document.querySelector('select.mpk-select')).toBeNull()
  expect(sendButton()?.disabled).toBe(true)

  // «Повторить» ведёт именно к перечитыванию заявок: второй ответ — список, и он доезжает.
  const callsBefore = poolsCalls
  await page.getByText('Повторить').click()
  await expect.poll(() => poolsCalls, T).toBeGreaterThan(callsBefore)
  await expect.poll(() => document.querySelector('select.mpk-select'), T).not.toBeNull()
  // Заявка одна — подставлена сама (M-003), отправка открылась.
  await expect.poll(() => sendButton()?.disabled, T).toBe(false)
  expect(document.body.textContent).not.toContain('Список заявок не загрузился')
})
