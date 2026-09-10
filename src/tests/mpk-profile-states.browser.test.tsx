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

// ── MP-3.7 (`KEEP-23`): мок сетевой границы ОБЯЗАТЕЛЕН здесь с тех пор, как таб `overview`
// перестал быть статичной заглушкой. До него этот файл мокал только `@/lib/account`, а
// раздел уходил РЕАЛЬНЫМ `supabase.rpc` в сеть: локально при живом `.env` — в настоящую
// базу, в CI — в placeholder-хост. Тесты при этом оставались зелёными (они утверждают
// шапку), то есть дефект был молчащим. Нашёл ревьюер «пробел верификации».
//
// Диспетчер ПО ИМЕНИ и `throw` на незамоканном (`KEEP-22`, приём
// `mpk-profile-org-section.browser.test.tsx`): мок, отвечающий одинаково на любое имя,
// пропустил бы опечатку в имени RPC — экран не работал бы никогда, а тесты не заметили.
const rpc = vi.hoisted(() => ({
  overview: null as unknown,
  overviewError: null as { message?: string } | null,
  // Задержка ответа — чтобы окно загрузки было наблюдаемо (§3.0 п.2).
  delayMs: 0,
  calls: 0,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-states-user', user_metadata: {}, phone: '' }
  const session = { access_token: 'smoke', refresh_token: 'smoke', token_type: 'bearer', expires_in: 3600, user }
  return {
    supabase: {
      auth: {
        getSession: async () => ({ data: { session }, error: null }),
        getUser: async () => ({ data: { user }, error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      },
      rpc: async (fn: string) => {
        rpc.calls += 1
        if (fn === 'rpc_get_mpk_profile_overview') {
          if (rpc.delayMs > 0) await new Promise((r) => setTimeout(r, rpc.delayMs))
          return { data: rpc.overview, error: rpc.overviewError }
        }
        throw new Error(`mpk-profile-states: незамоканный RPC ${fn}`)
      },
      from: () => Promise.resolve({ data: null, error: null }),
      channel: () => {
        const ch: Record<string, () => unknown> = {}
        for (const m of ['on', 'subscribe', 'unsubscribe']) ch[m] = () => ch
        return ch
      },
    },
  }
})

// Ответ агрегата: только то, что читает ШАПКА, плюс обязательные ключи проверки формы.
// Полный экран проверяется в `mpk-profile-overview.browser.test.tsx`.
function overviewWith(status: string) {
  return {
    contract_version: 1,
    organization_id: 'org-1',
    admission: { status, checked_at: new Date().toISOString(), has_pending_reviews: false },
    gates: [],
    attention: [],
    reputation: null,
    facts: {
      staff_active: 0,
      deals_closed: { available: false, blocked_by: 'ARS-668' },
      heads_accepted: { available: false, blocked_by: 'ARS-668' },
      supplier_orgs: { available: false, blocked_by: 'ARS-668' },
    },
    permissions: { 'mpk.review.submit': false },
  }
}

// Профиль-заготовка: заполняем только те поля, которые читает оболочка SCR-P0.
function profileWith(
  verificationStatus: string | null,
  membershipActive: boolean,
  name = 'МК «Семей Ет»',
): AccountProfile {
  return {
    userId: 'u1',
    orgId: 'org-1',
    name,
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
  // По умолчанию профиль ЕСТЬ. С MP-3.7 он нужен не бейджу, а только для `orgId`: без
  // организации оболочка осознанно не зовёт агрегат вовсе, и бейдж не появляется — тест
  // проходил бы «зелёным» по причине, не имеющей отношения к его предмету.
  // Аргумент статуса верификации на бейдж больше НЕ влияет (§3.0) — он лишь наполняет фикстуру.
  loader.impl = async () => profileWith('approved', true)
  rpc.calls = 0
  rpc.overview = overviewWith('unknown')
  rpc.overviewError = null
  rpc.delayMs = 0
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
})

const T = { timeout: 15_000 }
const badge = () => document.querySelector('.agos-mpk-console .mpkc-badge')

// ── MP-3.7 (§3.0, решение владельца 2026-09-09): ИСТОЧНИК БЕЙДЖА СМЕНИЛСЯ.
//
// Строка матрицы `M-013` та же и держится тут же, но фикстуры переехали с
// `loadAccountProfile` на `admission.status` агрегата — вместе с домом факта. Прежние тесты
// драйвили `verification.status` + членство и утверждали формулировки клиентского вывода
// (`admissionBadge`), которого больше нет: он считал вердикт второй раз и расходился с
// заголовком «Обзора» при `conditional`.
//
// ЧТО ЭТО МЕНЯЕТ ДЛЯ ПОЛЬЗОВАТЕЛЯ — названо прямо, а не спрятано в правке теста: перечень
// базы схлопывает `rejected`/`expired` в `restricted`, а `not_mpk` в `unknown`, поэтому
// бейдж больше НЕ говорит «Допуск отклонён» и «Организация не заявлена как МПК». Причину
// теперь называет гейт верификации на «Обзоре» («Не подтверждена» / «Данных пока нет») —
// то есть там, где прототип её и объясняет. Шапка отвечает «можно/нельзя», гейты — «почему».

// M-013 · нет данных верификации → «статус уточняется», НЕ «отказано».
it('M-013: admission unknown → бейдж «Статус уточняется» и нейтрален', async () => {
  rpc.overview = overviewWith('unknown')
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Статус уточняется')
  expect(badge()?.className).toContain('neutral')
  expect(badge()?.className).not.toContain('red')
})

it('M-013: admission allowed → зелёное «Допущен к закупкам»', async () => {
  rpc.overview = overviewWith('allowed')
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Допущен к закупкам')
  expect(badge()?.className).toContain('green')
})

// Intent: бейдж отвечает на «можем ли мы закупать прямо сейчас». Неактивное членство и
// отклонённая верификация оба дают `restricted` — обещать допуск нельзя ни в том, ни в
// другом случае.
it('M-013: admission restricted не обещает допуск к закупкам', async () => {
  rpc.overview = overviewWith('restricted')
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Закупки закрыты')
  expect(badge()?.textContent).not.toContain('Допущен к закупкам')
})

// §3.0 п.2: до прихода вердикта бейджа НЕТ — ни пустого, ни с подписью-заполнителем.
// Регрессия, которую держит этот тест: возврат клиентского вывода статуса в шапку.
it('M-013: пока агрегат НЕ ОТВЕТИЛ, бейдж не показывается вовсе', async () => {
  // Круг правок итерации 2: прежняя редакция задавала ОШИБКУ чтения и называлась «пока не
  // ответил» — то есть наблюдала состояние отказа, а окно загрузки, которое §3.0 п.2 и
  // описывает, не наблюдалось ничем. Теперь ответ действительно висит.
  rpc.delayMs = 600
  mountConsoleAt('/mpk/profile/overview')

  // Шапка уже на месте — значит наблюдаем именно отсутствие бейджа, а не незагруженный экран.
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-head-mono'), T).not.toBeNull()
  expect(badge(), 'бейдж появился до ответа базы — значит статус выведен на клиенте').toBeNull()

  // И появляется, как только вердикт пришёл.
  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Статус уточняется')
})

it('M-013: при отказе чтения агрегата бейджа тоже нет', async () => {
  rpc.overview = null
  rpc.overviewError = { message: 'OVERVIEW_READ_FAILED' }
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-head-mono'), T).not.toBeNull()
  expect(badge()).toBeNull()
})

// Значение вне закрытого перечня (`KEEP-14`) рисуется как `unknown`, а не пустой строкой.
it('M-013: неизвестный admission.status читается как «Статус уточняется»', async () => {
  rpc.overview = overviewWith('какой-то-новый-статус')
  mountConsoleAt('/mpk/profile/overview')

  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Статус уточняется')
})

// Монограмма шапки (`pr_mono`, §2) — инициалы ПРЕДПРИЯТИЯ, не формы собственности.
// Регрессия найдена прогоном против реальной базы 03.09.2026: «ТОО QA-Тест МПК» давало
// «ТQ». Кавычек в реальных названиях может не быть — это обычный случай, не исключение.
it('монограмма берёт имя предприятия, а не организационно-правовую форму', async () => {
  const mono = () => document.querySelector('.agos-mpk-console .mpkc-head-mono')?.textContent

  loader.impl = async () => profileWith('approved', true, 'ТОО QA-Тест МПК')
  mountConsoleAt('/mpk/profile/overview')
  await expect.poll(() => mono(), T).toBe('QМ')

  // Кавычки по-прежнему главнее: имя внутри них, форма снаружи игнорируется.
  root?.unmount(); mountEl?.remove()
  loader.impl = async () => profileWith('approved', true, 'МК «Семей Ет»')
  mountConsoleAt('/mpk/profile/overview')
  await expect.poll(() => mono(), T).toBe('СЕ')

  // Без кавычек и без формы — просто первые две буквы слов.
  root?.unmount(); mountEl?.remove()
  loader.impl = async () => profileWith('approved', true, 'Агрофирма Восток')
  mountConsoleAt('/mpk/profile/overview')
  await expect.poll(() => mono(), T).toBe('АВ')

  // Форма без имени не должна схлопнуть монограмму в пустоту.
  root?.unmount(); mountEl?.remove()
  loader.impl = async () => profileWith('approved', true, 'ТОО')
  mountConsoleAt('/mpk/profile/overview')
  await expect.poll(() => mono(), T).toBe('ТО')
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
  // Бейдж придёт из агрегата, а не из профиля (§3.0): восстановление экрана видно по
  // вердикту базы, поэтому агрегат тоже должен отвечать содержательно.
  rpc.overview = overviewWith('allowed')
  await page.getByRole('button', { name: 'Повторить' }).click()

  await expect.poll(() => loader.calls, T).toBeGreaterThan(callsBefore)
  await expect.poll(() => badge()?.textContent?.trim(), T).toBe('Допущен к закупкам')
  expect(document.body.textContent).not.toContain('Не удалось загрузить данные предприятия')
})
