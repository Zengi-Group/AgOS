// AgOS · ARS-755 · «Цену назначает фермер, и записывается ровно она» — UI-строки матрицы.
// Предмет: Docs/AGOS-TSP-FarmerOwnsPrice-ARS-755.md, раздел `## I/O & Edge-Case Matrix`,
// строки M-004, M-005, M-010, M-011, M-012, M-015.
//
// Один тест = одна строка матрицы, id в названии (Matrix Test Audit сверяет ПО ID:
// строка, совпавшая «по смыслу», считается непокрытой).
//
// ПОЧЕМУ ЭТИ СТРОКИ ЖИВУТ ЗДЕСЬ, А НЕ В SQL-ПРОГОНЕ. Дефект слайса двусторонний: сервер
// подменял цену (`least` в rpc_lower_price), а экран ЗАПРЕЩАЛ ввод, которого канон не
// запрещал. SQL-тест (tests/ars_755_farmer_owns_price_test.sql) закрывает первую половину;
// вторая наблюдаема только на экране — «кнопка активна», «предупреждение показано, но не
// блокирует», «число шага пришло из настройки, а не из хардкода».
//
// НЕ ПОКРЫТО ЗДЕСЬ И ПОЧЕМУ:
//   · M-001..M-003, M-006..M-009, M-013, M-016..M-018 — дом SQL-прогон (запись в БД, ACL).
//   · M-014 (при ошибке RPC тост успеха не показывается, значение откатывается) живёт
//     не на экране, а в цепочке `useBatches.patchBatch` → `CabinetApp.patchBatch`:
//     `BatchScreen` получает `onPatch` пропсом и об исходе RPC не знает. Поэтому его
//     тест внизу монтирует САМ ХУК через тестовую обёртку — иначе проверялся бы мок, а
//     не откат. Вторая половина строки (тост успеха не показывается) держится на том,
//     что `patchBatch` ОТКЛОНЯЕТ промис: `CabinetApp.patchBatch:647` показывает тост
//     только в `.then`, а в `.catch` — текст ошибки.
//
// Запуск: npx vitest run --project routers
//
// ФАЛЬСИФИЦИРУЕМОСТЬ. Без правок слайса падают: M-004 (кнопка «Предложить по …» была
// disabled ниже защитной цены), M-010 (шаг был хардкодом `cur − 100` и не читал ключ
// партии), M-011/M-015 (текстов не существовало), M-012 (в шторке «Сохранить цену» была
// disabled ниже защитной).
//
// @case TSPF-LIFE-02 TSPF-LIFE-03 TSPF-LIFE-04
//   (qa/scenarios/05-tsp-farmer.md — снижение цены, подсказка ниже пола, ручная смена цены.
//   Теги M-NNN здесь намеренно не проставлены: это id СПЕКОВОЙ матрицы ARS-755, а не
//   qa/scenarios/, и те же номера заняты чужими слайсами.)

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import { HostProvider } from '@/platform/host/HostContext'
import { BatchScreen } from '@/pages/cabinet/shell/screens/BatchScreen'
import { BatchPriceSheet } from '@/pages/cabinet/shell/components/sheets/BatchPriceSheet'
import { useBatches } from '@/pages/cabinet/shell/hooks/useBatches'
import type { Batch } from '@/pages/cabinet/shell/types'

/** Форма возврата useBatches, нужная тесту M-014 (полный тип хук не экспортирует). */
interface UseBatchesLike {
  batches: Batch[]
  patchBatch: (id: string, patch: Partial<Batch>) => Promise<void>
}

/** Управляемый отказ RPC — только для M-014; остальные тесты его не взводят.
 *  `names` пишет имена вызванных RPC: без этого ни один прибор не видел, КАКУЮ функцию
 *  зовёт шторка, и возврат `rpc_update_price` (no-op) прошёл бы все тесты зелёным. */
const rpcSpy = vi.hoisted(() => ({ lowerPrice: false, names: [] as string[] }))
const rpcFail = rpcSpy

