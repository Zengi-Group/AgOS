// AgOS · issue #4 · Регрессия: «назад» из треда НЕ должен проигрывать вход экрана списка
// чатов дважды. См. DECISIONS_LOG 2026-07-15 / memory cabinet-back-double-enter.
// Запуск: npm run test:routers (или VITE_BACK_DELAY=<ms> для проверки окна гонки).

import { afterEach, expect, it, vi } from 'vitest'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

vi.mock('@/lib/supabase', () => {
  const user = { id: 'msg-back-user', user_metadata: {}, phone: '' }
  const session = { access_token: 's', refresh_token: 's', token_type: 'bearer', expires_in: 3600, user }
  const noBackend = { message: 'msg-back: backend off' }
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
      // Realtime-заглушка (см. router-smoke): ARS-269 зовёт channel() при mount CabinetApp.
      channel: () => {
        const ch: Record<string, () => unknown> = {}
        for (const m of ['on', 'subscribe', 'unsubscribe']) ch[m] = () => ch
        return ch
      },
      removeChannel: async () => 'ok',
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
  const t0 = Date.now()
  while (Date.now() - t0 < ms) { if (fn()) return true; await sleep(50) }
  return false
}
const pages = () => Array.from(document.querySelectorAll('[data-screen-label]')) as HTMLElement[]
const isVis = (t: HTMLElement) =>
  !t.classList.contains('ion-page-invisible') && !t.classList.contains('ion-page-hidden') && t.getAttribute('aria-hidden') !== 'true'
const labelOf = (t: HTMLElement) => {
  const l = t.getAttribute('data-screen-label') || ''
  return l.startsWith('Сообщения · тред ') ? 'THREAD' : l === 'Сообщения · треды' ? 'LIST' : null
}

it('«назад» из треда входит в список чатов ровно один раз (issue #4)', async () => {
  window.history.replaceState(null, '', '/cabinet')
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<App />)

  await poll(() => !!document.querySelector('[data-screen-label^="Главная"]'))
  document.querySelector<HTMLElement>('ion-tab-button[tab="messages"]')!.click()
  await poll(() => !!document.querySelector('[data-screen-label="Сообщения · треды"]'))

  const prev = new WeakMap<HTMLElement, boolean>()
  let listEntersAfterBack = 0
  let backClicked = false
  const tl: string[] = []
  const snap = () => {
    for (const p of pages()) {
      const lab = labelOf(p)
      if (!lab) continue
      const vis = isVis(p)
      if (prev.get(p) !== vis) {
        tl.push(`${lab}:${vis ? 'ENTER' : 'leave'}${backClicked ? '(afterBack)' : ''}`)
        if (lab === 'LIST' && vis && backClicked) listEntersAfterBack++
        prev.set(p, vis)
      }
    }
  }
  snap()
  const obs = new MutationObserver(snap)
  obs.observe(document.querySelector('.ion-router-outlet') || document.body, {
    childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'aria-hidden'],
  })

  // Тред TURAN (индекс 3; индекс 0 — Консультант, гейт Platform Pro в демо).
  const convs = document.querySelectorAll<HTMLElement>('.cs-conversation')
  expect(convs.length).toBeGreaterThanOrEqual(4)
  convs[3]!.click()
  await poll(() => !!document.querySelector('[data-screen-label^="Сообщения · тред "]'))

  backClicked = true
  // (1) «Быстрый назад» ВНУТРИ окна forward-анимации (iOS ≈540мс) — до фикса давал ДВОЙНОЙ
  // вход; теперь тап в анимацию ИГНОРИРУЕТСЯ (нативное поведение iOS), остаёмся в треде.
  await sleep(Number(import.meta.env.VITE_BACK_DELAY ?? 250))
  document.querySelector<HTMLElement>('.thr-back')!.click()
  await sleep(150)
  expect(!!document.querySelector('[data-screen-label^="Сообщения · тред "]')).toBe(true) // тап проигнорирован

  // (2) «Назад» уже ПОСЛЕ анимации (окно ≤650мс закрыто) — штатный возврат, ровно один вход.
  await sleep(700)
  document.querySelector<HTMLElement>('.thr-back')!.click()
  await sleep(1600)
  obs.disconnect()

  if (listEntersAfterBack !== 1) throw new Error('enters=' + listEntersAfterBack + ' TL=' + JSON.stringify(tl))
  expect(listEntersAfterBack).toBe(1)
  expect(pages().filter((p) => labelOf(p) === 'LIST').length).toBe(1)
  expect(window.location.pathname).toBe('/cabinet/messages')
})
