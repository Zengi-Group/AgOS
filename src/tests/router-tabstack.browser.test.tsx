// AgOS · N-2 (Increment 2, аудит нативности) · Независимый навигационный стек на вкладку.
// Регрессия: до N-2 переключение таба делало root-replace и схлопывало всё в один общий
// стек — уход с вкладки и возврат терял, где ты был (и скролл). После N-2 (URL сгруппированы
// по табу /cabinet/{tab}/… + href на кнопках) каждая вкладка держит свой стек: ушёл вглубь,
// переключился на другой таб, вернулся — ты там же, где оставил. Гоняет реальный v5-остров
// в chromium (сеть замокана). Запуск: npm run test:routers. Механика: EngSpec §3, nav.ts N-2.

import { afterEach, expect, it, vi } from 'vitest'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

vi.mock('@/lib/supabase', () => {
  const user = { id: 'tabstack-user', user_metadata: {}, phone: '' }
  const session = { access_token: 's', refresh_token: 's', token_type: 'bearer', expires_in: 3600, user }
  const noBackend = { message: 'tabstack: backend off' }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: noBackend }) as Promise<unknown> & Record<string, unknown>
    for (const m of ['select', 'eq', 'order', 'limit', 'single', 'maybeSingle']) q[m] = () => q
    return q
  }
  return {
    supabase: {
      auth: {
        getSession: async () => ({ data: { session }, error: null }),
        getUser: async () => ({ data: { user }, error: null }),
        setSession: async () => ({ data: { session, user }, error: null }),
        signOut: async () => ({ error: null }),
        signInWithPassword: async () => ({ data: null, error: noBackend }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      },
      rpc: async () => ({ data: null, error: noBackend }),
      from: () => chain(),
    },
  }
})

let root: Root | null = null
let mountEl: HTMLElement | null = null
afterEach(() => {
  root?.unmount(); root = null; mountEl?.remove(); mountEl = null
  window.localStorage.clear()
  window.history.replaceState(null, '', '/')
})

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const poll = async (fn: () => boolean, ms = 12000) => {
  const t0 = Date.now(); while (Date.now() - t0 < ms) { if (fn()) return true; await sleep(50) } return false
}
const visible = (sel: string): boolean => {
  const el = document.querySelector<HTMLElement>(sel)
  if (!el) return false
  const page = el.closest('.ion-page') as HTMLElement | null
  const t = page ?? el
  return !t.classList.contains('ion-page-invisible') && !t.classList.contains('ion-page-hidden') && t.getAttribute('aria-hidden') !== 'true'
}

it('N-2: стек вкладки переживает переключение табов (deep → other tab → back → всё там же)', async () => {
  window.history.replaceState(null, '', '/cabinet')
  mountEl = document.createElement('div'); document.body.appendChild(mountEl)
  root = createRoot(mountEl); root.render(<App />)

  await poll(() => !!document.querySelector('[data-screen-label^="Главная"]'))

  // Уходим ВГЛУБЬ вкладки «Сообщения»: список тредов → тред TURAN.
  document.querySelector<HTMLElement>('ion-tab-button[tab="messages"]')!.click()
  await poll(() => !!document.querySelector('[data-screen-label="Сообщения · треды"]'))
  const convs = document.querySelectorAll<HTMLElement>('.cs-conversation')
  expect(convs.length).toBeGreaterThanOrEqual(4)
  convs[3]!.click()   // индекс 3 — тред TURAN (0 — Консультант, гейт Pro в демо)
  await poll(() => !!document.querySelector('[data-screen-label^="Сообщения · тред "]'))
  await sleep(750)    // пусть forward-анимация осядет (navBusy окно ≤650мс)

  // Переключаемся на другой таб (Главная) и обратно на «Сообщения».
  document.querySelector<HTMLElement>('ion-tab-button[tab="home"]')!.click()
  await poll(() => visible('[data-screen-label^="Главная"]'))
  await sleep(400)
  document.querySelector<HTMLElement>('ion-tab-button[tab="messages"]')!.click()
  await sleep(700)

  // Стек вкладки сохранён: вернулись НА ТРЕД (а не сброшены на список) + URL восстановлен.
  expect(visible('[data-screen-label^="Сообщения · тред "]')).toBe(true)
  expect(window.location.pathname).toBe('/cabinet/messages/thread/turan')
})

it('N-2: повторный тап по активному табу возвращает к корню вкладки (scroll-to-top / N-6)', async () => {
  window.history.replaceState(null, '', '/cabinet')
  mountEl = document.createElement('div'); document.body.appendChild(mountEl)
  root = createRoot(mountEl); root.render(<App />)

  await poll(() => !!document.querySelector('[data-screen-label^="Главная"]'))
  document.querySelector<HTMLElement>('ion-tab-button[tab="messages"]')!.click()
  await poll(() => !!document.querySelector('[data-screen-label="Сообщения · треды"]'))
  const convs = document.querySelectorAll<HTMLElement>('.cs-conversation')
  convs[3]!.click()
  await poll(() => !!document.querySelector('[data-screen-label^="Сообщения · тред "]'))
  await sleep(750)

  // Тап по УЖЕ активному табу «Сообщения» → нативный pop к корню вкладки (список тредов).
  document.querySelector<HTMLElement>('ion-tab-button[tab="messages"]')!.click()
  await sleep(700)
  expect(visible('[data-screen-label="Сообщения · треды"]')).toBe(true)
  expect(window.location.pathname).toBe('/cabinet/messages')
})

it('N-7/N-8: системный back внутри вкладки живёт и поппит стек назад (тред→список)', async () => {
  // До N-2 свитч таба был root-replace — стек схлопывался, системный back внутри вкладки
  // не имел записи «список под тредом» (мёртвая история N-7). После N-2 push внутри вкладки
  // добавляет реальную запись → back поппит тред→список в back-направлении (N-8).
  // Примечание: back НА КОРНЕ вкладки (кросс-таб / выход из острова) — предмет N-4 (backGuard),
  // здесь намеренно НЕ фиксируем, чтобы не зашивать поведение, которое N-4 может изменить.
  window.history.replaceState(null, '', '/welcome')
  window.history.pushState(null, '', '/cabinet')
  mountEl = document.createElement('div'); document.body.appendChild(mountEl)
  root = createRoot(mountEl); root.render(<App />)

  await poll(() => !!document.querySelector('[data-screen-label^="Главная"]'))
  document.querySelector<HTMLElement>('ion-tab-button[tab="messages"]')!.click()
  await poll(() => !!document.querySelector('[data-screen-label="Сообщения · треды"]'))
  document.querySelectorAll<HTMLElement>('.cs-conversation')[3]!.click()
  await poll(() => !!document.querySelector('[data-screen-label^="Сообщения · тред "]'))
  await sleep(750)

  // back: тред → список тредов (pop внутри вкладки «Сообщения»), направление — назад.
  window.history.back()
  expect(await poll(() => window.location.pathname === '/cabinet/messages' && visible('[data-screen-label="Сообщения · треды"]'), 4000)).toBe(true)
})