vi.mock('@/lib/supabase', () => {
  const user = { id: 'ars755-user', user_metadata: { full_name: 'Фермер Тест' }, phone: '' }
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
      rpc: async (name: string) => {
        rpcSpy.names.push(name)
        if (name === 'rpc_lower_price' && rpcFail.lowerPrice) {
          return { data: null, error: { message: 'RPC_DOWN', code: 'PGRST' } }
        }
        if (name === 'rpc_get_org_batches') {
          return ok([{
            id: 'ars755-batch', state: 'published', cat: 'bychki', breed: 'Ангус',
            heads: 20, avgWeight: 430, price: 1500, priceStepDown: 100, history: [],
          }])
        }
        return ok(null)
      },
    },
  }
})

/** Партия в точке решения по цене. `cat: 'bychki'` — у категории есть защитная цена
 *  (`CATS[cat].prot`, src/pages/cabinet/shell/data/status.ts), поэтому ориентир на экране
 *  реален, а не выключен отсутствием числа. */
function makeBatch(patch: Partial<Batch> = {}): Batch {
  return {
    id: 'ars755-batch',
    state: 'decision',
    cat: 'bychki',
    breed: 'Ангус',
    heads: 20,
    avgWeight: 430,
    price: 1500,
    priceStepDown: 100,
    history: [],
    ...patch,
  }
}

const T = { timeout: 15_000 }
let root: Root | null = null
let mountEl: HTMLElement | null = null

function mountBatch(batch: Batch, onPatch = vi.fn()) {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
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
  return onPatch
}

function mountSheet(batch: Batch, onConfirm = vi.fn()) {
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(
    <HostProvider>
      <BatchPriceSheet batch={batch} open onClose={vi.fn()} onConfirm={onConfirm} />
    </HostProvider>,
  )
  return onConfirm
}

const buttonByText = (t: string): HTMLButtonElement | undefined =>
  Array.from(document.querySelectorAll('button')).find((b) => b.textContent?.includes(t))

/** Ждёт появления кнопки и нажимает. Без ожидания тест падает на первом рендере экрана,
 *  а не на проверяемом требовании — и тогда он меряет скорость монтирования, не поведение. */
async function clickButton(t: string): Promise<void> {
  await expect.poll(() => buttonByText(t), T).toBeTruthy()
  buttonByText(t)!.click()
}

/** Разряды в `fmtMoney` разделяются НЕРАЗРЫВНЫМ пробелом (tsp-utils.ts:8), поэтому сравнение
 *  с обычным пробелом не сойдётся ни на одной цене ≥ 1000. Нормализуем при чтении, а не
 *  подгоняем ожидания под невидимый символ. */
const norm = (s: string) => s.replace(/\u00a0/g, ' ')
const bodyText = () => norm(document.body.textContent ?? '')

/** Цена из первого вызова `onPatch`. Отдельный хелпер, потому что «вызова не было» и
 *  «вызов был с другой ценой» — разные провалы, и их нельзя схлопывать в одно `undefined`. */
function patchedPrice(onPatch: ReturnType<typeof vi.fn>): number | undefined {
  const first = onPatch.mock.calls[0]
  expect(first, 'onPatch не вызван — экран не отправил цену вовсе').toBeTruthy()
  return (first?.[0] as Partial<Batch> | undefined)?.price
}

/** Открывает форму «Назначить свою цену» и вводит значение. Ввод идёт нативным сеттером:
 *  React слушает событие `input`, а прямое присваивание `value` его не поднимает. */
async function typeCustomPrice(value: string) {
  await clickButton('Назначить свою цену')
  await expect.poll(() => document.querySelector('input.mk-input.price'), T).toBeTruthy()
  const input = document.querySelector('input.mk-input.price') as HTMLInputElement
  setNativeValue(input, value)
}

