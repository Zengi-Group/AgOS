// AgOS · Slice10 MP-3.3 · SCR-P2 «Предприятие» (`org`) — приёмка ARS-624, левая половина.
// Закрывает M-007 (правка legal_name/address_text применяется сразу + запись на проверку),
// M-008 (правка bin_iin — прод-значение не меняется, предложение висит как pending) и
// M-018 (профиль ещё не заполнен → пустое состояние + поле доступно на ввод).
//
// Круг правок по итогам ревью второй итерации (08.09.2026, раздел C задания) — переписаны
// так, чтобы утверждения НАБЛЮДАЛИ поведение, а не проходили по конструкции фикстуры.
// Каждая правка ниже проверена обратной подменой (сломать логику вручную → тест обязан
// упасть); что именно пробовалось — в комментарии у соответствующего теста.
//   1. M-008: `binIin` (прод) и `proposed_value` (предложение) — РАЗНЫЕ строки. Раньше они
//      совпадали, и тест не отличал «показан прод-БИН» от «показан неодобренный БИН».
//   2. Новый тест «shown ≠ proposed»: legal_name с pending, где proposed_value НЕ равен
//      показанному значению — Badge обязан быть. Вместе с (1) это исключает ЛЮБУЮ логику
//      «Badge = value-diff»: (1) ловит diff-логику при равенстве, этот тест — при
//      неравенстве её не подловил бы один, но связка двух добивает именно value-diff.
//   3. Баннер `pr_pend` — подпись поля, срок «2–5 рабочих дней», оговорка про закупки.
//   4. M-018: вторая фикстура — заполненное описание, очистка textarea → Save остаётся
//      disabled, rpc_upsert_mpk_profile не вызывается.
//   5. История банка — `current`/`history`/`history_total` больше не хардкожены пустыми
//      в фабрике; тест на «действующий»/дату закрытия/отсутствие подписи при пустой истории.
//   6. Поверхность отказов — отказ записи с машинным хвостом, терминальный FORBIDDEN на
//      чтении (без «Повторить»), несовпадение contract_version.
//   7. Права — рендер при `mpk.profile.edit === false` и при `bank.access === 'denied'`.
//   8. Мок по умолчанию больше не отвечает `{data:null,error:null}` на любое имя RPC — он
//      бросает на любой незамоканный вызов (`mockRpc` ниже), иначе случайный вызов
//      удалённого писателя (rpc_update_mpk_org_details и т.п. — круг правок A) выглядел бы
//      успехом.
//
// Круг правок C (итерация 3, 08.09.2026, converge) — 4 новых теста, каждый проверен
// обратной подменой (см. комментарий у соответствующего теста):
//   9. M-007: клик мышью по «Сохранить» — через `page.getByTestId(...).click()` (реальный
//      клик протокола браузера с полной последовательностью mousedown→blur→click), а не
//      `.click()` на DOM-узле (синтезирует только `click`, ловушку onBlur не воспроизводит).
//  10. M-007: клик мышью по «Отмена» — правка отменяется, значение не меняется.
//  11-12. FR-008: «правка не заведена» — подпись СТРОКИ «Руководитель», не подвала карточки
//      целиком; при canEdit=false подвал несёт РОВНО одну подпись («нет права»), не две
//      подряд одного уровня.
//
// Отдельный файл от mpk-profile-router/mpk-profile-states: те мокают ЛИБО `@/lib/account`
// (loadAccountProfile всегда резолвится в заготовленный профиль, `@/lib/supabase` настоящий),
// ЛИБО `@/lib/supabase` целиком отказом на любой rpc (router-smoke) — под этим мок `org`
// коротко замыкается на «Организация не определена»/пустой рендер, ни одна карточка из
// §4.1 не строится, и M-007/M-008/M-018 недостижимы. Здесь мокаются ОБА: `@/lib/account`
// даёт `orgId`, `@/lib/supabase.rpc` отвечает на `rpc_get_org_profile` и на писателей
// (`rpc_propose_org_field_change`, `rpc_upsert_mpk_profile`) заготовленными payload'ами —
// приёмка судится по контракту (Docs/AGOS-MPK-Profile-ReadRPC-ARS-362.md «Design contract»),
// а не по реальной БД.
//
// @case M-007 M-008 M-018 FR-008 FR-016 FR-017 CONTRACT-VERSION-GUARD-01 WRITE-FORBIDDEN-01 READ-FORBIDDEN-TERMINAL-01
//   (реестр кейсов: qa/scenarios/, сверка: qa/check_coverage.sh — известный долг
//   SLICE10-QA-NO-COVERAGE-01: у домена «Профиль МПК» пока нет сценариев в qa/scenarios/,
//   поэтому эти теги останутся «сиротами» до его закрытия; это не задача данного файла)

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import type { AccountProfile } from '@/lib/account'
import { MpkProfileApp } from '@/pages/cabinet/shell/mpk/profile/MpkProfileApp'
import { PH_PATHS } from '@/pages/cabinet/shell/components/icons/PhIcon'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

const ORG_ID = 'org-1'

// ── Мок `@/lib/account`: единственное, что читает MpkProfileApp — `orgId`. Остальные поля
// профиля заполнены заготовками, не влияющими на раздел `org` (шапка/бейдж — не предмет
// этого файла, см. mpk-profile-states.browser.test.tsx).
const accountProfile: AccountProfile = {
  userId: 'u1',
  orgId: ORG_ID,
  name: 'МК «Тест МПК»',
  bin: '000000000000',
  district: null,
  ownerName: 'Тестов Т.Т.',
  legalForm: null,
  phone: null,
  orgTypes: ['mpk'],
  membershipLevel: 'standard',
  applicationStatus: null,
  membershipVerification: null,
  subscriptionState: null,
  currentPeriodEnd: null,
  nextBillingAt: null,
}

