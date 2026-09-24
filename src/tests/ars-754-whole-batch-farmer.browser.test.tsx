// AgOS · ARS-754 · «Партия продаётся только целиком» — экраны фермера.
// Предмет: Docs/AGOS-TSP-WholeBatchOnly-ARS-754.md, раздел `## I/O & Edge-Case Matrix`,
// строки M-013, M-014, M-015, M-016, M-017, M-020 (задача W-2, зона фермера — src/pages/cabinet/shell).
//
// Один тест = одна строка матрицы, id в названии (Matrix Test Audit сверяет ПО ID).
// FR-005 (словарь МПК `BATCH_DOES_NOT_FIT`) покрыт отдельно в src/tests/mpk-rpc-error-text.browser.test.ts.
//
// ФАЛЬСИФИЦИРУЕМОСТЬ (проверена прогоном на baseline 4ab2ad7 после ревью якоря 7 — первая
// версия файла на старом коде проходила почти целиком): падают M-013 (фикстуры под три
// условия старого showSplit), M-015 и M-016 (в наборе есть `partial`), M-020 (статус
// `partial` ещё в словаре). M-014 и M-017 — страховка от регресса целой сделки: на старом
// коде они проходят и обязаны проходить.
//
// Запуск: npx vitest run --project routers

import { afterEach, expect, it, vi } from 'vitest'
import { createRoot, type Root } from 'react-dom/client'
import { HostProvider } from '@/platform/host/HostContext'
import { BatchScreen } from '@/pages/cabinet/shell/screens/BatchScreen'
import { BatchCard } from '@/pages/cabinet/shell/components/BatchListCard'
import { WithdrawSheet } from '@/pages/cabinet/shell/components/sheets/WithdrawSheet'
import type { Batch } from '@/pages/cabinet/shell/types'

vi.mock('@/lib/supabase', () => {
  const user = { id: 'ars754-user', user_metadata: { full_name: 'Фермер Тест' }, phone: '' }
  const session = { access_token: 't', refresh_token: 't', token_type: 'bearer', expires_in: 3600, user }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: null }) as Promise<unknown> & Record<string, unknown>
    for (const m of ['select', 'eq', 'order', 'limit', 'single', 'maybeSingle']) q[m] = () => q
    return q
  }
  const ok = (data: unknown) => ({ data, error: null })
  return {
    supabase: {
      auth: {
        getSession: async () => ({ data: { session }, error: null }),
        getUser: async () => ({ data: { user }, error: null }),
        setSession: async () => ({ data: { session, user }, error: null }),
        signOut: async () => ({ error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      },
      from: () => chain(),
      storage: { from: () => ({ list: async () => ok([]), createSignedUrl: async () => ok(null) }) },
      channel: () => {
        const ch: Record<string, () => unknown> = {}
        for (const m of ['on', 'subscribe', 'unsubscribe']) ch[m] = () => ch
        return ch
      },
      removeChannel: async () => 'ok',
      rpc: async () => ({ data: null, error: null }),
    },
  }
})

const T = { timeout: 15_000 }

/** Партия, продаваемая целиком (владелец 24.09) — база для мутаций в тестах. */
function makeBatch(patch: Partial<Batch> = {}): Batch {
  return {
    id: 'ars754-batch',
    state: 'matched',
    cat: 'bychki',
    breed: 'Ангус',
    heads: 23,
    avgWeight: 430,
    price: 1500,
    history: [],
    ...patch,
  }
}

/** Разряды в `fmtMoney` разделяются НЕРАЗРЫВНЫМ пробелом (tsp-utils.ts:8). */
const norm = (s: string) => s.replace(/ /g, ' ')

let mounted: { root: Root; el: HTMLElement }[] = []

afterEach(() => {
  for (const { root, el } of mounted) {
    root.unmount()
    el.remove()
  }
  mounted = []
  window.localStorage.clear()
})

