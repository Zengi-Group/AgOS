// AgOS · ARS-691 · Отрисовка отказа: общий тост и подсказка формы создания заявки.
//
// Спек: `Docs/AGOS-TSP-MpkErrorText-ARS-691.md`, строки матрицы M-016, M-017 и правило
// FR-004 (строка «Код: …» — 12px, цвет контейнера без приглушения). Сам выбор фразы —
// в `mpk-rpc-error-text.browser.test.ts`.
// Запуск: npm run test:routers.

import { afterEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import type { ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import '@/pages/cabinet/shell/cabinet.css'
import { Toast } from '@/pages/cabinet/shell/components/Toast'
import { CreatePoolModal } from '@/pages/cabinet/shell/mpk/modals/CreatePoolModal'

const rpcCalls = vi.hoisted(() => [] as string[])
// ARS-691 M-014 (мобильный): создание прошло, запуск вернул ответ без pool_id.
const net = vi.hoisted(() => ({ activateNoPoolId: false }))

vi.mock('@/lib/supabase', () => ({
  supabase: {
    rpc: async (fn: string) => {
      rpcCalls.push(fn)
      if (fn === 'rpc_get_grade_formula') return { data: null, error: null }
      if (fn === 'rpc_self_create_pool_request') {
        if (net.activateNoPoolId) return { data: 'req-1', error: null }
        return { data: null, error: { message: 'UNKNOWN_DIMENSION: livestock_condition' } }
      }
      if (fn === 'rpc_self_activate_pool_request' && net.activateNoPoolId) return { data: {}, error: null }
      throw new Error(`mpk-error-text-ui: незамоканный RPC ${fn}`)
    },
  },
}))

let root: Root | null = null
let mountEl: HTMLElement | null = null

function mount(node: ReactNode) {
  mountEl = document.createElement('div')
  mountEl.className = 'agos-cabinet-stage'
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  root.render(<QueryClientProvider client={qc}>{node}</QueryClientProvider>)
}

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
  rpcCalls.length = 0
  net.activateNoPoolId = false
})

const T = { timeout: 15_000 }

/** FR-004: строка кода — 12px и цвет контейнера, без приглушения. */
function expectCodeLineStyle(line: Element, container: Element) {
  const cs = getComputedStyle(line)
  expect(cs.fontSize).toBe('12px')
  expect(cs.opacity).toBe('1')
  expect(cs.color).toBe(getComputedStyle(container).color)
}

it('ARS-691 M-016: тост без code — одна строка, как сегодня (фермерская зона не меняется)', async () => {
  mount(<Toast toast={{ id: 1, text: 'Цена обновлена' }} />)

  await expect.element(page.getByText('Цена обновлена'), T).toBeInTheDocument()
  const toast = document.querySelector('.toast')!
  expect(toast.children.length, 'второй строки нет').toBe(0)
  expect(toast.textContent).toBe('Цена обновлена')
})

it('ARS-691 M-007 · FR-004: тост с code — фраза и под ней «Код: …» 12px цветом тоста', async () => {
  mount(<Toast toast={{ id: 2, text: 'Не удалось отправить оффер: Не удалось выполнить действие.', code: 'UNKNOWN_DIMENSION' }} />)

  await expect.element(page.getByText('Код: UNKNOWN_DIMENSION'), T).toBeInTheDocument()
  const toast = document.querySelector('.toast')!
  const line = toast.querySelector('.rpc-error-code')!
  expect(line.textContent).toBe('Код: UNKNOWN_DIMENSION')
  expectCodeLineStyle(line, toast)
})

it('ARS-691 M-017: форма создания (мобильный), база — незнакомый код: общая фраза и «Код: …», хвоста нет', async () => {
  const onSubmit = vi.fn()
  const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
  mount(<CreatePoolModal orgId="org-1" onClose={vi.fn()} onSubmit={onSubmit} />)

  await page.getByPlaceholder('Сколько голов').fill('100')
  await page.getByRole('button', { name: 'Этот месяц' }).click()
  await page.getByPlaceholder('Цена ₸/кг').fill('1700')
  await page.getByRole('button', { name: 'Опубликовать' }).click()

  await expect.poll(() => rpcCalls.includes('rpc_self_create_pool_request'), T).toBe(true)
  await expect.element(page.getByText('Код: UNKNOWN_DIMENSION'), T).toBeInTheDocument()
  const hint = Array.from(document.querySelectorAll('.mpk-error-hint'))
    .find((el) => el.textContent?.startsWith('Не удалось сохранить заявку:'))!
  expect(hint.textContent).toBe(
    'Не удалось сохранить заявку: Не удалось выполнить действие. Повторите или сообщите в поддержку.Код: UNKNOWN_DIMENSION',
  )
  expect(hint.textContent).not.toContain('livestock_condition')
  expectCodeLineStyle(hint.querySelector('.rpc-error-code')!, hint)
  expect(onSubmit, 'заявка не добавлена').not.toHaveBeenCalled()
  errSpy.mockRestore()
})

it('ARS-691 M-014 · FR-013 (мобильный): запуск без pool_id — собственный текст формы показан как есть, без кода', async () => {
  net.activateNoPoolId = true
  const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
  mount(<CreatePoolModal orgId="org-1" onClose={vi.fn()} onSubmit={vi.fn()} />)

  await page.getByPlaceholder('Сколько голов').fill('100')
  await page.getByRole('button', { name: 'Этот месяц' }).click()
  await page.getByPlaceholder('Цена ₸/кг').fill('1700')
  await page.getByRole('button', { name: 'Опубликовать' }).click()

  await expect.element(page.getByText('Не удалось сохранить заявку: Пул не активирован (нет pool_id)'), T).toBeInTheDocument()
  expect(document.querySelector('.mpk-error-hint .rpc-error-code')).toBeNull()
  errSpy.mockRestore()
})