vi.mock('@/lib/account', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/account')>()
  return {
    ...actual,
    loadAccountProfile: async () => accountProfile,
  }
})

// ── Мок `@/lib/supabase`: только `.rpc()` — раздел `org` не читает таблицы напрямую
// (P-AI-1/канон RPC-only). Реализация подставляется per-тест через `rpcImpl.current`.
type RpcResult = { data: unknown; error: { message: string } | null }
const rpcImpl = vi.hoisted(() => ({
  current: async (_fn: string, _args: Record<string, unknown>): Promise<RpcResult> => ({ data: null, error: null }),
}))

vi.mock('@/lib/supabase', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => rpcImpl.current(fn, args),
  },
}))

// ── Заготовка контракта rpc_get_org_profile (Dok3 RPC-63). Только реально читаемые
// разделом поля перечислены явно; остальные — честные нейтральные значения.
interface Draft {
  legalName?: string | null
  binIin?: string | null
  addressText?: string | null
  headFullName?: string | null
  profile?: { public_description: string | null; logo_path: string | null } | null
  pending?: Array<{ field_name: 'legal_name' | 'address_text' | 'bin_iin'; proposed_value: string; previous_value: string }>
  bankAccess?: 'granted' | 'denied'
  // C.5 — раньше хардкожены пустыми, банковский блок и «История версий» не рендерились ни
  // в одном тесте файла.
  bankCurrent?: { bank_name: string; bik: string; iban: string } | null
  bankHistory?: Array<{ bank_name: string; bik: string; iban: string; valid_to: string | null }>
  bankHistoryTotal?: number
  canEdit?: boolean
  contractVersion?: number
}

function orgPayload(d: Draft = {}) {
  return {
    contract_version: d.contractVersion ?? 1,
    organization: {
      id: ORG_ID,
      legal_name: d.legalName ?? 'МК «Тест МПК»',
      bin_iin: d.binIin ?? '123456789012',
      legal_form: 'ТОО',
      region_id: null,
      region_name: null,
      district_id: null,
      address_text: d.addressText ?? 'г. Алматы, ул. Тестовая, 1',
      phone: null,
      email: null,
      website: null,
      head_full_name: d.headFullName ?? 'Тестов Т.Т.',
      head_title: null,
      is_active: true,
      org_types: ['mpk'],
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    },
    profile: d.profile === undefined ? null : d.profile,
    primary_site: null,
    bank: {
      access: d.bankAccess ?? 'granted',
      current: d.bankCurrent === undefined ? null : {
        account_id: 'acct-current',
        logical_account_id: 'acct-logical',
        version_no: (d.bankHistory?.length ?? 0) + 1,
        bank_name: d.bankCurrent?.bank_name ?? '',
        bik: d.bankCurrent?.bik ?? '',
        iban: d.bankCurrent?.iban ?? '',
        account_holder_name: d.legalName ?? 'МК «Тест МПК»',
        currency_code: 'KZT',
        is_primary: true,
        valid_from: '2026-06-01T00:00:00Z',
        valid_to: null,
        created_by_user_id: null,
        created_at: '2026-06-01T00:00:00Z',
      },
      history: (d.bankHistory ?? []).map((h, i) => ({
        account_id: `acct-hist-${i}`,
        logical_account_id: 'acct-logical',
        version_no: i + 1,
        bank_name: h.bank_name,
        bik: h.bik,
        iban: h.iban,
        account_holder_name: d.legalName ?? 'МК «Тест МПК»',
        currency_code: 'KZT',
        is_primary: false,
        valid_from: '2026-01-01T00:00:00Z',
        valid_to: h.valid_to,
        created_by_user_id: null,
        created_at: '2026-01-01T00:00:00Z',
      })),
      history_total: d.bankHistoryTotal ?? (d.bankHistory?.length ?? 0),
    },
    field_reviews: {
      pending: (d.pending ?? []).map((p, i) => ({
        id: `review-${i}`,
        field_name: p.field_name,
        previous_value: p.previous_value,
        proposed_value: p.proposed_value,
        status: 'pending' as const,
        requested_by_user_id: null,
        requested_at: '2026-09-08T00:00:00Z',
      })),
      resolved_recent: [],
      resolved_total: 0,
    },
    permissions: {
      'mpk.profile.edit': d.canEdit ?? true,
      'mpk.bank.manage': true,
    },
  }
}

// C.8 — раньше `rpcImpl.current` по умолчанию отвечал `{data:null,error:null}` НА ЛЮБОЕ имя
// RPC, поэтому случайный вызов удалённого писателя (rpc_update_mpk_org_details и три других,
// убранные кругом правок A) выглядел бы успехом, а не провалом теста. `mockRpc` — единая
// точка входа: незамоканное имя бросает, а не молчит.
type RpcHandler = (args: Record<string, unknown>) => RpcResult | Promise<RpcResult>
function mockRpc(handlers: Partial<Record<string, RpcHandler>>) {
  rpcImpl.current = async (fn, args) => {
    const h = handlers[fn]
    if (!h) throw new Error(`unexpected rpc() call in test: ${fn}`)
    return h(args)
  }
}

