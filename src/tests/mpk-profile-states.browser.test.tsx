// AgOS · Slice10 MP-3.1 · SCR-P0 — состояния консоли, зависящие от данных.
// Строки матрицы: M-013 (пусто ≠ «отказано») и M-014 (сеть недоступна → честный текст +
// retry), плюс правило Intent «можем ли мы закупать прямо сейчас»: бейдж не имеет права
// обещать допуск при неактивном членстве.
//
// Отдельный файл, потому что здесь мокается не сетевая граница, а сам загрузчик
// `@/lib/account`: под моком supabase из mpk-profile-router `loadAccountProfile` всегда
// РЕЗОЛВИТСЯ в null (ошибку RPC он гасит внутри), поэтому ни ветка ошибки, ни статусы
// верификации там недостижимы в принципе.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import type { AccountProfile } from '@/lib/account'
import { MpkProfileApp } from '@/pages/cabinet/shell/mpk/profile/MpkProfileApp'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

// Управляемый загрузчик: каждый тест задаёт, чем ответит `loadAccountProfile`.
const loader = vi.hoisted(() => ({
  impl: async (): Promise<AccountProfile | null> => null,
  calls: 0,
}))

vi.mock('@/lib/account', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/account')>()
  return {
    ...actual,
    loadAccountProfile: async () => { loader.calls += 1; return loader.impl() },
  }
})

// Профиль-заготовка: заполняем только те поля, которые читает оболочка SCR-P0.
function profileWith(
  verificationStatus: string | null,
  membershipActive: boolean,
): AccountProfile {
  return {
    userId: 'u1',
    orgId: 'org-1',
    name: 'МК «Семей Ет»',
    bin: '180440021345',
    district: 'Абайский район',
    ownerName: 'Дамир Оспанов',
    legalForm: null,
    phone: null,
    orgTypes: ['mpk'],
    membershipLevel: 'standard',
    applicationStatus: null,
    membershipVerification: {
      version: 1,
      organizationId: 'org-1',
      associationNumber: 'TRN-0042',
      membership: {
        isActive: membershipActive,
        source: 'subscription',
        state: membershipActive ? 'active' : 'expired',
        trialEnd: null,
        currentPeriodStart: null,
        currentPeriodEnd: null,
        nextBillingAt: null,
        cancelAtPeriodEnd: null,
        subscriptionId: null,
        plan: null,
        renewalMode: null,
        cta: null,
      },
      verification: verificationStatus === null ? null : {
        membershipId: null,
        status: verificationStatus as never,
        typeAssignment: null,
        timeline: [],
        latestByType: [],
      },
    },
    subscriptionState: membershipActive ? 'active' : 'expired',
    currentPeriodEnd: null,
    nextBillingAt: null,
  } as AccountProfile
}

let root: Root | null = null
let mountEl: HTMLElement | null = null

// Консоль монтируется напрямую: маршрутизация и redirect'ы проверяются в
// mpk-profile-router, здесь предмет — только содержимое шапки и тела.
function mountConsoleAt(path: string) {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/mpk/profile/*" element={<MpkProfileApp />} />
      </Routes>
    </MemoryRouter>,
  )
}

beforeEach(async () => {
  await page.viewport(1440, 900)
  loader.calls = 0
  loader.impl = async () => null
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
})

const T = { timeout: 15_000 }
const badge = () => document.querySelector('.agos-mpk-console .mpkc-badge')

// M-013 · нет данных верификации → «статус уточняется», НЕ «отказано».
it('M-013: без данных верификации бейдж читается «Статус уточняется» и нейтрален', async () => {
  loader.impl = async () => null
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Статус уточняется')
  expect(badge()?.className).toContain('neutral')
  expect(badge()?.className).not.toContain('red')
})

it('M-013: approved с активным членством → зелёное «Допущен к закупкам»', async () => {
  loader.impl = async () => profileWith('approved', true)
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Допущен к закупкам')
  expect(badge()?.className).toContain('green')
})

// Intent: бейдж отвечает на «можем ли мы закупать прямо сейчас». Одобренная верификация
// при неактивном членстве закупок не открывает — обещать допуск нельзя.
it('M-013: approved при неактивном членстве не обещает допуск к закупкам', async () => {
  loader.impl = async () => profileWith('approved', false)
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Членство неактивно')
  expect(badge()?.textContent).not.toContain('Допущен к закупкам')
})

it('M-013: rejected → «Допуск отклонён», not_mpk не выдаётся за незавершённую проверку', async () => {
  loader.impl = async () => profileWith('rejected', true)
  mountConsoleAt('/mpk/profile/overview')
  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Допуск отклонён')

  root?.unmount(); mountEl?.remove()
  loader.impl = async () => profileWith('not_mpk', true)
  mountConsoleAt('/mpk/profile/overview')
  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Организация не заявлена как МПК')
})

// M-014 · чтение упало: честный текст + retry; сырой текст SDK наружу не идёт.
it('M-014: при отказе чтения показан честный текст и кнопка «Повторить»', async () => {
  const raw = 'TypeError: Failed to fetch (supabase-js internal)'
  loader.impl = async () => { throw new Error(raw) }
  mountConsoleAt('/mpk/profile/overview')

  await expect.element(page.getByText('Не удалось загрузить данные предприятия'), T).toBeInTheDocument()
  // Техническая деталь остаётся в console.error, на экран не попадает (урок IDENTITY-14).
  expect(document.body.textContent).not.toContain('Failed to fetch')
  expect(document.body.textContent).not.toContain('TypeError')
})

it('M-014: «Повторить» повторно запрашивает данные и снимает ошибку', async () => {
  loader.impl = async () => { throw new Error('offline') }
  mountConsoleAt('/mpk/profile/overview')
  await expect.element(page.getByText('Не удалось загрузить данные предприятия'), T).toBeInTheDocument()

  const callsBefore = loader.calls
  loader.impl = async () => profileWith('approved', true)
  await page.getByRole('button', { name: 'Повторить' }).click()

  await expect.poll(() => loader.calls, T).toBeGreaterThan(callsBefore)
  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Допущен к закупкам')
  expect(document.body.textContent).not.toContain('Не удалось загрузить данные предприятия')
})