function setNativeValue(el: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
  setter?.call(el, value)
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

beforeEach(async () => {
  await page.viewport(430, 900)
  rpcSpy.lowerPrice = false
  rpcSpy.names = []
})

afterEach(() => {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
  window.localStorage.clear()
})

// ── M-015 · правило названо словами ДО нажатия ───────────────────────────────
it('ARS-755 M-015: на экране точки решения правило названо до любого нажатия', async () => {
  mountBatch(makeBatch())

  await expect.poll(() => bodyText(), T).toContain('Цену назначаете вы')
  expect(bodyText(), 'правило названо не полностью — фермер не знает, что можно поднять')
    .toContain('можно поднять, снизить или оставить прежней')
})

// ── M-011 · факт без совета ──────────────────────────────────────────────────
it('ARS-755 M-011: показан факт «покупателей не нашлось», рекомендации о цене фермера нет', async () => {
  // Состояние строки матрицы — «экран точки решения», а не «форма ввода»: факт обязан
  // быть виден ДО любого нажатия (найдено сверкой замысел↔реальность).
  mountBatch(makeBatch())

  await expect.poll(() => bodyText(), T).toContain('покупателей не нашлось')
  // Ст. 171: ассоциация не советует фермеру, какую цену ставить. Блок «Рекомендуем» —
  // это шаг понижения (FR-005, преэкзистентный и сохранённый), и в форме ввода его нет.
  expect(bodyText(), 'экран комментирует решение фермера о его цене').not.toContain('шансов')
  expect(bodyText(), 'экран советует поднять/не поднимать цену').not.toContain('советуем')
})

// ── M-004 · ниже защитной: предупреждают, но разрешают ───────────────────────
it('ARS-755 M-004: ввод ниже защитной — предупреждение показано, кнопка активна, цена уходит как введена', async () => {
  const onPatch = mountBatch(makeBatch())
  await typeCustomPrice('1300')   // защитная у bychki выше 1300

  await expect.poll(() => bodyText(), T).toContain('Ниже защитного уровня')
  const confirm = buttonByText('Предложить по')!
  expect(confirm.disabled, 'жёсткий запрет «ниже нельзя» вернулся — канон его не вводил').toBe(false)

  confirm.click()
  expect(onPatch).toHaveBeenCalledTimes(1)
  expect(patchedPrice(onPatch), 'экран подменил названную фермером цену').toBe(1300)
})

// ── M-004 (вторая половина) · выше текущей — верхней границы нет ─────────────
it('ARS-755 M-004: подъём выше текущей разрешён и уходит ровно названным числом', async () => {
  const onPatch = mountBatch(makeBatch({ price: 1500 }))
  await typeCustomPrice('1600')

  const confirm = await vi.waitFor(() => {
    const b = buttonByText('Предложить по')!
    expect(b.disabled).toBe(false)
    return b
  }, T)
  expect(norm(confirm.textContent ?? ''), 'экран подтверждает не то число, которое ввёл фермер')
    .toContain('1 600')

  confirm.click()
  expect(patchedPrice(onPatch)).toBe(1600)
  // M-001 требует, чтобы ТОСТ называл записанное число, а не только кнопка: подтверждение
  // фермеру и запись в БД должны говорить одно и то же — весь слайс про это.
  expect(norm((onPatch.mock.calls[0]?.[1] as string | undefined) ?? ''),
    'тост не называет цену — фермер не получает подтверждения числа').toContain('1 600')
})

// ── M-005 · пусто / ноль ─────────────────────────────────────────────────────
it('ARS-755 M-005: пустое поле и «0» — кнопка неактивна, вызова не происходит', async () => {
  const onPatch = mountBatch(makeBatch())
  await clickButton('Назначить свою цену')
  await expect.poll(() => document.querySelector('input.mk-input.price'), T).toBeTruthy()

  expect(buttonByText('Предложить по')!.disabled, 'пустое поле пропущено к подтверждению').toBe(true)

  const input = document.querySelector('input.mk-input.price') as HTMLInputElement
  setNativeValue(input, '0')
  await expect.poll(() => buttonByText('Предложить по')!.disabled, T).toBe(true)
  expect(onPatch).not.toHaveBeenCalled()
})

// ── M-010 · шаг читается из настройки, а не из хардкода ──────────────────────
it('ARS-755 M-010: шаг подсказки берётся из партии (tsp_config), хардкода −100 больше нет', async () => {
  // Текущая 1800 взята намеренно: защитная у `bychki` = 1400, и при 1500 подсказка
  // 1500−200=1300 ушла бы ниже пола — блок по замыслу скрылся бы (FR-003), и тест мерил
  // бы не тот факт. 1800−200=1600 ≥ 1400 — блок виден, а хардкод дал бы 1700.
  const onPatch = mountBatch(makeBatch({ price: 1800, priceStepDown: 200 }))

  await expect.poll(() => bodyText(), T).toContain('1 600')
  expect(bodyText(), 'подсказка посчитана хардкодом −100, а не шагом из настройки').not.toContain('1 700')

  await clickButton('Снизить и предложить снова')
  expect(patchedPrice(onPatch)).toBe(1600)
})

// ── M-010 (край) · ключа шага нет — подсказки нет, своего числа фронт не держит ──
it('ARS-755 M-010: ключ шага не пришёл — блок подсказки не показывается вовсе', async () => {
  mountBatch(makeBatch({ priceStepDown: null }))

  await expect.poll(() => bodyText(), T).toContain('Назначить свою цену')
  expect(buttonByText('Снизить и предложить снова'),
    'фронт придумал шаг сам — у числа снова два дома').toBeUndefined()
  expect(bodyText()).not.toContain('Рекомендуем')
})

// ── M-012 · шторка «Изменить цену» — те же правила ───────────────────────────
it('ARS-755 M-012: в шторке ниже защитной предупреждают, но сохранить дают, и число уходит как введено', async () => {
  const onConfirm = mountSheet(makeBatch({ state: 'published' }))
  const input = await vi.waitFor(() => {
    const el = document.querySelector('input.dec-price-input') as HTMLInputElement
    expect(el).toBeTruthy()
    return el
  }, T)

  setNativeValue(input, '1300')
  await expect.poll(() => bodyText(), T).toContain('Ниже защитного уровня')
  const save = buttonByText('Сохранить цену')!
  expect(save.hasAttribute('disabled'), 'в шторке остался жёсткий запрет ниже защитной').toBe(false)

  save.click()
  expect(onConfirm).toHaveBeenCalledWith(1300)
})

// ── M-012 (вторая половина) · подъём в шторке ────────────────────────────────
it('ARS-755 M-012: в шторке подъём выше текущей разрешён', async () => {
  const onConfirm = mountSheet(makeBatch({ state: 'published', price: 1500 }))
  const input = await vi.waitFor(() => {
    const el = document.querySelector('input.dec-price-input') as HTMLInputElement
    expect(el).toBeTruthy()
    return el
  }, T)

  setNativeValue(input, '1600')
  await expect.poll(() => buttonByText('Сохранить цену')!.hasAttribute('disabled'), T).toBe(false)
  expect(bodyText(), 'правило не названо в шторке').toContain('Цену назначаете вы')

  buttonByText('Сохранить цену')!.click()
  expect(onConfirm).toHaveBeenCalledWith(1600)
})

// ── M-014 · ошибка RPC: откат значения и отказ промиса ───────────────────────
// Хук монтируется по-настоящему: мок supabase отдаёт партию по rpc_get_org_batches и
// ошибку по rpc_lower_price. Тест над `BatchScreen` этот путь не увидел бы вовсе.
it('ARS-755 M-014: RPC не прошла — цена откатывается, промис отклонён (тоста успеха не будет)', async () => {
  rpcFail.lowerPrice = true
  const calls: { ok: boolean; err: string }[] = []
  let hook: UseBatchesLike | null = null

  function Probe() {
    hook = useBatches('ars755-user')
    return null
  }
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<Probe />)

  // Дождаться загрузки партии из мока — до неё откатывать нечего.
  await expect.poll(() => hook?.batches.find((b) => b.id === 'ars755-batch')?.price, T).toBe(1500)

  await hook!.patchBatch('ars755-batch', { state: 'offering', price: 1600 })
    .then(() => calls.push({ ok: true, err: '' }))
    .catch((e: unknown) => calls.push({ ok: false, err: e instanceof Error ? e.message : String(e) }))

  expect(calls[0]?.ok, 'промис успешен при упавшей RPC — CabinetApp покажет тост успеха на лжи').toBe(false)
  await expect.poll(
    () => hook?.batches.find((b) => b.id === 'ars755-batch')?.price, T,
  ).toBe(1500)
})

