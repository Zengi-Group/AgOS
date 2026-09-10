// AgOS · Slice10 MP-3.7 (ARS-628) — SCR-P1 «Обзор». Строки матрицы: M-013 · M-014 · M-015 ·
// M-019, плюс FR-008 (честное состояние вместо выдуманных чисел), FR-014 (путь продления не
// мутирует и ведёт в TURAN) и правило M-016 («оценок пока нет», НЕ «0.0») в применении к
// сводке репутации.
//
// Монтируется НАСТОЯЩИЙ `<App />` с настоящей историей, как в `mpk-profile-router`, а не
// компонент в `MemoryRouter`: каждый CTA проверяется КЛИКОМ И ПЕРЕХОДОМ (`KEEP-25`). Первый
// заход утверждал только подписи кнопок — подмена цели в карте маршрутов прошла бы мимо
// `tsc` и мимо всех тестов, а «Требует внимания» — единственный экран, отвечающий «что
// требует действия».
//
// Мок сетевой границы диспетчеризуется ПО ИМЕНИ и бросает на незамоканном (`KEEP-22`):
// мок, отвечающий одинаково на любое имя, оставил бы зелёными все тесты при опечатке в
// имени RPC или параметра — экран не работал бы никогда и выглядел бы как разрыв связи.
//
// Фикстура по умолчанию — снимок ЖИВОГО прода (смоук ARS-646, `DECISIONS_LOG` 2026-09-09):
// admission `unknown`, гейт документов признаком, `days_left = null`, три сделочных числа
// признаком, `attention = []`. Это основной сценарий приёмки, не краевой. Но фикстура ОДНОГО
// состояния прода недостаточна: тесты ниже переопределяют `gates` под состояния, которых
// сегодня нет ни у кого (`KEEP-24`) — иначе из четырёх ветвей верификации прогонялась бы
// одна, а полоса прогресса не наблюдалась бы ни разу.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import type { AccountProfile } from '@/lib/account'
import App from '@/App'

const rpc = vi.hoisted(() => ({
  overview: null as unknown,
  overviewError: null as { message?: string } | null,
  // Задержка ответа — чтобы состояние ЗАГРУЗКИ было наблюдаемо. Без неё утверждение о
  // скелете приходилось писать дизъюнкцией «скелет ИЛИ заголовок», которая истинна, как
  // только появилось любое из двух, то есть про скелет не утверждала ничего (нашёл
  // ревьюер «пробел верификации», круг правок итерации 2).
  delayMs: 0,
  calls: [] as Array<{ fn: string; args: unknown }>,
}))

vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-ov-user', user_metadata: {}, phone: '' }
  const session = { access_token: 'smoke', refresh_token: 'smoke', token_type: 'bearer', expires_in: 3600, user }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: null }) as Promise<unknown> & Record<string, unknown>
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
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      },
      rpc: async (fn: string, args: unknown) => {
        rpc.calls.push({ fn, args })
        if (fn === 'rpc_get_mpk_profile_overview') {
          if (rpc.delayMs > 0) await new Promise((r) => setTimeout(r, rpc.delayMs))
          return { data: rpc.overview, error: rpc.overviewError }
        }
        // `KEEP-22`: молчаливый успех на незамоканном имени — это ложное «чисто».
        throw new Error(`mpk-profile-overview: незамоканный RPC ${fn}`)
      },
      from: () => chain(),
      channel: () => {
        const ch: Record<string, () => unknown> = {}
        for (const m of ['on', 'subscribe', 'unsubscribe']) ch[m] = () => ch
        return ch
      },
    },
  }
})

vi.mock('@/lib/account', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/account')>()
  return {
    ...actual,
    loadAccountProfile: async (): Promise<AccountProfile> => ({
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
      membershipVerification: null,
      subscriptionState: 'active',
      currentPeriodEnd: null,
      nextBillingAt: null,
    } as AccountProfile),
  }
})

const VERIFICATION_UNKNOWN = {
  kind: 'verification', tone: 'unknown', available: true,
  status: 'not_mpk', approved_at: null, pending_field_count: 0,
}
const MEMBERSHIP_LEGACY = {
  kind: 'membership', tone: 'ok', available: true, is_active: true, source: 'legacy_membership',
  days_left: null, current_period_end: null, plan_title: null, cta: 'contact_turan',
}
const DOCUMENTS_BLOCKED = { kind: 'documents', available: false, blocked_by: 'ARS-363' }