/** Монтирует BatchScreen в свой отдельный контейнер (не document.body напрямую) —
 *  несколько партий можно сравнить в одном тесте без взаимной "утечки" текста. */
function renderBatch(batch: Batch, onPatch = vi.fn()) {
  const el = document.createElement('div')
  document.body.appendChild(el)
  const root = createRoot(el)
  root.render(
    <HostProvider>
      <BatchScreen
        batch={batch}
        onBack={vi.fn()}
        onPatch={onPatch}
        onNew={vi.fn()}
        onReview={vi.fn()}
        onTuran={vi.fn()}
        toast={vi.fn()}
      />
    </HostProvider>,
  )
  mounted.push({ root, el })
  return { el, onPatch }
}

function renderCard(batch: Batch) {
  const el = document.createElement('div')
  document.body.appendChild(el)
  const root = createRoot(el)
  root.render(<BatchCard b={batch} onOpen={vi.fn()} />)
  mounted.push({ root, el })
  return { el }
}

function renderWithdraw(batch: Batch) {
  const el = document.createElement('div')
  document.body.appendChild(el)
  const root = createRoot(el)
  root.render(<WithdrawSheet batch={batch} open onClose={vi.fn()} onConfirm={vi.fn()} />)
  mounted.push({ root, el })
  return { el }
}

const bodyOf = (el: HTMLElement) => norm(el.textContent ?? '')
const buttonByText = (el: HTMLElement, t: string): HTMLButtonElement | undefined =>
  Array.from(el.querySelectorAll('button')).find((b) => b.textContent?.includes(t))

// Ionic `IonModal` (Sheet) портирует своё содержимое в конец document.body, а не в узел,
// где объявлен компонент — поэтому шторки (Withdraw/Dispatch) читаются здесь через
// document.body, а не через локальный контейнер теста.
const bodyGlobal = () => norm(document.body.textContent ?? '')
const buttonGlobal = (t: string): HTMLButtonElement | undefined =>
  Array.from(document.body.querySelectorAll('button')).find((b) => b.textContent?.includes(t))

/** Снимает один смонтированный узел сразу (не дожидаясь afterEach) — нужно там, где
 *  несколько шторок последовательно портируются в document.body и не должны смешаться. */
function unmountOne(mount: { el: HTMLElement }) {
  const idx = mounted.findIndex((m) => m.el === mount.el)
  if (idx === -1) return
  const m = mounted[idx]!
  mounted.splice(idx, 1)
  m.root.unmount()
  m.el.remove()
}