// ── M-012 (третья половина) · шторка пишет цену ТОЙ ЖЕ RPC, что и точка решения ──
// Без этого утверждения возврат `rpc_update_price` (no-op-success, 20260622120000:638)
// прошёл бы всю проверку зелёным: экранные тесты смотрят собственный `onConfirm`,
// SQL-прогон зовёт функцию напрямую и не видит, какое имя набирает кабинет.
it('ARS-755 M-012: смена цены из шторки уходит в rpc_lower_price, а не в no-op rpc_update_price', async () => {
  let hook: UseBatchesLike | null = null
  function Probe() {
    hook = useBatches('ars755-user')
    return null
  }
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<Probe />)
  await expect.poll(() => hook?.batches.length, T).toBe(1)

  rpcSpy.names = []
  await hook!.patchBatch('ars755-batch', { price: 1600 })   // патч ШТОРКИ — без state

  expect(rpcSpy.names, 'шторка снова пишет в no-op — фермеру покажут успех на пустом месте')
    .not.toContain('rpc_update_price')
  expect(rpcSpy.names, 'шторка не дошла до записи цены вовсе').toContain('rpc_lower_price')
  // Ре-броадкаст по новой цене нужен обеим дверям одинаково: смена цены гасит старые
  // предложения (FR-007), и без него партия осталась бы без единого живого предложения.
  expect(rpcSpy.names, 'после смены цены из шторки рынок не переспрошен')
    .toContain('rpc_self_auto_match_batch')
})