function overviewPayload(over: Record<string, unknown> = {}) {
  return {
    contract_version: 1,
    organization_id: 'org-1',
    admission: { status: 'unknown', checked_at: new Date().toISOString(), has_pending_reviews: false },
    gates: [VERIFICATION_UNKNOWN, MEMBERSHIP_LEGACY, DOCUMENTS_BLOCKED],
    attention: [],
    reputation: { review_count: 0, average_score: null, weight_accuracy_average: null },
    facts: {
      staff_active: 1,
      deals_closed: { available: false, blocked_by: 'ARS-668' },
      heads_accepted: { available: false, blocked_by: 'ARS-668' },
      supplier_orgs: { available: false, blocked_by: 'ARS-668' },
    },
    permissions: { 'mpk.review.submit': true },
    ...over,
  }
}

const HIDDEN_REVIEW = {
  kind: 'hidden_review', priority: 3, tone: 'info', count: 1,
  counterparty_name: 'КХ «Береке-Восток»', action: { type: 'open_reputation' },
}
const PENDING_REVIEW = {
  kind: 'pending_field_review', priority: 2, tone: 'warning',
  field_count: 2, fields: ['legal_name', 'bin_iin'], action: { type: 'open_org' },
}
const MEMBERSHIP_EXPIRING = {
  kind: 'membership_expiring', priority: 1, tone: 'warning',
  days_left: 12, current_period_end: null, action: { type: 'open_admission' },
}

const initialUrl = window.location.pathname + window.location.search
let root: Root | null = null
let mountEl: HTMLElement | null = null

function mountOverview() {
  window.history.replaceState(null, '', '/mpk/profile/overview')
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<App />)
}

const T = { timeout: 15_000 }
const q = (sel: string) => document.querySelector(`.agos-mpk-console ${sel}`)
const qa = (sel: string) => Array.from(document.querySelectorAll(`.agos-mpk-console ${sel}`))
const title = () => q('.mpkc-ov-adm-title')?.textContent?.trim()
const activeTabLabel = () =>
  document.querySelector('.agos-mpk-console [role="tab"][aria-selected="true"]')?.textContent?.trim() ?? null
const gate = (i: number) => qa('.mpkc-ov-gate')[i]