let root: Root | null = null
let mountEl: HTMLElement | null = null

function mountOrgTab() {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(
    <MemoryRouter initialEntries={['/mpk/profile/org']}>
      <Routes>
        <Route path="/mpk/profile/*" element={<MpkProfileApp />} />
      </Routes>
    </MemoryRouter>,
  )
}

beforeEach(async () => {
  await page.viewport(1440, 900)
  // C.8: дефолт бросает на любое незамоканное имя — раньше был безусловный успех, из-за
  // которого случайный вызов лишнего RPC (например, одного из трёх писателей, убранных
  // кругом правок A) прошёл бы тест молча. Каждый `it` обязан явно перечислить через
  // `mockRpc(...)`, какие RPC ожидает.
  rpcImpl.current = async (fn) => {
    throw new Error(`unexpected rpc() call in test: ${fn} — call mockRpc({...}) in the test body`)
  }
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
})

const T = { timeout: 15_000 }

function rowValue(label: string): HTMLElement | null {
  const rows = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-req-row'))
  const row = rows.find((r) => r.querySelector('.mpkc-req-label')?.textContent?.trim() === label)
  return row?.querySelector('.mpkc-req-value') as HTMLElement | null
}
function rowBadge(label: string): HTMLElement | null {
  const rows = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-req-row'))
  const row = rows.find((r) => r.querySelector('.mpkc-req-label')?.textContent?.trim() === label)
  return row?.querySelector('.mpkc-badge') as HTMLElement | null
}

// React отслеживает изменение `.value` через собственный сеттер на прототипе элемента
// (нужен для controlled-инпутов); присвоение `el.value = x` идёт мимо этого сеттера, и
// последующий native 'input' event React игнорирует — трекер решает, что значение не
// менялось. Вызываем сеттер прототипа напрямую, как это делает реальный ввод пользователя.
function setNativeValue(el: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype
  const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set
  setter?.call(el, value)
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

// ── C.8 self-check · дефолтный мок бросает на незамоканный вызов ──────────────────────
it('дефолтный мок (beforeEach) бросает на незамоканный RPC — случайный вызов писателя не проходит тихо', async () => {
  // Обратная подмена: верни дефолт к `{data:null,error:null}` — этот тест перестанет
  // отличаться от старого поведения и упадёт (промис зарезолвится, а не бросит).
  await expect(rpcImpl.current('rpc_update_mpk_org_details', {})).rejects.toThrow('unexpected rpc() call')
})

// ── M-007 · правка legal_name применяется сразу, запись уходит на проверку ────────────
it('M-007: правка «Наименование» применяется сразу и помечается «На проверке»', async () => {
  let served = orgPayload({ legalName: 'Старое имя', pending: [] })
  mockRpc({
    rpc_get_org_profile: async () => ({ data: served, error: null }),
    rpc_propose_org_field_change: async (args) => {
      expect(args.p_field_name).toBe('legal_name')
      // Сервер применяет legal_name СРАЗУ (D-MPK-CRIT-03) и заводит pending-запись —
      // именно это отличает M-007 от M-008 (различитель — field_name, не значение).
      served = orgPayload({
        legalName: args.p_proposed_value as string,
        pending: [{ field_name: 'legal_name', previous_value: 'Старое имя', proposed_value: args.p_proposed_value as string }],
      })
      return { data: null, error: null }
    },
  })

  mountOrgTab()
  // `page.getByText('Предприятие')` неоднозначен: тот же текст несёт и вкладка ptabs —
  // ждём заголовок карточки конкретным селектором.
  await expect.poll(() => document.querySelector('.mpkc-req-card-title')?.textContent?.trim(), T).toBe('Предприятие')
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('Старое имя')

  rowValue('Наименование')?.click()
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-req-edit .mpkc-req-input'), T).not.toBeNull()
  const input = document.querySelector('.agos-mpk-console .mpkc-req-edit .mpkc-req-input') as HTMLInputElement
  setNativeValue(input, 'Новое имя')
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))

  // Значение обновилось СРАЗУ (применено немедленно), и появился Badge «На проверке» —
  // ровно поведение, которое KEEP-1 требует различать по `field_name`, а не по value-diff.
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('Новое имя')
  await expect.poll(() => rowBadge('Наименование')?.textContent?.trim(), T).toBe('На проверке')
})

// ── C (итерация 3) · M-007: клик мышью по «Сохранить» коммитит правку ─────────────────
it('M-007: клик мышью по кнопке «Сохранить» коммитит правку, а не теряет её через onBlur', async () => {
  // Раньше сохранить строку можно было только Enter — мышью нечем. `page.getByTestId(...).click()`
  // (в отличие от `.click()` на DOM-узле, который лишь синтезирует событие `click`) — это
  // РЕАЛЬНЫЙ клик через протокол браузера, с полной последовательностью mousedown → перенос
  // фокуса → blur → click, в которой и жила ловушка. Обратная подмена: убери
  // `onMouseDown={(e) => e.preventDefault()}` с кнопки «Сохранить» в EditableRow — мышиный
  // mousedown уведёт фокус с input на кнопку, onBlur отменит правку (`setEditing(false)`)
  // ДО срабатывания click, `rpc_propose_org_field_change` не будет вызван, и оба `poll` ниже
  // упадут (значение останется прежним, `proposeCalled` не станет true).
  let served = orgPayload({ legalName: 'Старое имя', pending: [] })
  let proposeCalled = false
  mockRpc({
    rpc_get_org_profile: async () => ({ data: served, error: null }),
    rpc_propose_org_field_change: async (args) => {
      proposeCalled = true
      served = orgPayload({
        legalName: args.p_proposed_value as string,
        pending: [{ field_name: 'legal_name', previous_value: 'Старое имя', proposed_value: args.p_proposed_value as string }],
      })
      return { data: null, error: null }
    },
  })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('Старое имя')

  rowValue('Наименование')?.click()
  await expect.poll(() => document.querySelector('[data-testid="mpkc-req-save"]'), T).not.toBeNull()
  const input = document.querySelector('.agos-mpk-console .mpkc-req-edit .mpkc-req-input') as HTMLInputElement
  setNativeValue(input, 'Новое имя мышью')

  await page.getByTestId('mpkc-req-save').click()

  await expect.poll(() => proposeCalled, T).toBe(true)
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('Новое имя мышью')
})