// ── M-013 · страница партии, продана целиком (matched/confirmed) ────────────
it('M-013: блока «ПРОДАЖА ЧАСТЯМИ» нет ни при matched, ни при confirmed; покупатель — по правилу как сегодня', async () => {
  const matched = renderBatch(makeBatch({ state: 'matched', dealPrice: 1550 }))
  await expect.poll(() => bodyOf(matched.el), T).toContain('ЦЕНА СДЕЛКИ')
  expect(bodyOf(matched.el), 'блок «продажа частями» остался при matched').not.toContain('ПРОДАЖА ЧАСТЯМИ')
  expect(bodyOf(matched.el), 'при matched покупатель должен быть скрыт').not.toContain('ПОКУПАТЕЛЬ')

  const confirmed = renderBatch(makeBatch({
    state: 'confirmed', dealPrice: 1550, buyer: 'ТОО Мясной дом', buyerPhone: '+7 701 000 00 00',
  }))
  await expect.poll(() => bodyOf(confirmed.el), T).toContain('ПОКУПАТЕЛЬ')
  expect(bodyOf(confirmed.el), 'блок «продажа частями» остался при confirmed').not.toContain('ПРОДАЖА ЧАСТЯМИ')
  expect(bodyOf(confirmed.el)).toContain('ТОО Мясной дом')
  expect(bodyOf(confirmed.el), 'цена сделки должна стоять в денежной зоне').toContain('ЦЕНА СДЕЛКИ')
  expect(bodyOf(confirmed.el)).toContain('1 550')

  // Фикстуры, на которых СТАРЫЙ showSplit был истинным (ревью якоря 7): confirmed с
  // matchedHeads < heads и партия с двумя живыми строками сделки (форма b2 ремонта).
  const underSold = renderBatch(makeBatch({
    state: 'confirmed', heads: 23, matchedHeads: 9, dealPrice: 1550, buyer: 'ТОО Мясной дом',
  }))
  await expect.poll(() => bodyOf(underSold.el), T).toContain('ПОКУПАТЕЛЬ')
  expect(bodyOf(underSold.el), 'confirmed с matchedHeads < heads').not.toContain('ПРОДАЖА ЧАСТЯМИ')
  expect(bodyOf(underSold.el)).not.toContain('Продано 9 из 23')

  const twoLive = renderBatch(makeBatch({
    state: 'dispatched', heads: 30, matchedHeads: 20, dealPrice: 1550, buyer: 'ТОО Мясной дом',
    allocations: [
      { heads: 10, price: 1550, status: 'delivered', buyer: 'ТОО Мясной дом' },
      { heads: 10, price: 1550, status: 'dispatched', buyer: 'ТОО Мясной дом' },
    ],
  }))
  await expect.poll(() => bodyOf(twoLive.el), T).toContain('голов')
  expect(bodyOf(twoLive.el), 'две живые строки сделки').not.toContain('ПРОДАЖА ЧАСТЯМИ')
  expect(bodyOf(twoLive.el)).not.toContain('Продано 20 из 30')
})

// ── M-014 · отремонтированная партия (ARS-754 FR-010/FR-011) ─────────────────
it('M-014: partial-остаток отремонтирован в delivered — «принята», без «Продано N из M» и без слова «частями»', async () => {
  const batch = makeBatch({
    state: 'delivered',
    heads: 20,
    matchedHeads: 10,
    dealPrice: 1600,
    allocations: [
      { heads: 10, price: 1600, status: 'delivered', buyer: 'ТОО Мясной дом', buyerPhone: '+7 701 000 00 00' },
    ],
  })
  const page1 = renderBatch(batch)
  await expect.poll(() => bodyOf(page1.el), T).toContain('Партия принята покупателем')
  expect(bodyOf(page1.el), 'фраза «продано N из M» осталась после ремонта').not.toContain('Продано')
  expect(bodyOf(page1.el), 'слово «частями» осталось после ремонта').not.toContain('частями')
  expect(bodyOf(page1.el), 'блок «продажа частями» остался после ремонта').not.toContain('ПРОДАЖА ЧАСТЯМИ')

  const card = renderCard(batch)
  await expect.poll(() => bodyOf(card.el), T).toContain('Доставлено')
  expect(bodyOf(card.el), 'чип должен быть «Доставлено», не «частями»').not.toContain('частями')
})

// ── M-015 · список «Рынка» — ни у одной партии нет следов дробления ──────────
it('M-015: список карточек не показывает «Продаётся частями» и «Продано N из M» ни для одного статуса', async () => {
  // `partial` в наборе намеренно: «любая партия» — только на нём старый словарь давал
  // «Продаётся частями» / «Продано N из M» (без него тест не падал бы на старом коде).
  const states: Batch['state'][] = ['published', 'offering', 'partial', 'matched', 'confirmed', 'delivered']
  const container = document.createElement('div')
  document.body.appendChild(container)
  const root = createRoot(container)
  root.render(
    <>
      {states.map((state) => (
        <BatchCard key={state} b={makeBatch({ id: `b-${state}`, state, dealPrice: 1550, matchedHeads: 9 })} onOpen={vi.fn()} />
      ))}
    </>,
  )
  mounted.push({ root, el: container })

  await expect.poll(() => bodyOf(container), T).toContain('голов')
  expect(bodyOf(container)).not.toContain('Продаётся частями')
  expect(bodyOf(container)).not.toContain('Продано')
})