beforeEach(async () => {
  await page.viewport(1440, 900)
  expect(window.innerWidth, 'ширина раннера < 1024px — консоль подменяется заставкой').toBeGreaterThanOrEqual(1024)
  rpc.calls = []
  rpc.overview = overviewPayload()
  rpc.overviewError = null
  rpc.delayMs = 0
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

// ── KEEP-22 · чтение адресовано именно тому RPC и той организации

it('KEEP-22: экран читает rpc_get_mpk_profile_overview с p_organization_id организации', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  const call = rpc.calls.find((c) => c.fn === 'rpc_get_mpk_profile_overview')
  expect(call, 'агрегат «Обзора» не вызван').toBeTruthy()
  expect((call!.args as Record<string, unknown>).p_organization_id).toBe('org-1')
  // §3.0: один вызов на монтирование консоли, а не по одному на вкладку.
  expect(rpc.calls.filter((c) => c.fn === 'rpc_get_mpk_profile_overview')).toHaveLength(1)
})

// ── M-013 · нет данных верификации → «статус уточняется», НЕ «отказано»

it('M-013: admission unknown → заголовок «Статус уточняется», ни слова про отказ', async () => {
  mountOverview()

  await expect.poll(title, T).toBe('Статус уточняется')
  const card = q('.mpkc-ov-admission')
  expect(card?.className).toContain('tone-unknown')
  expect(card?.textContent).not.toContain('Закупки закрыты')
  expect(card?.textContent).not.toContain('отклонён')
  expect(q('.mpkc-ov-adm-sub')?.textContent).toContain('это не отказ')
})

it('M-013: admission allowed → «Допущен к закупкам» и подпись дословно из прототипа', async () => {
  rpc.overview = overviewPayload({
    admission: { status: 'allowed', checked_at: new Date().toISOString(), has_pending_reviews: false },
  })
  mountOverview()

  await expect.poll(title, T).toBe('Допущен к закупкам')
  expect(q('.mpkc-ov-adm-sub')?.textContent?.trim())
    .toBe('Верификация, членство и документы в порядке. Ограничений на заявки и приёмку нет.')
})

it('M-013: allowed с правками на проверке → второй вариант подписи прототипа', async () => {
  rpc.overview = overviewPayload({
    admission: { status: 'allowed', checked_at: new Date().toISOString(), has_pending_reviews: true },
  })
  mountOverview()

  await expect.poll(() => q('.mpkc-ov-adm-sub')?.textContent?.trim(), T)
    .toBe('Верификация, членство и документы в порядке. Изменения реквизитов проверяются — на закупки это не влияет.')
})

// §3.0 · «один дом вердикта» — по ВСЕМ пяти значениям перечня, а не по одному.
//
// Круг правок итерации 2: свойство было запиннено только на `restricted`, то есть на
// статусе, который никогда и не расходился. Состояние `allowed_conditional` — ровно то, из-за
// которого был откат (шапка говорила «Допуск не подтверждён» рядом с заголовком «Допущен с
// условиями») — не рендерилось ни одним тестом, и возврат дефекта прошёл бы зелёным.
const VERDICTS: Array<[status: string, label: string]> = [
  ['allowed', 'Допущен к закупкам'],
  ['allowed_conditional', 'Допущен с условиями'],
  ['restricted', 'Закупки закрыты'],
  ['pending', 'Проверка идёт'],
  ['unknown', 'Статус уточняется'],
]

for (const [status, label] of VERDICTS) {
  it(`M-013 · §3.0: бейдж и заголовок дают одну строку при admission = ${status}`, async () => {
    rpc.overview = overviewPayload({
      admission: { status, checked_at: new Date().toISOString(), has_pending_reviews: false },
    })
    mountOverview()

    await expect.poll(title, T).toBe(label)
    expect(q('.mpkc-badge')?.textContent?.trim(), 'шапка и заголовок разошлись').toBe(label)
  })
}

// ── Ветви гейта верификации, которых нет на сегодняшнем проде (`KEEP-24`)

const VERIFICATION_BRANCHES: Array<[status: string, value: string]> = [
  ['rejected', 'Не подтверждена'],
  ['expired', 'Истекла'],
  ['conditional', 'Подтверждена с условиями'],
  ['incomplete', 'Проверка не завершена'],
]

for (const [status, value] of VERIFICATION_BRANCHES) {
  it(`KEEP-24: гейт верификации при status = ${status} → «${value}»`, async () => {
    rpc.overview = overviewPayload({
      gates: [
        { ...VERIFICATION_UNKNOWN, tone: 'warning', status },
        MEMBERSHIP_LEGACY, DOCUMENTS_BLOCKED,
      ],
    })
    mountOverview()

    await expect.poll(() => gate(0)?.querySelector('.mpkc-ov-gate-value')?.textContent?.trim(), T)
      .toBe(value)
    // Подпись не обещает причину в разделе «Допуск» — он ещё заглушка (ARS-625).
    const note = gate(0)?.querySelector('.mpkc-ov-gate-note')?.textContent ?? ''
    expect(note).not.toContain('показано в разделе')
    expect(gate(0)?.querySelector('.mpkc-ov-gate-bar'), 'полоса без числа').toBeNull()
  })
}

it('KEEP-24: неактивное членство → «Членство неактивно», а не «Активно»', async () => {
  // Состояние не гипотетическое: у такой организации база отдаёт admission = restricted,
  // а гейт несёт is_active = false. Прежний пин этого состояния («Членство неактивно» в
  // бейдже) был снят вместе с клиентским выводом вердикта — возвращаем его на гейте.
  rpc.overview = overviewPayload({
    admission: { status: 'restricted', checked_at: new Date().toISOString(), has_pending_reviews: false },
    gates: [VERIFICATION_UNKNOWN, { ...MEMBERSHIP_LEGACY, tone: 'warning', is_active: false }, DOCUMENTS_BLOCKED],
  })
  mountOverview()

  await expect.poll(() => gate(1)?.querySelector('.mpkc-ov-gate-value')?.textContent?.trim(), T)
    .toBe('Членство неактивно')
  expect(gate(1)?.textContent).not.toContain('Активно')
  expect(gate(1)?.textContent).toContain('Без активного членства закупки закрыты.')
})

// ── M-014 · чтение упало: честный текст + retry, сырой текст SDK наружу не идёт

it('M-014: отказ чтения → честный текст и кнопка «Повторить», без текста SDK', async () => {
  rpc.overview = null
  rpc.overviewError = { message: 'TypeError: NetworkError when attempting to fetch resource' }
  mountOverview()

  await expect.poll(() => q('.mpkc-stub-title')?.textContent?.trim(), T)
    .toBe('Не удалось загрузить сводку по предприятию. Проверьте соединение и повторите.')
  expect(q('.mpkc-stub-act')?.textContent?.trim()).toBe('Повторить')
  expect(document.body.textContent).not.toContain('NetworkError')
  expect(document.body.textContent).not.toContain('TypeError')
})

it('M-014: «Повторить» повторно запрашивает агрегат и снимает ошибку', async () => {
  rpc.overview = null
  rpc.overviewError = { message: 'OVERVIEW_READ_FAILED' }
  mountOverview()
  await expect.poll(() => q('.mpkc-stub-act')?.textContent?.trim(), T).toBe('Повторить')

  const before = rpc.calls.length
  rpc.overview = overviewPayload()
  rpc.overviewError = null
  await page.getByRole('button', { name: 'Повторить' }).click()

  await expect.poll(title, T).toBe('Статус уточняется')
  expect(rpc.calls.length).toBeGreaterThan(before)
})

it('M-014: FORBIDDEN — терминальный отказ без «Повторить»', async () => {
  rpc.overview = null
  rpc.overviewError = { message: 'FORBIDDEN: not a member of organization abc' }
  mountOverview()

  await expect.poll(() => q('.mpkc-stub-title')?.textContent?.trim(), T).toBe('Нет доступа к этой организации')
  expect(q('.mpkc-stub-act')).toBeNull()
  expect(document.body.textContent).not.toContain('not a member of organization')
})

// ── M-015 · загрузка раздела: скелет, без белого провала

it('M-015: до ответа агрегата в теле раздела показан скелет', async () => {
  // Ответ задержан — иначе загрузка успевает закончиться до первого опроса DOM и
  // состояние, ради которого написана строка матрицы, нечем наблюдать.
  rpc.delayMs = 400
  mountOverview()

  await expect.poll(() => q('.mpkc-skel'), T).not.toBeNull()
  // Скелет не навсегда: данные приходят и тело раздела наполняется.
  await expect.poll(title, T).toBe('Статус уточняется')
  expect(q('.mpkc-skel')).toBeNull()
})

it('M-014: AUTH_REQUIRED — терминальный отказ без «Повторить»', async () => {
  rpc.overview = null
  rpc.overviewError = { message: 'AUTH_REQUIRED' }
  mountOverview()

  await expect.poll(() => q('.mpkc-stub-title')?.textContent?.trim(), T)
    .toBe('Нужно войти, чтобы увидеть сводку по предприятию')
  // «Повторить» повторил бы тот же отказ: истёкшей сессии нужен вход, а не повтор.
  expect(q('.mpkc-stub-act')).toBeNull()
})

// ── FR-008 · честное состояние вместо выдуманных чисел

it('FR-008: три сделочных числа приходят признаком → «пока не ведётся», а не «0»', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  const facts = qa('.mpkc-ov-fact')
  expect(facts).toHaveLength(4)   // пятая строка прототипа «Средний расчёт» снята контрактом ARS-646
  const na = qa('.mpkc-ov-fact.is-na')
  expect(na).toHaveLength(3)
  for (const row of na) {
    expect(row.textContent).toContain('пока не ведётся')
    expect(row.querySelector('.mpkc-ov-fact-value')?.textContent?.trim()).not.toBe('0')
  }
  const counted = facts.find((f) => !f.classList.contains('is-na'))
  expect(counted?.textContent).toContain('Сотрудников')
  expect(counted?.querySelector('.mpkc-ov-fact-value')?.textContent?.trim()).toBe('1')
})