// ── C (итерация 3) · кнопка «Отмена» отменяет правку явным кликом, значение не меняется ─
it('M-007: клик мышью по кнопке «Отмена» отменяет правку, значение не меняется, RPC не вызывается', async () => {
  const served = orgPayload({ legalName: 'Старое имя', pending: [] })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('Старое имя')

  rowValue('Наименование')?.click()
  await expect.poll(() => document.querySelector('[data-testid="mpkc-req-cancel"]'), T).not.toBeNull()
  const input = document.querySelector('.agos-mpk-console .mpkc-req-edit .mpkc-req-input') as HTMLInputElement
  setNativeValue(input, 'Черновик, который не должен сохраниться')

  await page.getByTestId('mpkc-req-cancel').click()

  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-req-edit .mpkc-req-input'), T).toBeNull()
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('Старое имя')
})

// ── C (итерация 3) · FR-008: «правка не заведена» стоит у строки «Руководитель» ───────
it('FR-008: «правка не заведена» — подпись строки «Руководитель», не безусловный подвал карточки (canEdit=true)', async () => {
  // Обратная подмена: верни `<div className="mpkc-req-note">{READ_ONLY_NOT_BUILT_NOTE}</div>`
  // на прежнее место — безусловно в `.mpkc-req-card-body`, вне какой-либо строки. Тогда
  // `bodyNotes` ниже перестанет быть пустым массивом (найдётся текст как прямой потомок
  // card-body), и `expect(bodyNotes).toHaveLength(0)` упадёт.
  const served = orgPayload({ canEdit: true, pending: [] })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.tagName, T).toBe('BUTTON')

  const card = document.querySelector('.agos-mpk-console .mpkc-req-card') as HTMLElement
  const bodyNotes = Array.from(card.querySelectorAll(':scope > .mpkc-req-card-body > .mpkc-req-note'))
  expect(bodyNotes).toHaveLength(0)

  const rows = Array.from(card.querySelectorAll('.mpkc-req-row'))
  const headRow = rows.find((r) => r.querySelector('.mpkc-req-label')?.textContent?.trim() === 'Руководитель')
  expect(headRow?.textContent).toContain('Пока только просмотр: изменение этих данных на этом экране ещё не заведено.')
})

it('FR-008: при canEdit=false подвал карточки несёт РОВНО одну подпись «нет права», «не заведено» — только у строки «Руководитель»', async () => {
  // Обратная подмена: убери `note={READ_ONLY_NOT_BUILT_NOTE}` с `StaticRow` «Руководитель» и
  // верни безусловный `<div className="mpkc-req-note">{READ_ONLY_NOT_BUILT_NOTE}</div>` в
  // подвал — `bodyNotes` станет длины 2 (два текста подряд одного уровня), `toHaveLength(1)`
  // упадёт: ровно найденный владельцем 08.09 дефект («обе причины сразу»).
  const served = orgPayload({ canEdit: false, pending: [] })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.tagName, T).toBe('SPAN')

  const card = document.querySelector('.agos-mpk-console .mpkc-req-card') as HTMLElement
  const bodyNotes = Array.from(card.querySelectorAll(':scope > .mpkc-req-card-body > .mpkc-req-note'))
  expect(bodyNotes).toHaveLength(1)
  expect(bodyNotes[0]?.textContent).toBe(
    'На изменение этих данных нет права. Данные видны, править их может администратор предприятия.',
  )

  const rows = Array.from(card.querySelectorAll('.mpkc-req-row'))
  const headRow = rows.find((r) => r.querySelector('.mpkc-req-label')?.textContent?.trim() === 'Руководитель')
  expect(headRow?.textContent).toContain('Пока только просмотр: изменение этих данных на этом экране ещё не заведено.')
})