// ── M-016 · шторка «Снять с продажи» — тексты как сегодня, без ветки «частями» ──
it('M-016: шторка снятия для published/matched — как сегодня, ветки «частями» нет', async () => {
  const published = renderWithdraw(makeBatch({ state: 'published' }))
  await expect.poll(() => bodyGlobal(), T).toContain('Партию можно выставить заново')
  expect(bodyGlobal()).not.toContain('частями')
  expect(bodyGlobal()).not.toContain('остаток')
  unmountOne(published)

  const matched = renderWithdraw(makeBatch({ state: 'matched' }))
  await expect.poll(() => bodyGlobal(), T).toContain('Покупатель уже найден')
  expect(bodyGlobal()).not.toContain('частями')
  expect(bodyGlobal()).not.toContain('кусков')
  unmountOne(matched)

  // Ветки «частями» нет и для дефектного partial (старая шторка показывала на нём
  // «Снять остаток (N гол.)» — без этой проверки тест не падал бы на старом коде).
  const partial = renderWithdraw(makeBatch({ state: 'partial', heads: 23, matchedHeads: 9 }))
  await expect.poll(() => bodyGlobal(), T).toContain('Снять')
  expect(bodyGlobal()).not.toContain('Снять остаток')
  expect(bodyGlobal()).not.toContain('Продано 9 из 23')
  unmountOne(partial)
})

// ── M-017 · отгрузка целой сделки ручного маршрута ───────────────────────────
it('M-017: confirmed с одной строкой сделки на всю партию — «Партия отгружена» → шторка с числом голов партии', async () => {
  const batch = makeBatch({
    state: 'confirmed',
    dealPrice: 1550,
    buyer: 'ТОО Мясной дом',
    buyerPhone: '+7 701 000 00 00',
    allocations: [
      { heads: 23, price: 1550, status: 'confirmed', buyer: 'ТОО Мясной дом', buyerPhone: '+7 701 000 00 00' },
    ],
  })
  const { el, onPatch } = renderBatch(batch)

  await expect.poll(() => buttonByText(el, 'Партия отгружена'), T).toBeTruthy()
  buttonByText(el, 'Партия отгружена')!.click()

  // Sheet (IonModal) портирует содержимое в конец document.body — не в el.
  await expect.poll(() => bodyGlobal(), T).toContain('Подтвердите отгрузку')
  expect(bodyGlobal(), 'шторка отгрузки должна показывать голов всей партии (23), а не долю')
    .toContain('23 гол.')

  buttonGlobal('Подтвердить отгрузку')!.click()
  expect(onPatch).toHaveBeenCalledWith({ _dispatchReady: true, dispatchedLabel: 'сегодня' }, 'Покупатель уведомлён об отгрузке')
})

// ── M-020 · дефект: partial всё же пришёл — сырой код, без чипа/фразы/действий ──
it('M-020: batch.state = partial (дефект) — карточка списка показывает сырой код, страница партии — без фразы и без действий', async () => {
  const batch = makeBatch({ state: 'partial', matchedHeads: 9, heads: 23 })

  const card = renderCard(batch)
  await expect.poll(() => bodyOf(card.el), T).toContain('голов')
  expect(bodyOf(card.el), 'словаря для partial больше нет — карточка обязана показать сырой код')
    .toContain('partial')
  expect(bodyOf(card.el)).not.toContain('Продаётся частями')

  const { el } = renderBatch(batch)
  await expect.poll(() => bodyOf(el), T).toContain('голов')
  expect(bodyOf(el), 'фраза статуса не должна остаться для дефектного partial').not.toContain('Часть партии')
  expect(bodyOf(el)).not.toContain('Отгрузить готовое')
  expect(el.querySelector('.mk-kebab'), 'на дефектной partial-партии не должно быть меню действий').toBeNull()
  expect(buttonByText(el, 'Снять с продажи'), 'на дефектной partial-партии не должно быть действия «Снять с продажи»')
    .toBeUndefined()
})