it('FR-008: гейт документов — честная заглушка с указателем, без «5 из 5»', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  expect(qa('.mpkc-ov-gate')).toHaveLength(3)
  const docs = gate(2)
  expect(docs?.textContent).toContain('Документы')
  expect(docs?.textContent).toContain('Пока не ведётся')
  expect(docs?.textContent).toContain('ARS-363')
  expect(docs?.textContent).not.toContain('5 из 5')
  expect(docs?.querySelector('.mpkc-ov-gate-bar')).toBeNull()
})

it('FR-008: days_left = null при активном членстве → «Активно», без полосы и без «0 дней»', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  const membership = gate(1)
  expect(membership?.textContent).toContain('Членство в ассоциации')
  expect(membership?.textContent).toContain('Активно')
  expect(membership?.textContent).not.toContain('0 дней')
  expect(membership?.textContent).not.toContain('до конца')
  expect(membership?.querySelector('.mpkc-ov-gate-bar')).toBeNull()
})

it('FR-008: пустой список внимания — посчитанное «чисто», а не «не считалось»', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  expect(q('.mpkc-ov-count')?.textContent?.trim()).toBe('0')
  expect(q('.mpkc-ov-clean')?.textContent).toContain('Ничего не требует действий — профиль в порядке.')
  expect(qa('.mpkc-ov-todo-row')).toHaveLength(0)
})