// ── M-008 · правка БИН: прод-значение НЕ меняется — теперь прод и proposed РАЗНЫЕ ─────
it('M-008: БИН на проверке — показан прод-БИН, неодобренное значение в DOM карточки отсутствует', async () => {
  // C.1: раньше `binIin` и `proposed_value` были ОДНОЙ строкой — тест оставался зелёным,
  // даже если бы карточка ошибочно показала неодобренный БИН вместо прод-значения (они
  // совпадали, разницу увидеть было нечем). Обратная подмена: замени `displayValue` БИН на
  // `pendingByField.get('bin_iin')?.proposed_value ?? organization.bin_iin` в OrgSection —
  // `rowValue('БИН')` вернёт '999999999999', первый `.toBe('123456789012')` упадёт.
  const served = orgPayload({
    binIin: '123456789012',
    pending: [{ field_name: 'bin_iin', previous_value: '111111111111', proposed_value: '999999999999' }],
  })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('БИН')?.textContent?.trim(), T).toBe('123456789012')
  // Badge присутствует ИМЕННО потому что field_name='bin_iin' числится в pending.
  await expect.poll(() => rowBadge('БИН')?.textContent?.trim(), T).toBe('На проверке')
  // Неодобренное значение не должно попасть в DOM карточки нигде — не только не в строке
  // «БИН», а вообще (например, случайно как значение другого поля или в hidden-атрибуте).
  const cardText = document.querySelector('.agos-mpk-console .mpkc-req')?.textContent ?? ''
  expect(cardText).not.toContain('999999999999')
  // Поле с висящей pending-правкой не кликабельно — вторую правку того же поля UI не
  // предлагает начинать (сервер её всё равно отклонит, FIELD_REVIEW_ALREADY_PENDING).
  expect((rowValue('БИН') as HTMLButtonElement)?.disabled).toBe(true)
})

// ── C.2 · pending с proposed_value ≠ показанным значением — тоже обязан дать Badge ────
it('M-007: pending, где proposed_value отличается от показанного значения, всё равно даёт Badge «На проверке»', async () => {
  // Вместе с M-008 выше исключает ЛЮБУЮ реализацию Badge через сравнение значений: M-008
  // проверяет случай РАВЕНСТВА (diff-логика решила бы «применено», Badge пропал бы), этот
  // тест держит случай НЕРАВЕНСТВА. По отдельности каждый может случайно совпасть с
  // value-diff реализацией; связка — нет. Обратная подмена: замени условие Badge на
  // `pendingReview.proposed_value !== displayValue` — тест не упадёт САМ ПО СЕБЕ (Badge
  // всё ещё покажется, раз значения различны), но это ожидаемо: ловушка только парная
  // с M-008, о чём и предупреждает комментарий в задании.
  const served = orgPayload({
    legalName: 'Прод-значение',
    pending: [{ field_name: 'legal_name', previous_value: 'Прежнее значение', proposed_value: 'Совсем другое предложение' }],
  })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('Прод-значение')
  await expect.poll(() => rowBadge('Наименование')?.textContent?.trim(), T).toBe('На проверке')
})

// ── C.3 · баннер pr_pend — подпись поля, срок, оговорка про закупки ───────────────────
it('pr_pend: баннер называет предложенные поля, срок «2–5 рабочих дней» и что закупки не блокируются', async () => {
  const served = orgPayload({
    pending: [
      { field_name: 'bin_iin', previous_value: 'a', proposed_value: 'b' },
      { field_name: 'address_text', previous_value: 'c', proposed_value: 'd' },
    ],
  })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.element(page.getByText('Изменения на повторной проверке TURAN'), T).toBeInTheDocument()
  // Обратная подмена: убери суффикс «· 2–5 рабочих дней. Закупки, заявки и приёмка
  // работают как обычно.» из pr_pendTxt — оба `toContain` ниже упадут.
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-req-pend-body')?.textContent ?? '', T)
    .toContain('БИН')
  const bannerBody = document.querySelector('.agos-mpk-console .mpkc-req-pend-body')?.textContent ?? ''
  expect(bannerBody).toContain('юридический адрес')
  expect(bannerBody).toContain('2–5 рабочих дней')
  expect(bannerBody).toContain('Закупки, заявки и приёмка работают как обычно.')
})

// ── M-018 · профиль ещё не заполнен → пустое состояние + поле доступно на ввод ────────
it('M-018: пустой mpk_profiles показывает приглашение заполнить, поле доступно на ввод', async () => {
  let served = orgPayload({ profile: null })
  mockRpc({
    rpc_get_org_profile: async () => ({ data: served, error: null }),
    rpc_upsert_mpk_profile: async (args) => {
      expect(args.p_public_description).toBe('Продаём говядину высшей категории.')
      served = orgPayload({ profile: { public_description: args.p_public_description as string, logo_path: null } })
      return { data: null, error: null }
    },
  })

  mountOrgTab()
  // Круг правок C: канон §4.1.2 несёт приглашающую половину («Заполните описание — его
  // увидят фермеры.») — она часть требования M-018, не украшение. Обратная подмена: верни
  // код к «Описание ещё не заполнено.» — этот `getByText` перестанет находить элемент.
  await expect.element(page.getByText('Профиль предприятия ещё не заполнен. Заполните описание предприятия.'), T).toBeInTheDocument()

  const textarea = document.querySelector('.agos-mpk-console .mpkc-req-textarea') as HTMLTextAreaElement
  expect(textarea).toBeTruthy()
  expect(textarea.disabled).toBe(false)

  const saveBtn = () => Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-stub-act'))
    .find((b) => b.textContent?.trim() === 'Сохранить') as HTMLButtonElement | undefined
  // KEEP-3: Save закрыт по непустоте черновика — пустое поле не должно уметь сохраниться.
  expect(saveBtn()?.disabled).toBe(true)

  setNativeValue(textarea, 'Продаём говядину высшей категории.')
  await expect.poll(() => saveBtn()?.disabled, T).toBe(false)

  saveBtn()?.click()
  // Пустое состояние исчезает: `profile` перестал быть `null` после успешного сохранения.
  await expect.poll(
    () => document.body.textContent?.includes('Профиль предприятия ещё не заполнен. Заполните описание предприятия.'),
    T,
  ).toBe(false)
})

