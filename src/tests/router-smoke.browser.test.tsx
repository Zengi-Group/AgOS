// AgOS · DEBT-NATIVE-ROUTER-01 (ARS-152) · Smoke двух роутеров: v6-приложение + v5-остров.
// Регрессия, «протёкшая» v5 в дерево приложения (или наоборот), ломается тихо — белым
// экраном (спайк ADR-NATIVE-ROUTER-01 AMEND-1). Тест гоняет ОБА роутера в реальном
// chromium через Vite-пайплайн, где работает resolveId-редирект agos:ionic-v5-island
// (vite.config.ts) — node-окружение остров не воспроизводит.
// Запуск: npm run test:routers. Механика острова: AGOS-NativeApp-EngSpec-v0_1.md §3.

import { afterEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

// Единственный мок — сетевая граница (@/lib/supabase). Роутинг-стек остаётся реальным:
// BrowserRouter v6 → RequireAuth → CabinetApp (IonReactRouter, v5-остров) / MpkApp.
// Фейковая сессия проводит через RequireAuth; rpc-ошибки уводят оболочки в штатный
// демо-фолбэк (профиль null → демо-режим, seed-данные) — так тест не зависит от БД.
vi.mock('@/lib/supabase', () => {
  const user = { id: 'router-smoke-user', user_metadata: {}, phone: '' }
  const session = { access_token: 'smoke', refresh_token: 'smoke', token_type: 'bearer', expires_in: 3600, user }
  const noBackend = { message: 'router-smoke: backend отключён' }
  // Чейн-заглушка .from().select().eq().order().limit().single() — thenable «нет данных».
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

// URL тестового раннера восстанавливаем после каждого теста — история iframe общая.
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

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
  window.localStorage.clear() // agos.cabinet.* не должен протекать между тестами
  window.history.replaceState(null, '', initialUrl)
})

const T = { timeout: 15_000 }

it('v6: /login рендерится и навигируется на /register', async () => {
  mountAppAt('/login')
  await expect.element(page.getByText('Вход в кабинет'), T).toBeInTheDocument()
  await page.getByRole('button', { name: /Зарегистрироваться/ }).click()
  await expect.element(page.getByText('С чего начнём?'), T).toBeInTheDocument()
  expect(window.location.pathname).toBe('/register')
})

it('v5-остров: /cabinet рендерит Главную и навигируется ion-роутером на /cabinet/market', async () => {
  mountAppAt('/cabinet')
  // Оболочка поднялась: IonPage Главной (IonShellFrame data-screen-label="Главная · …").
  // Сломанный island-редирект = @ionic/react-router получает v6 и падает до рендера.
  await expect.poll(() => document.querySelector('[data-screen-label^="Главная"]'), T).not.toBeNull()
  // Навигация v5-острова: таб «Рынок» → go() → ion.push('/cabinet/market', 'root', 'replace').
  const marketTab = document.querySelector<HTMLElement>('ion-tab-button[tab="market"]')
  expect(marketTab).not.toBeNull()
  marketTab!.click()
  await expect.poll(() => window.location.pathname, T).toBe('/cabinet/market')
  await expect.poll(() => document.querySelector('[data-screen-label^="Рынок"]'), T).not.toBeNull()
})

it('v6+v5 сосуществуют: /mpk (v6-роут) рендерит оболочку МПК', async () => {
  mountAppAt('/mpk')
  // Демо-фолбэк МПК: баннер проверки типа организации (typeStatus='under_review').
  await expect.element(page.getByText('Проверяем тип организации'), T).toBeInTheDocument()
})