// ── KEEP-24 · состояния, которых на сегодняшнем проде НЕТ ни у кого

it('KEEP-24: верификация approved → полоса есть и подпись несёт дату', async () => {
  rpc.overview = overviewPayload({
    gates: [
      {
        kind: 'verification', tone: 'ok', available: true,
        status: 'approved', approved_at: '2026-05-12T08:00:00Z', pending_field_count: 0,
      },
      MEMBERSHIP_LEGACY,
      DOCUMENTS_BLOCKED,
    ],
  })
  mountOverview()
  await expect.poll(() => gate(0)?.textContent?.includes('Подтверждена'), T).toBe(true)

  // Единственное состояние с посчитанной полнотой — и единственное, где рисуется полоса.
  expect(gate(0)?.querySelector('.mpkc-ov-gate-bar')).not.toBeNull()
  const note = gate(0)?.querySelector('.mpkc-ov-gate-note')?.textContent ?? ''
  expect(note).toContain('TURAN Compliance')
  expect(note).toContain('2026')
  // Суффикс «г.» русской локали снимается — прототип его не несёт (L1996).
  expect(note).not.toContain(' г.')
})

it('KEEP-24: членство с days_left = 12 → склонение, план и срок', async () => {
  rpc.overview = overviewPayload({
    gates: [
      VERIFICATION_UNKNOWN,
      {
        // Полдень, а не полночь UTC: у полуночного момента дата съезжает на сутки на любом
        // раннере западнее UTC, и тест начал бы падать по таймзоне, а не по коду.
        ...MEMBERSHIP_LEGACY, source: 'subscription', days_left: 12,
        current_period_end: '2026-08-07T12:00:00Z', plan_title: 'Мясной союз Казахстана', cta: 'manage',
      },
      DOCUMENTS_BLOCKED,
    ],
  })
  mountOverview()

  await expect.poll(() => gate(1)?.querySelector('.mpkc-ov-gate-value')?.textContent?.trim(), T)
    .toBe('12 дней до конца')
  const note = gate(1)?.querySelector('.mpkc-ov-gate-note')?.textContent ?? ''
  expect(note).toContain('Мясной союз Казахстана')
  expect(note).toContain('до 7 августа 2026')
})

it('KEEP-19: days_left = 0 → «Истекает сегодня», а не «0 дней до конца»', async () => {
  rpc.overview = overviewPayload({
    gates: [VERIFICATION_UNKNOWN, { ...MEMBERSHIP_LEGACY, days_left: 0 }, DOCUMENTS_BLOCKED],
  })
  mountOverview()

  await expect.poll(() => gate(1)?.querySelector('.mpkc-ov-gate-value')?.textContent?.trim(), T)
    .toBe('Истекает сегодня')
  expect(gate(1)?.textContent).not.toContain('0 дней')
})

it('KEEP-24: верификация с правками на проверке → счётчик и срок, полосы нет', async () => {
  rpc.overview = overviewPayload({
    gates: [
      { ...VERIFICATION_UNKNOWN, tone: 'warning', status: 'incomplete', pending_field_count: 2 },
      MEMBERSHIP_LEGACY, DOCUMENTS_BLOCKED,
    ],
  })
  mountOverview()

  await expect.poll(() => gate(0)?.querySelector('.mpkc-ov-gate-value')?.textContent?.trim(), T)
    .toBe('Проверка изменений')
  expect(gate(0)?.textContent).toContain('2 изменения на проверке · 2–5 раб. дней')
  expect(gate(0)?.querySelector('.mpkc-ov-gate-bar')).toBeNull()
})

// ── KEEP-14 · значение вне закрытого перечня не подписывается чужим текстом

it('KEEP-14: неизвестный вид гейта пропускается, а не рисуется как «Документы»', async () => {
  rpc.overview = overviewPayload({
    gates: [VERIFICATION_UNKNOWN, MEMBERSHIP_LEGACY, DOCUMENTS_BLOCKED, { kind: 'что-то_новое', available: true }],
  })
  mountOverview()
  await expect.poll(() => qa('.mpkc-ov-gate').length, T).toBe(3)

  expect(document.body.textContent).not.toContain('undefined')
  expect(qa('.mpkc-ov-gate').filter((g) => g.textContent?.includes('Документы'))).toHaveLength(1)
})