// ── C.4 · Save-гейт (M-018): очистка УЖЕ ЗАПОЛНЕННОГО описания — Save остаётся disabled ─
it('M-018/Save-гейт: очистка заполненного описания оставляет Save disabled, rpc_upsert_mpk_profile не вызывается', async () => {
  // Раньше гейт проверялся только там, где обе половины дизъюнкции (`saving`, `draft===''`)
  // истинны ОДНОВРЕМЕННО на пустом стартовом состоянии. Здесь старт НЕПУСТОЙ (dirty=false),
  // и только очистка делает `draft.trim()===''` истинным независимо от `dirty`. Обратная
  // подмена: убери `|| draft.trim() === ''` из `disabled=...` в PublicDescriptionCard,
  // оставив только `saving || !dirty` — после очистки `dirty` становится true, кнопка
  // разблокируется, и `await expect.poll(...).toBe(true)` ниже упадёт.
  const served = orgPayload({ profile: { public_description: 'Уже есть описание.', logo_path: null } })
  let upsertCalled = false
  mockRpc({
    rpc_get_org_profile: async () => ({ data: served, error: null }),
    rpc_upsert_mpk_profile: async () => { upsertCalled = true; return { data: null, error: null } },
  })

  mountOrgTab()
  const textarea = () => document.querySelector('.agos-mpk-console .mpkc-req-textarea') as HTMLTextAreaElement
  await expect.poll(() => textarea()?.value, T).toBe('Уже есть описание.')

  const saveBtn = () => Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-stub-act'))
    .find((b) => b.textContent?.trim() === 'Сохранить') as HTMLButtonElement | undefined

  setNativeValue(textarea(), '')
  await expect.poll(() => saveBtn()?.disabled, T).toBe(true)

  saveBtn()?.click()
  await new Promise((resolve) => setTimeout(resolve, 80))
  expect(upsertCalled).toBe(false)
})

// ── C.5 · история банка — «действующий» / дата закрытия / подпись только при непустой ─
it('История банка: «действующий» на valid_to=null, дата закрытия на закрытой версии, счётчик «показано N из M»', async () => {
  // Раньше `bank.current`/`history`/`history_total` были хардкожены пустыми в фабрике —
  // блок истории не рендерился НИ В ОДНОМ тесте файла. Обратная подмена: поменяй местами
  // ветки тернарника `h.valid_to ? ... : 'действующий'` в BankBlock — порядок меток в
  // `metas` ниже перевернётся, `toEqual` упадёт.
  const served = orgPayload({
    bankCurrent: { bank_name: 'Народный банк', bik: 'HSBKKZKX', iban: 'KZ123456789012345678' },
    bankHistory: [
      { bank_name: 'Вторая живая лестница', bik: 'ABCDKZKX', iban: 'KZ000000000000000002', valid_to: null },
      { bank_name: 'Закрытый счёт', bik: 'OLDBKKZKX', iban: 'KZ000000000000000001', valid_to: '2026-05-01T00:00:00Z' },
    ],
    bankHistoryTotal: 5,
  })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.element(page.getByText('История версий: показано 2 из 5'), T).toBeInTheDocument()
  const metas = () => Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-req-history-list .mpkc-req-history-meta'))
    .map((el) => el.textContent?.trim())
  await expect.poll(metas, T).toEqual(['действующий', 'до 01.05.2026'])
})

it('История банка: пустая история — подписи «История версий» нет вообще', async () => {
  // KEEP-2б, теперь фактически наблюдаемо: раньше `bank.history` был всегда `[]` в фабрике,
  // и утверждение «подписи нет» было тавтологией. Обратная подмена: убери условие
  // `bank.history.length > 0` вокруг блока `.mpkc-req-history` в BankBlock — подпись
  // появится даже с пустой историей, `toBe(false)` ниже упадёт.
  const served = orgPayload({
    bankCurrent: { bank_name: 'Народный банк', bik: 'HSBKKZKX', iban: 'KZ123456789012345678' },
  })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.element(page.getByText('Народный банк'), T).toBeInTheDocument()
  expect(document.body.textContent?.includes('История версий')).toBe(false)
})

// ── C.6 · поверхность отказов ──────────────────────────────────────────────────────────
it('Отказ записи с машинным хвостом (FORBIDDEN: mpk.profile.edit required) показывает конкретный текст, не общий фолбэк', async () => {
  // Обратная подмена: в `writeErrorText` верни `WRITE_FALLBACK` безусловно (проигнорируй
  // код) — `page.getByText('У вас нет права на это изменение.')` ниже не найдёт элемент.
  const served = orgPayload({ pending: [] })
  mockRpc({
    rpc_get_org_profile: async () => ({ data: served, error: null }),
    rpc_propose_org_field_change: async () => ({ data: null, error: { message: 'FORBIDDEN: mpk.profile.edit required' } }),
  })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('МК «Тест МПК»')
  rowValue('Наименование')?.click()
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-req-edit .mpkc-req-input'), T).not.toBeNull()
  const input = document.querySelector('.agos-mpk-console .mpkc-req-edit .mpkc-req-input') as HTMLInputElement
  setNativeValue(input, 'Другое имя')
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))

  await expect.element(page.getByText('У вас нет права на это изменение.'), T).toBeInTheDocument()
  expect(document.querySelector('.agos-mpk-console .mpkc-req-error')?.textContent).not.toContain('Повторите позже')
})

