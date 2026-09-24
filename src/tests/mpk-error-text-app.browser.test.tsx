// AgOS · ARS-691 · Отказ доезжает до тоста мобильного шелла МПК (уровень MpkApp).
//
// Спек: `Docs/AGOS-TSP-MpkErrorText-ARS-691.md`. Юнит-тест словаря и тест `Toast` с
// подставленным вручную `code` не видят звена «точка вывода → MpkApp.showToast(text, code) →
// <Toast>»: потеряй `showToast` второй аргумент — оба остались бы зелёными. Здесь мокается
// только сетевая граница, путь App → /mpk/offers → «Принять»/«Отклонить» настоящий.
// Запуск: npm run test:routers.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

const net = vi.hoisted(() => ({
  acceptError: null as { message: string } | null,
  rejectError: null as { message: string } | null,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'ars691-mpk', user_metadata: {}, phone: '' }
  const session = { access_token: 'ars691', refresh_token: 'ars691', token_type: 'bearer', expires_in: 3600, user }
  const noBackend = { message: 'ars691: backend отключён' }
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
      rpc: async (fn: string) => {
        if (fn === 'rpc_get_incoming_offers') {
          return {
            data: [{
              id: 'offer-1', batchId: 'batch-1', cat: 'steers', breed: 'КБГ', heads: 20, avgWeight: 420,
              region: 'Тестовый район', windowLabel: 'октябрь', offeredPrice: 1750,
              expiresAtIso: new Date(Date.now() + 3_600_000).toISOString(), status: 'pending',
            }],
            error: null,
          }
        }
        if (fn === 'rpc_self_accept_offer') return { data: null, error: net.acceptError }
        if (fn === 'rpc_self_reject_offer') return { data: null, error: net.rejectError }
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
let consoleError: ReturnType<typeof vi.spyOn> | null = null

function mountAppAt(path: string) {
  window.history.replaceState(null, '', path)
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<App />)
}

beforeEach(async () => {
  await page.viewport(1440, 900)
  net.acceptError = null
  net.rejectError = null
  consoleError = vi.spyOn(console, 'error').mockImplementation(() => {})
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
  consoleError?.mockRestore()
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

const T = { timeout: 20_000 }
const toastText = () => document.querySelector('.toast')?.textContent ?? null

it('ARS-691 M-007 · «Принять» (MpkApp): незнакомый код — тост с общей фразой и строкой «Код: …», хвоста нет', async () => {
  net.acceptError = { message: 'UNKNOWN_DIMENSION: livestock_condition' }
  mountAppAt('/mpk/offers')

  await expect.element(page.getByRole('button', { name: 'Принять' }), T).toBeInTheDocument()
  await page.getByRole('button', { name: 'Принять' }).click()

  await expect.poll(() => document.querySelector('.toast .rpc-error-code')?.textContent ?? null, T)
    .toBe('Код: UNKNOWN_DIMENSION')
  expect(toastText()).toBe('Не удалось принять: Не удалось выполнить действие. Повторите или сообщите в поддержку.Код: UNKNOWN_DIMENSION')
  expect(toastText()).not.toContain('livestock_condition')
})

it('ARS-691 FR-001 · «Отклонить» (MpkApp): знакомый код — фраза словаря, строки кода нет', async () => {
  net.rejectError = { message: 'OFFER_EXPIRED: offer expires_at passed' }
  mountAppAt('/mpk/offers')

  await expect.element(page.getByRole('button', { name: 'Отклонить' }), T).toBeInTheDocument()
  await page.getByRole('button', { name: 'Отклонить' }).click()

  await expect.poll(toastText, T).toBe('Не удалось: Срок предложения истёк.')
  expect(document.querySelector('.toast .rpc-error-code')).toBeNull()
})