it('KEEP-14: неизвестный вид пункта внимания пропускается, а не подписывается как скрытый отзыв', async () => {
  rpc.overview = overviewPayload({
    attention: [{ kind: 'appeal_open', priority: 4, tone: 'warning', action: { type: 'open_admission' } }],
  })
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  expect(qa('.mpkc-ov-todo-row')).toHaveLength(0)
  expect(document.body.textContent).not.toContain('Отзыв поставщика скрыт')
  // Круг правок итерации 2: раньше проверялось только число строк, а счётчик и пустое
  // состояние считались по НЕотфильтрованному списку — экран показывал «1» при нуле строк
  // и без «Ничего не требует действий».
  expect(q('.mpkc-ov-count')?.textContent?.trim()).toBe('0')
  expect(q('.mpkc-ov-clean')?.textContent).toContain('Ничего не требует действий')
})

it('KEEP-14: гейт документов без признака недоступности пропускается, а не печатает «(undefined)»', async () => {
  rpc.overview = overviewPayload({
    gates: [VERIFICATION_UNKNOWN, MEMBERSHIP_LEGACY, { kind: 'documents', available: true }],
  })
  mountOverview()
  await expect.poll(() => qa('.mpkc-ov-gate').length, T).toBe(2)

  expect(document.body.textContent).not.toContain('undefined')
  expect(document.body.textContent).not.toContain('Пока не ведётся')
})

it('KEEP-3: пропавший ключ фактов даёт честный отказ, а не белый экран', async () => {
  const facts = {
    staff_active: 1,
    heads_accepted: { available: false, blocked_by: 'ARS-668' },
    supplier_orgs: { available: false, blocked_by: 'ARS-668' },
  }
  rpc.overview = overviewPayload({ facts })
  mountOverview()

  // Раньше `formatNumber(undefined)` ронял `toLocaleString`, и консоль уходила в пустой
  // экран. Теперь форма не распознана — и это видно человеку.
  await expect.poll(() => q('.mpkc-stub-title')?.textContent?.trim(), T)
    .toBe('Контракт ответа не распознан. Обновите страницу.')
})

it('KEEP-3: строка вместо числа в репутации даёт честный отказ, а не «оценок пока нет»', async () => {
  rpc.overview = overviewPayload({
    reputation: { review_count: 18, average_score: '4.7', weight_accuracy_average: null },
  })
  mountOverview()

  await expect.poll(() => q('.mpkc-stub-title')?.textContent?.trim(), T)
    .toBe('Контракт ответа не распознан. Обновите страницу.')
})

// ── Правило M-016 в применении к сводке на «Обзоре»

it('M-016 (правило): нет раскрытых отзывов → «оценок пока нет», НЕ «0.0»', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  const rep = q('.mpkc-ov-rep')
  expect(rep?.textContent).toContain('оценок пока нет')
  // Запятая, а не точка: форматтер печатает ru-RU, поэтому утверждение против «0.0» не
  // могло упасть НИКОГДА — даже если пустое состояние сломается и нарисует «0,0».
  // Круг правок итерации 2 (нашёл ревьюер «пробел верификации»).
  expect(rep?.textContent).not.toContain('0,0')
  expect(rep?.querySelector('.mpkc-ov-rep-num')).toBeNull()
})

it('M-016 (правило): есть раскрытые отзывы → средняя оценка и число оценок', async () => {
  rpc.overview = overviewPayload({
    reputation: { review_count: 18, average_score: 4.7, weight_accuracy_average: 4.5 },
  })
  mountOverview()

  await expect.poll(() => q('.mpkc-ov-rep-num')?.textContent?.trim(), T).toBe('4,7')
  const rep = q('.mpkc-ov-rep')
  expect(rep?.textContent).toContain('из 5 · оценки фермеров')
  expect(rep?.textContent).toContain('18 оценок')
  // Подпись второй размерности — из справочника review_dimensions, не прототипная.
  expect(rep?.textContent).toContain('Соответствие заявленному весу')
  expect(qa('.mpkc-ov-dim')).toHaveLength(2)
})

it('размерность без своего числа не рисуется', async () => {
  rpc.overview = overviewPayload({
    reputation: { review_count: 3, average_score: 5, weight_accuracy_average: null },
  })
  mountOverview()

  await expect.poll(() => qa('.mpkc-ov-dim').length, T).toBe(1)
  expect(q('.mpkc-ov-rep')?.textContent).toContain('Общая оценка')
  expect(q('.mpkc-ov-rep')?.textContent).toContain('3 оценки')
})