it('Терминальный FORBIDDEN при чтении не предлагает «Повторить»', async () => {
  // Обратная подмена: убери развилку KEEP-6 в OrgSection (падение в общий сетевой блок с
  // кнопкой «Повторить» для любого rpc-отказа) — `retryBtn` ниже перестанет быть undefined.
  mockRpc({
    rpc_get_org_profile: async () => ({ data: null, error: { message: 'FORBIDDEN: not a member of organization org-1' } }),
  })

  mountOrgTab()
  await expect.element(page.getByText('Нет доступа к этой организации'), T).toBeInTheDocument()
  const retryBtn = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-stub-act'))
    .find((b) => b.textContent?.trim() === 'Повторить')
  expect(retryBtn).toBeUndefined()
})

it('Несовпадение contract_version — честный отказ, не белый экран', async () => {
  // Обратная подмена: убери проверку `contract_version !== CONTRACT_VERSION` в
  // loadOrgProfile — экран попытается отрендерить payload версии 2 как версию 1, и текст
  // отказа ниже не появится (реальный контракт версии 2 в этом тесте не имеет полей,
  // отличных от версии 1, поэтому без guard он молча прошёл бы как «успех»).
  const served = orgPayload({ contractVersion: 2 })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.element(page.getByText('Контракт ответа не распознан. Обновите страницу.'), T).toBeInTheDocument()
})

it('Ответ без bank/field_reviews/permissions — честный отказ, не TypeError на payload.bank.access', async () => {
  // B.5: version=1 сам по себе не гарантировал форму — раньше проверялось только
  // `organization`. Обратная подмена: верни guard к `!payload.organization` (убери три
  // остальных условия) — компонент попытается прочитать `payload.bank.access` на
  // `undefined` и упадёт TypeError'ом вместо честного текста ниже.
  const served = orgPayload() as unknown as Record<string, unknown>
  delete served.bank
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.element(page.getByText('Контракт ответа не распознан. Обновите страницу.'), T).toBeInTheDocument()
})

// ── C.7 · права — ветки, которые раньше не рендерились вовсе ──────────────────────────
it("permissions['mpk.profile.edit']=false: карточки read-only и несут объяснение FR-016", async () => {
  const served = orgPayload({ canEdit: false })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.tagName, T).toBe('SPAN')
  await expect.poll(
    () => document.body.textContent?.includes('На изменение этих данных нет права. Данные видны, править их может администратор предприятия.'),
    T,
  ).toBe(true)
})

it("bank.access='denied': блок показан с честным пояснением, значения счёта не просачиваются", async () => {
  const served = orgPayload({ bankAccess: 'denied', bankCurrent: { bank_name: 'СекретныйБанк', bik: 'ZZZZKZKX', iban: 'KZ999999999999999999' } })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.element(page.getByText('Реквизиты доступны бухгалтеру и администратору.'), T).toBeInTheDocument()
  expect(document.body.textContent).not.toContain('СекретныйБанк')
})

// ── ARS-624 (точечный круг «иконки заголовков 1:1 с макетом») ─────────────────────────
// Прототип, §4.1.1 pr_cards (L1983-1985): building/«Предприятие», mapPin/«Площадка
// приёмки», briefcase/«Банковские реквизиты». «О предприятии» — наш блок под
// mpk_profiles, вне pr_cards прототипа — иконки не имеет (выдумывать канон не стали).
it('Заголовки «Предприятие»/«Площадка приёмки»/«Банковские реквизиты» несут иконку прототипа; «О предприятии» — нет', async () => {
  const served = orgPayload({ pending: [] })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('МК «Тест МПК»')

  const headIconPath = (title: string) => {
    const heads = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-req-card-head'))
    const head = heads.find((h) => h.querySelector('.mpkc-req-card-title')?.textContent?.trim() === title)
    return head?.querySelector('svg path')?.getAttribute('d')
  }
  // Обратная подмена: убери <PhIcon name="building" .../> из заголовка «Предприятие» в
  // OrgSection.tsx — headIconPath('Предприятие') вернёт undefined, toBe(...) упадёт.
  expect(headIconPath('Предприятие')).toBe(PH_PATHS.building)
  expect(headIconPath('Площадка приёмки')).toBe(PH_PATHS.mapPin)
  expect(headIconPath('Банковские реквизиты')).toBe(PH_PATHS.briefcase)
  expect(headIconPath('О предприятии')).toBeUndefined()
})