// ── M-006 (экранная половина) · «Оставить цену и ждать» реально пишет ────────
// SQL-прогон проверяет поведение RPC, но не то, что до неё доходит НАЖАТИЕ. Верни сюда
// прежний `toast(...)` — сервер останется невызванным, а все остальные тесты зелёными.
it('ARS-755 M-006: «Оставить цену и ждать» отправляет текущую цену, а не только тост', async () => {
  const onPatch = mountBatch(makeBatch({ price: 1500 }))
  await clickButton('Оставить цену и ждать')

  expect(patchedPrice(onPatch), 'действие не отправило цену — партия осталась в точке решения')
    .toBe(1500)
  const toastText = onPatch.mock.calls[0]?.[1] as string | undefined
  expect(toastText, 'тост обещает рассылку по НОВОЙ цене, хотя цена не менялась')
    .not.toContain('по новой цене')
})

// ── M-006 / M-017 · «оставить цену» не трогает рынок ─────────────────────────
// Ре-броадкаст здесь запрещён замыслом: живое тело rpc_self_auto_match_batch при непустом
// рынке уводит партию в `offering` и переставляет живым предложениям срок
// (20260918120000:128-138) — а M-006 требует `published`, M-017 «предложения не трогаются».
it('ARS-755 M-006/M-017: «оставить цену» пишет ту же цену и НЕ зовёт ре-броадкаст', async () => {
  let hook: UseBatchesLike | null = null
  function Probe() {
    hook = useBatches('ars755-user')
    return null
  }
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<Probe />)
  await expect.poll(() => hook?.batches.find((b) => b.id === 'ars755-batch')?.price, T).toBe(1500)

  rpcSpy.names = []
  await hook!.patchBatch('ars755-batch', { state: 'offering', price: 1500 })   // цена ТА ЖЕ

  expect(rpcSpy.names, 'запись цены не дошла до сервера').toContain('rpc_lower_price')
  expect(rpcSpy.names, 'неизменная цена запустила ре-броадкаст — рынку переставят сроки')
    .not.toContain('rpc_self_auto_match_batch')
})

// ── M-001 (вторая половина) · фактическая смена цены рынок ПЕРЕСПРАШИВАЕТ ─────
it('ARS-755 M-001: смена цены зовёт ре-броадкаст по новой цене', async () => {
  let hook: UseBatchesLike | null = null
  function Probe() {
    hook = useBatches('ars755-user')
    return null
  }
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<Probe />)
  await expect.poll(() => hook?.batches.find((b) => b.id === 'ars755-batch')?.price, T).toBe(1500)

  rpcSpy.names = []
  await hook!.patchBatch('ars755-batch', { state: 'offering', price: 1600 })

  expect(rpcSpy.names).toContain('rpc_lower_price')
  expect(rpcSpy.names, 'после смены цены рынок не переспрошен — партия осталась без предложений')
    .toContain('rpc_self_auto_match_batch')
})