// ── M-019 · без права раздел read-only: данные видны, действие недоступно С ПОЯСНЕНИЕМ

it('M-019: без mpk.review.submit пункт виден, кнопки нет, и это ОБЪЯСНЕНО', async () => {
  rpc.overview = overviewPayload({
    attention: [HIDDEN_REVIEW], permissions: { 'mpk.review.submit': false },
  })
  mountOverview()

  await expect.poll(() => qa('.mpkc-ov-todo-row').length, T).toBe(1)
  const row = qa('.mpkc-ov-todo-row')[0]
  expect(row?.textContent).toContain('Отзыв КХ «Береке-Восток» скрыт')
  expect(row?.textContent).toContain('Оцените поставщика — отзывы откроются у обеих сторон.')
  expect(row?.querySelector('.mpkc-ov-btn')).toBeNull()
  // Третья клаузула M-019: отсутствия кнопки недостаточно — нужно пояснение.
  expect(row?.querySelector('.mpkc-ov-todo-denied')?.textContent)
    .toBe('Оценить может сотрудник с правом на отзывы.')
})

it('M-019: с правом кнопка «Оценить» появляется, пояснения нет', async () => {
  rpc.overview = overviewPayload({ attention: [HIDDEN_REVIEW] })
  mountOverview()

  await expect.poll(() => qa('.mpkc-ov-todo-row').length, T).toBe(1)
  const row = qa('.mpkc-ov-todo-row')[0]
  expect(row?.querySelector('.mpkc-ov-btn')?.textContent?.trim()).toBe('Оценить')
  expect(row?.querySelector('.mpkc-ov-todo-denied')).toBeNull()
})

it('несколько скрытых отзывов не схлопываются в имя одного контрагента', async () => {
  rpc.overview = overviewPayload({
    attention: [{ ...HIDDEN_REVIEW, count: 3 }],
  })
  mountOverview()

  await expect.poll(() => q('.mpkc-ov-todo-t')?.textContent?.trim(), T).toBe('3 отзыва поставщиков скрыты')
  expect(q('.mpkc-ov-todo-t')?.textContent).not.toContain('Береке-Восток')
})

it('пункты внимания сортируются по priority, а не по порядку в ответе', async () => {
  rpc.overview = overviewPayload({ attention: [HIDDEN_REVIEW, MEMBERSHIP_EXPIRING, PENDING_REVIEW] })
  mountOverview()

  await expect.poll(() => qa('.mpkc-ov-todo-row').length, T).toBe(3)
  const rows = qa('.mpkc-ov-todo-t').map((n) => n.textContent?.trim())
  expect(rows[0]).toBe('Членство истекает через 12 дней')   // прототип L2012
  expect(rows[1]).toBe('Реквизиты на повторной проверке')   // прототип L2013
  expect(rows[2]).toBe('Отзыв КХ «Береке-Восток» скрыт')    // прототип L2014
  // Фраза собрана тем же словарём подписи поля, что и раздел «Предприятие» (P4, KEEP-5).
  expect(qa('.mpkc-ov-todo-s')[1]?.textContent)
    .toContain('На проверке: наименование, БИН · 2–5 рабочих дней. На закупки не влияет.')
})

// ── KEEP-25 · каждый CTA проверяется КЛИКОМ И ПЕРЕХОДОМ, а не подписью кнопки

it('KEEP-25: «Открыть допуск» у гейта верификации уводит на вкладку «Допуск»', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  ;(gate(0)?.querySelector('.mpkc-ov-link') as HTMLButtonElement).click()
  await expect.poll(activeTabLabel, T).toBe('Допуск')
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/adm')
})

it('KEEP-25: «Посмотреть» у правок на проверке уводит на «Предприятие», а не на «Допуск»', async () => {
  rpc.overview = overviewPayload({ attention: [PENDING_REVIEW] })
  mountOverview()
  await expect.poll(() => qa('.mpkc-ov-todo-row').length, T).toBe(1)

  await page.getByRole('button', { name: 'Посмотреть' }).click()
  await expect.poll(activeTabLabel, T).toBe('Предприятие')
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/org')
})

it('KEEP-25: «Отзывы фермеров →» уводит на вкладку «Репутация» (§3, goRep)', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  ;(q('.mpkc-ov-rep .mpkc-ov-link') as HTMLButtonElement).click()
  await expect.poll(activeTabLabel, T).toBe('Репутация')
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/rep')
})