// ── ARS-624 (точечный круг «раскладка карточки — сетка, не стек») ─────────────────────
// §4.1.1 «Структура карточки — снята с прототипа, а не придумана»: строка — двухколоночная
// grid (не вертикальный стек), meta шапки прижата к правому краю (распорка flex:1), Badge
// «На проверке» стоит ПОСЛЕ значения, а не рядом с подписью. Проверено обратной подменой
// (см. итог задачи) — верни `.mpkc-req-row` к `display:flex;flex-direction:column` и Badge
// в `.mpkc-req-row-head` — этот тест падает первым на `rowStyle.display`.
// Легенда §4.1.1: место (ПОД баннером) и правый угол у третьего пункта. Правки владельца
// 08.09 — четвёртый заход одного и того же класса: канон фиксировал содержание и не фиксировал
// форму, поэтому сборка раскладывала «как получится». Тест запирает именно форму.
it('Раскладка §4.1.1: легенда стоит ПОД баннером pr_pend, третий пункт — в правом углу, кегль совпадает с подписью строки', async () => {
  const served = orgPayload({
    pending: [{ field_name: 'bin_iin', previous_value: '123456789012', proposed_value: '999999999999' }],
  })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-req-legend'), T).toBeTruthy()

  const banner = document.querySelector('.agos-mpk-console .mpkc-req-pend') as HTMLElement
  const legend = document.querySelector('.agos-mpk-console .mpkc-req-legend') as HTMLElement
  expect(banner).toBeTruthy()
  expect(legend).toBeTruthy()

  // Порядок в документе: баннер ПЕРЕД легендой (прототип: баннер L766-772, легенда L773-783).
  // DOCUMENT_POSITION_FOLLOWING === 4: legend идёт ПОСЛЕ banner.
  expect(banner.compareDocumentPosition(legend) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  expect(legend.getBoundingClientRect().top).toBeGreaterThan(banner.getBoundingClientRect().top)

  // Третий пункт — в правый угол (`margin-left:auto`, прототип L780).
  const items = Array.from(legend.querySelectorAll('li')) as HTMLElement[]
  expect(items).toHaveLength(3)
  expect(items[2]!.textContent).toContain('клик по значению — правка')
  expect(legend.getBoundingClientRect().right - items[2]!.getBoundingClientRect().right).toBeLessThanOrEqual(4)
  // …а первые два — слева, вплотную друг к другу (иначе «в углу» выполнялось бы растяжкой всех).
  expect(items[1]!.getBoundingClientRect().left - items[0]!.getBoundingClientRect().right).toBeLessThanOrEqual(24)

  // Кегль легенды = кегль подписи строки (13px в прототипе L774/L794): раньше легенда была
  // на 11px и выглядела мельче подписей.
  const anyLabel = document.querySelector('.agos-mpk-console .mpkc-req-label') as HTMLElement
  expect(anyLabel).toBeTruthy()
  expect(getComputedStyle(legend).fontSize).toBe(getComputedStyle(anyLabel).fontSize)
})

it('Раскладка §4.1.1: подпись и значение строки — одна grid-строка; meta шапки прижата к правому краю; Badge после значения', async () => {
  const served = orgPayload({
    pending: [{ field_name: 'legal_name', previous_value: 'Старое', proposed_value: 'Новое' }],
  })
  mockRpc({ rpc_get_org_profile: async () => ({ data: served, error: null }) })

  mountOrgTab()
  await expect.poll(() => rowValue('Наименование')?.textContent?.trim(), T).toBe('МК «Тест МПК»')

  // ── строка «Наименование»: `.mpkc-req-row` — grid с колонкой 170px, подпись (левая
  // ячейка) и значение (правая ячейка) лежат в ОДНОЙ строке сетки (align-items:start
  // выравнивает верх обеих ячеек по одной линии — раньше (flex-column) подпись и значение
  // были на разных строках стека, и разница `top` была бы равна высоте строки подписи,
  // а не ~0).
  const rows = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-req-row'))
  const nameRow = rows.find((r) => r.querySelector('.mpkc-req-label')?.textContent?.trim() === 'Наименование') as HTMLElement
  expect(nameRow).toBeTruthy()
  const rowStyle = getComputedStyle(nameRow)
  expect(rowStyle.display).toBe('grid')
  expect(rowStyle.gridTemplateColumns.split(' ')[0]).toBe('170px')

  const label = nameRow.querySelector('.mpkc-req-label') as HTMLElement
  const valueCell = nameRow.querySelector('.mpkc-req-row-value') as HTMLElement
  expect(label).toBeTruthy()
  expect(valueCell).toBeTruthy()
  expect(Math.abs(label.getBoundingClientRect().top - valueCell.getBoundingClientRect().top)).toBeLessThanOrEqual(2)

  // ── Badge «На проверке» — в правой ячейке, ПОСЛЕ значения (`.mpkc-req-value`), не в
  // левой (`.mpkc-req-row-head`, где сидит подпись).
  expect(nameRow.querySelector('.mpkc-req-row-head .mpkc-badge')).toBeNull()
  const inline = nameRow.querySelector('.mpkc-req-row-value-inline') as HTMLElement
  expect(inline).toBeTruthy()
  const inlineKids = Array.from(inline.children)
  const valueIdx = inlineKids.findIndex((k) => k.classList.contains('mpkc-req-value'))
  const badgeIdx = inlineKids.findIndex((k) => k.classList.contains('mpkc-badge'))
  expect(valueIdx).toBeGreaterThanOrEqual(0)
  expect(badgeIdx).toBeGreaterThan(valueIdx)

  // ── meta шапки карточки «Предприятие» — прижата к правому краю (распорка `flex:1`
  // между заголовком и meta), не липнет к заголовку слева. Проверяем через геометрию:
  // правый край meta должен совпадать с правым краем шапки за вычетом её padding-right
  // (16px, `.mpkc-req-card-head`), а не стоять сразу после заголовка.
  const card = Array.from(document.querySelectorAll('.agos-mpk-console .mpkc-req-card'))
    .find((c) => c.querySelector('.mpkc-req-card-title')?.textContent?.trim() === 'Предприятие') as HTMLElement
  const head = card.querySelector('.mpkc-req-card-head') as HTMLElement
  const meta = card.querySelector('.mpkc-req-card-meta') as HTMLElement
  const headRect = head.getBoundingClientRect()
  const metaRect = meta.getBoundingClientRect()
  expect(headRect.right - metaRect.right).toBeLessThanOrEqual(20)
})