it('KEEP-15: «Написать в TURAN» у гейта документов ведёт в достижимый путь, а не в заглушку', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  ;(gate(2)?.querySelector('.mpkc-ov-link') as HTMLButtonElement).click()
  // Достижимый путь — экран, с которого открывается обращение в TURAN. Раздела документов
  // в мобильном шелле НЕ существует, поэтому «Открыть в мобильном кабинете» было бы ложным
  // обещанием.
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

// Круг правок итерации 2: два CTA проверялись подписью, а не переходом — и именно на них
// висел дефект маршрутизации. Ниже оба закрыты кликом.

it('KEEP-25: «Оценить» уводит на вкладку «Репутация», а не куда-нибудь ещё', async () => {
  rpc.overview = overviewPayload({ attention: [HIDDEN_REVIEW] })
  mountOverview()
  await expect.poll(() => qa('.mpkc-ov-todo-row').length, T).toBe(1)

  await page.getByRole('button', { name: 'Оценить' }).click()
  await expect.poll(activeTabLabel, T).toBe('Репутация')
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/rep')
})

it('KEEP-16: ссылка гейта членства ведёт в TURAN при legacy-членстве', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  ;(gate(1)?.querySelector('.mpkc-ov-link') as HTMLButtonElement).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

it('KEEP-16: ссылка гейта членства ведёт в TURAN и при cta = manage, а не в заглушку «Допуск»', async () => {
  // Это состояние живой подписки. Первая редакция перевывода уводила его в незастроенную
  // заглушку `adm` — тот же дефект «названный, но недостижимый путь», из-за которого CTA
  // и переписывали. Ветка достижима по коду, хотя на сегодняшнем проде подписок нет.
  rpc.overview = overviewPayload({
    gates: [
      VERIFICATION_UNKNOWN,
      { ...MEMBERSHIP_LEGACY, source: 'subscription', days_left: 40, cta: 'manage' },
      DOCUMENTS_BLOCKED,
    ],
  })
  mountOverview()
  await expect.poll(() => gate(1)?.textContent?.includes('40 дней до конца'), T).toBe(true)

  ;(gate(1)?.querySelector('.mpkc-ov-link') as HTMLButtonElement).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
  expect(window.location.pathname).not.toBe('/mpk/profile/adm')
})

it('FR-014/KEEP-16: «Продлить» ведёт в обращение в TURAN и НЕ мутирует подписку', async () => {
  rpc.overview = overviewPayload({ attention: [MEMBERSHIP_EXPIRING] })
  mountOverview()
  await expect.poll(() => qa('.mpkc-ov-todo-row').length, T).toBe(1)

  // FR-014 проверяется НА САМОМ ОБРАБОТЧИКЕ, а не по общему счётчику вызовов: переход на
  // `/mpk` монтирует мобильный шелл с его собственными (законными) чтениями, и счётчик
  // всего прогона вырос бы от них. Первая редакция этого теста считала все вызовы и падала
  // в полном прогоне, проходя в одиночном — то есть проверяла скорость, а не требование.
  // Нативный `.click()` доставляется синхронно, обработчик React выполняется синхронно,
  // поэтому вызов `supabase.rpc` из него попал бы в журнал ДО следующей проверки.
  const button = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-ov-btn'))
    .find((b) => b.textContent?.trim() === 'Продлить') as HTMLButtonElement
  expect(button, 'кнопка «Продлить» не найдена').toBeTruthy()

  const callsBefore = rpc.calls.length
  button.click()
  expect(rpc.calls.length, 'кнопка продления обратилась в RPC — FR-014 запрещает мутацию').toBe(callsBefore)

  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

// ── KEEP-26 · критерий 11 по разметке НОВОГО раздела

it('критерий 11: в теле «Обзора» только Phosphor-иконки (viewBox 256)', async () => {
  mountOverview()
  await expect.poll(title, T).toBe('Статус уточняется')

  const svgs = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-ov svg'))
  expect(svgs.length, 'в теле раздела нет ни одной иконки — проверять нечего').toBeGreaterThan(0)
  expect(svgs.filter((s) => s.getAttribute('viewBox') !== '0 0 256 256').map((s) => s.getAttribute('viewBox')))
    .toEqual([])
  expect(document.querySelectorAll('.agos-mpk-console .mpkc-ov svg.lucide')).toHaveLength(0)
})
